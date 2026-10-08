// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
//==============================================================================
// ONE streamed projection phase:  C[s] = A . W[s] for its QWEN_STAGES_N projections
//==============================================================================
//
// Not compiled on its own: an app's phase wrapper defines the hooks below, puts the phase's
// generated headers (<phase>/data/qwen_shape.h, qwen_tiles.h, qwen_hash.h) on the include path
// and #includes this file -- once per phase, because gemm_config.h / mshr_cfg.h derive the kernel
// size, split and MSHR tuning from GEMM_M/N/P at compile time (qwen-ffn: phase_gu.c, phase_dn.c).
//
// The pipeline is qwen-ffn-down's (itself qwen-gate-up's): K tiles streamed by one DMA into a
// double buffer, the decode split, the K split inside or across groups (FFN_KSPLIT_XGROUP), the
// fp16 C, the group MSHR tuned per phase.
//
// Hooks the wrapper defines before including this file:
//   QP_PFX(x)        required: prefixes every exported symbol, e.g. gu_##x
//   QP_NAME          required: the phase's name in reports, e.g. "gate+up"
//   QP_W_AREA        required: the W double buffer, two regions of QP_WREG_ELEMS elements --
//   QP_WREG_ELEMS              may be shared with other phases (tile t of a projection is in t & 1)
//   QP_A_EXT         optional: the A operand is this external buffer (e.g. written by an earlier
//                    phase's epilogue); QP_A_EXT_ELEMS / _LDX / _REPLICAS / _STRIDE_E must match
//                    this phase's layout. Without it the phase owns a replicated A (qwen_x) and
//                    copies it from L2 (qwen_x_l2) in setup.
//   QP_SETUP_GBAR    optional, 1: this phase programs the GBAR_PLOOP group-barrier struct
//                    (exactly one phase per app does, the struct is shared)
//   QP_EPILOGUE      optional: void QP_EPILOGUE(uint32_t cid, uint32_t strip, const qp_patch_t *)
//                    called after each strip's projections are reduced, with the MSHR off around
//                    it (its loads have one reader each) and global rendezvous on both sides. It
//                    owns its output layout. Without it a multi-strip phase writes C back to L2.
//                    After the last strip the MSHR is left OFF for the next phase to tune.
//   QP_NEXT_REFILL   optional: void QP_NEXT_REFILL(uint32_t j) -- the stream continues into the
//                    next phase: this phase's last two pipeline barriers launch that phase's
//                    tiles 0 and 1 (its QP_PFX(refill_head)), into the regions just freed.
//   QP_PREV_BANK_SEL optional: uint32_t QP_PREV_BANK_SEL(uint32_t g) -- the previous phase's
//                    packed bank-hash triple; enables QP_PFX(mshr_handover).
//
// Exported (each prefixed): setup, prime (the first phase: tiles 0/1 + full MSHR tuning), run,
// refill_head, mshr_handover, bank_sel, barrier, mshr_off, macs, report.
//
//==============================================================================

#include <stddef.h>
#include <stdint.h>

#ifndef QP_PFX
#error "qwen_phase.c is included by a phase wrapper that defines QP_PFX, QP_NAME and QP_W_AREA"
#endif

#include "data/qwen_shape.h"  // this phase's, via the include path
#include "qwen_layout.h"
#include "qwen_pattern.h"
#include "data/qwen_hash.h"
_Static_assert(sizeof(qwen_hash_sel) / sizeof(qwen_hash_sel[0]) == NUM_GROUPS,
               "qwen_hash.h was generated for another mesh: rebuild its generated headers");

#include "gemm_config.h"
#include "gemm_burst.h"

#define MSHR_HASH_SEARCH 0
#include "mshr_cfg.h"
#include "qwen_tu_prefix.h"  // this TU's own copies of the kernels and of dma.h's two functions
#include "kernel/qwen-fmatmul.c"

#include "printf.h"
#include "runtime.h"
#include "synchronization.h"
#include "encoding.h"
#include "dma.h"

#include "qwen_phase.h"

#define QWEN_STEPS ((QWEN_K) / (QWEN_KT))
#define QWEN_GROUP_HELPER 1u
#ifndef QWEN_DMA_CORE
#define QWEN_DMA_CORE 0u
#endif
#ifndef QWEN_PRELOAD
#define QWEN_PRELOAD 0
#endif
#ifndef QP_SETUP_GBAR
#define QP_SETUP_GBAR 0
#endif

_Static_assert(GEMM_ELEM_BYTES == 2, "fp16 only");
_Static_assert(!QWEN_ACC32 && !QWEN_SWIGLU && FFN_PRIME_SPLIT == 1,
               "qwen_phase.c runs the fp16 C, no SwiGLU prologue, a whole first tile");
