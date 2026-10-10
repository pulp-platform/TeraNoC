// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Global log barrier for the Qwen kernels (qwen-ffn-down's, via qwen-ffn/phase.c).
//
// mempool_barrier's single shared counter costs ~14k cycles at 8x8; this one counts in a
// radix tree of counters, each in one core's sequential memory (its crt0 stack-limit word,
// SEQ_MEM_SIZE * core + 4). Call qc_sync_init(cid) once (then a mempool_barrier) before use.
#ifndef QC_SYNC_H
#define QC_SYNC_H

#include <stdint.h>

#include "runtime.h"
#include "synchronization.h"

#if NUM_CORES > 256
#define QC_LOG2_RADIX 5
#elif NUM_CORES > 64
#define QC_LOG2_RADIX 4
#elif NUM_CORES > 16
#define QC_LOG2_RADIX 3
#else
#define QC_LOG2_RADIX 2
#endif
#define QC_RADIX (1u << QC_LOG2_RADIX)

// The counter is word 1 of the core's sequential region, which is also its 512 B stack (crt0
// starts sp at 0x1fc): a call chain deeper than 500 B overwrites it -- a barrier that hangs or
// releases early. script/stack_depth.py checks every build (build_app.sh).
static inline void qc_sync_init(uint32_t cid) {
  *(volatile uint32_t *)(cid * SEQ_MEM_SIZE + 4) = 0u;
}

static uint32_t qc_log_barrier(uint32_t step, uint32_t cid) {
  uint32_t *bar =
      (uint32_t *)(((cid / step) * step + (step >> QC_LOG2_RADIX) - 1) * SEQ_MEM_SIZE + 4);
  uint32_t val = __atomic_fetch_add(bar, 1, __ATOMIC_RELAXED);
  if (val == (uint32_t)(QC_RADIX - 1)) {
    if (step == (uint32_t)NUM_CORES) return (uint32_t)bar;
    __atomic_store_n(bar, 0, __ATOMIC_RELAXED);
    return qc_log_barrier(step << QC_LOG2_RADIX, cid);
  }
  mempool_wfi();
  return 0;
}

// Global rendezvous; this core's vector stores are drained first (the counter is scalar).
static inline void qc_barrier(uint32_t cid) {
  __asm__ volatile("fence" ::: "memory");
  uint32_t bar = qc_log_barrier(QC_RADIX, cid);
  if (bar) {
    __atomic_store_n((uint32_t *)bar, 0, __ATOMIC_RELAXED);
    __sync_synchronize();
    wake_up_all();
    mempool_wfi();
  }
}

#endif  // QC_SYNC_H
