// Copyright 2023 ETH Zurich and University of Bologna.
//
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Author: Matteo Perotti <mperotti@iis.ee.ethz.ch>

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h>

#include "data/data_fconv2d.h"

#include "kernel/fconv2d.c"
#include "dma.h"
#include "printf.h"
#ifdef MEMPOOL
#include "alloc.h"
#include "runtime.h"
#include "synchronization.h"
#endif

// Perform a final check with the golden model
#define CHECK
// Print per-core info about per-core variables
#define VERBOSE

// Threshold for FP comparisons
#define THRESHOLD 0.000000001

#define OVERLAP(a0,a1,b0,b1) (!((a1) < (b0) || (b1) < (a0)))

// Macro to check similarity between two fp-values, wrt a threshold
// #define fp_check(a, b, threshold)
//   ((((a) < (b)) ? (b) - (a) : (a) - (b)) < (threshold))

// Verify the matrices
int verify_matrix(float *matrix, const float *golden, const unsigned int size) {
  int error = 0;
  for (unsigned int j = 0; j < size; ++j) {
    float diff = matrix[j] - golden[j];
    if (diff < 0)
      diff = -diff;
    if (diff > 0.01f)
      error ++;
  }
  return error;
}

// // Matrices
// float *imtx;
// float *omtx;
// float *fmtx;

// Initialize the matrices
void init_matrix(float *matrix, const float *src, const unsigned int len) {
  for (unsigned int i = 0; i < len; ++i) {
    matrix[i] = src[i];
  }
}


