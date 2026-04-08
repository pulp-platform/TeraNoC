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

#ifndef _GEMV_H
#define _GEMV_H

inline void gemv_v32b_opt_unroll8 (float *a, float* b, float* c, 
																	 uint32_t M_core, uint32_t N, uint32_t offset)
																	 __attribute__((always_inline));
																
inline void gemv_v32b_opt_unroll8_scalar2 (float *a, float* b, float* c, 
																	 uint32_t M_core, uint32_t N, uint32_t offset)
																	 __attribute__((always_inline));

inline void gemv_v32b_opt_unroll8_scalar8 (float *a, float* b, float* c, 
																	 uint32_t M_core, uint32_t N, uint32_t offset)
																	 __attribute__((always_inline));
																	 
inline void gemv_v32b_m4 					(float *a, float* b, float* c,
		 															 uint32_t M, uint32_t M_core, uint32_t N)
																	 __attribute__((always_inline));


inline void gemv_v32b_m4_unroll8			(float *a, float* b, float* c,
		 															 uint32_t M, uint32_t M_core, uint32_t N)
																	 __attribute__((always_inline));																	 


#endif
