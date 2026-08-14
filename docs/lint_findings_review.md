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

# 2026-08-14 run — the MSHR PPA series (28 commits, `87e9446c`..`f7a7e90f`)

`terapool_20260814_173616`, goals `Design_Read` + `lint_rtl`, run against the `zexin/mshr_ppa`
worktree. `sg_shell` exited cleanly, **no `RULE CHECKING ABORTED`** — the tb-exclusion filter
(`Makefile:797`) worked, so rules genuinely ran on 3,130 source files.

## Verdict: clean for the handoff

| | |
|---|---|
| Errors anywhere in the design | **9** — all in Spatz / snitch / vendored (`spatz_decoder.sv` ×6, `type.v`, `spatz_mempool_cc.sv`, `snitch_icache_lookup_serial.sv`) |
| Errors in `mempool_group_mshr.sv` | **0** |
| Warnings in `mempool_group_mshr.sv` | 123, all triaged below |

**No finding in the 28 commits is a defect.** Each was verified against the RTL, not accepted from
the rule text — per the standing rule that Spyglass read-not-set / set-not-read are known-false in
this tree.

| rule | n | verdict | basis |
|---|---:|---|---|
| `W415a` multiple assignment in one `always_comb` | 105 | **FALSE POSITIVE** | default-then-override is the idiom the whole file is built on; last-wins is defined SV semantics, not a race |
| `W362` width mismatch in `<` | 5 | **FALSE POSITIVE** | arithmetic checked — see below |
| `W216` range select on a loop variable | 5 | **benign** | `port_i[RespPortIdW-1:0]` inside `for` loops (`:3668,3679,3761,3907,3936`) |
| `W528` set but not read | 5 | **FALSE POSITIVE** ×2 verified | see below |
| `W240` input declared but not read | 3 | **pre-existing** | `testmode_i` `:83`, `scan_enable_i` `:85`, `group_id_i` `:89` — tie-offs |

### `W528` on `merge_same_mask` — C1's signal, and it is live

Written `:2917`/`:2923`, **read at `:2927`** by `SubReqCountW'($countones(merge_same_mask))`, which
*is* C1's parallel merge rank. Spyglass does not see a read through a system function. C1 is not
dead code.

### `W528` on `victim_rr_d`

Written `:2883`/`:3065`, consumed at `:2102` through the `` `FF `` macro into `victim_rr_q`. The rule
does not expand macros. Standard pattern throughout this file.

### `W362` — needed real arithmetic, and it is clean

Flags `(meta_id - meta_id_base) < burst_len` at `:1579`, `:1593`, `:3279` as "left 6 bits, right 5".

`MetaIdWidth = 6` (from `snitch_pkg`) and `BurstLenWidth = $clog2(MaxBurstWords+1) = $clog2(17) = 5`.
So the subtraction evaluates at **6 bits — exactly the meta-id space** — which is what makes the
wraparound in the modular range test correct, and the 5-bit `burst_len` (max 31) zero-extends
safely into 6. Benign.

Worth noting for future edits: B2's *new* test at `:1689` writes the same idiom with an explicit
`meta_id_t'` cast, so it is correct by construction regardless of context widening. The three sites
above are **pre-existing** and happen to be correct without it. Adding the cast there would be
uniformity, not a fix — there is no bug to repair.

### Not fixed, deliberately: 6 unguarded sim-only constructs

`$error` `:2004`, four `assert property` `:2064-2096`, `$fatal` `:4853` sit outside any
`translate_off`. DC and Genus ignore concurrent assertions and `initial` blocks, so these are not
synthesis hazards. Left alone rather than churn RTL that is mid-verification; worth wrapping when
the file is next touched.

### Stats containment (backend item D2/D3) — checked, no leak

