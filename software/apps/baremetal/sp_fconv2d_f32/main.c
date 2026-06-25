// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Matteo Perotti <mperotti@iis.ee.ethz.ch>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "dma.h"
#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#include "data_sp_fconv2d_f32.h"

#include "baremetal/mempool_sp_fconv2d_f32.h"
#include "mempool_checks.h"

float imtx[CH * (R + F - 1) * (C + F - 1)]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float omtx[R * C] __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float fmtx[CH * F * F]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

float l2_R_check[R * C] __attribute__((aligned(4 * NUM_BANKS), section(".l2")));

int main() {

  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  uint32_t time_init, time_end;
  mempool_barrier_init(core_id);

  // Set matrix dimension
  const uint32_t r = R;
  const uint32_t c = C;
  const uint32_t f = F;
  const uint32_t ch = CH;

  // We support only square matrices for now
  if (r != c)
    return -9;

  uint32_t num_rows = r / num_cores;
  float *i = imtx + core_id * num_rows * (c + f - 1);
  float *o = omtx + core_id * num_rows * c;

  // Initialize data
  if (core_id == 0) {
    dma_memcpy_blocking(fmtx, fconv2d_F_dram, f * f * ch * sizeof(float));
    dma_memcpy_blocking(imtx, fconv2d_I_dram,
                        (r + f - 1) * (c + f - 1) * sizeof(float));
    dma_memcpy_blocking(omtx, fconv2d_R_dram, r * c * sizeof(float));
  }
  mempool_barrier(num_cores);

  // PARALLEL
  time_init = mempool_get_timer();
  mempool_start_benchmark();
  conv3d_CHx7x7(o, i, fmtx, num_rows);
  mempool_barrier(num_cores);
  mempool_stop_benchmark();
  time_end = mempool_get_timer();

  // Check results
  if (core_id == 0) {
    uint32_t timer = time_end - time_init;
    uint32_t performance = 1000 * 2 * ch * f * f * r * c / timer;
    uint32_t utilization = performance / (2 * num_cores * N_FPU);

    printf("\n----- (%dx%d) fp fconv2d -----\n", r, c);
    printf("The execution took %u cycles.\n", timer);
    printf("The performance is %u OP/1000cycle (%u%%o utilization).\n",
           performance, utilization);
  }
  if (core_id == 0) {
    dma_memcpy_blocking(l2_R_check, omtx, r * c * sizeof(float));
  }
  mempool_check_dpi_f32(l2_R_check, fconv2d_GR_dram, r * c, 0.01f, 0);
  mempool_barrier(num_cores);

  return 0;
}
