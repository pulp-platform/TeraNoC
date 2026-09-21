// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
//==============================================================================
// Qwen3.8-27B FFN gate/up projections, streamed from L2.
//==============================================================================
//
//   G = X . Wgate     U = X . Wup      X:[B][K]  W:[K][P]  G,U:[B][P]
//
// B is the decode batch, K = hidden, P = intermediate. SiLU, the elementwise
// product and the down projection are not here.
//
// One projection is K*P*2 bytes of weights, far past L1, so W is cut into
// QWEN_KT-row tiles: tile t+1 is DMA'd into one L1 buffer while the cores compute
// on the other, and each tile adds into the same C. That K-tile pipeline is the
// only structural difference from sp-fmatmul-opt-burst-merge-fp16 -- the work
// split, KERNEL_SIZE policy, MSHR tuning, group barrier and I$ warm-up are that
// app's, because the per-tile problem is an L1-resident GEMM of [B]x[KT]x[P].
//
// W is stored row-major [K][QWEN_LDP], so a K tile is one contiguous slice: one
// DMA, no packing, no tile index arithmetic. X is replicated across the mesh (see
// qwen_layout.h) so no group is a hot spot for it. C stays in L1 as both
// accumulator and output.
//
// The L2 operands are .l2_bss: reserved, not stored in the ELF. QWEN_CHECK builds
// fill them on the target with a pattern whose exact result is known and verify it
// with integer compares only.
//
//==============================================================================

#include <stddef.h>
#include <stdint.h>

#include "data/qwen_shape.h"  // GEMM_M/N/P, GEMM_ELEM_BYTES, QWEN_KT, QWEN_CHECK
#include "qwen_layout.h"      // where X's replicas sit in L1
#include "qwen_pattern.h"     // the synthetic operand values
#include "data/qwen_hash.h"   // bank-hash selectors chosen at build time

#include "gemm_config.h"  // KERNEL_SIZE + MATMUL_DECODE_SPLIT from the shape
#include "gemm_burst.h"   // GEMM_BURST_* geometry; the kernel's stripe rule needs it

// Before the kernel: it brackets its C-accumulator reload with CFG_ENABLE writes
// (QWEN_CBYPASS), so mshr_cfg_write must already be declared.
#define MSHR_HASH_SEARCH 0
#include "mshr_cfg.h"
#include "kernel/qwen-fmatmul.c"

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
_Static_assert((QWEN_LDP % QWEN_STRIPE_E) == 0, "Row stride must be a whole number of stripes");
_Static_assert((QWEN_PBLOCKS & (QWEN_PBLOCKS - 1)) == 0,
               "A power-of-two column-block count is what makes QWEN_PAD_UNIT a single "
               "round-up instead of a least common multiple");
_Static_assert((QWEN_LDP / QWEN_PBLOCKS) % QWEN_SPAN_ALIGN == 0,
               "Columns per core must be a multiple of 4 elements or the weight loads "
               "stop bursting; see the QWEN_PAD_UNIT derivation");
#if QWEN_CHECK == 1
_Static_assert(QWEN_B <= QWEN_K,
               "The unit pattern gives each batch row its own X column, so it needs "
               "B <= K; otherwise two rows would alias onto one column and the check "
               "would silently stop distinguishing them");
#endif
#if QWEN_CHECK == 2
_Static_assert(QWEN_K <= 2048 && (QWEN_K & (QWEN_K - 1)) == 0,
               "The ones pattern needs K a power of two <= 2048 to stay exact in fp16");
#endif

