// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
// Gated DeltaNet delta-rule step on one CHUNK (docs/qwen3_8_27b/mixer_plan.md, section 4),
// shared by qwen-gdn (the kernel on its own) and qwen-gdn-block (the whole mixer block).
//
// Per sequence and value head the state S is 128 x 128 fp16 (rows i = value dims, columns j =
// key dims); 3 value heads share a key head. A chunk is 32 rows of one value head:
//
//     pred_i = s_i . k ;  c_i = beta (v_i - alpha pred_i) ;  s_i <- alpha s_i + c_i k ;
//     o_i    = s_i . q
//
// The chunk is COLUMN-MAJOR in the core's own 64-byte tile slots: column j = this core's slot of
// sweep j of a state tile, so every vector access stays in the core's own tile. Vectors run over
// the 32 rows, k_j / q_j are scalars (vfmacc.vf), no reductions. Inputs and output sit in the
// core's slots of an aux area (QC_GDN_AUX_*, one sweep each).
#ifndef QC_GDN_H
#define QC_GDN_H

#include <stddef.h>
#include <stdint.h>

#include "qc_layout.h"

#define QC_GDN_KH 16u                          // key heads
#define QC_GDN_VPK 3u                          // value heads per key head
#define QC_GDN_VH (QC_GDN_KH * QC_GDN_VPK)     // 48 value heads
#define QC_GDN_D 128u                          // head dim, dk = dv
#define QC_GDN_RC QC_SLOT_F16                  // rows per chunk = one tile slot (32)
#define QC_GDN_RB (QC_GDN_D / QC_GDN_RC)       // row blocks per head (4)
#define QC_GDN_CPS (QC_GDN_VH * QC_GDN_RB)     // chunks per sequence (192)
#define QC_GDN_TILE_B (QC_GDN_D * QC_SWEEP_B)  // one state tile: column j of every core at sweep j

// aux sweeps (this core's slot in each)
#define QC_GDN_AUX_V 0u   // v_i, the chunk's 32 rows
#define QC_GDN_AUX_O 1u   // o_i out
#define QC_GDN_AUX_K 2u   // k, 128 = 4 slots
#define QC_GDN_AUX_Q 6u   // q, 4 slots
#define QC_GDN_AUX_AB 10u // alpha (element 0), beta (element 1)
#define QC_GDN_AUX_PP 11u // chunked form: this core's partial S0 k_t (its columns)
#define QC_GDN_AUX_PR 12u // and S0 q_t
#define QC_GDN_AUX_SW 13u // sweeps the kernel uses; apps may add their own after these

#ifndef QC_GDN_POLL_COLS
#define QC_GDN_POLL_COLS 16u  // `poll` (if any) is called every this many columns
#endif

// Chunk c of a step: sequence b, key head kh, value head vh = kh * 3 + vs, row block rb.
typedef struct {
  uint32_t b, kh, vh, rb;
} qc_gdn_id_t;
static inline qc_gdn_id_t qc_gdn_id(uint32_t c) {
  qc_gdn_id_t d;
  d.rb = c % QC_GDN_RB;
  const uint32_t vs = (c / QC_GDN_RB) % QC_GDN_VPK;
  d.kh = (c / (QC_GDN_RB * QC_GDN_VPK)) % QC_GDN_KH;
  d.b = c / QC_GDN_CPS;
  d.vh = d.kh * QC_GDN_VPK + vs;
  return d;
}

#ifndef QC_HOST  // host generators need only the constants above
// s: column 0 of this core's chunk (its slot in sweep 0 of the tile); aux: this core's slot in
// the round's aux sweep 0. Registers (e16 m1, vl = 32): v0-v3 pred partial sums, v4-v7 o
// partial sums, v8-v11 state columns, v16 c, v17 v.
static __attribute__((noinline)) void qc_gdn_chunk(uint8_t *s, uint8_t *aux, void (*poll)(void)) {
  const _Float16 *ab = (const _Float16 *)(aux + QC_GDN_AUX_AB * QC_SWEEP_B);
  const _Float16 alpha = ab[0], beta = ab[1];
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_GDN_RC));
  // No accumulator is zeroed: the first column group starts each sum with vfmul (FPU only; no
  // slide-unit vfmv.v.f ahead of the FMAs).

  // ---- pass 1: pred = S k -----------------------------------------------------------------
