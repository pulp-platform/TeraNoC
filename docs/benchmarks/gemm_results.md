# GEMM benchmark results -- TeraNoC-Spatz vs. baseline

Generated 2026-08-03 13:02:16

The single source of truth for `sp-fmatmul` GEMM performance: **29 shapes**
(the 22-shape tuning sweep plus the 7 N-scaling shapes), the tuning rules that
derive each shape's configuration, and every finding from the campaign.

## What is being compared

| | ours | baseline |
|---|---|---|
| tree | `TeraNoC_Spatz/TeraNoC` | `TeraNoC_ori/TeraNoC_spatz` |
| kernel | `sp-fmatmul-opt-burst-merge` | `sp-fmatmul-opt` |
| Spatz VLSU burst load | **yes** (16-word bursts) | no |
| group MSHR request merge | **yes** | no |
| group MSHR multicast response | **yes** | no |
| config | `terapool_spatz4_fpu`, 256 cores, 16 groups | same |

Cycles are the benchmark region only (`took N cycles`), recorded before the
device-side verify. `util = floor/cycles`, `floor = 2·M·N·P/2048`
(2048 = 256 cores x 4 FPU x 2 flop). Baseline = Verilator; QuestaSim agrees within
+-5.7% wherever both landed. Baseline includes the `tcdm_id_remapper` fix (below).

## Parameter legend

| column | meaning |
|---|---|
| `ss` / `sb` | `group_mshr_bank_shift_single` / `_burst` |
| `bb` | burst_bits = `log2(VL/MaxBurstWords)`; always 1 for e32/m2 |
| `A-sh` / `B-sh` | cores sharing an A line (`split_p_count`) / B line (`split_m_count`) |
| `merge` | `group_mshr_merge_reqs` = **max(A-sh, B-sh)** |
| `it` | p-iterations = `(P/split_p_count)/VL` |
| `lim` | which matrix is the heavily-shared one |

`hold_subs_single/_burst` = A-sh / B-sh **clamped to [2, merge]**; a raw degree of 1
is illegal (see Caveats). Derive everything with `scripts/gemm_autotune.py`.

## All 29 shapes, sorted by our utilisation

