// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
// qwen-layer mixer: everything between the qkvz projection and the o-projection
// (docs/qwen3_8_27b/mixer_plan.md, sections 4-5).
//
//   ab stage   a, b: 96 dot products x_b . w per sequence, spread over all cores, each result sent
//              to the aux slots of the 4 chunks of its value head
//   per chunk  q, k L2-normalised (q also by 1/sqrt(128)); alpha = exp(-softplus(a)),
//              beta = sigmoid(b) (A_log = dt_bias = 0); the delta rule (qc_gdn.h); the chunk's
//              sum of o^2
//   per round  (after the round barrier) gated RMSNorm per value head -- its 4 chunks are 4
//              consecutive cores of one group: o' = o * rsqrt(mean o^2) * SiLU(z), straight into
//              every replica of the o-projection's A operand
//
// Chunk part u = c * QL_CS + p (layer.h) is on core u % NUM_CORES in round u / NUM_CORES. The state
// is streamed from L2 (QL_STREAM=1, mixer_plan D1) or resident in L1 -- the same scheme as qwen-gdn.
// QL_GCK=1 runs the chunked delta rule: the step's QL_TOK tokens in one pass over the state
// (qc_gdn.h), the QL_CS column parts of a chunk summing their partial S k / S q through their aux
// slots; part p writes (and gated-norms) the tokens j with j % QL_CS == p.
#include <stdint.h>

#include "layer.h"
#include "../qwen-common/qc_sync.h"
#include "../qwen-common/qc_vec.h"
#define QC_GDN_NT QL_TOK
#include "../qwen-common/qc_gdn.h"
#include "dma.h"
#include "printf.h"
#include "runtime.h"

#if QL_STATE_W
// The W area is idle between the projections. When the state tiles fit in its second region, the
// o-projection's tile 0 loads into the first one during the a,b stage (no DMA there).
#define QL_STATE_IN_W1 (QL_L1_STATE <= 2u * (uint32_t)QL_WREG_ELEMS)
#define ql_s ((uint8_t *)(ql_w_area + (QL_STATE_IN_W1 ? QL_WREG_ELEMS : 0u)))
#else
#define QL_STATE_IN_W1 0
static uint8_t ql_s[QL_L1_STATE] QC_L1_SWEEP;
#endif

// a, b: round t's chunk parts belong to QL_HEADS_PER_ROUND value-head instances (b, vh) = head
// h = t * HPR + j; each needs a = x_b . w[2 vh] and b = x_b . w[2 vh + 1] for every token of the
// step. HPR heads x {a, b} x QL_AB_KP K parts = one task per core, all tokens per task (the W row
// chunk loaded once): task cid of round t+1 runs in round t after the core's own chunk, while the
// state DMA is still busy; round 0's run up front. The partial sums go to the AB slots (per
// token) of the head's 4 QL_CS chunk parts (element 2 + part for a, 2 + KP + part for b).
#define QL_HEADS_PER_ROUND (NUM_CORES / (QC_GDN_RB * QL_CS))
#define QL_AB_KP (NUM_CORES / (2u * QL_HEADS_PER_ROUND))  // 2 QL_CS
#define QL_AB_KLEN (QL_H / QL_AB_KP)
_Static_assert(QL_AB_KP * 2u * QL_HEADS_PER_ROUND == NUM_CORES, "one a,b task per core");
_Static_assert(QL_AB_KLEN % 128u == 0u, "a,b: whole 128-element row chunks per task");
_Static_assert(2u + 2u * QL_AB_KP <= QC_SLOT_F16, "AB slot: alpha, beta and the partial sums");
_Static_assert(NUM_CORES % (QC_GDN_RB * QL_CS) == 0u, "a head's chunk parts: inside one round");
#if QL_STREAM
// Sweep-aligned: a tile copy then maps every group slice to the same L2 offset (a 4 KiB shift of
// this buffer halved the GVSoC DMA rate).
static uint8_t ql_s_l2[QL_T * QL_GTILE_B] __attribute__((section(".l2_bss"), aligned(QC_SWEEP_B)));
#endif
#if QL_GCK && QL_CS > 1
static volatile uint32_t ql_gsync[NUM_CORES];  // chunk parts: partials stored, per call
#endif
static ql_elem_t ql_wab[QL_AB * QL_H] __attribute__((section(".l1_prio"), aligned(64)));
// Stage timers, written by core 0 only: they sit in L2, and one word stored by every core costs
// each core ~1.6k cycles on RTL (1024 stores serialised on one bank).
static uint32_t ql_t_start, ql_t_ab, ql_t_rounds, ql_t_end;

static inline uint8_t *ql_buf(uint32_t t) { return ql_s + (t % QL_NBUF) * QL_GTILE_B; }
static inline float *ql_ss(uint32_t t, uint32_t j, uint32_t cid) {
  return (float *)ql_auxt(t, j, QL_AUX_SS, cid);
}
// This core's scratch: slot 0 data, slot 1 zeros (written at setup).
static inline uint8_t *ql_scr_at(uint32_t k, uint32_t cid) {
  return (uint8_t *)qc_slot(ql_scr, k, cid);
}

