// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
//==============================================================================
// qwen-ffn: ONE phase of the fused FFN, compiled twice.
//==============================================================================
//
//   phase_gu.c (FFN_PHASE_GU):  G = X . Wg, U = X . Wu, then H = SiLU(G) * U on each core's
//                               own output patch, straight into the H replicas
//   phase_dn.c (FFN_PHASE_DN):  Y = H . Wd
//
// The two phases have different shapes, and gemm_config.h / mshr_cfg.h derive the kernel size,
// split and MSHR tuning from GEMM_M/N/P at compile time -- hence one translation unit each, with
// that phase's generated headers (<phase>/data/qwen_shape.h, qwen_tiles.h, qwen_hash.h) on the
// include path and its exported symbols prefixed gu_ / dn_ (ffn.h).
//
// The pipeline is qwen-ffn-down's (itself qwen-gate-up's): K tiles streamed by one DMA into a
// double buffer, the decode split, the K split inside or across groups, the fp16 C. What is
// shared between the phases is in ffn.h: the W area (the stream runs on from the last gate+up
// tile into the first down tile) and H. Parked qwen-ffn-down features are left out: the fp32 C,
// the piece-wise first tile (the continuous stream makes it moot), the G/U staging and checks
// 3/4.
//
//==============================================================================

#include <stddef.h>
#include <stdint.h>

#ifndef FFN_PHASE_GU
#define FFN_PHASE_GU 0
#endif
#ifndef FFN_PHASE_DN
#define FFN_PHASE_DN 0
#endif

#if FFN_PHASE_GU
#define FFN_PFX(x) gu_##x
#define FFN_NAME "gate+up"
#elif FFN_PHASE_DN
#define FFN_PFX(x) dn_##x
#define FFN_NAME "down"
#else
#error "Compile phase.c through phase_gu.c or phase_dn.c"
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
// The kernels are global functions; each phase compiles its own copy (its own KERNEL_SIZE and
// shape macros), so prefix them to keep the two copies apart at link time.
#if FFN_PHASE_GU
#define matmul_1xVL gu_matmul_1xVL
#define matmul_2xVL gu_matmul_2xVL
#define matmul_4xVL gu_matmul_4xVL
#define matmul_8xVL gu_matmul_8xVL
#else
#define matmul_1xVL dn_matmul_1xVL
#define matmul_2xVL dn_matmul_2xVL
#define matmul_4xVL dn_matmul_4xVL
#define matmul_8xVL dn_matmul_8xVL
#endif
#include "kernel/qwen-fmatmul.c"
#if FFN_PHASE_GU
#include "swiglu.h"
#endif

#include "printf.h"
#include "runtime.h"
#include "synchronization.h"
#include "encoding.h"
// runtime/dma.h defines two of its functions without `static`; each phase gets its own copy.
#define dma_memcpy_nonblocking FFN_PFX(dma_memcpy_nonblocking)
#define dma_memcpy_blocking FFN_PFX(dma_memcpy_blocking)
#include "dma.h"

#include "ffn.h"


#define QWEN_STEPS ((QWEN_K) / (QWEN_KT))
#define QWEN_GROUP_HELPER 1u
#ifndef QWEN_DMA_CORE
#define QWEN_DMA_CORE 0u
#endif
#ifndef QWEN_PRELOAD
#define QWEN_PRELOAD 0
#endif

_Static_assert(GEMM_ELEM_BYTES == 2, "fp16 only");
_Static_assert(!QWEN_ACC32 && !QWEN_SWIGLU && FFN_PRIME_SPLIT == 1,
               "qwen-ffn uses the fp16 C, no SwiGLU prologue and a whole first tile per phase");
_Static_assert((QWEN_K % QWEN_KT) == 0 && (QWEN_KT % 2) == 0, "K tiles must tile K, even rows");
_Static_assert((QWEN_KT % (2 * QWEN_KSPLIT)) == 0, "Each K part must be an even number of rows");
#if QWEN_KSPLIT > 1
_Static_assert((QWEN_KSPLIT & (QWEN_KSPLIT - 1)) == 0 && QWEN_KSPLIT <= 16, "ks: 2^n <= 16");
_Static_assert(MATMUL_DECODE_SPLIT, "The K split exists only in the decode split");
_Static_assert(QWEN_NSTRIPS == 1 || FFN_PHASE_GU,
               "Down reduces after the last tile, but writes a strip back inside that tile's "
               "barrier: one strip under a K split");
