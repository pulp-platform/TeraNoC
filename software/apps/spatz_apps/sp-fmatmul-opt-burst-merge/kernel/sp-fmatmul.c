// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Burst-optimized matrix multiply for TeraNoC + Spatz system
//
// Matrix multiplication: C = A * B
//   - A is MxN matrix
//   - B is NxP matrix  
//   - C is MxP matrix (result)
//
// This kernel is optimized for:
//   - 16-word aligned vector loads (burst mode)
//   - Maximum memory latency hiding through software pipelining
//   - Minimal register usage (matches sp-fmatmul-opt pattern)
//
// The key optimization is "Load-Next-First" pattern:
//   While computing C += A[k] * B[k], we prefetch B[k+1] so it's ready
//   for the next iteration. This hides memory latency.
//
//==========================================================
// MEMORY ACCESS PATTERN
//==========================================================
// Matrix B is accessed in column-major order (unit stride in inner loop):
//   for k = 0 to N-1:
//     // Load B[k*P : k*P+16] (16-word burst)
//     // Multiply each row of A by this column of B
//
// Matrix A is accessed sequentially:
//   for each row m: A[m*N + k] is accessed in order
//
//==========================================================
// REGISTER USAGE (2xVL example)
//==========================================================
// Vector registers (RISC-V Vector extension):
//   v0, v4  : accumulator for C rows (2 rows * 1 vector each)
//   v16      : holds B[k] vector (current column)
//   v24      : holds B[k+1] vector (prefetch for next)
//
// Scalar registers (FPR):
//   t0, t1    : A matrix elements for current k (2 rows)
//   a0, a1    : pointers to current row of A
//
//==========================================================
// LOOP STRUCTURE
//==========================================================
// Outer loop: p = 0 to P-1 (process 16-word columns of B at a time)
//   Middle loop: m = 0 to M-1 (process rows of C)
//     Inner loop: k = 0 to N-1 (compute dot product)
//
// The 16-word aligned blocks use the optimized version (_pf suffix)
// while misaligned head/tail use the baseline version.
//==========================================================

#include "sp-fmatmul.h"

#define MIN(a, b) ((a) < (b) ? (a) : (b))

//==========================================================
// 2xVL: Process 2 output rows per iteration
// Vector length = 2 rows of C computed in parallel
//==========================================================

//----------------------------------------------------------------------
// Baseline version: simple nested loops (no optimization)
// Used for head/tail sections where data is not 16-word aligned
//----------------------------------------------------------------------
static inline void matmul_2xVL_chunk_base(float *c, const float *a, const float *b,
                                           const unsigned int m_start,
                                           const unsigned int m_end,
                                           const unsigned int N,
                                           const unsigned int P,
                                           const unsigned int p,
                                           const unsigned int gvl) {
  // Set vector length (e32 = 32-bit elements, m1 = 1 vector register per group)
  size_t vl;
  asm volatile("vsetvli %[vl], %[gvl], e32, m1, ta, ma"
               : [vl] "=r"(vl)
               : [gvl] "r"(gvl));

  // Pointers: b_col starts at column p, c_col starts at column p
  const float *b_col = b + p;
  float *c_col = c + p;

  // Loop over rows of C (2 rows at a time)
  for (unsigned int m = m_start; m < m_end; m += 2) {
    // a0 points to row m, a1 points to row m+1
    const float *a0 = a + (m + 0) * N;
    const float *a1 = a + (m + 1) * N;
    // c0, c1 point to output rows
    float *c0 = c_col + (m + 0) * P;
    float *c1 = c_col + (m + 1) * P;

    // Initialize accumulators to zero
    asm volatile("vmv.v.i v0, 0");  // C[0] = 0
    asm volatile("vmv.v.i v4, 0");  // C[1] = 0

    // Inner loop: compute dot product
    for (unsigned int k = 0; k < N; ++k) {
      // Load column k of B (16-word vector)
      const float *b_k = b_col + k * P;
      // Load A elements for this k
      float t0 = a0[k];  // A[m+0, k]
      float t1 = a1[k];  // A[m+1, k]
      // Vector load of B[k]
      asm volatile("vle32.v v16, (%0)" :: "r"(b_k) : "memory");
      // Multiply-accumulate: C += A * B
      asm volatile("vfmacc.vf v0, %0, v16" :: "f"(t0));  // C[0] += A[0,k] * B[k]
      asm volatile("vfmacc.vf v4, %0, v16" :: "f"(t1));  // C[1] += A[1,k] * B[k]
    }

    // Store result
    asm volatile("vse32.v v0, (%0)" :: "r"(c0) : "memory");
    asm volatile("vse32.v v4, (%0)" :: "r"(c1) : "memory");
  }
}

