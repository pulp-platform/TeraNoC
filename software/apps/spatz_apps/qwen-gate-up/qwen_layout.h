// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Where X lives in L1, shared by the app and by the build-time hash generator so
// the two cannot disagree about an address.
#ifndef QWEN_LAYOUT_H
#define QWEN_LAYOUT_H

#include "data/qwen_shape.h"

// ---- K split: two cores on one output patch -------------------------------------
//
// The kernel's register block is KERNEL_SIZE x VLMAX = 512 fp16 outputs at every KS >= 2
// (GEMM_LMUL pins KS * LMUL at 16). A core owns B * P / cores outputs, and below 512 every
// vector runs at a fraction of its length while each K step still pays the same fixed cost --
// 8x8 B=16 has 256 per core and measured ~71% against 95%+ for every shape with >= 512.
//
// So when a core would own fewer than 512 but at least 256, pair the cores instead: both
// cores of a pair own the SAME patch, twice as wide, and each takes half of every K tile's
// rows (QWEN_KT_CORE). Vectors are full again; each core does the same number of FMACs.
// Nothing extra is loaded -- the two halves of a tile are read by different cores -- and
// the two partial sums are added once per projection (main.c, qwen_ksplit_reduce).
// qwen_ksplit=1|2 pins it; auto = 2 exactly in that half-full band, 1 everywhere else.
#ifndef QWEN_KSPLIT_REQ
#define QWEN_KSPLIT_REQ 0
#endif
#ifdef ACTIVE_GROUP_DIV
#define QWEN_OUT_PER_CORE (((GEMM_M) * (GEMM_P)) / ((NUM_CORES) / (ACTIVE_GROUP_DIV)))
#else
#define QWEN_OUT_PER_CORE (((GEMM_M) * (GEMM_P)) / (NUM_CORES))
#endif
#if QWEN_KSPLIT_REQ > 0
#define GEMM_KSPLIT QWEN_KSPLIT_REQ
#elif QWEN_OUT_PER_CORE >= 256 && QWEN_OUT_PER_CORE < 512
#define GEMM_KSPLIT 2
#else
#define GEMM_KSPLIT 1
#endif
#define QWEN_KSPLIT GEMM_KSPLIT

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
// W is stored STRIP-MAJOR in L2, [strip][K][LDW], so the K tile of a strip is one
// contiguous DMA exactly as before. The output goes to L2 strip-major too,
// [strip][B][LDW], which is also the order the down projection reads it in (it
// reduces over P). LDW = PT + QWEN_WPAD (below); with one strip and no pad both
// layouts are the old row-major ones.
//
// ---- Row pad: spreading one K row's successor over the tiles -----------------
//
// W and C rows are PT elements, and PT*2 bytes is a whole number of mesh sweeps
// (32 KiB at PT=16384), so going down a K row lands on the SAME group and tile.
// Every core walks its columns 64 at a time in step with the others, so at any
// moment the whole machine reads W from 2 tiles per column block: 8 of 16 tiles
// per group at B=16, 4 at B=32, 2 at B=64. Those few tiles serve every response,
// and the response remapper can only spread them inside their own 4-tile quad.
//
// QWEN_WPAD extra elements per row (default one tile stripe, 64 B) shift row k by
// k tiles, so a K tile's rows cycle through all 16 tiles, and every 16 rows by one
// group, so the group that reads its own W (unmerged: local bursts bypass the MSHR)
// rotates instead of always being the same two. The pad is a whole stripe, so every
// row still starts on a burst boundary and sharers still load identical addresses.
// The pad is stored in L2 too, so a K tile is still ONE contiguous DMA. 0 disables.
#ifndef QWEN_WPAD
#define QWEN_WPAD QWEN_STRIPE_E
#endif
#define QWEN_SWEEP_E ((QWEN_MESH_SWEEP) / GEMM_ELEM_BYTES)
#define QWEN_ROUND_SWEEP(n) ((((n) + (QWEN_SWEEP_E)-1) / (QWEN_SWEEP_E)) * (QWEN_SWEEP_E))

