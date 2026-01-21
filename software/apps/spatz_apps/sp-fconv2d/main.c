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


  // Wait for all cores to finish
  mempool_barrier(num_cores);

  // // Initialize matrices NO MORE NEEDED
  // if (cid == 0) {
  //   init_matrix(imtx, fconv2d_I_dram, (r + f - 1) * (c + f - 1));
  //   init_matrix(omtx, fconv2d_R_dram, r * c);
  //   init_matrix(fmtx, fconv2d_F_dram, f * f * ch);
  // }


  if (cid == 0) {
    // // 全局三个缓冲区的起止地址
    // size_t fmtx_len = (size_t)f * (size_t)f * (size_t)ch;
    // size_t imtx_len = (size_t)(r + f - 1) * (size_t)(c + f - 1);
    // size_t omtx_len = (size_t)r * (size_t)c;

    // uintptr_t fmtx0 = (uintptr_t)fmtx;
    // uintptr_t fmtx1 = (uintptr_t)(fmtx + fmtx_len) - 1;
    // uintptr_t imtx0 = (uintptr_t)imtx;
    // uintptr_t imtx1 = (uintptr_t)(imtx + imtx_len) - 1;
    // uintptr_t omtx0 = (uintptr_t)omtx;
    // uintptr_t omtx1 = (uintptr_t)(omtx + omtx_len) - 1;

    // printf("\n=== ADDRESS CHECK BEFORE DMA ===\n");
    // printf("fmtx: [%p .. %p]  len=%zu floats, bytes=%zu\n", 
    //        (void*)fmtx0, (void*)(fmtx1+1), fmtx_len, fmtx_len*sizeof(float));
    // printf("imtx: [%p .. %p]  len=%zu floats, bytes=%zu\n", 
    //        (void*)imtx0, (void*)(imtx1+1), imtx_len, imtx_len*sizeof(float));
    // printf("omtx: [%p .. %p]  len=%zu floats, bytes=%zu\n", 
    //        (void*)omtx0, (void*)(omtx1+1), omtx_len, omtx_len*sizeof(float));

    // printf("\nOVERLAP CHECK:\n");
    // printf("OVERLAP(fmtx, imtx) = %s\n", OVERLAP(fmtx0,fmtx1,imtx0,imtx1) ? "YES *** PROBLEM ***":"NO");
    // printf("OVERLAP(fmtx, omtx) = %s\n", OVERLAP(fmtx0,fmtx1,omtx0,omtx1) ? "YES *** PROBLEM ***":"NO");
    // printf("OVERLAP(imtx, omtx) = %s\n", OVERLAP(imtx0,imtx1,omtx0,omtx1) ? "YES *** PROBLEM ***":"NO");
    
    // printf("\n=== Check DRAM data range ===\n");
    // // 检查前20个元素
    // for (int i = 0; i < 20; i++) {
    //     printf("  DRAM[%d] = 0x%08x\n", i, *((uint32_t*)&fconv2d_F_dram[i]));
    // }
    
    // // 检查最后几个元素
    // printf("\n=== Check DRAM end ===\n");
    // int total = f * f * ch;
    // for (int i = total-5; i < total; i++) {
    //     printf("  DRAM[%d] = 0x%08x\n", i, *((uint32_t*)&fconv2d_F_dram[i]));
    // }
    
    // printf("\n=== C reads fconv2d_F_dram (BEFORE DMA) ===\n");
    // for (int i = 0; i < 12; i++) {
    //     printf("  fconv2d_F_dram[%d] = 0x%08x\n", i, *((uint32_t*)&fconv2d_F_dram[i]));
    // }

    dma_memcpy_blocking(fmtx, fconv2d_F_dram, f * f * ch * sizeof(float));
    
    // printf("\n=== Check fmtx (AFTER DMA) ===\n");
    // for (int i = 0; i < 12; i++) {
    //     printf("  fmtx[%d] = 0x%08x\n", i, *((uint32_t*)&fmtx[i]));
    // }
    
    dma_memcpy_blocking(imtx, fconv2d_I_dram, (r+f-1)*(c+f-1)*sizeof(float));
    dma_memcpy_blocking(omtx, fconv2d_R_dram, r*c*sizeof(float));

    printf("finish copy\n");
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

  // mempool_barrier(num_cores);

  /////////////////// Calculate the result //////////////////////////
  if (is_core_active)
    conv3d_CHx7x7(o, i, fmtx, num_rows);

  // Wait for all cores to finish
  mempool_barrier(num_cores);

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



#ifdef CHECK
  if (cid == 0) {
    int error = verify_matrix(omtx, fconv2d_GR_dram, r * c);
    printf("Error count: %d\n", error);
  }
#endif


  // Wait for core 0 to finish displaying results
  mempool_barrier(num_cores);

  return 0;
}