// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
// fp16 vector library for the Qwen decode kernels (docs/qwen3_8_27b/mixer_plan.md, D5/D7).
//
// Everything is fp16 in and out AND inside (D7); value accuracy is not the goal, a few percent
// is fine (script/vec_ref.py report: exp 2.6%, sigmoid / SiLU 2.1%, softplus 1.8% worst case).
//
// FP-ONLY. No integer vector instruction appears anywhere, so no IPU <-> FPU unit switch and no
// short-vector wedge (docs/spatz_short_vl_wedge_handover.md) at any vl. The usual exp builds 2^n
// in the exponent field with vadd/vsll (integer); here instead
//     exp(x) = p(x / 32)^32,  p = degree-4 Taylor,  5 squarings,
// which costs ~13 FPU ops and needs no exponent manipulation. vfmv.v.f (slide unit) is only
// used to set the two constant registers, once per call. This Spatz has no divider: 1/d is a
// linear seed plus one Newton step.
//
// Two ways to use it:
//   * qc_v{exp,sigmoid,silu,softplus}_f16(x, y, n): stand-alone, memory to memory, any n.
//   * QC_EXP / QC_ENEG / QC_SIGMOID / QC_SOFTPLUS: the same op sequences on named vector
//     registers, for a kernel epilogue that already holds its data in registers (D4, fusion).
//     They need `const qc_k_t qck = qc_k();` in scope and the constant registers set with
//     QC_SET_CONST_REGS(C2, ONE) at the current SEW/LMUL.
//
// The op order here is the order script/vec_ref.py emulates; the device must match that model
// bit for bit (qwen-vec-test checks it). Change both together.
#ifndef QC_VEC_H
#define QC_VEC_H

#include <stddef.h>
#include <stdint.h>

// ---- scalar constants without fmv.w.x and without .rodata in L2 ------------------------------
// fmv.w.x clobbers the GPR on images before df049c78, and a .rodata literal sits in L2 where
// every core fetching it serialises on one bank (~14k cycles at 8x8). Bits go through this
// core's own stack instead.
static inline _Float16 qc_f16_imm(uint16_t bits) {
  volatile uint16_t slot = bits;
  _Float16 v;
  __asm__ volatile("flh %0, 0(%1)" : "=f"(v) : "r"(&slot) : "memory");
  return v;
}
static inline float qc_f32_imm(uint32_t bits) {
  volatile uint32_t slot = bits;
  float v;
  __asm__ volatile("flw %0, 0(%1)" : "=f"(v) : "r"(&slot) : "memory");
  return v;
}
static inline uint32_t qc_f32_bits(float f) {
  volatile float slot = f;
  return *(volatile uint32_t *)&slot;
}

// fp16 bit patterns (vec_ref.py: K_*). Keep in sync.
#define QC_K_XMIN 0xcc80u     // -18     exp clamp: exp(-18) rounds to exactly 0 in fp16
#define QC_K_XMAX 0x4980u     // 11      exp clamp (exp(11) = 59874 < 65504)
#define QC_K_INV32 0x2800u    // 1/32
#define QC_K_MINV32 0xa800u   // -1/32
#define QC_K_C4 0x2955u       // 1/24
#define QC_K_C3 0x3155u       // 1/6
#define QC_K_C2 0x3800u       // 1/2
#define QC_K_ONE 0x3c00u      // 1
#define QC_K_TWO 0x4000u      // 2
#define QC_K_ZERO 0x0000u     // 0
#define QC_K_ABSMAX 0x4c40u   // 17
#define QC_K_RA 0xb788u       // -8/17   1/d seed: 24/17 - 8/17 d on [1, 2]
#define QC_K_RB 0x3da6u       // 24/17
#define QC_K_BIG 0x7400u      // 16384   sigmoid branch select
#define QC_K_Q0 0x3bffu       // log1p(u) = u (q0 + q1 u + q2 u^2 + q3 u^3), u in [0, 1]
#define QC_K_Q1 0xb7c9u
#define QC_K_Q2 0x3413u
#define QC_K_Q3 0xacc8u

typedef struct {
  _Float16 xmin, xmax, inv32, minv32, c4, c3, c2, one, two, zero, absmax, ra, rb, big;
  _Float16 q0, q1, q2, q3;
} qc_k_t;

