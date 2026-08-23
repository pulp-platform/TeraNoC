# Plan — fp16 packed-A load (one word fetch, two elements)

## Goal

Remove the fp16 second-round A load entirely. Today each 32-bit word holding
`A[m][n]` and `A[m][n+1]` is fetched **twice** (two `flh`), which both wastes half the
TCDM/interconnect bandwidth *and* creates the cohort-splitting pathology the whole
campaign has been chasing. Fetch it **once** and split it in registers.

```
today    : flh A[m][n] ; flh A[m][n+1]     2 word fetches -> 2 elements   50% useful
target   : lw  w ; fmv.h.x lo,w
           srli w2,w,16 ; fmv.h.x hi,w2    1 word fetch  -> 2 elements  100% useful
```

Second consequence, and the bigger one: with one fetch there is **no second cohort**,
so no `CACHED` line can be half-consumed, so the RESP-HOLD stall cannot occur. This
makes both `resp_cache=0` and the idea-2 reuse target irrelevant for fp16 A traffic.

## Facts established before planning

- `t0..t7` are eight **rows** at column n (`a__ += N`); the two fp16 values sharing a
  word are `A[m][n]` / `A[m][n+1]`, consumed in the **two halves of one unrolled
  iteration** — so both are live inside a single loop body. Feasible without
  restructuring the loop.
- `FMV_H_X` is decoded by the **compiled** core, `hardware/deps/snitch/src/snitch.sv:2318`,
  gated `FP_EN && XF16` with `XF16 = RVF ? 1 : 0` = 1. NOTE: `working_dir/spatz/hw/ip/snitch/`
  has a *different* copy that is NOT compiled — check the right file.
- It dispatches to the FPU (`is_acc=1`). So it costs an FPU issue slot — but so does the
  `flh` it replaces, so the swap is roughly issue-neutral on the FPU, which matters
  because this kernel is FPU-bound.
- FP-LSU and Snitch integer LSU **share scalar data port 0** through the
  `tcdm_id_remapper` (`spatz_mempool_cc.sv:332`, `.req_i({fp_lsu_req, snitch_req})`).
  So an integer `lw` gets the same MSHR treatment as `flh` — no port penalty.
- Alignment holds: `A[m][n]` at even n is 4-byte aligned whenever N is even, which the
  autotuner already requires.
- **minpool / mempool_spatz are boot-broken on this branch** (host-chimney assertion), so
  fast iteration must come from a small SHAPE on terapool, not a small config.

## Steps

### 1. Feasibility test for `fmv.h.x` (blocking)

Standalone baremetal test, not the matmul. Load a known packed word, split it, and
check both halves against expected fp16 bit patterns.

- Build for `terapool_spatz4_fpu` (only config that boots).
- Verify: correct values, no illegal-instruction trap, no hang.
- Also test `fcsr.fmode.dst` — recent commit `0fd8a0b4` enabled bf16 (XF16ALT); the
  decoder takes a different branch when `fmode.dst==1`, so test both modes.

**If it hangs or traps:** minimise to a single instruction, then add RTL probes on the
snitch accelerator handshake (`acc_qvalid_o` / `acc_qready_i`) and the FPU response path.
The known-risky direction is `fmv.x.w` (FP->int, implicated in the epilogue deadlock);
`fmv.h.x` is int->FP and should not touch that path — confirm on the wave.

### 2. Micro-benchmark the instruction cost

Small loop, N iterations of `lw + srli + 2x fmv.h.x` vs `2x flh`, same data.
Measures whether the FPU issue-slot cost offsets the saved fetch. Expect roughly
neutral issue, one fewer memory transaction.

### 3. Kernel change, smallest shape first

Modify `sp-fmatmul-opt-burst-merge-fp16/kernel/sp-fmatmul.c`:
- keep 8 packed words live across the two halves of the unrolled n-loop
- `lw` once per row per n-pair; `fmv.h.x` at each use
- watch register pressure: 8 more int registers (or 16 f-registers)

