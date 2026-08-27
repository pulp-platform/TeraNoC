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
# -kdb builds the Verdi knowledge database during analysis. Only the debug flow
# (mempool_simv, opened in Verdi) ever reads it; mempool_simvopt never does, so for a
# headless run it is pure analysis cost. Drop it with `vcs_kdb=`.
vcs_kdb ?= -kdb
vlogan_args += -assert svaext +v2k -override_timescale=1ns/1ps $(vcs_kdb)
# Parallel C compilation of the generated model. VCS is serial by default and the
# generated C dominates elaboration at 1024 cores. Override with vcs_jobs=N.
vcs_jobs ?= 16
ifdef app
  # Parity with questa_args (+APP): TB code keyed on the application name needs this.
  vcs_args += +APP=$(app)$(app_suf)
endif
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
# Group-barrier watchdog in cycles. 0/unset = NO watchdog: the barrier waits until all `target`
# cores arrive (the intended rendezvous). A non-zero W force-releases the arrived subset after W
# cycles from the first arrival -- that does not synchronize, it splits the group into cohorts one
# round apart and every later barrier times out too. Use W > 0 only as a debug deadlock escape.
group_barrier_wd_limit ?=
ifneq ($(strip $(group_barrier_wd_limit)),)
  vlog_defs += -DGROUP_BARRIER_WD_LIMIT=$(group_barrier_wd_limit)
endif
# Reserved within-tile word base for the group barrier. MUST match GROUP_BARRIER_WORD on the
# software side (software/runtime/runtime.mk -> arch.ld.c truncates L1 at this word, and
# barrier-using apps derive GBAR_BASE_WORD from it). See mempool_group.sv GroupBarrierWord.
group_barrier_word ?= 240
vlog_defs += -DGROUP_BARRIER_WORD=$(group_barrier_word)
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
# No config defines `num_remote_ports_per_tile`, so this expanded unconditionally to a bare
# `-DNUM_REMOTE_PORTS_PER_TILE=` -- the malformed empty-value form this file already warns about
# for the group_mshr knobs. QuestaSim tolerates it; a backend `analyze` need not, and the macro is
# read by no RTL (only the orphaned selector.sv generator at the bottom uses the make variable).
# Guard it like every other optional knob so the define appears only when something sets it.
ifneq ($(strip $(num_remote_ports_per_tile)),)
  vlog_defs += -DNUM_REMOTE_PORTS_PER_TILE=$(num_remote_ports_per_tile)
