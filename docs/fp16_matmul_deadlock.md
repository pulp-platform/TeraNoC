# fp16 sp-fmatmul deadlocks at 512x512x512 — investigation state

2026-08-18. **Open bug.** Root cause NOT found. This records what has been eliminated (with
evidence) so the next person does not repeat it, and hands over the one correction that
invalidated part of the first analysis.

## Symptom

`sp-fmatmul-opt-burst-merge-fp16` deadlocks during the **icache warm-up pass** at every shape
tried so far (512x512x512 and 512x64x256 alike)
(before the timed region opens):

- every core stops retiring at cycle **12,000-18,000**; the sim runs on to 98,000 with
  `[STALLG] ins=0 raw=16000/16000` — a 100% RAW stall on every core
- `[CMS] inflight=2` (vs **9,921** in the healthy fp32 arm at the same point): the machine is
  *idle*, not thrashing
- stuck requests with monotonically growing `age`; cores are parked on
  `vfmacc.vf v0, ft7, v20`, waiting for a `vle16.v` that never lands
- the fp32 arm on the identical kernel structure is healthy and reaches its benchmark at 53,000

## What it is NOT (each with evidence)

| hypothesis | verdict | evidence |
|---|---|---|
| the new `spatz_vlsu_burst_ew16` gate | **NO** | arm B ran with `SPATZ_VLSU_BURST_EW16=0` (verified in its build log) and hung identically |
| `spatz_vlsu_dual_load` runahead | **NO** | dual_load 2 vs 1 on the same shape are **byte-identical at every period** (1447 / 4810 / 1044 / 433 …) and both deadlock at **exactly cyc=13000**. Not a timing coincidence to be explained away: the feature makes no difference whatsoever to this workload |
| group-barrier arrival mismatch | **NO** | `bar_rel=+16` (barriers firing) and `bar_max=40` (tiny spread) right up to the stall; the healthy fp32 arm reaches `bar_max=9664`. Barriers stopped because cores stopped *arriving* — downstream of the fault |
| `vl` -> bytes conversion for e16 | **NO** | `spatz_vlsu.sv:190` `EW_16: vl << 1` is correct (64 elements -> 128 B) |
| MSHR hold / subscriber config | **NO** | `[RH STUCK] subs=2/4` appears **more** often in the healthy fp32 arm (462 vs 128), and the MSHR defines are identical between the two builds |
| address misalignment | **NO** | `mem_is_addr_unaligned` is `rs1[1:0] != 0`; the stuck address `0xa1740` is even 64-B aligned |

## ⚠️ The correction that invalidated the first analysis

**`bl=1` in `[CMS WARN] STUCK_REQ` does NOT mean "this load never became a burst."**
`tb_core_mem_scoreboard.sv:281-308` *expands* a burst request of length N into **N separate
entries, one per expected beat id, each with `burst_len = 1`**. So `bl=1` is exactly what a
burst's individual beats look like in this probe.

Several deductions were built on the opposite reading — that the load had fallen off the port-0
burst path, hence that `use_port0_burst_req` must have failed its alignment test. All of that is
void. Check what a TB probe *records* before inferring hardware behaviour from it.

## Facts the root cause must explain

1. **It is the SCALAR path.** At the moment of the wedge the stuck requests are on **port 0 —
   the scalar port** — at addresses `0x000217e8` and `0x000217f4`, i.e. inside `a` and exactly
   **12 bytes apart = 6 fp16 elements = the warm-up's clamped N**. That is the `flh` walk down a
   column of A, `a__ += N`. Cores stall on `vfmacc.vf` because its *scalar* operand never returns,
   not because the vector load failed. (Vector-buffer addresses appear stuck too, but downstream.)

   **Leading hypothesis.** At fp32 every scalar FP load is a full 32-bit word. At fp16 `flh` is a
   **sub-word** load and two adjacent A elements share one word. The group MSHR admits singles
   into its merge pool (`group_mshr_enable_single=1`) and *holds* the response until
   `group_mshr_hold_subs_single=4` subscribers arrive (`group_mshr_resp_wait_subs_single=1`).
   Sub-word scalar requests are a case that path has never seen. Tests in flight:
   `group_mshr_enable_single=0` (singles bypass the MSHR entirely) and
   `group_mshr_resp_wait_subs_single=0` (deliver immediately, do not hold for subscribers).
2. **The stuck pattern differs by gate, as the request paths do.** Gate OFF: 426 distinct stuck
   addresses stepping individually (`0xa1500`, `0xa1510`, `0xa1520`, separate ids) — the
   word-interleaved multi-port path. Gate ON: many ids collapsed on one address — burst beats.
   Both deadlock.
3. **It is NOT shape-dependent — corrected 2026-08-18.** An earlier revision of this file claimed
   `512x64x256` ran clean; it does not, it deadlocks at ~12,000 cycles exactly like `512x512x512`.
   It was merely slower to arrive. **This is the useful correction**: a shape with an ideal of
   4,096 cycles reproduces the bug, so the repro is cheap and does not need the 2-hour full shape.
   Both shapes fail at ~12k, and both run the same warm-up (N clamped to 6, m range 0-8), so the
   trigger is in the warm-up rather than in the matmul dimensions.
4. **It fires in the warm-up pass**, where `ICACHE_WARMUP_N` clamps N to 6, so the A row stride is
   degenerate (6 elements = 12 B). The fp32 build survives the same clamp.

