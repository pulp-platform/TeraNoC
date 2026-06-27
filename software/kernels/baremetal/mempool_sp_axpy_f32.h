// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Domenic Wuthrich, ETH Zurich

// 32-bit AXPY: y = a * x + y
void faxpy_v32b(const float a, const float *x, const float *y, uint32_t round,
                uint32_t dim) {
  const float *std = y;
  for (uint32_t rnd = 0; rnd < round; rnd++) {
    std = y;
    // Load vectors
    asm volatile("vle32.v v0, (%0)" ::"r"(x));
    asm volatile("vle32.v v8, (%0)" ::"r"(y));
    x += dim;
    y += dim;

    // Multiply-accumulate
    asm volatile("vfmacc.vf v8, %0, v0" ::"f"(a));

    // Store results
    asm volatile("vse32.v v8, (%0)" ::"r"(std));
  }
}

// 32-bit AXPY: y = a * x + y
void faxpy_v32b_unroll2(const float a, const float *x, const float *y,
                        uint32_t round, uint32_t dim) {
  const float *std1 = y;
  const float *std2 = y;
  for (uint32_t rnd = 0; rnd < round; rnd++) {
    std1 = y;
    asm volatile("vle32.v v0, (%0)" ::"r"(x));
    x += dim;
    asm volatile("vle32.v v8, (%0)" ::"r"(y));
    y += dim;
    asm volatile("vfmacc.vf v8, %0, v0" ::"f"(a));

    std2 = y;
    asm volatile("vle32.v v16, (%0)" ::"r"(x));
    x += dim;
    asm volatile("vle32.v v24, (%0)" ::"r"(y));
    y += dim;
    asm volatile("vfmacc.vf v24, %0, v16" ::"f"(a));

    // Store results
    asm volatile("vse32.v v8,  (%0)" ::"r"(std1));
    asm volatile("vse32.v v24, (%0)" ::"r"(std2));
  }
}

// 32-bit AXPY: y = a * x + y
void faxpy_v32b_unroll4(const float a, const float *x, const float *y,
                        uint32_t round, uint32_t dim) {
  const float *std1 = y;
  const float *std2 = y;
  const float *std3 = y;
  const float *std4 = y;

  for (uint32_t rnd = 0; rnd < round; rnd++) {
    std1 = y;
    asm volatile("vle32.v v0, (%0)" ::"r"(x));
    x += dim;
    asm volatile("vle32.v v4, (%0)" ::"r"(y));
    y += dim;
    asm volatile("vfmacc.vf v4, %0, v0" ::"f"(a));

    std2 = y;
    asm volatile("vle32.v v8, (%0)" ::"r"(x));
    x += dim;
    asm volatile("vle32.v v12, (%0)" ::"r"(y));
    y += dim;
    asm volatile("vfmacc.vf v12, %0, v8" ::"f"(a));

    std3 = y;
    asm volatile("vle32.v v16, (%0)" ::"r"(x));
    x += dim;
    asm volatile("vle32.v v20, (%0)" ::"r"(y));
    y += dim;
    asm volatile("vfmacc.vf v20, %0, v16" ::"f"(a));

    std4 = y;
    asm volatile("vle32.v v24, (%0)" ::"r"(x));
    x += dim;
    asm volatile("vle32.v v28, (%0)" ::"r"(y));
    y += dim;
    asm volatile("vfmacc.vf v28, %0, v24" ::"f"(a));

    // Store results
    asm volatile("vse32.v v4,  (%0)" ::"r"(std1));
    asm volatile("vse32.v v12, (%0)" ::"r"(std2));
    asm volatile("vse32.v v20, (%0)" ::"r"(std3));
    asm volatile("vse32.v v28, (%0)" ::"r"(std4));
  }
}
