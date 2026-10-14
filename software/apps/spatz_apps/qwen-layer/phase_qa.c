// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer, attention: the in-projection, C = x . W (qwen-common/qwen_phase.c, qa/data/ on the
// include path), columns q (24 heads x 256) | gate (24 x 256) | k (4 x 256) | v (4 x 256) of the
// new token. Epilogue, on each core's own reduced patch: the pre-mixer RMSNorm's 1/rms, then every
// value to where the attention mixer reads it -- q and gate to the slots of the core that starts
// (part 0) its problem (sequence, KV head), the new token's k and v to the core whose block holds
// the last position (the last part). q/k RMSNorm and RoPE happen there (they need whole heads).
// The KV tiles use the W area during the mixer, so the stream does not run on into o-proj.
#include "layer.h"

#define QP_PFX(x) qa_##x
#define QP_NAME "q|gate|k|v"
#define QP_W_AREA ql_w_area
#define QP_WREG_ELEMS QL_WREG_ELEMS
#define QP_A_EXT ql_x
#define QP_A_EXT_ELEMS QL_X_ELEMS
#define QP_A_EXT_LDX QL_X_LDX
#define QP_A_EXT_REPLICAS QL_X_REPLICAS
#define QP_A_EXT_STRIDE_E QL_X_STRIDE_E
#define QP_SETUP_GBAR 1
static void ql_qa_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt);
#define QP_EPILOGUE ql_qa_epilogue
#define QP_PT_BASE QL_PT_IN_PRE
#include "qwen_phase.c"

// 14336 is a whole number of the phase's pad unit at 4x4 (2048) but not at 8x8 (4096): there the
// stored width is 16384 and the 2048 pad columns are computed and dropped (+14% of this phase).
_Static_assert(QWEN_STAGES_N == 1 && QWEN_K == QL_H && QWEN_P == QL_P_QA && QWEN_LDP >= QWEN_P,
               "q|gate|k|v: one projection 4096 -> 14336");

static inline void ql_qa_scatter(uint32_t b, uint32_t col, uint16_t v) {
  if (col < QL_A_COL_K) {  // q or gate of query head h: problem (b, h / 6), its part 0
    const uint32_t gate = col >= QL_A_COL_G, c = col - (gate ? QL_A_COL_G : 0u);
    const uint32_t h = c / QC_ATT_D, d = c % QC_ATT_D, p = b * QC_ATT_KVH + h / QC_ATT_QPK;
    const uint32_t sw = (gate ? QL_A_RES_GATE : QL_A_RES_Q) + (ql_a_qp(p) * QC_ATT_QPK + h % QC_ATT_QPK) * 8u + d / 32u;
    ((uint16_t *)ql_resp(sw, ql_a_core(p, 0)))[d % 32u] = v;
  } else {  // the new token's k or v of KV head g: problem (b, g), its last part
    const uint32_t isv = col >= QL_A_COL_V, c = col - (isv ? QL_A_COL_V : QL_A_COL_K);
    const uint32_t g = c / QC_ATT_D, d = c % QC_ATT_D, p = b * QC_ATT_KVH + g;
    const uint32_t sw = (isv ? QL_A_RES_VNEW : QL_A_RES_KNEW) + ql_a_qp(p) * 8u + d / 32u;
    ((uint16_t *)ql_resp(sw, ql_a_core(p, QL_A_CPP - 1u)))[d % 32u] = v;
  }
}

static void ql_qa_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt) {
  (void)cid;
  (void)strip;
  for (uint32_t r = pt->r0; r < pt->r1; ++r) {
    const _Float16 rinv = (_Float16)ql_rinv[0][r];
    const _Float16 *x = pt->c[0] + r * pt->ldc;
    for (uint32_t c = pt->c0; c < pt->c1; ++c) {
      const uint32_t col = pt->col0 + c;
      if (col >= QL_P_QA) break;  // pad columns
      if (QL_CHECK) {
        ql_qa_scatter(r, col, ql_pat(r, col));
      } else {
        const _Float16 v = x[c] * rinv;
        ql_qa_scatter(r, col, *(const uint16_t *)&v);
      }
    }
  }
}
