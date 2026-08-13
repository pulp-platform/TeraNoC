# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
# 4x4 flavour with the MSHR provisioned for the 1024x128x128 GEMM.
#
# Values are NOT hand-picked: they are what
#   scripts/gemm_autotune.py -M 1024 -N 128 -P 128
# emits. Running a shape on another shape's knobs under-provisions the MSHR and pins
# utilisation at ~24-27% regardless of N -- see the 256x512x256 flavour's note.
#
# DERIVED, not a fork: assigned BEFORE the include; every base definition is `?=`.
group_mshr_merge_reqs        := 8
group_mshr_hold_subs_single  := 2
group_mshr_hold_subs_burst   := 8
group_mshr_bank_shift_burst  := 6
group_mshr_bank_shift_single := 7
include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu.mk
