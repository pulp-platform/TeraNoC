// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Writes the operand images the ELF carries, plus the assembly stub that places
// them in L2. Runs on the HOST: the target then starts with W and X already in
// memory and fills nothing.
//
// The values come from qwen_pattern.h, the same header the target verifies
// against, so a preloaded operand and its expectation cannot disagree.
// qwen-ffn-down: X is H [B][K], W is Wdown; one stage (QWEN_STAGES_N).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#include "qwen_layout.h"
#include "qwen_pattern.h"
#include "fp16_host.h"

static void write_bin(const char *path, uint32_t rows, uint32_t cols,
                      uint16_t (*value)(uint32_t, uint32_t, uint32_t),
                      uint32_t stages) {
  FILE *f = fopen(path, "wb");
  if (!f) { perror(path); exit(1); }
  // One row at a time: the full image is far too large to hold in memory.
  uint16_t *row = malloc((size_t)cols * sizeof(uint16_t));
  if (!row) { fprintf(stderr, "out of memory\n"); exit(1); }
  for (uint32_t s = 0; s < stages; ++s)
    for (uint32_t r = 0; r < rows; ++r) {
      for (uint32_t c = 0; c < cols; ++c) row[c] = value(s, r, c);
      if (fwrite(row, sizeof(uint16_t), cols, f) != cols) { perror(path); exit(1); }
    }
  free(row);
  fclose(f);
}

// W is [stage][strip][K][PT] -- strip-major, so a K tile of one strip is one
// contiguous DMA (qwen_layout.h, "P strips"); with one strip that is [stage][K][LDP].
// Columns past P are alignment padding the kernel never reads, and are zero so a run
// that does read them is obviously wrong.
#if QWEN_CHECK == 4
// ---- Check 4: random operands and the bit-exact model of the kernel ---------------------
// H ~ SiLU(g) * u with g, u ~ N(0, 1) (the distribution a real SwiGLU output has), W ~ N(0,
// 0.02^2) (a trained projection's scale), both rounded to fp16. The model replays what the
// kernel does to every output: each K part j accumulates its rows in order -- tile by tile,
// row by row -- with fused fp16 FMAs from +0; then the parts are added in order 0, 1, ...
// (qwen_ksplit_reduce). fma16/add16 are exact-then-round-once (script/fp16_host.h).
static uint16_t *X4, *W4;
static uint32_t hash32(uint32_t x) {  // splitmix-style finaliser
  x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
  return x;
}
static double gauss(uint32_t seed) {
  const double u1 = (hash32(seed) + 1.0) / 4294967297.0;
  const double u2 = hash32(seed ^ 0x9e3779b9u) / 4294967296.0;
  return sqrt(-2.0 * log(u1)) * cos(6.283185307179586 * u2);
}
static void make_check4(void) {
  X4 = malloc((size_t)QWEN_B * QWEN_K * 2);
  W4 = malloc((size_t)QWEN_K * QWEN_P * 2);
  if (!X4 || !W4) { fprintf(stderr, "out of memory\n"); exit(1); }
  for (uint32_t b = 0; b < (uint32_t)QWEN_B; ++b)
    for (uint32_t k = 0; k < (uint32_t)QWEN_K; ++k) {
      const uint32_t i = b * (uint32_t)QWEN_K + k;
      const double g = gauss(2u * i + 1u), u = gauss(2u * i + 0x40000001u);
      X4[i] = double_to_fp16(g * u / (1.0 + exp(-g)));
    }
  for (uint32_t k = 0; k < (uint32_t)QWEN_K; ++k)
    for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p)
      W4[k * (uint32_t)QWEN_P + p] = double_to_fp16(0.02 * gauss(0x80000000u ^ (k * (uint32_t)QWEN_P + p)));
}
static uint16_t yref_value(uint32_t stage, uint32_t b, uint32_t p);
static uint16_t *Y4;
// The kernel's calls, in order, for K part j: (first row, rows) of each. Tile 0 is
// FFN_PRIME_SPLIT calls of FFN_SUB_ROWS rows when it is fetched in pieces.
static uint32_t n_calls(void) { return (uint32_t)(FFN_PRIME_SPLIT + QWEN_K / QWEN_KT - 1); }
static void call_rows(uint32_t j, uint32_t i, uint32_t *k0, uint32_t *n) {
  if (i < (uint32_t)FFN_PRIME_SPLIT) {
    *k0 = j * (uint32_t)QWEN_KT_CORE + i * (uint32_t)FFN_SUB_ROWS;
    *n = FFN_SUB_ROWS;
  } else {
    *k0 = (i - (uint32_t)FFN_PRIME_SPLIT + 1u) * (uint32_t)QWEN_KT + j * (uint32_t)QWEN_KT_CORE;
    *n = QWEN_KT_CORE;
  }
}
static void model_check4(void) {
  Y4 = malloc((size_t)QWEN_B * QWEN_P * 2);
  uint16_t *acc = malloc((size_t)QWEN_P * 2), *sum = malloc((size_t)QWEN_P * 2);
  float *c32 = malloc((size_t)QWEN_P * sizeof(float)), *s32 = malloc((size_t)QWEN_P * sizeof(float));
  if (!Y4 || !acc || !sum || !c32 || !s32) { fprintf(stderr, "out of memory\n"); exit(1); }
  for (uint32_t b = 0; b < (uint32_t)QWEN_B; ++b) {
    for (uint32_t j = 0; j < (uint32_t)QWEN_KSPLIT; ++j) {
      for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p) acc[p] = 0u;  // +0
      for (uint32_t i = 0; i < n_calls(); ++i) {
        uint32_t k0, n;
        call_rows(j, i, &k0, &n);
#if QWEN_ACC32
        for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p) acc[p] = 0u;  // every call from +0
#endif
        for (uint32_t r = 0; r < n; ++r) {
          const uint32_t k = k0 + r;
          const uint16_t xv = X4[b * (uint32_t)QWEN_K + k];
          const uint16_t *wr = W4 + (size_t)k * QWEN_P;
          for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p) acc[p] = fma16(xv, wr[p], acc[p]);
        }
#if QWEN_ACC32
        // vfwadd.wv: the fp16 partial widened (exact) and added in fp32, one rounding. The
        // double sum is exact whenever the rounding could matter (script/fp16_host.h).
        for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p)
          c32[p] = i ? (float)((double)c32[p] + fp16_to_double(acc[p]))
                     : (float)fp16_to_double(acc[p]);
