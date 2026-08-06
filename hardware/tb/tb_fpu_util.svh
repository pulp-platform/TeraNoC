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
// which is exactly the fraction of available FPU issue slots that were occupied.
//
// Gated on csr_trace_any_global like the other probes, so the numbers cover the
// benchmark region the software marks and not the boot/DMA setup around it. The
// cumulative figure is therefore directly comparable to the kernel's own cycle
// count, and the per-period figure shows the ramp as cores enter the kernel.
// ============================================================================

`ifndef TB_FPU_UTIL_SVH
`define TB_FPU_UTIL_SVH

`ifndef FPU_UTIL_PERIOD
`define FPU_UTIL_PERIOD 1000
`endif

// pragma translate_off
`ifndef VERILATOR
`ifdef TARGET_SPATZ

  localparam int FU_NumCores = NumGroups * NumTilesPerGroup * NumCoresPerTile;
  localparam int FU_Lanes    = FU_NumCores * `N_FPU;

  int unsigned fu_busy_cum;      // busy lane-cycles since the benchmark started
  int unsigned fu_busy_prev;     // snapshot at the previous report
  int unsigned fu_active_cyc;    // cycles counted (benchmark-active only)
  int unsigned fu_active_prev;
  int unsigned fu_cycle;
  int unsigned fu_grp_cum [NumGroups];
  int unsigned fu_grp_prev[NumGroups];
  logic        fu_active;

  assign fu_active = csr_trace_any_global;

  // Per-group busy-lane count this cycle. Summing in a generate keeps the
  // hierarchical references static, which is what lets this scale to 1024 cores
  // without a procedural loop over the hierarchy.
  logic [$clog2(NumTilesPerGroup*NumCoresPerTile*`N_FPU+1)-1:0] fu_grp_now [NumGroups];

  generate
    for (genvar gx = 0; gx < NumX; gx++) begin : gen_fu_gx
      for (genvar gy = 0; gy < NumY; gy++) begin : gen_fu_gy
        localparam int GID = NumY*gx + gy;
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            fu_grp_cum[GID]  <= 0;
            fu_grp_prev[GID] <= 0;
          end else if (fu_active) begin
            automatic int unsigned n = 0;
            for (int t = 0; t < NumTilesPerGroup; t++)
              for (int c = 0; c < NumCoresPerTile; c++)
                n += $countones(
                  dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
                     .gen_rtl_group.i_group.i_mempool_group
                     .gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core
                     .i_spatz.i_vfu.gen_fpu.fpu_busy_q);
            fu_grp_cum[GID] <= fu_grp_cum[GID] + n;
          end
        end
      end
    end
  endgenerate

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fu_cycle <= 0; fu_busy_cum <= 0; fu_busy_prev <= 0;
      fu_active_cyc <= 0; fu_active_prev <= 0;
    end else begin
      automatic int unsigned tot = 0;
      fu_cycle <= fu_cycle + 1;
      if (fu_active) begin
        for (int g = 0; g < NumGroups; g++) tot += fu_grp_cum[g];
        fu_busy_cum   <= tot;
        fu_active_cyc <= fu_active_cyc + 1;
      end
    end
  end

  task automatic fu_report(input string tag);
    int unsigned d_busy, d_cyc, g_max, g_min, g_max_id, g_min_id;
    real         util_p, util_c;
    d_busy = fu_busy_cum   - fu_busy_prev;
    d_cyc  = fu_active_cyc - fu_active_prev;
    util_p = (d_cyc > 0)         ? 100.0*d_busy      /($itor(d_cyc)*FU_Lanes)         : 0.0;
    util_c = (fu_active_cyc > 0) ? 100.0*fu_busy_cum /($itor(fu_active_cyc)*FU_Lanes) : 0.0;
    g_max = 0; g_min = 32'hFFFFFFFF; g_max_id = 0; g_min_id = 0;
    for (int g = 0; g < NumGroups; g++) begin
      automatic int unsigned dg = fu_grp_cum[g] - fu_grp_prev[g];
      if (dg > g_max) begin g_max = dg; g_max_id = g; end
      if (dg < g_min) begin g_min = dg; g_min_id = g; end
    end
    $display("[FPU] %s cyc=%0d util=%.2f%% (cum %.2f%%) busy=%0d of %0d lane-cyc  lanes=%0d  grp_max=%0d(g%0d) grp_min=%0d(g%0d)",
             tag, fu_cycle, util_p, util_c, d_busy, d_cyc*FU_Lanes, FU_Lanes,
             g_max, g_max_id, g_min, g_min_id);
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
