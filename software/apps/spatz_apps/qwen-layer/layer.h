// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// qwen-layer: one Qwen3.8 decoder layer (or its mixer block) in one timed region -- what the phase
// wrappers, the mixer (mixer_gdn.c or mixer_attn.c) and main.c share.
// docs/qwen3_8_27b/mixer_plan.md, steps 4-6.
//
// GDN (QL_ATTN=0):
//   x [B][4096] --qz--> q k v z (+ conv1d + SiLU on q k v, epilogue) --mixer--> o' [B][6144]
//   qz: qwen_phase.c, K=4096, P=16384, columns q[0,2048) k[2048,4096) v[4096,10240) z[10240,16384)
//   a, b (the 48+48 gate inputs) are 96 dot products per sequence, done in the mixer.
// Attention (QL_ATTN=1):
//   x --qa--> q gate k v (4096 -> 14336) --mixer--> o' = attn(q, KV cache) * sigmoid(gate)
// Both:
//   --op--> y = x + o' . Wo (6144 -> 4096), into x's replicas; with QL_FFN the FFN follows
//   (gate+up with SwiGLU, down with the residual). Both RMSNorms are folded (D4).
#ifndef QWEN_QL_H
#define QWEN_QL_H

#include <stdint.h>

#include "../qwen-common/qc_attn.h"  // constants
#include "../qwen-common/qc_gdn.h"
#include "../qwen-common/qc_layout.h"
#include "data/ql_knobs.h"  // QL_B, QL_ATTN, QL_S, QL_STREAM, QL_CHECK, QL_FFN (app.mk)
#ifndef QL_RESERVE_ONLY
#include "../qwen-common/qwen_phase.h"
#include "data/ql_joint.h"  // QL_WREG_ELEMS (script/gen_joint.c)
#include "data/ql_a_qz.h"   // QL_X_*: the in-projection's A operand layout (script/gen_a.c)
#include "data/ql_a_op.h"   // QL_O_*: op's A operand layout
#include "data/ql_a_gu.h"   // QL_GX_*: gate+up's A layout (= x's, asserted in phase_gu.c)
#include "data/ql_a_dn.h"   // QL_FH_*: down's A layout (H = SiLU(G) * U)
// The streamed state's (GDN) / KV cache's (attention) tile buffers live in the W double buffer
// (idle during the mixer).
#define QL_STATE_W (QL_STATE_IN_W && QL_STREAM)
#endif
// The in-projection phase's prefix.
#if QL_ATTN
#define QL_IN(x) qa_##x
#else
#define QL_IN(x) qz_##x
#endif

#ifndef QL_RESERVE_ONLY
typedef _Float16 ql_elem_t;
#endif

// ---- model dimensions ----------------------------------------------------------------------
#define QL_H 4096u                       // hidden (x, y)
#define QL_QK (QC_GDN_KH * QC_GDN_D)     // 2048 each for q and k
#define QL_VZ (QC_GDN_VH * QC_GDN_D)     // 6144 each for v and z
#define QL_COL_Q 0u
#define QL_COL_K QL_QK
#define QL_COL_V (2u * QL_QK)
#define QL_COL_Z (2u * QL_QK + QL_VZ)
#define QL_P_QZ (2u * QL_QK + 2u * QL_VZ)  // 16384
#define QL_CONV_CH (2u * QL_QK + QL_VZ)    // 10240 channels through the conv
#define QL_CONV_K 4u                           // conv taps (3 of state + the current input)
#define QL_AB (2u * QC_GDN_VH)                 // 96 gate inputs

#if !QL_ATTN
// ---- mixer ---------------------------------------------------------------------------------
#define QL_NC (QC_GDN_CPS * QL_B)                    // chunks per step
#define QL_T ((QL_NC + NUM_CORES - 1) / NUM_CORES)   // rounds; chunk c on core c % cores
#if QL_STREAM
#define QL_NBUF (QL_T < 3u ? QL_T : 3u)
#else
#define QL_NBUF QL_T
#endif
// aux sweeps per round: the kernel's, then z, the o partial sum of squares (fp32), scratch
#define QL_AUX_Z (QC_GDN_AUX_SW + 0u)
#define QL_AUX_SS (QC_GDN_AUX_SW + 1u)
#define QL_AUX_SW (QC_GDN_AUX_SW + 2u)
// AB slot elements: [0] alpha, [1] beta (the kernel's), [2] a, [3] b (raw, from the ab stage)
#define QL_SCR_SW 2u  // per-core scratch: 64 fp16 in the core's own slots

