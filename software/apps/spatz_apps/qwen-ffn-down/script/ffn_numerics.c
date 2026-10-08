// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// How accurate is fp16 accumulation for the Qwen FFN projections? Host-only study.
//
//   cc -O2 -Iscript script/ffn_numerics.c -o /tmp/ffn_numerics -lm
//   /tmp/ffn_numerics <B> <K> <P> <KT> <cols> <sigma_w> <ks> [<ks> ...]
//
// The fp16 result is the kernel's arithmetic reproduced bit for bit (fp16_host.h fma16/add16:
// each of `ks` K parts accumulates its rows tile by tile with fused fp16 FMAs from +0, then the
// parts are added in order) -- the same model check 4 (ffn_check=4) compares against the
// hardware bit for bit. It is compared, on the same fp16 inputs, with:
//   ref    float64 (Kahan-compensated) sum -- the reference;
//   fp32   fp32 accumulation (fmaf chain: what vfwmacc would give), rounded to fp16 at the end;
//   floor  the reference rounded to fp16: the error no fp16 OUTPUT can avoid.
// Errors are reported relative to the RMS of the reference outputs (a scale-free "how big is
// the error next to a typical output"), plus the fraction of outputs off by more than 1% of it.
//
// Inputs: H ~ SiLU(g) * u, g, u ~ N(0, 1) (what SwiGLU produces); W ~ N(0, sigma_w^2). Both
// rounded to fp16. `cols` output columns are sampled evenly out of P (the statistics do not
// need all of them).
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "fp16_host.h"

static uint32_t hash32(uint32_t x) {
  x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
  return x;
}
static double gauss(uint32_t seed) {
  const double u1 = (hash32(seed) + 1.0) / 4294967297.0;
  const double u2 = hash32(seed ^ 0x9e3779b9u) / 4294967296.0;
  return sqrt(-2.0 * log(u1)) * cos(6.283185307179586 * u2);
}

typedef struct { double sq, mx; uint32_t over1; } err_t;
static void err_add(err_t *e, double d, double scale) {
  const double r = fabs(d) / scale;
  e->sq += r * r;
  if (r > e->mx) e->mx = r;
  e->over1 += (r > 0.01);
}

