// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`ifndef TB_REDMULE_PROFILING_SVH_
`define TB_REDMULE_PROFILING_SVH_

`ifndef TARGET_SYNTHESIS
`ifndef TARGET_VERILATOR

  // ===========================================================================
  // RedMulE ENGINE trace -- ALWAYS ON whenever the system contains RedMulE.
  // Engine INTERNALS only (control/scheduler FSMs, array occupancy, per-cycle
  // stall causes); the RedMulE memory-port traffic stays under NOC_PROFILING.
  //
  // One log file per RedMulE tile (reuses cycle_q from tb_noc_profiling.svh):
  //   D <ARRAY_HEIGHT> <ARRAY_WIDTH> <PIPE_REGS>                              (header, once)
  //   C <cyc> <ctrl> <sched> <reg_en> <stall> <sw> <sx> <sy> <busy> <pc_ov>
  //   E <last_cyc>                                                           (footer, once)
  // A C line is written every cycle the engine is active; a cycle with no C line
  // means IDLE. The exporter derives the FSM slices, util counters and the 7-way
  // CPI stack from these raw samples, so the policy can change without re-simulating.
  // stall_Z (store) is derived at export as stall & ~(sched==LOAD_W & (sw|sx|sy)).
  // (engine busy_o is NOT sampled: it is the OR of clock-gate-frozen pipeline valids,
  // a stuck all-high constant, useless as an activity gate or occupancy metric.)
  // ===========================================================================

  `define RM_TOP(gg,tt) dut.i_mempool_cluster.gen_groups_x[(gg)/NumY].gen_groups_y[(gg)%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[tt].i_tile.gen_redmule.i_redmule_top

  if (NumRMTilesPerGroup > 0) begin : gen_rm_eng_prof
    int f_rmeng [NumGroups][NumRMTilesPerGroup];

    initial begin
      string  rm_log_path;
      integer rm_retval;
      rm_log_path = "redmule_profiling";
      rm_retval   = $system({"mkdir -p ", rm_log_path});
      for (int g = 0; g < NumGroups; g++)
        for (int t = 0; t < NumRMTilesPerGroup; t++) begin
          f_rmeng[g][t] = $fopen($sformatf("%s/redmule_g%0d_t%0d.log", rm_log_path, g, t), "w");
          // ARRAY_* macros only exist when num_redmule_tiles!=0; guard so configs WITHOUT
          // RedMulE still analyze (macros expand at analysis time regardless of the `if).
`ifdef ARRAY_HEIGHT
          $fwrite(f_rmeng[g][t], "D %0d %0d %0d\n", `ARRAY_HEIGHT, `ARRAY_WIDTH, `PIPE_REGS);
`else
          $fwrite(f_rmeng[g][t], "D 0 0 0\n");
`endif
        end
    end

    for (genvar g = 0; g < NumGroups; g++) begin : gen_g
      for (genvar t = 0; t < NumRMTilesPerGroup; t++) begin : gen_t
        always_ff @(posedge clk or negedge rst_n) begin
          if (rst_n) begin
            automatic int unsigned ctrl  = `RM_TOP(g,t).i_control.current;
            automatic int unsigned sched = `RM_TOP(g,t).i_scheduler.current_state;
            automatic logic        regen = `RM_TOP(g,t).i_scheduler.reg_enable_o;
            automatic logic        stall = `RM_TOP(g,t).i_scheduler.stall_engine;
            automatic logic        sw    = ~`RM_TOP(g,t).i_scheduler.check_w_valid  & `RM_TOP(g,t).i_scheduler.check_w_valid_en;
            automatic logic        sx    = ~`RM_TOP(g,t).i_scheduler.check_x_full   & `RM_TOP(g,t).i_scheduler.check_x_full_en;
            automatic logic        sy    = ~`RM_TOP(g,t).i_scheduler.check_y_loaded & `RM_TOP(g,t).i_scheduler.check_y_loaded_en;
            automatic logic        busy  = `RM_TOP(g,t).busy_o;
            automatic int unsigned pcov  = $countones(`RM_TOP(g,t).i_redmule_engine.out_valid_o);
            if (busy || pcov != 0)
              $fwrite(f_rmeng[g][t], "C %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                      cycle_q, ctrl, sched, regen, stall, sw, sx, sy, busy, pcov);
          end
        end
      end
    end

    final begin
      // End-of-sim marker: last cycle, so the exporter can render IDLE across
      // every gap between active bursts and out to the end of the run.
      for (int g = 0; g < NumGroups; g++)
        for (int t = 0; t < NumRMTilesPerGroup; t++) begin
          $fwrite(f_rmeng[g][t], "E %0d\n", cycle_q);
          $fclose(f_rmeng[g][t]);
        end
    end
  end

`endif // TARGET_VERILATOR
`endif // TARGET_SYNTHESIS
`endif // TB_REDMULE_PROFILING_SVH_
