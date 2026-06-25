// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`ifndef TB_SPATZ_PROFILING_SVH_
`define TB_SPATZ_PROFILING_SVH_

`ifndef TARGET_SYNTHESIS
`ifndef TARGET_VERILATOR

  // ===========================================================================
  // Spatz VECTOR ENGINE trace -- ALWAYS ON whenever the cores are Spatz cores
  // (mempool_pkg::RVV). Engine INTERNALS only (controller scoreboard occupancy,
  // VFU / VLSU / VSLDU busy + sub-state, issue/retire handshakes, active memory
  // ports); the Spatz memory-port traffic itself stays under NOC_PROFILING.
  //
  // Spatz is per-CORE (not per-tile like RedMulE), so one log file per Spatz
  // core (reuses cycle_q from tb_noc_profiling.svh):
  //   D <VLEN> <N_FU> <NrMemPorts>                                  (header, once)
  //   C <cyc> <occ> <stall> <issue> <vfu_busy> <vfu_st> <vlsu_busy> <vlsu_st>
  //       <vsldu_busy> <vfu_rsp> <vlsu_rsp> <vsldu_rsp> <memact>
  //   E <last_cyc>                                                  (footer, once)
  // A C line is written every cycle the engine is active; a cycle with no C line
  // means IDLE. The exporter derives the FSM slices, util counters and the
  // occupancy/CPI breakdown from these raw samples, so the policy can change
  // without re-simulating.
  //
  //   occ        = $countones(controller.running_insn_q) -- in-flight vinsns
  //   stall      = controller.stall (issue stalled: target ex-unit not ready)
  //   issue      = controller issue handshake (issue_valid & issue_ready)
  //   vfu_busy   = i_vfu.busy_q ;  vfu_st  = i_vfu.state_q  (0=IPU,1=FPU)
  //   vlsu_busy  = i_vlsu.busy_q;  vlsu_st = i_vlsu.state_q (0=load,1=store)
  //   vsldu_busy = |i_vsldu.running_q
  //   *_rsp      = per-unit retire-valid (vfu/vlsu/vsldu_rsp_valid)
  //   memact     = $countones(spatz_mem_req_valid_o) -- TCDM ports requesting
  // ===========================================================================

  // Path to core c's Spatz vector unit. Mirrors RM_TOP but Spatz lives per core
  // inside the unified core complex (mempool_cc.riscv_core.gen_spatz.i_spatz).
  `define SPATZ_TOP(gg,tt,cc) dut.i_mempool_cluster.gen_groups_x[(gg)/NumY].gen_groups_y[(gg)%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[tt].i_tile.gen_cores[cc].gen_mempool_cc.riscv_core.gen_spatz.i_spatz

  if (mempool_pkg::RVV) begin : gen_spatz_eng_prof
    int f_speng [NumGroups][NumTilesPerGroup][NumCoresPerTile];

    initial begin
      string  sp_log_path;
      integer sp_retval;
      sp_log_path = "spatz_profiling";
      sp_retval   = $system({"mkdir -p ", sp_log_path});
      for (int g = 0; g < NumGroups; g++)
        for (int t = 0; t < NumTilesPerGroup; t++)
          for (int c = 0; c < NumCoresPerTile; c++) begin
            f_speng[g][t][c] = $fopen($sformatf("%s/spatz_g%0d_t%0d_c%0d.log",
                                                sp_log_path, g, t, c), "w");
            $fwrite(f_speng[g][t][c], "D %0d %0d %0d\n",
                    spatz_pkg::VLEN, spatz_pkg::N_FU,
                    mempool_pkg::NumMemPortsPerSpatz);
          end
    end

    for (genvar g = 0; g < NumGroups; g++) begin : gen_g
      for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_t
        for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_c
          always_ff @(posedge clk or negedge rst_n) begin
            if (rst_n) begin
              automatic int unsigned occ        = $countones(`SPATZ_TOP(g,t,c).i_controller.running_insn_q);
              automatic logic        stall      = `SPATZ_TOP(g,t,c).i_controller.stall;
              automatic logic        issue      = `SPATZ_TOP(g,t,c).issue_valid & `SPATZ_TOP(g,t,c).issue_ready;
              automatic logic        vfu_busy   = `SPATZ_TOP(g,t,c).i_vfu.busy_q;
              automatic int unsigned vfu_st     = `SPATZ_TOP(g,t,c).i_vfu.state_q;
              automatic logic        vlsu_busy  = `SPATZ_TOP(g,t,c).i_vlsu.busy_q;
              automatic int unsigned vlsu_st    = `SPATZ_TOP(g,t,c).i_vlsu.state_q;
              automatic logic        vsldu_busy = |`SPATZ_TOP(g,t,c).i_vsldu.running_q;
              automatic logic        vfu_rsp    = `SPATZ_TOP(g,t,c).vfu_rsp_valid;
              automatic logic        vlsu_rsp   = `SPATZ_TOP(g,t,c).vlsu_rsp_valid;
              automatic logic        vsldu_rsp  = `SPATZ_TOP(g,t,c).vsldu_rsp_valid;
              automatic int unsigned memact     = $countones(`SPATZ_TOP(g,t,c).spatz_mem_req_valid_o);
              if (occ != 0 || vfu_busy || vlsu_busy || vsldu_busy || issue || memact != 0)
                $fwrite(f_speng[g][t][c],
                        "C %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                        cycle_q, occ, stall, issue, vfu_busy, vfu_st,
                        vlsu_busy, vlsu_st, vsldu_busy,
                        vfu_rsp, vlsu_rsp, vsldu_rsp, memact);
            end
          end
        end
      end
    end

    final begin
      // End-of-sim marker: last cycle, so the exporter can render IDLE across
      // every gap between active bursts and out to the end of the run.
      for (int g = 0; g < NumGroups; g++)
        for (int t = 0; t < NumTilesPerGroup; t++)
          for (int c = 0; c < NumCoresPerTile; c++) begin
            $fwrite(f_speng[g][t][c], "E %0d\n", cycle_q);
            $fclose(f_speng[g][t][c]);
          end
    end
  end

`endif // TARGET_VERILATOR
`endif // TARGET_SYNTHESIS
`endif // TB_SPATZ_PROFILING_SVH_
