// Directed response lifecycle checks against the real MSHR. State seeding isolates
// rare simultaneous events; all response and merge handshakes use the DUT ports.
`timescale 1ns/1ps
module pool_response_tb;
  import mempool_pkg::*;
  localparam int NT = 4;
  localparam int NP = 3;
  localparam int NR = 3;
  localparam int MN = 8;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n;
  tcdm_master_req_t [NT-1:0][NP-1:1] req, noc_req;
  logic [NT-1:0][NP-1:1] req_valid, req_ready, noc_req_valid, noc_req_ready;
  tcdm_master_resp_t [NT-1:0][NR-1:1] resp, noc_resp;
  logic [NT-1:0][NR-1:1] resp_valid, resp_ready, noc_resp_valid, noc_resp_ready;
  mshr_cfg_t cfg;
  string test_case;
  int errors;
  int seed_len;

  mempool_group_mshr #(
    .NumGroups(NumGroups), .NumTilesPerGroup(NT),
    .NumRemoteReqPortsPerTile(NP), .NumRemoteRespPortsPerTile(NR),
    .MshrNum(MN), .MshrWaysPerBank(2), .MshrMergeReqs(4),
    .MshrOverflowNum(`TB_POOL_NUM), .EnableMshrSingleReq(1),
    .EnableMshrNonFullBurstReq(1), .EnableMshrFullBurstReq(1),
    .SpillReqIn(0), .SpillReqOut(0), .SpillRespIn(0), .SpillRespOut(0)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .scan_enable_i(1'b0),
    .scan_data_i(1'b0), .scan_data_o(), .group_id_i(group_id_t'(0)),
    .group_mshr_req_i(req), .group_mshr_req_valid_i(req_valid),
    .group_mshr_req_ready_o(req_ready), .mshr_noc_req_o(noc_req),
    .mshr_noc_req_valid_o(noc_req_valid), .mshr_noc_req_ready_i(noc_req_ready),
    .mshr_noc_resp_i(noc_resp), .mshr_noc_resp_valid_i(noc_resp_valid),
    .mshr_noc_resp_ready_o(noc_resp_ready), .group_mshr_resp_o(resp),
    .group_mshr_resp_valid_o(resp_valid), .group_mshr_resp_ready_i(resp_ready),
    .cfg_i(cfg), .mshr_busy_o()
  );

  task automatic check(input bit ok, input string what);
    if (!ok) begin
      errors++;
      $display("FAIL %s: %s", test_case, what);
    end
  endtask

  task automatic reset_dut;
    rst_n = 0;
    req = '0; req_valid = '0; noc_req_ready = '1;
    noc_resp = '0; noc_resp_valid = '0; resp_ready = '0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);
  endtask

  // Force/release deposits are made away from the clock edge. All forces are
  // released before the next edge, where the real sequential logic resumes.
  task automatic seed_pool(input int len, input bit draining);
    seed_len = len;
    force dut.pool_q[0] = '0;
    release dut.pool_q[0];
    force dut.pool_q_valid[0] = 1'b1;
    release dut.pool_q_valid[0];
    force dut.pool_q[0].base_addr = tcdm_addr_t'('h120);
    release dut.pool_q[0].base_addr;
    force dut.pool_q[0].tgt_group_id = group_id_t'(1);
    release dut.pool_q[0].tgt_group_id;
    force dut.pool_q[0].burst_len = BurstLenWidth'(seed_len);
    release dut.pool_q[0].burst_len;
    force dut.pool_q[0].beats_left = BurstLenWidth'(seed_len);
    release dut.pool_q[0].beats_left;
    if (draining) begin
      force dut.pool_q[0].state = dut.MSHR_DRAIN_RESP;
    end else begin
      force dut.pool_q[0].state = dut.MSHR_WAIT_RESP;
    end
    release dut.pool_q[0].state;
    force dut.pool_q[0].issued = 1'b1;
    release dut.pool_q[0].issued;
    force dut.pool_q[0].cacheable = 1'b1;
    release dut.pool_q[0].cacheable;
    force dut.pool_q[0].sub_reqs_num = 1;
    release dut.pool_q[0].sub_reqs_num;
    force dut.pool_q[0].served_cnt = 1;
    release dut.pool_q[0].served_cnt;
    force dut.pool_q[0].sub_reqs[0].valid = 1'b1;
    release dut.pool_q[0].sub_reqs[0].valid;
    force dut.pool_q[0].sub_reqs[0].tile_id = tile_group_id_t'(1);
    release dut.pool_q[0].sub_reqs[0].tile_id;
    force dut.pool_q[0].sub_reqs[0].port_id = 1;
    release dut.pool_q[0].sub_reqs[0].port_id;
    force dut.pool_q[0].sub_reqs[0].core_id = tile_core_id_t'(1);
    release dut.pool_q[0].sub_reqs[0].core_id;
    force dut.pool_q[0].sub_reqs[0].meta_id_base = meta_id_t'(3);
    release dut.pool_q[0].sub_reqs[0].meta_id_base;
    if (draining) begin
      force dut.pool_q[0].resp_buf_cnt = 1;
      release dut.pool_q[0].resp_buf_cnt;
      force dut.pool_q[0].resp_buf_wr_ptr = 1;
      release dut.pool_q[0].resp_buf_wr_ptr;
      force dut.pool_q[0].resp_buf[0].data = 32'hcafe1234;
      release dut.pool_q[0].resp_buf[0].data;
      force dut.pool_q[0].beat_pending = 1;
      release dut.pool_q[0].beat_pending;
      force dut.pool_q[0].beat_seen = 1;
      release dut.pool_q[0].beat_seen;
    end
  endtask

  task automatic offer_beat(input int port_id, input int offset);
    noc_resp_valid[1][port_id] = 1'b1;
    noc_resp[1][port_id].mshr_tag = MshrTagWidth'(MN + 1);
    noc_resp[1][port_id].rdata.core_id = tile_core_id_t'(1 + offset % NumMemPortsPerSpatz);
    noc_resp[1][port_id].rdata.meta_id = meta_id_t'(3 + offset / NumMemPortsPerSpatz);
    noc_resp[1][port_id].rdata.data = 32'hcafe0000 + offset;
  endtask

  task automatic capture_lane;
    reset_dut();
    seed_pool(8, 0);
    offer_beat(2, 5);
    #1;
    check(dut.psn_v[1][2] === 1'b1, "pool response classified");
    check(dut.pool_cap_want[0] === 8'b00001000, "capture uses current lane 3");
    check(noc_resp_ready[1][2] === 1'b1, "response lane accepted");
    check(dut.pool_d[0].resp_buf_cnt === 1, "one captured response");
    check(dut.pool_d[0].resp_buf[0].beat_off === 5, "beat ordinal retained");
    check(dut.pool_d[0].resp_buf[0].data === 32'hcafe0005, "payload captured");
  endtask

  task automatic capture_burst;
    int received;
    int offset;
    bit [7:0] seen;
    reset_dut();
    seed_pool(8, 0);
    offer_beat(1, 0);
    offer_beat(2, 5);
    #1;
    check(noc_resp_ready[1] === 2'b11, "both pool capture lanes accepted");
    @(posedge clk);
    @(negedge clk);
    noc_resp_valid = '0;
    resp_ready = '1;
    received = 0;
    seen = '0;
    repeat (12) begin
      #1;
      for (int p = 1; p < NR; p++) begin
        if (resp_valid[1][p]) begin
          offset = (int'(resp[1][p].rdata.meta_id) - 3) * NumMemPortsPerSpatz +
                   int'(resp[1][p].rdata.core_id) - 1;
          check((offset == 0 || offset == 5), "drained ordinal is 0 or 5");
          if (offset >= 0 && offset < 8) begin
            check(!seen[offset], "each ordinal delivered once");
            seen[offset] = 1;
            check(resp[1][p].rdata.data === (32'hcafe0000 + offset), "data matches ordinal");
          end
          received++;
        end
      end
      @(negedge clk);
    end
    check(received == 2 && seen == 8'b00100001, "both captured beats delivered exactly once");
  endtask

  task automatic cross_clear;
    reset_dut();
    seed_pool(1, 1);
    force dut.mshr_q[0] = dut.pool_q[0];
    release dut.mshr_q[0];
    force dut.mshr_q_valid[0] = 1'b1;
    release dut.mshr_q_valid[0];
    force dut.mshr_q[0].base_addr = '0;
    release dut.mshr_q[0].base_addr;
    force dut.mshr_q[0].sub_reqs[0].tile_id = tile_group_id_t'(2);
    release dut.mshr_q[0].sub_reqs[0].tile_id;
    resp_ready[1][1] = 1'b1;
    #1;
    check(dut.drain_published[0] === 1'b1, "unrelated bank zero entry published");
    check(dut.resp_sel_pool_valid[1][1] === 1'b1, "pool selected for tile one");
    check(dut.pool_bp_clr[0][0] === 1'b1, "pool handshake clears its pending bit");
    check(dut.bp_clr[0][0] === 1'b0, "pool handshake preserves bank zero pending bit");
    check(dut.sv_clr[0][0] === 1'b0, "pool handshake preserves bank zero subscriber");
    check(dut.mshr_d[0].sub_reqs[0].valid === 1'b1, "bank zero subscriber survives");
  endtask

  task automatic clear_generations;
    reset_dut();
    seed_pool(1, 1);
    resp_ready[1][1] = 1'b1;
    #1;
    check(dut.pool_bp_clr[0][0] === 1'b1, "first generation has a clear");
    @(posedge clk);
    @(negedge clk);
    resp_ready = '0;
    seed_pool(1, 1);
    force dut.pool_q[0].sub_reqs[0].meta_id_base = meta_id_t'(7);
    release dut.pool_q[0].sub_reqs[0].meta_id_base;
    #1;
    check(dut.pool_bp_clr === '0, "pending clears default off in next generation");
    check(dut.pool_sv_clr === '0, "subscriber clears default off in next generation");
    check(dut.pool_d[0].beat_pending[0] === 1'b1, "blocked new subscriber remains pending");
    check(dut.pool_d[0].sub_reqs[0].valid === 1'b1, "blocked new subscriber remains live");
  endtask

  task automatic cache_expiry_merge;
    reset_dut();
    seed_pool(1, 1);
    force dut.pool_q[0].state = dut.MSHR_CACHED;
    release dut.pool_q[0].state;
    force dut.pool_q[0].sub_reqs_num = 0;
    release dut.pool_q[0].sub_reqs_num;
    force dut.pool_q[0].sub_reqs[0].valid = 0;
    release dut.pool_q[0].sub_reqs[0].valid;
    force dut.pool_q[0].beat_pending = 0;
    release dut.pool_q[0].beat_pending;
    force dut.pool_q[0].beats_left = 0;
    release dut.pool_q[0].beats_left;
    force dut.pool_q[0].hold_cnt = 1;
    release dut.pool_q[0].hold_cnt;
    req_valid[1][1] = 1'b1;
    req[1][1].tgt_addr = tcdm_addr_t'('h120);
    req[1][1].tgt_group_id = group_id_t'(1);
    req[1][1].burst_len = 1;
    req[1][1].be = '1;
    req[1][1].wdata.core_id = tile_core_id_t'(1);
    req[1][1].wdata.meta_id = meta_id_t'(7);
    #1;
    check(req_ready[1][1] === 1'b1 && dut.mpb_v === 1'b1, "cached merge accepted before expiry");
    @(posedge clk);
    @(negedge clk);
    req_valid = '0;
    #1;
    check(dut.mpb_q_v === 1'b1 && dut.pool_q[0].hold_cnt === 0, "merge applies at zero countdown");
    check(dut.pool_d_valid[0] === 1'b1, "cache timeout preserves accepted merge");
    check(dut.pool_d[0].state == dut.MSHR_DRAIN_RESP && dut.pool_d[0].sub_reqs_num == 1,
          "cached merge is ready to drain");
  endtask

  task automatic seed_cached;
    seed_pool(1, 1);
    force dut.pool_q[0].state = dut.MSHR_CACHED;
    release dut.pool_q[0].state;
    force dut.pool_q[0].sub_reqs_num = 0;
    release dut.pool_q[0].sub_reqs_num;
    force dut.pool_q[0].sub_reqs[0].valid = 0;
    release dut.pool_q[0].sub_reqs[0].valid;
    force dut.pool_q[0].beat_pending = 0;
    release dut.pool_q[0].beat_pending;
    force dut.pool_q[0].beats_left = 0;
    release dut.pool_q[0].beats_left;
    force dut.pool_q[0].hold_cnt = 8;
    release dut.pool_q[0].hold_cnt;
  endtask

  task automatic offer_store(input int tile_id, input data_t data, input logic [3:0] be);
    req_valid[tile_id][1] = 1'b1;
    req[tile_id][1].wen = 1'b1;
    req[tile_id][1].tgt_addr = tcdm_addr_t'('h120);
    req[tile_id][1].tgt_group_id = group_id_t'(1);
    req[tile_id][1].burst_len = 1;
    req[tile_id][1].be = be;
    req[tile_id][1].wdata.data = data;
    req[tile_id][1].wdata.core_id = tile_core_id_t'(1);
  endtask

  task automatic store_cache_update;
    reset_dut();
    seed_cached();
    offer_store(1, 32'h11223344, 4'b0011);
    offer_store(2, 32'haabbccdd, 4'b0110);
    #1;
    check(req_ready[1][1] && req_ready[2][1], "both overlapping stores accepted");
    check(dut.pool_d[0].resp_buf[0].data === 32'hcabbcc44,
          "highest lane wins overlap and disabled bytes retain cached data");
    check(dut.pool_rb_we[0][0] === 1'b1, "store enables only the cached response slot");
    @(posedge clk);
    @(negedge clk);
    req_valid = '0;
    #1;
    check(dut.pool_q[0].resp_buf[0].data === 32'hcabbcc44, "updated cache data registered");
  endtask

  task automatic store_cache_blocked;
    reset_dut();
    seed_cached();
    offer_store(1, 32'h11223344, 4'b1111);
    noc_req_ready[1][1] = 0;
    #1;
    check(req_ready[1][1] === 1'b0, "store backpressure reaches requester");
    check(dut.pool_d[0].resp_buf[0].data === 32'hcafe1234, "unaccepted store preserves data");
    check(dut.pool_rb_we[0] === '0, "unaccepted store never enables cache write");
  endtask

  task automatic store_amo_guard;
    reset_dut();
    seed_cached();
    offer_store(1, 32'h11223344, 4'b1111);
    req_valid[3][1] = 1'b1;
    req[3][1].tgt_addr = tcdm_addr_t'('h280);
    req[3][1].tgt_group_id = group_id_t'(1);
    req[3][1].burst_len = 1;
    req[3][1].wdata.amo = 1;
    #1;
    check(dut.amo_invalidate === 1'b1, "AMO invalidation guard exercised");
    check(dut.pool_d[0].resp_buf[0].data === 32'hcafe1234,
          "AMO guard suppresses same-cycle cache byte update");
    check(dut.pool_rb_we[0] === '0, "AMO guard suppresses cache write enable");
  endtask

  task automatic store_force_drain(input bit blocked);
    reset_dut();
    seed_pool(1, 1);
    force dut.pool_q[0].state = dut.MSHR_RESP_HOLD;
    release dut.pool_q[0].state;
    force dut.pool_q[0].beat_pending = 0;
    release dut.pool_q[0].beat_pending;
    force dut.pool_q[0].hold_cnt = 8;
    release dut.pool_q[0].hold_cnt;
    offer_store(2, 32'h11223344, 4'b1111);
    if (blocked) noc_req_ready[2][1] = 0;
    #1;
    if (blocked) begin
      check(req_ready[2][1] === 1'b0, "held-line store is backpressured");
      check(dut.pool_d[0].state == dut.MSHR_RESP_HOLD && dut.pool_d[0].cacheable,
            "unaccepted store preserves response hold");
    end else begin
      check(req_ready[2][1] === 1'b1, "held-line store is accepted");
      check(dut.pool_d[0].state == dut.MSHR_DRAIN_RESP && !dut.pool_d[0].cacheable,
            "accepted store flushes held pool entry and prevents recaching");
      check(dut.pool_d[0].beat_pending[0] === 1'b1, "flushed response retains its subscriber");
    end
  endtask

  task automatic store_cache_merge;
    reset_dut();
    seed_cached();
    offer_store(2, 32'hdeadc0de, 4'b1111);
    req_valid[0][1] = 1'b1;
    req[0][1].tgt_addr = tcdm_addr_t'('h120);
    req[0][1].tgt_group_id = group_id_t'(1);
    req[0][1].burst_len = 1;
    req[0][1].be = '1;
    req[0][1].wdata.core_id = tile_core_id_t'(1);
    req[0][1].wdata.meta_id = meta_id_t'(7);
    #1;
    check(req_ready[0][1] && req_ready[2][1] && dut.mpb_v,
          "cached load merge and store accepted together");
    @(posedge clk);
    @(negedge clk);
    req_valid = '0;
    #1;
    check(dut.pool_d_valid[0] && dut.pool_d[0].state == dut.MSHR_DRAIN_RESP,
          "same-cycle store did not drop cached subscriber");
    @(posedge clk);
    @(negedge clk);
    resp_ready[0][1] = 1'b1;
    #1;
    check(resp_valid[0][1] && resp[0][1].rdata.data === 32'hdeadc0de,
          "cached subscriber sees registered byte update");
  endtask

  task automatic store_capture_force;
    reset_dut();
    seed_pool(1, 0);
    offer_beat(1, 0);
    offer_store(2, 32'hdeadc0de, 4'b1111);
    #1;
    check(noc_resp_ready[1][1] && req_ready[2][1], "scalar capture and store accepted together");
    check(dut.pool_d[0].state == dut.MSHR_DRAIN_RESP && !dut.pool_d[0].cacheable,
          "store flush sees a response captured this cycle");
    check(dut.pool_d[0].resp_buf[0].data === 32'hcafe0000 &&
          dut.pool_d[0].beat_pending[0], "captured pre-store response remains pending for owner");
  endtask

  task automatic offer_amo;
    req_valid[2][1] = 1'b1;
    req[2][1].tgt_addr = tcdm_addr_t'('h120);
    req[2][1].tgt_group_id = group_id_t'(1);
    req[2][1].burst_len = 1;
    req[2][1].wdata.amo = 1;
  endtask

  task automatic amo_pool(input bit held);
    reset_dut();
    seed_cached();
    if (held) begin
      force dut.pool_q[0].state = dut.MSHR_RESP_HOLD;
      release dut.pool_q[0].state;
      force dut.pool_q[0].sub_reqs_num = 1;
      release dut.pool_q[0].sub_reqs_num;
      force dut.pool_q[0].sub_reqs[0].valid = 1;
      release dut.pool_q[0].sub_reqs[0].valid;
      force dut.pool_q[0].beats_left = 1;
      release dut.pool_q[0].beats_left;
    end
    offer_amo();
    #1;
    check(req_ready[2][1] && dut.amo_invalidate, "pool-address AMO accepted");
    if (held) begin
      check(dut.pool_d[0].state == dut.MSHR_DRAIN_RESP && !dut.pool_d[0].cacheable,
            "AMO releases held pool response without recaching");
      check(dut.pool_d_valid[0] && dut.pool_d[0].beat_pending[0],
            "AMO release retains original subscriber");
    end else begin
      check(dut.pool_d_valid[0] === 1'b0, "AMO invalidates cached pool data");
    end
  endtask

  task automatic amo_cache_merge;
    reset_dut();
    seed_cached();
    req_valid[0][1] = 1'b1;
    req[0][1].tgt_addr = tcdm_addr_t'('h120);
    req[0][1].tgt_group_id = group_id_t'(1);
    req[0][1].burst_len = 1;
    req[0][1].be = '1;
    req[0][1].wdata.core_id = tile_core_id_t'(1);
    req[0][1].wdata.meta_id = meta_id_t'(7);
    #1;
    check(req_ready[0][1] && dut.mpb_v, "cached load accepted before AMO");
    @(posedge clk);
    @(negedge clk);
    req_valid = '0;
    offer_amo();
    #1;
    check(dut.pool_merge_inflight[0] && req_ready[2][1] && dut.amo_invalidate,
          "AMO accepted while cached merge applies");
    check(dut.pool_d_valid[0] && dut.pool_d[0].state == dut.MSHR_DRAIN_RESP &&
          dut.pool_d[0].sub_reqs_num == 1 && dut.pool_d[0].beat_pending[0],
          "AMO preserves the already accepted cached subscriber");
    check(!dut.pool_d[0].cacheable, "AMO prevents the merged cached word from recaching");
    @(posedge clk);
    @(negedge clk);
    req_valid = '0;
    resp_ready[0][1] = 1'b1;
    #1;
    check(!dut.amo_invalidate, "AMO pulse ends before the cached subscriber drains");
    check(resp_valid[0][1] && resp[0][1].rdata.data === 32'hcafe1234 &&
          resp[0][1].rdata.meta_id === meta_id_t'(7),
          "accepted subscriber receives its one preserved response");
    @(posedge clk);
    @(negedge clk);
    #1;
    check(!dut.pool_q_valid[0], "entry retires after the AMO instead of caching stale data");
    check(resp_valid === '0, "AMO merge response is delivered exactly once");
  endtask

  task automatic coherence_hold_merge(input bit use_amo);
    int received;
    reset_dut();
    cfg.hold_subs_single = 2;
    seed_pool(1, 1);
    force dut.pool_q[0].state = dut.MSHR_RESP_HOLD;
    release dut.pool_q[0].state;
    force dut.pool_q[0].beat_pending = 0;
    release dut.pool_q[0].beat_pending;
    force dut.pool_q[0].hold_cnt = 8;
    release dut.pool_q[0].hold_cnt;
    req_valid[0][1] = 1'b1;
    req[0][1].tgt_addr = tcdm_addr_t'('h120);
    req[0][1].tgt_group_id = group_id_t'(1);
    req[0][1].burst_len = 1;
    req[0][1].be = '1;
    req[0][1].wdata.core_id = tile_core_id_t'(1);
    req[0][1].wdata.meta_id = meta_id_t'(7);
    #1;
    check(req_ready[0][1] && dut.mpb_v, "held response accepts threshold-reaching merge");
    @(posedge clk);
    @(negedge clk);
    req_valid = '0;
    if (use_amo) offer_amo();
    else offer_store(2, 32'hdeadc0de, 4'b1111);
    #1;
    check(dut.pool_merge_inflight[0] && req_ready[2][1],
          "coherence request accepted while held merge reaches threshold");
    check(dut.pool_st_post_cap[0] == dut.MSHR_DRAIN_RESP,
          "threshold merge releases held state before coherence pass");
    check(dut.pool_d_valid[0] && dut.pool_d[0].sub_reqs_num == 2 &&
          dut.pool_d[0].beat_pending[1:0] == 2'b11,
          "coherence request preserves both previously accepted subscribers");
    check(!dut.pool_d[0].cacheable, "coherence event prevents threshold merge from recaching");
    @(posedge clk);
    @(negedge clk);
    req_valid = '0;
    resp_ready = '1;
    received = 0;
    repeat (3) begin
      #1;
      for (int t = 0; t < NT; t++) begin
        for (int p = 1; p < NR; p++) begin
          if (resp_valid[t][p]) begin
            check((t == 0 || t == 1) && p == 1 &&
                  resp[t][p].rdata.data === 32'hcafe1234,
                  "pre-coherence subscribers receive preserved response data");
            received++;
          end
        end
      end
      @(negedge clk);
    end
    check(received == 2, "both accepted subscribers drain exactly once");
    check(!dut.pool_q_valid[0], "threshold merge retires after the coherence event");
  endtask

  task automatic coherence_drain(input bit use_amo, input bit capturing, input bit banked);
    reset_dut();
    seed_pool(1, !capturing);
    if (banked) begin
      // BankHash=0 folds address 0x120 and group 1 to bank 2, way 0.
      force dut.mshr_q[4] = dut.pool_q[0];
      release dut.mshr_q[4];
      force dut.mshr_q_valid[4] = 1'b1;
      release dut.mshr_q_valid[4];
      force dut.pool_q_valid[0] = 1'b0;
      release dut.pool_q_valid[0];
    end
    if (capturing) begin
      offer_beat(1, 0);
      if (banked) noc_resp[1][1].mshr_tag = MshrTagWidth'(5);
    end
    if (use_amo) offer_amo();
    else offer_store(2, 32'hdeadc0de, 4'b1111);
    #1;
    check(req_ready[2][1], "coherence request accepted while response output is blocked");
    if (capturing) check(noc_resp_ready[1][1], "response captured during coherence event");
    if (banked) begin
      check(dut.req_bank[2][1] == 2, "banked seed matches the store address hash");
      check(dut.mshr_d_valid[4] && dut.mshr_d[4].state == dut.MSHR_DRAIN_RESP &&
            dut.mshr_d[4].resp_buf_cnt == 1 && dut.mshr_d[4].beat_pending[0],
            "banked coherence event retains blocked response and its subscriber");
      check(!dut.mshr_d[4].cacheable, "banked blocked response cannot recache after coherence");
    end else begin
      check(dut.pool_d_valid[0] && dut.pool_d[0].state == dut.MSHR_DRAIN_RESP &&
            dut.pool_d[0].resp_buf_cnt == 1 && dut.pool_d[0].beat_pending[0],
            "pool coherence event retains blocked response and its subscriber");
      check(!dut.pool_d[0].cacheable, "pool blocked response cannot recache after coherence");
    end
    @(posedge clk);
    @(negedge clk);
    req_valid = '0;
    noc_resp_valid = '0;
    resp_ready[1][1] = 1'b1;
    #1;
    check(resp_valid[1][1] && resp[1][1].rdata.meta_id === meta_id_t'(3) &&
          resp[1][1].rdata.data === (capturing ? 32'hcafe0000 : 32'hcafe1234),
          "blocked subscriber drains its preserved response after coherence pulse");
    @(posedge clk);
    @(negedge clk);
    #1;
    if (banked) check(!dut.mshr_q_valid[4], "banked entry retires instead of recaching old data");
    else check(!dut.pool_q_valid[0], "pool entry retires instead of recaching old data");
    check(resp_valid === '0, "blocked coherence response is delivered exactly once");
  endtask

  task automatic coherence_guard(input int kind);
    reset_dut();
    seed_cached();
    if (kind == 1) begin
      force dut.pool_q[0].state = dut.MSHR_RESP_HOLD;
      release dut.pool_q[0].state;
      force dut.pool_q[0].sub_reqs_num = 1;
      release dut.pool_q[0].sub_reqs_num;
      force dut.pool_q[0].sub_reqs[0].valid = 1;
      release dut.pool_q[0].sub_reqs[0].valid;
      force dut.pool_q[0].beats_left = 1;
      release dut.pool_q[0].beats_left;
    end
    if (kind == 2) offer_amo();
    else offer_store(2, 32'hdeadc0de, 4'b1111);
    @(posedge clk);
    #1;
    $fatal(1, "expected disabled-coherence assertion did not fire");
  endtask

`ifdef TB_CHECK_STATS
  task automatic stats_merge;
    reset_dut();
    seed_cached();
    req_valid[0][1] = 1'b1;
    req[0][1].tgt_addr = tcdm_addr_t'('h120);
    req[0][1].tgt_group_id = group_id_t'(1);
    req[0][1].burst_len = 1;
    req[0][1].be = '1;
    req[0][1].wdata.core_id = tile_core_id_t'(1);
    req[0][1].wdata.meta_id = meta_id_t'(7);
    #1;
    check(req_ready[0][1] && dut.mpb_v, "stats case accepts one pool cache merge");
    check(dut.stat_req_merge_cycle === 1 && dut.stat_req_accept_cycle === 1,
          "accepted pool merge counted as merge");
    check(dut.stat_req_bypass_cycle === 0 && dut.stat_req_mshr_overflow_cycle === 0,
          "accepted pool merge is neither bypass nor overflow");
    check(dut.stat_cache_hit_cycle === 1, "pool cached merge counted as cache hit");
    for (int b = 0; b < 4; b++) begin
      check(dut.gen_stats.rc_bank_ovf_inc[b] === 0, "pool merge never increments bank overflow");
    end
  endtask
`endif

  initial begin
    errors = 0;
    rst_n = 0;
    cfg = '0;
    cfg.enable = 1;
    cfg.hold_subs_single = 4;
    cfg.hold_subs_burst = 4;
    cfg.cache_reuse_target = 4;
    cfg.serve_timeout = 8;
    cfg.hold_window_single = 8;
    cfg.hold_window_burst = 8;
    cfg.bankfull_backpressure = 1;
    cfg.bank_shift_single = 4;
    cfg.bank_shift_burst = 4;
    if (!$value$plusargs("CASE=%s", test_case)) test_case = "capture_lane";
    $dumpfile("waves.vcd");
    $dumpvars(0, pool_response_tb);
    case (test_case)
      "capture_lane": capture_lane();
      "capture_burst": capture_burst();
      "cross_clear": cross_clear();
      "clear_generations": clear_generations();
      "cache_expiry_merge": cache_expiry_merge();
      "store_cache_update": store_cache_update();
      "store_cache_blocked": store_cache_blocked();
      "store_amo_guard": store_amo_guard();
      "store_force_drain": store_force_drain(0);
      "store_force_blocked": store_force_drain(1);
      "store_cache_merge": store_cache_merge();
      "store_capture_force": store_capture_force();
      "amo_pool_cached": amo_pool(0);
      "amo_pool_held": amo_pool(1);
      "amo_cache_merge": amo_cache_merge();
      "amo_hold_merge": coherence_hold_merge(1);
      "store_hold_merge": coherence_hold_merge(0);
      "amo_drain": coherence_drain(1, 0, 0);
      "store_drain": coherence_drain(0, 0, 0);
      "amo_capture": coherence_drain(1, 1, 0);
      "bank_amo_drain": coherence_drain(1, 0, 1);
      "bank_store_drain": coherence_drain(0, 0, 1);
      "bank_amo_capture": coherence_drain(1, 1, 1);
      "guard_cached_store": coherence_guard(0);
      "guard_held_store": coherence_guard(1);
      "guard_cached_amo": coherence_guard(2);
`ifdef TB_CHECK_STATS
      "stats_merge": stats_merge();
`endif
      default: $fatal(1, "unknown response case %s", test_case);
    endcase
    if (errors) $fatal(1, "%0d response lifecycle checks failed", errors);
    $display("PASS overflow_pool %s", test_case);
    $finish;
  end
endmodule
