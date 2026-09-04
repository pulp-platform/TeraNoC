// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "mempool/mempool.svh"

/// Per-lane request decode for the group MSHR: classify each incoming remote request and derive
/// the address key the merge lookup compares on. Purely combinational and stateless -- it reads
/// no MSHR entry, which is what lets it live outside the main process.
///
/// A MISALIGNED burst is clamped to len = 1 (so is_single is set), but the requesting VLSU still
/// expects len_raw beats from the NoC. It must NOT be admitted on the single-merge arm, which is
/// why can_merge tests len_raw == 1 rather than is_single.
module mempool_group_mshr_req_decode
  import mempool_pkg::*;
#(
  parameter int unsigned NumTilesPerGroup         = 16,
  parameter int unsigned NumRemoteReqPortsPerTile = 3,
  parameter int unsigned BurstLenWidth            = 5,
  parameter int unsigned TileIdBits               = 4,
  parameter int unsigned BurstAlignBits           = 4,
  /// Low address bits masked out of a single-word merge key (0 = exact address).
  parameter int unsigned MergeWordOffset          = 0,
  parameter int unsigned MshrFullBurstWords       = 16,
  parameter bit          EnableMshrSingleReq       = 1'b1,
  parameter bit          EnableMshrNonFullBurstReq = 1'b1,
  parameter bit          EnableMshrFullBurstReq    = 1'b1
) (
  input  logic             [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_valid_i,
  input  tcdm_master_req_t [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_i,
  /// Runtime bypass classes (CSR-backed in the parent).
  input  logic                                                                  cfg_bypass_single_i,
  input  logic                                                                  cfg_bypass_burst_i,

  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][BurstLenWidth-1:0] len_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][BurstLenWidth-1:0] len_raw_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1][TileIdBits-1:0]    tile_id_o,
  output tcdm_addr_t [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              tile_addr_o,
  output tcdm_addr_t [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              tile_addr_key_o,
  output tcdm_addr_t [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              addr_key_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_load_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_store_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_single_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_non_full_burst_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_full_burst_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    can_merge_o,
  /// Any lane presented an AMO this cycle. The parent uses it to invalidate matching entries.
  output logic                                                                         amo_invalidate_o
);

  function automatic tcdm_addr_t merge_addr_key(input tcdm_addr_t addr);
    if (MergeWordOffset == 0) begin
      merge_addr_key = addr;
    end else begin
      merge_addr_key = {addr[$bits(tcdm_addr_t)-1:MergeWordOffset], {MergeWordOffset{1'b0}}};
    end
  endfunction

  always_comb begin
    amo_invalidate_o = 1'b0;
    for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
      for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
        len_o[tile_i][port_i]               = BurstLenWidth'(1);
        len_raw_o[tile_i][port_i]           = BurstLenWidth'(1);
        tile_id_o[tile_i][port_i]           = '0;
        tile_addr_o[tile_i][port_i]         = '0;
        tile_addr_key_o[tile_i][port_i]     = '0;
        is_load_o[tile_i][port_i]           = req_valid_i[tile_i][port_i] &&
                                              ~req_i[tile_i][port_i].wen &&
                                              (req_i[tile_i][port_i].wdata.amo == '0);
        is_store_o[tile_i][port_i]          = req_valid_i[tile_i][port_i] &&
                                              req_i[tile_i][port_i].wen &&
                                              (req_i[tile_i][port_i].wdata.amo == '0);
        is_single_o[tile_i][port_i]         = 1'b0;
        is_non_full_burst_o[tile_i][port_i] = 1'b0;
        is_full_burst_o[tile_i][port_i]     = 1'b0;
        can_merge_o[tile_i][port_i]         = 1'b0;

        if (req_valid_i[tile_i][port_i] && (req_i[tile_i][port_i].wdata.amo != '0)) begin
          amo_invalidate_o = 1'b1;
        end

        if (req_valid_i[tile_i][port_i]) begin
          tile_id_o[tile_i][port_i]   = req_i[tile_i][port_i].tgt_addr[TileIdBits-1:0];
          tile_addr_o[tile_i][port_i] =
              req_i[tile_i][port_i].tgt_addr[$bits(tcdm_addr_t)-1:TileIdBits];
          len_raw_o[tile_i][port_i]   = (req_i[tile_i][port_i].burst_len == '0)
                                            ? BurstLenWidth'(1)
                                            : req_i[tile_i][port_i].burst_len;
          // Stores and misaligned bursts are clamped to a single word.
          if (!is_load_o[tile_i][port_i] ||
              ((len_raw_o[tile_i][port_i] > 1) &&
               (tile_addr_o[tile_i][port_i][BurstAlignBits-1:0] != '0))) begin
            len_o[tile_i][port_i] = BurstLenWidth'(1);
          end else begin
            len_o[tile_i][port_i] = len_raw_o[tile_i][port_i];
          end

          if (len_o[tile_i][port_i] > 1) begin
            tile_addr_key_o[tile_i][port_i] =
                {tile_addr_o[tile_i][port_i][$bits(tcdm_addr_t)-TileIdBits-1:BurstAlignBits],
                 {BurstAlignBits{1'b0}}};
            addr_key_o[tile_i][port_i] =
                {tile_addr_key_o[tile_i][port_i], tile_id_o[tile_i][port_i]};
          end else begin
            addr_key_o[tile_i][port_i] = merge_addr_key(req_i[tile_i][port_i].tgt_addr);
          end

          is_single_o[tile_i][port_i]     = (len_o[tile_i][port_i] == BurstLenWidth'(1));
          is_full_burst_o[tile_i][port_i] =
              (len_o[tile_i][port_i] == BurstLenWidth'(MshrFullBurstWords));
          is_non_full_burst_o[tile_i][port_i] =
              !is_single_o[tile_i][port_i] && !is_full_burst_o[tile_i][port_i];

          can_merge_o[tile_i][port_i] =
              is_load_o[tile_i][port_i] &&
              !(is_single_o[tile_i][port_i] ? cfg_bypass_single_i : cfg_bypass_burst_i) &&
              ((EnableMshrSingleReq       && is_single_o[tile_i][port_i] &&
                (len_raw_o[tile_i][port_i] == BurstLenWidth'(1))) ||
               (EnableMshrNonFullBurstReq && is_non_full_burst_o[tile_i][port_i]) ||
               (EnableMshrFullBurstReq    && is_full_burst_o[tile_i][port_i]));
        end else begin
          addr_key_o[tile_i][port_i] = '0;
        end
      end
    end
  end

endmodule
