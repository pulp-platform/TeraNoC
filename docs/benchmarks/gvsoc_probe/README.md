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