endif
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
# Scalar response-release policy. 0/unset = drain a returned scalar word immediately. 1 = retain
# it in the MSHR and keep merging same-address scalar requests until group_mshr_hold_subs_single
# subscribers are present, then multicast the buffered word. Independent of the request hold window.
group_mshr_resp_wait_subs_single ?=
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
# Intra-load burst bits in the hash-3 burst bank index: clog2(bursts per vector load) =
# clog2(VL/MaxBurstWords) -> m1=0, m2=1, m4=2, m8=3. Empty = 1 (m2).
group_mshr_bank_burst_bits ?=
# Response cache (MSHR_CACHED). Empty/1 = ON (default, keeps responded entries as a small
# read-response cache); 0 = DRAIN_RESP goes straight to IDLE, disabling same-address reuse.
group_mshr_resp_cache ?=
# Cache reuse target / cache-phase timeout. Empty or 0 = legacy (self-invalidate at hold_subs,
# cache phase re-armed from serve_timeout). With group_mshr_cfg_runtime=1 these are RESET values
# only -- software owns them at runtime.
group_mshr_cache_reuse_target ?=
group_mshr_cache_timeout ?=
group_mshr_bankfull_backpressure ?=
# Cache self-invalidate (idea 1, docs/mshr_bank_hash_design.md). 0/unset = OFF (bit-identical);
# 1 = a CACHED entry frees itself once it has served its per-type sharing target
# (group_mshr_hold_subs_single for scalar/single, group_mshr_hold_subs_burst for burst), turning a
# done cache line into an INVALID way that the invalid-first allocator prefers. Whether an idle
# CACHED line is also reclaimable by allocation is controlled by group_mshr_cache_reclaimable.
group_mshr_cache_self_inval ?=
# RR cache-victim selection. 0/unset = legacy lowest-index reclaimable CACHED way (way-0
# thrash); 1 = per-bank round-robin victim start pointer, advanced past the evicted way only
# when a reclaim actually fires. Bit-identical when 0.
group_mshr_cache_victim_rr ?=
# CACHED replacement policy. 1/unset = CACHED ways are allocator victims when their bank has no
# invalid way (legacy behavior). 0 = protect CACHED ways until self-invalidation or AMO invalidation.
group_mshr_cache_reclaimable ?=
# Bypass-path delivery probe (SIM ONLY, pragma translate_off -- no synthesis impact).
# 1 = pair each entry-less (mshr_tag==0) single-beat forward against the bypass response
# returned to the tile; report [BYP ORPHAN] the cycle a response arrives with no outstanding
# forward, plus a periodic [BYP] fwd/rsp/orphan summary. Silent otherwise.
group_mshr_bypass_probe ?=
# RESP_HOLD stall probe (SIM ONLY). Age in cycles after which a still-held entry is reported once
# with the evidence needed to explain WHY it never reached its subscriber target: same-address
# requests LOST to the bypass path (byp) vs merely stalled (stl), same-address peer entries, and
# the bank's per-state way census. 0/unset = off.
group_mshr_resp_hold_probe ?=
# Serve-target timeout in cycles for an entry holding data while waiting to reach its serve target.
# 0/unset = no timeout (an unreachable target wedges the entry and eventually the whole bank).
# W > 0 behaves like group_mshr_hold_window: a free-running countdown, so liveness holds for any
# target. Covers RESP_HOLD (deliver to whoever subscribed) and CACHED below target (self-invalidate).
group_mshr_serve_timeout ?=
# Same-address request handling while that entry is receiving its response. 1/unset = STALL and
# retry (the request merges next cycle, into RESP_HOLD or the resulting CACHED line). 0 = legacy:
# the request misses and allocates a SECOND way for the same address, costing a redundant NoC fetch
# and leaving both entries short of their subscriber target.
group_mshr_stall_on_resp ?=
# Prescaler for the hold/serve countdown, in bits. Each entry stores its window in ticks of 2**W
# cycles instead of cycles, so hold_cnt loses W bits and toggles 2**W times less often; entry e
# takes its tick when the shared prescaler equals e[W-1:0], which spreads expiries instead of
# releasing every held fetch on one grid tick. Default 4 (+-16 cycles on a window that is a
# coalescing heuristic). 0 = exact cycle-accurate countdown.
group_mshr_hold_prescale_w ?=
ifneq ($(strip $(group_mshr_hold_prescale_w)),)
  vlog_defs += -DGROUP_MSHR_HOLD_PRESCALE_W=$(group_mshr_hold_prescale_w)
endif
# Each knob needs its OWN guard: nesting them under the prescaler's made them silently vanish for
# any config that leaves group_mshr_hold_prescale_w unset, and expand to a malformed -DX= for any
# config that does not define the knob itself.
group_mshr_drain_from_q ?=
ifneq ($(strip $(group_mshr_drain_from_q)),)
  vlog_defs += -DGROUP_MSHR_DRAIN_FROM_Q=$(group_mshr_drain_from_q)
endif
group_mshr_bank_publish ?=
ifneq ($(strip $(group_mshr_bank_publish)),)
  vlog_defs += -DGROUP_MSHR_BANK_PUBLISH=$(group_mshr_bank_publish)
endif
group_mshr_spill_req_in ?=
ifneq ($(strip $(group_mshr_spill_req_in)),)
  vlog_defs += -DGROUP_MSHR_SPILL_REQ_IN=$(group_mshr_spill_req_in)
