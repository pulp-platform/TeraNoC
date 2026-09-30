// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module chain;
  import spatz_pkg::*;
  import rvv_pkg::*;
  typedef struct packed {
    logic [5:0] id;
    logic [31:0] data_op, data_arga, data_argb, data_argc;
  } issue_t;
  typedef struct packed {
    logic accept, writeback, loadstore, isfloat;
  } issue_rsp_t;
  typedef struct packed {
    logic [5:0] id;
    logic [31:0] data;
    logic write;
  } rsp_t;
  logic clk = 0, rst_n = 0;
  always #1 clk = ~clk;
  issue_t issue;
  issue_rsp_t issue_rsp;
  rsp_t rsp;
  logic valid = 0, ready, rsp_valid;
  spatz_req_t req;
  logic req_valid, fu_ready, fu_valid, fu_rsp_ready;
  vfu_rsp_t fu_rsp;
  vrf_addr_t [2:0] wa;
  vrf_data_t [2:0] wd;
  vrf_be_t [2:0] be;
  logic [2:0] we, sb_we, wvalid;
  vrf_addr_t [5:0] ra;
  vrf_data_t [5:0] rd;
  logic [5:0] re, sb_re, rvalid;
  spatz_id_t [8:0] ids;
  int cycle = 0;
  logic init = 0;
  vrf_addr_t init_addr = 0;
  logic slide_ready, slide_valid;
  vsldu_rsp_t slide_rsp;
  assign sb_re[4:3] = 0;
  assign ra[4:3] = '0;
  assign sb_we[1] = init;
  assign wa[1] = init_addr;
  assign wd[1] = {N_FU{32'h3f800000}};
  assign be[1] = '1;
  assign ids[7] = '0;
  assign ids[4:3] = '0;
  spatz_controller #(
    .NrVregfilePorts(9), .NrWritePorts(3),
    .spatz_issue_req_t(issue_t), .spatz_issue_rsp_t(issue_rsp_t), .spatz_rsp_t(rsp_t)
  ) con (
    .clk_i(clk), .rst_ni(rst_n), .issue_valid_i(valid), .issue_ready_o(ready),
    .issue_req_i(issue), .issue_rsp_o(issue_rsp), .rsp_valid_o(rsp_valid),
    .rsp_ready_i(1'b1), .rsp_o(rsp), .fpu_rnd_mode_i(fpnew_pkg::RNE),
    .fpu_fmt_mode_i('0), .spatz_req_valid_o(req_valid), .spatz_req_o(req),
    .vfu_req_ready_i(fu_ready), .vfu_rsp_valid_i(fu_valid),
    .vfu_rsp_ready_o(fu_rsp_ready), .vfu_rsp_i(fu_rsp),
    .vlsu_req_ready_i(1'b1), .vlsu_rsp_valid_i(1'b0), .vlsu_rsp_i('0),
    .vsldu_req_ready_i(slide_ready), .vsldu_rsp_valid_i(slide_valid), .vsldu_rsp_i(slide_rsp),
    .sb_enable_i({sb_we,sb_re}), .sb_enable_o({we,re}),
    .sb_wrote_result_i(wvalid), .sb_id_i(ids)
  );
  spatz_vrf #(.NrReadPorts(6), .NrWritePorts(3)) vrf (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .waddr_i(wa), .wdata_i(wd), .we_i(we), .wbe_i(be), .wvalid_o(wvalid),
    .raddr_i(ra), .re_i(re), .rdata_o(rd), .rvalid_o(rvalid)
  );
  spatz_vfu #(.FPUImplementation(MemPoolFPUImpl)) fu (
    .clk_i(clk), .rst_ni(rst_n), .hart_id_i(32'b0),
    .spatz_req_i(req), .spatz_req_valid_i(req_valid), .spatz_req_ready_o(fu_ready),
    .vfu_rsp_valid_o(fu_valid), .vfu_rsp_ready_i(fu_rsp_ready), .vfu_rsp_o(fu_rsp),
    .vrf_waddr_o(wa[0]), .vrf_wdata_o(wd[0]), .vrf_we_o(sb_we[0]),
    .vrf_wbe_o(be[0]), .vrf_wvalid_i(wvalid[0]),
    .vrf_id_o({ids[6],ids[2:0]}), .vrf_raddr_o(ra[2:0]),
    .vrf_re_o(sb_re[2:0]), .vrf_rdata_i(rd[2:0]), .vrf_rvalid_i(rvalid[2:0]),
    .fpu_status_o()
  );
  spatz_vsldu slide (
    .clk_i(clk), .rst_ni(rst_n), .spatz_req_i(req), .spatz_req_valid_i(req_valid),
    .spatz_req_ready_o(slide_ready), .vsldu_rsp_valid_o(slide_valid),
    .vsldu_rsp_o(slide_rsp), .vrf_waddr_o(wa[2]), .vrf_wdata_o(wd[2]),
    .vrf_we_o(sb_we[2]), .vrf_wbe_o(be[2]), .vrf_wvalid_i(wvalid[2]),
    .vrf_id_o({ids[8],ids[5]}), .vrf_raddr_o(ra[5]), .vrf_re_o(sb_re[5]),
    .vrf_rdata_i(rd[5]), .vrf_rvalid_i(rvalid[5])
  );
  logic [NrParallelInstructions-1:0] slide_active = '0;
  int slide_remaining[NrParallelInstructions];
  vrf_addr_t slide_address[NrParallelInstructions];
  vrf_data_t slide_data[NrParallelInstructions];
  int slide_completions = 0;
  always @(posedge clk) if (rst_n) begin
    if (con.spatz_req_valid && req.ex_unit == SLD) begin
      if (slide_active[req.id]) $fatal(1, "slide ID reused before completion");
      slide_active[req.id] = 1;
      slide_remaining[req.id] = int'(req.vl) << req.vtype.vsew;
      slide_address[req.id] = vrf_addr_t'(req.vd * NrWordsPerVector);
      slide_data[req.id] = req.vtype.vsew == EW_16 ? {2*N_FU{req.rs1[15:0]}} :
                                                   {N_FU{req.rs1}};
    end
    if (we[2] && wvalid[2]) begin
      automatic int id = ids[8];
      if (!slide_active[id] || wa[2] != slide_address[id])
        $fatal(1, "slide write has wrong ID/address id=%0d addr=%0d", id, wa[2]);
      for (int b = 0; b < VRFWordBWidth; b++) begin
        if (be[2][b] != (b < slide_remaining[id]))
          $fatal(1, "slide byte enable mismatch id=%0d byte=%0d", id, b);
        if (be[2][b] && wd[2][b*8 +: 8] !== slide_data[id][b*8 +: 8])
          $fatal(1, "slide data mismatch id=%0d byte=%0d", id, b);
      end
      slide_remaining[id] -= VRFWordBWidth;
      slide_address[id]++;
    end
    if (slide_valid) begin
      if (!slide_active[slide_rsp.id] || slide_remaining[slide_rsp.id] > 0)
        $fatal(1, "slide completed before all writes");
      slide_active[slide_rsp.id] = 0;
      slide_completions++;
    end
  end
  always @(posedge clk) if (rst_n) begin
    cycle++;
    if (cycle < 120 || cycle % 1000 == 0)
      $display("CHAIN c=%0d req=%b/%0d/%0d fu=%b/%0d read=%b issue=%b running=%b pending=%b sb=%p tables_w24=%p/%p tables_r24=%p/%p",
        cycle, fu.spatz_req_valid, fu.spatz_req.id, fu.spatz_req.op,
        fu_valid, fu_rsp.id, rvalid[2:0], fu.word_issued, con.running_insn_q,
        con.vfu_rsp_pending_q, con.scoreboard_q, con.write_table_q[24], con.write_table_q[28], con.read_table_q[24], con.read_table_q[28]);
  end
  task automatic send(input logic [31:0] insn, input logic [31:0] arg = 32'h3f800000);
    @(negedge clk);
    valid = 0;
    repeat ($urandom_range(0, 4)) @(negedge clk);
    issue = '{id: 0, data_op: insn, data_arga: arg, data_argb: 0, data_argc: 0};
    valid = 1;
    do @(posedge clk); while (!ready);
    if (!issue_rsp.accept) $fatal(1, "illegal instruction %h", insn);
  endtask
  task automatic drain;
    @(negedge clk);
    valid = 0;
    repeat (100) begin
      @(negedge clk);
      if (con.running_insn_q == 0 && !fu.spatz_req_valid && !slide.spatz_req_valid) begin
        if (slide_active != 0) $fatal(1, "slide completion missing");
        return;
      end
    end
    $fatal(1, "chain stuck running=%b sb=%p", con.running_insn_q, con.scoreboard_q);
  endtask
  initial begin
    issue = '0;
    repeat (3) @(negedge clk);
    init = 1;
    for (int regnum = 0; regnum < 32*NrWordsPerVector; regnum++) begin
      init_addr = vrf_addr_t'(regnum);
      @(negedge clk);
    end
    init = 0;
    rst_n = 1;
    for (int format = 0; format < 4; format++)
    for (int trial = 0; trial < 30; trial++)
    for (int length = 0; length < 10; length++) begin
      automatic int avl = length == 0 ? (format < 2 ? 16 : 32) :
                          length == 1 ? (format < 2 ? 15 : 31) : 10-length;
      send(32'h00057057 | ((32'hc0 | ((format < 2 ? 2 : 1) << 3) |
            ((format % 2) == 0 ? 2 : 0)) << 20), avl); // e32/e16, m4/m1
      drain();
      for (int iteration = 0; iteration < 4; iteration++) begin
        send(32'hb2821c57); // vfmacc v24,v4,v8
        send(32'hb28c1e57); // vfmacc v28,v24,v8
        send(32'hb28e1c57); // vfmacc v24,v28,v8
        send(32'h03064857, 127); // independent vadd v16,v16
      end
      drain();
      $display("CHAIN P4 vl=%0d OK", avl);
      for (int iteration = 0; iteration < 4; iteration++) begin
        send(32'h5e015c57, format < 2 ? 32'h3f800000 : 32'hffff3c00); // vfmv v24,ft2
        send(32'hb2ce1c57); // vfmacc v24,v28,v12
        send(32'h5e015e57, format < 2 ? 32'h3f800000 : 32'hffff3c00); // vfmv v28,ft2
        send(32'hb2cc1e57); // vfmacc v28,v24,v12
      end
      drain();
      $display("CHAIN moves vl=%0d OK", avl);
    end
    $display("PASS short VL controller/VRF chain slide_completions=%0d", slide_completions);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "chain timeout");
  end
endmodule
