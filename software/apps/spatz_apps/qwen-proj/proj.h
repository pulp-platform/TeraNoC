// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-proj: what main.c and the phase translation unit (phase.c = qwen-common/qwen_phase.c)
// share -- the W double buffer and the phase's entry points.
#ifndef PROJ_H
#define PROJ_H

#include <stdint.h>

#include "data/proj_joint.h"  // QL_WREG_ELEMS (qwen-layer/script/gen_joint.c, one phase)
#include "data/proj_knobs.h"
#include "qwen_phase.h"

#define PROJ_WREG_ELEMS QL_WREG_ELEMS  // one W region (elements)

extern _Float16 proj_w_area[2 * PROJ_WREG_ELEMS];

int pj_setup(uint32_t cid, qp_split_t *sp);
void pj_prime(uint32_t cid);                      // tiles 0 and 1 + the MSHR tuning
void pj_run(uint32_t cid, const qp_split_t *sp);  // the projection(s); MSHR left off
void pj_report(uint32_t cid, uint32_t cycles);
void pj_report_min(uint32_t t0, uint32_t cycles);  // proj_report=min: one hex line (core 0)
uint64_t pj_macs(void);
void pj_mshr_off(void);
uint32_t pj_bad(void);  // check builds: wrong outputs found by the epilogue (0 = pass)

#endif
