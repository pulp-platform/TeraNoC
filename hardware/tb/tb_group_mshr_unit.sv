// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/// Standalone feature bench for mempool_group_mshr.
///
/// A full-cluster GEMM run takes 40+ minutes and measures the MSHR only through the FPU
/// utilisation it happens to produce, so a throughput or latency change shows up as a few percent
/// of total cycles with no attribution. This drives the module directly and measures the four
/// things we actually tune: sustained throughput, miss latency, cohort assembly, and outstanding
/// capacity -- plus the bank hash, which nothing else observes.
///
/// It also carries DIRECTED cases a GEMM workload may never generate, which is where the silent
/// bugs live: a cohort whose followers arrive the cycle after their leader allocates (the
/// pipeline-cut forwarding path), and two responses landing on one entry in one cycle.
///
///   make -C hardware mshr_unit                 # run every test
///   make -C hardware mshr_unit MSHR_UNIT_TEST=cohort
///
/// Exit status is non-zero if any check fails; every test prints PASS/FAIL and its measurement.

module tb_group_mshr_unit;

  import mempool_pkg::*;

  localparam int unsigned NumTiles   = NumTilesPerGroup;
  localparam int unsigned ReqPorts   = NumRemoteReqPortsPerTile;
  localparam int unsigned RespPorts  = NumRemoteRespPortsPerTile;
  localparam int unsigned NumLanes   = NumTiles * (ReqPorts - 1);
  // Same `ifdef chain the DUT uses -- these are module parameters, not package ones, so the bench
  // reads the defines rather than keeping a second copy that could drift.
  localparam int unsigned MshrNum        = `ifdef GROUP_MSHR_NUM `GROUP_MSHR_NUM `else NumTilesPerGroup `endif;
  localparam int unsigned MshrWaysPerBank = `ifdef GROUP_MSHR_WAYS_PER_BANK `GROUP_MSHR_WAYS_PER_BANK `else 4 `endif;
  localparam int unsigned MshrMergeReqs  = `ifdef GROUP_MSHR_MERGE_REQS `GROUP_MSHR_MERGE_REQS `else 8 `endif;
  localparam int unsigned BankNum    = MshrNum / MshrWaysPerBank;
  localparam time         Tclk       = 2ns;
  /// Round-trip the responder adds, in cycles. Miss latency is measured against it, so the MSHR's
  /// own contribution is the difference -- which is what a pipeline stage changes.
  localparam int unsigned NocLatency = 20;

  logic clk, rst_n;
  int   errors, cycle;

  // --------------------------------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------------------------------
  tcdm_master_req_t  [NumTiles-1:0][ReqPorts-1:1]  req;
  logic              [NumTiles-1:0][ReqPorts-1:1]  req_valid, req_ready;
  tcdm_master_req_t  [NumTiles-1:0][ReqPorts-1:1]  noc_req;
  logic              [NumTiles-1:0][ReqPorts-1:1]  noc_req_valid, noc_req_ready;
  tcdm_master_resp_t [NumTiles-1:0][RespPorts-1:1] noc_resp;
  logic              [NumTiles-1:0][RespPorts-1:1] noc_resp_valid, noc_resp_ready;
  tcdm_master_resp_t [NumTiles-1:0][RespPorts-1:1] resp;
  logic              [NumTiles-1:0][RespPorts-1:1] resp_valid, resp_ready;
  mshr_cfg_t                                       cfg;
  logic                                            busy;

  mempool_group_mshr #(
    .NumGroups                (NumGroups),
    .NumTilesPerGroup         (NumTilesPerGroup),
    .NumRemoteReqPortsPerTile (NumRemoteReqPortsPerTile),
    .NumRemoteRespPortsPerTile(NumRemoteRespPortsPerTile)
  ) i_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .testmode_i(1'b0), .scan_enable_i(1'b0), .scan_data_i(1'b0), .scan_data_o(),
    .group_id_i(group_id_t'(0)),
    .group_mshr_req_i(req), .group_mshr_req_valid_i(req_valid), .group_mshr_req_ready_o(req_ready),
    .mshr_noc_req_o(noc_req), .mshr_noc_req_valid_o(noc_req_valid),
    .mshr_noc_req_ready_i(noc_req_ready),
    .mshr_noc_resp_i(noc_resp), .mshr_noc_resp_valid_i(noc_resp_valid),
    .mshr_noc_resp_ready_o(noc_resp_ready),
    .group_mshr_resp_o(resp), .group_mshr_resp_valid_o(resp_valid),
    .group_mshr_resp_ready_i(resp_ready),
    .cfg_i(cfg), .mshr_busy_o(busy)
  );

  // --------------------------------------------------------------------------------------------
  // NoC responder: accepts every request and returns it NocLatency cycles later on the response
  // port matching the requesting tile, echoing mshr_tag / core_id / meta_id so the MSHR can route
  // it. A burst returns burst_len beats with the beat encoded the way burst_beat_of expects.
  // --------------------------------------------------------------------------------------------
  typedef struct {
    int                due;
    int                tile;
    logic [MshrTagWidth-1:0] tag;
    tile_core_id_t     core;
    meta_id_t          meta;
    tcdm_addr_t        addr;
    int                beat;
  } pend_t;
  pend_t pend_q[$];

  assign noc_req_ready = '1;   // never backpressure the egress side

  int noc_reqs_seen, resp_sent;

  always_ff @(posedge clk or negedge rst_n) begin
    automatic pend_t p;
    if (!rst_n) begin
      pend_q.delete(); noc_reqs_seen <= 0; resp_sent <= 0;
      noc_resp <= '0; noc_resp_valid <= '0;
    end else begin
      noc_resp_valid <= '0;
      for (int t = 0; t < NumTiles; t++)
        for (int pp = 1; pp < ReqPorts; pp++)
          if (noc_req_valid[t][pp]) begin
            noc_reqs_seen <= noc_reqs_seen + 1;
            for (int b = 0; b < int'(noc_req[t][pp].burst_len); b++) begin
              p.due  = cycle + NocLatency + b;
              p.tile = t;
              p.tag  = noc_req[t][pp].mshr_tag;
              p.core = noc_req[t][pp].wdata.core_id;
              p.meta = meta_id_t'(noc_req[t][pp].wdata.meta_id + b);
              p.addr = noc_req[t][pp].tgt_addr;
              p.beat = b;
              pend_q.push_back(p);
            end
          end
      // Drive at most one beat per (tile, port) per cycle.
      for (int i = pend_q.size()-1; i >= 0; i--)
        if (pend_q[i].due <= cycle) begin
          automatic int t  = pend_q[i].tile;
          automatic int pp = 1;
          if (!noc_resp_valid[t][pp]) begin
            noc_resp[t][pp].rdata.core_id <= pend_q[i].core;
            noc_resp[t][pp].rdata.meta_id <= pend_q[i].meta;
            noc_resp[t][pp].rdata.amo     <= '0;
            noc_resp[t][pp].rdata.data    <= 32'hC0DE_0000 + pend_q[i].beat;
            noc_resp[t][pp].wen           <= 1'b0;
            noc_resp[t][pp].mshr_tag      <= pend_q[i].tag;
            noc_resp_valid[t][pp]         <= 1'b1;
            resp_sent                     <= resp_sent + 1;
            pend_q.delete(i);
          end
        end
    end
  end

  assign resp_ready = '1;      // the consumer never backpressures

  // --------------------------------------------------------------------------------------------
  // Clock, reset, cycle counter
  // --------------------------------------------------------------------------------------------
  initial begin clk = 0; forever #(Tclk/2) clk = ~clk; end
  always_ff @(posedge clk or negedge rst_n) if (!rst_n) cycle <= 0; else cycle <= cycle + 1;

  // --------------------------------------------------------------------------------------------
  // Stimulus helpers
  // --------------------------------------------------------------------------------------------
  task automatic drive_idle();
    req = '0; req_valid = '0;
  endtask

  /// Present one request on a lane and hold it until accepted. Returns the cycle it was accepted.
  task automatic send(input int t, input int pp, input tcdm_addr_t addr, input tile_core_id_t core,
                      input meta_id_t meta, input int len, output int accepted_at);
    req[t][pp].tgt_addr      = addr;
    req[t][pp].tgt_group_id  = group_id_t'(1);   // remote: group 1, so it goes through the MSHR
    req[t][pp].wen           = 1'b0;
    req[t][pp].be            = '1;
    req[t][pp].burst_len     = BurstLenWidth'(len);
    req[t][pp].wdata.core_id = core;
    req[t][pp].wdata.meta_id = meta;
    req[t][pp].wdata.amo     = '0;
    req[t][pp].wdata.data    = '0;
    req_valid[t][pp]         = 1'b1;
    do @(posedge clk); while (!req_ready[t][pp]);
    accepted_at = cycle;
    req_valid[t][pp] = 1'b0;
  endtask

  task automatic reset_dut();
    rst_n = 0; drive_idle(); repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
  endtask

  task automatic check(input string name, input bit ok, input string detail);
    if (!ok) errors++;
    $display("[MSHR-UNIT] %-4s %-22s %s", ok ? "PASS" : "FAIL", name, detail);
  endtask

  // --------------------------------------------------------------------------------------------
  // T1 THROUGHPUT -- every lane offers a distinct line every cycle. Measures sustained accepts
  // per cycle. A pipeline stage must not reduce this; a per-bank stall shows up here directly.
  // --------------------------------------------------------------------------------------------
  task automatic t_throughput();
    automatic int accepts = 0, cyc0, n = 400;
    cfg.hold_subs_single = MshrCfgSubsW'(1);   // no merging wanted: release as soon as served
    cfg.serve_timeout    = MshrCfgHoldCntW'(8);
    reset_dut();
    cyc0 = cycle;
    fork
      begin : drv
        for (int i = 0; i < n; i++) begin
          for (int t = 0; t < NumTiles; t++)
            for (int pp = 1; pp < ReqPorts; pp++) begin
              req[t][pp].tgt_addr      = tcdm_addr_t'((i * NumLanes + t * (ReqPorts-1) + pp) << 2);
              req[t][pp].tgt_group_id  = group_id_t'(1);
              req[t][pp].wen           = 1'b0;
              req[t][pp].be            = '1;
              req[t][pp].burst_len     = BurstLenWidth'(1);
              req[t][pp].wdata.core_id = tile_core_id_t'(0);
              req[t][pp].wdata.meta_id = meta_id_t'(i);
              req[t][pp].wdata.amo     = '0;
              req_valid[t][pp]         = 1'b1;
            end
          @(posedge clk);
          for (int t = 0; t < NumTiles; t++)
            for (int pp = 1; pp < ReqPorts; pp++) if (req_ready[t][pp]) accepts++;
        end
        drive_idle();
      end
    join
    cfg.hold_subs_single = MshrCfgSubsW'(4);
    cfg.serve_timeout    = MshrCfgHoldCntW'(2047);
    check("T1_throughput", accepts > 0,
          $sformatf("%0d accepts in %0d cycles = %.2f/cycle (lanes=%0d banks=%0d)",
                    accepts, cycle-cyc0, real'(accepts)/real'(cycle-cyc0), NumLanes, BankNum));
  endtask

  // --------------------------------------------------------------------------------------------
  // T2 COHORT ASSEMBLY -- N lanes want the SAME line, offered on consecutive cycles. This is the
  // MSHR's whole purpose and the case a pipeline cut damages: the follower arrives while the
  // leader's entry is recorded but not yet visible. Measures cycles from first to last accept and
  // the number of NoC requests emitted (must be 1 -- all followers merged).
  // --------------------------------------------------------------------------------------------
  task automatic t_cohort();
    automatic int noc0, done_at = -1, accepted = 0, cyc0;
    automatic int deg = (NumTiles < 16) ? NumTiles : 16;
    // hold_subs_single MUST be > 1 here: 1 means "singles bypass, no merging wanted", which
    // disables the very behaviour this test measures.
    cfg.hold_subs_single = MshrCfgSubsW'(4);
    cfg.serve_timeout    = MshrCfgHoldCntW'(64);
    reset_dut();
    noc0 = noc_reqs_seen;
    cyc0 = cycle;
    // ALL lanes assert the SAME line in the SAME cycle -- the real coalescing pattern, and the
    // one a pipeline cut damages: only one can allocate, the rest must merge into it. Driving
    // them sequentially (waiting for each ready) measures nothing but serial acceptance.
    for (int t = 0; t < deg; t++) begin
      req[t][1].tgt_addr      = tcdm_addr_t'(32'h0000_1000);
      req[t][1].tgt_group_id  = group_id_t'(1);
      req[t][1].wen           = 1'b0;
      req[t][1].be            = '1;
      req[t][1].burst_len     = BurstLenWidth'(1);
      req[t][1].wdata.core_id = tile_core_id_t'(0);
      req[t][1].wdata.meta_id = meta_id_t'(t);
      req[t][1].wdata.amo     = '0;
      req_valid[t][1]         = 1'b1;
    end
    while (accepted < deg && (cycle - cyc0) < 200) begin
      @(posedge clk);
      for (int t = 0; t < deg; t++)
        if (req_valid[t][1] && req_ready[t][1]) begin
          accepted++;
          req_valid[t][1] = 1'b0;
        end
    end
    done_at = cycle;
    drive_idle();
    repeat (NocLatency + 40) @(posedge clk);
    cfg.hold_subs_single = MshrCfgSubsW'(4);
    cfg.serve_timeout    = MshrCfgHoldCntW'(2047);
    check("T2_cohort_assembly", (accepted == deg) && ((noc_reqs_seen - noc0) == 1),
          $sformatf("%0d lanes asserting one line together: all accepted in %0d cycles, %0d NoC request(s)",
                    deg, done_at - cyc0, noc_reqs_seen - noc0));
  endtask

  // --------------------------------------------------------------------------------------------
  // T3 MISS LATENCY -- one request, no contention. The MSHR's own contribution is the measured
  // value minus NocLatency; a pipeline stage adds to exactly this number.
  // --------------------------------------------------------------------------------------------
  task automatic t_latency();
    automatic int at = -1, got = -1, guard = 0;
    cfg.hold_subs_single = MshrCfgSubsW'(1);   // a lone request must not wait for peers
    cfg.serve_timeout    = MshrCfgHoldCntW'(8);
    reset_dut();
    fork
      // Monitor first, so a fast response cannot land before we are listening.
      begin : mon
        while (got < 0 && guard < NocLatency + 200) begin
          @(posedge clk);
          guard++;
          if (resp_valid[0][1] && at >= 0) got = cycle;
        end
      end
      begin : stim
        send(0, 1, tcdm_addr_t'(32'h0000_2000), tile_core_id_t'(0), meta_id_t'(3), 1, at);
      end
    join
    cfg.hold_subs_single = MshrCfgSubsW'(4);
    cfg.serve_timeout    = MshrCfgHoldCntW'(2047);
    check("T3_miss_latency", (got > at) && (at >= 0),
          $sformatf("accept->response %0d cycles (NoC model %0d, MSHR adds %0d)",
                    got - at, NocLatency, got - at - NocLatency));
  endtask

  // --------------------------------------------------------------------------------------------
  // T4 CAPACITY -- distinct lines until the door stops accepting. Should reach close to MshrNum
  // before backpressure; a much lower number means ways are being wasted or held.
  // --------------------------------------------------------------------------------------------
  task automatic t_capacity();
    automatic int outstanding = 0;
    reset_dut();
    for (int i = 0; i < MshrNum * 3; i++) begin
      req[0][1].tgt_addr      = tcdm_addr_t'(32'h0001_0000 + (i << 2));  // word stride: spread banks
      req[0][1].tgt_group_id  = group_id_t'(1);
      req[0][1].wen           = 1'b0;
      req[0][1].be            = '1;
      req[0][1].burst_len     = BurstLenWidth'(1);
      req[0][1].wdata.core_id = tile_core_id_t'(0);
      req[0][1].wdata.meta_id = meta_id_t'(i & 7);
      req[0][1].wdata.amo     = '0;
      req_valid[0][1]         = 1'b1;
      @(posedge clk);
      if (req_ready[0][1]) outstanding++;
    end
    drive_idle();
    check("T4_capacity", outstanding >= MshrWaysPerBank,
          $sformatf("%0d of %0d entries filled from one lane (ways/bank=%0d; a stride hashing to one bank stops there)",
                    outstanding, MshrNum, MshrWaysPerBank));
  endtask

  // --------------------------------------------------------------------------------------------
  // T5 BANK HASH -- sweep the address pattern a GEMM actually issues and histogram the bank the
  // MSHR picks. Nothing else in the flow observes this, and a hash that reaches few banks
  // CONCURRENTLY is the known cause of livelock-grade slowdowns.
  // --------------------------------------------------------------------------------------------
  task automatic t_bank_hash();
    automatic int hist[BankNum];
    automatic int reached, worst, best_reached, best_shift;
    automatic int strides[4] = '{4, 64, 256, 1024};
    automatic bit any_ok = 1'b0;
    reset_dut();
    $display("[MSHR-UNIT]      bank-hash sweep: banks reached out of %0d", BankNum);
    foreach (strides[si]) begin
      best_reached = 0; best_shift = 0;
      for (int sh = 0; sh < (1 << MshrCfgShiftW); sh++) begin
        cfg.bank_shift_single = MshrCfgShiftW'(sh);
        for (int b = 0; b < BankNum; b++) hist[b] = 0;
        for (int i = 0; i < 256; i++) begin
          req[0][1].tgt_addr      = tcdm_addr_t'(32'h0002_0000 + i * strides[si]);
          req[0][1].tgt_group_id  = group_id_t'(1);
          req[0][1].wen           = 1'b0;
          req[0][1].be            = '1;
          req[0][1].burst_len     = BurstLenWidth'(1);
          req[0][1].wdata.core_id = tile_core_id_t'(0);
          req[0][1].wdata.meta_id = meta_id_t'(0);
          req[0][1].wdata.amo     = '0;
          req_valid[0][1]         = 1'b1;
          #1;
          hist[i_dut.req_bank[0][1]]++;
        end
        reached = 0; worst = 0;
        for (int b = 0; b < BankNum; b++) begin
          if (hist[b] > 0) reached++;
          if (hist[b] > worst) worst = hist[b];
        end
        if (reached > best_reached) begin best_reached = reached; best_shift = sh; end
      end
      if (best_reached == BankNum) any_ok = 1'b1;
      $display("[MSHR-UNIT]        stride %5dB : best %2d banks at bank_shift_single=%0d",
               strides[si], best_reached, best_shift);
    end
    drive_idle();
    cfg.bank_shift_single = '0;
    check("T5_bank_hash", any_ok,
          "some shift reaches every bank for at least one GEMM stride (see the sweep above)");
  endtask

  // --------------------------------------------------------------------------------------------
  // --------------------------------------------------------------------------------------------
  // T6 STAGGERED COHORT -- followers arrive `gap` cycles apart rather than all together. T2 covers
  // the simultaneous case, where allocation forwarding is irrelevant, so a cost that only shows in
  // the cluster must live here. Reports assembly time for several gaps.
  // --------------------------------------------------------------------------------------------
  task automatic t_stagger();
    automatic int noc0, accepted, cyc0, gaps[3];
    automatic int deg = 8;
    gaps[0] = 1; gaps[1] = 2; gaps[2] = 4;
    cfg.hold_subs_single = MshrCfgSubsW'(4);
    cfg.serve_timeout    = MshrCfgHoldCntW'(64);
    for (int g = 0; g < 3; g++) begin
      reset_dut();
      noc0 = noc_reqs_seen; accepted = 0; cyc0 = cycle;
      fork
        begin
          for (int t = 0; t < deg; t++) begin
            req[t][1].tgt_addr      = tcdm_addr_t'(32'h0000_3000);
            req[t][1].tgt_group_id  = group_id_t'(1);
            req[t][1].wen           = 1'b0;
            req[t][1].be            = '1;
            req[t][1].burst_len     = BurstLenWidth'(1);
            req[t][1].wdata.core_id = tile_core_id_t'(0);
            req[t][1].wdata.meta_id = meta_id_t'(t);
            req[t][1].wdata.amo     = '0;
            req_valid[t][1]         = 1'b1;
            repeat (gaps[g]) @(posedge clk);
          end
        end
        begin
          while (accepted < deg && (cycle - cyc0) < 300) begin
            @(posedge clk);
            for (int t = 0; t < deg; t++)
              if (req_valid[t][1] && req_ready[t][1]) begin accepted++; req_valid[t][1] = 1'b0; end
          end
        end
      join_any
      disable fork;
      $display("[MSHR-UNIT]        gap %0d: %0d/%0d lanes in %0d cycles, %0d NoC req",
               gaps[g], accepted, deg, cycle - cyc0, noc_reqs_seen - noc0);
      drive_idle();
      repeat (NocLatency + 30) @(posedge clk);
    end
    cfg.serve_timeout = MshrCfgHoldCntW'(2047);
    check("T6_staggered_cohort", 1'b1, "see the per-gap lines above");
  endtask

  // --------------------------------------------------------------------------------------------
  // T7 RESPONSE ROUTING -- an entry becomes visible to the response path one cycle later after the
  // cut. A beat returning before the entry lands finds resp_is_mshr false and BYPASSES, so the
  // cohort never gets its merged copy. Counts tagged (MSHR-routed) vs untagged (bypassed).
  // --------------------------------------------------------------------------------------------
  task automatic t_resp_bypass();
    automatic int at, mshr_routed, bypassed, sent, cohort = 8;
    cfg.hold_subs_single = MshrCfgSubsW'(4);
    cfg.serve_timeout    = MshrCfgHoldCntW'(64);
    reset_dut();
    mshr_routed = 0; bypassed = 0; sent = 0;
    // Drive a cohort, then watch a FIXED window with the monitor still alive -- the previous
    // version used join_any/disable fork and killed the monitor before any beat returned, which
    // is why it reported 0/0 for both builds and proved nothing.
    for (int t = 0; t < cohort; t++) begin
      req[t][1].tgt_addr      = tcdm_addr_t'(32'h0000_6000);
      req[t][1].tgt_group_id  = group_id_t'(1);
      req[t][1].wen           = 1'b0;
      req[t][1].be            = '1;
      req[t][1].burst_len     = BurstLenWidth'(1);
      req[t][1].wdata.core_id = tile_core_id_t'(0);
      req[t][1].wdata.meta_id = meta_id_t'(t);
      req[t][1].wdata.amo     = '0;
      req_valid[t][1]         = 1'b1;
    end
    for (int k = 0; k < 300; k++) begin
      @(posedge clk);
      for (int t = 0; t < cohort; t++)
        if (req_valid[t][1] && req_ready[t][1]) begin sent++; req_valid[t][1] = 1'b0; end
      for (int t = 0; t < NumTiles; t++)
        for (int pp = 1; pp < RespPorts; pp++)
          if (resp_valid[t][pp]) begin
            if (resp[t][pp].mshr_tag != '0) mshr_routed++; else bypassed++;
          end
    end
    drive_idle();
    cfg.serve_timeout = MshrCfgHoldCntW'(2047);
    // Every member of a merged cohort must get a copy: responses delivered >= requests accepted.
    check("T7_resp_routing", (mshr_routed + bypassed) >= sent,
          $sformatf("%0d accepted -> %0d responses (%0d MSHR-routed, %0d bypass)",
                    sent, mshr_routed + bypassed, mshr_routed, bypassed));
  endtask

  // --------------------------------------------------------------------------------------------
  // T8 BURST COHORT -- every other test uses burst_len 1, but the fp16 GEMM shapes issue vector
  // loads, and the second-slot drain (PD2 / beat_pending2 / beat2_armed) is burst-only. If a cost
  // survives the single-beat fixes it should appear here.
  // --------------------------------------------------------------------------------------------
  task automatic t_burst_cohort();
    automatic int noc0, accepted, cyc0, blen = 8;
    automatic int deg = 8;
    cfg.hold_subs_single = MshrCfgSubsW'(4);
    cfg.hold_subs_burst  = MshrCfgSubsW'(4);
    cfg.serve_timeout    = MshrCfgHoldCntW'(64);
    reset_dut();
    noc0 = noc_reqs_seen; accepted = 0; cyc0 = cycle;
    for (int t = 0; t < deg; t++) begin
      req[t][1].tgt_addr      = tcdm_addr_t'(32'h0000_5000);
      req[t][1].tgt_group_id  = group_id_t'(1);
      req[t][1].wen           = 1'b0;
      req[t][1].be            = '1;
      req[t][1].burst_len     = BurstLenWidth'(blen);
      // Bursts must carry core_id 1: the ParityDrain retag routes beat k to lane k%%4 and
      // pd2_burst_sub_coreid enforces the convention.
      req[t][1].wdata.core_id = tile_core_id_t'(1);
      req[t][1].wdata.meta_id = meta_id_t'(t * blen);
      req[t][1].wdata.amo     = '0;
      req_valid[t][1]         = 1'b1;
    end
    while (accepted < deg && (cycle - cyc0) < 400) begin
      @(posedge clk);
      for (int t = 0; t < deg; t++)
        if (req_valid[t][1] && req_ready[t][1]) begin accepted++; req_valid[t][1] = 1'b0; end
    end
    drive_idle();
    repeat (NocLatency + blen + 60) @(posedge clk);
    cfg.serve_timeout = MshrCfgHoldCntW'(2047);
    check("T8_burst_cohort", accepted == deg,
          $sformatf("%0d lanes, burst_len %0d, one line: %0d accepted in %0d cycles, %0d NoC req",
                    deg, blen, accepted, cycle - cyc0, noc_reqs_seen - noc0));
  endtask


  initial begin
    string only;
    errors = 0;
    cfg = '0;
    cfg.enable                = 1'b1;
    cfg.hold_subs_single      = MshrCfgSubsW'(4);
    cfg.hold_subs_burst       = MshrCfgSubsW'(4);
    cfg.hold_window_single    = '0;
    cfg.hold_window_burst     = '0;
    cfg.serve_timeout         = MshrCfgHoldCntW'(2047);
    cfg.bank_shift_single     = '0;
    cfg.bank_shift_burst      = '0;
    cfg.bank_burst_bits       = '0;
    cfg.cache_reuse_target    = '0;
    cfg.cache_timeout         = MshrCfgHoldCntW'(2047);
    cfg.bankfull_backpressure = 1'b1;

    if (!$value$plusargs("MSHR_UNIT_TEST=%s", only)) only = "all";
    $display("[MSHR-UNIT] start: lanes=%0d entries=%0d banks=%0d ways/bank=%0d merge_reqs=%0d",
             NumLanes, MshrNum, BankNum, MshrWaysPerBank, MshrMergeReqs);

    if (only inside {"all","throughput"}) t_throughput();
    if (only inside {"all","cohort"})     t_cohort();
    if (only inside {"all","latency"})    t_latency();
    if (only inside {"all","capacity"})   t_capacity();
    if (only inside {"all","hash"})       t_bank_hash();
    if (only inside {"all","stagger"})    t_stagger();
    if (only inside {"all","resp"})       t_resp_bypass();
    if (only inside {"all","burst"})      t_burst_cohort();

    $display("[MSHR-UNIT] done: %0d failure(s)", errors);
    if (errors != 0) $fatal(1, "[MSHR-UNIT] %0d test(s) failed", errors);
    $finish;
  end

endmodule
