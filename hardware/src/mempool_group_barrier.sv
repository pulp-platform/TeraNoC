// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
// mempool_group_barrier  (general-purpose, memory-mapped rendezvous unit)
// =======================================================================
// A bank of NumBarriers independent, SW-configured barrier STRUCTS, exposed as a
// memory-mapped TCDM slave (one extra output port of the group local interconnect;
// the requesting core, target struct and operation are decoded by the instantiator
// from the request address + write-enable). Each struct holds:
//   * target_q  : SW-written target arrival count        (memory-mapped)
//   * resp_mask_q: SW-written participant/respond bitmask (memory-mapped)
//   * count_q   : HW arrival counter
//   * a per-struct watchdog (force-release safety net)
//
// Operation (per struct s):
//   - SW config (WRITE): one core writes target_q[s] and resp_mask[s] ONCE at
//     setup; both persist and are reused every iteration. A config write is
//     ACKed (the requesting core's store must get a response to free its LSU id).
//   - ARRIVE (LOAD): each participating core issues a load mapped to struct s ->
//     count_q[s]++ and the load response is WITHHELD. When count_q[s]==target_q[s]
//     the unit fires the held responses to every core in resp_mask[s] (one per
//     cycle), then resets count_q[s]=0 and waits for the next iteration.
//   - The held LOAD response IS the release: the arriving core does `lw; ...; fence`
//     and the fence falls through when its response returns. Reuses the TCDM
//     req/resp datapath (no WFI/wake path); the meta_id echo (LSU match) and the
//     LIC resp routing (by ini_addr) are handled by the mempool_group adapter.
//
// This keeps the HW simple (counters + masks, no hardwired pairing) and flexible
// (any group size/composition, many concurrent barriers) at low SW cost (set up
// target+mask once, then just load the struct's address).

