// Copyright 2021 ETH Zurich and University of Bologna.
//
// SPDX-License-Identifier: Apache-2.0
//
// This file is a lightly modified copy of sp-fmatmul-opt/kernel/sp-fmatmul.c.
// The only functional change is that we can cap the requested VL (FMATMUL_MAX_VL)
// so a vector load issues fewer 32-bit word loads at a time.

#include "sp-fmatmul.h"

#ifndef FMATMUL_MAX_VL
// Default: Align with the the length of a per-tile TCDM burst (16 words).
#define FMATMUL_MAX_VL 256u
#endif

#define MIN(a, b) ((a) < (b) ? (a) : (b))

void matmul(float *c, const float *a, const float *b, const unsigned int M,
            const unsigned int N, const unsigned int P) {
  if (M <= 4) {
    matmul_2xVL(c, a, b, 0, M, N, P, 0, P);
  } else if (M <= 8) {
    matmul_4xVL(c, a, b, 0, M, N, P, 0, P);
  } else {
    matmul_8xVL(c, a, b, 0, M, N, P, 0, P);
  }
}

// ---------------
// 1xVL
// ---------------
void matmul_1xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
  unsigned int p = p_start;
  while (p < p_end) {
    size_t gvl;
    const unsigned int vl = (unsigned int)MIN((p_end - p), FMATMUL_MAX_VL);
    // Use m2 so VLmax=32 for VLEN=512 and SEW=32 (matches 8xVL behavior).
    asm volatile("vsetvli %[gvl], %[vl], e32, m2, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(vl));

    const float *b_p = b + p;
    float *c_p = c + p;

    for (unsigned int m = m_start; m < m_end; m += 1) {
      const float *a_m = a + m * N;
      float *c_m = c_p + m * P;

      // Accumulate in v0.
      for (unsigned int n = 0; n < N; ++n) {
        const float t = a_m[n];
        const float *b_n = b_p + n * P;
        asm volatile("vle32.v v16, (%0);" ::"r"(b_n));
        if (n == 0) {
          asm volatile("vfmul.vf v0, v16, %0" ::"f"(t));
        } else {
          asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t));
        }
      }

      asm volatile("vse32.v v0, (%0);" ::"r"(c_m));
    }

    p += (unsigned int)gvl;
  }
}

// ---------------
// 2xVL
// ---------------
void matmul_2xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
  unsigned int p = p_start;
  while (p < p_end) {
    size_t gvl;
    const unsigned int vl = (unsigned int)MIN((p_end - p), FMATMUL_MAX_VL);
    asm volatile("vsetvli %[gvl], %[vl], e32, m8, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(vl));

    const float *b_ = b + p;
    float *c_ = c + p;

    for (unsigned int m = m_start; m < m_end; m += 2) {
      const float *a_ = a + m * N;
      const float *a__ = a_;

      asm volatile("vle32.v v16, (%0);" ::"r"(b_));
      const float *b__ = b_ + P;

      float *c__ = c_ + m * P;

      float t0, t1;

      t0 = *a__;
      a__ += N;
      t1 = *a__;

      unsigned int n = 0;

      while (n < N) {
        a__ = a_ + ++n;

        asm volatile("vle32.v v24, (%0);" ::"r"(b__));
        b__ += P;

        if (n == 1) {
          asm volatile("vfmul.vf v0, v16, %0" ::"f"(t0));
          t0 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v8, v16, %0" ::"f"(t1));
          t1 = *a__;
        } else {
          asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
          t0 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
          t1 = *a__;
        }

        a__ = a_ + ++n;

        if (n == N) break;

        asm volatile("vle32.v v16, (%0);" ::"r"(b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
        t0 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
        t1 = *a__;
      }

      asm volatile("vfmacc.vf v0, %0, v24" ::"f"(t0));
      asm volatile("vse32.v v0, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v8, %0, v24" ::"f"(t1));
      asm volatile("vse32.v v8, (%0);" ::"r"(c__));
    }

    p += (unsigned int)gvl;
  }
}

// ---------------
// 4xVL
// ---------------
void matmul_4xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
  unsigned int p = p_start;
  while (p < p_end) {
    size_t gvl;
    const unsigned int vl = (unsigned int)MIN((p_end - p), FMATMUL_MAX_VL);
    asm volatile("vsetvli %[gvl], %[vl], e32, m4, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(vl));

    const float *b_ = b + p;
    float *c_ = c + p;

    for (unsigned int m = m_start; m < m_end; m += 4) {
      const float *a_ = a + m * N;
      const float *a__ = a_;

      asm volatile("vle32.v v16, (%0);" ::"r"(b_));
      const float *b__ = b_ + P;

      float *c__ = c_ + m * P;

      float t0, t1, t2, t3;

      t0 = *a__;
      a__ += N;
      t1 = *a__;
      a__ += N;
      t2 = *a__;
      a__ += N;
      t3 = *a__;

      unsigned int n = 0;

      while (n < N) {
        asm volatile("vle32.v v20, (%0);" ::"r"(b__));
        b__ += P;

        a__ = a_ + ++n;

        if (n == 1) {
          asm volatile("vfmul.vf v0, v16, %0" ::"f"(t0));
          t0 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v4, v16, %0" ::"f"(t1));
          t1 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v8, v16, %0" ::"f"(t2));
          t2 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v12, v16, %0" ::"f"(t3));
          t3 = *a__;
        } else {
          asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
          t0 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v4, %0, v16" ::"f"(t1));
          t1 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t2));
          t2 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v12, %0, v16" ::"f"(t3));
          t3 = *a__;
        }

        a__ = a_ + ++n;

        if (n == N) break;

        asm volatile("vle32.v v16, (%0);" ::"r"(b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t1));
        t1 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t2));
        t2 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t3));
        t3 = *a__;
      }

      asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
      asm volatile("vse32.v v0, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t1));
      asm volatile("vse32.v v4, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t2));
      asm volatile("vse32.v v8, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t3));
      asm volatile("vse32.v v12, (%0);" ::"r"(c__));
    }

    p += (unsigned int)gvl;
  }
}

