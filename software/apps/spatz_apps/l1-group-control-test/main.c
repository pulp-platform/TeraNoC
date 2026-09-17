// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0

#include "dma.h"
#include "mshr_cfg.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"
#include <stdint.h>

#define BANKS_PER_TILE (N_FU * BANKING_FACTOR * NUM_CORES_PER_TILE)
#define TILE_STRIDE (4u * BANKS_PER_TILE)
#define GROUP_STRIDE (TILE_STRIDE * NUM_TILES_PER_GROUP)
#define WORD_STRIDE (GROUP_STRIDE * NUM_GROUPS)
#define L1_BYTES (NUM_CORES * N_FU * BANKING_FACTOR * L1_BANK_SIZE)
#define TOP_SLICE (L1_BYTES - WORD_STRIDE)

// No heap allocation: this test owns the last word slice of physical L1.
// Preload expected data in L2 so setup does not dominate full-system
// simulation.
#define PATTERN(i) (0x6ac00000u ^ ((i)*0x10203u))
#define DATA4(i)                                                               \
  PATTERN(i), PATTERN((i) + 1), PATTERN((i) + 2), PATTERN((i) + 3)
#define DATA16(i) DATA4(i), DATA4((i) + 4), DATA4((i) + 8), DATA4((i) + 12)
#define DATA64(i)                                                              \
  DATA16(i), DATA16((i) + 16), DATA16((i) + 32), DATA16((i) + 48)
#define DATA256(i)                                                             \
  DATA64(i), DATA64((i) + 64), DATA64((i) + 128), DATA64((i) + 192)
#define DATA1024(i)                                                            \
  DATA256(i), DATA256((i) + 256), DATA256((i) + 512), DATA256((i) + 768)
#define DATA4096(i)                                                            \
  DATA1024(i), DATA1024((i) + 1024), DATA1024((i) + 2048), DATA1024((i) + 3072)
#define DATA16384(i)                                                           \
  DATA4096(i), DATA4096((i) + 4096), DATA4096((i) + 8192), DATA4096((i) + 12288)
static const uint32_t source[16384]
    __attribute__((section(".l2"), aligned(WORD_STRIDE))) = {DATA16384(0)};
_Static_assert(WORD_STRIDE <= sizeof(source),
               "Test source must cover the word slice");
_Static_assert(NUM_CORES_PER_GROUP < 32, "Test mask must fit in one word");
static volatile uint32_t errors __attribute__((section(".l1")));
static volatile uint32_t arrived[NUM_CORES] __attribute__((section(".l1")));

static uint32_t pattern(uint32_t index) {
  return 0x6ac00000u ^ (index * 0x10203u);
}

int main(void) {
  uint32_t core = mempool_get_core_id();
  uint32_t group = core / NUM_CORES_PER_GROUP;
  uint32_t lane = core % NUM_CORES_PER_GROUP;
  uint32_t tile = lane / NUM_CORES_PER_TILE;
  mempool_barrier_init(core);
  // Static storage only. Disable MSHR holding so scalar routing checks do not
  // inherit the benchmark's long merge windows.
  if (lane == 0)
    mshr_cfg_write(group, tile, MSHR_CSR_ENABLE, 0);
  mempool_barrier(NUM_CORES);
  if (core == 0) {
    printf("[L1CTRL] start groups=%u\n", NUM_GROUPS);
    errors = 0;
    dma_memcpy_blocking((void *)TOP_SLICE, source, WORD_STRIDE);
    printf("[L1CTRL] DMA done\n");
  }
  mempool_barrier(NUM_CORES);

  // Read the DMA data from own tile, another local tile, and another group.
  for (uint32_t route = 0; route < 3; ++route) {
    uint32_t dest_group = route == 2 ? (group + 1) % NUM_GROUPS : group;
    uint32_t dest_tile = route == 0 ? tile : (tile + 1) % NUM_TILES_PER_GROUP;
    uint32_t offset = dest_group * GROUP_STRIDE + dest_tile * TILE_STRIDE;
    for (uint32_t bank = 0; bank < BANKS_PER_TILE; ++bank) {
      uint32_t index = offset / 4 + bank;
      volatile uint32_t *p = (volatile uint32_t *)(TOP_SLICE + index * 4);
      if (*p != pattern(index))
        __atomic_fetch_add(&errors, 1, __ATOMIC_RELAXED);
    }
  }
  mempool_barrier(NUM_CORES);

  // Use an OWN-TILE control target, which must bypass the local SRAM path.
  uint32_t ctrl = GROUP_CONTROL_BASE + GROUP_BARRIER_WORD * WORD_STRIDE +
                  group * GROUP_STRIDE + tile * TILE_STRIDE;
  if (lane == 0) {
    *(volatile uint32_t *)(ctrl + 4) = NUM_CORES_PER_GROUP;
    *(volatile uint32_t *)(ctrl + 8) = (1u << NUM_CORES_PER_GROUP) - 1u;
    mshr_cfg_write(group, tile, MSHR_CSR_STATUS, 0);
    if (mshr_cfg_status(group, tile) != 0)
      __atomic_fetch_add(&errors, 1, __ATOMIC_RELAXED);
  }
  mempool_barrier(NUM_CORES);
  for (uint32_t round = 1; round <= 2; ++round) {
    // Deliberately skew arrivals; a response must wait for every participant.
    if (lane == NUM_CORES_PER_GROUP - 1)
      for (volatile uint32_t delay = 0; delay < 200; ++delay) {
      }
    arrived[core] = round;
    asm volatile("fence" ::: "memory");
    uint32_t value;
    asm volatile("lw %0, 0(%1)" : "=r"(value) : "r"(ctrl) : "memory");
    asm volatile("fence" ::: "memory");
    for (uint32_t peer = 0; peer < NUM_CORES_PER_GROUP; ++peer)
      if (arrived[group * NUM_CORES_PER_GROUP + peer] < round)
        __atomic_fetch_add(&errors, 1, __ATOMIC_RELAXED);
    mempool_barrier(NUM_CORES);
  }
  if (core == 0)
    printf("[L1CTRL] top=0x%x bytes=%u groups=%u errors=%u\n", TOP_SLICE,
           WORD_STRIDE, NUM_GROUPS, errors);
  mempool_barrier(NUM_CORES);
  return (int)errors;
}
