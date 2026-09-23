# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Matheus Cavalcante, ETH Zurich

# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Matheus Cavalcante, ETH Zurich

config_build_path ?= terapool

###########################
## 1. Architecture Config
###########################

# Global Control
terapool ?= 1

# Number of cores
num_cores ?= 256

# Number of groups
num_groups ?= 16

# Number of cores per Terapool tile
num_cores_per_tile ?= 1

# L1 scratchpad banking factor
banking_factor ?= 4

# Number of shared divsqrt units per MemPool tile
# Defaults to 1 if xDivSqrt is activated
num_divsqrt_per_tile ?= 0

#####################
## 2. NoC Config
#####################

# FlooNoC configuration
num_directions ?= 5
num_x          ?= 4

# Topology
# 0: 2D mesh, 1: torus
noc_topology ?= 0

# Routing algorithm
# 0: xy, 1: odd-even, 2: o1
noc_routing_algorithm ?= 0

# NoC remapping configuration
# 0: no remapping, 1: req remapping, 2: resp remapping 3: req+resp remapping
#
# 2 (response remapping) is the default as of 2026-08-14, by decision -- it aligns 4x4 with
# terapool_spatz4_fpu_backend_8x8.mk, which has pinned 2 for some time, so both meshes now differ
# in the thing under test rather than in the remapper as well.
#
# CAVEAT, recorded so this is not mistaken for a measured optimum. The note in
# terapool_spatz4_fpu_8x8_gbar511r2.mk states that remapping=2 has NO throughput evidence at 8x8:
# its reputation comes from arm FGIR2's 85.2% utilisation plateau -- the best in that sweep -- but
# plateau correlates +0.82 with being SLOWER across all eight completions there, and no remap=2 arm
# had ever finished. fpugir2 also reached ~90.5% cumulative and then DEGRADED to 86.8% after ~35
# periods, with a different group stalling each period. That evidence is 8x8 and about throughput;
# it says nothing about 4x4 or about area.
#
# What it does cost physically: gen_resp_remapping in mempool_group_floonoc_wrapper.sv:576
# elaborates only for values 2 and 3, so this adds the response remapper to every group. That is a
# real area delta the backend will now see -- intended, but it is a change to what gets synthesised.
#
# The three in-flight PPA sweeps were all built with 0 and are NOT comparable to builds made after
# this commit. Re-baseline before comparing across it.
noc_router_remapping ?= 3

# Hash-based port spreading at tile level (bitmask)
#   bit0 (1): req port hash     — spread req across remote req ports
#   bit1 (2): resp temporal RR  — rotate resp port across cycles (resp_rr_q)
#   bit2 (4): resp spatial RR   — offset resp port by bank id within a cycle,
#                                 so multiple remote-destined bank responses
#                                 in the same cycle spread across resp ports
# Common values: 0 none, 3 req+temporal, 6 temporal+spatial, 7 all
noc_port_hash ?= 7

# Virtual channel number
noc_virtual_channel_num ?= 1

# Channel configuration mode (internal control only)
# Options: baseline, narrow, enhanced
channel_config_mode ?= baseline  # Change this value to switch modes

# Channel configuration based on selected mode
ifeq ($(strip $(channel_config_mode)), baseline)
# Baseline config, do NOT define USE_NARROW_REQ_CHANNEL
noc_req_rd_channel_num   ?= 0
noc_req_rdwr_channel_num ?= 2
noc_req_wr_channel_num   ?= 0
noc_resp_channel_num     ?= 2

else ifeq ($(strip $(channel_config_mode)), narrow)
# Reduced req link count, define USE_NARROW_REQ_CHANNEL
noc_req_rd_channel_num   ?= 1
noc_req_rdwr_channel_num ?= 1
noc_req_wr_channel_num   ?= 0
noc_resp_channel_num     ?= 2

else ifeq ($(strip $(channel_config_mode)), enhanced)
# Enhanced resp link, define USE_NARROW_REQ_CHANNEL
noc_req_rd_channel_num   ?= 1
noc_req_rdwr_channel_num ?= 1
noc_req_wr_channel_num   ?= 0
noc_resp_channel_num     ?= 3

else
$(error Unsupported channel_config_mode: $(channel_config_mode))
endif

# Print configuration info for debugging
$(info [DEBUG:][noc_req_rd_channel_num]----$(noc_req_rd_channel_num))
$(info [DEBUG:][noc_req_rdwr_channel_num]--$(noc_req_rdwr_channel_num))
$(info [DEBUG:][noc_req_wr_channel_num]----$(noc_req_wr_channel_num))
$(info [DEBUG:][noc_resp_channel_num]------$(noc_resp_channel_num))

# Router buffer configuration
noc_router_input_fifo_dep  ?= 2
noc_router_output_fifo_dep ?= 2

# Router remapping xbar size configuration
noc_router_remap_group_size ?= 4

# Tile ID remapping (0=disabled).
tile_id_remap ?= 0

#####################
## 2b. Group MSHR  ##
#####################
# Number of MSHR entries per group (peak outstanding remote bursts).
# 32 = 8 banks x 4 ways (user's area-halving experiment; run by hand). CAUTION: earlier runs
# measured 32 entries collapsing the matmul ~14x (54.5k cyc, barrier-write congestion) with BOTH
# the fold and the field-select hash -- terapool has 16 tiles x 2 remote req ports = 32 concurrent
# request slots, so 32 entries has ~zero headroom. 64 (16 banks x 4 ways) was the measured-safe
# value; revert to 64 if the collapse reproduces.
# Runtime-configurable group MSHR (docs/mshr_runtime_csr_design.md).
#   0 = fixed-function. Every CSR const-folds to its elaborated default and the register file has no
#       storage, so the build is BIT-IDENTICAL to the pre-CSR design -- verified twice at exactly
#       34,596 cycles (V1, and V1-redo after the guard/width fixes).
#   1 = software-writable. The MSHR then ships DISABLED out of reset and software must program and
#       enable it before the timed region; a binary that does not costs +55.6% (measured), which the
#       [MSHRCFG] testbench line reports at benchmark start.
#
# DEFAULT 1 since 2026-08-20 (user request): the per-shape MSHR tuning is written by
# mshr_cfg_apply_group() at runtime, so a build without CSRs silently ignores it and runs the
# elaborated values instead. Reset `enable=0` means init/DMA/I$ warm-up still never allocate.
#
# The previous comment here claimed an "unexplained 3-12x slowdown on 512x256x512 and 128x128x512"
# and cited docs/mshr_runtime_csr_verification.md. That citation does not support it: the doc's V1
# gate is bit-identical (34,596 == 34,596) and V3 reports MSHR work counters BYTE-IDENTICAL with a
# +265 cyc (+0.77%) cold-start cost. The only ~12x in the repo is the MSHR desync trap in
# gemm_results_vs_nofeature.txt -- a different mechanism, not attributed to the CSR path.
# The real risk the old comment named IS valid and is handled below: at CfgRuntime=1 the config
# file stops const-folding, so the backend flavours pin it back to 0 explicitly.
group_mshr_cfg_runtime   ?= 1

