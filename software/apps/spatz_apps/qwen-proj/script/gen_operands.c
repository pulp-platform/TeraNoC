// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-proj check 1 operands (host): X (multi-hot, qwen_pattern.h qwen_x_bits) and every W[s]
// (the exact grid, qwen_w_bits) in the phase's L2 layouts. Compiled with the app's generated
// headers, so the layout is the target's.
//
//   gen_operands <out-dir>   writes pj_w_l2.bin, pj_x_l2.bin, align.txt
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "qwen_layout.h"
#include "qwen_pattern.h"

static FILE *open_out(const char *dir, const char *name) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/%s", dir, name);
  FILE *f = fopen(path, "wb");
  if (!f) { perror(path); exit(1); }
  return f;
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: %s <out-dir>\n", argv[0]); return 2; }
  // pj_w_l2[stage][strip][step] = one K tile, KT rows of LDW (PT columns + pad), then the slot fill.
  FILE *f = open_out(argv[1], "pj_w_l2.bin");
  const uint32_t fill = (uint32_t)QWEN_WSLOT - (uint32_t)(QWEN_KT * QWEN_LDW);
  uint16_t *row = calloc((size_t)QWEN_LDW + fill, 2);
  for (uint32_t s = 0; s < (uint32_t)QWEN_STAGES_N; ++s)
    for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip)
      for (uint32_t step = 0; step < (uint32_t)(QWEN_K / QWEN_KT); ++step) {
        for (uint32_t kk = 0; kk < (uint32_t)QWEN_KT; ++kk) {
          const uint32_t k = step * (uint32_t)QWEN_KT + kk;
          for (uint32_t c = 0; c < (uint32_t)QWEN_LDW; ++c) {
            const uint32_t col = strip * (uint32_t)QWEN_PT + c;
            row[c] = (c < (uint32_t)QWEN_PT && col < (uint32_t)QWEN_P) ? qwen_w_bits(s, k, col) : 0u;
          }
          fwrite(row, 2, QWEN_LDW, f);
        }
        for (uint32_t c = 0; c < fill; ++c) row[c] = 0;
        if (fill) fwrite(row, 2, fill, f);
      }
  free(row);
  fclose(f);
  // pj_x_l2 = X [B][LDX], the row pad zero.
  f = open_out(argv[1], "pj_x_l2.bin");
  uint16_t *x = calloc((size_t)QWEN_LDX, 2);
  for (uint32_t b = 0; b < (uint32_t)QWEN_B; ++b) {
    for (uint32_t k = 0; k < (uint32_t)QWEN_LDX; ++k) x[k] = k < (uint32_t)QWEN_K ? qwen_x_bits(b, k) : 0u;
    fwrite(x, 2, QWEN_LDX, f);
  }
  free(x);
  fclose(f);
  f = open_out(argv[1], "align.txt");
  fprintf(f, "%u\n", (unsigned)QWEN_MESH_SWEEP);
  fclose(f);
  return 0;
}
