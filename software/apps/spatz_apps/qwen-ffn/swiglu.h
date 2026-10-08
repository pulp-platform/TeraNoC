// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// H = SiLU(G) * U = G * U * sigmoid(G), elementwise, fp16 in and out, fp32 inside.
//
// What the compiled Spatz offers (working_dir/spatz/hw/ip/spatz/src/spatz_decoder.sv),
// and what that forces:
//   * no divider (FDivSqrt = 0)          -> the reciprocal is a seed + Newton steps;
//   * no vfwcvt.f.f.v (fp16 -> fp32)     -> widen with vfwadd.vf x, +0.0 (exact);
//   * vfncvt.f.f.w, vfcvt.x.f.v / .f.x.v, vsll / vadd, vfsgnj*, vfmin / vfmax -- all present.
//
// Per element, e = exp(-|g|) in (0, 1], so d = 1 + e in (1, 2] and 1/d is well conditioned:
//   sigmoid(g) = 1/d          for g >= 0
//              = e/d          for g <  0          (= e^g / (1 + e^g))
//   exp(x), x = max(-|g|, -87): n = round(x log2 e), r = x - n ln2 (two-constant
//   Cody-Waite, |r| <= ln2/2), exp(r) by a degree-5 Taylor polynomial (rel. error < 2.5e-6),
//   2^n by writing n + 127 into the exponent field (n >= -126: always a normal float).
//   1/d: linear seed 24/17 - 8/17 d (rel. error <= 1/17 on [1, 2]), two Newton steps
//   (error <= (1/17)^4 = 1.2e-5), far below half an fp16 ulp (2.4e-4).
// Branch-free select of the g < 0 factor: ind = clamp(g * 2^100, 0, 1) is 1 for every
// g > 0 and 0 for g < 0 (g = 0 has e = 1, where both branches agree), and the factor is
// max(e, ind): 1 when g > 0, e when g < 0.
//
// About 35 vector ops per 64-element strip at e32/m4. The rounding mode is set to RNE
// (the rounding of vfcvt.x.f.v and of the final narrowing depends on it).
#ifndef QWEN_SWIGLU_H
#define QWEN_SWIGLU_H

#include <stddef.h>
#include <stdint.h>

// An fp32 value from its bit pattern, WITHOUT fmv.w.x and without touching L2.
//
// fmv.w.x cannot be used on this RTL: MemPool's Snitch (hardware/deps/snitch/src/snitch.sv, the
// FMV_W_X / FCVT_S_W / FCVT_S_WU case) offloads it to Spatz but lacks `write_rd = 1'b0`, so it
// ALSO writes the source value into integer register x[rd]. `fmv.w.x fa0, a4` overwrote a0 (the
// G pointer), fa1 -> a1, fa3 -> a3 (the length), ft1 -> ra, ft2 -> sp: the prologue then loaded
// from 0x3d2aaaa8 (the bits of 1/24) and the whole machine wedged (RTL only; GVSoC is correct).
// A literal is no better: it sits in .rodata in L2, and every core fetching the same words from
// one L2 bank cost ~13 cycles x cores (14k at 8x8). So: store the bits to this core's own stack
// (its sequential L1 memory, no contention) and flw them back.
static inline float f32_imm(uint32_t bits) {
  volatile uint32_t slot = bits;
  float f;
  __asm__ volatile("flw %0, 0(%1)" : "=f"(f) : "r"(&slot) : "memory");
  return f;
}