// The mixer's L1 (gen_reserve.c reports it to the joint tiling chooser).
#define QL_L1_STATE ((uint32_t)QL_NBUF * QC_GDN_TILE_B)
#define QL_L1_AUX ((uint32_t)QL_T * QL_TOK * QL_AUX_SW * QC_SWEEP_B)  // per round and token
#define QL_L1_SCR (QL_SCR_SW * QC_SWEEP_B)
#define QL_L1_CONV ((QL_B * 3u + QL_CONV_K) * QL_CONV_CH * 2u)
#define QL_L1_WAB (QL_AB * QL_H * 2u)
// Without the state tiles: those live in the projections' W double buffer when it is big enough
// (it is idle during the mixer); gen_joint.c decides (QL_STATE_IN_W).
// Resident state (QL_STREAM=0) must survive the projections, so it never shares the W area.
#define QL_L1_STATE_W (QL_STREAM ? QL_L1_STATE : 0u)
#define QL_L1_MIXER                                                                     \
  (QL_L1_AUX + QL_L1_SCR + QL_L1_CONV + QL_L1_WAB + 4u * QC_SWEEP_B +             \
   (QL_STREAM ? 0u : QL_L1_STATE))

#else
// ---- attention mixer (QL_ATTN=1) ------------------------------------------------------------
// A problem is (sequence, token group, KV head): QL_TG of the step's QL_TOK tokens share its cores'
// K/V tiles, the other groups get their own cores. Its S-token history is cut into 32-token
// blocks, split across QL_A_CPP consecutive cores (split-S) when there are fewer problems than
// cores. The step's new tokens are the last QL_TOK positions of the last block (causal among them).
#define QL_A_MAX(a, b) ((a) > (b) ? (a) : (b))
#define QL_A_MIN(a, b) ((a) < (b) ? (a) : (b))
#define QL_A_TGRP (QL_TOK / QL_TG)
#define QL_A_NPRB (QC_ATT_KVH * QL_B * QL_A_TGRP)
#define QL_A_NBP (QL_S / QC_ATT_TB)
#define QL_A_CPP QL_A_MIN(QL_A_MAX(1u, NUM_CORES / QL_A_NPRB), QL_A_NBP)
#define QL_A_PPC QL_A_MAX(1u, QL_A_NPRB / NUM_CORES)
#define QL_A_ACTIVE QL_A_MIN(NUM_CORES, QL_A_NPRB * QL_A_CPP)
#define QL_A_RPP (QL_A_NBP / QL_A_CPP)
#define QL_A_T (QL_A_PPC * QL_A_RPP)
#define QL_P_QA (2u * QC_ATT_KVH * QC_ATT_QPK * QC_ATT_D + 2u * QC_ATT_KVH * QC_ATT_D)  // 14336
#define QL_A_COL_G (QC_ATT_KVH * QC_ATT_QPK * QC_ATT_D)                                 // 6144
#define QL_A_COL_K (2u * QL_A_COL_G)                                                    // 12288
#define QL_A_COL_V (QL_A_COL_K + QC_ATT_KVH * QC_ATT_D)                                // 13312
// Resident sweeps (this core's slots), per problem p of the core (p < QL_A_PPC), token j < QL_TG of
// its group, token t < QL_TOK of the step:
#define QL_A_RES_Q 0u                                         // q: ((p TG + j) 6 + h) 8 + d / 32
#define QL_A_RES_K0 (QL_A_RES_Q + QL_A_PPC * QL_TG * 48u)    // qc_attn.h's own (per token j)
#define QL_A_RES_GATE (QL_A_RES_K0 + QC_ATT_SWT(QL_TG))       // gate: as q
#define QL_A_RES_KNEW (QL_A_RES_GATE + QL_A_PPC * QL_TG * 48u)  // new k: (p TOK + t) 8 + d / 32
#define QL_A_RES_VNEW (QL_A_RES_KNEW + QL_A_PPC * QL_TOK * 8u)  // and v
#define QL_A_RES_ROPE (QL_A_RES_VNEW + QL_A_PPC * QL_TOK * 8u)  // cos, sin of token t: 2 t, 2 t + 1
#define QL_A_RES_MASK (QL_A_RES_ROPE + 2u * QL_TOK)  // token t's causal mask on the last block
// Above 16 part cores a problem spans several groups: the q broadcast and the split-S combine run
// in two levels, within each 16-core sub-problem (one group) and across the sub-problems.
#define QL_A_SUB QL_A_MIN(QL_A_CPP, 16u)  // part cores per sub-problem
#define QL_A_NSUB (QL_A_CPP / QL_A_SUB)   // sub-problems per problem
#define QL_A_NPC (48u * QL_TG)           // combine pieces per problem: (token, head, 32 dims)
#define QL_A_P1 (QL_A_NPC / QL_A_SUB)     // level-1 combine pieces per core
#define QL_A_RES_C1 (QL_A_RES_MASK + QL_TOK)  // level-1 merged accumulator pieces
#define QL_A_RES_C1M (QL_A_RES_C1 + (QL_A_NSUB > 1u ? QL_A_P1 : 0u))  // their m, then l (fp32)
#define QL_A_RES_SW (QL_A_RES_C1M + (QL_A_NSUB > 1u ? 2u : 0u))
#define QL_SCR_SW 3u  // + the split-S combine's weights (fp16, at most 32: one slot)

