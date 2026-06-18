// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// MSHR + Spatz-VLSU-burst correctness regression test.
//
// A fast, self-checking baremetal test that exercises the group-MSHR
// (request merge + response multicast, single-word + burst, sub-request and
// bank-full overflow, peak occupancy, AMO / response cache) and the Spatz VLSU
// burst path (full / multi / non-full / no-burst shapes). All golden values are
// timing-independent: data phases
// read pre-initialised read-only shared arrays, AMO phases check deterministic
// reductions. Each phase is barrier-separated and self-checked; a per-phase
// fail bitmask is aggregated and core 0 prints a single PASS/FAIL verdict.
//
// Run alongside the core-memory-scoreboard VIP ([CMS] lines): the VIP catches
// MSHR-level over/under-delivery and stuck requests that the SW data-checks
// alone cannot observe. A true RTL deadlock (e.g. the force_send corner) shows
// up as the simulation never reaching the final "PASS"/"FAIL" line.
//
// clang-format off

#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#ifndef ACTIVE_CORES
#define ACTIVE_CORES 0   // 0 => use all cores
#endif

#define PC_WORDS    64   // per-core golden region (covers 3x16 wrap in P7)
#define BUF_WORDS   32   // local result buffer; kept small so main's stack frame
                         // fits the 512B per-core stack (seq_mem_size). Caps the
                         // largest single vld at VL=32.
#define N_SHARED_S  16   // shared words for the scalar-merge phase
#define N_SHARED_B  32   // shared words for the burst-merge phase
#define PRINT_CAP   24   // max detailed [FAIL] lines across all cores
#define VERDICT_PRINTF   // enable detailed per-phase verdict lines (stack-heavy; may overflow 512B stack)

// ---- Geometry for guaranteed cross-group (remote) targeting [P8/P9] ----
// group(byte_addr) = (addr / (NumBanksPerTile * NumTilesPerGroup * 4)) % NumGroups
// (mempool_tile.sv:1166); L1 base is 0 so an .l1 pointer IS the byte address.
#define WORDS_PER_LINE     16u   // = mempool_pkg::MaxBurstWords (one 64B burst line)
#define BANKS_PER_TILE     ((uint32_t)(NUM_CORES_PER_TILE) * (uint32_t)(BANKING_FACTOR) * (uint32_t)(N_FU))
#define GROUP_STRIDE_BYTES (BANKS_PER_TILE * (uint32_t)(NUM_TILES_PER_GROUP) * 4u)
#define CACHE_REPS         8u    // repeated single-word loads to provoke response-cache hits

// ---- Shared data (L1, word-interleaved across all groups) ----
static uint32_t percore [NUM_CORES * PC_WORDS] __attribute__((section(".l1_prio"), aligned(4096)));
static uint32_t shared_s[N_SHARED_S]           __attribute__((section(".l1_prio"), aligned(4096)));
static uint32_t shared_b[N_SHARED_B]           __attribute__((section(".l1_prio"), aligned(256)));
static uint32_t amo_cnt                         __attribute__((section(".l1_prio"), aligned(64)));
static uint32_t amo_mix                         __attribute__((section(".l1_prio"), aligned(64)));
static volatile uint32_t g_fail                 __attribute__((section(".l1_prio"), aligned(64)));
static volatile uint32_t g_print                __attribute__((section(".l1_prio"), aligned(64)));

// Deterministic golden patterns (read-only after init).
static inline uint32_t gold_pc(uint32_t cid, uint32_t i) { return 0xB0000000u + cid * 0x1000u + i; }
static inline uint32_t gold_s(uint32_t k)                { return 0xA0000000u + k; }
static inline uint32_t gold_b(uint32_t i)                { return 0xC0000000u + i; }
// percore golden by absolute word index (line owner = w / PC_WORDS).
static inline uint32_t gold_pc_w(uint32_t w)             { return gold_pc(w / PC_WORDS, w % PC_WORDS); }

