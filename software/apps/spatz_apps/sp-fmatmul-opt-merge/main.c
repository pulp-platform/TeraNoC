// SPDX-License-Identifier: Apache-2.0
//
// sp-matmult-opt-merge
// -------------------
// A variant of sp-fmatmul-opt that is more "group-MSHR friendly":
// - Avoid splitting the P dimension across tiles (which explodes the number of
//   distinct remote words in-flight).
// - Instead, prefer splitting only along M by selecting a smaller kernel_size
//   (1/2/4/8) so that each group has enough M-blocks for all cores.
// - Optionally cap the vector length (FMATMUL_MAX_VL) to reduce the number of
//   32-bit word loads per vector load (useful for profiling word-granularity
//   merge and for matching a future 16-word burst design).
//
// Note: This intentionally keeps the software transparent (no explicit
// communication between tiles). The goal is to shape the access schedule so the
// group-level word-merge MSHR sees fewer distinct words per cycle.

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Reuse the same auto-generated GEMM data as sp-fmatmul-opt.
#include "../sp-fmatmul-opt/data/data_gemm.h"

// Use a locally modified kernel implementation (in this app folder).
#include "kernel/sp-fmatmul.c"

#include "printf.h"

#ifdef MEMPOOL
#include "alloc.h"
#include "encoding.h"
#include "runtime.h"
#include "synchronization.h"
#endif

#define USE_DMA
#ifdef USE_DMA
#include "dma.h"
#endif

// Allow running with fewer active groups than the hardware provides. This is
// useful to increase dim_group (= M/active_groups) so we can avoid splitting P
// across cores while still keeping cores per active group busy.
#ifndef ACTIVE_GROUPS
#define ACTIVE_GROUPS NUM_GROUPS
#endif

static void init_matrix(float *matrix, const float *src, const uint32_t rows_start,
                        const uint32_t rows_end, const uint32_t num_columns) {
  for (uint32_t i = rows_start; i < rows_end; ++i) {
    for (uint32_t j = 0; j < num_columns; ++j) {
      matrix[i * num_columns + j] = src[i * num_columns + j];
    }
  }
}

static int verify_matrix(float *matrix, const float *checksum,
                         const uint32_t num_rows, const uint32_t num_columns) {
  for (uint32_t i = 0; i < num_rows; ++i) {
    float sum = 0.0f;
    for (uint32_t j = 0; j < num_columns; ++j) {
      sum += matrix[i * num_columns + j];
    }
    float diff = sum - checksum[i];
    if (diff < 0.0f) diff = -diff;
    if (diff > 0.001f) return (i == 0) ? -1 : (int)i;
  }
  return 0;
}

static inline uint32_t pick_kernel_size(uint32_t dim_group, uint32_t cores_per_group) {
  // Prefer larger kernels (better compute intensity) but only if we can keep all
  // cores busy without splitting P.
  if ((dim_group / 8) >= cores_per_group) return 8;
  if ((dim_group / 4) >= cores_per_group) return 4;
  if ((dim_group / 2) >= cores_per_group) return 2;
  return 1;
}