//==============================================================================
// DMA sequencing (core 0, streamed state): one transfer at a time (mempool_dma.sv)
//==============================================================================

#if QL_STREAM
typedef struct {
  void *dst;
  const void *src;
} ql_xfer_t;
static ql_xfer_t ql_dq[2];
static uint32_t ql_dq_n, ql_dq_i;
static inline void ql_dma_launch(void) {
  dma_memcpy_nonblocking(ql_dq[ql_dq_i].dst, ql_dq[ql_dq_i].src, QL_GTILE_B);
  ++ql_dq_i;
}
static void ql_dma_poll(void) {
  if (ql_dq_i < ql_dq_n && dma_done()) ql_dma_launch();
}
static void ql_dma_drain(void) {
  if (!ql_dq_n) return;  // nothing of the round's (QL_T = 1: o-proj tile 0 may still be loading)
  while (ql_dq_i < ql_dq_n) {
    dma_wait();
    ql_dma_launch();
  }
  dma_wait();
}
// Round t: write tile t-1 back, then load tile t+1.
static __attribute__((noinline)) void ql_dma_round(uint32_t t) {
  ql_dq_n = ql_dq_i = 0;
  if (t >= 1)
    ql_dq[ql_dq_n++] = (ql_xfer_t){ql_s_l2 + (t - 1) * QL_GTILE_B, ql_buf(t - 1)};
  if (t + 1 < QL_T)
    ql_dq[ql_dq_n++] = (ql_xfer_t){ql_buf(t + 1), ql_s_l2 + (t + 1) * QL_GTILE_B};
  if (ql_dq_n) ql_dma_launch();
}
#endif

//==============================================================================
// Small pieces
//==============================================================================

// Element 0 of a reduction result in v24 (e32), through this core's scratch slot: a VLSU store
// then a scalar load (vfmv.f.s right after a reduction read stale values on GVSoC).
static inline float ql_red_out(uint32_t cid) {
  QC_VL1("e32");
  __asm__ volatile("vse32.v v24, (%0)" ::"r"(ql_scr_at(0, cid)) : "memory");
  __asm__ volatile("fence" ::: "memory");
  return *(volatile float *)ql_scr_at(0, cid);
}

// sum of squares of n_slots aux slots (32 fp16 each) in fp32.
static __attribute__((noinline)) float ql_sumsq_slots(uint8_t *slot0, uint32_t n_slots, uint32_t cid) {
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
  __asm__ volatile("vle16.v v0, (%0)" ::"r"(slot0) : "memory");
  __asm__ volatile("vfwmul.vv v8, v0, v0");
  for (uint32_t k = 1; k < n_slots; ++k) {
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(slot0 + k * QC_SWEEP_B) : "memory");
    __asm__ volatile("vfwmacc.vv v8, v0, v0");
  }
  QC_VL1("e32");
  __asm__ volatile("vle32.v v26, (%0)" ::"r"(ql_scr_at(1, cid)) : "memory");  // zeros
  __asm__ volatile("vsetvli %0, %1, e32, m2, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
  __asm__ volatile("vfredusum.vs v24, v8, v26");
  return ql_red_out(cid);
}

#if !QL_GCK
static void ql_scale_slots(uint8_t *slot0, uint32_t n_slots, _Float16 s) {
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
  for (uint32_t k = 0; k < n_slots; ++k) {
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(slot0 + k * QC_SWEEP_B) : "memory");
    __asm__ volatile("vfmul.vf v0, v0, %0" ::"f"(s));
    __asm__ volatile("vse16.v v0, (%0)" ::"r"(slot0 + k * QC_SWEEP_B) : "memory");
  }
}
#endif

// alpha, beta (fp32) of token j from the raw a, b partial sums in its AB slot.
static __attribute__((noinline)) void ql_alpha_beta(uint32_t t, uint32_t j, uint32_t cid, float *out) {
  _Float16 *ab = (_Float16 *)ql_auxt(t, j, QC_GDN_AUX_AB, cid);
  float a = (float)ab[2], b = (float)ab[2u + QL_AB_KP];
  for (uint32_t pp = 1; pp < QL_AB_KP; ++pp) {
    a += (float)ab[2u + pp];
    b += (float)ab[2u + QL_AB_KP + pp];
  }
  const float one = qc_f32_imm(0x3f800000u), zero = qc_f32_imm(0u);
  // softplus(a) = max(a, 0) + log1p(exp(-|a|)); log1p(u) = u (q0 + q1 u + q2 u^2 + q3 u^3)
  const float ea = qc_exp_f32(-__builtin_fmaxf(a, -a));
  const float lp = ea * (qc_f32_imm(0x3f7fe000u) +
                         ea * (qc_f32_imm(0xbef92000u) +
                               ea * (qc_f32_imm(0x3e826000u) + ea * qc_f32_imm(0xbd990000u))));
  const float alpha = qc_exp_f32(-(__builtin_fmaxf(a, zero) + lp));
  // sigmoid(b), branch-free: e = exp(-|b|), r = 1/(1+e), times (b > 0 ? 1 : e)
  const float eb = qc_exp_f32(-__builtin_fmaxf(b, -b));
  const float rb = qc_recip_f32(one + eb);
  const float sel = __builtin_fminf(one, eb + qc_f32_imm(0x46800000u) * __builtin_fmaxf(b, zero));
  out[0] = alpha;
  out[1] = rb * sel;
}

