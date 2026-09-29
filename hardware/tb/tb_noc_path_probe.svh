// ============================================================================
// tb_noc_path_probe.svh — bandwidth and latency breakdown of the REMOTE TCDM path.
// Include inside mempool_tb. Opt-in: compiled only with +define+NOC_PATH_PROBE.
//
// Eleven tap points along the life of a remote access (index k = tile*ports + port, per group):
//
//   MIN   core request into the group MSHR       (split: slice lanes m*4+l; legacy: tiles)
//   MOUT  MSHR -> wrapper (tcdm_master_req)       -- after merging
//   RINJ  request router LOCAL input              -- after the request remapper
//   REJ   request router LOCAL output             (destination group)
//   SIN   destination tile slave request          -- after the local request crossbar
//   SOUT  destination tile slave response         -- one word per response
//   PINJ  response router LOCAL input             -- after the response remapper
//   PEJ   response router LOCAL output
//   PLANE local response crossbar input           -- after RespLocalExtraFifoDepth (== PEJ at 0)
//   MRSP  crossbar output = MSHR NoC response     (tcdm_master_resp)
//   MRO   MSHR response to the tiles              -- after multicast
//
// Units are WORDS: a request counts its burst_len (1 for a single), a response one word.
//
// [NPP]  per point, per period: words/cycle machine-wide (all, reads), per-port utilisation mean
//        and max (with the hottest g/k), stall (valid && !ready) per port-cycle and per handshake.
// [NPPL] per segment, per period: mean READ latency by Little's law. The occupancy of segment
//        A->B is cum_reads(A) - cum_reads(B) machine-wide (counted from reset, so pre-benchmark
//        traffic never skews it); latency = sum over the period of that occupancy / read words
//        leaving B. Every segment from MOUT to MRSP conserves words (no merge, no multicast in
//        between), so the segments add up to the NoC round trip. `drift` is the occupancy at the
//        period end: it must stay bounded, a steady climb means a point lost count of words.
//        merge = MIN/MOUT read words, mcast = MRO/MRSP read words.
// [NPPX] per local crossbar (req at the destination, resp at the requester), per period:
//        valid inputs/cycle, the share of valid inputs whose target lane had another valid input
//        that cycle (conflict), the share of valid inputs not accepted (stall) and output lanes
//        busy/cycle. Busy lanes low with stall high = input-side conflicts (head of line), not an
//        output that cannot drain.
//
// Simulation only; per-point arrays are filled by generate-scope assigns (cross-module references
// into generate arrays need constant indices).
// ============================================================================

`ifndef TB_NOC_PATH_PROBE_SVH
`define TB_NOC_PATH_PROBE_SVH

// pragma translate_off
`ifndef VERILATOR
`ifdef TARGET_SPATZ
`ifdef NOC_PATH_PROBE

`ifndef NPP_PERIOD
`define NPP_PERIOD 1000
`endif

