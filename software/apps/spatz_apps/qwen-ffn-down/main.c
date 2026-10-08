// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
//==============================================================================
// Qwen3.8-27B FFN down projection, streamed from L2.
//==============================================================================
//
//   Y = H . Wdown      H:[B][K]  Wdown:[K][P]  Y:[B][P]      K = 16384, P = 4096
//
// Canonical shapes (docs/qwen3_8_27b/canonical_shapes.md): the model's 17408 -> 5120 is
// rounded to 16384 -> 4096 so every per-core column span is a whole 64-byte stripe.
// H = SiLU(G) * U. With ffn_swiglu=1 (default) it is computed here, in a timed prologue, from
// G and U in L2 in qwen-gate-up's output layout; ffn_swiglu=0 loads H directly.
// docs/qwen3_8_27b/ffn_plan.md, steps 1-2.
//
// FORKED from qwen-gate-up @ dd6056fa (main.c, qwen_layout.h, kernel/, script/). The
// pipeline is the parent's, unchanged: W is cut into QWEN_KT-row tiles, tile t+1 is DMA'd
// into one L1 buffer while the cores compute on the other, every tile adds into the same
// C, one continuous W stream, one DMA per tile. What differs is the aspect ratio: K is long
// and P short, so a core owns few outputs and the K split (QWEN_KSPLIT cores per output
// patch, partials added once at the end) is the norm rather than the small-batch case.
// The A operand keeps the parent's name X (qwen_x) so the two files diff cleanly.
//
// The L2 operands are .l2_bss: reserved, not stored in the ELF. QWEN_CHECK builds fill
// them (on the target, or preloaded from the host with ffn_preload=1) with a pattern whose
// exact result is known and verify it with integer compares only (qwen_pattern.h).
//
//==============================================================================

#include <stddef.h>
#include <stdint.h>

#include "data/qwen_shape.h"  // GEMM_M/N/P, GEMM_ELEM_BYTES, QWEN_KT_REQ, QWEN_CHECK
#include "qwen_layout.h"      // where X's replicas sit in L1
#include "qwen_pattern.h"     // the synthetic operand values
#include "data/qwen_hash.h"   // bank-hash selectors chosen at build time
_Static_assert(sizeof(qwen_hash_sel) / sizeof(qwen_hash_sel[0]) == NUM_GROUPS,
              "data/qwen_hash.h was generated for another mesh: rebuild its generated headers");

#include "gemm_config.h"  // KERNEL_SIZE + MATMUL_DECODE_SPLIT from the shape
#include "gemm_burst.h"   // GEMM_BURST_* geometry; the kernel's stripe rule needs it

// Before the kernel: it brackets its C-accumulator reload with CFG_ENABLE writes
// (QWEN_CBYPASS), so mshr_cfg_write must already be declared.
#define MSHR_HASH_SEARCH 0
#include "mshr_cfg.h"
#include "kernel/qwen-fmatmul.c"
#if QWEN_SWIGLU
#include "swiglu.h"
#endif

#include "printf.h"
#include "alloc.h"
#include "runtime.h"
#include "synchronization.h"
#include "encoding.h"
#include "dma.h"

//==============================================================================
// Derived shape
//==============================================================================

#define QWEN_STEPS ((QWEN_K) / (QWEN_KT))

// Correctness patterns, all exactly representable in fp16 so the check is an
// integer compare of raw halfwords -- no FP anywhere on the checking path.
//   0 = none: L2 operands are left unwritten, nothing is verified. Perf runs.
//   1 = unit:  X = one-hot, so C[b][p] == W[k0+b][p] exactly. Checks addressing,
//              tiling, DMA and the burst path at ANY K.
//   2 = ones:  X = W = 1, so C[b][p] == K exactly. Checks the MAC count and the
//              accumulation across K tiles. Needs K a power of two <= 2048, since
//              fp16 counts integers exactly only that far.
// Core 0 is the long pole at start-up: it copies X to every replica and primes
// the pipeline. The once-per-group setup -- the group barrier and the MSHR CSRs
// -- needs only "some core of this group", so give it to another one and let it
// overlap with core 0's DMA. Any tile in a group can write that group's CSRs.
#define QWEN_GROUP_HELPER 1u

// Which core drives the global DMA. Core 0 by default; set to a core of another
// group to test whether the DMA duty, rather than the buffers' home, is what
// desynchronises a merge pair.
#ifndef QWEN_DMA_CORE
#define QWEN_DMA_CORE 0u
#endif

// Whether the operands are written on target at all. Off by default: the
// platform is expected to hand us defined memory (tc_sram SimInit on RTL,
// zeroed L2 in GVSoC). When it is on, it writes the SAME pattern a check build
// uses -- filling with zeros would cost the same and leave any later comparison
// meaningless.
#ifndef QWEN_INIT
#define QWEN_INIT 0
#endif
#ifndef QWEN_PRELOAD
#define QWEN_PRELOAD 0
#endif
#define QWEN_FILL (!(QWEN_PRELOAD) && ((QWEN_INIT) || (QWEN_CHECK)))

_Static_assert(GEMM_ELEM_BYTES == 2, "This app is fp16 only");
_Static_assert((QWEN_K % QWEN_KT) == 0,
               "K must be a whole number of K tiles: pick a QWEN_KT that divides it");
_Static_assert((QWEN_KT % 2) == 0, "The kernel's n loop unrolls by 2, so KT must be even");
_Static_assert((QWEN_KT % (2 * QWEN_KSPLIT)) == 0,
               "Under the K split each core reduces KT/QWEN_KSPLIT rows, which must be even too");
#if QWEN_KSPLIT > 1
_Static_assert((QWEN_KSPLIT & (QWEN_KSPLIT - 1)) == 0 && QWEN_KSPLIT <= 16,
               "The K split factor is a power of two up to one group (16)");
_Static_assert(MATMUL_DECODE_SPLIT, "The K split exists only in the decode split");
_Static_assert(QWEN_NSTRIPS == 1,
               "The K split reduces after the last K tile, but a strip is written back inside "
               "that tile's barrier -- it would write out the unreduced half");
_Static_assert(GBAR_PLOOP, "The reduction rendezvouses the group on the GBAR_PLOOP struct");
#endif
_Static_assert((QWEN_LDP % QWEN_STRIPE_E) == 0, "Row stride must be a whole number of stripes");
_Static_assert((QWEN_WPAD % QWEN_STRIPE_E) == 0,
               "The row pad must be whole stripes, or rows stop starting on a burst boundary");
_Static_assert((QWEN_PBLOCKS & (QWEN_PBLOCKS - 1)) == 0,
               "A power-of-two column-block count is what makes QWEN_PAD_UNIT a single "
               "round-up instead of a least common multiple");
_Static_assert((QWEN_LDP / QWEN_PBLOCKS) % QWEN_SPAN_ALIGN == 0,
               "Columns per core must be a multiple of 4 elements or the weight loads "
               "stop bursting; see the QWEN_PAD_UNIT derivation");
#if QWEN_CHECK == 1
_Static_assert(4u * QWEN_HOT_TERMS < 2048u,
               "The multi-hot pattern sums QWEN_HOT_TERMS grid values of up to 1/2; every "
               "partial sum must stay below 256 to be exact in fp16 -- lower K or raise KT");
#endif
#if QWEN_CHECK == 3
_Static_assert(QWEN_SWIGLU && QWEN_PRELOAD,
               "The SwiGLU check compares against a host reference: ffn_swiglu=1 ffn_preload=1");
#endif
#if QWEN_CHECK == 4
_Static_assert(!QWEN_SWIGLU && QWEN_PRELOAD && QWEN_NSTRIPS == 1,
               "The bit-exact check preloads random H and W and the host model's Y: "
               "ffn_swiglu=0 ffn_preload=1, one strip");
#endif
#if QWEN_SWIGLU
// Each core computes one contiguous run of H; it must stay inside one row and one G/U strip.
// At least FFN_SW_MIN elements per core: on this RTL, Spatz wedges when an integer-unit op
// consumes an FPU result at vl <= 4 (the 2^n step, `vadd.vx` on `vfcvt.x.f.v`'s output; measured
// 4x4 B=1: 2 and 4 elements per core hang every core, 8 run). When B*K/cores is smaller, only
// the first FFN_SW_CORES cores compute and the rest just meet the barrier. Only small check
// shapes get there -- at K = 16384 every core has >= 16.
#ifndef FFN_SW_MIN
#define FFN_SW_MIN 16u  // EXTRA_DEFINES=-DFFN_SW_MIN=2 re-exposes the wedge (for an RTL fix)
#endif
#define FFN_SW_EVEN ((uint32_t)((QWEN_B * QWEN_K) / NUM_CORES))
#define FFN_SW_CHUNK ((FFN_SW_EVEN) > (FFN_SW_MIN) ? (FFN_SW_EVEN) : (FFN_SW_MIN))
#define FFN_SW_CORES ((uint32_t)((QWEN_B * QWEN_K) / (FFN_SW_CHUNK)))
_Static_assert(((QWEN_B * QWEN_K) % NUM_CORES) == 0 && (FFN_SW_CHUNK % 2u) == 0u &&
                   ((QWEN_B * QWEN_K) % FFN_SW_CHUNK) == 0 &&
                   (QWEN_K % FFN_SW_CHUNK) == 0 && (FFN_GU_PT % FFN_SW_CHUNK) == 0,
               "SwiGLU: every core's run of H must be whole, even, and inside one row and strip");
_Static_assert((QWEN_K % FFN_GU_PT) == 0, "G/U strips must tile K");
_Static_assert(FFN_GU_ELEMS <= QWEN_WSLOT, "G and U are staged in the W slots: one must fit one slot");
_Static_assert(QWEN_REPEATS == 1, "The prologue consumes the staged G/U: one pass only");
#endif
#if QWEN_CHECK == 2
_Static_assert(QWEN_K <= 2048 && (QWEN_K & (QWEN_K - 1)) == 0,
               "The ones pattern needs K a power of two <= 2048 to stay exact in fp16");
#endif
#if FFN_KSPLIT_XGROUP
_Static_assert(QWEN_KSPLIT > 1 && MATMUL_DECODE_SPLIT && !QWEN_ACC32,
               "ffn_kgroup=1 moves the K split across groups: needs a K split, the decode split, "
               "and ffn_acc=16 (the fp32 C is group-local, so its partners must share a group)");
#endif
#if QWEN_ACC32
_Static_assert(QWEN_NSTRIPS == 1 && QWEN_STAGES_N == 1,
               "fp32 accumulation writes one fp16 Y at the end: one strip, one stage");
#endif
#if FFN_PRIME_SPLIT > 1
_Static_assert(QWEN_NSTRIPS == 1 && QWEN_REPEATS == 1,
               "The first tile is fetched in pieces once, at the start of the only strip");
_Static_assert((QWEN_KT_CORE % (2u * FFN_PRIME_SPLIT)) == 0,
               "Every piece of the first tile must leave each core an even number of rows");
#endif