// Group that owns L1 byte address p (interleaved region; L1 base == 0).
static inline uint32_t l1_group_of(const volatile void *p) {
  return ((uint32_t)p / GROUP_STRIDE_BYTES) % (uint32_t)NUM_GROUPS;
}
// 64B-aligned word index into percore[] for a line REMOTE to group `mg`, drawn
// from the first `nlines` lines (the initialised pool). Each 16-word line stays
// within one core's PC_WORDS region (owner constant) so gold_pc_w() applies.
// Wraps; with NUM_GROUPS>1 a remote line always exists.
static uint32_t remote_line(uint32_t mg, uint32_t slot, uint32_t nlines) {
  uint32_t line = (nlines ? slot % nlines : 0u);
  for (uint32_t t = 0; t < nlines; ++t) {
    if (l1_group_of(&percore[line * WORDS_PER_LINE]) != mg) break;
    line = (line + 1u) % nlines;
  }
  return line * WORDS_PER_LINE;
}
// PC_WORDS-aligned base of an owner region REMOTE to group `mg`. The whole region
// is one group, so up to PC_WORDS words read from it share golden gold_pc_w().
// Used by the per-core burst phases so they traverse the MSHR for ANY core count
// (a lone core in group 0 still targets another group -> its group-0 MSHR alloc).
static uint32_t remote_base(uint32_t mg, uint32_t slot) {
  const uint32_t no = (uint32_t)NUM_CORES;
  uint32_t o = slot % no;
  for (uint32_t t = 0; t < no; ++t) {
    if (l1_group_of(&percore[o * PC_WORDS]) != mg) break;
    o = (o + 1u) % no;
  }
  return o * PC_WORDS;
}

// ---- Atomics ----
static inline uint32_t amo_add(volatile uint32_t *a, uint32_t v) {
  uint32_t old;
  asm volatile("amoadd.w %0, %2, (%1)" : "=r"(old) : "r"(a), "r"(v) : "memory");
  return old;
}
static inline void amo_or(volatile uint32_t *a, uint32_t v) {
  uint32_t old;
  asm volatile("amoor.w %0, %2, (%1)" : "=r"(old) : "r"(a), "r"(v) : "memory");
  (void)old;
}

// ---- Vector load->store helpers (one vle/vse; LMUL picks beat count) ----
static inline void vld_m1(const uint32_t *s, uint32_t *d, uint32_t vl) {
  size_t g; asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(g) : "r"(vl));
  asm volatile("vle32.v v0, (%0)" :: "r"(s) : "memory");
  asm volatile("vse32.v v0, (%0)" :: "r"(d) : "memory");
  asm volatile("fence" ::: "memory");
}
static inline void vld_m2(const uint32_t *s, uint32_t *d, uint32_t vl) {
  size_t g; asm volatile("vsetvli %0, %1, e32, m2, ta, ma" : "=r"(g) : "r"(vl));
  asm volatile("vle32.v v0, (%0)" :: "r"(s) : "memory");
  asm volatile("vse32.v v0, (%0)" :: "r"(d) : "memory");
  asm volatile("fence" ::: "memory");
}
static inline void vld_m4(const uint32_t *s, uint32_t *d, uint32_t vl) {
  size_t g; asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(g) : "r"(vl));
  asm volatile("vle32.v v0, (%0)" :: "r"(s) : "memory");
  asm volatile("vse32.v v0, (%0)" :: "r"(d) : "memory");
  asm volatile("fence" ::: "memory");
}

// Record a failure for `phase`. The phase bit ends up in the EOC return value
// (g_fail). Detailed [FAIL] lines are opt-in (-DVERDICT_PRINTF) because the
// stack-heavy printf overflows the 512B per-core stack under main's frame.
static void fail(uint32_t phase, uint32_t cid, uint32_t idx, uint32_t exp, uint32_t got) {
  amo_or(&g_fail, 1u << phase);
#ifdef VERDICT_PRINTF
  if (amo_add(&g_print, 1) < PRINT_CAP) {
    printf("[FAIL] phase=%u core=%u idx=%u exp=0x%08x got=0x%08x\n",
           (unsigned)phase, (unsigned)cid, (unsigned)idx,
           (unsigned)exp, (unsigned)got);
  }
#else
  (void)cid; (void)idx; (void)exp; (void)got;
#endif
}
// Check buf[0..n) against gold(i); record first mismatch for `phase`.
#define CHECK(phase, buf, n, GOLD)                                       \
  do { for (uint32_t _i = 0; _i < (uint32_t)(n); ++_i) {                 \
         uint32_t _e = (GOLD);                                           \
         if ((buf)[_i] != _e) { fail((phase), cid, _i, _e, (buf)[_i]); break; } \
       } } while (0)

// Per-phase benchmark marker in the `trace` CSR (0x7d0). The written value (the
// phase number) (a) gates the [CMS]/[MSHR stats] profiling -- any non-zero value
// enables it -- and (b) is tapped by the TB (core_bench_phase) so the waveform
// shows WHICH phase is running as a 1..9 staircase. phase_end() writes 0 between
// phases, so each phase is also its own [MSHR stats] window. All cores call these
// (barrier-synced) so the global trace tracks the current phase.
static inline void phase_begin(uint32_t p) { asm volatile("" ::: "memory"); write_csr(trace, p); asm volatile("" ::: "memory"); }
static inline void phase_end(void)          { asm volatile("" ::: "memory"); write_csr(trace, 0); asm volatile("" ::: "memory"); }