# ---- Group MSHR organisation: ONE switch, two knob sets -----------------------------------------
# group_mshr_split = 1 (default since 2026-09-22): eight 4-tile SLICES per group, rows R_k = tiles
#   4k..4k+3 and columns C_k = tiles k,k+4,k+8,k+12 (hardware/src/mempool_group_mshr_slice.sv,
#   docs/mshr_split_design.md). A request is steered to its row or column slice by CLASS
#   (single/burst; CSR 12 steer_single_row, written by software from the prefill/decode split) and
#   bypass traffic by tile parity, so every slice has 4 NoC lanes and 8 tile lanes. Measured on
#   512x128x128 fp32 prefill: 11,199 vs 12,374 legacy cycles (-9.5 %); qwen-gate-up B16: +1.1 %.
# group_mshr_split = 0: the legacy single 32-lane group MSHR.
# The entry knobs below are PER MSHR INSTANCE, so the two sets differ: 8+1 entries per slice is the
# same 64+8 per group as the legacy module. Software reads the same variables (runtime.mk ->
# MSHR_CFG_ENTRIES / MSHR_CFG_SPLIT), so selecting the switch here configures HW and SW together;
# nothing has to be repeated on the make command line.
group_mshr_split         ?= 1
ifeq ($(strip $(group_mshr_split)),1)
  # --- split: per SLICE ---
  group_mshr_num           ?= 8    # entries per slice (8 slices -> 64 per group)
  group_mshr_ways_per_bank ?= 4    # banks per slice = 8 / 4 = 2
  group_mshr_overflow_num  ?= 1    # unbanked overflow entries per slice (8 per group)
  # Reset value of CSR 12; software overwrites it from the split (1 = prefill, 0 = decode).
  group_mshr_steer_single_row ?= 0
else
  # --- legacy: ONE module per group ---
  group_mshr_num           ?= 64
  # Ways (entries) per bank; banks = group_mshr_num / group_mshr_ways_per_bank. 16 entries / 2 ways
  # = 8 banks x 2 ways (user experiment). WARNING: 16 entries is HALF of the 32 concurrent request
  # slots (16 tiles x 2 remote ports) -- 32 entries already collapsed the matmul ~14x, so 16 is very
  # likely to collapse harder. Revert to 64 (16 banks x 4 ways) for the measured-safe design.
  group_mshr_ways_per_bank ?= 4
  # Unbanked overflow entries. Allocated ONLY when a request's hashed bank has no free way -- and
  # that test already includes the cache-reclaim pass, so a bank holding a reclaimable cached way is
  # not "full" and the pool stays free for the case it exists for: a cohort that holds every way of
  # one bank while the request which would complete it hashes to that same bank, which otherwise
  # only ends at the serve timeout. 0 removes the pool entirely (netlist identical to the design
  # without it).
  group_mshr_overflow_num  ?= 8
endif
# Max sub-requests coalesced into one MSHR entry.
# MUST be max(A-share, B-share), where A-share = split_p_count and B-share =
# split_m_count. The two INVERT with M: at M<=256 A is the shared matrix, at
# M>=1024 it is B. Derive with `scripts/gemm_autotune.py -M .. -N .. -P ..`.
# Under-provisioning does not merely slow things down -- it removes N-amortisation
# and pins utilisation at ~24% regardless of N.
#   M=256 (A 8-way, B 2-way) -> 8      M=512  (A 4-way, B 4-way)  -> 4
#   M=128 (A 16-way,B 1-way) -> 16     M=1024 (A 2-way, B 8-way)  -> 8
# group_mshr_merge_reqs    ?= 8      # 256x512x256: A 8-way, B 2-way
# group_mshr_merge_reqs    ?= 8      # 1024x128x128: A 2-way, B 8-way
# group_mshr_merge_reqs    ?= 16     # 128x1024x512 (best measured 96.8%): A 16-way, B 1-way
# 512x512x512 (default): A 4-way, B 4-way -> max = 4
# Sim convention: MERGE_REQS is elaboration-only and the SW sets the real target via CSR
# (group_mshr_cfg_runtime=1 above), so 16 is the sizing every sweep image was built with.
# Only a backend run needs the true merge number here.
group_mshr_merge_reqs    ?= 16
# Admit single-word reqs into MSHR merge pool (1) or let them bypass (0).
# Set to 1 (design intent: single-word loads coalesce + multicast via the MSHR).
# The earlier sporadic sp-fmatmul deadlocks attributed here to a "duplicate-entry
# allocation when a CACHED entry exists for the same address" were investigated
# and that hypothesis was ruled out: a CACHED entry always retains its buffered
# response (resp_buf_cnt>0/resp_valid=1), so a single-word load to a cached
# address ALWAYS takes the merge/hit path and can never allocate a second entry
# (verified by the cached_entry_holds_data assertion in mempool_group_mshr.sv).
# (Same-address entries with different meta_ids are legitimate and not a dup.)
# The real causes were the VLSU force_send single-beat
# wedge, the burst-tail->store counter corruption, and the AMO/response-cache
# race -- all now fixed (spatz_vlsu.sv, mempool_group_mshr.sv). See
# bottleneck_analysis/ for the audit/investigation.
group_mshr_enable_single ?= 1
# Emit MSHR internal [MSHR stats] via $display (sim-only).
group_mshr_enable_stats  ?= 1
# Stats print period (cycles) while csr_trace is active (0 = final dump only).
group_mshr_stats_period  ?= 2000