// Friendly early failure for an L1 budget the linker would otherwise report as a
// bare region overflow. Approximate on purpose: the linker stays authoritative.
// The budget and the strip width are in qwen_layout.h ("P strips").
_Static_assert(QWEN_PT > 0,
               "No output-strip width fits L1 even at LDP/64: lower QWEN_KT (the W "
               "double buffer) or the batch (X)");
_Static_assert(QWEN_PT_OK(QWEN_PT),
               "qwen_pt must be a whole number of pad units, divide LDP, leave every "
               "core a column span of at least one vector load, and fit L1");

//==============================================================================
// Storage
//==============================================================================

#define QWEN_L1 __attribute__((section(".l1_prio"), aligned(QWEN_MESH_SWEEP)))
// Reserved in L2 but NOT stored in the ELF -- see the header comment.
#define QWEN_L2 __attribute__((section(".l2_bss"), aligned(QWEN_MESH_SWEEP)))

enum { QWEN_DOWN = 0, QWEN_STAGES = QWEN_STAGES_N };

#if QWEN_PRELOAD
// Defined by data/qwen_operands.S, which .incbin's the images the host wrote.
extern elem_t qwen_w_l2[QWEN_STAGES][QWEN_WTILES * QWEN_WSLOT];
#if QWEN_SWIGLU
extern elem_t qwen_gu_l2[2][FFN_GU_SLOT];  // G, U in gate-up's output layout
#if QWEN_CHECK == 3
extern elem_t qwen_href_l2[QWEN_B * QWEN_K];  // host reference H
#endif
#else
extern elem_t qwen_x_l2[QWEN_B * QWEN_LDX];
#endif
#if QWEN_CHECK == 4
extern elem_t qwen_yref_l2[QWEN_B * QWEN_P];  // the host model's bit-exact Y
#endif
#else
static elem_t qwen_w_l2[QWEN_STAGES][QWEN_WTILES * QWEN_WSLOT] QWEN_L2;
#if QWEN_SWIGLU
static elem_t qwen_gu_l2[2][FFN_GU_SLOT] QWEN_L2;
#else
static elem_t qwen_x_l2[QWEN_B * QWEN_LDX] QWEN_L2;
#endif
#endif

// Slots are rounded up to whole mesh sweeps (QWEN_WSLOT/CSLOT) so the second of each
// pair starts sweep-aligned like the first; the rows inside use stride QWEN_LDW.
static elem_t qwen_w[2][QWEN_WSLOT] QWEN_L1;            // K-tile double buffer
#if QWEN_ACC32
// fp32 accumulators, every core's and every K part's, group-local (qwen_layout.h, QWEN_C32_*);
// the fp16 result Y = H . W goes to qwen_y, [B][LDW].
static elem_t qwen_c32[QWEN_C32_ELEMS] QWEN_L1;
static elem_t qwen_y[QWEN_CSLOT] QWEN_L1;
#define QWEN_Y qwen_y
// Core `core`'s first chunk: its group's slice of the sweep, then its run of slices.
static inline elem_t *qwen_c32_of(uint32_t core) {
  const uint32_t per_group = (uint32_t)(NUM_CORES / NUM_GROUPS);
  const uint32_t g = core / per_group, cg = core % per_group;
  return (elem_t *)((uintptr_t)qwen_c32 + g * (uint32_t)QWEN_GROUP_STRIDE +
                    cg * ((uint32_t)QWEN_C32_CH / (uint32_t)QWEN_C32_CPG) *
                        (uint32_t)QWEN_MESH_SWEEP);
}
#else
// Accumulator, one strip.
static elem_t qwen_c[QWEN_STAGES][QWEN_CSLOT] QWEN_L1;
#if QWEN_KSPLIT > 1
// K parts 1..QWEN_KSPLIT-1's partial sums, each the layout of qwen_c. One set serves both
// stages: a projection's partials are consumed by its own reduction before the next one runs.
static elem_t qwen_cp[QWEN_KSPLIT - 1][QWEN_CSLOT] QWEN_L1;
#endif
#define QWEN_Y qwen_c[0]
#endif
#if QWEN_NSTRIPS > 1
// Finished strips, strip-major [strip][B][LDW]: each strip is one contiguous DMA.
static elem_t qwen_out_l2[QWEN_STAGES][QWEN_NSTRIPS * QWEN_B * QWEN_LDW] QWEN_L2;
#endif
// One copy of X per QWEN_X_GROUPS_PER_REPLICA groups; replica r starts at
// r * QWEN_X_STRIDE_E so it lands on the first group of its neighbourhood.
static elem_t qwen_x[QWEN_X_ELEMS] QWEN_L1;
#if QWEN_SWIGLU
#if FFN_GU_EARLY
#define FFN_G_L1 (qwen_w[1])
#define FFN_U_L1 (qwen_w[1] + FFN_GU_SLOT)
#else
#define FFN_G_L1 (qwen_w[0])
#define FFN_U_L1 (qwen_w[1])
#endif
#endif

// Each core reports the FMACs its own range implies, so the dashboard's expected
// assignment comes from the real split rather than a second copy of the formula.
static uint32_t qwen_fmac_core[NUM_CORES];

// When each K tile's barrier closed (timer, last pass), written by the one core that closes
// it: one CSR read and one store per tile. Printed after the region as cycles per K tile, so
// a run that completes gives the steady-state rate without an RTL-only probe.
// Tile 0 counts once per piece when it is fetched in pieces (FFN_PRIME_SPLIT).
#define QWEN_TS_N ((QWEN_NSTRIPS) * (QWEN_STAGES_N) * (QWEN_STEPS) + (FFN_PRIME_SPLIT)-1)
static uint32_t qwen_tile_ts[QWEN_TS_N];


#if !QWEN_CHECK && (QWEN_FILL || QWEN_PRELOAD)
// The finished output element (stage, b, p): the L1 accumulator with one strip,
// the strip-major L2 copy with several. Only the perf build's fingerprint reads it;
// a check build verifies strip by strip from L1 instead.
static inline const uint16_t *qwen_out_at(uint32_t stage, uint32_t b, uint32_t p) {
#if QWEN_NSTRIPS > 1
  return (const uint16_t *)&qwen_out_l2[stage][(p / QWEN_PT) * (QWEN_B * QWEN_LDW) +
                                               b * QWEN_LDW + (p % QWEN_PT)];
#else
  (void)stage;
  return (const uint16_t *)&QWEN_Y[b * QWEN_LDW + p];
#endif
}
#endif

//==============================================================================
// Synthetic operands (QWEN_CHECK builds only)
//==============================================================================
// Bit patterns, not arithmetic: every value below is exact in fp16, so the whole
// fill-and-verify path is integer stores, integer loads and integer compares.

#if QWEN_CHECK == 1 || QWEN_CHECK == 2
// What C must hold afterwards. The multi-hot sum depends on p only through p mod 3
// (qwen_pattern.h), so the verify keeps the three values of the row it is on.
static inline uint16_t qwen_expect_bits(uint32_t stage, uint32_t b, uint32_t p) {
#if QWEN_CHECK == 2
  (void)stage;
  (void)b;
  (void)p;
  // K = 2^e, and fp16 2^e is (15 + e) << 10 with a zero mantissa.
  uint32_t e = 0;
  while ((1u << e) != (uint32_t)QWEN_K) ++e;
  return (uint16_t)((15u + e) << 10);
#else
  return qwen_eighths_to_fp16(qwen_expect_eighths(stage, b, p));
#endif
}

#endif  // QWEN_CHECK (expectation)

#if QWEN_FILL
// Every core fills its own interleaved share; this runs before the MSHR is
// enabled and outside the timed region.
//
// A WORD at a time, not a halfword: at the full shape this is 178M elements, and
// each store is a separate NoC transaction to L2, so pairing them halves the cost
// of the slowest part of a check build. K and LDW are both even, so the pairs never
// straddle a row.
static void qwen_fill_operands(uint32_t cid, uint32_t num_cores) {
#if QWEN_SWIGLU
  // G and U in gate-up's layout [strip][B][LD]; LD and PT are even, so a pair never straddles.
  for (uint32_t s = 0; s < 2u; ++s) {
    uint32_t *gu = (uint32_t *)qwen_gu_l2[s];
    for (uint32_t i = cid; i < (uint32_t)FFN_GU_ELEMS / 2u; i += num_cores) {
      const uint32_t e = 2u * i, strip = e / (QWEN_B * FFN_GU_LD), r = e % (QWEN_B * FFN_GU_LD);
      const uint32_t b = r / FFN_GU_LD, c = r % FFN_GU_LD, k = strip * FFN_GU_PT + c;
      uint32_t lo = 0, hi = 0;
      if (c < (uint32_t)FFN_GU_PT) lo = s ? qwen_u_bits(b, k) : qwen_g_bits(b, k);
      if (c + 1u < (uint32_t)FFN_GU_PT) hi = s ? qwen_u_bits(b, k + 1u) : qwen_g_bits(b, k + 1u);
      gu[i] = lo | (hi << 16);
    }
  }
#else
  uint32_t *x = (uint32_t *)qwen_x_l2;
  // [B][QWEN_LDX]: K and LDX are even, so a pair never straddles a row; the pad is zero.
  for (uint32_t i = cid; i < (uint32_t)(QWEN_B * QWEN_LDX) / 2u; i += num_cores) {
    const uint32_t e = 2u * i, b = e / QWEN_LDX, k = e % QWEN_LDX;
    x[i] = (k < (uint32_t)QWEN_K)
               ? ((uint32_t)qwen_x_bits(b, k) | ((uint32_t)qwen_x_bits(b, k + 1u) << 16))
               : 0u;
  }
#endif
  for (uint32_t s = 0; s < QWEN_STAGES; ++s) {
    uint32_t *w = (uint32_t *)qwen_w_l2[s];
    for (uint32_t i = cid; i < (uint32_t)(QWEN_WTILES * QWEN_WSLOT) / 2u; i += num_cores) {
      // e walks [tile][r], tile = strip * STEPS + step, and inside a tile the KT rows of
      // LDW then the zero fill up to the sweep-rounded slot. LDW and WSLOT are even, so a
      // pair never straddles a row; with one strip and no pad this is the old row-major
      // decode.
      const uint32_t e = 2u * i, tile = e / QWEN_WSLOT, r = e % QWEN_WSLOT;
      const uint32_t in_tile = r < (uint32_t)(QWEN_KT * QWEN_LDW);
      const uint32_t strip = tile / QWEN_STEPS;
      const uint32_t k = FFN_W_ROW(tile % QWEN_STEPS, r / QWEN_LDW);  // tile 0 piece-major
      const uint32_t c = r % QWEN_LDW, col = strip * QWEN_PT + c;
      // Columns in [P, LDP) are alignment padding, c >= PT the row pad and r past the
      // tile the slot fill: never read by the kernel, and zero so that a run that
      // accidentally reads them is obviously wrong.
      const uint32_t lo = (in_tile && c < (uint32_t)QWEN_PT && col < (uint32_t)QWEN_P)
                              ? qwen_w_bits(s, k, col) : 0u;
      const uint32_t hi = (in_tile && c + 1u < (uint32_t)QWEN_PT && col + 1u < (uint32_t)QWEN_P)
                              ? qwen_w_bits(s, k, col + 1u) : 0u;
      w[i] = lo | (hi << 16);
    }
  }
}