`define NPP_GRP(G) dut.i_mempool_cluster.gen_groups_x[(G)/NumY].gen_groups_y[(G)%NumY].gen_rtl_group.i_group

  localparam int unsigned NppP   = NumRemoteRespPortsPerTile - 1;  // remote ports per tile
  localparam int unsigned NppWP  = NumWideRemoteReqPortsPerTile;
  localparam int unsigned NppTK  = NumTilesPerGroup * NppP;        // tile ports per group
  localparam int unsigned NppSK  = MshrNumSlices * MshrSliceTiles * NppP;  // MSHR lanes
  localparam int unsigned NppK   = (NppSK > NppTK) ? NppSK : NppTK;
  localparam int unsigned NppBW  = BurstLenWidth;
  localparam int unsigned NppNPt = 11;
  localparam int unsigned NppNSeg = 8;
  typedef enum int unsigned {
    NPP_MIN = 0, NPP_MOUT, NPP_RINJ, NPP_REJ, NPP_SIN, NPP_SOUT, NPP_PINJ, NPP_PEJ, NPP_PLANE,
    NPP_MRSP, NPP_MRO
  } npp_pt_e;

  // [g][point][k]
  logic [NumGroups-1:0][NppNPt-1:0][NppK-1:0]            npp_v, npp_r, npp_wen;
  logic [NumGroups-1:0][NppNPt-1:0][NppK-1:0][NppBW-1:0] npp_w;
  // local crossbars: [g][k] input valid/ready and target lane; output valid/ready
  logic [NumGroups-1:0][NppTK-1:0]       npp_xq_v, npp_xq_r, npp_xp_v, npp_xp_r;
  logic [NumGroups-1:0][NppTK-1:0]       npp_xq_ov, npp_xq_or, npp_xp_ov, npp_xp_or;
  logic [NumGroups-1:0][NppTK-1:0][7:0]  npp_xq_sel, npp_xp_sel;

  function automatic string npp_name(input int unsigned pt);
    case (pt)
      0: return "MIN";   1: return "MOUT";  2: return "RINJ"; 3: return "REJ";
      4: return "SIN";   5: return "SOUT";  6: return "PINJ"; 7: return "PEJ";
      8: return "PLANE"; 9: return "MRSP"; 10: return "MRO";
      default: return "?";
    endcase
  endfunction
  function automatic int unsigned npp_nk(input int unsigned pt);
    return (pt == NPP_MIN || pt == NPP_MRO) ? (MshrSplit ? NppSK : NppTK) : NppTK;
  endfunction

  if (NumNarrowRemoteReqPortsPerTile != 0) begin : gen_npp_narrow_unsupported
    initial $display("[NPP] WARNING: narrow request channels are not tapped; RINJ/REJ read 0");
  end

  for (genvar g = 0; g < NumGroups; g++) begin : gen_npp_g
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_npp_t
      for (genvar p = 1; p <= NppP; p++) begin : gen_npp_p
        localparam int unsigned K = t * NppP + (p - 1);
        // MOUT
        assign npp_v  [g][NPP_MOUT][K] = `NPP_GRP(g).tcdm_master_req_valid[t][p];
        assign npp_r  [g][NPP_MOUT][K] = `NPP_GRP(g).tcdm_master_req_ready[t][p];
        assign npp_w  [g][NPP_MOUT][K] = `NPP_GRP(g).tcdm_master_req[t][p].burst_len;
        assign npp_wen[g][NPP_MOUT][K] = `NPP_GRP(g).tcdm_master_req[t][p].wen;
        // SIN / SOUT
        assign npp_v  [g][NPP_SIN][K]  = `NPP_GRP(g).tcdm_slave_req_valid[t][p];
        assign npp_r  [g][NPP_SIN][K]  = `NPP_GRP(g).tcdm_slave_req_ready[t][p];
        assign npp_w  [g][NPP_SIN][K]  = `NPP_GRP(g).tcdm_slave_req[t][p].burst_len;
        assign npp_wen[g][NPP_SIN][K]  = `NPP_GRP(g).tcdm_slave_req[t][p].wen;
        assign npp_v  [g][NPP_SOUT][K] = `NPP_GRP(g).tcdm_slave_resp_valid[t][p];
        assign npp_r  [g][NPP_SOUT][K] = `NPP_GRP(g).tcdm_slave_resp_ready[t][p];
        assign npp_w  [g][NPP_SOUT][K] = NppBW'(1);
        assign npp_wen[g][NPP_SOUT][K] = `NPP_GRP(g).tcdm_slave_resp[t][p].wen;
        // PINJ / PEJ / PLANE / MRSP
        assign npp_v  [g][NPP_PINJ][K] = `NPP_GRP(g).floo_tcdm_resp_to_router_valid[t][p];
        assign npp_r  [g][NPP_PINJ][K] = `NPP_GRP(g).floo_tcdm_resp_to_router_ready[t][p];
        assign npp_w  [g][NPP_PINJ][K] = NppBW'(1);
        assign npp_wen[g][NPP_PINJ][K] = `NPP_GRP(g).floo_tcdm_resp_to_router[t][p].payload.wen;
        assign npp_v  [g][NPP_PEJ][K]  = `NPP_GRP(g).floo_tcdm_resp_from_router_vc_valid[t][p];
        assign npp_r  [g][NPP_PEJ][K]  = `NPP_GRP(g).floo_tcdm_resp_from_router_vc_ready[t][p];
        assign npp_w  [g][NPP_PEJ][K]  = NppBW'(1);
        assign npp_wen[g][NPP_PEJ][K]  = `NPP_GRP(g).floo_tcdm_resp_from_router_vc[t][p].payload.wen;
        assign npp_v  [g][NPP_PLANE][K] = `NPP_GRP(g).floo_tcdm_resp_from_router_before_xbar_valid[t][p];
        assign npp_r  [g][NPP_PLANE][K] = `NPP_GRP(g).floo_tcdm_resp_from_router_before_xbar_ready[t][p];
        assign npp_w  [g][NPP_PLANE][K] = NppBW'(1);
        assign npp_wen[g][NPP_PLANE][K] = `NPP_GRP(g).floo_tcdm_resp_from_router[t][p].payload.wen;
        assign npp_v  [g][NPP_MRSP][K] = `NPP_GRP(g).tcdm_master_resp_valid[t][p];
        assign npp_r  [g][NPP_MRSP][K] = `NPP_GRP(g).tcdm_master_resp_ready[t][p];
        assign npp_w  [g][NPP_MRSP][K] = NppBW'(1);
        assign npp_wen[g][NPP_MRSP][K] = `NPP_GRP(g).tcdm_master_resp[t][p].wen;
        // local crossbars (index space of the crossbar inputs)
        assign npp_xq_v  [g][K] = `NPP_GRP(g).floo_tcdm_req_from_router_before_xbar_valid[t][p];
        assign npp_xq_r  [g][K] = `NPP_GRP(g).floo_tcdm_req_from_router_before_xbar_ready[t][p];
        assign npp_xq_sel[g][K] = 8'(`NPP_GRP(g).req_tile_sel[t][p]);
        assign npp_xq_ov [g][K] = `NPP_GRP(g).floo_tcdm_req_from_router_after_xbar_valid[t][p];
        assign npp_xq_or [g][K] = `NPP_GRP(g).floo_tcdm_req_from_router_after_xbar_ready[t][p];
        assign npp_xp_v  [g][K] = `NPP_GRP(g).floo_tcdm_resp_from_router_before_xbar_valid[t][p];
        assign npp_xp_r  [g][K] = `NPP_GRP(g).floo_tcdm_resp_from_router_before_xbar_ready[t][p];
        assign npp_xp_sel[g][K] = 8'(`NPP_GRP(g).resp_tile_sel[t][p]);
        assign npp_xp_ov [g][K] = `NPP_GRP(g).floo_tcdm_resp_from_router_after_xbar_valid[t][p];
        assign npp_xp_or [g][K] = `NPP_GRP(g).floo_tcdm_resp_from_router_after_xbar_ready[t][p];
      end
      // RINJ / REJ: wide request ports j = 0..NppWP-1 are remote ports 1 + j (no narrow channel)
      for (genvar j = 0; j < NppWP; j++) begin : gen_npp_w
        localparam int unsigned K = t * NppP + j;
        assign npp_v  [g][NPP_RINJ][K] = `NPP_GRP(g).floo_tcdm_rdwr_req_to_router_valid[t][j];
        assign npp_r  [g][NPP_RINJ][K] = `NPP_GRP(g).floo_tcdm_rdwr_req_to_router_ready[t][j];
        assign npp_w  [g][NPP_RINJ][K] = `NPP_GRP(g).floo_tcdm_rdwr_req_to_router[t][j].hdr.burst_len;
        assign npp_wen[g][NPP_RINJ][K] = `NPP_GRP(g).floo_tcdm_rdwr_req_to_router[t][j].payload.wen;
        assign npp_v  [g][NPP_REJ][K]  = `NPP_GRP(g).floo_tcdm_rdwr_req_from_router_vc_valid[t][j];
        assign npp_r  [g][NPP_REJ][K]  = `NPP_GRP(g).floo_tcdm_rdwr_req_from_router_vc_ready[t][j];
        assign npp_w  [g][NPP_REJ][K]  = `NPP_GRP(g).floo_tcdm_rdwr_req_from_router_vc[t][j].hdr.burst_len;
        assign npp_wen[g][NPP_REJ][K]  = `NPP_GRP(g).floo_tcdm_rdwr_req_from_router_vc[t][j].payload.wen;
      end
    end
    // MIN / MRO: the MSHR's tile-side ports
    if (MshrSplit) begin : gen_npp_split
