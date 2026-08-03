# Benchmark documentation

Performance measurements of TeraNoC-Spatz on GEMM (`sp-fmatmul`), the tooling used
to produce them, and the bottleneck analysis behind them.

Design documents live one level up in `docs/`; this folder is **measurements and
the infrastructure that produces them**.

---

## The four documents

| document | what it is |
|---|---|
| **[`gemm_results.md`](gemm_results.md)** | **Start here.** The single source of truth for GEMM performance: all 29 shapes vs. the baseline, the tuning rules, and every finding. |
| [`gemm_results_table.txt`](gemm_results_table.txt) | The same table as plain text, for diffing and quoting. |
| [`verilator_simulation.md`](verilator_simulation.md) | How to build and run these benchmarks fast. |
| [`matmul_bottleneck_report.md`](matmul_bottleneck_report.md) | Microarchitectural analysis of where matmul cycles go — the motivation for the design work in `docs/`. |

---

## Headline results

| | |
|---|---|
| **Best shape** | `128×1024×512` — **96.8%** FPU utilisation |
| **Practical ceiling** | ~97%, set by L1 capacity (N=2048 does not fit) |
| **vs. baseline** | geomean **1.17×** on the 23 non-B-limited shapes, **0.50×** on the 6 B-limited ones |
| **Design rule** | raise N *and* keep M small — small M buys the A-sharing degree that makes raising N pay off |

Report the split, never the 1.01× overall: the shape set deliberately over-samples
M ≥ 1024, so the aggregate averages two populations that behave completely
differently.

Two known regressions, both documented in `gemm_results.md`:

- **B-limited shapes** (M ≥ 1024) run ~0.47×. Burst merging is *window*-limited,
  not capacity-limited — the fix is to **bypass** the MSHR when `B-share > A-share`.
- **`512×1024×128`** collapses to 37.7% while the baseline manages 71%. A distinct
  MSHR *entry*-exhaustion failure, and **untested**.

---

## Reading the numbers

Utilisation is always recomputed from cycle counts as

```
util = floor / cycles,   floor = 2·M·N·P / 2048
```

where 2048 = 256 cores × 4 FPU × 2 flop/FPU/cycle.

⚠️ **Do not trust the utilisation the benchmark prints.** `main.c:457` computes
`1000*2*M*N*P` in 32 bits, which overflows for large shapes and under-reports by up
to ~125×. Every figure in these documents is recomputed from the cycle count.

**Simulator agreement:** Verilator and QuestaSim agree within ±5.9% across all
shapes measured on both, sign varying — neither is systematically optimistic. The
disagreement concentrates in *small* shapes (fixed boot/setup offset); every shape
with floor ≥ 32k cycles agrees to under 1.6%.

---

## Two traps worth knowing before you generate a config

1. **Verilator does not enforce elaboration `$error`s.** An illegal configuration
   builds and produces plausible-looking numbers; QuestaSim refuses to elaborate
   the same thing. **Elaborate generated configs under QuestaSim before trusting
   them.** Two of the three auto-tuner bugs found in this campaign were invisible
   under Verilator.
2. **`scripts/gemm_autotune.py` provisions merge width, not entry count.** Nothing
   checks that the number of *distinct* concurrent MSHR entries fits in
   `group_mshr_num`. That is the leading explanation for the `512×1024×128`
   collapse.

---

## Reproducing

```bash
# derive every shape-dependent knob (rejects illegal shapes)
python3 scripts/gemm_autotune.py -M 128 -N 1024 -P 512

# build + run — see verilator_simulation.md for the full flow
cd hardware
make -o update-floogen <verilator-target> config=terapool_spatz4_fpu \
     group_mshr_bank_shift_single=10 group_mshr_bank_shift_burst=5 \
     group_mshr_merge_reqs=16 group_mshr_hold_subs_single=16 \
     group_mshr_hold_subs_burst=2 group_mshr_hold_window_burst=0
```

Matrix dimensions come from `software/apps/spatz_apps/<app>/script/matmul.json`
via `gen_data.py`; the app must be rebuilt after changing them.
