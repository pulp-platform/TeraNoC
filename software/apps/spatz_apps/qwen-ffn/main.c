// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
//==============================================================================
// Qwen3.8-27B decode FFN, fused: gate+up -> SwiGLU -> down in one timed region.
//==============================================================================
//
//   G = X . Wg, U = X . Wu   X [B][4096]   Wg, Wu [4096][16384]     phase_gu.c
//   H = SiLU(G) * U          fused into gate+up's epilogue, H stays in L1
//   Y = H . Wd               Wd [16384][4096]   Y [B][4096]         phase_dn.c
//
// docs/qwen3_8_27b/ffn_fused_plan.md. Each phase is qwen-common/qwen_phase.c compiled with its
// own shape; this file owns what they share (ffn.h): the W double buffer -- one stream from the first gate tile
// to the last down tile -- and H.
//
// ffn_check=1 checks end to end: X one-hot, Wg = 16 and Wu = 1/16 at down's multi-hot positions,
// so H is exactly down's multi-hot pattern and Y has its known value (script/gen_operands_*.c).
// A perf build computes on L2 nobody wrote (X on RTL), so it prints no data-dependent output.
//
//==============================================================================

#include <stdint.h>

#include "data/ffn_joint.h"
#include "ffn.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#define FFN_SWEEP_B \
  (4u * N_FU * BANKING_FACTOR * NUM_CORES_PER_TILE * NUM_TILES_PER_GROUP * NUM_GROUPS)
#define FFN_L1 __attribute__((section(".l1_prio"), aligned(FFN_SWEEP_B)))

ffn_elem_t ffn_w_area[2 * FFN_WREG_ELEMS] FFN_L1;
ffn_elem_t ffn_h[FFN_H_ELEMS] FFN_L1;

int main(void) {
  const uint32_t cid = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  mempool_barrier_init(cid);
  *(volatile uint32_t *)(cid * SEQ_MEM_SIZE + 4) = 0u;  // this core's log-barrier counter
  mempool_barrier(num_cores);

  // Both splits, X into its replicas, the warm-ups, both MSHR tunings computed; then the first
  // two gate tiles and gate+up's tuning. All outside the region.
  qp_split_t s_gu, s_dn;  // on this core's stack: local, never through the MSHR
  const int e_gu = gu_setup(cid, &s_gu), e_dn = dn_setup(cid, &s_dn);
  if (e_gu || e_dn) {
    if (cid == 0) printf("[FFN] split error: gate+up %d, down %d\n", e_gu, e_dn);
    mempool_barrier(num_cores);
    return -1;
  }
  gu_prime(cid);
  mempool_barrier(num_cores);

  const uint32_t t0 = mempool_get_timer();
  mempool_start_benchmark();
  gu_run(cid, &s_gu);  // ends with the MSHR off and down's tiles 0 (landed) and 1 (in flight)
  const uint32_t t1 = mempool_get_timer();
  dn_mshr_handover(cid);
  gu_barrier(cid);  // down's tuning in force everywhere before any down load
  const uint32_t t2 = mempool_get_timer();
  dn_run(cid, &s_dn);
  mempool_stop_benchmark();
  const uint32_t t3 = mempool_get_timer();

  dn_mshr_off();
  mempool_barrier(num_cores);
  if (cid == 0) {
    const uint64_t macs = gu_macs() + dn_macs();
    const uint64_t ideal = macs / ((uint64_t)num_cores * 2u * N_FPU);
    printf("\n----- qwen ffn (fused) -----\n");
    printf("The execution took %u cycles.\n", (unsigned)(t3 - t0));
    printf("[FFN] gate+up=%u handover=%u down=%u total=%u cycles; ideal=%u eff=%u%%o\n",
           (unsigned)(t1 - t0), (unsigned)(t2 - t1), (unsigned)(t3 - t2), (unsigned)(t3 - t0),
           (unsigned)ideal, (unsigned)(ideal * 1000ull / (t3 - t0)));
  }
  gu_report(cid, t1 - t0);
  dn_report(cid, t3 - t2);
  mempool_barrier(num_cores);
  dn_verify(cid);
  mempool_barrier(num_cores);
  return 0;
}