int main() {
  const uint32_t cid       = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  const uint32_t my_group  = mempool_get_group_id();
  uint32_t active          = ACTIVE_CORES;
  if (active == 0 || active > num_cores) active = num_cores;
  const uint32_t on        = (cid < active);
  // Whole percore pool, in 64B lines. The remote phases draw targets from the
  // FULL pool (not just active cores' slices), so a line in a *different* group
  // exists even when a single core -- or only one group's cores -- run.
  const uint32_t nlines    = (uint32_t)(NUM_CORES * PC_WORDS) / WORDS_PER_LINE;

  // Per-core REMOTE targets, computed ONCE and reused by both init and phases, so
  // we initialise only what is read (not the whole pool): a single core then inits
  // ~96 words instead of 16384. All lie in a group != my_group.
  const uint32_t rb = on ? remote_base(my_group, cid)              : 0u; // P1/P6/P7 owner region
  const uint32_t w8 = on ? remote_line(my_group, cid,      nlines) : 0u; // P8 burst line
  const uint32_t w9 = on ? remote_line(my_group, cid + 1u, nlines) : 0u; // P9 single-word line

  uint32_t buf[BUF_WORDS];   // per-core local result buffer

  mempool_barrier_init(cid);

  // ---- Init: each active core writes ONLY the remote regions it will read
  // (rb owner region + the P8/P9 lines), so the golden is valid for exactly what
  // is loaded -- correct for any ACTIVE_CORES without a full-pool sweep. ----
  if (on) {
    for (uint32_t j = 0; j < PC_WORDS;       ++j) percore[rb + j] = gold_pc_w(rb + j);
    for (uint32_t j = 0; j < WORDS_PER_LINE; ++j) percore[w8 + j] = gold_pc_w(w8 + j);
    for (uint32_t j = 0; j < WORDS_PER_LINE; ++j) percore[w9 + j] = gold_pc_w(w9 + j);
  }
  if (cid == 0) {
    for (uint32_t k = 0; k < N_SHARED_S; ++k) shared_s[k] = gold_s(k);
    for (uint32_t i = 0; i < N_SHARED_B; ++i) shared_b[i] = gold_b(i);
    amo_cnt = 0; amo_mix = 0; g_fail = 0; g_print = 0;
  }
  mempool_barrier(num_cores);

  // ---- P1: VLSU burst shapes, per-core (isolates burst gen, no merge) ----
  phase_begin(1);
  if (on) {
    const uint32_t b = rb;   // REMOTE owner region (precomputed in main)
    vld_m1(&percore[b], buf, 16);  CHECK(1, buf, 16, gold_pc_w(b + _i));  // full burst
    vld_m2(&percore[b], buf, 32);  CHECK(1, buf, 32, gold_pc_w(b + _i));  // 2x16 bursts
    vld_m2(&percore[b], buf, 24);  CHECK(1, buf, 24, gold_pc_w(b + _i));  // burst + tail
    vld_m1(&percore[b], buf, 7);   CHECK(1, buf, 7,  gold_pc_w(b + _i));  // non-full
    vld_m4(&percore[b], buf, 32);  CHECK(1, buf, 32, gold_pc_w(b + _i));  // no-burst (multi-port)
  }
  mempool_barrier(num_cores);

  phase_end();
  phase_begin(2);
  // ---- P2: scalar single-word merge + multicast + overflow ----
  // All active cores read the SAME 8 words at the same time -> within each
  // group up to `cpg` cores contend per word (cpg=16 > MshrMergeReqs=8 => the
  // overflow path is exercised too). EnableMshrSingleReq single-word merge.
  if (on) {
    for (uint32_t k = 0; k < 8; ++k) {
      uint32_t v; asm volatile("lw %0, 0(%1)" : "=r"(v) : "r"(&shared_s[k]) : "memory");
      buf[k] = v;
    }
    asm volatile("fence" ::: "memory");
    CHECK(2, buf, 8, gold_s(_i));
  }
  mempool_barrier(num_cores);

  phase_end();
  phase_begin(3);
  // ---- P3: burst merge (cores in a group read the SAME aligned region) ----
  if (on) {
    vld_m1(&shared_b[0], buf, 16);
    CHECK(3, buf, 16, gold_b(_i));
  }
  mempool_barrier(num_cores);

  phase_end();
  phase_begin(4);
  // ---- P4: AMO reduction (deterministic: counter == #active) ----
  if (on) (void)amo_add(&amo_cnt, 1);
  mempool_barrier(num_cores);
  if (cid == 0 && amo_cnt != active) fail(4, cid, 0, active, amo_cnt);
  mempool_barrier(num_cores);

  phase_end();
  phase_begin(5);
  // ---- P5: AMO + concurrent loads (mix traffic; deterministic final) ----
  // Each active core does L amoadds of 1; everyone also loads the word in the
  // same window (stresses AMO-vs-cache). Final == L * #active (deterministic).
  {
    const uint32_t L = 4;
    if (on) {
      for (uint32_t it = 0; it < L; ++it) {
        (void)amo_add(&amo_mix, 1);
        uint32_t v; asm volatile("lw %0, 0(%1)" : "=r"(v) : "r"(&amo_mix) : "memory");
        (void)v;  // intermediate value is racy -> not checked
      }
    }
    mempool_barrier(num_cores);
    if (cid == 0 && amo_mix != L * active) fail(5, cid, 0, L * active, amo_mix);
    mempool_barrier(num_cores);
  }

  phase_end();
  phase_begin(6);
  // ---- P6: back-to-back bursts (ROB pressure -> force_send corner) ----
  // 4 consecutive LMUL=2 loads (4*32 beat-ids >> ROB=32) to stress the
  // burst_alloc / force_send path. Correctness-checked; a true hang (bug #1)
  // shows as the sim never reaching the verdict line.
  if (on) {
    const uint32_t b = rb;
    for (uint32_t r = 0; r < 4; ++r) {
      vld_m2(&percore[b], buf, 32);
      CHECK(6, buf, 32, gold_pc_w(b + _i));
    }
  }
  mempool_barrier(num_cores);

  phase_end();
  phase_begin(7);
  // ---- P7: meta_id wrap across consecutive bursts (3x16 = 48 beat-ids) ----
  if (on) {
    const uint32_t b = rb;
    for (uint32_t r = 0; r < 3; ++r) {
      vld_m1(&percore[b + r * 16], buf, 16);
      CHECK(7, buf, 16, gold_pc_w(b + r * 16 + _i));
    }
  }
  mempool_barrier(num_cores);

  phase_end();
  phase_begin(8);
  // ---- P8: distinct remote bursts -> peak MSHR occupancy + bank-full bypass ----
  // Every active core bursts a DISTINCT line in a *remote* group at the same
  // time, driving mshr_valid_max toward the full MshrNum and exercising the
  // bank-full -> bypass path. (folded in from the former mshr-capacity-test)
  if (on) {
    const uint32_t w = w8;
    vld_m1(&percore[w], buf, 16);
    CHECK(8, buf, 16, gold_pc_w(w + _i));
  }
  mempool_barrier(num_cores);

  phase_end();
  phase_begin(9);
  // ---- P9: repeated single-word remote load -> response-cache hits ----
  // The same remote word read CACHE_REPS times: after the first fill the entry
  // is MSHR_CACHED and later reads hit it; P8's distinct-line churn drives the
  // matching cache fill/evict. (folded in from the former mshr-capacity-test)
  if (on) {
    const uint32_t w = w9;
    const uint32_t e = gold_pc_w(w);
    for (uint32_t r = 0; r < CACHE_REPS; ++r) {
      uint32_t v; asm volatile("lw %0, 0(%1)" : "=r"(v) : "r"(&percore[w]) : "memory");
      if (v != e) { fail(9, cid, 0, e, v); break; }
    }
  }
  mempool_barrier(num_cores);

  phase_end();   // P9 done -> trace back to 0

  // ---- Verdict ----
  // The pass/fail verdict is reported via the EOC return value (g_fail mask),
  // not printf: the embedded printf is stack-heavy and main's frame plus printf
  // overflows the 512B per-core stack (seq_mem_size). Optionally re-enable a
  // human-readable line with -DVERDICT_PRINTF when running with a larger stack.
#ifdef VERDICT_PRINTF
  if (cid == 0) {
    const uint32_t f = g_fail;
    if (f == 0) {
      printf("sp-mshr-burst-test: PASS (cores=%u)\n", (unsigned)active);
    } else {
      printf("sp-mshr-burst-test: FAIL mask=0x%08x", (unsigned)f);
      for (uint32_t p = 1; p <= 9; ++p) if (f & (1u << p)) printf(" P%u", (unsigned)p);
      printf("\n");
    }
  }
#endif
  mempool_barrier(num_cores);
  // Return the fail mask so the verdict is observable via the EOC return value
  // (retval) even in harnesses where UART printf is not surfaced. 0 => PASS.
  // g_fail is shared and stable after the final barrier, so every core returns
  // the same value and the first-finisher EOC reports it correctly.
  return (int)g_fail;
}

// clang-format on
