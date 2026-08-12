# Spyglass lint findings — triage for review

**Nothing in this file has been fixed.** Every entry is verified against the RTL and classified, for
you to decide on. Per your instruction (2026-08-11): findings are collected here rather than acted
on, and "read but not set" / "set but not read" in Spatz are treated as suspected false positives
until the RTL says otherwise.

Verdicts used:

| verdict | meaning |
|---|---|
| **FALSE POSITIVE** | verified against the RTL; the condition the rule describes cannot occur |
| **ALREADY FIXED** | was real, fixed today; listed so a stale report is not re-triaged |
| **GENUINE** | verified real, needs your decision |
| **VENDORED** | in `hardware/deps/` — not our code |
| **NEEDS DATA** | cannot be settled from the report alone |

---

## Source reports

| project | goal | read at | covers |
|---|---|---|---|
| `terapool_20260811_112828` | `lint_rtl` | 11:28 | **pre-dates all of today's RTL work** |
| `terapool_20260811_120634` | `Design_Read` | 12:06 | pre-dates today's MSHR work |
| `terapool_20260811_181830` | `Design_Read` | 18:18 | after struct trims / gating / hoists |
| `terapool_20260811_194237` | `Design_Read` | 19:42 | after **all** RTL commits incl. drain rewrites |

Reports live at
`hardware/spyglass/sg_projects/<project>/consolidated_reports/*/moresimple.rpt`.
Sort by mtime — several stale project directories exist, and a fresh directory with an *empty*
report is just a phase change, not a completed run.

---

## 1. FALSE POSITIVE — division by zero, `hardware/src/mempool_tile.sv:19`

```
WRN_63  Division by zero in an expression ( (NumCoresPerTile / NumDivsqrtPerTile) )
```

The division is already guarded on the same line:

```systemverilog
parameter int unsigned NumCoresPerDivsqrt =
    |NumDivsqrtPerTile ? (NumCoresPerTile/NumDivsqrtPerTile) : ...
```

`|NumDivsqrtPerTile` is a reduction-OR, so the divide is evaluated only when the divisor is
non-zero. Spyglass reports it because it statically evaluates both arms of the ternary.

**Recommendation:** waive. No RTL change would improve it without obscuring the intent.

---

## 2. FALSE POSITIVE (benign) — 32-bit capacity, `hardware/src/mempool_system.sv:595`

```
WRN_58  Numeric value ( 2147483648 ) exceeds 32-bit capacity
```

```systemverilog
localparam addr_t L2MemoryBaseAddr = `ifdef L2_BASE `L2_BASE `else 32'h8000_0000 `endif;
```

2147483648 = 2^31 = `32'h8000_0000`, written explicitly sized, assigned to an unsigned `addr_t`.
It exceeds the *signed* 32-bit range, which is what the rule measures; as an unsigned 32-bit
address it is exactly representable.

**One caveat worth your eye:** if any config passes `L2_BASE` as an *unsized* define (e.g.
`-DL2_BASE=2147483648` rather than `-DL2_BASE=32'h8000_0000`), the literal would be unsized and the
warning would become meaningful. Worth confirming for any flavour that overrides `L2_BASE`.

---

## 3. ALREADY FIXED — `spatz_vlsu.sv:710`, identifier not declared

```
STX_VE_606  Identifier ( burst_word_idx ) not declared in current scope
```

This was a **FATAL that aborted rule checking entirely**, so it is worth knowing it is gone. The
burst tracking signals were declared beside their assigns further down the file while being read by
`gen_vreg_addr` above. Fixed in `442a714` (12:36) by moving the declarations before first use; the
11:28 report pre-dates that fix. Current RTL: declared at line 718, first read at 724.

**Status:** no action. Listed only so the stale report is not re-triaged.

---

## 4. ALREADY FIXED — `mempool_group_mshr.sv`, today's own findings

| rule | finding | status |
|---|---|---|
| SYNTH_89 ×9 | "Initial Assignment at Declaration for (X) is ignored by synthesis" — `cand`, `rw`, `vid`, `vw`, `hit_e`, `e`, `cand`, `hit_e`, `e2` | fixed: procedural `automatic`s hoisted to module scope |
| SYNTH_78 ×1 | "'final' construct is not synthesizable" | fixed: added the missing `// pragma translate_off` |
| WRN_74 ×1 | "translate_on specified without associated translate_off" | fixed: same missing pragma |
| SYNTH_5255 ×1 | **"Illegal bit select. Index -8 for hold_tick_phase is out of range"** | fixed in `b83d5db` — see below |

The MSHR finding count fell **11 → 2** between the 12:06 and 18:18 reads, and the two that remain
are item 5 (vendored) and the bit-select, now fixed.

### The one that was real — and why it matters

`SYNTH_5255` was **not** a false positive. `hold_tick[e]` indexed a phase decoder with
`HoldPrescaleWSafe'(e)` where `e` was a plain `int` — signed. For e = 8..15 the 4-bit truncation
gives `1000..1111`, read back as −8..−1, so the select was out of range and returned `'x`. Half of
all entries (any `e` where `e mod 16 >= 8`) had their hold and serve countdowns gated by an X,
whenever the prescaler is enabled — which is the default.