// Friendly early failure for an L1 budget the linker would otherwise report as a
// bare region overflow. Approximate on purpose: the linker stays authoritative.
#define QWEN_L1_BYTES ((NUM_CORES) * (N_FU) * (BANKING_FACTOR) * (L1_BANK_SIZE))
#define QWEN_L1_USED                                                      \
  (2 * (QWEN_KT) * (QWEN_LDP)*GEMM_ELEM_BYTES +      /* W double buffer */ \
   2 * (QWEN_B) * (QWEN_LDP)*GEMM_ELEM_BYTES +       /* gate + up C     */ \
   (QWEN_X_ELEMS)*GEMM_ELEM_BYTES +                  /* X (+ replicas)  */ \
   (NUM_CORES) * (STACK_SIZE))
_Static_assert(QWEN_L1_USED < QWEN_L1_BYTES,
               "Buffers do not fit L1: lower QWEN_KT, lower the batch, or tile P");

//==============================================================================
// Storage
//==============================================================================

#define QWEN_L1 __attribute__((section(".l1_prio"), aligned(QWEN_MESH_SWEEP)))
// Reserved in L2 but NOT stored in the ELF -- see the header comment.
#define QWEN_L2 __attribute__((section(".l2_bss"), aligned(QWEN_MESH_SWEEP)))

enum { QWEN_GATE = 0, QWEN_UP = 1, QWEN_STAGES = 2 };

#if QWEN_PRELOAD
// Defined by data/qwen_operands.S, which .incbin's the images the host wrote.
extern elem_t qwen_w_l2[QWEN_STAGES][QWEN_K * QWEN_LDP];
extern elem_t qwen_x_l2[QWEN_B * QWEN_K];
#else
static elem_t qwen_w_l2[QWEN_STAGES][QWEN_K * QWEN_LDP] QWEN_L2;
static elem_t qwen_x_l2[QWEN_B * QWEN_K] QWEN_L2;
#endif

static elem_t qwen_w[2][QWEN_KT * QWEN_LDP] QWEN_L1;          // K-tile double buffer
static elem_t qwen_c[QWEN_STAGES][QWEN_B * QWEN_LDP] QWEN_L1; // accumulator + output
// One copy of X per QWEN_X_GROUPS_PER_REPLICA groups; replica r starts at
// r * QWEN_X_STRIDE_E so it lands on the first group of its neighbourhood.
static elem_t qwen_x[QWEN_X_ELEMS] QWEN_L1;

// Each core reports the FMACs its own range implies, so the dashboard's expected
// assignment comes from the real split rather than a second copy of the formula.
static uint32_t qwen_fmac_core[NUM_CORES];


//==============================================================================
// Synthetic operands (QWEN_CHECK builds only)
//==============================================================================
// Bit patterns, not arithmetic: every value below is exact in fp16, so the whole
// fill-and-verify path is integer stores, integer loads and integer compares.

#if QWEN_CHECK
// What C must hold afterwards.
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
  return qwen_w_bits(stage, QWEN_UNIT_COL(b), p);  // one-hot X picks one W row
#endif
}

#endif  // QWEN_CHECK (expectation)

#if QWEN_FILL
// Every core fills its own interleaved share; this runs before the MSHR is
// enabled and outside the timed region.
//
// A WORD at a time, not a halfword: at the full shape this is 178M elements, and
// each store is a separate NoC transaction to L2, so pairing them halves the cost
// of the slowest part of a check build. K and LDP are both even, so the pairs never
// straddle a row.
static void qwen_fill_operands(uint32_t cid, uint32_t num_cores) {
  uint32_t *x = (uint32_t *)qwen_x_l2;
  for (uint32_t i = cid; i < (uint32_t)(QWEN_B * QWEN_K) / 2u; i += num_cores) {
    const uint32_t e = 2u * i;
    x[i] = (uint32_t)qwen_x_bits(e / QWEN_K, e % QWEN_K) |
           ((uint32_t)qwen_x_bits((e + 1) / QWEN_K, (e + 1) % QWEN_K) << 16);
  }
  for (uint32_t s = 0; s < QWEN_STAGES; ++s) {
    uint32_t *w = (uint32_t *)qwen_w_l2[s];
    for (uint32_t i = cid; i < (uint32_t)(QWEN_K * QWEN_LDP) / 2u; i += num_cores) {
      const uint32_t e = 2u * i, k = e / QWEN_LDP, col = e % QWEN_LDP;
      // Columns in [P, LDP) are alignment padding: never read by the kernel, and
      // zero so that a run that accidentally reads them is obviously wrong.
      const uint32_t lo = (col < (uint32_t)QWEN_P) ? qwen_w_bits(s, k, col) : 0u;
      const uint32_t hi = (col + 1u < (uint32_t)QWEN_P) ? qwen_w_bits(s, k, col + 1u) : 0u;
      w[i] = lo | (hi << 16);
    }
  }
}

