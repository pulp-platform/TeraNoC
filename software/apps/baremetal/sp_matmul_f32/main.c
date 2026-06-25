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

#include "data_sp_matmul_f32.h"

#include "baremetal/mempool_sp_matmul_f32.h"
#include "mempool_checks.h"

#ifndef SP_MATMUL_KERNEL_SIZE
#define SP_MATMUL_KERNEL_SIZE 8
#endif

#if SP_MATMUL_KERNEL_SIZE != 2 && SP_MATMUL_KERNEL_SIZE != 4 &&                \
    SP_MATMUL_KERNEL_SIZE != 8
#error "SP_MATMUL_KERNEL_SIZE must be 2, 4, or 8"
#endif

// Matrix A: MxN, Matrix B: NxP, Matrix C: MxP
float l1_A[matrix_M * matrix_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float l1_B[matrix_N * matrix_P]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float l1_C[matrix_M * matrix_P]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

float l2_C_check[matrix_M * matrix_P]
    __attribute__((aligned(4 * NUM_BANKS), section(".l2")));

int main() {

  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  const uint32_t cores_per_group = num_cores / NUM_GROUPS;
  const uint32_t core_gid = core_id % cores_per_group;
  const uint32_t gid = core_id / cores_per_group;

  const uint32_t active_groups = 4;
  const uint32_t active_cores = cores_per_group * active_groups;
  const uint32_t is_core_active = core_id < active_cores;

  uint32_t time_init, time_end;
  const uint32_t kernel_size = SP_MATMUL_KERNEL_SIZE;
  mempool_barrier_init(core_id);

  time_init = 0;
  time_end = 0;

  // Block dimension of group
  const uint32_t dim_group = matrix_M / active_groups;
  // Number of parallel cores in m direction
  const uint32_t split_m_count = dim_group / kernel_size;

  uint32_t m_start, m_end;
  uint32_t p_start, p_end;
  if (split_m_count < cores_per_group) {
    // Split P dimension up
    const uint32_t split_p_count = cores_per_group / split_m_count;
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

  // Initialize data
  if (core_id == 0) {
    dma_memcpy_blocking(l1_A, l2_A, (matrix_M * matrix_N) * sizeof(float));
    dma_memcpy_blocking(l1_B, l2_B, (matrix_N * matrix_P) * sizeof(float));
  }
  mempool_barrier(num_cores);

  // PARALLEL
  time_init = mempool_get_timer();
  mempool_start_benchmark();
  if (is_core_active) {
    if (kernel_size == 2) {
      matmul_2xVL(l1_C, l1_A, l1_B, m_start, m_end, matrix_N, matrix_P, p_start,
                  p_end);
    } else if (kernel_size == 4) {
      matmul_4xVL(l1_C, l1_A, l1_B, m_start, m_end, matrix_N, matrix_P, p_start,
                  p_end);
    } else if (kernel_size == 8) {
      matmul_8xVL(l1_C, l1_A, l1_B, m_start, m_end, matrix_N, matrix_P, p_start,
                  p_end);
    } else {
      return -2;
    }
  }
  mempool_log_barrier(2, core_id);
  mempool_stop_benchmark();
  time_end = mempool_get_timer();

  // Check results
  if (core_id == 0) {
    uint32_t clock_cycles = (time_end - time_init);
    long unsigned int performance =
        1000UL * 2 * matrix_M * matrix_P * matrix_N / clock_cycles;
    long unsigned int utilization = performance / (2 * active_cores * N_FPU);

    printf("\n----- (%dx%d) sp fmatmul -----\n", matrix_M, matrix_P);
    printf("\nKernel execution takes %d clock cycles\n", clock_cycles);
    printf("The performance is %u OP/1000cycle (%u%%o utilization).\n",
           performance, utilization);
  }
  if (core_id == 0) {
    dma_memcpy_blocking(l2_C_check, l1_C, matrix_M * matrix_P * sizeof(float));
  }
  mempool_check_dpi_f32(l2_C_check, l2_C, matrix_M * matrix_P, 0.01f, 0);
  mempool_barrier(num_cores);

  return 0;
}
