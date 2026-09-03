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

#define NUM_TESTS 15
// Raised from 320 for the LMUL cases below (m8 alone is 128 elements).  Cost is
// 2 * NUM_CORES * PER_CORE_WORDS * 4 B: 6.8 MiB at 8x8 (14.9 MiB usable L1) and
// 1.7 MiB at 4x4 (3.6 MiB) -- fits both.
#define PER_CORE_WORDS 832

typedef struct {
  uint32_t len;
  uint32_t offset;
  uint32_t lmul;   // 1/2/4/8 -- selects vl, and therefore how many bursts one
                   // instruction spans.  At e32, VLEN=512: m1=64B, m2=128B,
                   // m4=256B, m8=512B.
} burst_test_t;

static const burst_test_t tests[NUM_TESTS] = {
    {1,  0, 1},  // aligned, short
    {2,  0, 1},
    {4,  0, 1},
    {8,  0, 1},
    {16, 0, 1},  // full burst
    {24, 0, 2},  // burst + tail
    {32, 0, 1},  // multiple bursts
    {64, 0, 4},  // multiple bursts
    {7,  1, 1},  // unaligned
    {20, 3, 2},  // unaligned, not full

    // ---- vl CEILING cases (added 2026-08-27) -------------------------------
    // use_port0_burst_req demands vl <= NrOutstandingLoads*MemDataWidthB -- 256 B
    // at ROB64, 128 B at ROB32.  Above it the load SILENTLY leaves the burst path:
    // still correct, just not a burst.  So these cases do not fail today; they are
    // here to be run against the [BURSTWHY] / "BURST DROPPED" probes, which say
    // whether the burst actually happened.
    {32,  0, 2},  // m2, 128 B -- 2 bursts, legal at ROB32 and ROB64
    {64,  0, 4},  // m4, 256 B -- 4 bursts, exactly AT the ROB64 ceiling; OVER at ROB32
    {128, 0, 8},  // m8, 512 B -- 8 bursts, OVER the ceiling at both depths
    {96,  0, 8},  // m8 partial: 384 B, over the ceiling AND with a tail
    {128, 1, 8},  // m8 unaligned: fails burst_addr_aligned too -- control that the
                  // non-burst path stays correct when several predicates fail at once
};

// ---------------------------------------------------------------------------------
// fp16 burst cases.  The burst path is WORD granular end to end -- a word's lane is its
// word index mod NrMemPorts -- so how many elements sit inside a 32-bit word must not
// affect the lane mapping.  These prove it: an e16 load packs TWO elements per word, so
// if anything downstream still reasoned in elements the halves would land transposed.
// (There is no longer an eligibility knob for this; every element width bursts.)
//
// len is in ELEMENTS (halfwords).  At VLEN=512, e16: m1=32, m2=64, m4=128, m8=256
// elements, i.e. the same 64/128/256/512 BYTES the e32 cases use.
#define NUM_TESTS16 7
static const burst_test_t tests16[NUM_TESTS16] = {
    {32,  0, 1},  // exactly one full burst, 64 B
    {64,  0, 2},  // 2 bursts
    {128, 0, 4},  // 4 bursts
    {256, 0, 8},  // 8 bursts -- 512 B, exactly at the admission ceiling
    {40,  0, 2},  // burst + tail: 80 B, a short trailing burst
    {34,  0, 1},  // 68 B -- one full burst then a ONE-WORD remainder (the word-path
                  // case that gives the other lanes a dummy)
    {36,  2, 2},  // unaligned: base not 64 B aligned, must stay correct off the burst path
};