static inline qc_k_t qc_k(void) {
  qc_k_t k;
  k.xmin = qc_f16_imm(QC_K_XMIN);
  k.xmax = qc_f16_imm(QC_K_XMAX);
  k.inv32 = qc_f16_imm(QC_K_INV32);
  k.minv32 = qc_f16_imm(QC_K_MINV32);
  k.c4 = qc_f16_imm(QC_K_C4);
  k.c3 = qc_f16_imm(QC_K_C3);
  k.c2 = qc_f16_imm(QC_K_C2);
  k.one = qc_f16_imm(QC_K_ONE);
  k.two = qc_f16_imm(QC_K_TWO);
  k.zero = qc_f16_imm(QC_K_ZERO);
  k.absmax = qc_f16_imm(QC_K_ABSMAX);
  k.ra = qc_f16_imm(QC_K_RA);
  k.rb = qc_f16_imm(QC_K_RB);
  k.big = qc_f16_imm(QC_K_BIG);
  k.q0 = qc_f16_imm(QC_K_Q0);
  k.q1 = qc_f16_imm(QC_K_Q1);
  k.q2 = qc_f16_imm(QC_K_Q2);
  k.q3 = qc_f16_imm(QC_K_Q3);
  return k;
}

// Round to nearest even (the model's rounding; reset value, set explicitly anyway).
static inline void qc_rne(void) { __asm__ volatile("csrwi frm, 0"); }

// ---- register-level sequences (fusion) -------------------------------------------------------
// Register arguments are string literals ("v4"); C2 and ONE hold 1/2 and 1 broadcast.
#define QC_SET_CONST_REGS(C2, ONE)                                       \
  do {                                                                   \
    __asm__ volatile("vfmv.v.f " C2 ", %0" ::"f"(qck.c2));               \
    __asm__ volatile("vfmv.v.f " ONE ", %0" ::"f"(qck.one));             \
  } while (0)

// The exponential. QC_EXP_FAKE=1 (default) stands in for an exponent instruction in the Spatz FPU:
// ONE vector FPU op (vfmul on the FMA pipeline, a MAC's latency, reading only x -- a vfmacc would
// add a false dependency on its destination), and the scalar one is one fmadd.s. The values are
// wrong: timing only. QC_EXP_FAKE=0: the FP-only polynomial below (the vector tests and every
// value check need it).
#ifndef QC_EXP_FAKE
#define QC_EXP_FAKE 1
#endif

// P = exp(32 Y) for Y in [-0.54, 0.35]: Taylor, then 5 squarings. 10 ops. Y is kept.
#define QC_POLY_SQ(Y, P, C2, ONE)                                        \
  do {                                                                   \
    __asm__ volatile("vfmul.vf " P ", " Y ", %0" ::"f"(qck.c4));         \
    __asm__ volatile("vfadd.vf " P ", " P ", %0" ::"f"(qck.c3));         \
    __asm__ volatile("vfmadd.vv " P ", " Y ", " C2);                     \
    __asm__ volatile("vfmadd.vv " P ", " Y ", " ONE);                    \
    __asm__ volatile("vfmadd.vv " P ", " Y ", " ONE);                    \
    __asm__ volatile("vfmul.vv " P ", " P ", " P);                       \
    __asm__ volatile("vfmul.vv " P ", " P ", " P);                       \
    __asm__ volatile("vfmul.vv " P ", " P ", " P);                       \
    __asm__ volatile("vfmul.vv " P ", " P ", " P);                       \
    __asm__ volatile("vfmul.vv " P ", " P ", " P);                       \
  } while (0)

#if QC_EXP_FAKE
#define QC_EXP(X, A, P, C2, ONE) __asm__ volatile("vfmul.vv " P ", " X ", " ONE)
#define QC_ENEG(X, A, P, C2, ONE) __asm__ volatile("vfmul.vv " P ", " X ", " ONE)
#else
// P = exp(X), X clamped in place to [-17, 11]; A is scratch. 13 ops.
#define QC_EXP(X, A, P, C2, ONE)                                         \
  do {                                                                   \
    __asm__ volatile("vfmax.vf " X ", " X ", %0" ::"f"(qck.xmin));       \
    __asm__ volatile("vfmin.vf " X ", " X ", %0" ::"f"(qck.xmax));       \
    __asm__ volatile("vfmul.vf " A ", " X ", %0" ::"f"(qck.inv32));      \
    QC_POLY_SQ(A, P, C2, ONE);                                           \
  } while (0)

// P = exp(-|X|); X kept, A scratch. 13 ops.
#define QC_ENEG(X, A, P, C2, ONE)                                        \
  do {                                                                   \
    __asm__ volatile("vfsgnjx.vv " A ", " X ", " X);                     \
    __asm__ volatile("vfmin.vf " A ", " A ", %0" ::"f"(qck.absmax));     \
    __asm__ volatile("vfmul.vf " A ", " A ", %0" ::"f"(qck.minv32));     \
    QC_POLY_SQ(A, P, C2, ONE);                                           \
  } while (0)
