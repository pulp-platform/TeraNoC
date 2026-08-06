// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Samuel Riedel <sriedel@iis.ee.ethz.ch>
//
// Adapted from the axi_burst_splitter authored by:
//   Andreas Kurth       <akurth@iis.ee.ethz.ch>
//   Florian Zaruba      <zarubaf@iis.ee.ethz.ch>
//   Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

/// Convert from AXI to Cache requests and reconstruct response beats on the way back
/// Adapted from axi_burst_splitter
module snitch_axi_to_cache #(
  // Maximum number of AXI read bursts outstanding at the same time
  parameter int unsigned MaxTrans           = 32'd0,
  // AXI Bus Types
  parameter type         req_t              = logic,
  parameter type         resp_t             = logic,
  // R-MCAST (docs/icache_rmcast_design.md): deliver a merged response to every waiting tile icache
  // in ONE beat instead of unrolling the requester bitmask one id per cycle.
  // McastPortMask = '0 (default) disables the feature; every added term then const-folds away.
  parameter int unsigned McastNumPorts      = 1,
  parameter int unsigned McastIdShift       = 0,
  parameter logic [McastNumPorts-1:0] McastPortMask = '0,
  parameter snitch_icache_pkg::config_t CFG = '0
)(
  input  logic                         clk_i,
  input  logic                         rst_ni,
  // Cache request
  output logic [CFG.FETCH_AW-1:0]      req_addr_o,
  output logic [CFG.ID_WIDTH_REQ-1:0]  req_id_o,
  output logic                         req_valid_o,
  input  logic                         req_ready_i,
  // Cache response
  input  logic [CFG.LINE_WIDTH-1:0]    rsp_data_i,
  input  logic                         rsp_error_i,
  input  logic [CFG.ID_WIDTH_RESP-1:0] rsp_id_i,
  input  logic                         rsp_valid_i,
  output logic                         rsp_ready_o,
  // AXI
  input  req_t                         slv_req_i,
  output resp_t                        slv_rsp_o,
  // R-MCAST: N-hot "this R beat is for these slave ports". Non-zero only while a multicast (phase A)
  // beat is presented; '0 for every ordinary/unicast beat.
  output logic [McastNumPorts-1:0]     r_mcast_mask_o,
  // Same information as r_mcast_mask_o but expanded to ID space, for the demux id-counter pop.
  output logic [CFG.ID_WIDTH_RESP-1:0] r_mcast_idset_o
);

  import cf_math_pkg::idx_width;

  // AXI-word offset within cache line
  localparam int unsigned WordOffset = idx_width(CFG.LINE_WIDTH/CFG.FETCH_DW);

  typedef logic [WordOffset-1:0]       offset_t;
  typedef logic [CFG.ID_WIDTH_REQ-1:0] id_t;
  typedef struct packed {
    logic [CFG.FETCH_AW-1:0]     addr;
    logic [CFG.ID_WIDTH_REQ-1:0] id;
    axi_pkg::len_t               len;
    axi_pkg::burst_t             burst;
  } chan_t;

  // AR Channel
  chan_t         ax_d, ax_q, ax_o;
  offset_t       ar_offset;
  axi_pkg::len_t ar_len;
  logic          cnt_alloc_req, cnt_alloc_gnt;

  // R Channel
  id_t           rsp_id;
  logic          r_cnt_req, r_cnt_gnt;
  logic          r_cnt_len_dec, r_cnt_offset_inc;
  offset_t       r_cnt_offset, r_offset, r_offset_d, r_offset_q;
  axi_pkg::len_t r_cnt_len;

  // --------------------------------------------------
  // Write Channels
  // --------------------------------------------------
  // AW, W, B channel --> Never used tie off
  assign slv_rsp_o.aw_ready = 1'b0;
  assign slv_rsp_o.w_ready = 1'b0;
  assign slv_rsp_o.b_valid = 1'b0;
  assign slv_rsp_o.b = '0;

  // --------------------------------------------------
  // AR Channel
  // --------------------------------------------------
  // Store the offset if the cache is wider than AXI
  assign ar_offset = slv_req_i.ar.addr[$clog2(CFG.FETCH_DW/8)+:WordOffset];
  // Issue less requests if the cache is wider than AXI
  always_comb begin
    if (CFG.LINE_WIDTH > CFG.FETCH_DW) begin
      ar_len = (slv_req_i.ar.len + ar_offset) >> $clog2(CFG.LINE_WIDTH/CFG.FETCH_DW);
    end else begin
      ar_len = slv_req_i.ar.len;
    end
  end

  // Store counters
  axi_burst_splitter_table #(
    .MaxTrans ( MaxTrans         ),
    .IdWidth  ( CFG.ID_WIDTH_REQ ),
    .offset_t ( offset_t         )
  ) i_axi_burst_splitter_table (
    .clk_i,
    .rst_ni,
    .alloc_id_i       ( slv_req_i.ar.id  ),
    .alloc_len_i      ( slv_req_i.ar.len ),
    .alloc_offset_i   ( ar_offset        ),
    .alloc_req_i      ( cnt_alloc_req    ),
    .alloc_gnt_o      ( cnt_alloc_gnt    ),
    .cnt_id_i         ( rsp_id           ),
    .cnt_len_o        ( r_cnt_len        ),
    .cnt_offset_o     ( r_cnt_offset     ),
    .cnt_set_err_i    ( 1'b0             ),
    .cnt_err_o        ( /* unused */     ),
    .cnt_len_dec_i    ( r_cnt_len_dec    ),
    .cnt_offset_inc_i ( r_cnt_offset_inc ),
    .cnt_req_i        ( r_cnt_req        ),
    .cnt_gnt_o        ( r_cnt_gnt        )
  );

  assign req_addr_o = ax_o.addr;
  assign req_id_o = ax_o.id;

  typedef enum logic {Idle, Busy} ar_state_e;
  ar_state_e ar_state_d, ar_state_q;

  // R-MCAST: an ELIGIBLE read is served by phase A, which never queries the burst-length table
  // (r_cnt_req = 0). It must therefore not ALLOCATE a table entry either, or the entry would leak
  // and eventually block AR. Eligibility is a pure function of the (constant-masked) id, so an id is
  // either always eligible or never -- alloc and query can never disagree.
  logic ar_elig, ar_noalloc;
  assign ar_elig    = (McastPortMask != '0)
                   && (slv_req_i.ar.id[McastIdShift-1:0] == '0)
                   && McastPortMask[slv_req_i.ar.id[$bits(slv_req_i.ar.id)-1:McastIdShift]];
  assign ar_noalloc = ar_elig;

  always_comb begin
    cnt_alloc_req      = 1'b0;
    ax_d               = ax_q;
    ar_state_d         = ar_state_q;
    ax_o               = '0;
    req_valid_o        = 1'b0;
    slv_rsp_o.ar_ready = 1'b0;
    unique case (ar_state_q)
      Idle: begin
        if (slv_req_i.ar_valid && (cnt_alloc_gnt || ar_noalloc)) begin
          if (ar_len == '0) begin // No splitting required -> feed through.
            ax_o.addr  = slv_req_i.ar.addr >> CFG.LINE_ALIGN << CFG.LINE_ALIGN;
            ax_o.id    = slv_req_i.ar.id;
            ax_o.len   = ar_len;
            req_valid_o = 1'b1;
            // As soon as downstream is ready, allocate a counter and acknowledge upstream.
            // R-MCAST: an eligible id skips the allocation (see ar_noalloc above).
            if (req_ready_i) begin
              cnt_alloc_req      = ~ar_noalloc;
              slv_rsp_o.ar_ready = 1'b1;
            end
          end else begin // Splitting required.
            // Store Ax, allocate a counter, and acknowledge upstream.
            ax_d.addr          = slv_req_i.ar.addr >> CFG.LINE_ALIGN << CFG.LINE_ALIGN;
            ax_d.id            = slv_req_i.ar.id;
            ax_d.len           = ar_len;
            ax_d.burst         = slv_req_i.ar.burst;
            cnt_alloc_req      = 1'b1;
            slv_rsp_o.ar_ready = 1'b1;
            // Try to feed first burst through.
            ax_o     = ax_d;
            ax_o.len = '0;
            req_valid_o = 1'b1;
            if (req_ready_i) begin
              // Reduce number of bursts still to be sent by one and increment address.
              ax_d.len--;
              if (ax_d.burst == axi_pkg::BURST_INCR) begin
                ax_d.addr += CFG.LINE_WIDTH/8;
              end
            end
            ar_state_d = Busy;
          end
        end
      end
      Busy: begin
        // Sent next burst from split.
        ax_o        = ax_q;
        ax_o.len    = '0;
        req_valid_o = 1'b1;
        if (req_ready_i) begin
          if (ax_q.len == '0) begin
            // If this was the last burst, go back to idle.
            ar_state_d = Idle;
          end else begin
            // Otherwise, continue with the next burst.
            ax_d.len--;
            if (ax_q.burst == axi_pkg::BURST_INCR) begin
              ax_d.addr += CFG.LINE_WIDTH/8;
            end
          end
        end
      end
      default: /*do nothing*/;
    endcase
  end

  // registers
  `FF(ax_q, ax_d, '0, clk_i, rst_ni)
  `FF(ar_state_q, ar_state_d, Idle, clk_i, rst_ni)

  // --------------------------------------------------
  // R Channel
  // --------------------------------------------------
  // Cut path
  typedef struct packed {
    logic [CFG.LINE_WIDTH-1:0]    data;
    logic                         error;
    logic [CFG.ID_WIDTH_RESP-1:0] id;
  } rsp_in_t;

  logic rsp_valid_q, rsp_ready_q;
  rsp_in_t rsp_in_d, rsp_in_q;

  assign rsp_in_d.data  = rsp_data_i;
  assign rsp_in_d.error = rsp_error_i;
  assign rsp_in_d.id    = rsp_id_i;

  spill_register #(
    .T      ( rsp_in_t),
    .Bypass ( 1'b0    )
  ) i_cut_rsp_in (
    .clk_i   ( clk_i       ),
    .rst_ni  ( rst_ni      ),
    .valid_i ( rsp_valid_i ),
    .ready_o ( rsp_ready_o ),
    .data_i  ( rsp_in_d    ),
    .valid_o ( rsp_valid_q ),
    .ready_i ( rsp_ready_q ),
    .data_o  ( rsp_in_q    )
  );

  // Reconstruct `id` by splitting cache's ID vector into multiple responses
  // rsp_valid_i --> [forward]                                             --> rsp_valid
  // rsp_ready_o <-- [ready if downstream is ready and input ID is onehot] <-- rsp_ready
  // rsp_id_i    --> [from vector to single ID with lzc]                   --> rsp_id
  // rsp_data_i  --> [forward]                                             --> rsp_in_q.data
  // rsp_error_i --> [forward]                                             --> rsp_in_q.error
  logic rsp_valid, rsp_ready;
  logic rsp_id_onehot, rsp_id_empty;
  logic [CFG.ID_WIDTH_RESP-1:0] rsp_id_mask, rsp_id_masked;

  // ------------------------------------------------------------------------------------------
  // R-MCAST phase split (docs/icache_rmcast_design.md 3.2)
  //   phase A (mcast_phase): every ELIGIBLE requester -- one beat, all of them at once.
  //   phase B             : the residue (DMA / SoC port) -- the original one-id-per-cycle walk.
  // The two sets are an EXACT partition of the outstanding mask, so no id is served twice or lost,
  // and an eligible id can never reach the lzc/burst-table path.
  // McastPortMask is an elaboration constant, so mcast_pmask is a pure wire-pick off flops (no lzc
  // in front of it) and all non-eligible bits fold away.
  // ------------------------------------------------------------------------------------------
  logic [McastNumPorts-1:0]     mcast_pmask;
  logic [CFG.ID_WIDTH_RESP-1:0] mcast_idset, resid_set;
  logic                         mcast_phase;
  logic [McastNumPorts-1:0]     mcast_rep_onehot;
  logic [$clog2(McastNumPorts > 1 ? McastNumPorts : 2)-1:0] mcast_rep;

  always_comb begin
    mcast_idset = '0;
    for (int unsigned p = 0; p < McastNumPorts; p++) begin
      mcast_pmask[p] = McastPortMask[p] & rsp_id_masked[p << McastIdShift];
      mcast_idset[p << McastIdShift] = mcast_pmask[p];
    end
  end
  assign resid_set   = rsp_id_masked & ~mcast_idset;
  assign mcast_phase = |mcast_pmask;

  lzc #(
    .WIDTH ( McastNumPorts ),
    .MODE  ( 0             )
  ) i_lzc_mcast (
    .in_i    ( mcast_pmask ),
    .cnt_o   ( mcast_rep   ),
    .empty_o ( /* unused */)
  );

  // Pop the cache entry when phase A (if any) and phase B have both drained.
  assign rsp_ready_q   = mcast_phase ? (rsp_ready & ~|resid_set)
                                     : ((rsp_id_onehot | rsp_id_empty) & rsp_ready);
  assign rsp_valid     = rsp_valid_q; // And not empty?
  assign rsp_id_masked = rsp_in_q.id & ~rsp_id_mask;
  assign r_mcast_mask_o  = (rsp_valid && mcast_phase) ? mcast_pmask : '0;
  assign r_mcast_idset_o = (rsp_valid && mcast_phase) ? mcast_idset : '0;

  // The original walk now runs over the RESIDUE only (identical when McastPortMask == '0).
  lzc #(
    .WIDTH ( CFG.ID_WIDTH_RESP ),
    .MODE  ( 0                 )
  ) i_lzc (
    .in_i    ( resid_set    ),
    .cnt_o   ( rsp_id       ),
    .empty_o ( rsp_id_empty )
  );

  cc_onehot #(
    .Width ( CFG.ID_WIDTH_RESP )
  ) i_onehot (
    .d_i         ( resid_set     ),
    .is_onehot_o ( rsp_id_onehot )
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(~rst_ni) begin
      rsp_id_mask <= '0;
    end else begin
      if (rsp_valid && rsp_ready) begin
        // Downstream handshake --> Go to next ID.
        // R-MCAST phase A retires EVERY eligible id in one handshake; phase B is the original walk.
        rsp_id_mask <= rsp_id_mask | (mcast_phase ? mcast_idset : (1 << rsp_id));
      end
      if (rsp_valid_q && rsp_ready_q) begin // Or empty, should be redundant
        // Upstream handshake --> Clear mask
        rsp_id_mask <= '0;
      end
    end
  end

  // Reconstruct `last`, feed rest through.
  logic r_last_d, r_last_q;
  logic [CFG.FETCH_DW-1:0] r_data, r_data_d, r_data_q;
  typedef enum logic {RFeedthrough, RWait} r_state_e;
  r_state_e r_state_d, r_state_q;

  // Tie the offset down if cache and AXI width are the same
  assign r_offset  = (CFG.LINE_WIDTH > CFG.FETCH_DW) ? r_cnt_offset : '1;
  // Do not realign data if cache and AXI width are the same
  assign r_data = (CFG.LINE_WIDTH > CFG.FETCH_DW) ?
      rsp_in_q.data >> (r_offset * CFG.FETCH_DW) : rsp_in_q.data;

  always_comb begin
    r_cnt_len_dec     = 1'b0;
    r_cnt_offset_inc  = 1'b0;
    r_cnt_req         = 1'b0;
    r_last_d          = r_last_q;
    r_state_d         = r_state_q;
    r_data_d          = r_data_q;
    r_offset_d        = r_offset_q;
    rsp_ready         = 1'b0;
    slv_rsp_o.r.id    = rsp_id;
    slv_rsp_o.r.data  = r_data;
    slv_rsp_o.r.resp  = rsp_in_q.error; // This response is already an AXI response.
    slv_rsp_o.r.user  = '0;
    slv_rsp_o.r.last  = 1'b0;
    slv_rsp_o.r_valid = 1'b0;

    unique case (r_state_q)
      RFeedthrough: begin
        // R-MCAST phase A: one beat for ALL eligible requesters. This arm never enters RWait --
        // while the beat is held the spill is not popped, so rsp_in_q is frozen, and rsp_id_mask
        // only changes on a handshake, so mcast_pmask/mcast_rep are frozen too. Payload stability
        // is therefore free (this is what makes the freeze-register bugs of other designs
        // impossible). r.last is a THEOREM here: eligibility implies ar.len == 0 (see
        // mempool_pkg::ROCacheMcastOk), and r_offset is tied '1 because LINE_WIDTH == FETCH_DW.
        if (rsp_valid && mcast_phase) begin
          slv_rsp_o.r_valid = 1'b1;
          slv_rsp_o.r.last  = 1'b1;
          // id[McastIdShift-1:0] == 0 for every eligible member, so one representative id is
          // bit-exact for all of them after the group mux truncates to the slave-port id width.
          slv_rsp_o.r.id    = mcast_rep << McastIdShift;
          r_cnt_req         = 1'b0;   // burst table is never queried for eligible ids
          if (slv_req_i.r_ready) rsp_ready = 1'b1;
        // If downstream has an R beat and the R counters can give us the remaining length of
        // that burst, ...
        end else if (rsp_valid) begin
          r_cnt_req = 1'b1;
          if (r_cnt_gnt) begin
            r_last_d = (r_cnt_len == 8'd0);
            slv_rsp_o.r.last   = r_last_d;
            // Decrement the counter
            r_cnt_len_dec      = 1'b1;
            // Increment the offset counter
            r_cnt_offset_inc   = 1'b1;
            // Try to forward the beat upstream
            slv_rsp_o.r_valid  = 1'b1;
            if (slv_req_i.r_ready) begin
              // Is this the last chunk of this cache line
              if (r_offset == '1 || r_last_d) begin
                // Acknowledge downstream
                rsp_ready      = 1'b1;
              end
            end else begin
              // Keep output constant
              r_data_d   = r_data;
              r_offset_d = r_offset;
              // Wait for upstream to become ready
              r_state_d = RWait;
            end
          end
        end
      end
      RWait: begin
        slv_rsp_o.r.last   = r_last_q;
        slv_rsp_o.r_valid  = rsp_valid;
        slv_rsp_o.r.data   = r_data_q;
        if (rsp_valid && slv_req_i.r_ready) begin
          // Is this the last chunk of this cache line
          if (r_offset_q == '1 || r_last_q) begin
            // Acknowledge downstream
            rsp_ready      = 1'b1;
          end
          r_state_d         = RFeedthrough;
        end
      end
      default: /*do nothing*/;
    endcase
  end

  // --------------------------------------------------
  // Flip-Flops
  // --------------------------------------------------
  `FF(r_last_q, r_last_d, 1'b0, clk_i, rst_ni)
  `FF(r_state_q, r_state_d, RFeedthrough, clk_i, rst_ni)
  `FF(r_data_q, r_data_d, '0, clk_i, rst_ni)
  `FF(r_offset_q, r_offset_d, '0, clk_i, rst_ni)

endmodule


/// Stores the burst length and the corresponding address offset for the axi_to_cache module.
/// Adapted from axi_burst_splitter_counters
module axi_burst_splitter_table #(
  parameter int unsigned MaxTrans = 0,
  parameter int unsigned IdWidth  = 0,
  parameter type         offset_t = logic,
  parameter type         id_t     = logic [IdWidth-1:0]
) (
  input  logic          clk_i,
  input  logic          rst_ni,

  input  id_t           alloc_id_i,
  input  axi_pkg::len_t alloc_len_i,
  input  offset_t       alloc_offset_i,
  input  logic          alloc_req_i,
  output logic          alloc_gnt_o,

  input  id_t           cnt_id_i,
  output axi_pkg::len_t cnt_len_o,
  output offset_t       cnt_offset_o,
  input  logic          cnt_set_err_i,
  output logic          cnt_err_o,
  input  logic          cnt_len_dec_i,
  input  logic          cnt_offset_inc_i,
  input  logic          cnt_req_i,
  output logic          cnt_gnt_o
);
  localparam int unsigned CntIdxWidth = (MaxTrans > 1) ? $clog2(MaxTrans) : 32'd1;

  typedef logic [CntIdxWidth-1:0]         cnt_idx_t;
  typedef logic [$bits(axi_pkg::len_t):0] cnt_t;

  cnt_idx_t            cnt_free_idx, cnt_r_idx;
  logic [MaxTrans-1:0] cnt_len_dec, cnt_offset_inc, cnt_free, cnt_set, err_d, err_q;
  cnt_t                cnt_len_inp;
  cnt_t [MaxTrans-1:0] cnt_len_oup;
  offset_t                cnt_offset_inp;
  offset_t [MaxTrans-1:0] cnt_offset_oup;
  for (genvar i = 0; i < MaxTrans; i++) begin : gen_cnt
    counter #(
      .WIDTH ( $bits(cnt_t) )
    ) i_cnt_len (
      .clk_i,
      .rst_ni,
      .clear_i    ( 1'b0           ),
      .en_i       ( cnt_len_dec[i] ),
      .load_i     ( cnt_set[i]     ),
      .down_i     ( 1'b1           ),
      .d_i        ( cnt_len_inp    ),
      .q_o        ( cnt_len_oup[i] ),
      .overflow_o (                )  // not used
    );
    counter #(
      .WIDTH ( $bits(offset_t) )
    ) i_cnt_offset (
      .clk_i,
      .rst_ni,
      .clear_i    ( 1'b0              ),
      .en_i       ( cnt_offset_inc[i] ),
      .load_i     ( cnt_set[i]        ),
      .down_i     ( 1'b0              ),
      .d_i        ( cnt_offset_inp    ),
      .q_o        ( cnt_offset_oup[i] ),
      .overflow_o (                   )  // not used
    );
    assign cnt_free[i] = (cnt_len_oup[i] == '0);
  end
  assign cnt_len_inp    = {1'b0, alloc_len_i} + 1;
  assign cnt_offset_inp = alloc_offset_i;

  lzc #(
    .WIDTH ( MaxTrans ),
    .MODE  ( 1'b0     )
  ) i_lzc (
    .in_i    ( cnt_free     ),
    .cnt_o   ( cnt_free_idx ),
    .empty_o (              )
  );

  logic idq_inp_req, idq_inp_gnt;
  logic idq_oup_gnt, idq_oup_valid, idq_oup_pop;
  id_queue #(
    .ID_WIDTH ( $bits(id_t) ),
    .CAPACITY ( MaxTrans    ),
    .FULL_BW  ( 1'b1        ),
    .data_t   ( cnt_idx_t   )
  ) i_idq (
    .clk_i,
    .rst_ni,
    .inp_id_i         ( alloc_id_i    ),
    .inp_data_i       ( cnt_free_idx  ),
    .inp_req_i        ( idq_inp_req   ),
    .inp_gnt_o        ( idq_inp_gnt   ),
    .exists_data_i    ( '0            ),
    .exists_mask_i    ( '0            ),
    .exists_req_i     ( 1'b0          ),
    .exists_o         ( /* unused */  ),
    .exists_gnt_o     ( /* unused */  ),
    .oup_id_i         ( cnt_id_i      ),
    .oup_pop_i        ( idq_oup_pop   ),
    .oup_req_i        ( cnt_req_i     ),
    .oup_data_o       ( cnt_r_idx     ),
    .oup_data_valid_o ( idq_oup_valid ),
    .oup_gnt_o        ( idq_oup_gnt   )
  );
  logic [8:0] read_len;
  assign idq_inp_req  = alloc_req_i & alloc_gnt_o;
  assign alloc_gnt_o  = idq_inp_gnt & |(cnt_free);
  assign cnt_gnt_o    = idq_oup_gnt & idq_oup_valid;
  assign read_len     = cnt_len_oup[cnt_r_idx] - 1;
  assign cnt_len_o    = read_len[7:0];
  assign cnt_offset_o = cnt_offset_oup[cnt_r_idx];
  assign idq_oup_pop  = cnt_req_i & cnt_gnt_o & cnt_len_dec_i & (cnt_len_o == 8'd0);

  always_comb begin
    cnt_len_dec            = '0;
    cnt_len_dec[cnt_r_idx] = cnt_req_i & cnt_gnt_o & cnt_len_dec_i;
  end
  always_comb begin
    cnt_offset_inc            = '0;
    cnt_offset_inc[cnt_r_idx] = cnt_req_i & cnt_gnt_o & cnt_offset_inc_i;
  end
  always_comb begin
    cnt_set               = '0;
    cnt_set[cnt_free_idx] = alloc_req_i & alloc_gnt_o;
  end
  always_comb begin
    err_d     = err_q;
    cnt_err_o = err_q[cnt_r_idx];
    if (cnt_req_i && cnt_gnt_o && cnt_set_err_i) begin
      err_d[cnt_r_idx] = 1'b1;
      cnt_err_o        = 1'b1;
    end
    if (alloc_req_i && alloc_gnt_o) begin
      err_d[cnt_free_idx] = 1'b0;
    end
  end

  // registers
  `FF(err_q, err_d, '0, clk_i, rst_ni)

  `ifndef VERILATOR
  // pragma translate_off
  // An `assume` is a constraint, not a checker -- it must not terminate a simulation.
  // VCS evaluates assumes by default and this $finish() (bare, so no diagnostic banner and
  // exit status 0) silently killed every 1024-core run at the same cycle, immediately after
  // the barrier release when all cores hit the RO-cache -> L2 bridge at once. QuestaSim does
  // not act on assumes, so it never surfaced there. Report, do not exit.
  idq_oup_handshake: assert property (@(posedge clk_i) idq_oup_gnt |-> idq_oup_valid)
    else $error("[snitch_axi_to_cache] %m: ID-queue output not valid while granted");
  // pragma translate_on
  `endif

endmodule