//----------------------------------------------------------------------
// Optimized version: Load-Next-First pattern (matches sp-fmatmul-opt)
// This version prefetches B[k+1] to hide memory latency
//----------------------------------------------------------------------
static inline void matmul_2xVL_chunk_pf(float *c, const float *a, const float *b,
                                         const unsigned int m_start,
                                         const unsigned int m_end,
                                         const unsigned int N,
                                         const unsigned int P,
                                         const unsigned int p,
                                         const unsigned int gvl) {
  size_t vl;
  asm volatile("vsetvli %[vl], %[gvl], e32, m1, ta, ma"
               : [vl] "=r"(vl)
               : [gvl] "r"(gvl));

  const float *b_col = b + p;
  float *c_col = c + p;

  for (unsigned int m = m_start; m < m_end; m += 2) {
    const float *a0 = a + (m + 0) * N;
    const float *a1 = a + (m + 1) * N;
    float *c0 = c_col + (m + 0) * P;
    float *c1 = c_col + (m + 1) * P;

    // Initialize accumulators
    asm volatile("vmv.v.i v0, 0");
    asm volatile("vmv.v.i v4, 0");

    //------------------------------------------------------------------
    // INITIALIZATION
    // Load first column of B (k=0) into v16
    //------------------------------------------------------------------
    const float *b_k = b_col + 0 * P;
    asm volatile("vle32.v v16, (%0)" :: "r"(b_k) : "memory");
    // b_next points to B[k+1] - will be prefetched in first iteration
    const float *b_next = b_col + P;

    // Load initial A values (for k=0)
    float t0 = a0[0];  // A[m+0, 0]
    float t1 = a1[0];  // A[m+1, 0]

    unsigned int n = 0;

    //------------------------------------------------------------------
    // MAIN LOOP - Load-Next-First pattern (matches sp-fmatmul-opt exactly)
    //
    // The key insight: After computing with current B, load the NEXT A values
    // IMMEDIATELY, before rotating to load the next B. This overlaps the A load
    // with the compute of the next iteration.
    //
    // Sequence per iteration (matches sp-fmatmul-opt):
    //   1. Load B[n] into v24 (prefetch for next compute)
    //   2. Increment n, point to next A
    //   3. Compute with current B (v16), then load NEXT A values immediately
    //   4. Increment n, check if done
    //   5. If not done: Load B[n] into v16 (rotate)
    //   6. Compute with B_next (v24), then load NEXT A values immediately
    //------------------------------------------------------------------
    while (n < N) {
      // STEP 1: Load B[n+1] (prefetch) into v24
      asm volatile("vle32.v v24, (%0)" :: "r"(b_next) : "memory");
      b_next += P;

      // STEP 2: Increment n, point to next A element
      n++;
      a0 += N;
      a1 += N;

      // STEP 3: Compute with current B (v16), then load NEXT A values
      // This is the key: A load happens while v16 result is being consumed
      if (n == 1) {
        asm volatile("vfmul.vf v0, v16, %0" :: "f"(t0));
        t0 = *a0;  // Load next A immediately after compute
        a0 += N;
        asm volatile("vfmul.vf v4, v16, %0" :: "f"(t1));
        t1 = *a1;  // Load next A immediately after compute
        a1 += N;
      } else {
        asm volatile("vfmacc.vf v0, %0, v16" :: "f"(t0));
        t0 = *a0;  // Load next A immediately after compute
        a0 += N;
        asm volatile("vfmacc.vf v4, %0, v16" :: "f"(t1));
        t1 = *a1;  // Load next A immediately after compute
        a1 += N;
      }

      // STEP 4: Increment n, check if done
      n++;
      if (n == N) break;  // Exit if we've processed all columns

      // STEP 5: Rotate - Load B[n] into v16 for next iteration
      asm volatile("vle32.v v16, (%0)" :: "r"(b_next) : "memory");
      b_next += P;

      // STEP 6: Compute with B_next (v24), then load NEXT A values
      // A load happens while v24 result is being consumed
      asm volatile("vfmacc.vf v0, %0, v24" :: "f"(t0));
      t0 = *a0;  // Load next A immediately after compute
      a0 += N;
      asm volatile("vfmacc.vf v4, %0, v24" :: "f"(t1));
      t1 = *a1;  // Load next A immediately after compute
      a1 += N;
    }

    // Extra compute after loop (matches sp-fmatmul-opt exactly)
    asm volatile("vfmacc.vf v0, %0, v24" :: "f"(t0));
    asm volatile("vse32.v v0, (%0)" :: "r"(c0) : "memory");
    c0 += P;
    asm volatile("vfmacc.vf v4, %0, v24" :: "f"(t1));
    asm volatile("vse32.v v4, (%0)" :: "r"(c1) : "memory");
  }
}