endif
# Runtime-configurable MSHR (docs/mshr_runtime_csr_design.md). 0 = every CSR const-folds to its
# elaborated default and the hold block still folds away on shapes that pin the window to 0 --
# bit-identical to the pre-CSR design, and what a fixed-function tapeout wants. 1 = software-writable
# through the group-barrier port. Development and characterisation builds want 1: it turns a
# sweep-per-config into configs-per-simulation.
group_mshr_cfg_runtime ?=
ifneq ($(strip $(group_mshr_cfg_runtime)),)
  vlog_defs += -DGROUP_MSHR_CFG_RUNTIME=$(group_mshr_cfg_runtime)
endif
ifneq ($(strip $(group_mshr_stall_on_resp)),)
  vlog_defs += -DGROUP_MSHR_STALL_ON_RESP=$(group_mshr_stall_on_resp)
endif
ifneq ($(strip $(group_mshr_serve_timeout)),)
  vlog_defs += -DGROUP_MSHR_SERVE_TIMEOUT=$(group_mshr_serve_timeout)
endif
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
ifneq ($(strip $(group_mshr_resp_wait_subs_single)),)
  vlog_defs += -DGROUP_MSHR_RESP_WAIT_SUBS_SINGLE=$(group_mshr_resp_wait_subs_single)
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
ifneq ($(strip $(group_mshr_resp_cache)),)
  vlog_defs += -DGROUP_MSHR_RESP_CACHE=$(group_mshr_resp_cache)
endif
ifneq ($(strip $(group_mshr_cache_reuse_target)),)
  vlog_defs += -DGROUP_MSHR_CACHE_REUSE_TARGET=$(group_mshr_cache_reuse_target)
endif
ifneq ($(strip $(group_mshr_cache_timeout)),)
  vlog_defs += -DGROUP_MSHR_CACHE_TIMEOUT=$(group_mshr_cache_timeout)
endif
ifneq ($(strip $(group_mshr_bankfull_backpressure)),)
  vlog_defs += -DGROUP_MSHR_BANKFULL_BACKPRESSURE=$(group_mshr_bankfull_backpressure)
endif
ifneq ($(strip $(group_mshr_cache_victim_rr)),)
  vlog_defs += -DGROUP_MSHR_CACHE_VICTIM_RR=$(group_mshr_cache_victim_rr)
endif
ifneq ($(strip $(group_mshr_cache_reclaimable)),)
  vlog_defs += -DGROUP_MSHR_CACHE_RECLAIMABLE=$(group_mshr_cache_reclaimable)
endif
ifneq ($(strip $(group_mshr_bypass_probe)),)
  vlog_defs += -DGROUP_MSHR_BYPASS_PROBE=$(group_mshr_bypass_probe)
endif
ifneq ($(strip $(group_mshr_resp_hold_probe)),)
  vlog_defs += -DGROUP_MSHR_RESP_HOLD_PROBE=$(group_mshr_resp_hold_probe)
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
ifneq ($(strip $(group_mshr_bank_burst_bits)),)
  vlog_defs += -DGROUP_MSHR_BANK_BURST_BITS=$(group_mshr_bank_burst_bits)
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
# Per-port ROB depth: ports 1..N-1 only (ROB0 keeps spatz_vlsu_rob_depth). Bursts use ROB0
# alone -- ParityDrain lands even beats from mem port 0 and odd beats from mem port 1 in ROB0's
# id range -- so ROBs 1-3 hold no burst data and need not match ROB0's depth. Unset = equal to
# spatz_vlsu_rob_depth (bit-identical). Shrinking costs NON-burst memory-level parallelism.
#   "ROB0 deep, rest shallow": spatz_vlsu_rob_depth=128 spatz_vlsu_robn_depth=16
ifneq ($(strip $(spatz_vlsu_robn_depth)),)
  vlog_defs += -DSPATZ_VLSU_ROBN_DEPTH=$(spatz_vlsu_robn_depth)
