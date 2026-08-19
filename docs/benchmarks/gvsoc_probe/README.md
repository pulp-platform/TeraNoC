# RTL probe data for gvsoc VLSU calibration

Answers `TeraNoC_gvsoc/docs/rtl_probe_request.md`.

**Absolute path:** `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/docs/benchmarks/gvsoc_probe/`

| file | what it is |
|---|---|
| `README.md` | this file — definitions, method, status |
| `collect_vperf.py` | parses `[VPERF]` lines into fleet means + derived L / N / T |
| `raw/` | unedited QuestaSim transcript excerpts, one file per run |
| `request_A_4x4_256x32x256.md` | Request A+B result (4x4) — *pending* |
| `request_C_8x8_2048x512x512.md` | Request C result (8x8) — *not started, see Status* |

---

## What we changed in the RTL (Request B, the only change you asked for)

One accumulator pair on the existing `[VPERF]` line in `working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv`.
The line now ends:

```
... dual_adv=%0d blk_stall=%0d infl_sum=%0d act_cyc=%0d
```

* `infl_sum` — running sum of `inflight_q`, accumulated every cycle of the benchmark window
* `act_cyc` — count of cycles where the VLSU had work (`inflight_q != 0`, or `commit_insn_valid`
  when `dual_load=1`, since `inflight_q` only exists under runahead)

Nothing else in the RTL was touched for this. The counters are sim-only and gated by the same
`csr_trace_any_global` window as the existing ones.

## Definitions — please read before comparing

Your §4 warns that mismatched definitions are the likeliest failure. We therefore report N under
**both** denominators rather than picking one:

| quantity | formula | note |
|---|---|---|
| `N_window` | `infl_sum / win` | averaged over the whole benchmark window |
| **`N_active`** | `infl_sum / act_cyc` | averaged over cycles the VLSU has work — **your definition** |
| **`L`** | `infl_sum / insn_ret` | load latency |
| `X` | `insn_ret / win` | retire throughput |
| `T` | `L / N_active` | issue interval |

**`L` needs no extra state.** `insn_ret` already counts `commit_insn_pop`, which is exactly your
stated definition of retire (admission → `commit_insn_pop`). Little's law `L = N / X` then reduces
to `infl_sum / insn_ret`. So you get L *measured on our side* too, not derived from
`vlsu_burst_bandwidth.md` — which means the L comparison stops being doc-vs-model and becomes
measurement-vs-measurement.

**One caveat on `wait_beats`**, from the comment above the counter block: it is VLSU **occupancy**,
not critical-path exposure — it overlaps VFU compute. Do not treat it as pure lost latency when
you build the matching partition. The cycle-accounting identity the RTL authors verified is
`win = pair_commit + wait_beats + no_insn + store/residual + vrf_bp`.

## Disclosure: unrelated sim-only edits present in this tree

This tree currently also carries two **`pragma translate_off` / `ifndef TARGET_SYNTHESIS`** probes
added for an unrelated fp16 investigation:

* a `[VLSU OVERSHOOT]` detector next to `commit_finished_q` in `spatz_vlsu.sv`
* `+tracer_all` and a periodic `$fflush` in `tb/tb_noc_req_resp_tracer.svh`

Neither changes VLSU timing or the VPERF counters. Flagged so an unexplained delta is never
attributed to them silently.

## Status

* **Request A + B (4x4, 256x32x256)** — in progress.
* **Request C (8x8, 2048x512x512)** — not started. It requires a mesh switch, which rewrites the
  shared `hardware/generated/*.sv` (those files are mesh-specific and shared by every build dir),
  so it cannot overlap 4x4 work; plus ~4 h elaboration and a 169,073-cycle run. It is queued
  behind the current 4x4 experiments.
* **Request D (MSHR entry lifetime)** — not started; needs new probes in
  `mempool_group_mshr.sv`. Only meaningful alongside Request C.

---

## Request D — MSHR entry lifetime (`[MSHRLIFE]`)

