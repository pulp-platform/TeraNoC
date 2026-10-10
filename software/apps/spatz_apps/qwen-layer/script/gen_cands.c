// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer (from qwen-ffn/script/gen_cands.c): every legal (K tile, strip width) of ONE phase, with what it costs in L1, for the
// joint chooser (gen_joint.c). Compiled once per phase with that phase's data/qwen_shape.h on the
// include path. Legality is the phase's own (qwen_layout.h QWEN_PT_LEGAL_K, plus the same K-tile
// rules as gen_tiles.c); the L1 fit is decided jointly, because both phases share one W area.
//
// Output: a first line "L1 <l1_bytes> <stack_bytes>", then one candidate per line:
//   kt pt wslot_bytes own_bytes ldp
#include <stdint.h>
#include <stdio.h>

#define QWEN_TILE_PROBE 1
#include "qwen_layout.h"

#ifndef QWEN_KT_MAX
#define QWEN_KT_MAX 640
#endif

int main(void) {
  unsigned n = 0;
  printf("L1 %llu %llu\n", (unsigned long long)QWEN_L1_BYTES,
         (unsigned long long)(NUM_CORES) * (unsigned long long)(STACK_SIZE));
  // Any EVEN tile count (qwen-ffn: powers of two only): 6144 / 12 = 512 gives the o-projection a
  // 4 MiB slot at 4x4, which lets the attention mixer's two KV tiles share the W area.
  for (uint32_t s = 2; s <= 256; s += 2) {
    const uint32_t kt = (uint32_t)QWEN_K / s;
    if (((uint32_t)QWEN_K % s) || kt == 0u || (kt % (2u * (uint32_t)QWEN_KSPLIT)) ||
        kt > (uint32_t)QWEN_KT_MAX)
      continue;
    for (uint32_t d = 1; d <= 64; d *= 2) {
      const uint32_t pt = (uint32_t)QWEN_LDP / d;
      if (((uint32_t)QWEN_LDP % d) || !QWEN_PT_LEGAL_K(kt, pt)) continue;
      printf("%u %u %llu %llu %u\n", (unsigned)kt, (unsigned)pt,
             (unsigned long long)QWEN_WSLOT_BYTES_K(kt, pt),
             (unsigned long long)QWEN_OWN_BYTES_K(kt, pt), (unsigned)QWEN_LDP);
      ++n;
    }
  }
  if (!n) {
    fprintf(stderr, "gen_cands: no legal K tile / strip for B=%u K=%u P=%u\n", (unsigned)QWEN_B,
            (unsigned)QWEN_K, (unsigned)QWEN_P);
    return 1;
  }
  return 0;
}
