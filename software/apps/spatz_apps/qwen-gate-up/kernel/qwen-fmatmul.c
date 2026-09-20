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
// Burst-optimized matrix multiply for TeraNoC + Spatz, K-TILE STREAMING FORK.
//
// Forked from sp-fmatmul-opt-burst-merge-fp16/kernel/sp-fmatmul.c. That app is a
// calibration anchor with exact cycle references, so it is left untouched and this
// copy carries the three changes a streamed projection needs:
//
//   1. `lda` -- A's ROW STRIDE, previously hardwired to N. A K tile hands the kernel
//      a column slice a[.. , k0 .. k0+N) of a wider [M][K] matrix, so the reduction
//      length (N) and the row stride (lda) are no longer the same number.
//   2. `accum` -- when set, the accumulators are LOADED from C instead of zeroed, so
//      tile t adds into what tiles 0..t-1 left there. The original peeled first
//      iteration initialised with vfmul; that special case is gone, replaced by an
//      explicit accumulator init (vmv.v.i 0, or vle16 from C) plus a uniform vfmacc.
//   3. A burst-safe vector length -- see qwen_burst_vl() below.
//   4. The group rendezvous moved from "every column block" to "once per call".
//      It has to: change 3 makes the number of column blocks depend on a core's
//      start offset, so the cores of a group would arrive at that barrier a
//      different number of times and it would stop releasing. Once per call is one
//      rendezvous per streamed K tile, which is the alignment point that matters.
//
// Everything else -- the unroll-by-2 B ping-pong, the register allocation, the
// LMUL-per-KS choice, the 1xVL ROB-capacity splits -- is unchanged.

#include "qwen-fmatmul.h"

#define MIN(a, b) ((a) < (b) ? (a) : (b))

// ---- Burst-safe vector length ----------------------------------------------
// docs/qwen3_8_27b/tile_contained_burst_hash.md: a unit-stride vector load takes the
// VLSU burst path only if it either stays INSIDE one 64-byte tile bank stripe (any
// 4-byte-aligned start will do) or starts 16-byte aligned (NrMemPorts * MemDataWidthB)
// so that every internal split ends on a complete ROB lane row. A load that crosses a
// stripe from a badly aligned start does not merely lose one segment -- the WHOLE load
// falls back to single-word requests.
//
// That is not hypothetical here. A full-width Qwen projection gives each core
// P / n_p_blocks = 17408 / 256 = 68 columns, so core k starts at element 68*k, i.e.
// byte 136*k -- 8-byte aligned, never 16. Every B load of every core but the first
// would take the word path.
//
// Fix, costing no padding and no extra bytes: cap the FIRST vector of a p-loop at the
// next stripe boundary. That one load is stripe-CONTAINED (legal at 8-byte alignment,
// 56 B = a 14-word burst in the 68-column case); from there on p is 64-byte aligned and
// every following load may cross freely. 68 columns become 28 + 40 elements, both
// burst-eligible, instead of one 136-byte load that bursts not at all.
//
// This assumes the row stride is itself a whole number of stripes so that every row
// starts aligned -- main.c pads the stored row stride (QWEN_LDP) to guarantee it. When
// p_start is already stripe-aligned the expression returns p_end - p, i.e. exactly what
// the parent kernel computes, which is why the fp32/fp16 GEMM shapes are unaffected.
// THE CAP IS UNCONDITIONAL, and that is load-bearing. Capping only when p is
// misaligned (the obvious reading of the rule) makes the number of vector loads
// depend on a core's start offset: with 68 columns, a stripe-ALIGNED core emits one
// 68-element load and every other core emits two (28+40). At 256 column blocks that
// is exactly 2 cores per group of 16 doing less work per column block, and those two
// run ahead.
//
// That breaks the MSHR cohort, and it is expensive. The 16 cores of a group read the
// same X word, so the group MSHR holds the entry until hold_subs_single of them have
// subscribed. Measured on B=1 K=64 P=17408: mean entry lifetime was 3,834 cycles in
// HOLD against 10 cycles in flight, entries reached mean_served=30.1 against a target
// of 32 -- short by exactly the two runaway cores -- and half of them aged out on
// serve_timeout. Lowering hold_subs_single to 8, i.e. below the in-phase cohort, cut
// the hold to 18 cycles and the runtime by 2.4x, which is the same symptom seen from
// the other side.
//
// Capping always costs one extra vector load on the aligned cores and makes every
// core emit the same sequence, so the cohort assembles. Both loads stay
// burst-eligible: the first is a stripe-contained 64 B (one 16-word burst), the
// second starts 64 B-aligned and may cross freely.
#define QWEN_STRIPE_ELEMS ((unsigned int)(GEMM_BURST_TILE_WORDS * 4 / sizeof(elem_t)))
#if QWEN_SPAN_ALIGN >= 8
// Every span starts 16-byte aligned, so a load may cross stripe boundaries and is
// still burst-eligible: the VLSU splits it into 16-word requests. Take the whole
// vector rather than stopping at one stripe -- eight bursts instead of one.
//
// The cap is a CONSTANT, so every core emits the same number of vectors whatever
// its start offset. GBAR_PLOOP needs that uniform arrival count.
// What the hardware and the burst rule allow, whichever is smaller:
//   - the vector itself: VLEN * LMUL bits, and GEMM_LMUL is m8 at KERNEL_SIZE 1
//   - the burst path: gemm_burst.h rejects a load beyond ROB_DEPTH * LANES words
// At KERNEL_SIZE 1 both are 256 elements, i.e. 512 B, i.e. eight 16-word bursts.
#define QWEN_VL_HW ((VLEN) * GEMM_LMUL(KERNEL_SIZE) / (8u * GEMM_ELEM_BYTES))
#define QWEN_VL_BURST \
  ((GEMM_BURST_ROB_DEPTH) * (GEMM_BURST_LANES) * 4u / GEMM_ELEM_BYTES)
#define QWEN_VL_MAX \
  ((QWEN_VL_HW) < (QWEN_VL_BURST) ? (unsigned int)(QWEN_VL_HW) \
                                  : (unsigned int)(QWEN_VL_BURST))
static inline unsigned int qwen_burst_vl(unsigned int p, unsigned int p_end) {
  const unsigned int left = p_end - p;
  (void)p;
  return (left > QWEN_VL_MAX) ? QWEN_VL_MAX : left;
}
#else
// 8-byte spans: a load that crossed a stripe would not be 16-byte aligned and the
// whole thing would fall back to the single-word path, so stay inside the stripe.
// Capping UNCONDITIONALLY keeps the vector count uniform across cores.
static inline unsigned int qwen_burst_vl(unsigned int p, unsigned int p_end) {
  const unsigned int left = p_end - p;
  const unsigned int to_stripe_end = QWEN_STRIPE_ELEMS - (p % QWEN_STRIPE_ELEMS);
  return (left > to_stripe_end) ? to_stripe_end : left;
}
#endif

