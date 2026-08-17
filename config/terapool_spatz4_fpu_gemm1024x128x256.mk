# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
# 4x4 flavour for the 1024x128x256 GEMM -- batch-ladder rung, share_a=2 share_b=8
# (docs/paper_plan_llm_inference.md 4.1).
#
# Values are scripts/gemm_autotune.py output, not hand-picked. DERIVED, not a fork:
# assigned BEFORE the include; every base definition is `?=`.
group_mshr_bank_burst_bits       := 1
group_mshr_bank_shift_burst      := 7
group_mshr_bank_shift_single     := 7
group_mshr_hold_subs_burst       := 8
group_mshr_hold_subs_single      := 2
group_mshr_merge_reqs            := 8
include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu.mk
