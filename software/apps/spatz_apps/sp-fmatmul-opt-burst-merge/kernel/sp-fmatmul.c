// Copyright 2026 ETH Zurich and University of Bologna.
//
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Author: Zexin Fu <zexifu@iis.ee.ethz.ch>
//
// Burst-optimized matrix multiply for TeraNoC + Spatz.
//
// Uses LMUL=2 (VL=32 elements = 128 bytes per vector load).
// The Spatz VLSU automatically splits each aligned 128-byte load into
// 2 × 16-word burst requests on the NoC, giving burst efficiency
// while processing 32 columns per inner-loop iteration.
//
// The inner loop uses the same double-buffered "Load-Next-First" pattern
// as sp-fmatmul-opt, with a shared pointer (a__) that zigzags through
// the A matrix to load A[m+0..7][n] for successive n values.

#include "sp-fmatmul.h"

#define MIN(a, b) ((a) < (b) ? (a) : (b))

// ---- Group barrier (memory-mapped, general-purpose structs) ----------------
// The HW barrier (group LIC output port = NumTilesPerGroup) owns L1 words
// [GBAR_BASE_WORD, +NumBarriers); struct s = word - GBAR_BASE_WORD. Per struct,
// SW writes target+mask ONCE (gbar_setup, persists/auto-reused); then each
// participant does gbar_arrive(struct) (a held load) + gbar_wait (fence). When the
// struct's arrival count hits target, the HW fires the held responses to the
// resp_mask cores, releasing them aligned.  The access MUST target a different tile
// in the same group ((own_tile+1)%16) so it is TCDM_EXTERNAL and reaches the xbar
// barrier port (a same-tile address is TCDM_LOCAL -> served tile-internally). The
// struct is selected by the word (shared across the group); the tile field is only
// routing. bank field = op: 0=arrive(load), 1=set target, 2=set mask.
// Gated by GROUP_BARRIER; must match the RTL EnableGroupBarrier.
#ifndef GROUP_BARRIER
// DEFAULT 0 since the 2026-07-16 ablation (docs/matmul_bottleneck_report.md §7): the per-step
// barrier was measured NET-NEGATIVE on both axes -- kernel 3940 -> 3836 cycles without it, AND
// the merge rate ROSE (10.8% -> 11.6%, bypasses down). The rendezvous cannot fix the downstream
// emission skew (residual VLSU drain + ROB alloc walk diverge the pairs past the ~10-15 cyc
// effective merge window), while its synchronized launches CREATE the MSHR bank-pressure spikes
// that cause bypasses. Set =1 to restore the old per-step alignment for experiments.
#define GROUP_BARRIER 0
#endif
// Ablation knob (bottleneck report Option B3): keep the two PEELED-iteration syncs (cold-start
// pair alignment) but compile out the two STEADY-LOOP syncs -- pairs align once, then drift.
// Default = GROUP_BARRIER (no behavior change).
#ifndef GBAR_STEADY
#define GBAR_STEADY GROUP_BARRIER
#endif
// ---- Per-p-iteration GROUP-WIDE barrier (outer-loop alignment) --------------
// INDEPENDENT of GROUP_BARRIER above (which is the per-STEP, per-PAIR rendezvous that
// measured net-negative: it fires once per n step and cannot fix the downstream emission
// skew). This one fires only at the TOP of each outer p iteration -- (p_end-p_start)/gvl
// times per kernel, i.e. 4x for a 128-column range at m2 (VL=32), 2x at m4 -- and syncs
// ALL cores of the group instead of a pair.
// Rationale: the B-line sharing set is the cores with the same p_start (degree
// cores_per_group/split_m_count, = 4 at M=P=512), and they can only coalesce in the group
// MSHR if they issue inside the merge window. They drift apart over the long n sweep;
// one rendezvous per column block re-locks them at negligible cost. It also subsumes
// COLDSTART_GROUP_SYNC: the first iteration is aligned by the same barrier.
// Uses its OWN struct (>= cores_per_group/2) so it can never collide with the pair
// structs 0..7 that GROUP_BARRIER configures.
#ifndef GBAR_PLOOP
#define GBAR_PLOOP 1
#endif
#define GBAR_PLOOP_STRUCT 8u
#if GROUP_BARRIER || GBAR_PLOOP
// Reserved barrier word base. Derived from the build's GROUP_BARRIER_WORD (runtime.mk) so it
// cannot drift from mempool_group.sv's GroupBarrierWord -- a mismatch either misses the barrier
// port entirely or, worse, points ordinary data at it (response withheld forever = silent hang).
#ifndef GROUP_BARRIER_WORD
#error "GROUP_BARRIER_WORD not defined: build via the app Makefile so runtime.mk supplies it."
#endif
#define GBAR_BASE_WORD ((uint32_t)GROUP_BARRIER_WORD)
static inline uint32_t gbar_tgt_tile(void) {                 // a same-group tile != own
  uint32_t hid; asm volatile("csrr %0, mhartid" : "=r"(hid));
  return (hid & 0xF0u) | (((hid & 0xFu) + 1u) & 0xFu);
}
static inline uint32_t gbar_base(uint32_t s) {               // byte addr: word=base+s, tile, bank0
  return ((GBAR_BASE_WORD + s) << 14) | (gbar_tgt_tile() << 6);
}
static inline void gbar_setup(uint32_t s, uint32_t target, uint32_t mask) {
  uint32_t b = gbar_base(s);
  *(volatile uint32_t *)(b + 4u) = target;                   // bank 1 -> WR_TARGET
  *(volatile uint32_t *)(b + 8u) = mask;                     // bank 2 -> WR_MASK
}
static inline void gbar_arrive(uint32_t a) {                 // a = gbar_base(s); held load
  uint32_t v; asm volatile("lw %0, 0(%1)" : "=r"(v) : "r"(a) : "memory"); (void)v;
}
// Full fence (both): wait for the held barrier lw (integer LSU) AND the Spatz VLSU
// to drain (plain `fence` = both; see hardware/deps/snitch/src/snitch.sv). So the
// pair rendezvouses AND each core's outstanding vector mem ops are drained before
// the next aligned B prefetch issues.
static inline void gbar_wait_both(void) { asm volatile("fence" ::: "memory"); }
static inline void gbar_wait_snitch(void) { asm volatile("fence.i" ::: "memory"); }
// Request-sent fence: sfence.vma is repurposed in snitch.sv to block until all THIS
// core's prior Spatz mem requests -- BOTH vector VLSU and scalar FP-LSU -- are ISSUED to
// the interconnect (NOT drained -- responses stay in flight, so in-flight bursts remain
// coalescable and overlap is kept).
static inline void gbar_wait_req_sent(void) { asm volatile("sfence.vma" ::: "memory"); }
// One-call rendezvous. First ensure THIS core's prior Spatz mem requests (BOTH vector
// VLSU and scalar FP-LSU) are all SENT to the interconnect (NOT drained -- they stay in
// flight, overlap preserved), then arrive (held lw), then wait for the pair to release.
// Both cores meet with their B requests issued, so the next B vle's bursts land in the
// MSHR merge window together.
static inline void gbar_sync(uint32_t a) {
  gbar_wait_req_sent();   // wait until my mem requests (vector + scalar-FP) are issued
  gbar_arrive(a);         // arrive: held load to the barrier struct
  gbar_wait_snitch();     // wait for the held lw to return (the pair has rendezvoused)
}
#endif
// Per-STEP / per-PAIR macros. These stay gated on GROUP_BARRIER ALONE (not the helper
// gate above): their call sites reference the pair address `gbar`, which is only declared
// under GROUP_BARRIER. Making them real whenever the helpers exist would break a
// GBAR_PLOOP=1, GROUP_BARRIER=0 build.
#if GROUP_BARRIER
#define GBAR_SETUP(s,t,m) gbar_setup((s),(t),(m))
#define GBAR_ARRIVE(a)    gbar_arrive(a)
#define GBAR_WAIT()       gbar_wait_both()
#define GBAR_SYNC(a)      gbar_sync(a)
#if GBAR_STEADY
#define GBAR_SYNC_STEADY(a) gbar_sync(a)
#else
#define GBAR_SYNC_STEADY(a) ((void)0)
#endif
#else
#define GBAR_SETUP(s,t,m) ((void)0)
#define GBAR_ARRIVE(a)    ((void)0)
#define GBAR_WAIT()       ((void)0)
#define GBAR_SYNC(a)      ((void)0)
#define GBAR_SYNC_STEADY(a) ((void)0)
#endif
// Per-p-iteration sync. When off, the macro discards its argument at preprocess time, so
// the (also compiled-out) address variable is never referenced.
#if GBAR_PLOOP
#define GBAR_SYNC_PLOOP(a) gbar_sync(a)
#else
#define GBAR_SYNC_PLOOP(a) ((void)0)
#endif