_Static_assert((QWEN_K % QWEN_KT) == 0 && (QWEN_KT % 2) == 0, "K tiles must tile K, even rows");
_Static_assert((QWEN_KT % (2 * QWEN_KSPLIT)) == 0, "Each K part must be an even number of rows");
_Static_assert(QWEN_STAGES_N <= 2, "qp_patch_t carries at most two projections");
#if QWEN_KSPLIT > 1
_Static_assert((QWEN_KSPLIT & (QWEN_KSPLIT - 1)) == 0 && QWEN_KSPLIT <= 16, "ks: 2^n <= 16");
_Static_assert(MATMUL_DECODE_SPLIT, "The K split exists only in the decode split");
_Static_assert(GBAR_PLOOP, "The reduction rendezvouses on the GBAR_PLOOP struct");
#ifndef QP_EPILOGUE
_Static_assert(QWEN_NSTRIPS == 1,
               "Without an epilogue a strip is written back inside its last tile's barrier, "
               "before the reduction: one strip under a K split");
#endif
#endif
_Static_assert((QWEN_LDP % QWEN_STRIPE_E) == 0 && (QWEN_WPAD % QWEN_STRIPE_E) == 0,
               "Rows must start on a burst boundary");
_Static_assert(QWEN_PT_LEGAL_K(QWEN_KT, QWEN_PT), "Illegal strip width for this phase");
_Static_assert(QWEN_WSLOT <= QP_WREG_ELEMS, "This phase's W slot does not fit the W region");
_Static_assert((QWEN_STEPS % 2) == 0, "The continuous stream needs an even K-tile count");
#ifdef QP_A_EXT
_Static_assert(QWEN_X_ELEMS == QP_A_EXT_ELEMS && QWEN_LDX == QP_A_EXT_LDX &&
                   QWEN_X_REPLICAS == QP_A_EXT_REPLICAS && QWEN_X_STRIDE_E == QP_A_EXT_STRIDE_E,
               "The external A operand's layout is stale: it must be this phase's");
#endif

//==============================================================================
// Storage
//==============================================================================

#define QWEN_L1 __attribute__((section(".l1_prio"), aligned(QWEN_MESH_SWEEP)))
#define QWEN_L2 __attribute__((section(".l2_bss"), aligned(QWEN_MESH_SWEEP)))

#if QWEN_PRELOAD
// Written by the host and placed by the app's operands stub: <prefix>w_l2 (and <prefix>x_l2).
extern elem_t QP_PFX(w_l2)[QWEN_STAGES_N][QWEN_WTILES * QWEN_WSLOT];
#define qwen_w_l2 QP_PFX(w_l2)
#ifndef QP_A_EXT
extern elem_t QP_PFX(x_l2)[QWEN_B * QWEN_LDX];
#define qwen_x_l2 QP_PFX(x_l2)
#endif
#else
static elem_t qwen_w_l2[QWEN_STAGES_N][QWEN_WTILES * QWEN_WSLOT] QWEN_L2;
#ifndef QP_A_EXT
static elem_t qwen_x_l2[QWEN_B * QWEN_LDX] QWEN_L2;
#endif
#endif

// The two W regions. Arithmetic, not a pointer table: a const table sits in .rodata (L2), one
// load per K tile.
#define QWEN_W(slot) ((elem_t *)(QP_W_AREA) + (uint32_t)(slot) * (uint32_t)(QP_WREG_ELEMS))
static elem_t qwen_c[QWEN_STAGES_N][QWEN_CSLOT] QWEN_L1;  // C, one strip
#if QWEN_KSPLIT > 1
static elem_t qwen_cp[QWEN_KSPLIT - 1][QWEN_CSLOT] QWEN_L1;  // K parts 1.. partial sums
#endif
#ifdef QP_A_EXT
#define qwen_x ((elem_t *)(QP_A_EXT))
#else
static elem_t qwen_x[QWEN_X_ELEMS] QWEN_L1;  // A, replicated
#endif
#if !defined(QP_EPILOGUE) && QWEN_NSTRIPS > 1
static elem_t qwen_out_l2[QWEN_STAGES_N][QWEN_NSTRIPS * QWEN_B * QWEN_LDW] QWEN_L2;  // C strips
#endif

static uint32_t qwen_tile_ts[QWEN_NSTRIPS * QWEN_STAGES_N * QWEN_STEPS];
static uint32_t qwen_fmac_core[NUM_CORES];
static uint32_t ph_share_burst, ph_share_single, ph_pblocks;
#if MSHR_RUNTIME_CFG
static mshr_cfg_t ph_cfg;
static uint32_t ph_mshr_status[NUM_GROUPS], ph_split_bad, ph_align_bad;
#endif
static uint32_t ph_t_pass;

//==============================================================================
// Barriers (qwen-ffn-down's)
//==============================================================================

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

