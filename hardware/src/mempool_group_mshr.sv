// Copyright 2026 ETH Zurich and University of Bologna.

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

  // Parameter int MshrNum        = NumTilesPerGroup * 32,
  parameter int MshrNum        = `ifdef GROUP_MSHR_NUM `GROUP_MSHR_NUM `else NumTilesPerGroup `endif,
  parameter int MshrMergeWords = 1,
  parameter int MshrMergeReqs  = `ifdef GROUP_MSHR_MERGE_REQS `GROUP_MSHR_MERGE_REQS `else 8 `endif,
  // Address-banking: the MSHR table is partitioned into MshrNum/MshrWaysPerBank banks, a request
  // maps to bank_of({tgt_group,addr}), and allocation and the hit search stay inside that bank.
  parameter int MshrWaysPerBank = `ifdef GROUP_MSHR_WAYS_PER_BANK `GROUP_MSHR_WAYS_PER_BANK `else 4 `endif,
  // MSHR admission policy by effective load length:
  //   single     : req_len == 1
  //   non-full   : 1 < req_len < MshrFullBurstWords
  //   full-burst : req_len == MshrFullBurstWords
  parameter int unsigned MshrFullBurstWords = MaxBurstWords,
  parameter bit EnableMshrSingleReq         = `ifdef GROUP_MSHR_ENABLE_SINGLE `GROUP_MSHR_ENABLE_SINGLE `else 1'b0 `endif,
  parameter bit EnableMshrNonFullBurstReq   = `ifdef GROUP_MSHR_ENABLE_NON_FULL `GROUP_MSHR_ENABLE_NON_FULL `else 1'b1 `endif,
  parameter bit EnableMshrFullBurstReq      = `ifdef GROUP_MSHR_ENABLE_FULL `GROUP_MSHR_ENABLE_FULL `else 1'b1 `endif,
  // Per-entry buffered response beats (for out-of-order/multi-channel returns).
  // Sized by BANDWIDTH x DELAY, not by port count. The admission (mshr_resp_slots) only ever sees
  // REGISTERED state, so a slot's round trip is 2 cycles: captured -> registered -> the drain scan
  // sees it -> drained -> registered -> the admission sees it free. To sustain 2 beats/cycle the
  // capture (cap_first/cap_second) and drain (ParityDrain) datapaths are built for:
  // 2 beats/cycle x 2 cycles = 4 slots.
  // It settles at cnt=2 and holds 2 in / 2 out indefinitely. THREE DOES NOT WORK: slots = 3-2 = 1
  // caps admission at 1/cycle. The old value was NumRemoteRespPortsPerTile-1 = 2, which tied the
  // depth to the port count and gave exactly half the achievable rate.
  parameter int RespBufWords   = 4,
  // 0: drain one sub-request per MSHR per cycle (original behavior)
  // 1: drain as many sub-requests as ports allow per cycle
  parameter bit DrainMultiPort = 1'b1,
  // Round-robin fairness on the contended arbitration scans: the per-bank
  // allocation admit, the drain entry scan, and the drain sub_req scan all rotate their priority
  parameter bit EnableRrFairness = `ifdef GROUP_MSHR_ENABLE_RR `GROUP_MSHR_ENABLE_RR `else 1'b1 `endif,
  // Keep responded entries as a small read-response cache.
  parameter bit EnableRespCache = `ifdef GROUP_MSHR_RESP_CACHE `GROUP_MSHR_RESP_CACHE `else 1'b1 `endif,
  // Simulation-only statistics/prints (translate_off).
  parameter bit EnableStats   = `ifdef GROUP_MSHR_ENABLE_STATS `GROUP_MSHR_ENABLE_STATS `else 1'b0 `endif,
  // Stats print period in cycles while trace is active (0 disables periodic prints).
  parameter int unsigned StatsPeriod = `ifdef GROUP_MSHR_STATS_PERIOD `GROUP_MSHR_STATS_PERIOD `else 0 `endif,
  // Spill register enables (0 = pass-through).
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
  // The bank index both places an entry and looks it up, so re-hashing mid-flight makes a lookup
  // probe the wrong bank and a second entry is allocated for a line that already has one.
  output logic                                                                            mshr_busy_o
);

  localparam int unsigned RespPortIdW      = idx_width(NumRemoteRespPortsPerTile);
  localparam int unsigned ReqPortIdW       = idx_width(NumRemoteReqPortsPerTile);
  // ParityDrain (TwinROB0 receive): beats of one multi-beat entry drained per cycle.
  localparam int unsigned DrainBeatsPerEntry =
    `ifdef GROUP_MSHR_DRAIN_BEATS `GROUP_MSHR_DRAIN_BEATS
    `else 1 `endif;
  localparam bit PD2 = (DrainBeatsPerEntry > 1);

  // BURST LANE LAW: beat b belongs to VLSU lane b % NrMemPorts and is entry b / NrMemPorts of
  // that reorder buffer, so a burst's beats are distributed by the ordinary word->port rule.
  // Width of a beat OFFSET (0..MaxBurstWords-1). Distinct from BurstLenWidth, which sizes a LENGTH
  // (1..MaxBurstWords) and therefore needs one more bit.
  localparam int unsigned BeatOffW   = $clog2(mempool_pkg::MaxBurstWords);
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
  // misconfig guards: the parity datapath is hardwired for 2 beats/cycle and needs both usable
  // resp ports [2:1]; an illegal knob must fail elaboration, not wedge silently at runtime.
  // Two distinct conditions, deliberately at different severities: an $error must mean BROKEN,
  // and running at half the achievable response rate is suboptimal, not broken.
  if (RespBufWords < DrainBeatsPerEntry)
    $error({"[mempool_group_mshr] RespBufWords (%0d) < DrainBeatsPerEntry (%0d): the buffer cannot ",
            "even hold one cycle's drain width."}, RespBufWords, DrainBeatsPerEntry);
  else if (RespBufWords < 2 * DrainBeatsPerEntry)
    $warning({"[mempool_group_mshr] RespBufWords (%0d) < 2 x DrainBeatsPerEntry (%0d): the admission ",
              "sees only REGISTERED state, so a slot's round trip is 2 cycles. Below bandwidth x ",
              "delay the per-entry response rate is halved (admit N / admit 0 / admit N)."},
             RespBufWords, DrainBeatsPerEntry);
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
  // allocation is consumed locally and its NoC fetch is withheld for up to HoldWindow cycles, so
  // later requests to the same line can still merge into it. 0 releases the fetch immediately.
  localparam int unsigned HoldWindow = `ifdef GROUP_MSHR_HOLD_WINDOW `GROUP_MSHR_HOLD_WINDOW `else 0 `endif;
  // Per-request-type hold windows (default: the uniform HoldWindow).
  localparam int unsigned HoldWindowSingle = `ifdef GROUP_MSHR_HOLD_WINDOW_SINGLE `GROUP_MSHR_HOLD_WINDOW_SINGLE `else HoldWindow `endif;
  localparam int unsigned HoldWindowBurst = `ifdef GROUP_MSHR_HOLD_WINDOW_BURST `GROUP_MSHR_HOLD_WINDOW_BURST `else HoldWindow `endif;
  // The hold feature is active (and its logic generated) iff EITHER class holds; the counter is
  // sized from the larger of the two windows.
  localparam int unsigned HoldWindowMax =
    (HoldWindowSingle > HoldWindowBurst) ? HoldWindowSingle : HoldWindowBurst;
  localparam int unsigned HoldSubs = `ifdef GROUP_MSHR_HOLD_SUBS `GROUP_MSHR_HOLD_SUBS `else 2 `endif;
  // Per-request-type early-release targets (default: the uniform HoldSubs).
  localparam int unsigned HoldSubsSingle = `ifdef GROUP_MSHR_HOLD_SUBS_SINGLE `GROUP_MSHR_HOLD_SUBS_SINGLE `else HoldSubs `endif;
  localparam int unsigned HoldSubsBurst = `ifdef GROUP_MSHR_HOLD_SUBS_BURST `GROUP_MSHR_HOLD_SUBS_BURST `else HoldSubs `endif;
  // Scalar response-release policy.
  localparam bit RespWaitSubsSingle = `ifdef GROUP_MSHR_RESP_WAIT_SUBS_SINGLE `GROUP_MSHR_RESP_WAIT_SUBS_SINGLE `else 1'b0 `endif;
  // Cache self-invalidate (docs/mshr_bank_hash_design.md): a CACHED entry that has served its
  // per-type sharing target -- HoldSubsSingle for a scalar/single entry, HoldSubsBurst for a burst
  // -- retires itself instead of waiting for the cache timeout.
  localparam bit CacheSelfInval = `ifdef GROUP_MSHR_CACHE_SELF_INVAL `GROUP_MSHR_CACHE_SELF_INVAL `else 1'b0 `endif;
  // Cache reuse target / cache-phase timeout (group_mshr_cache_reuse_target, _cache_timeout).
  localparam int unsigned CacheReuseTarget = `ifdef GROUP_MSHR_CACHE_REUSE_TARGET `GROUP_MSHR_CACHE_REUSE_TARGET `else 0 `endif;
  localparam int unsigned CacheTimeout = `ifdef GROUP_MSHR_CACHE_TIMEOUT `GROUP_MSHR_CACHE_TIMEOUT `else 0 `endif;
  // Bank-full policy: 0 = bypass (legacy), 1 = backpressure. Reset value only when
  // MshrCfgRuntime=1; software owns it thereafter.
  localparam int unsigned BankfullBackpressure = `ifdef GROUP_MSHR_BANKFULL_BACKPRESSURE `GROUP_MSHR_BANKFULL_BACKPRESSURE `else 1 `endif;
  // RR cache-victim selection (group_mshr_cache_victim_rr): per-bank round-robin start pointer for
  // the pass-2 CACHED-reclaim scan, instead of always taking the lowest-index reclaimable.
  localparam bit CacheVictimRR = `ifdef GROUP_MSHR_CACHE_VICTIM_RR `GROUP_MSHR_CACHE_VICTIM_RR `else 1'b0 `endif;
  // CACHED replacement policy. 1 preserves the original pass-2 allocator behavior, where a bank
  // with no INVALID way may reclaim an idle CACHED way. 0 protects CACHED ways from allocation;
  // They remain resident until self-invalidation or the existing AMO invalidation.
  localparam bit CacheReclaimable = `ifdef GROUP_MSHR_CACHE_RECLAIMABLE `GROUP_MSHR_CACHE_RECLAIMABLE `else 1'b1 `endif;
  // Bypass-path delivery probe (simulation-only; see the gen_bypass_probe block). 0 = off.
  localparam bit BypassProbe = `ifdef GROUP_MSHR_BYPASS_PROBE `GROUP_MSHR_BYPASS_PROBE `else 1'b0 `endif;
  // RESP_HOLD stall probe (simulation-only; see gen_resp_hold_probe). Age in cycles after which a
  // still-held entry is reported; 0 = off.
  localparam int unsigned RespHoldProbe = `ifdef GROUP_MSHR_RESP_HOLD_PROBE `GROUP_MSHR_RESP_HOLD_PROBE `else 0 `endif;
  // Stall (instead of allocating a duplicate entry) when a same-address entry is receiving its
  // response this very cycle -- see req_addr_hit_drain_way.
  localparam bit StallOnResp = `ifdef GROUP_MSHR_STALL_ON_RESP `GROUP_MSHR_STALL_ON_RESP `else 1'b1 `endif;
  localparam int unsigned VictimPtrW = (MshrWaysPerBank > 1) ? $clog2(MshrWaysPerBank) : 1;
  // hold_cnt is sized from the window itself, so ANY window value is supported -- there is no
  localparam int unsigned ServeTimeout = `ifdef GROUP_MSHR_SERVE_TIMEOUT `GROUP_MSHR_SERVE_TIMEOUT `else 0 `endif;
  // The counter must be sized for the LARGEST value that can ever be loaded, and at
  // MshrCfgRuntime=1 that is the hardware bound, NOT the elaborated default -- software can write
  localparam int unsigned HoldCntElabMax =
    (HoldWindowMax > ServeTimeout) ? HoldWindowMax : ServeTimeout;
  localparam int unsigned HoldCntMax =
    mempool_pkg::MshrCfgRuntime ? mempool_pkg::MshrCfgHoldCntMax : HoldCntElabMax;
  // HOLD PRESCALER: hold_cnt ticks every 2**HoldPrescaleW cycles, not every cycle, so the counter
  // is narrower and MshrNum counters no longer toggle every cycle.
  localparam int unsigned HoldPrescaleW = `ifdef GROUP_MSHR_HOLD_PRESCALE_W `GROUP_MSHR_HOLD_PRESCALE_W `else 4 `endif;
  localparam int unsigned HoldPrescaleWSafe = (HoldPrescaleW > 0) ? HoldPrescaleW : 1;

  // DrainFromQ (group_mshr_drain_from_q): source the response-drain eligibility scan from the
  // REGISTERED entry array instead of the combinational next state.
  localparam bit BankPublish = `ifdef GROUP_MSHR_BANK_PUBLISH `GROUP_MSHR_BANK_PUBLISH `else 1'b0 `endif;

  // Source the hold-the-fetch REPLAY walker from the registered array.
  localparam bit ReplayFromQ = `ifdef GROUP_MSHR_REPLAY_FROM_Q `GROUP_MSHR_REPLAY_FROM_Q `else 1'b1 `endif;

  // req_meta_ovlp_map is the last [lane][MshrNum] structure in the module: 32 lanes x 64 entries =
  // 2048 replications of a tile compare, a core compare and a two-sided modular range test. But the
  // relation is SPARSE -- the test is gated on sub_reqs[0].tile_id == tile_i, and an entry has
  localparam bit MetaOvlpByOwner = `ifdef GROUP_MSHR_META_OVLP_BY_OWNER `GROUP_MSHR_META_OVLP_BY_OWNER `else 1'b1 `endif;
  // Extend the head-beat drain's BankPublish narrowing to the second-slot (drain2) selector,
  // which is otherwise ungated and runs MshrNum-wide in every config x 32 (tile, resp port)
  // instances. Published entries are addressed as b*MshrWaysPerBank + pub_w[b] with b a loop
  // constant, so the sub-request lookup stays MshrWaysPerBank:1, never MshrNum:1.
  // Same trade as next door: a lane whose target sits in a bank that published a different
  // entry waits a cycle. Publication rotates, and a drain2 candidate is continuous.
  localparam bit Drain2BankPublish = `ifdef GROUP_MSHR_DRAIN2_BANK_PUBLISH `GROUP_MSHR_DRAIN2_BANK_PUBLISH `else 1'b1 `endif;
  // Arbitrate response capture per BANK instead of per entry: MshrBankNum arbiters instead of
  // MshrNum, paid for with a NumRespLanes:1 entry select and a dynamic index into
  // mshr_resp_slots. Measured on the reference shape: no cost -- cycles and [CAPARB] identical
  // on and off, so the 31.6% deferral there is the resp-buf-full case, not bank contention.
  localparam bit CapPerBank = `ifdef GROUP_MSHR_CAP_PER_BANK `GROUP_MSHR_CAP_PER_BANK `else 1'b1 `endif;
  // NOT DONE: the two aging sweeps (cache self-invalidate, and the serve-timeout / cache age-out
  // countdown) are also whole-array passes on mshr_d and were the obvious third knob here.
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
  // range check (mempool_group_mshr_cfg.sv: subs_ok = [1, MergeReqs]).
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
  // resp_wait_subs_single makes delivery wait for a subscriber target, and cache_reclaimable=0.
  if ((RespWaitSubsSingle || !CacheReclaimable) && (ServeTimeout == 0))
    $error("[mempool_group_mshr] group_mshr_resp_wait_subs_single=1 or group_mshr_cache_reclaimable=0 requires group_mshr_serve_timeout > 0 (no release path otherwise).");
  localparam int unsigned SubReqCountW     = idx_width(MshrMergeReqs + 1);

  // RUNTIME CONFIG SELECT: each cfg_* is the localparam at MshrCfgRuntime=0 (folds to a constant)
  // and the CSR field at 1. READ THESE at the use sites, never the localparams.
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
  // hold_subs == 1 means "this class does not merge -- bypass it".
  logic                                    cfg_bypass_single, cfg_bypass_burst;

  // The merge rank and slot need their OWN width, not SubReqCountW.
  localparam int unsigned MergeRankW      = idx_width(2 * MshrMergeReqs + 1);
  localparam int unsigned MergeCountW     = idx_width(NumTilesPerGroup *
                                              ((NumRemoteReqPortsPerTile > 1) ?
                                               (NumRemoteReqPortsPerTile - 1) : 1) + 1);
  // served_cnt only has to reach the larger sharing target, where it saturates.
  localparam int unsigned ServedCntElabMax = (HoldSubsSingle > HoldSubsBurst)
                                             ? HoldSubsSingle : HoldSubsBurst;
  // 2*MshrMergeReqs, not MshrMergeReqs.
  localparam int unsigned ServedCntMax     = mempool_pkg::MshrCfgRuntime ? (2 * MshrMergeReqs)
                                                                         : ServedCntElabMax;
  localparam int unsigned ServedCntW       = idx_width(ServedCntMax + 1);
  localparam int unsigned RespBufCountW    = idx_width(RespBufWords + 1);
  localparam int unsigned RespBufPtrW      = idx_width(RespBufWords);
  localparam int unsigned MergeWordOffset  = (MshrMergeWords <= 1) ? 0 : $clog2(MshrMergeWords);
  localparam int unsigned BurstAlignBits  = (MaxBurstWords > 1) ? $clog2(MaxBurstWords) : 1;
  localparam int unsigned TileIdBits       = idx_width(NumTilesPerGroup);
  localparam int unsigned TcdmAddrNoTileW  = $bits(tcdm_addr_t) - TileIdBits;
  localparam int unsigned SpatzNumOutstandingLoads = snitch_pkg::NumIntOutstandingLoads;
  // Address-banking geometry: MshrBankNum banks of MshrWaysPerBank entries each.
  localparam int unsigned MshrBankNum = (MshrWaysPerBank > 0) ? (MshrNum / MshrWaysPerBank) : 1;
  localparam int unsigned BankIdW     = idx_width(MshrBankNum);
  // Current coalescer merges only exact 32-bit words (MshrMergeWords should be 1).

  // Bank-select hash choice (docs/mshr_bank_hash_design.md).
  localparam int unsigned BankHash = `ifdef GROUP_MSHR_BANK_HASH `GROUP_MSHR_BANK_HASH `else 0 `endif;
  // Bank-select field shift for BankHash==3 (field-select on the reconstructed LINEAR word
  // address).
  localparam int unsigned BankSelShift = `ifdef GROUP_MSHR_BANK_SHIFT `GROUP_MSHR_BANK_SHIFT `else 5 `endif;
  // Per-request-type field-select shifts (default: the uniform BankSelShift).
  localparam int unsigned BankSelShiftSingle = `ifdef GROUP_MSHR_BANK_SHIFT_SINGLE `GROUP_MSHR_BANK_SHIFT_SINGLE `else BankSelShift `endif;
  localparam int unsigned BankSelShiftBurst = `ifdef GROUP_MSHR_BANK_SHIFT_BURST `GROUP_MSHR_BANK_SHIFT_BURST `else BankSelShift `endif;
  // Burst-branch hash structure (BankHash==3, bursts only).
  localparam int unsigned BankBurstBits = `ifdef GROUP_MSHR_BANK_BURST_BITS `GROUP_MSHR_BANK_BURST_BITS `else 1 `endif;
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
  // intra-load burst bits end at BurstAlignBits+BankBurstBits-1.
  if ((BankHash == 3) && (BankSelShiftBurst < BurstAlignBits + BankBurstBits))
    $error("[mempool_group_mshr] group_mshr_bank_shift_burst (%0d) overlaps the intra-load burst bits [%0d +: %0d]. Set it to clog2(p_start gap in words), e.g. 5 (M=P=256) / 7 (M=P=512).",
           BankSelShiftBurst, BurstAlignBits, BankBurstBits);
    // Bb == BankIdW is LEGAL: every bank bit then comes from the intra-load burst index, which is
    // exactly what a shape with ONE p-slice per group (KS=1) needs.
    if ((BankHash == 3) && (BankBurstBits > BankIdW))
      $error("[mempool_group_mshr] group_mshr_bank_burst_bits (%0d) exceeds BankIdW (%0d).",
           BankBurstBits, BankIdW);

  // Map a (target group, merge address key, request type) to its MSHR bank.
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
      // Field-select on the reconstructed LINEAR word address (pure re-wiring: put the group field
      // back above the tile field).
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
        // bit just above the burst boundary.
        b = { word_addr[sh_burst +: BankIdW - 1],
              word_addr[BurstAlignBits +: 1] };
      end
    end else if (BankHash == 0) begin
      // Legacy: each bank bit is the XOR of a fixed stride-BankIdW subset of address bits.
      for (int i = BurstAlignBits; i < $bits(tcdm_addr_t); i++) begin
        b[(i - BurstAlignBits) % BankIdW] = b[(i - BurstAlignBits) % BankIdW] ^ addr_key[i];
      end
    end else if (BankHash == 1) begin
      mix = addr_key >> BurstAlignBits;
      mix = mix ^ (mix >> 7);
      mix = mix ^ (mix >> 13);
      mix = mix ^ (mix >> 17);
      for (int i = 0; i < $bits(tcdm_addr_t); i++) begin
        b[i % BankIdW] = b[i % BankIdW] ^ mix[i];
      end
    end else begin
      // Include the low BurstAlignBits (the tile field of tgt_addr) in the bank index, on top of
      // the legacy fold of the higher bits.
      b = b ^ BankIdW'(addr_key[BurstAlignBits-1:0]);
      for (int i = BurstAlignBits; i < $bits(tcdm_addr_t); i++) begin
        b[(i - BurstAlignBits) % BankIdW] = b[(i - BurstAlignBits) % BankIdW] ^ addr_key[i];
      end
    end
    return b;
  endfunction

  // Per-entry MSHR lifecycle: - IDLE: entry is free/unused (typically valid=0).
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
    // No `amo` field: a sub-request only exists behind req_can_merge, which requires req_is_load.
  } mempool_group_mshr_sub_req_t;

  // Response-buffer slot -- NOT a full tcdm_master_resp_t: the drain path builds its reply from
  // sub_reqs, so only the fields below are ever read back.
  // BeatOffW, not BurstLenWidth: this field holds an OFFSET (0..MaxBurstWords-1), not a length
  // (1..MaxBurstWords). A value is written only after burst_beat_valid() passed, which requires
  // beat < burst_len <= MaxBurstWords, so 0..15 is provable -- see the assertion at the capture.
  // NOTE burst_beat_of()'s RETURN type must stay BurstLenWidth: it is called inside
  // burst_beat_valid() on responses not yet proven in range, and the extra bit is what makes an
  // out-of-range raw value (16..31) fail `beat_of < len`. At 4 bits a raw 16 truncates to 0, passes
  // the check, and a bogus response is accepted as beat 0 -- silent burst corruption.
  typedef struct packed {
    logic [BeatOffW-1:0] beat_off;
    data_t               data;
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
    // entry has admitted/served over its whole life (owner + every merge, in WAIT_RESP and
    logic [ServedCntW-1:0] served_cnt;
    // Per-head-beat pending mask: bit s=1 means requester s still needs the current
    // buffered response beat; cleared as each requester is serviced.
    logic [MshrMergeReqs-1:0] beat_pending;
    // ParityDrain second-slot service state (the beat at resp_buf_rd_ptr+1, burst entries only):
    // Pending mask + one-shot arm flag.
    logic [MshrMergeReqs-1:0] beat_pending2;
    logic                     beat2_armed;
    // Number of response beats still required to complete the whole entry.
    // Decremented once per fully drained beat.
    logic [BurstLenWidth-1:0] beats_left;
    // Per-beat bookkeeping (no per-beat payload stored here):
    // - beat_seen[b]: beat b has been captured from NoC (possibly out-of-order)
    // - beat_done[b]: beat b has been fully drained to all merged requesters
`ifndef TARGET_SYNTHESIS
    // VERIFICATION ONLY: every read of beat_seen is an assertion, so it is excluded from synthesis.
    logic [MaxBurstWords-1:0] beat_seen;
`endif
`ifndef TARGET_SYNTHESIS
    // VERIFICATION ONLY, for the same reason as beat_seen above: its only reader is the
    // beat_done_subset_seen assertion.
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
  // Block-local scratch values, hoisted out of the always blocks: packed signals at module scope
  // instead of procedural automatics, so they are visible in a waveform.
  mshr_id_t                cache_hit_e;
  mshr_id_t                evict_vid;
  logic [VictimPtrW-1:0]   evict_vw;
  mshr_id_t      drain2_sel_e2;
  mshr_id_t      resp_tag_cand;
  mshr_id_t      rsn_tag_cand;
  // Clock-gate write flags, raised at the write sites themselves (see the entry register block).
  logic [MshrNum-1:0]                                                          mshr_wr_all;
  logic [MshrNum-1:0]                                                          mshr_id_we;
  logic [MshrNum-1:0][RespBufWords-1:0]                                        mshr_rb_we;
  mempool_group_mshr_t [MshrNum-1:0]                                           mshr_q;
  logic                [MshrNum-1:0]                                           mshr_d_valid;
  logic                [MshrNum-1:0]                                           mshr_q_valid;
  // Occupancy, exported so the CSR file can refuse a bank-hash change while entries are resident.
  // Hold-the-fetch replay walk start pointer (rotates every cycle for fairness among held
  // entries contending for the same outbound lane). Tied off when the feature is compiled out.
  mshr_id_t                                                                    hold_replay_rr_q;
  // Only an assertion reads this now: term-for-term identical to req_resp_seen on the same
  // candidate. Synthesis drops it with its last reader.
  logic                [MshrNum-1:0]                                           mshr_resp_inflight;
  // per-response-lane validation, kept as (valid, target entry id) instead of scattered into a
  // MshrNum-wide vector. Both consumers index that vector by e_abs -- a DIFFERENT dynamic index --
  // so the scatter was immediately undone by a 64:1 re-mux. Comparing ids removes scatter and mux.
  logic     [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]                   rsn_v;
  mshr_id_t [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]                   rsn_id;
  logic     [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_resp_seen;
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
  // Bank-scoped hit detection: each request compares its address against only the
  // MshrWaysPerBank entries of its own bank (req_bank), not all MshrNum.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_addr_hit_way;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_addr_hit_drain_way;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_hit_way;
  // Merge capacity for this way, evaluated where the entry index is still the EARLY req_bank.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_hit_cap_way;
  // Meta-overlap is a CROSS-address check (same tile+core, different address, overlapping meta_id
  // range) that protects core-side (core,meta_id) response uniqueness.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrNum-1:0]         req_meta_ovlp_map;
  // Meta-range overlap: one result per (entry, req port), scattered by an owner one-hot. An entry
  // has exactly one owner tile, so the per-lane form was 63/64 dead.
  logic      [MshrNum-1:0][NumRemoteReqPortsPerTile-1:1]                             mo_ovlp;
  logic      [MshrNum-1:0][NumTilesPerGroup-1:0]                                     mo_owner_oh;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_addr_hit_drain;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_meta_conflict;
  /// An allocation from this lane's own (tile, core) is recorded but not yet in mshr_q, so
  /// req_meta_ovlp_map cannot see its meta range. Conservative: same owner, any bank.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_owner_inflight;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrBankNum-1:0]  req_owner_inflight_bank;
  /// This request's line is being allocated right now -- recorded in agb_q_*, not yet in mshr_q.
  /// req_addr_hit_way reads the way's OLD key and would miss, so without forwarding the request
  /// either allocates a duplicate (wrong) or waits a cycle. Forward instead: the target entry id
  /// is b*MshrWaysPerBank + agb_q_way[b], so the follower merges into the leader's entry at once.
  /// b*WaysPerBank + agb_q_way[b], so the follower merges into the leader's entry immediately.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_fwd_hit;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_fwd_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr_sel_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr_sel_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_cap_sel;
  logic      [MshrNum-1:0]                                                     mshr_hit_req;
  /// Per-entry, per-lane hit terms feeding mshr_hit_req. Only generated at CacheReclaimable=1.
  logic [MshrNum-1:0][NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]      mshr_hit_req_lane;

  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_ready;
  // Prefix rank of same-target merging ports.
  logic                                                                                           amo_invalidate;

  // Request allocation (banked allocator bookkeeping).
  logic    [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found;
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found_mshr_id;
  // Per-bank single-allocation-per-cycle scheme: req_alloc_cand marks a request that
  // wants a new entry: a mergeable load that missed, with no drain or meta hazard.
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
`ifndef TARGET_SYNTHESIS
  logic      [MshrNum-1:0][BurstLenWidth-1:0]                                  resp_beat_offset;
`endif
  // ParityDrain second-slot scheduling ('0/unused when DrainBeatsPerEntry == 1).
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel2_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel2_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]
             [idx_width(MshrMergeReqs)-1:0]                                    resp_sel2_subreq_idx;
  // The entry view the second-slot scan reads, and the second-slot read pointer
  // and beat offset derived from THAT view. Const-folds away entirely at Drain2FromQ = 0.
  mempool_group_mshr_t [MshrNum-1:0]                                           drain2_scan_ent;
  logic      [MshrNum-1:0]                                                     drain2_scan_valid;
  // The entry view the hold-the-fetch replay walker reads.
  mempool_group_mshr_t [MshrNum-1:0]                                           replay_scan_ent;
  logic      [MshrNum-1:0]                                                     replay_scan_valid;
  // One bit per entry, "some store lane forced this RESP_HOLD entry to drain this cycle".
  logic      [MshrNum-1:0]                                                     st_force_drain;
  // Serve-timeout predicate and window value, both from registered state plus fire terms.
  logic                                                                        st_hold_live;
  logic      [HoldCntW-1:0]                                                    st_hold_src;
  // Allocation's valid-set, applied as one OR at the end of the pass so the arbiter stays out of
  // every clear guard. Safe: allocation writes MSHR_WAIT_RESP, and every clear requires CACHED,
  // RESP_HOLD or DRAIN_RESP with resp_buf_cnt != 0, so no clear can fire on a just-allocated entry.
  logic      [MshrNum-1:0]                                                     mshr_alloc_set;
  /// SOURCING DISCIPLINE -- read this once; the sites below refer back to it.
  /// The entry array has two vintages: `mshr_q` is the register, `mshr_d` is what this cycle's
  /// passes have written so far. A pass reading `mshr_d` inherits the depth of every earlier pass
  /// that wrote it.
  /// The rule: if a later pass depends only on WHETHER an earlier one fired -- not on the value it
  /// wrote -- compute it from `mshr_q` plus a narrow fire term, so the two evaluate in PARALLEL.
  /// `alloc_inflight` / `merge_inflight` / `st_post_cap` exist for exactly that.
  /// HARD LIMIT: a pass whose TRIGGER and DATA come from different vintages is wrong whenever the
  /// two can disagree. Both must be mshr_q, or both mshr_d. Sites that depart say why in one line.
  /// Break the serial read-modify-write chain on mshr_d[e].state. The store force-drain needs
  /// "a buffered response predates any store/AMO observed after it returned", which depends only on
  /// WHETHER THE CAPTURE FIRED, not on the state it wrote -- so st_post_cap computes it in parallel
  /// from mshr_q plus the capture's own fire terms. Sites that need the pre-capture value keep
  /// reading mshr_d.
  logic      [MshrNum-1:0]                                                     st_alloc_fire;
  logic      [MshrNum-1:0]                                                     st_merge_drain;

  /// REQUEST PIPELINE CUT (stage boundary).
  /// The arbiter decision is registered here and the entry write happens next cycle, splitting the
  /// request cone into two roughly equal halves.
  /// Everything downstream reads these records, never the combinational agb_* / mgb_*, so the
  /// arbiter output is out of the entry-write cone entirely.
  logic [MshrBankNum-1:0]                    agb_q_v;
  logic [MshrBankNum-1:0][VictimPtrW-1:0]    agb_q_way;
  tcdm_addr_t [MshrBankNum-1:0]              agb_q_addr;
  group_id_t [MshrBankNum-1:0]               agb_q_grp;
  logic [MshrBankNum-1:0][BurstLenWidth-1:0] agb_q_len;
  tile_group_id_t [MshrBankNum-1:0]          agb_q_tile;
  logic [MshrBankNum-1:0][RespPortIdW-1:0]   agb_q_port;
  tile_core_id_t [MshrBankNum-1:0]           agb_q_core;
  meta_id_t [MshrBankNum-1:0]                agb_q_meta;
  logic [MshrBankNum-1:0]                    mgb_q_v;
  logic [MshrBankNum-1:0][VictimPtrW-1:0]    mgb_q_way;
  tile_group_id_t [MshrBankNum-1:0]          mgb_q_tile;
  logic [MshrBankNum-1:0][RespPortIdW-1:0]   mgb_q_port;
  tile_core_id_t [MshrBankNum-1:0]           mgb_q_core;
  meta_id_t [MshrBankNum-1:0]                mgb_q_meta;

  /// Per-entry views of the two in-flight records: "a write for this entry is registered but has
  /// not reached mshr_q yet". Bank and way are compile-time constants per entry, so each is one
  /// compare against a register -- no variable index, nothing from the request path.
  logic [MshrNum-1:0] alloc_inflight;
  logic [MshrNum-1:0] merge_inflight;
  logic [MshrNum-1:0] merge_decided;
  /// mshr_q_valid as the free-way lookup must see it: an in-flight allocation already owns its way.
  logic [MshrNum-1:0] free_way_valid;

  // Busy must also cover a decision that is recorded but not yet in mshr_q, or the bank-hash CSR
  // could be rewritten in that window.
  assign mshr_busy_o = (|mshr_q_valid) | (|agb_q_v) | (|mgb_q_v);

  logic      [MshrNum-1:0]                                                     st_cap_fire;
  logic      [MshrNum-1:0]                                                     st_cap_hold;
  mshr_state_t [MshrNum-1:0]                                                   st_post_cap;
  // st_post_cap == MSHR_RESP_HOLD, reduced per entry so a lane selects one bit instead of
  // muxing the state and comparing afterwards.
  logic        [MshrNum-1:0]                                                   st_hold_post_cap;
  // Response capture is decided per ENTRY instead of chained across lanes.
  localparam int unsigned NumRespPortsActive = (NumRemoteRespPortsPerTile > 1) ?
                                               (NumRemoteRespPortsPerTile - 1) : 1;
  localparam int unsigned NumRespLanes       = NumTilesPerGroup * NumRespPortsActive;
  localparam int unsigned RespLaneW          = idx_width(NumRespLanes);
  logic [MshrNum-1:0][NumRespLanes-1:0]                                        cap_want;
  logic [MshrNum-1:0][NumRespLanes-1:0]                                        cap_first, cap_second;
  logic [NumRespLanes-1:0]                                                     cap_rest;
  logic [MshrNum-1:0]                                                          cap_g1, cap_g2;
  // Per-bank capture arbitration (CapPerBank).
  logic [MshrBankNum-1:0][NumRespLanes-1:0]                                    capb_want;
  logic [MshrBankNum-1:0][NumRespLanes-1:0]                                    capb_l1, capb_l2;
  logic [NumRespLanes-1:0]                                                     capb_rest;
  mshr_id_t [MshrBankNum-1:0]                                                  capb_e1, capb_e2;
  logic [MshrBankNum-1:0]                                                      capb_g1, capb_g2;
  logic [MshrBankNum-1:0]                                                      capb_same;
  logic [RespLaneW-1:0]                                                        capb_lane;
  // Per-entry masks of what the two drain DRIVE loops want cleared. Both loops only ever
  // clear BITS, and bit clears commute -- so ORing the requests and applying one AND-NOT per entry
  // is identical to letting 32 lanes each read-modify-write the entry in turn.
  logic [MshrNum-1:0][MshrMergeReqs-1:0]                                       bp_clr, bp2_clr, sv_clr;
  // Store byte-merge into CACHED lines, decided per entry instead of chained across lanes.
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
  /// Per (entry, byte): which lanes want to write that byte, which one wins, and its data.
  /// The winner is the HIGHEST lane index, reproducing the old loop's last-writer-wins.
  logic [MshrNum-1:0][StrbW-1:0][NumReqLanes-1:0]                              stb_byte_req;
  logic [MshrNum-1:0][StrbW-1:0][NumReqLanes-1:0]                              stb_byte_win;
  logic [MshrNum-1:0][StrbW-1:0][7:0]                                          stb_byte_data;
  mshr_resp_slot_t [MshrNum-1:0]                                               cap_d0, cap_d1;
  logic [RespBufPtrW-1:0]                                                      cap_s0, cap_s1, cap_n0, cap_n1;
  logic      [RespBufCountW-1:0]                                               cap_cnt_sum;
  logic [RespLaneW-1:0]                                                        cap_lane;
  // The grant takes at most TWO lanes per entry per cycle (cap_first/cap_second are one-hot). With
  // RespBufWords > 2 that is no longer "one grant per free slot", and that is INTENTIONAL: the
  // capture datapath is built for 2 beats/cycle and the extra depth exists to cover the admission's
  // 2-cycle view of the buffer, not to capture more per cycle. A third lane targeting the same
  // entry is NOT dropped -- it gets neither cap_first nor cap_second, so resp_in_ready stays low
  // and it retries next cycle. The pointer arithmetic below is generic in RespBufWords (modulo
  // wraparound via cap_n0/cap_n1, count saturating at RespBufWords), so no generalisation is
  // required. The real sizing constraint is asserted above: RespBufWords >= 2 x DrainBeatsPerEntry.
  logic      [MshrNum-1:0][RespBufPtrW-1:0]                                    drain2_rd_ptr;
  logic      [MshrNum-1:0][BurstLenWidth-1:0]                                  drain2_beat_off;

  logic      [MshrNum-1:0][RespBufCountW-1:0]                                  mshr_resp_slots;

  /// Response admission credit, per entry. A pure register-to-output cone: it reads mshr_q only,
  /// so it does not depend on this cycle's request pass. Two earlier mshr_d writes to resp_buf_cnt
  /// are deliberately not seen -- allocation cannot be captured into (resp_is_mshr needs
  /// mshr_q_valid), and the store byte-merge only touches MSHR_CACHED entries while capture needs
  /// WAIT_RESP/DRAIN_RESP, so the worst divergence is 0 vs 1 against 4 slots.
  generate
    for (genvar e = 0; e < MshrNum; e++) begin : gen_resp_slots
      assign mshr_resp_slots[e] =
          (mshr_q_valid[e] && (mshr_q[e].resp_buf_cnt < RespBufWords))
            ? (RespBufCountW'(RespBufWords) - mshr_q[e].resp_buf_cnt) : '0;
    end
  endgenerate
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_capture_fire;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]
             [BurstLenWidth-1:0]                                               resp_capture_beat_offset;
  logic      [MshrNum-1:0]                                                     resp_head_beat_pending;
  logic      [MshrNum-1:0][RespBufCountW-1:0]                                  resp_cnt_after_pop;
  // Finalize pop-count terms (see the finalize pass). Per entry, evaluated from the values
  // entering that pass so the head and second beat do not chain.
  logic                                                                        fin_cache;
  logic                                                                        fin_head;
  logic                                                                        fin_second_en;
  logic                                                                        fin_second;
  logic                                                                        fin_retire;
  logic      [1:0]                                                             fin_pop;
  // Response drain scheduling (single-response per MSHR).

  // Round-robin fairness bases.
  localparam int unsigned NumReqPortsActive = (NumRemoteReqPortsPerTile > 1) ?
                                              (NumRemoteReqPortsPerTile - 1) : 1;
  localparam int unsigned NumAllocSlots     = NumTilesPerGroup * NumReqPortsActive;
  localparam int unsigned AllocRrW          = idx_width(NumAllocSlots);
  // Sized by NumAllocSlots, so these must follow it rather than sit beside req_merge_*.
  logic [NumAllocSlots-1:0] merge_same_mask;   // earlier ports targeting the SAME entry
  logic [AllocRrW-1:0]      alloc_rr_q, alloc_rr_d;
  // (B) drain: rotate the MSHR-entry scan axis (MshrNum entries) -- width is MshrIdxW below.
  // Natural widths for the rotated scan indices. Power-of-two MshrNum/MshrMergeReqs is
  // asserted at elaboration, so truncation to these widths is exactly mod-N.
  localparam int unsigned MshrIdxW = idx_width(MshrNum);
  localparam int unsigned SubIdxW  = idx_width(MshrMergeReqs);

  // Per-lane parallel first-match for the hold-the-fetch replay.
  logic [MshrNum-1:0]                                        replay_ready;    // hold-done + eligible
  tile_group_id_t [MshrNum-1:0]                              replay_own_t;
  logic [MshrNum-1:0][RespPortIdW-1:0]                       replay_own_p;
  logic [MshrNum-1:0]                                        replay_rr_mask;
  logic [MshrNum-1:0]                                        replay_cand, replay_hi, replay_lo, replay_win_oh;
  logic [MshrIdxW-1:0]                                       replay_win_e;
  // BankPublish splits the entry-space rotation base into {bank, way} by bit position. idx_width()
  // floors at 1 for a single-element axis, so with MshrBankNum==1 or MshrWaysPerBank==1 the two
  // halves no longer tile the entry index and the split would silently select the wrong bank.
  if (BankPublish && (MshrIdxW != (BankIdW + VictimPtrW)))
    $error("[mempool_group_mshr] group_mshr_bank_publish needs idx_width(MshrNum)=%0d to equal BankIdW(%0d)+VictimPtrW(%0d).",
           MshrIdxW, BankIdW, VictimPtrW);
  logic [MshrBankNum-1:0][VictimPtrW-1:0]                     bank_rr_q, bank_rr_d;
  logic [MshrBankNum-1:0][VictimPtrW-1:0]                     bank_pub_w;
  logic [MshrBankNum-1:0]                                     bank_pub_v;
  logic [VictimPtrW-1:0]                                      bank_scan_w;
  logic [MshrIdxW-1:0]  drain_mshr_rr_q, drain_mshr_rr_d;
  // (C) drain: rotate the sub_req scan axis (MshrMergeReqs sub-requests), a separate base from
  // (B) so the two axes do not rotate in lockstep. Width is SubIdxW above.
  logic [SubIdxW-1:0]     subreq_rr_q, subreq_rr_d;

  // Performance counters (simulation only).
  `ifndef TARGET_SYNTHESIS
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
  `endif

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

  // Per-lane request decode (stateless: reads no MSHR entry).
  mempool_group_mshr_req_decode #(
    .NumTilesPerGroup(NumTilesPerGroup), .NumRemoteReqPortsPerTile(NumRemoteReqPortsPerTile),
    .BurstLenWidth(BurstLenWidth), .TileIdBits(TileIdBits), .BurstAlignBits(BurstAlignBits),
    .MergeWordOffset(MergeWordOffset), .MshrFullBurstWords(MshrFullBurstWords),
    .EnableMshrSingleReq(EnableMshrSingleReq),
    .EnableMshrNonFullBurstReq(EnableMshrNonFullBurstReq),
    .EnableMshrFullBurstReq(EnableMshrFullBurstReq)
  ) i_req_decode (
    .req_valid_i         (req_in_valid),
    .req_i               (req_in),
    .cfg_bypass_single_i (cfg_bypass_single),
    .cfg_bypass_burst_i  (cfg_bypass_burst),
    .len_o               (req_len),
    .len_raw_o           (req_len_raw),
    .tile_id_o           (req_tile_id),
    .tile_addr_o         (req_tile_addr),
    .tile_addr_key_o     (req_tile_addr_key),
    .addr_key_o          (req_addr_key),
    .is_load_o           (req_is_load),
    .is_store_o          (req_is_store),
    .is_single_o         (req_is_single),
    .is_non_full_burst_o (req_is_non_full_burst),
    .is_full_burst_o     (req_is_full_burst),
    .can_merge_o         (req_can_merge),
    .amo_invalidate_o    (amo_invalidate)
  );

  // Detect whether any response beat on input already targets each MSHR entry.
  // O(1) by tag: the response carries the entry id, so index it and re-validate. The legacy form
  // scanned all MshrNum entries per lane; it sat behind a localparam that nothing could set, so it
  // was const-folded away and is deleted rather than left as a 64-way scan a reader has to
  // discount.
  always_comb begin
    rsn_v  = '0;
    rsn_id = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        // Unconditional: the id must be valid for the consumer's compare even when rsn_v is 0.
        rsn_tag_cand = mshr_id_t'(resp_in[tile_i][port_i].mshr_tag - MshrTagWidth'(1));
        rsn_id[tile_i][port_i] = rsn_tag_cand;
        if (resp_in_valid[tile_i][port_i] &&
            (resp_in[tile_i][port_i].wen == 1'b0) &&
            (resp_in[tile_i][port_i].rdata.amo == '0)) begin
          if (resp_in[tile_i][port_i].mshr_tag != '0) begin : rsn_tag
            if (mshr_q_valid[rsn_tag_cand] &&
                ((mshr_q[rsn_tag_cand].state == MSHR_WAIT_RESP) ||
                 (mshr_q[rsn_tag_cand].state == MSHR_DRAIN_RESP)) &&
                (mshr_q[rsn_tag_cand].sub_reqs[0].tile_id == tile_group_id_t'(tile_i)) &&
                burst_beat_valid(resp_in[tile_i][port_i].rdata.core_id,
                                 resp_in[tile_i][port_i].rdata.meta_id,
                                 mshr_q[rsn_tag_cand].sub_reqs[0].core_id,
                                 mshr_q[rsn_tag_cand].sub_reqs[0].meta_id_base,
                                 mshr_q[rsn_tag_cand].burst_len)) begin
              rsn_v[tile_i][port_i] = 1'b1;
            end
          end
        end
      end
    end
  end

`ifndef TARGET_SYNTHESIS
  // Sim-only per-entry view of the above, for the statistics include, which scans all entries.
  // Reconstructed from the lane form; excluded from synthesis, so it costs no hardware.
  logic [MshrNum-1:0] mshr_resp_seen_now;
  always_comb begin
    mshr_resp_seen_now = '0;
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int pp = 1; pp < NumRemoteRespPortsPerTile; pp++) begin
        if (rsn_v[t][pp]) mshr_resp_seen_now[rsn_id[t][pp]] = 1'b1;
      end
    end
  end