_Static_assert(GBAR_PLOOP, "The reduction rendezvouses on the GBAR_PLOOP struct");
#endif
_Static_assert((QWEN_LDP % QWEN_STRIPE_E) == 0 && (QWEN_WPAD % QWEN_STRIPE_E) == 0,
               "Rows must start on a burst boundary");
_Static_assert(QWEN_PT_LEGAL_K(QWEN_KT, QWEN_PT), "Illegal strip width for this phase");
_Static_assert(QWEN_WSLOT <= FFN_WREG_ELEMS, "This phase's W slot does not fit the shared region");
_Static_assert((QWEN_STEPS % 2) == 0, "The continuous stream needs an even K-tile count");
#if FFN_PHASE_GU
_Static_assert(QWEN_STAGES_N == 2 && QWEN_P == FFN_DN_K && QWEN_LDP == QWEN_P,
               "gate+up: two projections whose output width is down's K, unpadded");
_Static_assert(((QWEN_NSTRIPS * 2 * QWEN_STEPS) % 2) == 0,
               "Down's tile 0 must land in region 0: an even gate+up tile count");
#else
_Static_assert(QWEN_STAGES_N == 1, "down: one projection");
_Static_assert(QWEN_X_ELEMS == FFN_H_ELEMS && QWEN_LDX == FFN_H_LDX &&
                   QWEN_X_REPLICAS == FFN_H_REPLICAS && QWEN_X_STRIDE_E == FFN_H_STRIDE_E,
               "data/ffn_shared.h is stale: it must describe this phase's A operand");
#endif

//==============================================================================
// Storage
//==============================================================================

#define QWEN_L1 __attribute__((section(".l1_prio"), aligned(QWEN_MESH_SWEEP)))
#define QWEN_L2 __attribute__((section(".l2_bss"), aligned(QWEN_MESH_SWEEP)))

#if QWEN_PRELOAD
// Written by the host (script/gen_operands_<phase>.c) and placed by data/<phase>_operands.S.
extern elem_t FFN_PFX(w_l2)[QWEN_STAGES_N][QWEN_WTILES * QWEN_WSLOT];
#define qwen_w_l2 FFN_PFX(w_l2)
#if FFN_PHASE_GU
extern elem_t gu_x_l2[QWEN_B * QWEN_LDX];
#define qwen_x_l2 gu_x_l2
#endif
#else
static elem_t qwen_w_l2[QWEN_STAGES_N][QWEN_WTILES * QWEN_WSLOT] QWEN_L2;
#if FFN_PHASE_GU
static elem_t qwen_x_l2[QWEN_B * QWEN_LDX] QWEN_L2;
#endif
#endif

// The two W regions, shared with the other phase (ffn.h). Tile t of any projection is in t & 1.
// Arithmetic, not a pointer table: a const table sits in .rodata (L2), one load per K tile.
#define QWEN_W(slot) (ffn_w_area + (uint32_t)(slot) * (uint32_t)FFN_WREG_ELEMS)
static elem_t qwen_c[QWEN_STAGES_N][QWEN_CSLOT] QWEN_L1;  // C, one strip
#if QWEN_KSPLIT > 1
static elem_t qwen_cp[QWEN_KSPLIT - 1][QWEN_CSLOT] QWEN_L1;  // K parts 1.. partial sums
#endif
#if FFN_PHASE_GU
static elem_t qwen_x[QWEN_X_ELEMS] QWEN_L1;  // X, replicated
#else
#define qwen_x ffn_h                         // H is the A operand
#if QWEN_NSTRIPS > 1
static elem_t qwen_out_l2[QWEN_NSTRIPS * QWEN_B * QWEN_LDW] QWEN_L2;  // Y strips
#endif
#endif

