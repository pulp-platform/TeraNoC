// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
#include "dma.h"
#include "mshr_cfg.h"
#include "printf.h"
#include "qwen_config.h"
#include "runtime.h"
#include "synchronization.h"

_Static_assert(NUM_CORES_PER_TILE * N_FU * BANKING_FACTOR == 16 &&
                   N_FU == 4 && VLEN == 512,
               "Vector segmentation requires the Spatz4 16-bank tile geometry");
_Static_assert(Q_PT % 32 == 0, "Weight row strides must preserve tile alignment");

#define Q_L1 __attribute__((section(".l1_prio"), aligned(64 * NUM_CORES)))
extern const _Float16 q_x_data[], q_gate_weights[], q_up_weights[];
extern _Float16 q_output_l2[];
static _Float16 q_weights[2][Q_KT * Q_PT] Q_L1;
static _Float16 q_x[2][NUM_GROUPS * Q_X_STRIDE] Q_L1;
static _Float16 q_partial[Q_BATCH * Q_PT] Q_L1;
uint32_t q_status[NUM_CORES][16] Q_L1;
uint32_t q_core_compute[NUM_CORES][16] Q_L1;
uint32_t q_complete Q_L1;
static volatile uint32_t q_join_count Q_L1;
uint32_t q_projection_begin[2] Q_L1, q_projection_end[2] Q_L1;
uint32_t q_dma_stats[8] Q_L1;
typedef struct {
  uint32_t stage, tile, begin, compute_end, joined, ready;
} q_event_t;
q_event_t q_events[2 * Q_PANELS * Q_STEPS] Q_L1;
static uint32_t q_retired[2];
#include "csr_config.h"

static inline void q_join(void) {
  asm volatile("fence" ::: "memory");
  uint32_t cid = mempool_get_core_id(), group = cid / NUM_CORES_PER_GROUP;
  uint32_t ctrl = GROUP_CONTROL_BASE + GROUP_BARRIER_WORD * MSHR_WORD_STRIDE +
                  group * MSHR_GROUP_STRIDE +
                  (cid % NUM_CORES_PER_GROUP) * MSHR_TILE_STRIDE;
  uint32_t unused;
  asm volatile("lw %0, 0(%1)" : "=r"(unused) : "r"(ctrl) : "memory");
  if (cid % NUM_CORES_PER_GROUP == 0 &&
      __atomic_fetch_add(&q_join_count, 1, __ATOMIC_RELAXED) ==
          NUM_GROUPS - 1) {
    __atomic_store_n(&q_join_count, 0, __ATOMIC_RELAXED);
    asm volatile("fence" ::: "memory");
    wake_up_all();
  }
  mempool_wfi();
}

#include "microkernel.h"

static void q_fill(uint32_t slot, uint32_t panel, uint32_t step,
                   const _Float16 *weights) {
  // All readers of this slot have drained. Bound cached-line lifetime before
  // DMA overwrites a reused address; this is shared by both control mappings.
  uint32_t start = mempool_get_timer();
  while ((uint32_t)(mempool_get_timer() - q_retired[slot]) < Q_REUSE_GUARD)
    ;
  q_dma_stats[3] += mempool_get_timer() - start;
  const _Float16 *x = q_x_data + step * NUM_GROUPS * Q_X_STRIDE;
  // Replicas are packed in the immutable L2 input. Two accepted DMA launches
  // fill X and weights without a serial per-group launch loop on core 0.
  dma_memcpy_nonblocking(q_x[slot], x, sizeof(q_x[0]));
  dma_memcpy_nonblocking(q_weights[slot],
                         weights + (panel * Q_STEPS + step) * Q_KT * Q_PT,
                         sizeof(q_weights[0]));
  q_dma_stats[0] += sizeof(q_weights[0]);
  q_dma_stats[1] += sizeof(q_x[0]);
}