Test on `256x32x256` (smallest, ~3k cycles, fastest turnaround). Verify **correctness
first** (the kernel's own result check), then cycles.

### 4. Validate on the shapes that hurt

`512x64x256` (v1 RH=244), `128x128x512` (RH=1056), `512x256x256` (RH=6793).
Expected signature: **RH = 0 with the cache still ON**, because there is no second
cohort to split — distinct from rc0, which achieves RH=0 by removing the cache.

### 5. Commit, then full sweep

If small shapes are correct and faster: commit (brief message, no AI attribution),
then run the full 61-shape sweep and record results in the idea-2 artifact
(https://claude.ai/code/artifact/3a9aa36e-c69e-47f5-a655-b3aca737437b) as a third
configuration alongside rc0 and idea 2.

## Risks

| risk | mitigation |
|---|---|
| `fmv.h.x` buggy/unsupported in this FPU | step 1 is a blocking gate before any kernel work |
| FPU issue-slot cost exceeds the saved fetch | step 2 measures it in isolation |
| register pressure spills | check the dump for stack traffic in the inner loop |
| bf16 mode (`XF16ALT`) changes the decode path | test both `fmode.dst` values |
| correctness regression | kernel's own verify, on the smallest shape, before any perf claim |

## Explicitly NOT doing

- Option D (store A pre-NaN-boxed, one element per 32-bit word): rejected — it fetches
  the same number of words as today (still 50% useful) and doubles A's footprint, which
  would push the largest fp16-only shapes out of L1.
- Touching the running rc0 / idea-2 sweeps. They continue; monitoring stays live.


---

## Step 1 RESULT (2026-08-21): PASS

`fmv.h.x` works, and the whole path the kernel uses works:

    A: fmv.h.x low survived
    B: fmv.h.x high survived
    C: vsetvli gvl=32
    D: vle16 survived
    E: vfmul.vf  with fmv.h.x scalar survived
    F: vfmacc.vf with fmv.h.x scalar survived
    G: vse16 survived
    vdst[0]=0x4200 vdst[31]=0x4200 expect 0x4200 (3.0)
    RESULT=PASS

`1.0*2.0 + 1.0*1.0 = 3.0` exactly, on the first AND last vector element -- so both halves are
extracted from one packed word, correctly NaN-boxed, and consumed correctly by both vector ops.

### Two mistakes worth recording

**Tested the wrong instruction first.** The initial test checked `lo + hi`, a SCALAR `fadd.h`,
as the "does NaN-boxing work" proof. That instruction is not on the kernel's path -- an A
element is only ever the `"f"` operand of `vfmacc.vf`/`vfmul.vf`. Two runs died at it with core 0
showing `acc=1000/1000`, and I nearly reported fp16 arithmetic as broken and a blocker. Rewriting
the test to use the vector path passed immediately. **Test what the caller actually issues.**
(The scalar-`fadd.h` stall may still be a real bug; it is simply not this plan's concern.)

**Blamed the design for a launch-harness problem.** Three runs died 10-20 min in with the log
frozen and the process gone. At the moment of death the core was executing normally (`acc=0`,
`ins=347`) -- not wedged. The cause was launching with `setsid nohup ... & disown` from a tool
call; the same sim run as a tracked background task completed. Sweep arms launched from a
long-lived script were never affected, which is why they ran for hours.

### Next

Step 2 (benchmark: 2x flh vs 1x lw + 2x fmv.h.x) is running. Step 3 is confined to
`matmul_8xVL` -- **5 load sites**, not the 15 across the file; the other 10 belong to the
`4xVL`/`2xVL` variants used only at non-default KERNEL_SIZE.


---

## Step 3 IMPLEMENTED (2026-08-21), instruction-level verified

Change is confined to `matmul_8xVL` and gated on `-DPACKED_A=1`; the default build expands to
the original single `flh` per element, so the baseline path is untouched.

    inside matmul_8xVL      flh   fmv.h.x   lw
      PACKED_A=0             40         0   19
      PACKED_A=1              0        40   33

**A-matrix word fetches 40 -> 24 statically; exactly halved in the steady loop.**
(40 -> 24 is 0.6x, not 0.5x -- the static count is skewed by the peel. The five sites are
3 EVEN + 2 ODD, so 24 of the 40 element fetches still touch memory. The STEADY loop is what
governs a large N: one ODD + one EVEN site per iteration, 8 loads serving 16 elements = an
exact 2:1. The peel's extra EVEN site is a fixed per-row-block cost that amortises away as N
grows, so the achievable A-traffic reduction approaches 50% and is below it for small N.) The 40 `fmv.h.x` are 24 low-half extractions
(3 even-column sites x 8 rows) plus 16 high-half reuses (2 odd-column sites x 8 rows); the odd
sites no longer touch memory at all.

**Parity is fixed per call site, not tested at runtime.** Columns are fetched in order
0,1,2,3,... and pack as (0,1),(2,3),..., so the five sites alternate EVEN, ODD, EVEN, ODD, EVEN
starting from the preamble (column 0). `A_LD_EVEN` does the 32-bit load and uses the low half;
`A_LD_ODD` uses the high half of the word already held in `w0..w7`. No branch enters the hot loop.

### Correctness strategy

The kernel's own `verify_matrix()` is disabled by default (`MATMUL_VERIFY=0`) because it sums C
rows in scalar FP and wedges core 0 (`main.c:51`). That is the SAME mechanism as the scalar
`fadd.h` stall found in step 1 -- two independent observations of one bug. Correctness is
therefore checked with `MATMUL_SPOTCHECK=1`, which reads C back as raw 32-bit words with
ordinary integer loads (one sample per group) and touches no FP register. The two builds must
print bit-identical `[SPOT]` words.

### Build traps hit

- **`make <app> EXTRA_DEFINES=...` silently does nothing and reports success when the ELF is
  newer than the source** -- documented at `software/runtime/runtime.mk:162`. The first
  PACKED_A=1 build was a no-op; the disassembly still showed 40 `flh`. Always `rm -f` the ELF
  first, and confirm the define landed by disassembling rather than trusting the exit code.
- A substitution regex assuming 8 consecutive `t<N> = *a__;` lines matched only 1 of 5 sites:
  the preamble is the only block where the loads are consecutive, the other four interleave
  them with `vfmacc` lines. Match loads individually and group by count.

### Status

`256x32x256`, same RTL image, PACKED_A off vs on, both with `MATMUL_SPOTCHECK=1` -- running.
Correctness (identical [SPOT] words) is the gate; cycles are the payoff measurement.


---

## SIDE FINDING: the SCALAR FP path wedges core 0 (four independent sightings)

Not part of this plan, but it shaped every test written for it, so it is recorded here.

1. **Step-1 test v1** hung at a scalar `fadd.h` (`lo + hi`), core 0 at `acc=1000/1000`,
   reproducible across two runs. I nearly reported fp16 arithmetic as a blocker.
2. **`verify_matrix()` is disabled by default** (`MATMUL_VERIFY=0`) because it "sums each row of
   C on the scalar FP path and wedges core 0" -- `sp-fmatmul-opt-burst-merge-fp16/main.c:51`,
   written well before tonight.
3. **`MATMUL_SPOTCHECK` exists solely to avoid it**: it reads C back as raw 32-bit words with
   ordinary integer loads precisely so it "cannot reproduce the wedge".
4. **Step-2 micro-benchmark never reached its first print.** Its init loop is
   `src[i] = (_Float16)((float)(i & 7) * 0.25f)` -- `fcvt.s.w`, `fmul.s`, `fcvt.h.s`, all
   scalar FP -- and it sat at `acc=1000` from cyc 12,000 to 44,000. It hangs initialising its
   own data, not in anything it was built to measure.

**Consequence for this plan:** step 2 as written CANNOT run -- any C-level fp16 setup wedges
before the timed region. It is also no longer needed: the pa_off/pa_on pair measures the same
question better (real kernel, real data, with a correctness check attached), and is unaffected
because the kernel only ever uses fp16 as the scalar operand of a VECTOR op. Step 2 is dropped
rather than fixed.

**Consequence beyond this plan:** the VFU fp16 fix (`spatz_vfu.sv`, 2026-08-19) addressed the
vector path and is compiled in; the scalar path is separate and still broken. Anything that
touches scalar fp16/fp32 arithmetic on this core -- verification code, data staging, host-side
checks written in C -- must be assumed to hang until that is fixed.


---

## Step 4: measurement on a shape that HAS the pathology (2026-08-21)

`256x32x256` was the wrong shape to judge this on: RH=0 there in every configuration, so the
change had nothing to fix and cost `+2.6%` (33,285 -> 34,143 cyc). That number is still valid,
but as an answer to a different question -- what packed-A costs where there is no stranding.

Re-run on **`512x64x256`**, which does exhibit it (v1 RH=244), same RTL image, cache still ON:

| arm | A-load form | RH STUCK | cum FPU util |
|---|---|---|---|
| `pa_off` | 2x `flh` per pair | 1677+ | 8.98% |
| `pa_on`  | 1x `lw` + 2x `fmv.h.x` | 462+ | 9.94% |

**~3.5x fewer stall episodes**, stable across every sample taken during the run. Utilisation is
~11% better -- NOT the 2.4x an early reading suggested: that came from the per-period `util=`
field, which swings widely; `cum=` is the figure that means anything.

This is the predicted mechanism, and it is worth being precise about why it differs from rc0.
Turning the response cache off (rc0) avoids the pathology by removing the structure that strands
the second cohort. Packed-A removes **the second cohort itself** -- there is no second request to
strand, so the cache can stay on and keep serving the cases it is good for.

### Build-sequencing error: the correctness gate was not actually armed

Both `512x64x256` ELFs were built BEFORE the `[CKSUM]` patch was applied to `main.c`, so neither
contains it -- `strings pa_on.elf | grep CKSUM` returns 0 while the source has it. The pair in
flight can therefore report performance but **cannot** answer correctness, which is the same gap
that made the first pair inconclusive; adding the fingerprint fixed nothing because the fingerprint
never reached the binary.

Rebuilt as `pa_ck_off` / `pa_ck_on` with an explicit gate in the build script -- it now refuses to
proceed unless `strings <elf> | grep -c CKSUM` is non-zero -- and relaunched. Verifying the
*intent* landed in the artifact is not optional here: this is the second time in this effort that
a build silently produced something other than what was asked for (the first was
`EXTRA_DEFINES` no-op'ing against a newer ELF, `runtime.mk:162`).

### Correctness argument, verified by reading the emitted structure

The parity chain cannot drift, because `a__ = a_ + n` is **reset at every site** rather than
carried across them, so a site's column parity is exactly the parity of `n`:

    preamble  n=0  EVEN                     (loads the word, uses low half)
    peel      n=1  ODD    n=2  EVEN
    steady    n=3  ODD    n=4  EVEN   ...    (while (n < N), ++n twice per iteration)

Every ODD site reuses the word its immediately preceding EVEN site loaded, including across the
loop back-edge. No over-read past the row: the second half does `if (n == N) break;` *before* any
`A_LD_EVEN`, so the last 32-bit A fetch is at `n <= N-2` and covers columns `N-2, N-1`.

**Precondition: N must be even** -- both for the pairing and for 4-byte alignment, since
`a_ = a + m*N` and each row step is `+= N` elements (2N bytes). This is already enforced:
`main.c:253` rejects odd N because the inner loop unrolls n by 2. The two requirements coincide,
so packed-A needs no new guard -- but the comment there now says so explicitly, because a future
relaxation of the unroll would silently break packed loads. Every shape in the sweep has N in
{32,64,128,256,512,1024}, all even.

### Status

`pa_off`/`pa_on` running for performance; `pa_ck_off`/`pa_ck_on` running for correctness.
Identical `[CKSUM]` between the two is the gate. No commit and no sweep until it clears.

### What MSHR configuration these runs actually use -- and a comparability caveat

The worktree predates the compile-time MSHR derivation (staged in the main tree, never carried
over): `software/runtime/mshr_cfg.h` here has no `MSHR_D_*` enum, and the app's `mshr_cfg_t`
initialiser names no `.cache_reuse_target`, so it zero-fills to **0 = legacy self-invalidate**.

Two consequences:

1. **The pair is a clean isolation of packed-A.** Both arms run cache ON with legacy behaviour and
   identical MSHR settings; only the A-load form differs. Nothing about idea 2 is in the loop.
2. **These cycle counts are NOT comparable to the main-tree sweep**, which builds with the derived
   configuration. Compare `pa_on` to `pa_off`, never to a sweep row. (Same rule that made the
   knob-vs-layout isolation necessary earlier: a delta against a differently-built arm conflates
   the change with the build.)

### Design note: packed-A and idea 2 are mutually exclusive by construction

`MSHR_D_CACHE_REUSE_RAW = 2 * MSHR_D_HOLD_SUBS_SINGLE` rests explicitly on "two scalar fp16 loads
alias one 32-bit word, so the SAME S cores touch the line twice." Packed-A deletes the second
touch: one load per word, so `served_cnt` tops out at S. A target of 2S would then be
**unreachable**, the line would never self-invalidate on the target path, and it would ride the
cache timeout instead -- precisely the way-capacity pressure behind the idea-2 collapses
(`valid_avg` 0.18 -> 32.34 of 64, `mshr_overflow` 0 -> 155).

So the two changes attack the same waste from opposite ends and must not be stacked. If packed-A
is adopted, the derivation needs `PACKED_A -> target = 0`, or fp16 shapes would silently inherit
an unsatisfiable target. Recorded here rather than implemented, because the worktree does not
carry the derivation and the decision belongs with the sweep result.


---

## Step 5: the first implementation did not do what it claimed (2026-08-21)

`__builtin_memcpy(&_pw, (const void *)(p), 4)` does **not** compile to a word load here. The
compiler knows only that `p` is `_Float16 *` (2-byte aligned) and cannot see the loop invariant
that makes even-n elements 4-byte aligned, so it emits an unaligned byte-wise sequence:

    mnemonic counts inside matmul_8xVL, PACKED_A=1
      before fix:  lbu 96   slli 81   or 73   fmv.h.x 40   srli 16   lw 33(31 of them spills)
      after  fix:  lbu  0   slli  9   or  -   fmv.h.x 40   srli 16   lw 48(26 non-sp = 24 A + 2)

**96 lbu = 24 EVEN sites x 4 bytes.** The change intended to replace 2 `flh` per pair with 1 `lw`
was in fact issuing **4 byte loads** per pair -- strictly worse than the baseline it was measured
against. Fixed by stating the instruction directly:

    asm("lw %0, 0(%1)" : "=r"(_pw) : "r"((const void *)(p)));

The alignment argument is not lost, it just cannot be expressed to the compiler through a
`_Float16 *`; it is asserted in `main.c:253` (N even) and documented at the macro.

### How this was missed, and how it surfaced

The three checks that were run all PASSED and all were insensitive to the defect: `flh` went
40 -> 0, `fmv.h.x` went 0 -> 40, `srli` = 16. Every one of those is about the *consumer* of the
word; none is about *how the word was fetched*. The signal that did catch it was an arithmetic
inconsistency I initially waved past -- static `lw` rose only 19 -> 33 when 24 new load sites had
been added. **A count that does not add up is a finding, not a rounding error.**

### The broken arm is worth keeping as a control

`pa_off`/`pa_on` and `pa_ck_off`/`pa_ck_on` are all in flight with the byte-load version. Rather
than discard them: both the byte-load and word-load variants move A loads off the FP-LSU onto the
integer LSU (`flh` -> `lbu`/`lw`), so they share that change of load unit and differ ONLY in request
count (96 byte loads vs 24 word loads per row-block). That makes the accidental arm a control that
separates "fewer requests" from "different load unit" -- a decomposition the corrected pair alone
cannot provide.

NOTE -- load UNIT, not port. `spatz_mempool_cc.sv:327` instantiates
`tcdm_id_remapper #(.NumIn(2))` over `{fp_lsu_req, snitch_req}`, merging both onto a single
`data_req_d`: the shared scalar port 0. The variants therefore gain no bandwidth. What changes
is which unit's outstanding-request tracking applies (the FP-LSU is id-based OOO with 16
outstanding) and how the two streams arbitrate at the remapper. Do not describe this as
freeing or migrating a port.

It also means the earlier interim reading (RH 1677 -> 462, ~3.5x) is **not** a packed-A result and
must not be reported as one. It is the byte-load variant's result, and it is genuinely surprising:
4x MORE requests to the same word still cut stall episodes 3.5x, which points at the port
migration rather than the request count as the active ingredient. The corrected pair
(`pa_fx_off`/`pa_fx_on`) is what decides.

### Status

Six sims in flight: `pa_off`/`pa_on` (byte-load, no fingerprint), `pa_ck_off`/`pa_ck_on`
(byte-load, with fingerprint), `pa_fx_off`/`pa_fx_on` (word-load, with fingerprint). The last pair
is the one that answers the plan's question. Correctness gate unchanged: identical `[CKSUM]`.


---

## Step 6: the committed form, and an accidental variance floor (2026-08-21)

### Final form of the load

The raw `asm("lw %0, 0(%1)" ...)` fix gets the right instruction but tells the compiler nothing
about reading memory, so it is schedulable across barriers. Both forms are correct *today* -- A is
fully written before `matmul_8xVL` is entered, so there is no valid-data hazard to hoist past --
but the asm form would break silently if A were ever written in place. Committed form keeps
memcpy's aliasing safety AND the single load:

    __builtin_memcpy(&_pw, __builtin_assume_aligned((const void *)(p), 4), 4);

    variant                          lbu   non-sp lw   total lw   fmv.h.x   srli
      memcpy (original, BROKEN)       96          2         33        40      16
      asm lw                           0         26         48        40      16
      memcpy + assume_aligned          0         26         53        40      16

Same 24 A-word loads; `assume_aligned` costs 5 extra spill reloads over the asm form. Against 32
`vfmacc` per row-block that is not worth trading robustness for.

### Three baselines are running the same code -- keep them

`pa2_off`, `pa_ck_off` and `pa_fx_off` were built at different points, and their ELFs differ by
md5 -- but only through `__LINE__`/metadata shifts from comment edits. With addresses and opcode
bytes stripped, the `matmul_8xVL` disassembly is **byte-identical** across all three.

That was not planned, and it is worth keeping: three independent runs of identical code give a
**run-to-run variance floor**. Any packed-A delta smaller than the spread among those three is
noise, not signal. Without it, a single baseline-vs-packed pair offers no way to tell the
difference -- which is exactly how the `+2.6%` on `256x32x256` was over-read as a real cost.

### Arms in flight (7)

| arm | A-load | fingerprint | role |
|---|---|---|---|
| `pa2_off`, `pa_ck_off`, `pa_fx_off` | 40 `flh` | ck: yes | baseline x3 -> variance floor |
| `pa2_on`, `pa_ck_on` | 96 `lbu` | ck: yes | control: load unit changed, 4x MORE requests |
| `pa_fx_on` | 24 `lw` (asm) | yes | word-load, fewer spills |
| `pa_al_on` | 24 `lw` (assume_aligned) | yes | **the committed form -- this is the result** |


---

## Step 7: inline asm is the committed form (2026-08-21)

Step 6 chose `__builtin_assume_aligned` over inline asm on the grounds that a bare
`asm("lw %0, 0(%1)" : "=r"(w) : "r"(p))` tells the compiler nothing about reading memory. That
was a false binary: the deficiency is in **how the asm was written**, not in asm. The correct form
carries an `"m"` memory operand, which mandates the instruction AND states the memory dependency:

    asm("lw %0, %1" : "=r"(_pw) : "m"(*(const uint32_t *)(const void *)(p)));

    variant                          lbu   non-sp lw   total lw   fmv.h.x   srli
      memcpy (original, BROKEN)       96          2         33        40      16
      asm lw, register operand         0         26         48        40      16
      memcpy + assume_aligned          0         26         53        40      16
      asm lw, "m" operand   <-- USE    0         26         53        40      16

Identical counts to `assume_aligned`, so the `"m"` form costs nothing and is strictly stronger:
`assume_aligned` is a HINT the compiler is free to discard (it happened to honour it here), while
the asm is a guarantee. Given that this exact optimisation was already silently discarded once --
memcpy quietly becoming 96 `lbu` -- relying on a second hint would be repeating the mistake.

Codegen differs from the `assume_aligned` build only in register allocation and spill slots
(instruction counts are identical), so `pa_al_on` does not measure this binary exactly and
`pa_m_on` was launched. `pa_al_on` is kept: with the same instruction mix but different spill
placement, the pair bounds how much of any delta is register-allocation luck rather than the
load change.