endif
# H1 dual-load runahead (validated only with spatz_vlsu_rob_depth=64). Unset = MaxInflight 1
# (bit-identical). 2 = a 2nd burst-safe load co-resident while the elder drains.
ifneq ($(strip $(spatz_vlsu_dual_load)),)
  vlog_defs += -DSPATZ_VLSU_DUAL_LOAD=$(spatz_vlsu_dual_load)
endif
# Sub-word burst eligibility. Unset/0 = LEGACY: only vsew == EW_32 may take the port-0 burst
# path, so a vle16.v never reaches the group MSHR's burst class (no burst merge, no ParityDrain,
# no BlockAlloc) -- bit-identical netlist. 1 = admit every element width except EW_8.
# The BURST LENGTH IS UNCHANGED: MaxBurstWords 32-bit words (64 B) in both modes, so the MSHR,
# the burst expander and the NoC see an identical burst stream. Only the eligibility test widens,
# and it widens to something CHEAPER (|vsew instead of a 2-bit equality against EW_32).
ifneq ($(strip $(spatz_vlsu_burst_ew16)),)
  vlog_defs += -DSPATZ_VLSU_BURST_EW16=$(spatz_vlsu_burst_ew16)
endif
# --------------------------
# AXI & DMA Configuration
# --------------------------
vlog_defs += -DAXI_DATA_WIDTH=$(axi_data_width)
vlog_defs += -DRO_LINE_WIDTH=$(ro_line_width)
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

# Headless simulation WITHOUT full-visibility elaboration or whole-design logging.
#
# simc asks vopt for +acc (which suppresses most optimisation so every signal stays
# addressable) and then logs the entire hierarchy with "log -r *". That is the right
# default at 256 cores, where you usually want the waveform. It does not survive the
# scale-up: at 1024 cores vopt alone did not finish in 60 minutes, and a full "log -r *"
# over 1024 cores would produce a WLF too large to be useful anyway.
#
# This target drops both. Use it for "does it elaborate, boot and finish?" runs. The TB
# instrumentation ([LP], [BP], [CMS], [GroupMerge], [UART]) all report through $display,
# so it survives here untouched -- only waveform visibility is given up. Use simc when
# you actually need to look at signals.
.PHONY: simc-lean
simc-lean: clean-dasm compile
	cd $(buildpath) && \
	ulimit -n $(sim_ulimit_n) 2>/dev/null || true; \
	$(questa_cmd) vsim -c $(questa_args) $(library).$(top_level) -do "run -a"
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
	$(vcs_cmd) vcs -full64 -j$(vcs_jobs) $(top_level) -cc $(CC) -cpp $(CXX) -ld $(CXX) $(dpi_library)/mempool_vcs_dpi.so $(vcs_config) -debug_access+all -kdb -assert disable_cover -o mempool_simv

compile_vcs_simvopt: update-floogen elabvcs $(buildpath)/mempool_simvopt
$(buildpath)/mempool_simvopt: $(buildpath)/compilevcs.sh $(buildpath)/$(dpi_library)/mempool_vcs_dpi.so
	cd $(buildpath) && \
	$(vcs_cmd) vcs -full64 -j$(vcs_jobs) $(top_level) -cc $(CC) -cpp $(CXX) -ld $(CXX) $(dpi_library)/mempool_vcs_dpi.so $(vcs_config) -assert disable_cover -o mempool_simvopt

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
	# ASSERTS_OFF gates common_cells' INC_ASSERT; COMMON_CELLS_ASSERTS_OFF alone does not,
	# and the surviving `ASSERT macros use SVA that Verilator 4.x cannot parse.
	$(bender) script verilator $(vlog_defs) -t rtl -t mempool_verilator $(bender_defs) -DCOMMON_CELLS_ASSERTS_OFF -DASSERTS_OFF > $(verilator_files)
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
# The bender target set below pulls in the TESTBENCH (-t mempool_verilator). Spyglass hits its
# non-synthesizable constructs, prints "Syntax Errors detected - RULE CHECKING ABORTED" and runs
# ZERO rules -- while make still exits 0. Those files are excluded from the source list; override
# SPYGLASS_EXCLUDE='' to lint them anyway.
SPYGLASS_EXCLUDE ?= /hardware/tb/|/common_verification/src/(clk_rst_gen|sim_timeout|stream_watchdog|signal_highlighter)