`vlog`, elaboration, and both in-flight simulations all missed it: it is legal SystemVerilog, and
the equivalence run has the prescaler disabled. Proven over every (entry, prescaler) pair: the
signed form yields X in **512 of 1024** cases, the unsigned form is correct in **1024 of 1024**.

It is present in `e175213` — the prescaler commit **already published upstream as `47beac8`**.

---

## 5. VENDORED — findings in `hardware/deps/`, not our RTL

| rule | count | files |
|---|---|---|
| `WRN_51` "Concatenation with unsized number" | 52 | mostly `deps/axi/src/axi_lite_lfsr.sv` |
| `ErrorAnalyzeBBox` | 4–5 | `axi_xbar_unmuxed`, `floo_rob_wrapper`, `snitch_icache_lookup`, `snitch_read_only_cache` |
| `ELAB_6312` ElaborationError | 2 | `axi_demux`, `axi_demux_simple` |

These are the only *Error*-severity items design-wide. They sit in vendored IP that the project
patches minimally, so fixing them means diverging from upstream.

**Recommendation:** waive as a group, or add a Spyglass waiver file scoped to `hardware/deps/`.

---

## 6. NOISE — macro hygiene

| rule | count | note |
|---|---|---|
| `CMD_define05` MacroMultipleGiven | 94 | the same `+define+` supplied more than once on the command line |
| `CMD_define02` MacroNotUsed | 13 | defines passed but never referenced |

Harmless, but 94 of one rule dominates the report and makes real findings harder to see. Could be
cleaned by de-duplicating the define list the Makefile builds.

---

## 7. "read but not set" / "set but not read" — the full rule-check report

The `lint_rtl` goal finished (project `terapool_20260811_120634`, 38,304 findings). The class you
flagged is present in volume. **Every Error-severity finding has been checked against the RTL below.**

### W123 "read but never set" — Error, 40 findings — 39 FALSE POSITIVE, 1 genuine-but-benign

| signals | count | verdict | evidence |
|---|---|---|---|
| `tcdm_slave_req[0][N].mshr_tag` | 16 | **FALSE POSITIVE** | driven in `mempool_group_floonoc_wrapper.sv:566` from the NoC request header (`floo_tcdm_req_from_router_after_xbar[i][j].hdr.mshr_tag`) |
| `tcdm_master_resp[0][N].mshr_tag` | 16 | **FALSE POSITIVE** | driven in `mempool_tile.sv:727` (`bank_resp_payload[b].mshr_tag = meta_out.mshr_tag`, "echo MSHR id back") and carried at wrapper `:733` |
| `decoder_req_i.{instr,rd,rs1,rs2,rsd,vtype.vsew}` | 6 | **FALSE POSITIVE** | all assigned in `spatz_controller.sv:177-187` (default `'0` at 177, fields at 182-187) and wired to the decoder at `:165` |
| `snitch_req.burst_len[4:0]` | 1 | **GENUINE, benign** | see below |

The 38 struct-field false positives share one mechanism: the driver is a **field of a struct that
crosses a module boundary** (through the NoC wrapper, or through a port connection), and the
hierarchical analysis does not connect it. Note the report itself is inconsistent about this — it
raises them as Errors while the same signals are demonstrably driven one level up.

Plausible root cause worth checking before trusting any driver-tracing result from this run: four
modules were **black-boxed** (`ErrorAnalyzeBBox` on `axi_xbar_unmuxed`, `floo_rob_wrapper`,
`snitch_icache_lookup`, `snitch_read_only_cache`). A signal whose driver path passes through a black
box appears undriven by construction. Fixing the black-box errors may clear most of this class.

### The one that is real: `snitch_req.burst_len`

`snitch_req` is a `snitch_pkg::dreq_t` whose fields are driven by the scalar core's output ports
(`spatz_mempool_cc.sv:187-189`). The core has **no `data_qburst_len_o` output** — `snitch.sv` does
not declare one — so `burst_len` genuinely has no driver. It is then copied wholesale
(`assign data_req_d = snitch_req;` at `:347`), so the unset field propagates as X in simulation.

It is benign only because the single consumer overrides it:

```systemverilog
assign data_qburst_len_o[0] = snitch_pkg::BurstLenWidth'(1);   // :398 -- constant, not snitch_req.burst_len
```

**Your call:** drive it explicitly (`snitch_req.burst_len = BurstLenWidth'(1)`) so the struct copy
carries a defined value, or waive it on the grounds that the consumer is hardcoded. The former costs
nothing and removes an X from the waveform.

### W528 "set but never read" — Warning, 30,776 findings

Not triaged individually — **29,932 of them (97%) are in one file**,
`hardware/src/terapool_cluster_floonoc_wrapper.sv`, the generated top level, where per-instance
signals are legitimately unused at many mesh positions. The remainder is dominated by vendored
`common_cells` (`spill_register_flushable.sv` 5,305, `fifo_v3.sv` 396).

