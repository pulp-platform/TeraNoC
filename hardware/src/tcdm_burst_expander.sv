// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Description: Expand a burst request (burst_len > 1) into single-word
//              requests by incrementing addr/meta_id per beat.
//
// Notes:
// - Issues up to IssueWidth beats per cycle.
// - Assumes burst_len is in words (not bytes).
// - NumContexts = 1 (default): the input port is stalled while draining a burst
//   (legacy behavior, bit-identical).
// - NumContexts = 2 (docs/tcdm_burst_interleave_design.md): while a burst drains,
//   a second LOAD request is accepted into a shadow context and beats of the two
//   contexts issue round-robin. Two same-address bursts then finish within ~1 cycle
//   of each other instead of a full drain-time apart -- removing the pair-skew
//   injection that intra-group same-line bursts otherwise suffer (they bypass the
//   group MSHR, so this expander is their only convergence point). Loads only:
//   a store/AMO never enters the shadow context, so no write can reorder around
//   un-issued beats of the draining burst; between two loads, every response
//   consumer (MSHR beat_seen bitmap, bypass-retag range match, VLSU ROB) is
//   order-insensitive by construction.

module tcdm_burst_expander
  import mempool_pkg::*;
#(
  parameter type req_t = logic,
  parameter int unsigned MaxBurstWords = mempool_pkg::MaxBurstWords,
  parameter int unsigned BurstLenWidth = mempool_pkg::BurstLenWidth,
  parameter int unsigned IssueWidth    = 1,
  parameter int unsigned NumContexts   = 1
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

  localparam int unsigned BankOffsetBits = (NumBanksPerTile > 1) ? $clog2(NumBanksPerTile) : 1;
  localparam int unsigned BoundaryWidth =
      ((BankOffsetBits > BurstLenWidth) ? BankOffsetBits : BurstLenWidth) + 1;

  // ------------------------------------------------------------------------------------
  // BURST LANE LAW. Spatz distributes a burst's beats across its NrMemPorts reorder buffers
  // by the ordinary word->port rule, so beat b belongs to lane b % BurstLanes and is entry
  // b / BurstLanes of that buffer. This expander is where a burst becomes individual beats,
  // so this is where the split is applied:
  //     core_id <- base core_id + (b % BurstLanes)
  //     meta_id <- base meta_id + (b / BurstLanes)
  // tgt_addr is UNCHANGED (base + b): the address sequence is a property of the memory, not
  // of which buffer the word lands in.
  //
  // Identity for b == 0, so a single-word (non-burst) request passes through byte-identically.
  //
  // Both instantiation sites apply it, and they must: the source group's MSHR recovers b from
  // BOTH fields (mempool_group_mshr.sv burst_beat_of), and a bypassed or intra-group burst
  // reaches its requester with no MSHR in between and so must already be in final form. The
  // own-tile instance never sees a burst -- mempool_tile.sv diverts those onto the group path,
  // because a local response is routed back by crossbar initiator index and cannot be steered
  // by core_id at all.
  localparam int unsigned BurstLanes = mempool_pkg::NumMemPortsPerSpatz;
  localparam int unsigned BurstLaneW = (BurstLanes > 1) ? $clog2(BurstLanes) : 1;
  if (BurstLanes & (BurstLanes - 1))
    $error("[tcdm_burst_expander] NumMemPortsPerSpatz (%0d) must be a power of two.", BurstLanes);
  // ------------------------------------------------------------------------------------

  if ((NumContexts != 1) && (NumContexts != 2))
    $error("[tcdm_burst_expander] NumContexts (%0d) must be 1 or 2.", NumContexts);

  logic req_is_load;
  logic burst_contained_i;
  logic [BoundaryWidth-1:0] burst_end_bank;
  logic [BurstLenWidth-1:0] len_i;
  logic [BurstLenWidth-1:0] len_raw_i;
  logic is_burst_i;

  assign req_is_load = (!req_i.wen) && (req_i.wdata.amo == '0);
  assign len_raw_i   = (req_i.burst_len == '0) ? BurstLenWidth'(1) : req_i.burst_len;
  // tgt_addr is word-addressed. The destination tile is already selected, so
  // expansion may advance banks but must never carry into the next bank row.
  assign burst_end_bank = ((NumBanksPerTile > 1)
                          ? BoundaryWidth'(req_i.tgt_addr[BankOffsetBits-1:0]) : '0) +
                          BoundaryWidth'(len_raw_i);
  assign burst_contained_i = (len_raw_i <= BurstLenWidth'(MaxBurstWords)) &&
                             (burst_end_bank <= BoundaryWidth'(NumBanksPerTile));
  assign len_i       = (req_is_load && burst_contained_i) ? len_raw_i : BurstLenWidth'(1);
  assign is_burst_i  = (len_i > 1);

  if (NumContexts == 1) begin : gen_single_ctx
    // ------------------------------------------------------------------
    // Legacy single-context expander: input stalled while draining.
    // ------------------------------------------------------------------
    req_t req_q, req_d;
    logic active_q, active_d;
    logic [BurstLenWidth-1:0] beat_q, beat_d;
    logic [BurstLenWidth-1:0] len_q, len_d;

    logic [BurstLenWidth-1:0] beat_base;
    logic [BurstLenWidth-1:0] len_base;
    logic [BurstLenWidth-1:0] remaining;
    logic [BurstLenWidth-1:0] issue_cnt;
    logic [BurstLenWidth-1:0] issue_fire_cnt;
    logic issue_prefix_ready;
    logic have_req;
    req_t req_base;

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

      // Issue contiguous beats only: lane k is offered only if all lanes < k can
      // fire in the same cycle. This keeps beat order deterministic.
      issue_fire_cnt     = '0;
      issue_prefix_ready = 1'b1;
      if (have_req) begin
        for (int k = 0; k < IssueWidth; k++) begin
          if ((k < issue_cnt) && issue_prefix_ready) begin
            valid_o[k] = 1'b1;
            req_o[k]   = req_base;
            req_o[k].tgt_addr      = req_base.tgt_addr + (beat_base + k[BurstLenWidth-1:0]);
            // Lane law: the beat index splits into (row, lane) across meta_id and core_id.
            req_o[k].wdata.meta_id = req_base.wdata.meta_id +
                                     ((beat_base + k[BurstLenWidth-1:0]) >> BurstLaneW);
            req_o[k].wdata.core_id = req_base.wdata.core_id +
                                     ((beat_base + k[BurstLenWidth-1:0]) &
                                      BurstLenWidth'(BurstLanes - 1));
            req_o[k].burst_len     = BurstLenWidth'(1);
            if (ready_i[k]) begin
              issue_fire_cnt = issue_fire_cnt + BurstLenWidth'(1);
            end else begin
              issue_prefix_ready = 1'b0;
            end
          end
        end
      end

      if (!active_q) begin
        // One request can always be accepted when no burst is in flight.
        ready_o = 1'b1;
        if (valid_i) begin
          if (remaining > issue_fire_cnt) begin
            req_d    = req_i;
            active_d = 1'b1;
            len_d    = len_i;
            beat_d   = beat_base + issue_fire_cnt;
          end else begin
            active_d = 1'b0;
            beat_d   = '0;
            len_d    = '0;
          end
        end
      end else begin
        ready_o = 1'b0;
        if (issue_fire_cnt != '0) begin
          if (remaining > issue_fire_cnt) begin
            beat_d = beat_base + issue_fire_cnt;
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
  end else begin : gen_dual_ctx
    // ------------------------------------------------------------------
    // Dual-context expander: while context A drains, a second LOAD is accepted
    // into context B; active contexts issue round-robin, one context per cycle
    // (the lane-prefix issue logic is reused unchanged on the selected context).
    // A store/AMO arriving while any context is active waits for full drain,
    // exactly as the legacy expander (no write reordering introduced).
    // ------------------------------------------------------------------
    req_t                     ctx_req_q  [2];
    logic [1:0]               ctx_active_q;
    logic [BurstLenWidth-1:0] ctx_beat_q [2];
    logic [BurstLenWidth-1:0] ctx_len_q  [2];
    req_t                     ctx_req_d  [2];
    logic [1:0]               ctx_active_d;
    logic [BurstLenWidth-1:0] ctx_beat_d [2];
    logic [BurstLenWidth-1:0] ctx_len_d  [2];
    logic                     issue_ctx_q, issue_ctx_d;

    logic                     sel;
    logic                     any_active, both_active;
    logic                     accept_shadow;
    logic                     shadow_idx;
    logic                     resident_is_load;
    logic [BurstLenWidth-1:0] beat_base;
    logic [BurstLenWidth-1:0] len_base;
    logic [BurstLenWidth-1:0] remaining;
    logic [BurstLenWidth-1:0] issue_cnt;
    logic [BurstLenWidth-1:0] issue_fire_cnt;
    logic issue_prefix_ready;
    logic have_req;
    req_t req_base;

    always_comb begin
      ctx_req_d    = ctx_req_q;
      ctx_active_d = ctx_active_q;
      ctx_beat_d   = ctx_beat_q;
      ctx_len_d    = ctx_len_q;
      issue_ctx_d  = issue_ctx_q;

      for (int k = 0; k < IssueWidth; k++) begin
        valid_o[k] = 1'b0;
        req_o[k]   = '0;
      end
      ready_o = 1'b0;

      any_active  = |ctx_active_q;
      both_active = &ctx_active_q;
      // Issuing context: the RR pointer if that context is active, else the other
      // active one (no idle cycle when only one context is active).
      sel = ctx_active_q[issue_ctx_q] ? issue_ctx_q : ~issue_ctx_q;

      // Source of this cycle's beats: the selected active context, or -- when the
      // expander is idle -- the input itself (combinational passthrough, so a lone
      // single/burst-head keeps the legacy zero-cycle path).
      req_base  = any_active ? ctx_req_q[sel]  : req_i;
      len_base  = any_active ? ctx_len_q[sel]  : len_i;
      beat_base = any_active ? ctx_beat_q[sel] : '0;
      have_req  = any_active ? 1'b1 : valid_i;
      remaining = have_req ? (len_base - beat_base) : '0;
      if (remaining > BurstLenWidth'(IssueWidth)) begin
        issue_cnt = BurstLenWidth'(IssueWidth);
      end else begin
        issue_cnt = remaining;
      end

      // Issue contiguous beats only (identical prefix-ready rule as legacy).
      issue_fire_cnt     = '0;
      issue_prefix_ready = 1'b1;
      if (have_req) begin
        for (int k = 0; k < IssueWidth; k++) begin
          if ((k < issue_cnt) && issue_prefix_ready) begin
            valid_o[k] = 1'b1;
            req_o[k]   = req_base;
            req_o[k].tgt_addr      = req_base.tgt_addr + (beat_base + k[BurstLenWidth-1:0]);
            // Lane law: the beat index splits into (row, lane) across meta_id and core_id.
            req_o[k].wdata.meta_id = req_base.wdata.meta_id +
                                     ((beat_base + k[BurstLenWidth-1:0]) >> BurstLaneW);
            req_o[k].wdata.core_id = req_base.wdata.core_id +
                                     ((beat_base + k[BurstLenWidth-1:0]) &
                                      BurstLenWidth'(BurstLanes - 1));
            req_o[k].burst_len     = BurstLenWidth'(1);
            if (ready_i[k]) begin
              issue_fire_cnt = issue_fire_cnt + BurstLenWidth'(1);
            end else begin
              issue_prefix_ready = 1'b0;
            end
          end
        end
      end

      // Context/state update for the issuing side.
      accept_shadow    = 1'b0;
      shadow_idx       = ~sel;
      resident_is_load = 1'b0;
      if (!any_active) begin
        ready_o = 1'b1;
        if (valid_i) begin
          if (remaining > issue_fire_cnt) begin
            ctx_req_d[0]    = req_i;
            ctx_active_d[0] = 1'b1;
            ctx_len_d[0]    = len_i;
            ctx_beat_d[0]   = beat_base + issue_fire_cnt;
            issue_ctx_d     = 1'b0;
          end
        end
      end else begin
        // Advance / retire the selected context.
        if (issue_fire_cnt != '0) begin
          if (remaining > issue_fire_cnt) begin
            ctx_beat_d[sel] = beat_base + issue_fire_cnt;
          end else begin
            ctx_active_d[sel] = 1'b0;
            ctx_beat_d[sel]   = '0;
            ctx_len_d[sel]    = '0;
          end
        end
        // Shadow acceptance: one context busy, the other free, incoming is a LOAD
        // (single or burst), AND the resident context is itself a load. The
        // resident check is required: a stalled single STORE (or AMO) can occupy a
        // context via the idle-path activation exactly as the legacy expander
        // latches a stalled single. Opening a shadow onto it would run a store
        // concurrently with a load from the same in-order input stream, allowing a
        // write to reorder around the load's beats. When the resident is not a
        // load we hold it alone (legacy behavior) until it drains. Two concurrent
        // LOADS never conflict (read-after-read), so their beats may interleave.
        resident_is_load = !ctx_req_q[sel].wen && (ctx_req_q[sel].wdata.amo == '0);
        if (!both_active && valid_i && req_is_load && resident_is_load) begin
          ready_o                 = 1'b1;
          accept_shadow           = 1'b1;
          ctx_req_d[shadow_idx]   = req_i;
          ctx_active_d[shadow_idx] = 1'b1;
          ctx_len_d[shadow_idx]   = len_i;
          ctx_beat_d[shadow_idx]  = '0;
        end
        // Round-robin: hand the next cycle to the other context ONLY after the
        // current context served every beat it offered this cycle
        // (issue_fire_cnt == issue_cnt). The downstream local interconnect has
        // LockIn: once a beat is presented (valid high) its sel/data must stay
        // stable until ready. A stalled beat must therefore be re-presented
        // unchanged next cycle, so we must NOT switch contexts (which would drive
        // the other burst's address onto the same unserved lane). Holding the
        // context re-presents the same beat -- identical to the legacy
        // single-context stall behavior. Switching only after a clean, fully
        // served cycle is safe because every presented beat has completed its
        // handshake, freeing the lanes for the other context's requests.
        if ((issue_fire_cnt == issue_cnt) && ctx_active_d[~sel]) begin
          issue_ctx_d = ~sel;
        end else begin
          issue_ctx_d = sel;
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ctx_req_q    <= '{default: '0};
        ctx_active_q <= '0;
        ctx_beat_q   <= '{default: '0};
        ctx_len_q    <= '{default: '0};
        issue_ctx_q  <= 1'b0;
      end else begin
        ctx_req_q    <= ctx_req_d;
        ctx_active_q <= ctx_active_d;
        ctx_beat_q   <= ctx_beat_d;
        ctx_len_q    <= ctx_len_d;
        issue_ctx_q  <= issue_ctx_d;
      end
    end

`ifndef SYNTHESIS
    // Both contexts occupied implies both hold loads (the shadow-acceptance rule).
    dual_ctx_loads_only: assert property(
      @(posedge clk_i) disable iff (!rst_ni)
        !(&ctx_active_q) ||
        (!ctx_req_q[0].wen && (ctx_req_q[0].wdata.amo == '0) &&
         !ctx_req_q[1].wen && (ctx_req_q[1].wdata.amo == '0)))
      else $fatal(1, "Burst expander: store/AMO in a concurrent context.");

    // An active context's beat pointer stays within its length.
    for (genvar c = 0; c < 2; c++) begin : gen_beat_bound
      ctx_beat_in_range: assert property(
        @(posedge clk_i) disable iff (!rst_ni)
          !ctx_active_q[c] || (ctx_beat_q[c] < ctx_len_q[c]))
        else $fatal(1, "Burst expander: context %0d beat pointer out of range.", c);
    end
`endif

    // pragma translate_off
    // [BEXP] probes (docs/tcdm_burst_interleave_design.md 2.6): quantify the
    // serialization this feature removes. Free-running from reset.
    logic [63:0] exp_wait_while_drain_cnt;   // cycles a valid input sat blocked
    logic [63:0] exp_shadow_accept_cnt;      // second-context acceptances
    logic [63:0] exp_shadow_same_base_cnt;   // ... whose base addr matches the draining burst
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        exp_wait_while_drain_cnt <= '0;
        exp_shadow_accept_cnt    <= '0;
        exp_shadow_same_base_cnt <= '0;
      end else begin
        if (valid_i && !ready_o) begin
          exp_wait_while_drain_cnt <= exp_wait_while_drain_cnt + 64'd1;
        end
        if (accept_shadow) begin
          exp_shadow_accept_cnt <= exp_shadow_accept_cnt + 64'd1;
          if (ctx_active_q[sel] && (req_i.tgt_addr == ctx_req_q[sel].tgt_addr)) begin
            exp_shadow_same_base_cnt <= exp_shadow_same_base_cnt + 64'd1;
          end
        end
      end
    end
    final begin
      if ((exp_shadow_accept_cnt != 0) || (exp_wait_while_drain_cnt != 0)) begin
        $display("[BEXP] %m shadow_accepts=%0d same_base=%0d wait_while_drain_cyc=%0d",
                 exp_shadow_accept_cnt, exp_shadow_same_base_cnt, exp_wait_while_drain_cnt);
      end
    end
    // pragma translate_on
  end

`ifndef SYNTHESIS
  // Each burst must remain inside the selected tile bank stripe.
  burst_load_only: assert property(
    @(posedge clk_i) disable iff (!rst_ni)
      !(valid_i && ready_o && (len_raw_i > 1)) || req_is_load)
    else $warning("Burst expander: non-load burst observed; clamping to single beat.");

  burst_contained: assert property(
    @(posedge clk_i) disable iff (!rst_ni)
      !(valid_i && ready_o && req_is_load && (len_raw_i > 1)) || burst_contained_i)
    else $fatal(1, "Burst expander: burst crosses tile boundary or exceeds maximum length.");
`endif

endmodule
