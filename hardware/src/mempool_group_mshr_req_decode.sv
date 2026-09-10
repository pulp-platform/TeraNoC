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
  // The two forms addr_key_o selects between, published unmuxed so the bank hash can start its
  // barrel select without waiting on req_len_is_burst.
  output tcdm_addr_t [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              addr_key_burst_o,
  output tcdm_addr_t [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]              addr_key_single_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_load_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_store_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_single_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_non_full_burst_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    is_full_burst_o,
  output logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]                    can_merge_o,
  /// Any lane presented an AMO this cycle. The parent uses it to invalidate matching entries.
  output logic                                                                         amo_invalidate_o
);

  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_is_amo;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_no_amo;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_burst_misaligned;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_len_is_burst;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_can_merge_class;

  genvar t, p;

  generate
    for (t = 0; t < NumTilesPerGroup; t++) begin : gen_req_decode_t
      for (p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_req_decode_p

        assign req_is_amo[t][p] = req_valid_i[t][p] && (req_i[t][p].wdata.amo != '0);
        assign req_no_amo[t][p] = req_valid_i[t][p] && (req_i[t][p].wdata.amo == '0);

        assign is_load_o [t][p] = req_no_amo[t][p] && ~req_i[t][p].wen;
        assign is_store_o[t][p] = req_no_amo[t][p] &&  req_i[t][p].wen;

        assign tile_id_o  [t][p] = req_valid_i[t][p] ? req_i[t][p].tgt_addr[TileIdBits-1:0] : '0;
        assign tile_addr_o[t][p] = req_valid_i[t][p]
                                 ? req_i[t][p].tgt_addr[$bits(tcdm_addr_t)-1:TileIdBits] : '0;

        assign len_raw_o[t][p] = (!req_valid_i[t][p] || (req_i[t][p].burst_len == '0))
                               ? BurstLenWidth'(1) : req_i[t][p].burst_len;

        // A burst whose tile address is not BurstAlignBits-aligned is clamped to a single word.
        assign req_burst_misaligned[t][p] = (len_raw_o[t][p] > 1) &&
                                            (tile_addr_o[t][p][BurstAlignBits-1:0] != '0);
        assign len_o[t][p] = (!req_valid_i[t][p] || !is_load_o[t][p] ||
                              req_burst_misaligned[t][p]) ? BurstLenWidth'(1) : len_raw_o[t][p];
        assign req_len_is_burst[t][p] = req_valid_i[t][p] && (len_o[t][p] > 1);

        assign tile_addr_key_o[t][p] = req_len_is_burst[t][p]
            ? {tile_addr_o[t][p][$bits(tcdm_addr_t)-TileIdBits-1:BurstAlignBits],
               {BurstAlignBits{1'b0}}}
            : '0;
        assign addr_key_burst_o[t][p] =
            {{tile_addr_o[t][p][$bits(tcdm_addr_t)-TileIdBits-1:BurstAlignBits],
              {BurstAlignBits{1'b0}}}, tile_id_o[t][p]};
        assign addr_key_single_o[t][p] = merge_addr_key(req_i[t][p].tgt_addr);
        assign addr_key_o[t][p] = !req_valid_i[t][p] ? '0
                                : req_len_is_burst[t][p]
                                    ? addr_key_burst_o[t][p]
                                    : addr_key_single_o[t][p];

        assign is_single_o    [t][p] = req_valid_i[t][p] &&
                                       (len_o[t][p] == BurstLenWidth'(1));
        assign is_full_burst_o[t][p] = req_valid_i[t][p] &&
                                       (len_o[t][p] == BurstLenWidth'(MshrFullBurstWords));
        assign is_non_full_burst_o[t][p] = req_valid_i[t][p] && !is_single_o[t][p] &&
                                           !is_full_burst_o[t][p];

        // A misaligned burst has is_single set but len_raw > 1; it must not take the single arm.
        assign req_can_merge_class[t][p] =
            (EnableMshrSingleReq       && is_single_o[t][p] &&
             (len_raw_o[t][p] == BurstLenWidth'(1)))                 ||
            (EnableMshrNonFullBurstReq && is_non_full_burst_o[t][p]) ||
            (EnableMshrFullBurstReq    && is_full_burst_o[t][p]);
        assign can_merge_o[t][p] = is_load_o[t][p] && req_can_merge_class[t][p] &&
                                   !(is_single_o[t][p] ? cfg_bypass_single_i : cfg_bypass_burst_i);

      end
    end
  endgenerate

  assign amo_invalidate_o = |req_is_amo;

  function automatic tcdm_addr_t merge_addr_key(input tcdm_addr_t addr);
    if (MergeWordOffset == 0) begin
      merge_addr_key = addr;
    end else begin
      merge_addr_key = {addr[$bits(tcdm_addr_t)-1:MergeWordOffset], {MergeWordOffset{1'b0}}};
    end
  endfunction

endmodule
