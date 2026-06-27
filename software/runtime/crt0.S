// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Samuel Riedel, ETH Zurich
//         Matheus Cavalcante, ETH Zurich

// #define TOP4_STACK

#include "addrmap.h"

.globl _start
.globl _eoc
.section .text;
.section .text.init;

_start:
    // Initialize global pointer
    .option push
    .option norelax
    1:auipc gp, %pcrel_hi(__global_pointer$)
      addi  gp, gp, %pcrel_lo(1b)
    .option pop

    /* reset vector */
    j _reset_vector
_reset_vector:
    li      x1, 0
    li      x4, 0
    li      x5, 0
    li      x6, 0
    li      x7, 0
    li      x8, 0
    li      x9, 0
    li      x10, 0
    li      x11, 0
    li      x12, 0
    li      x13, 0
    li      x14, 0
    li      x15, 0
    li      x16, 0
    li      x17, 0
    li      x18, 0
    li      x19, 0
    li      x20, 0
    li      x10, 0
    li      x21, 0
    li      x22, 0
    li      x23, 0
    li      x24, 0
    li      x25, 0
    li      x26, 0
    li      x27, 0
    li      x28, 0
    li      x29, 0
    li      x30, 0
    li      x31, 0
#if N_FPU != 0
    // Zero the FP register file (Spatz/FPU builds only; N_FPU is undefined for
    // scalar builds, so this block disappears and the binary is unchanged).
    fmv.s.x f0, zero
    fmv.s.x f1, zero
    fmv.s.x f2, zero
    fmv.s.x f3, zero
    fmv.s.x f4, zero
    fmv.s.x f5, zero
    fmv.s.x f6, zero
    fmv.s.x f7, zero
    fmv.s.x f8, zero
    fmv.s.x f9, zero
    fmv.s.x f10, zero
    fmv.s.x f11, zero
    fmv.s.x f12, zero
    fmv.s.x f13, zero
    fmv.s.x f14, zero
    fmv.s.x f15, zero
    fmv.s.x f16, zero
    fmv.s.x f17, zero
    fmv.s.x f18, zero
    fmv.s.x f19, zero
    fmv.s.x f20, zero
    fmv.s.x f21, zero
    fmv.s.x f22, zero
    fmv.s.x f23, zero
    fmv.s.x f24, zero
    fmv.s.x f25, zero
    fmv.s.x f26, zero
    fmv.s.x f27, zero
    fmv.s.x f28, zero
    fmv.s.x f29, zero
    fmv.s.x f30, zero
    fmv.s.x f31, zero
#endif
    // Build-time guarantee that every hart's stack stays inside its OWN tile.
    // The SPM scrambler selects the tile by addr / (NUM_CORES_PER_TILE *
    // SEQ_MEM_SIZE), so the NUM_CORES_PER_TILE stacks plus the head-of-region
    // queues of a tile must fit in that span; otherwise the top stack aliases a
    // remote tile (a silent locality/correctness bug). NUM_BANKS_PER_TILE =
    // NUM_CORES_PER_TILE * BANKING_FACTOR * N_FU.
#if (NUM_CORES_PER_TILE * STACK_SIZE \
     + NUM_CORES_PER_TILE * BANKING_FACTOR * N_FU * XQUEUE_SIZE * 4) \
    > (NUM_CORES_PER_TILE * SEQ_MEM_SIZE)
#error "Per-tile stacks + queues exceed NUM_CORES_PER_TILE*SEQ_MEM_SIZE; a stack would fall in a remote tile. Increase SEQ_MEM_SIZE or reduce STACK_SIZE/XQUEUE_SIZE."
#endif
    la      sp, __stack_start                                   // load stack
    csrr    a0, mhartid                                         // get hart id
    // Calculate sequential region offset for our tile. The hardware numbers
    // harts as {tile_id, core_in_tile} with LOG2_NUM_CORES_PER_TILE low bits,
    // and each tile owns a sequential region of NUM_CORES_PER_TILE*SEQ_MEM_SIZE
    // bytes. This is independent of the Spatz N_FU bank scaling, so the layout
    // is identical for scalar and Spatz/FPU builds.
    srli    t0, a0, LOG2_NUM_CORES_PER_TILE                     // tile_id = id / NUM_CORES_PER_TILE
    slli    t0, t0, (LOG2_NUM_CORES_PER_TILE+LOG2_SEQ_MEM_SIZE) // tile_offset = tile_id * NUM_CORES_PER_TILE * SEQ_MEM_SIZE
    // Calculate stack offset within tile
    li      t1, NUM_CORES_PER_TILE                              // NUM_CORES_PER_TILE
    addi    t1, t1, -1                                          // Create mask for NUM_CORES_PER_TILE
    and     t1, a0, t1                                          // tile_core_id = id % NUM_CORES_PER_TILE
    addi    t1, t1, 1                                           // tile_core_id += 1
    slli    t1, t1, LOG2_STACK_SIZE                             // tile_core_offset = tile_core_id * STACK_SIZE
    addi    t1, t1, -4                                          // tile_core_offset -= 1 word
    // Calculate final stack pointer
    add     t0, t0, t1                                          // offset = tile_offset + tile_core_offset
    add     sp, sp, t0                                          // sp += offset
    // Skip past the hardware queues at the head of the tile's sequential
    // region. Byte size = XQUEUE_SIZE(words) * NUM_BANKS_PER_TILE * 4, with
    // NUM_BANKS_PER_TILE = NUM_CORES_PER_TILE * BANKING_FACTOR * N_FU derived
    // from the config (not a hardcoded bank count), so it tracks Spatz builds.
    li      t0, (XQUEUE_SIZE * NUM_CORES_PER_TILE * BANKING_FACTOR * N_FU * 4)
    add     sp, sp, t0                                          // sp += queue region
    // Write the stack limit into the dedicated CSR
    addi    t0, sp, -(STACK_SIZE-4)                             // stack_limit = sp - (STACK_SIZE - 1)
    csrw    stacklimit, t0                                     // write stack limit into CSR
    // Configure the RO cache or directly jump to main
    bnez    a0, _jump_main
    li      t0, (CONTROL_REGISTER_OFFSET + CONTROL_REGISTERS_RO_CACHE_END_0_REG_OFFSET) // Get peripheral register to set cacheable region
    la      t1, _erodata                                        // Write the end of the read-only data to be cacheable
    sw      t1, 0(t0)
_jump_main:
    call    main

_eoc:
    li      t0, (CONTROL_REGISTER_OFFSET + CONTROL_REGISTERS_EOC_REG_OFFSET)
    slli    t1, a0, 1
    addi    t1, t1, 1
    sw      t1, 0(t0)
    la      ra, __rom_start
    ret

.section .data
