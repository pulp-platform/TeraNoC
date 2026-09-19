// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Simulation-only STATISTICS and PROBES for mempool_group_mshr.
//
// Included into the module body rather than bound as a separate module: the entry type
// (mempool_group_mshr_t) and its companions are typedef'd inside the module, so a bound module
// could not declare matching ports without first moving those types into a package.
//
// Everything here is inside `ifndef TARGET_SYNTHESIS` / `ifndef VERILATOR` and contributes no
// hardware. Keep it that way -- these blocks instantiate 32-bit counters and `final` blocks that
// synthesis would otherwise build or trip over.
//
// Emits: [MSHRG] (read by gen_fp16_sweep_dash.py, parse_ks_probes.py, collect_8x8_results.py),
// [RH STUCK] (NOTE: a SPACE, not a hyphen), [MSHRLIFE], [F3cCOV], [MRGARB], [CAPARB].

  `ifndef TARGET_SYNTHESIS
  `ifndef TARGET_SYNTHESIS
  `ifndef VERILATOR
  generate
    if (EnableStats) begin : gen_stats
      // Occupancy, capacity, free-entry cohorts and hold-release histograms below remain
      // banked-table measurements. Request/response and cache event totals include the pool.
      logic [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1] stat_cache_store_match;
      // Root-cause instrumentation (whole-run accumulators, one dump at final): - per-bank alloc /
      // Bank-full histograms: is the way-conflict pressure concentrated in a few hot banks or
      logic [63:0] stat_bank_alloc_hist [MshrBankNum];
      logic [63:0] stat_bank_ovf_hist   [MshrBankNum];
      logic [63:0] stat_free_s_subs1, stat_free_s_subs2p, stat_free_s_subs_sum, stat_free_s_cachehit_sum;
      logic [63:0] stat_free_b_subs1, stat_free_b_subs2p, stat_free_b_subs_sum;
      logic [63:0] stat_drain_stall_s, stat_drain_stall_b;
      logic [63:0] stat_hold_early_s, stat_hold_early_b, stat_hold_to_s, stat_hold_to_b;
      logic [MshrNum-1:0] stat_issued_shadow_q;
      logic [7:0]  rc_bank_alloc_inc [MshrBankNum];
      logic [7:0]  rc_bank_ovf_inc   [MshrBankNum];
      logic [7:0]  rc_drain_stall_s_inc, rc_drain_stall_b_inc;
      logic [7:0]  rc_free_s_subs1_inc, rc_free_s_subs2p_inc, rc_free_b_subs1_inc, rc_free_b_subs2p_inc;
      logic [15:0] rc_free_s_subs_sum_inc, rc_free_b_subs_sum_inc;
      logic [31:0] rc_free_s_cachehit_inc;
      logic [7:0]  rc_hold_early_s_inc, rc_hold_early_b_inc, rc_hold_to_s_inc, rc_hold_to_b_inc;

      always_comb begin
        for (int b = 0; b < MshrBankNum; b++) begin
          rc_bank_alloc_inc[b] = '0;
          rc_bank_ovf_inc[b]   = '0;
        end
        rc_drain_stall_s_inc = '0; rc_drain_stall_b_inc = '0;
        rc_free_s_subs1_inc = '0; rc_free_s_subs2p_inc = '0; rc_free_s_subs_sum_inc = '0;
        rc_free_b_subs1_inc = '0; rc_free_b_subs2p_inc = '0; rc_free_b_subs_sum_inc = '0;
        rc_free_s_cachehit_inc = '0;
        rc_hold_early_s_inc = '0; rc_hold_early_b_inc = '0; rc_hold_to_s_inc = '0; rc_hold_to_b_inc = '0;
        for (int t = 0; t < NumTilesPerGroup; t++) begin
          for (int p = 1; p < NumRemoteReqPortsPerTile; p++) begin
            if (req_in_valid[t][p] && req_can_merge[t][p]) begin
              if (req_in_ready[t][p] && !req_merge_valid[t][p] &&
                  !req_merge_pool_valid[t][p]) begin
                // A POOL grant is a per-bank ALLOCATION too: the request hashed to this bank and did
                // get an entry, it simply came from the pool rather than a way. Counting it in
                // bank_ovf_hist would say the bank overflowed AND the request was lost, which is
                // wrong on the second half. The bank it is binned under is still the hashed bank,
                // which is the informative part.
                if (req_alloc_found[t][p] || req_alloc_found_pool[t][p]) begin
                  rc_bank_alloc_inc[req_bank[t][p]] = rc_bank_alloc_inc[req_bank[t][p]] + 1'b1;
                end else begin
                  rc_bank_ovf_inc[req_bank[t][p]] = rc_bank_ovf_inc[req_bank[t][p]] + 1'b1;
                end
              end
              if (req_addr_hit_drain[t][p]) begin
                if (req_len[t][p] == BurstLenWidth'(1)) begin
                  rc_drain_stall_s_inc = rc_drain_stall_s_inc + 1'b1;
                end else begin
                  rc_drain_stall_b_inc = rc_drain_stall_b_inc + 1'b1;
                end
              end
            end
          end
        end
        for (int e = 0; e < MshrNum; e++) begin
          if (mshr_q_valid[e] && !mshr_d_valid[e]) begin
            if (mshr_q[e].burst_len == BurstLenWidth'(1)) begin
              if (mshr_q[e].sub_reqs_num <= SubReqCountW'(1)) rc_free_s_subs1_inc = rc_free_s_subs1_inc + 1'b1;
              else                                            rc_free_s_subs2p_inc = rc_free_s_subs2p_inc + 1'b1;
              rc_free_s_subs_sum_inc = rc_free_s_subs_sum_inc + 16'(mshr_q[e].sub_reqs_num);
`ifndef TARGET_SYNTHESIS
              rc_free_s_cachehit_inc = rc_free_s_cachehit_inc + mshr_q[e].cache_hit_cnt;
