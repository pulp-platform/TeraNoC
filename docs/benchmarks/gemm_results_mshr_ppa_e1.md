# GEMM benchmark results — Phase E1 — commit-FIFO depth + ROB counter (config only)

Generated 2026-08-16 01:24 from `b5e543c5`. **Re-runnable**: `python3 scripts/gen_sweep_doc_phase.py phaseE1 sweepC2 gemm_results_mshr_ppa_e1.md "Phase E1 — commit-FIFO depth + ROB counter (config only)" "spatz_vlsu_commit_qmin=1 (commit FIFO 64->4, ~571k DFF cluster) and spatz_rob_cnt_idvalid=1 (drops the 64-bit free-id bitmap, ~65k DFF + ~380k GE cluster). No RTL change."`.

**What changed in this phase:** spatz_vlsu_commit_qmin=1 (commit FIFO 64->4, ~571k DFF cluster) and spatz_rob_cnt_idvalid=1 (drops the 64-bit free-id bitmap, ~65k DFF + ~380k GE cluster). No RTL change.

Part of the chained PPA campaign — see [`README.md`](README.md). The **`Δ vs sweepC2`** column is this phase measured alone, against the arm immediately before it; that is the number to quote. `Δ vs old` compares against `gemm_results.md` and bundles everything since 2026-08-03.

## Results

| M×N×P | ideal | A-sh | B-sh | merge | ELF | old cyc | old % | sweepC2 cyc | new cyc | new % | Δ vs old | **Δ vs sweepC2** |
|---|---:|---:|---:|---:|:--|---:|---:|---:|---:|---:|---:|---:|
| 128x1024x512 | 65,536 | 16 | 1 | 16 | `1149dab0` | 67,693 | 96.8% | 130,792 | 130,792 | 50.1% | +93.2% | **+0.00%** |
| 256x1024x256 | 65,536 | 8 | 2 | 8 | `046f329e` | 68,253 | 96.0% | 68,410 | 68,410 | 95.8% | +0.2% | **+0.00%** |
| 128x512x512 | 32,768 | 16 | 1 | 16 | `edd55ba5` | 34,489 | 95.0% | 41,943 | 41,943 | 78.1% | +21.6% | **+0.00%** |
| 256x512x256 | 32,768 | 8 | 2 | 8 | `09e2cdf8` | 34,821 | 94.1% | 34,547 | 34,547 | 94.9% | -0.8% | **+0.00%** |
| 256x512x512 | 65,536 | 8 | 2 | 8 | `1f7a3ed8` | 71,218 | 92.0% | 71,116 | 71,116 | 92.2% | -0.1% | **+0.00%** |
| 128x256x512 | 16,384 | 16 | 1 | 16 | `a0dd1086` | 18,082 | 90.6% | 21,614 | 21,614 | 75.8% | +19.5% | **+0.00%** |
| 256x256x256 | 16,384 | 8 | 2 | 8 | `eff18904` | 18,177 | 90.1% | 17,984 | 17,984 | 91.1% | -1.1% | **+0.00%** |
| 512x256x256 | 32,768 | 4 | 4 | 4 | `4bfabeee` | 37,632 | 87.1% | 38,260 | 38,260 | 85.6% | +1.7% | **+0.00%** |
| 512x512x128 | 32,768 | 4 | 4 | 4 | `aec98132` | 38,325 | 85.5% | 38,885 | 38,885 | 84.3% | +1.5% | **+0.00%** |
| 512x512x512 | 131,072 | 4 | 4 | 4 | `97c85346` | 153,707 | 85.3% | 154,734 | 154,734 | 84.7% | +0.7% | **+0.00%** |
| 512x256x512 | 65,536 | 4 | 4 | 4 | `2903acbf` | 78,314 | 83.7% | 79,653 | 79,653 | 82.3% | +1.7% | **+0.00%** |
| 128x128x512 | 8,192 | 16 | 1 | 16 | `f4e7253a` | 9,792 | 83.7% | 16,995 | 16,995 | 48.2% | +73.6% | **+0.00%** |
| 256x128x256 | 8,192 | 8 | 2 | 8 | `55b75bcd` | 10,014 | 81.8% | 9,944 | 9,944 | 82.4% | -0.7% | **+0.00%** |
| 512x256x128 | 16,384 | 4 | 4 | 4 | `30c8a832` | 20,155 | 81.3% | 19,493 | 19,493 | 84.1% | -3.3% | **+0.00%** |
| 512x128x256 | 16,384 | 4 | 4 | 4 | `15e8ddef` | 20,307 | 80.7% | 20,538 | 20,538 | 79.8% | +1.1% | **+0.00%** |
| 512x128x512 | 32,768 | 4 | 4 | 4 | `6045d69e` | 42,767 | 76.6% | 42,743 | 42,743 | 76.7% | -0.1% | **+0.00%** |
| 512x128x128 | 8,192 | 4 | 4 | 4 | `bb2834ad` | 11,111 | 73.7% | 11,144 | 11,144 | 73.5% | +0.3% | **+0.00%** |
| 256x64x256 | 4,096 | 8 | 2 | 8 | `52e63dfe` | 6,050 | 67.7% | 5,860 | 5,860 | 69.9% | -3.1% | **+0.00%** |
| 512x64x256 | 8,192 | 4 | 4 | 4 | `fa6007d0` | 12,183 | 67.2% | 11,930 | 11,930 | 68.7% | -2.1% | **+0.00%** |
| 512x64x512 | 16,384 | 4 | 4 | 4 | `fe1ebb97` | 24,616 | 66.6% | 24,607 | 24,607 | 66.6% | -0.0% | **+0.00%** |
| 256x32x512 | 4,096 | 8 | 2 | 8 | `afc79e88` | 6,752 | 60.7% | 6,598 | 6,598 | 62.1% | -2.3% | **+0.00%** |
| 512x32x512 | 8,192 | 4 | 4 | 4 | `9209f128` | 16,238 | 50.4% | 15,088 | 15,088 | 54.3% | -7.1% | **+0.00%** |
| 256x32x256 | 2,048 | 8 | 2 | 8 | `697a398d` | 4,081 | 50.2% | 3,771 | 3,771 | 54.3% | -7.6% | **+0.00%** |

**23 of 23 complete**, 23 paired against `sweepC2`.

- **this phase alone: mean +0.00%** · best +0.00% · worst +0.00%
- whole tree vs `gemm_results.md`: mean +8.1%

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
SPATZ_ROB_CNT_IDVALID = 1
SPATZ_TRACE = 0
SPATZ_VLSU_BLOCK_ALLOC = 1
SPATZ_VLSU_COMMIT_QMIN = 1
SPATZ_VLSU_DUAL_LOAD = 2
SPATZ_VLSU_ROB_DEPTH = 64
```

Per-shape knobs (`merge_reqs`, `hold_subs_*`, `bank_shift_*`, `hold_window_burst`) come from
`scripts/gemm_autotune.py` via `config/terapool_spatz4_fpu_gemm<shape>.mk` and are omitted here.

## Known caveat on four shapes

`128x1024x512`, `128x512x512`, `128x256x512`, `128x128x512` have **B shared 1-way** and their
flavour pins `hold_window_burst := 0`. Their `Δ vs old` also carries a `serve_timeout` 255→2047
difference from `gemm_results.md`, so that column is **two-variable** on those rows. The
`Δ vs sweepC2` column is unaffected — both arms use the same timeout.

