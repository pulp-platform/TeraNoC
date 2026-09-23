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
// Reports EVERY period, tagged "pre" or "bench" by whether csr_trace_any_global is
// high. The other gated probes ([LP], [BP]) stay silent until the software marks the
// benchmark region, which on this workload is long after boot, DMA and several
// 1024-core barriers -- too late to be useful for watching a run in flight. The
// per-period figure here is therefore always-on; the "cum" field is the
// benchmark-region-only cumulative, which is the number to quote as THE utilisation.
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
  int unsigned fu_raw_cum,  fu_raw_prev;
  int unsigned fu_active_cyc, fu_active_prev;
  int unsigned fu_cycle;
  logic        fu_active;

  // --------------------------------------------------------------------------
  // MSHR health counters, reported as PER-PERIOD DELTAS alongside utilisation.
  //   mshr_issue_timeout_cnt_dbg : hold window expired (hold_cnt hit 0) -- the entry
  //     issued on the timeout rather than on reaching its subscriber target. A rising
  //     rate means the hold window is too long for the merge opportunity actually there.
  //   req_bankfull_bypass_cnt_dbg: request bypassed the MSHR because no way was free.
  //     This is the way-capacity backfire an earlier hold-window sweep blamed for its
  //     net-negative result, so it is the counter that tells us whether a longer window
  //     is buying merges or just occupying ways.
  // Both are free-running 32-bit counters per group; deltas scope them to a period.
  // Hierarchical refs sit inside genvar loops (a procedural index into a generate-block
  // instance array passes analysis and fails elaboration with XMRE).
  // --------------------------------------------------------------------------
  logic [31:0] fu_mshr_timeout [NumGroups];
  logic [31:0] fu_bankfull_byp [NumGroups];

  generate
    for (genvar gx = 0; gx < NumX; gx++) begin : gen_fu_mshr_gx
      for (genvar gy = 0; gy < NumY; gy++) begin : gen_fu_mshr_gy
        if (MshrSplit) begin : gen_split
          // Disaggregated MSHR: the group figure is the sum over its eight slice cores.
          logic [31:0] to_s [MshrNumSlices];
          logic [31:0] bf_s [MshrNumSlices];
          for (genvar m = 0; m < MshrNumSlices; m++) begin : gen_slice
            assign to_s[m] = dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
               .gen_rtl_group.i_group.i_mempool_group.gen_group_mshr_split.gen_slice[m].i_slice.i_core
               .mshr_issue_timeout_cnt_dbg;
            assign bf_s[m] = dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
               .gen_rtl_group.i_group.i_mempool_group.gen_group_mshr_split.gen_slice[m].i_slice.i_core
               .req_bankfull_bypass_cnt_dbg;
          end
          always_comb begin
            fu_mshr_timeout[NumY*gx+gy] = '0;
            fu_bankfull_byp[NumY*gx+gy] = '0;
            for (int m = 0; m < MshrNumSlices; m++) begin
              fu_mshr_timeout[NumY*gx+gy] += to_s[m];
              fu_bankfull_byp[NumY*gx+gy] += bf_s[m];
            end
          end
        end else begin : gen_legacy
          assign fu_mshr_timeout[NumY*gx+gy] =
            dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
               .gen_rtl_group.i_group.i_mempool_group.gen_group_mshr.i_group_mshr.mshr_issue_timeout_cnt_dbg;
          assign fu_bankfull_byp[NumY*gx+gy] =
            dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
               .gen_rtl_group.i_group.i_mempool_group.gen_group_mshr.i_group_mshr.req_bankfull_bypass_cnt_dbg;
        end
      end
    end
  endgenerate

  longint unsigned fu_to_cum,  fu_to_prev;    // summed across all groups
  longint unsigned fu_bfb_cum, fu_bfb_prev;

  // PER-GROUP previous values, so [MSHRG] can report a per-group delta. The summed
  // fu_to_cum/fu_bfb_cum above answer "how much MSHR pressure is there"; these answer "WHICH
  // GROUPS have it", which is the question the aggregate cannot. Both source arrays are already
  // wired per group above -- the aggregate just adds them up before anyone sees them.
  // `int unsigned`, not `logic [31:0]`: 2-state types default to 0, 4-state to X, and an X here
  // would make the very first [MSHRG] delta print as x rather than a number. fu_grp_prev above
  // is declared the same way for the same reason.
  //
  // Like the aggregate fu_to_prev/fu_bfb_prev, these start at 0 while the RTL counters they
  // track are free-running from reset, so the FIRST reported delta is the absolute count rather
  // than a period delta. That matches the existing aggregate behaviour exactly; the first line
  // of a run is not a period measurement in either case.
  int unsigned fu_to_grp_prev  [NumGroups];
  int unsigned fu_bfb_grp_prev [NumGroups];

  // --------------------------------------------------------------------------
  // PROBE 2: intra-group CORE PROGRESS SPREAD.
  //
  // grp_max/grp_min compare GROUPS. They say nothing about how far apart the 16 cores WITHIN a
  // group have drifted -- which is the quantity that decides whether their B-bursts land in the
  // same MSHR merge window. The per-core busy bits are already collected above; this just stops
  // throwing the detail away.
  //
  // Per period, per group: spread = (busiest core's cycles) - (idlest core's cycles). A group
  // running in lockstep has spread ~0; one that has drifted shows a large spread. Reported as
  // the mean over groups and the worst single group.
  // --------------------------------------------------------------------------
  int unsigned fu_core_cum [NumGroups][NumTilesPerGroup][NumCoresPerTile];
  int unsigned fu_core_prev[NumGroups][NumTilesPerGroup][NumCoresPerTile];

  // --------------------------------------------------------------------------
  // PROBE 3: per-core RETIRED-INSTRUCTION counter (user's idea, 2026-08-07).
  //
  // Strictly better than PROBE 2 for the alignment question. Busy-FPU-cycles conflate two
  // things -- a core can be busy without progressing (spinning) or progressing without FPU
  // work (scalar sections). Retired instructions measure PROGRAM POSITION: two cores with the
  // same count are at the same instruction. Every core in a group runs the same loop structure
  // (only m_start/p_start differ), so at any moment aligned cores should have near-identical
  // counts, and the spread IS the drift.
  //
  // Counting starts when csr_trace_any_global rises (the benchmark region), so the counters
  // measure the timed kernel only.
  //
  // Three views come out of it:
  //   intra-group spread : drift between the 16 cores of a group -- what the p-loop barrier
  //                        exists to control, and what decides whether B-bursts share a merge
  //                        window.
  //   inter-group spread : drift between groups -- which NO barrier controls (the group
  //                        barrier is per-group), so it is unmanaged by construction.
  //   spread right after a release : the residual skew a barrier failed to remove.
  // --------------------------------------------------------------------------
  logic        fu_retire [NumGroups][NumTilesPerGroup][NumCoresPerTile];
  int unsigned fu_insn_cum [NumGroups][NumTilesPerGroup][NumCoresPerTile];

  generate
    for (genvar gx = 0; gx < NumX; gx++) begin : gen_fu_ret_gx
      for (genvar gy = 0; gy < NumY; gy++) begin : gen_fu_ret_gy
        for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_fu_ret_t
          for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_fu_ret_c
            // Any of the four retire paths counts as one instruction leaving the core.
            // retire_p is a post-increment writeback that accompanies another retire, so it is
            // deliberately EXCLUDED to avoid double-counting a single instruction.
            assign fu_retire[NumY*gx+gy][t][c] =
              dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
                 .gen_rtl_group.i_group.i_mempool_group
                 .gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.retire_i
            | dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
                 .gen_rtl_group.i_group.i_mempool_group
                 .gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.retire_load
            | dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
                 .gen_rtl_group.i_group.i_mempool_group
                 .gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.retire_acc;
          end
        end
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // PROBE 4: per-group STALL-REASON breakdown and outstanding-memory census.
  //
  // [FPUG] says WHICH groups are idle; until now nothing said WHY. Snitch's issue stage defines
  // (snitch.sv:354)
  //     stall = ~valid_instr | lsu_stall | acc_stall | fence_stall
  // and that decomposition IS the diagnosis: a group sitting at ~0% FPU is either starved of
  // instructions, blocked on scalar memory, unable to hand work to Spatz, or parked in a fence.
  //
  // Three of the four already have free-running counters inside the core (snitch.sv:394-400).
  // They are always compiled -- SNITCH_ENABLE_STALL_COUNTER and SNITCH_ENABLE_PERF are set
  // unconditionally in deps/snitch/Bender.yml -- so they cost one wire each and are already
  // live in every run ever made; only the readout was missing. acc_stall and fence_stall have
  // NO counter and are sampled combinationally and counted here.
  //
  // fence_stall is the reason this probe exists. It is
  //     !lsu_empty || (|acc_mem_cnt_q)                                   (snitch.sv:887)
  // i.e. "wait until the memory I already asked for comes back". A core parked there shows the
  // exact signature the slow groups show: no FPU work, no retired instructions, and NO NoC
  // stall -- it is not blocked ON the network, it is waiting for something the network already
  // owes it. Congestion and a dropped response look identical from [BP] and opposite here.
  //
  // acc_mem_cnt_q is therefore exported alongside: if one group's outstanding count sits pinned
  // at a constant non-zero value while every other group drains, a response was lost, which is a
  // different bug from congestion and has a different fix. acc_mem_req_cnt_q (requests not yet
  // issued) separates "hasn't sent it yet" from "sent it and never got it back".
  // --------------------------------------------------------------------------
  `define FU_SNITCH(gx,gy,t,c) dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy] \
      .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.gen_cores[c]          \
      .gen_mempool_cc.riscv_core.i_snitch

  logic [31:0] fu_sins [NumGroups][NumTilesPerGroup][NumCoresPerTile]; // icache starvation
  logic [31:0] fu_sraw [NumGroups][NumTilesPerGroup][NumCoresPerTile]; // operand / RAW hazard
  logic [31:0] fu_slsu [NumGroups][NumTilesPerGroup][NumCoresPerTile]; // scalar LSU backpressure
  logic        fu_sacc [NumGroups][NumTilesPerGroup][NumCoresPerTile]; // Spatz will not accept
  logic        fu_sfen [NumGroups][NumTilesPerGroup][NumCoresPerTile]; // parked in a fence
  logic [2:0]  fu_memo [NumGroups][NumTilesPerGroup][NumCoresPerTile]; // outstanding acc mem ops
  logic [2:0]  fu_memq [NumGroups][NumTilesPerGroup][NumCoresPerTile]; // ... requests still unsent

  generate
    for (genvar gx = 0; gx < NumX; gx++) begin : gen_fu_st_gx
      for (genvar gy = 0; gy < NumY; gy++) begin : gen_fu_st_gy
        for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_fu_st_t
          for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_fu_st_c
            assign fu_sins[NumY*gx+gy][t][c] = `FU_SNITCH(gx,gy,t,c).stall_ins_q;
            assign fu_sraw[NumY*gx+gy][t][c] = `FU_SNITCH(gx,gy,t,c).stall_raw_q;
            assign fu_slsu[NumY*gx+gy][t][c] = `FU_SNITCH(gx,gy,t,c).stall_lsu_q;
            assign fu_sacc[NumY*gx+gy][t][c] = `FU_SNITCH(gx,gy,t,c).acc_stall;
            assign fu_sfen[NumY*gx+gy][t][c] = `FU_SNITCH(gx,gy,t,c).fence_stall;
            assign fu_memo[NumY*gx+gy][t][c] = `FU_SNITCH(gx,gy,t,c).acc_mem_cnt_q;
            assign fu_memq[NumY*gx+gy][t][c] = `FU_SNITCH(gx,gy,t,c).acc_mem_req_cnt_q;
          end
        end
      end
    end
  endgenerate
  `undef FU_SNITCH

  // acc_stall / fence_stall are level signals, so the TB counts them; the other three arrive
  // pre-counted. memo/memq accumulate their occupancy so a period mean falls out of the delta.
  // All always-on (like fu_grp_cum) so the pre-benchmark ramp is visible too.
  int unsigned fu_sacc_cum [NumGroups], fu_sacc_prev [NumGroups];
  int unsigned fu_sfen_cum [NumGroups], fu_sfen_prev [NumGroups];
  int unsigned fu_memo_cum [NumGroups], fu_memo_prev [NumGroups];
  int unsigned fu_memq_cum [NumGroups], fu_memq_prev [NumGroups];
  int unsigned fu_sins_prev [NumGroups], fu_sraw_prev [NumGroups], fu_slsu_prev [NumGroups];
  int unsigned fu_insn_prev [NumGroups], fu_barc_prev [NumGroups];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int g = 0; g < NumGroups; g++) begin
        fu_sacc_cum[g] <= 0; fu_sfen_cum[g] <= 0;
        fu_memo_cum[g] <= 0; fu_memq_cum[g] <= 0;
      end
    end else begin
      for (int g = 0; g < NumGroups; g++) begin
        automatic int unsigned na = 0, nf = 0, no = 0, nq = 0;
        for (int t = 0; t < NumTilesPerGroup; t++)
          for (int c = 0; c < NumCoresPerTile; c++) begin
            if (fu_sacc[g][t][c]) na++;
            if (fu_sfen[g][t][c]) nf++;
            no += fu_memo[g][t][c];
            nq += fu_memq[g][t][c];
          end
        fu_sacc_cum[g] <= fu_sacc_cum[g] + na;
        fu_sfen_cum[g] <= fu_sfen_cum[g] + nf;
        fu_memo_cum[g] <= fu_memo_cum[g] + no;
        fu_memq_cum[g] <= fu_memq_cum[g] + nq;
      end
    end
  end

  // PROBE 1 readback: barrier arrival spread, summed over all groups.
  logic [31:0] fu_bar_sum [NumGroups];
  logic [31:0] fu_bar_cnt [NumGroups];
  logic [15:0] fu_bar_max [NumGroups];
  generate
    for (genvar gx = 0; gx < NumX; gx++) begin : gen_fu_bar_gx
      for (genvar gy = 0; gy < NumY; gy++) begin : gen_fu_bar_gy
        assign fu_bar_sum[NumY*gx+gy] =
          dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
             .gen_rtl_group.i_group.i_mempool_group.gen_group_barrier.i_group_barrier.bar_spread_sum_dbg;
        assign fu_bar_cnt[NumY*gx+gy] =
          dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
             .gen_rtl_group.i_group.i_mempool_group.gen_group_barrier.i_group_barrier.bar_release_cnt_dbg;
        assign fu_bar_max[NumY*gx+gy] =
          dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
             .gen_rtl_group.i_group.i_mempool_group.gen_group_barrier.i_group_barrier.bar_spread_max_dbg;
      end
    end
  endgenerate
  longint unsigned fu_bsum_cum, fu_bsum_prev, fu_bcnt_cum, fu_bcnt_prev;

  assign fu_active = csr_trace_any_global;

  // fu_busy_bits is a plain array now, so a procedural sum over it is legal.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fu_cycle <= 0; fu_busy_cum <= 0; fu_active_cyc <= 0; fu_raw_cum <= 0;
      for (int g = 0; g < NumGroups; g++) fu_grp_cum[g] <= 0;
      for (int g = 0; g < NumGroups; g++)
        for (int t = 0; t < NumTilesPerGroup; t++)
          for (int c = 0; c < NumCoresPerTile; c++) begin
            fu_core_cum[g][t][c] <= 0; fu_insn_cum[g][t][c] <= 0;
          end
    end else begin
      automatic int unsigned tot = 0;
      fu_cycle <= fu_cycle + 1;
      for (int g = 0; g < NumGroups; g++) begin
        automatic int unsigned n = 0;
        for (int t = 0; t < NumTilesPerGroup; t++)
          for (int c = 0; c < NumCoresPerTile; c++) begin
            fu_core_cum[g][t][c] <= fu_core_cum[g][t][c] + $countones(fu_busy_bits[g][t][c]);
            n += $countones(fu_busy_bits[g][t][c]);
          end
        fu_grp_cum[g] <= fu_grp_cum[g] + n;   // always-on, so per-group data exists pre-benchmark
        tot += n;
      end
      fu_raw_cum <= fu_raw_cum + tot;         // always-on
      // PROBE 3: retired instructions, benchmark region only (the user's "start the counter
      // when the benchmark starts" -- so the counts are directly comparable across cores).
      if (fu_active)
        for (int g = 0; g < NumGroups; g++)
          for (int t = 0; t < NumTilesPerGroup; t++)
            for (int c = 0; c < NumCoresPerTile; c++)
              if (fu_retire[g][t][c]) fu_insn_cum[g][t][c] <= fu_insn_cum[g][t][c] + 1;
      if (fu_active) begin                    // benchmark-region only
        fu_busy_cum   <= fu_busy_cum + tot;
        fu_active_cyc <= fu_active_cyc + 1;
      end
    end
  end

  task automatic fu_report(input string tag);
    int unsigned d_busy, d_cyc, g_max, g_min, g_max_id, g_min_id, dg;
    real         util_p, util_c, gu_max, gu_min;
    longint unsigned d_to, d_bfb, d_bsum, d_bcnt;
    real             core_spread_avg, bar_spread_avg;
    int unsigned     core_spread_max, core_spread_g, bar_max_any;
    real             insn_intra_avg;
    int unsigned     insn_intra_max, insn_intra_g, insn_inter, insn_total;
    // Sum the free-running per-group counters, then delta against the last report.
    fu_to_cum  = 0;
    fu_bfb_cum = 0;
    for (int g = 0; g < NumGroups; g++) begin
      fu_to_cum  = fu_to_cum  + longint'(fu_mshr_timeout[g]);
      fu_bfb_cum = fu_bfb_cum + longint'(fu_bankfull_byp[g]);
    end
    d_to  = fu_to_cum  - fu_to_prev;
    d_bfb = fu_bfb_cum - fu_bfb_prev;
    d_busy = fu_raw_cum - fu_raw_prev;                 // this period, always-on
    d_cyc  = `FPU_UTIL_PERIOD;
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
    // PROBE 2: intra-group core spread, this period. For each group, the busiest core's
    // cycles minus the idlest core's. Mean over groups + worst single group.
    begin
      automatic int unsigned sp_sum = 0, sp_worst = 0, sp_worst_g = 0;
      for (int g = 0; g < NumGroups; g++) begin
        automatic int unsigned cmax = 0, cmin = 32'hFFFFFFFF, dc;
        for (int t = 0; t < NumTilesPerGroup; t++)
          for (int c = 0; c < NumCoresPerTile; c++) begin
            dc = fu_core_cum[g][t][c] - fu_core_prev[g][t][c];
            if (dc > cmax) cmax = dc;
            if (dc < cmin) cmin = dc;
          end
        sp_sum += (cmax - cmin);
        if ((cmax - cmin) > sp_worst) begin sp_worst = cmax - cmin; sp_worst_g = g; end
      end
      core_spread_avg = real'(sp_sum) / real'(NumGroups);
      core_spread_max = sp_worst; core_spread_g = sp_worst_g;
    end
    // PROBE 3: retired-instruction drift. Two views, exactly as proposed:
    //   intra = max-min ACROSS THE 16 CORES OF A GROUP, averaged over groups, and the worst group
    //   inter = max-min ACROSS GROUP TOTALS (no barrier controls this -- the group barrier is
    //           per-group, so inter-group drift is unmanaged by construction)
    begin
      automatic int unsigned isum = 0, iworst = 0, iworst_g = 0;
      automatic int unsigned gtot_max = 0, gtot_min = 32'hFFFFFFFF;
      for (int g = 0; g < NumGroups; g++) begin
        automatic int unsigned imax = 0, imin = 32'hFFFFFFFF, gtot = 0;
        for (int t = 0; t < NumTilesPerGroup; t++)
          for (int c = 0; c < NumCoresPerTile; c++) begin
            automatic int unsigned v = fu_insn_cum[g][t][c];
            if (v > imax) imax = v;
            if (v < imin) imin = v;
            gtot += v;
          end
        isum += (imax - imin);
        if ((imax - imin) > iworst) begin iworst = imax - imin; iworst_g = g; end
        if (gtot > gtot_max) gtot_max = gtot;
        if (gtot < gtot_min) gtot_min = gtot;
      end
      insn_intra_avg  = real'(isum) / real'(NumGroups);
      insn_intra_max  = iworst; insn_intra_g = iworst_g;
      // per-core equivalent so intra and inter are on the same scale
      insn_inter      = (gtot_max - gtot_min) / (NumTilesPerGroup*NumCoresPerTile);
      insn_total      = gtot_max;
    end
    // PROBE 1: barrier arrival spread (cycles between first and last arrival), averaged over
    // every release in this period across all groups.
    fu_bsum_cum = 0; fu_bcnt_cum = 0;
    for (int g = 0; g < NumGroups; g++) begin
      fu_bsum_cum += longint'(fu_bar_sum[g]);
      fu_bcnt_cum += longint'(fu_bar_cnt[g]);
    end
    d_bsum = fu_bsum_cum - fu_bsum_prev;
    d_bcnt = fu_bcnt_cum - fu_bcnt_prev;
    bar_spread_avg = (d_bcnt > 0) ? real'(d_bsum)/real'(d_bcnt) : 0.0;
    bar_max_any = 0;
    for (int g = 0; g < NumGroups; g++) if (fu_bar_max[g] > bar_max_any) bar_max_any = fu_bar_max[g];

    $display("[FPU] %s cyc=%0d util=%.2f%% cum=%.2f%% busy=%0d/%0d lane-cyc  grp_max=%.1f%%(g%0d) grp_min=%.1f%%(g%0d)  mshr_timeout=+%0d bankfull_bypass=+%0d  core_spread=%.0f/%0d(g%0d)  bar_rel=+%0d bar_spread=%.1f bar_max=%0d  insn_drift_intra=%.0f/%0d(g%0d) inter=%0d insn_max=%0d",
             tag, fu_cycle, util_p, util_c, d_busy, d_cyc*FU_Lanes,
             gu_max, g_max_id, gu_min, g_min_id, d_to, d_bfb,
             core_spread_avg, core_spread_max, core_spread_g,
             d_bcnt, bar_spread_avg, bar_max_any,
             insn_intra_avg, insn_intra_max, insn_intra_g, insn_inter, insn_total);