| M×N×P | L1 MB | ss | sb | bb | A-sh | B-sh | merge | it | floor | ours | ours % | baseline | base % | speedup | lim |
|-------|------:|---:|---:|---:|-----:|-----:|------:|---:|------:|-----:|-------:|---------:|-------:|--------:|:---:|
| 128x1024x512 | 2.75 | 10 | 5 | 1 | 16 | 1 | 16 | 1 | 65,536 | 67,693 | **96.8%** | 86,902 | 75.4% | **1.28×** | A |
| 256x1024x256 | 2.25 | 10 | 5 | 1 | 8 | 2 | 8 | 1 | 65,536 | 68,253 | **96.0%** | 88,671 | 73.9% | **1.30×** | A |
| 128x512x512 | 1.50 | 9 | 5 | 1 | 16 | 1 | 16 | 1 | 32,768 | 34,489 | **95.0%** | 44,292 | 74.0% | **1.28×** | A |
| 256x512x256 | 1.25 | 9 | 5 | 1 | 8 | 2 | 8 | 1 | 32,768 | 34,821 | **94.1%** | 44,618 | 73.4% | **1.28×** | A |
| 256x512x512 | 2.00 | 9 | 6 | 1 | 8 | 2 | 8 | 2 | 65,536 | 71,218 | **92.0%** | 94,078 | 69.7% | **1.32×** | A |
| 128x256x512 | 0.88 | 8 | 5 | 1 | 16 | 1 | 16 | 1 | 16,384 | 18,082 | **90.6%** | 20,446 | 80.1% | **1.13×** | A |
| 256x256x256 | 0.75 | 8 | 5 | 1 | 8 | 2 | 8 | 1 | 16,384 | 18,177 | **90.1%** | 20,785 | 78.8% | **1.14×** | A |
| 512x256x256 | 1.25 | 8 | 6 | 1 | 4 | 4 | 4 | 2 | 32,768 | 37,632 | **87.1%** | 48,505 | 67.6% | **1.29×** | - |
| 512x512x128 | 1.50 | 9 | 5 | 1 | 4 | 4 | 4 | 1 | 32,768 | 38,325 | **85.5%** | 45,309 | 72.3% | **1.18×** | - |
| 512x512x512 | 3.00 | 9 | 7 | 1 | 4 | 4 | 4 | 4 | 131,072 | 153,707 | **85.3%** | 208,630 | 62.8% | **1.36×** | - |
| 512x256x512 | 2.00 | 8 | 7 | 1 | 4 | 4 | 4 | 4 | 65,536 | 78,314 | **83.7%** | 105,766 | 62.0% | **1.35×** | - |
| 128x128x512 | 0.56 | 7 | 5 | 1 | 16 | 1 | 16 | 1 | 8,192 | 9,792 | **83.7%** | 10,850 | 75.5% | **1.11×** | A |
| 256x128x256 | 0.50 | 7 | 5 | 1 | 8 | 2 | 8 | 1 | 8,192 | 10,014 | **81.8%** | 12,181 | 67.3% | **1.22×** | A |
| 512x256x128 | 0.88 | 8 | 5 | 1 | 4 | 4 | 4 | 1 | 16,384 | 20,155 | **81.3%** | 21,352 | 76.7% | **1.06×** | - |
| 512x128x256 | 0.88 | 7 | 6 | 1 | 4 | 4 | 4 | 2 | 16,384 | 20,307 | **80.7%** | 26,010 | 63.0% | **1.28×** | - |
| 512x128x512 | 1.50 | 7 | 7 | 1 | 4 | 4 | 4 | 4 | 32,768 | 42,767 | **76.6%** | 55,859 | 58.7% | **1.31×** | - |
| 512x128x128 | 0.56 | 7 | 5 | 1 | 4 | 4 | 4 | 1 | 8,192 | 11,111 | **73.7%** | 12,553 | 65.3% | **1.13×** | - |
| 256x64x256 | 0.38 | 6 | 5 | 1 | 8 | 2 | 8 | 1 | 4,096 | 6,050 | **67.7%** | 7,203 | 56.9% | **1.19×** | A |
| 512x64x256 | 0.69 | 6 | 6 | 1 | 4 | 4 | 4 | 2 | 8,192 | 12,183 | **67.2%** | 16,223 | 50.5% | **1.33×** | - |
| 512x64x512 | 1.25 | 6 | 7 | 1 | 4 | 4 | 4 | 4 | 16,384 | 24,616 | **66.6%** | 30,198 | 54.3% | **1.23×** | - |
| 256x32x512 | 0.59 | 5 | 6 | 1 | 8 | 2 | 8 | 2 | 4,096 | 6,752 | **60.7%** | 7,901 | 51.8% | **1.17×** | A |
| 512x32x512 | 1.12 | 5 | 7 | 1 | 4 | 4 | 4 | 4 | 8,192 | 16,238 | **50.4%** | 16,884 | 48.5% | **1.04×** | - |
| 256x32x256 | 0.31 | 5 | 5 | 1 | 8 | 2 | 8 | 1 | 2,048 | 4,081 | **50.2%** | 3,919 | 52.3% | **0.96×** | A |
| 512x1024x128 | 2.75 | 10 | 5 | 1 | 4 | 4 | 4 | 1 | 65,536 | 173,949 | **37.7%** | 92,340 | 71.0% | **0.53×** | - |
| 2048x128x128 | 2.06 | 7 | 7 | 1 | 1 | 16 | 16 | 4 | 32,768 | 99,202 | **33.0%** | 62,703 | 52.3% | **0.63×** | B |
| 1024x256x256 | 2.25 | 8 | 7 | 1 | 2 | 8 | 8 | 4 | 65,536 | 229,609 | **28.5%** | 107,489 | 61.0% | **0.47×** | B |
| 1024x128x128 | 1.06 | 7 | 6 | 1 | 2 | 8 | 8 | 2 | 16,384 | 59,820 | **27.4%** | 28,185 | 58.1% | **0.47×** | B |
| 1024x256x512 | 3.50 | 8 | 8 | 1 | 2 | 8 | 8 | 8 | 131,072 | 549,575 | **23.8%** | 254,603 | 51.5% | **0.46×** | B |
| 1024x128x512 | 2.75 | 7 | 8 | 1 | 2 | 8 | 8 | 8 | 65,536 | 278,128 | **23.6%** | 132,103 | 49.6% | **0.47×** | B |

