// ============================================================================
// tb_system_overview.svh — machine-wide per-cycle indicators for the waveform.
// Include inside mempool_tb module.
//
// The per-instance waves (one group per router, eight per group MSHR) run to thousands of
// entries at 8x8 and give no view of the whole machine. These are the whole-machine counts,
// per cycle, in the style of the Utilization group: one analog trace per class, with the
// per-direction / per-family / per-group breakdown one level down.
//
//   TCDM mesh, per router class (narrow req, wide req, resp), per OUTPUT direction N/E/S/W:
//     ov_<cls>_hsk      flits that left a router this cycle   (valid & ready)
//     ov_<cls>_stall    flits held at a router output          (valid & !ready)
//     ov_<cls>_hsk_dir[d], ov_<cls>_stall_dir[d]   the same, per direction
//   AXI wide mesh (DMA path), per output direction: ov_axiw_hsk / ov_axiw_stall (+ _dir).
//   Group MSHR, per family (0 = row slices R0..R3 = bursts, 1 = column slices C0..C3 = singles;
//   legacy single MSHR counts as family 0):
//     ov_mshr_inuse[f]        entries in flight (not counting response-cache lines)
//     ov_mshr_cached[f]       response-cache lines held
//     ov_mshr_full[f]         slices whose banked table is completely valid
//     ov_mshr_req_hsk[f]      tile requests accepted;   ov_mshr_req_stall[f]  refused
//     ov_mshr_merge[f]        accepted requests that merged into an existing entry
//     ov_mshr_alloc[f]        accepted requests that allocated a new entry
//     ov_mshr_bypass[f]       mergeable requests that bypassed because their bank was full
//     ov_mshr_noc_req_hsk[f]  requests sent to the NoC; ov_mshr_noc_req_stall[f] blocked there
//     ov_mshr_noc_resp_hsk[f] responses taken from the NoC; ov_mshr_noc_resp_stall[f] refused
//                             (the MSHR back-pressuring the response network)
//     ov_mshr_resp_hsk[f]     responses delivered to tiles; ov_mshr_resp_stall[f] refused
//     ov_mshr_inuse_grp[g]    entries in flight per group (skew across the mesh)
//
// Simulation only; every reference is inside a genvar loop (cross-module references into
// generate arrays need constant indices). Disable with +define+SYS_OVERVIEW_DISABLE.
// ============================================================================

`ifndef TB_SYSTEM_OVERVIEW_SVH
`define TB_SYSTEM_OVERVIEW_SVH

// pragma translate_off
`ifndef VERILATOR

`define OV_GRP(G) dut.i_mempool_cluster.gen_groups_x[(G)/NumY].gen_groups_y[(G)%NumY].gen_rtl_group.i_group
`define OV_MSHR_S(G,M) `OV_GRP(G).i_mempool_group.gen_group_mshr_split.gen_slice[M].i_slice.i_core
`define OV_MSHR_L(G) `OV_GRP(G).i_mempool_group.gen_group_mshr.i_group_mshr

  localparam int unsigned OvDirs = 4;  // North, East, South, West: the mesh output ports

  // ---- TCDM mesh ------------------------------------------------------------------------
  int unsigned ov_nreq_hsk_g [NumGroups][OvDirs], ov_nreq_stall_g [NumGroups][OvDirs];
  int unsigned ov_wreq_hsk_g [NumGroups][OvDirs], ov_wreq_stall_g [NumGroups][OvDirs];
  int unsigned ov_resp_hsk_g [NumGroups][OvDirs], ov_resp_stall_g [NumGroups][OvDirs];
  int unsigned ov_axiw_hsk_g [NumGroups][OvDirs], ov_axiw_stall_g [NumGroups][OvDirs];

  for (genvar g = 0; g < NumGroups; g++) begin : gen_ov_noc_g
    for (genvar d = 0; d < OvDirs; d++) begin : gen_ov_noc_d
      // The narrow request routers exist only with USE_NARROW_REQ_CHANNEL (the wrapper
      // declares their links under the same define).
