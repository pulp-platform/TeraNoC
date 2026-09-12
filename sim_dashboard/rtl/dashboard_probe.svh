// Optional simulation-only instrumentation, included inside mempool_tb.
// Enable output with +dashboard_file=/absolute/path/telemetry.jsonl.
// +dashboard_period=1000, +dashboard_entries (per-entry windows).
// Supported FMAC scope: current unmasked GEMM vector instructions, completion-granular.
// No original RTL or application file is modified by instrument.py.
`ifndef SIM_DASHBOARD_PROBE_SVH
`define SIM_DASHBOARD_PROBE_SVH
`ifndef VERILATOR
`ifdef TARGET_SPATZ
`define SD_GROUP(G) dut.i_mempool_cluster.gen_groups_x[(G)/NumY].gen_groups_y[(G)%NumY].gen_rtl_group.i_group
`define SD_MEM(G) `SD_GROUP(G).i_mempool_group
`define SD_MSHR(G) `SD_MEM(G).gen_group_mshr.i_group_mshr
`define SD_TILE(G,T) `SD_MEM(G).gen_tiles[T].i_tile
`define SD_VFU(G,T,C) `SD_TILE(G,T).gen_cores[C].gen_mempool_cc.riscv_core.i_spatz.i_vfu

localparam int SD_C = NumTilesPerGroup * NumCoresPerTile;
localparam int SD_E = `ifdef GROUP_MSHR_NUM `GROUP_MSHR_NUM `else NumTilesPerGroup `endif;
localparam int SD_W = `ifdef GROUP_MSHR_WAYS_PER_BANK `GROUP_MSHR_WAYS_PER_BANK `else 4 `endif;
localparam int SD_RQ = NumNarrowRemoteReqPortsPerTile + NumWideRemoteReqPortsPerTile;
localparam int SD_RP = NumRemoteRespPortsPerTile - 1;
localparam int SD_NS = NumTilesPerGroup * (SD_RQ > SD_RP ? SD_RQ : SD_RP);
localparam int SD_IDS = 2**$bits(spatz_pkg::spatz_id_t);
logic [`N_FPU-1:0] sd_busy[NumGroups][SD_C];
logic sd_issue[NumGroups][SD_C], sd_done[NumGroups][SD_C], sd_mac[NumGroups][SD_C];
int unsigned sd_iid[NumGroups][SD_C], sd_oid[NumGroups][SD_C], sd_elements[NumGroups][SD_C];
logic sd_valid[NumGroups][SD_E], sd_held[NumGroups][SD_E];
logic sd_single[NumGroups][SD_E];
int unsigned sd_single_target[NumGroups], sd_burst_target[NumGroups];
logic [2:0] sd_state[NumGroups][SD_E];
logic sd_bv[NumGroups][NumTilesPerGroup][NumBanksPerTile];
logic sd_br[NumGroups][NumTilesPerGroup][NumBanksPerTile];
logic sd_lv[2][NumGroups][SD_NS][4], sd_lr[2][NumGroups][SD_NS][4];
logic sd_mqv[NumGroups][NumTilesPerGroup][SD_RQ], sd_mqr[NumGroups][NumTilesPerGroup][SD_RQ];
logic sd_sqv[NumGroups][NumTilesPerGroup][SD_RQ], sd_sqr[NumGroups][NumTilesPerGroup][SD_RQ];
logic sd_mrv[NumGroups][NumTilesPerGroup][SD_RP], sd_mrr[NumGroups][NumTilesPerGroup][SD_RP];
logic sd_srv[NumGroups][NumTilesPerGroup][SD_RP], sd_srr[NumGroups][NumTilesPerGroup][SD_RP];

