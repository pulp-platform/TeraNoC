// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Directed probe: Spatz wedges on short vectors when an integer-unit (IPU) op
// follows FPU work.
//
// Found 2026-09-30 in qwen-ffn-down's SwiGLU (swiglu.h): with 2 or 4 elements
// per core every core of a 4x4 run froze at `vadd.vx v16, v16, a7` (the 2^n
// step, on vfcvt.x.f.v's output) with the next vector instruction never issued;
// with 8 elements the same code ran. This app narrows the condition. Every core
// runs the same sequences on its own registers; each phase is fenced, barriered
// and then marked by core 0, so the LAST marker printed names the phase that
// wedged. Inside a phase each vector length has its own vsetvli, whose
// requested AVL is the `opa` of that line in the per-hart trace
// (snitch_trace=1), which gives the vl.
//
//   P0 FPU -> FPU, dependent      vfcvt.x.f.v v16 ; vfcvt.f.x.v v20, v16
//   (control) P1 IPU -> IPU, dependent      vadd.vx v16 ; vsll.vi v16 (control)
//   P2 FPU -> IPU, dependent      vfadd.vv v16 ; vadd.vx v16, v16
//   P3 CONV -> IPU, dependent     vfcvt.x.f.v v16 ; vadd.vx v16, v16 (the
//   observed pair) P4 FPU chain + IPU, NOT dependent: vfmacc chain on v24..v28
//   ; vadd.vx v16 on older data P5 IPU -> FPU, dependent      vadd.vx v16 ;
//   vfadd.vv v20, v16 P6 the exact swiglu_f16 body (known wedge)
//
// All at e32/m4 like the SwiGLU core (PROBE_LMUL=1 builds the m1 variant). vl
// sweeps 8..1 (descending, so the healthy lengths are proven first in every
// phase).

#include "printf.h"
#include "runtime.h"
#include "synchronization.h"
#include <stdint.h>

#ifndef PROBE_SEW
#define PROBE_SEW 32
#endif
#ifndef PROBE_ITERS
#define PROBE_ITERS 4
#endif
#ifndef PROBE_FIRST_PHASE
#define PROBE_FIRST_PHASE 0
#endif
#ifndef PROBE_LMUL
#define PROBE_LMUL 4
#endif
#ifndef PROBE_RAW_LOADS
#define PROBE_RAW_LOADS 0
#endif
#if PROBE_LMUL == 4
#define VSET32 "vsetvli %0, %1, e32, m4, ta, ma"
#define VSET16 "vsetvli zero, %0, e16, m2, ta, ma"
#else
#define VSET32 "vsetvli %0, %1, e32, m1, ta, ma"
#define VSET16 "vsetvli zero, %0, e16, mf2, ta, ma"
#endif

#if PROBE_SEW == 16
#define VSET "vsetvli %0, %1, e16, m" STR(PROBE_LMUL) ", ta, ma"
#define VLOAD "vle16.v "
typedef _Float16 elem_t;
#else
#define VSET VSET32
#define VLOAD "vle32.v "
typedef float elem_t;
#endif
#define STR_IMPL(x) #x
#define STR(x) STR_IMPL(x)

static elem_t src[64] __attribute__((aligned(64)));

static void mark(uint32_t cid, uint32_t ncores, const char *what) {
  __asm__ volatile("fence" ::: "memory"); // drains the Spatz VLSU/VFU too
  mempool_barrier(ncores);
  if (cid == 0)
    printf("[VPROBE] %s OK\n", what);
  mempool_barrier(ncores);
}

// Load immutable inputs once per phase, then vary only the arithmetic VL.
#if !PROBE_RAW_LOADS
static void initialize_vectors(void) {
  size_t vl;
  __asm__ volatile(VSET : "=r"(vl) : "r"(16));
  __asm__ volatile(VLOAD "v12, (%0)" ::"r"(src) : "memory");
  __asm__ volatile(VLOAD "v4, (%0)" ::"r"(src) : "memory");
  __asm__ volatile(VLOAD "v8, (%0)" ::"r"(src) : "memory");
  __asm__ volatile("fence" ::: "memory");
}
#endif

static inline size_t set_vl(uint32_t avl) {
  size_t vl;
  __asm__ volatile(VSET : "=r"(vl) : "r"(avl));
#if PROBE_RAW_LOADS
  __asm__ volatile(VLOAD "v12, (%0)" ::"r"(src) : "memory");
  __asm__ volatile(VLOAD "v4, (%0)" ::"r"(src) : "memory");
  __asm__ volatile(VLOAD "v8, (%0)" ::"r"(src) : "memory");
#endif
  return vl;
}