#endif  // QWEN_FILL

#if QWEN_CHECK == 1 || QWEN_CHECK == 2
// Integer compare of the whole output, one strip at a time, split across every core
// (element i of the strip goes to core i % num_cores). With several strips the DMA
// first brings the strip back from L2 into the L1 accumulator, so the check reads L1
// and also covers the write-back and its strip-major layout. The first core to find a
// wrong element records it. Both stages carry the same expected value.
static volatile uint32_t qwen_bad, qwen_bad_s, qwen_bad_b, qwen_bad_p, qwen_bad_got,
    qwen_bad_want;
static void qwen_verify_strip(uint32_t strip, uint32_t cid, uint32_t num_cores) {
  const uint32_t n = (uint32_t)(QWEN_STAGES * QWEN_B * QWEN_PT);
  uint32_t cached = 0xffffffffu;  // (stage, row) the three expectations below belong to
  uint16_t want3[3] = {0, 0, 0};
  for (uint32_t i = cid; i < n; i += num_cores) {
    const uint32_t s = i / (QWEN_B * QWEN_PT), r = i % (QWEN_B * QWEN_PT);
    const uint32_t b = r / QWEN_PT, col = r % QWEN_PT;
    const uint32_t p = strip * (uint32_t)QWEN_PT + col;
    if (p >= (uint32_t)QWEN_P) continue;  // padding columns hold no result
    if (cached != s * (uint32_t)QWEN_B + b) {
      cached = s * (uint32_t)QWEN_B + b;
      for (uint32_t m = 0; m < 3u; ++m) want3[m] = qwen_expect_bits(s, b, m);
    }
    const uint16_t e = want3[p % 3u];
    const uint16_t v = ((const uint16_t *)QWEN_Y)[s * (uint32_t)QWEN_CSLOT + b * QWEN_LDW + col];
    if (v != e && __atomic_fetch_add(&qwen_bad, 1u, __ATOMIC_RELAXED) == 0u) {
      qwen_bad_s = s;
      qwen_bad_b = b;
      qwen_bad_p = p;
      qwen_bad_got = v;
      qwen_bad_want = e;
    }
  }
}
#endif  // QWEN_CHECK 1/2 (verify)

#if QWEN_CHECK == 4
// Bit-exact check of the fp16 arithmetic: Y (in C, L1) against the host model of the kernel
// (script/fp16_host.h fma16/add16 in the kernel's order), DMA'd into W slot 0. Any difference
// means the model -- and so every accuracy number derived from it -- does not match the
// hardware. Per-core result slots, no AMOs.
static uint32_t qwen_bx_bad[NUM_CORES], qwen_bx_first[NUM_CORES];
static void qwen_verify_bitexact(uint32_t cid, uint32_t num_cores) {
  const uint16_t *y = (const uint16_t *)QWEN_Y, *ref = (const uint16_t *)qwen_w[0];
  uint32_t bad = 0, first = 0xffffffffu;
  for (uint32_t i = cid; i < (uint32_t)(QWEN_B * QWEN_P); i += num_cores) {
    const uint32_t b = i / (uint32_t)QWEN_P, p = i % (uint32_t)QWEN_P;
    if (y[b * (uint32_t)QWEN_LDW + p] != ref[i]) {
      if (!bad) first = i;
      ++bad;
    }
  }
  qwen_bx_bad[cid] = bad;
  qwen_bx_first[cid] = first;
}
#endif

#if QWEN_CHECK == 3
// SwiGLU check: H (replica 0) against the host's float64 reference, both fp16, compared as
// ordered integers so the distance is in ulps (+0 and -0 are the same point). Integer-only,
// all cores in parallel; the host reference has been DMA'd into W slot 0 (free again).
// Each core writes its own result slot and core 0 sums them, with no AMOs
// (an amomaxu on L1 made the GVSoC TCDM interface report an untracked response).
static uint32_t qwen_sw_bad[NUM_CORES], qwen_sw_maxulp[NUM_CORES], qwen_sw_exact[NUM_CORES],
    qwen_sw_first[NUM_CORES];
static inline int32_t qwen_f16_ord(uint16_t h) {
  return (h & 0x8000u) ? -(int32_t)(h & 0x7fffu) : (int32_t)h;
}
static void qwen_verify_swiglu(uint32_t cid, uint32_t num_cores) {
  const uint16_t *h = (const uint16_t *)qwen_x, *ref = (const uint16_t *)qwen_w[0];
  uint32_t maxulp = 0, exact = 0, bad = 0, first = 0xffffffffu;
  for (uint32_t i = cid; i < (uint32_t)(QWEN_B * QWEN_K); i += num_cores) {
    const uint32_t hi = (i / (uint32_t)QWEN_K) * (uint32_t)QWEN_LDX + i % (uint32_t)QWEN_K;
    const int32_t d = qwen_f16_ord(h[hi]) - qwen_f16_ord(ref[i]);
    const uint32_t ad = (uint32_t)(d < 0 ? -d : d);
    exact += (ad == 0u);
    if (ad > maxulp) maxulp = ad;
    if (ad > 2u) {
      if (!bad) first = i;
      ++bad;
    }
  }
  qwen_sw_bad[cid] = bad;
  qwen_sw_maxulp[cid] = maxulp;
  qwen_sw_exact[cid] = exact;
  qwen_sw_first[cid] = first;
}
#endif

//==============================================================================
// The K-tile pipeline
//==============================================================================

// The timed region's rendezvous, ported from the verified MemPool double-buffer
// barrier (double_buffer_2/apps/tests/main.c).
//
// Each stage counts in ONE core's sequential memory -- crt0 puts that region in
// the core's own tile, so the cores of a group settle their stage without leaving
// it, which a shared counter array cannot promise. The word is the deepest one of
// that core's stack slot (crt0.S sets stacklimit to exactly core_id*SEQ_MEM_SIZE),
// so it is only safe while no stack comes within 8 bytes of its limit; that is the
// reference's assumption too, and its config matches ours.
//
// Radix follows the reference's rule: 16 at 256 cores, so the first stage is the
// 16 cores of a group and the second the 16 groups of the mesh.
#if NUM_CORES > 256
#define QWEN_LOG2_RADIX 5
#elif NUM_CORES > 64
#define QWEN_LOG2_RADIX 4
#elif NUM_CORES > 16
#define QWEN_LOG2_RADIX 3
#else
#define QWEN_LOG2_RADIX 2
#endif
#define QWEN_RADIX (1u << QWEN_LOG2_RADIX)

// Returns the counter address to the one core that closed the last stage, and 0
// to everyone else -- who are asleep until that core wakes them.
static uint32_t qwen_log_barrier(uint32_t step, uint32_t core_id) {
  uint32_t *bar = (uint32_t *)(((core_id / step) * step +
                                (step >> QWEN_LOG2_RADIX) - 1) *
                                   SEQ_MEM_SIZE +
                               4);
  uint32_t val = __atomic_fetch_add(bar, 1, __ATOMIC_RELAXED);
  if (val == (uint32_t)(QWEN_RADIX - 1)) {
    if (step == (uint32_t)NUM_CORES) return (uint32_t)bar;  // last stage
    __atomic_store_n(bar, 0, __ATOMIC_RELAXED);
    return qwen_log_barrier(step << QWEN_LOG2_RADIX, core_id);
  }
  mempool_wfi();
  return 0;
}

// Log barrier carrying the DMA handoff: the FIRST core to arrive absorbs 
// the outstanding transfer's wait while the rest are still finishing compute,
// so the DMA latency hides under the arrival skew instead of sitting between
// two rendezvous. Returns the barrier address to the ONE core that closes it,
// 0 to everyone else.
static uint32_t qwen_dma_log_barrier(uint32_t step, uint32_t core_id,
                                     uint32_t dma_pending) {
  uint32_t *bar = (uint32_t *)(((core_id / step) * step +
                                (step >> QWEN_LOG2_RADIX) - 1) *
                                   SEQ_MEM_SIZE +
                               4);
  uint32_t val = __atomic_fetch_add(bar, 1, __ATOMIC_RELAXED);
  if (val == (uint32_t)(QWEN_RADIX - 1)) {
    if (step == (uint32_t)NUM_CORES) return (uint32_t)bar;  // last stage
    __atomic_store_n(bar, 0, __ATOMIC_RELAXED);
    return qwen_dma_log_barrier(step << QWEN_LOG2_RADIX, core_id, dma_pending);
  }
  // First arrival on the first stage word (cores 0..RADIX-1 share it).
  if (dma_pending && val == 0 && bar == (uint32_t *)(uintptr_t)4) dma_wait();
  mempool_wfi();
  return 0;
}

static inline void qwen_barrier(uint32_t core_id) {
  uint32_t bar = qwen_log_barrier(QWEN_RADIX, core_id);
  if (bar) {
    __atomic_store_n((uint32_t *)bar, 0, __ATOMIC_RELAXED);
    __sync_synchronize();
    wake_up_all();
    mempool_wfi();  // clear our own trigger, as the plain barrier does
  }
}

// Launch the DMA that refills buffer slot `slot` with K tile `step` of `strip` of
// `stage`. Each K tile has its own sweep-aligned slot in L2 holding the KT x LDW
// block contiguously, so this is one DMA. Core 0 only; the caller has already
// barriered every reader off this slot.
static void qwen_refill(uint32_t slot, uint32_t stage, uint32_t strip, uint32_t step) {
  dma_memcpy_nonblocking(qwen_w[slot],
                         qwen_w_l2[stage] +
                             (strip * (uint32_t)QWEN_STEPS + step) * (uint32_t)QWEN_WSLOT,
                         (size_t)(QWEN_KT * QWEN_LDW) * GEMM_ELEM_BYTES);
}

// Prime the pipeline for one projection of one strip: tile 0 resident, tile 1 in
// flight. Separate from the loop so the very first prime can sit outside the
// measured region -- a fill into an empty L1 has nothing to overlap with.
static void qwen_prime(uint32_t stage, uint32_t strip, uint32_t cid) {
  if (cid != (uint32_t)QWEN_DMA_CORE) return;
  qwen_refill(0, stage, strip, 0);
  dma_wait();
  if ((uint32_t)QWEN_STEPS > 1u) qwen_refill(1, stage, strip, 1);
}

