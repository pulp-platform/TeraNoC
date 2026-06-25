// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Domenic Wuthrich, ETH Zurich

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "dma.h"
#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#include "data_sp_axpy_f32.h"

#include "baremetal/mempool_sp_axpy_f32.h"
#include "mempool_checks.h"

#ifndef SP_AXPY_LMUL
#define SP_AXPY_LMUL 1
#endif

#if SP_AXPY_LMUL != 1 && SP_AXPY_LMUL != 2 && SP_AXPY_LMUL != 4 &&             \
    SP_AXPY_LMUL != 8
#error "SP_AXPY_LMUL must be 1, 2, 4, or 8"
#endif

float l1_X[array_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float l1_Y[array_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

float l2_Y_check[array_N]
    __attribute__((aligned(4 * NUM_BANKS), section(".l2")));

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  uint32_t time_init, time_end;
  mempool_barrier_init(core_id);

  // Copy the inputs into the local L1 scratchpad.
  if (core_id == 0) {
    dma_memcpy_blocking(l1_X, l2_X, array_N * sizeof(float));
    dma_memcpy_blocking(l1_Y, l2_Y, array_N * sizeof(float));
  }
  const float a = l2_A;
  mempool_barrier(num_cores);

  // Each core strip-mines an LMUL-wide chunk over `round` iterations.
  const uint32_t max_vl = (VLEN / 32) * SP_AXPY_LMUL;
  const uint32_t dim_per_round = max_vl * num_cores;
  const uint32_t round =
      (array_N > dim_per_round) ? array_N / dim_per_round : 1;
  const uint32_t dim_core = (round == 0) ? (array_N / num_cores) : max_vl;
  float *x_core = l1_X + dim_core * core_id;
  float *y_core = l1_Y + dim_core * core_id;
  uint32_t vl;
#if SP_AXPY_LMUL == 1
  asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"(dim_core));
#elif SP_AXPY_LMUL == 2
  asm volatile("vsetvli %0, %1, e32, m2, ta, ma" : "=r"(vl) : "r"(dim_core));
#elif SP_AXPY_LMUL == 4
  asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(dim_core));
#else
  asm volatile("vsetvli %0, %1, e32, m8, ta, ma" : "=r"(vl) : "r"(dim_core));
#endif

  // PARALLEL, LOCAL ACCESSES
  time_init = mempool_get_timer();
  mempool_start_benchmark();
#if SP_AXPY_LMUL < 8
  if (round >= 4)
    faxpy_v32b_unroll4(a, x_core, y_core, round >> 2, dim_per_round);
  else if (round >= 2)
#else
  if (round >= 2)
#endif
    faxpy_v32b_unroll2(a, x_core, y_core, round >> 1, dim_per_round);
  else
    faxpy_v32b(a, x_core, y_core, round, dim_per_round);
  mempool_log_barrier(2, core_id);
  mempool_stop_benchmark();
  time_end = mempool_get_timer();

  // Check results
  if (core_id == 0) {
    uint32_t clock_cycles = (time_end - time_init);
    printf("\nKernel execution takes %d clock cycles\n", clock_cycles);
  }
  if (core_id == 0) {
    dma_memcpy_blocking(l2_Y_check, l1_Y, array_N * sizeof(float));
  }
  mempool_check_dpi_f32(l2_Y_check, l2_Z, array_N, 0.01f, 0);
  mempool_barrier(num_cores);

  return 0;
}
