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
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_can_merge_single;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_can_merge_burst;
  /// burst_len >= 2 and the burst-alignment test, read straight off the request. len_o is derived
  /// from these, so taking them directly keeps is_single two levels from burst_len instead of six
  /// through len_raw -> misaligned -> len_o -> compare.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_len_ge2;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_addr_unaligned;

  // is_full_burst_o is derived from burst_len directly, which is only disjoint from the single
  // class while a full burst is at least two words.
  initial begin
    if (MshrFullBurstWords < 2)
      $error("[mempool_group_mshr_req_decode] MshrFullBurstWords (%0d) must be >= 2.",
             MshrFullBurstWords);
  end

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
        // len_raw_o is 1 exactly when the request is invalid or burst_len is 0, so len_raw_o > 1
        // is valid && burst_len >= 2 -- no zero-compare and no mux in front of it.
        assign req_len_ge2[t][p]        = |req_i[t][p].burst_len[BurstLenWidth-1:1];
        assign req_addr_unaligned[t][p] = (tile_addr_o[t][p][BurstAlignBits-1:0] != '0);
        assign req_burst_misaligned[t][p] = req_valid_i[t][p] && req_len_ge2[t][p] &&
                                            req_addr_unaligned[t][p];
        assign len_o[t][p] = (!req_valid_i[t][p] || !is_load_o[t][p] ||
                              req_burst_misaligned[t][p]) ? BurstLenWidth'(1) : len_raw_o[t][p];
        // len_o >= 1 by construction, so len_o > 1 is len_o != 1.
        assign req_len_is_burst[t][p] = req_valid_i[t][p] && !is_single_o[t][p];

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

        // len_o == 1 <=> !is_load || misaligned || len_raw == 1. Substituting misaligned and
        // absorbing (!len_ge2 | (len_ge2 & unaligned)) = (!len_ge2 | unaligned).
        assign is_single_o    [t][p] = req_valid_i[t][p] &&
                                       (!is_load_o[t][p] || !req_len_ge2[t][p] ||
                                        req_addr_unaligned[t][p]);
        // len_o == MshrFullBurstWords needs the un-clamped length, so is_load, alignment and a
        // direct burst_len compare are the whole test (is_load_o implies req_valid_i).
        assign is_full_burst_o[t][p] = is_load_o[t][p] && !req_addr_unaligned[t][p] &&
                                       (req_i[t][p].burst_len == BurstLenWidth'(MshrFullBurstWords));
        assign is_non_full_burst_o[t][p] = req_valid_i[t][p] && !is_single_o[t][p] &&
                                           !is_full_burst_o[t][p];

        // The class test and the bypass test both branch on is_single, so branch once. is_load_o
        // implies req_valid_i, and the three classes are disjoint and cover a valid request, so the
        // non-single arm is just which burst class is enabled. A misaligned burst has is_single set
        // but len_raw > 1, which the single arm still excludes.
        assign req_can_merge_single[t][p] = EnableMshrSingleReq && !cfg_bypass_single_i &&
                                            (len_raw_o[t][p] == BurstLenWidth'(1));
        assign req_can_merge_burst [t][p] = !cfg_bypass_burst_i &&
                                            (is_full_burst_o[t][p] ? EnableMshrFullBurstReq
                                                                   : EnableMshrNonFullBurstReq);
        assign can_merge_o[t][p] = is_load_o[t][p] &&
                                   (is_single_o[t][p] ? req_can_merge_single[t][p]
                                                      : req_can_merge_burst[t][p]);

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
