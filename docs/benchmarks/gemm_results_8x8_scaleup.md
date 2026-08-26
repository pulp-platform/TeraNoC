# GEMM results — 8×8 mesh, 1024 cores — 248-shape scale-up campaign

Generated 2026-08-26 08:32 by `scripts/gen_8x8_scaleup_doc.py`. **Re-run rather than editing.**

`eff = ideal/actual`, `ideal = M·N·P / lanes` (fp16 8192 MAC/cyc, fp32 4096). Rank on `eff`,
not on the TB `util` column — that counter is lane *occupancy*, is not conserved across runs
of identical work, and has inverted a real ranking before.

> **Not comparable with `gemm_results_8x8_1024core.md`.** That file records a different sweep
> (MSHR / response-channel, single shape 2048×512×512) whose build dirs were reclaimed.

## Campaign state

| | count |
|---|---:|
| measurements | **154** |
| recorded livelock (failures, excluded below) | **50** |
| of manifest | 248 |

Efficiency over the 154 measurements: **median 39.2%**, mean 41.0%, range 7.4–89.1%.

## Cohort target × P

`MSHR_D_HOLD_SUBS_SINGLE` is derived from `M` alone; whether the cohort can form depends
on `P`. Mean efficiency by (target, P) over measurements only:

| target \ P | 128 | 256 | 512 | 1024 | 2048 |
|---:|---:|---:|---:|---:|---:|
| **16** | — | 36.5% (7) | 48.3% (14) | 45.1% (12) | 36.7% (4) |
| **8** | 36.6% (7) | 48.1% (12) | 57.3% (10) | 56.5% (9) | 66.9% (3) |
| **4** | 36.7% (8) | 53.4% (9) | 59.4% (7) | 53.6% (4) | 62.0% (2) |
| **1** | 17.5% (18) | 22.8% (15) | 29.6% (11) | 31.3% (2) | — |

Livelock arms are excluded, so the low-target/low-P cells read better here than the
campaign actually ran — the failures are listed separately below.

## Best 12 by efficiency

| shape | prec | target | B slice | cycles | eff | util | RH |
|---|---|---:|---:|---:|---:|---:|---:|
| `2048x2048x256` | fp16 | 4 | 128B | 147,182 | **89.1%** | 91.84% | 4 |
| `1024x1024x512` | fp16 | 8 | 128B | 75,645 | **86.6%** | 89.79% | 0 |
| `2048x1024x256` | fp16 | 4 | 128B | 78,437 | **83.6%** | 87.42% | 0 |
| `1024x512x512` | fp16 | 8 | 128B | 39,928 | **82.1%** | 85.86% | 0 |
| `1024x1024x256` | fp32 | 8 | 128B | 81,530 | **80.4%** | 84.42% | 0 |
| `2048x1024x128` | fp32 | 4 | 128B | 83,310 | **78.7%** | 82.63% | 0 |
| `2048x512x512` | fp32 | 4 | 512B | 174,741 | **75.0%** | 80.85% | 0 |
| `1024x512x256` | fp32 | 8 | 128B | 43,777 | **74.9%** | 79.32% | 0 |
| `2048x512x256` | fp32 | 4 | 256B | 88,041 | **74.4%** | 80.28% | 0 |
| `2048x256x512` | fp16 | 4 | 256B | 44,586 | **73.5%** | 78.15% | 0 |
| `512x1024x1024` | fp16 | 16 | 128B | 90,013 | **72.8%** | 81.26% | 0 |
| `1024x256x512` | fp16 | 8 | 128B | 22,504 | **72.8%** | 77.60% | 0 |

## Worst 12 by efficiency

