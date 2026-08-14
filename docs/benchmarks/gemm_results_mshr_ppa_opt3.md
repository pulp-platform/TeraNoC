# GEMM benchmark results — MSHR PPA re-baseline, opt3 ON

Generated 2026-08-14 17:13. **Re-runnable**: `python3 scripts/gen_sweep_doc_opt3.py` refreshes this file as arms complete.

Companion to `gemm_results.md`, which this re-measures. Same kernel, same shapes, same
`ideal = M·N·P / 1024` definition — so the two tables are directly comparable.

## What changed since `gemm_results.md` (2026-08-03)

| | `gemm_results.md` | this run |
|---|---|---|
| RTL | pre-PPA | `8ca4f060` — A1–A5, B0.3, B1, B2, B3 |
| `group_mshr_drain_from_q` | 0 | **1** (timing closure; the 0 path does not close) |
| `group_mshr_bank_publish` | 0 | **1** — opt3 on (this is the difference from the companion file) |
| `group_mshr_hold_window_burst` | 255 | **2047**, except four shapes pinned to 0 |

**This is the opt3-ON set.** Its companion `gemm_results_mshr_ppa.md` is the same 23
shapes with `bank_publish=0`; the delta between the two files isolates opt3.

**CONFOUND, stated up front:** these arms build from the working tree at `1d5a5756`
(C1 `cc2a751e` plus its compile fix); the opt3-OFF arms were built at `8ca4f060` and
do not contain C1. NOTE: the launcher stamped `f23f8605`, but that commit does not
compile -- the arms used the corrected working tree. C1 is claimed bit-identical and
its equivalence run is in flight; if it verifies the two sweeps differ only in
`bank_publish`, otherwise this comparison is invalid and both sets need rebuilding.

**What opt3 cost when measured in isolation** (hold=255, drain_from_q=0, matched pairs):
`256x512x256` -0.51%, `1024x128x128` -2.21%, `128x1024x512` +0.84%,
`512x512x512` **+21.20%** — the last traced to group 8 alone stalling ~76,000 cycles
while the other fifteen groups stayed within +-1 pp of baseline. Root cause unresolved.

## Configuration

Common to all 23 arms:

```
base config   terapool_spatz4_fpu.mk — 256 cores, 16 groups, 4x4 mesh, Spatz vlen=512
kernel        apps/spatz_apps/sp-fmatmul-opt-burst-merge
ELF           one private per shape, md5-verified distinct (column below)
simulator     VCS, +notracer, no waveforms
passed        hold_window_burst=2047  serve_timeout=2047  hold_prescale_w=0
```

Resolved MSHR defines (per-shape values in the table; the rest are constant):

```
GROUP_MSHR_BANK_BURST_BITS = 1
GROUP_MSHR_BANK_HASH = 3
GROUP_MSHR_BANK_PUBLISH = 1
GROUP_MSHR_BANK_SHIFT = 5
GROUP_MSHR_BYPASS_PROBE = 1
GROUP_MSHR_CACHE_RECLAIMABLE = 0
GROUP_MSHR_CACHE_SELF_INVAL = 1
GROUP_MSHR_CACHE_VICTIM_RR = 1
GROUP_MSHR_DRAIN_BEATS = 2
GROUP_MSHR_DRAIN_FROM_Q = 1
GROUP_MSHR_ENABLE_SINGLE = 1
GROUP_MSHR_ENABLE_STATS = 1
GROUP_MSHR_HOLD_PRESCALE_W = 0
GROUP_MSHR_HOLD_SUBS = 2
GROUP_MSHR_HOLD_WINDOW = 0
GROUP_MSHR_HOLD_WINDOW_SINGLE = 0
GROUP_MSHR_NUM = 64
GROUP_MSHR_RESP_HOLD_PROBE = 1000
GROUP_MSHR_RESP_WAIT_SUBS_SINGLE = 1
GROUP_MSHR_SERVE_TIMEOUT = 2047
GROUP_MSHR_STALL_ON_RESP = 1
GROUP_MSHR_STATS_PERIOD = 2000
GROUP_MSHR_WAYS_PER_BANK = 4
```

Per-shape knobs come from `scripts/gemm_autotune.py` via
`config/terapool_spatz4_fpu_gemm<shape>.mk`. `hold_subs_single/_burst` = A-sh / B-sh
clamped to `[2, merge]`.

**Four shapes pin `hold_window_burst := 0`** — `128x1024x512`, `128x512x512`,
`128x256x512`, `128x128x512`. All have **B shared 1-way**, so `hold_subs_burst` clamps
to 2 and a 1-way-shared line can never supply 2 subscribers: the early-release condition
is unreachable and any non-zero window becomes a guaranteed full-window stall on every
burst allocation. Forcing 2047 on `128x1024x512` measured **+803%** before that arm was
killed. The pin is a disable, not a tuning value.

## Results

