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
// Overflow-pool size. Mirrors the RTL parameter's own `ifdef default, and is reported even when the
// pool is absent: 0 says "this build has no pool", where an absent field would be indistinguishable
// from a trace taken before the pool existed.
localparam int SD_OV = `ifdef GROUP_MSHR_OVERFLOW_NUM `GROUP_MSHR_OVERFLOW_NUM `else 1 `endif;
localparam int SD_P = (SD_OV > 0) ? SD_OV : 0;
localparam int SD_PA = (SD_P > 0) ? SD_P : 1;
logic sd_pv[NumGroups][SD_PA], sd_pcached[NumGroups][SD_PA], sd_pheld[NumGroups][SD_PA];
logic [2:0] sd_pstate[NumGroups][SD_PA];
int unsigned sd_pstate_s[NumGroups][SD_PA];   // state at the last sampled cycle
int unsigned sd_psubn[NumGroups][SD_PA];
int unsigned sd_pv_last[NumGroups][SD_PA], sd_psubn_last[NumGroups][SD_PA];
longint unsigned sd_poocc[NumGroups][SD_PA], sd_pocache[NumGroups][SD_PA], sd_poheld[NumGroups][SD_PA];
longint unsigned sd_palloc[NumGroups], sd_pmerge[NumGroups];
logic sd_prht[NumGroups][SD_PA], sd_pcto[NumGroups][SD_PA];
longint unsigned sd_erhp[NumGroups][SD_PA], sd_ectp[NumGroups][SD_PA];
localparam int SD_RQ = NumNarrowRemoteReqPortsPerTile + NumWideRemoteReqPortsPerTile;
localparam int SD_RP = NumRemoteRespPortsPerTile - 1;
localparam int SD_NS = NumTilesPerGroup * (SD_RQ > SD_RP ? SD_RQ : SD_RP);
localparam int SD_IDS = 2**$bits(spatz_pkg::spatz_id_t);
logic [`N_FPU-1:0] sd_busy[NumGroups][SD_C];
logic sd_issue[NumGroups][SD_C], sd_done[NumGroups][SD_C], sd_mac[NumGroups][SD_C];
int unsigned sd_iid[NumGroups][SD_C], sd_oid[NumGroups][SD_C], sd_elements[NumGroups][SD_C];
logic sd_valid[NumGroups][SD_E], sd_held[NumGroups][SD_E];
logic sd_single[NumGroups][SD_E];
// Hold-window expiry, per entry. sd_to is the RTL's own release pulse, taken d-side, so a window's
// entry sum equals the stats view's timeout_single/timeout_burst: mempool_group_mshr_stats.svh:86-97
// counts the SAME transition one cycle later off the q-side shadow, with the same burst_len and
// hold_cnt=0 classification. sd_subs is the subscriber count the entry died with, which separates
// "cohort never formed" from "cohort formed late".
logic sd_to[NumGroups][SD_E];
int unsigned sd_subs[NumGroups][SD_E];
// Response-side deaths, per entry, counted separately from the issue-side hold window above:
// sd_rht is a RESP_HOLD entry aged out by serve_timeout, sd_cto a cache line aged out before it
// reached its reuse target. Neither contributes to timeout_subs.
logic sd_rht[NumGroups][SD_E], sd_cto[NumGroups][SD_E];
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
    // Both debug signals are declared inside the MSHR's `ifndef TARGET_SYNTHESIS region
    // (mempool_group_mshr.sv:2160 opens it, :2234 declares), so guard the reads the same way.
`ifndef TARGET_SYNTHESIS
    assign sd_to[g][e] = `SD_MSHR(g).mshr_issue_timeout_dbg[e];
    assign sd_subs[g][e] = int'(`SD_MSHR(g).mshr_q[e].sub_reqs_num);
    assign sd_rht[g][e] = `SD_MSHR(g).mshr_resp_hold_timeout_dbg[e];
    assign sd_cto[g][e] = `SD_MSHR(g).mshr_cache_timeout_dbg[e];
`else
    assign sd_to[g][e] = 1'b0;
    assign sd_subs[g][e] = 0;
    assign sd_rht[g][e] = 1'b0;
    assign sd_cto[g][e] = 1'b0;
`endif
  end
  // Pool entries, sampled through the same per-entry shape. Guarded on SD_P, so a pool-less build
  // generates no reference to them at all.
  for (genvar p=0; p<SD_P; p++) begin : gen_pool_entry
    assign sd_pv[g][p]      = `SD_MSHR(g).pool_q_valid[p];
    assign sd_pstate[g][p]  = `SD_MSHR(g).pool_q[p].state;
    assign sd_psubn[g][p]   = int'(`SD_MSHR(g).pool_q[p].sub_reqs_num);
    assign sd_pheld[g][p]   = sd_pv[g][p] && (sd_pstate[g][p]==1) && !`SD_MSHR(g).pool_q[p].issued;
    assign sd_pcached[g][p] = sd_pv[g][p] && (sd_pstate[g][p]==3);
    assign sd_prht[g][p]     = `SD_MSHR(g).pool_resp_hold_timeout_dbg[p];
    assign sd_pcto[g][p]     = `SD_MSHR(g).pool_cache_timeout_dbg[p];
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
longint unsigned sd_eto_s[NumGroups][SD_E], sd_eto_b[NumGroups][SD_E], sd_eto_subs[NumGroups][SD_E];
longint unsigned sd_erh[NumGroups][SD_E], sd_ect[NumGroups][SD_E];
int unsigned sd_estate[NumGroups][SD_E], sd_peak[NumGroups];
longint unsigned sd_full[NumGroups];
longint unsigned sd_bh[NumGroups][NumTilesPerGroup][NumBanksPerTile];
longint unsigned sd_bs[NumGroups][NumTilesPerGroup][NumBanksPerTile];
longint unsigned sd_lh[2][NumGroups][SD_NS][4], sd_ls[2][NumGroups][SD_NS][4];
longint unsigned sd_mresp[SD_RP], sd_sresp[SD_RP];
longint unsigned sd_mreq[SD_RQ], sd_sreq[SD_RQ];
int unsigned sd_pending[NumGroups][SD_C][SD_IDS];
bit sd_pending_bench[NumGroups][SD_C][SD_IDS];

// ---------------------------------------------------------------------------------------------
// OVERFLOW POOL sampling. Pool entries are reported as ORDINARY per-entry records at ids
// SD_E+0 .. SD_E+SD_P-1, per the contract shared with the GVSoC model; the thing that marks them as
// pool rather than bank/way is the id, and the dashboard learns how many there are from
// meta.mshr_overflow_entries. SD_P is 0 for a pool-less build and every use below is guarded, so a
// K=0 build emits the meta field and nothing else.
//
// alloc and merge are edge-detected here rather than read from an RTL counter: a pool allocation is
// the rising edge of an entry's valid bit, and a pool merge is a rise in that entry's sub_reqs_num
// once it is ALREADY valid. The else-if matters -- allocation raises valid and sets sub_reqs_num to
// 1 in the same cycle, so an unguarded rise test would count every allocation as a merge as well.
// ---------------------------------------------------------------------------------------------

initial begin
  if ($value$plusargs("dashboard_file=%s",sd_file)) begin
    sd_fd=$fopen(sd_file,"w");
    if (!sd_fd) $fatal(1,"Cannot open dashboard telemetry %s",sd_file);
    if ($value$plusargs("dashboard_period=%d",sd_period)) begin end
    if (sd_period<=0) $fatal(1,"dashboard_period must be positive");
    sd_entries=$test$plusargs("dashboard_entries");
    sd_banks=$test$plusargs("dashboard_banks");
    sd_links=$test$plusargs("dashboard_links");
    $fwrite(sd_fd,"{\"kind\":\"meta\",\"schema_version\":1,\"backend\":\"rtl\",\"mesh\":[%0d,%0d],\"tiles_per_group\":%0d,\"cores_per_tile\":%0d,\"n_fpu\":%0d,\"banks_per_tile\":%0d,\"mshr_entries\":%0d,\"mshr_ways\":%0d,\"mshr_overflow_entries\":%0d,\"req_subnets\":%0d,\"resp_subnets\":%0d,\"fmac_scope\":\"unmasked vector FMAC at instruction completion\"}\n",
      NumX,NumY,NumTilesPerGroup,NumCoresPerTile,`N_FPU,NumBanksPerTile,SD_E,SD_W,SD_P,
      NumTilesPerGroup*SD_RQ,NumTilesPerGroup*SD_RP);
  end