#endif

// R = sigmoid(X); X kept, A P D scratch. 23 ops.
//   e = exp(-|x|), d = 1 + e, r = 1/d (seed + 1 Newton step), sigmoid = r * (x > 0 ? 1 : e);
//   the select is min(e + 16384 max(x, 0), 1).
#define QC_SIGMOID(X, A, P, D, R, C2, ONE)                               \
  do {                                                                   \
    QC_ENEG(X, A, P, C2, ONE);                                           \
    __asm__ volatile("vfadd.vf " D ", " P ", %0" ::"f"(qck.one));        \
    __asm__ volatile("vfmul.vf " R ", " D ", %0" ::"f"(qck.ra));         \
    __asm__ volatile("vfadd.vf " R ", " R ", %0" ::"f"(qck.rb));         \
    __asm__ volatile("vfmul.vv " A ", " D ", " R);                       \
    __asm__ volatile("vfrsub.vf " A ", " A ", %0" ::"f"(qck.two));       \
    __asm__ volatile("vfmul.vv " R ", " R ", " A);                       \
    __asm__ volatile("vfmax.vf " D ", " X ", %0" ::"f"(qck.zero));       \
    __asm__ volatile("vfmacc.vf " P ", %0, " D ::"f"(qck.big));          \
    __asm__ volatile("vfmin.vf " P ", " P ", %0" ::"f"(qck.one));        \
    __asm__ volatile("vfmul.vv " R ", " R ", " P);                       \
  } while (0)

// R = SiLU(X) = X sigmoid(X). 24 ops.
#define QC_SILU(X, A, P, D, R, C2, ONE)                                  \
  do {                                                                   \
    QC_SIGMOID(X, A, P, D, R, C2, ONE);                                  \
    __asm__ volatile("vfmul.vv " R ", " R ", " X);                       \
  } while (0)

// R = softplus(X) = max(X, 0) + log1p(exp(-|X|)); X kept, A P D scratch. 22 ops.
#define QC_SOFTPLUS(X, A, P, D, R, C2, ONE)                              \
  do {                                                                   \
    QC_ENEG(X, A, P, C2, ONE);                                           \
    __asm__ volatile("vfmul.vf " R ", " P ", %0" ::"f"(qck.q3));         \
    __asm__ volatile("vfadd.vf " R ", " R ", %0" ::"f"(qck.q2));         \
    __asm__ volatile("vfmul.vv " R ", " R ", " P);                       \
    __asm__ volatile("vfadd.vf " R ", " R ", %0" ::"f"(qck.q1));         \
    __asm__ volatile("vfmul.vv " R ", " R ", " P);                       \
    __asm__ volatile("vfadd.vf " R ", " R ", %0" ::"f"(qck.q0));         \
    __asm__ volatile("vfmul.vv " R ", " R ", " P);                       \
    __asm__ volatile("vfmax.vf " D ", " X ", %0" ::"f"(qck.zero));       \
    __asm__ volatile("vfadd.vv " R ", " D ", " R);                       \
  } while (0)

// ---- stand-alone routines: y[i] = f(x[i]), i < n -----------------------------------------------
// e16 m2 (64 elements per strip), registers v0..v15: X v0, A v2, P v4, D v6, R v8, C2 v12,
// ONE v14. Any n, including n <= 4 (FP-only, so no short-vector wedge).
#define QC_STRIP_BEGIN(n)                                                   \
  const qc_k_t qck = qc_k();                                                \
  size_t _vl;                                                               \
  qc_rne();                                                                 \
  __asm__ volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(_vl) : "r"(64u)); \
  QC_SET_CONST_REGS("v12", "v14");                                          \
  while (n) {                                                               \
    __asm__ volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(_vl) : "r"(n)); \
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(x) : "memory");
#define QC_STRIP_END(OUT)                                                   \
    __asm__ volatile("vse16.v " OUT ", (%0)" ::"r"(y) : "memory");          \
    x += _vl;                                                               \
    y += _vl;                                                               \
    n -= _vl;                                                               \
  }

