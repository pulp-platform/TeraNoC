# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Matheus Cavalcante, ETH Zurich

# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Matheus Cavalcante, ETH Zurich

config_build_path ?= terapool8x8

###########################
## 1. Architecture Config
###########################

# Global Control
terapool ?= 1

# Number of cores
num_cores ?= 1024

# Number of groups
num_groups ?= 64

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
num_x          ?= 8

# Topology
# 0: 2D mesh, 1: torus
noc_topology ?= 0

# Routing algorithm
# 0: xy, 1: odd-even, 2: o1
noc_routing_algorithm ?= 0

# NoC remapping configuration
# 0: no remapping, 1: req remapping, 2: resp remapping 3: req+resp remapping
#
# 2 as of 2026-08-14, matching terapool_spatz4_fpu.mk -- one value at every mesh, so 4x4 and 8x8
# differ in the thing under test and not in the remapper as well. See the base flavour for the
# full caveat: remapping=2 has NO throughput evidence at 8x8 (FGIR2's 85.2% plateau is its whole
# reputation, and plateau correlates +0.82 with being SLOWER across the eight completions there),
# and it adds gen_resp_remapping to every group.
#
# CONSEQUENCE: terapool_spatz4_fpu_8x8_r2.mk pinned `:= 2` as its ONLY difference from this file,
# so that flavour is now identical to this one. Its header still claims one knob differs -- it no
# longer does.
noc_router_remapping ?= 2

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
group_mshr_num           ?= 64
# Ways (entries) per bank; banks = group_mshr_num / group_mshr_ways_per_bank. 16 entries / 2 ways
# = 8 banks x 2 ways (user experiment). WARNING: 16 entries is HALF of the 32 concurrent request
# slots (16 tiles x 2 remote ports) -- 32 entries already collapsed the matmul ~14x, so 16 is very
# likely to collapse harder. Revert to 64 (16 banks x 4 ways) for the measured-safe design.
group_mshr_ways_per_bank ?= 4
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
group_mshr_merge_reqs    ?= 4
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
group_mshr_hold_window_single ?= 0
group_mshr_hold_window_burst  ?= 2047   # standing decision 2026-08-14: 2047 at every mesh
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
group_mshr_hold_prescale_w ?= 4
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
group_mshr_serve_timeout ?= 2047

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

# ---------------------------------------------------------------------------------------------
# PARITY WITH terapool_spatz4_fpu.mk (4x4). These seven knobs were ABSENT from this file, so an
# 8x8 build silently fell back to the RTL `ifdef defaults -- and for FOUR of them the RTL default
# is the OPPOSITE of what every 4x4 arm ran with. Any 8x8-vs-4x4 comparison made before this was
# added was comparing five MSHR behaviours at once, not the mesh.
#
#   knob                              RTL default   4x4 value   silently wrong at 8x8?
#   group_mshr_bankfull_backpressure  0             1           YES -- bp OFF, in HW *and* in SW
#                                                               (runtime.mk:154 keys the CSR write
#                                                               off this same variable, so the ELF
#                                                               programmed MSHR_CFG_BANKFULL_BP=0)
#   group_mshr_bank_publish           1'b0          1           YES -- publish OFF
#   group_mshr_drain_from_q           1'b0          1           YES -- drain-from-q OFF
#   group_mshr_spill_req_in           1'b1          0           YES -- spill ON (deadlock-relevant)
#   group_mshr_resp_cache             1'b1          1           no  (default already matched)
#   group_mshr_cache_reuse_target     0             0           no  (software sets it per shape)
#   group_mshr_cache_timeout          0             0           no
#
# Set explicitly rather than left to the defaults: a knob whose value comes from an `ifdef fallback
# is invisible in this file, and that invisibility is exactly what made four of them wrong.
group_mshr_bankfull_backpressure ?= 1
group_mshr_bank_publish          ?= 1
group_mshr_drain_from_q          ?= 1
group_mshr_spill_req_in          ?= 0
group_mshr_resp_cache            ?= 1
group_mshr_cache_reuse_target    ?= 0
group_mshr_cache_timeout         ?= 0
# ---------------------------------------------------------------------------------------------

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
# Reserved within-tile word base for the group barrier (see mempool_group.sv GroupBarrierWord).
# The window [group_barrier_word, +cores_per_group) is STOLEN from the data address space
# group-wide; arch.ld.c truncates L1 at group_barrier_word<<14 to keep data out. 240 puts the
# window at the very top of L1 (words 240..255), costing a trailing 256 KB and no fragmentation.
# Changing this REQUIRES changing GBAR_BASE_WORD in the barrier-using software to match.
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
# The L2 SAM gives every channel 1 MB (gen_perimeter_map.py --emit-yml), so the total
# MUST be l2_banks * 1 MB. axi_L2_interleaver places the bank field at
# addr[31-MSBConstantBits -: ScrambleBits] with MSBConstantBits = 32 - clog2(l2_size);
# if l2_size does not span every channel the bank field lands one bit low and reads for
# the upper channels decode to the wrong endpoint, never reach the L2, and never return.
l2_size               ?= $(shell echo $$((1048576 * $(l2_banks))))  # l2_banks * 1 MB
l2_banks              ?= 32
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
#     -> 3488 cycles (-2.8%; needs BOTH). dual_load without rob_depth=64 has no ROB room.
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
spatz_vlsu_rob_depth ?= 64
# --- H1 dual-load runahead (REQUIRES spatz_vlsu_rob_depth=64 to have ROB room) ---
# Unset/1 = legacy: the next load starts only when the previous one fully retires
# (bit-identical). 2 = the next burst-safe load starts as soon as the previous one's requests
# are all ISSUED, so its flight overlaps the elder's drain. Measured with rob_depth=64:
# 3589 -> 3488 cycles (-2.8%), dual_adv on 32/40 instructions, all assertions silent.
spatz_vlsu_dual_load ?= 2

# --- Sub-word (fp16) burst eligibility -------------------------------------------
# spatz_vlsu.sv gates the port-0 burst path on vsew == EW_32, so an fp16 vector load
# (vle16.v) falls back to the 4-port word-interleaved path: it moves the same bytes per
# cycle, but it never reaches the group MSHR's BURST class, so burst merging, ParityDrain
# and BlockAlloc are all inactive. 0 = that legacy behaviour, bit-identical netlist.
# 1 = admit every element width except EW_8.
#
# The burst LENGTH does not change: a burst is MaxBurstWords(16) 32-bit words = 64 B in both
# modes, carrying 16 fp32 or 32 fp16 elements. Everything downstream is byte/word-granular
# and sees an identical stream, so this adds no state and no datapath -- the eligibility
# test actually gets cheaper (|vsew rather than a 2-bit compare).
#
# KEEP fp16 KERNELS AT LMUL <= 4: burst eligibility also caps vl at
# NrOutstandingLoads*4 = 256 B, and e16,m8 is 512 B -- it would silently take the non-burst
# path. The gen_burst_ew_vl_ceiling probe warns when that happens.
# DEFAULT 1 since 2026-08-20, matching terapool_spatz4_fpu.mk. This flavour does not include the
# 4x4 base, so the knob has to be repeated here or no -D is emitted at all and the RTL falls back
# to its `ifdef default of 0 -- which silently discards every CSR write mshr_cfg_apply_group() makes.
group_mshr_cfg_runtime ?= 1

spatz_vlsu_burst_ew16 ?= 1
