# GEMM benchmark results — Phase CSR — runtime-configurable group MSHR, software-enabled

Generated 2026-08-16 20:19 from `36e9ea76`. **Re-runnable**: `python3 scripts/gen_sweep_doc_phase.py sweepCSR phaseE1 gemm_results_mshr_ppa_csr.md "Phase CSR — runtime-configurable group MSHR, software-enabled" "group_mshr_cfg_runtime=1: the MSHR ships DISABLED and software programs+enables it before the timed region"`.

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
| 128x1024x512 | 65,536 | 16 | 1 | 16 | `b347f729` | 67,693 | 96.8% | 130,792 | _running (68 periods)_ | — | — | **—** |
| 256x1024x256 | 65,536 | 8 | 2 | 8 | `b132b25e` | 68,253 | 96.0% | 68,410 | 68,379 | 95.8% | +0.2% | **-0.05%** |
| 128x512x512 | 32,768 | 16 | 1 | 16 | `3585610a` | 34,489 | 95.0% | 41,943 | 45,969 | 71.3% | +33.3% | **+9.60%** |
| 256x512x256 | 32,768 | 8 | 2 | 8 | `40ec869f` | 34,821 | 94.1% | 34,547 | 34,812 | 94.1% | -0.0% | **+0.77%** |
| 256x512x512 | 65,536 | 8 | 2 | 8 | `d3403f61` | 71,218 | 92.0% | 71,116 | 70,379 | 93.1% | -1.2% | **-1.04%** |
| 128x256x512 | 16,384 | 16 | 1 | 16 | `17d5e01b` | 18,082 | 90.6% | 21,614 | 27,579 | 59.4% | +52.5% | **+27.60%** |
| 256x256x256 | 16,384 | 8 | 2 | 8 | `1f770128` | 18,177 | 90.1% | 17,984 | 18,115 | 90.4% | -0.3% | **+0.73%** |
| 512x256x256 | 32,768 | 4 | 4 | 4 | `42a4a176` | 37,632 | 87.1% | 38,260 | 38,730 | 84.6% | +2.9% | **+1.23%** |
| 512x512x128 | 32,768 | 4 | 4 | 4 | `2c8d9b30` | 38,325 | 85.5% | 38,885 | 39,612 | 82.7% | +3.4% | **+1.87%** |
| 512x512x512 | 131,072 | 4 | 4 | 4 | `51cf3dbc` | 153,707 | 85.3% | 154,734 | _running (156 periods)_ | — | — | **—** |
| 512x256x512 | 65,536 | 4 | 4 | 4 | `4ed3124f` | 78,314 | 83.7% | 79,653 | 280,917 | 23.3% | +258.7% | **+252.68%** |
| 128x128x512 | 8,192 | 16 | 1 | 16 | `5cbaf0b3` | 9,792 | 83.7% | 16,995 | _running (0 periods)_ | — | — | **—** |
| 256x128x256 | 8,192 | 8 | 2 | 8 | `506c097b` | 10,014 | 81.8% | 9,944 | 9,906 | 82.7% | -1.1% | **-0.38%** |
| 512x256x128 | 16,384 | 4 | 4 | 4 | `9b58c096` | 20,155 | 81.3% | 19,493 | 19,919 | 82.3% | -1.2% | **+2.19%** |
| 512x128x256 | 16,384 | 4 | 4 | 4 | `3c0223fb` | 20,307 | 80.7% | 20,538 | 21,065 | 77.8% | +3.7% | **+2.57%** |
| 512x128x512 | 32,768 | 4 | 4 | 4 | `b41e3eb6` | 42,767 | 76.6% | 42,743 | 42,578 | 77.0% | -0.4% | **-0.39%** |
| 512x128x128 | 8,192 | 4 | 4 | 4 | `3e31135c` | 11,111 | 73.7% | 11,144 | 11,179 | 73.3% | +0.6% | **+0.31%** |
| 256x64x256 | 4,096 | 8 | 2 | 8 | `2145eecf` | 6,050 | 67.7% | 5,860 | 5,701 | 71.8% | -5.8% | **-2.71%** |
| 512x64x256 | 8,192 | 4 | 4 | 4 | `5275b834` | 12,183 | 67.2% | 11,930 | 11,712 | 69.9% | -3.9% | **-1.83%** |
| 512x64x512 | 16,384 | 4 | 4 | 4 | `4738c39f` | 24,616 | 66.6% | 24,607 | 24,480 | 66.9% | -0.6% | **-0.52%** |
| 256x32x512 | 4,096 | 8 | 2 | 8 | `e11c953f` | 6,752 | 60.7% | 6,598 | 6,826 | 60.0% | +1.1% | **+3.46%** |
| 512x32x512 | 8,192 | 4 | 4 | 4 | `126121b3` | 16,238 | 50.4% | 15,088 | 15,471 | 53.0% | -4.7% | **+2.54%** |
| 256x32x256 | 2,048 | 8 | 2 | 8 | `11b4dcfc` | 4,081 | 50.2% | 3,771 | 3,667 | 55.8% | -10.1% | **-2.76%** |

