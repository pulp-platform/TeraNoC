// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
// Where data lives in the word-interleaved L1, for the Qwen mixer kernels
// (docs/qwen3_8_27b/mixer_plan.md, D6 and section 3).
//
// Consecutive L1 bytes go bank -> tile -> group: a tile owns QC_SLOT_B contiguous bytes of
// every sweep, a group QC_GSLICE_B, and the pattern repeats every QC_SWEEP_B. Derived from
// the runtime's geometry, never hard-coded (CLAUDE.md scaling checklist):
//
//            4x4 (16 groups)   8x8 (64 groups)
//   slot     64 B              64 B             16 banks x 4 B: one word per bank
//   gslice   1 KiB             1 KiB
//   sweep    16 KiB            64 KiB
//
// A buffer aligned to QC_SWEEP_B gives core c (one core per tile) the slot at byte offset
// c * QC_SLOT_B of every sweep: qc_slot(base, s, c). A vector access inside one slot touches
// only that core's own tile.
#ifndef QC_LAYOUT_H
#define QC_LAYOUT_H

#include <stdint.h>

#ifndef QC_HOST
#include "runtime.h"
#endif

#define QC_SLOT_B (4u * (NUM_CORES_PER_TILE) * (BANKING_FACTOR) * (N_FU))
#define QC_GSLICE_B (QC_SLOT_B * (NUM_TILES_PER_GROUP))
#define QC_SWEEP_B (QC_GSLICE_B * (NUM_GROUPS))
#define QC_SLOT_F16 (QC_SLOT_B / 2u)  // 32 fp16 per slot

#if NUM_CORES_PER_TILE != 1
#error "qc_layout.h assumes one core per tile (the Spatz flavours)"
#endif

// L1 placement aligned to a whole sweep, so slot offsets are the same in every sweep.
#define QC_L1_SWEEP __attribute__((section(".l1_prio"), aligned(QC_SWEEP_B)))

// The slot of core `cid` in sweep `s` of a sweep-aligned buffer.
static inline void *qc_slot(void *base, uint32_t s, uint32_t cid) {
  return (uint8_t *)base + s * QC_SWEEP_B + cid * QC_SLOT_B;
}

static inline uint32_t qc_group_of(uint32_t cid) { return cid / NUM_TILES_PER_GROUP; }
static inline uint32_t qc_tile_in_group(uint32_t cid) { return cid % NUM_TILES_PER_GROUP; }

#endif  // QC_LAYOUT_H