## Summary

| group | shapes | geomean speedup |
|---|---|---|
| **all** | 29 | **1.01×** |
| A-limited + balanced | 24 | **1.17×** |
| B-limited (`B-sh > A-sh`) | 5 | **0.50×** |

- **21 win** (>=1.05x), **2 flat**, **6 regress**.
- Highest utilisation: **128x1024x512 at 96.8%**.
- Largest speedup: **512x512x512 at 1.36×**.
- Worst: **1024x256x512 at 0.46×**.

Report the **split, not the overall geomean** -- the shape set deliberately
over-samples M >= 1024, so the aggregate averages two populations that behave
completely differently.

### Where we regress
| M×N×P | L1 MB | ss | sb | bb | A-sh | B-sh | merge | it | floor | ours | ours % | baseline | base % | speedup | lim |
|-------|------:|---:|---:|---:|-----:|-----:|------:|---:|------:|-----:|-------:|---------:|-------:|--------:|:---:|
| 512x1024x128 | 2.75 | 10 | 5 | 1 | 4 | 4 | 4 | 1 | 65,536 | 173,949 | **37.7%** | 92,340 | 71.0% | **0.53×** | - |
| 2048x128x128 | 2.06 | 7 | 7 | 1 | 1 | 16 | 16 | 4 | 32,768 | 99,202 | **33.0%** | 62,703 | 52.3% | **0.63×** | B |
| 1024x256x256 | 2.25 | 8 | 7 | 1 | 2 | 8 | 8 | 4 | 65,536 | 229,609 | **28.5%** | 107,489 | 61.0% | **0.47×** | B |
| 1024x128x128 | 1.06 | 7 | 6 | 1 | 2 | 8 | 8 | 2 | 16,384 | 59,820 | **27.4%** | 28,185 | 58.1% | **0.47×** | B |
| 1024x256x512 | 3.50 | 8 | 8 | 1 | 2 | 8 | 8 | 8 | 131,072 | 549,575 | **23.8%** | 254,603 | 51.5% | **0.46×** | B |
| 1024x128x512 | 2.75 | 7 | 8 | 1 | 2 | 8 | 8 | 8 | 65,536 | 278,128 | **23.6%** | 132,103 | 49.6% | **0.47×** | B |

All regressions are **B-limited** (`B-sh > A-sh`, i.e. M >= 1024) except
`512x1024x128`, which is a distinct MSHR-capacity failure (Finding 5).

## Finding 1 -- `merge_reqs` must equal `max(A-share, B-share)`

A and B have **different** sharing degrees, because the work split separates them:

```
dim_group     = M / num_groups
split_m_count = dim_group / KERNEL_SIZE
split_p_count = cores_per_group / split_m_count

A  a[m][n]         cores sharing an m-block differ only in p -> shared by split_p_count
B  b[n][p..p+VL]   cores sharing a p-range  differ only in m -> shared by split_m_count
```

The degrees **invert** with M, which is what makes this easy to get wrong:

| M | split_m | split_p | A share | B share | merge_reqs |
|---|---|---|---|---|---|
| 128 | 1 | 16 | 16 | 1 | 16 |
| 256 | 2 | 8 | 8 | 2 | 8 |
| **512** | **4** | **4** | **4** | **4** | **4** <- the shipped config |
| 1024 | 8 | 2 | 2 | 8 | 8 |
| 2048 | 16 | 1 | 1 | 16 | 16 |

At M=512 both degrees are 4, which is why the shipped configuration works and why
the dependency is invisible if you only ever run that shape. Sizing from
`split_p_count` alone (the A side) yields `merge_reqs=1` at M=2048 and `2` at
M=1024 -- **worse** than the wrong default.

At `merge_reqs=4` the sweep split bimodally with zero overlap, predicted **22/22**
by `max(A,B) > 4`: 9 shapes correctly provisioned at 50.4-87.1%, 13
under-provisioned at 20.8-28.2%.

