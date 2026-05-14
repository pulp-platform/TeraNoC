// ============================================================================
// tb_noc_bottleneck_profiling.svh -- Per-stage stall/utilization profiling
// Include inside mempool_tb module (after tb_noc_link_profiling.svh).
//
// Three-state classification per tile-port per cycle:
//   handshake (valid & ready) / stall (valid & !ready) / idle (!valid)
//
// CORRECTNESS NOTE:
//   Previous versions used NBA (<=) increments inside a nested for-loop,
//   which violates SystemVerilog semantics (multiple NBA writes to the
//   same variable in one cycle collapse to a single +1, not +N).
//   This file uses BLOCKING accumulation into a per-cycle temporary,
//   committed once via NBA at the end. This gives true tile-port x cycle
//   counts.
//
// Counters implemented:
//   * 8 pipeline stages, group-aggregate (summed across all tile-ports):
//       REQ_TILE_OUT, REQ_MSHR_IN, REQ_MSHR_OUT, REQ_SLAVE_IN,
//       RESP_SLAVE_OUT, RESP_MSHR_IN, RESP_MSHR_OUT, RESP_TILE_BACK
//   * Bank contention (per group per tile, aggregated over 16 banks/tile):
//       BANK_REQ  (superbank_req_valid & ~ready)
//       BANK_RESP (superbank_resp_valid & ~ready)
//
// Output: [BP] CSV lines prefixed per delta/final period.
// ============================================================================

`ifndef TB_NOC_BOTTLENECK_PROFILING_SVH
`define TB_NOC_BOTTLENECK_PROFILING_SVH

`ifndef BP_PROFILE_PERIOD
`define BP_PROFILE_PERIOD 1000
`endif

// pragma translate_off
`ifndef VERILATOR

// ------------ Stage definitions ----------------
localparam int BP_REQ_TILE_OUT    = 0;
localparam int BP_REQ_MSHR_IN     = 1;
localparam int BP_REQ_MSHR_OUT    = 2;
localparam int BP_REQ_SLAVE_IN    = 3;
localparam int BP_RESP_SLAVE_OUT  = 4;
localparam int BP_RESP_MSHR_IN    = 5;
localparam int BP_RESP_MSHR_OUT   = 6;
localparam int BP_RESP_TILE_BACK  = 7;
localparam int BP_NUM_STAGES      = 8;

string bp_stage_names [BP_NUM_STAGES] = '{
  "REQ_TILE_OUT", "REQ_MSHR_IN", "REQ_MSHR_OUT", "REQ_SLAVE_IN",
  "RESP_SLAVE_OUT", "RESP_MSHR_IN", "RESP_MSHR_OUT", "RESP_TILE_BACK"
};

localparam int BP_NReq  = NumRemoteReqPortsPerTile - 1;
localparam int BP_NResp = NumRemoteRespPortsPerTile - 1;
localparam int BP_NPortsPerStage [BP_NUM_STAGES] = '{
  BP_NReq, BP_NReq, BP_NReq, BP_NReq,
  BP_NResp, BP_NResp, BP_NResp, BP_NResp
};
localparam int BP_NBanks = NumBanksPerTile;

// ------------ Wire arrays tapping XMR signals ----------------
// [group][tile][port]
logic bp_v [BP_NUM_STAGES][NumGroups][NumTilesPerGroup][BP_NReq > BP_NResp ? BP_NReq : BP_NResp];
logic bp_r [BP_NUM_STAGES][NumGroups][NumTilesPerGroup][BP_NReq > BP_NResp ? BP_NReq : BP_NResp];

// Bank-level: taps the whole superbank_req/resp buses (one per tile)
logic [BP_NBanks-1:0] bp_sb_req_v  [NumGroups][NumTilesPerGroup];
logic [BP_NBanks-1:0] bp_sb_req_r  [NumGroups][NumTilesPerGroup];
logic [BP_NBanks-1:0] bp_sb_resp_v [NumGroups][NumTilesPerGroup];
logic [BP_NBanks-1:0] bp_sb_resp_r [NumGroups][NumTilesPerGroup];

