// Copyright 2021 ETH Zurich and University of Bologna.
//
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Author: Zexin Fu, ETH Zurich
//
// Burst-spread matmul: B matrix is redistributed with a padded row stride
// so that consecutive B rows land on different TCDM tiles. This spreads
// burst vector load traffic across all 16 tiles.
//
// Padding: B_PAD floats per row. Stride = P + B_PAD.
// Choose B_PAD so that (P + B_PAD) * 4 / 64 is coprime with 16.
// For P=128: stride=144, 144*4/64 = 9, gcd(9,16)=1 -> all tiles hit.

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "data/data_gemm.h"
#include "kernel/sp-fmatmul.c"
#include "printf.h"
#ifdef MEMPOOL
#include "alloc.h"
#include "runtime.h"
#include "synchronization.h"
#include "encoding.h"
#endif

#define USE_DMA

#ifdef USE_DMA
#include "dma.h"
#endif

// Padding per B row (in floats). Chosen so stride*4/64 is coprime with 16.
// P=128 -> stride=144 -> 144*4=576 -> 576/64=9 -> gcd(9,16)=1.
#define B_PAD 16

void init_matrix(float *matrix, const float *src,
                 const uint32_t rows_start, const uint32_t rows_end,
                 const uint32_t num_columns) {
  for (uint32_t i = rows_start; i < rows_end; ++i) {
    for (uint32_t j = 0; j < num_columns; ++j) {
      matrix[i * num_columns + j] = src[i * num_columns + j];
    }
  }
}

int verify_matrix(float *matrix, const float *checksum,
                 const uint32_t num_rows, const uint32_t num_columns) {
  for (uint32_t i = 0; i < num_rows; ++i) {
    float sum = 0;
    for (uint32_t j = 0; j < num_columns; ++j) {
      sum += (float)matrix[i * num_columns + j];
    }
    float diff = (float)sum - (float)checksum[i];
    float prec = (float)0.001;
    if (diff < 0)
      diff = -diff;
    if (diff > prec) {
      return (i) == 0 ? -1 : (int)(i);
    }
  }
  return 0;
}

// Redistribute B from row-major (stride P) to padded layout (stride P+B_PAD).
// Only the first P elements of each padded row contain data; the B_PAD
// trailing floats are unused padding.
static void spread_b_matrix(float *b_spread, const float *b_orig,
                            const uint32_t N, const uint32_t P,
                            const uint32_t B_stride) {
  for (uint32_t row = 0; row < N; ++row) {
    // Copy P elements to padded row
    for (uint32_t col = 0; col < P; ++col) {
      b_spread[row * B_stride + col] = b_orig[row * P + col];
    }
    // Zero padding region (not strictly needed but avoids X in sim)
    for (uint32_t col = P; col < B_stride; ++col) {
      b_spread[row * B_stride + col] = 0.0f;
    }
  }
}

