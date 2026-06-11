// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// SPM bank-activity time-series trace (enabled by SPM_PROFILING).
//
// One lightweight log per tile (spm_profiling/bank_g<g>_t<t>.log) covering all
// its banks. Taps the post-arbitration bank grant + winning request payload, so
// it shows per-bank idle/stall/read/write over time AND which core won each bank
// cycle (explains tile slave_req-in stalls from bank contention).
//   S <bank> <start> <end> <state>   state 0=idle 1=stall 2=read 3=write
//   P <bank> <cycle> <wen> <tgt_addr(hex)> <loc> <wide> <port> <src_grp> <src_tile> <src_core> <meta_id>
//       loc=1 iff winning input port is local; wide=1 = DMA. Local requests zero
//       their src_{grp,tile,core} payload fields, so use port for local accesses;
//       remote accesses carry the true NoC origin in src_{grp,tile,core}.
//
// The old per-cycle bank-conflict counters and heavy per-word profiler
// (dbg_profile_q, mirroring mempool_tile.profile_d) are commented out at the
// bottom -- their unbounded dynamic cycle lists balloon VCS memory. mempool_tile's
// matching profile_d is likewise commented out (under its SPM_PROFILING gate).
// Relies on cycle_q (declared in tb_noc_profiling.svh, included first).

`ifndef TB_SPM_PROFILING_SVH_
`define TB_SPM_PROFILING_SVH_

