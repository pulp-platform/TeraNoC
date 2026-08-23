# cvfpu (fpnew) pulp-v0.1.3 → pulp-v0.3.0 — migration assessment

**Question:** a colleague reports v0.3.0 has "much better PPA". Can we swap it into the Spatz VFU?

**Verdict (ORIGINAL, 2026-08-19 morning): do NOT upgrade for PPA — the likely win is available on
the version we already build.**

> **SUPERSEDED the same day. The upgrade was directed and has landed** (`5245676e` here,
> `37c8c33` in spatz). Shipping config is **v0.3.0 + `PipeConfig: INSIDE` + bf16 (FP16ALT) enabled,
> with fp32 and fp16 as the default working formats.** The analysis below stands on its own terms —
> the PPA *claim* was indeed unsupported for our Width=32 configuration — but the decision went the
> other way, and the migration was validated cycle-identical on all four acceptance fields
> (4188 cycles, busy=2156908 of 3938304 over 3846, retval=0, 67210.00 ns).
>
> Note the doc's own §1 reasoning explains why **bf16 is nearly free while FP8 is not**: bf16 is
> 16-bit, so `min_fp_width` over the enabled formats stays 16 and `max_num_lanes = Width/min_fp_width`
> is unchanged; FP8 would drop it to 8 and double the merged ADDMUL/CONV lanes. Same formula,
> opposite verdicts.
>
> ⚠️ **Still open:** the migration is proven cycle-identical on the **scalar** path only. The gate ran
> fp32, and at ELEN=32 fp32 sets `fpu_vectorial_op = 0` while fp16 sets it to **1** — so the
> vectorial slice, which is the only path fp16 uses, is unvalidated. A PRE/POST fp16 pair at one
> shape must land before any fp16 sweep number is quoted.

Current: `Bender.yml:19` pins `rev: pulp-v0.1.3` (commit `a8e0cba6`). Target tag `pulp-v0.3.0` =
`841b19b9`.

---

## 1. The PPA claim is unsupported for *our* configuration

Our config (`generated/spatz_pkg.sv`, non-RVD branch): Width=`ELEN`=32, FP32+FP16 only,
ADDMUL=MERGED, DIVSQRT=DISABLED, CONV=MERGED, NONCOMP=PARALLEL, SDOTP=DISABLED,
`PipeConfig: BEFORE`, N_FPU=4 per core × 256 cores.

* `docs/CHANGELOG-PULP.md` and `docs/CHANGELOG.md` in v0.3.0 contain **zero** occurrences of
  area / timing / PPA / power / optimiz / retim / fmax. Every v0.2.0→v0.3.0 entry is a **new
  feature** (MXDOTP, PACE, FP6/FP6ALT/FP4, THMULTI divsqrt) or a fix.
* The files carrying our datapath are **byte-for-byte identical**: `fpnew_rounding.sv`,
  `fpnew_fma.sv`, `fpnew_opgroup_fmt_slice.sv`, `fpnew_divsqrt_multi.sv`,
  `fpnew_divsqrt_th_32.sv`, `lfsr_sr.sv`.
* `fpnew_classifier.sv`'s new branches are guarded by an `MX` parameter defaulting to 0, which
  constant-folds back to the v0.1.3 behaviour.
* v0.3.0 does not change a single arithmetic expression in the merged FMA.

New features cost area unless disabled; the question was never "is v0.3.0 bigger" but "for a config
with everything new switched off, is our FP32+FP16 merged FMA better". It is not — it is the same
logic.

## 2. The probable confound, and the change actually worth testing

The colleague's snippet changes `PipeConfig: BEFORE → INSIDE` **alongside** the version bump. That
is a genuine Fmax lever and the plausible source of their result.

⚠️ **`INSIDE` is already supported by the v0.1.3 we build today** — `fpnew_fma_multi.sv:85`:

```systemverilog
localparam NUM_MID_REGS = PipeConfig == fpnew_pkg::INSIDE ? NumPipeRegs : ...
```

Why it should help *us* specifically: `spatz_vfu.sv:1000-1011` registers **every** fpnew input
(operands, op, fmts, rnd_mode, tag, valid), and `:1025` wires `operands_i` straight off those flops.
So the combinational depth feeding the FPU is **zero**, and `BEFORE` places our single ADDMUL
register back-to-back with a Spatz flop — buying almost nothing — while leaving the entire FMA
(classify → 24×24 multiply → align shift → add → LZC → normalise → round) as one unbroken
combinational block. `INSIDE` relocates that same register to just after the mantissa adder,
bisecting it.

**Latency-neutral**: the INSIDE split sums to exactly `NumPipeRegs`, so no cycle count and no
calibration number moves. One-line change, near-zero risk, and it isolates the suspected win from
the version bump.

**Do this first.** If it delivers, the upgrade may be unnecessary.

## 3. If we upgrade anyway — two blockers

### ⚠️ BLOCKER 1 — silent misconfiguration, presents as a hang

`fmt_logic_t` is **ascending**: `typedef logic [0:NUM_FP_FORMATS-1] fmt_logic_t;` (unchanged in both
versions), and `NUM_FP_FORMATS` goes 6 → 9.

Our mask is written as a 6-bit **concatenation**, not an assignment pattern:

```systemverilog
FpFmtMask : {RVF, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0}   // FP32 FP64 FP16 FP8 FP16a FP8a
```

Assigned to a 9-bit ascending vector, SystemVerilog pads on the **index-0 side**, shifting every
real bit by +3: **FP32 becomes disabled and FP8 enabled.** It compiles cleanly; then the merged
ADDMUL slice ties FP32's ready low, `in_ready_o` never asserts, and the VFU hangs on the first FP
instruction. Loud at runtime, invisible at compile time.

