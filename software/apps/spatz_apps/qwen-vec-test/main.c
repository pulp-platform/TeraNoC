// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
// Test and cost of the fp16 vector library (qwen-common/qc_vec.h).
//
//   make qwen-vec-test config=terapool_spatz4_fpu l1_bank_size=4096 l2_size=536870912
//
// Core 0, outside any timed region of interest:
//   1. every routine over QC_TEST_N inputs, compared BIT FOR BIT with the host model
//      (qwen-common/script/vec_ref.py, which also wrote data/qc_vec_test_data.h);
//   2. the same at n = 1..5 -- the short vectors that wedge integer/FP sequences on this RTL;
//   3. qc_sumsq_f16 and qc_rsqrt_f32 against host values;
//   4. cost: each register-level sequence repeated on 64 resident elements (the fused,
//      in-register cost per element), and the stand-alone routine over 1024 L1 elements.
// Prints "[QVT] PASS" or "[QVT] FAIL ..." and returns the number of failures.

#include <stdint.h>

#include "../qwen-common/qc_layout.h"
#include "../qwen-common/qc_sync.h"
#define QC_EXP_FAKE 0  // bit-exact tests of the polynomial
#include "../qwen-common/qc_vec.h"
#include "data/qc_vec_test_data.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#define QVT_PERF_N 1024u
#define QVT_REPS 16u

static _Float16 qvt_x[QVT_PERF_N] QC_L1_SWEEP;
static _Float16 qvt_y[QVT_PERF_N] __attribute__((section(".l1_prio")));

typedef void (*qvt_fn_t)(const _Float16 *, _Float16 *, size_t);

static uint32_t qvt_check(const char *name, qvt_fn_t fn, const uint16_t *want, uint32_t n) {
  for (uint32_t i = 0; i < QC_TEST_N; ++i) qvt_y[i] = (_Float16)0;
  fn(qvt_x, qvt_y, n);
  __asm__ volatile("fence" ::: "memory");
  uint32_t bad = 0, first = n;
  const uint16_t *got = (const uint16_t *)qvt_y;
  for (uint32_t i = 0; i < n; ++i) {
    if (got[i] != want[i]) {
      if (!bad) first = i;
      ++bad;
    }
  }
  // Nothing past n may be written.
  for (uint32_t i = n; i < n + 8u && i < QC_TEST_N; ++i)
    if (got[i] != 0u) ++bad;
  if (bad)
    printf("[QVT] %s n=%u: %u mismatches, first i=%u x=0x%04x got 0x%04x want 0x%04x\n", name,
           n, bad, first, ((const uint16_t *)qvt_x)[first], got[first], want[first]);
  return bad ? 1u : 0u;
}