#define QC_GDN_P1_LOAD()                                                                         \
  const _Float16 *kk = (const _Float16 *)(aux + (QC_GDN_AUX_K + j / QC_GDN_RC) * QC_SWEEP_B) + j % QC_GDN_RC; \
  const _Float16 k0 = kk[0], k1 = kk[1], k2 = kk[2], k3 = kk[3];                             \
  __asm__ volatile("vle16.v v8, (%0)" ::"r"(p) : "memory");                                   \
  __asm__ volatile("vle16.v v9, (%0)" ::"r"(p + QC_SWEEP_B) : "memory");                      \
  __asm__ volatile("vle16.v v10, (%0)" ::"r"(p + 2 * QC_SWEEP_B) : "memory");                 \
  __asm__ volatile("vle16.v v11, (%0)" ::"r"(p + 3 * QC_SWEEP_B) : "memory")
  uint8_t *p = s;
  {
    const uint32_t j = 0;
    QC_GDN_P1_LOAD();
    __asm__ volatile("vfmul.vf v0, v8, %0" ::"f"(k0));
    __asm__ volatile("vfmul.vf v1, v9, %0" ::"f"(k1));
    __asm__ volatile("vfmul.vf v2, v10, %0" ::"f"(k2));
    __asm__ volatile("vfmul.vf v3, v11, %0" ::"f"(k3));
    p += 4 * QC_SWEEP_B;
  }
  for (uint32_t j = 4; j < QC_GDN_D; j += 4) {
    QC_GDN_P1_LOAD();
    __asm__ volatile("vfmacc.vf v0, %0, v8" ::"f"(k0));
    __asm__ volatile("vfmacc.vf v1, %0, v9" ::"f"(k1));
    __asm__ volatile("vfmacc.vf v2, %0, v10" ::"f"(k2));
    __asm__ volatile("vfmacc.vf v3, %0, v11" ::"f"(k3));
    p += 4 * QC_SWEEP_B;
    if (poll && (j + 4) % QC_GDN_POLL_COLS == 0) poll();
  }
#undef QC_GDN_P1_LOAD
  __asm__ volatile("vfadd.vv v0, v0, v1");
  __asm__ volatile("vfadd.vv v2, v2, v3");
  __asm__ volatile("vfadd.vv v0, v0, v2");
  // c = beta (v - alpha pred)
  __asm__ volatile("vle16.v v17, (%0)" ::"r"(aux + QC_GDN_AUX_V * QC_SWEEP_B) : "memory");
  __asm__ volatile("vfnmsac.vf v17, %0, v0" ::"f"(alpha));
  __asm__ volatile("vfmul.vf v16, v17, %0" ::"f"(beta));

  // ---- pass 2: S = alpha S + c k^T ; o = S q ---------------------------------------------
  // Two register sets (v8-v11, v12-v15) alternate between 4-column groups, so a group's loads
  // never overwrite registers the previous group's o-FMAs still read.
#define QC_GDN_P2(OOP, R0, R1, R2, R3)                                                           \
  do {                                                                                        \
    const uint32_t off = (j / QC_GDN_RC) * QC_SWEEP_B;                                          \
    const _Float16 *kk = (const _Float16 *)(aux + QC_GDN_AUX_K * QC_SWEEP_B + off) + j % QC_GDN_RC;    \
    const _Float16 *qq = (const _Float16 *)(aux + QC_GDN_AUX_Q * QC_SWEEP_B + off) + j % QC_GDN_RC;    \
    const _Float16 k0 = kk[0], k1 = kk[1], k2 = kk[2], k3 = kk[3];                           \
    const _Float16 q0 = qq[0], q1 = qq[1], q2 = qq[2], q3 = qq[3];                           \
    __asm__ volatile("vle16.v " R0 ", (%0)" ::"r"(p) : "memory");                             \
    __asm__ volatile("vle16.v " R1 ", (%0)" ::"r"(p + QC_SWEEP_B) : "memory");                \
    __asm__ volatile("vle16.v " R2 ", (%0)" ::"r"(p + 2 * QC_SWEEP_B) : "memory");            \
    __asm__ volatile("vle16.v " R3 ", (%0)" ::"r"(p + 3 * QC_SWEEP_B) : "memory");            \
    __asm__ volatile("vfmul.vf " R0 ", " R0 ", %0" ::"f"(alpha));                            \
    __asm__ volatile("vfmul.vf " R1 ", " R1 ", %0" ::"f"(alpha));                            \
    __asm__ volatile("vfmul.vf " R2 ", " R2 ", %0" ::"f"(alpha));                            \
    __asm__ volatile("vfmul.vf " R3 ", " R3 ", %0" ::"f"(alpha));                            \
    __asm__ volatile("vfmacc.vf " R0 ", %0, v16" ::"f"(k0));                                  \
    __asm__ volatile("vfmacc.vf " R1 ", %0, v16" ::"f"(k1));                                  \
    __asm__ volatile("vfmacc.vf " R2 ", %0, v16" ::"f"(k2));                                  \
    __asm__ volatile("vfmacc.vf " R3 ", %0, v16" ::"f"(k3));                                  \
    __asm__ volatile("vse16.v " R0 ", (%0)" ::"r"(p) : "memory");                             \
    __asm__ volatile("vse16.v " R1 ", (%0)" ::"r"(p + QC_SWEEP_B) : "memory");                \
    __asm__ volatile("vse16.v " R2 ", (%0)" ::"r"(p + 2 * QC_SWEEP_B) : "memory");            \
    __asm__ volatile("vse16.v " R3 ", (%0)" ::"r"(p + 3 * QC_SWEEP_B) : "memory");            \
    OOP(R0, R1, R2, R3);                                                                      \
    p += 4 * QC_SWEEP_B;                                                                      \
    j += 4;                                                                                   \
  } while (0)
