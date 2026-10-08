// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Where the operands live in L1, shared by the app and by the build-time generators so
// they cannot disagree about an address.
//
// qwen-ffn-down: forked from qwen-gate-up @ dd6056fa. The A operand is H = SiLU(G)*U
// [B][K=16384] (still called X / qwen_x below, as in the parent, so the two files diff
// cleanly), W is Wdown [K][P=4096], and there is ONE projection instead of two. Comments
// that quote gate-up shapes (K=5120, P=16384/17408) record where each rule came from.
#ifndef QWEN_LAYOUT_H
#define QWEN_LAYOUT_H

#include "data/qwen_shape.h"

// Projections streamed back to back (gate-up: 2). Sizes the C buffers and the W image.
#define QWEN_STAGES_N 1u

// ---- K split: two cores on one output patch -------------------------------------
//
// The kernel's register block is KERNEL_SIZE x VLMAX = 512 fp16 outputs at every KS >= 2
// (GEMM_LMUL pins KS * LMUL at 16). A core owns B * P / cores outputs, and below 512 every
// vector runs at a fraction of its length while each K step still pays the same fixed cost --
// 8x8 B=16 has 256 per core and measured ~71% against 95%+ for every shape with >= 512.
//
// So when a core would own fewer, QWEN_KSPLIT cores share one patch, that many times wider,
// and each takes 1/QWEN_KSPLIT of every K tile's rows (QWEN_KT_CORE). Vectors are full again;
// each core does the same number of FMACs. Nothing extra is loaded -- the K parts of a tile
// are read by different cores -- and the partial sums are added once per projection (main.c,
// qwen_ksplit_reduce). Fewer, wider column blocks also keep the stripe-aligned span from
// padding the stored width: at 8x8 B<=8 without the split, 1024 blocks of 16 columns pad
// LDP 16384 -> 32768, which doubles W and overflows the 512 MiB L2.
//
// auto = the smallest power of two that fills the block (KS=1, i.e. odd B, runs m8: 256),
// capped at 16 = one group: 2 at 8x8 B=16 and 4x4 B=4, 4 at 8x8 B=8 and 4x4 B=1/2, 8 at 8x8
// B=4, 16 at 8x8 B=1/2; 1 from 512 outputs up. qwen_ksplit=1|2|4|8|16 pins it.
#ifndef QWEN_KSPLIT_REQ
#define QWEN_KSPLIT_REQ 0
#endif
#ifdef ACTIVE_GROUP_DIV
#define QWEN_OUT_PER_CORE (((GEMM_M) * (GEMM_P)) / ((NUM_CORES) / (ACTIVE_GROUP_DIV)))
#else
#define QWEN_OUT_PER_CORE (((GEMM_M) * (GEMM_P)) / (NUM_CORES))
#endif
#define QWEN_KS_BLOCK (((GEMM_M) % 2) ? 256 : 512)  // KS x VLMAX: 256 at KS=1 (m8), else 512
#if QWEN_KSPLIT_REQ > 0
#define GEMM_KSPLIT QWEN_KSPLIT_REQ
#elif (QWEN_OUT_PER_CORE) >= (QWEN_KS_BLOCK)
#define GEMM_KSPLIT 1
#elif 2 * (QWEN_OUT_PER_CORE) >= (QWEN_KS_BLOCK)
#define GEMM_KSPLIT 2
#elif 4 * (QWEN_OUT_PER_CORE) >= (QWEN_KS_BLOCK)
#define GEMM_KSPLIT 4
#elif 8 * (QWEN_OUT_PER_CORE) >= (QWEN_KS_BLOCK)
#define GEMM_KSPLIT 8
#else
#define GEMM_KSPLIT 16
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