#endif
      }
#if QWEN_ACC32
      // qwen_ksplit_reduce: C + P1 + P2 ... in fp32, part order.
      for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p)
        s32[p] = j ? (float)((double)s32[p] + (double)c32[p]) : c32[p];
#else
      for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p) sum[p] = j ? add16(sum[p], acc[p]) : acc[p];
#endif
    }
#if QWEN_ACC32
    for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p) sum[p] = double_to_fp16((double)s32[p]);
#endif
    for (uint32_t p = 0; p < (uint32_t)QWEN_P; ++p) Y4[b * (uint32_t)QWEN_P + p] = sum[p];
  }
  free(acc);
  free(sum);
  free(c32);
  free(s32);
}
static uint16_t yref_value(uint32_t stage, uint32_t b, uint32_t p) {
  (void)stage;
  return Y4[b * (uint32_t)QWEN_P + p];
}
#endif

static uint16_t w_value(uint32_t stage, uint32_t k, uint32_t p) {
#if QWEN_CHECK == 4
  (void)stage;
  return (p < (uint32_t)QWEN_P) ? W4[k * (uint32_t)QWEN_P + p] : 0u;
#else
  return (p < (uint32_t)QWEN_P) ? qwen_w_bits(stage, k, p) : 0u;
#endif
}
static void write_w_bin(const char *path) {
  FILE *f = fopen(path, "wb");
  if (!f) { perror(path); exit(1); }
  // [stage][strip][K tile][QWEN_WSLOT]: KT rows of LDW = PT + QWEN_WPAD (the pad
  // stored as zeros, so the target's K-tile DMA stays one contiguous copy), then zeros
  // up to the sweep-rounded slot so every tile starts sweep-aligned (qwen_layout.h).
  const uint32_t fill = (uint32_t)QWEN_WSLOT - (uint32_t)(QWEN_KT * QWEN_LDW);
  uint16_t *row = calloc((size_t)QWEN_LDW + fill, sizeof(uint16_t));
  if (!row) { fprintf(stderr, "out of memory\n"); exit(1); }
  for (uint32_t s = 0; s < (uint32_t)QWEN_STAGES_N; ++s)
    for (uint32_t strip = 0; strip < (uint32_t)QWEN_NSTRIPS; ++strip)
      for (uint32_t step = 0; step < (uint32_t)(QWEN_K / QWEN_KT); ++step) {
        for (uint32_t kk = 0; kk < (uint32_t)QWEN_KT; ++kk) {
          const uint32_t k = FFN_W_ROW(step, kk);  // tile 0 piece-major (qwen_layout.h)
          for (uint32_t c = 0; c < (uint32_t)QWEN_PT; ++c)
            row[c] = w_value(s, k, strip * (uint32_t)QWEN_PT + c);
          for (uint32_t c = QWEN_PT; c < (uint32_t)QWEN_LDW; ++c) row[c] = 0;
          if (fwrite(row, sizeof(uint16_t), QWEN_LDW, f) != (size_t)QWEN_LDW) { perror(path); exit(1); }
        }
        if (fill) {
          for (uint32_t c = 0; c < fill; ++c) row[c] = 0;
          if (fwrite(row, sizeof(uint16_t), fill, f) != (size_t)fill) { perror(path); exit(1); }
        }
      }
  free(row);
  fclose(f);
}
static uint16_t x_value(uint32_t stage, uint32_t b, uint32_t k) {
  (void)stage;
  if (k >= (uint32_t)QWEN_K) return 0u;  // H row pad
#if QWEN_CHECK == 4
  return X4[b * (uint32_t)QWEN_K + k];
#else
  return qwen_x_bits(b, k);
#endif
}

