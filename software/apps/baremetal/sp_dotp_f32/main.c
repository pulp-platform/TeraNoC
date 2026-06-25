// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Diyou Shen     <dishen@student.ethz.ch>
//         Matteo Perotti <mperotti@iis.ee.ethz.ch>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "dma.h"
#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#include "data_sp_dotp_f32.h"

#include "baremetal/mempool_sp_dotp_f32.h"
#include "mempool_checks.h"

// Kernel selection.
//   SP_DOTP_PARTITION - how the work is split across cores:
//     SP_DOTP_GLOBAL : every core sweeps an interleaved chunk of the whole
//                      array (round-based), using all cores.
//     SP_DOTP_LOCAL  : every core works only on the data resident in its own
//                      tile (no remote accesses); the active core count is
//                      derived from the problem size.
//   SP_DOTP_UNROLL    - the register-blocked partial-product kernel to use.
// The vector LMUL is fixed by (partition, unroll) from register-file pressure
// (global: u1/u2/u4 -> m4, u8 -> m2; local: m1) and is not set by hand.
#define SP_DOTP_GLOBAL 0
#define SP_DOTP_LOCAL 1

#ifndef SP_DOTP_PARTITION
#define SP_DOTP_PARTITION SP_DOTP_GLOBAL
#endif

#ifndef SP_DOTP_UNROLL
#define SP_DOTP_UNROLL 2
#endif

#if SP_DOTP_PARTITION == SP_DOTP_LOCAL
#if SP_DOTP_UNROLL != 1 && SP_DOTP_UNROLL != 2
#error "local SP_DOTP_PARTITION supports SP_DOTP_UNROLL 1 or 2"
#endif
#define SP_DOTP_LMUL 1
#else
#if SP_DOTP_UNROLL != 1 && SP_DOTP_UNROLL != 2 && SP_DOTP_UNROLL != 4 &&       \
    SP_DOTP_UNROLL != 8
#error "global SP_DOTP_PARTITION supports SP_DOTP_UNROLL 1, 2, 4, or 8"
#endif
#if SP_DOTP_UNROLL == 8
#define SP_DOTP_LMUL 2
#else
#define SP_DOTP_LMUL 4
#endif
#endif