#endif  // QWEN_FILL

#if QWEN_CHECK
// Integer compare of the whole output. Returns the number of wrong elements and
// reports the first one. Both stages carry the same expected value.
static uint32_t qwen_verify(uint32_t *first_p, uint16_t *got, uint16_t *want) {
  uint32_t bad = 0;
  for (uint32_t s = 0; s < QWEN_STAGES; ++s) {
    const uint16_t *c = (const uint16_t *)qwen_c[s];
    for (uint32_t b = 0; b < (uint32_t)QWEN_B; ++b)
      for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p) {
        const uint16_t e = qwen_expect_bits(s, b, p);
        const uint16_t v = c[b * QWEN_LDP + p];
        if (v != e) {
          if (bad == 0) {
            *first_p = p;
            *got = v;
            *want = e;
          }
          ++bad;
        }
      }
  }
  return bad;
}
#endif  // QWEN_CHECK (verify)

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

// Launch the DMA that refills buffer slot `slot` with K tile `step` of `stage`.
// Core 0 only; the caller has already barriered every reader off this slot.
static void qwen_refill(uint32_t slot, uint32_t stage, uint32_t step) {
  dma_memcpy_nonblocking(qwen_w[slot],
                         qwen_w_l2[stage] + (uint32_t)step * (QWEN_KT * QWEN_LDP),
                         (size_t)(QWEN_KT * QWEN_LDP) * GEMM_ELEM_BYTES);
}

// Prime the pipeline for one projection: tile 0 resident, tile 1 in flight.
// Separate from the loop so the first projection's prime can sit outside the
// measured region -- a fill into an empty L1 has nothing to overlap with.
static void qwen_prime(uint32_t stage, uint32_t cid) {
  if (cid != (uint32_t)QWEN_DMA_CORE) return;
  qwen_refill(0, stage, 0);
  dma_wait();
  if ((uint32_t)QWEN_STEPS > 1u) qwen_refill(1, stage, 1);
}

