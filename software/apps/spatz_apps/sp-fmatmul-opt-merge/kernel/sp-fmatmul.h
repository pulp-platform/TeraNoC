// Copyright 2021 ETH Zurich and University of Bologna.
//
// SPDX-License-Identifier: Apache-2.0
//
// Author: Domenic Wüthrich, ETH Zurich

#ifndef SPFMATMUL_H
#define SPFMATMUL_H

void matmul(float *c, const float *a, const float *b, const unsigned int M,
            const unsigned int N, const unsigned int P);

// 1xVL computes 1 row of C per core (no unrolling in M). This is useful when
// dim_group is small (e.g. 16) and you want to keep all cores busy without
// splitting P across cores.
inline void matmul_1xVL(float *c, const float *a, const float *b,
                        const unsigned int m_start, const unsigned int m_end,
                        const unsigned int N, const unsigned int P,
                        const unsigned int p_start, const unsigned int p_end)
    __attribute__((always_inline));
inline void matmul_2xVL(float *c, const float *a, const float *b,
                        const unsigned int m_start, const unsigned int m_end,
                        const unsigned int N, const unsigned int P,
                        const unsigned int p_start, const unsigned int p_end)
    __attribute__((always_inline));
inline void matmul_4xVL(float *c, const float *a, const float *b,
                        const unsigned int m_start, const unsigned int m_end,
                        const unsigned int N, const unsigned int P,
                        const unsigned int p_start, const unsigned int p_end)
    __attribute__((always_inline));
inline void matmul_8xVL(float *c, const float *a, const float *b,
                        const unsigned int m_start, const unsigned int m_end,
                        const unsigned int N, const unsigned int P,
                        const unsigned int p_start, const unsigned int p_end)
    __attribute__((always_inline));

#endif
