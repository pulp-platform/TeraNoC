# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# BACKEND CONFIG B -- 8x8 mesh (1024 cores, 64 groups), response-remapped.
#
#   mesh          8x8, num_cores 1024, num_groups 64, 1 core/tile
#   NoC channels  baseline: rd 0 + rdwr 2 request, 2 response
#   MSHR hold     2047 (window_burst and serve_timeout)
#   router remap  2 (response remapping)
#
# WHAT DIFFERS FROM THE BASE: response remapping, the stats guard, and merge_reqs (below).
# channel_config_mode baseline (rd 0 + rdwr 2, resp 2), mshr_num 64, hold_subs 4/4 and port_hash 7
# all come from the base unchanged.
#
# CORRECTED 2026-09-13: this header claimed the base shipped hold_window_burst / serve_timeout
# 2047 and merge_reqs 4. Neither is true any more -- terapool_spatz4_fpu_8x8.mk sets none of the
# three, so all of them come from terapool_spatz4_fpu.mk, which now ships 8191 / 8191 / 16. The
# hold values are fine inherited; merge_reqs 16 is a simulation value and is pinned back to 4
# below. Measurements quoted further down predate those base changes.
#
# NOTE the hold window moved 1023 -> 2047 under the standing decision of 2026-08-14 (one value at
# every mesh). This header claimed 1023 until 2026-08-18; the measurements quoted below were taken
# at 1023 and are annotated accordingly.
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
# KNOWN COST, inherited from the base: a long hold window is expensive. Matched pairs at 8x8 show 1023
# costing +22% (D), +82% (F) and +108% (E) in completion cycles versus 511, and the shipped 4x4
# default is 255. The base now carries 2047, which is longer still. If the backend run is meant to
# represent the *best* 8x8 design rather than the *measured* one, hold 255-511 is the better
# operating point and would need only a one-line override here. Note the window is a COUNTER
# WIDTH knob as well as a policy one, so 2047 vs 1023 is one extra flop per entry -- it is not
# PPA-neutral, only nearly so.
#
# DERIVED, not a fork: assigned before the include, and every definition in the base is `?=`.
# If you need a non-default channel split, pass it as a MAKE ARGUMENT
# (`channel_config_mode=enhanced`), never as a pre-assignment.
noc_router_remapping := 2

# Synthesis insurance, and PARITY WITH backend_4x4 -- which has set this since 2026-08-14. The
# stats blocks are contained three ways (`pragma translate_off`, this parameter, `ifndef
# VERILATOR`), but the 4x4 config's own history records a bare translate_off guard leaking into
# synthesis once. Beyond the leak risk: if the two backend configs disagree on this knob, a
# 4x4-vs-8x8 area comparison is measuring the counters as well as the mesh.
# MERGE_REQS: 4 for the backend, against the base's 16 -- an ELABORATION constant, not a tuning
# knob. MshrMergeReqs sizes the per-entry sub_reqs array (mempool_group_mshr.sv:519), so 16 builds
# four times the per-entry storage. Simulation wants 16 because software sets the real target
# through the CSR; every OOC result we have was measured at 4. Kept in step with the 4x4 flavour.
group_mshr_merge_reqs := 4

group_mshr_enable_stats := 0

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

include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu_8x8.mk
