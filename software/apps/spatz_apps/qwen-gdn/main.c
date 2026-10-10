// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
//==============================================================================
// Qwen3.8-27B Gated DeltaNet decode step: the delta-rule state update.
//==============================================================================
//
// docs/qwen3_8_27b/mixer_plan.md, section 4. Per sequence b and value head h, the state S is
// 128 x 128 fp16 (rows i = value dims, columns j = key dims); 3 value heads share a key head.
//
//     pred_i = s_i . k ;  c_i = beta (v_i - alpha pred_i) ;  s_i <- alpha s_i + c_i k ;
//     o_i    = s_i . q
//
// Rows are independent. A CHUNK is 32 rows of one value head (alpha and beta are scalars for
// it): 4 per head, 192 per sequence. Chunk c goes to core c % NUM_CORES in round
// c / NUM_CORES. The chunk is stored COLUMN-MAJOR in tile slots: column j (32 fp16 = 64 B) is
// this core's slot of sweep j, so every vector access stays in the core's own tile and the
// state never crosses the NoC. Vectors run over the 32 rows and k_j, q_j are scalars
// (vfmacc.vf), like the GEMM kernels -- no reductions:
//
//   pass 1:  pred += k_j * S[:,j]                         (4 accumulators)
//            c = beta (v - alpha pred)
//   pass 2:  S[:,j] = alpha S[:,j] + k_j c ;  o += q_j S[:,j]
//
// Per column: 4 vector FP ops on 32 fp16 (16 FPU cycles), 2 loads + 1 store of 64 B.
//
// A STATE TILE is one round: column j of every core's chunk at sweep j = 128 sweeps (2 MiB at
// 4x4, 8 MiB at 8x8). The per-chunk inputs (v, k, q, alpha, beta) and output o sit in the same
// core's slots of an aux area, 11 sweeps per round (what the projection epilogue will write).
//
// GDN_STREAM=1 (default, option B, mixer_plan D1): the state lives in L2 in L1 sweep order, so a
// tile is ONE contiguous DMA each way. Three L1 tile buffers: round t computes buf[t % 3] while
// the DMA writes tile t-1 back and loads tile t+1. The cluster DMA takes one transfer at a time
// (mempool_dma.sv: a launch clears `done` and is not stalled while busy), so core 0 sequences
// the two transfers by polling between column blocks of its own chunk.
// GDN_STREAM=0 (option A): every round's tile stays resident in L1 (small B only).
//
// GDN_CHECK=1: exact small-integer pattern (all fp16 arithmetic exact), every core checks o and
// the new state of its chunks against an integer model. Perf builds init the state only in L1
// (option A) and print nothing data-dependent.
//
//==============================================================================

#include <stdint.h>

#include "../qwen-common/qc_gdn.h"
#include "../qwen-common/qc_layout.h"
#include "../qwen-common/qc_sync.h"
#include "../qwen-common/qc_vec.h"
#include "dma.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#ifndef GDN_B
#define GDN_B 1  // decode batch: independent sequences
#endif
#ifndef GDN_STREAM
#define GDN_STREAM 1  // 1 = state streamed from L2 (option B), 0 = resident in L1 (option A)
#endif
#ifndef GDN_CHECK
#define GDN_CHECK 0
#endif
#define GDN_KH QC_GDN_KH
#define GDN_VPK QC_GDN_VPK
#define GDN_VH QC_GDN_VH
#define GDN_D QC_GDN_D
#define GDN_RC QC_GDN_RC
#define GDN_RB QC_GDN_RB
#define GDN_CPS QC_GDN_CPS
#define GDN_NC (GDN_CPS * GDN_B)                      // chunks per step
#define GDN_T ((GDN_NC + NUM_CORES - 1) / NUM_CORES)  // rounds
#define GDN_TILE_B QC_GDN_TILE_B
#define AUX_V QC_GDN_AUX_V
#define AUX_O QC_GDN_AUX_O
#define AUX_K QC_GDN_AUX_K
#define AUX_Q QC_GDN_AUX_Q
#define AUX_AB QC_GDN_AUX_AB
#define AUX_SW QC_GDN_AUX_SW

#if GDN_STREAM
#define GDN_NBUF (GDN_T < 3u ? GDN_T : 3u)
#else
#define GDN_NBUF GDN_T
#endif

static uint8_t gdn_s[GDN_NBUF * GDN_TILE_B] QC_L1_SWEEP;
static uint8_t gdn_aux[GDN_T * AUX_SW * QC_SWEEP_B] QC_L1_SWEEP;
#if GDN_STREAM
static uint8_t gdn_s_l2[GDN_T * GDN_TILE_B] __attribute__((section(".l2_bss"), aligned(4096)));
#endif

