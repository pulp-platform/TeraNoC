# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Author: Yichao Zhang, ETH Zurich

SHELL = /usr/bin/env bash
ROOT_DIR 		:= $(patsubst %/,%, $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
MEMPOOL_DIR 	:= $(shell git rev-parse --show-toplevel 2>/dev/null || echo $$MEMPOOL_DIR)
INSTALL_DIR 	:= $(abspath $(ROOT_DIR)/../install)
TOOLCHAIN_DIR 	:= $(abspath $(ROOT_DIR)/../toolchain)

# Include configuration
config_mk = $(abspath $(ROOT_DIR)/../config/config.mk)
include $(config_mk)

# ============================================================================
# Build and Simulation Tool Configuration
# ============================================================================
# Build paths
buildpath        ?= build
resultpath       ?= results
# Questa library
library          ?= work
# DPI library
dpi_library      ?= work-dpi
# Top level module to compile
top_level        ?= mempool_tb
# QuestaSim Configuration
questa_version   ?= 2023.4-zr
questa_cmd       ?= questa-$(questa_version)
questa_args      ?=
questa_config    ?=
questa_voptargs ?= +acc
questa_wlf      ?= vsim.wlf
# Soft fd limit for the sim shell. The Spatz/Snitch tracers + DMA/profiling hold ~1030 files open
# at once on a 256-core run (4 streams x 256 harts), which overflows the default 1024 and silently
# drops the last cores' traces (EMFILE -> [FOFIW]/vsim-PLI-3085). Must exceed that; 8192 is the
# smallest power of two comfortably above. Override with sim_ulimit_n=... if the host caps lower.
sim_ulimit_n    ?= 8192
# VCS Configuration
vcs_version      ?= 2024.09-zr
vcs_cmd          ?= vcs-$(vcs_version)
vcs_config       ?=
# Path to the application binaries
app_path         ?= $(abspath $(ROOT_DIR)/../software/bin)
# Bender
bender           ?= $(INSTALL_DIR)/bender/bender
# Verilator
verilator        ?= $(INSTALL_DIR)/verilator/bin/verilator
verilator_build  ?= $(ROOT_DIR)/verilator_build
verilator_files  ?= $(verilator_build)/files
verilator_top    ?= mempool_tb_verilator
# Python
python           ?= python3
# Enable Snitch tracing
snitch_trace     ?= 1
# Per-Spatz-core vector trace (working_dir/spatz spatz_mempool_cc.sv). 0 = emit only inside the
# benchmark's csr_trace region (default); 1 = force always-on for the whole sim (heavy: one line
# per active cycle per core). Files land in $(buildpath); post-process with `make spatz-trace`.
spatz_trace      ?= 0

# Enable spatz (automatically set when using spatz configuration)
spatz            ?= 1

# DRAMSys Integration
dramsys_resouces_path ?= $(MEMPOOL_DIR)/hardware/deps/dram_rtl_sim/dramsys_lib/DRAMSys/configs
dramsys_lib_path      ?= $(MEMPOOL_DIR)/hardware/deps/dram_rtl_sim/dramsys_lib/DRAMSys/build/lib
questa_args += +DRAMSYS_RES=$(dramsys_resouces_path)
questa_args += -sv_lib $(dramsys_lib_path)/libsystemc -sv_lib $(dramsys_lib_path)/libDRAMSys_Simulator
# Check if the specified QuestaSim version exists
ifeq (, $(shell which $(questa_cmd)))
  $(warning "Specified QuestaSim version ($(questa_cmd)) not found in PATH $(PATH)")
  questa_cmd =
endif
# Simulation tool environment paths
QUESTASIM_HOME  ?= /usr/pack/questa-$(questa_version)/questasim
VCS_HOME        ?= /usr/pack/vcs-$(vcs_version)/vcs

# ============================================================================
# Application and Preload Handling
# ============================================================================
ifdef app
  questa_args += +APP=$(app)$(app_suf)
  preload := "$(app_path)/$(app)"
  ifeq ("$(shell test -f $(preload))","")
    # The file doesn't exist, let's search for the app in the bin folder
    # since we might just be missing the hierarchy
    search_app   := $(shell find $(app_path) -type f -path "*$(app)")
    num_matches  := $(words $(search_app))
    ifeq ($(num_matches), 0)
      $(error "App ($(app)) not found in bin dir $(app_path)")
    else ifeq ($(num_matches), 1)
      preload := "$(search_app)"
      $(warning "Running application $(preload)")
    else
      $(error "Multiple apps ($(app)) found in bin dir $(app_path): $(search_app)")
    endif
  endif
endif
ifdef preload
  questa_args += +PRELOAD=$(preload)
endif
questa_args += -sv_lib $(dpi_library)/mempool_dpi -work $(library)
questa_args += -suppress vsim-12070

# ============================================================================
# VCS Options
# ============================================================================
vlogan_args += -assert svaext +v2k -override_timescale=1ns/1ps -kdb
ifdef preload
  vcs_args += +PRELOAD=$(preload)
endif

# ============================================================================
# DPI and Trace Configuration
# ============================================================================
# DPI source files
dpi     := $(patsubst tb/dpi/%.cpp,      $(buildpath)/$(dpi_library)/%.o,      $(wildcard tb/dpi/*.cpp))
dpi_vcs := $(patsubst tb/dpi/%.cpp,      $(buildpath)/$(dpi_library)/%_vcs.o,  $(wildcard tb/dpi/*.cpp))
# Traces
trace         := $(patsubst $(buildpath)/%.dasm, $(buildpath)/%.trace, $(wildcard $(buildpath)/*.dasm))
tracepath     ?= $(buildpath)/traces
traceresult   ?= $(tracepath)/results.csv
# Output result directory with timestamp and git hash
ifndef result_dir
  result_dir := $(resultpath)/$(shell date +"%Y%m%d_%H%M%S_$(app)_$$(git rev-parse --short HEAD)")
endif

# ============================================================================
# Architecture Variable Passing ##
# ============================================================================
vlog_args += -suppress vlog-2583 -suppress vlog-13314 -suppress vlog-13233
vlog_args += -work $(library)

# General Configuration
vlog_defs += -D$(config)
ifeq ($(terapool), 1)
	vlog_defs += -DTERAPOOL
endif
# Group-level fine-grained barrier (held-response TCDM slave). Default ON in
# mempool_group; group_barrier=0 disables it (-DGROUP_BARRIER_OFF) for A/B.
ifeq ($(group_barrier), 0)
	vlog_defs += -DGROUP_BARRIER_OFF
endif
# --------------------------
# Cluster Configuration
# --------------------------
vlog_defs += -DNUM_CORES=$(num_cores)
vlog_defs += -DNUM_CORES_PER_TILE=$(num_cores_per_tile)
vlog_defs += -DNUM_DIVSQRT_PER_TILE=$(num_divsqrt_per_tile)
vlog_defs += -DNUM_GROUPS=$(num_groups)
vlog_defs += -DBANKING_FACTOR=$(banking_factor)
vlog_defs += -DL2_BASE=32\'d$(l2_base)
vlog_defs += -DL2_SIZE=32\'d$(l2_size)
vlog_defs += -DL2_BANKS=$(l2_banks)
vlog_defs += -DL1_BANK_SIZE=$(l1_bank_size)
vlog_defs += -DBOOT_ADDR=32\'d$(boot_addr)
# --------------------------
# FlooNoC Configuration
# --------------------------
vlog_defs += -DNUM_REMOTE_PORTS_PER_TILE=$(num_remote_ports_per_tile)
vlog_defs += -DNUM_DIRECTIONS=$(num_directions)
vlog_defs += -DNUM_X=$(num_x)
vlog_defs += -DNOC_TOPOLOGY=$(noc_topology)
vlog_defs += -DNOC_ROUTING_ALGORITHM=$(noc_routing_algorithm)
vlog_defs += -DNOC_ROUTER_REMAPPING=$(noc_router_remapping)
noc_port_hash ?= 0
vlog_defs += -DNOC_PORT_HASH=$(noc_port_hash)
vlog_defs += -DNOC_VIRTUAL_CHANNEL_NUM=$(noc_virtual_channel_num)
# --------------------------
# Group MSHR Tuning & Stats
# --------------------------
# Values below are fallbacks used when a config .mk file did not set them.
# Prefer setting these in the per-flavor config (e.g. config/terapool_spatz4_fpu.mk).
# Keeping them minimal here so other configs match the RTL module defaults.
group_mshr_num           ?= 16
# Ways (entries) per MSHR bank; number of banks = group_mshr_num / group_mshr_ways_per_bank. Empty
# = RTL default 4. E.g. num=16, ways=2 -> 8 banks x 2 ways.
group_mshr_ways_per_bank ?=
group_mshr_merge_reqs    ?= 8
group_mshr_enable_single ?= 0
group_mshr_enable_stats  ?= 0
group_mshr_stats_period  ?= 0
group_merge_profiling    ?= 0
# Fallbacks only: the Spatz flavors set these in config/<flavor>.mk (documented there with the
# measured data). Empty here = feature off / RTL default, for flavors that do not define them.
# Per-entry MSHR response-drain width (ParityDrain 2-wide burst receive). Empty/unset = 1 = OFF
# (legacy single-beat drain; all beat-parity logic const-folds out). Set =2 to OPT IN to 2
# beats/cycle: the wire contract is unchanged (meta_id = base+b), so entries stay FULLY MERGEABLE
# and coalescing is untouched (measured 1.11-1.16x FASTER on sp-fmatmul). Needs
# noc_resp_channel_num>=2; only 1 or 2 is legal (elaboration $error otherwise). Single source of
# truth: also drives the tile->VLSU NumRespPorts (mempool_tile MshrDrainBeats).
group_mshr_drain_beats   ?=
# Hold-the-fetch request-hold merge window (docs/mshr_request_hold_design.md). Empty/unset/0 = OFF
# (every alloc issues its NoC fetch same-cycle; all hold logic const-folds out). Set =W (any W>0;
# the hold counter is sized from W, so there is no upper bound) to
# withhold each mergeable allocation's NoC fetch up to W cycles, releasing early once the entry
# reaches group_mshr_hold_subs subscribers -- extends the MSHR merge window by exactly the held
# cycles. group_mshr_hold_subs (default 2) = early-release sharing degree, legal range [2, merge_reqs].
group_mshr_hold_window   ?=
# Per-request-type hold windows (override the uniform group_mshr_hold_window): _single applies to
# 1-word (scalar) loads, _burst to multi-beat (vector) loads. Empty = inherit
# group_mshr_hold_window. A 0 window for a class means that class is never held (issues immediately).
group_mshr_hold_window_single ?=
group_mshr_hold_window_burst  ?=
group_mshr_hold_subs     ?=
# Per-request-type early-release targets (override the uniform group_mshr_hold_subs): _single
# applies to 1-word (scalar) entries, _burst to multi-beat (vector) entries. Empty = inherit
# group_mshr_hold_subs. Legal range [2, group_mshr_merge_reqs].
group_mshr_hold_subs_single ?=
group_mshr_hold_subs_burst  ?=
# Dual-context tcdm_burst_expander (docs/tcdm_burst_interleave_design.md). Empty/unset/0 = OFF
# (legacy stall-while-draining, bit-identical). Set =1 so a second LOAD is accepted while a burst
# drains and beats interleave round-robin -- same-address burst pairs then complete together
# instead of a drain-time apart (removes the intra-group pair-skew injection).
tcdm_burst_interleave    ?=
# MSHR bank-select hash (docs/mshr_bank_hash_design.md). 0/unset = legacy strided XOR-fold;
# 1 = xorshift-mixed fold that de-correlates address bits of one residue class (breaks temporal
# bank concentration). Both preserve coalescing (pure function of {group, line addr}).
group_mshr_bank_hash     ?=
# Per-request-type bank-select shifts for group_mshr_bank_hash=3 (override the uniform
# group_mshr_bank_shift): _single applies to 1-word (scalar) requests, _burst to multi-beat (vector)
# ones. Empty = inherit group_mshr_bank_shift (bit-identical to the single-shift behaviour).
group_mshr_bank_shift_single ?=
group_mshr_bank_shift_burst  ?=
# Cache self-invalidate (idea 1, docs/mshr_bank_hash_design.md). 0/unset = OFF (bit-identical);
# 1 = a CACHED entry frees itself once it has served its per-type sharing target
# (group_mshr_hold_subs_single for scalar/single, group_mshr_hold_subs_burst for burst), turning a
# done cache line into an INVALID way that the invalid-first allocator prefers. Cached entries stay
# reclaimable-on-demand regardless, so an unreached target cannot leak a way.
group_mshr_cache_self_inval ?=
# RR cache-victim selection. 0/unset = legacy lowest-index reclaimable CACHED way (way-0
# thrash); 1 = per-bank round-robin victim start pointer, advanced past the evicted way only
# when a reclaim actually fires. Bit-identical when 0.
group_mshr_cache_victim_rr ?=
vlog_defs += -DGROUP_MSHR_NUM=$(group_mshr_num)
ifneq ($(strip $(group_mshr_ways_per_bank)),)
  vlog_defs += -DGROUP_MSHR_WAYS_PER_BANK=$(group_mshr_ways_per_bank)
endif
vlog_defs += -DGROUP_MSHR_MERGE_REQS=$(group_mshr_merge_reqs)
vlog_defs += -DGROUP_MSHR_ENABLE_SINGLE=$(group_mshr_enable_single)
vlog_defs += -DGROUP_MSHR_ENABLE_STATS=$(group_mshr_enable_stats)
vlog_defs += -DGROUP_MSHR_STATS_PERIOD=$(group_mshr_stats_period)
ifneq ($(strip $(group_mshr_drain_beats)),)
  vlog_defs += -DGROUP_MSHR_DRAIN_BEATS=$(group_mshr_drain_beats)
endif
ifneq ($(strip $(group_mshr_hold_window)),)
  vlog_defs += -DGROUP_MSHR_HOLD_WINDOW=$(group_mshr_hold_window)
endif
ifneq ($(strip $(group_mshr_hold_window_single)),)
  vlog_defs += -DGROUP_MSHR_HOLD_WINDOW_SINGLE=$(group_mshr_hold_window_single)
endif
ifneq ($(strip $(group_mshr_hold_window_burst)),)
  vlog_defs += -DGROUP_MSHR_HOLD_WINDOW_BURST=$(group_mshr_hold_window_burst)
endif
ifneq ($(strip $(group_mshr_hold_subs)),)
  vlog_defs += -DGROUP_MSHR_HOLD_SUBS=$(group_mshr_hold_subs)
endif
ifneq ($(strip $(group_mshr_hold_subs_single)),)
  vlog_defs += -DGROUP_MSHR_HOLD_SUBS_SINGLE=$(group_mshr_hold_subs_single)
endif
ifneq ($(strip $(group_mshr_hold_subs_burst)),)
  vlog_defs += -DGROUP_MSHR_HOLD_SUBS_BURST=$(group_mshr_hold_subs_burst)
endif
ifneq ($(strip $(tcdm_burst_interleave)),)
  vlog_defs += -DTCDM_BURST_INTERLEAVE=$(tcdm_burst_interleave)
endif
ifneq ($(strip $(group_mshr_bank_hash)),)
  vlog_defs += -DGROUP_MSHR_BANK_HASH=$(group_mshr_bank_hash)
endif
ifneq ($(strip $(group_mshr_cache_self_inval)),)
  vlog_defs += -DGROUP_MSHR_CACHE_SELF_INVAL=$(group_mshr_cache_self_inval)
endif
ifneq ($(strip $(group_mshr_cache_victim_rr)),)
  vlog_defs += -DGROUP_MSHR_CACHE_VICTIM_RR=$(group_mshr_cache_victim_rr)
endif
ifeq ($(group_mshr_bank_dump), 1)
  vlog_defs += -DGROUP_MSHR_BANK_DUMP
endif
ifneq ($(strip $(group_mshr_bank_shift_single)),)
  vlog_defs += -DGROUP_MSHR_BANK_SHIFT_SINGLE=$(group_mshr_bank_shift_single)
endif
ifneq ($(strip $(group_mshr_bank_shift_burst)),)
  vlog_defs += -DGROUP_MSHR_BANK_SHIFT_BURST=$(group_mshr_bank_shift_burst)
endif
ifneq ($(strip $(group_mshr_bank_shift)),)
  vlog_defs += -DGROUP_MSHR_BANK_SHIFT=$(group_mshr_bank_shift)
endif
ifeq ($(group_merge_profiling), 1)
  vlog_defs += -DGROUP_MERGE_PROFILING
endif
# --------------------------
# Snitch ISA Extensions
# --------------------------
vlog_defs += -DXPULPIMG=$(xpulpimg)
vlog_defs += -DZFINX=$(zfinx)
vlog_defs += -DZQUARTERINX=$(zquarterinx)
vlog_defs += -DXDIVSQRT=$(xDivSqrt)
vlog_defs += -DSNITCH_TRACE=$(snitch_trace)
vlog_defs += -DSPATZ_TRACE=$(spatz_trace)
# --------------------------
# Spatz Core Settings
# --------------------------
# Use Spatz?
vlog_defs += -DRVV=$(spatz)
# 32b or 64b?
vlog_defs += -DRVF=$(rvf) -DRVD=$(rvd)
ifeq ($(spatz), 1)
	# VLEN, IPU, FPU counts
	vlog_defs   += -DVLEN=$(vlen) -DN_IPU=$(n_ipu) -DN_FPU=$(n_fpu)
	vlog_defs 	+= -DN_FU=$(shell awk 'BEGIN{print ($(n_ipu) > $(n_fpu)) ? $(n_ipu) : $(n_fpu)}')
	vlog_defs 	+= -DRESPWEN=1
	# spatz need wen signal on TCDM response channel for ACK handling
	# this bender_def is used to turn on this feature in interconnection
	bender_defs += -t spatz -t mempool
	SPATZ_DIR 	:= $(shell $(bender) path spatz)
	SPATZ_CLUSTER_DIR := $(SPATZ_DIR)/hw/system/spatz_cluster
endif
# --------------------------
# Spatz VLSU / ROB area-timing knobs (docs/spatz_mlp_design_plan.md)
# --------------------------
# R1: reorder_buffer free-id tracking from status_cnt_q instead of the id_valid_q
# bitmap. Unset/0 = legacy bitmap (bit-identical netlist); 1 deletes NumWords flops,
# the write-pointer decoder and the two NumWords:1 muxes per ROB -- a netlist change.
ifneq ($(strip $(spatz_rob_cnt_idvalid)),)
  vlog_defs += -DSPATZ_ROB_CNT_IDVALID=$(spatz_rob_cnt_idvalid)
endif
# R2: size the VLSU commit-metadata FIFO to the reachable occupancy
# (NrParallelInstructions) instead of NrOutstandingLoads. Unset/0 = legacy depth
# (bit-identical netlist); 1 = 8x smaller FIFO -- a netlist change.
ifneq ($(strip $(spatz_vlsu_commit_qmin)),)
  vlog_defs += -DSPATZ_VLSU_COMMIT_QMIN=$(spatz_vlsu_commit_qmin)
endif
# Block ROB-id reservation: the port-0 burst allocator reserves its whole MaxBurstWords id
# window in ONE cycle instead of walking one id per cycle (18 -> 3 cycles from burst
# eligibility to the request handshake, -30 cyc per two-burst load). Unset/0 = legacy walk
# (bit-identical netlist); 1 = block reservation.
ifneq ($(strip $(spatz_vlsu_block_alloc)),)
  vlog_defs += -DSPATZ_VLSU_BLOCK_ALLOC=$(spatz_vlsu_block_alloc)
endif
# ROB64: VLSU ROB 32->64 ids + system meta_id 5b->6b (docs/spatz_rob64_h1_design_plan.md).
# Unset = 32 (bit-identical). Moves THREE roots atomically (snitch_pkg::RobDepth, spatz
# NrOutstandingLoads, spatz_mem_rsp_t.id); spatz_mempool_cc elaboration asserts pin the pairing.
ifneq ($(strip $(spatz_vlsu_rob_depth)),)
  vlog_defs += -DSPATZ_VLSU_ROB_DEPTH=$(spatz_vlsu_rob_depth)
endif
# H1 dual-load runahead (validated only with spatz_vlsu_rob_depth=64). Unset = MaxInflight 1
# (bit-identical). 2 = a 2nd burst-safe load co-resident while the elder drains.
ifneq ($(strip $(spatz_vlsu_dual_load)),)
  vlog_defs += -DSPATZ_VLSU_DUAL_LOAD=$(spatz_vlsu_dual_load)
endif
# --------------------------
# AXI & DMA Configuration
# --------------------------
vlog_defs += -DAXI_DATA_WIDTH=$(axi_data_width)
vlog_defs += -DRO_LINE_WIDTH=$(ro_line_width)
# R-MCAST: 1-cycle multicast of the RO instruction-cache response to all merged tile icaches
# (docs/icache_rmcast_design.md). 0 = OFF, bit-identical. Default lives in config/config.mk.
vlog_defs += -DRO_CACHE_R_MCAST=$(ro_cache_r_multicast)
vlog_defs += -DDMAS_PER_GROUP=$(dmas_per_group)
vlog_defs += -DAXI_HIER_RADIX=$(axi_hier_radix)
vlog_defs += -DAXI_MASTERS_PER_GROUP=$(axi_masters_per_group)
# --------------------------
# Systolic Configurations
# --------------------------
vlog_defs += -DSEQ_MEM_SIZE=$(seq_mem_size)
vlog_defs += -DXQUEUE_SIZE=$(xqueue_size)
# --------------------------
# DRAMsys Co-Simulation
# --------------------------
vlog_defs += -D${l2_sim_type}
vlog_defs += -DAXI_WIDTH_INTERLEAVED=${axi_width_interleaved}
# --------------------------
# Profiling Options
# --------------------------
ifeq (1, $(spm_profiling))
	vlog_defs += -DSPM_PROFILING=$(spm_profiling)
endif
ifeq (1, $(noc_profiling))
	vlog_defs += -DNOC_PROFILING=$(noc_profiling)
endif
# --------------------------
# Remapping Controls
# --------------------------
vlog_defs += -DSPM_BANK_ID_REMAP=$(spm_bank_id_remap)
vlog_defs += -DTILE_ID_REMAP=$(tile_id_remap)
# --------------------------
# NoC Channel Configuration
# --------------------------
vlog_defs += -DNOC_REQ_RD_CHANNEL_NUM=$(noc_req_rd_channel_num)
ifneq (0, $(noc_req_rd_channel_num))
	vlog_defs += -DUSE_NARROW_REQ_CHANNEL
endif
vlog_defs += -DNOC_REQ_RDWR_CHANNEL_NUM=$(noc_req_rdwr_channel_num)
vlog_defs += -DNOC_REQ_WR_CHANNEL_NUM=$(noc_req_wr_channel_num)
vlog_defs += -DNOC_RESP_CHANNEL_NUM=$(noc_resp_channel_num)
# --------------------------
# Router Buffer Configuration
# --------------------------
vlog_defs += -DNOC_ROUTER_INPUT_FIFO_DEP=$(noc_router_input_fifo_dep)
vlog_defs += -DNOC_ROUTER_OUTPUT_FIFO_DEP=$(noc_router_output_fifo_dep)
vlog_defs += -DNOC_ROUTER_REMAP_GROUP_SIZE=$(noc_router_remap_group_size)
# Extra defines injected from command line (e.g. sweep scripts) without clobbering base config.
extra_vlog_defs ?=
vlog_defs += $(extra_vlog_defs)

# ============================================================================
# Verilator: C++ Preprocessor Defines ##
# ============================================================================
# --------------------------
# Traffic Generation
# --------------------------
ifdef tg
	tg_ncycles ?= 10000
	vlog_defs += -DTRAFFIC_GEN=1
	cpp_defs  += -DTRAFFIC_GEN=1
	cpp_defs  += -DTG_REQ_PROB=$(tg_reqprob)
	cpp_defs  += -DTG_SEQ_PROB=$(tg_seqprob)
	cpp_defs  += -DTG_NCYCLES=$(tg_ncycles)
	cpp_defs  += -DNUM_CORES=$(num_cores)
	# Simulation termination
	veril_flags := --term-after-cycles=$(tg_ncycles)
else
	tg          := 0
	veril_flags := --meminit=ram,$(preload)
endif
# --------------------------
# Memory Configuration
# --------------------------
cpp_defs += -DL2_BASE=$(l2_base)
cpp_defs += -DL2_SIZE=$(l2_size)
cpp_defs += -DL2_BANKS=$(l2_banks)
cpp_defs += -DAXI_DATA_WIDTH=$(axi_data_width)
cpp_defs += -DAXI_WIDTH_INTERLEAVED=$(axi_width_interleaved)

################
# Dependencies #
################

BENDER_ROOT ?= $(ROOT_DIR)/deps

# Ensure both Bender dependencies and (essential) submodules are checked out
$(BENDER_ROOT)/.teranoc_deps: $(bender)
	cd $(ROOT_DIR)/.. $(bender) checkout
# 	cd $(ROOT_DIR)/.. && git submodule update --init --recursive toolchain
	@touch $@

# Make sure dependencies are more up-to-date than any targets run
ifeq ($(shell test -f $(BENDER_ROOT)/.teranoc_deps && echo 1),)
-include $(BENDER_ROOT)/.teranoc_deps
endif

# Generate required Spatz files (spatz_pkg.sv)
.PHONY: buildspatz
buildspatz:
	export PYTHON=$(python);
	$(MAKE) -BC $(shell $(bender) path spatz)/hw/system/spatz_cluster \
		SPATZ_CLUSTER_CFG=$(shell $(bender) path spatz)/hw/system/spatz_cluster/cfg/mempool.hjson \
		generate PYTHON=$(python);


# Running this target will reset dependencies (without updating the checked-in Bender.lock)
.PHONY: clean-deps
clean-deps:
	cd $(BENDER_ROOT) && rm -rf \
		apb \
		axi \
		axi_riscv_atomics \
		cluster_icache \
		cluster_interconnect \
		common_cells \
		common_verification \
		floo_noc \
		fpnew \
		fpu_div_sqrt_mvp \
		register_interface \
		tech_cells_generic \
		spatz
	rm -f $(BENDER_ROOT)/.teranoc_deps
# 	cd $(ROOT_DIR)/.. && git submodule deinit -f toolchain/*

##########################
## Default Build Target ##
##########################
.DEFAULT_GOAL := compile

##################
## Build Path ##
##################
$(buildpath):
	mkdir -p $(buildpath)

##################
## Bender Setup ##
##################
$(bender):
	make -C $(MEMPOOL_DIR) bender

################
# Modelsim     #
################
# Library
.PHONY: lib
lib: $(buildpath) $(buildpath)/$(library)
$(buildpath)/$(library):
	cd $(buildpath) && $(questa_cmd) vlib $(library) && chmod +w modelsim.ini; $(questa_cmd) vmap $(library) $(library)

# FlooGen Update
.PHONY: update-floogen
update-floogen:
	$(MAKE) -C .. FLOO_CFG=./config/floo_noc_$(config).yml update-floonoc config=$(config)

# Compilation
.PHONY: gen_selector
gen_selector: scripts/gen_xbar.py
	$< -in ${num_cores_per_tile} -on $$(($(num_remote_ports_per_tile) - 1)) -o src/selector.sv

.PHONY: compile
compile: update-floogen dpi lib $(buildpath) $(buildpath)/compile.tcl update_opcodes
$(buildpath)/compile.tcl: $(bender) $(config_mk) Makefile $(MEMPOOL_DIR)/Bender.yml $(shell find {src,tb,deps} -type f)
	$(bender) script vsim --vlog-arg="$(vlog_args)" $(vlog_defs) -t rtl -t mempool_vsim $(bender_defs) > $(buildpath)/compile.tcl
	echo "exit" >> $(buildpath)/compile.tcl
	cd $(buildpath) && $(questa_cmd) vsim -work $(library) -c -do compile.tcl
	echo $(questa_config) >> $(buildpath)/modelsim.ini

# Simulation
.PHONY: sim
sim: clean-dasm compile
	cd $(buildpath) && \
	ulimit -n $(sim_ulimit_n) 2>/dev/null || true; \
	$(questa_cmd) vsim -voptargs=$(questa_voptargs) -wlf $(questa_wlf) $(questa_args) $(library).$(top_level) -do "set config ${config}" -do ../scripts/questa/run.tcl
	./scripts/return_status.sh $(buildpath)/transcript

.PHONY: simc
simc: clean-dasm compile
	cd $(buildpath) && \
	ulimit -n $(sim_ulimit_n) 2>/dev/null || true; \
	$(questa_cmd) vsim -c -voptargs=$(questa_voptargs) -wlf $(questa_wlf) $(questa_args) $(library).$(top_level) -do "log -r *" -do "run -a"
	./scripts/return_status.sh $(buildpath)/transcript

# 	$(questa_cmd) vsim -c $(questa_args) $(library).$(top_level) -do "run -a"
# 	$(questa_cmd) vsim -c -voptargs=$(questa_voptargs) -wlf $(questa_wlf) $(questa_args) $(library).$(top_level) -do "log -r *" -do "run -a"

# DPIs
.PHONY: dpi
dpi: $(buildpath)/$(dpi_library)/mempool_dpi.so

$(buildpath)/$(dpi_library)/%.o: tb/dpi/%.cpp
	mkdir -p $(buildpath)/$(dpi_library)
	$(CXX) -shared -fPIC -std=c++11 -Bsymbolic -c $< -I$(QUESTASIM_HOME)/include -o $@

$(buildpath)/$(dpi_library)/mempool_dpi.so: $(dpi)
	mkdir -p $(buildpath)/$(dpi_library)
	$(CXX) -shared -m64 -o $(buildpath)/$(dpi_library)/mempool_dpi.so $^

################
# VCS          #
################
# Elaboration
.PHONY: elabvcs
elabvcs: dpivcs $(buildpath) $(buildpath)/compilevcs.sh update_opcodes
$(buildpath)/compilevcs.sh: $(bender) $(config_mk) Makefile $(MEMPOOL_DIR)/Bender.yml $(shell find {src,tb,deps} -type f)
	$(bender) script vcs --vlogan-bin="$(vcs_cmd) vlogan" --vlog-arg="$(vlogan_args)" $(vlog_defs) -t rtl -t mempool_vsim $(bender_defs) > $(buildpath)/compilevcs.sh
	echo "exit" >> $(buildpath)/compilevcs.sh
	# Call VCS
	cd $(buildpath) && \
	chmod +x compilevcs.sh && \
	./compilevcs.sh

# Compilation
.PHONY: compile_vcs_simv compile_vcs_simvopt

compile_vcs_simv: update-floogen elabvcs $(buildpath)/mempool_simv
$(buildpath)/mempool_simv: $(buildpath)/compilevcs.sh $(buildpath)/$(dpi_library)/mempool_vcs_dpi.so
	cd $(buildpath) && \
	$(vcs_cmd) vcs -full64 $(top_level) -cc $(CC) -cpp $(CXX) -ld $(CXX) $(dpi_library)/mempool_vcs_dpi.so $(vcs_config) -debug_access+all -kdb -assert disable_cover -o mempool_simv

compile_vcs_simvopt: update-floogen elabvcs $(buildpath)/mempool_simvopt
$(buildpath)/mempool_simvopt: $(buildpath)/compilevcs.sh $(buildpath)/$(dpi_library)/mempool_vcs_dpi.so
	cd $(buildpath) && \
	$(vcs_cmd) vcs -full64 $(top_level) -cc $(CC) -cpp $(CXX) -ld $(CXX) $(dpi_library)/mempool_vcs_dpi.so $(vcs_config) -assert disable_cover -o mempool_simvopt

# Simulation
simvcs: compile_vcs_simv
	cd $(buildpath) && \
	./mempool_simv $(vcs_args) -ucli -l transcript -do ../scripts/vcs/run.tcl -gui

simcvcs: compile_vcs_simvopt
	cd $(buildpath) && \
	./mempool_simvopt $(vcs_args) -l transcript

# DPIs
.PHONY: dpivcs
dpivcs: $(buildpath)/$(dpi_library)/mempool_vcs_dpi.so

$(buildpath)/$(dpi_library)/%_vcs.o: tb/dpi/%.cpp
	mkdir -p $(buildpath)/$(dpi_library)
	$(CXX) -shared -fPIC -std=c++11 -Bsymbolic -c $< -I$(VCS_HOME)/include -o $@

$(buildpath)/$(dpi_library)/mempool_vcs_dpi.so: $(dpi_vcs)
	mkdir -p $(buildpath)/$(dpi_library)
	$(CXX) -shared -m64 -o $(buildpath)/$(dpi_library)/mempool_vcs_dpi.so $^

################
# Verilator    #
################
VERILATOR_SRC   := $(ROOT_DIR)/tb/verilator
VERILATOR_LIBS  := $(shell find $(VERILATOR_SRC) -name "*.cc" -print | sort)
VERILATOR_INCS  := $(shell find $(VERILATOR_SRC) -name "cpp" -print | sort)
VERILATOR_EXE   := $(verilator_build)/V$(verilator_top)
VERILATOR_MK    := $(VERILATOR_EXE).mk
VERILATOR_WAIVE := $(shell find $(VERILATOR_SRC) -name "*.vlt" -print | sort)
VERILATOR_CONF  := $(VERILATOR_SRC)/verilator.flags

VERILATOR_FLAGS += -Wno-fatal
VERILATOR_FLAGS += -CFLAGS "-DTOPLEVEL_NAME=$(verilator_top)"
VERILATOR_FLAGS += --Mdir $(verilator_build)
VERILATOR_FLAGS += -f $(verilator_files)
VERILATOR_FLAGS += -f $(VERILATOR_CONF)
VERILATOR_FLAGS += $(VERILATOR_WAIVE)
# Uncomment the following line to enable verilator waveform dumping
# VERILATOR_FLAGS += --trace --trace-fst --trace-structs --trace-params --trace-max-array 1024
# Uncomment the following line to enable verilator debug mode
# VERILATOR_FLAGS += --debug

# We need to link the verilated model against LLVM's libc++.
# Define CLANG_PATH to be the path of your Clang installation.
# At IIS, check .gitlab/.gitlab-ci.yml for an example CLANG_PATH.

ifneq (${CLANG_PATH},)
  VERILATOR_FLAGS += -CFLAGS "-nostdinc++ -isystem $(CLANG_PATH)/include/c++/v1"
  VERILATOR_FLAGS += -LDFLAGS "-L $(CLANG_PATH)/lib -Wl,-rpath,$(CLANG_PATH)/lib -lc++ -nostdlib++"
endif

ifeq ($(CI_REUSE_MODEL),true) # if ci already build the verilator model, don't rebuild again
$(VERILATOR_MK): $(VERILATOR_CONF) $(VERILATOR_WAIVE) $(MEMPOOL_DIR)/Bender.yml $(shell find {src,tb,deps} -type f) $(bender) $(config_mk) Makefile
else
$(VERILATOR_MK): update-floogen $(VERILATOR_CONF) $(VERILATOR_WAIVE) $(MEMPOOL_DIR)/Bender.yml $(shell find {src,tb,deps} -type f) $(bender) $(config_mk) Makefile
endif
	rm -rf $(verilator_build); mkdir -p $(verilator_build)
	# Overwrite Bootaddress to L2 base while we don't have a DPI to write a wake-up
	$(eval boot_addr=$(l2_base))
	# Create Bender script of all RTL files
	$(bender) script verilator $(vlog_defs) -t rtl -t mempool_verilator $(bender_defs) -DCOMMON_CELLS_ASSERTS_OFF > $(verilator_files)
	# Append the verilator library files
	@echo '' >> $(verilator_files)
	# Append the verilator library files: Includes
	@echo $(addprefix +incdir+,$(VERILATOR_INCS)) | tr ' ' '\n' >> $(verilator_files)
	for i in $(VERILATOR_INCS); do echo "-CFLAGS -I$${i}" >> $(verilator_files); done
	# Append the CPP defines
	@echo "-CFLAGS \"$(cpp_defs)\"" >> $(verilator_files)
	# Append the verilator library files: source files
	@echo $(VERILATOR_LIBS) | tr ' ' '\n'  >> $(verilator_files)
	# Create Verilator Makefile
	$(verilator) $(VERILATOR_FLAGS) --top-module $(verilator_top)

$(VERILATOR_EXE): $(VERILATOR_MK) $(shell find $(VERILATOR_SRC) -type f) Makefile
	make -j4 -C $(verilator_build) -f $<

verilate: $(VERILATOR_EXE) $(buildpath) Makefile
	cd $(buildpath) && $(VERILATOR_EXE) $(veril_flags) | tee transcript
	# Avoid capturing the return status when running the load-throughput analysis
	if [ $(tg) -ne 1 ]; then ./scripts/return_status.sh $(buildpath)/transcript; fi

#############
# Lint      #
#############
SPYGLASS_WORK_DIR ?= spyglass

.PHONY: lint $(SPYGLASS_WORK_DIR)/tmp/files

SNPS_SG ?= spyglass-2022.06
SG_SCRIPT_PATH ?= scripts
SG_SCRIPT_SUF ?=
lint: update-floogen $(SPYGLASS_WORK_DIR)/tmp/files $(SPYGLASS_WORK_DIR)/sdc/func.sdc $(SPYGLASS_WORK_DIR)/scripts/run_lint.tcl
	cd $(SPYGLASS_WORK_DIR); config=$(config) $(SNPS_SG) sg_shell -tcl $(SG_SCRIPT_PATH)/run_lint$(SG_SCRIPT_SUF).tcl

# Build file list, use subst to remove the "32'd" which spyglass can't handle
$(SPYGLASS_WORK_DIR)/tmp/files%: $(bender)
	mkdir -p $(SPYGLASS_WORK_DIR)/tmp
	$(bender) script verilator $(subst 32\'d,,$(vlog_defs)) -t rtl -t mempool_verilator $(bender_defs) > $@

################
# Tracing      #
################

# Give configuration in env
trace_env += NUM_CORES=$(num_cores)
trace_env += SEQ_MEM_SIZE=$(seq_mem_size)

benchmark: log simcvcs
	# Call `make` again to get variable extension with all traces
	result_dir=$(result_dir) $(MAKE) trace

trace: pre_trace $(trace) post_trace

log:
	mkdir -p "$(result_dir)"
	[ -e "$(preload)" ] && cp "$(preload)"* "$(result_dir)" || \
	([ -e "$(buildpath)/transcript" ] && \
	cp "$$(grep -oP '(?<=\+PRELOAD=)[^ \"]*' $(buildpath)/transcript)"* "$(result_dir)" || \
	echo "No application specified")
	env > "$(result_dir)/env"
	cp $(MEMPOOL_DIR)/config/config.mk $(result_dir)/config
	git rev-parse HEAD > "$(result_dir)/git-info.diff"
	git show --oneline -s >> "$(result_dir)/git-info.diff"
	git diff >> "$(result_dir)/git-info.diff"

pre_trace:
	rm -rf $(tracepath)

post_trace:
	mkdir -p "$(result_dir)"
	cp $(buildpath)/transcript "$(result_dir)/" | true
	cp $(traceresult) "$(result_dir)"
	printf "%s\n" $(trace) | xargs -n 100 cp -t "$(result_dir)"
	$(python) $(ROOT_DIR)/scripts/gen_avg.py --folder "$(result_dir)" | tee $(result_dir)/avg.txt

$(buildpath)/%.trace: $(buildpath)/%.dasm
	mkdir -p $(tracepath)
	$(INSTALL_DIR)/riscv-isa-sim/bin/spike-dasm < $< > $(tracepath)/$*
	$(trace_env) $(python) $(ROOT_DIR)/scripts/gen_trace.py -p --csv $(traceresult) $(tracepath)/$* > $@

tracevis:
	$(MEMPOOL_DIR)/scripts/tracevis.py $(preload) $(buildpath)/*.trace -o $(buildpath)/tracevis.json

# Post-process the per-Spatz-core vector traces (trace_spatz_insn_hart_*.log +
# trace_spatz_cyc_hart_*.log emitted by spatz_mempool_cc.sv) into readable per-core timelines and
# FU-utilization / stall-reason summaries. Reads from $(buildpath); writes $(buildpath)/spatz_traces.
spatz-trace:
	$(python) $(ROOT_DIR)/scripts/gen_spatz_trace.py --buildpath $(buildpath) --out $(buildpath)/spatz_traces

############################
# NoC traffic visualization #
############################
noc_vis_W ?= $(num_x)
noc_vis_H ?= $(shell echo $$(( $(num_groups) / $(num_x) )))
noc_vis_tiles_per_group ?= $(shell echo $$(( $(num_cores) / $(num_cores_per_tile) / $(num_groups) )))

noc-vis: $(buildpath)/v4m_out/trace_events.csv
	$(python) scripts/noc_visualization/gen_v4m_from_csv.py \
		$< $(buildpath)/vis4mesh_out \
		--W $(noc_vis_W) --H $(noc_vis_H) \
		--tiles-per-group $(noc_vis_tiles_per_group) \
		--narrow-req-ch $(noc_req_rd_channel_num) \
		--wide-req-ch $(noc_req_rdwr_channel_num) \
		--resp-ch $(noc_resp_channel_num) \
		--cycles-per-slice 10 --debug

############################
# Unit tests simulation    #
############################
TESTS_DIR := $(abspath $(ROOT_DIR)/../software/riscv-tests/isa)
include $(TESTS_DIR)/snitch_isa.mk

test_result_dir_vsim := $(resultpath)/test_result_vsim
test_result_dir_verilate := $(resultpath)/test_result_verilate

tests_vsim := $(addsuffix .out,$(addprefix $(test_result_dir_vsim)/,$(rtl_mempool_tests)))
tests_verilate := $(addsuffix .out,$(addprefix $(test_result_dir_verilate)/,$(rtl_mempool_tests)))

simc_test: clean-dasm compile $(buildpath) $(tests_vsim)
verilate_test: clean-dasm $(VERILATOR_EXE) $(buildpath) $(tests_verilate)

$(tests_vsim): $(test_result_dir_vsim)/%.out : $(app_path)/%
	mkdir -p $(test_result_dir_vsim)
	cd $(buildpath) && \
	ulimit -n $(sim_ulimit_n) 2>/dev/null || true; \
	$(questa_cmd) vsim -c $(questa_args) +PRELOAD=$< $(library).$(top_level) -do "run -a"
	./scripts/return_status.sh $(buildpath)/transcript > $@

$(tests_verilate): $(test_result_dir_verilate)/%.out : $(app_path)/%
	mkdir -p $(test_result_dir_verilate)
	cd $(buildpath) && $(VERILATOR_EXE) --meminit=ram,$< | tee transcript
	./scripts/return_status.sh $(buildpath)/transcript > $@

################
# Helper       #
################

# Bootrom
src/bootrom.sv: $(MEMPOOL_DIR)/software/runtime/bootrom.img $(config_mk) Makefile
	$(python) ./scripts/generate_bootrom.py --sv --output src/bootrom --datawidth $(axi_data_width) $<

$(MEMPOOL_DIR)/software/runtime/bootrom.img:
	make -C $(MEMPOOL_DIR)/software runtime/bootrom.img

# Control Register
CONTROL_REG_DIR := src/control_registers
$(CONTROL_REG_DIR)/control_registers_reg_top.sv: $(CONTROL_REG_DIR)/control_registers.hjson
	make -C $(CONTROL_REG_DIR) all

# Clean targets
.PHONY: clean clean-dasm clean-trace update_opcodes

update_opcodes:
	make -C $(MEMPOOL_DIR) update_opcodes

clean:
	@rm -rf $(buildpath)
	@rm -rf $(verilator_build)

clean-dasm:
	rm -rf $(buildpath)/*.dasm

clean-trace:
	rm -rf $(buildpath)/*.trace
