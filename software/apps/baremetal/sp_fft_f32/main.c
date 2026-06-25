// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Diyou Shen, ETH Zurich
//         Yinrong Li, ETH Zurich

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "dma.h"
#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#ifndef SP_FFT_DATA_HEADER
#define SP_FFT_DATA_HEADER "data_sp_fft_f32.h"
#endif
#include SP_FFT_DATA_HEADER

#include "baremetal/mempool_sp_fft_f32.h"
#include "mempool_checks.h"

#ifdef SP_FFT_MULTI
#if NUM_CORES == 1
#define SP_FFT_ACTIVE_CORES 1
#define SP_FFT_LOG2_ACTIVE_CORES 0
#elif NUM_CORES == 2
#define SP_FFT_ACTIVE_CORES 2
#define SP_FFT_LOG2_ACTIVE_CORES 1
#elif NUM_CORES == 4
#define SP_FFT_ACTIVE_CORES 4
#define SP_FFT_LOG2_ACTIVE_CORES 2
#elif NUM_CORES == 8
#define SP_FFT_ACTIVE_CORES 8
#define SP_FFT_LOG2_ACTIVE_CORES 3
#else
#define SP_FFT_ACTIVE_CORES 16
#define SP_FFT_LOG2_ACTIVE_CORES 4
#endif
#define SP_FFT_NUM_FFT (NUM_CORES / SP_FFT_ACTIVE_CORES)
#else
#if NUM_CORES == 1
#define SP_FFT_LOG2_ACTIVE_CORES 0
#elif NUM_CORES == 2
#define SP_FFT_LOG2_ACTIVE_CORES 1
#elif NUM_CORES == 4
#define SP_FFT_LOG2_ACTIVE_CORES 2
#elif NUM_CORES == 8
#define SP_FFT_LOG2_ACTIVE_CORES 3
#elif NUM_CORES == 16
#define SP_FFT_LOG2_ACTIVE_CORES 4
#elif NUM_CORES == 32
#define SP_FFT_LOG2_ACTIVE_CORES 5
#elif NUM_CORES == 64
#define SP_FFT_LOG2_ACTIVE_CORES 6
#elif NUM_CORES == 128
#define SP_FFT_LOG2_ACTIVE_CORES 7
#elif NUM_CORES == 256
#define SP_FFT_LOG2_ACTIVE_CORES 8
#else
#error "Unsupported NUM_CORES for sp_fft_f32"
#endif
#define SP_FFT_ACTIVE_CORES NUM_CORES
#define SP_FFT_NUM_FFT 1
#endif

#define SP_FFT_NFFTPC (NFFT / SP_FFT_ACTIVE_CORES)
#define SP_FFT_LOG2_NFFT2 (FFT_LOG2_NFFT - SP_FFT_LOG2_ACTIVE_CORES)
#define SP_FFT_NTWI_P1 (NFFT - SP_FFT_NFFTPC)
#define SP_FFT_NTWI_P2 (SP_FFT_LOG2_NFFT2 * (SP_FFT_NFFTPC >> 1))
#define SP_FFT_STORE_IDX_LEN ((SP_FFT_LOG2_NFFT2 - 1) * (SP_FFT_NFFTPC >> 1))

enum {
  active_cores = SP_FFT_ACTIVE_CORES,
  num_fft = SP_FFT_NUM_FFT,
  log2_nfft = FFT_LOG2_NFFT,
  log2_nfft1 = SP_FFT_LOG2_ACTIVE_CORES,
  log2_nfft2 = SP_FFT_LOG2_NFFT2,
  NTWI_P1 = SP_FFT_NTWI_P1,
  NTWI_P2 = SP_FFT_NTWI_P2
};

// Per-FFT working buffers (split layout: [re..][im..]).
float samples[SP_FFT_NUM_FFT][2 * NFFT]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float buffer[SP_FFT_NUM_FFT][2 * NFFT]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float out[SP_FFT_NUM_FFT][2 * NFFT]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float twiddle_p1[SP_FFT_NUM_FFT][2 * SP_FFT_NTWI_P1]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
float twiddle_p2[SP_FFT_NUM_FFT][SP_FFT_ACTIVE_CORES * 2 * SP_FFT_NTWI_P2]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
uint16_t store_idx[SP_FFT_NUM_FFT][SP_FFT_STORE_IDX_LEN]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));
uint32_t core_offset[SP_FFT_NUM_FFT][SP_FFT_ACTIVE_CORES]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