`ifdef USE_NARROW_REQ_CHANNEL
      assign ov_nreq_hsk_g[g][d] = $countones(`OV_GRP(g).floo_tcdm_narrow_req_valid_out[d] &
                                              `OV_GRP(g).floo_tcdm_narrow_req_ready_in[d]);
      assign ov_nreq_stall_g[g][d] = $countones(`OV_GRP(g).floo_tcdm_narrow_req_valid_out[d] &
                                                ~`OV_GRP(g).floo_tcdm_narrow_req_ready_in[d]);
`else
      assign ov_nreq_hsk_g[g][d]   = 0;
      assign ov_nreq_stall_g[g][d] = 0;
`endif
      assign ov_wreq_hsk_g[g][d] = $countones(`OV_GRP(g).floo_tcdm_wide_req_valid_out[d] &
                                              `OV_GRP(g).floo_tcdm_wide_req_ready_in[d]);
      assign ov_wreq_stall_g[g][d] = $countones(`OV_GRP(g).floo_tcdm_wide_req_valid_out[d] &
                                                ~`OV_GRP(g).floo_tcdm_wide_req_ready_in[d]);
      assign ov_resp_hsk_g[g][d] = $countones(`OV_GRP(g).floo_tcdm_resp_valid_out[d] &
                                              `OV_GRP(g).floo_tcdm_resp_ready_in[d]);
      assign ov_resp_stall_g[g][d] = $countones(`OV_GRP(g).floo_tcdm_resp_valid_out[d] &
                                                ~`OV_GRP(g).floo_tcdm_resp_ready_in[d]);
      // FlooNoC link convention: the input ready travels in the router's OUTPUT struct, so a
      // flit leaves on port d when out[d].valid meets in[d].ready (as tb_dma_profiling).
      assign ov_axiw_hsk_g[g][d]   = `OV_GRP(g).floo_axi_wide_out[d].valid &
                                     `OV_GRP(g).floo_axi_wide_in[d].ready;
      assign ov_axiw_stall_g[g][d] = `OV_GRP(g).floo_axi_wide_out[d].valid &
                                     !`OV_GRP(g).floo_axi_wide_in[d].ready;
    end
  end

  int unsigned ov_nreq_hsk, ov_nreq_stall, ov_wreq_hsk, ov_wreq_stall;
  int unsigned ov_resp_hsk, ov_resp_stall, ov_axiw_hsk, ov_axiw_stall;
  int unsigned ov_nreq_hsk_dir [OvDirs], ov_nreq_stall_dir [OvDirs];
  int unsigned ov_wreq_hsk_dir [OvDirs], ov_wreq_stall_dir [OvDirs];
  int unsigned ov_resp_hsk_dir [OvDirs], ov_resp_stall_dir [OvDirs];
  int unsigned ov_axiw_hsk_dir [OvDirs], ov_axiw_stall_dir [OvDirs];

  always_comb begin
    ov_nreq_hsk = 0; ov_nreq_stall = 0; ov_wreq_hsk = 0; ov_wreq_stall = 0;
    ov_resp_hsk = 0; ov_resp_stall = 0; ov_axiw_hsk = 0; ov_axiw_stall = 0;
    for (int d = 0; d < OvDirs; d++) begin
      ov_nreq_hsk_dir[d] = 0; ov_nreq_stall_dir[d] = 0;
      ov_wreq_hsk_dir[d] = 0; ov_wreq_stall_dir[d] = 0;
      ov_resp_hsk_dir[d] = 0; ov_resp_stall_dir[d] = 0;
      ov_axiw_hsk_dir[d] = 0; ov_axiw_stall_dir[d] = 0;
      for (int g = 0; g < NumGroups; g++) begin
        ov_nreq_hsk_dir[d]   += ov_nreq_hsk_g[g][d];
        ov_nreq_stall_dir[d] += ov_nreq_stall_g[g][d];
        ov_wreq_hsk_dir[d]   += ov_wreq_hsk_g[g][d];
        ov_wreq_stall_dir[d] += ov_wreq_stall_g[g][d];
        ov_resp_hsk_dir[d]   += ov_resp_hsk_g[g][d];
        ov_resp_stall_dir[d] += ov_resp_stall_g[g][d];
        ov_axiw_hsk_dir[d]   += ov_axiw_hsk_g[g][d];
        ov_axiw_stall_dir[d] += ov_axiw_stall_g[g][d];
      end
      ov_nreq_hsk += ov_nreq_hsk_dir[d]; ov_nreq_stall += ov_nreq_stall_dir[d];
      ov_wreq_hsk += ov_wreq_hsk_dir[d]; ov_wreq_stall += ov_wreq_stall_dir[d];
      ov_resp_hsk += ov_resp_hsk_dir[d]; ov_resp_stall += ov_resp_stall_dir[d];
      ov_axiw_hsk += ov_axiw_hsk_dir[d]; ov_axiw_stall += ov_axiw_stall_dir[d];
    end
  end

  // ---- Group MSHR -----------------------------------------------------------------------
  localparam int unsigned OvSlices = MshrSplit ? 8 : 1;
  int unsigned ov_sl_inuse   [NumGroups][OvSlices], ov_sl_cached   [NumGroups][OvSlices];
  int unsigned ov_sl_full    [NumGroups][OvSlices];
  int unsigned ov_sl_req_hsk [NumGroups][OvSlices], ov_sl_req_stall[NumGroups][OvSlices];
  int unsigned ov_sl_merge   [NumGroups][OvSlices], ov_sl_alloc    [NumGroups][OvSlices];
  int unsigned ov_sl_bypass  [NumGroups][OvSlices];
  int unsigned ov_sl_nreq_hsk[NumGroups][OvSlices], ov_sl_nreq_stall[NumGroups][OvSlices];
  int unsigned ov_sl_nrsp_hsk[NumGroups][OvSlices], ov_sl_nrsp_stall[NumGroups][OvSlices];
  int unsigned ov_sl_rsp_hsk [NumGroups][OvSlices], ov_sl_rsp_stall [NumGroups][OvSlices];

  // One MSHR core's counts into slot (G, M): shared by the split slices and the legacy MSHR.
`define OV_MSHR_COUNTS(G, M, C) \
      assign ov_sl_inuse[G][M]      = C.mshr_inuse_cnt_dbg; \
      assign ov_sl_cached[G][M]     = C.mshr_cached_cnt_dbg; \
      assign ov_sl_full[G][M]       = &C.mshr_q_valid; \
      assign ov_sl_req_hsk[G][M]    = $countones(C.group_mshr_req_valid_i & C.group_mshr_req_ready_o); \
      assign ov_sl_req_stall[G][M]  = $countones(C.group_mshr_req_valid_i & ~C.group_mshr_req_ready_o); \
      assign ov_sl_merge[G][M]      = $countones(C.group_mshr_req_valid_i & C.group_mshr_req_ready_o & \
                                                 C.req_merge_valid); \
      assign ov_sl_alloc[G][M]      = $countones(C.group_mshr_req_valid_i & C.group_mshr_req_ready_o & \
                                                 C.req_alloc_found); \
      assign ov_sl_bypass[G][M]     = $countones(C.req_bankfull_bypass_dbg); \
      assign ov_sl_nreq_hsk[G][M]   = $countones(C.mshr_noc_req_valid_o & C.mshr_noc_req_ready_i); \
      assign ov_sl_nreq_stall[G][M] = $countones(C.mshr_noc_req_valid_o & ~C.mshr_noc_req_ready_i); \
      assign ov_sl_nrsp_hsk[G][M]   = $countones(C.mshr_noc_resp_valid_i & C.mshr_noc_resp_ready_o); \
      assign ov_sl_nrsp_stall[G][M] = $countones(C.mshr_noc_resp_valid_i & ~C.mshr_noc_resp_ready_o); \
      assign ov_sl_rsp_hsk[G][M]    = $countones(C.group_mshr_resp_valid_o & C.group_mshr_resp_ready_i); \
      assign ov_sl_rsp_stall[G][M]  = $countones(C.group_mshr_resp_valid_o & ~C.group_mshr_resp_ready_i);

  if (MshrSplit) begin : gen_ov_mshr_split
    for (genvar g = 0; g < NumGroups; g++) begin : gen_ov_g
      for (genvar m = 0; m < OvSlices; m++) begin : gen_ov_m
        `OV_MSHR_COUNTS(g, m, `OV_MSHR_S(g, m))
      end
    end
  end else begin : gen_ov_mshr_legacy
    for (genvar g = 0; g < NumGroups; g++) begin : gen_ov_g
      `OV_MSHR_COUNTS(g, 0, `OV_MSHR_L(g))
    end
  end