// ---- The continuous W stream ------------------------------------------------------
// Every K tile of every projection of every strip, in execution order:
//     seq = (strip * QWEN_STAGES + stage) * QWEN_STEPS + step.
// Tile `step` of any projection lives in slot `step & 1`, so with an EVEN tile count
// the slot of seq is seq & 1 and the refill of seq + 2 can run straight across a
// projection or strip boundary: the last two steps of one projection prefetch the next
// projection's tiles 0 and 1. Before, every projection start was a qwen_prime() --
// a whole tile's DMA with nothing to overlap it, 2 per strip. A strip's write-back
// moves into the barrier of its last step, after tile 0 of the next strip has landed
// and before tile 1 is launched, so the only strip cost left is the C copy itself.
// An odd tile count keeps the prime-per-projection path.
#define QWEN_STREAM (((QWEN_STEPS) % 2) == 0)
#define QWEN_SEQ_TOTAL ((uint32_t)(QWEN_NSTRIPS * QWEN_STAGES * QWEN_STEPS))
#if QWEN_STREAM
static void qwen_refill_seq(uint32_t seq) {
  const uint32_t step = seq % (uint32_t)QWEN_STEPS, proj = seq / (uint32_t)QWEN_STEPS;
  qwen_refill(step & 1u, proj % (uint32_t)QWEN_STAGES, proj / (uint32_t)QWEN_STAGES, step);
}
#endif
#if QWEN_NSTRIPS > 1 && QWEN_STREAM
// Copy both finished output strips to L2, one transfer at a time (the frontend holds
// one). The caller has fenced every core's vector stores and owns the DMA.
static void qwen_writeback_dma(uint32_t strip) {
  for (uint32_t s = 0; s < QWEN_STAGES; ++s) {
    dma_memcpy_nonblocking(qwen_out_l2[s] + strip * (uint32_t)(QWEN_B * QWEN_LDW), qwen_c[s],
                           (size_t)(QWEN_B * QWEN_LDW) * GEMM_ELEM_BYTES);
    dma_wait();
  }
}
#endif

#if QWEN_KSPLIT > 1
// Group CSR write, from the one writer per group, of the MSHR enable.
static inline void qwen_ksplit_mshr(uint32_t on) {
#if MSHR_RUNTIME_CFG
  if (mshr_cfg_is_group_writer())
    mshr_cfg_write(mshr_cfg_my_group(), mshr_cfg_peer_tile(), MSHR_CSR_ENABLE, on);
#else
  (void)on;
#endif
}

// Add the other K parts' partial sums into C: C[stage] += sum of qwen_cp over the patch. The
// QWEN_KSPLIT cores sharing the patch split it: by ROWS when they divide evenly (8x8 B=16:
// 4 of 8 rows each), else by COLUMNS (KS=1 has one row).
//
// All partners are in the same group (main.c puts the K part inside the group), so a
// group rendezvous is all the ordering this needs -- gbar_sync_drain waits for this core's
// vector stores to COMPLETE before arriving, so after it every partial is in L1.
//
// With the MSHR bypassed: every address here has exactly one reader, and a live MSHR would hold
// each of those loads for a merge partner that never comes (hold window up to 8191 cycles). Same
// drain / flip / drain protocol as the kernel's C reload (QWEN_CBYPASS_ENTER/EXIT), and the last
// rendezvous also keeps the next projection's first partial stores off qwen_cp until both cores
// of the pair have read it.
static void qwen_ksplit_reduce(uint32_t stage, uint32_t kpart, uint32_t m_start, uint32_t m_end,
                               uint32_t p_start, uint32_t p_end) {
#if FFN_KSPLIT_XGROUP
  // Partners in other groups: every rendezvous is global (fence first: it drains this core's
  // vector stores, which the scalar barrier atomic does not order).
  const uint32_t cid = mempool_get_core_id();
#define QWEN_KS_SYNC() do { __asm__ volatile("fence" ::: "memory"); qwen_barrier(cid); } while (0)
#else
  if (m_end == m_start) return;  // an inactive group skips it whole, rendezvous included
  const uint32_t gb = gbar_base(GBAR_PLOOP_STRUCT);
#define QWEN_KS_SYNC() gbar_sync_drain(gb)
#endif
  const uint32_t ks = (uint32_t)QWEN_KSPLIT;
  const uint32_t nrow = m_end - m_start, ncol = p_end - p_start;
  uint32_t r0 = m_start, r1 = m_end, c0 = p_start, c1 = p_end;
  if ((nrow % ks) == 0) {
    r0 = m_start + kpart * (nrow / ks);
    r1 = r0 + nrow / ks;
  } else {
    c0 = p_start + kpart * (ncol / ks);
    c1 = c0 + ncol / ks;
  }

  QWEN_KS_SYNC();  // every partial stored, the MSHR empty
  qwen_ksplit_mshr(0u);
  QWEN_KS_SYNC();  // the bypass is in force before anyone loads
#if QWEN_ACC32
  // fp32 partials: Y = fp16(C0 + C1 + C2 + ...), added in part order, rounded once. Part j's
  // sums are in the group-local chunks of the partner core with K part j: the cores of one
  // patch are rcg apart (main.c STEP 1), all in this group.
  (void)stage;
  const uint32_t n_rc = (uint32_t)QWEN_B / (uint32_t)KERNEL_SIZE;
  const uint32_t rcg = n_rc < (uint32_t)GEMM_DECODE_RC_PER_GROUP ? n_rc
                                                                 : (uint32_t)GEMM_DECODE_RC_PER_GROUP;
  const uint32_t core0 = mempool_get_core_id() - kpart * rcg;  // this patch's K part 0
  const uint32_t npiece = (p_end - p_start + QWEN_FLUSH_PIECE_E - 1u) / QWEN_FLUSH_PIECE_E;
  for (uint32_t r = r0; r < r1; ++r) {
    for (uint32_t p = c0; p < c1;) {
      // Never across a chunk: e32,m4 is at most one 64-float piece, 256 B.
      const uint32_t e = p - p_start, in = e % QWEN_FLUSH_PIECE_E;
      const uint32_t k = (r - m_start) * npiece + e / QWEN_FLUSH_PIECE_E;
      const uint32_t off = (k / (uint32_t)QWEN_C32_CPG) * (uint32_t)QWEN_SWEEP_F +
                           (k % (uint32_t)QWEN_C32_CPG) * (QWEN_C32_CHUNK_B / 4u) + in;
      const uint32_t left = QWEN_FLUSH_PIECE_E - in;
      size_t vl;
      asm volatile("vsetvli %0, %1, e32, m4, ta, ma"
                   : "=r"(vl) : "r"((c1 - p) < left ? (c1 - p) : left));
      asm volatile("vle32.v v24, (%0)" ::"r"((const float *)qwen_c32_of(core0) + off));
      for (uint32_t j = 1; j < ks; ++j) {
        asm volatile("vle32.v v28, (%0)" ::"r"((const float *)qwen_c32_of(core0 + j * rcg) + off));
        asm volatile("vfadd.vv v24, v24, v28");
      }
      asm volatile("vsetvli zero, %0, e16, m2, ta, ma" ::"r"(vl));
      asm volatile("vfncvt.f.f.w v0, v24");
      asm volatile("vse16.v v0, (%0)" ::"r"(QWEN_Y + r * (uint32_t)QWEN_LDW + p));
      p += (uint32_t)vl;
    }
  }
#else
  elem_t *c = qwen_c[stage];
  for (uint32_t r = r0; r < r1; ++r) {
    for (uint32_t p = c0; p < c1;) {
      // e16,m2 caps a vector at 64 elements: the kernel's own KS=8 load, 128 B, two bursts.
      size_t vl;
      asm volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(vl) : "r"(c1 - p));
      const uint32_t off = r * (uint32_t)QWEN_LDW + p;
      asm volatile("vle16.v v24, (%0)" ::"r"(c + off));
      for (uint32_t j = 0; j + 1u < ks; ++j) {
        asm volatile("vle16.v v28, (%0)" ::"r"(qwen_cp[j] + off));
        asm volatile("vfadd.vv v24, v24, v28");
      }
      asm volatile("vse16.v v24, (%0)" ::"r"(c + off));
      p += (uint32_t)vl;
    }
  }
#endif
  QWEN_KS_SYNC();  // every sum stored; nobody still reads qwen_cp
  qwen_ksplit_mshr(1u);
  QWEN_KS_SYNC();  // merging back on before the next projection issues into it
#undef QWEN_KS_SYNC
}
#define QWEN_KPART_PARAM , uint32_t kpart
#define QWEN_KPART_ARG , kpart
#else
#define QWEN_KPART_PARAM
#define QWEN_KPART_ARG
#endif

// The kernel for this build's KERNEL_SIZE, on n K rows of W (row stride QWEN_LDW) and the
// matching n columns of X (row stride QWEN_LDX). zz: bit0 walk the column blocks backwards,
// bit1 the first block arrives in the accumulators, bit2 leave the last one there, bit3 this
// is the part's last call and there is no K split, so the result goes to Y (fp32 C only).
static inline void qwen_kernel(elem_t *c, const elem_t *a, const elem_t *w, uint32_t m_start,
                               uint32_t m_end, uint32_t n, uint32_t p_start, uint32_t p_end,
                               uint32_t accum, uint32_t zz) {
#if KERNEL_SIZE == 1
  matmul_1xVL(c, a, w, m_start, m_end, n, QWEN_LDW, p_start, p_end, QWEN_LDX, accum, zz, QWEN_Y);
#elif KERNEL_SIZE == 2
  matmul_2xVL(c, a, w, m_start, m_end, n, QWEN_LDW, p_start, p_end, QWEN_LDX, accum, zz, QWEN_Y);
#elif KERNEL_SIZE == 4
  matmul_4xVL(c, a, w, m_start, m_end, n, QWEN_LDW, p_start, p_end, QWEN_LDX, accum, zz, QWEN_Y);
#else
  matmul_8xVL(c, a, w, m_start, m_end, n, QWEN_LDW, p_start, p_end, QWEN_LDX, accum, zz, QWEN_Y);
#endif
}

#if FFN_PRIME_SPLIT > 1
_Static_assert(((FFN_SUB_TILE_ROWS) * (QWEN_LDW) * GEMM_ELEM_BYTES) % 1024u == 0,
               "A piece of the first tile must start on the 1 KiB L2 interleave, or the DMA "
               "backend rejects it");
// Piece s of tile 0 into its place in slot 0. Tile 0 is stored piece-major (qwen_layout.h,
// FFN_W_ROW), so a piece is one contiguous DMA.
static void ffn_refill_piece(uint32_t s) {
  const uint32_t off = s * (uint32_t)(FFN_SUB_TILE_ROWS * QWEN_LDW);
  dma_memcpy_nonblocking(qwen_w[0] + off, qwen_w_l2[QWEN_DOWN] + off,
                         (size_t)(FFN_SUB_TILE_ROWS * QWEN_LDW) * GEMM_ELEM_BYTES);
}
// The DMA queue while the pieces run: pieces 0 .. S-1 of tile 0, then tiles 1, 2, ... (one
// strip, one stage). Item i computes on DMA i, and after it DMA i + 2 is launched -- the same
// one-ahead pipeline as the tiles: tile t + 2 reuses the slot tile t has just left.
static void ffn_refill_item(uint32_t j) {
  if (j < (uint32_t)FFN_PRIME_SPLIT) {
    ffn_refill_piece(j);
  } else {
    const uint32_t t = j - (uint32_t)FFN_PRIME_SPLIT + 1u;
    qwen_refill(t & 1u, QWEN_DOWN, 0, t);
  }
}
#endif

