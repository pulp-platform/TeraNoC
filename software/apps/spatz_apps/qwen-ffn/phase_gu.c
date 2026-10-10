// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-ffn gate+up phase: G = X . Wg, U = X . Wu (qwen-common/qwen_phase.c, gu/data/ on the
// include path), then H = SiLU(G) * U in the epilogue -- each core's own reduced G/U patch straight
// into the H replicas, in the layout the down phase reads. The stream runs on into down's tiles.
#include "ffn.h"

#define QP_PFX(x) gu_##x
#define QP_NAME "gate+up"
#define QP_W_AREA ffn_w_area
#define QP_WREG_ELEMS FFN_WREG_ELEMS
#define QP_SETUP_GBAR 1
#define QP_NEXT_REFILL dn_refill_head
static void ffn_swiglu_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt);
#define QP_EPILOGUE ffn_swiglu_epilogue
#include "qwen_phase.c"
#include "swiglu.h"
#ifndef QC_EXP_FAKE
#define QC_EXP_FAKE 0  // a swiglu.h without the fake-exponent option runs the real one
#endif

// Which exponential the SwiGLU epilogue ran (swiglu.h QC_EXP_FAKE), for the report.
const char *gu_exp_name(void) { return QC_EXP_FAKE ? "fake" : "real"; }

_Static_assert(QWEN_STAGES_N == 2 && QWEN_P == FFN_DN_K && QWEN_LDP == QWEN_P,
               "gate+up: two projections whose output width is down's K, unpadded");
_Static_assert((QWEN_SEQ_TOTAL % 2) == 0,
               "Down's tile 0 must land in region 0: an even gate+up tile count");

// G = c[0], U = c[1]; H column = strip's first column + c.
static void ffn_swiglu_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt) {
  (void)cid;
  (void)strip;
  for (uint32_t r = pt->r0; r < pt->r1 && pt->c1 > pt->c0; ++r)
    swiglu_f16(pt->c[0] + r * pt->ldc + pt->c0, pt->c[1] + r * pt->ldc + pt->c0,
               ffn_h + r * (uint32_t)FFN_H_LDX + pt->col0 + pt->c0, pt->c1 - pt->c0,
               (uint32_t)FFN_H_REPLICAS, (uint32_t)FFN_H_STRIDE_E);
}