| M×N×P | ideal | ss | sb | A-sh | B-sh | merge | win | ELF | old cyc | old % | new cyc | new % | delta |
|---|---:|---:|---:|---:|---:|---:|---:|:---|---:|---:|---:|---:|---:|
| 128x1024x512 | 65,536 | 10 | 5 | 16 | 1 | 16 | 0 | `1149dab0` | 67,693 | 96.8% | _0p_ | — | — |
| 256x1024x256 | 65,536 | 10 | 5 | 8 | 2 | 8 | 2047 | `046f329e` | 68,253 | 96.0% | _1p_ | — | — |
| 128x512x512 | 32,768 | 9 | 5 | 16 | 1 | 16 | 0 | `edd55ba5` | 34,489 | 95.0% | _1p_ | — | — |
| 256x512x256 | 32,768 | 9 | 5 | 8 | 2 | 8 | 2047 | `09e2cdf8` | 34,821 | 94.1% | _1p_ | — | — |
| 256x512x512 | 65,536 | 9 | 6 | 8 | 2 | 8 | 2047 | `1f7a3ed8` | 71,218 | 92.0% | _0p_ | — | — |
| 128x256x512 | 16,384 | 8 | 5 | 16 | 1 | 16 | 0 | `a0dd1086` | 18,082 | 90.6% | _1p_ | — | — |
| 256x256x256 | 16,384 | 8 | 5 | 8 | 2 | 8 | 2047 | `eff18904` | 18,177 | 90.1% | _1p_ | — | — |
| 512x256x256 | 32,768 | 8 | 6 | 4 | 4 | 4 | 2047 | `4bfabeee` | 37,632 | 87.1% | _0p_ | — | — |
| 512x512x128 | 32,768 | 9 | 5 | 4 | 4 | 4 | 2047 | `aec98132` | 38,325 | 85.5% | _2p_ | — | — |
| 512x512x512 | 131,072 | 9 | 7 | 4 | 4 | 4 | 2047 | `97c85346` | 153,707 | 85.3% | _0p_ | — | — |
| 512x256x512 | 65,536 | 8 | 7 | 4 | 4 | 4 | 2047 | `2903acbf` | 78,314 | 83.7% | _0p_ | — | — |
| 128x128x512 | 8,192 | 7 | 5 | 16 | 1 | 16 | 0 | `f4e7253a` | 9,792 | 83.7% | _1p_ | — | — |
| 256x128x256 | 8,192 | 7 | 5 | 8 | 2 | 8 | 2047 | `55b75bcd` | 10,014 | 81.8% | _2p_ | — | — |
| 512x256x128 | 16,384 | 8 | 5 | 4 | 4 | 4 | 2047 | `30c8a832` | 20,155 | 81.3% | _3p_ | — | — |
| 512x128x256 | 16,384 | 7 | 6 | 4 | 4 | 4 | 2047 | `15e8ddef` | 20,307 | 80.7% | _1p_ | — | — |
| 512x128x512 | 32,768 | 7 | 7 | 4 | 4 | 4 | 2047 | `6045d69e` | 42,767 | 76.6% | _0p_ | — | — |
| 512x128x128 | 8,192 | 7 | 5 | 4 | 4 | 4 | 2047 | `bb2834ad` | 11,111 | 73.7% | _3p_ | — | — |
| 256x64x256 | 4,096 | 6 | 5 | 8 | 2 | 8 | 2047 | `52e63dfe` | 6,050 | 67.7% | _3p_ | — | — |
| 512x64x256 | 8,192 | 6 | 6 | 4 | 4 | 4 | 2047 | `fa6007d0` | 12,183 | 67.2% | _2p_ | — | — |
| 512x64x512 | 16,384 | 6 | 7 | 4 | 4 | 4 | 2047 | `fe1ebb97` | 24,616 | 66.6% | _0p_ | — | — |
| 256x32x512 | 4,096 | 5 | 6 | 8 | 2 | 8 | 2047 | `afc79e88` | 6,752 | 60.7% | _1p_ | — | — |
| 512x32x512 | 8,192 | 5 | 7 | 4 | 4 | 4 | 2047 | `9209f128` | 16,238 | 50.4% | _0p_ | — | — |
| 256x32x256 | 2,048 | 5 | 5 | 8 | 2 | 8 | 2047 | `697a398d` | 4,081 | 50.2% | _4p_ | — | — |

**0 of 23 complete.**

`ideal = M·N·P / 1024` (MACs ÷ 1024 FMA lanes = 256 cores × 4 FPU). Efficiency is
`ideal / actual`; the denominator comes from the data size, never from simulation.

## Reading this table

**Do not rank on the TB's `[FPU] util`.** It samples `spatz_vfu.fpu_busy_q` — lane
*occupancy*, which is not conserved across runs of identical work. On the
`1024x128x128` opt2/opt3 pair it ranked the arm that finished **434 cycles later** as
higher. Rank on completion cycles, or equivalently on `ideal/actual`.

**The delta bundles every change at once** — nine RTL commits, `drain_from_q=1` and
hold 255→2047. It says what the current tree does; it does not attribute the gain. A
matching sweep at hold=255 would separate the window out (one was started and stopped).

## Verification

Every arm was cross-checked before its result was accepted:

- `merge_reqs`, `hold_subs_single/burst`, `bank_shift_single/burst` against `gemm_results.md`
- `hold_window_burst` = 0 where B-sh = 1, else 2047
- `drain_from_q` = 1 on every arm
- ELF md5 against the build record, and its `.M/.N/.P` header against the shape name
- each **running process**'s `+PRELOAD` path and simv symlink read from `/proc/<pid>/cmdline`
- `hardware/generated/` confirmed 4×4 — it is shared across build dirs and encodes the mesh
- zero uncommitted changes under `hardware/src`, so every arm is reproducible from git

23/23 verified clean.

