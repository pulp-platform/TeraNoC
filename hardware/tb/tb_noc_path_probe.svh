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
// [NPPC] the requesting side, outside the NoC (reads, words, per core per cycle): core-port read
//        requests split into inter-group (address group != own group: these enter the group MSHR)
//        and intra-group, core-port read responses, core-port request stalls (valid && !ready per
//        VLSU port-cycle), and the core-port round trip by Little's law (all read words; the [LDP]
//        latency minus this is reorder-buffer time). Core port -> MSHR and MSHR-internal latencies
//        are NOT reported: those point pairs do not conserve words (multicast, merges, intra-group
//        bursts that partly enter the MSHR).
// [NPPV] the Spatz vector load/store unit, fraction of core-cycles in each state: issue (some port
//        sends a request), active (an instruction is being issued but no port sends), idle_blk (idle,
//        the controller offers an LSU instruction the unit refuses), idle_none (idle, no LSU
//        instruction offered: dependencies or the instruction stream); vrf_wr / vrf_blk = cycles
//        the unit writes the register file / is refused a write; insn = LSU instructions accepted
//        per core per 1000 cycles.
// [NPPS] the source (serving) side: src_sat = share of tile-cycles in which BOTH remote response
//        ports of a tile send a word (the tile at its 2-word egress limit), src_blk = share of
//        tile-cycles in which a remote request waits at the tile's slave input, then per group the
//        response words sent per cycle (grp_wpc) and the blocked share (grp_blk), to expose
//        source-group hot spots that the machine-wide means average away.
// [NPPK] the Spatz controller's issue head, fraction of core-cycles: empty (no instruction from the
//        core), issue (an instruction leaves), full (all NrParallelInstructions ids in use), vfu /
//        vlsu / sld (the target unit is not ready); run = mean ids in use.
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


  // requesting side: core data ports 1..NumDataPortsPerCore-1 (the Spatz VLSU ports)
  localparam int unsigned NppCP  = NumCoresPerTile * (NumDataPortsPerCore - 1);
  localparam int unsigned NppCK  = NumTilesPerGroup * NppCP;
  localparam int unsigned NppGrpLsb = ByteOffset + $clog2(NumBanksPerTile) + $clog2(NumTilesPerGroup);
  logic [NumGroups-1:0][NppCK-1:0]            npp_cq_v, npp_cq_r, npp_cq_w, npp_cq_x, npp_cp_v, npp_cp_r, npp_cp_w;
  logic [NumGroups-1:0][NppCK-1:0][NppBW-1:0] npp_cq_bl;
  longint unsigned npp_c_reqx, npp_c_reqi, npp_c_rsp;          // cumulative read words
  longint unsigned npp_w_reqx, npp_w_reqi, npp_w_rsp, npp_w_stall;  // this period
  longint unsigned npp_o_core;                                      // summed occupancy

  // vector load/store unit, one per core
  localparam int unsigned NppNC = NumTilesPerGroup * NumCoresPerTile;
  logic [NumGroups-1:0][NppNC-1:0] npp_v_issue, npp_v_active, npp_v_offer, npp_v_acc, npp_v_we, npp_v_wok;
  longint unsigned npp_vs_issue, npp_vs_active, npp_vs_blk, npp_vs_none, npp_vs_we, npp_vs_wok, npp_vs_insn;

  // source side, accumulated per group
  longint unsigned npp_s_sat, npp_s_blk;
  longint unsigned npp_s_gw [NumGroups], npp_s_gb [NumGroups];

  // Spatz controller issue head, one per core
  logic [NumGroups-1:0][NppNC-1:0] npp_k_valid, npp_k_pop, npp_k_full, npp_k_vfu, npp_k_vlsu, npp_k_sld;
  logic [NumGroups-1:0][NppNC-1:0][3:0] npp_k_run;
  longint unsigned npp_ks_empty, npp_ks_issue, npp_ks_full, npp_ks_vfu, npp_ks_vlsu, npp_ks_sld, npp_ks_run;

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
    // Core data ports (requesting side)
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_npp_c_t
      for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_npp_c_c
        for (genvar p = 1; p < NumDataPortsPerCore; p++) begin : gen_npp_c_p
          localparam int unsigned K = (t * NumCoresPerTile + c) * (NumDataPortsPerCore - 1) + (p - 1);
          assign npp_cq_v [g][K] = `NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qvalid[c][p];
          assign npp_cq_r [g][K] = `NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qready[c][p];
          assign npp_cq_w [g][K] = `NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qwrite[c][p];
          assign npp_cq_bl[g][K] = `NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qburst_len[c][p];
          assign npp_cq_x [g][K] =
              (((`NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qaddr[c][p]) >> NppGrpLsb) &
               (NumGroups - 1)) != g;
          assign npp_cp_v [g][K] = `NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_pvalid[c][p];
          assign npp_cp_r [g][K] = `NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_pready[c][p];
          assign npp_cp_w [g][K] = `NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_pwrite[c][p];
        end
      end
    end
    // Vector load/store units
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_npp_v_t
      for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_npp_v_c
        localparam int unsigned K = t * NumCoresPerTile + c;
`define NPP_VLSU `NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_spatz.i_vlsu
        assign npp_v_issue [g][K] = |(`NPP_VLSU.spatz_mem_req_valid_o & `NPP_VLSU.spatz_mem_req_ready_i);
        assign npp_v_active[g][K] = `NPP_VLSU.mem_spatz_req_valid;
        assign npp_v_offer [g][K] = `NPP_VLSU.spatz_req_valid_i && (`NPP_VLSU.spatz_req_i.ex_unit == spatz_pkg::LSU);
        assign npp_v_acc   [g][K] = npp_v_offer[g][K] && `NPP_VLSU.spatz_req_ready_o;
        assign npp_v_we    [g][K] = `NPP_VLSU.vrf_we_o;
        assign npp_v_wok   [g][K] = `NPP_VLSU.vrf_we_o && `NPP_VLSU.vrf_wvalid_i;
`undef NPP_VLSU
`define NPP_CTRL `NPP_GRP(g).i_mempool_group.gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_spatz.i_controller
        assign npp_k_valid[g][K] = `NPP_CTRL.req_buffer_valid;
        assign npp_k_pop  [g][K] = `NPP_CTRL.req_buffer_pop;
        assign npp_k_full [g][K] = `NPP_CTRL.running_insn_full;
        assign npp_k_vfu  [g][K] = `NPP_CTRL.vfu_stall;
        assign npp_k_vlsu [g][K] = `NPP_CTRL.vlsu_stall;
        assign npp_k_sld  [g][K] = `NPP_CTRL.vsldu_stall;
        assign npp_k_run  [g][K] = 4'($countones(`NPP_CTRL.running_insn_q));
`undef NPP_CTRL
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
      npp_c_reqx = 0; npp_c_reqi = 0; npp_c_rsp = 0;
      npp_w_reqx = 0; npp_w_reqi = 0; npp_w_rsp = 0; npp_w_stall = 0;
      npp_o_core = 0;
      npp_vs_issue = 0; npp_vs_active = 0; npp_vs_blk = 0; npp_vs_none = 0;
      npp_vs_we = 0; npp_vs_wok = 0; npp_vs_insn = 0;
      npp_s_sat = 0; npp_s_blk = 0;
      for (int g = 0; g < NumGroups; g++) begin npp_s_gw[g] = 0; npp_s_gb[g] = 0; end
      npp_ks_empty = 0; npp_ks_issue = 0; npp_ks_full = 0; npp_ks_vfu = 0; npp_ks_vlsu = 0;
      npp_ks_sld = 0; npp_ks_run = 0;
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
      begin : npp_core_side
        for (int g = 0; g < NumGroups; g++)
          for (int k = 0; k < NppCK; k++) begin
            if (npp_cq_v[g][k] && npp_cq_r[g][k] && !npp_cq_w[g][k]) begin
              automatic int unsigned w = (npp_cq_bl[g][k] == 0) ? 1 : npp_cq_bl[g][k];
              if (npp_cq_x[g][k]) begin
                npp_c_reqx += w; if (csr_trace_any_global) npp_w_reqx += w;
              end else begin
                npp_c_reqi += w; if (csr_trace_any_global) npp_w_reqi += w;
              end
            end
            if (csr_trace_any_global && npp_cq_v[g][k] && !npp_cq_r[g][k]) npp_w_stall += 1;
            if (npp_cp_v[g][k] && npp_cp_r[g][k] && !npp_cp_w[g][k]) begin
              npp_c_rsp += 1; if (csr_trace_any_global) npp_w_rsp += 1;
            end
          end
        if (csr_trace_any_global) begin
          npp_o_core += longint'(npp_c_reqx + npp_c_reqi) - longint'(npp_c_rsp);
        end
      end
      if (csr_trace_any_global) begin : npp_source
        for (int g = 0; g < NumGroups; g++)
          for (int t = 0; t < NumTilesPerGroup; t++) begin
            automatic int unsigned sent = 0;
            automatic logic blk = 1'b0;
            for (int p = 0; p < NppP; p++) begin
              automatic int unsigned k = t * NppP + p;
              if (npp_v[g][NPP_SOUT][k] && npp_r[g][NPP_SOUT][k]) sent += 1;
              if (npp_v[g][NPP_SIN][k] && !npp_r[g][NPP_SIN][k]) blk = 1'b1;
            end
            if (sent == NppP) npp_s_sat += 1;
            if (blk) begin npp_s_blk += 1; npp_s_gb[g] += 1; end
            npp_s_gw[g] += sent;
          end
      end
      if (csr_trace_any_global) begin : npp_ctrl
        for (int g = 0; g < NumGroups; g++)
          for (int k = 0; k < NppNC; k++) begin
            npp_ks_run += npp_k_run[g][k];
            if (!npp_k_valid[g][k])      npp_ks_empty += 1;
            else if (npp_k_pop[g][k])    npp_ks_issue += 1;
            else if (npp_k_vfu[g][k])    npp_ks_vfu   += 1;
            else if (npp_k_vlsu[g][k])   npp_ks_vlsu  += 1;
            else if (npp_k_sld[g][k])    npp_ks_sld   += 1;
            else if (npp_k_full[g][k])   npp_ks_full  += 1;
          end
      end
      if (csr_trace_any_global) begin : npp_vlsu
        for (int g = 0; g < NumGroups; g++) begin
          npp_vs_issue  += $countones(npp_v_issue[g]);
          npp_vs_active += $countones(npp_v_active[g] & ~npp_v_issue[g]);
          npp_vs_blk    += $countones(~npp_v_active[g] & ~npp_v_issue[g] & npp_v_offer[g] & ~npp_v_acc[g]);
          npp_vs_none   += $countones(~npp_v_active[g] & ~npp_v_issue[g] & ~npp_v_offer[g]);
          npp_vs_we     += $countones(npp_v_we[g]);
          npp_vs_wok    += $countones(npp_v_wok[g]);
          npp_vs_insn   += $countones(npp_v_acc[g]);
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
        begin : npp_core_report
          automatic real ncore = real'(npp_win) * NumGroups * NumTilesPerGroup * NumCoresPerTile;
          $display("[NPPC] cyc=%0d creq_x_pc=%.3f creq_i_pc=%.3f crsp_pc=%.3f cq_stall_pc=%.3f lat_core=%.1f",
                   npp_cyc, real'(npp_w_reqx) / ncore, real'(npp_w_reqi) / ncore, real'(npp_w_rsp) / ncore,
                   real'(npp_w_stall) / (ncore * (NumDataPortsPerCore - 1)),
                   (npp_w_rsp        > 0) ? real'(npp_o_core) / npp_w_rsp        : 0.0);
          npp_w_reqx = 0; npp_w_reqi = 0; npp_w_rsp = 0; npp_w_stall = 0;
          npp_o_core = 0;
        end
        begin : npp_source_report
          automatic string sw = "", sb = "";
          automatic real nt = real'(npp_win) * NumGroups * NumTilesPerGroup;
          for (int g = 0; g < NumGroups; g++) begin
            sw = {sw, $sformatf((g == 0) ? "%.2f" : ",%.2f", real'(npp_s_gw[g]) / npp_win)};
            sb = {sb, $sformatf((g == 0) ? "%.3f" : ",%.3f",
                                real'(npp_s_gb[g]) / (real'(npp_win) * NumTilesPerGroup))};
            npp_s_gw[g] = 0; npp_s_gb[g] = 0;
          end
          $display("[NPPS] cyc=%0d src_sat=%.3f src_blk=%.3f grp_wpc=%s grp_blk=%s",
                   npp_cyc, real'(npp_s_sat) / nt, real'(npp_s_blk) / nt, sw, sb);
          npp_s_sat = 0; npp_s_blk = 0;
        end
        begin : npp_ctrl_report
          automatic real nc = real'(npp_win) * NumGroups * NppNC;
          $display("[NPPK] cyc=%0d empty=%.3f issue=%.3f full=%.3f vfu=%.3f vlsu=%.3f sld=%.3f run=%.2f",
                   npp_cyc, real'(npp_ks_empty) / nc, real'(npp_ks_issue) / nc, real'(npp_ks_full) / nc,
                   real'(npp_ks_vfu) / nc, real'(npp_ks_vlsu) / nc, real'(npp_ks_sld) / nc,
                   real'(npp_ks_run) / nc);
          npp_ks_empty = 0; npp_ks_issue = 0; npp_ks_full = 0; npp_ks_vfu = 0; npp_ks_vlsu = 0;
          npp_ks_sld = 0; npp_ks_run = 0;
        end
        begin : npp_vlsu_report
          automatic real nc = real'(npp_win) * NumGroups * NppNC;
          $display("[NPPV] cyc=%0d issue=%.3f active=%.3f idle_blk=%.3f idle_none=%.3f vrf_wr=%.3f vrf_blk=%.3f insn=%.1f",
                   npp_cyc, real'(npp_vs_issue) / nc, real'(npp_vs_active) / nc, real'(npp_vs_blk) / nc,
                   real'(npp_vs_none) / nc, real'(npp_vs_wok) / nc, real'(npp_vs_we - npp_vs_wok) / nc,
                   1000.0 * real'(npp_vs_insn) / nc);
          npp_vs_issue = 0; npp_vs_active = 0; npp_vs_blk = 0; npp_vs_none = 0;
          npp_vs_we = 0; npp_vs_wok = 0; npp_vs_insn = 0;
        end
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
