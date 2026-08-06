// ============================================================================
// tb_fpu_util.svh — periodic Spatz VFU/FPU utilisation.
// Include inside mempool_tb module.
//
// Answers "what is the FPU utilisation?" WHILE the run is in flight, instead of
// only from the final cycle count. Samples spatz_vfu's fpu_busy_q (one bit per
// FPU lane, N_FPU per core) every cycle and reports, per period:
//
//   busy FPU-lane-cycles / (period * NumCores * N_FPU)
//
// which is the fraction of available FPU issue slots that were occupied.
//
// Gated on csr_trace_any_global like the other probes, so the numbers cover the
// benchmark region the software marks and not the boot/DMA setup around it.
//
// NOTE on structure: every hierarchical reference sits inside a genvar loop.
// Generate-block instance arrays (gen_tiles[t], gen_cores[c]) may only be indexed
// by CONSTANTS in a cross-module reference -- a procedural `int` loop variable
// passes analysis and then fails elaboration with XMRE. The per-core busy counts
// are latched into a plain array first; summing that array procedurally is legal.
// ============================================================================

`ifndef TB_FPU_UTIL_SVH
`define TB_FPU_UTIL_SVH

`ifndef FPU_UTIL_PERIOD
`define FPU_UTIL_PERIOD 1000
`endif

// pragma translate_off
`ifndef VERILATOR
`ifdef TARGET_SPATZ

  localparam int FU_NumCores   = NumGroups * NumTilesPerGroup * NumCoresPerTile;
  localparam int FU_Lanes      = FU_NumCores * `N_FPU;
  localparam int FU_PerGrpLane = NumTilesPerGroup * NumCoresPerTile * `N_FPU;

  // Per-core busy-lane bitmap, filled by constant-indexed generate assigns.
  logic [`N_FPU-1:0] fu_busy_bits [NumGroups][NumTilesPerGroup][NumCoresPerTile];

  generate
    for (genvar gx = 0; gx < NumX; gx++) begin : gen_fu_gx
      for (genvar gy = 0; gy < NumY; gy++) begin : gen_fu_gy
        for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_fu_t
          for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_fu_c
            assign fu_busy_bits[NumY*gx+gy][t][c] =
              dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
                 .gen_rtl_group.i_group.i_mempool_group
                 .gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core
                 .i_spatz.i_vfu.gen_fpu.fpu_busy_q;
          end
        end
      end
    end
  endgenerate

  int unsigned fu_grp_cum  [NumGroups];   // busy lane-cycles per group
  int unsigned fu_grp_prev [NumGroups];
  int unsigned fu_busy_cum, fu_busy_prev;
  int unsigned fu_active_cyc, fu_active_prev;
  int unsigned fu_cycle;
  logic        fu_active;

  assign fu_active = csr_trace_any_global;

  // fu_busy_bits is a plain array now, so a procedural sum over it is legal.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fu_cycle <= 0; fu_busy_cum <= 0; fu_active_cyc <= 0;
      for (int g = 0; g < NumGroups; g++) fu_grp_cum[g] <= 0;
    end else begin
      fu_cycle <= fu_cycle + 1;
      if (fu_active) begin
        automatic int unsigned tot = 0;
        for (int g = 0; g < NumGroups; g++) begin
          automatic int unsigned n = 0;
          for (int t = 0; t < NumTilesPerGroup; t++)
            for (int c = 0; c < NumCoresPerTile; c++)
              n += $countones(fu_busy_bits[g][t][c]);
          fu_grp_cum[g] <= fu_grp_cum[g] + n;
          tot += n;
        end
        fu_busy_cum   <= fu_busy_cum + tot;
        fu_active_cyc <= fu_active_cyc + 1;
      end
    end
  end

  task automatic fu_report(input string tag);
    int unsigned d_busy, d_cyc, g_max, g_min, g_max_id, g_min_id, dg;
    real         util_p, util_c, gu_max, gu_min;
    d_busy = fu_busy_cum   - fu_busy_prev;
    d_cyc  = fu_active_cyc - fu_active_prev;
    util_p = (d_cyc > 0)         ? 100.0*d_busy     /($itor(d_cyc)*FU_Lanes)         : 0.0;
    util_c = (fu_active_cyc > 0) ? 100.0*fu_busy_cum/($itor(fu_active_cyc)*FU_Lanes) : 0.0;
    g_max = 0; g_min = 32'hFFFFFFFF; g_max_id = 0; g_min_id = 0;
    for (int g = 0; g < NumGroups; g++) begin
      dg = fu_grp_cum[g] - fu_grp_prev[g];
      if (dg > g_max) begin g_max = dg; g_max_id = g; end
      if (dg < g_min) begin g_min = dg; g_min_id = g; end
    end
    gu_max = (d_cyc > 0) ? 100.0*g_max/($itor(d_cyc)*FU_PerGrpLane) : 0.0;
    gu_min = (d_cyc > 0) ? 100.0*g_min/($itor(d_cyc)*FU_PerGrpLane) : 0.0;
    $display("[FPU] %s cyc=%0d util=%.2f%% cum=%.2f%% busy=%0d/%0d lane-cyc  grp_max=%.1f%%(g%0d) grp_min=%.1f%%(g%0d)",
             tag, fu_cycle, util_p, util_c, d_busy, d_cyc*FU_Lanes,
             gu_max, g_max_id, gu_min, g_min_id);
    fu_busy_prev   = fu_busy_cum;
    fu_active_prev = fu_active_cyc;
    for (int g = 0; g < NumGroups; g++) fu_grp_prev[g] = fu_grp_cum[g];
  endtask

  always @(posedge clk) begin
    if (rst_n && (fu_cycle % `FPU_UTIL_PERIOD) == 0 && fu_active)
      fu_report("delta");
  end

  final begin
    if (fu_active_cyc > 0)
      $display("[FPU FINAL] busy=%0d of %0d lane-cycles over %0d benchmark cycles -> util=%.2f%%  (%0d lanes = %0d cores x %0d FPU)",
               fu_busy_cum, fu_active_cyc*FU_Lanes, fu_active_cyc,
               100.0*fu_busy_cum/($itor(fu_active_cyc)*FU_Lanes),
               FU_Lanes, FU_NumCores, `N_FPU);
    else
      $display("[FPU FINAL] benchmark region never active (csr_trace_any_global stayed low) -- no utilisation sampled");
  end

`endif  // TARGET_SPATZ
`endif  // VERILATOR
// pragma translate_on

`endif  // TB_FPU_UTIL_SVH
