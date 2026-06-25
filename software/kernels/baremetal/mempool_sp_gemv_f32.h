// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Navaneeth Kunhi Purayil, ETH Zurich <nkunhi@iis.ee.ethz.ch>
// Author: Diyou Shen,              ETH Zurich <dishen@iis.ee.ethz.ch>

#include "printf.h"

// gemv_f32_col          = column-major (transpose_a=1) unroll-8.
// gemv_f32_col_prefetch = same, with scalar-x prefetch + bank-line-stride
//                         loads.
// gemv_f32_row          = row-major (transpose_a=0) with vfredusum/vfslide1up
//                         reduction.

// Default column-major (transpose_a=1) gemv, unrolled by 8 in the N dimension.
inline void gemv_f32_col(float *a, float *b, float *c, uint32_t M,
                         uint32_t M_core, uint32_t N)
    __attribute__((always_inline));
// Optimized column-major gemv: line-stride loads + scalar-prefetched x[].
// M_core should not be less than 16; N is passed pre-divided by 8.
inline void gemv_f32_col_prefetch(float *a, float *b, float *c, uint32_t M_core,
                                  uint32_t N, uint32_t offset)
    __attribute__((always_inline));
// Row-major backup GEMV: each core reduces M rows of a contiguous MxN tile.
inline void gemv_f32_row(float *a, float *b, float *c, uint32_t M, uint32_t N)
    __attribute__((always_inline));

void gemv_f32_col(float *a, float *b, float *c, uint32_t M, uint32_t M_core,
                  uint32_t N) {
  unsigned int vl, avl = M_core;
  float *a_ = a;
  float *b_ = b;
  float *c_ = c;

  asm volatile("vmv.s.x v28, zero");
  do {
    asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(avl));
    for (uint32_t col = 0; col < N; col += 8) {
      // Load chunk a
      asm volatile("vle32.v v0, (%0)" ::"r"(a_));
      a_ += M;
      // Multiply and accumulate
      asm volatile("vfmacc.vf v28, %0, v0" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v4, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v4" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v8, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v8" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v12, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v12" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v16, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v16" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v20, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v20" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v24, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v24" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v8, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v8" ::"f"(*b_));
      b_++;
    }
    asm volatile("vse32.v v28, (%0)" ::"r"(c_));
    avl -= vl;
    c_ += vl;
    b_ = b;
    a_ += vl;
  } while (avl > 0);
}

void gemv_f32_col_prefetch(float *a, float *b, float *c, uint32_t M_core,
                           uint32_t N, uint32_t offset) {

  unsigned int vl, avl = M_core;
  float *a_ = a;
  float *s1_ = b;
  float *s2_ = b + 1;
  float *s3_ = b + 2;
  float *s4_ = b + 3;
  register float b1 __asm__("ft1") = *s1_;
  register float b2 __asm__("ft2") = *s2_;
  register float b3 __asm__("ft3") = *s3_;
  register float b4 __asm__("ft4") = *s4_;
  float *c_ = c;

  asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"(avl));
  asm volatile("vmv.v.i v24, 0");

  for (uint32_t i = 0; i < N; i++) {

    asm volatile("vle32.v v0, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, ft1, v0" ::"f"(b1));
    s1_ += 4;
    b1 = *s1_;

    asm volatile("vle32.v v1, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, ft2, v1" ::"f"(b2));
    s2_ += 4;
    b2 = *s2_;

    asm volatile("vle32.v v2, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, ft3, v2" ::"f"(b3));
    s3_ += 4;
    b3 = *s3_;

    asm volatile("vle32.v v3, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, ft4, v3" ::"f"(b4));
    s4_ += 4;
    b4 = *s4_;

    asm volatile("vle32.v v4, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, ft1, v4" ::"f"(b1));
    s1_ += 4;
    b1 = *s1_;

    asm volatile("vle32.v v5, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, ft2, v5" ::"f"(b2));
    s2_ += 4;
    b2 = *s2_;

    asm volatile("vle32.v v6, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, ft3, v6" ::"f"(b3));
    s3_ += 4;
    b3 = *s3_;

    asm volatile("vle32.v v7, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, ft4, v7" ::"f"(b4));
    s4_ += 4;
    b4 = *s4_;
  }
  asm volatile("vse32.v v24, (%0)" ::"r"(c_));
}

void gemv_f32_row(float *a, float *b, float *c, uint32_t M, uint32_t N) {
  unsigned int vl, avl = N;
  float *a_ = a + (M - 2) * N;
  float *b_ = b;

  asm volatile("vmv.s.x v16, zero");
  asm volatile("vmv.s.x v20, zero");

  for (uint32_t r = 0; r < M / 2; r++) {
    float *a2 = a_ + N;

    do {
      asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(avl));

      asm volatile("vle32.v v0,  (%0)" ::"r"(b_));
      b_ += vl;
      asm volatile("vle32.v v4, (%0)" ::"r"(a_));
      a_ += vl;

      if (avl == N) {
        asm volatile("vfmul.vv v24, v4, v0");
      } else {
        asm volatile("vfmacc.vv v24, v4, v0");
      }

      asm volatile("vle32.v v8, (%0)" ::"r"(a2));
      a2 += vl;
      if (avl == N) {
        asm volatile("vfmul.vv v28, v8, v0");
      } else {
        asm volatile("vfmacc.vv v28, v8, v0");
      }

      avl -= vl;
      if (avl > 0) {
        asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(avl));
        asm volatile("vle32.v v12, (%0)" ::"r"(b_));
        b_ += vl;
        asm volatile("vle32.v v4, (%0)" ::"r"(a_));
        a_ += vl;

        asm volatile("vfmacc.vv v24, v4, v12");

        asm volatile("vle32.v v8, (%0)" ::"r"(a2));
        a2 += vl;

        asm volatile("vfmacc.vv v28, v8, v12");

        avl -= vl;
      }
    } while (avl > 0);

    asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(N));
    asm volatile("vfredusum.vs v16, v28, v16");
    asm volatile("vfslide1up.vf v20, v16, %0" ::"f"((float)0.0));
    asm volatile("vfredusum.vs v20, v24, v20");
    asm volatile("vfslide1up.vf v16, v20, %0" ::"f"((float)0.0));
    b_ = b;
    a_ -= (3 * N);
    avl = N;
  }

  asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(M));
  asm volatile("vse32.v v20,  (%0)" ::"r"(c));
}