// L1 staging buffer that re-interleaves a split FFT output into the same
// [re, im, re, im, ...] layout as the golden gold_out_dram.
float l1_R[2 * NFFT]
    __attribute__((aligned(4 * NUM_BANKS), section(".l1_prio")));

// L2 buffer to hold the result for the testbench DPI checker:
float l2_R_check[2 * NFFT]
    __attribute__((aligned(4 * NUM_BANKS), section(".l2")));

static uint32_t fft_log2_u32(uint32_t value) {
  uint32_t log = 0;
  while (value > 1) {
    value >>= 1;
    log++;
  }
  return log;
}

static uint32_t fft_twiddle_table_offset(uint32_t nfft) {
  uint32_t offset = 0;
  for (uint32_t sub_nfft = 2; sub_nfft < nfft; sub_nfft <<= 1)
    offset += fft_log2_u32(sub_nfft) * (sub_nfft >> 1);
  return offset;
}

static uint32_t fft_store_idx_table_offset(uint32_t nfft) {
  uint32_t offset = 0;
  for (uint32_t sub_nfft = 2; sub_nfft < nfft; sub_nfft <<= 1) {
    uint32_t log = fft_log2_u32(sub_nfft);
    if (log > 0)
      offset += (log - 1) * (sub_nfft >> 1);
  }
  return offset;
}

static uint32_t fft_bit_reverse(uint32_t value, uint32_t bits) {
  uint32_t reversed = 0;
  for (uint32_t i = 0; i < bits; i++) {
    reversed = (reversed << 1) | (value & 1);
    value >>= 1;
  }
  return reversed;
}

static void fft_prepare_tables(uint32_t n_fft) {
  uint32_t nfftpc = SP_FFT_NFFTPC;
  uint32_t p1_src_base = fft_twiddle_table_offset(NFFT);
  uint32_t p1_dst = 0;

  for (uint32_t stage = 0; stage < log2_nfft1; stage++) {
    uint32_t stage_len = NFFT >> (stage + 1);
    uint32_t p1_src = p1_src_base + stage * (NFFT >> 1);
    dma_memcpy_blocking(twiddle_p1[n_fft] + p1_dst,
                        fft_twiddle_re_dram + p1_src,
                        stage_len * sizeof(float));
    dma_memcpy_blocking(twiddle_p1[n_fft] + NTWI_P1 + p1_dst,
                        fft_twiddle_im_dram + p1_src,
                        stage_len * sizeof(float));
    p1_dst += stage_len;
  }

  uint32_t p2_src = fft_twiddle_table_offset(nfftpc);
  for (uint32_t core = 0; core < active_cores; core++) {
    float *p2_dst = twiddle_p2[n_fft] + core * (NTWI_P2 << 1);
    dma_memcpy_blocking(p2_dst, fft_twiddle_re_dram + p2_src,
                        NTWI_P2 * sizeof(float));
    dma_memcpy_blocking(p2_dst + NTWI_P2, fft_twiddle_im_dram + p2_src,
                        NTWI_P2 * sizeof(float));
    core_offset[n_fft][core] = fft_bit_reverse(core, log2_nfft1);
  }

  dma_memcpy_blocking(store_idx[n_fft],
                      store_idx_dram + fft_store_idx_table_offset(nfftpc),
                      SP_FFT_STORE_IDX_LEN * sizeof(uint16_t));
}