// Counters in each core's sequential memory (crt0 stack limit word); see qwen-ffn-down.
static uint32_t qwen_log_barrier(uint32_t step, uint32_t core_id) {
  uint32_t *bar = (uint32_t *)(((core_id / step) * step + (step >> QWEN_LOG2_RADIX) - 1) *
                                   SEQ_MEM_SIZE + 4);
  uint32_t val = __atomic_fetch_add(bar, 1, __ATOMIC_RELAXED);
  if (val == (uint32_t)(QWEN_RADIX - 1)) {
    if (step == (uint32_t)NUM_CORES) return (uint32_t)bar;
    __atomic_store_n(bar, 0, __ATOMIC_RELAXED);
    return qwen_log_barrier(step << QWEN_LOG2_RADIX, core_id);
  }
  mempool_wfi();
  return 0;
}

// The first arriver absorbs the outstanding transfer's wait (qwen-ffn-down).
static uint32_t qwen_dma_log_barrier(uint32_t step, uint32_t core_id, uint32_t dma_pending) {
  uint32_t *bar = (uint32_t *)(((core_id / step) * step + (step >> QWEN_LOG2_RADIX) - 1) *
                                   SEQ_MEM_SIZE + 4);
  uint32_t val = __atomic_fetch_add(bar, 1, __ATOMIC_RELAXED);
  if (val == (uint32_t)(QWEN_RADIX - 1)) {
    if (step == (uint32_t)NUM_CORES) return (uint32_t)bar;
    __atomic_store_n(bar, 0, __ATOMIC_RELAXED);
    return qwen_dma_log_barrier(step << QWEN_LOG2_RADIX, core_id, dma_pending);
  }
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
    mempool_wfi();
  }
}

// Global rendezvous with this core's vector stores drained first (the barrier atomic is scalar).
static inline void qp_sync(uint32_t cid) {
  __asm__ volatile("fence" ::: "memory");
  qwen_barrier(cid);
}

static inline void qp_mshr_enable(uint32_t on) {
#if MSHR_RUNTIME_CFG
  if (mshr_cfg_is_group_writer())
    mshr_cfg_write(mshr_cfg_my_group(), mshr_cfg_peer_tile(), MSHR_CSR_ENABLE, on);
  __asm__ volatile("fence" ::: "memory");
#else
  (void)on;
#endif
}

//==============================================================================
// The W stream
//==============================================================================

static void qwen_refill(uint32_t slot, uint32_t stage, uint32_t strip, uint32_t step) {
  dma_memcpy_nonblocking(QWEN_W(slot),
                         qwen_w_l2[stage] +
                             (strip * (uint32_t)QWEN_STEPS + step) * (uint32_t)QWEN_WSLOT,
                         (size_t)(QWEN_KT * QWEN_LDW) * GEMM_ELEM_BYTES);
}

// seq = (strip * STAGES + stage) * STEPS + step; tile seq lives in region seq & 1 (even STEPS).
#define QWEN_SEQ_TOTAL ((uint32_t)(QWEN_NSTRIPS * QWEN_STAGES_N * QWEN_STEPS))
static void qwen_refill_seq(uint32_t seq) {
  const uint32_t step = seq % (uint32_t)QWEN_STEPS, proj = seq / (uint32_t)QWEN_STEPS;
  qwen_refill(step & 1u, proj % (uint32_t)QWEN_STAGES_N, proj / (uint32_t)QWEN_STAGES_N, step);
}

// The stream's hand-over target: the previous phase's last two pipeline barriers launch this
// phase's tiles 0 and 1, into the regions it has just left. Its tile count must be even so
// that this phase's tile t lands in region t & 1.
void QP_PFX(refill_head)(uint32_t j) {
  if (j < QWEN_SEQ_TOTAL) qwen_refill_seq(j);
}

#if !defined(QP_EPILOGUE) && QWEN_NSTRIPS > 1
static void qwen_writeback_dma(uint32_t strip) {
  for (uint32_t s = 0; s < (uint32_t)QWEN_STAGES_N; ++s) {
    dma_memcpy_nonblocking(qwen_out_l2[s] + strip * (uint32_t)(QWEN_B * QWEN_LDW), qwen_c[s],
                           (size_t)(QWEN_B * QWEN_LDW) * GEMM_ELEM_BYTES);
    dma_wait();
  }
}
#endif

//==============================================================================
// K split
//==============================================================================

// The sub-patch of (rows, columns) a K part finalises: by rows when they divide, else columns.
static inline void qp_subpatch(uint32_t kpart, uint32_t m_start, uint32_t m_end,
                               uint32_t p_start, uint32_t p_end, uint32_t *r0, uint32_t *r1,
                               uint32_t *c0, uint32_t *c1) {
  const uint32_t ks = (uint32_t)QWEN_KSPLIT, nrow = m_end - m_start, ncol = p_end - p_start;
  *r0 = m_start; *r1 = m_end; *c0 = p_start; *c1 = p_end;
  if (ks == 1u || m_end == m_start) return;
  if ((nrow % ks) == 0) {
    *r0 = m_start + kpart * (nrow / ks);
    *r1 = *r0 + nrow / ks;
  } else {
    *c0 = p_start + kpart * (ncol / ks);
    *c1 = *c0 + ncol / ks;
  }
}

