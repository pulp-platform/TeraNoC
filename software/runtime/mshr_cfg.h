// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Group MSHR runtime configuration.
//
// Written through the group-barrier port's unused op encoding (bank field == 3), so this costs no
// new address space and no new crossbar decode. See docs/mshr_runtime_csr_design.md for the map and
// hardware/src/mempool_group_mshr_cfg.sv for the register file.
//
// Address form:  (GROUP_BARRIER_WORD + csr) * WORD_STRIDE
//              | (group * GROUP_STRIDE)
//              | (tile  << 6)
//              | (3 << 2)                      <- bank field selects the MSHR-CSR op
//
// The write must target a tile in the destination group OTHER than our own: a same-tile access is
// TCDM_LOCAL and never reaches the group crossbar, so it would never arrive.

#ifndef MSHR_CFG_H
#define MSHR_CFG_H

#include <stdint.h>
#include "encoding.h"
#include "runtime.h"

// ---- CSR indices. Mirror mempool_pkg.sv's MSHR_CSR_* -- keep the two in step. ----------------
#define MSHR_CSR_ENABLE             0
#define MSHR_CSR_HOLD_SUBS_SINGLE   1
#define MSHR_CSR_HOLD_SUBS_BURST    2
#define MSHR_CSR_HOLD_WINDOW_SINGLE 3
#define MSHR_CSR_HOLD_WINDOW_BURST  4
#define MSHR_CSR_BANK_SHIFT_SINGLE  5
#define MSHR_CSR_BANK_SHIFT_BURST   6
#define MSHR_CSR_BANK_BURST_BITS    7
#define MSHR_CSR_SERVE_TIMEOUT      8   // response-side, SINGLE-only; NOT the hold window
#define MSHR_CSR_CACHE_REUSE_TARGET 9   // 0 = legacy: self-invalidate at hold_subs_*
#define MSHR_CSR_CACHE_TIMEOUT     10   // 0 = legacy: cache phase re-arms from serve_timeout
#define MSHR_CSR_STATUS            15   // read: sticky errors; write: clear

// ---- CFG_STATUS sticky bits. Non-zero means the config in effect is NOT the one requested. -----
#define MSHR_STATUS_BANK_BUSY    (1u << 0)  // bank-hash write refused: MSHR was not empty
#define MSHR_STATUS_RANGE        (1u << 1)  // value out of range, write dropped
#define MSHR_STATUS_TIMEOUT_ZERO (1u << 2)  // serve_timeout=0 refused (would pin a cache way)
#define MSHR_STATUS_BAD_INDEX    (1u << 3)  // write to an undefined CSR index

// ---- Address arithmetic --------------------------------------------------------------------
// DERIVED, never hardcoded. The word field sits above group|tile|bank|byte, so its stride depends
// on every field below it: 16384 at 16 groups, 65536 at 64. A hardcoded <<14 in sp-fmatmul.c made
// the group barrier a SILENT no-op across the entire 8x8 campaign -- no hang, no error, just no
// synchronisation. Same derivation as runtime/arch.ld.c.
#define MSHR_BANKS_PER_TILE (N_FU * BANKING_FACTOR * NUM_CORES_PER_TILE)
#define MSHR_WORD_STRIDE    (4 * MSHR_BANKS_PER_TILE * NUM_TILES_PER_GROUP * NUM_GROUPS)
#define MSHR_GROUP_STRIDE   (4 * MSHR_BANKS_PER_TILE * NUM_TILES_PER_GROUP)
#define MSHR_TILE_STRIDE    (4 * MSHR_BANKS_PER_TILE)
#define MSHR_CSR_OP         3   // bank-field encoding claimed for MSHR CSR writes

