// ============================================================================
// tb_noc_req_resp_tracer.svh — per-flit NoC request/response event tracer
// ----------------------------------------------------------------------------
// Records every remote TCDM REQUEST and RESPONSE as it crosses the NoC datapath
// to a single CSV (noc_trace/events.csv). A companion Python script
// (hardware/scripts/analyze_noc_trace.py) reconstructs each transaction's path
// and pinpoints WHERE/WHEN a request or response is lost or stuck, the per
// transaction req->resp latency, and the NoC congestion points.
//
// Why this works: a remote transaction carries a STABLE identity
//   (owner_group, owner_tile, core_id, meta_id)
// from the core port -> group MSHR -> NoC flit -> remote slave -> and all the
// way back. The MSHR does not rewrite meta_id/core_id on the request side and
// reconstructs them from its sub-request record on the response side, so the
// same 4-tuple keys the transaction at every observation point. Every tap below
// emits that normalized key ("og,ot,core,mid") plus the local observation
// location ("loc_g,loc_t,loc_p") and the stage name, so the analyzer can stitch
// the life of one transaction across layers.
//
// Tap layers (Tier-1, always on — all robust module/tile-port XMRs):
//   CORE_REQ / CORE_RSP   @ gen_tiles[t].i_tile.snitch_data_{q,p}*[c][p]
//   MSHR_REQ_IN/REQ_OUT/RSP_IN/RSP_OUT @ gen_group_mshr.i_group_mshr.*
//   SLAVE_REQ_IN / SLAVE_RSP_OUT       @ destination tile tcdm_slave_{req,resp}*
// Tier-2 (define TRACER_TRACE_HOPS) — per-hop mesh router directional taps.
//
// Include inside the mempool_tb module (after tb_noc_bottleneck_profiling.svh).
// Gating: csr_trace_any_global (benchmark window) AND an optional time window
//   via +tracer_lo_ns=<ns> / +tracer_hi_ns=<ns>; disable entirely with +notracer.
// ============================================================================

`ifndef TB_NOC_REQ_RESP_TRACER_SVH
`define TB_NOC_REQ_RESP_TRACER_SVH

