# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# BACKEND CONFIG A -- 4x4 mesh (256 cores, 16 groups), tuned for a 512x512x512 matmul.
#
#   mesh          4x4, num_cores 256, num_groups 16, 1 core/tile
#   NoC channels  baseline: rd 0 + rdwr 2 request, 2 response
#   MSHR hold     511 (window_burst and serve_timeout)
#   router remap  0 (off)
#
# ONLY THE HOLD WINDOW DIFFERS FROM THE BASE FLAVOUR. terapool_spatz4_fpu.mk already ships every
# other value this config needs, and its own comments name them as the 512x512x512 presets:
#
#   group_mshr_merge_reqs       = 4   "512x512x512 (default): A 4-way, B 4-way -> max = 4"
#   group_mshr_hold_subs_single = 4   "512x512x512 (default): A 4-way, B 4-way"
#   group_mshr_hold_subs_burst  = 4
#   group_mshr_bank_shift_burst = 7   "512x512x512 (default): P/split_p_count = 512/4 = 128 -> 7"
#   noc_router_remapping        = 0
#   channel_config_mode         = baseline  (rd 0 + rdwr 2, resp 2)
#
# So this file sets two knobs and inherits the rest. Do NOT copy the base's values in here: a
# fork would silently drift the moment the base is retuned, which is exactly how a shape-matched
# config stops matching its shape.
#
# DERIVED, not a fork: assigned before the include, and every definition in the base is `?=`,
# so these win. (`channel_config_mode` is also `?=` in the base and already defaults to
# baseline, so it needs no override here -- but if you ever need a non-default channel split,
# pass it as a MAKE ARGUMENT, e.g. `channel_config_mode=enhanced`, not as a pre-assignment.)
#
# hold=2047, per the standing decision of 2026-08-14 (see terapool_spatz4_fpu.mk). This file
# previously pinned 511 with a note arguing that shorter windows complete faster -- that note is
# superseded: the value is now uniform across 4x4 and 8x8 so that configs differ in the thing under
# test and not in the hold window as well.
group_mshr_hold_window_burst := 2047
group_mshr_serve_timeout     := 2047

include $(MEMPOOL_DIR)/config/terapool_spatz4_fpu.mk