# Response-drain width per MSHR entry (ParityDrain: 2-wide burst receive).
# 1 = legacy single-beat drain (bit-identical netlist; all beat-parity logic const-folds
# out). 2 = OPT IN to 2 beats/cycle: beat b is delivered on tile resp port 1+(b&1) with
# core_id+(b&1). The wire contract is unchanged (meta_id = base+b, one contiguous range),
# so entries stay FULLY MERGEABLE -- coalescing is untouched. Requires
# noc_resp_channel_num >= 2; only 1 and 2 are legal (elaboration $error otherwise).
# Single source of truth: also drives the tile->VLSU NumRespPorts (mempool_tile
# MshrDrainBeats). Measured on sp-fmatmul-opt-burst-merge: 4453 -> 4009 cyc (1.11x), and
# 3836 (1.16x) together with the bypass-retag table and no per-step barrier.
# See docs/respbw_paritydrain_design.md.
group_mshr_drain_beats   ?= 2

# Hold-the-fetch request-hold merge window (docs/mshr_request_hold_design.md).
# 0 = OFF: every allocation issues its NoC fetch the same cycle (all hold logic
# const-folds out). Any W > 0 withholds a mergeable allocation's fetch for up to W
# cycles, releasing early once the entry reaches its subscriber target -- extending the
# MSHR merge window by exactly the held cycles. There is no upper bound: the hold
# counter is sized from W ($clog2(W+1)). Large-W notes: way occupancy and door-conflict
# stalls both scale with W, and W near the TB scoreboard's 1000-cycle stuck threshold
# will produce [CMS WARN] noise.
# KEEP 0 ON THIS WORKLOAD: measured net-negative at every W (3836 OFF -> 3986 / 4209 /
# 4229 at W = 8 / 16 / 24). Measured root cause (design doc 5c): same-line partners are
# iteration-scale apart (>60 cycles), so 70-85% of held entries time out and pay the full
# W in latency for nothing, while the extra way occupancy crowds out allocations
# (bank-full overflow 42% -> 51%). sp-fmatmul is latency-bound; coalescing saves NoC
# traffic, which is not the scarce resource here.
group_mshr_hold_window   ?= 0
# Per-request-type hold windows (override the uniform group_mshr_hold_window above).
# A 0 window = that class issues its fetch the same cycle (no hold). (The uniform
# value above only applies to a class that has no override.)
# 8191 (was 0): give a single cohort that CAN form long enough to converge. Only meaningful where
# hold_subs_single > 1; a bypass shape (target 1) never allocates, so this is inert there.
group_mshr_hold_window_single ?= 8191
# STANDING DECISION 2026-08-14: 2047 everywhere, 4x4 and 8x8 alike. Previously the tree carried
# five different values (base 255, backend_4x4 511, 8x8 1023, plus 511/2047 experiment flavours),
# so "the hold window" meant something different in almost every run and cross-config comparisons
# were not like-for-like. One value ends that.
# Silicon cost of 2047 over 255: hold_cnt widens 4 -> 7 bits (HoldCntTicks = 2047>>4 = 127), i.e.
# +192 flops/group, ~3k cluster-wide. The replay walker exists for ANY non-zero window, so its
# cost is unchanged by this.
# 8191 (was 2047): the burst cohort is the one that can actually form on the can-burst shapes --
# e.g. fp16_4096x32x512, burst target 8, B slice 512 B, 8 cores genuinely sharing the line. 2047
# was not long enough for them to converge. Shapes below the 64 B burst floor are NOT helped by
# this and should be kept out of sweeps (rh_livelock_root_cause.md section 0).
group_mshr_hold_window_burst  ?= 8191
# Prescaler for the hold/serve countdown, in BITS. Each entry stores its window in ticks of
# 2**W cycles instead of cycles, so hold_cnt loses W bits and toggles 2**W times less often;
# entry e takes its tick when the shared prescaler equals e[W-1:0], which spreads expiries
# instead of releasing every held fetch on one grid tick. 0 = exact cycle-accurate countdown.
#
# Pinned here rather than left to the RTL default so it is visible in a config and lands in
# every build's define list. `?=` because derived flavours assign before including this file.
#
# Measured on the 4x4 tuned config (one matched pair, one workload -- suggestive, not settled):
#   W=0  34629 cycles   W=4  34417 cycles  (0.61% faster), and 4 bits x MshrNum fewer flops
#   per group -- ~16.1k at 8x8. Equivalence with W=0 proven bit-exact over all 35 periods.
# 6 (was 4): hold_cnt ticks once per 2**6 = 64 cycles. This makes the LONGER window CHEAPER, not
# more expensive: HoldCntTicks = MshrCfgHoldCntMax >> PrescaleW = 8191>>6 = 127, so the counter is
# 7 bits against the 8 it took at 4095>>4 = 255. The cost is granularity -- a window is quantised
# to 64 cycles, and hold_ticks() never rounds a non-zero window down to zero.
group_mshr_hold_prescale_w ?= 6

# Source the response-drain eligibility scan from the REGISTERED entry array (mshr_q) instead of
# the combinational next state (mshr_d). The scan sits at the end of the same always_comb that
# computes mshr_d, behind 86 writes to it, so today the response path does not start at a flop:
#   mshr_q -> [allocate/merge/admit/cache/self-invalidate] -> mshr_d -> [drain scan] -> resp_out
# Reading mshr_q cuts that entire cone out of the path.
#
# Cost is purely latency: an entry that becomes drainable in cycle N is seen in N+1. Safe because
# each sub-request has exactly one destination (tile, port), so a stale view cannot let two ports
# drain the same sub-request. 0 = off (bit-identical to before), 1 = registered scan.
#
# DEFAULT IS 1 BECAUSE THE 0 PATH IS NOT PHYSICALLY FEASIBLE, not because it is faster.
# At 0 the drain arbitration is rooted behind the whole mshr_d update network (~132 dynamic-index
# writes into the 64-entry array, in program order) and does not close timing. At 1 it is rooted at
# flop outputs. This is a closure requirement; the cycle effect is the price, not the reason.
#
# Measured cycle cost at 4x4 (matched pairs, same ELF, single define apart):
#     256x512x256    34,715 -> 34,577   -0.40%   (faster)
#     1024x128x128   60,447 -> 59,548   -1.49%   (faster)
#     128x1024x512   67,529 -> 68,713   +1.75%   (SLOWER -- the near-roofline shape, 97% -> 95%)
#     512x512x512    pending
# So the worst case is +1.75% cycles. Since wall-clock is cycles x period, enabling this pays for
# itself as long as the registered scan buys more than ~1.75% of Fmax -- and if the 0 path cannot
# close at all, the comparison is against a design that does not exist.
#
# NOTE FOR FUTURE EQUIVALENCE RUNS: the 34,715-cycle reference was taken at drain_from_q=0. With
# this default at 1 the baseline for 256x512x256 is 34,577; do not compare a new arm against 34,715
# unless it explicitly sets group_mshr_drain_from_q=0.
group_mshr_drain_from_q ?= 1

