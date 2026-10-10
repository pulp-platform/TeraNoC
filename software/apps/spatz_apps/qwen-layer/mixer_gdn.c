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
// Chunk c is on core c % NUM_CORES in round c / NUM_CORES (qc_gdn.h). The state is streamed from
// L2 (QL_STREAM=1, mixer_plan D1) or resident in L1 -- the same scheme as qwen-gdn.
#include <stdint.h>

#include "layer.h"
#include "../qwen-common/qc_sync.h"
#include "../qwen-common/qc_vec.h"
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

// a, b: round t's chunks belong to 64 value-head instances (b, vh) = head h = t * 64 + j; each
// needs a = x_b . w[2 vh] and b = x_b . w[2 vh + 1]. 64 heads x {a, b} x QL_AB_KP K parts = 256
// tasks, one per core: task cid of round t+1 runs in round t after the core's own chunk, while
// the state DMA is still busy (the rounds are DMA-bound); round 0's run up front. The partial
// sums go to the AB slots of the head's 4 chunks (element 2 + part for a, 2 + KP + part for b).
#define QL_AB_KP (NUM_CORES / (2u * NUM_CORES / QC_GDN_RB))  // 2
#define QL_AB_KLEN (QL_H / QL_AB_KP)
#define QL_HEADS_PER_ROUND (NUM_CORES / QC_GDN_RB)
_Static_assert(QL_AB_KP * 2u * QL_HEADS_PER_ROUND == NUM_CORES, "one a,b task per core");
_Static_assert(2u + 2u * QL_AB_KP <= QC_SLOT_F16, "AB slot: alpha, beta and the partial sums");
#if QL_STREAM
static uint8_t ql_s_l2[QL_T * QC_GDN_TILE_B] __attribute__((section(".l2_bss"), aligned(4096)));
#endif
static ql_elem_t ql_wab[QL_AB * QL_H] __attribute__((section(".l1_prio"), aligned(64)));
static uint32_t ql_t_start, ql_t_ab, ql_t_rounds, ql_t_end;

static inline uint8_t *ql_buf(uint32_t t) { return ql_s + (t % QL_NBUF) * QC_GDN_TILE_B; }
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
  dma_memcpy_nonblocking(ql_dq[ql_dq_i].dst, ql_dq[ql_dq_i].src, QC_GDN_TILE_B);
  ++ql_dq_i;
}
static void ql_dma_poll(void) {
  if (ql_dq_i < ql_dq_n && dma_done()) ql_dma_launch();
}
static void ql_dma_drain(void) {
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
    ql_dq[ql_dq_n++] = (ql_xfer_t){ql_s_l2 + (t - 1) * QC_GDN_TILE_B, ql_buf(t - 1)};
  if (t + 1 < QL_T)
    ql_dq[ql_dq_n++] = (ql_xfer_t){ql_buf(t + 1), ql_s_l2 + (t + 1) * QC_GDN_TILE_B};
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

static void ql_scale_slots(uint8_t *slot0, uint32_t n_slots, _Float16 s) {
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
  for (uint32_t k = 0; k < n_slots; ++k) {
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(slot0 + k * QC_SWEEP_B) : "memory");
    __asm__ volatile("vfmul.vf v0, v0, %0" ::"f"(s));
    __asm__ volatile("vse16.v v0, (%0)" ::"r"(slot0 + k * QC_SWEEP_B) : "memory");
  }
}

// Chunk inputs: q, k normalised; alpha, beta from the raw a, b.
static __attribute__((noinline)) void ql_chunk_pre(uint32_t t, uint32_t j, uint32_t cid) {
  const float eps = qc_f32_imm(0x358637bdu);           // 1e-6
  const float rs128 = qc_f32_imm(0x3db504f3u);         // 1/sqrt(128)
  uint8_t *q = ql_auxt(t, j, QC_GDN_AUX_Q, cid), *k = ql_auxt(t, j, QC_GDN_AUX_K, cid);
  const float sq = ql_sumsq_slots(q, QC_GDN_D / QC_SLOT_F16, cid);
  const float sk = ql_sumsq_slots(k, QC_GDN_D / QC_SLOT_F16, cid);
  ql_scale_slots(q, QC_GDN_D / QC_SLOT_F16, (_Float16)(qc_rsqrt_f32(sq + eps) * rs128));
  ql_scale_slots(k, QC_GDN_D / QC_SLOT_F16, (_Float16)qc_rsqrt_f32(sk + eps));
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
  ab[0] = (_Float16)alpha;
  ab[1] = (_Float16)(rb * sel);
}

