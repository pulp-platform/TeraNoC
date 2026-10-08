// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// The synthetic operand pattern, shared by the target and by the host-side
// generator that writes the preloaded images. One definition, so a preloaded
// operand and the expectation a check build verifies cannot disagree.
//
// Every value is exactly representable in fp16 and every partial sum the kernel forms
// is exact too, so the whole fill-and-verify path is integer stores, integer loads and
// integer compares.
//
// qwen-ffn-down: the parent's one-hot pattern lit ONE X column per row. Under the K split
// that column sits in one K part, so a partial sum that is never added back leaves the
// result unchanged -- gate-up's B=1 check could not see a missing reduction. Here each H
// row lights one column in EVERY K part of EVERY tile (the "multi-hot" pattern), so a
// dropped, duplicated or misaddressed part, tile or row changes the sum.
#ifndef QWEN_PATTERN_H
#define QWEN_PATTERN_H

#include <stdint.h>
#include "qwen_layout.h"  // QWEN_KT, QWEN_KT_CORE, QWEN_KSPLIT, QWEN_STAGES_N

#define QWEN_UNIT_K0 3u  // offset of the lit column inside a K part
#define QWEN_FP16_ONE 0x3c00u
// (n/8) for n = -4..4: entry n is (n - 4) eighths.
static const uint16_t qwen_grid[9] = {0xb800u, 0xb600u, 0xb400u, 0xb000u, 0x0000u,
                                      0x3000u, 0x3400u, 0x3600u, 0x3800u};
static inline uint32_t qwen_grid_idx(uint32_t stage, uint32_t k, uint32_t p) {
  return (k * 7u + p * 3u + stage * 5u) % 9u;
}

static inline uint16_t qwen_w_bits(uint32_t stage, uint32_t k, uint32_t p) {
#if QWEN_CHECK == 2
  (void)stage;
  (void)k;
  (void)p;
  return QWEN_FP16_ONE;
#else
  return qwen_grid[qwen_grid_idx(stage, k, p)];
#endif
}

// Multi-hot: in K tile t, K part j (QWEN_KT_CORE rows each), row b lights position
// (K0 + b + t + j) mod QWEN_KT_CORE. Varying with t and j as well as b means a tile or part
// read from the wrong place lands on a different W row and a different grid value.
#define QWEN_HOT_TERMS ((uint32_t)(QWEN_K / QWEN_KT_CORE))  // lit columns per row
static inline uint32_t qwen_hot_pos(uint32_t b, uint32_t t, uint32_t j) {
  return (QWEN_UNIT_K0 + b + t + j) % (uint32_t)QWEN_KT_CORE;
}
static inline uint32_t qwen_hot_k(uint32_t b, uint32_t term) {
  const uint32_t t = term / (uint32_t)QWEN_KSPLIT, j = term % (uint32_t)QWEN_KSPLIT;
  return t * (uint32_t)QWEN_KT + j * (uint32_t)QWEN_KT_CORE + qwen_hot_pos(b, t, j);
}

static inline uint16_t qwen_x_bits(uint32_t b, uint32_t k) {
#if QWEN_CHECK == 2
  (void)b;
  (void)k;
  return QWEN_FP16_ONE;
#else
  const uint32_t t = k / (uint32_t)QWEN_KT, r = k % (uint32_t)QWEN_KT;
  const uint32_t j = r / (uint32_t)QWEN_KT_CORE, pos = r % (uint32_t)QWEN_KT_CORE;
  return (pos == qwen_hot_pos(b, t, j)) ? QWEN_FP16_ONE : 0u;
#endif
}

// Through the SwiGLU prologue (ffn_swiglu=1), checks 1 and 2 feed G and U that make H exactly
// the pattern above: SiLU(16) / 16 = 0.99999989 rounds to 1.0 in fp16, and SiLU(0) * 0 = +0.
#define QWEN_G_ON 0x4c00u  // 16.0
#define QWEN_U_ON 0x2c00u  // 1/16
static inline uint16_t qwen_g_bits(uint32_t b, uint32_t k) {
  return (qwen_x_bits(b, k) == QWEN_FP16_ONE) ? QWEN_G_ON : 0u;
}
static inline uint16_t qwen_u_bits(uint32_t b, uint32_t k) {
  return (qwen_x_bits(b, k) == QWEN_FP16_ONE) ? QWEN_U_ON : 0u;
}

// fp16 bits of s/8 for an integer s with |s| < 2048: exact (11 significant bits).
static inline uint16_t qwen_eighths_to_fp16(int32_t s) {
  if (s == 0) return 0u;  // +0: every partial sum starts at +0 and x + (-0) keeps it
  const uint32_t sign = (s < 0) ? 0x8000u : 0u;
  uint32_t mag = (uint32_t)(s < 0 ? -s : s), e = 0;
  while ((mag >> (e + 1)) != 0u) ++e;  // e = floor(log2(mag)), mag < 2^11
  const uint32_t mant = ((mag << (10u - e)) & 0x3ffu);
  return (uint16_t)(sign | ((e - 3u + 15u) << 10) | mant);
}

// Expected result in eighths: the grid values of the lit W rows. It depends on p only
// through 3p mod 9, i.e. on p mod 3 -- which is what lets the verify precompute it per row.
static inline int32_t qwen_expect_eighths(uint32_t stage, uint32_t b, uint32_t p) {
  int32_t s = 0;
  for (uint32_t term = 0; term < QWEN_HOT_TERMS; ++term)
    s += (int32_t)qwen_grid_idx(stage, qwen_hot_k(b, term), p) - 4;
  return s;
}

#endif
