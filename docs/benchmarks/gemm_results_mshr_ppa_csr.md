# GEMM benchmark results — Phase CSR — runtime-configurable group MSHR, software-enabled

Generated 2026-08-16 23:25 from `36e9ea76`. **Re-runnable**: `python3 scripts/gen_sweep_doc_phase.py sweepCSR phaseE1 gemm_results_mshr_ppa_csr.md "Phase CSR — runtime-configurable group MSHR, software-enabled" "group_mshr_cfg_runtime=1: the MSHR ships DISABLED and software programs+enables it before the timed region"`.

**What changed in this phase:** group_mshr_cfg_runtime=1: the MSHR ships DISABLED and software programs+enables it before the timed region

Part of the chained PPA campaign — see [`README.md`](README.md). The **`Δ vs phaseE1`** column is this phase measured alone, against the arm immediately before it; that is the number to quote. `Δ vs old` compares against `gemm_results.md` and bundles everything since 2026-08-03.

## Results

Column guide — the three cycle columns are three DIFFERENT measurements, which is easy to misread:

| column | what it is |
|---|---|
| `baseline cyc` | pre-campaign reference from `gemm_results.md` (2026-08-03) |
| `phaseE1 cyc` | the phase immediately before this one |
| **`THIS PHASE cyc`** | **this sweep's result** |
| `Δ vs baseline` | bundles every change since 2026-08-03 |
| **`Δ vs phaseE1`** | **this phase alone — the number to quote** |

`_running (N periods)_` means the arm has not produced a FINAL yet; it is not a result.

| M×N×P | ideal | A-sh | B-sh | merge | ELF | baseline cyc | baseline % | phaseE1 cyc | **THIS PHASE cyc** | this % | Δ vs baseline | **Δ vs phaseE1** |
|---|---:|---:|---:|---:|:--|---:|---:|---:|---:|---:|---:|---:|
| 128x1024x512 | 65,536 | 16 | 1 | 16 | `1149dab0` | 67,693 | 96.8% | 130,792 | 219,562 | 29.8% | +224.3% | **+67.87%** |
| 256x1024x256 | 65,536 | 8 | 2 | 8 | `046f329e` | 68,253 | 96.0% | 68,410 | 68,379 | 95.8% | +0.2% | **-0.05%** |
| 128x512x512 | 32,768 | 16 | 1 | 16 | `edd55ba5` | 34,489 | 95.0% | 41,943 | 45,969 | 71.3% | +33.3% | **+9.60%** |
| 256x512x256 | 32,768 | 8 | 2 | 8 | `09e2cdf8` | 34,821 | 94.1% | 34,547 | 34,812 | 94.1% | -0.0% | **+0.77%** |
| 256x512x512 | 65,536 | 8 | 2 | 8 | `1f7a3ed8` | 71,218 | 92.0% | 71,116 | 70,379 | 93.1% | -1.2% | **-1.04%** |
| 128x256x512 | 16,384 | 16 | 1 | 16 | `a0dd1086` | 18,082 | 90.6% | 21,614 | 27,579 | 59.4% | +52.5% | **+27.60%** |
| 256x256x256 | 16,384 | 8 | 2 | 8 | `eff18904` | 18,177 | 90.1% | 17,984 | 18,115 | 90.4% | -0.3% | **+0.73%** |
| 512x256x256 | 32,768 | 4 | 4 | 4 | `4bfabeee` | 37,632 | 87.1% | 38,260 | 38,730 | 84.6% | +2.9% | **+1.23%** |
| 512x512x128 | 32,768 | 4 | 4 | 4 | `aec98132` | 38,325 | 85.5% | 38,885 | 39,612 | 82.7% | +3.4% | **+1.87%** |
| 512x512x512 | 131,072 | 4 | 4 | 4 | `97c85346` | 153,707 | 85.3% | 154,734 | 155,036 | 84.5% | +0.9% | **+0.20%** |
| 512x256x512 | 65,536 | 4 | 4 | 4 | `2903acbf` | 78,314 | 83.7% | 79,653 | 280,917 | 23.3% | +258.7% | **+252.68%** |
| 128x128x512 | 8,192 | 16 | 1 | 16 | `f4e7253a` | 9,792 | 83.7% | 16,995 | _running (0 periods)_ | — | — | **—** |
| 256x128x256 | 8,192 | 8 | 2 | 8 | `55b75bcd` | 10,014 | 81.8% | 9,944 | 9,906 | 82.7% | -1.1% | **-0.38%** |
| 512x256x128 | 16,384 | 4 | 4 | 4 | `30c8a832` | 20,155 | 81.3% | 19,493 | 19,919 | 82.3% | -1.2% | **+2.19%** |
| 512x128x256 | 16,384 | 4 | 4 | 4 | `15e8ddef` | 20,307 | 80.7% | 20,538 | 21,065 | 77.8% | +3.7% | **+2.57%** |
| 512x128x512 | 32,768 | 4 | 4 | 4 | `6045d69e` | 42,767 | 76.6% | 42,743 | 42,578 | 77.0% | -0.4% | **-0.39%** |
| 512x128x128 | 8,192 | 4 | 4 | 4 | `bb2834ad` | 11,111 | 73.7% | 11,144 | 11,179 | 73.3% | +0.6% | **+0.31%** |
| 256x64x256 | 4,096 | 8 | 2 | 8 | `52e63dfe` | 6,050 | 67.7% | 5,860 | 5,701 | 71.8% | -5.8% | **-2.71%** |
| 512x64x256 | 8,192 | 4 | 4 | 4 | `fa6007d0` | 12,183 | 67.2% | 11,930 | 11,712 | 69.9% | -3.9% | **-1.83%** |
| 512x64x512 | 16,384 | 4 | 4 | 4 | `fe1ebb97` | 24,616 | 66.6% | 24,607 | 24,480 | 66.9% | -0.6% | **-0.52%** |
| 256x32x512 | 4,096 | 8 | 2 | 8 | `afc79e88` | 6,752 | 60.7% | 6,598 | 6,826 | 60.0% | +1.1% | **+3.46%** |
| 512x32x512 | 8,192 | 4 | 4 | 4 | `9209f128` | 16,238 | 50.4% | 15,088 | 15,471 | 53.0% | -4.7% | **+2.54%** |
| 256x32x256 | 2,048 | 8 | 2 | 8 | `697a398d` | 4,081 | 50.2% | 3,771 | 3,667 | 55.8% | -10.1% | **-2.76%** |

