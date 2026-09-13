// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
#ifndef GEMM_BURST_H
#define GEMM_BURST_H
#include <stdint.h>

// Unit-stride, unmasked GEMM loads with vstart=0 and 32-bit memory words.
// Match the integration's VLSU parameters; runtime.mk supplies build overrides.
#ifndef GEMM_BURST_ENABLED
#define GEMM_BURST_ENABLED 1
#endif
#ifndef GEMM_BURST_TILE_WORDS
#define GEMM_BURST_TILE_WORDS (NUM_CORES_PER_TILE * N_FU * BANKING_FACTOR)
#endif
#ifndef GEMM_BURST_LANES
#define GEMM_BURST_LANES N_FU
#endif
#ifndef GEMM_BURST_ROB_DEPTH
#define GEMM_BURST_ROB_DEPTH 32
#endif
#ifndef GEMM_BURST_MAX_WORDS
#define GEMM_BURST_MAX_WORDS 16
#endif
_Static_assert(GEMM_BURST_TILE_WORDS > 0 &&
               !(GEMM_BURST_TILE_WORDS & (GEMM_BURST_TILE_WORDS - 1)),
               "Tile words must match the power-of-two RTL bank stripe");
_Static_assert(GEMM_BURST_MAX_WORDS > 1 &&
               !(GEMM_BURST_MAX_WORDS & (GEMM_BURST_MAX_WORDS - 1)),
               "Maximum burst must be a power of two");
_Static_assert(GEMM_BURST_LANES > 0 && GEMM_BURST_ROB_DEPTH > 0,
               "Invalid VLSU geometry");
#define GEMM_BURST_HASH_ALIGN (__builtin_ctz(GEMM_BURST_MAX_WORDS))
#define GEMM_BURST_MODEL "tile-contained-v1"

static inline uint32_t gemm_burst_eligible(uint32_t address, uint32_t bytes) {
  const uint32_t tile_left = GEMM_BURST_TILE_WORDS -
                            (address / 4) % GEMM_BURST_TILE_WORDS;
  return GEMM_BURST_ENABLED && !(address % 4) && !(bytes % 4) && bytes >= 8 &&
    bytes <= GEMM_BURST_ROB_DEPTH * GEMM_BURST_LANES * 4 &&
    (!(GEMM_BURST_MAX_WORDS % GEMM_BURST_LANES) || bytes <= GEMM_BURST_MAX_WORDS * 4) &&
    (bytes <= tile_left * 4 || (!(address % (GEMM_BURST_LANES * 4)) &&
     !(GEMM_BURST_TILE_WORDS % GEMM_BURST_LANES) &&
     !(GEMM_BURST_MAX_WORDS % GEMM_BURST_LANES)));
}

// Returned length includes scalar tails. Classify by length > 1, not operand.
static inline uint32_t gemm_burst_next(uint32_t word, uint32_t remaining,
                                      uint32_t eligible) {
  if (!eligible) return 1;
  uint32_t count = GEMM_BURST_TILE_WORDS - word % GEMM_BURST_TILE_WORDS;
  if (count > GEMM_BURST_MAX_WORDS) count = GEMM_BURST_MAX_WORDS;
  if (count > remaining) count = remaining;
  // The VLSU refuses a burst longer than the per-lane ROB depth.
  return count > GEMM_BURST_ROB_DEPTH ? 1 : count;
}
#endif