//==========================================================
// 4xVL: Process 4 output rows per iteration
// Same pattern as 2xVL but with 4 rows
//==========================================================

static inline void matmul_4xVL_chunk_base(float *c, const float *a, const float *b,
                                           const unsigned int m_start,
                                           const unsigned int m_end,
                                           const unsigned int N,
                                           const unsigned int P,
                                           const unsigned int p,
                                           const unsigned int gvl) {
  size_t vl;
  asm volatile("vsetvli %[vl], %[gvl], e32, m1, ta, ma"
               : [vl] "=r"(vl)
               : [gvl] "r"(gvl));

  const float *b_col = b + p;
  float *c_col = c + p;

  for (unsigned int m = m_start; m < m_end; m += 4) {
    const float *a0 = a + (m + 0) * N;
    const float *a1 = a + (m + 1) * N;
    const float *a2 = a + (m + 2) * N;
    const float *a3 = a + (m + 3) * N;
    float *c0 = c_col + (m + 0) * P;
    float *c1 = c_col + (m + 1) * P;
    float *c2 = c_col + (m + 2) * P;
    float *c3 = c_col + (m + 3) * P;

    asm volatile("vmv.v.i v0, 0");
    asm volatile("vmv.v.i v4, 0");
    asm volatile("vmv.v.i v8, 0");
    asm volatile("vmv.v.i v12, 0");

    for (unsigned int k = 0; k < N; ++k) {
      const float *b_k = b_col + k * P;
      float t0 = a0[k], t1 = a1[k], t2 = a2[k], t3 = a3[k];
      asm volatile("vle32.v v16, (%0)" :: "r"(b_k) : "memory");
      asm volatile("vfmacc.vf v0, %0, v16" :: "f"(t0));
      asm volatile("vfmacc.vf v4, %0, v16" :: "f"(t1));
      asm volatile("vfmacc.vf v8, %0, v16" :: "f"(t2));
      asm volatile("vfmacc.vf v12, %0, v16" :: "f"(t3));
    }

    asm volatile("vse32.v v0, (%0)" :: "r"(c0) : "memory");
    asm volatile("vse32.v v4, (%0)" :: "r"(c1) : "memory");
    asm volatile("vse32.v v8, (%0)" :: "r"(c2) : "memory");
    asm volatile("vse32.v v12, (%0)" :: "r"(c3) : "memory");
  }
}