module mempool_group_barrier #(
  parameter int unsigned NumCoresPerGroup = 16,
  parameter int unsigned NumBarriers      = 16,
  // 0 = NO watchdog: a barrier waits indefinitely until all `target` cores arrive (the intended
  // rendezvous semantics). Any W > 0 force-releases after W cycles measured from the FIRST arrival,
  // which does NOT synchronize -- it releases the arrived subset and leaves the stragglers a round
  // behind, so every later barrier times out too (measured 2026-07-30: a >1024-cycle inter-lane
  // skew turned every group barrier into a 1024-cycle penalty that synchronized nothing). Use W > 0
  // only as a deadlock escape while debugging, never as the normal mode.
  parameter int unsigned WatchdogLimit    = 0,
  // Derived (do not override)
  parameter int unsigned IniW    = $clog2(NumCoresPerGroup),
  parameter int unsigned StructW = (NumBarriers > 1) ? $clog2(NumBarriers) : 1,
  parameter int unsigned CntW    = $clog2(NumCoresPerGroup + 1),
  parameter int unsigned WdW     = (WatchdogLimit > 0) ? $clog2(WatchdogLimit + 1) : 1
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  // Request (from the LIC barrier port, decoded by the mempool_group adapter).
  input  logic                        req_valid_i,
  input  logic [IniW-1:0]             req_ini_addr_i,   // requesting core (= tile, 1 core/tile)
  input  logic [1:0]                  req_op_i,         // OP_ARRIVE / OP_WR_TARGET / OP_WR_MASK
  input  logic [StructW-1:0]          req_struct_i,     // which barrier struct
  input  logic [NumCoresPerGroup-1:0] req_cfg_data_i,   // config value (target: low CntW bits; mask: all)
  output logic                        req_ready_o,
  // Response: ARRIVE release (resp_wen=0) or config-write ACK (resp_wen=1). The
  // adapter supplies the rdata payload (echoed meta_id) routed by resp_ini_addr.
  output logic                        resp_valid_o,
  output logic [IniW-1:0]             resp_ini_addr_o,
  output logic                        resp_wen_o,
  input  logic                        resp_ready_i,
  // Stats: sticky per-struct watchdog-fired flag (expected 0 on a correct run).
  output logic [NumBarriers-1:0]      wd_fire_o
);

  localparam logic [1:0] OP_ARRIVE    = 2'd0;
  localparam logic [1:0] OP_WR_TARGET = 2'd1;
  localparam logic [1:0] OP_WR_MASK   = 2'd2;

  // ---- registered state ------------------------------------------------------
  logic [NumBarriers-1:0][CntW-1:0]             target_q,  target_d;    // SW-set, persists
  logic [NumBarriers-1:0][NumCoresPerGroup-1:0] mask_q,    mask_d;      // SW-set, persists
  logic [NumBarriers-1:0][CntW-1:0]             count_q,   count_d;     // HW arrival count
  logic [NumBarriers-1:0][WdW-1:0]              wd_q,      wd_d;        // per-struct watchdog
  logic [NumBarriers-1:0]                        wd_fire_q, wd_fire_d;
  logic                                          releasing_q, releasing_d;
  logic [StructW-1:0]                            rel_struct_q, rel_struct_d;
  logic [NumCoresPerGroup-1:0]                  rel_rem_q, rel_rem_d;   // responders still to release
  // Per-struct set of cores that have actually ARRIVED this round (one bit per core, set by
  // OP_ARRIVE, cleared when the struct's release completes). The release set is taken from THIS,
  // never from mask_q: on a watchdog force-release only count_q < target_q cores have arrived, and
  // releasing the configured mask would fire a held-load response at a core that never issued one
  // -- a phantom response its LSU has no metadata for (observed 2026-07-30: struct 8 force-fired
  // with count=15/target=16, the mask walk hit the non-arrived core and tripped
  // snitch_lsu invalid_resp_id). arrived_q == mask_q on every normal (ready) release, so this is
  // behaviourally identical there; it only changes the force-release path.
  logic [NumBarriers-1:0][NumCoresPerGroup-1:0]  arrived_q, arrived_d;
  logic                                          ack_pend_q, ack_pend_d; // config-write ack pending
  logic [IniW-1:0]                              ack_ini_q,  ack_ini_d;

  // ---- combinational ---------------------------------------------------------
  logic [NumBarriers-1:0] ready;       // count == target (>0)
  logic [NumBarriers-1:0] force_rel;   // watchdog expired
  logic [NumBarriers-1:0] ready_other; // ready|force, excluding the releasing struct
  logic                   pick_valid;
  logic [StructW-1:0]     pick_struct;
  logic [IniW-1:0]        rel_target;
  logic                   rel_have;
  logic                   ack_fire, rel_fire;

  always_comb begin
    target_d    = target_q;
    mask_d      = mask_q;
    count_d     = count_q;
    wd_d        = wd_q;
    wd_fire_d   = wd_fire_q;
    releasing_d = releasing_q;
    rel_struct_d= rel_struct_q;
    rel_rem_d   = rel_rem_q;
    arrived_d   = arrived_q;
    ack_pend_d  = ack_pend_q;
    ack_ini_d   = ack_ini_q;

    // accept a request unless an ack is still pending (throttles back-to-back
    // config writes; arrives don't overlap setup so they are never throttled).
    req_ready_o = !ack_pend_q;

    // per-struct ready / watchdog
    for (int unsigned s = 0; s < NumBarriers; s++) begin
      ready[s]     = (count_q[s] == target_q[s]) && (target_q[s] != '0);
      if (WatchdogLimit > 0) begin
        wd_d[s]      = (count_q[s] == '0) ? WdW'(WatchdogLimit)
                       : (wd_q[s] != '0)  ? (wd_q[s] - 1'b1) : '0;
        force_rel[s] = (count_q[s] != '0) && (wd_q[s] == '0) && !ready[s];
      end else begin
        wd_d[s]      = '0;
        force_rel[s] = 1'b0;
      end
      ready_other[s] = (ready[s] || force_rel[s]) && !(releasing_q && (rel_struct_q == StructW'(s)));
    end

    // request handling (accepted this cycle)
    if (req_valid_i && req_ready_o) begin
      unique case (req_op_i)
        OP_WR_TARGET: begin
          target_d[req_struct_i] = req_cfg_data_i[CntW-1:0];
          ack_pend_d = 1'b1; ack_ini_d = req_ini_addr_i;
        end
        OP_WR_MASK: begin
          mask_d[req_struct_i] = req_cfg_data_i;
          ack_pend_d = 1'b1; ack_ini_d = req_ini_addr_i;
        end
        default: begin // OP_ARRIVE
          count_d[req_struct_i] = count_q[req_struct_i] + 1'b1;
          arrived_d[req_struct_i][req_ini_addr_i] = 1'b1;  // this core is now releasable
        end
      endcase
    end

    // pick a releasable struct (lowest index, not the one already releasing)
    pick_valid = 1'b0; pick_struct = '0;
    for (int unsigned s = 0; s < NumBarriers; s++)
      if (!pick_valid && ready_other[s]) begin pick_valid = 1'b1; pick_struct = StructW'(s); end

    // release datapath: lowest set responder of the releasing struct
    rel_have = 1'b0; rel_target = '0;
    for (int unsigned c = 0; c < NumCoresPerGroup; c++)
      if (!rel_have && rel_rem_q[c]) begin rel_have = 1'b1; rel_target = IniW'(c); end

    // response: config-write ACK has priority over a release (acks are rare/setup)
    resp_valid_o    = ack_pend_q || (releasing_q && rel_have);
    resp_wen_o      = ack_pend_q;                       // 1 = write ack, 0 = read release
    resp_ini_addr_o = ack_pend_q ? ack_ini_q : rel_target;

    ack_fire = ack_pend_q && resp_ready_i;
    rel_fire = !ack_pend_q && releasing_q && rel_have && resp_ready_i;
    if (ack_fire) ack_pend_d = 1'b0;
    if (rel_fire) rel_rem_d[rel_target] = 1'b0;

    // next-state of the release FSM
    if (releasing_q && (rel_rem_d != '0)) begin
      releasing_d = 1'b1; rel_struct_d = rel_struct_q;  // keep draining
    end else begin
      if (releasing_q) begin
        count_d[rel_struct_q]   = '0;                   // finished -> reset counter (target/mask persist)
        arrived_d[rel_struct_q] = '0;                   // ... and the arrival set for the next round
      end
      if (pick_valid) begin
        releasing_d  = 1'b1;
        rel_struct_d = pick_struct;
        // Release exactly the cores that arrived. arrived_d (not _q) so a core arriving in this
        // very cycle is included -- otherwise it would wait out another full watchdog window.
        // pick_struct != rel_struct_q (ready_other excludes the releasing struct), so the clear
        // above can never clobber the set being loaded here.
        rel_rem_d    = arrived_d[pick_struct];
        if (force_rel[pick_struct]) wd_fire_d[pick_struct] = 1'b1;
      end else begin
        releasing_d = 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      target_q <= '0; mask_q <= '0; count_q <= '0;
      wd_q <= {NumBarriers{WdW'(WatchdogLimit)}}; wd_fire_q <= '0;
      releasing_q <= 1'b0; rel_struct_q <= '0; rel_rem_q <= '0; arrived_q <= '0;
      ack_pend_q <= 1'b0; ack_ini_q <= '0;
    end else begin
      target_q <= target_d; mask_q <= mask_d; count_q <= count_d;
      wd_q <= wd_d; wd_fire_q <= wd_fire_d;
      releasing_q <= releasing_d; rel_struct_q <= rel_struct_d; rel_rem_q <= rel_rem_d;
      arrived_q <= arrived_d;
      ack_pend_q <= ack_pend_d; ack_ini_q <= ack_ini_d;
    end
  end

  assign wd_fire_o = wd_fire_q;

  // pragma translate_off
  // No declaration initializers: a `= 0` on a variable that an always_ff also writes is a
  // second procedural driver. QuestaSim tolerates it, VCS rejects it (ICPD_INIT), and the
  // LRM is on VCS's side. Reset in the always_ff instead, which is also what makes the
  // counters restart correctly across a reset rather than only at time 0.
  int unsigned dbg_arrive_cnt, dbg_release_cnt, dbg_wd_cnt;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      dbg_arrive_cnt <= 0; dbg_release_cnt <= 0; dbg_wd_cnt <= 0;
    end
    if (rst_ni && req_valid_i && req_ready_o && req_op_i == OP_ARRIVE) dbg_arrive_cnt  <= dbg_arrive_cnt + 1;
    if (rst_ni && rel_fire)                                            dbg_release_cnt <= dbg_release_cnt + 1;
    // A watchdog fire means this barrier did NOT synchronize: it timed out and released only the
    // cores that had arrived. Never silent -- the skew it reports is the actionable number (the
    // 2026-07-30 GBAR_PLOOP failure was a first-barrier skew > WatchdogLimit).
    if (rst_ni) begin
      for (int unsigned s = 0; s < NumBarriers; s++) begin
        if (!releasing_q && force_rel[s] && (pick_valid && (pick_struct == StructW'(s)))) begin
          dbg_wd_cnt <= dbg_wd_cnt + 1;
          $display("[GBAR WD] %m t=%0t struct=%0d TIMEOUT: arrived=%0d/%0d arrived_set=%b mask=%b -- releasing arrived only",
                   $time, s, count_q[s], target_q[s], arrived_q[s], mask_q[s]);
        end
      end
    end
  end
  // A core may only be released if it arrived; the configured mask must cover the arrival set.
  // A violation means SW mis-sized target/mask for the participating set.
  for (genvar s = 0; s < NumBarriers; s++) begin : gen_gbar_mask_chk
    arrived_subset_of_mask: assert property (
      @(posedge clk_i) disable iff (!rst_ni)
        (mask_q[s] == '0) || ((arrived_q[s] & ~mask_q[s]) == '0))
      else $error("[GBAR] %m struct %0d: core arrived outside resp_mask (arrived=%b mask=%b)",
                  s, arrived_q[s], mask_q[s]);
  end
  final $display("[GBAR] %m arrives=%0d releases=%0d wd_timeouts=%0d wd_fire=%b",
                 dbg_arrive_cnt, dbg_release_cnt, dbg_wd_cnt, wd_fire_q);
  // pragma translate_on

endmodule
