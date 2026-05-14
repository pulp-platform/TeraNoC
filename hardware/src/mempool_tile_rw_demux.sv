// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "mempool/mempool.svh"

module mempool_tile_rw_demux
  import mempool_pkg::*;
  import cf_math_pkg::idx_width;
#(
  parameter int unsigned NumCoresPerTile              = 4,
  parameter int unsigned NumRemoteReqPortsPerTile     = 4,
  parameter int unsigned NumRdRemoteReqPortsPerTile   = 2,
  parameter int unsigned NumWrRemoteReqPortsPerTile   = 2,
  parameter int unsigned NumWideRemoteReqPortsPerTile = 0,
  parameter int unsigned NumRdWrRemoteReqPortsPerTile = 0,
  parameter int unsigned NumBanksPerTile              = 16,
  parameter int unsigned NumTilesPerGroup             = 4,
  parameter int unsigned NumGroups                    = 4,
  parameter int unsigned ByteOffset                   = 2
) (
  input  logic                                                               clk_i,
  input  logic                                                               rst_ni,
  input  group_id_t                                                           group_id_i,
  input  logic                [NumCoresPerTile-1:0]                           remote_req_interco_valid_i,
  input  logic                [NumCoresPerTile-1:0]                           remote_req_interco_ready_i,
  input  logic                [NumCoresPerTile-1:0]                           remote_req_interco_wen_i,
  input  logic                [NumCoresPerTile-1:0]                           remote_req_interco_amoen_i,
  input  addr_t               [NumCoresPerTile-1:0]                           prescramble_tcdm_req_tgt_addr_i,
  output logic                [NumCoresPerTile-1:0]                           remote_req_interco_to_xbar_valid_o,
  output logic                [NumCoresPerTile-1:0]                           remote_req_interco_to_xbar_ready_o,
  output logic [NumCoresPerTile-1:0][idx_width(NumRemoteReqPortsPerTile)-1:0] remote_req_interco_tgt_sel_o
);

`include "common_cells/registers.svh"

  /*******************
   *   Core De/mux   *
   *******************/
  group_id_t           [NumCoresPerTile-1:0]                    tgt_group_id;
  logic                [NumCoresPerTile-1:0]                    group_id_is_local;

  // Round-robin counter for request port spreading (visible in waveform).
  localparam int unsigned NumRemotePorts = (NumRemoteReqPortsPerTile > 1) ? (NumRemoteReqPortsPerTile - 1) : 1;
  localparam int unsigned RRWidth = (NumRemotePorts > 1) ? $clog2(NumRemotePorts) : 1;
  logic [RRWidth-1:0] req_rr_q, req_rr_d;
  `FF(req_rr_q, req_rr_d, '0)

  // Advance round-robin on any remote request handshake
  always_comb begin
    req_rr_d = req_rr_q;
    for (int c = 0; c < NumCoresPerTile; c++) begin
      if (remote_req_interco_valid_i[c] && remote_req_interco_ready_i[c] &&
          !group_id_is_local[c]) begin
        if (req_rr_d == RRWidth'(NumRemotePorts - 1))
          req_rr_d = '0;
        else
          req_rr_d = req_rr_d + RRWidth'(1);
      end
    end
  end

  for (genvar c = 0; c < NumCoresPerTile; c++) begin: gen_core_mux
    assign tgt_group_id[c] = prescramble_tcdm_req_tgt_addr_i[c][ByteOffset + $clog2(NumBanksPerTile) + $clog2(NumTilesPerGroup) +: $clog2(NumGroups)];
    assign group_id_is_local[c] = tgt_group_id[c] == group_id_i;

    // Map the requests from cores to the
    // channels with different usage:
    //                                 port id
    // ------     ------   -> local    [ 0 (lsb for local port)
    // |    | ->  |    |   -> r     Low  1
    // |Tile| ->  |xbar|   -> r     ||   2
    // |    | ->  |    |   -> rw    ||   3
    // |    | ->  |    |   -> w     \/   4
    // ------     ------   -> w    High   5 ]

    if ((NumRdRemoteReqPortsPerTile > 0) || (NumWrRemoteReqPortsPerTile > 0)) begin
      assign remote_req_interco_tgt_sel_o[c] = group_id_is_local[c] ? 0 :
                                              ~(remote_req_interco_wen_i[c] | remote_req_interco_amoen_i[c]) ?
                                               (1 + (c % (NumRdRemoteReqPortsPerTile + NumRdWrRemoteReqPortsPerTile))) :
                                               (1 + NumRdRemoteReqPortsPerTile + (c % (NumWideRemoteReqPortsPerTile)));

    end else if (NocPortHash[0] && (NumRemoteReqPortsPerTile > 2)) begin
      // Round-robin port spreading: each remote request uses the current
      // round-robin pointer, which advances on every handshake.
      assign remote_req_interco_tgt_sel_o[c] = group_id_is_local[c] ? 0 : (1 + req_rr_q);

    end else begin
      assign remote_req_interco_tgt_sel_o[c] = group_id_is_local[c] ? 0 : (1 + (c % (NumRemoteReqPortsPerTile - 1)));
    end
  end

  assign remote_req_interco_to_xbar_valid_o   = remote_req_interco_valid_i;
  assign remote_req_interco_to_xbar_ready_o   = remote_req_interco_ready_i;
endmodule