int main() {
  const uint32_t num_cores       = mempool_get_core_count();
  const uint32_t cores_per_group = num_cores / NUM_GROUPS;
  const uint32_t cid             = mempool_get_core_id();
  const uint32_t core_gid        = cid % cores_per_group;
  const uint32_t gid             = cid / cores_per_group;

  const uint32_t active_groups =
      (ACTIVE_GROUPS < NUM_GROUPS) ? (uint32_t)ACTIVE_GROUPS : (uint32_t)NUM_GROUPS;

  // Group block in M.
  const uint32_t dim_group   = gemm_l.M / active_groups;
  const uint32_t kernel_size = pick_kernel_size(dim_group, cores_per_group);

  // Split only along M (never split P here).
  const uint32_t m_start = dim_group * gid + kernel_size * core_gid;
  const uint32_t m_end   = (m_start + kernel_size) < (dim_group * (gid + 1))
                               ? (m_start + kernel_size)
                               : (dim_group * (gid + 1));
  const uint32_t p_start = 0;
  const uint32_t p_end   = gemm_l.P;

  const uint32_t is_group_active = (gid < active_groups);
  const uint32_t is_core_active =
      is_group_active && (m_start < (dim_group * (gid + 1)));

  // Initialize multicore barrier.
  mempool_barrier_init(cid);

  // Make sure everyone is ready.
  mempool_barrier(num_cores);

#ifdef USE_DMA
  if (cid == 0) {
    dma_memcpy_blocking(a, gemm_A_dram, (gemm_l.M * gemm_l.N) * sizeof(float));
    dma_memcpy_blocking(b, gemm_B_dram, (gemm_l.N * gemm_l.P) * sizeof(float));
    init_matrix(r, gemm_checksum, 0, 1, gemm_l.M);
  }
#else
  init_matrix(a, gemm_A_dram, cid * (gemm_l.M / num_cores),
              (cid + 1) * (gemm_l.M / num_cores), gemm_l.N);
  init_matrix(b, gemm_B_dram, cid * (gemm_l.N / num_cores),
              (cid + 1) * (gemm_l.N / num_cores), gemm_l.P);
  if (cid == 0) init_matrix(r, gemm_checksum, 0, 1, gemm_l.M);
#endif

  mempool_barrier(num_cores);

  if (cid == 0) {
    printf("sp-matmult-opt-merge: dim_group=%u cores_per_group=%u kernel_size=%u FMATMUL_MAX_VL=%u\n",
           dim_group, cores_per_group, kernel_size, (uint32_t)FMATMUL_MAX_VL);
    printf("sp-matmult-opt-merge: active_groups=%u (NUM_GROUPS=%u)\n", active_groups,
           (uint32_t)NUM_GROUPS);
  }

  const uint32_t measure_iterations = 1;
  uint32_t best_cycles = (uint32_t)-1;

  for (uint32_t it = 0; it < measure_iterations; ++it) {
    uint32_t timer_start = 0, timer_end = 0;

    if (is_core_active) {
      timer_start = mempool_get_timer();
      if (cid == 0) mempool_start_benchmark();

      if (kernel_size == 2) {
        matmul_2xVL(c, a, b, m_start, m_end, gemm_l.N, gemm_l.P, p_start, p_end);
      } else if (kernel_size == 4) {
        matmul_4xVL(c, a, b, m_start, m_end, gemm_l.N, gemm_l.P, p_start, p_end);
      } else if (kernel_size == 1) {
        matmul_1xVL(c, a, b, m_start, m_end, gemm_l.N, gemm_l.P, p_start, p_end);
      } else {
        matmul_8xVL(c, a, b, m_start, m_end, gemm_l.N, gemm_l.P, p_start, p_end);
      }
    }

    mempool_barrier(num_cores);

    if (cid == 0) mempool_stop_benchmark();

    timer_end = mempool_get_timer();
    const uint32_t cycles = timer_end - timer_start;
    if (cid == 0 && cycles < best_cycles) best_cycles = cycles;
  }

  if (cid == 0) {
    const uint32_t used_cores =
        active_groups * ((dim_group + kernel_size - 1) / kernel_size);
    long unsigned int performance =
        1000UL * 2UL * gemm_l.M * gemm_l.P * gemm_l.N / (unsigned long)best_cycles;
    // Spatz lane count is exposed as N_FU in the build system defines.
    long unsigned int utilization = performance / (2UL * used_cores * N_FU);

    printf("\n----- (%dx%dx%d) sp matmult opt merge -----\n", gemm_l.M, gemm_l.N,
           gemm_l.P);
    printf("The execution took %u cycles.\n", best_cycles);
    printf("Used cores (no P-split): %u\n", used_cores);
    printf("The performance is %lu OP/1000cycle (%lu%%o utilization).\n",
           performance, utilization);

    const int error = verify_matrix((float *)c, (const float *)r, gemm_l.M, gemm_l.P);
    if (error != 0) {
      printf("Error: checksum[%d]=%u\n", error, (uint32_t)r[error]);
      return error;
    }
    printf("success!\n");
  }

  mempool_barrier(num_cores);
  return 0;
}
