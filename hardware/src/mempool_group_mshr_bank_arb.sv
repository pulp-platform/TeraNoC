// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/// Per-bank one-hot arbiter for the group MSHR: grants at most one slot per bank per cycle.
///
/// Used twice -- once for allocation (gated by bank_has_free) and once for merging (ungated).
/// Both callers flatten their (tile, port) requesters into a slot index and pass the bank each
/// slot targets; a slot appears only in its own bank's vector, so the banks arbitrate independently
/// and in parallel.
///
/// The bank is passed PRE-DECODED. The two instances share one req_bank, so an encoded port made
/// each of them build its own NumSlots x NumBanks compare -- twice the comparators and twice the
/// fanout on an early signal. Decoding once in the parent is the same depth for half the gates.
///
/// Priority: split each bank's request vector at the rotation base (rr_mask_i is a thermometer
/// mask, 1 = slot at or above the base), take the lowest set bit of the high half, else of the low
/// half. That is exactly "first candidate at or after the base, wrapping", in one priority encode
/// with no variable shifter.
module mempool_group_mshr_bank_arb #(
  parameter int unsigned NumSlots = 32,
  parameter int unsigned NumBanks = 16,
  parameter int unsigned BankIdW  = 4
) (
  input  logic [NumSlots-1:0]                cand_i,      // slot wants a grant
  input  logic [NumSlots-1:0][NumBanks-1:0]  bank_oh_i,   // bank the slot targets, PRE-DECODED
  input  logic [NumSlots-1:0]                rr_mask_i,   // 1 = slot at/above the rotation base
  input  logic [NumBanks-1:0]                bank_gate_i, // 0 = this bank grants nobody
  output logic [NumBanks-1:0][NumSlots-1:0]  win_oh_o,    // one-hot winner per bank
  // "this bank granted somebody", WITHOUT waiting for the one-hot. It is the OR-reduce that the
  // priority split already needs, so it lands ~3 levels earlier than |win_oh_o, which must wait
  // for the LSB-isolate and the select mux. A caller whose grant implies its accept can drive a
  // clock-gate enable from this instead -- that enable is a gating check, the tightest in the
  // design, so the levels are worth more here than anywhere else.
  output logic [NumBanks-1:0]                any_o
);

  logic [NumBanks-1:0][NumSlots-1:0] req_per_bank;
  logic [NumBanks-1:0][NumSlots-1:0] req_per_bank_rr_high, req_per_bank_rr_low;
  logic [NumBanks-1:0]               req_per_bank_rr_high_non_empty, req_per_bank_rr_low_non_empty;
  logic [NumBanks-1:0][NumSlots-1:0] req_per_bank_rr_high_oh, req_per_bank_rr_low_oh;
  logic [NumBanks-1:0][NumSlots-1:0] pfx_high, pfx_low;   // doubling prefix-OR, see below

  genvar b, s;

  generate
    for (b = 0; b < NumBanks; b++) begin : gen_req_per_bank_b
      for (s = 0; s < NumSlots; s++) begin : gen_req_per_bank_s
        assign req_per_bank[b][s] = cand_i[s] && bank_oh_i[s][b];
      end
    end
  endgenerate

  generate
    for (b = 0; b < NumBanks; b++) begin : gen_req_per_bank_rr_b
      assign req_per_bank_rr_high[b] = req_per_bank[b] &  rr_mask_i;
      assign req_per_bank_rr_low[b]  = req_per_bank[b] & ~rr_mask_i;
      assign req_per_bank_rr_high_non_empty[b] = (|req_per_bank_rr_high[b] == 1'b1);
      assign req_per_bank_rr_low_non_empty [b] = (|req_per_bank_rr_low [b] == 1'b1);
      // Prefix-OR isolate rather than `v & (-v)`: the two's-complement form maps to a carry chain
      // across NumSlots, which the placed netlist showed rippling ten positions. The doubling
      // prefix below is log2(NumSlots) OR levels plus one AND, and is the same idiom the drain
      // select already uses. Identical result: both keep only the lowest set bit.
      always_comb begin
        pfx_high[b] = req_per_bank_rr_high[b];
        pfx_low [b] = req_per_bank_rr_low [b];
        for (int st = 1; st < NumSlots; st = st << 1) begin
          pfx_high[b] = pfx_high[b] | (pfx_high[b] << st);
          pfx_low [b] = pfx_low [b] | (pfx_low [b] << st);
        end
      end
      assign req_per_bank_rr_high_oh[b] = pfx_high[b] & ~(pfx_high[b] << 1);
      assign req_per_bank_rr_low_oh [b] = pfx_low [b] & ~(pfx_low [b] << 1);

      assign win_oh_o[b] = {NumSlots{bank_gate_i[b]}} &
                           (req_per_bank_rr_high_non_empty[b] ? req_per_bank_rr_high_oh[b]
                                                              : req_per_bank_rr_low_oh[b]);
      // Equal to |win_oh_o[b] by construction: the isolate of a non-empty vector is non-empty,
      // and both halves are gated identically.
      assign any_o[b] = bank_gate_i[b] &
                        (req_per_bank_rr_high_non_empty[b] | req_per_bank_rr_low_non_empty[b]);
    end
  endgenerate

endmodule