`ifndef FPU_PER_GROUP_DISABLE
    // PER-GROUP UTILISATION, ALL GROUPS, EVERY PERIOD.
    //
    // grp_max/grp_min above report only the two extremes. They cannot distinguish a group
    // that is persistently slow from one that merely happens to be slowest this period, and
    // that distinction decides whether the 8x8 utilisation collapse is a fixed set of starved
    // groups or every group taking turns. fu_grp_cum[] already holds the answer for all 64
    // groups; until now it was thrown away at the end of this task.
    //
    // Emitted as RAW busy lane-cycles plus the per-group denominator rather than a percentage,
    // so a consumer normalises exactly as gu_max/gu_min do and nothing is lost to rounding:
    //     util_g = 100.0 * busy[g] / denom
    // One line per period, ~64 short integers -- a few hundred bytes, negligible next to the
    // rest of the log. Compile out with +define+FPU_PER_GROUP_DISABLE.
    //
    // MUST stay ahead of the fu_grp_prev update below, which destroys the delta.
    //
    // Cosmetic quirk, verified in the first FG511 output and left alone deliberately: the
    // ternary picks between "%0d" and ",%0d", and SV pads the shorter string literal to the
    // wider one, so field 0 prints with a leading space ("busy= 0,0,..."). Harmless -- any
    // int()/atoi() strips it -- and NOT worth an 81-minute rebuild to make pretty. Do not
    // "fix" it in isolation either: the runs must stay format-identical to each other.
    begin
      automatic string gs = "";
      for (int g = 0; g < NumGroups; g++)
        gs = {gs, $sformatf((g == 0) ? "%0d" : ",%0d", fu_grp_cum[g] - fu_grp_prev[g])};
      $display("[FPUG] %s cyc=%0d denom=%0d busy=%s", tag, fu_cycle, d_cyc*FU_PerGrpLane, gs);
    end

    // [MSHRG] -- the same treatment for MSHR pressure. The [FPU] line reports mshr_timeout and
    // bankfull_bypass summed over every group, which tells you how much pressure exists but not
    // WHERE. Per-group deltas identify the groups whose MSHR bank saturates -- the ones that lose
    // coalescing and fall behind, which is the MSHR-side view of the inter-group progress spread.
    //
    // Both source arrays are free-running 32-bit counters per group, so the subtraction below
    // wraps correctly without a widening cast: at 32 bits an overflow between two consecutive
    // reports would need ~4.3e9 events in one period, which is not reachable.
    //
    // MUST stay ahead of the prev update below, exactly as [FPUG] must.
    begin
      automatic string ts = "";
      automatic string bs = "";
      for (int g = 0; g < NumGroups; g++) begin
        ts = {ts, $sformatf((g == 0) ? "%0d" : ",%0d", fu_mshr_timeout[g] - fu_to_grp_prev[g])};
        bs = {bs, $sformatf((g == 0) ? "%0d" : ",%0d", fu_bankfull_byp[g] - fu_bfb_grp_prev[g])};
      end
      $display("[MSHRG] %s cyc=%0d timeout=%s bypass=%s", tag, fu_cycle, ts, bs);
    end

    // [STALLG] / [MEMOG] / [INSNG] / [BARG] -- PROBE 4 readout, the "why is this group idle"
    // set. Read them together; each alone is ambiguous and the combination is not:
    //
    //   low FPU + low insn + high fen   -> parked waiting for memory it already requested
    //   low FPU + low insn + high ins   -> icache starvation
    //   low FPU + low insn + high acc   -> Spatz backed up, core cannot hand off
    //   low FPU + HIGH insn             -> not stalled at all: spinning in a poll/barrier loop
    //   low FPU + low insn + all ~0     -> not stalled and not retiring => waiting on the
    //                                      barrier's release signal, not on any local resource
    //
    // and then MEMOG disambiguates the first case: memo draining each period is congestion,
    // memo pinned at a constant while other groups drain is a LOST RESPONSE. BARG closes it by
    // showing whether the group is a barrier release behind everyone else.
    //
    // Denominator is core-cycles (not lane-cycles as [FPUG] uses) because these count per core,
    // so a share is value/denom in [0,1]. memo/memq are occupancy sums: divide by denom for the
    // mean outstanding ops per core.
    //
    // MUST stay ahead of the prev updates below, exactly as [FPUG] and [MSHRG] must.
    begin
      automatic string si = "", sr = "", sl = "", sa = "", sf = "";
      automatic string mo = "", mq = "", ni = "", bc = "";
      for (int g = 0; g < NumGroups; g++) begin
        automatic int unsigned ci = 0, cr = 0, cl = 0, cn = 0;
        for (int t = 0; t < NumTilesPerGroup; t++)
          for (int c = 0; c < NumCoresPerTile; c++) begin
            ci += fu_sins[g][t][c];
            cr += fu_sraw[g][t][c];
            cl += fu_slsu[g][t][c];
            cn += fu_insn_cum[g][t][c];
          end
        si = {si, $sformatf((g == 0) ? "%0d" : ",%0d", ci - fu_sins_prev[g])};
        sr = {sr, $sformatf((g == 0) ? "%0d" : ",%0d", cr - fu_sraw_prev[g])};
        sl = {sl, $sformatf((g == 0) ? "%0d" : ",%0d", cl - fu_slsu_prev[g])};
        sa = {sa, $sformatf((g == 0) ? "%0d" : ",%0d", fu_sacc_cum[g] - fu_sacc_prev[g])};
        sf = {sf, $sformatf((g == 0) ? "%0d" : ",%0d", fu_sfen_cum[g] - fu_sfen_prev[g])};
        mo = {mo, $sformatf((g == 0) ? "%0d" : ",%0d", fu_memo_cum[g] - fu_memo_prev[g])};
        mq = {mq, $sformatf((g == 0) ? "%0d" : ",%0d", fu_memq_cum[g] - fu_memq_prev[g])};
        ni = {ni, $sformatf((g == 0) ? "%0d" : ",%0d", cn - fu_insn_prev[g])};
        bc = {bc, $sformatf((g == 0) ? "%0d" : ",%0d", fu_bar_cnt[g] - fu_barc_prev[g])};
        fu_sins_prev[g] = ci;  fu_sraw_prev[g] = cr;  fu_slsu_prev[g] = cl;
        fu_insn_prev[g] = cn;  fu_barc_prev[g] = fu_bar_cnt[g];
        fu_sacc_prev[g] = fu_sacc_cum[g];  fu_sfen_prev[g] = fu_sfen_cum[g];
        fu_memo_prev[g] = fu_memo_cum[g];  fu_memq_prev[g] = fu_memq_cum[g];
      end
      $display("[STALLG] %s cyc=%0d denom=%0d ins=%s raw=%s lsu=%s acc=%s fen=%s",
               tag, fu_cycle, d_cyc*NumTilesPerGroup*NumCoresPerTile, si, sr, sl, sa, sf);
      $display("[MEMOG] %s cyc=%0d memo=%s memq=%s", tag, fu_cycle, mo, mq);
      $display("[INSNG] %s cyc=%0d insn=%s rel=%s", tag, fu_cycle, ni, bc);
    end
`endif
    fu_raw_prev    = fu_raw_cum;
    fu_busy_prev   = fu_busy_cum;
    fu_active_prev = fu_active_cyc;
    fu_to_prev     = fu_to_cum;
    fu_bfb_prev    = fu_bfb_cum;
    fu_bsum_prev   = fu_bsum_cum;
    fu_bcnt_prev   = fu_bcnt_cum;
    for (int g = 0; g < NumGroups; g++)
      for (int t = 0; t < NumTilesPerGroup; t++)
        for (int c = 0; c < NumCoresPerTile; c++) fu_core_prev[g][t][c] = fu_core_cum[g][t][c];
    for (int g = 0; g < NumGroups; g++) fu_grp_prev[g] = fu_grp_cum[g];
    for (int g = 0; g < NumGroups; g++) begin
      fu_to_grp_prev[g]  = fu_mshr_timeout[g];
      fu_bfb_grp_prev[g] = fu_bankfull_byp[g];
    end
  endtask

  // Report EVERY period, not only inside the benchmark region: the point of this probe is
  // to see utilisation while the run is in flight, and on this workload the benchmark
  // region does not open until well after boot, DMA and several 1024-core barriers.
  always @(posedge clk) begin
    if (rst_n && (fu_cycle % `FPU_UTIL_PERIOD) == 0)
      fu_report(fu_active ? "bench" : "pre   ");
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


  // ---------------------------------------------------------------------------------------------
  // [MSHRCFG] -- did software actually turn the group MSHR on?
  //
  // With group_mshr_cfg_runtime=1 the MSHR resets to enable=0 BY DESIGN: init, DMA and I$ warm-up
  // must not occupy ways. Software is then required to enable it (mshr_cfg_apply_group) before the
  // timed region. If it does not, nothing crashes -- the benchmark simply runs with the MSHR
  // bypassed, which measured +55.6% on 256x512x256 (53,835 vs 34,596 cyc).
  //
  // That is a SILENTLY SLOW run, the same failure class as the 8x8 group barrier that was a no-op
  // for days. So the TB checks it once, at the instant the benchmark region opens, and says so
  // loudly. Costs nothing in synthesis -- this whole file is translate_off.
`ifdef GROUP_MSHR_CFG_RUNTIME
  logic [NumGroups-1:0] fu_mshr_en;
  generate
    for (genvar gx = 0; gx < NumX; gx++) begin : gen_fu_mshren_gx
      for (genvar gy = 0; gy < NumY; gy++) begin : gen_fu_mshren_gy
        if (MshrSplit) begin : gen_split
          // One CSR file feeds every slice, so slice 0 speaks for the group.
          assign fu_mshr_en[NumY*gx+gy] =
            dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
               .gen_rtl_group.i_group.i_mempool_group.gen_group_mshr_split.gen_slice[0].i_slice.i_core
               .cfg_mshr_enable;
        end else begin : gen_legacy
          assign fu_mshr_en[NumY*gx+gy] =
            dut.i_mempool_cluster.gen_groups_x[gx].gen_groups_y[gy]
               .gen_rtl_group.i_group.i_mempool_group.gen_group_mshr.i_group_mshr.cfg_mshr_enable;
        end
      end
    end
  endgenerate

  logic fu_bench_q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fu_bench_q <= 1'b0;
    end else begin
      fu_bench_q <= csr_trace_any_global;
      if (csr_trace_any_global && !fu_bench_q) begin   // benchmark region just opened
        // GROUP_MSHR_CFG_RUNTIME is defined even when its VALUE is 0, so distinguish on the
        // package parameter: only a runtime build can be left un-enabled by software.
        if (&fu_mshr_en)
          $display("[MSHRCFG] cyc=%0d all %0d groups ENABLED (%s)", fu_cycle, NumGroups,
                   mempool_pkg::MshrCfgRuntime ? "runtime, software-configured" : "fixed-function");
        else
          $display("[MSHRCFG WARN] cyc=%0d MSHR DISABLED in %0d of %0d groups at benchmark start (en=%b) -- software never configured it; this run measures a BYPASSED MSHR and its cycle count is NOT comparable",
                   fu_cycle, NumGroups - $countones(fu_mshr_en), NumGroups, fu_mshr_en);
      end
    end
  end
`endif  // GROUP_MSHR_CFG_RUNTIME

`endif  // TARGET_SPATZ
`endif  // VERILATOR
// pragma translate_on

`endif  // TB_FPU_UTIL_SVH