/// One MSHR configuration. Produced per shape by scripts/gemm_autotune.py.
typedef struct {
  uint32_t hold_subs_single;    ///< [1, merge_reqs]; 1 = singles do not merge, they bypass
  uint32_t hold_subs_burst;     ///< [1, merge_reqs]; 1 = bursts do not merge, they bypass
  uint32_t hold_window_single;  ///< request-side hold, single entries (cycles)
  uint32_t hold_window_burst;   ///< request-side hold, burst entries (cycles)
  uint32_t serve_timeout;       ///< response-side, SINGLE-only (RESP_HOLD / CACHED)
  uint32_t bank_shift_single;   ///< bank-hash address bit select, singles
  uint32_t bank_shift_burst;    ///< ... bursts
  uint32_t bank_burst_bits;     ///< 0 or 1
  /// Cache reuse target. 0 = LEGACY (a CACHED line self-invalidates once served_cnt reaches
  /// hold_subs_*). Non-zero keeps the line resident until served_cnt reaches this value, so a
  /// second cohort hitting the other half of the same 32-bit word is served from the line rather
  /// than allocating a fresh entry that then waits out serve_timeout for peers already served.
  /// This is the fp16 case: two scalar fp16 loads alias one word. Legal [0, merge_reqs].
  uint32_t cache_reuse_target;
  /// CACHED-phase residency countdown. 0 = LEGACY (re-arm from serve_timeout).
  uint32_t cache_timeout;
} mshr_cfg_t;

/// The group this core belongs to.
static inline uint32_t mshr_cfg_my_group(void) { return mempool_get_group_id(); }

/// A tile in our own group that is NOT ours.
///
/// A same-tile access is TCDM_LOCAL and never reaches the group crossbar, so a CSR write aimed at
/// our own tile would simply never arrive -- silently, with no error. Pick the next tile round-robin.
static inline uint32_t mshr_cfg_peer_tile(void) {
  const uint32_t tile_in_group = mempool_get_tile_id() % NUM_TILES_PER_GROUP;
  return (tile_in_group + 1) % NUM_TILES_PER_GROUP;
}

/// True for exactly one core per group -- the designated CSR writer.
///
/// Every group owns its own MSHR and there is no broadcast, so all NUM_GROUPS must be programmed.
/// One writer per group, in parallel, then a barrier.
static inline int mshr_cfg_is_group_writer(void) {
  return (mempool_get_core_id() % (NUM_CORES / NUM_GROUPS)) == 0;
}

/// Write one CSR of one group. `tile` must be a tile in `group` other than the caller's own.
static inline void mshr_cfg_write(uint32_t group, uint32_t tile, uint32_t csr, uint32_t val) {
  volatile uint32_t *p = (volatile uint32_t *)(uintptr_t)(
      ((GROUP_BARRIER_WORD + csr) * MSHR_WORD_STRIDE) +
      (group * MSHR_GROUP_STRIDE) + (tile * MSHR_TILE_STRIDE) +
      (MSHR_CSR_OP * 4));
  *p = val;
}

/// Read CFG_STATUS of one group. Zero means every write was accepted.
static inline uint32_t mshr_cfg_status(uint32_t group, uint32_t tile) {
  volatile uint32_t *p = (volatile uint32_t *)(uintptr_t)(
      ((GROUP_BARRIER_WORD + MSHR_CSR_STATUS) * MSHR_WORD_STRIDE) +
      (group * MSHR_GROUP_STRIDE) + (tile * MSHR_TILE_STRIDE) +
      (MSHR_CSR_OP * 4));
  return *p;
}