#if !QL_GCK
// Chunk inputs: q, k normalised; alpha, beta from the raw a, b.
static __attribute__((noinline)) void ql_chunk_pre(uint32_t t, uint32_t j, uint32_t cid) {
  const float eps = qc_f32_imm(0x358637bdu);           // 1e-6
  const float rs128 = qc_f32_imm(0x3db504f3u);         // 1/sqrt(128)
  uint8_t *q = ql_auxt(t, j, QC_GDN_AUX_Q, cid), *k = ql_auxt(t, j, QC_GDN_AUX_K, cid);
  const float sq = ql_sumsq_slots(q, QC_GDN_D / QC_SLOT_F16, cid);
  const float sk = ql_sumsq_slots(k, QC_GDN_D / QC_SLOT_F16, cid);
  ql_scale_slots(q, QC_GDN_D / QC_SLOT_F16, (_Float16)(qc_rsqrt_f32(sq + eps) * rs128));
  ql_scale_slots(k, QC_GDN_D / QC_SLOT_F16, (_Float16)qc_rsqrt_f32(sk + eps));
  float ab2[2];
  ql_alpha_beta(t, j, cid, ab2);
  _Float16 *ab = (_Float16 *)ql_auxt(t, j, QC_GDN_AUX_AB, cid);
  ab[0] = (_Float16)ab2[0];
  ab[1] = (_Float16)ab2[1];
}
#else
// The chunked kernel on this core's chunk part (round t): alpha, beta of every token, partial S k /
// S q over its columns, the parts' sync, then c / o / the state update; the sums of squares of the
// tokens it writes. Core 0 sequences the state DMA between the calls.
static __attribute__((noinline)) void ql_gck_part(uint32_t t, uint32_t cid) {
  const uint32_t part = cid % QL_CS, astr = QL_AUX_SW * QC_SWEEP_B;
  float ab[2u * QL_TOK];
  for (uint32_t j = 0; j < QL_TOK; ++j) ql_alpha_beta(t, j, cid, ab + 2u * j);
  uint8_t *s = (uint8_t *)qc_slot(ql_buf(t), 0, cid), *aux = ql_auxt(t, 0u, 0u, cid);
  qc_gdn_ck_pr(s, QL_GW, part * QL_GW, aux, astr);
#if QL_STREAM
  if (cid == 0) ql_dma_poll();
#endif
#if QL_CS > 1
  {  // every part's partials stored before any part reads them
    __asm__ volatile("fence" ::: "memory");
    const uint32_t n = ql_gsync[cid] + 1u, c0 = cid - part;
    ql_gsync[cid] = n;
    for (uint32_t p = 0; p < QL_CS; ++p)
      while (ql_gsync[c0 + p] < n) { }
  }
#endif
  uint32_t own = 0;
  for (uint32_t j = part; j < QL_TOK; j += QL_CS) own |= 1u << j;
  qc_gdn_ck_out(s, QL_GW, part * QL_GW, aux, astr, QL_CS, part, own, ab, ql_scr_at(2, cid),
                ql_scr_at(1, cid));
#if QL_STREAM
  if (cid == 0) ql_dma_poll();
#endif
  for (uint32_t j = part; j < QL_TOK; j += QL_CS)
    *ql_ss(t, j, cid) = ql_sumsq_slots(ql_auxt(t, j, QC_GDN_AUX_O, cid), 1u, cid);
}
#endif