// ---- H row pad (qwen-ffn-down) ----------------------------------------------------------
// H is [B][K]; at K = 16384 a row is 32 KiB, a whole number of mesh sweeps (16 KiB at 4x4,
// 64 KiB at 8x8 counts in halves), so element k of EVERY row sits in the same group and bank
// (4x4) or in two groups (8x8). Every core's per-step scalar H loads then pile onto one or two
// banks; measured on GVSoC, full-K 8x8 B=16 ran ~80x slower (1-2M cycles per K tile) while the
// same shape at K = 4096 (8 KiB rows, spread over 8 groups) was healthy. One group stride of
// pad per row puts consecutive rows in consecutive groups -- the same idea as the W row pad.
// ffn_hpad: auto (= one group stride) or a number of elements (0 = the unpadded layout).
#if defined(FFN_HPAD_REQ) && (FFN_HPAD_REQ) >= 0
#define FFN_HPAD (FFN_HPAD_REQ)
#else
#define FFN_HPAD ((QWEN_GROUP_STRIDE) / GEMM_ELEM_BYTES)
#endif
#define QWEN_LDX ((GEMM_N) + (FFN_HPAD))  // H (the A operand) row stride, elements

#define QWEN_X_BYTES ((GEMM_M) * (QWEN_LDX)*GEMM_ELEM_BYTES)
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
                         : (GEMM_M) * (QWEN_LDX))
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

// ---- Accumulation precision (ffn_acc) ------------------------------------------------
// 16 (default since 2026-10-01): fp16 C all the way. fp32 is parked: on RTL its check 4 is not
// bit-exact (1-2 ulp in 0.03-0.2% of outputs, 50% at B=1) and it costs ~20% at 4x4 B=16.
// 32: the kernel still multiplies and accumulates in fp16 inside one call -- one K
// tile's rows of this core's K part, i.e. QWEN_KT_CORE rows, or 1/FFN_PRIME_SPLIT of that
// on the first tile -- but at the end of every call adds that fp16 partial into an fp32 C
// (vfwadd.wv), and only the final result is rounded to fp16, into Y. fp16 accumulation over
// the whole K = 16384 is 0.5-1.8% rms (docs/qwen3_8_27b/ffn_plan.md 11.4); a flush every
// 16-256 rows is 0.06-0.24%. 16: the original fp16 C, reloaded and stored in fp16.
// C and the K-split partials double in size; Y (fp16) is a separate buffer.
#ifndef QWEN_ACC32
#define QWEN_ACC32 0
#endif
// K split across groups instead of inside one (ffn_kgroup, main.c STEP 1). auto (-1, default):
// on whenever the in-group split leaves fewer than 3 X (H) sharers per group -- the MSHR then
// bypasses the single class and every core fetches every H word over the NoC (8x8 B=16..64,
// 4x4 B<=4). RTL 8x8 K=2048: B=32 60,498 -> 53,998, B=64 107,834 -> 89,229 cycles. Needs the
// fp16 C (the fp32 one is group-local), so auto is off under ffn_acc=32.
#ifndef FFN_KSPLIT_XGROUP_REQ
#define FFN_KSPLIT_XGROUP_REQ (-1)
#endif
#if (FFN_KSPLIT_XGROUP_REQ) >= 0
#define FFN_KSPLIT_XGROUP (FFN_KSPLIT_XGROUP_REQ)
#elif !(QWEN_ACC32) && (QWEN_KSPLIT) > 1 && defined(MATMUL_DECODE_SPLIT) && (MATMUL_DECODE_SPLIT) && \
    (GEMM_CPG) / (GEMM_DECODE_RCG(KERNEL_SIZE) * (QWEN_KSPLIT)) < 3
#define FFN_KSPLIT_XGROUP 1
#else
#define FFN_KSPLIT_XGROUP 0
#endif
#define QWEN_ACC_BYTES ((QWEN_ACC32) ? 4 : 2)
// The fp32 C is GROUP-LOCAL and private per core, in 256-byte chunks: one kernel flush piece
// (64 floats, the widest access the kernel makes) of one row of the core's patch. Chunk k of a
// core in group g sits in g's own slice of the mesh sweep -- the address bits that pick the
// group are g -- so every flush load and store stays inside the group: no NoC hop, and no
// group MSHR (group-local requests never enter it), hence none of the bypass rendezvous the
// fp16 C reload needs. A group slice (QWEN_GROUP_STRIDE, 1 KiB) holds QWEN_C32_CPG chunks, so
// chunk k is at slice k / CPG, offset (k % CPG) * 256. Core c of the group owns chunks
// [c * QWEN_C32_CH, (c + 1) * QWEN_C32_CH): its QWEN_C32_ROWS rows x pieces per row, rounded up
// to whole slices. The K-split partners of a patch are cores of the same group, so the
// reduction reads its partners' chunks locally too. (Stack and sequential memory are 512 B per
// core, too small to hold it.)
#define QWEN_C32_CHUNK_B 256u
#define QWEN_C32_CPG ((QWEN_GROUP_STRIDE) / (QWEN_C32_CHUNK_B))
// Columns per core (decode split): PT x row chunks x K split / cores.
#define QWEN_C32_SPAN(pt) \
  ((pt) * ((QWEN_B) / (KERNEL_SIZE)) * (QWEN_KSPLIT) / (NUM_CORES))
