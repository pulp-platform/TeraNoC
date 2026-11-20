// ============================================================================
// tb_l1_bank_access.svh -- L1 SRAM accesses per group over the benchmark window.
// Include inside mempool_tb module. Only with +define+L1_BANK_PROF.
//
// Counts, per group, the cycles each tile bank's tc_sram is enabled (gen_banks[b] req_valid,
// the SRAM's req_i), split by req_write. Each count is one SRAM access, the event the netlist
// macros' CEB marks, so it pairs with the per-access energy of the post-layout power runs
// (hardware/postlayout/power) to estimate L1 power for workloads the netlist cannot run.
// Every source is counted: local and remote cores, the DMA and the MSHR. A post-layout build's
// netlist group (0,0) reads 0 here.
//
// The window is csr_trace_any_global, every window is reported when it closes:
//   [L1ACC] win=W cyc=N rd= wr=                     (one field / group)
// and once at the end of the run, summed over all windows:
//   [L1ACC] total win=W cyc=N rd= wr=
//
// The format of each $write is a literal: a ternary between two format strings is not a format
// string to $write, which then prints the string's bits as a number before each value.
//
// As in tb_fpu_util.svh, the hierarchical references sit inside genvar loops (generate
// instance arrays may only be indexed by constants) and are summed procedurally.
// ============================================================================

`ifndef TB_L1_BANK_ACCESS_SVH
`define TB_L1_BANK_ACCESS_SVH

// pragma translate_off
`ifdef L1_BANK_PROF

`define L1A_TILE(g, t) dut.i_mempool_cluster.gen_groups_x[(g)/NumY].gen_groups_y[(g)%NumY] \
    .gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile

logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumBanksPerTile-1:0] l1a_req, l1a_we;
for (genvar g = 0; g < NumGroups; g++) begin : gen_l1a_g
  for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_l1a_t
    for (genvar b = 0; b < NumBanksPerTile; b++) begin : gen_l1a_b
      if (PostLayoutGr && (g == 0)) begin : gen_netlist  // no RTL banks: counted from its SAIF
        assign l1a_req[g][t][b] = 1'b0;
        assign l1a_we[g][t][b]  = 1'b0;
      end else begin : gen_rtl
        assign l1a_req[g][t][b] = `L1A_TILE(g, t).gen_banks[b].req_valid;
        assign l1a_we[g][t][b]  = `L1A_TILE(g, t).gen_banks[b].req_write;
      end
    end
  end
end

logic [NumGroups-1:0][63:0] l1a_rd, l1a_wr, l1a_rd_tot, l1a_wr_tot;
logic [63:0] l1a_cyc, l1a_cyc_tot, l1a_win;
logic        l1a_on_q;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    l1a_rd      <= '0;
    l1a_wr      <= '0;
    l1a_rd_tot  <= '0;
    l1a_wr_tot  <= '0;
    l1a_cyc     <= '0;
    l1a_cyc_tot <= '0;
    l1a_win     <= '0;
    l1a_on_q    <= 1'b0;
  end else begin
    l1a_on_q <= csr_trace_any_global;
    if (csr_trace_any_global) begin
      for (int g = 0; g < NumGroups; g++) begin
        l1a_rd[g] <= l1a_rd[g] + $countones(l1a_req[g] & ~l1a_we[g]);
        l1a_wr[g] <= l1a_wr[g] + $countones(l1a_req[g] & l1a_we[g]);
      end
      l1a_cyc <= l1a_cyc + 1;
    end else if (l1a_on_q) begin
      // The window closed on this edge: report it, fold it into the totals, restart.
      $write("[L1ACC] win=%0d cyc=%0d rd=", l1a_win, l1a_cyc);
      for (int g = 0; g < NumGroups; g++)
        if (g) $write(",%0d", l1a_rd[g]); else $write("%0d", l1a_rd[g]);
      $write(" wr=");
      for (int g = 0; g < NumGroups; g++)
        if (g) $write(",%0d", l1a_wr[g]); else $write("%0d", l1a_wr[g]);
      $write("\n");
      for (int g = 0; g < NumGroups; g++) begin
        l1a_rd_tot[g] <= l1a_rd_tot[g] + l1a_rd[g];
        l1a_wr_tot[g] <= l1a_wr_tot[g] + l1a_wr[g];
      end
      l1a_cyc_tot <= l1a_cyc_tot + l1a_cyc;
      l1a_win     <= l1a_win + 1;
      l1a_rd      <= '0;
      l1a_wr      <= '0;
      l1a_cyc     <= '0;
    end
  end
end

final begin
  $write("[L1ACC] total win=%0d cyc=%0d rd=", l1a_win, l1a_cyc_tot);
  for (int g = 0; g < NumGroups; g++)
    if (g) $write(",%0d", l1a_rd_tot[g]); else $write("%0d", l1a_rd_tot[g]);
  $write(" wr=");
  for (int g = 0; g < NumGroups; g++)
    if (g) $write(",%0d", l1a_wr_tot[g]); else $write("%0d", l1a_wr_tot[g]);
  $write("\n");
end

`undef L1A_TILE
`endif
// pragma translate_on

`endif
