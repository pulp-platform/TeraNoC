// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "qwen_config.h"
#include "runtime.h"
#include "synchronization.h"
#include "dma.h"
#include "printf.h"

// Reuse the benchmark microkernels without their application harness. Outer
// synchronization belongs to the streaming scheduler, with whole active groups.
#define GROUP_BARRIER 0
#define GBAR_PLOOP 0
#define GEMM_M Q_BATCH
#define GEMM_N Q_KT
#define GEMM_P Q_PT
#define GEMM_ELEM_BYTES (Q_PRECISION / 8)
#define KERNEL_SIZE Q_KS
#define ACTIVE_GROUP_DIV (NUM_GROUPS / Q_ACTIVE_GROUPS)
#define MATMUL_DECODE_SPLIT 1
#include "gemm_config.h"
#include "gemm_burst.h"
// The private build adapts only C's row stride, preserving the existing ASM.
#define Q_C_STRIDE (4 * N_FU * BANKING_FACTOR * NUM_CORES / (Q_PRECISION/8))
#if Q_PRECISION == 32
typedef float elem_t;
#endif
#include "qwen_microkernel.h"
#include "mshr_cfg.h"
#include "gemm_hash.h"

#define Q_PAD(n,t) (((n) + (t) - 1) / (t) * (t))
#define Q_MAX(a,b) ((a) > (b) ? (a) : (b))
#define Q_ALIGN (4 * N_FU * BANKING_FACTOR * NUM_CORES)
#define Q_L1 __attribute__((section(".l1_prio"), aligned(Q_ALIGN)))
#define Q_ACTIVE_CORES (Q_ACTIVE_GROUPS * NUM_CORES_PER_GROUP)
#define Q_ROW_CHUNKS (Q_BATCH / Q_KS)
#define Q_COL_CHUNKS (Q_ACTIVE_CORES / Q_ROW_CHUNKS)
#define Q_SPAN (Q_PT / Q_COL_CHUNKS)
#define Q_MAX_K Q_MAX(Q_PAD(Q_HIDDEN,Q_KT), Q_PAD(Q_INTERMEDIATE,Q_KT))
#define Q_MAX_EVENTS (2*(Q_PAD(Q_HIDDEN,Q_KT)/Q_KT)*(Q_PAD(Q_INTERMEDIATE,Q_PT)/Q_PT)+(Q_PAD(Q_INTERMEDIATE,Q_KT)/Q_KT)*(Q_PAD(Q_HIDDEN,Q_PT)/Q_PT))

_Static_assert(Q_KT >= 2 && Q_KT % 2 == 0, "Microkernel requires even K >= 2");
_Static_assert(Q_BATCH % Q_KS == 0 && Q_ACTIVE_CORES % Q_ROW_CHUNKS == 0,
               "Invalid row partition");
_Static_assert(Q_PT % Q_COL_CHUNKS == 0 && Q_SPAN * sizeof(elem_t) >= 8,
               "Use fewer active groups or a wider column tile");

extern const elem_t q_x_data[], q_gate_weights[], q_up_weights[], q_down_weights[];
// Pad buffers through the largest address bit used by the hash selector.
#define Q_HASH_PERIOD (4u << (10+4))
#define Q_WEIGHT_E (Q_PAD(Q_KT * Q_PT * sizeof(elem_t), Q_HASH_PERIOD)/sizeof(elem_t))
#define Q_ACC_ROWS Q_PAD(Q_KS * Q_SPAN, 16)/16
static elem_t q_weights[2][Q_WEIGHT_E] Q_L1;
// One 64-byte bank stripe per tile. Advancing a mesh stripe preserves ownership.
static elem_t q_partial[Q_KS * Q_C_STRIDE] Q_L1;
static float q_acc[2][Q_ACC_ROWS * Q_ALIGN/4] Q_L1;
elem_t q_h[Q_BATCH * Q_INTERMEDIATE] Q_L1;
static elem_t q_input[2][Q_PAD(Q_BATCH * Q_MAX_K * sizeof(elem_t), Q_HASH_PERIOD)/sizeof(elem_t)] Q_L1;
float q_output[Q_BATCH * Q_HIDDEN] Q_L1;
static uint32_t q_core_end[NUM_CORES] Q_L1;
uint32_t q_core_compute[NUM_CORES * 16] Q_L1;
uint32_t q_runtime_status[NUM_GROUPS] Q_L1;
static uint32_t q_config_report[7][Q_ALIGN/4] Q_L1;
uint32_t q_complete Q_L1;

