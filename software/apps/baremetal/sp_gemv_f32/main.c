// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Diyou Shen,              ETH Zurich <dishen@iis.ee.ethz.ch>
//         Navaneeth Kunhi Purayil, ETH Zurich <nkunhi@iis.ee.ethz.ch>
//         Yinrong Li,              ETH Zurich

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "dma.h"
#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#ifndef SP_GEMV_DATA_HEADER
#define SP_GEMV_DATA_HEADER "data_sp_gemv_f32.h"
#endif
#include SP_GEMV_DATA_HEADER

#include "baremetal/mempool_sp_gemv_f32.h"
#include "mempool_checks.h"

// Matrix A: MxN, Vector X: Nx1, Vector Y: Mx1
//
// Default/SP_GEMV_PREFETCH use column-major A from transpose_a=1.
// SP_GEMV_ROWMAJ uses row-major A from transpose_a=0 and the backup
// row-reduction kernel.
#if defined(SP_GEMV_PREFETCH) && defined(SP_GEMV_ROWMAJ)
#error "SP_GEMV_PREFETCH and SP_GEMV_ROWMAJ are mutually exclusive"
#endif

#ifdef SP_GEMV_PREFETCH
#define MULTIB NUM_CORES
#else
#define MULTIB 1
#endif

static uint32_t multiB = MULTIB;

float l1_A[matrix_M * matrix_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float l1_X[MULTIB][matrix_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float l1_Y[matrix_M]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

float l2_Y_check[matrix_M]
    __attribute__((aligned(4 * NUM_BANKS), section(".l2")));

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  uint32_t time_init, time_end;
  mempool_barrier_init(core_id);

  // Copy the inputs into the local L1 scratchpad.
  if (core_id == 0) {
    dma_memcpy_blocking(l1_A, l2_A, (matrix_M * matrix_N) * sizeof(float));
    for (uint32_t i = 0; i < multiB; i++) {
      // Copy multiple X vectors to reduce conflicts
      dma_memcpy_blocking(l1_X[i], l2_X, (matrix_N) * sizeof(float));
    }
  }
  mempool_barrier(num_cores);

  // Work distribution
  unsigned int m_core = matrix_M / num_cores;
#ifdef SP_GEMV_ROWMAJ
  float *l1_A_core = l1_A + matrix_N * m_core * core_id;
#else
  float *l1_A_core = l1_A + m_core * core_id;
#endif
  float *l1_X_core = l1_X[core_id * multiB / num_cores];
  float *l1_Y_core = l1_Y + m_core * core_id;

#ifdef SP_GEMV_PREFETCH
  uint32_t linesize = mempool_get_tile_count() * NUM_BANKS_PER_TILE;
#endif

  // PARALLEL, LOCAL ACCESSES
  time_init = mempool_get_timer();
  mempool_start_benchmark();
#ifdef SP_GEMV_ROWMAJ
  gemv_f32_row(l1_A_core, l1_X_core, l1_Y_core, m_core, matrix_N);
#elif defined(SP_GEMV_PREFETCH)
  gemv_f32_col_prefetch(l1_A_core, l1_X_core, l1_Y_core, m_core, matrix_N >> 3,
                        linesize);
#else
  gemv_f32_col(l1_A_core, l1_X_core, l1_Y_core, matrix_M, m_core, matrix_N);
#endif
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
    dma_memcpy_blocking(l2_Y_check, l1_Y, matrix_M * sizeof(float));
  }
  mempool_check_dpi_f32(l2_Y_check, l2_Y, matrix_M, 0.01f, 0);
  mempool_barrier(num_cores);

  return 0;
}