/// Program this core's own group and enable the MSHR.
///
/// ORDERING IS NOT OPTIONAL: disable -> drain -> bank hash -> the rest -> enable. The bank-hash
/// CSRs are REFUSED by hardware unless the MSHR is empty, because the bank index both places an
/// entry and looks it up -- re-hashing with entries resident makes a lookup probe the wrong bank
/// and a second entry gets allocated for a line that already has one. Writing them while enabled
/// silently sets MSHR_STATUS_BANK_BUSY and leaves the old hash in place.
///
/// Returns CFG_STATUS: 0 = every write accepted, non-zero = the configuration in effect is NOT the
/// one requested. Callers must check it. A configuration that silently differs from the requested
/// one is the exact failure that invalidated three measurement runs on 2026-08-14.
static inline uint32_t mshr_cfg_apply_group(const mshr_cfg_t *c) {
  const uint32_t g    = mshr_cfg_my_group();
  const uint32_t tile = mshr_cfg_peer_tile();

  mshr_cfg_write(g, tile, MSHR_CSR_ENABLE, 0);          // quiesce: bank-hash needs an empty MSHR
  mshr_cfg_write(g, tile, MSHR_CSR_STATUS, 0);          // clear stale sticky bits
  __asm__ volatile("fence" ::: "memory");               // let resident entries drain

  mshr_cfg_write(g, tile, MSHR_CSR_BANK_SHIFT_SINGLE, c->bank_shift_single);
  mshr_cfg_write(g, tile, MSHR_CSR_BANK_SHIFT_BURST,  c->bank_shift_burst);
  mshr_cfg_write(g, tile, MSHR_CSR_BANK_BURST_BITS,   c->bank_burst_bits);
  mshr_cfg_write(g, tile, MSHR_CSR_HOLD_SUBS_SINGLE,  c->hold_subs_single);
  mshr_cfg_write(g, tile, MSHR_CSR_HOLD_SUBS_BURST,   c->hold_subs_burst);
  mshr_cfg_write(g, tile, MSHR_CSR_HOLD_WINDOW_SINGLE,c->hold_window_single);
  mshr_cfg_write(g, tile, MSHR_CSR_HOLD_WINDOW_BURST, c->hold_window_burst);
  mshr_cfg_write(g, tile, MSHR_CSR_SERVE_TIMEOUT,     c->serve_timeout);
  mshr_cfg_write(g, tile, MSHR_CSR_CACHE_REUSE_TARGET,c->cache_reuse_target);
  mshr_cfg_write(g, tile, MSHR_CSR_CACHE_TIMEOUT,     c->cache_timeout);

  mshr_cfg_write(g, tile, MSHR_CSR_ENABLE, 1);          // arm last
  __asm__ volatile("fence" ::: "memory");
  return mshr_cfg_status(g, tile);
}

// ---------------------------------------------------------------------------------------------
// RUNTIME DERIVATION of the per-shape MSHR tuning, from M/N/P.
//
// Replaces the per-shape config/terapool_spatz4_fpu_gemm<M>x<N>x<P>.mk files: the group's
// setting core computes the same numbers those files carried. Mirrors scripts/gemm_autotune.py
// derive() exactly -- validated against all 28 per-shape .mk files and both precisions.
// TIMEOUTS ARE NOT DERIVED: hold_window_*, serve_timeout and the cache_* knobs stay macro-fed,
// because they are latency/liveness policy, not a function of the data shape.
//
// KEEP IN STEP with gemm_autotune.py; the split arithmetic also mirrors main.c's own
// dim_group / split_m_count / split_p_count (mshr_cfg_check_splits below asserts they agree,
// so a divergence fails loudly instead of quietly mistuning the hash).
// ---------------------------------------------------------------------------------------------

/// ceil(log2(x)); clog2(0)=clog2(1)=0.
static inline uint32_t mshr_clog2(uint32_t x) {
  return (x <= 1u) ? 0u : (uint32_t)(32 - __builtin_clz(x - 1u));
}

#ifndef MSHR_MAX_BURST_WORDS
#define MSHR_MAX_BURST_WORDS 16u   // MaxBurstWords: the VLSU's 16-word burst
#endif
#ifndef MSHR_ELEN
#define MSHR_ELEN 32u              // memory word width in bits (NOT the element width)
#endif
// CSR-accepted bank-shift window (mempool_group_mshr_cfg.sv BankShiftMin/Max). Writing outside
// it is REFUSED and the RESET value stays in force, silently -- so clamp here rather than let
// the hardware quietly run a tuning nobody asked for.
#define MSHR_SHIFT_MIN 5u
#define MSHR_SHIFT_MAX 10u
// Hold-window MAGNITUDE is not derivable from M/N/P: the two classes carry OPPOSITE policies
// (hold_window_single is 0 -- sp-fmatmul's requesters are >60 cycles apart, so 70-85% of held
// singles time out and crowd out allocations, bank-full 42%->51% -- while hold_window_burst is
// 2047). Deriving both from the CSR field width reproduced only 1 of 28 shapes. The magnitudes
// stay macro-fed from config; the SHAPE decides only whether a class may be held at all.
// Hold-window MAGNITUDE is NOT derivable -- neither from M/N/P nor from the hardware ceiling.
// The two classes carry OPPOSITE policies: hold_window_single is 0 everywhere (singles issue
// the same cycle: sp-fmatmul's requesters are >60 cycles apart, so 70-85% of held singles time
// out, paying full latency for nothing while crowding out allocations -- bank-full overflow
// 42%->51%), while hold_window_burst is 2047. An attempt to derive both from the CSR field
// width (MshrCfgHoldCntW=11 -> 2047) reproduced only 1 of 28 shapes, because it forced the
// single class to 2047 too. The SHAPE decides only whether a class may be held at all.