typedef struct {
  uint32_t stage, p, k, buffer, begin, issue_begin, issue_end;
  uint32_t compute_begin, compute_end, joined, wait_begin, ready, end;
} q_event_t;
q_event_t q_events[Q_MAX_EVENTS] Q_L1;
uint32_t q_event_count Q_L1;
uint32_t q_benchmark_begin Q_L1, q_benchmark_end Q_L1;

static inline void q_drain(void) { asm volatile("fence" ::: "memory"); }
static inline void q_barrier(void) {
  q_drain();
  mempool_barrier(NUM_CORES);
}

// Producer-owned FP32 scratch bypasses the remote source-group MSHR.
static inline uint32_t q_acc_index(uint32_t cid, uint32_t i) {
  return (i/16)*(Q_ALIGN/4) + cid*16 + i%16;
}

static void q_configure(uint32_t cid) {
  if (mshr_cfg_is_group_writer()) {
    uint32_t g = mempool_get_group_id();
    mshr_cfg_t cfg = MSHR_CFG_DERIVED_INIT;
    // Freeze one hash for the projection schedule. Buffer stride is a multiple
    // of the full mesh stripe. Check both addresses in the host manifest.
    if (g < Q_ACTIVE_GROUPS)
      gemm_hash_select((uint32_t)q_input, (uint32_t)q_weights[0], g,
                      MSHR_CFG_ENTRIES / MSHR_CFG_WAYS,
                      &cfg.bank_shift_single, &cfg.bank_shift_burst,
                      &cfg.bank_burst_bits);
    q_runtime_status[g] = mshr_cfg_apply_group(&cfg);
    q_config_report[0][g]=cfg.hold_subs_single;
    q_config_report[1][g]=cfg.hold_subs_burst;
    q_config_report[2][g]=cfg.cache_reuse_target;
    q_config_report[3][g]=cfg.bank_shift_single;
    q_config_report[4][g]=cfg.bank_shift_burst;
    q_config_report[5][g]=cfg.bank_burst_bits;
    q_config_report[6][g]=q_runtime_status[g];
  }
  q_barrier();
  if(!cid)for(uint32_t g=0;g<NUM_GROUPS;++g)
    printf("[QCSR] %u %u %u %u %u %u %u %u\n",g,q_config_report[0][g],q_config_report[1][g],q_config_report[2][g],q_config_report[3][g],q_config_report[4][g],q_config_report[5][g],q_config_report[6][g]);
  q_barrier();
}

// Keep the larger FP32 wrapper separate and its scalar accumulation compact.
// Inlining/unrolling those loops can exceed the 512-byte per-core stack.
#if Q_PRECISION == 32 && Q_KS >= 4
#define Q_COMPACT_LOOP _Pragma("clang loop unroll(disable)")
__attribute__((noinline))
#else
#define Q_COMPACT_LOOP
#endif
static void q_microkernel(uint32_t cid, uint32_t k, uint32_t buffer,
                          uint32_t acc, uint32_t stage) {
  uint32_t row = (cid % Q_ROW_CHUNKS) * Q_KS;
  uint32_t col = (cid / Q_ROW_CHUNKS) * Q_SPAN;
  const elem_t *a = q_input[stage == 3] + k * Q_BATCH * Q_KT + row * Q_KT;
  elem_t *partial = q_partial + cid * (64/sizeof(elem_t));
  for (uint32_t j=0;j<Q_SPAN;j+=64/sizeof(elem_t)) {
    uint32_t span=Q_SPAN-j;
    if(span>64/sizeof(elem_t))span=64/sizeof(elem_t);
#if Q_KS == 1
    matmul_1xVL(partial, a, q_weights[buffer]+col+j, 0, Q_KS,
                Q_KT, Q_PT, 0, span);
#elif Q_KS == 2
    matmul_2xVL(partial, a, q_weights[buffer]+col+j, 0, Q_KS,
                Q_KT, Q_PT, 0, span);
#elif Q_KS == 4
    matmul_4xVL(partial, a, q_weights[buffer]+col+j, 0, Q_KS,
                Q_KT, Q_PT, 0, span);
#else
    matmul_8xVL(partial, a, q_weights[buffer]+col+j, 0, Q_KS,
                Q_KT, Q_PT, 0, span);
#endif
    q_drain();
    Q_COMPACT_LOOP
    for(uint32_t m=0;m<Q_KS;++m)
      Q_COMPACT_LOOP
      for(uint32_t z=0;z<span;++z)
        q_acc[acc][q_acc_index(cid,m*Q_SPAN+j+z)] += (float)partial[m*Q_C_STRIDE+z];
    q_drain();
  }
}

