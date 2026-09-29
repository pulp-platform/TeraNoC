// ============================================================================
// tb_load_noc_probe.svh — per-core vector-load delivery and per-sub-NoC link balance.
// Include inside mempool_tb module. Reports every LNP_PERIOD cycles while the benchmark region
// (csr_trace_any_global) is active.
//
// [LDP]  Per group, averaged over its cores:
//          rsp_x1000  words delivered to the Spatz VLSU per cycle per core, x1000
//                     (spatz_mem_rsp_valid, one word per valid, summed over the memory ports);
//          occ_x10    mean reorder-buffer occupancy per core (words allocated and not yet
//                     drained: in flight + arrived out of order), x10, summed over the ports;
//        and machine-wide: rsp words/cycle/core, occupancy, and lat = occ / rsp (Little's law:
//        the mean time a word spends between allocation and drain).
// [SUBNOC] Per router class (wreq / nreq / resp) and per parallel sub-NoC s = tile*P + port -- the
//        word-level meshes the req/resp remappers spread traffic over -- flits that left a router
//        output (hsk) and flits held there (stall), summed over all groups and N/E/S/W outputs.
//        [SUBNOCD] is the same per output direction. An even spread is equal numbers across s.
// [EJECT] The response path at the DESTINATION group, per stage, summed over groups, hsk / stall
//        (valid && !ready) cycles:
//          cls=rtr   each resp router's local output, index tile*RP + port (RP resp ports);
//          cls=lane  the local response crossbar's outputs = MemPool master-response lanes,
//                    index lane*RP + port. With the split MSHR a lane is (slice, k) =
//                    mshr_noc_lane: bursts land on row-slice lanes, singles on column-slice ones.
// [SLICEQ] Split MSHR, per slice m (0..3 rows R, 4..7 columns C), summed over groups: NoC-response
//        ingress hsk/stall (noc_resp_valid_i/ready_o) and tile-response egress hsk/stall.
//
// Simulation only; references inside genvar loops (cross-module refs into generate arrays need
// constant indices). Disable with +define+LNP_DISABLE.
// ============================================================================

`ifndef TB_LOAD_NOC_PROBE_SVH
`define TB_LOAD_NOC_PROBE_SVH

// pragma translate_off
`ifndef VERILATOR
`ifdef TARGET_SPATZ