The stats logic is guarded three ways — `pragma translate_off`, `EnableStats`, and
`` `ifndef VERILATOR`` — and all **8** stats `always_ff` blocks sit inside `translate_off`.
`config/terapool_spatz4_fpu_backend_4x4.mk` now also pins `group_mshr_enable_stats := 0`. Still
confirm after elaboration with `sizeof_collection [get_cells -hier *stat_*]`; non-zero means the
guard leaked, which this file's history records happening once.

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

### W123 "read but never set" — Error, 40 findings — 6 FALSE POSITIVE, 34 genuine (33 benign)

> **Corrected 2026-08-12.** The two `mshr_tag` rows were previously marked FALSE POSITIVE here.
> That verdict was wrong — both cited a real driver of a **different array index**. The group's
> remote ports are declared `[NumRemote*PortsPerTile-1:1]` while the internal arrays are `[N-1:0]`,
> and the port→array loops start at `r = 1`, so index `[0]` — the local intra-group path, driven
> field-by-field at `mempool_group.sv:314-330` — never receives `mshr_tag` from anywhere.
> Wrapper `:566` drives `tcdm_slave_req_i`, which lands on ports **1+**; `mempool_tile.sv:727`
> drives `bank_resp_payload[b].mshr_tag`, a different signal.
>
> **Benign** because port `[0]` never reaches the MSHR (its connection loops also start at `r = 1`),
> so the `mshr_tag == '0` qualifiers never see it, and the tile ties its own outbound local tag to
> zero (`mempool_tile.sv:1201,1207`). **FIXED 2026-08-12** in `5ca5c22` with two tie-offs; the
> 4×4 re-lint reports 0 (see §12).

| signals | count | verdict | evidence |
|---|---|---|---|
| `tcdm_slave_req[0][N].mshr_tag` | 16 | **GENUINE, benign — fixed** | port `[0]` is the LOCAL path; see the note above |
| `tcdm_master_resp[0][N].mshr_tag` | 16 | **GENUINE, benign — fixed** | port `[0]` is the LOCAL path; see the note above |
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

### Follow-up: the W110 fix was proven, and the OLD assertion had a false-negative hole

The rewritten A5 assertion changes a `$fatal` condition, so it carries its own risk: if the new
condition is wrong it fires spuriously. Modelled fifo_v3's semantics standalone and swept every
(occupancy, inflight) state:

    585 states checked
      NEW form  0 mismatches -- encodes exactly "inflight_q == FIFO occupancy"
      OLD form  1 mismatch   -- cnt=64 (FULL), infl=0: wanted FALSE, returned TRUE

So the rewrite cannot spuriously fatal. More importantly the OLD form had a **false negative**: with
the queue full and inflight 0, `usage_o` truncates to 0 and the comparison returned TRUE, so the
assertion silently passed on precisely the divergence it exists to detect. A `$fatal` that does not
fire when it should is worse than one that fires when it should not.

The width fix therefore did more than clear W110 -- it restored the assertion's coverage at the
boundary it guards.

STILL UNSIMULATED (both spatz fixes): the equivalence run predates them by 5.5 hours. It reruns when
the 8x8 lint releases the 4x4 mesh. `snitch_req.burst_len` is the lower-risk of the two (X -> 1,
and the consumer hardcodes 1) but it does reach data_req_q.burst_len via the struct copy.

---

## 10. NEEDS A DECISION — inferred latch in the VLSU burst path

```
SYNTH_12608  spatz_vlsu.sv:1081
  The logic of the always block mismatches with the type of Always Block
  (which should be "always_latch") due to latch instance \burst_mode_req_reg[1]
```

`burst_mode_req_reg[1]` is the ELABORATED latch instance name for `burst_mode_req[1]`
(declared at `spatz_vlsu.sv:676`). Verified against the RTL:

```systemverilog
always_comb begin                                   // 1081-1204, per memory port
  if (mem_use_port0_burst && (port != 0)) begin     // 1083-1098
    // assigns 12 signals: mem_max_elements, mem_remaining_*, burst_len_calc,
    // burst_use, mem_operation_valid/last, mem_counter_*
    // ^ burst_mode_req[port] is NEVER assigned on this path
  end else begin
    burst_mode_req[port] = ...                      // 1146
  end
end
```

So whenever port-0 burst mode is active, `burst_mode_req[1]` retains its previous value rather than
being driven, and synthesis infers a latch. **Present in both the 4x4 and 8x8 reports** — it is not
configuration-specific (an earlier note calling it 8x8-only was wrong; it was inferred from a
top-10 histogram that did not reach it).

**Why it is more than lint hygiene.** `burst_mode_req[port]` is READ at line 1664 in the
burst-completion path (`!burst_mode_req[port] || !burst_use[port]`). A latched value there lets
port-1 burst state persist across a mode switch, and this is the same code with a recorded history
of burst deadlocks and the burst+tail-store hang.