/// Fill the shape-derived fields of *c. Timeout/cache fields are left untouched -- set them
/// from the MSHR_CFG_* macros before calling, or after.
/// elem_bytes: 4 for fp32, 2 for fp16.  kernel_size: the kernel's KERNEL_SIZE (selects LMUL).
/// Returns 0 on success, negative if the shape is illegal for this core count.
static inline int mshr_cfg_derive(uint32_t M, uint32_t N, uint32_t P,
                                  uint32_t elem_bytes, uint32_t kernel_size,
                                  mshr_cfg_t *c) {
  const uint32_t num_groups     = NUM_GROUPS;
  const uint32_t cores_per_group = (uint32_t)NUM_CORES / num_groups;
  if (kernel_size == 0u || num_groups == 0u) return -1;

  const uint32_t dim_group = M / num_groups;
  if (dim_group == 0u || (dim_group % kernel_size) != 0u) return -2;
  const uint32_t split_m_count = dim_group / kernel_size;
  if (split_m_count == 0u) return -3;

  uint32_t split_p_count;
  if (split_m_count < cores_per_group) {
    if ((cores_per_group % split_m_count) != 0u) return -4;
    split_p_count = cores_per_group / split_m_count;
    if (split_p_count == 0u) split_p_count = 1u;
    if ((P % split_p_count) != 0u) return -5;
  } else {
    split_p_count = 1u;               // no P split: every core owns full P
  }

  // A is shared by split_p_count cores, B by split_m_count. One entry pool serves both.
  const uint32_t share_a = split_p_count;
  const uint32_t share_b = split_m_count;
  const uint32_t merge   = (share_a > share_b) ? share_a : share_b;

  // hold_subs == 1 is the RTL's "bypass this class" encoding. share_a<=2 MUST bypass: at a
  // share degree of 2 only one other core can ever supply the partner, while A is the
  // high-volume scalar class, so held entries accumulate faster than they retire and push the
  // burst class out of the MSHR by capacity. Measured 20.1x on 1024x128x256. NON-MONOTONIC in
  // share_a (1 fine, 2 catastrophic, >=4 fine) -- do not "simplify" to min(share_a, merge).
  const uint32_t subs_a = (share_a <= 2u) ? 1u : ((share_a < merge) ? share_a : merge);
  const uint32_t subs_b = (share_b < merge) ? share_b : merge;

  // LMUL follows kernel_size: 8 -> m2, 4 -> m4, 2 -> m8.  vl_words counts 32-bit MEMORY words,
  // so it is elem-size INVARIANT -- e32,m2 and e16,m2 both move 128 B and split identically.
  const uint32_t lmul     = 16u / kernel_size;
  const uint32_t vl_words = ((uint32_t)VLEN * lmul) / MSHR_ELEN;

  // Both shifts select bits of the WORD address, but N and gap count ELEMENTS. At fp16 an
  // element is 2 B, so a stride of N elements is N/2 words and BOTH shifts drop by one.
  // Getting this wrong does not error -- the hash just picks the wrong bits and the run is
  // quietly slow (docs/mshr_bank_hash_design.md 7).
  const uint32_t gap       = P / split_p_count;
  const uint32_t n_words   = (N * elem_bytes) / 4u;
  const uint32_t gap_words = (gap * elem_bytes) / 4u;

  const uint32_t burst_bits = (vl_words > MSHR_MAX_BURST_WORDS)
                                ? mshr_clog2(vl_words / MSHR_MAX_BURST_WORDS) : 0u;
  // The burst field must sit ABOVE the burst-align bits. This floor is STRICTER than the CSR
  // window at burst_bits>=2, where the guard would accept an illegal 5.
  const uint32_t lo = mshr_clog2(MSHR_MAX_BURST_WORDS) + burst_bits;
  uint32_t burst_floor = (lo > MSHR_SHIFT_MIN) ? lo : MSHR_SHIFT_MIN;

  uint32_t sh_s = (n_words   > 0u) ? mshr_clog2(n_words)   : 0u;
  uint32_t sh_b = (gap_words > 0u) ? mshr_clog2(gap_words) : 0u;
  if (sh_s < MSHR_SHIFT_MIN) sh_s = MSHR_SHIFT_MIN;
  if (sh_s > MSHR_SHIFT_MAX) sh_s = MSHR_SHIFT_MAX;
  if (sh_b < burst_floor)    sh_b = burst_floor;
  if (sh_b > MSHR_SHIFT_MAX) sh_b = MSHR_SHIFT_MAX;

  c->hold_subs_single  = subs_a;
  c->hold_subs_burst   = subs_b;
  c->bank_shift_single = sh_s;
  c->bank_shift_burst  = sh_b;
  c->bank_burst_bits   = burst_bits;
  return 0;
}