static inline void matmul_4xVL_chunk_pf(float *c, const float *a, const float *b,
                                         const unsigned int m_start,
                                         const unsigned int m_end,
                                         const unsigned int N,
                                         const unsigned int P,
                                         const unsigned int p,
                                         const unsigned int gvl) {
  size_t vl;
  asm volatile("vsetvli %[vl], %[gvl], e32, m1, ta, ma"
               : [vl] "=r"(vl)
               : [gvl] "r"(gvl));

  const float *b_col = b + p;
  float *c_col = c + p;

  for (unsigned int m = m_start; m < m_end; m += 4) {
    const float *a0 = a + (m + 0) * N;
    const float *a1 = a + (m + 1) * N;
    const float *a2 = a + (m + 2) * N;
    const float *a3 = a + (m + 3) * N;
    float *c0 = c_col + (m + 0) * P;
    float *c1 = c_col + (m + 1) * P;
    float *c2 = c_col + (m + 2) * P;
    float *c3 = c_col + (m + 3) * P;

    asm volatile("vmv.v.i v0, 0");
    asm volatile("vmv.v.i v4, 0");
    asm volatile("vmv.v.i v8, 0");
    asm volatile("vmv.v.i v12, 0");

    // Initial: load B[0] into v16
    const float *b_k = b_col + 0 * P;
    asm volatile("vle32.v v16, (%0)" :: "r"(b_k) : "memory");
    const float *b_next = b_col + P;

    // Initial: load A[0], A[1], A[2], A[3]
    float t0 = a0[0], t1 = a1[0], t2 = a2[0], t3 = a3[0];

    unsigned int n = 0;

    // Same Load-Next-First pattern as 2xVL
    while (n < N) {
      // STEP 1: Load B[n+1] (prefetch)
      asm volatile("vle32.v v20, (%0)" :: "r"(b_next) : "memory");
      b_next += P;

      // STEP 2: Increment n, point to next A
      n++;
      a0 += N; a1 += N; a2 += N; a3 += N;

      // STEP 3: Compute with current B (v16), then load NEXT A immediately
      if (n == 1) {
        asm volatile("vfmul.vf v0, v16, %0" :: "f"(t0));
        t0 = *a0; a0 += N;
        asm volatile("vfmul.vf v4, v16, %0" :: "f"(t1));
        t1 = *a1; a1 += N;
        asm volatile("vfmul.vf v8, v16, %0" :: "f"(t2));
        t2 = *a2; a2 += N;
        asm volatile("vfmul.vf v12, v16, %0" :: "f"(t3));
        t3 = *a3; a3 += N;
      } else {
        asm volatile("vfmacc.vf v0, %0, v16" :: "f"(t0));
        t0 = *a0; a0 += N;
        asm volatile("vfmacc.vf v4, %0, v16" :: "f"(t1));
        t1 = *a1; a1 += N;
        asm volatile("vfmacc.vf v8, %0, v16" :: "f"(t2));
        t2 = *a2; a2 += N;
        asm volatile("vfmacc.vf v12, %0, v16" :: "f"(t3));
        t3 = *a3; a3 += N;
      }

      // STEP 4: Increment n, check if done
      n++;
      if (n == N) break;

      // STEP 5: Rotate - load B[n] into v16
      asm volatile("vle32.v v16, (%0)" :: "r"(b_next) : "memory");
      b_next += P;

      // STEP 6: Compute with B_next (v20), then load NEXT A immediately
      asm volatile("vfmacc.vf v0, %0, v20" :: "f"(t0));
      t0 = *a0; a0 += N;
      asm volatile("vfmacc.vf v4, %0, v20" :: "f"(t1));
      t1 = *a1; a1 += N;
      asm volatile("vfmacc.vf v8, %0, v20" :: "f"(t2));
      t2 = *a2; a2 += N;
      asm volatile("vfmacc.vf v12, %0, v20" :: "f"(t3));
      t3 = *a3; a3 += N;
    }

    // Extra compute after loop (matches sp-fmatmul-opt exactly)
    asm volatile("vfmacc.vf v0, %0, v20" :: "f"(t0));
    asm volatile("vse32.v v0, (%0)" :: "r"(c0) : "memory");
    c0 += P;
    asm volatile("vfmacc.vf v4, %0, v20" :: "f"(t1));
    asm volatile("vse32.v v4, (%0)" :: "r"(c1) : "memory");
    c1 += P;
    asm volatile("vfmacc.vf v8, %0, v20" :: "f"(t2));
    asm volatile("vse32.v v8, (%0)" :: "r"(c2) : "memory");
    c2 += P;
    asm volatile("vfmacc.vf v12, %0, v20" :: "f"(t3));
    asm volatile("vse32.v v12, (%0)" :: "r"(c3) : "memory");
  }
}

