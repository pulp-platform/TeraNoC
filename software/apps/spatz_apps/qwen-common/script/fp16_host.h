// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// IEEE binary16 <-> double on the HOST, without _Float16 (the host GCC 8 does not have it).
// Both directions are exact where they can be: half -> double always is, double -> half
// rounds to nearest-even once (nearbyint in the default rounding mode), including the
// subnormal range and overflow to infinity.
#ifndef FP16_HOST_H
#define FP16_HOST_H

#include <math.h>
#include <stdint.h>

static inline double fp16_to_double(uint16_t h) {
  const int sign = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff;
  double v;
  if (e == 0x1f) v = m ? NAN : INFINITY;
  else if (e == 0) v = ldexp((double)m, -24);                 // subnormal
  else v = ldexp((double)(m | 0x400), e - 25);
  return sign ? -v : v;
}

static inline uint16_t double_to_fp16(double x) {
  const uint16_t s = signbit(x) ? 0x8000u : 0u;
  if (isnan(x)) return 0x7e00u;
  x = fabs(x);
  if (x >= 65520.0) return s | 0x7c00u;                       // rounds past the largest finite
  int e;
  (void)frexp(x, &e);                                         // x = m 2^e, m in [0.5, 1)
  if (x == 0.0 || e - 1 < -14) {                              // subnormal (or zero): units of 2^-24
    const double r = nearbyint(ldexp(x, 24));                 // 1024 is the smallest normal
    return s | (uint16_t)r;
  }
  double r = nearbyint(ldexp(x, 10 - (e - 1)));               // [1024, 2048]
  int E = e - 1;
  if (r >= 2048.0) { r = 1024.0; ++E; }
  if (E > 15) return s | 0x7c00u;
  return s | (uint16_t)((E + 15) << 10) | (uint16_t)((uint32_t)r - 1024u);
}


// ---- Exact fp16 arithmetic, for a bit-exact model of the kernel -----------------------
// Every finite fp16 value is an integer multiple of 2^-24, so every product of two is a
// multiple of 2^-48 below 2^32 and every sum of such terms fits a signed 128-bit integer in
// units of 2^-48. fma16/add16 form the exact result there and round it to fp16 ONCE (nearest,
// ties to even), which is what fpnew's fused fp16 FMA and add do. Infinities and NaNs are
// not modelled (the inputs are finite and every intermediate here stays in range).
typedef __int128 fp16_fix_t;

static inline fp16_fix_t fp16_to_fix(uint16_t h) {  // value * 2^48, exact
  const int e = (h >> 10) & 0x1f, m = h & 0x3ff;
  const fp16_fix_t mag = (e == 0) ? ((fp16_fix_t)m << 24) : ((fp16_fix_t)(m | 0x400) << (e + 23));
  return (h & 0x8000u) ? -mag : mag;
}

static inline uint16_t fix_to_fp16(fp16_fix_t x) {  // round-to-nearest-even
  const uint16_t s = (x < 0) ? 0x8000u : 0u;
  unsigned __int128 a = (unsigned __int128)(x < 0 ? -x : x);
  if (a == 0) return s;  // exact zero keeps the sign it was given (+0 for x == 0)
  const uint64_t hi = (uint64_t)(a >> 64), lo = (uint64_t)a;  // value = a * 2^-48
  const int msb = hi ? 127 - __builtin_clzll(hi) : 63 - __builtin_clzll(lo);
  // ulp in fix units: 2^24 for subnormals and [2^-14, 2^-13); 2^(msb - 10) above.
  const int ulp_shift = (msb - 10 > 24) ? msb - 10 : 24;
  const unsigned __int128 ulp = (unsigned __int128)1 << ulp_shift;
  unsigned __int128 q = a >> ulp_shift, rem = a & (ulp - 1), half = ulp >> 1;
  if (rem > half || (rem == half && (q & 1))) ++q;  // RNE
  // q * 2^(ulp_shift - 48): rebuild the fp16 fields (a carry into the next binade is fine).
  if (ulp_shift == 24)  // subnormal / smallest binade: q IS the bit pattern (1024.. = e 1,
    return s | (uint16_t)q;  // and a round-up to 2048 = 0x0800 = 2^-13, the next binade)
  int e = ulp_shift - 24 + 1;                        // exponent field for q in [1024, 2048)
  if (q >= 2048) { q >>= 1; ++e; }
  if (e >= 31) return s | 0x7c00u;
  return s | (uint16_t)(e << 10) | (uint16_t)(q & 0x3ffu);
}

// fma16(a, b, c) = round16(a * b + c), fused.
static inline uint16_t fma16(uint16_t a, uint16_t b, uint16_t c) {
  const fp16_fix_t pa = fp16_to_fix(a), pb = fp16_to_fix(b);
  // (a 2^48)(b 2^48) = ab 2^96: divide by 2^48 exactly (ab is a multiple of 2^-48).
  const fp16_fix_t prod = (pa / ((fp16_fix_t)1 << 24)) * (pb / ((fp16_fix_t)1 << 24));
  const fp16_fix_t sum = prod + fp16_to_fix(c);
  if (sum == 0) {  // IEEE: exact zero sum is +0 in RNE unless both addends are -0
    const int pneg = ((a ^ b) & 0x8000u) != 0, cneg = (c & 0x8000u) != 0;
    return (pneg && cneg) ? 0x8000u : 0u;
  }
  return fix_to_fp16(sum);
}
static inline uint16_t add16(uint16_t a, uint16_t b) {
  const fp16_fix_t sum = fp16_to_fix(a) + fp16_to_fix(b);
  if (sum == 0) return ((a & b) & 0x8000u) ? 0x8000u : 0u;
  return fix_to_fp16(sum);
}

#endif
