# GEMM benchmark results — 8×8 mesh, 1024 cores — MSHR & response-channel sweep

Shape **2048×512×512** on the 8×8 / 64-group mesh (1024 cores, 4096 FPU lanes).
`ideal = M·N·P / 4096 = 131,072` cycles; efficiency is `ideal / actual`.

**Provenance.** Recovered on 2026-08-16 from the published artifact *FIXED BARRIER — FPU
utilisation — 8×8 / 1024-core sweep* (generated 2026-08-13 23:05), which was the live view
during that campaign. The underlying build directories have since been reclaimed, so this
file is the durable record. Numbers are as the artifact reported them; the efficiency column
is derived here.

> **These are 8×8 numbers and do not compare with anything in the 4×4 files.** Different mesh,
> different core count, different lane count, different shape. The 4×4 campaign
> (`gemm_results_mshr_ppa*.md`) is a separate series.

## Completed runs

| arm | cycles | efficiency | fleet util | plateau | hold | resp | split | note |
|---|---:|---:|---:|---:|---:|---:|:--|:--|
| `h2047r2` | 169,073 | 77.5% | 82.22% | 91.3% | 2047 | 2 | rd0+rdwr2 | remap2 NEW hold-2047 cell |
| `h2047r2e` | 172,985 | 75.8% | 79.42% | 88.6% | 2047 | 3 | rd1+rdwr1 | remap2 enhanced NEW |
| `g54diag` | 178,009 | 73.6% | 77.97% | 90.4% | 1023 | 2 | rd0+rdwr2 | remap2 + stall/mem/insn probes, traces g54,56,62 |
| `fpugir2` | 178,009 | 73.6% | 77.97% | 90.4% | 1023 | 2 | rd0+rdwr2 | remap2 rtl08-09 trace-off FPUG |
| `b2047` | 180,313 | 72.7% | 78.38% | 85.9% | 2047 | 3 | rd1+rdwr1 | rtl08-07 traced |
| `b1023` | 186,711 | 70.2% | 75.43% | 87.0% | 1023 | 3 | rd1+rdwr1 | rtl08-07 traced |
| `bremap2` | 196,301 | 66.8% | 70.11% | 87.4% | 1023 | 3 | rd1+rdwr1 | remap2 rtl08-08 trace-off |
| `c2047` | 200,314 | 65.4% | 73.88% | 79.3% | 2047 | 2 | rd1+rdwr1 | rtl08-07 traced |
| `fpug1023` | 200,675 | 65.3% | 74.27% | 79.7% | 1023 | 2 | rd0+rdwr2 | rtl08-09 trace-off FPUG |
| `a2047` | 201,075 | 65.2% | 74.02% | 79.0% | 2047 | 2 | rd0+rdwr2 | rtl08-07 traced |
| `xf1023` | 203,617 | 64.4% | 67.95% | 85.0% | 1023 | 4 | rd0+rdwr1 | rtl08-07 trace-off |
| `xe1023` | 207,100 | 63.3% | 68.4% | 81.7% | 1023 | 3 | rd0+rdwr1 | rtl08-07 trace-off |
| `xa511n` | 315,044 | 41.6% | 45.8% | 72.7% | 511 | 2 | rd0+rdwr2 | bcastOFF rtl08-07 trace-off |
| `bfix` | 315,684 | 41.5% | 44.06% | 79.3% | 511 | 3 | rd1+rdwr1 | rtl08-06 traced |
| `xd2047` | 332,191 | 39.5% | 51.03% | 52.9% | 2047 | 2 | rd0+rdwr1 | rtl08-07 trace-off |
| `cfix` | 337,430 | 38.8% | 41.73% | 67.2% | 511 | 2 | rd1+rdwr1 | rtl08-06 traced |
| `c1023` | 350,061 | 37.4% | 42.03% | 79.3% | 1023 | 2 | rd1+rdwr1 | rtl08-07 traced |
| `fpug511` | 363,782 | 36.0% | 39.26% | 71.0% | 511 | 2 | rd0+rdwr2 | rtl08-08 trace-off FPUG |
| `xa511` | 363,782 | 36.0% | 39.26% | 71.0% | 511 | 2 | rd0+rdwr2 | rtl08-07 trace-off |
| `fpug255` | 369,611 | 35.5% | 40.58% | 25.0% | 255 | 2 | rd0+rdwr2 | rtl08-09 trace-off FPUG |
| `f2047` | 445,748 | 29.4% | 30.99% | 84.8% | 2047 | 4 | rd0+rdwr1 | rtl08-07 traced |
| `ihash0` | 551,678 | 23.8% | 29.24% | 43.6% | 1023 | 2 | rd0+rdwr2 | hash0 rtl08-07 trace-off |
| `d1023` | 577,474 | 22.7% | 26.93% | 46.6% | 1023 | 2 | rd0+rdwr1 | rtl08-07 traced |
| `e2047` | 606,644 | 21.6% | 23.35% | 81.7% | 2047 | 3 | rd0+rdwr1 | rtl08-07 traced |
| `d511` | 687,906 | 19.1% | 23.22% | 14.6% | 511 | 2 | rd0+rdwr1 | rtl08-06 traced |
| `fpuggb0` | 743,851 | 17.6% | 19.32% | 63.5% | 511 | 2 | rd0+rdwr2 | BARRIER OFF (GBAR_PLOOP=0) rtl08-08 trace-off FPUG |

