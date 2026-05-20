// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Samuel Riedel, ETH Zurich

#include <stdint.h>
#include <string.h>

#include "dma.h"
#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#include "data_matmul_i8.h"

#include "baremetal/mempool_checks.h"
#include "baremetal/mempool_matmul_i8p.h"

int8_t l1_A[matrix_M * matrix_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
int8_t l1_B[matrix_N * matrix_P]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
int32_t l1_C[matrix_M * matrix_P]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  uint32_t time_init, time_end;
  mempool_barrier_init(core_id);

  // Initialize data
  if (core_id == 0) {
    dma_memcpy_blocking(l1_A, l2_A, matrix_M * matrix_N * sizeof(int8_t));
    dma_memcpy_blocking(l1_B, l2_B, matrix_N * matrix_P * sizeof(int8_t));
  }
  mempool_barrier(num_cores);

  // Benchmark
  time_init = mempool_get_timer();
  mempool_start_benchmark();
#ifdef __XPULPIMG
  matmul_unrolled_2x4_pincr_asm_parallel_i8_xpulpv2(
      l1_A, l1_B, l1_C, matrix_M, matrix_N, matrix_P, core_id, num_cores);
#else
  matmul_unrolled_2x2_parallel_i8_rv32im(l1_A, l1_B, l1_C, matrix_M, matrix_N,
                                         matrix_P, core_id, num_cores);
#endif
  mempool_log_barrier(2, core_id);
  mempool_stop_benchmark();
  time_end = mempool_get_timer();

  if (core_id == 0) {
    uint32_t clock_cycles = (time_end - time_init);
    printf("\nKernel execution takes %d clock cycles\n", clock_cycles);
  }

  // Verify results
  mempool_check_i32(l1_C, l2_C, matrix_M * matrix_P, 0, 0);
  mempool_barrier(num_cores);
  return 0;
}