int main() {
  const uint32_t num_cores = mempool_get_core_count();
  const uint32_t cores_per_group = num_cores / NUM_GROUPS;
  const uint32_t cid = mempool_get_core_id();
  const uint32_t core_gid = cid % cores_per_group;
  const uint32_t gid = cid / cores_per_group;

  const uint32_t active_groups = NUM_GROUPS;
  const uint32_t active_cores = cores_per_group * active_groups;
  const uint32_t is_core_active = cid < active_cores;

  const uint32_t measure_iterations = 1;
  const uint32_t B_stride = gemm_l.P + B_PAD;

  uint32_t timer_start, timer_end, timer;

  uint32_t m_start, m_end;
  uint32_t p_start, p_end;
  uint32_t kernel_size;

  mempool_barrier_init(cid);

  timer = (uint32_t)-1;
  kernel_size = 8;

  // Work distribution (same as burst-merge)
  const uint32_t dim_group = gemm_l.M / active_groups;
  const uint32_t split_m_count = dim_group / kernel_size;

  if (split_m_count < cores_per_group) {
    const uint32_t split_p_count = cores_per_group / split_m_count;
    p_start = gemm_l.P / split_p_count * (core_gid % split_p_count);
    p_end   = gemm_l.P / split_p_count * ((core_gid % split_p_count) + 1);
    m_start = dim_group * gid + kernel_size * (core_gid / split_p_count);
    m_end   = dim_group * gid + kernel_size * (core_gid / split_p_count + 1);
  } else {
    p_start = 0;
    p_end   = gemm_l.P;
    m_start = dim_group * gid + (dim_group / cores_per_group) * core_gid;
    m_end   = dim_group * gid + (dim_group / cores_per_group) * (core_gid + 1);
  }

  mempool_barrier(num_cores);

  // DMA: copy A, B, checksums to TCDM
  #ifdef USE_DMA
  if (cid == 0) {
    dma_memcpy_blocking(a, gemm_A_dram, (gemm_l.M * gemm_l.N) * sizeof(float));
    dma_memcpy_blocking(b, gemm_B_dram, (gemm_l.N * gemm_l.P) * sizeof(float));
    init_matrix(r, gemm_checksum, 0, 1, gemm_l.M);
  }
  #else
  init_matrix(a, gemm_A_dram, cid * (gemm_l.M / active_cores),
              (cid + 1) * (gemm_l.M / active_cores), gemm_l.N);
  init_matrix(b, gemm_B_dram, cid * (gemm_l.N / active_cores),
              (cid + 1) * (gemm_l.N / active_cores), gemm_l.P);
  if (cid == 0) {
    init_matrix(r, gemm_checksum, 0, 1, gemm_l.M);
  }
  #endif

  mempool_barrier(num_cores);

  // Redistribute B with padded stride for tile spreading.
  // Each core copies a portion of B rows to avoid serial bottleneck.
  {
    const uint32_t rows_per_core = gemm_l.N / active_cores;
    const uint32_t row_start = cid * rows_per_core;
    const uint32_t row_end = (cid == active_cores - 1)
                                 ? gemm_l.N
                                 : (cid + 1) * rows_per_core;
    if (is_core_active) {
      for (uint32_t row = row_start; row < row_end; ++row) {
        for (uint32_t col = 0; col < gemm_l.P; ++col) {
          b_spread[row * B_stride + col] = b[row * gemm_l.P + col];
        }
        // Zero pad
        for (uint32_t col = gemm_l.P; col < B_stride; ++col) {
          b_spread[row * B_stride + col] = 0.0f;
        }
      }
    }
  }

  if (cid == 0) {
    printf("finish copy\n");
  }

  mempool_barrier(num_cores);

  // Matrix multiplication using padded B
  for (uint32_t i = 0; i < measure_iterations; ++i) {
    if (is_core_active) {
      timer_start = mempool_get_timer();

      if (cid == 0)
        mempool_start_benchmark();

      if (kernel_size == 2) {
        matmul_2xVL(c, a, b_spread, m_start, m_end, gemm_l.N, gemm_l.P,
                    B_stride, p_start, p_end);
      } else if (kernel_size == 4) {
        matmul_4xVL(c, a, b_spread, m_start, m_end, gemm_l.N, gemm_l.P,
                    B_stride, p_start, p_end);
      } else if (kernel_size == 8) {
        matmul_8xVL(c, a, b_spread, m_start, m_end, gemm_l.N, gemm_l.P,
                    B_stride, p_start, p_end);
      } else {
        return -2;
      }

      mempool_barrier(num_cores);

      if (cid == 0)
        mempool_stop_benchmark();

      timer_end = mempool_get_timer();
      uint32_t timer_temp = timer_end - timer_start;
      if (cid == 0) {
        if (timer_temp < timer) {
          timer = timer_temp;
        }
      }
    }
  }

  if (cid == 0) {
    long unsigned int performance =
        1000 * 2 * gemm_l.M * gemm_l.P * gemm_l.N / timer;
    long unsigned int utilization = performance / (2 * active_cores * N_FPU);

    printf("\n----- (%dx%dx%d) sp fmatmul burst-spread -----\n",
           gemm_l.M, gemm_l.N, gemm_l.P);
    printf("The execution took %u cycles.\n", timer);
    printf("The performance is %u OP/1000cycle (%u%%o utilization).\n",
           performance, utilization);
  }

  // Verification
  int error = 0;
  if (cid == 0) {
    error = verify_matrix((float *)c, (const float *)r, gemm_l.M, gemm_l.P);
    if (error != 0) {
      printf("Error core %d: checksum[%d]=%u\n", cid, error, (uint32_t)r[error]);
    } else {
      printf("success!\n");
    }
  }

  mempool_barrier(num_cores);
  return error;
}
