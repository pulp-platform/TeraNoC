// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
//==============================================================================
// Qwen3.8-27B Gated DeltaNet mixer block, decode: one timed region.
//==============================================================================
//
//   qz     C = x . Wqkvz (4096 -> 16384); epilogue: conv1d + SiLU on q k v, scatter into the
//          mixer's per-chunk aux slots (phase_qz.c)
//   mixer  a, b dot products; per chunk q/k L2-norm, gates, the delta rule (state streamed from
//          L2 by default); gated RMSNorm into the o-projection's A (mixer_gdn.c)
//   op     y = x + o' . Wo (6144 -> 4096); epilogue: residual into x's replicas (phase_op.c)
//
// docs/qwen3_8_27b/mixer_plan.md, step 4. The RMSNorm before qz is folded (D4: gamma into Wqkvz;
// 1/rms is a per-sequence output scale) and not modelled separately here.
// A perf build computes on L2 nobody wrote (X on RTL) and prints nothing data-dependent.
//
//==============================================================================

#include <stdint.h>

#include "layer.h"
#include "../qwen-common/qc_sync.h"
#include "printf.h"
#include "runtime.h"
#include "control_registers.h"
#include "synchronization.h"

ql_elem_t ql_w_area[2 * QL_WREG_ELEMS] QC_L1_SWEEP;
ql_elem_t ql_x[QL_X_ELEMS] QC_L1_SWEEP;
ql_elem_t ql_o[QL_O_ELEMS] QC_L1_SWEEP;
uint8_t ql_scr[QL_L1_SCR] QC_L1_SWEEP;
#if !QL_ATTN
uint8_t ql_aux[QL_L1_AUX] QC_L1_SWEEP;
ql_elem_t ql_conv_state[QL_B * 3u * QL_CONV_CH] __attribute__((section(".l1_prio"), aligned(64)));
ql_elem_t ql_conv_w[QL_CONV_K * QL_CONV_CH] __attribute__((section(".l1_prio"), aligned(64)));
#else
uint8_t ql_res[QL_A_RES_SW * QC_SWEEP_B] QC_L1_SWEEP;
#endif
#if QL_FFN
ql_elem_t ql_fh[QL_FH_ELEMS] QC_L1_SWEEP;
#endif

#if QL_CHECK
static uint32_t ql_bad_aux[NUM_CORES], ql_bad_o[NUM_CORES];
static uint32_t ql_miss_n, ql_miss[16][4];
// After the block: o' in every replica holds the mixer's identity values.
uint32_t ql_check_o(uint32_t cid) {
  uint32_t bad = 0;
  for (uint32_t i = cid; i < QL_B * QL_O_LDX; i += NUM_CORES) {
    const uint32_t b = i / QL_O_LDX, k = i % QL_O_LDX;
    if (k >= 6144u) continue;  // row pad
    for (uint32_t r = 0; r < (uint32_t)QL_O_REPLICAS; ++r) {
      const uint16_t got = *(uint16_t *)ql_o_at(r, b, k), want = ql_pat(b, QL_PAT_O + k);
      if (got != want) {
        ++bad;
        const uint32_t n = __atomic_fetch_add(&ql_miss_n, 1u, __ATOMIC_RELAXED);
        if (n < 16u) {
          ql_miss[n][0] = b; ql_miss[n][1] = k; ql_miss[n][2] = got; ql_miss[n][3] = want;
        }
      }
    }
  }
  return bad;
}
#endif

