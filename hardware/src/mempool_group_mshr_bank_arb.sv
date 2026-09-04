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
  input  logic [NumSlots-1:0][BankIdW-1:0]   bank_i,      // bank the slot targets
  input  logic [NumSlots-1:0]                rr_mask_i,   // 1 = slot at/above the rotation base
  input  logic [NumBanks-1:0]                bank_gate_i, // 0 = this bank grants nobody
  output logic [NumBanks-1:0][NumSlots-1:0]  win_oh_o     // one-hot winner per bank
);

  logic [NumBanks-1:0][NumSlots-1:0] rq;
  logic [NumSlots-1:0] hi, lo;

  generate
    for (int b = 0; b < NumBanks; b++) begin : gen_rq_b
      for (int s = 0; s < NumSlots; s++) begin : gen_rq_s
        assign rq[s] = cand_i[s] && (int'(bank_i[s]) == b);
      end
    end
  endgenerate

  always_comb begin
    rq = '0;
    hi = '0;
    lo = '0;
    for (int b = 0; b < NumBanks; b++) begin
      for (int s = 0; s < NumSlots; s++) begin
        rq[s] = cand_i[s] && (int'(bank_i[s]) == b);
      end
      hi = rq &  rr_mask_i;
      lo = rq & ~rr_mask_i;
      win_oh_o[b] = !bank_gate_i[b]
                  ? '0
                  : ((hi != '0) ? (hi & (~hi + NumSlots'(1)))
                                : (lo & (~lo + NumSlots'(1))));
    end
  end

endmodule
