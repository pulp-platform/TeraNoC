// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
// Gated-attention decode core (flash-decoding) on one 32-token block, shared by qwen-attn (the
// kernel on its own) and qwen-layer (the attention layer). docs/qwen3_8_27b/mixer_plan.md, D2.
//
// Per KV head, 6 query heads (GQA) of dim 256. Layouts, all in the core's own 64-byte tile slots:
//   K block: TRANSPOSED, row d (256) = the block's 32 tokens: scores are vfmacc.vf over tokens
//            with q[h][d] scalars (6 accumulators, one per query head), no reductions;
//   V block: row-major in 8 slices of 32 dims, slot (slice * 32 + token): the PV product is
//            vfmacc.vf over 32 dims with p[h][t] scalars.
//   With QC_ATT_KS > 1 both are split by slices over adjacent cores (below).
// Online softmax per query head: running max m and sum l in fp32 (D7), fp16 accumulator.
//
// The app defines, before including this file:
//   QC_ATT_RES  (uint8_t *) a sweep-aligned resident area (qc_layout.h), and
//   QC_ATT_K0   the first sweep of the kernel's own slots in it (QC_ATT_SW sweeps).
// q (6 heads x 8 slots, at any sweep the app passes) and the output ctx are the app's.
//
// Include it once without QC_ATT_RES for the constants, and again with it for the kernel.
#ifndef QC_ATTN_CONST_H
#define QC_ATTN_CONST_H

#include <stdint.h>

#include "qc_layout.h"

#define QC_ATT_KVH 4u                     // KV heads
#define QC_ATT_QPK 6u                     // query heads per KV head
#define QC_ATT_D 256u                     // head dim
#define QC_ATT_TB QC_SLOT_F16             // tokens per block = one slot (32)
#define QC_ATT_NSL (QC_ATT_D / QC_SLOT_F16)  // 8 slices of 32 dims
#define QC_ATT_TILE_B (QC_ATT_D * QC_SWEEP_B)  // one K or V block of every core: 256 sweeps
// The kernel's own sweeps (from QC_ATT_K0) for n tokens sharing a core's K/V tile (MTP: the
// tokens verified per step): per token acc 48 + p 6 + m/l + corr, then the zero and RED slots.
#define QC_ATT_TSW 56u
#define QC_ATT_SWT(n) (QC_ATT_TSW * (n) + 2u)
#define QC_ATT_SW QC_ATT_SWT(1u)
#endif  // QC_ATTN_CONST_H

#if defined(QC_ATT_RES) && !defined(QC_ATTN_H)
#define QC_ATTN_H
#include "qc_vec.h"

#ifndef QC_ATT_TOKS
#define QC_ATT_TOKS 1u  // tokens per core (each its own softmax state, one K/V tile)
#endif
// KV sharing: a block's K and V tiles spread over QC_ATT_KS adjacent cores, core j holding slices
// [j, j + 1) * QC_ATT_NSLC (32 dims each) at its sweeps 0.. (the kernels get the set's first core's
// tile slot and read the other slices from the neighbours' tiles, same group).
#ifndef QC_ATT_KS
#define QC_ATT_KS 1u
#endif
#define QC_ATT_NSLC (QC_ATT_NSL / QC_ATT_KS)
#define QC_ATT_SLICE_OFF(s) \
  (((s) % QC_ATT_NSLC) * QC_ATT_TB * QC_SWEEP_B + ((s) / QC_ATT_NSLC) * QC_SLOT_B)
