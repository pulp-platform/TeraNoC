// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
#ifndef GEMM_CONFIG_H
#define GEMM_CONFIG_H

// Shared work partition for the FP16/FP32 burst-merge applications. Select
// among legal kernels by A/B sharing imbalance, then burst eligibility, then
// larger KS. This is a static policy, not a measured performance optimum.
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
  (GEMM_M % GEMM_ACTIVE_GROUPS == 0 && GEMM_ROW_TILES(k) > 0 && \
   GEMM_ROWS_PER_GROUP % (k) == 0 && \
   ((GEMM_ROW_TILES(k) < GEMM_CPG) \
     ? GEMM_MOD(GEMM_CPG, GEMM_ROW_TILES(k)) == 0 \
     : GEMM_ROWS_PER_GROUP % (GEMM_CPG * (k)) == 0) && \
   GEMM_MOD(GEMM_P, GEMM_PREFILL_PBLOCKS(k)) == 0)
#define GEMM_DECODE_ROWS(k) GEMM_DIV(GEMM_M, k)
#define GEMM_DECODE_PBLOCKS(k) \
  GEMM_DIV(GEMM_ACTIVE_CORES, GEMM_DECODE_ROWS(k))
#define GEMM_DECODE_OK(k) \
  (GEMM_M % (k) == 0 && GEMM_DECODE_ROWS(k) > 0 && \
   GEMM_DECODE_ROWS(k) <= GEMM_ACTIVE_CORES && \
   GEMM_MOD(GEMM_ACTIVE_CORES, GEMM_DECODE_ROWS(k)) == 0 && \
   ((GEMM_DECODE_ROWS(k) < GEMM_CPG) \
     ? GEMM_MOD(GEMM_CPG, GEMM_DECODE_ROWS(k)) == 0 \
     : GEMM_DECODE_ROWS(k) % GEMM_CPG == 0) && \
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
    ? GEMM_DECODE_ROWS(k) : GEMM_ROW_TILES(k)))
#define GEMM_SHARE_A(k) GEMM_DIV(GEMM_CPG, GEMM_SHARE_B(k))
#define GEMM_PBLOCKS(k) (GEMM_USE_DECODE(k) \
  ? GEMM_DECODE_PBLOCKS(k) : GEMM_PREFILL_PBLOCKS(k))
#define GEMM_PSPAN(k) GEMM_DIV(GEMM_P, GEMM_PBLOCKS(k))
#define GEMM_LMUL(k) GEMM_MIN(8, 16 / (k))
#define GEMM_LOAD_WORDS(k) \
  GEMM_MIN(VLEN * GEMM_LMUL(k) / 32, \
           GEMM_PSPAN(k) * GEMM_ELEM_BYTES / 4)
#define GEMM_IMBALANCE(k) ((GEMM_SHARE_A(k) > GEMM_SHARE_B(k)) \
  ? GEMM_SHARE_A(k) - GEMM_SHARE_B(k) \
  : GEMM_SHARE_B(k) - GEMM_SHARE_A(k))
#define GEMM_SCORE(k) (GEMM_LEGAL(k) \
  ? 2 * GEMM_IMBALANCE(k) + (GEMM_LOAD_WORDS(k) < 16) : 1000000)

#ifndef KERNEL_SIZE
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
