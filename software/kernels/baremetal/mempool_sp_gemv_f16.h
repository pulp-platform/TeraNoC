// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Diyou Shen,              ETH Zurich <dishen@iis.ee.ethz.ch>
// Author: Navaneeth Kunhi Purayil, ETH Zurich <nkunhi@iis.ee.ethz.ch>

#include "printf.h"

// gemv_f16_col = column-major (transpose_a=1) e16/m4 gemv, unrolled by 2 in the
//                N dimension with two accumulators (v4/v12), vfadd.vv finalize
//                and flh scalar-x loads.
inline void gemv_f16_col(__fp16 *a, __fp16 *b, __fp16 *c, uint32_t M,
                         uint32_t M_core, uint32_t N)
    __attribute__((always_inline));

void gemv_f16_col(__fp16 *a, __fp16 *b, __fp16 *c, uint32_t M, uint32_t M_core,
                  uint32_t N) {
  unsigned int vl, avl = M_core;
  __fp16 *a_ = a;
  __fp16 *b_ = b;
  __fp16 *c_ = c;

  do {
    asm volatile("vsetvli %0, %1, e16, m4, ta, ma" : "=r"(vl) : "r"(avl));
    for (uint32_t col = 0; col < N; col += 2) {
      // Load chunk a
      asm volatile("vle16.v v0, (%0)" ::"r"(a_));
      a_ += M;

      // Load chunk a
      asm volatile("vle16.v v8, (%0)" ::"r"(a_));
      a_ += M;

      // Multiply and accumulate
      float t0;
      asm volatile("flh %[t], 0(%[b])" : [t] "=f"(t0) : [b] "r"(b_));
      if (col == 0) {
        asm volatile("vfmul.vf v4, v0, %0" ::"f"(t0));
      } else {
        asm volatile("vfmacc.vf v4, %0, v0" ::"f"(t0));
      }
      b_++;

      // Multiply and accumulate
      float t1;
      asm volatile("flh %[t], 0(%[b])" : [t] "=f"(t1) : [b] "r"(b_));
      if (col == 0) {
        asm volatile("vfmul.vf v12, v8, %0" ::"f"(t1));
      } else {
        asm volatile("vfmacc.vf v12, %0, v8" ::"f"(t1));
      }
      b_++;
    }
    asm volatile("vfadd.vv v12, v12, v4");
    asm volatile("vse16.v v12, (%0)" ::"r"(c_));
    avl -= vl;
    c_ += vl;
    b_ = b;
    a_ = a + avl;
  } while (avl > 0);
}
