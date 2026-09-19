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
  // Overflow pool: entries that belong to NO bank, allocated only when a request's hash-mapped bank
  // has no free way. They break a per-bank circular wait -- a cohort holding every way of one bank
  // while the request that would complete it hashes to that same bank and cannot allocate, so the
  // cohort only ever ends at the serve timeout.
  //
  // The pool is addressed OUT OF BAND rather than by extending the entry table, because the flat id
  // space cannot grow here: BankPublish asserts idx_width(MshrNum) == BankIdW + VictimPtrW (6 == 4+2
  // at 64/4) and mshr_id_t is exactly idx_width(MshrNum) wide, so one more entry would both break
  // that identity and truncate in the response path. Pool indices are separate from banked ids;
  // NoC tags MshrNum+1 .. MshrNum+MshrOverflowNum use the existing tag field's spare values.
  //
  // 0 removes the pool entirely: every pool structure is generate-guarded, so the netlist is
  // identical to the design without it.
  parameter int MshrOverflowNum = `ifdef GROUP_MSHR_OVERFLOW_NUM `GROUP_MSHR_OVERFLOW_NUM `else 1 `endif,
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
  if (MshrMergeReqs & (MshrMergeReqs - 1))
    $error("[mempool_group_mshr] group_mshr_merge_reqs (%0d) must be a power of two.", MshrMergeReqs);
  // Ways need not be a power of two: every bank/way split and every ways-axis wrap is guarded by
  // WaysPow2. The BANK count must be, because the bank hash selects a BankIdW-wide field and every
  // code that field can produce has to name a real bank.
  if ((MshrNum / MshrWaysPerBank) & ((MshrNum / MshrWaysPerBank) - 1))
    $error("[mempool_group_mshr] banks (%0d = group_mshr_num %0d / ways %0d) must be a power of two.",
           MshrNum / MshrWaysPerBank, MshrNum, MshrWaysPerBank);
  if (MshrNum % MshrWaysPerBank)
    $error("[mempool_group_mshr] group_mshr_num (%0d) must be a multiple of ways (%0d).",
           MshrNum, MshrWaysPerBank);
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
  // Response-cache coherence against incoming stores/AMOs. Both default OFF: on the target GEMM
  // workload neither ever fires (measured store_update = 0 and amo_inval = 0 against 67,882 cache
  // hits, the cache retiring entirely through self-invalidate), while between them they carry the
  // store byte-merge into resp_buf.data and the only request-fed writer of mshr_d_valid.
  // With a knob off, the corresponding assertion below makes the "never fires" property CHECKED
  // rather than assumed -- a store or AMO landing on a cached line would otherwise read stale data
  // silently. Turn a knob on for any workload that does not hold that property.
  localparam bit CacheStoreUpdate = `ifdef GROUP_MSHR_CACHE_STORE_UPDATE `GROUP_MSHR_CACHE_STORE_UPDATE `else 1'b0 `endif;
  localparam bit CacheAmoInval    = `ifdef GROUP_MSHR_CACHE_AMO_INVAL `GROUP_MSHR_CACHE_AMO_INVAL `else 1'b0 `endif;
  // Store force-drain: the third store-coherence mechanism, guarding the HOLD window rather than
  // the cache. RespWaitSubsSingle parks a returned single-word response in MSHR_RESP_HOLD hoping
  // more readers join; a store to that address goes to memory and leaves the held copy stale, so
  // this flushes the entry and clears cacheable before anyone can merge into it.
  // OFF by default for the same reason as its two siblings: it can only fire when a store hits an
  // address the MSHR is holding a load response for, which a read-only-A/B, write-only-C GEMM
  // never does. The assertion below fails the run if that assumption ever breaks.
  localparam bit StoreForceDrain  = `ifdef GROUP_MSHR_STORE_FORCE_DRAIN `GROUP_MSHR_STORE_FORCE_DRAIN `else 1'b0 `endif;
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
  // Entry id e = bank * MshrWaysPerBank + way. When ways is a power of two that split is a bit
  // slice and a truncating add is already mod-ways; when it is not, both need real arithmetic.
  // The flag is elaboration-constant, so a power-of-two ways elaborates exactly the old logic.
  localparam bit WaysPow2 = ((MshrWaysPerBank & (MshrWaysPerBank - 1)) == 0);
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
  // key_burst / key_single are the two forms addr_key selects between. Mode 3 hashes each with the
  // shift that applies to it, so the barrel selects do not wait on the key mux; every other mode
  // takes the already-muxed addr_key. Callers holding a registered key pass it for all three.
  function automatic logic [BankIdW-1:0] mshr_bank_of(input tcdm_addr_t addr_key,
                                                      input tcdm_addr_t key_burst,
                                                      input tcdm_addr_t key_single,
                                                      input group_id_t grp,
                                                      input logic is_single,
                                                      input logic [mempool_pkg::MshrCfgShiftW-1:0] sh_single,
                                                      input logic [mempool_pkg::MshrCfgShiftW-1:0] sh_burst,
                                                      input logic [mempool_pkg::MshrCfgBurstBitsW-1:0] burst_bits);
    logic [BankIdW-1:0]              b;
    logic [$bits(tcdm_addr_t)-1:0]   mix;
    logic [WordAddrW-1:0]            word_addr;
    logic [WordAddrW-1:0]            word_addr_burst, word_addr_single;
    b = BankIdW'(grp);
    if (BankHash == 3) begin
      // Field-select on the reconstructed LINEAR word address (pure re-wiring: put the group field
      // back above the tile field).
      word_addr_burst  = { key_burst[$bits(tcdm_addr_t)-1 : TileIdBits + BankInTileW],
                           grp[GroupBits-1:0],
                           key_burst[TileIdBits-1:0],
                           key_burst[TileIdBits +: BankInTileW] };
      word_addr_single = { key_single[$bits(tcdm_addr_t)-1 : TileIdBits + BankInTileW],
                           grp[GroupBits-1:0],
                           key_single[TileIdBits-1:0],
                           key_single[TileIdBits +: BankInTileW] };
      if (is_single) begin
        b = word_addr_single[sh_single +: BankIdW];
      end else if (!burst_bits) begin
        b = word_addr_burst[sh_burst +: BankIdW];
      end else begin
        // ONE intra-load bit: the high BankIdW-1 bits from the p-slice gap at sh_burst, plus the
        // bit just above the burst boundary.
        b = { word_addr_burst[sh_burst +: BankIdW - 1],
              word_addr_burst[BurstAlignBits +: 1] };
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
`ifndef TARGET_SYNTHESIS

  // Entries the two gates above admit but mshr_d_valid does not; checked below.
  logic                [MshrNum-1:0]                                           gate_extra;
`endif
  logic                [MshrNum-1:0]                                           mshr_q_valid;

  // ---------------------------------------------------------------------------------------------
  // OVERFLOW POOL state.
  //
  // A pool entry is a NORMAL entry: same struct, same lifecycle, same hold window, same response
  // cache, both request classes, same merge capacity. Only its ADDRESSING differs -- it has no
  // bank, so it joins none of the per-bank narrowings (BankPublish, Drain2BankPublish, CapPerBank)
  // and needs an explicit arm in every pass that walks the banked table. A pass that is missed does
  // not fail to compile: the entry is simply allocated and then never served.
  //
  // PoolArr is the ARRAY bound, PoolNum the generated size. SystemVerilog has no zero-element
  // array, so at MshrOverflowNum = 0 the arrays are declared one deep and every pool generate block
  // is skipped; nothing drives or reads them and synthesis deletes them.
  // ---------------------------------------------------------------------------------------------
  localparam int unsigned PoolNum  = (MshrOverflowNum > 0) ? MshrOverflowNum : 0;
  localparam int unsigned PoolArr  = (PoolNum > 0) ? PoolNum : 1;
  localparam int unsigned PoolIdxW = idx_width(PoolArr);
  if ((MshrOverflowNum < 0) ||
      ((64'(MshrNum) + 64'(PoolNum)) >= (64'b1 << MshrTagWidth)))
    $error("[mempool_group_mshr] banked and pool entries exceed the nonzero NoC tag range.");
  mempool_group_mshr_t [PoolArr-1:0]                                           pool_d;
  mempool_group_mshr_t [PoolArr-1:0]                                           pool_q;
  logic                [PoolArr-1:0]                                           pool_d_valid;
  logic                [PoolArr-1:0]                                           pool_q_valid;
  // Clock-gate write flags, raised at the pool write sites exactly as the banked ones are.
  logic                [PoolArr-1:0]                                           pool_wr_all;
  logic                [PoolArr-1:0]                                           pool_id_we;
  logic                [PoolArr-1:0][RespBufWords-1:0]                         pool_rb_we;
  // Merge slot for the pool write, the twin of mgb_slot.
  logic                [MergeRankW-1:0]                                       pmb_slot;
  /// Deferred valid-set for pool entries, the twin of mshr_alloc_set: recorded at the allocation
  /// apply and summed into pool_d_valid once at the end of the pass.
  logic                [PoolArr-1:0]                                          pool_alloc_set;
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
`ifndef TARGET_SYNTHESIS
  /// An accepted AMO whose merge key and target group match entry e. The address test is the one
  /// req_addr_hit_way uses (base_addr is the entry's key), and acceptance matters because a
  /// stalled request never reaches the cache.
  logic [MshrNum-1:0] amo_hits_entry;
  always_comb begin
    amo_hits_entry = '0;
    for (int ah = 0; ah < MshrNum; ah++) begin
      for (int at = 0; at < NumTilesPerGroup; at++) begin
        for (int ap = 1; ap < NumRemoteReqPortsPerTile; ap++) begin
          if (req_in_valid[at][ap] && req_in_ready[at][ap] &&
              (req_in[at][ap].wdata.amo != '0) &&
              (req_in[at][ap].tgt_group_id == mshr_q[ah].tgt_group_id) &&
              (req_addr_key[at][ap] == mshr_q[ah].base_addr)) begin
            amo_hits_entry[ah] = 1'b1;
          end
        end
      end
    end
  end
`endif
  tcdm_addr_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_addr_key_burst;
  /// The bank hash of each class, so the decode runs before req_is_single selects rather than
  /// after it.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][BankIdW-1:0] req_bank_s, req_bank_b;
`ifndef TARGET_SYNTHESIS
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][BankIdW-1:0]      req_bank_ref;
`endif
  tcdm_addr_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_addr_key_single;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][BankIdW-1:0] req_bank;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]
             [TileIdBits-1:0]                                                 req_tile_id;
  // tcdm_addr_t, matching the decode's port type. A narrower element width does not truncate each
  // element -- a port connection truncates the flattened array, which stitches every lane after the
  // first out of its neighbours' address bits.
  tcdm_addr_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_tile_addr;
  tcdm_addr_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_tile_addr_key;
  // Bank-scoped hit detection: each request compares its address against only the
  // MshrWaysPerBank entries of its own bank (req_bank), not all MshrNum.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_addr_hit_way;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_addr_hit_drain_way;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_hit_way;
  // Merge capacity for this way, evaluated where the entry index is still the EARLY req_bank.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_hit_cap_way;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_hit_retire_way;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_addr_hit_drain;
  /// This request's line is being allocated right now -- recorded in agb_q_*, not yet in mshr_q.
  /// req_addr_hit_way reads the way's OLD key and would miss, so without forwarding the request
  /// either allocates a duplicate (wrong) or waits a cycle. Forward instead: the target entry id
  /// is b*MshrWaysPerBank + agb_q_way[b], so the follower merges into the leader's entry at once.
  /// b*WaysPerBank + agb_q_way[b], so the follower merges into the leader's entry immediately.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_fwd_hit;
  // Bank one-hot, decoded once per lane. req_bank is late; everything it used to SELECT is
  // register-fed, so comparing per bank and selecting one result bit is shallower than selecting
  // an operand and comparing afterwards.
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrBankNum-1:0] req_bank_oh;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrBankNum-1:0] req_fwd_eq;
  // The address/group key compared against EVERY bank's way-w entry, off operands that are ready
  // before req_bank. req_bank then selects one bit instead of selecting the entry and comparing.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0][MshrBankNum-1:0] req_key_eq;
  // e_abs at module scope rather than inside the generate: a declaration in a generate block gets
  // a hierarchical name that wave scripts and assertions cannot follow.
  mshr_id_t [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_e_abs;
  // The pre-rewrite form, kept ONLY so an assertion can prove the two agree every cycle. Nothing
  // synthesised reads it, so it disappears from the netlist.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrWaysPerBank-1:0] req_addr_hit_way_old;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][VictimPtrW-1:0]  req_fwd_way;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_fwd_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr_sel_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr_sel_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_cap_sel;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_retire_sel;
  /// Entries whose retire conditions already hold on registers alone. Register-only by
  /// construction: it is what lets the retire sites drop the combinational merge veto.
  logic      [MshrNum-1:0]                                                     retire_eligible;
  logic      [MshrNum-1:0]                                                     mshr_hit_req;
  /// Per-entry, per-lane hit terms feeding mshr_hit_req. Only generated at CacheReclaimable=1.
  logic [MshrNum-1:0][NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]      mshr_hit_req_lane;

  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_ready;
  // Prefix rank of same-target merging ports.
  logic                                                                                           amo_invalidate;
  /// AMO invalidation is a CacheAmoInval behaviour, so every guard that exists to keep a line out
  /// of the cache while an AMO is in flight belongs under that knob. With it off this folds to 0,
  /// which takes |req_is_amo -- and with it the request path -- off the finalize;
  /// cache_amo_never_hits then checks the property that actually matters, that no ACCEPTED AMO
  /// reaches the address of a cached line.
  logic                                                                                           amo_inval_guard;

  // Request allocation (banked allocator bookkeeping).
  logic    [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found;
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found_mshr_id;
  // Per-bank single-allocation-per-cycle scheme: req_alloc_cand marks a request that
  // wants a new entry: a mergeable load that missed, with no same-address drain hazard.
  logic    [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_cand;
  logic    [MshrBankNum-1:0]                                                   bank_has_free;
  mshr_id_t[MshrBankNum-1:0]                                                   bank_free_id;
  // RR victim start pointer per bank (CacheVictimRR); consumed by the pass-2 reclaim scan,
  // advanced only on a reclaim fire. Tied 0 / unread when CacheVictimRR=0 (const-folds out).
  logic    [MshrBankNum-1:0][VictimPtrW-1:0]                                   victim_rr_q, victim_rr_d;

  // Response drain scheduling (per response port).
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel_mshr_id;
  /// Pool drain selection, kept on its own axis: a pool entry has no bank, so resp_sel_mshr_id
  /// cannot name it. Banked and pool selections are mutually exclusive per lane, with the banked
  /// one taking priority.
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel_pool_valid;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][PoolIdxW-1:0] resp_sel_pool_id;

  // ---- POOL request-side declarations ----------------------------------------------------
  // Declared HERE, before first use. These are consumed by the banked hit reductions, the winner
  // select, the allocation candidacy and the pool arbiters, all of which appear further down;
  // SystemVerilog requires declaration before use and a forward reference fails analysis.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][PoolArr-1:0] pool_addr_hit_way;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][PoolArr-1:0] pool_hit_way;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][PoolArr-1:0] pool_addr_hit_drain_way;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][PoolArr-1:0] pool_cap_way;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_pool;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_addr_hit_drain_pool;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_fwd_pool_hit;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][PoolIdxW-1:0] req_fwd_pool_id;
  /// The selected pool merge target. Kept separate from req_hit_mshr_sel_id because that is
  /// mshr_id_t -- idx_width(MshrNum), 6 bits at 64 -- and a pool index does not fit in it. Two
  /// signals also keep the banked select's timing cone untouched.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_pool_sel_valid;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][PoolIdxW-1:0] req_hit_pool_sel_id;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_pool_cap_sel;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_pool_retire_sel;
  logic [PoolArr-1:0] pool_retire_eligible;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_merge_pool_valid;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_merge_pool_ready;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_alloc_found_pool;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][PoolIdxW-1:0] req_alloc_found_pool_id;
  // Combinational pool grant records (the _q forms are declared with the staged records).
  logic                                      apb_v;
  /// Load enable for the staged allocation payload. Every winner is a candidate, so this is a
  /// superset of apb_v, and it is safe because every read of the apb_q payload fields is qualified
  /// by apb_q_v, which stays exact: a capture in a cycle without a grant is never read. It keeps
  /// the round-robin pick over all request lanes off the payload clock-gate enable.
  logic                                      apb_en;
  logic [PoolIdxW-1:0]                       apb_way;
  tcdm_addr_t                                apb_addr;
  group_id_t                                 apb_grp;
  logic [BurstLenWidth-1:0]                  apb_len;
  tile_group_id_t                            apb_tile;
  logic [RespPortIdW-1:0]                    apb_port;
  tile_core_id_t                             apb_core;
  meta_id_t                                  apb_meta;
  logic                                      mpb_v;
  logic [PoolIdxW-1:0]                       mpb_way;
  tile_group_id_t                            mpb_tile;
  logic [RespPortIdW-1:0]                    mpb_port;
  tile_core_id_t                             mpb_core;
  meta_id_t                                  mpb_meta;
  logic [PoolArr-1:0]                        pool_cand;
  logic [PoolArr-1:0]                        pool_first;
  logic                                      pool_first_any;
  logic [PoolArr-1:0][MshrMergeReqs-1:0]     pool_sub_cand_map;
  logic [PoolIdxW-1:0]                       pool_win;
  logic [MshrMergeReqs-1:0]                  pool_sub_cand, pool_sub_first;
  // Sized by idx_width directly rather than by SubIdxW: SubIdxW is a localparam declared further
  // down this module, and a forward reference to it here fails analysis.
  logic [idx_width(MshrMergeReqs)-1:0]       pool_win_s;
  logic                                      pool_have_s;
  /// Pool equivalents of bp_clr / sv_clr, and the clear apply's operands.
  /// There is deliberately NO pool2_clr: the ParityDrain second slot is armed only by the banked
  /// loop (the one that sets beat2_armed), and a pool entry has no arming site, so pool entries run
  /// with PD2 effectively OFF -- one beat per cycle. That is correct, and half the drain bandwidth
  /// the banked table gets. wiring a pool second slot needs both an arming site and a drain2 arm; it
  /// is not required for correctness, only for pool drain throughput.
  logic [PoolArr-1:0][MshrMergeReqs-1:0]     pool_bp_clr, pool_sv_clr;
  logic [PoolArr-1:0]                        pool_resp_head_beat_pending;
  logic [PoolArr-1:0][RespBufCountW-1:0]     pool_resp_cnt_after_pop;
  /// POOL replay operands, the twins of the hold-the-fetch walker's. Required, not optional: a
  /// pool entry is allocated with the SAME hold window as a banked one, so its NoC fetch is
  /// withheld at allocation and only this walker can issue it. Without it the entry would never
  /// fetch and would time out with certainty.
  logic [PoolArr-1:0]                        pool_replay_scan_valid;
  mempool_group_mshr_t [PoolArr-1:0]         pool_replay_scan_ent;
  logic [PoolArr-1:0]                        pool_replay_ready;
  logic [PoolArr-1:0]                        pool_replay_issue;
  tile_group_id_t [PoolArr-1:0]              pool_replay_own_t;
  logic [PoolArr-1:0][RespPortIdW-1:0]       pool_replay_own_p;
  logic [PoolIdxW-1:0]                       pool_replay_win;
  logic                                      pool_replay_any;
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

  /// POOL staged records, the same cut on the same cycle boundary. One record rather than one per
  /// bank: the pool has its own allocation and merge port and grants at most one of each per cycle,
  /// so a bank-full miss never contends for the bank's slot as well.
  logic                                      apb_q_v;
  logic [PoolIdxW-1:0]                       apb_q_way;
  tcdm_addr_t                                apb_q_addr;
  group_id_t                                 apb_q_grp;
  logic [BurstLenWidth-1:0]                  apb_q_len;
  tile_group_id_t                            apb_q_tile;
  logic [RespPortIdW-1:0]                    apb_q_port;
  tile_core_id_t                             apb_q_core;
  meta_id_t                                  apb_q_meta;
  logic                                      mpb_q_v;
  logic [PoolIdxW-1:0]                       mpb_q_way;
  tile_group_id_t                            mpb_q_tile;
  logic [RespPortIdW-1:0]                    mpb_q_port;
  tile_core_id_t                             mpb_q_core;
  meta_id_t                                  mpb_q_meta;
  /// Per-pool-entry views of those records -- the twins of alloc_inflight / merge_inflight. The way
  /// index is a loop constant per entry here too, so each is one compare against a register.
  logic [PoolArr-1:0]                        pool_alloc_inflight;
  logic [PoolArr-1:0]                        pool_merge_inflight;
  /// Twin of st_merge_drain for the pool: a merge recorded against a pool entry this cycle. Declared
  /// HERE, before the gen_pool_fire that drives it -- SystemVerilog requires declaration before use.
  logic [PoolArr-1:0]                        pool_st_merge_drain;
  /// pool_q_valid as the free-entry lookup must see it: an in-flight allocation already owns it.
  logic [PoolArr-1:0]                        pool_free_valid;

  /// Per-pool-entry views of the staged records. The pool way is a loop constant per entry, exactly
  /// as bank and way are for a banked entry, so each is one compare against a register and no
  /// variable index reaches the entry write.
  generate
    if (PoolNum > 0) begin : gen_pool_fire
      for (genvar p = 0; p < PoolNum; p++) begin : gen_pool_fire_p
        assign pool_alloc_inflight[p] = apb_q_v && (apb_q_way == PoolIdxW'(p));
        assign pool_merge_inflight[p] = mpb_q_v && (mpb_q_way == PoolIdxW'(p));
        assign pool_free_valid[p]     = pool_q_valid[p] | pool_alloc_inflight[p];
        // The twin of st_merge_drain: a merge landing on a CACHED or RESP_HOLD pool entry turns it
        // into a drain, which is the one condition the cache-retire sites must veto.
        assign pool_st_merge_drain[p] = pool_merge_inflight[p] &&
                                        ((EnableRespCache &&
                                          (pool_q[p].state == MSHR_CACHED)) ||
                                         (RespWaitSubsSingle &&
                                          (pool_q[p].state == MSHR_RESP_HOLD) &&
                                          ((MergeRankW'(pool_q[p].sub_reqs_num) +
                                            MergeRankW'(1)) >=
                                           SubReqCountW'(cfg_hold_subs_single))));
      end
    end else begin : gen_pool_fire_tie
      assign pool_alloc_inflight = '0;
      assign pool_merge_inflight = '0;
      assign pool_st_merge_drain = '0;
      assign pool_free_valid     = '0;
    end
  endgenerate

  /// Free POOL entry: the lowest invalid one, the same invalid-first isolate that
  /// mempool_group_mshr_free_way pass 1 runs per bank. There is deliberately NO reclaim pass here.
  /// A CACHED pool entry is reachable by every bank's requests, so evicting one to serve a
  /// bank-full miss would trade a live shared line for the very entry the miss is escaping to.
  logic                 pool_has_free;
  logic [PoolIdxW-1:0]  pool_free_id;
  logic [PoolArr-1:0]   pool_free_oh;
  generate
    if (PoolNum > 0) begin : gen_pool_free
      logic [PoolArr-1:0] pool_invalid;
      for (genvar p = 0; p < PoolNum; p++) begin : gen_pool_invalid
        assign pool_invalid[p] = ~pool_free_valid[p];
      end
      assign pool_free_oh  = pool_invalid & (~pool_invalid + PoolArr'(1));
      assign pool_has_free = |pool_invalid;
      /// One-hot to binary, the free_way idiom: bit k is the OR of the one-hot positions whose own
      /// binary value has bit k set. (p >> k) & 1 is a genvar expression, so each term is either the
      /// one-hot bit or a constant 0 -- a fixed OR, not a mux.
      for (genvar k = 0; k < PoolIdxW; k++) begin : gen_pool_free_id_k
        logic [PoolArr-1:0] pool_free_masked;
        for (genvar p = 0; p < PoolNum; p++) begin : gen_pool_free_id_p
          assign pool_free_masked[p] = ((p >> k) & 1) ? pool_free_oh[p] : 1'b0;
        end
        assign pool_free_id[k] = |pool_free_masked;
      end
    end else begin : gen_pool_free_tie
      assign pool_has_free = 1'b0;
      assign pool_free_id  = '0;
      assign pool_free_oh  = '0;
    end
  endgenerate

  /// Per-entry views of the two in-flight records: "a write for this entry is registered but has
  /// not reached mshr_q yet". Bank and way are compile-time constants per entry, so each is one
  /// compare against a register -- no variable index, nothing from the request path.
  logic [MshrNum-1:0] alloc_inflight;
  logic [MshrNum-1:0] merge_inflight;
  /// mshr_q_valid as the free-way lookup must see it: an in-flight allocation already owns its way.
  logic [MshrNum-1:0] free_way_valid;

  // Busy must also cover a decision that is recorded but not yet in mshr_q, or the bank-hash CSR
  // could be rewritten in that window.
  // Pool occupancy counts too: the CSR refuses a bank-hash change while busy is high, and a resident
  // pool entry was keyed under the OLD hash exactly like a banked one.
  assign mshr_busy_o = (|mshr_q_valid) | (|agb_q_v) | (|mgb_q_v) |
                       (|pool_q_valid) | apb_q_v | mpb_q_v;

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
  /// Per-lane view of the capture target: the bank it wants and the way inside that bank. A lane
  /// targets exactly one entry, so intersecting a granted lane with a way is a way compare -- the
  /// 64x32 cap_want array was only ever reduced back to these two facts.
  logic [MshrBankNum-1:0][NumRespLanes-1:0]                                    capb_want_l;
  /// Lanes whose target way is w. capb_l* is already masked to the bank, so intersecting with a
  /// way column names the same lane the row lookup did.
  logic [MshrWaysPerBank-1:0][NumRespLanes-1:0]                                cap_way_col;
  /// Two-lowest-lane reduction for the capture arbiter. The isolate named the winning lane and a
  /// 32-wide AND-OR then recovered its way and credit; the tree carries way and credit WITH the
  /// winner, so the recovery disappears. Node n of stage st merges nodes 2n and 2n+1; the left
  /// half holds the lower lane indices, so it wins both slots it can fill.
  localparam int unsigned CapStages = $clog2(NumRespLanes);
`ifndef TARGET_SYNTHESIS
  /// The isolate-and-recover form the tree replaces, kept only so the run proves them identical.
  logic [MshrBankNum-1:0][MshrWaysPerBank-1:0] capb_l1_way_ref, capb_l2_way_ref;
  logic [MshrBankNum-1:0]                      capb_g1_ref, capb_g2_ref, capb_same_ref;
`endif
  logic [NumRespLanes-1:0]                                                     cap_lane_ge1, cap_lane_ge2;
  logic [NumRespLanes-1:0][VictimPtrW-1:0]                                     cap_lane_way;
  logic [MshrBankNum-1:0][CapStages:0][NumRespLanes-1:0]                       capt_v1, capt_v2, capt_a1, capt_a2, capt_b1;
  logic [MshrBankNum-1:0][CapStages:0][NumRespLanes-1:0][VictimPtrW-1:0]       capt_w1, capt_w2;
  logic [MshrNum-1:0][NumRespLanes-1:0]                                        cap_first, cap_second;
  logic [NumRespLanes-1:0]                                                     cap_rest;
  logic [MshrNum-1:0]                                                          cap_g1, cap_g2;
  // Per-bank capture arbitration (CapPerBank).
  logic [MshrBankNum-1:0][NumRespLanes-1:0]                                    capb_want;
  logic [MshrBankNum-1:0][NumRespLanes-1:0]                                    capb_l1, capb_l2;
  logic [NumRespLanes-1:0]                                                     capb_rest;
  // Which WAY of the bank each grant landed on, and that way's slot headroom. Keeping the winner
  // as a one-hot over MshrWaysPerBank instead of an entry id removes the 32-deep last-writer chain
  // that encoded it, the MshrNum:1 reads of mshr_resp_slots, and the MshrNum-wide scatter back.
  logic [MshrBankNum-1:0][MshrWaysPerBank-1:0]                                 capb_l1_way, capb_l2_way;
  logic [MshrBankNum-1:0][MshrWaysPerBank-1:0]                                 capb_slot_ge1, capb_slot_ge2;
  logic [MshrBankNum-1:0]                                                      capb_g1, capb_g2;
  logic [MshrBankNum-1:0]                                                      capb_same;
  // Per-entry masks of what the two drain DRIVE loops want cleared. Both loops only ever
  // clear BITS, and bit clears commute -- so ORing the requests and applying one AND-NOT per entry
  // is identical to letting 32 lanes each read-modify-write the entry in turn.
  logic [MshrNum-1:0][MshrMergeReqs-1:0]                                       bp_clr, bp2_clr, sv_clr;
  /// Per-lane drain handshake, recorded on the axes the decision was made on. The entry a lane
  /// serves is its bank's published row, so membership is drain_published and a compare against the
  /// entry's constant bank -- neither waits for that row's id to be recovered from the winning bank.
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]                    drain_fire;
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]                    drain_fire_sv;
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][MshrMergeReqs-1:0] drain_fire_sub_oh;
  /// The banked-only twins of the three records above, read by the banked clear scatter.
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]                    drain_fire_bank;
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]                    drain_fire_bank_sv;
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][MshrMergeReqs-1:0] drain_fire_bank_sub_oh;
`ifndef TARGET_SYNTHESIS
  /// The pool-qualified scatter the banked-only form replaces, kept so the run proves them identical.
  logic [MshrNum-1:0][MshrMergeReqs-1:0]                                         bp_clr_ref, sv_clr_ref;
`endif
  // Store byte-merge into CACHED lines, decided per entry instead of chained across lanes.
  localparam int unsigned NumReqPortsActiveF3 = (NumRemoteReqPortsPerTile > 1) ?
                                                (NumRemoteReqPortsPerTile - 1) : 1;
  localparam int unsigned NumReqLanes         = NumTilesPerGroup * NumReqPortsActiveF3;
  localparam int unsigned StrbW               = $bits(strb_t);
  logic [MshrNum-1:0][NumReqLanes-1:0]                                         stb_hit;
  // Entry-side half of the store byte-merge hit, reduced per entry so a lane selects one bit
  // instead of muxing valid / alloc_inflight / state and comparing afterwards.
  logic [MshrNum-1:0]                                                          stb_ent_ok;
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
  logic [PoolArr-1:0][NumReqLanes-1:0]                  pool_stb_hit;
  logic [PoolArr-1:0][StrbW-1:0][NumReqLanes-1:0]      pool_stb_byte_req, pool_stb_byte_win;
  logic [PoolArr-1:0][StrbW-1:0][7:0]                  pool_stb_byte_data;
  logic [PoolArr-1:0][StrbW-1:0]                       pool_stb_bytes;
  logic [PoolArr-1:0][NumReqLanes-1:0]                  pool_sfd_hit;
  mshr_resp_slot_t [MshrNum-1:0]                                               cap_d0, cap_d1;
  logic [RespBufPtrW-1:0]                                                      cap_s0, cap_s1, cap_n0, cap_n1;
  logic      [RespBufCountW-1:0]                                               cap_cnt_sum;
  /// "resp_buf_cnt after the capture" as predicates rather than as a value, so a guard that only
  /// needs != 0 or >= 2 does not wait for the 3-bit add and the saturate. The count's only earlier
  /// writers are the allocation's whole-entry blank and that sum.
  logic      [MshrNum-1:0]                                                     cap_cnt_nz;
  logic      [MshrNum-1:0]                                                     cap_cnt_ge2;
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
  /// The same admission credit for pool entries. Identical expression on pool_q, because a pool
  /// entry buffers responses exactly as a banked one does.
  logic [PoolArr-1:0][RespBufCountW-1:0] pool_resp_slots;
  generate
    if (PoolNum > 0) begin : gen_pool_resp_slots
      for (genvar p = 0; p < PoolNum; p++) begin : gen_pool_resp_slots_p
        assign pool_resp_slots[p] =
            (pool_q_valid[p] && (pool_q[p].resp_buf_cnt < RespBufWords))
              ? (RespBufCountW'(RespBufWords) - pool_q[p].resp_buf_cnt) : '0;
      end
    end else begin : gen_pool_resp_slots_tie
      assign pool_resp_slots = '0;
    end
  endgenerate
  // ---------------------------------------------------------------------------------------------
  // POOL capture operands.
  //
  // The pool has no bank, so it cannot use the per-bank capture arbiter (CapPerBank) or its
  // two-lowest-lane tree -- there is no bank axis to arbitrate over. It uses the SAME shape as the
  // non-banked fallback: one two-lane grant per entry, computed directly from that entry's want
  // vector. At K=1 this is one grant against the banked version's MshrBankNum, so the cost is small
  // and bounded by the pool size.
  // ---------------------------------------------------------------------------------------------
  logic [PoolArr-1:0][NumRespLanes-1:0]  pool_cap_want;
  logic [PoolArr-1:0][NumRespLanes-1:0]  pool_cap_first, pool_cap_second;
  logic [PoolArr-1:0]                    pool_cap_g1, pool_cap_g2;
  logic [NumRespLanes-1:0]               pool_cap_rest;   // the second-slot remainder, per entry
  logic [PoolArr-1:0]                    pool_st_cap_fire;
  /// Post-capture state per pool entry, the twin of st_post_cap: the value the entry holds after
  /// this cycle's capture, expressed from pool_q plus the capture's own fire term so the serve and
  /// cache timeout passes do not have to read pool_d.
  mshr_state_t [PoolArr-1:0]             pool_st_post_cap;
  mshr_resp_slot_t [PoolArr-1:0]         pool_cap_d0, pool_cap_d1;
  mshr_resp_slot_t [NumRespLanes-1:0]    pool_cap_payload;
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
  /// Finalize operands snapshotted before the pass writes anything, and the values it can write.
  /// Decided without the head-beat term so that term meets only the final select, instead of
  /// entering ahead of the pointer adder, the count subtract and the beats_left subtract.
  logic [RespBufCountW-1:0] fin_cnt_in,  fin_cnt_next;
  logic [RespBufPtrW-1:0]   fin_rdp_in,  fin_rdp_next;
  logic [BurstLenWidth-1:0] fin_bl_in,   fin_bl_next;
  logic [MshrMergeReqs-1:0] fin_bp2_in;
  logic                     fin_arm, fin_cache_sel, fin_cnt_next_nz;
  logic                     fin_bp_promote, fin_b2_clr;
  // Response drain scheduling (single-response per MSHR).

  // Round-robin fairness bases.
  localparam int unsigned NumReqPortsActive = (NumRemoteReqPortsPerTile > 1) ?
                                              (NumRemoteReqPortsPerTile - 1) : 1;
  localparam int unsigned NumAllocSlots     = NumTilesPerGroup * NumReqPortsActive;
  localparam int unsigned AllocRrW          = idx_width(NumAllocSlots);
  // One arbiter PER PORT, each NumTilesPerGroup wide, instead of one NumAllocSlots-wide arbiter.
  // The OR-reduce and the LSB-isolate both scale with log2(slots), so halving the width takes one
  // level off each; the per-bank combine below adds one back, for a small net gain. It is done
  // this way rather than by muxing the two ports into one stream because the ports usually hash to
  // DIFFERENT banks, where they contend for nothing -- a pre-mux would serialise them anyway.
  localparam int unsigned NumPortSlots      = NumTilesPerGroup;
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
  // The winner's payload, packed. Selecting ONE wide vector per lane costs MshrNum masked ORs
  // instead of MshrNum x (one per field), which is what makes the one-hot form affordable here --
  // per-field selection would be MshrNum x NumReqLanes x 7 statements in an already slow
  // elaboration. The entry index rides along, so the one-hot never has to be encoded at all.
  typedef struct packed {
    meta_id_t                 meta;
    tile_core_id_t            core;
    group_id_t                grp;
    tcdm_addr_t               addr;
    logic [BurstLenWidth-1:0] len;
    logic [MshrIdxW-1:0]      idx;
  } replay_payload_t;
  replay_payload_t [MshrNum-1:0]                             replay_payload;
  replay_payload_t                                           replay_sel;
  // Per-lane replay selection, hoisted OUT of the req_out_valid gate below. Nothing here reads
  // req_out_valid: replay_ready, replay_own_t/p, replay_payload and replay_rr_mask are all mshr_q
  // or CSR fed. Computing it under that gate put a 64-wide candidate scan, a 64-bit isolate and a
  // 64-way payload select AFTER the ready chain, for no reason -- the gate only has to pick.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrNum-1:0] replay_cand_l, replay_win_l;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrNum-1:0] replay_hi_l, replay_lo_l;
  /// A replay issued LAST cycle, carried as (fired, winner index) per lane rather than as the
  /// 64-bit union. replay_win_l is one-hot under replay_fire, so the pair is lossless -- and it puts
  /// the 32-lane OR on the register side of the flop, leaving the allocation grant one gate from
  /// the D pin. replay_pending is the union rebuilt from those registers.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                replay_fire_q;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrIdxW-1:0]  replay_widx_q;
  logic [MshrNum-1:0][NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   replay_pend_lane;
  logic [MshrNum-1:0]                                                       replay_pending;
  replay_payload_t [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   replay_sel_l;
  /// The replay gate, split at req_alloc_found. Every other term of req_out_valid is a decode or
  /// hit result, so the allocation grant -- the last thing to arrive -- meets a single 2:1 select
  /// instead of the four-deep stall chain that produced req_out_valid.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] replay_arm;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] replay_lane_stall;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] replay_fire_a0, replay_fire_a1;
  /// Whether a REPLAY may use this lane, as distinct from whether the banked walker happens to fire
  /// on it. Mirrors the walker's own a1 availability rule: the lane is stalled, or its request was
  /// just consumed by hold-the-fetch. The pool replay must use THIS rather than !replay_fire --
  /// replay_fire is 0 for a lane carrying a fresh, accepted request, and driving that lane would
  /// overwrite the fresh fetch with the replay's and lose the request.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] replay_lane_avail;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] replay_fire;
  /// req_out_valid, re-associated the same way: the allocation grant selects between two
  /// early arms rather than sitting at the end of the stall chain.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_out_use;
  // Replay winners accumulated across the lane loop, applied once per entry afterwards. Writing
  // mshr_d[replay_win_e].issued inside the loop made lane k+1 depend on lane k -- a 32-deep
  // last-writer chain on a bit that is only ever set. An OR is associative, so the tool balances
  // it; the scatter it replaces could not be. Lanes are disjoint by construction (one owner lane
  // per entry), which is what makes the OR equivalent to the priority form.
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
  /// Published way as a one-hot, in the thermometer-mask form the bank arbitration already uses.
  /// The descending (rr + k) scan takes the first hit in the order rr, rr+1, ... , W-1, 0, ... ,
  /// rr-1, which is the lowest set way at or above the base, else the lowest below it.
  logic [MshrBankNum-1:0][MshrWaysPerBank-1:0] bank_pub_oh;
  logic [MshrBankNum-1:0][MshrWaysPerBank-1:0] way_any, way_rr_mask, way_hi, way_lo;
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
    .BurstLenWidth(BurstLenWidth), .TileIdBits(TileIdBits),
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
    .addr_key_burst_o    (req_addr_key_burst),
    .addr_key_single_o   (req_addr_key_single),
    .is_load_o           (req_is_load),
    .is_store_o          (req_is_store),
    .is_single_o         (req_is_single),
    .is_non_full_burst_o (req_is_non_full_burst),
    .is_full_burst_o     (req_is_full_burst),
    .can_merge_o         (req_can_merge),
    .amo_invalidate_o    (amo_invalidate)
  );

  assign amo_inval_guard = CacheAmoInval && amo_invalidate;

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
          // The upper bound is load-bearing, not defensive. rsn_tag_cand is mshr_id_t, which is
          // idx_width(MshrNum) wide, so a POOL tag of MshrNum+1 casts to the value MshrNum and then
          // truncates to 0 in that width -- aliasing a pool response onto banked entry 0. Tags are
          // partitioned, so restricting this decode to the banked range is the whole fix.
          if ((resp_in[tile_i][port_i].mshr_tag != '0) &&
              (resp_in[tile_i][port_i].mshr_tag <= MshrTagWidth'(MshrNum))) begin : rsn_tag
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

  // ---------------------------------------------------------------------------------------------
  // POOL response landing, the twin of rsn_* above.
  //
  // Tags partition the space rather than sharing it: 1..MshrNum address the banked table and
  // MshrNum+1..MshrNum+PoolNum the pool, so one range test separates them and neither decode can
  // alias into the other. The pool id must NOT be recovered through mshr_id_t -- that type is
  // idx_width(MshrNum) wide (6 bits at 64 entries) and would truncate tag MshrNum+1 onto entry 0.
  // ---------------------------------------------------------------------------------------------
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               psn_v;
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][PoolIdxW-1:0] psn_id;
  logic [PoolIdxW-1:0]                                                      psn_tag_cand;
  generate
    if (PoolNum > 0) begin : gen_pool_resp_seen
      always_comb begin
        psn_v        = '0;
        psn_id       = '0;
        psn_tag_cand = '0;
        for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
          for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
            // Unconditional, as in the banked form: the id must be valid for the consumer's compare
            // even when the valid bit is 0.
            psn_tag_cand = PoolIdxW'(resp_in[tile_i][port_i].mshr_tag -
                                     MshrTagWidth'(MshrNum) - MshrTagWidth'(1));
            psn_id[tile_i][port_i] = psn_tag_cand;
            if (resp_in_valid[tile_i][port_i] &&
                (resp_in[tile_i][port_i].wen == 1'b0) &&
                (resp_in[tile_i][port_i].rdata.amo == '0)) begin
              // In the pool range, and only there.
              if ((resp_in[tile_i][port_i].mshr_tag >  MshrTagWidth'(MshrNum)) &&
                  (resp_in[tile_i][port_i].mshr_tag <= MshrTagWidth'(MshrNum + PoolNum))) begin : psn_tag
                if (pool_q_valid[psn_tag_cand] &&
                    ((pool_q[psn_tag_cand].state == MSHR_WAIT_RESP) ||
                     (pool_q[psn_tag_cand].state == MSHR_DRAIN_RESP)) &&
                    (pool_q[psn_tag_cand].sub_reqs[0].tile_id == tile_group_id_t'(tile_i)) &&
                    burst_beat_valid(resp_in[tile_i][port_i].rdata.core_id,
                                     resp_in[tile_i][port_i].rdata.meta_id,
                                     pool_q[psn_tag_cand].sub_reqs[0].core_id,
                                     pool_q[psn_tag_cand].sub_reqs[0].meta_id_base,
                                     pool_q[psn_tag_cand].burst_len)) begin
                  psn_v[tile_i][port_i] = 1'b1;
                end
              end
            end
          end
        end
      end
    end else begin : gen_pool_resp_seen_tie
      always_comb begin
        psn_v        = '0;
        psn_id       = '0;
        psn_tag_cand = '0;
      end
    end
  endgenerate

  // Is any validated response beat targeting POOL entry p this cycle? Same argument-passing
  // discipline as resp_seen_at: everything it reads is an argument.
  function automatic logic pool_resp_seen_at(
      input logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               v,
      input logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][PoolIdxW-1:0] id,
      input logic [PoolIdxW-1:0]                                                      p);
    pool_resp_seen_at = 1'b0;
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int pp = 1; pp < NumRemoteRespPortsPerTile; pp++) begin
        if (v[t][pp] && (id[t][pp] == p)) pool_resp_seen_at = 1'b1;
      end
    end
  endfunction

  // The pool has few entries but every response lane can target one. Gather each one-hot
  // winner at a constant entry index; a lane-indexed write would infer a priority scatter.
  generate
    if (PoolNum > 0) begin : gen_pool_cap_payload
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_pool_cap_payload_tile
        for (genvar p = 1; p < NumRemoteRespPortsPerTile; p++) begin : gen_pool_cap_payload_port
          localparam int unsigned Lane = t * NumRespPortsActive + p - 1;
          assign pool_cap_payload[Lane] =
              '{beat_off: BeatOffW'(resp_capture_beat_offset[t][p]),
                data: resp_in[t][p].rdata.data};
        end
      end
      for (genvar e = 0; e < PoolNum; e++) begin : gen_pool_cap_gather
        always_comb begin
          pool_cap_d0[e] = '0;
          pool_cap_d1[e] = '0;
          for (int l = 0; l < NumRespLanes; l++) begin
            pool_cap_d0[e] |= {$bits(mshr_resp_slot_t){pool_cap_first[e][l]}}
                              & pool_cap_payload[l];
            pool_cap_d1[e] |= {$bits(mshr_resp_slot_t){pool_cap_second[e][l]}}
                              & pool_cap_payload[l];
          end
        end
      end
    end else begin : gen_pool_cap_payload_tie
      assign pool_cap_payload = '0;
      assign pool_cap_d0 = '0;
      assign pool_cap_d1 = '0;
    end
  endgenerate

  // address-banking replaces the O(ports^2) same-cycle leader/follower coalescing.
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_bank_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_bank_port
        // Type comes from the CLAMPED req_is_single, not req_len_raw: a store or a
        // AMO is forced to req_len=1 and must bank like a single (see BankSelShift*).
        // Compare-then-mux: the hash runs for both classes in parallel and req_is_single picks the
        // result, instead of picking the class first and hashing after it. mshr_bank_of is pure, so
        // calling it with is_single forced to a constant and selecting afterwards is exact.
        assign req_bank_s[tile_i][port_i] =
            mshr_bank_of(req_addr_key[tile_i][port_i],
                         req_addr_key_burst[tile_i][port_i],
                         req_addr_key_single[tile_i][port_i],
                         req_in[tile_i][port_i].tgt_group_id, 1'b1,
                         cfg_bank_shift_single, cfg_bank_shift_burst, cfg_bank_burst_bits);
        assign req_bank_b[tile_i][port_i] =
            mshr_bank_of(req_addr_key[tile_i][port_i],
                         req_addr_key_burst[tile_i][port_i],
                         req_addr_key_single[tile_i][port_i],
                         req_in[tile_i][port_i].tgt_group_id, 1'b0,
                         cfg_bank_shift_single, cfg_bank_shift_burst, cfg_bank_burst_bits);
        assign req_bank[tile_i][port_i] = req_is_single[tile_i][port_i]
                                        ? req_bank_s[tile_i][port_i] : req_bank_b[tile_i][port_i];
`ifndef TARGET_SYNTHESIS
        // The split keys are not zeroed on an invalid request the way addr_key is, so equivalence
        // is claimed only where req_bank is consumed.
        assign req_bank_ref[tile_i][port_i] =
            mshr_bank_of(req_addr_key[tile_i][port_i], req_addr_key[tile_i][port_i],
                         req_addr_key[tile_i][port_i], req_in[tile_i][port_i].tgt_group_id,
                         req_is_single[tile_i][port_i],
                         cfg_bank_shift_single, cfg_bank_shift_burst, cfg_bank_burst_bits);
        req_bank_split_equiv: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            req_in_valid[tile_i][port_i] |->
              (req_bank[tile_i][port_i] == req_bank_ref[tile_i][port_i]))
          else $fatal(1, "tile %0d port %0d: split bank hash %0d != muxed-key %0d",
                      tile_i, port_i, req_bank[tile_i][port_i], req_bank_ref[tile_i][port_i]);
`endif
      end
    end
  endgenerate

  // q + g1 + g2 <= 6 < 2**RespBufCountW, so the sum never wraps, and sat(x)=min(x,RespBufWords)
  // is order-preserving for both tests: sat(x)!=0 == x!=0 and sat(x)>=2 == x>=2.
  generate
    for (genvar e = 0; e < MshrNum; e++) begin : gen_cap_cnt_pred
      assign cap_cnt_nz[e]  = !alloc_inflight[e] &&
                              ((mshr_q[e].resp_buf_cnt != '0) || cap_g1[e] || cap_g2[e]);
      assign cap_cnt_ge2[e] = !alloc_inflight[e] &&
                              ((mshr_q[e].resp_buf_cnt >= RespBufCountW'(2)) ||
                               ((mshr_q[e].resp_buf_cnt == RespBufCountW'(1)) &&
                                (cap_g1[e] || cap_g2[e])) ||
                               (cap_g1[e] && cap_g2[e]));
    end
  endgenerate

  // Per-lane capture credit and way, read at the lane's own returned tag. mshr_resp_slots is
  // registered and rsn_id is the tag minus one, so both resolve long before capb_want does.
  generate
    for (genvar l = 0; l < NumRespLanes; l++) begin : gen_cap_lane
      localparam int unsigned CapT = l / NumRespPortsActive;
      localparam int unsigned CapP = (l % NumRespPortsActive) + 1;
      assign cap_lane_ge1[l] = mshr_resp_slots[rsn_id[CapT][CapP]] >= RespBufCountW'(1);
      assign cap_lane_ge2[l] = mshr_resp_slots[rsn_id[CapT][CapP]] >= RespBufCountW'(2);
      assign cap_lane_way[l] = WaysPow2 ? VictimPtrW'(rsn_id[CapT][CapP])
                                        : VictimPtrW'(int'(rsn_id[CapT][CapP]) % MshrWaysPerBank);
    end
    for (genvar b = 0; b < MshrBankNum; b++) begin : gen_cap_tree_bank
      for (genvar l = 0; l < NumRespLanes; l++) begin : gen_cap_tree_leaf
        assign capt_v1[b][0][l] = capb_want_l[b][l];
        assign capt_a1[b][0][l] = cap_lane_ge1[l];
        assign capt_a2[b][0][l] = cap_lane_ge2[l];
        assign capt_w1[b][0][l] = cap_lane_way[l];
        assign capt_v2[b][0][l] = 1'b0;
        assign capt_b1[b][0][l] = 1'b0;
        assign capt_w2[b][0][l] = '0;
      end
      for (genvar st = 1; st <= CapStages; st++) begin : gen_cap_tree_stage
        for (genvar n = 0; n < (NumRespLanes >> st); n++) begin : gen_cap_tree_node
          assign capt_v1[b][st][n] = capt_v1[b][st-1][2*n] | capt_v1[b][st-1][2*n+1];
          assign capt_a1[b][st][n] = capt_v1[b][st-1][2*n] ? capt_a1[b][st-1][2*n]
                                                           : capt_a1[b][st-1][2*n+1];
          assign capt_a2[b][st][n] = capt_v1[b][st-1][2*n] ? capt_a2[b][st-1][2*n]
                                                           : capt_a2[b][st-1][2*n+1];
          assign capt_w1[b][st][n] = capt_v1[b][st-1][2*n] ? capt_w1[b][st-1][2*n]
                                                           : capt_w1[b][st-1][2*n+1];
          assign capt_v2[b][st][n] = capt_v2[b][st-1][2*n] | capt_v2[b][st-1][2*n+1] |
                                     (capt_v1[b][st-1][2*n] & capt_v1[b][st-1][2*n+1]);
          assign capt_b1[b][st][n] =
              capt_v2[b][st-1][2*n] ? capt_b1[b][st-1][2*n]
            : (capt_v1[b][st-1][2*n] ? capt_a1[b][st-1][2*n+1] : capt_b1[b][st-1][2*n+1]);
          assign capt_w2[b][st][n] =
              capt_v2[b][st-1][2*n] ? capt_w2[b][st-1][2*n]
            : (capt_v1[b][st-1][2*n] ? capt_w1[b][st-1][2*n+1] : capt_w2[b][st-1][2*n+1]);
        end
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
          wire mshr_id_t e_abs = req_e_abs[tile_i][port_i][way_i];
          assign req_e_abs[tile_i][port_i][way_i] =
              mshr_id_t'(int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i);
          // Compare-then-mux on the widest test in the cone: every bank's way-w entry is compared
          // in parallel against req_addr_key and tgt_group_id, both ready before req_bank, and the
          // bank one-hot picks one bit. The old form muxed base_addr and tgt_group_id on req_bank
          // and only then compared, putting a wide mux and a ~20-bit comparator in series after
          // the latest signal here.
          for (genvar bk = 0; bk < MshrBankNum; bk++) begin : gen_req_key_eq
            assign req_key_eq[tile_i][port_i][way_i][bk] =
                mshr_q_valid[bk * MshrWaysPerBank + way_i] &&
                (mshr_q[bk * MshrWaysPerBank + way_i].base_addr ==
                     req_addr_key[tile_i][port_i]) &&
                (mshr_q[bk * MshrWaysPerBank + way_i].tgt_group_id ==
                     req_in[tile_i][port_i].tgt_group_id);
          end
          assign req_addr_hit_way[tile_i][port_i][way_i] =
              req_in_valid[tile_i][port_i] &&
              |(req_bank_oh[tile_i][port_i] & req_key_eq[tile_i][port_i][way_i]);
          assign req_addr_hit_way_old[tile_i][port_i][way_i] =
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
               (RespWaitSubsSingle && !amo_inval_guard &&
                (mshr_q[e_abs].state == MSHR_RESP_HOLD) &&
                (mshr_q[e_abs].resp_buf_cnt != '0) &&
                (req_len[tile_i][port_i] == BurstLenWidth'(1))) ||
               (EnableRespCache && !amo_inval_guard &&
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
          // Same shape as the capacity term: indexed on req_bank, which is ready early, and read
          // from a register-only vector.
          assign req_hit_retire_way[tile_i][port_i][way_i] = retire_eligible[e_abs];
        end
        // Pool hits are folded into the same two reductions. Without this, a request that hits a
        // pool entry would also read as "missed every entry" and could win the allocator, resident
        // twice -- the single-copy violation the pool must not create.
        assign req_hit_mshr[tile_i][port_i] = |req_hit_way[tile_i][port_i] |
                                              req_hit_pool[tile_i][port_i];
        assign req_addr_hit_drain[tile_i][port_i] = |req_addr_hit_drain_way[tile_i][port_i] |
                                                    req_addr_hit_drain_pool[tile_i][port_i];
        // Exactly the req_addr_hit_way key, compared against the in-flight allocation record.
        // agb_q_len keeps a different-length request free to allocate its own entry, as req_hit_way
        // would have let it.
        // Compare-then-mux: all MshrBankNum records are compared in parallel against operands
        // that are ready well before req_bank, and req_bank then picks one BIT. The old form
        // selected ~20 bits of record with req_bank and only then compared, putting a wide mux
        // and a comparator in series after the latest signal in this cone.
        for (genvar bank_i = 0; bank_i < MshrBankNum; bank_i++) begin : gen_req_fwd_eq
          // decode(mux(a,b)) == mux(decode(a),decode(b)): the 16-way decode moves ahead of the
          // class select so req_is_single picks one BIT rather than an index to compare.
          assign req_bank_oh[tile_i][port_i][bank_i] = req_is_single[tile_i][port_i]
              ? (req_bank_s[tile_i][port_i] == BankIdW'(bank_i))
              : (req_bank_b[tile_i][port_i] == BankIdW'(bank_i));
          assign req_fwd_eq[tile_i][port_i][bank_i] =
              agb_q_v[bank_i] &&
              (agb_q_addr[bank_i] == req_addr_key[tile_i][port_i]) &&
              (agb_q_grp [bank_i] == req_in[tile_i][port_i].tgt_group_id) &&
              (agb_q_len [bank_i] == req_len[tile_i][port_i]);
        end
        assign req_fwd_hit[tile_i][port_i] =
            req_can_merge[tile_i][port_i] &&
            |(req_bank_oh[tile_i][port_i] & req_fwd_eq[tile_i][port_i]);
        assign req_fwd_id[tile_i][port_i] =
            mshr_id_t'(int'(req_bank[tile_i][port_i]) * MshrWaysPerBank +
                       int'(req_fwd_way[tile_i][port_i]));
      end
    end
  endgenerate

  // The forwarded way, selected with the same one-hot rather than indexed by req_bank.
  always_comb begin
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
        req_fwd_way[t][p] = '0;
        for (int b = 0; b < MshrBankNum; b++) begin
          req_fwd_way[t][p] = req_fwd_way[t][p] |
              ({VictimPtrW{req_bank_oh[t][p][b]}} & agb_q_way[b]);
        end
      end
    end
  end

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

  // Stores cannot merge, so their input handshake reduces to downstream ready. Constant entry
  // indices and one-hot byte winners avoid a lane priority mux.
  generate
    if (PoolNum > 0 && CacheStoreUpdate && EnableRespCache) begin : gen_pool_stb
      for (genvar p = 0; p < PoolNum; p++) begin : gen_entry
        for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_tile
          for (genvar rp = 1; rp < NumRemoteReqPortsPerTile; rp++) begin : gen_port
            localparam int unsigned Lane = t * NumReqPortsActiveF3 + rp - 1;
            assign pool_stb_hit[p][Lane] =
                !amo_invalidate && pool_q_valid[p] && !pool_alloc_inflight[p] &&
                (pool_q[p].state == MSHR_CACHED) && pool_addr_hit_way[t][rp][p] &&
                req_in_valid[t][rp] && req_is_store[t][rp] &&
                (req_len[t][rp] == BurstLenWidth'(1)) &&
                req_out_ready[t][rp];
          end
        end
        for (genvar b = 0; b < StrbW; b++) begin : gen_byte
          for (genvar lane = 0; lane < NumReqLanes; lane++) begin : gen_lane
            assign pool_stb_byte_req[p][b][lane] = pool_stb_hit[p][lane] && stb_be[lane][b];
          end
          // The highest lane wins an overlapping byte, matching the banked store path.
          assign pool_stb_byte_win[p][b] = stb_hi_isolate(pool_stb_byte_req[p][b]);
          assign pool_stb_bytes[p][b] = |pool_stb_byte_req[p][b];
          always_comb begin
            pool_stb_byte_data[p][b] = '0;
            for (int lane = 0; lane < NumReqLanes; lane++) begin
              pool_stb_byte_data[p][b] |=
                  {8{pool_stb_byte_win[p][b][lane]}} & stb_wd[lane][b*8 +: 8];
            end
          end
        end
      end
    end else begin : gen_pool_stb_tie
      assign pool_stb_hit = '0;
      assign pool_stb_byte_req = '0;
      assign pool_stb_byte_win = '0;
      assign pool_stb_byte_data = '0;
      assign pool_stb_bytes = '0;
    end
  endgenerate

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

  // ---------------------------------------------------------------------------------------------
  // POOL request-side lookup: the twins of req_hit_way and req_fwd_eq, evaluated against the
  // pool instead of the request's bank ways.
  //
  // A pool entry is reachable by EVERY bank's requests, so this compare is not bank-scoped and is
  // therefore wider than the banked one -- but only by PoolNum, so at K=1 it is one comparator per
  // (tile, port) rather than one per (tile, port, way) per bank.
  //
  // SINGLE-COPY INVARIANT. A line must never be resident both in a bank way and in the pool, or the
  // cohort splits across two entries and both time out. What enforces it: a request that hits the
  // pool must not also be an allocation candidate, and a request that hits a bank way must not
  // allocate into the pool. Both are handled by folding req_hit_pool into req_hit_mshr, which
  // req_alloc_cand already reads, and by making the pool arm of the selection mutually exclusive
  // with the way loop's.
  // ---------------------------------------------------------------------------------------------

  generate
    if (PoolNum > 0) begin : gen_pool_req_lookup
      for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_pool_lookup_tile
        for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_pool_lookup_port
          for (genvar p = 0; p < PoolNum; p++) begin : gen_pool_lookup_entry
            // Same key as req_addr_hit_way: valid, base_addr, tgt_group_id. No bank compare -- a
            // pool entry has no bank, which is the whole point of it.
            assign pool_addr_hit_way[tile_i][port_i][p] =
                req_in_valid[tile_i][port_i] &&
                pool_q_valid[p] &&
                (pool_q[p].base_addr    == req_addr_key[tile_i][port_i]) &&
                (pool_q[p].tgt_group_id == req_in[tile_i][port_i].tgt_group_id);
            // Merge eligibility: identical term for term to req_hit_way, with pool_q in place of
            // mshr_q[e_abs] and no way index to select.
            assign pool_hit_way[tile_i][port_i][p] =
                req_can_merge[tile_i][port_i] &&
                pool_addr_hit_way[tile_i][port_i][p] &&
                (pool_q[p].burst_len == req_len[tile_i][port_i]) &&
                (((pool_q[p].state == MSHR_WAIT_RESP) &&
                  (pool_q[p].beats_left == pool_q[p].burst_len)) ||
                 (RespWaitSubsSingle && !amo_inval_guard &&
                  (pool_q[p].state == MSHR_RESP_HOLD) &&
                  (pool_q[p].resp_buf_cnt != '0) &&
                  (req_len[tile_i][port_i] == BurstLenWidth'(1))) ||
                 (EnableRespCache && !amo_inval_guard &&
                  (pool_q[p].state == MSHR_CACHED) &&
                  (pool_q[p].resp_buf_cnt != '0) &&
                  (req_len[tile_i][port_i] == BurstLenWidth'(1)))) &&
                !pool_resp_seen_at(psn_v, psn_id, PoolIdxW'(p)) &&
                ((pool_q[p].sub_reqs_num + SubReqCountW'(1)) <= MshrMergeReqs);
            // The same in-flight / drain / landing terms as req_addr_hit_drain_way.
            assign pool_addr_hit_drain_way[tile_i][port_i][p] =
                pool_addr_hit_way[tile_i][port_i][p] &&
                ((pool_q[p].state == MSHR_DRAIN_RESP) ||
                 (pool_merge_inflight[p] && (pool_q[p].state != MSHR_WAIT_RESP)) ||
                 pool_alloc_inflight[p] ||
                 (StallOnResp && pool_resp_seen_at(psn_v, psn_id, PoolIdxW'(p))));
            // Capacity including the merge this entry has not absorbed yet, as in req_hit_cap_way.
            assign pool_cap_way[tile_i][port_i][p] =
                ((MergeRankW'(pool_q[p].sub_reqs_num + SubReqCountW'(pool_merge_inflight[p])) +
                  MergeRankW'(1)) <= MergeRankW'(MshrMergeReqs));
          end
          assign req_hit_pool[tile_i][port_i]            = |pool_hit_way[tile_i][port_i];
          assign req_addr_hit_drain_pool[tile_i][port_i] = |pool_addr_hit_drain_way[tile_i][port_i];
          // Forward into an in-flight POOL allocation: exactly the req_fwd_eq key, and the id is the
          // record's own way -- already a pool index, so no mshr_id_t round trip is possible and
          // none is needed.
          assign req_fwd_pool_hit[tile_i][port_i] =
              req_can_merge[tile_i][port_i] && apb_q_v &&
              (apb_q_addr == req_addr_key[tile_i][port_i]) &&
              (apb_q_grp  == req_in[tile_i][port_i].tgt_group_id) &&
              (apb_q_len  == req_len[tile_i][port_i]);
          assign req_fwd_pool_id[tile_i][port_i] = apb_q_way;
        end
      end
    end else begin : gen_pool_req_lookup_tie
      assign pool_addr_hit_way       = '0;
      assign pool_hit_way            = '0;
      assign pool_addr_hit_drain_way = '0;
      assign pool_cap_way            = '0;
      assign req_hit_pool            = '0;
      assign req_addr_hit_drain_pool = '0;
      assign req_fwd_pool_hit        = '0;
      assign req_fwd_pool_id         = '0;
    end
  endgenerate

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
        // A forwarded merge joins a leader allocated this cycle, which can never be retiring.
        req_hit_retire_sel[tile_i][port_i]     = 1'b0;
        for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
          if (!req_hit_mshr_sel_valid[tile_i][port_i] &&
              req_hit_way[tile_i][port_i][way_i]) begin
            req_hit_mshr_sel_valid[tile_i][port_i] = 1'b1;
            req_hit_mshr_sel_id[tile_i][port_i] =
                mshr_id_t'(int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i);
            req_hit_cap_sel[tile_i][port_i] = req_hit_cap_way[tile_i][port_i][way_i];
            req_hit_retire_sel[tile_i][port_i] = req_hit_retire_way[tile_i][port_i][way_i];
          end
        end
        // POOL arm, LAST so a banked way hit keeps priority. With no pool entry resident -- and
        // certainly at MshrOverflowNum = 0, where every term here is constant -- the whole arm folds
        // away and this select is bit-identical to the design without a pool.
        // Seeded from the in-flight POOL allocation first, exactly as the banked arm is seeded from
        // req_fwd_hit: a follower must merge into the leader's entry rather than allocate a second
        // one for the same line.
        req_hit_pool_sel_valid[tile_i][port_i]  = req_fwd_pool_hit[tile_i][port_i];
        req_hit_pool_sel_id[tile_i][port_i]     = req_fwd_pool_hit[tile_i][port_i]
                                                ? req_fwd_pool_id[tile_i][port_i] : '0;
        req_hit_pool_cap_sel[tile_i][port_i]    =
            (MergeRankW'(1) + MergeRankW'(1)) <= MergeRankW'(MshrMergeReqs);
        req_hit_pool_retire_sel[tile_i][port_i] = 1'b0;
        for (int pp = 0; pp < PoolNum; pp++) begin
          if (!req_hit_mshr_sel_valid[tile_i][port_i] &&
              !req_hit_pool_sel_valid[tile_i][port_i] &&
              pool_hit_way[tile_i][port_i][pp]) begin
            req_hit_pool_sel_valid[tile_i][port_i]  = 1'b1;
            req_hit_pool_sel_id[tile_i][port_i]     = PoolIdxW'(pp);
            req_hit_pool_cap_sel[tile_i][port_i]    = pool_cap_way[tile_i][port_i][pp];
            req_hit_pool_retire_sel[tile_i][port_i] = pool_retire_eligible[pp];
          end
        end
      end
    end
  end

  // Allocation candidacy: a mergeable load that missed every resident entry and has no
  // same-address drain hazard wants a new entry. Responses select an entry by mshr_tag;
  // requester metadata IDs need only remain unique until that requester consumes its responses,
  // not until all other subscribers of the old entry finish draining.
  for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_alloc_cand_tile
    for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_alloc_cand_port
      assign req_alloc_cand[tile_i][port_i] =
          req_can_merge[tile_i][port_i]      &&
          !req_hit_mshr[tile_i][port_i]      &&
          // A forwarding lane merges into the in-flight allocation; req_hit_mshr only sees
          // RESIDENT ways, so without this it would also stay an allocation candidate and could
          // win the arbiter -- allocating a second entry for a line it is already merging into.
          !req_fwd_hit[tile_i][port_i]       &&
          !req_fwd_pool_hit[tile_i][port_i]  &&
          !req_addr_hit_drain[tile_i][port_i];
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
  // Slot -> bank, decoded ONCE and shared by both arbiters (they differ only in cand_i).
  logic [NumAllocSlots-1:0][MshrBankNum-1:0] arb_bank_oh;
  logic [NumAllocSlots-1:0]                  alloc_rr_mask;   // 1 = slot is at/above the RR base
  logic [MshrBankNum-1:0][NumAllocSlots-1:0] bank_win_oh;     // one-hot winner per bank
  // Per-port slices of the flattened candidate/bank/mask vectors, and each port's own winner.
  logic [NumReqPortsActive-1:0][NumPortSlots-1:0]                  alloc_cand_p, merge_cand_p;
  logic [NumReqPortsActive-1:0][NumPortSlots-1:0][MshrBankNum-1:0] arb_bank_oh_p;
  logic [NumReqPortsActive-1:0][NumPortSlots-1:0]                  alloc_rr_mask_p;
  logic [NumReqPortsActive-1:0][MshrBankNum-1:0][NumPortSlots-1:0] win_oh_p, merge_win_oh_p;
  // "bank granted somebody", straight out of each arbiter's OR-reduce -- see any_o there.
  logic [NumReqPortsActive-1:0][MshrBankNum-1:0]                   alloc_any_o, merge_any_o;
  logic [MshrBankNum-1:0][NumReqPortsActive-1:0]                   alloc_any_p, merge_any_p;
  /// The OTHER port's veto. win_oh_p already implies that port's own any_o -- the isolate of a
  /// non-empty vector is non-empty, and both halves carry the same bank gate -- so win && pick
  /// equals win && yield, and the port's own OR-reduce leaves the grant path.
  logic [MshrBankNum-1:0][NumReqPortsActive-1:0]                   alloc_yield_p, merge_yield_p;

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
  logic [MshrBankNum-1:0][NumAllocSlots-1:0] bank_merge_win_oh;   // one-hot merge winner per bank
  logic [AllocRrW-1:0]                       merge_arb_slot_idx;      // flatten block
`ifndef TARGET_SYNTHESIS
  logic [NumAllocSlots-1:0]                  merge_arb_grant_flat_dbg; // granted lanes, for coverage
`endif

  always_comb begin
    alloc_cand_flat = '0;
    // Slot = tile*NumReqPortsActive + (port-1) is a bijection over the active req ports
    // (1..NumRemoteReqPortsPerTile-1); the * and + are constant folds, not arithmetic.
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        alloc_slot_idx = AllocRrW'(tile_i * NumReqPortsActive + (port_i - 1));
        // req_in_valid folded in: the arbiter must not grant an invalid lane, and with it folded
        // the grant implies the valid half of the accept. req_alloc_cand is built from decode and
        // hit terms, none of which carries valid.
        alloc_cand_flat[alloc_slot_idx] = req_in_valid[tile_i][port_i] &&
                                          req_alloc_cand[tile_i][port_i];
      end
    end
    // Thermometer mask from the rotation base, computed once and shared by every bank.
    // EnableRrFairness = 0 collapses it to all-ones, i.e. plain ascending priority from slot 0 --
    // exactly the old alloc_base = 0 behaviour.
    for (int s = 0; s < NumAllocSlots; s++) begin
      alloc_rr_mask[s] = EnableRrFairness ? (s >= int'(alloc_rr_q)) : 1'b1;
    end
  end

  // A superset of what the two retire sites below can fire on, built from registers alone: the
  // reuse-target retire and the self-invalidate age-out. A superset is the safe direction -- it
  // only refuses a merge that the retire would otherwise have had to veto in-cycle.
  generate
    for (genvar e = 0; e < MshrNum; e++) begin : gen_retire_eligible
      assign retire_eligible[e] =
          EnableRespCache && mshr_q_valid[e] &&
          (mshr_q[e].state == MSHR_CACHED) &&
          (mshr_q[e].sub_reqs_num == '0) &&
          ((mshr_q[e].served_cnt >=
              ((cfg_cache_reuse_target != '0)
                 ? ServedCntW'(cfg_cache_reuse_target)
                 : ServedCntW'((mshr_q[e].burst_len == BurstLenWidth'(1))
                                 ? cfg_hold_subs_single : cfg_hold_subs_burst))) ||
           (CacheSelfInval && (mshr_q[e].hold_cnt == '0)));
    end
  endgenerate
  /// The same superset for pool entries: a pool entry retires on the same two conditions, so the
  /// merge veto that reads it must see them too.
  generate
    if (PoolNum > 0) begin : gen_pool_retire_eligible
      for (genvar p = 0; p < PoolNum; p++) begin : gen_pool_retire_eligible_p
        assign pool_retire_eligible[p] =
            EnableRespCache && pool_q_valid[p] &&
            (pool_q[p].state == MSHR_CACHED) &&
            (pool_q[p].sub_reqs_num == '0) &&
            ((pool_q[p].served_cnt >=
                ((cfg_cache_reuse_target != '0)
                   ? ServedCntW'(cfg_cache_reuse_target)
                   : ServedCntW'((pool_q[p].burst_len == BurstLenWidth'(1))
                                   ? cfg_hold_subs_single : cfg_hold_subs_burst))) ||
             (CacheSelfInval && (pool_q[p].hold_cnt == '0)));
      end
    end else begin : gen_pool_retire_eligible_tie
      assign pool_retire_eligible = '0;
    end
  endgenerate

  // A bank with no free way grants nobody; its candidates fall through to stall/bypass unchanged.
  // Slot Sl = t * NumReqPortsActive + (p-1), so port p owns the slots with (Sl % ports) == p-1.
  generate
    for (genvar pp = 0; pp < NumReqPortsActive; pp++) begin : gen_arb_port
      for (genvar tt = 0; tt < NumPortSlots; tt++) begin : gen_arb_port_slot
        localparam int unsigned SlF = tt * NumReqPortsActive + pp;
        assign alloc_cand_p   [pp][tt] = alloc_cand_flat    [SlF];
        assign merge_cand_p   [pp][tt] = merge_arb_cand_flat[SlF];
        assign arb_bank_oh_p  [pp][tt] = arb_bank_oh        [SlF];
        assign alloc_rr_mask_p[pp][tt] = alloc_rr_mask      [SlF];
      end
      mempool_group_mshr_bank_arb #(
        .NumSlots(NumPortSlots), .NumBanks(MshrBankNum), .BankIdW(BankIdW)
      ) i_alloc_arb (
        .cand_i (alloc_cand_p[pp]), .bank_oh_i (arb_bank_oh_p[pp]),
        .rr_mask_i (alloc_rr_mask_p[pp]), .bank_gate_i (bank_has_free),
        .win_oh_o (win_oh_p[pp]), .any_o (alloc_any_o[pp])
      );
      mempool_group_mshr_bank_arb #(
        .NumSlots(NumPortSlots), .NumBanks(MshrBankNum), .BankIdW(BankIdW)
      ) i_merge_arb (
        .cand_i (merge_cand_p[pp]), .bank_oh_i (arb_bank_oh_p[pp]),
        .rr_mask_i (alloc_rr_mask_p[pp]), .bank_gate_i ({MshrBankNum{1'b1}}),
        .win_oh_o (merge_win_oh_p[pp]), .any_o (merge_any_o[pp])
      );
    end

    // A bank can grant one slot per cycle, so where both ports produced a winner for the SAME bank
    // one must yield -- and only there. Different banks are untouched, which is why this costs no
    // throughput. The preference alternates with the allocation rotation base, so neither port can
    // starve the other on a persistently contended bank.
    for (genvar b = 0; b < MshrBankNum; b++) begin : gen_arb_combine
      for (genvar pp = 0; pp < NumReqPortsActive; pp++) begin : gen_arb_combine_p
        // From the arbiter's OR-reduce, not from |win_oh: identical value, ~3 levels earlier,
        // because it does not wait for the LSB-isolate or the select mux.
        assign alloc_any_p[b][pp] = alloc_any_o[pp][b];
        assign merge_any_p[b][pp] = merge_any_o[pp][b];
      end
      assign alloc_yield_p[b][0] = !alloc_any_p[b][1] || !alloc_rr_q[0];
      assign alloc_yield_p[b][1] = !alloc_any_p[b][0] ||  alloc_rr_q[0];
      assign merge_yield_p[b][0] = !merge_any_p[b][1] || !alloc_rr_q[0];
      assign merge_yield_p[b][1] = !merge_any_p[b][0] ||  alloc_rr_q[0];
      for (genvar tt = 0; tt < NumPortSlots; tt++) begin : gen_arb_combine_slot
        for (genvar pp = 0; pp < NumReqPortsActive; pp++) begin : gen_arb_combine_slot_p
          assign bank_win_oh      [b][tt * NumReqPortsActive + pp] =
              win_oh_p      [pp][b][tt] && alloc_yield_p[b][pp];
          assign bank_merge_win_oh[b][tt * NumReqPortsActive + pp] =
              merge_win_oh_p[pp][b][tt] && merge_yield_p[b][pp];
        end
      end
    end
  endgenerate

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
        // Unqualified: bank_free_id is register-fed and req_bank is early, so the id is shallow;
        // the grant qualifier only put the allocation arbiter on it. Every synthesised reader is
        // already under the grant -- the record under agb_v, the tag stamp under req_alloc_found --
        // and the CacheVictimRR reader is not generated at CacheReclaimable=0.
        assign req_alloc_found_mshr_id[tile_i][port_i] = bank_free_id[req_bank[tile_i][port_i]];
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
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        merge_arb_slot_idx = AllocRrW'(tile_i * NumReqPortsActive + (port_i - 1));
        // Capacity folded into the CANDIDATE, not applied to the grant. A lane with no room can
        // no longer win a bank's merge slot and then be refused, wasting that slot for the cycle;
        // a different lane in the bank wins instead. NOT bit-exact -- it changes which lane merges
        // -- but nothing is lost (a capless lane still stalls and retries) and no merge can
        // overflow, since the same test decides. Judge it on merge_arb_stall/grant, not on cycles.
        // An entry whose retire conditions already hold is not a merge candidate. That is what
        // removes the combinational merge veto from the two retire sites, and with it the only
        // request-fed term that reached mshr_d: no merge can be decided into an entry that is
        // retiring, so the retire needs no in-cycle knowledge of the arbiter.
        merge_arb_cand_flat[merge_arb_slot_idx] = req_in_valid[tile_i][port_i] &&
                                                  req_merge_valid[tile_i][port_i] &&
                                                  req_hit_cap_sel[tile_i][port_i] &&
                                                  !req_hit_retire_sel[tile_i][port_i];
      end
    end
  end

  // ---------------------------------------------------------------------------------------------
  // POOL arbiters. The pool has its OWN allocation port rather than borrowing the bank's slot: a
  // bank-full miss is trying to escape that bank's arbitration, so making it contend for the same
  // bank's slot would re-create the very wait the pool exists to break. One merge port too, for the
  // same reason.
  //
  // Both arbiters are NumAllocSlots wide and share the allocation rotation base, so a high-index
  // tile is not perpetually beaten to the pool either.
  // ---------------------------------------------------------------------------------------------
  logic [NumAllocSlots-1:0] pool_alloc_cand_flat;
  logic [NumAllocSlots-1:0] pool_merge_cand_flat;
  logic [NumAllocSlots-1:0] pool_alloc_win_oh;
  logic [NumAllocSlots-1:0] pool_merge_win_oh;
  // Both allocators use the same acceptance guard after choosing a candidate.
  logic [NumAllocSlots-1:0] alloc_accept;

  /// First candidate at or above the rotation base, else the first below it -- the same
  /// thermometer-mask + prefix-OR isolate the bank arbiter uses, over the flattened slot axis.
  /// Everything it reads is an argument, so it samples nothing implicitly.
  function automatic logic [NumAllocSlots-1:0] pool_arb_pick(
      input logic [NumAllocSlots-1:0] cand,
      input logic [AllocRrW-1:0]      base,
      input logic                     rr_en);
    logic [NumAllocSlots-1:0] rr_mask, hi, lo, pf_hi, pf_lo;
    rr_mask = '0;
    for (int s = 0; s < NumAllocSlots; s++) begin
      rr_mask[s] = rr_en ? (s >= int'(base)) : 1'b1;
    end
    hi = cand &  rr_mask;
    lo = cand & ~rr_mask;
    pf_hi = hi;
    pf_lo = lo;
    for (int st = 1; st < NumAllocSlots; st = st << 1) begin
      pf_hi = pf_hi | (pf_hi << st);
      pf_lo = pf_lo | (pf_lo << st);
    end
    pool_arb_pick = (|hi) ? (pf_hi & ~(pf_hi << 1)) : (pf_lo & ~(pf_lo << 1));
  endfunction

  generate
    if (PoolNum > 0) begin : gen_pool_arb
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_pool_arb_tile
        for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_pool_arb_port
          localparam int unsigned Sl = t * NumReqPortsActive + (p - 1);
          // Reclaimable CACHED ways are already included in bank_has_free.
          assign pool_alloc_cand_flat[Sl] = req_in_valid[t][p] && req_alloc_cand[t][p] &&
              !bank_has_free[req_bank[t][p]] && pool_has_free;
          assign pool_merge_cand_flat[Sl] = req_in_valid[t][p] && req_merge_pool_valid[t][p] &&
              req_hit_pool_cap_sel[t][p] && !req_hit_pool_retire_sel[t][p];
          assign req_alloc_found_pool[t][p]    = pool_alloc_win_oh[Sl];
          assign req_alloc_found_pool_id[t][p] = pool_free_id;
          assign req_merge_pool_ready[t][p]    = pool_merge_win_oh[Sl];
          assign req_merge_pool_valid[t][p]    = req_can_merge[t][p] &&
              req_hit_pool_sel_valid[t][p] && !req_addr_hit_drain[t][p];
        end
      end
      assign pool_alloc_win_oh = pool_arb_pick(pool_alloc_cand_flat, alloc_rr_q, EnableRrFairness);
      assign pool_merge_win_oh = pool_arb_pick(pool_merge_cand_flat, alloc_rr_q, EnableRrFairness);
      // Keep the stage enables separate from the payload reduction. Allocation grants require
      // acceptance; a merge grant already implies the complete input handshake.
      assign apb_v = |(pool_alloc_win_oh & alloc_accept);
      assign apb_en = |(pool_alloc_cand_flat & alloc_accept);
      // The picker always returns one winner for a nonempty candidate vector.
      // Keep RR selection and prefix isolation off the stage-register enable.
      assign mpb_v = |pool_merge_cand_flat;
      // The free id is register-derived and read only under apb_v.
      assign apb_way = pool_free_id;

      // Each grant vector is one-hot, so masked ORs select the same payload as a priority loop
      // without serializing every request lane on the stage-register D pins.
      always_comb begin
        apb_addr = '0; apb_grp = '0; apb_len = '0;
        apb_tile = '0; apb_port = '0; apb_core = '0; apb_meta = '0;
        mpb_way  = '0;
        mpb_tile = '0; mpb_port = '0; mpb_core = '0; mpb_meta = '0;
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
            apb_addr |= {$bits(tcdm_addr_t){pool_alloc_win_oh[t * NumReqPortsActive + p - 1]}}
                        & req_addr_key[t][p];
            apb_grp  |= {$bits(group_id_t){pool_alloc_win_oh[t * NumReqPortsActive + p - 1]}}
                        & req_in[t][p].tgt_group_id;
            apb_len  |= {BurstLenWidth{pool_alloc_win_oh[t * NumReqPortsActive + p - 1]}}
                        & req_len[t][p];
            apb_tile |= {$bits(tile_group_id_t){pool_alloc_win_oh[t * NumReqPortsActive + p - 1]}}
                        & tile_group_id_t'(t);
            apb_port |= {RespPortIdW{pool_alloc_win_oh[t * NumReqPortsActive + p - 1]}}
                        & RespPortIdW'(p);
            apb_core |= {$bits(tile_core_id_t){pool_alloc_win_oh[t * NumReqPortsActive + p - 1]}}
                        & req_in[t][p].wdata.core_id;
            apb_meta |= {$bits(meta_id_t){pool_alloc_win_oh[t * NumReqPortsActive + p - 1]}}
                        & req_in[t][p].wdata.meta_id;
            mpb_way  |= {PoolIdxW{pool_merge_win_oh[t * NumReqPortsActive + p - 1]}}
                        & req_hit_pool_sel_id[t][p];
            mpb_tile |= {$bits(tile_group_id_t){pool_merge_win_oh[t * NumReqPortsActive + p - 1]}}
                        & tile_group_id_t'(t);
            mpb_port |= {RespPortIdW{pool_merge_win_oh[t * NumReqPortsActive + p - 1]}}
                        & RespPortIdW'(p);
            mpb_core |= {$bits(tile_core_id_t){pool_merge_win_oh[t * NumReqPortsActive + p - 1]}}
                        & req_in[t][p].wdata.core_id;
            mpb_meta |= {$bits(meta_id_t){pool_merge_win_oh[t * NumReqPortsActive + p - 1]}}
                        & req_in[t][p].wdata.meta_id;
          end
        end
      end
    end else begin : gen_pool_arb_tie
      // EVERY pool output must be driven here, including the staged record and its valid bit.
      // Leaving apb_v/mpb_v undriven puts X on the pool's staged registers at
      // MshrOverflowNum = 0, and mshr_busy_o ORs apb_q_v / mpb_q_v -- so an X there reaches the CSR
      // interlock that gates a bank-hash change while entries are resident. The
      // pool_absent_never_allocates assertion caught exactly this on the first pool-OFF run.
      always_comb begin
        pool_alloc_cand_flat = '0;
        pool_merge_cand_flat = '0;
        pool_alloc_win_oh    = '0;
        pool_merge_win_oh    = '0;
        req_merge_pool_valid = '0;
        req_merge_pool_ready = '0;
        req_alloc_found_pool = '0;
        req_alloc_found_pool_id = '0;
        apb_v    = 1'b0;
        apb_en   = 1'b0;
        apb_way  = '0;
        apb_addr = '0; apb_grp = '0; apb_len = '0;
        apb_tile = '0; apb_port = '0; apb_core = '0; apb_meta = '0;
        mpb_v    = 1'b0;
        mpb_way  = '0;
        mpb_tile = '0; mpb_port = '0; mpb_core = '0; mpb_meta = '0;
      end
    end
  endgenerate


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
  logic [PoolArr-1:0]                pool_hold_tick;   // ... and per pool entry
  // A held pool response must drain before a same-address store can leave a stale copy.
  logic [PoolArr-1:0]                pool_st_force_drain;
  generate
    if (PoolNum > 0 && StoreForceDrain) begin : gen_pool_sfd
      for (genvar p = 0; p < PoolNum; p++) begin : gen_entry
        for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_tile
          for (genvar rp = 1; rp < NumRemoteReqPortsPerTile; rp++) begin : gen_port
            localparam int unsigned Lane = t * NumReqPortsActiveF3 + rp - 1;
            assign pool_sfd_hit[p][Lane] =
                ((pool_q[p].state == MSHR_RESP_HOLD) ||
                 (pool_st_post_cap[p] == MSHR_RESP_HOLD)) && pool_addr_hit_way[t][rp][p] &&
                req_in_valid[t][rp] && req_is_store[t][rp] &&
                req_out_ready[t][rp] &&
                (req_len[t][rp] == BurstLenWidth'(1));
          end
        end
        assign pool_st_force_drain[p] = |pool_sfd_hit[p];
      end
    end else begin : gen_pool_sfd_tie
      assign pool_sfd_hit = '0;
      assign pool_st_force_drain = '0;
    end
  endgenerate

  /// Per-pool-entry timeout pulses, the twins of mshr_resp_hold_timeout_dbg / mshr_cache_timeout_dbg,
  /// so the dashboard's per-entry timeout records can label pool ids too.
  logic [PoolArr-1:0]                pool_resp_hold_timeout_dbg;
  logic [PoolArr-1:0]                pool_cache_timeout_dbg;
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
    // Pool entries take their phase off the pool index, so expiries stay spread the same way.
    pool_hold_tick = '0;
    for (int unsigned p = 0; p < PoolNum; p++) begin
      pool_hold_tick[p] = (HoldPrescaleW == 0) ? 1'b1 : hold_tick_phase[HoldPrescaleWSafe'(p)];
    end
  end


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

  // Enabled, not a bare `FF: a plain flop lets the tool invent the gate enable from all of
  // mshr_d_valid, putting that whole cone on a gating check. mshr_ctl_en is a safe superset.
  generate
    for (genvar e = 0; e < MshrNum; e++) begin : gen_mshr_valid_ff
      `FFL(mshr_q_valid[e], mshr_d_valid[e], mshr_ctl_en[e], '0)
    end
  endgenerate

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

  // ---------------------------------------------------------------------------------------------
  // POOL registers: the same three clock-gate groups as the banked block above, for the same
  // reason -- a bare `FF lets the tool invent the enable from the whole next-state cone, putting it
  // on a gating check. The enables are the same conservative supersets.
  // ---------------------------------------------------------------------------------------------
  generate
    if (PoolNum > 0) begin : gen_pool_reg
      logic [PoolArr-1:0]                   pool_id_en;
      logic [PoolArr-1:0]                   pool_ctl_en;
      logic [PoolArr-1:0][RespBufWords-1:0] pool_rb_en;
      always_comb begin
        for (int p = 0; p < PoolNum; p++) begin
          pool_ctl_en[p] = pool_q_valid[p] | pool_alloc_inflight[p];
          pool_id_en[p]  = pool_wr_all[p]  | pool_id_we[p];
          for (int b = 0; b < RespBufWords; b++) begin
            pool_rb_en[p][b] = pool_wr_all[p] | pool_rb_we[p][b];
          end
        end
      end
      for (genvar p = 0; p < PoolNum; p++) begin : gen_pool_valid_ff
        `FFL(pool_q_valid[p], pool_d_valid[p], pool_ctl_en[p], '0)
      end
      for (genvar p = 0; p < PoolNum; p++) begin : gen_pool_entry_reg
        `FFL(pool_q[p].base_addr,    pool_d[p].base_addr,    pool_id_en[p], '0)
        `FFL(pool_q[p].tgt_group_id, pool_d[p].tgt_group_id, pool_id_en[p], '0)
        `FFL(pool_q[p].burst_len,    pool_d[p].burst_len,    pool_id_en[p], '0)
        for (genvar s = 0; s < MshrMergeReqs; s++) begin : gen_pool_sub_req_reg
          `FFL(pool_q[p].sub_reqs[s].tile_id,      pool_d[p].sub_reqs[s].tile_id,      pool_id_en[p], '0)
          `FFL(pool_q[p].sub_reqs[s].port_id,      pool_d[p].sub_reqs[s].port_id,      pool_id_en[p], '0)
          `FFL(pool_q[p].sub_reqs[s].core_id,      pool_d[p].sub_reqs[s].core_id,      pool_id_en[p], '0)
          `FFL(pool_q[p].sub_reqs[s].meta_id_base, pool_d[p].sub_reqs[s].meta_id_base, pool_id_en[p], '0)
          `FFL(pool_q[p].sub_reqs[s].valid,        pool_d[p].sub_reqs[s].valid,        pool_ctl_en[p], '0)
        end
        for (genvar b = 0; b < RespBufWords; b++) begin : gen_pool_resp_buf_reg
          `FFL(pool_q[p].resp_buf[b], pool_d[p].resp_buf[b], pool_rb_en[p][b], '0)
        end
        `FFL(pool_q[p].sub_reqs_num,    pool_d[p].sub_reqs_num,    pool_ctl_en[p], '0)
        `FFL(pool_q[p].served_cnt,      pool_d[p].served_cnt,      pool_ctl_en[p], '0)
        `FFL(pool_q[p].beat_pending,    pool_d[p].beat_pending,    pool_ctl_en[p], '0)
        `FFL(pool_q[p].beat_pending2,   pool_d[p].beat_pending2,   pool_ctl_en[p], '0)
        `FFL(pool_q[p].beat2_armed,     pool_d[p].beat2_armed,     pool_ctl_en[p], '0)
        `FFL(pool_q[p].beats_left,      pool_d[p].beats_left,      pool_ctl_en[p], '0)
        `FFL(pool_q[p].resp_buf_cnt,    pool_d[p].resp_buf_cnt,    pool_ctl_en[p], '0)
        `FFL(pool_q[p].resp_buf_rd_ptr, pool_d[p].resp_buf_rd_ptr, pool_ctl_en[p], '0)
        `FFL(pool_q[p].resp_buf_wr_ptr, pool_d[p].resp_buf_wr_ptr, pool_ctl_en[p], '0)
        `FFL(pool_q[p].cacheable,       pool_d[p].cacheable,       pool_ctl_en[p], '0)
        `FFL(pool_q[p].hold_cnt,        pool_d[p].hold_cnt,        pool_ctl_en[p], '0)
        `FFL(pool_q[p].issued,          pool_d[p].issued,          pool_ctl_en[p], '0)
        `FFL(pool_q[p].state,           pool_d[p].state,           pool_ctl_en[p], mshr_state_t'(0))
`ifndef TARGET_SYNTHESIS
        `FFL(pool_q[p].beat_seen,     pool_d[p].beat_seen,     pool_ctl_en[p], '0)
        `FFL(pool_q[p].beat_done,     pool_d[p].beat_done,     pool_ctl_en[p], '0)
        `FFL(pool_q[p].cache_hit_cnt, pool_d[p].cache_hit_cnt, pool_ctl_en[p], '0)
`endif
      end
    end else begin : gen_no_pool
      // Nothing drives the pool arrays at PoolNum = 0; tie the read side off so no consumer sees X.
      assign pool_q       = '0;
      assign pool_q_valid = '0;
    end
  endgenerate

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
  generate
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_replay_pend_t
      for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_replay_pend_p
        `FF(replay_fire_q[t][p], replay_fire[t][p], '0)
        // replay_arm is a register-fed superset of replay_fire, and the index is only read under
        // replay_fire_q, so over-asserting the enable can neither lose nor invent a write.
        `FFL(replay_widx_q[t][p], replay_sel_l[t][p].idx, replay_arm[t][p], '0)
      end
    end
  endgenerate

  generate
    for (genvar e = 0; e < MshrNum; e++) begin : gen_replay_pending_e
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_replay_pending_t
        for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_replay_pending_p
          assign replay_pend_lane[e][t][p] =
              replay_fire_q[t][p] && (replay_widx_q[t][p] == MshrIdxW'(e));
        end
      end
      assign replay_pending[e] = |replay_pend_lane[e];
    end
  endgenerate
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

  // Per-window occupancy report for MshrNum sizing (simulation-only, group_mshr_stats_period).
  // Each line is one window, not a running total: mean occupancy x100, the high-water marks, and
  // how many cycles the array sat completely full.
  logic [63:0]         occ_cyc;
  logic [31:0]         occ_win_cyc;
  logic [63:0]         occ_valid_sum;
  logic [MshrCntW-1:0] occ_valid_max;
  logic [MshrCntW-1:0] occ_inuse_max;
  logic [MshrCntW-1:0] occ_cached_max;
  logic [31:0]         occ_full_cyc;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      occ_cyc        <= '0;
      occ_win_cyc    <= '0;
      occ_valid_sum  <= '0;
      occ_valid_max  <= '0;
      occ_inuse_max  <= '0;
      occ_cached_max <= '0;
      occ_full_cyc   <= '0;
    end else if (StatsPeriod != 0) begin
      occ_cyc        <= occ_cyc + 64'd1;
      occ_win_cyc    <= occ_win_cyc + 32'd1;
      occ_valid_sum  <= occ_valid_sum + 64'(mshr_valid_cnt_dbg);
      if (mshr_valid_cnt_dbg  > occ_valid_max)  occ_valid_max  <= mshr_valid_cnt_dbg;
      if (mshr_inuse_cnt_dbg  > occ_inuse_max)  occ_inuse_max  <= mshr_inuse_cnt_dbg;
      if (mshr_cached_cnt_dbg > occ_cached_max) occ_cached_max <= mshr_cached_cnt_dbg;
      if (mshr_valid_cnt_dbg == MshrCntW'(MshrNum)) occ_full_cyc <= occ_full_cyc + 32'd1;
      if ((occ_win_cyc != 32'd0) && ((occ_win_cyc % StatsPeriod) == 0)) begin
        $display("[MSHRU] cyc=%0d g=%0d win=%0d valid_avg_x100=%0d valid_max=%0d inuse_max=%0d cached_max=%0d full_cyc=%0d entries=%0d",
                 occ_cyc, group_id_i, occ_win_cyc,
                 (occ_valid_sum * 64'd100) / 64'(occ_win_cyc),
                 occ_valid_max, occ_inuse_max, occ_cached_max, occ_full_cyc, MshrNum);
        occ_win_cyc    <= '0;
        occ_valid_sum  <= '0;
        occ_valid_max  <= '0;
        occ_inuse_max  <= '0;
        occ_cached_max <= '0;
        occ_full_cyc   <= '0;
      end
    end
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
  // (banked or pool) against lanes that actually did (resp_capture_fire). The difference is the
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
      cap_want_cnt_dbg        <= cap_want_cnt_dbg + 32'($countones(resp_is_mshr | psn_v));
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
        // A pool grant is an ALLOCATION, not a bypass: without the pool term this counter would
        // report every pool-allocated request as a bankfull bypass and corrupt the very metric the
        // pool's effect is read from.
        if (req_in_valid[t][p] && req_can_merge[t][p] &&
            !req_merge_valid[t][p] && !req_alloc_found[t][p] &&
            !req_alloc_found_pool[t][p] &&
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
  // The published entry's drive operands, per bank. The publication is port-independent, so
  // these are built MshrWaysPerBank:1 once instead of MshrNum:1 in each of the 32 lanes.
  data_t         [MshrBankNum-1:0]                     pub_drv_data;
  logic          [MshrBankNum-1:0][BurstLenWidth-1:0]  pub_drv_beat_off;
  logic          [MshrBankNum-1:0]                     pub_drv_burst_one;
  // Drain eligibility of each bank's published row, read at the loop constant like the drive
  // operands above it. At bank_pub_e[b] each of these was an MshrNum:1 select, evaluated in all 32
  // lanes; here they are MshrWaysPerBank:1 and evaluated once.
  logic           [MshrBankNum-1:0][MshrMergeReqs-1:0]                  pub_sub_ready;
  tile_group_id_t [MshrBankNum-1:0][MshrMergeReqs-1:0]                  pub_sub_tile;
  logic           [MshrBankNum-1:0][MshrMergeReqs-1:0][RespPortIdW-1:0] pub_sub_port;
  logic           [MshrBankNum-1:0][MshrMergeReqs-1:0][RespPortIdW-1:0] pub_sub_map;
  /// Per-bank scan temporaries: the sub-request terms that do not involve the response port, and
  /// the port test for the ParityDrain arm, where the port is the same for every sub-request.
  logic           [MshrMergeReqs-1:0]                                   pub_sub_ok;
  logic                                                                 pub_parity_ok;
  tile_core_id_t [MshrBankNum-1:0][MshrMergeReqs-1:0]  pub_drv_sub_core;
  meta_id_t      [MshrBankNum-1:0][MshrMergeReqs-1:0]  pub_drv_sub_meta;
  // This lane's operands after the bank select.
  data_t                                               drv_sel_data;
  logic          [BurstLenWidth-1:0]                   drv_sel_beat_off;
  logic                                                drv_sel_burst_one;
  /// The banked row's burst_one for this lane, independent of the pool operands.
  logic                                                drv_bank_burst_one;
  tile_core_id_t [MshrMergeReqs-1:0]                   drv_sel_sub_core;
  meta_id_t      [MshrMergeReqs-1:0]                   drv_sel_sub_meta;
  logic [MshrBankNum-1:0]   bank_cand, bank_cand_rot, bank_cand_eff, bank_pfx, bank_first;
  // Per-bank candidates with the sub-request axis KEPT, so the winner's sub-request set is
  // selected rather than re-derived at the winning entry id.
  logic [MshrBankNum-1:0][MshrMergeReqs-1:0] bank_sub_cand;
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][BankIdW-1:0] resp_sel_bank;
  /// The winning bank as the arbiter emitted it. bank_first is already one-hot, so the row select
  /// and the per-lane drive operands read it directly instead of through bank_win's encoder and a
  /// MshrBankNum:1 re-mux.
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][MshrBankNum-1:0] resp_sel_bank_oh;
  /// The selected sub-request as a one-hot. sub_first is already one-hot under drain_have_s, so
  /// the handshake scatter takes it directly instead of through drain_win_s's encoder and a
  /// per-slot equality compare.
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][MshrMergeReqs-1:0] resp_sel_sub_oh;
  /// A banked row won this lane, and its sub-request one-hot. Written only by the banked selection,
  /// so the banked drive select and the banked clear scatter carry no pool term. The pool is offered
  /// a lane only when no banked row won it, so inside a valid selection "not banked" is exactly
  /// "pool", and a banked handshake is exactly a handshake without a pool selection.
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]                    resp_sel_bank_valid;
  logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][MshrMergeReqs-1:0] resp_sel_bank_sub_oh;
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
  // The requester's own mapped port, without the ParityDrain override. The published-row scan
  // tests the two arms separately, so it needs the un-muxed form.
  logic [MshrNum-1:0][MshrMergeReqs-1:0][RespPortIdW-1:0]     drain_sub_map;
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
        drain_sub_map[e][s]   = map_resp_port_id(mshr_q[e].sub_reqs[s].port_id);
        drain_sub_port[e][s]  = (PD2 && (mshr_q[e].burst_len != BurstLenWidth'(1)))
                              ? (RespPortIdW'(1) + RespPortIdW'(drv_beat_off[e][0]))
                              : drain_sub_map[e][s];
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

  // ---------------------------------------------------------------------------------------------
  // POOL drain operands, head beat and ParityDrain second slot.
  //
  // The banked versions above are consumed through the per-bank publish, which evaluates one
  // published row per bank instead of every entry. A pool entry has no bank and so cannot be
  // published; it carries its own copy of the same per-entry values and is offered to the drain
  // selection directly. Register-fed (pool_q only), exactly like its twin -- so this block adds no
  // depth to the drain cone, only width.
  // ---------------------------------------------------------------------------------------------
  logic [PoolArr-1:0]                                          pool_drain_ent_ok;
  logic [PoolArr-1:0][MshrMergeReqs-1:0]                       pool_drain_sub_ready;
  tile_group_id_t [PoolArr-1:0][MshrMergeReqs-1:0]             pool_drain_sub_tile;
  logic [PoolArr-1:0][MshrMergeReqs-1:0][RespPortIdW-1:0]      pool_drain_sub_port;
  logic [PoolArr-1:0][MshrMergeReqs-1:0][RespPortIdW-1:0]      pool_drain_sub_map;
  data_t [PoolArr-1:0]                                         pool_drv_data;
  tile_core_id_t [PoolArr-1:0][MshrMergeReqs-1:0]              pool_drv_sub_core;
  meta_id_t [PoolArr-1:0][MshrMergeReqs-1:0]                   pool_drv_sub_meta;
  logic [PoolArr-1:0]                                          pool_drv_burst_one;
  logic [PoolArr-1:0][BurstLenWidth-1:0]                       pool_drv_beat_off;
  logic [PoolArr-1:0]                                          pool_drain2_ent_ok;
  logic [PoolArr-1:0][MshrMergeReqs-1:0]                       pool_drain2_sub_ready;
  tile_group_id_t [PoolArr-1:0][MshrMergeReqs-1:0]             pool_drain2_sub_tile;
  logic [PoolArr-1:0][RespPortIdW-1:0]                         pool_drain2_sub_port;
  logic [PoolArr-1:0][RespBufPtrW-1:0]                         pool_drain2_rd_ptr;
  logic [PoolArr-1:0][BurstLenWidth-1:0]                       pool_drain2_beat_off;
  data_t [PoolArr-1:0]                                         pool_drv2_data;
  generate
    if (PoolNum > 0) begin : gen_pool_drain_scan
      for (genvar p = 0; p < PoolNum; p++) begin : gen_pool_drain_p
        // Head slot. Same q-sourcing argument as the banked block: capture writes at wr_ptr, the
        // drive reads rd_ptr, and the scan requires resp_buf_cnt != 0, so they address different
        // slots.
        assign pool_drv_data[p]      = pool_q[p].resp_buf[pool_q[p].resp_buf_rd_ptr].data;
        assign pool_drv_beat_off[p]  = (pool_q[p].burst_len == BurstLenWidth'(1))
                                     ? '0
                                     : pool_q[p].resp_buf[pool_q[p].resp_buf_rd_ptr].beat_off;
        assign pool_drv_burst_one[p] = (pool_q[p].burst_len == BurstLenWidth'(1));
        assign pool_drain_ent_ok[p]  = pool_q_valid[p] && (pool_q[p].resp_buf_cnt != '0) &&
                                       (pool_q[p].state == MSHR_DRAIN_RESP);
        for (genvar s = 0; s < MshrMergeReqs; s++) begin : gen_pool_drain_sub
          assign pool_drain_sub_ready[p][s] = pool_drain_ent_ok[p] &&
                                              pool_q[p].sub_reqs[s].valid &&
                                              pool_q[p].beat_pending[s];
          assign pool_drain_sub_tile[p][s]  = pool_q[p].sub_reqs[s].tile_id;
          assign pool_drv_sub_core[p][s]    = pool_q[p].sub_reqs[s].core_id;
          assign pool_drv_sub_meta[p][s]    = pool_q[p].sub_reqs[s].meta_id_base;
          assign pool_drain_sub_map[p][s]   = map_resp_port_id(pool_q[p].sub_reqs[s].port_id);
          assign pool_drain_sub_port[p][s]  =
              (PD2 && (pool_q[p].burst_len != BurstLenWidth'(1)))
                ? (RespPortIdW'(1) + RespPortIdW'(pool_drv_beat_off[p][0]))
                : pool_drain_sub_map[p][s];
        end
        // Second slot (ParityDrain): the head-beat test one buffer slot further on.
        assign pool_drain2_ent_ok[p] = PD2 && pool_q_valid[p]                            &&
                                       (pool_q[p].state        == MSHR_DRAIN_RESP)       &&
                                       (pool_q[p].burst_len    != BurstLenWidth'(1))     &&
                                       (pool_q[p].resp_buf_cnt >= RespBufCountW'(2))     &&
                                       pool_q[p].beat2_armed;
        assign pool_drain2_rd_ptr[p] =
            (RespBufWords > 1)
              ? ((pool_q[p].resp_buf_rd_ptr == RespBufPtrW'(RespBufWords - 1))
                   ? '0 : RespBufPtrW'(pool_q[p].resp_buf_rd_ptr + 1'b1))
              : '0;
        assign pool_drain2_beat_off[p] = pool_q[p].resp_buf[pool_drain2_rd_ptr[p]].beat_off;
        assign pool_drv2_data[p]       = pool_q[p].resp_buf[pool_drain2_rd_ptr[p]].data;
        // Both beats share one parity port, so this is per entry, not per sub-request.
        assign pool_drain2_sub_port[p] = RespPortIdW'(1) + RespPortIdW'(pool_drain2_beat_off[p][0]);
        for (genvar s = 0; s < MshrMergeReqs; s++) begin : gen_pool_drain2_sub
          assign pool_drain2_sub_ready[p][s] = pool_drain2_ent_ok[p] &&
                                               pool_q[p].sub_reqs[s].valid &&
                                               pool_q[p].beat_pending2[s];
          assign pool_drain2_sub_tile[p][s]  = pool_q[p].sub_reqs[s].tile_id;
        end
      end
    end else begin : gen_pool_drain_scan_tie
      assign pool_drain_ent_ok     = '0;
      assign pool_drain_sub_ready  = '0;
      assign pool_drain_sub_tile   = '0;
      assign pool_drain_sub_port   = '0;
      assign pool_drain_sub_map    = '0;
      assign pool_drv_data         = '0;
      assign pool_drv_sub_core     = '0;
      assign pool_drv_sub_meta     = '0;
      assign pool_drv_burst_one    = '0;
      assign pool_drv_beat_off     = '0;
      assign pool_drain2_ent_ok    = '0;
      assign pool_drain2_sub_ready = '0;
      assign pool_drain2_sub_tile  = '0;
      assign pool_drain2_sub_port  = '0;
      assign pool_drain2_rd_ptr    = '0;
      assign pool_drain2_beat_off  = '0;
      assign pool_drv2_data        = '0;
    end
  endgenerate

  logic [MshrIdxW-1:0]      drain_win_e;
  logic [SubIdxW-1:0]       drain_win_s;
  logic                     drain_have_e,    drain_have_s;
  logic [SubIdxW-1:0]       drain_scan_s;                          // A: rotated scan index
  /// Hi/lo split about the sub-request rotation base, in place of the rotated priority scan: the
  /// same order, but one AND and a width-4 isolate instead of a four-deep sequential chain.
  logic [MshrMergeReqs-1:0] sub_rr_mask;
  logic [MshrMergeReqs-1:0] sub_hi, sub_lo, sub_first;
  /// Hi/lo split about the bank rotation base, in place of the barrel rotate. The rotate put four
  /// mux levels on the candidate vector -- the latest signal here -- for a priority order the mask
  /// expresses directly, and the winner is then applied as a one-hot instead of being encoded and
  /// indexed back.
  logic [MshrBankNum-1:0] bank_rr_mask;
  /// Lane-invariant half of the bank arbitration, with the demoted-base correction folded into
  /// the masks so the per-lane candidate vector meets one AND instead of a demote AND then a mask
  /// AND. drain_sel_base is a register and bank_pub_* are computed above the lane loop.
  logic [MshrBankNum-1:0] bank_hi_mask, bank_lo_mask;
  logic [MshrBankNum-1:0] bank_hi, bank_lo;
  logic [MshrBankNum-1:0] bank_pfx_hi, bank_pfx_lo, bank_first_hi, bank_first_lo;
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
  // Merge accept, without re-deriving what the grant already proves. bank_merge_win_oh[b][s]
  // implies merge_arb_cand_flat[s] = req_merge_valid[s], so the ready chain takes its FIRST
  // branch, req_in_ready = req_merge_ready && req_hit_cap_sel -- and req_merge_ready[s] is itself
  // implied by the grant. Only the capacity bit is left to check.
  // Keep explicit validity in acceptance even though req_can_merge also
  // carries validity through request decoding.
  // Allocation accept, by the same argument. bank_win_oh[b][s] implies req_alloc_cand[s], which
  // excludes resident and in-flight hits and same-address drain hazards. The grant also
  // excludes the bank-full stall, leaving only the hold-window/NoC acceptance condition.
  logic [NumAllocSlots-1:0]                     arb_hold_nz;
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
        assign arb_accept[Sl]   = req_in_valid[t][p] && req_in_ready[t][p];
        // The grant now implies capacity, so only validity is left to check here.
        for (genvar ab = 0; ab < MshrBankNum; ab++) begin : gen_arb_bank_oh
          // Identical function to req_bank_oh, so share it rather than rebuild the comparators.
          assign arb_bank_oh[Sl][ab] = req_bank_oh[t][p][ab];
        end
        assign arb_hold_nz[Sl]  = ((((req_len[t][p] == BurstLenWidth'(1)) ? cfg_hold_window_single
                                                                         : cfg_hold_window_burst)
                                    != '0));
        // req_in_valid is in the candidate now. req_out_ready must NOT be folded there: the
        // bank-full arm would stall the lane and drop req_out_valid, making valid depend on
        // ready. So the allocation keeps a narrow accept.
        assign alloc_accept[Sl] = arb_hold_nz[Sl] || req_out_ready[t][p];
        assign arb_addr  [Sl] = req_addr_key[t][p];
        assign arb_grp   [Sl] = req_in[t][p].tgt_group_id;
        assign arb_len   [Sl] = req_len[t][p];
        assign arb_tile  [Sl] = tile_group_id_t'(t);
        assign arb_port  [Sl] = RespPortIdW'(p);
        assign arb_core  [Sl] = req_in[t][p].wdata.core_id;
        assign arb_meta  [Sl] = req_in[t][p].wdata.meta_id;
        // The way of an absolute entry id: a bit slice only when ways is a power of two.
        assign arb_awy   [Sl] = WaysPow2
                              ? req_alloc_found_mshr_id[t][p][VictimPtrW-1:0]
                              : VictimPtrW'(int'(req_alloc_found_mshr_id[t][p]) % MshrWaysPerBank);
        // A free NoC port and at least one held entry owned by this lane: everything the replay
        // needs that does not depend on the allocation grant.
        assign replay_arm[t][p] = req_out_ready[t][p] && (|replay_cand_l[t][p]);
        // The request leaves this port free whatever the grant says.
        assign replay_lane_stall[t][p] =
            !req_in_valid[t][p] || req_merge_valid[t][p] ||
            req_merge_pool_valid[t][p] ||
            (req_can_merge[t][p] && req_addr_hit_drain[t][p]);
        // The two grant arms: bank-full stall when the lane did not win a slot, hold-the-fetch when
        // it did. Both are decode and hit terms only.
        assign replay_fire_a0[t][p] = replay_arm[t][p] &&
            (replay_lane_stall[t][p] ||
             (req_can_merge[t][p] &&
              (bank_has_free[req_bank[t][p]] || cfg_bankfull_bp)));
        assign replay_fire_a1[t][p] = replay_arm[t][p] &&
            (replay_lane_stall[t][p] || (req_can_merge[t][p] && arb_hold_nz[Sl]));
        // The a1 availability term, exposed on its own for the pool walker. A lane whose request was
        // just ACCEPTED and is driving its own fetch this cycle satisfies neither disjunct, and that
        // is the case the pool walker was missing.
        assign replay_lane_avail[t][p] =
            replay_lane_stall[t][p] ||
            (req_can_merge[t][p] && arb_hold_nz[Sl] &&
             (req_alloc_found[t][p] || req_alloc_found_pool[t][p]));
        // A POOL grant is the same event as a banked grant here: the lane won an entry, so it either
        // drives its own fetch (hold window 0) or consumes the request locally and lets the replay
        // walker issue it. Without the pool term in these two expressions the lane was CONSUMED and
        // nothing was driven: req_out_use came out 0 because bank_has_free is false by definition
        // when the pool is used and cfg_bankfull_bp then made the else-arm true -- so every pool
        // allocation silently dropped its request, the entry never fetched, and its cohort desynced.
        // That is what killed both pool-ON runs ~340 cycles into the benchmark while the pool-OFF
        // control ran on.
        assign replay_fire[t][p] = (req_alloc_found[t][p] || req_alloc_found_pool[t][p])
                                   ? replay_fire_a1[t][p] : replay_fire_a0[t][p];
        assign req_out_use[t][p] =
            !(replay_lane_stall[t][p] ||
              (req_can_merge[t][p] &&
               ((req_alloc_found[t][p] || req_alloc_found_pool[t][p])
                  ? arb_hold_nz[Sl]
                  : (bank_has_free[req_bank[t][p]] || cfg_bankfull_bp))));
        assign arb_mwy   [Sl] = WaysPow2
                              ? req_merge_mshr_id[t][p][VictimPtrW-1:0]
                              : VictimPtrW'(int'(req_merge_mshr_id[t][p]) % MshrWaysPerBank);
      end
    end

    for (genvar b = 0; b < MshrBankNum; b++) begin : gen_arb_record
      assign agb_sel[b] = bank_win_oh[b]       & alloc_accept;
      assign mgb_sel[b] = bank_merge_win_oh[b];   // the grant implies the whole merge accept
      assign agb_v[b]   = |agb_sel[b];
      // NOT |mgb_sel[b]: a merge grant already implies validity and capacity, so the enable is
      // just "some port's arbiter granted this bank" -- and pick implies any, so the OR over the
      // two ports' picks reduces to the OR of their any_o. That takes the LSB-isolate and the
      // select mux off this clock-gate enable, which is the tightest check in the block.
      assign mgb_v[b]   = |merge_any_p[b];

      always_comb begin
        agb_way [b] = '0; agb_addr[b] = '0; agb_grp [b] = '0; agb_len [b] = '0;
        agb_tile[b] = '0; agb_port[b] = '0; agb_core[b] = '0; agb_meta[b] = '0;
        mgb_way [b] = '0; mgb_tile[b] = '0; mgb_port[b] = '0;
        mgb_core[b] = '0; mgb_meta[b] = '0;
        for (int s = 0; s < NumAllocSlots; s++) begin
          agb_way [b] |= {VictimPtrW      {bank_win_oh[b][s]}} & arb_awy [s];
          agb_addr[b] |= {$bits(tcdm_addr_t){bank_win_oh[b][s]}} & arb_addr[s];
          agb_grp [b] |= {$bits(group_id_t) {bank_win_oh[b][s]}} & arb_grp [s];
          agb_len [b] |= {BurstLenWidth   {bank_win_oh[b][s]}} & arb_len [s];
          agb_tile[b] |= {$bits(tile_group_id_t){bank_win_oh[b][s]}} & arb_tile[s];
          agb_port[b] |= {RespPortIdW     {bank_win_oh[b][s]}} & arb_port[s];
          agb_core[b] |= {$bits(tile_core_id_t){bank_win_oh[b][s]}} & arb_core[s];
          agb_meta[b] |= {$bits(meta_id_t) {bank_win_oh[b][s]}} & arb_meta[s];
          mgb_way [b] |= {VictimPtrW      {bank_merge_win_oh[b][s]}} & arb_mwy [s];
          mgb_tile[b] |= {$bits(tile_group_id_t){bank_merge_win_oh[b][s]}} & arb_tile[s];
          mgb_port[b] |= {RespPortIdW     {bank_merge_win_oh[b][s]}} & arb_port[s];
          mgb_core[b] |= {$bits(tile_core_id_t){bank_merge_win_oh[b][s]}} & arb_core[s];
          mgb_meta[b] |= {$bits(meta_id_t) {bank_merge_win_oh[b][s]}} & arb_meta[s];
        end
      end
    end
  endgenerate

  /// Stage register. The valid bits are unconditional; each bank's payload is enabled by its own
  /// valid, so an idle bank's flops do not toggle.
  `FF(agb_q_v, agb_v, '0)
  `FF(mgb_q_v, mgb_v, '0)
  // POOL stage records, the same cut on the same boundary. One record each rather than one per bank,
  // because the pool grants at most one allocation and one merge per cycle.
  `FF(apb_q_v, apb_v, '0)
  `FF(mpb_q_v, mpb_v, '0)
  // D input is the COMBINATIONAL apb_* / mpb_* record; the _q form is the output.
  `FFL(apb_q_way,  apb_way,  apb_en, '0)
  `FFL(apb_q_addr, apb_addr, apb_en, '0)
  `FFL(apb_q_grp,  apb_grp,  apb_en, '0)
  `FFL(apb_q_len,  apb_len,  apb_en, '0)
  `FFL(apb_q_tile, apb_tile, apb_en, '0)
  `FFL(apb_q_port, apb_port, apb_en, '0)
  `FFL(apb_q_core, apb_core, apb_en, '0)
  `FFL(apb_q_meta, apb_meta, apb_en, '0)
  `FFL(mpb_q_way,  mpb_way,  mpb_v, '0)
  `FFL(mpb_q_tile, mpb_tile, mpb_v, '0)
  `FFL(mpb_q_port, mpb_port, mpb_v, '0)
  `FFL(mpb_q_core, mpb_core, mpb_v, '0)
  `FFL(mpb_q_meta, mpb_meta, mpb_v, '0)
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
  // Candidates with the sub-request axis kept, and the winning BANK. Under Drain2BankPublish
  // the winner never has to be widened to MshrNum and encoded back.
  logic [MshrBankNum-1:0][MshrMergeReqs-1:0] drain2_bank_sub_cand;
  logic [BankIdW-1:0]       drain2_bank_idx;
  logic [MshrBankNum-1:0]   drain2_bank_rr_mask;
  logic [MshrBankNum-1:0]   drain2_bhi, drain2_blo, drain2_bfirst;
  logic [BankIdW-1:0]       drain2_bank_base;
  logic                     drain2_any;                            // a candidate exists, either form
  logic [MshrNum-1:0]       drain2_rr_mask;                        // 1 = entry is at/above the base
  logic [MshrNum-1:0]       drain2_hi, drain2_lo;
  logic [MshrIdxW-1:0]      drain2_idx;                            // A: index within the rotation
  logic [MshrIdxW-1:0]      drain2_base, drain2_mshr_i;            // B
  logic [SubIdxW-1:0]       drain2_sub_base, drain2_s;             // B

  // Per-lane replay selection, computed unconditionally. Pure code motion: none of these reads
  // req_out_valid, so evaluating them ahead of the ready chain changes nothing but their arrival.
  generate
    for (genvar rt = 0; rt < NumTilesPerGroup; rt++) begin : gen_replay_lane_t
      for (genvar rp = 1; rp < NumRemoteReqPortsPerTile; rp++) begin : gen_replay_lane
        for (genvar re = 0; re < MshrNum; re++) begin : gen_replay_cand
          assign replay_cand_l[rt][rp][re] =
              replay_ready[re] && (replay_own_t[re] == tile_group_id_t'(rt)) &&
              (replay_own_p[re] == RespPortIdW'(rp));
        end
        assign replay_hi_l[rt][rp] = replay_cand_l[rt][rp] &  replay_rr_mask;
        assign replay_lo_l[rt][rp] = replay_cand_l[rt][rp] & ~replay_rr_mask;
        assign replay_win_l[rt][rp] =
            (replay_hi_l[rt][rp] != '0)
              ? (replay_hi_l[rt][rp] & (~replay_hi_l[rt][rp] + MshrNum'(1)))
              : (replay_lo_l[rt][rp] & (~replay_lo_l[rt][rp] + MshrNum'(1)));
      end
    end
  endgenerate

  // The winner's payload, selected with the one-hot rather than an encoded index.
  always_comb begin
    for (int rt = 0; rt < NumTilesPerGroup; rt++) begin
      for (int rp = 1; rp < NumRemoteReqPortsPerTile; rp++) begin
        replay_sel_l[rt][rp] = '0;
        for (int re = 0; re < MshrNum; re++) begin
          replay_sel_l[rt][rp] = replay_sel_l[rt][rp] |
              ({$bits(replay_payload_t){replay_win_l[rt][rp][re]}} & replay_payload[re]);
        end
      end
    end
  end

  always_comb begin
    // Defaults
    mgb_slot = '0;
    mshr_d      = mshr_q;
    // Every pool register holds its value unless the corresponding write path fires.
    pool_d      = pool_q;
    pool_wr_all = '0;
    pool_id_we  = '0;
    pool_rb_we  = '0;
    // Timeout telemetry consists of one-cycle pulses.
    pool_resp_hold_timeout_dbg = '0;
    pool_cache_timeout_dbg     = '0;
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
    // Same hold-by-default, and the same deferred set, for the pool.
    pool_d_valid   = pool_q_valid;
    pool_alloc_set = '0;
    pmb_slot = '0;
    pool_cand = '0;
    pool_first = '0;
    pool_first_any = 1'b0;
    pool_sub_cand_map = '0;
    pool_win = '0;
    pool_sub_cand = '0;
    pool_sub_first = '0;
    pool_win_s = '0;
    pool_have_s = 1'b0;
    pool_replay_scan_valid = '0;
    pool_replay_scan_ent = '0;
    pool_replay_ready = '0;
    pool_replay_issue = '0;
    pool_replay_own_t = '0;
    pool_replay_own_p = '0;
    pool_replay_win = '0;
    pool_replay_any = 1'b0;
    pool_cap_rest = '0;
`ifndef TARGET_SYNTHESIS
    gate_extra     = '0;
`endif
    mshr_alloc_set = '0;
    // A replay issued last cycle marks its entry now. Applied here, before the allocation apply,
    // so an entry reallocated in the meantime takes allocation's own value instead.
    for (int e = 0; e < MshrNum; e++) begin
      if (replay_pending[e]) mshr_d[e].issued = 1'b1;
    end
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

    // POOL twin of the countdown above, and REQUIRED rather than optional: this is the only pass
    // that decrements a held entry's counter, so with no pool arm here a pool entry's hold_cnt
    // would stay frozen at its allocated value. The replay walker releases a held fetch when the
    // window expires OR the subscriber target is met, so the entry would then wait for subscribers
    // that already stopped arriving, never fetch, and hang -- allocated but never issued.
    if (HoldWindowMax != 0) begin
      for (int p = 0; p < PoolNum; p++) begin
        if (pool_q_valid[p] && (pool_q[p].state == MSHR_WAIT_RESP) && !pool_q[p].issued &&
            (pool_q[p].hold_cnt != '0) && pool_hold_tick[p]) begin
          pool_d[p].hold_cnt = pool_q[p].hold_cnt - HoldCntW'(1);
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
    // Hoisted out of the lane loop below: none of valid / alloc_inflight / state is written by that
    // loop (the allocation is recorded, not applied), so all 32 lanes see the same entry state and
    // this is evaluated once per entry at a CONSTANT index.
    for (int e = 0; e < MshrNum; e++) begin
      stb_ent_ok[e] = CacheStoreUpdate && mshr_d_valid[e] && !alloc_inflight[e] &&
                      (mshr_d[e].state == MSHR_CACHED);
    end

    // ------------------------------------------------------------
    // request path: merge loads, allocate MSHR, or bypass to NoC
    // ------------------------------------------------------------
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        if (req_in_valid[tile_i][port_i]) begin
          // default tag 0 (= no MSHR entry / bypass); overwritten with (entry id + 1) on alloc.
          req_out[tile_i][port_i].mshr_tag = '0;
          // One write, from the re-associated form; the branches below decide req_in_ready and the
          // payload only.
          req_out_valid[tile_i][port_i] = req_out_use[tile_i][port_i];
          if (req_in[tile_i][port_i].wdata.amo != '0) begin
            req_out[tile_i][port_i].burst_len = BurstLenWidth'(1);
          end
          if (req_merge_valid[tile_i][port_i]) begin
            // Merge hit: accept without touching NoC. Capacity was decided per way alongside
            // req_hit_way and selected with it, so no entry array is read at the selected id here.
            // The merge itself is RECORDED by the arbiter; the apply runs once per bank after this
            // loop closes, so no lane reads what an earlier lane wrote.
            // req_merge_ready implies capacity now that it is part of the arbiter's candidate,
            // so the explicit test is redundant and only lengthened the ready output.
            req_in_ready[tile_i][port_i] = req_merge_ready[tile_i][port_i];
          end else if (req_merge_pool_valid[tile_i][port_i]) begin
            // POOL merge hit: accept it exactly as a banked merge. WITHOUT THIS ARM a request that
            // hits a pool entry is a deadlock -- req_hit_mshr is set (the pool hit is folded in, which
            // correctly blocks allocation) while req_merge_valid is not, so the lane falls through to
            // STALL/ALLOCATE/BYPASS, cannot allocate because it reads as a hit, and stalls forever.
            // The pool arbiter had already recorded the merge, so the requestor was never told ready
            // while its subscriber was added anyway. That is why three earlier fixes downstream of
            // this point never moved the failure: the lane never got past here.
            req_in_ready[tile_i][port_i] = req_merge_pool_ready[tile_i][port_i];
          end else begin
            // Not a merge into a resident entry: decide STALL / ALLOCATE / BYPASS.
            if (req_can_merge[tile_i][port_i] &&
                req_addr_hit_drain[tile_i][port_i]) begin
              // A same-address entry is draining: wait for it.
              req_in_ready[tile_i][port_i]  = 1'b0;
            end else if (req_can_merge[tile_i][port_i] && !req_alloc_found[tile_i][port_i] &&
                         !req_alloc_found_pool[tile_i][port_i] &&
                         (bank_has_free[req_bank[tile_i][port_i]] || cfg_bankfull_bp)) begin
              // Mergeable miss that lost this bank's single allocation slot this cycle, but a free
              // way exists: STALL and retry. A POOL grant suppresses the stall -- that is the whole
              // escape: with the bank full under backpressure this is the arm a bank-full miss
              // would otherwise wedge in, waiting for a cohort peer that can never allocate.
              req_in_ready[tile_i][port_i]  = 1'b0;
            end else begin
              // ALLOCATE (won the per-bank slot) or BYPASS (non-mergeable store/AMO, or a
              // mergeable miss whose bank is full): forward this request to the NoC.
              if ((((req_len[tile_i][port_i] == BurstLenWidth'(1)) ?
                     cfg_hold_window_single : cfg_hold_window_burst) != 0) &&
                  req_can_merge[tile_i][port_i] &&
                  (req_alloc_found[tile_i][port_i] ||
                   req_alloc_found_pool[tile_i][port_i])) begin
                // Hold-the-fetch: allocate the entry but WITHHOLD its NoC fetch (the replay walker
                // below issues it once hold_done). Consume the request locally so the door never
                // couples to NoC readiness and never head-of-line-blocks the tile port.
                req_in_ready[tile_i][port_i]  = 1'b1;
              end else begin
                req_in_ready[tile_i][port_i]  = req_out_ready[tile_i][port_i];
              end
              if (req_can_merge[tile_i][port_i]) begin
                // Allocate a new MSHR entry (only the bank's slot winner has req_alloc_found set;
                // Bank-full mergeable misses fall through here as a plain bypass).
                if ((req_alloc_found[tile_i][port_i] ||
                     req_alloc_found_pool[tile_i][port_i]) &&
                    req_in_ready[tile_i][port_i]) begin
                // stamp the egress NoC request with (allocated entry id + 1) so the returning
                // response routes back to this entry by direct index (tag 0 stays the bypass
                // sentinel).
                // Per-LANE output, so it stays here.
                // A POOL allocation takes its tag from the range above the banked table, which the
                // receiver decodes back to a pool index. The field is MshrTagWidth =
                // idx_width(MshrNum+1) wide, so at 64 banked entries it holds tags 1..64 for the
                // table and 65..(64+K) for the pool without widening.
                req_out[tile_i][port_i].mshr_tag =
                    req_alloc_found[tile_i][port_i]
                      ? (MshrTagWidth'(req_alloc_found_mshr_id[tile_i][port_i]) + MshrTagWidth'(1))
                      : (MshrTagWidth'(MshrNum) + MshrTagWidth'(1) +
                         MshrTagWidth'(req_alloc_found_pool_id[tile_i][port_i]));
                // RR victim advance: firing on a still-valid CACHED way IS a reclaim -- move that
                // bank's scan start just past the evicted way.
                // The victim pointer belongs to the BANKED table: a pool allocation reclaims
                // nothing from a bank, so it must not advance any bank's scan start.
                if (req_alloc_found[tile_i][port_i] && CacheVictimRR && CacheReclaimable) begin
                  evict_vid = int'(req_alloc_found_mshr_id[tile_i][port_i]);
                  evict_vw  = WaysPow2 ? VictimPtrW'(evict_vid & unsigned'(MshrWaysPerBank - 1))
                                       : VictimPtrW'(evict_vid % MshrWaysPerBank);
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
            if (CacheStoreUpdate && EnableRespCache && !amo_invalidate &&
                req_is_store[tile_i][port_i] &&
                (req_len[tile_i][port_i] == BurstLenWidth'(1)) &&
                req_in_ready[tile_i][port_i]) begin
              // Bank-scoped: a store can only hit a CACHED entry in its OWN bank, so only this
              // request's MshrWaysPerBank ways are examined and hit_e reconstructs the absolute id.
              for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
                cache_hit_e =
                    int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i;
                // Both terms are one bit selected on req_bank, not a state mux plus a compare.
                if (stb_ent_ok[cache_hit_e] && req_addr_hit_way[tile_i][port_i][way_i]) begin
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

    // -------------------------------------------------------------------------------------------
    // POOL allocation apply. One iteration per pool entry, and at most ONE can be in flight in a
    // cycle because the pool arbiter grants a single allocation per cycle -- so, as with the banked
    // loop, these writes need no ordering between them.
    // -------------------------------------------------------------------------------------------
    for (int p = 0; p < PoolNum; p++) begin
      if (pool_alloc_inflight[p]) begin
        pool_alloc_set[p] = 1'b1;
        pool_d[p]       = '0;
        pool_wr_all[p]  = 1'b1;
        // The staged record carries no way: the pool entry is whichever one the free-entry lookup
        // returned, and apb_q_way holds exactly that.
        pool_d[p].base_addr    = apb_q_addr;
        pool_d[p].tgt_group_id = apb_q_grp;
        pool_d[p].burst_len    = apb_q_len;
        pool_d[p].state        = MSHR_WAIT_RESP;
        pool_d[p].cacheable    = 1'b1;
        pool_d[p].beats_left   = apb_q_len;
        pool_d[p].beat_pending  = '0;
        pool_d[p].beat_pending2 = '0;
        pool_d[p].beat2_armed   = 1'b0;
`ifndef TARGET_SYNTHESIS
        pool_d[p].beat_seen = '0;
        pool_d[p].beat_done = '0;
`endif
        pool_d[p].sub_reqs[0].valid        = 1'b1;
        pool_d[p].sub_reqs[0].tile_id      = apb_q_tile;
        pool_d[p].sub_reqs[0].port_id      = apb_q_port;
        pool_d[p].sub_reqs[0].core_id      = apb_q_core;
        pool_d[p].sub_reqs[0].meta_id_base = apb_q_meta;
`ifndef TARGET_SYNTHESIS
        pool_d[p].cache_hit_cnt = '0;
`endif
        // Hold-the-fetch: the SAME per-type window a banked entry arms. A pool entry is not a
        // fast path -- it coalesces exactly like the rest of the table, which is what keeps the
        // cohort together when one of its members lands here.
        pool_d[p].hold_cnt =
            hold_ticks((apb_q_len == BurstLenWidth'(1)) ?
                       cfg_hold_window_single : cfg_hold_window_burst);
        pool_d[p].issued =
            (((apb_q_len == BurstLenWidth'(1)) ?
              cfg_hold_window_single : cfg_hold_window_burst) == 0);
        pool_d[p].sub_reqs_num = SubReqCountW'(1);
        pool_d[p].served_cnt   = ServedCntW'(1);
      end
    end

    // -------------------------------------------------------------------------------------------
    // POOL merge apply: the twin of the banked merge above, on the pool's own staged record.
    // -------------------------------------------------------------------------------------------
    for (int p = 0; p < PoolNum; p++) begin
      if (pool_merge_inflight[p]) begin
        pmb_slot = MergeRankW'(pool_q[p].sub_reqs_num);
        pool_id_we[p] = 1'b1;
        pool_d[p].sub_reqs[pmb_slot].valid        = 1'b1;
        pool_d[p].sub_reqs[pmb_slot].tile_id      = mpb_q_tile;
        pool_d[p].sub_reqs[pmb_slot].port_id      = mpb_q_port;
        pool_d[p].sub_reqs[pmb_slot].core_id      = mpb_q_core;
        pool_d[p].sub_reqs[pmb_slot].meta_id_base = mpb_q_meta;
        pool_d[p].sub_reqs_num = SubReqCountW'(pmb_slot + MergeRankW'(1));
        // Same reasoning as the banked form: the entry may have turned DRAIN_RESP between the
        // decision and now, and the head seed is skipped when beat_pending is already set, so this
        // subscriber would otherwise never be drained.
        if (pool_q[p].state == MSHR_DRAIN_RESP) begin
          pool_d[p].beat_pending[pmb_slot] = 1'b1;
          if (PD2 && pool_q[p].beat2_armed) pool_d[p].beat_pending2[pmb_slot] = 1'b1;
        end
        pool_d[p].served_cnt   = pool_q[p].served_cnt + ServedCntW'(1);
`ifndef TARGET_SYNTHESIS
        if (EnableRespCache && (pool_q[p].state == MSHR_CACHED)) begin
          pool_d[p].cache_hit_cnt = pool_d[p].cache_hit_cnt + 1'b1;
        end
`endif
        if (EnableRespCache && (pool_q[p].state == MSHR_CACHED)) begin
          pool_d[p].state         = MSHR_DRAIN_RESP;
          pool_d[p].beats_left    = BurstLenWidth'(1);
          pool_d[p].beat_pending  = '0;
          pool_d[p].beat_pending2 = '0;
          pool_d[p].beat2_armed   = 1'b0;
`ifndef TARGET_SYNTHESIS
          pool_d[p].beat_seen     = '0;
          pool_d[p].beat_seen[0]  = 1'b1;
          pool_d[p].beat_done     = '0;
`endif
        end else if (RespWaitSubsSingle &&
                     (pool_q[p].state == MSHR_RESP_HOLD) &&
                     ((pmb_slot + MergeRankW'(1)) >=
                      SubReqCountW'(cfg_hold_subs_single))) begin
          pool_d[p].state         = MSHR_DRAIN_RESP;
          pool_d[p].beats_left    = BurstLenWidth'(1);
          pool_d[p].beat_pending  = '0;
          pool_d[p].beat_pending2 = '0;
          pool_d[p].beat2_armed   = 1'b0;
`ifndef TARGET_SYNTHESIS
          pool_d[p].beat_seen     = '0;
          pool_d[p].beat_seen[0]  = 1'b1;
          pool_d[p].beat_done     = '0;
`endif
        end
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
        stb_bytes[e][b] = CacheStoreUpdate && (|stb_byte_req[e][b]);
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

    // Apply each pool entry's byte winners once, retaining untouched bytes and beat metadata.
    for (int p = 0; p < PoolNum; p++) begin
      for (int b = 0; b < StrbW; b++) begin
        if (pool_stb_bytes[p][b]) begin
          pool_d[p].resp_buf[pool_q[p].resp_buf_rd_ptr].data[b*8 +: 8] =
              pool_stb_byte_data[p][b];
        end
      end
      if (|pool_stb_bytes[p]) pool_rb_we[p][pool_q[p].resp_buf_rd_ptr] = 1'b1;
    end

    // Replay withheld fetches once their hold window expires or their cohort is complete.
    if (HoldWindowMax != 0) begin
      // Step 1: hold-done and owner lane per ENTRY -- lane-independent, so computed once
      // instead of re-derived inside a chain.
      for (int e = 0; e < MshrNum; e++) begin
        // Elaboration-constant select: one arm is built, and at ReplayFromQ = 0 every term is
        // literally the mshr_d expression it replaced.
        replay_scan_valid[e] = ReplayFromQ ? mshr_q_valid[e] : mshr_d_valid[e];
        replay_scan_ent[e]   = ReplayFromQ ? mshr_q[e]       : mshr_d[e];
        replay_ready[e] = replay_scan_valid[e] && (replay_scan_ent[e].state == MSHR_WAIT_RESP) &&
                          !replay_scan_ent[e].issued && !replay_pending[e] &&
                          ((replay_scan_ent[e].hold_cnt == '0) ||
                           (replay_scan_ent[e].sub_reqs_num >=
                            SubReqCountW'((replay_scan_ent[e].burst_len == BurstLenWidth'(1)) ?
                                          cfg_hold_subs_single : cfg_hold_subs_burst)));
        replay_payload[e].meta = replay_scan_ent[e].sub_reqs[0].meta_id_base;
        replay_payload[e].core = replay_scan_ent[e].sub_reqs[0].core_id;
        replay_payload[e].grp  = replay_scan_ent[e].tgt_group_id;
        replay_payload[e].addr = replay_scan_ent[e].base_addr;
        replay_payload[e].len  = replay_scan_ent[e].burst_len;
        replay_payload[e].idx  = MshrIdxW'(e);
        replay_own_t[e] = replay_scan_ent[e].sub_reqs[0].tile_id;
        replay_own_p[e] = replay_scan_ent[e].sub_reqs[0].port_id;
        replay_rr_mask[e] = MshrIdxW'(e) >= MshrIdxW'(hold_replay_rr_q);
      end
      // POOL equivalents, the same hold-done test. No rotation mask: the pool is at most a couple
      // of entries and each is owned by one lane, so there is nothing to rotate over.
      pool_replay_issue = '0;
      for (int p = 0; p < PoolNum; p++) begin
        pool_replay_scan_valid[p] = ReplayFromQ ? pool_q_valid[p] : pool_d_valid[p];
        pool_replay_scan_ent[p]   = ReplayFromQ ? pool_q[p]       : pool_d[p];
        pool_replay_ready[p] = pool_replay_scan_valid[p] &&
                               (pool_replay_scan_ent[p].state == MSHR_WAIT_RESP) &&
                               !pool_replay_scan_ent[p].issued &&
                               ((pool_replay_scan_ent[p].hold_cnt == '0) ||
                                (pool_replay_scan_ent[p].sub_reqs_num >=
                                 SubReqCountW'((pool_replay_scan_ent[p].burst_len == BurstLenWidth'(1)) ?
                                               cfg_hold_subs_single : cfg_hold_subs_burst)));
        pool_replay_own_t[p] = pool_replay_scan_ent[p].sub_reqs[0].tile_id;
        pool_replay_own_p[p] = pool_replay_scan_ent[p].sub_reqs[0].port_id;
      end
      // Step 2: each lane picks its own winner, in parallel. Lanes are disjoint by construction
      // (one owner lane per entry), so no lane can steal another's candidate.
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
          // Everything the replay needs is precomputed in gen_replay_lane; the ready chain only
          // reaches this final select, instead of the candidate scan, the isolate and the payload
          // OR that used to sit behind it.
          if (replay_fire[t][p]) begin
            req_out_valid[t][p]               = 1'b1;
            req_out[t][p]                     = '0;
            req_out[t][p].wdata.meta_id       = replay_sel_l[t][p].meta;
            req_out[t][p].wdata.core_id       = replay_sel_l[t][p].core;
            req_out[t][p].wen                 = 1'b0;
            req_out[t][p].be                  = '1;
            req_out[t][p].tgt_group_id        = replay_sel_l[t][p].grp;
            req_out[t][p].tgt_addr            = replay_sel_l[t][p].addr;
            req_out[t][p].burst_len           = replay_sel_l[t][p].len;
            req_out[t][p].mshr_tag            = MshrTagWidth'(replay_sel_l[t][p].idx) + MshrTagWidth'(1);
          end
          // POOL replay for this lane, only when the banked walker did not already use the lane AND
          // the lane is actually available for a replay. The availability test is load-bearing:
          // replay_fire is 0 for a lane carrying a fresh, accepted request, and driving that lane
          // would replace the request's own fetch with the replay's, losing the request and
          // stranding the entry it was allocating. The owner lane is the entry's own owner, so lanes
          // stay disjoint exactly as they do for the banked walker.
          if (!replay_fire[t][p] && replay_lane_avail[t][p] && req_out_ready[t][p]) begin
            pool_replay_win = '0;
            pool_replay_any = 1'b0;
            for (int q = 0; q < PoolNum; q++) begin
              if (!pool_replay_any && pool_replay_ready[q] &&
                  (pool_replay_own_t[q] == tile_group_id_t'(t)) &&
                  (pool_replay_own_p[q] == RespPortIdW'(p))) begin
                pool_replay_any     = 1'b1;
                pool_replay_win     = PoolIdxW'(q);
                pool_replay_issue[q] = 1'b1;
              end
            end
            if (pool_replay_any) begin
              req_out_valid[t][p]         = 1'b1;
              req_out[t][p]               = '0;
              req_out[t][p].wdata.meta_id =
                  pool_replay_scan_ent[pool_replay_win].sub_reqs[0].meta_id_base;
              req_out[t][p].wdata.core_id =
                  pool_replay_scan_ent[pool_replay_win].sub_reqs[0].core_id;
              req_out[t][p].wen           = 1'b0;
              req_out[t][p].be            = '1;
              req_out[t][p].tgt_group_id  = pool_replay_scan_ent[pool_replay_win].tgt_group_id;
              req_out[t][p].tgt_addr      = pool_replay_scan_ent[pool_replay_win].base_addr;
              req_out[t][p].burst_len     = pool_replay_scan_ent[pool_replay_win].burst_len;
              // The SAME pool tag encoding the allocation stamps, so the returning response routes
              // back to this pool entry.
              req_out[t][p].mshr_tag      = MshrTagWidth'(MshrNum) + MshrTagWidth'(1) +
                                            MshrTagWidth'(pool_replay_win);
            end
          end
        end
      end
      // Mark every pool entry whose fetch just went out. Set directly rather than through a
      // pending register: the replay is off the request critical path, and `issued` is what the
      // ready test reads back, so the entry cannot be replayed twice.
      for (int q = 0; q < PoolNum; q++) begin
        if (pool_replay_issue[q]) pool_d[q].issued = 1'b1;
      end
    end

    if (CacheAmoInval && EnableRespCache && amo_invalidate) begin
      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        // From mshr_q: allocation writes MSHR_WAIT_RESP so it can never present CACHED here.
        // An already accepted merge must drain its subscriber. Suppress later
        // re-caching of that word across the AMO; idle cached entries retire.
        if (mshr_q_valid[mshr_i] && (mshr_q[mshr_i].state == MSHR_CACHED)) begin
          if (merge_inflight[mshr_i]) begin
            mshr_d[mshr_i].cacheable = 1'b0;
          end else begin
            mshr_d_valid[mshr_i] = 1'b0;
          end
        end
      end
      // POOL twin: an AMO invalidating a line resident in the pool. Without it the pool entry stays
      // CACHED and stale across the AMO, which is exactly the hazard this pass exists to close.
      for (int p = 0; p < PoolNum; p++) begin
        if (pool_q_valid[p] && (pool_q[p].state == MSHR_CACHED)) begin
          if (pool_merge_inflight[p]) begin
            pool_d[p].cacheable = 1'b0;
          end else begin
            pool_d_valid[p] = 1'b0;
          end
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
            !st_merge_drain[e] &&
            (mshr_q[e].sub_reqs_num == '0) &&
            (mshr_q[e].served_cnt >=
             ((cfg_cache_reuse_target != '0)
                ? ServedCntW'(cfg_cache_reuse_target)
                : ServedCntW'((mshr_q[e].burst_len == BurstLenWidth'(1)) ? cfg_hold_subs_single : cfg_hold_subs_burst)))) begin
          mshr_d_valid[e] = 1'b0;
          // Retire by dropping valid only (see the first retire site for why).
        end
      end
      // POOL twin of the self-invalidate above, with the same merge veto: a merge into a CACHED
      // pool entry sets DRAIN_RESP and bumps served_cnt, so retiring it would lose that subscriber.
      for (int p = 0; p < PoolNum; p++) begin
        if (pool_q_valid[p] && (pool_q[p].state == MSHR_CACHED) &&
            !pool_st_merge_drain[p] &&
            (pool_q[p].sub_reqs_num == '0) &&
            (pool_q[p].served_cnt >=
             ((cfg_cache_reuse_target != '0)
                ? ServedCntW'(cfg_cache_reuse_target)
                : ServedCntW'((pool_q[p].burst_len == BurstLenWidth'(1)) ? cfg_hold_subs_single : cfg_hold_subs_burst)))) begin
          pool_d_valid[p] = 1'b0;
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
          // Same upper bound as the rsn_* twin above, for the same reason: resp_tag_cand is
          // mshr_id_t and a pool tag would truncate onto banked entry 0.
          if ((resp_in[tile_i][port_i].mshr_tag != '0) &&
              (resp_in[tile_i][port_i].mshr_tag <= MshrTagWidth'(MshrNum))) begin
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
        end else if (psn_v[tile_i][port_i]) begin
          resp_capture_beat_offset[tile_i][port_i] =
              burst_beat_of(resp_in[tile_i][port_i].rdata.core_id,
                            resp_in[tile_i][port_i].rdata.meta_id,
                            pool_q[psn_id[tile_i][port_i]].sub_reqs[0].core_id,
                            pool_q[psn_id[tile_i][port_i]].sub_reqs[0].meta_id_base);
        end else begin
          // Bypass ready, for a lane that is neither a banked MSHR beat nor a pool beat. The
          // !psn_v guard is what keeps this mutually exclusive with the pool arm further down
          // (which assigns the same variable): without it the pool lane was assigned here and
          // again there, and correctness rested on the pool arm happening to come later in the
          // always_comb. One assignment per lane, order-independent.
          resp_in_ready[tile_i][port_i] = resp_out_ready[tile_i][port_i];
        end

        // !psn_v, not just !resp_is_mshr. A POOL-tagged response also has resp_is_mshr = 0 --
        // that term is the BANKED classification, whose upper bound at MshrNum is exactly what
        // keeps a pool tag from truncating onto banked entry 0. So without this second term a
        // pool beat is captured by the pool's own ready arm below AND forwarded here in the same
        // cycle: resp_out carries the raw MSHR tag, the core sees an id it never issued
        // (snitch_lsu.sv "Response ID does not match with valid metadata"), and the cohort's beat
        // is delivered twice. The ready arm alone was not enough -- it fixes what the lane
        // accepts, this fixes what the lane emits.
        if (resp_in_valid[tile_i][port_i] && !resp_is_mshr[tile_i][port_i] &&
            !psn_v[tile_i][port_i]) begin
          resp_out_valid[tile_i][port_i] = 1'b1;
          resp_out[tile_i][port_i] = resp_in[tile_i][port_i];
          // NO RETAG: a bypassed burst is expanded at the DESTINATION tile, which applies the
          // lane law there relative to this requester's own core_id/meta_id.
          resp_from_bypass[tile_i][port_i] = 1'b1;
        end
      end
    end

    // Grant response slots per ENTRY, then capture once per entry.
    cap_want      = '0;
    capb_want_l   = '0;
    cap_way_col   = '0;
    pool_cap_want = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        // The lane index belongs to both tag classes, including a cycle with only pool beats.
        cap_lane = RespLaneW'(tile_i * NumRespPortsActive + (port_i - 1));
        // resp_is_mshr and psn_v each imply a valid response.
        if (resp_is_mshr[tile_i][port_i]) begin
          cap_want[resp_mshr_id[tile_i][port_i]][cap_lane] = 1'b1;
          // Same fact on the two axes the arbiter actually uses: a bank compare instead of an OR
          // over that bank's rows, and a way compare instead of a row lookup.
          capb_want_l[int'(resp_mshr_id[tile_i][port_i]) / MshrWaysPerBank][cap_lane] = 1'b1;
          for (int w = 0; w < MshrWaysPerBank; w++) begin
            if ((int'(resp_mshr_id[tile_i][port_i]) % MshrWaysPerBank) == w) begin
              cap_way_col[w][cap_lane] = 1'b1;
            end
          end
        end else if (psn_v[tile_i][port_i]) begin
          // Pool beat: indexed by the POOL id, never through resp_mshr_id, which is mshr_id_t and
          // cannot represent it.
          pool_cap_want[psn_id[tile_i][port_i]][cap_lane] = 1'b1;
        end
      end
    end
    if (CapPerBank) begin
      // One arbiter per bank over the union of its ways' wanters.
      for (int b = 0; b < MshrBankNum; b++) begin
        capb_want[b] = capb_want_l[b];
        capb_l1[b] = capb_want[b] & (~capb_want[b] + NumRespLanes'(1));
        capb_rest  = capb_want[b] & ~capb_l1[b];
        capb_l2[b] = capb_rest    & (~capb_rest    + NumRespLanes'(1));
        // cap_want[e] is the set of lanes targeting entry e, so intersecting it with the granted
        // lane names the way directly -- one-hot, because a lane targets exactly one entry.
        for (int w = 0; w < MshrWaysPerBank; w++) begin
          // From the tree: it named the winner's way with the winner, so no 32-wide recovery.
          capb_l1_way  [b][w] = capt_v1[b][CapStages][0] &&
                                (capt_w1[b][CapStages][0] == VictimPtrW'(w));
          capb_l2_way  [b][w] = capt_v2[b][CapStages][0] &&
                                (capt_w2[b][CapStages][0] == VictimPtrW'(w));
          capb_slot_ge1[b][w] =
              (mshr_resp_slots[b * MshrWaysPerBank + w] >= RespBufCountW'(1));
          capb_slot_ge2[b][w] =
              (mshr_resp_slots[b * MshrWaysPerBank + w] >= RespBufCountW'(2));
`ifndef TARGET_SYNTHESIS
          capb_l1_way_ref[b][w] = |(capb_l1[b] & cap_way_col[w]);
          capb_l2_way_ref[b][w] = |(capb_l2[b] & cap_way_col[w]);
`endif
        end
        // Both grants on the same way is the same entry. Only read under capb_l2 != 0, where both
        // one-hots are populated -- the old id compare needed the same guard, since the ids
        // defaulted to 0.
        // The credits travelled with the winners, so the grants are one AND each.
        capb_same[b] = capt_w1[b][CapStages][0] == capt_w2[b][CapStages][0];
        capb_g1[b]   = capt_v1[b][CapStages][0] && capt_a1[b][CapStages][0];
        capb_g2[b]   = capt_v2[b][CapStages][0] &&
                       (capb_same[b] ? capt_a2[b][CapStages][0] : capt_b1[b][CapStages][0]);
`ifndef TARGET_SYNTHESIS
        capb_same_ref[b] = |(capb_l1_way_ref[b] & capb_l2_way_ref[b]);
        capb_g1_ref[b] = (capb_l1[b] != '0) && |(capb_l1_way_ref[b] & capb_slot_ge1[b]);
        capb_g2_ref[b] = (capb_l2[b] != '0) &&
                         (capb_same_ref[b] ? |(capb_l1_way_ref[b] & capb_slot_ge2[b])
                                           : |(capb_l2_way_ref[b] & capb_slot_ge1[b]));
`endif
      end
      // Map back onto the per-entry vectors the rest of the pass reads, so nothing downstream
      // changes. The guards matter: a bank with no wanter must not write entry 0 and clobber
      // bank 0's grant, since capb_e* default to 0.
      cap_first  = '0;
      cap_second = '0;
      cap_g1     = '0;
      cap_g2     = '0;
      for (int b = 0; b < MshrBankNum; b++) begin
        for (int w = 0; w < MshrWaysPerBank; w++) begin
          if ((capb_l1[b] != '0) && capb_l1_way[b][w]) begin
            cap_first[b * MshrWaysPerBank + w] = capb_l1[b];
            cap_g1   [b * MshrWaysPerBank + w] = capb_g1[b];
          end
          if ((capb_l2[b] != '0) && capb_l2_way[b][w]) begin
            if (capb_same[b]) begin
              cap_second[b * MshrWaysPerBank + w] = capb_l2[b];
              cap_g2    [b * MshrWaysPerBank + w] = capb_g2[b];
            end else begin
              cap_first[b * MshrWaysPerBank + w] = capb_l2[b];
              cap_g1   [b * MshrWaysPerBank + w] = capb_g2[b];
            end
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
    // POOL grants: the non-banked shape, one two-lane grant per pool entry, from that entry's own
    // want vector and its own admission credits.
    pool_cap_first  = '0;
    pool_cap_second = '0;
    pool_cap_g1     = '0;
    pool_cap_g2     = '0;
    for (int p = 0; p < PoolNum; p++) begin
      pool_cap_first[p]  = pool_cap_want[p] & (~pool_cap_want[p] + NumRespLanes'(1));
      pool_cap_rest     = pool_cap_want[p] & ~pool_cap_first[p];
      pool_cap_second[p] = pool_cap_rest    & (~pool_cap_rest    + NumRespLanes'(1));
      pool_cap_g1[p] = (pool_cap_first[p]  != '0) && (pool_resp_slots[p] >= RespBufCountW'(1));
      pool_cap_g2[p] = (pool_cap_second[p] != '0) && (pool_resp_slots[p] >= RespBufCountW'(2));
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
        end else if (psn_v[tile_i][port_i]) begin
          // A POOL beat takes its own ready arm. Without it the lane would fall through to the
          // bypass branch below and the beat would be forwarded to the requester instead of
          // buffered -- correct-looking, and wrong: the coalesced cohort would never receive it.
          cap_lane = RespLaneW'(tile_i * NumRespPortsActive + (port_i - 1));
          resp_in_ready[tile_i][port_i] =
              (pool_cap_first [psn_id[tile_i][port_i]][cap_lane] && pool_cap_g1[psn_id[tile_i][port_i]]) ||
              (pool_cap_second[psn_id[tile_i][port_i]][cap_lane] && pool_cap_g2[psn_id[tile_i][port_i]]);
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
          if (!psn_v[tile_i][port_i]) begin
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
        if (RespWaitSubsSingle && !amo_inval_guard &&
            (mshr_q[e].burst_len == BurstLenWidth'(1)) &&
            (mshr_d[e].sub_reqs_num < SubReqCountW'(cfg_hold_subs_single))) begin
          mshr_d[e].state    = MSHR_RESP_HOLD;
          mshr_d[e].hold_cnt = hold_ticks(cfg_serve_timeout);
        end else begin
          mshr_d[e].state    = MSHR_DRAIN_RESP;
        end
      end
    end

    // -------------------------------------------------------------------------------------------
    // POOL capture apply: the twin of the banked apply above, one write per pool entry. Same slot
    // order, same saturating count, same RESP_HOLD-versus-DRAIN_RESP decision.
    // -------------------------------------------------------------------------------------------
    for (int p = 0; p < PoolNum; p++) begin
      if (pool_cap_g1[p] || pool_cap_g2[p]) begin
        cap_s0 = pool_q[p].resp_buf_wr_ptr;
        cap_n0 = (RespBufWords > 1) ?
                 ((cap_s0 == RespBufPtrW'(RespBufWords - 1)) ? '0 : RespBufPtrW'(cap_s0 + 1'b1))
                 : cap_s0;
        cap_s1 = cap_n0;
        cap_n1 = (RespBufWords > 1) ?
                 ((cap_s1 == RespBufPtrW'(RespBufWords - 1)) ? '0 : RespBufPtrW'(cap_s1 + 1'b1))
                 : cap_s1;
        if (pool_cap_g1[p]) begin
          pool_rb_we[p][cap_s0]      = 1'b1;
          pool_d[p].resp_buf[cap_s0] = pool_cap_d0[p];
        end
        if (pool_cap_g2[p]) begin
          pool_rb_we[p][cap_s1]      = 1'b1;
          pool_d[p].resp_buf[cap_s1] = pool_cap_d1[p];
        end
        cap_cnt_sum = RespBufCountW'(pool_q[p].resp_buf_cnt)
                    + RespBufCountW'(pool_cap_g1[p]) + RespBufCountW'(pool_cap_g2[p]);
        pool_d[p].resp_buf_cnt = (cap_cnt_sum > RespBufCountW'(RespBufWords))
                               ? RespBufCountW'(RespBufWords) : cap_cnt_sum;
        pool_d[p].resp_buf_wr_ptr = pool_cap_g2[p] ? cap_n1 : cap_n0;
        // Same RESP_HOLD decision as the banked form, from pool_q and pool_d resp_buf_cnt.
        if (RespWaitSubsSingle && !amo_inval_guard &&
            (pool_q[p].burst_len == BurstLenWidth'(1)) &&
            (pool_d[p].sub_reqs_num < SubReqCountW'(cfg_hold_subs_single))) begin
          pool_d[p].state    = MSHR_RESP_HOLD;
          pool_d[p].hold_cnt = hold_ticks(cfg_serve_timeout);
        end else begin
          pool_d[p].state    = MSHR_DRAIN_RESP;
        end
      end
    end
    // The pool twin of st_post_cap, from pool_q plus the capture's own fire term.
    pool_st_cap_fire = '0;
    pool_st_post_cap = '{default: MSHR_IDLE};
    for (int p = 0; p < PoolNum; p++) begin
      pool_st_cap_fire[p] = pool_cap_g1[p] | pool_cap_g2[p];
      pool_st_post_cap[p] = pool_st_cap_fire[p]
                          ? ((RespWaitSubsSingle && !amo_inval_guard &&
                              (pool_q[p].burst_len == BurstLenWidth'(1)) &&
                              (pool_d[p].sub_reqs_num < SubReqCountW'(cfg_hold_subs_single)))
                               ? MSHR_RESP_HOLD : MSHR_DRAIN_RESP)
                          : (pool_alloc_inflight[p] ? MSHR_WAIT_RESP
                             : (pool_st_merge_drain[p] ? MSHR_DRAIN_RESP : pool_q[p].state));
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
      st_cap_hold[e] = st_cap_fire[e] && RespWaitSubsSingle && !amo_inval_guard &&
                       (mshr_q[e].burst_len == BurstLenWidth'(1)) &&
                       (mshr_d[e].sub_reqs_num < SubReqCountW'(cfg_hold_subs_single));
      st_post_cap[e] = st_cap_fire[e]
                     ? (st_cap_hold[e]    ? MSHR_RESP_HOLD : MSHR_DRAIN_RESP)
                     : (st_alloc_fire[e]  ? MSHR_WAIT_RESP
                     : (st_merge_drain[e] ? MSHR_DRAIN_RESP : mshr_q[e].state));
      // A staged merge can start draining a previously held response.
      // Coherence must still suppress re-caching that pre-store/AMO word.
      st_hold_post_cap[e] = (mshr_q[e].state == MSHR_RESP_HOLD) ||
                            (st_post_cap[e] == MSHR_RESP_HOLD);
    end

    // A buffered response predates any store/AMO observed after it returned.
    st_force_drain = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        // req_in_ready is written out rather than read, because it COLLAPSES under req_is_store
        // and synthesis cannot see it: is_store implies !is_load implies !req_can_merge, which
        // kills the merge branch and both mergeable-stall branches, and the hold arm needs
        // req_can_merge too -- leaving only the NoC handshake. The general req_in_ready
        // carries both arbiters; req_out_ready does not.
        if (StoreForceDrain &&
            req_in_valid[tile_i][port_i] && req_is_store[tile_i][port_i] &&
            req_out_ready[tile_i][port_i] &&
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
            // A draining buffered word also predates the accepted store.
            // Keep its pending beat bookkeeping; only prevent later re-caching.
            if (req_addr_hit_way[tile_i][port_i][way_i] &&
                (st_post_cap[cache_hit_e] == MSHR_DRAIN_RESP)) begin
              mshr_d[cache_hit_e].cacheable = 1'b0;
            end
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
    for (int p = 0; p < PoolNum; p++) begin
      // Stores may arrive while a buffered scalar is already draining.
      // Suppress re-caching without resetting an outstanding response beat.
      if (StoreForceDrain && (pool_st_post_cap[p] == MSHR_DRAIN_RESP)) begin
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int rp = 1; rp < NumRemoteReqPortsPerTile; rp++) begin
            if (pool_addr_hit_way[t][rp][p] && req_in_valid[t][rp] &&
                req_is_store[t][rp] &&
                req_out_ready[t][rp] && (req_len[t][rp] == BurstLenWidth'(1))) begin
              pool_d[p].cacheable = 1'b0;
            end
          end
        end
      end
      if (pool_st_force_drain[p]) begin
        pool_d[p].state = MSHR_DRAIN_RESP;
        pool_d[p].cacheable = 1'b0;
        pool_d[p].beats_left = BurstLenWidth'(1);
        pool_d[p].beat_pending = '0;
        pool_d[p].beat_pending2 = '0;
        pool_d[p].beat2_armed = 1'b0;
`ifndef TARGET_SYNTHESIS
        pool_d[p].beat_seen = '0;
        pool_d[p].beat_seen[0] = 1'b1;
        pool_d[p].beat_done = '0;
`endif
      end
    end
    if (CacheAmoInval && amo_invalidate) begin
      // Invalidation is persistent even if capture/merge already started drain.
      // Leave response state and pending beat ownership to their existing passes.
      for (int e = 0; e < MshrNum; e++) begin
        if (mshr_d_valid[e]) mshr_d[e].cacheable = 1'b0;
      end
      for (int p = 0; p < PoolNum; p++) begin
        if (pool_d_valid[p]) pool_d[p].cacheable = 1'b0;
      end
      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        // From mshr_q + st_post_cap. Under amo_invalidate the capture cannot write MSHR_RESP_HOLD
        // (st_cap_hold carries !amo_invalidate), so the only remaining writer is the store
        // force-drain, which writes this identical field set -- re-firing is idempotent.
        // mshr_d_valid == mshr_q_valid for a RESP_HOLD entry: both retires above are CACHED-gated.
        if (mshr_q_valid[mshr_i] &&
            ((mshr_q[mshr_i].state == MSHR_RESP_HOLD) ||
             (st_post_cap[mshr_i] == MSHR_RESP_HOLD))) begin
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
      // POOL twin. A pool entry held in RESP_HOLD across an AMO would otherwise deliver the
      // pre-AMO word to its subscribers -- the stale-read hazard this pass exists to close. Same
      // field set, and the same re-fire idempotence argument as above.
      for (int p = 0; p < PoolNum; p++) begin
        if (pool_q_valid[p] &&
            ((pool_q[p].state == MSHR_RESP_HOLD) ||
             (pool_st_post_cap[p] == MSHR_RESP_HOLD))) begin
          pool_d[p].state         = MSHR_DRAIN_RESP;
          pool_d[p].cacheable     = 1'b0;
          pool_d[p].beats_left    = BurstLenWidth'(1);
          pool_d[p].beat_pending  = '0;
          pool_d[p].beat_pending2 = '0;
          pool_d[p].beat2_armed   = 1'b0;
`ifndef TARGET_SYNTHESIS
          pool_d[p].beat_seen     = '0;
          pool_d[p].beat_seen[0]  = 1'b1;
`endif
`ifndef TARGET_SYNTHESIS
          pool_d[p].beat_done     = '0;
`endif
        end
      end
    end

    // Serve-target timeout (group_mshr_serve_timeout).
    if (cfg_serve_timeout != 0) begin
      for (int e = 0; e < MshrNum; e++) begin
        // Parallel form. MSHR_RESP_HOLD here comes from the capture (st_cap_hold) or from mshr_q,
        // and only the store force-drain and the AMO block can have cleared it -- both run above.
        // !amo_inval_guard covers the latter because that block converts EVERY RESP_HOLD entry --
        // and with CacheAmoInval off it converts none, so there is nothing to cover.
        st_hold_live = mshr_q_valid[e] && (st_post_cap[e] == MSHR_RESP_HOLD) &&
                       !st_force_drain[e] && !amo_inval_guard;
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
                     (st_post_cap[e] == MSHR_CACHED) &&
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

    // POOL twins of the two timeouts above. A pool entry is retired by the same rules, so it cannot
    // pin its entry forever either -- and these are the paths that end a pooled cohort that never
    // completes, exactly as they do for a banked one.
    if (cfg_serve_timeout != 0) begin
      for (int p = 0; p < PoolNum; p++) begin
        st_hold_live = pool_q_valid[p] && (pool_st_post_cap[p] == MSHR_RESP_HOLD) &&
                       !pool_st_force_drain[p] && !amo_inval_guard;
        st_hold_src  = pool_st_cap_fire[p] ? hold_ticks(cfg_serve_timeout) : pool_q[p].hold_cnt;
        if (st_hold_live) begin
          if (st_hold_src != '0) begin
            if (pool_hold_tick[p]) pool_d[p].hold_cnt = st_hold_src - HoldCntW'(1);
          end else begin
`ifndef TARGET_SYNTHESIS
            pool_resp_hold_timeout_dbg[p] = 1'b1;
`endif
            pool_d[p].state         = MSHR_DRAIN_RESP;
            pool_d[p].beats_left    = BurstLenWidth'(1);
            pool_d[p].beat_pending  = '0;
            pool_d[p].beat_pending2 = '0;
            pool_d[p].beat2_armed   = 1'b0;
`ifndef TARGET_SYNTHESIS
            pool_d[p].beat_seen     = '0;
            pool_d[p].beat_seen[0]  = 1'b1;
            pool_d[p].beat_done     = '0;
`endif
          end
        end else if (CacheSelfInval && EnableRespCache && pool_d_valid[p] &&
                     (pool_st_post_cap[p] == MSHR_CACHED) &&
                     (pool_q[p].sub_reqs_num == '0)) begin
          if (pool_q[p].hold_cnt != '0) begin
            if (pool_hold_tick[p]) pool_d[p].hold_cnt = pool_q[p].hold_cnt - HoldCntW'(1);
          end else begin
`ifndef TARGET_SYNTHESIS
            pool_cache_timeout_dbg[p] = 1'b1;
`endif
            pool_d_valid[p] = 1'b0;
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
`ifndef TARGET_SYNTHESIS
      gate_extra[mshr_i] = gate_extra[mshr_i] | (mshr_q_valid[mshr_i] & ~mshr_d_valid[mshr_i]);
`endif
      // mshr_q_valid, not mshr_d_valid: it is registered, so it keeps the request path off this
      // cone, and it is an exact superset here -- the only writer that
      // sets mshr_d_valid runs after this loop, so mshr_d_valid can only be mshr_q_valid minus the
      // retires above. The entries it adds are retiring this cycle; every write below is
      // entry-local and the entry goes invalid, which gate_extra_dead_next_cycle checks.
      if (mshr_q_valid[mshr_i] &&
          (mshr_d[mshr_i].state == MSHR_DRAIN_RESP) &&
          (mshr_d[mshr_i].resp_buf_cnt != '0) &&
          (mshr_d[mshr_i].beat_pending == '0) &&
          (mshr_d[mshr_i].sub_reqs_num != '0)) begin
        for (int s = 0; s < MshrMergeReqs; s++) begin
          mshr_d[mshr_i].beat_pending[s] = mshr_d[mshr_i].sub_reqs[s].valid;
        end
      end
    end

    // POOL head-beat seed, the twin of the banked seed above, and REQUIRED for the same reason: the
    // drain scan gates on beat_pending, so a pool entry that is never seeded never offers a beat --
    // it would be allocated, buffer its response, and hold it forever. Same predicate, pool_d /
    // pool_q in place of the banked arrays, and no gate_extra term (that vector is banked-only and
    // simulation-only).
    for (int p = 0; p < PoolNum; p++) begin
      if (pool_q_valid[p] &&
          (pool_d[p].state == MSHR_DRAIN_RESP) &&
          (pool_d[p].resp_buf_cnt != '0) &&
          (pool_d[p].beat_pending == '0) &&
          (pool_d[p].sub_reqs_num != '0)) begin
        for (int s = 0; s < MshrMergeReqs; s++) begin
          pool_d[p].beat_pending[s] = pool_d[p].sub_reqs[s].valid;
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
    pool_bp_clr = '0; pool_sv_clr = '0;
    drain_fire = '0; drain_fire_sv = '0; drain_fire_sub_oh = '0;
    drain_fire_bank = '0; drain_fire_bank_sv = '0; drain_fire_bank_sub_oh = '0;
    resp_sel_bank_valid = '0; resp_sel_bank_sub_oh = '0;
    drv_bank_burst_one = 1'b0;
`ifndef TARGET_SYNTHESIS
    bp_clr_ref = '0; sv_clr_ref = '0;
`endif
    if (DrainMultiPort) begin
      // Use all available response ports per cycle.
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          // bypass MUST take the port -- bypass responses are non-backpressurable by
          // contract, while MSHR-targeted responses are buffered (resp_buf) and CAN be
          port_taken[tile_i][port_i] = resp_in_valid[tile_i][port_i] &&
                                       !resp_is_mshr[tile_i][port_i] &&
                                       !psn_v[tile_i][port_i];
          resp_sel_valid[tile_i][port_i] = 1'b0;
          resp_sel_mshr_id[tile_i][port_i] = '0;
          resp_sel_pool_valid[tile_i][port_i] = 1'b0;
          resp_sel_pool_id[tile_i][port_i]    = '0;
          resp_sel_subreq_idx[tile_i][port_i] = '0;
          resp_sel_sub_oh[tile_i][port_i]     = '0;
          resp_sel_bank[tile_i][port_i] = '0;
          resp_sel_bank_oh[tile_i][port_i] = '0;
        end
      end
      // One entry published per bank, round-robin and port-independent: computed once here,
      // shared by every (tile,port) instance below.
      for (int e = 0; e < MshrNum; e++) begin
        drain_ent_any[e]   = |drain_sub_ready[e];
        drain_published[e] = 1'b0;          // cleared per ENTRY, never per bank
      end
      for (int b = 0; b < MshrBankNum; b++) begin
        for (int w = 0; w < MshrWaysPerBank; w++) begin
          way_any    [b][w] = drain_ent_any[b * MshrWaysPerBank + w];
          way_rr_mask[b][w] = (VictimPtrW'(w) >= bank_rr_q[b]);
        end
        way_hi[b] = way_any[b] &  way_rr_mask[b];
        way_lo[b] = way_any[b] & ~way_rr_mask[b];
        bank_pub_oh[b] = (|way_hi[b]) ? (way_hi[b] & (~way_hi[b] + MshrWaysPerBank'(1)))
                                      : (way_lo[b] & (~way_lo[b] + MshrWaysPerBank'(1)));
        bank_pub_v[b] = |way_any[b];
        bank_pub_w[b] = '0;
        bank_pub_e[b] = '0;
        bank_rr_d [b] = bank_rr_q[b];
        for (int w = 0; w < MshrWaysPerBank; w++) begin
          bank_pub_w[b] = bank_pub_w[b] | ({VictimPtrW{bank_pub_oh[b][w]}} & VictimPtrW'(w));
          if (bank_pub_oh[b][w]) begin
            // (w + 1) % MshrWaysPerBank is a loop constant: no adder, no wrap compare.
            bank_rr_d[b] = VictimPtrW'((w + 1) % MshrWaysPerBank);
            if (BankPublish) begin
              // The one-hot IS the published-entry mask, so no decode of an index.
              drain_published[b * MshrWaysPerBank + w] = 1'b1;
              bank_pub_e[b] = MshrIdxW'(b * MshrWaysPerBank + w);
            end
          end
        end
      end

      // Publish the winning entry's drive operands per bank, once. b is a loop constant, so each of
      // these is a MshrWaysPerBank:1 select; the drive loop below then selects MshrBankNum:1
      // instead of reading the MshrNum-wide arrays at the winning entry id, in all 32 lanes.
      for (int b = 0; b < MshrBankNum; b++) begin
        pub_drv_data     [b] = drv_data     [b * MshrWaysPerBank + int'(bank_pub_w[b])];
        pub_drv_beat_off [b] = drv_beat_off [b * MshrWaysPerBank + int'(bank_pub_w[b])];
        pub_drv_burst_one[b] = drv_burst_one[b * MshrWaysPerBank + int'(bank_pub_w[b])];
        pub_drv_sub_core [b] = drv_sub_core [b * MshrWaysPerBank + int'(bank_pub_w[b])];
        pub_drv_sub_meta [b] = drv_sub_meta [b * MshrWaysPerBank + int'(bank_pub_w[b])];
        pub_sub_ready    [b] = drain_sub_ready[b * MshrWaysPerBank + int'(bank_pub_w[b])];
        pub_sub_tile     [b] = drain_sub_tile [b * MshrWaysPerBank + int'(bank_pub_w[b])];
        pub_sub_port     [b] = drain_sub_port [b * MshrWaysPerBank + int'(bank_pub_w[b])];
        pub_sub_map      [b] = drain_sub_map  [b * MshrWaysPerBank + int'(bank_pub_w[b])];
      end

      // Select one sub-request per response port.
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          if (!port_taken[tile_i][port_i]) begin
            // RR fairness: rotate the entry visit by drain_mshr_rr and the sub_req
            // visit by subreq_rr (separate bases) so high-index entries/sub_reqs are not starved.
            drain_sel_base     = EnableRrFairness ? MshrIdxW'(drain_mshr_rr_q) : '0;
            drain_sel_sub_base = EnableRrFairness ? SubIdxW'(subreq_rr_q) : '0;
            bank_base = WaysPow2 ? drain_sel_base[MshrIdxW-1 -: BankIdW]
                                 : BankIdW'(int'(drain_sel_base) / MshrWaysPerBank);
            base_way  = WaysPow2 ? drain_sel_base[VictimPtrW-1:0]
                                 : VictimPtrW'(int'(drain_sel_base) % MshrWaysPerBank);
            bank_demote = bank_pub_v[bank_base] && (bank_pub_w[bank_base] < base_way);
            for (int b = 0; b < MshrBankNum; b++) begin
              bank_rr_mask[b] = (BankIdW'(b) >= bank_base);
              bank_hi_mask[b] =  bank_rr_mask[b] & ~(bank_demote && (BankIdW'(b) == bank_base));
              bank_lo_mask[b] = ~bank_rr_mask[b] & ~(bank_demote && (BankIdW'(b) == bank_base));
            end
            // Per-entry: does this entry offer any sub-request eligible for THIS port?
            drain_ent_cand = '0;
            bank_cand      = '0;
            bank_sub_cand  = '0;
            if (BankPublish) begin
              // Evaluate only the MshrBankNum published entries, not all MshrNum -- the
              // per-(tile,port) predicate work drops by MshrWaysPerBank.
              for (int b = 0; b < MshrBankNum; b++) begin
                // A burst entry drains on the parity pin of its head beat, the same port for every
                // sub-request, so the port term leaves the reduce and meets it as one AND. It is
                // also a single bit of beat_off against a constant port, not an add and a compare.
                pub_parity_ok = (RespPortIdW'(1) + RespPortIdW'(pub_drv_beat_off[b][0])) ==
                                port_i[RespPortIdW-1:0];
                for (int s = 0; s < MshrMergeReqs; s++) begin
                  pub_sub_ok[s] = bank_pub_v[b] && pub_sub_ready[b][s] &&
                                  (pub_sub_tile[b][s] == tile_group_id_t'(tile_i));
                end
                if (PD2 && !pub_drv_burst_one[b]) begin
                  for (int s = 0; s < MshrMergeReqs; s++) begin
                    bank_sub_cand[b][s] = pub_sub_ok[s] && pub_parity_ok;
                  end
                  bank_cand[b] = (|pub_sub_ok) && pub_parity_ok;
                end else begin
                  for (int s = 0; s < MshrMergeReqs; s++) begin
                    bank_sub_cand[b][s] = pub_sub_ok[s] &&
                                          (pub_sub_map[b][s] == port_i[RespPortIdW-1:0]);
                  end
                  bank_cand[b] = |bank_sub_cand[b];
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
              // AND of AND: bank_cand & ~demote_oh & rr_mask == bank_cand & (rr_mask & ~demote_oh).
              bank_hi = bank_cand & bank_hi_mask;
              bank_lo = bank_cand & bank_lo_mask;
              bank_cand_eff = bank_hi | bank_lo;
              bank_pfx_hi = bank_hi;
              bank_pfx_lo = bank_lo;
              for (int st = 1; st < MshrBankNum; st = st << 1) begin
                bank_pfx_hi = bank_pfx_hi | (bank_pfx_hi << st);
                bank_pfx_lo = bank_pfx_lo | (bank_pfx_lo << st);
              end
              bank_first_hi = bank_pfx_hi & ~(bank_pfx_hi << 1);
              bank_first_lo = bank_pfx_lo & ~(bank_pfx_lo << 1);
              // Winner: first candidate at or above the base, else the first below it, else the
              // base bank itself -- the demoted fallback the rotated form reached with bank_win_d 0.
              for (int b = 0; b < MshrBankNum; b++) begin
                bank_first[b] = (|bank_cand_eff)
                              ? ((|bank_hi) ? bank_first_hi[b] : bank_first_lo[b])
                              : (BankIdW'(b) == bank_base);
              end
              bank_win     = '0;
              drain_have_e = |bank_cand;
              drain_win_e  = '0;
              for (int b = 0; b < MshrBankNum; b++) begin
                bank_win    = bank_win    | ({BankIdW {bank_first[b]}} & BankIdW'(b));
                drain_win_e = drain_win_e |
                              ({MshrIdxW{bank_first[b] && drain_have_e}} & bank_pub_e[b]);
              end
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
              // Eligible sub-requests inside the winning entry. Under BankPublish this is the row
              // already evaluated above -- a MshrBankNum:1 select of MshrMergeReqs bits, not a
              // MshrNum:1 re-read of drain_sub_ready/_tile/_port at the winning entry id. The
              // winning bank always has bank_pub_v set: bank_cand[b] requires it, and the demoted
              // fallback picks bank_base, which is in bank_cand whenever bank_cand_eff is empty.
              drain_sub_cand = '0;
              if (BankPublish) begin
                // bank_first is exactly one-hot in every branch, so OR-ing the masked rows is
                // bank_sub_cand[bank_win] without the encoder or the MshrBankNum:1 re-mux.
                for (int b = 0; b < MshrBankNum; b++) begin
                  drain_sub_cand = drain_sub_cand |
                                   ({MshrMergeReqs{bank_first[b]}} & bank_sub_cand[b]);
                end
              end else begin
                for (int s = 0; s < MshrMergeReqs; s++) begin
                  if (drain_sub_ready[drain_win_e][s] &&
                      (drain_sub_tile[drain_win_e][s] == tile_group_id_t'(tile_i)) &&
                      (drain_sub_port[drain_win_e][s] == port_i[RespPortIdW-1:0])) begin
                    drain_sub_cand[s] = 1'b1;
                  end
                end
              end
              for (int s = 0; s < MshrMergeReqs; s++) begin
                sub_rr_mask[s] = (SubIdxW'(s) >= drain_sel_sub_base);
              end
              sub_hi    = drain_sub_cand &  sub_rr_mask;
              sub_lo    = drain_sub_cand & ~sub_rr_mask;
              // First candidate at or above the base, else the first below it -- the wrap point the
              // rotated scan crossed.
              sub_first = (|sub_hi) ? (sub_hi & (~sub_hi + MshrMergeReqs'(1)))
                                    : (sub_lo & (~sub_lo + MshrMergeReqs'(1)));
              drain_have_s = |drain_sub_cand;
              drain_win_s  = '0;
              for (int s = 0; s < MshrMergeReqs; s++) begin
                drain_win_s = drain_win_s | ({SubIdxW{sub_first[s]}} & SubIdxW'(s));
              end
              if (drain_have_s) begin
                resp_sel_valid[tile_i][port_i]       = 1'b1;
                resp_sel_bank_valid[tile_i][port_i]  = 1'b1;
                resp_sel_mshr_id[tile_i][port_i]     = mshr_id_t'(drain_win_e);
                resp_sel_subreq_idx[tile_i][port_i]  = drain_win_s;   // already SubIdxW wide
                resp_sel_sub_oh[tile_i][port_i]      = sub_first;
                resp_sel_bank_sub_oh[tile_i][port_i] = sub_first;
                resp_sel_bank[tile_i][port_i]       = bank_win;
                resp_sel_bank_oh[tile_i][port_i]    = bank_first;
              end
            end
            // POOL candidates, offered ONLY when no banked row won this lane this cycle. A pool
            // entry is otherwise offered to the drain exactly as a banked one: same eligibility
            // terms, same sub-request walk, same handshake. Priority is the LOWEST pool entry with a
            // candidate, with no rotation -- the pool is at most a couple of entries and an entry
            // drains completely once it starts, so starvation is not reachable the way it is with
            // MshrNum rows.
            if (!resp_sel_valid[tile_i][port_i]) begin
              pool_cand         = '0;
              pool_sub_cand_map = '0;
              for (int p = 0; p < PoolNum; p++) begin
                for (int s = 0; s < MshrMergeReqs; s++) begin
                  if (pool_drain_sub_ready[p][s] &&
                      (pool_drain_sub_tile[p][s] == tile_group_id_t'(tile_i)) &&
                      (pool_drain_sub_port[p][s] == port_i[RespPortIdW-1:0])) begin
                    pool_sub_cand_map[p][s] = 1'b1;
                  end
                end
                pool_cand[p] = |pool_sub_cand_map[p];
              end
              pool_first     = '0;
              pool_first_any = 1'b0;
              for (int p = 0; p < PoolNum; p++) begin
                if (!pool_first_any && pool_cand[p]) begin
                  pool_first[p]  = 1'b1;
                  pool_first_any = 1'b1;
                end
              end
              if (pool_first_any) begin
                pool_win = '0;
                for (int p = 0; p < PoolNum; p++) begin
                  if (pool_first[p]) pool_win = PoolIdxW'(p);
                end
                pool_sub_cand = '0;
                for (int p = 0; p < PoolNum; p++) begin
                  if (pool_first[p]) pool_sub_cand = pool_sub_cand_map[p];
                end
                pool_sub_first = pool_sub_cand & (~pool_sub_cand + MshrMergeReqs'(1));
                pool_have_s    = |pool_sub_cand;
                pool_win_s     = '0;
                for (int s = 0; s < MshrMergeReqs; s++) begin
                  pool_win_s = pool_win_s | ({SubIdxW{pool_sub_first[s]}} & SubIdxW'(s));
                end
                if (pool_have_s) begin
                  resp_sel_valid[tile_i][port_i]      = 1'b1;
                  resp_sel_pool_valid[tile_i][port_i] = 1'b1;
                  resp_sel_pool_id[tile_i][port_i]    = pool_win;
                  resp_sel_subreq_idx[tile_i][port_i] = pool_win_s;
                  resp_sel_sub_oh[tile_i][port_i]     = pool_sub_first;
                end
              end
            end
          end
        end
      end

      // Drive responses and clear sub-requests on handshake.
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          // Computed for every lane from the banked operands alone, so the banked clear record does
          // not wait on the pool/banked operand select below.
          drv_bank_burst_one = BankPublish
                             ? |(resp_sel_bank_oh[tile_i][port_i] & pub_drv_burst_one)
                             : drv_burst_one[resp_sel_mshr_id[tile_i][port_i]];
          if (resp_sel_valid[tile_i][port_i]) begin
            resp_out_valid[tile_i][port_i] = 1'b1;
            // A buffered beat is a READ response by construction: the capture gate only admits
            // responses with wen == 0 (resp_is_mshr stays 0 otherwise and the beat takes the
            // bypass path), so the stored bit could never be anything but 0.
            resp_out[tile_i][port_i].wen = 1'b0;
            // One select per lane, on the bank the winner came from. Under BankPublish the winning
            // entry IS its bank's published entry, so these are the same values the MshrNum-wide
            // reads returned.
            if (!resp_sel_bank_valid[tile_i][port_i]) begin
              // Pool drive operands, read at the pool index -- never through resp_sel_mshr_id.
              drv_sel_data      = pool_drv_data     [resp_sel_pool_id[tile_i][port_i]];
              drv_sel_beat_off  = pool_drv_beat_off [resp_sel_pool_id[tile_i][port_i]];
              drv_sel_burst_one = pool_drv_burst_one[resp_sel_pool_id[tile_i][port_i]];
              drv_sel_sub_core  = pool_drv_sub_core [resp_sel_pool_id[tile_i][port_i]];
              drv_sel_sub_meta  = pool_drv_sub_meta [resp_sel_pool_id[tile_i][port_i]];
            end else if (BankPublish) begin
              // Selected with the bank one-hot, not its encoding: same values, no encoder in front.
              drv_sel_data      = '0;
              drv_sel_beat_off  = '0;
              drv_sel_burst_one = 1'b0;
              drv_sel_sub_core  = '0;
              drv_sel_sub_meta  = '0;
              for (int b = 0; b < MshrBankNum; b++) begin
                if (resp_sel_bank_oh[tile_i][port_i][b]) begin
                  drv_sel_data      = pub_drv_data     [b];
                  drv_sel_beat_off  = pub_drv_beat_off [b];
                  drv_sel_burst_one = pub_drv_burst_one[b];
                  drv_sel_sub_core  = pub_drv_sub_core [b];
                  // Selected with the bank one-hot, like every operand above. bank_first is
                  // one-hot in every branch, so this is pub_drv_sub_meta[bank_win] without the
                  // encoder in front of it.
                  drv_sel_sub_meta  = pub_drv_sub_meta [b];
                end
              end
            end else begin
              drv_sel_data      = drv_data     [resp_sel_mshr_id[tile_i][port_i]];
              drv_sel_beat_off  = drv_beat_off [resp_sel_mshr_id[tile_i][port_i]];
              drv_sel_burst_one = drv_burst_one[resp_sel_mshr_id[tile_i][port_i]];
              drv_sel_sub_core  = drv_sub_core [resp_sel_mshr_id[tile_i][port_i]];
              drv_sel_sub_meta  = drv_sub_meta [resp_sel_mshr_id[tile_i][port_i]];
            end
            resp_out[tile_i][port_i].rdata.data = drv_sel_data;
            // Re-emit beat b for THIS requester under the lane law: lane from the low BurstLaneW
            // bits, row from the rest.
            resp_out[tile_i][port_i].rdata.core_id =
                drv_sel_sub_core[resp_sel_subreq_idx[tile_i][port_i]] +
                tile_core_id_t'(drv_sel_beat_off[BurstLaneW-1:0]);
            resp_out[tile_i][port_i].rdata.meta_id =
                drv_sel_sub_meta[resp_sel_subreq_idx[tile_i][port_i]] +
                meta_id_t'(drv_sel_beat_off >> BurstLaneW);
            resp_out[tile_i][port_i].rdata.amo = '0;  // sub-requests are loads by construction (req_is_load)
            resp_from_mshr[tile_i][port_i] = 1'b1;
`ifndef TARGET_SYNTHESIS
            resp_mshr_id_dbg[tile_i][port_i] = resp_sel_mshr_id[tile_i][port_i];
`endif

            if (resp_out_ready[tile_i][port_i]) begin
              // Record on the bank axis; the scatter to entries runs once after the loop. sv_clr
              // clears sub_req.valid on the handshake so the next cycle's beat_pending seed cannot
              // re-include it and re-deliver the same response.
              drain_fire   [tile_i][port_i] = 1'b1;
              drain_fire_sv[tile_i][port_i] = drv_sel_burst_one;
              drain_fire_sub_oh[tile_i][port_i] = resp_sel_sub_oh[tile_i][port_i];
              drain_fire_bank       [tile_i][port_i] = resp_sel_bank_valid[tile_i][port_i];
              drain_fire_bank_sv    [tile_i][port_i] = drv_bank_burst_one;
              drain_fire_bank_sub_oh[tile_i][port_i] = resp_sel_bank_sub_oh[tile_i][port_i];
            end
          end
        end
      end

      // Scatter the recorded drain handshakes to entries. A lane served bank b's published row, so
      // the entry it served is the one drain_published marks in that bank -- bank_pub_e[bank_win]
      // said the same thing but had to recover the id through an MshrNum:1 select first.
      for (int e = 0; e < MshrNum; e++) begin
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int p = 1; p < NumRemoteRespPortsPerTile; p++) begin
            // Membership on the bank ONE-HOT: e / MshrWaysPerBank is a constant once the loop is
            // unrolled, so this is a wire, where the encoded form was a bank encoder feeding a
            // BankIdW compare in every (entry, lane) pair.
            if (drain_published[e] && drain_fire_bank[t][p] &&
                resp_sel_bank_oh[t][p][e / MshrWaysPerBank]) begin
              for (int s = 0; s < MshrMergeReqs; s++) begin
                if (drain_fire_bank_sub_oh[t][p][s]) begin
                  bp_clr[e][s] = 1'b1;
                  if (drain_fire_bank_sv[t][p]) sv_clr[e][s] = 1'b1;
                end
              end
            end
`ifndef TARGET_SYNTHESIS
            if (drain_published[e] && drain_fire[t][p] && !resp_sel_pool_valid[t][p] &&
                (resp_sel_bank[t][p] == BankIdW'(e / MshrWaysPerBank))) begin
              for (int s = 0; s < MshrMergeReqs; s++) begin
                if (drain_fire_sub_oh[t][p][s]) begin
                  bp_clr_ref[e][s] = 1'b1;
                  if (drain_fire_sv[t][p]) sv_clr_ref[e][s] = 1'b1;
                end
              end
            end
`endif
          end
        end
      end

      // POOL scatter, the same bit-clear form: acknowledged from the lane's own pool selection, no
      // bank published row involved because a pool entry has no bank.
      for (int p = 0; p < PoolNum; p++) begin
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int pp = 1; pp < NumRemoteRespPortsPerTile; pp++) begin
            if (resp_sel_pool_valid[t][pp] && drain_fire[t][pp] &&
                (resp_sel_pool_id[t][pp] == PoolIdxW'(p))) begin
              for (int s = 0; s < MshrMergeReqs; s++) begin
                if (drain_fire_sub_oh[t][pp][s]) begin
                  pool_bp_clr[p][s] = 1'b1;
                  if (drain_fire_sv[t][pp]) pool_sv_clr[p][s] = 1'b1;
                end
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
              drain2_bank_sub_cand = '0;
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
                      drain2_bank_sub_cand[b][s] = 1'b1;
                      drain2_bank_cand[b]        = 1'b1;
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
              end else begin
                for (int e = 0; e < MshrNum; e++) begin
                  drain2_rr_mask[e] = EnableRrFairness ? (MshrIdxW'(e) >= drain2_base) : 1'b1;
                end
                drain2_hi    = drain2_cand &  drain2_rr_mask;
                drain2_lo    = drain2_cand & ~drain2_rr_mask;
                drain2_first = (drain2_hi != '0) ? (drain2_hi & (~drain2_hi + MshrNum'(1)))
                                                 : (drain2_lo & (~drain2_lo + MshrNum'(1)));
              end
              // Encode the winner on the axis it was decided on: MshrBankNum wide under
              // Drain2BankPublish, MshrNum wide otherwise.
              drain2_bank_idx = '0;
              drain2_idx      = '0;
              if (Drain2BankPublish) begin
                for (int b = 0; b < MshrBankNum; b++) begin
                  if (drain2_bfirst[b]) drain2_bank_idx |= BankIdW'(b);
                end
              end else begin
                for (int b = 0; b < MshrNum; b++) begin
                  if (drain2_first[b]) drain2_idx |= MshrIdxW'(b);
                end
              end
              if (drain2_any) begin
                // The absolute id is still needed to address the entry, but it is now built from
                // the winning bank and that bank's published way, not recovered from a MshrNum-wide
                // scatter.
                drain2_mshr_i = Drain2BankPublish
                    ? MshrIdxW'(int'(drain2_bank_idx) * MshrWaysPerBank +
                                int'(drain2_pub_w[drain2_bank_idx]))
                    : drain2_idx;
                // First eligible sub-request inside the winning entry, same rotated order.
                for (int ks = 0; ks < MshrMergeReqs; ks++) begin
                  drain2_s = SubIdxW'(drain2_sub_base + SubIdxW'(ks));
                  // Under Drain2BankPublish this row was already evaluated above: a
                  // MshrBankNum:1 select instead of re-reading the ready/tile/port vectors at the
                  // winning entry id.
                  if (!resp_sel2_valid[tile_i][port_i] &&
                      (Drain2BankPublish
                         ? drain2_bank_sub_cand[drain2_bank_idx][drain2_s]
                         : (drain2_sub_ready[drain2_mshr_i][drain2_s] &&
                            (drain2_sub_tile[drain2_mshr_i][drain2_s] ==
                             tile_group_id_t'(tile_i)) &&
                            (drain2_sub_port[drain2_mshr_i] == port_i[RespPortIdW-1:0])))) begin
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
    // The same clears for pool entries.
    for (int p = 0; p < PoolNum; p++) begin
      pool_d[p].beat_pending  = pool_d[p].beat_pending  & ~pool_bp_clr[p];
      // No beat_pending2 clear: nothing ever sets it for a pool entry (see the pool2_clr note).
      for (int s = 0; s < MshrMergeReqs; s++) begin
        if (pool_sv_clr[p][s]) pool_d[p].sub_reqs[s].valid = 1'b0;
      end
    end

    // Finalize response draining per beat.
    // Pop-count form: both pops are decided on the values entering this pass and applied once,
    // instead of two chained read-modify-writes of resp_buf_rd_ptr / resp_buf_cnt / beats_left.
    // "resp_buf_cnt after the head pop != 0"     ==  resp_buf_cnt >= 2
    // "beats_left after the head decrement == 1" ==  beats_left == 2
    // NOT a bandwidth change: pop == 2 is the same two beats, decided in parallel not in series.
    for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      // Entering values, read before any write below, so each is what the sequential form saw.
      fin_cnt_in = mshr_d[mshr_i].resp_buf_cnt;
      fin_rdp_in = mshr_d[mshr_i].resp_buf_rd_ptr;
      fin_bl_in  = mshr_d[mshr_i].beats_left;
      fin_bp2_in = mshr_d[mshr_i].beat_pending2;

      // Decided WITHOUT the head-beat term: these are only ever consumed under fin_head, so
      // dropping that qualifier cannot change a selected value.
      fin_second_en = PD2 && (mshr_d[mshr_i].burst_len != BurstLenWidth'(1)) &&
                      mshr_d[mshr_i].beat2_armed && (fin_bl_in != BurstLenWidth'(1));
      fin_second    = fin_second_en && (fin_bp2_in == '0) && cap_cnt_ge2[mshr_i];
      fin_pop       = fin_second ? 2'd2 : 2'd1;
      fin_retire    = (fin_bl_in == BurstLenWidth'(1)) ||
                      (fin_second && (fin_bl_in == BurstLenWidth'(2)));

      // Both pop distances off the ENTERING pointer and count, so the late term drives only the
      // select. pop <= 2 and rd_ptr <= RespBufWords-1, so one conditional subtract covers the wrap.
      fin_rdp_next = (RespBufWords > 1)
                   ? (((int'(fin_rdp_in) + int'(fin_pop)) >= int'(RespBufWords))
                        ? RespBufPtrW'(int'(fin_rdp_in) + int'(fin_pop) - int'(RespBufWords))
                        : RespBufPtrW'(int'(fin_rdp_in) + int'(fin_pop)))
                   : fin_rdp_in;
      fin_cnt_next = fin_cnt_in - RespBufCountW'(fin_pop);
      fin_bl_next  = (fin_bl_in != '0) ? (fin_bl_in - BurstLenWidth'(fin_pop)) : fin_bl_in;
      // "count after the pop != 0" is "count > pop": the guard gives cnt != 0 and fin_second needs
      // cnt >= 2, so the subtraction never borrows.
      fin_cnt_next_nz = fin_second ? (fin_cnt_in > RespBufCountW'(2))
                                   : (fin_cnt_in > RespBufCountW'(1));

      fin_arm       = mshr_q_valid[mshr_i] && cap_cnt_nz[mshr_i] &&
                      (mshr_d[mshr_i].state == MSHR_DRAIN_RESP);
      fin_cache_sel = (fin_bl_in == BurstLenWidth'(1)) && EnableRespCache && !amo_inval_guard &&
                      mshr_d[mshr_i].cacheable &&
                      (mshr_d[mshr_i].burst_len == BurstLenWidth'(1));

`ifndef TARGET_SYNTHESIS
      gate_extra[mshr_i] = gate_extra[mshr_i] | (mshr_q_valid[mshr_i] & ~mshr_d_valid[mshr_i]);
`endif
      resp_head_beat_pending[mshr_i] = fin_arm && (|mshr_d[mshr_i].beat_pending);
      fin_cache = fin_arm && !resp_head_beat_pending[mshr_i] &&  fin_cache_sel;
      fin_head  = fin_arm && !resp_head_beat_pending[mshr_i] && !fin_cache_sel;
      resp_cnt_after_pop[mshr_i] = fin_head ? fin_cnt_next : fin_cnt_in;

      fin_bp_promote = fin_head && fin_second_en && !fin_second;
      fin_b2_clr     = fin_head && !fin_retire && fin_second_en;

      mshr_d[mshr_i].resp_buf_rd_ptr = fin_head ? fin_rdp_next : fin_rdp_in;
      mshr_d[mshr_i].resp_buf_cnt    = fin_head ? fin_cnt_next : fin_cnt_in;
      mshr_d[mshr_i].beats_left      = fin_cache                 ? '0
                                     : (fin_head && !fin_retire) ? fin_bl_next : fin_bl_in;
      mshr_d[mshr_i].state           = fin_cache                 ? MSHR_CACHED
                                     : (fin_head && !fin_retire)
                                         ? (fin_cnt_next_nz ? MSHR_DRAIN_RESP : MSHR_WAIT_RESP)
                                         : mshr_d[mshr_i].state;
      mshr_d[mshr_i].beat_pending    = fin_bp_promote           ? fin_bp2_in
                                     : (fin_cache || fin_head)  ? '0
                                                                : mshr_d[mshr_i].beat_pending;
      mshr_d[mshr_i].beat_pending2   = fin_b2_clr ? '0   : fin_bp2_in;
      mshr_d[mshr_i].beat2_armed     = fin_b2_clr ? 1'b0 : mshr_d[mshr_i].beat2_armed;
      mshr_d[mshr_i].sub_reqs_num    = fin_cache  ? '0   : mshr_d[mshr_i].sub_reqs_num;
      // Re-arm the serve-target timeout for the cache-resident phase.
      mshr_d[mshr_i].hold_cnt        = fin_cache  ? hold_ticks(cfg_cache_hold_ticks_src)
                                                  : mshr_d[mshr_i].hold_cnt;
      for (int s = 0; s < MshrMergeReqs; s++) begin
        if (fin_cache) mshr_d[mshr_i].sub_reqs[s].valid = 1'b0;
      end
      if (fin_head && fin_retire) mshr_d_valid[mshr_i] = 1'b0;
`ifndef TARGET_SYNTHESIS
      if (fin_cache || fin_head) mshr_d[mshr_i].beat_done[resp_beat_offset[mshr_i]] = 1'b1;
      if (fin_head && fin_second) mshr_d[mshr_i].beat_done[drain2_beat_off[mshr_i]] = 1'b1;
`endif
    end

    // -------------------------------------------------------------------------------------------
    // POOL finalize: the twin of the banked pass above, same pop-count form and same decision
    // order, on pool_d. Reuses the fin_* scratch signals -- the two passes are sequential, so they
    // never hold a live value across each other.
    // -------------------------------------------------------------------------------------------
    for (int p = 0; p < PoolNum; p++) begin
      fin_cnt_in = pool_d[p].resp_buf_cnt;
      fin_rdp_in = pool_d[p].resp_buf_rd_ptr;
      fin_bl_in  = pool_d[p].beats_left;
      fin_bp2_in = pool_d[p].beat_pending2;

      fin_second_en = PD2 && (pool_d[p].burst_len != BurstLenWidth'(1)) &&
                      pool_d[p].beat2_armed && (fin_bl_in != BurstLenWidth'(1));
      // cap_cnt_ge2 is banked-table state; the pool's equivalent is computed from pool_d directly.
      fin_second    = fin_second_en && (fin_bp2_in == '0) &&
                      ((pool_d[p].resp_buf_cnt >= RespBufCountW'(2)) ||
                       ((pool_d[p].resp_buf_cnt == RespBufCountW'(1)) &&
                        (pool_cap_g1[p] || pool_cap_g2[p])) ||
                       (pool_cap_g1[p] && pool_cap_g2[p]));
      fin_pop       = fin_second ? 2'd2 : 2'd1;
      fin_retire    = (fin_bl_in == BurstLenWidth'(1)) ||
                      (fin_second && (fin_bl_in == BurstLenWidth'(2)));

      fin_rdp_next = (RespBufWords > 1)
                   ? (((int'(fin_rdp_in) + int'(fin_pop)) >= int'(RespBufWords))
                        ? RespBufPtrW'(int'(fin_rdp_in) + int'(fin_pop) - int'(RespBufWords))
                        : RespBufPtrW'(int'(fin_rdp_in) + int'(fin_pop)))
                   : fin_rdp_in;
      fin_cnt_next = fin_cnt_in - RespBufCountW'(fin_pop);
      fin_bl_next  = (fin_bl_in != '0) ? (fin_bl_in - BurstLenWidth'(fin_pop)) : fin_bl_in;
      fin_cnt_next_nz = fin_second ? (fin_cnt_in > RespBufCountW'(2))
                                   : (fin_cnt_in > RespBufCountW'(1));

      fin_arm       = pool_q_valid[p] &&
                      (pool_d[p].resp_buf_cnt != '0) &&
                      (pool_d[p].state == MSHR_DRAIN_RESP);
      fin_cache_sel = (fin_bl_in == BurstLenWidth'(1)) && EnableRespCache && !amo_inval_guard &&
                      pool_d[p].cacheable &&
                      (pool_d[p].burst_len == BurstLenWidth'(1));

      pool_resp_head_beat_pending[p] = fin_arm && (|pool_d[p].beat_pending);
      fin_cache = fin_arm && !pool_resp_head_beat_pending[p] &&  fin_cache_sel;
      fin_head  = fin_arm && !pool_resp_head_beat_pending[p] && !fin_cache_sel;
      pool_resp_cnt_after_pop[p] = fin_head ? fin_cnt_next : fin_cnt_in;

      fin_bp_promote = fin_head && fin_second_en && !fin_second;
      fin_b2_clr     = fin_head && !fin_retire && fin_second_en;

      pool_d[p].resp_buf_rd_ptr = fin_head ? fin_rdp_next : fin_rdp_in;
      pool_d[p].resp_buf_cnt    = fin_head ? fin_cnt_next : fin_cnt_in;
      pool_d[p].beats_left      = fin_cache                 ? '0
                                : (fin_head && !fin_retire) ? fin_bl_next : fin_bl_in;
      pool_d[p].state           = fin_cache                 ? MSHR_CACHED
                                : (fin_head && !fin_retire)
                                    ? (fin_cnt_next_nz ? MSHR_DRAIN_RESP : MSHR_WAIT_RESP)
                                    : pool_d[p].state;
      pool_d[p].beat_pending    = fin_bp_promote           ? fin_bp2_in
                                : (fin_cache || fin_head)  ? '0
                                                           : pool_d[p].beat_pending;
      pool_d[p].beat_pending2   = fin_b2_clr ? '0   : fin_bp2_in;
      pool_d[p].beat2_armed     = fin_b2_clr ? 1'b0 : pool_d[p].beat2_armed;
      pool_d[p].sub_reqs_num    = fin_cache  ? '0   : pool_d[p].sub_reqs_num;
      pool_d[p].hold_cnt        = fin_cache  ? hold_ticks(cfg_cache_hold_ticks_src)
                                             : pool_d[p].hold_cnt;
      for (int s = 0; s < MshrMergeReqs; s++) begin
        if (fin_cache) pool_d[p].sub_reqs[s].valid = 1'b0;
      end
      if (fin_head && fin_retire) pool_d_valid[p] = 1'b0;
    end

    // Apply the deferred allocation valid-set. Placed last so the allocation arbiter never enters
    // any clear guard; the two are mutually exclusive by state, so an OR reproduces the in-place
    // form exactly (allocation wins a reclaimed CACHED way, as it did when its write landed first).
    mshr_d_valid = mshr_d_valid | mshr_alloc_set;
    pool_d_valid = pool_d_valid | pool_alloc_set;
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
    logic [31:0] cut_addr_stall_dbg, cut_alloc_dbg, cut_bench_cyc_dbg;
    // Port-concurrency probe. The two remote request ports of a tile arbitrate independently
    // today, which is what makes NumAllocSlots 32 and sets the OR-32 + 32-bit LSB-isolate in both
    // bank arbiters. If a tile almost never presents two requests in the same cycle, a 2:1
    // round-robin per tile would halve the arbitration width for almost no throughput.
    //   pc_tile_any  : cycles in which the tile had at least one valid request
    //   pc_tile_both : of those, cycles in which BOTH ports were valid
    //   pc_both_rdy  : both valid AND both accepted -- the only case a 2:1 merge would slow down
    logic [31:0] pc_tile_any_dbg, pc_tile_both_dbg, pc_both_rdy_dbg;
    // Store-force-drain opportunity counter. Evaluated from the SAME terms as the real decision but
    // WITHOUT the StoreForceDrain gate, so it still measures how often the mechanism would have
    // fired while the knob is off -- a counter that the knob silences would answer nothing.
    logic [31:0] sfd_hit_cnt_dbg;
    logic [MshrNum-1:0] sfd_would_fire;
    always_comb begin
      sfd_would_fire = '0;
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int pp = 1; pp < NumRemoteReqPortsPerTile; pp++) begin
          if (req_in_valid[t][pp] && req_is_store[t][pp] &&
              req_out_ready[t][pp] &&
              (req_len[t][pp] == BurstLenWidth'(1))) begin
            for (int w = 0; w < MshrWaysPerBank; w++) begin
              if (req_addr_hit_way[t][pp][w] &&
                  st_hold_post_cap[int'(req_bank[t][pp]) * MshrWaysPerBank + w]) begin
                sfd_would_fire[int'(req_bank[t][pp]) * MshrWaysPerBank + w] = 1'b1;
              end
            end
          end
        end
      end
    end
    logic [$clog2(NumTilesPerGroup+1)-1:0] pc_any_now, pc_both_now, pc_rdy_now;
    always_comb begin
      pc_any_now = '0; pc_both_now = '0; pc_rdy_now = '0;
      for (int pt = 0; pt < NumTilesPerGroup; pt++) begin
        if (|req_in_valid[pt]) pc_any_now  = pc_any_now  + 1'b1;
        if (&req_in_valid[pt]) begin
          pc_both_now = pc_both_now + 1'b1;
          if (&req_in_ready[pt]) pc_rdy_now = pc_rdy_now + 1'b1;
        end
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        cut_addr_stall_dbg  <= '0;
        pc_tile_any_dbg     <= '0;
        sfd_hit_cnt_dbg     <= '0;
        pc_tile_both_dbg    <= '0;
        pc_both_rdy_dbg     <= '0;
        cut_alloc_dbg       <= '0;
        cut_bench_cyc_dbg   <= '0;
      end else begin
        cut_addr_stall_dbg  <= cut_addr_stall_dbg  + 32'($countones(req_fwd_hit));
        cut_alloc_dbg       <= cut_alloc_dbg       + 32'($countones(agb_v));
        cut_bench_cyc_dbg   <= cut_bench_cyc_dbg   + 32'd1;
        // Sum across tiles COMBINATIONALLY first: 16 non-blocking increments of one variable in
        // one cycle would leave only the last, counting at most 1 per cycle instead of per tile.
        pc_tile_any_dbg  <= pc_tile_any_dbg  + 32'(pc_any_now);
        pc_tile_both_dbg <= pc_tile_both_dbg + 32'(pc_both_now);
        pc_both_rdy_dbg  <= pc_both_rdy_dbg  + 32'(pc_rdy_now);
        sfd_hit_cnt_dbg  <= sfd_hit_cnt_dbg  + 32'($countones(sfd_would_fire));
      end
    end
    final $display("[CUTSTALL] fwd_hits=%0d allocations=%0d cycles=%0d",
                   cut_addr_stall_dbg, cut_alloc_dbg, cut_bench_cyc_dbg);
    final $display("[PORTCONC] tile_any=%0d tile_both=%0d both_ready=%0d cycles=%0d",
                   pc_tile_any_dbg, pc_tile_both_dbg, pc_both_rdy_dbg, cut_bench_cyc_dbg);
    final $display("[SFD] group=%0d store_hits_held_entry=%0d knob=%0d",
                   group_id_i, sfd_hit_cnt_dbg, StoreForceDrain);

    // With the knob off nothing flushes a held entry, so a store landing on one would leave a
    // stale copy for a later merge to read. The knob is off because that never happens on this
    // workload -- assert it rather than assume it.
    if (!StoreForceDrain) begin : gen_no_store_hits_held
      for (genvar se = 0; se < MshrNum; se++) begin : gen_nshh_e
        store_never_hits_held: assert property(
          @(posedge clk_i) disable iff (!rst_ni) !sfd_would_fire[se])
          else $fatal(1,
              "store hit a RESP_HOLD entry %0d with group_mshr_store_force_drain off -- stale data",
              se);
      end
    end

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

    // -------------------------------------------------------------------------------------------
    // POOL assertions.
    //
    // Deliberately NOT asserted: "a line is never resident both in a banked way and in the pool".
    // That reads like the invariant the design depends on, and it is what a reader would expect
    // here, but it is FALSE by design in this module: a same-address pair is legal whenever the two
    // requests differ in burst_len, which is exactly why req_hit_way carries a burst_len compare and
    // why no_late_join_burst lets a refused request allocate its own entry. An assertion of that
    // shape would fire on the banked table's own documented behaviour. The real guarantee is
    // narrower -- a pool HIT is never an allocation candidate -- and it is structural: pool hits are
    // folded into req_hit_mshr / req_addr_hit_drain, and req_alloc_cand is built from those. What
    // follows asserts the parts of that which are checkable without re-deriving the request path.
    // -------------------------------------------------------------------------------------------
    // No generate/endgenerate here: this sits inside an existing generate region, and vlog rejects
    // a nested pair outright -- the bare if/for forms are generate constructs already.
      // Both the drive select and the clear scatter read the bank one-hot where they used to read
      // its encoding, so the two must agree whenever a banked row won the lane.
      for (genvar bt = 0; bt < NumTilesPerGroup; bt++) begin : gen_bank_sel_oh_tile
        for (genvar bp = 1; bp < NumRemoteRespPortsPerTile; bp++) begin : gen_bank_sel_oh_port
          bank_sel_oh_matches_encoding: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              !resp_sel_bank_valid[bt][bp] ||
              ($onehot(resp_sel_bank_oh[bt][bp]) &&
               resp_sel_bank_oh[bt][bp][resp_sel_bank[bt][bp]]))
            else $fatal(1, "bank one-hot disagrees with its encoding at tile %0d port %0d", bt, bp);
        end
      end
      // The banked clear scatter carries no pool term; it must equal the pool-qualified form.
      drain_clr_bank_equiv: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          (bp_clr == bp_clr_ref) && (sv_clr == sv_clr_ref))
        else $fatal(1, "banked drain clear diverged from the pool-qualified reference");
      drain_sel_bank_pool_exclusive: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          (resp_sel_bank_valid & resp_sel_pool_valid) == '0)
        else $fatal(1, "a lane holds both a banked and a pool drain selection");
      if (PoolNum > 0) begin : gen_pool_checks
        apb_en_covers_valid: assert property(
          @(posedge clk_i) disable iff (!rst_ni) apb_v |-> apb_en)
          else $fatal(1, "pool allocation payload enable does not cover the staged valid");
        pool_grants_onehot: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            $onehot0(pool_alloc_win_oh) && $onehot0(pool_merge_win_oh))
          else $fatal(1, "pool grant payload reduction received multiple winners");

        pool_controls_known: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            !$isunknown({pool_q_valid, apb_q_v, mpb_q_v, pool_wr_all, pool_id_we, pool_rb_we}))
          else $fatal(1, "unknown pool valid or write control");

        for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_pool_accept_tile
          for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_pool_accept_port
            localparam int unsigned Sl = t * NumReqPortsActive + p - 1;
            pool_alloc_accepted: assert property(
              @(posedge clk_i) disable iff (!rst_ni)
                (apb_v && pool_alloc_win_oh[Sl]) |->
                  (req_in_valid[t][p] && req_in_ready[t][p]))
              else $fatal(1, "pool recorded an unaccepted allocation: tile=%0d port=%0d", t, p);
            pool_merge_accepted: assert property(
              @(posedge clk_i) disable iff (!rst_ni)
                pool_merge_win_oh[Sl] |-> (req_in_valid[t][p] && req_in_ready[t][p]))
              else $fatal(1, "pool recorded an unaccepted merge: tile=%0d port=%0d", t, p);
          end
        end
        for (genvar e = 0; e < PoolNum; e++) begin : gen_pool_entry_checks
          for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_pool_coherence_tile
            for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_pool_coherence_port
              if (!CacheStoreUpdate && EnableRespCache) begin : gen_no_cached_store
                pool_cached_store_requires_update: assert property(
                  @(posedge clk_i) disable iff (!rst_ni)
                    !(req_in_valid[t][p] && req_in_ready[t][p] && req_is_store[t][p] &&
                      (req_len[t][p] == BurstLenWidth'(1)) && pool_addr_hit_way[t][p][e] &&
                      (pool_q[e].state == MSHR_CACHED)))
                  else $fatal(1, "store hit cached pool entry %0d with cache update disabled", e);
              end
              if (!StoreForceDrain) begin : gen_no_held_store
                pool_held_store_requires_drain: assert property(
                  @(posedge clk_i) disable iff (!rst_ni)
                    !(req_in_valid[t][p] && req_in_ready[t][p] && req_is_store[t][p] &&
                      (req_len[t][p] == BurstLenWidth'(1)) && pool_addr_hit_way[t][p][e] &&
                      (pool_st_post_cap[e] == MSHR_RESP_HOLD)))
                  else $fatal(1, "store hit held pool entry %0d with force drain disabled", e);
              end
              if (!CacheAmoInval && EnableRespCache) begin : gen_no_cached_amo
                pool_cached_amo_requires_invalidate: assert property(
                  @(posedge clk_i) disable iff (!rst_ni)
                    !(req_in_valid[t][p] && req_in_ready[t][p] &&
                      (req_in[t][p].wdata.amo != '0) &&
                      pool_addr_hit_way[t][p][e] && (pool_q[e].state == MSHR_CACHED)))
                  else $fatal(1, "AMO hit cached pool entry %0d with invalidation disabled", e);
              end
            end
          end
          pool_cached_data_valid: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              (pool_q_valid[e] && (pool_q[e].state == MSHR_CACHED)) |->
                ((pool_q[e].burst_len == BurstLenWidth'(1)) && (pool_q[e].resp_buf_cnt != '0)))
            else $fatal(1, "pool entry %0d cached without a buffered scalar response", e);
          pool_response_count_in_range: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              pool_q_valid[e] |-> (pool_q[e].resp_buf_cnt <= RespBufCountW'(RespBufWords)))
            else $fatal(1, "pool entry %0d response buffer count overflowed", e);
          pool_state_known: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              pool_q_valid[e] |->
                !$isunknown({pool_q[e].state, pool_q[e].burst_len, pool_q[e].sub_reqs_num,
                             pool_q[e].beats_left, pool_q[e].beat_pending, pool_q[e].issued,
                             pool_q[e].resp_buf_cnt, pool_q[e].hold_cnt}))
            else $fatal(1, "unknown control state in live pool entry %0d", e);
          pool_merge_not_retired: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              pool_merge_inflight[e] |-> pool_d_valid[e])
            else $fatal(1, "pool entry %0d retired with a merge in flight", e);
          pool_capture_sees_merge: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              (pool_st_cap_fire[e] && pool_merge_inflight[e]) |->
                (pool_d[e].sub_reqs_num == SubReqCountW'(pool_q[e].sub_reqs_num + 1)))
            else $fatal(1, "pool entry %0d captured with a lost subscriber", e);
          pool_replay_accepted: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              pool_replay_issue[e] |->
                (req_out_valid[pool_replay_own_t[e]][pool_replay_own_p[e]] &&
                 req_out_ready[pool_replay_own_t[e]][pool_replay_own_p[e]]))
            else $fatal(1, "pool entry %0d marked an unaccepted replay as issued", e);
          pool_capture_onehot: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              $onehot0(pool_cap_first[e]) && $onehot0(pool_cap_second[e]) &&
              !(|(pool_cap_first[e] & pool_cap_second[e])))
            else $fatal(1, "pool entry %0d capture grants overlap", e);
        end

        // A pool allocation takes an entry nothing else owns. pool_free_id comes from the
        // invalid-first lookup, and only one allocation can be in flight, so this must hold; it is
        // the guard against a future edit that lets a grant name a resident entry.
        pool_alloc_target_free: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            !apb_q_v || !pool_q_valid[apb_q_way])
          else $fatal(1, "pool allocation named entry %0d, which is already valid", apb_q_way);

        // One allocation per cycle, the pool's own port. The arbiter grants a single slot, so a
        // second in-flight record would mean the port had been widened without the apply following.
        pool_one_alloc_per_cycle: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            $countones(pool_alloc_inflight) <= 1)
          else $fatal(1, "more than one pool allocation in flight");

        // Pool occupancy and in-flight records must be visible to the CSR interlock, exactly as the
        // banked ones are: a resident pool entry was keyed under the current hash.
        pool_busy_covers: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            !(apb_q_v || mpb_q_v || (|pool_q_valid)) || mshr_busy_o)
          else $fatal(1, "MSHR busy_o low with pool state live -- bank-hash CSR could change");
      end
      // Holds for every build, pool or not: with no pool nothing may be allocated into it.
      pool_absent_never_allocates: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          (PoolNum > 0) || !apb_q_v)
        else $fatal(1, "pool allocation recorded in a build with MshrOverflowNum = 0");

    // Every stamped tag must land in one of the two ranges: 1..MshrNum for the banked table,
    // MshrNum+1..MshrNum+PoolNum for the pool. This is what keeps a response routable -- the banked
    // decode is bounded at MshrNum precisely so a pool tag cannot truncate through mshr_id_t onto
    // banked entry 0, and the pool decode range-tests the other side. Tag 0 is the bypass sentinel
    // and is excluded.
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_pool_tag_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_pool_tag_port
        pool_tag_in_range: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            (req_out_valid[tile_i][port_i] && (req_out[tile_i][port_i].mshr_tag != '0)) |->
              ((req_out[tile_i][port_i].mshr_tag >  MshrTagWidth'(MshrNum))
                 ? (req_out[tile_i][port_i].mshr_tag <= MshrTagWidth'(MshrNum + PoolNum))
                 : (req_out[tile_i][port_i].mshr_tag <= MshrTagWidth'(MshrNum))))
          else $fatal(1, "tile %0d port %0d: mshr_tag %0d outside both the banked and the pool range",
                      tile_i, port_i, req_out[tile_i][port_i].mshr_tag);
      end
    end

    for (genvar mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin : gen_mshr_bank_invariant
      mshr_entry_in_its_bank: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
        mshr_q_valid[mshr_i] |->
          (mshr_bank_of(mshr_q[mshr_i].base_addr, mshr_q[mshr_i].base_addr,
                        mshr_q[mshr_i].base_addr, mshr_q[mshr_i].tgt_group_id,
                        mshr_q[mshr_i].burst_len == BurstLenWidth'(1),
                        cfg_bank_shift_single, cfg_bank_shift_burst, cfg_bank_burst_bits) ==
           BankIdW'(mshr_i / MshrWaysPerBank)))
        else $fatal(1, "MSHR entry %0d not in its address bank (got %0d, expected %0d)",
                    mshr_i,
                    mshr_bank_of(mshr_q[mshr_i].base_addr, mshr_q[mshr_i].base_addr,
                        mshr_q[mshr_i].base_addr, mshr_q[mshr_i].tgt_group_id,
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

`ifndef TARGET_SYNTHESIS
        // The producer owns splitting; this check adds no request-path logic.
        burst_within_tile: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            (!req_in_valid[tile_i][port_i] ||
             !req_is_load[tile_i][port_i] ||
             (req_len_raw[tile_i][port_i] <= 1)) ||
            ((($unsigned(req_tile_addr[tile_i][port_i]) % NumBanksPerTile) +
              int'(req_len_raw[tile_i][port_i])) <= NumBanksPerTile))
          else $fatal(1, "MSHR burst crosses tile bank stripe or exceeds maximum: tile=%0d port=%0d addr=0x%0x len=%0d",
                      tile_i, port_i, req_in[tile_i][port_i].tgt_addr,
                      req_len_raw[tile_i][port_i]);
`endif
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

    // With CacheStoreUpdate / CacheAmoInval off the cache has no coherence mechanism against an
    // incoming store or AMO, so a hit on a CACHED entry would silently serve stale data. The knobs
    // are off because that never happens on the target workload -- assert it rather than trust it.
    if (!CacheStoreUpdate && EnableRespCache) begin : gen_no_store_hit_assert
      for (genvar nt = 0; nt < NumTilesPerGroup; nt++) begin : gen_nsh_tile
        for (genvar np = 1; np < NumRemoteReqPortsPerTile; np++) begin : gen_nsh_port
          for (genvar nw = 0; nw < MshrWaysPerBank; nw++) begin : gen_nsh_way
            cache_store_never_hits: assert property(
              @(posedge clk_i) disable iff (!rst_ni)
                !(req_in_valid[nt][np] && req_in_ready[nt][np] && req_is_store[nt][np] &&
                  (req_len[nt][np] == BurstLenWidth'(1)) &&
                  req_addr_hit_way[nt][np][nw] &&
                  mshr_q_valid[mshr_id_t'(int'(req_bank[nt][np]) * MshrWaysPerBank + nw)] &&
                  (mshr_q[mshr_id_t'(int'(req_bank[nt][np]) * MshrWaysPerBank + nw)].state
                     == MSHR_CACHED)))
              else $fatal(1,
                  "store hit a CACHED entry with group_mshr_cache_store_update off (tile %0d port %0d way %0d)",
                  nt, np, nw);
          end
        end
      end
    end
    if (!CacheAmoInval && EnableRespCache) begin : gen_no_amo_hit_assert
      // Scoped like the store twin above: an ACCEPTED amo whose key and target group match the
      // cached line. amo_invalidate alone is |req_is_amo over every lane, so pairing it with "some
      // entry is CACHED" fires on an unrelated AMO -- a barrier on another address, which is the
      // common case -- and says nothing about whether the cache was actually reached.
      for (genvar ae = 0; ae < MshrNum; ae++) begin : gen_nah_entry
        cache_amo_never_hits: assert property(
          @(posedge clk_i) disable iff (!rst_ni)
            !(mshr_q_valid[ae] && (mshr_q[ae].state == MSHR_CACHED) && amo_hits_entry[ae]))
          else $fatal(1,
              "accepted AMO to the address of CACHED entry %0d with group_mshr_cache_amo_inval off",
              ae);
      end
    end

    // Compare-then-mux equivalence: selecting one comparison result with the bank one-hot must
    // give exactly what selecting the entry and then comparing gave.
    for (genvar qt = 0; qt < NumTilesPerGroup; qt++) begin : gen_hitway_eq_t
      for (genvar qp = 1; qp < NumRemoteReqPortsPerTile; qp++) begin : gen_hitway_eq_p
        for (genvar qw = 0; qw < MshrWaysPerBank; qw++) begin : gen_hitway_eq_w
          hitway_compare_then_mux_equiv: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              req_addr_hit_way[qt][qp][qw] == req_addr_hit_way_old[qt][qp][qw])
            else $fatal(1,
                "req_addr_hit_way rewrite diverged at tile %0d port %0d way %0d", qt, qp, qw);
        end
      end
    end

    // The two mshr_q_valid substitutions above run the seed and the finalize on entries that
    // mshr_d_valid excludes. Every write they make is entry-local, so this is safe exactly while
    // such an entry is dead next cycle -- if one were instead allocated (mshr_alloc_set applies
    // after both gates), the extra writes would land in the fresh entry.
    // What the merge-candidate exclusion buys: a merge can only ever apply to a live entry. If a
    // retire and a merge could still pick the same entry, the subscriber would be lost silently.
    for (genvar me = 0; me < MshrNum; me++) begin : gen_merge_live
      merge_applies_to_live_entry: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          merge_inflight[me] |-> mshr_q_valid[me])
        else $fatal(1, "entry %0d absorbed a merge while not valid", me);
    end

    // The capture tree must name the same winners, ways and credits as the isolate it replaces.
    for (genvar cb = 0; cb < MshrBankNum; cb++) begin : gen_cap_tree_equiv
      cap_tree_equiv: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          CapPerBank |-> ((capb_g1[cb] == capb_g1_ref[cb]) &&
                          (capb_g2[cb] == capb_g2_ref[cb]) &&
                          (capb_l1_way[cb] == capb_l1_way_ref[cb]) &&
                          (capb_l2_way[cb] == capb_l2_way_ref[cb])))
        else $fatal(1, "capture tree diverged from the isolate at bank %0d", cb);
    end

    for (genvar ce = 0; ce < MshrNum; ce++) begin : gen_gate_extra
      gate_extra_dead_next_cycle: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          gate_extra[ce] |=> !mshr_q_valid[ce])
        else $fatal(1,
            "entry %0d took the seed/finalize gate while mshr_d_valid excluded it, then stayed valid",
            ce);
    end

    // A tile can never have a third outstanding bypassed multi-beat burst
    // (VLSU one-instruction serialization x <=2 bursts/instruction).
    if (StallOnResp) begin : gen_stall_on_resp_assert
      for (genvar at = 0; at < NumTilesPerGroup; at++) begin : gen_sor_tile
        for (genvar ap = 1; ap < NumRemoteReqPortsPerTile; ap++) begin : gen_sor_port
          no_alloc_while_resp_landing: assert property(
            @(posedge clk_i) disable iff (!rst_ni)
              !(req_in_valid[at][ap] && req_in_ready[at][ap] &&
                (req_alloc_found[at][ap] || req_alloc_found_pool[at][ap]) &&
                req_addr_hit_drain[at][ap]))
            else $fatal(1,
                "MSHR allocation while same-address response drains: tile=%0d port=%0d valid=%b ready=%b bank=%b pool=%b drain=%b",
                at, ap, $sampled(req_in_valid[at][ap]), $sampled(req_in_ready[at][ap]),
                $sampled(req_alloc_found[at][ap]), $sampled(req_alloc_found_pool[at][ap]),
                $sampled(req_addr_hit_drain[at][ap]));
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
