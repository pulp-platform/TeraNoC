// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// VLSU statistics reference this top-level window signal.
module mempool_tb;
  import spatz_pkg::*;
  import rvv_pkg::*;
  wire csr_trace_any_global = 0;
  logic clk = 0, rst_n = 0;
  always #1 clk = ~clk;
  spatz_req_t req;
  logic valid = 0, ready, done, we, wready;
  spatz_mem_req_t [3:0] mr;
  spatz_mem_rsp_t [3:0] ms;
  logic [3:0] mv, mready, sv = '0;
  vrf_addr_t waddr;
  vrf_data_t wdata;
  vrf_be_t wbe;
  spatz_id_t [2:0] ids;
  vlsu_rsp_t rsp;
  typedef struct packed {
    spatz_mem_rsp_t data;
    int due;
  } beat_t;
  beat_t pending[4][$];
  int cycle = 0, cases = 0, completions = 0;
  logic [NrParallelInstructions-1:0] active = '0;
  int remaining[NrParallelInstructions];
  int length_bytes[NrParallelInstructions];
  int source_address[NrParallelInstructions];
  int element_bytes[NrParallelInstructions];
  int stride_bytes[NrParallelInstructions];
  vrf_addr_t destination[NrParallelInstructions];
  logic [511:0] wrote[NrParallelInstructions];
  bit blocked = 0;
  bit saw_rob_full = 0;

  assign wready = we && (!blocked || cycle % 11 >= 6);
  for (genvar p = 0; p < 4; p++)
    assign mready[p] = !blocked || (cycle + p) % 7 >= 2;

  spatz_vlsu #(.NrMemPorts(4), .NrOutstandingLoads(32),
    .spatz_mem_req_t(spatz_mem_req_t), .spatz_mem_rsp_t(spatz_mem_rsp_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .spatz_req_i(req),
    .spatz_req_valid_i(valid), .spatz_req_ready_o(ready),
    .vlsu_rsp_valid_o(done), .vlsu_rsp_o(rsp),
    .vrf_waddr_o(waddr), .vrf_wdata_o(wdata), .vrf_we_o(we),
    .vrf_wbe_o(wbe), .vrf_wvalid_i(wready), .vrf_id_o(ids),
    .vrf_raddr_o(), .vrf_re_o(), .vrf_rdata_i('0), .vrf_rvalid_i('1),
    .spatz_mem_req_o(mr), .spatz_mem_req_valid_o(mv),
    .spatz_mem_req_ready_i(mready), .spatz_mem_rsp_i(ms),
    .spatz_mem_rsp_valid_i(sv), .spatz_mem_finished_o(),
    .spatz_mem_str_finished_o(), .spatz_mem_req_sent_o()
  );

  function automatic logic [31:0] memory_word(input int address);
    for (int b = 0; b < 4; b++) memory_word[8*b +: 8] = 8'(address + b);
  endfunction

  // Expand bursts into word-indexed lanes/ROB rows, independently of the
  // DUT's allocation counters. Return delayed beats in varying order.
  always @(posedge clk) if (rst_n) begin
    cycle++;
    saw_rob_full |= |dut.rob_full;
    if ($test$plusargs("trace") && cases == 2)
      $display("LD c=%0d req=%b/%0d commit=%b/%0d pop=%b cnt=%p fin=%b rvalid=%b dummy=%b wi=%b/%b/%0d wd=%h rsp=%b",
        cycle, dut.mem_spatz_req_valid, dut.mem_spatz_req.id,
        dut.commit_insn_valid, dut.commit_insn_q.id, dut.commit_insn_pop,
        dut.commit_counter_q, dut.commit_finished_q, dut.rob_rvalid, dut.rob_dummy,
        dut.vrf_req_valid_d, dut.vrf_req_ready_d, dut.vrf_req_d.rsp.id,
        dut.vrf_req_d.wdata, done);
    sv <= '0;
    for (int p = 0; p < 4; p++) begin
      if (mv[p] && mready[p]) begin
        if (mr[p].write) $fatal(1, "Unexpected store");
        for (int k = 0; k < int'(mr[p].burst_len); k++) begin
          automatic int lane = mr[p].burst_len > 1 ? k % 4 : p;
          automatic beat_t beat;
          if (mr[p].burst_len > 1 && p != 0) $fatal(1, "Burst on nonzero port");
          beat.data = '{id: MemRspIdWidth'(mr[p].id + k/4),
            data: memory_word((int'(mr[p].addr) & ~3) + 4*k), err: 0, write: 0};
          beat.due = cycle + (blocked ? $urandom_range(1, 12) : 1);
          pending[lane].push_back(beat);
        end
      end
    end
    for (int p = 0; p < 4; p++) begin
      for (int k = pending[p].size()-1; k >= 0; k--) begin
        if (pending[p][k].due <= cycle) begin
          automatic beat_t beat = pending[p][k];
          pending[p].delete(k);
          ms[p] <= beat.data;
          sv[p] <= 1;
          break;
        end
      end
    end
    if (we && wready) begin
      automatic int id = ids[2];
      if (!active[id]) $fatal(1, "Write with inactive ID %0d", id);
      for (int b = 0; b < VRFWordBWidth; b++) if (wbe[b]) begin
        automatic int offset = (int'(waddr) - int'(destination[id])) * VRFWordBWidth + b;
        if (offset < 0 || offset >= length_bytes[id] || wrote[id][offset])
          $fatal(1, "Write ID/address/byte mismatch id=%0d offset=%0d", id, offset);
        if (wdata[8*b +: 8] !== 8'(source_address[id] +
            (offset / element_bytes[id]) * stride_bytes[id] + offset % element_bytes[id]))
          $fatal(1, "Load data mismatch id=%0d offset=%0d data=%h", id, offset, wdata);
        wrote[id][offset] = 1;
        remaining[id]--;
      end
    end
    if (done) begin
      if (!active[rsp.id] || remaining[rsp.id] != 0)
        $fatal(1, "Load completed before its writes id=%0d left=%0d",
          rsp.id, remaining[rsp.id]);
      active[rsp.id] = 0;
      completions++;
    end
  end

  task automatic send(input int id, input int length, input vew_e sew,
      input int address, input int stride = 0);
    @(negedge clk);
    if (active[id]) $fatal(1, "ID reused before completion");
    active[id] = 1;
    remaining[id] = length << sew;
    length_bytes[id] = remaining[id];
    source_address[id] = address;
    element_bytes[id] = 1 << sew;
    stride_bytes[id] = stride == 0 ? element_bytes[id] : stride;
    destination[id] = vrf_addr_t'((4 + 8*id) * NrWordsPerVector);
    wrote[id] = '0;
    req = '0;
    req.op = stride == 0 ? VLE : VLSE;
    req.ex_unit = LSU;
    req.id = spatz_id_t'(id);
    req.vd = vreg_t'(4 + 8*id);
    req.use_vd = 1;
    req.vl = vlen_t'(length);
    req.rs1 = address;
    req.rs2 = stride;
    req.vtype.vsew = sew;
    req.vtype.vlmul = LMUL_4;
    req.op_mem.is_load = 1;
    valid = 1;
    do @(posedge clk); while (!ready);
  endtask

  task automatic drain;
    @(negedge clk); valid = 0;
    repeat (600) begin
      @(negedge clk);
      if (active == 0 && &dut.rob_empty && dut.mem_pending_q == 0 && mv == 0) begin
        for (int p = 0; p < 4; p++) begin
          if (pending[p].size() != 0) $fatal(1, "Unconsumed memory responses");
          if (dut.rob_id[p] != dut.rob_id[0])
            $fatal(1, "Unequal ROB allocations lane=%0d IDs=%p", p, dut.rob_id);
        end
        return;
      end
    end
    $fatal(1, "Load drain stalled active=%h pending=%p commit=%p IDs=%p",
      active, dut.mem_pending_q, dut.commit_counter_q, dut.rob_id);
  endtask

  initial begin
    req = '0; ms = '0;
    repeat (3) @(negedge clk); rst_n = 1;
    for (int sew = ($test$plusargs("load_e32") ? 2 : 0); sew <= 2; sew++)
    for (int pressure = 0; pressure < 2; pressure++)
    for (int start = 0; start < 8; start++)
    for (int length = (($test$plusargs("load_long") ? 256 : 64) >> sew);
         length >= 1; length--) begin
      automatic int address = 32'h22400 + (start == 3 ? 60 : start < 4 ? 4*start :
                                  start == 4 ? 1 << sew : start == 5 ? 60 + (1 << sew) : 0);
      automatic int stride = start < 6 ? 0 : (1 << sew) * (start == 6 ? 4 : 3);
      if (sew == 2 && start inside {4, 5}) continue;
      blocked = 1'(pressure);
      // The original P4 setup loads v12/v4/v8 back to back at each VL.
      for (int id = 0; id < 3; id++)
        send(id, length, vew_e'(sew), address + 64*id, stride);
      drain();
      cases++;
      $display("LOAD sew=%0d vl=%0d addr=%h pressure=%0d OK", sew, length, address, pressure);
    end
    if ($test$plusargs("load_long") && !saw_rob_full)
      $fatal(1, "Maximum m4 sweep did not exercise a full ROB");
    $display("PASS short VL loads: %0d cases, %0d completions, ROB full=%0d",
      cases, completions, saw_rob_full);
    $finish;
  end
  initial begin #4000000; $fatal(1, "Load regression timeout"); end
endmodule
