// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
//==============================================================================
// Qwen3.8-27B gated-attention decode step: the attention core (flash-decoding).
//==============================================================================
//
// docs/qwen3_8_27b/mixer_plan.md, D2. Per sequence b and KV head g (4), 6 query heads h share
// the head's K and V cache (GQA), head dim 256, history S tokens:
//
//     score[h][t] = q_h . K[t] / 16 ;  p = softmax_t(score) ;  ctx_h = sum_t p[h][t] V[t]
//
// A PROBLEM is one (b, g). Its history is cut into 32-token blocks; when there are fewer problems
// than cores, a problem's blocks are split across ATT_CPP consecutive cores ("split-S"), each
// keeping an online-softmax partial (running max m and sum l in fp32 -- D7 -- and the fp16
// accumulator), and the partials are combined in a pairwise tree at the end.
//
// Layouts, all in the core's own 64-byte tile slots (qc_layout.h):
//   K block: TRANSPOSED, row d (256) = the block's 32 tokens -> scores are vfmacc.vf over tokens
//            with q[h][d] scalars, no reductions (6 accumulators, one per query head);
//   V block: row-major in 8 slices of 32 dims, slot (slice * 32 + token) -> the PV product is
//            vfmacc.vf over 32 dims with p[h][t] scalars.
// One round = one block per core = two 256-sweep tiles (K, then V; 4 MiB each at 4x4). The cache
// is in L2 in exactly this order, so each tile is one contiguous DMA; L1 holds two buffers (K
// in 0, V in 1) and the DMA loads the next tile while the cores work on the current one. The
// cluster DMA takes one transfer at a time; core 0 waits for it before each sub-round barrier.
//
// ATT_CHECK=1: an exact pattern (selected tokens score 0, the others -18.75 -> p is exactly 1 or
// 0; V is 0/1) -- every value on the way is exact in fp16, every problem's context is 0.5 or 0.
//
//==============================================================================

#include <stdint.h>

#if defined(ATT_CHECK) && ATT_CHECK
#define QC_EXP_FAKE 0  // the exact check needs real exponentials
#endif
#include "../qwen-common/qc_attn.h"  // constants (the kernel below, once QC_ATT_RES is set)
#include "../qwen-common/qc_layout.h"
#include "../qwen-common/qc_sync.h"
#include "../qwen-common/qc_vec.h"
#include "dma.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#ifndef ATT_B
#define ATT_B 1  // decode batch
#endif
#ifndef ATT_S
#define ATT_S 2048  // history length
#endif
#ifndef ATT_CHECK
#define ATT_CHECK 0
#endif

#define ATT_KVH QC_ATT_KVH
#define ATT_QPK QC_ATT_QPK
#define ATT_D QC_ATT_D
#define ATT_TB QC_ATT_TB
#define ATT_NSL QC_ATT_NSL
#define ATT_TILE_B QC_ATT_TILE_B
#define ATT_NPRB (ATT_KVH * ATT_B)    // problems
#define ATT_NBP (ATT_S / ATT_TB)      // blocks per problem
#define ATT_MAX(a, b) ((a) > (b) ? (a) : (b))
#define ATT_MIN(a, b) ((a) < (b) ? (a) : (b))
#define ATT_CPP ATT_MIN(ATT_MAX(1u, NUM_CORES / ATT_NPRB), ATT_NBP)  // cores per problem
#define ATT_PPC ATT_MAX(1u, ATT_NPRB / NUM_CORES)                   // problems per core
#define ATT_ACTIVE ATT_MIN(NUM_CORES, ATT_NPRB * ATT_CPP)
#define ATT_RPP (ATT_NBP / ATT_CPP)   // rounds per problem part
#define ATT_T (ATT_PPC * ATT_RPP)     // rounds

_Static_assert((ATT_S % ATT_TB) == 0, "S must be a whole number of 32-token blocks");
_Static_assert((ATT_NBP % ATT_CPP) == 0, "a problem's blocks must split evenly across its cores");
_Static_assert((ATT_CPP & (ATT_CPP - 1u)) == 0, "cores per problem: a power of two");
_Static_assert(ATT_NPRB <= NUM_CORES || (ATT_NPRB % NUM_CORES) == 0, "problems per core: whole");