// pragma translate_off
`ifndef VERILATOR

// ---- Hierarchy-path shorthands (genvar-indexed; constant in generate scope) --
`define TR_TILE(G,T) dut.i_mempool_cluster.gen_groups_x[(G)/NumY].gen_groups_y[(G)%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[T].i_tile
`define TR_MSHR(G)   dut.i_mempool_cluster.gen_groups_x[(G)/NumY].gen_groups_y[(G)%NumY].gen_rtl_group.i_group.i_mempool_group.gen_group_mshr.i_group_mshr
`define TR_RTR(G,T)  dut.i_mempool_cluster.gen_groups_x[(G)/NumY].gen_groups_y[(G)%NumY].gen_rtl_group.i_group.gen_router_router_i[T]

// ---- One CSV row. Guarded by `if (tracer_active)` at the call site. ----------
// Columns: time_ns,cyc,stage,loc_g,loc_t,loc_p,og,ot,core,mid,addr,tgt_g,tgt_t,
//          tgt_bank,wen,burst,amo,data,mshr,sub,flags
`define TR_ROW(STAGE,LG,LT,LP,OG,OT,CORE,MID,ADDR,TGTG,TGTT,TGTB,WEN,BURST,AMO,DAT,MSHR,SUB,FLAGS) \
  $fwrite(tracer_fd, "%0d,%0d,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08x,%0d,%0d,%0d,%0d,%0d,%0d,%08x,%0d,%0d,%s\n", \
    $time, tracer_cycle, STAGE, LG, LT, LP, OG, OT, CORE, MID, ADDR, TGTG, TGTT, TGTB, WEN, BURST, AMO, DAT, MSHR, SUB, FLAGS)

// ---- Address-field geometry (computed from params; interleaved TCDM region) --
localparam int unsigned TR_BankBits  = $clog2(NumBanksPerTile);
localparam int unsigned TR_TileBits  = $clog2(NumTilesPerGroup);
localparam int unsigned TR_GroupBits = $clog2(NumGroups);
localparam int unsigned TR_BankLsb   = ByteOffset;
localparam int unsigned TR_TileLsb   = ByteOffset + TR_BankBits;
localparam int unsigned TR_GroupLsb  = ByteOffset + TR_BankBits + TR_TileBits;

// Decode (raw byte address -> destination group/tile/bank). Valid for the
// interleaved region (addr >= sequential-region end, ~0x20000); the matmul data
// traffic and the 0x52c08 case are all interleaved. Sequential-region addresses
// (rare here) may mis-decode and are harmless for correlation (which uses the key).
function automatic int unsigned tr_g(input logic [31:0] a);
  return (a >> TR_GroupLsb) & ((1 << TR_GroupBits) - 1);
endfunction
function automatic int unsigned tr_t(input logic [31:0] a);
  return (a >> TR_TileLsb) & ((1 << TR_TileBits) - 1);
endfunction
function automatic int unsigned tr_b(input logic [31:0] a);
  return (a >> TR_BankLsb) & ((1 << TR_BankBits) - 1);
endfunction
// Bank index inside a tile-relative slave address (tile_addr layout: low bits = bank).
function automatic int unsigned tr_slvbank(input logic [31:0] a);
  return a & ((1 << TR_BankBits) - 1);
endfunction

// ---- State / control -------------------------------------------------------
integer       tracer_fd;
longint unsigned tracer_cycle;
logic         tracer_en;
longint unsigned tracer_lo_ns;
longint unsigned tracer_hi_ns;
logic         tracer_active;
string        tracer_dir;
string        tracer_path;

initial begin
  int notr;
  tracer_dir   = "noc_trace";
  tracer_en    = 1'b1;
  tracer_lo_ns = 0;
  tracer_hi_ns = 64'hFFFF_FFFF_FFFF_FFFF;
  void'($value$plusargs("tracer_lo_ns=%d", tracer_lo_ns));
  void'($value$plusargs("tracer_hi_ns=%d", tracer_hi_ns));
  void'($value$plusargs("tracer_dir=%s",   tracer_dir));
  if ($value$plusargs("notracer=%d", notr)) tracer_en = 1'b0;
  if ($test$plusargs("notracer"))           tracer_en = 1'b0;

  if (tracer_en) begin
    void'($system($sformatf("mkdir -p %s", tracer_dir)));
    tracer_path = $sformatf("%s/events.csv", tracer_dir);
    tracer_fd   = $fopen(tracer_path, "w");
    if (tracer_fd == 0) begin
      $display("[TRACER] ERROR: could not open %s — disabling tracer", tracer_path);
      tracer_en = 1'b0;
    end else begin
      $fwrite(tracer_fd,
        "time_ns,cyc,stage,loc_g,loc_t,loc_p,og,ot,core,mid,addr,tgt_g,tgt_t,tgt_bank,wen,burst,amo,data,mshr,sub,flags\n");
      $display("[TRACER] logging NoC req/resp events to %s (window [%0d,%0d] ns)",
               tracer_path, tracer_lo_ns, tracer_hi_ns);
    end
  end
end

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) tracer_cycle <= 0;
  else        tracer_cycle <= tracer_cycle + 1;
end

assign tracer_active = tracer_en && csr_trace_any_global &&
                       (longint'($time) >= tracer_lo_ns) &&
                       (longint'($time) <= tracer_hi_ns);

// ===========================================================================
// L0 — CORE / TILE data ports (req issued + resp received at the core).
//      p = 0 is the shared scalar port (Snitch int LSU + Spatz FP-LSU, e.g. flw);
//      p = 1..NumMemPortsPerSpatz are the Spatz VLSU vector ports.
// ===========================================================================
for (genvar g = 0; g < NumGroups; g++) begin : gen_tr_core_g
  for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_tr_core_t
    for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_tr_core_c
      for (genvar p = 0; p < NumDataPortsPerCore; p++) begin : gen_tr_core_p
        always @(posedge clk) begin : tr_core_blk
          logic [31:0] qa;
          if (tracer_active) begin
            // request
            if (`TR_TILE(g,t).snitch_data_qvalid[c][p] && `TR_TILE(g,t).snitch_data_qready[c][p]) begin
              qa = `TR_TILE(g,t).snitch_data_qaddr[c][p];
              `TR_ROW("CORE_REQ", g, t, p, g, t, c, `TR_TILE(g,t).snitch_data_qid[c][p],
                      qa, tr_g(qa), tr_t(qa), tr_b(qa),
                      `TR_TILE(g,t).snitch_data_qwrite[c][p], `TR_TILE(g,t).snitch_data_qburst_len[c][p],
                      0, 32'h0, -1, -1, "req");
            end
            // response
            if (`TR_TILE(g,t).snitch_data_pvalid[c][p] && `TR_TILE(g,t).snitch_data_pready[c][p]) begin
              `TR_ROW("CORE_RSP", g, t, p, g, t, c, `TR_TILE(g,t).snitch_data_pid[c][p],
                      32'h0, -1, -1, -1, 0, 0, 0, `TR_TILE(g,t).snitch_data_pdata[c][p],
                      -1, -1, "rsp");
            end
          end
        end
      end
    end
  end
