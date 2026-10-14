// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
// qwen-layer attention mixer: between the in-projection (q | gate | k | v) and the o-projection.
// docs/qwen3_8_27b/mixer_plan.md, D2 / step 6.
//
//   prep    the core starting a problem (part 0) RMS-normalises its 6 query heads and applies the
//           partial RoPE (first 64 of 256 dims); the core holding the last block (last part) does
//           the same for the new token's k. Other part cores copy the prepared q.
//   rounds  flash-decoding over the problem's KV cache (qwen-common/qc_attn.h), streamed from L2
//           tile by tile through two buffers in the W area (idle between the projections); the
//           last-part core writes the new token's k and v into its last block (and into L2).
//   combine split-S partials merged in a pairwise tree; part 0 normalises, multiplies by
//           sigmoid(gate) and writes o' into every replica of the o-projection's A.
//
// KV cache layout (per round, as qwen-attn): a K tile (row d = this core's block's 32 tokens) and
// a V tile (slot s * 32 + t = dims s*32.. of token t), each one contiguous DMA.
#include <stdint.h>

#include "layer.h"
#include "../qwen-common/qc_sync.h"
#include "dma.h"
#include "printf.h"
#include "runtime.h"
#include "control_registers.h"

#define QC_ATT_RES ql_res
#define QC_ATT_K0 QL_A_RES_K0
#define QC_ATT_TOKS QL_TG
#define QC_ATT_KS QL_KS
#include "../qwen-common/qc_attn.h"

_Static_assert((QL_S % QC_ATT_TB) == 0, "S: whole 32-token blocks");
_Static_assert((QL_A_NBP % QL_A_CPP) == 0, "a problem's blocks split evenly across its cores");
_Static_assert(QL_A_NPRB <= NUM_CORES || (QL_A_NPRB % NUM_CORES) == 0, "problems per core: whole");
_Static_assert(QL_A_CPP % QL_A_SUB == 0 && QL_A_NPC % QL_A_SUB == 0 && QL_A_NSUB <= 32u &&
               QL_A_P1 <= 16u || QL_A_NSUB == 1u, "two-level split: whole sub-problems");
_Static_assert(QL_TOK % QL_TG == 0 && QL_TOK <= QC_ATT_TB, "token groups: whole, in one block");
_Static_assert(QL_KS == 1u || (QL_A_TGRP % QL_KS == 0 && NUM_TILES_PER_GROUP % QL_KS == 0),
               "KV sharing: whole token groups, a set inside one group");

#if QL_STATE_W
#define ql_kvbuf ((uint8_t *)ql_w_area)  // K tile, then V tile: idle W area
#else
static uint8_t ql_kvbuf[2u * QL_A_TILE_B] QC_L1_SWEEP;
#endif
// Sweep-aligned (a 4 KiB shift of an L2 tile source halved the GVSoC DMA rate).
static uint8_t ql_kv_l2[QL_A_T * 2u * QL_A_TILE_B] __attribute__((section(".l2_bss"), aligned(QC_SWEEP_B)));
// KV sharing: inserts of the step's new k / v done by each core (its slices of the last block);
// the set's other cores wait for them before reading the block.
static volatile uint32_t ql_ins_cnt[NUM_CORES];
// Stage timers, written by core 0 only (one L2 word stored by every core: ~1.6k cycles on RTL).
static uint32_t ql_t_start, ql_t_prep, ql_t_rounds, ql_t_comb, ql_t_end;
static uint32_t ql_bad_knew[NUM_CORES];  // check mode: the new k in the KV cache (L2) vs its slots

static inline uint8_t *ql_scr_at(uint32_t k, uint32_t cid) {
  return (uint8_t *)qc_slot(ql_scr, k, cid);
}

typedef struct {
  uint32_t b, g, p, blk, qp, t0;  // t0: the problem's first token of the step
  uint32_t kw;                    // this token group writes the step's new k / v into the cache
} ql_a_id_t;
// Core cid is token group cid % QL_KS of plane core cid / QL_KS (layer.h); a plane problem is a
// (sequence, set of QL_KS token groups, KV head).
static inline ql_a_id_t ql_a_id(uint32_t cid, uint32_t r) {
  ql_a_id_t d;
  const uint32_t v = cid / QL_KS, pv = v / QL_A_CPP + r / QL_A_RPP * (QL_A_NV / QL_A_CPP);
  const uint32_t ts = pv / QC_ATT_KVH % (QL_A_TGRP / QL_KS), tgi = ts * QL_KS + cid % QL_KS;
  d.qp = r / QL_A_RPP;
  d.g = pv % QC_ATT_KVH;
  d.b = pv / QC_ATT_KVH / (QL_A_TGRP / QL_KS);
  d.t0 = tgi * QL_TG;
  d.p = (d.b * QL_A_TGRP + tgi) * QC_ATT_KVH + d.g;
  d.blk = v % QL_A_CPP * QL_A_RPP + r % QL_A_RPP;
  d.kw = ts == 0u;
  return d;
}
static inline uint32_t ql_a_part(uint32_t cid) { return cid / QL_KS % QL_A_CPP; }

//==============================================================================
// prep: per-head RMSNorm (256 dims = 8 slots) and the partial RoPE (dims 0..63 = slots 0, 1)
//==============================================================================