// Resident per-core area (sweeps of this core's slots): q, the kernel's own (qc_attn.h), ctx.
#define RES_Q 0u                         // q[p][h][d]: slot (p * 6 + h) * 8 + d / 32
#define RES_K0 (RES_Q + ATT_PPC * 48u)   // qc_attn.h's QC_ATT_SW sweeps
#define RES_OUT (RES_K0 + QC_ATT_SW)     // ctx[p][h][d]: slot (p * 6 + h) * 8 + d / 32
#define RES_SW (RES_OUT + ATT_PPC * 48u)

static uint8_t att_buf[2 * ATT_TILE_B] QC_L1_SWEEP;  // K tile in 0, V tile in 1
static uint8_t att_res[RES_SW * QC_SWEEP_B] QC_L1_SWEEP;
#define QC_ATT_RES att_res
#define QC_ATT_K0 RES_K0
#include "../qwen-common/qc_attn.h"

static uint8_t att_kv_l2[ATT_T * 2u * ATT_TILE_B] __attribute__((section(".l2_bss"), aligned(4096)));

static inline uint8_t *res(uint32_t sw, uint32_t cid) { return qc_att_res(sw, cid); }

typedef struct {
  uint32_t b, g, blk;  // problem (sequence, KV head) and global block index within it
} att_id_t;
static inline att_id_t att_id(uint32_t cid, uint32_t r) {
  att_id_t d;
  const uint32_t p = (cid / ATT_CPP) + (r / ATT_RPP) * (NUM_CORES / ATT_CPP);
  d.b = p / ATT_KVH;
  d.g = p % ATT_KVH;
  d.blk = (cid % ATT_CPP) * ATT_RPP + r % ATT_RPP;
  return d;
}

//==============================================================================
// Pattern: q one-hot at dim dh(h) = 7h + g; K[t][dh(h)] = 0 if (t + h) % 4 == 0 else -300;
// V[t][d] = 1 if (t + d + g + b) % 8 == 0. -> ctx[h][d] = 0.5 if (d + g + b - h) % 4 == 0, else 0.
//==============================================================================

static inline uint32_t att_dh(uint32_t h, uint32_t g) { return 7u * h + g; }

// Write vector `v` (one of the prepared pattern registers) to slot `sw` of tile `base`.
#define ATT_PUT(REG, PTR) __asm__ volatile("vse16.v " REG ", (%0)" ::"r"(PTR) : "memory")

#if ATT_CHECK
static uint16_t att_scratch[NUM_CORES][16][ATT_TB] __attribute__((section(".l1_prio")));
// K tile (rows d) and V tile of this core's block in round r, into the L1 staging buffers.
static void att_init_block(uint32_t cid, uint32_t r) {
  const att_id_t d = att_id(cid, r);
  const uint32_t t0 = d.blk * ATT_TB;
  uint16_t(*sc)[ATT_TB] = att_scratch[cid];
  // rows 0..3: K at dh(h) by (t0 + h) % 4 == 0 -> phase (h % 4); rows 4..11: V by rotation;
  // rows 12..14: other K rows, (d + t) % 3 - 1.
  for (uint32_t j = 0; j < ATT_TB; ++j) {
    for (uint32_t ph = 0; ph < 4u; ++ph) sc[ph][j] = ((j + ph) % 4u == 0u) ? 0x0000u : 0xdcb0u;  // -300
    for (uint32_t rt = 0; rt < 8u; ++rt) sc[4 + rt][j] = ((j + rt) % 8u == 0u) ? 0x3c00u : 0u;
    for (uint32_t rt = 0; rt < 3u; ++rt) {
      const int32_t v = (int32_t)((j + rt) % 3u) - 1;
      sc[12 + rt][j] = v == 0 ? 0u : (v > 0 ? 0x3c00u : 0xbc00u);
    }
  }
  __asm__ volatile("fence" ::: "memory");
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(ATT_TB));
  // Rows of K: dh(h) rows use phase (t0 + h) % 4 == h % 4 (t0 is a multiple of 32).
  for (uint32_t row = 0; row < ATT_D; ++row) {
    uint32_t pick = 12u + (row + t0) % 3u;
    for (uint32_t h = 0; h < ATT_QPK; ++h)
      if (row == att_dh(h, d.g)) pick = h % 4u;
    __asm__ volatile("vle16.v v8, (%0)" ::"r"(sc[pick]) : "memory");
    ATT_PUT("v8", qc_slot(att_buf, row, cid));
  }
  // V slot (s * 32 + t): dims s*32 .. s*32+31 of token t0 + t: rotation (t0 + t + s*32 + g + b) % 8.
  for (uint32_t s = 0; s < ATT_NSL; ++s)
    for (uint32_t t = 0; t < ATT_TB; ++t) {
      const uint32_t rt = (t0 + t + s * 32u + d.g + d.b) % 8u;
      __asm__ volatile("vle16.v v8, (%0)" ::"r"(sc[4 + rt]) : "memory");
      ATT_PUT("v8", (uint8_t *)qc_slot(att_buf, s * ATT_TB + t, cid) + ATT_TILE_B);
    }
  __asm__ volatile("fence" ::: "memory");
}
#endif

