// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Where X lives in L1, shared by the app and by the build-time hash generator so
// the two cannot disagree about an address.
#ifndef QWEN_LAYOUT_H
#define QWEN_LAYOUT_H

#include "data/qwen_shape.h"
#include "gemm_config.h"  // KERNEL_SIZE, GEMM_PBLOCKS
#include "gemm_burst.h"   // GEMM_BURST_* geometry

#define QWEN_B GEMM_M
#define QWEN_K GEMM_N
#define QWEN_P GEMM_P

// ---- Stored width, and why it is padded ------------------------------------
//
// Elements in one 64-byte tile bank stripe (32 at fp16).
#define QWEN_STRIPE_E ((GEMM_BURST_TILE_WORDS * 4) / GEMM_ELEM_BYTES)
//
// docs/qwen3_8_27b/tile_contained_burst_hash.md: a vector load bursts only if it
// is stripe-contained from a 4-byte-aligned start. Given the kernel's stripe cap
// (qwen_burst_vl), it is enough that every core's column span is a multiple of 4
// elements -- then no emitted vector is ever below the burst floor or oddly
// aligned. script/test_burst_vl.py checks this against the runtime's own
// eligibility predicate.
//
// So the STORED width is P rounded up until the per-core span divides by 4. At
// 4x4 B=1 nothing is padded; at 8x8 B=1 the span would be 17 and 74% of the
// weight bytes would take the single-word path, so it is rounded to 20 for +17.6%
// traffic. The [QWEN] line prints what the padding cost.
#define QWEN_PBLOCKS GEMM_PBLOCKS(KERNEL_SIZE)
// Column spans in elements. 8 elements is 16 bytes, which is what lets a vector
// load cross stripe boundaries and still burst (gemm_burst.h:41): the VLSU then
// splits it into 16-word requests instead of falling back to single words. That
// doubles the vector length we can use and the requests in flight per core.
//
// B=1 keeps 8-byte spans: LDP is 17408 = 17 x 1024, so every batch from 2 up gets
// 16-byte spans for free, while B=1 has 256 column blocks and would round LDP up
// to 18432 -- 5.9% more weight traffic on the one shape that is already
// bandwidth-bound with all 16 banks engaged.
// Default: align every core's column span to a WHOLE tile stripe. Then
// p_start = p_block * span is stripe-aligned for every core, qwen_burst_vl never
// has to clip a load to a stripe remainder, and every vector load is a full
// 16-word burst instead of the 16/12/8/4-word sawtooth that an unaligned span
// produces (span % STRIPE_E = 8 at B=16 walks the start offset 0,8,16,24).
// The price is stored width: PAD_UNIT becomes PBLOCKS*STRIPE_E, which rounds
// LDP 17408 -> 20480 at 128 blocks (+17.6%) and -> 24576 at 256 (+41%).
// qwen_span_align=4 restores the unpadded, stripe-capped behaviour.
#ifndef QWEN_SPAN_ALIGN
#define QWEN_SPAN_ALIGN QWEN_STRIPE_E
#endif
#define QWEN_PAD_UNIT                                     \
  (((QWEN_PBLOCKS) * (QWEN_SPAN_ALIGN)) > (QWEN_STRIPE_E) \
       ? ((QWEN_PBLOCKS) * (QWEN_SPAN_ALIGN))             \
       : (QWEN_STRIPE_E))
#define QWEN_LDP \
  ((((QWEN_P) + (QWEN_PAD_UNIT)-1) / (QWEN_PAD_UNIT)) * (QWEN_PAD_UNIT))


// How far a buffer must move to land on the next group of the word-interleaved
// L1. Same derivation as arch.ld.c and the kernel's gbar_base().
#define QWEN_GROUP_STRIDE \
  (4 * (N_FU) * (BANKING_FACTOR) * (NUM_CORES_PER_TILE) * (NUM_TILES_PER_GROUP))
#define QWEN_MESH_SWEEP ((NUM_GROUPS) * (QWEN_GROUP_STRIDE))

// X is read by every core, so a single copy makes its few groups a hot spot. One
// copy per neighbourhood removes both the contention and the distance -- but only
// while X is small enough to sit in fewer groups than the mesh has. Past that it
// already spans every group, so replication would buy nothing and cost L1.
#define QWEN_P2_UP(n)                                                        \
  ((n) <= 1 ? 1 : (n) <= 2 ? 2 : (n) <= 4 ? 4 : (n) <= 8 ? 8 : (n) <= 16 ? 16 \
   : (n) <= 32 ? 32 : (n) <= 64 ? 64 : (n))