//==========================================================
// 8xVL: Process 8 output rows per iteration, LMUL=2
//
// Register allocation (32 vector regs, LMUL=2 → each "vreg" = 2 physical):
//   v0,v2,v4,v6,v8,v10,v12,v14: 8 accumulators (8 × m2 = 16 regs)
//   v18: B[n]   column vector (m2 = 2 regs)
//   v20: B[n+1] column vector (m2 = 2 regs)
//   Total: 20 out of 32 vector registers
//
// Scalar floats: t0..t7 = A[m+0..7][n] elements
//==========================================================

KERNEL_ATTR
void matmul_8xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
#if GROUP_BARRIER
  // This core's pair-struct = (within-group tile) % 8; arrive address precomputed.
  uint32_t bhid; asm volatile("csrr %0, mhartid" : "=r"(bhid));
  const uint32_t gbar = gbar_base(bhid & 7u);
#endif
#if GBAR_PLOOP
  const uint32_t gbar_pl = gbar_base(GBAR_PLOOP_STRUCT);
#endif
  unsigned int p = p_start;
  while (p < p_end) {
    // Re-align every core of the group at the start of this column block, so the
    // same-p_start B-line sharing set issues its bursts inside the MSHR merge
    // window (see GBAR_PLOOP). Request-sent fence only: responses stay in flight.
    GBAR_SYNC_PLOOP(gbar_pl);
    // LMUL=2: each vector holds up to 32 float32 elements (VLEN=512, m2).
    // The VLSU auto-splits aligned loads > 16 words into 16-word bursts.
    size_t gvl;
    asm volatile("vsetvli %[gvl], %[vl], e32, m2, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(p_end - p));

    const float *b_ = b + p;
    float *c_ = c + p;

    KERNEL_NO_UNROLL
    for (unsigned int m = m_start; m < m_end; m += 8) {
      // a_ = base of row m in A; a__ = shared walking pointer
      const float *a_ = a + m * N;
      const float *a__ = a_;

      // Load B[0] column chunk
      asm volatile("vle32.v v18, (%0);" ::"r"(b_));
      const float *b__ = b_ + P;

      float *c__ = c_ + m * P;

      float t0, t1, t2, t3, t4, t5, t6, t7;

      // Pre-load A[m+0..7][0] — column 0 from 8 consecutive rows
      t0 = *a__;  a__ += N;  // A[m][0]
      t1 = *a__;  a__ += N;  // A[m+1][0]
      t2 = *a__;  a__ += N;  // A[m+2][0]
      t3 = *a__;  a__ += N;  // A[m+3][0]
      t4 = *a__;  a__ += N;  // A[m+4][0]
      t5 = *a__;  a__ += N;  // A[m+5][0]
      t6 = *a__;  a__ += N;  // A[m+6][0]
      t7 = *a__;             // A[m+7][0]

      unsigned int n = 0;

      // ---- Peeled first iteration ----------------------------------------
      // The first inner iteration is the ONLY one that *initializes* the
      // accumulators (vfmul) instead of accumulating (vfmacc). Peeling it out
      // of the loop removes the per-iteration (n == 1) test and keeps the 8
      // vfmul OUT of the hot loop body (smaller, branch-free hot loop).
      //
      // First half: init column 0 with vfmul (v18 = B[0]); prefetch B[1]->v20
      // and load A[..][1] for the second half.
      ++n;  // n = 1
      a__ = a_ + n;
      GBAR_SYNC(gbar);  // arrive + wait: rendezvous the pair; next vle issues aligned
      asm volatile("vle32.v v20, (%0);" ::"r"(b__));
      b__ += P;
      asm volatile("vfmul.vf v0, v18, %0" ::"f"(t0));
      t0 = *a__;  a__ += N;
      asm volatile("vfmul.vf v2, v18, %0" ::"f"(t1));
      t1 = *a__;  a__ += N;
      asm volatile("vfmul.vf v4, v18, %0" ::"f"(t2));
      t2 = *a__;  a__ += N;
      asm volatile("vfmul.vf v6, v18, %0" ::"f"(t3));
      t3 = *a__;  a__ += N;
      asm volatile("vfmul.vf v8, v18, %0" ::"f"(t4));
      t4 = *a__;  a__ += N;
      asm volatile("vfmul.vf v10, v18, %0" ::"f"(t5));
      t5 = *a__;  a__ += N;
      asm volatile("vfmul.vf v12, v18, %0" ::"f"(t6));
      t6 = *a__;  a__ += N;
      asm volatile("vfmul.vf v14, v18, %0" ::"f"(t7));
      t7 = *a__;

      // Second half: accumulate column 1 (v20 = B[1]); prefetch B[2]->v18 and
      // load A[..][2]. Skipped when N == 2 so column 1 falls to the epilogue
      // (exactly as the original loop's mid-iteration break did).
      ++n;  // n = 2
      a__ = a_ + n;
      if (n != N) {
        GBAR_SYNC(gbar);  // arrive + wait: rendezvous the pair; next vle issues aligned
        asm volatile("vle32.v v18, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v2, %0, v20" ::"f"(t1));
        t1 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t2));
        t2 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v6, %0, v20" ::"f"(t3));
        t3 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t4));
        t4 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v10, %0, v20" ::"f"(t5));
        t5 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t6));
        t6 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v14, %0, v20" ::"f"(t7));
        t7 = *a__;
      }

      // ---- Steady state: vfmacc only, no (n == 1) test --------------------
      KERNEL_NO_UNROLL
      while (n < N) {
        // First half: accumulate with v18 (B[even]); prefetch B[odd] -> v20.
        ++n;
        a__ = a_ + n;
        GBAR_SYNC_STEADY(gbar);  // per-step rendezvous (compiled out when GBAR_STEADY=0)
        asm volatile("vle32.v v20, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v18" ::"f"(t0));
        t0 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v2, %0, v18" ::"f"(t1));
        t1 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v4, %0, v18" ::"f"(t2));
        t2 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v6, %0, v18" ::"f"(t3));
        t3 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v8, %0, v18" ::"f"(t4));
        t4 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v10, %0, v18" ::"f"(t5));
        t5 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v12, %0, v18" ::"f"(t6));
        t6 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v14, %0, v18" ::"f"(t7));
        t7 = *a__;

        // Second half: accumulate with v20 (B[odd]); prefetch B[even] -> v18.
        ++n;
        a__ = a_ + n;
        if (n == N)
          break;
        GBAR_SYNC_STEADY(gbar);  // per-step rendezvous (compiled out when GBAR_STEADY=0)
        asm volatile("vle32.v v18, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v2, %0, v20" ::"f"(t1));
        t1 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t2));
        t2 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v6, %0, v20" ::"f"(t3));
        t3 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t4));
        t4 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v10, %0, v20" ::"f"(t5));
        t5 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t6));
        t6 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v14, %0, v20" ::"f"(t7));
        t7 = *a__;
      }

      // Final accumulate + store
      asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
      asm volatile("vse32.v v0, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v2, %0, v20" ::"f"(t1));
      asm volatile("vse32.v v2, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t2));
      asm volatile("vse32.v v4, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v6, %0, v20" ::"f"(t3));
      asm volatile("vse32.v v6, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t4));
      asm volatile("vse32.v v8, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v10, %0, v20" ::"f"(t5));
      asm volatile("vse32.v v10, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t6));
      asm volatile("vse32.v v12, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v14, %0, v20" ::"f"(t7));
      asm volatile("vse32.v v14, (%0);" ::"r"(c__));
    }

    p += gvl;
  }
}

