// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-proj: one decode projection phase, C[s] = X . W[s] (qwen-common/qwen_phase.c, data/ on
// the include path). Pure GEMM: the epilogue does no work in a perf build -- C stays in L1, as in
// the layer, where the consumer's epilogue reads it in place -- so the timed region is what every
// projection of the layer costs apart from its fused epilogue. A check build verifies each core's
// own reduced patch there instead (qwen_pattern.h, check 1: exact, integer compares).
#include "proj.h"

#define QP_PFX(x) pj_##x
#define QP_NAME "proj"
#define QP_W_AREA proj_w_area
#define QP_WREG_ELEMS PROJ_WREG_ELEMS
#define QP_SETUP_GBAR 1
static void proj_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt);
#define QP_EPILOGUE proj_epilogue
#include "qwen_phase.c"

static volatile uint32_t proj_bad, proj_bad_s, proj_bad_b, proj_bad_p, proj_bad_got, proj_bad_want;

// proj_report=min: the whole result on one line, every number in hex. printf's decimal path
// divides per digit (~90 cycles a character on RTL; a full run's report took 50-70k cycles after
// the timed region), this one only shifts. Read by script/proj_results.py ("[PROJ] min").
static void pj_puts(const char *s) {
  while (*s) _putchar(*s++);
}

static void pj_hex(const char *key, uint32_t v) {
  pj_puts(key);
  uint32_t on = 0;
  for (int sh = 28; sh >= 0; sh -= 4) {
    const uint32_t d = (v >> sh) & 15u;
    on |= d | (sh == 0);
    if (on) _putchar((char)(d < 10u ? '0' + d : 'a' - 10 + d));
  }
}

void pj_report_min(uint32_t t0, uint32_t cycles) {
  uint32_t warn = (ph_split_bad ? 1u : 0u) | (ph_align_bad ? 2u : 0u);
#if MSHR_RUNTIME_CFG
  for (uint32_t g = 0; g < (uint32_t)NUM_GROUPS; ++g)
    if (ph_mshr_status[g]) warn |= 4u;
#endif
  pj_puts("[PROJ] min shape=" PROJ_SHAPE);
  pj_hex(" cores=", NUM_CORES);
  pj_hex(" B=", QWEN_B);
  pj_hex(" K=", QWEN_K);
  pj_hex(" P=", QWEN_P);
  pj_hex(" stages=", QWEN_STAGES_N);
  pj_hex(" kt=", QWEN_KT);
  pj_hex(" pt=", QWEN_PT);
  pj_hex(" strips=", QWEN_NSTRIPS);
  pj_hex(" steps=", QWEN_STEPS);
  pj_hex(" strips_run=", QWEN_STRIPS_RUN);
  pj_hex(" steps_run=", QWEN_STEPS_RUN);
  pj_hex(" ks=", KERNEL_SIZE);
  pj_hex(" ksplit=", QWEN_KSPLIT);
  pj_hex(" kgroup=", FFN_KSPLIT_XGROUP);
  pj_hex(" xrep=", QWEN_X_REPLICAS);
  pj_hex(" warn=", warn);
  pj_hex(" t0=", t0);
  pj_hex(" cycles=", cycles);
  pj_puts(" tiles");
  for (uint32_t i = 0; i < QWEN_SEQ_TOTAL; ++i)
    pj_hex(i ? "," : "=", qwen_tile_ts[i] - (i ? qwen_tile_ts[i - 1] : ph_t_pass));
  _putchar('\n');
}

uint32_t pj_bad(void) {
  if (proj_bad)
    printf("FAIL: %u/%u outputs wrong; first at stage=%u b=%u p=%u got=0x%04x want=0x%04x\n",
           (unsigned)proj_bad, (unsigned)(QWEN_STAGES_N * QWEN_B * QWEN_P), (unsigned)proj_bad_s,
           (unsigned)proj_bad_b, (unsigned)proj_bad_p, (unsigned)proj_bad_got,
           (unsigned)proj_bad_want);
  return proj_bad;
}

static void proj_epilogue(uint32_t cid, uint32_t strip, const qp_patch_t *pt) {
  (void)cid;
  (void)strip;
#if QWEN_CHECK == 1
  for (uint32_t s = 0; s < (uint32_t)QWEN_STAGES_N; ++s)
    for (uint32_t r = pt->r0; r < pt->r1; ++r) {
      uint16_t want3[3];
      for (uint32_t m = 0; m < 3u; ++m) want3[m] = qwen_eighths_to_fp16(qwen_expect_eighths(s, r, m));
      for (uint32_t c = pt->c0; c < pt->c1; ++c) {
        const uint32_t p = pt->col0 + c;
        if (p >= (uint32_t)QWEN_P) continue;
        const uint16_t v = ((const uint16_t *)pt->c[s])[r * pt->ldc + c], e = want3[p % 3u];
        if (v != e && __atomic_fetch_add(&proj_bad, 1u, __ATOMIC_RELAXED) == 0u) {
          proj_bad_s = s; proj_bad_b = r; proj_bad_p = p; proj_bad_got = v; proj_bad_want = e;
        }
      }
    }
#else
  (void)pt;
#endif
}
