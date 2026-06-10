# Copyright 2021 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# VCS + Verdi (nWave) curated overview for the 2D-mesh FlooNoC topology.
# `make simvcs` auto-sources this from run.tcl; re-source any time from Verdi's
# Tcl console: source ../scripts/vcs/wave.tcl. run.tcl dumps EVERY signal to the
# FSDB, so anything not listed here can still be dragged into nWave (no re-run).
#
# GOTCHA: interpreted by VERDI (nWave), NOT the UCLI shell -- use only `wv*`
# commands (no `dump`/`run`/`get`) and hard-code loop bounds (no
# `get mempool_pkg::...`). Wrap `[0]`/`[3]` indices in {braces} so Tcl does not
# treat them as command substitution.

# GOTCHA: capture wvCreateWindow's return -- it does NOT auto-set $_nWave2 from
# the -do/TclPlay console, so `wvAddSignal -win $_nWave2` would otherwise fail.
set _nWave2 [wvCreateWindow]

# --- System overview (testbench level) ---
wvAddSignal -win $_nWave2 {/mempool_tb/wfi}
wvAddSignal -win $_nWave2 {/mempool_tb/eoc_valid}
wvAddSignal -win $_nWave2 {/mempool_tb/snitch_utilization}
wvAddSignal -win $_nWave2 {/mempool_tb/lsu_utilization}

# --- Control registers (end-of-computation / wake-up) ---
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_ctrl_registers/eoc_o}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_ctrl_registers/eoc_valid_o}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_ctrl_registers/wake_up_o}

# --- Group 0 / Tile 0, core 0 (snitch front-end) ---
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/gen_groups_x[0]/gen_groups_y[0]/gen_rtl_group/i_group/i_mempool_group/gen_tiles[0]/i_tile/gen_cores[0]/gen_mempool_cc/riscv_core/i_snitch/pc_q}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/gen_groups_x[0]/gen_groups_y[0]/gen_rtl_group/i_group/i_mempool_group/gen_tiles[0]/i_tile/gen_cores[0]/gen_mempool_cc/riscv_core/i_snitch/wfi_q}


wvZoomAll -win $_nWave2