// The head at slots sw0.. of core `own` (this core or another of the problem: same group),
// written to the same slots of cores d0 .. d0 + nd - 1 (every part core of the problem gets its
// own copy: one writer per head spreads the traffic over the destination tiles, where 15 readers
// of part 0's slots serialised on its tile -- 11.5k cycles). The scratch and RoPE table are this
// core's; destinations rotate with this core so the writers start on different tiles.
// Destinations are d0 + i * ds, i < nd.
#define QL_HEAD_PUT(REG, SW)                                                                  \
  for (uint32_t _i = 0; _i < nd; ++_i)                                                        \
  __asm__ volatile("vse16.v " REG ", (%0)" ::"r"(ql_resp((SW), d0 + ((_i + cid) % nd) * ds)) : "memory")
static __attribute__((noinline)) void ql_head_norm_rope(uint32_t cid, uint32_t own, uint32_t sw0,
                                                        uint32_t d0, uint32_t nd, uint32_t ds,
                                                        uint32_t rt) {  // rt: the token's RoPE
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_resp(sw0, own)) : "memory");
  __asm__ volatile("vfwmul.vv v8, v0, v0");
  for (uint32_t s = 1; s < QC_ATT_NSL; ++s) {
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_resp(sw0 + s, own)) : "memory");
    __asm__ volatile("vfwmacc.vv v8, v0, v0");
  }
  QC_VL1("e32");
  __asm__ volatile("vle32.v v12, (%0)" ::"r"(ql_scr_at(1, cid)) : "memory");  // zeros (el. 0)
  __asm__ volatile("vsetvli %0, %1, e32, m2, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  __asm__ volatile("vfredusum.vs v14, v8, v12");
  QC_VL1("e32");
  __asm__ volatile("vse32.v v14, (%0)" ::"r"(ql_scr_at(0, cid)) : "memory");
  __asm__ volatile("fence" ::: "memory");
  const float ss = *(volatile float *)ql_scr_at(0, cid);
  const _Float16 rs =
      (_Float16)qc_rsqrt_f32(ss * qc_f32_imm(0x3b800000u) + qc_f32_imm(0x358637bdu));  // /256
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  // RoPE (rotate-half over the first 64 dims): o1 = x1 c - x2 s ; o2 = x2 c + x1 s
  __asm__ volatile("vle16.v v4, (%0)" ::"r"(ql_resp(sw0, own)) : "memory");
  __asm__ volatile("vle16.v v5, (%0)" ::"r"(ql_resp(sw0 + 1u, own)) : "memory");
  __asm__ volatile("vle16.v v2, (%0)" ::"r"(ql_resp(QL_A_RES_ROPE + 2u * rt, cid)) : "memory");
  __asm__ volatile("vle16.v v3, (%0)" ::"r"(ql_resp(QL_A_RES_ROPE + 2u * rt + 1u, cid)) : "memory");
  __asm__ volatile("vfmul.vf v4, v4, %0" ::"f"(rs));
  __asm__ volatile("vfmul.vf v5, v5, %0" ::"f"(rs));
  __asm__ volatile("vfmul.vv v0, v4, v2");
  __asm__ volatile("vfnmsac.vv v0, v5, v3");
  __asm__ volatile("vfmul.vv v1, v5, v2");
  __asm__ volatile("vfmacc.vv v1, v4, v3");
  QL_HEAD_PUT("v0", sw0);
  QL_HEAD_PUT("v1", sw0 + 1u);
  for (uint32_t s = 2; s < QC_ATT_NSL; ++s) {
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_resp(sw0 + s, own)) : "memory");
    __asm__ volatile("vfmul.vf v0, v0, %0" ::"f"(rs));
    QL_HEAD_PUT("v0", sw0 + s);
  }
}
// Level 2 of the q broadcast: this core's (already normalised) head at sw0.. to cores d0 .. +nd.
static __attribute__((noinline)) void ql_head_bcast(uint32_t cid, uint32_t sw0, uint32_t d0,
                                                    uint32_t nd) {
  const uint32_t ds = QL_KS;  // the problem's part cores
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  for (uint32_t s = 0; s < QC_ATT_NSL; ++s) {
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_resp(sw0 + s, cid)) : "memory");
    QL_HEAD_PUT("v0", sw0 + s);
  }
}

//==============================================================================
// the new token into the last block (the last part core, in its last round)
//==============================================================================