`ifndef LNP_PERIOD
`define LNP_PERIOD 1000
`endif

`define LNP_GRP(G) dut.i_mempool_cluster.gen_groups_x[(G)/NumY].gen_groups_y[(G)%NumY].gen_rtl_group.i_group
`define LNP_CORE(G,T,C) `LNP_GRP(G).i_mempool_group.gen_tiles[T].i_tile.gen_cores[C].gen_mempool_cc.riscv_core

  localparam int unsigned LnpCpg   = NumTilesPerGroup * NumCoresPerTile;
  localparam int unsigned LnpWP    = NumWideRemoteReqPortsPerTile;
  localparam int unsigned LnpRP    = NumRemoteRespPortsPerTile - 1;
  localparam int unsigned LnpNP    = NumNarrowRemoteReqPortsPerTile;
  localparam int unsigned LnpWSub  = NumTilesPerGroup * LnpWP;
  localparam int unsigned LnpRSub  = NumTilesPerGroup * LnpRP;
  localparam int unsigned LnpNSub  = NumTilesPerGroup * ((LnpNP > 0) ? LnpNP : 1);

  // ---- per-core delivery and occupancy (combinational per cycle) ----
  int unsigned lnp_rsp [NumGroups][LnpCpg];
  logic [NumGroups-1:0][LnpCpg-1:0][NumMemPortsPerSpatz-1:0][7:0] lnp_occ_pp;  // ROB fill per port
  for (genvar g = 0; g < NumGroups; g++) begin : gen_lnp_g
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_lnp_t
      for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_lnp_c
        for (genvar p = 0; p < NumMemPortsPerSpatz; p++) begin : gen_lnp_p
          assign lnp_occ_pp[g][t*NumCoresPerTile+c][p] =
            8'(`LNP_CORE(g,t,c).i_spatz.i_vlsu.gen_rob[p].i_reorder_buffer.status_cnt_q);
        end
        assign lnp_rsp[g][t*NumCoresPerTile+c] = $countones(`LNP_CORE(g,t,c).spatz_mem_rsp_valid);
      end
    end
  end

  // ---- per sub-NoC, per output direction (combinational per cycle) ----
  // index [g][d][s], s = tile*ports + port
  logic [NumGroups-1:0][3:0][LnpWSub-1:0] lnp_w_v, lnp_w_r;
  logic [NumGroups-1:0][3:0][LnpRSub-1:0] lnp_r_v, lnp_r_r;
  logic [NumGroups-1:0][3:0][LnpNSub-1:0] lnp_n_v, lnp_n_r;
  for (genvar g = 0; g < NumGroups; g++) begin : gen_lnp_sub_g
    for (genvar d = 0; d < 4; d++) begin : gen_lnp_sub_d
      assign lnp_w_v[g][d] = `LNP_GRP(g).floo_tcdm_wide_req_valid_out[d];
      assign lnp_w_r[g][d] = `LNP_GRP(g).floo_tcdm_wide_req_ready_in[d];
      assign lnp_r_v[g][d] = `LNP_GRP(g).floo_tcdm_resp_valid_out[d];
      assign lnp_r_r[g][d] = `LNP_GRP(g).floo_tcdm_resp_ready_in[d];
`ifdef USE_NARROW_REQ_CHANNEL
      assign lnp_n_v[g][d] = `LNP_GRP(g).floo_tcdm_narrow_req_valid_out[d];
      assign lnp_n_r[g][d] = `LNP_GRP(g).floo_tcdm_narrow_req_ready_in[d];
`else
      assign lnp_n_v[g][d] = '0;
      assign lnp_n_r[g][d] = '0;
`endif
    end
  end

  // ---- destination response path (combinational per cycle) ----
  localparam int unsigned LnpEj = NumTilesPerGroup * LnpRP;
  logic [NumGroups-1:0][LnpEj-1:0] lnp_ej_v, lnp_ej_r, lnp_ln_v, lnp_ln_r;
  for (genvar g = 0; g < NumGroups; g++) begin : gen_lnp_ej_g
    assign lnp_ej_v[g] = `LNP_GRP(g).floo_tcdm_resp_from_router_before_xbar_valid;
    assign lnp_ej_r[g] = `LNP_GRP(g).floo_tcdm_resp_from_router_before_xbar_ready;
    assign lnp_ln_v[g] = `LNP_GRP(g).floo_tcdm_resp_from_router_after_xbar_valid;
    assign lnp_ln_r[g] = `LNP_GRP(g).floo_tcdm_resp_from_router_after_xbar_ready;
  end
  localparam int unsigned LnpSl = MshrSplit ? 8 : 1;
  int unsigned lnp_sq_nh [NumGroups][LnpSl], lnp_sq_ns [NumGroups][LnpSl];
  int unsigned lnp_sq_th [NumGroups][LnpSl], lnp_sq_ts [NumGroups][LnpSl];
`define LNP_SL(G,M) `LNP_GRP(G).i_mempool_group.gen_group_mshr_split.gen_slice[M].i_slice
  if (MshrSplit) begin : gen_lnp_sq
    for (genvar g = 0; g < NumGroups; g++) begin : gen_lnp_sq_g
      for (genvar m = 0; m < 8; m++) begin : gen_lnp_sq_m
        assign lnp_sq_nh[g][m] = $countones(`LNP_SL(g,m).noc_resp_valid_i &  `LNP_SL(g,m).noc_resp_ready_o);
        assign lnp_sq_ns[g][m] = $countones(`LNP_SL(g,m).noc_resp_valid_i & ~`LNP_SL(g,m).noc_resp_ready_o);
        assign lnp_sq_th[g][m] = $countones(`LNP_SL(g,m).tile_resp_valid_o &  `LNP_SL(g,m).tile_resp_ready_i);
        assign lnp_sq_ts[g][m] = $countones(`LNP_SL(g,m).tile_resp_valid_o & ~`LNP_SL(g,m).tile_resp_ready_i);
      end
    end
  end else begin : gen_lnp_sq_none
    for (genvar g = 0; g < NumGroups; g++) begin : gen_lnp_sq_g
      assign lnp_sq_nh[g][0] = 0; assign lnp_sq_ns[g][0] = 0;
      assign lnp_sq_th[g][0] = 0; assign lnp_sq_ts[g][0] = 0;
    end
  end
`undef LNP_SL
  int unsigned lnp_ej_h [LnpEj], lnp_ej_s [LnpEj], lnp_ln_h [LnpEj], lnp_ln_s [LnpEj];
  int unsigned lnp_sqa_nh [LnpSl], lnp_sqa_ns [LnpSl], lnp_sqa_th [LnpSl], lnp_sqa_ts [LnpSl];

  // ---- period accumulation ----
  longint unsigned lnp_rsp_acc [NumGroups], lnp_occ_acc [NumGroups];
  int unsigned lnp_w_h [4][LnpWSub], lnp_w_s [4][LnpWSub];
  int unsigned lnp_r_h [4][LnpRSub], lnp_r_s [4][LnpRSub];
  int unsigned lnp_n_h [4][LnpNSub], lnp_n_s [4][LnpNSub];
  int unsigned lnp_cyc, lnp_win;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lnp_cyc = 0; lnp_win = 0;
      for (int e = 0; e < LnpEj; e++) begin lnp_ej_h[e] = 0; lnp_ej_s[e] = 0; lnp_ln_h[e] = 0; lnp_ln_s[e] = 0; end
      for (int m = 0; m < LnpSl; m++) begin lnp_sqa_nh[m] = 0; lnp_sqa_ns[m] = 0; lnp_sqa_th[m] = 0; lnp_sqa_ts[m] = 0; end
      for (int g = 0; g < NumGroups; g++) begin lnp_rsp_acc[g] = 0; lnp_occ_acc[g] = 0; end
      for (int d = 0; d < 4; d++) begin
        for (int s = 0; s < LnpWSub; s++) begin lnp_w_h[d][s] = 0; lnp_w_s[d][s] = 0; end
        for (int s = 0; s < LnpRSub; s++) begin lnp_r_h[d][s] = 0; lnp_r_s[d][s] = 0; end
        for (int s = 0; s < LnpNSub; s++) begin lnp_n_h[d][s] = 0; lnp_n_s[d][s] = 0; end
      end
    end else begin
      lnp_cyc = lnp_cyc + 1;
      if (csr_trace_any_global) begin
        lnp_win = lnp_win + 1;
        for (int g = 0; g < NumGroups; g++) begin
          for (int e = 0; e < LnpEj; e++) begin
            if (lnp_ej_v[g][e] &&  lnp_ej_r[g][e]) lnp_ej_h[e] += 1;
            if (lnp_ej_v[g][e] && !lnp_ej_r[g][e]) lnp_ej_s[e] += 1;
            if (lnp_ln_v[g][e] &&  lnp_ln_r[g][e]) lnp_ln_h[e] += 1;
            if (lnp_ln_v[g][e] && !lnp_ln_r[g][e]) lnp_ln_s[e] += 1;
          end
          for (int m = 0; m < LnpSl; m++) begin
            lnp_sqa_nh[m] += lnp_sq_nh[g][m]; lnp_sqa_ns[m] += lnp_sq_ns[g][m];
            lnp_sqa_th[m] += lnp_sq_th[g][m]; lnp_sqa_ts[m] += lnp_sq_ts[g][m];
          end
          for (int c = 0; c < LnpCpg; c++) begin
            lnp_rsp_acc[g] += lnp_rsp[g][c];
            for (int p = 0; p < NumMemPortsPerSpatz; p++) lnp_occ_acc[g] += lnp_occ_pp[g][c][p];
          end
          for (int d = 0; d < 4; d++) begin
            for (int s = 0; s < LnpWSub; s++) begin
              if (lnp_w_v[g][d][s] &&  lnp_w_r[g][d][s]) lnp_w_h[d][s] += 1;
              if (lnp_w_v[g][d][s] && !lnp_w_r[g][d][s]) lnp_w_s[d][s] += 1;
            end
            for (int s = 0; s < LnpRSub; s++) begin
              if (lnp_r_v[g][d][s] &&  lnp_r_r[g][d][s]) lnp_r_h[d][s] += 1;
              if (lnp_r_v[g][d][s] && !lnp_r_r[g][d][s]) lnp_r_s[d][s] += 1;
            end
            for (int s = 0; s < LnpNSub; s++) begin
              if (lnp_n_v[g][d][s] &&  lnp_n_r[g][d][s]) lnp_n_h[d][s] += 1;
              if (lnp_n_v[g][d][s] && !lnp_n_r[g][d][s]) lnp_n_s[d][s] += 1;
            end
          end
        end
      end
      if (lnp_win == `LNP_PERIOD) begin : lnp_report
        automatic string sr = "", so = "";
        automatic longint unsigned tr = 0, to = 0;
        for (int g = 0; g < NumGroups; g++) begin
          sr = {sr, $sformatf((g == 0) ? "%0d" : ",%0d", lnp_rsp_acc[g] * 1000 / (lnp_win * LnpCpg))};
          so = {so, $sformatf((g == 0) ? "%0d" : ",%0d", lnp_occ_acc[g] * 10 / (lnp_win * LnpCpg))};
          tr += lnp_rsp_acc[g]; to += lnp_occ_acc[g];
        end
        $display("[LDP] cyc=%0d rsp_wpc_core=%.3f occ_words_core=%.1f lat=%.0f rsp_x1000=%s occ_x10=%s",
                 lnp_cyc, real'(tr) / (lnp_win * NumGroups * LnpCpg),
                 real'(to) / (lnp_win * NumGroups * LnpCpg),
                 (tr > 0) ? real'(to) / real'(tr) : 0.0, sr, so);
        for (int cls = 0; cls < 3; cls++) begin
          automatic int unsigned ns = (cls == 0) ? LnpWSub : (cls == 1) ? LnpRSub : LnpNSub;
          automatic string cn = (cls == 0) ? "wreq" : (cls == 1) ? "resp" : "nreq";
          automatic string sh = "", ss = "";
          if (cls == 2 && LnpNP == 0) continue;
          for (int s = 0; s < ns; s++) begin
            automatic int unsigned h = 0, st = 0;
            for (int d = 0; d < 4; d++) begin
              h  += (cls == 0) ? lnp_w_h[d][s] : (cls == 1) ? lnp_r_h[d][s] : lnp_n_h[d][s];
              st += (cls == 0) ? lnp_w_s[d][s] : (cls == 1) ? lnp_r_s[d][s] : lnp_n_s[d][s];
            end
            sh = {sh, $sformatf((s == 0) ? "%0d" : ",%0d", h)};
            ss = {ss, $sformatf((s == 0) ? "%0d" : ",%0d", st)};
          end
          $display("[SUBNOC] cyc=%0d cls=%s hsk=%s stall=%s", lnp_cyc, cn, sh, ss);
          for (int d = 0; d < 4; d++) begin
            automatic string dh = "", ds = "";
            for (int s = 0; s < ns; s++) begin
              dh = {dh, $sformatf((s == 0) ? "%0d" : ",%0d",
                    (cls == 0) ? lnp_w_h[d][s] : (cls == 1) ? lnp_r_h[d][s] : lnp_n_h[d][s])};
              ds = {ds, $sformatf((s == 0) ? "%0d" : ",%0d",
                    (cls == 0) ? lnp_w_s[d][s] : (cls == 1) ? lnp_r_s[d][s] : lnp_n_s[d][s])};
            end
            $display("[SUBNOCD] cyc=%0d cls=%s dir=%0d hsk=%s stall=%s", lnp_cyc, cn, d, dh, ds);
          end
        end
        begin : lnp_eject_report
          automatic string a = "", b = "", c = "", d = "";
          for (int e = 0; e < LnpEj; e++) begin
            a = {a, $sformatf((e == 0) ? "%0d" : ",%0d", lnp_ej_h[e])};
            b = {b, $sformatf((e == 0) ? "%0d" : ",%0d", lnp_ej_s[e])};
            c = {c, $sformatf((e == 0) ? "%0d" : ",%0d", lnp_ln_h[e])};
            d = {d, $sformatf((e == 0) ? "%0d" : ",%0d", lnp_ln_s[e])};
          end
          $display("[EJECT] cyc=%0d cls=rtr hsk=%s stall=%s", lnp_cyc, a, b);
          $display("[EJECT] cyc=%0d cls=lane hsk=%s stall=%s", lnp_cyc, c, d);
          a = ""; b = ""; c = ""; d = "";
          for (int m = 0; m < LnpSl; m++) begin
            a = {a, $sformatf((m == 0) ? "%0d" : ",%0d", lnp_sqa_nh[m])};
            b = {b, $sformatf((m == 0) ? "%0d" : ",%0d", lnp_sqa_ns[m])};
            c = {c, $sformatf((m == 0) ? "%0d" : ",%0d", lnp_sqa_th[m])};
            d = {d, $sformatf((m == 0) ? "%0d" : ",%0d", lnp_sqa_ts[m])};
          end
          $display("[SLICEQ] cyc=%0d nrsp_hsk=%s nrsp_stall=%s trsp_hsk=%s trsp_stall=%s",
                   lnp_cyc, a, b, c, d);
        end
        lnp_win = 0;
        for (int e = 0; e < LnpEj; e++) begin lnp_ej_h[e] = 0; lnp_ej_s[e] = 0; lnp_ln_h[e] = 0; lnp_ln_s[e] = 0; end
        for (int m = 0; m < LnpSl; m++) begin lnp_sqa_nh[m] = 0; lnp_sqa_ns[m] = 0; lnp_sqa_th[m] = 0; lnp_sqa_ts[m] = 0; end
        for (int g = 0; g < NumGroups; g++) begin lnp_rsp_acc[g] = 0; lnp_occ_acc[g] = 0; end
        for (int d = 0; d < 4; d++) begin
          for (int s = 0; s < LnpWSub; s++) begin lnp_w_h[d][s] = 0; lnp_w_s[d][s] = 0; end
          for (int s = 0; s < LnpRSub; s++) begin lnp_r_h[d][s] = 0; lnp_r_s[d][s] = 0; end
          for (int s = 0; s < LnpNSub; s++) begin lnp_n_h[d][s] = 0; lnp_n_s[d][s] = 0; end
        end
      end
    end
  end

`undef LNP_GRP
`undef LNP_CORE

`endif
`endif
// pragma translate_on

`endif