// The 4 chunks of a value head are 4 QL_CS consecutive cores from base; token j of chunk rb sits on
// core base + rb QL_CS + j % QL_CS: o' = o * rsqrt(mean o^2) * SiLU(z), into every replica of the
// o-projection's A. Token j of the step: o' row b * QL_TOK + j.
static __attribute__((noinline)) void ql_gated_norm(uint32_t t, uint32_t j, uint32_t cid,
                                                    const qc_k_t *kp) {
  const qc_k_t qck = *kp;
  const uint32_t c = (t * NUM_CORES + cid) / QL_CS;
  const qc_gdn_id_t d = qc_gdn_id(c);
  const uint32_t base = cid - cid % (QC_GDN_RB * QL_CS) + j % QL_CS;
  const float ss = *ql_ss(t, j, base) + *ql_ss(t, j, base + QL_CS) +
                   *ql_ss(t, j, base + 2u * QL_CS) + *ql_ss(t, j, base + 3u * QL_CS);
  const uint32_t row = d.b * QL_TOK + j;
  const _Float16 r = (_Float16)qc_rsqrt_f32(ss * qc_f32_imm(0x3c000000u) + qc_f32_imm(0x358637bdu));
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
  __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_auxt(t, j, QC_GDN_AUX_O, cid)) : "memory");
  __asm__ volatile("vle16.v v1, (%0)" ::"r"(ql_auxt(t, j, QL_AUX_Z, cid)) : "memory");
  QC_SILU("v1", "v2", "v3", "v4", "v5", "v28", "v29");
  __asm__ volatile("vfmul.vf v0, v0, %0" ::"f"(r));
  __asm__ volatile("vfmul.vv v0, v0, v5");
  const uint32_t col = d.vh * QC_GDN_D + d.rb * QC_GDN_RC;
  if (QL_CHECK) {  // identity values instead of o'
    uint16_t *scr = (uint16_t *)ql_scr_at(0, cid);
    for (uint32_t i = 0; i < QC_GDN_RC; ++i) scr[i] = ql_pat(d.b, QL_PAT_O + col + i);
    __asm__ volatile("fence" ::: "memory");
    __asm__ volatile("vle16.v v6, (%0)" ::"r"(scr) : "memory");
    for (uint32_t k = 0; k < (uint32_t)QL_O_REPLICAS; ++k)
      __asm__ volatile("vse16.v v6, (%0)" ::"r"(ql_o_at(k, row, col)) : "memory");
    return;
  }
  for (uint32_t k = 0; k < (uint32_t)QL_O_REPLICAS; ++k)
    __asm__ volatile("vse16.v v0, (%0)" ::"r"(ql_o_at(k, row, col)) : "memory");
}

//==============================================================================
// Setup and run
//==============================================================================

#if QL_GCHK
static void ql_gchk_fill(uint32_t cid);  // the self-test's patterns (below)
#endif

// The DMA's last transfer (dma.h defines non-inline functions: one translation unit only).
void ql_mixer_dma_wait(void) { dma_wait(); }

// Mixer-only builds: no in-projection ran, and the RTL DMA's done flag reads 0 until a first
// transfer completes, so the mixer's first dma_wait() would never return (GVSoC starts at 1).
// One small transfer before the timed region leaves the DMA as the in-projection would: idle.
// In the small initialised .l2 section: an .l2_bss object here would shift the big streamed
// buffers off their sweep alignment (that halves the DMA rate).
static const uint8_t ql_dma_prime_l2[64] __attribute__((section(".l2"), aligned(64))) = {0};
void ql_mixer_dma_prime(void) { dma_memcpy_blocking(ql_scr, ql_dma_prime_l2, 64u); }

void ql_mixer_setup(uint32_t cid) {
  // zeros in scratch slot 1; synthetic conv weights / gate weights (values are not the goal)
  for (uint32_t i = 0; i < QC_SLOT_F16; ++i) ((uint16_t *)ql_scr_at(1, cid))[i] = 0u;
  for (uint32_t i = cid; i < QL_CONV_K * QL_CONV_CH; i += NUM_CORES)
    ((uint16_t *)ql_conv_w)[i] = 0x3400u;  // 0.25
  for (uint32_t i = cid; i < QL_B * 3u * QL_CONV_CH; i += NUM_CORES)
    ((uint16_t *)ql_conv_state)[i] = 0u;
  for (uint32_t i = cid; i < QL_AB * QL_H; i += NUM_CORES)
    ((uint16_t *)ql_wab)[i] = 0x1400u;  // ~1/1024
#if QL_GCK && QL_CS > 1
  ql_gsync[cid] = 0u;
#endif
#if !QL_STREAM && !QL_GCHK
  // resident state: zero (finite) columns
  for (uint32_t t = 0; t < QL_T; ++t)
    for (uint32_t j = 0; j < QL_GW; ++j) {
      uint16_t *col = (uint16_t *)qc_slot(ql_buf(t), j, cid);
      for (uint32_t i = 0; i < QC_GDN_RC; ++i) col[i] = 0u;
    }
#endif
#if QL_GCHK
  ql_gchk_fill(cid);
#endif
}

// a, b: 96 weight rows (2 * value head + {a, b}) times every sequence's x. A task is one row,
// one K part (QL_AB_KP of them, so that the tasks fill the mesh) and a block of up to 8
// sequences: each 64-element chunk of the row is loaded once for the whole block. A task's
// partial sums go to the AB slots of the 4 chunks of its head (element 2 + part for a,
// 2 + QL_AB_KP + part for b); ql_chunk_pre adds the parts.