#if QWEN_KSPLIT > 1
// C[stage] += the other K parts' partials over this core's sub-patch, MSHR bypassed (every
// address has one reader). Partners in the same group meet on the group barrier, partners in
// other groups (cross-group split) on the global one. qwen-ffn-down's protocol.
static void qwen_ksplit_reduce(uint32_t cid, uint32_t stage, uint32_t kpart, uint32_t m_start,
                               uint32_t m_end, uint32_t p_start, uint32_t p_end) {
#if FFN_KSPLIT_XGROUP
#define QWEN_KS_SYNC() qp_sync(cid)
#else
  if (m_end == m_start) return;
  const uint32_t gb = gbar_base(GBAR_PLOOP_STRUCT);
#define QWEN_KS_SYNC() gbar_sync_drain(gb)
  (void)cid;
#endif
  uint32_t r0, r1, c0, c1;
  qp_subpatch(kpart, m_start, m_end, p_start, p_end, &r0, &r1, &c0, &c1);
  elem_t *c = qwen_c[stage];
  QWEN_KS_SYNC();
  qp_mshr_enable(0u);
  QWEN_KS_SYNC();
  for (uint32_t r = r0; r < r1; ++r) {
    for (uint32_t p = c0; p < c1;) {
      size_t vl;
      asm volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(vl) : "r"(c1 - p));
      const uint32_t off = r * (uint32_t)QWEN_LDW + p;
      asm volatile("vle16.v v24, (%0)" ::"r"(c + off));
      for (uint32_t j = 0; j + 1u < (uint32_t)QWEN_KSPLIT; ++j) {
        asm volatile("vle16.v v28, (%0)" ::"r"(qwen_cp[j] + off));
        asm volatile("vfadd.vv v24, v24, v28");
      }
      asm volatile("vse16.v v24, (%0)" ::"r"(c + off));
      p += (uint32_t)vl;
    }
  }
  QWEN_KS_SYNC();
  qp_mshr_enable(1u);
  QWEN_KS_SYNC();
#undef QWEN_KS_SYNC
}
#endif

//==============================================================================
// One projection of one strip
//==============================================================================

static inline void qwen_kernel(elem_t *c, const elem_t *a, const elem_t *w, uint32_t m_start,
                               uint32_t m_end, uint32_t n, uint32_t p_start, uint32_t p_end,
                               uint32_t accum, uint32_t zz) {
#if KERNEL_SIZE == 1
  matmul_1xVL(c, a, w, m_start, m_end, n, QWEN_LDW, p_start, p_end, QWEN_LDX, accum, zz, c);
#elif KERNEL_SIZE == 2
  matmul_2xVL(c, a, w, m_start, m_end, n, QWEN_LDW, p_start, p_end, QWEN_LDX, accum, zz, c);
#elif KERNEL_SIZE == 4
  matmul_4xVL(c, a, w, m_start, m_end, n, QWEN_LDW, p_start, p_end, QWEN_LDX, accum, zz, c);
#else
  matmul_8xVL(c, a, w, m_start, m_end, n, QWEN_LDW, p_start, p_end, QWEN_LDX, accum, zz, c);
#endif
}