// K tile row d holds the block's 32 tokens; the step's new tokens are its last QL_TOK positions.
#define QL_NEWPOS(t) (QC_ATT_TB - QL_TOK + (t))
static __attribute__((noinline)) void ql_insert_k(uint32_t cid, const ql_a_id_t *d) {
  // slot s of token t's k (dims s*32..) is column NEWPOS(t) of rows s*32..: one strided store;
  // KV sharing: this core's slices only (its tile rows (s % NSLC) * 32..)
  const uint32_t s0 = cid % QL_KS * QC_ATT_NSLC;
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  for (uint32_t t = 0; t < QL_TOK; ++t)
    for (uint32_t s = s0; s < s0 + QC_ATT_NSLC; ++s) {
      __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_resp(QL_A_RES_KNEW + (d->qp * QL_TOK + t) * 8u + s, cid)) : "memory");
      __asm__ volatile("vsse16.v v0, (%0), %1" ::"r"((uint8_t *)qc_slot(ql_kvbuf, (s - s0) * QC_ATT_TB, cid) +
                                                     QL_NEWPOS(t) * 2u),
                       "r"(QC_SWEEP_B) : "memory");
    }
}
// The new k into the L2 cache (column 31 of the last block's K tile: 256 scattered 2-byte writes),
// after the rounds and split over the problem's cores -- on one core it held up every barrier.
#define QL_KW QL_A_MIN(QL_A_CPP, 16u / QL_KS)  // writers: >= 16 dims each (no short vectors)
static __attribute__((noinline)) void ql_put_k_l2(uint32_t cid, uint32_t part) {
  if (part >= QL_KW || !ql_a_id(cid, 0).kw) return;  // one token group (set) writes the cache
  // KV sharing: each core of the set writes its own dims (its tile rows), from its plane's last core
  const uint32_t last = cid + (QL_A_CPP - 1u - part) * QL_KS, n = QC_ATT_D / QL_KS / QL_KW;
  const uint32_t d0 = cid % QL_KS * (QC_ATT_D / QL_KS);
  const uint32_t m = n < QC_ATT_TB ? n : QC_ATT_TB;
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(m));
  for (uint32_t qp = 0; qp < QL_A_PPC; ++qp) {
    const uint32_t r = qp * QL_A_RPP + QL_A_RPP - 1u;  // the round of the problem's last block
    for (uint32_t t = 0; t < QL_TOK; ++t) {
      uint8_t *l2 = ql_kv_l2 + (2u * r) * QL_A_TILE_B + last * QC_SLOT_B + QL_NEWPOS(t) * 2u -
                    d0 * QC_SWEEP_B;
      for (uint32_t dd = d0 + part * n; dd < d0 + (part + 1u) * n; dd += m) {
        __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_resp(QL_A_RES_KNEW + (qp * QL_TOK + t) * 8u + dd / 32u, last) +
                                                   (dd % 32u) * 2u)
                         : "memory");
        __asm__ volatile("vsse16.v v0, (%0), %1" ::"r"(l2 + dd * QC_SWEEP_B), "r"(QC_SWEEP_B) : "memory");
      }
    }
  }
}
// V tile slot (s * 32 + NEWPOS(t)) = dims s*32.. of the step's token t.
static __attribute__((noinline)) void ql_insert_v(uint32_t cid, const ql_a_id_t *d, uint32_t r) {
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  const uint32_t s0 = cid % QL_KS * QC_ATT_NSLC;  // KV sharing: this core's slices
  for (uint32_t t = 0; t < QL_TOK; ++t)
    for (uint32_t s = s0; s < s0 + QC_ATT_NSLC; ++s) {
      const uint32_t sw = (s - s0) * QC_ATT_TB + QL_NEWPOS(t);
      __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_resp(QL_A_RES_VNEW + (d->qp * QL_TOK + t) * 8u + s, cid)) : "memory");
      __asm__ volatile("vse16.v v0, (%0)" ::"r"(qc_slot(ql_kvbuf + QL_A_TILE_B, sw, cid)) : "memory");
      if (d->kw)  // one token group (set) writes the cache
        __asm__ volatile("vse16.v v0, (%0)" ::"r"(ql_kv_l2 + (2u * r + 1u) * QL_A_TILE_B + sw * QC_SWEEP_B +
                                                   cid * QC_SLOT_B)
                         : "memory");
    }
}

// KV sharing: the set's cores insert their slices of the last block, then wait for each other's
// before any of them reads the block (a set-local barrier, counted per insert).
static __attribute__((noinline)) void ql_ins_sync(uint32_t cid) {
  __asm__ volatile("fence" ::: "memory");  // this core's inserts (VLSU stores) have landed
  const uint32_t n = ql_ins_cnt[cid] + 1u, c0 = cid - cid % QL_KS;
  ql_ins_cnt[cid] = n;
  for (uint32_t j = 0; j < QL_KS; ++j)
    while (ql_ins_cnt[c0 + j] < n) { }
}

//==============================================================================
// o' = ctx * sigmoid(gate), into every replica of the o-projection's A
//==============================================================================

// Slices k = k0, k0 + kstep, ... of the problem's 48 (head, 32-dim) pieces: ctx (the merged
// accumulator in core `src`'s slots) / l * sigmoid(gate), into every replica of o'. Every core of
// the problem takes a share (kstep = cores per problem) -- the gate and ctx live on part 0.
static __attribute__((noinline)) void ql_gate_out(uint32_t cid, const ql_a_id_t *d, uint32_t src,
                                                  uint32_t k0, uint32_t kstep, uint32_t tk) {
  const qc_k_t qck = qc_k();
  const float *l = qc_att_l(src, tk);
  const uint32_t row = d->b * QL_TOK + d->t0 + tk;
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  QC_SET_CONST_REGS("v28", "v29");
  for (uint32_t k = k0; k < QC_ATT_QPK * QC_ATT_NSL; k += kstep) {
    const uint32_t h = k / QC_ATT_NSL, s = k % QC_ATT_NSL;
    const uint32_t col = (d->g * QC_ATT_QPK + h) * QC_ATT_D + s * QC_ATT_TB;
    if (QL_CHECK) {  // identity values instead of o'
      uint16_t *scr = (uint16_t *)ql_scr_at(0, cid);
      for (uint32_t i = 0; i < QC_ATT_TB; ++i) scr[i] = ql_pat(row, QL_PAT_O + col + i);
      __asm__ volatile("fence" ::: "memory");
      __asm__ volatile("vle16.v v6, (%0)" ::"r"(scr) : "memory");
    } else {
      const _Float16 rl = (_Float16)qc_recip_f32(l[h]);
      __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_resp(QL_A_RES_GATE + ((d->qp * QL_TG + tk) * 6u + h) * 8u + s, src)) : "memory");
      __asm__ volatile("vle16.v v1, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + h * 8u + s, src)) : "memory");
      QC_SIGMOID("v0", "v2", "v3", "v4", "v5", "v28", "v29");
      __asm__ volatile("vfmul.vf v1, v1, %0" ::"f"(rl));
      __asm__ volatile("vfmul.vv v6, v1, v5");
    }
    for (uint32_t r = 0; r < (uint32_t)QL_O_REPLICAS; ++r)
      __asm__ volatile("vse16.v v6, (%0)" ::"r"(ql_o_at(r, row, col)) : "memory");
  }
}