`undef OV_MSHR_COUNTS

  int unsigned ov_mshr_inuse [2], ov_mshr_cached [2], ov_mshr_full [2];
  int unsigned ov_mshr_req_hsk [2], ov_mshr_req_stall [2], ov_mshr_merge [2], ov_mshr_alloc [2];
  int unsigned ov_mshr_bypass [2];
  int unsigned ov_mshr_noc_req_hsk [2], ov_mshr_noc_req_stall [2];
  int unsigned ov_mshr_noc_resp_hsk [2], ov_mshr_noc_resp_stall [2];
  int unsigned ov_mshr_resp_hsk [2], ov_mshr_resp_stall [2];
  int unsigned ov_mshr_inuse_grp [NumGroups];

  always_comb begin
    for (int f = 0; f < 2; f++) begin
      ov_mshr_inuse[f] = 0; ov_mshr_cached[f] = 0; ov_mshr_full[f] = 0;
      ov_mshr_req_hsk[f] = 0; ov_mshr_req_stall[f] = 0; ov_mshr_merge[f] = 0;
      ov_mshr_alloc[f] = 0; ov_mshr_bypass[f] = 0;
      ov_mshr_noc_req_hsk[f] = 0; ov_mshr_noc_req_stall[f] = 0;
      ov_mshr_noc_resp_hsk[f] = 0; ov_mshr_noc_resp_stall[f] = 0;
      ov_mshr_resp_hsk[f] = 0; ov_mshr_resp_stall[f] = 0;
    end
    for (int g = 0; g < NumGroups; g++) begin
      ov_mshr_inuse_grp[g] = 0;
      for (int m = 0; m < OvSlices; m++) begin
        automatic int f = (m < 4) ? 0 : 1;   // rows R0..R3 = bursts, columns C0..C3 = singles
        ov_mshr_inuse_grp[g]     += ov_sl_inuse[g][m];
        ov_mshr_inuse[f]         += ov_sl_inuse[g][m];
        ov_mshr_cached[f]        += ov_sl_cached[g][m];
        ov_mshr_full[f]          += ov_sl_full[g][m];
        ov_mshr_req_hsk[f]       += ov_sl_req_hsk[g][m];
        ov_mshr_req_stall[f]     += ov_sl_req_stall[g][m];
        ov_mshr_merge[f]         += ov_sl_merge[g][m];
        ov_mshr_alloc[f]         += ov_sl_alloc[g][m];
        ov_mshr_bypass[f]        += ov_sl_bypass[g][m];
        ov_mshr_noc_req_hsk[f]   += ov_sl_nreq_hsk[g][m];
        ov_mshr_noc_req_stall[f] += ov_sl_nreq_stall[g][m];
        ov_mshr_noc_resp_hsk[f]  += ov_sl_nrsp_hsk[g][m];
        ov_mshr_noc_resp_stall[f]+= ov_sl_nrsp_stall[g][m];
        ov_mshr_resp_hsk[f]      += ov_sl_rsp_hsk[g][m];
        ov_mshr_resp_stall[f]    += ov_sl_rsp_stall[g][m];
      end
    end
  end

`undef OV_GRP
`undef OV_MSHR_S
`undef OV_MSHR_L

`endif
// pragma translate_on

`endif