#define QL_L1_STATE (2u * QC_ATT_TILE_B)  // the K and the V tile buffer
#define QL_L1_SCR (QL_SCR_SW * QC_SWEEP_B)
#define QL_L1_STATE_W QL_L1_STATE
#define QL_L1_MIXER (QL_A_RES_SW * QC_SWEEP_B + QL_L1_SCR + 4u * QC_SWEEP_B)
#endif

#ifndef QL_RESERVE_ONLY
// ---- shared buffers (main.c) ----------------------------------------------------------------
extern ql_elem_t ql_w_area[2 * QL_WREG_ELEMS];  // W double buffer of both phases
extern ql_elem_t ql_x[QL_X_ELEMS];              // x: qz's A, op's residual and output
extern ql_elem_t ql_o[QL_O_ELEMS];              // o': op's A, written by the mixer
extern uint8_t ql_scr[QL_L1_SCR];
#if !QL_ATTN
extern uint8_t ql_aux[QL_L1_AUX];
extern ql_elem_t ql_conv_state[QL_B * 3u * QL_CONV_CH];  // [b][tap][channel]
extern ql_elem_t ql_conv_w[QL_CONV_K * QL_CONV_CH];      // [tap][channel]
#else
extern uint8_t ql_res[QL_A_RES_SW * QC_SWEEP_B];  // the attention mixer's resident slots
static inline uint8_t *ql_resp(uint32_t sw, uint32_t cid) {
  return (uint8_t *)qc_slot(ql_res, sw, cid);
}
// Problem p (= b * 4 + g): its first and last part's core and the core's problem index.
static inline uint32_t ql_a_core(uint32_t p, uint32_t part) {
  return QL_A_NPRB <= NUM_CORES ? p * QL_A_CPP + part : p % NUM_CORES;
}
static inline uint32_t ql_a_qp(uint32_t p) { return QL_A_NPRB <= NUM_CORES ? 0u : p / NUM_CORES; }
#endif
#if QL_FFN
extern ql_elem_t ql_fh[QL_FH_ELEMS];  // H: down's A, written by gate+up's epilogue
#endif

// ---- the two RMSNorms (mixer_plan D4: folded) -------------------------------------------------
// gamma is folded into the next projection's W; 1/rms(x_b) scales that projection's output in
// its epilogue. The sums of squares are fp32 (D7): per-core partials [b][core], one reduction per
// norm by B cores, then ql_rinv[norm][b].
extern float ql_rms_part[QL_ROWS * NUM_CORES];
extern float ql_rinv[2][QL_ROWS];
void ql_rms_x_partials(uint32_t cid);              // norm 0: from x (the layer input)
void ql_rms_reduce(uint32_t cid, uint32_t norm);   // core b < B: ql_rinv[norm][b]
float ql_sumsq_seg(const _Float16 *p, uint32_t n, uint32_t cid);  // fp32 sum of p[i]^2