static void qwen_project(uint32_t stage, uint32_t strip, uint32_t cid, const elem_t *x,
                         const qp_split_t *sp) {
  const uint32_t m_start = sp->m_start, m_end = sp->m_end;
  const uint32_t p_start = sp->p_start, p_end = sp->p_end, kpart = sp->kpart;
#if QWEN_KSPLIT > 1
  elem_t *c = kpart ? qwen_cp[kpart - 1u] : qwen_c[stage];
#else
  elem_t *c = qwen_c[stage];
  (void)kpart;
#endif
  for (uint32_t step = 0; step < (uint32_t)QWEN_STEPS; ++step) {
    const uint32_t slot = step & 1u;
    const elem_t *a = x + step * (uint32_t)QWEN_KT + kpart * (uint32_t)QWEN_KT_CORE;
    const elem_t *w = QWEN_W(slot) + kpart * (uint32_t)(QWEN_KT_CORE * QWEN_LDW);
    // Zig-zag the column blocks per tile so one block's accumulators stay in registers across
    // the tile boundary (qwen-ffn-down); not across projections.
    qwen_kernel(c, a, w, m_start, m_end, QWEN_KT_CORE, p_start, p_end, step != 0u,
                (step & 1u) | ((step != 0u) ? 2u : 0u) |
                    ((step + 1u < (uint32_t)QWEN_STEPS) ? 4u : 0u));

    const uint32_t seq = (strip * (uint32_t)QWEN_STAGES_N + stage) * (uint32_t)QWEN_STEPS + step;
#ifdef QP_NEXT_REFILL
    // The stream does not stop at the end of this phase: its last two barriers wait for and
    // launch the next phase's tiles 0 and 1.
    const uint32_t pending = 1u, launch = 1u, wb = 0u;
#else
    const uint32_t pending = (seq + 1u < QWEN_SEQ_TOTAL);
    const uint32_t launch = (seq + 2u < QWEN_SEQ_TOTAL);
#if !defined(QP_EPILOGUE) && QWEN_NSTRIPS > 1
    const uint32_t wb = (stage + 1u == (uint32_t)QWEN_STAGES_N) && (step + 1u == (uint32_t)QWEN_STEPS);
    if (wb) __asm__ volatile("fence" ::: "memory");
#else
    const uint32_t wb = 0u;
#endif
#endif
    uint32_t bar = qwen_dma_log_barrier(QWEN_RADIX, cid, pending);
    if (bar) {
      qwen_tile_ts[seq] = mempool_get_timer();
      if (pending) dma_wait();
#if !defined(QP_EPILOGUE) && QWEN_NSTRIPS > 1
      if (wb) qwen_writeback_dma(strip);
#endif
      (void)wb;
      if (launch) {
        if (seq + 2u < QWEN_SEQ_TOTAL) qwen_refill_seq(seq + 2u);
#ifdef QP_NEXT_REFILL
        else QP_NEXT_REFILL(seq + 2u - QWEN_SEQ_TOTAL);
#endif
      }
      __atomic_store_n((uint32_t *)bar, 0, __ATOMIC_RELAXED);
      __sync_synchronize();
      wake_up_all();
      mempool_wfi();
    }
  }
#if QWEN_KSPLIT > 1
  qwen_ksplit_reduce(cid, stage, kpart, m_start, m_end, p_start, p_end);
#endif
}

#ifdef QP_EPILOGUE
// After a strip's projections are reduced: the core's finished patch to the app's epilogue.
// MSHR off around it -- these reads have one reader each. The closing rendezvous also keeps the
// next strip's partial stores off C until every core has read it. After the last strip the
// MSHR is left off: the next phase writes its own tuning (QP_PFX(mshr_handover)).
static void qp_epilogue_strip(uint32_t cid, uint32_t strip, uint32_t last, const qp_split_t *sp) {
  qp_patch_t pt;
  qp_subpatch(sp->kpart, sp->m_start, sp->m_end, sp->p_start, sp->p_end, &pt.r0, &pt.r1, &pt.c0,
              &pt.c1);
  pt.c[0] = qwen_c[0];
  pt.c[1] = QWEN_STAGES_N > 1 ? qwen_c[QWEN_STAGES_N > 1 ? 1 : 0] : (const elem_t *)0;
  pt.ldc = (uint32_t)QWEN_LDW;
  pt.col0 = strip * (uint32_t)QWEN_PT;
  qp_sync(cid);
  qp_mshr_enable(0u);
  qp_sync(cid);
  QP_EPILOGUE(cid, strip, &pt);
  qp_sync(cid);
  if (!last) {
    qp_mshr_enable(1u);
    qp_sync(cid);
  }
}
#endif

//==============================================================================
// Setup (outside the timed region)
//==============================================================================