#define QC_GDN_O_FIRST(R0, R1, R2, R3)                                                           \
  do {                                                                                        \
    __asm__ volatile("vfmul.vf v4, " R0 ", %0" ::"f"(q0));                                    \
    __asm__ volatile("vfmul.vf v5, " R1 ", %0" ::"f"(q1));                                    \
    __asm__ volatile("vfmul.vf v6, " R2 ", %0" ::"f"(q2));                                    \
    __asm__ volatile("vfmul.vf v7, " R3 ", %0" ::"f"(q3));                                    \
  } while (0)
#define QC_GDN_O_ACC(R0, R1, R2, R3)                                                             \
  do {                                                                                        \
    __asm__ volatile("vfmacc.vf v4, %0, " R0 ::"f"(q0));                                      \
    __asm__ volatile("vfmacc.vf v5, %0, " R1 ::"f"(q1));                                      \
    __asm__ volatile("vfmacc.vf v6, %0, " R2 ::"f"(q2));                                      \
    __asm__ volatile("vfmacc.vf v7, %0, " R3 ::"f"(q3));                                      \
  } while (0)
  p = s;
  {
    uint32_t j = 0;
    QC_GDN_P2(QC_GDN_O_FIRST, "v8", "v9", "v10", "v11");
    QC_GDN_P2(QC_GDN_O_ACC, "v12", "v13", "v14", "v15");
    for (; j < QC_GDN_D;) {
      QC_GDN_P2(QC_GDN_O_ACC, "v8", "v9", "v10", "v11");
      QC_GDN_P2(QC_GDN_O_ACC, "v12", "v13", "v14", "v15");
      if (poll && j % QC_GDN_POLL_COLS == 0) poll();
    }
  }
#undef QC_GDN_P2
#undef QC_GDN_O_FIRST
#undef QC_GDN_O_ACC
  __asm__ volatile("vfadd.vv v4, v4, v5");
  __asm__ volatile("vfadd.vv v6, v6, v7");
  __asm__ volatile("vfadd.vv v4, v4, v6");
  __asm__ volatile("vse16.v v4, (%0)" ::"r"(aux + QC_GDN_AUX_O * QC_SWEEP_B) : "memory");
#ifdef QC_GDN_DBG_FENCE
  __asm__ volatile("fence" ::: "memory");
#endif
}


#endif  // QC_HOST

#endif  // QC_GDN_H

// Include again with QC_GDN_NT defined (the tokens per state pass) for the chunked kernels.
#if defined(QC_GDN_NT) && !defined(QC_HOST) && !defined(QC_GDN_CK_H)
#define QC_GDN_CK_H
//==============================================================================
// Chunked form: QC_GDN_NT tokens (MTP: the tokens verified in one step) through ONE pass over
// the state, optionally with the chunk's 128 columns split over QC_GDN_NT-independent `cs`
// adjacent cores (each holds w = 128 / cs columns, global j0..). With Gamma_t = prod_{u<=t} alpha_u
// and r(s,t) = Gamma_t / Gamma_s = prod_{s<u<=t} alpha_u, the per-token recurrence above is
//
//   P_t = S0 k^_t ,  R_t = S0 q^_t                                       (phase A, all columns)
//   c_t = beta_t (v_t - Gamma_t P_t - sum_{s<t} r(s,t) (k^_s . k^_t) c_s)
//   o_t = Gamma_t R_t + sum_{s<=t} r(s,t) (k^_s . q^_t) c_s
//   S   = Gamma_last S0 + sum_s r(s,last) c_s k^_s^T                       (phase C, own columns)
//
// k^ = k / |k|, q^ = q / |q| / sqrt(128): the L2 norms are folded into the scalar coefficients,
// so k and q are used raw (no rescaling pass). Per column: phase A 2 NT FMAs, phase C NT + 1, on
// 32 rows (the per-token form: 4 NT). The partial P / R of the cs column parts are summed
// through their aux slots (the app synchronises the parts between the two calls).
// aux: token 0's slot of aux sweep 0; token t's is at aux + t * astr. Registers (e16 m1):
// P_t v0-v3, R_t v4-v7, columns v8-v11, c_t v16-v19.
_Static_assert(QC_GDN_NT >= 1 && QC_GDN_NT <= 4, "QC_GDN_NT: 1..4 tokens");

