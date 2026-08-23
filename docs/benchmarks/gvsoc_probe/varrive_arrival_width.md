# VLSU response arrival width at 4x4 (256 cores) — RTL measurement

## Run identification (cycle count first, per the agreed rule)

    [UART] The execution took 4188 cycles.
    [FPU FINAL] busy=2156908 of 3938304 lane-cycles over 3846 benchmark cycles -> util=54.77%
    [EOC] Simulation ended at 67210.00 ns (retval = 0).

All four fields reproduce the reference run exactly (`build_vperf`, `build_occ`, `build_mshrlife4`),
so this is a valid arm, not a requeue.

**RTL: cvfpu pulp-v0.1.3** (pre-upgrade; `build_arr` compiled 2026-08-19 13:26, zero
`fpnew_mxdotp_multi` refs). ELF `matmul_gvsoc_probe.elf`, 256x32x256, e32/m2, fp32.

**Full knob set** (a shape name is not sufficient identification for a measurement):

    GROUP_MSHR_HOLD_SUBS_SINGLE=8   GROUP_MSHR_HOLD_SUBS_BURST=2   GROUP_MSHR_MERGE_REQS=8
    GROUP_MSHR_BANK_SHIFT_SINGLE=5  GROUP_MSHR_BANK_SHIFT_BURST=5  GROUP_MSHR_BANK_BURST_BITS=1
    GROUP_MSHR_HOLD_WINDOW_BURST=2047   GROUP_MSHR_NUM=64
    NOC_ROUTER_REMAPPING=2          SPATZ_VLSU_BURST_EW16=0

## Result: the gap is ARRIVAL WIDTH, not commit policy

256 of 256 cores reported. Every core: `win=3845`, `arr_words=1280`, `ports=4` — identical load, so
no imbalance confound.

| metric | min | mean | max |
|---|---|---|---|
| arrival width (words per cycle in which anything arrived) | 1.1841 | **1.2667** | 1.3375 |
| fraction of arrival cycles that are 2-wide | 0.1841 | 0.2664 | 0.3375 |
| words per MULTI-arrival cycle | 2.0000 | **2.0013** | 2.0283 |
| arrival-cycle occupancy (`arr_cyc/win`) | — | 0.2629 | — |
| sustained rate over whole window (`arr_words/win`) | — | **0.3329** | — |

stdev of arrival width across cores = 0.0247 (tight).

**The load never presents wider than 2.** When two or more words arrive in the same cycle, it is
essentially always *exactly* two — mean 2.0013 — despite `ports=4`. 3- and 4-wide arrivals are
negligible.

So the entry path averages 1.27 words per arrival cycle because ~73% of arrival cycles carry one
word and ~27% carry two. A model assuming 2.00 words/cycle on the entry path is assuming a width
this hardware does not sustain. The GVSOC-side figure of 1.31 sits inside the RTL's per-core range
[1.1841, 1.3375] — that measurement was correct.

## CORRECTION: arrival width is NOT comparable to the GVSOC 1.31

An earlier version of this note claimed the GVSOC-side 1.31 "sits inside the RTL's per-core range
[1.1841, 1.3375]" and was therefore correct. **That compared two different stages.** The 1.31/1.33 is
words per *commit* cycle; the 1.2667 here is words per *arrival* cycle. Like-for-like:

| stage | RTL | GVSOC model | ratio |
|---|---|---|---|
| arrival width | **1.2663** | 1.0025 | 1.263 |
| 2-wide fraction of arrival cycles | **26.6%** | 0.25% | — |
| commit width | 2.00 | 1.33 | 1.50 |

The arrival-width deficit is **confirmed, not retired**. What this measurement changes is the
*magnitude*: 1.27x, not the 2x the work had been sized against.

## The 256-word gap is DEGENERATE at this shape

`arr_words` = 1280/core but only 1024 commit (512 pairs, 0 singles). The 256-word remainder is 20% of
arrivals. Per-core geometry printed by the run (`m=8, N=32, p=32`):

    A = m*N = 256 words   scalar flw (t0 = *a__, feeds vfmacc.vf "f" operand)
    B = N*p = 1024 words  vle32.v      == the commit count exactly
    C = m*p = 256 words   vse32.v stores

**A and C are both exactly 256** because N = p = 32 here, so `B+A` and `B+C` both equal 1280.
Arithmetic cannot separate them at this shape.

Port topology *favours* C stores — `mempool_tile.sv:89` establishes flat port 0 as the scalar port and
flat ports 1..N as the VLSU's, so a probe scoped inside `i_vlsu` should not observe scalar `flw`, and
stores never commit into the ROB. **This is inference from topology, not a measurement, and is not
asserted.**

Consequence for return-path sizing: treat the requirement as **1024 confirmed + 256 unattributed**,
not a flat 1280. If the 256 are C stores, sizing a *load* return path at 1280 over-provisions by 25%,
compounding with the 2-wide duty-cycle overshoot in the same direction.

**Decisive experiment:** re-add `[VARRIVE]` and run a shape with **N != p**, which breaks the
degeneracy (A = m*N and C = m*p then differ, and the two hypotheses predict different `arr_words`).
Repeating 256x32x256 would only produce another undecidable number.

