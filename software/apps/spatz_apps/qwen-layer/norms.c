// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer: the two RMSNorms' sums of squares (fp32, mixer_plan D7) and their reduction to
// 1/rms per sequence (layer.h). Shared by both layer types.
#include <stdint.h>

#include "layer.h"
#include "../qwen-common/qc_vec.h"
#include "runtime.h"

static inline uint8_t *ql_scr_at(uint32_t k, uint32_t cid) {
  return (uint8_t *)qc_slot(ql_scr, k, cid);
}

// Element 0 of v24 (e32) through this core's scratch slot: a VLSU store then a scalar load.
static inline float ql_red_out(uint32_t cid) {
  QC_VL1("e32");
  __asm__ volatile("vse32.v v24, (%0)" ::"r"(ql_scr_at(0, cid)) : "memory");
  __asm__ volatile("fence" ::: "memory");
  return *(volatile float *)ql_scr_at(0, cid);
}

// ---- the RMSNorms' sums of squares (fp32) ------------------------------------------------------
float ql_rms_part[QL_ROWS * NUM_CORES] __attribute__((section(".l1_prio"), aligned(64)));
float ql_rinv[2][QL_ROWS];

// fp32 sum of p[i]^2, i < n (n >= 1): the first strip (<= 64) starts the e32 m4 accumulator with
// vfwmul, later strips are no longer, one reduction over the first strip's length.
float ql_sumsq_seg(const _Float16 *p, uint32_t n, uint32_t cid) {
  size_t vl, vl0;
  __asm__ volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(vl0) : "r"(n < 64u ? n : 64u));
  __asm__ volatile("vle16.v v0, (%0)" ::"r"(p) : "memory");
  __asm__ volatile("vfwmul.vv v16, v0, v0");
  for (uint32_t i = (uint32_t)vl0; i < n;) {
    __asm__ volatile("vsetvli %0, %1, e16, m2, tu, ma" : "=r"(vl) : "r"(n - i));
    __asm__ volatile("vle16.v v0, (%0)" ::"r"(p + i) : "memory");
    __asm__ volatile("vfwmacc.vv v16, v0, v0");
    i += (uint32_t)vl;
  }
  QC_VL1("e32");
  __asm__ volatile("vle32.v v24, (%0)" ::"r"(ql_scr_at(1, cid)) : "memory");  // zeros (el. 0)
  __asm__ volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(vl0));
  __asm__ volatile("vfredusum.vs v24, v16, v24");
  return ql_red_out(cid);
}

// Norm 0 (before qz): core cid's columns of every row of x.
void ql_rms_x_partials(uint32_t cid) {
  const uint32_t w = QL_H / NUM_CORES, rep = ql_x_replica(cid);
  for (uint32_t r = 0; r < QL_ROWS; ++r)
    ql_rms_part[r * NUM_CORES + cid] = ql_sumsq_seg(ql_x_at(rep, r, cid * w), w, cid);
}

// Core b < B: 1/rms of row b from the NUM_CORES partials.
void ql_rms_reduce(uint32_t cid, uint32_t norm) {
  if (cid >= QL_ROWS) return;
  const float *p = ql_rms_part + cid * NUM_CORES;
  size_t vl;
  __asm__ volatile("vsetvli %0, %1, e32, m8, ta, ma" : "=r"(vl) : "r"(128u));
  __asm__ volatile("vle32.v v0, (%0)" ::"r"(p) : "memory");
  for (uint32_t i = 128u; i < NUM_CORES; i += 128u) {
    __asm__ volatile("vle32.v v8, (%0)" ::"r"(p + i) : "memory");
    __asm__ volatile("vfadd.vv v0, v0, v8");
  }
  QC_VL1("e32");
  __asm__ volatile("vle32.v v16, (%0)" ::"r"(ql_scr_at(1, cid)) : "memory");  // zeros
  __asm__ volatile("vsetvli %0, %1, e32, m8, ta, ma" : "=r"(vl) : "r"(128u));
  __asm__ volatile("vfredusum.vs v24, v0, v16");
  const float s = ql_red_out(cid);
  ql_rinv[norm][cid] = qc_rsqrt_f32(s * qc_f32_imm(0x39800000u) + qc_f32_imm(0x358637bdu));
}