`endif

  // Is any validated response beat targeting entry e this cycle? Arguments, not module reads: a
  // function called from a continuous assign does not sample signals it reads but does not take.
  function automatic logic resp_seen_at(
      input logic     [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1] v,
      input mshr_id_t [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1] id,
      input mshr_id_t e);
    resp_seen_at = 1'b0;
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int pp = 1; pp < NumRemoteRespPortsPerTile; pp++) begin
        if (v[t][pp] && (id[t][pp] == e)) resp_seen_at = 1'b1;
      end
    end
  endfunction

  // address-banking replaces the O(ports^2) same-cycle leader/follower coalescing.
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_bank_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_bank_port
        // Type comes from the CLAMPED req_is_single, not req_len_raw: a store or a
        // misaligned burst is forced to req_len=1 and must bank like a single (see BankSelShift*).
        assign req_bank[tile_i][port_i] =
            mshr_bank_of(req_addr_key[tile_i][port_i], req_in[tile_i][port_i].tgt_group_id,
                         req_is_single[tile_i][port_i],
                         cfg_bank_shift_single, cfg_bank_shift_burst, cfg_bank_burst_bits);
      end
    end
  endgenerate

  // MSHR hit lookup (parallel compare), bank-scoped to this request's MshrWaysPerBank ways. For a
  // fixed way_i, the absolute entry id e_abs = req_bank*MshrWaysPerBank + way_i selects one entry
  // per bank, so mshr_q[e_abs] is a MshrBankNum:1 mux feeding a single comparator (vs one
  // comparator per MshrNum entry).
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
          // A same-address entry that cannot be merged into right now makes the request wait
          // rather than allocate a second entry for the same line. Two valid entries CAN still
          // share an address (a request refused by no_late_join_burst allocates its own), so a
          // same-address pair is not by itself a duplicate-allocation bug.
          assign req_resp_seen[tile_i][port_i][way_i] = resp_seen_at(rsn_v, rsn_id, e_abs);

          // Both in-flight terms make the request WAIT rather than act on a stale entry:
          // merge_inflight -- sub_reqs_num and state are one cycle behind, so req_hit_way's
          // capacity test and its CACHED / RESP_HOLD disjuncts would read pre-merge values;
          // alloc_inflight -- this way is being re-keyed to another line, and mshr_q still shows
          // the old address, so a hit here would merge into an entry about to become someone
          // else's.
          assign req_addr_hit_drain_way[tile_i][port_i][way_i] =
              req_addr_hit_way[tile_i][port_i][way_i] &&
              ((mshr_q[e_abs].state == MSHR_DRAIN_RESP) ||
               (merge_inflight[e_abs] && (mshr_q[e_abs].state != MSHR_WAIT_RESP)) ||
               alloc_inflight[e_abs] ||
               (StallOnResp && req_resp_seen[tile_i][port_i][way_i]));

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
              !req_resp_seen[tile_i][port_i][way_i] &&
              ((mshr_q[e_abs].sub_reqs_num + SubReqCountW'(1)) <= MshrMergeReqs);

          // Same capacity test the merge accept applies, plus the in-flight merge this entry has
          // not yet absorbed. Evaluated here because e_abs indexes on req_bank, which is ready
          // early; at the accept the only available index is the selected way, the latest signal
          // in this cone. Data is register-fed (mshr_q, and merge_inflight from mgb_q_*).
          assign req_hit_cap_way[tile_i][port_i][way_i] =
              ((MergeRankW'(mshr_q[e_abs].sub_reqs_num + SubReqCountW'(merge_inflight[e_abs])) +
                MergeRankW'(1)) <= MergeRankW'(MshrMergeReqs));
        end
        // Full-table meta-overlap (cross-bank): same tile+core, overlapping meta_id, different
        // address.
        if (MetaOvlpByOwner) begin : gen_req_meta_ovlp_owner
          for (genvar mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin : gen_map
            assign req_meta_ovlp_map[tile_i][port_i][mshr_i] =
                mo_owner_oh[mshr_i][tile_i] && mo_ovlp[mshr_i][port_i];
          end
        end else begin : gen_req_meta_ovlp_perlane
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
                // Two-sided modular range test in place of a MetaSpace-wide mask AND +
                // OR-reduce.
                (mshr_q[mshr_i].burst_len != '0) &&
                (req_len[tile_i][port_i] != '0) &&
                ((meta_id_t'(mshr_q[mshr_i].sub_reqs[0].meta_id_base -
                             req_in[tile_i][port_i].wdata.meta_id) < req_len[tile_i][port_i]) ||
                 (meta_id_t'(req_in[tile_i][port_i].wdata.meta_id -
                             mshr_q[mshr_i].sub_reqs[0].meta_id_base) < mshr_q[mshr_i].burst_len));
          end
        end
        assign req_hit_mshr[tile_i][port_i] = |req_hit_way[tile_i][port_i];
        assign req_addr_hit_drain[tile_i][port_i] = |req_addr_hit_drain_way[tile_i][port_i];
        assign req_meta_conflict[tile_i][port_i] = |req_meta_ovlp_map[tile_i][port_i];

        // req_meta_ovlp_map scans mshr_q across ALL banks, so the per-bank hold below cannot
        // cover it: an in-flight allocation in another bank is invisible to the overlap check.
        // Same (tile, core) is the conservative stand-in -- one registered compare per bank.
        for (genvar b = 0; b < MshrBankNum; b++) begin : gen_owner_inflight_bank
          assign req_owner_inflight_bank[tile_i][port_i][b] =
              agb_q_v[b] && (agb_q_tile[b] == tile_group_id_t'(tile_i)) &&
              (agb_q_core[b] == req_in[tile_i][port_i].wdata.core_id) &&
              ((meta_id_t'(agb_q_meta[b] - req_in[tile_i][port_i].wdata.meta_id) <
                req_len[tile_i][port_i]) ||
               (meta_id_t'(req_in[tile_i][port_i].wdata.meta_id - agb_q_meta[b]) <
                agb_q_len[b]));
        end
        assign req_owner_inflight[tile_i][port_i] = |req_owner_inflight_bank[tile_i][port_i];
        // Exactly the req_addr_hit_way key, compared against the in-flight allocation record.
        // agb_q_len keeps a different-length request free to allocate its own entry, as req_hit_way
        // would have let it.
        assign req_fwd_hit[tile_i][port_i] =
            req_can_merge[tile_i][port_i] && agb_q_v[req_bank[tile_i][port_i]] &&
            (agb_q_addr[req_bank[tile_i][port_i]] == req_addr_key[tile_i][port_i]) &&
            (agb_q_grp [req_bank[tile_i][port_i]] == req_in[tile_i][port_i].tgt_group_id) &&
            (agb_q_len [req_bank[tile_i][port_i]] == req_len[tile_i][port_i]);
        assign req_fwd_id[tile_i][port_i] =
            mshr_id_t'(int'(req_bank[tile_i][port_i]) * MshrWaysPerBank +
                       int'(agb_q_way[req_bank[tile_i][port_i]]));
      end
    end
  endgenerate

  // Meta-range overlap, computed ONCE PER ENTRY (see MetaOvlpByOwner).
  generate
    for (genvar e = 0; e < MshrNum; e++) begin : gen_mo_entry
      // Owner one-hot. Only read where mo_ovlp is non-zero, which requires mshr_q_valid[e].
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_mo_owner
        assign mo_owner_oh[e][t] =
            mshr_q_valid[e] && (mshr_q[e].sub_reqs[0].tile_id == tile_group_id_t'(t));
      end
      for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_mo_port
        // NumTilesPerGroup:1 select of the owner tile's request on this port.
        tile_group_id_t mo_ot;
        assign mo_ot = mshr_q[e].sub_reqs[0].tile_id;
        assign mo_ovlp[e][p] =
            req_can_merge[mo_ot][p] &&
            mshr_q_valid[e] &&
            ((mshr_q[e].state == MSHR_WAIT_RESP) ||
             (mshr_q[e].state == MSHR_DRAIN_RESP) ||
             (mshr_q[e].state == MSHR_RESP_HOLD)) &&
            (mshr_q[e].sub_reqs[0].core_id == req_in[mo_ot][p].wdata.core_id) &&
            // Same-address exclusion, bank-local exactly as in the per-lane form: a same-address
            // entry must lie in the request's own bank, so req_addr_hit_way (already bank-scoped)
            // carries it and no extra address comparator appears here.
            !((req_bank[mo_ot][p] == BankIdW'(e / MshrWaysPerBank)) &&
              req_addr_hit_way[mo_ot][p][e % MshrWaysPerBank]) &&
            // Length guards are load-bearing -- see the per-lane form for why.
            (mshr_q[e].burst_len != '0) &&
            (req_len[mo_ot][p] != '0) &&
            ((meta_id_t'(mshr_q[e].sub_reqs[0].meta_id_base -
                         req_in[mo_ot][p].wdata.meta_id) < req_len[mo_ot][p]) ||
             (meta_id_t'(req_in[mo_ot][p].wdata.meta_id -
                         mshr_q[e].sub_reqs[0].meta_id_base) < mshr_q[e].burst_len));
      end
    end
  endgenerate

  /// Store byte-merge lane pack: a flat view of req_in for the merge below. Reads req_in only and
  /// nothing else drives these, so it carries no order dependence on the main pass.
  generate
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_stb_pack_t
      for (genvar pp = 1; pp < NumRemoteReqPortsPerTile; pp++) begin : gen_stb_pack_p
        localparam int unsigned StbL = t * NumReqPortsActiveF3 + (pp - 1);
        assign stb_be[StbL] = req_in[t][pp].be;
        assign stb_wd[StbL] = req_in[t][pp].wdata.data;
      end
    end
  endgenerate

  /// Highest set bit of a lane vector -- the last writer in the old sequential loop.
  function automatic logic [NumReqLanes-1:0] stb_hi_isolate(input logic [NumReqLanes-1:0] v);
    logic [NumReqLanes-1:0] rev, iso;
    for (int i = 0; i < NumReqLanes; i++) rev[i] = v[NumReqLanes-1-i];
    iso = rev & (~rev + 1'b1);
    for (int i = 0; i < NumReqLanes; i++) stb_hi_isolate[i] = iso[NumReqLanes-1-i];
  endfunction

  /// Store byte-merge select, one-hot per (entry, byte).
  /// The sequential form walked 32 lanes per byte, each overwriting the last, so synthesis built a
  /// 32-deep chain into resp_buf.data -- 8192 registers, and the worst request-fed endpoint family
  /// in the placed report. Selecting with a one-hot and OR-ing the masked lanes is the same result
  /// in log depth: 32 levels -> 5. Every operand is an argument, so the function samples nothing
  /// implicitly.
  generate
    for (genvar e = 0; e < MshrNum; e++) begin : gen_stb_e
      for (genvar b = 0; b < StrbW; b++) begin : gen_stb_b
        for (genvar l = 0; l < NumReqLanes; l++) begin : gen_stb_l
          assign stb_byte_req[e][b][l] = stb_hit[e][l] && stb_be[l][b];
        end
        assign stb_byte_win[e][b] = stb_hi_isolate(stb_byte_req[e][b]);
      end
    end
  endgenerate

  always_comb begin
    stb_byte_data = '0;
    for (int e = 0; e < MshrNum; e++)
      for (int b = 0; b < StrbW; b++)
        for (int l = 0; l < NumReqLanes; l++)
          stb_byte_data[e][b] |= {8{stb_byte_win[e][b][l]}} & stb_wd[l][b*8 +: 8];
  end

  // mshr_hit_req[e]: is entry e address-hit by some request this cycle?
  if (CacheReclaimable) begin : gen_mshr_hit_req
    for (genvar e = 0; e < MshrNum; e++) begin : gen_hit_req_e
      localparam int unsigned HrBank = e / MshrWaysPerBank;
      localparam int unsigned HrWay  = e % MshrWaysPerBank;
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_hit_req_t
        for (genvar pp = 1; pp < NumRemoteReqPortsPerTile; pp++) begin : gen_hit_req_p
          assign mshr_hit_req_lane[e][t][pp] =
              (req_bank[t][pp] == BankIdW'(HrBank)) && req_hit_way[t][pp][HrWay];
        end
      end
      assign mshr_hit_req[e] = |mshr_hit_req_lane[e];
    end
  end else begin : gen_mshr_hit_req_tie
    assign mshr_hit_req = '0;
  end

  // Select the first matching way per request to avoid multi-merge; absolute id = req_bank*ways +
  // way.
  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        // Forwarded in-flight allocation first: no resident way can hold this line, or the
        // allocation would not have fired for it.
        req_hit_mshr_sel_valid[tile_i][port_i] = req_fwd_hit[tile_i][port_i];
        req_hit_mshr_sel_id[tile_i][port_i]    = req_fwd_hit[tile_i][port_i]
                                               ? req_fwd_id[tile_i][port_i] : '0;
        // A forwarded merge is the leader's sub_reqs[1], so its capacity term const-folds.
        req_hit_cap_sel[tile_i][port_i]        =
            (MergeRankW'(1) + MergeRankW'(1)) <= MergeRankW'(MshrMergeReqs);
        for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
          if (!req_hit_mshr_sel_valid[tile_i][port_i] &&
              req_hit_way[tile_i][port_i][way_i]) begin
            req_hit_mshr_sel_valid[tile_i][port_i] = 1'b1;
            req_hit_mshr_sel_id[tile_i][port_i] =
                mshr_id_t'(int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i);
            req_hit_cap_sel[tile_i][port_i] = req_hit_cap_way[tile_i][port_i][way_i];
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
          // A forwarding lane merges into the in-flight allocation; req_hit_mshr only sees
          // RESIDENT ways, so without this it would also stay an allocation candidate and could
          // win the arbiter -- allocating a second entry for a line it is already merging into.
          !req_fwd_hit[tile_i][port_i]       &&
          !req_addr_hit_drain[tile_i][port_i] &&
          !req_meta_conflict[tile_i][port_i];
    end
  end

  // Per-bank free-way lookup with INVALID-FIRST priority: prefer a truly free (invalid)
  // way, and reclaim a CACHED way only when the bank has no invalid way.
  // Reduce each entry to the two bits the free-way lookup needs, so the submodule takes ~200 bits
  // instead of MshrNum full entries.
  logic [MshrNum-1:0] way_reclaimable;
  generate
    if (CacheReclaimable) begin : gen_way_reclaimable
      for (genvar e = 0; e < MshrNum; e++) begin : gen_way_reclaimable_e
        // Neither in-flight record may be reclaimed: mshr_q still shows the pre-write entry, so a
        // merge landing this cycle would be blanked by the allocation that picked it as victim.
        assign way_reclaimable[e] = EnableRespCache && mshr_q_valid[e] &&
                                    !alloc_inflight[e] && !merge_inflight[e] &&
                                    (mshr_q[e].state == MSHR_CACHED) &&
                                    (mshr_q[e].sub_reqs_num == '0) && !mshr_hit_req[e];
      end
    end else begin : gen_no_way_reclaimable
      // free_way does not read reclaimable_i at CacheReclaimable = 0; do not build the producer.
      assign way_reclaimable = '0;
    end
  endgenerate

  mempool_group_mshr_free_way #(
    .MshrNum(MshrNum), .WaysPerBank(MshrWaysPerBank), .BankNum(MshrBankNum),
    .IdW($bits(mshr_id_t)), .VictimPtrW(VictimPtrW),
    .CacheReclaimable(CacheReclaimable), .CacheVictimRR(CacheVictimRR)
  ) i_free_way (
    .valid_i       (free_way_valid),
    .reclaimable_i (way_reclaimable),
    .victim_rr_i   (victim_rr_q),
    .has_free_o    (bank_has_free),
    .free_id_o     (bank_free_id)
  );

  // Per-bank single allocation per cycle: at most one candidate per bank is granted a new entry
  // (taking that bank's free way).
  logic [NumAllocSlots-1:0]                  alloc_cand_flat;
  logic [NumAllocSlots-1:0][BankIdW-1:0]     alloc_bank_flat;
  logic [NumAllocSlots-1:0]                  alloc_rr_mask;   // 1 = slot is at/above the RR base
  logic [MshrBankNum-1:0][NumAllocSlots-1:0] bank_win_oh;     // one-hot winner per bank

  // Loop temporaries for the allocation arbiter, declared at module scope rather than as
  // procedural `automatic`s inside the always_comb below.
  logic [AllocRrW-1:0]                       alloc_slot_idx;      // flatten block
  // Per-bank grant, before the OR that returns it to its requester.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrBankNum-1:0] alloc_grant_bank;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrBankNum-1:0] merge_grant_bank;

  // Per-bank merge arbiter (OneMergePerBank). Same shape as the allocation arbiter above and
  // sharing its rotation base, so a high-index tile is not perpetually beaten to a contended bank.
  // Separate signals rather than reuse: a module-scope variable may have only one combinational
  // driver.
  logic [NumAllocSlots-1:0]                  merge_arb_cand_flat;
  logic [NumAllocSlots-1:0][BankIdW-1:0]     merge_arb_bank_flat;
  logic [MshrBankNum-1:0][NumAllocSlots-1:0] bank_merge_win_oh;   // one-hot merge winner per bank
  logic [AllocRrW-1:0]                       merge_arb_slot_idx;      // flatten block
`ifndef TARGET_SYNTHESIS
  logic [NumAllocSlots-1:0]                  merge_arb_grant_flat_dbg; // granted lanes, for coverage
