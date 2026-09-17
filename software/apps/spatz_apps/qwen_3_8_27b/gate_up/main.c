// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
#include "dma.h"
#include "mshr_cfg.h"
#include "printf.h"
#include "qwen_config.h"
#include "runtime.h"
#include "synchronization.h"

#define Q_STRIPE (64 * NUM_CORES)
#define Q_L1 __attribute__((section(".l1_prio"), aligned(Q_STRIPE)))
extern const _Float16 q_x_data[], q_gate_weights[], q_up_weights[];
static _Float16 q_weights[2][Q_WEIGHT_ELEMENTS] Q_L1;
static _Float16 q_x[Q_X_REPLICAS * Q_X_REPLICA_ELEMENTS] Q_L1;
float q_partial[Q_PARTIAL_ELEMENTS] Q_L1;
float q_output[2][Q_BATCH * Q_INTERMEDIATE] Q_L1;
uint32_t q_core_compute[NUM_CORES][16] Q_L1;
uint32_t q_status[NUM_CORES][16] Q_L1;
uint32_t q_complete Q_L1;
static volatile uint32_t q_join_count Q_L1;
uint32_t q_projection_begin[2] Q_L1, q_projection_end[2] Q_L1;
uint32_t q_benchmark_begin Q_L1, q_benchmark_end Q_L1;
typedef struct {
  uint32_t stage, tile, begin, compute_end, joined, ready;
} q_event_t;
q_event_t q_events[2 * Q_HIDDEN / Q_KT] Q_L1;

static inline void q_join(void) {
  asm volatile("fence" ::: "memory");
#if Q_GROUP_BARRIER
  uint32_t cid = mempool_get_core_id(), group = cid / NUM_CORES_PER_GROUP;
  uint32_t ctrl = GROUP_CONTROL_BASE + GROUP_BARRIER_WORD * MSHR_WORD_STRIDE +
                  group * MSHR_GROUP_STRIDE +
                  (cid % NUM_CORES_PER_GROUP) * MSHR_TILE_STRIDE;
  uint32_t unused;
  asm volatile("lw %0, 0(%1)" : "=r"(unused) : "r"(ctrl) : "memory");
  // Every reader in this group has drained before its leader joins globally.
  if (cid % NUM_CORES_PER_GROUP == 0 &&
      __atomic_fetch_add(&q_join_count, 1, __ATOMIC_RELAXED) ==
          NUM_GROUPS - 1) {
    __atomic_store_n(&q_join_count, 0, __ATOMIC_RELAXED);
    asm volatile("fence" ::: "memory");
    wake_up_all();
  }
  mempool_wfi();
#else
  mempool_barrier(NUM_CORES);
#endif
}
#include "microkernel.h"

static void q_project(uint32_t stage, uint32_t cid, const _Float16 *source) {
  q_zero(cid);
  if (!cid) {
    q_projection_begin[stage] = mempool_get_timer();
    dma_memcpy_blocking(q_weights[0], source, sizeof(q_weights[0]));
  }
  q_join();
  for (uint32_t t = 0; t < Q_HIDDEN / Q_KT; ++t) {
    uint32_t b = t & 1;
    q_event_t *e = &q_events[stage * (Q_HIDDEN / Q_KT) + t];
    if (!cid) {
      e->stage = stage;
      e->tile = t;
      e->begin = mempool_get_timer();
      if (Q_OVERLAP && t + 1 < Q_HIDDEN / Q_KT)
        dma_memcpy_nonblocking(q_weights[1 - b],
                               source + (t + 1) * Q_WEIGHT_ELEMENTS,
                               sizeof(q_weights[0]));
    }
    uint32_t begin = mempool_get_timer();
    q_compute(cid, t, q_weights[b]);
    // FENCE drains the vector memory side before the all-core rendezvous.
    // Accumulator stores also depend on completion of all weight loads.
    asm volatile("fence" ::: "memory");
    uint32_t end = mempool_get_timer();
    q_core_compute[cid][0] += end - begin;
    if (!cid)
      e->compute_end = end;
    q_join();
    if (!cid) {
      e->joined = mempool_get_timer();
      if (t + 1 < Q_HIDDEN / Q_KT) {
        if (!Q_OVERLAP)
          dma_memcpy_nonblocking(q_weights[1 - b],
                                 source + (t + 1) * Q_WEIGHT_ELEMENTS,
                                 sizeof(q_weights[0]));
        dma_wait();
      }
      e->ready = mempool_get_timer();
    }
    q_join();
  }
  q_store(cid, q_output[stage]);
  q_join();
  if (!cid)
    q_projection_end[stage] = mempool_get_timer();
}