**26 arms completed.** Best 169,073 cyc, worst 743,851 cyc — a 4.4× spread across configurations.

## Determinism — there is no noise floor

Configurations differing only in name completed at **byte-identical** cycle counts:

| cycles | arms that produced exactly this |
|---:|:--|
| 648,607 | `FG255`, `P255` |
| 743,851 | `FGGB0`, `GBAR0`, `PGB0` |
| 866,235 | `11`, `FG511`, `P511`, `PA511`, `XA511`, `XA511N` |
| 1,432,655 | `FGIR2`, `IREMAP2` |
| 1,438,712 | `C1023`, `PC1023`, `XC1023` |
| 1,446,448 | `B1023`, `XB1023` |
| 1,493,883 | `A1023`, `FG1023`, `PA1023`, `XA1023` |
| 1,556,377 | `F1023`, `XF1023` |
| 1,597,735 | `D1023`, `PD1023` |
| 1,669,486 | `E1023`, `XE1023` |
| 2,783,198 | `D2047`, `XD2047` |

30 arms across 49 runs. Run-to-run variation is not small, it is **exactly zero**.

Two consequences, and they shaped how the rest of the campaign was run:

- **Any cycle difference between two configs is signal.** The only thing to rule out is a
  *confound*, never noise.
- **Repeats measure nothing.** A second run of the same config is guaranteed to reproduce the
  first, so machine time is better spent on more configurations. This is what licensed
  single-run matched-pair comparisons throughout the campaign.

## Findings that carried forward

These are the conclusions the campaign reached, recorded because several of them were corrections
of earlier claims and the reasoning matters more than the numbers.

### The barrier fix is worth 14.1%, and that is the only defensible throughput figure

`GBAR0` 743,851 cyc against `A` 866,235 cyc. The comparison is **"barrier working" versus "barrier
absent"**, not a tuning choice: at 8×8 the pre-fix group barrier was a *silent no-op*, because
`sp-fmatmul.c` hardcoded a `<<14` word stride that is only correct at 16 groups. At 64 groups every
barrier op addressed a word outside the barrier window, so the RTL re-route never fired and three of
four went to a remote group. No hang, no error, no synchronisation.

The one-grep test for this, worth keeping: `grep -o 'bar_rel=+[0-9]*' <run>.log | sort -u` — all
`+0` across a run means the barrier never fired.

### `hold=1023` costs 22–108% and the 8×8 base config shipped it to every arm

Three matched pairs measured +22%, +82% and +108% against `hold=511`; family medians 1.92× apart.
The 4×4 production default was already 255. Several 8×8 arms are slow substantially *because* of
this inherited default rather than because of the variable under test.

### Whole-kernel utilisation is an identity, not a measurement

Total work is fixed, so busy lane-cycles are ~constant and `util = busy/(cycles·lanes)`. Over 22
completed arms, `util × cycles = 146,571 ± 7,684` (CV 5.2%), and `log(util)` against `log(cycles)`
gives **r = −0.985, slope −0.995** where the identity predicts exactly −1.

**A whole-kernel utilisation ranking is the completion ranking written backwards.** Rank on
completion cycles. (Early-window utilisation is a different thing and remains a genuine leading
indicator.)

### A fixed slow set, not rotating stragglers

21 of 64 groups are persistently slow, the same set early and late (r = 0.92), bimodal at ~82% and
~22%. They are **not** contiguous on the mesh — apparent clustering appeared in one arm only
(FG511, 0.77) while others showed none (0.96–0.99). An earlier reading of "every group takes turns"
came from a ranking that showed only the extremes; the full per-group distribution contradicts it.

### Retracted

An earlier headline claimed **+0.78 correlation** between early utilisation and completion cycles —
i.e. that higher-utilisation arms finished *slower*. **Retracted 2026-08-13.** Re-derived over 46
completions it is **−0.16 to −0.29**, sign reversed. The original sample came from a ranking that
excluded the fastest arms. Rank on completion, but because whole-kernel utilisation is an algebraic
restatement of it, not because utilisation misleads.

## Excluded from the ranking

| arm | cycles | periods | plateau | why |
|---|---:|---:|---:|:--|
| `h2047r2` | 169,073 | 168 | 91.3% | reference cell for the busted-window comparison, not a sweep arm |
| `h2047r2e` | 172,985 | 172 | 88.6% | its enhanced-channel twin, same role |

## What is not here

Per-period and per-group series, the barrier-alignment (`bar_rel`) tables, MSHR counter histories
and the core-drift panel exist only in the artifact. The core-drift numbers in particular **cannot be
regenerated** — they came from per-core `.dasm` traces that were truncated on 2026-08-08 to reclaim
756 GB. Reproducing that panel needs a fresh run with tracing enabled.