`define NPP_SL(G,M) `NPP_GRP(G).i_mempool_group.gen_group_mshr_split.gen_slice[M].i_slice.i_core
      for (genvar m = 0; m < MshrNumSlices; m++) begin : gen_npp_m
        for (genvar l = 0; l < MshrSliceTiles; l++) begin : gen_npp_l
          for (genvar p = 1; p <= NppP; p++) begin : gen_npp_p
            localparam int unsigned K = (m * MshrSliceTiles + l) * NppP + (p - 1);
            assign npp_v  [g][NPP_MIN][K] = `NPP_SL(g,m).group_mshr_req_valid_i[l][p];
            assign npp_r  [g][NPP_MIN][K] = `NPP_SL(g,m).group_mshr_req_ready_o[l][p];
            assign npp_w  [g][NPP_MIN][K] = `NPP_SL(g,m).group_mshr_req_i[l][p].burst_len;
            assign npp_wen[g][NPP_MIN][K] = `NPP_SL(g,m).group_mshr_req_i[l][p].wen;
            assign npp_v  [g][NPP_MRO][K] = `NPP_SL(g,m).group_mshr_resp_valid_o[l][p];
            assign npp_r  [g][NPP_MRO][K] = `NPP_SL(g,m).group_mshr_resp_ready_i[l][p];
            assign npp_w  [g][NPP_MRO][K] = NppBW'(1);
            assign npp_wen[g][NPP_MRO][K] = `NPP_SL(g,m).group_mshr_resp_o[l][p].wen;
          end
        end
      end
`undef NPP_SL
    end else begin : gen_npp_legacy
