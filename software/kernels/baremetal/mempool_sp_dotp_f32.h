// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Diyou Shen     <dishen@student.ethz.ch>
//         Matteo Perotti <mperotti@iis.ee.ethz.ch>

// 32-bit dot-product kernels, named fdotp_v32b_<partition>_p<phase>_u<unroll>:
//   <partition> = local  : each core works only on its own tile's data (LMUL=1;
//                          the kernel re-issues its own vsetvli internally).
//               = global : each core sweeps an interleaved strip of the whole
//                          array per round (LMUL=4 for u1/u2/u4, LMUL=2 for
//                          u8).
//   p1 builds the per-core partial-product vector; p2 horizontally reduces it.
//   u<N> is the unroll factor (independent accumulators / macs per iteration).
// All variants are always defined; the app selects which to call.

// ---- local-tile kernels (LMUL=1) ----

// 32-bit dot-product: a * b
void fdotp_v32b_local_p1_u1(const float *a, const float *b, uint32_t avl,
                            const uint32_t loops, const uint32_t offset) {
  const uint32_t orig_avl = avl;
  uint32_t vl;

  const float *a_in_loop = a;
  const float *a_out_loop = a;
  const float *b_in_loop = b;
  const float *b_out_loop = b;

  for (uint32_t i = 0; i < loops; i++) {
    // Stripmine and accumulate a partial reduced vector
    do {
      // Set the vl
      asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"(avl));

      // Load chunk a and b
      asm volatile("vle32.v v8,  (%0)" ::"r"(a_in_loop));
      asm volatile("vle32.v v16, (%0)" ::"r"(b_in_loop));
      a_in_loop += vl;
      b_in_loop += vl;
      // Multiply and accumulate
      if (i == 0 & avl == orig_avl) {
        // first loop first calc, do mul
        asm volatile("vfmul.vv v24, v8, v16");
      } else {
        asm volatile("vfmacc.vv v24, v8, v16");
      }
      avl -= vl;
    } while (avl > 0);

    if (i != loops - 1) {
      a_out_loop += offset;
      b_out_loop += offset;
      a_in_loop = a_out_loop;
      b_in_loop = b_out_loop;
      avl = orig_avl;
    }
  }
}

void fdotp_v32b_local_p1_u2(const float *a, const float *b, uint32_t avl,
                            const uint32_t loops, const uint32_t offset) {

  uint32_t vl;
  const float *a_in_loop = a;
  const float *b_in_loop = b;
  asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"(avl));
  asm volatile("vmv.v.i v24, 0");
  asm volatile("vmv.v.i v25, 0");

  for (uint32_t i = 0; i < loops; i++) {
    // Stripmine and accumulate a partial reduced vector
    // Load chunk a and b
    asm volatile("vle32.v v8,  (%0)" ::"r"(a_in_loop));
    asm volatile("vle32.v v16, (%0)" ::"r"(b_in_loop));
    a_in_loop += offset;
    b_in_loop += offset;
    // Multiply and accumulate
    asm volatile("vfmacc.vv v24, v8, v16");

    // Load chunk a and b
    asm volatile("vle32.v v9,  (%0)" ::"r"(a_in_loop));
    asm volatile("vle32.v v17, (%0)" ::"r"(b_in_loop));
    a_in_loop += offset;
    b_in_loop += offset;
    // Multiply and accumulate
    asm volatile("vfmacc.vv v25, v9, v17");
  }
}

float fdotp_v32b_local_p2_u1() {
  float red;
  // Reduce and return
  asm volatile("vfredusum.vs v0, v24, v0");
  asm volatile("vfmv.f.s %0, v0" : "=f"(red));
  return red;
}

float fdotp_v32b_local_p2_u2() {
  float red, blue;
  asm volatile("vfredusum.vs v0, v24, v0");
  asm volatile("vfredusum.vs v1, v25, v1");
  asm volatile("vfmv.f.s %0, v0" : "=f"(red));
  asm volatile("vfmv.f.s %0, v1" : "=f"(blue));
  return (red + blue);
}

// ---- global round-based kernels (LMUL=4, m2 for u8) ----

// 32-bit dot-product: a * b
void fdotp_v32b_global_p1_u1(const float *a, const float *b, uint32_t round,
                             uint32_t dim) {
  for (uint32_t rnd = 0; rnd < round; rnd++) {
    // Load chunk a and b
    asm volatile("vle32.v v8,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v16, (%0)" ::"r"(b));
    b += dim;
    if (rnd == 0)
      asm volatile("vfmul.vv v24, v8, v16");
    else
      asm volatile("vfmacc.vv v24, v8, v16");
  }
}

