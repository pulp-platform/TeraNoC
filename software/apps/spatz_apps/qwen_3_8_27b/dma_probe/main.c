// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
#include "qwen_config.h"
#include "runtime.h"
#include "synchronization.h"
#include "dma.h"
#include "printf.h"
#define ALIGN (4*N_FU*BANKING_FACTOR*NUM_CORES)
#define GROUP_STRIPE (4*N_FU*BANKING_FACTOR*NUM_CORES_PER_GROUP)
#define WORDS (Q_BATCH*Q_HIDDEN)
#define SLOT_WORDS (((WORDS*4+ALIGN-1)/ALIGN)*ALIGN/4)
extern const uint32_t q_gate_weights[];
uint32_t q_buffers[2][SLOT_WORDS] __attribute__((section(".l1_prio"),aligned(ALIGN)));
uint32_t q_output[8][WORDS] __attribute__((section(".l1_prio"),aligned(ALIGN)));
uint32_t q_complete __attribute__((section(".l1_prio"),aligned(ALIGN)));
int main(void) {
 uint32_t cid=mempool_get_core_id();mempool_barrier_init(cid);
 mempool_start_benchmark();
 if(!cid) {
  for(uint32_t round=0;round<8;round+=2) {
   // Independent descriptors, different L2 bank mappings, two reused slots.
   for(uint32_t slot=0;slot<2;++slot) {
    uint32_t i=round+slot,offset=i*WORDS+(i%2)*GROUP_STRIPE/4;
    dma_memcpy_nonblocking(q_buffers[slot],q_gate_weights+offset,WORDS*4);
   }
   dma_wait();
   for(uint32_t slot=0;slot<2;++slot)
    for(uint32_t i=0;i<WORDS;++i)q_output[round+slot][i]=q_buffers[slot][i];
  }
  q_complete=8;
 }
 mempool_barrier(NUM_CORES);mempool_stop_benchmark();
 if(!cid)printf("[DMA_PROBE] bytes=%u copies=%u complete\n",WORDS*4,8);
 mempool_barrier(NUM_CORES);return 0;
}
