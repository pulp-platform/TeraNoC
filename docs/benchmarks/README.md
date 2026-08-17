# Benchmark documentation

Performance measurements of TeraNoC-Spatz on GEMM (`sp-fmatmul`), the tooling used
to produce them, and the bottleneck analysis behind them.

Design documents live one level up in `docs/`; this folder is **measurements and
the infrastructure that produces them**.

---

## The documents

| document | what it is |
|---|---|
| **[`gemm_shape_status.md`](gemm_shape_status.md)** | **Where everything stands right now.** All 23 shapes × every phase in one table, with `current` (the default build) separated from `best` (which for most shapes sits on a superseded phase). Generated — `python3 scripts/gen_shape_status.py`. |
| **[`gemm_results.md`](gemm_results.md)** | The single source of truth for GEMM performance: all 29 shapes vs. the baseline, the tuning rules, and every finding. Predates the PPA campaign — for today's numbers read `gemm_shape_status.md` first. |
| [`gemm_results_burst_bypass.md`](gemm_results_burst_bypass.md) | `hold_subs_burst = 1` on the `share_b = 1` family. The largest win in the campaign (up to −44.7%, 96.3% of roofline) and the explanation for three of the four runtime-CSR outliers. |
| [`gemm_results_default_latest.md`](gemm_results_default_latest.md) | **First-ever measurement of the shipping default** (`group_mshr_hold_prescale_w=4` — every prior arm pinned 0). `dflt` = defaults with the runtime CSR off; `latest` = with it on. Generated — `python3 /tmp/claude-620771/gen_dflt_latest_doc.py`. |
| [`gemm_results_table.txt`](gemm_results_table.txt) | The same table as plain text, for diffing and quoting. |
| [`verilator_simulation.md`](verilator_simulation.md) | How to build and run these benchmarks fast. |
| [`matmul_bottleneck_report.md`](matmul_bottleneck_report.md) | Microarchitectural analysis of where matmul cycles go — the motivation for the design work in `docs/`. |
| **PPA sweeps** — the three `gemm_results_mshr_ppa*.md` files | Re-measurements of the same shapes on the post-PPA RTL. See below. |

---

## How the four result files relate

`gemm_results.md` is the **reference**, measured 2026-08-03 on pre-PPA RTL. The three
`gemm_results_mshr_ppa*.md` files re-measure **the same 23 shapes with the same kernel,
the same ELFs and the same `ideal = M·N·P / 1024` definition**, so every table is
directly comparable, cell for cell.

They form a **chain, one knob apart at each link** — which is the point. Each file's
delta against the one above it isolates a single change:

| # | file | RTL base | `drain_from_q`<br>(opt2) | `bank_publish`<br>(opt3) | `spill_req_in`<br>(C2) | hold window |
|---|---|---|:--:|:--:|:--:|---|
| 0 | `gemm_results.md` | pre-PPA | 0 | 0 | 1 | 255 |
| 1 | `gemm_results_mshr_ppa.md` | `8ca4f060` | **1** | 0 | 1 | **2047**\* |
| 2 | `gemm_results_mshr_ppa_opt3.md` | `1d5a5756` | 1 | **1** | 1 | 2047\* |
| 3 | `gemm_results_mshr_ppa_c2.md` | + B1b, C3, C2 | 1 | 1 | **0** | 2047\* |

\* except four shapes whose flavour pins `hold_window_burst := 0` — see any of the three
files for why (B shared 1-way makes the early-release condition unreachable).

**Which delta answers which question:**

- **0 → 1** — the verified-inert RTL work (A1–A5, B0.3, B1, B2, B3) plus opt2 plus the
  hold-window change, all at once. Says where the tree stands; **attributes nothing**,
  because three things moved together.
- **1 → 2** — **opt3 alone.** The two sets differ only in `bank_publish`.
- **2 → 3** — **C2 alone.** The two sets differ only in `spill_req_in`.

Read the CONFOUND section in files 2 and 3 before quoting either pairwise delta: each set
was built from a later commit than the one above it, and those commits are only
*claimed* bit-identical until their equivalence runs land.

### Phase files (E1 onward)

From Phase E the campaign continues the same way, one file per phase, each measured against the
phase before it:

| file | phase | measured against |
|---|---|---|
| `gemm_results_mshr_ppa_e1.md` | commit-FIFO depth + ROB counter (config only) | `sweepC2` |
| `gemm_results_mshr_ppa_e2.md` | MSHR cleanups | `phaseE1` |
| `gemm_results_mshr_ppa_e3.md` | VLSU stride multipliers | `phaseE2` |

These are produced by **one** generator, `scripts/gen_sweep_doc_phase.py <tag> <base> <out> <title>
<changed>`, and **one** sweep runner, `sweep_generic.sh <tag> "<knobs>"` — not by copying. The three
original generators were hand-copied, drifted apart, and when the `serve_timeout` bundling bug was
found each copy had to be patched separately (one needed a different anchor because its wording had
diverged). One copy each from here on.

Each phase's own file records the **compiled define set read back from that arm's build log**, not
the launcher's intent — the distinction that caught three invalid runs on 2026-08-14.

**Why the chain instead of one table.** Bundled deltas are unattributable, and this
campaign has already been bitten by that — the hold-window change was 255 → 2047 at the
same moment as nine RTL commits, and 2047 was later measured at **+725%** on
`1024x128x128`. One knob per link is what makes a regression traceable to its cause.

**opt2 and opt3 are on by default** and are not optional: the `drain_from_q=0` path does
not close timing. So files 2 and 3 describe the shipping configuration; file 1 is a
diagnostic baseline, not a config anyone should build.

**Bit-identity.** A1–A5, B0.3, B1, B2, B3, C1 and C3 were each verified to reproduce
34,715 cycles exactly on `256x512x256` — they are pure area/timing rewrites. **C2 is the
exception**: it removes a pipeline stage, so its sweep is a measurement, not an
equivalence check.

Each PPA file is generated, not hand-written — `python3 scripts/gen_sweep_doc.py`,
`gen_sweep_doc_opt3.py`, `gen_sweep_doc_c2.py`. Re-run any of them to refresh as arms
complete; do not edit the `.md` in place.

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

## `gemm_results_bankpub_window_2x2.md` — the `bank_publish` × `hold_window_single` factorial

Not part of the chain: four builds of **one** shape (`128x1024x512`), differing in two knobs. It
exists to answer the opt3 bisect that `mshr_ppa_plan.md` called for. Result: the collapse needs
**both** `bank_publish=1` and `hold_window_single=0` — either knob alone escapes it, and the two are
strongly sub-additive, so they are two routes out of one pathology rather than two wins. The shipping
default is the corner that has both.

## `gemm_results_mshr_ppa_csr.md` — runtime-configurable MSHR

Chain position: `phaseE1` + `group_mshr_cfg_runtime=1`. Read its "How to read the per-shape deltas"
section before quoting anything from it: the per-shape scatter is alignment jitter, the mean is
unstable until the sweep completes, and four B-share=1 arms plus two collapsed arms need separate
treatment. Verification record: `../mshr_runtime_csr_verification.md`.

## `gemm_results_8x8_1024core.md` — the 8×8 / 1024-core campaign

**Not part of the 4×4 chain and not comparable to it**: different mesh, core count, lane count and
shape (2048×512×512 on 64 groups). Recovered from the published artifact after the build directories
were reclaimed, so it is the durable record of that campaign. Carries the determinism result (renamed
configs complete at byte-identical cycle counts, so there is no noise floor), the 14.1% barrier-fix
figure, and the retraction of the utilisation-versus-throughput correlation.