static inline void qc_vexp_f16(const _Float16 *x, _Float16 *y, size_t n) {
  QC_STRIP_BEGIN(n)
  QC_EXP("v0", "v2", "v4", "v12", "v14");
  QC_STRIP_END("v4")
}
static inline void qc_vsigmoid_f16(const _Float16 *x, _Float16 *y, size_t n) {
  QC_STRIP_BEGIN(n)
  QC_SIGMOID("v0", "v2", "v4", "v6", "v8", "v12", "v14");
  QC_STRIP_END("v8")
}
static inline void qc_vsilu_f16(const _Float16 *x, _Float16 *y, size_t n) {
  QC_STRIP_BEGIN(n)
  QC_SILU("v0", "v2", "v4", "v6", "v8", "v12", "v14");
  QC_STRIP_END("v8")
}
static inline void qc_vsoftplus_f16(const _Float16 *x, _Float16 *y, size_t n) {
  QC_STRIP_BEGIN(n)
  QC_SOFTPLUS("v0", "v2", "v4", "v6", "v8", "v12", "v14");
  QC_STRIP_END("v8")
}

// ---- reductions and scalars (fp32: the RMSNorm sums, D7) -----------------------------------------
// vl = 1 for a reduction's zero load and its readback store: they need element 0 only, and a
// full-vl access is wider than this core's 64 B slot -- it spills into the next cores' slots.
#define QC_VL1(SEW)                                                                           \
  do {                                                                                        \
    size_t _vl1;                                                                              \
    __asm__ volatile("vsetvli %0, %1, " SEW ", m1, ta, ma" : "=r"(_vl1) : "r"(1u));          \
  } while (0)
// sum of x[i]^2 in fp32: vfwmacc.vv into e32 m4 accumulators (v16), one vfredusum at the end.
static inline float qc_sumsq_f16(const _Float16 *x, size_t n) {
  size_t vl;
  float zero = qc_f32_imm(0u), s;
  __asm__ volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(64u));
  __asm__ volatile("vfmv.v.f v16, %0" ::"f"(zero));
  __asm__ volatile("vfmv.s.f v24, %0" ::"f"(zero));
  const size_t vmax = vl;
  while (n) {
    __asm__ volatile("vsetvli %0, %1, e16, m2, tu, ma" : "=r"(vl) : "r"(n));
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(x) : "memory");
    __asm__ volatile("vfwmacc.vv v16, v0, v0");
    x += vl;
    n -= vl;
  }
  __asm__ volatile("vsetvli zero, %0, e32, m4, ta, ma" ::"r"(vmax));
  __asm__ volatile("vfredusum.vs v24, v16, v24");
  __asm__ volatile("vfmv.f.s %0, v24" : "=f"(s));
  return s;
}

// 1/sqrt(x), fp32 scalar: bit seed + 3 Newton steps (no fsqrt / fdiv in this FPU).
static inline float qc_rsqrt_f32(float x) {
  const uint32_t i = 0x5F3759DFu - (qc_f32_bits(x) >> 1);
  float y = qc_f32_imm(i);
  const float hx = qc_f32_imm(0x3f000000u) * x, c15 = qc_f32_imm(0x3fc00000u);
  for (int it = 0; it < 3; ++it) y = y * (c15 - hx * y * y);
  return y;
}

// 1/x, fp32 scalar, x > 0: bit seed + 3 Newton steps.
static inline float qc_recip_f32(float x) {
  float y = qc_f32_imm(0x7EF311C7u - qc_f32_bits(x));
  const float two = qc_f32_imm(0x40000000u);
  for (int it = 0; it < 3; ++it) y = y * (two - x * y);
  return y;
}

// exp(x), fp32 scalar, for x <= 0 (softmax corrections): clamp at -87, x / 256 into [-0.34, 0],
// degree-5 Taylor, 8 squarings. FP-only, like the vector routine.
static inline float qc_exp_f32(float x) {
#if QC_EXP_FAKE
  float r;  // one scalar FPU op standing in for an exponent instruction (value meaningless)
  __asm__ volatile("fmadd.s %0, %1, %1, %1" : "=f"(r) : "f"(x));
  return r;
#endif
  const float lo = qc_f32_imm(0xc2ae0000u);  // -87
  x = __builtin_fmaxf(x, lo);  // no data-dependent branch (X-safe on RTL)
  const float y = x * qc_f32_imm(0x3b800000u);  // 1/256
  float p = y * qc_f32_imm(0x3c088889u);        // 1/120
  p = (p + qc_f32_imm(0x3d2aaaabu)) * y;        // 1/24
  p = (p + qc_f32_imm(0x3e2aaaabu)) * y;        // 1/6
  p = (p + qc_f32_imm(0x3f000000u)) * y;        // 1/2
  p = (p + qc_f32_imm(0x3f800000u)) * y;        // 1
  p = p + qc_f32_imm(0x3f800000u);
  for (int it = 0; it < 8; ++it) p = p * p;
  return p;
}

#endif  // QC_VEC_H