//==========================================================
// 8xVL: Process 8 output rows per iteration
// Same pattern as 2xVL but with 8 rows
//==========================================================

static inline void matmul_8xVL_chunk_base(float *c, const float *a, const float *b,
                                           const unsigned int m_start,
                                           const unsigned int m_end,
                                           const unsigned int N,
                                           const unsigned int P,
                                           const unsigned int p,
                                           const unsigned int gvl) {
  size_t vl;
  asm volatile("vsetvli %[vl], %[gvl], e32, m1, ta, ma"
               : [vl] "=r"(vl)
               : [gvl] "r"(gvl));

  const float *b_col = b + p;
  float *c_col = c + p;

  for (unsigned int m = m_start; m < m_end; m += 8) {
    const float *a0 = a + (m + 0) * N;
    const float *a1 = a + (m + 1) * N;
    const float *a2 = a + (m + 2) * N;
    const float *a3 = a + (m + 3) * N;
    const float *a4 = a + (m + 4) * N;
    const float *a5 = a + (m + 5) * N;
    const float *a6 = a + (m + 6) * N;
    const float *a7 = a + (m + 7) * N;
    float *c0 = c_col + (m + 0) * P;
    float *c1 = c_col + (m + 1) * P;
    float *c2 = c_col + (m + 2) * P;
    float *c3 = c_col + (m + 3) * P;
    float *c4 = c_col + (m + 4) * P;
    float *c5 = c_col + (m + 5) * P;
    float *c6 = c_col + (m + 6) * P;
    float *c7 = c_col + (m + 7) * P;

    asm volatile("vmv.v.i v0, 0");
    asm volatile("vmv.v.i v4, 0");
    asm volatile("vmv.v.i v8, 0");
    asm volatile("vmv.v.i v12, 0");
    asm volatile("vmv.v.i v16, 0");
    asm volatile("vmv.v.i v20, 0");
    asm volatile("vmv.v.i v24, 0");
    asm volatile("vmv.v.i v28, 0");

    for (unsigned int k = 0; k < N; ++k) {
      const float *b_k = b_col + k * P;
      float t0 = a0[k], t1 = a1[k], t2 = a2[k], t3 = a3[k];
      float t4 = a4[k], t5 = a5[k], t6 = a6[k], t7 = a7[k];
      asm volatile("vle32.v v31, (%0)" :: "r"(b_k) : "memory");
      asm volatile("vfmacc.vf v0, %0, v31" :: "f"(t0));
      asm volatile("vfmacc.vf v4, %0, v31" :: "f"(t1));
      asm volatile("vfmacc.vf v8, %0, v31" :: "f"(t2));
      asm volatile("vfmacc.vf v12, %0, v31" :: "f"(t3));
      asm volatile("vfmacc.vf v16, %0, v31" :: "f"(t4));
      asm volatile("vfmacc.vf v20, %0, v31" :: "f"(t5));
      asm volatile("vfmacc.vf v24, %0, v31" :: "f"(t6));
      asm volatile("vfmacc.vf v28, %0, v31" :: "f"(t7));
    }

    asm volatile("vse32.v v0, (%0)" :: "r"(c0) : "memory");
    asm volatile("vse32.v v4, (%0)" :: "r"(c1) : "memory");
    asm volatile("vse32.v v8, (%0)" :: "r"(c2) : "memory");
    asm volatile("vse32.v v12, (%0)" :: "r"(c3) : "memory");
    asm volatile("vse32.v v16, (%0)" :: "r"(c4) : "memory");
    asm volatile("vse32.v v20, (%0)" :: "r"(c5) : "memory");
    asm volatile("vse32.v v24, (%0)" :: "r"(c6) : "memory");
    asm volatile("vse32.v v28, (%0)" :: "r"(c7) : "memory");
  }
}

