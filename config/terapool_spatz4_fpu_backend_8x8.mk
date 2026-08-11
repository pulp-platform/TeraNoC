# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# BACKEND CONFIG B -- 8x8 mesh (1024 cores, 64 groups), response-remapped.
#
#   mesh          8x8, num_cores 1024, num_groups 64, 1 core/tile
#   NoC channels  baseline: rd 0 + rdwr 2 request, 2 response
#   MSHR hold     1023 (window_burst and serve_timeout)
#   router remap  2 (response remapping)
#
# ONE KNOB DIFFERS FROM THE BASE. terapool_spatz4_fpu_8x8.mk already ships hold_window_burst 1023,
# serve_timeout 1023, and channel_config_mode baseline (rd 0 + rdwr 2, resp 2), so response
# remapping is the entire delta. mshr_num 64, merge_reqs 4, hold_subs 4/4 and port_hash 7 all
# come from the base unchanged.
#
# This is byte-for-byte the configuration of the `fpugir2` arm and of build_g54diag -- verified
# against build_fpugir2/compilevcs.sh define-by-define -- so every measurement below applies to
# what this file builds.
#
# WHAT IS KNOWN ABOUT THIS CONFIGURATION (2026-08-11):
#
#  * remap=2 is +4.1% FASTER than remap=0 on the one clean matched pair that has completed:
#    IREMAP2 1,432,655 cycles vs A1023 1,493,883, identical hold/split/resp with remap the only
#    variable. The remap=0 baseline is reproduced EXACTLY by three arms (A1023, PA1023, XA1023),
#    and duplicate configs across the fleet complete at byte-identical cycle counts, so
#    run-to-run variance is zero and a 61,228-cycle gap is signal. A second matched pair
#    (BREMAP2 vs B1023, the enhanced-channel split) is still running.
#  * It holds the fleet's best barrier-release concentration after the first barrier
#    (6.4 releases/period vs 4.5-5.3 for every other arm) -- i.e. its groups stay the most
#    synchronised of any configuration measured.
#
# KNOWN COST, inherited from the base: hold=1023 is expensive. Matched pairs at 8x8 show 1023
# costing +22% (D), +82% (F) and +108% (E) in completion cycles versus 511, and the shipped 4x4
# default is 255. This config keeps 1023 as requested, but if the backend run is meant to
# represent the *best* 8x8 design rather than the *measured* one, hold 255-511 is the better
# operating point and would need only a one-line override here.
#
# DERIVED, not a fork: assigned before the include, and every definition in the base is `?=`.
# If you need a non-default channel split, pass it as a MAKE ARGUMENT
# (`channel_config_mode=enhanced`), never as a pre-assignment.
noc_router_remapping := 2

include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu_8x8.mk