## Context worth knowing

The entire aggressive VLSU feature stack — `block_alloc`, ROB64, `dual_load`, and the burst path
itself — was designed and validated **at e32 only**. All three design docs
(`spatz_mlp_design_plan.md`, `spatz_rob64_h1_design_plan.md`, `tcdm_burst_interleave_design.md`)
mention `e16` **zero** times, and the ROB64 doc reasons explicitly in terms of "two e32,m2 loads =
2*32 ids exactly fill ROB0". The two other e16 apps in the tree (`gemv`, `gemv-bk`) have no built
binaries. The e16 VLSU path looks genuinely unexercised.

Note the ROB is an in-order **ring** (`read_pointer` / `write_pointer` / `status_cnt`), not a free
list, so an id "leak" is not possible — but a stall-forever is: if a burst reserves `BlockWords`
ids and fewer beats return, the ring can never advance past them.

## ⭐ THE KEY FINDING: it is the VLSU COMMIT path, not the memory system

Arm H1 (`group_mshr_enable_single=0` + `resp_wait_subs_single=0` — scalar requests never enter
the MSHR at all) still deadlocks, one period later at cyc=14000. **But its signature is completely
different from the baseline:**

| | baseline | H1 (singles out of MSHR) |
|---|---:|---:|
| stuck requests | 2,385 | **0** |
| `[RH STUCK]` held entries | 174 | **0** |
| bank census | `hold=4 inv=0` (full) | — (none held) |
| **CMS `inflight` at the hang** | 2 | **0** |

**`inflight = 0`.** At the moment of the deadlock there is not a single outstanding memory
request — and yet every core is RAW-stalled (`raw=14962/16000`) at
`0x800002d4 = vfmacc.vf v0, ft7, v20`, waiting for `v20`.

If no memory operation is pending, the load's data has already come back. The VLSU is **not
committing it to the vector register file**, so the scoreboard keeps `v20` busy and the dependent
`vfmacc` never issues. That is a Spatz-internal stall in the load *commit* path, not a memory
system problem.

**This reinterprets everything earlier in this file.** The MSHR bank saturation (`hold=4, inv=0`)
and the 2,385 stuck requests in the baseline are a **downstream symptom**: cores stall -> their
loads never retire -> requests pile up -> banks fill. Remove singles from the MSHR and the symptom
disappears entirely while the deadlock survives. Do not chase the MSHR.

**Corollary — why every MSHR knob was inert.** `dual_load`, `resp_wait_subs_single` and
`enable_single` were all tested and none prevents the hang, which is exactly what you expect if
the fault is downstream of the memory system. `enable_single` is the only one that changes
anything at all (it removes the symptom and delays the hang by one period).

**⚠️ A methodology error worth not repeating.** H1 was byte-identical to the baseline for its
first ten periods, and that was read as "the knob is inert". It is not: the early periods are
boot and DMA, before the workload generates remote traffic, so *no* MSHR knob can differ there.
The divergence appears at cyc=11000 the moment real traffic starts. **Never conclude equivalence
from periods in which the mechanism under test is not yet exercised.**

## Next step: waveforms, now well-targeted

Log-level analysis is exhausted. The concrete next move is to take one stuck request and follow
it from issue to non-response:

The search is now narrow: **one core's VLSU, at the moment its load data returns.**

1. Fast repro: `512x64x256` fp16, `hardware/matmul_fp16_512x64x256.elf`, deadlock at cyc 13000-14000.
2. Re-run with logging scoped to ONE core's Spatz VLSU (the whole design is not needed).
3. Watch, for the load that fills `v20`: the ROB pop, `commit_counter_*`, the VRF write-enable, and
   the instruction-retire/scoreboard-release signal. The data returns (`inflight=0`); the question
   is which of those never fires at `vsew = EW_16`.
4. **PRIME SUSPECT — an exact-equality completion test.** `spatz_vlsu.sv:632`:

   ```systemverilog
   assign commit_finished_q[fu] = commit_insn_valid && (commit_counter_q[fu] == commit_counter_max[fu]);
   ```

   `==`, not `>=`. If a commit ever advances the counter **past** max, this never matches, the
   load never completes, `mem_finish_ready` (`:818`) never asserts, and the destination vector
   register is never released — a permanent stall with the data already returned and nothing
   outstanding. **That is exactly the measured signature.**

   The commit delta is element-size dependent —
   `commit_single_element_size = 1 << commit_insn_q.vsew` (2 B at e16) versus `ELENB` (4 B) for
   the full-word path (`:1064-1066`) — and `switch_to_tail_phase` re-bases the counter mid
   instruction (`:1070`). An overshoot at e16 is plausible there and is invisible at e32, where
   element size and word size coincide so every delta divides `max` evenly.

   **To confirm:** log `commit_counter_q[fu]`, `commit_counter_max[fu]` and `commit_counter_delta[fu]`
   for the stalled core and look for `q > max`. If confirmed, the minimal fix is `>=` (with a
   width check), but the *correct* fix is to stop the overshoot at source.

## Status of the surrounding work

The RTL change this was meant to exercise is **independently proven safe**: the same fp32 ELF run
with `spatz_vlsu_burst_ew16` 0 vs 1 is byte-identical over 280+ probe-periods across five counters
(`scripts/check_arm_equivalence.py`), both arms opening the timed region at exactly cyc=53000. The
deadlock does not implicate it and does not block landing it.