static inline uint8_t *gdn_buf(uint32_t t) { return gdn_s + (t % GDN_NBUF) * GDN_TILE_B; }
static inline uint8_t *gdn_auxp(uint32_t t, uint32_t sw, uint32_t cid) {
  return (uint8_t *)qc_slot(gdn_aux, t * AUX_SW + sw, cid);
}

//==============================================================================
// DMA sequencing (core 0, option B)
//==============================================================================

#if GDN_STREAM
typedef struct {
  void *dst;
  const void *src;
} gdn_xfer_t;
static gdn_xfer_t gdn_dq[2];
static uint32_t gdn_dq_n, gdn_dq_i;

static inline void gdn_dma_launch(void) {
  dma_memcpy_nonblocking(gdn_dq[gdn_dq_i].dst, gdn_dq[gdn_dq_i].src, GDN_TILE_B);
  ++gdn_dq_i;
}
// Launch the next queued transfer once the previous one has completed.
static void gdn_dma_poll(void) {
  if (gdn_dq_i < gdn_dq_n && dma_done()) gdn_dma_launch();
}
static inline void gdn_dma_drain(void) {
  while (gdn_dq_i < gdn_dq_n) {
    dma_wait();
    gdn_dma_launch();
  }
  dma_wait();
}
// Round t's transfers: write tile t-1 back, then load tile t+1.
static void gdn_dma_round(uint32_t t) {
  gdn_dq_n = gdn_dq_i = 0;
  if (t >= 1) gdn_dq[gdn_dq_n++] = (gdn_xfer_t){gdn_s_l2 + (t - 1) * GDN_TILE_B, gdn_buf(t - 1)};
  if (t + 1 < GDN_T) gdn_dq[gdn_dq_n++] = (gdn_xfer_t){gdn_buf(t + 1), gdn_s_l2 + (t + 1) * GDN_TILE_B};
  if (gdn_dq_n) gdn_dma_launch();  // the previous round drained, so the DMA is idle
}
#endif

//==============================================================================
// One chunk
//==============================================================================

#if GDN_STREAM
static void (*const gdn_poll_fn)(void) = gdn_dma_poll;
#else
static void (*const gdn_poll_fn)(void) = 0;
#endif

//==============================================================================
// Pattern (exact in fp16) and its integer model, in units of 1/256
//==============================================================================

typedef qc_gdn_id_t gdn_id_t;
#define gdn_id qc_gdn_id
// Column j of every chunk is one of 5 rotations (j % 5), so the state is written with vector
// stores of 5 prepared columns.
static inline int32_t pat_s0(uint32_t i, uint32_t j) { return (int32_t)((2u * i + 3u * j) % 5u) - 2; }
static inline int32_t pat_k(gdn_id_t d, uint32_t j) {
  const uint32_t m = (j + 3u * d.kh + d.b) % 16u;
  return m == 0u ? 1 : (m == 8u ? -1 : 0);
}
static inline int32_t pat_q(gdn_id_t d, uint32_t j) {
  const uint32_t m = (j + 5u * d.kh + 2u * d.b) % 16u;
  return m == 3u ? 1 : (m == 11u ? -1 : 0);
}
static inline int32_t pat_a256(gdn_id_t d) { return (d.vh % 2u) ? 64 : 128; }        // 0.25 / 0.5
static inline int32_t pat_b256(gdn_id_t d) { return ((d.vh / 2u) % 2u) ? 128 : 64; } // 0.5 / 0.25
static inline int32_t pat_v(gdn_id_t d, uint32_t i) {
  return (int32_t)(((d.rb * GDN_RC + i) * 3u + d.vh + d.b) % 7u) - 3;
}
// v256 / 256 as fp16: exact for the pattern (small integers and multiples of 1/256 that need
// at most 11 significant bits).
static inline uint16_t f16_of_fix256(int32_t v256) {
  if (v256 == 0) return 0u;
  const uint16_t s = v256 < 0 ? 0x8000u : 0u;
  uint32_t a = (uint32_t)(v256 < 0 ? -v256 : v256);
  int32_t e = 15 - 8;
  while (a >= 2048u) a >>= 1, ++e;
  while (a < 1024u) a <<= 1, --e;
  return (uint16_t)(s | ((uint32_t)(e + 10) << 10) | (a & 0x3ffu));
}
static inline uint16_t f16_of_int(int32_t v) { return f16_of_fix256(v * 256); }