// One task, every token of the step (the x row of token j is (sequence, token)), at e16 m1: per
// 32-element chunk k the W row chunk and the tokens' x chunks load into one of two register sets
// (A: v4, v8-v11; B: v5, v12-v15) while the other set's FMAs run -- x and W are spread over the
// cluster, so the loads are remote. Token j accumulates in v16 + j.
#define QL_AB_LD(K, VW, X0, X1, X2, X3)                                                       \
  do {                                                                                        \
    __asm__ volatile("vle16.v " VW ", (%0)" ::"r"(w + (K)) : "memory");                       \
    __asm__ volatile("vle16.v " X0 ", (%0)" ::"r"(x + (K)) : "memory");                       \
    if (QL_TOK > 1) __asm__ volatile("vle16.v " X1 ", (%0)" ::"r"(x + (uint32_t)QL_X_LDX + (K)) : "memory"); \
    if (QL_TOK > 2) __asm__ volatile("vle16.v " X2 ", (%0)" ::"r"(x + 2u * QL_X_LDX + (K)) : "memory"); \
    if (QL_TOK > 3) __asm__ volatile("vle16.v " X3 ", (%0)" ::"r"(x + 3u * QL_X_LDX + (K)) : "memory"); \
  } while (0)
#define QL_AB_MAC(OP, VW, X0, X1, X2, X3)                                                     \
  do {                                                                                        \
    __asm__ volatile(OP " v16, " X0 ", " VW);                                                 \
    if (QL_TOK > 1) __asm__ volatile(OP " v17, " X1 ", " VW);                                 \
    if (QL_TOK > 2) __asm__ volatile(OP " v18, " X2 ", " VW);                                 \
    if (QL_TOK > 3) __asm__ volatile(OP " v19, " X3 ", " VW);                                 \
  } while (0)
#define QL_AB_SETA "v4", "v8", "v9", "v10", "v11"
#define QL_AB_SETB "v5", "v12", "v13", "v14", "v15"
#define QL_AB_LD_(K, ...) QL_AB_LD(K, __VA_ARGS__)
#define QL_AB_MAC_(OP, ...) QL_AB_MAC(OP, __VA_ARGS__)
#define QL_AB_RED(J, VA)                                                                      \
  if (QL_TOK > J) {                                                                           \
    __asm__ volatile("vfredusum.vs v20, " VA ", v24");                                        \
    QC_VL1("e16");                                                                            \
    __asm__ volatile("vse16.v v20, (%0)" ::"r"((uint16_t *)ql_scr_at(0, cid) + (J)) : "memory"); \
    __asm__ volatile("vsetvli zero, %0, e16, m1, ta, ma" ::"r"(QC_SLOT_F16));                 \
  }
#define QL_AB_C 32u  // elements per chunk (e16 m1)
_Static_assert(QL_AB_KLEN % (2u * QL_AB_C) == 0u, "a,b: whole chunk pairs per task");
_Static_assert((QL_AB_KLEN & (QL_AB_KLEN - 1u)) == 0u, "a,b: the start rotation wraps by a mask");
// Each task walks its K range from a start chunk hashed from cid, wrapping round. A 64 B chunk is
// one tile and the W rows are 8 KiB apart, so at a common chunk index all 96 rows (and the x rows)
// sit on a handful of tiles: in lockstep, hundreds of cores load from the same few tiles at once.
#define QL_AB_ROT(K) (((K) + rot) & (QL_AB_KLEN - 1u))
static __attribute__((noinline)) void ql_ab_round(uint32_t t, uint32_t cid) {
  const uint32_t hl = cid / (2u * QL_AB_KP), ab = (cid / QL_AB_KP) % 2u, part = cid % QL_AB_KP;
  const uint32_t h = t * QL_HEADS_PER_ROUND + hl;
  if (h * QC_GDN_RB >= QL_NC) return;
  const uint32_t b = h / QC_GDN_VH, vh = h % QC_GDN_VH, k0 = part * QL_AB_KLEN;
  const ql_elem_t *x = ql_x_at(ql_x_replica(cid), b * QL_TOK, k0);
  const ql_elem_t *w = ql_wab + (2u * vh + ab) * QL_H + k0;
  const uint32_t rot = QL_ABROT ? (((cid * 0x9E3779B1u) >> 16) * QL_AB_C) & (QL_AB_KLEN - 1u) : 0u;
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
  __asm__ volatile("vle16.v v24, (%0)" ::"r"(ql_scr_at(1, cid)) : "memory");  // zeros
  QL_AB_LD_(QL_AB_ROT(0u), QL_AB_SETA);
  QL_AB_LD_(QL_AB_ROT(QL_AB_C), QL_AB_SETB);
  QL_AB_MAC_("vfmul.vv", QL_AB_SETA);
  for (uint32_t k = 2u * QL_AB_C; k < QL_AB_KLEN; k += 2u * QL_AB_C) {
    QL_AB_LD_(QL_AB_ROT(k), QL_AB_SETA);
    QL_AB_MAC_("vfmacc.vv", QL_AB_SETB);
    QL_AB_LD_(QL_AB_ROT(k + QL_AB_C), QL_AB_SETB);
    QL_AB_MAC_("vfmacc.vv", QL_AB_SETA);
  }
  QL_AB_MAC_("vfmacc.vv", QL_AB_SETB);
  QL_AB_RED(0, "v16");
  QL_AB_RED(1, "v17");
  QL_AB_RED(2, "v18");
  QL_AB_RED(3, "v19");
  __asm__ volatile("fence" ::: "memory");
  const uint32_t slot = 2u + ab * QL_AB_KP + part;
  for (uint32_t j = 0; j < QL_TOK; ++j) {
    const uint16_t v = ((volatile uint16_t *)ql_scr_at(0, cid))[j];
    for (uint32_t i = 0; i < QC_GDN_RB * QL_CS; ++i) {  // every part of the head's 4 chunks
      const uint32_t u = h * QC_GDN_RB * QL_CS + i;
      ((uint16_t *)ql_auxt(u / NUM_CORES, j, QC_GDN_AUX_AB, u % NUM_CORES))[slot] = v;
    }
  }
}
#undef QL_AB_LD
#undef QL_AB_MAC
#undef QL_AB_ROT
#undef QL_AB_RED
_Static_assert(QL_TOK <= 4u, "a,b: at most 4 tokens per task");

