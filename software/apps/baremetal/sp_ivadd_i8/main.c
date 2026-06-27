// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Domenic Wüthrich, ETH Zurich

// clang-format off

#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

// #define UNALIGNED 1
// #define VEC_LENGTH 33+UNALIGNED
#define VEC_LENGTH 32
#define UNALIGNED 0

uint8_t vector1[VEC_LENGTH] = {0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef};
uint8_t vector2[VEC_LENGTH] = {0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10};

uint8_t vector_res[VEC_LENGTH];

int main() {
  //////////////////
  // Strip Mining //
  //////////////////

  // Stripmining loop
  int32_t remaining_elem = VEC_LENGTH-UNALIGNED;
  uint8_t *ptr_vec1 = vector1+UNALIGNED;
  uint8_t *ptr_vec2 = vector2+UNALIGNED;
  uint8_t *ptr_vec_res = vector_res+UNALIGNED;
  const unsigned int core_id = mempool_get_core_id();
  const unsigned int num_cores = mempool_get_core_count();
  int error = 0;
  while (remaining_elem > 0) {
    uint32_t actual_elem;
    asm volatile("vsetvli %0, %1, e8, m1, ta, ma" : "=r"(actual_elem) : "r"(remaining_elem));
    asm volatile("vle8.v v12, (%[vector1])" :: [vector1]"r"(ptr_vec1));
    asm volatile("vle8.v v13, (%[vector2])" :: [vector2]"r"(ptr_vec2));
    asm volatile("vadd.vv v14, v12, v13");
    asm volatile("vse8.v v14, (%[vector_res])" :: [vector_res]"r"(ptr_vec_res));
    remaining_elem -= actual_elem;
    ptr_vec1 += actual_elem;
    ptr_vec2 += actual_elem;
    ptr_vec_res += actual_elem;
  }

  mempool_barrier_init(core_id);
  mempool_barrier(num_cores);

  if (core_id == 0) {
    printf("CHECK RESULT\n");
  }
  int diff;
  for (int i = UNALIGNED; i < VEC_LENGTH; i++) {
    diff = vector1[i] + vector2[i] - vector_res[i];
    // if (vector1[i] + vector2[i] != vector_res[i]) {
    if (diff != 0) {
      if (core_id == 0) {
        printf("W: %d,%d\n", i, vector_res[i]);
      }
      error = 1;
      // return i+1;
    }
  }

  mempool_barrier(num_cores);
  if (core_id == 0 & error == 0) {
    printf("CORRECT!\n");
  }
  mempool_barrier(num_cores);

  return error;
}

// clang-format on