/// Cross-check against the kernel's own work-split. Call with main.c's values; a non-zero
/// return means the two derivations have drifted apart and the tuning cannot be trusted.
static inline int mshr_cfg_check_splits(uint32_t M, uint32_t kernel_size,
                                        uint32_t split_m_count, uint32_t split_p_count) {
  const uint32_t cores_per_group = (uint32_t)NUM_CORES / (uint32_t)NUM_GROUPS;
  const uint32_t dim_group = M / (uint32_t)NUM_GROUPS;
  const uint32_t my_m = (kernel_size ? dim_group / kernel_size : 0u);
  const uint32_t my_p = (my_m && my_m < cores_per_group) ? (cores_per_group / my_m) : 1u;
  return (my_m == split_m_count && my_p == split_p_count) ? 0 : -1;
}

// ---------------------------------------------------------------------------------------------
// COMPILE-TIME derivation. Same arithmetic as mshr_cfg_derive() above, but evaluated by the
// compiler from the GEMM_* macros that data_gemm.h emits, so the cores are handed constants and
// do no division at runtime. This is what replaces the per-shape config/*_gemm<M>x<N>x<P>.mk
// files: the shape already reaches the compiler, so nothing has to be passed in from outside.
//
// Requires data_gemm.h to be included FIRST (it is: main.c includes it at the top, this header
// well below). Guarded on GEMM_M so kernels without a GEMM shape still compile.
// ---------------------------------------------------------------------------------------------
#ifdef GEMM_M
#ifndef GEMM_ELEM_BYTES
#error "GEMM_ELEM_BYTES missing -- regenerate data_gemm.h (script/gen_data.py emits it). Both MSHR bank shifts depend on element size; guessing 4 would silently mistune fp16."
#endif
// Must match the kernel's KERNEL_SIZE -- it selects LMUL, which drives vl_words, which drives
// bank_burst_bits AND the bank_shift_burst floor. main.c only DEFAULTS KernelSize far below its
// own #include of this header, so a plain build has it undefined here; a -DKERNEL_SIZE=4 override
// IS defined by then and must be honoured, or an m4 kernel would be tuned as if it were m2.
#ifndef MSHR_KERNEL_SIZE
# ifdef KERNEL_SIZE
#  define MSHR_KERNEL_SIZE KERNEL_SIZE
# else
#  define MSHR_KERNEL_SIZE 8
# endif
#endif

/// ceil(log2(x)) as an integer constant expression (clog2(0)=clog2(1)=0).
#define MSHR_CLOG2(x) ((x) <= 1 ? 0 : (x) <= 2 ? 1 : (x) <= 4 ? 2 : (x) <= 8 ? 3 : \
                       (x) <= 16 ? 4 : (x) <= 32 ? 5 : (x) <= 64 ? 6 : (x) <= 128 ? 7 : \
                       (x) <= 256 ? 8 : (x) <= 512 ? 9 : (x) <= 1024 ? 10 : (x) <= 2048 ? 11 : \
                       (x) <= 4096 ? 12 : (x) <= 8192 ? 13 : (x) <= 16384 ? 14 : \
                       (x) <= 32768 ? 15 : 16)