#if QWEN_SWIGLU
// The first DMA of the pipeline (tile 0, or its piece 0) and, once it has landed, the second
// (tile 1, or piece 1). Core QWEN_DMA_CORE only.
static void ffn_prime_first(void) {
#if FFN_PRIME_SPLIT > 1
  ffn_refill_piece(0);
#else
  qwen_refill(0, QWEN_DOWN, 0, 0);
#endif
}
static void ffn_prime_second(void) {
#if FFN_PRIME_SPLIT > 1
  ffn_refill_item(1u);
#else
  if ((uint32_t)QWEN_STEPS > 1u) qwen_refill(1, QWEN_DOWN, 0, 1);
#endif
}
#endif

// One projection of one strip: C[stage] = X . W[stage][strip], reduced over all K
// tiles. C and the W buffers both have row stride QWEN_LDW (strip width + pad).
// Under the K split, K part `kpart` of every tile goes to this core; part 0 accumulates
// in C, part j in qwen_cp[j-1], and qwen_ksplit_reduce adds them after the last tile.
//
// Each iteration computes on the resident slot, then -- once every reader has left
// it -- waits for the in-flight tile and launches the next into the slot just
// freed. Exactly one transfer is outstanding: the global DMA frontend has one
// {src,dst,len} register set, so a second launch would overwrite the first.
static void qwen_project(uint32_t stage, uint32_t strip, uint32_t cid, const elem_t *x,
                         uint32_t m_start, uint32_t m_end,
                         uint32_t p_start, uint32_t p_end QWEN_KPART_PARAM) {
#if QWEN_ACC32
  (void)stage;
  elem_t *c = qwen_c32_of(cid);  // this core's fp32 chunks, whatever its K part
#elif QWEN_KSPLIT > 1
  elem_t *c = kpart ? qwen_cp[kpart - 1u] : qwen_c[stage];
#else
  elem_t *c = qwen_c[stage];
#endif

  // ---- Tile 0 in pieces (FFN_PRIME_SPLIT > 1) -------------------------------------------
  // Piece s: this core's rows s * FFN_SUB_ROWS .. of its K part, stored at L1 row
  // s * FFN_SUB_TILE_ROWS + kpart * FFN_SUB_ROWS (piece-major tile 0). Each piece ends on the
  // pipeline barrier, whose closer waits for the next piece and launches the one after.
  uint32_t first_step = 0;
#if FFN_PRIME_SPLIT > 1
  {
    const uint32_t items = (uint32_t)(FFN_PRIME_SPLIT + QWEN_STEPS - 1);
#if QWEN_KSPLIT > 1
    const uint32_t kp = kpart;
#else
    const uint32_t kp = 0;
#endif
    for (uint32_t s = 0; s < (uint32_t)FFN_PRIME_SPLIT; ++s) {
      const elem_t *a = x + kp * (uint32_t)QWEN_KT_CORE + s * (uint32_t)FFN_SUB_ROWS;
      const elem_t *w = qwen_w[0] + (s * (uint32_t)FFN_SUB_TILE_ROWS + kp * (uint32_t)FFN_SUB_ROWS) *
                                        (uint32_t)QWEN_LDW;
      const uint32_t last = (s + 1u == items);
      qwen_kernel(c, a, w, m_start, m_end, FFN_SUB_ROWS, p_start, p_end, s != 0u,
                  (s & 1u) | ((s != 0u) ? 2u : 0u) | (last ? 0u : 4u) |
                      ((last && QWEN_KSPLIT == 1) ? 8u : 0u));
      const uint32_t pending = (s + 1u < items), launch = (s + 2u < items);
      uint32_t bar = qwen_dma_log_barrier(QWEN_RADIX, cid, pending);
      if (bar) {
        qwen_tile_ts[s] = mempool_get_timer();
        if (pending) dma_wait();
        if (launch) ffn_refill_item(s + 2u);
        __atomic_store_n((uint32_t *)bar, 0, __ATOMIC_RELAXED);
        __sync_synchronize();
        wake_up_all();
        mempool_wfi();
      }
    }
    first_step = 1;
  }
#endif

  for (uint32_t step = first_step; step < (uint32_t)QWEN_STEPS; ++step) {
    const uint32_t slot = step & 1u;
    // The call's index in the whole sequence, which the zig-zag parity follows: tile 0 is
    // FFN_PRIME_SPLIT calls when it comes in pieces.
    const uint32_t call = step + (uint32_t)FFN_PRIME_SPLIT - 1u;

    // An ordinary L1-resident GEMM: reduction length KT, A the K-slice of X at
    // column step*KT (so lda = K, not KT), adding into C after the first tile.
#if QWEN_KSPLIT > 1
    const elem_t *a = x + (uint32_t)step * QWEN_KT + kpart * (uint32_t)QWEN_KT_CORE;
    const elem_t *w = qwen_w[slot] + kpart * (uint32_t)(QWEN_KT_CORE * QWEN_LDW);
#define QWEN_W_TILE w
#else
    const elem_t *a = x + (uint32_t)step * QWEN_KT;
#define QWEN_W_TILE qwen_w[slot]
#endif
    const uint32_t accum = (call != 0);
    // Alternate the column-block direction per call so the block one call ends on is the one
    // the next starts on: its accumulators stay in registers and neither the store nor the
    // reload happens (fp16 C only). Not across projections -- the last call stores everything.
    qwen_kernel(c, a, QWEN_W_TILE, m_start, m_end, QWEN_KT_CORE, p_start, p_end, accum,
                (call & 1u) | ((call != 0u) ? 2u : 0u) |
                    ((step + 1u < (uint32_t)QWEN_STEPS) ? 4u : 0u) |
                    ((QWEN_KSPLIT == 1 && step + 1u == (uint32_t)QWEN_STEPS) ? 8u : 0u));

#if QWEN_STREAM
    const uint32_t seq = (strip * (uint32_t)QWEN_STAGES + stage) * (uint32_t)QWEN_STEPS + step;
    const uint32_t pending = (seq + 1u < QWEN_SEQ_TOTAL);
    const uint32_t launch = (seq + 2u < QWEN_SEQ_TOTAL);
    // The strip is finished after the last step of its last stage.
    const uint32_t wb = (QWEN_NSTRIPS > 1) && (stage + 1u == (uint32_t)QWEN_STAGES) &&
                        (step + 1u == (uint32_t)QWEN_STEPS);
    // The kernel ends on vector stores and the barrier is a scalar atomic: drain them
    // (a plain fence covers the Spatz VLSU) before the DMA reads C.
    if (wb) __asm__ volatile("fence" ::: "memory");
#else
    const uint32_t pending = (step + 1u < (uint32_t)QWEN_STEPS);
    const uint32_t launch = (step + 2u < (uint32_t)QWEN_STEPS);
    const uint32_t wb = 0;
#endif
    uint32_t bar = qwen_dma_log_barrier(QWEN_RADIX, cid, pending);
    if (bar) {
      qwen_tile_ts[(strip * (uint32_t)QWEN_STAGES + stage) * (uint32_t)QWEN_STEPS + call] =
          mempool_get_timer();
      // Guarantee, not the optimistic early wait: the frontend has ONE
      // {src,dst,len} register set, so the previous transfer must be complete
      // before another is programmed. A no-op when the first arriver already waited.
      if (pending) dma_wait();
#if QWEN_STREAM
#if QWEN_NSTRIPS > 1
      if (wb) qwen_writeback_dma(strip);
#endif
      if (launch) qwen_refill_seq(seq + 2u);
#else
      (void)wb;
      if (launch) qwen_refill(slot, stage, strip, step + 2u);
#endif
      __atomic_store_n((uint32_t *)bar, 0, __ATOMIC_RELAXED);
      __sync_synchronize();
      wake_up_all();
      mempool_wfi();  // clear our own trigger, as the plain barrier does
    }
  }
#undef QWEN_W_TILE
#if QWEN_KSPLIT > 1
  qwen_ksplit_reduce(stage, kpart, m_start, m_end, p_start, p_end);
#endif
}

#if QWEN_NSTRIPS > 1 && !QWEN_STREAM
// Move a finished strip of both outputs to L2 so the next strip can reuse the
// buffers. The kernel ends on vector stores and the barrier is a scalar atomic, so
// every core first FENCEs (a plain fence drains the Spatz VLSU too) -- otherwise the
// DMA could read a C block whose last stores are still in flight. The DMA core then
// copies both stages, one transfer at a time (the frontend holds one). The caller's
// next prime + barrier keeps everyone off C until this is done; after the LAST strip
// nothing follows, so it closes with its own barrier to keep the timer honest.
static void qwen_writeback(uint32_t strip, uint32_t cid, uint32_t last) {
  __asm__ volatile("fence" ::: "memory");
  qwen_barrier(cid);
  if (cid == (uint32_t)QWEN_DMA_CORE) {
    for (uint32_t s = 0; s < QWEN_STAGES; ++s) {
      dma_memcpy_nonblocking(qwen_out_l2[s] + strip * (uint32_t)(QWEN_B * QWEN_LDW), qwen_c[s],
                             (size_t)(QWEN_B * QWEN_LDW) * GEMM_ELEM_BYTES);
      dma_wait();
    }
  }
  if (last) qwen_barrier(cid);
}
#endif

//==============================================================================
// main
//==============================================================================

