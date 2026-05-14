// ============================================================================
// tb_noc_link_profiling.svh — NoC link utilization profiling (per-period delta)
// Include inside mempool_tb module.
// ============================================================================

`ifndef TB_NOC_LINK_PROFILING_SVH
`define TB_NOC_LINK_PROFILING_SVH

`ifndef NOC_LINK_PROFILE_PERIOD
`define NOC_LINK_PROFILE_PERIOD 1000
`endif

// pragma translate_off
`ifndef VERILATOR

localparam int LP_NumReqPorts  = NumRemoteReqPortsPerTile - 1;
localparam int LP_NumRespPorts = NumRemoteRespPortsPerTile - 1;

// Per-group, per-tile, per-port: cumulative and previous-snapshot counters
int unsigned lp_req_hsk   [NumGroups][NumTilesPerGroup][LP_NumReqPorts];
int unsigned lp_resp_hsk  [NumGroups][NumTilesPerGroup][LP_NumRespPorts];
int unsigned lp_sreq_hsk  [NumGroups][NumTilesPerGroup][LP_NumReqPorts];
int unsigned lp_sresp_hsk [NumGroups][NumTilesPerGroup][LP_NumRespPorts];

// Previous snapshot (for delta computation)
int unsigned lp_req_prev   [NumGroups][NumTilesPerGroup][LP_NumReqPorts];
int unsigned lp_resp_prev  [NumGroups][NumTilesPerGroup][LP_NumRespPorts];
int unsigned lp_sreq_prev  [NumGroups][NumTilesPerGroup][LP_NumReqPorts];
int unsigned lp_sresp_prev [NumGroups][NumTilesPerGroup][LP_NumRespPorts];

int unsigned lp_cycle;
logic        lp_benchmark_active;

// Sample counters
generate
  for (genvar g = 0; g < NumGroups; g++) begin : gen_lp_g
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_lp_t
      for (genvar p = 0; p < LP_NumReqPorts; p++) begin : gen_lp_rq
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) lp_req_hsk[g][t][p] <= 0;
          else if (dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                   .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile
                   .tcdm_master_req_valid_o[p+1] &&
                   dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                   .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile
                   .tcdm_master_req_ready_i[p+1])
            lp_req_hsk[g][t][p] <= lp_req_hsk[g][t][p] + 1;
        end
      end
      for (genvar p = 0; p < LP_NumRespPorts; p++) begin : gen_lp_rp
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) lp_resp_hsk[g][t][p] <= 0;
          else if (dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                   .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile
                   .tcdm_master_resp_valid_i[p+1] &&
                   dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                   .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile
                   .tcdm_master_resp_ready_o[p+1])
            lp_resp_hsk[g][t][p] <= lp_resp_hsk[g][t][p] + 1;
        end
      end
      for (genvar p = 0; p < LP_NumReqPorts; p++) begin : gen_lp_sq
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) lp_sreq_hsk[g][t][p] <= 0;
          else if (dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                   .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile
                   .tcdm_slave_req_valid_i[p+1] &&
                   dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                   .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile
                   .tcdm_slave_req_ready_o[p+1])
            lp_sreq_hsk[g][t][p] <= lp_sreq_hsk[g][t][p] + 1;
        end
      end
      for (genvar p = 0; p < LP_NumRespPorts; p++) begin : gen_lp_sp
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) lp_sresp_hsk[g][t][p] <= 0;
          else if (dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                   .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile
                   .tcdm_slave_resp_valid_o[p+1] &&
                   dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                   .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile
                   .tcdm_slave_resp_ready_i[p+1])
            lp_sresp_hsk[g][t][p] <= lp_sresp_hsk[g][t][p] + 1;
        end
      end
    end
  end
endgenerate

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) lp_cycle <= 0;
  else        lp_cycle <= lp_cycle + 1;
end

assign lp_benchmark_active = csr_trace_any_global;

