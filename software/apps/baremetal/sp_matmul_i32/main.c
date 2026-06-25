// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Domenic Wuthrich, ETH Zurich

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "dma.h"
#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#include "data_sp_matmul_i32.h"

#include "baremetal/mempool_sp_matmul_i32.h"
#include "mempool_checks.h"

#ifndef SP_MATMUL_I32_KERNEL_SIZE
#ifdef SP_MATMUL_KERNEL_SIZE
#define SP_MATMUL_I32_KERNEL_SIZE SP_MATMUL_KERNEL_SIZE
#else
#define SP_MATMUL_I32_KERNEL_SIZE 4
#endif
#endif

#if SP_MATMUL_I32_KERNEL_SIZE != 2 && SP_MATMUL_I32_KERNEL_SIZE != 4 &&        \
    SP_MATMUL_I32_KERNEL_SIZE != 8
#error "SP_MATMUL_I32_KERNEL_SIZE must be 2, 4, or 8"
#endif

int32_t l1_A[matrix_M * matrix_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
int32_t l1_B[matrix_N * matrix_P]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
int32_t l1_C[matrix_M * matrix_P]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

// L2 buffer to hold the result for the testbench DPI checker:
int32_t l2_C_check[matrix_M * matrix_P]
    __attribute__((aligned(4 * NUM_BANKS), section(".l2")));

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  uint32_t time_init, time_end;
  mempool_barrier_init(core_id);

  // Work-distribution geometry
  const unsigned int cores_per_group = num_cores / NUM_GROUPS;
  const unsigned int core_gid = core_id % cores_per_group;
  const unsigned int gid = core_id / cores_per_group;
  const unsigned int active_groups = NUM_GROUPS;

  unsigned int m_start, m_end;
  unsigned int p_start, p_end;
  unsigned int kernel_size;

  // Copy the inputs into the local L1 scratchpad.
  if (core_id == 0) {
    dma_memcpy_blocking(l1_A, l2_A, (matrix_M * matrix_N) * sizeof(int32_t));
    dma_memcpy_blocking(l1_B, l2_B, (matrix_N * matrix_P) * sizeof(int32_t));
  }
  mempool_barrier(num_cores);

  // Set matrix dimension
  kernel_size = SP_MATMUL_I32_KERNEL_SIZE;

  // Block dimension of group
  const unsigned int dim_group = matrix_M / active_groups;
  // Number of parallel cores in m direction
  const unsigned int split_m_count = dim_group / kernel_size;

  if (split_m_count < cores_per_group) {
    // Split P dimension up
    const unsigned int split_p_count = cores_per_group / split_m_count;
    p_start = matrix_P / split_p_count * (core_gid % split_p_count);
    p_end = matrix_P / split_p_count * ((core_gid % split_p_count) + 1);
    m_start = dim_group * gid + kernel_size * (core_gid / split_p_count);
    m_end = dim_group * gid + kernel_size * (core_gid / split_p_count + 1);
  } else {
    // Work over complete P dimension
    p_start = 0;
    p_end = matrix_P;
    m_start = dim_group * gid + (dim_group / cores_per_group) * core_gid;
    m_end = dim_group * gid + (dim_group / cores_per_group) * (core_gid + 1);
  }

  mempool_barrier(num_cores);

  // PARALLEL, LOCAL ACCESSES
  time_init = mempool_get_timer();
  mempool_start_benchmark();
  if (kernel_size == 2) {
    matmul_2xVL((int32_t *)l1_C, (const int32_t *)l1_A, (const int32_t *)l1_B,
                m_start, m_end, matrix_N, matrix_P, p_start, p_end);
  } else if (kernel_size == 4) {
    matmul_4xVL((int32_t *)l1_C, (const int32_t *)l1_A, (const int32_t *)l1_B,
                m_start, m_end, matrix_N, matrix_P, p_start, p_end);
  } else if (kernel_size == 8) {
    matmul_8xVL((int32_t *)l1_C, (const int32_t *)l1_A, (const int32_t *)l1_B,
                m_start, m_end, matrix_N, matrix_P, p_start, p_end);
  } else {
    return -2;
  }
  mempool_log_barrier(2, core_id);
  mempool_stop_benchmark();
  time_end = mempool_get_timer();

  // Check results
  if (core_id == 0) {
    uint32_t clock_cycles = (time_end - time_init);
    printf("\nKernel execution takes %d clock cycles\n", clock_cycles);
  }
  if (core_id == 0) {
    dma_memcpy_blocking(l2_C_check, l1_C,
                        matrix_M * matrix_P * sizeof(int32_t));
  }
  mempool_check_dpi_i32(l2_C_check, l2_C, matrix_M * matrix_P, 0, 0);
  mempool_barrier(num_cores);

  return 0;
}
