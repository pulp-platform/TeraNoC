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
| 128x256x512 | 16,384 | 21,614 | _running_ | — | 75.8% | — |
| 128x512x512 | 32,768 | 41,943 | _running_ | — | 78.1% | — |
| 128x1024x512 | 65,536 | 130,792 | _running_ | — | 50.1% | — |

`_running_` means no FINAL yet; it is not a result.

## 128x128x512 — verified, not just faster

A 1.81× speedup is exactly the shape of result that a **lost-work** bug produces, and this campaign
has already been bitten once by that (the `MshrCfgSubsW=4` truncation manufactured a fake 43% "win"
on this same family). So the cycle count alone was not accepted. The work counters:

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

## Consequence for the autotuner

The clamp in `gemm_autotune.py` is now obsolete and, on this family, expensive. `subs_b` should be
allowed to take the derived `share_b = 1` rather than being lifted to 2, and the paired
`hold_window_burst=0` mitigation becomes unnecessary — there is no window to hold.

## Open thread worth pulling

Two of the three runtime-CSR outliers are in this same `128x*x512` family (`128x256x512` +27.6%,
`128x512x512` +9.6%). If the CSR cold-start cost on those shapes is *paid on burst entries that were
never going to merge*, then bypassing bursts should remove that cost too. This is a hypothesis, not
a result — the third and largest outlier, `512x256x512` at +252.7%, is **B-share=4** and cannot be
explained this way, so at most this accounts for two of the three.

Testing it needs a `cfg_runtime=1` × `hold_subs_burst=1` arm on `128x256x512`, which is not yet run.