int QP_PFX(setup)(uint32_t cid, qp_split_t *sp) {
  const uint32_t num_cores = mempool_get_core_count();
  const uint32_t cores_per_group = num_cores / NUM_GROUPS;
  const uint32_t core_gid = cid % cores_per_group, gid = cid / cores_per_group;
  const uint32_t active_groups = NUM_GROUPS / ACTIVE_GROUP_DIV;
  const uint32_t active_cores = cores_per_group * active_groups;
  const uint32_t kernel_size = KERNEL_SIZE;
  uint32_t m_start = 0, m_end = 0, p_start = 0, p_end = 0, kpart = 0;
  uint32_t share_burst = 1, share_single = 1, pblocks = 1;

  // Work split: qwen-ffn-down STEP 1 (decode split, K split inside or across groups).
#if MATMUL_DECODE_SPLIT
  {
    const uint32_t ks = (uint32_t)QWEN_KSPLIT;
    const uint32_t n_row_chunks = (uint32_t)QWEN_B / kernel_size;
    const uint32_t n_p_blocks = active_cores / (n_row_chunks * ks);
    if (n_row_chunks == 0u || ((uint32_t)QWEN_B % kernel_size) != 0u) return -6;
    if (n_p_blocks == 0u || (active_cores % (n_row_chunks * ks)) != 0u) return -7;
    if (((uint32_t)QWEN_PT % n_p_blocks) != 0u) return -5;
    const uint32_t rcg = (n_row_chunks < (uint32_t)GEMM_DECODE_RC_PER_GROUP)
                             ? n_row_chunks : (uint32_t)GEMM_DECODE_RC_PER_GROUP;
    if (rcg == 0u || (cores_per_group % (rcg * ks)) != 0u || (n_row_chunks % rcg) != 0u)
      return -6;
    const uint32_t n_bands = n_row_chunks / rcg;
#if FFN_KSPLIT_XGROUP
    const uint32_t gid_p = gid / ks;
    const uint32_t pb_per_group = cores_per_group / rcg;
    if (((active_groups / ks) % n_bands) != 0u) return -10;
    const uint32_t row_chunk = (gid_p % n_bands) * rcg + core_gid % rcg;
    const uint32_t p_block = (gid_p / n_bands) * pb_per_group + core_gid / rcg;
    kpart = gid % ks;
#else
    const uint32_t pb_per_group = cores_per_group / (rcg * ks);
    const uint32_t row_chunk = (gid % n_bands) * rcg + core_gid % rcg;
    const uint32_t p_block = (gid / n_bands) * pb_per_group + core_gid / (rcg * ks);
    kpart = (core_gid / rcg) % ks;
#endif
    const uint32_t p_span = (uint32_t)QWEN_PT / n_p_blocks;
    if ((kernel_size % ks) != 0u && (p_span % ks) != 0u) return -8;
    m_start = row_chunk * kernel_size;
    m_end = m_start + kernel_size;
    p_start = p_block * p_span;
    p_end = p_start + p_span;
    share_burst = rcg;
    share_single = pb_per_group;
    pblocks = n_p_blocks;
  }
#else
#error "qwen_phase.c runs the decode split"
#endif
  if (cid >= active_cores) m_start = m_end = p_start = p_end = 0;
  sp->m_start = m_start; sp->m_end = m_end;
  sp->p_start = p_start; sp->p_end = p_end; sp->kpart = kpart;
  if (cid == 0) { ph_share_burst = share_burst; ph_share_single = share_single; ph_pblocks = pblocks; }
  qwen_fmac_core[cid] = (p_end - p_start) * (m_end - m_start) * (uint32_t)QWEN_NSTRIPS *
                        (uint32_t)(QWEN_K / QWEN_KSPLIT) * (uint32_t)QWEN_STAGES_N;

#ifndef QP_A_EXT
  // A into its replicas.
  if (cid == (uint32_t)QWEN_DMA_CORE) {
    for (uint32_t r = 0; r < (uint32_t)QWEN_X_REPLICAS; ++r) {
      dma_memcpy_nonblocking(qwen_x + r * (uint32_t)QWEN_X_STRIDE_E, qwen_x_l2,
                             (size_t)(QWEN_B * QWEN_LDX) * GEMM_ELEM_BYTES);
      dma_wait();
    }
  }
#endif
#if QP_SETUP_GBAR && GBAR_PLOOP
  // One group-barrier struct serves every phase (same group, same target).
  if (cid < active_cores && core_gid == QWEN_GROUP_HELPER) {
    const uint32_t gmask = (cores_per_group >= 32u) ? 0xFFFFFFFFu : ((1u << cores_per_group) - 1u);
    gbar_setup(GBAR_PLOOP_STRUCT, cores_per_group, gmask);
  }
#endif

  // I$ warm-up of this phase's kernel copy, on W region 0: its contents are whatever is there,
  // the results are discarded.
#if ICACHE_WARMUP
  {
    const elem_t *x_use = qwen_x + (uint32_t)QWEN_X_REPLICA_OF(gid) * (uint32_t)QWEN_X_STRIDE_E;
    const uint32_t warm = (QWEN_KT < 6u) ? (uint32_t)QWEN_KT : 6u;
    qwen_kernel(qwen_c[0], x_use, QWEN_W(0), m_start, m_end, warm, p_start, p_end, 0, 0u);
  }
#endif

#if MSHR_RUNTIME_CFG
  // This phase's tuning, from its own derivation; written by prime / mshr_handover.
  if (cid == 0) {
    mshr_cfg_t cfg = MSHR_CFG_DERIVED_INIT;
#if FFN_KSPLIT_XGROUP
    // mshr_cfg.h assumes the K split inside a group (qwen-ffn-down main.c): retune singles.
    ph_split_bad = (share_burst != (uint32_t)MSHR_D_SPLIT_M) || (pblocks != (uint32_t)MSHR_D_PGAP);
    const uint32_t subs = share_single <= 2u ? 1u
                        : (share_single > (uint32_t)MSHR_MERGE_CAP ? (uint32_t)MSHR_MERGE_CAP
                                                                  : share_single);
    cfg.hold_subs_single = subs;
    cfg.hold_window_single = share_single < 2u ? 0u : (uint32_t)MSHR_CFG_HOLD_WINDOW_SINGLE;
    cfg.cache_reuse_target = MSHR_CFG_CACHE_REUSE_TARGET ? (uint32_t)MSHR_CFG_CACHE_REUSE_TARGET
                           : (subs < 2u || 2u * subs > 2u * (uint32_t)MSHR_MERGE_REQS) ? 0u
                           : 2u * subs;
#else
    ph_split_bad = mshr_cfg_check_splits(share_burst, share_single, pblocks) != 0;
#endif
    ph_align_bad = (((uintptr_t)qwen_x | (uintptr_t)QWEN_W(0)) & (QWEN_MESH_SWEEP - 1)) != 0u;
    ph_cfg = cfg;
  }
#endif
  return 0;
}