_Static_assert(QC_ATT_NSL % QC_ATT_KS == 0, "QC_ATT_KS: whole slices per core");
// Per token tk (a variable named tk must be in scope):
#define QC_ATT_ACC (QC_ATT_K0 + (tk) * QC_ATT_TSW)  // acc[h][d]: slot h * 8 + d / 32
#define QC_ATT_P (QC_ATT_ACC + 48u)       // p[h][t]: slot h
#define QC_ATT_ML (QC_ATT_P + 6u)         // m[6], l[6] fp32 (48 B)
#define QC_ATT_CORR (QC_ATT_ML + 1u)      // corr[6] fp32
// Shared:
#define QC_ATT_ZERO (QC_ATT_K0 + QC_ATT_TOKS * QC_ATT_TSW)  // 32 zeros (qc_att_setup)
#define QC_ATT_RED (QC_ATT_ZERO + 1u)     // reduction results, element 0
_Static_assert(QC_ATT_RED + 1u - QC_ATT_K0 == QC_ATT_SWT(QC_ATT_TOKS), "QC_ATT_SWT");

static inline uint8_t *qc_att_res(uint32_t sw, uint32_t cid) {
  return (uint8_t *)qc_slot(QC_ATT_RES, sw, cid);
}
static inline float *qc_att_m(uint32_t cid, uint32_t tk) { return (float *)qc_att_res(QC_ATT_ML, cid); }
static inline float *qc_att_l(uint32_t cid, uint32_t tk) {
  return (float *)qc_att_res(QC_ATT_ML, cid) + QC_ATT_QPK;
}
static inline float *qc_att_corr(uint32_t cid, uint32_t tk) {
  return (float *)qc_att_res(QC_ATT_CORR, cid);
}
static inline void qc_att_setup(uint32_t cid) {
  for (uint32_t i = 0; i < QC_ATT_TB; ++i) ((uint16_t *)qc_att_res(QC_ATT_ZERO, cid))[i] = 0u;
}

// Element 0 of vector register REG as an fp16 scalar, through this core's own slot: a VLSU
// store then a scalar load. (vfmv.f.s right after a reduction read a stale value on GVSoC.)
#define qc_att_scalar0(REG, CID, IDX)                                                            \
  ({                                                                                          \
    /* element 0 only, into element IDX of the RED slot: per-head, per-kind slots, so a read  \
       GVSoC hands out early is at worst this head's previous value (RTL orders it). */       \
    __asm__ volatile("vsetivli zero, 1, e16, m1, ta, ma");                                    \
    __asm__ volatile("vse16.v " REG ", (%0)"                                                  \
                     ::"r"(qc_att_res(QC_ATT_RED, (CID)) + 2u * (IDX)) : "memory");            \
    __asm__ volatile("vsetvli zero, %0, e16, m1, ta, ma" ::"r"(QC_ATT_TB));                   \
    __asm__ volatile("fence" ::: "memory");                                                   \
    ((volatile _Float16 *)qc_att_res(QC_ATT_RED, (CID)))[(IDX)];                              \
  })

#ifndef QC_ATT_RED_SCALAR
#define QC_ATT_RED_SCALAR 0  // 1: block max / sum by a scalar loop over the stored vector
#endif
#if QC_ATT_RED_SCALAR
#define QC_ATT_BLOCK_MAX(VS, OUT, H)                                                                \
  do {                                                                                        \
    __asm__ volatile("vse16.v " VS ", (%0)" ::"r"(qc_att_res(QC_ATT_RED, cid)) : "memory");             \
    __asm__ volatile("fence" ::: "memory");                                                   \
    const volatile _Float16 *_e = (const volatile _Float16 *)qc_att_res(QC_ATT_RED, cid);               \
    float _m = (float)_e[0];                                                                  \
    for (uint32_t _i = 1; _i < QC_ATT_TB; ++_i) _m = __builtin_fmaxf(_m, (float)_e[_i]);         \
    (OUT) = (_Float16)_m;                                                                     \
  } while (0)
#define QC_ATT_BLOCK_SUM(VS, OUT, H)                                                                \
  do {                                                                                        \
    __asm__ volatile("vse16.v " VS ", (%0)" ::"r"(qc_att_res(QC_ATT_RED, cid)) : "memory");             \
    __asm__ volatile("fence" ::: "memory");                                                   \
    const volatile _Float16 *_e = (const volatile _Float16 *)qc_att_res(QC_ATT_RED, cid);               \
    float _s = (float)_e[0];                                                                  \
    for (uint32_t _i = 1; _i < QC_ATT_TB; ++_i) _s = _s + (float)_e[_i];                         \
    (OUT) = (_Float16)_s;                                                                     \
  } while (0)
