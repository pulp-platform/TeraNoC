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

  parameter int MshrNum        = 16,
  parameter int MshrMergeWords = 1,
  parameter int MshrMergeReqs  = 16
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
    MSHR_DRAIN_RESP = 2'b10
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
    tile_group_id_t owner_tile;
    logic [RespPortIdW-1:0] owner_port;
    tile_core_id_t owner_core;
    meta_id_t owner_meta;
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

  // MSHR state (registered and next-state).
  mempool_group_mshr_t [MshrNum-1:0]                                           mshr_d;
  mempool_group_mshr_t [MshrNum-1:0]                                           mshr_q;
  logic                [MshrNum-1:0]                                           mshr_d_valid;
  logic                [MshrNum-1:0]                                           mshr_q_valid;
  logic                [MshrNum-1:0]                                           mshr_resp_inflight; // Block same-cycle merge.

  // Response classification and debug (per response port).
  logic    [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_is_mshr;
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_mshr_id;
  logic    [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_from_mshr;
  logic    [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_from_bypass;
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               resp_mshr_id_dbg;
  logic    [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]               port_taken;

  // Request decode and merge lookup (per request port).
  logic      [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_is_load;
  tcdm_addr_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              req_addr_key;
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

  // Request allocation (banked allocator bookkeeping).
  logic    [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found;
  mshr_id_t[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                req_alloc_found_mshr_id;
  logic    [MshrNum-1:0]                                                       mshr_alloc_found;
  req_id_t [MshrNum-1:0]                                                       mshr_alloc_found_req_id;

  // Response drain scheduling (per MSHR entry).
  logic         [MshrNum-1:0]                                                  drain_subreq_found;
  logic         [idx_width(MshrMergeReqs)-1:0]                                 drain_subreq_idx [MshrNum-1:0];
  tile_group_id_t[MshrNum-1:0]                                                 drain_dst_tile;
  logic         [RespPortIdW-1:0]                                              drain_dst_port [MshrNum-1:0];
  logic         [MshrNum-1:0]                                                  drain_last_subreq;

  function automatic tcdm_addr_t merge_addr_key(input tcdm_addr_t addr);
    if (MergeWordOffset == 0) begin
      merge_addr_key = addr;
    end else begin
      merge_addr_key = {addr[$bits(tcdm_addr_t)-1:MergeWordOffset], {MergeWordOffset{1'b0}}};
    end
  endfunction

  assign scan_data_o = scan_data_i;

  // Decode request type and address key for merge lookup.
  always_comb begin
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        req_is_load[tile_i][port_i] = group_mshr_req_valid_i[tile_i][port_i] &&
                                      ~group_mshr_req_i[tile_i][port_i].wen &&
                                      (group_mshr_req_i[tile_i][port_i].wdata.amo == '0);
        if (group_mshr_req_valid_i[tile_i][port_i]) begin
          req_addr_key[tile_i][port_i] =
              merge_addr_key(group_mshr_req_i[tile_i][port_i].tgt_addr);
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
                  (group_mshr_req_i[tile_i][port_i].tgt_group_id ==
                   group_mshr_req_i[oth_tile_i][oth_port_i].tgt_group_id);
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
          assign req_hit_mshr_map[tile_i][port_i][mshr_i] =
              req_is_load[tile_i][port_i] &&
              mshr_q_valid[mshr_i] &&
              (mshr_q[mshr_i].state == MSHR_WAIT_RESP) &&
              !mshr_resp_inflight[mshr_i] &&
              (mshr_q[mshr_i].base_addr == req_addr_key[tile_i][port_i]) &&
              (mshr_q[mshr_i].tgt_group_id == group_mshr_req_i[tile_i][port_i].tgt_group_id) &&
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
          if (!mshr_q_valid[mshr_i] &&
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
            if (!mshr_q_valid[mshr_i] &&
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
            mshr_noc_req_ready_i[req_leader_tile[tile_i][port_i]][req_leader_port[tile_i][port_i]];
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
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mshr_q_valid <= '0;
      mshr_q       <= '0;
    end else begin
      mshr_q_valid <= mshr_d_valid;
      mshr_q       <= mshr_d;
    end
  end

  // Main combinational control: request merge/alloc, response capture, and drain
  always_comb begin
    // Defaults
    mshr_d = mshr_q;
    mshr_d_valid = mshr_q_valid;

    mshr_noc_req_o = group_mshr_req_i;
    mshr_noc_req_valid_o = '0;
    group_mshr_req_ready_o = '1;

    group_mshr_resp_o = '0;
    group_mshr_resp_valid_o = '0;
    resp_from_mshr = '0;
    resp_from_bypass = '0;
    resp_mshr_id_dbg = '0;
    mshr_noc_resp_ready_o = '1;
    mshr_resp_inflight = '0;

    // ------------------------------------------------------------
    // Request path: merge loads, allocate MSHR, or bypass to NoC
    // ------------------------------------------------------------
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        if (group_mshr_req_valid_i[tile_i][port_i]) begin
          if (req_merge_valid[tile_i][port_i]) begin
            // Merge hit: accept without touching NoC.
            group_mshr_req_ready_o[tile_i][port_i] = req_merge_ready[tile_i][port_i];
            if (group_mshr_req_ready_o[tile_i][port_i]) begin
              if (mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num < MshrMergeReqs) begin
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].valid = 1'b1;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].tile_id = tile_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].port_id = port_i;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].core_id =
                    group_mshr_req_i[tile_i][port_i].wdata.core_id;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].meta_id =
                    group_mshr_req_i[tile_i][port_i].wdata.meta_id;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs[
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num].amo =
                    group_mshr_req_i[tile_i][port_i].wdata.amo;
                mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num =
                    mshr_d[req_merge_mshr_id[tile_i][port_i]].sub_reqs_num + 1;
              end
            end
          end else begin
            // Need to send to NoC (store, miss, or merge list full).
            group_mshr_req_ready_o[tile_i][port_i] = mshr_noc_req_ready_i[tile_i][port_i];
            if (req_is_load[tile_i][port_i]) begin
              // Allocate a new MSHR entry for load miss if space exists.
              if (req_alloc_found[tile_i][port_i] && group_mshr_req_ready_o[tile_i][port_i]) begin
                mshr_d_valid[req_alloc_found_mshr_id[tile_i][port_i]] = 1'b1;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]] = '0;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].base_addr =
                    req_addr_key[tile_i][port_i];
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].tgt_group_id =
                    group_mshr_req_i[tile_i][port_i].tgt_group_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].owner_tile = tile_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].owner_port = port_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].owner_core =
                    group_mshr_req_i[tile_i][port_i].wdata.core_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].owner_meta =
                    group_mshr_req_i[tile_i][port_i].wdata.meta_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].state      = MSHR_WAIT_RESP;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].resp_valid = 1'b0;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].valid   = 1'b1;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].tile_id = tile_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].port_id = port_i;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].core_id =
                    group_mshr_req_i[tile_i][port_i].wdata.core_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].meta_id =
                    group_mshr_req_i[tile_i][port_i].wdata.meta_id;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs[0].amo =
                    group_mshr_req_i[tile_i][port_i].wdata.amo;
                mshr_d[req_alloc_found_mshr_id[tile_i][port_i]].sub_reqs_num = 1;
              end
            end
            // Forward the request to NoC (alloc or bypass).
            mshr_noc_req_valid_o[tile_i][port_i] = 1'b1;
          end
        end else begin
          group_mshr_req_ready_o[tile_i][port_i] = 1'b1;
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
        if (mshr_noc_resp_valid_i[tile_i][port_i] &&
            (mshr_noc_resp_i[tile_i][port_i].wen == 1'b0) &&
            (mshr_noc_resp_i[tile_i][port_i].rdata.amo == '0)) begin
          for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
            if (mshr_q_valid[mshr_i] &&
                mshr_q[mshr_i].state == MSHR_WAIT_RESP &&
                mshr_q[mshr_i].owner_tile == tile_i &&
                mshr_q[mshr_i].owner_core == mshr_noc_resp_i[tile_i][port_i].rdata.core_id &&
                mshr_q[mshr_i].owner_meta == mshr_noc_resp_i[tile_i][port_i].rdata.meta_id) begin
              resp_is_mshr[tile_i][port_i] = 1'b1;
              resp_mshr_id[tile_i][port_i] = mshr_id_t'(mshr_i);
              break;
            end
          end
        end

        if (resp_is_mshr[tile_i][port_i]) begin
          mshr_resp_inflight[resp_mshr_id[tile_i][port_i]] = 1'b1;
          mshr_noc_resp_ready_o[tile_i][port_i] = ~mshr_q[resp_mshr_id[tile_i][port_i]].resp_valid;
        end else begin
          mshr_noc_resp_ready_o[tile_i][port_i] = group_mshr_resp_ready_i[tile_i][port_i];
        end

        if (mshr_noc_resp_valid_i[tile_i][port_i] && !resp_is_mshr[tile_i][port_i]) begin
          group_mshr_resp_valid_o[tile_i][port_i] = 1'b1;
          group_mshr_resp_o[tile_i][port_i] = mshr_noc_resp_i[tile_i][port_i];
          resp_from_bypass[tile_i][port_i] = 1'b1;
        end
      end
    end

    // Capture MSHR responses
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        if (mshr_noc_resp_valid_i[tile_i][port_i] &&
            resp_is_mshr[tile_i][port_i] &&
            mshr_noc_resp_ready_o[tile_i][port_i]) begin
          mshr_d[resp_mshr_id[tile_i][port_i]].resp_buf   = mshr_noc_resp_i[tile_i][port_i];
          mshr_d[resp_mshr_id[tile_i][port_i]].resp_valid = 1'b1;
          mshr_d[resp_mshr_id[tile_i][port_i]].state      = MSHR_DRAIN_RESP;
        end
      end
    end

    // ------------------------------------------------------------
    // Drain captured responses to all recorded sub-requests
    // ------------------------------------------------------------
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
        port_taken[tile_i][port_i] = mshr_noc_resp_valid_i[tile_i][port_i];
      end
    end

    for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
      drain_subreq_found[mshr_i] = 1'b0;
      drain_subreq_idx[mshr_i] = '0;
      drain_dst_tile[mshr_i] = '0;
      drain_dst_port[mshr_i] = '0;
      drain_last_subreq[mshr_i] = 1'b0;
      if (mshr_d_valid[mshr_i] && mshr_d[mshr_i].resp_valid && mshr_d[mshr_i].state == MSHR_DRAIN_RESP) begin
        for (int s = 0; s < MshrMergeReqs; s++) begin
          if (mshr_d[mshr_i].sub_reqs[s].valid) begin
            drain_subreq_found[mshr_i] = 1'b1;
            drain_subreq_idx[mshr_i] = s[idx_width(MshrMergeReqs)-1:0];
            break;
          end
        end

        if (drain_subreq_found[mshr_i]) begin
          drain_dst_tile[mshr_i] = mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].tile_id;
          drain_dst_port[mshr_i] = mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].port_id;

          if (!port_taken[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]]) begin
            group_mshr_resp_valid_o[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = 1'b1;
            group_mshr_resp_o[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].wen =
                mshr_d[mshr_i].resp_buf.wen;
            group_mshr_resp_o[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.data =
                mshr_d[mshr_i].resp_buf.rdata.data;
            group_mshr_resp_o[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.core_id =
                mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].core_id;
            group_mshr_resp_o[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.meta_id =
                mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].meta_id;
            group_mshr_resp_o[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]].rdata.amo =
                mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].amo;
            resp_from_mshr[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = 1'b1;
            resp_mshr_id_dbg[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = mshr_id_t'(mshr_i);

            if (group_mshr_resp_ready_i[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]]) begin
              drain_last_subreq[mshr_i] = (mshr_d[mshr_i].sub_reqs_num == 1);
              mshr_d[mshr_i].sub_reqs[drain_subreq_idx[mshr_i]].valid = 1'b0;
              if (mshr_d[mshr_i].sub_reqs_num != 0) begin
                mshr_d[mshr_i].sub_reqs_num = mshr_d[mshr_i].sub_reqs_num - 1;
              end

              // If all sub-requests are drained, free the entry.
              if (drain_last_subreq[mshr_i]) begin
                mshr_d_valid[mshr_i] = 1'b0;
                mshr_d[mshr_i] = '0;
              end
            end
            port_taken[drain_dst_tile[mshr_i]][drain_dst_port[mshr_i]] = 1'b1;
          end
        end
      end
    end
  end

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