# opt3: each MSHR bank publishes ONE entry per cycle (round-robin over its ways),
# port-independently. Preserves multicast (an entry, not a sub-request, is published)
# but caps distinct entries drained per cycle at the bank count.
#
# DEFAULT 1 FOR PHYSICAL FEASIBILITY, and the frontend cost is NOT small -- read before changing.
# With B0.3 (ed1e5dd2) this narrows the drain arbitration 4x: MshrBankNum(16) candidates instead of
# MshrNum(64), in both the per-(tile,port) predicate work and the rotate/prefix tree. B0.3 is proven
# cycle-identical to the stage-1 behavioural model (34,538 cyc, 35/35 periods byte-identical), so
# the narrowing itself is free -- the cost below belongs entirely to the publish cap.
#
# Measured at 4x4, hold=255, drain_from_q=0, matched pairs against the same baseline:
#     256x512x256    34,715 -> 34,538   -0.51%   faster
#     1024x128x128   60,447 -> 59,114   -2.21%   faster
#     128x1024x512   67,529 -> 68,096   +0.84%
#     512x512x512   153,446 -> 185,972  +21.20%  <-- see below
#
# THE 512x512x512 REGRESSION IS A DEFECT, NOT A TRADE-OFF, AND IT IS UNRESOLVED. Per-group data:
# fifteen of sixteen groups sit within +-1 pp of baseline; group 8 alone falls from 91.94% to
# 67.91%, collapsing at ~cyc 62,000, running at 30-45% for ~76,000 cycles, then recovering fully at
# ~cyc 142,000. A capacity cap would depress all groups slightly; this is one group starving, which
# points at the per-bank round-robin publish rather than the 16-entry cap. Root cause not found.
#
# Enabled anyway on the same grounds as drain_from_q: the drain arbitration has to shrink for the
# design to close, and a frontend cost is the price. If the g8 starvation is fixed the cost should
# fall; if it cannot be, the recorded fallback is TWO candidates per bank (cap 32 = the port count,
# selector still halves 64 -> 32) -- see docs/mshr_ppa_plan.md B0.3.
group_mshr_bank_publish ?= 1

# Accept at most one MERGE per MSHR bank per cycle, mirroring the per-bank single ALLOCATION the
# arbiter has always enforced. Removes the NumAllocSlots^2 merge-rank comparator network from the
# request door (see OneMergePerBank in mempool_group_mshr.sv). Losers stall one cycle and retry
# against the same resident entry, so coalescing is preserved; set 0 to restore the old form.
group_mshr_one_merge_per_bank ?= 1

# Meta-range overlap computed once per ENTRY rather than once per (lane, entry). Exact -- an entry
# has exactly one owner tile, so 63 of every 64 per-lane replications were structurally dead.
group_mshr_meta_ovlp_by_owner ?= 1

# Extend the head-beat drain's bank publication to the second-slot (drain2) selector, so each lane
# arbitrates over MshrBankNum published entries instead of MshrNum.
group_mshr_drain2_bank_publish ?= 1

# Arbitrate response capture per bank instead of per entry (4x fewer arbiters). Trades some
# response throughput; [CAPARB] cap_wanted/cap_fired measures it. Set 0 to restore per-entry.
group_mshr_cap_per_bank ?= 1

# Source the ParityDrain second-slot scan and the hold-the-fetch replay walker from the REGISTERED
# array. This decouples the tail from the request door: the critical path becomes
# max(door+capture, tail) instead of their sum. Cost measured on 256x256x256: +2.7% cycles (a beat
# captured this cycle becomes second-slot drainable next cycle); free on 256x32x256.
group_mshr_drain2_from_q ?= 1
group_mshr_replay_from_q ?= 1

# C2: bypass the request-input spill register. The tile already registers its request output, and
# only wire assigns separate the two -- so this stage is a second register back-to-back with the
# first, costing 32 x 166 = 5,312 flops/group (~85k cluster) for no data-path benefit.
#
# It was gated on C1: bypassing exposes the tile's spill to req_in_ready, which used to carry the
# up-to-32-deep serial merge read-modify-write. C1 replaced that with a prefix rank against the
# registered array, so the ready path is shallow now.
#
# NOT bit-identical -- it removes a pipeline stage, so request arrival shifts by a cycle. Needs a
# performance run, not an equivalence run. 0 = bypassed (the saving), 1 = spill present.
#
# The other three spills stay: req_out is the only register between the replay path and the NoC,
# resp_out is documented deadlock-relevant (mempool_group_mshr.sv:1067-1072) and feeds a
# fall_through_register that is combinational when empty, and bypassing resp_in would compose the
# router output crossbar onto the capture->drain arc.
group_mshr_spill_req_in ?= 0
# Early-release subscriber target: a held entry issues its fetch as soon as this many
# requesters have merged into it. Legal range [2, group_mshr_merge_reqs].
group_mshr_hold_subs     ?= 2
# Per-request-type overrides of group_mshr_hold_subs: _single applies to 1-word scalar
# entries (A-line flw, natural sharing degree 8), _burst to multi-beat vector entries
# (B-line, degree 2). Default: inherit the uniform target above.
# single=8 / burst=2 measured 4167 (W=16) and 4354 (W=24, worst point of the sweep):
# singles essentially never reach 8 subscribers in-window, so a higher target only
# lengthens the timeout path.