// One projection: C[stage] = X . W[stage], reduced over all K tiles.
//
// Each iteration computes on the resident slot, then -- once every reader has left
// it -- waits for the in-flight tile and launches the next into the slot just
// freed. Exactly one transfer is outstanding: the global DMA frontend has one
// {src,dst,len} register set, so a second launch would overwrite the first.
static void qwen_project(uint32_t stage, uint32_t cid, const elem_t *x,
                         uint32_t m_start, uint32_t m_end,
                         uint32_t p_start, uint32_t p_end) {
  elem_t *c = qwen_c[stage];

  for (uint32_t step = 0; step < (uint32_t)QWEN_STEPS; ++step) {
    const uint32_t slot = step & 1u;

    // An ordinary L1-resident GEMM: reduction length KT, A the K-slice of X at
    // column step*KT (so lda = K, not KT), adding into C after the first tile.
    const elem_t *a = x + (uint32_t)step * QWEN_KT;
    const uint32_t accum = (step != 0);
#if KERNEL_SIZE == 1
    matmul_1xVL(c, a, qwen_w[slot], m_start, m_end, QWEN_KT, QWEN_LDP, p_start, p_end,
                QWEN_K, accum);
#elif KERNEL_SIZE == 2
    matmul_2xVL(c, a, qwen_w[slot], m_start, m_end, QWEN_KT, QWEN_LDP, p_start, p_end,
                QWEN_K, accum);
#elif KERNEL_SIZE == 4
    matmul_4xVL(c, a, qwen_w[slot], m_start, m_end, QWEN_KT, QWEN_LDP, p_start, p_end,
                QWEN_K, accum);
#else
    matmul_8xVL(c, a, qwen_w[slot], m_start, m_end, QWEN_KT, QWEN_LDP, p_start, p_end,
                QWEN_K, accum);
#endif

    const uint32_t pending = (step + 1u < (uint32_t)QWEN_STEPS);
    uint32_t bar = qwen_dma_log_barrier(QWEN_RADIX, cid, pending);
    if (bar) {
      // Guarantee, not the optimistic early wait: the frontend has ONE
      // {src,dst,len} register set, so the previous transfer must be complete
      // before another is programmed. A no-op when the first arriver already waited.
      if (pending) dma_wait();
      if (step + 2u < (uint32_t)QWEN_STEPS) qwen_refill(slot, stage, step + 2u);
      __atomic_store_n((uint32_t *)bar, 0, __ATOMIC_RELAXED);
      __sync_synchronize();
      wake_up_all();
      mempool_wfi();  // clear our own trigger, as the plain barrier does
    }
  }
}

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
    const uint32_t n_row_chunks = (uint32_t)QWEN_B / kernel_size;
    const uint32_t n_p_blocks = active_cores / n_row_chunks;
    if (n_row_chunks == 0u || ((uint32_t)QWEN_B % kernel_size) != 0u) return -6;
    if (n_p_blocks == 0u || (active_cores % n_row_chunks) != 0u) return -7;
    if (((uint32_t)QWEN_LDP % n_p_blocks) != 0u) return -5;
    // row_chunk varies fastest so that cores sharing a column block are adjacent
    // core ids, i.e. in the same group, where the MSHR can merge their identical
    // W loads.
    const uint32_t row_chunk = cid % n_row_chunks;
    const uint32_t p_block = cid / n_row_chunks;
    // The PADDED width, so every span is burst-friendly. The pad columns hold
    // zeros and their results are never read.
    const uint32_t p_span = (uint32_t)QWEN_LDP / n_p_blocks;
    m_start = row_chunk * kernel_size;
    m_end = m_start + kernel_size;
    p_start = p_block * p_span;
    p_end = p_start + p_span;
    // How many cores of ONE GROUP actually issue each address, per request class.
    // W (burst): the cores sharing a p_block, i.e. n_row_chunks of them.
    // X (single): the cores sharing a row chunk, i.e. the rest of the group.
    share_burst = (n_row_chunks < cores_per_group) ? n_row_chunks : cores_per_group;
    share_single = cores_per_group / share_burst;
    pblocks = n_p_blocks;
  }