end

task automatic sd_clear();
  foreach(sd_busy_sum[g]) begin sd_busy_sum[g]=0; sd_fmac[g]=0; sd_peak[g]=0; sd_full[g]=0; end
  foreach(sd_eocc[g,e]) begin sd_eocc[g][e]=0; sd_ecache[g][e]=0; sd_eheld[g][e]=0; sd_esingle[g][e]=0; sd_eburst[g][e]=0;
    sd_eto_s[g][e]=0; sd_eto_b[g][e]=0; sd_eto_subs[g][e]=0; sd_erh[g][e]=0; sd_ect[g][e]=0; end
  foreach(sd_poocc[g,p]) begin sd_poocc[g][p]=0; sd_pocache[g][p]=0; sd_poheld[g][p]=0; end
  // sd_pv_last / sd_psubn_last are deliberately NOT cleared here. They are the previous-value side
  // of the alloc/merge edge detectors, so clearing them per window would re-report a pool entry that
  // is still resident as a fresh allocation at every window boundary, and would hide a merge inside
  // such an entry (the rising-sub_reqs_num arm is only reachable once the entry already reads valid).
  // They are reset with the rest of the state at reset instead, below.
  foreach(sd_palloc[g]) begin sd_palloc[g]=0; sd_pmerge[g]=0; end
  foreach(sd_erhp[g,p]) begin sd_erhp[g][p]=0; sd_ectp[g][p]=0; end
  foreach(sd_bh[g,t,b]) begin sd_bh[g][t][b]=0; sd_bs[g][t][b]=0; end
  foreach(sd_lh[n,g,s,d]) begin sd_lh[n][g][s][d]=0; sd_ls[n][g][s][d]=0; end
  foreach(sd_mreq[p]) begin sd_mreq[p]=0; sd_sreq[p]=0; end
  foreach(sd_mresp[p]) begin sd_mresp[p]=0; sd_sresp[p]=0; end
