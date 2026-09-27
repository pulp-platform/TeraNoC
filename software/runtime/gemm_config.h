// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
#ifndef GEMM_CONFIG_H
#define GEMM_CONFIG_H

// Shared work partition for the FP16/FP32 burst-merge applications. Two
// policies: with GEMM_KS_PREFER_MAX the largest legal kernel wins (maximum
// in-core operand reuse); otherwise legal kernels are ranked by A/B sharing
// imbalance, then burst eligibility, then larger KS. The tie-breaker tests
// potential short-burst eligibility; actual addresses, ROB capacity and tile
// crossings are checked by the runtime tuner. Either way this is a static
// policy, not a measured performance optimum. KERNEL_SIZE defined by the caller
// overrides both.
#if NUM_GROUPS < 1 || NUM_CORES < NUM_GROUPS || NUM_CORES % NUM_GROUPS != 0
#error "GEMM requires an integral, nonempty core count per group"
#endif
#ifndef ACTIVE_GROUP_DIV
#define ACTIVE_GROUP_DIV 1
#endif
#if ACTIVE_GROUP_DIV < 1 || NUM_GROUPS % ACTIVE_GROUP_DIV != 0
#error "ACTIVE_GROUP_DIV must divide NUM_GROUPS"
#endif
#define GEMM_ACTIVE_GROUPS (NUM_GROUPS / ACTIVE_GROUP_DIV)
#define GEMM_ACTIVE_CORES (NUM_CORES / ACTIVE_GROUP_DIV)
#define GEMM_CPG (NUM_CORES / NUM_GROUPS)
#define GEMM_DIV(a, b) ((a) / ((b) ? (b) : 1))
#define GEMM_MOD(a, b) ((a) % ((b) ? (b) : 1))
#define GEMM_MIN(a, b) ((a) < (b) ? (a) : (b))
#define GEMM_ROWS_PER_GROUP (GEMM_M / GEMM_ACTIVE_GROUPS)
#define GEMM_ROW_TILES(k) GEMM_DIV(GEMM_ROWS_PER_GROUP, k)
#define GEMM_PREFILL_PBLOCKS(k) \
  ((GEMM_ROW_TILES(k) < GEMM_CPG) \
    ? GEMM_DIV(GEMM_CPG, GEMM_ROW_TILES(k)) : 1)
#define GEMM_PREFILL_OK(k) \
  (GEMM_KSPLIT == 1 && GEMM_M % GEMM_ACTIVE_GROUPS == 0 && GEMM_ROW_TILES(k) > 0 && \
   GEMM_ROWS_PER_GROUP % (k) == 0 && \
   ((GEMM_ROW_TILES(k) < GEMM_CPG) \
     ? GEMM_MOD(GEMM_CPG, GEMM_ROW_TILES(k)) == 0 \
     : GEMM_ROWS_PER_GROUP % (GEMM_CPG * (k)) == 0) && \
   GEMM_MOD(GEMM_P, GEMM_PREFILL_PBLOCKS(k)) == 0)
#define GEMM_DECODE_ROWS(k) GEMM_DIV(GEMM_M, k)
// K split (decode only): GEMM_KSPLIT cores own the SAME output patch and each takes 1/GEMM_KSPLIT
// of every K tile's rows; their partial sums are added once per projection. It is for shapes where
// B*P/cores is below one register block (KS x VLMAX = 512 fp16), which otherwise run every vector
// at a fraction of its length. The caller reduces the partials. 1 = off, which is every app but
// qwen-gate-up; all the macros below then evaluate exactly as without it.
#ifndef GEMM_KSPLIT
#define GEMM_KSPLIT 1
#endif
#define GEMM_DECODE_PBLOCKS(k) \
  GEMM_DIV(GEMM_ACTIVE_CORES, GEMM_DECODE_ROWS(k) * GEMM_KSPLIT)
// Row chunks ONE GROUP holds in the decode split. The default, the whole group, is
// the original split: row_chunk = cid % n_rows, so a group takes up to GEMM_CPG row
// chunks of a few column blocks. A smaller cap gives each group a squarer
// (row chunks x column blocks) patch instead. With the split group MSHR's 4-tile
// slices, a cap of 4 makes both sharing degrees 4 -- W sharers are one tile row
// (one burst slice), X sharers one tile column (one single slice) -- where
// 8 x 2 at B=64 left X with 2 sharers, below the merge threshold, and W with 8
// straddling two slices. Legacy shapes with n_rows <= cap are unchanged.
#ifndef GEMM_DECODE_RC_PER_GROUP
#define GEMM_DECODE_RC_PER_GROUP GEMM_CPG
#endif
#define GEMM_DECODE_RCG(k) GEMM_MIN(GEMM_DECODE_ROWS(k), GEMM_DECODE_RC_PER_GROUP)
#define GEMM_DECODE_OK(k) \
  (GEMM_M % (k) == 0 && GEMM_DECODE_ROWS(k) > 0 && \
   GEMM_DECODE_ROWS(k) * GEMM_KSPLIT <= GEMM_ACTIVE_CORES && \
   GEMM_MOD(GEMM_ACTIVE_CORES, GEMM_DECODE_ROWS(k) * GEMM_KSPLIT) == 0 && \
   ((GEMM_DECODE_ROWS(k) < GEMM_CPG) \
     ? GEMM_MOD(GEMM_CPG, GEMM_DECODE_ROWS(k)) == 0 \
     : GEMM_DECODE_ROWS(k) % GEMM_CPG == 0) && \
   GEMM_MOD(GEMM_CPG, GEMM_DECODE_RCG(k) * GEMM_KSPLIT) == 0 && \
   GEMM_MOD(GEMM_DECODE_ROWS(k), GEMM_DECODE_RCG(k)) == 0 && \
   GEMM_MOD(GEMM_P, GEMM_DECODE_PBLOCKS(k)) == 0)
