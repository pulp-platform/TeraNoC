# GEMM shape status — every shape, every phase, side by side

Generated 2026-08-16 22:03. **Re-runnable**: `python3 scripts/gen_shape_status.py`.


The other `gemm_results_*.md` files are a **chain**: each measures one phase against the phase
immediately before it. That is the right way to attribute a change, but it means answering "where
does this shape stand now?" takes six files and some arithmetic. This file is the transpose —
shapes down, phases across — and it is generated from the same `[FPU FINAL]` lines, so it cannot
drift from them.

`_run_` means the arm is still running and has produced no FINAL; `_inc_` means it reached the
benchmark but died or was killed before one. Neither is a result. `—` means that arm was never run
for that shape — the `BYP` and `CSRBYP` columns exist only for the four `128x*x512` shapes, where
`share_b = 1` makes B private and a burst MSHR entry can never find a second subscriber.

**Efficiency is `ideal / actual`**, `ideal = M·N·P / 1024`. Not the testbench's `[FPU] util`
counter, which measures lane occupancy and is not conserved across runs of identical work.

## Phases

The chain — the default build's history, each step adding to the one above:

| column | what it adds |
|---|---|
| `opt2` | drain_from_q=1 |
| `opt3` | + bank_publish=1 |
| `C2` | + B1b, C3, spill_req_in=0 |
| `E1` | + commit-FIFO depth, ROB counter (config only) — **the default today** |

Opt-in branches. **None of these is in the default build** — each is a knob you turn on,
so their columns are alternatives to `current`, not successors to it:

| column | what it is |
|---|---|
| `CSR` | cfg_runtime=1 — MSHR off at reset, software enables it |
| `BYP` | hold_subs_burst=1 elaborated (share_b=1 family only) |
| `CSRBYP` | hold_subs_burst=1 written by software, with cfg_runtime=1 |

## Current status

**`current`** is the latest phase of the **default build** (`group_mshr_cfg_runtime = 0`) — what
you get today without turning anything on. The `CSR`, `BYP` and `CSRBYP` columns are **opt-in
alternatives**, not later states: a number there is what that shape would do *if you enabled that
knob*, and it is frequently worse.

**`best`** is the minimum over every arm ever run. Where it differs from `current` the best often
sits on a **superseded** phase, so it is not performance you can have today without reverting
something — treat a large gap as a regression to explain, not as headroom.

Sorted by current efficiency, best first.