Under-provisioning does not merely lower throughput, it **removes N-amortisation
entirely**. The M=256 family stays flat at 22.7-26.1% across a **16x range of N**,
because the overhead becomes proportional to the work (~2.8x compute) instead of
fixed per iteration.

## Finding 2 -- A coalescing is capacity-limited; B coalescing is not

Retuning each mis-provisioned shape to its derived `merge_reqs`:

| class | shapes | gain | final |
|---|---|---|---|
| **A-limited** | 8 | **2.21-3.61x** | 50.2-94.1% |
| **B-limited** | 5 | **1.01-1.25x** | 23.6-33.0% |

The decisive comparison is a controlled pair with **identical sharing degree and
identical merge capacity**, differing only in *which* matrix is shared:

```
128x128x512    A shared 16-way, merge=16  ->  83.7%
2048x128x128   B shared 16-way, merge=16  ->  33.0%
```

A **50-point gap at equal capacity** rules capacity out as the B-side limiter.
(Both halves of this pair were originally measured under an illegal `hold_subs`
setting; both have since been re-run legally and agree -- identical and -0.96%.)

**What the limiter is NOT** -- both candidates were tested directly and both failed:

| candidate | knob | result |
|---|---|---|
| futile hold timeouts | `hold_window_burst` 255 -> 64 -> 0 | 59,820 -> 59,620 -> **57,484** (**-3.9%**) |
| MSHR entry/bank capacity | `group_mshr_num` 64 -> 128 -> 256 | 173,949 -> 173,828 -> **172,301** (**-0.95%**) |

Neither the hold policy nor the entry pool explains the B-limited regression.
A "window-limited" framing was previously asserted here on the strength of held-entry
subscriber counts; that was **overstated** -- those counters track only the minority
held path, and removing holding entirely recovers 3.9%, not the ~2x gap.

**What is measured.** Instrumented runs of the mirror-image pair
(`1024x128x128`, A 2-way / B 8-way, 26.9% util -- and `256x512x256`, A 8-way /
B 2-way, 94.5% util):

| | 1024x128x128 | 256x512x256 |
|---|---|---|
| requests accepted | 737,777 | 1,290,481 |
| **merged** | 114,318 (**15.5%**) | 983,040 (**76.2%**) |
| **bypassed the MSHR** | **623,459 (84.5%)** | 307,441 (23.8%) |
| single merge rate | 38.3% | **87.5%** |
| burst merge rate | 53.2% | **50.0%** |

With `share`-way sharing the best achievable merge rate is `(share-1)/share`.
**`256x512x256` hits both ceilings exactly** -- A 8-way: ceiling 87.5%, measured
87.5%; B 2-way: ceiling 50%, measured 50.0%. The merge machinery is not defective.

The dominant difference is that the slow shape **bypasses 84.5% of its requests**
-- they never enter the MSHR at all, so they cannot merge. Bypass is *not* driven
by running out of ways (adding 4x the entries changed nothing), so its cause is
still **unidentified**.

Consequences:

* Sizing `merge_reqs` correctly is **necessary** but not sufficient.
* **Prefer shapes whose heavily-shared matrix is A, i.e. M <= 512.** Every result
  above 80% has M <= 512; every M >= 1024 shape stays below 33% regardless of tuning.
* The **bypass rate** is the metric to chase next; the hold window and the entry
  pool are both ruled out.

## Finding 3 -- utilisation is set by compute per p-iteration, and by A-sharing

The group barrier sits **inside** the p loop (`GBAR_SYNC_PLOOP`,
`kernel/sp-fmatmul.c:182`), so the number of syncs is `(P/split_p_count)/VL`.
**N raises compute per sync; P multiplies the number of syncs**, giving

```
util ~= C / (C + overhead),   C = floor / p_iters
```

But `overhead` is **not** a constant -- it grows with N, at a rate set by the
A-sharing degree:

| A-share | overhead: N=128 -> 256 -> 512 -> 1024 |
|---|---|
| 16-way (M=128) | 1,600 -> 1,698 -> 1,721 -> 2,157  (nearly flat) |
|  8-way (M=256) |   --  -> 1,793 -> 2,053 -> 2,717  (mild growth) |
|  4-way (M=512) | 2,919 -> 3,771 -> 5,557 -> (collapse)  (steep) |

