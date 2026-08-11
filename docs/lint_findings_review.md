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

## 7. Awaiting — "read but not set" / "set but not read"

**None have appeared yet** in any report so far. The rules present to date are listed above; the
class you flagged (`W123`/`W415`/`W528`-family, depending on policy) has not been emitted, most
likely because the full rule set has not finished — the in-flight run was at rule ~249 of 302 when
this file was written.

When they do appear the procedure is: open the RTL, establish whether the signal genuinely has no
driver or no reader, and record the verdict here with the evidence rather than changing Spatz.

---

*Last updated 2026-08-11 from the reports listed above. Append new findings; do not fix in place.*