| M×N×P | ideal | baseline | opt2 | opt3 | C2 | E1 | CSR | BYP | CSRBYP | **current** | from | **eff** | best | from |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|:--|---:|---:|:--|
| 256x1024x256 | 65,536 | 68,253 | 68,689 | 68,607 | 68,410 | 68,410 | 68,379 | — | — | **68,410** | E1 | **95.8%** | 68,379 | CSR |
| 256x512x256 | 32,768 | 34,821 | 34,671 | 34,703 | 34,547 | 34,547 | 34,812 | — | — | **34,547** | E1 | **94.9%** | = |  |
| 256x512x512 | 65,536 | 71,218 | 70,990 | 70,550 | 71,116 | 71,116 | 70,379 | — | — | **71,116** | E1 | **92.2%** | 70,379 | CSR |
| 256x256x256 | 16,384 | 18,177 | 18,038 | 18,210 | 17,984 | 17,984 | 18,115 | — | — | **17,984** | E1 | **91.1%** | = |  |
| 512x256x256 | 32,768 | 37,632 | 37,875 | 38,397 | 38,260 | 38,260 | 38,730 | — | — | **38,260** | E1 | **85.6%** | 37,875 | opt2 |
| 512x512x512 | 131,072 | 153,707 | 156,085 | 156,294 | 154,734 | 154,734 | 155,036 | — | — | **154,734** | E1 | **84.7%** | = |  |
| 512x512x128 | 32,768 | 38,325 | 37,738 | 36,959 | 38,885 | 38,885 | 39,612 | — | — | **38,885** | E1 | **84.3%** | 36,959 | opt3 |
| 512x256x128 | 16,384 | 20,155 | 19,959 | 19,819 | 19,493 | 19,493 | 19,919 | — | — | **19,493** | E1 | **84.1%** | = |  |
| 256x128x256 | 8,192 | 10,014 | 10,018 | 9,831 | 9,944 | 9,944 | 9,906 | — | — | **9,944** | E1 | **82.4%** | 9,831 | opt3 |
| 512x256x512 | 65,536 | 78,314 | 79,499 | 80,468 | 79,653 | 79,653 | 280,917 | — | — | **79,653** | E1 | **82.3%** | 79,499 | opt2 |
| 512x128x256 | 16,384 | 20,307 | 20,812 | 20,575 | 20,538 | 20,538 | 21,065 | — | — | **20,538** | E1 | **79.8%** | = |  |
| 128x512x512 | 32,768 | 34,489 | 46,106 | 46,256 | 41,943 | 41,943 | 45,969 | _run_ | — | **41,943** | E1 | **78.1%** | = |  |
| 512x128x512 | 32,768 | 42,767 | 42,500 | 42,554 | 42,743 | 42,743 | 42,578 | — | — | **42,743** | E1 | **76.7%** | 42,500 | opt2 |
| 128x256x512 | 16,384 | 18,082 | 25,606 | 25,498 | 21,614 | 21,614 | 27,579 | 17,627 | _run_ | **21,614** | E1 | **75.8%** | 17,627 | BYP |
| 512x128x128 | 8,192 | 11,111 | 12,233 | 11,493 | 11,144 | 11,144 | 11,179 | — | — | **11,144** | E1 | **73.5%** | = |  |
| 256x64x256 | 4,096 | 6,050 | 5,907 | 5,804 | 5,860 | 5,860 | 5,701 | — | — | **5,860** | E1 | **69.9%** | 5,701 | CSR |
| 512x64x256 | 8,192 | 12,183 | 11,756 | 11,898 | 11,930 | 11,930 | 11,712 | — | — | **11,930** | E1 | **68.7%** | 11,712 | CSR |
| 512x64x512 | 16,384 | 24,616 | 24,399 | 24,300 | 24,607 | 24,607 | 24,480 | — | — | **24,607** | E1 | **66.6%** | 24,300 | opt3 |
| 256x32x512 | 4,096 | 6,752 | 6,563 | 6,584 | 6,598 | 6,598 | 6,826 | — | — | **6,598** | E1 | **62.1%** | 6,563 | opt2 |
| 256x32x256 | 2,048 | 4,081 | _inc_ | 3,859 | 3,771 | 3,771 | 3,667 | — | — | **3,771** | E1 | **54.3%** | 3,667 | CSR |
| 512x32x512 | 8,192 | 16,238 | 15,037 | 15,213 | 15,088 | 15,088 | 15,471 | — | — | **15,088** | E1 | **54.3%** | 15,037 | opt2 |
| 128x1024x512 | 65,536 | 67,693 | 75,614 | 139,129 | 130,792 | 130,792 | _run_ | _run_ | — | **130,792** | E1 | **50.1%** | 75,614 | opt2 |
| 128x128x512 | 8,192 | 9,792 | 13,138 | 165,585 | 16,995 | 16,995 | — | 9,401 | — | **16,995** | E1 | **48.2%** | 9,401 | BYP |

`=` in the `best` column means current *is* the best ever measured for that shape.

## Summary

- **23 of 23 shapes** have a result on a chain phase.
- Current efficiency: median **78.1%**, range 48.2%–95.8%.
- Current result comes from: `E1` ×23.
- **12 of 23** are faster than the 2026-08-03 baseline; 11 are not.
- Enabling the runtime CSR (`CSR`) costs a median **+0.73%** over 21 shapes, but the spread is what matters: `512x256x512` +252.7%, `128x256x512` +27.6%, `128x512x512` +9.6%.
- **16 shapes are slower now than their best-ever arm.** Largest gaps: `128x128x512` 1.81× (E1 16,995 vs BYP 9,401), `128x1024x512` 1.73× (E1 130,792 vs opt2 75,614), `128x256x512` 1.23× (E1 21,614 vs BYP 17,627), `512x512x128` 1.05× (E1 38,885 vs opt3 36,959).
- Burst bypass (`BYP`), on the `share_b = 1` family: `128x256x512` -18.4% vs current, `128x128x512` -44.7% vs current.

Generated from `[FPU FINAL]` in the per-arm run logs. Re-run the script after any new arm lands rather than editing this table by hand.