static uint32_t qwen_tile_ts[QWEN_NSTRIPS * QWEN_STAGES_N * QWEN_STEPS];
static uint32_t qwen_fmac_core[NUM_CORES];

// This core's split lives in the caller's ffn_split_t, on the core's own stack: a per-core array
// here would sit in interleaved L1, and every core reading its entry is a remote single load
// with one reader -- the live MSHR holds each for its whole hold window (~8k cycles) waiting for
// a merge partner, measured as ~90k cycles at the start of every projection (GVSoC).
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
static inline void ffn_sync(uint32_t cid) {
  __asm__ volatile("fence" ::: "memory");
  qwen_barrier(cid);
}

static inline void ffn_mshr_enable(uint32_t on) {
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

#if FFN_PHASE_DN
// The stream's hand-over: gate+up's last two pipeline barriers launch down's tiles 0 and 1, into
// the regions gate+up has just left (its tile count is even, so down's tile t lands in t & 1).
void dn_refill_head(uint32_t j) {
  if (j < QWEN_SEQ_TOTAL) qwen_refill_seq(j);
}
#if QWEN_NSTRIPS > 1
static void qwen_writeback_dma(uint32_t strip) {
  dma_memcpy_nonblocking(qwen_out_l2 + strip * (uint32_t)(QWEN_B * QWEN_LDW), qwen_c[0],
                         (size_t)(QWEN_B * QWEN_LDW) * GEMM_ELEM_BYTES);
  dma_wait();
}
#endif
#endif

//==============================================================================
// K split
//==============================================================================

// The sub-patch of (rows, columns) a K part finalises: by rows when they divide, else columns.
static inline void ffn_subpatch(uint32_t kpart, uint32_t m_start, uint32_t m_end,
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
#define QWEN_KS_SYNC() ffn_sync(cid)
#else
  if (m_end == m_start) return;
  const uint32_t gb = gbar_base(GBAR_PLOOP_STRUCT);
#define QWEN_KS_SYNC() gbar_sync_drain(gb)
  (void)cid;
#endif
  uint32_t r0, r1, c0, c1;
  ffn_subpatch(kpart, m_start, m_end, p_start, p_end, &r0, &r1, &c0, &c1);
  elem_t *c = qwen_c[stage];
  QWEN_KS_SYNC();
  ffn_mshr_enable(0u);
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
  ffn_mshr_enable(1u);
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
                         const ffn_split_t *sp) {
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
#if FFN_PHASE_GU
    // The stream does not stop at the end of gate+up: its last two barriers wait for and launch
    // down's tiles 0 and 1 (dn_refill_head).
    const uint32_t pending = 1u, launch = 1u, wb = 0u;
#else
    const uint32_t pending = (seq + 1u < QWEN_SEQ_TOTAL);
    const uint32_t launch = (seq + 2u < QWEN_SEQ_TOTAL);
    const uint32_t wb = (QWEN_NSTRIPS > 1) && (step + 1u == (uint32_t)QWEN_STEPS);
    if (wb) __asm__ volatile("fence" ::: "memory");
#endif
    uint32_t bar = qwen_dma_log_barrier(QWEN_RADIX, cid, pending);
    if (bar) {
      qwen_tile_ts[seq] = mempool_get_timer();
      if (pending) dma_wait();
#if FFN_PHASE_DN && QWEN_NSTRIPS > 1
      if (wb) qwen_writeback_dma(strip);
#endif
      (void)wb;
      if (launch) {
        if (seq + 2u < QWEN_SEQ_TOTAL) qwen_refill_seq(seq + 2u);
#if FFN_PHASE_GU
        else dn_refill_head(seq + 2u - QWEN_SEQ_TOTAL);
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

#if FFN_PHASE_GU
//==============================================================================
// The fused SwiGLU epilogue
//==============================================================================
// After both projections of a strip are reduced, C[0] = G and C[1] = U hold this core's patch
// (its sub-patch under the K split: the one its own reduction finalised). H = SiLU(G) * U goes
// straight into every H replica at column strip * PT + p: no G/U in L2, no staging. MSHR off
// around it -- these reads have one reader each. The closing rendezvous also keeps the next
// strip's partial stores off C until every core has read it. After the last strip the MSHR is
// left off: the down phase writes its own tuning (dn_mshr_apply).
static void ffn_swiglu_strip(uint32_t cid, uint32_t strip, uint32_t last, const ffn_split_t *sp) {
  uint32_t r0, r1, c0, c1;
  ffn_subpatch(sp->kpart, sp->m_start, sp->m_end, sp->p_start, sp->p_end, &r0, &r1, &c0, &c1);
  ffn_sync(cid);
  ffn_mshr_enable(0u);
  ffn_sync(cid);
  for (uint32_t r = r0; r < r1 && c1 > c0; ++r)
    swiglu_f16(qwen_c[0] + r * (uint32_t)QWEN_LDW + c0, qwen_c[1] + r * (uint32_t)QWEN_LDW + c0,
               ffn_h + r * (uint32_t)FFN_H_LDX + strip * (uint32_t)QWEN_PT + c0, c1 - c0,
               (uint32_t)FFN_H_REPLICAS, (uint32_t)FFN_H_STRIDE_E);
  ffn_sync(cid);
  if (!last) {
    ffn_mshr_enable(1u);
    ffn_sync(cid);
  }
}
#endif

//==============================================================================
// Setup (outside the timed region)
//==============================================================================

int FFN_PFX(setup)(uint32_t cid, ffn_split_t *sp) {
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
#error "qwen-ffn runs the decode split"
#endif
  if (cid >= active_cores) m_start = m_end = p_start = p_end = 0;
  sp->m_start = m_start; sp->m_end = m_end;
  sp->p_start = p_start; sp->p_end = p_end; sp->kpart = kpart;
  if (cid == 0) { ph_share_burst = share_burst; ph_share_single = share_single; ph_pblocks = pblocks; }
  qwen_fmac_core[cid] = (p_end - p_start) * (m_end - m_start) * (uint32_t)QWEN_NSTRIPS *
                        (uint32_t)(QWEN_K / QWEN_KSPLIT) * (uint32_t)QWEN_STAGES_N;

#if FFN_PHASE_GU
  // X into its replicas (in the fused layer it is the previous block's output, already in L1).
  if (cid == (uint32_t)QWEN_DMA_CORE) {
    for (uint32_t r = 0; r < (uint32_t)QWEN_X_REPLICAS; ++r) {
      dma_memcpy_nonblocking(qwen_x + r * (uint32_t)QWEN_X_STRIDE_E, qwen_x_l2,
                             (size_t)(QWEN_B * QWEN_LDX) * GEMM_ELEM_BYTES);
      dma_wait();
    }
  }
  // One group-barrier struct serves both phases (same group, same target).
#if GBAR_PLOOP
  if (cid < active_cores && core_gid == QWEN_GROUP_HELPER) {
    const uint32_t gmask = (cores_per_group >= 32u) ? 0xFFFFFFFFu : ((1u << cores_per_group) - 1u);
    gbar_setup(GBAR_PLOOP_STRUCT, cores_per_group, gmask);
  }
#endif
#endif

  // I$ warm-up of this phase's kernel copy (and of the epilogue), on W region 0: its contents
  // are whatever is there, the results are discarded.
#if ICACHE_WARMUP
  {
    const elem_t *x_use = qwen_x + (uint32_t)QWEN_X_REPLICA_OF(gid) * (uint32_t)QWEN_X_STRIDE_E;
    const uint32_t warm = (QWEN_KT < 6u) ? (uint32_t)QWEN_KT : 6u;
    qwen_kernel(qwen_c[0], x_use, QWEN_W(0), m_start, m_end, warm, p_start, p_end, 0, 0u);
  }
#endif

#if MSHR_RUNTIME_CFG
  // This phase's tuning, from its own derivation; written by dn_mshr_apply / gu_prime.
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

#if MSHR_RUNTIME_CFG
// This group's bank-hash triple, packed (both phases compare them at the handover).
uint32_t FFN_PFX(bank_sel)(uint32_t g) {
  return (uint32_t)qwen_hash_sel[g][0] | ((uint32_t)qwen_hash_sel[g][1] << 8) |
         ((uint32_t)qwen_hash_sel[g][2] << 16);
}

// This phase's tuning into this group's CSRs, enabled. Group helper only; the caller barriers.
// At boot (gate+up) the MSHR is empty and mshr_cfg_apply_group writes everything. At the
// handover (down) it is not: lines gate+up left in the response cache stay until their serve
// timeout, and a bank-hash write while any entry is resident is refused (MSHR_STATUS_BANK_BUSY,
// old hash kept). So the down phase writes the hold / reuse / timeout fields straight away and
// the bank hash only where it differs from gate+up's -- retrying until the entries have drained.
static void ffn_mshr_apply(uint32_t cid, uint32_t at_handover) {
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
  if (gu_bank_sel(gid) != FFN_PFX(bank_sel)(gid)) {
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

#if FFN_PHASE_GU
// The pipeline's log barrier for main.c (mempool_barrier's single counter costs ~14k cycles at
// 8x8), with this core's vector stores drained first.
void ffn_barrier(uint32_t cid) { ffn_sync(cid); }
#else
// MSHR off in this group (after the region: the epilogue's loads have one reader each).
void ffn_mshr_off(void) { ffn_mshr_enable(0u); }
#endif

#if FFN_PHASE_GU
// Tiles 0 and 1 of the stream (before the region: nothing to overlap), and gate+up's tuning.
void gu_prime(uint32_t cid) {
  if (cid == (uint32_t)QWEN_DMA_CORE) {
    qwen_refill(0, 0, 0, 0);
    dma_wait();
    qwen_refill_seq(1);
  }
#if MSHR_RUNTIME_CFG
  ffn_mshr_apply(cid, 0u);
#endif
}

void gu_run(uint32_t cid, const ffn_split_t *sp) {
  const elem_t *x_use =
      qwen_x + (uint32_t)QWEN_X_REPLICA_OF(cid / (NUM_CORES / NUM_GROUPS)) * (uint32_t)QWEN_X_STRIDE_E;
  ph_t_pass = mempool_get_timer();
  for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip) {
    qwen_project(0, strip, cid, x_use, sp);  // gate
    qwen_project(1, strip, cid, x_use, sp);  // up
    ffn_swiglu_strip(cid, strip, strip + 1u == (uint32_t)QWEN_NSTRIPS, sp);
  }
}
#else
void dn_mshr_apply(uint32_t cid) {
#if MSHR_RUNTIME_CFG
  ffn_mshr_apply(cid, 1u);
#else
  (void)cid;
#endif
}

void dn_run(uint32_t cid, const ffn_split_t *sp) {
  const elem_t *x_use =
      qwen_x + (uint32_t)QWEN_X_REPLICA_OF(cid / (NUM_CORES / NUM_GROUPS)) * (uint32_t)QWEN_X_STRIDE_E;
  ph_t_pass = mempool_get_timer();
  for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip)
    qwen_project(0, strip, cid, x_use, sp);
}
#endif

//==============================================================================
// Report and check
//==============================================================================

uint64_t FFN_PFX(macs)(void) {
  return (uint64_t)QWEN_STAGES_N * QWEN_B * QWEN_K * QWEN_P;
}

void FFN_PFX(report)(uint32_t cid, uint32_t cycles) {
  if (cid != 0) return;
  const uint64_t ideal = FFN_PFX(macs)() / ((uint64_t)NUM_CORES * 2u * N_FPU);
  printf("[FFN] %s B=%u K=%u P=%u stages=%u kt=%u pt=%u strips=%u steps=%u ks=%u ksplit=%u "
         "kgroup=%u xrep=%u\n",
         FFN_NAME, (unsigned)QWEN_B, (unsigned)QWEN_K, (unsigned)QWEN_P, (unsigned)QWEN_STAGES_N,
         (unsigned)QWEN_KT, (unsigned)QWEN_PT, (unsigned)QWEN_NSTRIPS, (unsigned)QWEN_STEPS,
         (unsigned)KERNEL_SIZE, (unsigned)QWEN_KSPLIT, (unsigned)FFN_KSPLIT_XGROUP,
         (unsigned)QWEN_X_REPLICAS);
#if MSHR_RUNTIME_CFG
  uint32_t bad = 0;
  for (uint32_t g = 0; g < (uint32_t)NUM_GROUPS; ++g) bad |= ph_mshr_status[g];
  printf("[FFN] %s MSHR share burst=%u single=%u pblocks=%u | subs=%u/%u reuse=%u%s%s%s\n",
         FFN_NAME, (unsigned)ph_share_burst, (unsigned)ph_share_single, (unsigned)ph_pblocks,
         (unsigned)ph_cfg.hold_subs_single, (unsigned)ph_cfg.hold_subs_burst,
         (unsigned)ph_cfg.cache_reuse_target, ph_split_bad ? " SPLIT MISMATCH" : "",
         ph_align_bad ? " UNALIGNED" : "", bad ? " cfg REJECTED" : "");
#endif
  printf("[FFN] %s cycles=%u ideal=%u eff=%u%%o\n", FFN_NAME, (unsigned)cycles, (unsigned)ideal,
         (unsigned)(ideal * 1000ull / (cycles ? cycles : 1u)));
  printf("[FFN] %s tile_cyc", FFN_NAME);
  for (uint32_t i = 0; i < QWEN_SEQ_TOTAL; ++i)
    printf("%s%u", i ? "," : "=", (unsigned)(qwen_tile_ts[i] - (i ? qwen_tile_ts[i - 1] : ph_t_pass)));
  printf("\n");
}

#if FFN_PHASE_DN
// Check 1 (end to end): Y against down's multi-hot expectation -- H is exactly that pattern when
// gate+up and SwiGLU are right (script/gen_operands_gu.c). Integer compares only.
#if QWEN_CHECK == 1
static volatile uint32_t ffn_bad, ffn_bad_b, ffn_bad_p, ffn_bad_got, ffn_bad_want;
#endif
int dn_verify(uint32_t cid) {
#if QWEN_CHECK == 1
  const uint32_t num_cores = mempool_get_core_count();
  if (cid == 0) ffn_bad = 0;
  qwen_barrier(cid);
  for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip) {
#if QWEN_NSTRIPS > 1
    if (cid == (uint32_t)QWEN_DMA_CORE)
      dma_memcpy_blocking(qwen_c[0], qwen_out_l2 + strip * (uint32_t)(QWEN_B * QWEN_LDW),
                          (size_t)(QWEN_B * QWEN_LDW) * GEMM_ELEM_BYTES);
    qwen_barrier(cid);
#endif
    uint32_t cached = 0xffffffffu;
    uint16_t want3[3] = {0, 0, 0};
    for (uint32_t i = cid; i < (uint32_t)(QWEN_B * QWEN_PT); i += num_cores) {
      const uint32_t b = i / (uint32_t)QWEN_PT, col = i % (uint32_t)QWEN_PT;
      const uint32_t p = strip * (uint32_t)QWEN_PT + col;
      if (p >= (uint32_t)QWEN_P) continue;
      if (cached != b) {
        cached = b;
        for (uint32_t m = 0; m < 3u; ++m) want3[m] = qwen_eighths_to_fp16(qwen_expect_eighths(0, b, m));
      }
      const uint16_t e = want3[p % 3u], v = ((const uint16_t *)qwen_c[0])[b * QWEN_LDW + col];
      if (v != e && __atomic_fetch_add(&ffn_bad, 1u, __ATOMIC_RELAXED) == 0u) {
        ffn_bad_b = b; ffn_bad_p = p; ffn_bad_got = v; ffn_bad_want = e;
      }
    }
    qwen_barrier(cid);
  }
  if (cid == 0) {
    if (ffn_bad)
      printf("FAIL: %u/%u outputs wrong; first at b=%u p=%u got=0x%04x want=0x%04x\n",
             (unsigned)ffn_bad, (unsigned)(QWEN_B * QWEN_P), (unsigned)ffn_bad_b,
             (unsigned)ffn_bad_p, (unsigned)ffn_bad_got, (unsigned)ffn_bad_want);
    else
      printf("success!\n");
  }
  return ffn_bad ? -1 : 0;
#else
  (void)cid;
  return 0;
#endif
}
#endif