### ⚠️ BLOCKER 2 — outside the Spatz tree

`hardware/deps/snitch/src/snitch_pkg.sv:138,142,158,179` independently constructs one
`fpu_features_t` and **two** `fpu_implementation_t` with 6-bit masks and 5-row shapes — in a
vendored dependency, and it **is** compiled. Easy to miss entirely.

### Required edits (loud — these fail at compile, so they are low risk)

* `generated/spatz_pkg.sv` — `FPUFeatures` **both ternary arms** (both elaborate as constants even
  at RVD=0): widen `FpFmtMask` to 9 bits and add `MxFpFmtMask: 9'b0`, `MxIntFmtMask: 4'b0`,
  `PaceFeatures: '{default: 0}`.
* `MemPoolFPUImpl` — `PipeRegs` needs a 6th row (MXDOTP) **and** 6→9 columns; `UnitTypes` needs only
  the 6th row (its rows use `'{default: …}`, which auto-sizes). **MXDOTP must be `DISABLED`** — its
  source notes *"Assumes width == 64"* and we are Width=32.
* ⚠️ **Generated-file trap**: `generated/spatz_pkg.sv` has a template (`.tpl`). The generator is
  never run by this build, so edit **both** — the build will not regenerate the fix for you.
* `spatz_vfu.sv` — connect the two new inputs `pace_param_i`, `pace_mode_i` (tie to `'0`; dead when
  PACE is disabled). **No parameter change needed**: Spatz never passes `PulpDivsqrt`, so the
  `PulpDivsqrt → DivSqrtSel` rename requires no edit.
* Root `Bender.yml` — one line, then `bender update`. The new vendored sources are listed in
  v0.3.0's own Bender.yml and need nothing extra.

## 4. Do NOT adopt these choices from the colleague's snippet

| their choice | verdict |
|---|---|
| `FpFmtMask` enabling **FP8** | **Reject.** `max_num_lanes = Width / min_fp_width` over *enabled* formats. FP8 takes `min_fp_width` 16→8, doubling merged ADDMUL **and** CONV lanes from 2 to 4 at Width=32 — pure area for a format we cannot issue. Also incoherent: the VFU's EW_8 branch selects FP8ALT when `fm.src/dst` is set, and their mask leaves FP8ALT off. |
| `IntFmtMask` enabling **INT8** | **Reject.** Only buys 8-bit conversions in the merged CONV unit, unreachable without FP8. Keep ours. |
| `.StochasticRndImplementation(DEFAULT_RSR)` | **No-op for us — we already pass it** (`spatz_vfu.sv:1018`), and it is inert because RSR only reaches the DOTP block, which we disable. Worth flipping to `DEFAULT_NO_RSR` on principle so that enabling DOTP later cannot silently add 2× 32-bit LFSR + FSM + comparator per FPU across 1024 FPUs. |
| `PipeConfig: INSIDE` | **Adopt — but on v0.1.3 first** (see §2). |

## 5. Corrections to earlier claims in this investigation

Three things asserted while scoping this turned out to be wrong, all corrected by reading source:

1. `gated_clk_cell.v` is **not** new — already present in v0.1.3's Bender.yml and already compiled.
2. `StochasticRndImplementation` is **not** new — it exists in v0.1.3 at the same position with the
   same default, and Spatz already passes `DEFAULT_RSR`.
3. Spatz does **not** pass `PulpDivsqrt`, so that rename is a non-event for us.

## 6. Cheapest regression proof, if the swap is attempted

A correct translation is provably **cycle-identical** (no latency change from any required edit), so
one fast arm settles it:

* **Arm 0** — current tree, `sp-fmatmul` 256x32x256 on `terapool_spatz4_fpu` (4x4, 256 cores).
  Golden is **4,081 cycles** (`docs/benchmarks/gemm_results.md:65`); our current builds read
  **4,188**.

  ⚠️ **That 107-cycle gap is NOT instrumentation overhead** — an earlier version of this line said
  it was, and that was wrong. A cycle-accurate sim's cycle count is invariant to passive probes:
  TB counters and `$countones` observe the design without participating in it, so they cost
  wall-clock, not simulated cycles. The gap is **baseline drift**. `sp-fmatmul-gvsoc-probe` and
  `sp-fmatmul-opt-burst-merge` have byte-identical `main.c` and `kernel/`, both run 256x32x256,
  and both compile `HOLD_SUBS_SINGLE=8` / `HOLD_SUBS_BURST=2` — matching the golden row's
  A-sh=8 / B-sh=2. What differs is the RTL: the golden table was last regenerated **2026-08-03**
  (`4d3d9d17`) and at least a dozen functional commits have landed since, including
  `c05d54c1` noc_router_remapping 0→2, `ee38f5ff` bank_publish→1, `8ca4f060` hold window 2047,
  `fa00ffb5` drain_from_q→1, `f7a7e90f` MSHR C2 spill bypass, and `7737baee`, a C1 rank/slot
  truncation **bug fix**.

  So use 4,188 as the same-tree baseline for any arm built today, and treat every row of the
  2026-08-03 golden table as stale by an unquantified amount until re-measured.
* **Arm 1** — same ELF, same pinned defines, v0.3.0 RTL. **Must reproduce the same cycle count.**
  Any delta means the translation is wrong, not that the FPU is different.

⚠️ Diff the **full** define set between arms before comparing, and check the cycle count as an
external invariant — an instrument change and a config change can arrive in the same run, and the
config change is the silent one.

## 7. What cannot be determined from source

The actual area/fmax delta. Nothing in the RTL gives it. If the PPA question matters, synthesise
**v0.1.3+BEFORE vs v0.1.3+INSIDE** first — that isolates the pipeline-placement lever from the
version bump, and it is the comparison most likely to explain the colleague's result.
