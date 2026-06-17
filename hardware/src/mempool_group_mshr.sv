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
  localparam int unsigned SubReqCountW     = idx_width(MshrMergeReqs + 1);
  localparam int unsigned RespBufCountW    = idx_width(RespBufWords + 1);
  localparam int unsigned RespBufPtrW      = idx_width(RespBufWords);
  localparam int unsigned MergeWordOffset  = (MshrMergeWords <= 1) ? 0 : $clog2(MshrMergeWords);
  localparam int unsigned BurstAlignBits  = (MaxBurstWords > 1) ? $clog2(MaxBurstWords) : 1;
  localparam int unsigned TileIdBits       = idx_width(NumTilesPerGroup);
  localparam int unsigned TcdmAddrNoTileW  = $bits(tcdm_addr_t) - TileIdBits;
  localparam int unsigned SpatzNumOutstandingLoads = snitch_pkg::NumIntOutstandingLoads;
  // Address-banking geometry (Increment 3): MshrBankNum banks of MshrWaysPerBank entries each.
  localparam int unsigned MshrBankNum = (MshrWaysPerBank > 0) ? (MshrNum / MshrWaysPerBank) : 1;
  localparam int unsigned BankIdW     = idx_width(MshrBankNum);
  // Current coalescer merges only exact 32-bit words (MshrMergeWords should be 1).

  // Map a (target group, merge address key) to its MSHR bank: XOR-fold address bits ABOVE the
  // burst-alignment boundary together with the target group. Pure function of {group,addr} (no
  // requester dependence) so all same-(group,line) requests hash to the same bank (cross-tile merge
  // preserved); folding above BurstAlignBits keeps a burst's beats within one bank.
  function automatic logic [BankIdW-1:0] mshr_bank_of(input tcdm_addr_t addr_key, input group_id_t grp);
    logic [BankIdW-1:0] b;
    b = BankIdW'(grp);
    for (int i = BurstAlignBits; i < $bits(tcdm_addr_t); i++) begin
      b[(i - BurstAlignBits) % BankIdW] = b[(i - BurstAlignBits) % BankIdW] ^ addr_key[i];
    end
    return b;
  endfunction

  // Per-entry MSHR lifecycle:
  // - IDLE       : entry is free/unused (typically valid=0).
  // - WAIT_RESP  : entry is allocated; requests are tracked while waiting for NoC data.
  // - DRAIN_RESP : at least one response beat is buffered; current head beat is draining to sub-requests.
  // - CACHED     : best-effort response cache state (no pending sub-requests, data kept for hits).
  //                On a cache hit the entry can go back to DRAIN_RESP; on replacement it is reallocated.
  typedef enum logic [1:0] {
    MSHR_IDLE       = 2'b00,
    MSHR_WAIT_RESP  = 2'b01,
    MSHR_DRAIN_RESP = 2'b10,
    MSHR_CACHED     = 2'b11
  } mshr_state_t;

  typedef struct packed {
    logic           valid;
    tile_group_id_t tile_id;
    logic [RespPortIdW-1:0] port_id;
    tile_core_id_t  core_id;
    // Base meta_id of this requester; per-beat meta_id is computed as
    // (meta_id_base + beat_offset) when draining a returned beat.
    meta_id_t       meta_id_base;
    amo_t           amo;
  } mempool_group_mshr_sub_req_t;

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
    // Per-head-beat pending mask: bit s=1 means requester s still needs the current
    // buffered response beat; cleared as each requester is serviced.
    logic [MshrMergeReqs-1:0] beat_pending;
    // Number of response beats still required to complete the whole entry.
    // Decremented once per fully drained beat.
    logic [BurstLenWidth-1:0] beats_left;
    // Per-beat bookkeeping (no per-beat payload stored here):
    // - beat_seen[b]   : beat b has been captured from NoC (possibly out-of-order)
    // - beat_done[b]   : beat b has been fully drained to all merged requesters
    logic [MaxBurstWords-1:0] beat_seen;
    logic [MaxBurstWords-1:0] beat_done;
    // Small per-entry response FIFO to absorb returning beats while outputs are
    // temporarily blocked or responses arrive from multiple channels.
    tcdm_master_resp_t [RespBufWords-1:0] resp_buf;
    // Valid bit per response-buffer slot.
    logic [RespBufWords-1:0] resp_buf_valid;
    // Number of valid beats currently stored in resp_buf.
    logic [RespBufCountW-1:0] resp_buf_cnt;
    // Read pointer of resp_buf head beat to be drained next.
    logic [RespBufPtrW-1:0] resp_buf_rd_ptr;
    // Write pointer where the next captured response beat is stored.
    logic [RespBufPtrW-1:0] resp_buf_wr_ptr;
    // Convenience mirror of (resp_buf_cnt != 0), used by scheduling logic.
    logic resp_valid;