#else
#define QC_ATT_BLOCK_MAX(VS, OUT, H)                                                                \
  do {                                                                                        \
    __asm__ volatile("vfredmax.vs v16, " VS ", " VS);                                         \
    (OUT) = qc_att_scalar0("v16", cid, (H));                                                          \
  } while (0)
#define QC_ATT_BLOCK_SUM(VS, OUT, H)                                                                \
  do {                                                                                        \
    __asm__ volatile("vfmul.vf v24, " VS ", %0" ::"f"(zero));                                 \
    __asm__ volatile("vfredusum.vs v17, " VS ", v24");                                        \
    (OUT) = qc_att_scalar0("v17", cid, 8u + (H));                                                          \
  } while (0)
#endif

//==============================================================================
// QK^T and the online softmax for one block (K tile slot of this core at kt)
//==============================================================================

// One K row (I of an 8-row group) against the 6 heads' q scalars: per-head pointers with fixed
// offsets (the heads sit 8 sweeps apart: recomputing those addresses per row -- lui + add per
// scalar -- had halved the issue rate), the K row pointer advances by one sweep.
#define QC_ATT_QK8(I, R)                                                                      \
  do {                                                                                        \
    const _Float16 a0 = q0[I], a1 = q1[I], a2 = q2[I], a3 = q3[I], a4 = q4[I], a5 = q5[I];    \
    __asm__ volatile("vle16.v " R ", (%0)" ::"r"(kr) : "memory");                             \
    QC_ATT_MAC("v0", R, a0);                                                                  \
    QC_ATT_MAC("v1", R, a1);                                                                  \
    QC_ATT_MAC("v2", R, a2);                                                                  \
    QC_ATT_MAC("v3", R, a3);                                                                  \
    QC_ATT_MAC("v4", R, a4);                                                                  \
    QC_ATT_MAC("v5", R, a5);                                                                  \
    kr += QC_SWEEP_B;                                                                         \
  } while (0)
#define QC_ATT_MUL(VD, VS, F) __asm__ volatile("vfmul.vf " VD ", " VS ", %0" ::"f"(F))
#define QC_ATT_MAC(VD, VS, F) __asm__ volatile("vfmacc.vf " VD ", %0, " VS ::"f"(F))

// Online-softmax step for head h held in register VS: scores -> p (written to QC_ATT_P slot h),
// m, l and the accumulator correction factor updated in this core's QC_ATT_ML / QC_ATT_CORR.
#define QC_ATT_SOFTMAX(VS, H)                                                                    \
  do {                                                                                        \
    _Float16 bmh, psh;                                                                        \
    __asm__ volatile("vfmul.vf " VS ", " VS ", %0" ::"f"(scale));                             \
    if (mask) __asm__ volatile("vfadd.vv " VS ", " VS ", v7"); /* causal: -1000 past t */      \
    QC_ATT_BLOCK_MAX(VS, bmh, H);                                                                   \
    const float mo = m[H], bm = (float)bmh, mn = __builtin_fmaxf(bm, mo);                           \
    const float corr = qc_exp_f32(mo - mn);                                                   \
    const _Float16 mnh = (_Float16)mn;                                                        \
    __asm__ volatile("vfsub.vf " VS ", " VS ", %0" ::"f"(mnh));                               \
    QC_EXP(VS, "v18", "v20", "v22", "v23");                                                   \
    QC_ATT_BLOCK_SUM("v20", psh, H);                                                                \
    __asm__ volatile("vse16.v v20, (%0)" ::"r"(qc_att_res(QC_ATT_P + (H), cid)) : "memory");            \
    m[H] = mn;                                                                                \
    l[H] = l[H] * corr + (float)psh;                                                          \
    cr[H] = corr;                                                                             \
  } while (0)