//==========================================================
// 4xVL: Process 4 output rows per iteration, LMUL=2
//==========================================================
KERNEL_ATTR
void matmul_4xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
#if GBAR_PLOOP
  const uint32_t gbar_pl = gbar_base(GBAR_PLOOP_STRUCT);
#endif

  unsigned int p = p_start;
  while (p < p_end) {
    // Group-wide re-alignment at each column block (see GBAR_PLOOP).
    GBAR_SYNC_PLOOP(gbar_pl);
    size_t gvl;
    asm volatile("vsetvli %[gvl], %[vl], e32, m4, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(p_end - p));

    const float *b_ = b + p;
    float *c_ = c + p;

    KERNEL_NO_UNROLL
    for (unsigned int m = m_start; m < m_end; m += 4) {
      const float *a_ = a + m * N;
      const float *a__ = a_;

      asm volatile("vle32.v v16, (%0);" ::"r"(b_));
      const float *b__ = b_ + P;

      float *c__ = c_ + m * P;

      float t0, t1, t2, t3;

      t0 = *a__;  a__ += N;
      t1 = *a__;  a__ += N;
      t2 = *a__;  a__ += N;
      t3 = *a__;

      unsigned int n = 0;

      // ---- Peeled first iteration (init col 0 with vfmul; removes the per-
      //      iteration (n == 1) test and keeps the vfmul out of the hot loop) ----
      asm volatile("vle32.v v20, (%0);" ::"r"(b__));
      b__ += P;
      ++n;  // n = 1
      a__ = a_ + n;
      asm volatile("vfmul.vf v0, v16, %0" ::"f"(t0));
      t0 = *a__;  a__ += N;
      asm volatile("vfmul.vf v4, v16, %0" ::"f"(t1));
      t1 = *a__;  a__ += N;
      asm volatile("vfmul.vf v8, v16, %0" ::"f"(t2));
      t2 = *a__;  a__ += N;
      asm volatile("vfmul.vf v12, v16, %0" ::"f"(t3));
      t3 = *a__;

      ++n;  // n = 2
      a__ = a_ + n;
      if (n != N) {
        asm volatile("vle32.v v16, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t1));
        t1 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t2));
        t2 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t3));
        t3 = *a__;
      }

      // ---- Steady state: vfmacc only, no (n == 1) test ----
      KERNEL_NO_UNROLL
      while (n < N) {
        asm volatile("vle32.v v20, (%0);" ::"r"(b__));
        b__ += P;
        ++n;
        a__ = a_ + n;
        asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
        t0 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v4, %0, v16" ::"f"(t1));
        t1 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t2));
        t2 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v12, %0, v16" ::"f"(t3));
        t3 = *a__;

        ++n;
        a__ = a_ + n;

        if (n == N)
          break;

        asm volatile("vle32.v v16, (%0);" ::"r"(b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t1));
        t1 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t2));
        t2 = *a__;  a__ += N;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t3));
        t3 = *a__;
      }

      asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
      asm volatile("vse32.v v0, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t1));
      asm volatile("vse32.v v4, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t2));
      asm volatile("vse32.v v8, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t3));
      asm volatile("vse32.v v12, (%0);" ::"r"(c__));
    }

    p += gvl;
  }
}

