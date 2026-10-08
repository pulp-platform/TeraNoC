// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Types shared by every instantiation of qwen_phase.c (one streamed projection phase) and the
// app code that drives them. See qwen_phase.c for the hook contract.
#ifndef QWEN_PHASE_H
#define QWEN_PHASE_H

#include <stdint.h>

// One core's share of a phase: rows m, columns p of one strip, its K part. Keep it on the
// caller's stack (the core's own memory): a per-core array in L1 is a remote single load with
// one reader, which a live group MSHR holds for its whole hold window (~8k cycles) waiting for
// merge partners -- measured as ~90k cycles at every projection start in qwen-ffn.
typedef struct {
  uint32_t m_start, m_end, p_start, p_end, kpart;
} qp_split_t;

// What a phase's epilogue gets after the last projection of a strip has been reduced: this
// core's finished patch of every projection's C (c[0], c[1], ... for QWEN_STAGES_N projections,
// row stride ldc elements), rows [r0, r1), strip-local columns [c0, c1), and the strip's first
// global output column. Under the K split this is the sub-patch the core's own reduction
// finalised; it may be empty (r0 == r1 or c0 == c1). The epilogue owns its output layout.
typedef struct {
  const _Float16 *c[2];
  uint32_t ldc, r0, r1, c0, c1, col0;
} qp_patch_t;

#endif