// Token tk's 6 query heads (at sweep qsw) against this core's K block; `mask` (or 0): 32 fp16
// added to the scaled scores -- 0 where the token may look, -1000 for later tokens of the step
// (the block holding the step's new tokens).
static __attribute__((noinline)) void qc_att_qk_softmax(const uint8_t *kt, uint32_t cid,
                                                        uint32_t qsw, uint32_t tk,
                                                        const uint8_t *mask) {
  const uint8_t *qb = qc_att_res(qsw, cid);
  const qc_k_t qck = qc_k();
  const _Float16 scale = qc_f16_imm(0x2c00u);  // 1/16 = 1/sqrt(256)
  const _Float16 zero = qc_f16_imm(0u);
  float *m = qc_att_m(cid, tk), *l = qc_att_l(cid, tk), *cr = qc_att_corr(cid, tk);
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  QC_SET_CONST_REGS("v22", "v23");
  if (mask) __asm__ volatile("vle16.v v7, (%0)" ::"r"(mask) : "memory");
  // zero the 6 accumulators from the zero slot (VLSU only)
  const uint8_t *zs = qc_att_res(QC_ATT_ZERO, cid);
  __asm__ volatile("vle16.v v0, (%0)" ::"r"(zs) : "memory");
  __asm__ volatile("vle16.v v1, (%0)" ::"r"(zs) : "memory");
  __asm__ volatile("vle16.v v2, (%0)" ::"r"(zs) : "memory");
  __asm__ volatile("vle16.v v3, (%0)" ::"r"(zs) : "memory");
  __asm__ volatile("vle16.v v4, (%0)" ::"r"(zs) : "memory");
  __asm__ volatile("vle16.v v5, (%0)" ::"r"(zs) : "memory");
  for (uint32_t s = 0; s < QC_ATT_NSL; ++s) {  // dims s*32 ..: q head h at slot h * 8 + s
    const _Float16 *q0 = (const _Float16 *)(qb + (0u * 8u + s) * QC_SWEEP_B);
    const _Float16 *q1 = (const _Float16 *)(qb + (1u * 8u + s) * QC_SWEEP_B);
    const _Float16 *q2 = (const _Float16 *)(qb + (2u * 8u + s) * QC_SWEEP_B);
    const _Float16 *q3 = (const _Float16 *)(qb + (3u * 8u + s) * QC_SWEEP_B);
    const _Float16 *q4 = (const _Float16 *)(qb + (4u * 8u + s) * QC_SWEEP_B);
    const _Float16 *q5 = (const _Float16 *)(qb + (5u * 8u + s) * QC_SWEEP_B);
    const uint8_t *kr = kt + QC_ATT_SLICE_OFF(s);
    for (uint32_t i = 0; i < QC_ATT_TB; i += 8u) {
      QC_ATT_QK8(0, "v8");
      QC_ATT_QK8(1, "v9");
      QC_ATT_QK8(2, "v8");
      QC_ATT_QK8(3, "v9");
      QC_ATT_QK8(4, "v8");
      QC_ATT_QK8(5, "v9");
      QC_ATT_QK8(6, "v8");
      QC_ATT_QK8(7, "v9");
      q0 += 8, q1 += 8, q2 += 8, q3 += 8, q4 += 8, q5 += 8;
    }
  }
  QC_ATT_SOFTMAX("v0", 0u);
  QC_ATT_SOFTMAX("v1", 1u);
  QC_ATT_SOFTMAX("v2", 2u);
  QC_ATT_SOFTMAX("v3", 3u);
  QC_ATT_SOFTMAX("v4", 4u);
  QC_ATT_SOFTMAX("v5", 5u);
}

//==============================================================================
// P V for one block (V tile slot of this core at vt): acc = acc * corr + p V
//==============================================================================

