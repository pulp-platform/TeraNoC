// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer qkvz phase: C = x . Wqkvz (qwen-common/qwen_phase.c, qz/data/ on the include
// path), columns q | k | v | z. Epilogue, on each core's own reduced patch: the causal conv1d
// (4 taps, state of 3 tokens per channel) and SiLU on q, k, v; then every value goes where the
// mixer reads it -- the aux slots of the chunk core(s) that need it (v, z: one core; q, k: the 12
// chunks of their (sequence, key head)). The stream runs on into the o-projection's tiles.
#include "layer.h"

#define QP_PFX(x) qz_##x
#define QP_NAME "qkvz"
#define QP_W_AREA ql_w_area
#define QP_WREG_ELEMS QL_WREG_ELEMS
#define QP_A_EXT ql_x
#define QP_A_EXT_ELEMS QL_X_ELEMS
#define QP_A_EXT_LDX QL_X_LDX
#define QP_A_EXT_REPLICAS QL_X_REPLICAS
#define QP_A_EXT_STRIDE_E QL_X_STRIDE_E
#define QP_SETUP_GBAR 1
#if !QL_STATE_W
#define QP_NEXT_REFILL op_refill_head
#endif
static void ql_qz_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt);
#define QP_EPILOGUE ql_qz_epilogue
#include "qwen_phase.c"
#include "../qwen-common/qc_vec.h"

_Static_assert(QWEN_STAGES_N == 1 && QWEN_K == QL_H && QWEN_P == QL_P_QZ && QWEN_LDP == QWEN_P,
               "qkvz: one projection 4096 -> 16384, unpadded");
#if !QL_STATE_W
_Static_assert((QWEN_SEQ_TOTAL % 2) == 0, "o-proj's tile 0 must land in region 0");
#endif

// One value of sequence b, channel col (after conv/SiLU for q k v) to its reader(s).
static inline void ql_scatter(uint32_t b, uint32_t col, uint16_t v) {
  if (col < QL_COL_V) {  // q or k of key head kh: the 12 chunks (3 value heads x 4 blocks)
    const uint32_t k = col >= QL_COL_K, ch = col - (k ? QL_COL_K : 0u);
    const uint32_t kh = ch / QC_GDN_D, d = ch % QC_GDN_D;
    const uint32_t sw = (k ? QC_GDN_AUX_K : QC_GDN_AUX_Q) + d / QC_GDN_RC;
    const uint32_t c0 = (b * QC_GDN_KH + kh) * QC_GDN_VPK * QC_GDN_RB;
    for (uint32_t u = 0; u < QC_GDN_VPK * QC_GDN_RB; ++u) {
      const uint32_t c = c0 + u;
      ((uint16_t *)ql_auxp(c / NUM_CORES, sw, c % NUM_CORES))[d % QC_GDN_RC] = v;
    }
  } else {  // v or z of value head vh: one chunk
    const uint32_t z = col >= QL_COL_Z, ch = col - (z ? QL_COL_Z : QL_COL_V);
    const uint32_t vh = ch / QC_GDN_D, i = ch % QC_GDN_D;
    const uint32_t c = ((b * QC_GDN_KH + vh / QC_GDN_VPK) * QC_GDN_VPK + vh % QC_GDN_VPK) *
                           QC_GDN_RB + i / QC_GDN_RC;
    ((uint16_t *)ql_auxp(c / NUM_CORES, z ? QL_AUX_Z : QC_GDN_AUX_V, c % NUM_CORES))
        [i % QC_GDN_RC] = v;
  }
}

static void ql_qz_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt) {
  (void)strip;
  const qc_k_t qck = qc_k();
  uint16_t *scr = (uint16_t *)qc_slot(ql_scr, 0, cid);  // 2 slots = 64 fp16, this core's tile
  qc_rne();
  {
    size_t vl;  // the constant registers once, at the widest strip (vfmv.v.f: slide unit)
    __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(QC_SLOT_F16));
    QC_SET_CONST_REGS("v12", "v13");
  }
  for (uint32_t r = pt->r0; r < pt->r1; ++r)
    for (uint32_t c = pt->c0; c < pt->c1;) {
      const uint32_t col = pt->col0 + c;
      // A strip of at most 32 channels (one scratch slot) that does not cross a section edge.
      uint32_t n = pt->c1 - c;
      if (n > QC_SLOT_F16) n = QC_SLOT_F16;
      const uint32_t edge = col < QL_COL_V ? (col < QL_COL_K ? QL_COL_K : QL_COL_V)
                                             : (col < QL_COL_Z ? QL_COL_Z : QL_P_QZ);
      if (col + n > edge) n = edge - col;
      const _Float16 *x = pt->c[0] + r * pt->ldc + c;
      const _Float16 rinv = (_Float16)ql_rinv[0][r];
      if (QL_CHECK) {
        for (uint32_t e = 0; e < n; ++e) ql_scatter(r, col + e, ql_pat(r, col + e));
      } else if (col < QL_COL_Z) {
        // y = w3 x + w0 h0 + w1 h1 + w2 h2 ; state <- (h1, h2, x) ; out = SiLU(y)
        ql_elem_t *h = ql_conv_state + (r * 3u) * QL_CONV_CH + col;
        const ql_elem_t *w = ql_conv_w + col;
        size_t vl;
        __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(n));
        __asm__ volatile("vle16.v v0, (%0)" ::"r"(x) : "memory");
        __asm__ volatile("vfmul.vf v0, v0, %0" ::"f"(rinv));  // the pre-mixer RMSNorm
        __asm__ volatile("vle16.v v1, (%0)" ::"r"(h) : "memory");
        __asm__ volatile("vle16.v v2, (%0)" ::"r"(h + QL_CONV_CH) : "memory");
        __asm__ volatile("vle16.v v3, (%0)" ::"r"(h + 2u * QL_CONV_CH) : "memory");
        __asm__ volatile("vle16.v v4, (%0)" ::"r"(w) : "memory");
        __asm__ volatile("vle16.v v5, (%0)" ::"r"(w + QL_CONV_CH) : "memory");
        __asm__ volatile("vle16.v v6, (%0)" ::"r"(w + 2u * QL_CONV_CH) : "memory");
        __asm__ volatile("vle16.v v7, (%0)" ::"r"(w + 3u * QL_CONV_CH) : "memory");
        __asm__ volatile("vse16.v v2, (%0)" ::"r"(h) : "memory");
        __asm__ volatile("vse16.v v3, (%0)" ::"r"(h + QL_CONV_CH) : "memory");
        __asm__ volatile("vse16.v v0, (%0)" ::"r"(h + 2u * QL_CONV_CH) : "memory");
        __asm__ volatile("vfmul.vv v8, v0, v7");
        __asm__ volatile("vfmacc.vv v8, v1, v4");
        __asm__ volatile("vfmacc.vv v8, v2, v5");
        __asm__ volatile("vfmacc.vv v8, v3, v6");
        QC_SILU("v8", "v9", "v10", "v11", "v14", "v12", "v13");
        __asm__ volatile("vse16.v v14, (%0)" ::"r"(scr) : "memory");
        __asm__ volatile("fence" ::: "memory");
        for (uint32_t e = 0; e < n; ++e) ql_scatter(r, col + e, scr[e]);
      } else {  // z: scaled, no conv
        for (uint32_t e = 0; e < n; ++e) {
          const _Float16 zv = x[e] * rinv;
          ql_scatter(r, col + e, *(const uint16_t *)&zv);
        }
      }
      c += n;
    }
}
