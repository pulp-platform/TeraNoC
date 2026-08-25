# GEMM results — 8×8 mesh, 1024 cores — 248-shape scale-up campaign

Generated 2026-08-25 01:32 by `scripts/gen_8x8_scaleup_doc.py`. **Re-run rather than editing.**

`eff = ideal/actual`, `ideal = M·N·P / lanes` (fp16 8192 MAC/cyc, fp32 4096). Rank on `eff`,
not on the TB `util` column — that counter is lane *occupancy*, is not conserved across runs
of identical work, and has inverted a real ranking before.

> **Not comparable with `gemm_results_8x8_1024core.md`.** That file records a different sweep
> (MSHR / response-channel, single shape 2048×512×512) whose build dirs were reclaimed.

## Campaign state

| | count |
|---|---:|
| measurements | **131** |
| recorded livelock (failures, excluded below) | **28** |
| of manifest | 248 |

Efficiency over the 131 measurements: **median 38.0%**, mean 38.7%, range 7.4–86.6%.

## Cohort target × P

`MSHR_D_HOLD_SUBS_SINGLE` is derived from `M` alone; whether the cohort can form depends
on `P`. Mean efficiency by (target, P) over measurements only:

| target \ P | 128 | 256 | 512 | 1024 | 2048 |
|---:|---:|---:|---:|---:|---:|
| **16** | — | 36.5% (7) | 46.7% (13) | 45.7% (11) | 36.7% (2) |
| **8** | 34.6% (6) | 48.1% (12) | 57.3% (10) | 55.3% (8) | 67.2% (1) |
| **4** | 30.7% (7) | 45.3% (7) | 54.2% (5) | 43.2% (2) | 56.3% (1) |
| **1** | 17.5% (17) | 20.4% (13) | 28.1% (8) | 26.6% (1) | — |

Livelock arms are excluded, so the low-target/low-P cells read better here than the
campaign actually ran — the failures are listed separately below.

## Best 12 by efficiency

| shape | prec | target | B slice | cycles | eff | util | RH |
|---|---|---:|---:|---:|---:|---:|---:|
| `1024x1024x512` | fp16 | 8 | 128B | 75,645 | **86.6%** | 89.79% | 0 |
| `2048x1024x256` | fp16 | 4 | 128B | 78,437 | **83.6%** | 87.42% | 0 |
| `1024x512x512` | fp16 | 8 | 128B | 39,928 | **82.1%** | 85.86% | 0 |
| `1024x1024x256` | fp32 | 8 | 128B | 81,530 | **80.4%** | 84.42% | 0 |
| `1024x512x256` | fp32 | 8 | 128B | 43,777 | **74.9%** | 79.32% | 0 |
| `2048x256x512` | fp16 | 4 | 256B | 44,586 | **73.5%** | 78.15% | 0 |
| `512x1024x1024` | fp16 | 16 | 128B | 90,013 | **72.8%** | 81.26% | 0 |
| `1024x256x512` | fp16 | 8 | 128B | 22,504 | **72.8%** | 77.60% | 0 |
| `1024x512x1024` | fp16 | 8 | 256B | 93,250 | **70.3%** | 81.57% | 0 |
| `512x512x1024` | fp16 | 16 | 128B | 47,642 | **68.8%** | 77.30% | 0 |
| `1024x128x2048` | fp16 | 8 | 512B | 48,735 | **67.2%** | ~74.92% | 0 |
| `512x1024x512` | fp32 | 16 | 128B | 97,727 | **67.1%** | 74.13% | 0 |

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

37 measurements sit below 25% efficiency with **no** RH-livelock. Their `N` distribution:

| N | arms |
|---:|---:|
| 32 | 17 |
| 64 | 9 |
| 128 | 6 |
| 256 | 5 |

Small contraction depth, not the cohort mechanism. Distinct from the livelock and
not addressed by any MSHR hold-window change.

## Recorded LIVELOCK (28) — failures, not results

Root cause: the per-core **B slice** `(P/SPLIT_P)*elem_bytes` is below the **64-byte** burst floor, so B cannot burst, falls back to single-word requests, and inherits `hold_subs_single` — a target derived for **A**, which B can never meet because each core owns a distinct `p` range. See `docs/benchmarks/8x8_scaleup/rh_livelock_root_cause.md` §0. **Every one of these has a sub-burst B slice.** Averaging them into the campaign drags the mean by ~7 pp.

| shape | prec | target | B slice | util | RH |
|---|---|---:|---:|---:|---:|
| `1024x1024x128` | fp16 | 8 | **32B** | ~2.25% | 176966 |
| `1024x128x128` | fp16 | 8 | **32B** | ~3.98% | 373567 |
| `1024x2048x128` | fp16 | 8 | **32B** | ~1.50% | 181995 |
| `1024x256x128` | fp16 | 8 | **32B** | ~2.93% | 167165 |
| `1024x32x128` | fp16 | 8 | **32B** | 0.59% | 123743 |
| `1024x512x128` | fp16 | 8 | **32B** | ~2.34% | 134546 |
| `1024x64x128` | fp16 | 8 | **32B** | ~4.58% | 201236 |
| `512x1024x128` | fp16 | 16 | **16B** | ~0.05% | 215285 |
| `512x1024x128` | fp32 | 16 | **32B** | ~1.29% | 133614 |
| `512x1024x256` | fp16 | 16 | **32B** | ~2.20% | 214655 |
| `512x128x128` | fp16 | 16 | **16B** | ~0.09% | 228733 |
| `512x128x128` | fp32 | 16 | **32B** | ~1.86% | 313085 |
| `512x128x256` | fp16 | 16 | **32B** | ~3.06% | 355439 |
| `512x2048x128` | fp32 | 16 | **32B** | ~0.44% | 47908 |
| `512x2048x128` | fp16 | 16 | **16B** | ~0.02% | 167916 |
| `512x2048x256` | fp16 | 16 | **32B** | ~1.19% | 97472 |
| `512x256x128` | fp16 | 16 | **16B** | ~0.01% | 1918 |
| `512x256x128` | fp32 | 16 | **32B** | ~1.81% | 291364 |
| `512x256x256` | fp16 | 16 | **32B** | ~2.33% | 234787 |
| `512x32x128` | fp32 | 16 | **32B** | ~0.73% | 4416 |
| `512x32x128` | fp16 | 16 | **16B** | ~0.09% | 187020 |
| `512x32x256` | fp16 | 16 | **32B** | ~1.55% | 219207 |
| `512x512x128` | fp16 | 16 | **16B** | ~0.06% | 132663 |
| `512x512x128` | fp32 | 16 | **32B** | ~2.06% | 189333 |
| `512x512x256` | fp16 | 16 | **32B** | ~2.00% | 142388 |
| `512x64x128` | fp16 | 16 | **16B** | 0.23% | 243240 |
| `512x64x128` | fp32 | 16 | **32B** | ~1.98% | 252354 |
| `512x64x256` | fp16 | 16 | **32B** | ~1.25% | 102201 |

