// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/* This file will get processed by the precompiler to expand all macros. */

/* Group-barrier reserved window.
 *
 * mempool_group re-routes ANY intra-group, different-tile access whose within-tile word
 * field lands in [GROUP_BARRIER_WORD, GROUP_BARRIER_WORD+NUM_GROUP_BARRIERS) to the group
 * barrier port and WITHHOLDS its response until a rendezvous that ordinary data never
 * performs -- i.e. a silent, undetectable deadlock. The window is stolen from the data
 * address space group-wide, so the linker must keep every object out of it.
 *
 * The word field is byte_addr>>14 (bits [13:0] are group|tile|bank|byte), so the window
 * starts at GROUP_BARRIER_WORD*16384. GROUP_BARRIER_WORD is chosen so the window is the
 * TOP of L1; truncating the l1 region here is therefore sufficient and costs no
 * fragmentation. Keep in sync with GroupBarrierWord in hardware/src/mempool_group.sv.
 */
#define L1_FULL_BYTES  (NUM_CORES * N_FU * BANKING_FACTOR * L1_BANK_SIZE)
#define GBAR_WINDOW_LO (GROUP_BARRIER_WORD * 16384)
#define L1_USABLE_BYTES ((GBAR_WINDOW_LO) < (L1_FULL_BYTES) ? (GBAR_WINDOW_LO) : (L1_FULL_BYTES))

MEMORY {
  l1 (R) : ORIGIN = 0x00000000, LENGTH = L1_USABLE_BYTES
  l2     : ORIGIN = L2_BASE   , LENGTH = L2_SIZE
  rom (R): ORIGIN = BOOT_ADDR , LENGTH = 0x00001000
}

SECTIONS {
  // Start end end of memories
  __l1_start = ORIGIN(l1);
  __l1_end = ORIGIN(l1) + LENGTH(l1);
  __l2_start = ORIGIN(l2);
  __l2_end = ORIGIN(l2) + LENGTH(l2);
  __rom_start = ORIGIN(rom);
  __rom_end = ORIGIN(rom) + LENGTH(rom);

  // Stack size
  __stack_start = __l1_start;
  __stack_end = __l1_start + (NUM_CORES * STACK_SIZE);

  // Sequential region size
  __seq_start = __l1_start;
  __seq_end = __l1_start + (NUM_CORES * SEQ_MEM_SIZE);

  // Heap size (start address is re-assigned in link.ld)
  __heap_start = __l1_start;
  __heap_end = __l1_end;

  fake_uart              = 0xC0000000;
}
