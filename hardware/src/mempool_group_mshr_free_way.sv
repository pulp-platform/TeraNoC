// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/// Per-bank free-way lookup for the group MSHR: which way, if any, each bank would allocate next.
///
/// The two passes run in PARALLEL and each picks its own candidate; the final select prefers the
/// INVALID candidate and falls back to the reclaimable one. Pass 1 takes the lowest invalid way.
/// Pass 2 takes the first reclaimable way at or after that bank's round-robin victim pointer,
/// wrapping, so the victim rotates instead of always falling on way 0.
///
/// At CacheReclaimable = 0 (the shipping setting) pass 2 is NOT GENERATED: no comparators, no
/// second LSB-isolate, and the final mux disappears with it, so the invalid candidate drives the
/// output directly. reclaimable_i is then unused and the caller's producer logic dies with it.
///
/// Takes DERIVED per-entry vectors rather than the entry array: the caller reduces each entry to
/// one valid bit and one reclaimable bit, which keeps this interface ~200 bits instead of carrying
/// MshrNum full entries across the boundary.
module mempool_group_mshr_free_way #(
  parameter int unsigned MshrNum          = 64,
  parameter int unsigned WaysPerBank      = 4,
  parameter int unsigned BankNum          = 16,
  parameter int unsigned IdW              = 6,
  parameter int unsigned VictimPtrW       = 2,
  parameter bit          CacheReclaimable = 1'b0,
  parameter bit          CacheVictimRR    = 1'b0
) (
  input  logic [MshrNum-1:0]                 valid_i,
  /// Entry is a reclaimable CACHED way: resident, no pending subscribers, and no request is about
  /// to hit-merge it this cycle. The caller folds EnableRespCache into this.
  /// UNUSED when CacheReclaimable = 0.
  input  logic [MshrNum-1:0]                 reclaimable_i,
  input  logic [BankNum-1:0][VictimPtrW-1:0] victim_rr_i,
  output logic [BankNum-1:0]                 has_free_o,
  output logic [BankNum-1:0][IdW-1:0]        free_id_o
);

  localparam int unsigned WayIdW = (WaysPerBank > 1) ? $clog2(WaysPerBank) : 1;

  // Pass 1: INVALID ways.
  logic [BankNum-1:0][WaysPerBank-1:0]              way_invalid;
  logic [BankNum-1:0][WaysPerBank-1:0]              way_invalid_oh;
  logic [BankNum-1:0]                               way_invalid_any;

  // Pass 2: reclaimable CACHED ways, scanned from the victim pointer. Tied to '0 when
  // CacheReclaimable = 0, so the comparators and the second LSB-isolate are never built.
  logic [BankNum-1:0][WaysPerBank-1:0]              way_reclaim;
  logic [BankNum-1:0][WaysPerBank-1:0]              way_reclaim_rr_mask;
  logic [BankNum-1:0][WaysPerBank-1:0]              way_reclaim_rr_high, way_reclaim_rr_low;
  logic [BankNum-1:0]                               way_reclaim_rr_high_non_empty;
  logic [BankNum-1:0][WaysPerBank-1:0]              way_reclaim_rr_high_oh, way_reclaim_rr_low_oh;
  logic [BankNum-1:0][WaysPerBank-1:0]              way_reclaim_oh;
  logic [BankNum-1:0]                               way_reclaim_any;

  // Final selection and its one-hot -> binary encoding.
  logic [BankNum-1:0][WaysPerBank-1:0]              way_sel_oh;
  logic [BankNum-1:0][WayIdW-1:0][WaysPerBank-1:0]  way_sel_oh_masked;
  logic [BankNum-1:0][WayIdW-1:0]                   way_sel_idx;

  genvar b, w, k;

  // Pass 1: lowest INVALID way. Always generated.
  generate
    for (b = 0; b < BankNum; b++) begin : gen_way_invalid_b
      for (w = 0; w < WaysPerBank; w++) begin : gen_way_invalid_w
        assign way_invalid[b][w] = ~valid_i[b*WaysPerBank + w];
      end
      assign way_invalid_any[b] = |way_invalid[b];
      assign way_invalid_oh [b] = way_invalid[b] & (~way_invalid[b] + 1);
    end
  endgenerate

  // Pass 2: first reclaimable way at/after the victim pointer, wrapping. Same hi/lo split as the
  // bank arbiter: the high half's lowest set bit is the first candidate at or after the pointer;
  // if that half is empty the scan wraps and the low half's lowest bit wins.
  generate
    if (CacheReclaimable) begin : gen_way_reclaim
      for (b = 0; b < BankNum; b++) begin : gen_way_reclaim_b
        for (w = 0; w < WaysPerBank; w++) begin : gen_way_reclaim_w
          assign way_reclaim[b][w] = reclaimable_i[b*WaysPerBank + w];
          // CacheVictimRR = 0 collapses the mask to all-ones, i.e. plain ascending priority.
          assign way_reclaim_rr_mask[b][w] = CacheVictimRR ? (w >= int'(victim_rr_i[b])) : 1'b1;
        end
        assign way_reclaim_rr_high[b] = way_reclaim[b] &  way_reclaim_rr_mask[b];
        assign way_reclaim_rr_low [b] = way_reclaim[b] & ~way_reclaim_rr_mask[b];
        assign way_reclaim_rr_high_non_empty[b] = (|way_reclaim_rr_high[b] == 1'b1);
        assign way_reclaim_rr_high_oh[b] = way_reclaim_rr_high[b] & (~way_reclaim_rr_high[b] + 1);
        assign way_reclaim_rr_low_oh [b] = way_reclaim_rr_low [b] & (~way_reclaim_rr_low [b] + 1);
        assign way_reclaim_oh [b] = way_reclaim_rr_high_non_empty[b] ? way_reclaim_rr_high_oh[b]
                                                                     : way_reclaim_rr_low_oh[b];
        assign way_reclaim_any[b] = |way_reclaim[b];
      end
    end else begin : gen_no_way_reclaim
      assign way_reclaim                   = '0;
      assign way_reclaim_rr_mask           = '0;
      assign way_reclaim_rr_high           = '0;
      assign way_reclaim_rr_low            = '0;
      assign way_reclaim_rr_high_non_empty = '0;
      assign way_reclaim_rr_high_oh        = '0;
      assign way_reclaim_rr_low_oh         = '0;
      assign way_reclaim_oh                = '0;
      assign way_reclaim_any               = '0;
    end
  endgenerate

  // Final select: INVALID wins, reclaim is the fallback. With CacheReclaimable = 0 the reclaim
  // terms are constant '0, so the mux and the OR fold away and way_invalid drives the output.
  generate
    for (b = 0; b < BankNum; b++) begin : gen_way_sel_b
      assign way_sel_oh[b] = way_invalid_any[b] ? way_invalid_oh[b] : way_reclaim_oh[b];
      assign has_free_o[b] = way_invalid_any[b] | way_reclaim_any[b];
    end
  endgenerate

  // One-hot to binary: bit k of the index is the OR of every one-hot position w whose own binary
  // value has bit k set. At WaysPerBank = 4 that is idx[0] = oh[1]|oh[3], idx[1] = oh[2]|oh[3].
  // (w >> k) & 1 is evaluated at elaboration -- w and k are genvars -- so each term is either the
  // one-hot bit itself or a constant 0, and this is a plain OR of a fixed subset, not a mux.
  //
  // free_id_o is the absolute entry id. b*WaysPerBank is a per-bank constant and the way index is
  // below WaysPerBank, so the add carries only inside the way field.
  //
  // It does NOT depend on has_free_o, deliberately. Two reasons, and the second is the stronger:
  //   * every consumer gates on it -- bank_win_oh is forced to '0 when the bank has no free way,
  //     and both users of bank_free_id are qualified by bank_win_oh -- so the value is a
  //     don't-care in that case;
  //   * it is not even a relaxation. has_free_o = 0 means way_invalid_any and way_reclaim_any are
  //     both 0, hence way_invalid and way_reclaim are all-zero, hence their LSB-isolates and
  //     way_sel_oh are all-zero, hence the index is already 0. Qualifying it would be a redundant
  //     mux that puts the OR-reductions behind has_free_o into the free_id_o cone for nothing.
  generate
    for (b = 0; b < BankNum; b++) begin : gen_way_idx_b
      for (k = 0; k < WayIdW; k++) begin : gen_way_idx_k
        for (w = 0; w < WaysPerBank; w++) begin : gen_way_idx_w
          assign way_sel_oh_masked[b][k][w] = ((w >> k) & 1) ? way_sel_oh[b][w] : 1'b0;
        end
        assign way_sel_idx[b][k] = |way_sel_oh_masked[b][k];
      end
      assign free_id_o[b] = IdW'(b*WaysPerBank) + IdW'(way_sel_idx[b]);
    end
  endgenerate

endmodule