int main(void) {
  const uint32_t num_cores = mempool_get_core_count();
  const uint32_t cores_per_group = num_cores / NUM_GROUPS;
  const uint32_t cid = mempool_get_core_id();
  const uint32_t core_gid = cid % cores_per_group;
  const uint32_t gid = cid / cores_per_group;
  const uint32_t active_groups = NUM_GROUPS / ACTIVE_GROUP_DIV;
  const uint32_t active_cores = cores_per_group * active_groups;
  const uint32_t is_core_active = cid < active_cores;
  const uint32_t kernel_size = KERNEL_SIZE;

  uint32_t m_start, m_end, p_start, p_end;
  // Per-group sharing degree of each MSHR request class, as the SPLIT ABOVE
  // actually produces it. Cross-checked against the MSHR's compile-time
  // derivation below; see the [MSHR] report.
  uint32_t share_burst = 1, share_single = 1, pblocks = 1;
#if QWEN_KSPLIT > 1
  uint32_t kpart = 0;  // which K part of every tile this core reduces over
#endif

  mempool_barrier_init(cid);
  // Every stage counter this core can host, cleared before anyone counts on it.
  *(volatile uint32_t *)(cid * SEQ_MEM_SIZE + 4) = 0u;

  //--------------------------------------------------------------------------
  // STEP 1: work split. Verbatim from sp-fmatmul-opt-burst-merge-fp16, because
  // the same gemm_config.h policy derives the MSHR's expected sharing degree --
  // the split the kernel runs and the split the MSHR is tuned for must be one
  // source or the merge targets are unreachable.
  //--------------------------------------------------------------------------
#if MATMUL_DECODE_SPLIT
  {
    // K split: ks cores share each (row chunk, column block) patch; 1 = off.
    const uint32_t ks = (uint32_t)QWEN_KSPLIT;
    const uint32_t n_row_chunks = (uint32_t)QWEN_B / kernel_size;
    const uint32_t n_p_blocks = active_cores / (n_row_chunks * ks);
    if (n_row_chunks == 0u || ((uint32_t)QWEN_B % kernel_size) != 0u) return -6;
    if (n_p_blocks == 0u || (active_cores % (n_row_chunks * ks)) != 0u) return -7;
    if (((uint32_t)QWEN_PT % n_p_blocks) != 0u) return -5;
    // Each group takes an rcg x (cores_per_group / rcg) patch of (row chunks x column
    // blocks), rcg = min(n_row_chunks, GEMM_DECODE_RC_PER_GROUP). Inside the group the
    // row chunk varies fastest, so the cores sharing a column block are one run of
    // rcg adjacent tiles (one tile row at rcg = 4: one burst slice of the split MSHR)
    // and the cores sharing a row chunk are every rcg-th tile (one tile column: one
    // single slice). Across groups, gid % n_bands picks the band of row chunks and
    // gid / n_bands the run of column blocks. With rcg = n_row_chunks (n_bands = 1)
    // this is exactly the original row_chunk = cid % n, p_block = cid / n.
    //
    // Under the K split the K part varies next, after the row chunk: the ks x rcg cores of
    // one column block are one run of adjacent tiles (at rcg = 2, ks = 2: one tile row), so
    // the W sharers -- same block, same K part, the rcg row chunks -- are still adjacent tiles
    // of one burst slice, and the X sharers -- same row chunk, same K part -- are every
    // (rcg * ks)-th tile: one tile column, one single slice. The K parts of a pair are
    // in the same group, which is what lets qwen_ksplit_reduce order them with a group
    // rendezvous.
    const uint32_t rcg = (n_row_chunks < (uint32_t)GEMM_DECODE_RC_PER_GROUP)
                             ? n_row_chunks : (uint32_t)GEMM_DECODE_RC_PER_GROUP;
    if (rcg == 0u || (cores_per_group % (rcg * ks)) != 0u || (n_row_chunks % rcg) != 0u)
      return -6;
    const uint32_t n_bands = n_row_chunks / rcg;
#if FFN_KSPLIT_XGROUP
    // K split ACROSS groups (ffn_kgroup=1): group g takes K part g % ks, and the groups of one
    // part run the plain decode split among themselves. A group then holds rcg row chunks x
    // cores_per_group / rcg column blocks of ONE K part, so its X (H) sharers are
    // cores_per_group / rcg -- 4 at rcg = 4, where the in-group split leaves 16 / (rcg * ks):
    // 1 at B=32, 2 at B=64, below the MSHR's merge threshold, so every core fetched every H
    // word over the NoC (8x8 B=32/64 plateaued at ~83%). The K-split partners of a patch are
    // the same core of ks neighbouring groups; qwen_ksplit_reduce meets them with a global
    // barrier instead of the group one.
    const uint32_t gid_p = gid / ks;  // this group's index among the groups of its K part
    const uint32_t pb_per_group = cores_per_group / rcg;
    if (((active_groups / ks) % n_bands) != 0u) return -10;
    const uint32_t row_chunk = (gid_p % n_bands) * rcg + core_gid % rcg;
    const uint32_t p_block = (gid_p / n_bands) * pb_per_group + core_gid / rcg;
    kpart = gid % ks;
#else
    const uint32_t pb_per_group = cores_per_group / (rcg * ks);
    const uint32_t row_chunk = (gid % n_bands) * rcg + core_gid % rcg;
    const uint32_t p_block = (gid / n_bands) * pb_per_group + core_gid / (rcg * ks);
#if QWEN_KSPLIT > 1
    kpart = (core_gid / rcg) % ks;
#endif
#endif
    // Split ONE STRIP (the padded width when there is one strip), so every span is
    // burst-friendly; each strip is split identically. The pad columns hold zeros
    // and their results are never read.
    const uint32_t p_span = (uint32_t)QWEN_PT / n_p_blocks;
    // qwen_ksplit_reduce splits a patch between its ks cores by rows, else by columns.
    if ((kernel_size % ks) != 0u && (p_span % ks) != 0u) return -8;
    m_start = row_chunk * kernel_size;
    m_end = m_start + kernel_size;
    p_start = p_block * p_span;
    p_end = p_start + p_span;
    // How many cores of ONE GROUP actually issue each address, per request class.
    // W (burst): the cores sharing a p_block and K part, i.e. the group's rcg row chunks.
    // X (single): the cores sharing a row chunk and K part, i.e. the group's pb_per_group
    // blocks.
    share_burst = rcg;
    share_single = pb_per_group;
    pblocks = n_p_blocks;
  }
#else
  {
    const uint32_t dim_group = (uint32_t)QWEN_B / active_groups;
    const uint32_t split_m_count = dim_group / kernel_size;
    if ((dim_group % kernel_size) != 0u || split_m_count == 0u) return -6;
    if (split_m_count < cores_per_group) {
      const uint32_t split_p_count = cores_per_group / split_m_count;
      if (((uint32_t)QWEN_PT % split_p_count) != 0u) return -5;
      p_start = (uint32_t)QWEN_PT / split_p_count * (core_gid % split_p_count);
      p_end = (uint32_t)QWEN_PT / split_p_count * ((core_gid % split_p_count) + 1);
      m_start = dim_group * gid + kernel_size * (core_gid / split_p_count);
      m_end = m_start + kernel_size;
      share_burst = (split_m_count < cores_per_group) ? split_m_count : cores_per_group;
      share_single = cores_per_group / share_burst;
      pblocks = split_p_count;
    } else {
      p_start = 0;
      p_end = (uint32_t)QWEN_PT;
      m_start = dim_group * gid + (dim_group / cores_per_group) * core_gid;
      m_end = m_start + (dim_group / cores_per_group);
      share_burst = cores_per_group;
      share_single = 1;
      pblocks = 1;
    }
  }
#endif

  // ACTIVE_GROUP_DIV shrinks the active set to whole groups. Those cores get an
  // EMPTY range rather than skipping the projection: the pipeline synchronises with
  // mempool_barrier(num_cores), so a core that walked past those barriers instead of
  // arriving at them would hang every core that did. With an empty range the kernel's
  // p and m loops simply do not execute, and the per-group rendezvous inside the
  // kernel is untouched because an inactive GROUP is inactive in full.
  if (!is_core_active) {
    m_start = m_end = 0;
    p_start = p_end = 0;
  }
#if QWEN_ACC32
  // The fp32 chunks were sized at compile time from the same split (QWEN_C32_SPAN).
  if ((m_end - m_start) * ((p_end - p_start + 63u) / 64u) > (uint32_t)QWEN_C32_CH) return -9;
#endif

  // Every core states the work its own range implies; core 0 folds these into the
  // per-group assignment the dashboard compares measured FMAC progress against.
  // Every projection and every repetition are included, and the padded width is
  // used because the padding columns are FMACs the machine really issues.
  // Under the K split a core reduces over 1/QWEN_KSPLIT of K.
  qwen_fmac_core[cid] = (p_end - p_start) * (m_end - m_start) * (uint32_t)QWEN_NSTRIPS *
                        (uint32_t)(QWEN_K / QWEN_KSPLIT) * (uint32_t)QWEN_STAGES * (uint32_t)QWEN_REPEATS;

  //--------------------------------------------------------------------------
  // STEP 2: operands.
  //--------------------------------------------------------------------------
#if QWEN_FILL
  qwen_fill_operands(cid, num_cores);
  mempool_barrier(num_cores);  // every core has written its share of the operands
#endif
  if (cid == (uint32_t)QWEN_DMA_CORE) {
#if QWEN_SWIGLU
    // Stage G and U in L1 (FFN_G_L1 / FFN_U_L1): both in W slot 1 when they fit, so the
    // first W tile can stream into slot 0 under the prologue; else one per slot, and the
    // first tile waits for the prologue to finish. In a fused FFN they are already in L1, so
    // this is not timed. The single-descriptor frontend takes one transfer at a time; U is
    // waited for before the region starts.
    dma_memcpy_nonblocking(FFN_G_L1, qwen_gu_l2[0], (size_t)FFN_GU_ELEMS * GEMM_ELEM_BYTES);
    dma_wait();
    dma_memcpy_nonblocking(FFN_U_L1, qwen_gu_l2[1], (size_t)FFN_GU_ELEMS * GEMM_ELEM_BYTES);
#else
    for (uint32_t r = 0; r < (uint32_t)QWEN_X_REPLICAS; ++r) {
      dma_memcpy_nonblocking(qwen_x + r * (uint32_t)QWEN_X_STRIDE_E, qwen_x_l2,
                            (size_t)(QWEN_B * QWEN_LDX) * GEMM_ELEM_BYTES);
      if ((r % 2 == 1u) || (r == (uint32_t)QWEN_X_REPLICAS - 1)) dma_wait();
    }
#endif
  }
#if GBAR_PLOOP
  // Independent of the copy above, so it shares that copy's rendezvous.
  if (is_core_active && core_gid == QWEN_GROUP_HELPER) {
    const uint32_t gmask =
        (cores_per_group >= 32u) ? 0xFFFFFFFFu : ((1u << cores_per_group) - 1u);
    gbar_setup(GBAR_PLOOP_STRUCT, cores_per_group, gmask);
  }
#endif
  // No rendezvous here: the barrier after qwen_prime below covers both the copy
  // and the setup, and nothing between reads either.

  // Every core reads the copy nearest its own group.
  const elem_t *const x_use =
      qwen_x + (uint32_t)QWEN_X_REPLICA_OF(gid) * (uint32_t)QWEN_X_STRIDE_E;

  //--------------------------------------------------------------------------
  // STEP 3: I$ warm-up, then the MSHR. In that order: the MSHR ships disabled out
  // of reset, so the fill, the DMA and the warm-up all bypass it and cannot leave
  // a line in its response cache before the measured region.
  //--------------------------------------------------------------------------
  // Launch both slots and do NOT wait here: the two fetches then overlap the
  // warm-up and the MSHR programming below, and one dma_wait before the timed
  // region covers them. The warm-up reads qwen_w[0] while it is still filling --
  // harmless, its results are discarded and no address derives from them.
#if !QWEN_SWIGLU
  if (cid == (uint32_t)QWEN_DMA_CORE) {
    qwen_refill(0, QWEN_DOWN, 0, 0);
    if ((uint32_t)QWEN_STEPS > 1u) qwen_refill(1, QWEN_DOWN, 0, 1);
  }
#else
  // This core's run of H, and where its G and U sit in the staged images.
  const uint32_t sw_on = cid < FFN_SW_CORES;             // this core computes a run of H
  const uint32_t sw_e0 = sw_on ? cid * FFN_SW_CHUNK : 0u;
  const uint32_t sw_b = sw_e0 / (uint32_t)QWEN_K, sw_k = sw_e0 % (uint32_t)QWEN_K;
  const uint32_t sw_gu = FFN_GU_AT(sw_b, sw_k);
  const uint32_t sw_h = sw_b * (uint32_t)QWEN_LDX + sw_k;  // where that run goes in H
#endif

#if ICACHE_WARMUP
  {
    const uint32_t warm = (QWEN_KT < 6u) ? (uint32_t)QWEN_KT : 6u;
#if QWEN_ACC32
    qwen_kernel(qwen_c32_of(cid), x_use, qwen_w[0], m_start, m_end, warm, p_start, p_end, 0, 0u);
#else
    qwen_kernel(qwen_c[0], x_use, qwen_w[0], m_start, m_end, warm, p_start, p_end, 0, 0u);
#endif
#if QWEN_SWIGLU
    // The prologue's code too, on this core's own run (overwritten by the real one).
    if (sw_on)
      swiglu_f16(FFN_G_L1 + sw_gu, FFN_U_L1 + sw_gu, qwen_x + sw_h,
                 FFN_SW_CHUNK < 64u ? FFN_SW_CHUNK : 64u, 1u, 0u);
#endif
  }
#endif

#if MSHR_RUNTIME_CFG
  // Configure, but report later: a printf here is simulated time before the
  // measured region, and on RTL that is the slowest part of the whole run.
  mshr_cfg_t cfg = MSHR_CFG_DERIVED_INIT;
  uint32_t mshr_status = 0, mshr_split_bad = 0, mshr_align_bad = 0;
  {
    // The subscriber targets are derived at compile time from the shape; the split
    // that decides how many cores really issue each address is computed above. If
    // they disagree, every mergeable request waits for a cohort that never arrives
    // and times out -- which looks like too long a hold window and is not fixed by
    // shortening it. Both come from gemm_config.h, and this proves it every run.
#if FFN_KSPLIT_XGROUP
    // mshr_cfg.h derives the X (H) sharers as if the K split were inside a group and divides
    // them by it; here it is not, so the single class is retuned below from the real
    // share_single with the header's own rules (<= 2 sharers bypass, clamp to the merge cap,
    // fp16 cache reuse 2x). The burst class and the column-block count are checked as usual.
    mshr_split_bad = (share_burst != (uint32_t)MSHR_D_SPLIT_M) ||
                     (pblocks != (uint32_t)MSHR_D_PGAP);
    {
      const uint32_t subs = share_single <= 2u ? 1u
                          : (share_single > (uint32_t)MSHR_MERGE_CAP ? (uint32_t)MSHR_MERGE_CAP
                                                                    : share_single);
      cfg.hold_subs_single = subs;
      cfg.hold_window_single = share_single < 2u ? 0u : (uint32_t)MSHR_CFG_HOLD_WINDOW_SINGLE;
      cfg.cache_reuse_target = MSHR_CFG_CACHE_REUSE_TARGET ? (uint32_t)MSHR_CFG_CACHE_REUSE_TARGET
                             : (subs < 2u || 2u * subs > 2u * (uint32_t)MSHR_MERGE_REQS) ? 0u
                             : 2u * subs;
    }
#else
    mshr_split_bad = mshr_cfg_check_splits(share_burst, share_single, pblocks) != 0;
#endif

    if (core_gid == QWEN_GROUP_HELPER) {
      // script/gen_hash.c chose these on the host from the shape and the replica
      // layout. They are exact only while every operand stays aligned to a mesh
      // sweep, which is what keeps the link addresses out of the hash.
      mshr_align_bad =
          (((uintptr_t)qwen_x | (uintptr_t)qwen_w[0]) & (QWEN_MESH_SWEEP - 1)) != 0u;
      cfg.bank_shift_single = qwen_hash_sel[gid][0];
      cfg.bank_shift_burst = qwen_hash_sel[gid][1];
      cfg.bank_burst_bits = qwen_hash_sel[gid][2];
      mshr_status = mshr_cfg_apply_group(&cfg);
#if QWEN_SWIGLU
      // Configured, but held off until H is complete: every prologue load has one reader,
      // and a live MSHR would hold each for a merge partner that never comes.
      mshr_cfg_write(mshr_cfg_my_group(), mshr_cfg_peer_tile(), MSHR_CSR_ENABLE, 0);
      __asm__ volatile("fence" ::: "memory");
#endif
    }
  }
#endif

  //--------------------------------------------------------------------------
  // STEP 4: the measured region.
  //--------------------------------------------------------------------------
  // Per-projection boundaries, printed after the region so timing is undisturbed:
  // they answer whether the second projection costs the same as the first.

  if (cid == (uint32_t)QWEN_DMA_CORE) {
    dma_wait();
  }
  mempool_barrier(num_cores);
  // Cycles per stage over the last pass, summed over its strips (includes the strip
  // write-back; without the continuous stream, also the next strip's prime).
  uint32_t stage_cyc[QWEN_STAGES] = {0};

  const uint32_t t0 = mempool_get_timer();
  mempool_start_benchmark();
  uint32_t t_swiglu = 0, t_prime = 0;  // core 0's view, printed after the region
#if QWEN_SWIGLU
  // ---- Prologue: H = SiLU(G) * U into every H replica, then prime the W stream. ---------
#if FFN_GU_EARLY
  // Slot 0 is free: the first DMA of the W stream runs under the prologue.
  if (cid == (uint32_t)QWEN_DMA_CORE) ffn_prime_first();
#endif
  if (sw_on) swiglu_f16(FFN_G_L1 + sw_gu, FFN_U_L1 + sw_gu, qwen_x + sw_h, FFN_SW_CHUNK,
             (uint32_t)QWEN_X_REPLICAS, (uint32_t)QWEN_X_STRIDE_E);
  __asm__ volatile("fence" ::: "memory");  // H stored before anyone reads it
  // The pipeline's log barrier, not mempool_barrier: that one's single counter serialises
  // every core's atomic (measured ~14k cycles at 8x8, ~3.8k at 4x4, whatever the batch).
  qwen_barrier(cid);
  if (cid == 0) t_swiglu = mempool_get_timer() - t0;
  // qwen_project's entry state: the first DMA landed, the second in flight (tile 0 and 1, or
  // pieces 0 and 1 of tile 0). In a fused FFN these would stream behind the up projection.
  if (cid == (uint32_t)QWEN_DMA_CORE) {
#if !FFN_GU_EARLY
    ffn_prime_first();  // G/U sat in slot 0: only now is it free
#endif
    dma_wait();
    ffn_prime_second();
  }
#if MSHR_RUNTIME_CFG
  if (core_gid == QWEN_GROUP_HELPER)
    mshr_cfg_write(mshr_cfg_my_group(), mshr_cfg_peer_tile(), MSHR_CSR_ENABLE, 1);
  __asm__ volatile("fence" ::: "memory");
#endif
  qwen_barrier(cid);
  if (cid == 0) t_prime = mempool_get_timer() - t0 - t_swiglu;
#endif
  uint32_t t_pass = t0;
  for (uint32_t rep = 0; rep < (uint32_t)QWEN_REPEATS; ++rep) {
    stage_cyc[QWEN_DOWN] = 0;
    t_pass = mempool_get_timer();
    uint32_t ts = (cid == 0) ? mempool_get_timer() : 0;
    for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip) {
      qwen_project(QWEN_DOWN, strip, cid, x_use, m_start, m_end, p_start, p_end QWEN_KPART_ARG);
      if (cid == 0) {
        const uint32_t t = mempool_get_timer();
        stage_cyc[QWEN_DOWN] += t - ts;
        ts = t;
      }
#if QWEN_STREAM
      // The stream already wrote this strip back and prefetched the next one; only a
      // new repetition restarts it from strip 0.
      if (strip + 1u == (uint32_t)QWEN_NSTRIPS && rep + 1u < (uint32_t)QWEN_REPEATS) {
        qwen_prime(QWEN_DOWN, 0, cid);
        qwen_barrier(cid);
      }
#else
      const uint32_t last =
          (rep + 1u == (uint32_t)QWEN_REPEATS) && (strip + 1u == (uint32_t)QWEN_NSTRIPS);
#if QWEN_NSTRIPS > 1
      qwen_writeback(strip, cid, last);
#endif
      if (!last) {
        qwen_prime(QWEN_DOWN, (strip + 1u) % (uint32_t)QWEN_NSTRIPS, cid);
        qwen_barrier(cid);
      }
#endif
    }
  }
  mempool_stop_benchmark();
  const uint32_t timer = (mempool_get_timer() - t0) / (uint32_t)QWEN_REPEATS;

