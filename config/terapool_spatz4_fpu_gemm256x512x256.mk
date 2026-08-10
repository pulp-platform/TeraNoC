# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# 4x4 flavour with the MSHR provisioned for the 256x512x256 GEMM.
#
# WHY THIS EXISTS. The stock terapool_spatz4_fpu ships the tuning for 512x512x512, with the
# other shapes' values commented out beside them. Running 256x512x256 on the stock knobs
# under-provisions the MSHR and pins utilisation at ~24-27% regardless of N -- which is exactly
# what happened on 2026-08-10 and was briefly mistaken for a 3.49x RTL regression. The 2026-08-01
# sweep that recorded 94.1% for this shape used the RETUNED values below, not the stock ones.
#
# Values are NOT hand-picked: they are what `scripts/gemm_autotune.py -M 256 -N 512 -P 256`
# emits, and they match the commented-out "M=256" lines in the base flavour.
#
#   dim_group=16, split_m_count=2, split_p_count=8   =>  A shared 8-way, B shared 2-way
#
#     merge_reqs        = max(A-share, B-share)        = 8   (stock 4 -- under by 2x)
#     hold_subs_single  = A-share                      = 8   (stock 4 -- under by 2x)
#     hold_subs_burst   = B-share                      = 2   (stock 4)
#     bank_shift_burst  = clog2(P / split_p_count)     = 5   (stock 7)
#     bank_shift_single = clog2(N)                     = 9   (stock 9 -- already correct)
#
# Neither share degree is 1, so none of the clamp-to-2 / zero-the-hold-window special cases
# in the base flavour apply here.
#
# DERIVED, not a fork: every knob is assigned BEFORE including the base flavour, whose own
# definitions are all `?=`, so these win and everything else stays in lockstep.
group_mshr_merge_reqs        := 8
group_mshr_hold_subs_single  := 8
group_mshr_hold_subs_burst   := 2
group_mshr_bank_shift_burst  := 5
group_mshr_bank_shift_single := 9

include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu.mk