// The 4 chunks of a value head are cores (cid & ~3) .. +3: o' = o * rsqrt(mean o^2) * SiLU(z),
// into every replica of the o-projection's A.
// Token j of the step: o' row b * QL_TOK + j.
static __attribute__((noinline)) void ql_gated_norm(uint32_t t, uint32_t j, uint32_t cid,
                                                    const qc_k_t *kp) {
  const qc_k_t qck = *kp;
  const uint32_t c = t * NUM_CORES + cid;
  const qc_gdn_id_t d = qc_gdn_id(c);
  const uint32_t base = cid & ~3u;
  const float ss = *ql_ss(t, j, base) + *ql_ss(t, j, base + 1u) + *ql_ss(t, j, base + 2u) +
                   *ql_ss(t, j, base + 3u);
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

// The DMA's last transfer (dma.h defines non-inline functions: one translation unit only).
void ql_mixer_dma_wait(void) { dma_wait(); }

void ql_mixer_setup(uint32_t cid) {
  // zeros in scratch slot 1; synthetic conv weights / gate weights (values are not the goal)
  for (uint32_t i = 0; i < QC_SLOT_F16; ++i) ((uint16_t *)ql_scr_at(1, cid))[i] = 0u;
  for (uint32_t i = cid; i < QL_CONV_K * QL_CONV_CH; i += NUM_CORES)
    ((uint16_t *)ql_conv_w)[i] = 0x3400u;  // 0.25
  for (uint32_t i = cid; i < QL_B * 3u * QL_CONV_CH; i += NUM_CORES)
    ((uint16_t *)ql_conv_state)[i] = 0u;
  for (uint32_t i = cid; i < QL_AB * QL_H; i += NUM_CORES)
    ((uint16_t *)ql_wab)[i] = 0x1400u;  // ~1/1024
#if !QL_STREAM
  // resident state: zero (finite) columns
  for (uint32_t t = 0; t < QL_T; ++t)
    for (uint32_t j = 0; j < QC_GDN_D; ++j) {
      uint16_t *col = (uint16_t *)qc_slot(ql_buf(t), j, cid);
      for (uint32_t i = 0; i < QC_GDN_RC; ++i) col[i] = 0u;
    }
#endif
}

// a, b: 96 weight rows (2 * value head + {a, b}) times every sequence's x. A task is one row,
// one K part (QL_AB_KP of them, so that the tasks fill the mesh) and a block of up to 8
// sequences: each 64-element chunk of the row is loaded once for the whole block. A task's
// partial sums go to the AB slots of the 4 chunks of its head (element 2 + part for a,
// 2 + QL_AB_KP + part for b); ql_chunk_pre adds the parts.

static __attribute__((noinline)) void ql_ab_one(uint32_t t, uint32_t j, uint32_t cid);
// Every token of the step: the task's row of x is (sequence, token).
static __attribute__((noinline)) void ql_ab_round(uint32_t t, uint32_t cid) {
  for (uint32_t j = 0; j < QL_TOK; ++j) ql_ab_one(t, j, cid);
}
static __attribute__((noinline)) void ql_ab_one(uint32_t t, uint32_t j, uint32_t cid) {
  const uint32_t hl = cid / (2u * QL_AB_KP), ab = (cid / QL_AB_KP) % 2u, part = cid % QL_AB_KP;
  const uint32_t h = t * QL_HEADS_PER_ROUND + hl;
  if (h * QC_GDN_RB >= QL_NC) return;
  const uint32_t b = h / QC_GDN_VH, vh = h % QC_GDN_VH, k0 = part * QL_AB_KLEN;
  const ql_elem_t *x = ql_x_at(ql_x_replica(cid), b * QL_TOK + j, k0);
  const ql_elem_t *w = ql_wab + (2u * vh + ab) * QL_H + k0;
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m4, ta, ma" : "=r"(vl) : "r"(128u));
  __asm__ volatile("vle16.v v0, (%0)" ::"r"(x) : "memory");
  __asm__ volatile("vle16.v v4, (%0)" ::"r"(w) : "memory");
  __asm__ volatile("vfmul.vv v16, v0, v4");
  for (uint32_t k = 128; k < QL_AB_KLEN; k += 256u) {
    __asm__ volatile("vle16.v v8, (%0)" ::"r"(x + k) : "memory");
    __asm__ volatile("vle16.v v12, (%0)" ::"r"(w + k) : "memory");
    if (k + 128u < QL_AB_KLEN) {
      __asm__ volatile("vle16.v v0, (%0)" ::"r"(x + k + 128u) : "memory");
      __asm__ volatile("vle16.v v4, (%0)" ::"r"(w + k + 128u) : "memory");
    }
    __asm__ volatile("vfmacc.vv v16, v8, v12");
    if (k + 128u < QL_AB_KLEN) __asm__ volatile("vfmacc.vv v16, v0, v4");
  }
  QC_VL1("e16");
  __asm__ volatile("vle16.v v24, (%0)" ::"r"(ql_scr_at(1, cid)) : "memory");  // zeros (el. 0)
  __asm__ volatile("vsetvli %0, %1, e16, m4, ta, ma" : "=r"(vl) : "r"(128u));
  __asm__ volatile("vfredusum.vs v20, v16, v24");
  QC_VL1("e16");
  __asm__ volatile("vse16.v v20, (%0)" ::"r"(ql_scr_at(0, cid)) : "memory");
  __asm__ volatile("fence" ::: "memory");
  const uint16_t v = *(volatile uint16_t *)ql_scr_at(0, cid);
  const uint32_t slot = 2u + ab * QL_AB_KP + part;
  for (uint32_t rb = 0; rb < QC_GDN_RB; ++rb) {
    const uint32_t c = h * QC_GDN_RB + rb;
    ((uint16_t *)ql_auxt(c / NUM_CORES, j, QC_GDN_AUX_AB, c % NUM_CORES))[slot] = v;
  }
}

void ql_mixer_run(uint32_t cid) {
  ql_t_start = mempool_get_timer();
  const qc_k_t qck = qc_k();
  qc_rne();
  if (cid == 0) {
    dma_wait();  // qz's last transfer (or the o-projection's tile 1)
    if (QL_STATE_IN_W1) op_refill_head(0);  // overlaps the a,b stage
  }
  ql_ab_round(0, cid);
  qc_barrier(cid);
  ql_t_ab = mempool_get_timer();
  {
    size_t vl;  // SiLU's constant registers, once
    __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
    QC_SET_CONST_REGS("v28", "v29");
  }
#if QL_STREAM
  if (cid == 0) {
    dma_wait();  // the o-projection's tile 0, if it was launched
    dma_memcpy_blocking(ql_buf(0), ql_s_l2, QC_GDN_TILE_B);  // state tile 0, exposed
  }
  qc_barrier(cid);
#endif
  ql_t_rounds = mempool_get_timer();
  for (uint32_t t = 0; t < QL_T; ++t) {
    const uint32_t c = t * NUM_CORES + cid;
#if QL_STREAM
    if (cid == 0) ql_dma_round(t);
#endif
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
    if (t + 1u < QL_T) ql_ab_round(t + 1u, cid);  // in the state DMA's shadow
    {
      size_t vl;  // back to the SiLU constants' shape
      __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
    }
#if QL_STREAM
    if (cid == 0) ql_dma_drain();
#endif
    qc_barrier(cid);
    if (c < QL_NC)
      for (uint32_t j = 0; j < QL_TOK; ++j) ql_gated_norm(t, j, cid, &qck);
  }
#if QL_STREAM
  if (cid == 0)
    dma_memcpy_blocking(ql_s_l2 + (QL_T - 1) * QC_GDN_TILE_B, ql_buf(QL_T - 1),
                        QC_GDN_TILE_B);  // last tile back, exposed
#endif
  qc_barrier(cid);
  ql_t_end = mempool_get_timer();
}

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
    const uint32_t c = t * NUM_CORES + cid;
    if (c >= QL_NC) break;
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
      bad += ((uint16_t *)ql_auxp(t, QL_AUX_Z, cid))[i] != ql_pat(d.b, QL_COL_Z + ch);
    }
  }
  return bad;
}
void ql_mixer_report(uint32_t cid) {
  if (cid != 0) return;
  printf("[GDNB] mixer T=%u chunks=%u rounds=%u %s%s: total=%u ab=%u prologue=%u rounds=%u "
         "per_round=%u\n",
         QL_TOK, QL_NC, QL_T, QL_STREAM ? "state streamed" : "state resident",
         QL_STATE_W ? " (in the W area)" : "", ql_t_end - ql_t_start, ql_t_ab - ql_t_start, ql_t_rounds - ql_t_ab,
         ql_t_end - ql_t_rounds, (ql_t_end - ql_t_rounds) / QL_T);
}