// Print delta (current - previous snapshot) for a period
task automatic lp_print_delta(input string tag);
  int unsigned d_req[2], d_resp[2], d_sreq[2], d_sresp[2];
  int unsigned total;
  for (int i = 0; i < 2; i++) begin
    d_req[i]=0; d_resp[i]=0; d_sreq[i]=0; d_sresp[i]=0;
  end

  for (int g = 0; g < NumGroups; g++)
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int p = 0; p < LP_NumReqPorts && p < 2; p++)
        d_req[p] += lp_req_hsk[g][t][p] - lp_req_prev[g][t][p];
      for (int p = 0; p < LP_NumRespPorts && p < 2; p++)
        d_resp[p] += lp_resp_hsk[g][t][p] - lp_resp_prev[g][t][p];
      for (int p = 0; p < LP_NumReqPorts && p < 2; p++)
        d_sreq[p] += lp_sreq_hsk[g][t][p] - lp_sreq_prev[g][t][p];
      for (int p = 0; p < LP_NumRespPorts && p < 2; p++)
        d_sresp[p] += lp_sresp_hsk[g][t][p] - lp_sresp_prev[g][t][p];
    end

  total = d_req[0]+d_req[1];
  $display("[LP] %s cyc=%0d mst_req=%0d/%0d(%.0f%%) mst_resp=%0d/%0d(%.0f%%) slv_req=%0d/%0d(%.0f%%) slv_resp=%0d/%0d(%.0f%%)",
    tag, lp_cycle,
    d_req[0], d_req[1], total>0 ? 100.0*d_req[0]/$itor(total) : 0.0,
    d_resp[0], d_resp[1], (d_resp[0]+d_resp[1])>0 ? 100.0*d_resp[0]/$itor(d_resp[0]+d_resp[1]) : 0.0,
    d_sreq[0], d_sreq[1], (d_sreq[0]+d_sreq[1])>0 ? 100.0*d_sreq[0]/$itor(d_sreq[0]+d_sreq[1]) : 0.0,
    d_sresp[0], d_sresp[1], (d_sresp[0]+d_sresp[1])>0 ? 100.0*d_sresp[0]/$itor(d_sresp[0]+d_sresp[1]) : 0.0);

  // Save snapshot
  for (int g = 0; g < NumGroups; g++)
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int p = 0; p < LP_NumReqPorts; p++) lp_req_prev[g][t][p] = lp_req_hsk[g][t][p];
      for (int p = 0; p < LP_NumRespPorts; p++) lp_resp_prev[g][t][p] = lp_resp_hsk[g][t][p];
      for (int p = 0; p < LP_NumReqPorts; p++) lp_sreq_prev[g][t][p] = lp_sreq_hsk[g][t][p];
      for (int p = 0; p < LP_NumRespPorts; p++) lp_sresp_prev[g][t][p] = lp_sresp_hsk[g][t][p];
    end
endtask

// Periodic delta print (only during benchmark)
always @(posedge clk) begin
  if (`NOC_LINK_PROFILE_PERIOD > 0 && lp_cycle > 0 &&
      (lp_cycle % `NOC_LINK_PROFILE_PERIOD) == 0 && lp_benchmark_active) begin
    lp_print_delta("delta");
  end
end

// Final cumulative summary with per-tile detail
task automatic lp_print_final();
  int unsigned total_req[2], total_resp[2], total_sreq[2], total_sresp[2];
  for (int i = 0; i < 2; i++) begin
    total_req[i]=0; total_resp[i]=0; total_sreq[i]=0; total_sresp[i]=0;
  end
  for (int g = 0; g < NumGroups; g++)
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int p = 0; p < LP_NumReqPorts && p < 2; p++) total_req[p] += lp_req_hsk[g][t][p];
      for (int p = 0; p < LP_NumRespPorts && p < 2; p++) total_resp[p] += lp_resp_hsk[g][t][p];
      for (int p = 0; p < LP_NumReqPorts && p < 2; p++) total_sreq[p] += lp_sreq_hsk[g][t][p];
      for (int p = 0; p < LP_NumRespPorts && p < 2; p++) total_sresp[p] += lp_sresp_hsk[g][t][p];
    end
  $display("[LP] final @ cycle %0d", lp_cycle);
  $display("[LP]   mst_req: p0=%0d p1=%0d (%.1f%%/%.1f%%)", total_req[0], total_req[1],
    100.0*total_req[0]/$itor(total_req[0]+total_req[1]+1), 100.0*total_req[1]/$itor(total_req[0]+total_req[1]+1));
  $display("[LP]   mst_resp: p0=%0d p1=%0d (%.1f%%/%.1f%%)", total_resp[0], total_resp[1],
    100.0*total_resp[0]/$itor(total_resp[0]+total_resp[1]+1), 100.0*total_resp[1]/$itor(total_resp[0]+total_resp[1]+1));
  $display("[LP]   slv_req: p0=%0d p1=%0d (%.1f%%/%.1f%%)", total_sreq[0], total_sreq[1],
    100.0*total_sreq[0]/$itor(total_sreq[0]+total_sreq[1]+1), 100.0*total_sreq[1]/$itor(total_sreq[0]+total_sreq[1]+1));
  $display("[LP]   slv_resp: p0=%0d p1=%0d (%.1f%%/%.1f%%)", total_sresp[0], total_sresp[1],
    100.0*total_sresp[0]/$itor(total_sresp[0]+total_sresp[1]+1), 100.0*total_sresp[1]/$itor(total_sresp[0]+total_sresp[1]+1));

  for (int g = 0; g < NumGroups; g++) begin
    $display("[LP] G%0d Slave Resp per tile:", g);
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      if (LP_NumRespPorts >= 2)
        $display("[LP]   T%02d: p0=%6d p1=%6d", t, lp_sresp_hsk[g][t][0], lp_sresp_hsk[g][t][1]);
    end
  end
endtask

final begin
  lp_print_final();
end

`endif
// pragma translate_on

`endif
