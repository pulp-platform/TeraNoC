// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// X/Z monitor for one port of the post-layout group (hardware/postlayout/README.md).
//
// Samples the port on every rising clock edge once enable_i is high. Reports the first cycle it
// carries any X/Z bit, and at the end of simulation how many cycles did and the most X/Z bits seen
// at once. An X on an output was produced by the netlist; one on an input arrived from the RTL.
//
// The port is connected zero-extended to MaxWidth: VCS rejects $bits() of a hierarchical reference
// as a parameter value in the full design (SV-BXBSF), and zero bits never count as X.

`ifndef TB_POSTLAYOUT_XMON_SVH
`define TB_POSTLAYOUT_XMON_SVH

module tb_postlayout_xmon #(
  parameter int unsigned MaxWidth = 16384,
  parameter string       Name     = ""
) (
  input logic                clk_i,
  input logic                enable_i,
  input logic [MaxWidth-1:0] sig_i
);

  timeunit      1ns;
  timeprecision 1ps;

  logic [63:0] cycle, x_cycles, first_x_cycle;
  logic [31:0] x_bits, max_x_bits;

  initial begin
    cycle      = '0;
    x_cycles   = '0;
    max_x_bits = '0;
  end

  always @(posedge clk_i) begin
    if (enable_i) begin
      cycle <= cycle + 1;
      if ($isunknown(sig_i)) begin
        x_bits = $countbits(sig_i, 'x, 'z);
        if (x_cycles == 0) begin
          first_x_cycle = cycle;
          $display("[PL-X] %s: first X/Z at %0.3f ns (cycle %0d after reset), %0d bits",
                   Name, $realtime, cycle, x_bits);
        end
        x_cycles <= x_cycles + 1;
        if (x_bits > max_x_bits) max_x_bits <= x_bits;
      end
    end
  end

  final begin
    if (x_cycles != 0)
      $display("[PL-X] %s: X/Z in %0d of %0d cycles (first at cycle %0d, at most %0d bits)",
               Name, x_cycles, cycle, first_x_cycle, max_x_bits);
    else
      $display("[PL-X] %s: clean over %0d cycles", Name, cycle);
  end

endmodule

`endif
