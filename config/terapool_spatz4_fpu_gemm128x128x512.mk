# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
# 4x4 flavour for the 128x128x512 GEMM (83.7% util in docs/benchmarks/gemm_results.md).
#
# Values are scripts/gemm_autotune.py output, not hand-picked. DERIVED, not a fork:
# assigned BEFORE the include; every base definition is `?=`.
#
# B IS 1-WAY SHARED. hold_subs_burst clamps to 2, which a 1-way-shared line can never
# reach, so ANY non-zero burst hold window is a pure stall -- every burst entry waits the
# full window and times out. Measured: forcing 2047 here cost >+300%. Pin it to 0.
group_mshr_hold_window_burst := 0
group_mshr_bank_burst_bits       := 1
group_mshr_bank_shift_burst      := 5
group_mshr_bank_shift_single     := 7
group_mshr_hold_subs_burst       := 1
group_mshr_hold_subs_single      := 16
group_mshr_hold_window_burst     := 0
group_mshr_merge_reqs            := 16
include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu.mk