static void att_init_q(uint32_t cid) {
  // q for each problem this core handles: one-hot at dh(h) (perf builds use the same pattern).
  for (uint32_t qp = 0; qp < ATT_PPC; ++qp) {
    const att_id_t d = att_id(cid, qp * ATT_RPP);
    for (uint32_t h = 0; h < ATT_QPK; ++h)
      for (uint32_t dd = 0; dd < ATT_D; ++dd)
        ((uint16_t *)res(RES_Q + (qp * 6u + h) * 8u + dd / 32u, cid))[dd % 32u] =
            dd == att_dh(h, d.g) ? 0x3c00u : 0u;
  }
}

#if ATT_CHECK
static uint32_t att_bad[NUM_CORES];
typedef struct {
  uint32_t b, g, h, d;
  uint16_t got, want;
} att_miss_t;
static att_miss_t att_first[NUM_CORES];
#endif

int main(void) {
  const uint32_t cid = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  mempool_barrier_init(cid);
  qc_sync_init(cid);
  mempool_barrier(num_cores);
  qc_rne();
  const uint32_t active = cid < ATT_ACTIVE;

  // ---- setup ----------------------------------------------------------------------------------
  if (active) {
    att_init_q(cid);
    qc_att_setup(cid);
  }
#if ATT_CHECK
  for (uint32_t r = 0; r < ATT_T; ++r) {
    if (active) att_init_block(cid, r);
    qc_barrier(cid);
    if (cid == 0) {
      dma_memcpy_blocking(att_kv_l2 + (2u * r) * ATT_TILE_B, att_buf, ATT_TILE_B);
      dma_memcpy_blocking(att_kv_l2 + (2u * r + 1u) * ATT_TILE_B, att_buf + ATT_TILE_B, ATT_TILE_B);
    }
    qc_barrier(cid);
  }
#endif
  qc_barrier(cid);

  // ---- the attention core ----------------------------------------------------------------------
  // Tiles in order K(0), V(0), K(1), ...: tile i is in buffer i & 1, and the DMA brings tile i+1
  // while the cores work on tile i.
  const uint32_t t0 = mempool_get_timer();
  mempool_start_benchmark();
  if (cid == 0) dma_memcpy_blocking(att_buf, att_kv_l2, ATT_TILE_B);
  qc_barrier(cid);
  const uint32_t t1 = mempool_get_timer();
  uint32_t qp = 0;
  for (uint32_t i = 0; i < 2u * ATT_T; ++i) {
    if (cid == 0 && i + 1u < 2u * ATT_T)
      dma_memcpy_nonblocking(att_buf + ((i + 1u) & 1u) * ATT_TILE_B,
                             att_kv_l2 + (i + 1u) * ATT_TILE_B, ATT_TILE_B);
    const uint32_t r = i / 2u;
    if (active) {
      qp = r / ATT_RPP;
      if ((i & 1u) == 0u) {
        if (r % ATT_RPP == 0u) qc_att_part_reset(cid, 0u);
        qc_att_qk_softmax((uint8_t *)qc_slot(att_buf, 0, cid), cid, RES_Q + qp * 48u, 0u, 0);
      } else {
        qc_att_pv((uint8_t *)qc_slot(att_buf + ATT_TILE_B, 0, cid), cid, 0u);
        if (ATT_CPP == 1u && r % ATT_RPP == ATT_RPP - 1u) qc_att_finish(cid, RES_OUT + qp * 48u, 0u);
      }
    }
    if (cid == 0) dma_wait();
    qc_barrier(cid);
  }
  const uint32_t t2 = mempool_get_timer();
  // Combine the split-S partials (ATT_PPC == 1 whenever ATT_CPP > 1).
  for (uint32_t s = 1; s < ATT_CPP; s <<= 1) {
    const uint32_t part = cid % ATT_CPP;
    if (active && (part % (2u * s)) == 0u) qc_att_merge(cid, cid + s, 0u);
    qc_barrier(cid);
  }
  if (ATT_CPP > 1u && active && (cid % ATT_CPP) == 0u) qc_att_finish(cid, RES_OUT, 0u);
  qc_barrier(cid);
  mempool_stop_benchmark();
  const uint32_t t3 = mempool_get_timer();

  if (cid == 0) {
    // FPU element-ops per block: QK 6 x 256 x 32, PV 6 x 256 x 32 (FMAs; softmax not counted)
    const uint32_t ops = ATT_NPRB * ATT_NBP * 2u * ATT_QPK * ATT_D * ATT_TB;
    const uint32_t ideal = ops / (NUM_CORES * 2u * N_FPU);
    printf("\n----- qwen attention core (B=%u, S=%u) -----\n", ATT_B, ATT_S);
    printf("The execution took %u cycles.\n", t3 - t0);
    printf("[ATT] B=%u S=%u problems=%u cores/problem=%u active=%u rounds=%u total=%u "
           "prologue=%u rounds_cyc=%u per_round=%u combine=%u ideal=%u eff=%u%%o kv_bytes=%u\n",
           ATT_B, ATT_S, ATT_NPRB, ATT_CPP, ATT_ACTIVE, ATT_T, t3 - t0, t1 - t0, t2 - t1,
           (t2 - t1) / ATT_T, t3 - t2, ideal, ideal * 1000u / (t3 - t0),
           ATT_NPRB * ATT_S * ATT_D * 4u);
  }

#if ATT_CHECK
  uint32_t bad = 0;
  if (active && (cid % ATT_CPP) == 0u)
    for (uint32_t q = 0; q < ATT_PPC; ++q) {
      const att_id_t d = att_id(cid, q * ATT_RPP);
      for (uint32_t h = 0; h < ATT_QPK; ++h)
        for (uint32_t dd = 0; dd < ATT_D; ++dd) {
          const uint16_t want = ((dd + d.g + d.b + 4u * ATT_QPK - h) % 4u == 0u) ? 0x3800u : 0u;
          const uint16_t got = ((const uint16_t *)res(RES_OUT + (q * 6u + h) * 8u + dd / 32u, cid))[dd % 32u];
          if (got != want) {
            if (!bad) att_first[cid] = (att_miss_t){d.b, d.g, h, dd, got, want};
            ++bad;
          }
        }
    }
  att_bad[cid] = bad;
  qc_barrier(cid);
  if (cid == 0) {
    uint32_t total = 0;
    for (uint32_t k = 0; k < NUM_CORES; ++k) total += att_bad[k];
    printf("[ATT] check: %s (%u mismatches)\n", total ? "FAIL" : "PASS", total);
    for (uint32_t k = 0, n = 0; k < NUM_CORES && n < 40u; ++k)
      if (att_bad[k]) {
        ++n;
        printf("[ATT]   core %u: %u bad, first b=%u g=%u ctx[%u][%u] = 0x%04x want 0x%04x\n", k,
               att_bad[k], att_first[k].b, att_first[k].g, att_first[k].h, att_first[k].d,
               att_first[k].got, att_first[k].want);
      }
  }
#endif
  qc_barrier(cid);
  return 0;
}
