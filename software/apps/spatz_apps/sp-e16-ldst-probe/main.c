// e16 load/store isolation probe.
//
// The fp16 matmul wedges with every core blocked where the next vector op is the
// first vse16.v. That is consistent with TWO different causes and the matmul cannot
// separate them, because it interleaves e16 loads, e16 stores and vfmacc:
//   (a) the STORE never completes, or
//   (b) an earlier e16 LOAD never completes and the store is merely where Spatz's
//       instruction queue happens to fill.
// This kernel runs the two in isolation, in phases, printing a marker after each.
// Whichever marker fails to appear names the culprit. Each phase ends with an
// sfence.vma (request-sent fence) plus a barrier, so a phase cannot be credited
// until its memory traffic has actually been issued by every core.

#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#define NELEM 4096            // 8 KB at 2 B/elem -- several vector register groups
#define ITERS 64

// Two buffers so loads and stores never touch the same lines.
static _Float16 src[NELEM] __attribute__((aligned(64)));
static _Float16 dst[NELEM] __attribute__((aligned(64)));

static inline void req_sent_fence(void) { asm volatile("sfence.vma" ::: "memory"); }

int main() {
  const unsigned cid       = mempool_get_core_id();
  const unsigned num_cores = mempool_get_core_count();

  mempool_barrier_init(cid);

  if (cid == 0) {
    for (unsigned i = 0; i < NELEM; ++i) { src[i] = (_Float16)1.0f; dst[i] = (_Float16)0.0f; }
    printf("[E16] start ncores=%u NELEM=%u ITERS=%u\n", num_cores, NELEM, ITERS);
  }
  mempool_barrier(num_cores);

  // Give every core a distinct 64-element window so the traffic pattern resembles
  // the matmul's (many cores, spread addresses) rather than 256 cores hammering one line.
  const unsigned stride = 64;
  _Float16 *s = src + ((cid * stride) % (NELEM - stride));
  _Float16 *d = dst + ((cid * stride) % (NELEM - stride));

  // ---- PHASE 1: e16 LOADS ONLY (no vector store anywhere) ----------------
  size_t vl;
  asm volatile("vsetvli %0, %1, e16, m2, ta, ma" : "=r"(vl) : "r"(stride));
  for (unsigned it = 0; it < ITERS; ++it)
    asm volatile("vle16.v v0, (%0)" :: "r"(s) : "memory");
  req_sent_fence();
  mempool_barrier(num_cores);
  if (cid == 0) printf("[E16] PHASE1_LOADS_OK\n");
  mempool_barrier(num_cores);

  // ---- PHASE 2: e16 STORES ONLY (v0 already holds data; no vector load) --
  for (unsigned it = 0; it < ITERS; ++it)
    asm volatile("vse16.v v0, (%0)" :: "r"(d) : "memory");
  req_sent_fence();
  mempool_barrier(num_cores);
  if (cid == 0) printf("[E16] PHASE2_STORES_OK\n");
  mempool_barrier(num_cores);

  // ---- PHASE 3: interleaved load+store, as the matmul does ---------------
  for (unsigned it = 0; it < ITERS; ++it) {
    asm volatile("vle16.v v0, (%0)" :: "r"(s) : "memory");
    asm volatile("vse16.v v0, (%0)" :: "r"(d) : "memory");
  }
  req_sent_fence();
  mempool_barrier(num_cores);
  if (cid == 0) printf("[E16] PHASE3_MIXED_OK\n");
  mempool_barrier(num_cores);

  // ---- PHASE 4: the e32 control, same shape ------------------------------
  asm volatile("vsetvli %0, %1, e32, m2, ta, ma" : "=r"(vl) : "r"(stride));
  for (unsigned it = 0; it < ITERS; ++it) {
    asm volatile("vle32.v v0, (%0)" :: "r"(s) : "memory");
    asm volatile("vse32.v v0, (%0)" :: "r"(d) : "memory");
  }
  req_sent_fence();
  mempool_barrier(num_cores);
  if (cid == 0) printf("[E16] PHASE4_E32_CONTROL_OK\n");
  mempool_barrier(num_cores);

  if (cid == 0) printf("[E16] ALL_PHASES_DONE\n");
  mempool_barrier(num_cores);
  return 0;
}
