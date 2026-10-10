// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer: one phase's L2 weight bytes (all its projections, all K tiles) -- for the shared
// weight region of a perf build (ql_wshare=1, see app.mk). Compiled with that phase's data/.
#include <stdio.h>

#include "qwen_layout.h"

int main(void) {
  printf("%llu\n", (unsigned long long)QWEN_STAGES_N * (unsigned long long)QWEN_WTILES *
                       (unsigned long long)QWEN_WSLOT * 2ull);
  return 0;
}