#define QC_CK_LDK(T, G) const _Float16 k##T = *(const _Float16 *)(aux + (T) * astr + kofs + (G))
#define QC_CK_LDQ(T, G) const _Float16 q##T = *(const _Float16 *)(aux + (T) * astr + qofs + (G))
// phase A, one column in register VS (first column: vfmul; then vfmacc)
#define QC_CK_A_COL(VS, FIRST)                                                                \
  do {                                                                                        \
    const uint32_t g = j0 + j, gofs = (g / QC_GDN_RC) * QC_SWEEP_B + (g % QC_GDN_RC) * 2u;     \
    const uint32_t kofs = QC_GDN_AUX_K * QC_SWEEP_B, qofs = QC_GDN_AUX_Q * QC_SWEEP_B;           \
    QC_CK_LDK(0, gofs); QC_CK_LDQ(0, gofs);                                                   \
    _Float16 k1 = k0, q1 = q0, k2 = k0, q2 = q0, k3 = k0, q3 = q0;                             \
    if (QC_GDN_NT > 1) { k1 = *(const _Float16 *)(aux + astr + kofs + gofs);                   \
                         q1 = *(const _Float16 *)(aux + astr + qofs + gofs); }                 \
    if (QC_GDN_NT > 2) { k2 = *(const _Float16 *)(aux + 2u * astr + kofs + gofs);              \
                         q2 = *(const _Float16 *)(aux + 2u * astr + qofs + gofs); }            \
    if (QC_GDN_NT > 3) { k3 = *(const _Float16 *)(aux + 3u * astr + kofs + gofs);              \
                         q3 = *(const _Float16 *)(aux + 3u * astr + qofs + gofs); }            \
    __asm__ volatile("vle16.v " VS ", (%0)" ::"r"(s + j * QC_SWEEP_B) : "memory");            \
    if (FIRST) {                                                                              \
      __asm__ volatile("vfmul.vf v0, " VS ", %0" ::"f"(k0));                                  \
      __asm__ volatile("vfmul.vf v4, " VS ", %0" ::"f"(q0));                                  \
      if (QC_GDN_NT > 1) { __asm__ volatile("vfmul.vf v1, " VS ", %0" ::"f"(k1));             \
                           __asm__ volatile("vfmul.vf v5, " VS ", %0" ::"f"(q1)); }           \
      if (QC_GDN_NT > 2) { __asm__ volatile("vfmul.vf v2, " VS ", %0" ::"f"(k2));             \
                           __asm__ volatile("vfmul.vf v6, " VS ", %0" ::"f"(q2)); }           \
      if (QC_GDN_NT > 3) { __asm__ volatile("vfmul.vf v3, " VS ", %0" ::"f"(k3));             \
                           __asm__ volatile("vfmul.vf v7, " VS ", %0" ::"f"(q3)); }           \
    } else {                                                                                  \
      __asm__ volatile("vfmacc.vf v0, %0, " VS ::"f"(k0));                                    \
      __asm__ volatile("vfmacc.vf v4, %0, " VS ::"f"(q0));                                    \
      if (QC_GDN_NT > 1) { __asm__ volatile("vfmacc.vf v1, %0, " VS ::"f"(k1));               \
                           __asm__ volatile("vfmacc.vf v5, %0, " VS ::"f"(q1)); }             \
      if (QC_GDN_NT > 2) { __asm__ volatile("vfmacc.vf v2, %0, " VS ::"f"(k2));               \
                           __asm__ volatile("vfmacc.vf v6, %0, " VS ::"f"(q2)); }             \
      if (QC_GDN_NT > 3) { __asm__ volatile("vfmacc.vf v3, %0, " VS ::"f"(k3));               \
                           __asm__ volatile("vfmacc.vf v7, %0, " VS ::"f"(q3)); }             \
    }                                                                                         \
    (void)k1; (void)q1; (void)k2; (void)q2; (void)k3; (void)q3;                               \
  } while (0)

// Phase A: this core's partial P_t, R_t (raw k, q) into its own aux PP / PR slots of token t.
static __attribute__((noinline)) void qc_gdn_ck_pr(const uint8_t *s, uint32_t w, uint32_t j0,
                                                   uint8_t *aux, uint32_t astr) {
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_GDN_RC));
  uint32_t j = 0;
  QC_CK_A_COL("v8", 1);
  for (j = 1; j < w; j += 2) {
    QC_CK_A_COL("v9", 0);
    if (j + 1 < w) { ++j; QC_CK_A_COL("v8", 0); --j; }
  }
#define QC_CK_ST(T, VP, VR)                                                                   \
  if (QC_GDN_NT > T) {                                                                        \
    __asm__ volatile("vse16.v " VP ", (%0)" ::"r"(aux + (T) * astr + QC_GDN_AUX_PP * QC_SWEEP_B) : "memory"); \
    __asm__ volatile("vse16.v " VR ", (%0)" ::"r"(aux + (T) * astr + QC_GDN_AUX_PR * QC_SWEEP_B) : "memory"); \
  }
  QC_CK_ST(0, "v0", "v4");
  QC_CK_ST(1, "v1", "v5");
  QC_CK_ST(2, "v2", "v6");
  QC_CK_ST(3, "v3", "v7");
#undef QC_CK_ST
}

