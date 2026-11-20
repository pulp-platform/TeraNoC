module mempool_tb;
  wire csr_trace_any_global = 1'b0;
  import spatz_pkg::*;
  import rvv_pkg::*;
  typedef struct packed {
    logic [3:0] id;
    logic [31:0] addr;
    logic [1:0] mode, size;
    logic write;
    logic [4:0] burst_len;
    logic [3:0] strb;
    logic [31:0] data;
    logic last, spec;
  } req_t;
  typedef struct packed {
    logic [3:0] id;
    logic [31:0] data;
    logic write;
  } rsp_t;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst, valid, ready, done;
  spatz_req_t insn;
  req_t [3:0] req;
  rsp_t [3:0] rsp;
  logic [3:0] req_valid, req_ready, rsp_valid;
  logic we;
  vrf_data_t wdata;
  vrf_be_t wbe;
  vrf_addr_t waddr;
  rsp_t queue[4][$];
  rsp_t response;
  int base_addr, words, cycles, seen, burst_count;
  int lane_seen[4];
  int instruction_id = 0;
  bit [31:0] requested_words;
  logic active, done_seen;
  spatz_vlsu #(.NrMemPorts(4), .NrOutstandingLoads(16),
    .spatz_mem_req_t(req_t), .spatz_mem_rsp_t(rsp_t)) dut (
    .clk_i(clk), .rst_ni(rst), .spatz_req_i(insn),
    .spatz_req_valid_i(valid), .spatz_req_ready_o(ready),
    .vlsu_rsp_valid_o(done), .vlsu_rsp_o(),
    .vrf_waddr_o(waddr), .vrf_wdata_o(wdata), .vrf_we_o(we), .vrf_wbe_o(wbe),
    .vrf_wvalid_i(1'b1), .vrf_id_o(), .vrf_raddr_o(), .vrf_re_o(),
    .vrf_rdata_i('0), .vrf_rvalid_i('1),
    .spatz_mem_req_o(req), .spatz_mem_req_valid_o(req_valid),
    .spatz_mem_req_ready_i(req_ready), .spatz_mem_rsp_i(rsp),
    .spatz_mem_rsp_valid_i(rsp_valid), .spatz_mem_finished_o(),
    .spatz_mem_str_finished_o(), .spatz_mem_req_sent_o());

  always @(negedge clk) begin
    rsp_valid = '0;
    req_ready = (cycles % 3 == 0) ? '0 : '1;
    if (rst && active) begin
      for (int p = 0; p < 4; p++) begin
        if (queue[p].size() != 0 && ((cycles + p) % 4 != 0)) begin
          rsp[p] = queue[p].pop_front();
          rsp_valid[p] = 1;
        end
      end
    end
  end
  always @(posedge clk) begin
    if (rst && active) begin
      cycles++;
      if (done) done_seen = 1;
      for (int p = 0; p < 4; p++) begin
        if (req_valid[p] && req_ready[p]) begin
          if (req[p].burst_len > 1) begin
            burst_count++;
            if ((req[p].addr % 64) + 4 * req[p].burst_len > 64)
              $fatal(1, "cross-tile request");
            if (p != 0) $fatal(1, "unexpected burst port");
          end
          for (int b = 0; b < req[p].burst_len; b++) begin
            if (req[p].addr + 4*b < base_addr || req[p].addr + 4*b >= base_addr + 4*words)
              $fatal(1, "request outside vector extent");
            if (requested_words[(req[p].addr + 4*b - base_addr)/4])
              $fatal(1, "duplicate requested word");
            requested_words[(req[p].addr + 4*b - base_addr)/4] = 1;
            response.id = req[p].id + b / 4;
            response.data = req[p].addr + 4*b;
            response.write = 0;
            if (req[p].burst_len > 1) queue[b % 4].push_back(response);
            else queue[p].push_back(response);
          end
        end
        if (we && (wbe[4*p +: 4] != 0)) begin
          if (wbe[4*p +: 4] != 4'hf) $fatal(1, "partial word write");
          if (wdata[32*p +: 32] !== (base_addr + 4*(p + 4*lane_seen[p])))
            $fatal(1, "bad VRF lane %0d word %0d got %x expected %x base %x words %0d",
                   p, lane_seen[p], wdata[32*p +: 32],
                   base_addr + 4*(p+4*lane_seen[p]), base_addr, words);
          lane_seen[p]++;
          seen++;
        end
      end
      if (cycles > 500) $fatal(1,
        "timeout base=%x words=%0d seen=%0d empty=%b commit=%b pending=%x",
        base_addr, words, seen, dut.rob_empty, dut.commit_insn_valid, dut.mem_pending_q);
    end
  end
  task automatic run_case(input int bank, input int count, input bit fp16, input bit reset_block = 1);
    @(negedge clk);
    active = 0; valid = 0;
    if (reset_block) begin
      rst = 0;
      repeat (3) @(negedge clk);
    end
    for (int p=0; p<4; p++) begin queue[p].delete(); lane_seen[p]=0; end
    base_addr = 'h1000 + bank*4; words=count;
    seen=0; cycles=1; burst_count=0; done_seen=0; requested_words=0;
    insn='0; insn.id=spatz_id_t'(instruction_id++); insn.op=VLE; insn.ex_unit=LSU; insn.op_mem.is_load=1;
    insn.op_mem.ew=fp16 ? EW_16 : EW_32;
    insn.vtype.vsew=fp16 ? EW_16 : EW_32;
    insn.rs1=base_addr; insn.vl=fp16 ? 2*count : count; insn.use_vd=1;
    rst=1; active=1; valid=1;
    do @(posedge clk); while (!ready);
    @(negedge clk); valid=0;
    wait(seen == count);
    wait (done_seen && (dut.rob_empty == '1) && !dut.commit_insn_valid &&
          (dut.mem_pending_q == '0));
    @(negedge clk);
    if (seen != count) $fatal(1, "wrong result count got=%0d expected=%0d",seen,count);
    if ((count > 1) && ((bank+count <= 16) || (bank%4 == 0))) begin
      if (burst_count == 0) $fatal(1, "missed eligible burst bank=%0d words=%0d",bank,count);
    end else if (burst_count != 0) $fatal(1, "unsafe split used burst");
    active=0;
  endtask
  initial begin
    $dumpfile("vlsu_tile_burst.vcd");
    $dumpvars(1, mempool_tb);
    $dumpvars(0, dut.burst_len_calc, dut.burst_tile_words, dut.mem_counter_q, dut.rob_id);
    rst=0; active=0; valid=0; insn='0; cycles=0;
    for (int fp16=0; fp16<2; fp16++)
      for (int bank=0; bank<16; bank++)
        for (int count=1; count<=32; count++) run_case(bank,count,fp16);
    // Keep ROB pointers and dummy retirement state across changing request classes.
    for (int iteration=0; iteration<20; iteration++) begin
      run_case(1,3,1,0);
      run_case(12,17,0,0);
      run_case(13,2,1,0);
      run_case(1,20,0,0);
      run_case(0,32,1,0);
    end
    $display("PASS VLSU 1024 reset cases + 100 consecutive loads, FP16/FP32 VRF data");
    $finish;
  end
endmodule