// The existing kernel produces one partial product in its native precision.
// Outer K-tile sums are FP32. This is explicitly distinct from a widening-FMA
// kernel with FP32 accumulation for every multiply.
static void q_project_tile(uint32_t stage, uint32_t p, uint32_t width,
                           const elem_t *weights, uint32_t acc, uint32_t cid) {
  const uint32_t blocks = Q_PAD(width,Q_KT) / Q_KT;
  const uint32_t bytes = Q_KT * Q_PT * sizeof(elem_t);
  const elem_t *base = weights + p * blocks * Q_KT * Q_PT;
  if(cid < Q_ACTIVE_CORES)
    for (uint32_t i=0;i<Q_KS*Q_SPAN;++i) q_acc[acc][q_acc_index(cid,i)] = 0;
  if (!cid) dma_memcpy_blocking(q_weights[0], base, bytes);
  q_barrier();
  for (uint32_t k = 0; k < blocks; ++k) {
    uint32_t buffer = k % 2;
    q_event_t *e = cid ? (q_event_t *)0 : &q_events[q_event_count];
    if (!cid) {
      e->stage=stage; e->p=p; e->k=k; e->buffer=buffer;
      e->begin=mempool_get_timer();
      e->issue_begin=mempool_get_timer();
      if (Q_OVERLAP && k+1 < blocks)
        dma_memcpy_nonblocking(q_weights[1-buffer], base+(k+1)*Q_KT*Q_PT, bytes);
      e->issue_end=mempool_get_timer();
    }
    q_barrier();
    uint32_t start=mempool_get_timer();
    if (!cid) e->compute_begin=start;
    if (cid < Q_ACTIVE_CORES) {
      q_microkernel(cid,k,buffer,acc,stage);
      q_drain();
      q_core_end[cid]=mempool_get_timer();
      q_core_compute[cid*16] += q_core_end[cid]-start;
    } else q_core_end[cid]=0;
    q_barrier();
    if (!cid) {
      e->joined=mempool_get_timer();
      e->compute_end=0;
      for(uint32_t c=0;c<Q_ACTIVE_CORES;++c)
        if(q_core_end[c]>e->compute_end)e->compute_end=q_core_end[c];
      e->wait_begin=mempool_get_timer();
      if(k+1<blocks) {
        if(!Q_OVERLAP)
          dma_memcpy_nonblocking(q_weights[1-buffer],base+(k+1)*Q_KT*Q_PT,bytes);
        dma_wait();
      }
      e->ready=mempool_get_timer();
      e->end=e->ready;
      ++q_event_count;
    }
    q_barrier();
  }
}

// Stable SiLU without hardware division or exp instructions. Range-reduced
// exp(-abs(x)) uses a sixth-order polynomial; five reciprocal Newton steps
// cover [1,2]. Validate this approximation independently against host exp.
static float q_silu(float x) {
  float a = x < 0 ? -x : x;
  if (a > 80.0f) return x < 0 ? 0.0f : x;
  uint32_t n = 0;
  while (a > 0.6931471805599453f) { a -= 0.6931471805599453f; ++n; }
  float r = -a;
  float z = 1.0f+r*(1.0f+r*(0.5f+r*(0.1666666667f+r*(0.0416666667f+
            r*(0.0083333333f+r*0.0013888889f)))));
  union { uint32_t bits; float value; } scale;
  scale.bits = (127u-n)<<23;
  z *= scale.value;
  float d = 1.0f+z, inv = 0.75f;
  for(uint32_t i=0;i<5;++i)inv *= 2.0f-d*inv;
  return x * (x < 0 ? z*inv : inv);
}