`endif

  always_comb begin
    alloc_cand_flat = '0;
    alloc_bank_flat = '0;
    // Slot = tile*NumReqPortsActive + (port-1) is a bijection over the active req ports
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
  end

  // A bank with no free way grants nobody; its candidates fall through to stall/bypass unchanged.
  mempool_group_mshr_bank_arb #(
    .NumSlots(NumAllocSlots), .NumBanks(MshrBankNum), .BankIdW(BankIdW)
  ) i_alloc_arb (
    .cand_i      (alloc_cand_flat),
    .bank_i      (alloc_bank_flat),
    .rr_mask_i   (alloc_rr_mask),
    .bank_gate_i (bank_has_free),
    .win_oh_o    (bank_win_oh)
  );

  // Return the per-bank one-hot grant to its (tile,port) requester. The arbiter builds its request
  // vector as `cand && (bank == b)` (mempool_group_mshr_bank_arb), so a slot can only ever win in
  // its OWN bank -- the OR below is identical to indexing by req_bank, and keeps req_bank (the
  // latest signal in this cone) off the grant path. bank_free_id reads registers only, so the one
  // remaining bank select has early data and an early index.
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_grant_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_grant_port
        for (genvar bank_i = 0; bank_i < MshrBankNum; bank_i++) begin : gen_grant_bank
          assign alloc_grant_bank[tile_i][port_i][bank_i] =
              bank_win_oh[bank_i][tile_i * NumReqPortsActive + (port_i - 1)];
          assign merge_grant_bank[tile_i][port_i][bank_i] =
              bank_merge_win_oh[bank_i][tile_i * NumReqPortsActive + (port_i - 1)];
        end
        assign req_alloc_found[tile_i][port_i] = |alloc_grant_bank[tile_i][port_i];
        assign req_merge_ready[tile_i][port_i] = |merge_grant_bank[tile_i][port_i];
        assign req_alloc_found_mshr_id[tile_i][port_i] =
            req_alloc_found[tile_i][port_i] ? bank_free_id[req_bank[tile_i][port_i]] : '0;
      end
    end
  endgenerate

  // Select the merge target per request.
  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        // No late join once a beat is in flight. req_addr_hit_drain means "this address's entry is
        // draining, OR has a response arriving this cycle / in flight" (StallOnResp). It already
        // gates the ALLOCATE path and the non-merge branch, but not the merge -- so a subscriber
        // could join in the very cycle a beat lands and the entry flipped to MSHR_DRAIN_RESP.
        // Blocking it makes mshr_d.sub_reqs == mshr_q.sub_reqs for any entry with a beat in flight,
        // BY CONSTRUCTION, which is what lets the drain read sub_reqs from mshr_q. Cost: such a
        // merge becomes stall-and-retry, one cycle later.
        req_merge_valid[tile_i][port_i] =
            req_can_merge[tile_i][port_i] && req_hit_mshr_sel_valid[tile_i][port_i] &&
            !req_addr_hit_drain[tile_i][port_i];
        req_merge_mshr_id[tile_i][port_i] = req_hit_mshr_sel_id[tile_i][port_i];
      end
    end
  end

  // Per-bank merge arbiter (OneMergePerBank): same shape as the allocation arbiter and sharing its
  // rotation base, so a high-index tile is not perpetually beaten to a contended bank.
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
  end

  // Ungated: an entry that is already resident is always a legal merge target. Shares the
  // allocation rotation base, so a high-index tile is not perpetually beaten to a contended bank.
  mempool_group_mshr_bank_arb #(
    .NumSlots(NumAllocSlots), .NumBanks(MshrBankNum), .BankIdW(BankIdW)
  ) i_merge_arb (
    .cand_i      (merge_arb_cand_flat),
    .bank_i      (merge_arb_bank_flat),
    .rr_mask_i   (alloc_rr_mask),
    .bank_gate_i ({MshrBankNum{1'b1}}),
    .win_oh_o    (bank_merge_win_oh)
  );

`ifndef TARGET_SYNTHESIS
  always_comb begin
    merge_arb_grant_flat_dbg = '0;
    for (int b = 0; b < MshrBankNum; b++) begin
      merge_arb_grant_flat_dbg = merge_arb_grant_flat_dbg | bank_merge_win_oh[b];
    end
  end