so at **identical C** utilisation still varies by 10+ points:

| C | 16-way | 8-way | 4-way |
|---|---|---|---|
| 16,384 | 90.6% | 90.1% | 81.3% |
| 32,768 | 95.0% | 94.1% | 85.5% |
| 65,536 | 96.8% | 96.0% | (collapse) |

The exposed (non-coalesced) fraction of the A-scalar stream is set by the sharing
degree and scales with N. At 16-way the MSHR absorbs essentially all of it, so
adding N adds compute without adding exposed latency; at 4-way most stays exposed.

**Design rule: raise N *and* keep M small.** Small M is what buys the sharing
degree that makes raising N pay off.

**Treat the formula as a mechanism, not a predictor.** Predictions from it ran
0.6-8 points optimistic in *every* case checked, and failed outright on
`512x1024x128` (predicted ~89%, measured 37.7%).

## Finding 4 -- the ceiling is ~97%, set by L1

Minimising `p_iters` means one full vector per core:

```
p_iters = 1   <=>   P = 32 * split_p_count      (VL = 32 words for e32,m2)
```

`split_p_count = 16/split_m_count` is fixed by M, so **P is pinned by M** and N is
the only free variable. Then:

* **Larger N helps** -- every family improves monotonically with N.
* **Smaller P is illegal**, not merely worse: the burst path requires
  `P/split_p_count >= 32` words, so at M=256 the minimum legal P is 256.
* **N=1024 is the largest legal step** -- N=2048 needs 4.25 MB against 3.61 MB
  usable L1.

Best measured: **`128x1024x512` at 96.8%**, up from 94.1%. Verified as a complete
2x2 -- both designs on both simulators:

| | Verilator | QuestaSim |
|---|---|---|
| ours | 67,693 (96.8%) | 67,654 (96.9%) |
| baseline | 86,902 (75.4%) | 86,173 (76.1%) |
| **speedup** | **1.28x** | **1.27x** |

The utilisation and the speedup each reproduce independently within 0.9%. Passing ~97% needs a
different tiling (blocking N so A and B are not both fully resident), not a
different shape.

## Finding 5 -- `512x1024x128` collapses, and it is our regression

Ours 173,949 (37.7%) vs baseline 92,340 (71.0%) = **0.53x**. Functionally correct
(0 errors), **reproduced on QuestaSim** (172,670 / 38.0%, -0.74% from Verilator --
so not a simulator artifact), and the **baseline runs the same shape at 71%**, so the shape is not
pathological -- our MSHR is. Overhead jumps 20x on the last N doubling
(5,557 -> 108,413) after growing ~45% per step: a threshold effect, not a trend.

| shape | A-share | A working set / group | util |
|---|---|---|---|
| 128x1024x512 | 16-way | 32 KB | 96.8% |
| 256x1024x256 |  8-way | 64 KB | 96.0% |
| 512x512x128  |  4-way | 64 KB | 85.5% |
| **512x1024x128** | **4-way** | **128 KB** | **37.7%** |

Largest per-group A footprint tested with the weakest sharing to amortise it --
which made **MSHR entry exhaustion** the obvious hypothesis. **It was tested and
refuted:**

| `group_mshr_num` | cycles | util |
|---|---|---|
| 64 (default) | 173,949 | 37.7% |
| 128 | 173,828 | 37.7% |
| 256 | 172,301 | 38.0% |

4x the entries (and 4x the banks, at `ways_per_bank=4`) buys **0.95%**. Capacity is
not the cause. The mechanism is **unknown**; what is established is that it is
reproducible, simulator-independent, functionally correct, absent from the baseline,
and *not* explained by entry count, bank count, or hold policy.

## Finding 6 -- three bugs in `scripts/gemm_autotune.py`, found by running its output

