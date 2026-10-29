// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// SAIF of the netlist group over the benchmark window, for PrimeTime power
// (hardware/postlayout/README.md). Included inside mempool_tb, where `PL_GROUP names the netlist.
//
// The window is the [PWR] window: it opens and closes on the same clock edges that print the
// [PWR] lines, from csr_trace_any_global. Only the first window is recorded. Every net of the
// netlist is monitored, including the pins of each standard cell and the nets inside the cell
// models; PrimeTime annotates what matches its design and ignores the rest. VCS counts at most one
// transition per net per time step, so zero-delay glitches add nothing.
//
// The file is written to the run directory, `pl_group.saif` unless +pl_saif=<file> says otherwise.
// Its hierarchy starts at mempool_tb; strip the netlist's path in PrimeTime (README).

  initial begin : pl_saif_setup
    $set_gate_level_monitoring("on");
    $set_toggle_region(`PL_GROUP);
  end

  logic  pl_saif_on, pl_saif_done;
  string pl_saif_file;
  always @(posedge clk or negedge rst_n) begin  // not always_ff: the file name is a blocking write
    if (!rst_n) begin
      pl_saif_on   <= 1'b0;
      pl_saif_done <= 1'b0;
    end else if (!pl_saif_done) begin
      if (csr_trace_any_global && !csr_trace_any_global_q && !pl_saif_on) begin
        $toggle_start();
        pl_saif_on <= 1'b1;
        $display("[SAIF] recording the netlist group from %0.3f ns (cycle %0d)", $realtime,
                 pl_cycle);
      end else if (!csr_trace_any_global && csr_trace_any_global_q && pl_saif_on) begin
        $toggle_stop();
        if (!$value$plusargs("pl_saif=%s", pl_saif_file)) pl_saif_file = "pl_group.saif";
        $toggle_report(pl_saif_file, 1.0e-12, "mempool_tb");
        pl_saif_on   <= 1'b0;
        pl_saif_done <= 1'b1;
        $display("[SAIF] stopped at %0.3f ns (cycle %0d), written to %s", $realtime, pl_cycle,
                 pl_saif_file);
      end
    end
  end