void fdotp_v32b_global_p1_u2(const float *a, const float *b, uint32_t round,
                             uint32_t dim) {
  for (uint32_t rnd = 0; rnd < round; rnd++) {
    // Load chunk a and b
    asm volatile("vle32.v v0,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v4,  (%0)" ::"r"(b));
    b += dim;

    if (rnd == 0)
      asm volatile("vfmul.vv v8, v0, v4");
    else
      asm volatile("vfmacc.vv v8, v0, v4");

    // Load chunk a and b
    asm volatile("vle32.v v12,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v16, (%0)" ::"r"(b));
    b += dim;

    if (rnd == 0)
      asm volatile("vfmul.vv v20, v12, v16");
    else
      asm volatile("vfmacc.vv v20, v12, v16");
  }
}

void fdotp_v32b_global_p1_u4(const float *a, const float *b, uint32_t round,
                             uint32_t dim) {
  for (uint32_t rnd = 0; rnd < round; rnd++) {
    // Load chunk a and b
    asm volatile("vle32.v v0,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v4,  (%0)" ::"r"(b));
    b += dim;

    if (rnd == 0)
      asm volatile("vfmul.vv v8, v0, v4");
    else
      asm volatile("vfmacc.vv v8, v0, v4");

    // Load chunk a and b
    asm volatile("vle32.v v12,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v16, (%0)" ::"r"(b));
    b += dim;

    asm volatile("vfmacc.vv v8, v12, v16");

    // Load chunk a and b
    asm volatile("vle32.v v20,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v24, (%0)" ::"r"(b));
    b += dim;

    asm volatile("vfmacc.vv v8, v20, v24");

    // Load chunk a and b
    asm volatile("vle32.v v28,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v16, (%0)" ::"r"(b));
    b += dim;

    asm volatile("vfmacc.vv v8, v28, v16");
  }
}

void fdotp_v32b_global_p1_u8(const float *a, const float *b, uint32_t round,
                             uint32_t dim) {
  for (uint32_t rnd = 0; rnd < round; rnd++) {
    // Load chunk a and b
    asm volatile("vle32.v v0,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v2,  (%0)" ::"r"(b));
    b += dim;

    if (rnd == 0)
      asm volatile("vfmul.vv v4, v0, v2");
    else
      asm volatile("vfmacc.vv v4, v0, v2");

    // Load chunk a and b
    asm volatile("vle32.v v6,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v8, (%0)" ::"r"(b));
    b += dim;

    if (rnd == 0)
      asm volatile("vfmul.vv v10, v6, v8");
    else
      asm volatile("vfmacc.vv v10, v6, v8");

    asm volatile("vle32.v v12,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v14, (%0)" ::"r"(b));
    b += dim;
    asm volatile("vfmacc.vv v4, v12, v14");

    asm volatile("vle32.v v16,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v18, (%0)" ::"r"(b));
    b += dim;
    asm volatile("vfmacc.vv v10, v16, v18");

    asm volatile("vle32.v v20,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v22, (%0)" ::"r"(b));
    b += dim;
    asm volatile("vfmacc.vv v4, v20, v22");

    asm volatile("vle32.v v24,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v26, (%0)" ::"r"(b));
    b += dim;
    asm volatile("vfmacc.vv v10, v24, v26");

    asm volatile("vle32.v v12,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v14, (%0)" ::"r"(b));
    b += dim;
    asm volatile("vfmacc.vv v4, v12, v14");

    asm volatile("vle32.v v16,  (%0)" ::"r"(a));
    a += dim;
    asm volatile("vle32.v v18, (%0)" ::"r"(b));
    b += dim;
    asm volatile("vfmacc.vv v10, v16, v18");
  }
}

float fdotp_v32b_global_p2_u1() {
  // Reduce and return
  float red;
  asm volatile("vfredusum.vs v0, v24, v0");
  asm volatile("vfmv.f.s %0, v0" : "=f"(red));
  return red;
}

float fdotp_v32b_global_p2_u2() {
  // Reduce and return
  float red;
  float blue;
  asm volatile("vfredusum.vs v24, v8, v24");
  asm volatile("vfredusum.vs v28, v20, v28");
  asm volatile("vfmv.f.s %0, v24" : "=f"(red));
  asm volatile("vfmv.f.s %0, v28" : "=f"(blue));
  return (red + blue);
}

float fdotp_v32b_global_p2_u4() {
  // Reduce and return
  float red;
  asm volatile("vfmv.s.f v28, %0" ::"f"((float)0.0));
  asm volatile("vfredusum.vs v28, v8, v28");
  asm volatile("vfmv.f.s %0, v28" : "=f"(red));
  return red;
}

float fdotp_v32b_global_p2_u8() {
  // Reduce and return
  float red;
  float blue;
  asm volatile("vfmv.s.f v24, %0" ::"f"((float)0.0));
  asm volatile("vfmv.s.f v28, %0" ::"f"((float)0.0));
  asm volatile("vfredusum.vs v24, v4, v24");
  asm volatile("vfredusum.vs v28, v10, v28");
  asm volatile("vfmv.f.s %0, v24" : "=f"(red));
  asm volatile("vfmv.f.s %0, v28" : "=f"(blue));
  return (red + blue);
}
