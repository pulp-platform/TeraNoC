// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Zexin Fu <zexifu@iis.ee.ethz.ch>

`ifndef TB_GROUP_MERGE_SVH_
`define TB_GROUP_MERGE_SVH_

`ifndef TARGET_SYNTHESIS
`ifndef TARGET_VERILATOR
`ifdef GROUP_MERGE_PROFILING

  // Merge profiling parameters (compile-time). Override with defines as needed.
  // - MergeBurstWords: burst length in words (merge granularity).
  // - MergeWindowCycles: cycles an MSHR stays open for merging since first request.
  // - MergeMshrNum: number of MSHR entries tracked per group.
  // - MergeRecordsPerMshr: max unique word offsets tracked per MSHR.
  // - MergeReqsPerMshr: max total requests accepted per MSHR (duplicates allowed).
  // - MergeRecordLimit: actual cap on unique records (min of burst words and records).
  // - MergeAnalyzeMode: load/store selection (0 combined, 1 load-only, 2 store-only).
  // - MergeSeparateMshr: separate pools for load/store (0 shared, 1 split).
  // - MergeUtilDumpCycles: periodic utilization dump interval in cycles (0 disables).
  localparam int unsigned MergeBurstWords      = `ifdef MERGE_BURST_WORDS      `MERGE_BURST_WORDS      `else 16 `endif;
  localparam int unsigned MergeWindowCycles    = `ifdef MERGE_WINDOW_CYCLES    `MERGE_WINDOW_CYCLES    `else 8  `endif;
  localparam int unsigned MergeMshrNum         = `ifdef MERGE_MSHR_NUM         `MERGE_MSHR_NUM         `else 8  `endif;
  localparam int unsigned MergeRecordsPerMshr  = `ifdef MERGE_RECORDS_PER_MSHR `MERGE_RECORDS_PER_MSHR `else 16 `endif;
  localparam int unsigned MergeReqsPerMshr     = `ifdef MERGE_REQS_PER_MSHR    `MERGE_REQS_PER_MSHR    `else 16 `endif;
  localparam int unsigned MergeRecordLimit     = (MergeRecordsPerMshr < MergeBurstWords) ?
                                                 MergeRecordsPerMshr : MergeBurstWords;
  localparam int unsigned MergeUtilDumpCycles  = `ifdef MERGE_UTIL_DUMP_CYCLES `MERGE_UTIL_DUMP_CYCLES `else 10000 `endif;
  // MergeAnalyzeMode: 0 = combined (load+store), 1 = load-only, 2 = store-only.
  localparam int unsigned MergeAnalyzeMode     = `ifdef MERGE_ANALYZE_MODE `MERGE_ANALYZE_MODE `else 1 `endif;
  // MergeSeparateMshr: 0 = shared pool, 1 = separate pools for load/store.
  localparam bit          MergeSeparateMshr    = `ifdef MERGE_SEPARATE_MSHR `MERGE_SEPARATE_MSHR `else 0 `endif;
  localparam bit          MergeAnalyzeLoad     = (MergeAnalyzeMode == 0) || (MergeAnalyzeMode == 1);
  localparam bit          MergeAnalyzeStore    = (MergeAnalyzeMode == 0) || (MergeAnalyzeMode == 2);
  localparam int unsigned MergeMshrPools       = MergeSeparateMshr ? 2 : 1;
  localparam int unsigned MergeMshrTotal       = MergeMshrPools * MergeMshrNum;

  typedef struct packed {
    logic             valid;
    logic             wen;
    tcdm_addr_t       burst_base_addr;
    logic [MergeBurstWords-1:0] word_mask;
    int unsigned      req_count;
    int unsigned      record_count;
    tile_group_id_t [MergeReqsPerMshr-1:0]   req_tile_id;
    logic [MergeReqsPerMshr-1:0] req_tile_id_valid;
    longint unsigned  start_cycle;
    longint unsigned  last_cycle;
  } merge_mshr_entry_t;

  logic [63:0] merge_cycle_q;

  merge_mshr_entry_t [NumGroups-1:0][MergeMshrPools-1:0][MergeMshrNum-1:0]              merge_mshr_q;
  merge_mshr_entry_t [NumGroups-1:0][MergeMshrPools-1:0][MergeMshrNum-1:0]              merge_mshr_shadow;
  logic [NumGroups-1:0][MergeMshrPools-1:0][MergeMshrNum-1:0]                           merge_mshr_q_valid;
  logic [NumGroups-1:0][MergeMshrTotal-1:0]                                             merge_mshr_q_valid_flat;
  // Per-group thresholds: valid MSHR count > 0..MergeMshrTotal-1 (index = threshold, pooled if split).
  logic [MergeMshrTotal-1:0][NumGroups-1:0]                                             merge_mshr_q_valid_count_more_than_x;
  logic [MergeMshrTotal-1:0][NumGroups-1:0]                                             merge_mshr_q_valid_count_x;
  // Per-MSHR thresholds: req_count > 0..MergeReqsPerMshr-1 (index = threshold).
  logic [MergeReqsPerMshr-1:0][NumGroups-1:0][MergeMshrPools-1:0][MergeMshrNum-1:0]     merge_mshr_q_req_count_more_than_x;
  logic [MergeReqsPerMshr-1:0][NumGroups-1:0][MergeMshrPools-1:0][MergeMshrNum-1:0]     merge_mshr_q_req_count_x;
  // Per-MSHR thresholds: record_count > 0..MergeRecordsPerMshr-1 (index = threshold).
  logic [MergeRecordsPerMshr-1:0][NumGroups-1:0][MergeMshrPools-1:0][MergeMshrNum-1:0]  merge_mshr_q_record_count_more_than_x;
  logic [MergeRecordsPerMshr-1:0][NumGroups-1:0][MergeMshrPools-1:0][MergeMshrNum-1:0]  merge_mshr_q_record_count_x;

  generate
    for(genvar g = 0; g < NumGroups; g++) begin : gen_merge_mshr_group
      for (genvar p_i = 0; p_i < MergeMshrPools; p_i++) begin : gen_merge_mshr_pool
        for (genvar m = 0; m < MergeMshrNum; m++) begin : gen_merge_mshr_entry
          localparam int unsigned ValidIdx = (p_i * MergeMshrNum) + m;
          assign merge_mshr_q_valid[g][p_i][m] = merge_mshr_q[g][p_i][m].valid;
          assign merge_mshr_q_valid_flat[g][ValidIdx] = merge_mshr_q_valid[g][p_i][m];
          for (genvar r = 0; r < MergeReqsPerMshr; r++) begin : gen_merge_mshr_req_count
            assign merge_mshr_q_req_count_more_than_x[r][g][p_i][m] =
                (merge_mshr_q[g][p_i][m].valid && (merge_mshr_q[g][p_i][m].req_count > r)) ? 1'b1 : 1'b0;
            assign merge_mshr_q_req_count_x[r][g][p_i][m] =
                (merge_mshr_q[g][p_i][m].valid && (merge_mshr_q[g][p_i][m].req_count == (r+1))) ? 1'b1 : 1'b0;
          end
          for (genvar rc = 0; rc < MergeRecordsPerMshr; rc++) begin : gen_merge_mshr_record_count
            assign merge_mshr_q_record_count_more_than_x[rc][g][p_i][m] =
                (merge_mshr_q[g][p_i][m].valid && (merge_mshr_q[g][p_i][m].record_count > rc)) ? 1'b1 : 1'b0;
            assign merge_mshr_q_record_count_x[rc][g][p_i][m] =
                (merge_mshr_q[g][p_i][m].valid && (merge_mshr_q[g][p_i][m].record_count == (rc+1))) ? 1'b1 : 1'b0;
          end
        end
      end
    end
  endgenerate

  generate
    for(genvar g = 0; g < NumGroups; g++) begin : gen_merge_mshr_valid_count_group
      for (genvar m = 0; m < MergeMshrTotal; m++) begin : gen_merge_mshr_valid_count_thresh
        assign merge_mshr_q_valid_count_more_than_x[m][g] =
            ($countones(merge_mshr_q_valid_flat[g]) > m) ? 1'b1 : 1'b0;
        assign merge_mshr_q_valid_count_x[m][g] =
            ($countones(merge_mshr_q_valid_flat[g]) == (m+1)) ? 1'b1 : 1'b0;
      end
    end
  endgenerate

  int unsigned merge_total_reqs;
  int unsigned merge_total_reqs_load;
  int unsigned merge_total_reqs_store;
  int unsigned merge_total_merge_hits;
  int unsigned merge_total_merge_overflow;
  int unsigned merge_total_mshr_alloc;
  int unsigned merge_total_mshr_no_free;
  int unsigned merge_total_mshr_closed;
  int unsigned merge_total_reqs_closed;
  int unsigned merge_total_records_closed;
  int unsigned merge_max_reqs_per_mshr;
  int unsigned merge_max_records_per_mshr;
  int unsigned merge_max_active_mshr[NumGroups-1:0];
  int unsigned merge_max_active_mshr_global;
  longint unsigned merge_valid_entry_cycles;
  longint unsigned merge_req_count_cycles;
  longint unsigned merge_record_count_cycles;
  longint unsigned merge_expired_req_sum;
  longint unsigned merge_expired_record_sum;
  longint unsigned merge_expired_unique_tile_sum;

  int unsigned merge_group_total_reqs[NumGroups-1:0];
  int unsigned merge_group_total_reqs_load[NumGroups-1:0];
  int unsigned merge_group_total_reqs_store[NumGroups-1:0];
  int unsigned merge_group_merge_hits[NumGroups-1:0];
  int unsigned merge_group_mshr_alloc[NumGroups-1:0];
  int unsigned merge_group_mshr_no_free[NumGroups-1:0];
  longint unsigned merge_group_valid_entry_cycles[NumGroups-1:0];
  longint unsigned merge_group_req_count_cycles[NumGroups-1:0];
  longint unsigned merge_group_record_count_cycles[NumGroups-1:0];
  longint unsigned merge_group_mshr_closed[NumGroups-1:0];
  longint unsigned merge_group_expired_req_sum[NumGroups-1:0];
  longint unsigned merge_group_expired_record_sum[NumGroups-1:0];
  longint unsigned merge_group_expired_unique_tile_sum[NumGroups-1:0];

  string merge_log_path;
  int    merge_log_fd;
  int    merge_log_retval;

  logic merge_dumped;

  // Per-port request capture from group wrapper.
  logic      [NumX-1:0][NumY-1:0][NumRemoteReqPortsPerTile-2:0][NumTilesPerGroup-1:0] merge_req_valid;
  logic      [NumX-1:0][NumY-1:0][NumRemoteReqPortsPerTile-2:0][NumTilesPerGroup-1:0] merge_req_ready;
  tcdm_addr_t[NumX-1:0][NumY-1:0][NumRemoteReqPortsPerTile-2:0][NumTilesPerGroup-1:0] merge_req_addr;
  logic      [NumX-1:0][NumY-1:0][NumRemoteReqPortsPerTile-2:0][NumTilesPerGroup-1:0] merge_req_wen;

  generate
    for (genvar x_dim = 0; x_dim < NumX; x_dim++) begin : gen_merge_x
      for (genvar y_dim = 0; y_dim < NumY; y_dim++) begin : gen_merge_y
        for (genvar p = 0; p < (NumRemoteReqPortsPerTile - 1); p++) begin : gen_merge_port
          for (genvar t_i = 0; t_i < NumTilesPerGroup; t_i++) begin : gen_merge_tile
            if (PostLayoutGr) begin : gen_merge_postlayout
              assign merge_req_valid[x_dim][y_dim][p][t_i] =
                  dut.i_mempool_cluster
                    .gen_groups_x[x_dim]
                    .gen_groups_y[y_dim]
                    .gen_postly_group
                    .i_group
                    .i_mempool_group
                    .tcdm_master_req_valid_o[t_i][p + 1];

              assign merge_req_ready[x_dim][y_dim][p][t_i] =
                  dut.i_mempool_cluster
                    .gen_groups_x[x_dim]
                    .gen_groups_y[y_dim]
                    .gen_postly_group
                    .i_group
                    .i_mempool_group
                    .tcdm_master_req_ready_i[t_i][p + 1];

              assign merge_req_addr[x_dim][y_dim][p][t_i] =
                  dut.i_mempool_cluster
                    .gen_groups_x[x_dim]
                    .gen_groups_y[y_dim]
                    .gen_postly_group
                    .i_group
                    .i_mempool_group
                    .tcdm_master_req_o[t_i][p + 1]
                    .tgt_addr;

              assign merge_req_wen[x_dim][y_dim][p][t_i] =
                  dut.i_mempool_cluster
                    .gen_groups_x[x_dim]
                    .gen_groups_y[y_dim]
                    .gen_postly_group
                    .i_group
                    .i_mempool_group
                    .tcdm_master_req_o[t_i][p + 1]
                    .wen;

            end else begin : gen_merge_rtl
              assign merge_req_valid[x_dim][y_dim][p][t_i] =
                  dut.i_mempool_cluster
                    .gen_groups_x[x_dim]
                    .gen_groups_y[y_dim]
                    .gen_rtl_group
                    .i_group
                    .i_mempool_group
                    .tcdm_master_req_valid_o[t_i][p + 1];

              assign merge_req_ready[x_dim][y_dim][p][t_i] =
                  dut.i_mempool_cluster
                    .gen_groups_x[x_dim]
                    .gen_groups_y[y_dim]
                    .gen_rtl_group
                    .i_group
                    .i_mempool_group
                    .tcdm_master_req_ready_i[t_i][p + 1];

              assign merge_req_addr[x_dim][y_dim][p][t_i] =
                  dut.i_mempool_cluster
                    .gen_groups_x[x_dim]
                    .gen_groups_y[y_dim]
                    .gen_rtl_group
                    .i_group
                    .i_mempool_group
                    .tcdm_master_req_o[t_i][p + 1]
                    .tgt_addr;

              assign merge_req_wen[x_dim][y_dim][p][t_i] =
                  dut.i_mempool_cluster
                    .gen_groups_x[x_dim]
                    .gen_groups_y[y_dim]
                    .gen_rtl_group
                    .i_group
                    .i_mempool_group
                    .tcdm_master_req_o[t_i][p + 1]
                    .wen;
            end
          end
        end
      end
    end
  endgenerate

  task automatic dump_group_merge_util(int fd, string reason);
    longint unsigned total_entry_cycles;
    real avg_req_cycle;
    real avg_rec_cycle;
    real avg_req_expired;
    real avg_rec_expired;
    real avg_tile_expired;
    begin
      total_entry_cycles = merge_cycle_q * MergeMshrTotal * NumGroups;
      avg_req_cycle = (total_entry_cycles == 0) ? 0.0 :
          (merge_req_count_cycles * 1.0) / (total_entry_cycles * 1.0);
      avg_rec_cycle = (total_entry_cycles == 0) ? 0.0 :
          (merge_record_count_cycles * 1.0) / (total_entry_cycles * 1.0);
      avg_req_expired = (merge_total_mshr_closed == 0) ? 0.0 :
          (merge_expired_req_sum * 1.0) / (merge_total_mshr_closed * 1.0);
      avg_rec_expired = (merge_total_mshr_closed == 0) ? 0.0 :
          (merge_expired_record_sum * 1.0) / (merge_total_mshr_closed * 1.0);
      avg_tile_expired = (merge_total_mshr_closed == 0) ? 0.0 :
          (merge_expired_unique_tile_sum * 1.0) / (merge_total_mshr_closed * 1.0);

      if (fd != 0) begin
        $fwrite(fd,
                "util %s avg_req_cycle=%.3f avg_record_cycle=%.3f avg_req_expired=%.3f avg_record_expired=%.3f avg_unique_tile_expired=%.3f\n",
                reason, avg_req_cycle, avg_rec_cycle, avg_req_expired, avg_rec_expired, avg_tile_expired);
        for (int g = 0; g < NumGroups; g++) begin
          longint unsigned group_entry_cycles;
          real group_avg_req_cycle;
          real group_avg_rec_cycle;
          real group_avg_req_expired;
          real group_avg_rec_expired;
          real group_avg_tile_expired;

          group_entry_cycles = merge_cycle_q * MergeMshrTotal;
          group_avg_req_cycle = (group_entry_cycles == 0) ? 0.0 :
              (merge_group_req_count_cycles[g] * 1.0) / (group_entry_cycles * 1.0);
          group_avg_rec_cycle = (group_entry_cycles == 0) ? 0.0 :
              (merge_group_record_count_cycles[g] * 1.0) / (group_entry_cycles * 1.0);
          group_avg_req_expired = (merge_group_mshr_closed[g] == 0) ? 0.0 :
              (merge_group_expired_req_sum[g] * 1.0) / (merge_group_mshr_closed[g] * 1.0);
          group_avg_rec_expired = (merge_group_mshr_closed[g] == 0) ? 0.0 :
              (merge_group_expired_record_sum[g] * 1.0) / (merge_group_mshr_closed[g] * 1.0);
          group_avg_tile_expired = (merge_group_mshr_closed[g] == 0) ? 0.0 :
              (merge_group_expired_unique_tile_sum[g] * 1.0) / (merge_group_mshr_closed[g] * 1.0);

          $fwrite(fd,
                  "util group %0d avg_req_cycle=%.3f avg_record_cycle=%.3f avg_req_expired=%.3f avg_record_expired=%.3f avg_unique_tile_expired=%.3f\n",
                  g, group_avg_req_cycle, group_avg_rec_cycle,
                  group_avg_req_expired, group_avg_rec_expired, group_avg_tile_expired);
        end
      end
    end
  endtask

  task automatic dump_group_merge_stats(string reason);
    begin
      if (merge_log_fd != 0) begin
        dump_group_merge_stats_fd(merge_log_fd, reason);
        $fflush(merge_log_fd);
      end else begin
        int unsigned total_reqs_after_merge;
        real total_merge_eff;
        total_reqs_after_merge = merge_total_reqs - merge_total_merge_hits;
        total_merge_eff = (merge_total_reqs == 0) ? 0.0 :
            (total_reqs_after_merge * 1.0) / (merge_total_reqs * 1.0);
        $display("[GroupMerge] %s: reqs=%0d reqs_after_merge=%0d merge_eff=%.3f reqs_load=%0d reqs_store=%0d merge_hits=%0d merge_overflow=%0d mshr_alloc=%0d mshr_no_free=%0d",
                 reason, merge_total_reqs, total_reqs_after_merge, total_merge_eff,
                 merge_total_reqs_load, merge_total_reqs_store,
                 merge_total_merge_hits, merge_total_merge_overflow,
                 merge_total_mshr_alloc, merge_total_mshr_no_free);
      end
    end
  endtask

  task automatic dump_group_merge_stats_fd(int fd, string reason);
    int unsigned active_mshr;
    int unsigned active_reqs;
    int unsigned active_records;
    int unsigned total_reqs_after_merge;
    real avg_reqs_per_mshr;
    real avg_records_per_mshr;
    real total_merge_eff;
    begin
      active_mshr = 0;
      active_reqs = 0;
      active_records = 0;
      for (int g = 0; g < NumGroups; g++) begin
        for (int p_i = 0; p_i < MergeMshrPools; p_i++) begin
          for (int m = 0; m < MergeMshrNum; m++) begin
            if (merge_mshr_q[g][p_i][m].valid) begin
              active_mshr++;
              active_reqs += merge_mshr_q[g][p_i][m].req_count;
              active_records += merge_mshr_q[g][p_i][m].record_count;
            end
          end
        end
      end

      avg_reqs_per_mshr = (merge_total_mshr_closed == 0) ? 0.0 :
          (merge_total_reqs_closed * 1.0) / (merge_total_mshr_closed * 1.0);
      avg_records_per_mshr = (merge_total_mshr_closed == 0) ? 0.0 :
          (merge_total_records_closed * 1.0) / (merge_total_mshr_closed * 1.0);
      total_reqs_after_merge = merge_total_reqs - merge_total_merge_hits;
      total_merge_eff = (merge_total_reqs == 0) ? 0.0 :
          (total_reqs_after_merge * 1.0) / (merge_total_reqs * 1.0);

      if (fd != 0) begin
        $fwrite(fd, "group_merge_profile %s\n", reason);
        $fwrite(fd,
                "cfg burst_words=%0d window_cycles=%0d mshr_num=%0d records_per_mshr=%0d reqs_per_mshr=%0d analyze_mode=%0d separate_mshr=%0d\n",
                MergeBurstWords, MergeWindowCycles, MergeMshrNum, MergeRecordsPerMshr, MergeReqsPerMshr,
                MergeAnalyzeMode, MergeSeparateMshr);
        $fwrite(fd,
                "totals reqs=%0d reqs_after_merge=%0d merge_eff=%.3f reqs_load=%0d reqs_store=%0d merge_hits=%0d merge_overflow=%0d mshr_alloc=%0d mshr_no_free=%0d\n",
                merge_total_reqs, total_reqs_after_merge, total_merge_eff,
                merge_total_reqs_load, merge_total_reqs_store,
                merge_total_merge_hits, merge_total_merge_overflow,
                merge_total_mshr_alloc, merge_total_mshr_no_free);
        $fwrite(fd,
                "closed mshr=%0d avg_reqs_per_mshr=%.2f avg_records_per_mshr=%.2f max_reqs_per_mshr=%0d max_records_per_mshr=%0d\n",
                merge_total_mshr_closed, avg_reqs_per_mshr, avg_records_per_mshr,
                merge_max_reqs_per_mshr, merge_max_records_per_mshr);
        $fwrite(fd,
                "active mshr=%0d active_reqs=%0d active_records=%0d max_active_global=%0d\n",
                active_mshr, active_reqs, active_records, merge_max_active_mshr_global);
        for (int g = 0; g < NumGroups; g++) begin
          int unsigned group_reqs_after_merge;
          real group_merge_eff;
          group_reqs_after_merge = merge_group_total_reqs[g] - merge_group_merge_hits[g];
          group_merge_eff = (merge_group_total_reqs[g] == 0) ? 0.0 :
              (group_reqs_after_merge * 1.0) / (merge_group_total_reqs[g] * 1.0);
          $fwrite(fd,
                  "group %0d reqs=%0d reqs_after_merge=%0d merge_eff=%.3f reqs_load=%0d reqs_store=%0d merge_hits=%0d mshr_alloc=%0d mshr_no_free=%0d max_active=%0d\n",
                  g,
                  merge_group_total_reqs[g],
                  group_reqs_after_merge,
                  group_merge_eff,
                  merge_group_total_reqs_load[g],
                  merge_group_total_reqs_store[g],
                  merge_group_merge_hits[g],
                  merge_group_mshr_alloc[g],
                  merge_group_mshr_no_free[g],
                  merge_max_active_mshr[g]);
        end
        dump_group_merge_util(fd, reason);
      end
    end
  endtask

  initial begin
    merge_log_path = "group_merge_profiling";
    merge_log_retval = $system({"mkdir -p ", merge_log_path});
    merge_log_fd = $fopen($sformatf("%s/group_merge_profile.log", merge_log_path), "w");
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      merge_cycle_q <= '0;
      merge_total_reqs <= '0;
      merge_total_reqs_load <= '0;
      merge_total_reqs_store <= '0;
      merge_total_merge_hits <= '0;
      merge_total_merge_overflow <= '0;
      merge_total_mshr_alloc <= '0;
      merge_total_mshr_no_free <= '0;
      merge_total_mshr_closed <= '0;
      merge_total_reqs_closed <= '0;
      merge_total_records_closed <= '0;
      merge_max_reqs_per_mshr <= '0;
      merge_max_records_per_mshr <= '0;
      merge_max_active_mshr_global <= '0;
      merge_valid_entry_cycles <= '0;
      merge_req_count_cycles <= '0;
      merge_record_count_cycles <= '0;
      merge_expired_req_sum <= '0;
      merge_expired_record_sum <= '0;
      merge_expired_unique_tile_sum <= '0;
      merge_dumped <= 1'b0;
      for (int g = 0; g < NumGroups; g++) begin
        merge_max_active_mshr[g] <= '0;
        merge_group_total_reqs[g] <= '0;
        merge_group_total_reqs_load[g] <= '0;
        merge_group_total_reqs_store[g] <= '0;
        merge_group_merge_hits[g] <= '0;
        merge_group_mshr_alloc[g] <= '0;
        merge_group_mshr_no_free[g] <= '0;
        merge_group_valid_entry_cycles[g] <= '0;
        merge_group_req_count_cycles[g] <= '0;
        merge_group_record_count_cycles[g] <= '0;
        merge_group_mshr_closed[g] <= '0;
        merge_group_expired_req_sum[g] <= '0;
        merge_group_expired_record_sum[g] <= '0;
        merge_group_expired_unique_tile_sum[g] <= '0;
        for (int p_i = 0; p_i < MergeMshrPools; p_i++) begin
          for (int m = 0; m < MergeMshrNum; m++) begin
            merge_mshr_q[g][p_i][m].valid <= 1'b0;
            merge_mshr_q[g][p_i][m].wen <= 1'b0;
            merge_mshr_q[g][p_i][m].burst_base_addr <= '0;
            merge_mshr_q[g][p_i][m].word_mask <= '0;
            merge_mshr_q[g][p_i][m].req_count <= '0;
            merge_mshr_q[g][p_i][m].record_count <= '0;
            merge_mshr_q[g][p_i][m].req_tile_id <= '{default: '0};
            merge_mshr_q[g][p_i][m].req_tile_id_valid <= '0;
            merge_mshr_q[g][p_i][m].start_cycle <= '0;
            merge_mshr_q[g][p_i][m].last_cycle <= '0;
          end
        end
      end
    end else begin
      int unsigned cycle_reqs;
      int unsigned cycle_reqs_load;
      int unsigned cycle_reqs_store;
      int unsigned cycle_merge_hits;
      int unsigned cycle_merge_overflow;
      int unsigned cycle_mshr_alloc;
      int unsigned cycle_mshr_no_free;
      int unsigned cycle_mshr_closed;
      int unsigned cycle_reqs_closed;
      int unsigned cycle_records_closed;
      int unsigned max_reqs_seen;
      int unsigned max_records_seen;
      int unsigned max_active_global;
      int unsigned cycle_valid_entries_total;
      int unsigned cycle_req_sum_total;
      int unsigned cycle_record_sum_total;
      int unsigned cycle_expired_req_sum;
      int unsigned cycle_expired_record_sum;
      int unsigned cycle_expired_unique_tile_sum;
      int unsigned group_reqs_inc[NumGroups-1:0];
      int unsigned group_reqs_load_inc[NumGroups-1:0];
      int unsigned group_reqs_store_inc[NumGroups-1:0];
      int unsigned group_valid_entries_inc[NumGroups-1:0];
      int unsigned group_req_sum_inc[NumGroups-1:0];
      int unsigned group_record_sum_inc[NumGroups-1:0];
      int unsigned group_mshr_closed_inc[NumGroups-1:0];
      int unsigned group_expired_req_sum_inc[NumGroups-1:0];
      int unsigned group_expired_record_sum_inc[NumGroups-1:0];
      int unsigned group_expired_unique_tile_sum_inc[NumGroups-1:0];
      int unsigned group_merge_hits_inc[NumGroups-1:0];
      int unsigned group_mshr_alloc_inc[NumGroups-1:0];
      int unsigned group_mshr_no_free_inc[NumGroups-1:0];
      int util_fd;
      string util_fn;
      string util_reason;

      merge_cycle_q <= merge_cycle_q + 64'd1;

      cycle_reqs = 0;
      cycle_reqs_load = 0;
      cycle_reqs_store = 0;
      cycle_merge_hits = 0;
      cycle_merge_overflow = 0;
      cycle_mshr_alloc = 0;
      cycle_mshr_no_free = 0;
      cycle_mshr_closed = 0;
      cycle_reqs_closed = 0;
      cycle_records_closed = 0;
      max_reqs_seen = merge_max_reqs_per_mshr;
      max_records_seen = merge_max_records_per_mshr;
      max_active_global = merge_max_active_mshr_global;
      cycle_valid_entries_total = 0;
      cycle_req_sum_total = 0;
      cycle_record_sum_total = 0;
      cycle_expired_req_sum = 0;
      cycle_expired_record_sum = 0;
      cycle_expired_unique_tile_sum = 0;
      for (int g = 0; g < NumGroups; g++) begin
        group_reqs_inc[g] = 0;
        group_reqs_load_inc[g] = 0;
        group_reqs_store_inc[g] = 0;
        group_valid_entries_inc[g] = 0;
        group_req_sum_inc[g] = 0;
        group_record_sum_inc[g] = 0;
        group_mshr_closed_inc[g] = 0;
        group_expired_req_sum_inc[g] = 0;
        group_expired_record_sum_inc[g] = 0;
        group_expired_unique_tile_sum_inc[g] = 0;
        group_merge_hits_inc[g] = 0;
        group_mshr_alloc_inc[g] = 0;
        group_mshr_no_free_inc[g] = 0;
      end

      merge_mshr_shadow = merge_mshr_q;

      // Expire MSHR entries whose merge window has elapsed.
      for (int g = 0; g < NumGroups; g++) begin
        for (int p_i = 0; p_i < MergeMshrPools; p_i++) begin
          for (int m = 0; m < MergeMshrNum; m++) begin
            if (merge_mshr_shadow[g][p_i][m].valid &&
                (merge_cycle_q - merge_mshr_shadow[g][p_i][m].start_cycle) >= MergeWindowCycles) begin
              int unsigned unique_tile_count;
              logic [NumTilesPerGroup-1:0] tile_seen;

              tile_seen = '0;
              for (int t_idx = 0; t_idx < MergeReqsPerMshr; t_idx++) begin
                if (merge_mshr_shadow[g][p_i][m].req_tile_id_valid[t_idx]) begin
                  tile_seen[merge_mshr_shadow[g][p_i][m].req_tile_id[t_idx]] = 1'b1;
                end
              end
              unique_tile_count = $countones(tile_seen);

              cycle_mshr_closed++;
              cycle_reqs_closed += merge_mshr_shadow[g][p_i][m].req_count;
              cycle_records_closed += merge_mshr_shadow[g][p_i][m].record_count;
              cycle_expired_req_sum += merge_mshr_shadow[g][p_i][m].req_count;
              cycle_expired_record_sum += merge_mshr_shadow[g][p_i][m].record_count;
              cycle_expired_unique_tile_sum += unique_tile_count;
              group_mshr_closed_inc[g]++;
              group_expired_req_sum_inc[g] += merge_mshr_shadow[g][p_i][m].req_count;
              group_expired_record_sum_inc[g] += merge_mshr_shadow[g][p_i][m].record_count;
              group_expired_unique_tile_sum_inc[g] += unique_tile_count;
              if (merge_mshr_shadow[g][p_i][m].req_count > max_reqs_seen) begin
                max_reqs_seen = merge_mshr_shadow[g][p_i][m].req_count;
              end
              if (merge_mshr_shadow[g][p_i][m].record_count > max_records_seen) begin
                max_records_seen = merge_mshr_shadow[g][p_i][m].record_count;
              end
              merge_mshr_shadow[g][p_i][m].valid = 1'b0;
              merge_mshr_shadow[g][p_i][m].req_tile_id_valid = '0;
              merge_mshr_shadow[g][p_i][m].req_tile_id = '{default: '0};
            end
          end
        end
      end

      // Process incoming requests and model merge behavior.
      for (int g = 0; g < NumGroups; g++) begin
        int x_dim;
        int y_dim;
        x_dim = g / NumY;
        y_dim = g % NumY;
        for (int p = 0; p < (NumRemoteReqPortsPerTile - 1); p++) begin
          for (int t_i = 0; t_i < NumTilesPerGroup; t_i++) begin
            if (merge_req_valid[x_dim][y_dim][p][t_i] &&
                merge_req_ready[x_dim][y_dim][p][t_i]) begin
              int match_idx;
              int empty_idx;
              longint unsigned req_addr_int;
              int unsigned req_offset;
              tcdm_addr_t req_addr;
              tcdm_addr_t req_burst_base;
              logic req_wen;
              logic analyze_req;
              int pool_idx;
              tile_group_id_t req_tile_id;

              req_addr = merge_req_addr[x_dim][y_dim][p][t_i];
              req_wen = merge_req_wen[x_dim][y_dim][p][t_i];
              req_tile_id = tile_group_id_t'(t_i);
              analyze_req = req_wen ? MergeAnalyzeStore : MergeAnalyzeLoad;
              req_addr_int = req_addr;
              req_offset = (MergeBurstWords == 0) ? 0 : (req_addr_int % MergeBurstWords);
              req_burst_base = tcdm_addr_t'(req_addr_int - req_offset);

              if (analyze_req) begin
                cycle_reqs++;
                group_reqs_inc[g]++;
                if (req_wen) begin
                  cycle_reqs_store++;
                  group_reqs_store_inc[g]++;
                end else begin
                  cycle_reqs_load++;
                  group_reqs_load_inc[g]++;
                end

                pool_idx = MergeSeparateMshr ? (req_wen ? 1 : 0) : 0;
                match_idx = -1;
                empty_idx = -1;
                for (int m = 0; m < MergeMshrNum; m++) begin
                  if (merge_mshr_shadow[g][pool_idx][m].valid) begin
                    if ((merge_mshr_shadow[g][pool_idx][m].burst_base_addr == req_burst_base) &&
                        (merge_mshr_shadow[g][pool_idx][m].wen == req_wen) &&
                        (match_idx < 0)) begin
                      match_idx = m;
                    end
                  end else if (empty_idx < 0) begin
                    empty_idx = m;
                  end
                end

                if (match_idx >= 0) begin
                  logic offset_hit;
                  int unsigned req_count;
                  int unsigned record_count;

                  req_count = merge_mshr_shadow[g][pool_idx][match_idx].req_count;
                  record_count = merge_mshr_shadow[g][pool_idx][match_idx].record_count;
                  offset_hit = merge_mshr_shadow[g][pool_idx][match_idx].word_mask[req_offset];

                  if ((req_count < MergeReqsPerMshr) &&
                      (offset_hit || (record_count < MergeRecordLimit))) begin
                    cycle_merge_hits++;
                    group_merge_hits_inc[g]++;
                    merge_mshr_shadow[g][pool_idx][match_idx].req_tile_id_valid[req_count] = 1'b1;
                    merge_mshr_shadow[g][pool_idx][match_idx].req_tile_id[req_count] = req_tile_id;
                    merge_mshr_shadow[g][pool_idx][match_idx].req_count = req_count + 1;
                    if (!offset_hit) begin
                      merge_mshr_shadow[g][pool_idx][match_idx].word_mask[req_offset] = 1'b1;
                      merge_mshr_shadow[g][pool_idx][match_idx].record_count = record_count + 1;
                    end
                    merge_mshr_shadow[g][pool_idx][match_idx].last_cycle = merge_cycle_q;
                    if (merge_mshr_shadow[g][pool_idx][match_idx].req_count > max_reqs_seen) begin
                      max_reqs_seen = merge_mshr_shadow[g][pool_idx][match_idx].req_count;
                    end
                    if (merge_mshr_shadow[g][pool_idx][match_idx].record_count > max_records_seen) begin
                      max_records_seen = merge_mshr_shadow[g][pool_idx][match_idx].record_count;
                    end
                  end else begin
                    cycle_merge_overflow++;
                    if (empty_idx >= 0) begin
                      cycle_mshr_alloc++;
                      group_mshr_alloc_inc[g]++;
                      merge_mshr_shadow[g][pool_idx][empty_idx].valid = 1'b1;
                      merge_mshr_shadow[g][pool_idx][empty_idx].wen = req_wen;
                      merge_mshr_shadow[g][pool_idx][empty_idx].burst_base_addr = req_burst_base;
                      merge_mshr_shadow[g][pool_idx][empty_idx].word_mask = '0;
                      merge_mshr_shadow[g][pool_idx][empty_idx].word_mask[req_offset] = 1'b1;
                      merge_mshr_shadow[g][pool_idx][empty_idx].req_count = 1;
                      merge_mshr_shadow[g][pool_idx][empty_idx].record_count = 1;
                      merge_mshr_shadow[g][pool_idx][empty_idx].req_tile_id = '{default: '0};
                      merge_mshr_shadow[g][pool_idx][empty_idx].req_tile_id_valid = '0;
                      merge_mshr_shadow[g][pool_idx][empty_idx].req_tile_id_valid[0] = 1'b1;
                      merge_mshr_shadow[g][pool_idx][empty_idx].req_tile_id[0] = req_tile_id;
                      merge_mshr_shadow[g][pool_idx][empty_idx].start_cycle = merge_cycle_q;
                      merge_mshr_shadow[g][pool_idx][empty_idx].last_cycle = merge_cycle_q;
                    end else begin
                      cycle_mshr_no_free++;
                      group_mshr_no_free_inc[g]++;
                    end
                  end
                end else begin
                  if (empty_idx >= 0) begin
                    cycle_mshr_alloc++;
                    group_mshr_alloc_inc[g]++;
                    merge_mshr_shadow[g][pool_idx][empty_idx].valid = 1'b1;
                    merge_mshr_shadow[g][pool_idx][empty_idx].wen = req_wen;
                    merge_mshr_shadow[g][pool_idx][empty_idx].burst_base_addr = req_burst_base;
                    merge_mshr_shadow[g][pool_idx][empty_idx].word_mask = '0;
                    merge_mshr_shadow[g][pool_idx][empty_idx].word_mask[req_offset] = 1'b1;
                    merge_mshr_shadow[g][pool_idx][empty_idx].req_count = 1;
                    merge_mshr_shadow[g][pool_idx][empty_idx].record_count = 1;
                    merge_mshr_shadow[g][pool_idx][empty_idx].req_tile_id = '{default: '0};
                    merge_mshr_shadow[g][pool_idx][empty_idx].req_tile_id_valid = '0;
                    merge_mshr_shadow[g][pool_idx][empty_idx].req_tile_id_valid[0] = 1'b1;
                    merge_mshr_shadow[g][pool_idx][empty_idx].req_tile_id[0] = req_tile_id;
                    merge_mshr_shadow[g][pool_idx][empty_idx].start_cycle = merge_cycle_q;
                    merge_mshr_shadow[g][pool_idx][empty_idx].last_cycle = merge_cycle_q;
                  end else begin
                    cycle_mshr_no_free++;
                    group_mshr_no_free_inc[g]++;
                  end
                end
              end
            end
          end
        end
      end

      for (int g = 0; g < NumGroups; g++) begin
        int unsigned active_count;
        int unsigned group_valid_entries;
        int unsigned group_req_sum;
        int unsigned group_record_sum;
        active_count = 0;
        group_valid_entries = 0;
        group_req_sum = 0;
        group_record_sum = 0;
        for (int p_i = 0; p_i < MergeMshrPools; p_i++) begin
          for (int m = 0; m < MergeMshrNum; m++) begin
            if (merge_mshr_shadow[g][p_i][m].valid) begin
              active_count++;
              group_valid_entries++;
              group_req_sum += merge_mshr_shadow[g][p_i][m].req_count;
              group_record_sum += merge_mshr_shadow[g][p_i][m].record_count;
              if (merge_mshr_shadow[g][p_i][m].req_count > max_reqs_seen) begin
                max_reqs_seen = merge_mshr_shadow[g][p_i][m].req_count;
              end
              if (merge_mshr_shadow[g][p_i][m].record_count > max_records_seen) begin
                max_records_seen = merge_mshr_shadow[g][p_i][m].record_count;
              end
            end
          end
        end
        if (active_count > merge_max_active_mshr[g]) begin
          merge_max_active_mshr[g] <= active_count;
        end
        if (active_count > max_active_global) begin
          max_active_global = active_count;
        end
        group_valid_entries_inc[g] = group_valid_entries;
        group_req_sum_inc[g] = group_req_sum;
        group_record_sum_inc[g] = group_record_sum;
        cycle_valid_entries_total += group_valid_entries;
        cycle_req_sum_total += group_req_sum;
        cycle_record_sum_total += group_record_sum;
        merge_group_total_reqs[g] <= merge_group_total_reqs[g] + group_reqs_inc[g];
        merge_group_total_reqs_load[g] <= merge_group_total_reqs_load[g] + group_reqs_load_inc[g];
        merge_group_total_reqs_store[g] <= merge_group_total_reqs_store[g] + group_reqs_store_inc[g];
        merge_group_merge_hits[g] <= merge_group_merge_hits[g] + group_merge_hits_inc[g];
        merge_group_mshr_alloc[g] <= merge_group_mshr_alloc[g] + group_mshr_alloc_inc[g];
        merge_group_mshr_no_free[g] <= merge_group_mshr_no_free[g] + group_mshr_no_free_inc[g];
        merge_group_valid_entry_cycles[g] <= merge_group_valid_entry_cycles[g] + group_valid_entries_inc[g];
        merge_group_req_count_cycles[g] <= merge_group_req_count_cycles[g] + group_req_sum_inc[g];
        merge_group_record_count_cycles[g] <= merge_group_record_count_cycles[g] + group_record_sum_inc[g];
        merge_group_mshr_closed[g] <= merge_group_mshr_closed[g] + group_mshr_closed_inc[g];
        merge_group_expired_req_sum[g] <= merge_group_expired_req_sum[g] + group_expired_req_sum_inc[g];
        merge_group_expired_record_sum[g] <= merge_group_expired_record_sum[g] + group_expired_record_sum_inc[g];
        merge_group_expired_unique_tile_sum[g] <=
            merge_group_expired_unique_tile_sum[g] + group_expired_unique_tile_sum_inc[g];
      end

      merge_mshr_q <= merge_mshr_shadow;
      merge_valid_entry_cycles <= merge_valid_entry_cycles + cycle_valid_entries_total;
      merge_req_count_cycles <= merge_req_count_cycles + cycle_req_sum_total;
      merge_record_count_cycles <= merge_record_count_cycles + cycle_record_sum_total;
      merge_total_reqs <= merge_total_reqs + cycle_reqs;
      merge_total_reqs_load <= merge_total_reqs_load + cycle_reqs_load;
      merge_total_reqs_store <= merge_total_reqs_store + cycle_reqs_store;
      merge_total_merge_hits <= merge_total_merge_hits + cycle_merge_hits;
      merge_total_merge_overflow <= merge_total_merge_overflow + cycle_merge_overflow;
      merge_total_mshr_alloc <= merge_total_mshr_alloc + cycle_mshr_alloc;
      merge_total_mshr_no_free <= merge_total_mshr_no_free + cycle_mshr_no_free;
      merge_total_mshr_closed <= merge_total_mshr_closed + cycle_mshr_closed;
      merge_total_reqs_closed <= merge_total_reqs_closed + cycle_reqs_closed;
      merge_total_records_closed <= merge_total_records_closed + cycle_records_closed;
      merge_expired_req_sum <= merge_expired_req_sum + cycle_expired_req_sum;
      merge_expired_record_sum <= merge_expired_record_sum + cycle_expired_record_sum;
      merge_expired_unique_tile_sum <= merge_expired_unique_tile_sum + cycle_expired_unique_tile_sum;
      merge_max_reqs_per_mshr <= max_reqs_seen;
      merge_max_records_per_mshr <= max_records_seen;
      merge_max_active_mshr_global <= max_active_global;

      if ((MergeUtilDumpCycles != 0) &&
          (merge_cycle_q != 0) &&
          (
              ((merge_cycle_q % MergeUtilDumpCycles) == 0) ||
              (merge_cycle_q == 5000)
            )
          ) begin
        $sformat(util_fn, "%s/group_merge_util_%0d.log", merge_log_path, merge_cycle_q);
        util_fd = $fopen(util_fn, "w");
        if (util_fd != 0) begin
          $sformat(util_reason, "cycle_%0d", merge_cycle_q);
          dump_group_merge_stats_fd(util_fd, util_reason);
          $fclose(util_fd);
        end
      end

      if (eoc_valid && !merge_dumped) begin
        merge_dumped <= 1'b1;
        dump_group_merge_stats("eoc");
      end
    end
  end

  final begin
    if (!merge_dumped) begin
      dump_group_merge_stats("final");
    end
    if (merge_log_fd != 0) begin
      $fclose(merge_log_fd);
    end
  end

`endif
`endif
`endif

`endif