Added 2026-08-19 at the GVSOC side's request, after their 8x8 split showed the mesh-scaling term is
almost entirely the memory round trip: L grows 129.3 → 180.3 from 4x4 to 8x8, **flight accounts for
+52.3 of the +51**, and commit actually *improves* (49.1 → 42.5).

Probe: `hardware/src/mempool_group_mshr.sv`, block `gen_mshr_lifetime`, immediately before
`endmodule`. Sim-only (`ifndef VERILATOR` / `ifndef TARGET_SYNTHESIS` + `pragma translate_off`), so
it cannot affect timing or the netlist.

### ⚠️ Span boundary definitions — check these against yours BEFORE comparing numbers

All three spans are cut at **registered** boundaries and are **disjoint by construction**, so
`hold + flight + drain == entry lifetime` rather than being three independently-defined numbers
that merely get compared:

| span | starts at | ends at |
|---|---|---|
| `hold` | entry allocated — `mshr_q_valid[e]` rises | request issued — `mshr_q[e].issued` rises |
| `flight` | request issued | **first** response beat captured — `\|mshr_rb_we[e]` |
| `drain` | first response beat captured | entry freed — `mshr_q_valid[e]` falls |

`life` is stamped **independently** (alloc → free) so the sum can be *checked* against it rather
than assumed. A mismatch means some entries took a path these spans miss — e.g. freed before any
beat arrived, or a `MSHR_CACHED` revisit. Entries freed without ever capturing a beat are counted
separately as `freed_without_beat` and are **excluded from `drain_n`**, so `drain_sum/drain_n` is
not diluted by them.

This matters because the GVSOC-side MSHR numbers at 8x8 are hold 15 / flight 28 / drain 9 (≈52)
against a VLSU-observed flight of 132.6 — an ~80-cycle unexplained remainder. **A boundary
disagreement produces a gap of exactly that size**, so definitions must be reconciled before the
remainder is treated as real physics.

### ⚠️ Split by burst length — a pooled drain mean is not comparable

The MSHR allocates entries for **single-word** requests (`burst_len==1`) as well as bursts. Those
drain in a couple of cycles, so a pooled drain mean is dragged far below the per-burst-entry
number another model would report for a 16-beat entry. Comparing a pooled mean against a
per-burst number looks arithmetically fine and is wrong by a large factor.

So a second line is emitted:

```
[MSHRLIFE-BL] <hier> drain_single_n= drain_single_sum= drain_burst_n= drain_burst_sum= burst_beats_sum=
```

  * drain per burst entry = `drain_burst_sum / drain_burst_n`
  * cycles per beat       = `drain_burst_sum / burst_beats_sum`

`burst_beats_sum` accumulates each entry's **actually captured** `burst_len`, not an assumed
`MaxBurstWords` — an entry that allocated as a burst but completed short would otherwise silently
inflate the per-beat rate.

### ⚠️ `drain` is not pure beat delivery

The span is *first beat captured → entry freed*, and this MSHR is a **coalescer**: an entry stays
alive while it serves every merged subscriber, not merely while beats arrive. An entry serving
several merge partners therefore legitimately outlives `beats / 2-per-cycle`. Do not treat
`16 beats / 2 per cycle = 8 cycles` as the RTL expectation and difference against it.

### Beat arrival spacing — `[MSHRLIFE-BEATS]`

Added at the GVSOC side's request after they localised their 1-beat/cycle limit to the *response
path*, not the MSHR: their beat-rate counters read 4.80 beats/cyc into the MSHR and 10.79 out of it
(OUT above IN is multicast working), while only 1.00 reaches the VLSU per core. So the binding
constraint is how fast the 16 beats of ONE burst come back from the target group.

```
[MSHRLIFE-BEATS] <hier> entries= first_to_last_sum= beats_captured_sum=
```
  * mean first-to-last beat span   = `first_to_last_sum / entries`
  * mean beats per entry           = `beats_captured_sum / entries`
  * beats per cycle within an entry = `(beats_captured_sum - entries) / first_to_last_sum`

