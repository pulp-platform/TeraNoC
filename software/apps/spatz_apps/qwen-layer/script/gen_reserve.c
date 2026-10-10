// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer: the mixer's L1 bytes (layer.h QL_L1_MIXER) and the two A operands' bytes, which
// the joint tiling chooser must leave free. Compiled with the app's data/ql_knobs.h and one
// phase's layout (for the A operand sizes) on the path.
#include <stdio.h>

#define QL_RESERVE_ONLY 1
#include "layer.h"

int main(void) {
  printf("%llu %llu\n", (unsigned long long)QL_L1_MIXER, (unsigned long long)QL_L1_STATE_W);
  return 0;
}
