// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
// sp-flw-latency-test
// ===================
// A SHORT microbenchmark that reproduces the sp-fmatmul-opt-burst-merge inner
// loop (matmul_8xVL) so we can measure whether that loop is COMPUTE-BOUND (at
// the VFU floor) or LATENCY-EXPOSED (stalling on flw/vle memory latency) on
// terapool — without the long DMA + 256^3 of the full kernel.
//
// Per active core: C[8][32] = sum_{n=0..NN-1} A[8][n] * B[n][32]
//   - exactly matmul_8xVL(c, a, b, 0, 8, NN, 32, 0, 32): 8 accumulators,
//     per n: 1 vle32.v (B row, vector/VLSU) + 8 flw (A col, scalar/FP-LSU) +
//     8 vfmacc.vf, with the peeled-first-iteration interleave.
//   - B is SHARED across all cores (coalescable, like the real kernel's B);
//     A and C are per-core.
//   - All inputs are 1.0, so every C element must equal NN (trivial self-check).
//
// FPU floor (per core): 8 vfmacc * (VL/N_FU = 32/4 = 8) cyc * NN = 64*NN cyc.
//   measured ~= 64*NN  -> compute-bound (flw/vle latency fully hidden)
//   measured >> 64*NN   -> latency-exposed (the interleave is NOT hiding it)

#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"
#include "encoding.h"

#include "kernel/sp-fmatmul.c"

// ---- tunables ----
// ACTIVE_CORES: keep SMALL by default. A single core isolates the per-core
// inner-loop (does the interleave hide L1 latency?) with no contention and no
// cross-group NoC deadlock, and keeps the terapool sim short. Scale up only to
// study contention (256 cores reproduces the documented g12/g15 NoC hang).
#ifndef ACTIVE_CORES
#define ACTIVE_CORES 1
#endif
#ifndef NN
#define NN 16                         // inner length; FPU floor = 64*NN cyc/core
#endif
#define KS 8                          // accumulator rows (matmul_8xVL)
#define VL 32                         // columns per core (LMUL=2, e32)

// L1-resident data. B is shared (coalescable); A,C per active core.
static float g_a[ACTIVE_CORES * KS * NN] __attribute__((section(".l1_prio"), aligned(64)));
static float g_b[NN * VL]               __attribute__((section(".l1_prio"), aligned(64)));
static float g_c[ACTIVE_CORES * KS * VL] __attribute__((section(".l1_prio"), aligned(64)));
static volatile uint32_t g_fail          __attribute__((section(".l1_prio"), aligned(64)));
static volatile float    g_drain         __attribute__((section(".l1_prio"), aligned(64)));
static volatile uint32_t g_nwrong        __attribute__((section(".l1_prio"), aligned(64)));
static volatile uint32_t g_c0bits        __attribute__((section(".l1_prio"), aligned(64)));
static volatile uint32_t g_fwidx         __attribute__((section(".l1_prio"), aligned(64)));
static volatile uint32_t g_fwbits        __attribute__((section(".l1_prio"), aligned(64)));

int main() {
  const uint32_t cid       = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  const uint32_t active    = cid < ACTIVE_CORES;

  mempool_barrier_init(cid);
  if (cid == 0) g_fail = 0;

  // ---- init (parallel, no DMA): all-ones A and B, zero C ----
  if (active) {
    float *a = &g_a[cid * KS * NN];
    float *c = &g_c[cid * KS * VL];
    for (uint32_t i = 0; i < KS * NN; ++i) a[i] = 1.0f;
    for (uint32_t i = 0; i < KS * VL; ++i) c[i] = 0.0f;
  }
  if (cid == 0)
    for (uint32_t i = 0; i < NN * VL; ++i) g_b[i] = 1.0f;

  mempool_barrier(num_cores);

  // ---- timed region: the matmul-style inner loop ----
  uint32_t t0 = mempool_get_timer();
  // Benchmark CSR also gates the per-instruction .dasm trace (very slow). Leave
  // it OFF for the fast cycle measurement; enable with -DENABLE_BENCH to also
  // collect [BP]/[CMS] profiling (much slower sim).
#ifdef ENABLE_BENCH
  if (cid == 0) mempool_start_benchmark();
#endif

  if (active) {
    float *a = &g_a[cid * KS * NN];
    float *c = &g_c[cid * KS * VL];
    matmul_8xVL(c, a, g_b, 0, KS, NN, VL, 0, VL);
  }

  mempool_barrier(num_cores);
#ifdef ENABLE_BENCH
  if (cid == 0) mempool_stop_benchmark();
#endif
  uint32_t t1 = mempool_get_timer();

  // ---- drain delay (after timing) ----
  // Single core has no barrier margin, so the scalar verify below can race the
  // in-flight vse32.v stores. A scalar spin gives the VLSU time to commit them
  // WITHOUT a vle-after-vse (which can stall the VLSU store->load transition).
  if (active) {
    // ~1500 nops: bounded, register-only (fast, no SEQ-stack latency), and not
    // elided/hoisted (volatile asm has a side effect). Gives the VLSU time to
    // commit its vse32.v stores before the scalar verify (single core has no
    // barrier margin). Avoids the vle-after-vse HW stall and the timer-hoist bug.
    for (int k = 0; k < 1500; k++) asm volatile("nop");
    g_drain = 1.0f;  // touch to keep the section live
  }

  // ---- self-check: every C element must equal NN (count + capture first bad) ----
  if (active) {
    float *c = &g_c[cid * KS * VL];
    uint32_t nw = 0, fwi = 0xffffffffu, fwb = 0;
    for (uint32_t i = 0; i < KS * VL; ++i) {
      float d = c[i] - (float)NN;
      if (d < 0) d = -d;
      if (d > 0.5f) {
        if (nw == 0) { fwi = i; fwb = *((uint32_t *)&c[i]); }
        nw++;
      }
    }
    if (nw) g_fail = 1;
    if (cid == 0) {
      g_nwrong = nw;
      g_c0bits = *((uint32_t *)&c[0]);
      g_fwidx  = fwi;
      g_fwbits = fwb;
    }
  }

  mempool_barrier(num_cores);

  // ONE compact printf line: triggers EOC in this TB (a no-printf build never
  // reaches end-of-sim) while keeping the slow UART output minimal.
  if (cid == 0) {
    uint32_t cyc = t1 - t0, fl = 64u * (uint32_t)NN;
    printf("RESULT NN=%u cyc=%u floor=%u x100=%u check=%s nwrong=%u c0=0x%08x\n",
           (unsigned)NN, cyc, fl, (fl ? (cyc * 100u) / fl : 0u),
           g_fail ? "FAIL" : "PASS", g_nwrong, g_c0bits);
  }

  mempool_barrier(num_cores);
  return (int)g_fail;  // 0 = self-check PASS (peel correct), 1 = FAIL
}
