# GEMM results — 8×8 mesh, 1024 cores — 248-shape scale-up campaign

Generated 2026-08-24 17:48 by `scripts/gen_8x8_scaleup_doc.py`. **Re-run rather than editing.**

`eff = ideal/actual`, `ideal = M·N·P / lanes` (fp16 8192 MAC/cyc, fp32 4096). Rank on `eff`,
not on the TB `util` column — that counter is lane *occupancy*, is not conserved across runs
of identical work, and has inverted a real ranking before.

> **Not comparable with `gemm_results_8x8_1024core.md`.** That file records a different sweep
> (MSHR / response-channel, single shape 2048×512×512) whose build dirs were reclaimed.

## Campaign state

| | count |
|---|---:|
| measurements | **123** |
| recorded livelock (failures, excluded below) | **26** |
| of manifest | 248 |

Efficiency over the 123 measurements: **median 35.6%**, mean 36.4%, range 0.1–82.1%.

## Cohort target × P

`MSHR_D_HOLD_SUBS_SINGLE` is derived from `M` alone; whether the cohort can form depends
on `P`. Mean efficiency by (target, P) over measurements only:

| target \ P | 128 | 256 | 512 | 1024 | 2048 |
|---:|---:|---:|---:|---:|---:|
| **16** | 0.1% (1) | 34.5% (6) | 45.0% (12) | 46.5% (10) | 35.8% (1) |
| **8** | 29.6% (7) | 45.2% (11) | 54.0% (9) | 53.1% (7) | 67.2% (1) |
| **4** | 30.7% (7) | 38.9% (6) | 54.2% (5) | 43.2% (2) | 56.3% (1) |
| **1** | 14.8% (15) | 20.4% (13) | 28.1% (8) | 26.6% (1) | — |

Livelock arms are excluded, so the low-target/low-P cells read better here than the
campaign actually ran — the failures are listed separately below.

## Best 12 by efficiency

| shape | prec | target | cycles | eff | util | RH |
|---|---|---:|---:|---:|---:|---:|
| `1024x512x512` | fp16 | 8 | 39,928 | **82.1%** | 85.86% | 0 |
| `1024x512x256` | fp32 | 8 | 43,777 | **74.9%** | 79.32% | 0 |
| `2048x256x512` | fp16 | 4 | 44,586 | **73.5%** | 78.15% | 0 |
| `512x1024x1024` | fp16 | 16 | 90,013 | **72.8%** | 81.26% | 0 |
| `1024x256x512` | fp16 | 8 | 22,504 | **72.8%** | 77.60% | 0 |
| `512x512x1024` | fp16 | 16 | 47,642 | **68.8%** | 77.30% | 0 |
| `1024x128x2048` | fp16 | 8 | 48,735 | **67.2%** | ~74.92% | 0 |
| `1024x256x256` | fp32 | 8 | 24,532 | **66.8%** | 71.50% | 0 |
| `1024x256x1024` | fp16 | 8 | 50,363 | **65.1%** | 76.33% | 0 |
| `512x256x1024` | fp16 | 16 | 25,238 | **64.9%** | 74.44% | 4 |
| `512x512x512` | fp32 | 16 | 51,688 | **63.4%** | 70.27% | 0 |
| `2048x128x512` | fp16 | 4 | 26,245 | **62.4%** | 67.21% | 0 |

## Worst 12 by efficiency

| shape | prec | target | cycles | eff | util | RH |
|---|---|---:|---:|---:|---:|---:|
| `4096x32x256` | fp32 | 1 | 58,440 | **14.0%** | 15.90% | 0 |
| `8192x32x512` | fp16 | 1 | 118,658 | **13.8%** | ~16.02% | 0 |
| `8192x32x256` | fp16 | 1 | 70,746 | **11.6%** | ~13.97% | 0 |
| `8192x32x128` | fp32 | 1 | 75,423 | **10.9%** | 13.79% | 0 |
| `4096x64x256` | fp16 | 1 | 76,555 | **10.7%** | ~12.26% | 0 |
| `8192x256x128` | fp16 | 1 | 314,480 | **10.4%** | ~12.07% | 0 |
| `8192x128x128` | fp16 | 1 | 166,574 | **9.8%** | ~11.40% | 0 |
| `8192x32x128` | fp16 | 1 | 43,048 | **9.5%** | ~12.68% | 0 |
| `2048x32x256` | fp16 | 4 | 22,626 | **9.1%** | 10.92% | 270 |
| `2048x32x128` | fp16 | 4 | 13,840 | **7.4%** | 9.27% | 250 |
| `1024x32x128` | fp16 | 8 | 295,185 | **0.2%** | 0.59% | 123743 |
| `512x64x128` | fp16 | 16 | 360,882 | **0.1%** | 0.23% | 243240 |

## Low efficiency with `RH = 0` — a second, separate mechanism

36 measurements sit below 25% efficiency with **no** RH-livelock. Their `N` distribution:

| N | arms |
|---:|---:|
| 32 | 17 |
| 64 | 9 |
| 128 | 6 |
| 256 | 4 |

Small contraction depth, not the cohort mechanism. Distinct from the livelock and
not addressed by any MSHR hold-window change.

## Recorded LIVELOCK (26) — failures, not results

These measure the `mshr_cfg.h` cohort-target bug (`docs/benchmarks/8x8_scaleup/rh_livelock_root_cause.md`), not the architecture.
Averaging them into the campaign drags the mean by ~7 pp.

| shape | prec | target | util | RH |
|---|---|---:|---:|---:|
| `1024x1024x128` | fp16 | 8 | ~2.25% | 176966 |
| `1024x128x128` | fp16 | 8 | ~3.98% | 373567 |
| `1024x2048x128` | fp16 | 8 | ~1.50% | 181995 |
| `1024x256x128` | fp16 | 8 | ~2.93% | 167165 |
| `1024x512x128` | fp16 | 8 | ~2.34% | 134546 |
| `1024x64x128` | fp16 | 8 | ~4.58% | 201236 |
| `512x1024x128` | fp16 | 16 | ~0.05% | 215285 |
| `512x1024x128` | fp32 | 16 | ~1.29% | 133614 |
| `512x1024x256` | fp16 | 16 | ~2.20% | 214655 |
| `512x128x128` | fp16 | 16 | ~0.09% | 228733 |
| `512x128x128` | fp32 | 16 | ~1.86% | 313085 |
| `512x128x256` | fp16 | 16 | ~3.06% | 355439 |
| `512x2048x128` | fp32 | 16 | ~0.44% | 47908 |
| `512x2048x128` | fp16 | 16 | ~0.02% | 167916 |
| `512x2048x256` | fp16 | 16 | ~1.19% | 97472 |
| `512x256x128` | fp16 | 16 | ~0.08% | 232618 |
| `512x256x128` | fp32 | 16 | ~1.81% | 291364 |
| `512x256x256` | fp16 | 16 | ~2.33% | 234787 |
| `512x32x128` | fp32 | 16 | ~0.73% | 4416 |
| `512x32x128` | fp16 | 16 | ~0.09% | 187020 |
| `512x32x256` | fp16 | 16 | ~1.55% | 219207 |
| `512x512x128` | fp16 | 16 | ~0.06% | 207909 |
| `512x512x128` | fp32 | 16 | ~2.06% | 189333 |
| `512x512x256` | fp16 | 16 | ~2.00% | 142388 |
| `512x64x128` | fp32 | 16 | ~1.98% | 252354 |
| `512x64x256` | fp16 | 16 | ~1.12% | 471920 |