// Split-S combine fused with the output gate. Every core of the problem takes a contiguous share
// of the 48 (head, 32-dim slice) pieces; for each, the CPP partials (acc_j, m_j, l_j in the part
// cores' slots, same group) give ctx = sum_j f_j acc_j / L, f_j = exp(m_j - M), M = max_j m_j,
// L = sum_j f_j l_j (fp32, D7), and o' = ctx * sigmoid(gate) into every replica. One pass instead
// of a log2(CPP)-level tree with a barrier per level and a separate gate pass.
static inline _Float16 *ql_cw(uint32_t cid, uint32_t j) {  // combine weight j: scratch slots 2..
  return (_Float16 *)ql_scr_at(2u + j / QC_SLOT_F16, cid) + j % QC_SLOT_F16;
}
// Weights of n partials whose m_j, l_j (fp32) sit at mp, lp + j * stride bytes: f_j = exp(m_j - M)
// into this core's scratch; returns L = sum_j f_j l_j, and M through mx.
static __attribute__((noinline)) float ql_wts(uint32_t cid, const uint8_t *mp, const uint8_t *lp,
                                              uint32_t n, uint32_t stride, float *mx_out) {
  float mx = *(const float *)mp, sl = qc_f32_imm(0u);
  for (uint32_t j = 1; j < n; ++j) mx = __builtin_fmaxf(mx, *(const float *)(mp + j * stride));
  for (uint32_t j = 0; j < n; ++j) {
    const float e = qc_exp_f32(*(const float *)(mp + j * stride) - mx);
    *ql_cw(cid, j) = (_Float16)e;
    sl = sl + e * *(const float *)(lp + j * stride);
  }
  __asm__ volatile("fence" ::: "memory");
  *mx_out = mx;
  return sl;
}
// v1 = sum_j f_j * (32 fp16 at p + j * stride), f_j from the scratch (vl = 32 set by the caller).
static inline void ql_wsum(uint32_t cid, const uint8_t *p, uint32_t n, uint32_t stride) {
  __asm__ volatile("vle16.v v1, (%0)" ::"r"(p) : "memory");
  __asm__ volatile("vfmul.vf v1, v1, %0" ::"f"(*ql_cw(cid, 0)));
  for (uint32_t j = 1; j < n; ++j) {
    __asm__ volatile("vle16.v v2, (%0)" ::"r"(p + j * stride) : "memory");
    __asm__ volatile("vfmacc.vf v1, %0, v2" ::"f"(*ql_cw(cid, j)));
  }
}
// Level 1 of the two-level combine: the 16 part cores of a sub-problem (one group) merge their
// partials, QL_A_P1 pieces each, into their own C1 slots with the merged m, l in C1M -- every
// core busy, every load inside the group.
static __attribute__((noinline)) void ql_combine_l1(uint32_t cid, uint32_t part) {
  const uint32_t i = part % QL_A_SUB, s0 = cid - i * QL_KS;
  float *mo = (float *)ql_resp(QL_A_RES_C1M, cid), *lo = (float *)ql_resp(QL_A_RES_C1M + 1u, cid);
  float mx = qc_f32_imm(0u), sl = mx;
  uint32_t hc = ~0u;
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  for (uint32_t o = 0; o < QL_A_P1; ++o) {  // piece k: token tk, head h, slice s
    const uint32_t k = i * QL_A_P1 + o, tk = k / 48u, h = k % 48u / QC_ATT_NSL;
    const uint32_t s = k % QC_ATT_NSL;
    if (tk * QC_ATT_QPK + h != hc) {
      sl = ql_wts(cid, (const uint8_t *)&qc_att_m(s0, tk)[h], (const uint8_t *)&qc_att_l(s0, tk)[h],
                  QL_A_SUB, QL_KS * QC_SLOT_B, &mx);
      hc = tk * QC_ATT_QPK + h;
      __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
    }
    ql_wsum(cid, qc_att_res(QC_ATT_ACC + h * 8u + s, s0), QL_A_SUB, QL_KS * QC_SLOT_B);
    __asm__ volatile("vse16.v v1, (%0)" ::"r"(ql_resp(QL_A_RES_C1 + o, cid)) : "memory");
    mo[o] = mx;
    lo[o] = sl;
  }
}
#ifdef QL_COMBINE_CMP
// Debug: synthetic partials before the combine, and every combined piece compared with a flat
// fp32 recomputation over all part cores (validates the one- and two-level merges).
static uint32_t ql_bad_cmb[NUM_CORES], ql_n_cmb[NUM_CORES];
static __attribute__((noinline)) void ql_cmp_fill(uint32_t cid, uint32_t part) {
  for (uint32_t tk = 0; tk < QL_TG; ++tk) {
    float *m = qc_att_m(cid, tk), *l = qc_att_l(cid, tk);
    for (uint32_t h = 0; h < QC_ATT_QPK; ++h) {
      m[h] = qc_f32_imm(0xbe800000u) * (float)((part * 5u + h + tk) % 9u);  // -0.25 * {0..8}
      l[h] = qc_f32_imm(0x3f800000u) + qc_f32_imm(0x3f000000u) * (float)((part + h + tk) % 3u);
    }
    for (uint32_t k = 0; k < 48u; ++k) {
      _Float16 *a = (_Float16 *)qc_att_res(QC_ATT_ACC + k, cid);
      for (uint32_t e = 0; e < QC_ATT_TB; ++e)
        a[e] = (_Float16)((float)((int)((part * 7u + e * 3u + k + tk) % 17u) - 8) *
                          qc_f32_imm(0x3e000000u));
    }
  }
  __asm__ volatile("fence" ::: "memory");
}
// ctx (before the gate) of piece (tk, h, s) from v1 * rl, against the flat formula over all parts.
static __attribute__((noinline)) void ql_cmp_piece(uint32_t cid, uint32_t c0, uint32_t tk, uint32_t h, uint32_t s,
                         _Float16 rl) {
  _Float16 *got = (_Float16 *)ql_scr_at(1, cid);
  __asm__ volatile("vfmul.vf v7, v1, %0" ::"f"(rl));
  __asm__ volatile("vse16.v v7, (%0)" ::"r"(got) : "memory");
  __asm__ volatile("fence" ::: "memory");
  float mx = qc_att_m(c0, tk)[h];
  for (uint32_t j = 1; j < QL_A_CPP; ++j) mx = __builtin_fmaxf(mx, qc_att_m(c0 + j * QL_KS, tk)[h]);
  float lsum = qc_f32_imm(0u);
  for (uint32_t j = 0; j < QL_A_CPP; ++j)
    lsum = lsum + qc_exp_f32(qc_att_m(c0 + j * QL_KS, tk)[h] - mx) * qc_att_l(c0 + j * QL_KS, tk)[h];
  for (uint32_t e = 0; e < QC_ATT_TB; ++e) {
    float ref = qc_f32_imm(0u);
    for (uint32_t j = 0; j < QL_A_CPP; ++j)
      ref = ref + qc_exp_f32(qc_att_m(c0 + j * QL_KS, tk)[h] - mx) *
                      (float)((const _Float16 *)qc_att_res(QC_ATT_ACC + h * 8u + s, c0 + j * QL_KS))[e];
    ref = ref / lsum;
    const float g = (float)got[e], dd = g > ref ? g - ref : ref - g, r = ref > 0 ? ref : -ref;
    if (dd > qc_f32_imm(0x3ca3d70au) * r + qc_f32_imm(0x3a83126fu)) ++ql_bad_cmb[cid];  // 2% + 1e-3
    ++ql_n_cmb[cid];
  }
}
#endif
static __attribute__((noinline)) void ql_combine_out(uint32_t cid, uint32_t part) {
  const uint32_t c0 = cid - part * QL_KS, k0 = part * QL_A_NPC / QL_A_CPP;
  const uint32_t k1 = (part + 1u) * QL_A_NPC / QL_A_CPP;
  const ql_a_id_t d = ql_a_id(cid, 0);
  const qc_k_t qck = qc_k();
  _Float16 rl = (_Float16)qc_f32_imm(0u);
  uint32_t hc = ~0u;  // the (token, head) whose weights are in the scratch
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  QC_SET_CONST_REGS("v28", "v29");
  for (uint32_t k = k0; k < k1; ++k) {  // piece k: token tk of the group, head h, slice s
    const uint32_t tk = k / 48u, h = k % 48u / QC_ATT_NSL, s = k % QC_ATT_NSL;
    const uint32_t row = d.b * QL_TOK + d.t0 + tk;
    const uint32_t col = (d.g * QC_ATT_QPK + h) * QC_ATT_D + s * QC_ATT_TB;
    if (QL_CHECK) {  // identity values instead of o'
      uint16_t *scr = (uint16_t *)ql_scr_at(0, cid);
      for (uint32_t i = 0; i < QC_ATT_TB; ++i) scr[i] = ql_pat(row, QL_PAT_O + col + i);
      __asm__ volatile("fence" ::: "memory");
      __asm__ volatile("vle16.v v6, (%0)" ::"r"(scr) : "memory");
    } else {
      // the partials of piece k: every part core's (one level), or the sub-problems' level-1
      // results, held by core i = k / P1 of each sub-problem at slot o = k % P1 (two levels)
      const uint8_t *mp, *lp, *ap;
      uint32_t n, stride;
      if (QL_A_NSUB > 1u) {
        const uint32_t ci = c0 + k / QL_A_P1 * QL_KS, o = k % QL_A_P1;
        mp = (const uint8_t *)((const float *)ql_resp(QL_A_RES_C1M, ci) + o);
        lp = (const uint8_t *)((const float *)ql_resp(QL_A_RES_C1M + 1u, ci) + o);
        ap = ql_resp(QL_A_RES_C1 + o, ci);
        n = QL_A_NSUB;
        stride = QL_A_SUB * QL_KS * QC_SLOT_B;
      } else {
        mp = (const uint8_t *)&qc_att_m(c0, tk)[h];
        lp = (const uint8_t *)&qc_att_l(c0, tk)[h];
        ap = qc_att_res(QC_ATT_ACC + h * 8u + s, c0);
        n = QL_A_CPP;
        stride = QL_KS * QC_SLOT_B;
      }
      if (tk * QC_ATT_QPK + h != hc) {
        float mx;
        rl = (_Float16)qc_recip_f32(ql_wts(cid, mp, lp, n, stride, &mx));
        hc = tk * QC_ATT_QPK + h;
        __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
      }
      __asm__ volatile("vle16.v v0, (%0)" ::"r"(ql_resp(QL_A_RES_GATE + ((d.qp * QL_TG + tk) * 6u + h) * 8u + s, c0)) : "memory");
      QC_SIGMOID("v0", "v2", "v3", "v4", "v5", "v28", "v29");
      ql_wsum(cid, ap, n, stride);
#ifdef QL_COMBINE_CMP
      ql_cmp_piece(cid, c0, tk, h, s, rl);
      __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
#endif
      __asm__ volatile("vfmul.vf v1, v1, %0" ::"f"(rl));
      __asm__ volatile("vfmul.vv v6, v1, v5");
    }
    for (uint32_t r = 0; r < (uint32_t)QL_O_REPLICAS; ++r)
      __asm__ volatile("vse16.v v6, (%0)" ::"r"(ql_o_at(r, row, col)) : "memory");
  }
}