int main(void) {
  uint32_t cid = mempool_get_core_id();
  mempool_barrier_init(cid);
  q_core_compute[cid][0] = 0;
  q_status[cid][0] = 0;
  if (!cid)
    q_join_count = 0;
  mempool_barrier(NUM_CORES);
  if (mshr_cfg_is_group_writer()) {
    // Distinct weights: one subscriber bypasses retention for each class.
    // Keep admission enabled, with no assumed four-way GEMM sharing.
    const mshr_cfg_t cfg = {.hold_subs_single = 1,
                            .hold_subs_burst = 1,
                            .hold_window_single = 1,
                            .hold_window_burst = 1,
                            .serve_timeout = 64,
                            .bank_shift_single = 4,
                            .bank_shift_burst = 4,
                            .bank_burst_bits = 0,
                            .cache_reuse_target = 0,
                            .cache_timeout = 0,
                            .bankfull_backpressure = 1};
    q_status[cid][0] = mshr_cfg_apply_group(&cfg);
#if Q_GROUP_BARRIER
    uint32_t ctrl = GROUP_CONTROL_BASE + GROUP_BARRIER_WORD * MSHR_WORD_STRIDE +
                    (cid / NUM_CORES_PER_GROUP) * MSHR_GROUP_STRIDE;
    *(volatile uint32_t *)(ctrl + 4) = NUM_CORES_PER_GROUP;
    *(volatile uint32_t *)(ctrl + 8) = (1u << NUM_CORES_PER_GROUP) - 1;
#endif
  }
  q_join();
  if (!cid) {
    q_complete = 0;
    printf("[GATEUP] groups=%u batch=%u rows=%u teams=%u k=%u p=%u kt=%u "
           "overlap=%u ctrl=0x%x\n",
           NUM_GROUPS, Q_BATCH, Q_ROWS, Q_TEAMS, Q_HIDDEN, Q_INTERMEDIATE, Q_KT,
           Q_OVERLAP, GROUP_CONTROL_BASE);
    for (uint32_t c = 0; c < NUM_CORES; c += NUM_CORES_PER_GROUP)
      printf("[GUCSR] group=%u status=%u single=1 burst=1 reuse=0\n",
             c / NUM_CORES_PER_GROUP, q_status[c][0]);
  }
  q_join();
  mempool_start_benchmark();
  if (!cid) {
    q_benchmark_begin = mempool_get_timer();
    for (uint32_t g = 0; g < Q_X_REPLICAS; ++g)
      dma_memcpy_blocking(q_x + g * Q_X_REPLICA_ELEMENTS, q_x_data,
                          Q_BATCH * Q_HIDDEN * sizeof(_Float16));
  }
  q_join();
  for (uint32_t repeat = 0; repeat < Q_REPEATS; ++repeat) {
    q_project(0, cid, q_gate_weights);
    q_project(1, cid, q_up_weights);
  }
  if (!cid)
    q_benchmark_end = mempool_get_timer();
  mempool_stop_benchmark();
  q_join();
  if (!cid) {
    q_complete = 0x5157454e;
    printf("[GATEUP] completed cycles=%u\n",
           q_benchmark_end - q_benchmark_begin);
  }
  q_join();
  return q_status[cid][0] ? 2 : 0;
}