// ---- Group barrier (memory-mapped, general-purpose structs) ----------------
// The HW barrier uses the separate group-control aperture; SRAM is unaffected.
// Struct s is encoded by word = GBAR_BASE_WORD + s. Per struct,
// SW writes target+mask ONCE (gbar_setup, persists/auto-reused); then each
// participant does gbar_arrive(struct) (a held load) + gbar_wait (fence). When the
// struct's arrival count hits target, the HW fires the held responses to the
// resp_mask cores, releasing them aligned. Control accesses always take the
// group path, including own-tile targets. The word field selects the struct;
// bank field selects the op: 0=arrive(load), 1=set target, 2=set mask.
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
// Rationale: the B-line sharing set is the cores with the same p_start. p_start is indexed
// by (core_gid % split_p_count), so the set SIZE is cores_per_group/split_p_count, which is
// split_m_count = M/(active_groups*kernel_size) -- NOT cores_per_group/split_m_count, which
// is split_p_count (the COUNT of distinct p_start values). The two coincide at M=P=512 (both
// 4), which is why the distinction never mattered before; they diverge as soon as the group
// count scales. At 64 groups with M=512, dim_group==kernel_size so split_m_count==1: every
// core in the group takes a distinct p_start and NOTHING coalesces. Preserving degree d at
// G groups requires M = G*kernel_size*d. They can only coalesce in the group
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
// Index encoding within the separate group-control aperture.
#ifndef GROUP_BARRIER_WORD
#error "Build via the app Makefile to supply GROUP_BARRIER_WORD."
#endif
#define GBAR_BASE_WORD ((uint32_t)GROUP_BARRIER_WORD)
// Derive field strides so both 4x4 and 8x8 use the RTL address layout.
#define GBAR_BANKS_PER_TILE (N_FU * BANKING_FACTOR * NUM_CORES_PER_TILE)
#define GBAR_TILE_STRIDE    (4u * (uint32_t)GBAR_BANKS_PER_TILE)
#define GBAR_GROUP_STRIDE   (GBAR_TILE_STRIDE * (uint32_t)NUM_TILES_PER_GROUP)
#define GBAR_WORD_STRIDE    (GBAR_GROUP_STRIDE * (uint32_t)NUM_GROUPS)
static inline uint32_t gbar_base(uint32_t s) {               // byte addr: word=base+s, tile, bank0
  uint32_t hid; asm volatile("csrr %0, mhartid" : "=r"(hid));
  // hartid packs group above tile; recover both instead of masking a fixed bit width, so
  // the group survives at any NumGroups (the old `hid & 0xF0u` dropped group[5:4] at 64).
  uint32_t tile = hid % (uint32_t)NUM_TILES_PER_GROUP;
  uint32_t grp  = hid / (uint32_t)NUM_TILES_PER_GROUP;
  // Control accesses always take the group path; retain the existing tile encoding.
  uint32_t tgt  = (tile + 1u) % (uint32_t)NUM_TILES_PER_GROUP;
  return GROUP_CONTROL_BASE + (GBAR_BASE_WORD + s) * GBAR_WORD_STRIDE
       + grp * GBAR_GROUP_STRIDE
       + tgt * GBAR_TILE_STRIDE;
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
// Full-DRAIN rendezvous. gbar_sync above only guarantees a core's requests were
// ISSUED, which is right when the point is to launch a cohort together. It is NOT
// enough to change MSHR configuration: requests that are issued but not yet answered
// still own resident entries, so a CFG_ENABLE flip would land while the MSHR is
// occupied and those entries would drain under the old setting. `fence` waits for
// this core's Spatz VLSU and integer-LSU RESPONSES, so once the group releases every
// core's memory transactions have completed and the group MSHR is empty.
static inline void gbar_sync_drain(uint32_t a) {
  gbar_wait_both();       // fence: drain my vector + scalar memory ops (responses, not issue)
  gbar_arrive(a);         // arrive: held load to the barrier struct
  gbar_wait_snitch();     // wait for the held lw to return (the group has rendezvoused)
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

// ---- MSHR bypass around the C-accumulator reload ---------------------------
// 0 = off (the reload allocates MSHR entries, as before). 1 = disable the group
// MSHR for the reload window only. Needs GBAR_PLOOP for the rendezvous and
// MSHR_RUNTIME_CFG for the CSR.
// Default: on exactly where it pays. The reload only hurts when the burst class is
// actually merging, i.e. GEMM_SHARE_B >= 2; at share 1 the hold window is already
// zeroed, entries retire immediately and the rendezvous would be pure cost (~10%).
#ifndef QWEN_CBYPASS
#define QWEN_CBYPASS (GEMM_SHARE_B(KERNEL_SIZE) >= 2)
#endif
// Barriers only, no CSR: separates "the rendezvous re-aligned the cores" from
// "the MSHR stopped seeing unmergeable entries".
#ifndef QWEN_CBYPASS_BARRIER_ONLY
#define QWEN_CBYPASS_BARRIER_ONLY 0
#endif
#if (QWEN_CBYPASS || QWEN_CBYPASS_BARRIER_ONLY) && GBAR_PLOOP && MSHR_RUNTIME_CFG
static inline void qwen_mshr_enable(uint32_t on) {
#if QWEN_CBYPASS
  if (mshr_cfg_is_group_writer())
    mshr_cfg_write(mshr_cfg_my_group(), mshr_cfg_peer_tile(), MSHR_CSR_ENABLE, on);
#else
  (void)on;
#endif
}
// Rendezvous count per toggle. 4 (default) is the tight form: one barrier so every
// core's prior requests are issued before the flip, a second so the new setting is
// visible before anyone issues into it. 2 drops the visibility barrier and flips
// straight after the release -- a core can then race ahead of the CSR by a few
// cycles. Ordered barrier-then-flip on BOTH edges deliberately: the leak is then at
// most the block's first W load taking the bypass, instead of up to eight C loads
// allocating.
#ifndef QWEN_CBYPASS_BARRIERS
#define QWEN_CBYPASS_BARRIERS 4
#endif
// The FIRST barrier of each edge drains: the MSHR must be empty before CFG_ENABLE
// moves, or entries allocated under the old setting are still resident across the
// flip. The SECOND only has to publish the new setting, so issue-order is enough.
// QWEN_CBYPASS_DRAIN=0 reverts both to the issue-only barrier for A/B.
#ifndef QWEN_CBYPASS_DRAIN
#define QWEN_CBYPASS_DRAIN 1
#endif
#if QWEN_CBYPASS_DRAIN
#define QWEN_CBYPASS_FENCE(a) gbar_sync_drain(a)
#else
#define QWEN_CBYPASS_FENCE(a) gbar_sync(a)
#endif
#if QWEN_CBYPASS_BARRIERS >= 4
#define QWEN_CBYPASS_ENTER(a) do { QWEN_CBYPASS_FENCE(a); qwen_mshr_enable(0u); gbar_sync(a); } while (0)
#define QWEN_CBYPASS_EXIT(a)  do { QWEN_CBYPASS_FENCE(a); qwen_mshr_enable(1u); gbar_sync(a); } while (0)
#else
#define QWEN_CBYPASS_ENTER(a) do { QWEN_CBYPASS_FENCE(a); qwen_mshr_enable(0u); } while (0)
#define QWEN_CBYPASS_EXIT(a)  do { QWEN_CBYPASS_FENCE(a); qwen_mshr_enable(1u); } while (0)
#endif
#else
#define QWEN_CBYPASS_ENTER(a) ((void)0)
#define QWEN_CBYPASS_EXIT(a)  ((void)0)
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
// Scalar fp16: t0..t7 = A[m+0..7][n] elements (scalar flh -> vfmacc.vf broadcast)
//==========================================================

KERNEL_ATTR
void matmul_8xVL(elem_t *c, const elem_t *a, const elem_t *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end,
                 const unsigned int lda, const unsigned int accum) {
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
    // ---- Per-column-block group rendezvous ----------------------------------
    // Re-align every core of the group at the start of this column block, so the
    // cores that share a B/W line issue their loads inside the MSHR's merge window.
    // This is the parent kernel's GBAR_PLOOP, restored.
    //
    // It needs a UNIFORM arrival count, which is why qwen_burst_vl caps at the
    // stripe boundary unconditionally: a cap applied only when misaligned makes the
    // number of column blocks depend on a core's start offset, the cores of a group
    // arrive here a different number of times, and the barrier stops releasing.
    //
    // Why it matters, measured: from B=2 the burst class stops bypassing and the
    // cores sharing a W line must form a cohort. At B=4 a core walks 9 column blocks
    // x 32 reduction steps per kernel call; with only one rendezvous per call they
    // drift apart, the cohort never assembles, entries sit out the 8191-cycle hold
    // and the banks fill (bank_full fired 93M times at B=4).
    GBAR_SYNC_PLOOP(gbar_pl);
    // LMUL=2: each vector holds up to 64 float16 elements (VLEN=512, m2).
    // LMUL IS DELIBERATELY UNCHANGED from the fp32 kernel: e16,m2 is 64 elements =
    // 128 BYTES, exactly the same byte count as e32,m2, so the VLSU still emits two
    // 16-word bursts per load and the group MSHR sees an identical burst stream.
    // Twice the arithmetic per byte fetched; the memory side is byte-for-byte the same.
    // The VLSU auto-splits aligned loads > 16 words into 16-word bursts.
    size_t gvl;
    asm volatile("vsetvli %[gvl], %[vl], e16, m2, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(qwen_burst_vl(p, p_end)));

    const elem_t *b_ = b + p;
    elem_t *c_ = c + p;

    KERNEL_NO_UNROLL
    for (unsigned int m = m_start; m < m_end; m += 8) {
      // a_ = base of row m in A; a__ = shared walking pointer
      const elem_t *a_ = a + m * lda;
      const elem_t *a__ = a_;

      // Load B[0] column chunk
      asm volatile("vle16.v v18, (%0);" ::"r"(b_));
      const elem_t *b__ = b_ + P;

      elem_t *c__ = c_ + m * P;

      elem_t t0, t1, t2, t3, t4, t5, t6, t7;

      // Pre-load A[m+0..7][0] — column 0 from 8 consecutive rows
      t0 = *a__;  a__ += lda;  // A[m][0]
      t1 = *a__;  a__ += lda;  // A[m+1][0]
      t2 = *a__;  a__ += lda;  // A[m+2][0]
      t3 = *a__;  a__ += lda;  // A[m+3][0]
      t4 = *a__;  a__ += lda;  // A[m+4][0]
      t5 = *a__;  a__ += lda;  // A[m+5][0]
      t6 = *a__;  a__ += lda;  // A[m+6][0]
      t7 = *a__;             // A[m+7][0]

      // ---- Accumulator init ------------------------------------------------
      // accum == 0: this is the first K tile, start the sums at zero.
      // accum != 0: continue the partial sums an earlier tile left in C.
      // The load mirrors the epilogue's store sequence exactly -- same registers,
      // same c__ walk -- so the two can never drift apart.
      // ---- C reload window ---------------------------------------------
      // These eight loads are per-core PRIVATE (c__ = c_ + m_start*P), so no two
      // cores of the group ever share one. Under a live MSHR they allocate
      // unmergeable entries that hold bank ways and evict the W cohort -- the
      // merge rate collapses from ~88% to ~52% the moment accum goes high.
      // Bracket them with CFG_ENABLE=0, which gates merge/alloc only (resident
      // entries keep draining), so they bypass the MSHR entirely. Each toggle
      // needs its own rendezvous: gbar_sync guarantees a core's prior requests
      // are ISSUED, so after the release the writer may flip the CSR, and after
      // the next release every core sees the new setting.
      if (accum) {
        QWEN_CBYPASS_ENTER(gbar_pl);
        elem_t *c_ld = c__;
        asm volatile("vle16.v v0, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v2, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v4, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v6, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v8, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v10, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v12, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v14, (%0);" ::"r"(c_ld));
        (void)c_ld;
        QWEN_CBYPASS_EXIT(gbar_pl);
      } else {
        asm volatile("vmv.v.i v0, 0");
        asm volatile("vmv.v.i v2, 0");
        asm volatile("vmv.v.i v4, 0");
        asm volatile("vmv.v.i v6, 0");
        asm volatile("vmv.v.i v8, 0");
        asm volatile("vmv.v.i v10, 0");
        asm volatile("vmv.v.i v12, 0");
        asm volatile("vmv.v.i v14, 0");
      }

      unsigned int n = 0;

      // ---- Peeled first iteration ----------------------------------------
      // The accumulators were already initialised above, so this peel exists only
      // to prime the B ping-pong and to keep the per-iteration (n == 1) test out
      // of the hot loop body.
      //
      // First half: accumulate column 0 (v18 = B[0]); prefetch B[1]->v20 and load
      // A[..][1] for the second half.
      ++n;  // n = 1
      a__ = a_ + n;
      GBAR_SYNC(gbar);  // arrive + wait: rendezvous the pair; next vle issues aligned
      asm volatile("vle16.v v20, (%0);" ::"r"(b__));
      b__ += P;
      asm volatile("vfmacc.vf v0, %0, v18" ::"f"(t0));
      t0 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v2, %0, v18" ::"f"(t1));
      t1 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v4, %0, v18" ::"f"(t2));
      t2 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v6, %0, v18" ::"f"(t3));
      t3 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v8, %0, v18" ::"f"(t4));
      t4 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v10, %0, v18" ::"f"(t5));
      t5 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v12, %0, v18" ::"f"(t6));
      t6 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v14, %0, v18" ::"f"(t7));
      t7 = *a__;

      // Second half: accumulate column 1 (v20 = B[1]); prefetch B[2]->v18 and
      // load A[..][2]. Skipped when N == 2 so column 1 falls to the epilogue
      // (exactly as the original loop's mid-iteration break did).
      ++n;  // n = 2
      a__ = a_ + n;
      if (n != N) {
        GBAR_SYNC(gbar);  // arrive + wait: rendezvous the pair; next vle issues aligned
        asm volatile("vle16.v v18, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v2, %0, v20" ::"f"(t1));
        t1 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t2));
        t2 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v6, %0, v20" ::"f"(t3));
        t3 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t4));
        t4 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v10, %0, v20" ::"f"(t5));
        t5 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t6));
        t6 = *a__;  a__ += lda;
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
        asm volatile("vle16.v v20, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v18" ::"f"(t0));
        t0 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v2, %0, v18" ::"f"(t1));
        t1 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v4, %0, v18" ::"f"(t2));
        t2 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v6, %0, v18" ::"f"(t3));
        t3 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v8, %0, v18" ::"f"(t4));
        t4 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v10, %0, v18" ::"f"(t5));
        t5 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v12, %0, v18" ::"f"(t6));
        t6 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v14, %0, v18" ::"f"(t7));
        t7 = *a__;

        // Second half: accumulate with v20 (B[odd]); prefetch B[even] -> v18.
        ++n;
        a__ = a_ + n;
        if (n == N)
          break;
        GBAR_SYNC_STEADY(gbar);  // per-step rendezvous (compiled out when GBAR_STEADY=0)
        asm volatile("vle16.v v18, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v2, %0, v20" ::"f"(t1));
        t1 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t2));
        t2 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v6, %0, v20" ::"f"(t3));
        t3 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t4));
        t4 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v10, %0, v20" ::"f"(t5));
        t5 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t6));
        t6 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v14, %0, v20" ::"f"(t7));
        t7 = *a__;
      }

      // Final accumulate + store
      asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
      asm volatile("vse16.v v0, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v2, %0, v20" ::"f"(t1));
      asm volatile("vse16.v v2, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t2));
      asm volatile("vse16.v v4, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v6, %0, v20" ::"f"(t3));
      asm volatile("vse16.v v6, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t4));
      asm volatile("vse16.v v8, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v10, %0, v20" ::"f"(t5));
      asm volatile("vse16.v v10, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t6));
      asm volatile("vse16.v v12, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v14, %0, v20" ::"f"(t7));
      asm volatile("vse16.v v14, (%0);" ::"r"(c__));
    }

    p += gvl;
  }
}