static int q_main(uint32_t ffn) {
  uint32_t cid=mempool_get_core_id();
  mempool_barrier_init(cid);
  q_core_compute[cid*16]=0;
  if(!cid) { q_complete=0; q_event_count=0; }
  q_barrier();
  q_configure(cid);
  uint32_t bad=mshr_cfg_status(mshr_cfg_my_group(),mshr_cfg_peer_tile());
  if(bad) return 2;
  if(!cid) printf("[QCONFIG] mesh=%u active_groups=%u batch=%u hidden=%u intermediate=%u kt=%u pt=%u ks=%u precision=%u overlap=%u\n",
    NUM_GROUPS,Q_ACTIVE_GROUPS,Q_BATCH,Q_HIDDEN,Q_INTERMEDIATE,Q_KT,Q_PT,Q_KS,Q_PRECISION,Q_OVERLAP);
  q_barrier();
  mempool_start_benchmark();
  if(!cid) {
    q_benchmark_begin=mempool_get_timer();
    dma_memcpy_blocking(q_input[0],q_x_data,Q_BATCH*Q_PAD(Q_HIDDEN,Q_KT)*sizeof(elem_t));
  }
  q_barrier();
  for(uint32_t p=0;p<Q_PAD(Q_INTERMEDIATE,Q_PT)/Q_PT;++p) {
    q_project_tile(1,p,Q_HIDDEN,q_gate_weights,0,cid);
    if(ffn)q_project_tile(2,p,Q_HIDDEN,q_up_weights,1,cid);
    if(cid<Q_ACTIVE_CORES)for(uint32_t i=0;i<Q_KS*Q_SPAN;++i) {
      uint32_t row=(cid%Q_ROW_CHUNKS)*Q_KS+i/Q_SPAN;
      uint32_t col=p*Q_PT+(cid/Q_ROW_CHUNKS)*Q_SPAN+i%Q_SPAN;
      uint32_t ai=q_acc_index(cid,i);
      if(col<Q_INTERMEDIATE) {
        elem_t value=(elem_t)(ffn ? q_silu(q_acc[0][ai])*q_acc[1][ai] : q_acc[0][ai]);
        q_h[row*Q_INTERMEDIATE+col]=value;
        // Store the next projection's packed A directly; no unshared readback.
        q_input[1][(col/Q_KT)*Q_BATCH*Q_KT+row*Q_KT+col%Q_KT]=value;
      }
    }
    q_barrier();
  }
  if(ffn) {
    for(uint32_t p=0;p<Q_PAD(Q_HIDDEN,Q_PT)/Q_PT;++p) {
      q_project_tile(3,p,Q_INTERMEDIATE,q_down_weights,0,cid);
      if(cid<Q_ACTIVE_CORES)for(uint32_t i=0;i<Q_KS*Q_SPAN;++i) {
        uint32_t row=(cid%Q_ROW_CHUNKS)*Q_KS+i/Q_SPAN;
        uint32_t col=p*Q_PT+(cid/Q_ROW_CHUNKS)*Q_SPAN+i%Q_SPAN;
        if(col<Q_HIDDEN)q_output[row*Q_HIDDEN+col]=q_acc[0][q_acc_index(cid,i)];
      }
      q_barrier();
    }
  }
  q_barrier();
  if(!cid) { q_benchmark_end=mempool_get_timer(); q_complete=0x5157454e; }
  mempool_stop_benchmark();
  q_barrier();
  if(!cid) {
    printf("[QRESULT] cycles=%u events=%u complete=%u\n",q_benchmark_end-q_benchmark_begin,q_event_count,q_complete);
    // The host reads q_events from the L1 dump; avoid UART and remote reads.

  }
  q_barrier();
  return 0;
}