__attribute__((noinline)) static void p0(uint32_t avl) {
  set_vl(avl);
  for (int i = 0; i < PROBE_ITERS; ++i) {
    __asm__ volatile("vfcvt.x.f.v v16, v12");
    __asm__ volatile("vfcvt.f.x.v v20, v16");
  }
}
__attribute__((noinline)) static void p1(uint32_t avl) {
  set_vl(avl);
  for (int i = 0; i < PROBE_ITERS; ++i) {
    __asm__ volatile("vadd.vx v16, v12, %0" ::"r"(127));
    __asm__ volatile("vsll.vi v16, v16, 23");
  }
}
__attribute__((noinline)) static void p2(uint32_t avl) {
  set_vl(avl);
  for (int i = 0; i < PROBE_ITERS; ++i) {
    __asm__ volatile("vfadd.vv v16, v12, v12");
    __asm__ volatile("vadd.vx v16, v16, %0" ::"r"(127));
  }
}
__attribute__((noinline)) static void p3(uint32_t avl) {
  set_vl(avl);
  for (int i = 0; i < PROBE_ITERS; ++i) {
    __asm__ volatile("vfcvt.x.f.v v16, v12");
    __asm__ volatile("vadd.vx v16, v16, %0" ::"r"(127));
  }
}
__attribute__((noinline)) static void p4(uint32_t avl) {
  set_vl(avl);
  __asm__ volatile("vadd.vx v16, v12, %0" ::"r"(1)); // v16 settled long before
  __asm__ volatile("fence" ::: "memory");
  for (int i = 0; i < PROBE_ITERS; ++i) {
    __asm__ volatile("vfmacc.vv v24, v4, v8");
    __asm__ volatile("vfmacc.vv v28, v24, v8");
    __asm__ volatile("vfmacc.vv v24, v28, v8");
    __asm__ volatile(
        "vadd.vx v16, v16, %0" ::"r"(127)); // independent of the chain
  }
}
__attribute__((noinline)) static void p5(uint32_t avl) {
  set_vl(avl);
  for (int i = 0; i < PROBE_ITERS; ++i) {
    __asm__ volatile("vadd.vx v16, v12, %0" ::"r"(127));
    __asm__ volatile("vfadd.vv v20, v16, v12");
  }
}
// The SwiGLU body from qwen-ffn-down/swiglu.h, register for register (constants
// from src).
__attribute__((noinline)) static void p6(uint32_t avl) {
  size_t vl = set_vl(avl);
  const elem_t c = src[1];
  for (int i = 0; i < PROBE_ITERS; ++i) {
    __asm__ volatile("vfsgnjx.vv v12, v4, v4");
    __asm__ volatile("vfsgnjn.vv v12, v12, v12");
    __asm__ volatile("vfmax.vf v12, v12, %0" ::"f"(c));
    __asm__ volatile("vfmul.vf v16, v12, %0" ::"f"(c));
    __asm__ volatile("vfcvt.x.f.v v16, v16");
    __asm__ volatile("vfcvt.f.x.v v20, v16");
    __asm__ volatile("vfnmsac.vf v12, %0, v20" ::"f"(c));
    __asm__ volatile("vfnmsac.vf v12, %0, v20" ::"f"(c));
    __asm__ volatile("vfmv.v.f v24, %0" ::"f"(c));
    __asm__ volatile("vfmacc.vf v24, %0, v12" ::"f"(c));
    __asm__ volatile("vfmv.v.f v28, %0" ::"f"(c));
    __asm__ volatile("vfmacc.vv v28, v24, v12");
    __asm__ volatile("vadd.vx v16, v16, %0" ::"r"(127));
    __asm__ volatile("vsll.vi v16, v16, 23");
    __asm__ volatile("vfmul.vv v20, v24, v16");
  }
  (void)vl;
}

__attribute__((noinline)) static void p7(uint32_t avl) {
  size_t vl;
#if PROBE_RAW_LOADS
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(avl));
  __asm__ volatile("vle16.v v4, (%0)" ::"r"(src) : "memory");
#else
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(16));
  __asm__ volatile("vle16.v v4, (%0)" ::"r"(src) : "memory");
  __asm__ volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"(avl));
#endif
  __asm__ volatile("vfwadd.vv v16, v4, v4");
  __asm__ volatile("vsetvli zero, %0, e32, m2, ta, ma" ::"r"(vl));
  __asm__ volatile("vadd.vx v20, v16, %0" ::"r"(1));
  __asm__ volatile("vsetvli zero, %0, e16, m1, ta, ma" ::"r"(vl));
  __asm__ volatile("vfncvt.f.f.w v24, v16");
  __asm__ volatile("vadd.vx v28, v24, %0" ::"r"(1));
}

typedef void (*phase_fn)(uint32_t);
static const phase_fn phases[] = {p0, p1, p2, p3, p4, p5, p6, p7};
static const char *const names[] = {
    "P0_FPU_FPU_dep",  "P1_IPU_IPU_dep",         "P2_FPU_IPU_dep",
    "P3_CONV_IPU_dep", "P4_FPU_chain_IPU_indep", "P5_IPU_FPU_dep",
    "P6_swiglu_body",  "P7_widen_narrow"};

int main(void) {
  const uint32_t cid = mempool_get_core_id(), ncores = mempool_get_core_count();
  mempool_barrier_init(cid);
  if (cid == 0) {
    // No int->float conversion: on the unfixed RTL (images before df049c78)
    // fcvt.s.w also writes x[rd], and the compiler's `fcvt.s.w ft2, a0` here
    // clobbered sp.
    elem_t v = 1.0f;
    for (int i = 0; i < 64; ++i) {
      src[i] = v;
      v += 0.25f;
    }
    printf("[VPROBE] start sew=%u ncores=%u lmul=m%u iters=%u first_phase=%u\n",
           (unsigned)PROBE_SEW, ncores, (unsigned)PROBE_LMUL,
           (unsigned)PROBE_ITERS, (unsigned)PROBE_FIRST_PHASE);
  }
  mempool_barrier(ncores);
  for (uint32_t p = PROBE_FIRST_PHASE; p < sizeof(phases) / sizeof(phases[0]);
       ++p) {
#if !PROBE_RAW_LOADS
    initialize_vectors();
#endif
    for (uint32_t avl = PROBE_SEW == 16 ? 16 : 8; avl >= 1; --avl)
      phases[p](avl);
    mark(cid, ncores, names[p]);
  }
  if (cid == 0)
    printf("[VPROBE] ALL_DONE\n");
  mempool_barrier(ncores);
  return 0;
}