//==============================================================================
// setup and run
//==============================================================================

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
  ql_bad_knew[cid] = 0u;  // .bss is not cleared
  ql_ins_cnt[cid] = 0u;
  qc_att_setup(cid);  // its zero slot
  for (uint32_t i = 0; i < QC_SLOT_F16; ++i) ((uint16_t *)ql_scr_at(1, cid))[i] = 0u;
  // RoPE cos / sin per token of the step (synthetic: 0.6 / 0.8) and its causal mask on the block
  // holding the step's new tokens: token t may look at positions up to NEWPOS(t).
  for (uint32_t t = 0; t < QL_TOK; ++t)
    for (uint32_t i = 0; i < QC_SLOT_F16; ++i) {
      ((uint16_t *)ql_resp(QL_A_RES_ROPE + 2u * t, cid))[i] = 0x38cdu;
      ((uint16_t *)ql_resp(QL_A_RES_ROPE + 2u * t + 1u, cid))[i] = 0x3a66u;
      ((uint16_t *)ql_resp(QL_A_RES_MASK + t, cid))[i] = i <= QL_NEWPOS(t) ? 0u : 0xe3d0u;  // -1000
    }
}

#ifdef QL_PROF  // prep sub-timers per core: [in-proj DMA wait, norms, barrier, q copy]
static uint32_t ql_prof[NUM_CORES][4], ql_rprof[NUM_CORES][2];  // rounds: compute, wait
#define QL_PROF_AT(cid, i) (ql_prof[(cid)][(i)] = mempool_get_timer())
#else
#define QL_PROF_AT(cid, i) do { } while (0)
#endif
#ifdef QL_DBG
#define QL_STAGE(x) do { if (cid == 0 || cid == 15) printf("[DBG] core %u stage %s\n", cid, x); } while (0)
#else
#define QL_STAGE(x) do { } while (0)
#endif
void ql_mixer_run(uint32_t cid) {
  if (cid == 0) ql_t_start = mempool_get_timer();
  QL_STAGE("start");
  QL_DBG_STAGE(cid, 1);
  qc_rne();
  const uint32_t active = cid < QL_A_ACTIVE, part = ql_a_part(cid);
  const uint32_t c0 = cid - part * QL_KS;  // the problem's part 0 (its parts are QL_KS apart)
  if (cid == 0) {  // the in-projection's last transfer, then K tile 0 under the prep
    dma_wait();
    dma_memcpy_nonblocking(ql_kvbuf, ql_kv_l2, QL_A_TILE_B);
  }
  QL_DBG_STAGE(cid, 40);
  QL_PROF_AT(cid, 0);

  // ---- prep: q at part 0, the new k at the last part --------------------------------------
  if (active) {
    const uint32_t t0 = ql_a_id(cid, 0).t0;
    for (uint32_t qp = 0; qp < QL_A_PPC; ++qp) {
      // part hh: q head hh = (token j of the group) * 6 + h, normalised from part 0's slots
      for (uint32_t hh = part; hh < QL_TG * QC_ATT_QPK; hh += QL_A_CPP) {
        const uint32_t sw = QL_A_RES_Q + (qp * QL_TG * QC_ATT_QPK + hh) * 8u;
        const uint32_t rt = t0 + hh / QC_ATT_QPK;
        // to every part core (one level), or to core hh % SUB of every sub-problem (two levels)
        if (QL_A_NSUB > 1u)
          ql_head_norm_rope(cid, c0, sw, c0 + hh % QL_A_SUB * QL_KS, QL_A_NSUB, QL_A_SUB * QL_KS, rt);
        else
          ql_head_norm_rope(cid, c0, sw, c0, QL_A_CPP, QL_KS, rt);
        QL_DBG_STAGE(cid, 41 + hh);
      }
      // the step's new k (every token: the last block holds all of them), core CPP-1-t, into
      // the last part core's slots
      const uint32_t lastc = c0 + (QL_A_CPP - 1u) * QL_KS;
      for (uint32_t t = 0; t < QL_TOK; ++t)
        if (part == QL_A_CPP - 1u - t % QL_A_CPP)
          ql_head_norm_rope(cid, lastc, QL_A_RES_KNEW + (qp * QL_TOK + t) * 8u, lastc, 1u, 1u, t);
    }
  }
  QL_STAGE("prep done");
  QL_DBG_STAGE(cid, 2);
  QL_PROF_AT(cid, 1);
  qc_barrier(cid);
  if (QL_A_NSUB > 1u && active) {  // level 2, inside each group: core j fans out heads j, j+SUB..
    const uint32_t j = part % QL_A_SUB;
    for (uint32_t qp = 0; qp < QL_A_PPC; ++qp)
      for (uint32_t hh = j; hh < QL_TG * QC_ATT_QPK; hh += QL_A_SUB)
        ql_head_bcast(cid, QL_A_RES_Q + (qp * QL_TG * QC_ATT_QPK + hh) * 8u, cid - j * QL_KS, QL_A_SUB);
  }
  QL_PROF_AT(cid, 2);
  QL_STAGE("prep barrier");
  QL_DBG_STAGE(cid, 3);
  QL_PROF_AT(cid, 3);
  if (cid == 0) dma_wait();  // K tile 0
  qc_barrier(cid);
  QL_STAGE("tile 0 in");
  QL_DBG_STAGE(cid, 4);
  if (cid == 0) ql_t_prep = mempool_get_timer();

  // ---- rounds: K tile, then V tile; the DMA brings tile i+1 during tile i -------------------
#ifdef QL_PROF
  uint32_t tr = mempool_get_timer();
  ql_rprof[cid][0] = ql_rprof[cid][1] = 0u;
#endif
  for (uint32_t i = 0; i < 2u * QL_A_T; ++i) {
    if (cid == 0 && i + 1u < 2u * QL_A_T)
      dma_memcpy_nonblocking(ql_kvbuf + ((i + 1u) & 1u) * QL_A_TILE_B,
                             ql_kv_l2 + (i + 1u) * QL_A_TILE_B, QL_A_TILE_B);
    const uint32_t r = i / 2u, kvc = cid - cid % QL_KS;  // kvc: the K/V set's first core
    if (active) {
      const ql_a_id_t d = ql_a_id(cid, r);
      const uint32_t last = d.blk == QL_A_NBP - 1u;
      // the group's tokens one after the other on the tile in L1 (one K/V stream for all)
      if ((i & 1u) == 0u) {
        if (last) ql_insert_k(cid, &d);
        if (QL_KS > 1u && last) ql_ins_sync(cid);
        for (uint32_t j = 0; j < QL_TG; ++j) {
          if (r % QL_A_RPP == 0u) qc_att_part_reset(cid, j);
          qc_att_qk_softmax((uint8_t *)qc_slot(ql_kvbuf, 0, kvc), cid,
                            QL_A_RES_Q + (d.qp * QL_TG + j) * 48u, j,
                            last ? ql_resp(QL_A_RES_MASK + d.t0 + j, cid) : 0);
        }
      } else {
        if (last) ql_insert_v(cid, &d, r);
        if (QL_KS > 1u && last) ql_ins_sync(cid);
        for (uint32_t j = 0; j < QL_TG; ++j) {
          qc_att_pv((uint8_t *)qc_slot(ql_kvbuf + QL_A_TILE_B, 0, kvc), cid, j);
          if (QL_A_CPP == 1u && r % QL_A_RPP == QL_A_RPP - 1u) ql_gate_out(cid, &d, cid, 0u, 1u, j);
        }
      }
    }
    QL_STAGE("sub-round computed");
    QL_DBG_STAGE(cid, 5 + i);
#ifdef QL_PROF
    const uint32_t tc = mempool_get_timer();
#endif
    if (cid == 0) dma_wait();
    qc_barrier(cid);
#ifdef QL_PROF
    const uint32_t tw = mempool_get_timer();
    ql_rprof[cid][0] += tc - tr, ql_rprof[cid][1] += tw - tc, tr = tw;
#endif
  }
  if (active) ql_put_k_l2(cid, part);
  qc_barrier(cid);
#if QL_CHECK
  if (active && part == QL_A_CPP - 1u) {  // the last round's K tile: column 31 = the new k
    const ql_a_id_t d = ql_a_id(cid, QL_A_T - 1u);
    const uint8_t *l2 = ql_kv_l2 + 2u * (QL_A_T - 1u) * QL_A_TILE_B + cid * QC_SLOT_B + (QC_ATT_TB - 1u) * 2u;
    uint32_t bad = 0;
    for (uint32_t dd = 0; dd < QC_ATT_D; ++dd)
      bad += *(const volatile uint16_t *)(l2 + dd * QC_SWEEP_B) !=
             ((const uint16_t *)ql_resp(QL_A_RES_KNEW + d.qp * 8u + dd / 32u, cid))[dd % 32u];
    ql_bad_knew[cid] = bad;
  }
#endif
  QL_STAGE("rounds done");
  QL_DBG_STAGE(cid, 20);
  if (cid == 0) ql_t_rounds = mempool_get_timer();

  // ---- split-S partials: one flat pass over all parts, fused with the gate -----------------
  // The KV buffers are dead: the o-projection's tile 0 loads under the combine.
  if (cid == 0) op_refill_head(0);
  QL_DBG_STAGE(cid, 21);
  if (cid == 0) ql_t_comb = mempool_get_timer();
#ifdef QL_COMBINE_CMP
  ql_bad_cmb[cid] = ql_n_cmb[cid] = 0u;
  if (active) ql_cmp_fill(cid, part);
  qc_barrier(cid);
#endif
  if (QL_A_NSUB > 1u) {  // level 1 inside each group, then the cross-group pass below
    if (active) ql_combine_l1(cid, part);
    qc_barrier(cid);
  }
  if (QL_A_CPP > 1u && active) ql_combine_out(cid, part);
  qc_barrier(cid);
  QL_DBG_STAGE(cid, 22);
  if (cid == 0) ql_t_end = mempool_get_timer();
}