# _single = A-share = split_p_count, _burst = B-share = split_m_count, each CLAMPED
# to the legal range [2, group_mshr_merge_reqs]. A raw share degree of 1 is ILLEGAL
# (elaboration $error in mempool_group_mshr.sv): Verilator does not enforce it and
# will happily run, QuestaSim refuses to elaborate. When a share degree is 1, clamp
# to 2 AND zero that class's hold window -- and for the SINGLE class also set
# group_mshr_resp_wait_subs_single=0, because that gate blocks DELIVERY on the
# subscriber target independently of the hold window (an unreachable target then
# rides out group_mshr_serve_timeout on every entry: measured -25% on 2048x128x128).
# group_mshr_hold_subs_single ?= 8   # 256x512x256    (A 8-way, B 2-way)
# group_mshr_hold_subs_burst  ?= 2
# group_mshr_hold_subs_single ?= 2   # 1024x128x128   (A 2-way, B 8-way)
# group_mshr_hold_subs_burst  ?= 8
# group_mshr_hold_subs_single ?= 16  # 128x1024x512   (A 16-way, B 1-way; needs hold_window_burst=0)
# group_mshr_hold_subs_burst  ?= 2
# 512x512x512 (default): A 4-way, B 4-way
group_mshr_hold_subs_single ?= 4
group_mshr_hold_subs_burst  ?= 4
# Scalar response-release policy. The request-side hold window above remains 127. 1 = after the
# scalar response returns, keep its word in the MSHR and continue merging until
# group_mshr_hold_subs_single subscribers are present; 0 = start responding immediately.
group_mshr_resp_wait_subs_single ?= 1

# Enable tb_group_merge.svh (TB-side merge-opportunity analysis).
# Produces [GroupMerge] lines and `group_merge_profiling/*.log` per 10k cycles.
group_merge_profiling    ?= 1

# Dual-context TCDM burst expander (docs/tcdm_burst_interleave_design.md).
# 0 = OFF: legacy stall-while-draining expansion, bit-identical netlist. 1 = while one
# burst drains, a second LOAD is accepted into a shadow context and beats interleave
# round-robin -- two same-address bursts (which converge on the destination tile's
# expander and today serialize, the second completing a full drain-time later) finish
# within ~1 cycle of each other. Removes the intra-group pair-skew injection that
# poisons subsequent remote MSHR coalescing (see design doc 1). Loads-only shadow
# acceptance: stores/AMOs still wait for full drain, so no write reordering.
tcdm_burst_interleave    ?= 1

# MSHR bank-select hash (docs/mshr_bank_hash_design.md). Root cause of bank concentration
# (measured, §7): the legacy fold (0) and the xorshift fold (1) both drop addr_key[3:0] (the tile
# field) -- the bits that distinguish the concurrent requests -- so ~16 requests collapse onto one
# bank while ~13 sit empty. 2 = legacy fold PLUS the tile bits (stride-agnostic, best on measured
# traffic). 3 = field-select on the reconstructed LINEAR word address: bank = word[group_mshr_bank_shift
# +: BankIdW], i.e. select the bits that carry the dominant access stride (see group_mshr_bank_shift).
# All modes are pure functions of {group, line address} -> coalescing preserved.
# 2 (fold+tile) is the measured WINNER at 64 entries -- bank-full overflow 28400 -> 120, merge
# 14.3% -> 37.7%, stride-AGNOSTIC (no shift / no N tuning / no CSR). 3 (field-select) is set here
# for the user's 32-entry experiment: bank = word_addr[group_mshr_bank_shift +: BankIdW], which
# needs the shift tuned to the data stride N (below).
group_mshr_bank_hash     ?= 3
# BankHash==3 field-select. Per request type (mempool_group_mshr.sv, mshr_bank_of):
#
#     single: bank = word_addr[shift_single +: BankIdW]
#     burst : bank = { word_addr[shift_burst +: BankIdW-burst_bits],
#                      word_addr[clog2(MaxBurstWords) +: burst_bits] }
#
#     word_addr = byte_addr >> 2   (tcdm_addr_t is word-granular, mempool_pkg.sv:74)
#     BankIdW   = $clog2(group_mshr_num / group_mshr_ways_per_bank)   (128/8 -> 4 here)
#
# Idea: the concurrent burst requests of one inner iteration differ in (a) WHICH 16-word
# burst of a vector load they are -- the low burst_bits, taken just above the burst boundary
# (tracks MaxBurstWords automatically if the HW burst ever grows) -- and (b) which CORE's
# p_start they come from -- the field above shift_burst. Splitting them keeps the two
# streams from ever overlapping a bit.
#
# Quick calculation of the two burst knobs:
#   burst_bits  = $clog2(bursts per vector load) = $clog2(VL/MaxBurstWords):
#                 m1=0, m2=1, m4=2, m8=3. (m1 -> 0 -> plain contiguous field, like single.)
#   shift_burst = $clog2(p_start gap between sibling cores, IN WORDS)
#               = $clog2(P / split_p_count),
#                 split_p_count = cores_per_group / (dim_group/KERNEL_SIZE),
#                 dim_group = M / num_groups.
#                 M=P=256 ks=8: gap = 256/8  = 32w  -> 5
#                 M=P=512 ks=8: gap = 512/4  = 128w -> 7
#   RULE: shift_burst must be > clog2(MaxBurstWords)+burst_bits-1 (=4 here) -- the RTL
#   elaboration $errors on overlap. Retune when M/P/KERNEL_SIZE changes.
#   shift_single = $clog2(A row stride N in words): N=32 -> 5, N=512 -> 9.
group_mshr_bank_shift        ?= 5
# Per-type overrides. Both default to group_mshr_bank_shift above.
group_mshr_bank_burst_bits   ?= 1      # m2 (KERNEL_SIZE=8)
# shift_burst = $clog2(P / split_p_count) = $clog2(words each core owns along P).
# RTL rule: must be > $clog2(MaxBurstWords)+burst_bits-1, i.e. >= 5, so a shape with
# fewer than 32 words per core along P is REJECTED at elaboration.
# group_mshr_bank_shift_burst ?= 5    # 256x512x256    (256/8  = 32 words, the legal minimum)
# group_mshr_bank_shift_burst ?= 6    # 1024x128x128   (128/2  = 64 words)
# 512x512x512 (default): P/split_p_count = 512/4 = 128 words -> 7
group_mshr_bank_shift_burst  ?= 7
# shift_single = $clog2(N), the A row stride in words.
# group_mshr_bank_shift_single ?= 5   # N = 32
# group_mshr_bank_shift_single ?= 7   # N = 128   (1024x128x128, s19)
# group_mshr_bank_shift_single ?= 8   # N = 256
# group_mshr_bank_shift_single ?= 10  # N = 1024  (128x1024x512, best 96.8%)
# 512x512x512 (default): N = 512 -> 9
group_mshr_bank_shift_single ?= 9
# Cache self-invalidate (idea 1). 0 = OFF (bit-identical baseline). 1 = a CACHED entry frees itself
# once it has served its per-type sharing target (group_mshr_hold_subs_single scalar /
# group_mshr_hold_subs_burst burst), so a done cache line becomes an INVALID way the invalid-first
# allocator prefers -- keeping other cache lines resident longer. Reclaim-on-demand is controlled
# separately by group_mshr_cache_reclaimable below.
group_mshr_cache_self_inval ?= 1
# Response-cache coherence against stores/AMOs. OFF: neither fires on this workload (measured
# store_update = 0, amo_inval = 0 against 67,882 cache hits), and between them they own the store
# byte-merge into resp_buf.data and the only request-fed writer of mshr_d_valid. Assertions in
# mempool_group_mshr.sv fail the run if a store or AMO ever lands on a cached line while off.
group_mshr_cache_store_update ?= 0
group_mshr_cache_amo_inval ?= 0
# Store force-drain: flushes a MSHR_RESP_HOLD entry when a store hits its address. OFF for the
# same reason as the two above -- a read-only-A/B, write-only-C GEMM never stores to an address the
# MSHR is holding a load response for. [SFD] counts the opportunities regardless of the knob.
group_mshr_store_force_drain ?= 0
# Response cache (MSHR_CACHED): 1 = keep responded entries as a small read-response cache;
# 0 = MSHR_DRAIN_RESP -> MSHR_IDLE directly, no same-address reuse. Set 0 to remove the
# cohort-splitting path described in mempool_group_mshr.sv (EnableRespCache).
group_mshr_resp_cache ?= 1
# Cache reuse target (fp16 half-word aliasing): 0 = legacy self-invalidate at hold_subs_*.
# Non-zero keeps a CACHED line resident until served_cnt reaches it, so the second of the two
# scalar fp16 loads that alias one 32-bit word is served from the line instead of allocating a
# fresh entry that waits out serve_timeout for peers the line already served.
# Legal [0, group_mshr_merge_reqs]. Reset value only -- software sets it per kernel.
group_mshr_cache_reuse_target ?= 0
# CACHED-phase residency countdown. 0 = legacy (re-arm from group_mshr_serve_timeout).
group_mshr_cache_timeout ?= 0