//==========================================================
// 4xVL: Process 4 output rows per iteration, LMUL=2
//==========================================================
KERNEL_ATTR
void matmul_4xVL(elem_t *c, const elem_t *a, const elem_t *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end,
                 const unsigned int lda, const unsigned int accum) {
#if GBAR_PLOOP
  const uint32_t gbar_pl = gbar_base(GBAR_PLOOP_STRUCT);
#endif

  unsigned int p = p_start;
  while (p < p_end) {
    // ---- Per-column-block group rendezvous ----------------------------------
    // Re-align every core of the group at the start of this column block, so the
    // cores that share a B/W line issue their loads inside the MSHR's merge window.
    // This is the parent kernel's GBAR_PLOOP, restored.
    //
    // It needs a UNIFORM arrival count, which is why qwen_burst_vl caps at the
    // stripe boundary unconditionally: a cap applied only when misaligned makes the
    // number of column blocks depend on a core's start offset, the cores of a group
    // arrive here a different number of times, and the barrier stops releasing.
    //
    // Why it matters, measured: from B=2 the burst class stops bypassing and the
    // cores sharing a W line must form a cohort. At B=4 a core walks 9 column blocks
    // x 32 reduction steps per kernel call; with only one rendezvous per call they
    // drift apart, the cohort never assembles, entries sit out the 8191-cycle hold
    // and the banks fill (bank_full fired 93M times at B=4).
    GBAR_SYNC_PLOOP(gbar_pl);
    size_t gvl;
    asm volatile("vsetvli %[gvl], %[vl], e16, m4, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(qwen_burst_vl(p, p_end)));

    const elem_t *b_ = b + p;
    elem_t *c_ = c + p;

    KERNEL_NO_UNROLL
    for (unsigned int m = m_start; m < m_end; m += 4) {
      const elem_t *a_ = a + m * lda;
      const elem_t *a__ = a_;

      asm volatile("vle16.v v16, (%0);" ::"r"(b_));
      const elem_t *b__ = b_ + P;

      elem_t *c__ = c_ + m * P;

      elem_t t0, t1, t2, t3;

      t0 = *a__;  a__ += lda;
      t1 = *a__;  a__ += lda;
      t2 = *a__;  a__ += lda;
      t3 = *a__;

      // ---- Accumulator init ------------------------------------------------
      // accum == 0: this is the first K tile, start the sums at zero.
      // accum != 0: continue the partial sums an earlier tile left in C.
      // The load mirrors the epilogue's store sequence exactly -- same registers,
      // same c__ walk -- so the two can never drift apart.
      // ---- C reload window ---------------------------------------------
      // These eight loads are per-core PRIVATE (c__ = c_ + m_start*P), so no two
      // cores of the group ever share one. Under a live MSHR they allocate
      // unmergeable entries that hold bank ways and evict the W cohort -- the
      // merge rate collapses from ~88% to ~52% the moment accum goes high.
      // Bracket them with CFG_ENABLE=0, which gates merge/alloc only (resident
      // entries keep draining), so they bypass the MSHR entirely. Each toggle
      // needs its own rendezvous: gbar_sync guarantees a core's prior requests
      // are ISSUED, so after the release the writer may flip the CSR, and after
      // the next release every core sees the new setting.
      if (accum) {
        QWEN_CBYPASS_ENTER(gbar_pl);
        elem_t *c_ld = c__;
        asm volatile("vle16.v v0, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v4, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v8, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v12, (%0);" ::"r"(c_ld));
        (void)c_ld;
        QWEN_CBYPASS_EXIT(gbar_pl);
      } else {
        asm volatile("vmv.v.i v0, 0");
        asm volatile("vmv.v.i v4, 0");
        asm volatile("vmv.v.i v8, 0");
        asm volatile("vmv.v.i v12, 0");
      }

      unsigned int n = 0;

      // ---- Peeled first iteration (primes the B ping-pong and keeps the
      //      per-iteration (n == 1) test out of the hot loop) ----
      asm volatile("vle16.v v20, (%0);" ::"r"(b__));
      b__ += P;
      ++n;  // n = 1
      a__ = a_ + n;
      asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
      t0 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v4, %0, v16" ::"f"(t1));
      t1 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t2));
      t2 = *a__;  a__ += lda;
      asm volatile("vfmacc.vf v12, %0, v16" ::"f"(t3));
      t3 = *a__;

      ++n;  // n = 2
      a__ = a_ + n;
      if (n != N) {
        asm volatile("vle16.v v16, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t1));
        t1 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t2));
        t2 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t3));
        t3 = *a__;
      }

      // ---- Steady state: vfmacc only, no (n == 1) test ----
      KERNEL_NO_UNROLL
      while (n < N) {
        asm volatile("vle16.v v20, (%0);" ::"r"(b__));
        b__ += P;
        ++n;
        a__ = a_ + n;
        asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
        t0 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v4, %0, v16" ::"f"(t1));
        t1 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t2));
        t2 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v12, %0, v16" ::"f"(t3));
        t3 = *a__;

        ++n;
        a__ = a_ + n;

        if (n == N)
          break;

        asm volatile("vle16.v v16, (%0);" ::"r"(b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t1));
        t1 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t2));
        t2 = *a__;  a__ += lda;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t3));
        t3 = *a__;
      }

      asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
      asm volatile("vse16.v v0, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t1));
      asm volatile("vse16.v v4, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t2));
      asm volatile("vse16.v v8, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t3));
      asm volatile("vse16.v v12, (%0);" ::"r"(c__));
    }

    p += gvl;
  }
}

