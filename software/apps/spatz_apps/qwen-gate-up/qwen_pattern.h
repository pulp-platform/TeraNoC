// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// The synthetic operand pattern, shared by the target and by the host-side
// generator that writes the preloaded images. One definition, so a preloaded
// operand and the expectation a check build verifies cannot disagree.
//
// Every value is exactly representable in fp16, so the whole fill-and-verify
// path is integer stores, integer loads and integer compares.
#ifndef QWEN_PATTERN_H
#define QWEN_PATTERN_H

#include <stdint.h>
#include "data/qwen_shape.h"

#define QWEN_STAGES_N 2u  // gate and up
#define QWEN_UNIT_K0 3u  // which X column the unit pattern lights up
#define QWEN_FP16_ONE 0x3c00u
// (n/8) for n = -4..4.
static const uint16_t qwen_grid[9] = {0xb800u, 0xb600u, 0xb400u, 0xb000u, 0x0000u,
                                      0x3000u, 0x3400u, 0x3600u, 0x3800u};

// Gate and up get DIFFERENT weights, so a run that fed one projection the other's
// base would fail rather than quietly agree with itself.
static inline uint16_t qwen_w_bits(uint32_t stage, uint32_t k, uint32_t p) {
#if QWEN_CHECK == 2
  (void)stage;
  (void)k;
  (void)p;
  return QWEN_FP16_ONE;
#else
  return qwen_grid[(k * 7u + p * 3u + stage * 5u) % 9u];
#endif
}

// Which X column row b's one-hot lights up. MODULO K: without the wrap, B=64 at
// K=64 ran the index off the end for b >= 61, leaving those rows all-zero while the
// expected value was not -- 21,846 spurious mismatches that looked like a kernel bug
// and were a harness bug.
#define QWEN_UNIT_COL(b) (((QWEN_UNIT_K0) + (b)) % (uint32_t)QWEN_K)

static inline uint16_t qwen_x_bits(uint32_t b, uint32_t k) {
#if QWEN_CHECK == 2
  (void)b;
  (void)k;
  return QWEN_FP16_ONE;
#else
  return (k == QWEN_UNIT_COL(b)) ? QWEN_FP16_ONE : 0u;
#endif
}


#endif