//==============================================================================
// MSHR tuning
//==============================================================================

#if MSHR_RUNTIME_CFG
// This group's bank-hash triple, packed (phases compare them at a handover).
uint32_t QP_PFX(bank_sel)(uint32_t g) {
  return (uint32_t)qwen_hash_sel[g][0] | ((uint32_t)qwen_hash_sel[g][1] << 8) |
         ((uint32_t)qwen_hash_sel[g][2] << 16);
}

// This phase's tuning into this group's CSRs, enabled. Group helper only; the caller barriers.
// At boot the MSHR is empty and mshr_cfg_apply_group writes everything. At a handover it is not:
// lines the previous phase left in the response cache stay until their serve timeout, and a
// bank-hash write while any entry is resident is refused (MSHR_STATUS_BANK_BUSY, old hash kept).
// So a handover writes the hold / reuse / timeout fields straight away and the bank hash only
// where it differs from the previous phase's -- retrying until the entries have drained.
static void qp_mshr_apply(uint32_t cid, uint32_t prev_sel, uint32_t at_handover) {
  const uint32_t cores_per_group = NUM_CORES / NUM_GROUPS;
  if (cid % cores_per_group != QWEN_GROUP_HELPER) return;
  const uint32_t gid = cid / cores_per_group;
  mshr_cfg_t cfg = ph_cfg;
  cfg.bank_shift_single = qwen_hash_sel[gid][0];
  cfg.bank_shift_burst = qwen_hash_sel[gid][1];
  cfg.bank_burst_bits = qwen_hash_sel[gid][2];
  if (!at_handover) {
    ph_mshr_status[gid] = mshr_cfg_apply_group(&cfg);
    __asm__ volatile("fence" ::: "memory");
    return;
  }
  const uint32_t g = mshr_cfg_my_group(), tile = mshr_cfg_peer_tile();
  mshr_cfg_write(g, tile, MSHR_CSR_ENABLE, 0);
  mshr_cfg_write(g, tile, MSHR_CSR_STATUS, 0);
  mshr_cfg_write(g, tile, MSHR_CSR_HOLD_SUBS_SINGLE, cfg.hold_subs_single);
  mshr_cfg_write(g, tile, MSHR_CSR_HOLD_SUBS_BURST, cfg.hold_subs_burst);
  mshr_cfg_write(g, tile, MSHR_CSR_HOLD_WINDOW_SINGLE, cfg.hold_window_single);
  mshr_cfg_write(g, tile, MSHR_CSR_HOLD_WINDOW_BURST, cfg.hold_window_burst);
  mshr_cfg_write(g, tile, MSHR_CSR_SERVE_TIMEOUT, cfg.serve_timeout);
  mshr_cfg_write(g, tile, MSHR_CSR_CACHE_REUSE_TARGET, cfg.cache_reuse_target);
  mshr_cfg_write(g, tile, MSHR_CSR_CACHE_TIMEOUT, cfg.cache_timeout);
  mshr_cfg_write(g, tile, MSHR_CSR_BANKFULL_BP, cfg.bankfull_backpressure);
#if MSHR_CFG_SPLIT
  mshr_cfg_write(g, tile, MSHR_CSR_STEER_SINGLE_ROW, cfg.steer_single_row);
#endif
  __asm__ volatile("fence" ::: "memory");
  uint32_t st = mshr_cfg_status(g, tile);
  if (prev_sel != QP_PFX(bank_sel)(gid)) {
    for (uint32_t tries = 0; tries < 256u; ++tries) {
      mshr_cfg_write(g, tile, MSHR_CSR_STATUS, 0);
      mshr_cfg_write(g, tile, MSHR_CSR_BANK_SHIFT_SINGLE, cfg.bank_shift_single);
      mshr_cfg_write(g, tile, MSHR_CSR_BANK_SHIFT_BURST, cfg.bank_shift_burst);
      mshr_cfg_write(g, tile, MSHR_CSR_BANK_BURST_BITS, cfg.bank_burst_bits);
      __asm__ volatile("fence" ::: "memory");
      st = mshr_cfg_status(g, tile);
      if (!(st & MSHR_STATUS_BANK_BUSY)) break;
      for (volatile uint32_t spin = 0; spin < 64u; ++spin) {
      }
    }
  }
  mshr_cfg_write(g, tile, MSHR_CSR_ENABLE, 1);
  __asm__ volatile("fence" ::: "memory");
  ph_mshr_status[gid] = st;
}
#endif