// ---- B-vector load chunking (DERIVED -- see the ROB0 budget below) -------------------------
// Mirrors SPATZ_1XVL_STORE_LMUL. Loading v8 as v8+v12 (and v16 as v16+v20) fills the same m8
// group, so the vfmacc consuming it is unchanged -- same register-mapping argument as the store
// split. 8 = one full-length load; 4 = two m4 halves, both still on the burst path (256 B is
// above the 64 B burst floor).
//
// WHY THIS IS DERIVED AND NOT A DEFAULT. The ROB0 id IS the memory response tag, and
// spatz_vlsu.sv:279 admits a burst load on the sole condition vl <= NrOutstandingLoads *
// MemDataWidthB -- a TAG-UNIQUENESS bound, with `<=`. The ALLOCATOR needs strictly more than
// that: reorder_buffer.sv:249 grants a burst block only at status_cnt <= NumWords - BlockWords,
// :236 never hands out the top two ids at all, and SPATZ_VLSU_DUAL_LOAD=2 deliberately keeps a
// SECOND load in flight (its validated design point is two loads that TOGETHER fill ROB0:
// 2 x 32 ids at rob_depth=64). So a load sized to the whole ROB passes the eligibility test and
// then starves -- no error, the run simply freezes before the kernel.
//
// Measured, single-variable control (waveC4, 2026-08-31): at rob_depth=128 an unsplit 512 B load
// froze at request 241,349; the split ran to completion. Passing this by hand is what made 10 of
// the 2026-09-01 re-run arms deadlock in the I$ warm-up -- the flag was simply omitted. Derive it
// so it cannot be omitted again.
//
// BUDGET: with dual-load, two loads must coexist, so one load may claim at most half of ROB0.
#ifndef SPATZ_ROB0_WORDS
// Software mirror of the RTL rob_depth (config/terapool_spatz4_fpu.mk: spatz_vlsu_rob_depth,
// -> SPATZ_VLSU_ROB_DEPTH). Keep the two in step; this is the only place software knows it.
#define SPATZ_ROB0_WORDS 128
#endif
#define SPATZ_1XVL_LOAD_WORD_CAP ((SPATZ_ROB0_WORDS) / 2)

