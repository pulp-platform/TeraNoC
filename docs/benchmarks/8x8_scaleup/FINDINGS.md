# 8×8 scale-up sweep — engineering findings

Consolidated from the 248-shape 8×8 GEMM campaign (2026-08-22 → 08-25), at 138 measurements
+ 28 recorded livelocks. Regenerate the live numbers with `scripts/gen_8x8_scaleup_doc.py`;
this file records the *conclusions* and the reasoning behind them.

**Read `rh_livelock_root_cause.md` §0 first** for the livelock mechanism itself. This file is
the layer above: what the whole sweep says about how to shape work for this machine.

---

## 1. The one design rule: B slice = 128 bytes

Every core's per-row slice of the B operand is

```
B_slice_bytes = (P / SPLIT_P) x elem_bytes
SPLIT_P       = 16 / SPLIT_M ,  SPLIT_M = (M / NUM_GROUPS) / KERNEL_SIZE
```

which for `M < 8192` (where `SPLIT_M < 16`) collapses to a **pure M·P product**:

```
B_slice_bytes = M x P x elem_bytes / 8192
```

| | bursts at all | optimum |
|---|---|---|
| fp16 | M·P ≥ 256 K | **M·P = 512 K** |
| fp32 | M·P ≥ 128 K | **M·P = 256 K** |

**Above M = 8192 the shortcut stops applying**: `SPLIT_P` collapses to 1 and the slice is just
`P x elem_bytes`. Do not use the M·P form there.

Measured efficiency against the slice:

| B slice | fp16 | fp32 |
|---|---:|---:|
| 64–127 B | 41.9% (n=19) | 38.7% (n=13) |
| **128 B** | **48.6% (n=22)** | **55.2% (n=13)** |
| 129–511 B | 35.8% (n=19) | 35.6% (n=15) |
| 512 B+ | 35.5% (n=18) | 30.1% (n=19) |

**128 B is a peak, not a floor — overshooting is as bad as undershooting.** Seven of the top
eight arms sit exactly on it:

```
fp16_1024x1024x512  86.6%  128B      fp32_1024x1024x256  80.4%  128B
fp16_2048x1024x256  83.6%  128B      fp32_1024x512x256   74.9%  128B
fp16_1024x512x512   82.1%  128B      fp16_512x1024x1024  72.8%  128B
```

## 2. N is the second axis, and it is monotonic

At the burst optimum (slice 100–160 B), efficiency tracks the contraction depth:

```
N=32   25.9%      N=256   62.2%
N=64   42.1%      N=512   68.8%
N=128  55.1%      N=1024  80.4%
```

So the recipe is: **fix M·P at the optimum, then make N as large as L1 allows.** N is not a
free parameter to shrink for capacity — it is worth more than anything else you would spend
the L1 on.

## 3. Three distinct failure mechanisms — do not conflate them

They are separable by two counters, `RH` (hold episodes) and `mshr_timeout`:

| | signature | population | cause |
|---|---|---|---|
| **A. Cohort livelock** | `RH` ~10^5, `tmo = 0` | **28 arms, 28/28 sub-burst** | B slice under the 64 B floor → B cannot burst → falls back to single-word requests → inherits `hold_subs_single`, a target derived for **A**, which B can never meet (each core owns a distinct `p` range). `rh_livelock_root_cause.md` §0. |
| **B. Low-N collapse** | `RH = 0`, `tmo = 0`, 59–118× over ideal | 6 arms, all **N=32 / P=2048** | not the burst floor (all ≥ 256 B slice). ~1% utilisation, so an 8–16 k-cycle problem needs >1 M cycles and **never finishes inside the 24 h wall clock**. |
| **C. Bypass-regime timeouts** | `RH = 0`, **`tmo` in the thousands** | 42 arms, all **M ≥ 4096** | at M ≥ 4096 `hold_subs_single` derives to 1, so scalar singles **bypass the MSHR entirely**. |

Mechanism C is the sharpest structural break in the whole dataset:

| M | SPLIT_P | n | median `tmo` | median eff |
|---:|---:|---:|---:|---:|
| 512 | 16 | 33 | **0** | 41.4% |
| 1024 | 8 | 38 | **0** | 49.1% |
| 2048 | 4 | 25 | **0** | 48.2% |
| **4096** | **2** | 26 | **664** | **23.5%** |
| **8192** | **1** | 16 | **2,371** | **15.0%** |

Timeouts are *identically zero* below M=4096 and in the thousands at and above it — exactly
where singles start bypassing. **For a shape in mechanism C the RH probe reads zero by
construction**: `add_rh_stall.tcl` shows nothing, and `mshr_timeout` is the signal to trace.

## 4. Metric traps that produced wrong answers here

Each of these cost a real, stated-out-loud wrong conclusion during the campaign.

- **`RH` episode count is not comparable across hold-window settings.** The probe fires once per
  hold *episode*, so doubling the window roughly halves the count for identical stalling.
  Measured: **257 episodes at window 2047 vs 73 at 4095, at an identical 0.04% utilisation** —
  a 3.5× "improvement" that was nothing. Valid *within* one config, misleading across one.
- **The TB `util` counter is lane occupancy, not work done.** It is not conserved across runs of
  identical work and runs 3–11 pp above `ideal/actual`. Rank on `eff = ideal/actual`.
- **A livelocked arm can still finish.** Classifying on "did it print `execution took`" filed two
  sub-burst livelocks (0.23% and 0.59%) as measurements. Classify on the mechanism (`RH`), not on
  whether the wall clock allowed completion.
- **Never estimate a failure rate from a table filtered on the symptom.** A pivot built by
  filtering on "has an RH-STUCK line" deleted every healthy arm, so an empty cell read as "no
  data" rather than "all clean" — and produced a wrong fp32 prediction that five delivered arms
  already falsified.

## 5. Infrastructure lessons

- **A refused CSR write is silent.** `mempool_group_mshr_cfg`'s `HoldCntHwMax` was never wired
  to the package constant, so every value above 2047 was dropped and the reset default stayed in
  force. An entire 26-arm campaign ran at 2047 while believing it ran at 4095. `MSHR_STATUS_RANGE`
  is never `$display`ed — **gate on software's `[MSHR] cfg REJECTED ... MEASUREMENT INVALID`**,
  never on grepping the transcript for `RANGE`.
- **Verify a rebuild reproduces the shipped ELF byte-for-byte before trusting a comparison.**
  Two knobs (`group_mshr_merge_reqs=16`, `EXTRA_DEFINES=-DMATMUL_SPOTCHECK=1`) are not in the
  config and a naive `make` silently omits both.
- **`badist cancel` does not kill the simulator.** It rewrites the ledger; `vsimk` keeps the
  licence seat. The tell is arithmetic, not an error: 0 jobs running but 125 seats held. Reconcile
  seats-held against jobs-running after any cancel.
- **`ssh` inside a `while read` loop eats the loop's stdin**, so a fleet sweep visits one host and
  reports all-clear. Use `ssh -n`, and check the visited count. This produced a false
  "survivors: 0" while 8 cancelled arms held seats.
- **Transcripts are transient.** badist overwrites `hardware/s8_<arm>/transcript` unconditionally,
  and a stale duplicate's gather can land an *old* partial over a complete one at any moment. The
  originals survive in node-local `/scratch/zexifu_cache/badist/run/<batch>/<job>/` — sweep **every**
  node, the ledger's node may be wrong. Now mitigated: the collector archives the probe lines
  (0.26% of the file) on first sight.
- **Trace output is ~35 GB per arm per node and nothing reads it.** `trace_hart_*.dasm` (~21 GB),
  `trace_spatz_*.log` (3,072 files, ~13 GB), `v4m_out` (~2.5 GB). The job collects `transcript`
  only. `+notracer` (runtime) removes the NoC tracer; the rest need `snitch_trace=0` and
  `+define+V4M_ENABLE=0` at the next rebuild. Reclaim from a *live* sim by truncating through
  `/proc/<pid>/fd` — unlinking a file the simulator holds open frees nothing.