end

// ===========================================================================
// L1 — GROUP MSHR (req ingress/egress + resp ingress/egress). Port index p
//      starts at 1 (p=0 is the intra-group local port, not MSHR-managed).
//      Array index [t] is the requester tile within this group -> owner key
//      (g, t, *.core_id, *.meta_id).
// ===========================================================================
for (genvar g = 0; g < NumGroups; g++) begin : gen_tr_mshr_g
  for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_tr_mshr_t
    // ---- request ports (1..NumRemoteReqPortsPerTile-1) ----
    for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_tr_mshr_rq
      always @(posedge clk) begin : tr_mshr_req_blk
        tcdm_master_req_t rq;
        string fl;
        if (tracer_active) begin
          // ingress from tiles
          if (`TR_MSHR(g).group_mshr_req_valid_i[t][p] && `TR_MSHR(g).group_mshr_req_ready_o[t][p]) begin
            rq = `TR_MSHR(g).group_mshr_req_i[t][p];
            fl = `TR_MSHR(g).req_merge_valid[t][p] ? "merge" :
                 (`TR_MSHR(g).req_alloc_found[t][p] ? "alloc" : "fwd");
            `TR_ROW("MSHR_REQ_IN", g, t, p, g, t, rq.wdata.core_id, rq.wdata.meta_id,
                    rq.tgt_addr, rq.tgt_group_id, -1, -1, rq.wen, rq.burst_len,
                    rq.wdata.amo, rq.wdata.data, -1, -1, fl);
          end
          // egress toward NoC
          if (`TR_MSHR(g).mshr_noc_req_valid_o[t][p] && `TR_MSHR(g).mshr_noc_req_ready_i[t][p]) begin
            rq = `TR_MSHR(g).mshr_noc_req_o[t][p];
            `TR_ROW("MSHR_REQ_OUT", g, t, p, g, t, rq.wdata.core_id, rq.wdata.meta_id,
                    rq.tgt_addr, rq.tgt_group_id, -1, -1, rq.wen, rq.burst_len,
                    rq.wdata.amo, rq.wdata.data, -1, -1, "noc");
          end
        end
      end
    end
    // ---- response ports (1..NumRemoteRespPortsPerTile-1) ----
    for (genvar p = 1; p < NumRemoteRespPortsPerTile; p++) begin : gen_tr_mshr_rp
      always @(posedge clk) begin : tr_mshr_rsp_blk
        tcdm_master_resp_t rs;
        string fl;
        if (tracer_active) begin
          // ingress from NoC
          if (`TR_MSHR(g).mshr_noc_resp_valid_i[t][p] && `TR_MSHR(g).mshr_noc_resp_ready_o[t][p]) begin
            rs = `TR_MSHR(g).mshr_noc_resp_i[t][p];
            fl = `TR_MSHR(g).resp_is_mshr[t][p] ? "ismshr" : "bypass";
            `TR_ROW("MSHR_RSP_IN", g, t, p, g, t, rs.rdata.core_id, rs.rdata.meta_id,
                    32'h0, -1, -1, -1, rs.wen, 0, rs.rdata.amo, rs.rdata.data,
                    `TR_MSHR(g).resp_mshr_id[t][p], -1, fl);
          end
          // egress toward tiles (multicast)
          if (`TR_MSHR(g).group_mshr_resp_valid_o[t][p] && `TR_MSHR(g).group_mshr_resp_ready_i[t][p]) begin
            rs = `TR_MSHR(g).group_mshr_resp_o[t][p];
            fl = `TR_MSHR(g).resp_from_mshr[t][p] ? "frommshr" :
                 (`TR_MSHR(g).resp_from_bypass[t][p] ? "bypass" : "drain");
            `TR_ROW("MSHR_RSP_OUT", g, t, p, g, t, rs.rdata.core_id, rs.rdata.meta_id,
                    32'h0, -1, -1, -1, rs.wen, 0, rs.rdata.amo, rs.rdata.data,
                    `TR_MSHR(g).resp_sel_mshr_id[t][p], `TR_MSHR(g).resp_sel_subreq_idx[t][p], fl);
          end
        end
      end
    end
  end
end

// ===========================================================================
// L3 — REMOTE SLAVE (destination tile): did the request reach memory and did
//      the response leave it? Location = slave (g,t); the OWNER key is carried
//      in the slave payload (src_group_id, ini_addr, core_id, meta_id).
//      Slave ports 1..N-1 carry NoC-arrived traffic (port 0 = intra-group).
// ===========================================================================
for (genvar g = 0; g < NumGroups; g++) begin : gen_tr_slv_g
  for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_tr_slv_t
    for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_tr_slv_rq
      always @(posedge clk) begin : tr_slv_req_blk
        tcdm_slave_req_t sq;
        if (tracer_active) begin
          if (`TR_TILE(g,t).tcdm_slave_req_valid_i[p] && `TR_TILE(g,t).tcdm_slave_req_ready_o[p]) begin
            sq = `TR_TILE(g,t).tcdm_slave_req_i[p];
            `TR_ROW("SLAVE_REQ_IN", g, t, p, sq.src_group_id, sq.ini_addr, sq.wdata.core_id, sq.wdata.meta_id,
                    sq.tgt_addr, g, t, tr_slvbank(sq.tgt_addr), sq.wen, sq.burst_len,
                    sq.wdata.amo, sq.wdata.data, -1, -1, "slvreq");
          end
        end
      end
    end
    for (genvar p = 1; p < NumRemoteRespPortsPerTile; p++) begin : gen_tr_slv_rp
      always @(posedge clk) begin : tr_slv_rsp_blk
        tcdm_slave_resp_t ss;
        if (tracer_active) begin
          if (`TR_TILE(g,t).tcdm_slave_resp_valid_o[p] && `TR_TILE(g,t).tcdm_slave_resp_ready_i[p]) begin
            ss = `TR_TILE(g,t).tcdm_slave_resp_o[p];
            `TR_ROW("SLAVE_RSP_OUT", g, t, p, ss.src_group_id, ss.ini_addr, ss.rdata.core_id, ss.rdata.meta_id,
                    32'h0, ss.src_group_id, ss.ini_addr, -1, ss.wen, 0,
                    ss.rdata.amo, ss.rdata.data, -1, -1, "slvrsp");
          end
        end
      end
    end
  end
end

// ===========================================================================
// L2 — Per-hop mesh ROUTER directional outputs (opt-in: define TRACER_TRACE_HOPS).
//      Mirrors the proven tb_noc_visualization XMR paths. dir 0..3 = N/E/S/W.
//      Normalized key recovered from the flit header.
// ===========================================================================
`ifdef TRACER_TRACE_HOPS
for (genvar g = 0; g < NumGroups; g++) begin : gen_tr_hop_g
  for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_tr_hop_t
    // ---- wide request routers ----
    for (genvar j = 0; j < NumWideRemoteReqPortsPerTile; j++) begin : gen_tr_hop_rq
      for (genvar d = 0; d < 4; d++) begin : gen_tr_hop_rqd
        always @(posedge clk) begin : tr_hop_req_blk
          logic [31:0] ha;
          if (tracer_active) begin
            if (`TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.valid_o[d][0] &&
                `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.ready_i[d][0]) begin
              ha = `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].hdr.tgt_addr;
              `TR_ROW("RTR_REQ", g, t, d,
                      `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].hdr.src_id.x * NumY +
                      `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].hdr.src_id.y,
                      `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].hdr.src_tile_id,
                      `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].hdr.core_id,
                      `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].hdr.meta_id,
                      ha,
                      `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].hdr.dst_id.x * NumY +
                      `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].hdr.dst_id.y,
                      -1, -1,
                      `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].payload.wen,
                      `TR_RTR(g,t).gen_router_wide_req_router_j[j].gen_2dmesh.i_floo_tcdm_wide_req_router.data_o[d][0].hdr.burst_len,
                      0, 32'h0, -1, d, "NESW");
            end
          end
        end
      end
    end
    // ---- wide response routers (index 1..N-1) ----
    for (genvar p = 1; p < NumRemoteRespPortsPerTile; p++) begin : gen_tr_hop_rp
      for (genvar d = 0; d < 4; d++) begin : gen_tr_hop_rpd
        always @(posedge clk) begin : tr_hop_rsp_blk
          if (tracer_active) begin
            if (`TR_RTR(g,t).gen_router_wide_resp_router_j[p].gen_2dmesh.i_floo_tcdm_wide_resp_router.valid_o[d][0] &&
                `TR_RTR(g,t).gen_router_wide_resp_router_j[p].gen_2dmesh.i_floo_tcdm_wide_resp_router.ready_i[d][0]) begin
              `TR_ROW("RTR_RSP", g, t, d,
                      `TR_RTR(g,t).gen_router_wide_resp_router_j[p].gen_2dmesh.i_floo_tcdm_wide_resp_router.data_o[d][0].hdr.dst_id.x * NumY +
                      `TR_RTR(g,t).gen_router_wide_resp_router_j[p].gen_2dmesh.i_floo_tcdm_wide_resp_router.data_o[d][0].hdr.dst_id.y,
                      `TR_RTR(g,t).gen_router_wide_resp_router_j[p].gen_2dmesh.i_floo_tcdm_wide_resp_router.data_o[d][0].hdr.tile_id,
                      `TR_RTR(g,t).gen_router_wide_resp_router_j[p].gen_2dmesh.i_floo_tcdm_wide_resp_router.data_o[d][0].hdr.core_id,
                      `TR_RTR(g,t).gen_router_wide_resp_router_j[p].gen_2dmesh.i_floo_tcdm_wide_resp_router.data_o[d][0].hdr.meta_id,
                      32'h0, -1, -1, -1, 0, 0, 0,
                      `TR_RTR(g,t).gen_router_wide_resp_router_j[p].gen_2dmesh.i_floo_tcdm_wide_resp_router.data_o[d][0].payload.data,
                      -1, d, "NESW");
            end
          end
        end
      end
    end
  end
end
`endif // TRACER_TRACE_HOPS

final begin
  if (tracer_en && tracer_fd != 0) begin
    $fclose(tracer_fd);
    $display("[TRACER] closed %s at cyc=%0d (%0t)", tracer_path, tracer_cycle, $time);
  end
end

`endif // VERILATOR
// pragma translate_on

`endif // TB_NOC_REQ_RESP_TRACER_SVH
