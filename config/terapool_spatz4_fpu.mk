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
noc_router_remapping ?= 0

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
channel_config_mode := baseline  # Change this value to switch modes

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
# For terapool: 16 tiles/group * 2 remote req ports = 32 concurrent slots,
# 64+ is recommended to absorb overlapping outstanding bursts without overflow.
group_mshr_num           ?= 64
# Max sub-requests coalesced into one MSHR entry.
group_mshr_merge_reqs    ?= 8
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
group_mshr_hold_window   ?= 100
# Early-release subscriber target: a held entry issues its fetch as soon as this many
# requesters have merged into it. Legal range [2, group_mshr_merge_reqs].
group_mshr_hold_subs     ?= 2
# Per-request-type overrides of group_mshr_hold_subs: _single applies to 1-word scalar
# entries (A-line flw, natural sharing degree 8), _burst to multi-beat vector entries
# (B-line, degree 2). Default: inherit the uniform target above.
# single=8 / burst=2 measured 4167 (W=16) and 4354 (W=24, worst point of the sweep):
# singles essentially never reach 8 subscribers in-window, so a higher target only
# lengthens the timeout path.
group_mshr_hold_subs_single ?= 8
group_mshr_hold_subs_burst  ?= 2

# Enable tb_group_merge.svh (TB-side merge-opportunity analysis).
# Produces [GroupMerge] lines and `group_merge_profiling/*.log` per 10k cycles.
group_merge_profiling    ?= 1

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
axi_width_interleaved ?= 16

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