void ql_mixer_run(uint32_t cid) {
  if (cid == 0) ql_t_start = mempool_get_timer();
  const qc_k_t qck = qc_k();
  qc_rne();
  // One round (QL_T = 1): state tile 0 loads under the a,b stage and the o-projection's tile 0
  // under the round (the state is needed first). Several rounds: o-proj tile 0 under the a,b stage,
  // then the state tiles one after the other.
#define QL_ST_EARLY (QL_STREAM && QL_T == 1u)
  if (cid == 0) {
    dma_wait();  // qz's last transfer (or the o-projection's tile 1)
#if QL_ST_EARLY
    dma_memcpy_nonblocking(ql_buf(0), ql_s_l2, QL_GTILE_B);
#else
    if (QL_STATE_IN_W1) op_refill_head(0);  // overlaps the a,b stage
#endif
  }
  ql_ab_round(0, cid);
  qc_barrier(cid);
  if (cid == 0) ql_t_ab = mempool_get_timer();
  {
    size_t vl;  // SiLU's constant registers, once
    __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
    QC_SET_CONST_REGS("v28", "v29");
  }
#if QL_ST_EARLY
  if (cid == 0) {
    dma_wait();  // state tile 0
    if (QL_STATE_IN_W1) op_refill_head(0);  // under the round
  }
  qc_barrier(cid);
#elif QL_STREAM
  if (cid == 0) {
    dma_wait();  // the o-projection's tile 0, if it was launched
    dma_memcpy_blocking(ql_buf(0), ql_s_l2, QL_GTILE_B);  // state tile 0, exposed
  }
  qc_barrier(cid);
#endif
  if (cid == 0) ql_t_rounds = mempool_get_timer();
  for (uint32_t t = 0; t < QL_T; ++t) {
    const uint32_t c = t * NUM_CORES + cid;  // the chunk part (= the chunk at QL_CS = 1)
#if QL_STREAM
    if (cid == 0) ql_dma_round(t);
#endif
#if QL_GCK
    if (c < QL_NU) ql_gck_part(t, cid);
#else
    if (c < QL_NC)  // the step's tokens one after the other through the state tile in L1
      for (uint32_t j = 0; j < QL_TOK; ++j) {
        ql_chunk_pre(t, j, cid);
#if QL_STREAM
        qc_gdn_chunk((uint8_t *)qc_slot(ql_buf(t), 0, cid), ql_auxt(t, j, 0, cid),
                     cid == 0 ? ql_dma_poll : 0);
#else
        qc_gdn_chunk((uint8_t *)qc_slot(ql_buf(t), 0, cid), ql_auxt(t, j, 0, cid), 0);
#endif
        *ql_ss(t, j, cid) = ql_sumsq_slots(ql_auxt(t, j, QC_GDN_AUX_O, cid), 1u, cid);
      }
#endif
    if (t + 1u < QL_T) ql_ab_round(t + 1u, cid);  // in the state DMA's shadow
    {
      size_t vl;  // back to the SiLU constants' shape
      __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
    }
#if QL_STREAM
    if (cid == 0) ql_dma_drain();
#endif
    qc_barrier(cid);
    if (QL_GCK && c < QL_NU) QC_SET_CONST_REGS("v28", "v29");  // the chunked kernel uses v16-v31
    if (c < QL_NU)
      for (uint32_t j = c % QL_CS; j < QL_TOK; j += QL_CS) ql_gated_norm(t, j, cid, &qck);
  }
#if QL_STREAM
  if (cid == 0) {
    dma_wait();  // QL_T = 1: the o-projection's tile 0 (under the round)
    dma_memcpy_blocking(ql_s_l2 + (QL_T - 1) * QL_GTILE_B, ql_buf(QL_T - 1),
                        QL_GTILE_B);  // last tile back, exposed
  }
#endif
  qc_barrier(cid);
  if (cid == 0) ql_t_end = mempool_get_timer();
}

