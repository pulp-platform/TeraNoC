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
//   arstall  AR valid, NOT ready             -- the NoC / chimney refuses more reads
//   chunks   1 KB transfers handed to the backend by the distributed midend
//
// and, per L2 channel: the 64 B beats its bank served, the ARs it accepted, the cycles its
// AR waited (arstall) and the cycles its R data waited for the NoC (rstall). A period is
// printed only if some backend moved data in it.
//
//   [DMAP] cyc=N busy= r= rstall= rwait= wstall= out= arstall= chunks=   (one field / group)
//   [L2BW] cyc=N beats= ar= arstall= rstall=                             (one field / channel)
//
// The DMA's AXI traffic has its own mesh (one floo_nw_router per group, mempool_group_floonoc_wrapper
// i_floo_narrow_wide_router). Per router and port (0 N, 1 E, 2 S, 3 W, 4 Eject = the group's own AXI
// NI), on the WIDE network that carries the read data:
//   [AXIW] cyc=N port=P ohsk= ostall= ihsk= istall=                      (one field / group)
//     ohsk/ostall  flits sent out of that port / valid but the far side not ready
//     ihsk/istall  flits taken in on that port / offered but this router not ready
// and the router in front of the L2 channel that shares its perimeter point with the peripherals
// (terapool only): port 1 = from that channel's NI, port 0 = towards the mesh.
//   [AXIWP] cyc=N ohsk= ostall= ihsk= istall=                            (one field / port 0..3)
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
logic dp_qv [NumGroups][NumDmasPerGroup], dp_qr [NumGroups][NumDmasPerGroup];  // chunk handout
logic dp_l2_arv [NumL2Channels], dp_l2_arr [NumL2Channels];
logic dp_l2_rv  [NumL2Channels], dp_l2_rr  [NumL2Channels];
localparam int unsigned DpPorts = 5;   // floo_pkg::route_direction_e: N, E, S, W, Eject
logic dp_wov [NumGroups][DpPorts], dp_wor [NumGroups][DpPorts];   // out valid / far-side ready
logic dp_wiv [NumGroups][DpPorts], dp_wir [NumGroups][DpPorts];   // in valid / our ready
logic dp_pov [4], dp_por [4], dp_piv [4], dp_pir [4];             // periph router ports

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
      assign dp_qv[g][d]    = `DP_GROUP(g).dma_req_valid[d];
      assign dp_qr[g][d]    = `DP_GROUP(g).dma_req_ready[d];
    end
  end
  for (genvar g = 0; g < NumGroups; g++) begin : gen_dp_axiw
    for (genvar d = 0; d < DpPorts; d++) begin : gen_dp_port
      // A router's input ready travels back in its OUTPUT struct (FlooNoC link convention).
      assign dp_wov[g][d] = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                              .gen_rtl_group.i_group.floo_axi_wide_out[d].valid;
      assign dp_wor[g][d] = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                              .gen_rtl_group.i_group.floo_axi_wide_in[d].ready;
      assign dp_wiv[g][d] = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                              .gen_rtl_group.i_group.floo_axi_wide_in[d].valid;
      assign dp_wir[g][d] = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY]
                              .gen_rtl_group.i_group.floo_axi_wide_out[d].ready;
    end
  end
`ifdef TERAPOOL
  for (genvar i = 0; i < 4; i++) begin : gen_dp_periph
    assign dp_pov[i] = dut.gen_cluster_axi_chimney[perimeter_map_pkg::PeriphHbmChannel]
                         .gen_periph_hbm.periph_router_wide_out[i].valid;
    assign dp_por[i] = dut.gen_cluster_axi_chimney[perimeter_map_pkg::PeriphHbmChannel]
                         .gen_periph_hbm.periph_router_wide_in[i].ready;
    assign dp_piv[i] = dut.gen_cluster_axi_chimney[perimeter_map_pkg::PeriphHbmChannel]
                         .gen_periph_hbm.periph_router_wide_in[i].valid;
    assign dp_pir[i] = dut.gen_cluster_axi_chimney[perimeter_map_pkg::PeriphHbmChannel]
                         .gen_periph_hbm.periph_router_wide_out[i].ready;
  end
`else
  for (genvar i = 0; i < 4; i++) begin : gen_dp_periph
    assign dp_pov[i] = 1'b0; assign dp_por[i] = 1'b0; assign dp_piv[i] = 1'b0; assign dp_pir[i] = 1'b0;
  end
