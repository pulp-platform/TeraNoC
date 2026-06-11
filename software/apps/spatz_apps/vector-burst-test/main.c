// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0

// Stress vector load/store test for burst-capable VLSU.
// Exercises aligned bursts, partial bursts, unaligned loads, and multi-burst lengths.

// clang-format off

#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#ifndef ACTIVE_CORES
#define ACTIVE_CORES 0 // 0 => use all cores
#endif

#define BURST_WORDS 16
#define BURST_BYTES (BURST_WORDS * 4)

#define NUM_TESTS 10
#define PER_CORE_WORDS 320

typedef struct {
  uint32_t len;
  uint32_t offset;
} burst_test_t;

static const burst_test_t tests[NUM_TESTS] = {
    {1,  0},  // aligned, short
    {2,  0},
    {4,  0},
    {8,  0},
    {16, 0},  // full burst
    {24, 0},  // burst + tail
    {32, 0},  // multiple bursts
    {64, 0},  // multiple bursts
    {7,  1},  // unaligned
    {20, 3},  // unaligned, not full
};

static uint32_t __attribute__((aligned(BURST_BYTES))) src[NUM_CORES * PER_CORE_WORDS];
static uint32_t __attribute__((aligned(BURST_BYTES))) dst[NUM_CORES * PER_CORE_WORDS];

// Shared error accumulator. The verdict is reported via the EOC return value
// (0 = PASS); [UART] detail is opt-in (-DVERDICT_PRINTF) to keep main's stack
// frame + printf within the 512B per-core stack.
static volatile uint32_t g_errors;

static inline uint32_t amo_add(volatile uint32_t *a, uint32_t v) {
  uint32_t old;
  asm volatile("amoadd.w %0, %2, (%1)" : "=r"(old) : "r"(a), "r"(v) : "memory");
  return old;
}

static inline void vload_store(uint32_t *src_ptr, uint32_t *dst_ptr, uint32_t len) {
  size_t gvl;
  uint32_t remaining = len;
  uint32_t *s = src_ptr;
  uint32_t *d = dst_ptr;

  while (remaining) {
    asm volatile("vsetvli %[gvl], %[len], e32, m1, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [len] "r"(remaining));
    asm volatile("vle32.v v0, (%0)" :: "r"(s) : "memory");
    asm volatile("vse32.v v0, (%0)" :: "r"(d) : "memory");
    s += gvl;
    d += gvl;
    remaining -= (uint32_t)gvl;
  }
}

int main() {
  const uint32_t cid = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  uint32_t active_cores = ACTIVE_CORES;
  uint32_t test_base[NUM_TESTS];
  uint32_t cursor = 0;

  if (active_cores == 0 || active_cores > num_cores) {
    active_cores = num_cores;
  }

  for (uint32_t t = 0; t < NUM_TESTS; ++t) {
    const uint32_t aligned = (cursor + (uint32_t)(BURST_WORDS - 1)) &
                             ~((uint32_t)(BURST_WORDS - 1));
    test_base[t] = aligned + tests[t].offset;
    cursor = test_base[t] + tests[t].len + 1;
  }

  mempool_barrier_init(cid);

  if (cid == 0) g_errors = 0;

  if (cursor > PER_CORE_WORDS) {
    if (cid == 0) {
      printf("vector-burst-test: ERROR PER_CORE_WORDS too small (%u > %u)\n",
             (unsigned)cursor, (unsigned)PER_CORE_WORDS);
    }
    mempool_barrier(num_cores);
    return 1;
  }

  if (cid < active_cores) {
    const uint32_t core_base = cid * PER_CORE_WORDS;
    for (uint32_t t = 0; t < NUM_TESTS; ++t) {
      const uint32_t base = core_base + test_base[t];
      for (uint32_t i = 0; i < tests[t].len; ++i) {
        src[base + i] = (cid << 24) ^ (t << 16) ^ i;
        dst[base + i] = 0;
      }
    }
  }

  mempool_barrier(num_cores);

  if (cid < active_cores) {
    const uint32_t core_base = cid * PER_CORE_WORDS;
    for (uint32_t t = 0; t < NUM_TESTS; ++t) {
      uint32_t *s = &src[core_base + test_base[t]];
      uint32_t *d = &dst[core_base + test_base[t]];
      vload_store(s, d, tests[t].len);
    }
  }

  mempool_barrier(num_cores);

  // Parallel verify: each core checks only its OWN dst region. The old design
  // had core 0 serially check all active_cores' data (~O(cores*data) remote
  // loads on one core) -> far too slow at 256 cores. Mismatches accumulate into
  // the shared g_errors via AMO.
  if (cid < active_cores) {
    const uint32_t core_base = cid * PER_CORE_WORDS;
    uint32_t my_errors = 0;
    for (uint32_t t = 0; t < NUM_TESTS; ++t) {
      const uint32_t base = core_base + test_base[t];
      for (uint32_t i = 0; i < tests[t].len; ++i) {
        const uint32_t exp = (cid << 24) ^ (t << 16) ^ i;
        if (dst[base + i] != exp) my_errors++;
      }
    }
    if (my_errors) (void)amo_add(&g_errors, my_errors);
  }

  mempool_barrier(num_cores);

#ifdef VERDICT_PRINTF
  if (cid == 0) {
    if (g_errors == 0) {
      printf("vector-burst-test: PASS (cores=%u tests=%u)\n",
             (unsigned)active_cores, (unsigned)NUM_TESTS);
    } else {
      printf("vector-burst-test: FAIL errors=%u\n", (unsigned)g_errors);
    }
  }
#endif

  mempool_barrier(num_cores);
  return (int)g_errors;
}

// clang-format on