float l1_X[array_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float l1_Y[array_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float l1_result[NUM_CORES + 1]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

// L2 buffer to hold the scalar result for the testbench DPI checker.
float l2_result_check[1]
    __attribute__((aligned(4 * NUM_BANKS), section(".l2")));

int main() {
  const uint32_t core_id = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  const uint32_t dim = array_N;
  uint32_t time_init, time_end;

  mempool_barrier_init(core_id);

#if SP_DOTP_PARTITION == SP_DOTP_LOCAL
  // Derive the active core count from the problem dimension and the per-tile
  // geometry so every active core's slice stays inside its own tile.
  const uint32_t AddrOffset = mempool_get_tile_count() * NUM_BANKS_PER_TILE;
  uint32_t linesize;
  uint32_t active_cores;
  if (dim < AddrOffset) {
    // We cannot use all cores in this case.
    active_cores = (dim / NUM_BANKS_PER_TILE) * NUM_CORES_PER_TILE;
    linesize = dim;
  } else {
    active_cores = num_cores;
    linesize = AddrOffset;
  }
  const uint32_t is_core_active = core_id < active_cores;
  const uint32_t v_len = linesize / active_cores;
  const uint32_t loops = dim / linesize;
#else
  const uint32_t active_cores = num_cores;
  // One vector strip per core per round, sweeping the whole array.
  const uint32_t max_vl = (VLEN / 32) * SP_DOTP_LMUL;
  const uint32_t dim_per_round = max_vl * active_cores;
  const uint32_t round = (dim > dim_per_round) ? dim / dim_per_round : 1;
  const uint32_t dim_core = max_vl;
#endif

  // Copy the inputs into the local L1 scratchpad.
  if (core_id == 0) {
    dma_memcpy_blocking(l1_X, l2_X, dim * sizeof(float));
    dma_memcpy_blocking(l1_Y, l2_Y, dim * sizeof(float));
    for (uint32_t i = 0; i <= active_cores; i++) {
      l1_result[i] = 0;
    }
  }
  mempool_barrier(num_cores);

#if SP_DOTP_PARTITION == SP_DOTP_LOCAL
  float *a_int = l1_X + core_id * v_len;
  float *b_int = l1_Y + core_id * v_len;
#else
  float *a_int = l1_X + dim_core * core_id;
  float *b_int = l1_Y + dim_core * core_id;
#endif
  float *final_store = l1_result + active_cores;
  float acc = 0;

#if SP_DOTP_PARTITION == SP_DOTP_GLOBAL
  // The global kernels expect the SEW/LMUL to be configured once up front; the
  // local kernels re-issue their own vsetvli (m1) internally.
  uint32_t vl;
#if SP_DOTP_LMUL == 2
  asm volatile("vsetvli %0, %1, e32, m2, ta, ma" : "=r"(vl) : "r"(dim_core));
#else
  asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(dim_core));
#endif
#endif

  // PARALLEL, LOCAL ACCESSES
  time_init = mempool_get_timer();
  mempool_start_benchmark();

  // Phase 1: per-core partial dot products.
#if SP_DOTP_PARTITION == SP_DOTP_LOCAL
  if (is_core_active) {
#if SP_DOTP_UNROLL == 1
    fdotp_v32b_local_p1_u1(a_int, b_int, v_len, loops, linesize);
#else
    fdotp_v32b_local_p1_u2(a_int, b_int, v_len, loops >> 1, linesize);
#endif
  }
#elif SP_DOTP_UNROLL == 1
  fdotp_v32b_global_p1_u1(a_int, b_int, round, dim_per_round);
#elif SP_DOTP_UNROLL == 2
  fdotp_v32b_global_p1_u2(a_int, b_int, round >> 1, dim_per_round);
#elif SP_DOTP_UNROLL == 4
  fdotp_v32b_global_p1_u4(a_int, b_int, round >> 2, dim_per_round);
#else
  fdotp_v32b_global_p1_u8(a_int, b_int, round >> 3, dim_per_round);
#endif

  mempool_log_barrier(2, core_id);
  mempool_stop_benchmark();
  time_end = mempool_get_timer();

  // Phase 2: per-core reduction of the partial vectors.
#if SP_DOTP_PARTITION == SP_DOTP_LOCAL
  if (is_core_active) {
#if SP_DOTP_UNROLL == 1
    acc = fdotp_v32b_local_p2_u1();
#else
    acc = fdotp_v32b_local_p2_u2();
#endif
    l1_result[core_id] = acc;
  }
#else
#if SP_DOTP_UNROLL == 1
  acc = fdotp_v32b_global_p2_u1();
#elif SP_DOTP_UNROLL == 2
  acc = fdotp_v32b_global_p2_u2();
#elif SP_DOTP_UNROLL == 4
  acc = fdotp_v32b_global_p2_u4();
#else
  acc = fdotp_v32b_global_p2_u8();
#endif
  l1_result[core_id] = acc;
#endif

  mempool_barrier(num_cores);

  // Final cross-core accumulation on core 0.
  if (core_id == 0) {
    float sum = 0;
    for (uint32_t i = 0; i < active_cores; ++i)
      sum += l1_result[i];
    *final_store = sum;
  }
  mempool_barrier(num_cores);

  if (core_id == 0) {
    uint32_t clock_cycles = (time_end - time_init);
    printf("\nKernel execution takes %d clock cycles\n", clock_cycles);
  }

  // Copy the scalar result to L2 for the testbench DPI checker.
  if (core_id == 0)
    dma_memcpy_blocking(l2_result_check, final_store, sizeof(float));
  mempool_check_dpi_f32(l2_result_check, &l2_Z, 1, 0.01f, 0);
  mempool_barrier(num_cores);

  return 0;
}
