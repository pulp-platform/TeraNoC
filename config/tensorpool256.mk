# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Author: Yinrong Li, ETH Zurich
#
# TeraNoC flavor at tensorpool256 scale: 256 cores, 4 groups, 16 RedMulE.

###########################
## 1. Architecture Config
###########################

# Global Control
terapool ?= 1

# Number of cores
num_cores ?= 256

# Number of groups
num_groups ?= 16

# Number of cores per tile
num_cores_per_tile ?= 4

# L1 scratchpad banking factor
banking_factor ?= 8

# Number of shared divsqrt units per tile
# Defaults to 1 if xDivSqrt is activated
num_divsqrt_per_tile ?= 1

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
# 0: xy, 1: id_table
noc_routing_algorithm ?= 0

# NoC remapping configuration
# 0: no remapping, 1: req remapping, 2: resp remapping 3: req+resp remapping
noc_router_remapping ?= 3

# Virtual channel number
noc_virtual_channel_num ?= 1

# Channel configuration mode (internal control only)
# Options: baseline, narrow, enhanced
channel_config_mode := baseline

ifeq ($(strip $(channel_config_mode)), baseline)
noc_req_rd_channel_num   ?= 0
noc_req_rdwr_channel_num ?= 2
noc_req_wr_channel_num   ?= 0
noc_resp_channel_num     ?= 2
else ifeq ($(strip $(channel_config_mode)), narrow)
noc_req_rd_channel_num   ?= 1
noc_req_rdwr_channel_num ?= 1
noc_req_wr_channel_num   ?= 0
noc_resp_channel_num     ?= 2
else ifeq ($(strip $(channel_config_mode)), enhanced)
noc_req_rd_channel_num   ?= 1
noc_req_rdwr_channel_num ?= 1
noc_req_wr_channel_num   ?= 0
noc_resp_channel_num     ?= 3
else
$(error Unsupported channel_config_mode: $(channel_config_mode))
endif

$(info [DEBUG:][noc_req_rd_channel_num]----$(noc_req_rd_channel_num))
$(info [DEBUG:][noc_req_rdwr_channel_num]--$(noc_req_rdwr_channel_num))
$(info [DEBUG:][noc_req_wr_channel_num]----$(noc_req_wr_channel_num))
$(info [DEBUG:][noc_resp_channel_num]------$(noc_resp_channel_num))

# Router buffer configuration
noc_router_input_fifo_dep  ?= 2
noc_router_output_fifo_dep ?= 2

# Router remapping xbar size configuration
noc_router_remap_group_size ?= 4

###########################
## 3. RedMulE Tensor-Core Config
###########################

# Number of tiles that host a RedMulE tensor core
num_redmule_tiles ?= 16

# RedMulE engine geometry (array height, width, pipe regs)
redmule_height ?= 8
redmule_width  ?= 32
redmule_regs   ?= 3

# Outstanding-transactions ROB depth in the redmule TCDM path
rob_depth      ?= 16

###########################
## 4. AXI and DMA Config
###########################

# Radix for hierarchical AXI interconnect
axi_hier_radix ?= 17

# Number of AXI masters per group
axi_masters_per_group ?= 1

# Number of DMA backends in each group
dmas_per_group ?= 1 # Burst Length = 16

# L1 size per bank (in bytes)
l1_bank_size ?= 2048

# L2 Banks/Channels
l2_size               ?= 16777216  # 1000000
l2_banks              ?= 16
axi_width_interleaved ?= 16
