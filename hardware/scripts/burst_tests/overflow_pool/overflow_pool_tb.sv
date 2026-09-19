// Exercise overflow allocation/replay through the real DUT's external handshakes.
module overflow_pool_tb;
  timeunit 1ns;
  timeprecision 1ps;
  import mempool_pkg::*;
  localparam int NT = 4;
  localparam int NP = 3;
  localparam int NR = 3;
  localparam int Entries = 8;
  localparam int PoolNum = `TB_POOL_NUM;
  localparam tcdm_addr_t TestAddr = tcdm_addr_t'('h400);

  logic clk = 0;
  always #1 clk = ~clk;
  logic rst_n;
  tcdm_master_req_t [NT-1:0][NP-1:1] req, noc_req;
  logic [NT-1:0][NP-1:1] req_valid, req_ready, noc_req_valid, noc_req_ready;
  tcdm_master_resp_t [NT-1:0][NR-1:1] resp, noc_resp;
  logic [NT-1:0][NR-1:1] resp_valid, resp_ready, noc_resp_valid, noc_resp_ready;
  mshr_cfg_t cfg;
  logic busy;

  mempool_group_mshr #(
    .NumGroups(NumGroups), .NumTilesPerGroup(NT),
    .NumRemoteReqPortsPerTile(NP), .NumRemoteRespPortsPerTile(NR),
    .MshrNum(Entries), .MshrWaysPerBank(2), .MshrMergeReqs(4),
    .MshrOverflowNum(PoolNum), .EnableMshrSingleReq(1),
    .EnableMshrNonFullBurstReq(1), .EnableMshrFullBurstReq(1),
    .SpillReqIn(0), .SpillReqOut(0), .SpillRespIn(0), .SpillRespOut(0),
    .EnableStats(0)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .scan_enable_i(1'b0),
    .scan_data_i(1'b0), .scan_data_o(), .group_id_i(group_id_t'(0)),
    .group_mshr_req_i(req), .group_mshr_req_valid_i(req_valid),
    .group_mshr_req_ready_o(req_ready), .mshr_noc_req_o(noc_req),
    .mshr_noc_req_valid_o(noc_req_valid), .mshr_noc_req_ready_i(noc_req_ready),
    .mshr_noc_resp_i(noc_resp), .mshr_noc_resp_valid_i(noc_resp_valid),
    .mshr_noc_resp_ready_o(noc_resp_ready), .group_mshr_resp_o(resp),
    .group_mshr_resp_valid_o(resp_valid), .group_mshr_resp_ready_i(resp_ready),
    .cfg_i(cfg), .mshr_busy_o(busy)
  );

  typedef struct packed {
    int tile;
    int earliest_cycle;
    tcdm_master_resp_t value;
  } pending_t;
  pending_t pending[$];
  pending_t item;
  int cycle, fetches, received, accepted, response_beat;
  int expected_len[NT];
  tcdm_addr_t expected_addr[NT];
  int expected_tag[NT];
  data_t expected_data_base[NT];
  bit [MaxBurstWords-1:0] seen[NT];
  bit drive_response;
  string test_case;

  always @(posedge clk) begin
    if (!rst_n) begin
      pending.delete();
      cycle = 0;
      fetches = 0;
      received = 0;
      accepted = 0;
    end else begin
      cycle++;
      if (drive_response && noc_resp_ready[pending[0].tile][1])
        item = pending.pop_front();
      for (int t = 0; t < NT; t++) begin
        for (int p = 1; p < NP; p++) begin
          if (req_valid[t][p] && req_ready[t][p])
            $display("TRACE cycle=%0d input t=%0d p=%0d addr=%h len=%0d", cycle, t, p,
                     req[t][p].tgt_addr, req[t][p].burst_len);
          if (req_valid[t][p] && req_ready[t][p] && t < 2) accepted++;
          if (noc_req_valid[t][p] && noc_req_ready[t][p]) begin
            if (expected_len[t] == 0 || noc_req[t][p].tgt_addr != expected_addr[t] ||
                noc_req[t][p].mshr_tag != expected_tag[t] ||
                noc_req[t][p].burst_len != expected_len[t])
              $fatal(1, "unexpected fetch tile=%0d tag=%0d addr=%h len=%0d", t,
                     noc_req[t][p].mshr_tag, noc_req[t][p].tgt_addr,
                     noc_req[t][p].burst_len);
            fetches++;
            $display("TRACE cycle=%0d fetch t=%0d p=%0d addr=%h len=%0d tag=%0d", cycle,
                     t, p, noc_req[t][p].tgt_addr, noc_req[t][p].burst_len,
                     noc_req[t][p].mshr_tag);
            for (int b = 0; b < int'(noc_req[t][p].burst_len); b++) begin
              item = '0;
              item.tile = t;
              item.earliest_cycle = cycle + 3;
              item.value.mshr_tag = noc_req[t][p].mshr_tag;
              item.value.rdata.core_id = tile_core_id_t'(
                  int'(noc_req[t][p].wdata.core_id) + b % NumMemPortsPerSpatz);
              item.value.rdata.meta_id = meta_id_t'(
                  int'(noc_req[t][p].wdata.meta_id) + b / NumMemPortsPerSpatz);
              item.value.rdata.data = expected_data_base[t] + b;
              pending.push_back(item);
            end
          end
        end
        for (int p = 1; p < NR; p++) begin
          if (resp_valid[t][p] && resp_ready[t][p]) begin
            response_beat = int'(resp[t][p].rdata.meta_id) * NumMemPortsPerSpatz +
                            int'(resp[t][p].rdata.core_id) - 1;
            if (response_beat < 0 || response_beat >= expected_len[t] ||
                seen[t][response_beat] ||
                resp[t][p].rdata.data != expected_data_base[t] + response_beat)
              $fatal(1, "response mismatch tile=%0d beat=%0d data=%h", t,
                     response_beat, resp[t][p].rdata.data);
            seen[t][response_beat] = 1;
            received++;
            $display("TRACE cycle=%0d response t=%0d p=%0d beat=%0d data=%h", cycle,
                     t, p, response_beat, resp[t][p].rdata.data);
          end
        end
      end
      if (cycle > 500) $fatal(1, "watchdog");
    end
  end

  // Response backpressure exercises the real pool FIFO and drain path as well.
  always @(negedge clk) begin
    noc_resp = '0;
    noc_resp_valid = '0;
    drive_response = rst_n && pending.size() != 0 &&
                     cycle >= pending[0].earliest_cycle && cycle % 3 != 0;
    if (drive_response) begin
      noc_resp[pending[0].tile][1] = pending[0].value;
      noc_resp_valid[pending[0].tile][1] = 1;
    end
    resp_ready = cycle % 5 < 2 ? '0 : '1;
  end

  task automatic present(input int tile, input tcdm_addr_t addr, input int len);
    req[tile][1] = '0;
    req[tile][1].tgt_addr = addr;
    req[tile][1].tgt_group_id = group_id_t'(1);
    req[tile][1].burst_len = BurstLenWidth'(len);
    req[tile][1].wdata.core_id = tile_core_id_t'(1);
    req[tile][1].be = '1;
    req_valid[tile][1] = 1;
    #0.1;
    if (dut.req_bank[tile][1] !== 0)
      $fatal(1, "test address must hash to bank zero: %h", addr);
  endtask

  task automatic send_request(input int tile, input tcdm_addr_t addr, input int len);
    bit done;
    done = 0;
    @(negedge clk);
    present(tile, addr, len);
    for (int n = 0; n < 30; n++) begin
      @(posedge clk);
      if (req_ready[tile][1]) done = 1;
      @(negedge clk);
      if (done) break;
    end
    if (!done) $fatal(1, "request not accepted tile=%0d addr=%h", tile, addr);
    req_valid[tile][1] = 0;
  endtask

  task automatic fill_bank;
    // These two distinct long-held bursts occupy both ways of bank zero. There
    // are still six free banked entries; the pool must escape local pressure.
    send_request(2, tcdm_addr_t'('h40), 16);
    send_request(3, tcdm_addr_t'('h100), 16);
    repeat (3) @(negedge clk);
    if (dut.bank_has_free[0] !== 0 || $countones(dut.mshr_q_valid) != 2 ||
        dut.pool_q_valid != 0)
      $fatal(1, "failed to create real bank-local pressure");
  endtask

  task automatic wait_delivery(input int words, input int requests, input int fetch_count = 1);
    while (received < words && cycle < 400) @(negedge clk);
    repeat (12) @(negedge clk);
    if (received != words || fetches != fetch_count || accepted != requests)
      $fatal(1, "delivery incomplete/duplicated: accepted=%0d fetches=%0d words=%0d",
             accepted, fetches, received);
  endtask

  task automatic check_pool_off;
    @(negedge clk);
    noc_req_ready = '1;
    present(0, TestAddr, 1);
    repeat (8) begin
      @(posedge clk);
      if (req_ready[0][1] !== 0 || noc_req_valid[0][1] !== 0 ||
          dut.apb_q_v !== 0 || dut.pool_q_valid !== 0)
        $fatal(1, "pool-off request escaped the full bank");
    end
    @(negedge clk);
    req_valid = '0;
  endtask

  task automatic alloc_stall;
    expected_len[0] = 1;
    cfg.hold_window_single = '0;
    noc_req_ready = '0;
    @(negedge clk);
    present(0, TestAddr, 1);
    // A stalled source retains ownership. No entry or staged allocation may
    // consume the request until the external handshake actually occurs.
    repeat (8) begin
      @(posedge clk);
      if (req_ready[0][1] !== 0 || dut.apb_q_v !== 0 ||
          dut.pool_q_valid !== 0 || dut.apb_v !== 0)
        $fatal(1, "unaccepted request allocated pool: ready=%b staged=%b valid=%b grant=%b",
               req_ready[0][1], dut.apb_q_v, dut.pool_q_valid, dut.apb_v);
    end
    @(negedge clk);
    noc_req_ready = '1;
    @(posedge clk);
    if (req_ready[0][1] !== 1) $fatal(1, "allocation did not resume");
    @(negedge clk);
    req_valid[0][1] = 0;
    wait_delivery(1, 1);
  endtask

  task automatic owner_parallel;
    // Two eight-word bursts occupy distinct per-lane IDs (0..1 and 2..3), but
    // their old burst_len-wide metadata windows overlap. Admit the second into
    // the pool while the first banked allocation is still pending.
    @(negedge clk);
    present(0, TestAddr, 8);
    req[0][1].tgt_addr = TestAddr + tcdm_addr_t'('h10);
    #0.1;
    if (NumMemPortsPerSpatz != 4 || dut.req_bank[0][1] !== 1)
      $fatal(1, "owner-parallel setup requires four lanes and bank one");
    @(posedge clk);
    if (req_ready[0][1] !== 1) $fatal(1, "banked allocation was not accepted");
    @(negedge clk);
    present(0, TestAddr, 8);
    req[0][1].wdata.meta_id = meta_id_t'(2);
    #0.1;
    if (dut.agb_q_v[1] !== 1 || dut.req_alloc_found_pool[0][1] !== 1)
      $fatal(1, "pending banked allocation and pool grant were not exercised");
    @(posedge clk);
    if (req_ready[0][1] !== 1 || dut.apb_v !== 1)
      $fatal(1, "legal same-owner request stalled behind pending allocation");
    @(negedge clk);
    req_valid = '0;
    repeat (4) @(negedge clk);
    if (dut.pool_q_valid[0] !== 1 || accepted != 2 || fetches != 0 ||
        $countones(dut.mshr_q_valid) != 3 ||
        dut.pool_q[0].sub_reqs[0].meta_id_base !== meta_id_t'(2))
      $fatal(1, "parallel owner allocations did not remain independently resident");
  endtask

  task automatic replay_stall(input int len);
    expected_len[0] = len;
    expected_len[1] = len;
    noc_req_ready = '0;
    send_request(0, TestAddr, len);
    // An idle gap between leader and follower caught the missing pool defaults
    // in the original implementation. Preserve the leader across that gap.
    repeat (8) @(negedge clk);
    if (dut.pool_q_valid[0] !== 1 || dut.pool_q[0].sub_reqs_num !== 1 ||
        dut.pool_q[0].base_addr !== TestAddr)
      $fatal(1, "pool leader corrupted during idle gap");
    send_request(1, TestAddr, len);
    repeat (8) begin
      @(negedge clk);
      if (dut.pool_q[0].issued !== 0 || fetches != 0)
        $fatal(1, "unaccepted replay marked issued: issued=%b fetches=%0d",
               dut.pool_q[0].issued, fetches);
    end
    if (dut.pool_q[0].sub_reqs_num != 2)
      $fatal(1, "follower failed to join pool cohort");
    noc_req_ready = '1;
    wait_delivery(2 * len, 2);
  endtask

  task automatic two_entries;
    if (PoolNum != 2) $fatal(1, "two_entries requires --pool-num 2");
    expected_len[0] = 1;
    expected_len[1] = 1;
    expected_addr[1] = tcdm_addr_t'('h1000);
    expected_tag[1] = Entries + 2;
    expected_data_base[1] = 32'hcafe1000;
    cfg.hold_window_single = MshrCfgHoldCntW'(16);
    send_request(0, TestAddr, 1);
    send_request(1, expected_addr[1], 1);
    // Both entries expire while their distinct owner lanes are backpressured.
    // This also exercises nonzero pool indices and their independent response tags.
    repeat (24) @(negedge clk);
    if ($countones(dut.pool_q_valid) != 2 || fetches != 0)
      $fatal(1, "two pool entries did not remain held under egress backpressure");
    for (int p = 0; p < PoolNum; p++)
      if (dut.pool_q[p].issued !== 0)
        $fatal(1, "pool entry %0d marked issued before egress handshake", p);
    noc_req_ready = '1;
    wait_delivery(2, 2, 2);
  endtask

  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, overflow_pool_tb);
    if (!$value$plusargs("CASE=%s", test_case)) test_case = "alloc_stall";
    rst_n = 0;
    req = '0;
    req_valid = '0;
    noc_req_ready = '0;
    cfg = '0;
    drive_response = 0;
    for (int t = 0; t < NT; t++) begin
      expected_len[t] = 0;
      expected_addr[t] = TestAddr;
      expected_tag[t] = Entries + 1;
      expected_data_base[t] = 32'hcafe0000;
      seen[t] = '0;
    end
    cfg.enable = 1;
    cfg.hold_subs_single = MshrCfgSubsW'(2);
    cfg.hold_subs_burst = MshrCfgSubsW'(2);
    cfg.hold_window_single = MshrCfgHoldCntW'(1024);
    cfg.hold_window_burst = MshrCfgHoldCntW'(1024);
    cfg.serve_timeout = MshrCfgHoldCntW'(64);
    cfg.cache_reuse_target = MshrCfgSubsW'(4);
    cfg.bankfull_backpressure = 1;
    repeat (5) @(negedge clk);
    rst_n = 1;
    fill_bank();
    if (PoolNum == 0) check_pool_off();
    else if (test_case == "alloc_stall") alloc_stall();
    else if (test_case == "owner_parallel") owner_parallel();
    else if (test_case == "replay_scalar") replay_stall(1);
    else if (test_case == "replay_burst") replay_stall(8);
    else if (test_case == "two_entries") two_entries();
    else $fatal(1, "unknown CASE=%s", test_case);
    $display("PASS overflow_pool %s pool_num=%0d accepted=%0d fetches=%0d words=%0d cycles=%0d",
             test_case, PoolNum, accepted, fetches, received, cycle);
    $finish;
  end
endmodule
