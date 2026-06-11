// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`ifndef TB_NOC_PROFILING_SVH_
`define TB_NOC_PROFILING_SVH_

`ifndef TARGET_SYNTHESIS
`ifndef TARGET_VERILATOR
  logic [63:0] cycle_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if(~rst_n) begin
      cycle_q   <= '0;
    end else begin
      cycle_q   <= cycle_q + 64'd1;
    end
  end

`ifdef NOC_PROFILING
  // Hierarchical path to group g's FlooNoC wrapper (i_group).
  `define NOC_GRP(grp) dut.i_mempool_cluster.gen_groups_x[(grp) / NumY].gen_groups_y[(grp) % NumY].gen_rtl_group.i_group

  // ONE FULL per-router / per-tile NoC trace; the export-time --noc-slices flag
  // chooses the granularity. Each line is one of:
  //   S <portidx> <io> <start> <end> <state>   run-length: idle(0)/stall(1)/read(2)/write(3)
  //   P ... one accepted REQUEST flit (addr + XY routing), emitted every handshake cycle
  //   portidx 0..3 = N/E/S/W mesh ports, 4 = local; io 0=input, 1=output.
  // To stay under VCS's open-file limit, files are MERGED and lines PREFIXED with a demux idx:
  //   routers -> router_g<g>_{req,resp}.log  (one per group; <idx> = in-group router id
  //              <rid>, a flat slot t*ports+p -- routers are remapped so NOT tile/port)
  //   cores   -> pe_g<g>_t<t>.log            (one per tile; <idx> = core)
  //   tiles   -> tile_g<g>_t<t>.log          (already one per tile; NO prefix)
  string  app, log_path;
  integer retval;
  // MERGED file handles: routers -> ONE req + ONE resp file per group (line tagged with
  // router id); Snitch cores -> ONE file per tile (line tagged with core idx). PE = the
  // Snitch core's data memory port.
  int f_rreq  [NumGroups];
  int f_rresp [NumGroups];
  int f_tile  [NumGroups][NumTilesPerGroup];
  int f_pe    [NumGroups][NumTilesPerGroup];

  initial begin
    void'($value$plusargs("APP=%s", app));
    log_path = "noc_profiling";
    retval   = $system({"mkdir -p ", log_path});
    // Tiles keep their id. Routers use a FLAT in-group router id (r = t*NumPortsPerTile + p):
    // the req/resp remappers shuffle logical traffic across physical routers, so [tile][port]
    // is just a physical slot, not a tile/port assignment.
    for (int g = 0; g < NumGroups; g++) begin
      f_rreq[g]  = $fopen($sformatf("%s/router_g%0d_req.log",  log_path, g), "w");
      f_rresp[g] = $fopen($sformatf("%s/router_g%0d_resp.log", log_path, g), "w");
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        f_tile[g][t] = $fopen($sformatf("%s/tile_g%0d_t%0d.log", log_path, g, t), "w");
        f_pe[g][t]   = $fopen($sformatf("%s/pe_g%0d_t%0d.log",   log_path, g, t), "w");
      end
    end
  end

  // Module-scope state registers so the end-of-sim `final` below can flush them.
  // router: [group][tile][port][portidx 0..4][io 0..1]
  logic [1:0]  rsq_st    [NumGroups][NumTilesPerGroup][NumWideRemoteReqPortsPerTile][5][2];
  logic [63:0] rsq_start [NumGroups][NumTilesPerGroup][NumWideRemoteReqPortsPerTile][5][2];
  logic [1:0]  rsp_st    [NumGroups][NumTilesPerGroup][NumRemoteRespPortsPerTile-1][5][2];
  logic [63:0] rsp_start [NumGroups][NumTilesPerGroup][NumRemoteRespPortsPerTile-1][5][2];
  // tile: [group][tile][port]
  logic [1:0]  ts_mreq_st [NumGroups][NumTilesPerGroup][NumRemoteReqPortsPerTile];  logic [63:0] ts_mreq_s [NumGroups][NumTilesPerGroup][NumRemoteReqPortsPerTile];
  logic [1:0]  ts_sreq_st [NumGroups][NumTilesPerGroup][NumRemoteReqPortsPerTile];  logic [63:0] ts_sreq_s [NumGroups][NumTilesPerGroup][NumRemoteReqPortsPerTile];
  logic [1:0]  ts_mrsp_st [NumGroups][NumTilesPerGroup][NumRemoteRespPortsPerTile]; logic [63:0] ts_mrsp_s [NumGroups][NumTilesPerGroup][NumRemoteRespPortsPerTile];
  logic [1:0]  ts_srsp_st [NumGroups][NumTilesPerGroup][NumRemoteRespPortsPerTile]; logic [63:0] ts_srsp_s [NumGroups][NumTilesPerGroup][NumRemoteRespPortsPerTile];
  // PE (Snitch core data port): req = data_q* (out, read/write by qwrite), resp = data_p* (in).
  logic [1:0]  pe_req_st [NumGroups][NumTilesPerGroup][NumCoresPerTile]; logic [63:0] pe_req_s [NumGroups][NumTilesPerGroup][NumCoresPerTile];
  logic [1:0]  pe_rsp_st [NumGroups][NumTilesPerGroup][NumCoresPerTile]; logic [63:0] pe_rsp_s [NumGroups][NumTilesPerGroup][NumCoresPerTile];

  // ------------------------------------------------------------
  // Router port capture (4 mesh dirs + local, input + output) -> per-router file.
  // S lines RLE idle/stall/read/write; P lines log every accepted request flit
  // (req routers only). read/write split via payload.wen.
  // ------------------------------------------------------------
  generate
    for (genvar g = 0; g < NumGroups; g++) begin : gen_rstate_g
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          rsq_st[g] <= '{default: '0}; rsq_start[g] <= '{default: '0};
          rsp_st[g] <= '{default: '0}; rsp_start[g] <= '{default: '0};
        end else begin
          for (int t = 0; t < NumTilesPerGroup; t++) begin
            // ---- wide-req routers ----
            for (int p = 0; p < NumWideRemoteReqPortsPerTile; p++) begin
              automatic int rid = t*NumWideRemoteReqPortsPerTile + p;  // merged-file router tag
              for (int d = 0; d < 4; d++) begin
                automatic logic [1:0] si = `NOC_GRP(g).floo_tcdm_wide_req_valid_in_trans[t][p][d]
                  ? (`NOC_GRP(g).floo_tcdm_wide_req_ready_out_trans[t][p][d]
                     ? (`NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].payload.wen ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
                automatic logic [1:0] so = `NOC_GRP(g).floo_tcdm_wide_req_valid_out_trans[t][p][d]
                  ? (`NOC_GRP(g).floo_tcdm_wide_req_ready_in_trans[t][p][d]
                     ? (`NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].payload.wen ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
                if (si != rsq_st[g][t][p][d][0]) begin
                  $fwrite(f_rreq[g], "%0d S %0d 0 %0d %0d %0d\n", rid, d, rsq_start[g][t][p][d][0], cycle_q, rsq_st[g][t][p][d][0]);
                  rsq_st[g][t][p][d][0] <= si; rsq_start[g][t][p][d][0] <= cycle_q;
                end
                if (so != rsq_st[g][t][p][d][1]) begin
                  $fwrite(f_rreq[g], "%0d S %0d 1 %0d %0d %0d\n", rid, d, rsq_start[g][t][p][d][1], cycle_q, rsq_st[g][t][p][d][1]);
                  rsq_st[g][t][p][d][1] <= so; rsq_start[g][t][p][d][1] <= cycle_q;
                end
                // P: portidx io cycle wen tgt_addr dst_x dst_y src_x src_y src_tile core meta_id
                if (si >= 2)  // input handshake -> one request flit accepted
                  $fwrite(f_rreq[g], "%0d P %0d 0 %0d %0d %0h %0d %0d %0d %0d %0d %0d %0d\n", rid, d, cycle_q,
                    `NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].payload.wen,
                    `NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].hdr.tgt_addr,
                    `NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].hdr.dst_id.x,
                    `NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].hdr.dst_id.y,
                    `NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].hdr.src_id.x,
                    `NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].hdr.src_id.y,
                    `NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].hdr.src_tile_id,
                    `NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].hdr.core_id,
                    `NOC_GRP(g).floo_tcdm_wide_req_in_trans[t][p][d].hdr.meta_id);
                if (so >= 2)  // output handshake
                  $fwrite(f_rreq[g], "%0d P %0d 1 %0d %0d %0h %0d %0d %0d %0d %0d %0d %0d\n", rid, d, cycle_q,
                    `NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].payload.wen,
                    `NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].hdr.tgt_addr,
                    `NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].hdr.dst_id.x,
                    `NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].hdr.dst_id.y,
                    `NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].hdr.src_id.x,
                    `NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].hdr.src_id.y,
                    `NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].hdr.src_tile_id,
                    `NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].hdr.core_id,
                    `NOC_GRP(g).floo_tcdm_wide_req_out_trans[t][p][d].hdr.meta_id);
              end
              begin : req_local
                automatic logic [1:0] sli = `NOC_GRP(g).floo_tcdm_rdwr_req_to_router_vc_valid[t][p]
                  ? (`NOC_GRP(g).floo_tcdm_rdwr_req_to_router_vc_ready[t][p]
                     ? (`NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].payload.wen ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
                automatic logic [1:0] slo = `NOC_GRP(g).floo_tcdm_rdwr_req_from_router_vc_valid[t][p]
                  ? (`NOC_GRP(g).floo_tcdm_rdwr_req_from_router_vc_ready[t][p]
                     ? (`NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].payload.wen ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
                if (sli != rsq_st[g][t][p][4][0]) begin
                  $fwrite(f_rreq[g], "%0d S 4 0 %0d %0d %0d\n", rid, rsq_start[g][t][p][4][0], cycle_q, rsq_st[g][t][p][4][0]);
                  rsq_st[g][t][p][4][0] <= sli; rsq_start[g][t][p][4][0] <= cycle_q;
                end
                if (slo != rsq_st[g][t][p][4][1]) begin
                  $fwrite(f_rreq[g], "%0d S 4 1 %0d %0d %0d\n", rid, rsq_start[g][t][p][4][1], cycle_q, rsq_st[g][t][p][4][1]);
                  rsq_st[g][t][p][4][1] <= slo; rsq_start[g][t][p][4][1] <= cycle_q;
                end
                if (sli >= 2)  // local input (injection from tile) handshake
                  $fwrite(f_rreq[g], "%0d P 4 0 %0d %0d %0h %0d %0d %0d %0d %0d %0d %0d\n", rid, cycle_q,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].payload.wen,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].hdr.tgt_addr,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].hdr.dst_id.x,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].hdr.dst_id.y,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].hdr.src_id.x,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].hdr.src_id.y,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].hdr.src_tile_id,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].hdr.core_id,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_to_router[t][p].hdr.meta_id);
                if (slo >= 2)  // local output (ejection to tile) handshake
                  $fwrite(f_rreq[g], "%0d P 4 1 %0d %0d %0h %0d %0d %0d %0d %0d %0d %0d\n", rid, cycle_q,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].payload.wen,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].hdr.tgt_addr,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].hdr.dst_id.x,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].hdr.dst_id.y,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].hdr.src_id.x,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].hdr.src_id.y,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].hdr.src_tile_id,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].hdr.core_id,
                    `NOC_GRP(g).floo_tcdm_rdwr_req_from_router[t][p].hdr.meta_id);
              end
            end
            // ---- resp routers (router slot p+1; no read/write split). P lines log every
            //      accepted RESPONSE flit; a resp flit has no tgt_addr. hdr carries dst_id
            //      (requester it returns to), src_id (responder), tile_id/core_id (requester).
            //   P <portidx> <io> <cycle> <dst_x> <dst_y> <src_x> <src_y> <req_tile> <req_core> <meta_id> ----
            for (int p = 0; p < NumRemoteRespPortsPerTile-1; p++) begin
              automatic int rid = t*(NumRemoteRespPortsPerTile-1) + p;  // merged-file router tag
              for (int d = 0; d < 4; d++) begin
                automatic logic [1:0] si = `NOC_GRP(g).floo_tcdm_resp_valid_in_trans[t][p+1][d]
                  ? (`NOC_GRP(g).floo_tcdm_resp_ready_out_trans[t][p+1][d] ? 2'd2 : 2'd1) : 2'd0;
                automatic logic [1:0] so = `NOC_GRP(g).floo_tcdm_resp_valid_out_trans[t][p+1][d]
                  ? (`NOC_GRP(g).floo_tcdm_resp_ready_in_trans[t][p+1][d] ? 2'd2 : 2'd1) : 2'd0;
                if (si != rsp_st[g][t][p][d][0]) begin
                  $fwrite(f_rresp[g], "%0d S %0d 0 %0d %0d %0d\n", rid, d, rsp_start[g][t][p][d][0], cycle_q, rsp_st[g][t][p][d][0]);
                  rsp_st[g][t][p][d][0] <= si; rsp_start[g][t][p][d][0] <= cycle_q;
                end
                if (so != rsp_st[g][t][p][d][1]) begin
                  $fwrite(f_rresp[g], "%0d S %0d 1 %0d %0d %0d\n", rid, d, rsp_start[g][t][p][d][1], cycle_q, rsp_st[g][t][p][d][1]);
                  rsp_st[g][t][p][d][1] <= so; rsp_start[g][t][p][d][1] <= cycle_q;
                end
                if (si >= 2)  // mesh input handshake -> one response flit accepted
                  $fwrite(f_rresp[g], "%0d P %0d 0 %0d %0d %0d %0d %0d %0d %0d %0d\n", rid, d, cycle_q,
                    `NOC_GRP(g).floo_tcdm_resp_in_trans[t][p+1][d].hdr.dst_id.x,
                    `NOC_GRP(g).floo_tcdm_resp_in_trans[t][p+1][d].hdr.dst_id.y,
                    `NOC_GRP(g).floo_tcdm_resp_in_trans[t][p+1][d].hdr.src_id.x,
                    `NOC_GRP(g).floo_tcdm_resp_in_trans[t][p+1][d].hdr.src_id.y,
                    `NOC_GRP(g).floo_tcdm_resp_in_trans[t][p+1][d].hdr.tile_id,
                    `NOC_GRP(g).floo_tcdm_resp_in_trans[t][p+1][d].hdr.core_id,
                    `NOC_GRP(g).floo_tcdm_resp_in_trans[t][p+1][d].hdr.meta_id);
                if (so >= 2)  // mesh output handshake
                  $fwrite(f_rresp[g], "%0d P %0d 1 %0d %0d %0d %0d %0d %0d %0d %0d\n", rid, d, cycle_q,
                    `NOC_GRP(g).floo_tcdm_resp_out_trans[t][p+1][d].hdr.dst_id.x,
                    `NOC_GRP(g).floo_tcdm_resp_out_trans[t][p+1][d].hdr.dst_id.y,
                    `NOC_GRP(g).floo_tcdm_resp_out_trans[t][p+1][d].hdr.src_id.x,
                    `NOC_GRP(g).floo_tcdm_resp_out_trans[t][p+1][d].hdr.src_id.y,
                    `NOC_GRP(g).floo_tcdm_resp_out_trans[t][p+1][d].hdr.tile_id,
                    `NOC_GRP(g).floo_tcdm_resp_out_trans[t][p+1][d].hdr.core_id,
                    `NOC_GRP(g).floo_tcdm_resp_out_trans[t][p+1][d].hdr.meta_id);
              end
              begin : rsp_local
                automatic logic [1:0] sli = `NOC_GRP(g).floo_tcdm_resp_to_router_vc_valid[t][p+1]
                  ? (`NOC_GRP(g).floo_tcdm_resp_to_router_vc_ready[t][p+1] ? 2'd2 : 2'd1) : 2'd0;
                automatic logic [1:0] slo = `NOC_GRP(g).floo_tcdm_resp_from_router_vc_valid[t][p+1]
                  ? (`NOC_GRP(g).floo_tcdm_resp_from_router_vc_ready[t][p+1] ? 2'd2 : 2'd1) : 2'd0;
                if (sli != rsp_st[g][t][p][4][0]) begin
                  $fwrite(f_rresp[g], "%0d S 4 0 %0d %0d %0d\n", rid, rsp_start[g][t][p][4][0], cycle_q, rsp_st[g][t][p][4][0]);
                  rsp_st[g][t][p][4][0] <= sli; rsp_start[g][t][p][4][0] <= cycle_q;
                end
                if (slo != rsp_st[g][t][p][4][1]) begin
                  $fwrite(f_rresp[g], "%0d S 4 1 %0d %0d %0d\n", rid, rsp_start[g][t][p][4][1], cycle_q, rsp_st[g][t][p][4][1]);
                  rsp_st[g][t][p][4][1] <= slo; rsp_start[g][t][p][4][1] <= cycle_q;
                end
                if (sli >= 2)  // local input (injection from tile = slave_resp) handshake
                  $fwrite(f_rresp[g], "%0d P 4 0 %0d %0d %0d %0d %0d %0d %0d %0d\n", rid, cycle_q,
                    `NOC_GRP(g).floo_tcdm_resp_to_router[t][p+1].hdr.dst_id.x,
                    `NOC_GRP(g).floo_tcdm_resp_to_router[t][p+1].hdr.dst_id.y,
                    `NOC_GRP(g).floo_tcdm_resp_to_router[t][p+1].hdr.src_id.x,
                    `NOC_GRP(g).floo_tcdm_resp_to_router[t][p+1].hdr.src_id.y,
                    `NOC_GRP(g).floo_tcdm_resp_to_router[t][p+1].hdr.tile_id,
                    `NOC_GRP(g).floo_tcdm_resp_to_router[t][p+1].hdr.core_id,
                    `NOC_GRP(g).floo_tcdm_resp_to_router[t][p+1].hdr.meta_id);
                if (slo >= 2)  // local output (ejection to tile = master_resp) handshake
                  $fwrite(f_rresp[g], "%0d P 4 1 %0d %0d %0d %0d %0d %0d %0d %0d\n", rid, cycle_q,
                    `NOC_GRP(g).floo_tcdm_resp_from_router[t][p+1].hdr.dst_id.x,
                    `NOC_GRP(g).floo_tcdm_resp_from_router[t][p+1].hdr.dst_id.y,
                    `NOC_GRP(g).floo_tcdm_resp_from_router[t][p+1].hdr.src_id.x,
                    `NOC_GRP(g).floo_tcdm_resp_from_router[t][p+1].hdr.src_id.y,
                    `NOC_GRP(g).floo_tcdm_resp_from_router[t][p+1].hdr.tile_id,
                    `NOC_GRP(g).floo_tcdm_resp_from_router[t][p+1].hdr.core_id,
                    `NOC_GRP(g).floo_tcdm_resp_from_router[t][p+1].hdr.meta_id);
              end
            end
          end
        end
      end
    end
  endgenerate

  // ------------------------------------------------------------
  // Tile port capture -> per-tile file. req=master_req(out)/slave_req(in) split
  // read/write by .wen + P packet lines; resp=master_resp(in)/slave_resp(out)
  // single handshake state (no address). genvar t: gen_tiles[t].i_tile constant.
  // ------------------------------------------------------------
  generate
    for (genvar g = 0; g < NumGroups; g++) begin : gen_tstate_g
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_tstate_t
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            ts_mreq_st[g][t] <= '{default: '0}; ts_mreq_s[g][t] <= '{default: '0};
            ts_sreq_st[g][t] <= '{default: '0}; ts_sreq_s[g][t] <= '{default: '0};
            ts_mrsp_st[g][t] <= '{default: '0}; ts_mrsp_s[g][t] <= '{default: '0};
            ts_srsp_st[g][t] <= '{default: '0}; ts_srsp_s[g][t] <= '{default: '0};
          end else begin
            for (int p = 0; p < NumRemoteReqPortsPerTile; p++) begin
              automatic logic [1:0] smo = `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_valid_o[p]
                ? (`NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_ready_i[p]
                   ? (`NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_o[p].wen ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
              automatic logic [1:0] ssi = `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_valid_i[p]
                ? (`NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_ready_o[p]
                   ? (`NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_i[p].wen ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
              if (smo != ts_mreq_st[g][t][p]) begin
                $fwrite(f_tile[g][t], "S 0 1 %0d %0d %0d %0d\n", p, ts_mreq_s[g][t][p], cycle_q, ts_mreq_st[g][t][p]);
                ts_mreq_st[g][t][p] <= smo; ts_mreq_s[g][t][p] <= cycle_q;
              end
              if (ssi != ts_sreq_st[g][t][p]) begin
                $fwrite(f_tile[g][t], "S 0 0 %0d %0d %0d %0d\n", p, ts_sreq_s[g][t][p], cycle_q, ts_sreq_st[g][t][p]);
                ts_sreq_st[g][t][p] <= ssi; ts_sreq_s[g][t][p] <= cycle_q;
              end
              // P: io port cycle wen tgt_addr src_group dst_group req_tile req_core meta_id.
              //   src/dst groups are LINEAR ids (exporter renders as mesh (x,y));
              //   requester group == src group, so not emitted separately.
              if (smo >= 2)  // master_req out (this tile issues a request)
                $fwrite(f_tile[g][t], "P 1 %0d %0d %0d %0h %0d %0d %0d %0d %0d\n", p, cycle_q,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_o[p].wen,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_o[p].tgt_addr,
                  g,                                                                                  // src group
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_o[p].tgt_group_id, // dst group
                  t,                                                                                  // requester tile
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_o[p].wdata.core_id, // requester core
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_req_o[p].wdata.meta_id);// meta_id
              if (ssi >= 2)  // slave_req in (a request arrives at this tile's SPM)
                $fwrite(f_tile[g][t], "P 0 %0d %0d %0d %0h %0d %0d %0d %0d %0d\n", p, cycle_q,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_i[p].wen,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_i[p].tgt_addr,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_i[p].src_group_id,   // src group
                  g,                                                                                  // dst group
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_i[p].ini_addr,       // requester tile
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_i[p].wdata.core_id,  // requester core
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_req_i[p].wdata.meta_id); // meta_id
            end
            for (int p = 0; p < NumRemoteRespPortsPerTile; p++) begin
              automatic logic [1:0] smi = `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_resp_valid_i[p]
                ? (`NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_resp_ready_o[p] ? 2'd2 : 2'd1) : 2'd0;
              automatic logic [1:0] sso = `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_resp_valid_o[p]
                ? (`NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_resp_ready_i[p] ? 2'd2 : 2'd1) : 2'd0;
              // Tile RESP packets use Q lines (kept apart from P req lines):
              //   Q <io> <port> <cycle> <srcvalid> <src_grp> <dst_grp> <req_tile> <req_core> <meta_id>
              //   master_resp(in,io0): responder not on tcdm boundary -> srcvalid=0, dst=this group.
              //   slave_resp(out,io1): src=this group, dst=src_group_id (requester it returns to).
              if (smi != ts_mrsp_st[g][t][p]) begin
                $fwrite(f_tile[g][t], "S 1 0 %0d %0d %0d %0d\n", p, ts_mrsp_s[g][t][p], cycle_q, ts_mrsp_st[g][t][p]);
                ts_mrsp_st[g][t][p] <= smi; ts_mrsp_s[g][t][p] <= cycle_q;
              end
              if (smi >= 2)  // master_resp in: response arrives for this tile's core
                $fwrite(f_tile[g][t], "Q 0 %0d %0d 0 %0d %0d %0d %0d %0d\n", p, cycle_q,
                  g, g, t,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_resp_i[p].rdata.core_id,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_master_resp_i[p].rdata.meta_id);
              if (sso != ts_srsp_st[g][t][p]) begin
                $fwrite(f_tile[g][t], "S 1 1 %0d %0d %0d %0d\n", p, ts_srsp_s[g][t][p], cycle_q, ts_srsp_st[g][t][p]);
                ts_srsp_st[g][t][p] <= sso; ts_srsp_s[g][t][p] <= cycle_q;
              end
              if (sso >= 2)  // slave_resp out: this tile's SPM responds to a requester
                $fwrite(f_tile[g][t], "Q 1 %0d %0d 1 %0d %0d %0d %0d %0d\n", p, cycle_q,
                  g,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_resp_o[p].src_group_id,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_resp_o[p].ini_addr,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_resp_o[p].rdata.core_id,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.tcdm_slave_resp_o[p].rdata.meta_id);
            end
          end
        end
      end
    end
  endgenerate

  // ------------------------------------------------------------
  // PE (Snitch core) data-port capture -> per-tile file (one line per core). Same
  // format as a tile port; req = snitch_data_q* (out, read/write by qwrite, addr=qaddr),
  // resp = snitch_data_p* (in). No bw/util derived for PE ports.
  //   S <rr> <io> <port> <start> <end> <state> ; P <io> <port> <cycle> <wen> <addr(hex)>
  // ------------------------------------------------------------
  generate
    for (genvar g = 0; g < NumGroups; g++) begin : gen_pe_g
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_pe_t
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            pe_req_st[g][t] <= '{default: '0}; pe_req_s[g][t] <= '{default: '0};
            pe_rsp_st[g][t] <= '{default: '0}; pe_rsp_s[g][t] <= '{default: '0};
          end else begin
            for (int c = 0; c < NumCoresPerTile; c++) begin
              automatic logic [1:0] rq = `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qvalid[c]
                ? (`NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qready[c]
                   ? (`NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qwrite[c] ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
              automatic logic [1:0] rp = `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_pvalid[c]
                ? (`NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_pready[c] ? 2'd2 : 2'd1) : 2'd0;
              if (rq != pe_req_st[g][t][c]) begin
                $fwrite(f_pe[g][t], "%0d S 0 1 0 %0d %0d %0d\n", c, pe_req_s[g][t][c], cycle_q, pe_req_st[g][t][c]);
                pe_req_st[g][t][c] <= rq; pe_req_s[g][t][c] <= cycle_q;
              end
              if (rp != pe_rsp_st[g][t][c]) begin
                $fwrite(f_pe[g][t], "%0d S 1 0 0 %0d %0d %0d\n", c, pe_rsp_s[g][t][c], cycle_q, pe_rsp_st[g][t][c]);
                pe_rsp_st[g][t][c] <= rp; pe_rsp_s[g][t][c] <= cycle_q;
              end
              if (rq >= 2)  // req handshake -> one core load/store accepted (qid = meta_id)
                // mask qid to the low snitch_pkg::MetaIdWidth bits (upper bits are X) so the
                // printed id matches the NoC's zero-extended meta_id for this request.
                $fwrite(f_pe[g][t], "%0d P 1 0 %0d %0d %0h %0d\n", c, cycle_q,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qwrite[c],
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qaddr[c],
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_qid[c][snitch_pkg::MetaIdWidth-1:0]);
              if (rp >= 2)  // resp handshake -> a response returns to this core (pid = meta_id)
                $fwrite(f_pe[g][t], "%0d P 0 0 %0d %0d\n", c, cycle_q,
                  `NOC_GRP(g).i_mempool_group.gen_tiles[t].i_tile.snitch_data_pid[c]);
            end
          end
        end
      end
    end
  endgenerate

  // ------------------------------------------------------------
  // End-of-sim flush: write every port's still-open S run, then close every file.
  // P lines are written as they happen, so they need no flush.
  // ------------------------------------------------------------
  final begin
    for (int g = 0; g < NumGroups; g++) begin
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int p = 0; p < NumWideRemoteReqPortsPerTile; p++) begin
          automatic int rid = t*NumWideRemoteReqPortsPerTile + p;
          for (int d = 0; d < 4; d++) begin
            $fwrite(f_rreq[g], "%0d S %0d 0 %0d %0d %0d\n", rid, d, rsq_start[g][t][p][d][0], cycle_q, rsq_st[g][t][p][d][0]);
            $fwrite(f_rreq[g], "%0d S %0d 1 %0d %0d %0d\n", rid, d, rsq_start[g][t][p][d][1], cycle_q, rsq_st[g][t][p][d][1]);
          end
          $fwrite(f_rreq[g], "%0d S 4 0 %0d %0d %0d\n", rid, rsq_start[g][t][p][4][0], cycle_q, rsq_st[g][t][p][4][0]);
          $fwrite(f_rreq[g], "%0d S 4 1 %0d %0d %0d\n", rid, rsq_start[g][t][p][4][1], cycle_q, rsq_st[g][t][p][4][1]);
        end
        for (int p = 0; p < NumRemoteRespPortsPerTile-1; p++) begin
          automatic int rid = t*(NumRemoteRespPortsPerTile-1) + p;
          for (int d = 0; d < 4; d++) begin
            $fwrite(f_rresp[g], "%0d S %0d 0 %0d %0d %0d\n", rid, d, rsp_start[g][t][p][d][0], cycle_q, rsp_st[g][t][p][d][0]);
            $fwrite(f_rresp[g], "%0d S %0d 1 %0d %0d %0d\n", rid, d, rsp_start[g][t][p][d][1], cycle_q, rsp_st[g][t][p][d][1]);
          end
          $fwrite(f_rresp[g], "%0d S 4 0 %0d %0d %0d\n", rid, rsp_start[g][t][p][4][0], cycle_q, rsp_st[g][t][p][4][0]);
          $fwrite(f_rresp[g], "%0d S 4 1 %0d %0d %0d\n", rid, rsp_start[g][t][p][4][1], cycle_q, rsp_st[g][t][p][4][1]);
        end
        for (int p = 0; p < NumRemoteReqPortsPerTile; p++) begin
          $fwrite(f_tile[g][t], "S 0 1 %0d %0d %0d %0d\n", p, ts_mreq_s[g][t][p], cycle_q, ts_mreq_st[g][t][p]);
          $fwrite(f_tile[g][t], "S 0 0 %0d %0d %0d %0d\n", p, ts_sreq_s[g][t][p], cycle_q, ts_sreq_st[g][t][p]);
        end
        for (int p = 0; p < NumRemoteRespPortsPerTile; p++) begin
          $fwrite(f_tile[g][t], "S 1 0 %0d %0d %0d %0d\n", p, ts_mrsp_s[g][t][p], cycle_q, ts_mrsp_st[g][t][p]);
          $fwrite(f_tile[g][t], "S 1 1 %0d %0d %0d %0d\n", p, ts_srsp_s[g][t][p], cycle_q, ts_srsp_st[g][t][p]);
        end
        $fclose(f_tile[g][t]);
        for (int c = 0; c < NumCoresPerTile; c++) begin
          $fwrite(f_pe[g][t], "%0d S 0 1 0 %0d %0d %0d\n", c, pe_req_s[g][t][c], cycle_q, pe_req_st[g][t][c]);
          $fwrite(f_pe[g][t], "%0d S 1 0 0 %0d %0d %0d\n", c, pe_rsp_s[g][t][c], cycle_q, pe_rsp_st[g][t][c]);
        end
        $fclose(f_pe[g][t]);
      end
      $fclose(f_rreq[g]);
      $fclose(f_rresp[g]);
    end
  end

`endif // NOC_PROFILING

`endif // TARGET_VERILATOR
`endif // TARGET_SYNTHESIS

`endif // TB_NOC_PROFILING_SVH_
