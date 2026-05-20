// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include <string.h>

#include "builtins_v2.h"
#include "dma.h"
#include "encoding.h"
#include "runtime.h"
#include "synchronization.h"

#include "data_batchnorm_f8.h"

#include "baremetal/mempool_batchnorm_f8.h"
#include "baremetal/mempool_checks.h"

__fp8 matrix_a[matrix_M * matrix_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
__fp8 matrix_b[matrix_M * matrix_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  uint32_t time_init, time_end;
  // Initialize barrier and synchronize
  mempool_barrier_init(core_id);

  // Initialize matrices
  if (core_id == 0) {
    dma_memcpy_blocking(matrix_a, l2_A, (matrix_M * matrix_N) * sizeof(int8_t));
  }
  mempool_barrier(num_cores);

  // Matrix Normalization
  time_init = mempool_get_timer();
  mempool_start_benchmark();
  batchnorm_parallel_2x4_f8vec(matrix_a, matrix_b, matrix_M, matrix_N, core_id,
                               num_cores);
  mempool_log_barrier(2, core_id);
  mempool_stop_benchmark();
  time_end = mempool_get_timer();

  if (core_id == 0) {
    uint32_t clock_cycles = (time_end - time_init);
    printf("\nKernel execution takes %d clock cycles\n", clock_cycles);
  }
  // tolerance: tol = 0.25 = 0x34 (__fp8)
  mempool_check_f8(matrix_b, l2_B, matrix_M * matrix_N, 0x34, 0);
  mempool_barrier(num_cores);
  return 0;
}
