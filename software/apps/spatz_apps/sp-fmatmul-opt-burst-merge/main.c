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

//==========================================================
// OVERVIEW
//==========================================================
// This is a parallel matrix multiplication benchmark for the TeraNoC + Spatz system.
//
// Matrix dimensions:
//   A: M x N  (input)
//   B: N x P  (input)  
//   C: M x P  (output = A * B)
//
// The computation is distributed across multiple cores:
//   - Each core computes a portion of the output matrix C
//   - DMA is used to transfer data from DRAM to TCDM (tightly-coupled data memory)
//   - The kernel uses RISC-V Vector extension for parallel computation
//
//==========================================================
// MEMORY HIERARCHY
//==========================================================
// DRAM -> TCDM -> L1 Cache -> Registers
//
// The matrices are stored in DRAM initially, then copied to TCDM for faster access.
// TCDM (Tightly-Coupled Data Memory) is a scratchpad memory that provides
// low-latency, high-bandwidth access for the compute cores.
//
//==========================================================

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

//==========================================================
// MATRIX INITIALIZATION
//==========================================================
// Copies data from source matrix (in DRAM) to destination matrix (in TCDM)
//
// Parameters:
//   matrix    : destination matrix in TCDM
//   src       : source matrix in DRAM
//   rows_start: first row to copy (inclusive)
//   rows_end  : last row to copy (exclusive)
//   num_columns: number of columns in each row
//==========================================================
void init_matrix(float *matrix, const float *src,
                 const uint32_t rows_start, const uint32_t rows_end,
                 const uint32_t num_columns) {
  // Simple nested loop to copy matrix data
  for (uint32_t i = rows_start; i < rows_end; ++i) {
    for (uint32_t j = 0; j < num_columns; ++j) {
      matrix[i * num_columns + j] = src[i * num_columns + j];
    }
  }
}

//==========================================================
// VERIFICATION
//==========================================================
// Verifies the result by comparing row sums with pre-computed checksums
//
// Each row of the correct result has a predictable sum (stored in gemm_checksum).
// This function computes the actual row sums and compares them.
//
// Returns: 0 if all checksums match, otherwise returns the row index that failed
//==========================================================
int verify_matrix(float *matrix, const float *checksum,
                 const uint32_t num_rows, const uint32_t num_columns) {
  for (uint32_t i = 0; i < num_rows; ++i) {
    // Compute sum of all elements in row i
    float sum = 0;
    for (uint32_t j = 0; j < num_columns; ++j) {
      sum += (float)matrix[i * num_columns + j];
    }

    // Compare with expected checksum
    float diff = (float)sum - (float)checksum[i];
    float prec = (float)0.001;  // tolerance for floating-point comparison
    if (diff < 0)
      diff = -diff;
    if (diff > prec) {
      // Checksum mismatch. Return the failing row as 1-based (0 == success)
      // so the caller can index the checksum array safely. The previous
      // "-1 for row 0" convention caused an r[-1] out-of-bounds read in the
      // error path.
      return (int)(i) + 1;
    }
  }
  return 0;  // All checksums matched
}

