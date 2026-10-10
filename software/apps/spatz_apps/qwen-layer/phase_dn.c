// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer, full layer (ql_ffn=1): FFN down phase, Y = H . Wd (qwen_phase.c, dn/data/ on the
// include path). Epilogue: the residual, x = x + Y into every replica of x -- the next layer's
// input, in qz's A layout.
#include "layer.h"

#define QP_PFX(x) dn_##x
#define QP_NAME "down"
#define QP_W_AREA ql_w_area
#define QP_WREG_ELEMS QL_WREG_ELEMS
#define QP_A_EXT ql_fh
#define QP_A_EXT_ELEMS QL_FH_ELEMS
#define QP_A_EXT_LDX QL_FH_LDX
#define QP_A_EXT_REPLICAS QL_FH_REPLICAS
#define QP_A_EXT_STRIDE_E QL_FH_STRIDE_E
#define QP_PREV_BANK_SEL gu_bank_sel
static void ql_dn_residual(uint32_t cid, uint32_t strip, const qp_patch_t *pt);
#define QP_EPILOGUE ql_dn_residual
#include "qwen_phase.c"

_Static_assert(QWEN_STAGES_N == 1 && QWEN_K == 16384u && QWEN_P == QL_H, "down: 16384 -> 4096");

static void ql_dn_residual(uint32_t cid, uint32_t strip, const qp_patch_t *pt) {
  (void)strip;
  const uint32_t rep = ql_x_replica(cid);
  for (uint32_t r = pt->r0; r < pt->r1; ++r)
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
}
