# Router remapping x hold window — the 8x8 A/B grid

2026-08-26. Companion to `w4095_vs_2047.md`. Answers two questions on the same arms:
does the **hold window** (2047 vs 8191) pay, and does **`noc_router_remapping`** 2 vs 3 pay?

## Matching — verified, not assumed

- The two **window** cells at remap=3 share ONE image (`build_vcs_r3`), so 2047 vs 8191 differs
  only in the CSR-written hold window. Clean by construction.
- The **remap** comparison crosses images by necessity (remap is elaboration-time).
  `build_vcs_r2` vs `build_vcs_r3` differ in **exactly one define**:
  `+define+NOC_ROUTER_REMAPPING=2` vs `=3`. Full define-set diff run before quoting any ratio —
  see [[feedback_pin_knobs_across_default_changes]] for why this is mandatory.
- All arms VCS, `group_mshr_merge_reqs=16`, same ELFs.
- `eff` = `ideal/actual`, `ideal = M*N*P / lanes` (8192 fp16, 4096 fp32). Rank on it, never on the
  TB `util` counter, which is lane occupancy.
- `tmo` is the summed `mshr_timeout=+N` over the benchmark window. **Do not** compare the RH
  episode count across window settings — it is not commensurable (see `w4095_vs_2047.md`).

## `4096x256x128` fp16 — ideal 16,384 cyc

| remap | hold | cycles | eff | tmo |
|---:|---:|---:|---:|---:|
| 3 | 2047 | 84,952 | 19.3% | 2,209 |
| **3** | **8191** | **36,379** | **45.0%** | 0 |
| 2 | 8191 | 41,381 | 39.6% | 0 |
| 2 | 2047 | — | — | — |

## `4096x128x128` fp16 — ideal 8,192 cyc

| remap | hold | cycles | eff | tmo |
|---:|---:|---:|---:|---:|
| 3 | 2047 | 45,443 | 18.0% | 735 |
| 3 | 8191 | 24,555 | 33.4% | 0 |
| **2** | **8191** | **23,110** | **35.4%** | 0 |
| 2 | 2047 | — | — | — |

## `4096x256x128` fp32 — ideal 32,768 cyc

| remap | hold | cycles | eff | tmo |
|---:|---:|---:|---:|---:|
| 3 | 2047 | 88,972 | 36.8% | 3,471 |
| **3** | **8191** | **65,060** | **50.4%** | 0 |
| 2 | 8191 | 88,425 | 37.1% | 0 |

⚠️ **`mshr_timeout=+N` in a `[FPU] bench` line is a PER-PERIOD DELTA, not a running total.** The
completion monitor reported this arm as `mshr_timeout=+0` — that was the last period's delta, and
the summed total is **3,471**. Reading the last line as the total said "fp32 has no timeout problem
at 2047", which is the opposite of the truth. Always sum:
`grep -ao 'mshr_timeout=+[0-9]*' | awk -F+ '{s+=$2} END{print s}'`.

## `8192x128x512` fp16 — the third shape, and what predicts the window's payoff

| remap | hold | cycles | eff | tmo |
|---:|---:|---:|---:|---:|
| 3 | 2047 | 223,413 | 29.3% | 1,160 |
| **3** | **8191** | **184,886** | **35.4%** | 0 |

**1.21x** — far less than the 1.85x and 2.34x on the `4096x*x128` shapes. Every 8191 arm still
lands at `tmo = 0`, so the window works; there was simply less for it to fix.

**Within fp16 the payoff tracks the timeout RATE, not the raw count:**

| shape | tmo @2047 | tmo per kcyc | window payoff |
|---|---:|---:|---:|
| `8192x128x512` | 1,160 | **5.2** | 1.21x |
| `4096x128x128` | 735 | **16.2** | 1.85x |
| `4096x256x128` | 2,209 | **26.0** | 2.34x |