Three choices that each avoid a real bias:

  * **Beats are counted with `$countones(mshr_rb_we[e])`, not one per cycle.** With
    `DrainBeats=2` a cycle can capture two; counting cycles would understate the arrival rate by
    up to 2x — the same size as the effect being measured.
  * **first-to-LAST is deliberately distinct from `drain`.** `drain` is first-beat → entry-freed
    and a coalescer outlives its beats while serving merge partners. first-to-last excludes
    subscriber service, so it measures the response path alone.
  * **Entries with a single captured beat are excluded** — they trivially span 0 cycles and would
    pull the rate toward "infinitely fast".

⚠️ **Compare rates, not spans, if the beat counts differ.** This MSHR has a response cache, so an
entry can be satisfied partly from a cache hit rather than from a full set of fresh NoC beats. If
`beats_captured / entries` lands well below `burst_len`, the spans are measuring different amounts
of work and only beats-per-cycle is comparable.

### Output

One line per group MSHR instance at `final`:

```
[MSHRLIFE] <hier> MshrNum=N hold_n=.. hold_sum=.. flight_n=.. flight_sum=..
           drain_n=.. drain_sum=.. life_n=.. life_sum=.. freed_without_beat=..
```

Means are `*_sum / *_n`. Sums are 64-bit. Accumulation is staged into blocking locals and committed
with **one** nonblocking assignment per counter — several entries can hit the same boundary in one
cycle, and per-entry NBA updates to a shared accumulator would be silently lost to last-write-wins
(the same reason the existing `gen_stats` block stages its increments).

### ⚠️ PIN THE KNOBS — a bare `make` silently uses different ones

`scripts/gemm_autotune.py` sets per-shape MSHR knobs via `extra_vlog_defs`; the `config/*.mk`
file defaults are **different**. Launching a comparison run with a bare `make` therefore builds a
*different machine* from the tuned run you are comparing against, with nothing to indicate it.

That happened here: the first Request D build differed from the delivered A+B build in **five**
defines, including the ones that directly set how long an entry is held:

| define | A+B (tuned, 256x32x256) | bare `make` default |
|---|---|---|
| `GROUP_MSHR_HOLD_SUBS_SINGLE` | **8** | 4 |
| `GROUP_MSHR_HOLD_SUBS_BURST` | **2** | 4 |
| `GROUP_MSHR_MERGE_REQS` | **8** | 4 |
| `GROUP_MSHR_BANK_SHIFT_SINGLE` | **5** | 9 |
| `GROUP_MSHR_BANK_SHIFT_BURST` | **5** | 7 |

Replicate the reference run's defines verbatim and **diff the FULL set**, not a hand-picked
subset:

```bash
DEFS=$(grep -aoE '\+define\+GROUP_MSHR[A-Z_0-9]*=[0-9]+' build_<ref>/compile.tcl \
       | sed 's/+define+/-D/' | sort -u | tr '\n' ' ')
make ... buildpath=build_new extra_vlog_defs="$DEFS"
# then, SAME pattern on both sides or the diff is meaningless:
for d in build_<ref> build_new; do
  grep -aoE '\+define\+[A-Z_0-9]+=[0-9]+' $d/compile.tcl | sed 's/+define+//' | sort -u > /tmp/$d.defs
done
diff /tmp/build_<ref>.defs /tmp/build_new.defs   # must be empty
```

### Run

`build_mshrlife3`, config `terapool_spatz4_fpu` (4x4), preloading `hardware/matmul_gvsoc_probe.elf`
— **the same ELF and shape (256x32x256) as the Request A+B `[VPERF]` run**, so the two datasets are
directly comparable rather than being from different workloads.

### Caveat carried over from Request A+B

`wait_beats` in `[VPERF]` is VLSU **occupancy**, not critical-path exposure — it overlaps VFU
compute. The verified cycle identity is
`win = pair_commit + wait_beats + no_insn + store/residual + vrf_bp`, which is a **cycle-accounting**
identity, not a latency decomposition. Do not sum it into an L breakdown.
