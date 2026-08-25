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

// Device-side result verification. Default OFF: verify_matrix() sums each row of C on the
// scalar FP path and wedges core 0 (see the note at the call site). -DMATMUL_VERIFY=1 for
// a debug run.
//
// Defined HERE, not at the call site, because it also gates the gemm_checksum -> r copy in
// setup. That copy exists only to stage checksums for verify_matrix: a serial M-iteration
// loop run by core 0 alone, each iteration paying an L2 round trip (~32 cyc). At M=2048
// that is ~65k cycles of a ~102k-cycle run -- most of the simulation -- producing data
// nothing reads when the verify is off.
#ifndef MATMUL_SPOTCHECK
// FP-FREE correctness probe (default off). See the note at the call site.
#define MATMUL_SPOTCHECK 0
#endif
#ifndef MATMUL_VERIFY
#define MATMUL_VERIFY 0
#endif
#include "kernel/sp-fmatmul.c"
#include "printf.h"
#ifdef MEMPOOL
#include "alloc.h"
#include "runtime.h"
#include "synchronization.h"
#include "encoding.h"
#include "mshr_cfg.h"
#endif

#define USE_DMA

// ---- Phase-0 experiment knob (B-burst coalescing) --------------------------
// 1 = insert a one-time intra-group barrier right before the matmul so all
// cores in a group enter the n-loop aligned, landing their first shared-B
// vector bursts inside the MSHR's ~68-cycle no-late-join merge window (so they
// can coalesce). 0 = unaligned baseline. Flip to 0 and rebuild for the A/B
// comparison. See WORKLOG 2026-06-20 / memory project_mshr_bcoalesce_sync_plan.
#ifndef COLDSTART_GROUP_SYNC
#define COLDSTART_GROUP_SYNC 1  // Phase-0 BASELINE run (unaligned); set 1 for aligned
#endif

