// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-ffn check 1, down operand (host): Wd, down's exact grid (qwen_pattern.h qwen_w_bits), in
// down's L2 layout. Compiled with the down phase's headers.
//
//   gen_operands_dn <out-dir>   writes dn_w_l2.bin, align.txt
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
  _Static_assert(QWEN_STAGES_N == 1, "down phase headers expected");
  FILE *f = open_out(argv[1], "dn_w_l2.bin");
  const uint32_t fill = (uint32_t)QWEN_WSLOT - (uint32_t)(QWEN_KT * QWEN_LDW);
  uint16_t *row = calloc((size_t)QWEN_LDW + fill, 2);
  for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip)
    for (uint32_t step = 0; step < (uint32_t)(QWEN_K / QWEN_KT); ++step) {
      for (uint32_t kk = 0; kk < (uint32_t)QWEN_KT; ++kk) {
        const uint32_t k = step * (uint32_t)QWEN_KT + kk;
        for (uint32_t c = 0; c < (uint32_t)QWEN_LDW; ++c) {
          const uint32_t col = strip * (uint32_t)QWEN_PT + c;
          row[c] = (c < (uint32_t)QWEN_PT && col < (uint32_t)QWEN_P) ? qwen_w_bits(0, k, col) : 0u;
        }
        fwrite(row, 2, QWEN_LDW, f);
      }
      for (uint32_t c = 0; c < fill; ++c) row[c] = 0;
      if (fill) fwrite(row, 2, fill, f);
    }
  free(row);
  fclose(f);
  f = open_out(argv[1], "align.txt");
  fprintf(f, "%u\n", (unsigned)QWEN_MESH_SWEEP);
  fclose(f);
  return 0;
}