#if defined(GEMM_M) && defined(GEMM_P) && defined(GEMM_ELEM_BYTES)
// Per-core column slice, from the SAME work split main.c hands the kernel (decode: main.c:415-418
// via n_p_blocks; prefill: main.c:440-441 via split_p_count). MATMUL_DECODE_SPLIT is hoisted above
// the kernel include so this sees the same branch the run takes.
#  ifdef GEMM_CONFIG_H
#    define SPATZ_1XVL_PSPAN GEMM_PSPAN(KERNEL_SIZE)
#  elif MATMUL_DECODE_SPLIT
#    define SPATZ_1XVL_PSPAN  ((GEMM_P) / ((NUM_CORES) / ((GEMM_M) / (KERNEL_SIZE))))
#  else
#    define SPATZ_1XVL_CPG_   ((NUM_CORES) / (NUM_GROUPS))
#    define SPATZ_1XVL_SHRB_  (((GEMM_M) / (NUM_GROUPS)) / (KERNEL_SIZE))
#    define SPATZ_1XVL_SPLITP ((SPATZ_1XVL_SHRB_ > 0 && SPATZ_1XVL_SHRB_ < SPATZ_1XVL_CPG_) \
                                 ? (SPATZ_1XVL_CPG_ / SPATZ_1XVL_SHRB_) : 1)
#    define SPATZ_1XVL_PSPAN  ((GEMM_P) / (SPATZ_1XVL_SPLITP))
#  endif
// gvl = min(p_span, vlmax); vlmax in BYTES at LMUL=8 is VLEN bits * 8 / 8 bits-per-byte = VLEN.
#  define SPATZ_1XVL_VLMAX_B  (((VLEN) * 8) / 8)
#  define SPATZ_1XVL_VL_B     (((SPATZ_1XVL_PSPAN) * (GEMM_ELEM_BYTES)) < (SPATZ_1XVL_VLMAX_B) \
                                 ? ((SPATZ_1XVL_PSPAN) * (GEMM_ELEM_BYTES)) : (SPATZ_1XVL_VLMAX_B))