// 8xVL optimized version - matches sp-fmatmul-opt exactly
static inline void matmul_8xVL_chunk_pf(float *c, const float *a, const float *b,
                                         const unsigned int m_start,
                                         const unsigned int m_end,
                                         const unsigned int N,
                                         const unsigned int P,
                                         const unsigned int p,
                                         const unsigned int gvl) {
  size_t vl;
  asm volatile("vsetvli %[vl], %[gvl], e32, m1, ta, ma"
               : [vl] "=r"(vl)
               : [gvl] "r"(gvl));

  const float *b_col = b + p;
  float *c_col = c + p;

  for (unsigned int m = m_start; m < m_end; m += 8) {
    const float *a0 = a + (m + 0) * N;
    const float *a1 = a + (m + 1) * N;
    const float *a2 = a + (m + 2) * N;
    const float *a3 = a + (m + 3) * N;
    const float *a4 = a + (m + 4) * N;
    const float *a5 = a + (m + 5) * N;
    const float *a6 = a + (m + 6) * N;
    const float *a7 = a + (m + 7) * N;
    float *c0 = c_col + (m + 0) * P;
    float *c1 = c_col + (m + 1) * P;
    float *c2 = c_col + (m + 2) * P;
    float *c3 = c_col + (m + 3) * P;
    float *c4 = c_col + (m + 4) * P;
    float *c5 = c_col + (m + 5) * P;
    float *c6 = c_col + (m + 6) * P;
    float *c7 = c_col + (m + 7) * P;

    // Initialize accumulators (matches sp-fmatmul-opt: v0,v2,v4,v6,v8,v10,v12,v14)
    asm volatile("vmv.v.i v0, 0");
    asm volatile("vmv.v.i v2, 0");
    asm volatile("vmv.v.i v4, 0");
    asm volatile("vmv.v.i v6, 0");
    asm volatile("vmv.v.i v8, 0");
    asm volatile("vmv.v.i v10, 0");
    asm volatile("vmv.v.i v12, 0");
    asm volatile("vmv.v.i v14, 0");

    // Initial: load B[0] into v18 (matches sp-fmatmul-opt)
    const float *b_k = b_col + 0 * P;
    asm volatile("vle32.v v18, (%0)" :: "r"(b_k) : "memory");
    const float *b_next = b_col + P;

    // Initial: load A[0], A[1]
    float t0 = a0[0], t1 = a1[0], t2 = a2[0], t3 = a3[0];
    float t4 = a4[0], t5 = a5[0], t6 = a6[0], t7 = a7[0];

    unsigned int n = 0;

    // Same Load-Next-First pattern as 2xVL
    while (n < N) {
      // STEP 1: Load B[n+1]
      asm volatile("vle32.v v22, (%0)" :: "r"(b_next) : "memory");
      b_next += P;

      // STEP 2: Increment n, point to next A
      n++;
      a0 += N; a1 += N; a2 += N; a3 += N;
      a4 += N; a5 += N; a6 += N; a7 += N;

      // STEP 3: Compute with current B (v18), then load NEXT A immediately
      if (n == 1) {
        asm volatile("vfmul.vf v0, v18, %0" :: "f"(t0));
        t0 = *a0; a0 += N;
        asm volatile("vfmul.vf v2, v18, %0" :: "f"(t1));
        t1 = *a1; a1 += N;
        asm volatile("vfmul.vf v4, v18, %0" :: "f"(t2));
        t2 = *a2; a2 += N;
        asm volatile("vfmul.vf v6, v18, %0" :: "f"(t3));
        t3 = *a3; a3 += N;
        asm volatile("vfmul.vf v8, v18, %0" :: "f"(t4));
        t4 = *a4; a4 += N;
        asm volatile("vfmul.vf v10, v18, %0" :: "f"(t5));
        t5 = *a5; a5 += N;
        asm volatile("vfmul.vf v12, v18, %0" :: "f"(t6));
        t6 = *a6; a6 += N;
        asm volatile("vfmul.vf v14, v18, %0" :: "f"(t7));
        t7 = *a7; a7 += N;
      } else {
        asm volatile("vfmacc.vf v0, %0, v18" :: "f"(t0));
        t0 = *a0; a0 += N;
        asm volatile("vfmacc.vf v2, %0, v18" :: "f"(t1));
        t1 = *a1; a1 += N;
        asm volatile("vfmacc.vf v4, %0, v18" :: "f"(t2));
        t2 = *a2; a2 += N;
        asm volatile("vfmacc.vf v6, %0, v18" :: "f"(t3));
        t3 = *a3; a3 += N;
        asm volatile("vfmacc.vf v8, %0, v18" :: "f"(t4));
        t4 = *a4; a4 += N;
        asm volatile("vfmacc.vf v10, %0, v18" :: "f"(t5));
        t5 = *a5; a5 += N;
        asm volatile("vfmacc.vf v12, %0, v18" :: "f"(t6));
        t6 = *a6; a6 += N;
        asm volatile("vfmacc.vf v14, %0, v18" :: "f"(t7));
        t7 = *a7; a7 += N;
      }

      // STEP 4: Increment n, check if done
      n++;
      if (n == N) break;

      // STEP 5: Rotate - load B[n] into v18
      asm volatile("vle32.v v18, (%0)" :: "r"(b_next) : "memory");
      b_next += P;

      // STEP 6: Compute with B_next (v22), then load NEXT A immediately
      asm volatile("vfmacc.vf v0, %0, v22" :: "f"(t0));
      t0 = *a0; a0 += N;
      asm volatile("vfmacc.vf v2, %0, v22" :: "f"(t1));
      t1 = *a1; a1 += N;
      asm volatile("vfmacc.vf v4, %0, v22" :: "f"(t2));
      t2 = *a2; a2 += N;
      asm volatile("vfmacc.vf v6, %0, v22" :: "f"(t3));
      t3 = *a3; a3 += N;
      asm volatile("vfmacc.vf v8, %0, v22" :: "f"(t4));
      t4 = *a4; a4 += N;
      asm volatile("vfmacc.vf v10, %0, v22" :: "f"(t5));
      t5 = *a5; a5 += N;
      asm volatile("vfmacc.vf v12, %0, v22" :: "f"(t6));
      t6 = *a6; a6 += N;
      asm volatile("vfmacc.vf v14, %0, v22" :: "f"(t7));
      t7 = *a7; a7 += N;
    }

    // Extra compute after loop (matches sp-fmatmul-opt exactly)
    asm volatile("vfmacc.vf v0, %0, v22" :: "f"(t0));
    asm volatile("vse32.v v0, (%0)" :: "r"(c0) : "memory");
    c0 += P;
    asm volatile("vfmacc.vf v2, %0, v22" :: "f"(t1));
    asm volatile("vse32.v v2, (%0)" :: "r"(c1) : "memory");
    c1 += P;
    asm volatile("vfmacc.vf v4, %0, v22" :: "f"(t2));
    asm volatile("vse32.v v4, (%0)" :: "r"(c2) : "memory");
    c2 += P;
    asm volatile("vfmacc.vf v6, %0, v22" :: "f"(t3));
    asm volatile("vse32.v v6, (%0)" :: "r"(c3) : "memory");
    c3 += P;
    asm volatile("vfmacc.vf v8, %0, v22" :: "f"(t4));
    asm volatile("vse32.v v8, (%0)" :: "r"(c4) : "memory");
    c4 += P;
    asm volatile("vfmacc.vf v10, %0, v22" :: "f"(t5));
    asm volatile("vse32.v v10, (%0)" :: "r"(c5) : "memory");
    c5 += P;
    asm volatile("vfmacc.vf v12, %0, v22" :: "f"(t6));
    asm volatile("vse32.v v12, (%0)" :: "r"(c6) : "memory");
    c6 += P;
    asm volatile("vfmacc.vf v14, %0, v22" :: "f"(t7));
    asm volatile("vse32.v v14, (%0)" :: "r"(c7) : "memory");
  }
}

