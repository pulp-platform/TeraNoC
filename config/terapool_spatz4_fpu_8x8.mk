# terapool_spatz4_fpu_8x8 -- the 8x8 / 64-group / 1024-core mesh.
#
# This file is now a THIN OVERLAY on config/terapool_spatz4_fpu.mk. It used to be a 559-line copy
# of it, and the two had drifted to differ in exactly SIX settings while duplicating the other 76 --
# so every knob change had to be made twice, and a change made once silently produced two different
# designs. (That is the same class of failure as the pinned-knob problem in the sweep: a comparison
# is only valid if the two sides differ in what you think they differ in.)
#
# ORDER MATTERS. The overrides come BEFORE the include: every setting in the base file uses `?=`
# (conditional assignment), so a value already set here wins and the base's default is skipped.
# Putting the include first would silently give you the 4x4 values.
#
# To change a knob for BOTH meshes, edit terapool_spatz4_fpu.mk. Only mesh geometry belongs here.

# ---- mesh geometry: the only things that make this 8x8 -------------------------------------
num_cores      ?= 1024        # 4x4: 256
num_groups     ?= 64          # 4x4: 16
num_x          ?= 8           # 4x4: 4

# ---- L2 scaled with the mesh ----------------------------------------------------------------
# 32 banks of 1 MiB. l2_size MUST be set here too: the base assigns it with `?=` to a literal, so
# leaving it unset would take the 4x4's 16 MiB against this file's 32 banks.
l2_banks       ?= 32          # 4x4: 16
l2_size        ?= $(shell echo $$((1048576 * $(l2_banks))))

# ---- build directory -------------------------------------------------------------------------
config_build_path ?= terapool8x8

include $(dir $(lastword $(MAKEFILE_LIST)))terapool_spatz4_fpu.mk