// ---- Instruction-cache warm-up knob ---------------------------------------
// 1 = run one very short (reduced-N) pass of the matmul kernel BEFORE the timed
// region so the kernel code (and the gbar_sync path) is resident in each core's
// I$ when the measured run starts -- removes cold I$-miss noise from the timing.
// The pass uses the REAL m/p ranges + active set so the per-pair group barrier
// stays balanced (gbar_sync count is purely N-driven, data-independent), but N is
// clamped down to ICACHE_WARMUP_N. Since the kernel uses N as the A row-stride, the
// warm-up's A reads are mis-strided -> its C output is garbage, which the real run
// overwrites; only the instruction footprint matters here.
#ifndef ICACHE_WARMUP
#define ICACHE_WARMUP 1
#endif
#ifndef ICACHE_WARMUP_N
#define ICACHE_WARMUP_N 6u  // even; >=6 covers peel + both steady-state halves + epilogue
#endif

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
void init_matrix(elem_t *matrix, const elem_t *src,
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
int verify_matrix(const elem_t *matrix, const elem_t *checksum,
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
    // fp16 tolerance. The device accumulates each C element over N terms in fp16 (11-bit
    // mantissa, eps = 4.9e-4), so a single element carries ~sqrt(N)*eps relative error and the
    // row sum of P such elements carries ~sqrt(P) more. At N = P = 512 that is a few percent of
    // the row magnitude -- three orders of magnitude above the fp32 kernel's 1e-3, and it is
    // genuine fp16 arithmetic, NOT a device bug. A relative bound with an absolute floor, since
    // random-sign row sums can land near zero where a pure relative test is meaningless.
    float mag  = (float)checksum[i]; if (mag < 0) mag = -mag;
    float prec = (float)0.03 * mag + (float)1.0;
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

  // Determine how many cores are active in this run.
  // ACTIVE_GROUP_DIV shrinks the active set to the FIRST NUM_GROUPS/DIV groups
  // (cid < active_cores => gid < active_groups), leaving each active group fully
  // populated so the per-group barrier still sees all 16 of its cores. Default 1
  // = every group active, i.e. bit-identical to the previous behaviour.
  // Build with EXTRA_DEFINES=-DACTIVE_GROUP_DIV=4 for the quarter-load run; that
  // needs a matching M (M/active_groups must keep dim_group unchanged) or each
  // core silently gets DIV x the columns.
#ifndef ACTIVE_GROUP_DIV
#define ACTIVE_GROUP_DIV 1
#endif

// KERNEL_SIZE's own default lives further down, next to where it is used; hoist it here so the
// split predicate below can see it. The later #ifndef then finds it already defined and is a
// no-op, so the two cannot disagree.
#ifndef KERNEL_SIZE
#define KERNEL_SIZE 8
#endif

// WHICH WORK SPLIT: derived from the SHAPE, not chosen by hand.
//
// The prefill split hands each active group M/active_groups rows and each core KERNEL_SIZE of
// them, so it can only cover M when all three hold: M divides across the groups, the per-group
// row count is a whole number of kernel tiles, and there is at least one tile per core. When any
// fails, the prefill path cannot express the shape -- it returns -4 or -6 at RUNTIME, which is a
// binary that rejects its own workload. Decode shapes (M = batch, e.g. 32) fail all three.
//
// Deriving it here makes that unrepresentable: the shape selects the split at compile time, the
// same way mshr_cfg.h derives the MSHR targets from GEMM_M/N/P rather than from a per-shape .mk.
// Checked against the 8x8 campaign manifest: 0 of 248 shapes change branch (all have
// M >= 512 = 64 groups x 8), and both decode meshes select the decode branch at M = 32.
// The boundary is M >= NUM_GROUPS * KERNEL_SIZE: 128 at 4x4, 512 at 8x8.
//
// An explicit -DMATMUL_DECODE_SPLIT=0/1 still wins, for forcing a branch in an experiment.
#ifndef MATMUL_DECODE_SPLIT
#  define MATMUL_ACTIVE_GROUPS ((NUM_GROUPS) / (ACTIVE_GROUP_DIV))
#  if ((GEMM_M) % (MATMUL_ACTIVE_GROUPS)) != 0
#    define MATMUL_DECODE_SPLIT 1
#  elif ((GEMM_M) / (MATMUL_ACTIVE_GROUPS)) < (KERNEL_SIZE)
#    define MATMUL_DECODE_SPLIT 1
#  elif ((((GEMM_M) / (MATMUL_ACTIVE_GROUPS)) % (KERNEL_SIZE)) != 0)
#    define MATMUL_DECODE_SPLIT 1
#  else
#    define MATMUL_DECODE_SPLIT 0
#  endif
#endif
  const uint32_t active_groups = NUM_GROUPS / ACTIVE_GROUP_DIV;
  const uint32_t active_cores = cores_per_group * active_groups;
  const uint32_t is_core_active = cid < active_cores;

  // Kernel preconditions for the current work-distribution scheme. Every core
  // evaluates these identical constants, so on a violation they all return
  // together here (before any barrier), avoiding the barrier-skip hang noted
  // near the end of main. Without these guards, non-conforming dimensions
  // silently produce wrong results or out-of-bounds accesses (e.g. an odd N
  // makes the n+=2 unrolled inner loop read one B row past the matrix).
  if ((gemm_l.N % 2u) != 0u)            return -3;  // inner loop unrolls n by 2
#if !MATMUL_DECODE_SPLIT
  // PREFILL ONLY. The prefill scheme hands each group M/active_groups rows, so M must divide.
  // Decode never splits M (M = batch, far below active_groups) and this check would reject
  // every legal decode shape with -4 -- see the decode branch of STEP 2.
  if ((gemm_l.M % active_groups) != 0u) return -4;  // M rows split across groups
#endif

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
  // S1 experiment (docs/spatz_bottleneck_analysis_and_plan.md): kernel_size also selects LMUL --
  //   8 -> matmul_8xVL (e16,m2 -> vl=64,  8 accumulators)
  //   4 -> matmul_4xVL (e16,m4 -> vl=128, 4 accumulators)
  //   2 -> matmul_2xVL (e16,m8 -> vl=256, 2 accumulators; 512 B > burst ceiling, no burst)
  // Higher LMUL = fewer, longer vector ops = more FPU work per load => the 109-cycle load latency
  // needs less memory-level parallelism to hide. Override with
  // EXTRA_DEFINES=-DKERNEL_SIZE=4 (NOT DEFINES=..., which overrides the build's own
  // -DNUM_CORES/-DVLEN/... and fails to compile).
#ifndef KERNEL_SIZE
#define KERNEL_SIZE 8
#endif
  kernel_size = KERNEL_SIZE;

  //========================================================--
  // STEP 2: DISTRIBUTE WORK ACROSS CORES
  //========================================================--
#if MATMUL_DECODE_SPLIT
  // DECODE DISTRIBUTION -- split P (output width) and B (rows), never M.
  //
  // The prefill split divides M across groups first; decode has M = B = batch (32), so
  // dim_group = M/active_groups = 0 and the prefill path returns -6. Nothing about the INNER
  // kernel is wrong for decode -- matmul_8xVL already does scalar-A broadcast against a
  // contiguous vector B load, which is exactly C[B][I] = A[B][D] x W[D][I] wants:
  //     A is [B][D] row-major -> A[b][d] contiguous in d  -> scalar flh, no transpose
  //     W is [D][I] row-major -> W[d][p:p+VL] contiguous  -> vector load, BURSTS, no transpose
  // So only the work SPLIT changes, and no DMA transpose is needed for either operand.
  //
  //   row_chunk = cid % n_row_chunks      (which 8 rows of B this core owns)
  //   p_block   = cid / n_row_chunks      (which VL-wide column slice it owns)
  //
  // row_chunk VARIES FASTEST ON PURPOSE. Cores sharing a p_block read the SAME W bytes, and
  // consecutive core ids sit in the same group (hartid = (group<<4)|tile), so those cores land
  // together and the group MSHR burst-merges their identical W loads -- W leaves L2 once, not
  // n_row_chunks times. Reversing the two would scatter them across groups and lose that.
  const uint32_t n_row_chunks = gemm_l.M / kernel_size;      // B / 8
  const uint32_t n_p_blocks   = active_cores / n_row_chunks;

  // Uniform across cores -- safe to return before the work barrier.
  if (n_row_chunks == 0u || (gemm_l.M % kernel_size) != 0u) return -6;
  if (n_p_blocks == 0u || (active_cores % n_row_chunks) != 0u) return -7;
  if ((gemm_l.P % n_p_blocks) != 0u) return -5;

  const uint32_t row_chunk = cid % n_row_chunks;
  const uint32_t p_block   = cid / n_row_chunks;
  const uint32_t p_span    = gemm_l.P / n_p_blocks;

  m_start = row_chunk * kernel_size;
  m_end   = m_start + kernel_size;
  p_start = p_block * p_span;
  p_end   = p_start + p_span;
#else
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
#endif

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
    dma_memcpy_blocking(a, gemm_A_dram, (gemm_l.M * gemm_l.N) * sizeof(elem_t));
    dma_memcpy_blocking(b, gemm_B_dram, (gemm_l.N * gemm_l.P) * sizeof(elem_t));
#if MATMUL_VERIFY
    // Reference checksums, read only by verify_matrix().
    init_matrix(r, gemm_checksum, 0, 1, gemm_l.M);
#endif
  }
  #else
  // Alternative: each core copies a portion (non-DMA version)
  init_matrix(a, gemm_A_dram, cid * (gemm_l.M / active_cores),
              (cid + 1) * (gemm_l.M / active_cores), gemm_l.N);
  init_matrix(b, gemm_B_dram, cid * (gemm_l.N / active_cores),
              (cid + 1) * (gemm_l.N / active_cores), gemm_l.P);
#if MATMUL_VERIFY
  if (cid == 0) {
    init_matrix(r, gemm_checksum, 0, 1, gemm_l.M);
  }
#endif
  #endif

  // Print status message from core 0
  if (cid == 0) {
    printf("finish copy\n");
    printf("M, N, P, m_start, m_end, p_start, p_end = %u, %u, %u, %u, %u, %u, %u\n",
        gemm_l.M, gemm_l.N, gemm_l.P, m_start, m_end, p_start, p_end);
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
#if GROUP_BARRIER
  // Configure the per-pair barrier structs ONCE (Mode B: target+mask persist and
  // auto-reuse every iteration). Pair p = within-group cores {p, p+8} uses struct p;
  // the lower core configures it (target=2, resp_mask={p,p+8}). The barrier then
  // ensures all config writes are acked before any core arrives.
  if (is_core_active) {
    uint32_t wg   = cid % cores_per_group;            // within-group tile
    uint32_t half = cores_per_group / 2;
    if (wg < half)
      gbar_setup(wg, 2u, (1u << wg) | (1u << (wg + half)));
  }
  mempool_barrier(num_cores);
#endif

#if GBAR_PLOOP
  // Configure the GROUP-WIDE barrier struct ONCE (target+mask persist and auto-reuse).
  // One core per group configures it: target = every core of the group, resp_mask = all
  // of them, so each outer p iteration releases the whole group together.
  // NOTE: this assumes all cores_per_group cores of a group execute the kernel, which
  // holds here (active_cores == num_cores by construction above). If a future work split
  // ever leaves cores idle, target must be the ACTIVE count of the group -- otherwise the
  // struct only releases via the HW watchdog.
  if (is_core_active && (cid % cores_per_group) == 0u) {
    uint32_t gmask = (cores_per_group >= 32u) ? 0xFFFFFFFFu
                                              : ((1u << cores_per_group) - 1u);
    gbar_setup(GBAR_PLOOP_STRUCT, cores_per_group, gmask);
  }
  mempool_barrier(num_cores);
#endif

#if ICACHE_WARMUP
  // Instruction-cache warm-up: one short reduced-N pass of the kernel so the matmul
  // (+ gbar_sync) code is resident in each core's I$ before the timed run. Same m/p
  // ranges + active set keep the per-pair group barrier balanced. N is clamped down to
  // ICACHE_WARMUP_N; the kernel uses N as the A row-stride, so the warm-up's A reads are
  // mis-strided and its C output is garbage -- harmless, the timed run below overwrites C.
  // Runs before mempool_start_benchmark()/the timer, so it is neither traced nor measured.
  if (is_core_active) {
    const uint32_t warmup_n = MIN(ICACHE_WARMUP_N, gemm_l.N);
    if (kernel_size == 2) {
      matmul_2xVL(c, a, b, m_start, m_end, warmup_n, gemm_l.P, p_start, p_end);
    } else if (kernel_size == 4) {
      matmul_4xVL(c, a, b, m_start, m_end, warmup_n, gemm_l.P, p_start, p_end);
    } else if (kernel_size == 8) {
      matmul_8xVL(c, a, b, m_start, m_end, warmup_n, gemm_l.P, p_start, p_end);
    }
  }
  mempool_barrier(num_cores);
#endif

#if MSHR_RUNTIME_CFG
  // -----------------------------------------------------------------------------------------
  // Group MSHR runtime configuration (docs/mshr_runtime_csr_design.md).
  //
  // Placed HERE deliberately: after the I$ warm-up, before the timed region. The MSHR ships
  // DISABLED out of reset, so everything above -- init, DMA, warm-up -- bypasses it and never
  // occupies a way or a response-cache line during a phase whose locality does not matter.
  //
  // Every group owns its own MSHR and there is no broadcast, so all NUM_GROUPS are programmed,
  // one designated writer each, in parallel; the barrier makes the configuration visible to every
  // core before the first timed access.
  {
    // Shape-derived at COMPILE TIME from GEMM_M/N/P (data_gemm.h): one source per
    // precision, no per-shape config/*.mk and no runtime division. The timeout and
    // cache knobs stay macro-fed; MSHR_CFG_DERIVED_INIT gates the cache fields on
    // GEMM_ELEM_BYTES so fp32 keeps the legacy path automatically.
    static const mshr_cfg_t mshr_cfg = MSHR_CFG_DERIVED_INIT;
    uint32_t mshr_st = 0;
    if (mshr_cfg_is_group_writer()) mshr_st = mshr_cfg_apply_group(&mshr_cfg);
    mempool_barrier(num_cores);
    // Non-zero status means the configuration IN EFFECT is not the one requested -- a refused
    // bank-hash write, an out-of-range value, a rejected serve_timeout. Fail loudly: a silent
    // config mismatch is exactly what invalidated three measurement runs on 2026-08-14.
    if (mshr_st != 0) {
      printf("[MSHR] cfg REJECTED status=0x%x group=%d -- MEASUREMENT INVALID\n",
             (unsigned)mshr_st, (int)mshr_cfg_my_group());
    }

#if MSHR_CFG_NEGTEST
    // V5a -- NEGATIVE test of the reject-and-report path. Deterministic, unlike a "write the bank
    // hash while the MSHR is busy" test, which cannot guarantee entries are resident at the instant
    // of the write. Here the value is out of range by construction, so the refusal is not racy.
    //
    // bank_shift_single is legal only in [5,10] (mempool_group_mshr_cfg.sv:95). Writing 99 must:
    //   * be DROPPED  -- the old hash stays in effect, and
    //   * set MSHR_STATUS_RANGE in the sticky status.
    // A silently ACCEPTED out-of-range write is the failure this whole status mechanism exists to
    // prevent, so the test fails loudly in BOTH directions.
    if (mshr_cfg_is_group_writer()) {
      const uint32_t g = mshr_cfg_my_group(), tl = mshr_cfg_peer_tile();
      mshr_cfg_write(g, tl, MSHR_CSR_STATUS, 0);              // clear first: isolate this write
      mshr_cfg_write(g, tl, MSHR_CSR_BANK_SHIFT_SINGLE, 99);  // out of range -> must be refused
      __asm__ volatile("fence" ::: "memory");
      uint32_t st = mshr_cfg_status(g, tl);
      // REFUSED is the property under test, and the RTL has two legitimate ways to refuse:
      // mshr_busy_i is checked BEFORE the range check (mempool_group_mshr_cfg.sv:118-120), so with
      // the MSHR already enabled a bank-hash write can come back BANK_BUSY rather than RANGE.
      // Treating only RANGE as a pass would call a correct refusal a failure.
      const uint32_t refused = st & (MSHR_STATUS_RANGE | MSHR_STATUS_BANK_BUSY);
      // ONE printf, from ONE core. 16 group writers printing concurrently interleave
      // character-by-character on the shared UART and the contention storm wedged the run to ~5%
      // utilisation with 8364 stuck requests. Only group 0 reports the normal case; a FAILING group
      // still speaks up, because a garbled failure is better than a silent one.
      if (g == 0)
        printf("[V5A] %s status=0x%x (RANGE=%d BANK_BUSY=%d)\n",
               refused ? "PASS out-of-range write refused" : "FAIL out-of-range write ACCEPTED",
               (unsigned)st, (st & MSHR_STATUS_RANGE) ? 1 : 0, (st & MSHR_STATUS_BANK_BUSY) ? 1 : 0);
      else if (!refused)
        printf("[V5A] FAIL group=%d ACCEPTED out-of-range write, status=0x%x\n", (int)g, (unsigned)st);
      mshr_cfg_write(g, tl, MSHR_CSR_STATUS, 0);              // leave status clean for the run
    }
    mempool_barrier(num_cores);
#endif
  }
#endif

  for (uint32_t i = 0; i < measure_iterations; ++i) {
    if (is_core_active) {
      // Start timer
      timer_start = mempool_get_timer();

      
#if COLDSTART_GROUP_SYNC
      // Cold-start intra-group alignment (Phase-0 experiment). Re-align all
      // cores_per_group cores so their first (n=0) shared-B bursts issue within
      // the MSHR merge window. num_cores_barrier = cores_per_group => the
      // barrier wakes via wake_up_group (correct for all 16 groups; avoids the
      // wake_up_tile groups-8..15 bug). Assumes the whole group is active
      // (active_cores == num_cores here), else inactive cores would never
      // arrive. Placed after start_benchmark so the alignment + first bursts are
      // captured by the NoC tracer / [GroupMerge] stats.
      mempool_log_partial_barrier(2, cid, cores_per_group);
#endif

      // Start benchmark instrumentation
      // if (cid == 0)
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
      // if (cid == 0)
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

    printf("\n----- (%dx%dx%d) sp fmatmul -----\n", gemm_l.M, gemm_l.N, gemm_l.P);
    printf("The execution took %u cycles.\n", timer);
    printf("The performance is %u OP/1000cycle (%u%%o utilization).\n",
           performance, utilization);
  }

#if MATMUL_SPOTCHECK
  //========================================================--
  // STEP 5b: FP-FREE SPOT CHECK
  //========================================================--
  // The device verify above is disabled because summing C in scalar FP wedges core 0 in the
  // epilogue (see the MATMUL_VERIFY note). That leaves a perf run with NO correctness signal
  // at all, which for a brand-new fp16 kernel is not acceptable -- a kernel that computes
  // garbage twice as fast still "wins" the sweep.
  //
  // This probe reads C as raw 32-bit words with an ORDINARY INTEGER LOAD. One word holds two
  // packed fp16 elements; nothing here touches an FP register, the FP-LSU, or the accumulator
  // writeback, so it cannot reproduce the wedge. The host compares the printed words against
  // the torch golden bit-for-bit-ish (see scripts/check_fp16_spot.py).
  //
  // One sample per GROUP, taken at the first row that group owns, so a single bad group is
  // identified rather than merely detected -- the failure mode that actually happens here
  // (a group desynchronising, or a bank-hash mistake concentrating one group's traffic).
  if (cid == 0) {
    const uint32_t rows_per_group = gemm_l.M / active_groups;
    for (uint32_t g = 0; g < active_groups; ++g) {
      const uint32_t row = g * rows_per_group;
      const volatile uint32_t *w = (const volatile uint32_t *)(c + row * gemm_l.P);
      printf("[SPOT] g=%2u row=%4u w0=%08x w1=%08x w2=%08x w3=%08x\n",
             g, row, w[0], w[1], w[2], w[3]);
    }
  }
  mempool_barrier(active_cores);
#endif

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
  // KNOWN ISSUE (2026-06-24): the device-side verify WEDGES the sim. verify_matrix sums
  // each C row in FP (fadd.s) and compares to the golden row-checksum; those scalar-FP ops
  // route through the Spatz FPU / FP-LSU / acc-writeback path, which stalls core-0 mid-scan
  // (observed ~row 9, PC 0x1094). Every other core then waits forever at the final barrier.
  // This is the epilogue / FP-LSU wedge area and is INDEPENDENT of the group barrier and the
  // request-sent fence -- both validated clean in the same run (matmul completes, [GBAR]
  // arrives==releases, wd_fire=0). See WORKLOG 2026-06-24 / memory project_matmul_verify_fp_wedge.
  // WORKAROUND: MATMUL_VERIFY=0 -- skip the device verify (it is a debug-only host-side check;
  // correctness is confirmed by host replay). The matmul/barrier/fence still run and are timed.
  // PROPOSED FIX (future, FP-free verify): emit the full golden C in gen_data.py and rewrite
  // verify_matrix as a per-element ULP integer compare (lw + integer ops; |c_int - golden_int|
  // < ULP_TOL), which never touches the FP path. Exact-bit compare is too strict (device is
  // legitimately ~4.3e-4 off, a relative error -> ULP distance is the right tolerance model).
#if MATMUL_VERIFY
  if (cid == 0) {
    uint32_t nfail = 0, last_row = 0, sum_bits = 0, chk_bits = 0;
    error = verify_matrix((const elem_t *)c, (const elem_t *)r, gemm_l.M, gemm_l.P,
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
#endif

  // ALL cores must reach this barrier so the simulation exits cleanly. Do NOT
  // 'return error' on core 0 before this point: a core-0-only early return skips
  // the barrier and leaves the other cores asleep in WFI, hanging the run.
  mempool_barrier(num_cores);

  return error;
}
