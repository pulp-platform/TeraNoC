// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Zexin Fu, ETH Zurich
//
//==============================================================================
// Qwen3.8-27B decode: one linear stage (weight projection) on its own.
//==============================================================================
//
//   C[s] = X . W[s]    X [B][K] (L1, replicated)   W[s] [K][P] streamed from L2   C [B][P] (L1)
//
// The linear-stage benchmark (docs/qwen3_8_27b/linear_bench_plan.md): every projection of a
// decoder layer -- FFN gate+up and down, GDN q+k+v+z, attention q+gate+k+v, o-projection -- is
// this app at its shape (app.mk proj_shape). The timed region is the projection alone, as it runs
// inside the layer: its first two K tiles are primed before the region (the previous phase does
// that in the layer), and no epilogue work is timed (phase.c).
//
// proj_steps=<n> streams only the first n K tiles of every (strip, projection): a truncated
// timing run whose per-tile timestamps extrapolate to the full shape (script/proj_extrap.py).
// proj_check=1: exact end-to-end check on preloaded operands (small dims).
// proj_report=min (default without a check): one hex result line right after the region, then
// exit -- the decimal report costs RTL tens of thousands of cycles after the benchmark.
//
//==============================================================================

#include <stdint.h>

#include "proj.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#define PROJ_SWEEP_B \
  (4u * N_FU * BANKING_FACTOR * NUM_CORES_PER_TILE * NUM_TILES_PER_GROUP * NUM_GROUPS)

_Float16 proj_w_area[2 * PROJ_WREG_ELEMS]
    __attribute__((section(".l1_prio"), aligned(PROJ_SWEEP_B)));

int main(void) {
  const uint32_t cid = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  mempool_barrier_init(cid);
  *(volatile uint32_t *)(cid * SEQ_MEM_SIZE + 4) = 0u;  // this core's log-barrier counter
  mempool_barrier(num_cores);

  // Split, X into its replicas, the warm-up, the MSHR tuning; tiles 0 and 1. Outside the region.
  qp_split_t sp;  // on this core's stack: local, never through the MSHR
  const int e = pj_setup(cid, &sp);
  if (e) {
    if (cid == 0) printf("[PROJ] split error %d\n", e);
    mempool_barrier(num_cores);
    return -1;
  }
  pj_prime(cid);
  mempool_barrier(num_cores);

  const uint32_t t0 = mempool_get_timer();
  mempool_start_benchmark();
  pj_run(cid, &sp);
  mempool_stop_benchmark();
  const uint32_t t1 = mempool_get_timer();

#if PROJ_REPORT_MIN
  // perf build for RTL: report and leave -- no MSHR teardown, no decimal formatting
  if (cid == 0) pj_report_min(t0, t1 - t0);
  mempool_barrier(num_cores);
  return 0;
#endif

  pj_mshr_off();
  mempool_barrier(num_cores);
  int ret = 0;
  if (cid == 0) {
    printf("[PROJ] built for %s\n", PROJ_BUILT_FOR);
    const uint64_t ideal = pj_macs() / ((uint64_t)num_cores * 2u * N_FPU);
    printf("\n----- qwen proj -----\n");
    printf("The execution took %u cycles.\n", (unsigned)(t1 - t0));
    // steps_run=0: every K tile; else a truncated timing run (eff is then meaningless).
    printf("[PROJ] shape=%s B=%u K=%u P=%u stages=%u steps_run=%u t0=%u cycles=%u ideal=%u "
           "eff=%u%%o check=%u\n",
           PROJ_SHAPE, (unsigned)PROJ_B, (unsigned)PROJ_K, (unsigned)PROJ_P,
           (unsigned)PROJ_STAGES, (unsigned)PROJ_STEPS_KNOB, (unsigned)t0,
           (unsigned)(t1 - t0), (unsigned)ideal, (unsigned)(ideal * 1000ull / (t1 - t0)),
           (unsigned)PROJ_CHECK);
#if PROJ_CHECK
    if (!pj_bad()) printf("success!\n");
    else ret = -1;
#endif
  }
  pj_report(cid, t1 - t0);
  mempool_barrier(num_cores);
  return ret;
}
