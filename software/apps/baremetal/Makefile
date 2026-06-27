# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Matheus Cavalcante, ETH Zurich
#         Samuel Riedel, ETH Zurich

SHELL = /usr/bin/env bash
ROOT_DIR := $(patsubst %/,%, $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
MEMPOOL_DIR := $(shell git rev-parse --show-toplevel 2>/dev/null || echo $$MEMPOOL_DIR)
SOFTWARE_DIR := $(abspath $(ROOT_DIR)/../..)
APPS_DIR := $(ROOT_DIR)
BIN_DIR := $(abspath $(SOFTWARE_DIR)/bin/$(subst $(SOFTWARE_DIR),,$(APPS_DIR)))
DATA_DIR := $(abspath $(SOFTWARE_DIR)/data)
RUNTIME_DIR := $(abspath $(SOFTWARE_DIR)/runtime)

# Discover the apps and classify them by the numeric type in their name suffix.
APPS := $(patsubst $(APPS_DIR)/%/main.c,%,$(shell find $(APPS_DIR) -name "main.c"))
ALL := $(APPS)

FP_SUFFIXES := f16 f32 f8
I_SUFFIXES := q16 q32 i16 i32 i8
I_APPS := $(foreach suf, $(I_SUFFIXES), $(filter %_$(suf), $(ALL)))
FP_APPS := $(foreach suf, $(FP_SUFFIXES), $(filter %_$(suf), $(ALL)))
# Spatz/RVV vector apps are screened by the `sp_` prefix. They need a Spatz
# config and the LLVM toolchain (RVV codegen); the config is selected by the
# user (no automatic override).
SPATZ_APPS := $(filter sp_%, $(ALL))

# Default compiler per app type: gcc for integer apps, llvm for floating-point
# and vector apps. Still overridable on the command line.
ifneq ($(filter $(FP_APPS) $(SPATZ_APPS) all_llvm all_spatz,$(MAKECMDGOALS)),)
  COMPILER ?= llvm
endif

# This will overwrite the ROOT_DIR variable from the included makefile
include $(RUNTIME_DIR)/runtime.mk

BINARIES := $(addprefix $(BIN_DIR)/,$(APPS))

# gcc builds the integer apps (`all`), llvm the floating-point apps
# (`all_llvm`); the vector apps go through `all_spatz`.
ALL_GCC := $(filter-out $(FP_APPS) $(SPATZ_APPS), $(ALL))
ALL_LLVM := $(filter-out $(I_APPS) $(SPATZ_APPS), $(ALL))

# Make all applications
all: $(ALL_GCC)

# Make only applications with full llvm support
all_llvm: $(ALL_LLVM)

# Make all Spatz vector apps (uses LLVM by default; pass a Spatz config)
all_spatz: $(SPATZ_APPS)

$(APPS): % : $(BIN_DIR)/% $(APPS_DIR)/Makefile $(shell find $(RUNTIME_DIR)/**.{S,c,h,ld} -type f)

.PHONY: $(BINARIES)
$(BINARIES): $(BIN_DIR)/%: %/main.c.o $(RUNTIME) $(LINKER_SCRIPT) data_%.h update_opcodes
	mkdir -p $(dir $@)
	$(RISCV_CC) -Iinclude -o $@ $< $(RUNTIME) $(RISCV_LDFLAGS) -T$(RUNTIME_DIR)/link.ld
	$(RISCV_OBJDUMP) $(RISCV_OBJDUMP_FLAGS) -D $@ > $@.dump

# Helper targets: regenerate the opcode tables for the active config (forwarded
# so Spatz app builds get the RVV table, scalar builds the XpulpIMG table).
update_opcodes:
	make -C $(MEMPOOL_DIR) update_opcodes config=$(config)

.PHONY: clean
clean:
	rm -vf $(BINARIES)
	rm -vf $(addsuffix .dump,$(BINARIES))
	rm -vf $(addsuffix /main.c.o,$(APPS))
	rm -vf $(RUNTIME)
	rm -vf $(LINKER_SCRIPT)
	rm -vf $(wildcard $(DATA_DIR)/data_*.h)

.INTERMEDIATE: $(addsuffix /main.c.o,$(APPS))