#  define SPATZ_1XVL_LOAD_WORDS ((SPATZ_1XVL_VL_B) / 4)
#  ifndef SPATZ_1XVL_LOAD_LMUL
#    if (SPATZ_1XVL_LOAD_WORDS) > (SPATZ_1XVL_LOAD_WORD_CAP)
#      define SPATZ_1XVL_LOAD_LMUL 4
#    else
#      define SPATZ_1XVL_LOAD_LMUL 8
#    endif
#  endif
// A hand-passed 8 on a shape that needs 4 is the exact failure above. Fail the BUILD, where it is
// still cheap, rather than the run, where it costs a wedged simulation and no error message.
#  if ((SPATZ_1XVL_LOAD_LMUL) == 8) && ((SPATZ_1XVL_LOAD_WORDS) > (SPATZ_1XVL_LOAD_WORD_CAP))
#    error "SPATZ_1XVL_LOAD_LMUL=8 issues a load wider than half of ROB0 for this shape; with dual-load in flight it cannot allocate and the run freezes before the kernel. Drop the override (the derivation picks 4) or raise spatz_vlsu_rob_depth and SPATZ_ROB0_WORDS together."
#  endif
#else
// No GEMM shape in this translation unit: cannot derive the slice, so take the safe branch. At
// gvl <= half the split macro skips its second load, so 4 is never wrong, only occasionally
// one vsetvli more than necessary.
#  ifndef SPATZ_1XVL_LOAD_LMUL
#    define SPATZ_1XVL_LOAD_LMUL 4
#  endif
#endif
#if SPATZ_1XVL_LOAD_LMUL == 4
#  define SPATZ_LD(REGLO, REGHI, ADDR)                                                    \
     do {                                                                                 \
       const size_t _h = (size_t)128;                                              \
       const size_t _n2 = gvl > _h ? gvl - _h : 0;                                         \
       asm volatile("vsetvli zero, %0, e16, m4, ta, ma" ::"r"(gvl < _h ? gvl : _h));        \
       asm volatile("vle16.v " REGLO ", (%0);" ::"r"(ADDR));                                 \
       if (_n2) {                                                                          \
         asm volatile("vsetvli zero, %0, e16, m4, ta, ma" ::"r"(_n2));                       \
         asm volatile("vle16.v " REGHI ", (%0);" ::"r"((ADDR) + 128));                 \
       }                                                                                    \
       asm volatile("vsetvli zero, %0, e16, m8, ta, ma" ::"r"(gvl));                          \
     } while (0)
#else
#  define SPATZ_LD(REGLO, REGHI, ADDR) asm volatile("vle16.v " REGLO ", (%0);" ::"r"(ADDR))
#endif
// ---- C chunking geometry, shared by the accumulator load and the split store ----
#ifndef SPATZ_1XVL_STORE_LMUL
// C-store chunk size, as the LMUL of each store. The accumulator is m8; a store's TOTAL word
// count must fit the SHALLOW ROBs (ROB1-3), and it is the total, NOT the per-port share:
//     LMUL 8 -> 512 B = 128 words  needs ROBN >= 128
//     LMUL 4 -> 256 B =  64 words  needs ROBN >=  64
//     LMUL 2 -> 128 B =  32 words  needs ROBN >=  32
//     LMUL 1 ->  64 B =  16 words  needs ROBN >=  16
// Measured 2026-08-29: 2 x 256 B still froze at ROBN=16 (64 > 16), exactly as
// gen_robn_nonburst_capacity predicts. Splitting needs no data movement -- RVV maps element i to
// v(base + i/(VLEN/Ee16)) independently of LMUL, so an m8 group at v0 is 8/LMUL adjacent valid
// groups (v0,v4 at m4; v0,v2,v4,v6 at m2; v0..v7 at m1).
#define SPATZ_1XVL_STORE_LMUL 4
#endif
#define SPATZ_1XVL_CHUNK_ELEMS (32 * (SPATZ_1XVL_STORE_LMUL))
#if   SPATZ_1XVL_STORE_LMUL == 8
#  define SPATZ_1XVL_VT "e16, m8"
#elif SPATZ_1XVL_STORE_LMUL == 4
#  define SPATZ_1XVL_VT "e16, m4"
#elif SPATZ_1XVL_STORE_LMUL == 2
#  define SPATZ_1XVL_VT "e16, m2"
#else
#  define SPATZ_1XVL_VT "e16, m1"
#endif
// Accumulator LOAD, chunked exactly like SPATZ_ST_CHUNK below: an m8 accumulator whose
// store must be split for ROB capacity has to be RELOADED the same way, or the halves
// address the wrong elements.
#define SPATZ_LD_CHUNK(REG, IDX)                                                          \
  do {                                                                                    \
    const size_t _off = (size_t)(IDX) * (size_t)SPATZ_1XVL_CHUNK_ELEMS;                   \
    if (_off < gvl) {                                                                     \
      const size_t _rem = gvl - _off;                                                     \
      const size_t _n   = _rem < (size_t)SPATZ_1XVL_CHUNK_ELEMS                           \
                            ? _rem : (size_t)SPATZ_1XVL_CHUNK_ELEMS;                      \
      asm volatile("vsetvli zero, %0, " SPATZ_1XVL_VT ", ta, ma" ::"r"(_n));              \
      asm volatile("vle16.v " REG ", (%0);" ::"r"(c_ld + _off));                          \
    }                                                                                     \
  } while (0)
#define SPATZ_LD_ACC_RESTORE() asm volatile("vsetvli zero, %0, e16, m8, ta, ma" ::"r"(gvl))
#if   SPATZ_1XVL_STORE_LMUL == 8
#  define SPATZ_LD_ACC() do { SPATZ_LD_CHUNK("v0", 0); } while (0)
#elif SPATZ_1XVL_STORE_LMUL == 4
#  define SPATZ_LD_ACC() do { SPATZ_LD_CHUNK("v0", 0); SPATZ_LD_CHUNK("v4", 1);           \
                              SPATZ_LD_ACC_RESTORE(); } while (0)
#elif SPATZ_1XVL_STORE_LMUL == 2
#  define SPATZ_LD_ACC() do { SPATZ_LD_CHUNK("v0", 0); SPATZ_LD_CHUNK("v2", 1);           \
                              SPATZ_LD_CHUNK("v4", 2); SPATZ_LD_CHUNK("v6", 3);           \
                              SPATZ_LD_ACC_RESTORE(); } while (0)