#define QWEN_L1_BYTES ((NUM_CORES) * (N_FU) * (BANKING_FACTOR) * (L1_BANK_SIZE))
#define QWEN_L1_FIXED ((QWEN_X_ELEMS)*GEMM_ELEM_BYTES + (NUM_CORES) * (STACK_SIZE))
// Each buffer slot is rounded up to a whole mesh sweep so every slot, not just the
// first, starts sweep-aligned -- the build-time bank hash scores buffer offsets.
#define QWEN_L1_KP(kt, pt)                                                                \
  (2 * QWEN_ROUND_SWEEP((kt) * ((pt) + (QWEN_WPAD))) * GEMM_ELEM_BYTES +      /* W x2 */  \
   2 * QWEN_ROUND_SWEEP((QWEN_B) * ((pt) + (QWEN_WPAD))) * GEMM_ELEM_BYTES +  /* C x2 */  \
   ((QWEN_KSPLIT) > 1                                                      /* K-split */ \
        ? QWEN_ROUND_SWEEP((QWEN_B) * ((pt) + (QWEN_WPAD))) * GEMM_ELEM_BYTES /* partial */ \
        : 0) +                                                                            \
   (QWEN_L1_FIXED))
// A legal strip width for K tiles of kt rows: whole pad units (every core's span
// stays stripe-aligned), an exact divisor of LDP, a per-core span at least as long as
// the vector load the MSHR tuning assumes (GEMM_LOAD_BYTES) -- so every W load stays
// a full-length vector, 2 x 16-word bursts at KS=8 -- and fits L1.
#define QWEN_PT_OK_K(kt, pt)                                                   \
  ((pt) > 0 && ((pt) % (QWEN_PAD_UNIT)) == 0 && ((QWEN_LDP) % (pt)) == 0 &&     \
   ((pt) / (QWEN_PBLOCKS)) * GEMM_ELEM_BYTES >= GEMM_LOAD_BYTES(KERNEL_SIZE) && \
   (QWEN_L1_KP(kt, pt)) < (QWEN_L1_BYTES))

// ---- K tile height and strip width ---------------------------------------------------
//
// A core keeps its 8 x 64 accumulator block in registers for the whole K loop of one
// 64-column chunk, and pays ~1.5-2k cycles at every chunk boundary (C store, the group
// rendezvous, C reload, W restart) -- ~10 pp of FPU time at KT=160. The boundaries per
// MAC fall as 1/KT, and the W double buffer 2 x KT x PT is a fixed L1 budget, so a
// taller tile trades strip width for height: KT=640 PT=4096 moves the same 5.25 MB per
// DMA as KT=160 PT=16384 and measured +7 pp at 4x4 B=16/32/64. Every W load keeps its
// full vector length (QWEN_PT_OK_K), and with the continuous W stream (main.c) a strip
// boundary costs only the output write-back.
//
// script/gen_tiles.c picks both on the host and writes data/qwen_tiles.h (a macro search
// over KT x PT expands past what the compiler survives):
//   * QWEN_KT: qwen_kt=<n> pins it; qwen_kt=auto (default) takes the tallest K/s,
//     s = 2, 4, ..., 128 tiles -- an EVEN count, which the stream's slot parity needs --
//     up to QWEN_KT_MAX (make qwen_kt_max, default 640, the tallest measured) that leaves
//     a legal strip width;
//   * QWEN_PT: qwen_pt=<n> pins it; auto takes the widest legal width beside QWEN_KT.
#ifndef QWEN_TILE_PROBE
#include "data/qwen_tiles.h"
#endif
#define QWEN_L1_FOR(pt) QWEN_L1_KP(QWEN_KT, pt)
#define QWEN_PT_OK(pt) QWEN_PT_OK_K(QWEN_KT, pt)
#define QWEN_NSTRIPS ((QWEN_PT) > 0 ? (QWEN_LDP) / (QWEN_PT) : 1)
// Stored row stride of W (L2 and L1) and of C: the strip width plus the pad.
#define QWEN_LDW ((QWEN_PT) + (QWEN_WPAD))
// K rows of each tile ONE core reduces over: all of them, or its part under the K split.
#define QWEN_KT_CORE ((QWEN_KT) / (QWEN_KSPLIT))
#define QWEN_WSLOT QWEN_ROUND_SWEEP((QWEN_KT) * (QWEN_LDW))   // one W K-tile buffer
// W in L2 is [stage][strip][K tile][QWEN_WSLOT]: each K tile starts on a mesh sweep there too.
// L2 is interleaved on the same bits as the L1 group field, so a sweep-aligned tile makes the
// DMA backend of group g read L2 bank g for EVERY tile. Packed back to back, a padded tile
// (5,253,120 B at PT=16384) shifted that by 10 banks per tile and the refill time swung from
// 15.8k to 34.8k cycles around an unchanged mean -- which a DMA-bound shape pays at its max.
// Without the pad the slot is exactly the tile and the layout is the packed one.
#define QWEN_WTILES ((QWEN_NSTRIPS) * ((QWEN_K) / (QWEN_KT)))   // K tiles per stage in L2
#define QWEN_CSLOT QWEN_ROUND_SWEEP((QWEN_B) * (QWEN_LDW))    // one stage's C strip

#endif