// h[i] = SiLU(g[i]) * u[i] for i in [0, n). h may be written to `nrep` copies,
// `rep_stride` elements apart (the H replicas of qwen_layout.h).
__attribute__((noinline)) static void swiglu_f16(const _Float16 *g, const _Float16 *u, _Float16 *h, uint32_t n,
                       uint32_t nrep, uint32_t rep_stride) {
  // Constants come from f32_imm (stack + flw, see above), never from .rodata in L2. The fp16
  // zero uses fmv.h.x, whose Snitch case does clear write_rd (checked), and the asm output
  // keeps clang from constant-folding a _Float16 it cannot then place in an "f" operand.
  _Float16 zero_h;
  __asm__ volatile("fmv.h.x %0, zero" : "=f"(zero_h));
  const float zero = f32_imm(0x00000000u), one = f32_imm(0x3f800000u);
  const float xmin = f32_imm(0xc2ae0000u);      // -87
  const float log2e = f32_imm(0x3fb8aa3bu);     // 1.44269504
  const float ln2_hi = f32_imm(0x3f317200u);    // 0.693145751953125 (n*ln2_hi exact)
  const float ln2_lo = f32_imm(0x35bfbe8eu);    // 1.4286068e-6
  const float c5 = f32_imm(0x3c088889u), c4 = f32_imm(0x3d2aaaabu);  // 1/120, 1/24
  const float c3 = f32_imm(0x3e2aaaabu), c2 = f32_imm(0x3f000000u);  // 1/6, 1/2
  const float s0 = f32_imm(0x3fb4b4b5u), s1 = f32_imm(0x3ef0f0f1u);  // 24/17, 8/17
  const float big = f32_imm(0x71800000u);       // 2^100
  __asm__ volatile("fsrmi 0" ::: "memory");     // RNE

  for (uint32_t i = 0; i < n;) {
    size_t vl;
    // Load at e16/m2 and widen into e32/m4.
    __asm__ volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(vl) : "r"(n - i));
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(g + i));
    __asm__ volatile("vle16.v v2, (%0)" ::"r"(u + i));
    __asm__ volatile("vfwadd.vf v4, v0, %0" ::"f"(zero_h));   // g32
    __asm__ volatile("vfwadd.vf v8, v2, %0" ::"f"(zero_h));   // u32
    __asm__ volatile("vsetvli zero, %0, e32, m4, ta, ma" ::"r"(vl));
    // x = max(-|g|, -87)
    __asm__ volatile("vfsgnjx.vv v12, v4, v4");
    __asm__ volatile("vfsgnjn.vv v12, v12, v12");
    __asm__ volatile("vfmax.vf v12, v12, %0" ::"f"(xmin));
    // n = round(x log2e) (int in v16), nf = float(n) (v20), r = x - nf ln2 (v12)
    __asm__ volatile("vfmul.vf v16, v12, %0" ::"f"(log2e));
    __asm__ volatile("vfcvt.x.f.v v16, v16");
    __asm__ volatile("vfcvt.f.x.v v20, v16");
    __asm__ volatile("vfnmsac.vf v12, %0, v20" ::"f"(ln2_hi));
    __asm__ volatile("vfnmsac.vf v12, %0, v20" ::"f"(ln2_lo));
    // p = exp(r), Horner with a scalar-splat per step (v24 / v28 alternate)
    __asm__ volatile("vfmv.v.f v24, %0" ::"f"(c4));
    __asm__ volatile("vfmacc.vf v24, %0, v12" ::"f"(c5));
    __asm__ volatile("vfmv.v.f v28, %0" ::"f"(c3));
    __asm__ volatile("vfmacc.vv v28, v24, v12");
    __asm__ volatile("vfmv.v.f v24, %0" ::"f"(c2));
    __asm__ volatile("vfmacc.vv v24, v28, v12");
    __asm__ volatile("vfmv.v.f v28, %0" ::"f"(one));
    __asm__ volatile("vfmacc.vv v28, v24, v12");
    __asm__ volatile("vfmv.v.f v24, %0" ::"f"(one));
    __asm__ volatile("vfmacc.vv v24, v28, v12");
    // e = p * 2^n (v20); 2^n = (n + 127) << 23 reinterpreted
    __asm__ volatile("vadd.vx v16, v16, %0" ::"r"(127));
    __asm__ volatile("vsll.vi v16, v16, 23");
    __asm__ volatile("vfmul.vv v20, v24, v16");
    // y = 1 / (1 + e): seed + two Newton steps (d in v12, y in v16, t in v24)
    __asm__ volatile("vfadd.vf v12, v20, %0" ::"f"(one));
    __asm__ volatile("vfmv.v.f v16, %0" ::"f"(s0));
    __asm__ volatile("vfnmsac.vf v16, %0, v12" ::"f"(s1));
    __asm__ volatile("vfmv.v.f v24, %0" ::"f"(one));
    __asm__ volatile("vfnmsac.vv v24, v12, v16");
    __asm__ volatile("vfmacc.vv v16, v16, v24");
    __asm__ volatile("vfmv.v.f v24, %0" ::"f"(one));
    __asm__ volatile("vfnmsac.vv v24, v12, v16");
    __asm__ volatile("vfmacc.vv v16, v16, v24");
    // factor = max(e, clamp(g * 2^100, 0, 1)) (v24)
    __asm__ volatile("vfmul.vf v24, v4, %0" ::"f"(big));
    __asm__ volatile("vfmax.vf v24, v24, %0" ::"f"(zero));
    __asm__ volatile("vfmin.vf v24, v24, %0" ::"f"(one));
    __asm__ volatile("vfmax.vv v24, v24, v20");
    // h = g * u * y * factor (v28), narrowed to fp16 (v0)
    __asm__ volatile("vfmul.vv v28, v4, v8");
    __asm__ volatile("vfmul.vv v28, v28, v16");
    __asm__ volatile("vfmul.vv v28, v28, v24");
    __asm__ volatile("vsetvli zero, %0, e16, m2, ta, ma" ::"r"(vl));
    __asm__ volatile("vfncvt.f.f.w v0, v28");
    for (uint32_t r = 0; r < nrep; ++r)
      __asm__ volatile("vse16.v v0, (%0)" ::"r"(h + r * rep_stride + i) : "memory");
    i += (uint32_t)vl;
  }
}

#endif
