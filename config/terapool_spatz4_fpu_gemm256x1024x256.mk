# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
# 4x4 flavour for the 256x1024x256 GEMM (96.0% util in docs/benchmarks/gemm_results.md).
#
# Values are scripts/gemm_autotune.py output, not hand-picked. DERIVED, not a fork:
# assigned BEFORE the include; every base definition is `?=`.
group_mshr_bank_burst_bits       := 1
group_mshr_bank_shift_burst      := 5
group_mshr_bank_shift_single     := 10
group_mshr_hold_subs_burst       := 2
group_mshr_hold_subs_single      := 8
group_mshr_merge_reqs            := 8
include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu.mk