`endif
            end else begin
              if (mshr_q[e].sub_reqs_num <= SubReqCountW'(1)) rc_free_b_subs1_inc = rc_free_b_subs1_inc + 1'b1;
              else                                            rc_free_b_subs2p_inc = rc_free_b_subs2p_inc + 1'b1;
              rc_free_b_subs_sum_inc = rc_free_b_subs_sum_inc + 16'(mshr_q[e].sub_reqs_num);
            end
          end
          // Only classify entries whose OWN per-type window is non-zero.
          if ((HoldWindowMax != 0) && mshr_q_valid[e] && mshr_q[e].issued && !stat_issued_shadow_q[e]) begin
            if (mshr_q[e].burst_len == BurstLenWidth'(1)) begin
              if (cfg_hold_window_single != 0) begin
                if (mshr_q[e].hold_cnt == '0) rc_hold_to_s_inc    = rc_hold_to_s_inc + 1'b1;
                else                          rc_hold_early_s_inc = rc_hold_early_s_inc + 1'b1;
              end
            end else begin
              if (cfg_hold_window_burst != 0) begin
                if (mshr_q[e].hold_cnt == '0) rc_hold_to_b_inc    = rc_hold_to_b_inc + 1'b1;
                else                          rc_hold_early_b_inc = rc_hold_early_b_inc + 1'b1;
              end
            end
          end
        end
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          for (int b = 0; b < MshrBankNum; b++) begin
            stat_bank_alloc_hist[b] <= '0;
            stat_bank_ovf_hist[b]   <= '0;
          end
          stat_free_s_subs1 <= '0; stat_free_s_subs2p <= '0; stat_free_s_subs_sum <= '0;
          stat_free_s_cachehit_sum <= '0;
          stat_free_b_subs1 <= '0; stat_free_b_subs2p <= '0; stat_free_b_subs_sum <= '0;
          stat_drain_stall_s <= '0; stat_drain_stall_b <= '0;
          stat_hold_early_s <= '0; stat_hold_early_b <= '0; stat_hold_to_s <= '0; stat_hold_to_b <= '0;
          stat_issued_shadow_q <= '0;
        end else begin
          for (int e = 0; e < MshrNum; e++) begin
            stat_issued_shadow_q[e] <= mshr_q_valid[e] && mshr_q[e].issued;
          end
          if (csr_trace_any_i) begin
            for (int b = 0; b < MshrBankNum; b++) begin
              stat_bank_alloc_hist[b] <= stat_bank_alloc_hist[b] + 64'(rc_bank_alloc_inc[b]);
              stat_bank_ovf_hist[b]   <= stat_bank_ovf_hist[b]   + 64'(rc_bank_ovf_inc[b]);
            end
            stat_free_s_subs1        <= stat_free_s_subs1        + 64'(rc_free_s_subs1_inc);
            stat_free_s_subs2p       <= stat_free_s_subs2p       + 64'(rc_free_s_subs2p_inc);
            stat_free_s_subs_sum     <= stat_free_s_subs_sum     + 64'(rc_free_s_subs_sum_inc);
            stat_free_s_cachehit_sum <= stat_free_s_cachehit_sum + 64'(rc_free_s_cachehit_inc);
            stat_free_b_subs1        <= stat_free_b_subs1        + 64'(rc_free_b_subs1_inc);
            stat_free_b_subs2p       <= stat_free_b_subs2p       + 64'(rc_free_b_subs2p_inc);
            stat_free_b_subs_sum     <= stat_free_b_subs_sum     + 64'(rc_free_b_subs_sum_inc);
            stat_drain_stall_s       <= stat_drain_stall_s       + 64'(rc_drain_stall_s_inc);
            stat_drain_stall_b       <= stat_drain_stall_b       + 64'(rc_drain_stall_b_inc);
            stat_hold_early_s        <= stat_hold_early_s        + 64'(rc_hold_early_s_inc);
            stat_hold_early_b        <= stat_hold_early_b        + 64'(rc_hold_early_b_inc);
            stat_hold_to_s           <= stat_hold_to_s           + 64'(rc_hold_to_s_inc);
            stat_hold_to_b           <= stat_hold_to_b           + 64'(rc_hold_to_b_inc);
          end
        end
      end

      // Configuration summary at start of simulation.
      initial begin
        $display("[%0t] %m MSHR cfg: NumGroups=%0d NumTilesPerGroup=%0d NumRemoteReqPortsPerTile=%0d NumRemoteRespPortsPerTile=%0d",
                 $time, NumGroups, NumTilesPerGroup, NumRemoteReqPortsPerTile, NumRemoteRespPortsPerTile);
        $display("[%0t] %m MSHR cfg: MshrNum=%0d MshrMergeWords=%0d MshrMergeReqs=%0d RespBufWords=%0d DrainMultiPort=%0d EnableRespCache=%0d EnableStats=%0d StatsPeriod=%0d",
                 $time, MshrNum, MshrMergeWords, MshrMergeReqs, RespBufWords, DrainMultiPort, EnableRespCache,
                 EnableStats, StatsPeriod);
        $display("[%0t] %m MSHR cfg: MshrFullBurstWords=%0d EnableSingle=%0d EnableNonFullBurst=%0d EnableFullBurst=%0d",
                 $time, MshrFullBurstWords, EnableMshrSingleReq, EnableMshrNonFullBurstReq,
                 EnableMshrFullBurstReq);
        // Print the EFFECTIVE policy bit, not the localparam: with MshrCfgRuntime=1 the value in
        // Force comes from CSR 11, and an ELF that predates that CSR leaves the reset value
        $display("[%0t] %m MSHR cfg: BankfullBackpressure=%0d (0=bypass on full bank, 1=stall)",
                 $time, cfg_bankfull_bp);
        $display("[%0t] %m MSHR cfg: SpillReqIn=%0d SpillReqOut=%0d SpillRespIn=%0d SpillRespOut=%0d",
                 $time, SpillReqIn, SpillReqOut, SpillRespIn, SpillRespOut);
      end

      task automatic print_stats(input string tag,
                                 input logic [63-1:0] cycles,
                                 input logic [63-1:0] mshr_valid_acc,
                                 input logic [63-1:0] mshr_valid_uncached_acc,
                                 input logic [63-1:0] subreq_valid_acc,
                                 input logic [63-1:0] mshr_max_valid,
                                 input logic [63-1:0] subreq_max_valid,
                                 input logic [63-1:0] req_accept,
                                 input logic [63-1:0] req_accept_single,
                                 input logic [63-1:0] req_accept_burst,
                                 input logic [63-1:0] req_merge,
                                 input logic [63-1:0] req_alloc,
                                 input logic [63-1:0] req_bypass,
                                 input logic [63-1:0] req_mshr_overflow,
                                 input logic [63-1:0] req_subreq_overflow,
                                 input logic [63-1:0] resp_mshr,
                                 input logic [63-1:0] resp_bypass,
                                 input logic [63-1:0] cache_valid_acc,
                                 input logic [63-1:0] cache_max_valid,
                                 input logic [63-1:0] mshr_max_valid_uncached_in,
                                 input logic [63-1:0] cache_hit,
                                 input logic [63-1:0] cache_fill,
                                 input logic [63-1:0] cache_evict,
                                 input logic [63-1:0] cache_store_update,
                                 input logic [63-1:0] cache_amo_inval,
                                 input logic [63-1:0] cache_self_inval);
        real avg_mshr_valid;
        real avg_mshr_util;
        real avg_subreq_valid;
        real avg_subreq_util;
        real avg_subreq_per_mshr;
        real avg_cache_valid;
        real cache_hit_rate;
        real avg_mshr_valid_uncached;
        real avg_mshr_util_uncached;
        real mshr_max_valid_uncached;

        if (cycles != 0) begin
          avg_mshr_valid = $itor(mshr_valid_acc) / $itor(cycles);
          avg_mshr_util = $itor(mshr_valid_acc) / ($itor(cycles) * $itor(MshrNum));
          avg_subreq_valid = $itor(subreq_valid_acc) / $itor(cycles);
          if ((MshrNum * MshrMergeReqs) != 0) begin
            avg_subreq_util = $itor(subreq_valid_acc) /
                              ($itor(cycles) * $itor(MshrNum) * $itor(MshrMergeReqs));
          end else begin
            avg_subreq_util = 0.0;
          end
          if ((EnableRespCache ? mshr_valid_uncached_acc : mshr_valid_acc) != 0) begin
            avg_subreq_per_mshr = $itor(subreq_valid_acc) /
                                  $itor(EnableRespCache ? mshr_valid_uncached_acc : mshr_valid_acc);
          end else begin
            avg_subreq_per_mshr = 0.0;
          end
          avg_cache_valid = $itor(cache_valid_acc) / $itor(cycles);
          avg_mshr_valid_uncached = avg_mshr_valid - avg_cache_valid;
          if (MshrNum != 0) begin
            avg_mshr_util_uncached = avg_mshr_valid_uncached / $itor(MshrNum);
          end else begin
            avg_mshr_util_uncached = 0.0;
          end
          mshr_max_valid_uncached = $itor(mshr_max_valid_uncached_in);
          if ((cache_hit + cache_evict) != 0) begin
            cache_hit_rate = $itor(cache_hit) / $itor(cache_hit + cache_evict);
          end else begin
            cache_hit_rate = 0.0;
          end
        end else begin
          avg_mshr_valid = 0.0;
          avg_mshr_util = 0.0;
          avg_subreq_valid = 0.0;
          avg_subreq_util = 0.0;
          avg_subreq_per_mshr = 0.0;
          avg_cache_valid = 0.0;
          cache_hit_rate = 0.0;
          avg_mshr_valid_uncached = 0.0;
          avg_mshr_util_uncached = 0.0;
          mshr_max_valid_uncached = 0.0;
        end

        $display("[%0t] %m MSHR stats (%s):", $time, tag);
        $display("  cycles=%0d", cycles);
        $display("  mshr_valid_avg=%0f mshr_valid_max=%0d mshr_util_avg=%0f",
                 avg_mshr_valid, mshr_max_valid, avg_mshr_util);
        if (EnableRespCache) begin
          $display("  mshr_valid_uncached_avg=%0f mshr_valid_uncached_max=%0f mshr_util_uncached_avg=%0f",
                   avg_mshr_valid_uncached, mshr_max_valid_uncached, avg_mshr_util_uncached);
        end
        $display("  subreq_valid_avg=%0f subreq_valid_max=%0d subreq_util_avg=%0f subreq_per_valid_mshr_avg=%0f",
                 avg_subreq_valid, subreq_max_valid, avg_subreq_util, avg_subreq_per_mshr);
        $display("  reqs: accepted=%0d (single=%0d burst=%0d) merged=%0d alloc=%0d bypass=%0d mshr_overflow=%0d subreq_overflow=%0d",
                 req_accept, req_accept_single, req_accept_burst, req_merge, req_alloc, req_bypass,
                 req_mshr_overflow, req_subreq_overflow);
        $display("  resps: from_mshr=%0d from_bypass=%0d",
                 resp_mshr, resp_bypass);
        if (EnableRespCache) begin
          $display("  timeouts: resp_hold=%0d cache_aged=%0d issue=%0d   bankfull_bypass=%0d",
                   mshr_resp_hold_timeout_cnt_dbg, mshr_cache_timeout_cnt_dbg,
                   mshr_issue_timeout_cnt_dbg, req_bankfull_bypass_cnt_dbg);
          $display("  cache: valid_avg=%0f valid_max=%0d hit=%0d fill=%0d evict=%0d store_update=%0d amo_inval=%0d self_inval=%0d",
                   avg_cache_valid, cache_max_valid, cache_hit, cache_fill, cache_evict,
                   cache_store_update, cache_amo_inval, cache_self_inval);
          $display("  cache: hit_rate(hit/(hit+evict))=%0f", cache_hit_rate);
        end
      endtask

      always_comb begin
        stat_mshr_valid_cycle = '0;
        stat_cache_valid_cycle = '0;
        stat_mshr_valid_uncached_cycle = '0;
        stat_subreq_valid_cycle = '0;
        for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
          if (mshr_q_valid[mshr_i]) begin
            stat_mshr_valid_cycle = stat_mshr_valid_cycle + 1'b1;
            if (mshr_q[mshr_i].state == MSHR_CACHED) begin
              stat_cache_valid_cycle = stat_cache_valid_cycle + 1'b1;
            end else begin
              stat_subreq_valid_cycle =
                  stat_subreq_valid_cycle + mshr_q[mshr_i].sub_reqs_num;
            end
          end
        end
        if (stat_mshr_valid_cycle >= stat_cache_valid_cycle) begin
          stat_mshr_valid_uncached_cycle =
              stat_mshr_valid_cycle - stat_cache_valid_cycle;
        end else begin
          stat_mshr_valid_uncached_cycle = '0;
        end

        stat_req_accept_cycle = '0;
        stat_req_accept_single_cycle = '0;
        stat_req_accept_burst_cycle = '0;
        stat_req_merge_cycle = '0;
        stat_req_merge_single_cycle = '0;
        stat_req_merge_burst_cycle = '0;
        stat_req_alloc_cycle = '0;
        stat_req_alloc_single_cycle = '0;
        stat_req_alloc_burst_cycle = '0;
        stat_req_bypass_cycle = '0;
        stat_req_mshr_overflow_cycle = '0;
        stat_req_subreq_overflow_cycle = '0;
        for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
          for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
            stat_req_subreq_full_match[tile_i][port_i] = 1'b0;
            if (req_in_valid[tile_i][port_i] && req_can_merge[tile_i][port_i]) begin
              for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
                if (!stat_req_subreq_full_match[tile_i][port_i] &&
                    mshr_q_valid[mshr_i] &&
                    ((mshr_q[mshr_i].state == MSHR_WAIT_RESP) ||
                     (mshr_q[mshr_i].state == MSHR_RESP_HOLD)) &&
                    !mshr_resp_seen_now[mshr_i] &&
                    !mshr_resp_inflight[mshr_i] &&
                    (mshr_q[mshr_i].base_addr == req_addr_key[tile_i][port_i]) &&
                    (mshr_q[mshr_i].tgt_group_id == req_in[tile_i][port_i].tgt_group_id) &&
                    (mshr_q[mshr_i].burst_len == req_len[tile_i][port_i]) &&
                    ((mshr_q[mshr_i].sub_reqs_num + SubReqCountW'(1)) > MshrMergeReqs)) begin
                  stat_req_subreq_full_match[tile_i][port_i] = 1'b1;
                end
              end
            end

            if (req_in_valid[tile_i][port_i] && req_in_ready[tile_i][port_i]) begin
              stat_req_accept_cycle = stat_req_accept_cycle + 1'b1;
              if (req_len[tile_i][port_i] == BurstLenWidth'(1)) begin
                stat_req_accept_single_cycle = stat_req_accept_single_cycle + 1'b1;
              end else begin
                stat_req_accept_burst_cycle = stat_req_accept_burst_cycle + 1'b1;
              end
              if (req_merge_valid[tile_i][port_i] || req_merge_pool_valid[tile_i][port_i]) begin
                stat_req_merge_cycle = stat_req_merge_cycle + 1'b1;
                if (req_len[tile_i][port_i] == BurstLenWidth'(1)) begin
                  stat_req_merge_single_cycle = stat_req_merge_single_cycle + 1'b1;
                end else begin
                  stat_req_merge_burst_cycle = stat_req_merge_burst_cycle + 1'b1;
                end
              end else begin
                stat_req_bypass_cycle = stat_req_bypass_cycle + 1'b1;
                if (req_can_merge[tile_i][port_i]) begin
                  // A POOL grant is an allocation. Without this term it fell to the else-arm and was
                  // counted as an mshr_overflow -- "the request could not get an entry" -- when it
                  // HAD got one; it was also missing from stat_req_alloc entirely. This is the
                  // counter half of the same trap as the drive term: a pooled request walks a branch
                  // that used to mean "the bank was full and the request lost", so every statistic
                  // hanging off that branch silently changes meaning.
                  //
                  // stat_req_bypass_cycle is deliberately left alone. Its pre-existing definition is
                  // "the request did not merge" -- it already counts banked allocations too -- and a
                  // pooled request also did not merge, so it is consistent. Redefining it here would
                  // be the same error in the other direction.
                  if (req_alloc_found[tile_i][port_i] || req_alloc_found_pool[tile_i][port_i]) begin
                    stat_req_alloc_cycle = stat_req_alloc_cycle + 1'b1;
                    if (req_len[tile_i][port_i] == BurstLenWidth'(1)) begin
                      stat_req_alloc_single_cycle = stat_req_alloc_single_cycle + 1'b1;
                    end else begin
                      stat_req_alloc_burst_cycle = stat_req_alloc_burst_cycle + 1'b1;
                    end
                  end else begin
                    stat_req_mshr_overflow_cycle = stat_req_mshr_overflow_cycle + 1'b1;
                  end
                end
              end
              if (req_can_merge[tile_i][port_i] &&
                  stat_req_subreq_full_match[tile_i][port_i]) begin
                stat_req_subreq_overflow_cycle = stat_req_subreq_overflow_cycle + 1'b1;
              end
            end
          end
        end

        stat_resp_mshr_cycle = '0;
        stat_resp_bypass_cycle = '0;
        stat_cache_hit_cycle = '0;
        stat_cache_fill_cycle = '0;
        stat_cache_evict_cycle = '0;
        stat_cache_store_update_cycle = '0;
        stat_cache_store_match = '0;
        stat_cache_amo_inval_cycle = '0;
        stat_cache_self_inval_cycle = '0;
        for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
          for (int port_i = 1; port_i < NumRemoteRespPortsPerTile; port_i++) begin
            if (resp_out_valid[tile_i][port_i] && resp_out_ready[tile_i][port_i]) begin
              if (resp_from_mshr[tile_i][port_i]) begin
                stat_resp_mshr_cycle = stat_resp_mshr_cycle + 1'b1;
              end
              if (resp_from_bypass[tile_i][port_i]) begin
                stat_resp_bypass_cycle = stat_resp_bypass_cycle + 1'b1;
              end
            end
          end
        end

        if (EnableRespCache) begin
          for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
            for (int port_i = 1; port_i < NumRemoteReqPortsPerTile; port_i++) begin
              if (req_in_valid[tile_i][port_i] &&
                  req_in_ready[tile_i][port_i] &&
                  ((req_hit_mshr_sel_valid[tile_i][port_i] &&
                    (mshr_q[req_hit_mshr_sel_id[tile_i][port_i]].state == MSHR_CACHED)) ||
                   (req_merge_pool_valid[tile_i][port_i] &&
                    pool_q_valid[req_hit_pool_sel_id[tile_i][port_i]] &&
                    (pool_q[req_hit_pool_sel_id[tile_i][port_i]].state == MSHR_CACHED)))) begin
                stat_cache_hit_cycle = stat_cache_hit_cycle + 1'b1;
              end
              if (req_in_valid[tile_i][port_i] &&
                  req_in_ready[tile_i][port_i] &&
                  req_can_merge[tile_i][port_i] &&
                  !req_merge_valid[tile_i][port_i] &&
                  req_alloc_found[tile_i][port_i] &&
                  (mshr_q[req_alloc_found_mshr_id[tile_i][port_i]].state == MSHR_CACHED)) begin
                stat_cache_evict_cycle = stat_cache_evict_cycle + 1'b1;
              end
              if (req_in_valid[tile_i][port_i] &&
                  req_in_ready[tile_i][port_i] &&
                  req_is_store[tile_i][port_i] &&
                  (req_len[tile_i][port_i] == BurstLenWidth'(1))) begin
                for (int way_i = 0; way_i < MshrWaysPerBank; way_i++) begin
                  automatic int hit_e =
                      int'(req_bank[tile_i][port_i]) * MshrWaysPerBank + way_i;
                  if (mshr_q_valid[hit_e] &&
                      (mshr_q[hit_e].state == MSHR_CACHED) &&
                      req_addr_hit_way[tile_i][port_i][way_i]) begin
                    stat_cache_store_match[tile_i][port_i] = 1'b1;
                    break;
                  end
                end
                for (int p = 0; p < PoolNum; p++) begin
                  if (pool_q_valid[p] && (pool_q[p].state == MSHR_CACHED) &&
                      pool_addr_hit_way[tile_i][port_i][p]) begin
                    stat_cache_store_match[tile_i][port_i] = 1'b1;
                  end
                end
                if (stat_cache_store_match[tile_i][port_i]) begin
                  stat_cache_store_update_cycle = stat_cache_store_update_cycle + 1'b1;
                end
              end
            end
          end
          if (amo_invalidate) begin
            for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
              if (mshr_q_valid[mshr_i] && (mshr_q[mshr_i].state == MSHR_CACHED)) begin
                stat_cache_amo_inval_cycle = stat_cache_amo_inval_cycle + 1'b1;
              end
            end
            for (int p = 0; p < PoolNum; p++) begin
              if (pool_q_valid[p] && (pool_q[p].state == MSHR_CACHED)) begin
                stat_cache_amo_inval_cycle = stat_cache_amo_inval_cycle + 1'b1;
              end
            end
          end
          for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
            if (mshr_q_valid[mshr_i] &&
                (mshr_q[mshr_i].state != MSHR_CACHED) &&
                (mshr_d[mshr_i].state == MSHR_CACHED)) begin
              stat_cache_fill_cycle = stat_cache_fill_cycle + 1'b1;
            end
          end
          for (int p = 0; p < PoolNum; p++) begin
            if (pool_q_valid[p] && (pool_q[p].state != MSHR_CACHED) &&
                (pool_d[p].state == MSHR_CACHED)) begin
              stat_cache_fill_cycle = stat_cache_fill_cycle + 1'b1;
            end
          end
          // Cache self-invalidate (idea 1): a CACHED way that goes invalid this cycle without an
          // AMO and without being reclaimed by an allocation (alloc-reclaim keeps mshr_d_valid=1)
          if (CacheSelfInval) begin
            for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
              if (mshr_q_valid[mshr_i] && (mshr_q[mshr_i].state == MSHR_CACHED) &&
                  !mshr_d_valid[mshr_i] && !amo_invalidate) begin
                stat_cache_self_inval_cycle = stat_cache_self_inval_cycle + 1'b1;
              end
            end
            for (int p = 0; p < PoolNum; p++) begin
              if (pool_q_valid[p] && (pool_q[p].state == MSHR_CACHED) &&
                  !pool_d_valid[p] && !amo_invalidate) begin
                stat_cache_self_inval_cycle = stat_cache_self_inval_cycle + 1'b1;
              end
            end
          end
        end
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin
        logic            print_period;
        logic            print_fall;
        if (!rst_ni) begin
          stat_cycle_count <= 0;
          stat_mshr_valid_acc <= 0;
          stat_mshr_valid_uncached_acc <= 0;
          stat_cache_valid_acc <= 0;
          stat_subreq_valid_acc <= 0;
          stat_mshr_max_valid <= 0;
          stat_cache_max_valid <= 0;
          stat_mshr_max_valid_uncached <= 0;
          stat_subreq_max_valid <= 0;
          stat_req_accept <= 0;
          stat_req_accept_single <= 0;
          stat_req_accept_burst <= 0;
          stat_req_merge <= 0;
          stat_req_merge_single <= 0;
          stat_req_merge_burst <= 0;
          stat_req_alloc <= 0;
          stat_req_alloc_single <= 0;
          stat_req_alloc_burst <= 0;
          stat_req_bypass <= 0;
          stat_req_mshr_overflow <= 0;
          stat_req_subreq_overflow <= 0;
          stat_resp_mshr <= 0;
          stat_resp_bypass <= 0;
          stat_cache_hit <= 0;
          stat_cache_fill <= 0;
          stat_cache_evict <= 0;
          stat_cache_store_update <= 0;
          stat_cache_amo_inval <= 0;
          stat_cache_self_inval <= 0;
          stat_trace_q <= 1'b0;
        end else begin
          stat_trace_q <= csr_trace_any_i;

          stat_cycle_count_next = stat_cycle_count;
          stat_mshr_valid_acc_next = stat_mshr_valid_acc;
          stat_mshr_valid_uncached_acc_next = stat_mshr_valid_uncached_acc;
          stat_cache_valid_acc_next = stat_cache_valid_acc;
          stat_subreq_valid_acc_next = stat_subreq_valid_acc;
          stat_mshr_max_valid_next = stat_mshr_max_valid;
          stat_cache_max_valid_next = stat_cache_max_valid;
          stat_mshr_max_valid_uncached_next = stat_mshr_max_valid_uncached;
          stat_subreq_max_valid_next = stat_subreq_max_valid;
          stat_req_accept_next = stat_req_accept;
          stat_req_accept_single_next = stat_req_accept_single;
          stat_req_accept_burst_next = stat_req_accept_burst;
          stat_req_merge_next = stat_req_merge;
          stat_req_merge_single_next = stat_req_merge_single;
          stat_req_merge_burst_next = stat_req_merge_burst;
          stat_req_alloc_next = stat_req_alloc;
          stat_req_alloc_single_next = stat_req_alloc_single;
          stat_req_alloc_burst_next = stat_req_alloc_burst;
          stat_req_bypass_next = stat_req_bypass;
          stat_req_mshr_overflow_next = stat_req_mshr_overflow;
          stat_req_subreq_overflow_next = stat_req_subreq_overflow;
          stat_resp_mshr_next = stat_resp_mshr;
          stat_resp_bypass_next = stat_resp_bypass;
          stat_cache_hit_next = stat_cache_hit;
          stat_cache_fill_next = stat_cache_fill;
          stat_cache_evict_next = stat_cache_evict;
          stat_cache_store_update_next = stat_cache_store_update;
          stat_cache_amo_inval_next = stat_cache_amo_inval;
          stat_cache_self_inval_next = stat_cache_self_inval;

          if (csr_trace_any_i) begin
            stat_cycle_count_next = stat_cycle_count + 1;
            stat_mshr_valid_acc_next = stat_mshr_valid_acc + stat_mshr_valid_cycle;
            stat_mshr_valid_uncached_acc_next =
                stat_mshr_valid_uncached_acc + stat_mshr_valid_uncached_cycle;
            stat_cache_valid_acc_next = stat_cache_valid_acc + stat_cache_valid_cycle;
            stat_subreq_valid_acc_next = stat_subreq_valid_acc + stat_subreq_valid_cycle;
            if (stat_mshr_valid_cycle > stat_mshr_max_valid_next) begin
              stat_mshr_max_valid_next = stat_mshr_valid_cycle;
            end
            if (stat_cache_valid_cycle > stat_cache_max_valid_next) begin
              stat_cache_max_valid_next = stat_cache_valid_cycle;
            end
            if (stat_mshr_valid_uncached_cycle > stat_mshr_max_valid_uncached_next) begin
              stat_mshr_max_valid_uncached_next = stat_mshr_valid_uncached_cycle;
            end
            if (stat_subreq_valid_cycle > stat_subreq_max_valid_next) begin
              stat_subreq_max_valid_next = stat_subreq_valid_cycle;
            end
            stat_req_accept_next = stat_req_accept + stat_req_accept_cycle;
            stat_req_accept_single_next = stat_req_accept_single + stat_req_accept_single_cycle;
            stat_req_accept_burst_next = stat_req_accept_burst + stat_req_accept_burst_cycle;
            stat_req_merge_next = stat_req_merge + stat_req_merge_cycle;
            stat_req_merge_single_next = stat_req_merge_single + stat_req_merge_single_cycle;
            stat_req_merge_burst_next = stat_req_merge_burst + stat_req_merge_burst_cycle;
            stat_req_alloc_next = stat_req_alloc + stat_req_alloc_cycle;
            stat_req_alloc_single_next = stat_req_alloc_single + stat_req_alloc_single_cycle;
            stat_req_alloc_burst_next = stat_req_alloc_burst + stat_req_alloc_burst_cycle;
            stat_req_bypass_next = stat_req_bypass + stat_req_bypass_cycle;
            stat_req_mshr_overflow_next = stat_req_mshr_overflow + stat_req_mshr_overflow_cycle;
            stat_req_subreq_overflow_next = stat_req_subreq_overflow + stat_req_subreq_overflow_cycle;
            stat_resp_mshr_next = stat_resp_mshr + stat_resp_mshr_cycle;
            stat_resp_bypass_next = stat_resp_bypass + stat_resp_bypass_cycle;
            stat_cache_hit_next = stat_cache_hit + stat_cache_hit_cycle;
            stat_cache_fill_next = stat_cache_fill + stat_cache_fill_cycle;
            stat_cache_evict_next = stat_cache_evict + stat_cache_evict_cycle;
            stat_cache_store_update_next =
                stat_cache_store_update + stat_cache_store_update_cycle;
            stat_cache_amo_inval_next = stat_cache_amo_inval + stat_cache_amo_inval_cycle;
            stat_cache_self_inval_next = stat_cache_self_inval + stat_cache_self_inval_cycle;
          end

          print_period = (StatsPeriod != 0) && csr_trace_any_i &&
                         (stat_cycle_count_next >= StatsPeriod);
          print_fall = stat_trace_q && !csr_trace_any_i;
          if ((print_period || print_fall) && (stat_cycle_count_next != 0)) begin
            print_stats(print_period ? "period" : "trace_off",
                        stat_cycle_count_next,
                        stat_mshr_valid_acc_next,
                        stat_mshr_valid_uncached_acc_next,
                        stat_subreq_valid_acc_next,
                        stat_mshr_max_valid_next,
                        stat_subreq_max_valid_next,
                        stat_req_accept_next,
                        stat_req_accept_single_next,
                        stat_req_accept_burst_next,
                        stat_req_merge_next,
                        stat_req_alloc_next,
                        stat_req_bypass_next,
                        stat_req_mshr_overflow_next,
                        stat_req_subreq_overflow_next,
                        stat_resp_mshr_next,
                        stat_resp_bypass_next,
                        stat_cache_valid_acc_next,
                        stat_cache_max_valid_next,
                        stat_mshr_max_valid_uncached_next,
                        stat_cache_hit_next,
                        stat_cache_fill_next,
                        stat_cache_evict_next,
                        stat_cache_store_update_next,
                        stat_cache_amo_inval_next,
                        stat_cache_self_inval_next);
            $display("  reqs_by_class: merged_single=%0d merged_burst=%0d alloc_single=%0d alloc_burst=%0d",
                     stat_req_merge_single_next, stat_req_merge_burst_next,
                     stat_req_alloc_single_next, stat_req_alloc_burst_next);
            // Root-cause dump at the trace-off flush (the `final` block is skipped whenever the
            // Trace-off flush already zeroed stat_cycle_count, which is the common EOC path).
            // These accumulators are whole-run cumulative (never reset per period).
            if (print_fall) begin
              $write("  bank_alloc_hist:");
              for (int b = 0; b < MshrBankNum; b++) $write(" %0d", stat_bank_alloc_hist[b]);
              $write("\n  bank_ovf_hist:");
              for (int b = 0; b < MshrBankNum; b++) $write(" %0d", stat_bank_ovf_hist[b]);
              $write("\n");
              $display("  free_outcome: single subs1=%0d subs2p=%0d subs_sum=%0d cachehit_sum=%0d | burst subs1=%0d subs2p=%0d subs_sum=%0d",
                       stat_free_s_subs1, stat_free_s_subs2p, stat_free_s_subs_sum, stat_free_s_cachehit_sum,
                       stat_free_b_subs1, stat_free_b_subs2p, stat_free_b_subs_sum);
              $display("  drain_stall_cycles: single=%0d burst=%0d", stat_drain_stall_s, stat_drain_stall_b);
              if (HoldWindowMax != 0) begin
                $display("  hold_release: early_single=%0d timeout_single=%0d early_burst=%0d timeout_burst=%0d",
                         stat_hold_early_s, stat_hold_to_s, stat_hold_early_b, stat_hold_to_b);
              end
            end
            stat_cycle_count <= 0;
            stat_mshr_valid_acc <= 0;
            stat_mshr_valid_uncached_acc <= 0;
            stat_cache_valid_acc <= 0;
            stat_subreq_valid_acc <= 0;
            stat_mshr_max_valid <= 0;
            stat_cache_max_valid <= 0;
            stat_mshr_max_valid_uncached <= 0;
            stat_subreq_max_valid <= 0;
            stat_req_accept <= 0;
            stat_req_accept_single <= 0;
            stat_req_accept_burst <= 0;
            stat_req_merge <= 0;
            stat_req_merge_single <= 0;
            stat_req_merge_burst <= 0;
            stat_req_alloc <= 0;
            stat_req_alloc_single <= 0;
            stat_req_alloc_burst <= 0;
            stat_req_bypass <= 0;
            stat_req_mshr_overflow <= 0;
            stat_req_subreq_overflow <= 0;
            stat_resp_mshr <= 0;
            stat_resp_bypass <= 0;
            stat_cache_hit <= 0;
            stat_cache_fill <= 0;
            stat_cache_evict <= 0;
            stat_cache_store_update <= 0;
            stat_cache_amo_inval <= 0;
            stat_cache_self_inval <= 0;
          end else begin
            stat_cycle_count <= stat_cycle_count_next;
            stat_mshr_valid_acc <= stat_mshr_valid_acc_next;
            stat_mshr_valid_uncached_acc <= stat_mshr_valid_uncached_acc_next;
            stat_cache_valid_acc <= stat_cache_valid_acc_next;
            stat_subreq_valid_acc <= stat_subreq_valid_acc_next;
            stat_mshr_max_valid <= stat_mshr_max_valid_next;
            stat_cache_max_valid <= stat_cache_max_valid_next;
            stat_mshr_max_valid_uncached <= stat_mshr_max_valid_uncached_next;
            stat_subreq_max_valid <= stat_subreq_max_valid_next;
            stat_req_accept <= stat_req_accept_next;
            stat_req_accept_single <= stat_req_accept_single_next;
            stat_req_accept_burst <= stat_req_accept_burst_next;
            stat_req_merge <= stat_req_merge_next;
            stat_req_merge_single <= stat_req_merge_single_next;
            stat_req_merge_burst <= stat_req_merge_burst_next;
            stat_req_alloc <= stat_req_alloc_next;
            stat_req_alloc_single <= stat_req_alloc_single_next;
            stat_req_alloc_burst <= stat_req_alloc_burst_next;
            stat_req_bypass <= stat_req_bypass_next;
            stat_req_mshr_overflow <= stat_req_mshr_overflow_next;
            stat_req_subreq_overflow <= stat_req_subreq_overflow_next;
            stat_resp_mshr <= stat_resp_mshr_next;
            stat_resp_bypass <= stat_resp_bypass_next;
            stat_cache_hit <= stat_cache_hit_next;
            stat_cache_fill <= stat_cache_fill_next;
            stat_cache_evict <= stat_cache_evict_next;
            stat_cache_store_update <= stat_cache_store_update_next;
            stat_cache_amo_inval <= stat_cache_amo_inval_next;
            stat_cache_self_inval <= stat_cache_self_inval_next;
          end
        end
      end

      final begin
        if (stat_cycle_count != 0) begin
          print_stats("final",
                      stat_cycle_count,
                      stat_mshr_valid_acc,
                      stat_mshr_valid_uncached_acc,
                      stat_subreq_valid_acc,
                      stat_mshr_max_valid,
                      stat_subreq_max_valid,
                      stat_req_accept,
                      stat_req_accept_single,
                      stat_req_accept_burst,
                      stat_req_merge,
                      stat_req_alloc,
                      stat_req_bypass,
                      stat_req_mshr_overflow,
                      stat_req_subreq_overflow,
                      stat_resp_mshr,
                      stat_resp_bypass,
                      stat_cache_valid_acc,
                      stat_cache_max_valid,
                      stat_mshr_max_valid_uncached,
                      stat_cache_hit,
                      stat_cache_fill,
                      stat_cache_evict,
                      stat_cache_store_update,
                      stat_cache_amo_inval,
                      stat_cache_self_inval);
          $display("  reqs_by_class: merged_single=%0d merged_burst=%0d alloc_single=%0d alloc_burst=%0d",
                   stat_req_merge_single, stat_req_merge_burst,
                   stat_req_alloc_single, stat_req_alloc_burst);
          $write("  bank_alloc_hist:");
          for (int b = 0; b < MshrBankNum; b++) $write(" %0d", stat_bank_alloc_hist[b]);
          $write("\n  bank_ovf_hist:");
          for (int b = 0; b < MshrBankNum; b++) $write(" %0d", stat_bank_ovf_hist[b]);
          $write("\n");
          $display("  free_outcome: single subs1=%0d subs2p=%0d subs_sum=%0d cachehit_sum=%0d | burst subs1=%0d subs2p=%0d subs_sum=%0d",
                   stat_free_s_subs1, stat_free_s_subs2p, stat_free_s_subs_sum, stat_free_s_cachehit_sum,
                   stat_free_b_subs1, stat_free_b_subs2p, stat_free_b_subs_sum);
          $display("  drain_stall_cycles: single=%0d burst=%0d", stat_drain_stall_s, stat_drain_stall_b);
          if (HoldWindowMax != 0) begin
            $display("  hold_release: early_single=%0d timeout_single=%0d early_burst=%0d timeout_burst=%0d",
                     stat_hold_early_s, stat_hold_to_s, stat_hold_early_b, stat_hold_to_b);
          end
        end
      end
    end
  endgenerate
  `endif
  `endif
  `endif

  `ifndef TARGET_SYNTHESIS
  `ifndef TARGET_SYNTHESIS
  if (1) begin : gen_mshr_lifetime
    logic [31:0] ml_cyc;
    logic [31:0] ml_t_alloc [MshrNum];
    logic [31:0] ml_t_issue [MshrNum];
    logic [31:0] ml_t_first [MshrNum];
    logic [MshrNum-1:0] ml_seen_issue, ml_seen_first, ml_vld_q;
    logic [63:0] ml_hold_sum, ml_flight_sum, ml_drain_sum, ml_life_sum;
    logic [63:0] ml_hold_n,   ml_flight_n,   ml_drain_n,   ml_life_n;
    logic [63:0] ml_nobeat_n;   // freed without ever capturing a beat (drain undefined)
    // Split by burst length: a pooled drain mean is not comparable across models -- single-word
  // Entries drain in a couple of cycles and drag it down.
    logic [63:0] ml_drain_s_sum, ml_drain_s_n;              // burst_len == 1
    logic [63:0] ml_drain_b_sum, ml_drain_b_n, ml_bl_b_sum; // burst_len  > 1, + total beats
    logic [BurstLenWidth-1:0] ml_bl [MshrNum];              // burst_len captured at allocation
    // BEAT ARRIVAL SPACING within a single entry.
    logic [31:0] ml_t_last  [MshrNum];
    logic [31:0] ml_nbeats  [MshrNum];
    logic [63:0] ml_bspan_sum, ml_bspan_n, ml_bcap_sum;     // burst entries with >= 2 beats
    // TIME-AVERAGED OCCUPANCY, accumulated EVERY CYCLE: an instantaneous sample is an estimator,
  // Not a mean (GVSOC's was biased high by 2x).
    logic [63:0] ml_occ_sum, ml_occ_active;

    always_ff @(posedge clk_i) begin
      automatic logic [63:0] a_hold, a_flight, a_drain, a_life;
      automatic logic [63:0] n_hold, n_flight, n_drain, n_life, n_nobeat;
      automatic logic [63:0] a_drain_s, n_drain_s, a_drain_b, n_drain_b, a_bl_b;
      automatic logic [63:0] a_bspan, n_bspan, a_bcap;
      automatic logic [31:0] t_a;
      if (!rst_ni) begin
        ml_cyc <= '0; ml_vld_q <= '0; ml_seen_issue <= '0; ml_seen_first <= '0;
        ml_hold_sum <= '0; ml_flight_sum <= '0; ml_drain_sum <= '0; ml_life_sum <= '0;
        ml_hold_n <= '0; ml_flight_n <= '0; ml_drain_n <= '0; ml_life_n <= '0;
        ml_nobeat_n <= '0;
        ml_drain_s_sum <= '0; ml_drain_s_n <= '0;
        ml_drain_b_sum <= '0; ml_drain_b_n <= '0; ml_bl_b_sum <= '0;
        ml_bspan_sum <= '0; ml_bspan_n <= '0; ml_bcap_sum <= '0;
        ml_occ_sum <= '0; ml_occ_active <= '0;
      end else begin
        a_hold='0; a_flight='0; a_drain='0; a_life='0;
        n_hold='0; n_flight='0; n_drain='0; n_life='0; n_nobeat='0;
        a_drain_s='0; n_drain_s='0; a_drain_b='0; n_drain_b='0; a_bl_b='0;
        a_bspan='0; n_bspan='0; a_bcap='0;
        ml_cyc <= ml_cyc + 1;
        ml_occ_sum <= ml_occ_sum + 64'($countones(mshr_q_valid));
        if (|mshr_q_valid) ml_occ_active <= ml_occ_active + 1;
        for (int e = 0; e < MshrNum; e++) begin
          // An entry can be allocated and issued in the SAME cycle; ml_t_alloc[e] is
          // Nonblocking so it still holds the previous life's value here. Use the
          // Live stamp in that case, never the stale register.
          t_a = (mshr_q_valid[e] && !ml_vld_q[e]) ? ml_cyc : ml_t_alloc[e];

          if (mshr_q_valid[e] && !ml_vld_q[e]) begin
            ml_t_alloc[e]    <= ml_cyc;
            ml_seen_issue[e] <= 1'b0;
            ml_seen_first[e] <= 1'b0;
            ml_bl[e]         <= mshr_q[e].burst_len;
            ml_nbeats[e]     <= '0;
          end
          if (mshr_q_valid[e] && mshr_q[e].issued && !ml_seen_issue[e]) begin
            ml_t_issue[e]    <= ml_cyc;
            ml_seen_issue[e] <= 1'b1;
            a_hold = a_hold + 64'(ml_cyc - t_a); n_hold = n_hold + 1;
          end
          if (mshr_q_valid[e] && (|mshr_rb_we[e]) && ml_seen_issue[e] && !ml_seen_first[e]) begin
            ml_t_first[e]    <= ml_cyc;
            ml_seen_first[e] <= 1'b1;
            a_flight = a_flight + 64'(ml_cyc - ml_t_issue[e]); n_flight = n_flight + 1;
          end
          // Every beat, including the first: stamp the latest arrival and accumulate the count
          if (mshr_q_valid[e] && (|mshr_rb_we[e])) begin
            ml_t_last[e]  <= ml_cyc;
            ml_nbeats[e]  <= ml_nbeats[e] + 32'($countones(mshr_rb_we[e]));
          end
          if (!mshr_q_valid[e] && ml_vld_q[e]) begin
            if (ml_seen_first[e]) begin
              a_drain = a_drain + 64'(ml_cyc - ml_t_first[e]); n_drain = n_drain + 1;
              if (ml_bl[e] > BurstLenWidth'(1)) begin
                a_drain_b = a_drain_b + 64'(ml_cyc - ml_t_first[e]);
                n_drain_b = n_drain_b + 1;
                a_bl_b    = a_bl_b    + 64'(ml_bl[e]);
                // A single-beat entry has no arrival spacing to measure; excluding it keeps the
                // Rate from being diluted by entries that trivially span 0 cycles.
                if (ml_nbeats[e] >= 32'd2) begin
                  a_bspan = a_bspan + 64'(ml_t_last[e] - ml_t_first[e]);
                  n_bspan = n_bspan + 1;
                  a_bcap  = a_bcap  + 64'(ml_nbeats[e]);
                end
              end else begin
                a_drain_s = a_drain_s + 64'(ml_cyc - ml_t_first[e]);
                n_drain_s = n_drain_s + 1;
              end
            end else begin
              n_nobeat = n_nobeat + 1;
            end
            a_life = a_life + 64'(ml_cyc - ml_t_alloc[e]); n_life = n_life + 1;
          end
          ml_vld_q[e] <= mshr_q_valid[e];
        end
        ml_hold_sum   <= ml_hold_sum   + a_hold;   ml_hold_n   <= ml_hold_n   + n_hold;
        ml_flight_sum <= ml_flight_sum + a_flight; ml_flight_n <= ml_flight_n + n_flight;
        ml_drain_sum  <= ml_drain_sum  + a_drain;  ml_drain_n  <= ml_drain_n  + n_drain;
        ml_life_sum   <= ml_life_sum   + a_life;   ml_life_n   <= ml_life_n   + n_life;
        ml_nobeat_n   <= ml_nobeat_n   + n_nobeat;
        ml_drain_s_sum <= ml_drain_s_sum + a_drain_s; ml_drain_s_n <= ml_drain_s_n + n_drain_s;
        ml_drain_b_sum <= ml_drain_b_sum + a_drain_b; ml_drain_b_n <= ml_drain_b_n + n_drain_b;
        ml_bl_b_sum    <= ml_bl_b_sum    + a_bl_b;
        ml_bspan_sum <= ml_bspan_sum + a_bspan; ml_bspan_n <= ml_bspan_n + n_bspan;
        ml_bcap_sum  <= ml_bcap_sum  + a_bcap;
      end
    end

    final begin
      if (ml_life_n != 0)
        $display("[MSHRLIFE] %m MshrNum=%0d hold_n=%0d hold_sum=%0d flight_n=%0d flight_sum=%0d drain_n=%0d drain_sum=%0d life_n=%0d life_sum=%0d freed_without_beat=%0d",
                 MshrNum, ml_hold_n, ml_hold_sum, ml_flight_n, ml_flight_sum,
                 ml_drain_n, ml_drain_sum, ml_life_n, ml_life_sum, ml_nobeat_n);
      if (ml_life_n != 0)
        $display("[MSHRLIFE-BL] %m drain_single_n=%0d drain_single_sum=%0d drain_burst_n=%0d drain_burst_sum=%0d burst_beats_sum=%0d",
                 ml_drain_s_n, ml_drain_s_sum, ml_drain_b_n, ml_drain_b_sum, ml_bl_b_sum);
      if (ml_bspan_n != 0)
        $display("[MSHRLIFE-BEATS] %m entries=%0d first_to_last_sum=%0d beats_captured_sum=%0d",
                 ml_bspan_n, ml_bspan_sum, ml_bcap_sum);
      $display("[MSHRLIFE-OCC] %m MshrNum=%0d cycles=%0d occ_sum=%0d active_cycles=%0d",
               MshrNum, ml_cyc, ml_occ_sum, ml_occ_active);
    end
  end
  `endif
  `endif
