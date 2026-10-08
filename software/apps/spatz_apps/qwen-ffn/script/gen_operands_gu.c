// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-ffn check 1, gate+up operands (host). Compiled with the gate+up phase's headers.
//
//   X[b][j]  = 1 if j == b, else 0                   (one-hot: G = Wg[b][.], U = Wu[b][.])
//   Wg[j][k] = 16, Wu[j][k] = 1/16 where H[j][k] must be 1 (down's multi-hot positions), else 0
//
// so G and U are single exact terms, H = fp16(SiLU(16) / 16) = 1.0 exactly where lit and
// SiLU(0) * 0 = 0 elsewhere: H is down's multi-hot check pattern, and Y has its known value.
//
//   gen_operands_gu <out-dir>   writes gu_x_l2.bin, gu_w_l2.bin, align.txt
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "qwen_layout.h"
#include "data/ffn_shared.h"

// Down's multi-hot position (qwen_pattern.h qwen_hot_pos / qwen_x_bits, with down's tiling).
#define FFN_UNIT_K0 3u
static int h_hot(uint32_t b, uint32_t k) {
  const uint32_t t = k / FFN_DN_KT, r = k % FFN_DN_KT;
  const uint32_t j = r / FFN_DN_KT_CORE, pos = r % FFN_DN_KT_CORE;
  return pos == (FFN_UNIT_K0 + b + t + j) % FFN_DN_KT_CORE;
}
#define FP16_ONE 0x3c00u
#define FP16_16 0x4c00u
#define FP16_1_16 0x2c00u

static FILE *open_out(const char *dir, const char *name) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/%s", dir, name);
  FILE *f = fopen(path, "wb");
  if (!f) { perror(path); exit(1); }
  return f;
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: %s <out-dir>\n", argv[0]); return 2; }
  _Static_assert(QWEN_STAGES_N == 2, "gate+up phase headers expected");
  if ((uint32_t)QWEN_B > (uint32_t)QWEN_K) { fprintf(stderr, "one-hot X needs B <= K\n"); return 1; }

  FILE *f = open_out(argv[1], "gu_x_l2.bin");  // [B][LDX], the row pad zero
  for (uint32_t b = 0; b < (uint32_t)QWEN_B; ++b)
    for (uint32_t j = 0; j < (uint32_t)QWEN_LDX; ++j) {
      const uint16_t v = (j == b) ? FP16_ONE : 0u;
      fwrite(&v, 2, 1, f);
    }
  fclose(f);

  // [stage][strip][K tile][WSLOT]: KT rows of LDW (PT + pad, the pad zero), zeros to the slot.
  f = open_out(argv[1], "gu_w_l2.bin");
  const uint32_t fill = (uint32_t)QWEN_WSLOT - (uint32_t)(QWEN_KT * QWEN_LDW);
  uint16_t *row = calloc((size_t)QWEN_LDW + fill, 2);
  for (uint32_t s = 0; s < 2u; ++s)
    for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip)
      for (uint32_t step = 0; step < (uint32_t)(QWEN_K / QWEN_KT); ++step) {
        for (uint32_t kk = 0; kk < (uint32_t)QWEN_KT; ++kk) {
          const uint32_t k = step * (uint32_t)QWEN_KT + kk;
          for (uint32_t c = 0; c < (uint32_t)QWEN_LDW; ++c) {
            const uint32_t col = strip * (uint32_t)QWEN_PT + c;
            const int lit = c < (uint32_t)QWEN_PT && col < (uint32_t)QWEN_P &&
                            k < (uint32_t)QWEN_B && h_hot(k, col);
            row[c] = lit ? (s ? FP16_1_16 : FP16_16) : 0u;
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
