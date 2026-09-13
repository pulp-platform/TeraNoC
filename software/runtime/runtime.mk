# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Samuel Riedel, ETH Zurich
#         Matheus Cavalcante, ETH Zurich
SHELL = /usr/bin/env bash

ROOT_DIR := $(patsubst %/,%, $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
MEMPOOL_DIR := $(shell git rev-parse --show-toplevel 2>/dev/null || echo $$MEMPOOL_DIR)
# Include configuration
include $(MEMPOOL_DIR)/config/config.mk

# Python version
python             ?= python3

INSTALL_DIR        ?= $(MEMPOOL_DIR)/install
GCC_INSTALL_DIR    ?= $(INSTALL_DIR)/riscv-gcc
LLVM_INSTALL_DIR   ?= $(INSTALL_DIR)/llvm
# HALIDE_INSTALL_DIR ?= $(INSTALL_DIR)/halide
# HALIDE_INCLUDE     ?= $(HALIDE_INSTALL_DIR)/include
# HALIDE_LIB         ?= $(HALIDE_INSTALL_DIR)/lib
OMP_DIR            ?= $(ROOT_DIR)/omp
KERNELS_DIR        ?= $(abspath $(ROOT_DIR)/../kernels)
DATA_DIR           ?= $(abspath $(ROOT_DIR)/../data)

COMPILER      ?= llvm
XPULPIMG      ?= $(xpulpimg)
ZFINX         ?= $(zfinx)
XDIVSQRT	  ?= $(xDivSqrt)

RISCV_XLEN    ?= 32

RISCV_ABI     ?= ilp32
RISCV_TARGET  ?= riscv$(RISCV_XLEN)-unknown-elf
ifeq ($(COMPILER),gcc)
	# Use GCC
	# GCC compiler -march
	ifeq ($(XPULPIMG),1)
		RISCV_ARCH    ?= rv$(RISCV_XLEN)imaXpulpimg
		RISCV_ARCH_AS ?= $(RISCV_ARCH)
		# Define __XPULPIMG if the extension is active
		DEFINES       += -D__XPULPIMG
	else
		ifneq ($(n_fpu), 0)
			RISCV_ARCH    ?= rv$(RISCV_XLEN)imaf
			RISCV_ARCH_AS ?= $(RISCV_ARCH)
			RISCV_ABI     := ilp32
		else
			RISCV_ARCH_AS ?= rv$(RISCV_ARCH)ima
			RISCV_ARCH_AS ?= $(RISCV_ARCH)Xpulpv2
		endif
	endif

	# GCC Toolchain
	RISCV_PREFIX  ?= $(GCC_INSTALL_DIR)/bin/$(RISCV_TARGET)-
	RISCV_CC      ?= $(RISCV_PREFIX)gcc
	RISCV_CXX     ?= $(RISCV_PREFIX)g++
	RISCV_OBJDUMP ?= $(RISCV_PREFIX)objdump
else
	# Use LLVM by default
	# LLVM compiler -march
	ifeq ($(spatz), 1)
		RISCV_ARCH ?= rv$(RISCV_XLEN)ima
		ifneq ($(n_fpu), 0)
			RISCV_ARCH := $(addsuffix f, $(RISCV_ARCH))
			RISCV_ABI  := ilp32
		endif
		RISCV_ARCH := $(addsuffix vzfh, $(RISCV_ARCH))
	else
		RISCV_ARCH ?= rv$(RISCV_XLEN)ima
	endif
	ifeq ($(ZFINX), 1)
		RISCV_ARCH := $(RISCV_ARCH)_zfinx
		RISCV_ARCH := $(RISCV_ARCH)_zhinx
		RISCV_ARCH := $(RISCV_ARCH)_zquarterinx
		RISCV_ARCH := $(RISCV_ARCH)_zvechalfinx
		RISCV_ARCH := $(RISCV_ARCH)_zvecquarterinx
		RISCV_ARCH := $(RISCV_ARCH)_zexpauxvechalfinx
		RISCV_ARCH := $(RISCV_ARCH)_zexpauxvecquarterinx
	endif
	ifeq ($(XPULPIMG), 1)
		RISCV_ARCH := $(RISCV_ARCH)_xpulppostmod
		RISCV_ARCH := $(RISCV_ARCH)_xpulpmacsi
		RISCV_ARCH := $(RISCV_ARCH)_xpulpvect
		RISCV_ARCH := $(RISCV_ARCH)_xpulpvectshufflepack
	endif
	RISCV_ARCH := $(RISCV_ARCH)_xmempool
	# LLVM Toolchain
	RISCV_PREFIX  ?= $(LLVM_INSTALL_DIR)/bin/llvm-
	RISCV_CC      ?= $(LLVM_INSTALL_DIR)/bin/clang
	RISCV_CXX     ?= $(LLVM_INSTALL_DIR)/bin/clang++
	RISCV_OBJDUMP ?= $(RISCV_PREFIX)objdump
endif
RISCV_OBJCOPY ?= $(RISCV_PREFIX)objcopy
RISCV_AS      ?= $(RISCV_PREFIX)as
RISCV_AR      ?= $(RISCV_PREFIX)ar
RISCV_LD      ?= $(RISCV_PREFIX)ld
RISCV_STRIP   ?= $(RISCV_PREFIX)strip

# Defines
DEFINES += -DPRINTF_DISABLE_SUPPORT_FLOAT -DPRINTF_DISABLE_SUPPORT_LONG_LONG -DPRINTF_DISABLE_SUPPORT_PTRDIFF_T
DEFINES += -DNUM_CORES=$(num_cores)
DEFINES += -DNUM_GROUPS=$(num_groups)
DEFINES += -DNUM_CORES_PER_TILE=$(num_cores_per_tile)
DEFINES += -DBANKING_FACTOR=$(banking_factor)
DEFINES += -DNUM_BANKS=$(shell awk 'BEGIN{print $(banking_factor)*$(n_fpu)*$(num_cores)}')
DEFINES += -DNUM_CORES_PER_GROUP=$(shell awk 'BEGIN{print $(num_cores)/$(num_groups)}')
DEFINES += -DNUM_TILES_PER_GROUP=$(shell awk 'BEGIN{print ($(num_cores)/$(num_groups))/$(num_cores_per_tile)}')
DEFINES += -DLOG2_NUM_CORES_PER_TILE=$(shell awk 'BEGIN{print log($(num_cores_per_tile))/log(2)}')
DEFINES += -DBOOT_ADDR=$(boot_addr)
DEFINES += -DL1_BANK_SIZE=$(l1_bank_size)
DEFINES += -DL2_BASE=$(l2_base)
DEFINES += -DL2_SIZE=$(l2_size)
DEFINES += -DSEQ_MEM_SIZE=$(seq_mem_size)
DEFINES += -DLOG2_SEQ_MEM_SIZE=$(shell awk 'BEGIN{print log($(seq_mem_size))/log(2)}')
DEFINES += -DSTACK_SIZE=$(stack_size)
DEFINES += -DLOG2_STACK_SIZE=$(shell awk 'BEGIN{print log($(stack_size))/log(2)}')
DEFINES += -DXQUEUE_SIZE=$(xqueue_size)
# Group-barrier reserved word window. Consumed by arch.ld.c (to truncate L1 so no data can
# alias the window) and by barrier-using apps (GBAR_BASE_WORD). MUST match GroupBarrierWord
# in hardware/src/mempool_group.sv.
DEFINES += -DGROUP_BARRIER_WORD=$(group_barrier_word)

# --- Group MSHR runtime configuration -------------------------------------------------------
# The software values come from the SAME make variables the hardware elaborates from, so the CSR
# writes and the RTL defaults can never disagree. Enabled only when the hardware was built with
# group_mshr_cfg_runtime=1; otherwise the kernel's config block compiles out entirely and the
# behaviour is exactly the pre-CSR design.
DEFINES += -DMSHR_RUNTIME_CFG=$(if $(filter 1,$(group_mshr_cfg_runtime)),1,0)
# I$ warm-up. DEFAULT 1 -- do not change it for anything whose cycle count will be quoted.
# 0 skips the short reduced-N kernel pass before the timed region, which removes ~14k cycles of
# pre-phase. That is ~29% of a 256x512x256 run but ~79% of a 256x32x256 one, so it is a large
# debug-iteration win on small shapes and worthless on large ones.
#
# It is a make knob (not just a C #ifndef) SO THAT IT LANDS IN THE COMPILE LINE. Every sweep gate
# diffs the emitted define set, so an arm built with warm-up off can never be silently compared
# against one built with it on -- the same discipline that spill_req_in needed the hard way.
DEFINES += -DICACHE_WARMUP=$(if $(icache_warmup),$(icache_warmup),1)
# V5a negative test of the MSHR CSR reject path. DEBUG ONLY -- default 0, and it lands in the
# compile line so a sweep gate cannot confuse a negtest binary with a perf one.
DEFINES += -DMSHR_CFG_NEGTEST=$(if $(mshr_cfg_negtest),$(mshr_cfg_negtest),0)
DEFINES += -DMSHR_CFG_HOLD_SUBS_SINGLE=$(if $(group_mshr_hold_subs_single),$(group_mshr_hold_subs_single),2)
DEFINES += -DMSHR_CFG_HOLD_SUBS_BURST=$(if $(group_mshr_hold_subs_burst),$(group_mshr_hold_subs_burst),2)
DEFINES += -DMSHR_CFG_HOLD_WINDOW_SINGLE=$(if $(group_mshr_hold_window_single),$(group_mshr_hold_window_single),0)
DEFINES += -DMSHR_CFG_HOLD_WINDOW_BURST=$(if $(group_mshr_hold_window_burst),$(group_mshr_hold_window_burst),0)
DEFINES += -DMSHR_CFG_SERVE_TIMEOUT=$(if $(group_mshr_serve_timeout),$(group_mshr_serve_timeout),0)
DEFINES += -DMSHR_CFG_BANK_SHIFT_SINGLE=$(if $(group_mshr_bank_shift_single),$(group_mshr_bank_shift_single),5)
DEFINES += -DMSHR_CFG_BANK_SHIFT_BURST=$(if $(group_mshr_bank_shift_burst),$(group_mshr_bank_shift_burst),5)
DEFINES += -DMSHR_CFG_BANK_BURST_BITS=$(if $(group_mshr_bank_burst_bits),$(group_mshr_bank_burst_bits),1)
# 0 = legacy. fp16 kernels override cache_reuse_target locally; fp32 keeps the legacy path.
DEFINES += -DMSHR_CFG_CACHE_REUSE_TARGET=$(if $(group_mshr_cache_reuse_target),$(group_mshr_cache_reuse_target),0)
DEFINES += -DMSHR_CFG_CACHE_TIMEOUT=$(if $(group_mshr_cache_timeout),$(group_mshr_cache_timeout),0)
DEFINES += -DMSHR_CFG_BANKFULL_BP=$(if $(group_mshr_bankfull_backpressure),$(group_mshr_bankfull_backpressure),0)
# The HARDWARE merge capacity. Elaboration-only in RTL, but software needs it: the CSR range
# check refuses a cache_reuse_target above it, and served_cnt saturates at it.
# Geometry for the optional per-group software hash search.
DEFINES += -DMSHR_CFG_ENTRIES=$(if $(group_mshr_num),$(group_mshr_num),NUM_TILES_PER_GROUP)
DEFINES += -DMSHR_CFG_WAYS=$(if $(group_mshr_ways_per_bank),$(group_mshr_ways_per_bank),4)
# Mirror VLSU burst admission in the GEMM request model.
DEFINES += -DGEMM_BURST_ROB_DEPTH=$(if $(spatz_vlsu_rob_depth),$(spatz_vlsu_rob_depth),32)
DEFINES += -DGEMM_BURST_ENABLED=$(if $(spatz_vlsu_burst),$(spatz_vlsu_burst),1)
DEFINES += -DMSHR_CFG_HASH_MODE=$(if $(group_mshr_bank_hash),$(group_mshr_bank_hash),0)
DEFINES += -DMSHR_MERGE_REQS=$(if $(group_mshr_merge_reqs),$(group_mshr_merge_reqs),4)
DEFINES += -DNUM_GROUP_BARRIERS=$(shell awk 'BEGIN{print $(num_cores)/$(num_groups)}')
# Per-build extra defines (app/kernel A/B knobs), e.g.
#   make <app> config=<cfg> EXTRA_DEFINES="-DGBAR_PLOOP=1 -DKERNEL_SIZE=4"
# Use THIS, never `DEFINES=...` on the command line: a command-line assignment overrides
# every `DEFINES +=` above (make gives command-line variables top precedence), silently
# dropping NUM_CORES/NUM_GROUPS/VLEN/... and failing the build.
#
# AND FORCE THE REBUILD. The app target depends on main.c.o, not on the define set, so if the
# ELF is newer than the source `make <app> EXTRA_DEFINES=...` does NOTHING and reports success
# -- the same false-clean failure as `make compile` skipping vlog. Delete the binary first:
#   rm -f software/bin/apps/<cat>/<app> && make <app> config=<cfg> EXTRA_DEFINES="-DX=1"
# Verify with `strings <elf> | grep <a-string-only-the-define-adds>` before trusting the build.
DEFINES += $(EXTRA_DEFINES)
# Spatz related
DEFINES += -DRVF=$(rvf) -DRVD=$(rvd)
DEFINES += -DMEMPOOL
ifeq ($(spatz), 1)
	DEFINES += -DVLEN=$(vlen) -DN_IPU=$(n_ipu) -DN_FPU=$(n_fpu) -DN_FU=$(shell awk 'BEGIN{print ($(n_ipu) > $(n_fpu)) ? $(n_ipu) : $(n_fpu)}') -DRVV
	DEFINES += -DLOG2_N_FU=$(shell awk 'BEGIN{print ($(n_ipu) > $(n_fpu)) ? log($(n_ipu))/log(2) : log($(n_fpu))/log(2)}')
else
	DEFINES += -DN_FU=1
	DEFINES += -DLOG2_N_FU=0
endif
ifeq ($(rvd), 1)
	DEFINES += -DELEN=64
else
	DEFINES += -DELEN=32
endif

# Specify cross compilation target. This can be omitted if LLVM is built with riscv as default target
RISCV_LLVM_TARGET  ?= --target=$(RISCV_TARGET) --sysroot=$(GCC_INSTALL_DIR)/$(RISCV_TARGET) --gcc-toolchain=$(GCC_INSTALL_DIR)

RISCV_WARNINGS += -Wunused-variable -Wconversion -Wall -Wextra # -Werror
RISCV_FLAGS_COMMON_TESTS ?= -march=$(RISCV_ARCH) -mabi=$(RISCV_ABI) -I$(ROOT_DIR) -I$(KERNELS_DIR) -I$(DATA_DIR) -static
RISCV_FLAGS_COMMON ?= $(RISCV_FLAGS_COMMON_TESTS) -g -std=gnu99 -O3  -fno-builtin-memcpy -fno-builtin-memset -ffast-math -fno-common -fno-builtin-printf $(DEFINES) $(RISCV_WARNINGS)
RISCV_FLAGS_GCC    ?= -mcmodel=medany -Wa,-march=$(RISCV_ARCH_AS) -mtune=mempool -fno-tree-loop-distribute-patterns # -falign-loops=32 -falign-jumps=32
RISCV_FLAGS_LLVM   ?= -mcmodel=small -mcpu=mempool-rv32 -mllvm -misched-topdown -menable-experimental-extensions
# # Enable soft-divsqrt when the hardware is not supported.
# ifeq ($(xDivSqrt), 0)
# 	RISCV_FLAGS_LLVM_TESTS := $(RISCV_FLAGS_LLVM)
# 	RISCV_FLAGS_LLVM += -mno-fdiv
# endif

# # Disable division and square root
# ifeq ($(XDIVSQRT), 0)
# 	RISCV_FLAGS_LLVM += -mno-fdiv
# else
# 	# Define if the extension is active
# 	DEFINES       += -D__XDIVSQRT
# endif

ifeq ($(COMPILER),gcc)
	RISCV_CCFLAGS       += $(RISCV_FLAGS_GCC) $(RISCV_FLAGS_COMMON)
	RISCV_CXXFLAGS      += $(RISCV_CCFLAGS)
	RISCV_LDFLAGS       += -static -nostartfiles -lm -lgcc $(RISCV_FLAGS_GCC) $(RISCV_FLAGS_COMMON) -L$(ROOT_DIR)
	RISCV_OBJDUMP_FLAGS += --disassembler-option="march=$(RISCV_ARCH_AS)"
	# For unit tests
	RISCV_CCFLAGS_TESTS ?= $(RISCV_FLAGS_GCC) $(RISCV_FLAGS_COMMON_TESTS) -fvisibility=hidden -nostdlib $(RISCV_LDFLAGS)
else
	RISCV_CCFLAGS       += $(RISCV_LLVM_TARGET) $(RISCV_FLAGS_LLVM) $(RISCV_FLAGS_COMMON)
	RISCV_CXXFLAGS      += $(RISCV_CCFLAGS)
	RISCV_LDFLAGS       += -static -nostartfiles -lm -lgcc -mcmodel=small $(RISCV_LLVM_TARGET) $(RISCV_FLAGS_COMMON) -L$(ROOT_DIR)
	ifeq ($(XDIVSQRT), 0)
		RISCV_OBJDUMP_FLAGS += --mcpu=mempool-rv32 --mattr=+m,+a,+v,+zfh,+zfinx,+nofdiv
	else
		RISCV_OBJDUMP_FLAGS += --mcpu=mempool-rv32 --mattr=+m,+a,+v,+zfh
	endif
	RISCV_STRIP_FLAGS   ?= -ffunction-sections -Wl,--gc-sections
	RISCV_LDFLAGS_TESTS ?= -static -nostartfiles -lm -lgcc -mcmodel=small $(RISCV_LLVM_TARGET) $(RISCV_FLAGS_LLVM) $(RISCV_FLAGS_COMMON_RV) -L$(ROOT_DIR)
	# For unit tests
	RISCV_CCFLAGS_TESTS ?= $(RISCV_FLAGS_LLVM_TESTS) $(RISCV_FLAGS_COMMON_TESTS) -fvisibility=hidden -nostdlib $(RISCV_LDFLAGS)
endif

LINKER_SCRIPT ?= $(ROOT_DIR)/arch.ld

RUNTIME += $(ROOT_DIR)/alloc.c.o
RUNTIME += $(ROOT_DIR)/crt0.S.o
RUNTIME += $(ROOT_DIR)/printf.c.o
RUNTIME += $(ROOT_DIR)/serial.c.o
RUNTIME += $(ROOT_DIR)/string.c.o
RUNTIME += $(ROOT_DIR)/synchronization.c.o

OMP_RUNTIME := $(addsuffix .o,$(shell find $(OMP_DIR) -name "*.c"))

.INTERMEDIATE: $(RUNTIME) $(OMP_RUNTIME) $(LINKER_SCRIPT)
# Disable builtin rules
.SUFFIXES:

%.S.o: %.S
	$(RISCV_CC) $(RISCV_CCFLAGS) -c $< -o $@

%.c.o: %.c
	$(RISCV_CC) $(RISCV_CCFLAGS) -c $< -o $@

%.cpp.o: %.cpp
	$(RISCV_CXX) $(RISCV_CXXFLAGS) -c $< -o $@

%.ld: %.ld.c
	$(RISCV_CC) -P -E $(DEFINES) $< -o $@

data_%.h: $(DATA_DIR)/gendata_params.hjson
	$(python) $(DATA_DIR)/gendata_header.py --app_name $* --params $(DATA_DIR)/gendata_params.hjson

# Bootrom
%.elf: %.S $(ROOT_DIR)/bootrom.ld $(LINKER_SCRIPT)
	$(RISCV_CC) $(RISCV_CCFLAGS) -L$(ROOT_DIR) -T$(ROOT_DIR)/bootrom.ld $< -nostdlib -static -Wl,--no-gc-sections -o $@

%.bin: %.elf
	$(RISCV_OBJCOPY) -O binary $< $@

%.img: %.bin
	dd if=$< of=$@ bs=128

# Convenience formatting
format:
	make -C $(MEMPOOL_DIR) format