**22 of 23 complete**, 22 paired against `phaseE1`.

- **this phase, the 19 arms within ±10%: mean +0.83%, median +0.31%** · range -2.76% .. +9.60%
- **3 arm(s) outside ±10%, reported as defects and EXCLUDED from the mean above:** +252.7%, +67.9%, +27.6%. Including them the mean would read +16.54%, which one arm dominates.
- whole tree vs `gemm_results.md`: mean +25.1%

`ideal = M·N·P / 1024` (MACs ÷ 1024 FMA lanes = 256 cores × 4 FPU). Efficiency is `ideal / actual`;
the denominator comes from the data size, never from simulation. **Do not rank on the TB's
`[FPU] util`** — it samples lane occupancy, which is not conserved across runs of identical work,
and it once ranked an arm that finished 434 cycles later as higher.

## Compiled configuration

Recorded from the arm's own build log, not from the launcher's intent:

```
GROUP_MSHR_BANK_BURST_BITS = 1
GROUP_MSHR_BANK_HASH = 3
GROUP_MSHR_BANK_PUBLISH = 1
GROUP_MSHR_BANK_SHIFT = 5
GROUP_MSHR_BYPASS_PROBE = 1
GROUP_MSHR_CACHE_RECLAIMABLE = 0
GROUP_MSHR_CACHE_SELF_INVAL = 1
GROUP_MSHR_CACHE_VICTIM_RR = 1
GROUP_MSHR_CFG_RUNTIME = 1
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
GROUP_MSHR_SPILL_REQ_IN = 0
GROUP_MSHR_STALL_ON_RESP = 1
GROUP_MSHR_STATS_PERIOD = 2000
GROUP_MSHR_WAYS_PER_BANK = 4
```

Per-shape knobs (`merge_reqs`, `hold_subs_*`, `bank_shift_*`, `hold_window_burst`) come from
`scripts/gemm_autotune.py` via `config/terapool_spatz4_fpu_gemm<shape>.mk` and are omitted here.

## Known caveat on four shapes

`128x1024x512`, `128x512x512`, `128x256x512`, `128x128x512` have **B shared 1-way** and their
flavour pins `hold_window_burst := 0`. Their `Δ vs old` also carries a `serve_timeout` 255→2047
difference from `gemm_results.md`, so that column is **two-variable** on those rows. The
`Δ vs phaseE1` column is unaffected — both arms use the same timeout.

