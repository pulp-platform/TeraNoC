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
noc_router_remapping ?= 1

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
# NOTE: currently set to 0 as a workaround. With =1, a residual orphan race
# in the single-word admission path (likely duplicate-entry allocation when
# a CACHED entry exists for the same address) causes sporadic deadlocks on
# sp-fmatmul-opt-burst-merge. Tested fixes (beat_pending init for mid-drain
# merges; removing CACHED-merge) were each insufficient. Until the root
# cause is fully characterized, keep this at 0 — single-word loads bypass
# the MSHR. See bottleneck_analysis/ for details.
group_mshr_enable_single ?= 0
# Emit MSHR internal [MSHR stats] via $display (sim-only).
group_mshr_enable_stats  ?= 1
# Stats print period (cycles) while csr_trace is active (0 = final dump only).
group_mshr_stats_period  ?= 1000
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