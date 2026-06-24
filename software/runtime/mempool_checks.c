// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marco Bertuletti, ETH Zurich

#include "mempool_checks.h"
#include "printf.h"
#include "runtime.h"

#ifndef MEMPOOL_DPI_CHECK_CI_BUILD
volatile uint32_t mempool_dpi_check_count
    __attribute__((section(".l2"), used)) = 0;
mempool_dpi_check_t mempool_dpi_checks[MEMPOOL_DPI_CHECK_MAX]
    __attribute__((section(".l2"), used)) = {0};

static void mempool_dpi_check_record(uint32_t type, const void *pRes,
                                     const void *pExp, uint32_t NEL,
                                     uint32_t tolerance, bool verbose) {
  if (mempool_get_core_id() != 0) {
    return;
  }

  uint32_t check_id = mempool_dpi_check_count;
  if (check_id >= MEMPOOL_DPI_CHECK_MAX) {
    return;
  }

  mempool_dpi_checks[check_id].type = type;
  mempool_dpi_checks[check_id].count = NEL;
  mempool_dpi_checks[check_id].tolerance = tolerance;
  mempool_dpi_checks[check_id].result_addr = (uint32_t)pRes;
  mempool_dpi_checks[check_id].golden_addr = (uint32_t)pExp;
  mempool_dpi_checks[check_id].verbose = verbose;
  mempool_dpi_check_count = check_id + 1u;
}
#endif

/**
  @brief         Check for q32 kernels.
  @param[in]     pRes points to the result
  @param[in]     pExp points to the expected result
  @param[in]     NEL  number of elements to check
  @param[in]     TOL  floating point tolerance
  @return        none
*/
void mempool_check_i32(int32_t *__restrict__ pRes, int32_t *__restrict__ pExp,
                       uint32_t NEL, int32_t TOL, bool verbose) {
  uint32_t core_id = mempool_get_core_id();

  if (core_id == 0) {

    uint32_t ERRORS = 0;
    for (uint32_t i = 0; i < NEL; i++) {
      int32_t exp = pExp[i];
      int32_t res = pRes[i];
      int32_t diff = exp - res;
      uint32_t error = ((diff > TOL) || (diff < (-TOL))) ? 1 : 0;
      uint32_t print = error || verbose;
      ERRORS += error;
      if (print) {
        printf("CHECK(%d): EXP = %08X - RESP = %08X\n", i, exp, res);
      }
    }
    printf("%d ERRORS out of %d CHECKS\n", ERRORS, NEL);
  }
  return;
}

void mempool_check_dpi_i32(int32_t *__restrict__ pRes,
                           int32_t *__restrict__ pExp, uint32_t NEL,
                           int32_t TOL, bool verbose) {
#ifdef MEMPOOL_DPI_CHECK_CI_BUILD
  mempool_check_i32(pRes, pExp, NEL, TOL, verbose);
#else
  mempool_dpi_check_record(MEMPOOL_DPI_CHECK_TYPE_I32, pRes, pExp, NEL,
                           (uint32_t)TOL, verbose);
#endif
  return;
}

/**
  @brief         Check for q16 kernels.
  @param[in]     pRes points to the result
  @param[in]     pExp points to the expected result
  @param[in]     NEL  number of elements to check
  @param[in]     TOL  floating point tolerance
  @return        none
*/
void mempool_check_i16(int16_t *__restrict__ pRes, int16_t *__restrict__ pExp,
                       uint32_t NEL, int16_t TOL, bool verbose) {
  uint32_t core_id = mempool_get_core_id();

  if (core_id == 0) {

    uint32_t ERRORS = 0;
    for (uint32_t i = 0; i < NEL; i++) {
      int16_t exp = (int16_t)pExp[i];
      int16_t res = (int16_t)pRes[i];
      int16_t diff = (int16_t)(exp - res);
      uint32_t error = ((diff > TOL) || (diff < (-TOL))) ? 1 : 0;
      uint32_t print = error || verbose;
      ERRORS += error;
      if (print) {
        printf("CHECK(%d): EXP = %04X - RESP = %04X\n", i, exp, res);
        ERRORS++;
      }
    }
    printf("%d ERRORS out of %d CHECKS\n", ERRORS, NEL);
  }
  return;
}