| shape | prec | target | B slice | cycles | eff | util | RH |
|---|---|---:|---:|---:|---:|---:|---:|
| `4096x32x128` | fp16 | 1 | 128B | 14,362 | **14.3%** | ~18.36% | 0 |
| `8192x32x256` | fp32 | 1 | 1024B | 114,936 | **14.3%** | 16.71% | 0 |
| `4096x32x256` | fp32 | 1 | 512B | 58,440 | **14.0%** | 15.90% | 0 |
| `8192x32x512` | fp16 | 1 | 1024B | 118,658 | **13.8%** | ~16.02% | 0 |
| `8192x32x256` | fp16 | 1 | 512B | 70,746 | **11.6%** | ~13.97% | 0 |
| `8192x32x128` | fp32 | 1 | 512B | 75,423 | **10.9%** | 13.79% | 0 |
| `4096x64x256` | fp16 | 1 | 256B | 76,555 | **10.7%** | ~12.26% | 0 |
| `8192x256x128` | fp16 | 1 | 256B | 314,480 | **10.4%** | ~12.07% | 0 |
| `8192x128x128` | fp16 | 1 | 256B | 166,574 | **9.8%** | ~11.40% | 0 |
| `8192x32x128` | fp16 | 1 | 256B | 43,048 | **9.5%** | ~12.68% | 0 |
| `2048x32x256` | fp16 | 4 | 128B | 22,626 | **9.1%** | 10.92% | 270 |
| `2048x32x128` | fp16 | 4 | 64B | 13,840 | **7.4%** | 9.27% | 250 |

## Low efficiency with `RH = 0` — a second, separate mechanism

40 measurements sit below 25% efficiency with **no** RH-livelock. Their `N` distribution:

| N | arms |
|---:|---:|
| 32 | 17 |
| 64 | 9 |
| 128 | 8 |
| 256 | 5 |
| 512 | 1 |

Small contraction depth, not the cohort mechanism. Distinct from the livelock and
not addressed by any MSHR hold-window change.

## Gated shapes (5) — withdrawn from the sweep

The **N=32 / P=2048** family. 26 dispatches across 5 shapes, roughly 480 licence
seat-hours, and **not one completed run**. Every copy ran 59-118x over its ideal
cycle count and never reached the end of the kernel.

This is **not** the sub-burst livelock below: these B slices are 256-512 B, well
past the 128 B optimum, and they carry `RH = 0` and `mshr_timeout = 0`. It is the
low-N collapse -- at `N = 32` there is too little contraction work to keep a
1024-core mesh fed -- taken to the point where the shape does not finish in any
budget worth spending.

They are gated by name in `scripts/badist/feasibility.py`. The dispatchers block on
*evidence*, and "never produced a number" is not evidence they can read: with no
delivered utilisation and no RH count there was nothing to observe, so the family
stayed eligible and the top-up loops re-dispatched it indefinitely.

| shape | prec | B slice | role |
|---|---|---:|---|
| `1024x32x2048` | fp16 | 512B | gated |
| `2048x32x2048` | fp16 | 1024B | gated |
| `512x32x2048` | fp16 | 256B | **GUI debug shape** — reproduce this one interactively |
| `1024x32x2048` | fp32 | 1024B | gated |
| `512x32x2048` | fp32 | 512B | cross-precision control |

`fp16_512x32x2048` is the shape to open in QuestaSim when someone debugs this collapse: the
smallest `M` in the family, so the shortest elaboration, at the precision the decode
workload uses. `fp32_512x32x2048` is the control if the fp16 datapath itself falls
under suspicion.

## Recorded LIVELOCK (50) — failures, not results

Root cause: the per-core **B slice** `(P/SPLIT_P)*elem_bytes` is below the **64-byte** burst floor, so B cannot burst, falls back to single-word requests, and inherits `hold_subs_single` — a target derived for **A**, which B can never meet because each core owns a distinct `p` range. See `docs/benchmarks/8x8_scaleup/rh_livelock_root_cause.md` §0. **Every one of these has a sub-burst B slice.** Averaging them into the campaign drags the mean by ~7 pp.

