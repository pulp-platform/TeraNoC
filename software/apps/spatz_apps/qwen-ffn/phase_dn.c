// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-ffn down phase: Y = H . Wd (qwen-common/qwen_phase.c, dn/data/ on the include path). H is
// the gate+up epilogue's output; the MSHR is retuned at the handover; check 1 verifies Y.
#include "ffn.h"

#define QP_PFX(x) dn_##x
#define QP_NAME "down"
#define QP_W_AREA ffn_w_area
#define QP_WREG_ELEMS FFN_WREG_ELEMS
#define QP_A_EXT ffn_h
#define QP_A_EXT_ELEMS FFN_H_ELEMS
#define QP_A_EXT_LDX FFN_H_LDX
#define QP_A_EXT_REPLICAS FFN_H_REPLICAS
#define QP_A_EXT_STRIDE_E FFN_H_STRIDE_E
#define QP_PREV_BANK_SEL gu_bank_sel
#include "qwen_phase.c"

_Static_assert(QWEN_STAGES_N == 1, "down: one projection");

// Check 1 (end to end): Y against down's multi-hot expectation -- H is exactly that pattern when
// gate+up and SwiGLU are right (script/gen_operands_gu.c). Integer compares only.
#if QWEN_CHECK == 1
static volatile uint32_t ffn_bad, ffn_bad_b, ffn_bad_p, ffn_bad_got, ffn_bad_want;
#endif
int dn_verify(uint32_t cid) {
#if QWEN_CHECK == 1
  const uint32_t num_cores = mempool_get_core_count();
  if (cid == 0) ffn_bad = 0;
  qwen_barrier(cid);
  for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip) {
#if QWEN_NSTRIPS > 1
    if (cid == (uint32_t)QWEN_DMA_CORE)
      dma_memcpy_blocking(qwen_c[0], qwen_out_l2[0] + strip * (uint32_t)(QWEN_B * QWEN_LDW),
                          (size_t)(QWEN_B * QWEN_LDW) * GEMM_ELEM_BYTES);
    qwen_barrier(cid);
#endif
    uint32_t cached = 0xffffffffu;
    uint16_t want3[3] = {0, 0, 0};
    for (uint32_t i = cid; i < (uint32_t)(QWEN_B * QWEN_PT); i += num_cores) {
      const uint32_t b = i / (uint32_t)QWEN_PT, col = i % (uint32_t)QWEN_PT;
      const uint32_t p = strip * (uint32_t)QWEN_PT + col;
      if (p >= (uint32_t)QWEN_P) continue;
      if (cached != b) {
        cached = b;
        for (uint32_t m = 0; m < 3u; ++m) want3[m] = qwen_eighths_to_fp16(qwen_expect_eighths(0, b, m));
      }
      const uint16_t e = want3[p % 3u], v = ((const uint16_t *)qwen_c[0])[b * QWEN_LDW + col];
      if (v != e && __atomic_fetch_add(&ffn_bad, 1u, __ATOMIC_RELAXED) == 0u) {
        ffn_bad_b = b; ffn_bad_p = p; ffn_bad_got = v; ffn_bad_want = e;
      }
    }
    qwen_barrier(cid);
  }
  if (cid == 0) {
    if (ffn_bad)
      printf("FAIL: %u/%u outputs wrong; first at b=%u p=%u got=0x%04x want=0x%04x\n",
             (unsigned)ffn_bad, (unsigned)(QWEN_B * QWEN_P), (unsigned)ffn_bad_b,
             (unsigned)ffn_bad_p, (unsigned)ffn_bad_got, (unsigned)ffn_bad_want);
    else
      printf("success!\n");
  }
  return ffn_bad ? -1 : 0;
#else
  (void)cid;
  return 0;
#endif
}