//==============================================================================
// Value self-test (QL_GCHK): patterns in, two steps, o' against script/gen_gchk.py
//==============================================================================
#if QL_GCHK
#include "data/ql_gchk.h"
_Static_assert(QL_GCHK_B == QL_B && QL_GCHK_T == QL_TOK, "ql_gchk.h: built for another B / T");
static uint32_t ql_gchk_bad[NUM_CORES], ql_gchk_n[NUM_CORES], ql_gchk_badt[NUM_CORES][4];
static float ql_gchk_max[NUM_CORES];
static inline uint16_t ql_gchk_h(int32_t n, float scale) {
  const _Float16 h = (_Float16)((float)n * scale);
  return *(const uint16_t *)&h;
}
// q, k, v, z of every token into this core's chunk parts (all rounds).
void ql_gchk_refill(uint32_t cid) {
  for (uint32_t t = 0; t < QL_T; ++t) {
    const uint32_t u = t * NUM_CORES + cid;
    if (u >= QL_NU) break;
    const qc_gdn_id_t d = qc_gdn_id(u / QL_CS);
    const int32_t b = (int32_t)d.b, kh = (int32_t)d.kh, vh = (int32_t)d.vh;
    for (uint32_t j = 0; j < QL_TOK; ++j) {
      const int32_t jj = (int32_t)j;
      for (int32_t dd = 0; dd < (int32_t)QC_GDN_D; ++dd) {
        ((uint16_t *)ql_auxt(t, j, QC_GDN_AUX_K + (uint32_t)dd / 32u, cid))[dd % 32] =
            ql_gchk_h((7 * dd + 3 * kh + 5 * jj + b) % 17 - 8, 0.125f);
        ((uint16_t *)ql_auxt(t, j, QC_GDN_AUX_Q + (uint32_t)dd / 32u, cid))[dd % 32] =
            ql_gchk_h((5 * dd + 7 * kh + 3 * jj + 2 * b) % 15 - 7, 0.125f);
      }
      for (int32_t e = 0; e < (int32_t)QC_GDN_RC; ++e) {
        const int32_t i = (int32_t)d.rb * (int32_t)QC_GDN_RC + e;
        ((uint16_t *)ql_auxt(t, j, QC_GDN_AUX_V, cid))[e] =
            ql_gchk_h((5 * i + vh + 3 * jj + 7 * b) % 13 - 6, 0.125f);
        ((uint16_t *)ql_auxt(t, j, QL_AUX_Z, cid))[e] =
            ql_gchk_h((3 * i + 2 * vh + jj + b) % 11 - 5, 0.25f);
      }
    }
  }
  __asm__ volatile("fence" ::: "memory");
}
// The state S0 of this core's columns, x rows (b, token j) = (j - 1) / 8, and the aux inputs.
static void ql_gchk_fill(uint32_t cid) {
  for (uint32_t i = cid; i < QL_B * QL_TOK * QL_H; i += NUM_CORES) {
    const uint32_t row = i / QL_H, col = i % QL_H;
    for (uint32_t r = 0; r < (uint32_t)QL_X_REPLICAS; ++r)
      *(uint16_t *)ql_x_at(r, row, col) = ql_gchk_h((int32_t)(row % QL_TOK) - 1, 0.125f);
  }
  // the state: in L1 (streamed: through tile buffer 0, then one DMA per round -- every core
  // storing straight into L2 at once trips the GVSoC AXI model)
  for (uint32_t t = 0; t < QL_T; ++t) {
    const uint32_t u = t * NUM_CORES + cid;
    if (u < QL_NU) {
      const qc_gdn_id_t d = qc_gdn_id(u / QL_CS);
      for (uint32_t jc = 0; jc < QL_GW; ++jc) {
        const int32_t g = (int32_t)((u % QL_CS) * QL_GW + jc);
        uint16_t *col = (uint16_t *)qc_slot(ql_buf(QL_STREAM ? 0u : t), jc, cid);
        for (int32_t e = 0; e < (int32_t)QC_GDN_RC; ++e) {
          const int32_t i = (int32_t)d.rb * (int32_t)QC_GDN_RC + e;
          col[e] = ql_gchk_h((2 * i + 3 * g + (int32_t)d.vh + 5 * (int32_t)d.b) % 9 - 4, 0.0625f);
        }
      }
    }
#if QL_STREAM
    __asm__ volatile("fence" ::: "memory");
    qc_barrier(cid);
    if (cid == 0) dma_memcpy_blocking(ql_s_l2 + t * QL_GTILE_B, ql_buf(0), QL_GTILE_B);
    qc_barrier(cid);
#endif
  }
  ql_gchk_refill(cid);
}
// o' (replica 0) against the reference: |got - want| <= 5% |want| + 0.02.
// The reference is DMA'd into the (idle) W area first.
_Static_assert(sizeof(ql_gchk_ref) <= 2u * QL_WREG_ELEMS * sizeof(ql_elem_t), "gchk: ref in W");
void ql_gchk_check(uint32_t cid) {
  uint32_t bad = 0, n = 0;
  float mx = 0.0f;
  for (uint32_t j = 0; j < 4u; ++j) ql_gchk_badt[cid][j] = 0u;
  if (cid == 0) dma_memcpy_blocking(ql_w_area, ql_gchk_ref, sizeof(ql_gchk_ref));
  qc_barrier(cid);
  const uint16_t *ref = (const uint16_t *)ql_w_area;
  for (uint32_t i = cid; i < QL_B * QL_TOK * QL_VZ; i += NUM_CORES) {
    const uint32_t row = i / QL_VZ, col = i % QL_VZ;
    const float got = (float)*(const _Float16 *)ql_o_at(0, row, col);
    const float want = (float)*(const _Float16 *)&ref[i];
    const float e = got > want ? got - want : want - got, a = want > 0.0f ? want : -want;
    bad += e > 0.05f * a + 0.02f;
    if (e > 0.05f * a + 0.02f) {
      ++ql_gchk_badt[cid][row % QL_TOK];
    }
    mx = __builtin_fmaxf(mx, e);
    ++n;
  }
  ql_gchk_bad[cid] = bad;
  ql_gchk_n[cid] = n;
  ql_gchk_max[cid] = mx;
}
#endif

