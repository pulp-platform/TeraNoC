# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Samuel Riedel, ETH Zurich
#         Matheus Cavalcante, ETH Zurich

######################
##  MemPool flavor  ##
######################

# Choose a MemPool flavor, either "minpool" or "mempool".
# Check the README for more details
ifndef config
  ifdef MEMPOOL_CONFIGURATION
    config := $(MEMPOOL_CONFIGURATION)
  else
    # Default configuration, if neither `config` nor `MEMPOOL_CONFIGURATION` was found
    config := mempool
  endif
endif
include $(MEMPOOL_DIR)/config/$(config).mk

##############################
##  Spatz VLSU burst gate   ##
##############################

# Set here rather than per flavour so EVERY configuration gets it: mempool_tile.sv $errors on
# an undefined SPATZ_VLSU_BURST, because spatz_vlsu reads undefined as 1 (burst emission ON) and
# the tile-side burst lane retag is not implemented yet.
#
# spatz_vlsu distributes a burst's beats across its four reorder buffers (beat k -> lane
# k % NrMemPorts) so a vector register row is written atomically. Spatz chains one cycle after
# its producer's first VRF write, so the old form -- every beat funnelled into ROB0, a row
# assembled from four partial writes -- let a consumer read three stale lanes out of four. The
# memory side has to deliver beats lane-distributed; until it does, keep this 0 and every vector
# load takes the row-atomic word-interleaved path. See docs/spatz_vpu_burst_adoption_review.md.
spatz_vlsu_burst ?= 0

#############################
##  Address configuration  ##
#############################

# Boot address (in dec)
boot_addr ?= 2684354560 # A0000000

# L2 memory configuration (in dec)
l2_base  ?= 2147483648 # 80000000

# L1 size per bank (in dec)
l1_bank_size ?= 1024

# Size of sequential memory per core (in bytes)
# (must be a power of two)
seq_mem_size ?= 512

# Size of stack in sequential memory per core (in bytes)
stack_size ?= 512

#########################
##  AXI configuration  ##
#########################
# AXI bus data width (in bits)
axi_data_width ?= 512

# Read-only cache line width in AXI interconnect (in bits)
ro_line_width ?= 512

#############################
##  Xqueues configuration  ##
#############################

# XQueue extension's queue size in each memory bank (in words)
xqueue_size ?= 0

################################
##  Optional functionalities  ##
################################

# Enable the XpulpIMG extension
xpulpimg ?= 0

# Enable FPU extensions
zfinx ?= 0

# Enable FPU extensions
zquarterinx ?= 0

# DivSqrt deactivated by default
xDivSqrt ?= 0

# DRAMsys co-simulation: dram/sram
l2_sim_type ?= sram
axi_width_interleaved ?= 16

# Enable SPM bank id remapping inside of each tile
spm_bank_id_remap ?= 0

# Enable tile id remapping inside of each group
tile_id_remap ?= 0

# Enable the spm access pattern profiling
spm_profiling ?= 0

# Enable the interconnect access pattern profiling
noc_profiling ?= 0