enum {
  MSHR_D_CPG      = NUM_CORES / NUM_GROUPS,
  MSHR_D_SPLIT_M  = (GEMM_M / NUM_GROUPS) / MSHR_KERNEL_SIZE,
  MSHR_D_SPLIT_P  = (MSHR_D_SPLIT_M > 0 && MSHR_D_SPLIT_M < MSHR_D_CPG)
                      ? (MSHR_D_CPG / MSHR_D_SPLIT_M) : 1,
  MSHR_D_MERGE    = (MSHR_D_SPLIT_P > MSHR_D_SPLIT_M) ? MSHR_D_SPLIT_P : MSHR_D_SPLIT_M,

  // share_a <= 2 MUST bypass (hold_subs==1). NON-MONOTONIC: 1 fine, 2 catastrophic, >=4 fine --
  // measured 20.1x on 1024x128x256. Do not "simplify" to min(split_p, merge).
  MSHR_D_HOLD_SUBS_SINGLE = (MSHR_D_SPLIT_P <= 2) ? 1
                          : ((MSHR_D_SPLIT_P < MSHR_D_MERGE) ? MSHR_D_SPLIT_P : MSHR_D_MERGE),
  MSHR_D_HOLD_SUBS_BURST  = (MSHR_D_SPLIT_M < MSHR_D_MERGE) ? MSHR_D_SPLIT_M : MSHR_D_MERGE,

  // HOLD WINDOWS are a hybrid: the SHAPE decides whether a class may be held at all, the macro
  // supplies how long. A share degree below 2 means no second requester for that class can ever
  // arrive, so holding buys nothing and only adds latency -- the window must be 0. Above that,
  // the right number is the expected arrival SKEW between cohort members, which is a dynamic
  // timing property (barrier alignment, memory latency, NoC congestion), NOT a function of MNP.
  // These reproduce the per-shape .mk overrides exactly: hold_window_burst=0 on M=128 shapes
  // (split_m_count==1) and hold_window_single=0 on 2048x128x256 (split_p_count==1).
  // CACHE REUSE TARGET (fp16). Two scalar fp16 loads alias one 32-bit word, so the SAME S cores
  // touch the line twice: S merges for the low half, then S hits for the high half. served_cnt
  // counts every sub-request served, so the line's useful life ends at 2S -- setting the target
  // to S would make this expression identical to the legacy operand and change nothing.
  MSHR_D_CACHE_REUSE_RAW = 2 * MSHR_D_HOLD_SUBS_SINGLE,
  // Fall back to 0 (legacy) rather than clamp, in three cases:
  //   fp32              -- one load per word, no second cohort to catch;
  //   subs_single < 2   -- the class BYPASSES, so no entry is ever allocated to cache;
  //   2S > MergeReqs    -- the CSR write would be REFUSED and the reset value would silently
  //                        stand; and clamping to MergeReqs == S is the legacy operand anyway,
  //                        while a non-zero target would ALSO override hold_subs_burst for
  //                        burst entries -- a capacity change with no matching benefit.
  MSHR_D_CACHE_REUSE_TARGET =
      (GEMM_ELEM_BYTES != 2)                        ? 0
    : (MSHR_D_HOLD_SUBS_SINGLE < 2)                 ? 0
    : (MSHR_D_CACHE_REUSE_RAW > (int)MSHR_MERGE_REQS) ? 0
    : MSHR_D_CACHE_REUSE_RAW,

  MSHR_D_HOLD_WINDOW_SINGLE = (MSHR_D_SPLIT_P < 2) ? 0 : MSHR_CFG_HOLD_WINDOW_SINGLE,
  MSHR_D_HOLD_WINDOW_BURST  = (MSHR_D_SPLIT_M < 2) ? 0 : MSHR_CFG_HOLD_WINDOW_BURST,

  MSHR_D_LMUL     = 16 / MSHR_KERNEL_SIZE,          // KERNEL_SIZE 8/4/2 -> m2/m4/m8
  MSHR_D_VL_WORDS = ((int)VLEN * MSHR_D_LMUL) / (int)MSHR_ELEN,
  MSHR_D_BANK_BURST_BITS = (MSHR_D_VL_WORDS > (int)MSHR_MAX_BURST_WORDS)
                             ? MSHR_CLOG2(MSHR_D_VL_WORDS / (int)MSHR_MAX_BURST_WORDS) : 0,