| # | bug | effect |
|---|---|---|
| 1 | `hold_subs = 1` when a share degree is 1 | violates the RTL `[2, merge_reqs]` rule; **QuestaSim refuses to elaborate**, Verilator does not enforce it. No effect on results. |
| 2 | missing `resp_wait_subs_single = 0` | legal but **25% slower** (`2048x128x128`: 100,161 -> 125,433). That gate blocks *delivery* on the subscriber target independently of the hold window, so an unreachable target rides out `serve_timeout` on every scalar entry. |
| 3 | NOTE named the wrong matrix for B-limited shapes | cosmetic, but asserted the opposite of the truth. |

All fixed. Bug 1 was verified harmless by re-running four shapes legally -- all
bit-identical. Bug 2 was caught only because `2048x128x128` came back 25% off
instead of identical; with the complete fix it returns to 99,202 (-0.96% vs the
original), confirming no published number moves.

**Lesson: elaborate generated configs under QuestaSim before trusting them.**
Verilator does not enforce elaboration `$error`s, so an illegal configuration
silently produces plausible numbers.

## Baseline bug found and fixed: `tcdm_id_remapper` id_lock

`256x512x256` never completed on the baseline. Root cause in
`hardware/src/tcdm_id_remapper.sv`, which merges the Snitch integer LSU and the
Spatz FP-LSU onto one TCDM port: on a backpressured request cycle 1 presents the
remapped ID `next_id`, but cycle 2 skips the `if (!id_lock_q) req_o.id = next_id`
override and drives the master's raw `req.id`, keying the ROB at
`remapped_id_d[req.id]`. Presented ID, wire ID and ROB index disagree, so the
response is demuxed to the wrong master with an ID it never issued:

```
INVALID_RESP_ID resp_id=2 avail=11111100 ... req_id=2 req_id_q=1
```

an FP-LSU with only IDs 0,1 outstanding receiving a response tagged ID 2. The
misaligned loads and trashed stack frame Verilator reports ~11k cycles later are
downstream symptoms.

**Our tree already fixes this** (commit `e4a442f`, incidentally, as part of the
burst ID work): latch the presented remapped ID in `locked_remap_id_q`, keep
driving it for the whole stalled handshake, and key the ROB by it. Backporting
just that part to the baseline is bit-neutral on shapes that already worked
(`256x32x512` 8,303/7,901 and `512x64x256` 16,393/16,223, both exact) and repairs
the broken one: **44,618 cycles Verilator, 44,145 QuestaSim with the original
assertions armed**, `invalid_resp_id` and `input_data_unstable` both zero.

This is a latent, burst-independent correctness bug affecting any MemPool-derived
design sharing a TCDM port between the integer LSU and the FP-LSU.

## Caveats

- **`main.c:457` overflows 32 bits** (`1000*2*M*N*P`), so the *printed*
  `OP/1000cycle` and utilisation are wrong for large shapes. Every percentage here
  is recomputed from the cycle count.
- **`hold_subs` must be in `[2, merge_reqs]`.** A raw share degree of 1 is an
  elaboration `$error` that **Verilator does not enforce and QuestaSim rejects**.
  When a degree is 1, clamp to 2, zero that class's hold window, and -- for the
  SINGLE class -- also set `group_mshr_resp_wait_subs_single=0`, since that gate
  blocks delivery on the subscriber target independently of the window (skipping it
  cost 25% on `2048x128x128`). `128x128x512` and `2048x128x128` were originally
  measured under the illegal setting; both have been re-run legally and agree
  (identical, and -0.96%).
- **QuestaSim coverage is partial** for the baseline column (the table quotes
  Verilator); see the cross-simulator section below for every shape measured on
  both.

## Cross-simulator agreement

32 shapes measured on both simulators, sorted by absolute disagreement:

