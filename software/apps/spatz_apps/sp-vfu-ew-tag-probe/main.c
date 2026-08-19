// Targeted confirmation of the spatz_vfu.sv:141 element-width tag hazard.
//
//   assign pending_results = result_tag.wb ? (spatz_req.vtype.vsew == EW_32 ? 4'hf : 8'hff) : '1;
//
// The SELECTOR (result_tag.wb) belongs to the instruction whose result is at the FU
// output; the WIDTH (spatz_req.vtype.vsew) is read from the LIVE incoming request.
// With spatz_ipu Pipeline=1 those are different instructions whenever the pipe is not
// empty. Snitch has no multiplier (snitch.sv:1043-1046 offloads MUL/MULH/MULHSU/MULHU),
// so every `mul` becomes a Spatz VFU scalar op issued at vsew=EW_32 -- mask 4'hf, and
// only lane 0 is fed. If the very next instruction sets vsew=EW_16, the mul's result
// is then judged against 8'hff, four bits of which can never arrive, and
//   &(result_valid | ~pending_results)  ==  &(16'h000f | 16'hff00)  ==  0
// forever. result_ready (:380/:392) and vfu_rsp_valid_o (:273) die -> VFU wedged.
//
// Phases are ordered so the two controls are proven BEFORE the suspected poison runs;
// each is fenced and barriered so a marker cannot print until every core has passed it.
//
//   A: e16 vector ops, NO adjacent mul     -> expected PASS
//   B: mul + e32 vector op                 -> expected PASS  (width matches, 4'hf)
//   C: mul + e16 vector op                 -> expected WEDGE (the hazard)
//
// If A and B print and C does not, the mechanism is confirmed and it is the element
// width at the *pairing*, not e16 by itself and not the mul by itself.

#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#define ITERS 32
static _Float16 buf[512] __attribute__((aligned(64)));

int main() {
  const unsigned cid       = mempool_get_core_id();
  const unsigned num_cores = mempool_get_core_count();
  size_t vl;
  uint32_t x = cid + 3, y = cid + 5, z;

  mempool_barrier_init(cid);
  if (cid == 0) {
    for (unsigned i = 0; i < 512; ++i) buf[i] = (_Float16)1.0f;
    printf("[VFUTAG] start ncores=%u\n", num_cores);
  }
  mempool_barrier(num_cores);

  // ---- A: e16 vector work with NO mul anywhere near it --------------------
  asm volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(vl) : "r"(64));
  for (unsigned i = 0; i < ITERS; ++i)
    asm volatile("vle16.v v0, (%0)\n\t vfadd.vv v2, v0, v0" :: "r"(buf) : "memory");
  asm volatile("sfence.vma" ::: "memory");
  mempool_barrier(num_cores);
  if (cid == 0) printf("[VFUTAG] A_E16_NO_MUL_OK\n");
  mempool_barrier(num_cores);

  // ---- B: CONTROL -- mul immediately followed by an e32 vector op ---------
  asm volatile("vsetvli %0, %1, e32, m2, ta, ma" : "=r"(vl) : "r"(32));
  for (unsigned i = 0; i < ITERS; ++i)
    asm volatile("mul %0, %1, %2\n\t vfadd.vv v4, v0, v0"
                 : "=r"(z) : "r"(x), "r"(y) : "memory");
  asm volatile("sfence.vma" ::: "memory");
  mempool_barrier(num_cores);
  if (cid == 0) printf("[VFUTAG] B_MUL_PLUS_E32_OK (z=%u)\n", z);
  mempool_barrier(num_cores);

  // ---- C: THE HAZARD -- mul immediately followed by an e16 vector op ------
  // vsetvli is hoisted out so the pairing inside the loop is exactly mul -> e16 op,
  // matching sp-fmatmul-fp16's 0x800002d0 `mul` / 0x800002d4 `vfmacc.vf`.
  asm volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(vl) : "r"(64));
  for (unsigned i = 0; i < ITERS; ++i)
    asm volatile("mul %0, %1, %2\n\t vfadd.vv v6, v0, v0"
                 : "=r"(z) : "r"(x), "r"(y) : "memory");
  asm volatile("sfence.vma" ::: "memory");
  mempool_barrier(num_cores);
  if (cid == 0) printf("[VFUTAG] C_MUL_PLUS_E16_OK (z=%u)  <== hazard did NOT reproduce\n", z);
  mempool_barrier(num_cores);

  if (cid == 0) printf("[VFUTAG] ALL_PHASES_DONE\n");
  mempool_barrier(num_cores);
  return 0;
}
