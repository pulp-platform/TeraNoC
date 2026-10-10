// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer, full layer (ql_ffn=1): FFN gate+up phase, G = x . Wg, U = x . Wu (qwen_phase.c,
// gu/data/ on the include path). x is the block's output (the o-proj epilogue wrote it into x's
// replicas). Epilogue: the pre-FFN RMSNorm's 1/rms scales the core's G and U rows, then
// H = SiLU(G) * U straight into the H replicas down reads (qwen-ffn's SwiGLU, swiglu.h).
#include "layer.h"

#define QP_PFX(x) gu_##x
#define QP_NAME "gate+up"
#define QP_W_AREA ql_w_area
#define QP_WREG_ELEMS QL_WREG_ELEMS
#define QP_A_EXT ql_x
#define QP_A_EXT_ELEMS QL_X_ELEMS
#define QP_A_EXT_LDX QL_X_LDX
#define QP_A_EXT_REPLICAS QL_X_REPLICAS
#define QP_A_EXT_STRIDE_E QL_X_STRIDE_E
#define QP_PREV_BANK_SEL op_bank_sel
#define QP_NEXT_REFILL dn_refill_head
static void ql_swiglu_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt);
#define QP_EPILOGUE ql_swiglu_epilogue
#include "qwen_phase.c"
#include "swiglu.h"

_Static_assert(QWEN_STAGES_N == 2 && QWEN_K == QL_H && QWEN_LDP == QWEN_P,
               "gate+up: two projections 4096 -> 16384, unpadded");
_Static_assert((QWEN_SEQ_TOTAL % 2) == 0, "down's tile 0 must land in region 0");

static void ql_swiglu_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt) {
  (void)cid;
  (void)strip;
  if (pt->c1 <= pt->c0) return;
  for (uint32_t r = pt->r0; r < pt->r1; ++r) {
    _Float16 *g = (_Float16 *)pt->c[0] + r * pt->ldc + pt->c0;
    _Float16 *u = (_Float16 *)pt->c[1] + r * pt->ldc + pt->c0;
    const _Float16 s = (_Float16)ql_rinv[1][r];
    for (uint32_t c = 0; c < pt->c1 - pt->c0;) {
      size_t vl;
      __asm__ volatile("vsetvli %0, %1, e16, m4, ta, ma" : "=r"(vl) : "r"(pt->c1 - pt->c0 - c));
      __asm__ volatile("vle16.v v0, (%0)" ::"r"(g + c) : "memory");
      __asm__ volatile("vle16.v v4, (%0)" ::"r"(u + c) : "memory");
      __asm__ volatile("vfmul.vf v8, v0, %0" ::"f"(s));
      __asm__ volatile("vfmul.vf v12, v4, %0" ::"f"(s));
      __asm__ volatile("vse16.v v8, (%0)" ::"r"(g + c) : "memory");
      __asm__ volatile("vse16.v v12, (%0)" ::"r"(u + c) : "memory");
      c += (uint32_t)vl;
    }
    __asm__ volatile("fence" ::: "memory");
    swiglu_f16(g, u, ql_fh + r * (uint32_t)QL_FH_LDX + pt->col0 + pt->c0, pt->c1 - pt->c0,
               (uint32_t)QL_FH_REPLICAS, (uint32_t)QL_FH_STRIDE_E);
  }
}
