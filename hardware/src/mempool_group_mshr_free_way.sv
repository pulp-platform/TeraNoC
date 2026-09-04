// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/// Per-bank free-way lookup for the group MSHR: which way, if any, each bank would allocate next.
///
/// Two passes, INVALID first. Pass 1 takes the lowest invalid way. Only if the bank has none does
/// pass 2 reclaim a resident CACHED way, scanning from that bank's round-robin victim pointer so
/// the victim rotates instead of always falling on way 0.
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
  input  logic [MshrNum-1:0]                 reclaimable_i,
  input  logic [BankNum-1:0][VictimPtrW-1:0] victim_rr_i,
  output logic [BankNum-1:0]                 has_free_o,
  output logic [BankNum-1:0][IdW-1:0]        free_id_o
);

  int unsigned victim_rw;
  int unsigned e;

  always_comb begin
    victim_rw = 0;
    e         = 0;
    for (int b = 0; b < BankNum; b++) begin
      has_free_o[b] = 1'b0;
      free_id_o[b]  = IdW'(b * WaysPerBank);
      // Pass 1: lowest INVALID way.
      for (int w = 0; w < WaysPerBank; w++) begin
        e = b * WaysPerBank + w;
        if (!has_free_o[b] && !valid_i[e]) begin
          has_free_o[b] = 1'b1;
          free_id_o[b]  = IdW'(e);
        end
      end
      // Pass 2: reclaim a CACHED way, from the RR victim pointer so the victim rotates.
      if (!has_free_o[b] && CacheReclaimable) begin
        for (int w = 0; w < WaysPerBank; w++) begin
          victim_rw = w;
          if (CacheVictimRR) begin
            victim_rw = int'(victim_rr_i[b]) + w;
            if (victim_rw >= WaysPerBank) victim_rw = victim_rw - WaysPerBank;
          end
          e = b * WaysPerBank + victim_rw;
          if (!has_free_o[b] && reclaimable_i[e]) begin
            has_free_o[b] = 1'b1;
            free_id_o[b]  = IdW'(e);
          end
        end
      end
    end
  end

endmodule
