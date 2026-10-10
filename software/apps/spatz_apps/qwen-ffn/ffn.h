// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-ffn: what the two phase translation units (qwen-common/qwen_phase.c compiled as phase_gu.c
// and phase_dn.c) and main.c share -- the L1 buffers that cross the phase boundary and each phase's entry points.
#ifndef FFN_H
#define FFN_H

#include <stdint.h>

#include "data/ffn_joint.h"   // FFN_WREG_ELEMS
#include "data/ffn_shared.h"  // FFN_H_*

typedef _Float16 ffn_elem_t;

// The W double buffer of BOTH phases: two regions of the larger slot. The stream hands it from
// gate+up to down without a gap: gate+up's last two refills launch down's first two tiles.
extern ffn_elem_t ffn_w_area[2 * FFN_WREG_ELEMS];
// H = SiLU(G) * U, written by the gate+up epilogue, read by down as its A operand.
extern ffn_elem_t ffn_h[FFN_H_ELEMS];

// Each phase is qwen-common/qwen_phase.c instantiated with prefix gu_ / dn_; their split type
// (qp_split_t, on each core's stack) and exports:
#include "qwen_phase.h"

int gu_setup(uint32_t cid, qp_split_t *sp);
int dn_setup(uint32_t cid, qp_split_t *sp);
void gu_prime(uint32_t cid);                     // gate+up tiles 0 and 1 + its MSHR tuning
void gu_run(uint32_t cid, const qp_split_t *sp); // gate+up + SwiGLU epilogue; MSHR left off
void dn_mshr_handover(uint32_t cid);             // down's MSHR tuning, enabled
void dn_run(uint32_t cid, const qp_split_t *sp);
void dn_refill_head(uint32_t j);                 // down tile j (0 or 1): the stream's hand-over
uint32_t gu_bank_sel(uint32_t g);                // a group's packed bank-hash triple, per phase
uint32_t dn_bank_sel(uint32_t g);
void gu_report(uint32_t cid, uint32_t cycles);
void dn_report(uint32_t cid, uint32_t cycles);
uint64_t gu_macs(void);
uint64_t dn_macs(void);
int dn_verify(uint32_t cid);                     // check builds: 0 = pass
void gu_barrier(uint32_t cid);                   // global log barrier, vector stores drained
void dn_mshr_off(void);                          // this group's MSHR off
const char *gu_exp_name(void);                   // SwiGLU exponential: "real" or "fake" (timing)

#endif