// One V row (token I of an 8-token group): as QC_ATT_QK8, with the 6 heads' p scalars.
#define QC_ATT_PV8(I, R)                                                                      \
  do {                                                                                        \
    const _Float16 b0 = p0[I], b1 = p1[I], b2 = p2[I], b3 = p3[I], b4 = p4[I], b5 = p5[I];    \
    __asm__ volatile("vle16.v " R ", (%0)" ::"r"(vr) : "memory");                             \
    QC_ATT_MAC("v0", R, b0);                                                                  \
    QC_ATT_MAC("v1", R, b1);                                                                  \
    QC_ATT_MAC("v2", R, b2);                                                                  \
    QC_ATT_MAC("v3", R, b3);                                                                  \
    QC_ATT_MAC("v4", R, b4);                                                                  \
    QC_ATT_MAC("v5", R, b5);                                                                  \
    vr += QC_SWEEP_B;                                                                         \
  } while (0)

static __attribute__((noinline)) void qc_att_pv(const uint8_t *vt, uint32_t cid, uint32_t tk) {
  const float *cr = qc_att_corr(cid, tk);
  const _Float16 c0 = (_Float16)cr[0], c1 = (_Float16)cr[1], c2 = (_Float16)cr[2];
  const _Float16 c3 = (_Float16)cr[3], c4 = (_Float16)cr[4], c5 = (_Float16)cr[5];
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  for (uint32_t s = 0; s < QC_ATT_NSL; ++s) {
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 0u * 8u + s, cid)) : "memory");
    __asm__ volatile("vle16.v v1, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 1u * 8u + s, cid)) : "memory");
    __asm__ volatile("vle16.v v2, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 2u * 8u + s, cid)) : "memory");
    __asm__ volatile("vle16.v v3, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 3u * 8u + s, cid)) : "memory");
    __asm__ volatile("vle16.v v4, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 4u * 8u + s, cid)) : "memory");
    __asm__ volatile("vle16.v v5, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 5u * 8u + s, cid)) : "memory");
    QC_ATT_MUL("v0", "v0", c0);
    QC_ATT_MUL("v1", "v1", c1);
    QC_ATT_MUL("v2", "v2", c2);
    QC_ATT_MUL("v3", "v3", c3);
    QC_ATT_MUL("v4", "v4", c4);
    QC_ATT_MUL("v5", "v5", c5);
    const _Float16 *p0 = (const _Float16 *)qc_att_res(QC_ATT_P + 0u, cid);
    const _Float16 *p1 = (const _Float16 *)qc_att_res(QC_ATT_P + 1u, cid);
    const _Float16 *p2 = (const _Float16 *)qc_att_res(QC_ATT_P + 2u, cid);
    const _Float16 *p3 = (const _Float16 *)qc_att_res(QC_ATT_P + 3u, cid);
    const _Float16 *p4 = (const _Float16 *)qc_att_res(QC_ATT_P + 4u, cid);
    const _Float16 *p5 = (const _Float16 *)qc_att_res(QC_ATT_P + 5u, cid);
    const uint8_t *vr = vt + QC_ATT_SLICE_OFF(s);
    for (uint32_t t = 0; t < QC_ATT_TB; t += 8u) {
      QC_ATT_PV8(0, "v8");
      QC_ATT_PV8(1, "v9");
      QC_ATT_PV8(2, "v8");
      QC_ATT_PV8(3, "v9");
      QC_ATT_PV8(4, "v8");
      QC_ATT_PV8(5, "v9");
      QC_ATT_PV8(6, "v8");
      QC_ATT_PV8(7, "v9");
      p0 += 8, p1 += 8, p2 += 8, p3 += 8, p4 += 8, p5 += 8;
    }
    __asm__ volatile("vse16.v v0, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 0u * 8u + s, cid)) : "memory");
    __asm__ volatile("vse16.v v1, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 1u * 8u + s, cid)) : "memory");
    __asm__ volatile("vse16.v v2, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 2u * 8u + s, cid)) : "memory");
    __asm__ volatile("vse16.v v3, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 3u * 8u + s, cid)) : "memory");
    __asm__ volatile("vse16.v v4, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 4u * 8u + s, cid)) : "memory");
    __asm__ volatile("vse16.v v5, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + 5u * 8u + s, cid)) : "memory");
  }
}

// A fresh partial: m = -inf (clamped by qc_exp_f32), l = 0, acc = 0.
static __attribute__((noinline)) void qc_att_part_reset(uint32_t cid, uint32_t tk) {
  float *m = qc_att_m(cid, tk), *l = qc_att_l(cid, tk);
  const float ninf = qc_f32_imm(0xf149f2cau), zf = qc_f32_imm(0u);  // -1e30
  for (uint32_t h = 0; h < QC_ATT_QPK; ++h) {
    m[h] = ninf;
    l[h] = zf;
  }
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  // Zeros from memory (VLSU only; no slide-unit vfmv.v.f ahead of the stores).
  __asm__ volatile("vle16.v v0, (%0)" ::"r"(qc_att_res(QC_ATT_ZERO, cid)) : "memory");
  for (uint32_t k = 0; k < 48u; ++k)
    __asm__ volatile("vse16.v v0, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + k, cid)) : "memory");
  __asm__ volatile("fence" ::: "memory");
}

//==============================================================================
// Combine the partials of a problem (pairwise tree) and normalise
//==============================================================================

// This core (part % 2s == 0) absorbs partner's partial: m = max, f = exp(m_i - m), l and acc
// scaled and added. Partner's slots are in another tile (same group up to 16 cores apart).
static __attribute__((noinline)) void qc_att_merge(uint32_t cid, uint32_t partner, uint32_t tk) {
  float *m = qc_att_m(cid, tk), *l = qc_att_l(cid, tk);
  const float *pm = qc_att_m(partner, tk), *pl = qc_att_l(partner, tk);
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  for (uint32_t h = 0; h < QC_ATT_QPK; ++h) {
    const float mn = __builtin_fmaxf(m[h], pm[h]);
    const float f1 = qc_exp_f32(m[h] - mn), f2 = qc_exp_f32(pm[h] - mn);
    l[h] = l[h] * f1 + pl[h] * f2;
    m[h] = mn;
    const _Float16 f1h = (_Float16)f1, f2h = (_Float16)f2;
    for (uint32_t s = 0; s < QC_ATT_NSL; ++s) {
      __asm__ volatile("vle16.v v0, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + h * 8u + s, cid)) : "memory");
      __asm__ volatile("vle16.v v1, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + h * 8u + s, partner)) : "memory");
      __asm__ volatile("vfmul.vf v0, v0, %0" ::"f"(f1h));
      __asm__ volatile("vfmacc.vf v0, %0, v1" ::"f"(f2h));
      __asm__ volatile("vse16.v v0, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + h * 8u + s, cid)) : "memory");
    }
  }
}

static __attribute__((noinline)) void qc_att_finish(uint32_t cid, uint32_t osw, uint32_t tk) {
  const float *l = qc_att_l(cid, tk);
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_ATT_TB));
  for (uint32_t h = 0; h < QC_ATT_QPK; ++h) {
    const _Float16 rl = (_Float16)qc_recip_f32(l[h]);
    for (uint32_t s = 0; s < QC_ATT_NSL; ++s) {
      __asm__ volatile("vle16.v v0, (%0)" ::"r"(qc_att_res(QC_ATT_ACC + h * 8u + s, cid)) : "memory");
      __asm__ volatile("vfmul.vf v0, v0, %0" ::"f"(rl));
      __asm__ volatile("vse16.v v0, (%0)" ::"r"(qc_att_res(osw + h * 8u + s, cid))
                       : "memory");
    }
  }
}

#endif  // QC_ATT_RES && !QC_ATTN_H