`endif

  // Sequential state update
  // shared hold prescaler: one free-running counter per MSHR instance. Entry e takes its tick
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
    for (int unsigned e = 0; e < MshrNum; e++) begin
      hold_tick[e] = (HoldPrescaleW == 0) ? 1'b1 : hold_tick_phase[HoldPrescaleWSafe'(e)];
    end
  end

  `FF(mshr_q_valid, mshr_d_valid, '0)

  // Entry register, split by WRITE FREQUENCY so the wide fields can be clock gated.
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
  // deliberately so: a clock-gate enable may be over-asserted (it costs a little power) but never
  // under-asserted (it would lose a write).
  always_comb begin
    for (int e = 0; e < MshrNum; e++) begin
      // Control changes only while the entry is live, or on the cycle it is allocated --
      // alloc_inflight, not the arbiter grant, because the cut moved the write a cycle later.
      mshr_ctl_en[e] = mshr_q_valid[e] | alloc_inflight[e];
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

  // 16 x VictimPtrW flops that only the CacheReclaimable pass-2 scan reads; tie them off otherwise.
  if (CacheReclaimable && CacheVictimRR) begin : gen_victim_rr
    `FF(victim_rr_q, victim_rr_d, '0)
  end else begin : gen_victim_rr_tie
    assign victim_rr_q = '0;
  end

  // Round-robin fairness bases: free-running +1 mod-N every cycle, reset '0.
  assign alloc_rr_d      = (alloc_rr_q      == AllocRrW'(NumAllocSlots - 1)) ?
                           '0 : alloc_rr_q      + AllocRrW'(1);
  assign drain_mshr_rr_d = (drain_mshr_rr_q == MshrIdxW'(MshrNum - 1)) ?
                           '0 : drain_mshr_rr_q + MshrIdxW'(1);
  assign subreq_rr_d     = (subreq_rr_q     == SubIdxW'(MshrMergeReqs - 1)) ?
                           '0 : subreq_rr_q     + SubIdxW'(1);
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

  // Entry-occupancy view for utilization analysis (simulation-only, zero hardware, always
  // available -- no debug define needed).
  `ifndef TARGET_SYNTHESIS
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

  // Hold-the-fetch RELEASE-REASON view (simulation-only).
  logic [MshrNum-1:0] mshr_issue_timeout_dbg;
  logic [MshrNum-1:0] mshr_issue_subs_dbg;
  // RESPONSE-side timeout deaths.
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
        // Genuine held->released edge: the entry was VALID and NOT issued last cycle and is issued
        // now.
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

  // Coverage counter for the case the per-entry capture exists to handle: TWO response lanes
  // capturing into the SAME entry in one cycle. Zero here would make the equivalence arm vacuous.
  logic [31:0] stb_ovl_cnt_dbg;
  logic [31:0] cap_two_grant_cnt_dbg;   // cycles-with-entries where a second lane was granted
  logic [31:0] cap_one_grant_cnt_dbg;   // ... where only the first was, for a ratio
  // OneMergePerBank cost, measured rather than argued: merges the per-bank arbiter refused this
  // cycle (the lane is a valid merge hit but lost its bank), against merges it granted.
  logic [31:0] merge_arb_stall_cnt_dbg;
  logic [31:0] merge_arb_grant_cnt_dbg;
  // Comparable ACROSS the knob: lanes that wanted to capture a response this cycle
  // (resp_is_mshr) against lanes that actually did (resp_capture_fire). The difference is the
  // deferral the capture arbiter imposed, whichever form is compiled in.
  logic [31:0] cap_want_cnt_dbg;
  logic [31:0] cap_fire_cnt_dbg;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cap_two_grant_cnt_dbg <= '0;
      cap_one_grant_cnt_dbg <= '0;
      stb_ovl_cnt_dbg       <= '0;
      merge_arb_stall_cnt_dbg <= '0;
      merge_arb_grant_cnt_dbg <= '0;
      cap_want_cnt_dbg        <= '0;
      cap_fire_cnt_dbg        <= '0;
    end else begin
      cap_two_grant_cnt_dbg <= cap_two_grant_cnt_dbg + 32'($countones(cap_g2));
      cap_one_grant_cnt_dbg <= cap_one_grant_cnt_dbg + 32'($countones(cap_g1 & ~cap_g2));
      stb_ovl_cnt_dbg       <= stb_ovl_cnt_dbg       + 32'($countones(stb_ovl));
      merge_arb_stall_cnt_dbg <= merge_arb_stall_cnt_dbg +
          32'($countones(merge_arb_cand_flat & ~merge_arb_grant_flat_dbg));
      merge_arb_grant_cnt_dbg <= merge_arb_grant_cnt_dbg +
          32'($countones(merge_arb_cand_flat &  merge_arb_grant_flat_dbg));
      cap_want_cnt_dbg        <= cap_want_cnt_dbg + 32'($countones(resp_is_mshr));
      cap_fire_cnt_dbg        <= cap_fire_cnt_dbg + 32'($countones(resp_capture_fire));
    end
  end
  final begin
    $display("[F3cCOV] group=%0d two_lane_grants=%0d one_lane_grants=%0d store_byte_overlaps=%0d",
             group_id_i, cap_two_grant_cnt_dbg, cap_one_grant_cnt_dbg, stb_ovl_cnt_dbg);
    $display("[MRGARB] group=%0d merge_grants=%0d merge_arb_stalls=%0d",
             group_id_i, merge_arb_grant_cnt_dbg, merge_arb_stall_cnt_dbg);
    $display("[CAPARB] group=%0d cap_wanted=%0d cap_fired=%0d",
             group_id_i, cap_want_cnt_dbg, cap_fire_cnt_dbg);
  end

  // RESP_HOLD stall probe (simulation-only, group_mshr_resp_hold_probe = age threshold).
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
  `endif

  // Bypass-path delivery probe (simulation-only, group_mshr_bypass_probe).
`ifndef TARGET_SYNTHESIS
  if (BypassProbe) begin : gen_bypass_probe
    localparam int unsigned BpCoreN = 2**$bits(tile_core_id_t);
    localparam int unsigned BpMetaN = 2**$bits(meta_id_t);
    integer bp_out_cnt [NumTilesPerGroup][BpCoreN][BpMetaN];
    longint bp_cyc, bp_fwd, bp_rsp, bp_orphan;

    // Was a scan of bypass_track_q, which the deleted table's else-arm tied to '0 -- so this
    // folded into its one consumer, so the probe's intent stays legible.

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
                resp_from_bypass[t][p]) begin : bp_resp   // was && !bypass_match: constant 1
              automatic int bc = int'(resp_out[t][p].rdata.core_id);
              automatic int bm = int'(resp_out[t][p].rdata.meta_id);
              bp_rsp = bp_rsp + 1;
              if (bp_out_cnt[t][bc][bm] > 0) begin
                bp_out_cnt[t][bc][bm] -= 1;
              end else begin
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

  // Bank-full alloc bypass view (simulation-only).
  `ifndef TARGET_SYNTHESIS
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

  // Bank-concentration measurement (settles: is bank-full overflow caused by the hash
  // concentrating a temporal batch into few banks, or by genuine aggregate fullness?).
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
  // Address-capture probe (BankHashDump): dump the merge key + target group + current-hash bank of
  // bank-full-bypass events in ONE group (group 0), up to a cap, so the actual colliding.
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
  `endif

  // Debug-only view of cached/uncached valid entries.
  `ifndef TARGET_SYNTHESIS
  `ifndef VERILATOR
  // A verbose per-entry debug tracer lived here behind +define+GROUP_MSHR_DEBUG_TRACE.
  // Recover it from git history if needed.
  `endif
  `endif

  // Main combinational control: request merge/alloc, response capture, and drain