static void q_project(uint32_t stage, uint32_t cid, const _Float16 *weights) {
  if (!cid) {
    write_csr(trace, 3 + 4 * stage);
    q_projection_begin[stage] = mempool_get_timer();
  }
  for (uint32_t panel = 0; panel < Q_PANELS; ++panel) {
    q_zero(cid);
    q_join();
    if (!cid) {
      q_fill(0, panel, 0, weights);
      dma_wait();
    }
    q_join();
    for (uint32_t step = 0; step < Q_STEPS; ++step) {
      uint32_t slot = step & 1;
      q_event_t *e = &q_events[(stage * Q_PANELS + panel) * Q_STEPS + step];
      if (!cid) {
        e->stage = stage;
        e->tile = panel * Q_STEPS + step;
        e->begin = mempool_get_timer();
        if (step + 1 < Q_STEPS)
          q_fill(1 - slot, panel, step + 1, weights);
      }
      uint32_t begin = mempool_get_timer();
      q_compute(cid, slot, panel, step);
      asm volatile("fence" ::: "memory");
      uint32_t end = mempool_get_timer();
      q_core_compute[cid][0] += end - begin;
      if (!cid)
        e->compute_end = end;
      q_join();
      if (!cid) {
        e->joined = mempool_get_timer();
        q_retired[slot] = e->joined;
        if (step + 1 < Q_STEPS)
          dma_wait();
        e->ready = mempool_get_timer();
      }
      q_join();
    }
    if (!cid) {
      dma_memcpy_blocking(q_output_l2 +
                              (stage * Q_PANELS + panel) * Q_BATCH * Q_PT,
                          q_partial, sizeof(q_partial));
      q_dma_stats[2] += sizeof(q_partial);
    }
    q_join();
  }
  if (!cid) {
    write_csr(trace, 5 + 4 * stage);
    q_projection_end[stage] = mempool_get_timer();
  }
}

int main(void) {
  uint32_t cid = mempool_get_core_id(), group = cid / NUM_CORES_PER_GROUP;
  mempool_barrier_init(cid);
  q_status[cid][0] = 0;
  q_core_compute[cid][0] = 0;
  if (!cid) {
    q_join_count = 0;
    q_complete = 0;
    q_retired[0] = q_retired[1] = mempool_get_timer() - Q_REUSE_GUARD;
    for (uint32_t i = 0; i < 8; ++i)
      q_dma_stats[i] = 0;
  }
  mempool_barrier(NUM_CORES);
  if (mshr_cfg_is_group_writer()) {
    mshr_cfg_t cfg = q_csr[group];
    q_status[cid][0] = mshr_cfg_apply_group(&cfg);
    // Rearm after configuration writes; all 16 cores participate in each join.
    uint32_t ctrl = GROUP_CONTROL_BASE + GROUP_BARRIER_WORD * MSHR_WORD_STRIDE +
                    group * MSHR_GROUP_STRIDE;
    *(volatile uint32_t *)(ctrl + 4) = NUM_CORES_PER_GROUP;
    *(volatile uint32_t *)(ctrl + 8) = (1u << NUM_CORES_PER_GROUP) - 1;
  }
  q_join();
  if (!cid)
    printf(
        "[GATEUP] mapping=%u groups=%u batch=%u ks=%u blocks=%u pt=%u kt=%u\n",
        Q_MATMUL, NUM_GROUPS, Q_BATCH, Q_ROWS, Q_PBLOCKS, Q_PT, Q_KT);
  q_join();
  mempool_start_benchmark();
  for (uint32_t repeat = 0; repeat < Q_REPEATS; ++repeat) {
    q_project(0, cid, q_gate_weights);
    q_project(1, cid, q_up_weights);
  }
  mempool_stop_benchmark();
  q_join();
  if (!cid) {
    q_complete = 0x5157454e;
    printf("[GATEUP] completed\n");
  }
  q_join();
  return q_status[cid][0] ? 2 : 0;
}