// 4 slots (128 fp16) of token T's aux sweep SW into registers R0..R3
#define QC_CK_LD4(T, SW, R0, R1, R2, R3)                                                      \
  do {                                                                                        \
    const uint8_t *_b = aux + (T) * astr + (SW) * QC_SWEEP_B;                                 \
    __asm__ volatile("vle16.v " R0 ", (%0)" ::"r"(_b) : "memory");                            \
    __asm__ volatile("vle16.v " R1 ", (%0)" ::"r"(_b + QC_SWEEP_B) : "memory");               \
    __asm__ volatile("vle16.v " R2 ", (%0)" ::"r"(_b + 2u * QC_SWEEP_B) : "memory");          \
    __asm__ volatile("vle16.v " R3 ", (%0)" ::"r"(_b + 3u * QC_SWEEP_B) : "memory");          \
  } while (0)
// 32 lane partial sums of the 128-element product of A0..3 and B0..3 into scratch row IDX (one
// sweep each); the rows are summed column-wise afterwards (no reductions, no LMUL switch).
// The product register rotates over v0-v7 by row (a store's source is never the next FMA's
// destination: GVSoC orders a VLSU read after a later FPU write).
#define QC_CK_DOT(A0, A1, A2, A3, B0, B1, B2, B3, IDX)                                        \
  do {                                                                                        \
    switch ((IDX) % 8u) {                                                                     \
      case 0: QC_CK_DOTR("v0", A0, A1, A2, A3, B0, B1, B2, B3, IDX); break;                   \
      case 1: QC_CK_DOTR("v1", A0, A1, A2, A3, B0, B1, B2, B3, IDX); break;                   \
      case 2: QC_CK_DOTR("v2", A0, A1, A2, A3, B0, B1, B2, B3, IDX); break;                   \
      case 3: QC_CK_DOTR("v3", A0, A1, A2, A3, B0, B1, B2, B3, IDX); break;                   \
      case 4: QC_CK_DOTR("v4", A0, A1, A2, A3, B0, B1, B2, B3, IDX); break;                   \
      case 5: QC_CK_DOTR("v5", A0, A1, A2, A3, B0, B1, B2, B3, IDX); break;                   \
      case 6: QC_CK_DOTR("v6", A0, A1, A2, A3, B0, B1, B2, B3, IDX); break;                   \
      default: QC_CK_DOTR("v7", A0, A1, A2, A3, B0, B1, B2, B3, IDX); break;                  \
    }                                                                                         \
  } while (0)
#define QC_CK_DOTR(VD, A0, A1, A2, A3, B0, B1, B2, B3, IDX)                                   \
  do {                                                                                        \
    __asm__ volatile("vfmul.vv " VD ", " A0 ", " B0);                                         \
    __asm__ volatile("vfmacc.vv " VD ", " A1 ", " B1);                                        \
    __asm__ volatile("vfmacc.vv " VD ", " A2 ", " B2);                                        \
    __asm__ volatile("vfmacc.vv " VD ", " A3 ", " B3);                                        \
    __asm__ volatile("vse16.v " VD ", (%0)" ::"r"(scr + (IDX) * QC_SWEEP_B) : "memory");      \
  } while (0)
// scratch rows / dots: kk(s,t) = t (t + 1) / 2 + s, qq(t) = 10 + t, kq(s,t) = 14 + t (t + 1) / 2 + s
#define QC_CK_KK(S, T) ((T) * ((T) + 1u) / 2u + (S))
#define QC_CK_QQ(T) (10u + (T))
#define QC_CK_KQ(S, T) (14u + (T) * ((T) + 1u) / 2u + (S))
#define QC_CK_NDOT 24u  // rows of the NT = 4 layout (fewer tokens leave rows unused)

// Phase B + C. part: this core's column part (of cs, adjacent cores: the partials of part p are
// (p - part) slots away); own: bit t set = this core writes o_t (aux O of token t); ab: alpha_t,
// beta_t (fp32, [2t], [2t+1]); scr: this core's slot of QC_CK_NDOT + 1 scratch sweeps; zero: a
// zero slot (unused).
static __attribute__((noinline)) void qc_gdn_ck_out(uint8_t *s, uint32_t w, uint32_t j0,
                                                    uint8_t *aux, uint32_t astr, uint32_t cs,
                                                    uint32_t part, uint32_t own, const float *ab,
                                                    uint8_t *scr, const uint8_t *zero) {
  (void)zero;
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_GDN_RC));
  // ---- 1. dot products of the raw k, q: k_t in v16 + 4t .. + 3, q_t in v8 .. v11 -------------
  QC_CK_LD4(0, QC_GDN_AUX_K, "v16", "v17", "v18", "v19");
  if (QC_GDN_NT > 1) QC_CK_LD4(1, QC_GDN_AUX_K, "v20", "v21", "v22", "v23");
  if (QC_GDN_NT > 2) QC_CK_LD4(2, QC_GDN_AUX_K, "v24", "v25", "v26", "v27");
  if (QC_GDN_NT > 3) QC_CK_LD4(3, QC_GDN_AUX_K, "v28", "v29", "v30", "v31");