`ifndef TARGET_SYNTHESIS
  // Duplicate-response-beat detection.
  logic        dup_beat_detected;
  int unsigned dup_beat_mshr, dup_beat_beat, dup_beat_meta;
`endif

  // Loop temporaries for the three drain / response-select arbiters inside the always_comb below,
  // at module scope rather than as procedural `automatic`s.
  logic [MshrIdxW-1:0]      drain_sel_base;
  logic [SubIdxW-1:0]       drain_sel_sub_base;                    // A: rotation bases
  logic [MshrNum-1:0]       drain_ent_cand;                        // A: entries offering a beat
  // Bank-narrowed selector. With BankPublish on, at most one entry per bank is selectable,
  // so the arbitration runs over MshrBankNum candidates instead of MshrNum.
  logic [MshrBankNum-1:0][MshrIdxW-1:0] bank_pub_e;    // published entry id per bank (port-indep.)
  logic [MshrBankNum-1:0]   bank_cand, bank_cand_rot, bank_cand_eff, bank_pfx, bank_first;
  logic [BankIdW-1:0]       bank_base, bank_idx, bank_win_d, bank_win;
  logic [VictimPtrW-1:0]    base_way;
  logic                     bank_demote;
  logic [MshrMergeReqs-1:0] drain_sub_cand;                        // A: sub-reqs in the winner
  // PPA hoist: the (tile,port)-independent half of the drain eligibility test, computed once per
  // (entry, sub-request) instead of once per (entry, sub-request, tile, port).
  logic [MshrNum-1:0]                                         drain_scan_valid;
  // Opt3 stage-1: per-bank round-robin publish. bank_rr_q advances one way per cycle per bank.
  logic [MshrNum-1:0]                                         drain_published;
  logic [MshrNum-1:0]                                         drain_ent_any;
  logic [MshrNum-1:0]                                         drain_ent_ok;
  logic [MshrNum-1:0][MshrMergeReqs-1:0]                      drain_sub_ready;
  tile_group_id_t [MshrNum-1:0][MshrMergeReqs-1:0]            drain_sub_tile;
  logic [MshrNum-1:0][MshrMergeReqs-1:0][RespPortIdW-1:0]     drain_sub_port;
  // Head-beat DRIVE operands, hoisted per entry (applied to the head beat).
  // The drive read mshr_d[resp_sel_mshr_id[t][p]] directly -- a full-entry MshrNum:1 STRUCT mux per
  // lane, 32 of them, plus a second MshrNum:1 for the nested resp_buf_rd_ptr and a burst_len
  // comparator per lane. Hoisting turns each into a MshrNum:1 over a NARROW field, computed once.
  data_t [MshrNum-1:0]                                        drv_data;
  tile_core_id_t [MshrNum-1:0][MshrMergeReqs-1:0]             drv_sub_core;
  meta_id_t [MshrNum-1:0][MshrMergeReqs-1:0]                  drv_sub_meta;
  logic [MshrNum-1:0]                                         drv_burst_one;
  // Beat offset for the head and second slots, register-sourced like the operands beside them.
  logic [MshrNum-1:0][BurstLenWidth-1:0]                      drv_beat_off;
  data_t [MshrNum-1:0]                                        drv2_data;

  // ------------------------------------------------------------------------------------
  // drain scan and drive operands -- a pure function of mshr_q, so it lives OUTSIDE the
  // entry-update always_comb. Every signal written here has one driver and none is read back by
  // the update block before this settles, so the split is behaviour-preserving; it also makes
  // the depth visible, because this block reads REGISTERS only.
  // ------------------------------------------------------------------------------------
  always_comb begin
    // Hoist the (tile,port)-INDEPENDENT half of the drain eligibility test: the scan below runs
    // inside `for (tile) for (port)`, 32 instances at the 8x8 backend.
    for (int e = 0; e < MshrNum; e++) begin
      // NOT an `automatic ... = ...` local: an initialiser at declaration inside a procedural
      // block is ignored by synthesis (Spyglass SYNTH_89), which this module was cleaned of
      // earlier. drain_ent_ok is a module-scope packed vector instead.
      drain_scan_valid[e] = mshr_q_valid[e];
      // mshr_q, not mshr_d: the scan is already q-sourced (DrainFromQ), and for a scanned entry
      // the two agree -- capture writes at wr_ptr, the drive reads rd_ptr, and the scan requires
      // resp_buf_cnt != 0, so they address different slots.
      drv_data[e]      = mshr_q[e].resp_buf[mshr_q[e].resp_buf_rd_ptr].data;
      // Same q-sourcing. burst_len == 1 forces beat 0: a single-word entry has no other legal
      // beat, so replayed cached data never depends on a stale beat_off in resp_buf.
      drv_beat_off[e]  = (mshr_q[e].burst_len == BurstLenWidth'(1))
                       ? '0 : mshr_q[e].resp_buf[mshr_q[e].resp_buf_rd_ptr].beat_off;
      drv_burst_one[e] = (mshr_q[e].burst_len == BurstLenWidth'(1));
      drain_ent_ok[e] = drain_scan_valid[e] && (mshr_q[e].resp_buf_cnt != '0) &&
                        (mshr_q[e].state == MSHR_DRAIN_RESP);
      // BOTH entry-level terms must be assigned BEFORE the sub-request loop that reads them --
      // these are blocking assignments, so an assignment placed after the loop would feed it the
      // previous evaluation's value.
      for (int s = 0; s < MshrMergeReqs; s++) begin
        drain_sub_ready[e][s] = drain_ent_ok[e] && mshr_q[e].sub_reqs[s].valid &&
                                mshr_q[e].beat_pending[s];
        drain_sub_tile[e][s]  = mshr_q[e].sub_reqs[s].tile_id;
        // mshr_q for the same reason: a merge cannot land in an entry the mshr_q-based scan
        // selected, because req_hit_way requires mshr_q.state == MSHR_WAIT_RESP while the scan
        // requires MSHR_DRAIN_RESP. Disjoint, so mshr_d.sub_reqs == mshr_q.sub_reqs here.
        drv_sub_core[e][s]    = mshr_q[e].sub_reqs[s].core_id;
        drv_sub_meta[e][s]    = mshr_q[e].sub_reqs[s].meta_id_base;
        // Effective destination port: the ParityDrain pin for multi-beat entries, otherwise the
        // requester's own mapped port. Independent of s in the PD2 arm, but kept per-s so the
        // consumer is a single uniform compare.
        drain_sub_port[e][s]  = (PD2 && (mshr_q[e].burst_len != BurstLenWidth'(1)))
                              ? (RespPortIdW'(1) + RespPortIdW'(drv_beat_off[e][0]))
                              : map_resp_port_id(mshr_q[e].sub_reqs[s].port_id);
        // Second-slot (ParityDrain) eligibility, hoisted for the drain2 scan further down.
      end
    end
  end
  // ParityDrain second-slot equivalents. drain2_sub_port is indexed by ENTRY only: both beats of an
  // entry share one parity port, so it does not vary per sub-request.
  logic [MshrNum-1:0]                                         drain2_ent_ok;
  logic [MshrNum-1:0][MshrMergeReqs-1:0]                      drain2_sub_ready;
  tile_group_id_t [MshrNum-1:0][MshrMergeReqs-1:0]            drain2_sub_tile;
  logic [MshrNum-1:0][RespPortIdW-1:0]                        drain2_sub_port;

  /// Second-slot (ParityDrain) drain scan: the head-beat test one buffer slot further on.
  /// Register-sourced, so the second drive never waits on this cycle's capture. PD2 folds into
  /// drain2_scan_valid, so at PD2 = 0 every term below is constant zero and needs no default.
  generate
    for (genvar e = 0; e < MshrNum; e++) begin : gen_drain2_scan
      assign drain2_scan_valid[e] = PD2 && mshr_q_valid[e];
      assign drain2_scan_ent[e]   = mshr_q[e];
      assign drain2_ent_ok[e]     = drain2_scan_valid[e]                                     &&
                                    (drain2_scan_ent[e].state        == MSHR_DRAIN_RESP)     &&
                                    (drain2_scan_ent[e].burst_len    != BurstLenWidth'(1))   &&
                                    (drain2_scan_ent[e].resp_buf_cnt >= RespBufCountW'(2))   &&
                                    drain2_scan_ent[e].beat2_armed;
      // Slot rd_ptr+1, wrapping; the head slot is rd_ptr.
      assign drain2_rd_ptr[e]     = (RespBufWords > 1)
                                  ? ((drain2_scan_ent[e].resp_buf_rd_ptr ==
                                      RespBufPtrW'(RespBufWords - 1))
                                       ? '0
                                       : RespBufPtrW'(drain2_scan_ent[e].resp_buf_rd_ptr + 1'b1))
                                  : '0;
      assign drain2_beat_off[e]   = drain2_scan_ent[e].resp_buf[drain2_rd_ptr[e]].beat_off;
      assign drv2_data[e]         = drain2_scan_ent[e].resp_buf[drain2_rd_ptr[e]].data;
      // Both beats of an entry share one parity port, so this is per-entry, not per-sub-request.
      assign drain2_sub_port[e]   = RespPortIdW'(1) + RespPortIdW'(drain2_beat_off[e][0]);

      for (genvar s = 0; s < MshrMergeReqs; s++) begin : gen_drain2_sub
        assign drain2_sub_ready[e][s] = drain2_ent_ok[e]                     &&
                                        drain2_scan_ent[e].sub_reqs[s].valid &&
                                        drain2_scan_ent[e].beat_pending2[s];
        assign drain2_sub_tile[e][s]  = drain2_scan_ent[e].sub_reqs[s].tile_id;
      end
    end
  endgenerate

  logic [MshrIdxW-1:0]      drain_win_e;
  logic [SubIdxW-1:0]       drain_win_s;
  logic                     drain_have_e,    drain_have_s;
  logic [SubIdxW-1:0]       drain_scan_s;                          // A: rotated scan index
  logic [MshrNum-1:0]       drain_cand_rot;                        // A: candidates rotated to base
  logic [MshrNum-1:0]       drain_pfx, drain_first;                // A: prefix-OR, isolated LSB
  logic [MshrIdxW-1:0]      drain_idx;                             // A: index within the rotation
  logic [MshrNum-1:0]       drain2_cand;                           // A: 2nd-slot entry candidates
  logic [MshrNum-1:0]       drain2_first;                          // one-hot winner, ABSOLUTE index
  // Mask + LSB-isolate, the allocator's form.
  logic [MshrNum-1:0]       drain2_ent_any;                        // entry offers any 2nd-slot beat
  logic [MshrBankNum-1:0]                  drain2_pub_v;           // bank published an entry
  logic [MshrBankNum-1:0][VictimPtrW-1:0]  drain2_pub_w;           // ... which way
  logic [VictimPtrW-1:0]    drain2_scan_w;                         // way scan temporary
  // Per-bank merge apply.
  logic [MshrBankNum-1:0]                    mgb_v;
  logic [MshrBankNum-1:0][VictimPtrW-1:0]    mgb_way;
  tile_group_id_t [MshrBankNum-1:0]          mgb_tile;
  logic [MshrBankNum-1:0][RespPortIdW-1:0]   mgb_port;
  tile_core_id_t [MshrBankNum-1:0]           mgb_core;
  meta_id_t [MshrBankNum-1:0]                mgb_meta;
  // Per-bank allocation apply. The guarantee is stated at the
  // allocation site -- "At most one alloc fires per bank per cycle (bank_alloc_taken), so this
  // per-bank write never conflicts" -- so this needs no knob: it is unconditionally true.
  logic [MshrBankNum-1:0]                    agb_v;
  logic [MshrBankNum-1:0][VictimPtrW-1:0]    agb_way;

  /// Allocation and merge FIRE terms, from the per-bank grant records and mshr_q only.
  /// An entry's bank and way are compile-time constants here, so the arbiter's scatter becomes a
  /// per-entry compare and needs no variable index. The two merge cases set the same value and are
  /// mutually exclusive on state, so the original if / else-if is an OR.
  generate
    for (genvar e = 0; e < MshrNum; e++) begin : gen_st_fire
      localparam int unsigned StBank = e / MshrWaysPerBank;
      localparam int unsigned StWay  = e % MshrWaysPerBank;

      assign alloc_inflight[e] = agb_q_v[StBank] && (agb_q_way[StBank] == VictimPtrW'(StWay));
      assign merge_inflight[e] = mgb_q_v[StBank] && (mgb_q_way[StBank] == VictimPtrW'(StWay));
      // Combinational twin: a retire in THIS cycle must also stand off a merge that is only being
      // decided now, or the merge applies next cycle into an entry that has already been dropped.
      assign merge_decided[e]  = mgb_v  [StBank] && (mgb_way  [StBank] == VictimPtrW'(StWay));
      assign free_way_valid[e] = mshr_q_valid[e] | alloc_inflight[e];

      assign st_alloc_fire[e]  = alloc_inflight[e];
      assign st_merge_drain[e] = merge_inflight[e] &&
                                 ((EnableRespCache &&
                                   (mshr_q[e].state == MSHR_CACHED)) ||
                                  (RespWaitSubsSingle &&
                                   (mshr_q[e].state == MSHR_RESP_HOLD) &&
                                   ((MergeRankW'(mshr_q[e].sub_reqs_num) + MergeRankW'(1)) >=
                                    SubReqCountW'(cfg_hold_subs_single))));
    end
  endgenerate
  tcdm_addr_t [MshrBankNum-1:0]              agb_addr;
  group_id_t [MshrBankNum-1:0]               agb_grp;
  logic [MshrBankNum-1:0][BurstLenWidth-1:0] agb_len;
  tile_group_id_t [MshrBankNum-1:0]          agb_tile;
  logic [MshrBankNum-1:0][RespPortIdW-1:0]   agb_port;
  tile_core_id_t [MshrBankNum-1:0]           agb_core;
  meta_id_t [MshrBankNum-1:0]                agb_meta;
  logic [MergeRankW-1:0]                     mgb_slot;   // recomputed from mshr_q

  /// PER-BANK RECORD SCATTER, one-hot.
  /// Both arbiters emit an LSB-isolated win_oh per bank and their candidate already carries the
  /// bank match, so exactly one lane can ever write a bank's record: the 32-deep mux the
  /// procedural `agb_x[req_bank[t][p]] = ...` form inferred came from the VARIABLE INDEX, not from
  /// contention. Selecting with the arbiter's own one-hot and OR-ing the masked lanes turns 32
  /// levels into 5, and takes the whole record off the always_comb.
  /// win_oh implies req_alloc_cand (which carries req_can_merge) for allocation and
  /// req_merge_valid for merge, so accept = valid && ready reproduces each guard exactly.
  logic [NumAllocSlots-1:0]                     arb_accept;
  tcdm_addr_t [NumAllocSlots-1:0]               arb_addr;
  group_id_t [NumAllocSlots-1:0]                arb_grp;
  logic [NumAllocSlots-1:0][BurstLenWidth-1:0]  arb_len;
  tile_group_id_t [NumAllocSlots-1:0]           arb_tile;
  logic [NumAllocSlots-1:0][RespPortIdW-1:0]    arb_port;
  tile_core_id_t [NumAllocSlots-1:0]            arb_core;
  meta_id_t [NumAllocSlots-1:0]                 arb_meta;
  logic [NumAllocSlots-1:0][VictimPtrW-1:0]     arb_awy, arb_mwy;
  logic [MshrBankNum-1:0][NumAllocSlots-1:0]    agb_sel, mgb_sel;

  generate
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_arb_lane_t
      for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_arb_lane_p
        localparam int unsigned Sl = t * NumReqPortsActive + (p - 1);
        assign arb_accept[Sl] = req_in_valid[t][p] && req_in_ready[t][p];
        assign arb_addr  [Sl] = req_addr_key[t][p];
        assign arb_grp   [Sl] = req_in[t][p].tgt_group_id;
        assign arb_len   [Sl] = req_len[t][p];
        assign arb_tile  [Sl] = tile_group_id_t'(t);
        assign arb_port  [Sl] = RespPortIdW'(p);
        assign arb_core  [Sl] = req_in[t][p].wdata.core_id;
        assign arb_meta  [Sl] = req_in[t][p].wdata.meta_id;
        assign arb_awy   [Sl] = req_alloc_found_mshr_id[t][p][VictimPtrW-1:0];
        assign arb_mwy   [Sl] = req_merge_mshr_id[t][p][VictimPtrW-1:0];
      end
    end

    for (genvar b = 0; b < MshrBankNum; b++) begin : gen_arb_record
      assign agb_sel[b] = bank_win_oh[b]       & arb_accept;
      assign mgb_sel[b] = bank_merge_win_oh[b] & arb_accept;
      assign agb_v[b]   = |agb_sel[b];
      assign mgb_v[b]   = |mgb_sel[b];

      always_comb begin
        agb_way [b] = '0; agb_addr[b] = '0; agb_grp [b] = '0; agb_len [b] = '0;
        agb_tile[b] = '0; agb_port[b] = '0; agb_core[b] = '0; agb_meta[b] = '0;
        mgb_way [b] = '0; mgb_tile[b] = '0; mgb_port[b] = '0;
        mgb_core[b] = '0; mgb_meta[b] = '0;
        for (int s = 0; s < NumAllocSlots; s++) begin
          agb_way [b] |= {VictimPtrW      {agb_sel[b][s]}} & arb_awy [s];
          agb_addr[b] |= {$bits(tcdm_addr_t){agb_sel[b][s]}} & arb_addr[s];
          agb_grp [b] |= {$bits(group_id_t) {agb_sel[b][s]}} & arb_grp [s];
          agb_len [b] |= {BurstLenWidth   {agb_sel[b][s]}} & arb_len [s];
          agb_tile[b] |= {$bits(tile_group_id_t){agb_sel[b][s]}} & arb_tile[s];
          agb_port[b] |= {RespPortIdW     {agb_sel[b][s]}} & arb_port[s];
          agb_core[b] |= {$bits(tile_core_id_t){agb_sel[b][s]}} & arb_core[s];
          agb_meta[b] |= {$bits(meta_id_t) {agb_sel[b][s]}} & arb_meta[s];
          mgb_way [b] |= {VictimPtrW      {mgb_sel[b][s]}} & arb_mwy [s];
          mgb_tile[b] |= {$bits(tile_group_id_t){mgb_sel[b][s]}} & arb_tile[s];
          mgb_port[b] |= {RespPortIdW     {mgb_sel[b][s]}} & arb_port[s];
          mgb_core[b] |= {$bits(tile_core_id_t){mgb_sel[b][s]}} & arb_core[s];
          mgb_meta[b] |= {$bits(meta_id_t) {mgb_sel[b][s]}} & arb_meta[s];
        end
      end
    end
  endgenerate

  /// Stage register. The valid bits are unconditional; each bank's payload is enabled by its own
  /// valid, so an idle bank's flops do not toggle.
  `FF(agb_q_v, agb_v, '0)
  `FF(mgb_q_v, mgb_v, '0)
  generate
    for (genvar b = 0; b < MshrBankNum; b++) begin : gen_arb_stage_reg
      `FFL(agb_q_way [b], agb_way [b], agb_v[b], '0)
      `FFL(agb_q_addr[b], agb_addr[b], agb_v[b], '0)
      `FFL(agb_q_grp [b], agb_grp [b], agb_v[b], '0)
      `FFL(agb_q_len [b], agb_len [b], agb_v[b], '0)
      `FFL(agb_q_tile[b], agb_tile[b], agb_v[b], '0)
      `FFL(agb_q_port[b], agb_port[b], agb_v[b], '0)
      `FFL(agb_q_core[b], agb_core[b], agb_v[b], '0)
      `FFL(agb_q_meta[b], agb_meta[b], agb_v[b], '0)
      `FFL(mgb_q_way [b], mgb_way [b], mgb_v[b], '0)
      `FFL(mgb_q_tile[b], mgb_tile[b], mgb_v[b], '0)
      `FFL(mgb_q_port[b], mgb_port[b], mgb_v[b], '0)
      `FFL(mgb_q_core[b], mgb_core[b], mgb_v[b], '0)
      `FFL(mgb_q_meta[b], mgb_meta[b], mgb_v[b], '0)
    end
  endgenerate

  logic [MshrBankNum-1:0]   drain2_bank_cand;                      // per-lane bank candidates
  logic [MshrBankNum-1:0]   drain2_bank_rr_mask;
  logic [MshrBankNum-1:0]   drain2_bhi, drain2_blo, drain2_bfirst;
  logic [BankIdW-1:0]       drain2_bank_base;
  logic                     drain2_any;                            // a candidate exists, either form
  logic [MshrNum-1:0]       drain2_rr_mask;                        // 1 = entry is at/above the base
  logic [MshrNum-1:0]       drain2_hi, drain2_lo;
  logic [MshrIdxW-1:0]      drain2_idx;                            // A: index within the rotation
  logic [MshrIdxW-1:0]      drain2_base, drain2_mshr_i;            // B
  logic [SubIdxW-1:0]       drain2_sub_base, drain2_s;             // B

  always_comb begin
    // Defaults
    mgb_slot = '0;
    mshr_d      = mshr_q;
    // Clock-gate write flags. Set on the same line as the write they describe (see the entry
    // register block), never from a restatement of the write's condition.
    mshr_wr_all = '0;
    mshr_id_we  = '0;
    mshr_rb_we  = '0;
    // One-cycle pulses; set only at the two response-side death sites below.
    // Guarded because the DECLARATIONS live in an `ifndef TARGET_SYNTHESIS region: unguarded, these
    // reference undefined symbols under synthesis and the module does not analyze at all.
`ifndef TARGET_SYNTHESIS
    mshr_resp_hold_timeout_dbg = '0;
    mshr_cache_timeout_dbg     = '0;
`endif
`ifndef TARGET_SYNTHESIS
    dup_beat_detected = 1'b0;
    dup_beat_mshr = 0; dup_beat_beat = 0; dup_beat_meta = 0;
`endif
    mshr_d_valid   = mshr_q_valid;
    mshr_alloc_set = '0;
    victim_rr_d = victim_rr_q;

    // Hold-the-fetch: count down every held (allocated, fetch not yet sent) entry.
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

    // Rank each merging port against the earlier ports targeting the same entry.
    merge_same_mask = '0;

    stb_hit = '0;

    // ------------------------------------------------------------
    // request path: merge loads, allocate MSHR, or bypass to NoC
    // ------------------------------------------------------------
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        if (req_in_valid[tile_i][port_i]) begin
          // default tag 0 (= no MSHR entry / bypass); overwritten with (entry id + 1) on alloc.
          req_out[tile_i][port_i].mshr_tag = '0;
          if (req_in[tile_i][port_i].wdata.amo != '0) begin
            req_out[tile_i][port_i].burst_len = BurstLenWidth'(1);
          end
          if (req_merge_valid[tile_i][port_i]) begin
            // Merge hit: accept without touching NoC. Capacity was decided per way alongside
            // req_hit_way and selected with it, so no entry array is read at the selected id here.
            // The merge itself is RECORDED by the arbiter; the apply runs once per bank after this
            // loop closes, so no lane reads what an earlier lane wrote.
            req_in_ready[tile_i][port_i] =
                req_merge_ready[tile_i][port_i] && req_hit_cap_sel[tile_i][port_i];
          end else begin
            // Not a merge into a resident entry: decide STALL / ALLOCATE / BYPASS.
            if (req_can_merge[tile_i][port_i] &&
                (req_addr_hit_drain[tile_i][port_i] || req_meta_conflict[tile_i][port_i])) begin
              // A same-address entry is draining, or a meta-id range conflict exists: wait for it.
              req_in_ready[tile_i][port_i]  = 1'b0;
              req_out_valid[tile_i][port_i] = 1'b0;
            end else if (req_owner_inflight[tile_i][port_i]) begin
              // The one conflict with an in-flight allocation that cannot be forwarded:
              // req_meta_ovlp_map scans mshr_q, so it cannot see an in-flight allocation whose meta
              // range overlaps this request's. Same-line requests do not come here -- they forward
              // into the in-flight entry (req_fwd_hit) and merge in the same cycle.
              req_in_ready[tile_i][port_i]  = 1'b0;
              req_out_valid[tile_i][port_i] = 1'b0;
            end else if (req_can_merge[tile_i][port_i] && !req_alloc_found[tile_i][port_i] &&
                         (bank_has_free[req_bank[tile_i][port_i]] || cfg_bankfull_bp)) begin
              // Mergeable miss that lost this bank's single allocation slot this cycle, but a free
              // way exists: STALL and retry.
              req_in_ready[tile_i][port_i]  = 1'b0;
              req_out_valid[tile_i][port_i] = 1'b0;
            end else begin
              // ALLOCATE (won the per-bank slot) or BYPASS (non-mergeable store/AMO, or a
              // mergeable miss whose bank is full): forward this request to the NoC.
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
                // Bank-full mergeable misses fall through here as a plain bypass).
                if (req_alloc_found[tile_i][port_i] &&
                    req_in_ready[tile_i][port_i]) begin
                // stamp the egress NoC request with (allocated entry id + 1) so the returning
                // response routes back to this entry by direct index (tag 0 stays the bypass
                // sentinel).
                // Per-LANE output, so it stays here.
                req_out[tile_i][port_i].mshr_tag =
                    MshrTagWidth'(req_alloc_found_mshr_id[tile_i][port_i]) + MshrTagWidth'(1);
                // RR victim advance: firing on a still-valid CACHED way IS a reclaim -- move that
                // bank's scan start just past the evicted way.
                if (CacheVictimRR && CacheReclaimable) begin
                  evict_vid = int'(req_alloc_found_mshr_id[tile_i][port_i]);
                  evict_vw  = evict_vid & unsigned'(MshrWaysPerBank - 1);
                  if (mshr_q_valid[evict_vid] && (mshr_q[evict_vid].state == MSHR_CACHED)) begin
                    victim_rr_d[evict_vid / MshrWaysPerBank] =
                        (evict_vw + 1 >= MshrWaysPerBank) ? '0 : VictimPtrW'(evict_vw + 1);
                  end
                end
                // RECORD the allocation; the entry write happens once per bank after the loop.
                end
              end
            end
            // RECORD the store's byte-merge; the merge itself happens once per entry after
            // this loop.
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
                if (mshr_d_valid[cache_hit_e] && !alloc_inflight[cache_hit_e] &&
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

    // Apply the allocations recorded above, ONE ITERATION PER BANK. The guarantee is the
    // allocator's own: bank_win_oh grants at most one allocation per bank per
    // cycle, and bank_free_id[b] is by construction a way of bank b. So these MshrBankNum writes
    // target distinct entries and need no ordering between them -- exactly the property the old
    for (int e = 0; e < MshrNum; e++) begin
      if (alloc_inflight[e]) begin
        // Recorded, not applied -- see the mshr_alloc_set declaration. No pass below needs to see
        // this entry as valid: a response cannot arrive for an entry allocated this cycle
        // (no_alloc_while_resp_landing asserts exactly that), and every clear guard excludes
        // MSHR_WAIT_RESP, which is what allocation writes.
        mshr_alloc_set[e] = 1'b1;
        mshr_d[e]       = '0;
        mshr_wr_all[e]  = 1'b1;
        mshr_d[e].base_addr    = agb_q_addr[e / MshrWaysPerBank];
        mshr_d[e].tgt_group_id = agb_q_grp[e / MshrWaysPerBank];
        mshr_d[e].burst_len    = agb_q_len[e / MshrWaysPerBank];
        mshr_d[e].state        = MSHR_WAIT_RESP;
        mshr_d[e].cacheable    = 1'b1;
        mshr_d[e].beats_left   = agb_q_len[e / MshrWaysPerBank];
        mshr_d[e].beat_pending  = '0;
        mshr_d[e].beat_pending2 = '0;
        mshr_d[e].beat2_armed   = 1'b0;
`ifndef TARGET_SYNTHESIS
        mshr_d[e].beat_seen = '0;
        mshr_d[e].beat_done = '0;
`endif
        // Owner request is always stored in sub_reqs[0].
        mshr_d[e].sub_reqs[0].valid        = 1'b1;
        mshr_d[e].sub_reqs[0].tile_id      = agb_q_tile[e / MshrWaysPerBank];
        mshr_d[e].sub_reqs[0].port_id      = agb_q_port[e / MshrWaysPerBank];
        mshr_d[e].sub_reqs[0].core_id      = agb_q_core[e / MshrWaysPerBank];
        mshr_d[e].sub_reqs[0].meta_id_base = agb_q_meta[e / MshrWaysPerBank];
`ifndef TARGET_SYNTHESIS
        mshr_d[e].cache_hit_cnt = '0;
`endif
        // Hold-the-fetch: arm the per-type hold window (single vs burst). A 0 window (or the
        // feature off) means the fetch went out this same cycle on the passthrough, so mark it
        // issued immediately.
        mshr_d[e].hold_cnt =
            hold_ticks((agb_q_len[e / MshrWaysPerBank] == BurstLenWidth'(1)) ?
                       cfg_hold_window_single : cfg_hold_window_burst);
        mshr_d[e].issued =
            (((agb_q_len[e / MshrWaysPerBank] == BurstLenWidth'(1)) ?
              cfg_hold_window_single : cfg_hold_window_burst) == 0);
        mshr_d[e].sub_reqs_num = SubReqCountW'(1);
        // Cache self-invalidate: the owner is the first served sub-request.
        mshr_d[e].served_cnt = ServedCntW'(1);
      end
    end

    // Apply the merges recorded above, ONE ITERATION PER BANK. OneMergePerBank guarantees at
    // most one merge per bank and an entry lies in exactly one bank, so no two of these writes can
    // target the same entry -- the 32-deep lane chain becomes MshrBankNum independent writes.
    // B is a loop constant here, so b*MshrWaysPerBank + way is a MshrWaysPerBank:1 select and the
    // write is bank-local as well as parallel (the per-lane form was MshrNum:1).
    for (int e = 0; e < MshrNum; e++) begin
      if (merge_inflight[e]) begin
        // merge_rank is identically zero under this knob, so the slot is just the registered
        // count -- no need to have carried it out of the lane loop.
        mgb_slot = MergeRankW'(mshr_q[e].sub_reqs_num);
        mshr_id_we[e] = 1'b1;
        mshr_d[e].sub_reqs[mgb_slot].valid        = 1'b1;
        mshr_d[e].sub_reqs[mgb_slot].tile_id      = mgb_q_tile[e / MshrWaysPerBank];
        mshr_d[e].sub_reqs[mgb_slot].port_id      = mgb_q_port[e / MshrWaysPerBank];
        mshr_d[e].sub_reqs[mgb_slot].core_id      = mgb_q_core[e / MshrWaysPerBank];
        mshr_d[e].sub_reqs[mgb_slot].meta_id_base = mgb_q_meta[e / MshrWaysPerBank];
        mshr_d[e].sub_reqs_num = SubReqCountW'(mgb_slot + MergeRankW'(1));
        // The entry may have turned DRAIN_RESP between the decision and now (serve timeout, store
        // force-drain, AMO). Neither state branch below fires then, and the head seed is skipped
        // because beat_pending is already non-zero, so this subscriber would never be drained.
        if (mshr_q[e].state == MSHR_DRAIN_RESP) begin
          mshr_d[e].beat_pending[mgb_slot] = 1'b1;
          if (PD2 && mshr_q[e].beat2_armed) mshr_d[e].beat_pending2[mgb_slot] = 1'b1;
        end
        mshr_d[e].served_cnt   = mshr_q[e].served_cnt + ServedCntW'(1);
`ifndef TARGET_SYNTHESIS
        if (EnableRespCache && (mshr_q[e].state == MSHR_CACHED)) begin
          mshr_d[e].cache_hit_cnt = mshr_d[e].cache_hit_cnt + 1'b1;
        end
`endif
        if (EnableRespCache && (mshr_q[e].state == MSHR_CACHED)) begin
          mshr_d[e].state         = MSHR_DRAIN_RESP;
          mshr_d[e].beats_left    = BurstLenWidth'(1);
          mshr_d[e].beat_pending  = '0;
          mshr_d[e].beat_pending2 = '0;
          mshr_d[e].beat2_armed   = 1'b0;
`ifndef TARGET_SYNTHESIS
          mshr_d[e].beat_seen     = '0;
          mshr_d[e].beat_seen[0]  = 1'b1;
          mshr_d[e].beat_done     = '0;
`endif
        end else if (RespWaitSubsSingle &&
                     (mshr_q[e].state == MSHR_RESP_HOLD) &&
                     ((mgb_slot + MergeRankW'(1)) >=
                      SubReqCountW'(cfg_hold_subs_single))) begin
          mshr_d[e].state         = MSHR_DRAIN_RESP;
          mshr_d[e].beats_left    = BurstLenWidth'(1);
          mshr_d[e].beat_pending  = '0;
          mshr_d[e].beat_pending2 = '0;
          mshr_d[e].beat2_armed   = 1'b0;
`ifndef TARGET_SYNTHESIS
          mshr_d[e].beat_seen     = '0;
          mshr_d[e].beat_seen[0]  = 1'b1;
          mshr_d[e].beat_done     = '0;
`endif
        end
      end
    end

    // One byte-merge per entry. The lane walk lives in gen_stb_e above; this only applies the
    // per-byte winner. resp_buf_rd_ptr is read from mshr_q, matching the ENABLE index below.
    stb_bytes = '0; stb_ovl = '0;
    for (int e = 0; e < MshrNum; e++) begin
      for (int b = 0; b < StrbW; b++) begin
        stb_bytes[e][b] = |stb_byte_req[e][b];
`ifndef TARGET_SYNTHESIS
        // Two lanes writing one byte in one cycle -- a statistic, not a hazard: the winner is
        // defined (highest lane), exactly as the sequential form defined it.
        if ($countones(stb_byte_req[e][b]) > 1) stb_ovl[e] = 1'b1;
`endif
        if (stb_bytes[e][b]) begin
          mshr_d[e].resp_buf[mshr_q[e].resp_buf_rd_ptr].data[b*8 +: 8] = stb_byte_data[e][b];
        end
      end
      if (|stb_bytes[e]) begin
        // Pointer from mshr_q: the only earlier writer of resp_buf_rd_ptr is the allocation, which
        // blanks the entry and (at CacheReclaimable=0) only takes an INVALID way, while stb_hit
        // requires a valid MSHR_CACHED entry.
        mshr_rb_we[e][mshr_q[e].resp_buf_rd_ptr] = 1'b1;
        // No resp_buf_cnt re-arm here: stb_hit requires a valid MSHR_CACHED entry, and
        // cached_entry_holds_data asserts such an entry always has resp_buf_cnt != 0.
      end
    end

    // Hold-the-fetch replay: issue the withheld fetch of every hold_done entry (window expired, or
    // subscriber count reached HoldSubs -- checked on mshr_d so a merge landing THIS cycle
    if (HoldWindowMax != 0) begin
      // Step 1: hold-done and owner lane per ENTRY -- lane-independent, so computed once
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
      // Step 2: each lane picks its own winner, in parallel. Lanes are disjoint by construction
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
              // would put the 64:1 field mux back on the d-side cone for no benefit.
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

    if (EnableRespCache && amo_invalidate) begin
      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        // From mshr_q: allocation writes MSHR_WAIT_RESP so it can never present CACHED here.
        // !merge_inflight is required: a merge decided before amo_invalidate rose is applied
        // under it, and retiring the entry would drop the subscriber that merge just attached.
        if (mshr_q_valid[mshr_i] && (mshr_q[mshr_i].state == MSHR_CACHED) &&
            !merge_inflight[mshr_i]) begin
          mshr_d_valid[mshr_i] = 1'b0;
          // Retire by dropping valid only -- do NOT clear the entry.
        end
      end
    end

    // Cache self-invalidate: a CACHED entry (all subscribers drained, sub_reqs_num==0)
    // that has served its per-type sharing target -- HoldSubsSingle for a scalar/single entry.
    if (CacheSelfInval && EnableRespCache) begin
      for (int e = 0; e < MshrNum; e++) begin
        // cfg_cache_reuse_target == 0 keeps the legacy operand (the per-type sharing target), so
        // this expression is structurally what it was before the CSR existed.
        // From mshr_q, with the merge fire term as an explicit veto. This is the one cache retire a
        // merge CAN reach: a merge into a CACHED entry sets state = MSHR_DRAIN_RESP and bumps
        // sub_reqs_num/served_cnt, which the mshr_d form observed and the mshr_q form cannot.
        // !st_merge_drain[e] restores exactly that veto; without it the entry would be retired and
        // the merging subscriber's response lost.
        if (mshr_q_valid[e] && (mshr_q[e].state == MSHR_CACHED) &&
            !st_merge_drain[e] && !merge_decided[e] &&
            (mshr_q[e].sub_reqs_num == '0) &&
            (mshr_q[e].served_cnt >=
             ((cfg_cache_reuse_target != '0)
                ? ServedCntW'(cfg_cache_reuse_target)
                : ServedCntW'((mshr_q[e].burst_len == BurstLenWidth'(1)) ? cfg_hold_subs_single : cfg_hold_subs_burst)))) begin
          mshr_d_valid[e] = 1'b0;
          // Retire by dropping valid only (see the first retire site for why).
        end
      end
    end

    // ------------------------------------------------------------
    // response path: capture MSHR responses or bypass to group
    // ------------------------------------------------------------
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        resp_capture_fire[tile_i][port_i] = 1'b0;
        resp_capture_beat_offset[tile_i][port_i] = '0;
        resp_is_mshr[tile_i][port_i] = 1'b0;
        resp_mshr_id[tile_i][port_i] = '0;
        if (resp_in_valid[tile_i][port_i] &&
            (resp_in[tile_i][port_i].wen == 1'b0) &&
            (resp_in[tile_i][port_i].rdata.amo == '0)) begin
          // route the response by its round-tripped tag instead of scanning all entries.
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
          // Ready and fire come from the per-entry grant below, not from walking the lanes
          // and decrementing a slot counter as we go -- that decrement made lane k+1's readiness
        end else begin
          resp_in_ready[tile_i][port_i] = resp_out_ready[tile_i][port_i];
        end

        if (resp_in_valid[tile_i][port_i] && !resp_is_mshr[tile_i][port_i]) begin
          resp_out_valid[tile_i][port_i] = 1'b1;
          resp_out[tile_i][port_i] = resp_in[tile_i][port_i];
          // NO RETAG: a bypassed burst is expanded at the DESTINATION tile, which applies the
          // lane law there relative to this requester's own core_id/meta_id.
          resp_from_bypass[tile_i][port_i] = 1'b1;
        end
      end
    end

    // Grant response slots per ENTRY, then capture once per entry.
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
    if (CapPerBank) begin
      // One arbiter per bank over the union of its ways' wanters.
      for (int b = 0; b < MshrBankNum; b++) begin
        capb_want[b] = '0;
        for (int w = 0; w < MshrWaysPerBank; w++) begin
          capb_want[b] = capb_want[b] | cap_want[b * MshrWaysPerBank + w];
        end
        capb_l1[b] = capb_want[b] & (~capb_want[b] + NumRespLanes'(1));
        capb_rest  = capb_want[b] & ~capb_l1[b];
        capb_l2[b] = capb_rest    & (~capb_rest    + NumRespLanes'(1));
        capb_e1[b] = '0;
        capb_e2[b] = '0;
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int pp = 1; pp < NumRemoteRespPortsPerTile; pp++) begin
            capb_lane = RespLaneW'(t * NumRespPortsActive + (pp - 1));
            if (capb_l1[b][capb_lane]) capb_e1[b] = resp_mshr_id[t][pp];
            if (capb_l2[b][capb_lane]) capb_e2[b] = resp_mshr_id[t][pp];
          end
        end
        capb_same[b] = (capb_e1[b] == capb_e2[b]);
        capb_g1[b] = (capb_l1[b] != '0) &&
                     (mshr_resp_slots[capb_e1[b]] >= RespBufCountW'(1));
        capb_g2[b] = (capb_l2[b] != '0) &&
                     (capb_same[b] ? (mshr_resp_slots[capb_e1[b]] >= RespBufCountW'(2))
                                   : (mshr_resp_slots[capb_e2[b]] >= RespBufCountW'(1)));
      end
      // Map back onto the per-entry vectors the rest of the pass reads, so nothing downstream
      // changes. The guards matter: a bank with no wanter must not write entry 0 and clobber
      // bank 0's grant, since capb_e* default to 0.
      cap_first  = '0;
      cap_second = '0;
      cap_g1     = '0;
      cap_g2     = '0;
      for (int b = 0; b < MshrBankNum; b++) begin
        if (capb_l1[b] != '0) begin
          cap_first[capb_e1[b]] = capb_l1[b];
          cap_g1[capb_e1[b]]    = capb_g1[b];
        end
        if (capb_l2[b] != '0) begin
          if (capb_same[b]) begin
            cap_second[capb_e1[b]] = capb_l2[b];
            cap_g2[capb_e1[b]]     = capb_g2[b];
          end else begin
            cap_first[capb_e2[b]] = capb_l2[b];
            cap_g1[capb_e2[b]]    = capb_g2[b];
          end
        end
      end
    end else begin
      for (int e = 0; e < MshrNum; e++) begin
        cap_first[e]  = cap_want[e] & (~cap_want[e] + NumRespLanes'(1));
        cap_rest      = cap_want[e] & ~cap_first[e];
        cap_second[e] = cap_rest    & (~cap_rest    + NumRespLanes'(1));
        cap_g1[e] = (cap_first[e]  != '0) && (mshr_resp_slots[e] >= RespBufCountW'(1));
        cap_g2[e] = (cap_second[e] != '0) && (mshr_resp_slots[e] >= RespBufCountW'(2));
      end
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
    // Gathering per entry would cost MshrNum x 32 and blow up an already slow elaboration.
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
                '{beat_off: BeatOffW'(resp_capture_beat_offset[tile_i][port_i]),
                  data:     resp_in[tile_i][port_i].rdata.data};
          end else begin
            cap_d1[resp_mshr_id[tile_i][port_i]] =
                '{beat_off: BeatOffW'(resp_capture_beat_offset[tile_i][port_i]),
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
        // Register-sourced: the only earlier writer of resp_buf_wr_ptr is the allocation, and it
        // can never touch an entry the capture writes -- way_reclaimable requires MSHR_CACHED while
        // the capture requires WAIT_RESP or DRAIN_RESP.
        cap_s0 = mshr_q[e].resp_buf_wr_ptr;
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
        end
        if (cap_g2[e]) begin
          mshr_rb_we[e][cap_s1]      = 1'b1;
          mshr_d[e].resp_buf[cap_s1] = cap_d1[e];
        end
        // One saturating sum, not two chained increments. The value entering is mshr_q
        // resp_buf_cnt:
        // the only earlier writer is the allocation's whole-entry blank, and capture requires
        // mshr_q_valid, which a freshly allocated entry gains only at the next edge.
        cap_cnt_sum = RespBufCountW'(mshr_q[e].resp_buf_cnt)
                    + RespBufCountW'(cap_g1[e]) + RespBufCountW'(cap_g2[e]);
        mshr_d[e].resp_buf_cnt = (cap_cnt_sum > RespBufCountW'(RespBufWords))
                               ? RespBufCountW'(RespBufWords) : cap_cnt_sum;
        mshr_d[e].resp_buf_wr_ptr = cap_g2[e] ? cap_n1 : cap_n0;
        // burst_len from mshr_q: written only by the allocation, which cannot reach an entry the
        // capture is writing. sub_reqs_num from mshr_d: the cut applies a merge one cycle after it
        // is decided, so a beat can land on top of that merge.
        if (RespWaitSubsSingle && !amo_invalidate &&
            (mshr_q[e].burst_len == BurstLenWidth'(1)) &&
            (mshr_d[e].sub_reqs_num < SubReqCountW'(cfg_hold_subs_single))) begin
          mshr_d[e].state    = MSHR_RESP_HOLD;
          mshr_d[e].hold_cnt = hold_ticks(cfg_serve_timeout);
        end else begin
          mshr_d[e].state    = MSHR_DRAIN_RESP;
        end
      end
    end

    // The MSHR_RESP_HOLD predicate, without reading mshr_d. Only the CAPTURE can create
    // MSHR_RESP_HOLD (alloc writes WAIT_RESP, merge writes DRAIN_RESP) and only a MERGE can clear a
    // pre-existing one, so both are expressible from mshr_q plus their own fire terms -- the value
    // the store force-drain below would have read out of mshr_d, without serialising behind the
    // capture's write.
    // burst_len / sub_reqs_num come from mshr_q: the no-late-join gate on req_merge_valid
    // (req_addr_hit_drain covers "a response is arriving this cycle") means no merge can touch an
    // entry the capture is writing, so capture and merge are mutually exclusive on one entry and
    // the priority below cannot mask a real update.
    // mgb_slot needs no recording -- it is already defined as MergeRankW'(mshr_q[e].sub_reqs_num).
    st_cap_fire    = '0;
    st_cap_hold    = '0;
    st_post_cap    = '{default: MSHR_IDLE};
    st_hold_post_cap = '0;
    for (int e = 0; e < MshrNum; e++) begin
      st_cap_fire[e] = cap_g1[e] | cap_g2[e];
      // mshr_d: the merge apply above may have raised sub_reqs_num this cycle (see the capture
      // pass). Register-fed, so no request-path depth is added.
      st_cap_hold[e] = st_cap_fire[e] && RespWaitSubsSingle && !amo_invalidate &&
                       (mshr_q[e].burst_len == BurstLenWidth'(1)) &&
                       (mshr_d[e].sub_reqs_num < SubReqCountW'(cfg_hold_subs_single));
      st_post_cap[e] = st_cap_fire[e]
                     ? (st_cap_hold[e]    ? MSHR_RESP_HOLD : MSHR_DRAIN_RESP)
                     : (st_alloc_fire[e]  ? MSHR_WAIT_RESP
                     : (st_merge_drain[e] ? MSHR_DRAIN_RESP : mshr_q[e].state));
      st_hold_post_cap[e] = (st_post_cap[e] == MSHR_RESP_HOLD);
    end

    // A buffered response predates any store/AMO observed after it returned.
    st_force_drain = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        if (req_in_valid[tile_i][port_i] && req_in_ready[tile_i][port_i] &&
            req_is_store[tile_i][port_i] &&
            (req_len[tile_i][port_i] == BurstLenWidth'(1))) begin
          for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
            cache_hit_e =
                int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i;
            // Reads only, so the 32 lane evaluations are independent instead of chained.
            // The address test is req_addr_hit_way, not a second copy of it: same e_abs, same
            // mshr_q vintage, same two compares, and its extra req_in_valid term is implied by
            // this block's own guard.
            // st_post_cap holds the value mshr_d would, computed from mshr_q plus the capture/merge
            // fire terms. The sibling MSHR_RESP_HOLD test restricts this to an entry held in mshr_q
            // or put there by the capture -- never CACHED, never freshly allocated (st_alloc_fire
            // takes priority and yields MSHR_WAIT_RESP) -- and for such an entry
            // mshr_d_valid == mshr_q_valid with neither address field written.
            if (req_addr_hit_way[tile_i][port_i][way_i] && st_hold_post_cap[cache_hit_e]) begin
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
        // From mshr_q + st_post_cap. Under amo_invalidate the capture cannot write MSHR_RESP_HOLD
        // (st_cap_hold carries !amo_invalidate), so the only remaining writer is the store
        // force-drain, which writes this identical field set -- re-firing is idempotent.
        // mshr_d_valid == mshr_q_valid for a RESP_HOLD entry: both retires above are CACHED-gated.
        if (mshr_q_valid[mshr_i] && (st_post_cap[mshr_i] == MSHR_RESP_HOLD)) begin
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

    // Serve-target timeout (group_mshr_serve_timeout).
    if (cfg_serve_timeout != 0) begin
      for (int e = 0; e < MshrNum; e++) begin
        // Parallel form. MSHR_RESP_HOLD here comes from the capture (st_cap_hold) or from mshr_q,
        // and only the store force-drain and the AMO block can have cleared it -- both run above.
        // !amo_invalidate covers the latter because that block converts EVERY RESP_HOLD entry.
        st_hold_live = mshr_q_valid[e] && (st_post_cap[e] == MSHR_RESP_HOLD) &&
                       !st_force_drain[e] && !amo_invalidate;
        // The capture loads the window as a constant, so this is a 2:1 mux off registered state
        // rather than a read of what the capture wrote. hold_ticks(cfg_serve_timeout) != 0 under
        // this pass's own guard, so a just-captured entry can never expire on the same cycle.
        st_hold_src  = st_cap_hold[e] ? hold_ticks(cfg_serve_timeout) : mshr_q[e].hold_cnt;
        if (st_hold_live) begin
          if (st_hold_src != '0) begin
            if (hold_tick[e]) mshr_d[e].hold_cnt = st_hold_src - HoldCntW'(1);
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
        // mshr_d_valid STAYS: the AMO invalidate and the self-invalidate above are CACHED-gated and
        // target exactly these entries, so a q-sourced read would age an entry already retired this
        // cycle. The other three reads are safe -- nothing writes MSHR_CACHED before the finalize,
        // so state == CACHED is st_post_cap == CACHED; and under that predicate no merge touched
        // the entry (a merge into a CACHED entry sets st_merge_drain), so sub_reqs_num and hold_cnt
        // are still their registered values.
        end else if (CacheSelfInval && EnableRespCache && mshr_d_valid[e] &&
                     (st_post_cap[e] == MSHR_CACHED) && !merge_decided[e] &&
                     (mshr_q[e].sub_reqs_num == '0)) begin
          // A cache line that never reaches its sharing target ages out instead of pinning its way
          // forever. Entries that DO reach the target are freed earlier by the self-invalidate
          // pass.
          if (mshr_q[e].hold_cnt != '0) begin
            if (hold_tick[e]) mshr_d[e].hold_cnt = mshr_q[e].hold_cnt - HoldCntW'(1);
          end else begin
            // Cache line aged out WITHOUT reaching its reuse target: its second cohort never
            // completed in time. Distinct from self-invalidate, and the number that says whether
            // the residency is too SHORT.
`ifndef TARGET_SYNTHESIS
            mshr_cache_timeout_dbg[e] = 1'b1;
`endif
            mshr_d_valid[e] = 1'b0;
            // Retire by dropping valid only (see the first retire site for why).
          end
        end
      end
    end

`ifndef TARGET_SYNTHESIS
    // Head-beat offset per entry. Its only readers are beat_done and one assertion, both
    // simulation-only, so it is not built for synthesis.
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
`endif

    // Initialize pending-requester bitmap for a new head beat.
    // Trigger AND data both on mshr_d -- see SOURCING DISCIPLINE. A request hitting a CACHED entry
    // merges in and flips it to DRAIN_RESP in the same cycle, so mshr_q still shows the
    // cache-resident state where fin_cache zeroed sub_reqs. An all-zero beat_pending is not a
    // no-op: with state == DRAIN_RESP the fin logic reads it as "drain complete" and retires the
    // beat unserved. Free: the trigger already reads mshr_d.state, which the same merge writes.
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
    // buffered beats) and its ONE-SHOT pending arm.
    for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      if (PD2 && mshr_d_valid[mshr_i] &&
          (mshr_d[mshr_i].burst_len != BurstLenWidth'(1)) &&
          (mshr_d[mshr_i].resp_buf_cnt >= RespBufCountW'(2))) begin
        // Trigger and data on mshr_d, like the head-beat seed: req_addr_hit_drain blocks a merge
        // DECISION into a draining entry, but the cut applies it a cycle later, so mshr_d can carry
        // a subscriber mshr_q does not. beat2_armed is one-shot -- a slot missed here is never
        // re-seeded, and that subscriber is never served.
        if ((mshr_d[mshr_i].state == MSHR_DRAIN_RESP) &&
            !mshr_d[mshr_i].beat2_armed &&
            (mshr_q[mshr_i].sub_reqs_num != '0)) begin
          for (int s = 0; s < MshrMergeReqs; s++) begin
            mshr_d[mshr_i].beat_pending2[s] = mshr_d[mshr_i].sub_reqs[s].valid;
          end
          mshr_d[mshr_i].beat2_armed = 1'b1;
        end
      end
    end

    // ------------------------------------------------------------
    // drain captured responses to all recorded sub-requests
    // ------------------------------------------------------------
    bp_clr = '0; bp2_clr = '0; sv_clr = '0;
    if (DrainMultiPort) begin
      // Use all available response ports per cycle.
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          // bypass MUST take the port -- bypass responses are non-backpressurable by
          // contract, while MSHR-targeted responses are buffered (resp_buf) and CAN be
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

      // One entry published per bank, round-robin and port-independent: computed once here,
      // shared by every (tile,port) instance below.
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
            // RR fairness: rotate the entry visit by drain_mshr_rr and the sub_req
            // visit by subreq_rr (separate bases) so high-index entries/sub_reqs are not starved.
            drain_sel_base     = EnableRrFairness ? MshrIdxW'(drain_mshr_rr_q) : '0;
            drain_sel_sub_base = EnableRrFairness ? SubIdxW'(subreq_rr_q) : '0;
            // Per-entry: does this entry offer any sub-request eligible for THIS port?
            drain_ent_cand = '0;
            bank_cand      = '0;
            if (BankPublish) begin
              // Evaluate only the MshrBankNum published entries, not all MshrNum -- the
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
            if (BankPublish) begin
              // MshrBankNum-wide arbitration, exactly equivalent to the MshrNum-wide one.
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
            resp_out[tile_i][port_i].rdata.data = drv_data[resp_sel_mshr_id[tile_i][port_i]];
            // Re-emit beat b for THIS requester under the lane law: lane from the low BurstLaneW
            // bits, row from the rest.
            resp_out[tile_i][port_i].rdata.core_id =
                drv_sub_core[resp_sel_mshr_id[tile_i][port_i]]
                            [resp_sel_subreq_idx[tile_i][port_i]] +
                tile_core_id_t'(drv_beat_off[resp_sel_mshr_id[tile_i][port_i]][BurstLaneW-1:0]);
            resp_out[tile_i][port_i].rdata.meta_id =
                drv_sub_meta[resp_sel_mshr_id[tile_i][port_i]]
                            [resp_sel_subreq_idx[tile_i][port_i]] +
                meta_id_t'(drv_beat_off[resp_sel_mshr_id[tile_i][port_i]] >> BurstLaneW);
            resp_out[tile_i][port_i].rdata.amo = '0;  // sub-requests are loads by construction (req_is_load)
            resp_from_mshr[tile_i][port_i] = 1'b1;
`ifndef TARGET_SYNTHESIS
            resp_mshr_id_dbg[tile_i][port_i] = resp_sel_mshr_id[tile_i][port_i];
`endif

            if (resp_out_ready[tile_i][port_i]) begin
              // Record, do not write. Writing here made lane k+1 read the entry that
              // lane k had just modified -- a 32-deep chain for what is only ever a bit clear.
              bp_clr[resp_sel_mshr_id[tile_i][port_i]][
                  resp_sel_subreq_idx[tile_i][port_i]] = 1'b1;
              // Clear sub_req.valid on the drain handshake so the next cycle's beat_pending
              // seed cannot re-include it and re-deliver the same response.
              if (drv_burst_one[resp_sel_mshr_id[tile_i][port_i]]) begin
                sv_clr[resp_sel_mshr_id[tile_i][port_i]][
                    resp_sel_subreq_idx[tile_i][port_i]] = 1'b1;
              end
            end
          end
        end
      end

      // ParityDrain second-slot service: the beat at rd_ptr+1 drains CONCURRENTLY with the head on
      // its own parity port (consecutive beats have opposite parity, so head and slot2 of one
      if (PD2) begin
        // Publish at most one second-slot entry per bank. Lane-independent, so it is built
        // once here rather than 32 times inside the (tile, resp port) loops below. The way scan is
        // rotated by the shared drain RR pointer, so publication reaches every way over time.
        drain2_bank_base = BankIdW'(EnableRrFairness ? (drain_mshr_rr_q / MshrWaysPerBank) : '0);
        for (int e = 0; e < MshrNum; e++) begin
          drain2_ent_any[e] = |drain2_sub_ready[e];
        end
        for (int b = 0; b < MshrBankNum; b++) begin
          drain2_pub_v[b] = 1'b0;
          drain2_pub_w[b] = '0;
          // Descending scan so the LAST match written is the one closest to the rotation base,
          // matching the head-beat publication's form exactly.
          for (int k = MshrWaysPerBank - 1; k >= 0; k--) begin
            drain2_scan_w = VictimPtrW'((EnableRrFairness ? int'(drain_mshr_rr_q) : 0) + k);
            if (drain2_ent_any[b * MshrWaysPerBank + int'(drain2_scan_w)]) begin
              drain2_pub_v[b] = 1'b1;
              drain2_pub_w[b] = drain2_scan_w;
            end
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
              // Entry candidates for the second slot: does this entry offer a beat2 sub-request
              // for THIS port?
              drain2_cand = '0;
              drain2_bank_cand = '0;
              drain2_any = 1'b0;
              if (Drain2BankPublish) begin
                // Only the published entry of each bank is selectable. b is a loop constant, so
                // b*MshrWaysPerBank + pub_w[b] is a MshrWaysPerBank:1 select, not MshrNum:1.
                for (int b = 0; b < MshrBankNum; b++) begin
                  for (int s = 0; s < MshrMergeReqs; s++) begin
                    if (drain2_pub_v[b] &&
                        drain2_sub_ready[b * MshrWaysPerBank + int'(drain2_pub_w[b])][s] &&
                        (drain2_sub_tile[b * MshrWaysPerBank + int'(drain2_pub_w[b])][s] ==
                         tile_group_id_t'(tile_i)) &&
                        (drain2_sub_port[b * MshrWaysPerBank + int'(drain2_pub_w[b])] ==
                         port_i[RespPortIdW-1:0])) begin
                      drain2_bank_cand[b] = 1'b1;
                    end
                  end
                end
                drain2_any = |drain2_bank_cand;
              end else begin
                for (int e = 0; e < MshrNum; e++) begin
                  for (int s = 0; s < MshrMergeReqs; s++) begin
                    if (drain2_sub_ready[e][s] &&
                        (drain2_sub_tile[e][s] == tile_group_id_t'(tile_i)) &&
                        (drain2_sub_port[e] == port_i[RespPortIdW-1:0])) begin
                      drain2_cand[e] = 1'b1;
                    end
                  end
                end
                drain2_any = |drain2_cand;
              end
              // Hi/lo split about the rotation base, then isolate the lowest set bit of each.
              drain2_first = '0;
              if (Drain2BankPublish) begin
                for (int b = 0; b < MshrBankNum; b++) begin
                  drain2_bank_rr_mask[b] =
                      EnableRrFairness ? (BankIdW'(b) >= drain2_bank_base) : 1'b1;
                end
                drain2_bhi    = drain2_bank_cand &  drain2_bank_rr_mask;
                drain2_blo    = drain2_bank_cand & ~drain2_bank_rr_mask;
                drain2_bfirst = (drain2_bhi != '0)
                                    ? (drain2_bhi & (~drain2_bhi + MshrBankNum'(1)))
                                    : (drain2_blo & (~drain2_blo + MshrBankNum'(1)));
                // Re-expand the winning bank to the absolute entry one-hot so everything
                // downstream (drain2_idx, drain2_mshr_i, the sub-request scan) is unchanged.
                for (int b = 0; b < MshrBankNum; b++) begin
                  if (drain2_bfirst[b]) begin
                    drain2_first[b * MshrWaysPerBank + int'(drain2_pub_w[b])] = 1'b1;
                  end
                end
              end else begin
                for (int e = 0; e < MshrNum; e++) begin
                  drain2_rr_mask[e] = EnableRrFairness ? (MshrIdxW'(e) >= drain2_base) : 1'b1;
                end
                drain2_hi    = drain2_cand &  drain2_rr_mask;
                drain2_lo    = drain2_cand & ~drain2_rr_mask;
                drain2_first = (drain2_hi != '0) ? (drain2_hi & (~drain2_hi + MshrNum'(1)))
                                                 : (drain2_lo & (~drain2_lo + MshrNum'(1)));
              end
              drain2_idx   = '0;
              for (int b = 0; b < MshrNum; b++) begin
                if (drain2_first[b]) drain2_idx |= MshrIdxW'(b);
              end
              if (drain2_any) begin
                drain2_mshr_i = drain2_idx;   // already absolute -- no base add
                // First eligible sub-request inside the winning entry, same rotated order.
                for (int ks = 0; ks < MshrMergeReqs; ks++) begin
                  drain2_s = SubIdxW'(drain2_sub_base + SubIdxW'(ks));
                  // Reuse the hoisted vectors instead of re-reading mshr_d[drain2_mshr_i] -- a
                  // 4-bit
                  // select in place of a full-entry MshrNum:1 struct mux.
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
              resp_out[tile_i][port_i].rdata.data = drv2_data[drain2_sel_e2];
              // Same lane law as the head slot.
              resp_out[tile_i][port_i].rdata.core_id =
                  drv_sub_core[drain2_sel_e2][resp_sel2_subreq_idx[tile_i][port_i]] +
                  tile_core_id_t'(drain2_beat_off[drain2_sel_e2][BurstLaneW-1:0]);
              resp_out[tile_i][port_i].rdata.meta_id =
                  drv_sub_meta[drain2_sel_e2][resp_sel2_subreq_idx[tile_i][port_i]] +
                  meta_id_t'(drain2_beat_off[drain2_sel_e2] >> BurstLaneW);
              resp_out[tile_i][port_i].rdata.amo = '0;  // sub-requests are loads by construction (req_is_load)
              resp_from_mshr[tile_i][port_i] = 1'b1;
`ifndef TARGET_SYNTHESIS
              resp_mshr_id_dbg[tile_i][port_i] = drain2_sel_e2;
`endif
              // port_taken is NOT set here: both of its readers  precede this point,
              // so the write was dead. It also made the drain drive a second driver of a signal the
              // select pass owns, which blocked splitting the two apart.
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

    // Apply the recorded clears, once per entry. Both drive loops have closed, so this sees
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
    // Pop-count form: both pops are decided on the values entering this pass and applied once,
    // instead of two chained read-modify-writes of resp_buf_rd_ptr / resp_buf_cnt / beats_left.
    // "resp_buf_cnt after the head pop != 0"     ==  resp_buf_cnt >= 2
    // "beats_left after the head decrement == 1" ==  beats_left == 2
    // NOT a bandwidth change: pop == 2 is the same two beats, decided in parallel not in series.
    for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      resp_head_beat_pending[mshr_i] = 1'b0;
      resp_cnt_after_pop[mshr_i]     = mshr_d[mshr_i].resp_buf_cnt;
      fin_cache     = 1'b0;
      fin_head      = 1'b0;
      fin_second_en = 1'b0;
      fin_second    = 1'b0;
      fin_retire    = 1'b0;
      fin_pop       = 2'd0;

      if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].resp_buf_cnt != '0) &&
          (mshr_d[mshr_i].state == MSHR_DRAIN_RESP)) begin
        resp_head_beat_pending[mshr_i] = |mshr_d[mshr_i].beat_pending;
        if (!resp_head_beat_pending[mshr_i]) begin
          fin_cache = (mshr_d[mshr_i].beats_left == BurstLenWidth'(1)) &&
                      EnableRespCache && !amo_invalidate &&
                      mshr_d[mshr_i].cacheable &&
                      (mshr_d[mshr_i].burst_len == BurstLenWidth'(1));
          fin_head  = !fin_cache;
        end
      end

      if (fin_cache) begin
        // Keep final drained head response as cache data (do not pop).
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
        mshr_d[mshr_i].hold_cnt = hold_ticks(cfg_cache_hold_ticks_src);
      end else if (fin_head) begin
        // beats_left != 1 is exactly "the head pop does not retire the entry", which is what
        // gated the whole PD2 block on mshr_d_valid after the head write.
        fin_second_en = PD2 && (mshr_d[mshr_i].burst_len != BurstLenWidth'(1)) &&
                        mshr_d[mshr_i].beat2_armed &&
                        (mshr_d[mshr_i].beats_left != BurstLenWidth'(1));
        fin_second    = fin_second_en && (mshr_d[mshr_i].beat_pending2 == '0) &&
                        (mshr_d[mshr_i].resp_buf_cnt >= RespBufCountW'(2));
        fin_pop       = fin_second ? 2'd2 : 2'd1;
        fin_retire    = (mshr_d[mshr_i].beats_left == BurstLenWidth'(1)) ||
                        (fin_second && (mshr_d[mshr_i].beats_left == BurstLenWidth'(2)));

        // rd_ptr advances by the pop count. pop <= 2 and rd_ptr <= RespBufWords-1, so a single
        // conditional subtraction covers the wrap (RespBufWords >= 2 is asserted above).
        if (RespBufWords > 1) begin
          if ((int'(mshr_d[mshr_i].resp_buf_rd_ptr) + int'(fin_pop)) >= int'(RespBufWords)) begin
            mshr_d[mshr_i].resp_buf_rd_ptr = RespBufPtrW'(
                int'(mshr_d[mshr_i].resp_buf_rd_ptr) + int'(fin_pop) - int'(RespBufWords));
          end else begin
            mshr_d[mshr_i].resp_buf_rd_ptr = RespBufPtrW'(
                int'(mshr_d[mshr_i].resp_buf_rd_ptr) + int'(fin_pop));
          end
        end
        resp_cnt_after_pop[mshr_i]  = mshr_d[mshr_i].resp_buf_cnt - RespBufCountW'(fin_pop);
        mshr_d[mshr_i].resp_buf_cnt = resp_cnt_after_pop[mshr_i];
`ifndef TARGET_SYNTHESIS
        mshr_d[mshr_i].beat_done[resp_beat_offset[mshr_i]] = 1'b1;
        if (fin_second) begin
          mshr_d[mshr_i].beat_done[drain2_beat_off[mshr_i]] = 1'b1;
        end
`endif
        // An armed second beat that could not pop is promoted into the head slot.
        mshr_d[mshr_i].beat_pending =
            (fin_second_en && !fin_second) ? mshr_d[mshr_i].beat_pending2 : '0;

        if (fin_retire) begin
          mshr_d_valid[mshr_i] = 1'b0;
          // Retire by dropping valid only (see the first retire site for why). beat_pending2 and
          // `if (mshr_d_valid)`, i.e. never on the retiring path.
        end else begin
          if (mshr_d[mshr_i].beats_left != '0) begin
            mshr_d[mshr_i].beats_left = mshr_d[mshr_i].beats_left - BurstLenWidth'(fin_pop);
          end
          if (resp_cnt_after_pop[mshr_i] != '0) begin
            mshr_d[mshr_i].state = MSHR_DRAIN_RESP;
          end else begin
            mshr_d[mshr_i].state = MSHR_WAIT_RESP;
          end
          if (fin_second_en) begin
            mshr_d[mshr_i].beat_pending2 = '0;
            mshr_d[mshr_i].beat2_armed   = 1'b0;
          end
        end
      end
    end

    // Apply the deferred allocation valid-set. Placed last so the allocation arbiter never enters
    // any clear guard; the two are mutually exclusive by state, so an OR reproduces the in-place
    // form exactly (allocation wins a reclaimed CACHED way, as it did when its write landed first).
    mshr_d_valid = mshr_d_valid | mshr_alloc_set;
  end

  // Simulation-only statistics and probes; no hardware. Guarded HERE as well as inside the file,
  // so synthesis never has to find it at all.
`ifndef TARGET_SYNTHESIS
  `include "mempool/mempool_group_mshr_stats.svh"
`endif

`ifndef TARGET_SYNTHESIS
  // beat_off is stored in BeatOffW bits (0..MaxBurstWords-1), one bit narrower than the
  // BurstLenWidth value it is cast from. That is only sound because burst_beat_valid() has already
  // required beat < burst_len <= MaxBurstWords. If MaxBurstWords, the lane law or the tag scheme
  // ever change, this fires instead of silently aliasing an out-of-range beat onto a valid one.
  for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_beat_off_fits_tile
    for (genvar pp = 1; pp < NumRemoteRespPortsPerTile; pp++) begin : gen_beat_off_fits_port
      beat_off_fits: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          (resp_in_valid[t][pp] && resp_is_mshr[t][pp]) |->
            (resp_capture_beat_offset[t][pp] < BurstLenWidth'(mempool_pkg::MaxBurstWords)))
        else $fatal(1, "MSHR beat_off %0d does not fit BeatOffW (tile %0d port %0d)",
                    resp_capture_beat_offset[t][pp], t, pp);
    end
  end

  // Report a duplicate beat once per cycle, on settled values. See the note at the
  // declaration for why this cannot live inside the always_comb that detects it.
  always_ff @(posedge clk_i) begin
    if (rst_ni && dup_beat_detected)
      $fatal(1, "MSHR duplicate response beat: mshr=%0d beat=%0d meta=%0d",
             dup_beat_mshr, dup_beat_beat, dup_beat_meta);
  end
`endif

  // --------------------------------------------------------------------------------
  // assertions and simulation-only checks. Collected here rather than beside the logic so
  // the synthesised body reads uninterrupted; all are `ifndef TARGET_SYNTHESIS / VERILATOR
  // and declare nothing the design uses.
  // --------------------------------------------------------------------------------
  `ifndef TARGET_SYNTHESIS

  `ifndef TARGET_SYNTHESIS
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
  `endif

  `ifndef TARGET_SYNTHESIS
  `ifndef VERILATOR
  // Bank-scoped hit detection relies on a valid entry's (address,group) always hashing to its
  // own bank. Allocation enforces this (bank_free_id[req_bank] only returns ways of that bank), so
  // if this ever fails a request could miss a real hit and allocate a duplicate. Catch any
  // violation early.
  generate
    // Interlock firing counters. Distinguishes "the interlocks over-block" from "the extra cycle
    // of entry-visibility latency costs throughput" -- the two have the same symptom in cycles.
    logic [31:0] cut_addr_stall_dbg, cut_owner_stall_dbg, cut_alloc_dbg, cut_bench_cyc_dbg;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        cut_addr_stall_dbg  <= '0;
        cut_owner_stall_dbg <= '0;
        cut_alloc_dbg       <= '0;
        cut_bench_cyc_dbg   <= '0;
      end else begin
        cut_addr_stall_dbg  <= cut_addr_stall_dbg  + 32'($countones(req_fwd_hit));
        cut_owner_stall_dbg <= cut_owner_stall_dbg + 32'($countones(req_owner_inflight));
        cut_alloc_dbg       <= cut_alloc_dbg       + 32'($countones(agb_v));
        cut_bench_cyc_dbg   <= cut_bench_cyc_dbg   + 32'd1;
      end
    end
    final $display("[CUTSTALL] fwd_hits=%0d owner_stalls=%0d allocations=%0d cycles=%0d",
                   cut_addr_stall_dbg, cut_owner_stall_dbg, cut_alloc_dbg, cut_bench_cyc_dbg);

    // ------------------------------------------------------------
    // pipeline-cut invariants.
    // Every other per-entry assertion here checks ONE entry against ITSELF, so a write dropped by
    // a closed clock gate leaves the previous occupant's self-consistent snapshot and all of them
    // pass. These check the cut itself: that a decision in flight lands, lands once, and is not
    // overtaken. Simulation only.
    // ------------------------------------------------------------
    for (genvar e = 0; e < MshrNum; e++) begin : gen_mshr_cut_invariant
      cut_alloc_ctl_gated: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !alloc_inflight[e] || mshr_ctl_en[e])
        else $fatal(1, "MSHR entry %0d: allocation applied with the control clock gate off", e);

      cut_alloc_target_free: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !alloc_inflight[e] || !mshr_q_valid[e] || (mshr_q[e].state == MSHR_CACHED))
        else $fatal(1, "MSHR entry %0d: allocated over a live non-CACHED entry (state=%0d)",
                    e, mshr_q[e].state);

      cut_merge_not_retired: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !merge_inflight[e] || mshr_d_valid[e])
        else $fatal(1, "MSHR entry %0d: retired with a merge in flight -- subscriber lost", e);

      // The capture must see the merge that is being applied this cycle, not the pre-merge count.
      cut_cap_sees_merge: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !(st_cap_fire[e] && merge_inflight[e]) ||
          (mshr_d[e].sub_reqs_num == SubReqCountW'(mshr_q[e].sub_reqs_num + 1)))
        else $fatal(1, "MSHR entry %0d: capture read a pre-merge sub_reqs_num (d=%0d q=%0d)",
                    e, mshr_d[e].sub_reqs_num, mshr_q[e].sub_reqs_num);

      // no_late_join_burst samples the DECISION cycle; the merge lands one cycle later, so the
      // property has to be restated where the write actually happens.
      cut_merge_apply_no_late_join: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !(merge_inflight[e] && (mshr_q[e].burst_len > BurstLenWidth'(1))) ||
          ((mshr_q[e].state == MSHR_WAIT_RESP) &&
           (mshr_q[e].beats_left == mshr_q[e].burst_len)))
        else $fatal(1, "MSHR late join at apply: entry=%0d state=%0d left=%0d",
                    e, mshr_q[e].state, mshr_q[e].beats_left);
    end

    for (genvar b = 0; b < MshrBankNum; b++) begin : gen_mshr_cut_bank_invariant
      cut_no_double_grant: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !(agb_v[b] && agb_q_v[b] && (agb_way[b] == agb_q_way[b])))
        else $fatal(1, "MSHR bank %0d: re-granted way %0d across the cut", b, agb_way[b]);
    end

    cut_busy_covers_inflight: assert property(
      @(posedge clk_i) disable iff (!rst_ni)
        !((|agb_q_v) || (|mgb_q_v)) || mshr_busy_o)
      else $fatal(1, "MSHR busy_o low with a decision in flight -- bank-hash CSR could change");

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
  `endif
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

      // Load-bearing invariant for EnableMshrSingleReq + EnableRespCache: a live
      // CACHED entry must always hold its buffered response (resp_buf_cnt > 0, so
      // resp_valid == 1). This is what makes a single-word load to a cached
      // address ALWAYS take the merge/hit path (req_hit_mshr) and never
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

    // A tile can never have a third outstanding bypassed multi-beat burst
    // (VLSU one-instruction serialization x <=2 bursts/instruction).
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

    // ParityDrain retag-range invariant: every burst entry's subscribers must carry
    // core_id == 1 (the VLSU burst base port), so the +(b&1) retag lands on exactly {1,2}. A
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
            // A FORWARDED merge targets an entry allocated this cycle, so mshr_q still holds the
            // previous occupant. req_fwd_hit already requires agb_q_len == req_len, and
            // cut_merge_apply_no_late_join re-proves the property at the apply cycle.
            !(req_in_valid[tile_i][port_i] &&
              req_in_ready[tile_i][port_i] &&
              req_merge_valid[tile_i][port_i] &&
              req_hit_mshr_sel_valid[tile_i][port_i] &&
              !req_fwd_hit[tile_i][port_i] &&
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
  `endif

  // The gate must never swallow a write.
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

endmodule : mempool_group_mshr
