# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# 8x8, MSHR hold/timeout 2047 with router response remapping.
#
# WHY THIS COMBINATION. Across the whole fleet the two knobs are disjoint: every remap=2 build
# runs hold 511 or 1023, and all seven hold=2047 builds run remap=0. The pair has never been
# measured, and both are individually implicated:
#   * the barrier fix's value scales with the hold window -- +0.4 pp at 255 rising to +15.6 pp at
#     2047, correlation +0.71;
#   * remap=2 showed the fleet's highest utilisation, then both its arms degraded after ~35
#     periods with a rotating straggler.
# Whether they compose, or whether a wider hold window worsens the remap=2 collapse, is untested.
#
# CHANNEL SPLIT IS CHOSEN AT THE COMMAND LINE, not here. The base flavour sets
# `channel_config_mode := baseline` with `:=`, which a derived flavour cannot override by
# pre-assignment (only the individual noc_req_*/noc_resp_* numbers are `?=`). Pass it as a make
# ARGUMENT, which beats a makefile assignment:
#
#   (default, baseline)              -> rd0+rdwr2, resp 2   pairs with fpugir2 / a2047 / build_2
#   channel_config_mode=enhanced     -> rd1+rdwr1, resp 3   pairs with bremap2 / b2047
#                                       (also defines USE_NARROW_REQ_CHANNEL, as those arms have)
#
# Setting the channel numbers by hand instead would give the right counts WITHOUT
# USE_NARROW_REQ_CHANNEL, which is not the same RTL and would not pair cleanly with anything.
#
# DERIVED, not a fork: assigned before including the base, whose definitions are `?=`, so the
# base and the 23 arms currently running are untouched.
group_mshr_hold_window_burst := 2047
group_mshr_serve_timeout     := 2047
noc_router_remapping         := 2

include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu_8x8.mk