// ------------ Generate: connect wires to RTL signals ----------------
generate
  for (genvar g = 0; g < NumGroups; g++) begin : gen_bp_tap_g
    localparam int gx = g / NumY;
    localparam int gy = g % NumY;
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_bp_tap_t

      // ---- Request-side stages (BP_NReq ports) ----
      for (genvar p = 0; p < BP_NReq; p++) begin : gen_bp_tap_req
        // REQ_TILE_OUT
        assign bp_v[BP_REQ_TILE_OUT][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_valid_o[p+1];
        assign bp_r[BP_REQ_TILE_OUT][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_ready_i[p+1];

        // REQ_MSHR_IN (tile -> mshr)
        assign bp_v[BP_REQ_MSHR_IN][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_group_mshr.i_group_mshr
          .group_mshr_req_valid_i[t][p+1];
        assign bp_r[BP_REQ_MSHR_IN][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_group_mshr.i_group_mshr
          .group_mshr_req_ready_o[t][p+1];

        // REQ_MSHR_OUT (mshr -> noc)
        assign bp_v[BP_REQ_MSHR_OUT][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_group_mshr.i_group_mshr
          .mshr_noc_req_valid_o[t][p+1];
        assign bp_r[BP_REQ_MSHR_OUT][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_group_mshr.i_group_mshr
          .mshr_noc_req_ready_i[t][p+1];

        // REQ_SLAVE_IN (remote req arriving at destination tile)
        assign bp_v[BP_REQ_SLAVE_IN][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_valid_i[p+1];
        assign bp_r[BP_REQ_SLAVE_IN][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_ready_o[p+1];
      end

      // ---- Response-side stages (BP_NResp ports) ----
      for (genvar p = 0; p < BP_NResp; p++) begin : gen_bp_tap_resp
        // RESP_SLAVE_OUT (dest tile -> noc)
        assign bp_v[BP_RESP_SLAVE_OUT][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_resp_valid_o[p+1];
        assign bp_r[BP_RESP_SLAVE_OUT][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_resp_ready_i[p+1];

        // RESP_MSHR_IN (noc -> mshr)
        assign bp_v[BP_RESP_MSHR_IN][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_group_mshr.i_group_mshr
          .mshr_noc_resp_valid_i[t][p+1];
        assign bp_r[BP_RESP_MSHR_IN][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_group_mshr.i_group_mshr
          .mshr_noc_resp_ready_o[t][p+1];

        // RESP_MSHR_OUT (mshr -> tile)
        assign bp_v[BP_RESP_MSHR_OUT][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_group_mshr.i_group_mshr
          .group_mshr_resp_valid_o[t][p+1];
        assign bp_r[BP_RESP_MSHR_OUT][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_group_mshr.i_group_mshr
          .group_mshr_resp_ready_i[t][p+1];

        // RESP_TILE_BACK (resp delivered back to source tile's core)
        assign bp_v[BP_RESP_TILE_BACK][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_tiles[t].i_tile.tcdm_master_resp_valid_i[p+1];
        assign bp_r[BP_RESP_TILE_BACK][g][t][p] = dut.i_mempool_cluster
          .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
          .i_mempool_group.gen_tiles[t].i_tile.tcdm_master_resp_ready_o[p+1];
      end

      // ---- Bank-level aggregates (whole bus per tile) ----
      assign bp_sb_req_v[g][t] = dut.i_mempool_cluster
        .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
        .i_mempool_group.gen_tiles[t].i_tile.superbank_req_valid;
      assign bp_sb_req_r[g][t] = dut.i_mempool_cluster
        .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
        .i_mempool_group.gen_tiles[t].i_tile.superbank_req_ready;
      assign bp_sb_resp_v[g][t] = dut.i_mempool_cluster
        .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
        .i_mempool_group.gen_tiles[t].i_tile.superbank_resp_valid;
      assign bp_sb_resp_r[g][t] = dut.i_mempool_cluster
        .gen_groups_x[gx].gen_groups_y[gy].gen_rtl_group.i_group
        .i_mempool_group.gen_tiles[t].i_tile.superbank_resp_ready;
    end
  end
endgenerate

// ------------ Counters ----------------
// Per-group per-stage aggregate
longint unsigned bp_hsk       [NumGroups][BP_NUM_STAGES];
longint unsigned bp_stall     [NumGroups][BP_NUM_STAGES];
longint unsigned bp_idle      [NumGroups][BP_NUM_STAGES];
longint unsigned bp_hsk_prev  [NumGroups][BP_NUM_STAGES];
longint unsigned bp_stall_prev[NumGroups][BP_NUM_STAGES];
longint unsigned bp_idle_prev [NumGroups][BP_NUM_STAGES];

// Bank-level (per group per tile, aggregated over 16 banks in that tile)
longint unsigned bp_bank_req_hsk   [NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_req_stall [NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_req_idle  [NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_resp_hsk  [NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_resp_stall[NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_resp_idle [NumGroups][NumTilesPerGroup];

longint unsigned bp_bank_req_hsk_prev   [NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_req_stall_prev [NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_req_idle_prev  [NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_resp_hsk_prev  [NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_resp_stall_prev[NumGroups][NumTilesPerGroup];
longint unsigned bp_bank_resp_idle_prev [NumGroups][NumTilesPerGroup];

int unsigned bp_cycle;
int unsigned bp_active_cycles;       // # cycles with bp_benchmark_active=1
int unsigned bp_active_cycles_prev;
logic        bp_benchmark_active;

assign bp_benchmark_active = csr_trace_any_global;

// ------------ Counting logic ----------------
// One always per group. Inside, use BLOCKING accumulation into per-cycle
// temporaries, then commit to counters via NBA once.
// This gives true tile-port x cycle counts (not "any tile-port this cycle").
// Using plain `always @(posedge clk)` (not always_ff) because:
//   - each per-group block drives disjoint indices of shared arrays
//   - always_ff's strict single-driver-per-variable check would flag this
generate
  for (genvar g = 0; g < NumGroups; g++) begin : gen_bp_cnt_g
    always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        for (int s = 0; s < BP_NUM_STAGES; s++) begin
          bp_hsk[g][s]   <= 0;
          bp_stall[g][s] <= 0;
          bp_idle[g][s]  <= 0;
        end
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          bp_bank_req_hsk[g][t]    <= 0;
          bp_bank_req_stall[g][t]  <= 0;
          bp_bank_req_idle[g][t]   <= 0;
          bp_bank_resp_hsk[g][t]   <= 0;
          bp_bank_resp_stall[g][t] <= 0;
          bp_bank_resp_idle[g][t]  <= 0;
        end
      end else if (bp_benchmark_active) begin
        // --- Per-stage pipeline counters ---
        for (int s = 0; s < BP_NUM_STAGES; s++) begin
          automatic int unsigned h = 0;
          automatic int unsigned st = 0;
          automatic int unsigned id = 0;
          automatic int n_ports = (s <= BP_REQ_SLAVE_IN) ? BP_NReq : BP_NResp;
          for (int t = 0; t < NumTilesPerGroup; t++) begin
            for (int p = 0; p < n_ports; p++) begin
              if (bp_v[s][g][t][p] && bp_r[s][g][t][p])       h  = h  + 1;
              else if (bp_v[s][g][t][p])                       st = st + 1;
              else                                             id = id + 1;
            end
          end
          bp_hsk[g][s]   <= bp_hsk[g][s]   + h;
          bp_stall[g][s] <= bp_stall[g][s] + st;
          bp_idle[g][s]  <= bp_idle[g][s]  + id;
        end
        // --- Bank-level contention (per tile, aggregated over banks) ---
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          automatic int unsigned bh_req = 0, bs_req = 0, bi_req = 0;
          automatic int unsigned bh_rsp = 0, bs_rsp = 0, bi_rsp = 0;
          for (int b = 0; b < BP_NBanks; b++) begin
            // Request side: superbank_req_valid vs ready
            if (bp_sb_req_v[g][t][b] && bp_sb_req_r[g][t][b])  bh_req = bh_req + 1;
            else if (bp_sb_req_v[g][t][b])                      bs_req = bs_req + 1;
            else                                                bi_req = bi_req + 1;
            // Response side: superbank_resp_valid vs ready
            if (bp_sb_resp_v[g][t][b] && bp_sb_resp_r[g][t][b]) bh_rsp = bh_rsp + 1;
            else if (bp_sb_resp_v[g][t][b])                     bs_rsp = bs_rsp + 1;
            else                                                bi_rsp = bi_rsp + 1;
          end
          bp_bank_req_hsk[g][t]    <= bp_bank_req_hsk[g][t]    + bh_req;
          bp_bank_req_stall[g][t]  <= bp_bank_req_stall[g][t]  + bs_req;
          bp_bank_req_idle[g][t]   <= bp_bank_req_idle[g][t]   + bi_req;
          bp_bank_resp_hsk[g][t]   <= bp_bank_resp_hsk[g][t]   + bh_rsp;
          bp_bank_resp_stall[g][t] <= bp_bank_resp_stall[g][t] + bs_rsp;
          bp_bank_resp_idle[g][t]  <= bp_bank_resp_idle[g][t]  + bi_rsp;
        end
      end
    end
  end
endgenerate

// ------------ Initialize snapshot vars and cycle counters ----------------
initial begin
  for (int g = 0; g < NumGroups; g++) begin
    for (int s = 0; s < BP_NUM_STAGES; s++) begin
      bp_hsk_prev[g][s]=0; bp_stall_prev[g][s]=0; bp_idle_prev[g][s]=0;
    end
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      bp_bank_req_hsk_prev[g][t]=0; bp_bank_req_stall_prev[g][t]=0; bp_bank_req_idle_prev[g][t]=0;
      bp_bank_resp_hsk_prev[g][t]=0; bp_bank_resp_stall_prev[g][t]=0; bp_bank_resp_idle_prev[g][t]=0;
    end
  end
  bp_active_cycles_prev = 0;
end

// ------------ Cycle counters ----------------
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    bp_cycle         <= 0;
    bp_active_cycles <= 0;
  end else begin
    bp_cycle <= bp_cycle + 1;
    if (bp_benchmark_active) bp_active_cycles <= bp_active_cycles + 1;
  end
end

// ------------ Delta print ----------------
task automatic bp_print_delta(input string tag);
  automatic longint unsigned d_act;
  d_act = bp_active_cycles - bp_active_cycles_prev;
  // Stage stats: util/stall_rate are normalized by (d_act * n_ports)
  for (int g = 0; g < NumGroups; g++) begin
    for (int s = 0; s < BP_NUM_STAGES; s++) begin
      automatic longint unsigned d_hsk   = bp_hsk[g][s]   - bp_hsk_prev[g][s];
      automatic longint unsigned d_stall = bp_stall[g][s] - bp_stall_prev[g][s];
      automatic longint unsigned d_idle  = bp_idle[g][s]  - bp_idle_prev[g][s];
      automatic longint unsigned d_total = d_hsk + d_stall + d_idle;
      automatic longint unsigned d_offer = d_hsk + d_stall;
      $display("[BP] %s,kind=stage,cyc=%0d,active_cyc=%0d,g=%0d,s=%s,hsk=%0d,stall=%0d,idle=%0d,total=%0d,util=%.4f,stall_rate=%.4f,offered=%.4f",
        tag, bp_cycle, d_act, g, bp_stage_names[s],
        d_hsk, d_stall, d_idle, d_total,
        d_total > 0 ? real'(d_hsk)   / real'(d_total) : 0.0,
        d_offer > 0 ? real'(d_stall) / real'(d_offer) : 0.0,
        d_total > 0 ? real'(d_offer) / real'(d_total) : 0.0);
    end
  end
  // Bank-level stats: per tile
  for (int g = 0; g < NumGroups; g++) begin
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      automatic longint unsigned d_bh_req = bp_bank_req_hsk[g][t]    - bp_bank_req_hsk_prev[g][t];
      automatic longint unsigned d_bs_req = bp_bank_req_stall[g][t]  - bp_bank_req_stall_prev[g][t];
      automatic longint unsigned d_bi_req = bp_bank_req_idle[g][t]   - bp_bank_req_idle_prev[g][t];
      automatic longint unsigned d_bh_rsp = bp_bank_resp_hsk[g][t]   - bp_bank_resp_hsk_prev[g][t];
      automatic longint unsigned d_bs_rsp = bp_bank_resp_stall[g][t] - bp_bank_resp_stall_prev[g][t];
      automatic longint unsigned d_bi_rsp = bp_bank_resp_idle[g][t]  - bp_bank_resp_idle_prev[g][t];
      automatic longint unsigned d_tot_req = d_bh_req + d_bs_req + d_bi_req;
      automatic longint unsigned d_tot_rsp = d_bh_rsp + d_bs_rsp + d_bi_rsp;
      automatic longint unsigned d_of_req  = d_bh_req + d_bs_req;
      automatic longint unsigned d_of_rsp  = d_bh_rsp + d_bs_rsp;
      $display("[BP] %s,kind=bank_req,cyc=%0d,active_cyc=%0d,g=%0d,t=%0d,hsk=%0d,stall=%0d,idle=%0d,util=%.4f,stall_rate=%.4f,offered=%.4f",
        tag, bp_cycle, d_act, g, t,
        d_bh_req, d_bs_req, d_bi_req,
        d_tot_req > 0 ? real'(d_bh_req) / real'(d_tot_req) : 0.0,
        d_of_req  > 0 ? real'(d_bs_req) / real'(d_of_req)  : 0.0,
        d_tot_req > 0 ? real'(d_of_req) / real'(d_tot_req) : 0.0);
      $display("[BP] %s,kind=bank_resp,cyc=%0d,active_cyc=%0d,g=%0d,t=%0d,hsk=%0d,stall=%0d,idle=%0d,util=%.4f,stall_rate=%.4f,offered=%.4f",
        tag, bp_cycle, d_act, g, t,
        d_bh_rsp, d_bs_rsp, d_bi_rsp,
        d_tot_rsp > 0 ? real'(d_bh_rsp) / real'(d_tot_rsp) : 0.0,
        d_of_rsp  > 0 ? real'(d_bs_rsp) / real'(d_of_rsp)  : 0.0,
        d_tot_rsp > 0 ? real'(d_of_rsp) / real'(d_tot_rsp) : 0.0);
    end
  end
  // Save snapshots
  for (int g = 0; g < NumGroups; g++) begin
    for (int s = 0; s < BP_NUM_STAGES; s++) begin
      bp_hsk_prev[g][s]   = bp_hsk[g][s];
      bp_stall_prev[g][s] = bp_stall[g][s];
      bp_idle_prev[g][s]  = bp_idle[g][s];
    end
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      bp_bank_req_hsk_prev[g][t]    = bp_bank_req_hsk[g][t];
      bp_bank_req_stall_prev[g][t]  = bp_bank_req_stall[g][t];
      bp_bank_req_idle_prev[g][t]   = bp_bank_req_idle[g][t];
      bp_bank_resp_hsk_prev[g][t]   = bp_bank_resp_hsk[g][t];
      bp_bank_resp_stall_prev[g][t] = bp_bank_resp_stall[g][t];
      bp_bank_resp_idle_prev[g][t]  = bp_bank_resp_idle[g][t];
    end
  end
  bp_active_cycles_prev = bp_active_cycles;
endtask

always @(posedge clk) begin
  if (`BP_PROFILE_PERIOD > 0 && bp_cycle > 0 &&
      (bp_cycle % `BP_PROFILE_PERIOD) == 0 && bp_benchmark_active)
    bp_print_delta("delta");
end

final begin
  bp_print_delta("final");
end

`endif // VERILATOR
// pragma translate_on
`endif // TB_NOC_BOTTLENECK_PROFILING_SVH
