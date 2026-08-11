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
  // Keep responded entries as a small read-response cache.
  parameter bit EnableRespCache = 1'b1,
  // Simulation-only statistics/prints (translate_off).
  parameter bit EnableStats   = `ifdef GROUP_MSHR_ENABLE_STATS `GROUP_MSHR_ENABLE_STATS `else 1'b0 `endif,
  // Stats print period in cycles while trace is active (0 disables periodic prints).
  parameter int unsigned StatsPeriod = `ifdef GROUP_MSHR_STATS_PERIOD `GROUP_MSHR_STATS_PERIOD `else 0 `endif,
  // Spill register enables (0 = pass-through).
  parameter bit SpillReqIn     = 1'b1,
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
  input  logic                            [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]  group_mshr_resp_ready_i
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
  localparam int unsigned HoldCntMax =
    (HoldWindowMax > ServeTimeout) ? HoldWindowMax : ServeTimeout;
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
  if ((HoldSubs < 2) || (HoldSubs > MshrMergeReqs))
    $error("[mempool_group_mshr] group_mshr_hold_subs (%0d) must be in [2, MshrMergeReqs].",
           HoldSubs);
  if ((HoldSubsSingle < 2) || (HoldSubsSingle > MshrMergeReqs) ||
      (HoldSubsBurst  < 2) || (HoldSubsBurst  > MshrMergeReqs))
    $error("[mempool_group_mshr] group_mshr_hold_subs_single/burst (%0d/%0d) must be in [2, MshrMergeReqs].",
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
  // served_cnt only has to reach the larger sharing target, where it saturates.
  localparam int unsigned ServedCntMax     = (HoldSubsSingle > HoldSubsBurst)
                                             ? HoldSubsSingle : HoldSubsBurst;
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
  localparam int unsigned BypassTrackWays =
    (2 > (snitch_pkg::RobDepth / MaxBurstWords)) ? 2 : (snitch_pkg::RobDepth / MaxBurstWords);
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
  if ((BankHash == 3) && (BankBurstBits >= BankIdW))
    $error("[mempool_group_mshr] group_mshr_bank_burst_bits (%0d) must leave at least 1 gap bit (BankIdW=%0d).",
           BankBurstBits, BankIdW);

  // Map a (target group, merge address key, request type) to its MSHR bank. Folds address bits
  // ABOVE the burst-alignment boundary (so a burst's beats stay within one bank) together with the
  // target group. Pure function of {group, addr, TYPE} -- no requester dependence -- so all
  // same-(group,line,type) requests hash to the same bank (cross-tile merge preserved).
  // is_single only matters for BankHash==3 (the two field-select shifts); every other mode ignores
  // it and stays a pure function of {group,addr}. Splitting single from burst costs ZERO merging:
  // req_hit_way already requires burst_len equality (:1197) and the CACHED arm requires req_len==1
  // (:1203), so a single and a burst for the same line can never merge in the first place.
  function automatic logic [BankIdW-1:0] mshr_bank_of(input tcdm_addr_t addr_key, input group_id_t grp,
                                                      input logic is_single);
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
        b = word_addr[BankSelShiftSingle +: BankIdW];
      end else if (BankBurstBits == 0) begin
        b = word_addr[BankSelShiftBurst +: BankIdW];
      end else begin
        b = { word_addr[BankSelShiftBurst +: BankIdW - BankBurstBits],
              word_addr[BurstAlignBits   +: BankBurstBits] };
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
    // Base meta_id of this requester; per-beat meta_id is computed as
    // (meta_id_base + beat_offset) when draining a returned beat.
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
  //     .rdata.core_id <- sub_reqs[].core_id + parity retag
  //     .rdata.meta_id <- sub_reqs[].meta_id_base + beat_offset
  //     .rdata.amo     <- constant '0 (sub-requests are loads: req_is_load gate)
  // so core_id, amo and mshr_tag were stored and never used: 14 of 53 bits per slot, x2 slots
  // x64 entries = 1792 flops per group (114,688 at 8x8). meta_id is kept because the
  // ParityDrain second-slot path derives its beat offset from it (resp_beat_offset2).
  // mshr_tag in particular is the entry's own index -- known from where the slot lives.
  typedef struct packed {
    meta_id_t meta_id;
    data_t    data;
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
  int            cache_hit_e;
  int unsigned   alloc_victim_rw;
  int unsigned   evict_vid;
  int unsigned   evict_vw;
  int unsigned   replay_e;
  int unsigned   replay_rp;
  int unsigned   replay_rt;
  logic          replay_hold_done;
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
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_mshr_id_dbg;
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
  logic      [MshrNum-1:0][SubReqCountW-1:0]                                   drain_count;
  logic      [MshrNum-1:0][BurstLenWidth-1:0]                                  resp_beat_offset;
  // ParityDrain second-slot scheduling ('0/unused when DrainBeatsPerEntry == 1).
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel2_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel2_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]
             [idx_width(MshrMergeReqs)-1:0]                                    resp_sel2_subreq_idx;
  logic      [MshrNum-1:0][BurstLenWidth-1:0]                                  resp_beat_offset2;
  logic      [MshrNum-1:0][RespBufPtrW-1:0]                                    resp_rd_ptr2;

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

  if (PD2) begin : gen_bypass_retag
    // Loop temporaries for the two always_comb blocks below, at generate scope rather than as
    // procedural `automatic`s. Identical hardware -- each is assigned before it is read on every
    // unrolled iteration -- but visible in a waveform and in the form the backend flow expects.
    // bypass_retire_way keeps the table's own index width instead of widening to a 32-bit `int`
    // only to index a BypassTrackWays-deep array.
    meta_id_t                   bypass_off;         // meta_id - meta_base, wraps mod 2**MetaIdWidth
    logic [BypassTrackWayW-1:0] bypass_retire_way;
    logic                       bypass_way_found;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) bypass_track_q <= '0;
      else         bypass_track_q <= bypass_track_d;
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
  logic      [MshrNum-1:0]                                                     drain_subreq_found;
  logic      [idx_width(MshrMergeReqs)-1:0]                                    drain_subreq_idx [MshrNum-1:0];
  tile_group_id_t[MshrNum-1:0]                                                 drain_dst_tile;
  logic      [RespPortIdW-1:0]                                                 drain_dst_port [MshrNum-1:0];
  logic      [MshrNum-1:0]                                                     drain_port_found;
  logic      [MshrNum-1:0][MshrMergeReqs-1:0]                                  subreq_claimed;

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
  // and the drain scan has cross-port subreq_claimed coupling + a per-(tile,port)
  // tile_id/port_id filter over 64x8 pairs -- neither fits a fixed-input arbiter.
  // ---------------------------------------------------------------------------
  // (A) M2' allocator: rotate the requester (tile,port) priority axis. Active req
  //     ports are indices 1..NumRemoteReqPortsPerTile-1, flattened to one index.
  localparam int unsigned NumReqPortsActive = (NumRemoteReqPortsPerTile > 1) ?
                                              (NumRemoteReqPortsPerTile - 1) : 1;
  localparam int unsigned NumAllocSlots     = NumTilesPerGroup * NumReqPortsActive;
  localparam int unsigned AllocRrW          = idx_width(NumAllocSlots);
  logic [AllocRrW-1:0]      alloc_rr_q, alloc_rr_d;
  // (B) M3 drain: rotate the MSHR-entry scan axis (MshrNum entries).
  localparam int unsigned DrainMshrRrW = idx_width(MshrNum);
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

  // Occupancy mask of one modulo-meta_id range [base, base+len-1] over the whole meta space.
  //
  // This replaced meta_range_overlap(), which answered "do these two ranges overlap?" by
  // ENUMERATING all MaxBurstWords offsets of range A and testing each for membership in B --
  // MaxBurstWords add+subtract+compare units per call. That call sat in gen_req_meta_ovlp, which
  // is replicated NumTilesPerGroup x active req ports x MshrNum = 2048 times at 8x8, making it the
  // largest combinational structure in the module.
  //
  // As masks the test is |(mask_a & mask_b), and -- the actual win -- mask_b depends only on the
  // ENTRY, so it is built once per entry instead of once per (tile, port, entry). Note the meta
  // space is 2**$bits(meta_id_t) = 8 while MaxBurstWords is 16, so any len >= MetaSpace covers the
  // whole space; the mask form gets that for free where the enumeration needed all 16 iterations.
  //
  // Proven EXHAUSTIVELY equivalent to the old function over the complete input space --
  // 8 x 8 bases x 17 x 17 lengths = 18496 combinations, 0 mismatches.
  localparam int unsigned MetaSpace = 1 << $bits(meta_id_t);
  function automatic logic [MetaSpace-1:0] meta_range_mask(input meta_id_t base,
                                                           input logic [BurstLenWidth-1:0] len);
    meta_range_mask = '0;
    for (int k = 0; k < MetaSpace; k++) begin
      if ((meta_id_t'(k) - base) < len) meta_range_mask[k] = 1'b1;
    end
  endfunction

  // Entry-side masks: one per entry, NOT per requester -- this is what removes the replication.
  logic [MshrNum-1:0][MetaSpace-1:0] mshr_meta_mask;
  always_comb begin
    for (int e = 0; e < MshrNum; e++) begin
      mshr_meta_mask[e] = meta_range_mask(mshr_q[e].sub_reqs[0].meta_id_base, mshr_q[e].burst_len);
    end
  end

  // Request-side masks: one per (tile, request port).
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:0][MetaSpace-1:0] req_meta_mask;
  always_comb begin
    req_meta_mask = '0;
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
        req_meta_mask[t][p] = meta_range_mask(req_in[t][p].wdata.meta_id, req_len[t][p]);
      end
    end
  end

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
          req_can_merge[tile_i][port_i] =
              req_is_load[tile_i][port_i] &&
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
           (mshr_q[mshr_i].sub_reqs_num < SubReqCountW'(HoldSubsSingle))))
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
        else $fatal(1, "MSHR unmatched head beat: mshr=%0d meta=%0d base_meta=%0d subreqs=%0d beat_pending=0x%0x",
                    mshr_i,
                    mshr_d[mshr_i].resp_buf[mshr_d[mshr_i].resp_buf_rd_ptr].meta_id,
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
                  (mshr_q[rsn_tag_cand].sub_reqs[0].core_id ==
                       resp_in[tile_i][port_i].rdata.core_id) &&
                  ((resp_in[tile_i][port_i].rdata.meta_id -
                      mshr_q[rsn_tag_cand].sub_reqs[0].meta_id_base) <
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
                  (mshr_q[mshr_i].sub_reqs[0].core_id == resp_in[tile_i][port_i].rdata.core_id) &&
                  ((resp_in[tile_i][port_i].rdata.meta_id -
                    mshr_q[mshr_i].sub_reqs[0].meta_id_base) < mshr_q[mshr_i].burst_len)) begin
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
                         req_is_single[tile_i][port_i]);
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
              |(req_meta_mask[tile_i][port_i] & mshr_meta_mask[mshr_i]);
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
        req_merge_ready[tile_i][port_i]   = 1'b1; // an existing entry is always ready to accept a merge
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
  always_comb begin
    for (int e = 0; e < MshrNum; e++) begin
      // Control changes only while the entry is live; the free cycle (valid -> !valid) is
      // included so the clear lands.
      mshr_ctl_en[e] = mshr_q_valid[e] | mshr_d_valid[e];
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
  `FF(victim_rr_q, victim_rr_d, '0)

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
  logic [31:0]        mshr_issue_timeout_cnt_dbg;
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
               HoldWindowSingle : HoldWindowBurst) != 0)) begin
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
    end else begin
      mshr_issue_timeout_cnt_dbg <=
          mshr_issue_timeout_cnt_dbg + 32'($countones(mshr_issue_timeout_dbg));
      mshr_issue_subs_cnt_dbg    <=
          mshr_issue_subs_cnt_dbg    + 32'($countones(mshr_issue_subs_dbg));
    end
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
                       mshr_q[e].sub_reqs_num, HoldSubsSingle,
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
  int                       drain_sel_base,  drain_sel_sub_base;   // A: rotation bases
  logic [MshrNum-1:0]       drain_ent_cand;                        // A: entries offering a beat
  logic [MshrMergeReqs-1:0] drain_sub_cand;                        // A: sub-reqs in the winner
  int                       drain_win_e,     drain_win_s;
  logic                     drain_have_e,    drain_have_s;
  int                       drain_scan_s;                          // A: rotated scan index
  logic [MshrNum-1:0]       drain_cand_rot;                        // A: candidates rotated to base
  logic [MshrNum-1:0]       drain_pfx, drain_first;                // A: prefix-OR, isolated LSB
  int unsigned              drain_idx;                             // A: index within the rotation
  logic [MshrNum-1:0]       drain2_cand;                           // A: 2nd-slot entry candidates
  logic [MshrNum-1:0]       drain2_cand_rot;                       // A: rotated to base
  logic [MshrNum-1:0]       drain2_pfx, drain2_first;              // A: prefix-OR, isolated LSB
  int unsigned              drain2_idx;                            // A: index within the rotation
  int                       drain2_base, drain2_sub_base, drain2_mshr_i, drain2_s;   // B
  int                       drain3_base, drain3_sub_base, drain3_mshr_i, drain3_s;   // C

  always_comb begin
    int unsigned merge_new_idx;
    // Defaults
    mshr_d      = mshr_q;
    // Clock-gate write flags. Set on the same line as the write they describe (see the entry
    // register block), never from a restatement of the write's condition.
    mshr_wr_all = '0;
    mshr_id_we  = '0;
    mshr_rb_we  = '0;
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
    resp_mshr_id_dbg = '0;
    resp_in_ready = '1;
    mshr_resp_inflight = '0;

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
            req_in_ready[tile_i][port_i] =
                req_merge_ready[tile_i][port_i] &&
                ((mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num +
                  SubReqCountW'(1)) <= MshrMergeReqs);
            if (req_in_ready[tile_i][port_i]) begin
              if ((mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num +
                   SubReqCountW'(1)) <= MshrMergeReqs) begin
`ifndef TARGET_SYNTHESIS
                if (EnableRespCache &&
                    (mshr_d[req_merge_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].cache_hit_cnt =
                      mshr_d[req_merge_mshr_id[tile_i][port_i]].cache_hit_cnt + 1'b1;
                end
`endif
                merge_new_idx = mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num;
                mshr_id_we[req_merge_mshr_id[tile_i][port_i]] = 1'b1;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].valid = 1'b1;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].tile_id = tile_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].port_id = port_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].core_id =
                    req_in[tile_i][port_i].wdata.core_id;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].meta_id_base =
                    req_in[tile_i][port_i].wdata.meta_id;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num =
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num + SubReqCountW'(1);
                // Cache self-invalidate: count this merged sub-request toward the sharing target.
                mshr_d[req_merge_mshr_id[tile_i][port_i]].served_cnt =
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].served_cnt + ServedCntW'(1);
                if (EnableRespCache &&
                    (mshr_d[req_merge_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
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
                    (mshr_d[req_merge_mshr_id[tile_i][port_i]].state == MSHR_RESP_HOLD) &&
                    (mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num >=
                     SubReqCountW'(HoldSubsSingle))) begin
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
                         bank_has_free[req_bank[tile_i][port_i]]) begin
              // Mergeable miss that lost this bank's single allocation slot this cycle, but a free way
              // exists: STALL and retry. Next cycle it either wins the slot or HIT-merges the entry the
              // winner just created (same address) -> full coalescing preserved, no extra entry, no
              // bypass. This is the stall-and-merge half of the per-bank single-alloc scheme.
              req_in_ready[tile_i][port_i]  = 1'b0;
              req_out_valid[tile_i][port_i] = 1'b0;
            end else begin
              // ALLOCATE (won the per-bank slot) or BYPASS (non-mergeable store/AMO, or a mergeable
              // miss whose bank is full): forward this request to the NoC.
              // Per-type hold window: single (burst_len==1) uses HoldWindowSingle, burst uses
              // HoldWindowBurst. A 0 window for this class -> take the normal issue path (a held
              // door with a 0 window would never issue -> deadlock).
              if ((((req_len[tile_i][port_i] == BurstLenWidth'(1)) ?
                     HoldWindowSingle : HoldWindowBurst) != 0) &&
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
                if (CacheVictimRR) begin
                  evict_vid = int'(req_alloc_found_mshr_id[tile_i][port_i]);
                  evict_vw  = evict_vid % MshrWaysPerBank;
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
                               HoldWindowSingle : HoldWindowBurst);
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].issued =
                    (((req_len[tile_i][port_i] == BurstLenWidth'(1)) ?
                      HoldWindowSingle : HoldWindowBurst) == 0);
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs_num =
                    SubReqCountW'(1);
                // Cache self-invalidate: the owner is the first served sub-request.
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].served_cnt = ServedCntW'(1);
                end
              end
            end
            if (EnableRespCache && !amo_invalidate &&
                req_is_store[tile_i][port_i] &&
                (req_len[tile_i][port_i] == BurstLenWidth'(1)) &&
                req_in_ready[tile_i][port_i]) begin
              // Bank-scoped (3b): a store can only hit a CACHED entry in its own bank, so scan only
              // this request's MshrWaysPerBank ways; hit_e reconstructs the absolute entry id.
              for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
                cache_hit_e =
                    int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i;
                if (mshr_d_valid[cache_hit_e] &&
                    (mshr_d[cache_hit_e].state == MSHR_CACHED) &&
                    req_addr_hit_way[tile_i][port_i][way_i]) begin
                  // H3 fix: merge under byte-enables — a sub-word store must update only the
                  // enabled byte lanes and keep the existing cached bytes (writing the full word
                  // would corrupt the non-written bytes that a later cache-hit load would read).
                  for (int b = 0; b < $bits(req_in[tile_i][port_i].be); b++) begin
                    if (req_in[tile_i][port_i].be[b]) begin
                      mshr_d[cache_hit_e].resp_buf[mshr_d[cache_hit_e].resp_buf_rd_ptr]
                            .data[b*8 +: 8] =
                          req_in[tile_i][port_i].wdata.data[b*8 +: 8];
                    end
                  end
                  if (mshr_d[cache_hit_e].resp_buf_cnt == '0) begin
                    mshr_d[cache_hit_e].resp_buf_cnt = RespBufCountW'(1);
                  end
                end
              end
            end
          end
        end else begin
          req_in_ready[tile_i][port_i] = 1'b1;
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
      for (int k = 0; k < MshrNum; k++) begin
        replay_e = 32'(hold_replay_rr_q) + 32'(k);
        if (replay_e >= MshrNum) replay_e -= MshrNum;
        if (mshr_d_valid[replay_e] && (mshr_d[replay_e].state == MSHR_WAIT_RESP) &&
            !mshr_d[replay_e].issued) begin
          replay_hold_done = (mshr_d[replay_e].hold_cnt == '0) ||
                      (mshr_d[replay_e].sub_reqs_num >=
                       SubReqCountW'((mshr_d[replay_e].burst_len == BurstLenWidth'(1)) ?
                                     HoldSubsSingle : HoldSubsBurst));
          replay_rt = 32'(mshr_d[replay_e].sub_reqs[0].tile_id);
          replay_rp = 32'(mshr_d[replay_e].sub_reqs[0].port_id);
          if (replay_hold_done && !req_out_valid[replay_rt][replay_rp] &&
              req_out_ready[replay_rt][replay_rp]) begin
            req_out_valid[replay_rt][replay_rp]         = 1'b1;
            req_out[replay_rt][replay_rp]               = '0;
            req_out[replay_rt][replay_rp].wdata.meta_id = mshr_d[replay_e].sub_reqs[0].meta_id_base;
            req_out[replay_rt][replay_rp].wdata.core_id = mshr_d[replay_e].sub_reqs[0].core_id;
            req_out[replay_rt][replay_rp].wen           = 1'b0;
            req_out[replay_rt][replay_rp].be            = '1;
            req_out[replay_rt][replay_rp].tgt_group_id  = mshr_d[replay_e].tgt_group_id;
            req_out[replay_rt][replay_rp].tgt_addr      = mshr_d[replay_e].base_addr;
            req_out[replay_rt][replay_rp].burst_len     = mshr_d[replay_e].burst_len;
            req_out[replay_rt][replay_rp].mshr_tag      =
                MshrTagWidth'(replay_e) + MshrTagWidth'(1);
            mshr_d[replay_e].issued              = 1'b1;
          end
        end
      end
    end

    // AMO invalidates all cached entries (cache is best-effort only).
    if (EnableRespCache && amo_invalidate) begin
      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].state == MSHR_CACHED)) begin
          mshr_d_valid[mshr_i] = 1'b0;
          mshr_d[mshr_i] = '0;
          mshr_wr_all[mshr_i] = 1'b1;
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
        if (mshr_d_valid[e] && (mshr_d[e].state == MSHR_CACHED) &&
            (mshr_d[e].sub_reqs_num == '0) &&
            (mshr_d[e].served_cnt >=
             ServedCntW'((mshr_d[e].burst_len == BurstLenWidth'(1)) ? HoldSubsSingle : HoldSubsBurst))) begin
          mshr_d_valid[e] = 1'b0;
          mshr_d[e]       = '0;
          mshr_wr_all[e] = 1'b1;
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
                (mshr_q[resp_tag_cand].sub_reqs[0].core_id ==
                     resp_in[tile_i][port_i].rdata.core_id) &&
                ((resp_in[tile_i][port_i].rdata.meta_id -
                    mshr_q[resp_tag_cand].sub_reqs[0].meta_id_base) <
                       mshr_q[resp_tag_cand].burst_len)) begin
              resp_is_mshr[tile_i][port_i] = 1'b1;
              resp_mshr_id[tile_i][port_i] = resp_tag_cand;
            end
          end
        end

        if (resp_is_mshr[tile_i][port_i]) begin
          resp_capture_beat_offset[tile_i][port_i] =
              resp_in[tile_i][port_i].rdata.meta_id -
              mshr_q[resp_mshr_id[tile_i][port_i]].sub_reqs[0].meta_id_base;
          mshr_resp_inflight[resp_mshr_id[tile_i][port_i]] = 1'b1;
          resp_in_ready[tile_i][port_i] = (mshr_resp_slots[resp_mshr_id[tile_i][port_i]] != '0);
          if (resp_in_valid[tile_i][port_i] && resp_in_ready[tile_i][port_i]) begin
            resp_capture_fire[tile_i][port_i] = 1'b1;
            mshr_resp_slots[resp_mshr_id[tile_i][port_i]] =
                mshr_resp_slots[resp_mshr_id[tile_i][port_i]] - 1'b1;
          end
        end else begin
          resp_in_ready[tile_i][port_i] = resp_out_ready[tile_i][port_i];
        end

        if (resp_in_valid[tile_i][port_i] && !resp_is_mshr[tile_i][port_i]) begin
          resp_out_valid[tile_i][port_i] = 1'b1;
          resp_out[tile_i][port_i] = resp_in[tile_i][port_i];
          // ParityDrain bypass retag (design doc §4.6): a beat of a tracked bypassed burst gets
          // the same parity core_id retag as an MSHR-drained beat, so bypassed bursts also
          // deliver 2 beats/cycle (both tile resp ports -> both VLSU receive ports). Port choice
          // is untouched (bypass keeps the M4 non-backpressurable contract); only the xbar
          // destination changes. PD2=0 const-folds the term away.
          if (PD2 && bypass_match[tile_i][port_i]) begin
            resp_out[tile_i][port_i].rdata.core_id =
                resp_in[tile_i][port_i].rdata.core_id +
                tile_core_id_t'(bypass_beat_parity[tile_i][port_i]);
          end
          resp_from_bypass[tile_i][port_i] = 1'b1;
        end
      end
    end

    // Capture MSHR responses
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
              '{meta_id: resp_in[tile_i][port_i].rdata.meta_id,
                data:    resp_in[tile_i][port_i].rdata.data};
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
               SubReqCountW'(HoldSubsSingle))) begin
            mshr_d[resp_mshr_id[tile_i][port_i]].state = MSHR_RESP_HOLD;
            // Arm the serve-target timeout (0 => never expires; the countdown below is skipped).
            mshr_d[resp_mshr_id[tile_i][port_i]].hold_cnt = hold_ticks(ServeTimeout);
          end else begin
            mshr_d[resp_mshr_id[tile_i][port_i]].state = MSHR_DRAIN_RESP;
          end
`ifndef TARGET_SYNTHESIS
          mshr_d[resp_mshr_id[tile_i][port_i]].beat_seen[resp_capture_beat_offset[tile_i][port_i]] = 1'b1;
`endif
        end
      end
    end

    // A buffered response predates any store/AMO observed after it returned. Release the old value
    // to its already-recorded subscribers, but prohibit the entry from becoming a stale cache line.
    // This pass is after response capture so it also covers a response and invalidating operation
    // arriving in the same cycle.
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        if (req_in_valid[tile_i][port_i] && req_in_ready[tile_i][port_i] &&
            req_is_store[tile_i][port_i] &&
            (req_len[tile_i][port_i] == BurstLenWidth'(1))) begin
          for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
            cache_hit_e =
                int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i;
            if (mshr_d_valid[cache_hit_e] &&
                (mshr_d[cache_hit_e].state == MSHR_RESP_HOLD) &&
                (mshr_d[cache_hit_e].base_addr == req_addr_key[tile_i][port_i]) &&
                (mshr_d[cache_hit_e].tgt_group_id == req_in[tile_i][port_i].tgt_group_id)) begin
              mshr_d[cache_hit_e].state = MSHR_DRAIN_RESP;
              mshr_d[cache_hit_e].cacheable = 1'b0;
              mshr_d[cache_hit_e].beats_left = BurstLenWidth'(1);
              mshr_d[cache_hit_e].beat_pending = '0;
              mshr_d[cache_hit_e].beat_pending2 = '0;
              mshr_d[cache_hit_e].beat2_armed = 1'b0;
`ifndef TARGET_SYNTHESIS
              mshr_d[cache_hit_e].beat_seen = '0;
              mshr_d[cache_hit_e].beat_seen[0] = 1'b1;
`endif
`ifndef TARGET_SYNTHESIS
              mshr_d[cache_hit_e].beat_done = '0;
`endif
            end
          end
        end
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
    if (ServeTimeout != 0) begin
      for (int e = 0; e < MshrNum; e++) begin
        if (mshr_d_valid[e] && (mshr_d[e].state == MSHR_RESP_HOLD)) begin
          if (mshr_d[e].hold_cnt != '0) begin
            if (hold_tick[e]) mshr_d[e].hold_cnt = mshr_d[e].hold_cnt - HoldCntW'(1);
          end else begin
            // Expired: stop waiting for subscribers that are not coming and deliver the buffered
            // word to whoever HAS subscribed. Same re-arm the merge-target path performs.
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
            mshr_d_valid[e] = 1'b0;
            mshr_d[e]       = '0;
            mshr_wr_all[e] = 1'b1;
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
          resp_beat_offset[mshr_i] =
              mshr_d[mshr_i].resp_buf[mshr_d[mshr_i].resp_buf_rd_ptr].meta_id -
              mshr_d[mshr_i].sub_reqs[0].meta_id_base;
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
        resp_beat_offset2[mshr_i] =
            mshr_d[mshr_i].resp_buf[resp_rd_ptr2[mshr_i]].meta_id -
            mshr_d[mshr_i].sub_reqs[0].meta_id_base;
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
        drain_count[mshr_i] = '0;
        for (int s = 0; s < MshrMergeReqs; s++) begin
          subreq_claimed[mshr_i][s] = 1'b0;
        end
      end

      // Select one sub-request per response port.
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          if (!port_taken[tile_i][port_i]) begin
            // RR fairness (audit M3/L3): rotate the entry visit by drain_mshr_rr and the sub_req visit
            // by subreq_rr (separate bases) so high-index entries/sub_reqs are not starved. Bounded
            // wait: a pending (entry,sub_req) is a CONTINUOUS candidate (held in DRAIN_RESP until fully
            // drained), so the marching base reaches it within N. The eligibility predicate, the
            // per-PHYSICAL-index subreq_claimed cross-port guard, and resp_sel_* are byte-identical;
            // only the visit order rotates.
            // TIMING REWRITE (same selection; see the equivalence argument).
            //
            // The legacy form walked all MshrNum entries x MshrMergeReqs sub-requests in rotated
            // order carrying resp_sel_valid, i.e. a 128 x 4 = 512-deep serial first-match chain PER
            // PORT, and additionally carried subreq_claimed ACROSS the 32 ports -- chaining the
            // ports to each other as well.
            //
            // (1) subreq_claimed is DEAD. A candidate (entry,s) has exactly ONE destination:
            //     its tile comes from sub_reqs[s].tile_id and its port from either
            //     map_resp_port_id(sub_reqs[s].port_id) (single) or 1+(beat_offset&1) (PD2 burst).
            //     No two ports can ever evaluate the same (entry,s), so the flag could never block
            //     anything; only resp_sel_valid (one pick per port) ever mattered. Dropping it makes
            //     the 32 ports independent. It is still written below so the existing debug view and
            //     any waveform reference keep working.
            // (2) Within a port the scan is entry-major then sub-request-major in fixed rotated
            //     orders, so it is exactly: pick the first ENTRY that has any eligible sub-request,
            //     then the first eligible sub-request inside it. Two small rotated priority encodes
            //     (MshrNum-wide, then MshrMergeReqs-wide) reproduce that, at ~log2 depth instead of
            //     512 sequential stages.
            drain_sel_base     = EnableRrFairness ? int'(drain_mshr_rr_q) : 0;
            drain_sel_sub_base = EnableRrFairness ? int'(subreq_rr_q) : 0;
            // Per-entry: does this entry offer any sub-request eligible for THIS port?
            drain_ent_cand = '0;
            for (int e = 0; e < MshrNum; e++) begin
              if (mshr_d_valid[e] && (mshr_d[e].resp_buf_cnt != '0) &&
                  (mshr_d[e].state == MSHR_DRAIN_RESP)) begin
                for (int s = 0; s < MshrMergeReqs; s++) begin
                  if (mshr_d[e].sub_reqs[s].valid && mshr_d[e].beat_pending[s] &&
                      (mshr_d[e].sub_reqs[s].tile_id == tile_group_id_t'(tile_i)) &&
                      ((PD2 && (mshr_d[e].burst_len != BurstLenWidth'(1)))
                           ? ((RespPortIdW'(1) + RespPortIdW'(resp_beat_offset[e][0])) ==
                              port_i[RespPortIdW-1:0])
                           : (map_resp_port_id(mshr_d[e].sub_reqs[s].port_id) ==
                              port_i[RespPortIdW-1:0]))) begin
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
            drain_cand_rot = (drain_sel_base == 0)
                           ? drain_ent_cand
                           : ((drain_ent_cand >> drain_sel_base) |
                              (drain_ent_cand << (MshrNum - drain_sel_base)));
            drain_pfx = drain_cand_rot;
            for (int st = 1; st < MshrNum; st = st << 1) begin
              drain_pfx = drain_pfx | (drain_pfx << st);
            end
            drain_first = drain_pfx & ~(drain_pfx << 1);
            drain_idx   = 0;
            for (int b = 0; b < MshrNum; b++) begin
              if (drain_first[b]) drain_idx |= unsigned'(b);
            end
            drain_have_e = |drain_ent_cand;
            drain_win_e  = drain_have_e ? int'((drain_sel_base + drain_idx) % MshrNum) : 0;
            if (drain_have_e) begin
              // First eligible sub-request inside the winning entry, same rotated order.
              drain_sub_cand = '0;
              for (int s = 0; s < MshrMergeReqs; s++) begin
                if (mshr_d[drain_win_e].sub_reqs[s].valid && mshr_d[drain_win_e].beat_pending[s] &&
                    (mshr_d[drain_win_e].sub_reqs[s].tile_id == tile_group_id_t'(tile_i)) &&
                    ((PD2 && (mshr_d[drain_win_e].burst_len != BurstLenWidth'(1)))
                         ? ((RespPortIdW'(1) + RespPortIdW'(resp_beat_offset[drain_win_e][0])) ==
                            port_i[RespPortIdW-1:0])
                         : (map_resp_port_id(mshr_d[drain_win_e].sub_reqs[s].port_id) ==
                            port_i[RespPortIdW-1:0]))) begin
                  drain_sub_cand[s] = 1'b1;
                end
              end
              drain_have_s = 1'b0; drain_win_s = 0;
              for (int k = 0; k < MshrMergeReqs; k++) begin
                drain_scan_s = (drain_sel_sub_base + k) % MshrMergeReqs;
                if (!drain_have_s && drain_sub_cand[drain_scan_s]) begin
                  drain_have_s = 1'b1; drain_win_s = drain_scan_s;
                end
              end
              if (drain_have_s) begin
                resp_sel_valid[tile_i][port_i]      = 1'b1;
                resp_sel_mshr_id[tile_i][port_i]    = mshr_id_t'(drain_win_e);
                resp_sel_subreq_idx[tile_i][port_i] = drain_win_s[idx_width(MshrMergeReqs)-1:0];
                subreq_claimed[drain_win_e][drain_win_s]        = 1'b1;  // debug view only; not a guard
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
            // ParityDrain core_id retag: odd beats of a burst entry go to the next core data
            // port (VLSU mem port 1) so the tile xbar delivers 2 beats/cycle into one core.
            // Identity for single-word entries and when PD2=0 (legacy).
            resp_out[tile_i][port_i].rdata.core_id =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].core_id +
                ((PD2 && (mshr_d[resp_sel_mshr_id[tile_i][port_i]].burst_len != BurstLenWidth'(1)))
                     ? tile_core_id_t'(resp_beat_offset[resp_sel_mshr_id[tile_i][port_i]][0])
                     : '0);
            resp_out[tile_i][port_i].rdata.meta_id =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].meta_id_base +
                meta_id_t'(resp_beat_offset[resp_sel_mshr_id[tile_i][port_i]]);
            resp_out[tile_i][port_i].rdata.amo = '0;  // sub-requests are loads by construction (req_is_load)
            resp_from_mshr[tile_i][port_i] = 1'b1;
            resp_mshr_id_dbg[tile_i][port_i] = resp_sel_mshr_id[tile_i][port_i];

            if (resp_out_ready[tile_i][port_i]) begin
              mshr_d[resp_sel_mshr_id[tile_i][port_i]].beat_pending[
                  resp_sel_subreq_idx[tile_i][port_i]] = 1'b0;
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
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].valid = 1'b0;
              end
              drain_count[resp_sel_mshr_id[tile_i][port_i]] =
                  drain_count[resp_sel_mshr_id[tile_i][port_i]] + 1'b1;
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
        for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
          for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
            resp_sel2_valid[tile_i][port_i]      = 1'b0;
            resp_sel2_mshr_id[tile_i][port_i]    = '0;
            resp_sel2_subreq_idx[tile_i][port_i] = '0;
            if (!port_taken[tile_i][port_i] && !resp_sel_valid[tile_i][port_i]) begin
              drain2_base     = EnableRrFairness ? int'(drain_mshr_rr_q) : 0;
              // Hoisted: the sub-request base does not depend on kk/ks, but was previously
              // re-evaluated inside the inner loop on every unrolled iteration.
              drain2_sub_base = EnableRrFairness ? int'(subreq_rr_q) : 0;
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
              drain2_cand = '0;
              for (int e = 0; e < MshrNum; e++) begin
                if (mshr_d_valid[e] &&
                    (mshr_d[e].state == MSHR_DRAIN_RESP) &&
                    (mshr_d[e].burst_len != BurstLenWidth'(1)) &&
                    (mshr_d[e].resp_buf_cnt >= RespBufCountW'(2)) &&
                    mshr_d[e].beat2_armed) begin
                  for (int s = 0; s < MshrMergeReqs; s++) begin
                    if (mshr_d[e].sub_reqs[s].valid &&
                        mshr_d[e].beat_pending2[s] &&
                        (mshr_d[e].sub_reqs[s].tile_id == tile_group_id_t'(tile_i)) &&
                        ((RespPortIdW'(1) + RespPortIdW'(resp_beat_offset2[e][0])) ==
                         port_i[RespPortIdW-1:0])) begin
                      drain2_cand[e] = 1'b1;
                    end
                  end
                end
              end
              // Rotated first-set entry, parallel prefix (log2(MshrNum) doubling steps).
              drain2_cand_rot = (drain2_base == 0)
                              ? drain2_cand
                              : ((drain2_cand >> drain2_base) |
                                 (drain2_cand << (MshrNum - drain2_base)));
              drain2_pfx = drain2_cand_rot;
              for (int st = 1; st < MshrNum; st = st << 1) begin
                drain2_pfx = drain2_pfx | (drain2_pfx << st);
              end
              drain2_first = drain2_pfx & ~(drain2_pfx << 1);
              drain2_idx   = 0;
              for (int b = 0; b < MshrNum; b++) begin
                if (drain2_first[b]) drain2_idx |= unsigned'(b);
              end
              if (|drain2_cand) begin
                drain2_mshr_i = int'((drain2_base + drain2_idx) % MshrNum);
                // First eligible sub-request inside the winning entry, same rotated order.
                for (int ks = 0; ks < MshrMergeReqs; ks++) begin
                  drain2_s = (drain2_sub_base + ks) % MshrMergeReqs;
                  if (!resp_sel2_valid[tile_i][port_i] &&
                      mshr_d[drain2_mshr_i].sub_reqs[drain2_s].valid &&
                      mshr_d[drain2_mshr_i].beat_pending2[drain2_s] &&
                      (mshr_d[drain2_mshr_i].sub_reqs[drain2_s].tile_id == tile_group_id_t'(tile_i)) &&
                      ((RespPortIdW'(1) + RespPortIdW'(resp_beat_offset2[drain2_mshr_i][0])) ==
                       port_i[RespPortIdW-1:0])) begin
                    resp_sel2_valid[tile_i][port_i]      = 1'b1;
                    resp_sel2_mshr_id[tile_i][port_i]    = mshr_id_t'(drain2_mshr_i);
                    resp_sel2_subreq_idx[tile_i][port_i] = drain2_s[idx_width(MshrMergeReqs)-1:0];
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
              resp_out[tile_i][port_i].rdata.core_id =
                  mshr_d[drain2_sel_e2].sub_reqs[resp_sel2_subreq_idx[tile_i][port_i]].core_id +
                  tile_core_id_t'(resp_beat_offset2[drain2_sel_e2][0]);
              resp_out[tile_i][port_i].rdata.meta_id =
                  mshr_d[drain2_sel_e2]
                      .sub_reqs[resp_sel2_subreq_idx[tile_i][port_i]].meta_id_base +
                  meta_id_t'(resp_beat_offset2[drain2_sel_e2]);
              resp_out[tile_i][port_i].rdata.amo = '0;  // sub-requests are loads by construction (req_is_load)
              resp_from_mshr[tile_i][port_i] = 1'b1;
              resp_mshr_id_dbg[tile_i][port_i] = drain2_sel_e2;
              port_taken[tile_i][port_i] = 1'b1;
              if (resp_out_ready[tile_i][port_i]) begin
                mshr_d[drain2_sel_e2].beat_pending2[resp_sel2_subreq_idx[tile_i][port_i]] = 1'b0;
                drain_count[drain2_sel_e2] = drain_count[drain2_sel_e2] + 1'b1;
              end
            end
          end
        end
      end else begin
        resp_sel2_valid      = '0;
        resp_sel2_mshr_id    = '0;
        resp_sel2_subreq_idx = '0;
      end

    end else begin
      // Original behavior: one sub-request per MSHR per cycle.
      // (ParityDrain is only implemented for the DrainMultiPort=1 drain; keep its selects idle.)
      resp_sel2_valid      = '0;
      resp_sel2_mshr_id    = '0;
      resp_sel2_subreq_idx = '0;
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          // M4 (audit): bypass MUST take the port (non-backpressurable); MSHR drain is buffered and
          // bounded by finite bypass arrivals -- strict priority, not rotated. See the DrainMultiPort=1
          // path above for the full rationale. (This =0 path is inactive when DrainMultiPort=1.)
          port_taken[tile_i][port_i] = resp_in_valid[tile_i][port_i] &&
                                       !resp_is_mshr[tile_i][port_i];
        end
      end

      // RR fairness (audit M3): rotate the entry visit (mirror of the DrainMultiPort=1 path; inactive
      // when DrainMultiPort=1, kept aligned so the two paths do not silently diverge).
      drain3_base     = EnableRrFairness ? int'(drain_mshr_rr_q) : 0;
      // Hoisted out of both loops: neither base depends on kk or ks.
      drain3_sub_base = EnableRrFairness ? int'(subreq_rr_q) : 0;
      for (int kk = 0; kk < MshrNum; kk++) begin
        drain3_mshr_i = (drain3_base + kk) % MshrNum;
        drain_subreq_found[drain3_mshr_i] = 1'b0;
        drain_subreq_idx[drain3_mshr_i] = '0;
        drain_dst_tile[drain3_mshr_i] = '0;
        drain_dst_port[drain3_mshr_i] = '0;
        drain_port_found[drain3_mshr_i] = 1'b0;
        if (mshr_d_valid[drain3_mshr_i] && (mshr_d[drain3_mshr_i].resp_buf_cnt != '0) &&
            mshr_d[drain3_mshr_i].state == MSHR_DRAIN_RESP) begin
          // RR fairness (audit L3): rotate the sub_req visit, keep the first-match break.
          for (int ks = 0; ks < MshrMergeReqs; ks++) begin
            drain3_s = (drain3_sub_base + ks) % MshrMergeReqs;
            if (mshr_d[drain3_mshr_i].sub_reqs[drain3_s].valid &&
                mshr_d[drain3_mshr_i].beat_pending[drain3_s]) begin
              drain_subreq_found[drain3_mshr_i] = 1'b1;
              drain_subreq_idx[drain3_mshr_i] = drain3_s[idx_width(MshrMergeReqs)-1:0];
              break;
            end
          end

          if (drain_subreq_found[drain3_mshr_i]) begin
            drain_dst_tile[drain3_mshr_i] = mshr_d[drain3_mshr_i].sub_reqs[drain_subreq_idx[drain3_mshr_i]].tile_id;
            drain_dst_port[drain3_mshr_i] =
                map_resp_port_id(mshr_d[drain3_mshr_i].sub_reqs[drain_subreq_idx[drain3_mshr_i]].port_id);
            if (!port_taken[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]]) begin
              drain_port_found[drain3_mshr_i] = 1'b1;
            end

            if (drain_port_found[drain3_mshr_i]) begin
              resp_out_valid[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]] = 1'b1;
              resp_out[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]].wen = 1'b0;
              resp_out[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]].rdata.data =
                  mshr_d[drain3_mshr_i].resp_buf[mshr_d[drain3_mshr_i].resp_buf_rd_ptr].data;
              resp_out[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]].rdata.core_id =
                  mshr_d[drain3_mshr_i].sub_reqs[drain_subreq_idx[drain3_mshr_i]].core_id;
              resp_out[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]].rdata.meta_id =
                  mshr_d[drain3_mshr_i].sub_reqs[drain_subreq_idx[drain3_mshr_i]].meta_id_base +
                  meta_id_t'(resp_beat_offset[drain3_mshr_i]);
              resp_out[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]].rdata.amo = '0;
              resp_from_mshr[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]] = 1'b1;
              resp_mshr_id_dbg[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]] = mshr_id_t'(drain3_mshr_i);

              if (resp_out_ready[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]]) begin
                mshr_d[drain3_mshr_i].beat_pending[drain_subreq_idx[drain3_mshr_i]] = 1'b0;
                if (mshr_d[drain3_mshr_i].burst_len == BurstLenWidth'(1)) begin
                  mshr_d[drain3_mshr_i].sub_reqs[drain_subreq_idx[drain3_mshr_i]].valid = 1'b0;
                end
              end
              port_taken[drain_dst_tile[drain3_mshr_i]][drain_dst_port[drain3_mshr_i]] = 1'b1;
            end
          end
        end
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
            mshr_d[mshr_i].hold_cnt = hold_ticks(ServeTimeout);
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
              mshr_d[mshr_i] = '0;
              mshr_wr_all[mshr_i] = 1'b1;
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
                  mshr_d[mshr_i] = '0;
                  mshr_wr_all[mshr_i] = 1'b1;
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
              if (HoldWindowSingle != 0) begin
                if (mshr_q[e].hold_cnt == '0) rc_hold_to_s_inc    = rc_hold_to_s_inc + 1'b1;
                else                          rc_hold_early_s_inc = rc_hold_early_s_inc + 1'b1;
              end
            end else begin
              if (HoldWindowBurst != 0) begin
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
                        mshr_q[mshr_i].burst_len == BurstLenWidth'(1)) ==
           BankIdW'(mshr_i / MshrWaysPerBank)))
        else $fatal(1, "MSHR entry %0d not in its address bank (got %0d, expected %0d)",
                    mshr_i,
                    mshr_bank_of(mshr_q[mshr_i].base_addr, mshr_q[mshr_i].tgt_group_id,
                                 mshr_q[mshr_i].burst_len == BurstLenWidth'(1)),
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

endmodule : mempool_group_mshr