// The KV tiles used the W area: the o-projection's tile 0 loaded under the combine, tile 1 now.
void ql_op_prime(uint32_t cid) {
  if (cid == 0) {
    dma_wait();
    op_refill_head(1);
  }
}

// After the in-projection: q, gate at part 0 and the new k, v at the last part hold the pattern.
uint32_t ql_check_aux(uint32_t cid) {
  uint32_t bad = 0;
  if (cid >= QL_A_ACTIVE) return 0;
  const uint32_t part = ql_a_part(cid);
  for (uint32_t qp = 0; qp < QL_A_PPC; ++qp) {
    const ql_a_id_t d = ql_a_id(cid, qp * QL_A_RPP);
    for (uint32_t dd = 0; dd < QC_ATT_D; ++dd) {
      if (part == 0u)
        for (uint32_t h = 0; h < QC_ATT_QPK; ++h) {
          const uint32_t hq = d.g * QC_ATT_QPK + h, sw = (qp * QC_ATT_QPK + h) * 8u + dd / 32u;
          bad += ((uint16_t *)ql_resp(QL_A_RES_Q + sw, cid))[dd % 32u] !=
                 ql_pat(d.b, hq * QC_ATT_D + dd);
          bad += ((uint16_t *)ql_resp(QL_A_RES_GATE + sw, cid))[dd % 32u] !=
                 ql_pat(d.b, QL_A_COL_G + hq * QC_ATT_D + dd);
        }
      if (part == QL_A_CPP - 1u) {
        const uint32_t sw = qp * 8u + dd / 32u;
        bad += ((uint16_t *)ql_resp(QL_A_RES_KNEW + sw, cid))[dd % 32u] !=
               ql_pat(d.b, QL_A_COL_K + d.g * QC_ATT_D + dd);
        bad += ((uint16_t *)ql_resp(QL_A_RES_VNEW + sw, cid))[dd % 32u] !=
               ql_pat(d.b, QL_A_COL_V + d.g * QC_ATT_D + dd);
      }
    }
  }
  return bad;
}

