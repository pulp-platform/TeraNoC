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
// Reinterpret a float's bits as uint32 WITHOUT an fmv.x.w (FP->int register
// move). On this core the FP-sequencer's writeback for an fmv.x.w comes back
// with acc_pwrite=0, which the compiled Snitch arbiter never acknowledges --
// so the destination integer register's scoreboard bit stays set and the next
// instruction that reads it (e.g. the printf's `sw aN,off(sp)`) stalls forever.
// Forcing the round-trip through a volatile memory slot lowers to fsw + lw
// (an FP store has no writeback, an integer load needs no FP unit), sidestepping
// that hang. Used only on the error/report path.
static inline uint32_t f32_to_bits(float f) {
  volatile uint32_t slot;
  *(volatile float *)&slot = f;  // fsw: FP store, no acc writeback
  return slot;                   // lw : integer load, no fmv.x.w
}

// Verify C against the precomputed row checksums and REPORT the failure pattern
// (count + first/last failing row), not just the first mismatch. Whether the
// failing rows are all-256 (systematic), a contiguous block (a specific group's
// cores), or scattered (localized) is the key signal for diagnosing a device-side
// wrong result. Returns the first failing row 1-based (0 == all match), and fills
// the out-params for the report. A correct float32 A*B passes this with margin
// (host replay: worst |row-sum - checksum| = 4.3e-4 << prec=1e-3), so a failure
// here is a genuinely wrong device result, not float rounding.
int verify_matrix(float *matrix, const float *checksum,
                 const uint32_t num_rows, const uint32_t num_columns,
                 uint32_t *nfail_out, uint32_t *last_row_out,
                 uint32_t *first_sum_bits, uint32_t *first_chk_bits) {
  uint32_t nfail = 0, last = 0;
  int first = 0;
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
      // Checksum mismatch. Record the row (1-based so 0 == success and the
      // caller can index the checksum array safely) but DO NOT early-return:
      // keep scanning so we can report how many / which rows are wrong.
      if (first == 0) {
        first = (int)(i) + 1;
        *first_sum_bits = f32_to_bits(sum);                  // fsw+lw, no fmv
        *first_chk_bits = *(volatile uint32_t *)&checksum[i];// plain lw, no flw
      }
      last = i;
      nfail++;
    }
  }
  *nfail_out = nfail;
  *last_row_out = last;
  return first;  // 0 == all checksums matched
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
  // STEP 6: VERIFICATION  (same self-test as sp-fmatmul-opt)
  //========================================================--
  // Core 0 runs verify_matrix(): for each of the M rows it sums c[i][0..P-1] and
  // compares to the precomputed row checksum r[i] (= gemm_checksum, host-verified)
  // with an absolute tolerance of 0.001 -- exactly the sp-fmatmul-opt self-test.
  // Why this avoids the earlier stack overflow: verify_matrix uses only scalar
  // locals (sum/diff/prec); it does NOT recompute the product into a per-row
  // buffer, so nothing large lands on the 512 B per-core stack. It also performs
  // no fp DIVISION (this config is nofdiv / XDIVSQRT=0 -- fdiv.s traps as illegal).
  // (Note: result = alpha*C + A*B with alpha=0, so the true result is plain A*B
  // and gemm_checksum holds the true row sums; gemm_C_dram is the random
  // accumulate-INIT matrix, NOT a golden -- do not compare against it.)
  // verify_matrix returns 0 on success or (failing_row + 1) on the first bad row.
  int error = 0;
  if (cid == 0) {
    uint32_t nfail = 0, last_row = 0, sum_bits = 0, chk_bits = 0;
    error = verify_matrix((float *)c, (const float *)r, gemm_l.M, gemm_l.P,
                          &nfail, &last_row, &sum_bits, &chk_bits);
    if (error != 0) {
      // Integer-only args (the bit patterns came back via fsw+lw, never an
      // fmv.x.w) so this report path cannot deadlock the way the old
      // `0x%08x` of a float did. The first/last/count triple classifies the
      // failure: nfail==M => systematic; last-first+1==nfail => one contiguous
      // block (a specific group's rows); otherwise scattered.
      printf("FAIL: %u/%u rows mismatch; first row %d, last row %u\n",
             nfail, gemm_l.M, error - 1, last_row);
      printf("      row %d: device sum=0x%08x  expected checksum=0x%08x\n",
             error - 1, sum_bits, chk_bits);
    } else {
      printf("success!\n");
    }
  }

  // ALL cores must reach this barrier so the simulation exits cleanly. Do NOT
  // 'return error' on core 0 before this point: a core-0-only early return skips
  // the barrier and leaves the other cores asleep in WFI, hanging the run.
  mempool_barrier(num_cores);

  return error;
}
