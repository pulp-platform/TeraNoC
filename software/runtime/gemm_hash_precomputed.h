// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
#ifndef GEMM_HASH_PRECOMPUTED_H
#define GEMM_HASH_PRECOMPUTED_H

#ifndef MSHR_HASH_PRECOMPUTE
#define MSHR_HASH_PRECOMPUTE 1
#endif

#if MSHR_RUNTIME_CFG && MSHR_HASH_SEARCH && MSHR_CFG_HASH_MODE == 3 && MSHR_HASH_PRECOMPUTE
#ifndef GEMM_HASH_BUILD_FINGERPRINT
#error "Compile with runtime.mk or gemm_hash_fingerprint.py to stamp selector inputs"
#endif
static const char gemm_hash_build_runtime[] __attribute__((used)) =
    GEMM_HASH_BUILD_RUNTIME;
// Patched after linking, without relinking or changing any operand address.
// Volatile prevents the compiler from folding the unpatched initial values.
static const volatile uint32_t gemm_hash_table[1 + 3 * NUM_GROUPS]
    __attribute__((used, section(".rodata.gemm_hash"))) = {0};
static const uint32_t gemm_hash_descriptor[] __attribute__((used)) = {
    2, GEMM_M, GEMM_N, GEMM_P, GEMM_ELEM_BYTES, NUM_CORES, NUM_GROUPS,
    ACTIVE_GROUP_DIV, KERNEL_SIZE, MATMUL_DECODE_SPLIT, VLEN,
    GEMM_BURST_ENABLED, GEMM_BURST_TILE_WORDS, GEMM_BURST_LANES,
    GEMM_BURST_ROB_DEPTH, GEMM_BURST_MAX_WORDS, MSHR_HASH_SAMPLE_STEPS,
    MSHR_CFG_ENTRIES / MSHR_CFG_WAYS, MSHR_D_BANK_SHIFT_SINGLE,
    MSHR_D_BANK_SHIFT_BURST, MSHR_D_BANK_BURST_BITS,
    MATMUL_A_REPLICAS, A_GROUPS_PER_REPLICA, A_REPL_STRIDE_B,
    GEMM_HASH_BUILD_ABI, GEMM_HASH_BUILD_FINGERPRINT};
#define GEMM_HASH_READY (gemm_hash_table[0] == 0x47484d31u)
static inline void gemm_hash_prepare(mshr_cfg_t *cfg, const void *a_base,
                                     const void *b_base, uint32_t group) {
  (void)a_base; (void)b_base;
  cfg->bank_shift_single = gemm_hash_table[1 + 3 * group];
  cfg->bank_shift_burst = gemm_hash_table[2 + 3 * group];
  cfg->bank_burst_bits = gemm_hash_table[3 + 3 * group];
}
#else
#define GEMM_HASH_READY 1
#if MSHR_RUNTIME_CFG
#define gemm_hash_prepare mshr_cfg_tune_gemm
#endif
#endif
#endif
