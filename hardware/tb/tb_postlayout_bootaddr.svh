// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Boot-address override for a netlist synthesised with the wrong BootAddr
// (hardware/postlayout/README.md). Included inside mempool_tb, where `PL_GROUP names the netlist.
//
// The backend elaborates terapool_cluster_floonoc_wrapper with its default BootAddr = 0, so every
// Snitch PC in the netlist resets to 0x0 while the bootrom is at `BOOT_ADDR: core 0 never boots
// and the whole cluster waits on it. BootAddr has no other use than the PC reset value
// (snitch.sv `FFAR(pc_q, pc_d, BootAddr, ...)), so loading BootAddr into the PC flops at reset is
// equivalent to a netlist synthesised with it.
//
// The value is deposited on the PC flops' output nets at every falling clock edge while the netlist
// is in reset. The flops' internal state is then 0 and receives no event before reset ends, so the
// deposit holds until the first capture, which takes pc_d computed from it. Depositing after reset
// instead loses to a capture on the clock edge that releases reset: the flop holds pc_d while its
// net shows the stale deposit until pc_d next changes.
//
// The net names are Fusion's (one Snitch per tile, PC bits 31..2; bits 1..0 are 0 in any BootAddr).
// A netlist that names them differently fails elaboration here rather than booting from 0.

`define PL_PC(t, b) `PL_GROUP.i_mempool_group.gen_tiles_``t``__i_tile_snitch_inst_addr_``b``_
`define PL_PC_DEPOSIT(t, b) $deposit(`PL_PC(t, b), BootAddr[b]);
`define PL_PC_TILE(t) \
  `PL_PC_DEPOSIT(t, 31) `PL_PC_DEPOSIT(t, 30) `PL_PC_DEPOSIT(t, 29) `PL_PC_DEPOSIT(t, 28) \
  `PL_PC_DEPOSIT(t, 27) `PL_PC_DEPOSIT(t, 26) `PL_PC_DEPOSIT(t, 25) `PL_PC_DEPOSIT(t, 24) \
  `PL_PC_DEPOSIT(t, 23) `PL_PC_DEPOSIT(t, 22) `PL_PC_DEPOSIT(t, 21) `PL_PC_DEPOSIT(t, 20) \
  `PL_PC_DEPOSIT(t, 19) `PL_PC_DEPOSIT(t, 18) `PL_PC_DEPOSIT(t, 17) `PL_PC_DEPOSIT(t, 16) \
  `PL_PC_DEPOSIT(t, 15) `PL_PC_DEPOSIT(t, 14) `PL_PC_DEPOSIT(t, 13) `PL_PC_DEPOSIT(t, 12) \
  `PL_PC_DEPOSIT(t, 11) `PL_PC_DEPOSIT(t, 10) `PL_PC_DEPOSIT(t, 9)  `PL_PC_DEPOSIT(t, 8)  \
  `PL_PC_DEPOSIT(t, 7)  `PL_PC_DEPOSIT(t, 6)  `PL_PC_DEPOSIT(t, 5)  `PL_PC_DEPOSIT(t, 4)  \
  `PL_PC_DEPOSIT(t, 3)  `PL_PC_DEPOSIT(t, 2)

  initial begin : pl_boot_addr
    logic deposited;
    deposited = 1'b0;
    while (`PL_GROUP.rst_ni !== 1'b1) begin
      @(negedge clk);
      if (`PL_GROUP.rst_ni !== 1'b1) begin
        `PL_PC_TILE(0)  `PL_PC_TILE(1)  `PL_PC_TILE(2)  `PL_PC_TILE(3)
        `PL_PC_TILE(4)  `PL_PC_TILE(5)  `PL_PC_TILE(6)  `PL_PC_TILE(7)
        `PL_PC_TILE(8)  `PL_PC_TILE(9)  `PL_PC_TILE(10) `PL_PC_TILE(11)
        `PL_PC_TILE(12) `PL_PC_TILE(13) `PL_PC_TILE(14) `PL_PC_TILE(15)
        deposited = 1'b1;
      end
    end
    if (!deposited)
      $fatal(1, "[POSTLAYOUT] boot-address override: reset ended before a falling clock edge");
    $display("[POSTLAYOUT] netlist PC reset value overridden to BootAddr 0x%08x", BootAddr);
  end

`undef PL_PC_TILE
`undef PL_PC_DEPOSIT
`undef PL_PC
