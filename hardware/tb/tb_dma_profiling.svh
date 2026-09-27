// ============================================================================
// tb_dma_profiling.svh -- where does the DMA's L2 -> L1 bandwidth go?
// Include inside mempool_tb module. Disable with +define+DMA_PROF_DISABLE.
//
// Each group's DMA backend (axi_dma_backend, mempool_group.sv gen_dmas) READS L2 over AXI
// (AR out, R in) and WRITES L1 over AXI (AW/W out) through a 4-beat internal buffer. Its
// peak is one 64 B beat per cycle per group; the L2 behind it is NumL2Channels single-port
// 64 B banks, one beat per cycle each. A K-tile refill measured 22-68 % of that peak with
// the same bytes, so this probe splits every cycle of every backend into
//
//   r      R handshake                       -- data moving
//   rstall R valid, NOT ready                -- the backend's buffer is full: the L1 WRITE
//                                               side is the limit
//   rwait  no R valid, reads outstanding     -- waiting on L2 / the NoC R path
//   wstall W valid, NOT ready                -- L1 write port backpressure (tiles busy)
//   out    outstanding read beats (mean = out / busy): how much latency it can hide
//
// and, per L2 channel, how many 64 B beats the bank served. A period is printed only if
// some backend moved data in it.
//
//   [DMAP] cyc=N busy=csv r=csv rstall=csv rwait=csv wstall=csv out=csv   (one field / group)
//   [L2BW] cyc=N beats=csv                                                 (one field / channel)
// ============================================================================

`ifndef TB_DMA_PROFILING_SVH
`define TB_DMA_PROFILING_SVH

`ifndef DMA_PROF_PERIOD
`define DMA_PROF_PERIOD 1000
`endif

// pragma translate_off
`ifndef VERILATOR

`define DP_GROUP(g) dut.i_mempool_cluster.gen_groups_x[(g)/NumY].gen_groups_y[(g)%NumY] \
    .gen_rtl_group.i_group.i_mempool_group

logic dp_arv [NumGroups][NumDmasPerGroup], dp_arr [NumGroups][NumDmasPerGroup];
logic dp_rv  [NumGroups][NumDmasPerGroup], dp_rr  [NumGroups][NumDmasPerGroup];
logic dp_wv  [NumGroups][NumDmasPerGroup], dp_wr  [NumGroups][NumDmasPerGroup];
logic [7:0] dp_arlen [NumGroups][NumDmasPerGroup];

generate
  for (genvar g = 0; g < NumGroups; g++) begin : gen_dp_g
    for (genvar d = 0; d < NumDmasPerGroup; d++) begin : gen_dp_d
      assign dp_arv[g][d]   = `DP_GROUP(g).gen_dmas[d].axi_dma_premux_req.ar_valid;
      assign dp_arr[g][d]   = `DP_GROUP(g).gen_dmas[d].axi_dma_premux_resp.ar_ready;
      assign dp_arlen[g][d] = `DP_GROUP(g).gen_dmas[d].axi_dma_premux_req.ar.len;
      assign dp_rv[g][d]    = `DP_GROUP(g).gen_dmas[d].axi_dma_premux_resp.r_valid;
      assign dp_rr[g][d]    = `DP_GROUP(g).gen_dmas[d].axi_dma_premux_req.r_ready;
      assign dp_wv[g][d]    = `DP_GROUP(g).gen_dmas[d].axi_dma_premux_req.w_valid;
      assign dp_wr[g][d]    = `DP_GROUP(g).gen_dmas[d].axi_dma_premux_resp.w_ready;
    end
  end
endgenerate

// Per group, summed over its backends. Blocking accumulation, committed once per cycle
// (see tb_noc_bottleneck_profiling.svh: several NBA increments in one loop collapse).
int unsigned dp_busy [NumGroups], dp_r [NumGroups], dp_rstall [NumGroups];
int unsigned dp_rwait [NumGroups], dp_wstall [NumGroups];
longint unsigned dp_out_sum [NumGroups];
int unsigned dp_out [NumGroups][NumDmasPerGroup];   // outstanding read beats, live
int unsigned dp_l2 [NumL2Channels];
int unsigned dp_cyc;

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    dp_cyc = 0;
    for (int g = 0; g < NumGroups; g++) begin
      dp_busy[g] = 0; dp_r[g] = 0; dp_rstall[g] = 0; dp_rwait[g] = 0; dp_wstall[g] = 0;
      dp_out_sum[g] = 0;
      for (int d = 0; d < NumDmasPerGroup; d++) dp_out[g][d] = 0;
    end
    for (int k = 0; k < NumL2Channels; k++) dp_l2[k] = 0;
  end else begin
    dp_cyc = dp_cyc + 1;
    for (int g = 0; g < NumGroups; g++) begin
      for (int d = 0; d < NumDmasPerGroup; d++) begin
        automatic logic r_hsk = dp_rv[g][d] && dp_rr[g][d];
        if (dp_out[g][d] != 0 || dp_rv[g][d] || dp_wv[g][d]) dp_busy[g] += 1;
        if (r_hsk) dp_r[g] += 1;
        if (dp_rv[g][d] && !dp_rr[g][d]) dp_rstall[g] += 1;
        if (!dp_rv[g][d] && dp_out[g][d] != 0) dp_rwait[g] += 1;
        if (dp_wv[g][d] && !dp_wr[g][d]) dp_wstall[g] += 1;
        dp_out_sum[g] += dp_out[g][d];
        if (dp_arv[g][d] && dp_arr[g][d]) dp_out[g][d] += int'(dp_arlen[g][d]) + 1;
        if (r_hsk && dp_out[g][d] != 0) dp_out[g][d] -= 1;
      end
    end
`ifndef DRAM
    for (int k = 0; k < NumL2Channels; k++)
      if (dut.mem_rvalid[k]) dp_l2[k] += 1;
`endif
    if ((dp_cyc % `DMA_PROF_PERIOD) == 0) begin : dp_report
      automatic int unsigned moved = 0;
      for (int g = 0; g < NumGroups; g++) moved += dp_r[g];
      if (moved != 0) begin
        automatic string sb = "", sr = "", ss = "", sw = "", sws = "", so = "", sl = "";
        for (int g = 0; g < NumGroups; g++) begin
          sb  = {sb,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_busy[g])};
          sr  = {sr,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_r[g])};
          ss  = {ss,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_rstall[g])};
          sw  = {sw,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_rwait[g])};
          sws = {sws, $sformatf((g == 0) ? "%0d" : ",%0d", dp_wstall[g])};
          so  = {so,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_out_sum[g])};
        end
        for (int k = 0; k < NumL2Channels; k++)
          sl = {sl, $sformatf((k == 0) ? "%0d" : ",%0d", dp_l2[k])};
        $display("[DMAP] cyc=%0d busy=%s r=%s rstall=%s rwait=%s wstall=%s out=%s",
                 dp_cyc, sb, sr, ss, sw, sws, so);
        $display("[L2BW] cyc=%0d beats=%s", dp_cyc, sl);
      end
      for (int g = 0; g < NumGroups; g++) begin
        dp_busy[g] = 0; dp_r[g] = 0; dp_rstall[g] = 0; dp_rwait[g] = 0; dp_wstall[g] = 0;
        dp_out_sum[g] = 0;
      end
      for (int k = 0; k < NumL2Channels; k++) dp_l2[k] = 0;
    end
  end
end

`undef DP_GROUP

`endif  // VERILATOR
// pragma translate_on

`endif  // TB_DMA_PROFILING_SVH