// ---------------------------------------------------------------------------------
// Dual-load (H1 runahead) cases.  spatz_vlsu_dual_load=2 lets a second burst-safe load
// issue while the elder still drains, which only happens if two loads are actually
// co-resident -- so these deliberately issue load,load,store,store into DISJOINT
// register groups instead of the load,store,load,store the cases above use.
//
// The interesting corners:
//   - both at the maximum length: two m8 loads need 2x32 rows in each reorder buffer
//     and only 32 exist, so the allocator must THROTTLE, not deadlock.
//   - a tailed elder: dual_safe used to refuse any load whose vl is not a whole
//     multiple of a burst.  That restriction is gone, so this is new coverage.
//   - a one-word remainder under runahead: the elder pads the other lanes with dummies
//     while the younger is already allocating behind it.
#define NUM_DUAL 6
static const burst_test_t dual_tests[NUM_DUAL] = {
    {16,  0, 1},  // both short: plenty of room, runahead should fire freely
    {64,  0, 4},  // 256 B each: two fit exactly in the 32-deep buffers
    {128, 0, 8},  // 512 B each: CANNOT both fit -- throttle, do not wedge
    {24,  0, 2},  // tailed elder (96 B): newly allowed to run ahead
    {17,  0, 1},  // one-word remainder: dummy padding overlapping a younger load
    {20,  1, 2},  // unaligned pair: neither bursts, runahead must stay correct anyway
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

// LMUL is encoded in the instruction, not a register, so each multiplier needs its
// own vsetvli.  vl (bytes) = VLEN/8 * LMUL = 64 * LMUL at VLEN=512, which is what
// decides whether the load clears use_port0_burst_req's vl ceiling.
static inline void vload_store(uint32_t *src_ptr, uint32_t *dst_ptr, uint32_t len,
                               uint32_t lmul) {
  size_t gvl;
  uint32_t remaining = len;
  uint32_t *s = src_ptr;
  uint32_t *d = dst_ptr;

  while (remaining) {
    switch (lmul) {
      case 8:
        asm volatile("vsetvli %[gvl], %[len], e32, m8, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
      case 4:
        asm volatile("vsetvli %[gvl], %[len], e32, m4, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
      case 2:
        asm volatile("vsetvli %[gvl], %[len], e32, m2, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
      default:
        asm volatile("vsetvli %[gvl], %[len], e32, m1, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
    }
    // v0 is the base register of the group; m8 spans v0-v7, m4 v0-v3, m2 v0-v1.
    asm volatile("vle32.v v0, (%0)" :: "r"(s) : "memory");
    asm volatile("vse32.v v0, (%0)" :: "r"(d) : "memory");
    s += gvl;
    d += gvl;
    remaining -= (uint32_t)gvl;
  }
}

// e16 copy.  Same shape as vload_store, but two elements per 32-bit word -- which is the
// whole point: the lane mapping must not notice.
static inline void vload_store16(uint16_t *src_ptr, uint16_t *dst_ptr, uint32_t len,
                                 uint32_t lmul) {
  size_t gvl;
  uint32_t remaining = len;
  uint16_t *s = src_ptr;
  uint16_t *d = dst_ptr;

  while (remaining) {
    switch (lmul) {
      case 8:
        asm volatile("vsetvli %[gvl], %[len], e16, m8, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
      case 4:
        asm volatile("vsetvli %[gvl], %[len], e16, m4, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
      case 2:
        asm volatile("vsetvli %[gvl], %[len], e16, m2, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
      default:
        asm volatile("vsetvli %[gvl], %[len], e16, m1, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
    }
    asm volatile("vle16.v v0, (%0)" :: "r"(s) : "memory");
    asm volatile("vse16.v v0, (%0)" :: "r"(d) : "memory");
    s += gvl;
    d += gvl;
    remaining -= (uint32_t)gvl;
  }
}

// TWO independent copies with both loads issued before either store.  load,store,load,store
// serialises through the store's dependency on v0 and can never put two loads in the VLSU at
// once; this can, which is the only way dual_adv is reachable.  v0 and v8 are disjoint for
// every LMUL here (m8 spans v0-v7 and v8-v15).
static inline void vload2_store2(uint32_t *s0, uint32_t *d0,
                                 uint32_t *s1, uint32_t *d1,
                                 uint32_t len, uint32_t lmul) {
  size_t gvl;
  uint32_t remaining = len;

  while (remaining) {
    switch (lmul) {
      case 8:
        asm volatile("vsetvli %[gvl], %[len], e32, m8, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
      case 4:
        asm volatile("vsetvli %[gvl], %[len], e32, m4, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
      case 2:
        asm volatile("vsetvli %[gvl], %[len], e32, m2, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
      default:
        asm volatile("vsetvli %[gvl], %[len], e32, m1, ta, ma"
                     : [gvl] "=r"(gvl) : [len] "r"(remaining));
        break;
    }
    asm volatile("vle32.v v0, (%0)" :: "r"(s0) : "memory");
    asm volatile("vle32.v v8, (%0)" :: "r"(s1) : "memory");
    asm volatile("vse32.v v0, (%0)" :: "r"(d0) : "memory");
    asm volatile("vse32.v v8, (%0)" :: "r"(d1) : "memory");
    s0 += gvl; d0 += gvl;
    s1 += gvl; d1 += gvl;
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
      vload_store(s, d, tests[t].len, tests[t].lmul);
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

  // ===============================================================================
  // fp16 group.  REUSES src/dst -- the e32 group above is verified and the barrier
  // orders it, so the memory is free.  Reuse is what keeps PER_CORE_WORDS, and with it
  // the 8x8 L1 footprint, unchanged by these additions.
  // ===============================================================================
  {
    uint32_t base16[NUM_TESTS16];
    uint32_t c16 = 0;
    // Slots are aligned to 32 halfwords = 64 B, the burst alignment, so `offset` is the
    // only thing that can push a case off the burst path.
    for (uint32_t t = 0; t < NUM_TESTS16; ++t) {
      const uint32_t al = (c16 + 31u) & ~31u;
      base16[t] = al + tests16[t].offset;
      c16 = base16[t] + tests16[t].len + 1;
    }
    if (c16 > 2u * PER_CORE_WORDS) {
      if (cid == 0) printf("vector-burst-test: ERROR fp16 needs %u halfwords > %u\n",
                           (unsigned)c16, (unsigned)(2u * PER_CORE_WORDS));
      mempool_barrier(num_cores);
      return 1;
    }

    if (cid < active_cores) {
      uint16_t *s16 = (uint16_t *)&src[cid * PER_CORE_WORDS];
      uint16_t *d16 = (uint16_t *)&dst[cid * PER_CORE_WORDS];
      for (uint32_t t = 0; t < NUM_TESTS16; ++t)
        for (uint32_t i = 0; i < tests16[t].len; ++i) {
          s16[base16[t] + i] = (uint16_t)((t << 12) ^ (cid << 8) ^ i);
          d16[base16[t] + i] = 0;
        }
    }
    mempool_barrier(num_cores);

    if (cid < active_cores) {
      uint16_t *s16 = (uint16_t *)&src[cid * PER_CORE_WORDS];
      uint16_t *d16 = (uint16_t *)&dst[cid * PER_CORE_WORDS];
      for (uint32_t t = 0; t < NUM_TESTS16; ++t)
        vload_store16(&s16[base16[t]], &d16[base16[t]], tests16[t].len, tests16[t].lmul);
    }
    mempool_barrier(num_cores);

    if (cid < active_cores) {
      uint16_t *d16 = (uint16_t *)&dst[cid * PER_CORE_WORDS];
      uint32_t e = 0;
      for (uint32_t t = 0; t < NUM_TESTS16; ++t)
        for (uint32_t i = 0; i < tests16[t].len; ++i)
          if (d16[base16[t] + i] != (uint16_t)((t << 12) ^ (cid << 8) ^ i)) e++;
      if (e) (void)amo_add(&g_errors, e);
    }
    mempool_barrier(num_cores);
  }

  // ===============================================================================
  // Dual-load group.  Two independent streams per test so both loads are in the VLSU
  // at once; reuses src/dst again.
  // ===============================================================================
  {
    uint32_t dbase[NUM_DUAL];
    uint32_t cd = 0;
    for (uint32_t t = 0; t < NUM_DUAL; ++t) {
      const uint32_t al = (cd + (uint32_t)(BURST_WORDS - 1)) & ~((uint32_t)(BURST_WORDS - 1));
      dbase[t] = al + dual_tests[t].offset;
      // two streams, each len words, second one burst-aligned after the first
      cd = ((dbase[t] + dual_tests[t].len + (uint32_t)(BURST_WORDS - 1)) &
            ~((uint32_t)(BURST_WORDS - 1))) + dual_tests[t].len + 1;
    }
    if (cd > PER_CORE_WORDS) {
      if (cid == 0) printf("vector-burst-test: ERROR dual needs %u words > %u\n",
                           (unsigned)cd, (unsigned)PER_CORE_WORDS);
      mempool_barrier(num_cores);
      return 1;
    }

    if (cid < active_cores) {
      const uint32_t cb = cid * PER_CORE_WORDS;
      for (uint32_t t = 0; t < NUM_DUAL; ++t) {
        const uint32_t b0 = cb + dbase[t];
        const uint32_t b1 = cb + ((dbase[t] + dual_tests[t].len +
                                   (uint32_t)(BURST_WORDS - 1)) & ~((uint32_t)(BURST_WORDS - 1)));
        for (uint32_t i = 0; i < dual_tests[t].len; ++i) {
          src[b0 + i] = (cid << 20) ^ (t << 12) ^ i;
          src[b1 + i] = (cid << 20) ^ (t << 12) ^ 0x800u ^ i;
          dst[b0 + i] = 0;
          dst[b1 + i] = 0;
        }
      }
    }
    mempool_barrier(num_cores);

    if (cid < active_cores) {
      const uint32_t cb = cid * PER_CORE_WORDS;
      for (uint32_t t = 0; t < NUM_DUAL; ++t) {
        const uint32_t b0 = cb + dbase[t];
        const uint32_t b1 = cb + ((dbase[t] + dual_tests[t].len +
                                   (uint32_t)(BURST_WORDS - 1)) & ~((uint32_t)(BURST_WORDS - 1)));
        vload2_store2(&src[b0], &dst[b0], &src[b1], &dst[b1],
                      dual_tests[t].len, dual_tests[t].lmul);
      }
    }
    mempool_barrier(num_cores);

    if (cid < active_cores) {
      const uint32_t cb = cid * PER_CORE_WORDS;
      uint32_t e = 0;
      for (uint32_t t = 0; t < NUM_DUAL; ++t) {
        const uint32_t b0 = cb + dbase[t];
        const uint32_t b1 = cb + ((dbase[t] + dual_tests[t].len +
                                   (uint32_t)(BURST_WORDS - 1)) & ~((uint32_t)(BURST_WORDS - 1)));
        for (uint32_t i = 0; i < dual_tests[t].len; ++i) {
          if (dst[b0 + i] != ((cid << 20) ^ (t << 12) ^ i)) e++;
          if (dst[b1 + i] != ((cid << 20) ^ (t << 12) ^ 0x800u ^ i)) e++;
        }
      }
      if (e) (void)amo_add(&g_errors, e);
    }
    mempool_barrier(num_cores);
  }

#ifdef VERDICT_PRINTF
  if (cid == 0) {
    if (g_errors == 0) {
      printf("vector-burst-test: PASS (cores=%u e32=%u fp16=%u dual=%u)\n",
             (unsigned)active_cores, (unsigned)NUM_TESTS,
             (unsigned)NUM_TESTS16, (unsigned)NUM_DUAL);
    } else {
      printf("vector-burst-test: FAIL errors=%u\n", (unsigned)g_errors);
    }
  }
#endif

  mempool_barrier(num_cores);
  return (int)g_errors;
}

// clang-format on