// The o-projection's first two tiles, when qz could not hand the stream over (state in W).
void ql_op_prime(uint32_t cid) {
#if QL_STATE_W
  if (cid == 0) {
    if (!QL_STATE_IN_W1) {
      op_refill_head(0);
      dma_wait();
    }
    op_refill_head(1);
  }
#else
  (void)cid;
#endif
}

// ---- structural checks ----------------------------------------------------------------------
uint32_t ql_check_aux(uint32_t cid) {
  uint32_t bad = 0;
  for (uint32_t t = 0; t < QL_T; ++t) {
    const uint32_t u = t * NUM_CORES + cid, c = u / QL_CS;
    if (u >= QL_NU) break;
    const qc_gdn_id_t d = qc_gdn_id(c);
    for (uint32_t j = 0; j < QC_GDN_D; ++j) {
      const uint16_t q = ((uint16_t *)ql_auxp(t, QC_GDN_AUX_Q + j / 32u, cid))[j % 32u];
      const uint16_t k = ((uint16_t *)ql_auxp(t, QC_GDN_AUX_K + j / 32u, cid))[j % 32u];
      bad += q != ql_pat(d.b, QL_COL_Q + d.kh * QC_GDN_D + j);
      bad += k != ql_pat(d.b, QL_COL_K + d.kh * QC_GDN_D + j);
    }
    for (uint32_t i = 0; i < QC_GDN_RC; ++i) {
      const uint32_t ch = d.vh * QC_GDN_D + d.rb * QC_GDN_RC + i;
      bad += ((uint16_t *)ql_auxp(t, QC_GDN_AUX_V, cid))[i] != ql_pat(d.b, QL_COL_V + ch);
      if (u % QL_CS == 0u)  // z: the part that gated-norms the token (QL_TOK = 1: part 0)
        bad += ((uint16_t *)ql_auxp(t, QL_AUX_Z, cid))[i] != ql_pat(d.b, QL_COL_Z + ch);
    }
  }
  return bad;
}
void ql_mixer_report(uint32_t cid) {
  if (cid != 0) return;
#if QL_GCHK
  {
    uint32_t bad = 0, n = 0;
    float mx = 0.0f;
    for (uint32_t c = 0; c < NUM_CORES; ++c)
      bad += ql_gchk_bad[c], n += ql_gchk_n[c], mx = __builtin_fmaxf(mx, ql_gchk_max[c]);
    uint32_t bt[4] = {0u, 0u, 0u, 0u};
    for (uint32_t c = 0; c < NUM_CORES; ++c)
      for (uint32_t j = 0; j < 4u; ++j) bt[j] += ql_gchk_badt[c][j];
    printf("[GDNB] self-test (%s, 2 steps): %s, %u of %u o' values off (per token %u %u %u %u), "
           "max |err| %d/1000\n", QL_GCK ? "chunked" : "per-token", bad ? "FAIL" : "PASS", bad, n,
           bt[0], bt[1], bt[2], bt[3], (int)(mx * 1000.0f));
  }
#endif
  printf("[GDNB] mixer T=%u %s CS=%u chunks=%u rounds=%u %s%s: total=%u ab=%u prologue=%u "
         "rounds=%u per_round=%u\n",
         QL_TOK, QL_GCK ? "chunked" : "per-token", QL_CS, QL_NC, QL_T,
         QL_STREAM ? "state streamed" : "state resident",
         QL_STATE_W ? " (in the W area)" : "", ql_t_end - ql_t_start, ql_t_ab - ql_t_start, ql_t_rounds - ql_t_ab,
         ql_t_end - ql_t_rounds, (ql_t_end - ql_t_rounds) / QL_T);
}