#define QWEN_C32_PIECES(pt) ((QWEN_C32_SPAN(pt) + 63u) / 64u)
#define QWEN_C32_CH_OF(pt) \
  ((((KERNEL_SIZE) * QWEN_C32_PIECES(pt)) + (QWEN_C32_CPG) - 1) / (QWEN_C32_CPG) * (QWEN_C32_CPG))
#define QWEN_C32_BYTES(pt) \
  (((NUM_CORES) / (NUM_GROUPS)) * QWEN_C32_CH_OF(pt) / (QWEN_C32_CPG) * (QWEN_MESH_SWEEP))

#define QWEN_L1_BYTES ((NUM_CORES) * (N_FU) * (BANKING_FACTOR) * (L1_BANK_SIZE))
#define QWEN_L1_FIXED ((QWEN_X_ELEMS)*GEMM_ELEM_BYTES + (NUM_CORES) * (STACK_SIZE))
// Each buffer slot is rounded up to a whole mesh sweep so every slot, not just the
// first, starts sweep-aligned -- the build-time bank hash scores buffer offsets.
#define QWEN_L1_KP(kt, pt)                                                                \
  (2 * QWEN_ROUND_SWEEP((kt) * ((pt) + (QWEN_WPAD))) * GEMM_ELEM_BYTES +      /* W x2 */  \
   ((QWEN_ACC32) ? QWEN_C32_BYTES(pt) + /* fp32 C, all K parts, + fp16 Y */              \
                       QWEN_ROUND_SWEEP((QWEN_B) * ((pt) + (QWEN_WPAD))) * GEMM_ELEM_BYTES  \
                 : ((QWEN_STAGES_N) + (QWEN_KSPLIT) - 1) * /* fp16 C + K-split partials */ \
                       QWEN_ROUND_SWEEP((QWEN_B) * ((pt) + (QWEN_WPAD))) * GEMM_ELEM_BYTES) + \
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
#define QWEN_CSLOT QWEN_ROUND_SWEEP((QWEN_B) * (QWEN_LDW))    // one fp16 [B][LDW] strip
// One accumulator strip (C, or one K-split partial) in elem_t units: fp32 takes twice the room.
#define QWEN_CSLOT_ACC QWEN_ROUND_SWEEP((QWEN_B) * (QWEN_LDW) * (QWEN_ACC_BYTES) / 2)
#define QWEN_C32_CH QWEN_C32_CH_OF(QWEN_PT)        // chunks per core
#define QWEN_C32_ELEMS (QWEN_C32_BYTES(QWEN_PT) / 2)  // the fp32 C, in elem_t units
#define QWEN_SWEEP_F ((QWEN_MESH_SWEEP) / 4)         // one mesh sweep, in floats

// ---- First K tile in pieces (ffn_prime_split) ------------------------------------------
// With nothing to overlap it, the first tile's DMA is idle FPU time: 16 MiB at 8x8 KT=2048,
// ~15k cycles. So tile 0 is fetched in FFN_PRIME_SPLIT pieces, and the cores start on piece 0
// while piece 1 is in flight -- the same one-ahead DMA pipeline as the tiles, only finer. For
// every core to have work in every piece, tile 0 is stored PIECE-MAJOR in L2 (and so in L1):
// L1 row r = s * FFN_SUB_TILE_ROWS + j * FFN_SUB_ROWS + i holds K row
// j * QWEN_KT_CORE + s * FFN_SUB_ROWS + i -- piece s holds the s-th run of every K part j.
// Every other tile keeps the plain row order. Only with the SwiGLU prologue: without it the
// prime is outside the measured region. A piece must leave every core an even row count.
#ifndef FFN_PRIME_SPLIT_REQ
#define FFN_PRIME_SPLIT_REQ 0
#endif
#ifdef QWEN_TILE_PROBE
#define FFN_PRIME_SPLIT 1  // script/gen_tiles.c: QWEN_KT is what it is choosing
#elif !(QWEN_SWIGLU) || (QWEN_NSTRIPS) != 1  // pieces only at the start of the only strip
#define FFN_PRIME_SPLIT 1
#elif (FFN_PRIME_SPLIT_REQ) > 0
#define FFN_PRIME_SPLIT (FFN_PRIME_SPLIT_REQ)
#elif ((QWEN_KT_CORE) % 8) == 0 && (QWEN_KT_CORE) / 4 >= 16
#define FFN_PRIME_SPLIT 4
#elif ((QWEN_KT_CORE) % 4) == 0 && (QWEN_KT_CORE) / 2 >= 16
#define FFN_PRIME_SPLIT 2
#else
#define FFN_PRIME_SPLIT 1
#endif
#define FFN_SUB_ROWS ((QWEN_KT_CORE) / (FFN_PRIME_SPLIT))      // one core's rows per piece
#define FFN_SUB_TILE_ROWS ((QWEN_KT) / (FFN_PRIME_SPLIT))      // one piece of tile 0
// Logical K row of stored row r (0 <= r < QWEN_KT) of K tile `step`.
#define FFN_W_ROW(step, r)                                                                  \
  ((step) != 0u || (FFN_PRIME_SPLIT) == 1                                                   \
       ? (step) * (uint32_t)(QWEN_KT) + (r)                                                 \
       : ((r) % (uint32_t)(FFN_SUB_TILE_ROWS)) / (uint32_t)(FFN_SUB_ROWS) *                 \
                 (uint32_t)(QWEN_KT_CORE) +                                                 \
             (r) / (uint32_t)(FFN_SUB_TILE_ROWS) * (uint32_t)(FFN_SUB_ROWS) +              \
             (r) % (uint32_t)(FFN_SUB_ROWS))

// ---- SwiGLU input: G and U as qwen-gate-up leaves them in L2 -------------------------
// [strip][B][FFN_GU_LD], FFN_GU_LD = gate-up's strip width + its row pad. They are staged into
// the two W slots before the first W tile is primed (main.c), so each must fit one slot.
#ifndef QWEN_SWIGLU
#define QWEN_SWIGLU 0
#endif
#if defined(FFN_GU_PT_REQ) && (FFN_GU_PT_REQ) > 0
#define FFN_GU_PT (FFN_GU_PT_REQ)
#else
#define FFN_GU_PT (QWEN_K)
#endif
#if defined(FFN_GU_WPAD_REQ) && (FFN_GU_WPAD_REQ) >= 0
#define FFN_GU_WPAD (FFN_GU_WPAD_REQ)
#else
#define FFN_GU_WPAD (QWEN_STRIPE_E)
#endif
#define FFN_GU_LD ((FFN_GU_PT) + (FFN_GU_WPAD))
#define FFN_GU_NSTRIPS ((QWEN_K) / (FFN_GU_PT))
#define FFN_GU_ELEMS ((FFN_GU_NSTRIPS) * (QWEN_B) * (FFN_GU_LD))
// Each image in its own sweep-rounded slot, so U starts sweep-aligned like G: a DMA from an
// unaligned L2 source crosses the 1 KiB L2 interleave and the backend rejects it.
#define FFN_GU_SLOT QWEN_ROUND_SWEEP(FFN_GU_ELEMS)
// Element (b, k) of G or U inside that image.
#define FFN_GU_AT(b, k) \
  (((k) / (FFN_GU_PT)) * (QWEN_B) * (FFN_GU_LD) + (b) * (FFN_GU_LD) + (k) % (FFN_GU_PT))
// When G and U fit side by side in W slot 1, they are staged there, and slot 0 is free for the
// first W tile (or its first piece) to stream in UNDER the SwiGLU prologue instead of after it.
#define FFN_GU_EARLY ((QWEN_SWIGLU) && 2 * (FFN_GU_SLOT) <= (QWEN_WSLOT))

#endif