// This core's inputs for round t (any build) and, for option A, its initial state.
static void gdn_init_round(uint32_t t, uint32_t cid, uint8_t *tile) {
  const uint32_t c = t * NUM_CORES + cid;
  if (c >= GDN_NC) return;
  const gdn_id_t d = gdn_id(c);
  uint16_t *v = (uint16_t *)gdn_auxp(t, AUX_V, cid);
  for (uint32_t i = 0; i < GDN_RC; ++i) v[i] = f16_of_int(pat_v(d, i));
  for (uint32_t j = 0; j < GDN_D; ++j) {
    ((uint16_t *)gdn_auxp(t, AUX_K + j / GDN_RC, cid))[j % GDN_RC] = f16_of_int(pat_k(d, j));
    ((uint16_t *)gdn_auxp(t, AUX_Q + j / GDN_RC, cid))[j % GDN_RC] = f16_of_int(pat_q(d, j));
  }
  uint16_t *ab = (uint16_t *)gdn_auxp(t, AUX_AB, cid);
  ab[0] = f16_of_fix256(pat_a256(d));
  ab[1] = f16_of_fix256(pat_b256(d));
  if (!tile) return;
  for (uint32_t j = 0; j < 5u; ++j) {
    uint16_t *col = (uint16_t *)qc_slot(tile, j, cid);
    for (uint32_t i = 0; i < GDN_RC; ++i) col[i] = f16_of_int(pat_s0(i, j));
  }
  size_t vl;
  __asm__ volatile("fence" ::: "memory");
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(GDN_RC));
  __asm__ volatile("vle16.v v20, (%0)" ::"r"(qc_slot(tile, 0, cid)) : "memory");
  __asm__ volatile("vle16.v v21, (%0)" ::"r"(qc_slot(tile, 1, cid)) : "memory");
  __asm__ volatile("vle16.v v22, (%0)" ::"r"(qc_slot(tile, 2, cid)) : "memory");
  __asm__ volatile("vle16.v v23, (%0)" ::"r"(qc_slot(tile, 3, cid)) : "memory");
  __asm__ volatile("vle16.v v24, (%0)" ::"r"(qc_slot(tile, 4, cid)) : "memory");
  for (uint32_t j = 5; j < GDN_D; ++j) {
    void *col = qc_slot(tile, j, cid);
    switch (j % 5u) {
      case 0: __asm__ volatile("vse16.v v20, (%0)" ::"r"(col) : "memory"); break;
      case 1: __asm__ volatile("vse16.v v21, (%0)" ::"r"(col) : "memory"); break;
      case 2: __asm__ volatile("vse16.v v22, (%0)" ::"r"(col) : "memory"); break;
      case 3: __asm__ volatile("vse16.v v23, (%0)" ::"r"(col) : "memory"); break;
      default: __asm__ volatile("vse16.v v24, (%0)" ::"r"(col) : "memory"); break;
    }
  }
  __asm__ volatile("fence" ::: "memory");
}

#if GDN_CHECK
#include "data/gdn_check.h"  // script/gen_check.py: c (x256) and o per chunk row
#if GDN_CHECK_B != GDN_B
#error "data/gdn_check.h was generated for another batch"
#endif
typedef struct {
  uint32_t chunk, i, j;  // j = 0xffff: o[i]
  uint16_t got, want;
} gdn_miss_t;
static gdn_miss_t gdn_first[NUM_CORES];
// o, and the new state at column 0 and every column with k != 0 (GDN_CHECK=2: every column), of
// this core's chunk in round t; state column j at `tile` (L1, or the L2 copy in the same order).
static uint32_t gdn_check_round(uint32_t t, uint32_t cid, const uint8_t *tile) {
  const uint32_t c = t * NUM_CORES + cid;
  if (c >= GDN_NC) return 0u;
  const gdn_id_t d = gdn_id(c);
  const int32_t a256 = pat_a256(d);
  const uint16_t *o = (const uint16_t *)gdn_auxp(t, AUX_O, cid);
  uint32_t bad = 0;
  for (uint32_t i = 0; i < GDN_RC; ++i) {
    const uint16_t ow = gdn_o_bits[c * GDN_RC + i];
    if (o[i] != ow) {
      if (!bad) gdn_first[cid] = (gdn_miss_t){c, i, 0xffffu, o[i], ow};
      ++bad;
    }
    const int32_t c256 = gdn_c256[c * GDN_RC + i];
    for (uint32_t j = 0; j < GDN_D; ++j) {
      const int32_t kj = pat_k(d, j);
      if (GDN_CHECK < 2 && kj == 0 && j != 0) continue;
      const uint16_t want = f16_of_fix256(a256 * pat_s0(i, j) + c256 * kj);
      const uint16_t got = ((const uint16_t *)(tile + j * QC_SWEEP_B + cid * QC_SLOT_B))[i];
      if (got != want) {
        if (!bad) gdn_first[cid] = (gdn_miss_t){c, i, j, got, want};
        ++bad;
      }
    }
  }
  return bad;
}
static uint32_t gdn_bad[NUM_CORES];
#endif

//==============================================================================