int main(void) {
  const uint32_t cid = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  mempool_barrier_init(cid);
  qc_sync_init(cid);
  mempool_barrier(num_cores);
  if (cid != 0) {
    qc_barrier(cid);
    return 0;
  }

  uint32_t fails = 0;
  for (uint32_t i = 0; i < QC_TEST_N; ++i) ((uint16_t *)qvt_x)[i] = qc_test_x[i];

  static const struct {
    const char *name;
    qvt_fn_t fn;
    const uint16_t *want;
  } r[] = {{"exp", qc_vexp_f16, qc_test_exp},
           {"sigmoid", qc_vsigmoid_f16, qc_test_sigmoid},
           {"silu", qc_vsilu_f16, qc_test_silu},
           {"softplus", qc_vsoftplus_f16, qc_test_softplus}};
  for (uint32_t k = 0; k < 4; ++k) {
    fails += qvt_check(r[k].name, r[k].fn, r[k].want, QC_TEST_N);
    for (uint32_t n = 1; n <= 5; ++n) fails += qvt_check(r[k].name, r[k].fn, r[k].want, n);
  }

  const float ss = qc_sumsq_f16(qvt_x, QC_TEST_N), ss_want = QC_TEST_SUMSQ;
  const float ss_err = ss > ss_want ? ss - ss_want : ss_want - ss;
  if (ss_err > ss_want * qc_f32_imm(0x37800000u)) {  // 1.5e-5 relative
    printf("[QVT] sumsq: got %d want %d (x1)\n", (int)ss, (int)ss_want);
    ++fails;
  }
  // rsqrt(4096) = 1/64 exactly representable; rsqrt(2) ~ 0.70710677.
  const float r1 = qc_rsqrt_f32(qc_f32_imm(0x45800000u));    // 4096
  const float r2 = qc_rsqrt_f32(qc_f32_imm(0x40000000u));    // 2
  const uint32_t b1 = qc_f32_bits(r1), b2 = qc_f32_bits(r2);
  if (b1 < 0x3c7ffff0u || b1 > 0x3c800010u || b2 < 0x3f3504e0u || b2 > 0x3f350500u) {
    printf("[QVT] rsqrt: 1/sqrt(4096) bits 0x%08x, 1/sqrt(2) bits 0x%08x\n", b1, b2);
    ++fails;
  }

  // ---- cost -------------------------------------------------------------------------------
  {
    const qc_k_t qck = qc_k();
    size_t vl;
    __asm__ volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(vl) : "r"(64u));
    QC_SET_CONST_REGS("v12", "v14");
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(qvt_x) : "memory");
    __asm__ volatile("vle16.v v16, (%0)" ::"r"(qvt_x) : "memory");
    __asm__ volatile("fence" ::: "memory");
    uint32_t t0 = mempool_get_timer();
    for (uint32_t i = 0; i < QVT_REPS; ++i) {
      __asm__ volatile("vfsgnj.vv v0, v16, v16");  // fresh input (EXP clamps X in place)
      QC_EXP("v0", "v2", "v4", "v12", "v14");
    }
    __asm__ volatile("vfmv.f.s %0, v4" : "=f"(*(volatile _Float16 *)qvt_y));
    uint32_t t1 = mempool_get_timer();
    for (uint32_t i = 0; i < QVT_REPS; ++i) QC_SILU("v16", "v2", "v4", "v6", "v8", "v12", "v14");
    __asm__ volatile("vfmv.f.s %0, v8" : "=f"(*(volatile _Float16 *)qvt_y));
    uint32_t t2 = mempool_get_timer();
    for (uint32_t i = 0; i < QVT_REPS; ++i)
      QC_SOFTPLUS("v16", "v2", "v4", "v6", "v8", "v12", "v14");
    __asm__ volatile("vfmv.f.s %0, v8" : "=f"(*(volatile _Float16 *)qvt_y));
    uint32_t t3 = mempool_get_timer();
    // cycles per 64 elements, x100 (per element = value / 6400)
    printf("[QVT] in-register cycles per 64 elements (e16 m2): exp %u, silu %u, softplus %u "
           "(x1/%u reps)\n",
           (t1 - t0) / QVT_REPS, (t2 - t1) / QVT_REPS, (t3 - t2) / QVT_REPS, QVT_REPS);
  }
  for (uint32_t i = QC_TEST_N; i < QVT_PERF_N; ++i) qvt_x[i] = qvt_x[i - QC_TEST_N];
  {
    uint32_t t0 = mempool_get_timer();
    qc_vsilu_f16(qvt_x, qvt_y, QVT_PERF_N);
    __asm__ volatile("fence" ::: "memory");
    uint32_t t1 = mempool_get_timer();
    qc_vexp_f16(qvt_x, qvt_y, QVT_PERF_N);
    __asm__ volatile("fence" ::: "memory");
    uint32_t t2 = mempool_get_timer();
    printf("[QVT] stand-alone %u elements (L1, one core): silu %u cycles, exp %u cycles\n",
           QVT_PERF_N, t1 - t0, t2 - t1);
  }

  if (fails)
    printf("[QVT] FAIL %u\n", fails);
  else
    printf("[QVT] PASS\n");
  qc_barrier(cid);
  return (int)fails;
}
