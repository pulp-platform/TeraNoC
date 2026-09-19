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

#ifndef QWEN_FMATMUL_H
#define QWEN_FMATMUL_H

// fp16 build: the element type of A/B/C.
//
// _Float16, NOT __fp16. Only _Float16 is a native arithmetic type on this target, so only it
// can be tied to an "f" asm operand for the vfmacc.vf / vfmul.vf scalar broadcast; __fp16 is
// storage-only here and clang rejects it with
//     error: couldn't allocate input reg for constraint 'f'
// The generated data header declares its arrays as __fp16 (same 16-bit layout), so main.c
// casts at the boundary.
typedef _Float16 elem_t;

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

KERNEL_ATTR
void matmul_2xVL(elem_t *c, const elem_t *a, const elem_t *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end,
                 const unsigned int lda, const unsigned int accum);
KERNEL_ATTR
void matmul_4xVL(elem_t *c, const elem_t *a, const elem_t *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end,
                 const unsigned int lda, const unsigned int accum);
KERNEL_ATTR
void matmul_8xVL(elem_t *c, const elem_t *a, const elem_t *b,
                 const unsigned int m_start, const unsigned int m_end,
                 const unsigned int N, const unsigned int P,
                 const unsigned int p_start, const unsigned int p_end,
                 const unsigned int lda, const unsigned int accum);

#endif