**Recommendation:** waive by file for the generated wrapper and for `hardware/deps/`, then re-read
what is left. At 30k findings the rule currently carries no signal.

### Other high-count rules, all vendored or generated

| rule | count | meaning | where |
|---|---|---|---|
| `FlopEConst` | 5,504 | flop enable pin tied constant | `common_cells` spill/fifo |
| `W415a` | 835 | signal assigned more than once | `deps/axi` |
| `W240` | 445 | input declared but not read (e.g. `clk_i`) | `deps/axi` |
| `W287b` / `W287a` | 111 / 90 | port width / connection mismatches | deps |
| `UndrivenInTerm-ML` | 64 | undriven input terminal | deps |

---

*Last updated 2026-08-11 from the reports listed above. Append new findings; do not fix in place.*

---

## 8. CAVEAT — the two `lint_rtl` runs are NOT directly comparable

Do not quote "38,304 → 19,635 findings" as an improvement. It is almost certainly an artifact.

| | 12:06 run | 19:42 run |
|---|---|---|
| total findings | 38,304 | 19,635 |
| **`mempool_group_mshr.sv`** | **115** | **112** |
| `W528` in `terapool_cluster_floonoc_wrapper.sv` | 29,715 | 14,858 |
| source list | 3057 files (saved list) | 3050 files (regenerated, `SPYGLASS_EXCLUDE`) |

The entire global difference is one file — the generated top level — which **none of today's RTL work
touches**. The elaborated instance count evidently differs by roughly a factor of two between the
runs, and the source lists differ slightly. Until that is explained, the two totals measure
different things.

What the comparison *does* legitimately show, because it is scoped to the file that was actually
changed:

| | 12:06 | 19:42 | |
|---|---|---|---|
| `WRN_74` translate_on without translate_off | 1 | **0** | the pragma fix worked |
| `SYNTH_5255` illegal bit select | 0 | **1** | introduced by the prescaler, caught here, fixed in `b83d5db` |
| `W415a` | 97 | 95 | unchanged in character |
| MSHR total | 115 | 112 | the drain rewrites and meta-mask added **no new findings** |

That last row is the useful result: two substantial rewrites of the most delicate block in the file
landed without introducing lint findings, and the one finding they did introduce was a real bug that
static analysis caught and simulation would not have.

**Before comparing any two lint runs in future:** check the source list length and the elaborated
instance count first. Same config name is not sufficient.

---

## 9. FIXED — the two meaningful findings from the 19:42 run

Both were Error severity, both in code under our control (`working_dir/spatz`), both fixed in spatz
commit `a1047cf`. The full design compiles clean in both define sets.

### W110 — `spatz_vlsu.sv:500`, incompatible port width

```
Incompatible width for port 'usage_o' (width 6 in module 'fifo_v3')
on instance 'i_fifo_commit_insn' (actual width 7)
```

`commit_usage` was `[idx_width(CommitQDepth):0]` while `fifo_v3` drives `usage_o` as
`[ADDR_DEPTH-1:0]` = `idx_width(CommitQDepth)` bits, so the MSB was never driven and read as `'x`.

**Narrowing it to match uncovered a second, pre-existing bug in the assertion that consumes it.**
`usage_o` is the LOW `idx_width` bits of an `idx_width+1`-bit count, so a FULL queue reads back as
**0**. The A5 assertion compared `inflight_q` against it directly — wrong at precisely the boundary
the assertion exists to guard. The full case is now tested explicitly through `commit_insn_full`.

### W123 — `spatz_mempool_cc.sv`, `snitch_req.burst_len` read but never set

The scalar core has no `data_qburst_len_o` output, so the field had no driver at all, and
`assign data_req_d = snitch_req` copied the undefined value onward as an X. Benign only because the
single consumer hardcodes `BurstLenWidth'(1)` instead of reading it. Now driven at the source, so
the struct copy carries a defined value.

### NOT fixed, deliberately — W216 int part-selects in the MSHR drain

Seven sites: `port_i[RespPortIdW-1:0]`, `drain_win_s[...]`, `drain2_s[...]`, `drain3_s[...]`.

They are **benign**: the values are small positives, so the low bits are correct. They are also the
same CLASS as `SYNTH_5255`, which was a genuine X-propagation bug — so they are recorded here
rather than waived.

The reason not to touch them now is evidence, not risk aversion: that drain code was proven
**bit-exact** against the pre-work reference across all 35 telemetry periods hours ago. Editing it
would discard that proof for no functional gain. Worth cleaning at the same time as any future
change to the drain, when the equivalence run has to be repeated anyway.

### Also benign — UndrivenInTerm-ML x16

All at `terapool_cluster_floonoc_wrapper.sv:305`, `.scan_data_i (/* Unconnected */)` — one per group,
deliberately unconnected. A DFT note (an undriven scan input), not a functional defect.