int main() {


  const unsigned int num_cores = mempool_get_core_count();
  const unsigned int cores_per_group = num_cores / NUM_GROUPS;
  const unsigned int cid = mempool_get_core_id();

  //const unsigned int active_groups = 1;
  //const unsigned int active_cores = cores_per_group * active_groups;
  //const unsigned int active_cores = 4;
  const unsigned int is_core_active = cid < active_cores;

  // Set matrix dimension
  const unsigned int r = fconv2d_l.R;
  const unsigned int c = fconv2d_l.C;
  const unsigned int f = fconv2d_l.F;
  const unsigned int ch = fconv2d_l.CH;

  unsigned int timer_start, timer_end, timer;

  // Initialize MemPool
  mempool_init(cid);

  // Initialize multicore barrier
  mempool_barrier_init(cid);

  // Allocate the matrices in the local tile
  // if (cid == 0) {
  //   imtx = (float *)domain_malloc(get_alloc_tile(0),
  //                                  (r + f - 1) * (c + f - 1) * sizeof(float));
  //   omtx = (float *)domain_malloc(get_alloc_tile(0), r * c * sizeof(float));
  //   fmtx =
  //       (float *)domain_malloc(get_alloc_tile(0), f * f * ch * sizeof(float));
  // }

//   if (cid == 0) {
//    imtx = (float*)domain_malloc(get_alloc_l1(), (r+f-1)*(c+f-1)*sizeof(float));
//    omtx = (float*)domain_malloc(get_alloc_l1(), r*c*sizeof(float));
//    fmtx = (float*)domain_malloc(get_alloc_l1(), f*f*ch*sizeof(float));
//  }

  // Reset timer
  timer = (unsigned int)-1;

  // We support only square matrices for now
  if (r != c)
    return -9;

  unsigned int num_rows = r / active_cores; // 按行分

  // Wait for all cores to finish
  mempool_barrier(num_cores);

  // float *i = imtx + (r + f - 1) * num_rows * cid; 
  // float *i = imtx + (c + f - 1) * num_rows * cid;
  float *i = imtx + cid * num_rows * (c + f - 1);

  // float *o = omtx + r * num_rows * cid;
  float *o = omtx + cid * num_rows * c; 
  //ç®—å¥½æ¯ä¸ªcoreèµ·å§‹çš„addrï¼Œå†ä¸€èµ·å¼€å§‹

  // Wait for all cores to finish
  mempool_barrier(num_cores);

  // // Initialize matrices NO MORE NEEDED
  // if (cid == 0) {
  //   init_matrix(imtx, fconv2d_I_dram, (r + f - 1) * (c + f - 1));
  //   init_matrix(omtx, fconv2d_R_dram, r * c);
  //   init_matrix(fmtx, fconv2d_F_dram, f * f * ch);
  // }


  if (cid == 0) {
  //   printf("\n=== STEP 1: Check DRAM source ===\n");
  //   printf("fconv2d_F_dram address: %p\n", fconv2d_F_dram);
  //   printf("First 5 values in fconv2d_F_dram:\n");
  //   for (int i = 0; i < 5; i++) {
  //       printf("  [%d] = 0x%08x\n", i, *((uint32_t*)&fconv2d_F_dram[i]));
  //   }
    
    // printf("\n=== STEP 2: Perform DMA (skipping pre-DMA read) ===\n");
    // printf("fmtx address: %p\n", fmtx);
    // printf("Copying %u bytes from %p to %p\n", 
    //        f * f * ch * sizeof(float), fconv2d_F_dram, fmtx);
    dma_memcpy_blocking(fmtx, fconv2d_F_dram, f * f * ch * sizeof(float));
    
    // printf("\n=== STEP 3: Check L1 destination AFTER DMA ===\n");
    // printf("First 10 values in fmtx:\n");
    // for (int i = 0; i < 10; i++) {
    //     printf("  [%d] = 0x%08x\n", i, *((uint32_t*)&fmtx[i]));
    // }
    
    // printf("\n=== Compare with Python output ===\n");
    // printf("Expected from Python:\n");
    // printf("  [0] = 0xbf6a0a92 (matches DRAM? %s)\n", 
    //        (*((uint32_t*)&fmtx[0]) == 0xbf6a0a92) ? "YES" : "NO");
    
    dma_memcpy_blocking(imtx, fconv2d_I_dram, (r+f-1)*(c+f-1)*sizeof(float));
    dma_memcpy_blocking(omtx, fconv2d_R_dram, r*c*sizeof(float));

    printf("finish copy\n");

//     // 立刻check fmtx 是否正确
//     printf("\n=== Immediately after all DMAs ===\n");
//     printf("  fmtx[0]=0x%08x \n", *((uint32_t*)&fmtx[0]));
//     printf("  fmtx[1]=0x%08x \n", *((uint32_t*)&fmtx[1]));
//     printf("  fmtx[2]=0x%08x \n", *((uint32_t*)&fmtx[2]));
   }


  // Wait for all cores to finish
  mempool_barrier(num_cores);

  //
  // Calculate fconv2d
  //

  // Start timer
  if (cid == 0)
    timer_start = mempool_get_timer();

  // Start dump
  // if (cid == 0)
  //   start_kernel();

  // if (cid == 0) {
  //   printf("\n=== Filter check BEFORE conv ===\n");
  //   printf("  fmtx[0]=0x%08x\n", *((uint32_t*)&fmtx[0]));
  //   printf("  fmtx[7]=0x%08x\n", *((uint32_t*)&fmtx[7]));
  //   printf("  fmtx[14]=0x%08x\n", *((uint32_t*)&fmtx[14]));
  // }

  // if (cid == 0) {
  // // 全局三个缓冲区的起止地址（以 float 元素计）
  // size_t fmtx_len = (size_t)f * (size_t)f * (size_t)ch;
  // size_t imtx_len = (size_t)(r + f - 1) * (size_t)(c + f - 1);
  // size_t omtx_len = (size_t)r * (size_t)c;

  // uintptr_t fmtx0 = (uintptr_t)fmtx;
  // uintptr_t fmtx1 = (uintptr_t)(fmtx + fmtx_len) - 1;
  // uintptr_t imtx0 = (uintptr_t)imtx;
  // uintptr_t imtx1 = (uintptr_t)(imtx + imtx_len) - 1;
  // uintptr_t omtx0 = (uintptr_t)omtx;
  // uintptr_t omtx1 = (uintptr_t)(omtx + omtx_len) - 1;

  // printf("\n=== ADDRESS CHECK BEFORE KERNEL ===\n");
  // printf("fmtx: [%p .. %p]  bytes=%zu\n", (void*)fmtx, (void*)(fmtx1+1),
  //        fmtx_len*sizeof(float));
  // printf("imtx: [%p .. %p]  bytes=%zu\n", (void*)imtx, (void*)(imtx1+1),
  //        imtx_len*sizeof(float));
  // printf("omtx: [%p .. %p]  bytes=%zu\n", (void*)omtx, (void*)(omtx1+1),
  //        omtx_len*sizeof(float));

  // printf("OVERLAP(fmtx, imtx) = %s\n", OVERLAP(fmtx0,fmtx1,imtx0,imtx1) ? "YES":"NO");
  // printf("OVERLAP(fmtx, omtx) = %s\n", OVERLAP(fmtx0,fmtx1,omtx0,omtx1) ? "YES":"NO");
  // printf("OVERLAP(imtx, omtx) = %s\n", OVERLAP(imtx0,imtx1,omtx0,omtx1) ? "YES":"NO");

  // // 再把本核 slice 的 i/o 也检查一下（可直接看是否误指到 fmtx）
  // size_t i_len = (size_t)num_rows * (size_t)(c + f - 1);
  // size_t o_len = (size_t)num_rows * (size_t)c;
  // uintptr_t i0 = (uintptr_t)i, i1 = (uintptr_t)(i + i_len) - 1;
  // uintptr_t o0 = (uintptr_t)o, o1 = (uintptr_t)(o + o_len) - 1;

  // printf("i(slice): [%p .. %p]  bytes=%zu\n", (void*)i, (void*)(i1+1),
  //        i_len*sizeof(float));
  // printf("o(slice): [%p .. %p]  bytes=%zu\n", (void*)o, (void*)(o1+1),
  //        o_len*sizeof(float));

  // printf("OVERLAP(i, fmtx) = %s\n", OVERLAP(i0,i1,fmtx0,fmtx1) ? "YES":"NO");
  // printf("OVERLAP(o, fmtx) = %s\n", OVERLAP(o0,o1,fmtx0,fmtx1) ? "YES":"NO");
  // printf("OVERLAP(i, imtx) = %s\n", OVERLAP(i0,i1,imtx0,imtx1) ? "YES":"NO");
  // printf("OVERLAP(o, omtx) = %s\n", OVERLAP(o0,o1,omtx0,omtx1) ? "YES":"NO");
  // }

  // mempool_barrier(num_cores);

  /////////////////// Calculate the result //////////////////////////
  if (is_core_active)
    conv3d_CHx7x7(o, i, fmtx, num_rows);

  // Wait for all cores to finish
  mempool_barrier(num_cores);

  // if (cid == 0) {
  //   printf("\n=== Right after convolution ===\n");
  //   printf("  fmtx[0]=0x%08x\n", *((uint32_t*)&fmtx[0]));
  //   printf("  fmtx[7]=0x%08x\n", *((uint32_t*)&fmtx[7]));
  //   printf("  fmtx[14]=0x%08x\n", *((uint32_t*)&fmtx[14]));

  //   printf("\n=== Check which positions changed ===\n");
  //   int changed = 0;
  //   for (int i = 0; i < f * f * ch; i++) {
  //       if (*((uint32_t*)&fmtx[i]) != *((uint32_t*)&fconv2d_F_dram[i])) {
  //           printf("  Position %d changed: was 0x%08x, now 0x%08x\n",
  //                  i,
  //                  *((uint32_t*)&fconv2d_F_dram[i]),
  //                  *((uint32_t*)&fmtx[i]));
  //           changed++;
  //           if (changed >= 10) break;  // 只打印前10个
  //       }
  //   }
  // }

  // End timer
  if (cid == 0) {
    timer_end = mempool_get_timer();
    timer = timer_end - timer_start;
  }

  // End dump
  // if (cid == 0)
  //   stop_kernel();

  // Check and display results
  if (cid == 0) {
    unsigned int performance = 1000 * 2 * ch * f * f * r * c / timer;
    unsigned int utilization = performance / (2 * active_cores * N_FPU);

    printf("\n----- (%dx%d) dp fconv2d -----\n", r, c);
    printf("The execution took %u cycles.\n", timer);
    printf("The performance is %u OP/1000cycle (%u%%o utilization).\n",
           performance, utilization);
  }

// #ifdef CHECK
//   if (cid == 0) {
//     int error = verify_matrix(omtx, fconv2d_GR_dram, r * c );
//     printf("Error count: %d\n", error);
//   }
  
//     // for (unsigned int k = 0; k < r * c; ++k) {
//     //   if (!fp_check(fconv2d_GR_dram[k], omtx[k], THRESHOLD)) {
//     //     printf("Error index %d: result = %x (@ %x), golden = %x\n", k,
//     //            *((unsigned int *)&omtx[k]), omtx + k,
//     //            *((unsigned int *)&fconv2d_GR_dram[k]));
//     //     // return -1;
//     //   }
//     // }
// #endif

#ifdef CHECK
  if (cid == 0) {
    int error = verify_matrix(omtx, fconv2d_GR_dram, r * c);
    printf("Error count: %d\n", error);
  }
#endif


  // // Free the matrices
  // if (cid == 0) {
  //   domain_free(get_alloc_l1(), imtx);
  //   domain_free(get_alloc_l1(), omtx);
  //   domain_free(get_alloc_l1(), fmtx);
  // }

  // Wait for core 0 to finish displaying results
  mempool_barrier(num_cores);

  return 0;
}