#if MSHR_RUNTIME_CFG
  // Bypass the MSHR for everything after the measured region -- in EVERY build, not
  // just a checking one. Both epilogues are a single core walking memory with scalar
  // loads that no other core shares: the verify reads the output, and a perf build's
  // deferred report reads all NUM_CORES qwen_fmac_core slots plus the two [SPOT]
  // words. Each such entry gets one subscriber against a target of 16 and waits out
  // the full hold window, so 258 of them at 256 cores camp their banks and every
  // request hashing there retries -- measured as 258 resp_hold_timeouts and 910k
  // bank-full retries in group 0 alone. It costs no measured time, but it lands in
  // the same cumulative counters and makes a correctly tuned MSHR look mistuned.
  if (core_gid == QWEN_GROUP_HELPER)
    mshr_cfg_write(mshr_cfg_my_group(), mshr_cfg_peer_tile(), MSHR_CSR_ENABLE, 0);
  // Every group has to be disabled before the verify below starts issuing remote
  // loads into it, or the loads land in the MSHRs this is meant to spare.
  mempool_barrier(num_cores);
#endif

  //--------------------------------------------------------------------------
  // The startup report, deferred to here so nothing prints before the measured
  // region: on RTL a printf costs far more wall clock than the kernel does.
  //--------------------------------------------------------------------------
  if (cid == 0) {
    printf("[QWEN] B=%u K=%u P=%u ldp=%u (pad %u%%o) cols/core=%u kt=%u steps=%u "
           "ks=%u decode=%u check=%u xrep=%u pt=%u strips=%u wpad=%u hpad=%u\n",
           (unsigned)QWEN_B, (unsigned)QWEN_K, (unsigned)QWEN_P, (unsigned)QWEN_LDP,
           (unsigned)(1000u * (QWEN_LDP - QWEN_P) / QWEN_P),
           (unsigned)(p_end - p_start), (unsigned)QWEN_KT, (unsigned)QWEN_STEPS,
           (unsigned)kernel_size, (unsigned)MATMUL_DECODE_SPLIT, (unsigned)QWEN_CHECK,
           (unsigned)QWEN_X_REPLICAS, (unsigned)QWEN_PT, (unsigned)QWEN_NSTRIPS,
           (unsigned)QWEN_WPAD, (unsigned)FFN_HPAD);
#if QWEN_KSPLIT > 1
    printf("[QWEN] ksplit=%u kt/core=%u (cores per output patch, K rows per core per tile)\n",
           (unsigned)QWEN_KSPLIT, (unsigned)QWEN_KT_CORE);
#endif
    printf("[QWEN] acc=fp%u prime_split=%u gu_early=%u kgroup=%u\n", QWEN_ACC32 ? 32u : 16u,
           (unsigned)FFN_PRIME_SPLIT, (unsigned)FFN_GU_EARLY, (unsigned)FFN_KSPLIT_XGROUP);
    // The dashboard reads the shape from this line, so --shape is not needed on
    // the generator command line. One B x K x P projection (stages stacked on M).
    // shape is the USEFUL work (roofline); workload.executed_fmac is what the
    // machine actually issues, which includes the padding columns.
    printf("[DASHBOARD_META] {\"shape\":[%u,%u,%u],\"precision\":\"%s\","
           "\"repetitions\":%u,\"kernel_size\":%u,\"burst_model\":\"%s\","
           "\"burst_geometry\":{\"tile_words\":%u,\"max_words\":%u,\"lanes\":%u,"
           "\"rob_depth\":%u,\"enabled\":%u}}\n",
           (unsigned)(QWEN_STAGES * QWEN_B), (unsigned)QWEN_K, (unsigned)QWEN_P,
           GEMM_ELEM_BYTES == 2 ? "fp16" : "fp32", (unsigned)QWEN_REPEATS,
           (unsigned)kernel_size, GEMM_BURST_MODEL, (unsigned)GEMM_BURST_TILE_WORDS,
           (unsigned)GEMM_BURST_MAX_WORDS, (unsigned)GEMM_BURST_LANES,
           (unsigned)GEMM_BURST_ROB_DEPTH, (unsigned)GEMM_BURST_ENABLED);
    // The per-group assignment, plus the executed total it must sum to. Without
    // these the dashboard cannot report progress, completion or the run tail.
    printf("[DASHBOARD_META] {\"expected_fmac_per_group\":[");
    uint32_t executed = 0u;
    for (uint32_t g = 0; g < (uint32_t)NUM_GROUPS; ++g) {
      uint32_t sum = 0u;
      for (uint32_t c = 0; c < cores_per_group; ++c) sum += qwen_fmac_core[g * cores_per_group + c];
      executed += sum;
      printf("%s%u", g ? "," : "", (unsigned)sum);
    }
    printf("],\"workload\":{\"executed_fmac\":%u}}\n", (unsigned)executed);
  }
