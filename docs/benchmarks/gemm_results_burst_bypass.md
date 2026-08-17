# GEMM benchmark results — burst bypass on the B-share=1 family

Generated 2026-08-16. One knob against `phaseE1`: **`group_mshr_hold_subs_burst` 2 → 1**.

Not part of the chained sweep — this is a targeted four-arm experiment on the only shapes the knob
can affect. See [`README.md`](README.md) for the chain.

## The question

`gemm_autotune.py` derives `share_b = split_m_count`, and for the `128x*x512` family that is **1**:
B is private to each core, so a second requester for a burst line can never arrive. The honest MSHR
setting is therefore "do not hold burst entries at all". But the elaboration guard used to demand
`hold_subs ∈ [2, MshrMergeReqs]`, so the script clamped:

```python
subs_b = min(max(share_b, 2), merge)     # 1 -> 2, and its own comment says why
```

and paired the clamped 2 with `hold_window_burst=0` as a mitigation. The guard was relaxed to
`[1, MshrMergeReqs]` on 2026-08-16, and 1 now has a defined meaning — `cfg_bypass_burst`: bursts
skip the MSHR entirely. No entry, no hold, nothing to wait for.

So: **was the clamp costing anything?**

## Method

Deliberately `group_mshr_cfg_runtime=0` and the original non-CSR ELF, so this is a clean one-knob
comparison against phaseE1 and is independent of the runtime-CSR feature (which currently carries an
unexplained stall on two shapes — see [`gemm_results_mshr_ppa_csr.md`](gemm_results_mshr_ppa_csr.md)).

Each arm gates on a **full** `GROUP_MSHR_*` define diff against its phaseE1 pair, excluding only
`GROUP_MSHR_HOLD_SUBS_BURST`; any other difference aborts the arm before it runs. All four printed
`gate OK · GROUP_MSHR_HOLD_SUBS_BURST=1`.

Efficiency is `ideal / actual` with `ideal = M·N·P / 1024` (4×4, 1024 FPU lanes) — not the TB's
`[FPU] util` counter, which is lane occupancy and is not conserved across runs of identical work.

## Results

| M×N×P | ideal | phaseE1 cyc | **bypass cyc** | Δ | eff phaseE1 | **eff bypass** |
|---|---:|---:|---:|---:|---:|---:|
| 128x128x512 | 8,192 | 16,995 | **9,401** | **−44.68%** | 48.2% | **87.1%** |
| 128x256x512 | 16,384 | 21,614 | **17,627** | **−18.45%** | 75.8% | **92.9%** |
| 128x512x512 | 32,768 | 41,943 | **34,041** | **−18.84%** | 78.1% | **96.3%** |
| 128x1024x512 | 65,536 | 130,792 | **67,005** | **−48.77%** | 50.1% | **97.8%** |

**All four arms complete.**

**The win does NOT shrink with N.** After −44.7% at N=128 and −18.5% at N=256 the obvious reading
was that a larger N amortises the wasted allocation and the benefit decays to nothing; N=512 came in
at −18.8% and N=1024 at **−48.8%**, the largest of the four. So the cost is not a fixed overhead
being amortised — it scales with the work, which is what a per-burst-miss penalty should do. The
four arms land at **87.1% / 92.9% / 96.3% / 97.8%** of roofline against 48.2% / 75.8% / 78.1% / 50.1%.

**97.8% is the highest efficiency measured anywhere in this campaign**, against a previous best of
95.8% (`256x1024x256`) — and it comes from the shape with the *worst* standing regression, which
sits at 50.1% on the shipping default.

`alloc_burst` under the clamped setting scales **61,344 → 122,721 → 245,540 → 491,216** across the
four shapes: an exact doubling with N, merging zero every time. That is the whole finding in one
row — the waste is proportional to the work, so no amount of scaling escapes it.

## Verification — all four arms, not just faster

A 1.8× speedup is exactly the shape of result that a **lost-work** bug produces, and this campaign
has already been bitten once by that (the `MshrCfgSubsW=4` truncation manufactured a fake 43% "win"
on this same family). So no cycle count here was accepted on its own; each arm had to show that the
FPU retired the same work and that the single path was untouched.

