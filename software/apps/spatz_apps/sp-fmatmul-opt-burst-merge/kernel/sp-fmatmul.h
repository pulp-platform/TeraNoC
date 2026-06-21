// Copyright 2021 ETH Zurich and University of Bologna.
//
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Author: Domenic Wüthrich, ETH Zurich

#ifndef SPFMATMUL_H
#define SPFMATMUL_H

// Code-size / I-cache policy for the matmul_NxVL kernels.
//
// These kernels contain the ENTIRE hot loop (already hand-unrolled by 2) built
// from many inline-asm vector ops. We deliberately keep them OUT-OF-LINE and
// NOT auto-unrolled:
//   - KERNEL_ATTR (noinline[, noclone]): inlining/cloning into the cold
//     dispatcher or main() is pointless — the hot loop lives inside the kernel,
//     not at the call site — and only duplicates a large body, inflating the
//     I-cache footprint (risking I-cache overflow / extra misses).
//   - KERNEL_NO_UNROLL before each hot loop stops the compiler (clang -O3
//     unrolls aggressively) from further unrolling and thus duplicating the
//     asm-heavy loop body.
// noclone is GCC-only; clang has no such attribute (noinline suffices there).
#if defined(__clang__)
#define KERNEL_ATTR      __attribute__((noinline))
#define KERNEL_NO_UNROLL _Pragma("clang loop unroll(disable)")
#elif defined(__GNUC__)
#define KERNEL_ATTR      __attribute__((noinline, noclone))
#define KERNEL_NO_UNROLL _Pragma("GCC unroll 1")
#else
#define KERNEL_ATTR
#define KERNEL_NO_UNROLL
#endif

void matmul(float *c, const float *a, const float *b, const unsigned int M,
            const unsigned int N, const unsigned int P);

inline void matmul_single_unrolled(float *c, const float *a, const float *b,
                                   const unsigned int N, const unsigned int P,
                                   unsigned int vl)
    __attribute__((always_inline));
KERNEL_ATTR
void matmul_2xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end);
KERNEL_ATTR
void matmul_4xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end);
KERNEL_ATTR
void matmul_8xVL(float *c, const float *a, const float *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end);

#endif