//==========================================================
// 2xVL: Process 2 output rows per iteration, LMUL=2
//==========================================================
KERNEL_ATTR
void matmul_2xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
#if GBAR_PLOOP
  const uint32_t gbar_pl = gbar_base(GBAR_PLOOP_STRUCT);
#endif

  unsigned int p = p_start;
  while (p < p_end) {
    // Group-wide re-alignment at each column block (see GBAR_PLOOP).
    GBAR_SYNC_PLOOP(gbar_pl);
    size_t gvl;
    asm volatile("vsetvli %[gvl], %[vl], e32, m8, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(p_end - p));

    const float *b_ = b + p;
    float *c_ = c + p;

    KERNEL_NO_UNROLL
    for (unsigned int m = m_start; m < m_end; m += 2) {
      const float *a_ = a + m * N;
      const float *a__ = a_;

      asm volatile("vle32.v v16, (%0);" ::"r"(b_));
      const float *b__ = b_ + P;

      float *c__ = c_ + m * P;

      float t0, t1;

      t0 = *a__;
      a__ += N;
      t1 = *a__;

      unsigned int n = 0;

      // ---- Peeled first iteration (init col 0 with vfmul; removes the per-
      //      iteration (n == 1) test and keeps the vfmul out of the hot loop) ----
      ++n;  // n = 1
      a__ = a_ + n;
      asm volatile("vle32.v v24, (%0);" ::"r"(b__));
      b__ += P;
      asm volatile("vfmul.vf v0, v16, %0" ::"f"(t0));
      t0 = *a__;
      a__ += N;
      asm volatile("vfmul.vf v8, v16, %0" ::"f"(t1));
      t1 = *a__;

      ++n;  // n = 2
      a__ = a_ + n;
      if (n != N) {
        asm volatile("vle32.v v16, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
        t0 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
        t1 = *a__;
      }

      // ---- Steady state: vfmacc only, no (n == 1) test ----
      KERNEL_NO_UNROLL
      while (n < N) {
        ++n;
        a__ = a_ + n;

        asm volatile("vle32.v v24, (%0);" ::"r"(b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
        t0 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
        t1 = *a__;

        ++n;
        a__ = a_ + n;

        if (n == N)
          break;

        asm volatile("vle32.v v16, (%0);" ::"r"(b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
        t0 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
        t1 = *a__;
      }

      asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
      asm volatile("vse32.v v0, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
      asm volatile("vse32.v v8, (%0);" ::"r"(c__));
    }

    p += gvl;
  }
}

//==========================================================
// Top-level entry point
//==========================================================
void matmul(float *c, const float *a, const float *b, const unsigned int M,
            const unsigned int N, const unsigned int P) {
  if (M <= 4) {
    matmul_2xVL(c, a, b, 0, M, N, P, 0, P);
  } else if (M <= 8) {
    matmul_4xVL(c, a, b, 0, M, N, P, 0, P);
  } else {
    matmul_8xVL(c, a, b, 0, M, N, P, 0, P);
  }
}
