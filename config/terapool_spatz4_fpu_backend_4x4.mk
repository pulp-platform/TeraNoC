# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# BACKEND CONFIG A -- 4x4 mesh (256 cores, 16 groups), tuned for a 512x512x512 matmul.
#
#   mesh          4x4, num_cores 256, num_groups 16, 1 core/tile
#   NoC channels  baseline: rd 0 + rdwr 2 request, 2 response
#   MSHR hold     2047 (window_burst and serve_timeout)
#   router remap  2 (response remapping, inherited from the base)
#
# ONLY THE HOLD WINDOW DIFFERS FROM THE BASE FLAVOUR. terapool_spatz4_fpu.mk already ships every
# other value this config needs, and its own comments name them as the 512x512x512 presets:
#
#   group_mshr_merge_reqs       = 4   "512x512x512 (default): A 4-way, B 4-way -> max = 4"
#   group_mshr_hold_subs_single = 4   "512x512x512 (default): A 4-way, B 4-way"
#   group_mshr_hold_subs_burst  = 4
#   group_mshr_bank_shift_burst = 7   "512x512x512 (default): P/split_p_count = 512/4 = 128 -> 7"
#   noc_router_remapping        = 2   (base default since 2026-08-14)
#   channel_config_mode         = baseline  (rd 0 + rdwr 2, resp 2)
#
# So this file sets two knobs and inherits the rest. Do NOT copy the base's values in here: a
# fork would silently drift the moment the base is retuned, which is exactly how a shape-matched
# config stops matching its shape.
#
# DERIVED, not a fork: assigned before the include, and every definition in the base is `?=`,
# so these win. (`channel_config_mode` is also `?=` in the base and already defaults to
# baseline, so it needs no override here -- but if you ever need a non-default channel split,
# pass it as a MAKE ARGUMENT, e.g. `channel_config_mode=enhanced`, not as a pre-assignment.)
#
# hold=2047, per the standing decision of 2026-08-14 (see terapool_spatz4_fpu.mk). This file
# previously pinned 511 with a note arguing that shorter windows complete faster -- that note is
# superseded: the value is now uniform across 4x4 and 8x8 so that configs differ in the thing under
# test and not in the hold window as well.
group_mshr_hold_window_burst := 2047
group_mshr_serve_timeout     := 2047

# Synthesis insurance. The stats blocks are contained three ways -- `pragma translate_off`, this
# parameter, and `ifndef VERILATOR` -- and all eight stats always_ff sit inside translate_off, so
# they should never reach a netlist. But this file's own history records a bare translate_off guard
# leaking into synthesis once (mempool_group_mshr.sv:2458-2464), and the base flavour defaults this
# to 1 because simulation wants the counters. Cost of being wrong is silent area in every group;
# cost of setting it is nothing the backend needs. After elaboration, confirm with
#   sizeof_collection [get_cells -hier *stat_*]
# and if that is non-zero the guard leaked again and translate_off is not sufficient on its own.
group_mshr_enable_stats      := 0

# ---------------------------------------------------------------------------------------------
# REVERSED 2026-08-23 (user decision): the tape-out DOES enable the runtime CSR config.
#
# The pin below used to force this to 0, to keep mempool_group_mshr_cfg const-folding away to
# nothing -- "every field const-folds to its default and the whole file disappears" (the module's
# own note), bit-identical to the pre-CSR design, verified as gate V1 in
# docs/mshr_runtime_csr_verification.md (34,596 == 34,596). At 1 it becomes real CSR flops per
# group. That area is now bought deliberately.
#
# WHY. The MSHR tuning is derived per shape from GEMM_M/N/P (software/runtime/mshr_cfg.h), and a
# single chip runs eleven differently-shaped Qwen operations back to back under ONE configuration
# (docs/qwen38_kernel_mapping.md sec 6.1). At CfgRuntime=0 the elaborated constant serves all of
# them and ten run mistuned; at 1, software retunes per operation through CSR 11. It also makes
# every per-shape number measured in simulation transferable to silicon -- at 0 those arms are
# evidence for a part we would not be building.
#
# COST. CSR flops per group, x16 groups at 4x4 and x64 at 8x8. Quantify it in the next backend
# run and record it here; if it proves large, the fallback is to keep the CSRs but narrow the
# fields, not to go back to const-folding.
group_mshr_cfg_runtime := 1

include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu.mk
