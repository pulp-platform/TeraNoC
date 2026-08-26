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

| remap | hold | cycles | eff | TB util | tmo |
|---:|---:|---:|---:|---:|---:|
| 3 | 8191 | 65,060 | 50.4% | 57.88% | 0 |

fp16 is worth **1.79x** at this cell (65,060 / 36,379).

## What the grid says

**1. The hold window is doing the work.** 2047 -> 8191 is **1.85x** at `128x128` and **2.34x** at
`256x128`, and it drives the timeout count from 735 and 2,209 to **zero** in both. Every 8191 arm
measured so far has `tmo = 0`.

**2. `noc_router_remapping=3` is NOT uniformly better — it reverses sign between the two shapes.**

| shape | remap=2 @8191 | remap=3 @8191 | r3 vs r2 |
|---|---:|---:|---:|
| `4096x256x128` | 41,381 | 36,379 | **+14%** |
| `4096x128x128` | 23,110 | 24,555 | **-6%** |

Both timeout-free, so this is not a livelock artefact. One cell each way is thin, but it is enough
to retire the earlier reading that remap=3 is simply better. Whatever it buys depends on `P`, or on
the `N:P` ratio. **Do not promote remapping=3 to a default on this evidence.**

## Gaps

- **No `r2w2k` cell exists at all**, in either shape — the 2x2 is three-cornered, so the window
  effect is only measured at remap=3. Two arms would close it.
- `8192x128x512` at both remaps and `r2w8k` fp32 are running.
