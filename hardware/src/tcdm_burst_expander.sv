// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Description: Expand a burst request (burst_len > 1) into single-word
//              requests by incrementing addr/meta_id per beat.
//
// Notes:
// - Issues up to IssueWidth beats per cycle. The input port is stalled while draining a burst.
// - Assumes burst_len is in words (not bytes).

module tcdm_burst_expander
  import mempool_pkg::*;
#(
  parameter type req_t = logic,
  parameter int unsigned MaxBurstWords = mempool_pkg::MaxBurstWords,
  parameter int unsigned BurstLenWidth = mempool_pkg::BurstLenWidth,
  parameter int unsigned IssueWidth    = 1
) (
  input  logic clk_i,
  input  logic rst_ni,
  // Input request (may be burst)
  input  req_t req_i,
  input  logic valid_i,
  output logic ready_o,
  // Output request (always single-word)
  output req_t  [IssueWidth-1:0] req_o,
  output logic  [IssueWidth-1:0] valid_o,
  input  logic  [IssueWidth-1:0] ready_i
);

  localparam int unsigned BurstAlignBits = (MaxBurstWords > 1) ? $clog2(MaxBurstWords) : 1;

  req_t req_q, req_d;
  logic active_q, active_d;
  logic [BurstLenWidth-1:0] beat_q, beat_d;
  logic [BurstLenWidth-1:0] len_q, len_d;

  logic req_is_load;
  logic burst_aligned_i;
  logic [BurstLenWidth-1:0] len_i;
  logic [BurstLenWidth-1:0] len_raw_i;
  logic is_burst_i;
  logic [BurstLenWidth-1:0] beat_base;
  logic [BurstLenWidth-1:0] len_base;
  logic [BurstLenWidth-1:0] remaining;
  logic [BurstLenWidth-1:0] issue_cnt;
  logic issue_ready;
  logic have_req;
  req_t req_base;

  assign req_is_load = (!req_i.wen) && (req_i.wdata.amo == '0);
  assign len_raw_i   = (req_i.burst_len == '0) ? BurstLenWidth'(1) : req_i.burst_len;
  assign burst_aligned_i = (req_i.tgt_addr[BurstAlignBits-1:0] == '0);
  assign len_i       = (req_is_load && burst_aligned_i) ? len_raw_i : BurstLenWidth'(1);
  assign is_burst_i  = (len_i > 1);

  always_comb begin
    // Default state
    req_d    = req_q;
    active_d = active_q;
    beat_d   = beat_q;
    len_d    = len_q;

    for (int k = 0; k < IssueWidth; k++) begin
      valid_o[k] = 1'b0;
      req_o[k]   = '0;
    end
    ready_o = 1'b0;

    req_base  = active_q ? req_q : req_i;
    len_base  = active_q ? len_q : len_i;
    beat_base = active_q ? beat_q : '0;
    have_req  = active_q ? 1'b1 : valid_i;
    remaining = have_req ? (len_base - beat_base) : '0;
    if (remaining > BurstLenWidth'(IssueWidth)) begin
      issue_cnt = BurstLenWidth'(IssueWidth);
    end else begin
      issue_cnt = remaining;
    end

    issue_ready = 1'b1;
    for (int k = 0; k < IssueWidth; k++) begin
      if (k < issue_cnt) begin
        issue_ready &= ready_i[k];
      end
    end

    if (have_req) begin
      for (int k = 0; k < IssueWidth; k++) begin
        if (k < issue_cnt) begin
          valid_o[k] = 1'b1;
          req_o[k]   = req_base;
          req_o[k].tgt_addr      = req_base.tgt_addr + (beat_base + k[BurstLenWidth-1:0]);
          req_o[k].wdata.meta_id = req_base.wdata.meta_id + (beat_base + k[BurstLenWidth-1:0]);
          req_o[k].burst_len     = BurstLenWidth'(1);
        end
      end
    end

    if (!active_q) begin
      if (valid_i) begin
        ready_o = issue_ready;
        if (issue_ready) begin
          if (remaining > issue_cnt) begin
            req_d    = req_i;
            active_d = 1'b1;
            len_d    = len_i;
            beat_d   = beat_base + issue_cnt;
          end else begin
            active_d = 1'b0;
            beat_d   = '0;
            len_d    = '0;
          end
        end
      end else begin
        ready_o = 1'b1;
      end
    end else begin
      if (issue_ready) begin
        if (remaining > issue_cnt) begin
          beat_d = beat_base + issue_cnt;
        end else begin
          active_d = 1'b0;
          beat_d   = '0;
          len_d    = '0;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_q    <= '0;
      active_q <= 1'b0;
      beat_q   <= '0;
      len_q    <= '0;
    end else begin
      req_q    <= req_d;
      active_q <= active_d;
      beat_q   <= beat_d;
      len_q    <= len_d;
    end
  end

`ifndef SYNTHESIS
  // Burst requests must be 16-word aligned (word address).
  burst_load_only: assert property(
    @(posedge clk_i) disable iff (!rst_ni)
      !(valid_i && ready_o && (len_raw_i > 1)) || req_is_load)
    else $warning("Burst expander: non-load burst observed; clamping to single beat.");

  burst_aligned: assert property(
    @(posedge clk_i) disable iff (!rst_ni)
      !(valid_i && ready_o && req_is_load && (len_raw_i > 1)) || burst_aligned_i)
    else $warning("Burst expander: unaligned burst observed; clamping to single beat.");
`endif

endmodule