//==========================================================
// MAIN FUNCTION
//==========================================================
// Entry point for the matrix multiplication benchmark
//
// The function performs:
//   1. Core ID and group identification
//   2. Work distribution across cores
//   3. Data transfer from DRAM to TCDM
//   4. Matrix multiplication computation
//   5. Performance measurement
//   6. Result verification
//==========================================================
int main() {
  //========================================================--
  // STEP 1: IDENTIFY CORE AND GROUP
  //========================================================--
  // Each core has a unique ID (0 to num_cores-1)
  // Cores are organized into groups for synchronization
  const uint32_t num_cores = mempool_get_core_count();
  const uint32_t cores_per_group = num_cores / NUM_GROUPS;
  const uint32_t cid = mempool_get_core_id();        // My core ID
  const uint32_t core_gid = cid % cores_per_group;   // My position within group
  const uint32_t gid = cid / cores_per_group;        // My group ID

  // Determine how many cores are active in this run
  const uint32_t active_groups = NUM_GROUPS;
  const uint32_t active_cores = cores_per_group * active_groups;
  const uint32_t is_core_active = cid < active_cores;

  // Kernel preconditions for the current work-distribution scheme. Every core
  // evaluates these identical constants, so on a violation they all return
  // together here (before any barrier), avoiding the barrier-skip hang noted
  // near the end of main. Without these guards, non-conforming dimensions
  // silently produce wrong results or out-of-bounds accesses (e.g. an odd N
  // makes the n+=2 unrolled inner loop read one B row past the matrix).
  if ((gemm_l.N % 2u) != 0u)            return -3;  // inner loop unrolls n by 2
  if ((gemm_l.M % active_groups) != 0u) return -4;  // M rows split across groups

  const uint32_t measure_iterations = 1;  // Run matmul once

  uint32_t timer_start, timer_end, timer;

  // Variables to hold my portion of the work
  uint32_t m_start, m_end;  // Rows of C I'll compute
  uint32_t p_start, p_end;  // Columns of C I'll compute
  uint32_t kernel_size;      // 2, 4, or 8 (how many rows per vector operation)

  //========================================================--
  // INITIALIZATION
  //========================================================--
  // Initialize barrier for multicore synchronization
  mempool_barrier_init(cid);

  // Initialize timer to maximum value (will be updated with actual time)
  timer = (uint32_t)-1;

  // Set kernel size - this determines how many rows of C are computed per iteration
  // kernel_size = 8 means we compute 8 rows at a time (using 8 vector registers)
  kernel_size = 8;

  //========================================================--
  // STEP 2: DISTRIBUTE WORK ACROSS CORES
  //========================================================--
  // Divide the M dimension (rows) among groups
  const uint32_t dim_group = gemm_l.M / active_groups;
  
  // Calculate how many cores we have for the M dimension
  const uint32_t split_m_count = dim_group / kernel_size;

  // Uniform across cores (before the work barrier): guard the column-split
  // divisor below. split_m_count==0 (dim_group < kernel_size) would divide by
  // zero at split_p_count; a non-multiple dim_group would mis-cover M rows.
  if ((dim_group % kernel_size) != 0u || split_m_count == 0u) return -6;

  if (split_m_count < cores_per_group) {
    // Not enough rows to keep all cores busy in M dimension
    // Split the P dimension (columns) instead
    const uint32_t split_p_count = cores_per_group / split_m_count;
    
    // Uniform across cores: safe to return here (before the work barrier).
    if ((gemm_l.P % split_p_count) != 0u) return -5;  // P columns split per core

    // My column range in P dimension
    p_start = gemm_l.P / split_p_count * (core_gid % split_p_count);
    p_end   = gemm_l.P / split_p_count * ((core_gid % split_p_count) + 1);
    
    // My row range in M dimension
    m_start = dim_group * gid + kernel_size * (core_gid / split_p_count);
    m_end   = dim_group * gid + kernel_size * (core_gid / split_p_count + 1);
  } else {
    // Enough rows - split primarily in M dimension
    p_start = 0;
    p_end   = gemm_l.P;  // All columns
    
    // Divide rows evenly among cores in this group
    m_start = dim_group * gid + (dim_group / cores_per_group) * core_gid;
    m_end   = dim_group * gid + (dim_group / cores_per_group) * (core_gid + 1);
  }

  // Wait for all cores to finish work distribution
  mempool_barrier(num_cores);

  //========================================================--
  // STEP 3: DATA TRANSFER FROM DRAM TO TCDM
  //========================================================--
  // DMA provides faster data transfer than simple copy loops
  
  #ifdef USE_DMA
  // Core 0 handles all DMA transfers (simplifies synchronization)
  if (cid == 0) {
    // Copy matrices A and B from DRAM to TCDM
    dma_memcpy_blocking(a, gemm_A_dram, (gemm_l.M * gemm_l.N) * sizeof(float));
    dma_memcpy_blocking(b, gemm_B_dram, (gemm_l.N * gemm_l.P) * sizeof(float));
    // Initialize reference checksums
    init_matrix(r, gemm_checksum, 0, 1, gemm_l.M);
  }
  #else
  // Alternative: each core copies a portion (non-DMA version)
  init_matrix(a, gemm_A_dram, cid * (gemm_l.M / active_cores),
              (cid + 1) * (gemm_l.M / active_cores), gemm_l.N);
  init_matrix(b, gemm_B_dram, cid * (gemm_l.N / active_cores),
              (cid + 1) * (gemm_l.N / active_cores), gemm_l.P);
  if (cid == 0) {
    init_matrix(r, gemm_checksum, 0, 1, gemm_l.M);
  }
  #endif

  // Print status message from core 0
  if (cid == 0) {
    printf("finish copy\n");
  }

  // Wait for all cores to finish data transfer
  mempool_barrier(num_cores);

  //========================================================--
  // STEP 4: MATRIX MULTIPLICATION
  //========================================================--
  // Each core computes its portion of C = A * B
  //
  // The kernel dispatches based on kernel_size:
  //   - kernel_size = 2: matmul_2xVL (2 rows at a time)
  //   - kernel_size = 4: matmul_4xVL (4 rows at a time)
  //   - kernel_size = 8: matmul_8xVL (8 rows at a time)
  //
  // Parameters:
  //   c, a, b    : matrices in TCDM
  //   m_start/m_end: my row range
  //   gemm_l.N   : inner dimension (A columns = B rows)
  //   gemm_l.P   : output columns
  //   p_start/p_end: my column range
  //========================================================--
  for (uint32_t i = 0; i < measure_iterations; ++i) {
    if (is_core_active) {
      // Start timer
      timer_start = mempool_get_timer();

      // Start benchmark instrumentation
      if (cid == 0)
        mempool_start_benchmark();

      // Dispatch to appropriate kernel based on kernel_size
      if (kernel_size == 2) {
        matmul_2xVL(c, a, b, m_start, m_end, gemm_l.N, gemm_l.P, p_start, p_end);
      } else if (kernel_size == 4) {
        matmul_4xVL(c, a, b, m_start, m_end, gemm_l.N, gemm_l.P, p_start, p_end);
      } else if (kernel_size == 8) {
        matmul_8xVL(c, a, b, m_start, m_end, gemm_l.N, gemm_l.P, p_start, p_end);
      } else {
        return -2;  // Invalid kernel size
      }

      // Wait for all cores to finish computation
      mempool_barrier(num_cores);

      // Stop benchmark instrumentation
      if (cid == 0)
        mempool_stop_benchmark();

      // Calculate elapsed time
      timer_end = mempool_get_timer();
      uint32_t timer_temp = timer_end - timer_start;
      
      // Core 0 tracks the minimum time (best core)
      if (cid == 0) {
        if (timer_temp < timer) {
          timer = timer_temp;
        }
      }
    }
  }

  //========================================================--
  // STEP 5: PERFORMANCE REPORTING
  //========================================================--
  if (cid == 0) {
    // Calculate performance metrics
    // Operations: 2 * M * N * P (multiply-add for each element)
    long unsigned int performance =
        1000 * 2 * gemm_l.M * gemm_l.P * gemm_l.N / timer;
    
    // Utilization = actual performance / theoretical peak
    long unsigned int utilization = performance / (2 * active_cores * N_FPU);

    printf("\n----- (%dx%d) sp fmatmul -----\n", gemm_l.M, gemm_l.P);
    printf("The execution took %u cycles.\n", timer);
    printf("The performance is %u OP/1000cycle (%u%%o utilization).\n",
           performance, utilization);
  }

  //========================================================--
  // STEP 6: VERIFICATION
  //========================================================--
  // Verify correctness using row-sum checksums
  int error = 0;
  if (cid == 0) {
    error = verify_matrix((float *)c, (const float *)r, gemm_l.M, gemm_l.P);

#ifdef STRICT_VERIFY
    // Optional exhaustive element-wise check against the golden result.
    // Off by default: it reads the full MxP reference from DRAM (slow in RTL
    // simulation), but unlike the row-sum checksum it catches errors that
    // preserve row sums (e.g. a column-block swap or a wrong p_start).
    if (error == 0) {
      for (uint32_t i = 0; i < gemm_l.M && error == 0; ++i) {
        for (uint32_t j = 0; j < gemm_l.P; ++j) {
          float d = c[i * gemm_l.P + j] - gemm_C_dram[i * gemm_l.P + j];
          if (d < 0) d = -d;
          if (d > (float)0.01) {  // 1-based row index, matches verify_matrix
            error = (int)(i) + 1;
            break;
          }
        }
      }
      if (error == 0) printf("strict verify: success!\n");
    }
#endif

    if (error != 0) {
      // error is 1-based; index the checksum array with (error - 1).
      uint32_t bad_row = (uint32_t)error - 1u;
      printf("Error core %d: row=%u checksum[%u]=%u\n", cid, bad_row, bad_row,
             (uint32_t)r[bad_row]);
    } else {
      printf("success!\n");
    }
  }

  // All cores must reach this barrier so the simulation can exit cleanly.
  // Previously, 'return error' in the error path caused core 0 to skip the
  // barrier, leaving 63 cores stuck in WFI and the simulation hanging.
  mempool_barrier(num_cores);

  return error;
}