#if MSHR_RUNTIME_CFG
  if (cid == 0 && mshr_split_bad)
    printf("[MSHR] SPLIT MISMATCH: kernel burst=%u single=%u pblocks=%u, "
           "MSHR derived %d/%d/%d -- MSHR IS MISTUNED\n",
           (unsigned)share_burst, (unsigned)share_single, (unsigned)pblocks,
           (int)MSHR_D_SPLIT_M, (int)MSHR_D_SPLIT_P, (int)MSHR_D_PGAP);
  if (mshr_align_bad)
    printf("[MSHR] operands are not mesh-sweep aligned -- the build-time bank hash "
           "does not apply to this layout\n");
  if (mshr_status != 0)
    printf("[MSHR] cfg REJECTED status=0x%x group=%d -- MEASUREMENT INVALID\n",
           (unsigned)mshr_status, (int)mshr_cfg_my_group());
  if (cid == 0)
    printf("[MSHR] share burst=%u single=%u pblocks=%u | subs=%u/%u window=%u/%u "
           "serve=%u reuse=%u cache_timeout=%u shift=%u/%u/%u\n",
           (unsigned)share_burst, (unsigned)share_single, (unsigned)pblocks,
           (unsigned)cfg.hold_subs_single, (unsigned)cfg.hold_subs_burst,
           (unsigned)cfg.hold_window_single, (unsigned)cfg.hold_window_burst,
           (unsigned)cfg.serve_timeout, (unsigned)cfg.cache_reuse_target,
           (unsigned)cfg.cache_timeout, (unsigned)cfg.bank_shift_single,
           (unsigned)cfg.bank_shift_burst, (unsigned)cfg.bank_burst_bits);
#endif

  if (cid == 0) {
    // B*K*P MACs per projection. fp16 vfmacc packs two MACs per 32-bit lane, so the
    // peak is 2*N_FPU per core per cycle. 64-bit because B*K*P overflows 32 bits from
    // B=64 up; printf still gets plain uint32.
    const uint64_t macs = (uint64_t)QWEN_STAGES * QWEN_B * QWEN_K * QWEN_P;
    const uint64_t peak = (uint64_t)timer * active_cores * 2u * N_FPU;
    printf("\n----- qwen ffn down (B=%u K=%u P=%u) -----\n", (unsigned)QWEN_B,
           (unsigned)QWEN_K, (unsigned)QWEN_P);
    printf("The execution took %u cycles.\n", timer);
    printf("[QWEN] swiglu=%u prime=%u down=%u cycles (last pass)\n", t_swiglu, t_prime,
           stage_cyc[QWEN_DOWN]);
    // Ideal = MACs / (active cores x 16 fp16 MAC/cycle): the ideal/actual efficiency.
    printf("[QWEN] ideal=%u cycles, eff=%u%%o, per K tile ideal=%u\n",
           (unsigned)(macs / ((uint64_t)active_cores * 2u * N_FPU)),
           (unsigned)(macs * 1000ull / peak),
           (unsigned)(macs / ((uint64_t)active_cores * 2u * N_FPU) /
                      (QWEN_NSTRIPS * QWEN_STEPS)));
    printf("The performance is %u MAC/1000cycle (%u%%o of fp16 peak).\n",
           (unsigned)(macs * 1000ull / timer), (unsigned)(macs * 1000ull / peak));
    // Cycles per K tile, barrier close to barrier close (tile 0 from the region start, so it
    // also carries the start-up). Last pass only when QWEN_REPEATS > 1.
    printf("[QWEN] tile_cyc");
    for (uint32_t i = 0; i < (uint32_t)QWEN_TS_N; ++i)
      printf("%s%u", i ? "," : "=",
             (unsigned)(qwen_tile_ts[i] - (i ? qwen_tile_ts[i - 1] : t_pass)));
    printf("\n");
  }

  //--------------------------------------------------------------------------
  // STEP 5: the correctness check.
  //--------------------------------------------------------------------------
#if QWEN_CHECK == 3
  if (cid == (uint32_t)QWEN_DMA_CORE)
    dma_memcpy_blocking(qwen_w[0], qwen_href_l2, (size_t)(QWEN_B * QWEN_K) * GEMM_ELEM_BYTES);
  mempool_barrier(num_cores);
  qwen_verify_swiglu(cid, num_cores);
  mempool_barrier(num_cores);
  if (cid == 0) {
    uint32_t bad = 0, maxulp = 0, exact = 0, first = 0xffffffffu;
    for (uint32_t c = 0; c < num_cores; ++c) {
      bad += qwen_sw_bad[c];
      exact += qwen_sw_exact[c];
      if (qwen_sw_maxulp[c] > maxulp) maxulp = qwen_sw_maxulp[c];
      if (qwen_sw_first[c] < first) first = qwen_sw_first[c];
    }
    printf("[QWEN] swiglu check: %u elements, %u bit-exact, max %u ulp, %u over 2 ulp\n",
           (unsigned)(QWEN_B * QWEN_K), (unsigned)exact, (unsigned)maxulp, (unsigned)bad);
    if (bad) {
      const uint16_t *h = (const uint16_t *)qwen_x, *ref = (const uint16_t *)qwen_w[0];
      printf("FAIL: swiglu first at i=%u (b=%u k=%u) got=0x%04x want=0x%04x\n", (unsigned)first,
             (unsigned)(first / QWEN_K), (unsigned)(first % QWEN_K),
             (unsigned)h[(first / QWEN_K) * QWEN_LDX + first % QWEN_K],
             (unsigned)ref[first]);
    } else {
      printf("success!\n");
    }
  }
#elif QWEN_CHECK == 4
  if (cid == (uint32_t)QWEN_DMA_CORE)
    dma_memcpy_blocking(qwen_w[0], qwen_yref_l2, (size_t)(QWEN_B * QWEN_P) * GEMM_ELEM_BYTES);
  mempool_barrier(num_cores);
  qwen_verify_bitexact(cid, num_cores);
  mempool_barrier(num_cores);
  if (cid == 0) {
    uint32_t bad = 0, first = 0xffffffffu;
    for (uint32_t c = 0; c < num_cores; ++c) {
      bad += qwen_bx_bad[c];
      if (qwen_bx_first[c] < first) first = qwen_bx_first[c];
    }
    printf("[QWEN] bit-exact check: %u outputs, %u differ from the host fp16 model\n",
           (unsigned)(QWEN_B * QWEN_P), (unsigned)bad);
    if (bad)
      printf("FAIL: first at b=%u p=%u got=0x%04x want=0x%04x\n", (unsigned)(first / QWEN_P),
             (unsigned)(first % QWEN_P),
             (unsigned)((const uint16_t *)QWEN_Y)[(first / QWEN_P) * QWEN_LDW + first % QWEN_P],
             (unsigned)((const uint16_t *)qwen_w[0])[first]);
    else
      printf("success!\n");
  }
#elif QWEN_CHECK
  if (cid == 0) qwen_bad = 0;
  mempool_barrier(num_cores);
  for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip) {
#if QWEN_NSTRIPS > 1
    if (cid == (uint32_t)QWEN_DMA_CORE)
      for (uint32_t s = 0; s < QWEN_STAGES; ++s)
        dma_memcpy_blocking(qwen_c[s], qwen_out_l2[s] + strip * (uint32_t)(QWEN_B * QWEN_LDW),
                            (size_t)(QWEN_B * QWEN_LDW) * GEMM_ELEM_BYTES);
    mempool_barrier(num_cores);
#endif
    qwen_verify_strip(strip, cid, num_cores);
    mempool_barrier(num_cores);
  }
  if (cid == 0) {
    if (qwen_bad)
      printf("FAIL: %u/%u elements wrong; first at stage=%u b=%u p=%u got=0x%04x "
             "want=0x%04x\n",
             (unsigned)qwen_bad, (unsigned)(QWEN_STAGES * QWEN_B * QWEN_P),
             (unsigned)qwen_bad_s, (unsigned)qwen_bad_b, (unsigned)qwen_bad_p,
             (unsigned)qwen_bad_got, (unsigned)qwen_bad_want);
    else
      printf("success!\n");
  }
#elif QWEN_FILL || QWEN_PRELOAD
  // No golden without a check build: leave a fingerprint instead -- only when the operands are
  // defined. A plain perf build computes on L2 that nobody wrote (.l2_bss, X out of reset on
  // RTL), so Y is X, and printf's digit loop branches on it: the fetch PC goes X inside
  // _ntoa_long and the run never reaches EOC (four 4x4 GUI runs, 2026-09-30). The timed region
  // has no data-dependent control flow, so its cycles are unaffected.
  if (cid == 0) {
    // C[0][0..3] of each stage, wherever the finished output lives.
    const volatile uint32_t *g = (const volatile uint32_t *)qwen_out_at(QWEN_DOWN, 0, 0);
    printf("[SPOT] down w0=%08x w1=%08x\n", g[0], g[1]);
  }
#endif

  // Every core must reach this barrier or the run hangs with the others in WFI.
  mempool_barrier(num_cores);
  return 0;
}