`endif
  for (genvar k = 0; k < NumL2Channels; k++) begin : gen_dp_l2
    assign dp_l2_arv[k] = dut.axi_l2_req[k].ar_valid;
    assign dp_l2_arr[k] = dut.axi_l2_resp[k].ar_ready;
    assign dp_l2_rv[k]  = dut.axi_l2_resp[k].r_valid;
    assign dp_l2_rr[k]  = dut.axi_l2_req[k].r_ready;
  end
endgenerate

// Per group, summed over its backends. Blocking accumulation, committed once per cycle
// (see tb_noc_bottleneck_profiling.svh: several NBA increments in one loop collapse).
int unsigned dp_busy [NumGroups], dp_r [NumGroups], dp_rstall [NumGroups];
int unsigned dp_rwait [NumGroups], dp_wstall [NumGroups];
int unsigned dp_arstall [NumGroups], dp_chunks [NumGroups];
int unsigned dp_l2_ar [NumL2Channels], dp_l2_arstall [NumL2Channels], dp_l2_rstall [NumL2Channels];
int unsigned dp_ohsk [NumGroups][DpPorts], dp_ostall [NumGroups][DpPorts];
int unsigned dp_ihsk [NumGroups][DpPorts], dp_istall [NumGroups][DpPorts];
int unsigned dp_p_ohsk [4], dp_p_ostall [4], dp_p_ihsk [4], dp_p_istall [4];
longint unsigned dp_out_sum [NumGroups];
int unsigned dp_out [NumGroups][NumDmasPerGroup];   // outstanding read beats, live
int unsigned dp_l2 [NumL2Channels];
int unsigned dp_cyc;

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    dp_cyc = 0;
    for (int g = 0; g < NumGroups; g++) begin
      dp_busy[g] = 0; dp_r[g] = 0; dp_rstall[g] = 0; dp_rwait[g] = 0; dp_wstall[g] = 0;
      dp_out_sum[g] = 0; dp_arstall[g] = 0; dp_chunks[g] = 0;
      for (int d = 0; d < NumDmasPerGroup; d++) dp_out[g][d] = 0;
    end
    for (int k = 0; k < NumL2Channels; k++) begin
      dp_l2[k] = 0; dp_l2_ar[k] = 0; dp_l2_arstall[k] = 0; dp_l2_rstall[k] = 0;
    end
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
        if (dp_arv[g][d] && !dp_arr[g][d]) dp_arstall[g] += 1;
        if (dp_qv[g][d] && dp_qr[g][d]) dp_chunks[g] += 1;
        dp_out_sum[g] += dp_out[g][d];
        if (dp_arv[g][d] && dp_arr[g][d]) dp_out[g][d] += int'(dp_arlen[g][d]) + 1;
        if (r_hsk && dp_out[g][d] != 0) dp_out[g][d] -= 1;
      end
    end
`ifndef DRAM
    for (int k = 0; k < NumL2Channels; k++)
      if (dut.mem_rvalid[k]) dp_l2[k] += 1;