int main(void) {
  const uint32_t cid = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  mempool_barrier_init(cid);
  qc_sync_init(cid);
  mempool_barrier(num_cores);
  qc_rne();

  // ---- setup, outside the timed region ----------------------------------------------------
  for (uint32_t t = 0; t < GDN_T; ++t) {
#if GDN_STREAM
    // The L2 state of a check build is written through buffer 0, one tile at a time.
    gdn_init_round(t, cid, GDN_CHECK ? gdn_buf(0) : 0);
#if GDN_CHECK
    qc_barrier(cid);
    if (cid == 0) dma_memcpy_blocking(gdn_s_l2 + t * GDN_TILE_B, gdn_buf(0), GDN_TILE_B);
    qc_barrier(cid);
#endif
#else
    gdn_init_round(t, cid, gdn_buf(t));
#endif
  }
  qc_barrier(cid);

  // ---- the decode step ----------------------------------------------------------------------
  const uint32_t t0 = mempool_get_timer();
  mempool_start_benchmark();
#if GDN_STREAM
  if (cid == 0) dma_memcpy_blocking(gdn_buf(0), gdn_s_l2, GDN_TILE_B);  // tile 0, exposed
  qc_barrier(cid);
#endif
  const uint32_t t1 = mempool_get_timer();
  for (uint32_t t = 0; t < GDN_T; ++t) {
    const uint32_t c = t * NUM_CORES + cid;
#if GDN_STREAM
    if (cid == 0) gdn_dma_round(t);
#endif
    if (c < GDN_NC)
      qc_gdn_chunk((uint8_t *)qc_slot(gdn_buf(t), 0, cid), gdn_auxp(t, 0, cid),
                   (GDN_STREAM && cid == 0) ? gdn_poll_fn : 0);
#if GDN_STREAM
    if (cid == 0) gdn_dma_drain();
    qc_barrier(cid);
#endif
  }
#if GDN_STREAM
  if (cid == 0) dma_memcpy_blocking(gdn_s_l2 + (GDN_T - 1) * GDN_TILE_B, gdn_buf(GDN_T - 1),
                                    GDN_TILE_B);  // last tile back, exposed
#endif
  qc_barrier(cid);
  mempool_stop_benchmark();
  const uint32_t t2 = mempool_get_timer();

  if (cid == 0) {
    // FPU element-ops: 4 per state element (alpha*, two FMAs, the pred FMA) + c (2 per row)
    const uint32_t ops = GDN_NC * (GDN_RC * GDN_D * 4u + 2u * GDN_RC);
    const uint32_t ideal = ops / (NUM_CORES * 2u * N_FPU);
    printf("\n----- qwen gdn delta rule (B=%u, %s) -----\n", GDN_B,
           GDN_STREAM ? "state streamed from L2" : "state resident in L1");
    printf("The execution took %u cycles.\n", t2 - t0);
    printf("[GDN] B=%u chunks=%u rounds=%u total=%u prologue=%u rounds_cyc=%u per_round=%u "
           "ideal=%u eff=%u%%o state_bytes=%u\n",
           GDN_B, GDN_NC, GDN_T, t2 - t0, t1 - t0, t2 - t1, (t2 - t1) / GDN_T, ideal,
           ideal * 1000u / (t2 - t0), GDN_NC * GDN_RC * GDN_D * 2u);
  }

#if GDN_CHECK
  uint32_t bad = 0;
  for (uint32_t t = 0; t < GDN_T; ++t)
#if GDN_STREAM
    bad += gdn_check_round(t, cid, gdn_s_l2 + t * GDN_TILE_B);
#else
    bad += gdn_check_round(t, cid, gdn_buf(t));
#endif
  gdn_bad[cid] = bad;
  qc_barrier(cid);
  if (cid == 0) {
    uint32_t total = 0, cores = 0;
    for (uint32_t k = 0; k < NUM_CORES; ++k) {
      total += gdn_bad[k];
      cores += gdn_bad[k] ? 1u : 0u;
    }
    printf("[GDN] check: %s (%u mismatches on %u cores)\n", total ? "FAIL" : "PASS", total, cores);
    for (uint32_t k = 0, n = 0; k < NUM_CORES && n < 64u; ++k)
      if (gdn_bad[k]) {
        ++n;
        printf("[GDN]   core %u: %u bad, first chunk %u %s[%u][%u] = 0x%04x want 0x%04x\n", k,
               gdn_bad[k], gdn_first[k].chunk, gdn_first[k].j == 0xffffu ? "o" : "S",
               gdn_first[k].i, gdn_first[k].j, gdn_first[k].got, gdn_first[k].want);
      }
  }
  qc_barrier(cid);
#endif
  qc_barrier(cid);  // core 0's report is out before any core reaches EOC
  return 0;
}