void ql_mixer_report(uint32_t cid) {
  if (cid != 0) return;
#ifdef QL_COMBINE_CMP
  {
    uint32_t bad = 0, n = 0;
    for (uint32_t c = 0; c < NUM_CORES; ++c) bad += ql_bad_cmb[c], n += ql_n_cmb[c];
    printf("[ATTL] combine self-test (%s): %s, %u of %u values off\n",
           QL_A_NSUB > 1u ? "two-level" : "one-level", bad ? "FAIL" : "PASS", bad, n);
  }
#endif
#if QL_CHECK
  uint32_t bk = 0;
  for (uint32_t c = 0; c < NUM_CORES; ++c) bk += ql_bad_knew[c];
  printf("[ATTL] check: new k in the KV cache %s (%u mismatches)\n", bk ? "FAIL" : "PASS", bk);
#endif
#ifdef QL_PROF
  for (uint32_t c = 0; c < 16u && c < NUM_CORES; ++c)
    printf("[ATTP] core %u: wait_in=%u norms=%u barrier=%u copy=%u\n", c, ql_prof[c][0] - ql_t_start,
           ql_prof[c][1] - ql_prof[c][0], ql_prof[c][2] - ql_prof[c][1], ql_prof[c][3] - ql_prof[c][2]);
  for (uint32_t c = 0; c < 16u && c < NUM_CORES; c += 5u)
    printf("[ATTP] core %u rounds: compute=%u wait=%u\n", c, ql_rprof[c][0], ql_rprof[c][1]);
#endif
  printf("[ATTL] mixer S=%u T=%u TG=%u KS=%u problems=%u cores/problem=%u rounds=%u%s: total=%u prep=%u "
         "rounds=%u per_round=%u combine+gate=%u kv_bytes=%u\n",
         QL_S, QL_TOK, QL_TG, QL_KS, QL_A_NPRB, QL_A_CPP, QL_A_T,
         QL_STATE_W ? " (KV tiles in the W area)" : "",
         ql_t_end - ql_t_start, ql_t_prep - ql_t_start, ql_t_rounds - ql_t_prep,
         (ql_t_rounds - ql_t_prep) / QL_A_T, ql_t_end - ql_t_rounds,
         QL_A_NPRB / QL_KS * QL_S * QC_ATT_D * 4u);
}