## Data integrity

Internal identity `arr_h1 + arr_h2p == arr_cyc` holds **exactly for all 256 cores** (0 violations),
and `arr_words - arr_h1` divided by `arr_h2p` lands on 2.0 to four decimals. A malfunctioning probe
would not satisfy either.

⚠️ **RETRACTED — the probe was never reverted.** An earlier version of this note claimed
`[VARRIVE]` had been removed from the tree and that this was a one-shot artifact. False: it is at
`spatz_vlsu.sv:2042-2097` and always was. The claim came from grepping
`TeraNoC_Spatz/working_dir/...` instead of `TeraNoC_Spatz/TeraNoC/working_dir/...` — one dropped path
component, a non-existent directory, an empty result read as absence. These numbers are fully
reproducible. Raw per-core lines in `raw/varrive_4x4_256cores.txt` (256 lines).

## ⚠️ THE HEADLINE NUMBER DOES NOT ISOLATE WHAT IT NAMES

`c_arr_words` counts `$countones(spatz_mem_rsp_valid_i)` with **no write mask** (`:2068`), and
**store acknowledgements assert that same valid** — the store-ack test at `:280` qualifies on
`spatz_mem_rsp_i[port].write`, proving writes arrive on this interface. Meanwhile `rob_push`
(`:1673`) explicitly excludes writes. So the arrival counter counts loads **and** store acks while
the commit counter counts only loads; 1280 − 1024 = 256 = the C stores, from source, no geometry
argument needed.

The damaging consequence is for the histogram, not the total: **a store ack sharing a cycle with a
load is scored as a 2-wide arrival.** So `arr_h2p` never measured load+load width. Against 269
two-wide cycles and 256 store acks, genuine load+load cycles lie anywhere in **13 … 269** — a factor
of 20, with the conclusion inside it.

**Treat the 1.2667 arrival width as UNDETERMINED, not as a 1.27× advantage.** Do not size a return
path against it.

**Resolution in flight:** `spatz_vlsu.sv` now carries a parallel write-filtered histogram
(`rsp_load_valid[pp] = spatz_mem_rsp_valid_i[pp] && !spatz_mem_rsp_i[pp].write`) emitting
`[VARRIVE-LD] ld_words= ld_cyc= ld_h1= ld_h2p=` alongside the unfiltered `[VARRIVE]`, so the
difference measures store traffic directly. Running as `build_ldarr`,
`config=terapool_spatz4_fpu_gemm256x32x256`, knobs identical to the original run. Predictions
registered in advance: `ld_words=1024`, `arr_words=1280`, app timer `4188`.

---

## RESOLVED 2026-08-19 18:35 — write-filtered measurement

`spatz_vlsu.sv` now carries a parallel load-only histogram
(`rsp_load_valid[pp] = spatz_mem_rsp_valid_i[pp] && !spatz_mem_rsp_i[pp].write`). Run `build_ldarr2`,
same shape/knobs, reproducing all four acceptance fields (4188 cycles, busy=2156908 of 3938304 over
3846, retval=0, 67210.00 ns) — so the added counters are passive.

| | words | cycles | h1 | h2p |
|---|---:|---:|---:|---:|
| unfiltered (loads + store acks) | 1280.0 | 1010.9 | 742.1 | 268.8 |
| **load-only** | **1024.0** | **767.4** | 510.9 | **256.6** |

- **store acks = 256.0 exactly** — the 20% gap is the C stores, confirmed by measurement, not inference.
- **store-only cycles = arr_cyc − ld_cyc = 243.4.** For 256 acks that is ~0.95 per cycle: store acks
  land almost entirely **one per cycle in cycles of their own**.
- **Load arrival width = 1024.0 / 767.4 = 1.3343** (2-wide load fraction 33.4%).

### The contamination was hiding a LARGER deficit, not a smaller one

| | RTL | GVSOC model | ratio |
|---|---:|---:|---:|
| contaminated (as first published) | 1.2667 | 1.0025 | 1.263× |
| **load-only (correct)** | **1.3343** | 1.0025 | **1.331×** |

Store acks occupy their own 1-wide cycles, inflating `arr_cyc` and dragging the mean down. Removing
them **raises** the RTL width. The arrival-width deficit is real and ~5% larger than the
contaminated number suggested.

### Both predictions were wrong; the withdrawn one was right

Registered in advance: GVSOC originally ~269 (stores are epilogue-clustered, so they do not share
cycles with loads), then updated to ~141 after this session argued that clustered-and-isolated
traffic pairs with *itself*; this session also predicted ~141. **Actual 256.6** — the original
~269 reasoning was correct.

The error in the ~141 argument: the stores issue strictly in sequence through a serialising VLSU, so
their acks return in sequence — **clustered in time without being simultaneous**. Clustering and
concurrency are different properties, and conflating them produced a persuasive wrong answer that
moved a correct prediction off its position.

Raw per-core lines: `raw/varrive_ld_4x4_256cores.txt` (512 lines, 256 unfiltered + 256 load-only).