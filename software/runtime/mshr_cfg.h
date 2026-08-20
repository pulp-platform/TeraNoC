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

#endif // MSHR_CFG_H