| M×N×P | design | Verilator | QuestaSim | delta |
|-------|--------|----------:|----------:|------:|
| 512x256x128 | baseline | 21,352 | 22,605 | +5.87% |
| 512x32x512 | baseline | 16,884 | 17,758 | +5.18% |
| 256x32x512 | baseline | 7,901 | 8,303 | +5.09% |
| 512x128x256 | baseline | 26,010 | 27,182 | +4.51% |
| 512x256x128 | ours | 20,155 | 20,781 | +3.11% |
| 128x128x512 | baseline | 10,850 | 11,176 | +3.00% |
| 1024x128x128 | baseline | 28,185 | 28,874 | +2.44% |
| 512x512x128 | ours | 38,325 | 37,642 | -1.78% |
| 128x256x512 | baseline | 20,446 | 20,785 | +1.66% |
| 128x512x512 | baseline | 44,292 | 44,981 | +1.56% |
| 512x256x256 | baseline | 48,505 | 47,763 | -1.53% |
| 256x512x256 | baseline | 44,618 | 44,145 | -1.06% |
| 512x64x256 | baseline | 16,223 | 16,393 | +1.05% |
| 512x128x512 | baseline | 55,859 | 55,310 | -0.98% |
| 256x1024x256 | ours | 68,253 | 68,854 | +0.88% |
| 128x128x512 | ours | 9,792 | 9,878 | +0.88% |
| 256x1024x256 | baseline | 88,671 | 87,919 | -0.85% |
| 128x1024x512 | baseline | 86,902 | 86,173 | -0.84% |
| 512x512x512 | baseline | 208,630 | 206,949 | -0.81% |
| 512x1024x128 | baseline | 92,340 | 91,631 | -0.77% |
| 1024x256x256 | baseline | 107,489 | 106,680 | -0.75% |
| 512x1024x128 | ours | 173,949 | 172,670 | -0.74% |
| 2048x128x128 | baseline | 62,703 | 63,150 | +0.71% |
| 512x512x128 | baseline | 45,309 | 45,066 | -0.54% |
| 1024x128x512 | baseline | 132,103 | 132,489 | +0.29% |
| 128x512x512 | ours | 34,489 | 34,565 | +0.22% |
| 512x64x512 | baseline | 30,198 | 30,132 | -0.22% |
| 256x512x512 | baseline | 94,078 | 94,243 | +0.18% |
| 128x256x512 | ours | 18,082 | 18,062 | -0.11% |
| 1024x256x512 | baseline | 254,603 | 254,793 | +0.07% |
| 128x1024x512 | ours | 67,693 | 67,654 | -0.06% |
| 512x256x512 | baseline | 105,766 | 105,821 | +0.05% |

Maximum disagreement **5.87%**, and the sign varies -- neither simulator is
systematically optimistic. Verilator is the workhorse for sweeps (~29x faster on
our design, no licence); QuestaSim is the authority on anything involving
assertions, since Verilator compiles `ifndef VERILATOR` blocks out entirely and
does not enforce elaboration `$error`s.

## Tuning a new shape

```bash
scripts/gemm_autotune.py -M 256 -N 512 -P 256
scripts/gemm_autotune.py --json software/apps/spatz_apps/<app>/script/matmul.json
make ... $(scripts/gemm_autotune.py -M 256 -N 512 -P 256 --make)
```

It derives every shape-dependent knob, validates against the kernel work-split
guards and L1 capacity, and refuses illegal shapes. **Legal-shape constraints:**

* `M` a multiple of `num_groups x KERNEL_SIZE` = 128, and `split_m_count` must
  divide `cores_per_group` -> **M in (128, 256, 512, 1024, 2048)** (384, 640 illegal)
* `N` even; powers of two keep `clog2` exact
* `P / split_p_count >= 32` words, else `shift_burst < 5` and elaboration fails
* `4*(M*N + N*P + M*P) <= 3.61 MB`

## Method notes

* **Verilator, not QuestaSim**, for the bulk sweeps: ~29x faster on our design
  (54.3 vs 1.85 cyc/s), no licence, standalone binary, so all shapes ran
  concurrently. It is *slower* than QuestaSim on the baseline, whose cost scales
  with design activity rather than size. See `verilator_simulation.md`.
* Builds on **tmpfs** (`/dev/shm`) with a 60 GB ccache and `-g0`; disk I/O had
  been the binding constraint (91 processes in D-state while 1.1 TB of RAM sat
  unused).
* Traces must be deleted per run: the app enables `csr_trace` from software, so
  `snitch_trace=0` does **not** suppress them (~5-10 GB per run).
* Reproducibility: a control re-run reproduced `256x512x256` at exactly 34,821,
  and two independently built models of `256x1024x256` both gave 68,253. Counts
  from different *generations* of the tree are not necessarily comparable --
  re-measure a control when comparing across time.