### 128x128x512

| | phaseE1 | bypass | |
|---|---:|---:|:--|
| FPU busy lane-cycles | 8,474,768 | 8,447,676 | −0.32% — **same work retired** |
| `alloc_single` | 15,356 | 15,360 | +0.03% |
| `merged_single` | 230,224 | 230,400 | +0.08% |
| `alloc_burst` | **61,344** | **0** | bursts now bypass |
| `merged_burst` | **0** | **0** | ← the finding |

The single path is untouched to within 0.08% and the FPU retired the same work to within 0.32%, so
the 7,594 cycles are genuinely saved rather than skipped.

**The mechanism is one row.** phaseE1 allocated **61,344 burst MSHR entries and merged exactly zero
of them.** That is what `share_b = 1` means — there is no second requester, so no burst entry can
ever find a partner. Every one of those allocations was pure added latency in the path of a load
that was going to miss anyway. Bypassing them removes the cost without removing any coalescing,
because there was none to remove.

Benchmark-phase utilisation confirms it from the other side: seven consecutive periods at
99.6–99.9%, i.e. essentially at the FPU roofline. The residual gap to 100% efficiency is the cold
head period (73.97%) and the tail (52.93%), not steady-state stall.

Sanity checks that came back clean: `Mismatch in route selection!` appears exactly once in *both*
arms (background, not introduced here); no assertion, error, or mismatch output otherwise.

### 128x256x512

The same signature, independently:

| | phaseE1 | bypass | |
|---|---:|---:|:--|
| FPU busy lane-cycles | 16,880,884 | 16,857,588 | −0.14% — **same work retired** |
| `alloc_single` | 30,716 | 30,720 | +0.01% |
| `merged_single` | 460,634 | 460,800 | +0.04% |
| `alloc_burst` | **122,721** | **0** | bursts now bypass |
| `merged_burst` | **0** | **0** | ← again, zero merges to lose |

122,721 burst allocations, zero merges — twice the count of the smaller shape, same useless outcome.

### 128x512x512

| | phaseE1 | bypass | |
|---|---:|---:|:--|
| FPU busy lane-cycles | 33,774,128 | 33,631,728 | −0.42% — **same work retired** |
| `alloc_single` | 61,433 | 61,440 | +0.01% |
| `merged_single` | 921,431 | 921,600 | +0.02% |
| `alloc_burst` | **245,540** | **0** | bursts now bypass |
| `merged_burst` | **0** | **0** | ← third shape, still zero |

Three independent shapes now show `merged_burst = 0` under the clamped setting, with `alloc_burst`
scaling 61,344 → 122,721 → 245,540 — exactly doubling with N, and never merging once. That makes
this a property of `share_b = 1` rather than a quirk of one geometry.

### 128x1024x512

| | phaseE1 | bypass | |
|---|---:|---:|:--|
| FPU busy lane-cycles | 67,392,360 | 67,225,984 | −0.25% — **same work retired** |
| `alloc_single` | 122,874 | 122,880 | +0.005% |
| `merged_single` | 1,842,910 | 1,843,200 | +0.016% |
| `alloc_burst` | **491,216** | **0** | bursts now bypass |
| `merged_burst` | **0** | **0** | fourth shape, still zero |

**Against the 2026-08-03 baseline this shape goes from +93.2% to −1.0%** — the campaign's worst
standing regression becomes a small improvement.

Four shapes, `alloc_burst` **61,344 → 122,721 → 245,540 → 491,216** — an exact doubling with N — and
`merged_burst = 0` in every single one. That is why the benefit does not decay with N: the waste
grows at the same rate as the work.

## Consequence for the autotuner

The clamp in `gemm_autotune.py` is now obsolete and, on this family, expensive. `subs_b` should be
allowed to take the derived `share_b = 1` rather than being lifted to 2, and the paired
`hold_window_burst=0` mitigation becomes unnecessary — there is no window to hold.