# Bank-full policy for a mergeable miss. 0 = bypass the MSHR (legacy), 1 = backpressure: hold
# ready low until a way frees, which is what the design already does when the bank has a free way
# but the request lost that bank's single alloc slot.
#
# A bypass splits a cohort -- part of a round leaves without an MSHR tag, the bank frees, and a
# later member allocates a fresh entry whose subscriber target counts peers already served, so it
# waits out serve_timeout. Measured on the idea-2 sweep: arms with a non-zero cache_reuse_target
# sit bank-full far more often and show ~500x the bank-full bypass count of arms where the target
# is inactive (median 1,579 vs 3) -- and those are the arms that collapse 7-28x.
#
# Reset value only (group_mshr_cfg_runtime=1 -> software owns it via CSR 11).
group_mshr_bankfull_backpressure ?= 1
# CACHED-victim selection within a bank (pass-2 reclaim). 0 = legacy lowest-index-first:
# the lowest reclaimable CACHED way is ALWAYS the victim -> way-0 lines thrash while
# high-way lines stay pinned. 1 = per-bank round-robin victim start pointer, advanced past
# the evicted way only when a reclaim actually fires (invalid-first pass 1 unchanged, hit
# path untouched). HW: clog2(ways) flops/bank (16x3 = 48 here) + a rotated scan input.
# Bit-identical when 0. Policy change -> A/B measure before flipping the default.
group_mshr_cache_victim_rr ?= 1
# CACHED replacement policy. 0 = an idle CACHED entry is not an allocation victim and remains
# resident until cache self-invalidation (enabled above) or AMO invalidation. 1 = legacy
# reclaim-on-demand behavior when a bank has no invalid way.
group_mshr_cache_reclaimable ?= 0
# Bypass-path delivery probe (SIM ONLY, pragma translate_off -- zero synthesis/area impact).
# 1 = report [BYP ORPHAN] the cycle a bypass response is delivered to a tile with no
# outstanding entry-less forward for its {tile, core_id, meta_id} -- i.e. the cyc-23327
# "Response ID does not match with valid metadata" failure, caught at its source and one
# cycle BEFORE the core's own assertion. Also prints a periodic [BYP] fwd/rsp/orphan
# summary (uses group_mshr_stats_period). Single-beat traffic only (multi-beat bypass
# responses are retagged by ParityDrain and would produce false orphans). Silent when clean.
group_mshr_bypass_ways ?= 16
group_mshr_bypass_probe ?= 1
# RESP_HOLD stall probe (SIM ONLY): age threshold in cycles. An entry still holding its response
# after this many cycles is reported ONCE with byp/stl/peers/bank-census -- the evidence that says
# whether the missing subscriber was LOST to the bypass path (bank full), merely delayed, or split
# onto a second entry. 1000 matches the CMS stuck-request threshold. 0 = off.
group_mshr_resp_hold_probe ?= 1000

