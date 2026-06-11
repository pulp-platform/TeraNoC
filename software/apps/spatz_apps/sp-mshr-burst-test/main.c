// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// MSHR + Spatz-VLSU-burst correctness regression test.
//
// A fast, self-checking baremetal test that exercises the group-MSHR
// (request merge + response multicast, single-word + burst, overflow, AMO /
// response cache) and the Spatz VLSU burst path (full / multi / non-full /
// no-burst shapes). All golden values are timing-independent: data phases
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

int main() {
  const uint32_t cid       = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  uint32_t active          = ACTIVE_CORES;
  if (active == 0 || active > num_cores) active = num_cores;
  const uint32_t on        = (cid < active);

  uint32_t buf[BUF_WORDS];   // per-core local result buffer

  mempool_barrier_init(cid);

  // ---- Init shared/read-only data (distributed across active cores) ----
  if (on) {
    for (uint32_t i = 0; i < PC_WORDS; ++i) percore[cid * PC_WORDS + i] = gold_pc(cid, i);
  }
  if (cid == 0) {
    for (uint32_t k = 0; k < N_SHARED_S; ++k) shared_s[k] = gold_s(k);
    for (uint32_t i = 0; i < N_SHARED_B; ++i) shared_b[i] = gold_b(i);
    amo_cnt = 0; amo_mix = 0; g_fail = 0; g_print = 0;
  }
  mempool_barrier(num_cores);

  // ---- P1: VLSU burst shapes, per-core (isolates burst gen, no merge) ----
  if (on) {
    const uint32_t b = cid * PC_WORDS;
    vld_m1(&percore[b], buf, 16);  CHECK(1, buf, 16, gold_pc(cid, _i));  // full burst
    vld_m2(&percore[b], buf, 32);  CHECK(1, buf, 32, gold_pc(cid, _i));  // 2x16 bursts
    vld_m2(&percore[b], buf, 24);  CHECK(1, buf, 24, gold_pc(cid, _i));  // burst + tail
    vld_m1(&percore[b], buf, 7);   CHECK(1, buf, 7,  gold_pc(cid, _i));  // non-full
    vld_m4(&percore[b], buf, 32);  CHECK(1, buf, 32, gold_pc(cid, _i));  // no-burst (multi-port)
  }
  mempool_barrier(num_cores);

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

  // ---- P3: burst merge (cores in a group read the SAME aligned region) ----
  if (on) {
    vld_m1(&shared_b[0], buf, 16);
    CHECK(3, buf, 16, gold_b(_i));
  }
  mempool_barrier(num_cores);

  // ---- P4: AMO reduction (deterministic: counter == #active) ----
  if (on) (void)amo_add(&amo_cnt, 1);
  mempool_barrier(num_cores);
  if (cid == 0 && amo_cnt != active) fail(4, cid, 0, active, amo_cnt);
  mempool_barrier(num_cores);

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

  // ---- P6: back-to-back bursts (ROB pressure -> force_send corner) ----
  // 4 consecutive LMUL=2 loads (4*32 beat-ids >> ROB=32) to stress the
  // burst_alloc / force_send path. Correctness-checked; a true hang (bug #1)
  // shows as the sim never reaching the verdict line.
  if (on) {
    const uint32_t b = cid * PC_WORDS;
    for (uint32_t r = 0; r < 4; ++r) {
      vld_m2(&percore[b], buf, 32);
      CHECK(6, buf, 32, gold_pc(cid, _i));
    }
  }
  mempool_barrier(num_cores);

  // ---- P7: meta_id wrap across consecutive bursts (3x16 = 48 beat-ids) ----
  if (on) {
    const uint32_t b = cid * PC_WORDS;
    for (uint32_t r = 0; r < 3; ++r) {
      vld_m1(&percore[b + r * 16], buf, 16);
      CHECK(7, buf, 16, gold_pc(cid, r * 16 + _i));
    }
  }
  mempool_barrier(num_cores);

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
      for (uint32_t p = 1; p <= 7; ++p) if (f & (1u << p)) printf(" P%u", (unsigned)p);
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