#else
  {
    const uint32_t dim_group = (uint32_t)QWEN_B / active_groups;
    const uint32_t split_m_count = dim_group / kernel_size;
    if ((dim_group % kernel_size) != 0u || split_m_count == 0u) return -6;
    if (split_m_count < cores_per_group) {
      const uint32_t split_p_count = cores_per_group / split_m_count;
      if (((uint32_t)QWEN_LDP % split_p_count) != 0u) return -5;
      p_start = (uint32_t)QWEN_LDP / split_p_count * (core_gid % split_p_count);
      p_end = (uint32_t)QWEN_LDP / split_p_count * ((core_gid % split_p_count) + 1);
      m_start = dim_group * gid + kernel_size * (core_gid / split_p_count);
      m_end = m_start + kernel_size;
      share_burst = (split_m_count < cores_per_group) ? split_m_count : cores_per_group;
      share_single = cores_per_group / share_burst;
      pblocks = split_p_count;
    } else {
      p_start = 0;
      p_end = (uint32_t)QWEN_LDP;
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

  // Every core states the work its own range implies; core 0 folds these into the
  // per-group assignment the dashboard compares measured FMAC progress against.
  // Both projections and every repetition are included, and the padded width is
  // used because the padding columns are FMACs the machine really issues.
  qwen_fmac_core[cid] = (p_end - p_start) * (m_end - m_start) *
                        (uint32_t)QWEN_K * 2u * (uint32_t)QWEN_REPEATS;

  //--------------------------------------------------------------------------
  // STEP 2: operands.
  //--------------------------------------------------------------------------
#if QWEN_FILL
  qwen_fill_operands(cid, num_cores);
  mempool_barrier(num_cores);  // every core has written its share of the operands
#endif
  if (cid == (uint32_t)QWEN_DMA_CORE) {
    for (uint32_t r = 0; r < (uint32_t)QWEN_X_REPLICAS; ++r) {
      dma_memcpy_nonblocking(qwen_x + r * (uint32_t)QWEN_X_STRIDE_E, qwen_x_l2,
                            (size_t)(QWEN_B * QWEN_K) * GEMM_ELEM_BYTES);
      if (r % 2 == 1u) dma_wait();
    }
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
  // Fill the pipeline before the timer starts, so the measured region begins
  // exactly when the cores enter the first compute stage -- and before the
  // warm-up below, which reads the tile it lands.
  qwen_prime(QWEN_GATE, cid);
  mempool_barrier(num_cores);

#if ICACHE_WARMUP
  {
    const uint32_t warm = (QWEN_KT < 6u) ? (uint32_t)QWEN_KT : 6u;
#if KERNEL_SIZE == 1
    matmul_1xVL(qwen_c[0], x_use, qwen_w[0], m_start, m_end, warm, QWEN_LDP, p_start, p_end,
                QWEN_K, 0);
#elif KERNEL_SIZE == 2
    matmul_2xVL(qwen_c[0], x_use, qwen_w[0], m_start, m_end, warm, QWEN_LDP, p_start, p_end,
                QWEN_K, 0);
#elif KERNEL_SIZE == 4
    matmul_4xVL(qwen_c[0], x_use, qwen_w[0], m_start, m_end, warm, QWEN_LDP, p_start, p_end,
                QWEN_K, 0);
#else
    matmul_8xVL(qwen_c[0], x_use, qwen_w[0], m_start, m_end, warm, QWEN_LDP, p_start, p_end,
                QWEN_K, 0);
#endif
  }
  mempool_barrier(num_cores);
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
    mshr_split_bad = mshr_cfg_check_splits(share_burst, share_single, pblocks) != 0;

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
    }
  }
#endif

  //--------------------------------------------------------------------------
  // STEP 4: the measured region.
  //--------------------------------------------------------------------------
  // Per-projection boundaries, printed after the region so timing is undisturbed:
  // they answer whether the second projection costs the same as the first.
  uint32_t stage_end[QWEN_STAGES] = {0, 0};

  const uint32_t t0 = mempool_get_timer();
  mempool_start_benchmark();
  for (uint32_t rep = 0; rep < (uint32_t)QWEN_REPEATS; ++rep) {
    qwen_project(QWEN_GATE, cid, x_use, m_start, m_end, p_start, p_end);
    if (cid == 0) stage_end[QWEN_GATE] = mempool_get_timer();
    // The up projection's own prime IS measured: by then L1 is warm and this is an
    // ordinary pipeline restart, which a real FFN would pay too.
    qwen_prime(QWEN_UP, cid);
    qwen_barrier(cid);
    qwen_project(QWEN_UP, cid, x_use, m_start, m_end, p_start, p_end);
    if (cid == 0) stage_end[QWEN_UP] = mempool_get_timer();
    if (rep + 1u < (uint32_t)QWEN_REPEATS) {
      qwen_prime(QWEN_GATE, cid);
      qwen_barrier(cid);
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
           "ks=%u decode=%u check=%u xrep=%u\n",
           (unsigned)QWEN_B, (unsigned)QWEN_K, (unsigned)QWEN_P, (unsigned)QWEN_LDP,
           (unsigned)(1000u * (QWEN_LDP - QWEN_P) / QWEN_P),
           (unsigned)(p_end - p_start), (unsigned)QWEN_KT, (unsigned)QWEN_STEPS,
           (unsigned)kernel_size, (unsigned)MATMUL_DECODE_SPLIT, (unsigned)QWEN_CHECK,
           (unsigned)QWEN_X_REPLICAS);
    // The dashboard reads the shape from this line, so --shape is not needed on
    // the generator command line. Gate and up are two independent B x K x P
    // projections; stacking them on M states the real FMAC count, 2*B*K*P.
    // shape is the USEFUL work (roofline); workload.executed_fmac is what the
    // machine actually issues, which includes the padding columns.
    printf("[DASHBOARD_META] {\"shape\":[%u,%u,%u],\"precision\":\"%s\","
           "\"repetitions\":%u,\"kernel_size\":%u,\"burst_model\":\"%s\","
           "\"burst_geometry\":{\"tile_words\":%u,\"max_words\":%u,\"lanes\":%u,"
           "\"rob_depth\":%u,\"enabled\":%u}}\n",
           (unsigned)(2u * QWEN_B), (unsigned)QWEN_K, (unsigned)QWEN_P,
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
    // Two projections of B*K*P MACs. fp16 vfmacc packs two MACs per 32-bit lane,
    // so the peak is 2*N_FPU per core per cycle. 64-bit because 2*B*K*P overflows
    // 32 bits from B=32 up; printf still gets plain uint32.
    const uint64_t macs = 2ull * QWEN_B * QWEN_K * QWEN_P;
    const uint64_t peak = (uint64_t)timer * active_cores * 2u * N_FPU;
    printf("\n----- qwen gate/up (B=%u K=%u P=%u) -----\n", (unsigned)QWEN_B,
           (unsigned)QWEN_K, (unsigned)QWEN_P);
    printf("The execution took %u cycles.\n", timer);
    printf("[QWEN] gate=%u up=%u cycles (last pass)\n",
           stage_end[QWEN_GATE] - t0, stage_end[QWEN_UP] - stage_end[QWEN_GATE]);
    printf("The performance is %u MAC/1000cycle (%u%%o of fp16 peak).\n",
           (unsigned)(macs * 1000ull / timer), (unsigned)(macs * 1000ull / peak));
  }

  //--------------------------------------------------------------------------
  // STEP 5: the correctness check.
  //--------------------------------------------------------------------------
#if QWEN_CHECK
  if (cid == 0) {
    uint32_t first_p = 0;
    uint16_t got = 0, want = 0;
    const uint32_t bad = qwen_verify(&first_p, &got, &want);
    if (bad)
      printf("FAIL: %u/%u elements wrong; first at p=%u got=0x%04x want=0x%04x\n",
             (unsigned)bad, (unsigned)(QWEN_STAGES * QWEN_B * QWEN_P), (unsigned)first_p,
             (unsigned)got, (unsigned)want);
    else
      printf("success!\n");
  }
#else
  // No golden without a check build: leave a fingerprint instead.
  if (cid == 0) {
    const volatile uint32_t *g = (const volatile uint32_t *)qwen_c[QWEN_GATE];
    const volatile uint32_t *u = (const volatile uint32_t *)qwen_c[QWEN_UP];
    printf("[SPOT] gate w0=%08x w1=%08x  up w0=%08x w1=%08x\n", g[0], g[1], u[0], u[1]);
  }
#endif

  // Every core must reach this barrier or the run hangs with the others in WFI.
  mempool_barrier(num_cores);
  return 0;
}
