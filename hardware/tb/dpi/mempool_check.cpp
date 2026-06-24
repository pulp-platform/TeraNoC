// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <svdpi.h>

#include <cmath>
#include <cstring>
#include <limits>
#include <stdint.h>
#include <stdio.h>

static uint16_t load_u16(const uint8_t *data) {
  return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static uint32_t load_u32(const uint8_t *data) {
  return (uint32_t)data[0] | ((uint32_t)data[1] << 8) |
         ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);
}

static float bits_to_f32(uint32_t bits) {
  float value;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

static float fp16_to_float(uint16_t value) {
  const float sign = (value & 0x8000) ? -1.0f : 1.0f;
  const int exp = (value >> 10) & 0x1f;
  const int mant = value & 0x3ff;

  if (exp == 0) {
    return sign * std::ldexp((float)mant, -24);
  }
  if (exp == 0x1f) {
    return mant == 0 ? sign * std::numeric_limits<float>::infinity()
                     : std::numeric_limits<float>::quiet_NaN();
  }
  return sign * std::ldexp((float)(0x400 | mant), exp - 25);
}

static float fp8_to_float(uint8_t value) {
  const float sign = (value & 0x80) ? -1.0f : 1.0f;
  const int exp = (value >> 2) & 0x1f;
  const int mant = value & 0x3;

  if (exp == 0) {
    return sign * std::ldexp((float)mant, -16);
  }
  if (exp == 0x1f) {
    return mant == 0 ? sign * std::numeric_limits<float>::infinity()
                     : std::numeric_limits<float>::quiet_NaN();
  }
  return sign * std::ldexp((float)(0x4 | mant), exp - 17);
}

static int compare_i8(const uint8_t *result, const uint8_t *golden, int count,
                      int tolerance, bool verbose) {
  int errors = 0;
  for (int i = 0; i < count; i++) {
    int exp = (int)(int8_t)golden[i];
    int res = (int)(int8_t)result[i];
    int diff = exp - res;
    bool error = (diff > tolerance) || (diff < -tolerance);
    if (error) {
      errors++;
    }
    if (error || verbose) {
      printf("CHECK(%d): EXP = %02X - RESP = %02X\n", i, golden[i], result[i]);
    }
  }
  return errors;
}

static int compare_i16(const uint8_t *result, const uint8_t *golden, int count,
                       int tolerance, bool verbose) {
  int errors = 0;
  for (int i = 0; i < count; i++) {
    uint16_t exp_bits = load_u16(&golden[2 * i]);
    uint16_t res_bits = load_u16(&result[2 * i]);
    int diff = (int)(int16_t)exp_bits - (int)(int16_t)res_bits;
    bool error = (diff > tolerance) || (diff < -tolerance);
    if (error) {
      errors++;
    }
    if (error || verbose) {
      printf("CHECK(%d): EXP = %04X - RESP = %04X\n", i, exp_bits, res_bits);
    }
  }
  return errors;
}

static int compare_i32(const uint8_t *result, const uint8_t *golden, int count,
                       int tolerance, bool verbose) {
  int errors = 0;
  for (int i = 0; i < count; i++) {
    uint32_t exp_bits = load_u32(&golden[4 * i]);
    uint32_t res_bits = load_u32(&result[4 * i]);
    int64_t diff = (int64_t)(int32_t)exp_bits - (int64_t)(int32_t)res_bits;
    bool error = (diff > tolerance) || (diff < -tolerance);
    if (error) {
      errors++;
    }
    if (error || verbose) {
      printf("CHECK(%d): EXP = %08X - RESP = %08X\n", i, exp_bits, res_bits);
    }
  }
  return errors;
}

static int compare_f8(const uint8_t *result, const uint8_t *golden, int count,
                      uint8_t tolerance, bool verbose) {
  int errors = 0;
  float tol = fp8_to_float(tolerance);
  for (int i = 0; i < count; i++) {
    float diff = fp8_to_float(result[i]) - fp8_to_float(golden[i]);
    bool error = (diff > tol) || (diff < -tol);
    if (error) {
      errors++;
    }
    if (error || verbose) {
      printf("CHECK(%d): EXP = %02X - RESP = %02X\n", i, golden[i], result[i]);
    }
  }
  return errors;
}

static int compare_f16(const uint8_t *result, const uint8_t *golden, int count,
                       float tolerance, bool verbose) {
  int errors = 0;
  for (int i = 0; i < count; i++) {
    uint16_t exp_bits = load_u16(&golden[2 * i]);
    uint16_t res_bits = load_u16(&result[2 * i]);
    float diff = fp16_to_float(res_bits) - fp16_to_float(exp_bits);
    bool error = (diff > tolerance) || (diff < -tolerance);
    if (error) {
      errors++;
    }
    if (error || verbose) {
      printf("CHECK(%d): EXP = %08X - RESP = %08X\n", i, exp_bits, res_bits);
    }
  }
  return errors;
}

static int compare_f32(const uint8_t *result, const uint8_t *golden, int count,
                       float tolerance, bool verbose) {
  int errors = 0;
  for (int i = 0; i < count; i++) {
    uint32_t exp_bits = load_u32(&golden[4 * i]);
    uint32_t res_bits = load_u32(&result[4 * i]);
    float diff = bits_to_f32(res_bits) - bits_to_f32(exp_bits);
    bool error = (diff > tolerance) || (diff < -tolerance);
    if (error) {
      errors++;
    }
    if (error || verbose) {
      printf("CHECK(%d): EXP = %08X - RESP = %08X\n", i, exp_bits, res_bits);
    }
  }
  return errors;
}

static int elem_size_for_type(int type) {
  switch (type) {
  case 1:
  case 4:
    return 1;
  case 2:
  case 5:
    return 2;
  case 3:
  case 6:
    return 4;
  default:
    return 0;
  }
}

extern "C" int mempool_dpi_check(int type, int count, int tolerance,
                                 int verbose,
                                 const svOpenArrayHandle result_buffer,
                                 const svOpenArrayHandle golden_buffer) {
  if (count < 0) {
    return -count;
  }

  int elem_size = elem_size_for_type(type);
  if (elem_size == 0) {
    printf("[DPI_CHECK] Unsupported check type %d\n", type);
    return count;
  }

  int nbytes = count * elem_size;
  if ((svSize(result_buffer, 1) < nbytes) ||
      (svSize(golden_buffer, 1) < nbytes)) {
    printf("[DPI_CHECK] Buffer size mismatch for check with %d bytes\n",
           nbytes);
    return count;
  }

  const uint8_t *result = (const uint8_t *)svGetArrayPtr(result_buffer);
  const uint8_t *golden = (const uint8_t *)svGetArrayPtr(golden_buffer);
  if ((result == NULL) || (golden == NULL)) {
    printf("[DPI_CHECK] Could not access open-array data\n");
    return count;
  }

  switch (type) {
  case 1:
    return compare_i8(result, golden, count, (int16_t)tolerance, verbose != 0);
  case 2:
    return compare_i16(result, golden, count, (int16_t)tolerance, verbose != 0);
  case 3:
    return compare_i32(result, golden, count, (int32_t)tolerance, verbose != 0);
  case 4:
    return compare_f8(result, golden, count, (uint8_t)tolerance, verbose != 0);
  case 5:
    return compare_f16(result, golden, count, bits_to_f32((uint32_t)tolerance),
                       verbose != 0);
  case 6:
    return compare_f32(result, golden, count, bits_to_f32((uint32_t)tolerance),
                       verbose != 0);
  default:
    printf("[DPI_CHECK] Unsupported check type %d\n", type);
    return count;
  }
}
