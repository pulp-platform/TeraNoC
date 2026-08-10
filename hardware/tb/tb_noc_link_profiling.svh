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
// Prints ALL ports, not just two. The previous version clamped every loop with `p < 2`
// and sized the accumulators [2], so on any config with >2 response channels the extra
// channels' traffic was counted per-tile and then silently discarded at aggregation --
// i.e. a resp_ch=3/4 run could not report its own channel utilisation, which is exactly
// what a channel-fairness question needs.
task automatic lp_print_delta(input string tag);
  int unsigned d_req[LP_NumReqPorts], d_resp[LP_NumRespPorts];
  int unsigned d_sreq[LP_NumReqPorts], d_sresp[LP_NumRespPorts];
  int unsigned tot_req, tot_resp, tot_sreq, tot_sresp;
  string s_req, s_resp, s_sreq, s_sresp;

  for (int i = 0; i < LP_NumReqPorts;  i++) begin d_req[i]=0; d_sreq[i]=0; end
  for (int i = 0; i < LP_NumRespPorts; i++) begin d_resp[i]=0; d_sresp[i]=0; end

  for (int g = 0; g < NumGroups; g++)
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int p = 0; p < LP_NumReqPorts; p++) begin
        d_req[p]   += lp_req_hsk[g][t][p]   - lp_req_prev[g][t][p];
        d_sreq[p]  += lp_sreq_hsk[g][t][p]  - lp_sreq_prev[g][t][p];
      end
      for (int p = 0; p < LP_NumRespPorts; p++) begin
        d_resp[p]  += lp_resp_hsk[g][t][p]  - lp_resp_prev[g][t][p];
        d_sresp[p] += lp_sresp_hsk[g][t][p] - lp_sresp_prev[g][t][p];
      end
    end

  tot_req=0; tot_resp=0; tot_sreq=0; tot_sresp=0;
  for (int p = 0; p < LP_NumReqPorts;  p++) begin tot_req  += d_req[p];  tot_sreq  += d_sreq[p];  end
  for (int p = 0; p < LP_NumRespPorts; p++) begin tot_resp += d_resp[p]; tot_sresp += d_sresp[p]; end

  // "n0/n1/.. (p0%/p1%/..)" so per-channel share is directly readable
  s_req=""; s_resp=""; s_sreq=""; s_sresp="";
  for (int p = 0; p < LP_NumReqPorts; p++) begin
    s_req   = {s_req,   $sformatf("%0d(%.1f%%)", d_req[p],
               tot_req>0  ? 100.0*d_req[p] /$itor(tot_req)  : 0.0), (p<LP_NumReqPorts-1) ? "/" : ""};
    s_sreq  = {s_sreq,  $sformatf("%0d(%.1f%%)", d_sreq[p],
               tot_sreq>0 ? 100.0*d_sreq[p]/$itor(tot_sreq) : 0.0), (p<LP_NumReqPorts-1) ? "/" : ""};
  end
  for (int p = 0; p < LP_NumRespPorts; p++) begin
    s_resp  = {s_resp,  $sformatf("%0d(%.1f%%)", d_resp[p],
               tot_resp>0  ? 100.0*d_resp[p] /$itor(tot_resp)  : 0.0), (p<LP_NumRespPorts-1) ? "/" : ""};
    s_sresp = {s_sresp, $sformatf("%0d(%.1f%%)", d_sresp[p],
               tot_sresp>0 ? 100.0*d_sresp[p]/$itor(tot_sresp) : 0.0), (p<LP_NumRespPorts-1) ? "/" : ""};
  end

  $display("[LP] %s cyc=%0d nreq=%0d nresp=%0d mst_req=%s mst_resp=%s slv_req=%s slv_resp=%s",
           tag, lp_cycle, LP_NumReqPorts, LP_NumRespPorts, s_req, s_resp, s_sreq, s_sresp);
  $display("[LP] %s cyc=%0d totals: mst_req=%0d mst_resp=%0d resp_per_req=%.2f",
           tag, lp_cycle, tot_req, tot_resp, tot_req>0 ? $itor(tot_resp)/$itor(tot_req) : 0.0);

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
  int unsigned total_req[LP_NumReqPorts], total_resp[LP_NumRespPorts];
  int unsigned total_sreq[LP_NumReqPorts], total_sresp[LP_NumRespPorts];
  int unsigned sum_req, sum_resp, sum_sreq, sum_sresp;
  string f_req, f_resp, f_sreq, f_sresp;

  for (int i = 0; i < LP_NumReqPorts;  i++) begin total_req[i]=0; total_sreq[i]=0; end
  for (int i = 0; i < LP_NumRespPorts; i++) begin total_resp[i]=0; total_sresp[i]=0; end
  for (int g = 0; g < NumGroups; g++)
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      for (int p = 0; p < LP_NumReqPorts; p++) begin
        total_req[p]   += lp_req_hsk[g][t][p];
        total_sreq[p]  += lp_sreq_hsk[g][t][p];
      end
      for (int p = 0; p < LP_NumRespPorts; p++) begin
        total_resp[p]  += lp_resp_hsk[g][t][p];
        total_sresp[p] += lp_sresp_hsk[g][t][p];
      end
    end

  sum_req=0; sum_resp=0; sum_sreq=0; sum_sresp=0;
  for (int p = 0; p < LP_NumReqPorts;  p++) begin sum_req  += total_req[p];  sum_sreq  += total_sreq[p];  end
  for (int p = 0; p < LP_NumRespPorts; p++) begin sum_resp += total_resp[p]; sum_sresp += total_sresp[p]; end

  f_req=""; f_resp=""; f_sreq=""; f_sresp="";
  for (int p = 0; p < LP_NumReqPorts; p++) begin
    f_req  = {f_req,  $sformatf(" p%0d=%0d(%.1f%%)", p, total_req[p],
              sum_req>0  ? 100.0*total_req[p] /$itor(sum_req)  : 0.0)};
    f_sreq = {f_sreq, $sformatf(" p%0d=%0d(%.1f%%)", p, total_sreq[p],
              sum_sreq>0 ? 100.0*total_sreq[p]/$itor(sum_sreq) : 0.0)};
  end
  for (int p = 0; p < LP_NumRespPorts; p++) begin
    f_resp  = {f_resp,  $sformatf(" p%0d=%0d(%.1f%%)", p, total_resp[p],
               sum_resp>0  ? 100.0*total_resp[p] /$itor(sum_resp)  : 0.0)};
    f_sresp = {f_sresp, $sformatf(" p%0d=%0d(%.1f%%)", p, total_sresp[p],
               sum_sresp>0 ? 100.0*total_sresp[p]/$itor(sum_sresp) : 0.0)};
  end

  $display("[LP] final @ cycle %0d  (nreq=%0d nresp=%0d)", lp_cycle, LP_NumReqPorts, LP_NumRespPorts);
  $display("[LP]   mst_req: %s  total=%0d",  f_req,   sum_req);
  $display("[LP]   mst_resp:%s  total=%0d",  f_resp,  sum_resp);
  $display("[LP]   slv_req: %s  total=%0d",  f_sreq,  sum_sreq);
  $display("[LP]   slv_resp:%s  total=%0d",  f_sresp, sum_sresp);
  $display("[LP]   resp_per_req = %.2f (mst), %.2f (slv)",
           sum_req>0  ? $itor(sum_resp) /$itor(sum_req)  : 0.0,
           sum_sreq>0 ? $itor(sum_sresp)/$itor(sum_sreq) : 0.0);

  for (int g = 0; g < NumGroups; g++) begin
    $display("[LP] G%0d Slave Resp per tile:", g);
    for (int t = 0; t < NumTilesPerGroup; t++) begin
      string per_tile;
      per_tile = "";
      for (int p = 0; p < LP_NumRespPorts; p++)
        per_tile = {per_tile, $sformatf(" p%0d=%6d", p, lp_sresp_hsk[g][t][p])};
      $display("[LP]   T%02d:%s", t, per_tile);
    end
  end
endtask

final begin
  lp_print_final();
end

`endif
// pragma translate_on

`endif
