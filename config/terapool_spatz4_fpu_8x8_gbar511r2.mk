# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# 8x8 GUI/waveform flavor: hold 511 + response remapping, group barrier ON.
#
# DERIVED, not a fork. Every knob is assigned here BEFORE including the base 8x8 flavor,
# whose own definitions are all `?=`, so these win and everything else stays in lockstep
# with terapool_spatz4_fpu_8x8.mk. Editing that base file instead would silently change the
# defaults for the 73 sweep arms currently running (and any rebuild they might trigger),
# which is why this exists as a separate flavor.
#
# The group barrier needs NO knob: the RTL enables it unless -DGROUP_BARRIER_OFF, and the
# software's GBAR_PLOOP defaults to 1. It is on here by omission.
#
# NOTE ON THE EVIDENCE, recorded so this file is not mistaken for a tuned optimum:
#   * hold=511 is the user's choice. Every completed hold-255 arm beat every completed
#     hold-511 arm (255: 557,963 / 658,216 / 661,490 vs 511: 801,080 ... 866,235), though
#     all of those were measured with the group barrier silently dead (see WORKLOG
#     2026-08-10) and v10's 255 win is confounded with 3resp and COLDSTART=0.
#   * noc_router_remapping=2 has NO throughput evidence. Its reputation comes from FGIR2's
#     85.2% plateau -- the best in the sweep -- but plateau correlates +0.82 with being
#     SLOWER across all eight completions, and no remap=2 arm has ever finished. It is a
#     good choice for OBSERVING the mechanism in a waveform, not an established optimum.
group_mshr_hold_window_burst := 511
group_mshr_serve_timeout     := 511
noc_router_remapping         := 2

include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu_8x8.mk
