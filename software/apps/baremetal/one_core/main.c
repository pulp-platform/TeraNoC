// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0


#include <stdint.h>
#include <string.h>

#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#define BANK_NUM 4096
#define ITERATIONS 1

int32_t matrix_a[BANK_NUM * ITERATIONS] __attribute__((section(".l1_prio")));
int32_t matrix_b[BANK_NUM * ITERATIONS] __attribute__((section(".l1_prio")));

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize synchronization variables
  // mempool_barrier_init(core_id);

  if (core_id != 0) {
    mempool_wfi();
  } else {
    // Initialize data
    int32_t buff;
    for (uint32_t i = BANK_NUM/16*15; i < BANK_NUM; i++) {
      buff = matrix_a[i];
      matrix_b[i] = buff;
    }
    // wake_up_all();
  }

  // // wait until all cores have finished
  // mempool_barrier(num_cores);
  return 0;
}