#define QC_CK_QDOTS(T)                                                                        \
  if (QC_GDN_NT > T) {                                                                        \
    QC_CK_LD4(T, QC_GDN_AUX_Q, "v8", "v9", "v10", "v11");                                     \
    QC_CK_DOT("v8", "v9", "v10", "v11", "v8", "v9", "v10", "v11", QC_CK_QQ(T));               \
    QC_CK_DOT("v16", "v17", "v18", "v19", "v8", "v9", "v10", "v11", QC_CK_KQ(0u, T));         \
    if (T > 0) QC_CK_DOT("v20", "v21", "v22", "v23", "v8", "v9", "v10", "v11", QC_CK_KQ(1u, T)); \
    if (T > 1) QC_CK_DOT("v24", "v25", "v26", "v27", "v8", "v9", "v10", "v11", QC_CK_KQ(2u, T)); \
    if (T > 2) QC_CK_DOT("v28", "v29", "v30", "v31", "v8", "v9", "v10", "v11", QC_CK_KQ(3u, T)); \
  }
  QC_CK_QDOTS(0);
  QC_CK_QDOTS(1);
  QC_CK_QDOTS(2);
  QC_CK_QDOTS(3);
#undef QC_CK_QDOTS
#define QC_CK_KG0 "v16", "v17", "v18", "v19"
#define QC_CK_KG1 "v20", "v21", "v22", "v23"
#define QC_CK_KG2 "v24", "v25", "v26", "v27"
#define QC_CK_KG3 "v28", "v29", "v30", "v31"
#define QC_CK_DOTK(GA, GB, IDX) QC_CK_DOT_(GA, GB, IDX)
#define QC_CK_DOT_(...) QC_CK_DOT(__VA_ARGS__)
  QC_CK_DOTK(QC_CK_KG0, QC_CK_KG0, QC_CK_KK(0u, 0u));
  if (QC_GDN_NT > 1) {
    QC_CK_DOTK(QC_CK_KG0, QC_CK_KG1, QC_CK_KK(0u, 1u));
    QC_CK_DOTK(QC_CK_KG1, QC_CK_KG1, QC_CK_KK(1u, 1u));
  }
  if (QC_GDN_NT > 2) {
    QC_CK_DOTK(QC_CK_KG0, QC_CK_KG2, QC_CK_KK(0u, 2u));
    QC_CK_DOTK(QC_CK_KG1, QC_CK_KG2, QC_CK_KK(1u, 2u));
    QC_CK_DOTK(QC_CK_KG2, QC_CK_KG2, QC_CK_KK(2u, 2u));
  }
  if (QC_GDN_NT > 3) {
    QC_CK_DOTK(QC_CK_KG0, QC_CK_KG3, QC_CK_KK(0u, 3u));
    QC_CK_DOTK(QC_CK_KG1, QC_CK_KG3, QC_CK_KK(1u, 3u));
    QC_CK_DOTK(QC_CK_KG2, QC_CK_KG3, QC_CK_KK(2u, 3u));
    QC_CK_DOTK(QC_CK_KG3, QC_CK_KG3, QC_CK_KK(3u, 3u));
  }
  // column sums of the rows: lane i of the 32 strided loads = row i
  __asm__ volatile("vsetvli zero, %0, e16, m1, ta, ma" ::"r"(QC_CK_NDOT));
  __asm__ volatile("vlse16.v v12, (%0), %1" ::"r"(scr), "r"(QC_SWEEP_B) : "memory");
  for (uint32_t c = 1; c + 1u < QC_GDN_RC; c += 2u) {
    __asm__ volatile("vlse16.v v13, (%0), %1" ::"r"(scr + 2u * c), "r"(QC_SWEEP_B) : "memory");
    __asm__ volatile("vlse16.v v14, (%0), %1" ::"r"(scr + 2u * (c + 1u)), "r"(QC_SWEEP_B) : "memory");
    __asm__ volatile("vfadd.vv v12, v12, v13");
    __asm__ volatile("vfadd.vv v12, v12, v14");
  }
  __asm__ volatile("vlse16.v v13, (%0), %1" ::"r"(scr + 2u * (QC_GDN_RC - 1u)), "r"(QC_SWEEP_B) : "memory");
  __asm__ volatile("vfadd.vv v12, v12, v13");
  __asm__ volatile("vse16.v v12, (%0)" ::"r"(scr + QC_CK_NDOT * QC_SWEEP_B) : "memory");
  __asm__ volatile("fence" ::: "memory");
  const volatile _Float16 *dt = (const volatile _Float16 *)(scr + QC_CK_NDOT * QC_SWEEP_B);

  // ---- 2. scalar coefficients (fp32, then fp16 for the .vf operands) -----------------------
  const float eps = qc_f32_imm(0x358637bdu), rs128 = qc_f32_imm(0x3db504f3u);
  float nk[QC_GDN_NT], gam[QC_GDN_NT];
  _Float16 ca[QC_GDN_NT], cb[QC_GDN_NT], cbeta[QC_GDN_NT], cg[QC_GDN_NT];
  _Float16 ce[QC_GDN_NT * QC_GDN_NT], cf[QC_GDN_NT * QC_GDN_NT];
  for (uint32_t t = 0; t < QC_GDN_NT; ++t) {
    nk[t] = qc_rsqrt_f32((float)dt[QC_CK_KK(t, t)] + eps);
    gam[t] = (t ? gam[t - 1u] : qc_f32_imm(0x3f800000u)) * ab[2u * t];
  }
  for (uint32_t t = 0; t < QC_GDN_NT; ++t) {
    const float nq = qc_rsqrt_f32((float)dt[QC_CK_QQ(t)] + eps) * rs128;
    ca[t] = (_Float16)(gam[t] * nk[t]);
    cb[t] = (_Float16)(gam[t] * nq);
    cbeta[t] = (_Float16)ab[2u * t + 1u];
    float r = qc_f32_imm(0x3f800000u);  // r(s, t), s = t down to 0
    for (uint32_t s1 = t + 1u; s1-- > 0;) {
      cf[s1 * QC_GDN_NT + t] = (_Float16)(r * nk[s1] * nq * (float)dt[QC_CK_KQ(s1, t)]);
      if (s1 < t) ce[s1 * QC_GDN_NT + t] = (_Float16)(r * nk[s1] * nk[t] * (float)dt[QC_CK_KK(s1, t)]);
      r = r * ab[2u * s1];
    }
  }
  {
    float r = qc_f32_imm(0x3f800000u);  // r(s, last)
    for (uint32_t s1 = QC_GDN_NT; s1-- > 0;) {
      cg[s1] = (_Float16)(r * nk[s1]);
      r = r * ab[2u * s1];
    }
  }
  const _Float16 glast = (_Float16)gam[QC_GDN_NT - 1u];

  // ---- 3. P_t, R_t: the cs parts' partials summed ----------------------------------------
  __asm__ volatile("vsetvli zero, %0, e16, m1, ta, ma" ::"r"(QC_GDN_RC));