# Serve-target timeout, in cycles, for an entry holding data that has not reached its serve target.
# 0 = NO timeout (legacy): an entry whose target is never met waits forever, holds its way, and the
# bank eventually saturates -- measured 2026-07-30, the I$ warm-up pass (clamped row stride, so its
# scalar A loads never reach HoldSubsSingle=4) wedged whole banks at hold=8/8 with subs stuck at
# 1..3 of 4. Any W > 0 works exactly like group_mshr_hold_window: a free-running countdown that is
# never gated, so liveness holds for ANY target. Covers both waiting states -- RESP_HOLD delivers to
# whoever subscribed, and a CACHED line below its sharing target self-invalidates and frees the way.
# Reuses the hold_cnt field (mutually exclusive states), so no extra flops; only its width grows to
# cover the larger of the two windows. Required whenever group_mshr_resp_wait_subs_single=1 or
# group_mshr_cache_reclaimable=0, since both remove the release paths that used to bound the wait.
# 8191 (was 2047): the comment above says it TRACKS the hold window, and both windows are now
# 8191 -- leaving this at 2047 would have made the response-side release fire 4x sooner than the
# request-side hold it is supposed to track, so a single that waited the full request window could
# still be cut off on the response side. Costs no flops: it reuses hold_cnt, whose width is set by
# the LARGER of the two windows, and at prescale 6 that field is 7 bits (8191>>6 = 127).
#
# It DOES slow the burst-broken shapes (B slice under the 64 B floor): they cannot merge at any
# window, so this is purely how long they wait before giving up -- 4x longer now. That is accepted
# because those shapes are being kept out of future sweeps, not tuned for.
group_mshr_serve_timeout ?= 8191   # tracks the hold window; reuses the same hold_cnt field, so no extra flops

# Same-address request arriving in the SAME CYCLE as that entry's response.
# 1 = STALL and retry (default). 0 = legacy, which allocated a SECOND entry for the same address.
# Found from the waveform 2026-07-30: mshr_resp_seen_now/mshr_resp_inflight correctly kill
# req_hit_way while a response is landing (a mid-burst joiner would miss the earlier beats), but
# mshr_q still read WAIT_RESP so req_addr_hit_drain was false too -- the request matched NEITHER the
# merge path nor the wait path and fell through to ALLOCATE. Cost per occurrence: a wasted way, a
# redundant NoC fetch for data already arriving, and -- with group_mshr_resp_wait_subs_single=1 --
# two entries that each fall short of the subscriber target and ride out group_mshr_serve_timeout.
# Stalling costs the requester a few cycles instead: next cycle the entry is RESP_HOLD (mergeable,
# so it counts toward the target) or DRAIN_RESP (wait, then hit it as a CACHED line).
# Adds nothing to the merge/alloc timing path -- it reuses signals already feeding req_hit_way.
group_mshr_stall_on_resp ?= 1

# Group-barrier watchdog, in cycles. 0 = NO watchdog: a barrier waits until every core in its
# target set arrives -- the intended rendezvous semantics, and what the p-loop barrier
# (GBAR_PLOOP in kernel/sp-fmatmul.c) needs to actually synchronize. A non-zero W force-releases
# only the ARRIVED cores after W cycles from the first arrival, which does NOT synchronize: the
# stragglers end up a barrier round behind, so every subsequent barrier times out as well.
# Measured 2026-07-30 at the old default of 1024: a systematic >1024-cycle inter-lane skew
# (cores with core_gid%4==2 lag the rest) made EVERY group barrier time out, costing ~1024 cycles
# per cohort per barrier while synchronizing nothing. With W=0 the barrier costs the real skew but
# actually aligns the group. NOTE: with no watchdog, a mismatched arrival count (e.g. the I$
# warm-up pass and the timed run disagreeing on barrier count) HANGS instead of degrading
# silently -- that is intended, it surfaces the bug.
group_barrier_wd_limit ?= 0
# Index base within the separate group-control aperture at 0x20000000.
# This encoding no longer reserves any physical L1 SRAM.
group_barrier_word ?= 240

###########################
## 3. AXI and DMA Config
###########################

# Radix for hierarchical AXI interconnect
axi_hier_radix ?= 17

# Number of AXI masters per group
axi_masters_per_group ?= 1

# Number of DMA backends in each group
dmas_per_group ?= 1 # Burst Length = 16

# L2 Banks/Channels
l2_size               ?= 16777216  # 1000000
l2_banks              ?= 16
# L2 interleave granularity, in 64 B beats.
#
# NOT a free parameter. axi_L2_interleaver selects the L2 bank with
#     bank = addr[clog2(64*Interleave) +: clog2(l2_banks)]
# and that field MUST line up with the top of the L1 word-interleave group field
# (which begins at bit 2+clog2(banks/tile)+clog2(tiles/group) = 10), because the
# whole DMA path depends on channel G serving group G -- see
# docs/scaleup/mesh_plan.md sections 13 and 14. The alignment holds iff
#
#     axi_width_interleaved = 16 * num_groups / l2_banks
#
# At 4x4 there is one channel per group, so this is 16 and nothing changes. Above
# 4x4 the perimeter cannot host a channel per group (2*(NumX+NumY) < NumX*NumY),
# so channels are shared and the interleave coarsens by exactly the sharing
# factor. Coarsening is what makes the groups sharing a channel ADJACENT rather
# than scattered: at 8x8 it pairs (x,y) with (x,y+1) at 1.62 avg hops, against
# (x,y) with (x+4,y) at 2.88 if this were left at 16.
#
# mempool_system.sv asserts the alignment, so a wrong value fails elaboration.
axi_width_interleaved ?= $(shell echo $$((16 * $(num_groups) / $(l2_banks))))

###########################
## 4. Spatz Config
###########################

# Activate Spatz and RVV
spatz ?= 1

# Lenght of single vector register
vlen ?= 512

# Number of IPUs
n_ipu ?= 4

# Number of FPUs
n_fpu ?= 4

# Enable FPU
rvf ?= 1
rvd ?= 0

# Make sure XPULP is off for Spatz configuration
xpulpimg ?= 0

# Make sure zfinx is off for Spatz configuration
zfinx ?= 0

