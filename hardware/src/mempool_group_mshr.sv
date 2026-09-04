// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Zexin Fu <zexifu@iis.ee.ethz.ch>

`include "mempool/mempool.svh"
`include "reqrsp_interface/typedef.svh"
`include "common_cells/registers.svh"

module mempool_group_mshr
  import mempool_pkg::*;
  import cf_math_pkg::idx_width;
#(
  parameter int NumGroups                 = 16,
  parameter int NumTilesPerGroup          = 16,
  parameter int NumRemoteReqPortsPerTile  = 2,
  parameter int NumRemoteRespPortsPerTile = 2,

  // parameter int MshrNum        = NumTilesPerGroup * 32,
  // parameter int MshrNum        = NumTilesPerGroup * 2,
  // Can be overridden from build defines with GROUP_MSHR_NUM.
  parameter int MshrNum        = `ifdef GROUP_MSHR_NUM `GROUP_MSHR_NUM `else NumTilesPerGroup `endif,
  parameter int MshrMergeWords = 1,
  parameter int MshrMergeReqs  = `ifdef GROUP_MSHR_MERGE_REQS `GROUP_MSHR_MERGE_REQS `else 8 `endif,
  // Address-banking (Increment 3): the MSHR table is partitioned into MshrNum/MshrWaysPerBank banks,
  // each request maps to bank_of({tgt_group,addr}); allocation and the hit search are confined to that
  // bank's ways, so a request compares against only MshrWaysPerBank entries (not all MshrNum) while
  // same-(group,addr) requests from any tile still land in the same bank (cross-tile merge preserved).
  // MshrWaysPerBank must divide MshrNum.
  parameter int MshrWaysPerBank = `ifdef GROUP_MSHR_WAYS_PER_BANK `GROUP_MSHR_WAYS_PER_BANK `else 4 `endif,
  // MSHR admission policy by effective load length:
  // - single      : req_len == 1
  // - non-full    : 1 < req_len < MshrFullBurstWords
  // - full-burst  : req_len == MshrFullBurstWords
  // req_len is after alignment handling (unaligned bursts are clamped to single).
  parameter int unsigned MshrFullBurstWords = MaxBurstWords,
  parameter bit EnableMshrSingleReq         = `ifdef GROUP_MSHR_ENABLE_SINGLE `GROUP_MSHR_ENABLE_SINGLE `else 1'b0 `endif,
  parameter bit EnableMshrNonFullBurstReq   = `ifdef GROUP_MSHR_ENABLE_NON_FULL `GROUP_MSHR_ENABLE_NON_FULL `else 1'b1 `endif,
  parameter bit EnableMshrFullBurstReq      = `ifdef GROUP_MSHR_ENABLE_FULL `GROUP_MSHR_ENABLE_FULL `else 1'b1 `endif,
  // Per-entry buffered response beats (for out-of-order/multi-channel returns).
  // Default tracks remote response bandwidth per tile.
  parameter int RespBufWords   = ((NumRemoteRespPortsPerTile > 1) ?
                                  (NumRemoteRespPortsPerTile - 1) : 1),
  // 0: drain one sub-request per MSHR per cycle (original behavior)
  // 1: drain as many sub-requests as ports allow per cycle
  parameter bit DrainMultiPort = 1'b1,
  // Round-robin fairness on the contended arbitration scans (audit M2'/M3/L3):
  // the per-bank allocation admit, the drain entry scan, and the drain sub_req
  // scan all rotate their priority start point by a free-running base instead of
  // always favoring the lowest index. 1 = RR on; 0 = legacy fixed lowest-index
  // priority (start=0), bit-identical to the pre-RR baseline. See the RR-base
  // declarations and always_ff below. (M4 bypass-vs-MSHR is intentionally not a
  // fairness point -- bypass is non-backpressurable -- so it is never rotated.)
  parameter bit EnableRrFairness = `ifdef GROUP_MSHR_ENABLE_RR `GROUP_MSHR_ENABLE_RR `else 1'b1 `endif,
  // Keep responded entries as a small read-response cache. 0 = an entry goes straight from
  // MSHR_DRAIN_RESP to MSHR_IDLE, so a later same-address request can never be served from a
  // resident line -- which also removes the cohort-splitting path where some members of a
  // coalescing group hit the line while the rest arrive after it self-invalidates and then wait
  // out group_mshr_serve_timeout for peers that will never come.
  parameter bit EnableRespCache = `ifdef GROUP_MSHR_RESP_CACHE `GROUP_MSHR_RESP_CACHE `else 1'b1 `endif,
  // Simulation-only statistics/prints (translate_off).
  parameter bit EnableStats   = `ifdef GROUP_MSHR_ENABLE_STATS `GROUP_MSHR_ENABLE_STATS `else 1'b0 `endif,
  // Stats print period in cycles while trace is active (0 disables periodic prints).
  parameter int unsigned StatsPeriod = `ifdef GROUP_MSHR_STATS_PERIOD `GROUP_MSHR_STATS_PERIOD `else 0 `endif,
  // Spill register enables (0 = pass-through).
  // C2 (F5/F6): the request-input spill is data-path redundant -- the TILE already registers its
  // request output with its own spill_register (mempool_tile.sv:838), and between that and this one
  // there is nothing but two wire assigns (mempool_group.sv:216, :569). Two registers back to back,
  // zero logic between them. Bypassing removes 32 x 166 = 5,312 flops/group (~85k cluster).
  //
  // It was gated on C1, not on the data path: bypassing re-exposes the tile's spill to this module's
  // req_in_ready, which used to carry the up-to-32-deep serial merge chain. C1 replaced that with a
  // prefix rank against the registered array, so the ready path is now shallow and the bypass is
  // safe to take.
  //
  // NOT bit-identical: removing a pipeline stage shifts request arrival by a cycle, so this needs a
  // PERFORMANCE run, not an equivalence run. 0 = bypassed (no flops), 1 = spill present.
  parameter bit SpillReqIn     = `ifdef GROUP_MSHR_SPILL_REQ_IN `GROUP_MSHR_SPILL_REQ_IN `else 1'b1 `endif,
  parameter bit SpillReqOut    = 1'b1,
  parameter bit SpillRespIn    = 1'b1,
  parameter bit SpillRespOut   = 1'b1
) (
  // Clock and reset
  input  logic                                                                                   clk_i,
  input  logic                                                                                   rst_ni,
  input  logic                                                                                   testmode_i,
  // Scan chain
  input  logic                                                                                   scan_enable_i,
  input  logic                                                                                   scan_data_i,
  output logic                                                                                   scan_data_o,
  // Group ID
  input  logic                            [idx_width(NumGroups)-1:0]                             group_id_i,

  // Group -> MSHR
  input  `STRUCT_VECT(tcdm_master_req_t,  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1])  group_mshr_req_i,
  input  logic                            [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   group_mshr_req_valid_i,
  output logic                            [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   group_mshr_req_ready_o,

  // MSHR -> NoC
  output `STRUCT_VECT(tcdm_master_req_t,  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1])  mshr_noc_req_o,
  output logic                            [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   mshr_noc_req_valid_o,
  input  logic                            [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   mshr_noc_req_ready_i,

  // NoC -> MSHR
  input  `STRUCT_VECT(tcdm_master_resp_t, [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1])  mshr_noc_resp_i,
  input  logic                            [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]  mshr_noc_resp_valid_i,
  output logic                            [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]  mshr_noc_resp_ready_o,

  // MSHR -> Group
  output `STRUCT_VECT(tcdm_master_resp_t, [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1])  group_mshr_resp_o,
  output logic                            [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]  group_mshr_resp_valid_o,
  input  logic                            [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]  group_mshr_resp_ready_i,
  // Runtime configuration (docs/mshr_runtime_csr_design.md). At MshrCfgRuntime=0 every field is a
  // constant driven by mempool_group_mshr_cfg, so the reads below const-fold exactly as the
  // localparams they replace and the netlist is unchanged.
  input  mempool_pkg::mshr_cfg_t                                                          cfg_i,
  // Any entry valid. The CSR file uses it to REFUSE a bank-hash change while entries are resident:
  // the bank index both places an entry and looks it up, so re-hashing mid-flight makes a lookup
  // probe the wrong bank and a second entry is allocated for a line that already has one.
  output logic                                                                            mshr_busy_o
);

  localparam int unsigned RespPortIdW      = idx_width(NumRemoteRespPortsPerTile);
  localparam int unsigned ReqPortIdW       = idx_width(NumRemoteReqPortsPerTile);
  // ParityDrain (TwinROB0 receive): beats of one multi-beat entry drained per cycle. 1 = legacy
  // single-beat drain (all parity-drain logic const-folds out, bit-identical netlist). 2 = beat b
  // of ANY burst entry leaves on resp port 1+(b&1) with core_id+(b&1) -- uniform law, no
  // per-request mode, merge/multicast semantics untouched. Single-word entries (burst_len==1,
  // incl. the response cache) always take the byte-identical legacy path (b=0 -> +0 identity).
  localparam int unsigned DrainBeatsPerEntry =
    `ifdef GROUP_MSHR_DRAIN_BEATS `GROUP_MSHR_DRAIN_BEATS
    `else 1 `endif;
  localparam bit PD2 = (DrainBeatsPerEntry > 1);

  // ------------------------------------------------------------------------------------
  // BURST LANE LAW. Spatz distributes a burst's beats across its four reorder buffers by the
  // ordinary word->port rule, so beat b belongs to VLSU lane b % NrMemPorts and is entry
  // b / NrMemPorts of THAT buffer. tcdm_burst_expander applies it at the destination, so a
  // returning beat carries
  //     core_id = owner core_id + (b % BurstLanes)
  //     meta_id = owner meta_id  + (b / BurstLanes)
  // and b is recovered from BOTH fields rather than from meta_id alone. That is the whole
  // reason this file changed: under the funnel every beat came back on the issuing port with
  // meta_id base+b, so a vector register row was assembled from BurstLanes partial writes --
  // and Spatz chains one cycle after its producer's first write, so a consumer read the row
  // with BurstLanes-1 lanes stale.
  //
  // Identity for a single-word entry (b = 0), which is what keeps the response cache and every
  // scalar reply byte-identical.
  localparam int unsigned BurstLanes = NumMemPortsPerSpatz;
  localparam int unsigned BurstLaneW = idx_width(BurstLanes);
  if (BurstLanes & (BurstLanes - 1))
    $error("[mempool_group_mshr] NumMemPortsPerSpatz (%0d) must be a power of two: the lane law truncates.",
           BurstLanes);

  // Rows a burst of `len` words occupies in each buffer: ceil(len / BurstLanes).
  function automatic logic [BurstLenWidth-1:0] burst_rows(input logic [BurstLenWidth-1:0] len);
    burst_rows = BurstLenWidth'((len + BurstLenWidth'(BurstLanes - 1)) >> BurstLaneW);
  endfunction

  // Beat index of a returning response, from the two fields it is split across.
  function automatic logic [BurstLenWidth-1:0] burst_beat_of(
      input tile_core_id_t resp_core, input meta_id_t      resp_meta,
      input tile_core_id_t base_core, input meta_id_t      base_meta);
    automatic tile_core_id_t lane = resp_core - base_core;
    automatic meta_id_t      row  = resp_meta - base_meta;
    burst_beat_of = BurstLenWidth'((row << BurstLaneW) |
                                   meta_id_t'(lane & tile_core_id_t'(BurstLanes - 1)));
  endfunction

  // Does this response belong to a burst based at (base_core, base_meta) of length len?
  // BOTH halves must be in range before the combined index means anything: the subtractions
  // wrap in their own field widths, so a lane or row from an unrelated request would otherwise
  // fold into a legal-looking beat.
  function automatic logic burst_beat_valid(
      input tile_core_id_t resp_core, input meta_id_t      resp_meta,
      input tile_core_id_t base_core, input meta_id_t      base_meta,
      input logic [BurstLenWidth-1:0] len);
    automatic tile_core_id_t lane = resp_core - base_core;
    automatic meta_id_t      row  = resp_meta - base_meta;
    burst_beat_valid = (lane < tile_core_id_t'(BurstLanes)) &&
                       (row  < meta_id_t'(burst_rows(len)))  &&
                       (burst_beat_of(resp_core, resp_meta, base_core, base_meta) < len);
  endfunction
  // ------------------------------------------------------------------------------------
  // Misconfig guards: the parity datapath is hardwired for 2 beats/cycle and needs both usable
  // resp ports [2:1]; an illegal knob must fail elaboration, not wedge silently at runtime.
  if ((DrainBeatsPerEntry != 1) && (DrainBeatsPerEntry != 2))
    $error("[mempool_group_mshr] group_mshr_drain_beats must be 1 (off) or 2, got %0d.",
           DrainBeatsPerEntry);
  if (DrainBeatsPerEntry > (NumRemoteRespPortsPerTile - 1))
    $error("[mempool_group_mshr] group_mshr_drain_beats (%0d) exceeds usable resp ports (%0d): needs noc_resp_channel_num>=%0d.",
           DrainBeatsPerEntry, NumRemoteRespPortsPerTile - 1, DrainBeatsPerEntry);
  if (PD2 && !DrainMultiPort)
    $error("[mempool_group_mshr] ParityDrain (group_mshr_drain_beats=2) requires DrainMultiPort=1.");
  // The rotated scan indices wrap by TRUNCATION to idx_width() bits rather than by `%`. Since
  // idx_width() is $clog2(), truncation equals mod-N only when N is a power of two -- for any other
  // N it silently wraps at the next power of two instead, corrupting the scan order. Fail loudly.
  if (MshrNum & (MshrNum - 1))
    $error("[mempool_group_mshr] group_mshr_num (%0d) must be a power of two.", MshrNum);
  if (MshrMergeReqs & (MshrMergeReqs - 1))
    $error("[mempool_group_mshr] group_mshr_merge_reqs (%0d) must be a power of two.", MshrMergeReqs);
  if (MshrWaysPerBank & (MshrWaysPerBank - 1))
    $error("[mempool_group_mshr] group_mshr_ways_per_bank (%0d) must be a power of two.",
           MshrWaysPerBank);
  // Hold-the-fetch (request-hold merge window, docs/mshr_request_hold_design.md): a mergeable
  // allocation is consumed locally and its NoC fetch is withheld for up to HoldWindow cycles,
  // releasing EARLY the moment sub_reqs_num reaches HoldSubs. Since merging is legal until the
  // entry's first beat arrives (= issue + round trip), every held cycle extends the merge window
  // 1:1 -- temporal alignment applied at the door, no cross-core signaling, deadlock-free by
  // construction (the countdown always expires). 0 = off, everything const-folds out.
  localparam int unsigned HoldWindow =
    `ifdef GROUP_MSHR_HOLD_WINDOW `GROUP_MSHR_HOLD_WINDOW `else 0 `endif;
  // Per-request-type hold windows (default: the uniform HoldWindow). Scalar single-word loads and
  // multi-beat vector bursts have different sharing/timing, so each gets its own window: at alloc
  // an entry is armed with HoldWindowSingle (burst_len==1) or HoldWindowBurst. A per-type window of
  // 0 means that class is never held (issues its fetch the same cycle, like the feature-off path).
  localparam int unsigned HoldWindowSingle =
    `ifdef GROUP_MSHR_HOLD_WINDOW_SINGLE `GROUP_MSHR_HOLD_WINDOW_SINGLE `else HoldWindow `endif;
  localparam int unsigned HoldWindowBurst =
    `ifdef GROUP_MSHR_HOLD_WINDOW_BURST `GROUP_MSHR_HOLD_WINDOW_BURST `else HoldWindow `endif;
  // The hold feature is active (and its logic generated) iff EITHER class holds; the counter is
  // sized from the larger of the two windows.
  localparam int unsigned HoldWindowMax =
    (HoldWindowSingle > HoldWindowBurst) ? HoldWindowSingle : HoldWindowBurst;
  localparam int unsigned HoldSubs =
    `ifdef GROUP_MSHR_HOLD_SUBS `GROUP_MSHR_HOLD_SUBS `else 2 `endif;
  // Per-request-type early-release targets (default: the uniform HoldSubs). Rationale: the two
  // request classes have different natural sharing degrees -- in the matmul kernel a scalar
  // single (A-line flw) is shared by 8 cores of an m-block, while a vector burst (B-line) is
  // shared by a pair. The type bit (burst_len == 1) is already classified at the door, so the
  // split costs one mux; an address-range discriminator would need programmable range registers
  // for no extra separation power on this traffic.
  localparam int unsigned HoldSubsSingle =
    `ifdef GROUP_MSHR_HOLD_SUBS_SINGLE `GROUP_MSHR_HOLD_SUBS_SINGLE `else HoldSubs `endif;
  localparam int unsigned HoldSubsBurst =
    `ifdef GROUP_MSHR_HOLD_SUBS_BURST `GROUP_MSHR_HOLD_SUBS_BURST `else HoldSubs `endif;
  // Scalar response-release policy. 0 preserves the original behavior: a returned scalar word
  // starts draining to its current subscribers immediately. 1 keeps the returned word resident
  // in MSHR_RESP_HOLD and admits later same-address scalar subscribers until HoldSubsSingle is
  // reached. This is independent of HoldWindowSingle: the request-side hold window is unchanged.
  localparam bit RespWaitSubsSingle =
    `ifdef GROUP_MSHR_RESP_WAIT_SUBS_SINGLE `GROUP_MSHR_RESP_WAIT_SUBS_SINGLE `else 1'b0 `endif;
  // Cache self-invalidate (idea 1, docs/mshr_bank_hash_design.md): a CACHED entry that has served
  // its per-type sharing target (HoldSubsSingle for scalar/single entries, HoldSubsBurst for
  // bursts) self-invalidates, turning the done cache line into an INVALID way promptly (which the
  // invalid-first allocator then prefers, so OTHER cache lines survive). CACHED entries stay
  // reclaimable-on-demand when CacheReclaimable=1. With CacheReclaimable=0, self-invalidation or
  // AMO invalidation is the only release path. 0 = off (served_cnt maintained but unused).
  localparam bit CacheSelfInval =
    `ifdef GROUP_MSHR_CACHE_SELF_INVAL `GROUP_MSHR_CACHE_SELF_INVAL `else 1'b0 `endif;
  // Cache reuse target / cache-phase timeout (group_mshr_cache_reuse_target, _cache_timeout).
  // Both 0 = LEGACY, bit-identical to before they existed: self-invalidate at hold_subs_*, and
  // re-arm the cache phase from serve_timeout. Non-zero decouples cache residency from the
  // subscriber-sharing target -- the fp16 case, where two scalar loads alias one 32-bit word and
  // the second cohort must find the line still resident. Only the RESET values; with
  // MshrCfgRuntime=1 software owns them (mempool_group_mshr_cfg.sv).
  localparam int unsigned CacheReuseTarget =
    `ifdef GROUP_MSHR_CACHE_REUSE_TARGET `GROUP_MSHR_CACHE_REUSE_TARGET `else 0 `endif;
  localparam int unsigned CacheTimeout =
    `ifdef GROUP_MSHR_CACHE_TIMEOUT `GROUP_MSHR_CACHE_TIMEOUT `else 0 `endif;
  // Bank-full policy: 0 = bypass (legacy), 1 = backpressure. Reset value only when
  // MshrCfgRuntime=1; software owns it thereafter.
  localparam int unsigned BankfullBackpressure =
    `ifdef GROUP_MSHR_BANKFULL_BACKPRESSURE `GROUP_MSHR_BANKFULL_BACKPRESSURE `else 0 `endif;
  // RR cache-victim selection (group_mshr_cache_victim_rr): per-bank round-robin start pointer
  // for the pass-2 CACHED-reclaim scan, instead of always taking the lowest-index reclaimable
  // CACHED way (which thrashes way 0 of each bank while high ways stay pinned). The pointer
  // advances to victim+1 ONLY when a reclaim actually fires (a still-valid CACHED way is
  // reallocated) -- never on a mere selection, a stalled grant, or an invalid-way alloc.
  // 0 = legacy lowest-index-first (pointer tied 0, const-folds out -> bit-identical).
  localparam bit CacheVictimRR =
    `ifdef GROUP_MSHR_CACHE_VICTIM_RR `GROUP_MSHR_CACHE_VICTIM_RR `else 1'b0 `endif;
  // CACHED replacement policy. 1 preserves the original pass-2 allocator behavior, where a bank
  // with no INVALID way may reclaim an idle CACHED way. 0 protects CACHED ways from allocation;
  // they remain resident until self-invalidation or the existing AMO invalidation.
  localparam bit CacheReclaimable =
    `ifdef GROUP_MSHR_CACHE_RECLAIMABLE `GROUP_MSHR_CACHE_RECLAIMABLE `else 1'b1 `endif;
  // Bypass-path delivery probe (simulation-only; see the gen_bypass_probe block). 0 = off.
  localparam bit BypassProbe =
    `ifdef GROUP_MSHR_BYPASS_PROBE `GROUP_MSHR_BYPASS_PROBE `else 1'b0 `endif;
  // RESP_HOLD stall probe (simulation-only; see gen_resp_hold_probe). Age in cycles after which a
  // still-held entry is reported; 0 = off.
  localparam int unsigned RespHoldProbe =
    `ifdef GROUP_MSHR_RESP_HOLD_PROBE `GROUP_MSHR_RESP_HOLD_PROBE `else 0 `endif;
  // Stall (instead of allocating a duplicate entry) when a same-address entry is receiving its
  // response this very cycle -- see req_addr_hit_drain_way. 1 = stall and retry (default),
  // 0 = legacy allocate-a-second-way. Costs nothing on the merge/alloc timing path: it reuses
  // mshr_resp_seen_now / mshr_resp_inflight, which already feed req_hit_way at this level.
  localparam bit StallOnResp =
    `ifdef GROUP_MSHR_STALL_ON_RESP `GROUP_MSHR_STALL_ON_RESP `else 1'b1 `endif;
  localparam int unsigned VictimPtrW = (MshrWaysPerBank > 1) ? $clog2(MshrWaysPerBank) : 1;
  // hold_cnt is sized from the window itself, so ANY window value is supported -- there is no
  // width-imposed ceiling (an earlier > 31 guard wrongly claimed one; the counter had always been
  // parameterized). Practical notes when experimenting with large W: a held entry keeps its MSHR
  // way occupied for the full window, and door conflicts on its address / meta-id range stall for
  // up to W cycles; once W approaches the TB scoreboard's 1000-cycle stuck-request threshold the
  // held requests will start raising [CMS WARN] lines. Liveness is independent of W (the countdown
  // is free-running, so the fetch always issues).
  // Serve-target timeout, in cycles. An entry that is holding its response data while waiting to
  // reach a per-type serve target can wait forever if that target is never reached -- the target is
  // a property of the ACCESS PATTERN, which the hardware cannot guarantee. Measured 2026-07-30: the
  // I$ warm-up pass runs the kernel with a clamped row stride, so its scalar A loads never reach
  // HoldSubsSingle=4 and whole MSHR banks saturate (bank[hold=8/8], subs stuck at 1..3 of 4).
  // 0 = no timeout (legacy). Any W > 0 behaves exactly like group_mshr_hold_window: a free-running
  // countdown that is never gated, so liveness holds for ANY target. It covers both waiting states:
  //   RESP_HOLD -> on expiry, deliver to whatever subscribers are present (state = DRAIN_RESP);
  //   CACHED with served_cnt below target -> on expiry, self-invalidate and free the way.
  // The counter reuses the hold_cnt field: the request-side hold only lives in WAIT_RESP && !issued,
  // which is mutually exclusive with both states above, so this costs no extra flops -- only the
  // width has to cover whichever window is larger.
  localparam int unsigned ServeTimeout =
    `ifdef GROUP_MSHR_SERVE_TIMEOUT `GROUP_MSHR_SERVE_TIMEOUT `else 0 `endif;
  // The counter must be sized for the LARGEST value that can ever be loaded, and at
  // MshrCfgRuntime=1 that is the hardware bound, NOT the elaborated default -- software can write
  // any value up to MshrCfgHoldCntMax at any time.
  //
  // Getting this wrong is the same defect class as the C1 rank truncation: a field sized from one
  // source and fed from another. Concretely, a config elaborating hold_window=0 gives HoldCntW=1, so
  // a software write of 2047 would load hold_ticks() = 1'(2047) = 1 -- a 2047-cycle window silently
  // becoming a single tick, with nothing to indicate it.
  localparam int unsigned HoldCntElabMax =
    (HoldWindowMax > ServeTimeout) ? HoldWindowMax : ServeTimeout;
  localparam int unsigned HoldCntMax =
    mempool_pkg::MshrCfgRuntime ? mempool_pkg::MshrCfgHoldCntMax : HoldCntElabMax;
  // HOLD PRESCALER. hold_cnt used to tick every cycle, so it needed enough bits for the whole
  // window in cycles ($clog2(1024) = 10) and up to MshrNum counters toggled every cycle. A shared
  // prescaler divides the tick rate by 2**HoldPrescaleW, so each entry stores the window in TICKS.
  //
  //   area  : 10 -> 6 bits per entry (4 x MshrNum flops per group), minus one shared counter
  //   power : each hold_cnt moves once per 2**HoldPrescaleW cycles instead of every cycle
  //   timing: the (hold_cnt == 0) test in the issue decision narrows from 10 bits to 6
  //
  // The window is a coalescing heuristic and the serve timeout a deadlock backstop, so the
  // resulting +-2**HoldPrescaleW cycle quantisation is immaterial (1.5% at the default).
  //
  // PER-ENTRY PHASE, not a common overflow pulse: entry e ticks when the prescaler equals
  // e[HoldPrescaleW-1:0]. A shared pulse would align every entry's expiry to one global tick, so
  // up to MshrNum held fetches would release into the NoC in the same cycle -- the release
  // bunching this design is measurably sensitive to. Phasing spreads them across the period.
  //
  // HoldPrescaleW = 0 disables the divider and restores exact cycle-accurate behaviour.
  localparam int unsigned HoldPrescaleW =
      `ifdef GROUP_MSHR_HOLD_PRESCALE_W `GROUP_MSHR_HOLD_PRESCALE_W `else 4 `endif;
  localparam int unsigned HoldPrescaleWSafe = (HoldPrescaleW > 0) ? HoldPrescaleW : 1;

  // ------------------------------------------------------------------------------------------
  // DrainFromQ (group_mshr_drain_from_q): source the response-drain eligibility scan from the
  // REGISTERED entry array instead of the combinational next state.
  //
  // WHY: the scan sits at the end of the same always_comb that computes mshr_d, with 86 writes to
  // mshr_d ahead of it, so today the response path is
  //     mshr_q -> [allocate/merge/admit/cache/self-invalidate] -> mshr_d -> [scan] -> resp_out
  // i.e. it does not start at a flop. Reading mshr_q cuts the whole entry-update cone out of the
  // path; the scan then begins at a register.
  //
  // COST: strictly latency. An entry that enters MSHR_DRAIN_RESP, or captures its first beat, in
  // cycle N is seen by the scan in cycle N+1 instead of N. No correctness exposure: each
  // sub-request carries exactly one destination (tile_id, port_id), so it is eligible for exactly
  // one of the NumTilesPerGroup x (NumRemoteRespPortsPerTile-1) scan instances, and port_taken
  // still allows one pick per port per cycle. A stale view therefore cannot let two ports drain
  // the same sub-request -- that invariant is what makes this safe, and it is the same one
  // recorded at the drain scan itself.
  //
  // 0 = off (default, bit-identical to before). 1 = scan the registered array.
  // ------------------------------------------------------------------------------------------
  // BankPublish (group_mshr_bank_publish): stage-1 banked arbitration for the head-beat drain.
  //
  // Each of the MshrBankNum banks publishes ONE entry per cycle, round-robin over its
  // MshrWaysPerBank ways, PORT-INDEPENDENTLY -- so the choice is computed once and shared by all
  // NumTilesPerGroup x (NumRemoteRespPortsPerTile-1) scan instances instead of once each.
  //
  // Publishing an ENTRY (not a sub-request) is what preserves multicast: several ports can still
  // drain different subscribers of the same published entry in the same cycle, because each
  // sub-request carries its own destination (tile,port). The cost is that at most MshrBankNum
  // DISTINCT entries can be drained per cycle instead of up to the port count.
  //
  // THIS IS A BEHAVIOURAL MODEL, NOT THE FINAL STRUCTURE. It masks the existing 64-wide selector
  // rather than narrowing it to 16, so it measures the throughput cost without yet buying the area
  // back. Narrow the select tree only once the cost is known to be acceptable.
  //
  // 0 = off (default, bit-identical). 1 = one entry per bank.
  localparam bit BankPublish =
      `ifdef GROUP_MSHR_BANK_PUBLISH `GROUP_MSHR_BANK_PUBLISH `else 1'b0 `endif;

  localparam bit DrainFromQ =
      `ifdef GROUP_MSHR_DRAIN_FROM_Q `GROUP_MSHR_DRAIN_FROM_Q `else 1'b0 `endif;
  // F2: source the ParityDrain SECOND-SLOT scan from the registered array instead of the in-cycle
  // next state -- the same discipline DrainFromQ already applies to the head-beat scan, extended to
  // the one scan that was left behind.
  //
  // drain2 is the deepest block in the tail of the main process: it builds a 64-bit candidate
  // vector from mshr_d and LSB-isolates it, once per (tile, resp port) = 32 instances, AFTER the
  // response capture and the PD2 arm sweep have already rewritten mshr_d. Reading mshr_q takes all
  // of that off the critical cone (post-placement: 822 levels / 11.07 ns at 2.0 ns TCK).
  //
  // NOT an equivalent transformation when enabled: a beat captured this cycle becomes second-slot
  // drainable NEXT cycle. With RespBufWords = 2 that can cost drain throughput, so it defaults OFF
  // (bit-identical) and the default must not move without a measured number.
  localparam bit Drain2FromQ =
      `ifdef GROUP_MSHR_DRAIN2_FROM_Q `GROUP_MSHR_DRAIN2_FROM_Q `else 1'b0 `endif;
  // F2: source the hold-the-fetch REPLAY walker from the registered array. The walker reads mshr_d
  // after the 32-lane request door has rewritten it, then runs a 64-wide priority encode and a
  // 64:1 field mux per lane -- which is what puts req_out (class C, 3.77 ns post-placement) where
  // it is.
  //
  // Semantic cost when enabled, stated exactly: a FRESH allocation is already never replay-ready
  // (hold_ticks never rounds a non-zero window down to 0, so hold_cnt != 0, and sub_reqs_num = 1 is
  // below any legal target), so only the MERGE-triggered early release moves -- it fires one cycle
  // later. Against a hold window of thousands of cycles that is a rounding error, but it is not
  // zero, so this still defaults OFF.
  localparam bit ReplayFromQ =
      `ifdef GROUP_MSHR_REPLAY_FROM_Q `GROUP_MSHR_REPLAY_FROM_Q `else 1'b0 `endif;
  // F4: accept at most ONE merge per bank per cycle, mirroring the per-bank single ALLOCATION
  // that the arbiter above has always enforced. Losers get req_merge_ready = 0, which deasserts
  // req_in_ready and stalls them for a cycle; they retry against the same still-resident entry and
  // merge then, so coalescing is preserved, just spread over more cycles.
  //
  // This is not a new stall path: the capacity check below (merge_slot + 1 <= MshrMergeReqs) already
  // deasserts req_in_ready on a merge hit and is exercised on every shipping merge_reqs. The lane
  // takes the merge branch either way, so a stalled requester never leaks to the NoC.
  //
  // What it buys: merge_rank exists ONLY to give several lanes merging into the SAME entry distinct
  // sub_reqs slots, and it costs NumAllocSlots^2 (1024 here) mshr_id comparators plus NumAllocSlots
  // population counts, feeding merge_slot -> merge_new_idx -> the sub_reqs write index, i.e. sitting
  // directly on the request door. One merge per bank means at most one merge per ENTRY (an entry
  // belongs to exactly one bank), so the rank is identically zero and the whole network drops out.
  //
  // NOT an equivalent transformation: peak merge acceptance falls from NumAllocSlots per cycle to
  // MshrBankNum. A refused lane is not a lost merge -- it retries next cycle against the same
  // resident entry -- so a cohort still assembles fully, just over more cycles, against a hold
  // window of thousands. [MRGARB] merge_grants / merge_arb_stalls reports the retries.
  //
  // DEFAULT ON. The RTL default (not just the config value) is 1 deliberately: the backend define
  // list does not carry this knob, so a 0 here would silently synthesise the expensive form. Any
  // arm compared against a reference built before this knob existed must PIN it explicitly.
  localparam bit OneMergePerBank =
      `ifdef GROUP_MSHR_ONE_MERGE_PER_BANK `GROUP_MSHR_ONE_MERGE_PER_BANK `else 1'b1 `endif;
  // NOT DONE: the two aging sweeps (cache self-invalidate, and the serve-timeout / cache age-out
  // countdown) are also whole-array passes on mshr_d and were the obvious third knob here. They are
  // deliberately left alone.
  //
  // The serve-timeout sweep is PLACED after response capture on purpose -- its own comment says so
  // -- because it must observe the hold_cnt that the capture path arms when an entry enters
  // MSHR_RESP_HOLD this cycle. Reading mshr_q would show that entry a hold_cnt left over from a
  // previous life, quite possibly 0, and expire it immediately: a returned word delivered to
  // whoever had subscribed so far instead of to its cohort. That is a correctness change, not a
  // one-cycle latency change, and it is not worth taking blind.
  //
  // The self-invalidate sweep is benign by the same analysis (it would just self-invalidate a
  // cycle later), but it is the shallower of the two and not worth a knob on its own.
  //
  // Revisit once the drain2 and replay numbers are in and the remaining depth is known.
  if (Drain2FromQ && !PD2)
    $error("[mempool_group_mshr] group_mshr_drain2_from_q needs group_mshr_drain_beats=2; the second-slot scan does not exist otherwise.");
  localparam int unsigned HoldCntTicks =
      (HoldPrescaleW == 0) ? HoldCntMax : (HoldCntMax >> HoldPrescaleW);
  localparam int unsigned HoldCntW = (HoldCntTicks > 1) ? $clog2(HoldCntTicks + 1) : 1;
  // Convert a cycle count from the config into ticks. Never rounds a non-zero window down to
  // zero, which would silently turn "hold briefly" into "do not hold at all".
  function automatic logic [HoldCntW-1:0] hold_ticks(input int unsigned cycles);
    if (HoldPrescaleW == 0) hold_ticks = HoldCntW'(cycles);
    else if (cycles == 0)   hold_ticks = '0;
    else begin
      hold_ticks = HoldCntW'(cycles >> HoldPrescaleW);
      if (hold_ticks == '0) hold_ticks = HoldCntW'(1);
    end
  endfunction
  // Lower bound is 1, not 2: 1 is the defined "bypass this class" encoding, matched by the runtime
  // range check (mempool_group_mshr_cfg.sv: subs_ok = [1, MergeReqs]) and by
  // cfg_bypass_{single,burst} at :486-487. The old [2, ...] guard predated that semantics and made a
  // legal runtime value illegal as a reset value -- so a flavour could not ship a bypassed class,
  // and elaborating what software is allowed to write failed the build. At 1 the class never
  // allocates an entry, so the subscriber/hold/self-invalidate machinery is simply not exercised for
  // it; nothing downstream needs >= 2. (ServedCntW is safe: worst case both == 1 gives a 1-bit
  // counter, and both classes bypass so it is unused.)
  if ((HoldSubs < 1) || (HoldSubs > MshrMergeReqs))
    $error("[mempool_group_mshr] group_mshr_hold_subs (%0d) must be in [1, MshrMergeReqs].",
           HoldSubs);
  if ((HoldSubsSingle < 1) || (HoldSubsSingle > MshrMergeReqs) ||
      (HoldSubsBurst  < 1) || (HoldSubsBurst  > MshrMergeReqs))
    $error("[mempool_group_mshr] group_mshr_hold_subs_single/burst (%0d/%0d) must be in [1, MshrMergeReqs].",
           HoldSubsSingle, HoldSubsBurst);
  if (RespWaitSubsSingle && !EnableMshrSingleReq)
    $error("[mempool_group_mshr] group_mshr_resp_wait_subs_single requires scalar MSHRs.");
  // Both of these remove a release path that previously bounded how long an entry can hold data:
  // resp_wait_subs_single makes delivery wait for a subscriber target, and cache_reclaimable=0 stops
  // an idle CACHED way from being an allocation victim. With neither a timeout nor those paths, an
  // entry whose target the access pattern never delivers holds its way forever. Refuse the
  // combination rather than let it wedge a bank silently at run time.
  if ((RespWaitSubsSingle || !CacheReclaimable) && (ServeTimeout == 0))
    $error("[mempool_group_mshr] group_mshr_resp_wait_subs_single=1 or group_mshr_cache_reclaimable=0 requires group_mshr_serve_timeout > 0 (no release path otherwise).");
  localparam int unsigned SubReqCountW     = idx_width(MshrMergeReqs + 1);

  // ------------------------------------------------------------------------------------------
  // RUNTIME CONFIG SELECT. Each signal is the localparam when MshrCfgRuntime = 0 -- so it folds to
  // a constant and nothing downstream changes -- and the CSR field when 1. Read THESE at the use
  // sites, never the localparams.
  //
  // Only compare operands and shift amounts appear here. Anything that sizes an array or a struct
  // (MshrNum, MshrWaysPerBank, MshrMergeReqs, RespBufWords) stays elaboration-time by construction.
  // ------------------------------------------------------------------------------------------
  logic [mempool_pkg::MshrCfgSubsW-1:0]    cfg_hold_subs_single, cfg_hold_subs_burst;
  logic [mempool_pkg::MshrCfgHoldCntW-1:0] cfg_hold_window_single, cfg_hold_window_burst;
  logic [mempool_pkg::MshrCfgHoldCntW-1:0] cfg_serve_timeout;
  logic [mempool_pkg::MshrCfgSubsW-1:0]    cfg_cache_reuse_target;
  logic [mempool_pkg::MshrCfgHoldCntW-1:0] cfg_cache_timeout;
  logic                                   cfg_bankfull_bp;
  // Effective cache-phase countdown: the dedicated value when set, else the legacy serve_timeout.
  logic [mempool_pkg::MshrCfgHoldCntW-1:0] cfg_cache_hold_ticks_src;
  logic [mempool_pkg::MshrCfgShiftW-1:0]   cfg_bank_shift_single, cfg_bank_shift_burst;
  logic                                    cfg_bank_burst_bits, cfg_mshr_enable;
  // R3: hold_subs == 1 means "this class does not merge -- bypass it". That gives the value the
  // auto-tuner naturally produces for a 1-way-shared operand (B at M=128) the right meaning instead
  // of clamping it up to 2 and then always timing out, which is what the per-shape
  // `hold_window_burst := 0` pin was approximating.
  logic                                    cfg_bypass_single, cfg_bypass_burst;

  // C1 FIX (2026-08-14): the merge rank and slot need their OWN width, not SubReqCountW.
  //
  // The bug: merge_rank was SubReqCountW and took `SubReqCountW'($countones(mask))` over a
  // NumAllocSlots-wide (32) mask, so a rank above SubReqCountW's range wrapped mod 2**SubReqCountW;
  // merge_slot = sub_reqs_num + rank then wrapped again. The capacity check runs on the WRAPPED
  // slot, so a wrapped-to-small slot PASSES and the port overwrites a live sub_reqs[] record --
  // destroying the owner's tile/core/meta, which then never receives its response. Reachable at
  // every shipping merge_reqs (4/8/16), because req_merge_ready is unconditionally 1 and
  // req_merge_valid tests only an address/state hit, so the rank mask is capacity-BLIND and counts
  // ports that could never be accepted.
  //
  // Why the pre-C1 form was safe: it read the RUNNING mshr_d[..].sub_reqs_num, which the capacity
  // check itself clamps at MshrMergeReqs, so no value could ever exceed the field.
  //
  // Fix, in two parts, both needed:
  //   (a) SATURATE the rank at MshrMergeReqs. Exact, not approximate: a port with >= MshrMergeReqs
  //       earlier same-entry ports has slot >= rank >= MshrMergeReqs, so it fails
  //       (slot + 1) <= MshrMergeReqs no matter what the true rank is. Every rank at or above the
  //       cap is therefore behaviourally identical, and clamping loses nothing.
  //   (b) Size rank and slot to hold 2*MshrMergeReqs, since slot = sub_reqs_num + rank and both
  //       terms reach MshrMergeReqs after (a). Saturation alone is NOT sufficient -- at
  //       merge_reqs=4 a saturated rank of 4 plus sub_reqs_num 4 still overflows SubReqCountW.
  localparam int unsigned MergeRankW      = idx_width(2 * MshrMergeReqs + 1);
  localparam int unsigned MergeCountW     = idx_width(NumTilesPerGroup *
                                              ((NumRemoteReqPortsPerTile > 1) ?
                                               (NumRemoteReqPortsPerTile - 1) : 1) + 1);
  // served_cnt only has to reach the larger sharing target, where it saturates.
  //
  // ⚠ WITH RUNTIME CSRs THE ELABORATED VALUES ARE ONLY THE RESET VALUES. Software may later write
  // any hold_subs in [1, MshrMergeReqs], and :3358 casts that RUNTIME value to ServedCntW. Sizing
  // this width from the elaborated defaults would truncate the comparison the moment software wrote
  // something larger than the default -- e.g. defaults 2/2 give a 2-bit counter (max 3), so a write
  // of 16 casts to 0 and the self-invalidate compare becomes always-true, silently destroying
  // merging. That is the exact defect already fixed for the hold window at HoldCntMax (:253-256);
  // this is its sibling.
  //
  // It happened to be unreachable because every shipped flavour sets hold_subs_single == merge_reqs,
  // so the elaborated max already spanned the runtime range -- an accident, not an invariant, and
  // nothing enforced it. Sizing from MshrMergeReqs removes the dependence on that coincidence.
  // MshrCfgRuntime = 0 still folds to the old width, so a fixed-function build is unchanged.
  localparam int unsigned ServedCntElabMax = (HoldSubsSingle > HoldSubsBurst)
                                             ? HoldSubsSingle : HoldSubsBurst;
  // 2*MshrMergeReqs, not MshrMergeReqs. served_cnt is CUMULATIVE over the successive cohorts one
  // cached line serves, and cache_reuse_target may now be written up to 2*MergeReqs (the fp16
  // half-word case: the same S cores touch the line twice, so its useful life ends at 2S). Sized
  // at MergeReqs the counter is 5 bits, 32 is not representable, it wraps to 0, and the compare
  // `served_cnt >= target` could never fire -- the line would be pinned until a timeout. One extra
  // bit per entry. Worst case before the compare fires is 2*MergeReqs + (MergeReqs-1) = 47 < 63,
  // so the widened counter cannot wrap either.
  localparam int unsigned ServedCntMax     = mempool_pkg::MshrCfgRuntime ? (2 * MshrMergeReqs)
                                                                         : ServedCntElabMax;
  localparam int unsigned ServedCntW       = idx_width(ServedCntMax + 1);
  localparam int unsigned RespBufCountW    = idx_width(RespBufWords + 1);
  localparam int unsigned RespBufPtrW      = idx_width(RespBufWords);
  localparam int unsigned MergeWordOffset  = (MshrMergeWords <= 1) ? 0 : $clog2(MshrMergeWords);
  localparam int unsigned BurstAlignBits  = (MaxBurstWords > 1) ? $clog2(MaxBurstWords) : 1;
  // ParityDrain bypass-retag tracking depth (FF-1). Depth 2 encodes "one instruction in flight x
  // <=2 bursts/insn" -- but the VLSU burst admission scales with the ROB depth, so at ROB64 one
  // e32,m4 load alone is 4 bursts and a full MSHR bank would overflow the 2 ways -> the depth
  // assert $fatals. Bound: outstanding bypass ways <= floor(RobDepth/MaxBurstWords), because any
  // 16-id grant implies the oldest 16 ROB pops completed, and in-order pops retire the oldest
  // tracked burst completely. max(2, ...) keeps today's shape at ROB32.
  //
  // OVERRIDE (GROUP_MSHR_BYPASS_WAYS, 2026-08-29). The derived bound above is exact only while
  // vl < RobDepth words. At vl == RobDepth it is critically sized with ZERO margin: a 512 B load
  // at ROB128 is 128 words = 8 bursts = all 8 ways, so ONE instruction fills the track and a
  // back-to-back second one overflows it. Measured on a GEMM inner loop (KS=1, 512 B loads);
  // vector-burst-test never showed it because it issues isolated loads that retire in between.
  // Overflow is NOT a correctness bug -- :1067 leaves the burst untracked and it degrades to
  // 1-wide, correct but without ParityDrain's 2-wide drain -- but the assert $fatals, and the
  // degradation lands exactly where bandwidth matters most.
  //
  // Left as an explicit knob rather than doubling the formula: doubling would take ROB32 from
  // 2 -> 4 ways and ROB64 from 4 -> 8, perturbing every validated baseline for a case they
  // cannot reach. Unset = bit-identical.
  localparam int unsigned BypassTrackWaysDerived =
    (2 > (snitch_pkg::RobDepth / MaxBurstWords)) ? 2 : (snitch_pkg::RobDepth / MaxBurstWords);
  localparam int unsigned BypassTrackWays =
    `ifdef GROUP_MSHR_BYPASS_WAYS `GROUP_MSHR_BYPASS_WAYS `else BypassTrackWaysDerived `endif;
  // Way-index width for the match->retire path. MUST track BypassTrackWays: at 4 ways a 1-bit
  // index aliases ways 2/3 onto 0/1, leaking them (allocated, never retired) until the overflow
  // assert fires (observed on 512x256x512 fmatmul, the first geometry with >2 concurrent bypasses).
  localparam int unsigned BypassTrackWayW = (BypassTrackWays > 1) ? $clog2(BypassTrackWays) : 1;
  localparam int unsigned TileIdBits       = idx_width(NumTilesPerGroup);
  localparam int unsigned TcdmAddrNoTileW  = $bits(tcdm_addr_t) - TileIdBits;
  localparam int unsigned SpatzNumOutstandingLoads = snitch_pkg::NumIntOutstandingLoads;
  // Address-banking geometry (Increment 3): MshrBankNum banks of MshrWaysPerBank entries each.
  localparam int unsigned MshrBankNum = (MshrWaysPerBank > 0) ? (MshrNum / MshrWaysPerBank) : 1;
  localparam int unsigned BankIdW     = idx_width(MshrBankNum);
  // Current coalescer merges only exact 32-bit words (MshrMergeWords should be 1).

  // Bank-select hash choice (docs/mshr_bank_hash_design.md). 0 (default) = the legacy strided
  // XOR-fold; 1 = an xorshift-mixed fold that de-correlates address bits sharing a residue class
  // mod BankIdW (the legacy fold maps every address bit i to the single bank bit (i-align) mod
  // BankIdW, so a concurrent working set differing only in bits of one residue class collapses
  // onto 2 banks -- the temporal bank concentration this knob targets). Both are pure functions of
  // {group, line address}, so same-line requests always hash to the same bank -> coalescing is
  // preserved by construction regardless of the choice.
  localparam int unsigned BankHash =
    `ifdef GROUP_MSHR_BANK_HASH `GROUP_MSHR_BANK_HASH `else 0 `endif;
  // Bank-select field shift for BankHash==3 (field-select on the reconstructed LINEAR word
  // address). bank = word_addr[BankSelShift +: BankIdW]. Default 5 = the matmul A-load stride
  // (N=32 words -> log2(N)=5), i.e. word-address bits [BankSelShift+BankIdW-1 : BankSelShift].
  // Compile-time for now (a runtime SW register can drive this later; see docs). The word address
  // is reconstructed from {addr_key, group} by pure re-wiring (§0 layout):
  //   word[bank_in_tile | tile | group | bank_row]  (group re-inserted above the tile field).
  localparam int unsigned BankSelShift =
    `ifdef GROUP_MSHR_BANK_SHIFT `GROUP_MSHR_BANK_SHIFT `else 5 `endif;
  // Per-request-type field-select shifts (default: the uniform BankSelShift). The two concurrent
  // streams of a vector kernel have different key strides -- scalar loads step by the data row
  // stride, bursts step by MaxBurstWords -- so one shift cannot give both the maximal spread.
  // The classifier is the CLAMPED req_is_single (:878), NEVER req_len_raw: a store is force-clamped
  // to req_len=1, and it must hash like the single-word CACHED entry it write-updates (:2026-2031),
  // otherwise it misses that copy and leaves stale data for a later cache hit.
  localparam int unsigned BankSelShiftSingle =
    `ifdef GROUP_MSHR_BANK_SHIFT_SINGLE `GROUP_MSHR_BANK_SHIFT_SINGLE `else BankSelShift `endif;
  localparam int unsigned BankSelShiftBurst =
    `ifdef GROUP_MSHR_BANK_SHIFT_BURST `GROUP_MSHR_BANK_SHIFT_BURST `else BankSelShift `endif;
  // Burst-branch hash structure (BankHash==3, bursts only). A vector load of VL words issues
  // VL/MaxBurstWords bursts; with LMUL=m (e32) that is exactly m bursts, i.e. clog2(m) address
  // bits ABOVE the burst boundary distinguish one load's bursts from each other. The concurrent
  // requests the bank spread must separate are the DISTINCT (p_start, burst-half) pairs of one
  // inner iteration, so the burst bank index is built from two disjoint fields:
  //   bank = { word_addr[BankSelShiftBurst +: BankIdW-BankBurstBits],   <- inter-core field
  //            word_addr[BurstAlignBits  +: BankBurstBits] }            <- intra-load burst bits
  // BankSelShiftBurst = clog2 of the p_start GAP between sibling cores in words (the workload's
  // core-to-core address step); the field above it carries the bits that distinguish the cores
  // (and, at its top, the unrolled-iteration parity). The low BankBurstBits come from just above
  // the burst boundary (BurstAlignBits tracks MaxBurstWords automatically if the HW burst length
  // ever grows). BankBurstBits = clog2(bursts per load): m1=0, m2=1, m4=2, m8=3. m1 -> 0 bits ->
  // the burst branch degenerates to the plain contiguous field, like a single.
  localparam int unsigned BankBurstBits =
    `ifdef GROUP_MSHR_BANK_BURST_BITS `GROUP_MSHR_BANK_BURST_BITS `else 1 `endif;
  // Drive the runtime-config selects. MshrCfgRuntime is a compile-time constant, so each ternary
  // collapses at elaboration: at 0 these ARE the localparams and every downstream expression is
  // structurally what it was before the CSRs existed.
  assign cfg_mshr_enable        = mempool_pkg::MshrCfgRuntime ? cfg_i.enable : 1'b1;
  assign cfg_hold_subs_single   = mempool_pkg::MshrCfgRuntime ? cfg_i.hold_subs_single
                                                              : mempool_pkg::MshrCfgSubsW'(HoldSubsSingle);
  assign cfg_hold_subs_burst    = mempool_pkg::MshrCfgRuntime ? cfg_i.hold_subs_burst
                                                              : mempool_pkg::MshrCfgSubsW'(HoldSubsBurst);
  assign cfg_hold_window_single = mempool_pkg::MshrCfgRuntime ? cfg_i.hold_window_single
                                                              : mempool_pkg::MshrCfgHoldCntW'(HoldWindowSingle);
  assign cfg_hold_window_burst  = mempool_pkg::MshrCfgRuntime ? cfg_i.hold_window_burst
                                                              : mempool_pkg::MshrCfgHoldCntW'(HoldWindowBurst);
  assign cfg_serve_timeout      = mempool_pkg::MshrCfgRuntime ? cfg_i.serve_timeout
                                                              : mempool_pkg::MshrCfgHoldCntW'(ServeTimeout);
  assign cfg_bank_shift_single  = mempool_pkg::MshrCfgRuntime ? cfg_i.bank_shift_single
                                                              : mempool_pkg::MshrCfgShiftW'(BankSelShiftSingle);
  assign cfg_bank_shift_burst   = mempool_pkg::MshrCfgRuntime ? cfg_i.bank_shift_burst
                                                              : mempool_pkg::MshrCfgShiftW'(BankSelShiftBurst);
  assign cfg_bank_burst_bits    = mempool_pkg::MshrCfgRuntime ? cfg_i.bank_burst_bits
                                                              : (BankBurstBits != 0);
  assign cfg_cache_reuse_target = mempool_pkg::MshrCfgRuntime ? cfg_i.cache_reuse_target
                                                              : mempool_pkg::MshrCfgSubsW'(CacheReuseTarget);
  assign cfg_cache_timeout      = mempool_pkg::MshrCfgRuntime ? cfg_i.cache_timeout
                                                              : mempool_pkg::MshrCfgHoldCntW'(CacheTimeout);
  assign cfg_bankfull_bp        = mempool_pkg::MshrCfgRuntime ? cfg_i.bankfull_backpressure
                                                              : (BankfullBackpressure != 0);
  // 0 => legacy: the cache phase re-arms from serve_timeout, exactly as before.
  assign cfg_cache_hold_ticks_src = (cfg_cache_timeout != '0) ? cfg_cache_timeout : cfg_serve_timeout;
  // A class bypasses when its merge target is 1 (nothing to merge with) or the MSHR is disabled.
  assign cfg_bypass_single      = !cfg_mshr_enable || (cfg_hold_subs_single == mempool_pkg::MshrCfgSubsW'(1));
  assign cfg_bypass_burst       = !cfg_mshr_enable || (cfg_hold_subs_burst  == mempool_pkg::MshrCfgSubsW'(1));
  localparam int unsigned BankInTileW  = idx_width(mempool_pkg::NumBanksPerTile);
  localparam int unsigned GroupBits    = idx_width(NumGroups);
  // Reconstructed linear word address width = full addr_key + the re-inserted group field.
  localparam int unsigned WordAddrW    = $bits(tcdm_addr_t) + GroupBits;
  if ((BankHash == 3) && (BankSelShiftSingle + BankIdW > WordAddrW))
    $error("[mempool_group_mshr] group_mshr_bank_shift_single (%0d) + BankIdW (%0d) exceeds word-addr width (%0d).",
           BankSelShiftSingle, BankIdW, WordAddrW);
  if ((BankHash == 3) && (BankSelShiftBurst + (BankIdW - BankBurstBits) > WordAddrW))
    $error("[mempool_group_mshr] group_mshr_bank_shift_burst (%0d) + gap field (%0d) exceeds word-addr width (%0d).",
           BankSelShiftBurst, BankIdW - BankBurstBits, WordAddrW);
  // The two burst-hash fields must not overlap: the gap field starts at BankSelShiftBurst, the
  // intra-load burst bits end at BurstAlignBits+BankBurstBits-1. An overlapping shift (e.g. the
  // legacy contiguous value 4 at BankBurstBits=1) would double-count a bit and collapse half
  // the banks -- retune shift_burst to the p_start gap bit (see the config comment).
  if ((BankHash == 3) && (BankSelShiftBurst < BurstAlignBits + BankBurstBits))
    $error("[mempool_group_mshr] group_mshr_bank_shift_burst (%0d) overlaps the intra-load burst bits [%0d +: %0d]. Set it to clog2(p_start gap in words), e.g. 5 (M=P=256) / 7 (M=P=512).",
           BankSelShiftBurst, BurstAlignBits, BankBurstBits);
    // bb == BankIdW is LEGAL: every bank bit then comes from the intra-load burst index,
    // which is exactly what a shape with ONE p-slice per group (KS=1) needs -- there the gap
    // field is constant and would pin the whole group to a single bank. Only bb > BankIdW
    // is nonsense.
    if ((BankHash == 3) && (BankBurstBits > BankIdW))
      $error("[mempool_group_mshr] group_mshr_bank_burst_bits (%0d) exceeds BankIdW (%0d).",
           BankBurstBits, BankIdW);

  // Map a (target group, merge address key, request type) to its MSHR bank. Folds address bits
  // ABOVE the burst-alignment boundary (so a burst's beats stay within one bank) together with the
  // target group. Pure function of {group, addr, TYPE} -- no requester dependence -- so all
  // same-(group,line,type) requests hash to the same bank (cross-tile merge preserved).
  // is_single only matters for BankHash==3 (the two field-select shifts); every other mode ignores
  // it and stays a pure function of {group,addr}. Splitting single from burst costs ZERO merging:
  // req_hit_way already requires burst_len equality (:1197) and the CACHED arm requires req_len==1
  // (:1203), so a single and a burst for the same line can never merge in the first place.
  // The three hash fields arrive as ARGUMENTS rather than being read from localparams, so the body
  // is identical whether they are constants (MshrCfgRuntime=0: every caller passes the same constant
  // and the part-selects fold back to wires) or CSR fields.
  function automatic logic [BankIdW-1:0] mshr_bank_of(input tcdm_addr_t addr_key, input group_id_t grp,
                                                      input logic is_single,
                                                      input logic [mempool_pkg::MshrCfgShiftW-1:0] sh_single,
                                                      input logic [mempool_pkg::MshrCfgShiftW-1:0] sh_burst,
                                                      input logic [mempool_pkg::MshrCfgBurstBitsW-1:0] burst_bits);
    logic [BankIdW-1:0]              b;
    logic [$bits(tcdm_addr_t)-1:0]   mix;
    logic [WordAddrW-1:0]            word_addr;
    b = BankIdW'(grp);
    if (BankHash == 3) begin
      // Field-select on the reconstructed LINEAR word address (pure re-wiring: put the group
      // field back above the tile field). Singles take BankIdW contiguous bits at
      // BankSelShiftSingle. Bursts take the split field documented at BankBurstBits above:
      // { gap field at BankSelShiftBurst : BankIdW-BankBurstBits bits } over
      // { intra-load burst bits at BurstAlignBits : BankBurstBits bits }. Equal-shift defaults
      // (and BankBurstBits=0) collapse to the old contiguous behaviour. Coalescing-safe: same
      // line AND same type -> same word_addr -> same bank. All part-selects are constant, so
      // this is re-wiring plus a 2:1 mux.
      word_addr = { addr_key[$bits(tcdm_addr_t)-1 : TileIdBits + BankInTileW], // bank_row (high)
                    grp[GroupBits-1:0],                                        // group
                    addr_key[TileIdBits-1:0],                                  // tile
                    addr_key[TileIdBits +: BankInTileW] };                     // bank_in_tile (low)
      if (is_single) begin
        b = word_addr[sh_single +: BankIdW];
      end else if (!burst_bits) begin
        b = word_addr[sh_burst +: BankIdW];
      end else begin
        // ONE intra-load bit: the high BankIdW-1 bits from the p-slice gap at sh_burst, plus the
        // bit just above the burst boundary. Two constant part-selects -- no second variable shift.
        // bb is capped at 1 by construction (mempool_pkg::MshrCfgBurstBitsW), and a CSR write above
        // that is REFUSED with MSHR_STATUS_RANGE rather than truncated, so this can never be
        // silently asked for something it does not implement. Measured justification: every merging
        // burst class in the decode grid reaches its ceiling at bb=0, and KS=8 prefill at bb<=1.
        b = { word_addr[sh_burst +: BankIdW - 1],
              word_addr[BurstAlignBits +: 1] };
      end
    end else if (BankHash == 0) begin
      // Legacy: each bank bit is the XOR of a fixed stride-BankIdW subset of address bits.
      for (int i = BurstAlignBits; i < $bits(tcdm_addr_t); i++) begin
        b[(i - BurstAlignBits) % BankIdW] = b[(i - BurstAlignBits) % BankIdW] ^ addr_key[i];
      end
    end else if (BankHash == 1) begin
      // (Superseded by 2; kept for the record.) xorshift-mix the line index then fold. FAILED:
      // still GF(2)-linear AND still drops addr_key[BurstAlignBits-1:0], so it discards the tile
      // field -- the very bits that distinguish the concurrent colliding requests (measured: it is
      // bit-identical to the legacy fold on the real matmul traffic). See docs/mshr_bank_hash_design.md.
      mix = addr_key >> BurstAlignBits;
      mix = mix ^ (mix >> 7);
      mix = mix ^ (mix >> 13);
      mix = mix ^ (mix >> 17);
      for (int i = 0; i < $bits(tcdm_addr_t); i++) begin
        b[i % BankIdW] = b[i % BankIdW] ^ mix[i];
      end
    end else begin
      // Include the low BurstAlignBits (the tile field of tgt_addr) in the bank index, on top of
      // the legacy fold of the higher bits. MEASURED root cause: at every bank-full overflow ~13/16
      // banks are free and the colliding requests differ ONLY in addr_key[BurstAlignBits-1:0] (the
      // tile field) -- distinct addresses (scalar A-loads to different tiles of the same bank-row)
      // that the legacy fold drops and thus collapses onto one bank. XORing those bits in spreads
      // them ~2.4x (avg distinct banks/window 1.84 -> 4.5). Coalescing preserved: still a pure
      // function of {group, full addr_key}, so same-line requests share a bank; aligned bursts have
      // addr_key[BurstAlignBits-1:0]==0 so their bank is unchanged.
      b = b ^ BankIdW'(addr_key[BurstAlignBits-1:0]);
      for (int i = BurstAlignBits; i < $bits(tcdm_addr_t); i++) begin
        b[(i - BurstAlignBits) % BankIdW] = b[(i - BurstAlignBits) % BankIdW] ^ addr_key[i];
      end
    end
    return b;
  endfunction

  // Per-entry MSHR lifecycle:
  // - IDLE       : entry is free/unused (typically valid=0).
  // - WAIT_RESP  : entry is allocated; requests are tracked while waiting for NoC data.
  // - DRAIN_RESP : at least one response beat is buffered; current head beat drains to subscribers.
  // - CACHED     : best-effort response cache state (no pending sub-requests, data kept for hits).
  //                On a cache hit the entry can go back to DRAIN_RESP; on replacement it is reallocated.
  // - RESP_HOLD  : a scalar response is buffered, but delivery waits for HoldSubsSingle subscribers.
  typedef enum logic [2:0] {
    MSHR_IDLE       = 3'b000,
    MSHR_WAIT_RESP  = 3'b001,
    MSHR_DRAIN_RESP = 3'b010,
    MSHR_CACHED     = 3'b011,
    MSHR_RESP_HOLD  = 3'b100
  } mshr_state_t;

  typedef struct packed {
    logic           valid;
    tile_group_id_t tile_id;
    logic [RespPortIdW-1:0] port_id;
    tile_core_id_t  core_id;
    // Base meta_id of this requester. Per-beat, the drain emits
    // (meta_id_base + beat/BurstLanes) on (core_id + beat%BurstLanes) -- see BurstLanes.
    meta_id_t       meta_id_base;
    // NOTE: no `amo` field. A sub-request can only exist behind req_can_merge (1057), which
    // requires req_is_load (1006) = valid && ~wen && (wdata.amo == '0). Both the merge and the
    // allocate path are gated on it, so the AMO code of a stored requester is provably zero --
    // it was 4 bits x MshrMergeReqs = 16 flops per entry recording a constant.
  } mempool_group_mshr_sub_req_t;

  // Response-buffer slot. NOT a full tcdm_master_resp_t: only these three fields are ever read
  // back out. The drain path builds its reply from sub_reqs, not from the buffer --
  //     .wen           <- resp_buf                                (head drain, 2nd-slot drain)
  //     .rdata.data    <- resp_buf
  //     .rdata.core_id <- sub_reqs[].core_id      + beat % BurstLanes
  //     .rdata.meta_id <- sub_reqs[].meta_id_base + beat / BurstLanes
  //     .rdata.amo     <- constant '0 (sub-requests are loads: req_is_load gate)
  // so core_id, amo and mshr_tag were stored and never used: 14 of 53 bits per slot, x2 slots
  // x64 entries = 1792 flops per group (114,688 at 8x8).
  // mshr_tag in particular is the entry's own index -- known from where the slot lives.
  //
  // The slot stores the BEAT INDEX, not the meta_id it used to. The beat is now split across
  // meta_id and core_id (see BurstLanes), so re-deriving it on the drain path would mean
  // storing both fields; computing it once at capture stores neither. Same width as the
  // meta_id it replaces whenever BurstLenWidth <= MetaIdWidth, and never wider by more than
  // the difference.
  typedef struct packed {
    logic [BurstLenWidth-1:0] beat_off;
    data_t                    data;
  } mshr_resp_slot_t;

  typedef struct packed {
    // Canonical merged address key (tile bits included) used for hit lookup.
    tcdm_addr_t base_addr;
    // Target group used to route requests in NoC and to disambiguate same address
    // targeting different groups.
    group_id_t tgt_group_id;
    // Burst length for this merged entry (1..MaxBurstWords). All merged requesters
    // in this entry share the same burst_len.
    logic [BurstLenWidth-1:0] burst_len;
    // Requester records merged in this entry (one record per requester, not per beat).
    // sub_reqs[0] is reserved for the owner request used as match anchor.
    mempool_group_mshr_sub_req_t [MshrMergeReqs-1:0] sub_reqs;
    // Number of valid requester records currently stored in sub_reqs.
    logic [SubReqCountW-1:0] sub_reqs_num;
    // Cache self-invalidate (group_mshr_cache_self_inval): cumulative count of sub-requests this
    // entry has admitted/served over its whole life (owner + every merge, in WAIT_RESP and CACHED).
    // When it reaches the entry's per-type sharing target the entry self-invalidates (see the
    // self-invalidate block). Unused (stays 0) when the feature is off.
    // Width derived from the only values it is compared against (HoldSubsSingle/HoldSubsBurst:
    // 4 in the shipped configs, 16 in the widest preset). It was a fixed [5:0] holding up to 63.
    logic [ServedCntW-1:0] served_cnt;
    // Per-head-beat pending mask: bit s=1 means requester s still needs the current
    // buffered response beat; cleared as each requester is serviced.
    logic [MshrMergeReqs-1:0] beat_pending;
    // ParityDrain second-slot service state (the beat at resp_buf_rd_ptr+1, burst entries only):
    // pending mask + one-shot arm flag. Armed exactly once per buffered beat (eager init), so an
    // already-served slot can never be re-delivered; on a head pop the (possibly partial) mask is
    // promoted to beat_pending, or the slot pops together with the head when fully served.
    logic [MshrMergeReqs-1:0] beat_pending2;
    logic                     beat2_armed;
    // Number of response beats still required to complete the whole entry.
    // Decremented once per fully drained beat.
    logic [BurstLenWidth-1:0] beats_left;
    // Per-beat bookkeeping (no per-beat payload stored here):
    // - beat_seen[b]   : beat b has been captured from NoC (possibly out-of-order)
    // - beat_done[b]   : beat b has been fully drained to all merged requesters
`ifndef TARGET_SYNTHESIS
    // VERIFICATION ONLY. Every read of beat_seen is an assertion (beat_done must be a subset
    // of it; hold-the-fetch must see no response activity before issue), all under
    // `!VERILATOR` / `!TARGET_SYNTHESIS`. Synthesis was carrying 16 flops per entry -- 1024
    // per group, 65,536 at 8x8 -- that nothing reads. Writes below are guarded to match.
    logic [MaxBurstWords-1:0] beat_seen;
`endif
`ifndef TARGET_SYNTHESIS
    // VERIFICATION ONLY, for the same reason as beat_seen above: its only reader is the
    // beat_done_subset_seen assertion. Synthesised completion is tracked by beats_left, a
    // counter the state machine actually tests; this per-beat bitmap existed so the
    // assertion could check beat_done is a subset of beat_seen. 16 flops per entry.
    logic [MaxBurstWords-1:0] beat_done;
`endif
    // Small per-entry response FIFO to absorb returning beats while outputs are
    // temporarily blocked or responses arrive from multiple channels.
    mshr_resp_slot_t [RespBufWords-1:0] resp_buf;
    // Valid bit per response-buffer slot.
    // Number of valid beats currently stored in resp_buf.
    logic [RespBufCountW-1:0] resp_buf_cnt;
    // Read pointer of resp_buf head beat to be drained next.
    logic [RespBufPtrW-1:0] resp_buf_rd_ptr;
    // Write pointer where the next captured response beat is stored.
    logic [RespBufPtrW-1:0] resp_buf_wr_ptr;
    // Convenience mirror of (resp_buf_cnt != 0), used by scheduling logic.
    // resp_valid removed: a registered mirror of (resp_buf_cnt != '0). An assertion in this file
    // asserted exactly that identity, so the duplicate carried no information. Readers decode it.
    // Cleared when a store/AMO overlaps a held response. Existing subscribers may consume the
    // captured value, but the entry must deallocate afterward instead of caching stale data.
    logic cacheable;
`ifndef TARGET_SYNTHESIS
    // Debug: number of cached hits before this entry is reallocated.
    logic [31:0] cache_hit_cnt;
`endif
    // Hold-the-fetch: remaining cycles the entry's NoC fetch is withheld (counts down while
    // !issued; 0 = release now) and the fetch-sent one-shot. Const-folds when HoldWindowMax == 0
    // (every alloc then sets issued = 1 and the replay walker is not generated).
    logic [HoldCntW-1:0] hold_cnt;
    logic                issued;
    // Entry lifecycle state (IDLE/WAIT_RESP/DRAIN_RESP/CACHED/RESP_HOLD).
    mshr_state_t state;
  } mempool_group_mshr_t;

  typedef logic [idx_width(MshrNum)-1:0] mshr_id_t;
  // Spill register plumbing (internal view of interfaces).
  tcdm_master_req_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]      req_in;
  logic              [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]      req_in_valid;
  logic              [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]      req_in_ready;
  tcdm_master_req_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]      req_out;
  logic              [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]      req_out_valid;
  logic              [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]      req_out_ready;
  tcdm_master_resp_t [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]     resp_in;
  logic              [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]     resp_in_valid;
  logic              [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]     resp_in_ready;
  tcdm_master_resp_t [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]     resp_out;
  logic              [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]     resp_out_valid;
  logic              [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]     resp_out_ready;

  // MSHR state (registered and next-state).
  mempool_group_mshr_t [MshrNum-1:0]                                           mshr_d;
  // Block-local scratch values, hoisted out of the always blocks: packed signals at module
  // scope instead of procedural automatics, so they are visible in a waveform. One signal
  // per (block, name) -- two blocks sharing a hoisted temporary would alias, which is a
  // silent multiple-driver bug rather than a compile error.
  // logic, not int: int is 2-state, so an unassigned read returns 0 and hides exactly the X that
  // should expose the bug. All four are assign-then-use inside one always block, so 4-state is safe.
  // WIDTHS ARE NOT INTERCHANGEABLE -- size each to its widest INTERMEDIATE, not its final range:
  //   cache_hit_e  = bank*MshrWaysPerBank + way        -> [0, MshrNum-1], exactly mshr_id_t.
  //   evict_vid    = an mshr id                        -> mshr_id_t.
  //   evict_vw     = evict_vid & (MshrWaysPerBank-1)   -> [0, MshrWaysPerBank-1] = VictimPtrW.
  //   alloc_victim_rw needs VictimPtrW+1 BITS, not VictimPtrW: :1978 computes victim_rr_q[b] + w
  //     BEFORE the :1979-1980 wrap, and that sum reaches 2*MshrWaysPerBank-2 (6 at 4 ways). At
  //     VictimPtrW it would truncate 6 to 2, the wrap would never fire, and the victim round-robin
  //     would silently pick the wrong way -- a fourth instance of the truncation bug class this
  //     file already records for MshrCfgSubsW, HoldCntW and ServedCntMax.
  mshr_id_t                cache_hit_e;
  logic [VictimPtrW:0]     alloc_victim_rw;
  mshr_id_t                evict_vid;
  logic [VictimPtrW-1:0]   evict_vw;
  mshr_id_t      drain2_sel_e2;
  mshr_id_t      resp_tag_cand;
  mshr_id_t      rsn_tag_cand;
  // Clock-gate write flags, raised at the write sites themselves (see the entry register block).
  //   mshr_wr_all : the whole entry was written wholesale (allocation init, or a free clear)
  //   mshr_id_we  : a merge wrote the identity fields of one sub-request slot
  //   mshr_rb_we  : a response beat was captured into one resp_buf slot
  logic [MshrNum-1:0]                                                          mshr_wr_all;
  logic [MshrNum-1:0]                                                          mshr_id_we;
  logic [MshrNum-1:0][RespBufWords-1:0]                                        mshr_rb_we;
  mempool_group_mshr_t [MshrNum-1:0]                                           mshr_q;
  logic                [MshrNum-1:0]                                           mshr_d_valid;
  logic                [MshrNum-1:0]                                           mshr_q_valid;
  // Occupancy, exported so the CSR file can refuse a bank-hash change while entries are resident.
  // Declared HERE, not with the other cfg selects ~200 lines earlier: mshr_q_valid does not exist
  // yet at that point. Placing a use before its declaration is the Error-[IND] this file has already
  // hit three times (B0.3, C1, and the first C1-fix attempt).
  assign mshr_busy_o = |mshr_q_valid;
  // Hold-the-fetch replay walk start pointer (rotates every cycle for fairness among held
  // entries contending for the same outbound lane). Tied off when the feature is compiled out.
  mshr_id_t                                                                    hold_replay_rr_q;
  logic                [MshrNum-1:0]                                           mshr_resp_inflight; // Block same-cycle merge.
  logic                [MshrNum-1:0]                                           mshr_resp_seen_now; // Any in-flight input beat matching this MSHR.
  logic                                                                        csr_trace_any_i;

  // Response classification and debug (per response port).
  logic    [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_is_mshr;
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_mshr_id;
  logic    [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_from_mshr;
  logic    [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_from_bypass;
`ifndef TARGET_SYNTHESIS
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_mshr_id_dbg;
`endif
  logic    [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               port_taken;

  // Request decode and merge lookup (per request port).
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_is_load;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_is_store;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_is_single;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_is_non_full_burst;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_is_full_burst;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_can_merge;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]
             [BurstLenWidth-1:0]                                              req_len;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]
             [BurstLenWidth-1:0]                                              req_len_raw;
  tcdm_addr_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_addr_key;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][BankIdW-1:0] req_bank;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]
             [TileIdBits-1:0]                                                 req_tile_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]
             [TcdmAddrNoTileW-1:0]                                            req_tile_addr;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]
             [TcdmAddrNoTileW-1:0]                                            req_tile_addr_key;
  // Bank-scoped hit detection (Increment 3b): each request compares its address against only the
  // MshrWaysPerBank entries of its own bank (req_bank), not all MshrNum. This is behavior-preserving:
  // an entry is only ever allocated through bank_free_id[req_bank], so an entry's address always maps
  // (via mshr_bank_of) back to its own bank -- hence any entry that could address-match a request must
  // live in that request's bank. The per-request maps are therefore MshrWaysPerBank wide; the absolute
  // entry id is reconstructed as req_bank*MshrWaysPerBank + way where one is needed.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_addr_hit_way;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_addr_hit_drain_way;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_hit_way;
  // Meta-overlap is a CROSS-address check (same tile+core, different address, overlapping meta_id
  // range) that protects core-side (core,meta_id) response uniqueness. A conflicting entry can live in
  // ANY bank, so this stays full-table (MshrNum wide). It carries no 32-bit address comparator: the
  // only address-dependent term is the same-address exclusion, and a same-address entry is provably in
  // the request's own bank, so that term reuses the bank-scoped req_addr_hit_way bit (see below).
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrNum-1:0]         req_meta_ovlp_map;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_addr_hit_drain;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_meta_conflict;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr_sel_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr_sel_id;
  logic      [MshrNum-1:0]                                                     mshr_hit_req;

  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_ready;
  // C1 (F11a): prefix rank of same-target merging ports. Replaces the serial read-modify-write on
  // sub_reqs_num, where port p read the value every earlier port left behind -- an up-to-32-deep
  // chain of 64:1 mux + increment + compare + demux-write ending at req_in_ready.
  //
  // rank(p) = #{q < p : q merges into the SAME entry}. Port p then writes slot q.num + rank and is
  // ready iff q.num + rank + 1 <= MshrMergeReqs, all evaluated against the REGISTERED array.
  //
  // Proven equivalent in hardware/scripts/proof_merge_rank.py: slot assignment + count over 100k
  // random 32-port configurations and an exhaustive small case (a rejected port never steals a rank
  // because rejection is always a SUFFIX -- the count only grows); state transitions over 200k
  // configurations (both arms write identical values, so firing from every qualifying port instead
  // of only the first gives the same result). Prerequisite verified against this file: state,
  // sub_reqs_num and served_cnt are written ZERO times before the merge door, so mshr_d == mshr_q
  // for exactly the fields read here.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MergeRankW-1:0]                  merge_rank;
  logic                                                                                           amo_invalidate;

  // Request allocation (banked allocator bookkeeping).
  logic    [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found;
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found_mshr_id;
  // Per-bank single-allocation-per-cycle scheme (Increment 3): req_alloc_cand marks a request that
  // wants a new entry (mergeable load that missed, no drain/meta hazard); bank_free_id/bank_has_free
  // give each bank its lowest free (or, when enabled, reclaimable-CACHED) way; only one candidate
  // per bank is granted an allocation per cycle.
  logic    [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_cand;
  logic    [MshrBankNum-1:0]                                                   bank_has_free;
  mshr_id_t[MshrBankNum-1:0]                                                   bank_free_id;
  // RR victim start pointer per bank (CacheVictimRR); consumed by the pass-2 reclaim scan,
  // advanced only on a reclaim fire. Tied 0 / unread when CacheVictimRR=0 (const-folds out).
  logic    [MshrBankNum-1:0][VictimPtrW-1:0]                                   victim_rr_q, victim_rr_d;

  // Response drain scheduling (per response port).
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]
             [idx_width(MshrMergeReqs)-1:0]                                    resp_sel_subreq_idx;
  logic      [MshrNum-1:0][BurstLenWidth-1:0]                                  resp_beat_offset;
  // ParityDrain second-slot scheduling ('0/unused when DrainBeatsPerEntry == 1).
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel2_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel2_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]
             [idx_width(MshrMergeReqs)-1:0]                                    resp_sel2_subreq_idx;
  logic      [MshrNum-1:0][BurstLenWidth-1:0]                                  resp_beat_offset2;
  logic      [MshrNum-1:0][RespBufPtrW-1:0]                                    resp_rd_ptr2;
  // F2 (Drain2FromQ): the entry view the second-slot scan reads, and the second-slot read pointer
  // and beat offset derived from THAT view. Const-folds away entirely at Drain2FromQ = 0.
  mempool_group_mshr_t [MshrNum-1:0]                                           drain2_scan_ent;
  logic      [MshrNum-1:0]                                                     drain2_scan_valid;
  // F2 (ReplayFromQ): the entry view the hold-the-fetch replay walker reads.
  mempool_group_mshr_t [MshrNum-1:0]                                           replay_scan_ent;
  logic      [MshrNum-1:0]                                                     replay_scan_valid;
  // F3a: one bit per entry, "some store lane forced this RESP_HOLD entry to drain this cycle".
  logic      [MshrNum-1:0]                                                     st_force_drain;
  // F3c: response capture decided per ENTRY instead of chained across lanes.
  //   cap_want          which response lanes want this entry (derived from mshr_q only, so all
  //                     lanes are evaluated independently of one another)
  //   cap_first/_second lowest and next-lowest wanting lane, one-hot. The sequential loop granted
  //                     lanes in increasing index order until the entry ran out of slots, so
  //                     "the first N by index" is exactly the same set it produced.
  //   cap_g1/cap_g2     whether those two are granted, against the entry's free slots
  //   cap_d0/cap_d1     the beat each granted lane contributes
  localparam int unsigned NumRespPortsActive = (NumRemoteRespPortsPerTile > 1) ?
                                               (NumRemoteRespPortsPerTile - 1) : 1;
  localparam int unsigned NumRespLanes       = NumTilesPerGroup * NumRespPortsActive;
  localparam int unsigned RespLaneW          = idx_width(NumRespLanes);
  logic [MshrNum-1:0][NumRespLanes-1:0]                                        cap_want;
  logic [MshrNum-1:0][NumRespLanes-1:0]                                        cap_first, cap_second;
  logic [NumRespLanes-1:0]                                                     cap_rest;
  logic [MshrNum-1:0]                                                          cap_g1, cap_g2;
  // F3d: per-entry masks of what the two drain DRIVE loops want cleared. Both loops only ever
  // clear BITS, and bit clears commute -- so ORing the requests and applying one AND-NOT per entry
  // is identical to letting 32 lanes each read-modify-write the entry in turn.
  logic [MshrNum-1:0][MshrMergeReqs-1:0]                                       bp_clr, bp2_clr, sv_clr;
  // F3b: store byte-merge into CACHED lines, decided per entry instead of chained across lanes.
  //   stb_hit   which request lanes hit this entry as a store-to-CACHED
  //   stb_be    each lane's byte enables, and stb_wd its write data, captured once
  // The merge below ORs each hitting lane's ENABLED BYTES together. That is exactly the sequential
  // result whenever the hitting lanes touch DISJOINT bytes, which is the only case the memory
  // model gives a defined answer for anyway: two stores to the same byte in the same cycle are
  // unordered, so the old "last lane in index order wins" was one arbitrary choice among several.
  // stb_ovl flags the overlapping case so it is measured rather than assumed away -- see the
  // assertion and counter in the translate_off region.
  localparam int unsigned NumReqPortsActiveF3 = (NumRemoteReqPortsPerTile > 1) ?
                                                (NumRemoteReqPortsPerTile - 1) : 1;
  localparam int unsigned NumReqLanes         = NumTilesPerGroup * NumReqPortsActiveF3;
  localparam int unsigned StrbW               = $bits(strb_t);
  logic [MshrNum-1:0][NumReqLanes-1:0]                                         stb_hit;
  logic [NumReqLanes-1:0][StrbW-1:0]                                           stb_be;
  data_t [NumReqLanes-1:0]                                                     stb_wd;
  logic [RespLaneW-1:0]                                                        stb_lane;
  logic [MshrNum-1:0][StrbW-1:0]                                               stb_bytes;
  logic [MshrNum-1:0]                                                          stb_ovl;
  logic [StrbW-1:0]                                                            stb_seen;
  mshr_resp_slot_t [MshrNum-1:0]                                               cap_d0, cap_d1;
  logic [RespBufPtrW-1:0]                                                      cap_s0, cap_s1, cap_n0, cap_n1;
  logic [RespLaneW-1:0]                                                        cap_lane;
  // The grant takes at most TWO lanes per entry, exact only while an entry cannot have more than
  // two free slots. RespBufWords is NumRemoteRespPortsPerTile-1 and the resp channel count is
  // already restricted to 1 or 2, so this holds -- but fail loudly rather than drop a third beat.
  if (RespBufWords > 2)
    $error("[mempool_group_mshr] F3c grants at most 2 response lanes per entry per cycle; RespBufWords=%0d needs it generalised.", RespBufWords);
  logic      [MshrNum-1:0][RespBufPtrW-1:0]                                    drain2_rd_ptr;
  logic      [MshrNum-1:0][BurstLenWidth-1:0]                                  drain2_beat_off;

  // ------------------------------------------------------------------------------------------
  // ParityDrain bypass-retag table (design doc §4.6). An MSHR-BYPASSED multi-beat load (bank
  // full at allocation: forwarded to the NoC with mshr_tag=0, no entry) is served by the slave
  // under the legacy contract: every beat echoes the ORIGINAL core_id, so all beats collapse to
  // one core data port at the tile xbar and drain 1 beat/cycle -- even though they already
  // ARRIVE spread across both tile resp ports (slave-side round-robin channel hash). This small
  // side table gives bypassed bursts the same parity core_id retag as MSHR-drained beats, so the
  // bypass service class also uses both tile resp ports AND both VLSU receive ports (2/cycle).
  //
  // Depth 2 per tile is PROVABLY sufficient: the VLSU holds one memory instruction in flight
  // until full retire (op-queue serialization) and one instruction issues at most two bursts,
  // with disjoint ROB0 id ranges -- so a tile can never have a third outstanding tracked burst
  // (asserted below). The receive side needs NO change: the VLSU's burst_odd_expected classifier
  // accepts an expected-odd id on mem port 1 regardless of who delivered it.
  //
  // NOTE: this restores BANDWIDTH for bypasses, not coalescing -- a bypassed burst still has no
  // entry (no merge/multicast/cache). Everything const-folds out when PD2=0.
  // ------------------------------------------------------------------------------------------
  typedef struct packed {
    logic                     valid;
    meta_id_t                 meta_base;   // first beat's meta_id (== VLSU ROB0 burst base)
    logic [BurstLenWidth-1:0] len;         // original burst length (range check)
    logic [BurstLenWidth-1:0] beats_left;  // outstanding beats; free the way at 0
  } bypass_track_t;
  bypass_track_t [NumTilesPerGroup-1:0][BypassTrackWays-1:0]                     bypass_track_q, bypass_track_d;
  logic          [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]         bypass_match;
  logic          [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]
                 [BypassTrackWayW-1:0]                                         bypass_match_way;
  logic          [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]         bypass_beat_parity;

  // BYPASS-TRACK TABLE: DEAD, AND IT COULD NOT RETIRE.
  //
  // Its only consumer was the ParityDrain bypass retag, which the lane law replaced --
  // tcdm_burst_expander now applies the split at the destination, so a bypassed beat reaches
  // its requester already addressed to the right buffer and there is nothing to fix up here.
  //
  // Leaving it standing was not harmless, which is why this is a gate and not a comment. A way
  // is retired on a matching response, and bypass_match demands
  // rdata.core_id == tile_core_id_t'(1) -- the issuing port. Under the lane law a burst's beats
  // come back on core_id 1..BurstLanes, so only the lane-0 beats ever matched: ways were
  // allocated on every bypassed burst and never fully retired, the table filled, and the
  // depth assertion killed the run ("bypass-track overflow at tile 6, all 16 ways
  // outstanding", vector-burst-test cyc ~9674).
  //
  // Gated off rather than deleted so this change stays one idea; the else branch below ties
  // every signal to '0, so the flops and the compare tree fold away and the overflow
  // assertion's all_ways_valid is constant 0 (never fires). Delete the block outright in the
  // follow-up cleanup.
  localparam bit EnableBypassTrack = 1'b0;
  if (EnableBypassTrack) begin : gen_bypass_retag
    // Loop temporaries for the two always_comb blocks below, at generate scope rather than as
    // procedural `automatic`s. Identical hardware -- each is assigned before it is read on every
    // unrolled iteration -- but visible in a waveform and in the form the backend flow expects.
    // bypass_retire_way keeps the table's own index width instead of widening to a 32-bit `int`
    // only to index a BypassTrackWays-deep array.
    meta_id_t                   bypass_off;         // meta_id - meta_base, wraps mod 2**MetaIdWidth
    logic [BypassTrackWayW-1:0] bypass_retire_way;
    logic                       bypass_way_found;

    // B3 (F22): per-(tile,way) write enable instead of one unconditional load of the whole table.
    // The table is NumTilesPerGroup x BypassTrackWays x bypass_track_t and changes only on a
    // bypass-alloc or a beat retire -- a few percent of cycles -- yet every bit was clocked every
    // cycle. bypass_track_d defaults to bypass_track_q (see the always_comb below), so gating on
    // "d differs from q" is bit-identical by construction and gives the clock-gating pass a per-way
    // enable to key on. Same enable style the entry register block already uses.
    logic [NumTilesPerGroup-1:0][BypassTrackWays-1:0] bypass_track_we;
    always_comb begin
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int w = 0; w < BypassTrackWays; w++) begin
          bypass_track_we[t][w] = (bypass_track_d[t][w] != bypass_track_q[t][w]);
        end
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        bypass_track_q <= '0;
      end else begin
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int w = 0; w < BypassTrackWays; w++) begin
            if (bypass_track_we[t][w]) bypass_track_q[t][w] <= bypass_track_d[t][w];
          end
        end
      end
    end

    // Response-side match: a tag-0 (bypass) READ response from the burst-issuing core port whose
    // meta_id falls in a tracked range. meta arithmetic wraps mod 2**MetaIdWidth like the VLSU's
    // ROB0 id space, so wrapped ranges (base near the top) match correctly. The <=2 tracked
    // ranges of a tile are disjoint by construction (distinct ROB0 allocations).
    always_comb begin
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int p = 1; p < NumRemoteRespPortsPerTile; p++) begin
          bypass_match[t][p]       = 1'b0;
          bypass_match_way[t][p]   = '0;
          bypass_beat_parity[t][p] = 1'b0;
          if (resp_in_valid[t][p] &&
              (resp_in[t][p].mshr_tag == '0) &&
              (resp_in[t][p].wen == 1'b0) &&
              (resp_in[t][p].rdata.amo == '0) &&
              (resp_in[t][p].rdata.core_id == tile_core_id_t'(1))) begin
            for (int w = 0; w < BypassTrackWays; w++) begin
              bypass_off = resp_in[t][p].rdata.meta_id - bypass_track_q[t][w].meta_base;
              if (!bypass_match[t][p] && bypass_track_q[t][w].valid &&
                  (bypass_off < meta_id_t'(bypass_track_q[t][w].len))) begin
                bypass_match[t][p]       = 1'b1;
                bypass_match_way[t][p]   = BypassTrackWayW'(w);
                bypass_beat_parity[t][p] = bypass_off[0];
              end
            end
          end
        end
      end
    end

    // Table lifecycle: allocate on a bypass request handshake (a multi-beat load forwarded to
    // the NoC without an entry), retire beats on forwarded-response handshakes (both ports of a
    // tile can retire two beats of one burst in the same cycle).
    always_comb begin
      bypass_track_d = bypass_track_q;
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        // Beat retirement first (a freed way can be re-allocated in the same cycle below).
        for (int p = 1; p < NumRemoteRespPortsPerTile; p++) begin
          bypass_retire_way = bypass_match_way[t][p];
          if (bypass_match[t][p] && resp_from_bypass[t][p] &&
              resp_out_valid[t][p] && resp_out_ready[t][p]) begin
            if (bypass_track_d[t][bypass_retire_way].beats_left <= BurstLenWidth'(1)) begin
              bypass_track_d[t][bypass_retire_way] = '0;
            end else begin
              bypass_track_d[t][bypass_retire_way].beats_left =
                  bypass_track_d[t][bypass_retire_way].beats_left - 1'b1;
            end
          end
        end
        // Allocation: track every outgoing bypassed multi-beat load. The mshr_tag=='0 qualifier
        // identifies a genuine door passthrough: entry allocations and hold-the-fetch replay
        // injections both stamp (entry+1). Without it, a replay injection claiming a lane in the
        // same cycle the door locally accepts a merge/held-alloc on that lane would look like a
        // bypass handshake and leak a ghost track way (its beats return tagged, never as tag-0
        // bypass responses, so the way would never retire).
        for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
          if (req_in_valid[t][p] && req_in_ready[t][p] && req_out_valid[t][p] &&
              (req_out[t][p].mshr_tag == '0) &&
              req_is_load[t][p] && (req_len[t][p] > BurstLenWidth'(1)) &&
              !req_alloc_found[t][p]) begin
            begin : alloc_bypass_way
              bypass_way_found = 1'b0;
              for (int w = 0; w < BypassTrackWays; w++) begin
                if (!bypass_way_found && !bypass_track_d[t][w].valid) begin
                  bypass_track_d[t][w] = '{valid: 1'b1,
                                           meta_base: req_in[t][p].wdata.meta_id,
                                           len: req_len[t][p], beats_left: req_len[t][p]};
                  bypass_way_found   = 1'b1;
                end
              end
            end
            // else: untracked (cannot happen -- asserted); the burst degrades to 1-wide, correct.
          end
        end
      end
    end
  end else begin : gen_no_bypass_retag
    assign bypass_track_d     = '0;
    assign bypass_track_q     = '0;
    assign bypass_match       = '0;
    assign bypass_match_way   = '0;
    assign bypass_beat_parity = '0;
  end
  logic      [MshrNum-1:0][RespBufCountW-1:0]                                  mshr_resp_slots;
  logic      [MshrNum-1:0][RespBufPtrW-1:0]                                    resp_push_ptr;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_capture_fire;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]
             [BurstLenWidth-1:0]                                               resp_capture_beat_offset;
  logic      [MshrNum-1:0]                                                     resp_head_beat_pending;
  logic      [MshrNum-1:0][RespBufCountW-1:0]                                  resp_cnt_after_pop;
  // Response drain scheduling (single-response per MSHR).

  // ---------------------------------------------------------------------------
  // Round-robin fairness bases (audit M2'/M3/L3). Each is a registered counter
  // advanced +1 mod-N every cycle (free-running, NO grant feedback), read only by
  // the combinational arbitration scans below -> no new combinational loop. Free-
  // running (vs advance-on-grant) is the smallest, most deadlock-safe diff to this
  // module; it removes the deterministic lowest-index bias. The drain axes get a
  // true bounded wait (a pending entry/sub_req is a CONTINUOUS candidate held in
  // DRAIN_RESP until fully drained, so the marching pointer reaches it within N).
  // The allocator axis gets starvation-FREEDOM (an alloc loser whose bank is full
  // bypasses to the NoC and completes) plus best-effort rotation -- not a hard
  // bounded-wait under adversarial periodic bank occupancy (that would need a
  // per-grant/per-bank pointer at higher timing cost). All scoped by
  // EnableRrFairness: 0 forces base=0 -> legacy fixed lowest-index order.
  // rr_arb_tree is deliberately not used: the allocator's contenders map to banks
  // via the data-dependent req_bank[t][p] (would need a 16x32 candidate gather),
  // and the drain scan has a per-(tile,port) tile_id/port_id filter over 64x8
  // pairs -- neither fits a fixed-input arbiter.
  // ---------------------------------------------------------------------------
  // (A) M2' allocator: rotate the requester (tile,port) priority axis. Active req
  //     ports are indices 1..NumRemoteReqPortsPerTile-1, flattened to one index.
  localparam int unsigned NumReqPortsActive = (NumRemoteReqPortsPerTile > 1) ?
                                              (NumRemoteReqPortsPerTile - 1) : 1;
  localparam int unsigned NumAllocSlots     = NumTilesPerGroup * NumReqPortsActive;
  localparam int unsigned AllocRrW          = idx_width(NumAllocSlots);
  // C1: sized by NumAllocSlots, so these must follow it -- declaring them beside req_merge_* (which
  // is ~200 lines earlier) put them ahead of their own width parameter.
  logic [NumAllocSlots-1:0] merge_same_mask;   // earlier ports targeting the SAME entry
  logic [MergeRankW-1:0]    merge_slot;        // q.sub_reqs_num + this port's rank (cannot wrap)
  logic [MergeCountW-1:0]   merge_rank_raw;    // untruncated population count, before saturation
  logic [AllocRrW-1:0]      alloc_rr_q, alloc_rr_d;
  // (B) M3 drain: rotate the MSHR-entry scan axis (MshrNum entries).
  localparam int unsigned DrainMshrRrW = idx_width(MshrNum);
  // A5: natural widths for the rotated scan indices. Power-of-two MshrNum/MshrMergeReqs is
  // asserted at elaboration, so truncation to these widths is exactly mod-N.
  localparam int unsigned MshrIdxW = idx_width(MshrNum);
  localparam int unsigned SubIdxW  = idx_width(MshrMergeReqs);

  // C3 (F9): per-lane parallel first-match for the hold-the-fetch replay.
  //
  // The walker used to visit all MshrNum entries in rotated order, reading req_out_valid at the
  // owner lane and conditionally writing it -- so stage k+1 observed stage k's claim. A true
  // MshrNum-deep serial priority chain ending at req_out/req_out_valid, i.e. straight into the NoC
  // request spill register, with no pipeline stage in between.
  //
  // Every entry owns exactly ONE lane (sub_reqs[0].tile_id/port_id), so entries never contend
  // ACROSS lanes -- only within one, which is precisely what the chain serialised. Each lane can
  // therefore pick its own winner independently: the first hold-done entry it owns, in the same
  // rotated order. Same winner, depth MshrNum -> ~log2(MshrNum).
  //
  // Same transformation this file already applies at the alloc arbiter (:1710-1722) and the drain
  // scan, using the mask + LSB-isolate form from B1.
  logic [MshrNum-1:0]                                        replay_ready;    // hold-done + eligible
  tile_group_id_t [MshrNum-1:0]                              replay_own_t;
  logic [MshrNum-1:0][RespPortIdW-1:0]                       replay_own_p;
  logic [MshrNum-1:0]                                        replay_rr_mask;
  logic [MshrNum-1:0]                                        replay_cand, replay_hi, replay_lo, replay_win_oh;
  logic [MshrIdxW-1:0]                                       replay_win_e;
  // B0.3 splits the entry-space rotation base into {bank, way} by bit position. idx_width() floors
  // at 1 for a single-element axis, so with MshrBankNum==1 or MshrWaysPerBank==1 the two halves no
  // longer tile the entry index and the split would silently select the wrong bank.
  if (BankPublish && (MshrIdxW != (BankIdW + VictimPtrW)))
    $error("[mempool_group_mshr] group_mshr_bank_publish needs idx_width(MshrNum)=%0d to equal BankIdW(%0d)+VictimPtrW(%0d).",
           MshrIdxW, BankIdW, VictimPtrW);
  logic [MshrBankNum-1:0][VictimPtrW-1:0]                     bank_rr_q, bank_rr_d;
  logic [MshrBankNum-1:0][VictimPtrW-1:0]                     bank_pub_w;
  logic [MshrBankNum-1:0]                                     bank_pub_v;
  logic [VictimPtrW-1:0]                                      bank_scan_w;
  logic [DrainMshrRrW-1:0]  drain_mshr_rr_q, drain_mshr_rr_d;
  // (C) L3 drain: rotate the sub_req scan axis (MshrMergeReqs sub-requests). A
  //     separate base from (B) so the two axes do not rotate in lockstep.
  localparam int unsigned SubReqRrW = idx_width(MshrMergeReqs);
  logic [SubReqRrW-1:0]     subreq_rr_q, subreq_rr_d;

  // Performance counters (simulation only).
  // pragma translate_off
  `ifndef VERILATOR
  logic [63-1:0]                                                               stat_mshr_valid_cycle;
  logic [63-1:0]                                                               stat_cache_valid_cycle;
  logic [63-1:0]                                                               stat_mshr_valid_uncached_cycle;
  logic [63-1:0]                                                               stat_subreq_valid_cycle;
  logic [63-1:0]                                                               stat_req_accept_cycle;
  logic [63-1:0]                                                               stat_req_accept_single_cycle;
  logic [63-1:0]                                                               stat_req_accept_burst_cycle;
  logic [63-1:0]                                                               stat_req_merge_cycle;
  logic [63-1:0]                                                               stat_req_merge_single_cycle;
  logic [63-1:0]                                                               stat_req_merge_burst_cycle;
  logic [63-1:0]                                                               stat_req_alloc_cycle;
  logic [63-1:0]                                                               stat_req_alloc_single_cycle;
  logic [63-1:0]                                                               stat_req_alloc_burst_cycle;
  logic [63-1:0]                                                               stat_req_bypass_cycle;
  logic [63-1:0]                                                               stat_req_mshr_overflow_cycle;
  logic [63-1:0]                                                               stat_req_subreq_overflow_cycle;
  logic [63-1:0]                                                               stat_resp_mshr_cycle;
  logic [63-1:0]                                                               stat_resp_bypass_cycle;
  logic [63-1:0]                                                               stat_cache_hit_cycle;
  logic [63-1:0]                                                               stat_cache_fill_cycle;
  logic [63-1:0]                                                               stat_cache_evict_cycle;
  logic [63-1:0]                                                               stat_cache_store_update_cycle;
  logic [63-1:0]                                                               stat_cache_amo_inval_cycle;
  logic [63-1:0]                                                               stat_cache_self_inval_cycle;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                   stat_req_subreq_full_match;

  logic [63-1:0]                                                               stat_cycle_count;
  logic [63-1:0]                                                               stat_mshr_valid_acc;
  logic [63-1:0]                                                               stat_mshr_valid_uncached_acc;
  logic [63-1:0]                                                               stat_cache_valid_acc;
  logic [63-1:0]                                                               stat_subreq_valid_acc;
  logic [63-1:0]                                                               stat_mshr_max_valid;
  logic [63-1:0]                                                               stat_cache_max_valid;
  logic [63-1:0]                                                               stat_mshr_max_valid_uncached;
  logic [63-1:0]                                                               stat_subreq_max_valid;
  logic [63-1:0]                                                               stat_req_accept;
  logic [63-1:0]                                                               stat_req_accept_single;
  logic [63-1:0]                                                               stat_req_accept_burst;
  logic [63-1:0]                                                               stat_req_merge;
  logic [63-1:0]                                                               stat_req_merge_single;
  logic [63-1:0]                                                               stat_req_merge_burst;
  logic [63-1:0]                                                               stat_req_alloc;
  logic [63-1:0]                                                               stat_req_alloc_single;
  logic [63-1:0]                                                               stat_req_alloc_burst;
  logic [63-1:0]                                                               stat_req_bypass;
  logic [63-1:0]                                                               stat_req_mshr_overflow;
  logic [63-1:0]                                                               stat_req_subreq_overflow;
  logic [63-1:0]                                                               stat_resp_mshr;
  logic [63-1:0]                                                               stat_resp_bypass;
  logic [63-1:0]                                                               stat_cache_hit;
  logic [63-1:0]                                                               stat_cache_fill;
  logic [63-1:0]                                                               stat_cache_evict;
  logic [63-1:0]                                                               stat_cache_store_update;
  logic [63-1:0]                                                               stat_cache_amo_inval;
  logic [63-1:0]                                                               stat_cache_self_inval;
  logic                                                                        stat_trace_q;
  // Next-state debug signals for stats (for waveform visibility).
  logic [63-1:0]                                                               stat_cycle_count_next;
  logic [63-1:0]                                                               stat_mshr_valid_acc_next;
  logic [63-1:0]                                                               stat_mshr_valid_uncached_acc_next;
  logic [63-1:0]                                                               stat_cache_valid_acc_next;
  logic [63-1:0]                                                               stat_subreq_valid_acc_next;
  logic [63-1:0]                                                               stat_mshr_max_valid_next;
  logic [63-1:0]                                                               stat_cache_max_valid_next;
  logic [63-1:0]                                                               stat_mshr_max_valid_uncached_next;
  logic [63-1:0]                                                               stat_subreq_max_valid_next;
  logic [63-1:0]                                                               stat_req_accept_next;
  logic [63-1:0]                                                               stat_req_accept_single_next;
  logic [63-1:0]                                                               stat_req_accept_burst_next;
  logic [63-1:0]                                                               stat_req_merge_next;
  logic [63-1:0]                                                               stat_req_merge_single_next;
  logic [63-1:0]                                                               stat_req_merge_burst_next;
  logic [63-1:0]                                                               stat_req_alloc_single_next;
  logic [63-1:0]                                                               stat_req_alloc_burst_next;
  logic [63-1:0]                                                               stat_req_alloc_next;
  logic [63-1:0]                                                               stat_req_bypass_next;
  logic [63-1:0]                                                               stat_req_mshr_overflow_next;
  logic [63-1:0]                                                               stat_req_subreq_overflow_next;
  logic [63-1:0]                                                               stat_resp_mshr_next;
  logic [63-1:0]                                                               stat_resp_bypass_next;
  logic [63-1:0]                                                               stat_cache_hit_next;
  logic [63-1:0]                                                               stat_cache_fill_next;
  logic [63-1:0]                                                               stat_cache_evict_next;
  logic [63-1:0]                                                               stat_cache_store_update_next;
  logic [63-1:0]                                                               stat_cache_amo_inval_next;
  logic [63-1:0]                                                               stat_cache_self_inval_next;
  `endif
  // pragma translate_on

  function automatic tcdm_addr_t merge_addr_key(input tcdm_addr_t addr);
    if (MergeWordOffset == 0) begin
      merge_addr_key = addr;
    end else begin
      merge_addr_key = {addr[$bits(tcdm_addr_t)-1:MergeWordOffset], {MergeWordOffset{1'b0}}};
    end
  endfunction

  // Map a recorded request port ID to a legal response port ID [1..NumRemoteRespPortsPerTile-1].
  // When req/resp port counts differ, this keeps routing deterministic.
  function automatic logic [RespPortIdW-1:0] map_resp_port_id(input logic [RespPortIdW-1:0] req_port_id);
    logic [RespPortIdW-1:0] mapped_port;
    if (NumRemoteRespPortsPerTile <= 2) begin
      mapped_port = RespPortIdW'(1);
    end else if (req_port_id < RespPortIdW'(1)) begin
      mapped_port = RespPortIdW'(1);
    end else begin
      mapped_port = RespPortIdW'(((req_port_id - RespPortIdW'(1)) %
                                  RespPortIdW'(NumRemoteRespPortsPerTile - 1)) + RespPortIdW'(1));
    end
    map_resp_port_id = mapped_port;
  endfunction

  // Meta-range overlap between a request and an entry.
  //
  // History: this began as meta_range_overlap(), which ENUMERATED all MaxBurstWords offsets of one
  // range and tested each for membership in the other -- replicated
  // NumTilesPerGroup x active req ports x MshrNum = 2048 times, the largest combinational
  // structure in the module. That became a pair of MetaSpace-wide occupancy masks with the test
  // |(mask_a & mask_b), which hoisted the entry-side mask out of the (tile,port) replication.
  //
  // B2 (F7) removes the masks entirely: two cyclic intervals intersect iff one's start lies inside
  // the other, so the test is two modular subtract-compares and needs no mask at all. Both mask
  // builders and the MetaSpace-wide AND/OR-reduce network are gone with it. The test itself lives
  // at gen_req_meta_ovlp; see the equivalence proof and the load-bearing length guards there.

  assign scan_data_o = scan_data_i;
  assign csr_trace_any_i = 1'b1;

  // Spill registers on all interfaces (optional).
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_spill_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_spill_req
        spill_register #(
          .T(tcdm_master_req_t),
          .Bypass(!SpillReqIn)
        ) i_spill_req_in (
          .clk_i   (clk_i                             ),
          .rst_ni  (rst_ni                            ),
          .valid_i (group_mshr_req_valid_i[tile_i][port_i]),
          .ready_o (group_mshr_req_ready_o[tile_i][port_i]),
          .data_i  (group_mshr_req_i[tile_i][port_i]  ),
          .valid_o (req_in_valid[tile_i][port_i]      ),
          .ready_i (req_in_ready[tile_i][port_i]      ),
          .data_o  (req_in[tile_i][port_i]            )
        );

        spill_register #(
          .T(tcdm_master_req_t),
          .Bypass(!SpillReqOut)
        ) i_spill_req_out (
          .clk_i   (clk_i                             ),
          .rst_ni  (rst_ni                            ),
          .valid_i (req_out_valid[tile_i][port_i]     ),
          .ready_o (req_out_ready[tile_i][port_i]     ),
          .data_i  (req_out[tile_i][port_i]           ),
          .valid_o (mshr_noc_req_valid_o[tile_i][port_i]),
          .ready_i (mshr_noc_req_ready_i[tile_i][port_i]),
          .data_o  (mshr_noc_req_o[tile_i][port_i]     )
        );
      end : gen_spill_req

      for (genvar port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin : gen_spill_resp
        spill_register #(
          .T(tcdm_master_resp_t),
          .Bypass(!SpillRespIn)
        ) i_spill_resp_in (
          .clk_i   (clk_i                               ),
          .rst_ni  (rst_ni                              ),
          .valid_i (mshr_noc_resp_valid_i[tile_i][port_i]),
          .ready_o (mshr_noc_resp_ready_o[tile_i][port_i]),
          .data_i  (mshr_noc_resp_i[tile_i][port_i]     ),
          .valid_o (resp_in_valid[tile_i][port_i]       ),
          .ready_i (resp_in_ready[tile_i][port_i]       ),
          .data_o  (resp_in[tile_i][port_i]             )
        );

        // NOTE: the depth-1 output spill is the ORIGINAL, pre-deadlock-fix staging element. It ties
        // resp_out_ready to the downstream consumer's ready, so on the bypass path
        // mshr_noc_resp_ready_o depends on the (possibly stalled) core -> this RE-EXPOSES the
        // message-dependent head-of-line deadlock on the shared NoC response channel (see
        // bottleneck_analysis/2026-06-16_resp_sink_fifo_bug_rationale_and_overhead.md). The depth-32
        // response sink FIFO that made NoC-accept unconditional was reverted here on request.
        spill_register #(
          .T(tcdm_master_resp_t),
          .Bypass(!SpillRespOut)
        ) i_spill_resp_out (
          .clk_i   (clk_i                                ),
          .rst_ni  (rst_ni                               ),
          .valid_i (resp_out_valid[tile_i][port_i]       ),
          .ready_o (resp_out_ready[tile_i][port_i]       ),
          .data_i  (resp_out[tile_i][port_i]             ),
          .valid_o (group_mshr_resp_valid_o[tile_i][port_i]),
          .ready_i (group_mshr_resp_ready_i[tile_i][port_i]),
          .data_o  (group_mshr_resp_o[tile_i][port_i]    )
        );
      end : gen_spill_resp
    end : gen_spill_tile
  endgenerate

  // Decode request type and address key for merge lookup.
  always_comb begin
    amo_invalidate = 1'b0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_len[tile_i][port_i] = BurstLenWidth'(1);
        req_len_raw[tile_i][port_i] = BurstLenWidth'(1);
        req_tile_id[tile_i][port_i] = '0;
        req_tile_addr[tile_i][port_i] = '0;
        req_tile_addr_key[tile_i][port_i] = '0;
        req_is_load[tile_i][port_i] = req_in_valid[tile_i][port_i] &&
                                      ~req_in[tile_i][port_i].wen &&
                                      (req_in[tile_i][port_i].wdata.amo == '0);
        req_is_store[tile_i][port_i] = req_in_valid[tile_i][port_i] &&
                                       req_in[tile_i][port_i].wen &&
                                       (req_in[tile_i][port_i].wdata.amo == '0);
        req_is_single[tile_i][port_i] = 1'b0;
        req_is_non_full_burst[tile_i][port_i] = 1'b0;
        req_is_full_burst[tile_i][port_i] = 1'b0;
        req_can_merge[tile_i][port_i] = 1'b0;
        if (req_in_valid[tile_i][port_i] &&
            (req_in[tile_i][port_i].wdata.amo != '0)) begin
          amo_invalidate = 1'b1;
        end
        if (req_in_valid[tile_i][port_i]) begin
          req_tile_id[tile_i][port_i] =
              req_in[tile_i][port_i].tgt_addr[TileIdBits-1:0];
          req_tile_addr[tile_i][port_i] =
              req_in[tile_i][port_i].tgt_addr[$bits(tcdm_addr_t)-1:TileIdBits];
          req_len_raw[tile_i][port_i] =
              (req_in[tile_i][port_i].burst_len == '0)
                  ? BurstLenWidth'(1)
                  : req_in[tile_i][port_i].burst_len;
          if (!req_is_load[tile_i][port_i] ||
              ((req_len_raw[tile_i][port_i] > 1) &&
               (req_tile_addr[tile_i][port_i][BurstAlignBits-1:0] != '0))) begin
            req_len[tile_i][port_i] = BurstLenWidth'(1);
          end else begin
            req_len[tile_i][port_i] = req_len_raw[tile_i][port_i];
          end
          if (req_len[tile_i][port_i] > 1) begin
            req_tile_addr_key[tile_i][port_i] =
                {req_tile_addr[tile_i][port_i][$bits(tcdm_addr_t)-TileIdBits-1:BurstAlignBits],
                 {BurstAlignBits{1'b0}}};
            req_addr_key[tile_i][port_i] =
                {req_tile_addr_key[tile_i][port_i], req_tile_id[tile_i][port_i]};
          end else begin
            req_addr_key[tile_i][port_i] =
                merge_addr_key(req_in[tile_i][port_i].tgt_addr);
          end
          req_is_single[tile_i][port_i] = (req_len[tile_i][port_i] == BurstLenWidth'(1));
          req_is_full_burst[tile_i][port_i] =
              (req_len[tile_i][port_i] == BurstLenWidth'(MshrFullBurstWords));
          req_is_non_full_burst[tile_i][port_i] =
              !req_is_single[tile_i][port_i] && !req_is_full_burst[tile_i][port_i];
          // H1 fix: a MISALIGNED burst is clamped to req_len=1 (so req_is_single=1), but the
          // requesting VLSU still expects req_len_raw beats from the NoC. It must NOT be admitted
          // on the single-merge arm: a non-owner merging into a burst_len=1 entry would only ever
          // receive beat-0 and hang on beats 1..N-1 (the rest bypass to the owner only). Restrict
          // the single arm to a GENUINE single (req_len_raw==1); a misaligned burst then has
          // req_can_merge=0 and bypasses to the NoC with its original burst_len intact, so the
          // owner still receives all N beats and no non-owner can merge in.
          // RUNTIME BYPASS. req_can_merge is the single eligibility gate -- req_merge_valid
          // (:1926) and req_alloc_cand both AND with it -- so clearing it means the request
          // neither merges nor allocates and goes straight to the NoC. That makes this the one
          // correct place for both bypass rules:
          //   * CFG_ENABLE = 0  -> the whole MSHR is bypassed. This is its RESET state, so init,
          //     DMA and I$ warm-up never occupy a way or a response-cache line.
          //   * hold_subs_* = 1 -> that CLASS does not merge, so bypass it. A 1-way-shared operand
          //     (B at M=128) has nothing to merge with, and holding it only guarantees a
          //     full-window stall -- what the per-shape hold_window_burst := 0 pin approximated.
          // Both fold away at MshrCfgRuntime=0, where cfg_bypass_* are constant 0.
          req_can_merge[tile_i][port_i] =
              req_is_load[tile_i][port_i] &&
              !(req_is_single[tile_i][port_i] ? cfg_bypass_single : cfg_bypass_burst) &&
              ((EnableMshrSingleReq       && req_is_single[tile_i][port_i] &&
                (req_len_raw[tile_i][port_i] == BurstLenWidth'(1))) ||
               (EnableMshrNonFullBurstReq && req_is_non_full_burst[tile_i][port_i]) ||
               (EnableMshrFullBurstReq    && req_is_full_burst[tile_i][port_i]));
        end else begin
          req_addr_key[tile_i][port_i] = '0;
        end
      end
    end

  end

  // // pragma translate_off
  // `ifndef VERILATOR
  // generate
  //   for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_meta_id_check_tile
  //     for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_meta_id_check_port
  //       meta_id_in_range: assert property(
  //         @(posedge clk_i) disable iff (!rst_ni)
  //         (!group_mshr_req_valid_i[tile_i][port_i] ||
  //          (group_mshr_req_i[tile_i][port_i].wdata.meta_id < SpatzNumOutstandingLoads)))
  //         else $fatal(1, "MSHR req meta_id out of range: tile=%0d port=%0d meta_id=%0d (limit=%0d)",
  //                     tile_i, port_i,
  //                     group_mshr_req_i[tile_i][port_i].wdata.meta_id,
  //                     SpatzNumOutstandingLoads);
  //     end
  //   end
  // endgenerate
  // `endif
  // // pragma translate_on

  // pragma translate_off
  `ifndef VERILATOR
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_burst_req_checks_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_burst_req_checks_port
        amo_not_burst: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            (!req_in_valid[tile_i][port_i] ||
             (req_in[tile_i][port_i].wdata.amo == '0)) ||
            (req_in[tile_i][port_i].burst_len <= BurstLenWidth'(1)))
          else $warning("AMO req burst_len clamped to 1: tile=%0d port=%0d len=%0d",
                        tile_i, port_i, req_in[tile_i][port_i].burst_len);

        burst_len_in_range: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            (!req_in_valid[tile_i][port_i]) ||
            ((req_len_raw[tile_i][port_i] >= 1) && (req_len_raw[tile_i][port_i] <= MaxBurstWords)))
          else $fatal(1, "MSHR req burst_len out of range: tile=%0d port=%0d len=%0d",
                      tile_i, port_i, req_len_raw[tile_i][port_i]);

        full_burst_words_in_range: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            (MshrFullBurstWords >= 1) && (MshrFullBurstWords <= MaxBurstWords))
          else $fatal(1, "MSHR MshrFullBurstWords out of range: cfg=%0d valid=[1..%0d]",
                      MshrFullBurstWords, MaxBurstWords);

        burst_aligned: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            (!req_in_valid[tile_i][port_i] ||
             !req_is_load[tile_i][port_i] ||
             (req_len_raw[tile_i][port_i] <= 1)) ||
            (req_tile_addr[tile_i][port_i][BurstAlignBits-1:0] == '0))
          else $warning("MSHR req burst not aligned; clamping to single beat: tile=%0d port=%0d addr=0x%0x",
                        tile_i, port_i, req_in[tile_i][port_i].tgt_addr);
      end
    end

    for (genvar mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin : gen_mshr_burst_checks
      cache_only_single: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !mshr_q_valid[mshr_i] ||
          (mshr_q[mshr_i].state != MSHR_CACHED) ||
          (mshr_q[mshr_i].burst_len == BurstLenWidth'(1)))
        else $fatal(1, "MSHR cached entry has burst_len > 1: mshr=%0d len=%0d",
                    mshr_i, mshr_q[mshr_i].burst_len);

      resp_offset_in_range: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !mshr_q_valid[mshr_i] ||
          (mshr_q[mshr_i].state == MSHR_CACHED) ||
          (mshr_q[mshr_i].resp_buf_cnt == '0) ||
          (resp_beat_offset[mshr_i] < mshr_q[mshr_i].burst_len))
        else $fatal(1, "MSHR resp beat_offset out of range: mshr=%0d off=%0d len=%0d",
                    mshr_i, resp_beat_offset[mshr_i], mshr_q[mshr_i].burst_len);

      resp_buf_cnt_in_range: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !mshr_q_valid[mshr_i] ||
          (mshr_q[mshr_i].resp_buf_cnt <= RespBufWords))
        else $fatal(1, "MSHR resp_buf_cnt out of range: mshr=%0d cnt=%0d depth=%0d",
                    mshr_i, mshr_q[mshr_i].resp_buf_cnt, RespBufWords);

      resp_valid_coherent: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !mshr_q_valid[mshr_i] ||
          ((mshr_q[mshr_i].resp_buf_cnt != '0) == (mshr_q[mshr_i].resp_buf_cnt != '0)))
        else $fatal(1, "MSHR resp_valid mismatch with resp_buf_cnt: mshr=%0d valid=%0d cnt=%0d",
                    mshr_i, (mshr_q[mshr_i].resp_buf_cnt != '0), mshr_q[mshr_i].resp_buf_cnt);

      // Load-bearing invariant for EnableMshrSingleReq + EnableRespCache: a live
      // CACHED entry must always hold its buffered response (resp_buf_cnt > 0, so
      // resp_valid == 1). This is what makes a single-word load to a cached
      // address ALWAYS take the merge/hit path (req_hit_mshr) and never
      // duplicate-allocate a second MSHR entry for the same address. The
      // finalize-to-CACHED branch keeps the data (does not pop); nothing
      // decrements resp_buf_cnt while CACHED. If a future change ever breaks this
      // (e.g. an LRU/flush pop), the duplicate-allocation hazard could reopen --
      // this assertion catches it.
      cached_entry_holds_data: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !mshr_q_valid[mshr_i] ||
          (mshr_q[mshr_i].state != MSHR_CACHED) ||
          (mshr_q[mshr_i].resp_buf_cnt != '0))
        else $fatal(1, "MSHR CACHED entry without buffered data (resp_buf_cnt==0): mshr=%0d",
                    mshr_i);

      response_hold_is_live_scalar: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !mshr_q_valid[mshr_i] ||
          (mshr_q[mshr_i].state != MSHR_RESP_HOLD) ||
          (RespWaitSubsSingle &&
           (mshr_q[mshr_i].burst_len == BurstLenWidth'(1)) &&
           (mshr_q[mshr_i].resp_buf_cnt != '0) &&
           (mshr_q[mshr_i].sub_reqs_num != '0) &&
           (mshr_q[mshr_i].sub_reqs_num < SubReqCountW'(cfg_hold_subs_single))))
        else $fatal(1,
                    "MSHR invalid RESP_HOLD entry: mshr=%0d len=%0d resp=%0d subreqs=%0d",
                    mshr_i, mshr_q[mshr_i].burst_len, mshr_q[mshr_i].resp_buf_cnt,
                    mshr_q[mshr_i].sub_reqs_num);

`ifndef TARGET_SYNTHESIS
      // Guarded on TARGET_SYNTHESIS, not just VERILATOR: beat_seen itself is now
      // verification-only, so an assertion that reads it must vanish on exactly the same
      // condition as the field or the synthesis build fails on a missing member.
      beat_done_subset_seen: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !mshr_q_valid[mshr_i] ||
          ((mshr_q[mshr_i].beat_done & ~mshr_q[mshr_i].beat_seen) == '0))
        else $fatal(1, "MSHR beat_done not subset of beat_seen: mshr=%0d seen=0x%0x done=0x%0x",
                    mshr_i, mshr_q[mshr_i].beat_seen, mshr_q[mshr_i].beat_done);
`endif

      // A buffered head beat must match at least one pending sub-request.
      // Otherwise the beat gets popped without being delivered and data is lost.
      //
      // When a response first enters an MSHR, the entry may transition into
      // DRAIN_RESP, immediately service all requesters of the captured head beat,
      // and even advance the response FIFO head in the same combinational pass.
      // In that transition cycle, beat_pending can legally be zero before the
      // next head beat gets its pending bitmap initialized. Skip the assertion
      // while a matching response is being observed for this MSHR.
      head_beat_must_match_subreq: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !mshr_d_valid[mshr_i] ||
          (mshr_d[mshr_i].state != MSHR_DRAIN_RESP) ||
          (mshr_d[mshr_i].resp_buf_cnt == '0) ||
          (mshr_d[mshr_i].sub_reqs_num == '0) ||
          // Steady-state DRAIN_RESP is already covered by next-cycle checking.
          (mshr_q_valid[mshr_i] && mshr_q[mshr_i].state == MSHR_DRAIN_RESP) ||
          mshr_resp_inflight[mshr_i] ||
          (resp_head_beat_pending[mshr_i]))
        else $fatal(1, "MSHR unmatched head beat: mshr=%0d beat=%0d base_meta=%0d subreqs=%0d beat_pending=0x%0x",
                    mshr_i,
                    mshr_d[mshr_i].resp_buf[mshr_d[mshr_i].resp_buf_rd_ptr].beat_off,
                    mshr_d[mshr_i].sub_reqs[0].meta_id_base,
                    mshr_d[mshr_i].sub_reqs_num,
                    mshr_d[mshr_i].beat_pending);
    end

    // ParityDrain bypass-retag depth invariant (design §4.6): a tile can never have a third
    // outstanding bypassed multi-beat burst (VLSU one-insn serialization x <=2 bursts/insn).
    // An untracked burst is functionally safe (1-wide legacy delivery) but means the invariant
    // or the retirement accounting broke -- fatal in sim.
    // Priority check for StallOnResp: req_addr_hit_drain (now including "a same-address entry is
    // mid-response") must always steer a request into the WAIT branch, never into ALLOCATE.
    // Deliberately NOT "any same-address entry": a request whose same-address entry has a FULL
    // sub-request list (sub_reqs_num + 1 > MshrMergeReqs, reachable at group_mshr_merge_reqs=4)
    // legitimately allocates a second entry -- stalling it would block on an entry that can never
    // accept it. Likewise a length mismatch (a burst vs a resident single-word entry) is a
    // by-design miss. This assertion therefore checks only the case the knob governs.
    if (StallOnResp) begin : gen_stall_on_resp_assert
      for (genvar at = 0; at < NumTilesPerGroup; at++) begin : gen_sor_tile
        for (genvar ap = 1; ap < NumRemoteReqPortsPerTile; ap++) begin : gen_sor_port
          no_alloc_while_resp_landing: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              !(req_in_valid[at][ap] && req_in_ready[at][ap] &&
                req_alloc_found[at][ap] && req_addr_hit_drain[at][ap]))
            else $fatal(1,
                "MSHR allocated a second entry while a same-address entry was draining/receiving (tile %0d port %0d)",
                at, ap);
        end
      end
    end

    if (PD2) begin : gen_bypass_depth_assert
      for (genvar bt = 0; bt < NumTilesPerGroup; bt++) begin : gen_bypass_depth_tile
        // All tracking ways occupied = overflow. bypass_track_q is a PACKED ARRAY of structs,
        // so bypass_track_q[bt].valid is NOT a legal field select across the dimension (vlog
        // accepts it, vopt rejects it) -- reduce explicitly. all_ways_valid is sim-only (this
        // whole block is inside pragma translate_off).
        logic all_ways_valid;
        always_comb begin
          all_ways_valid = 1'b1;
          for (int w = 0; w < BypassTrackWays; w++)
            all_ways_valid = all_ways_valid & bypass_track_q[bt][w].valid;
        end
        for (genvar bp = 1; bp < NumRemoteReqPortsPerTile; bp++) begin : gen_bypass_depth_port
          bypass_track_overflow: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              (req_in_valid[bt][bp] && req_in_ready[bt][bp] && req_out_valid[bt][bp] &&
               (req_out[bt][bp].mshr_tag == '0) &&
               req_is_load[bt][bp] && (req_len[bt][bp] > BurstLenWidth'(1)) &&
               !req_alloc_found[bt][bp])
              |-> !all_ways_valid)
            else $fatal(1, "ParityDrain: bypass-track overflow at tile %0d (all %0d ways outstanding).", bt, BypassTrackWays);
        end
      end
    end

    // ParityDrain retag-range invariant (design §6): every burst entry's subscribers must carry
    // core_id == 1 (the VLSU burst base port), so the +（b&1) retag lands on exactly {1,2}. A
    // violation would misroute odd beats into another core data port (silent corruption).
    if (PD2) begin : gen_pd2_coreid_assert
      for (genvar pd_e = 0; pd_e < MshrNum; pd_e++) begin : gen_pd2_coreid_entry
        for (genvar s = 0; s < MshrMergeReqs; s++) begin : gen_pd2_coreid_sub
          pd2_burst_sub_coreid: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              !mshr_d_valid[pd_e] ||
              (mshr_d[pd_e].burst_len == BurstLenWidth'(1)) ||
              !mshr_d[pd_e].sub_reqs[s].valid ||
              (mshr_d[pd_e].sub_reqs[s].core_id == tile_core_id_t'(1)))
            else $fatal(1, "ParityDrain: burst entry %0d sub %0d core_id=%0d != 1 (retag would misroute).",
                        pd_e, s, mshr_d[pd_e].sub_reqs[s].core_id);
        end
      end
    end

    // Hold-the-fetch invariant: an entry whose fetch has not been issued can have no response
    // activity -- it must sit in WAIT_RESP with zero beats seen. A violation means a response
    // was captured for a never-sent tag (tag aliasing / capture-guard bug).
    if (HoldWindowMax != 0) begin : gen_hold_assert
      for (genvar he = 0; he < MshrNum; he++) begin : gen_hold_assert_entry
`ifndef TARGET_SYNTHESIS
        hold_unissued_no_beats: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            !mshr_q_valid[he] || mshr_q[he].issued ||
            ((mshr_q[he].state == MSHR_WAIT_RESP) && (mshr_q[he].beat_seen == '0)))
          else $fatal(1, "hold-the-fetch: entry %0d has response activity before issue (state=%0d beat_seen=%0h).",
                      he, mshr_q[he].state, mshr_q[he].beat_seen);
`endif
      end
    end

    // If a request merges into an existing burst MSHR entry, the entry must still
    // be in its pre-response phase (no beat has been drained yet).
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_late_join_guard_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_late_join_guard_port
        no_late_join_burst: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            !(req_in_valid[tile_i][port_i] &&
              req_in_ready[tile_i][port_i] &&
              req_merge_valid[tile_i][port_i] &&
              req_hit_mshr_sel_valid[tile_i][port_i] &&
              (req_len[tile_i][port_i] > BurstLenWidth'(1))) ||
            ((mshr_q[req_hit_mshr_sel_id[tile_i][port_i]].state == MSHR_WAIT_RESP) &&
             (mshr_q[req_hit_mshr_sel_id[tile_i][port_i]].beats_left ==
              mshr_q[req_hit_mshr_sel_id[tile_i][port_i]].burst_len)))
          else $fatal(1,
                      "MSHR late join burst: tile=%0d port=%0d mshr=%0d len=%0d left=%0d state=%0d",
                      tile_i, port_i, req_hit_mshr_sel_id[tile_i][port_i],
                      req_len[tile_i][port_i],
                      mshr_q[req_hit_mshr_sel_id[tile_i][port_i]].beats_left,
                      mshr_q[req_hit_mshr_sel_id[tile_i][port_i]].state);
      end
    end
  endgenerate
  `endif
  // pragma translate_on

  // NOTE: two valid MSHR entries CAN legitimately share an address and that is
  // NOT a duplicate-allocation bug: when a later same-address request cannot
  // merge into an already-draining entry (the no_late_join_burst rule), it
  // allocates a second entry with a DIFFERENT meta_id range, and responses are
  // routed by (tile_id, core_id, meta_id range), not by address -- so each entry
  // captures its own response correctly. (An address-only no-duplicate assertion
  // was tried and fired on this benign case in P1, so it was removed.) The
  // deadlock the config comment referred to (a CACHED entry plus a fresh
  // same-address single-word allocation) is instead prevented by the invariant
  // asserted above (cached_entry_holds_data): a CACHED entry always holds its
  // data, so a single-word load to it always hits the merge path and never
  // allocates a second entry.

  // Detect whether any response beat on input already targets each MSHR entry.
  // This blocks late-join on burst entries as soon as first beat appears,
  // even when that beat is not accepted in the same cycle.
  //
  // TIMING/AREA REWRITE (RespSeenByTag, default on): route by the round-tripped tag instead of
  // scanning every entry -- the same Tier-b trick the capture path (resp_is_mshr/resp_mshr_id)
  // already uses; this signal simply predates it. The legacy form ran the full predicate for
  // (resp ports x MshrNum) = 32 x 128 = 4096 candidate matches, each a subtract plus range compare,
  // and its result feeds req_hit_way -> the allocation grant -> req_in_ready. Tag routing does ONE
  // indexed lookup per response slot (32 total) with a byte-identical predicate.
  //
  // Equivalence: the tagged entry always matches (the tag was stamped from it), and no OTHER entry
  // can match, because req_meta_conflict forbids two live entries with the same owner tile+core and
  // overlapping meta ranges. The one exception is two SAME-ADDRESS entries of one core (the meta
  // check exempts same-address via same_addr_excl, reachable when a merge is refused by a full
  // sub-request list): there the legacy scan set the bit on BOTH entries while the tag sets it only
  // on the entry the beat actually belongs to -- strictly more accurate, and it only ever removes a
  // spurious merge block. Keep the knob to A/B that corner if a workload ever exercises it.
  localparam bit RespSeenByTag =
    `ifdef GROUP_MSHR_RESP_SEEN_BY_TAG `GROUP_MSHR_RESP_SEEN_BY_TAG `else 1'b1 `endif;
  always_comb begin
    mshr_resp_seen_now = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        if (resp_in_valid[tile_i][port_i] &&
            (resp_in[tile_i][port_i].wen == 1'b0) &&
            (resp_in[tile_i][port_i].rdata.amo == '0)) begin
          if (RespSeenByTag) begin
            // O(1): index the tagged entry, then run the identical re-validation.
            if (resp_in[tile_i][port_i].mshr_tag != '0) begin : rsn_tag
              rsn_tag_cand =
                  mshr_id_t'(resp_in[tile_i][port_i].mshr_tag - MshrTagWidth'(1));
              if (mshr_q_valid[rsn_tag_cand] &&
                  ((mshr_q[rsn_tag_cand].state == MSHR_WAIT_RESP) ||
                   (mshr_q[rsn_tag_cand].state == MSHR_DRAIN_RESP)) &&
                  (mshr_q[rsn_tag_cand].sub_reqs[0].tile_id == tile_group_id_t'(tile_i)) &&
                  burst_beat_valid(resp_in[tile_i][port_i].rdata.core_id,
                                   resp_in[tile_i][port_i].rdata.meta_id,
                                   mshr_q[rsn_tag_cand].sub_reqs[0].core_id,
                                   mshr_q[rsn_tag_cand].sub_reqs[0].meta_id_base,
                                   mshr_q[rsn_tag_cand].burst_len)) begin
                mshr_resp_seen_now[rsn_tag_cand] = 1'b1;
              end
            end
          end else begin
            for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
              if (mshr_q_valid[mshr_i] &&
                  ((mshr_q[mshr_i].state == MSHR_WAIT_RESP) ||
                   (mshr_q[mshr_i].state == MSHR_DRAIN_RESP)) &&
                  (mshr_q[mshr_i].sub_reqs[0].tile_id == tile_group_id_t'(tile_i)) &&
                  burst_beat_valid(resp_in[tile_i][port_i].rdata.core_id,
                                   resp_in[tile_i][port_i].rdata.meta_id,
                                   mshr_q[mshr_i].sub_reqs[0].core_id,
                                   mshr_q[mshr_i].sub_reqs[0].meta_id_base,
                                   mshr_q[mshr_i].burst_len)) begin
                mshr_resp_seen_now[mshr_i] = 1'b1;
              end
            end
          end
        end
      end
    end
  end

  // Increment 3: address-banking replaces the O(ports^2) same-cycle leader/follower coalescing.
  // Each request maps to bank_of({tgt_group, merge addr}); allocation and the hit search are confined
  // to that bank's ways. Same-cycle same-address misses now allocate two entries in the same bank
  // (each with its own Tier-b tag and response) instead of one coalesced entry; staggered same-address
  // requests still coalesce via the normal MSHR-hit path on the following cycle. This also removes
  // audit bug H2 (a follower could merge into an entry a meta-conflicted leader never allocated).
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_bank_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_bank_port
        // Type comes from the CLAMPED req_is_single (:878), not req_len_raw: a store or a
        // misaligned burst is forced to req_len=1 and must bank like a single (see BankSelShift*).
        assign req_bank[tile_i][port_i] =
            mshr_bank_of(req_addr_key[tile_i][port_i], req_in[tile_i][port_i].tgt_group_id,
                         req_is_single[tile_i][port_i],
                         cfg_bank_shift_single, cfg_bank_shift_burst, cfg_bank_burst_bits);
      end
    end
  endgenerate

  // MSHR hit lookup (parallel compare), bank-scoped to this request's MshrWaysPerBank ways. For a fixed
  // way_i, the absolute entry id e_abs = req_bank*MshrWaysPerBank + way_i selects one entry per bank, so
  // mshr_q[e_abs] is a MshrBankNum:1 mux feeding a single comparator (vs one comparator per MshrNum entry).
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_mshr_lookup_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_mshr_lookup_port
        for (genvar way_i = 0; way_i < MshrWaysPerBank; way_i++) begin : gen_req_mshr_lookup_way
          // Absolute entry id of this request's bank way (dynamic mux on req_bank).
          mshr_id_t e_abs;
          assign e_abs =
              mshr_id_t'(int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i);
          assign req_addr_hit_way[tile_i][port_i][way_i] =
              req_in_valid[tile_i][port_i] &&
              mshr_q_valid[e_abs] &&
              (mshr_q[e_abs].base_addr == req_addr_key[tile_i][port_i]) &&
              (mshr_q[e_abs].tgt_group_id == req_in[tile_i][port_i].tgt_group_id);
          // A same-address entry that cannot be merged into RIGHT NOW makes the request WAIT rather
          // than allocate a second entry for the same line.
          // The DRAIN_RESP term is the original one. The StallOnResp term closes a one-cycle hole:
          // while a response for the entry is arriving, req_hit_way is killed by
          // mshr_resp_seen_now/mshr_resp_inflight (correct -- a mid-burst joiner would miss the
          // earlier beats), but mshr_q still reads WAIT_RESP, so req_addr_hit_drain was false too.
          // The request therefore matched NEITHER the merge path nor the wait path and fell through
          // to ALLOCATE, taking a second way for an address whose data was already landing: a
          // redundant NoC fetch, a wasted way, and -- with resp_wait_subs_single -- two entries that
          // each fall short of the subscriber target and ride out group_mshr_serve_timeout.
          // Stalling instead costs this requester a few cycles: next cycle the entry is RESP_HOLD
          // (mergeable -- it then counts toward the target) or DRAIN_RESP (wait, then hit as CACHED).
          // Cheaper than a duplicate entry, and it adds nothing to req_hit_way / the alloc
          // arbitration path -- both signals are already computed at this level.
          assign req_addr_hit_drain_way[tile_i][port_i][way_i] =
              req_addr_hit_way[tile_i][port_i][way_i] &&
              ((mshr_q[e_abs].state == MSHR_DRAIN_RESP) ||
               (StallOnResp && (mshr_resp_seen_now[e_abs] || mshr_resp_inflight[e_abs])));

          assign req_hit_way[tile_i][port_i][way_i] =
              req_can_merge[tile_i][port_i] &&
              req_addr_hit_way[tile_i][port_i][way_i] &&
              (mshr_q[e_abs].burst_len == req_len[tile_i][port_i]) &&
              (((mshr_q[e_abs].state == MSHR_WAIT_RESP) &&
                (mshr_q[e_abs].beats_left == mshr_q[e_abs].burst_len)) ||
               (RespWaitSubsSingle && !amo_invalidate &&
                (mshr_q[e_abs].state == MSHR_RESP_HOLD) &&
                (mshr_q[e_abs].resp_buf_cnt != '0) &&
                (req_len[tile_i][port_i] == BurstLenWidth'(1))) ||
               (EnableRespCache && !amo_invalidate &&
                (mshr_q[e_abs].state == MSHR_CACHED) &&
                (mshr_q[e_abs].resp_buf_cnt != '0) &&
                (req_len[tile_i][port_i] == BurstLenWidth'(1)))) &&
              !mshr_resp_seen_now[e_abs] &&
              !mshr_resp_inflight[e_abs] &&
              ((mshr_q[e_abs].sub_reqs_num + SubReqCountW'(1)) <= MshrMergeReqs);
        end
        // Full-table meta-overlap (cross-bank): same tile+core, overlapping meta_id, different address.
        // The same-address exclusion (!addr_hit) is bank-local -- a same-address entry must be in this
        // request's bank -- so it reuses req_addr_hit_way[way] (no extra address comparator). For an
        // out-of-bank entry the bank-equality term is false, leaving the original !addr_hit == 1.
        for (genvar mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin : gen_req_meta_ovlp
          logic same_addr_excl;
          assign same_addr_excl =
              (req_bank[tile_i][port_i] == BankIdW'(mshr_i / MshrWaysPerBank)) &&
              req_addr_hit_way[tile_i][port_i][mshr_i % MshrWaysPerBank];
          assign req_meta_ovlp_map[tile_i][port_i][mshr_i] =
              req_can_merge[tile_i][port_i] &&
              mshr_q_valid[mshr_i] &&
              ((mshr_q[mshr_i].state == MSHR_WAIT_RESP) ||
               (mshr_q[mshr_i].state == MSHR_DRAIN_RESP) ||
               (mshr_q[mshr_i].state == MSHR_RESP_HOLD)) &&
              (mshr_q[mshr_i].sub_reqs[0].tile_id == tile_group_id_t'(tile_i)) &&
              (mshr_q[mshr_i].sub_reqs[0].core_id == req_in[tile_i][port_i].wdata.core_id) &&
              // Keep same-entry hits legal; block only cross-entry overlaps.
              !same_addr_excl &&
              // B2 (F7): two-sided modular range test in place of a MetaSpace-wide mask AND +
              // OR-reduce.  Two cyclic intervals intersect iff one's start lies inside the other.
              // Proven exhaustively (scripts/proof_meta_overlap.py, 1,183,744 cases at M=64, also
              // checked at M=32 and M=8) -- matching the precedent set for the mask form itself.
              //
              // The LENGTH GUARDS ARE LOAD-BEARING.  Without them the test reports overlap when
              // either length is zero, where the mask correctly reports none (an empty interval
              // intersects nothing).  Today an invalid entry cannot reach here because the test is
              // already gated on mshr_q_valid and on the entry state -- but that is a non-local
              // invariant, and burst_len is 0 for a cleared entry, so the guards stay.
              (mshr_q[mshr_i].burst_len != '0) &&
              (req_len[tile_i][port_i] != '0) &&
              ((meta_id_t'(mshr_q[mshr_i].sub_reqs[0].meta_id_base -
                           req_in[tile_i][port_i].wdata.meta_id) < req_len[tile_i][port_i]) ||
               (meta_id_t'(req_in[tile_i][port_i].wdata.meta_id -
                           mshr_q[mshr_i].sub_reqs[0].meta_id_base) < mshr_q[mshr_i].burst_len));
        end
        assign req_hit_mshr[tile_i][port_i] = |req_hit_way[tile_i][port_i];
        assign req_addr_hit_drain[tile_i][port_i] = |req_addr_hit_drain_way[tile_i][port_i];
        assign req_meta_conflict[tile_i][port_i] = |req_meta_ovlp_map[tile_i][port_i];
      end
    end
  endgenerate

  // mshr_hit_req[e]: is entry e address-hit by some request this cycle? Used by the per-bank free-way
  // reclaim guard to avoid evicting a CACHED entry that a request is about to merge into. Scatter the
  // bank-scoped per-request way hits to absolute entry ids (decoder + OR, no address comparators).
  // Generate-scoped on CacheReclaimable: the ONLY reader is the pass-2 reclaim guard below, which
  // is itself gated on CacheReclaimable. A procedural `if` would still elaborate this 32-port x
  // 4-way dynamic-index scatter before folding it away; generate scope means it is never built.
  if (CacheReclaimable) begin : gen_mshr_hit_req
    always_comb begin
      mshr_hit_req = '0;
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
          for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
            if (req_hit_way[tile_i][port_i][way_i]) begin
              mshr_hit_req[int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i] = 1'b1;
            end
          end
        end
      end
    end
  end else begin : gen_mshr_hit_req_tie
    assign mshr_hit_req = '0;
  end

  // Select the first matching way per request to avoid multi-merge; absolute id = req_bank*ways + way.
  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_hit_mshr_sel_valid[tile_i][port_i] = 1'b0;
        req_hit_mshr_sel_id[tile_i][port_i] = '0;
        for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
          if (!req_hit_mshr_sel_valid[tile_i][port_i] &&
              req_hit_way[tile_i][port_i][way_i]) begin
            req_hit_mshr_sel_valid[tile_i][port_i] = 1'b1;
            req_hit_mshr_sel_id[tile_i][port_i] =
                mshr_id_t'(int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i);
          end
        end
      end
    end
  end

  // Allocation candidacy: a mergeable load that missed every resident entry and has no drain/meta
  // hazard wants a new entry.
  for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_alloc_cand_tile
    for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_alloc_cand_port
      assign req_alloc_cand[tile_i][port_i] =
          req_can_merge[tile_i][port_i]      &&
          !req_hit_mshr[tile_i][port_i]      &&
          !req_addr_hit_drain[tile_i][port_i] &&
          !req_meta_conflict[tile_i][port_i];
    end
  end

  // Per-bank free-way lookup with INVALID-FIRST priority (idea 2): prefer a truly free (invalid)
  // way, and reclaim a CACHED way only when the bank has no invalid way. This preserves the
  // response cache better than the old lowest-index-free-or-cached scan (which could evict a
  // low-index CACHED line while a higher-index invalid way sat unused). Allocation priority is
  // With CacheReclaimable=1 priority is invalid -> CACHED -> bypass. With it at 0, pass 2 is
  // disabled and a bank containing only CACHED ways reports full.
  always_comb begin
    int e;
    for (int b = 0; b < MshrBankNum; b++) begin
      bank_has_free[b] = 1'b0;
      bank_free_id[b]  = mshr_id_t'(b * MshrWaysPerBank);
      // Pass 1: lowest INVALID way.
      for (int w = 0; w < MshrWaysPerBank; w++) begin
        e = b * MshrWaysPerBank + w;
        if (!bank_has_free[b] && !mshr_q_valid[e]) begin
          bank_has_free[b] = 1'b1;
          bank_free_id[b]  = mshr_id_t'(e);
        end
      end
      // Pass 2: only if no invalid way, reclaim a reclaimable CACHED way (a resident
      // cache line with no pending subscribers that no request is about to hit-merge this
      // cycle). CacheVictimRR=0: legacy lowest-index-first (way 0 always the first victim).
      // CacheVictimRR=1: the scan starts at the bank's RR victim pointer, so the victim
      // rotates across the ways (pointer advanced by reclaim fires, see the alloc block).
      if (!bank_has_free[b] && CacheReclaimable) begin
        for (int w = 0; w < MshrWaysPerBank; w++) begin
          alloc_victim_rw = w;
          if (CacheVictimRR) begin
            alloc_victim_rw = int'(victim_rr_q[b]) + w;
            if (alloc_victim_rw >= MshrWaysPerBank)
              alloc_victim_rw = alloc_victim_rw - MshrWaysPerBank;
          end
          e = b * MshrWaysPerBank + alloc_victim_rw;
          if (!bank_has_free[b] &&
              EnableRespCache &&
              mshr_q_valid[e] &&
              (mshr_q[e].state == MSHR_CACHED) &&
              (mshr_q[e].sub_reqs_num == '0) &&
              !mshr_hit_req[e]) begin
            bank_has_free[b] = 1'b1;
            bank_free_id[b]  = mshr_id_t'(e);
          end
        end
      end
    end
  end

  // Per-bank single allocation per cycle: at most one candidate per bank is granted a new entry (taking
  // that bank's free way). Other same-bank candidates get req_alloc_found=0 and STALL (req_in_ready=0),
  // then either win on a later cycle or HIT-and-merge once the granted entry is resident -> preserves
  // full coalescing (over <=2 cycles) without the O(ports^2) leader/follower compare.
  // RR fairness (audit M2'): when EnableRrFairness, the requester (tile,port) priority axis is rotated
  // by the free-running alloc_rr base so a high-index tile is no longer perpetually beaten to a contended
  // bank by a low-index one. This gives starvation-FREEDOM (a loser whose bank is full bypasses to the
  // NoC and completes, 1260-ish) plus best-effort fair rotation -- NOT a hard bounded-wait under
  // adversarial periodic bank occupancy. Exactly-one-grant-per-bank is unchanged (bank_alloc_taken[b]).
  // TIMING REWRITE (same grants, by construction -- see the equivalence argument below).
  //
  // The previous form walked the NumAllocSlots requester slots in rotated order and carried a
  // bank_alloc_taken bitmap between iterations, so slot k's decision depended on every slot < k:
  // a NumAllocSlots-deep (32 here) SERIAL chain, with a dynamic index per stage from the rotation,
  // sitting directly in front of req_in_ready / req_out_valid (the door handshake).
  //
  // Equivalence: a slot maps to exactly ONE bank, so "the first candidate for bank b in rotated
  // order" is independent per bank -- the carried bitmap only ever excluded slots of the SAME bank.
  // And visiting base, base+1, ... (mod N) is exactly (slots >= base, ascending) followed by
  // (slots < base, ascending). So splitting each bank's request vector at the rotation base and
  // taking the lowest set bit of the high half, else of the low half, picks the identical winner.
  // Depth becomes one priority encode (~log2 N) with all MshrBankNum banks evaluated in parallel.
  logic [NumAllocSlots-1:0]                  alloc_cand_flat;
  logic [NumAllocSlots-1:0][BankIdW-1:0]     alloc_bank_flat;
  logic [NumAllocSlots-1:0]                  alloc_rr_mask;   // 1 = slot is at/above the RR base
  logic [MshrBankNum-1:0][NumAllocSlots-1:0] bank_win_oh;     // one-hot winner per bank

  // Loop temporaries for the allocation arbiter, declared at module scope rather than as
  // procedural `automatic`s inside the always_comb below. Same hardware either way -- each is
  // written before it is read on every unrolled iteration -- but module-scope packed vectors are
  // what the backend flow expects, and they are visible in a waveform where an automatic is not.
  //
  // Widths are sized, not `int`: the slot index only has to span NumAllocSlots and the bank index
  // MshrBankNum, so this drops two 32-bit signed intermediates that the tools would otherwise
  // have to prove redundant.
  // One signal PER always_comb: a module-scope variable may have only a single combinational
  // driver, and this index is recomputed independently in the flatten and scatter blocks.
  logic [AllocRrW-1:0]                       alloc_slot_idx;      // flatten block
  logic [AllocRrW-1:0]                       alloc_scatter_slot;  // scatter block
  logic [BankIdW-1:0]                        alloc_scatter_bank;
  logic [NumAllocSlots-1:0]                  alloc_rq;        // per-bank request vector
  logic [NumAllocSlots-1:0]                  alloc_hi;        // ... at/above the rotation base
  logic [NumAllocSlots-1:0]                  alloc_lo;        // ... below it
  logic [NumAllocSlots-1:0]                  alloc_hi_lsb;    // lowest set bit of each half
  logic [NumAllocSlots-1:0]                  alloc_lo_lsb;

  // Per-bank merge arbiter (OneMergePerBank). Same shape as the allocation arbiter above and sharing
  // its rotation base, so a high-index tile is not perpetually beaten to a contended bank. Separate
  // signals rather than reuse: a module-scope variable may have only one combinational driver.
  logic [NumAllocSlots-1:0]                  merge_arb_cand_flat;
  logic [NumAllocSlots-1:0][BankIdW-1:0]     merge_arb_bank_flat;
  logic [MshrBankNum-1:0][NumAllocSlots-1:0] bank_merge_win_oh;   // one-hot merge winner per bank
  logic [AllocRrW-1:0]                       merge_arb_slot_idx;      // flatten block
  logic [AllocRrW-1:0]                       merge_arb_scatter_slot;  // scatter block
  logic [NumAllocSlots-1:0]                  merge_arb_rq;
  logic [NumAllocSlots-1:0]                  merge_arb_hi;
  logic [NumAllocSlots-1:0]                  merge_arb_lo;
  logic [NumAllocSlots-1:0]                  merge_arb_hi_lsb;
  logic [NumAllocSlots-1:0]                  merge_arb_lo_lsb;
  logic [NumAllocSlots-1:0]                  merge_arb_grant_flat_dbg; // granted lanes, for coverage

  always_comb begin
    alloc_cand_flat = '0;
    alloc_bank_flat = '0;
    // slot = tile*NumReqPortsActive + (port-1) is a bijection over the active req ports
    // (1..NumRemoteReqPortsPerTile-1); the * and + are constant folds, not arithmetic.
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        alloc_slot_idx = AllocRrW'(tile_i * NumReqPortsActive + (port_i - 1));
        alloc_cand_flat[alloc_slot_idx] = req_alloc_cand[tile_i][port_i];
        alloc_bank_flat[alloc_slot_idx] = req_bank[tile_i][port_i];
      end
    end
    // Thermometer mask from the rotation base, computed once and shared by every bank.
    // EnableRrFairness = 0 collapses it to all-ones, i.e. plain ascending priority from slot 0 --
    // exactly the old alloc_base = 0 behaviour.
    for (int s = 0; s < NumAllocSlots; s++) begin
      alloc_rr_mask[s] = EnableRrFairness ? (s >= int'(alloc_rr_q)) : 1'b1;
    end
    for (int b = 0; b < MshrBankNum; b++) begin
      alloc_rq = '0;
      for (int s = 0; s < NumAllocSlots; s++) begin
        alloc_rq[s] = alloc_cand_flat[s] && (int'(alloc_bank_flat[s]) == b);
      end
      alloc_hi     = alloc_rq &  alloc_rr_mask;
      alloc_lo     = alloc_rq & ~alloc_rr_mask;
      alloc_hi_lsb = alloc_hi & (~alloc_hi + NumAllocSlots'(1));   // isolate lowest set bit
      alloc_lo_lsb = alloc_lo & (~alloc_lo + NumAllocSlots'(1));
      // bank_has_free gating reproduces the old `bank_has_free[b]` term: a bank with no free way
      // grants nobody, and its candidates fall through to the stall/bypass decision unchanged.
      bank_win_oh[b] = !bank_has_free[b] ? '0
                                         : ((alloc_hi != '0) ? alloc_hi_lsb : alloc_lo_lsb);
    end
  end

  // Scatter the per-bank one-hot grant back to the (tile,port) requesters. Slot s only ever appears
  // in its own bank's vector, so indexing by req_bank here selects that same bank.
  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        alloc_scatter_slot = AllocRrW'(tile_i * NumReqPortsActive + (port_i - 1));
        alloc_scatter_bank = req_bank[tile_i][port_i];
        req_alloc_found[tile_i][port_i]         =
            bank_win_oh[alloc_scatter_bank][alloc_scatter_slot];
        req_alloc_found_mshr_id[tile_i][port_i] =
            bank_win_oh[alloc_scatter_bank][alloc_scatter_slot] ? bank_free_id[alloc_scatter_bank]
                                                                : '0;
      end
    end
  end

  // Select the merge target per request. With address-banking the only merge path is hitting an
  // already-resident entry (req_hit_mshr_sel); the same-cycle leader/follower path is removed (a 2nd
  // same-address requester in the same cycle allocates its own entry, and the next cycle's request to
  // that address hits and merges normally).
  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_merge_valid[tile_i][port_i] =
            req_can_merge[tile_i][port_i] && req_hit_mshr_sel_valid[tile_i][port_i];
        req_merge_mshr_id[tile_i][port_i] = req_hit_mshr_sel_id[tile_i][port_i];
      end
    end
  end

  // Per-bank merge arbiter. The hit search is already bank-scoped (a hit entry always lies in
  // req_bank -- asserted by mshr_entry_in_its_bank), so the merge target's bank is req_bank and no
  // decode of the entry id is needed. Structurally identical to the allocation arbiter: split each
  // bank's request vector at the shared rotation base, take the lowest set bit of the high half,
  // else of the low half.
  always_comb begin
    merge_arb_cand_flat = '0;
    merge_arb_bank_flat = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        merge_arb_slot_idx = AllocRrW'(tile_i * NumReqPortsActive + (port_i - 1));
        merge_arb_cand_flat[merge_arb_slot_idx] = req_merge_valid[tile_i][port_i];
        merge_arb_bank_flat[merge_arb_slot_idx] = req_bank[tile_i][port_i];
      end
    end
    for (int b = 0; b < MshrBankNum; b++) begin
      merge_arb_rq = '0;
      for (int s = 0; s < NumAllocSlots; s++) begin
        merge_arb_rq[s] = merge_arb_cand_flat[s] && (int'(merge_arb_bank_flat[s]) == b);
      end
      // alloc_rr_mask is the shared thermometer mask from the rotation base; it is a pure function
      // of alloc_rr_q, driven once in the allocation block above and only READ here.
      merge_arb_hi     = merge_arb_rq &  alloc_rr_mask;
      merge_arb_lo     = merge_arb_rq & ~alloc_rr_mask;
      merge_arb_hi_lsb = merge_arb_hi & (~merge_arb_hi + NumAllocSlots'(1));
      merge_arb_lo_lsb = merge_arb_lo & (~merge_arb_lo + NumAllocSlots'(1));
      bank_merge_win_oh[b] = (merge_arb_hi != '0) ? merge_arb_hi_lsb : merge_arb_lo_lsb;
    end
    merge_arb_grant_flat_dbg = '0;
    for (int b = 0; b < MshrBankNum; b++) begin
      merge_arb_grant_flat_dbg = merge_arb_grant_flat_dbg | bank_merge_win_oh[b];
    end
  end

  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        merge_arb_scatter_slot = AllocRrW'(tile_i * NumReqPortsActive + (port_i - 1));
        // OneMergePerBank = 0: an existing entry is always ready to accept a merge (legacy).
        req_merge_ready[tile_i][port_i] =
            !OneMergePerBank ? 1'b1
                             : bank_merge_win_oh[req_bank[tile_i][port_i]][merge_arb_scatter_slot];
      end
    end
  end

  // Sequential state update
  // Shared hold prescaler: one free-running counter per MSHR instance. Entry e takes its tick
  // when hold_prescale_q == e[HoldPrescaleWSafe-1:0].
  logic [HoldPrescaleWSafe-1:0]      hold_prescale_q;
  logic [2**HoldPrescaleWSafe-1:0]   hold_tick_phase;  // one-hot decode of the shared prescaler
  logic [MshrNum-1:0]                hold_tick;        // per-entry tick enable
  `FF(hold_prescale_q, (HoldPrescaleW == 0) ? '0 : (hold_prescale_q + 1'b1), '0)
  // One 1-of-2**HoldPrescaleW decoder feeds all MshrNum entries -- entries sharing the low
  // HoldPrescaleW bits of their index share a phase, so this is a decode and a fan-out, not
  // MshrNum comparators. Const-folds to all-ones when the prescaler is disabled.
  always_comb begin
    hold_tick_phase                  = '0;
    hold_tick_phase[hold_prescale_q] = 1'b1;
    // `int` is SIGNED: HoldPrescaleWSafe'(e) on a signed operand turns e = 8..15 into the 4-bit
    // patterns 1000..1111, read back as -8..-1, so the bit-select went out of range and returned
    // 'x for HALF the entries. Spyglass Design_Read caught it ("Illegal bit select. Index -8 for
    // hold_tick_phase"); vlog and elaboration did not, because it is legal SystemVerilog.
    // An unsigned loop variable truncates unsigned, giving 0..2**HoldPrescaleWSafe-1 as intended.
    for (int unsigned e = 0; e < MshrNum; e++) begin
      hold_tick[e] = (HoldPrescaleW == 0) ? 1'b1 : hold_tick_phase[HoldPrescaleWSafe'(e)];
    end
  end

  `FF(mshr_q_valid, mshr_d_valid, '0)

  // ------------------------------------------------------------
  // Entry register, split by WRITE FREQUENCY so the wide fields can be clock gated.
  //
  // 145 of an entry's 186 synthesised bits are written once or twice in its entire life:
  //
  //   identity  75 bits  base_addr, tgt_group_id, burst_len, sub_reqs[].{tile,port,core,meta}
  //                      -- written only by an allocation or a merge
  //   resp_buf  70 bits  -- written only when a response beat is captured
  //   control   41 bits  state, counters, masks, pointers -- changes on nearly every event
  //
  // One unconditional `FF over the whole entry clocked all 186 bits x MshrNum every cycle in
  // order to move, typically, a 3-bit state field.
  //
  // The enables are raised at the write sites THEMSELVES (mshr_wr_all / mshr_id_we / mshr_rb_we
  // are assigned on the line above the write they describe), not by restating the conditions
  // that guard those writes -- a restatement is what drifts out of sync when the logic changes.
  // Two independent checks keep the split honest:
  //   - MshrGateBits* below fails ELABORATION if a field is added to the entry struct without
  //     being placed in one of the three groups, so a new field cannot silently lose its flop;
  //   - mshr_gate_no_lost_write asserts every cycle in simulation that a gated-off field really
  //     is unchanged, so a missed write site is caught the first time it fires.
  //
  // The control group keeps the coarse (valid | valid_next) enable rather than a per-field one:
  // it is only 41 bits, and its fields change so often that a finer gate would cost more in
  // enable logic than it saves in clock power.
  // ------------------------------------------------------------
  localparam int unsigned MshrGateBitsIdent =
      $bits(tcdm_addr_t) + $bits(group_id_t) + BurstLenWidth +
      MshrMergeReqs * ($bits(mempool_group_mshr_sub_req_t) - 1);
  localparam int unsigned MshrGateBitsRespBuf = RespBufWords * $bits(mshr_resp_slot_t);
  localparam int unsigned MshrGateBitsCtl =
      MshrMergeReqs                 // sub_reqs[].valid
      + SubReqCountW + ServedCntW
      + MshrMergeReqs + MshrMergeReqs + 1   // beat_pending, beat_pending2, beat2_armed
      + BurstLenWidth                       // beats_left
      + RespBufCountW + RespBufPtrW + RespBufPtrW   // resp_buf_valid removed: write-only
      + 1                                   // cacheable
      + HoldCntW + 1                        // hold_cnt, issued
      + $bits(mshr_state_t)
`ifndef TARGET_SYNTHESIS
      + MaxBurstWords + MaxBurstWords + 32  // beat_seen, beat_done, cache_hit_cnt
`endif
      ;
  if ((MshrGateBitsIdent + MshrGateBitsRespBuf + MshrGateBitsCtl) !=
      $bits(mempool_group_mshr_t))
    $error("[mempool_group_mshr] entry clock-gate groups cover %0d of %0d bits -- a field was added to mempool_group_mshr_t without being assigned to a group in the entry register block.",
           MshrGateBitsIdent + MshrGateBitsRespBuf + MshrGateBitsCtl,
           $bits(mempool_group_mshr_t));

  logic [MshrNum-1:0]                   mshr_id_en;   // identity fields
  logic [MshrNum-1:0]                   mshr_ctl_en;  // control fields
  logic [MshrNum-1:0][RespBufWords-1:0] mshr_rb_en;   // one enable per response-buffer slot
  // "Some lane may allocate entry e this cycle." A CONSERVATIVE superset of the real grant, and
  // deliberately so: a clock-gate enable may be over-asserted (costs a little power) but must
  // never be under-asserted, and the cheap form is far shallower than the exact one.
  //
  // Built only from bank_win_oh / bank_free_id, which are produced OUTSIDE the big always_comb
  // (:2184 / :2072) -- roughly a 16-bank x 4-way decode. The exact grant would also need the
  // winning lane's req_in_ready, which is computed inside the request door and would drag this
  // enable back onto a ~3.8 ns path for nothing.
  //
  // bank_free_id[b] is by construction a way of bank b, so at most one e per bank is selected.
  logic [MshrNum-1:0] mshr_alloc_maybe;
  for (genvar e = 0; e < MshrNum; e++) begin : gen_alloc_maybe
    assign mshr_alloc_maybe[e] = (|bank_win_oh[e / MshrWaysPerBank]) &&
                                 (bank_free_id[e / MshrWaysPerBank] == mshr_id_t'(e));
  end
  always_comb begin
    for (int e = 0; e < MshrNum; e++) begin
      // Control changes only while the entry is live, or on the cycle it is allocated.
      //
      // This used to read `mshr_q_valid[e] | mshr_d_valid[e]`, which put every entry's control
      // clock gate on the 822-level cone: mshr_d_valid carries the dealloc decision, the LAST
      // thing computed in the process. The free cycle no longer needs an enable at all -- the
      // retire path stopped clearing the entry (see the dealloc sites), so there is nothing to
      // write -- and mshr_q_valid is an ungated `FF, so `valid` itself still updates regardless.
      mshr_ctl_en[e] = mshr_q_valid[e] | mshr_alloc_maybe[e];
      mshr_id_en[e]  = mshr_wr_all[e]  | mshr_id_we[e];
      for (int b = 0; b < RespBufWords; b++) begin
        mshr_rb_en[e][b] = mshr_wr_all[e] | mshr_rb_we[e][b];
      end
    end
  end

  for (genvar e = 0; e < MshrNum; e++) begin : gen_mshr_entry_reg
    `FFL(mshr_q[e].base_addr,    mshr_d[e].base_addr,    mshr_id_en[e], '0)
    `FFL(mshr_q[e].tgt_group_id, mshr_d[e].tgt_group_id, mshr_id_en[e], '0)
    `FFL(mshr_q[e].burst_len,    mshr_d[e].burst_len,    mshr_id_en[e], '0)
    for (genvar s = 0; s < MshrMergeReqs; s++) begin : gen_sub_req_reg
      `FFL(mshr_q[e].sub_reqs[s].tile_id,      mshr_d[e].sub_reqs[s].tile_id,      mshr_id_en[e], '0)
      `FFL(mshr_q[e].sub_reqs[s].port_id,      mshr_d[e].sub_reqs[s].port_id,      mshr_id_en[e], '0)
      `FFL(mshr_q[e].sub_reqs[s].core_id,      mshr_d[e].sub_reqs[s].core_id,      mshr_id_en[e], '0)
      `FFL(mshr_q[e].sub_reqs[s].meta_id_base, mshr_d[e].sub_reqs[s].meta_id_base, mshr_id_en[e], '0)
      `FFL(mshr_q[e].sub_reqs[s].valid,        mshr_d[e].sub_reqs[s].valid,        mshr_ctl_en[e], '0)
    end
    for (genvar b = 0; b < RespBufWords; b++) begin : gen_resp_buf_reg
      `FFL(mshr_q[e].resp_buf[b], mshr_d[e].resp_buf[b], mshr_rb_en[e][b], '0)
    end
    `FFL(mshr_q[e].sub_reqs_num,    mshr_d[e].sub_reqs_num,    mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].served_cnt,      mshr_d[e].served_cnt,      mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].beat_pending,    mshr_d[e].beat_pending,    mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].beat_pending2,   mshr_d[e].beat_pending2,   mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].beat2_armed,     mshr_d[e].beat2_armed,     mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].beats_left,      mshr_d[e].beats_left,      mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].resp_buf_cnt,    mshr_d[e].resp_buf_cnt,    mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].resp_buf_rd_ptr, mshr_d[e].resp_buf_rd_ptr, mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].resp_buf_wr_ptr, mshr_d[e].resp_buf_wr_ptr, mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].cacheable,       mshr_d[e].cacheable,       mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].hold_cnt,        mshr_d[e].hold_cnt,        mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].issued,          mshr_d[e].issued,          mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].state,           mshr_d[e].state,           mshr_ctl_en[e], mshr_state_t'(0))
`ifndef TARGET_SYNTHESIS
    `FFL(mshr_q[e].beat_seen,     mshr_d[e].beat_seen,     mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].beat_done,     mshr_d[e].beat_done,     mshr_ctl_en[e], '0)
    `FFL(mshr_q[e].cache_hit_cnt, mshr_d[e].cache_hit_cnt, mshr_ctl_en[e], '0)
`endif
  end

  // The gate must never swallow a write. A clock-gated field whose enable is low simply keeps its
  // old value, so a missed write site would not error anywhere -- the entry would just silently
  // carry stale data, exactly the failure mode that is hardest to find in a sim. These check the
  // converse of each enable directly: enable low => nothing wanted to change.
`ifndef VERILATOR
`ifndef TARGET_SYNTHESIS
  for (genvar e = 0; e < MshrNum; e++) begin : gen_mshr_gate_checks
    mshr_gate_ident_no_lost_write: assert property(
      @(posedge clk_i) disable iff (!rst_ni)
        mshr_id_en[e] ||
        ((mshr_d[e].base_addr    == mshr_q[e].base_addr) &&
         (mshr_d[e].tgt_group_id == mshr_q[e].tgt_group_id) &&
         (mshr_d[e].burst_len    == mshr_q[e].burst_len)))
      else $fatal(1, "MSHR clock gate dropped an identity write: entry=%0d", e);

    for (genvar s = 0; s < MshrMergeReqs; s++) begin : gen_mshr_gate_sub_checks
      mshr_gate_sub_no_lost_write: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          mshr_id_en[e] ||
          ((mshr_d[e].sub_reqs[s].tile_id      == mshr_q[e].sub_reqs[s].tile_id) &&
           (mshr_d[e].sub_reqs[s].port_id      == mshr_q[e].sub_reqs[s].port_id) &&
           (mshr_d[e].sub_reqs[s].core_id      == mshr_q[e].sub_reqs[s].core_id) &&
           (mshr_d[e].sub_reqs[s].meta_id_base == mshr_q[e].sub_reqs[s].meta_id_base)))
        else $fatal(1, "MSHR clock gate dropped a sub-request write: entry=%0d slot=%0d", e, s);
    end

    for (genvar b = 0; b < RespBufWords; b++) begin : gen_mshr_gate_rb_checks
      mshr_gate_rb_no_lost_write: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          mshr_rb_en[e][b] || (mshr_d[e].resp_buf[b] == mshr_q[e].resp_buf[b]))
        else $fatal(1, "MSHR clock gate dropped a resp_buf write: entry=%0d slot=%0d", e, b);
    end

    // The control group carries every remaining field, so compare the whole entry and let the
    // two checks above account for the parts they own.
    mshr_gate_ctl_no_lost_write: assert property(
      @(posedge clk_i) disable iff (!rst_ni)
        mshr_ctl_en[e] || mshr_id_en[e] || (|mshr_rb_en[e]) ||
        (mshr_d[e] == mshr_q[e]))
      else $fatal(1, "MSHR clock gate dropped a control write: entry=%0d", e);
  end
`endif
`endif
  // 16 x VictimPtrW flops that only the CacheReclaimable pass-2 scan reads; tie them off otherwise.
  if (CacheReclaimable && CacheVictimRR) begin : gen_victim_rr
    `FF(victim_rr_q, victim_rr_d, '0)
  end else begin : gen_victim_rr_tie
    assign victim_rr_q = '0;
  end

  // Round-robin fairness bases: free-running +1 mod-N every cycle, reset '0.
  // Each _d depends ONLY on its own _q (pure mod-N increment), never on any
  // arbitration/grant output -> no combinational loop. Reset '0 makes cycle-0
  // order match the legacy lowest-index order; rotation diverges from cycle 1.
  // The unconditional advance is exactly why an adversary cannot freeze priority
  // by withholding grants (the leader pointer marches every clock regardless).
  assign alloc_rr_d      = (alloc_rr_q      == AllocRrW'(NumAllocSlots - 1)) ?
                           '0 : alloc_rr_q      + AllocRrW'(1);
  assign drain_mshr_rr_d = (drain_mshr_rr_q == DrainMshrRrW'(MshrNum - 1)) ?
                           '0 : drain_mshr_rr_q + DrainMshrRrW'(1);
  assign subreq_rr_d     = (subreq_rr_q     == SubReqRrW'(MshrMergeReqs - 1)) ?
                           '0 : subreq_rr_q     + SubReqRrW'(1);
  `FF(alloc_rr_q,      alloc_rr_d,      '0)
  `FF(drain_mshr_rr_q, drain_mshr_rr_d, '0)
  `FF(subreq_rr_q,     subreq_rr_d,     '0)
  `FF(bank_rr_q,       bank_rr_d,       '0)

  // Hold-the-fetch replay base: same free-running pattern; compiled out with the feature.
  if (HoldWindowMax != 0) begin : gen_hold_replay_rr
    mshr_id_t hold_replay_rr_d;
    assign hold_replay_rr_d = (hold_replay_rr_q == mshr_id_t'(MshrNum - 1)) ?
                              '0 : hold_replay_rr_q + mshr_id_t'(1);
    `FF(hold_replay_rr_q, hold_replay_rr_d, '0)
  end else begin : gen_hold_replay_rr_off
    assign hold_replay_rr_q = '0;
  end

  // ------------------------------------------------------------------------
  // Entry-occupancy view for utilization analysis (simulation-only, zero hardware,
  // always available -- no debug define needed).
  //
  // mshr_q_valid alone is NOT utilization: it also counts ways that merely hold a
  // response-cache line (state == MSHR_CACHED), whose reclaimability is controlled by
  // CacheReclaimable. Split into the two populations:
  //   mshr_inuse_dbg  : entry tracks an OUTSTANDING remote miss (WAIT_RESP /
  //                     RESP_HOLD / DRAIN_RESP) -- the true MSHR occupancy.
  //   mshr_cached_dbg : entry is only a response-cache way (CACHED).
  //   mshr_held_dbg   : subset of in-use whose NoC fetch is still WITHHELD by
  //                     hold-the-fetch (WAIT_RESP && !issued) -- all-zero when
  //                     group_mshr_hold_window = 0, so this directly measures the
  //                     way-occupancy cost of a hold window.
  // The *_cnt_dbg signals are the per-cycle populations (0..MshrNum);
  // mshr_valid_cnt_dbg == mshr_inuse_cnt_dbg + mshr_cached_cnt_dbg.
  // ------------------------------------------------------------------------
  // pragma translate_off
  localparam int unsigned MshrCntW = idx_width(MshrNum + 1);
  logic [MshrNum-1:0]  mshr_inuse_dbg;
  logic [MshrNum-1:0]  mshr_cached_dbg;
  logic [MshrNum-1:0]  mshr_held_dbg;
  logic [MshrCntW-1:0] mshr_inuse_cnt_dbg;
  logic [MshrCntW-1:0] mshr_cached_cnt_dbg;
  logic [MshrCntW-1:0] mshr_held_cnt_dbg;
  logic [MshrCntW-1:0] mshr_valid_cnt_dbg;
  always_comb begin
    mshr_inuse_dbg  = '0;
    mshr_cached_dbg = '0;
    mshr_held_dbg   = '0;
    for (int e = 0; e < MshrNum; e++) begin
      if (mshr_q_valid[e]) begin
        if (mshr_q[e].state == MSHR_CACHED) begin
          mshr_cached_dbg[e] = 1'b1;
        end else begin
          mshr_inuse_dbg[e] = 1'b1;
          if ((mshr_q[e].state == MSHR_WAIT_RESP) && !mshr_q[e].issued) begin
            mshr_held_dbg[e] = 1'b1;
          end
        end
      end
    end
    mshr_inuse_cnt_dbg  = MshrCntW'($countones(mshr_inuse_dbg));
    mshr_cached_cnt_dbg = MshrCntW'($countones(mshr_cached_dbg));
    mshr_held_cnt_dbg   = MshrCntW'($countones(mshr_held_dbg));
    mshr_valid_cnt_dbg  = MshrCntW'($countones(mshr_q_valid));
  end

  // ------------------------------------------------------------------------
  // Hold-the-fetch RELEASE-REASON view (simulation-only). One-cycle pulse per entry
  // in the cycle its withheld fetch is actually handed to the NoC lane (the rising
  // edge of `issued`, so the pulse lines up with the req_out handshake), split by
  // which release condition fired:
  //   mshr_issue_timeout_dbg : the window expired (hold_cnt reached 0) -- the entry
  //                            waited the full W and no partner ever arrived.
  //   mshr_issue_subs_dbg    : sub_reqs_num reached the early-release target
  //                            (group_mshr_hold_subs / _single / _burst) -- a real
  //                            coalescing catch, the case the hold exists for.
  // Classified with the SAME expression the replay walker uses (both read the
  // post-decrement mshr_d view), so the split matches actual behavior. If both
  // conditions are true in one cycle, timeout wins -- the two vectors are therefore
  // mutually exclusive and together account for every held issue.
  // The *_cnt_dbg accumulators are FREE-RUNNING from reset (not csr_trace gated), so
  // take the delta between two cursors to scope a figure to a kernel region. They
  // add the per-cycle popcount because the walker can release several entries in one
  // cycle (one per free outbound lane). Both stay 0 when group_mshr_hold_window = 0.
  // ------------------------------------------------------------------------
  logic [MshrNum-1:0] mshr_issue_timeout_dbg;
  logic [MshrNum-1:0] mshr_issue_subs_dbg;
  // RESPONSE-side timeout deaths. Neither of these was counted anywhere: the only timeout counter
  // in this file is mshr_issue_timeout_cnt_dbg, which is REQUEST-side and gated on hold_window !=
  // 0 -- and hold_window_single is 0 in every shipping config, so scalar entries were invisible.
  //   resp_hold_timeout : a RESP_HOLD entry gave up waiting for subscribers (serve_timeout hit 0)
  //                       and delivered to whoever HAD subscribed. The 2047-cycle fp16 stall.
  //   cache_timeout     : a CACHED line aged out before reaching its reuse target. This is the
  //                       one that decides whether the cache residency is long ENOUGH: a line
  //                       that dies here took its second cohort's data with it, so the partial-hit
  //                       split recurs. It shows up as neither hit nor self_inval, which is why
  //                       "17 of 49 lines unaccounted" could not be diagnosed before.
  logic [MshrNum-1:0] mshr_resp_hold_timeout_dbg;
  logic [MshrNum-1:0] mshr_cache_timeout_dbg;
  logic [31:0]        mshr_issue_timeout_cnt_dbg;
  logic [31:0]        mshr_resp_hold_timeout_cnt_dbg;
  logic [31:0]        mshr_cache_timeout_cnt_dbg;
  logic [31:0]        mshr_issue_subs_cnt_dbg;

  always_comb begin
    mshr_issue_timeout_dbg = '0;
    mshr_issue_subs_dbg    = '0;
    if (HoldWindowMax != 0) begin
      for (int e = 0; e < MshrNum; e++) begin
        // Genuine held->released edge: the entry was VALID and NOT issued last cycle and is
        // issued now. This excludes a 0-window class (issued=1, hold_cnt=0 at birth), which was
        // never held -- otherwise every immediate issue would fall into the timeout bucket. The
        // per-type window != 0 gate makes it airtight even under a same-cycle realloc collision
        // (an evicted held entry replaced by a 0-window alloc in one cycle).
        if (mshr_d_valid[e] && mshr_d[e].issued &&
            mshr_q_valid[e] && !mshr_q[e].issued &&
            (((mshr_d[e].burst_len == BurstLenWidth'(1)) ?
               cfg_hold_window_single : cfg_hold_window_burst) != 0)) begin
          if (mshr_d[e].hold_cnt == '0) mshr_issue_timeout_dbg[e] = 1'b1;
          else                          mshr_issue_subs_dbg[e]    = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mshr_issue_timeout_cnt_dbg <= '0;
      mshr_issue_subs_cnt_dbg    <= '0;
      mshr_resp_hold_timeout_cnt_dbg <= '0;
      mshr_cache_timeout_cnt_dbg     <= '0;
    end else begin
      mshr_issue_timeout_cnt_dbg <=
          mshr_issue_timeout_cnt_dbg + 32'($countones(mshr_issue_timeout_dbg));
      mshr_issue_subs_cnt_dbg    <=
          mshr_issue_subs_cnt_dbg    + 32'($countones(mshr_issue_subs_dbg));
      mshr_resp_hold_timeout_cnt_dbg <=
          mshr_resp_hold_timeout_cnt_dbg + 32'($countones(mshr_resp_hold_timeout_dbg));
      mshr_cache_timeout_cnt_dbg     <=
          mshr_cache_timeout_cnt_dbg     + 32'($countones(mshr_cache_timeout_dbg));
    end
  end

  // ------------------------------------------------------------------------
  // F3c COVERAGE. The whole difficulty of the per-entry response capture is the case where TWO
  // response lanes capture into the SAME entry in one cycle -- that is the only path where slot
  // ordering, the resp_buf pointer advance and the saturating count can disagree between the
  // sequential and parallel forms. A cycle-identity result on a workload that never produces it
  // proves only that the one-lane path still works, which is not the thing at risk.
  //
  // So count it. Zero across a whole run means the equivalence check did NOT cover the hazard and
  // the arm must not be read as verifying F3c -- an identically-zero telemetry counter is a
  // finding, not background.
  //
  // Reachable in principle: resp_is_mshr requires sub_reqs[0].tile_id == tile_i, so both lanes
  // must be the two response ports of ONE tile -- which is exactly what ParityDrain produces when
  // consecutive beats of a burst return together.
  //
  // Declared and used entirely inside this translate_off region; simulators compile it, synthesis
  // never sees it. (The converse -- declaring here and using outside -- is what broke synthesis
  // in 467fa6c7.)
  // F3b's per-entry merge ORs each hitting lane's ENABLED bytes. That reproduces the sequential
  // last-lane-wins exactly while the hitting lanes touch DISJOINT bytes. When they overlap, the
  // two forms can differ -- both are architecturally valid (simultaneous stores to one byte are
  // unordered), but the difference would break a cycle-identity comparison, so it must be
  // measured, not assumed. Non-zero here means the equivalence arm's verdict needs interpreting.
  logic [31:0] stb_ovl_cnt_dbg;
  logic [31:0] cap_two_grant_cnt_dbg;   // cycles-with-entries where a second lane was granted
  logic [31:0] cap_one_grant_cnt_dbg;   // ... where only the first was, for a ratio
  // OneMergePerBank cost, measured rather than argued: merges the per-bank arbiter refused this
  // cycle (the lane is a valid merge hit but lost its bank), against merges it granted. A stalled
  // lane is not a lost merge -- it retries next cycle against the same resident entry -- so this is
  // the RETRY count, i.e. exactly the throughput being traded for the rank network's removal.
  logic [31:0] merge_arb_stall_cnt_dbg;
  logic [31:0] merge_arb_grant_cnt_dbg;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cap_two_grant_cnt_dbg <= '0;
      cap_one_grant_cnt_dbg <= '0;
      stb_ovl_cnt_dbg       <= '0;
      merge_arb_stall_cnt_dbg <= '0;
      merge_arb_grant_cnt_dbg <= '0;
    end else begin
      cap_two_grant_cnt_dbg <= cap_two_grant_cnt_dbg + 32'($countones(cap_g2));
      cap_one_grant_cnt_dbg <= cap_one_grant_cnt_dbg + 32'($countones(cap_g1 & ~cap_g2));
      stb_ovl_cnt_dbg       <= stb_ovl_cnt_dbg       + 32'($countones(stb_ovl));
      merge_arb_stall_cnt_dbg <= merge_arb_stall_cnt_dbg +
          32'($countones(merge_arb_cand_flat & ~merge_arb_grant_flat_dbg));
      merge_arb_grant_cnt_dbg <= merge_arb_grant_cnt_dbg +
          32'($countones(merge_arb_cand_flat &  merge_arb_grant_flat_dbg));
    end
  end
  final begin
    $display("[F3cCOV] group=%0d two_lane_grants=%0d one_lane_grants=%0d store_byte_overlaps=%0d",
             group_id_i, cap_two_grant_cnt_dbg, cap_one_grant_cnt_dbg, stb_ovl_cnt_dbg);
    $display("[MRGARB] group=%0d merge_grants=%0d merge_arb_stalls=%0d",
             group_id_i, merge_arb_grant_cnt_dbg, merge_arb_stall_cnt_dbg);
  end

  // ------------------------------------------------------------------------
  // RESP_HOLD stall probe (simulation-only, group_mshr_resp_hold_probe = age threshold).
  // Diagnoses WHY an entry holding a returned scalar response never reaches HoldSubsSingle
  // subscribers. It does not assume a cause -- it records, per held entry, the evidence that
  // separates the competing explanations:
  //   byp   : same-{addr,group} single-beat mergeable requests that BYPASSED to the NoC while this
  //           entry was held. A bank with no free way sends such a request to the bypass branch
  //           instead of merging, so its subscriber is lost to this entry FOREVER -> the target can
  //           never be met. (Hypothesis: bank pressure steals the missing subscriber.)
  //   stl   : same-{addr,group} requests presented but not accepted (drain-hazard / meta-conflict /
  //           lost the per-bank alloc slot). These retry, so they are a delay, not a loss --
  //           distinguishing them from `byp` is the whole point.
  //   peers : other VALID entries with the SAME {addr,group}. Non-zero means the sharers SPLIT
  //           across entries, so no single entry can reach the target.
  //   census: ways of this entry's bank by state (invalid/wait/drain/hold/cached) at the moment of
  //           the report -- shows whether the bank was full, and of what.
  // Reported once per hold episode (rh_rep), so a wedged entry does not spam.
  // ------------------------------------------------------------------------
  // pragma translate_off
  // SIMULATION ONLY -- the resp-hold probe is [RH STUCK] telemetry: a longint cycle counter, 32-bit debug counters and a
  // $display of stuck held entries. Nothing outside reads it.
  // It is enabled by a VALUE knob (group_mshr_resp_hold_probe), which both backend
  // configs set, so without this guard the probe is elaborated as real hardware.
`ifndef TARGET_SYNTHESIS
  if (RespHoldProbe != 0) begin : gen_resp_hold_probe
    int  rh_age   [MshrNum];
    int  rh_byp   [MshrNum];
    int  rh_stl   [MshrNum];
    bit  rh_rep   [MshrNum];
    longint rh_cyc;
    int  rh_report_cnt;

    always @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rh_cyc = 0; rh_report_cnt = 0;
        for (int e = 0; e < MshrNum; e++) begin
          rh_age[e] = 0; rh_byp[e] = 0; rh_stl[e] = 0; rh_rep[e] = 0;
        end
      end else begin
        rh_cyc = rh_cyc + 1;
        for (int e = 0; e < MshrNum; e++) begin
          if (mshr_q_valid[e] && (mshr_q[e].state == MSHR_RESP_HOLD)) begin
            rh_age[e] = rh_age[e] + 1;
            // Attribute this cycle's same-address traffic to the held entry.
            for (int t = 0; t < NumTilesPerGroup; t++) begin
              for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
                if (req_in_valid[t][p] && req_can_merge[t][p] &&
                    (req_len[t][p] == BurstLenWidth'(1)) &&
                    (mshr_q[e].base_addr    == req_addr_key[t][p]) &&
                    (mshr_q[e].tgt_group_id == req_in[t][p].tgt_group_id)) begin
                  if (req_in_ready[t][p] && req_out_valid[t][p] &&
                      (req_out[t][p].mshr_tag == '0)) begin
                    rh_byp[e] = rh_byp[e] + 1;      // LOST to the bypass path
                  end else if (!req_in_ready[t][p]) begin
                    rh_stl[e] = rh_stl[e] + 1;      // merely delayed
                  end
                end
              end
            end
            // One-shot report once the hold gets pathological.
            if ((rh_age[e] >= RespHoldProbe) && !rh_rep[e]) begin : rh_do_report
              automatic int bk    = e / MshrWaysPerBank;
              automatic int n_inv = 0, n_wait = 0, n_drain = 0, n_hold = 0, n_cach = 0;
              automatic int peers = 0;
              rh_rep[e] = 1'b1;
              rh_report_cnt = rh_report_cnt + 1;
              for (int w = 0; w < MshrWaysPerBank; w++) begin
                automatic int ee = bk * MshrWaysPerBank + w;
                if (!mshr_q_valid[ee]) n_inv = n_inv + 1;
                else case (mshr_q[ee].state)
                  MSHR_WAIT_RESP:  n_wait  = n_wait  + 1;
                  MSHR_DRAIN_RESP: n_drain = n_drain + 1;
                  MSHR_RESP_HOLD:  n_hold  = n_hold  + 1;
                  MSHR_CACHED:     n_cach  = n_cach  + 1;
                  default: ;
                endcase
              end
              for (int ee = 0; ee < MshrNum; ee++) begin
                if ((ee != e) && mshr_q_valid[ee] &&
                    (mshr_q[ee].base_addr    == mshr_q[e].base_addr) &&
                    (mshr_q[ee].tgt_group_id == mshr_q[e].tgt_group_id)) peers = peers + 1;
              end
              $display({"[RH STUCK] cyc=%0d g=%0d e=%0d bank=%0d addr=0x%0h tgt_g=%0d ",
                        "subs=%0d/%0d byp=%0d stl=%0d peers=%0d bank[inv=%0d wait=%0d drain=%0d hold=%0d cached=%0d]"},
                       rh_cyc, group_id_i, e, bk, mshr_q[e].base_addr, mshr_q[e].tgt_group_id,
                       mshr_q[e].sub_reqs_num, cfg_hold_subs_single,
                       rh_byp[e], rh_stl[e], peers,
                       n_inv, n_wait, n_drain, n_hold, n_cach);
              for (int s = 0; s < MshrMergeReqs; s++) begin
                if (mshr_q[e].sub_reqs[s].valid) begin
                  $display("[RH SUB  ] cyc=%0d g=%0d e=%0d s=%0d tile=%0d core=%0d meta=%0d",
                           rh_cyc, group_id_i, e, s, mshr_q[e].sub_reqs[s].tile_id,
                           mshr_q[e].sub_reqs[s].core_id, mshr_q[e].sub_reqs[s].meta_id_base);
                end
              end
            end
          end else begin
            rh_age[e] = 0; rh_byp[e] = 0; rh_stl[e] = 0; rh_rep[e] = 0;
          end
        end
        if ((StatsPeriod != 0) && ((rh_cyc % StatsPeriod) == 0) && (rh_report_cnt != 0)) begin
          $display("[RH] cyc=%0d g=%0d hold_episodes_reported=%0d", rh_cyc, group_id_i, rh_report_cnt);
        end
      end
    end
  end
`endif
  // pragma translate_on

  // ------------------------------------------------------------------------
  // Bypass-path delivery probe (simulation-only, group_mshr_bypass_probe).
  // Pairs every request forwarded to the NoC WITHOUT an MSHR entry (mshr_tag == 0)
  // against the bypass response later handed back to the tile, keyed on
  // {tile, core_id, meta_id}. A bypass response whose key has no outstanding
  // forward is an ORPHAN -- a response the core never asked for -- and is reported
  // the cycle it is delivered, i.e. BEFORE the core's own invalid_resp_id assertion
  // fires. Direct instrument for the 2026-07-30 cyc-23327 failure, where waveform
  // archaeology was needed just to learn the stray response came via resp_from_bypass.
  //   [BYP ORPHAN] : the anomaly, printed with full context.
  //   [BYP]        : periodic fwd/rsp/orphan counts (StatsPeriod, 0 = never).
  // Silent unless something is wrong, so it costs no transcript volume.
  //
  // Scope limits, chosen to avoid FALSE orphans rather than to be exhaustive:
  //  - single-beat traffic only. A multi-beat bypassed burst returns one response
  //    PER BEAT with meta = base+b, and under ParityDrain its core_id is retagged
  //    to core_id+(b&1), so those keys do not round-trip.
  //  - a response the retag table claims (bypass_match) is skipped, and so is any
  //    response to a tile that currently has a tracked bypass burst.
  // Counters are plain sim variables written with blocking assignments: a forward
  // and a response can touch the same key in the same cycle.
  // ------------------------------------------------------------------------
  // pragma translate_off
  // SIMULATION ONLY -- the bypass-orphan probe is [BYP ORPHAN] telemetry, including `integer bp_out_cnt [NumTilesPerGroup][BpCoreN][BpMetaN]`
  // -- an unpacked 16 x 8 x 8 array of integers, 32 kbit per group, plus longint counters.
  // It is enabled by a VALUE knob (group_mshr_bypass_probe), which both backend
  // configs set, so without this guard the probe is elaborated as real hardware.
`ifndef TARGET_SYNTHESIS
  if (BypassProbe) begin : gen_bypass_probe
    localparam int unsigned BpCoreN = 2**$bits(tile_core_id_t);
    localparam int unsigned BpMetaN = 2**$bits(meta_id_t);
    integer bp_out_cnt [NumTilesPerGroup][BpCoreN][BpMetaN];
    longint bp_cyc, bp_fwd, bp_rsp, bp_orphan;
    logic [NumTilesPerGroup-1:0] bp_tile_tracked;

    always_comb begin
      bp_tile_tracked = '0;
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int w = 0; w < BypassTrackWays; w++) begin
          if (bypass_track_q[t][w].valid) bp_tile_tracked[t] = 1'b1;
        end
      end
    end

    always @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        bp_cyc = 0; bp_fwd = 0; bp_rsp = 0; bp_orphan = 0;
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int c = 0; c < BpCoreN; c++) begin
            for (int m = 0; m < BpMetaN; m++) bp_out_cnt[t][c][m] = 0;
          end
        end
      end else begin
        bp_cyc = bp_cyc + 1;
        // (1) single-beat requests leaving the group without an entry.
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
            if (req_out_valid[t][p] && req_out_ready[t][p] &&
                (req_out[t][p].mshr_tag == '0) &&
                (req_len[t][p] == BurstLenWidth'(1))) begin
              bp_out_cnt[t][int'(req_out[t][p].wdata.core_id)]
                        [int'(req_out[t][p].wdata.meta_id)] += 1;
              bp_fwd = bp_fwd + 1;
            end
          end
        end
        // (2) bypass responses handed back to the tile.
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int p = 1; p < NumRemoteRespPortsPerTile; p++) begin
            if (resp_out_valid[t][p] && resp_out_ready[t][p] &&
                resp_from_bypass[t][p] && !bypass_match[t][p]) begin : bp_resp
              automatic int bc = int'(resp_out[t][p].rdata.core_id);
              automatic int bm = int'(resp_out[t][p].rdata.meta_id);
              bp_rsp = bp_rsp + 1;
              if (bp_out_cnt[t][bc][bm] > 0) begin
                bp_out_cnt[t][bc][bm] -= 1;
              end else if (!bp_tile_tracked[t]) begin
                bp_orphan = bp_orphan + 1;
                $display("[BYP ORPHAN] cyc=%0d g=%0d t=%0d p=%0d core=%0d meta=%0d wen=%0b : bypass response with no outstanding forward for this key",
                         bp_cyc, group_id_i, t, p, bc, bm, resp_out[t][p].wen);
              end
            end
          end
        end
        // (3) periodic summary.
        if ((StatsPeriod != 0) && ((bp_cyc % StatsPeriod) == 0)) begin
          $display("[BYP] cyc=%0d g=%0d fwd=%0d rsp=%0d orphan=%0d",
                   bp_cyc, group_id_i, bp_fwd, bp_rsp, bp_orphan);
        end
      end
    end
  end
`endif
  // pragma translate_on

  // ------------------------------------------------------------------------
  // Bank-full alloc bypass view (simulation-only). A request that WANTS an MSHR
  // entry (req_can_merge, a mergeable load) but is forwarded to the NoC without one
  // (req_out_valid, not a hit-merge, no alloc slot won). That combination is only
  // reachable when the request's bank has no free way: had a free way existed it
  // would have STALLed and retried (mempool_group_mshr.sv, the bank_has_free branch)
  // rather than bypassing. This is the per-request, per-cycle view of the
  // stat_req_mshr_overflow counter -- the "wanted an entry, bank full, bypassed"
  // event. NOT the same as sub_reqs-full (an entry exists but its requester list is
  // full); that is stat_req_subreq_overflow.
  //   req_bankfull_bypass_dbg[t][p] : high while such a bypass is presented on the
  //                                   tile's request lane.
  //   req_bankfull_bypass_cnt_dbg   : free-running count of ACCEPTED ones (fired
  //                                   handshake); take a cursor delta to scope it.
  // ------------------------------------------------------------------------
  // pragma translate_off
  // ^ THIS OPEN WAS MISSING. The block below is simulation-only (free-running debug
  //   counters, $display, and a `final` report) and is closed by the `// pragma translate_on`
  //   at the end of the `final` block -- but nothing ever opened the region, so all of it was
  //   visible to synthesis and lint. Spyglass Design_Read flagged exactly that:
  //     SYNTH_78  'final' construct is not synthesizable. Ignoring for synthesis
  //     WRN_74    translate_on specified without associated translate_off
  //   The `ifndef VERILATOR guards inside do NOT help here: a synthesis or lint tool does
  //   not define VERILATOR, so it sees the code regardless.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_bankfull_bypass_dbg;
  logic [31:0]                                               req_bankfull_bypass_cnt_dbg;
  logic [15:0]                                               req_bankfull_bypass_fire_cnt;

  always_comb begin
    req_bankfull_bypass_dbg      = '0;
    req_bankfull_bypass_fire_cnt = '0;
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
        if (req_in_valid[t][p] && req_can_merge[t][p] &&
            !req_merge_valid[t][p] && !req_alloc_found[t][p] &&
            req_out_valid[t][p]) begin
          req_bankfull_bypass_dbg[t][p] = 1'b1;
          if (req_in_ready[t][p]) begin
            req_bankfull_bypass_fire_cnt = req_bankfull_bypass_fire_cnt + 16'd1;
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) req_bankfull_bypass_cnt_dbg <= '0;
    else         req_bankfull_bypass_cnt_dbg <=
                     req_bankfull_bypass_cnt_dbg + 32'(req_bankfull_bypass_fire_cnt);
  end

  // ------------------------------------------------------------------------
  // Bank-concentration measurement (settles: is bank-full overflow caused by the
  // hash concentrating a temporal batch into few banks, or by genuine aggregate
  // fullness?). At each bank-full-bypass event, sample how many OTHER banks could
  // have accepted the request (bank_has_free popcount) -- the count of banks the
  // request's own address-pinned bank prevented it from using.
  //   bfb_free_banks_sum : running sum of free-bank-count over all events; the
  //                        AVERAGE (sum / req_bankfull_bypass_cnt_dbg) is the
  //                        headline number. High avg (many banks free at overflow)
  //                        => concentration => a better hash helps. ~0 => aggregate
  //                        full => only more ways/entries help.
  //   bfb_alias_events   : events with >= half the banks free (clear "could have
  //                        been placed elsewhere" cases).
  //   bfb_full_events    : events with ZERO other banks free (genuine aggregate full).
  // Free-running from reset (take a cursor delta to scope to the kernel).
  // ------------------------------------------------------------------------
  logic [BankIdW:0] bfb_free_banks_now;   // 0..MshrBankNum
  logic [47:0]      bfb_free_banks_sum;
  logic [31:0]      bfb_alias_events;
  logic [31:0]      bfb_full_events;
  always_comb begin
    bfb_free_banks_now = '0;
    for (int b = 0; b < MshrBankNum; b++) begin
      if (bank_has_free[b]) bfb_free_banks_now = bfb_free_banks_now + 1'b1;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bfb_free_banks_sum <= '0;
      bfb_alias_events   <= '0;
      bfb_full_events    <= '0;
    end else if (req_bankfull_bypass_fire_cnt != '0) begin
      bfb_free_banks_sum <= bfb_free_banks_sum +
                            48'(req_bankfull_bypass_fire_cnt) * 48'(bfb_free_banks_now);
      if ((bfb_free_banks_now * 2) >= (BankIdW+1)'(MshrBankNum)) begin
        bfb_alias_events <= bfb_alias_events + 32'(req_bankfull_bypass_fire_cnt);
      end
      if (bfb_free_banks_now == '0) begin
        bfb_full_events <= bfb_full_events + 32'(req_bankfull_bypass_fire_cnt);
      end
    end
  end
`ifndef VERILATOR
  // Address-capture probe (BankHashDump): dump the merge key + target group + current-hash bank
  // of bank-full-bypass events in ONE group (group 0), up to a cap, so the actual colliding
  // address set can be analyzed offline and a hash designed against real data. Gated to
  // +GROUP_MSHR_BANK_DUMP to keep it off by default.
`ifdef GROUP_MSHR_BANK_DUMP
  int unsigned bank_dump_cnt;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) bank_dump_cnt <= 0;
    else if ((group_id_i == '0) && (bank_dump_cnt < 4000)) begin
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
          if (req_bankfull_bypass_dbg[t][p] && req_in_ready[t][p] && (bank_dump_cnt < 4000)) begin
            $display("[BFBADDR] t=%0t key=%0h tgtgrp=%0d bank0=%0d",
                     $time, req_addr_key[t][p], req_in[t][p].tgt_group_id, req_bank[t][p]);
            bank_dump_cnt <= bank_dump_cnt + 1;
          end
        end
      end
    end
  end
`endif
  final begin
    if (req_bankfull_bypass_cnt_dbg != 0) begin
      $display("[BFBHASH] %m bankfull_bypass=%0d avg_free_banks_x1000=%0d alias_events=%0d full_events=%0d (banks=%0d)",
               req_bankfull_bypass_cnt_dbg,
               (bfb_free_banks_sum * 48'd1000) / 48'(req_bankfull_bypass_cnt_dbg),
               bfb_alias_events, bfb_full_events, MshrBankNum);
    end
  end
`endif
  // pragma translate_on

  // Debug-only view of cached/uncached valid entries.
  // pragma translate_off
  `ifndef VERILATOR
  // Verbose MSHR debug tracer ([E16D]/[T5*]/[GMA] lines) — SILENT by default.
  // Recompile with +define+GROUP_MSHR_DEBUG_TRACE to re-enable when debugging.
  `ifdef GROUP_MSHR_DEBUG_TRACE
  logic [MshrNum-1:0] mshr_q_valid_cached;
  logic [MshrNum-1:0] mshr_q_valid_uncached;
  generate
    for (genvar mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin : gen_mshr_valid_types
      assign mshr_q_valid_cached[mshr_i] =
          mshr_q_valid[mshr_i] &&
          EnableRespCache &&
          (mshr_q[mshr_i].state == MSHR_CACHED) &&
          (mshr_q[mshr_i].resp_buf_cnt != '0);
      assign mshr_q_valid_uncached[mshr_i] =
          mshr_q_valid[mshr_i] &&
          (!EnableRespCache ||
           (mshr_q[mshr_i].state != MSHR_CACHED) ||
           !(mshr_q[mshr_i].resp_buf_cnt != '0));
    end
  endgenerate

  // ---- DEBUG: focused trace of entry 16 in group 12 (where hart 0xc5 stuck) ----
  // Dumps a [E16D] line on every cycle where entry 16's mshr_q state, valid bits,
  // sub_reqs_num, beat_pending, or sub_reqs[*].valid changes. Filter by group 12
  // (hart 0xc5 lives in (gx=3, gy=0) → group_id = 12) by checking group_id_i.
  // Also dumps [E16D-EVT] one-shot events for alloc / merge / drain handshake /
  // response capture / cache transition / full reset for entry 16.
  logic [255:0] e16_prev_sig;
  logic [255:0] e16_curr_sig;
  always_comb begin
    e16_curr_sig = '0;
    e16_curr_sig[2:0]   = mshr_q[16].state;
    e16_curr_sig[3]     = mshr_q_valid[16];
    e16_curr_sig[11:4]  = mshr_q[16].sub_reqs_num;
    e16_curr_sig[19:12] = mshr_q[16].beat_pending[7:0];
    e16_curr_sig[27:20] = {mshr_q[16].sub_reqs[7].valid,
                            mshr_q[16].sub_reqs[6].valid,
                            mshr_q[16].sub_reqs[5].valid,
                            mshr_q[16].sub_reqs[4].valid,
                            mshr_q[16].sub_reqs[3].valid,
                            mshr_q[16].sub_reqs[2].valid,
                            mshr_q[16].sub_reqs[1].valid,
                            mshr_q[16].sub_reqs[0].valid};
    e16_curr_sig[35:28] = 8'(mshr_q[16].resp_buf_cnt); // zero-extend (width varies by config)
    e16_curr_sig[36]    = (mshr_q[16].resp_buf_cnt != '0);
    e16_curr_sig[40:37] = mshr_q[16].beats_left[3:0];
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni && (group_id_i == 4'd12) && 1'b1) begin
      // ---- T5/p1 contention trace: log all entries with sub_req at t5/p1 ----
      // Fires once per cycle per matching entry to show drain competition.
      for (int unsigned ei = 0; ei < MshrNum; ei++) begin
        if (mshr_q_valid[ei] && (mshr_q[ei].state == MSHR_DRAIN_RESP)) begin
          for (int unsigned si = 0; si < MshrMergeReqs; si++) begin
            if (mshr_q[ei].sub_reqs[si].valid &&
                mshr_q[ei].beat_pending[si] &&
                (mshr_q[ei].sub_reqs[si].tile_id == 5) &&
                (mshr_q[ei].sub_reqs[si].port_id == 1)) begin
              $display("[T5C %0t] g=12 e=%0d s%0d=t5/p1/c%0d/m%0h bp_pending sub_n=%0d resp_buf_cnt=%0d",
                       $time, ei, si,
                       mshr_q[ei].sub_reqs[si].core_id,
                       mshr_q[ei].sub_reqs[si].meta_id_base,
                       mshr_q[ei].sub_reqs_num,
                       mshr_q[ei].resp_buf_cnt);
            end
          end
        end
      end
      // T5 handshakes (req_in, req_out, resp_in, resp_out)
      for (int unsigned p = 1; p < NumRemoteReqPortsPerTile; p++) begin
        if (group_mshr_req_valid_i[5][p] && group_mshr_req_ready_o[5][p]) begin
          $display("[T5 %0t] g=12 t5 REQ_IN p=%0d core=%0d meta=%0h wen=%b",
                   $time, p, group_mshr_req_i[5][p].wdata.core_id,
                   group_mshr_req_i[5][p].wdata.meta_id, group_mshr_req_i[5][p].wen);
        end
      end
      // T5SEL: drain selection for (tile=5, port=1 or 2). Show which mshr/subreq selected.
      for (int unsigned p = 1; p < NumRemoteRespPortsPerTile; p++) begin
        if (resp_sel_valid[5][p]) begin
          $display("[T5SEL %0t] g=12 t5 p=%0d sel_mshr=%0d sel_subreq=%0d",
                   $time, p, resp_sel_mshr_id[5][p], resp_sel_subreq_idx[5][p]);
        end
        // T5BP: log bp/valid for each MSHR with matching tile=5 sub_req at posedge
        for (int unsigned ei = 0; ei < MshrNum; ei++) begin
          if (mshr_d_valid[ei] && (mshr_d[ei].state == MSHR_DRAIN_RESP)) begin
            for (int unsigned si = 0; si < MshrMergeReqs; si++) begin
              if (mshr_d[ei].sub_reqs[si].valid &&
                  (mshr_d[ei].sub_reqs[si].tile_id == 5) &&
                  (mshr_d[ei].sub_reqs[si].port_id == p)) begin
                $display("[T5BP %0t] g=12 t5 e=%0d s%0d=t5/p%0d/c%0d/m%0h bp(d)=%b state(d)=%0d",
                         $time, ei, si, p,
                         mshr_d[ei].sub_reqs[si].core_id,
                         mshr_d[ei].sub_reqs[si].meta_id_base,
                         mshr_d[ei].beat_pending[si],
                         mshr_d[ei].state);
              end
            end
          end
        end
      end
      for (int unsigned p = 1; p < NumRemoteRespPortsPerTile; p++) begin
        // Log valid alone (no handshake needed) to see backpressure.
        if (group_mshr_resp_valid_o[5][p]) begin
          $display("[T5V %0t] g=12 t5 RESP_VLD p=%0d core=%0d meta=%0h ready=%b",
                   $time, p, group_mshr_resp_o[5][p].rdata.core_id,
                   group_mshr_resp_o[5][p].rdata.meta_id,
                   group_mshr_resp_ready_i[5][p]);
        end
        if (group_mshr_resp_valid_o[5][p] && group_mshr_resp_ready_i[5][p]) begin
          $display("[T5 %0t] g=12 t5 RESP_OUT p=%0d core=%0d meta=%0h data=0x%0h wen=%b",
                   $time, p, group_mshr_resp_o[5][p].rdata.core_id,
                   group_mshr_resp_o[5][p].rdata.meta_id,
                   group_mshr_resp_o[5][p].rdata.data,
                   group_mshr_resp_o[5][p].wen);
        end
      end
      e16_prev_sig <= e16_curr_sig;
      // Also dump ALLOC events (entry 16 transitions IDLE→WAIT_RESP)
      if (mshr_d_valid[16] && !mshr_q_valid[16]) begin
        $display("[E16D-EVT %0t] g=%0d ALLOC entry 16, base_addr=0x%0h, sub_reqs_num(d)=%0d, sub_req[0].tile=%0d port=%0d core=%0d meta=%0h",
                 $time, group_id_i,
                 mshr_d[16].base_addr, mshr_d[16].sub_reqs_num,
                 mshr_d[16].sub_reqs[0].tile_id, mshr_d[16].sub_reqs[0].port_id,
                 mshr_d[16].sub_reqs[0].core_id, mshr_d[16].sub_reqs[0].meta_id_base);
      end
      // Dump full reset (deallocation)
      if (!mshr_d_valid[16] && mshr_q_valid[16]) begin
        $display("[E16D-EVT %0t] g=%0d DEALLOC entry 16 (was state=%0d, sub_reqs_num=%0d)",
                 $time, group_id_i, mshr_q[16].state, mshr_q[16].sub_reqs_num);
      end
      // ---- Wide event log: ALL entries ALLOC/DEALLOC/MERGE in g=12 ----
      for (int unsigned ei = 0; ei < MshrNum; ei++) begin
        // ALLOC: full sub_req[0..7] dump
        // REUSE: mshr_d_valid stays 1 but base_addr or burst_len changed → CACHED slot got reused
        if (mshr_d_valid[ei] && mshr_q_valid[ei] &&
            ((mshr_d[ei].base_addr != mshr_q[ei].base_addr) ||
             (mshr_d[ei].burst_len != mshr_q[ei].burst_len))) begin
          $display("[GMA %0t] g=%0d REUSE e=%0d old_base=0x%0h old_burst=%0d new_base=0x%0h new_burst=%0d new_s0=t%0d/p%0d/c%0d/m%0h",
                   $time, group_id_i, ei, mshr_q[ei].base_addr, mshr_q[ei].burst_len,
                   mshr_d[ei].base_addr, mshr_d[ei].burst_len,
                   mshr_d[ei].sub_reqs[0].tile_id, mshr_d[ei].sub_reqs[0].port_id,
                   mshr_d[ei].sub_reqs[0].core_id, mshr_d[ei].sub_reqs[0].meta_id_base);
        end
        if (mshr_d_valid[ei] && !mshr_q_valid[ei]) begin
          $display("[GMA %0t] g=%0d ALLOC e=%0d base=0x%0h burst=%0d sub_n=%0d s0=t%0d/p%0d/c%0d/m%0h v0=%b s1=t%0d/p%0d/c%0d/m%0h v1=%b s2=t%0d/p%0d/c%0d/m%0h v2=%b s3=t%0d/p%0d/c%0d/m%0h v3=%b s4=t%0d/p%0d/c%0d/m%0h v4=%b s5=t%0d/p%0d/c%0d/m%0h v5=%b s6=t%0d/p%0d/c%0d/m%0h v6=%b s7=t%0d/p%0d/c%0d/m%0h v7=%b",
                   $time, group_id_i, ei, mshr_d[ei].base_addr, mshr_d[ei].burst_len, mshr_d[ei].sub_reqs_num,
                   mshr_d[ei].sub_reqs[0].tile_id, mshr_d[ei].sub_reqs[0].port_id, mshr_d[ei].sub_reqs[0].core_id, mshr_d[ei].sub_reqs[0].meta_id_base, mshr_d[ei].sub_reqs[0].valid,
                   mshr_d[ei].sub_reqs[1].tile_id, mshr_d[ei].sub_reqs[1].port_id, mshr_d[ei].sub_reqs[1].core_id, mshr_d[ei].sub_reqs[1].meta_id_base, mshr_d[ei].sub_reqs[1].valid,
                   mshr_d[ei].sub_reqs[2].tile_id, mshr_d[ei].sub_reqs[2].port_id, mshr_d[ei].sub_reqs[2].core_id, mshr_d[ei].sub_reqs[2].meta_id_base, mshr_d[ei].sub_reqs[2].valid,
                   mshr_d[ei].sub_reqs[3].tile_id, mshr_d[ei].sub_reqs[3].port_id, mshr_d[ei].sub_reqs[3].core_id, mshr_d[ei].sub_reqs[3].meta_id_base, mshr_d[ei].sub_reqs[3].valid,
                   mshr_d[ei].sub_reqs[4].tile_id, mshr_d[ei].sub_reqs[4].port_id, mshr_d[ei].sub_reqs[4].core_id, mshr_d[ei].sub_reqs[4].meta_id_base, mshr_d[ei].sub_reqs[4].valid,
                   mshr_d[ei].sub_reqs[5].tile_id, mshr_d[ei].sub_reqs[5].port_id, mshr_d[ei].sub_reqs[5].core_id, mshr_d[ei].sub_reqs[5].meta_id_base, mshr_d[ei].sub_reqs[5].valid,
                   mshr_d[ei].sub_reqs[6].tile_id, mshr_d[ei].sub_reqs[6].port_id, mshr_d[ei].sub_reqs[6].core_id, mshr_d[ei].sub_reqs[6].meta_id_base, mshr_d[ei].sub_reqs[6].valid,
                   mshr_d[ei].sub_reqs[7].tile_id, mshr_d[ei].sub_reqs[7].port_id, mshr_d[ei].sub_reqs[7].core_id, mshr_d[ei].sub_reqs[7].meta_id_base, mshr_d[ei].sub_reqs[7].valid);
        end
        // DEALLOC
        if (!mshr_d_valid[ei] && mshr_q_valid[ei]) begin
          $display("[GMA %0t] g=%0d DEALLOC e=%0d state=%0d burst=%0d sub_n=%0d bpend=%h subv=%b%b%b%b%b%b%b%b cnt=%0d bl=%0d s0=t%0d/p%0d/c%0d/m%0h s1=t%0d/p%0d/c%0d/m%0h",
                   $time, group_id_i, ei, mshr_q[ei].state, mshr_q[ei].burst_len,
                   mshr_q[ei].sub_reqs_num, mshr_q[ei].beat_pending,
                   mshr_q[ei].sub_reqs[7].valid, mshr_q[ei].sub_reqs[6].valid,
                   mshr_q[ei].sub_reqs[5].valid, mshr_q[ei].sub_reqs[4].valid,
                   mshr_q[ei].sub_reqs[3].valid, mshr_q[ei].sub_reqs[2].valid,
                   mshr_q[ei].sub_reqs[1].valid, mshr_q[ei].sub_reqs[0].valid,
                   mshr_q[ei].resp_buf_cnt, mshr_q[ei].beats_left,
                   mshr_q[ei].sub_reqs[0].tile_id, mshr_q[ei].sub_reqs[0].port_id, mshr_q[ei].sub_reqs[0].core_id, mshr_q[ei].sub_reqs[0].meta_id_base,
                   mshr_q[ei].sub_reqs[1].tile_id, mshr_q[ei].sub_reqs[1].port_id, mshr_q[ei].sub_reqs[1].core_id, mshr_q[ei].sub_reqs[1].meta_id_base);
        end
        // MERGE: any sub_req that goes from invalid to valid while entry stays valid
        if (mshr_d_valid[ei] && mshr_q_valid[ei]) begin
          for (int unsigned si = 0; si < MshrMergeReqs; si++) begin
            if (mshr_d[ei].sub_reqs[si].valid && !mshr_q[ei].sub_reqs[si].valid) begin
              $display("[GMA %0t] g=%0d MERGE e=%0d s%0d=t%0d/p%0d/c%0d/m%0h sub_n=%0d bpend=%h",
                       $time, group_id_i, ei, si,
                       mshr_d[ei].sub_reqs[si].tile_id, mshr_d[ei].sub_reqs[si].port_id,
                       mshr_d[ei].sub_reqs[si].core_id, mshr_d[ei].sub_reqs[si].meta_id_base,
                       mshr_d[ei].sub_reqs_num, mshr_d[ei].beat_pending);
            end
            // DRAIN: sub_req valid 1→0 while entry stays allocated → log who got cleared
            if (!mshr_d[ei].sub_reqs[si].valid && mshr_q[ei].sub_reqs[si].valid) begin
              $display("[GMA %0t] g=%0d DRAIN e=%0d s%0d=t%0d/p%0d/c%0d/m%0h sub_n(d)=%0d bl(d)=%0d state(d)=%0d bpq[s]=%b bpd[s]=%b",
                       $time, group_id_i, ei, si,
                       mshr_q[ei].sub_reqs[si].tile_id, mshr_q[ei].sub_reqs[si].port_id,
                       mshr_q[ei].sub_reqs[si].core_id, mshr_q[ei].sub_reqs[si].meta_id_base,
                       mshr_d[ei].sub_reqs_num, mshr_d[ei].beats_left, mshr_d[ei].state,
                       mshr_q[ei].beat_pending[si], mshr_d[ei].beat_pending[si]);
            end
            // BP_SET: beat_pending[s] transitioned 0→1 (init block fired and set it)
            if (mshr_d[ei].beat_pending[si] && !mshr_q[ei].beat_pending[si]) begin
              $display("[GMA %0t] g=%0d BPSET e=%0d s%0d=t%0d/p%0d/c%0d/m%0h subv(q)=%b%b%b%b%b%b%b%b state(q)=%0d state(d)=%0d",
                       $time, group_id_i, ei, si,
                       mshr_d[ei].sub_reqs[si].tile_id, mshr_d[ei].sub_reqs[si].port_id,
                       mshr_d[ei].sub_reqs[si].core_id, mshr_d[ei].sub_reqs[si].meta_id_base,
                       mshr_q[ei].sub_reqs[7].valid, mshr_q[ei].sub_reqs[6].valid,
                       mshr_q[ei].sub_reqs[5].valid, mshr_q[ei].sub_reqs[4].valid,
                       mshr_q[ei].sub_reqs[3].valid, mshr_q[ei].sub_reqs[2].valid,
                       mshr_q[ei].sub_reqs[1].valid, mshr_q[ei].sub_reqs[0].valid,
                       mshr_q[ei].state, mshr_d[ei].state);
            end
            // BP_CLR: beat_pending[s] transitioned 1→0 while sub_req still valid → drain handshake
            if (!mshr_d[ei].beat_pending[si] && mshr_q[ei].beat_pending[si] && mshr_d[ei].sub_reqs[si].valid) begin
              $display("[GMA %0t] g=%0d BPCLR e=%0d s%0d=t%0d/p%0d/c%0d/m%0h handshake_completed",
                       $time, group_id_i, ei, si,
                       mshr_d[ei].sub_reqs[si].tile_id, mshr_d[ei].sub_reqs[si].port_id,
                       mshr_d[ei].sub_reqs[si].core_id, mshr_d[ei].sub_reqs[si].meta_id_base);
            end
          end
        end
      end
    end
  end
  `endif // GROUP_MSHR_DEBUG_TRACE
  `endif
  // pragma translate_on

  // Main combinational control: request merge/alloc, response capture, and drain
`ifndef TARGET_SYNTHESIS
  // Duplicate-response-beat detection. The CHECK stays combinational (it must see the
  // within-cycle accumulation of beat_seen across tiles/ports), but the REPORT must not
  // be: an always_comb re-evaluates as its inputs settle, and $fatal is not
  // glitch-tolerant, so reporting inline fires on transient intermediate values of
  // resp_capture_fire / resp_mshr_id / resp_capture_beat_offset. VCS and QuestaSim
  // schedule those evaluations differently, which is why the inline $fatal killed every
  // VCS run (cyc 101860 verify-on, 32199 no-verify) while QuestaSim ran the identical
  // RTL past the same point reporting no violation. Sampling at the clock edge sees
  // only settled values, so a real duplicate still fires and a glitch does not.
  logic        dup_beat_detected;
  int unsigned dup_beat_mshr, dup_beat_beat, dup_beat_meta;
`endif

  // -------------------------------------------------------------------------------------------
  // Loop temporaries for the three drain / response-select arbiters inside the always_comb below,
  // at module scope rather than as procedural `automatic`s. Each is written before it is read on
  // every unrolled iteration, so the hardware is unchanged -- but they are now visible in a
  // waveform, and in the form the backend flow expects.
  //
  // Three sets because the arbiters sit in mutually exclusive branches of ONE always_comb and
  // previously relied on `automatic` scoping to reuse the names `drain_base`/`subreq_base`.
  // At module scope that would alias, so each branch gets its own.
  //   A = DrainMultiPort priority-encoder path   B = PD2 second-beat path   C = single-port path
  // A5: natural width, unsigned. These were 32-bit signed `int`, which made every wrap a signed
  // 32-bit modulo and every array index a signed part-select (the VER-318 flood). All values are
  // provably in [0, MshrNum) / [0, MshrMergeReqs), and both moduli are guarded power-of-two above,
  // so truncation to idx_width bits is exactly the old `%`.
  logic [MshrIdxW-1:0]      drain_sel_base;
  logic [SubIdxW-1:0]       drain_sel_sub_base;                    // A: rotation bases
  logic [MshrNum-1:0]       drain_ent_cand;                        // A: entries offering a beat
  // B0.3: bank-narrowed selector. With BankPublish on, at most one entry per bank is selectable,
  // so the arbitration runs over MshrBankNum candidates instead of MshrNum.
  logic [MshrBankNum-1:0][MshrIdxW-1:0] bank_pub_e;    // published entry id per bank (port-indep.)
  logic [MshrBankNum-1:0]   bank_cand, bank_cand_rot, bank_cand_eff, bank_pfx, bank_first;
  logic [BankIdW-1:0]       bank_base, bank_idx, bank_win_d, bank_win;
  logic [VictimPtrW-1:0]    base_way;
  logic                     bank_demote;
  logic [MshrMergeReqs-1:0] drain_sub_cand;                        // A: sub-reqs in the winner
  // PPA hoist: the (tile,port)-independent half of the drain eligibility test, computed once per
  // (entry, sub-request) instead of once per (entry, sub-request, tile, port). Packed arrays at
  // module scope so they stay visible in the waveform and outside the always_comb.
  // The view both drain scans see: mshr_q when DrainFromQ, else mshr_d. Elaboration-constant
  // select, so only one arm is built.
  mempool_group_mshr_t [MshrNum-1:0]                          drain_scan_ent;
  logic [MshrNum-1:0]                                         drain_scan_valid;
  // opt3 stage-1: per-bank round-robin publish. bank_rr_q advances one way per cycle per bank.
  logic [MshrNum-1:0]                                         drain_published;
  logic [MshrNum-1:0]                                         drain_ent_any;
  logic [MshrNum-1:0]                                         drain_ent_ok;
  logic [MshrNum-1:0][MshrMergeReqs-1:0]                      drain_sub_ready;
  tile_group_id_t [MshrNum-1:0][MshrMergeReqs-1:0]            drain_sub_tile;
  logic [MshrNum-1:0][MshrMergeReqs-1:0][RespPortIdW-1:0]     drain_sub_port;
  // ParityDrain second-slot equivalents. drain2_sub_port is indexed by ENTRY only: both beats of an
  // entry share one parity port, so it does not vary per sub-request.
  logic [MshrNum-1:0]                                         drain2_ent_ok;
  logic [MshrNum-1:0][MshrMergeReqs-1:0]                      drain2_sub_ready;
  tile_group_id_t [MshrNum-1:0][MshrMergeReqs-1:0]            drain2_sub_tile;
  logic [MshrNum-1:0][RespPortIdW-1:0]                        drain2_sub_port;
  logic [MshrIdxW-1:0]      drain_win_e;
  logic [SubIdxW-1:0]       drain_win_s;
  logic                     drain_have_e,    drain_have_s;
  logic [SubIdxW-1:0]       drain_scan_s;                          // A: rotated scan index
  logic [MshrNum-1:0]       drain_cand_rot;                        // A: candidates rotated to base
  logic [MshrNum-1:0]       drain_pfx, drain_first;                // A: prefix-OR, isolated LSB
  logic [MshrIdxW-1:0]      drain_idx;                             // A: index within the rotation
  logic [MshrNum-1:0]       drain2_cand;                           // A: 2nd-slot entry candidates
  logic [MshrNum-1:0]       drain2_first;                          // one-hot winner, ABSOLUTE index
  // B1: mask + LSB-isolate, the allocator's form (:1762-1777). Replaces the variable barrel rotate
  // plus log2(MshrNum)-step prefix-OR. Same winner -- first candidate at-or-after the base, wrapping
  // -- but with no variable shifter and no prefix network, and the result is already in absolute
  // index space so the `base + idx` add disappears too.
  //
  // This is the arbiter that still matters: the head-beat MshrNum-wide selector is the else-arm of
  // `if (BankPublish)` and folds away at the shipping default, whereas drain2 is ungated and runs
  // MshrNum-wide in every config, x NumTilesPerGroup x (ports-1) instances.
  logic [MshrNum-1:0]       drain2_rr_mask;                        // 1 = entry is at/above the base
  logic [MshrNum-1:0]       drain2_hi, drain2_lo;
  logic [MshrIdxW-1:0]      drain2_idx;                            // A: index within the rotation
  logic [MshrIdxW-1:0]      drain2_base, drain2_mshr_i;            // B
  logic [SubIdxW-1:0]       drain2_sub_base, drain2_s;             // B

  always_comb begin
    int unsigned merge_new_idx;
    // Defaults
    mshr_d      = mshr_q;
    // Clock-gate write flags. Set on the same line as the write they describe (see the entry
    // register block), never from a restatement of the write's condition.
    mshr_wr_all = '0;
    mshr_id_we  = '0;
    mshr_rb_we  = '0;
    // One-cycle pulses; set only at the two response-side death sites below.
    // Guarded because the DECLARATIONS live in a `pragma translate_off` region: unguarded, these
    // reference undefined symbols under synthesis and the module does not analyze at all.
`ifndef TARGET_SYNTHESIS
    mshr_resp_hold_timeout_dbg = '0;
    mshr_cache_timeout_dbg     = '0;
`endif
`ifndef TARGET_SYNTHESIS
    dup_beat_detected = 1'b0;
    dup_beat_mshr = 0; dup_beat_beat = 0; dup_beat_meta = 0;
`endif
    mshr_d_valid = mshr_q_valid;
    victim_rr_d = victim_rr_q;

    // Hold-the-fetch: count down every held (allocated, fetch not yet sent) entry. Placed on the
    // _q view before this cycle's allocations overwrite their entries, so a fresh alloc keeps its
    // full window. The countdown never stalls -> a held fetch always releases within its (per-type)
    // window (deadlock-free by construction).
    if (HoldWindowMax != 0) begin
      for (int e = 0; e < MshrNum; e++) begin
        if (mshr_q_valid[e] && (mshr_q[e].state == MSHR_WAIT_RESP) && !mshr_q[e].issued &&
            (mshr_q[e].hold_cnt != '0) && hold_tick[e]) begin
          mshr_d[e].hold_cnt = mshr_q[e].hold_cnt - HoldCntW'(1);
        end
      end
    end

    req_out = req_in;
    req_out_valid = '0;
    req_in_ready = '1;

    resp_out = '0;
    resp_out_valid = '0;
    resp_from_mshr = '0;
    resp_from_bypass = '0;
`ifndef TARGET_SYNTHESIS
    resp_mshr_id_dbg = '0;
`endif
    resp_in_ready = '1;
    mshr_resp_inflight = '0;

    // C1: rank each merging port against the earlier ports targeting the same entry. Built as a
    // mask + population count rather than an accumulate-in-a-loop, so it maps to an adder tree
    // instead of reintroducing the 32-deep serial chain this change exists to remove.
    // OneMergePerBank: the arbiter grants at most one merge per bank, and an entry belongs to
    // exactly one bank, so no two granted lanes can target the same entry and the rank is
    // identically zero. The mask/popcount network below is then dead and, because the knob is an
    // elaboration constant, is removed rather than merely left unused.
    if (OneMergePerBank) begin
      merge_same_mask = '0;
      merge_rank_raw  = '0;
      merge_rank      = '0;
    end else begin
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
          merge_same_mask = '0;
          for (int t2 = 0; t2 < NumTilesPerGroup; t2++) begin
            for (int p2 = 1; p2 < NumRemoteReqPortsPerTile; p2++) begin
              if (((t2 < t) || ((t2 == t) && (p2 < p))) &&
                  req_merge_valid[t2][p2] && req_merge_ready[t2][p2] &&
                  (req_merge_mshr_id[t2][p2] == req_merge_mshr_id[t][p])) begin
                merge_same_mask[t2 * NumReqPortsActive + (p2 - 1)] = 1'b1;
              end
            end
          end
          // Saturate rather than truncate -- see MergeRankW above for why this is exact.
          merge_rank_raw   = MergeCountW'($countones(merge_same_mask));
          merge_rank[t][p] = (merge_rank_raw >= MergeCountW'(MshrMergeReqs)) ?
                             MergeRankW'(MshrMergeReqs) : MergeRankW'(merge_rank_raw);
        end
      end
    end

    stb_hit = '0;
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int pp = 1; pp < NumRemoteReqPortsPerTile; pp++) begin
        stb_be[t * NumReqPortsActiveF3 + (pp - 1)] = req_in[t][pp].be;
        stb_wd[t * NumReqPortsActiveF3 + (pp - 1)] = req_in[t][pp].wdata.data;
      end
    end

    // ------------------------------------------------------------
    // Request path: merge loads, allocate MSHR, or bypass to NoC
    // ------------------------------------------------------------
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        if (req_in_valid[tile_i][port_i]) begin
          // Tier-b: default tag 0 (= no MSHR entry / bypass); overwritten with (entry id + 1) on alloc.
          req_out[tile_i][port_i].mshr_tag = '0;
          if (req_in[tile_i][port_i].wdata.amo != '0) begin
            req_out[tile_i][port_i].burst_len = BurstLenWidth'(1);
          end
          if (req_merge_valid[tile_i][port_i]) begin
            // Merge hit: accept without touching NoC.
            // C1: slot and capacity come from the REGISTERED count plus this port's rank, not from
            // the value earlier ports left in mshr_d.
            merge_slot = mshr_q[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num +
                         merge_rank[tile_i][port_i];
            req_in_ready[tile_i][port_i] =
                req_merge_ready[tile_i][port_i] &&
                ((merge_slot + MergeRankW'(1)) <= MergeRankW'(MshrMergeReqs));
            if (req_in_ready[tile_i][port_i]) begin
              if ((merge_slot + MergeRankW'(1)) <= MergeRankW'(MshrMergeReqs)) begin
`ifndef TARGET_SYNTHESIS
                if (EnableRespCache &&
                    (mshr_q[req_merge_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].cache_hit_cnt =
                      mshr_d[req_merge_mshr_id[tile_i][port_i]].cache_hit_cnt + 1'b1;
                end
`endif
                merge_new_idx = merge_slot;
                mshr_id_we[req_merge_mshr_id[tile_i][port_i]] = 1'b1;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].valid = 1'b1;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].tile_id = tile_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].port_id = port_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].core_id =
                    req_in[tile_i][port_i].wdata.core_id;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].meta_id_base =
                    req_in[tile_i][port_i].wdata.meta_id;
                // Ports are visited in increasing order, so the LAST accepted port -- the one with the
                // highest rank -- writes the correct final count. No separate accumulator needed.
                // Guarded by the capacity check above, so this always fits SubReqCountW.
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num =
                    SubReqCountW'(merge_slot + MergeRankW'(1));
                // Cache self-invalidate: count this merged sub-request toward the sharing target.
                mshr_d[req_merge_mshr_id[tile_i][port_i]].served_cnt =
                    mshr_q[req_merge_mshr_id[tile_i][port_i]].served_cnt +
                    ServedCntW'(merge_rank[tile_i][port_i]) + ServedCntW'(1);
                if (EnableRespCache &&
                    (mshr_q[req_merge_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].state = MSHR_DRAIN_RESP;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beats_left = BurstLenWidth'(1);
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_pending = '0;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_pending2 = '0;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat2_armed = 1'b0;
`ifndef TARGET_SYNTHESIS
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_seen = '0;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_seen[0] = 1'b1;
`endif
`ifndef TARGET_SYNTHESIS
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_done = '0;
`endif
                end else if (
                    RespWaitSubsSingle &&
                    (mshr_q[req_merge_mshr_id[tile_i][port_i]].state == MSHR_RESP_HOLD) &&
                    ((merge_slot + MergeRankW'(1)) >=
                     SubReqCountW'(cfg_hold_subs_single))) begin
                  // The merge that landed this cycle reached the response-release target.
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].state = MSHR_DRAIN_RESP;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beats_left = BurstLenWidth'(1);
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_pending = '0;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_pending2 = '0;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat2_armed = 1'b0;
`ifndef TARGET_SYNTHESIS
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_seen = '0;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_seen[0] = 1'b1;
`endif
`ifndef TARGET_SYNTHESIS
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_done = '0;
`endif
                end
              end
            end
          end else begin
            // Not a merge into a resident entry: decide STALL / ALLOCATE / BYPASS.
            if (req_can_merge[tile_i][port_i] &&
                (req_addr_hit_drain[tile_i][port_i] || req_meta_conflict[tile_i][port_i])) begin
              // A same-address entry is draining, or a meta-id range conflict exists: wait for it.
              req_in_ready[tile_i][port_i]  = 1'b0;
              req_out_valid[tile_i][port_i] = 1'b0;
            end else if (req_can_merge[tile_i][port_i] && !req_alloc_found[tile_i][port_i] &&
                         (bank_has_free[req_bank[tile_i][port_i]] || cfg_bankfull_bp)) begin
              // Mergeable miss that lost this bank's single allocation slot this cycle, but a free way
              // exists: STALL and retry. Next cycle it either wins the slot or HIT-merges the entry the
              // winner just created (same address) -> full coalescing preserved, no extra entry, no
              // bypass. This is the stall-and-merge half of the per-bank single-alloc scheme.
              //
              // cfg_bankfull_bp extends the SAME stall to a genuinely FULL bank, where the legacy
              // policy bypasses. A bypass splits the cohort: part of a round leaves without an
              // MSHR tag, the bank frees, and a later member allocates a fresh entry whose
              // subscriber target counts peers already served -- it then waits out serve_timeout.
              // Stalling instead lets the late peer merge into the resident entry once reachable.
              // Bounded by serve_timeout (a held entry always releases), so a full bank cannot
              // wedge a port permanently. bank_has_free is already computed and consumed on this
              // very line, so the added term is one OR against a config bit: no new logic level
              // between the bank hash and this decision.
              req_in_ready[tile_i][port_i]  = 1'b0;
              req_out_valid[tile_i][port_i] = 1'b0;
            end else begin
              // ALLOCATE (won the per-bank slot) or BYPASS (non-mergeable store/AMO, or a mergeable
              // miss whose bank is full): forward this request to the NoC.
              // Per-type hold window: single (burst_len==1) uses HoldWindowSingle, burst uses
              // HoldWindowBurst. A 0 window for this class -> take the normal issue path (a held
              // door with a 0 window would never issue -> deadlock).
              if ((((req_len[tile_i][port_i] == BurstLenWidth'(1)) ?
                     cfg_hold_window_single : cfg_hold_window_burst) != 0) &&
                  req_can_merge[tile_i][port_i] &&
                  req_alloc_found[tile_i][port_i]) begin
                // Hold-the-fetch: allocate the entry but WITHHOLD its NoC fetch (the replay walker
                // below issues it once hold_done). Consume the request locally so the door never
                // couples to NoC readiness and never head-of-line-blocks the tile port.
                req_in_ready[tile_i][port_i]  = 1'b1;
                req_out_valid[tile_i][port_i] = 1'b0;
              end else begin
                req_in_ready[tile_i][port_i]  = req_out_ready[tile_i][port_i];
                req_out_valid[tile_i][port_i] = 1'b1;
              end
              if (req_can_merge[tile_i][port_i]) begin
                // Allocate a new MSHR entry (only the bank's slot winner has req_alloc_found set;
                // bank-full mergeable misses fall through here as a plain bypass).
                if (req_alloc_found[tile_i][port_i] &&
                    req_in_ready[tile_i][port_i]) begin
                mshr_d_valid[req_alloc_found_mshr_id[tile_i][port_i]] = 1'b1;
                // RR victim advance: firing on a still-valid CACHED way IS a reclaim -- move
                // that bank's scan start just past the evicted way. Invalid-way allocs (the
                // common case) leave the pointer alone. Reads the _q view: the fresh entry's
                // own fields are only in mshr_d, so this cycle's alloc cannot mask the reclaim.
                // At most one alloc fires per bank per cycle (bank_alloc_taken), so this
                // per-bank write never conflicts. /,% are shift/bit-select for the power-of-two
                // ways-per-bank here, not a divider.
                // ... and only when pass 2 can actually consume the pointer: the RR victim start is
                // read exclusively by the reclaim scan, which is gated on CacheReclaimable.
                if (CacheVictimRR && CacheReclaimable) begin
                  evict_vid = int'(req_alloc_found_mshr_id[tile_i][port_i]);
                  evict_vw  = evict_vid & unsigned'(MshrWaysPerBank - 1);
                  if (mshr_q_valid[evict_vid] && (mshr_q[evict_vid].state == MSHR_CACHED)) begin
                    victim_rr_d[evict_vid / MshrWaysPerBank] =
                        (evict_vw + 1 >= MshrWaysPerBank) ? '0 : VictimPtrW'(evict_vw + 1);
                  end
                end
                // Tier-b: stamp the egress NoC request with (allocated entry id + 1) so the returning
                // response routes back to this entry by direct index (tag 0 stays the bypass sentinel).
                req_out[tile_i][port_i].mshr_tag =
                    MshrTagWidth'(req_alloc_found_mshr_id[tile_i][port_i]) + MshrTagWidth'(1);
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]] = '0;
                mshr_wr_all[req_alloc_found_mshr_id[tile_i][port_i]] = 1'b1;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].base_addr =
                    req_addr_key[tile_i][port_i];
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].tgt_group_id =
                    req_in[tile_i][port_i].tgt_group_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].burst_len =
                    req_len[tile_i][port_i];
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].state      = MSHR_WAIT_RESP;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].cacheable  = 1'b1;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beats_left =
                    req_len[tile_i][port_i];
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beat_pending = '0;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beat_pending2 = '0;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beat2_armed = 1'b0;
`ifndef TARGET_SYNTHESIS
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beat_seen = '0;
`endif
`ifndef TARGET_SYNTHESIS
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beat_done = '0;
`endif
                // Owner request is always stored in sub_reqs[0].
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].valid = 1'b1;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].tile_id = tile_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].port_id = port_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].core_id =
                    req_in[tile_i][port_i].wdata.core_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].meta_id_base =
                    req_in[tile_i][port_i].wdata.meta_id;
`ifndef TARGET_SYNTHESIS
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].cache_hit_cnt = '0;
`endif
                // Hold-the-fetch: arm the per-type hold window (single vs burst). A 0 window (or
                // the feature off) means the fetch went out this same cycle on the passthrough, so
                // mark it issued immediately.
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].hold_cnt =
                    hold_ticks((req_len[tile_i][port_i] == BurstLenWidth'(1)) ?
                               cfg_hold_window_single : cfg_hold_window_burst);
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].issued =
                    (((req_len[tile_i][port_i] == BurstLenWidth'(1)) ?
                      cfg_hold_window_single : cfg_hold_window_burst) == 0);
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs_num =
                    SubReqCountW'(1);
                // Cache self-invalidate: the owner is the first served sub-request.
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].served_cnt = ServedCntW'(1);
                end
              end
            end
            // F3b: RECORD the store's byte-merge; the merge itself happens once per entry after
            // this loop. Writing mshr_d[e].resp_buf here made lane k+1 read the entry lane k had
            // just rewritten -- a 32-deep chain of 64-entry indexed writes inside the request door,
            // which is measured at 3.77 ns and is ~70% of what is left after F3a/F3c/F3d.
            if (EnableRespCache && !amo_invalidate &&
                req_is_store[tile_i][port_i] &&
                (req_len[tile_i][port_i] == BurstLenWidth'(1)) &&
                req_in_ready[tile_i][port_i]) begin
              // Bank-scoped: a store can only hit a CACHED entry in its OWN bank, so only this
              // request's MshrWaysPerBank ways are examined and hit_e reconstructs the absolute id.
              for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
                cache_hit_e =
                    int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i;
                // Reads only. None of state / resp_buf_cnt / resp_buf_rd_ptr is written by this
                // pass any more, so all 32 lanes evaluate against the same entry state.
                if (mshr_d_valid[cache_hit_e] &&
                    (mshr_d[cache_hit_e].state == MSHR_CACHED) &&
                    req_addr_hit_way[tile_i][port_i][way_i]) begin
                  stb_lane = RespLaneW'(tile_i * NumReqPortsActive + (port_i - 1));
                  stb_hit[cache_hit_e][stb_lane] = 1'b1;
                end
              end
            end
          end
        end else begin
          req_in_ready[tile_i][port_i] = 1'b1;
        end
      end
    end

    // F3b: one byte-merge per entry. Each hitting lane contributes only its enabled bytes, so
    // disjoint byte sets merge exactly as the sequential loop did. The clock-gate enable is
    // REQUIRED, not an optimisation: mshr_rb_en is (mshr_wr_all | mshr_rb_we) and this path raises
    // neither otherwise, so the `FFL holding resp_buf stays gated while its D changes -- which
    // drops the merged bytes in SIMULATION as well as synthesis, leaving the CACHED line stale for
    // the next hit. That bug was caught historically by mshr_gate_rb_no_lost_write.
    stb_bytes = '0; stb_ovl = '0;
    for (int e = 0; e < MshrNum; e++) begin
      stb_seen = '0;
      for (int l = 0; l < NumReqLanes; l++) begin
        if (stb_hit[e][l]) begin
          if (|(stb_seen & stb_be[l])) stb_ovl[e] = 1'b1;   // two lanes, same byte, same cycle
          stb_seen              = stb_seen | stb_be[l];
          stb_bytes[e]          = stb_bytes[e] | stb_be[l];
          for (int b = 0; b < StrbW; b++) begin
            if (stb_be[l][b]) begin
              mshr_d[e].resp_buf[mshr_d[e].resp_buf_rd_ptr].data[b*8 +: 8] =
                  stb_wd[l][b*8 +: 8];
            end
          end
        end
      end
      if (|stb_bytes[e]) begin
        mshr_rb_we[e][mshr_d[e].resp_buf_rd_ptr] = 1'b1;
        if (mshr_d[e].resp_buf_cnt == '0) begin
          mshr_d[e].resp_buf_cnt = RespBufCountW'(1);
        end
      end
    end

    // ------------------------------------------------------------
    // Hold-the-fetch replay: issue the withheld fetch of every hold_done entry (window expired,
    // or subscriber count reached HoldSubs -- checked on mshr_d so a merge landing THIS cycle
    // releases immediately). Runs after the door logic above, so fresh traffic (including
    // non-backpressurable bypasses) has already claimed its lanes; injection uses only idle
    // lanes, on the entry owner's original lane (the response-capture guard re-validates the
    // owner tile). valid is asserted only when the lane's ready is ALREADY high (spill-register
    // ready is state-only), so an injected request is always accepted in the same cycle and no
    // lane ever presents a retractable/mutating valid.
    // ------------------------------------------------------------
    if (HoldWindowMax != 0) begin
      // C3 step 1: hold-done and owner lane per ENTRY -- lane-independent, so computed once
      // instead of re-derived inside a chain.
      for (int e = 0; e < MshrNum; e++) begin
        // Elaboration-constant select: one arm is built, and at ReplayFromQ = 0 every term is
        // literally the mshr_d expression it replaced.
        replay_scan_valid[e] = ReplayFromQ ? mshr_q_valid[e] : mshr_d_valid[e];
        replay_scan_ent[e]   = ReplayFromQ ? mshr_q[e]       : mshr_d[e];
        replay_ready[e] = replay_scan_valid[e] && (replay_scan_ent[e].state == MSHR_WAIT_RESP) &&
                          !replay_scan_ent[e].issued &&
                          ((replay_scan_ent[e].hold_cnt == '0) ||
                           (replay_scan_ent[e].sub_reqs_num >=
                            SubReqCountW'((replay_scan_ent[e].burst_len == BurstLenWidth'(1)) ?
                                          cfg_hold_subs_single : cfg_hold_subs_burst)));
        replay_own_t[e] = replay_scan_ent[e].sub_reqs[0].tile_id;
        replay_own_p[e] = replay_scan_ent[e].sub_reqs[0].port_id;
        replay_rr_mask[e] = MshrIdxW'(e) >= MshrIdxW'(hold_replay_rr_q);
      end
      // C3 step 2: each lane picks its own winner, in parallel. Lanes are disjoint by construction
      // (one owner lane per entry), so no lane can steal another's candidate.
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
          if (!req_out_valid[t][p] && req_out_ready[t][p]) begin
            replay_cand = '0;
            for (int e = 0; e < MshrNum; e++) begin
              if (replay_ready[e] && (replay_own_t[e] == tile_group_id_t'(t)) &&
                  (replay_own_p[e] == RespPortIdW'(p))) begin
                replay_cand[e] = 1'b1;
              end
            end
            if (|replay_cand) begin
              replay_hi     = replay_cand &  replay_rr_mask;
              replay_lo     = replay_cand & ~replay_rr_mask;
              replay_win_oh = (replay_hi != '0) ? (replay_hi & (~replay_hi + MshrNum'(1)))
                                                : (replay_lo & (~replay_lo + MshrNum'(1)));
              replay_win_e  = '0;
              for (int b = 0; b < MshrNum; b++) begin
                if (replay_win_oh[b]) replay_win_e |= MshrIdxW'(b);
              end
              req_out_valid[t][p]               = 1'b1;
              req_out[t][p]                     = '0;
              // Read the payload from the SAME view the winner was selected from; mixing them
              // would put the 64:1 field mux back on the d-side cone for no benefit. Safe either
              // way: these are identity fields, written only by alloc and merge, and an entry that
              // is replay_ready was allocated in an earlier cycle.
              req_out[t][p].wdata.meta_id       = replay_scan_ent[replay_win_e].sub_reqs[0].meta_id_base;
              req_out[t][p].wdata.core_id       = replay_scan_ent[replay_win_e].sub_reqs[0].core_id;
              req_out[t][p].wen                 = 1'b0;
              req_out[t][p].be                  = '1;
              req_out[t][p].tgt_group_id        = replay_scan_ent[replay_win_e].tgt_group_id;
              req_out[t][p].tgt_addr            = replay_scan_ent[replay_win_e].base_addr;
              req_out[t][p].burst_len           = replay_scan_ent[replay_win_e].burst_len;
              req_out[t][p].mshr_tag            = MshrTagWidth'(replay_win_e) + MshrTagWidth'(1);
              mshr_d[replay_win_e].issued       = 1'b1;
            end
          end
        end
      end
    end

    // AMO invalidates all cached entries (cache is best-effort only).
    if (EnableRespCache && amo_invalidate) begin
      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].state == MSHR_CACHED)) begin
          mshr_d_valid[mshr_i] = 1'b0;
          // F1: retire by dropping valid only -- do NOT clear the entry. The clear was a WRITE, so
          // it forced every identity and resp_buf clock gate to wait on this decision, which is the
          // last thing computed in the process (822 logic levels, arrival 11.07 ns at 2.0 ns TCK).
          // It is also redundant: allocation blanks the entry before reuse (:3417), and every read
          // of the array is gated on mshr_q_valid / mshr_d_valid, so nothing can observe the stale
          // contents of a retired entry. The mshr_gate_*_no_lost_write assertions cover the converse.
        end
      end
    end

    // Cache self-invalidate (idea 1): a CACHED entry (all subscribers drained, sub_reqs_num==0)
    // that has served its per-type sharing target -- HoldSubsSingle for a scalar/single entry,
    // HoldSubsBurst for a burst -- frees itself. The done cache line becomes an INVALID way, which
    // the invalid-first allocator prefers, so other cache lines survive longer. Placed after the
    // alloc/merge updates: an entry a request merged into this cycle is now DRAIN_RESP, and one an
    // alloc just reclaimed is now WAIT_RESP, so neither is CACHED here -> untouched. When
    // CacheReclaimable=0 this becomes the normal capacity-release path for resident cache lines.
    if (CacheSelfInval && EnableRespCache) begin
      for (int e = 0; e < MshrNum; e++) begin
        // cfg_cache_reuse_target == 0 keeps the legacy operand (the per-type sharing target), so
        // this expression is structurally what it was before the CSR existed. Non-zero replaces it
        // with the reuse target, letting the line outlive the cohort that filled it -- served_cnt
        // is sized to ServedCntMax == 2*MshrMergeReqs, which is also the CSR's upper bound, so the
        // target is always reachable and a line can never be pinned by an unreachable threshold.
        if (mshr_d_valid[e] && (mshr_d[e].state == MSHR_CACHED) &&
            (mshr_d[e].sub_reqs_num == '0) &&
            (mshr_d[e].served_cnt >=
             ((cfg_cache_reuse_target != '0)
                ? ServedCntW'(cfg_cache_reuse_target)
                : ServedCntW'((mshr_d[e].burst_len == BurstLenWidth'(1)) ? cfg_hold_subs_single : cfg_hold_subs_burst)))) begin
          mshr_d_valid[e] = 1'b0;
          // F1: retire by dropping valid only (see the first retire site for why).
        end
      end
    end

    // ------------------------------------------------------------
    // Response path: capture MSHR responses or bypass to group
    // ------------------------------------------------------------
    for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].resp_buf_cnt < RespBufWords)) begin
        mshr_resp_slots[mshr_i] = RespBufCountW'(RespBufWords) - mshr_d[mshr_i].resp_buf_cnt;
      end else begin
        mshr_resp_slots[mshr_i] = '0;
      end
      resp_push_ptr[mshr_i] = mshr_d[mshr_i].resp_buf_wr_ptr;
    end

    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        resp_capture_fire[tile_i][port_i] = 1'b0;
        resp_capture_beat_offset[tile_i][port_i] = '0;
        resp_is_mshr[tile_i][port_i] = 1'b0;
        resp_mshr_id[tile_i][port_i] = '0;
        if (resp_in_valid[tile_i][port_i] &&
            (resp_in[tile_i][port_i].wen == 1'b0) &&
            (resp_in[tile_i][port_i].rdata.amo == '0)) begin
          // Tier-b: route the response by its round-tripped tag instead of scanning all entries.
          // A real entry id e was stamped as (e+1); tag 0 is the bypass sentinel. Index the candidate
          // entry directly, then RE-VALIDATE (state / owner tile+core / wrap-safe burst beat range) as
          // a guard against a stale or corrupted tag — on any mismatch resp_is_mshr stays 0 and the
          // response falls through to the bypass path. This replaces the O(resp-ports x MshrNum) scan
          // with an O(1) index + single-entry check.
          if (resp_in[tile_i][port_i].mshr_tag != '0) begin
            resp_tag_cand =
                mshr_id_t'(resp_in[tile_i][port_i].mshr_tag - MshrTagWidth'(1));
            if (mshr_q_valid[resp_tag_cand] &&
                ((mshr_q[resp_tag_cand].state == MSHR_WAIT_RESP) ||
                 (mshr_q[resp_tag_cand].state == MSHR_DRAIN_RESP)) &&
                (mshr_q[resp_tag_cand].sub_reqs[0].tile_id == tile_group_id_t'(tile_i)) &&
                burst_beat_valid(resp_in[tile_i][port_i].rdata.core_id,
                                 resp_in[tile_i][port_i].rdata.meta_id,
                                 mshr_q[resp_tag_cand].sub_reqs[0].core_id,
                                 mshr_q[resp_tag_cand].sub_reqs[0].meta_id_base,
                                 mshr_q[resp_tag_cand].burst_len)) begin
              resp_is_mshr[tile_i][port_i] = 1'b1;
              resp_mshr_id[tile_i][port_i] = resp_tag_cand;
            end
          end
        end

        if (resp_is_mshr[tile_i][port_i]) begin
          resp_capture_beat_offset[tile_i][port_i] =
              burst_beat_of(resp_in[tile_i][port_i].rdata.core_id,
                            resp_in[tile_i][port_i].rdata.meta_id,
                            mshr_q[resp_mshr_id[tile_i][port_i]].sub_reqs[0].core_id,
                            mshr_q[resp_mshr_id[tile_i][port_i]].sub_reqs[0].meta_id_base);
          mshr_resp_inflight[resp_mshr_id[tile_i][port_i]] = 1'b1;
          // F3c: ready and fire come from the per-entry grant below, not from walking the lanes
          // and decrementing a slot counter as we go -- that decrement made lane k+1's readiness
          // depend on lane k, which is half of why the class-B endpoint sits at 6.94 ns.
        end else begin
          resp_in_ready[tile_i][port_i] = resp_out_ready[tile_i][port_i];
        end

        if (resp_in_valid[tile_i][port_i] && !resp_is_mshr[tile_i][port_i]) begin
          resp_out_valid[tile_i][port_i] = 1'b1;
          resp_out[tile_i][port_i] = resp_in[tile_i][port_i];
          // NO RETAG. A bypassed burst -- intra-group, or inter-group without a merge -- is
          // expanded at the DESTINATION tile, and tcdm_burst_expander applies the lane law
          // there, relative to this requester's own core_id/meta_id. The beat therefore
          // arrives already addressed to the right reorder buffer and nothing is left to do.
          //
          // The old ParityDrain bypass-retag table (design doc §4.6) lived here and is gone
          // with its BypassTrackWays state: it existed only because the destination emitted
          // meta_id_base + b on the issuing port, so the parity had to be re-applied on the
          // way past. It could never have carried the lane law anyway -- it never saw
          // intra-group traffic, which rides master lane 0 and does not pass this module.
          resp_from_bypass[tile_i][port_i] = 1'b1;
        end
      end
    end

    // ------------------------------------------------------------
    // F3c: grant response slots per ENTRY, then capture once per entry.
    //
    // Both halves of the capture used to walk 16 tiles x 2 resp ports sequentially: the first
    // loop decremented mshr_resp_slots[id], and the second read-modify-wrote resp_push_ptr[id],
    // resp_buf_cnt and the 186-bit entry. A 32-deep chain of 64-entry indexed accesses in the
    // MIDDLE of the process -- the measured class-B endpoint (resp_in_ready) sits at 6.94 ns
    // against the door's 3.77 ns, and this chain is the difference between them.
    //
    // Equivalent by construction. resp_is_mshr / resp_mshr_id derive from mshr_q alone, so every
    // lane's target is known independently of the others. The sequential form granted lanes in
    // increasing index order until the slots ran out, so its granted set is exactly the first
    // slots[e] lanes by index. And the state decision reads only burst_len and sub_reqs_num,
    // neither of which this pass writes -- so it cannot depend on WHICH lane won.
    // ------------------------------------------------------------
    cap_want = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        // resp_is_mshr is only set inside `if (resp_in_valid ...)`, so it implies valid: no lane
        // can be granted here that the old code would have skipped.
        if (resp_is_mshr[tile_i][port_i]) begin
          cap_lane = RespLaneW'(tile_i * NumRespPortsActive + (port_i - 1));
          cap_want[resp_mshr_id[tile_i][port_i]][cap_lane] = 1'b1;
        end
      end
    end
    for (int e = 0; e < MshrNum; e++) begin
      cap_first[e]  = cap_want[e] & (~cap_want[e] + NumRespLanes'(1));
      cap_rest      = cap_want[e] & ~cap_first[e];
      cap_second[e] = cap_rest    & (~cap_rest    + NumRespLanes'(1));
      cap_g1[e] = (cap_first[e]  != '0) && (mshr_resp_slots[e] >= RespBufCountW'(1));
      cap_g2[e] = (cap_second[e] != '0) && (mshr_resp_slots[e] >= RespBufCountW'(2));
    end
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        if (resp_is_mshr[tile_i][port_i]) begin
          cap_lane = RespLaneW'(tile_i * NumRespPortsActive + (port_i - 1));
          resp_in_ready[tile_i][port_i] =
              (cap_first [resp_mshr_id[tile_i][port_i]][cap_lane] && cap_g1[resp_mshr_id[tile_i][port_i]]) ||
              (cap_second[resp_mshr_id[tile_i][port_i]][cap_lane] && cap_g2[resp_mshr_id[tile_i][port_i]]);
          resp_capture_fire[tile_i][port_i] =
              resp_in_valid[tile_i][port_i] && resp_in_ready[tile_i][port_i];
        end
      end
    end
    // Scatter each granted lane's beat to its entry. cap_first / cap_second are one-hot, so at
    // most one lane writes each of cap_d0 / cap_d1. Scattering by lane costs 32 iterations;
    // gathering per entry would cost MshrNum x 32 and blow up an already slow elaboration.
    cap_d0 = '0; cap_d1 = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        if (resp_capture_fire[tile_i][port_i]) begin
          cap_lane = RespLaneW'(tile_i * NumRespPortsActive + (port_i - 1));
`ifndef TARGET_SYNTHESIS
          if (mshr_d[resp_mshr_id[tile_i][port_i]].beat_seen[resp_capture_beat_offset[tile_i][port_i]]) begin
            dup_beat_detected = 1'b1;
            dup_beat_mshr     = resp_mshr_id[tile_i][port_i];
            dup_beat_beat     = resp_capture_beat_offset[tile_i][port_i];
            dup_beat_meta     = resp_in[tile_i][port_i].rdata.meta_id;
          end
          mshr_d[resp_mshr_id[tile_i][port_i]].beat_seen[resp_capture_beat_offset[tile_i][port_i]] = 1'b1;
`endif
          if (cap_first[resp_mshr_id[tile_i][port_i]][cap_lane]) begin
            cap_d0[resp_mshr_id[tile_i][port_i]] =
                '{beat_off: resp_capture_beat_offset[tile_i][port_i],
                  data:     resp_in[tile_i][port_i].rdata.data};
          end else begin
            cap_d1[resp_mshr_id[tile_i][port_i]] =
                '{beat_off: resp_capture_beat_offset[tile_i][port_i],
                  data:     resp_in[tile_i][port_i].rdata.data};
          end
        end
      end
    end
    // One write per entry. Slot order, the pointer and the saturating count reproduce the
    // sequential form: the first grant lands on resp_buf_wr_ptr, the second on the slot after
    // it, and the two guarded increments saturate at RespBufWords exactly as they did.
    for (int e = 0; e < MshrNum; e++) begin
      if (cap_g1[e] || cap_g2[e]) begin
        cap_s0 = mshr_d[e].resp_buf_wr_ptr;
        cap_n0 = (RespBufWords > 1) ?
                 ((cap_s0 == RespBufPtrW'(RespBufWords - 1)) ? '0 : RespBufPtrW'(cap_s0 + 1'b1))
                 : cap_s0;
        cap_s1 = cap_n0;
        cap_n1 = (RespBufWords > 1) ?
                 ((cap_s1 == RespBufPtrW'(RespBufWords - 1)) ? '0 : RespBufPtrW'(cap_s1 + 1'b1))
                 : cap_s1;
        if (cap_g1[e]) begin
          mshr_rb_we[e][cap_s0]      = 1'b1;
          mshr_d[e].resp_buf[cap_s0] = cap_d0[e];
          if (mshr_d[e].resp_buf_cnt < RespBufWords) begin
            mshr_d[e].resp_buf_cnt = mshr_d[e].resp_buf_cnt + 1'b1;
          end
        end
        if (cap_g2[e]) begin
          mshr_rb_we[e][cap_s1]      = 1'b1;
          mshr_d[e].resp_buf[cap_s1] = cap_d1[e];
          if (mshr_d[e].resp_buf_cnt < RespBufWords) begin
            mshr_d[e].resp_buf_cnt = mshr_d[e].resp_buf_cnt + 1'b1;
          end
        end
        mshr_d[e].resp_buf_wr_ptr = cap_g2[e] ? cap_n1 : cap_n0;
        if (RespWaitSubsSingle && !amo_invalidate &&
            (mshr_d[e].burst_len == BurstLenWidth'(1)) &&
            (mshr_d[e].sub_reqs_num < SubReqCountW'(cfg_hold_subs_single))) begin
          mshr_d[e].state    = MSHR_RESP_HOLD;
          mshr_d[e].hold_cnt = hold_ticks(cfg_serve_timeout);
        end else begin
          mshr_d[e].state    = MSHR_DRAIN_RESP;
        end
      end
    end

    // Superseded by the per-entry capture above. Kept compiled-out rather than deleted until the
    // equivalence arm confirms the rewrite, so the two forms can be diffed side by side.
    if (1'b0) begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        if (resp_capture_fire[tile_i][port_i]) begin
`ifndef TARGET_SYNTHESIS
          if (mshr_d[resp_mshr_id[tile_i][port_i]].beat_seen[resp_capture_beat_offset[tile_i][port_i]]) begin
            dup_beat_detected = 1'b1;
            dup_beat_mshr     = resp_mshr_id[tile_i][port_i];
            dup_beat_beat     = resp_capture_beat_offset[tile_i][port_i];
            dup_beat_meta     = resp_in[tile_i][port_i].rdata.meta_id;
          end
`endif
          mshr_rb_we[resp_mshr_id[tile_i][port_i]][resp_push_ptr[resp_mshr_id[tile_i][port_i]]] = 1'b1;
          mshr_d[resp_mshr_id[tile_i][port_i]].resp_buf[resp_push_ptr[resp_mshr_id[tile_i][port_i]]] =
              '{beat_off: resp_capture_beat_offset[tile_i][port_i],
                data:     resp_in[tile_i][port_i].rdata.data};
          if (RespBufWords > 1) begin
            if (resp_push_ptr[resp_mshr_id[tile_i][port_i]] == RespBufPtrW'(RespBufWords - 1)) begin
              resp_push_ptr[resp_mshr_id[tile_i][port_i]] = '0;
            end else begin
              resp_push_ptr[resp_mshr_id[tile_i][port_i]] =
                  resp_push_ptr[resp_mshr_id[tile_i][port_i]] + 1'b1;
            end
          end
          if (mshr_d[resp_mshr_id[tile_i][port_i]].resp_buf_cnt < RespBufWords) begin
            mshr_d[resp_mshr_id[tile_i][port_i]].resp_buf_cnt =
                mshr_d[resp_mshr_id[tile_i][port_i]].resp_buf_cnt + 1'b1;
          end
          mshr_d[resp_mshr_id[tile_i][port_i]].resp_buf_wr_ptr = resp_push_ptr[resp_mshr_id[tile_i][port_i]];
          if (RespWaitSubsSingle && !amo_invalidate &&
              (mshr_d[resp_mshr_id[tile_i][port_i]].burst_len == BurstLenWidth'(1)) &&
              (mshr_d[resp_mshr_id[tile_i][port_i]].sub_reqs_num <
               SubReqCountW'(cfg_hold_subs_single))) begin
            mshr_d[resp_mshr_id[tile_i][port_i]].state = MSHR_RESP_HOLD;
            // Arm the serve-target timeout (0 => never expires; the countdown below is skipped).
            mshr_d[resp_mshr_id[tile_i][port_i]].hold_cnt = hold_ticks(cfg_serve_timeout);
          end else begin
            mshr_d[resp_mshr_id[tile_i][port_i]].state = MSHR_DRAIN_RESP;
          end
`ifndef TARGET_SYNTHESIS
          mshr_d[resp_mshr_id[tile_i][port_i]].beat_seen[resp_capture_beat_offset[tile_i][port_i]] = 1'b1;
`endif
        end
      end
    end
    end

    // A buffered response predates any store/AMO observed after it returned. Release the old value
    // to its already-recorded subscribers, but prohibit the entry from becoming a stale cache line.
    // This pass is after response capture so it also covers a response and invalidating operation
    // arriving in the same cycle.
    // F3a: DECIDE for every lane, then WRITE once per entry.
    //
    // This pass used to be 16 tiles x 2 ports x 4 ways of sequential read-modify-write on mshr_d,
    // so lane k+1 read the 186-bit entry lane k had just rewritten. Synthesis has to build that as
    // a 32-deep chain of 64-entry indexed writes -- roughly 250 logic levels -- for a pass whose
    // every written value is a CONSTANT.
    //
    // Equivalent by construction, not by appeal to "it probably cannot happen": the only field the
    // hit test reads that this pass also writes is `state`, and the write moves it OUT of
    // MSHR_RESP_HOLD. So in the sequential form a second lane hitting the same entry found the test
    // false and wrote nothing, and the entry ended in exactly the state the first hitting lane
    // produced -- which is the same state every hitting lane would produce, because they are all
    // the same constants. ORing the hits and applying them once therefore gives the identical
    // result, and the scatter below is a 1-bit OR-reduction (decode + OR tree, ~11 levels) rather
    // than a chain of full-entry writes.
    st_force_drain = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        if (req_in_valid[tile_i][port_i] && req_in_ready[tile_i][port_i] &&
            req_is_store[tile_i][port_i] &&
            (req_len[tile_i][port_i] == BurstLenWidth'(1))) begin
          for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
            cache_hit_e =
                int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i;
            // Reads only -- every lane sees the same pre-pass entry state, which is what makes the
            // 32 evaluations independent instead of chained.
            if (mshr_d_valid[cache_hit_e] &&
                (mshr_d[cache_hit_e].state == MSHR_RESP_HOLD) &&
                (mshr_d[cache_hit_e].base_addr == req_addr_key[tile_i][port_i]) &&
                (mshr_d[cache_hit_e].tgt_group_id == req_in[tile_i][port_i].tgt_group_id)) begin
              st_force_drain[cache_hit_e] = 1'b1;
            end
          end
        end
      end
    end
    for (int e = 0; e < MshrNum; e++) begin
      if (st_force_drain[e]) begin
        mshr_d[e].state = MSHR_DRAIN_RESP;
        mshr_d[e].cacheable = 1'b0;
        mshr_d[e].beats_left = BurstLenWidth'(1);
        mshr_d[e].beat_pending = '0;
        mshr_d[e].beat_pending2 = '0;
        mshr_d[e].beat2_armed = 1'b0;
`ifndef TARGET_SYNTHESIS
        mshr_d[e].beat_seen = '0;
        mshr_d[e].beat_seen[0] = 1'b1;
`endif
`ifndef TARGET_SYNTHESIS
        mshr_d[e].beat_done = '0;
`endif
      end
    end
    if (amo_invalidate) begin
      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].state == MSHR_RESP_HOLD)) begin
          mshr_d[mshr_i].state = MSHR_DRAIN_RESP;
          mshr_d[mshr_i].cacheable = 1'b0;
          mshr_d[mshr_i].beats_left = BurstLenWidth'(1);
          mshr_d[mshr_i].beat_pending = '0;
          mshr_d[mshr_i].beat_pending2 = '0;
          mshr_d[mshr_i].beat2_armed = 1'b0;
`ifndef TARGET_SYNTHESIS
          mshr_d[mshr_i].beat_seen = '0;
          mshr_d[mshr_i].beat_seen[0] = 1'b1;
`endif
`ifndef TARGET_SYNTHESIS
          mshr_d[mshr_i].beat_done = '0;
`endif
        end
      end
    end

    // ------------------------------------------------------------
    // Serve-target timeout (group_mshr_serve_timeout). Free-running countdown -- never gated on
    // traffic, arbitration or readiness -- so an entry cannot wait on a target that the access
    // pattern never delivers. Same contract as the request-side hold window: early release on
    // reaching the target is the MECHANISM, this countdown is the LIVENESS GUARANTEE. Placed after
    // response capture and the store/AMO forced-drain passes so it observes this cycle's state and
    // never fights them. Entirely const-folded away when ServeTimeout == 0.
    // ------------------------------------------------------------
    if (cfg_serve_timeout != 0) begin
      for (int e = 0; e < MshrNum; e++) begin
        if (mshr_d_valid[e] && (mshr_d[e].state == MSHR_RESP_HOLD)) begin
          if (mshr_d[e].hold_cnt != '0) begin
            if (hold_tick[e]) mshr_d[e].hold_cnt = mshr_d[e].hold_cnt - HoldCntW'(1);
          end else begin
            // Expired: stop waiting for subscribers that are not coming and deliver the buffered
            // word to whoever HAS subscribed. Same re-arm the merge-target path performs.
`ifndef TARGET_SYNTHESIS
            mshr_resp_hold_timeout_dbg[e] = 1'b1;
`endif
            mshr_d[e].state         = MSHR_DRAIN_RESP;
            mshr_d[e].beats_left    = BurstLenWidth'(1);
            mshr_d[e].beat_pending  = '0;
            mshr_d[e].beat_pending2 = '0;
            mshr_d[e].beat2_armed   = 1'b0;
`ifndef TARGET_SYNTHESIS
            mshr_d[e].beat_seen     = '0;
            mshr_d[e].beat_seen[0]  = 1'b1;
`endif
`ifndef TARGET_SYNTHESIS
            mshr_d[e].beat_done     = '0;
`endif
          end
        end else if (CacheSelfInval && EnableRespCache && mshr_d_valid[e] &&
                     (mshr_d[e].state == MSHR_CACHED) &&
                     (mshr_d[e].sub_reqs_num == '0)) begin
          // A cache line that never reaches its sharing target ages out instead of pinning its way
          // forever. Entries that DO reach the target are freed earlier by the self-invalidate pass.
          if (mshr_d[e].hold_cnt != '0) begin
            if (hold_tick[e]) mshr_d[e].hold_cnt = mshr_d[e].hold_cnt - HoldCntW'(1);
          end else begin
            // Cache line aged out WITHOUT reaching its reuse target: its second cohort never
            // completed in time. Distinct from self-invalidate, and the number that says whether
            // the residency is too SHORT.
`ifndef TARGET_SYNTHESIS
            mshr_cache_timeout_dbg[e] = 1'b1;
`endif
            mshr_d_valid[e] = 1'b0;
            // F1: retire by dropping valid only (see the first retire site for why).
          end
        end
      end
    end

    // Precompute beat offset for the currently buffered head response (per MSHR).
    for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].resp_buf_cnt != '0)) begin
        // For single-word entries (including cached replay), the only legal beat
        // index is 0. Use 0 directly so replayed cached data does not depend on
        // stale meta_id inside resp_buf.
        if (mshr_d[mshr_i].burst_len == BurstLenWidth'(1)) begin
          resp_beat_offset[mshr_i] = '0;
        end else begin
          // Computed once at capture (the beat is split across meta_id and core_id, so
          // re-deriving it here would mean storing both fields).
          resp_beat_offset[mshr_i] =
              mshr_d[mshr_i].resp_buf[mshr_d[mshr_i].resp_buf_rd_ptr].beat_off;
        end
      end else begin
        resp_beat_offset[mshr_i] = '0;
      end
    end

    // Initialize pending-requester bitmap for a new head beat.
    for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      if (mshr_d_valid[mshr_i] &&
          (mshr_d[mshr_i].state == MSHR_DRAIN_RESP) &&
          (mshr_d[mshr_i].resp_buf_cnt != '0) &&
          (mshr_d[mshr_i].beat_pending == '0) &&
          (mshr_d[mshr_i].sub_reqs_num != '0)) begin
        for (int s = 0; s < MshrMergeReqs; s++) begin
          mshr_d[mshr_i].beat_pending[s] = mshr_d[mshr_i].sub_reqs[s].valid;
        end
      end
    end

    // ParityDrain: second-slot beat offset (resp_buf slot rd_ptr+1, burst entries with two
    // buffered beats) and its ONE-SHOT pending arm. Eager, armed exactly once per buffered
    // beat: after the slot's subscribers are all served the mask stays 0 until the slot is
    // popped/promoted, so re-delivery is structurally impossible (unlike a level-style re-arm).
    for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      resp_rd_ptr2[mshr_i] =
          (RespBufWords > 1) ?
          ((mshr_d[mshr_i].resp_buf_rd_ptr == RespBufPtrW'(RespBufWords - 1))
               ? '0 : RespBufPtrW'(mshr_d[mshr_i].resp_buf_rd_ptr + 1'b1))
          : '0;
      resp_beat_offset2[mshr_i] = '0;
      if (PD2 && mshr_d_valid[mshr_i] &&
          (mshr_d[mshr_i].burst_len != BurstLenWidth'(1)) &&
          (mshr_d[mshr_i].resp_buf_cnt >= RespBufCountW'(2))) begin
        resp_beat_offset2[mshr_i] = mshr_d[mshr_i].resp_buf[resp_rd_ptr2[mshr_i]].beat_off;
        if ((mshr_d[mshr_i].state == MSHR_DRAIN_RESP) &&
            !mshr_d[mshr_i].beat2_armed &&
            (mshr_d[mshr_i].sub_reqs_num != '0)) begin
          for (int s = 0; s < MshrMergeReqs; s++) begin
            mshr_d[mshr_i].beat_pending2[s] = mshr_d[mshr_i].sub_reqs[s].valid;
          end
          mshr_d[mshr_i].beat2_armed = 1'b1;
        end
      end
    end

    // ------------------------------------------------------------
    // Drain captured responses to all recorded sub-requests
    // ------------------------------------------------------------
    bp_clr = '0; bp2_clr = '0; sv_clr = '0;
    if (DrainMultiPort) begin
      // Use all available response ports per cycle.
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          // M4 (audit): bypass MUST take the port -- bypass responses are non-backpressurable by
          // contract, while MSHR-targeted responses are buffered (resp_buf) and CAN be backpressured
          // (resp_in_ready). Making bypass "wait its turn" would drop a response with nowhere to go, so
          // this is a strict-priority MUST, not an arbitration tie to rotate. Drain-behind-bypass is
          // BOUNDED, not starved: bypass arrivals on a port are finite (bounded by outstanding non-MSHR
          // responses), so a bypass-free cycle recurs and the persistently re-offered (RR-rotated) drain
          // beat then wins the freed port. RR fairness applies to the entry/sub_req axes, not bypass.
          port_taken[tile_i][port_i] = resp_in_valid[tile_i][port_i] &&
                                       !resp_is_mshr[tile_i][port_i];
          resp_sel_valid[tile_i][port_i] = 1'b0;
          resp_sel_mshr_id[tile_i][port_i] = '0;
          resp_sel_subreq_idx[tile_i][port_i] = '0;
        end
      end
      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        for (int s = 0; s < MshrMergeReqs; s++) begin
        end
      end

      // ---- PPA: hoist the (tile,port)-INDEPENDENT half of the drain eligibility test ----
      // The scan below runs inside `for (tile) for (port)` -- 16 x 2 = 32 instances at the 8x8
      // backend config -- and each instance evaluated all MshrNum x MshrMergeReqs = 256 (entry,
      // sub-request) pairs from scratch: 8,192 evaluations per group. Only the last two terms of
      // that test depend on (tile_i, port_i); the other five, and the PD2 destination-port
      // ternary (which reads burst_len and resp_beat_offset), are identical across all 32.
      //
      // Computing them once here leaves each instance with two narrow equality checks per pair.
      // Purely a restructuring: the per-pair predicate below is the same conjunction, factored.
      // DrainFromQ selects the SOURCE of this hoist -- registered array or combinational next
      // state. It is an elaboration constant, so one arm folds away entirely; there is no runtime
      // mux and no combinational loop through mshr_d when the registered arm is chosen. Because
      // optimisation (1) funnelled BOTH drain scans through these four vectors, this single
      // select covers the head-beat and the ParityDrain second-slot scan alike.
      for (int e = 0; e < MshrNum; e++) begin
        // NOT an `automatic ... = ...` local: an initialiser at declaration inside a procedural
        // block is ignored by synthesis (Spyglass SYNTH_89), which this module was cleaned of
        // earlier. drain_ent_ok is a module-scope packed vector instead.
        drain_scan_valid[e] = DrainFromQ ? mshr_q_valid[e] : mshr_d_valid[e];
        drain_scan_ent[e]   = DrainFromQ ? mshr_q[e]       : mshr_d[e];
        drain_ent_ok[e] = drain_scan_valid[e] && (drain_scan_ent[e].resp_buf_cnt != '0) &&
                          (drain_scan_ent[e].state == MSHR_DRAIN_RESP);
        // BOTH entry-level terms must be assigned BEFORE the sub-request loop that reads them --
        // these are blocking assignments, so an assignment placed after the loop would feed it the
        // previous evaluation's value.
        for (int s = 0; s < MshrMergeReqs; s++) begin
          drain_sub_ready[e][s] = drain_ent_ok[e] && drain_scan_ent[e].sub_reqs[s].valid &&
                                  drain_scan_ent[e].beat_pending[s];
          drain_sub_tile[e][s]  = drain_scan_ent[e].sub_reqs[s].tile_id;
          // Effective destination port: the ParityDrain pin for multi-beat entries, otherwise the
          // requester's own mapped port. Independent of s in the PD2 arm, but kept per-s so the
          // consumer is a single uniform compare.
          drain_sub_port[e][s]  = (PD2 && (drain_scan_ent[e].burst_len != BurstLenWidth'(1)))
                                ? (RespPortIdW'(1) + RespPortIdW'(resp_beat_offset[e][0]))
                                : map_resp_port_id(drain_scan_ent[e].sub_reqs[s].port_id);
          // Second-slot (ParityDrain) eligibility, hoisted for the drain2 scan further down.
        end
      end

      // ---- opt3 stage 1: one entry published per bank, round-robin, PORT-INDEPENDENT ----
      // Computed once here, shared by every (tile,port) instance below. The entry index is
      // bank-major (e = bank*MshrWaysPerBank + way), so each bank owns a contiguous slice.
      // The k loop descends so that k=0 -- the way AT the rotation pointer -- is assigned last
      // and therefore wins, giving round-robin priority from the pointer upward.
      for (int e = 0; e < MshrNum; e++) begin
        drain_ent_any[e]   = |drain_sub_ready[e];
        drain_published[e] = 1'b0;          // cleared per ENTRY, never per bank
      end
      for (int b = 0; b < MshrBankNum; b++) begin
        bank_rr_d[b]  = bank_rr_q[b];
        bank_pub_w[b] = '0;
        bank_pub_v[b] = 1'b0;
        bank_pub_e[b] = '0;
        for (int k = MshrWaysPerBank - 1; k >= 0; k--) begin
          // NOT `automatic int w = ...`: an initialiser at declaration inside a procedural block
          // is ignored by synthesis (Spyglass SYNTH_89). bank_scan_w is module scope.
          bank_scan_w = VictimPtrW'(bank_rr_q[b] + VictimPtrW'(k));
          if (drain_ent_any[b * MshrWaysPerBank + bank_scan_w]) begin
            bank_pub_w[b] = VictimPtrW'(bank_scan_w);
            bank_pub_v[b] = 1'b1;
          end
        end
        if (BankPublish && bank_pub_v[b]) begin
          drain_published[b * MshrWaysPerBank + int'(bank_pub_w[b])] = 1'b1;
          bank_pub_e[b] = MshrIdxW'(b * MshrWaysPerBank + int'(bank_pub_w[b]));
          bank_rr_d[b] = VictimPtrW'(bank_pub_w[b] + VictimPtrW'(1));
        end
      end

      // Select one sub-request per response port.
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          if (!port_taken[tile_i][port_i]) begin
            // RR fairness (audit M3/L3): rotate the entry visit by drain_mshr_rr and the sub_req visit
            // by subreq_rr (separate bases) so high-index entries/sub_reqs are not starved. Bounded
            // wait: a pending (entry,sub_req) is a CONTINUOUS candidate (held in DRAIN_RESP until fully
            // drained), so the marching base reaches it within N. The eligibility predicate and
            // resp_sel_* are byte-identical; only the visit order rotates.
            // TIMING REWRITE (same selection; see the equivalence argument).
            //
            // The legacy form walked all MshrNum entries x MshrMergeReqs sub-requests in rotated
            // order carrying resp_sel_valid, i.e. a 128 x 4 = 512-deep serial first-match chain PER
            // PORT, and additionally carried a `subreq_claimed` flag ACROSS the 32 ports -- chaining
            // the ports to each other as well.
            //
            // (1) That cross-port flag was DEAD, and has now been removed entirely. A candidate
            //     (entry,s) has exactly ONE destination: its tile comes from sub_reqs[s].tile_id and
            //     its port from either map_resp_port_id(sub_reqs[s].port_id) (single) or
            //     1+(beat_offset&1) (PD2 burst). No two ports can ever evaluate the same (entry,s),
            //     so the flag could never block anything; only resp_sel_valid (one pick per port)
            //     ever mattered. Dropping it makes the 32 ports independent.
            //     THIS INVARIANT IS LOAD-BEARING for the hoisted scans -- see the head-beat and
            //     drain2 predicate hoists, which rely on it to be port-order-independent.
            // (2) Within a port the scan is entry-major then sub-request-major in fixed rotated
            //     orders, so it is exactly: pick the first ENTRY that has any eligible sub-request,
            //     then the first eligible sub-request inside it. Two small rotated priority encodes
            //     (MshrNum-wide, then MshrMergeReqs-wide) reproduce that, at ~log2 depth instead of
            //     512 sequential stages.
            drain_sel_base     = EnableRrFairness ? MshrIdxW'(drain_mshr_rr_q) : '0;
            drain_sel_sub_base = EnableRrFairness ? SubIdxW'(subreq_rr_q) : '0;
            // Per-entry: does this entry offer any sub-request eligible for THIS port?
            // PPA: the five port-independent terms and the PD2 port ternary are precomputed once
            // above (drain_sub_ready / _tile / _port), so this is now two narrow equalities per
            // (entry, sub-request) instead of the full conjunction re-derived 32 times.
            drain_ent_cand = '0;
            bank_cand      = '0;
            if (BankPublish) begin
              // B0.3: evaluate only the MshrBankNum published entries, not all MshrNum -- the
              // per-(tile,port) predicate work drops by MshrWaysPerBank.
              for (int b = 0; b < MshrBankNum; b++) begin
                for (int s = 0; s < MshrMergeReqs; s++) begin
                  if (bank_pub_v[b] &&
                      drain_sub_ready[bank_pub_e[b]][s] &&
                      (drain_sub_tile[bank_pub_e[b]][s] == tile_group_id_t'(tile_i)) &&
                      (drain_sub_port[bank_pub_e[b]][s] == port_i[RespPortIdW-1:0])) begin
                    bank_cand[b] = 1'b1;
                  end
                end
              end
            end else begin
              for (int e = 0; e < MshrNum; e++) begin
                for (int s = 0; s < MshrMergeReqs; s++) begin
                  if (drain_sub_ready[e][s] &&
                      (drain_sub_tile[e][s] == tile_group_id_t'(tile_i)) &&
                      (drain_sub_port[e][s] == port_i[RespPortIdW-1:0])) begin
                    drain_ent_cand[e] = 1'b1;
                  end
                end
              end
            end
            // First candidate entry in rotated order (>= base first, then wrap).
            //
            // Parallel-prefix first-set-bit: log2(MshrNum) = 6 doubling steps, replacing a
            // MshrNum-deep `!drain_have_e` chain. The old form was worse than its depth
            // suggests -- it indexed drain_ent_cand[(base + k) % MshrNum] with a VARIABLE
            // base, so each of the MshrNum iterations needed its own MshrNum:1 mux. One
            // barrel rotate replaces all of them. This sits inside the (tile, resp port)
            // loops, so it is instantiated 32 times at 8x8.
            //
            // Equivalence proven exhaustively before the rewrite: all MshrNum rotation
            // bases x 25600 candidate vectors (corner, random and sparse), comparing BOTH
            // outputs -- including drain_win_e when no candidate exists. 0 mismatches.
            // A5: one shifter over the doubled vector. Bit-identical to the old guarded pair of
            // shifters including base==0, where the guard was already semantically redundant.
            if (BankPublish) begin
              // ---- B0.3: MshrBankNum-wide arbitration, EXACTLY equivalent to the MshrNum-wide one.
              //
              // Entries are bank-major (e = bank*MshrWaysPerBank + way) and the wide selector
              // rotates over the ENTRY index space, so a plain bank rotation is NOT equivalent:
              // for base = bank_base*W + base_way, the visit distance of bank b's published entry
              // is ((b - bank_base) mod MshrBankNum)*W + (pub_way[b] - base_way). Those windows are
              // disjoint across banks -- EXCEPT for the starting bank, whose distance goes negative
              // (i.e. wraps to the far end) when its published way precedes base_way.
              //
              // So: order by rotated bank distance, but demote the starting bank to LAST when
              // pub_way[bank_base] < base_way. It cannot simply be moved to slot MshrBankNum-1,
              // because that slot may hold another candidate; it is handled as a last-resort
              // fallback taken only when no other bank is a candidate.
              bank_base = drain_sel_base[MshrIdxW-1 -: BankIdW];
              base_way  = drain_sel_base[VictimPtrW-1:0];
              bank_cand_rot = MshrBankNum'({bank_cand, bank_cand} >> bank_base);
              bank_demote   = bank_pub_v[bank_base] && (bank_pub_w[bank_base] < base_way);
              bank_cand_eff = bank_demote ? (bank_cand_rot & ~{{(MshrBankNum-1){1'b0}}, 1'b1})
                                          : bank_cand_rot;
              bank_pfx = bank_cand_eff;
              for (int st = 1; st < MshrBankNum; st = st << 1) begin
                bank_pfx = bank_pfx | (bank_pfx << st);
              end
              bank_first = bank_pfx & ~(bank_pfx << 1);
              bank_idx   = '0;
              for (int b = 0; b < MshrBankNum; b++) begin
                if (bank_first[b]) bank_idx |= BankIdW'(b);
              end
              // Winner: first non-demoted bank, else the demoted starting bank, else nothing.
              bank_win_d   = (|bank_cand_eff) ? bank_idx : '0;
              bank_win     = BankIdW'(bank_base + bank_win_d);
              drain_have_e = |bank_cand;
              drain_win_e  = drain_have_e ? bank_pub_e[bank_win] : '0;
            end else begin
              drain_cand_rot = MshrNum'({drain_ent_cand, drain_ent_cand} >> drain_sel_base);
              drain_pfx = drain_cand_rot;
              for (int st = 1; st < MshrNum; st = st << 1) begin
                drain_pfx = drain_pfx | (drain_pfx << st);
              end
              drain_first = drain_pfx & ~(drain_pfx << 1);
              drain_idx   = '0;
              for (int b = 0; b < MshrNum; b++) begin
                if (drain_first[b]) drain_idx |= MshrIdxW'(b);
              end
              drain_have_e = |drain_ent_cand;
              drain_win_e  = drain_have_e ? MshrIdxW'(drain_sel_base + drain_idx) : '0;
            end
            if (drain_have_e) begin
              // First eligible sub-request inside the winning entry, same rotated order.
              // B1: select from the hoisted vectors rather than re-deriving the predicate from
              // mshr_d[drain_win_e]. The old form was a full-entry MshrNum:1 struct mux per
              // (tile,port) -- F8's "select elig_all[drain_win_e]" -- and is replaced by a
              // MshrMergeReqs-wide read of values already computed once per entry.
              //
              // drain_sub_ready additionally carries drain_ent_ok, which the old predicate did not
              // test. That is redundant, not a change: drain_win_e is a winning candidate, so its
              // entry-level terms already hold. Same argument as the drain2 sub-scan.
              drain_sub_cand = '0;
              for (int s = 0; s < MshrMergeReqs; s++) begin
                if (drain_sub_ready[drain_win_e][s] &&
                    (drain_sub_tile[drain_win_e][s] == tile_group_id_t'(tile_i)) &&
                    (drain_sub_port[drain_win_e][s] == port_i[RespPortIdW-1:0])) begin
                  drain_sub_cand[s] = 1'b1;
                end
              end
              drain_have_s = 1'b0; drain_win_s = '0;
              for (int k = 0; k < MshrMergeReqs; k++) begin
                drain_scan_s = SubIdxW'(drain_sel_sub_base + SubIdxW'(k));
                if (!drain_have_s && drain_sub_cand[drain_scan_s]) begin
                  drain_have_s = 1'b1; drain_win_s = drain_scan_s;
                end
              end
              if (drain_have_s) begin
                resp_sel_valid[tile_i][port_i]      = 1'b1;
                resp_sel_mshr_id[tile_i][port_i]    = mshr_id_t'(drain_win_e);
                resp_sel_subreq_idx[tile_i][port_i] = drain_win_s;   // already SubIdxW wide
              end
            end
          end
        end
      end

      // Drive responses and clear sub-requests on handshake.
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          if (resp_sel_valid[tile_i][port_i]) begin
            resp_out_valid[tile_i][port_i] = 1'b1;
            // A buffered beat is a READ response by construction: the capture gate only admits
            // responses with wen == 0 (resp_is_mshr stays 0 otherwise and the beat takes the
            // bypass path), so the stored bit could never be anything but 0.
            resp_out[tile_i][port_i].wen = 1'b0;
            resp_out[tile_i][port_i].rdata.data =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]]
                      .resp_buf[mshr_d[resp_sel_mshr_id[tile_i][port_i]].resp_buf_rd_ptr].data;
            // Re-emit beat b for THIS requester under the lane law: lane from the low
            // BurstLaneW bits, row from the rest. Not gated on PD2 -- this is the lane
            // MAPPING, not the drain width; DrainBeatsPerEntry only says how many beats may
            // leave in one cycle. Identity for a single-word entry (b = 0).
            resp_out[tile_i][port_i].rdata.core_id =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].core_id +
                tile_core_id_t'(resp_beat_offset[resp_sel_mshr_id[tile_i][port_i]][BurstLaneW-1:0]);
            resp_out[tile_i][port_i].rdata.meta_id =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].meta_id_base +
                meta_id_t'(resp_beat_offset[resp_sel_mshr_id[tile_i][port_i]] >> BurstLaneW);
            resp_out[tile_i][port_i].rdata.amo = '0;  // sub-requests are loads by construction (req_is_load)
            resp_from_mshr[tile_i][port_i] = 1'b1;
`ifndef TARGET_SYNTHESIS
            resp_mshr_id_dbg[tile_i][port_i] = resp_sel_mshr_id[tile_i][port_i];
`endif

            if (resp_out_ready[tile_i][port_i]) begin
              // F3d: record, do not write. Writing here made lane k+1 read the entry that
              // lane k had just modified -- a 32-deep chain for what is only ever a bit clear.
              bp_clr[resp_sel_mshr_id[tile_i][port_i]][
                  resp_sel_subreq_idx[tile_i][port_i]] = 1'b1;
              // Root-cause fix (WAL-verified): clear sub_req.valid on drain
              // handshake to prevent init from re-including it in next
              // cycle's beat_pending mask. Without this, MSHR delivers the
              // same response 3-5× to the tile (tile 5: 106 resps / 33 reqs
              // measured); duplicates overwhelm Spatz LSU tag tracking and
              // cause hart-stuck deadlock with EnableMshrSingleReq=1. Only
              // applied to single-beat entries: multi-beat entries need
              // valid to persist across beats so the full burst lands at
              // the same set of sub_reqs (mass-clear / full-dealloc
              // handles cleanup at end of burst).
              if (mshr_d[resp_sel_mshr_id[tile_i][port_i]].burst_len == BurstLenWidth'(1)) begin
                sv_clr[resp_sel_mshr_id[tile_i][port_i]][
                    resp_sel_subreq_idx[tile_i][port_i]] = 1'b1;
              end
            end
          end
        end
      end

      // ParityDrain second-slot service: the beat at rd_ptr+1 drains CONCURRENTLY with the head
      // on its own parity port (consecutive beats have opposite parity, so head and slot2 of one
      // entry never compete for a port). Purely additive: claims only ports the bypass and the
      // head selection left free. Serving the same (entry, sub) on both ports in one cycle is
      // the intended 2-wide delivery. Entire block const-folds out when PD2=0.
      if (PD2) begin
        // ---- Hoist the port-independent half of the second-slot test (mirror of the head-beat
        // hoist above). Computed ONCE here and shared by all NumTilesPerGroup x (ports-1) select
        // instances instead of re-evaluated in each.
        //
        // WHY THIS IS SAFE, and it is not the same argument as the head-beat one:
        // the PD2 SELECT loop below writes only drain2_* scratch and resp_sel2_*, and closes before
        // the separate DRIVE loop that clears beat_pending2. So every select iteration already
        // observes identical entry state -- the hoist is bit-identical by construction, not by an
        // appeal to the one-destination-per-sub-request invariant.
        //
        // Placed AFTER the head-beat drive on purpose: the head drive clears sub_reqs[].valid for
        // burst_len==1 entries, and hoisting to the top of the process would freeze the predicate
        // ahead of that. Here it captures exactly the state the per-port scan used to read.
        for (int e = 0; e < MshrNum; e++) begin
          // Drain2FromQ is an elaboration constant, so exactly one arm is built and there is no
          // runtime mux -- and at 0 every term below is literally the mshr_d expression it replaced.
          drain2_scan_valid[e] = Drain2FromQ ? mshr_q_valid[e] : mshr_d_valid[e];
          drain2_scan_ent[e]   = Drain2FromQ ? mshr_q[e]       : mshr_d[e];
          drain2_ent_ok[e]   = drain2_scan_valid[e] &&
                               (drain2_scan_ent[e].state == MSHR_DRAIN_RESP) &&
                               (drain2_scan_ent[e].burst_len != BurstLenWidth'(1)) &&
                               (drain2_scan_ent[e].resp_buf_cnt >= RespBufCountW'(2)) &&
                               drain2_scan_ent[e].beat2_armed;
          // The parity port comes from the second slot's beat offset, which must be derived from
          // the SAME view as the eligibility test above -- resp_beat_offset2 is mshr_d-based and
          // would drag the whole d-side cone back in through the port select alone.
          drain2_rd_ptr[e]   = (RespBufWords > 1) ?
              ((drain2_scan_ent[e].resp_buf_rd_ptr == RespBufPtrW'(RespBufWords - 1))
                   ? '0 : RespBufPtrW'(drain2_scan_ent[e].resp_buf_rd_ptr + 1'b1))
              : '0;
          drain2_beat_off[e] = drain2_scan_ent[e].resp_buf[drain2_rd_ptr[e]].beat_off;
          // Entry-level, not per-sub-request: both beats of an entry share one parity port.
          drain2_sub_port[e] = RespPortIdW'(1) +
              RespPortIdW'(Drain2FromQ ? drain2_beat_off[e][0] : resp_beat_offset2[e][0]);
          for (int s = 0; s < MshrMergeReqs; s++) begin
            drain2_sub_ready[e][s] = drain2_ent_ok[e] && drain2_scan_ent[e].sub_reqs[s].valid &&
                                     drain2_scan_ent[e].beat_pending2[s];
            drain2_sub_tile[e][s]  = drain2_scan_ent[e].sub_reqs[s].tile_id;
          end
        end
        for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
          for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
            resp_sel2_valid[tile_i][port_i]      = 1'b0;
            resp_sel2_mshr_id[tile_i][port_i]    = '0;
            resp_sel2_subreq_idx[tile_i][port_i] = '0;
            if (!port_taken[tile_i][port_i] && !resp_sel_valid[tile_i][port_i]) begin
              drain2_base     = EnableRrFairness ? MshrIdxW'(drain_mshr_rr_q) : '0;
              // Hoisted: the sub-request base does not depend on kk/ks, but was previously
              // re-evaluated inside the inner loop on every unrolled iteration.
              drain2_sub_base = EnableRrFairness ? SubIdxW'(subreq_rr_q) : '0;
              // Entry candidates for the second slot: does this entry offer a beat2 sub-request for
              // THIS port? Built with CONSTANT indices, so no entry-array mux is needed here.
              //
              // This replaced a rotated nested linear scan -- MshrNum outer x MshrMergeReqs inner,
              // guarded by !resp_sel2_valid[tile_i][port_i], i.e. a 256-deep sequential priority
              // chain per (tile, resp port), 32 of them at 8x8. Worse, its outer loop indexed
              // mshr_d[drain2_mshr_i] with a VARIABLE base, so each of the MshrNum iterations was
              // its own MshrNum:1 mux over a full entry.
              //
              // Equivalent by construction: the old nested scan took the first (entry, sub-request)
              // pair in rotated order, which is exactly the first entry offering any eligible
              // sub-request followed by the first eligible sub-request inside it. Same shape as the
              // head-beat selection above, and the same exhaustively-proven prefix encode.
              // PPA: hoisted, like the head-beat scan -- the entry-invariant terms and the
              // second-slot destination port are precomputed once above, outside these loops.
              // This scan is the SECOND 256-pair sweep inside the same (tile,port) loops, so the
              // module was doing 512 per instance -- 16,384 per group, not 8,192.
              //
              // An earlier revision of this comment claimed the hoist was UNSAFE here, on the
              // grounds that "the loop CLEARS beat_pending2 as it goes". It does not: the clear
              // lives in the DRIVE loop, which is a SEPARATE (tile,port) loop that begins only
              // after this select loop has closed. The select loop writes nothing this predicate
              // reads, so all iterations see identical state. Verified by enumerating every
              // left-hand side in the select loop body.
              drain2_cand = '0;
              for (int e = 0; e < MshrNum; e++) begin
                for (int s = 0; s < MshrMergeReqs; s++) begin
                  if (drain2_sub_ready[e][s] &&
                      (drain2_sub_tile[e][s] == tile_group_id_t'(tile_i)) &&
                      (drain2_sub_port[e] == port_i[RespPortIdW-1:0])) begin
                    drain2_cand[e] = 1'b1;
                  end
                end
              end
              // B1: hi/lo split about the rotation base, then isolate the lowest set bit of each.
              // hi holds candidates at-or-above the base, so its lowest bit is the first candidate
              // at-or-after it; if hi is empty the scan wraps and lo's lowest bit wins. Identical
              // selection to the rotate-then-prefix form, and the winner is already absolute.
              for (int e = 0; e < MshrNum; e++) begin
                drain2_rr_mask[e] = EnableRrFairness ? (MshrIdxW'(e) >= drain2_base) : 1'b1;
              end
              drain2_hi    = drain2_cand &  drain2_rr_mask;
              drain2_lo    = drain2_cand & ~drain2_rr_mask;
              drain2_first = (drain2_hi != '0) ? (drain2_hi & (~drain2_hi + MshrNum'(1)))
                                               : (drain2_lo & (~drain2_lo + MshrNum'(1)));
              drain2_idx   = '0;
              for (int b = 0; b < MshrNum; b++) begin
                if (drain2_first[b]) drain2_idx |= MshrIdxW'(b);
              end
              if (|drain2_cand) begin
                drain2_mshr_i = drain2_idx;   // already absolute -- no base add
                // First eligible sub-request inside the winning entry, same rotated order.
                for (int ks = 0; ks < MshrMergeReqs; ks++) begin
                  drain2_s = SubIdxW'(drain2_sub_base + SubIdxW'(ks));
                  // Reuse the hoisted vectors instead of re-reading mshr_d[drain2_mshr_i] -- a 4-bit
                  // select in place of a full-entry MshrNum:1 struct mux (F8's second half).
                  if (!resp_sel2_valid[tile_i][port_i] &&
                      drain2_sub_ready[drain2_mshr_i][drain2_s] &&
                      (drain2_sub_tile[drain2_mshr_i][drain2_s] == tile_group_id_t'(tile_i)) &&
                      (drain2_sub_port[drain2_mshr_i] == port_i[RespPortIdW-1:0])) begin
                    resp_sel2_valid[tile_i][port_i]      = 1'b1;
                    resp_sel2_mshr_id[tile_i][port_i]    = mshr_id_t'(drain2_mshr_i);
                    resp_sel2_subreq_idx[tile_i][port_i] = drain2_s;   // already SubIdxW wide
                  end
                end
              end
            end
          end
        end
        // Drive the selected second-slot beats and clear their pending bits on handshake.
        for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
          for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
            if (resp_sel2_valid[tile_i][port_i]) begin
              drain2_sel_e2 = resp_sel2_mshr_id[tile_i][port_i];
              resp_out_valid[tile_i][port_i] = 1'b1;
              resp_out[tile_i][port_i].wen = 1'b0;  // buffered beats are reads by construction (capture gate)
              resp_out[tile_i][port_i].rdata.data =
                  mshr_d[drain2_sel_e2].resp_buf[resp_rd_ptr2[drain2_sel_e2]].data;
              // Same lane law as the head slot.
              resp_out[tile_i][port_i].rdata.core_id =
                  mshr_d[drain2_sel_e2].sub_reqs[resp_sel2_subreq_idx[tile_i][port_i]].core_id +
                  tile_core_id_t'(resp_beat_offset2[drain2_sel_e2][BurstLaneW-1:0]);
              resp_out[tile_i][port_i].rdata.meta_id =
                  mshr_d[drain2_sel_e2]
                      .sub_reqs[resp_sel2_subreq_idx[tile_i][port_i]].meta_id_base +
                  meta_id_t'(resp_beat_offset2[drain2_sel_e2] >> BurstLaneW);
              resp_out[tile_i][port_i].rdata.amo = '0;  // sub-requests are loads by construction (req_is_load)
              resp_from_mshr[tile_i][port_i] = 1'b1;
`ifndef TARGET_SYNTHESIS
              resp_mshr_id_dbg[tile_i][port_i] = drain2_sel_e2;
`endif
              port_taken[tile_i][port_i] = 1'b1;
              if (resp_out_ready[tile_i][port_i]) begin
                bp2_clr[drain2_sel_e2][resp_sel2_subreq_idx[tile_i][port_i]] = 1'b1;
              end
            end
          end
        end
      end else begin
        resp_sel2_valid      = '0;
        resp_sel2_mshr_id    = '0;
        resp_sel2_subreq_idx = '0;
      end

    end

    // F3d: apply the recorded clears, once per entry. Both drive loops have closed, so this sees
    // every request from both, and because they are bit clears the order they were recorded in
    // cannot matter. Placed before the finalize pass, which is where the sequential writes landed.
    for (int e = 0; e < MshrNum; e++) begin
      mshr_d[e].beat_pending  = mshr_d[e].beat_pending  & ~bp_clr[e];
      mshr_d[e].beat_pending2 = mshr_d[e].beat_pending2 & ~bp2_clr[e];
      for (int s = 0; s < MshrMergeReqs; s++) begin
        if (sv_clr[e][s]) mshr_d[e].sub_reqs[s].valid = 1'b0;
      end
    end

    // Finalize response draining per beat.
    for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      resp_head_beat_pending[mshr_i] = 1'b0;
      resp_cnt_after_pop[mshr_i] = mshr_d[mshr_i].resp_buf_cnt;
      if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].resp_buf_cnt != '0) &&
          (mshr_d[mshr_i].state == MSHR_DRAIN_RESP)) begin
        resp_head_beat_pending[mshr_i] = |mshr_d[mshr_i].beat_pending;
        if (!resp_head_beat_pending[mshr_i]) begin
          if ((mshr_d[mshr_i].beats_left == BurstLenWidth'(1)) &&
              EnableRespCache && !amo_invalidate &&
              mshr_d[mshr_i].cacheable &&
              (mshr_d[mshr_i].burst_len == BurstLenWidth'(1))) begin
            // Keep final drained head response as cache data (do not pop).
            // Guarded by !amo_invalidate: a single-word load finalizing in the
            // same cycle as an AMO must NOT cache its (now stale, pre-AMO) value.
            // The AMO-invalidate sweep above runs earlier in this always_comb and
            // only clears entries that are already MSHR_CACHED, so without this
            // guard a freshly-cached entry would escape it and serve stale data to
            // a later load. The else branch instead pops+deallocates this entry
            // (the response was already delivered to the requester this cycle).
            for (int s = 0; s < MshrMergeReqs; s++) begin
              mshr_d[mshr_i].sub_reqs[s].valid = 1'b0;
            end
            mshr_d[mshr_i].sub_reqs_num = '0;
            mshr_d[mshr_i].beat_pending = '0;
`ifndef TARGET_SYNTHESIS
            mshr_d[mshr_i].beat_done[resp_beat_offset[mshr_i]] = 1'b1;
`endif
            mshr_d[mshr_i].beats_left = '0;
            mshr_d[mshr_i].state = MSHR_CACHED;
            // Re-arm the serve-target timeout for the cache-resident phase: a line whose target is
            // never reached would otherwise never self-invalidate, and with CacheReclaimable=0 it
            // is not an allocation victim either -- so its way would be pinned for good. A cache
            // HIT re-enters DRAIN_RESP and returns here, which refreshes the window, so a
            // frequently-used line keeps its way and only an idle one ages out.
            mshr_d[mshr_i].hold_cnt = hold_ticks(cfg_cache_hold_ticks_src);
          end else begin
            // Pop the drained head beat.
            if (mshr_d[mshr_i].resp_buf_cnt != '0) begin
              if (RespBufWords > 1) begin
                if (mshr_d[mshr_i].resp_buf_rd_ptr == RespBufPtrW'(RespBufWords - 1)) begin
                  mshr_d[mshr_i].resp_buf_rd_ptr = '0;
                end else begin
                  mshr_d[mshr_i].resp_buf_rd_ptr = mshr_d[mshr_i].resp_buf_rd_ptr + 1'b1;
                end
              end
              resp_cnt_after_pop[mshr_i] = mshr_d[mshr_i].resp_buf_cnt - 1'b1;
              mshr_d[mshr_i].resp_buf_cnt = resp_cnt_after_pop[mshr_i];
            end

            mshr_d[mshr_i].beat_pending = '0;
`ifndef TARGET_SYNTHESIS
            mshr_d[mshr_i].beat_done[resp_beat_offset[mshr_i]] = 1'b1;
`endif
            if (mshr_d[mshr_i].beats_left == BurstLenWidth'(1)) begin
              mshr_d_valid[mshr_i] = 1'b0;
              // F1: retire by dropping valid only (see the first retire site for why).
            end else begin
              if (mshr_d[mshr_i].beats_left != '0) begin
                mshr_d[mshr_i].beats_left = mshr_d[mshr_i].beats_left - BurstLenWidth'(1);
              end
              if (resp_cnt_after_pop[mshr_i] != '0) begin
                mshr_d[mshr_i].state = MSHR_DRAIN_RESP;
              end else begin
                mshr_d[mshr_i].state = MSHR_WAIT_RESP;
              end
            end

            // ParityDrain: resolve the second slot after the head pop. The slot indices just
            // shifted, so its one-shot state is consumed here either way:
            //  - fully served -> pop it too (2 beats retired this cycle);
            //  - partially served -> PROMOTE its (nonzero) mask to beat_pending, so the
            //    per-cycle head arm skips it and served subscribers are never re-delivered.
            if (PD2 && mshr_d_valid[mshr_i] &&
                (mshr_d[mshr_i].burst_len != BurstLenWidth'(1)) &&
                mshr_d[mshr_i].beat2_armed) begin
              if ((mshr_d[mshr_i].beat_pending2 == '0) &&
                  (mshr_d[mshr_i].resp_buf_cnt != '0)) begin
                // Pop the (already fully served) promoted beat as well.
                if (RespBufWords > 1) begin
                  if (mshr_d[mshr_i].resp_buf_rd_ptr == RespBufPtrW'(RespBufWords - 1)) begin
                    mshr_d[mshr_i].resp_buf_rd_ptr = '0;
                  end else begin
                    mshr_d[mshr_i].resp_buf_rd_ptr = mshr_d[mshr_i].resp_buf_rd_ptr + 1'b1;
                  end
                end
                mshr_d[mshr_i].resp_buf_cnt = mshr_d[mshr_i].resp_buf_cnt - 1'b1;
`ifndef TARGET_SYNTHESIS
                mshr_d[mshr_i].beat_done[resp_beat_offset2[mshr_i]] = 1'b1;
`endif
                if (mshr_d[mshr_i].beats_left == BurstLenWidth'(1)) begin
                  mshr_d_valid[mshr_i] = 1'b0;
                  // F1: retire by dropping valid only (see the first retire site for why).
                end else begin
                  if (mshr_d[mshr_i].beats_left != '0) begin
                    mshr_d[mshr_i].beats_left = mshr_d[mshr_i].beats_left - BurstLenWidth'(1);
                  end
                  if (mshr_d[mshr_i].resp_buf_cnt != '0) begin
                    mshr_d[mshr_i].state = MSHR_DRAIN_RESP;
                  end else begin
                    mshr_d[mshr_i].state = MSHR_WAIT_RESP;
                  end
                end
              end else begin
                mshr_d[mshr_i].beat_pending = mshr_d[mshr_i].beat_pending2;
              end
              if (mshr_d_valid[mshr_i]) begin
                mshr_d[mshr_i].beat_pending2 = '0;
                mshr_d[mshr_i].beat2_armed   = 1'b0;
              end
            end
          end
        end
      end
    end
  end

  // pragma translate_off
  `ifndef VERILATOR
  generate
    if (EnableStats) begin : gen_stats
      // ------------------------------------------------------------------
      // Root-cause instrumentation (whole-run accumulators, one dump at final):
      //  - per-bank alloc / bank-full histograms: is the way-conflict pressure
      //    concentrated in a few hot banks or uniform?
      //  - per-entry outcome at free: how many requesters did one fetch actually
      //    serve (sub_reqs_num at dealloc; + cache hits for singles) -- the
      //    direct partner-capture measurement, split single/burst.
      //  - door stall cycles on same-address drain / meta conflict: the price
      //    too-late partners pay serializing behind the leader's drain.
      //  - hold-the-fetch release reason: early (subs target) vs timeout,
      //    split single/burst. (timeout also includes rare lane-blocked-past-
      //    expiry releases.)
      // All increments are staged combinationally (blocking accumulation) so
      // same-cycle events on multiple ports/entries are not lost to
      // last-write-wins nonblocking updates.
      // ------------------------------------------------------------------
      logic [63:0] stat_bank_alloc_hist [MshrBankNum];
      logic [63:0] stat_bank_ovf_hist   [MshrBankNum];
      logic [63:0] stat_free_s_subs1, stat_free_s_subs2p, stat_free_s_subs_sum, stat_free_s_cachehit_sum;
      logic [63:0] stat_free_b_subs1, stat_free_b_subs2p, stat_free_b_subs_sum;
      logic [63:0] stat_drain_stall_s, stat_drain_stall_b;
      logic [63:0] stat_hold_early_s, stat_hold_early_b, stat_hold_to_s, stat_hold_to_b;
      logic [MshrNum-1:0] stat_issued_shadow_q;
      logic [7:0]  rc_bank_alloc_inc [MshrBankNum];
      logic [7:0]  rc_bank_ovf_inc   [MshrBankNum];
      logic [7:0]  rc_drain_stall_s_inc, rc_drain_stall_b_inc;
      logic [7:0]  rc_free_s_subs1_inc, rc_free_s_subs2p_inc, rc_free_b_subs1_inc, rc_free_b_subs2p_inc;
      logic [15:0] rc_free_s_subs_sum_inc, rc_free_b_subs_sum_inc;
      logic [31:0] rc_free_s_cachehit_inc;
      logic [7:0]  rc_hold_early_s_inc, rc_hold_early_b_inc, rc_hold_to_s_inc, rc_hold_to_b_inc;

      always_comb begin
        for (int b = 0; b < MshrBankNum; b++) begin
          rc_bank_alloc_inc[b] = '0;
          rc_bank_ovf_inc[b]   = '0;
        end
        rc_drain_stall_s_inc = '0; rc_drain_stall_b_inc = '0;
        rc_free_s_subs1_inc = '0; rc_free_s_subs2p_inc = '0; rc_free_s_subs_sum_inc = '0;
        rc_free_b_subs1_inc = '0; rc_free_b_subs2p_inc = '0; rc_free_b_subs_sum_inc = '0;
        rc_free_s_cachehit_inc = '0;
        rc_hold_early_s_inc = '0; rc_hold_early_b_inc = '0; rc_hold_to_s_inc = '0; rc_hold_to_b_inc = '0;
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
            if (req_in_valid[t][p] && req_can_merge[t][p]) begin
              if (req_in_ready[t][p] && !req_merge_valid[t][p]) begin
                if (req_alloc_found[t][p]) begin
                  rc_bank_alloc_inc[req_bank[t][p]] = rc_bank_alloc_inc[req_bank[t][p]] + 1'b1;
                end else begin
                  rc_bank_ovf_inc[req_bank[t][p]] = rc_bank_ovf_inc[req_bank[t][p]] + 1'b1;
                end
              end
              if (req_addr_hit_drain[t][p] || req_meta_conflict[t][p]) begin
                if (req_len[t][p] == BurstLenWidth'(1)) begin
                  rc_drain_stall_s_inc = rc_drain_stall_s_inc + 1'b1;
                end else begin
                  rc_drain_stall_b_inc = rc_drain_stall_b_inc + 1'b1;
                end
              end
            end
          end
        end
        for (int e = 0; e < MshrNum; e++) begin
          if (mshr_q_valid[e] && !mshr_d_valid[e]) begin
            if (mshr_q[e].burst_len == BurstLenWidth'(1)) begin
              if (mshr_q[e].sub_reqs_num <= SubReqCountW'(1)) rc_free_s_subs1_inc = rc_free_s_subs1_inc + 1'b1;
              else                                            rc_free_s_subs2p_inc = rc_free_s_subs2p_inc + 1'b1;
              rc_free_s_subs_sum_inc = rc_free_s_subs_sum_inc + 16'(mshr_q[e].sub_reqs_num);
`ifndef TARGET_SYNTHESIS
              rc_free_s_cachehit_inc = rc_free_s_cachehit_inc + mshr_q[e].cache_hit_cnt;
`endif
            end else begin
              if (mshr_q[e].sub_reqs_num <= SubReqCountW'(1)) rc_free_b_subs1_inc = rc_free_b_subs1_inc + 1'b1;
              else                                            rc_free_b_subs2p_inc = rc_free_b_subs2p_inc + 1'b1;
              rc_free_b_subs_sum_inc = rc_free_b_subs_sum_inc + 16'(mshr_q[e].sub_reqs_num);
            end
          end
          // Only classify entries whose OWN per-type window is non-zero. A 0-window class is issued
          // at birth (issued=1, hold_cnt=0) and was never held, so counting it here reports a
          // phantom "timeout" for every such request -- e.g. hold_window_single=0 with
          // hold_window_burst=63 made HoldWindowMax!=0 and mislabelled all 8k scalar issues as
          // timeout_single. (Same bug class as the mshr_issue_timeout_dbg wave signals, fixed there.)
          if ((HoldWindowMax != 0) && mshr_q_valid[e] && mshr_q[e].issued && !stat_issued_shadow_q[e]) begin
            if (mshr_q[e].burst_len == BurstLenWidth'(1)) begin
              if (cfg_hold_window_single != 0) begin
                if (mshr_q[e].hold_cnt == '0) rc_hold_to_s_inc    = rc_hold_to_s_inc + 1'b1;
                else                          rc_hold_early_s_inc = rc_hold_early_s_inc + 1'b1;
              end
            end else begin
              if (cfg_hold_window_burst != 0) begin
                if (mshr_q[e].hold_cnt == '0) rc_hold_to_b_inc    = rc_hold_to_b_inc + 1'b1;
                else                          rc_hold_early_b_inc = rc_hold_early_b_inc + 1'b1;
              end
            end
          end
        end
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          for (int b = 0; b < MshrBankNum; b++) begin
            stat_bank_alloc_hist[b] <= '0;
            stat_bank_ovf_hist[b]   <= '0;
          end
          stat_free_s_subs1 <= '0; stat_free_s_subs2p <= '0; stat_free_s_subs_sum <= '0;
          stat_free_s_cachehit_sum <= '0;
          stat_free_b_subs1 <= '0; stat_free_b_subs2p <= '0; stat_free_b_subs_sum <= '0;
          stat_drain_stall_s <= '0; stat_drain_stall_b <= '0;
          stat_hold_early_s <= '0; stat_hold_early_b <= '0; stat_hold_to_s <= '0; stat_hold_to_b <= '0;
          stat_issued_shadow_q <= '0;
        end else begin
          for (int e = 0; e < MshrNum; e++) begin
            stat_issued_shadow_q[e] <= mshr_q_valid[e] && mshr_q[e].issued;
          end
          if (csr_trace_any_i) begin
            for (int b = 0; b < MshrBankNum; b++) begin
              stat_bank_alloc_hist[b] <= stat_bank_alloc_hist[b] + 64'(rc_bank_alloc_inc[b]);
              stat_bank_ovf_hist[b]   <= stat_bank_ovf_hist[b]   + 64'(rc_bank_ovf_inc[b]);
            end
            stat_free_s_subs1        <= stat_free_s_subs1        + 64'(rc_free_s_subs1_inc);
            stat_free_s_subs2p       <= stat_free_s_subs2p       + 64'(rc_free_s_subs2p_inc);
            stat_free_s_subs_sum     <= stat_free_s_subs_sum     + 64'(rc_free_s_subs_sum_inc);
            stat_free_s_cachehit_sum <= stat_free_s_cachehit_sum + 64'(rc_free_s_cachehit_inc);
            stat_free_b_subs1        <= stat_free_b_subs1        + 64'(rc_free_b_subs1_inc);
            stat_free_b_subs2p       <= stat_free_b_subs2p       + 64'(rc_free_b_subs2p_inc);
            stat_free_b_subs_sum     <= stat_free_b_subs_sum     + 64'(rc_free_b_subs_sum_inc);
            stat_drain_stall_s       <= stat_drain_stall_s       + 64'(rc_drain_stall_s_inc);
            stat_drain_stall_b       <= stat_drain_stall_b       + 64'(rc_drain_stall_b_inc);
            stat_hold_early_s        <= stat_hold_early_s        + 64'(rc_hold_early_s_inc);
            stat_hold_early_b        <= stat_hold_early_b        + 64'(rc_hold_early_b_inc);
            stat_hold_to_s           <= stat_hold_to_s           + 64'(rc_hold_to_s_inc);
            stat_hold_to_b           <= stat_hold_to_b           + 64'(rc_hold_to_b_inc);
          end
        end
      end

      // Configuration summary at start of simulation.
      initial begin
        $display("[%0t] %m MSHR cfg: NumGroups=%0d NumTilesPerGroup=%0d NumRemoteReqPortsPerTile=%0d NumRemoteRespPortsPerTile=%0d",
                 $time, NumGroups, NumTilesPerGroup, NumRemoteReqPortsPerTile, NumRemoteRespPortsPerTile);
        $display("[%0t] %m MSHR cfg: MshrNum=%0d MshrMergeWords=%0d MshrMergeReqs=%0d RespBufWords=%0d DrainMultiPort=%0d EnableRespCache=%0d EnableStats=%0d StatsPeriod=%0d",
                 $time, MshrNum, MshrMergeWords, MshrMergeReqs, RespBufWords, DrainMultiPort, EnableRespCache,
                 EnableStats, StatsPeriod);
        $display("[%0t] %m MSHR cfg: MshrFullBurstWords=%0d EnableSingle=%0d EnableNonFullBurst=%0d EnableFullBurst=%0d",
                 $time, MshrFullBurstWords, EnableMshrSingleReq, EnableMshrNonFullBurstReq,
                 EnableMshrFullBurstReq);
        // Print the EFFECTIVE policy bit, not the localparam: with MshrCfgRuntime=1 the value in
        // force comes from CSR 11, and an ELF that predates that CSR leaves the reset value
        // standing. Printing the localparam would have shown 1 while the design ran with 0 --
        // exactly the silent mismatch that wasted a GUI elaboration on 2026-08-21.
        $display("[%0t] %m MSHR cfg: BankfullBackpressure=%0d (0=bypass on full bank, 1=stall)",
                 $time, cfg_bankfull_bp);
        $display("[%0t] %m MSHR cfg: SpillReqIn=%0d SpillReqOut=%0d SpillRespIn=%0d SpillRespOut=%0d",
                 $time, SpillReqIn, SpillReqOut, SpillRespIn, SpillRespOut);
      end

      task automatic print_stats(input string tag,
                                 input logic [63-1:0] cycles,
                                 input logic [63-1:0] mshr_valid_acc,
                                 input logic [63-1:0] mshr_valid_uncached_acc,
                                 input logic [63-1:0] subreq_valid_acc,
                                 input logic [63-1:0] mshr_max_valid,
                                 input logic [63-1:0] subreq_max_valid,
                                 input logic [63-1:0] req_accept,
                                 input logic [63-1:0] req_accept_single,
                                 input logic [63-1:0] req_accept_burst,
                                 input logic [63-1:0] req_merge,
                                 input logic [63-1:0] req_alloc,
                                 input logic [63-1:0] req_bypass,
                                 input logic [63-1:0] req_mshr_overflow,
                                 input logic [63-1:0] req_subreq_overflow,
                                 input logic [63-1:0] resp_mshr,
                                 input logic [63-1:0] resp_bypass,
                                 input logic [63-1:0] cache_valid_acc,
                                 input logic [63-1:0] cache_max_valid,
                                 input logic [63-1:0] mshr_max_valid_uncached_in,
                                 input logic [63-1:0] cache_hit,
                                 input logic [63-1:0] cache_fill,
                                 input logic [63-1:0] cache_evict,
                                 input logic [63-1:0] cache_store_update,
                                 input logic [63-1:0] cache_amo_inval,
                                 input logic [63-1:0] cache_self_inval);
        real avg_mshr_valid;
        real avg_mshr_util;
        real avg_subreq_valid;
        real avg_subreq_util;
        real avg_subreq_per_mshr;
        real avg_cache_valid;
        real cache_hit_rate;
        real avg_mshr_valid_uncached;
        real avg_mshr_util_uncached;
        real mshr_max_valid_uncached;

        if (cycles != 0) begin
          avg_mshr_valid = $itor(mshr_valid_acc) / $itor(cycles);
          avg_mshr_util = $itor(mshr_valid_acc) / ($itor(cycles) * $itor(MshrNum));
          avg_subreq_valid = $itor(subreq_valid_acc) / $itor(cycles);
          if ((MshrNum * MshrMergeReqs) != 0) begin
            avg_subreq_util = $itor(subreq_valid_acc) /
                              ($itor(cycles) * $itor(MshrNum) * $itor(MshrMergeReqs));
          end else begin
            avg_subreq_util = 0.0;
          end
          if ((EnableRespCache ? mshr_valid_uncached_acc : mshr_valid_acc) != 0) begin
            avg_subreq_per_mshr = $itor(subreq_valid_acc) /
                                  $itor(EnableRespCache ? mshr_valid_uncached_acc : mshr_valid_acc);
          end else begin
            avg_subreq_per_mshr = 0.0;
          end
          avg_cache_valid = $itor(cache_valid_acc) / $itor(cycles);
          avg_mshr_valid_uncached = avg_mshr_valid - avg_cache_valid;
          if (MshrNum != 0) begin
            avg_mshr_util_uncached = avg_mshr_valid_uncached / $itor(MshrNum);
          end else begin
            avg_mshr_util_uncached = 0.0;
          end
          mshr_max_valid_uncached = $itor(mshr_max_valid_uncached_in);
          if ((cache_hit + cache_evict) != 0) begin
            cache_hit_rate = $itor(cache_hit) / $itor(cache_hit + cache_evict);
          end else begin
            cache_hit_rate = 0.0;
          end
        end else begin
          avg_mshr_valid = 0.0;
          avg_mshr_util = 0.0;
          avg_subreq_valid = 0.0;
          avg_subreq_util = 0.0;
          avg_subreq_per_mshr = 0.0;
          avg_cache_valid = 0.0;
          cache_hit_rate = 0.0;
          avg_mshr_valid_uncached = 0.0;
          avg_mshr_util_uncached = 0.0;
          mshr_max_valid_uncached = 0.0;
        end

        $display("[%0t] %m MSHR stats (%s):", $time, tag);
        $display("  cycles=%0d", cycles);
        $display("  mshr_valid_avg=%0f mshr_valid_max=%0d mshr_util_avg=%0f",
                 avg_mshr_valid, mshr_max_valid, avg_mshr_util);
        if (EnableRespCache) begin
          $display("  mshr_valid_uncached_avg=%0f mshr_valid_uncached_max=%0f mshr_util_uncached_avg=%0f",
                   avg_mshr_valid_uncached, mshr_max_valid_uncached, avg_mshr_util_uncached);
        end
        $display("  subreq_valid_avg=%0f subreq_valid_max=%0d subreq_util_avg=%0f subreq_per_valid_mshr_avg=%0f",
                 avg_subreq_valid, subreq_max_valid, avg_subreq_util, avg_subreq_per_mshr);
        $display("  reqs: accepted=%0d (single=%0d burst=%0d) merged=%0d alloc=%0d bypass=%0d mshr_overflow=%0d subreq_overflow=%0d",
                 req_accept, req_accept_single, req_accept_burst, req_merge, req_alloc, req_bypass,
                 req_mshr_overflow, req_subreq_overflow);
        $display("  resps: from_mshr=%0d from_bypass=%0d",
                 resp_mshr, resp_bypass);
        if (EnableRespCache) begin
          $display("  timeouts: resp_hold=%0d cache_aged=%0d issue=%0d   bankfull_bypass=%0d",
                   mshr_resp_hold_timeout_cnt_dbg, mshr_cache_timeout_cnt_dbg,
                   mshr_issue_timeout_cnt_dbg, req_bankfull_bypass_cnt_dbg);
          $display("  cache: valid_avg=%0f valid_max=%0d hit=%0d fill=%0d evict=%0d store_update=%0d amo_inval=%0d self_inval=%0d",
                   avg_cache_valid, cache_max_valid, cache_hit, cache_fill, cache_evict,
                   cache_store_update, cache_amo_inval, cache_self_inval);
          $display("  cache: hit_rate(hit/(hit+evict))=%0f", cache_hit_rate);
        end
      endtask

      always_comb begin
        stat_mshr_valid_cycle = '0;
        stat_cache_valid_cycle = '0;
        stat_mshr_valid_uncached_cycle = '0;
        stat_subreq_valid_cycle = '0;
        for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
          if (mshr_q_valid[mshr_i]) begin
            stat_mshr_valid_cycle = stat_mshr_valid_cycle + 1'b1;
            if (mshr_q[mshr_i].state == MSHR_CACHED) begin
              stat_cache_valid_cycle = stat_cache_valid_cycle + 1'b1;
            end else begin
              stat_subreq_valid_cycle =
                  stat_subreq_valid_cycle + mshr_q[mshr_i].sub_reqs_num;
            end
          end
        end
        if (stat_mshr_valid_cycle >= stat_cache_valid_cycle) begin
          stat_mshr_valid_uncached_cycle =
              stat_mshr_valid_cycle - stat_cache_valid_cycle;
        end else begin
          stat_mshr_valid_uncached_cycle = '0;
        end

        stat_req_accept_cycle = '0;
        stat_req_accept_single_cycle = '0;
        stat_req_accept_burst_cycle = '0;
        stat_req_merge_cycle = '0;
        stat_req_merge_single_cycle = '0;
        stat_req_merge_burst_cycle = '0;
        stat_req_alloc_cycle = '0;
        stat_req_alloc_single_cycle = '0;
        stat_req_alloc_burst_cycle = '0;
        stat_req_bypass_cycle = '0;
        stat_req_mshr_overflow_cycle = '0;
        stat_req_subreq_overflow_cycle = '0;
        for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
          for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
            stat_req_subreq_full_match[tile_i][port_i] = 1'b0;
            if (req_in_valid[tile_i][port_i] && req_can_merge[tile_i][port_i]) begin
              for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
                if (!stat_req_subreq_full_match[tile_i][port_i] &&
                    mshr_q_valid[mshr_i] &&
                    ((mshr_q[mshr_i].state == MSHR_WAIT_RESP) ||
                     (mshr_q[mshr_i].state == MSHR_RESP_HOLD)) &&
                    !mshr_resp_seen_now[mshr_i] &&
                    !mshr_resp_inflight[mshr_i] &&
                    (mshr_q[mshr_i].base_addr == req_addr_key[tile_i][port_i]) &&
                    (mshr_q[mshr_i].tgt_group_id == req_in[tile_i][port_i].tgt_group_id) &&
                    (mshr_q[mshr_i].burst_len == req_len[tile_i][port_i]) &&
                    ((mshr_q[mshr_i].sub_reqs_num + SubReqCountW'(1)) > MshrMergeReqs)) begin
                  stat_req_subreq_full_match[tile_i][port_i] = 1'b1;
                end
              end
            end

            if (req_in_valid[tile_i][port_i] && req_in_ready[tile_i][port_i]) begin
              stat_req_accept_cycle = stat_req_accept_cycle + 1'b1;
              if (req_len[tile_i][port_i] == BurstLenWidth'(1)) begin
                stat_req_accept_single_cycle = stat_req_accept_single_cycle + 1'b1;
              end else begin
                stat_req_accept_burst_cycle = stat_req_accept_burst_cycle + 1'b1;
              end
              if (req_merge_valid[tile_i][port_i]) begin
                stat_req_merge_cycle = stat_req_merge_cycle + 1'b1;
                if (req_len[tile_i][port_i] == BurstLenWidth'(1)) begin
                  stat_req_merge_single_cycle = stat_req_merge_single_cycle + 1'b1;
                end else begin
                  stat_req_merge_burst_cycle = stat_req_merge_burst_cycle + 1'b1;
                end
              end else begin
                stat_req_bypass_cycle = stat_req_bypass_cycle + 1'b1;
                if (req_can_merge[tile_i][port_i]) begin
                  if (req_alloc_found[tile_i][port_i]) begin
                    stat_req_alloc_cycle = stat_req_alloc_cycle + 1'b1;
                    if (req_len[tile_i][port_i] == BurstLenWidth'(1)) begin
                      stat_req_alloc_single_cycle = stat_req_alloc_single_cycle + 1'b1;
                    end else begin
                      stat_req_alloc_burst_cycle = stat_req_alloc_burst_cycle + 1'b1;
                    end
                  end else begin
                    stat_req_mshr_overflow_cycle = stat_req_mshr_overflow_cycle + 1'b1;
                  end
                end
              end
              if (req_can_merge[tile_i][port_i] &&
                  stat_req_subreq_full_match[tile_i][port_i]) begin
                stat_req_subreq_overflow_cycle = stat_req_subreq_overflow_cycle + 1'b1;
              end
            end
          end
        end

        stat_resp_mshr_cycle = '0;
        stat_resp_bypass_cycle = '0;
        stat_cache_hit_cycle = '0;
        stat_cache_fill_cycle = '0;
        stat_cache_evict_cycle = '0;
        stat_cache_store_update_cycle = '0;
        stat_cache_amo_inval_cycle = '0;
        stat_cache_self_inval_cycle = '0;
        for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
          for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
            if (resp_out_valid[tile_i][port_i] && resp_out_ready[tile_i][port_i]) begin
              if (resp_from_mshr[tile_i][port_i]) begin
                stat_resp_mshr_cycle = stat_resp_mshr_cycle + 1'b1;
              end
              if (resp_from_bypass[tile_i][port_i]) begin
                stat_resp_bypass_cycle = stat_resp_bypass_cycle + 1'b1;
              end
            end
          end
        end

        if (EnableRespCache) begin
          for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
            for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
              if (req_in_valid[tile_i][port_i] &&
                  req_in_ready[tile_i][port_i] &&
                  req_hit_mshr_sel_valid[tile_i][port_i] &&
                  (mshr_q[req_hit_mshr_sel_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                stat_cache_hit_cycle = stat_cache_hit_cycle + 1'b1;
              end
              if (req_in_valid[tile_i][port_i] &&
                  req_in_ready[tile_i][port_i] &&
                  req_can_merge[tile_i][port_i] &&
                  !req_merge_valid[tile_i][port_i] &&
                  req_alloc_found[tile_i][port_i] &&
                  (mshr_q[req_alloc_found_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                stat_cache_evict_cycle = stat_cache_evict_cycle + 1'b1;
              end
              if (req_in_valid[tile_i][port_i] &&
                  req_in_ready[tile_i][port_i] &&
                  req_is_store[tile_i][port_i] &&
                  (req_len[tile_i][port_i] == BurstLenWidth'(1))) begin
                for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
                  automatic int hit_e =
                      int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i;
                  if (mshr_q_valid[hit_e] &&
                      (mshr_q[hit_e].state == MSHR_CACHED) &&
                      req_addr_hit_way[tile_i][port_i][way_i]) begin
                    stat_cache_store_update_cycle = stat_cache_store_update_cycle + 1'b1;
                    break;
                  end
                end
              end
            end
          end
          if (amo_invalidate) begin
            for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
              if (mshr_q_valid[mshr_i] && (mshr_q[mshr_i].state == MSHR_CACHED)) begin
                stat_cache_amo_inval_cycle = stat_cache_amo_inval_cycle + 1'b1;
              end
            end
          end
          for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
            if (mshr_q_valid[mshr_i] &&
                (mshr_q[mshr_i].state != MSHR_CACHED) &&
                (mshr_d[mshr_i].state == MSHR_CACHED)) begin
              stat_cache_fill_cycle = stat_cache_fill_cycle + 1'b1;
            end
          end
          // Cache self-invalidate (idea 1): a CACHED way that goes invalid this cycle without an
          // AMO and without being reclaimed by an allocation (alloc-reclaim keeps mshr_d_valid=1)
          // is a self-invalidation. Counting it keeps the cache lifecycle balanced
          // (fills == evict + amo_inval + self_inval + net-resident) and stops it from silently
          // deflating stat_cache_evict (which would inflate hit_rate=hit/(hit+evict)).
          if (CacheSelfInval) begin
            for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
              if (mshr_q_valid[mshr_i] && (mshr_q[mshr_i].state == MSHR_CACHED) &&
                  !mshr_d_valid[mshr_i] && !amo_invalidate) begin
                stat_cache_self_inval_cycle = stat_cache_self_inval_cycle + 1'b1;
              end
            end
          end
        end
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin
        logic            print_period;
        logic            print_fall;
        if (!rst_ni) begin
          stat_cycle_count <= 0;
          stat_mshr_valid_acc <= 0;
          stat_mshr_valid_uncached_acc <= 0;
          stat_cache_valid_acc <= 0;
          stat_subreq_valid_acc <= 0;
          stat_mshr_max_valid <= 0;
          stat_cache_max_valid <= 0;
          stat_mshr_max_valid_uncached <= 0;
          stat_subreq_max_valid <= 0;
          stat_req_accept <= 0;
          stat_req_accept_single <= 0;
          stat_req_accept_burst <= 0;
          stat_req_merge <= 0;
          stat_req_merge_single <= 0;
          stat_req_merge_burst <= 0;
          stat_req_alloc <= 0;
          stat_req_alloc_single <= 0;
          stat_req_alloc_burst <= 0;
          stat_req_bypass <= 0;
          stat_req_mshr_overflow <= 0;
          stat_req_subreq_overflow <= 0;
          stat_resp_mshr <= 0;
          stat_resp_bypass <= 0;
          stat_cache_hit <= 0;
          stat_cache_fill <= 0;
          stat_cache_evict <= 0;
          stat_cache_store_update <= 0;
          stat_cache_amo_inval <= 0;
          stat_cache_self_inval <= 0;
          stat_trace_q <= 1'b0;
        end else begin
          stat_trace_q <= csr_trace_any_i;

          stat_cycle_count_next = stat_cycle_count;
          stat_mshr_valid_acc_next = stat_mshr_valid_acc;
          stat_mshr_valid_uncached_acc_next = stat_mshr_valid_uncached_acc;
          stat_cache_valid_acc_next = stat_cache_valid_acc;
          stat_subreq_valid_acc_next = stat_subreq_valid_acc;
          stat_mshr_max_valid_next = stat_mshr_max_valid;
          stat_cache_max_valid_next = stat_cache_max_valid;
          stat_mshr_max_valid_uncached_next = stat_mshr_max_valid_uncached;
          stat_subreq_max_valid_next = stat_subreq_max_valid;
          stat_req_accept_next = stat_req_accept;
          stat_req_accept_single_next = stat_req_accept_single;
          stat_req_accept_burst_next = stat_req_accept_burst;
          stat_req_merge_next = stat_req_merge;
          stat_req_merge_single_next = stat_req_merge_single;
          stat_req_merge_burst_next = stat_req_merge_burst;
          stat_req_alloc_next = stat_req_alloc;
          stat_req_alloc_single_next = stat_req_alloc_single;
          stat_req_alloc_burst_next = stat_req_alloc_burst;
          stat_req_bypass_next = stat_req_bypass;
          stat_req_mshr_overflow_next = stat_req_mshr_overflow;
          stat_req_subreq_overflow_next = stat_req_subreq_overflow;
          stat_resp_mshr_next = stat_resp_mshr;
          stat_resp_bypass_next = stat_resp_bypass;
          stat_cache_hit_next = stat_cache_hit;
          stat_cache_fill_next = stat_cache_fill;
          stat_cache_evict_next = stat_cache_evict;
          stat_cache_store_update_next = stat_cache_store_update;
          stat_cache_amo_inval_next = stat_cache_amo_inval;
          stat_cache_self_inval_next = stat_cache_self_inval;

          if (csr_trace_any_i) begin
            stat_cycle_count_next = stat_cycle_count + 1;
            stat_mshr_valid_acc_next = stat_mshr_valid_acc + stat_mshr_valid_cycle;
            stat_mshr_valid_uncached_acc_next =
                stat_mshr_valid_uncached_acc + stat_mshr_valid_uncached_cycle;
            stat_cache_valid_acc_next = stat_cache_valid_acc + stat_cache_valid_cycle;
            stat_subreq_valid_acc_next = stat_subreq_valid_acc + stat_subreq_valid_cycle;
            if (stat_mshr_valid_cycle > stat_mshr_max_valid_next) begin
              stat_mshr_max_valid_next = stat_mshr_valid_cycle;
            end
            if (stat_cache_valid_cycle > stat_cache_max_valid_next) begin
              stat_cache_max_valid_next = stat_cache_valid_cycle;
            end
            if (stat_mshr_valid_uncached_cycle > stat_mshr_max_valid_uncached_next) begin
              stat_mshr_max_valid_uncached_next = stat_mshr_valid_uncached_cycle;
            end
            if (stat_subreq_valid_cycle > stat_subreq_max_valid_next) begin
              stat_subreq_max_valid_next = stat_subreq_valid_cycle;
            end
            stat_req_accept_next = stat_req_accept + stat_req_accept_cycle;
            stat_req_accept_single_next = stat_req_accept_single + stat_req_accept_single_cycle;
            stat_req_accept_burst_next = stat_req_accept_burst + stat_req_accept_burst_cycle;
            stat_req_merge_next = stat_req_merge + stat_req_merge_cycle;
            stat_req_merge_single_next = stat_req_merge_single + stat_req_merge_single_cycle;
            stat_req_merge_burst_next = stat_req_merge_burst + stat_req_merge_burst_cycle;
            stat_req_alloc_next = stat_req_alloc + stat_req_alloc_cycle;
            stat_req_alloc_single_next = stat_req_alloc_single + stat_req_alloc_single_cycle;
            stat_req_alloc_burst_next = stat_req_alloc_burst + stat_req_alloc_burst_cycle;
            stat_req_bypass_next = stat_req_bypass + stat_req_bypass_cycle;
            stat_req_mshr_overflow_next = stat_req_mshr_overflow + stat_req_mshr_overflow_cycle;
            stat_req_subreq_overflow_next = stat_req_subreq_overflow + stat_req_subreq_overflow_cycle;
            stat_resp_mshr_next = stat_resp_mshr + stat_resp_mshr_cycle;
            stat_resp_bypass_next = stat_resp_bypass + stat_resp_bypass_cycle;
            stat_cache_hit_next = stat_cache_hit + stat_cache_hit_cycle;
            stat_cache_fill_next = stat_cache_fill + stat_cache_fill_cycle;
            stat_cache_evict_next = stat_cache_evict + stat_cache_evict_cycle;
            stat_cache_store_update_next =
                stat_cache_store_update + stat_cache_store_update_cycle;
            stat_cache_amo_inval_next = stat_cache_amo_inval + stat_cache_amo_inval_cycle;
            stat_cache_self_inval_next = stat_cache_self_inval + stat_cache_self_inval_cycle;
          end

          print_period = (StatsPeriod != 0) && csr_trace_any_i &&
                         (stat_cycle_count_next >= StatsPeriod);
          print_fall = stat_trace_q && !csr_trace_any_i;
          if ((print_period || print_fall) && (stat_cycle_count_next != 0)) begin
            print_stats(print_period ? "period" : "trace_off",
                        stat_cycle_count_next,
                        stat_mshr_valid_acc_next,
                        stat_mshr_valid_uncached_acc_next,
                        stat_subreq_valid_acc_next,
                        stat_mshr_max_valid_next,
                        stat_subreq_max_valid_next,
                        stat_req_accept_next,
                        stat_req_accept_single_next,
                        stat_req_accept_burst_next,
                        stat_req_merge_next,
                        stat_req_alloc_next,
                        stat_req_bypass_next,
                        stat_req_mshr_overflow_next,
                        stat_req_subreq_overflow_next,
                        stat_resp_mshr_next,
                        stat_resp_bypass_next,
                        stat_cache_valid_acc_next,
                        stat_cache_max_valid_next,
                        stat_mshr_max_valid_uncached_next,
                        stat_cache_hit_next,
                        stat_cache_fill_next,
                        stat_cache_evict_next,
                        stat_cache_store_update_next,
                        stat_cache_amo_inval_next,
                        stat_cache_self_inval_next);
            $display("  reqs_by_class: merged_single=%0d merged_burst=%0d alloc_single=%0d alloc_burst=%0d",
                     stat_req_merge_single_next, stat_req_merge_burst_next,
                     stat_req_alloc_single_next, stat_req_alloc_burst_next);
            // Root-cause dump at the trace-off flush (the `final` block is skipped whenever the
            // trace-off flush already zeroed stat_cycle_count, which is the common EOC path).
            // These accumulators are whole-run cumulative (never reset per period).
            if (print_fall) begin
              $write("  bank_alloc_hist:");
              for (int b = 0; b < MshrBankNum; b++) $write(" %0d", stat_bank_alloc_hist[b]);
              $write("\n  bank_ovf_hist:");
              for (int b = 0; b < MshrBankNum; b++) $write(" %0d", stat_bank_ovf_hist[b]);
              $write("\n");
              $display("  free_outcome: single subs1=%0d subs2p=%0d subs_sum=%0d cachehit_sum=%0d | burst subs1=%0d subs2p=%0d subs_sum=%0d",
                       stat_free_s_subs1, stat_free_s_subs2p, stat_free_s_subs_sum, stat_free_s_cachehit_sum,
                       stat_free_b_subs1, stat_free_b_subs2p, stat_free_b_subs_sum);
              $display("  drain_stall_cycles: single=%0d burst=%0d", stat_drain_stall_s, stat_drain_stall_b);
              if (HoldWindowMax != 0) begin
                $display("  hold_release: early_single=%0d timeout_single=%0d early_burst=%0d timeout_burst=%0d",
                         stat_hold_early_s, stat_hold_to_s, stat_hold_early_b, stat_hold_to_b);
              end
            end
            stat_cycle_count <= 0;
            stat_mshr_valid_acc <= 0;
            stat_mshr_valid_uncached_acc <= 0;
            stat_cache_valid_acc <= 0;
            stat_subreq_valid_acc <= 0;
            stat_mshr_max_valid <= 0;
            stat_cache_max_valid <= 0;
            stat_mshr_max_valid_uncached <= 0;
            stat_subreq_max_valid <= 0;
            stat_req_accept <= 0;
            stat_req_accept_single <= 0;
            stat_req_accept_burst <= 0;
            stat_req_merge <= 0;
            stat_req_merge_single <= 0;
            stat_req_merge_burst <= 0;
            stat_req_alloc <= 0;
            stat_req_alloc_single <= 0;
            stat_req_alloc_burst <= 0;
            stat_req_bypass <= 0;
            stat_req_mshr_overflow <= 0;
            stat_req_subreq_overflow <= 0;
            stat_resp_mshr <= 0;
            stat_resp_bypass <= 0;
            stat_cache_hit <= 0;
            stat_cache_fill <= 0;
            stat_cache_evict <= 0;
            stat_cache_store_update <= 0;
            stat_cache_amo_inval <= 0;
            stat_cache_self_inval <= 0;
          end else begin
            stat_cycle_count <= stat_cycle_count_next;
            stat_mshr_valid_acc <= stat_mshr_valid_acc_next;
            stat_mshr_valid_uncached_acc <= stat_mshr_valid_uncached_acc_next;
            stat_cache_valid_acc <= stat_cache_valid_acc_next;
            stat_subreq_valid_acc <= stat_subreq_valid_acc_next;
            stat_mshr_max_valid <= stat_mshr_max_valid_next;
            stat_cache_max_valid <= stat_cache_max_valid_next;
            stat_mshr_max_valid_uncached <= stat_mshr_max_valid_uncached_next;
            stat_subreq_max_valid <= stat_subreq_max_valid_next;
            stat_req_accept <= stat_req_accept_next;
            stat_req_accept_single <= stat_req_accept_single_next;
            stat_req_accept_burst <= stat_req_accept_burst_next;
            stat_req_merge <= stat_req_merge_next;
            stat_req_merge_single <= stat_req_merge_single_next;
            stat_req_merge_burst <= stat_req_merge_burst_next;
            stat_req_alloc <= stat_req_alloc_next;
            stat_req_alloc_single <= stat_req_alloc_single_next;
            stat_req_alloc_burst <= stat_req_alloc_burst_next;
            stat_req_bypass <= stat_req_bypass_next;
            stat_req_mshr_overflow <= stat_req_mshr_overflow_next;
            stat_req_subreq_overflow <= stat_req_subreq_overflow_next;
            stat_resp_mshr <= stat_resp_mshr_next;
            stat_resp_bypass <= stat_resp_bypass_next;
            stat_cache_hit <= stat_cache_hit_next;
            stat_cache_fill <= stat_cache_fill_next;
            stat_cache_evict <= stat_cache_evict_next;
            stat_cache_store_update <= stat_cache_store_update_next;
            stat_cache_amo_inval <= stat_cache_amo_inval_next;
            stat_cache_self_inval <= stat_cache_self_inval_next;
          end
        end
      end

      final begin
        if (stat_cycle_count != 0) begin
          print_stats("final",
                      stat_cycle_count,
                      stat_mshr_valid_acc,
                      stat_mshr_valid_uncached_acc,
                      stat_subreq_valid_acc,
                      stat_mshr_max_valid,
                      stat_subreq_max_valid,
                      stat_req_accept,
                      stat_req_accept_single,
                      stat_req_accept_burst,
                      stat_req_merge,
                      stat_req_alloc,
                      stat_req_bypass,
                      stat_req_mshr_overflow,
                      stat_req_subreq_overflow,
                      stat_resp_mshr,
                      stat_resp_bypass,
                      stat_cache_valid_acc,
                      stat_cache_max_valid,
                      stat_mshr_max_valid_uncached,
                      stat_cache_hit,
                      stat_cache_fill,
                      stat_cache_evict,
                      stat_cache_store_update,
                      stat_cache_amo_inval,
                      stat_cache_self_inval);
          $display("  reqs_by_class: merged_single=%0d merged_burst=%0d alloc_single=%0d alloc_burst=%0d",
                   stat_req_merge_single, stat_req_merge_burst,
                   stat_req_alloc_single, stat_req_alloc_burst);
          $write("  bank_alloc_hist:");
          for (int b = 0; b < MshrBankNum; b++) $write(" %0d", stat_bank_alloc_hist[b]);
          $write("\n  bank_ovf_hist:");
          for (int b = 0; b < MshrBankNum; b++) $write(" %0d", stat_bank_ovf_hist[b]);
          $write("\n");
          $display("  free_outcome: single subs1=%0d subs2p=%0d subs_sum=%0d cachehit_sum=%0d | burst subs1=%0d subs2p=%0d subs_sum=%0d",
                   stat_free_s_subs1, stat_free_s_subs2p, stat_free_s_subs_sum, stat_free_s_cachehit_sum,
                   stat_free_b_subs1, stat_free_b_subs2p, stat_free_b_subs_sum);
          $display("  drain_stall_cycles: single=%0d burst=%0d", stat_drain_stall_s, stat_drain_stall_b);
          if (HoldWindowMax != 0) begin
            $display("  hold_release: early_single=%0d timeout_single=%0d early_burst=%0d timeout_burst=%0d",
                     stat_hold_early_s, stat_hold_to_s, stat_hold_early_b, stat_hold_to_b);
          end
        end
      end
    end
  endgenerate
  `endif
  // pragma translate_on

  // pragma translate_off
  `ifndef VERILATOR
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_resp_src_excl_tile
      for (genvar port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin : gen_resp_src_excl_port
        resp_src_exclusive: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
          !(resp_from_mshr[tile_i][port_i] && resp_from_bypass[tile_i][port_i]))
          else $fatal(1, "MSHR resp source conflict: tile=%0d port=%0d", tile_i, port_i);
      end
    end
  endgenerate
  `endif
  // pragma translate_on

  // pragma translate_off
  `ifndef VERILATOR
  // Bank-scoped hit detection (3b) relies on: a valid entry's (address,group) always hashes to its own
  // bank. Allocation enforces this (bank_free_id[req_bank] only returns ways of that bank), so if this
  // ever fails a request could miss a real hit and allocate a duplicate. Catch any violation early.
  generate
    for (genvar mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin : gen_mshr_bank_invariant
      mshr_entry_in_its_bank: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
        mshr_q_valid[mshr_i] |->
          (mshr_bank_of(mshr_q[mshr_i].base_addr, mshr_q[mshr_i].tgt_group_id,
                        mshr_q[mshr_i].burst_len == BurstLenWidth'(1),
                        cfg_bank_shift_single, cfg_bank_shift_burst, cfg_bank_burst_bits) ==
           BankIdW'(mshr_i / MshrWaysPerBank)))
        else $fatal(1, "MSHR entry %0d not in its address bank (got %0d, expected %0d)",
                    mshr_i,
                    mshr_bank_of(mshr_q[mshr_i].base_addr, mshr_q[mshr_i].tgt_group_id,
                                 mshr_q[mshr_i].burst_len == BurstLenWidth'(1),
                                 cfg_bank_shift_single, cfg_bank_shift_burst, cfg_bank_burst_bits),
                    mshr_i / MshrWaysPerBank);
    end
  endgenerate
  `endif
  // pragma translate_on

`ifndef TARGET_SYNTHESIS
  // Report a duplicate beat once per cycle, on settled values. See the note at the
  // declaration for why this cannot live inside the always_comb that detects it.
  always_ff @(posedge clk_i) begin
    if (rst_ni && dup_beat_detected)
      $fatal(1, "MSHR duplicate response beat: mshr=%0d beat=%0d meta=%0d",
             dup_beat_mshr, dup_beat_beat, dup_beat_meta);
  end
`endif

  // ---------------------------------------------------------------------------
  // [MSHRLIFE] -- per-entry lifetime spans, for the GVSOC performance calibration
  // (Request D, TeraNoC_gvsoc/docs/rtl_probe_request.md). Sim-only, no timing effect.
  //
  // The three spans are cut at REGISTERED boundaries and are DISJOINT BY
  // CONSTRUCTION, so hold+flight+drain == entry lifetime rather than being three
  // independently-defined numbers that happen to be compared:
  //   hold   : entry allocated (valid rises)      -> request issued (issued rises)
  //   flight : request issued                     -> FIRST response beat captured
  //   drain  : first beat captured                -> entry freed (valid falls)
  // life is stamped independently (alloc -> free) so the sum can be CHECKED against
  // it rather than assumed; a mismatch means an entry took a path these spans miss
  // (e.g. freed before any beat, or a CACHED-state revisit).
  //
  // Accumulation is staged into blocking locals and committed with ONE nonblocking
  // assignment per counter: several entries can hit the same boundary in one cycle,
  // and per-entry nonblocking updates to a shared accumulator would be lost to
  // last-write-wins (the same reason gen_stats stages its increments).
  // ---------------------------------------------------------------------------
`ifndef VERILATOR
`ifndef TARGET_SYNTHESIS
  // pragma translate_off
  if (1) begin : gen_mshr_lifetime
    logic [31:0] ml_cyc;
    logic [31:0] ml_t_alloc [MshrNum];
    logic [31:0] ml_t_issue [MshrNum];
    logic [31:0] ml_t_first [MshrNum];
    logic [MshrNum-1:0] ml_seen_issue, ml_seen_first, ml_vld_q;
    logic [63:0] ml_hold_sum, ml_flight_sum, ml_drain_sum, ml_life_sum;
    logic [63:0] ml_hold_n,   ml_flight_n,   ml_drain_n,   ml_life_n;
    logic [63:0] ml_nobeat_n;   // freed without ever capturing a beat (drain undefined)
    // Split by burst length. A pooled drain mean is NOT comparable against another model's
    // per-burst-entry number: single-word entries (burst_len==1) drain in a couple of cycles and
    // drag the pooled mean down, while a 16-beat entry is the thing under study. Keeping the
    // burst-entry beat total as well makes cycles-per-beat derivable (drain_b_sum / bl_b_sum)
    // rather than requiring the reader to assume every burst entry carried MaxBurstWords beats.
    logic [63:0] ml_drain_s_sum, ml_drain_s_n;              // burst_len == 1
    logic [63:0] ml_drain_b_sum, ml_drain_b_n, ml_bl_b_sum; // burst_len  > 1, + total beats
    logic [BurstLenWidth-1:0] ml_bl [MshrNum];              // burst_len captured at allocation
    // BEAT ARRIVAL SPACING within a single entry. The drain span above answers "how long does an
    // entry live", which is NOT the same as "how fast do its beats come back" -- an entry that
    // serves merge partners outlives its beats. first-beat -> LAST-beat is the arrival rate of one
    // burst from the target group, i.e. the response path, isolated from subscriber service.
    // Beats are counted with $countones, not one-per-cycle: with DrainBeats=2 a cycle can capture
    // two, and counting cycles instead of beats would understate the rate by up to 2x.
    logic [31:0] ml_t_last  [MshrNum];
    logic [31:0] ml_nbeats  [MshrNum];
    logic [63:0] ml_bspan_sum, ml_bspan_n, ml_bcap_sum;     // burst entries with >= 2 beats
    // TIME-AVERAGED OCCUPANCY. Deliberately accumulated EVERY CYCLE, not sampled at period
    // boundaries: an instantaneous sample is an estimator, not a mean, and the GVSOC side found
    // theirs biased high by exactly 2x when they compared the two. ml_occ_active counts cycles
    // with at least one live entry, so the mean can be quoted over both denominators (whole run,
    // and cycles the MSHR has any work) instead of leaving the denominator implicit.
    logic [63:0] ml_occ_sum, ml_occ_active;

    always_ff @(posedge clk_i) begin
      automatic logic [63:0] a_hold, a_flight, a_drain, a_life;
      automatic logic [63:0] n_hold, n_flight, n_drain, n_life, n_nobeat;
      automatic logic [63:0] a_drain_s, n_drain_s, a_drain_b, n_drain_b, a_bl_b;
      automatic logic [63:0] a_bspan, n_bspan, a_bcap;
      automatic logic [31:0] t_a;
      if (!rst_ni) begin
        ml_cyc <= '0; ml_vld_q <= '0; ml_seen_issue <= '0; ml_seen_first <= '0;
        ml_hold_sum <= '0; ml_flight_sum <= '0; ml_drain_sum <= '0; ml_life_sum <= '0;
        ml_hold_n <= '0; ml_flight_n <= '0; ml_drain_n <= '0; ml_life_n <= '0;
        ml_nobeat_n <= '0;
        ml_drain_s_sum <= '0; ml_drain_s_n <= '0;
        ml_drain_b_sum <= '0; ml_drain_b_n <= '0; ml_bl_b_sum <= '0;
        ml_bspan_sum <= '0; ml_bspan_n <= '0; ml_bcap_sum <= '0;
        ml_occ_sum <= '0; ml_occ_active <= '0;
      end else begin
        a_hold='0; a_flight='0; a_drain='0; a_life='0;
        n_hold='0; n_flight='0; n_drain='0; n_life='0; n_nobeat='0;
        a_drain_s='0; n_drain_s='0; a_drain_b='0; n_drain_b='0; a_bl_b='0;
        a_bspan='0; n_bspan='0; a_bcap='0;
        ml_cyc <= ml_cyc + 1;
        ml_occ_sum <= ml_occ_sum + 64'($countones(mshr_q_valid));
        if (|mshr_q_valid) ml_occ_active <= ml_occ_active + 1;
        for (int e = 0; e < MshrNum; e++) begin
          // An entry can be allocated and issued in the SAME cycle; ml_t_alloc[e] is
          // nonblocking so it still holds the previous life's value here. Use the
          // live stamp in that case, never the stale register.
          t_a = (mshr_q_valid[e] && !ml_vld_q[e]) ? ml_cyc : ml_t_alloc[e];

          if (mshr_q_valid[e] && !ml_vld_q[e]) begin
            ml_t_alloc[e]    <= ml_cyc;
            ml_seen_issue[e] <= 1'b0;
            ml_seen_first[e] <= 1'b0;
            ml_bl[e]         <= mshr_q[e].burst_len;
            ml_nbeats[e]     <= '0;
          end
          if (mshr_q_valid[e] && mshr_q[e].issued && !ml_seen_issue[e]) begin
            ml_t_issue[e]    <= ml_cyc;
            ml_seen_issue[e] <= 1'b1;
            a_hold = a_hold + 64'(ml_cyc - t_a); n_hold = n_hold + 1;
          end
          if (mshr_q_valid[e] && (|mshr_rb_we[e]) && ml_seen_issue[e] && !ml_seen_first[e]) begin
            ml_t_first[e]    <= ml_cyc;
            ml_seen_first[e] <= 1'b1;
            a_flight = a_flight + 64'(ml_cyc - ml_t_issue[e]); n_flight = n_flight + 1;
          end
          // every beat, including the first: stamp the latest arrival and accumulate the count
          if (mshr_q_valid[e] && (|mshr_rb_we[e])) begin
            ml_t_last[e]  <= ml_cyc;
            ml_nbeats[e]  <= ml_nbeats[e] + 32'($countones(mshr_rb_we[e]));
          end
          if (!mshr_q_valid[e] && ml_vld_q[e]) begin
            if (ml_seen_first[e]) begin
              a_drain = a_drain + 64'(ml_cyc - ml_t_first[e]); n_drain = n_drain + 1;
              if (ml_bl[e] > BurstLenWidth'(1)) begin
                a_drain_b = a_drain_b + 64'(ml_cyc - ml_t_first[e]);
                n_drain_b = n_drain_b + 1;
                a_bl_b    = a_bl_b    + 64'(ml_bl[e]);
                // A single-beat entry has no arrival spacing to measure; excluding it keeps the
                // rate from being diluted by entries that trivially span 0 cycles.
                if (ml_nbeats[e] >= 32'd2) begin
                  a_bspan = a_bspan + 64'(ml_t_last[e] - ml_t_first[e]);
                  n_bspan = n_bspan + 1;
                  a_bcap  = a_bcap  + 64'(ml_nbeats[e]);
                end
              end else begin
                a_drain_s = a_drain_s + 64'(ml_cyc - ml_t_first[e]);
                n_drain_s = n_drain_s + 1;
              end
            end else begin
              n_nobeat = n_nobeat + 1;
            end
            a_life = a_life + 64'(ml_cyc - ml_t_alloc[e]); n_life = n_life + 1;
          end
          ml_vld_q[e] <= mshr_q_valid[e];
        end
        ml_hold_sum   <= ml_hold_sum   + a_hold;   ml_hold_n   <= ml_hold_n   + n_hold;
        ml_flight_sum <= ml_flight_sum + a_flight; ml_flight_n <= ml_flight_n + n_flight;
        ml_drain_sum  <= ml_drain_sum  + a_drain;  ml_drain_n  <= ml_drain_n  + n_drain;
        ml_life_sum   <= ml_life_sum   + a_life;   ml_life_n   <= ml_life_n   + n_life;
        ml_nobeat_n   <= ml_nobeat_n   + n_nobeat;
        ml_drain_s_sum <= ml_drain_s_sum + a_drain_s; ml_drain_s_n <= ml_drain_s_n + n_drain_s;
        ml_drain_b_sum <= ml_drain_b_sum + a_drain_b; ml_drain_b_n <= ml_drain_b_n + n_drain_b;
        ml_bl_b_sum    <= ml_bl_b_sum    + a_bl_b;
        ml_bspan_sum <= ml_bspan_sum + a_bspan; ml_bspan_n <= ml_bspan_n + n_bspan;
        ml_bcap_sum  <= ml_bcap_sum  + a_bcap;
      end
    end

    final begin
      if (ml_life_n != 0)
        $display("[MSHRLIFE] %m MshrNum=%0d hold_n=%0d hold_sum=%0d flight_n=%0d flight_sum=%0d drain_n=%0d drain_sum=%0d life_n=%0d life_sum=%0d freed_without_beat=%0d",
                 MshrNum, ml_hold_n, ml_hold_sum, ml_flight_n, ml_flight_sum,
                 ml_drain_n, ml_drain_sum, ml_life_n, ml_life_sum, ml_nobeat_n);
      if (ml_life_n != 0)
        $display("[MSHRLIFE-BL] %m drain_single_n=%0d drain_single_sum=%0d drain_burst_n=%0d drain_burst_sum=%0d burst_beats_sum=%0d",
                 ml_drain_s_n, ml_drain_s_sum, ml_drain_b_n, ml_drain_b_sum, ml_bl_b_sum);
      if (ml_bspan_n != 0)
        $display("[MSHRLIFE-BEATS] %m entries=%0d first_to_last_sum=%0d beats_captured_sum=%0d",
                 ml_bspan_n, ml_bspan_sum, ml_bcap_sum);
      $display("[MSHRLIFE-OCC] %m MshrNum=%0d cycles=%0d occ_sum=%0d active_cycles=%0d",
               MshrNum, ml_cyc, ml_occ_sum, ml_occ_active);
    end
  end
  // pragma translate_on
`endif
`endif

endmodule : mempool_group_mshr