Monotonic in the rate, and NOT in the count — `8192x128x512` has more absolute timeouts than
`4096x128x128` and gains less, because it runs 5x longer. **Quote the rate.**

⚠️ fp32 `4096x256x128` breaks the ordering (39.0 tmo/kcyc, only 1.37x). Consistent with fp32 having
half the lanes, so each stalled cohort costs relatively less throughput — but it means the rate
predicts the payoff **within a precision**, not across one.

**Practical reading:** the hold window is worth having everywhere (it never costs anything — every
8191 arm is timeout-free), but its value is proportional to how timeout-bound the shape already is.
A shape at `tmo = 0` has nothing to gain, which is exactly why the decode arms are not expected to
move.

## The window is what lets fp16 realise its 2x at 8x8

Both precisions accumulate timeouts at 2047 and both go to zero at 8191, but the payoff is very
different — **2.34x for fp16, 1.37x for fp32**. The reason shows up in the cross-precision ratio at
`4096x256x128`:

| hold | fp16 cyc | fp32 cyc | fp16 speedup | fp16 eff | fp32 eff |
|---:|---:|---:|---:|---:|---:|
| 2047 | 84,952 | 88,972 | **1.05x** | 19.3% | 36.8% |
| 8191 | 36,379 | 65,060 | **1.79x** | 45.0% | 50.4% |

At 2047 fp16 is **barely faster than fp32 at all** despite having twice the lanes — its advantage
is entirely eaten by the short hold window, and it ends up the *worse* of the two on efficiency
(19.3% against 36.8%). At 8191 it recovers to 1.79x, near the 2x its lanes should give.

**This matters for the Qwen plan, which is an fp16 plan.** The prefill tile efficiencies in
`qwen38_kernel_mapping.md` §5.2 are fp16 numbers; if any of them were measured on an image with a
short hold window, they are not measuring the tile.

## What the grid says

**1. The hold window is doing the work.** 2047 -> 8191 is **1.85x** at `128x128` and **2.34x** at
`256x128`, and it drives the timeout count from 735 and 2,209 to **zero** in both. Every 8191 arm
measured so far has `tmo = 0`.

**2. `noc_router_remapping=3` is NOT uniformly better — it reverses sign between the two shapes.**

| shape | prec | remap=2 @8191 | remap=3 @8191 | r3 vs r2 |
|---|---|---:|---:|---:|
| `8192x128x512` | fp16 | 261,902 (25.0%) | 184,886 (35.4%) | **+42%** |
| `4096x256x128` | fp32 | 88,425 (37.1%) | 65,060 (50.4%) | **+36%** |
| `4096x256x128` | fp16 | 41,381 (39.6%) | 36,379 (45.0%) | **+14%** |
| `4096x128x128` | fp16 | 23,110 (35.4%) | 24,555 (33.4%) | **-6%** |

All timeout-free, so none of this is a livelock artefact. **remap=3 is a large win at
`N=256, P=128` — +36% in fp32 and +14% in fp16 — and a small loss at `N=128`.** The sign flip is
real but it is not symmetric: the gain where it helps is far bigger than the loss where it hurts,
and it helps more in fp32 than in fp16.

✅ **GRID COMPLETE (12/12 cells, 2026-08-26). Three shapes gain, one loses, and the gains are
large: +42%, +36%, +14% against a single -6%.** The earlier reading — "does not generalise, do not
promote to a default" — was written when only two shapes existed and one of them was the loss. With
four cells the evidence supports **remap=3 as the default**, which is what
`config/terapool_spatz4_fpu.mk` now ships.

The one loss (`4096x128x128`, -6%) is the smallest shape in the grid and the only one where BOTH
`N` and `P` are 128. Worth remembering as a known exception rather than treated as a reason to
withhold the default.

## Gaps

- **No `r2w2k` cell exists at all**, in either shape — the 2x2 is three-cornered, so the window
  effect is only measured at remap=3. Two arms would close it.
- `8192x128x512` at both remaps and `r2w8k` fp32 are running.