  // N and P count ELEMENTS; the hash selects WORD-address bits, so at fp16 both shifts drop one.
  MSHR_D_N_WORDS   = ((int)GEMM_N * (int)GEMM_ELEM_BYTES) / 4,
  MSHR_D_GAP_WORDS = (((int)GEMM_P / MSHR_D_SPLIT_P) * (int)GEMM_ELEM_BYTES) / 4,

  // Stricter than the CSR window: the burst field must sit above the burst-align bits.
  MSHR_D_BURST_FLOOR = ((MSHR_CLOG2((int)MSHR_MAX_BURST_WORDS) + MSHR_D_BANK_BURST_BITS)
                          > (int)MSHR_SHIFT_MIN)
                         ? (MSHR_CLOG2((int)MSHR_MAX_BURST_WORDS) + MSHR_D_BANK_BURST_BITS)
                         : (int)MSHR_SHIFT_MIN,
  MSHR_D_SH_S_RAW = MSHR_CLOG2(MSHR_D_N_WORDS),
  MSHR_D_SH_B_RAW = MSHR_CLOG2(MSHR_D_GAP_WORDS),
  // Clamp here: an out-of-window CSR write is REFUSED and the RESET value stays in force,
  // silently -- that is how 15 of 23 fp16 arms were once labelled with a tuning they never ran.
  MSHR_D_BANK_SHIFT_SINGLE = (MSHR_D_SH_S_RAW < (int)MSHR_SHIFT_MIN) ? (int)MSHR_SHIFT_MIN
                           : ((MSHR_D_SH_S_RAW > (int)MSHR_SHIFT_MAX) ? (int)MSHR_SHIFT_MAX
                                                                      : MSHR_D_SH_S_RAW),
  MSHR_D_BANK_SHIFT_BURST  = (MSHR_D_SH_B_RAW < MSHR_D_BURST_FLOOR) ? MSHR_D_BURST_FLOOR
                           : ((MSHR_D_SH_B_RAW > (int)MSHR_SHIFT_MAX) ? (int)MSHR_SHIFT_MAX
                                                                      : MSHR_D_SH_B_RAW)
};

/// Drop-in initialiser: shape-derived fields folded at compile time, timeouts from the macros.
#define MSHR_CFG_DERIVED_INIT {                          \
    .hold_subs_single   = MSHR_D_HOLD_SUBS_SINGLE,       \
    .hold_subs_burst    = MSHR_D_HOLD_SUBS_BURST,        \
    .hold_window_single = MSHR_D_HOLD_WINDOW_SINGLE,     \
    .hold_window_burst  = MSHR_D_HOLD_WINDOW_BURST,      \
    .serve_timeout      = MSHR_CFG_SERVE_TIMEOUT,        \
    .bank_shift_single  = MSHR_D_BANK_SHIFT_SINGLE,      \
    .bank_shift_burst   = MSHR_D_BANK_SHIFT_BURST,       \
    .bank_burst_bits    = MSHR_D_BANK_BURST_BITS,        \
    /* Idea 2 targets the fp16 half-word aliasing: two scalar loads hitting one 32-bit word.
       fp32 has one load per word, so there is no second cohort to catch -- gate on the element
       size so an fp32 kernel keeps the legacy path automatically instead of relying on each
       kernel to remember to zero it. */                 \
    /* An explicit -Dgroup_mshr_cache_reuse_target wins (for sweeps); otherwise use the
       shape-derived 2 x hold_subs_single. */                  \
    .cache_reuse_target = MSHR_CFG_CACHE_REUSE_TARGET          \
                            ? MSHR_CFG_CACHE_REUSE_TARGET      \
                            : MSHR_D_CACHE_REUSE_TARGET,       \
    .cache_timeout      = (GEMM_ELEM_BYTES == 2)         \
                            ? MSHR_CFG_CACHE_TIMEOUT : 0,      \
  }
#endif // GEMM_M

#endif // MSHR_CFG_H
