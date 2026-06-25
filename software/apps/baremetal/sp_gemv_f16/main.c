// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Diyou Shen,              ETH Zurich <dishen@iis.ee.ethz.ch>
//         Navaneeth Kunhi Purayil, ETH Zurich <nkunhi@iis.ee.ethz.ch>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "dma.h"
#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#ifndef SP_GEMV_DATA_HEADER
#define SP_GEMV_DATA_HEADER "data_sp_gemv_f16.h"
#endif
#include SP_GEMV_DATA_HEADER

#include "baremetal/mempool_sp_gemv_f16.h"
#include "mempool_checks.h"

// Matrix A: MxN, Vector X: Nx1, Vector Y: Mx1
//
// Column-major only: A comes from transpose_a=1.

__fp16 l1_A[matrix_M * matrix_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
__fp16 l1_X[matrix_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
__fp16 l1_Y[matrix_M]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

__fp16 l2_Y_check[matrix_M]
    __attribute__((aligned(4 * NUM_BANKS), section(".l2")));

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  uint32_t time_init, time_end;
  mempool_barrier_init(core_id);

  // Copy the inputs into the local L1 scratchpad.
  if (core_id == 0) {
    dma_memcpy_blocking(l1_A, l2_A, (matrix_M * matrix_N) * sizeof(__fp16));
    dma_memcpy_blocking(l1_X, l2_X, (matrix_N) * sizeof(__fp16));
  }
  mempool_barrier(num_cores);

  // Work distribution
  unsigned int m_core = matrix_M / num_cores;
  __fp16 *l1_A_core = l1_A + m_core * core_id;
  __fp16 *l1_X_core = l1_X;
  __fp16 *l1_Y_core = l1_Y + m_core * core_id;

  // PARALLEL, LOCAL ACCESSES
  time_init = mempool_get_timer();
  mempool_start_benchmark();
  gemv_f16_col(l1_A_core, l1_X_core, l1_Y_core, matrix_M, m_core, matrix_N);
  mempool_log_barrier(2, core_id);
  mempool_stop_benchmark();
  time_end = mempool_get_timer();

  // Report cycles
  if (core_id == 0) {
    uint32_t clock_cycles = (time_end - time_init);
    printf("\nKernel execution takes %d clock cycles\n", clock_cycles);
  }

  // L2 buffer to hold the result for the testbench DPI checker.
  if (core_id == 0) {
    dma_memcpy_blocking(l2_Y_check, l1_Y, matrix_M * sizeof(__fp16));
  }
  mempool_check_dpi_f16(l2_Y_check, l2_Y, matrix_M, 0.01f, 0);
  mempool_barrier(num_cores);

  return 0;
}
