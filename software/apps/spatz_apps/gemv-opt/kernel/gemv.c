// Copyright 2025 ETH Zurich and University of Bologna.
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

// Author: Navaneeth Kunhi Purayil, ETH Zurich <nkunhi@iis.ee.ethz.ch>
// Author: Diyou Shen,              ETH Zurich <dishen@iis.ee.ethz.ch>


#include "gemv.h"
#include "printf.h"

void gemv_v32b_m4(float *a, float* b, float* c, uint32_t M, uint32_t M_core, uint32_t N) {
  unsigned int vl, avl = M_core;
  float *a_ = a;
  float *b_ = b;
  float *c_ = c;
  
  do {
    asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(avl));
    for (uint32_t col = 0; col < N; col+=2) {
      // Load chunk a
      asm volatile("vle32.v v0, (%0)" ::"r"(a_));
      a_ += M;

      // Multiply and accumulate
      if (col == 0) {
        asm volatile("vfmul.vf v4, v0, %0" ::"f"(*b_));
      } else {
        asm volatile("vfmacc.vf v4, %0, v0" ::"f"(*b_));
      }
      b_++;

      // Load chunk a
      asm volatile("vle32.v v8, (%0)" ::"r"(a_));
      a_ += M;

      // Multiply and accumulate
      if (col == 0) {
        asm volatile("vfmul.vf v12, v8, %0" ::"f"(*b_));
      } else {
        asm volatile("vfmacc.vf v12, %0, v8" ::"f"(*b_));
      }
      b_++;

    }
    asm volatile("vfadd.vv v12, v12, v4");
    asm volatile("vse32.v v12, (%0)" ::"r"(c_));
    avl -= vl;
    c_ += vl;
    b_ = b;
    a_ = a + avl;
  } while (avl > 0);
  
}


void gemv_v32b_m4_unroll8(float *a, float* b, float* c, uint32_t M, uint32_t M_core, uint32_t N) {
  unsigned int vl, avl = M_core;
  float *a_ = a;
  float *b_ = b;
  float *c_ = c;
  
  asm volatile("vmv.s.x v28, zero");
  do {
    asm volatile("vsetvli %0, %1, e32, m4, ta, ma" : "=r"(vl) : "r"(avl));
    for (uint32_t col = 0; col < N; col+=8) {
      // Load chunk a
      asm volatile("vle32.v v0, (%0)" ::"r"(a_));
      a_ += M;
      // Multiply and accumulate
      asm volatile("vfmacc.vf v28, %0, v0" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v4, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v4" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v8, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v8" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v12, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v12" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v16, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v16" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v20, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v20" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v24, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v24" ::"f"(*b_));
      b_++;

      asm volatile("vle32.v v8, (%0)" ::"r"(a_));
      a_ += M;
      asm volatile("vfmacc.vf v28, %0, v8" ::"f"(*b_));
      b_++;
    }
    asm volatile("vse32.v v28, (%0)" ::"r"(c_));
    avl -= vl;
    c_ += vl;
    b_ = b;
    a_ += vl;
  } while (avl > 0);
}

// M_core should not be less than 16
void gemv_v32b_opt_unroll8(float *a, float* b, float* c, uint32_t M_core, uint32_t N, uint32_t offset) {
  
  unsigned int vl, avl = M_core;
  float *a_ = a;
  float *b_ = b;
  float *c_ = c;

  asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"(avl));
  asm volatile("vmv.v.i v24, 0");

  for (uint32_t i = 0; i < N; i++) {

    asm volatile("vle32.v v0, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, %0, v0" ::"f"(*b_));
    b_++;

    asm volatile("vle32.v v1, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, %0, v1" ::"f"(*b_));
    b_++;

    asm volatile("vle32.v v2, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, %0, v2" ::"f"(*b_));
    b_++;

    asm volatile("vle32.v v3, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, %0, v3" ::"f"(*b_));
    b_++;

    asm volatile("vle32.v v4, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, %0, v4" ::"f"(*b_));
    b_++;

    asm volatile("vle32.v v5, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, %0, v5" ::"f"(*b_));
    b_++;

    asm volatile("vle32.v v6, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, %0, v6" ::"f"(*b_));
    b_++;

    asm volatile("vle32.v v7, (%0)" ::"r"(a_));
    a_ += offset;
    asm volatile("vfmacc.vf v24, %0, v7" ::"f"(*b_));
    b_++;

  }
  asm volatile("vse32.v v24, (%0)" ::"r"(c_));
}