#if QWEN_SWIGLU
// ---- G and U for the SwiGLU prologue, in gate-up's output layout -------------------------
// Checks 1 and 2: the values that make H exactly the pattern (qwen_pattern.h). Check 3: a
// deterministic pseudo-random mix plus edge values, and the float64 reference H next to them.
#if QWEN_CHECK == 3
static uint32_t rng_state = 0x2545f491u;
static uint32_t rng32(void) {  // xorshift32
  rng_state ^= rng_state << 13;
  rng_state ^= rng_state >> 17;
  rng_state ^= rng_state << 5;
  return rng_state;
}
static double rng_normal(void) {  // Box-Muller
  const double u1 = (rng32() + 1.0) / 4294967297.0, u2 = rng32() / 4294967296.0;
  return sqrt(-2.0 * log(u1)) * cos(6.283185307179586 * u2);
}
// Edge values, as fp16 bits: zeros, the extremes, subnormals, and points around the
// polynomial / clamp boundaries (|g| near 87, where exp(-|g|) is clamped).
static const uint16_t edge[] = {
    0x0000u, 0x8000u, 0x3c00u, 0xbc00u, 0x7bffu, 0xfbffu, 0x0001u, 0x8001u, 0x03ffu, 0x83ffu,
    0x0400u, 0x8400u, 0x4c00u, 0xcc00u, 0x5170u, 0xd170u, 0x5570u, 0xd570u, 0x5970u, 0xd970u,
    0x1000u, 0x9000u, 0x3800u, 0xb800u, 0x4900u, 0xc900u, 0x4d00u, 0xcd00u};
