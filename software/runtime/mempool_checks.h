// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marco Bertuletti, ETH Zurich

#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "builtins_v2.h"

#ifndef MEMPOOL_DPI_CHECK_CI_BUILD

#define MEMPOOL_DPI_CHECK_MAX 4
enum {
  MEMPOOL_DPI_CHECK_TYPE_I8 = 1,
  MEMPOOL_DPI_CHECK_TYPE_I16 = 2,
  MEMPOOL_DPI_CHECK_TYPE_I32 = 3,
  MEMPOOL_DPI_CHECK_TYPE_F8 = 4,
  MEMPOOL_DPI_CHECK_TYPE_F16 = 5,
  MEMPOOL_DPI_CHECK_TYPE_F32 = 6
};

typedef struct {
  uint32_t type;
  uint32_t count;
  uint32_t tolerance;
  uint32_t result_addr;
  uint32_t golden_addr;
  uint32_t verbose;
} mempool_dpi_check_t;

extern volatile uint32_t mempool_dpi_check_count;
extern mempool_dpi_check_t mempool_dpi_checks[MEMPOOL_DPI_CHECK_MAX];

#endif

void mempool_check_i32(int32_t *__restrict__ pRes, int32_t *__restrict__ pExp,
                       uint32_t NEL, int32_t TOL, bool verbose);
void mempool_check_dpi_i32(int32_t *__restrict__ pRes,
                           int32_t *__restrict__ pExp, uint32_t NEL,
                           int32_t TOL, bool verbose);

void mempool_check_i16(int16_t *__restrict__ pRes, int16_t *__restrict__ pExp,
                       uint32_t NEL, int16_t TOL, bool verbose);
void mempool_check_dpi_i16(int16_t *__restrict__ pRes,
                           int16_t *__restrict__ pExp, uint32_t NEL,
                           int16_t TOL, bool verbose);

void mempool_check_i8(int8_t *__restrict__ pRes, int8_t *__restrict__ pExp,
                      uint32_t NEL, int16_t TOL, bool verbose);
void mempool_check_dpi_i8(int8_t *__restrict__ pRes, int8_t *__restrict__ pExp,
                          uint32_t NEL, int16_t TOL, bool verbose);

#ifdef __clang__
void mempool_check_f32(float *__restrict__ pRes, float *__restrict__ pExp,
                       uint32_t NEL, float TOL, bool verbose);
void mempool_check_dpi_f32(float *__restrict__ pRes, float *__restrict__ pExp,
                           uint32_t NEL, float TOL, bool verbose);

void mempool_check_f16(__fp16 *__restrict__ pRes, __fp16 *__restrict__ pExp,
                       uint32_t NEL, float TOL, bool verbose);
void mempool_check_dpi_f16(__fp16 *__restrict__ pRes, __fp16 *__restrict__ pExp,
                           uint32_t NEL, float TOL, bool verbose);

void mempool_check_f8(__fp8 *__restrict__ pRes, __fp8 *__restrict__ pExp,
                      uint32_t NEL, __fp8 TOL, bool verbose);
void mempool_check_dpi_f8(__fp8 *__restrict__ pRes, __fp8 *__restrict__ pExp,
                          uint32_t NEL, __fp8 TOL, bool verbose);
#endif
