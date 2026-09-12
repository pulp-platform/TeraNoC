// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "mempool/mempool.svh"

/// Per-lane request decode for the group MSHR: classify each incoming remote request and derive
/// the address key the merge lookup compares on. Purely combinational and stateless -- it reads
/// no MSHR entry, which is what lets it live outside the main process.
///
/// Requests carry word addresses. Bursts may start at any bank, but must remain in one tile
/// bank stripe. An invalid burst is excluded from merging; the parent asserts the protocol error.
module mempool_group_mshr_req_decode
  import mempool_pkg::*;
#(
  parameter int unsigned NumTilesPerGroup         = 16,
  parameter int unsigned NumRemoteReqPortsPerTile = 3,
  parameter int unsigned BurstLenWidth            = 5,
  parameter int unsigned TileIdBits               = 4,
  parameter int unsigned TileBankBits             = (NumBanksPerTile > 1) ? $clog2(NumBanksPerTile) : 1,
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
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_burst_invalid;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_len_is_burst;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_can_merge_single;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_can_merge_burst;
  // Decode the length and tile boundary in parallel with the request class.
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_len_ge2;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] req_crosses_tile;
  localparam int unsigned BoundaryWidth =
      ((TileBankBits > BurstLenWidth) ? TileBankBits : BurstLenWidth) + 1;
  logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]
        [BoundaryWidth-1:0] req_bank_end;

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

        // The widened sum includes the exclusive last bank, so a carry cannot hide a crossing.
        assign req_len_ge2[t][p]        = |req_i[t][p].burst_len[BurstLenWidth-1:1];
        assign req_bank_end[t][p] =
            ((NumBanksPerTile > 1) ?
             BoundaryWidth'(tile_addr_o[t][p][TileBankBits-1:0]) : BoundaryWidth'(0)) +
            BoundaryWidth'(req_i[t][p].burst_len);
        assign req_crosses_tile[t][p] = (req_bank_end[t][p] > BoundaryWidth'(NumBanksPerTile)) ||
                                        (req_i[t][p].burst_len > BurstLenWidth'(MaxBurstWords));
        assign req_burst_invalid[t][p] = req_valid_i[t][p] && req_len_ge2[t][p] &&
                                            req_crosses_tile[t][p];
        assign len_o[t][p] = (!req_valid_i[t][p] || !is_load_o[t][p] ||
                              req_burst_invalid[t][p]) ? BurstLenWidth'(1) : len_raw_o[t][p];
        // len_o >= 1 by construction, so len_o > 1 is len_o != 1.
        assign req_len_is_burst[t][p] = req_valid_i[t][p] && !is_single_o[t][p];

        // Preserve the exact start bank. The parent also compares burst length, so different
        // subranges cannot subscribe to one another's ordinal response stream.
        assign tile_addr_key_o[t][p] = req_len_is_burst[t][p] ? tile_addr_o[t][p] : '0;
        assign addr_key_burst_o[t][p] = req_i[t][p].tgt_addr;
        assign addr_key_single_o[t][p] = merge_addr_key(req_i[t][p].tgt_addr);
        assign addr_key_o[t][p] = !req_valid_i[t][p] ? '0
                                : req_len_is_burst[t][p]
                                    ? addr_key_burst_o[t][p]
                                    : addr_key_single_o[t][p];

        // Invalid bursts retain the non-mergeable single classification.
        assign is_single_o    [t][p] = req_valid_i[t][p] &&
                                       (!is_load_o[t][p] || !req_len_ge2[t][p] ||
                                        req_crosses_tile[t][p]);
        // len_o == MshrFullBurstWords needs the un-clamped length, so is_load, containment and a
        // direct burst_len compare are the whole test (is_load_o implies req_valid_i).
        assign is_full_burst_o[t][p] = is_load_o[t][p] && !req_crosses_tile[t][p] &&
                                       (req_i[t][p].burst_len == BurstLenWidth'(MshrFullBurstWords));
        assign is_non_full_burst_o[t][p] = req_valid_i[t][p] && !is_single_o[t][p] &&
                                           !is_full_burst_o[t][p];

        // The class test and the bypass test both branch on is_single, so branch once. is_load_o
        // implies req_valid_i, and the three classes are disjoint and cover a valid request, so the
        // non-single arm is just which burst class is enabled. An invalid burst has is_single set
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
