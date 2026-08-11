# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# 8x8 with router response remapping -- the `fpugir2` headless arm's configuration, for GUI
# and waveform runs.
#
# ONE knob differs from the base flavour. The base already ships hold/serve_timeout 1023, so
# response remapping is the entire difference; everything else (mshr_num 64, merge_reqs 4,
# hold_subs 4/4, port_hash 7, rd0+rdwr2, resp 2) comes from the base unchanged. Verified against
# build_fpugir2/compilevcs.sh define-by-define.
#
# WHY YOU MIGHT WANT THIS IN A WAVEFORM: fpugir2 reached the fleet's highest utilisation (~90.5%
# cumulative) and then DEGRADED after ~35 periods to 86.8%, with the slowest group dropping to
# 0-13% and a DIFFERENT group stalling each period. The rotating straggler is the thing to watch.
#
# DERIVED, not a fork: assigned before including the base, whose definitions are all `?=`.
noc_router_remapping := 2

include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu_8x8.mk