int main(void) {
  const uint32_t cid = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  mempool_barrier_init(cid);
  qc_sync_init(cid);
  mempool_barrier(num_cores);

  // ---- setup, outside the timed region ----------------------------------------------------
  qp_split_t s_qz, s_op;  // on this core's stack: local, never through the MSHR
  const int e_qz = QL_IN(setup)(cid, &s_qz), e_op = op_setup(cid, &s_op);
#if QL_FFN
  qp_split_t s_gu, s_dn;
  const int e_ffn = gu_setup(cid, &s_gu) | dn_setup(cid, &s_dn);
#else
  const int e_ffn = 0;
#endif
  if (e_qz || e_op || e_ffn) {
    if (cid == 0) printf("[QL] split error: qkvz %d, o-proj %d, ffn %d\n", e_qz, e_op, e_ffn);
    mempool_barrier(num_cores);
    return -1;
  }
  for (uint32_t i = cid; i < QL_X_ELEMS; i += num_cores) ((uint16_t *)ql_x)[i] = 0x2000u;
  ql_mixer_setup(cid);
  // The pre-mixer RMSNorm's sums of squares: in a stack of layers they come from the previous
  // layer's down epilogue (as the o-proj epilogue does for the pre-FFN norm), so outside the
  // region here -- and before qz_prime turns the MSHR on (one-reader loads would each wait out a
  // hold window).
  ql_rms_x_partials(cid);
  mempool_barrier(num_cores);
  ql_rms_reduce(cid, 0u);
  mempool_barrier(num_cores);
  _Static_assert(QL_TOK == 1u || QL_MIXER_ONLY,
                 "ql_t > 1: whole blocks/layers need the in-projection's per-token scatter (not yet)");
  _Static_assert(QL_TOK == 1u || !QL_CHECK, "ql_check: ql_t = 1 only");
#if QL_MIXER_ONLY
  // ---- the mixer alone: the MSHR stays off, as the in-projection leaves it --------------------
  _Static_assert(!QL_FFN && !QL_CHECK, "ql_mixer_only needs ql_ffn=0 and ql_check=0");
  {
    if (cid == 0) ql_mixer_dma_prime();  // the DMA as the in-projection leaves it (RTL: done = 1)
    mempool_barrier(num_cores);
#if !QL_ATTN && QL_GCHK  // the self-test's first step (untimed); the state carries over
    ql_mixer_run(cid);
    if (cid == 0) ql_mixer_dma_wait();
    mempool_barrier(num_cores);
    ql_gchk_refill(cid);
    mempool_barrier(num_cores);
#endif
    const uint32_t m0 = mempool_get_timer();
    mempool_start_benchmark();
    ql_mixer_run(cid);
    ql_op_prime(cid);  // the o-projection's first tiles, as at the end of a real mixer
    const uint32_t m1 = mempool_get_timer();
    mempool_stop_benchmark();
    if (cid == 0) ql_mixer_dma_wait();
    mempool_barrier(num_cores);
#if !QL_ATTN && QL_GCHK
    ql_gchk_check(cid);
    mempool_barrier(num_cores);
#endif
    if (cid == 0) {
      printf("\n----- qwen %s mixer only (B=%u, T=%u) -----\n", QL_ATTN ? "attention" : "gdn", QL_B,
             QL_TOK);
      printf("The execution took %u cycles.\n", (unsigned)(m1 - m0));
      printf("[QL] B=%u T=%u norm=0 qkvz=0 mixer=%u handover=0 oproj=0 ffn_norm=0 gateup=0 "
             "handover2=0 down=0 total=%u cycles; proj_ideal=0 eff=0%%o exp=%s\n", QL_B, QL_TOK,
             (unsigned)(m1 - m0), (unsigned)(m1 - m0), QC_EXP_FAKE ? "fake" : "real");
    }
    ql_mixer_report(cid);
    mempool_barrier(num_cores);
    return 0;
  }
#endif
  QL_IN(prime)(cid);
  mempool_barrier(num_cores);

  // ---- the block ----------------------------------------------------------------------------
  const uint32_t t0 = mempool_get_timer();
  mempool_start_benchmark();
  const uint32_t t0n = t0;
  QL_IN(run)(cid, &s_qz);  // ends with the MSHR off and op's tiles 0 (landed) and 1 (in flight)
  QL_DBG_STAGE(cid, 30);
  const uint32_t t1 = mempool_get_timer();
#if QL_CHECK
  ql_bad_aux[cid] = ql_check_aux(cid);  // before the mixer rewrites q, k in place
  QL_IN(barrier)(cid);
#endif
  ql_mixer_run(cid);
  ql_op_prime(cid);
  QL_DBG_STAGE(cid, 23);  // only when the state tiles used the W area
  const uint32_t t2 = mempool_get_timer();
  op_mshr_handover(cid);
  QL_IN(barrier)(cid);  // op's tuning in force everywhere before any op load
  const uint32_t t3 = mempool_get_timer();
  QL_DBG_STAGE(cid, 24);
  op_run(cid, &s_op);
  QL_DBG_STAGE(cid, 25);  // with the FFN: ends with gate+up's tiles 0 (landed) and 1 (in flight)
  const uint32_t t4 = mempool_get_timer();
#if QL_FFN
  // The pre-FFN RMSNorm: the o-proj epilogue left fp32 partials of y^2.
  ql_rms_reduce(cid, 1u);
  gu_mshr_handover(cid);
  op_barrier(cid);  // 1/rms and gate+up's tuning in force everywhere
  const uint32_t t5 = mempool_get_timer();
  gu_run(cid, &s_gu);  // ends with the MSHR off and down's tiles 0 (landed) and 1 (in flight)
  const uint32_t t6 = mempool_get_timer();
  dn_mshr_handover(cid);
  gu_barrier(cid);
  const uint32_t t7 = mempool_get_timer();
  dn_run(cid, &s_dn);
  const uint32_t t8 = mempool_get_timer();
#else
  const uint32_t t5 = t4, t6 = t4, t7 = t4, t8 = t4;
#endif
  mempool_stop_benchmark();

#if QL_FFN
  dn_mshr_off();
#else
  op_mshr_off();
#endif
  mempool_barrier(num_cores);
  if (cid == 0) {
    uint64_t macs = QL_IN(macs)() + op_macs();
#if QL_FFN
    macs += gu_macs() + dn_macs();
#endif
    const uint64_t ideal = macs / ((uint64_t)num_cores * 2u * N_FPU);
    printf("\n----- qwen %s %s (B=%u, %s) -----\n", QL_ATTN ? "attention" : "gdn",
           QL_FFN ? "layer" : "mixer block", QL_B, QL_STREAM ? "state streamed" : "state resident");
    printf("The execution took %u cycles.\n", (unsigned)(t8 - t0));
    printf("[QL] B=%u norm=%u qkvz=%u mixer=%u handover=%u oproj=%u ffn_norm=%u gateup=%u "
           "handover2=%u down=%u total=%u cycles; proj_ideal=%u eff=%u%%o exp=%s\n",
           QL_B, (unsigned)(t0n - t0), (unsigned)(t1 - t0n), (unsigned)(t2 - t1),
           (unsigned)(t3 - t2), (unsigned)(t4 - t3), (unsigned)(t5 - t4), (unsigned)(t6 - t5),
           (unsigned)(t7 - t6), (unsigned)(t8 - t7), (unsigned)(t8 - t0), (unsigned)ideal,
           (unsigned)(ideal * 1000ull / (t8 - t0)), QC_EXP_FAKE ? "fake" : "real");
  }
#if QL_CHECK
  // qz scattered identities (aux) and the mixer wrote identities as o' (ql_pat): both landed?
  ql_bad_o[cid] = ql_check_o(cid);
  mempool_barrier(num_cores);
  if (cid == 0) {
    uint32_t ba = 0, bo = 0;
    for (uint32_t k = 0; k < NUM_CORES; ++k) ba += ql_bad_aux[k], bo += ql_bad_o[k];
    printf("[QL] check: %s (aux %u, o' %u mismatches)\n", (ba || bo) ? "FAIL" : "PASS", ba, bo);
    for (uint32_t k = 0; k < ql_miss_n && k < 16u; ++k)
      printf("[QL]   o' b=%u k=%u got 0x%04x want 0x%04x\n", ql_miss[k][0], ql_miss[k][1],
             ql_miss[k][2], ql_miss[k][3]);
  }
#endif
  ql_mixer_report(cid);
  QL_IN(report)(cid, t1 - t0);
  op_report(cid, t4 - t3);
#if QL_FFN
  gu_report(cid, t6 - t5);
  dn_report(cid, t8 - t7);
#endif
  mempool_barrier(num_cores);
  return 0;
}