## Open thread worth pulling

The CSR sweep is now complete at 22 arms, and **every measured member of this family is an outlier**:

| shape | B-share | CSR Δ vs phaseE1 |
|---|---:|---:|
| `512x256x512` | 4 | **+252.7%** |
| `128x1024x512` | 1 | **+67.9%** |
| `128x256x512` | 1 | **+27.6%** |
| `128x512x512` | 1 | **+9.6%** |

Those are the *only* four arms above +5%; the other 18 sit at a median of +0.31% with a maximum of
+3.46%. Three of the four are `share_b = 1` — that is all three family members that have a CSR arm
(`128x128x512` has none) — so the family is 3-for-3, and only one shape outside it regresses at all.

If the runtime-CSR cost on those shapes is *paid on burst entries that were never going to merge*,
then bypassing bursts should remove it. That is a hypothesis, not a result, and it cannot be the
whole story: the largest outlier, `512x256x512`, is **B-share=4** and needs a different explanation.

## CONFIRMED — bypass removes the runtime-CSR penalty entirely, on all four shapes

Each `csrbypass` arm ran `cfg_runtime=1` **with** `hold_subs_burst=1`, on the *same*
`build_sweepCSR_<shape>` binary as its `sweepCSR` pair. Under `cfg_runtime=1` the value software
writes over the CSR wins (`mempool_group_mshr.sv:494`), so the RTL was bit-identical and the CSR
write was the only variable in the experiment — the tightest control in the campaign.

| M×N×P | baseline | `E1` | `CSR` | `BYP` | **`CSRBYP`** | eff | CSR cost **with** bypass | Δ vs baseline |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 128x128x512 | 9,792 | 16,995 | 207,223 | 9,401 | **9,478** | 86.4% | **+0.82%** | **−3.2%** |
| 128x256x512 | 18,082 | 21,614 | 27,579 | 17,627 | **17,658** | 92.8% | **+0.18%** | **−2.3%** |
| 128x512x512 | 34,489 | 41,943 | 45,969 | 34,041 | **34,120** | 96.0% | **+0.23%** | **−1.1%** |
| 128x1024x512 | 67,693 | 130,792 | 219,562 | 67,005 | **67,145** | 97.6% | **+0.21%** | **−0.8%** |

**Without** bypass the runtime CSR cost these same four shapes **+1119.3% / +27.6% / +9.6% /
+67.9%**. With it, **+0.82% / +0.18% / +0.23% / +0.21%** — all four inside the +0.31% median
cold-start cost the CSR shows on the 18 healthy shapes. The shape-specific penalty is not reduced,
it is *gone*, and that holds for both failure modes: the mild degradations **and** the hard collapse
on `128x128x512`, which went from a 12.2× blow-up to parity.

Every `csrbypass` arm is byte-identical to its `bypass` twin on the single path — e.g. at N=1024
both report `alloc_single=122,880`, `merged_single=1,843,200`, `alloc_burst=0`, `merged_burst=0`.
So how the `1` arrives (elaborated or written by software) changes nothing; only its value matters.

**All four shapes now sit at or below the 2026-08-03 baseline** on the full stack — CSR hardware
present, runtime-enabled, software-configured — at 86.4–97.6% of roofline.

## What this does NOT explain

`512x256x512` is `share_b = 4`. Its burst entries genuinely merge, bypass does not apply, and it
still collapses under `cfg_runtime=1` (+252.7%). After this it is the **only** unexplained CSR
regression in the 23-shape sweep.

⚠️ **Every arm in this campaign, including all of the above, runs `group_mshr_hold_prescale_w=0`,
which is NOT the shipping default (`4`).** The pin keeps one-knob deltas cycle-accurate — at 4 each
hold counter ticks once per 16 cycles, and that quantisation would sit on top of sub-1% effects —
but it means these absolute numbers describe a configuration nobody builds. 0 of 188 campaign arms
have ever measured `prescale_w=4`. A `presc4_512x256x512` arm is running to close that gap on the
one shape where it matters most.
