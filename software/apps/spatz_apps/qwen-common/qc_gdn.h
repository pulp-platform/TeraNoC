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
#define QC_GDN_AUX_SW 11u // sweeps the kernel uses; apps may add their own after these

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