`define NPP_LM(G) `NPP_GRP(G).i_mempool_group.gen_group_mshr.i_group_mshr
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_npp_t
        for (genvar p = 1; p <= NppP; p++) begin : gen_npp_p
          localparam int unsigned K = t * NppP + (p - 1);
          assign npp_v  [g][NPP_MIN][K] = `NPP_LM(g).group_mshr_req_valid_i[t][p];
          assign npp_r  [g][NPP_MIN][K] = `NPP_LM(g).group_mshr_req_ready_o[t][p];
          assign npp_w  [g][NPP_MIN][K] = `NPP_LM(g).group_mshr_req_i[t][p].burst_len;
          assign npp_wen[g][NPP_MIN][K] = `NPP_LM(g).group_mshr_req_i[t][p].wen;
          assign npp_v  [g][NPP_MRO][K] = `NPP_LM(g).group_mshr_resp_valid_o[t][p];
          assign npp_r  [g][NPP_MRO][K] = `NPP_LM(g).group_mshr_resp_ready_i[t][p];
          assign npp_w  [g][NPP_MRO][K] = NppBW'(1);
          assign npp_wen[g][NPP_MRO][K] = `NPP_LM(g).group_mshr_resp_o[t][p].wen;
        end
      end
`undef NPP_LM
    end
  end

  // ---- counters ----
  longint unsigned npp_cum_rd [NppNPt];     // read words since reset (occupancy source)
  longint unsigned npp_all [NppNPt], npp_rd [NppNPt];  // words in the period
  int unsigned     npp_hsk [NppNPt][NumGroups][NppK];  // handshakes per port in the period
  int unsigned     npp_stl [NppNPt][NumGroups][NppK];  // valid && !ready per port
  longint unsigned npp_occ [NppNSeg];       // summed occupancy in the period
  // crossbars: 0 = req, 1 = resp
  longint unsigned npp_x_in [2], npp_x_conf [2], npp_x_stall [2], npp_x_out [2];
  int unsigned     npp_cyc, npp_win;

  function automatic int unsigned npp_seg_a(input int unsigned s);
    return NPP_MOUT + s;  // MOUT->RINJ ... PLANE->MRSP
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      npp_cyc = 0; npp_win = 0;
      for (int x = 0; x < NppNPt; x++) begin
        npp_cum_rd[x] = 0; npp_all[x] = 0; npp_rd[x] = 0;
        for (int g = 0; g < NumGroups; g++)
          for (int k = 0; k < NppK; k++) begin npp_hsk[x][g][k] = 0; npp_stl[x][g][k] = 0; end
      end
      for (int s = 0; s < NppNSeg; s++) npp_occ[s] = 0;
      for (int c = 0; c < 2; c++) begin
        npp_x_in[c] = 0; npp_x_conf[c] = 0; npp_x_stall[c] = 0; npp_x_out[c] = 0;
      end
    end else begin
      npp_cyc = npp_cyc + 1;
      // cumulative read words: always, so occupancy is right whenever the window opens
      for (int x = 0; x < NppNPt; x++)
        for (int g = 0; g < NumGroups; g++)
          for (int k = 0; k < npp_nk(x); k++)
            if (npp_v[g][x][k] && npp_r[g][x][k]) begin
              automatic int unsigned w = (npp_w[g][x][k] == 0) ? 1 : npp_w[g][x][k];
              if (!npp_wen[g][x][k]) npp_cum_rd[x] += w;
              if (csr_trace_any_global) begin
                npp_all[x] += w;
                if (!npp_wen[g][x][k]) npp_rd[x] += w;
                npp_hsk[x][g][k] += 1;
              end
            end else if (npp_v[g][x][k] && csr_trace_any_global) begin
              npp_stl[x][g][k] += 1;
            end
      if (csr_trace_any_global) begin
        npp_win = npp_win + 1;
        for (int s = 0; s < NppNSeg; s++)
          npp_occ[s] += npp_cum_rd[npp_seg_a(s)] - npp_cum_rd[npp_seg_a(s) + 1];
        // local crossbars
        for (int g = 0; g < NumGroups; g++)
          for (int c = 0; c < 2; c++)
            for (int p = 0; p < NppP; p++) begin
              automatic int unsigned n [NumTilesPerGroup];
              for (int l = 0; l < NumTilesPerGroup; l++) n[l] = 0;
              for (int t = 0; t < NumTilesPerGroup; t++) begin
                automatic int unsigned k = t * NppP + p;
                automatic logic v = (c == 0) ? npp_xq_v[g][k] : npp_xp_v[g][k];
                automatic int unsigned sl = (c == 0) ? npp_xq_sel[g][k] : npp_xp_sel[g][k];
                if (v && sl < NumTilesPerGroup) n[sl] += 1;
              end
              for (int t = 0; t < NumTilesPerGroup; t++) begin
                automatic int unsigned k = t * NppP + p;
                automatic logic v  = (c == 0) ? npp_xq_v[g][k]  : npp_xp_v[g][k];
                automatic logic r  = (c == 0) ? npp_xq_r[g][k]  : npp_xp_r[g][k];
                automatic logic ov = (c == 0) ? npp_xq_ov[g][k] : npp_xp_ov[g][k];
                automatic logic orr = (c == 0) ? npp_xq_or[g][k] : npp_xp_or[g][k];
                automatic int unsigned sl = (c == 0) ? npp_xq_sel[g][k] : npp_xp_sel[g][k];
                if (v) begin
                  npp_x_in[c] += 1;
                  if (sl < NumTilesPerGroup && n[sl] > 1) npp_x_conf[c] += 1;
                  if (!r) npp_x_stall[c] += 1;
                end
                if (ov && orr) npp_x_out[c] += 1;
              end
            end
      end
      if (npp_win == `NPP_PERIOD) begin : npp_report
        automatic real den;
        for (int x = 0; x < NppNPt; x++) begin
          automatic longint unsigned hs = 0, st = 0;
          automatic int unsigned mx = 0, mg = 0, mk = 0, nk = npp_nk(x);
          for (int g = 0; g < NumGroups; g++)
            for (int k = 0; k < nk; k++) begin
              hs += npp_hsk[x][g][k]; st += npp_stl[x][g][k];
              if (npp_hsk[x][g][k] > mx) begin mx = npp_hsk[x][g][k]; mg = g; mk = k; end
            end
          den = real'(npp_win) * NumGroups * nk;
          $display("[NPP] cyc=%0d pt=%s wpc=%.2f rd_wpc=%.2f ports=%0d util=%.3f umax=%.3f@g%0d.k%0d stall_pc=%.3f stall_ph=%.2f",
                   npp_cyc, npp_name(x), real'(npp_all[x]) / npp_win, real'(npp_rd[x]) / npp_win,
                   NumGroups * nk, real'(hs) / den, real'(mx) / npp_win, mg, mk, real'(st) / den,
                   (hs > 0) ? real'(st) / hs : 0.0);
        end
        begin : npp_lat
          automatic string sl = "";
          automatic real tot = 0.0;
          for (int s = 0; s < NppNSeg; s++) begin
            automatic int unsigned a = npp_seg_a(s);
            automatic real l = (npp_rd[a + 1] > 0) ? real'(npp_occ[s]) / npp_rd[a + 1] : 0.0;
            tot += l;
            sl = {sl, $sformatf(" %s_%s=%.1f", npp_name(a), npp_name(a + 1), l)};
          end
          $display("[NPPL] cyc=%0d%s net=%.1f merge=%.2f mcast=%.2f drift=%0d",
                   npp_cyc, sl, tot,
                   (npp_rd[NPP_MOUT] > 0) ? real'(npp_rd[NPP_MIN]) / npp_rd[NPP_MOUT] : 0.0,
                   (npp_rd[NPP_MRSP] > 0) ? real'(npp_rd[NPP_MRO]) / npp_rd[NPP_MRSP] : 0.0,
                   longint'(npp_cum_rd[NPP_MOUT]) - longint'(npp_cum_rd[NPP_MRSP]));
        end
        for (int c = 0; c < 2; c++)
          $display("[NPPX] cyc=%0d xbar=%s in_pc=%.2f conflict=%.3f stall=%.3f out_pc=%.2f lanes=%0d",
                   npp_cyc, (c == 0) ? "req" : "resp",
                   real'(npp_x_in[c]) / (npp_win * NumGroups),
                   (npp_x_in[c] > 0) ? real'(npp_x_conf[c]) / npp_x_in[c] : 0.0,
                   (npp_x_in[c] > 0) ? real'(npp_x_stall[c]) / npp_x_in[c] : 0.0,
                   real'(npp_x_out[c]) / (npp_win * NumGroups), NppTK);
        npp_win = 0;
        for (int x = 0; x < NppNPt; x++) begin
          npp_all[x] = 0; npp_rd[x] = 0;
          for (int g = 0; g < NumGroups; g++)
            for (int k = 0; k < NppK; k++) begin npp_hsk[x][g][k] = 0; npp_stl[x][g][k] = 0; end
        end
        for (int s = 0; s < NppNSeg; s++) npp_occ[s] = 0;
        for (int c = 0; c < 2; c++) begin
          npp_x_in[c] = 0; npp_x_conf[c] = 0; npp_x_stall[c] = 0; npp_x_out[c] = 0;
        end
      end
    end
  end

`undef NPP_GRP

`endif
`endif
`endif
// pragma translate_on

`endif