//==========================================================
// Top-level matrix multiply functions
// These functions handle the outer loops and dispatch
// to the appropriate chunk function based on alignment
//==========================================================

// Main entry point: selects 2xVL, 4xVL, or 8xVL based on M dimension
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

// Dispatch function for 2xVL kernel
// Handles head/tail alignment and calls optimized version for 16-word blocks
void matmul_2xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
  unsigned int p = p_start;

  // HEAD: handle non-16-aligned start
  // If p doesn't start on a 16-word boundary, process partial block
  if (p < p_end && (p & 0xF)) {
    unsigned int head = 16 - (p & 0xF);  // bytes to reach 16-alignment
    unsigned int gvl = MIN(head, p_end - p);  // vector length for this block
    matmul_2xVL_chunk_base(c, a, b, m_start, m_end, N, P, p, gvl);
    p += gvl;
  }

  // BODY: 16-word aligned blocks - use optimized version
  // These are the common case where we can use burst loads
  for (; p + 16 <= p_end; p += 16) {
    matmul_2xVL_chunk_pf(c, a, b, m_start, m_end, N, P, p, 16);
  }

  // TAIL: handle remaining elements after last 16-word block
  if (p < p_end) {
    unsigned int gvl = p_end - p;
    matmul_2xVL_chunk_base(c, a, b, m_start, m_end, N, P, p, gvl);
  }
}