#define QC_CK_SUM(T, VP, VR)                                                                  \
  if (QC_GDN_NT > T) {                                                                        \
    uint8_t *_p = aux + (T) * astr + QC_GDN_AUX_PP * QC_SWEEP_B - part * QC_SLOT_B;           \
    __asm__ volatile("vle16.v " VP ", (%0)" ::"r"(_p) : "memory");                            \
    __asm__ volatile("vle16.v " VR ", (%0)" ::"r"(_p + QC_SWEEP_B) : "memory");               \
    for (uint32_t _q = 1; _q < cs; ++_q) {                                                    \
      __asm__ volatile("vle16.v v8, (%0)" ::"r"(_p + _q * QC_SLOT_B) : "memory");             \
      __asm__ volatile("vle16.v v9, (%0)" ::"r"(_p + QC_SWEEP_B + _q * QC_SLOT_B) : "memory"); \
      __asm__ volatile("vfadd.vv " VP ", " VP ", v8");                                        \
      __asm__ volatile("vfadd.vv " VR ", " VR ", v9");                                        \
    }                                                                                         \
  }
  _Static_assert(QC_GDN_AUX_PR == QC_GDN_AUX_PP + 1u, "PP, PR adjacent");
  QC_CK_SUM(0, "v0", "v4");
  QC_CK_SUM(1, "v1", "v5");
  QC_CK_SUM(2, "v2", "v6");
  QC_CK_SUM(3, "v3", "v7");
#undef QC_CK_SUM

  // ---- 4. c_t (v16 + t) and this core's o_t ------------------------------------------------
#define QC_CK_C(T, VP, VC)                                                                    \
  if (QC_GDN_NT > T) {                                                                        \
    __asm__ volatile("vle16.v " VC ", (%0)" ::"r"(aux + (T) * astr + QC_GDN_AUX_V * QC_SWEEP_B) : "memory"); \
    __asm__ volatile("vfnmsac.vf " VC ", %0, " VP ::"f"(ca[T]));                              \
    if (T > 0) __asm__ volatile("vfnmsac.vf " VC ", %0, v16" ::"f"(ce[0u * QC_GDN_NT + (T)])); \
    if (T > 1) __asm__ volatile("vfnmsac.vf " VC ", %0, v17" ::"f"(ce[1u * QC_GDN_NT + (T)])); \
    if (T > 2) __asm__ volatile("vfnmsac.vf " VC ", %0, v18" ::"f"(ce[2u * QC_GDN_NT + (T)])); \
    __asm__ volatile("vfmul.vf " VC ", " VC ", %0" ::"f"(cbeta[T]));                          \
  }
  QC_CK_C(0, "v0", "v16");
  QC_CK_C(1, "v1", "v17");
  QC_CK_C(2, "v2", "v18");
  QC_CK_C(3, "v3", "v19");