`ifndef TARGET_SYNTHESIS
`ifndef TARGET_VERILATOR
`ifdef SPM_PROFILING

  // Hierarchical path to group g, tile t's i_tile. Defined locally because
  // NOC_GRP (tb_noc_profiling.svh) only exists under NOC_PROFILING, whereas this
  // trace must work whenever SPM_PROFILING is set.
  `define SPM_TILE(gg,tt) dut.i_mempool_cluster.gen_groups_x[(gg)/NumY].gen_groups_y[(gg)%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[tt].i_tile

  string  spm_bank_log_path;
  integer spm_bank_retval;
  int     f_bank  [NumGroups][NumTilesPerGroup];
  // Per-bank run state (0=idle 1=stall 2=read 3=write) and start cycle of the
  // currently-open run.
  logic [1:0]  bank_st [NumGroups][NumTilesPerGroup][NumBanksPerTile];
  logic [63:0] bank_s  [NumGroups][NumTilesPerGroup][NumBanksPerTile];

  initial begin
    spm_bank_log_path = "spm_profiling";
    spm_bank_retval   = $system({"mkdir -p ", spm_bank_log_path});
    for (int g = 0; g < NumGroups; g++)
      for (int t = 0; t < NumTilesPerGroup; t++)
        f_bank[g][t] = $fopen($sformatf("%s/bank_g%0d_t%0d.log",
                              spm_bank_log_path, g, t), "w");
  end

  // Per-bank access capture. bank_req_valid/ready[b] is the post-arbitration
  // grant; bank_req_ini_addr[b] (winning input port) + bank_req_wide[b] identify
  // the requester (payload src fields valid only for remote inputs).
  generate
    for (genvar g = 0; g < NumGroups; g++) begin : gen_spm_bank_g
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_spm_bank_t
        // local/remote boundary = NumCoresPerTile core ports on the local side.
        localparam int unsigned NLP = NumCoresPerTile;
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            bank_st[g][t] <= '{default: '0}; bank_s[g][t] <= '{default: '0};
          end else begin
            for (int b = 0; b < NumBanksPerTile; b++) begin
              automatic logic [1:0] rb = `SPM_TILE(g,t).bank_req_valid[b]
                ? (`SPM_TILE(g,t).bank_req_ready[b]
                   ? (`SPM_TILE(g,t).bank_req_payload[b].wen ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
              if (rb != bank_st[g][t][b]) begin
                $fwrite(f_bank[g][t], "S %0d %0d %0d %0d\n", b, bank_s[g][t][b], cycle_q, bank_st[g][t][b]);
                bank_st[g][t][b] <= rb; bank_s[g][t][b] <= cycle_q;
              end
              if (rb >= 2) begin
                // Who won the bank: bank_req_ini_addr[b] = winning input-port index
                // (< NLP = local), bank_req_wide[b]=1 = DMA. Local inputs zero their
                // src fields, so port identifies them; remote inputs carry origin.
                automatic int unsigned winp = `SPM_TILE(g,t).bank_req_ini_addr[b];
                $fwrite(f_bank[g][t], "P %0d %0d %0d %0h %0d %0d %0d %0d %0d %0d %0d\n",
                  b, cycle_q,
                  `SPM_TILE(g,t).bank_req_payload[b].wen,
                  `SPM_TILE(g,t).bank_req_payload[b].tgt_addr,
                  (winp < NLP) ? 1 : 0,                              // loc: local port
                  `SPM_TILE(g,t).bank_req_wide[b],                   // wide: DMA access
                  winp,                                              // winning input port
                  `SPM_TILE(g,t).bank_req_payload[b].src_group_id,   // remote origin grp
                  `SPM_TILE(g,t).bank_req_payload[b].ini_addr,       // remote origin tile
                  `SPM_TILE(g,t).bank_req_payload[b].wdata.core_id,  // remote origin core
                  `SPM_TILE(g,t).bank_req_payload[b].wdata.meta_id); // meta_id
              end
            end
          end
        end
      end
    end
  endgenerate

  // End-of-sim flush: emit each bank's still-open run, then close every file.
  final begin
    for (int g = 0; g < NumGroups; g++)
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int b = 0; b < NumBanksPerTile; b++)
          $fwrite(f_bank[g][t], "S %0d %0d %0d %0d\n", b, bank_s[g][t][b], cycle_q, bank_st[g][t][b]);
        $fclose(f_bank[g][t]);
      end
  end

  /* ===================== DISABLED previous profiler =====================
   * Old per-cycle bank-conflict counters and per-word dbg_profile_q profiler.
   * The per-word profiler mirrors mempool_tile.profile_d, whose unbounded dynamic
   * cycle lists balloon VCS. Kept commented for reference.
   * ======================================================================
  string  spm_app, spm_log_path;
  integer spm_retval;
  int     f_0, f_1, f_final_0, f_final_1;
  string  fn_0, fn_1, fn_final_0, fn_final_1;
  int     f_bc;

  initial begin
    void'($value$plusargs("APP=%s", spm_app));
    $sformat(spm_log_path, "../scripts/spm_profiling/run_logs/%s", spm_app);
    spm_retval = $system({"mkdir -p ", spm_log_path});
    f_bc = $fopen({spm_log_path, "/bank_conflict.log"}, "w");
  end

  // ------------------------------------------------------------
  // Bank-conflict profiling (same-bank contention from multiple tiles)
  // ------------------------------------------------------------
  // Count of requests targeting the same bank from multiple tiles
  logic [NumGroups-1:0]
        [NumTilesPerGroup * NumBanksPerTile - 1:0]
        [$clog2(NumTilesPerGroup * (NumRemoteReqPortsPerTile - 1)) : 0]
        group_xbar_req_to_same_bank_count;
  logic [NumGroups-1:0]
        [NumTilesPerGroup * NumBanksPerTile - 1:0]
        [$clog2(NumTilesPerGroup * (NumRemoteReqPortsPerTile - 1)) : 0]
        group_xbar_req_to_same_bank_conflict_count;
  logic [NumGroups-1:0]
        [$clog2(NumTilesPerGroup * (NumRemoteReqPortsPerTile - 1)) : 0]
        group_xbar_req_to_same_bank_conflict_count_sum;
  logic [NumX-1:0][NumY-1:0][NumRemoteReqPortsPerTile - 2:0][NumTilesPerGroup-1:0]
        tcdm_slave_req_valid;
  logic [NumX-1:0][NumY-1:0][NumRemoteReqPortsPerTile - 2:0][NumTilesPerGroup-1:0]
        [idx_width(NumTilesPerGroup) + idx_width(NumBanksPerTile) - 1 : 0]
        tcdm_slave_req_tgt_addr;

  generate
    for (genvar x_dim = 0; x_dim < NumX; x_dim++) begin : gen_x
      for (genvar y_dim = 0; y_dim < NumY; y_dim++) begin : gen_y
        for (genvar p = 0; p < (NumRemoteReqPortsPerTile - 1); p++) begin : gen_port
          for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_tile
            assign tcdm_slave_req_valid[x_dim][y_dim][p][t] =
                dut.i_mempool_cluster.gen_groups_x[x_dim].gen_groups_y[y_dim]
                  .gen_rtl_group.i_group
                  .floo_tcdm_req_from_router_before_xbar_valid_per_port[p + 1][t];
            assign tcdm_slave_req_tgt_addr[x_dim][y_dim][p][t] =
                dut.i_mempool_cluster.gen_groups_x[x_dim].gen_groups_y[y_dim]
                  .gen_rtl_group.i_group.floo_tcdm_req_from_router[t][p + 1]
                  .hdr.tgt_addr[idx_width(NumTilesPerGroup) + idx_width(NumBanksPerTile) - 1 : 0];
          end
        end
      end
    end
  endgenerate

  always_comb begin
    group_xbar_req_to_same_bank_count = '0;
    for (int g = 0; g < NumGroups; g++)
      for (int p = 0; p < (NumRemoteReqPortsPerTile - 1); p++)
        for (int t = 0; t < NumTilesPerGroup; t++)
          if (tcdm_slave_req_valid[g / NumY][g % NumY][p][t])
            group_xbar_req_to_same_bank_count[g][
              tcdm_slave_req_tgt_addr[g / NumY][g % NumY][p][t]] += 1;
  end

  always_comb begin
    group_xbar_req_to_same_bank_conflict_count     = '0;
    group_xbar_req_to_same_bank_conflict_count_sum = '0;
    for (int g = 0; g < NumGroups; g++)
      for (int b = 0; b < NumTilesPerGroup * NumBanksPerTile; b++) begin
        if (group_xbar_req_to_same_bank_count[g][b] > 0)
          group_xbar_req_to_same_bank_conflict_count[g][b] =
              group_xbar_req_to_same_bank_count[g][b] - 1;  // minus the winner
        group_xbar_req_to_same_bank_conflict_count_sum[g] +=
            group_xbar_req_to_same_bank_conflict_count[g][b];
      end
  end

  // Cumulative per-group bank-conflict cycles, dumped as a time series.
  int unsigned bank_conflict_q [NumGroups];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      for (int g = 0; g < NumGroups; g++) bank_conflict_q[g] = '0;
    else
      for (int g = 0; g < NumGroups; g++)
        bank_conflict_q[g] += group_xbar_req_to_same_bank_conflict_count_sum[g];
  end

  always_ff @(posedge clk) begin
    if (rst_n && ((cycle_q % 1024) == 0)) begin
      $timeformat(-9, 0, "", 10);
      $fwrite(f_bc, "dump time %t, cycle %8d #;\n", $time, cycle_q);
      for (int g = 0; g < NumGroups; g++)
        $fwrite(f_bc, "{'GROUP': %03d, 'bank_conflict_cyc_num': %0d}\n", g, bank_conflict_q[g]);
    end
  end

  // ------------------------------------------------------------
  // SPM bank-activity profiling (per-bank-word access trace)
  // ------------------------------------------------------------
  profile_t dbg_profile_q[NumGroups-1:0][NumTilesPerGroup-1:0][NumBanksPerTile-1:0][2**TCDMAddrMemWidth-1:0];

  generate
    for (genvar g = 0; g < NumGroups; g++) begin
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin
        for (genvar b = 0; b < NumBanksPerTile; b++) begin
          for(genvar i = 0; i < 2**TCDMAddrMemWidth; i++) begin
            always_ff @(posedge clk or posedge rst_n) begin
              if(cycle_q[7:0] == 'h80) begin
                dbg_profile_q[g][t][b][i].initiated            = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].initiated;
                dbg_profile_q[g][t][b][i].initial_cycle        = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].initial_cycle;
                dbg_profile_q[g][t][b][i].last_read_cycle      = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].last_read_cycle;
                dbg_profile_q[g][t][b][i].last_write_cycle     = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].last_write_cycle;
                dbg_profile_q[g][t][b][i].last_access_cycle    = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].last_access_cycle;
                dbg_profile_q[g][t][b][i].access_read_number   = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].access_read_number;
                dbg_profile_q[g][t][b][i].access_write_number  = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].access_write_number;
                dbg_profile_q[g][t][b][i].access_number        = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].access_number;
                dbg_profile_q[g][t][b][i].read_cycles          = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].read_cycles;
                dbg_profile_q[g][t][b][i].write_cycles         = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.profile_d[b][i].write_cycles;
              end
            end
          end
        end
      end
    end
  endgenerate

  always_ff @(posedge clk or posedge rst_n) begin
    if (rst_n) begin
      if ((cycle_q[63:0] == 'h100)  ||
          (cycle_q[63:0] == 'h200)  ||
          (cycle_q[63:0] == 'h400)  ||
          (cycle_q[63:0] == 'h800)  ||
          (cycle_q[63:0] == 'h1000) ||
          (cycle_q[15:0] == 'h8000)) begin

        $sformat(fn_0, "%s/trace_banks_cyc_%8x.dasm",        spm_log_path, cycle_q);
        $sformat(fn_1, "%s/trace_banks_cyc_%8x_inited.dasm", spm_log_path, cycle_q);
        f_1 = $fopen(fn_1, "w");
        $display("[Tracer] Logging Banks to %s, %s", fn_0, fn_1);

        for (int g = 0; g < NumGroups; g++) begin
          for (int t = 0; t < NumTilesPerGroup; t++) begin
            for (int b = 0; b < NumBanksPerTile; b++) begin
              for (int i = 0; i < 2 ** TCDMAddrMemWidth; i++) begin
                automatic string trace_entry;
                automatic string extras_str;

                extras_str = $sformatf(
                  "{'GROUP': %03d, 'TILE': %03d, 'BANK': %03d, 'IDX': 0x%x, 'inited': %03d, 'ini_cyc': %03d, 'last_rd_cyc': %03d, 'last_wr_cyc': %03d, 'last_acc_cyc': %03d, 'acc_rd_num': %03d, 'acc_wr_num': %03d, 'acc_num': %03d, ",
                  g, t, b, i,
                  dbg_profile_q[g][t][b][i].initiated,
                  dbg_profile_q[g][t][b][i].initial_cycle,
                  dbg_profile_q[g][t][b][i].last_read_cycle,
                  dbg_profile_q[g][t][b][i].last_write_cycle,
                  dbg_profile_q[g][t][b][i].last_access_cycle,
                  dbg_profile_q[g][t][b][i].access_read_number,
                  dbg_profile_q[g][t][b][i].access_write_number,
                  dbg_profile_q[g][t][b][i].access_number
                );

                extras_str = $sformatf("%s'rd_cyc': ", extras_str);
                foreach (dbg_profile_q[g][t][b][i].read_cycles[cycle_idx])
                  extras_str = $sformatf("%s%03d ", extras_str, dbg_profile_q[g][t][b][i].read_cycles[cycle_idx]);
                extras_str = $sformatf("%s, ", extras_str);

                extras_str = $sformatf("%s'wr_cyc': ", extras_str);
                foreach (dbg_profile_q[g][t][b][i].write_cycles[cycle_idx])
                  extras_str = $sformatf("%s%03d ", extras_str, dbg_profile_q[g][t][b][i].write_cycles[cycle_idx]);
                extras_str = $sformatf("%s}", extras_str);

                if (dbg_profile_q[g][t][b][i].initiated) begin
                  $sformat(trace_entry, "%8d #; %s\n", cycle_q, extras_str);
                  $fwrite(f_1, trace_entry);
                end
              end
            end
          end
        end
        $fclose(f_1);
      end
    end
  end

  final begin
    $sformat(fn_final_0, "%s/trace_banks_cyc_%8x_final.dasm",        spm_log_path, cycle_q);
    $sformat(fn_final_1, "%s/trace_banks_cyc_%8x_inited_final.dasm", spm_log_path, cycle_q);
    f_final_0 = $fopen(fn_final_0, "w");
    f_final_1 = $fopen(fn_final_1, "w");
    $display("[Tracer] Final Logging Banks to %s, %s", fn_final_0, fn_final_1);

    for (int g = 0; g < NumGroups; g++) begin
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int b = 0; b < NumBanksPerTile; b++) begin
          for (int i = 0; i < 2 ** TCDMAddrMemWidth; i++) begin
            automatic string trace_entry_final;
            automatic string extras_str_final;

            extras_str_final = $sformatf(
              "{'GROUP': %03d, 'TILE': %03d, 'BANK': %03d, 'IDX': 0x%x, 'inited': %03d, 'ini_cyc': %03d, 'last_rd_cyc': %03d, 'last_wr_cyc': %03d, 'last_acc_cyc': %03d, 'acc_rd_num': %03d, 'acc_wr_num': %03d, 'acc_num': %03d, ",
              g, t, b, i,
              dbg_profile_q[g][t][b][i].initiated,
              dbg_profile_q[g][t][b][i].initial_cycle,
              dbg_profile_q[g][t][b][i].last_read_cycle,
              dbg_profile_q[g][t][b][i].last_write_cycle,
              dbg_profile_q[g][t][b][i].last_access_cycle,
              dbg_profile_q[g][t][b][i].access_read_number,
              dbg_profile_q[g][t][b][i].access_write_number,
              dbg_profile_q[g][t][b][i].access_number
            );

            extras_str_final = $sformatf("%s'rd_cyc': ", extras_str_final);
            foreach (dbg_profile_q[g][t][b][i].read_cycles[cycle_idx])
              extras_str_final = $sformatf("%s%03d ", extras_str_final, dbg_profile_q[g][t][b][i].read_cycles[cycle_idx]);
            extras_str_final = $sformatf("%s, ", extras_str_final);

            extras_str_final = $sformatf("%s'wr_cyc': ", extras_str_final);
            foreach (dbg_profile_q[g][t][b][i].write_cycles[cycle_idx])
              extras_str_final = $sformatf("%s%03d ", extras_str_final, dbg_profile_q[g][t][b][i].write_cycles[cycle_idx]);
            extras_str_final = $sformatf("%s}", extras_str_final);

            if (dbg_profile_q[g][t][b][i].initiated) begin
              $sformat(trace_entry_final, "%8d #; %s\n", cycle_q, extras_str_final);
              $fwrite(f_final_1, trace_entry_final);
            end
            $sformat(trace_entry_final, "%8d #; %s\n", cycle_q, extras_str_final);
            $fwrite(f_final_0, trace_entry_final);
          end
        end
      end
    end
    $fclose(f_final_0);
    $fclose(f_final_1);
    $fclose(f_bc);
  end
  ===================== end DISABLED previous profiler ===================== */

`endif // SPM_PROFILING
`endif // TARGET_VERILATOR
`endif // TARGET_SYNTHESIS
`endif // TB_SPM_PROFILING_SVH_