#ifdef MATMUL_DECODE_SPLIT
#define GEMM_USE_DECODE(k) MATMUL_DECODE_SPLIT
#else
#define GEMM_USE_DECODE(k) (!GEMM_PREFILL_OK(k))
#endif
#define GEMM_LEGAL(k) \
  (GEMM_P > 0 && GEMM_N > 0 && GEMM_N % 2 == 0 && \
   (GEMM_USE_DECODE(k) ? GEMM_DECODE_OK(k) : GEMM_PREFILL_OK(k)))
#define GEMM_SHARE_B(k) \
  GEMM_MIN(GEMM_CPG, (GEMM_USE_DECODE(k) \
    ? GEMM_DECODE_RCG(k) : GEMM_ROW_TILES(k)))
// A (X) sharers: the group's column blocks at one row chunk AND one K part.
#define GEMM_SHARE_A(k) \
  GEMM_DIV(GEMM_CPG, GEMM_SHARE_B(k) * (GEMM_USE_DECODE(k) ? GEMM_KSPLIT : 1))
#define GEMM_PBLOCKS(k) (GEMM_USE_DECODE(k) \
  ? GEMM_DECODE_PBLOCKS(k) : GEMM_PREFILL_PBLOCKS(k))
#define GEMM_PSPAN(k) GEMM_DIV(GEMM_P, GEMM_PBLOCKS(k))
#define GEMM_LMUL(k) GEMM_MIN(8, 16 / (k))
#define GEMM_LOAD_BYTES(k) \
  GEMM_MIN(VLEN * GEMM_LMUL(k) / 8, GEMM_PSPAN(k) * GEMM_ELEM_BYTES)
#define GEMM_LOAD_WORDS(k) (GEMM_LOAD_BYTES(k) / 4)
#define GEMM_IMBALANCE(k) ((GEMM_SHARE_A(k) > GEMM_SHARE_B(k)) \
  ? GEMM_SHARE_A(k) - GEMM_SHARE_B(k) \
  : GEMM_SHARE_B(k) - GEMM_SHARE_A(k))
#define GEMM_SCORE(k) (GEMM_LEGAL(k) \
  ? 2 * GEMM_IMBALANCE(k) + (GEMM_LOAD_BYTES(k) < 8 || GEMM_LOAD_BYTES(k) % 4 != 0) : 1000000)

#ifndef KERNEL_SIZE
#if defined(GEMM_KS_PREFER_MAX) && GEMM_KS_PREFER_MAX
// Largest legal kernel: keep the operand reuse inside the core instead of asking
// the memory system for it. GEMM_LMUL(k) pins k*LMUL at 16 for k >= 2, so one
// iteration always computes 512 fp16 FMACs while loading only 512/k elements of
// B -- arithmetic intensity is proportional to k. A larger k also lowers
// GEMM_SHARE_B, which takes the group-MSHR merge (and its hold window) off the
// critical path rather than depending on it to deliver the same reuse.
#if GEMM_LEGAL(8)
#define KERNEL_SIZE 8
#elif GEMM_LEGAL(4)
#define KERNEL_SIZE 4
#elif GEMM_LEGAL(2)
#define KERNEL_SIZE 2
#else
#define KERNEL_SIZE 1
#endif
#else
#if GEMM_SCORE(8) <= GEMM_SCORE(4) && \
    GEMM_SCORE(8) <= GEMM_SCORE(2) && GEMM_SCORE(8) <= GEMM_SCORE(1)
#define KERNEL_SIZE 8
#elif GEMM_SCORE(4) <= GEMM_SCORE(2) && GEMM_SCORE(4) <= GEMM_SCORE(1)
#define KERNEL_SIZE 4
#elif GEMM_SCORE(2) <= GEMM_SCORE(1)
#define KERNEL_SIZE 2
#else
#define KERNEL_SIZE 1
#endif
#endif
#endif
#if KERNEL_SIZE != 1 && KERNEL_SIZE != 2 && \
    KERNEL_SIZE != 4 && KERNEL_SIZE != 8
#error "KERNEL_SIZE must be 1, 2, 4 or 8"
#endif
#if !GEMM_LEGAL(KERNEL_SIZE)
#error "No legal GEMM partition for the selected shape, groups and KERNEL_SIZE"
#endif
// Freeze the selected branch before defining MATMUL_DECODE_SPLIT: otherwise
// GEMM_USE_DECODE would recursively refer to it when expanding later macros.
#ifndef MATMUL_DECODE_SPLIT
#if GEMM_PREFILL_OK(KERNEL_SIZE)
#define MATMUL_DECODE_SPLIT 0
#else
#define MATMUL_DECODE_SPLIT 1
#endif
#endif
#define MATMUL_ACTIVE_GROUPS GEMM_ACTIVE_GROUPS
#endif