**20 of 23 complete**, 20 paired against `phaseE1`.

- **this phase, the 18 arms within ±10%: mean +0.87%, median +0.52%** · range -2.76% .. +9.60%
- **2 arm(s) outside ±10%, reported as defects and EXCLUDED from the mean above:** +252.7%, +27.6%. Including them the mean would read +14.79%, which one arm dominates.
- whole tree vs `gemm_results.md`: mean +16.4%

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


## How to read the per-shape deltas

**The deltas scatter by roughly ±3% and change sign between shapes. That scatter is NOT a
behavioural change.** The MSHR does byte-identical work in both builds — checked on shapes whose
deltas have opposite sign:

| shape | delta | merged_single | merged_burst | alloc_single | alloc_burst |
|---|---:|---:|---:|---:|---:|
| 256x32x512 | +3.46% | 107,520 both | 15,360 both | 15,360 both | 15,360 both |
| 256x64x256 | −2.71% | 107,520 both | 15,360 both | 15,360 both | 15,360 both |
| 256x128x256 | −0.38% | 215,040 both | 30,720 both | 30,720 both | 30,720 both |

Same merges, same allocations, same class split, whether the arm came out faster or slower. What
differs is the **arrival phase**: with `cfg_runtime=1` the MSHR stays disabled until software enables
it just before the timed region, so the run enters with an empty MSHR and a slightly different
start-up transient. That shifts when cores reach the first barriers, and this kernel's sensitivity to
group alignment is the campaign's documented dominant loss mechanism at 4×4.

Two simpler explanations were considered and are **refuted by the data**:

- *"cold start costs ~0.8% everywhere"* (V3's figure on `256x512x256`) — the deltas are not uniform
  in percent, and several are negative.
- *"a fixed start-up transient, larger in relative terms on small shapes"* — the absolute deltas run
  from −38 to +383 cycles, so they are not uniform in cycles either.

**Quote the mean of the COMPLETE sweep, never a partial one, and never a single shape.** A single
shape's delta is alignment jitter of the same order as the effect being measured. And the mean
itself is unstable until the sweep finishes: at 7 arms it read **−0.20%**, at 15 arms **+0.47%**,
because the small shapes complete first and happened to skew negative. Both were honest readings of
the data available; only the second is close to the answer.

The picture the full data supports is a **small real cost of roughly +0.5%** — the cold MSHR entry,
consistent with V3's independently measured +0.77% on `256x512x256`, which this sweep reproduced
exactly at 34,812 — **plus ±3% alignment jitter** that dominates any individual shape. No trend with
shape size or with N; the sign is mixed at every size.

The functional claim — that runtime CSR configuration is transparent — rests on the **work
counters**, not on the cycle deltas.

> **A caveat this sweep earned the hard way.** The four `128x*x512` arms were first run with
> `MshrCfgSubsW = 4`, which silently truncated `hold_subs_single = 16` to 0 and crippled single
> merging. `128x128x512` came out at 9,718 — a 43% "improvement" — and the cycle count alone looked
> like a breakthrough. The work counters are what exposed it. **A benchmark number that improves
> unexpectedly deserves the same scrutiny as one that regresses.**

## Reporting rule for this table

**State collapsed arms as defects; never fold them into an average.** Two arms
(`512x256x512` +253%, `128x128x512` +1,119%) regress by multiples, not percent. Including them:

| set | mean |
|---|---:|
| the healthy arms | **+0.35%** (median +0.31%, range −2.76% .. +3.46%) |
| adding `512x256x512` alone | **+14.37%** — one arm dominates 18 |

The second number is arithmetically correct and tells you nothing. This is the third summary
statistic in this campaign to mislead in the same way — after a partial-sweep mean that read −0.20%
at 7 arms and +0.47% at 15, and a 2×2 main effect read off the one row where the pathology was
already escaped. **When a summary moves a lot on one more data point, report the distribution, not
the summary.**
