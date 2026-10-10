// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer o-projection phase: Y = o' . Wo (qwen-common/qwen_phase.c, op/data/ on the include
// path). o' is written by the mixer straight into this phase's A layout. Epilogue: the residual,
// y = x + Y, written into EVERY replica of x -- x's layout is the next layer's qz input.
#include "layer.h"

#define QP_PFX(x) op_##x
#define QP_NAME "o-proj"
#define QP_W_AREA ql_w_area
#define QP_WREG_ELEMS QL_WREG_ELEMS
#define QP_A_EXT ql_o
#define QP_A_EXT_ELEMS QL_O_ELEMS
#define QP_A_EXT_LDX QL_O_LDX
#define QP_A_EXT_REPLICAS QL_O_REPLICAS
#define QP_A_EXT_STRIDE_E QL_O_STRIDE_E
#define QP_PREV_BANK_SEL QL_IN(bank_sel)
#if QL_FFN
#define QP_NEXT_REFILL gu_refill_head
#endif
static void ql_residual_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt);
#define QP_EPILOGUE ql_residual_epilogue
#include "qwen_phase.c"

_Static_assert(QWEN_STAGES_N == 1 && QWEN_K == QL_VZ && QWEN_P == QL_H,
               "o-proj: one projection 6144 -> 4096");
#if QL_FFN
_Static_assert((QWEN_SEQ_TOTAL % 2) == 0, "gate+up's tile 0 must land in region 0");
#endif

// Columns [c0, c1) of rows [r0, r1): y = C + x (this core's replica), stored to every replica.
// With the FFN: this core's fp32 sum of y^2 per row, the pre-FFN RMSNorm's partials.
static void ql_residual_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt) {
  (void)strip;
  const uint32_t rep = ql_x_replica(cid);
#if QL_FFN
  for (uint32_t r = 0; r < QL_ROWS; ++r) ql_rms_part[r * NUM_CORES + cid] = 0.0f;
#endif
  for (uint32_t r = pt->r0; r < pt->r1; ++r) {
    for (uint32_t c = pt->c0; c < pt->c1;) {
      size_t vl;
      __asm__ volatile("vsetvli %0, %1, e16, m4, ta, ma" : "=r"(vl) : "r"(pt->c1 - c));
      const uint32_t col = pt->col0 + c;
      __asm__ volatile("vle16.v v0, (%0)" ::"r"(pt->c[0] + r * pt->ldc + c) : "memory");
      __asm__ volatile("vle16.v v4, (%0)" ::"r"(ql_x_at(rep, r, col)) : "memory");
      __asm__ volatile("vfadd.vv v0, v0, v4");
      for (uint32_t k = 0; k < (uint32_t)QL_X_REPLICAS; ++k)
        __asm__ volatile("vse16.v v0, (%0)" ::"r"(ql_x_at(k, r, col)) : "memory");
      c += (uint32_t)vl;
    }
#if QL_FFN
    if (pt->c1 > pt->c0) {
      __asm__ volatile("fence" ::: "memory");
      ql_rms_part[r * NUM_CORES + cid] =
          ql_sumsq_seg(ql_x_at(rep, r, pt->col0 + pt->c0), pt->c1 - pt->c0, cid);
    }
#endif
  }
}
