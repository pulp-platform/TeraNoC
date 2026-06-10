# Copyright 2021 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Headless full-signal FSDB dump (no GUI). Like run.tcl but skips the nWave
# window population (the wv* commands need the Verdi GUI).
dump -file mempool.fsdb -type FSDB
dump -add /mempool_tb -depth 0 -aggregates -fsdb_opt +mda+packedmda+struct
run