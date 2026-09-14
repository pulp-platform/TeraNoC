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

typedef struct {
  uint32_t spread;
  uint32_t peak;
} gemm_hash_score_t;

static inline gemm_hash_score_t gemm_hash_evaluate(
    uint32_t a_base, uint32_t b_base, uint32_t group, uint32_t banks,
    uint32_t burst, uint32_t shift, uint32_t bits) {
  const uint32_t steps = GEMM_MIN(GEMM_N, MSHR_HASH_SAMPLE_STEPS);
  const uint32_t bytes = GEMM_LOAD_BYTES(KERNEL_SIZE);
  uint32_t bank_load[banks];
  gemm_hash_score_t score = {0, 0};
  for (uint32_t bank = 0; bank < banks; ++bank) bank_load[bank] = 0;
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
          uint32_t bank = gemm_hash_bank(word, shift, 0, banks);
          occupied |= (uint64_t)1 << bank;
          ++bank_load[bank];
        }
      }
      if (!unique_b) continue;
      const uint32_t address = b_base + (n * GEMM_P + col) * GEMM_ELEM_BYTES;
      const uint32_t eligible = gemm_burst_eligible(address, bytes);
      const uint32_t words = (address % 4 + bytes + 3) / 4;
      for (uint32_t w = 0; w < words;) {
        const uint32_t word = address / 4 + w;
        const uint32_t count = gemm_burst_next(word, words - w, eligible);
        if ((count > 1) == burst) {
          uint32_t bank = gemm_hash_bank(word, shift, bits, banks);
          occupied |= (uint64_t)1 << bank;
          ++bank_load[bank];
        }
        w += count;
      }
    }
    while (occupied) {
      occupied &= occupied - 1;
      ++score.spread;
    }
  }
  for (uint32_t bank = 0; bank < banks; ++bank)
    if (bank_load[bank] > score.peak) score.peak = bank_load[bank];
  return score;
}

static inline uint32_t gemm_hash_score(uint32_t a_base, uint32_t b_base,
                                       uint32_t group, uint32_t banks,
                                       uint32_t burst, uint32_t shift,
                                       uint32_t bits) {
  return gemm_hash_evaluate(a_base, b_base, group, banks, burst, shift, bits).spread;
}

static inline int gemm_hash_better(gemm_hash_score_t candidate,
                                   uint32_t candidate_shift,
                                   uint32_t candidate_bits,
                                   gemm_hash_score_t best,
                                   uint32_t best_shift,
                                   uint32_t best_bits) {
  if (candidate.spread != best.spread) return candidate.spread > best.spread;
  if (candidate.peak != best.peak) return candidate.peak < best.peak;
  if (candidate_shift != best_shift) return candidate_shift < best_shift;
  return candidate_bits < best_bits;
}

// Search each class independently because the RTL provides independent
// single/burst selectors. First maximize banks reached at each sampled step,
// then spread requests over time by minimizing the busiest bank. The final
// shift/bit ordering keeps fully tied choices deterministic and matches the
// dashboard candidate ranking. Return 0 if geometry is invalid.
static inline int gemm_hash_select(uint32_t a_base, uint32_t b_base,
                                   uint32_t group, uint32_t banks,
                                   uint32_t *single, uint32_t *burst,
                                   uint32_t *bits) {
  if (!banks || banks > 64 || (banks & (banks - 1)) ||
      group >= GEMM_ACTIVE_GROUPS) return 0;
  gemm_hash_score_t best_s =
      gemm_hash_evaluate(a_base, b_base, group, banks, 0, *single, 0);
  gemm_hash_score_t best_b =
      gemm_hash_evaluate(a_base, b_base, group, banks, 1, *burst, *bits);
  for (uint32_t shift = 4; shift <= 10; ++shift) {
    gemm_hash_score_t score =
        gemm_hash_evaluate(a_base, b_base, group, banks, 0, shift, 0);
    if (gemm_hash_better(score, shift, 0, best_s, *single, 0)) {
      best_s = score;
      *single = shift;
    }
    for (uint32_t bb = 0; bb <= 1; ++bb) {
      if (shift < GEMM_BURST_HASH_ALIGN + bb) continue;
      score = gemm_hash_evaluate(a_base, b_base, group, banks, 1, shift, bb);
      if (gemm_hash_better(score, shift, bb, best_b, *burst, *bits)) {
        best_b = score;
        *burst = shift;
        *bits = bb;
      }
    }
  }
  return 1;
}
#endif