endtask

task automatic sd_flush();
  longint unsigned win,occupied,single_occupied,burst_occupied,to_s,to_b,to_subs,rh_to,ct_to;
  longint unsigned pool_occupied,p_rh,p_ct;
  string ph;
  win=sd_cycle-sd_start;
  ph=sd_phase?"bench":"pre";
  if(sd_fd && win>0) begin
    for(int g=0;g<NumGroups;g++) begin
      occupied=0; single_occupied=0; burst_occupied=0; to_s=0; to_b=0; to_subs=0; rh_to=0; ct_to=0;
      pool_occupied=0; p_rh=0; p_ct=0;
      for(int e=0;e<SD_E;e++) begin
        occupied+=sd_eocc[g][e];
        single_occupied+=sd_esingle[g][e]; burst_occupied+=sd_eburst[g][e];
        to_s+=sd_eto_s[g][e]; to_b+=sd_eto_b[g][e]; to_subs+=sd_eto_subs[g][e];
        rh_to+=sd_erh[g][e]; ct_to+=sd_ect[g][e];
        if(sd_entries) $fwrite(sd_fd,"{\"kind\":\"entry\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"entry\":%0d,\"occupied\":%0d,\"capacity\":%0d,\"cached\":%0d,\"held\":%0d,\"state\":%0d,\"occupied_single\":%0d,\"occupied_burst\":%0d,\"timeout_single\":%0d,\"timeout_burst\":%0d,\"timeout_subs\":%0d,\"resp_hold_timeout\":%0d,\"cache_timeout\":%0d}\n",
          sd_start,sd_cycle,ph,g,e,sd_eocc[g][e],win,sd_ecache[g][e],sd_eheld[g][e],sd_estate[g][e],sd_esingle[g][e],sd_eburst[g][e],sd_eto_s[g][e],sd_eto_b[g][e],sd_eto_subs[g][e],sd_erh[g][e],sd_ect[g][e]);
      end
      // Pool entries as ordinary per-entry records at ids SD_E+0 .. SD_E+SD_P-1. The id is what
      // tells the dashboard these are pool, using meta.mshr_overflow_entries as the boundary.
      // occupied_single / occupied_burst are deliberately ABSENT: the schema requires them to sum
      // to occupied when present, and the pool is not classified by the banked single/burst
      // occupancy counters -- emitting zeros would fail that check rather than inform it.
      if(SD_P>0) for(int p=0;p<SD_P;p++) begin
        pool_occupied+=sd_poocc[g][p]; p_rh+=sd_erhp[g][p]; p_ct+=sd_ectp[g][p];
        if(sd_entries) $fwrite(sd_fd,"{\"kind\":\"entry\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"entry\":%0d,\"occupied\":%0d,\"capacity\":%0d,\"cached\":%0d,\"held\":%0d,\"state\":%0d,\"resp_hold_timeout\":%0d,\"cache_timeout\":%0d}\n",
          sd_start,sd_cycle,ph,g,SD_E+p,sd_poocc[g][p],win,sd_pocache[g][p],sd_poheld[g][p],sd_pstate_s[g][p],sd_erhp[g][p],sd_ectp[g][p]);
      end
      $fwrite(sd_fd,"{\"kind\":\"fpu\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"busy\":%0d,\"capacity\":%0d}\n",sd_start,sd_cycle,ph,g,sd_busy_sum[g],win*SD_C*`N_FPU);
      $fwrite(sd_fd,"{\"kind\":\"work\",\"workload_phase\":\"bench\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"fmac\":%0d}\n",sd_start,sd_cycle,ph,g,sd_fmac[g]);
      $fwrite(sd_fd,"{\"kind\":\"mshr\",\"start\":%0d,\"end\":%0d,\"phase\":\"%s\",\"g\":%0d,\"occupied\":%0d,\"capacity\":%0d,\"entries\":%0d,\"peak\":%0d,\"full\":%0d,\"occupied_single\":%0d,\"occupied_burst\":%0d,\"single_merge_target\":%0d,\"burst_merge_target\":%0d,\"timeout_single\":%0d,\"timeout_burst\":%0d,\"timeout_subs\":%0d,\"resp_hold_timeout\":%0d,\"cache_timeout\":%0d,\"overflow_alloc\":%0d,\"overflow_merge\":%0d,\"overflow_occupied\":%0d}\n",sd_start,sd_cycle,ph,g,occupied,win*SD_E,SD_E,sd_peak[g],sd_full[g],single_occupied,burst_occupied,sd_single_target[g],sd_burst_target[g],to_s,to_b,to_subs,rh_to,ct_to,sd_palloc[g],sd_pmerge[g],pool_occupied);
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
      foreach(sd_pv_last[g,p]) begin sd_pv_last[g][p]=0; sd_psubn_last[g][p]=0; sd_pstate_s[g][p]=0; end
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
          // Outside the valid branch on purpose: this counts the release EDGE, not an occupancy
          // cycle. The RTL pulse already requires mshr_q_valid, so no entry is double-counted.
          if(sd_to[g][e]) begin
            if(sd_single[g][e]) sd_eto_s[g][e]++; else sd_eto_b[g][e]++;
            sd_eto_subs[g][e]+=sd_subs[g][e];
          end
          if(sd_rht[g][e]) sd_erh[g][e]++;
          if(sd_cto[g][e]) sd_ect[g][e]++;
        end
        if(occupied>sd_peak[g]) sd_peak[g]=occupied;
        if(occupied==SD_E) sd_full[g]++;
        if(SD_P>0) for(int p=0;p<SD_P;p++) begin
          if(sd_pv[g][p]) begin
            sd_poocc[g][p]++;
            if(sd_pcached[g][p]) sd_pocache[g][p]++;
            if(sd_pheld[g][p])   sd_poheld[g][p]++;
            // Allocation is the rising edge of valid; a merge is a rise in sub_reqs_num on an
            // entry that was ALREADY valid. The else-if keeps an allocation (which sets
            // sub_reqs_num to 1 as it raises valid) from being counted as both.
            if(!sd_pv_last[g][p])                 sd_palloc[g]++;
            else if(sd_psubn[g][p] > sd_psubn_last[g][p]) sd_pmerge[g]++;
          end
          if(sd_prht[g][p]) sd_erhp[g][p]++;
          if(sd_pcto[g][p]) sd_ectp[g][p]++;
          sd_pstate_s[g][p]   = sd_pv[g][p] ? int'(sd_pstate[g][p]) : 0;
          sd_pv_last[g][p]    = sd_pv[g][p];
          sd_psubn_last[g][p] = sd_psubn[g][p];
        end
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
