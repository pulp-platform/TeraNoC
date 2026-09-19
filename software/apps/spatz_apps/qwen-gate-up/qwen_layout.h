// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Where X lives in L1, shared by the app and by the build-time hash generator so
// the two cannot disagree about an address.
#ifndef QWEN_LAYOUT_H
#define QWEN_LAYOUT_H

#include "data/qwen_shape.h"

// How far a buffer must move to land on the next group of the word-interleaved
// L1. Same derivation as arch.ld.c and the kernel's gbar_base().
#define QWEN_GROUP_STRIDE \
  (4 * (N_FU) * (BANKING_FACTOR) * (NUM_CORES_PER_TILE) * (NUM_TILES_PER_GROUP))
#define QWEN_MESH_SWEEP ((NUM_GROUPS) * (QWEN_GROUP_STRIDE))

// X is read by every core, so a single copy makes its few groups a hot spot. One
// copy per neighbourhood removes both the contention and the distance -- but only
// while X is small enough to sit in fewer groups than the mesh has. Past that it
// already spans every group, so replication would buy nothing and cost L1.
#define QWEN_P2_UP(n)                                                        \
  ((n) <= 1 ? 1 : (n) <= 2 ? 2 : (n) <= 4 ? 4 : (n) <= 8 ? 8 : (n) <= 16 ? 16 \
   : (n) <= 32 ? 32 : (n) <= 64 ? 64 : (n))

#define QWEN_X_BYTES ((GEMM_M) * (GEMM_N)*GEMM_ELEM_BYTES)
// Groups one copy covers, rounded up to a power of two so the replicas always
// tile the mesh evenly instead of falling off a divisibility cliff.
#define QWEN_X_SPAN \
  QWEN_P2_UP(((QWEN_X_BYTES) + (QWEN_GROUP_STRIDE)-1) / (QWEN_GROUP_STRIDE))
#define QWEN_X_REPLICAS \
  ((QWEN_X_SPAN) >= (NUM_GROUPS) ? 1 : (NUM_GROUPS) / (QWEN_X_SPAN))
#define QWEN_X_GROUPS_PER_REPLICA ((NUM_GROUPS) / (QWEN_X_REPLICAS))
#define QWEN_X_STRIDE_B ((QWEN_X_GROUPS_PER_REPLICA) * (QWEN_GROUP_STRIDE))
#define QWEN_X_STRIDE_E ((QWEN_X_STRIDE_B) / GEMM_ELEM_BYTES)
// Replicated, X is spread over exactly one mesh sweep whatever the batch is.
#define QWEN_X_ELEMS                                       \
  ((QWEN_X_REPLICAS) > 1 ? (QWEN_X_REPLICAS) * (QWEN_X_STRIDE_E) \
                         : (GEMM_M) * (GEMM_N))
#define QWEN_X_REPLICA_OF(group) ((group) / (QWEN_X_GROUPS_PER_REPLICA))

#endif
