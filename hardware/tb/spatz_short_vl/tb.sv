// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb;
  import spatz_pkg::*;
  import rvv_pkg::*;
  logic clk = 0;
  always #1 clk = ~clk;
  logic rst_n = 0;
  spatz_req_t req;
  logic valid = 0, ready, rsp_valid;
  vfu_rsp_t rsp;
  vrf_addr_t waddr;
  vrf_data_t wdata;
  vrf_be_t wbe;
  logic we, wready, rsp_ready;
  spatz_id_t [3:0] ids;
  vrf_addr_t [2:0] raddr;
  logic [2:0] re, rvalid;
  vrf_data_t [2:0] rdata;
  vrf_data_t mem [NrVRFWords];
  vrf_be_t available [NrVRFWords];
  logic [3:0] completed = 0;
  int cycle = 0, tests = 0;
  bit backpressure = 0, trace = 0, long_only = 0, scalar_hold = 0, vector_hold = 0;

  // The VRF grants writes only when the VFU requests a vector write.
  assign wready = we && !vector_hold && (!backpressure || cycle % 7 >= 3);
  assign rsp_ready = !scalar_hold && (!backpressure || cycle % 5 >= 2);
  always_comb for (int port = 0; port < 3; port++) begin
    rdata[port] = mem[raddr[port]];
    rvalid[port] = &available[raddr[port]];
  end
  spatz_vfu #(.FPUImplementation(MemPoolFPUImpl)) dut (
    .clk_i(clk), .rst_ni(rst_n), .hart_id_i(32'b0),
    .spatz_req_i(req), .spatz_req_valid_i(valid), .spatz_req_ready_o(ready),
    .vfu_rsp_valid_o(rsp_valid), .vfu_rsp_ready_i(rsp_ready), .vfu_rsp_o(rsp),
    .vrf_waddr_o(waddr), .vrf_wdata_o(wdata), .vrf_we_o(we), .vrf_wbe_o(wbe),
    .vrf_wvalid_i(wready), .vrf_id_o(ids), .vrf_raddr_o(raddr), .vrf_re_o(re),
    .vrf_rdata_i(rdata), .vrf_rvalid_i(rvalid), .fpu_status_o()
  );

  for (genvar lane = 0; lane < N_FPU; lane++) begin
    always @(posedge clk) if (rst_n &&
        dut.gen_fpu.gen_fpnew[lane].int_fpu_in_valid &&
        dut.gen_fpu.gen_fpnew[lane].int_fpu_in_ready && !dut.word_issued)
      $fatal(1, "FPU lane %0d accepted an unissued word", lane);
  end
  always @(posedge clk) if (rst_n) begin
    cycle <= cycle + 1;
    if (trace && tests == 0 && cycle < 50)
      $display("C%0d state=%0d busy_fp=%b fp_in=%b busy_ip=%b req=%b op=%0d issue=%b result=%h retire=%b id=%0d",
        cycle, dut.state_q, dut.is_fpu_busy,
        dut.gen_fpu.gen_fpnew[0].fpu_in_valid_q, dut.is_ipu_busy,
        dut.spatz_req_valid, dut.spatz_req.op, dut.word_issued,
        dut.result_valid, rsp_valid, rsp.id);
    if (we && wready) begin
      for (int b = 0; b < VRFWordBWidth; b++) if (wbe[b]) begin
        mem[waddr][8*b +: 8] <= wdata[8*b +: 8];
        available[waddr][b] <= 1;
      end
    end
    if (rsp_valid) begin
      if (completed[rsp.id]) $fatal(1, "duplicate completion id=%0d", rsp.id);
      completed[rsp.id] <= 1;
    end
  end

  task automatic send(input op_e op, input int id, input int vl,
      input vew_e sew, input bit dependent = 0,
      input bit widen = 0, input bit narrow = 0, input bit scalar = 0);
    @(negedge clk);
    req = '0;
    req.op = op;
    req.id = spatz_id_t'(id);
    req.ex_unit = VFU;
    // The controller counts widening source half-words twice (controller:487).
    req.vl = vlen_t'(widen ? 2*vl : vl);
    req.vtype.vsew = sew;
    req.op_arith.is_scalar = scalar;
    req.rd = 7;
    req.op_arith.widen_vs1 = widen;
    req.op_arith.widen_vs2 = widen;
    req.op_arith.is_narrowing = narrow;
    req.use_vs2 = 1;
    req.use_vs1 = op != VADD;
    req.rs1 = id == 1 && op == VADD ? 127 : 0;
    if (scalar) begin
      req.rs1 = 32'h3f800000;
      req.rs2 = 32'h3f800000;
    end
    req.vs1 = 4;
    req.vs2 = dependent ? 16 : id == 1 ? 12 : 8;
    req.vd = vreg_t'(16 + 4 * id);
    // Reserve only active destination bytes; inactive tail bytes are readable.
    for (int b = 0; b < (scalar ? 0 : vl * (1 << (int'(sew) + int'(widen)))); b++)
      available[int'(req.vd)*NrWordsPerVector + b/VRFWordBWidth][b%VRFWordBWidth] = 0;
    valid = 1;
    do @(posedge clk); while (!ready);
  endtask

  task automatic pair(input int kind, input int vl, input vew_e sew,
      input bit dependent, input bit blocked);
    bit widen, narrow;
    vew_e second_sew;
    logic [31:0] expected;
    int bytes_per_element;
    @(negedge clk);
    valid = 0;
    rst_n = 0;
    completed = 0;
    cycle = 0;
    backpressure = blocked;
    for (int a = 0; a < NrVRFWords; a++) begin
      mem[a] = sew == EW_16 ? {N_FU*2{16'h3c00}} : {N_FU{32'h3f800000}};
      available[a] = '1;
    end
    repeat (3) @(negedge clk);
    rst_n = 1;
    widen = kind == 6;
    narrow = kind == 7;
    second_sew = widen ? EW_32 : sew;
    // Narrowing reads f32 even though its destination SEW is f16.
    if (narrow)
      for (int a = 4*NrWordsPerVector; a < 12*NrWordsPerVector; a++)
        mem[a] = {N_FU{32'h3f800000}};
    // The independent integer consumer uses its own e32 source after widening.
    if (widen && !dependent)
      for (int a = 12*NrWordsPerVector; a < 13*NrWordsPerVector; a++)
        mem[a] = {N_FU{32'h3f800000}};
    case (kind)
      0, 6: send(VFADD, 0, vl, sew, 0, widen);
      1: send(VF2I, 0, vl, sew);
      2, 4: send(VADD, 0, vl, sew);
      3: send(VFADD, 0, vl, sew);
      5: send(VFMADD, 0, vl, sew);
      7: send(VF2F, 0, vl, sew, 0, 0, narrow);
    endcase
    send(kind inside {2, 3} ? VFADD : VADD, 1, vl, second_sew, dependent);
    @(negedge clk);
    valid = 0;
    repeat (200) begin
      @(negedge clk);
      if (completed[1:0] == 2'b11) break;
    end
    if (completed[1:0] != 2'b11)
      $fatal(1, "lost completion kind=%0d vl=%0d sew=%0d dep=%b bp=%b completed=%b state=%0d fp_busy=%b ip_busy=%b",
        kind, vl, sew, dependent, blocked, completed,
        dut.state_q, dut.is_fpu_busy, dut.is_ipu_busy);
    bytes_per_element = 1 << int'(second_sew);
    if (kind inside {2, 3})
      expected = second_sew == EW_32 ? (kind == 3 && dependent ? 32'h40400000 : 32'h40000000) :
                                     (kind == 3 && dependent ? 32'h4200 : 32'h4000);
    else begin
      expected = second_sew == EW_32 ? 32'h3f800000 : 32'h3c00;
      if (dependent) case (kind)
        0, 6: expected = second_sew == EW_32 ? 32'h40000000 : 32'h4000;
        1: expected = 1;
        5: expected = second_sew == EW_32 ? 32'h40000000 : 32'h4000;
        default:;
      endcase
      expected += 127;
    end
    for (int b = 0; b < vl*bytes_per_element; b++)
      if (mem[20*NrWordsPerVector + b/VRFWordBWidth][8*(b%VRFWordBWidth) +: 8] !==
          expected[8*(b%bytes_per_element) +: 8])
        $fatal(1, "wrong result kind=%0d vl=%0d sew=%0d dep=%b byte=%0d expected=%h",
          kind, vl, sew, dependent, b, expected);
    if (long_only)
      $display("LONG kind=%0d vl=%0d sew=%0d dep=%b bp=%b cycles=%0d",
        kind, vl, sew, dependent, blocked, cycle);
    tests++;
  endtask

  initial begin
    req = '0;
    trace = $test$plusargs("trace");
    if ($test$plusargs("skew")) begin
      repeat (3) @(negedge clk);
      for (int a = 0; a < NrVRFWords; a++) begin
        mem[a] = {N_FU{32'h3f800000}};
        available[a] = '1;
      end
      for (int word = 0; word < NrWordsPerVector; word++)
        mem[4*NrWordsPerVector + word] = {N_FU{32'h3f800000 + 32'(word)*32'h00800000}};
      rst_n = 1;
      send(VF2I, 0, 1, EW_32, 0, 0, 0, 1);
      @(negedge clk);
      valid = 0;
      while (!dut.word_issued) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      scalar_hold = 1;
      fork
        begin
          repeat (20) @(negedge clk);
          scalar_hold = 0;
        end
        begin
          send($test$plusargs("skew_add") ? VFADD : VF2I, 1, 12, EW_32);
          @(negedge clk);
          valid = 0;
        end
      join
      repeat (80) @(negedge clk);
      if (completed[1:0] != 2'b11) $fatal(1, "lane skew completion=%b", completed);
      for (int word = 0; word < 3; word++)
        if (mem[20*NrWordsPerVector + word] !==
            {N_FU{$test$plusargs("skew_add") ?
              (word == 0 ? 32'h40000000 : word == 1 ? 32'h40400000 : 32'h40a00000) :
              32'(1 << word)}})
          $fatal(1, "lane skew data word=%0d value=%h", word, mem[20*NrWordsPerVector + word]);
      if (dut.is_fpu_busy || dut.is_ipu_busy || |dut.result_valid)
        $fatal(1, "lane skew left an unretired result");
      $display("PASS short VL lane-skew backpressure");
      $finish;
    end
    if ($test$plusargs("reorder")) begin
      repeat (3) @(negedge clk);
      for (int a = 0; a < NrVRFWords; a++) begin
        mem[a] = {N_FU{32'h3f800000}};
        available[a] = '1;
      end
      rst_n = 1;
      send(VFADD, 0, 1, EW_32, 0, 0, 0, 1);
      @(negedge clk);
      valid = 0;
      repeat (8) @(negedge clk);
      vector_hold = 1;
      send(VF2I, 1, 4, EW_32);
      send(VFADD, 2, 4, EW_32);
      @(negedge clk);
      valid = 0;
      repeat (8) @(negedge clk);
      vector_hold = 0;
      repeat (40) @(negedge clk);
      if (completed[2:0] != 3'b111) $fatal(1, "reorder completion=%b", completed);
      if (mem[20*NrWordsPerVector] !== {N_FU{32'h00000001}} ||
          mem[24*NrWordsPerVector] !== {N_FU{32'h40000000}})
        $fatal(1, "crossed FPU tags: add=%h sign=%h", mem[20*NrWordsPerVector], mem[24*NrWordsPerVector]);
      $display("PASS short VL scalar-seeded opgroup arbitration");
      $finish;
    end
    if ($test$plusargs("mixed")) begin
      repeat (3) @(negedge clk);
      for (int a = 0; a < NrVRFWords; a++) begin
        mem[a] = {N_FU{32'h3f800000}};
        available[a] = '1;
      end
      rst_n = 1;
      scalar_hold = 1;
      fork
        begin
          repeat (16) @(negedge clk);
          scalar_hold = 0;
        end
        begin
          send(VF2I, 0, 1, EW_32, 0, 0, 0, 1);
          send(VF2I, 1, 1, EW_32, 0, 0, 0, 1);
          send(VF2I, 2, 1, EW_32, 0, 0, 0, 1);
          send(VF2I, 3, 12, EW_32);
          @(negedge clk);
          valid = 0;
        end
      join
      repeat (80) @(negedge clk);
      if (completed != 4'b1111) $fatal(1, "mixed scalar/vector completion=%b", completed);
      for (int word = 0; word < 3; word++)
        if (mem[28*NrWordsPerVector + word] !== {N_FU{32'h00000001}})
          $fatal(1, "mixed scalar/vector data word=%0d value=%h", word, mem[28*NrWordsPerVector + word]);
      $display("PASS short VL mixed scalar/vector");
      $finish;
    end
    long_only = $test$plusargs("long_only");
    // First reproduce the single-word independent FPU -> IPU switch.
    if (!long_only) pair(0, 4, EW_32, 0, 0);
    for (int sew = 1; sew <= 2; sew++)
      for (int vl = 1; vl <= (sew == 1 ? 16 : 8); vl++)
        for (int kind = 0; kind < 8; kind++)
          if ((!(kind inside {6, 7}) || sew == 1) &&
              (!long_only || vl > (sew == 1 ? 8 : 4)))
            for (int dep = 0; dep < 2; dep++)
              for (int bp = 0; bp < 2; bp++)
                pair(kind, vl, vew_e'(sew), 1'(dep), 1'(bp));
    $display("PASS short VL: %0d cases", tests);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "testbench timeout");
  end
endmodule
