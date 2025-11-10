# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Matheus Cavalcante, ETH Zurich

###############
##  MemPool  ##
###############

# Number of cores
num_cores ?= 64

# Number of groups
num_groups ?= 4

# Number of cores per MemPool tile
num_cores_per_tile ?= 1

# L1 scratchpad banking factor
banking_factor ?= 4

# Number of shared divsqrt units per MemPool tile
# Defaults to 0 if xDivSqrt is not activated
num_divsqrt_per_tile ?= 0

#####################
## 2. NoC Config
#####################

# FlooNoC configuration
num_directions ?= 5
num_x          ?= 2

# Topology
# 0: 2D mesh, 1: torus
noc_topology ?= 0

# Routing algorithm
# 0: xy, 1: odd-even, 2: o1
noc_routing_algorithm ?= 0

# NoC remapping configuration
# 0: no remapping, 1: req remapping, 2: resp remapping 3: req+resp remapping
noc_router_remapping ?= 0

# Virtual channel number
noc_virtual_channel_num ?= 1

# Channel configuration mode (internal control only)
# Options: baseline, narrow, enhanced
channel_config_mode := baseline  # Current MemPool setting

# Channel configuration based on selected mode
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

# Print configuration info for debugging
$(info [DEBUG:][noc_req_rd_channel_num]----$(noc_req_rd_channel_num))
$(info [DEBUG:][noc_req_rdwr_channel_num]--$(noc_req_rdwr_channel_num))
$(info [DEBUG:][noc_req_wr_channel_num]----$(noc_req_wr_channel_num))
$(info [DEBUG:][noc_resp_channel_num]------$(noc_resp_channel_num))

# Router buffer configuration
noc_router_input_fifo_dep  ?= 2
noc_router_output_fifo_dep ?= 2

# Router remapping configuration
noc_router_remap_group_size ?= 8

###########################
## 3. AXI and DMA Config
###########################

# Radix for hierarchical AXI interconnect
axi_hier_radix ?= 17

# Number of AXI masters per group
axi_masters_per_group ?= 1

# Number of DMA backends in each group
dmas_per_group ?= 1  # Burst Length = 16

# L2 Banks/Channels
l2_size               ?= 4194304   # 400000
l2_banks              ?= 4
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

# Deactivate the XpulpIMG extension
xpulpimg ?= 0

# Make sure zfinx is off for Spatz configuration
zfinx ?= 0