#else
#  define SPATZ_LD_ACC() do { SPATZ_LD_CHUNK("v0", 0); SPATZ_LD_CHUNK("v1", 1);           \
                              SPATZ_LD_CHUNK("v2", 2); SPATZ_LD_CHUNK("v3", 3);           \
                              SPATZ_LD_CHUNK("v4", 4); SPATZ_LD_CHUNK("v5", 5);           \
                              SPATZ_LD_CHUNK("v6", 6); SPATZ_LD_CHUNK("v7", 7);           \
                              SPATZ_LD_ACC_RESTORE(); } while (0)
#endif

//==========================================================
// 1xVL: ONE output row per iteration, LMUL=8
//==========================================================
// KS x LMUL = 16 registers holds for KS = 8/4/2 (m2/m4/m8). KS=1 would need
// m16, which RVV does not have, so this variant keeps LMUL=8 and uses ONE
// accumulator: v0 (v0-v7) plus two m8 B buffers, v8 (v8-v15) and v16 (v16-v23).
// v24-v31 are deliberately left free -- a single accumulator is the whole point
// of KS=1, and there is nothing else to put in them.
//
// WHY IT EXISTS: kernel_size must divide M (main.c:343), so KS=1 is the ONLY
// legal kernel at B=1. Without it, decode GEMV cannot run at all.
//
// WHAT IT COSTS: arithmetic intensity is KS MACs per B element, so at KS=1
// every loaded element feeds exactly one FMA -- the one variant that cannot
// amortise a load. And sharers = M/KS = 1, so the group MSHR has no cohort to
// merge. Expect bandwidth-bound behaviour, not an FPU-bound one.
//
// N MUST BE EVEN. The steady-state loop only tests `n == N` on the even step;
// this is shared with 2xVL/4xVL/8xVL and every shape in use has N a power of 2.
//==========================================================
KERNEL_ATTR
void matmul_1xVL(elem_t *c, const elem_t *a, const elem_t *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end,
                 const unsigned int lda, const unsigned int accum) {
#if GBAR_PLOOP
  const uint32_t gbar_pl = gbar_base(GBAR_PLOOP_STRUCT);
#endif

  unsigned int p = p_start;
  while (p < p_end) {
    // ---- Per-column-block group rendezvous ----------------------------------
    // Re-align every core of the group at the start of this column block, so the
    // cores that share a B/W line issue their loads inside the MSHR's merge window.
    // This is the parent kernel's GBAR_PLOOP, restored.
    //
    // It needs a UNIFORM arrival count, which is why qwen_burst_vl caps at the
    // stripe boundary unconditionally: a cap applied only when misaligned makes the
    // number of column blocks depend on a core's start offset, the cores of a group
    // arrive here a different number of times, and the barrier stops releasing.
    //
    // Why it matters, measured: from B=2 the burst class stops bypassing and the
    // cores sharing a W line must form a cohort. At B=4 a core walks 9 column blocks
    // x 32 reduction steps per kernel call; with only one rendezvous per call they
    // drift apart, the cohort never assembles, entries sit out the 8191-cycle hold
    // and the banks fill (bank_full fired 93M times at B=4).
    GBAR_SYNC_PLOOP(gbar_pl);
    size_t gvl;
    asm volatile("vsetvli %[gvl], %[vl], e16, m8, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(qwen_burst_vl(p, p_end)));

    const elem_t *b_ = b + p;
    elem_t *c_ = c + p;

    KERNEL_NO_UNROLL
    for (unsigned int m = m_start; m < m_end; m += 1) {
      const elem_t *a_ = a + m * lda;
      const elem_t *a__ = a_;

      SPATZ_LD("v8", "v12", (b_));
      const elem_t *b__ = b_ + P;

      elem_t *c__ = c_ + m * P;

      elem_t t0;

      t0 = *a__;

      // ---- Accumulator init ------------------------------------------------
      // accum == 0: this is the first K tile, start the sums at zero.
      // accum != 0: continue the partial sums an earlier tile left in C.
      // The load mirrors the epilogue's store sequence exactly -- same registers,
      // same c__ walk -- so the two can never drift apart.
      if (accum) {
        elem_t *c_ld = c__;
        SPATZ_LD_ACC();
      } else {
        asm volatile("vmv.v.i v0, 0");
      }

      unsigned int n = 0;

      // ---- Peeled first iteration (primes the B ping-pong) ----
      ++n;  // n = 1
      a__ = a_ + n;
      SPATZ_LD("v16", "v20", (b__));
      b__ += P;
      asm volatile("vfmacc.vf v0, %0, v8" ::"f"(t0));
      t0 = *a__;

      ++n;  // n = 2
      a__ = a_ + n;
      if (n != N) {
        SPATZ_LD("v8", "v12", (b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
        t0 = *a__;
      }

      // ---- Steady state: vfmacc only ----
      KERNEL_NO_UNROLL
      while (n < N) {
        ++n;
        a__ = a_ + n;

        SPATZ_LD("v16", "v20", (b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v8" ::"f"(t0));
        t0 = *a__;

        ++n;
        a__ = a_ + n;

        if (n == N)
          break;

        SPATZ_LD("v8", "v12", (b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
        t0 = *a__;
      }

      asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
      // SPLIT STORE (SPATZ_1XVL_SPLIT_STORE, default ON).
      // Bursts are LOADS ONLY (use_port0_burst_req requires is_load), so a vector STORE always
      // takes the word-interleaved path across NrMemPorts=4 and its per-port share must fit the
      // SHALLOW ROBs. A 512 B store is 128 words = 32/port, which needs ROBN>=32; splitting it
      // into two 256 B stores makes it 16/port and fits ROBN=16, keeping the asymmetric-depth
      // area saving. The LOAD is untouched and keeps its full 512 B burst on ROB0.
      //
      // Legal without moving data: RVV maps element i to register v(base + i/(VLEN/Ee16))
      // independently of LMUL, so at VLEN=512 an m8 group at v0 holds its first 128
      // elements in v0-v3 and the rest in v4-v7 -- exactly two m4 groups. The split MUST land on
      // that 4-register boundary; anywhere else and v4 addresses the wrong elements and C is
      // silently wrong.
#define SPATZ_ST_CHUNK(REG, IDX)                                                          \
  do {                                                                                    \
    const size_t _off = (size_t)(IDX) * (size_t)SPATZ_1XVL_CHUNK_ELEMS;                   \
    if (_off < gvl) {                                                                     \
      const size_t _rem = gvl - _off;                                                     \
      const size_t _n   = _rem < (size_t)SPATZ_1XVL_CHUNK_ELEMS                           \
                            ? _rem : (size_t)SPATZ_1XVL_CHUNK_ELEMS;                      \
      asm volatile("vsetvli zero, %0, " SPATZ_1XVL_VT ", ta, ma" ::"r"(_n));              \
      asm volatile("vse16.v " REG ", (%0);" ::"r"(c__ + _off));                             \
    }                                                                                     \
  } while (0)
#if   SPATZ_1XVL_STORE_LMUL == 8
      SPATZ_ST_CHUNK("v0", 0);
#elif SPATZ_1XVL_STORE_LMUL == 4
      SPATZ_ST_CHUNK("v0", 0); SPATZ_ST_CHUNK("v4", 1);
#elif SPATZ_1XVL_STORE_LMUL == 2
      SPATZ_ST_CHUNK("v0", 0); SPATZ_ST_CHUNK("v2", 1);
      SPATZ_ST_CHUNK("v4", 2); SPATZ_ST_CHUNK("v6", 3);
#else
      SPATZ_ST_CHUNK("v0", 0); SPATZ_ST_CHUNK("v1", 1);
      SPATZ_ST_CHUNK("v2", 2); SPATZ_ST_CHUNK("v3", 3);
      SPATZ_ST_CHUNK("v4", 4); SPATZ_ST_CHUNK("v5", 5);
      SPATZ_ST_CHUNK("v6", 6); SPATZ_ST_CHUNK("v7", 7);
#endif
#if SPATZ_1XVL_STORE_LMUL != 8
      asm volatile("vsetvli zero, %0, e16, m8, ta, ma" ::"r"(gvl));   // restore the m8 view
#endif
    }

    p += gvl;
  }
}

//==========================================================
// 2xVL: Process 2 output rows per iteration, LMUL=2
//==========================================================
KERNEL_ATTR
void matmul_2xVL(elem_t *c, const elem_t *a, const elem_t *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end,
                 const unsigned int lda, const unsigned int accum) {
#if GBAR_PLOOP
  const uint32_t gbar_pl = gbar_base(GBAR_PLOOP_STRUCT);
#endif

  unsigned int p = p_start;
  while (p < p_end) {
    // ---- Per-column-block group rendezvous ----------------------------------
    // Re-align every core of the group at the start of this column block, so the
    // cores that share a B/W line issue their loads inside the MSHR's merge window.
    // This is the parent kernel's GBAR_PLOOP, restored.
    //
    // It needs a UNIFORM arrival count, which is why qwen_burst_vl caps at the
    // stripe boundary unconditionally: a cap applied only when misaligned makes the
    // number of column blocks depend on a core's start offset, the cores of a group
    // arrive here a different number of times, and the barrier stops releasing.
    //
    // Why it matters, measured: from B=2 the burst class stops bypassing and the
    // cores sharing a W line must form a cohort. At B=4 a core walks 9 column blocks
    // x 32 reduction steps per kernel call; with only one rendezvous per call they
    // drift apart, the cohort never assembles, entries sit out the 8191-cycle hold
    // and the banks fill (bank_full fired 93M times at B=4).
    GBAR_SYNC_PLOOP(gbar_pl);
    size_t gvl;
    asm volatile("vsetvli %[gvl], %[vl], e16, m8, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(qwen_burst_vl(p, p_end)));

    const elem_t *b_ = b + p;
    elem_t *c_ = c + p;

    KERNEL_NO_UNROLL
    for (unsigned int m = m_start; m < m_end; m += 2) {
      const elem_t *a_ = a + m * lda;
      const elem_t *a__ = a_;

      asm volatile("vle16.v v16, (%0);" ::"r"(b_));
      const elem_t *b__ = b_ + P;

      elem_t *c__ = c_ + m * P;

      elem_t t0, t1;

      t0 = *a__;
      a__ += lda;
      t1 = *a__;

      // ---- Accumulator init ------------------------------------------------
      // accum == 0: this is the first K tile, start the sums at zero.
      // accum != 0: continue the partial sums an earlier tile left in C.
      // The load mirrors the epilogue's store sequence exactly -- same registers,
      // same c__ walk -- so the two can never drift apart.
      // ---- C reload window ---------------------------------------------
      // These eight loads are per-core PRIVATE (c__ = c_ + m_start*P), so no two
      // cores of the group ever share one. Under a live MSHR they allocate
      // unmergeable entries that hold bank ways and evict the W cohort -- the
      // merge rate collapses from ~88% to ~52% the moment accum goes high.
      // Bracket them with CFG_ENABLE=0, which gates merge/alloc only (resident
      // entries keep draining), so they bypass the MSHR entirely. Each toggle
      // needs its own rendezvous: gbar_sync guarantees a core's prior requests
      // are ISSUED, so after the release the writer may flip the CSR, and after
      // the next release every core sees the new setting.
      if (accum) {
        QWEN_CBYPASS_ENTER(gbar_pl);
        elem_t *c_ld = c__;
        asm volatile("vle16.v v0, (%0);" ::"r"(c_ld));
        c_ld += P;
        asm volatile("vle16.v v8, (%0);" ::"r"(c_ld));
        (void)c_ld;
        QWEN_CBYPASS_EXIT(gbar_pl);
      } else {
        asm volatile("vmv.v.i v0, 0");
        asm volatile("vmv.v.i v8, 0");
      }

      unsigned int n = 0;

      // ---- Peeled first iteration (primes the B ping-pong and keeps the
      //      per-iteration (n == 1) test out of the hot loop) ----
      ++n;  // n = 1
      a__ = a_ + n;
      asm volatile("vle16.v v24, (%0);" ::"r"(b__));
      b__ += P;
      asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
      t0 = *a__;
      a__ += lda;
      asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
      t1 = *a__;

      ++n;  // n = 2
      a__ = a_ + n;
      if (n != N) {
        asm volatile("vle16.v v16, (%0);" ::"r"(b__));
        b__ += P;
        asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
        t0 = *a__;
        a__ += lda;
        asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
        t1 = *a__;
      }

      // ---- Steady state: vfmacc only, no (n == 1) test ----
      KERNEL_NO_UNROLL
      while (n < N) {
        ++n;
        a__ = a_ + n;

        asm volatile("vle16.v v24, (%0);" ::"r"(b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
        t0 = *a__;
        a__ += lda;
        asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
        t1 = *a__;

        ++n;
        a__ = a_ + n;

        if (n == N)
          break;

        asm volatile("vle16.v v16, (%0);" ::"r"(b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
        t0 = *a__;
        a__ += lda;
        asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
        t1 = *a__;
      }

      asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
      asm volatile("vse16.v v0, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
      asm volatile("vse16.v v8, (%0);" ::"r"(c__));
    }

    p += gvl;
  }
}