int main(int argc, char **argv) {
  if (argc < 8) {
    fprintf(stderr, "usage: %s B K P KT cols sigma_w ks [ks ...]\n", argv[0]);
    return 2;
  }
  const uint32_t B = atoi(argv[1]), K = atoi(argv[2]), P = atoi(argv[3]), KT = atoi(argv[4]);
  const uint32_t cols = atoi(argv[5]);
  const double sw = atof(argv[6]);
  const int nks = argc - 7;

  uint16_t *X = malloc((size_t)B * K * 2), *W = malloc((size_t)K * cols * 2);
  double *ref = malloc((size_t)B * cols * sizeof(double));
  uint16_t *y16 = malloc((size_t)B * cols * 2);
  if (!X || !W || !ref || !y16) { fprintf(stderr, "out of memory\n"); return 1; }
  for (uint32_t b = 0; b < B; ++b)
    for (uint32_t k = 0; k < K; ++k) {
      const uint32_t i = b * K + k;
      const double g = gauss(2u * i + 1u), u = gauss(2u * i + 0x40000001u);
      X[i] = double_to_fp16(g * u / (1.0 + exp(-g)));
    }
  for (uint32_t k = 0; k < K; ++k)
    for (uint32_t c = 0; c < cols; ++c) {
      const uint32_t p = (uint32_t)((uint64_t)c * P / cols);
      W[(size_t)k * cols + c] = double_to_fp16(sw * gauss(0x80000000u ^ (k * P + p)));
    }

  // Reference (float64, compensated) and the fp32-accumulation variant.
  double ss = 0.0;
  err_t e32 = {0}, efl = {0};
  float *y32 = malloc((size_t)B * cols * sizeof(float));
  for (uint32_t b = 0; b < B; ++b)
    for (uint32_t c = 0; c < cols; ++c) {
      double s = 0.0, comp = 0.0;
      float a32 = 0.0f;
      for (uint32_t k = 0; k < K; ++k) {
        const double xv = fp16_to_double(X[b * K + k]), wv = fp16_to_double(W[(size_t)k * cols + c]);
        const double t = xv * wv - comp, u = s + t;  // Kahan
        comp = (u - s) - t;
        s = u;
        a32 = fmaf((float)xv, (float)wv, a32);       // fp16*fp16 is exact in fp32; one rounding
      }
      ref[b * cols + c] = s;
      y32[b * cols + c] = a32;
      ss += s * s;
    }
  const double rms = sqrt(ss / ((double)B * cols));
  for (uint32_t i = 0; i < B * cols; ++i) {
    err_add(&e32, fp16_to_double(double_to_fp16((double)y32[i])) - ref[i], rms);
    err_add(&efl, fp16_to_double(double_to_fp16(ref[i])) - ref[i], rms);
  }
  printf("B=%u K=%u P=%u KT=%u cols=%u sigma_w=%g  rms(y)=%.4g  (errors relative to rms(y))\n",
         B, K, P, KT, cols, sw, rms);
  printf("  %-26s rms %.2e  max %.2e  >1%% %5.2f%%\n", "floor (ref rounded to fp16)",
         sqrt(efl.sq / (B * cols)), efl.mx, 100.0 * efl.over1 / (B * cols));
  printf("  %-26s rms %.2e  max %.2e  >1%% %5.2f%%\n", "fp32 accumulation",
         sqrt(e32.sq / (B * cols)), e32.mx, 100.0 * e32.over1 / (B * cols));

  // Optional blockwise variant (env FFN_CHUNK=c): fp16 FMAs for c rows at a time, each chunk
  // then added into an fp32 accumulator (vfwadd.wv), fp16 only at the end. Models an fp32 C
  // buffer that the kernel flushes into at chunk boundaries instead of fp16 all the way.
  const char *chunk_env = getenv("FFN_CHUNK");
  const uint32_t chunk = chunk_env ? (uint32_t)atoi(chunk_env) : 0u;
  uint16_t *acc = malloc((size_t)cols * 2), *sum = malloc((size_t)cols * 2);
  float *f32 = malloc((size_t)cols * sizeof(float));
  for (int a = 0; a < nks; ++a) {
    const uint32_t ks = atoi(argv[7 + a]), ktc = KT / ks;
    if (KT % ks || K % KT) { fprintf(stderr, "KT must divide K and ks divide KT\n"); return 2; }
    err_t e16 = {0};
    for (uint32_t b = 0; b < B; ++b) {
      for (uint32_t j = 0; j < ks; ++j) {
        for (uint32_t c = 0; c < cols; ++c) { acc[c] = 0u; f32[c] = 0.0f; }
        uint32_t rows = 0;
        for (uint32_t t = 0; t < K / KT; ++t)
          for (uint32_t n = 0; n < ktc; ++n) {
            const uint32_t k = t * KT + j * ktc + n;
            const uint16_t xv = X[b * K + k];
            const uint16_t *wr = W + (size_t)k * cols;
            for (uint32_t c = 0; c < cols; ++c) acc[c] = fma16(xv, wr[c], acc[c]);
            if (chunk && ++rows % chunk == 0)
              for (uint32_t c = 0; c < cols; ++c) {
                f32[c] = (float)((double)f32[c] + fp16_to_double(acc[c]));
                acc[c] = 0u;
              }
          }
        if (chunk) {
          for (uint32_t c = 0; c < cols; ++c) f32[c] = (float)((double)f32[c] + fp16_to_double(acc[c]));
        }
        if (chunk) {
          static float *fsum = 0;
          if (!fsum) fsum = malloc((size_t)cols * sizeof(float));
          for (uint32_t c = 0; c < cols; ++c) fsum[c] = j ? (float)((double)fsum[c] + f32[c]) : f32[c];
          if (j + 1 == ks)
            for (uint32_t c = 0; c < cols; ++c) sum[c] = double_to_fp16((double)fsum[c]);
        } else {
          for (uint32_t c = 0; c < cols; ++c) sum[c] = j ? add16(sum[c], acc[c]) : acc[c];
        }
      }
      for (uint32_t c = 0; c < cols; ++c) {
        y16[b * cols + c] = sum[c];
        err_add(&e16, fp16_to_double(sum[c]) - ref[b * cols + c], rms);
      }
    }
    char name[64];
    if (chunk) snprintf(name, sizeof(name), "fp16 x%u rows -> fp32, ks=%u", chunk, ks);
    else snprintf(name, sizeof(name), "fp16 accumulation, ks=%u", ks);
    printf("  %-26s rms %.2e  max %.2e  >1%% %5.2f%%   (%u sequential adds per part)\n", name,
           sqrt(e16.sq / (B * cols)), e16.mx, 100.0 * e16.over1 / (B * cols), K / ks);
  }
  return 0;
}