void mempool_check_dpi_i16(int16_t *__restrict__ pRes,
                           int16_t *__restrict__ pExp, uint32_t NEL,
                           int16_t TOL, bool verbose) {
#ifdef MEMPOOL_DPI_CHECK_CI_BUILD
  mempool_check_i16(pRes, pExp, NEL, TOL, verbose);
#else
  mempool_dpi_check_record(MEMPOOL_DPI_CHECK_TYPE_I16, pRes, pExp, NEL,
                           (uint32_t)(int32_t)TOL, verbose);
#endif
  return;
}

/**
  @brief         Check for i8 kernels.
  @param[in]     pRes points to the result
  @param[in]     pExp points to the expected result
  @param[in]     NEL  number of elements to check
  @param[in]     TOL  floating point tolerance
  @return        none
*/
void mempool_check_i8(int8_t *__restrict__ pRes, int8_t *__restrict__ pExp,
                      uint32_t NEL, int16_t TOL, bool verbose) {
  uint32_t core_id = mempool_get_core_id();
  int16_t error;
  if (core_id == 0) {
    uint32_t ERRORS = 0;
    for (uint32_t i = 0; i < NEL; i++) {
      int16_t exp = (int8_t)pExp[i];
      int16_t res = (int8_t)pRes[i];
      error = (int8_t)(exp - res);
      bool print = ((error > TOL) || (error < (-TOL))) | verbose;
      if (print) {
        printf("CHECK(%d): EXP = %02X - RESP = %02X\n", i, exp, res);
        ERRORS++;
      }
    }
    printf("%d ERRORS out of %d CHECKS\n", ERRORS, NEL);
  }
  return;
}

void mempool_check_dpi_i8(int8_t *__restrict__ pRes, int8_t *__restrict__ pExp,
                          uint32_t NEL, int16_t TOL, bool verbose) {
#ifdef MEMPOOL_DPI_CHECK_CI_BUILD
  mempool_check_i8(pRes, pExp, NEL, TOL, verbose);
#else
  mempool_dpi_check_record(MEMPOOL_DPI_CHECK_TYPE_I8, pRes, pExp, NEL,
                           (uint32_t)(int32_t)TOL, verbose);
#endif
  return;
}

#ifdef __clang__
/**
  @brief         Check for f32 kernels.
  @param[in]     pRes points to the result
  @param[in]     pExp points to the expected result
  @param[in]     NEL  number of elements to check
  @param[in]     TOL  floating point tolerance
  @return        none
*/
void mempool_check_f32(float *__restrict__ pRes, float *__restrict__ pExp,
                       uint32_t NEL, float TOL, bool verbose) {
  uint32_t core_id = mempool_get_core_id();

  if (core_id == 0) {

    uint32_t ERRORS = 0;
    for (uint32_t i = 0; i < NEL; i++) {
      float exp = pExp[i];
      float res = pRes[i];
      float diff;
      asm volatile("fsub.s %[diff], %[res], %[exp];"
                   : [diff] "+&r"(diff)
                   : [res] "r"(res), [exp] "r"(exp)
                   :);
      uint32_t error = ((diff > TOL) || (diff < (-TOL))) ? 1 : 0;
      uint32_t print = error || verbose;
      ERRORS += error;
      if (print) {
        printf("CHECK(%d): EXP = %08X - RESP = %08X\n", i, *(int32_t *)&exp,
               *(int32_t *)&res);
      }
    }
    printf("%d ERRORS out of %d CHECKS\n", ERRORS, NEL);
  }
  return;
}

void mempool_check_dpi_f32(float *__restrict__ pRes, float *__restrict__ pExp,
                           uint32_t NEL, float TOL, bool verbose) {
#ifdef MEMPOOL_DPI_CHECK_CI_BUILD
  mempool_check_f32(pRes, pExp, NEL, TOL, verbose);
#else
  mempool_dpi_check_record(MEMPOOL_DPI_CHECK_TYPE_F32, pRes, pExp, NEL,
                           *(uint32_t *)&TOL, verbose);
#endif
  return;
}