# --- VLSU / ROB area-timing cleanups (docs/spatz_mlp_design_plan.md §5.2, §5.3) ---
# Both are deliberate netlist changes when ON (they delete provably unreachable
# silicon), so they are NOT bit-identical to the 0 build -- keep them 0 until each has
# its own A/B + LEC run, and commit them separately.
#
# --- Spatz VLSU / ROB knobs (toggle guide) ---------------------------------------
# Quick reference:
#   block-alloc only (shipped default):  spatz_vlsu_block_alloc=1, everything else 0/unset
#     -> 3589 cycles.
#   + H1 dual load:                      spatz_vlsu_rob_depth=64 + spatz_vlsu_dual_load=2
#     -> 3488 cycles (-2.8%, measured with BOTH). At the shipped rob_depth=32 dual_load still
#     works for loads below the admission ceiling; only a ceiling-sized load fills the ROB and
#     leaves the runahead with nothing to overlap. See the dual_load block below.
#   R1/R2 are AREA-only (no perf change): enable to shrink the netlist once timing allows.
# Any knob can also be overridden on the command line: make ... spatz_vlsu_dual_load=2
#
# R1: reorder_buffer id_valid_o from status_cnt_q instead of the id_valid_q free-id
# bitmap. 0 = legacy bitmap. 1 = -NumWords flops, -1 decoder and -2 32:1 muxes per
# ROB (x4 ROBs/core), and ~6 fewer logic levels on the id_valid_o -> mem_req_lvalid path.
# AREA-reduction / timing cleanup, NOT a performance change (measured cycle-identical
# at ROB32 and ROB64). Deliberate netlist change when on; not bit-identical.
spatz_rob_cnt_idvalid ?= 1
# R2: VLSU commit-metadata FIFO DEPTH NrOutstandingLoads(32) -> NrParallelInstructions(4),
# the most entries that can ever be resident (the push is gated on the per-id
# mem_insn_pending_q bit). 0 = legacy depth. 1 = -28 x 37 flops + a 37b 32:1 read mux.
# AREA-reduction only, NOT a performance change (measured cycle-identical).
spatz_vlsu_commit_qmin ?= 1

# --- Block ROB-id reservation (docs/spatz_mlp_design_plan.md §5.1, the main MLP lever) ---
# 0 = OFF: the port-0 burst allocator walks its ROB ids one per cycle, so every 16-beat burst
# waits 18 cycles between becoming eligible and its request handshake (1 decide + 16 walk +
# 1 send). 1 = ON: ROB0 grants the whole 16-id window in a single cycle -- decide -> reserve ->
# send = 3 cycles -- removing 15 cyc/burst = 30 cyc/load from the load recurrence the FPU-idle
# analysis is short on. Measured: 3821 -> 3589 cycles (-6.1%, reproduced twice). Bit-identical
# netlist when 0.
spatz_vlsu_block_alloc ?= 1

# --- ROB64: VLSU ROB 32->64 ids + system meta_id 5b->6b (docs/spatz_rob64_h1_design_plan.md) ---
# Unset = 32 (bit-identical). Set = 64: room for TWO m2 loads (2x32 ids). Moves THREE roots
# atomically (snitch_pkg::RobDepth, spatz NrOutstandingLoads, spatz_mem_rsp_t.id); widens
# every mesh link by 1 bit (PNR re-close needed). Measured: cycle-identical (3589) for m2 --
# invisible on its own, it is the enabler for dual_load below.
# "ROB0 deep, rest shallow" (hardware/Makefile:491): bursts use ROB0 alone, so ports 1..N-1
# need not match its depth. This pair is what build_tgt4x4 / build_tgt8x8 were built with and
# what every sweep result on this branch was measured on.
# 128 -> 32, and robn_depth GONE. Both were consequences of the funnel: ROB0 alone had to hold
# a whole 512 B burst, and ROBs 1-3 saw no burst data so they were shrunk separately (which then
# needed a generation tag in the id, because their storage no longer matched the id width).
# Distributing the beats makes a 512 B burst 128/NrMemPorts = 32 ids in EVERY buffer, so one
# uniform 32 covers the same admission ceiling (vl <= NrOutstandingLoads*MemDataWidthB*NrMemPorts
# = 512 B) AND the non-burst path, with no asymmetry and GenBits = 0.
#
# This also narrows snitch_pkg::MetaIdWidth = idx_width(RobDepth) from 7 to 5 bits, and meta_id_t
# reaches every TCDM struct and both FlooNoC flit metas -- so it un-does the ROB64->ROB128 link
# widening. Re-close PNR on this.
spatz_vlsu_rob_depth ?= 32

# --- H1 dual-load runahead ---
# Unset/1 = legacy: the next load starts only when the previous one fully retires
# (bit-identical). 2 = the next burst-safe load starts as soon as the previous one's requests
# are all ISSUED, so its flight overlaps the elder's drain. Measured with rob_depth=64:
# 3589 -> 3488 cycles (-2.8%), dual_adv on 32/40 instructions, all assertions silent.
#
# HOW IT INTERACTS WITH rob_depth, since this header used to read "REQUIRES rob_depth=64" and
# that sent readers hunting a bug in the shipped build. It is a CEILING effect, not a hard
# requirement. The admission ceiling is vl <= NrOutstandingLoads * MemDataWidthB * NrMemPorts,
# so at rob_depth=32 that is 512 B: a ceiling-sized load is 128 words spread over the 4 ports,
# i.e. all 32 ids in EVERY buffer, leaving the younger load nothing to allocate. A 256 B load
# takes 16 ids and two of them overlap fine. So at 32 the runahead is live below the ceiling and
# inert at it; 64 is what makes ceiling-sized loads overlap too.
#
# It is not a hazard at 32 either: dual_adv is gated on mem_req_all_issued, not on ROB room, so
# the younger load simply stalls in its allocator until the elder retires (spatz_vlsu.sv:1038,
# "inflight_q drops at A's retire, independent of the held instruction"). Every build on this
# branch runs 32 + dual_load=2 with all assertions silent.
#
# COST of going to 64, before anyone does: MetaIdWidth = idx_width(RobDepth) goes 5 -> 6, and
# meta_id_t reaches every TCDM struct and both FlooNoC flit metas -- so it widens every mesh
# link by a bit and needs a PNR re-close. Moving to 32 was partly to undo exactly that.
# The -2.8% above was measured at 64; the benefit AT 32 has never been A/B'd.
spatz_vlsu_dual_load ?= 2

# --- Element width and the burst path ---------------------------------------------
# There is no element-width knob any more. spatz_vlsu_burst_ew16 used to admit e16/e8 to a
# burst path that was gated on vsew == EW_32; the path is WORD granular end to end now (a
# word's lane is its word index mod NrMemPorts), so how many elements sit inside a 32-bit
# word never enters the mapping and EVERY element width bursts unconditionally.
#
# The define was deleted rather than defaulted: it was still being passed into every build
# while nothing in the RTL read it, so setting it to 0 to get an fp32-only baseline produced
# an image bit-identical to the one it was meant to differ from.
