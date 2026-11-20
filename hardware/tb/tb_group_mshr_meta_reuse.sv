// Check requester metadata reuse through the real MSHR external handshakes.
module tb_group_mshr_meta_reuse;
  timeunit 1ns;
  timeprecision 1ps;
  import mempool_pkg::*;
  localparam int NT = 4;
  localparam int NP = 3;
  localparam int NR = 3;
  localparam int Entries = 8;
  localparam int PoolNum = 1;

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
    .EnableRespCache(0), .EnableStats(0)
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

  // Score by the complete requester response key, never by the NoC tag. A key
  // can be reused only after its previous response has been consumed.
  bit expected[NT][16][32];
  data_t expected_data[NT][16][32];
  tcdm_master_req_t fetched[16];
  int fetched_tile[16];
  int fetches, received, cycle, follower_received;
  bit block_follower;

  always @(posedge clk) begin
    if (rst_n) begin
      cycle++;
      for (int t = 0; t < NT; t++) begin
        for (int p = 1; p < NP; p++) begin
          if (noc_req_valid[t][p] && noc_req_ready[t][p]) begin
            if (fetches >= 16) $fatal(1, "too many NoC requests");
            fetched[fetches] = noc_req[t][p];
            fetched_tile[fetches] = t;
            $display("FETCH %0d tile=%0d addr=%h tag=%0d meta=%0d", fetches, t,
                     noc_req[t][p].tgt_addr, noc_req[t][p].mshr_tag,
                     noc_req[t][p].wdata.meta_id);
            fetches++;
          end
        end
        for (int p = 1; p < NR; p++) begin
          if (resp_valid[t][p] && resp_ready[t][p]) begin
            if (!expected[t][resp[t][p].rdata.core_id][resp[t][p].rdata.meta_id] ||
                expected_data[t][resp[t][p].rdata.core_id][resp[t][p].rdata.meta_id]
                    !== resp[t][p].rdata.data)
              $fatal(1, "unexpected/duplicate response tile=%0d core=%0d meta=%0d data=%h",
                     t, resp[t][p].rdata.core_id, resp[t][p].rdata.meta_id,
                     resp[t][p].rdata.data);
            expected[t][resp[t][p].rdata.core_id][resp[t][p].rdata.meta_id] = 0;
            received++;
            if (t == 1) follower_received++;
          end
        end
      end
      if (cycle > 2000) $fatal(1, "watchdog");
    end
  end

  always @(negedge clk) begin
    resp_ready = cycle % 5 < 2 ? '0 : '1;
    if (block_follower && follower_received == 15) resp_ready[1] = '0;
  end

  task automatic expect_words(input int tile, input int meta, input int len,
                              input data_t data_base);
    for (int b = 0; b < len; b++) begin
      if (expected[tile][1 + b % 4][(meta + b / 4) % 32])
        $fatal(1, "test attempted premature metadata reuse");
      expected[tile][1 + b % 4][(meta + b / 4) % 32] = 1;
      expected_data[tile][1 + b % 4][(meta + b / 4) % 32] = data_base + b;
    end
  endtask

  // Called at a falling edge; successive calls issue on adjacent cycles.
  task automatic send(input int tile, input int address, input int meta,
                      input int len, input data_t data_base);
    bit done;
    expect_words(tile, meta, len, data_base);
    req[tile][1] = '0;
    req[tile][1].tgt_addr = tcdm_addr_t'(address);
    req[tile][1].tgt_group_id = group_id_t'(1);
    req[tile][1].burst_len = BurstLenWidth'(len);
    req[tile][1].wdata.core_id = tile_core_id_t'(1);
    req[tile][1].wdata.meta_id = meta_id_t'(meta);
    req[tile][1].be = '1;
    req_valid[tile][1] = 1;
    done = 0;
    for (int n = 0; n < 40; n++) begin
      @(posedge clk);
      if (req_ready[tile][1]) done = 1;
      @(negedge clk);
      if (done) break;
    end
    if (!done) $fatal(1, "request stalled addr=%h meta=%0d", address, meta);
    req_valid[tile][1] = 0;
  endtask

  task automatic wait_fetches(input int count);
    for (int n = 0; n < 100; n++) begin
      if (fetches == count) return;
      @(negedge clk);
    end
    $fatal(1, "expected %0d fetches, got %0d", count, fetches);
  endtask

  // Preserve valid and payload until ready. Reverse beat order exercises tagged
  // capture independently of arrival order; output backpressure is periodic.
  task automatic reply(input int idx, input data_t data_base);
    int tile;
    tile = fetched_tile[idx];
    for (int b = int'(fetched[idx].burst_len) - 1; b >= 0; b--) begin
      noc_resp[tile][1] = '0;
      noc_resp[tile][1].mshr_tag = fetched[idx].mshr_tag;
      noc_resp[tile][1].rdata.core_id = tile_core_id_t'(1 + b % 4);
      noc_resp[tile][1].rdata.meta_id = meta_id_t'(
          int'(fetched[idx].wdata.meta_id) + b / 4);
      noc_resp[tile][1].rdata.data = data_base + b;
      noc_resp_valid[tile][1] = 1;
      do @(posedge clk); while (!noc_resp_ready[tile][1]);
      @(negedge clk);
      noc_resp_valid[tile][1] = 0;
    end
  endtask

  task automatic wait_received(input int count);
    for (int n = 0; n < 300; n++) begin
      if (received == count) return;
      @(negedge clk);
    end
    $fatal(1, "expected %0d responses, got %0d", count, received);
  endtask

  initial begin
    rst_n = 0;
    req = '0;
    req_valid = '0;
    noc_req_ready = '1;
    noc_resp = '0;
    noc_resp_valid = '0;
    resp_ready = '0;
    fetches = 0;
    received = 0;
    follower_received = 0;
    cycle = 0;
    block_follower = 0;
    cfg = '0;
    cfg.enable = 1;
    cfg.hold_subs_single = MshrCfgSubsW'(1); // scalar uses tag-zero bypass
    cfg.hold_subs_burst = MshrCfgSubsW'(4);
    cfg.serve_timeout = MshrCfgHoldCntW'(2047);
    cfg.cache_timeout = MshrCfgHoldCntW'(2047);
    cfg.bankfull_backpressure = 1;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (3) @(negedge clk);

    // Three distinct requests use legal disjoint four-row IDs, although their
    // old sixteen-ID conservative ranges overlap. All addresses hash to bank 0:
    // its two ways fill and the third request must allocate in the pool.
    send(0, 'h40, 0, 16, 'h1000);
    send(0, 'h100, 4, 16, 'h2000);
    send(0, 'h1000, 8, 16, 'h3000);
    // Another bank must also admit a legal range overlapping the live pool's
    // former conservative metadata range.
    send(0, 'h80, 12, 16, 'h4000);
    send(0, 'h800, 16, 1, 'h7000);
    wait_fetches(5);
    if (fetched[0].mshr_tag == 0 || fetched[0].mshr_tag > Entries ||
        fetched[1].mshr_tag == fetched[0].mshr_tag ||
        fetched[1].mshr_tag == 0 || fetched[1].mshr_tag > Entries ||
        fetched[2].mshr_tag != Entries + 1 ||
        fetched[3].mshr_tag <= 2 || fetched[3].mshr_tag > Entries ||
        fetched[4].mshr_tag != 0)
      $fatal(1, "expected distinct bank, pool and bypass tags");
    reply(4, 'h7000);
    reply(3, 'h4000);
    reply(2, 'h3000);
    reply(1, 'h2000);
    reply(0, 'h1000);
    wait_received(65);
    repeat (20) @(negedge clk);

    // A merged subscriber keeps the old entry alive after tile 0 consumed its
    // data. Tile 0 now legally reuses the exact old IDs at a different address.
    block_follower = 1;
    send(0, 'h40, 0, 16, 'h5000);
    send(1, 'h40, 0, 16, 'h5000);
    wait_fetches(6);
    reply(5, 'h5000);
    wait_received(96);
    if (dut.mshr_q_valid == '0) $fatal(1, "old entry must still serve its follower");
    send(0, 'h100, 0, 16, 'h6000);
    wait_fetches(7);
    if (fetched[6].mshr_tag == fetched[5].mshr_tag)
      $fatal(1, "live old entry tag reused");
    reply(6, 'h6000);
    wait_received(112);
    block_follower = 0;
    wait_received(113);
    repeat (20) @(negedge clk);
    if (received != 113 || fetches != 7) $fatal(1, "duplicate traffic");
    foreach (expected[t, c, m])
      if (expected[t][c][m]) $fatal(1, "missing response");
    $display("PASS metadata reuse: bank/pool/bypass tags, reverse replies, owner reuse, 113 words");
    $finish;
  end
endmodule