`endif
    for (int k = 0; k < NumL2Channels; k++) begin
      if (dp_l2_arv[k] && dp_l2_arr[k])  dp_l2_ar[k] += 1;
      if (dp_l2_arv[k] && !dp_l2_arr[k]) dp_l2_arstall[k] += 1;
      if (dp_l2_rv[k] && !dp_l2_rr[k])   dp_l2_rstall[k] += 1;
    end
    for (int g = 0; g < NumGroups; g++) begin
      for (int d = 0; d < DpPorts; d++) begin
        if (dp_wov[g][d] && dp_wor[g][d])  dp_ohsk[g][d] += 1;
        if (dp_wov[g][d] && !dp_wor[g][d]) dp_ostall[g][d] += 1;
        if (dp_wiv[g][d] && dp_wir[g][d])  dp_ihsk[g][d] += 1;
        if (dp_wiv[g][d] && !dp_wir[g][d]) dp_istall[g][d] += 1;
      end
    end
    for (int i = 0; i < 4; i++) begin
      if (dp_pov[i] && dp_por[i])  dp_p_ohsk[i] += 1;
      if (dp_pov[i] && !dp_por[i]) dp_p_ostall[i] += 1;
      if (dp_piv[i] && dp_pir[i])  dp_p_ihsk[i] += 1;
      if (dp_piv[i] && !dp_pir[i]) dp_p_istall[i] += 1;
    end
    if ((dp_cyc % `DMA_PROF_PERIOD) == 0) begin : dp_report
      automatic int unsigned moved = 0;
      for (int g = 0; g < NumGroups; g++) moved += dp_r[g];
      if (moved != 0) begin
        automatic string sb = "", sr = "", ss = "", sw = "", sws = "", so = "", sl = "";
        automatic string sas = "", sch = "", sla = "", slas = "", slrs = "";
        for (int g = 0; g < NumGroups; g++) begin
          sb  = {sb,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_busy[g])};
          sr  = {sr,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_r[g])};
          ss  = {ss,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_rstall[g])};
          sw  = {sw,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_rwait[g])};
          sws = {sws, $sformatf((g == 0) ? "%0d" : ",%0d", dp_wstall[g])};
          so  = {so,  $sformatf((g == 0) ? "%0d" : ",%0d", dp_out_sum[g])};
          sas = {sas, $sformatf((g == 0) ? "%0d" : ",%0d", dp_arstall[g])};
          sch = {sch, $sformatf((g == 0) ? "%0d" : ",%0d", dp_chunks[g])};
        end
        for (int k = 0; k < NumL2Channels; k++) begin
          sl   = {sl,   $sformatf((k == 0) ? "%0d" : ",%0d", dp_l2[k])};
          sla  = {sla,  $sformatf((k == 0) ? "%0d" : ",%0d", dp_l2_ar[k])};
          slas = {slas, $sformatf((k == 0) ? "%0d" : ",%0d", dp_l2_arstall[k])};
          slrs = {slrs, $sformatf((k == 0) ? "%0d" : ",%0d", dp_l2_rstall[k])};
        end
        $display("[DMAP] cyc=%0d busy=%s r=%s rstall=%s rwait=%s wstall=%s out=%s arstall=%s chunks=%s",
                 dp_cyc, sb, sr, ss, sw, sws, so, sas, sch);
        $display("[L2BW] cyc=%0d beats=%s ar=%s arstall=%s rstall=%s", dp_cyc, sl, sla, slas, slrs);
        for (int d = 0; d < DpPorts; d++) begin : dp_axiw_report
          automatic string a = "", b = "", c = "", e = "";
          for (int g = 0; g < NumGroups; g++) begin
            a = {a, $sformatf((g == 0) ? "%0d" : ",%0d", dp_ohsk[g][d])};
            b = {b, $sformatf((g == 0) ? "%0d" : ",%0d", dp_ostall[g][d])};
            c = {c, $sformatf((g == 0) ? "%0d" : ",%0d", dp_ihsk[g][d])};
            e = {e, $sformatf((g == 0) ? "%0d" : ",%0d", dp_istall[g][d])};
          end
          $display("[AXIW] cyc=%0d port=%0d ohsk=%s ostall=%s ihsk=%s istall=%s", dp_cyc, d, a, b, c, e);
        end
        $display("[AXIWP] cyc=%0d ohsk=%0d,%0d,%0d,%0d ostall=%0d,%0d,%0d,%0d ihsk=%0d,%0d,%0d,%0d istall=%0d,%0d,%0d,%0d",
                 dp_cyc, dp_p_ohsk[0], dp_p_ohsk[1], dp_p_ohsk[2], dp_p_ohsk[3],
                 dp_p_ostall[0], dp_p_ostall[1], dp_p_ostall[2], dp_p_ostall[3],
                 dp_p_ihsk[0], dp_p_ihsk[1], dp_p_ihsk[2], dp_p_ihsk[3],
                 dp_p_istall[0], dp_p_istall[1], dp_p_istall[2], dp_p_istall[3]);
      end
      for (int g = 0; g < NumGroups; g++) begin
        dp_busy[g] = 0; dp_r[g] = 0; dp_rstall[g] = 0; dp_rwait[g] = 0; dp_wstall[g] = 0;
        dp_out_sum[g] = 0; dp_arstall[g] = 0; dp_chunks[g] = 0;
      end
      for (int k = 0; k < NumL2Channels; k++) begin
        dp_l2[k] = 0; dp_l2_ar[k] = 0; dp_l2_arstall[k] = 0; dp_l2_rstall[k] = 0;
      end
      for (int g = 0; g < NumGroups; g++)
        for (int d = 0; d < DpPorts; d++) begin
          dp_ohsk[g][d] = 0; dp_ostall[g][d] = 0; dp_ihsk[g][d] = 0; dp_istall[g][d] = 0;
        end
      for (int i = 0; i < 4; i++) begin
        dp_p_ohsk[i] = 0; dp_p_ostall[i] = 0; dp_p_ihsk[i] = 0; dp_p_istall[i] = 0;
      end
    end
  end
end

`undef DP_GROUP

`endif  // VERILATOR
// pragma translate_on

`endif  // TB_DMA_PROFILING_SVH