#undef QC_CK_C
#define QC_CK_O(T, VR)                                                                        \
  if (QC_GDN_NT > T && (own >> (T) & 1u)) {                                                   \
    __asm__ volatile("vfmul.vf v12, " VR ", %0" ::"f"(cb[T]));                                \
    __asm__ volatile("vfmacc.vf v12, %0, v16" ::"f"(cf[0u * QC_GDN_NT + (T)]));               \
    if (T > 0) __asm__ volatile("vfmacc.vf v12, %0, v17" ::"f"(cf[1u * QC_GDN_NT + (T)]));    \
    if (T > 1) __asm__ volatile("vfmacc.vf v12, %0, v18" ::"f"(cf[2u * QC_GDN_NT + (T)]));    \
    if (T > 2) __asm__ volatile("vfmacc.vf v12, %0, v19" ::"f"(cf[3u * QC_GDN_NT + (T)]));    \
    __asm__ volatile("vse16.v v12, (%0)" ::"r"(aux + (T) * astr + QC_GDN_AUX_O * QC_SWEEP_B) : "memory"); \
  }
  QC_CK_O(0, "v4");
  QC_CK_O(1, "v5");
  QC_CK_O(2, "v6");
  QC_CK_O(3, "v7");
#undef QC_CK_O
  // c~_s = r(s, last) / |k_s| c_s, for the update with the raw k_s
  __asm__ volatile("vfmul.vf v16, v16, %0" ::"f"(cg[0]));
  if (QC_GDN_NT > 1) __asm__ volatile("vfmul.vf v17, v17, %0" ::"f"(cg[QC_GDN_NT > 1 ? 1 : 0]));
  if (QC_GDN_NT > 2) __asm__ volatile("vfmul.vf v18, v18, %0" ::"f"(cg[QC_GDN_NT > 2 ? 2 : 0]));
  if (QC_GDN_NT > 3) __asm__ volatile("vfmul.vf v19, v19, %0" ::"f"(cg[QC_GDN_NT > 3 ? 3 : 0]));

  // ---- 5. phase C: S[:, j] = Gamma_last S0[:, j] + sum_s k_s[j] c~_s (own columns) ---------
#define QC_CK_C_COL(VS)                                                                       \
  do {                                                                                        \
    const uint32_t g = j0 + j, gofs = (g / QC_GDN_RC) * QC_SWEEP_B + (g % QC_GDN_RC) * 2u;     \
    const uint32_t kofs = QC_GDN_AUX_K * QC_SWEEP_B;                                           \
    QC_CK_LDK(0, gofs);                                                                       \
    _Float16 k1 = k0, k2 = k0, k3 = k0;                                                       \
    if (QC_GDN_NT > 1) k1 = *(const _Float16 *)(aux + astr + kofs + gofs);                    \
    if (QC_GDN_NT > 2) k2 = *(const _Float16 *)(aux + 2u * astr + kofs + gofs);               \
    if (QC_GDN_NT > 3) k3 = *(const _Float16 *)(aux + 3u * astr + kofs + gofs);               \
    __asm__ volatile("vle16.v " VS ", (%0)" ::"r"(s + j * QC_SWEEP_B) : "memory");            \
    __asm__ volatile("vfmul.vf " VS ", " VS ", %0" ::"f"(glast));                             \
    __asm__ volatile("vfmacc.vf " VS ", %0, v16" ::"f"(k0));                                  \
    if (QC_GDN_NT > 1) __asm__ volatile("vfmacc.vf " VS ", %0, v17" ::"f"(k1));               \
    if (QC_GDN_NT > 2) __asm__ volatile("vfmacc.vf " VS ", %0, v18" ::"f"(k2));               \
    if (QC_GDN_NT > 3) __asm__ volatile("vfmacc.vf " VS ", %0, v19" ::"f"(k3));               \
    __asm__ volatile("vse16.v " VS ", (%0)" ::"r"(s + j * QC_SWEEP_B) : "memory");            \
    (void)k1; (void)k2; (void)k3;                                                             \
  } while (0)
  for (uint32_t j = 0; j < w; ++j) {
    QC_CK_C_COL("v8");
    ++j;
    QC_CK_C_COL("v9");
    ++j;
    QC_CK_C_COL("v10");
    ++j;
    QC_CK_C_COL("v11");
  }
#undef QC_CK_C_COL
}
#undef QC_CK_A_COL
#undef QC_CK_LDK
#undef QC_CK_LDQ
#undef QC_CK_LD4
#undef QC_CK_DOT
#undef QC_CK_DOTK
#undef QC_CK_DOTR
#undef QC_CK_DOT_
#endif  // QC_GDN_NT && !QC_HOST && !QC_GDN_CK_H
