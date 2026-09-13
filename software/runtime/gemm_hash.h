// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
#ifndef GEMM_HASH_H
#define GEMM_HASH_H

#include <stdint.h>
#include "gemm_config.h"
#include "gemm_burst.h"

// Bounded, deterministic bank-spread model for the first row/column microtile
// at evenly spaced reduction steps. This does not model arrival skew, cache
// lifetime or NoC contention, and is not a runtime performance autotuner.
#ifndef MSHR_HASH_SEARCH
#define MSHR_HASH_SEARCH 1
#endif
#ifndef MSHR_HASH_SAMPLE_STEPS
#define MSHR_HASH_SAMPLE_STEPS 16
#endif
#if MSHR_HASH_SAMPLE_STEPS < 1 || MSHR_HASH_SAMPLE_STEPS > 128
#error "MSHR_HASH_SAMPLE_STEPS must be in [1, 128]"
#endif

static inline uint32_t gemm_hash_bank(uint32_t word, uint32_t shift,
                                      uint32_t bits, uint32_t banks) {
  return (((word >> shift) << bits) | ((word >> GEMM_BURST_HASH_ALIGN) & bits)) & (banks - 1);
}

static inline uint32_t gemm_hash_score(uint32_t a_base, uint32_t b_base,
                                       uint32_t group, uint32_t banks,
                                       uint32_t burst, uint32_t shift,
                                       uint32_t bits) {
  const uint32_t steps = GEMM_MIN(GEMM_N, MSHR_HASH_SAMPLE_STEPS);
  const uint32_t bytes = GEMM_LOAD_BYTES(KERNEL_SIZE);
  uint32_t score = 0;
  for (uint32_t s = 0; s < steps; ++s) {
    const uint32_t n = s * (GEMM_N - 1) / (steps > 1 ? steps - 1 : 1);
    uint64_t occupied = 0;
    for (uint32_t core = 0; core < GEMM_CPG; ++core) {
      uint32_t row, col;
#if MATMUL_DECODE_SPLIT
      const uint32_t cid = group * GEMM_CPG + core;
      row = (cid % GEMM_DECODE_ROWS(KERNEL_SIZE)) * KERNEL_SIZE;
      col = (cid / GEMM_DECODE_ROWS(KERNEL_SIZE)) * GEMM_PSPAN(KERNEL_SIZE);
#else
      const uint32_t rows = GEMM_ROWS_PER_GROUP;
      row = group * rows + ((GEMM_ROW_TILES(KERNEL_SIZE) < GEMM_CPG)
        ? (core / GEMM_SHARE_A(KERNEL_SIZE)) * KERNEL_SIZE
        : core * (rows / GEMM_CPG));
      col = (core % GEMM_SHARE_A(KERNEL_SIZE)) * GEMM_PSPAN(KERNEL_SIZE);
#endif
      // Model each shared operand address once, not once per subscribing core.
#if MATMUL_DECODE_SPLIT
      const uint32_t unique_a = core < GEMM_SHARE_B(KERNEL_SIZE);
      const uint32_t unique_b = core % GEMM_SHARE_B(KERNEL_SIZE) == 0;
#else
      const uint32_t unique_a = core % GEMM_SHARE_A(KERNEL_SIZE) == 0;
      const uint32_t unique_b = core < GEMM_SHARE_A(KERNEL_SIZE);
#endif
      if (!burst && unique_a) {
        for (uint32_t r = 0; r < KERNEL_SIZE; ++r) {
          uint32_t word = (a_base + ((row + r) * GEMM_N + n)
                           * GEMM_ELEM_BYTES) / 4;
          occupied |= (uint64_t)1 << gemm_hash_bank(word, shift, 0, banks);
        }
      }
      if (!unique_b) continue;
      const uint32_t address = b_base + (n * GEMM_P + col) * GEMM_ELEM_BYTES;
      const uint32_t eligible = gemm_burst_eligible(address, bytes);
      const uint32_t words = (address % 4 + bytes + 3) / 4;
      for (uint32_t w = 0; w < words;) {
        const uint32_t word = address / 4 + w;
        const uint32_t count = gemm_burst_next(word, words - w, eligible);
        if ((count > 1) == burst)
          occupied |= (uint64_t)1 << gemm_hash_bank(word, shift, bits, banks);
        w += count;
      }
    }
    while (occupied) {
      occupied &= occupied - 1;
      ++score;
    }
  }
  return score;
}

// Retain the seed on ties. Search each class independently because the RTL
// provides independent single/burst selectors. Return 0 if geometry is invalid.
static inline int gemm_hash_select(uint32_t a_base, uint32_t b_base,
                                   uint32_t group, uint32_t banks,
                                   uint32_t *single, uint32_t *burst,
                                   uint32_t *bits) {
  if (!banks || banks > 64 || (banks & (banks - 1)) ||
      group >= GEMM_ACTIVE_GROUPS) return 0;
  const uint32_t steps = GEMM_MIN(GEMM_N, MSHR_HASH_SAMPLE_STEPS);
  // A bank-count ceiling is valid for every mixture of scalar and burst requests.
  // Shape-only ceilings based on words/16 can terminate before testing short bursts.
  const uint32_t max_s = steps * banks;
  const uint32_t max_b = steps * banks;
  uint32_t best_s = gemm_hash_score(a_base, b_base, group, banks, 0, *single, 0);
  uint32_t best_b = gemm_hash_score(a_base, b_base, group, banks, 1, *burst, *bits);
  // Once every possible distinct line/bank is reached, no candidate can
  // improve the score. This avoids exhaustive startup work on regular GEMMs.
  for (uint32_t shift = 4; shift <= 10 && (best_s < max_s || best_b < max_b); ++shift) {
    uint32_t score;
    if (best_s < max_s) {
      score = gemm_hash_score(a_base, b_base, group, banks, 0, shift, 0);
      if (score > best_s) {
        best_s = score;
        *single = shift;
      }
    }
    for (uint32_t bb = 0; bb <= 1; ++bb) {
      if (shift < GEMM_BURST_HASH_ALIGN + bb || best_b == max_b) continue;
      score = gemm_hash_score(a_base, b_base, group, banks, 1, shift, bb);
      if (score > best_b) {
        best_b = score;
        *burst = shift;
        *bits = bb;
      }
    }
  }
  return 1;
}
#endif