// ---------------
// 8xVL
// ---------------
void matmul_8xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
  unsigned int p = p_start;
  while (p < p_end) {
    size_t gvl;
    const unsigned int vl = (unsigned int)MIN((p_end - p), FMATMUL_MAX_VL);
    asm volatile("vsetvli %[gvl], %[vl], e32, m2, ta, ma"
                 : [gvl] "=r"(gvl)
                 : [vl] "r"(vl));

    const float *b_ = b + p;
    float *c_ = c + p;

    for (unsigned int m = m_start; m < m_end; m += 8) {
      const float *a_ = a + m * N;
      const float *a__ = a_;

      asm volatile("vle32.v v18, (%0);" ::"r"(b_));
      const float *b__ = b_ + P;

      float *c__ = c_ + m * P;

      float t0, t1, t2, t3, t4, t5, t6, t7;

      t0 = *a__;
      a__ += N;
      t1 = *a__;
      a__ += N;
      t2 = *a__;
      a__ += N;
      t3 = *a__;
      a__ += N;
      t4 = *a__;
      a__ += N;
      t5 = *a__;
      a__ += N;
      t6 = *a__;
      a__ += N;
      t7 = *a__;

      unsigned int n = 0;

      while (n < N) {
        a__ = a_ + ++n;

        asm volatile("vle32.v v20, (%0);" ::"r"(b__));
        b__ += P;

        if (n == 1) {
          asm volatile("vfmul.vf v0, v18, %0" ::"f"(t0));
          t0 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v2, v18, %0" ::"f"(t1));
          t1 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v4, v18, %0" ::"f"(t2));
          t2 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v6, v18, %0" ::"f"(t3));
          t3 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v8, v18, %0" ::"f"(t4));
          t4 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v10, v18, %0" ::"f"(t5));
          t5 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v12, v18, %0" ::"f"(t6));
          t6 = *a__;
          a__ += N;
          asm volatile("vfmul.vf v14, v18, %0" ::"f"(t7));
          t7 = *a__;
        } else {
          asm volatile("vfmacc.vf v0, %0, v18" ::"f"(t0));
          t0 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v2, %0, v18" ::"f"(t1));
          t1 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v4, %0, v18" ::"f"(t2));
          t2 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v6, %0, v18" ::"f"(t3));
          t3 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v8, %0, v18" ::"f"(t4));
          t4 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v10, %0, v18" ::"f"(t5));
          t5 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v12, %0, v18" ::"f"(t6));
          t6 = *a__;
          a__ += N;
          asm volatile("vfmacc.vf v14, %0, v18" ::"f"(t7));
          t7 = *a__;
        }

        a__ = a_ + ++n;
        if (n == N) break;

        asm volatile("vle32.v v18, (%0);" ::"r"(b__));
        b__ += P;

        asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
        t0 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v2, %0, v20" ::"f"(t1));
        t1 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t2));
        t2 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v6, %0, v20" ::"f"(t3));
        t3 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t4));
        t4 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v10, %0, v20" ::"f"(t5));
        t5 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t6));
        t6 = *a__;
        a__ += N;
        asm volatile("vfmacc.vf v14, %0, v20" ::"f"(t7));
        t7 = *a__;
      }

      asm volatile("vfmacc.vf v0, %0, v20" ::"f"(t0));
      asm volatile("vse32.v v0, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v2, %0, v20" ::"f"(t1));
      asm volatile("vse32.v v2, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v4, %0, v20" ::"f"(t2));
      asm volatile("vse32.v v4, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v6, %0, v20" ::"f"(t3));
      asm volatile("vse32.v v6, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v8, %0, v20" ::"f"(t4));
      asm volatile("vse32.v v8, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v10, %0, v20" ::"f"(t5));
      asm volatile("vse32.v v10, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v12, %0, v20" ::"f"(t6));
      asm volatile("vse32.v v12, (%0);" ::"r"(c__));
      c__ += P;
      asm volatile("vfmacc.vf v14, %0, v20" ::"f"(t7));
      asm volatile("vse32.v v14, (%0);" ::"r"(c__));
    }

    p += (unsigned int)gvl;
  }
}