#define QWEN_X_BYTES ((GEMM_M) * (GEMM_N)*GEMM_ELEM_BYTES)
// Groups one copy covers, rounded up to a power of two so the replicas always
// tile the mesh evenly instead of falling off a divisibility cliff.
#define QWEN_X_SPAN \
  QWEN_P2_UP(((QWEN_X_BYTES) + (QWEN_GROUP_STRIDE)-1) / (QWEN_GROUP_STRIDE))
#define QWEN_X_REPLICAS \
  ((QWEN_X_SPAN) >= (NUM_GROUPS) ? 1 : (NUM_GROUPS) / (QWEN_X_SPAN))
#define QWEN_X_GROUPS_PER_REPLICA ((NUM_GROUPS) / (QWEN_X_REPLICAS))
#define QWEN_X_STRIDE_B ((QWEN_X_GROUPS_PER_REPLICA) * (QWEN_GROUP_STRIDE))
#define QWEN_X_STRIDE_E ((QWEN_X_STRIDE_B) / GEMM_ELEM_BYTES)
// Replicated, X is spread over exactly one mesh sweep whatever the batch is.
#define QWEN_X_ELEMS                                       \
  ((QWEN_X_REPLICAS) > 1 ? (QWEN_X_REPLICAS) * (QWEN_X_STRIDE_E) \
                         : (GEMM_M) * (GEMM_N))
#define QWEN_X_REPLICA_OF(group) ((group) / (QWEN_X_GROUPS_PER_REPLICA))

// ---- P strips: how the output is cut when it does not fit L1 ---------------------
//
// L1 holds the W double buffer, the gate and up outputs and X. The outputs are
// 2*B*LDP elements, so they grow with the batch and are what runs out first: at
// K=5120, KT=160 the whole output fits up to B=64 and not beyond.
//
// So the output columns are cut into strips of QWEN_PT columns. A strip is finished
// completely -- every K tile of gate, then of up -- written out to L2, and then the
// next strip reuses the same L1 buffers. Nothing is reduced across cores: each core
// still owns a block of C and runs the whole K loop on it. Every W element belongs to
// exactly one strip, so W is still read from L2 once, and X stays resident.
//
// W is stored STRIP-MAJOR in L2, [strip][K][PT], so the K tile of a strip is one
// contiguous DMA exactly as before. The output goes to L2 strip-major too,
// [strip][B][PT], which is also the order the down projection reads it in (it
// reduces over P). With one strip both layouts are the old row-major ones.
#define QWEN_L1_BYTES ((NUM_CORES) * (N_FU) * (BANKING_FACTOR) * (L1_BANK_SIZE))
#define QWEN_L1_FIXED ((QWEN_X_ELEMS)*GEMM_ELEM_BYTES + (NUM_CORES) * (STACK_SIZE))
#define QWEN_L1_FOR(pt)                                                  \
  (2 * (QWEN_KT) * (pt)*GEMM_ELEM_BYTES +  /* W double buffer          */ \
   2 * (QWEN_B) * (pt)*GEMM_ELEM_BYTES +   /* gate + up output strip   */ \
   (QWEN_L1_FIXED))
// A legal strip width: whole pad units (every core's span stays stripe-aligned),
// an exact divisor of LDP, a per-core span at least as long as the vector load the
// MSHR tuning assumes (GEMM_LOAD_BYTES), and fits L1.
#define QWEN_PT_OK(pt)                                                         \
  ((pt) > 0 && ((pt) % (QWEN_PAD_UNIT)) == 0 && ((QWEN_LDP) % (pt)) == 0 &&     \
   ((pt) / (QWEN_PBLOCKS)) * GEMM_ELEM_BYTES >= GEMM_LOAD_BYTES(KERNEL_SIZE) && \
   (QWEN_L1_FOR(pt)) < (QWEN_L1_BYTES))
#define QWEN_PT_TRY(d, rest) \
  ((((QWEN_LDP) % (d)) == 0 && QWEN_PT_OK((QWEN_LDP) / (d))) ? ((QWEN_LDP) / (d)) : (rest))
// The widest strip that fits: fewest strip boundaries. 0 when nothing fits.
#define QWEN_PT_AUTO                                                               \
  QWEN_PT_TRY(1, QWEN_PT_TRY(2, QWEN_PT_TRY(4, QWEN_PT_TRY(8, QWEN_PT_TRY(16,       \
      QWEN_PT_TRY(32, QWEN_PT_TRY(64, 0)))))))
// qwen_pt=<n> on the make line pins the width; qwen_pt=auto (default) picks it.
#if defined(QWEN_PT_REQ) && (QWEN_PT_REQ) > 0
#define QWEN_PT (QWEN_PT_REQ)
#else
#define QWEN_PT (QWEN_PT_AUTO)
#endif
#define QWEN_NSTRIPS ((QWEN_PT) > 0 ? (QWEN_LDP) / (QWEN_PT) : 1)

#endif