#define N_EDGE (sizeof(edge) / sizeof(edge[0]))
static uint16_t *g3, *u3;
static void make_check3(void) {
  const uint32_t n = (uint32_t)(QWEN_B * QWEN_K);
  g3 = malloc((size_t)n * 2);
  u3 = malloc((size_t)n * 2);
  if (!g3 || !u3) { fprintf(stderr, "out of memory\n"); exit(1); }
  for (uint32_t i = 0; i < n; ++i) {
    // Every 16th element pairs an edge g with an edge u; the rest are N(0, s^2) with the
    // scale drawn from 1/64 .. 64, so both tails of the sigmoid are well populated.
    if (i % 16u == 7u) {
      g3[i] = edge[(i / 16u) % N_EDGE];
      u3[i] = edge[(i / 16u / N_EDGE + i / 16u) % N_EDGE];
    } else {
      const double sg = ldexp(1.0, (int)(rng32() % 13u) - 6), su = ldexp(1.0, (int)(rng32() % 7u) - 3);
      g3[i] = double_to_fp16(rng_normal() * sg);
      u3[i] = double_to_fp16(rng_normal() * su);
    }
  }
}
static uint16_t href_value(uint32_t stage, uint32_t b, uint32_t k) {
  (void)stage;
  const uint32_t i = b * (uint32_t)QWEN_K + k;
  const double g = fp16_to_double(g3[i]), u = fp16_to_double(u3[i]);
  return double_to_fp16(g * u / (1.0 + exp(-g)));
}
#endif
static uint16_t gu_bits(uint32_t stage, uint32_t b, uint32_t k) {
#if QWEN_CHECK == 3
  const uint32_t i = b * (uint32_t)QWEN_K + k;
  return stage ? u3[i] : g3[i];
#elif QWEN_CHECK == 1 || QWEN_CHECK == 2
  return stage ? qwen_u_bits(b, k) : qwen_g_bits(b, k);
#else
  (void)stage; (void)b; (void)k;
  return 0u;
#endif
}
// [stage][strip][B][FFN_GU_LD]: the pad columns and nothing else are zero.
static void write_gu_bin(const char *path) {
  FILE *f = fopen(path, "wb");
  if (!f) { perror(path); exit(1); }
  uint16_t *row = calloc((size_t)FFN_GU_LD, sizeof(uint16_t));
  if (!row) { fprintf(stderr, "out of memory\n"); exit(1); }
  for (uint32_t s = 0; s < 2u; ++s) {
    for (uint32_t strip = 0; strip < (uint32_t)FFN_GU_NSTRIPS; ++strip)
      for (uint32_t b = 0; b < (uint32_t)QWEN_B; ++b) {
        for (uint32_t c = 0; c < (uint32_t)FFN_GU_LD; ++c)
          row[c] = (c < (uint32_t)FFN_GU_PT) ? gu_bits(s, b, strip * (uint32_t)FFN_GU_PT + c) : 0u;
        if (fwrite(row, sizeof(uint16_t), FFN_GU_LD, f) != (size_t)FFN_GU_LD) { perror(path); exit(1); }
      }
    // Zeros up to the sweep-rounded slot, so U starts where main.c's qwen_gu_l2[1] does.
    const uint16_t z = 0;
    for (uint32_t i = FFN_GU_ELEMS; i < (uint32_t)FFN_GU_SLOT; ++i)
      if (fwrite(&z, sizeof(z), 1, f) != 1) { perror(path); exit(1); }
  }
  free(row);
  fclose(f);
}
#endif

static void stub_symbol(FILE *f, const char *sym, const char *dir, const char *bin) {
  fprintf(f,
          "  .balign %u\n"
          "  .globl %s\n"
          "%s:\n"
          "  .incbin \"%s/%s\"\n",
          (unsigned)QWEN_MESH_SWEEP, sym, sym, dir, bin);
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: %s <data-dir>\n", argv[0]); return 2; }
  char path[4096];

#if QWEN_CHECK == 4
  make_check4();
  model_check4();
  snprintf(path, sizeof(path), "%s/qwen_yref.bin", argv[1]);
  write_bin(path, QWEN_B, QWEN_P, yref_value, 1);
#endif
  snprintf(path, sizeof(path), "%s/qwen_w.bin", argv[1]);
  write_w_bin(path);
#if QWEN_SWIGLU
#if QWEN_CHECK == 3
  make_check3();
  snprintf(path, sizeof(path), "%s/qwen_href.bin", argv[1]);
  write_bin(path, QWEN_B, QWEN_K, href_value, 1);
#endif
  snprintf(path, sizeof(path), "%s/qwen_gu.bin", argv[1]);
  write_gu_bin(path);
#else
  snprintf(path, sizeof(path), "%s/qwen_x.bin", argv[1]);
  write_bin(path, QWEN_B, QWEN_LDX, x_value, 1);  // [B][LDX], the row pad zero
#endif

  // The stub: .incbin costs the assembler a copy, where an initialised C array
  // of this many elements would never finish compiling.
  snprintf(path, sizeof(path), "%s/qwen_operands.S", argv[1]);
  FILE *f = fopen(path, "w");
  if (!f) { perror(path); return 1; }
  fprintf(f,
          "// GENERATED by script/gen_operands.c -- do not hand-edit.\n"
          "  .section .l2, \"a\", @progbits\n");
  stub_symbol(f, "qwen_w_l2", argv[1], "qwen_w.bin");
#if QWEN_SWIGLU
  stub_symbol(f, "qwen_gu_l2", argv[1], "qwen_gu.bin");
#if QWEN_CHECK == 3
  stub_symbol(f, "qwen_href_l2", argv[1], "qwen_href.bin");
#endif
#else
  stub_symbol(f, "qwen_x_l2", argv[1], "qwen_x.bin");
#endif
#if QWEN_CHECK == 4
  stub_symbol(f, "qwen_yref_l2", argv[1], "qwen_yref.bin");
#endif
  fclose(f);
  return 0;
}
