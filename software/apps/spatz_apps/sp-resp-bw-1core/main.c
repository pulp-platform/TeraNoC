// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// sp-resp-bw-1core: per-core burst-load response-bandwidth microbenchmark.
//
// ACTIVE_CORES cores (default 1) stream back-to-back REMOTE 16-word vle32 bursts
// (VL=16 / LMUL=1 = one 64B line) with NO compute and NO per-iteration barrier.
// Default geometry: DISTINCT contiguous lines in REMOTE_G (no coalescing, no
// same-address collision) -- the clean single-requester beat-spread case. Build
// with -DSAME_ADDR to stream ONE line repeatedly (non-mergeable same-address
// pileup + post-stream congestion-tail stress). A 4-way v-reg round-robin keeps
// the VLSU ROB full (double-buffered) so there is no inter-burst idle gap.
// Reports the realized per-core burst-load response bandwidth ([RESPBW] cyc,
// words, words_per_1000cyc); compare group_mshr_drain_beats=2 (2-wide beat-spread
// receive) against the default single-beat drain.
//
// clang-format off

#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#ifndef ACTIVE_CORES
#define ACTIVE_CORES 1           // single core: clean per-core beat-spread BW (no coalescing/contention)
#endif
#ifndef STREAM_ITERS
#define STREAM_ITERS 64u         // back-to-back bursts/core (mult of 4). Bump for a longer sustained
                                 // measurement; SAME_ADDR (same-line) has a slow post-stream congestion
                                 // tail (beat-spread disables coalescing) so keep it modest there.
#endif
#ifndef REMOTE_G
#define REMOTE_G 1u              // remote owner group the stream targets (remote to group 0)
#endif

#define PC_WORDS        64u
#define WORDS_PER_LINE  16u      // = mempool_pkg::MaxBurstWords (one 64B burst line)
#define BANKS_PER_TILE     ((uint32_t)(NUM_CORES_PER_TILE) * (uint32_t)(BANKING_FACTOR) * (uint32_t)(N_FU))
#define GROUP_STRIDE_BYTES (BANKS_PER_TILE * (uint32_t)(NUM_TILES_PER_GROUP) * 4u)

// L1, word-interleaved across all groups (same layout convention as sp-mshr-burst-test).
static uint32_t percore[NUM_CORES * PC_WORDS] __attribute__((section(".l1_prio"), aligned(4096)));

static inline uint32_t l1_group_of(const volatile void *p) {
  return ((uint32_t)p / GROUP_STRIDE_BYTES) % (uint32_t)NUM_GROUPS;
}
// First 16-word line (word index) that lives in group g -- a FIXED address (same for
// all cores), so streamed reads of it (and lines +GROUP_STRIDE apart, also group g)
// coalesce while staying remote to the active group-0 cores.
static uint32_t line_in_group(uint32_t g) {
  const uint32_t nl = (uint32_t)(NUM_CORES * PC_WORDS) / WORDS_PER_LINE;
  for (uint32_t line = 0; line < nl; ++line)
    if (l1_group_of(&percore[line * WORDS_PER_LINE]) == g) return line * WORDS_PER_LINE;
  return 0u;
}
static inline void prof_begin(void) { asm volatile("" ::: "memory"); write_csr(trace, 1); asm volatile("" ::: "memory"); }
static inline void prof_end(void)   { asm volatile("" ::: "memory"); write_csr(trace, 0); asm volatile("" ::: "memory"); }

int main(void) {
  const uint32_t cid       = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  const uint32_t active    = (ACTIVE_CORES == 0u) ? num_cores : (uint32_t)ACTIVE_CORES;
  const uint32_t is_active = (cid < active);

  mempool_barrier_init(cid);

  // Initialise the streamed region to defined data (core-strided).
  for (uint32_t i = cid; i < (uint32_t)(NUM_CORES * PC_WORDS); i += num_cores) percore[i] = i;
  mempool_barrier(num_cores);

  // Stream geometry: base line in REMOTE_G. Step by ONE LINE (distinct contiguous 64B lines within
  // REMOTE_G's window -> distinct destination tiles, NO coalescing/same-address pileup). This isolates
  // whether the beat-spread deadlock is the same-address pileup (then this completes) or general.
  const uint32_t base_w   = line_in_group(REMOTE_G);
#ifdef SAME_ADDR
  // Same-address pileup stress: every burst reads the SAME remote line -> N non-mergeable
  // beat_spread entries to one address. Deadlocked before the MSHR same-address serialize (M7).
  const uint32_t stride_w = 0u;
#else
  const uint32_t stride_w = WORDS_PER_LINE;
#endif
  uint32_t n_lines = (stride_w ? ((uint32_t)(NUM_CORES * PC_WORDS) - base_w) / stride_w : 1u);
  if (n_lines == 0u) n_lines = 1u;

  uint32_t cyc = 0u;
  if (is_active) {
    size_t vl;
    asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"(WORDS_PER_LINE));

    // No active-subset barrier here: mixing mempool_barrier(active) with the surrounding
    // mempool_barrier(num_cores) corrupts the shared barrier -> premature EOC / no UART output.
    // The init mempool_barrier(num_cores) above already aligns the active cores' start.
    const uint32_t t0 = mempool_get_timer();
    prof_begin();                            // open the [BP] / [MSHR stats] window

    // Sustained: back-to-back coalesced remote bursts, no compute, no barrier.
    for (uint32_t k = 0; k < (uint32_t)STREAM_ITERS; k += 4u) {
      volatile uint32_t *a0 = &percore[base_w + ((k + 0u) % n_lines) * stride_w];
      volatile uint32_t *a1 = &percore[base_w + ((k + 1u) % n_lines) * stride_w];
      volatile uint32_t *a2 = &percore[base_w + ((k + 2u) % n_lines) * stride_w];
      volatile uint32_t *a3 = &percore[base_w + ((k + 3u) % n_lines) * stride_w];
      asm volatile("vle32.v v8,  (%0)" :: "r"(a0) : "memory");
      asm volatile("vle32.v v9,  (%0)" :: "r"(a1) : "memory");
      asm volatile("vle32.v v10, (%0)" :: "r"(a2) : "memory");
      asm volatile("vle32.v v11, (%0)" :: "r"(a3) : "memory");
    }
    asm volatile("fence" ::: "memory");      // drain the last bursts to completion

    prof_end();
    cyc = mempool_get_timer() - t0;
  }
  mempool_barrier(num_cores);

  if (cid == 0) {
    const uint32_t words = (uint32_t)STREAM_ITERS * WORDS_PER_LINE;       // words loaded / core
    const uint32_t wp1k  = cyc ? (words * 1000u) / cyc : 0u;              // words per 1000 cyc (x1000 to keep ints)
    // Keep each printf small (<=3 args) so it fits the 512B per-core stack.
    printf("[RESPBW] cyc=%u words=%u\n", (unsigned)cyc, (unsigned)words);
    printf("[RESPBW] words_per_1000cyc=%u n_lines=%u\n", (unsigned)wp1k, (unsigned)n_lines);
  }
  mempool_barrier(num_cores);
  return 0;
}