lint: update-floogen $(SPYGLASS_WORK_DIR)/tmp/files $(SPYGLASS_WORK_DIR)/sdc/func.sdc $(SPYGLASS_WORK_DIR)/scripts/run_lint.tcl
	@# hardware/generated/ is SHARED by every build and encodes the mesh, and one of its three
	@# files is untracked. If update-floogen silently failed (it needs python>=3.10 and
	@# verible-verilog-format on PATH) the wrong mesh is still in place and the lint would check
	@# a design that is not this config.
	@if [ -n "$(num_x)" ] && [ -f generated/perimeter_map_pkg.sv ]; then \
	  mesh=`grep -m1 -oE 'NumMeshX *= *[0-9]+' generated/perimeter_map_pkg.sv | grep -oE '[0-9]+$$'`; \
	  if [ "$$mesh" != "$(num_x)" ]; then \
	    echo "[lint] ERROR: hardware/generated/ holds a $${mesh}x mesh, config=$(config) needs $(num_x)."; \
	    echo "[lint]        update-floogen did not regenerate it -- check python3 --version (>=3.10)"; \
	    echo "[lint]        and 'which verible-verilog-format'."; \
	    exit 1; \
	  fi; \
	  echo "[lint] mesh NumMeshX=$$mesh matches config=$(config)"; \
	fi
	@before=`wc -l < $(SPYGLASS_WORK_DIR)/sg_shell.log 2>/dev/null || echo 0`; \
	cd $(SPYGLASS_WORK_DIR); config=$(config) $(SNPS_SG) sg_shell -tcl $(SG_SCRIPT_PATH)/run_lint$(SG_SCRIPT_SUF).tcl; \
	rc=$$?; \
	if tail -n +$$((before+1)) sg_shell.log 2>/dev/null | grep -qE 'Syntax Errors detected|RULE CHECKING ABORTED'; then \
	  echo "[lint] ERROR: rule checking was ABORTED -- no rules ran. See $(SPYGLASS_WORK_DIR)/sg_shell.log"; \
	  exit 1; \
	fi; \
	exit $$rc
	@echo "[lint] done. hardware/generated/ now holds the $(config) mesh (shared by every build)."
	@ls -dt $(SPYGLASS_WORK_DIR)/sg_projects/*/consolidated_reports 2>/dev/null | head -1 \
	  | sed 's|^|[lint] reports: |'

# Build the Spyglass source list. subst removes the "32'd" which spyglass cannot handle.
#
# This was a PATTERN rule -- $(SPYGLASS_WORK_DIR)/tmp/files%: -- whose % must match at least one
# character, so the plain target named in lint's prerequisites had NO recipe. make printed
# "Nothing to be done", the list was never written, and sg_shell then died with
#   `sourcelist' file `tmp/files' does not exist
# while make still exited 0: a lint that checked nothing and reported success. It is a plain
# target now, and .PHONY above keeps it regenerated on every run.
$(SPYGLASS_WORK_DIR)/tmp/files: $(bender)
	mkdir -p $(SPYGLASS_WORK_DIR)/tmp
	$(bender) script verilator $(subst 32\'d,,$(vlog_defs)) -t rtl -t mempool_verilator $(bender_defs) \
	  | grep -vE '$(SPYGLASS_EXCLUDE)' > $@
	@echo "[lint] source list: $$(wc -l < $@) files (testbench and sim-only helpers excluded)"

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
