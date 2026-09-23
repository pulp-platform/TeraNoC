// Deterministic miniature hierarchy for exercising probe accounting, not an RTL model.
`define TARGET_SPATZ
`define N_FPU 2
`define GROUP_MSHR_NUM 4
`define GROUP_MSHR_WAYS_PER_BANK 2
package spatz_pkg;
  typedef logic [2:0] spatz_id_t;
  typedef enum {VFU} unit_t;
  typedef enum {VFMADD,VFMSUB,VFNMADD,VFNMSUB,OTHER} op_t;
  typedef struct packed {bit is_scalar; bit is_reduction;} arith_t;
  typedef struct packed {bit[2:0] id; unit_t ex_unit; op_t op; arith_t op_arith; bit[7:0] vl; bit[7:0] vstart;} req_t;
  typedef struct packed {bit[2:0] id;} rsp_t;
endpackage
module mock_vfu;
  import spatz_pkg::*;
  req_t spatz_req_i;
  rsp_t vfu_rsp_o;
  bit spatz_req_valid_i=0,spatz_req_ready_o=1,vfu_rsp_valid_o=0;
  if(1) begin:gen_fpu
    bit[1:0] fpu_busy_q=2'b11;
  end
  initial begin
    spatz_req_i='{id:1,ex_unit:VFU,op:VFMADD,op_arith:'0,vl:8,vstart:0};
    vfu_rsp_o.id=1;
    #24 spatz_req_valid_i=1;
    #10 spatz_req_valid_i=0;
    #20 vfu_rsp_valid_o=1;
    #10 vfu_rsp_valid_o=0;
  end
endmodule
module mock_core;
  if(1) begin:i_spatz
    mock_vfu i_vfu();
  end
endmodule
module mock_tile;
  // Two remote request ports, with opposite ready masks; port zero is excluded.
  bit[2:0] tcdm_master_req_valid_o=3'b111,tcdm_master_req_ready_i=3'b011;
  bit[2:0] tcdm_slave_req_valid_i=3'b111,tcdm_slave_req_ready_o=3'b101;
  bit[1:0] superbank_req_valid=2'b11,superbank_req_ready=2'b01;
  bit[1:0] tcdm_master_resp_valid_i=2'b10,tcdm_master_resp_ready_o=2'b10;
  bit[1:0] tcdm_slave_resp_valid_o=2'b10,tcdm_slave_resp_ready_i=2'b10;
  for(genvar c=0;c<1;c++)begin:gen_cores
    if(1)begin:gen_mempool_cc
      mock_core riscv_core();
    end
  end
endmodule
module mock_mshr;
  parameter MshrNum=4,MshrWaysPerBank=2;
  bit[5:0] cfg_hold_subs_single=2,cfg_hold_subs_burst=4;
  bit[1:0] bank_has_free=2'b10;
  typedef struct packed {bit[2:0] state;bit issued;bit[4:0] burst_len;bit[3:0] sub_reqs_num;} entry_t;
  bit[3:0] mshr_q_valid=4'b0011;
  entry_t mshr_q[4];
  // Hold-window release pulses, one clock wide each, placed so exactly one is sampled while entry
  // zero is single and one after it becomes a burst. Clock edges fall on multiples of 10 ns.
  bit[3:0] mshr_issue_timeout_dbg=4'b0000;
  // Response-side deaths, driven on entry one so they cannot be confused with the issue-side
  // pulses on entry zero.
  bit[3:0] mshr_resp_hold_timeout_dbg=4'b0000,mshr_cache_timeout_dbg=4'b0000;
  // Overflow-pool signals the probe samples. Entry zero becomes valid at 70 ns and takes a merge
  // at 80 ns, so the probe's alloc (rising valid) and merge (rising sub_reqs_num on a VALID entry)
  // edge detectors both fire exactly once.
  bit[0:0] pool_q_valid=1'b0;
  entry_t pool_q[1];
  bit[0:0] pool_resp_hold_timeout_dbg=1'b0, pool_cache_timeout_dbg=1'b0;
  initial begin
    pool_q[0]='0;
    #70 pool_q_valid=1'b1; pool_q[0]='{state:1,issued:0,burst_len:1,sub_reqs_num:1};
    #10 pool_q[0].sub_reqs_num=2;   // a merge into an already-valid pool entry
  end
  initial begin
    #64 mshr_resp_hold_timeout_dbg[1]=1;  // sampled at 70 ns
    #10 mshr_resp_hold_timeout_dbg[1]=0;
        mshr_cache_timeout_dbg[1]=1;      // sampled at 80 ns
    #10 mshr_cache_timeout_dbg[1]=0;
  end
  initial begin
    mshr_q[0]='{state:1,issued:0,burst_len:1,sub_reqs_num:3};
    mshr_q[1]='{state:3,issued:1,burst_len:16,sub_reqs_num:5};
    mshr_q[2]='0;mshr_q[3]='0;
    // Reuse entry zero as a burst during a reporting window.
    #42 mshr_q[0].burst_len=16;
  end
  initial begin
    #34 mshr_issue_timeout_dbg[0]=1;  // sampled at 40 ns: single, 3 subscribers
    #10 mshr_issue_timeout_dbg[0]=0;
    #10 mshr_issue_timeout_dbg[0]=1;  // set at 54, sampled at 60 ns: now a burst
    #10 mshr_issue_timeout_dbg[0]=0;
  end
endmodule
module mock_mem;
  if(1)begin:gen_group_mshr
    mock_mshr i_group_mshr();
  end
  for(genvar t=0;t<1;t++)begin:gen_tiles
    mock_tile i_tile();
  end
endmodule
module mock_router;
  bit[3:0][0:0] valid_o='1,ready_i=4'b0101;
endmodule
module mock_group;
  mock_mem i_mempool_group();
  for(genvar t=0;t<1;t++)begin:gen_router_router_i
    for(genvar p=0;p<1;p++)begin:gen_router_narrow_req_router_j
      if(1)begin:gen_2dmesh
        mock_router i_floo_tcdm_narrow_req_router();
      end
    end
    for(genvar p=0;p<1;p++)begin:gen_router_wide_req_router_j
      if(1)begin:gen_2dmesh
        mock_router i_floo_tcdm_wide_req_router();
      end
    end
    for(genvar p=1;p<2;p++)begin:gen_router_wide_resp_router_j
      if(1)begin:gen_2dmesh
        mock_router i_floo_tcdm_wide_resp_router();
      end
    end
  end
endmodule
module mock_dut;
  if(1)begin:i_mempool_cluster
    for(genvar x=0;x<2;x++)begin:gen_groups_x
      for(genvar y=0;y<2;y++)begin:gen_groups_y
        if(1)begin:gen_rtl_group
          mock_group i_group();
        end
      end
    end
  end
endmodule
module mempool_tb;
  parameter NumX=2,NumY=2,NumGroups=4,NumTilesPerGroup=1,NumCoresPerTile=1;
  parameter NumBanksPerTile=2,NumNarrowRemoteReqPortsPerTile=1,NumWideRemoteReqPortsPerTile=1;
  parameter NumRemoteRespPortsPerTile=2;
  localparam bit MshrSplit=0;
  localparam int MshrNumSlices=1;
  bit clk=0,rst_n=0,csr_trace_any_global=0;
  always #5 clk=~clk;
  mock_dut dut();
  initial begin
    #12 rst_n=1;
    #10 csr_trace_any_global=1;
    #60 csr_trace_any_global=0;
    #10 $finish;
  end
  `include "dashboard_probe.svh"
endmodule