/**
  @brief         Check for f16 kernels.
  @param[in]     pRes points to the result
  @param[in]     pExp points to the expected result
  @param[in]     NEL  number of elements to check
  @param[in]     TOL  floating point tolerance
  @return        none
*/
void mempool_check_f16(__fp16 *__restrict__ pRes, __fp16 *__restrict__ pExp,
                       uint32_t NEL, float TOL, bool verbose) {
  uint32_t core_id = mempool_get_core_id();

  if (core_id == 0) {
    uint32_t ERRORS = 0;
    for (uint32_t i = 0; i < NEL; i++) {
      __fp16 exp = pExp[i];
      __fp16 res = pRes[i];
      float diff;
      asm volatile("fsub.h %[diff], %[res], %[exp];"
                   "fcvt.s.h %[diff], %[diff];"
                   : [diff] "+&r"(diff)
                   : [res] "r"(res), [exp] "r"(exp)
                   :);

      uint32_t error = ((diff > TOL) || (diff < (-TOL))) ? 1 : 0;
      uint32_t print = error || verbose;
      ERRORS += error;
      if (print) {
        printf("CHECK(%d): EXP = %08X - RESP = %08X\n", i, *(int32_t *)&exp,
               *(int32_t *)&res);
      }
    }
    printf("%d ERRORS out of %d CHECKS\n", ERRORS, NEL);
  }
  return;
}

void mempool_check_dpi_f16(__fp16 *__restrict__ pRes, __fp16 *__restrict__ pExp,
                           uint32_t NEL, float TOL, bool verbose) {
#ifdef MEMPOOL_DPI_CHECK_CI_BUILD
  mempool_check_f16(pRes, pExp, NEL, TOL, verbose);
#else
  mempool_dpi_check_record(MEMPOOL_DPI_CHECK_TYPE_F16, pRes, pExp, NEL,
                           *(uint32_t *)&TOL, verbose);
#endif
  return;
}

/**
  @brief         Check for f8 kernels.
  @param[in]     pRes points to the result
  @param[in]     pExp points to the expected result
  @param[in]     NEL  number of elements to check
  @param[in]     TOL  floating point tolerance
  @return        none
*/
void mempool_check_f8(__fp8 *__restrict__ pRes, __fp8 *__restrict__ pExp,
                      uint32_t NEL, __fp8 TOL, bool verbose) {
  uint32_t core_id = mempool_get_core_id();

  if (core_id == 0) {
    uint32_t ERRORS = 0;
    for (uint32_t i = 0; i < NEL; i++) {
      __fp8 exp = pExp[i];
      __fp8 res = pRes[i];
      __fp8 diff;
      asm volatile("fsub.b %[diff], %[res], %[exp];"
                   : [diff] "+&r"(diff)
                   : [res] "r"(res), [exp] "r"(exp));

      uint32_t error = ((diff > TOL) || (diff < (-TOL))) ? 1 : 0;
      uint32_t print = error || verbose;
      ERRORS += error;
      if (print) {
        printf("CHECK(%d): EXP = %02X - RESP = %02X - DIFF = %04X\n", i,
               *(int32_t *)&exp, *(int32_t *)&res, *(int32_t *)&diff);
      }
    }
    printf("%d ERRORS out of %d CHECKS\n", ERRORS, NEL);
  }
  return;
}

void mempool_check_dpi_f8(__fp8 *__restrict__ pRes, __fp8 *__restrict__ pExp,
                          uint32_t NEL, __fp8 TOL, bool verbose) {
#ifdef MEMPOOL_DPI_CHECK_CI_BUILD
  mempool_check_f8(pRes, pExp, NEL, TOL, verbose);
#else
  mempool_dpi_check_record(MEMPOOL_DPI_CHECK_TYPE_F8, pRes, pExp, NEL,
                           (uint32_t)(uint8_t)TOL, verbose);
#endif
  return;
}
#endif
