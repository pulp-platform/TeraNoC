// bf16 (FP16ALT) smoke test.
//
// Enabling XF16ALT/FpFmtMask[4] is not self-verifying: if the format were NOT actually
// reaching the FPU, e16 ops would quietly keep running as IEEE FP16 and every kernel
// would still "work" -- just with the wrong numerics. So this test does not ask
// "did it crash?", it asks "which format actually executed?", and it is built so that
// the two answers are different bit patterns.
//
// bf16 is simply fp32 truncated to its top 16 bits, which makes the discriminators exact:
//
//   case A (mantissa/encoding)   0x4000 * 0x4040
//        as bf16:  2.0 * 3.0            = 6.0        -> 0x40C0
//        as fp16:  2.0 * 2.125          = 4.25       -> 0x4440
//
//   case B (exponent range)      0x7F00 * 0x3F80
//        as bf16:  1.7014e38 * 1.0      = 1.7014e38  -> 0x7F00   (exp 254 = max finite)
//        as fp16:  NaN * 1.875          = NaN        -> 0x7E00   (exp 31 = NaN)
//   Case B is the strong one: it can only pass if the 8-bit exponent is live, which is
//   the entire point of bf16 over fp16.
//
// The test runs BOTH fmode=0 (fp16) and fmode=3 (bf16) and requires each to produce its
// OWN answer. The fp16 arm is the control: if it did not come back with the fp16 values,
// the test has no discriminating power and a "bf16 PASS" would be meaningless.
//
// CSR_FMODE is 0x800 and snitch.sv:2601 assigns fmt_mode_t'(alu_result[1:0]); fmt_mode_t
// is packed {src, dst}, so src is bit 1 and dst is bit 0 -- 3 selects FP16ALT for both.
// spatz_vfu.sv:861-862 then picks fm.src ? FP16ALT : FP16 for a non-widening EW_16 op.
//
// All values move as raw uint16_t through memory (vle16.v / vse16.v) and are read back
// with integer loads, so no GPR<->FPR transfer is involved anywhere.

#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#define NV 8

static volatile uint16_t vin_a[NV] __attribute__((aligned(64)));
static volatile uint16_t vin_b[NV] __attribute__((aligned(64)));
static volatile uint16_t vout[NV]  __attribute__((aligned(64)));

static inline void set_fmode(unsigned m) {
  asm volatile("csrw 0x800, %0" ::"r"(m) : "memory");
}

// FENCE drains both the integer and the Spatz side (SFENCE.VMA is request-sent only,
// which would let us read vout before the store data landed).
static inline void drain(void) { asm volatile("fence" ::: "memory"); }

static void mul_e16(void) {
  size_t vl;
  asm volatile("vsetvli %0, %1, e16, m1, ta, ma" : "=r"(vl) : "r"((size_t)NV));
  asm volatile("vle16.v v8,  (%0)" ::"r"(vin_a) : "memory");
  asm volatile("vle16.v v9,  (%0)" ::"r"(vin_b) : "memory");
  asm volatile("vfmul.vv v10, v8, v9");
  asm volatile("vse16.v v10, (%0)" ::"r"(vout) : "memory");
  drain();
}

static inline int is_nan_fp16(uint16_t h) {
  return ((h & 0x7C00u) == 0x7C00u) && ((h & 0x03FFu) != 0u);
}

int main() {
  const unsigned cid       = mempool_get_core_id();
  const unsigned num_cores = mempool_get_core_count();

  mempool_barrier_init(cid);

  int fail = 0;

  if (cid == 0) {
    printf("[BF16] start\n");

    // lane 0..3 -> case A, lane 4..7 -> case B
    for (unsigned i = 0; i < NV; ++i) {
      if (i < 4) { vin_a[i] = 0x4000; vin_b[i] = 0x4040; }
      else       { vin_a[i] = 0x7F00; vin_b[i] = 0x3F80; }
      vout[i] = 0xDEAD;
    }

    // ---- control arm: fmode=0 must give the FP16 answers ----
    set_fmode(0);
    mul_e16();
    uint16_t a_fp16 = vout[0], b_fp16 = vout[4];
    printf("[BF16] fmode=0 (fp16 control): A=0x%04x (want 0x4440)  B=0x%04x (want a NaN)\n",
           a_fp16, b_fp16);
    if (a_fp16 != 0x4440)   { printf("[BF16] CONTROL FAIL: A\n"); fail = 1; }
    if (!is_nan_fp16(b_fp16)) { printf("[BF16] CONTROL FAIL: B not NaN\n"); fail = 1; }

    for (unsigned i = 0; i < NV; ++i) vout[i] = 0xDEAD;

    // ---- bf16 arm: fmode=3 must give the FP16ALT answers ----
    set_fmode(3);
    mul_e16();
    uint16_t a_bf16 = vout[0], b_bf16 = vout[4];
    printf("[BF16] fmode=3 (bf16)        : A=0x%04x (want 0x40C0)  B=0x%04x (want 0x7F00)\n",
           a_bf16, b_bf16);

    if (a_bf16 == 0x40C0 && b_bf16 == 0x7F00) {
      printf("[BF16] PASS: FP16ALT is live (2.0*3.0=6.0 in bf16 encoding, and the "
             "8-bit exponent survives 1.7e38)\n");
    } else {
      fail = 1;
      if (a_bf16 == 0x4440 || is_nan_fp16(b_bf16))
        printf("[BF16] FAIL: results are the IEEE FP16 answers -- fmode=3 did NOT select "
               "FP16ALT. Check FpFmtMask element 5 (index 4) and XF16ALT.\n");
      else
        printf("[BF16] FAIL: unexpected results, neither bf16 nor fp16.\n");
    }

    set_fmode(0);
    printf("[BF16] %s\n", fail ? "RESULT=FAIL" : "RESULT=PASS");
  }

  mempool_barrier(num_cores);
  return 0;
}
