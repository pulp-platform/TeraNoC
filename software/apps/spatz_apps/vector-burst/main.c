// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0

// Simple vector-burst load test: issue aligned 16-word vector loads and
// store them back to memory, then verify with scalar loads.

// clang-format off

#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#define BURST_WORDS 16
#define BURST_BYTES (BURST_WORDS * 4)

static uint32_t __attribute__((aligned(BURST_BYTES))) src[2 * BURST_WORDS];
static uint32_t __attribute__((aligned(BURST_BYTES))) dst[2 * BURST_WORDS];

int main() {
  const uint32_t cid = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();

  mempool_barrier_init(cid);

  if (cid == 0) {
    for (uint32_t i = 0; i < 2 * BURST_WORDS; ++i) {
      src[i] = i + 1;
      dst[i] = 0;
    }
  }

  mempool_barrier(num_cores);

  if (cid == 0) {
    size_t gvl;

    asm volatile("vsetvli %[gvl], %[vl], e32, m1, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(BURST_WORDS));

    // First 16-word burst load/store.
    asm volatile("vle32.v v0, (%0)" :: "r"(src) : "memory");
    asm volatile("vse32.v v0, (%0)" :: "r"(dst) : "memory");

    // Second 16-word burst load/store (next aligned block).
    asm volatile("vle32.v v1, (%0)" :: "r"(src + BURST_WORDS) : "memory");
    asm volatile("vse32.v v1, (%0)" :: "r"(dst + BURST_WORDS) : "memory");

    printf("vector_burst: gvl=%u\n", (unsigned)gvl);

    if (gvl != BURST_WORDS) {
      printf("vector_burst: ERROR gvl mismatch (expected %u)\n", (unsigned)BURST_WORDS);
    }

    // Scalar verify of stored data.
    uint32_t errors = 0;
    for (uint32_t i = 0; i < 2 * BURST_WORDS; ++i) {
      if (dst[i] != src[i]) {
        printf("[FAIL] vector_burst: idx=%u src=%u dst=%u\n",
                (unsigned)i, (unsigned)src[i], (unsigned)dst[i]);
        errors++;
      } else {
        printf("[PASS] vector_burst: idx=%u src=%u dst=%u\n",
                (unsigned)i, (unsigned)src[i], (unsigned)dst[i]);
      }
    }
    if (errors != 0) {
      printf("vector_burst: ERROR mismatches=%u\n", (unsigned)errors);
    } else {
      printf("vector_burst: PASS all data matched\n");
    }
  }

  mempool_barrier(num_cores);
  return 0;
}

// clang-format on