#if !QL_ATTN
// Round t, token j (of the step's QL_TOK): aux sweep sw of core cid.
static inline uint8_t *ql_auxt(uint32_t t, uint32_t j, uint32_t sw, uint32_t cid) {
  return (uint8_t *)qc_slot(ql_aux, (t * QL_TOK + j) * QL_AUX_SW + sw, cid);
}
static inline uint8_t *ql_auxp(uint32_t t, uint32_t sw, uint32_t cid) {
  return ql_auxt(t, 0u, sw, cid);
}
#endif
// x / o' element (b, col) in replica r (row-major rows of LDX inside one replica).
static inline ql_elem_t *ql_x_at(uint32_t r, uint32_t b, uint32_t col) {
  return ql_x + r * (uint32_t)QL_X_STRIDE_E + b * (uint32_t)QL_X_LDX + col;
}
static inline ql_elem_t *ql_o_at(uint32_t r, uint32_t b, uint32_t col) {
  return ql_o + r * (uint32_t)QL_O_STRIDE_E + b * (uint32_t)QL_O_LDX + col;
}
static inline uint32_t ql_x_replica(uint32_t cid) {
  return (cid / NUM_TILES_PER_GROUP) / ((NUM_GROUPS) / (QL_X_REPLICAS));
}

// ---- structural check (QL_CHECK=1): values carry their identity ---------------------------
// The in-projection's epilogue scatters ql_pat(b, col) instead of its values; the mixer writes
// ql_pat(b, QL_PAT_O + k) as o'[b][k]. Integers below 2048: exact in fp16.
static inline uint16_t ql_pat(uint32_t b, uint32_t col) {
  uint32_t v = (b * 7u + col) % 2039u + 1u, e = 25u;
  while (v < 1024u) v <<= 1, --e;
  return (uint16_t)((e << 10) | (v & 0x3ffu));
}
#define QL_PAT_O 16384u  // o'[b][k] carries ql_pat(b, QL_PAT_O + k)
uint32_t ql_check_aux(uint32_t cid);  // after the in-projection: this core's slots hold the pattern
uint32_t ql_check_o(uint32_t cid);    // after the mixer: o' in every replica

// ---- phases (prefixed exports of qwen_phase.c) ------------------------------------------------
#define QL_PHASE_PROTOS(p)                                       \
  int p##setup(uint32_t cid, qp_split_t *sp);                      \
  void p##prime(uint32_t cid);                                     \
  void p##run(uint32_t cid, const qp_split_t *sp);                 \
  void p##refill_head(uint32_t j);                                 \
  uint32_t p##bank_sel(uint32_t g);                                \
  void p##barrier(uint32_t cid);                                   \
  void p##mshr_off(void);                                          \
  uint64_t p##macs(void);                                          \
  void p##report(uint32_t cid, uint32_t cycles);
QL_PHASE_PROTOS(qz_)
QL_PHASE_PROTOS(qa_)
QL_PHASE_PROTOS(op_)
void op_mshr_handover(uint32_t cid);
#if QL_FFN
QL_PHASE_PROTOS(gu_)
QL_PHASE_PROTOS(dn_)
void gu_mshr_handover(uint32_t cid);
void dn_mshr_handover(uint32_t cid);
#endif

// Debug: QL_DBG_EXIT=k ends the simulation (EOC, retval k) when core 0 reaches stage k.
#ifdef QL_DBG_EXIT
#define QL_DBG_STAGE(cid, k)                                                                  \
  do {                                                                                        \
    if ((cid) == 0u && (k) == (QL_DBG_EXIT))                                                  \
      *(volatile uint32_t *)(CONTROL_REGISTER_OFFSET + CONTROL_REGISTERS_EOC_REG_OFFSET) =    \
          ((uint32_t)(k) << 1) | 1u;                                                          \
  } while (0)
#else
#define QL_DBG_STAGE(cid, k) do { (void)(cid); } while (0)
#endif

// ---- mixer (mixer_gdn.c or mixer_attn.c) ----------------------------------------------------
void ql_mixer_setup(uint32_t cid);  // outside the timed region
void ql_mixer_run(uint32_t cid);    // the mixer core, o' into op's A
void ql_mixer_report(uint32_t cid);
void ql_mixer_dma_wait(void);      // the DMA idle (main has no dma.h)
void ql_op_prime(uint32_t cid);     // o-proj tiles 0 (landed) and 1 (in flight), core 0
#endif

#endif