`ifndef TARGET_SYNTHESIS
    // Debug: number of cached hits before this entry is reallocated.
    logic [31:0] cache_hit_cnt;
`endif
    // Entry lifecycle state (IDLE/WAIT_RESP/DRAIN_RESP/CACHED).
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
  mempool_group_mshr_t [MshrNum-1:0]                                           mshr_q;
  logic                [MshrNum-1:0]                                           mshr_d_valid;
  logic                [MshrNum-1:0]                                           mshr_q_valid;
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
  // give each bank its lowest free (or reclaimable-CACHED) way; only one candidate per bank is granted
  // an allocation per cycle, the rest stall and merge once the entry becomes resident next cycle.
  logic    [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_cand;
  logic    [MshrBankNum-1:0]                                                   bank_has_free;
  mshr_id_t[MshrBankNum-1:0]                                                   bank_free_id;

  // Response drain scheduling (per response port).
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]
             [idx_width(MshrMergeReqs)-1:0]                                    resp_sel_subreq_idx;
  logic      [MshrNum-1:0][SubReqCountW-1:0]                                   drain_count;
  logic      [MshrNum-1:0][BurstLenWidth-1:0]                                  resp_beat_offset;
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
  logic [63-1:0]                                                               stat_req_alloc_cycle;
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
  logic [63-1:0]                                                               stat_req_alloc;
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

  // True when two modulo-meta_id ranges overlap:
  // [base_a, base_a+len_a-1] and [base_b, base_b+len_b-1].
  function automatic logic meta_range_overlap(input meta_id_t base_a,
                                              input logic [BurstLenWidth-1:0] len_a,
                                              input meta_id_t base_b,
                                              input logic [BurstLenWidth-1:0] len_b);
    logic hit_any;
    hit_any = 1'b0;
    for (int i = 0; i < MaxBurstWords; i++) begin
      if ((i < len_a) && (((base_a + meta_id_t'(i)) - base_b) < len_b)) begin
        hit_any = 1'b1;
      end
    end
    meta_range_overlap = hit_any;
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
          (mshr_q[mshr_i].resp_valid == (mshr_q[mshr_i].resp_buf_cnt != '0)))
        else $fatal(1, "MSHR resp_valid mismatch with resp_buf_cnt: mshr=%0d valid=%0d cnt=%0d",
                    mshr_i, mshr_q[mshr_i].resp_valid, mshr_q[mshr_i].resp_buf_cnt);

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

      beat_done_subset_seen: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !mshr_q_valid[mshr_i] ||
          ((mshr_q[mshr_i].beat_done & ~mshr_q[mshr_i].beat_seen) == '0))
        else $fatal(1, "MSHR beat_done not subset of beat_seen: mshr=%0d seen=0x%0x done=0x%0x",
                    mshr_i, mshr_q[mshr_i].beat_seen, mshr_q[mshr_i].beat_done);

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
                    mshr_d[mshr_i].resp_buf[mshr_d[mshr_i].resp_buf_rd_ptr].rdata.meta_id,
                    mshr_d[mshr_i].sub_reqs[0].meta_id_base,
                    mshr_d[mshr_i].sub_reqs_num,
                    mshr_d[mshr_i].beat_pending);
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
  always_comb begin
    mshr_resp_seen_now = '0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        if (resp_in_valid[tile_i][port_i] &&
            (resp_in[tile_i][port_i].wen == 1'b0) &&
            (resp_in[tile_i][port_i].rdata.amo == '0)) begin
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

  // Increment 3: address-banking replaces the O(ports^2) same-cycle leader/follower coalescing.
  // Each request maps to bank_of({tgt_group, merge addr}); allocation and the hit search are confined
  // to that bank's ways. Same-cycle same-address misses now allocate two entries in the same bank
  // (each with its own Tier-b tag and response) instead of one coalesced entry; staggered same-address
  // requests still coalesce via the normal MSHR-hit path on the following cycle. This also removes
  // audit bug H2 (a follower could merge into an entry a meta-conflicted leader never allocated).
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_bank_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_bank_port
        assign req_bank[tile_i][port_i] =
            mshr_bank_of(req_addr_key[tile_i][port_i], req_in[tile_i][port_i].tgt_group_id);
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
          assign req_addr_hit_drain_way[tile_i][port_i][way_i] =
              req_addr_hit_way[tile_i][port_i][way_i] &&
              (mshr_q[e_abs].state == MSHR_DRAIN_RESP);

          assign req_hit_way[tile_i][port_i][way_i] =
              req_can_merge[tile_i][port_i] &&
              req_addr_hit_way[tile_i][port_i][way_i] &&
              (mshr_q[e_abs].burst_len == req_len[tile_i][port_i]) &&
              (((mshr_q[e_abs].state == MSHR_WAIT_RESP) &&
                (mshr_q[e_abs].beats_left == mshr_q[e_abs].burst_len)) ||
               (EnableRespCache && !amo_invalidate &&
                (mshr_q[e_abs].state == MSHR_CACHED) &&
                mshr_q[e_abs].resp_valid &&
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
               (mshr_q[mshr_i].state == MSHR_DRAIN_RESP)) &&
              (mshr_q[mshr_i].sub_reqs[0].tile_id == tile_group_id_t'(tile_i)) &&
              (mshr_q[mshr_i].sub_reqs[0].core_id == req_in[tile_i][port_i].wdata.core_id) &&
              // Keep same-entry hits legal; block only cross-entry overlaps.
              !same_addr_excl &&
              meta_range_overlap(req_in[tile_i][port_i].wdata.meta_id,
                                 req_len[tile_i][port_i],
                                 mshr_q[mshr_i].sub_reqs[0].meta_id_base,
                                 mshr_q[mshr_i].burst_len);
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

  // Per-bank free-way lookup: lowest free (or reclaimable CACHED) way in each bank.
  always_comb begin
    int e;
    for (int b = 0; b < MshrBankNum; b++) begin
      bank_has_free[b] = 1'b0;
      bank_free_id[b]  = mshr_id_t'(b * MshrWaysPerBank);
      for (int w = 0; w < MshrWaysPerBank; w++) begin
        e = b * MshrWaysPerBank + w;
        if (!bank_has_free[b] &&
            (!mshr_q_valid[e] ||
             (EnableRespCache &&
              mshr_q_valid[e] &&
              (mshr_q[e].state == MSHR_CACHED) &&
              (mshr_q[e].sub_reqs_num == '0) &&
              !mshr_hit_req[e]))) begin
          bank_has_free[b] = 1'b1;
          bank_free_id[b]  = mshr_id_t'(e);
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
  always_comb begin
    int b;
    int alloc_base;
    logic [MshrBankNum-1:0] bank_alloc_taken;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_alloc_found[tile_i][port_i]         = 1'b0;
        req_alloc_found_mshr_id[tile_i][port_i] = '0;
      end
    end
    bank_alloc_taken = '0;
    // Visit the NumAllocSlots flattened (tile,port) requester slots starting at the RR base, so the
    // first candidate for each bank in ROTATED order wins it. slot = tile*NumReqPortsActive+(port-1)
    // is a bijection over the active req ports (1..NumRemoteReqPortsPerTile-1); the /,% by
    // NumReqPortsActive is a shift/bit-select for the power-of-two port count here, not a divider.
    alloc_base = EnableRrFairness ? int'(alloc_rr_q) : 0;
    for (int k = 0; k < NumAllocSlots; k++) begin
      automatic int slot   = (alloc_base + k) % NumAllocSlots;
      automatic int tile_i = slot / NumReqPortsActive;
      automatic int port_i = (slot % NumReqPortsActive) + 1;
      b = int'(req_bank[tile_i][port_i]);
      if (req_alloc_cand[tile_i][port_i] && !bank_alloc_taken[b] && bank_has_free[b]) begin
        req_alloc_found[tile_i][port_i]         = 1'b1;
        req_alloc_found_mshr_id[tile_i][port_i] = bank_free_id[b];
        bank_alloc_taken[b]                     = 1'b1;
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
  `FF(mshr_q_valid, mshr_d_valid, '0)
  `FF(mshr_q, mshr_d, '0)

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
          mshr_q[mshr_i].resp_valid;
      assign mshr_q_valid_uncached[mshr_i] =
          mshr_q_valid[mshr_i] &&
          (!EnableRespCache ||
           (mshr_q[mshr_i].state != MSHR_CACHED) ||
           !mshr_q[mshr_i].resp_valid);
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
    e16_curr_sig[1:0]   = mshr_q[16].state;
    e16_curr_sig[2]     = mshr_q_valid[16];
    e16_curr_sig[10:3]  = mshr_q[16].sub_reqs_num;
    e16_curr_sig[18:11] = mshr_q[16].beat_pending[7:0];
    e16_curr_sig[26:19] = {mshr_q[16].sub_reqs[7].valid,
                            mshr_q[16].sub_reqs[6].valid,
                            mshr_q[16].sub_reqs[5].valid,
                            mshr_q[16].sub_reqs[4].valid,
                            mshr_q[16].sub_reqs[3].valid,
                            mshr_q[16].sub_reqs[2].valid,
                            mshr_q[16].sub_reqs[1].valid,
                            mshr_q[16].sub_reqs[0].valid};
    e16_curr_sig[34:27] = 8'(mshr_q[16].resp_buf_cnt); // zero-extend (width varies by config)
    e16_curr_sig[35]    = mshr_q[16].resp_valid;
    e16_curr_sig[39:36] = mshr_q[16].beats_left[3:0];
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
  always_comb begin
    int unsigned merge_new_idx;
    // Defaults
    mshr_d = mshr_q;
    mshr_d_valid = mshr_q_valid;

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
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].valid = 1'b1;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].tile_id = tile_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].port_id = port_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].core_id =
                    req_in[tile_i][port_i].wdata.core_id;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].meta_id_base =
                    req_in[tile_i][port_i].wdata.meta_id;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[merge_new_idx].amo =
                    req_in[tile_i][port_i].wdata.amo;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num =
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num + SubReqCountW'(1);
                if (EnableRespCache &&
                    (mshr_d[req_merge_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].state = MSHR_DRAIN_RESP;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beats_left = BurstLenWidth'(1);
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_pending = '0;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_seen = '0;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_seen[0] = 1'b1;
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].beat_done = '0;
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
              req_in_ready[tile_i][port_i]  = req_out_ready[tile_i][port_i];
              req_out_valid[tile_i][port_i] = 1'b1;
              if (req_can_merge[tile_i][port_i]) begin
                // Allocate a new MSHR entry (only the bank's slot winner has req_alloc_found set;
                // bank-full mergeable misses fall through here as a plain bypass).
                if (req_alloc_found[tile_i][port_i] &&
                    req_in_ready[tile_i][port_i]) begin
                mshr_d_valid[req_alloc_found_mshr_id[tile_i][port_i]] = 1'b1;
                // Tier-b: stamp the egress NoC request with (allocated entry id + 1) so the returning
                // response routes back to this entry by direct index (tag 0 stays the bypass sentinel).
                req_out[tile_i][port_i].mshr_tag =
                    MshrTagWidth'(req_alloc_found_mshr_id[tile_i][port_i]) + MshrTagWidth'(1);
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]] = '0;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].base_addr =
                    req_addr_key[tile_i][port_i];
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].tgt_group_id =
                    req_in[tile_i][port_i].tgt_group_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].burst_len =
                    req_len[tile_i][port_i];
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].state      = MSHR_WAIT_RESP;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].resp_valid = 1'b0;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beats_left =
                    req_len[tile_i][port_i];
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beat_pending = '0;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beat_seen = '0;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].beat_done = '0;
                // Owner request is always stored in sub_reqs[0].
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].valid = 1'b1;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].tile_id = tile_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].port_id = port_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].core_id =
                    req_in[tile_i][port_i].wdata.core_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].meta_id_base =
                    req_in[tile_i][port_i].wdata.meta_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].amo =
                    req_in[tile_i][port_i].wdata.amo;
`ifndef TARGET_SYNTHESIS
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].cache_hit_cnt = '0;
`endif
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs_num =
                    SubReqCountW'(1);
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
                automatic int hit_e =
                    int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i;
                if (mshr_d_valid[hit_e] &&
                    (mshr_d[hit_e].state == MSHR_CACHED) &&
                    req_addr_hit_way[tile_i][port_i][way_i]) begin
                  // H3 fix: merge under byte-enables — a sub-word store must update only the
                  // enabled byte lanes and keep the existing cached bytes (writing the full word
                  // would corrupt the non-written bytes that a later cache-hit load would read).
                  for (int b = 0; b < $bits(req_in[tile_i][port_i].be); b++) begin
                    if (req_in[tile_i][port_i].be[b]) begin
                      mshr_d[hit_e].resp_buf[mshr_d[hit_e].resp_buf_rd_ptr]
                            .rdata.data[b*8 +: 8] =
                          req_in[tile_i][port_i].wdata.data[b*8 +: 8];
                    end
                  end
                  mshr_d[hit_e].resp_buf[mshr_d[hit_e].resp_buf_rd_ptr].wen = 1'b0;
                  mshr_d[hit_e].resp_buf_valid[mshr_d[hit_e].resp_buf_rd_ptr] = 1'b1;
                  if (mshr_d[hit_e].resp_buf_cnt == '0) begin
                    mshr_d[hit_e].resp_buf_cnt = RespBufCountW'(1);
                  end
                  mshr_d[hit_e].resp_valid = 1'b1;
                end
              end
            end
          end
        end else begin
          req_in_ready[tile_i][port_i] = 1'b1;
        end
      end
    end

    // AMO invalidates all cached entries (cache is best-effort only).
    if (EnableRespCache && amo_invalidate) begin
      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].state == MSHR_CACHED)) begin
          mshr_d_valid[mshr_i] = 1'b0;
          mshr_d[mshr_i] = '0;
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
            automatic mshr_id_t cand =
                mshr_id_t'(resp_in[tile_i][port_i].mshr_tag - MshrTagWidth'(1));
            if (mshr_q_valid[cand] &&
                ((mshr_q[cand].state == MSHR_WAIT_RESP) ||
                 (mshr_q[cand].state == MSHR_DRAIN_RESP)) &&
                (mshr_q[cand].sub_reqs[0].tile_id == tile_group_id_t'(tile_i)) &&
                (mshr_q[cand].sub_reqs[0].core_id == resp_in[tile_i][port_i].rdata.core_id) &&
                ((resp_in[tile_i][port_i].rdata.meta_id -
                  mshr_q[cand].sub_reqs[0].meta_id_base) < mshr_q[cand].burst_len)) begin
              resp_is_mshr[tile_i][port_i] = 1'b1;
              resp_mshr_id[tile_i][port_i] = cand;
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
          resp_from_bypass[tile_i][port_i] = 1'b1;
        end
      end
    end

    // Capture MSHR responses
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        if (resp_capture_fire[tile_i][port_i]) begin
          if (mshr_d[resp_mshr_id[tile_i][port_i]].beat_seen[resp_capture_beat_offset[tile_i][port_i]]) begin
            $fatal(1, "MSHR duplicate response beat: mshr=%0d beat=%0d meta=%0d",
                   resp_mshr_id[tile_i][port_i],
                   resp_capture_beat_offset[tile_i][port_i],
                   resp_in[tile_i][port_i].rdata.meta_id);
          end
          mshr_d[resp_mshr_id[tile_i][port_i]].resp_buf[resp_push_ptr[resp_mshr_id[tile_i][port_i]]] =
              resp_in[tile_i][port_i];
          mshr_d[resp_mshr_id[tile_i][port_i]].resp_buf_valid[resp_push_ptr[resp_mshr_id[tile_i][port_i]]] =
              1'b1;
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
          mshr_d[resp_mshr_id[tile_i][port_i]].resp_valid = 1'b1;
          mshr_d[resp_mshr_id[tile_i][port_i]].state      = MSHR_DRAIN_RESP;
          mshr_d[resp_mshr_id[tile_i][port_i]].beat_seen[resp_capture_beat_offset[tile_i][port_i]] = 1'b1;
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
              mshr_d[mshr_i].resp_buf[mshr_d[mshr_i].resp_buf_rd_ptr].rdata.meta_id -
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
            automatic int drain_base = EnableRrFairness ? int'(drain_mshr_rr_q) : 0;
            for (int kk = 0; kk < MshrNum; kk++) begin
              automatic int mshr_i = (drain_base + kk) % MshrNum;
              if (mshr_d_valid[mshr_i] && mshr_d[mshr_i].resp_valid &&
                  mshr_d[mshr_i].state == MSHR_DRAIN_RESP) begin
                automatic int subreq_base = EnableRrFairness ? int'(subreq_rr_q) : 0;
                for (int ks = 0; ks < MshrMergeReqs; ks++) begin
                  automatic int s = (subreq_base + ks) % MshrMergeReqs;
                  if (!resp_sel_valid[tile_i][port_i] &&
                      mshr_d[mshr_i].sub_reqs[s].valid &&
                      mshr_d[mshr_i].beat_pending[s] &&
                      !subreq_claimed[mshr_i][s] &&
                      (mshr_d[mshr_i].sub_reqs[s].tile_id == tile_group_id_t'(tile_i)) &&
                      (map_resp_port_id(mshr_d[mshr_i].sub_reqs[s].port_id) ==
                       port_i[RespPortIdW-1:0])) begin
                    resp_sel_valid[tile_i][port_i] = 1'b1;
                    resp_sel_mshr_id[tile_i][port_i] = mshr_id_t'(mshr_i);
                    resp_sel_subreq_idx[tile_i][port_i] = s[idx_width(MshrMergeReqs)-1:0];
                    subreq_claimed[mshr_i][s] = 1'b1;
                  end
                end
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
            resp_out[tile_i][port_i].wen =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]]
                      .resp_buf[mshr_d[resp_sel_mshr_id[tile_i][port_i]].resp_buf_rd_ptr].wen;
            resp_out[tile_i][port_i].rdata.data =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]]
                      .resp_buf[mshr_d[resp_sel_mshr_id[tile_i][port_i]].resp_buf_rd_ptr].rdata.data;
            resp_out[tile_i][port_i].rdata.core_id =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].core_id;
            resp_out[tile_i][port_i].rdata.meta_id =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].meta_id_base +
                meta_id_t'(resp_beat_offset[resp_sel_mshr_id[tile_i][port_i]]);
            resp_out[tile_i][port_i].rdata.amo =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].amo;
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

    end else begin
      // Original behavior: one sub-request per MSHR per cycle.
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
      for (int kk = 0; kk < MshrNum; kk++) begin
        automatic int drain_base = EnableRrFairness ? int'(drain_mshr_rr_q) : 0;
        automatic int mshr_i = (drain_base + kk) % MshrNum;
        drain_subreq_found[mshr_i] = 1'b0;
        drain_subreq_idx[mshr_i] = '0;
        drain_dst_tile[mshr_i] = '0;
        drain_dst_port[mshr_i] = '0;
        drain_port_found[mshr_i] = 1'b0;
        if (mshr_d_valid[mshr_i] && mshr_d[mshr_i].resp_valid &&
            mshr_d[mshr_i].state == MSHR_DRAIN_RESP) begin
          // RR fairness (audit L3): rotate the sub_req visit, keep the first-match break.
          for (int ks = 0; ks < MshrMergeReqs; ks++) begin
            automatic int subreq_base = EnableRrFairness ? int'(subreq_rr_q) : 0;
            automatic int s = (subreq_base + ks) % MshrMergeReqs;
            if (mshr_d[mshr_i].sub_reqs[s].valid &&
                mshr_d[mshr_i].beat_pending[s]) begin
              drain_subreq_found[mshr_i] = 1'b1;
              drain_subreq_idx[mshr_i] = s[idx_width(MshrMergeReqs)-1:0];
              break;
            end
          end

          if (drain_subreq_found[mshr_i]) begin
            drain_dst_tile[mshr_i] = mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].tile_id;
            drain_dst_port[mshr_i] =
                map_resp_port_id(mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].port_id);
            if (!port_taken[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]]) begin
              drain_port_found[mshr_i] = 1'b1;
            end

            if (drain_port_found[mshr_i]) begin
              resp_out_valid[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = 1'b1;
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].wen =
                  mshr_d[mshr_i].resp_buf[mshr_d[mshr_i].resp_buf_rd_ptr].wen;
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.data =
                  mshr_d[mshr_i].resp_buf[mshr_d[mshr_i].resp_buf_rd_ptr].rdata.data;
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.core_id =
                  mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].core_id;
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.meta_id =
                  mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].meta_id_base +
                  meta_id_t'(resp_beat_offset[mshr_i]);
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.amo =
                  mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].amo;
              resp_from_mshr[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = 1'b1;
              resp_mshr_id_dbg[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = mshr_id_t'(mshr_i);

              if (resp_out_ready[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]]) begin
                mshr_d[mshr_i].beat_pending[drain_subreq_idx[mshr_i]] = 1'b0;
                if (mshr_d[mshr_i].burst_len == BurstLenWidth'(1)) begin
                  mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].valid = 1'b0;
                end
              end
              port_taken[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = 1'b1;
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
            mshr_d[mshr_i].beat_done[resp_beat_offset[mshr_i]] = 1'b1;
            mshr_d[mshr_i].beats_left = '0;
            mshr_d[mshr_i].state = MSHR_CACHED;
            mshr_d[mshr_i].resp_valid = (mshr_d[mshr_i].resp_buf_cnt != '0);
          end else begin
            // Pop the drained head beat.
            if (mshr_d[mshr_i].resp_buf_cnt != '0) begin
              mshr_d[mshr_i].resp_buf_valid[mshr_d[mshr_i].resp_buf_rd_ptr] = 1'b0;
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
            mshr_d[mshr_i].beat_done[resp_beat_offset[mshr_i]] = 1'b1;
            if (mshr_d[mshr_i].beats_left == BurstLenWidth'(1)) begin
              mshr_d_valid[mshr_i] = 1'b0;
              mshr_d[mshr_i] = '0;
            end else begin
              if (mshr_d[mshr_i].beats_left != '0) begin
                mshr_d[mshr_i].beats_left = mshr_d[mshr_i].beats_left - BurstLenWidth'(1);
              end
              if (resp_cnt_after_pop[mshr_i] != '0) begin
                mshr_d[mshr_i].state = MSHR_DRAIN_RESP;
                mshr_d[mshr_i].resp_valid = 1'b1;
              end else begin
                mshr_d[mshr_i].state = MSHR_WAIT_RESP;
                mshr_d[mshr_i].resp_valid = 1'b0;
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
                                 input logic [63-1:0] cache_amo_inval);
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
          $display("  cache: valid_avg=%0f valid_max=%0d hit=%0d fill=%0d evict=%0d store_update=%0d amo_inval=%0d",
                   avg_cache_valid, cache_max_valid, cache_hit, cache_fill, cache_evict,
                   cache_store_update, cache_amo_inval);
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
        stat_req_alloc_cycle = '0;
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
                    (mshr_q[mshr_i].state == MSHR_WAIT_RESP) &&
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
              end else begin
                stat_req_bypass_cycle = stat_req_bypass_cycle + 1'b1;
                if (req_can_merge[tile_i][port_i]) begin
                  if (req_alloc_found[tile_i][port_i]) begin
                    stat_req_alloc_cycle = stat_req_alloc_cycle + 1'b1;
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
          stat_req_alloc <= 0;
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
          stat_req_alloc_next = stat_req_alloc;
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
            stat_req_alloc_next = stat_req_alloc + stat_req_alloc_cycle;
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
                        stat_cache_amo_inval_next);
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
            stat_req_alloc <= 0;
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
            stat_req_alloc <= stat_req_alloc_next;
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
                      stat_cache_amo_inval);
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
          (mshr_bank_of(mshr_q[mshr_i].base_addr, mshr_q[mshr_i].tgt_group_id) ==
           BankIdW'(mshr_i / MshrWaysPerBank)))
        else $fatal(1, "MSHR entry %0d not in its address bank (got %0d, expected %0d)",
                    mshr_i,
                    mshr_bank_of(mshr_q[mshr_i].base_addr, mshr_q[mshr_i].tgt_group_id),
                    mshr_i / MshrWaysPerBank);
    end
  endgenerate
  `endif
  // pragma translate_on

endmodule : mempool_group_mshr