#ifdef QP_PREV_BANK_SEL
// The previous phase is done and left the MSHR off: this phase's tuning, enabled. The caller
// rendezvouses everyone before any of this phase's loads.
void QP_PFX(mshr_handover)(uint32_t cid) {
#if MSHR_RUNTIME_CFG
  qp_mshr_apply(cid, QP_PREV_BANK_SEL(cid / (NUM_CORES / NUM_GROUPS)), 1u);
#else
  (void)cid;
#endif
}
#endif

// The pipeline's log barrier (mempool_barrier's single counter costs ~14k cycles at 8x8), with
// this core's vector stores drained first; and this group's MSHR off.
void QP_PFX(barrier)(uint32_t cid) { qp_sync(cid); }
void QP_PFX(mshr_off)(void) { qp_mshr_enable(0u); }

//==============================================================================
// Run
//==============================================================================

// The first phase of a region: tiles 0 and 1 of the stream (before the region: nothing to
// overlap) and this phase's MSHR tuning on the still-empty MSHR.
void QP_PFX(prime)(uint32_t cid) {
  if (cid == (uint32_t)QWEN_DMA_CORE) {
    qwen_refill(0, 0, 0, 0);
    dma_wait();
    if (QWEN_SEQ_TOTAL > 1u) qwen_refill_seq(1);
  }
#if MSHR_RUNTIME_CFG
  qp_mshr_apply(cid, 0u, 0u);
#endif
}

void QP_PFX(run)(uint32_t cid, const qp_split_t *sp) {
  const elem_t *x_use =
      qwen_x + (uint32_t)QWEN_X_REPLICA_OF(cid / (NUM_CORES / NUM_GROUPS)) * (uint32_t)QWEN_X_STRIDE_E;
  ph_t_pass = mempool_get_timer();
  for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip) {
    for (uint32_t stage = 0; stage < (uint32_t)QWEN_STAGES_N; ++stage)
      qwen_project(stage, strip, cid, x_use, sp);
#ifdef QP_EPILOGUE
    qp_epilogue_strip(cid, strip, strip + 1u == (uint32_t)QWEN_NSTRIPS, sp);
#endif
  }
}

//==============================================================================
// Report
//==============================================================================

uint64_t QP_PFX(macs)(void) {
  return (uint64_t)QWEN_STAGES_N * QWEN_B * QWEN_K * QWEN_P;
}

void QP_PFX(report)(uint32_t cid, uint32_t cycles) {
  if (cid != 0) return;
  const uint64_t ideal = QP_PFX(macs)() / ((uint64_t)NUM_CORES * 2u * N_FPU);
  printf("[FFN] %s B=%u K=%u P=%u stages=%u kt=%u pt=%u strips=%u steps=%u ks=%u ksplit=%u "
         "kgroup=%u xrep=%u\n",
         QP_NAME, (unsigned)QWEN_B, (unsigned)QWEN_K, (unsigned)QWEN_P, (unsigned)QWEN_STAGES_N,
         (unsigned)QWEN_KT, (unsigned)QWEN_PT, (unsigned)QWEN_NSTRIPS, (unsigned)QWEN_STEPS,
         (unsigned)KERNEL_SIZE, (unsigned)QWEN_KSPLIT, (unsigned)FFN_KSPLIT_XGROUP,
         (unsigned)QWEN_X_REPLICAS);
#if MSHR_RUNTIME_CFG
  uint32_t bad = 0;
  for (uint32_t g = 0; g < (uint32_t)NUM_GROUPS; ++g) bad |= ph_mshr_status[g];
  printf("[FFN] %s MSHR share burst=%u single=%u pblocks=%u | subs=%u/%u reuse=%u%s%s%s\n",
         QP_NAME, (unsigned)ph_share_burst, (unsigned)ph_share_single, (unsigned)ph_pblocks,
         (unsigned)ph_cfg.hold_subs_single, (unsigned)ph_cfg.hold_subs_burst,
         (unsigned)ph_cfg.cache_reuse_target, ph_split_bad ? " SPLIT MISMATCH" : "",
         ph_align_bad ? " UNALIGNED" : "", bad ? " cfg REJECTED" : "");
#endif
  printf("[FFN] %s cycles=%u ideal=%u eff=%u%%o\n", QP_NAME, (unsigned)cycles, (unsigned)ideal,
         (unsigned)(ideal * 1000ull / (cycles ? cycles : 1u)));
  printf("[FFN] %s tile_cyc", QP_NAME);
  for (uint32_t i = 0; i < QWEN_SEQ_TOTAL; ++i)
    printf("%s%u", i ? "," : "=", (unsigned)(qwen_tile_ts[i] - (i ? qwen_tile_ts[i - 1] : ph_t_pass)));
  printf("\n");
}
