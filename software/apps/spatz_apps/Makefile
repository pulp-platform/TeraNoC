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
# This will overwrite the ROOT_DIR variable from the included makefile
include $(RUNTIME_DIR)/runtime.mk

APPS := $(patsubst $(APPS_DIR)/%/main.c,%,$(shell find $(APPS_DIR) -name "main.c"))
BINARIES := $(addprefix $(BIN_DIR)/,$(APPS))
ALL := $(APPS)

FP_SUFFIXES := f16 f32 f8
I_SUFFIXES := q16 q32 i16 i32 i8
I_APPS := $(foreach suf, $(FP_SUFFIXES), $(filter %_$(suf), $(ALL)))
FP_APPS := $(foreach suf, $(I_SUFFIXES), $(filter %_$(suf), $(ALL)))
# Filter out applications
ALL_GCC := $(filter-out $(I_APPS), $(ALL))
ALL_LLVM := $(filter-out $(FP_APPS), $(ALL))

# Make all applications
all: $(ALL_GCC)

# Make only applications with full llvm support
all_llvm: $(ALL_LLVM)

$(APPS): % : $(BIN_DIR)/% $(APPS_DIR)/Makefile $(shell find $(RUNTIME_DIR)/**.{S,c,h,ld} -type f)

.PHONY: $(BINARIES)
$(BINARIES): $(BIN_DIR)/%: %/main.c.o $(RUNTIME) $(LINKER_SCRIPT) data_%.h update_opcodes
	mkdir -p $(dir $@)
	$(RISCV_CC) -Iinclude -o $@ $< $(RUNTIME) $(RISCV_LDFLAGS) -T$(RUNTIME_DIR)/link.ld
	$(RISCV_OBJDUMP) $(RISCV_OBJDUMP_FLAGS) -D $@ > $@.dump

# Regenerate a per-shape GEMM data header from its shape spec. data_gemm.h carries the
# GEMM_M/N/P/ELEM_BYTES macros that runtime/mshr_cfg.h derives the MSHR tuning from at compile
# time, so a stale header would silently mistune the run. Making it a real prerequisite means
# editing script/matmul.json is enough -- no manual gen_data.py step, no per-shape config/*.mk.
%/data/data_gemm.h: %/script/matmul.json %/script/gen_data.py
	cd $(APPS_DIR)/$* && $(python) script/gen_data.py -c script/matmul.json

# ---- shape-parameterised decode apps -------------------------------------------------
# ONE app per PRECISION (sp-decode-fp16 / sp-decode-fp32) instead of one directory per shape.
# The 43 per-shape copies this replaces had drifted into 5 distinct main.c versions and 6
# distinct kernels; three of those groups were stale (one missing MATMUL_REPEAT entirely, so
# its cycles were not comparable to any other arm). Only the fp16/fp32 split is principled --
# elem_t vs float, and a genuinely different verify tolerance -- so precision stays a
# directory and shape becomes a parameter.
#
# The shape arrives as make variables and is WRITTEN INTO script/matmul.json, which is already
# the prerequisite of data/data_gemm.h. That matters: data_gemm.h carries the GEMM_M/N/P and
# ELEM_BYTES macros that runtime/mshr_cfg.h derives the MSHR tuning from AT COMPILE TIME, so a
# shape that changed without regenerating the header would silently mistune the run. Writing
# the json through a cmp guard means its mtime moves exactly when the shape really changes.
#
#   make sp-decode-fp16 config=terapool_spatz4_fpu gemm_m=16 gemm_n=128 gemm_p=16384
#
# ONE APP PER PRECISION, for BOTH prefill and decode. main.c:295 auto-derives
# MATMUL_DECODE_SPLIT from GEMM_M / active groups / KERNEL_SIZE, so the two regimes need no
# separate program -- only a different shape. This replaces 317 generated per-shape dirs
# (43 decode + 274 prefill) that had drifted into 9 distinct main.c versions between them.
SHAPED_APPS := sp-fmatmul-opt-burst-merge-fp16 sp-fmatmul-opt-burst-merge
gemm_m ?= 16
gemm_n ?= 128
gemm_p ?= 16384

define SHAPE_rule
$(1)/script/matmul.json: FORCE
	@mkdir -p $$(@D)
	@{ \
	  echo '// GENERATED from make vars gemm_m/gemm_n/gemm_p -- do not hand-edit.'; \
	  echo '// DECODE-shape GEMM: C[B][I] = A[B][D] x W[D][I], mapped as M=B, N=D, P=I.'; \
	  echo '{'; \
	  echo '    kernel: "GEMM"'; \
	  echo '    M: $$(gemm_m),'; \
	  echo '    N: $$(gemm_n),'; \
	  echo '    P: $$(gemm_p),'; \
	  echo '    alpha: 0,'; \
	  echo '    transpose_A: false,'; \
	  echo '    transpose_B: false,'; \
	  echo '    prec: $(2),'; \
	  echo '    expand: 0'; \
	  echo '}'; \
	} > $$@.tmp
	@if cmp -s $$@.tmp $$@; then rm -f $$@.tmp; else mv $$@.tmp $$@; fi
endef
$(eval $(call SHAPE_rule,sp-fmatmul-opt-burst-merge-fp16,16))
$(eval $(call SHAPE_rule,sp-fmatmul-opt-burst-merge,32))
.PHONY: FORCE
FORCE:

# ---- Qwen gate/up streaming projection ------------------------------------------------
# Same idea as SHAPE_rule above: the shape is a make variable, written into a generated
# header, so there is one source for every batch and both meshes. GEMM_M/N/P must be in
# that header because gemm_config.h picks KERNEL_SIZE from them and mshr_cfg.h derives the
# MSHR tuning from them, both at COMPILE TIME -- a shape that changed without regenerating
# the header would silently mistune the run.
#
#   make qwen-gate-up config=terapool_spatz4_fpu qwen_b=1 l2_size=536870912
#   make qwen-gate-up config=terapool_spatz4_fpu qwen_b=1 qwen_k=256 qwen_p=512 \
#        qwen_kt=32 qwen_check=1              # small self-checking correctness build
qwen_b     ?= 1
qwen_k     ?= 5120
qwen_p     ?= 17408
qwen_kt    ?= 40
qwen_check ?= 0
qwen_repeats ?= 1
qwen-gate-up/data/qwen_shape.h: FORCE
	@mkdir -p $(@D)
	@{ \
	  echo '// GENERATED from make vars qwen_b/qwen_k/qwen_p/qwen_kt/qwen_check -- do not hand-edit.'; \
	  echo '#ifndef QWEN_SHAPE_H'; \
	  echo '#define QWEN_SHAPE_H'; \
	  echo '#define GEMM_M $(qwen_b)          // batch: independent decode sequences'; \
	  echo '#define GEMM_N $(qwen_k)          // hidden'; \
	  echo '#define GEMM_P $(qwen_p)          // FFN intermediate'; \
	  echo '#define GEMM_ELEM_BYTES 2'; \
	  echo '#define QWEN_KT $(qwen_kt)        // reduction rows of W per streamed tile'; \
	  echo '#define QWEN_CHECK $(qwen_check)'; \
	  echo '#define QWEN_REPEATS $(qwen_repeats)'; \
	  echo '#endif'; \
	} > $@.tmp
	@if cmp -s $@.tmp $@; then rm -f $@.tmp; else mv $@.tmp $@; fi
# The bank hash depends only on the shape and on where X's replicas sit, both of
# which are known here. Selecting it on the host keeps it out of the target's boot
# path entirely -- the app just writes the constants to its CSRs.
HOST_CC ?= cc
qwen-gate-up/data/qwen_hash.h: qwen-gate-up/data/qwen_shape.h \
	qwen-gate-up/qwen_layout.h qwen-gate-up/script/gen_hash.c \
	$(RUNTIME_DIR)/gemm_hash.h $(RUNTIME_DIR)/gemm_config.h $(RUNTIME_DIR)/gemm_burst.h
	@mkdir -p $(@D)
	$(HOST_CC) -O1 -I$(RUNTIME_DIR) -Iqwen-gate-up $(DEFINES) \
		qwen-gate-up/script/gen_hash.c -o $(@D)/gen_hash
	$(@D)/gen_hash > $@

qwen-gate-up/main.c.o: qwen-gate-up/data/qwen_shape.h qwen-gate-up/data/qwen_hash.h \
	qwen-gate-up/qwen_layout.h \
	qwen-gate-up/kernel/qwen-fmatmul.c qwen-gate-up/kernel/qwen-fmatmul.h

GEMM_APPS := $(patsubst $(APPS_DIR)/%/script/matmul.json,%,$(wildcard $(APPS_DIR)/*/script/matmul.json))
# the merged apps have no checked-in matmul.json, so the wildcard above cannot see them
GEMM_APPS += $(SHAPED_APPS)
GEMM_APPS := $(sort $(GEMM_APPS))
$(foreach a,$(GEMM_APPS),$(eval $(a)/main.c.o: $(a)/data/data_gemm.h))

# Helper targets, here force a spatz configuration
update_opcodes:
	make -C $(MEMPOOL_DIR) update_opcodes config=minpool_spatz4_fpu

.PHONY: clean
clean:
	rm -vf $(BINARIES)
	rm -vf $(addsuffix .dump,$(BINARIES))
	rm -vf $(addsuffix /main.c.o,$(APPS))
	rm -vf $(RUNTIME)
	rm -vf $(LINKER_SCRIPT)
	rm -vf $(wildcard $(DATA_DIR)/data_*.h)

.INTERMEDIATE: $(addsuffix /main.c.o,$(APPS))