for (genvar g=0; g<NumGroups; g++) begin : gen_dashboard_group
  assign sd_single_target[g] = int'(`SD_MSHR(g).cfg_hold_subs_single);
  assign sd_burst_target[g] = int'(`SD_MSHR(g).cfg_hold_subs_burst);
  for (genvar t=0; t<NumTilesPerGroup; t++) begin : gen_tile
    for (genvar c=0; c<NumCoresPerTile; c++) begin : gen_core
      localparam int I=t*NumCoresPerTile+c;
      assign sd_busy[g][I] = `SD_VFU(g,t,c).gen_fpu.fpu_busy_q;
      assign sd_issue[g][I] = `SD_VFU(g,t,c).spatz_req_valid_i &&
        `SD_VFU(g,t,c).spatz_req_ready_o && `SD_VFU(g,t,c).spatz_req_i.ex_unit == spatz_pkg::VFU;
      assign sd_done[g][I] = `SD_VFU(g,t,c).vfu_rsp_valid_o;
      assign sd_iid[g][I] = int'(`SD_VFU(g,t,c).spatz_req_i.id);
      assign sd_oid[g][I] = int'(`SD_VFU(g,t,c).vfu_rsp_o.id);
      assign sd_mac[g][I] = (`SD_VFU(g,t,c).spatz_req_i.op inside
        {spatz_pkg::VFMADD,spatz_pkg::VFMSUB,spatz_pkg::VFNMADD,spatz_pkg::VFNMSUB}) &&
        !`SD_VFU(g,t,c).spatz_req_i.op_arith.is_scalar &&
        !`SD_VFU(g,t,c).spatz_req_i.op_arith.is_reduction;
      assign sd_elements[g][I] = int'(`SD_VFU(g,t,c).spatz_req_i.vl) -
        int'(`SD_VFU(g,t,c).spatz_req_i.vstart);
    end
    for (genvar b=0; b<NumBanksPerTile; b++) begin : gen_bank
      assign sd_bv[g][t][b] = `SD_TILE(g,t).superbank_req_valid[b];
      assign sd_br[g][t][b] = `SD_TILE(g,t).superbank_req_ready[b];
    end
    for (genvar p=0; p<SD_RQ; p++) begin : gen_request_endpoint
      assign sd_mqv[g][t][p] = `SD_TILE(g,t).tcdm_master_req_valid_o[p+1];
      assign sd_mqr[g][t][p] = `SD_TILE(g,t).tcdm_master_req_ready_i[p+1];
      assign sd_sqv[g][t][p] = `SD_TILE(g,t).tcdm_slave_req_valid_i[p+1];
      assign sd_sqr[g][t][p] = `SD_TILE(g,t).tcdm_slave_req_ready_o[p+1];
    end
    for (genvar p=0; p<SD_RP; p++) begin : gen_endpoint
      assign sd_mrv[g][t][p] = `SD_TILE(g,t).tcdm_master_resp_valid_i[p+1];
      assign sd_mrr[g][t][p] = `SD_TILE(g,t).tcdm_master_resp_ready_o[p+1];
      assign sd_srv[g][t][p] = `SD_TILE(g,t).tcdm_slave_resp_valid_o[p+1];
      assign sd_srr[g][t][p] = `SD_TILE(g,t).tcdm_slave_resp_ready_i[p+1];
    end
  end
  for (genvar e=0; e<SD_E; e++) begin : gen_entry
    assign sd_single[g][e] = (`SD_MSHR(g).mshr_q[e].burst_len == 1);
    assign sd_valid[g][e] = `SD_MSHR(g).mshr_q_valid[e];
    assign sd_state[g][e] = `SD_MSHR(g).mshr_q[e].state;
    assign sd_held[g][e] = sd_valid[g][e] && sd_state[g][e]==1 && !`SD_MSHR(g).mshr_q[e].issued;
  end
  for (genvar n=0; n<2; n++) begin : gen_network
    for (genvar s=0; s<SD_NS; s++) begin : gen_subnet
      for (genvar d=0; d<4; d++) begin : gen_dir
        if (n==0 && s<NumTilesPerGroup*SD_RQ) begin : gen_req
          localparam int T=s/SD_RQ;
          localparam int P=s%SD_RQ;
          if (P<NumNarrowRemoteReqPortsPerTile) begin : gen_narrow
            assign sd_lv[n][g][s][d] = `SD_GROUP(g).gen_router_router_i[T]
              .gen_router_narrow_req_router_j[P].gen_2dmesh.i_floo_tcdm_narrow_req_router.valid_o[d][0];
            assign sd_lr[n][g][s][d] = `SD_GROUP(g).gen_router_router_i[T]
              .gen_router_narrow_req_router_j[P].gen_2dmesh.i_floo_tcdm_narrow_req_router.ready_i[d][0];
          end else begin : gen_wide
            localparam int PWide=P-NumNarrowRemoteReqPortsPerTile;
            assign sd_lv[n][g][s][d] = `SD_GROUP(g).gen_router_router_i[T]
              .gen_router_wide_req_router_j[PWide].gen_2dmesh.i_floo_tcdm_wide_req_router.valid_o[d][0];
            assign sd_lr[n][g][s][d] = `SD_GROUP(g).gen_router_router_i[T]
              .gen_router_wide_req_router_j[PWide].gen_2dmesh.i_floo_tcdm_wide_req_router.ready_i[d][0];
          end
        end else if (n==1 && s<NumTilesPerGroup*SD_RP) begin : gen_resp
          localparam int T=s/SD_RP;
          localparam int P=s%SD_RP+1;
          assign sd_lv[n][g][s][d] = `SD_GROUP(g).gen_router_router_i[T]
            .gen_router_wide_resp_router_j[P].gen_2dmesh.i_floo_tcdm_wide_resp_router.valid_o[d][0];
          assign sd_lr[n][g][s][d] = `SD_GROUP(g).gen_router_router_i[T]
            .gen_router_wide_resp_router_j[P].gen_2dmesh.i_floo_tcdm_wide_resp_router.ready_i[d][0];
        end else begin : gen_unused
          assign sd_lv[n][g][s][d]=0;
          assign sd_lr[n][g][s][d]=0;
        end
      end
    end
  end
end

integer sd_fd=0, sd_period=1000;
string sd_file;
bit sd_entries=0, sd_banks=0, sd_links=0, sd_phase=0;
longint unsigned sd_cycle=0, sd_start=0;
longint unsigned sd_busy_sum[NumGroups], sd_fmac[NumGroups];
longint unsigned sd_eocc[NumGroups][SD_E], sd_ecache[NumGroups][SD_E], sd_eheld[NumGroups][SD_E];
longint unsigned sd_esingle[NumGroups][SD_E], sd_eburst[NumGroups][SD_E];
int unsigned sd_estate[NumGroups][SD_E], sd_peak[NumGroups];
longint unsigned sd_full[NumGroups];
longint unsigned sd_bh[NumGroups][NumTilesPerGroup][NumBanksPerTile];
longint unsigned sd_bs[NumGroups][NumTilesPerGroup][NumBanksPerTile];
longint unsigned sd_lh[2][NumGroups][SD_NS][4], sd_ls[2][NumGroups][SD_NS][4];
longint unsigned sd_mresp[SD_RP], sd_sresp[SD_RP];
longint unsigned sd_mreq[SD_RQ], sd_sreq[SD_RQ];
int unsigned sd_pending[NumGroups][SD_C][SD_IDS];
bit sd_pending_bench[NumGroups][SD_C][SD_IDS];

initial begin
  if ($value$plusargs("dashboard_file=%s",sd_file)) begin
    sd_fd=$fopen(sd_file,"w");
    if (!sd_fd) $fatal(1,"Cannot open dashboard telemetry %s",sd_file);
    if ($value$plusargs("dashboard_period=%d",sd_period)) begin end
    if (sd_period<=0) $fatal(1,"dashboard_period must be positive");
    sd_entries=$test$plusargs("dashboard_entries");
    sd_banks=$test$plusargs("dashboard_banks");
    sd_links=$test$plusargs("dashboard_links");
    $fwrite(sd_fd,"{\"kind\":\"meta\",\"schema_version\":1,\"backend\":\"rtl\",\"mesh\":[%0d,%0d],\"tiles_per_group\":%0d,\"cores_per_tile\":%0d,\"n_fpu\":%0d,\"banks_per_tile\":%0d,\"mshr_entries\":%0d,\"mshr_ways\":%0d,\"req_subnets\":%0d,\"resp_subnets\":%0d,\"fmac_scope\":\"unmasked vector FMAC at instruction completion\"}\n",
      NumX,NumY,NumTilesPerGroup,NumCoresPerTile,`N_FPU,NumBanksPerTile,SD_E,SD_W,
      NumTilesPerGroup*SD_RQ,NumTilesPerGroup*SD_RP);
  end
end

task automatic sd_clear();
  foreach(sd_busy_sum[g]) begin sd_busy_sum[g]=0; sd_fmac[g]=0; sd_peak[g]=0; sd_full[g]=0; end
  foreach(sd_eocc[g,e]) begin sd_eocc[g][e]=0; sd_ecache[g][e]=0; sd_eheld[g][e]=0; sd_esingle[g][e]=0; sd_eburst[g][e]=0; end
  foreach(sd_bh[g,t,b]) begin sd_bh[g][t][b]=0; sd_bs[g][t][b]=0; end
  foreach(sd_lh[n,g,s,d]) begin sd_lh[n][g][s][d]=0; sd_ls[n][g][s][d]=0; end
  foreach(sd_mreq[p]) begin sd_mreq[p]=0; sd_sreq[p]=0; end
  foreach(sd_mresp[p]) begin sd_mresp[p]=0; sd_sresp[p]=0; end
endtask

task automatic sd_flush();
  longint unsigned win,occupied,single_occupied,burst_occupied;
  string ph;
  win=sd_cycle-sd_start;
  ph=sd_phase?"bench":"pre";
  if(sd_fd && win>0) begin
    for(int g=0;g<NumGroups;g++) begin
      occupied=0; single_occupied=0; burst_occupied=0;
      for(int e=0;e<SD_E;e++) begin
        occupied+=sd_eocc[g][e];
        single_occupied+=sd_esingle[g][e]; burst_occupied+=sd_eburst[g][e];
        if(sd_entries) $fwrite(sd_fd,"{\"kind\":\"entry\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"entry\":%0d,\"occupied\":%0d,\"capacity\":%0d,\"cached\":%0d,\"held\":%0d,\"state\":%0d,\"occupied_single\":%0d,\"occupied_burst\":%0d}\n",
          sd_start,sd_cycle,ph,g,e,sd_eocc[g][e],win,sd_ecache[g][e],sd_eheld[g][e],sd_estate[g][e],sd_esingle[g][e],sd_eburst[g][e]);
      end
      $fwrite(sd_fd,"{\"kind\":\"fpu\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"busy\":%0d,\"capacity\":%0d}\n",sd_start,sd_cycle,ph,g,sd_busy_sum[g],win*SD_C*`N_FPU);
      $fwrite(sd_fd,"{\"kind\":\"work\",\"workload_phase\":\"bench\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"fmac\":%0d}\n",sd_start,sd_cycle,ph,g,sd_fmac[g]);
      $fwrite(sd_fd,"{\"kind\":\"mshr\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"occupied\":%0d,\"capacity\":%0d,\"entries\":%0d,\"peak\":%0d,\"full\":%0d,\"occupied_single\":%0d,\"occupied_burst\":%0d,\"single_merge_target\":%0d,\"burst_merge_target\":%0d}\n",sd_start,sd_cycle,ph,g,occupied,win*SD_E,SD_E,sd_peak[g],sd_full[g],single_occupied,burst_occupied,sd_single_target[g],sd_burst_target[g]);
      if(sd_banks) for(int t=0;t<NumTilesPerGroup;t++) for(int b=0;b<NumBanksPerTile;b++)
        $fwrite(sd_fd,"{\"kind\":\"bank\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"t\":%0d,\"bank\":%0d,\"hsk\":%0d,\"stall\":%0d}\n",sd_start,sd_cycle,ph,g,t,b,sd_bh[g][t][b],sd_bs[g][t][b]);
      if(sd_links) for(int n=0;n<2;n++) for(int s=0;s<NumTilesPerGroup*(n==0?SD_RQ:SD_RP);s++)
        for(int d=0;d<4;d++)
          $fwrite(sd_fd,"{\"kind\":\"link\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"network\":\"%s\",\"subnet\":%0d,\"direction\":%0d,\"hsk\":%0d,\"stall\":%0d}\n",sd_start,sd_cycle,ph,g,n==0?string'("req"):string'("resp"),s,d,sd_lh[n][g][s][d],sd_ls[n][g][s][d]);
    end
    $fwrite(sd_fd,"{\"kind\":\"traffic\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"mst_req\":[",sd_start,sd_cycle,ph);
    for(int p=0;p<SD_RQ;p++) $fwrite(sd_fd,"%s%0d",p?",":"",sd_mreq[p]);
    $fwrite(sd_fd,"],\"slv_req\":[");
    for(int p=0;p<SD_RQ;p++) $fwrite(sd_fd,"%s%0d",p?",":"",sd_sreq[p]);
    $fwrite(sd_fd,"],\"mst_resp\":[");
    for(int p=0;p<SD_RP;p++) $fwrite(sd_fd,"%s%0d",p?",":"",sd_mresp[p]);
    $fwrite(sd_fd,"],\"slv_resp\":[");
    for(int p=0;p<SD_RP;p++) $fwrite(sd_fd,"%s%0d",p?",":"",sd_sresp[p]);
    $fwrite(sd_fd,"]}\n");
    $fflush(sd_fd);
  end
  sd_clear(); sd_start=sd_cycle;
endtask

always @(posedge clk) begin : dashboard_sample
  int occupied;
  if(sd_fd) begin
    if(!rst_n) begin
      sd_clear(); sd_cycle=0; sd_start=0; sd_phase=0;
      foreach(sd_pending[g,c,i]) begin sd_pending[g][c][i]=0; sd_pending_bench[g][c][i]=0; end
    end else begin
      if(sd_phase != csr_trace_any_global) begin
        sd_flush(); sd_phase=csr_trace_any_global;
      end
      for(int g=0;g<NumGroups;g++) begin
        for(int c=0;c<SD_C;c++) begin
          sd_busy_sum[g]+=$countones(sd_busy[g][c]);
          // Retire before issuing, allowing an ID to be reused on the same edge.
          if(sd_done[g][c]) begin
            if(sd_pending_bench[g][c][sd_oid[g][c]])
              sd_fmac[g]+=sd_pending[g][c][sd_oid[g][c]];
            sd_pending[g][c][sd_oid[g][c]]=0;
          end
          if(sd_issue[g][c]) begin
            if(sd_pending[g][c][sd_iid[g][c]]!=0) $fatal(1,"dashboard FMAC ID reused before completion");
            sd_pending[g][c][sd_iid[g][c]]=sd_mac[g][c]?sd_elements[g][c]:0;
            sd_pending_bench[g][c][sd_iid[g][c]]=sd_phase;
          end
        end
        occupied=0;
        for(int e=0;e<SD_E;e++) begin
          sd_estate[g][e]=sd_valid[g][e]?int'(sd_state[g][e]):0;
          if(sd_valid[g][e]) begin
            occupied++; sd_eocc[g][e]++;
            if(sd_single[g][e]) sd_esingle[g][e]++; else sd_eburst[g][e]++;
            if(sd_state[g][e]==3) sd_ecache[g][e]++;
            if(sd_held[g][e]) sd_eheld[g][e]++;
          end
        end
        if(occupied>sd_peak[g]) sd_peak[g]=occupied;
        if(occupied==SD_E) sd_full[g]++;
        for(int t=0;t<NumTilesPerGroup;t++) begin
          if(sd_banks) for(int b=0;b<NumBanksPerTile;b++) if(sd_bv[g][t][b]) begin
            if(sd_br[g][t][b]) sd_bh[g][t][b]++; else sd_bs[g][t][b]++;
          end
          for(int p=0;p<SD_RQ;p++) begin
            if(sd_mqv[g][t][p]&&sd_mqr[g][t][p]) sd_mreq[p]++;
            if(sd_sqv[g][t][p]&&sd_sqr[g][t][p]) sd_sreq[p]++;
          end
          for(int p=0;p<SD_RP;p++) begin
            if(sd_mrv[g][t][p]&&sd_mrr[g][t][p]) sd_mresp[p]++;
            if(sd_srv[g][t][p]&&sd_srr[g][t][p]) sd_sresp[p]++;
          end
        end
      end
      if(sd_links) foreach(sd_lh[n,g,s,d]) if(sd_lv[n][g][s][d]) begin
        if(sd_lr[n][g][s][d]) sd_lh[n][g][s][d]++; else sd_ls[n][g][s][d]++;
      end
      sd_cycle++;
      if(sd_cycle-sd_start>=sd_period) sd_flush();
    end
  end
end
final begin
  sd_flush();
  if(sd_fd) $fclose(sd_fd);
end
`undef SD_GROUP
`undef SD_MEM
`undef SD_MSHR
`undef SD_TILE
`undef SD_VFU
`endif
`endif
`endif