int main() {
  // twiddle layout: [re_p1, im_p1, re_p2, im_p2]
  const uint32_t core_id = mempool_get_core_id();
  const uint32_t num_cores = mempool_get_core_count();
  uint32_t time_init, time_end;
  mempool_barrier_init(core_id);

  const uint32_t NFFTpc = NFFT / active_cores;
  // 32-bit floating, 4 byte distance in memory
  const uint32_t element_size = 4;
  // elements distance between two stores
  const uint32_t stride_e = active_cores;
  // distance in bits
  const uint32_t stride = stride_e * element_size;
  const uint32_t total_active_cores = active_cores * num_fft;
  const uint32_t is_core_active = core_id < total_active_cores;

  time_init = 0;
  time_end = 0;

  // Initialize data: multi-FFT mode replicates the same input in each slot.
  if (core_id == 0) {
    for (uint32_t n_fft = 0; n_fft < num_fft; n_fft++) {
      dma_memcpy_blocking(samples[n_fft], samples_dram,
                          (NFFT * 2) * sizeof(float));
      dma_memcpy_blocking(buffer[n_fft], buffer_dram,
                          (NFFT * 2) * sizeof(float));
      dma_memcpy_blocking(out[n_fft], buffer_dram, (NFFT * 2) * sizeof(float));
      fft_prepare_tables(n_fft);
    }
  }
  mempool_barrier(num_cores);

  uint32_t n_fft_id = 0;
  uint32_t n_fft_cid = 0;
  float *src_p2 = samples[0];
  float *buf_p2 = buffer[0];
  float *twi_p2 = twiddle_p2[0];
  float *out_p2 = out[0];
  uint16_t *store_idx_p = store_idx[0];
  float *src_p1 = samples[0];
  float *buf_p1 = buffer[0];
  float *twi_p1 = twiddle_p1[0];
  const uint32_t len = (NFFTpc >> 1);

  if (is_core_active) {
    n_fft_id = core_id / active_cores;
    n_fft_cid = core_id - active_cores * n_fft_id;

    // Calculate pointers for the second butterfly onwards.
    src_p2 = samples[n_fft_id] + n_fft_cid * NFFTpc;
    buf_p2 = buffer[n_fft_id] + n_fft_cid * NFFTpc;
    // Let each core have its own twiddle copy to reduce bank conflicts.
    twi_p2 = twiddle_p2[n_fft_id] + n_fft_cid * (NTWI_P2 << 1);
    out_p2 = out[n_fft_id] + core_offset[n_fft_id][n_fft_cid];
    store_idx_p = store_idx[n_fft_id];

    src_p1 = samples[n_fft_id];
    buf_p1 = buffer[n_fft_id];
    twi_p1 = twiddle_p1[n_fft_id];
  }

  uint32_t p2_switch = 0;

  mempool_barrier(num_cores);

  // Benchmark
  time_init = mempool_get_timer();
  mempool_start_benchmark();

  for (uint32_t i = 0; i < log2_nfft1; i++) {
    if (is_core_active) {
      fft_p1(src_p1, buf_p1, twi_p1, NFFT, NTWI_P1, n_fft_cid, active_cores, i,
             len);
      // Each round will use half the twiddle than previous round; the first
      // round needs re/im NFFT/2 twiddles.
      src_p1 = (i & 1) ? samples[n_fft_id] : buffer[n_fft_id];
      buf_p1 = (i & 1) ? buffer[n_fft_id] : samples[n_fft_id];
      twi_p1 += (NFFT >> (i + 1));
      p2_switch = (i & 1);
    }
    mempool_barrier(num_cores);
  }

  if (is_core_active) {
    // Fall back into the single-core case: each core does an FFT on the
    // (NFFT >> log2_nfft1) data it owns.
    if (p2_switch) {
      fft_p2(buf_p2, src_p2, twi_p2, out_p2, store_idx_p, (NFFT >> log2_nfft1),
             NFFT, log2_nfft2, stride, log2_nfft1, NTWI_P2);
    } else {
      fft_p2(src_p2, buf_p2, twi_p2, out_p2, store_idx_p, (NFFT >> log2_nfft1),
             NFFT, log2_nfft2, stride, log2_nfft1, NTWI_P2);
    }
  }

  mempool_log_barrier(2, core_id);
  mempool_stop_benchmark();
  time_end = mempool_get_timer();

  // Display runtime
  if (core_id == 0) {
    uint32_t clock_cycles = (time_end - time_init);
    printf("\nKernel execution takes %d clock cycles\n", clock_cycles);
  }

  // Every concurrent FFT computes the same result on replicated input data, so
  // re-interleave each output to the golden [re, im, ...] layout, ship it to
  // L2 and DPI-check it against the single shared golden.
  for (uint32_t n_fft = 0; n_fft < num_fft; n_fft++) {
    if (core_id == 0) {
      for (uint32_t i = 0; i < NFFT; i++) {
        l1_R[2 * i] = out[n_fft][i];
        l1_R[2 * i + 1] = out[n_fft][i + NFFT];
      }
      dma_memcpy_blocking(l2_R_check, l1_R, (NFFT * 2) * sizeof(float));
    }
    mempool_check_dpi_f32(l2_R_check, gold_out_dram, 2 * NFFT, 0.01f, 0);
    mempool_barrier(num_cores);
  }

  return 0;
}
