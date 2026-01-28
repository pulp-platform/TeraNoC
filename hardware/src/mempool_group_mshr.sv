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

  parameter int MshrNum        = NumTilesPerGroup * 32,
  parameter int MshrMergeWords = 1,
  parameter int MshrMergeReqs  = 8,
  // 0: drain one sub-request per MSHR per cycle (original behavior)
  // 1: drain as many sub-requests as ports allow per cycle
  parameter bit DrainMultiPort = 1'b1,
  // Keep responded entries as a small read-response cache.
  parameter bit EnableRespCache = 1'b1,
  // Simulation-only statistics/prints (translate_off).
  parameter bit EnableStats   = 1'b1,
  // Stats print period in cycles while trace is active (0 disables periodic prints).
  parameter int unsigned StatsPeriod = 1000,
  // Spill register enables (0 = pass-through).
  parameter bit SpillReqIn     = 1'b0,
  parameter bit SpillReqOut    = 1'b1,
  parameter bit SpillRespIn    = 1'b0,
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
  localparam int unsigned MergeWordOffset  = (MshrMergeWords <= 1) ? 0 : $clog2(MshrMergeWords);
  localparam int unsigned SpatzNumOutstandingLoads = snitch_pkg::NumIntOutstandingLoads;
  // Current coalescer merges only exact 32-bit words (MshrMergeWords should be 1).

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
    meta_id_t       meta_id;
    amo_t           amo;
  } mempool_group_mshr_sub_req_t;

  typedef struct packed {
    tcdm_addr_t base_addr;
    group_id_t tgt_group_id;
    // sub_reqs[0] is always reserved for the owner request.
    mempool_group_mshr_sub_req_t [MshrMergeReqs-1:0] sub_reqs;
    logic [SubReqCountW-1:0] sub_reqs_num;
    tcdm_master_resp_t resp_buf;
    logic resp_valid;
    mshr_state_t state;
  } mempool_group_mshr_t;

  typedef logic [idx_width(MshrNum)-1:0] mshr_id_t;
  typedef struct packed {
    tile_group_id_t tile_id;
    logic [RespPortIdW-1:0] port_id;
  } req_id_t;

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
  tcdm_addr_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_addr_key;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrNum-1:0] req_addr_hit_map;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][MshrNum-1:0] req_hit_mshr_map;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr_sel_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_hit_mshr_sel_id;
  logic      [MshrNum-1:0][NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] mshr_hit_req_map;
  logic      [MshrNum-1:0]                                                     mshr_hit_req;

  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][NumTilesPerGroup-1:0]
             [NumRemoteReqPortsPerTile-1:1]                                                       req_hit_req_map; // only compare smaller idx
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_hit_req;
  tile_group_id_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                             req_leader_tile;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][ReqPortIdW-1:0]                 req_leader_port;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_leader_alloc_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_leader_alloc_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_leader_alloc_ready;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                                 req_merge_ready;
  logic                                                                                           amo_invalidate;

  // Request allocation (banked allocator bookkeeping).
  logic    [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found;
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found_mshr_id;
  logic    [MshrNum-1:0]                                                       mshr_alloc_found;
  req_id_t [MshrNum-1:0]                                                       mshr_alloc_found_req_id;

  // Response drain scheduling (per response port).
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel_valid;
  mshr_id_t  [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]             resp_sel_mshr_id;
  logic      [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]
             [idx_width(MshrMergeReqs)-1:0]                                    resp_sel_subreq_idx;
  logic      [MshrNum-1:0][SubReqCountW-1:0]                                   drain_count;
  // Response drain scheduling (single-response per MSHR).
  logic      [MshrNum-1:0]                                                     drain_subreq_found;
  logic      [idx_width(MshrMergeReqs)-1:0]                                    drain_subreq_idx [MshrNum-1:0];
  tile_group_id_t[MshrNum-1:0]                                                 drain_dst_tile;
  logic      [RespPortIdW-1:0]                                                 drain_dst_port [MshrNum-1:0];
  logic      [MshrNum-1:0]                                                     drain_last_subreq;
  logic      [MshrNum-1:0]                                                     drain_port_found;
  logic      [MshrNum-1:0][MshrMergeReqs-1:0]                                  subreq_claimed;

  // Performance counters (simulation only).
  // pragma translate_off
  `ifndef VERILATOR
  logic [63-1:0]                                                               stat_mshr_valid_cycle;
  logic [63-1:0]                                                               stat_cache_valid_cycle;
  logic [63-1:0]                                                               stat_subreq_valid_cycle;
  logic [63-1:0]                                                               stat_req_accept_cycle;
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
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              stat_req_subreq_full_match;

  logic [63-1:0]                                                               stat_cycle_count;
  logic [63-1:0]                                                               stat_mshr_valid_acc;
  logic [63-1:0]                                                               stat_cache_valid_acc;
  logic [63-1:0]                                                               stat_subreq_valid_acc;
  logic [63-1:0]                                                               stat_mshr_max_valid;
  logic [63-1:0]                                                               stat_cache_max_valid;
  logic [63-1:0]                                                               stat_subreq_max_valid;
  logic [63-1:0]                                                               stat_req_accept;
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
  `endif
  // pragma translate_on

  function automatic tcdm_addr_t merge_addr_key(input tcdm_addr_t addr);
    if (MergeWordOffset == 0) begin
      merge_addr_key = addr;
    end else begin
      merge_addr_key = {addr[$bits(tcdm_addr_t)-1:MergeWordOffset], {MergeWordOffset{1'b0}}};
    end
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

  // Decode request type and address key for merge lookup.
  always_comb begin
    amo_invalidate = 1'b0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_is_load[tile_i][port_i] = req_in_valid[tile_i][port_i] &&
                                      ~req_in[tile_i][port_i].wen &&
                                      (req_in[tile_i][port_i].wdata.amo == '0);
        req_is_store[tile_i][port_i] = req_in_valid[tile_i][port_i] &&
                                       req_in[tile_i][port_i].wen &&
                                       (req_in[tile_i][port_i].wdata.amo == '0);
        if (req_in_valid[tile_i][port_i] &&
            (req_in[tile_i][port_i].wdata.amo != '0)) begin
          amo_invalidate = 1'b1;
        end
        if (req_in_valid[tile_i][port_i]) begin
          req_addr_key[tile_i][port_i] =
              merge_addr_key(req_in[tile_i][port_i].tgt_addr);
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

  // Request-to-request hit lookup (parallel compare).
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_hit_req_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_hit_req_port
        for (genvar oth_tile_i = 0; oth_tile_i < NumTilesPerGroup; oth_tile_i++) begin : gen_req_hit_req_oth_tile
          for (genvar oth_port_i = 1; oth_port_i < NumRemoteReqPortsPerTile; oth_port_i++) begin : gen_req_hit_req_oth_port
            // only compare the requests with smaller idx than itself
            if (tile_i * (NumRemoteReqPortsPerTile - 1) + (port_i - 1) <=
                oth_tile_i * (NumRemoteReqPortsPerTile - 1) + (oth_port_i - 1)) begin
              assign req_hit_req_map[tile_i][port_i][oth_tile_i][oth_port_i] = 1'b0;
            end else begin
              assign req_hit_req_map[tile_i][port_i][oth_tile_i][oth_port_i] =
                  req_is_load[tile_i][port_i] &&
                  req_is_load[oth_tile_i][oth_port_i] &&
                  (req_addr_key[tile_i][port_i] == req_addr_key[oth_tile_i][oth_port_i]) &&
                  (req_in[tile_i][port_i].tgt_group_id ==
                   req_in[oth_tile_i][oth_port_i].tgt_group_id);
            end
          end
        end
        assign req_hit_req[tile_i][port_i] = |req_hit_req_map[tile_i][port_i];
      end
    end
  endgenerate

  // Select the first matching request (smallest index) as leader.
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_leader_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_leader_port
        always_comb begin
          req_leader_tile[tile_i][port_i] = tile_group_id_t'(tile_i);
          req_leader_port[tile_i][port_i] = port_i[ReqPortIdW-1:0];
          for (int oth_tile_i = 0; oth_tile_i < NumTilesPerGroup; oth_tile_i++) begin
            for (int oth_port_i = 1; oth_port_i < NumRemoteReqPortsPerTile; oth_port_i++) begin
              if ((req_leader_tile[tile_i][port_i] == tile_group_id_t'(tile_i)) &&
                  (req_leader_port[tile_i][port_i] == port_i[ReqPortIdW-1:0]) &&
                  req_hit_req_map[tile_i][port_i][oth_tile_i][oth_port_i]) begin
                req_leader_tile[tile_i][port_i] = tile_group_id_t'(oth_tile_i);
                req_leader_port[tile_i][port_i] = oth_port_i[ReqPortIdW-1:0];
              end
            end
          end
        end
      end
    end
  endgenerate

  // MSHR hit lookup (parallel compare).
  generate
    for (genvar tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin : gen_req_mshr_lookup_tile
      for (genvar port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin : gen_req_mshr_lookup_port
        for (genvar mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin : gen_req_mshr_lookup_entry
          assign req_addr_hit_map[tile_i][port_i][mshr_i] =
              req_in_valid[tile_i][port_i] &&
              mshr_q_valid[mshr_i] &&
              (mshr_q[mshr_i].base_addr == req_addr_key[tile_i][port_i]) &&
              (mshr_q[mshr_i].tgt_group_id == req_in[tile_i][port_i].tgt_group_id);
          assign req_hit_mshr_map[tile_i][port_i][mshr_i] =
              req_is_load[tile_i][port_i] &&
              req_addr_hit_map[tile_i][port_i][mshr_i] &&
              ((mshr_q[mshr_i].state == MSHR_WAIT_RESP) ||
               (EnableRespCache && !amo_invalidate &&
                (mshr_q[mshr_i].state == MSHR_CACHED) &&
                mshr_q[mshr_i].resp_valid)) &&
              !mshr_resp_inflight[mshr_i] &&
              (mshr_q[mshr_i].sub_reqs_num < MshrMergeReqs);
          assign mshr_hit_req_map[mshr_i][tile_i][port_i] = req_hit_mshr_map[tile_i][port_i][mshr_i];
        end
        assign req_hit_mshr[tile_i][port_i] = |req_hit_mshr_map[tile_i][port_i];
      end
    end

    for (genvar mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin : gen_mshr_hit_req
      assign mshr_hit_req[mshr_i] = |mshr_hit_req_map[mshr_i];
    end
  endgenerate

  // Select the first matching MSHR per request to avoid multi-merge.
  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_hit_mshr_sel_valid[tile_i][port_i] = 1'b0;
        req_hit_mshr_sel_id[tile_i][port_i] = '0;
        for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
          if (!req_hit_mshr_sel_valid[tile_i][port_i] &&
              req_hit_mshr_map[tile_i][port_i][mshr_i]) begin
            req_hit_mshr_sel_valid[tile_i][port_i] = 1'b1;
            req_hit_mshr_sel_id[tile_i][port_i] = mshr_id_t'(mshr_i);
          end
        end
      end
    end
  end

  localparam int unsigned ReqPortsTotal =
      NumTilesPerGroup * (NumRemoteReqPortsPerTile - 1);
  localparam int unsigned ReqsPerMshr =
      (ReqPortsTotal == 0) ? 0 : (ReqPortsTotal / MshrNum);
  localparam int unsigned MshrsPerReq =
      (ReqPortsTotal == 0) ? 0 : (MshrNum / ReqPortsTotal);

  // Banked MSHR allocation (single combinational process).
  always_comb begin
    int tile_i;
    int port_i;
    int req_i;
    int mshr_i;
    int mshr_start;
    int mshr_end;

    for (tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_alloc_found[tile_i][port_i] = 1'b0;
        req_alloc_found_mshr_id[tile_i][port_i] = '0;
      end
    end
    for (mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      mshr_alloc_found[mshr_i] = 1'b0;
      mshr_alloc_found_req_id[mshr_i] = '0;
    end

    if (MshrNum < ReqPortsTotal) begin
      for (mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        for (req_i = 0; req_i < ReqsPerMshr; req_i++) begin
          tile_i = (mshr_i * ReqsPerMshr + req_i) / (NumRemoteReqPortsPerTile - 1);
          port_i = (mshr_i * ReqsPerMshr + req_i) % (NumRemoteReqPortsPerTile - 1) + 1;
          if ((!mshr_q_valid[mshr_i] ||
               (EnableRespCache &&
                mshr_q_valid[mshr_i] &&
                (mshr_q[mshr_i].state == MSHR_CACHED) &&
                (mshr_q[mshr_i].sub_reqs_num == '0) &&
                !mshr_hit_req[mshr_i])) &&
              !mshr_alloc_found[mshr_i] &&
              req_is_load[tile_i][port_i] &&
              !req_hit_req[tile_i][port_i] &&
              !req_hit_mshr[tile_i][port_i] &&
              !req_alloc_found[tile_i][port_i]) begin
            req_alloc_found[tile_i][port_i] = 1'b1;
            req_alloc_found_mshr_id[tile_i][port_i] = mshr_id_t'(mshr_i);
            mshr_alloc_found[mshr_i] = 1'b1;
            mshr_alloc_found_req_id[mshr_i].tile_id = tile_group_id_t'(tile_i);
            mshr_alloc_found_req_id[mshr_i].port_id = port_i[RespPortIdW-1:0];
          end
        end
      end
    end else begin
      for (tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
          mshr_start = (tile_i * (NumRemoteReqPortsPerTile - 1) + (port_i - 1)) * MshrsPerReq;
          mshr_end = (tile_i * (NumRemoteReqPortsPerTile - 1) + (port_i - 1) + 1) * MshrsPerReq;
          for (mshr_i = mshr_start; mshr_i < mshr_end; mshr_i++) begin
            if ((!mshr_q_valid[mshr_i] ||
                 (EnableRespCache &&
                  mshr_q_valid[mshr_i] &&
                  (mshr_q[mshr_i].state == MSHR_CACHED) &&
                  (mshr_q[mshr_i].sub_reqs_num == '0) &&
                  !mshr_hit_req[mshr_i])) &&
                !mshr_alloc_found[mshr_i] &&
                req_is_load[tile_i][port_i] &&
                !req_hit_req[tile_i][port_i] &&
                !req_hit_mshr[tile_i][port_i] &&
                !req_alloc_found[tile_i][port_i]) begin
              req_alloc_found[tile_i][port_i] = 1'b1;
              req_alloc_found_mshr_id[tile_i][port_i] = mshr_id_t'(mshr_i);
              mshr_alloc_found[mshr_i] = 1'b1;
              mshr_alloc_found_req_id[mshr_i].tile_id = tile_group_id_t'(tile_i);
              mshr_alloc_found_req_id[mshr_i].port_id = port_i[RespPortIdW-1:0];
            end
          end
        end
      end
    end
  end

  // Track leader allocation status per request.
  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_leader_alloc_valid[tile_i][port_i] =
            req_alloc_found[req_leader_tile[tile_i][port_i]][req_leader_port[tile_i][port_i]];
        req_leader_alloc_id[tile_i][port_i] =
            req_alloc_found_mshr_id[req_leader_tile[tile_i][port_i]][req_leader_port[tile_i][port_i]];
        req_leader_alloc_ready[tile_i][port_i] =
            req_out_ready[req_leader_tile[tile_i][port_i]][req_leader_port[tile_i][port_i]];
      end
    end
  end

  // Select the merge target per request (existing MSHR or leader's new allocation).
  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_merge_valid[tile_i][port_i] =
            req_is_load[tile_i][port_i] &&
            (req_hit_mshr_sel_valid[tile_i][port_i] ||
             (req_hit_req[tile_i][port_i] && req_leader_alloc_valid[tile_i][port_i]));
        req_merge_mshr_id[tile_i][port_i] =
            req_hit_mshr_sel_valid[tile_i][port_i]
                ? req_hit_mshr_sel_id[tile_i][port_i]
                : req_leader_alloc_id[tile_i][port_i];
        req_merge_ready[tile_i][port_i] =
            req_hit_mshr_sel_valid[tile_i][port_i] ? 1'b1 : req_leader_alloc_ready[tile_i][port_i];
      end
    end
  end

  // Sequential state update
  `FF(mshr_q_valid, mshr_d_valid, '0)
  `FF(mshr_q, mshr_d, '0)

  // Main combinational control: request merge/alloc, response capture, and drain
  always_comb begin
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
          if (req_merge_valid[tile_i][port_i]) begin
            // Merge hit: accept without touching NoC.
            req_in_ready[tile_i][port_i] =
                req_merge_ready[tile_i][port_i] &&
                (mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num < MshrMergeReqs);
            if (req_in_ready[tile_i][port_i]) begin
              if (mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num < MshrMergeReqs) begin
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].valid = 1'b1;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].tile_id = tile_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].port_id = port_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].core_id =
                    req_in[tile_i][port_i].wdata.core_id;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].meta_id =
                    req_in[tile_i][port_i].wdata.meta_id;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].amo =
                    req_in[tile_i][port_i].wdata.amo;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num =
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num + 1;
                if (EnableRespCache &&
                    (mshr_d[req_merge_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                  mshr_d[req_merge_mshr_id[tile_i][port_i]].state = MSHR_DRAIN_RESP;
                end
              end
            end
          end else begin
            // Need to send to NoC (store, miss, or merge list full).
            req_in_ready[tile_i][port_i] = req_out_ready[tile_i][port_i];
            if (req_is_load[tile_i][port_i]) begin
              // Allocate a new MSHR entry for load miss if space exists.
              if (req_alloc_found[tile_i][port_i] && req_in_ready[tile_i][port_i]) begin
                mshr_d_valid[req_alloc_found_mshr_id[tile_i][port_i]] = 1'b1;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]] = '0;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].base_addr =
                    req_addr_key[tile_i][port_i];
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].tgt_group_id =
                    req_in[tile_i][port_i].tgt_group_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].state      = MSHR_WAIT_RESP;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].resp_valid = 1'b0;
                // Owner request is always stored in sub_reqs[0].
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].valid   = 1'b1;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].tile_id = tile_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].port_id = port_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].core_id =
                    req_in[tile_i][port_i].wdata.core_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].meta_id =
                    req_in[tile_i][port_i].wdata.meta_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].amo =
                    req_in[tile_i][port_i].wdata.amo;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs_num = 1;
              end
            end
            if (EnableRespCache && !amo_invalidate &&
                req_is_store[tile_i][port_i] && req_in_ready[tile_i][port_i]) begin
              for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
                if (mshr_d_valid[mshr_i] &&
                    (mshr_d[mshr_i].state == MSHR_CACHED) &&
                    req_addr_hit_map[tile_i][port_i][mshr_i]) begin
                  mshr_d[mshr_i].resp_buf.rdata.data = req_in[tile_i][port_i].wdata.data;
                  mshr_d[mshr_i].resp_buf.wen = 1'b0;
                  mshr_d[mshr_i].resp_valid = 1'b1;
                end
              end
            end
            // Forward the request to NoC (alloc or bypass).
            req_out_valid[tile_i][port_i] = 1'b1;
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
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        resp_is_mshr[tile_i][port_i] = 1'b0;
        resp_mshr_id[tile_i][port_i] = '0;
        if (resp_in_valid[tile_i][port_i] &&
            (resp_in[tile_i][port_i].wen == 1'b0) &&
            (resp_in[tile_i][port_i].rdata.amo == '0)) begin
          for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
            if (mshr_q_valid[mshr_i] &&
                mshr_q[mshr_i].state == MSHR_WAIT_RESP &&
                mshr_q[mshr_i].sub_reqs[0].valid &&
                (mshr_q[mshr_i].sub_reqs[0].tile_id == tile_group_id_t'(tile_i)) &&
                (mshr_q[mshr_i].sub_reqs[0].core_id == resp_in[tile_i][port_i].rdata.core_id) &&
                (mshr_q[mshr_i].sub_reqs[0].meta_id == resp_in[tile_i][port_i].rdata.meta_id)) begin
              resp_is_mshr[tile_i][port_i] = 1'b1;
              resp_mshr_id[tile_i][port_i] = mshr_id_t'(mshr_i);
              break;
            end
          end
        end

        if (resp_is_mshr[tile_i][port_i]) begin
          mshr_resp_inflight[resp_mshr_id[tile_i][port_i]] = 1'b1;
          resp_in_ready[tile_i][port_i] = ~mshr_q[resp_mshr_id[tile_i][port_i]].resp_valid;
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
        if (resp_in_valid[tile_i][port_i] &&
            resp_is_mshr[tile_i][port_i] &&
            resp_in_ready[tile_i][port_i]) begin
          mshr_d[resp_mshr_id[tile_i][port_i]].resp_buf   = resp_in[tile_i][port_i];
          mshr_d[resp_mshr_id[tile_i][port_i]].resp_valid = 1'b1;
          mshr_d[resp_mshr_id[tile_i][port_i]].state      = MSHR_DRAIN_RESP;
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
          port_taken[tile_i][port_i] = resp_in_valid[tile_i][port_i];
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
            for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
              if (mshr_d_valid[mshr_i] && mshr_d[mshr_i].resp_valid &&
                  mshr_d[mshr_i].state == MSHR_DRAIN_RESP) begin
                for (int s = 0; s < MshrMergeReqs; s++) begin
                  if (!resp_sel_valid[tile_i][port_i] &&
                      mshr_d[mshr_i].sub_reqs[s].valid &&
                      !subreq_claimed[mshr_i][s] &&
                      (mshr_d[mshr_i].sub_reqs[s].tile_id == tile_group_id_t'(tile_i))) begin
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
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].resp_buf.wen;
            resp_out[tile_i][port_i].rdata.data =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].resp_buf.rdata.data;
            resp_out[tile_i][port_i].rdata.core_id =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].core_id;
            resp_out[tile_i][port_i].rdata.meta_id =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].meta_id;
            resp_out[tile_i][port_i].rdata.amo =
                mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                    resp_sel_subreq_idx[tile_i][port_i]].amo;
            resp_from_mshr[tile_i][port_i] = 1'b1;
            resp_mshr_id_dbg[tile_i][port_i] = resp_sel_mshr_id[tile_i][port_i];

            if (resp_out_ready[tile_i][port_i]) begin
              mshr_d[resp_sel_mshr_id[tile_i][port_i]].sub_reqs[
                  resp_sel_subreq_idx[tile_i][port_i]].valid = 1'b0;
              drain_count[resp_sel_mshr_id[tile_i][port_i]] =
                  drain_count[resp_sel_mshr_id[tile_i][port_i]] + 1'b1;
            end
          end
        end
      end

      // Update per-entry counters and free when all drained.
      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        if (drain_count[mshr_i] != '0) begin
          if (mshr_d[mshr_i].sub_reqs_num >= drain_count[mshr_i]) begin
            mshr_d[mshr_i].sub_reqs_num = mshr_d[mshr_i].sub_reqs_num - drain_count[mshr_i];
          end else begin
            mshr_d[mshr_i].sub_reqs_num = '0;
          end
          if (mshr_d[mshr_i].sub_reqs_num == '0) begin
            if (EnableRespCache) begin
              mshr_d[mshr_i].state = MSHR_CACHED;
            end else begin
              mshr_d_valid[mshr_i] = 1'b0;
              mshr_d[mshr_i] = '0;
            end
          end
        end
      end
    end else begin
      // Original behavior: one sub-request per MSHR per cycle.
      for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
        for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
          port_taken[tile_i][port_i] = resp_in_valid[tile_i][port_i];
        end
      end

      for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
        drain_subreq_found[mshr_i] = 1'b0;
        drain_subreq_idx[mshr_i] = '0;
        drain_dst_tile[mshr_i] = '0;
        drain_dst_port[mshr_i] = '0;
        drain_last_subreq[mshr_i] = 1'b0;
        drain_port_found[mshr_i] = 1'b0;
        if (mshr_d_valid[mshr_i] && mshr_d[mshr_i].resp_valid &&
            mshr_d[mshr_i].state == MSHR_DRAIN_RESP) begin
          for (int s = 0; s < MshrMergeReqs; s++) begin
            if (mshr_d[mshr_i].sub_reqs[s].valid) begin
              drain_subreq_found[mshr_i] = 1'b1;
              drain_subreq_idx[mshr_i] = s[idx_width(MshrMergeReqs)-1:0];
              break;
            end
          end

          if (drain_subreq_found[mshr_i]) begin
            drain_dst_tile[mshr_i] = mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].tile_id;
            for (int rp = 1; rp < NumRemoteRespPortsPerTile; rp++) begin
              if (!drain_port_found[mshr_i] &&
                  !port_taken[drain_dst_tile[mshr_i]][rp]) begin
                drain_dst_port[mshr_i] = rp[RespPortIdW-1:0];
                drain_port_found[mshr_i] = 1'b1;
              end
            end

            if (drain_port_found[mshr_i]) begin
              resp_out_valid[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = 1'b1;
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].wen =
                  mshr_d[mshr_i].resp_buf.wen;
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.data =
                  mshr_d[mshr_i].resp_buf.rdata.data;
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.core_id =
                  mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].core_id;
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.meta_id =
                  mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].meta_id;
              resp_out[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.amo =
                  mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].amo;
              resp_from_mshr[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = 1'b1;
              resp_mshr_id_dbg[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = mshr_id_t'(mshr_i);

              if (resp_out_ready[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]]) begin
                drain_last_subreq[mshr_i] = (mshr_d[mshr_i].sub_reqs_num == 1);
                mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].valid = 1'b0;
                if (mshr_d[mshr_i].sub_reqs_num != 0) begin
                  mshr_d[mshr_i].sub_reqs_num = mshr_d[mshr_i].sub_reqs_num - 1;
                end

                if (drain_last_subreq[mshr_i]) begin
                  if (EnableRespCache) begin
                    mshr_d[mshr_i].state = MSHR_CACHED;
                  end else begin
                    mshr_d_valid[mshr_i] = 1'b0;
                    mshr_d[mshr_i] = '0;
                  end
                end
              end
              port_taken[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = 1'b1;
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
        $display("[%0t] %m MSHR cfg: MshrNum=%0d MshrMergeWords=%0d MshrMergeReqs=%0d DrainMultiPort=%0d EnableRespCache=%0d EnableStats=%0d StatsPeriod=%0d",
                 $time, MshrNum, MshrMergeWords, MshrMergeReqs, DrainMultiPort, EnableRespCache,
                 EnableStats, StatsPeriod);
        $display("[%0t] %m MSHR cfg: SpillReqIn=%0d SpillReqOut=%0d SpillRespIn=%0d SpillRespOut=%0d",
                 $time, SpillReqIn, SpillReqOut, SpillRespIn, SpillRespOut);
      end

      task automatic print_stats(input string tag,
                                 input logic [63-1:0] cycles,
                                 input logic [63-1:0] mshr_valid_acc,
                                 input logic [63-1:0] subreq_valid_acc,
                                 input logic [63-1:0] mshr_max_valid,
                                 input logic [63-1:0] subreq_max_valid,
                                 input logic [63-1:0] req_accept,
                                 input logic [63-1:0] req_merge,
                                 input logic [63-1:0] req_alloc,
                                 input logic [63-1:0] req_bypass,
                                 input logic [63-1:0] req_mshr_overflow,
                                 input logic [63-1:0] req_subreq_overflow,
                                 input logic [63-1:0] resp_mshr,
                                 input logic [63-1:0] resp_bypass,
                                 input logic [63-1:0] cache_valid_acc,
                                 input logic [63-1:0] cache_max_valid,
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
          if (mshr_valid_acc != 0) begin
            avg_subreq_per_mshr = $itor(subreq_valid_acc) / $itor(mshr_valid_acc);
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
          if (mshr_max_valid >= cache_max_valid) begin
            mshr_max_valid_uncached = $itor(mshr_max_valid - cache_max_valid);
          end else begin
            mshr_max_valid_uncached = 0.0;
          end
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
        $display("  reqs: accepted=%0d merged=%0d alloc=%0d bypass=%0d mshr_overflow=%0d subreq_overflow=%0d",
                 req_accept, req_merge, req_alloc, req_bypass,
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
        stat_subreq_valid_cycle = '0;
        for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
          if (mshr_q_valid[mshr_i]) begin
            stat_mshr_valid_cycle = stat_mshr_valid_cycle + 1'b1;
            stat_subreq_valid_cycle =
                stat_subreq_valid_cycle + mshr_q[mshr_i].sub_reqs_num;
            if (mshr_q[mshr_i].state == MSHR_CACHED) begin
              stat_cache_valid_cycle = stat_cache_valid_cycle + 1'b1;
            end
          end
        end

        stat_req_accept_cycle = '0;
        stat_req_merge_cycle = '0;
        stat_req_alloc_cycle = '0;
        stat_req_bypass_cycle = '0;
        stat_req_mshr_overflow_cycle = '0;
        stat_req_subreq_overflow_cycle = '0;
        for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
          for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
            stat_req_subreq_full_match[tile_i][port_i] = 1'b0;
            if (req_in_valid[tile_i][port_i] && req_is_load[tile_i][port_i]) begin
              for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
                if (!stat_req_subreq_full_match[tile_i][port_i] &&
                    mshr_q_valid[mshr_i] &&
                    (mshr_q[mshr_i].state == MSHR_WAIT_RESP) &&
                    !mshr_resp_inflight[mshr_i] &&
                    (mshr_q[mshr_i].base_addr == req_addr_key[tile_i][port_i]) &&
                    (mshr_q[mshr_i].tgt_group_id == req_in[tile_i][port_i].tgt_group_id) &&
                    (mshr_q[mshr_i].sub_reqs_num >= MshrMergeReqs)) begin
                  stat_req_subreq_full_match[tile_i][port_i] = 1'b1;
                end
              end
            end

            if (req_in_valid[tile_i][port_i] && req_in_ready[tile_i][port_i]) begin
              stat_req_accept_cycle = stat_req_accept_cycle + 1'b1;
              if (req_merge_valid[tile_i][port_i]) begin
                stat_req_merge_cycle = stat_req_merge_cycle + 1'b1;
              end else begin
                stat_req_bypass_cycle = stat_req_bypass_cycle + 1'b1;
                if (req_is_load[tile_i][port_i]) begin
                  if (req_alloc_found[tile_i][port_i]) begin
                    stat_req_alloc_cycle = stat_req_alloc_cycle + 1'b1;
                  end else begin
                    stat_req_mshr_overflow_cycle = stat_req_mshr_overflow_cycle + 1'b1;
                  end
                end
              end
              if (req_is_load[tile_i][port_i] &&
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
                  req_merge_valid[tile_i][port_i] &&
                  (mshr_q[req_merge_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                stat_cache_hit_cycle = stat_cache_hit_cycle + 1'b1;
              end
              if (req_in_valid[tile_i][port_i] &&
                  req_in_ready[tile_i][port_i] &&
                  req_is_load[tile_i][port_i] &&
                  !req_merge_valid[tile_i][port_i] &&
                  req_alloc_found[tile_i][port_i] &&
                  (mshr_q[req_alloc_found_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                stat_cache_evict_cycle = stat_cache_evict_cycle + 1'b1;
              end
              if (req_in_valid[tile_i][port_i] &&
                  req_in_ready[tile_i][port_i] &&
                  req_is_store[tile_i][port_i]) begin
                for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
                  if (mshr_q_valid[mshr_i] &&
                      (mshr_q[mshr_i].state == MSHR_CACHED) &&
                      req_addr_hit_map[tile_i][port_i][mshr_i]) begin
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
        logic [63-1:0] cycle_next;
        logic [63-1:0] mshr_valid_acc_next;
        logic [63-1:0] cache_valid_acc_next;
        logic [63-1:0] subreq_valid_acc_next;
        logic [63-1:0] mshr_max_valid_next;
        logic [63-1:0] cache_max_valid_next;
        logic [63-1:0] subreq_max_valid_next;
        logic [63-1:0] req_accept_next;
        logic [63-1:0] req_merge_next;
        logic [63-1:0] req_alloc_next;
        logic [63-1:0] req_bypass_next;
        logic [63-1:0] req_mshr_overflow_next;
        logic [63-1:0] req_subreq_overflow_next;
        logic [63-1:0] resp_mshr_next;
        logic [63-1:0] resp_bypass_next;
        logic [63-1:0] cache_hit_next;
        logic [63-1:0] cache_fill_next;
        logic [63-1:0] cache_evict_next;
        logic [63-1:0] cache_store_update_next;
        logic [63-1:0] cache_amo_inval_next;
        logic            print_period;
        logic            print_fall;
        if (!rst_ni) begin
          stat_cycle_count <= 0;
          stat_mshr_valid_acc <= 0;
          stat_cache_valid_acc <= 0;
          stat_subreq_valid_acc <= 0;
          stat_mshr_max_valid <= 0;
          stat_cache_max_valid <= 0;
          stat_subreq_max_valid <= 0;
          stat_req_accept <= 0;
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

          cycle_next = stat_cycle_count;
          mshr_valid_acc_next = stat_mshr_valid_acc;
          cache_valid_acc_next = stat_cache_valid_acc;
          subreq_valid_acc_next = stat_subreq_valid_acc;
          mshr_max_valid_next = stat_mshr_max_valid;
          cache_max_valid_next = stat_cache_max_valid;
          subreq_max_valid_next = stat_subreq_max_valid;
          req_accept_next = stat_req_accept;
          req_merge_next = stat_req_merge;
          req_alloc_next = stat_req_alloc;
          req_bypass_next = stat_req_bypass;
          req_mshr_overflow_next = stat_req_mshr_overflow;
          req_subreq_overflow_next = stat_req_subreq_overflow;
          resp_mshr_next = stat_resp_mshr;
          resp_bypass_next = stat_resp_bypass;
          cache_hit_next = stat_cache_hit;
          cache_fill_next = stat_cache_fill;
          cache_evict_next = stat_cache_evict;
          cache_store_update_next = stat_cache_store_update;
          cache_amo_inval_next = stat_cache_amo_inval;

          if (csr_trace_any_i) begin
            cycle_next = stat_cycle_count + 1;
            mshr_valid_acc_next = stat_mshr_valid_acc + stat_mshr_valid_cycle;
            cache_valid_acc_next = stat_cache_valid_acc + stat_cache_valid_cycle;
            subreq_valid_acc_next = stat_subreq_valid_acc + stat_subreq_valid_cycle;
            if (stat_mshr_valid_cycle > mshr_max_valid_next) begin
              mshr_max_valid_next = stat_mshr_valid_cycle;
            end
            if (stat_cache_valid_cycle > cache_max_valid_next) begin
              cache_max_valid_next = stat_cache_valid_cycle;
            end
            if (stat_subreq_valid_cycle > subreq_max_valid_next) begin
              subreq_max_valid_next = stat_subreq_valid_cycle;
            end
            req_accept_next = stat_req_accept + stat_req_accept_cycle;
            req_merge_next = stat_req_merge + stat_req_merge_cycle;
            req_alloc_next = stat_req_alloc + stat_req_alloc_cycle;
            req_bypass_next = stat_req_bypass + stat_req_bypass_cycle;
            req_mshr_overflow_next = stat_req_mshr_overflow + stat_req_mshr_overflow_cycle;
            req_subreq_overflow_next = stat_req_subreq_overflow + stat_req_subreq_overflow_cycle;
            resp_mshr_next = stat_resp_mshr + stat_resp_mshr_cycle;
            resp_bypass_next = stat_resp_bypass + stat_resp_bypass_cycle;
            cache_hit_next = stat_cache_hit + stat_cache_hit_cycle;
            cache_fill_next = stat_cache_fill + stat_cache_fill_cycle;
            cache_evict_next = stat_cache_evict + stat_cache_evict_cycle;
            cache_store_update_next = stat_cache_store_update + stat_cache_store_update_cycle;
            cache_amo_inval_next = stat_cache_amo_inval + stat_cache_amo_inval_cycle;
          end

          print_period = (StatsPeriod != 0) && csr_trace_any_i && (cycle_next >= StatsPeriod);
          print_fall = stat_trace_q && !csr_trace_any_i;
          if ((print_period || print_fall) && (cycle_next != 0)) begin
            print_stats(print_period ? "period" : "trace_off",
                        cycle_next,
                        mshr_valid_acc_next,
                        subreq_valid_acc_next,
                        mshr_max_valid_next,
                        subreq_max_valid_next,
                        req_accept_next,
                        req_merge_next,
                        req_alloc_next,
                        req_bypass_next,
                        req_mshr_overflow_next,
                        req_subreq_overflow_next,
                        resp_mshr_next,
                        resp_bypass_next,
                        cache_valid_acc_next,
                        cache_max_valid_next,
                        cache_hit_next,
                        cache_fill_next,
                        cache_evict_next,
                        cache_store_update_next,
                        cache_amo_inval_next);
            stat_cycle_count <= 0;
            stat_mshr_valid_acc <= 0;
            stat_cache_valid_acc <= 0;
            stat_subreq_valid_acc <= 0;
            stat_mshr_max_valid <= 0;
            stat_cache_max_valid <= 0;
            stat_subreq_max_valid <= 0;
            stat_req_accept <= 0;
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
            stat_cycle_count <= cycle_next;
            stat_mshr_valid_acc <= mshr_valid_acc_next;
            stat_cache_valid_acc <= cache_valid_acc_next;
            stat_subreq_valid_acc <= subreq_valid_acc_next;
            stat_mshr_max_valid <= mshr_max_valid_next;
            stat_cache_max_valid <= cache_max_valid_next;
            stat_subreq_max_valid <= subreq_max_valid_next;
            stat_req_accept <= req_accept_next;
            stat_req_merge <= req_merge_next;
            stat_req_alloc <= req_alloc_next;
            stat_req_bypass <= req_bypass_next;
            stat_req_mshr_overflow <= req_mshr_overflow_next;
            stat_req_subreq_overflow <= req_subreq_overflow_next;
            stat_resp_mshr <= resp_mshr_next;
            stat_resp_bypass <= resp_bypass_next;
            stat_cache_hit <= cache_hit_next;
            stat_cache_fill <= cache_fill_next;
            stat_cache_evict <= cache_evict_next;
            stat_cache_store_update <= cache_store_update_next;
            stat_cache_amo_inval <= cache_amo_inval_next;
          end
        end
      end

      final begin
        if (stat_cycle_count != 0) begin
          print_stats("final",
                      stat_cycle_count,
                      stat_mshr_valid_acc,
                      stat_subreq_valid_acc,
                      stat_mshr_max_valid,
                      stat_subreq_max_valid,
                      stat_req_accept,
                      stat_req_merge,
                      stat_req_alloc,
                      stat_req_bypass,
                      stat_req_mshr_overflow,
                      stat_req_subreq_overflow,
                      stat_resp_mshr,
                      stat_resp_bypass,
                      stat_cache_valid_acc,
                      stat_cache_max_valid,
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

endmodule : mempool_group_mshr
