# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
# 4x4 flavour for the 2048x128x256 GEMM -- batch-ladder rung, share_a=1 share_b=16
# (docs/paper_plan_llm_inference.md 4.1).
#
# Values are scripts/gemm_autotune.py output, not hand-picked. DERIVED, not a fork:
# assigned BEFORE the include; every base definition is `?=`.
group_mshr_bank_burst_bits       := 1
group_mshr_bank_shift_burst      := 8
group_mshr_bank_shift_single     := 7
group_mshr_hold_subs_burst       := 16
group_mshr_hold_subs_single      := 1
group_mshr_merge_reqs            := 16
group_mshr_hold_window_single    := 0
group_mshr_resp_wait_subs_single := 0
include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu.mk