| shape | prec | target | B slice | util | RH |
|---|---|---:|---:|---:|---:|
| `1024x1024x128` | fp16 | 8 | **32B** | ~2.25% | 176966 |
| `1024x128x128` | fp16 | 8 | **32B** | ~3.98% | 373567 |
| `1024x2048x128` | fp16 | 8 | **32B** | ~1.50% | 181995 |
| `1024x256x128` | fp16 | 8 | **32B** | ~2.93% | 167165 |
| `1024x32x128` | fp16 | 8 | **32B** | 0.59% | 123743 |
| `1024x32x2048` | fp16 | 8 | **512B** | ~0.39% | 0 |
| `1024x512x128` | fp16 | 8 | **32B** | ~2.34% | 134546 |
| `1024x64x128` | fp16 | 8 | **32B** | ~4.58% | 201236 |
| `1024x64x2048` | fp16 | 8 | **512B** | ~0.55% | 0 |
| `1024x64x2048` | fp32 | 8 | **1024B** | ~0.41% | 0 |
| `2048x128x128` | fp32 | 4 | **128B** | ~0.32% | 0 |
| `2048x128x256` | fp32 | 4 | **256B** | ~0.46% | 0 |
| `2048x256x128` | fp32 | 4 | **128B** | ~0.49% | 0 |
| `2048x256x256` | fp32 | 4 | **256B** | ~1.67% | 0 |
| `2048x32x1024` | fp32 | 4 | **1024B** | ~0.50% | 0 |
| `2048x32x2048` | fp16 | 4 | **1024B** | ~0.32% | 0 |
| `2048x32x256` | fp32 | 4 | **256B** | ~0.09% | 0 |
| `2048x32x512` | fp32 | 4 | **512B** | ~0.32% | 0 |
| `2048x512x128` | fp32 | 4 | **128B** | ~1.78% | 0 |
| `2048x64x1024` | fp32 | 4 | **1024B** | ~1.91% | 0 |
| `2048x64x128` | fp32 | 4 | **128B** | ~0.09% | 0 |
| `2048x64x512` | fp32 | 4 | **512B** | ~0.40% | 0 |
| `512x1024x128` | fp16 | 16 | **16B** | ~0.05% | 215285 |
| `512x1024x128` | fp32 | 16 | **32B** | ~1.29% | 133614 |
| `512x1024x256` | fp16 | 16 | **32B** | ~2.20% | 214655 |
| `512x128x128` | fp16 | 16 | **16B** | ~0.09% | 228733 |
| `512x128x128` | fp32 | 16 | **32B** | ~1.86% | 313085 |
| `512x128x2048` | fp32 | 16 | **512B** | ~2.51% | 19 |
| `512x128x2048` | fp16 | 16 | **256B** | ~0.45% | 274 |
| `512x128x256` | fp16 | 16 | **32B** | ~3.06% | 355439 |
| `512x2048x128` | fp32 | 16 | **32B** | ~0.44% | 47908 |
| `512x2048x128` | fp16 | 16 | **16B** | ~0.02% | 167916 |
| `512x2048x256` | fp16 | 16 | **32B** | ~1.19% | 97472 |
| `512x256x128` | fp16 | 16 | **16B** | ~0.02% | 6048 |
| `512x256x128` | fp32 | 16 | **32B** | ~1.81% | 291364 |
| `512x256x256` | fp16 | 16 | **32B** | ~2.33% | 234787 |
| `512x32x128` | fp32 | 16 | **32B** | ~1.33% | 231648 |
| `512x32x128` | fp16 | 16 | **16B** | ~0.07% | 230873 |
| `512x32x2048` | fp16 | 16 | **256B** | ~0.30% | 71 |
| `512x32x2048` | fp32 | 16 | **512B** | ~0.58% | 0 |
| `512x32x256` | fp16 | 16 | **32B** | ~1.55% | 219207 |
| `512x512x128` | fp16 | 16 | **16B** | ~0.06% | 207909 |
| `512x512x128` | fp32 | 16 | **32B** | ~2.06% | 189333 |
| `512x512x256` | fp16 | 16 | **32B** | ~2.00% | 142388 |
| `512x64x128` | fp16 | 16 | **16B** | 0.23% | 243240 |
| `512x64x128` | fp32 | 16 | **32B** | ~1.98% | 252354 |
| `512x64x2048` | fp16 | 16 | **256B** | ~0.28% | 0 |
| `512x64x2048` | fp32 | 16 | **512B** | ~0.27% | 29 |
| `512x64x256` | fp16 | 16 | **32B** | ~1.12% | 471920 |
| `8192x256x256` | fp16 | 1 | **512B** | ~2.64% | 0 |

