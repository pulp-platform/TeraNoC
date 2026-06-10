# Copyright 2021 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# VCS + Verdi run script. Under `-verdi` the simv `-do` file is played by Verdi's
# TclPlay console, which runs both simulator (dump/run) and Verdi/nWave commands.
#
#   1. Full-signal FSDB dump (= QuestaSim `log -r *`): -depth 0 = all levels,
#      -aggregates keeps structs/arrays, -fsdb_opt also captures memories.
dump -file mempool.fsdb -type FSDB
dump -add /mempool_tb -depth 0 -aggregates -fsdb_opt +mda+packedmda+struct

#   2. Populate nWave. wave.tcl uses Verdi-only console commands, so source it
#      here (under -verdi), not via -ucli.
source ../scripts/vcs/wave.tcl

#   3. Run until the testbench's $finish.
run