// Dispatch function for 4xVL kernel
void matmul_4xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
  unsigned int p = p_start;

  if (p < p_end && (p & 0xF)) {
    unsigned int head = 16 - (p & 0xF);
    unsigned int gvl = MIN(head, p_end - p);
    matmul_4xVL_chunk_base(c, a, b, m_start, m_end, N, P, p, gvl);
    p += gvl;
  }

  for (; p + 16 <= p_end; p += 16) {
    matmul_4xVL_chunk_pf(c, a, b, m_start, m_end, N, P, p, 16);
  }

  if (p < p_end) {
    unsigned int gvl = p_end - p;
    matmul_4xVL_chunk_base(c, a, b, m_start, m_end, N, P, p, gvl);
  }
}

// Dispatch function for 8xVL kernel
void matmul_8xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end) {
  unsigned int p = p_start;

  if (p < p_end && (p & 0xF)) {
    unsigned int head = 16 - (p & 0xF);
    unsigned int gvl = MIN(head, p_end - p);
    matmul_8xVL_chunk_base(c, a, b, m_start, m_end, N, P, p, gvl);
    p += gvl;
  }

  for (; p + 16 <= p_end; p += 16) {
    matmul_8xVL_chunk_pf(c, a, b, m_start, m_end, N, P, p, 16);
  }

  if (p < p_end) {
    unsigned int gvl = p_end - p;
    matmul_8xVL_chunk_base(c, a, b, m_start, m_end, N, P, p, gvl);
  }
}
