// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Diyou Shen     <dishen@student.ethz.ch>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "alloc.h"
#include "dma.h"
#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#include "data_sp_bandwidth_test_i32.h"

#ifndef SP_BANDWIDTH_LMUL
#define SP_BANDWIDTH_LMUL 4
#endif

#ifndef SP_BANDWIDTH_ROUNDS
#define SP_BANDWIDTH_ROUNDS 10
#endif

#ifndef SP_BANDWIDTH_STEP
#define SP_BANDWIDTH_STEP 1
#endif

#if SP_BANDWIDTH_LMUL != 1 && SP_BANDWIDTH_LMUL != 2 && SP_BANDWIDTH_LMUL != 4
#error "SP_BANDWIDTH_LMUL must be 1, 2, or 4"
#endif

#if SP_BANDWIDTH_LMUL == 1
#define SP_BANDWIDTH_VSETVLI(vl, avl)                                          \
  asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"(avl))
#elif SP_BANDWIDTH_LMUL == 2
#define SP_BANDWIDTH_VSETVLI(vl, avl)                                          \
  asm volatile("vsetvli %0, %1, e32, m2, ta, ma" : "=r"(vl) : "r"(avl))
#else
#define SP_BANDWIDTH_VSETVLI(vl, avl)                                          \
  asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(avl))
#endif

static int data_l1[M]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
static uint32_t offset_l1[NUM_CORES * SP_BANDWIDTH_ROUNDS]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

static void init_offsets(uint32_t *offsets, uint32_t count, uint32_t dim,
                         uint32_t v_len) {
  uint32_t span = (dim > v_len) ? dim - v_len : 1;
  uint32_t slots = span / SP_BANDWIDTH_STEP;
  if (slots == 0)
    slots = 1;

  for (uint32_t i = 0; i < count; i++) {
    offsets[i] = ((i * 17u + 42u) % slots) * SP_BANDWIDTH_STEP;
  }
}

uint32_t vle_benchmark_n2(const int *addr, uint32_t avl, const uint32_t core_id,
                          const uint32_t num_cores) {
  uint32_t vl;
  uint32_t timer = 0;

  SP_BANDWIDTH_VSETVLI(vl, avl);
  mempool_barrier(num_cores);

  if (core_id == 0)
    timer = mempool_get_timer();

  asm volatile("vle32.v v0,  (%0)" ::"r"(addr));
  asm volatile("vle32.v v4,  (%0)" ::"r"(addr));

  mempool_barrier(num_cores);

  if (core_id == 0)
    timer = mempool_get_timer() - timer;

  return timer;
}

uint32_t vle_benchmark_n4(const int *addr1, const int *addr2, uint32_t avl,
                          const uint32_t core_id, const uint32_t num_cores) {
  uint32_t vl;
  uint32_t timer = 0;

  SP_BANDWIDTH_VSETVLI(vl, avl);
  mempool_barrier(num_cores);

  if (core_id == 0)
    timer = mempool_get_timer();

  asm volatile("vle32.v v0,  (%0)" ::"r"(addr1));
  asm volatile("vle32.v v4,  (%0)" ::"r"(addr1));
  asm volatile("vle32.v v8,  (%0)" ::"r"(addr2));
  asm volatile("vle32.v v12, (%0)" ::"r"(addr2));

  mempool_barrier(num_cores);
  if (core_id == 0)
    timer = mempool_get_timer() - timer;

  return timer;
}

uint32_t barrier_test(const uint32_t core_id, const uint32_t num_cores) {
  uint32_t timer = 0;
  if (core_id == 0)
    timer = mempool_get_timer();

  mempool_barrier(num_cores);

  if (core_id == 0)
    timer = mempool_get_timer() - timer;

  return timer;
}

// Vector A occupies two rows of the entire L1; each core loads a vector at a
// random location in the first row of A.
int main() {
  // Vector length grouping factor
  const uint32_t Vec_Lmul = SP_BANDWIDTH_LMUL;
  // Measurement rounds
  const uint32_t measure_iterations = SP_BANDWIDTH_ROUNDS;
  // Element width (8, 16, 32)
  const uint32_t elem_width = 32;
  // Vector length per vector (elements)
  const uint32_t Vec_Len = (VLEN < 512) ? VLEN / elem_width : 512 / elem_width;

  const uint32_t num_cores = mempool_get_core_count();
  const uint32_t core_id = mempool_get_core_id();
  const uint32_t dim = M;
  const uint32_t v_len = Vec_Lmul * Vec_Len;

  mempool_barrier_init(core_id);
  mempool_barrier(num_cores);

  // Initialize data
  if (core_id == 0) {
    dma_memcpy_blocking(data_l1, data_dram, dim * sizeof(int));
    init_offsets(offset_l1, num_cores * measure_iterations, dim, v_len);
  }

  // Each core's starting address
  uint32_t *offset_p = offset_l1;
  offset_p += core_id;

  int *addr1 = data_l1;
  int *addr2 = data_l1;
  int *addr3 = data_l1;
  int *addr4 = data_l1;
  uint32_t timer = 0;
  uint32_t timer_tot = 0;

  uint32_t vl;
  SP_BANDWIDTH_VSETVLI(vl, v_len);

  mempool_barrier(num_cores);

  if (core_id == 0) {
    mempool_start_benchmark();
    timer = mempool_get_timer();
  }

  for (uint32_t i = 0; i < measure_iterations / 4; i++) {
    addr1 = data_l1 + *offset_p;
    offset_p += num_cores;
    addr2 = data_l1 + *offset_p;
    offset_p += num_cores;
    asm volatile("vle32.v v0,  (%0)" ::"r"(addr1));
    asm volatile("vle32.v v4,  (%0)" ::"r"(addr2));
    addr3 = data_l1 + *offset_p;
    offset_p += num_cores;
    addr4 = data_l1 + *offset_p;
    offset_p += num_cores;
    asm volatile("vle32.v v8,  (%0)" ::"r"(addr3));
    asm volatile("vle32.v v12, (%0)" ::"r"(addr4));
  }

  for (uint32_t i = 0; i < measure_iterations % 4; i++) {
    addr1 = data_l1 + *offset_p;
    offset_p += num_cores;
    asm volatile("vle32.v v0,  (%0)" ::"r"(addr1));
  }

  if (core_id == 0) {
    mempool_stop_benchmark();
    timer_tot = mempool_get_timer() - timer;
  }

  // Check and display results
  if (core_id == 0) {
    // Number of loads one core executes per 1000 cycles
    uint32_t performance = measure_iterations * v_len * 1000 / timer_tot;
    // Each cycle one core can load at most N_FU elements
    uint32_t utilization = performance / N_FU;

    printf("\n----- (%dx%d) vle%d -----\n", measure_iterations, v_len,
           elem_width);
    printf("The execution took %u cycles, average %u cycles\n", timer_tot,
           timer_tot / measure_iterations);
    printf("The performance is %u load/1000cycle (%u%%o utilization).\n",
           performance, utilization);
  }

  mempool_barrier(num_cores);

  return 0;
}