**NOT fixed, deliberately.** The obvious repair is `burst_mode_req[port] = 1'b0;` in that branch,
alongside the `burst_use[port] = 1'b0;` already there. But unlike the width/driver fixes, this
CHANGES BEHAVIOUR: it replaces a held value with a defined one, which could equally repair a latent
bug or perturb burst sequencing. In an area with this history it deserves its own equivalence run
rather than being folded into a batch.

Recommended sequence if you want it: apply the one-line assignment, then run the 4x4 tuned
equivalence config with the prescaler disabled and require the usual bit-exact match over all 35
periods. If it is NOT bit-exact, that is itself the interesting result -- it would mean the latch
was affecting behaviour, and the diff would show where.

---

## 11. THE 8×8 RUN — `terapool_20260812_015943`, finished 2026-08-12 10:23

*(Reconstructed 2026-08-13 from the session record after the working copy was destroyed.)*

Ran on the real 8×8 mesh (guard confirmed `mesh 8x8, 65 routers, 64 groups`), post-fix RTL.
**Completed cleanly — no abort, no fatal, not OOM-killed**, despite peaking at 593 GB RSS during
design flattening (1.34 billion instances).

```
Reported Messages:   0 Fatals,   48 Errors,  38086 Warnings,   9 Infos
```

| count | rule | file | verdict |
|---|---|---|---|
| 32 | W123 | `hardware/src/mempool_group.sv` | genuine, benign — `mshr_tag` on local port `[0]` (§7) |
| 6 | W123 | `spatz_decoder.sv` | false positive — driven in `spatz_controller.sv:177-187` |
| 1 | W123 | `spatz_mempool_cc.sv` | false positive *now* — fix is in the analysed source, see below |
| 1 | InferLatch | `spatz_vlsu.sv` | §10 |
| 1 | SYNTH_5273 | `deps/tech_cells_generic/tc_sram.sv` | vendored |
| 4 | ErrorAnalyzeBBox | vendored black boxes | vendored |
| 2 | ELAB_6312 | `deps/axi/axi_demux{,_simple}.sv` | vendored |

**`mempool_group_mshr.sv`: 0 Errors.** The backend cleanup holds at 4× the mesh size.

### The `snitch_req.burst_len` fix is in the source but the finding persists

- the driver is present — `spatz_mempool_cc.sv:348`
- the analysed file is the right one — `working_dir/spatz/...` (the Bender.local override, not the
  stale `hardware/deps/spatz` copy), mtime **01:58:45**
- Spyglass read it **after** the fix — `Design_Read/spyglass.log` timestamped **04:53**

Likely mechanism: `snitch_req` has its other fields driven by module **output-port connections**
(`:187-192`) while `burst_len` is driven by a **continuous assign**, and the rule appears not to
merge those two driver kinds across one struct. Recorded as a tool limitation — but *unexplained*,
not *understood*, so a recurrence is expected rather than a regression.

---

## 12. VERIFICATION OF THE TWO FIXES — 4×4 lint `terapool_20260812_141427`

Both fixes applied and committed (`5ca5c22` main, `f427541` spatz — **two separate git repos**, the
latter being the `Bender.local` override). Re-linted at 4×4 on the fixed tree, 14:14 → 16:18:

```
[4x4] mshr_tag W123 (was 32): 0        <- fix 1 cleared
[4x4] burst_mode_req latch  : 0        <- fix 2 cleared
Reported Messages:  0 Fatals,  15 Errors,  19559 Warnings,  9 Infos
```

**Errors 48 → 15.** Every survivor is pre-existing and outside `hardware/src/`; one of the 15 is
not a defect at all but a cross-reference line pointing at `SignalUsageReport.rpt`, which is why
Spyglass reports 15 while a path-based grep counts 14.

**Nothing in `hardware/src/` is at Error severity any more.**

Two limits on how far to read this:
- 4×4 and 8×8 counts are **not** directly comparable; the Warnings drop 38,086 → 19,559 is mostly
  the smaller mesh, not the fixes.
- **The behavioural equivalence originally claimed here has been WITHDRAWN.** Both builds used for
  it predate the two fix commits, so they compared two pre-fix builds. Neither fix has yet been
  simulated in a build that contains it — see the WORKLOG entry of 2026-08-13 03:30.
