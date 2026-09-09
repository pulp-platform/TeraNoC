---
name: rtl-ppa
description: "Timing/area/power improvement of SystemVerilog RTL against a real backend flow — how to read synthesis reports without fooling yourself, the restructurings that actually buy logic levels, how to add a pipeline stage without destroying throughput, the verification traps that make PPA bugs silent, and the comment/coding style that keeps a hot module reviewable. Use when optimising RTL for frequency or area, when planning a pipeline cut, when doing a comment or style pass on RTL, or when reviewing someone else's PPA change."
---

# RTL PPA improvement

Hard-won from two campaigns in TSMC N7: pushing a 4,000-line MSHR from 500 MHz toward 800 MHz, and
closing an L1D insitu-cache controller at 1 GHz (post-placement WNS -0.260 -> -0.091 ns, TNS 122x,
1901 -> 28 violating endpoints, logic area -3.4%, from 12 shipped transforms out of 15 tried). Every
rule here cost something to learn. The measurements are from those designs; the reasoning transfers.

## 0. The one-line summary

**Measure the population, not the tail, and score every transform at the ENDPOINT -- a change that
improves the segment it targets can still make the design slower. Restructure so the tool can see
parallelism that already exists. A pipeline stage costs latency, never throughput. And assume every
"these two things can't happen in the same cycle" comment in the file is about to become false.**

---

## 1. Reading synthesis reports without fooling yourself

**Read live iteration lines, not stage summaries.** In Fusion Compiler the
`Compile-fusion optimization Phase N Iter M` lines carry current values; the `Compile-fusion  `
stage-summary rows LAG, sometimes by 5x. Reporting a stale row is the easiest way to be confidently
wrong.

**Which stage to trust:** `initial_opto` (post-placement) is the honest timing reading. `logic_opto`
is pre-placement and untrustworthy — one design read −14.08 ns there and +0.003 after placement.
`final_opto` trades timing for DRC and will look *worse* on TNS while fixing tens of thousands of
DRC nets. Compare like with like.

**A plateau is not a floor.** One run held SETUP flat at 13,729.71 for **30 consecutive iterations**
across a phase boundary, then dropped 85% at the next phase. Another held 18,969 for 20 iterations
then halved. The optimiser recomputes the cost only at certain points. Never call a run stalled from
flatness alone — wait for it to exit, or for a comparable run to show the same shape breaking.

**What a real structural limit looks like:** the design buys AREA and gets no timing. Converged:
timing met and area *falling* (117,622 µm² after closure). Genuinely stuck: still missing by 0.65 ns
with area *up* 33%. Use that contrast, not iteration count.

**Closing timing properly makes the block SMALLER -- and area is a free cross-check.** The
"stuck" signature above (area up, timing flat) has a positive twin. When restructuring genuinely
removes levels, the optimiser stops paying area and leakage to compensate for your RTL:

| | baseline | after 12 transforms |
|---|---|---|
| logic-only area | 21 974 um2 | **21 235 um2 (-3.36%)** |
| buf/inv count | 11 467 | **10 105 (-11.9%)** |
| buf/inv area | 915 um2 | **704 um2 (-23.1%)** |
| ULVT cells | 44 162 | **40 898 (-7.4%)** |
| ULVT registers | 640 | **266 (-58%)** |

Compare **logic-only area** (total minus macros), not total cell area: macro area is constant and
dilutes the delta to nothing (-1.13% here). The ULVT drop is also a **leakage** win -- ULVT is the
leakiest flavour and the tool reaches for it under timing pressure.

Then use it as evidence: **logic area tracked WNS almost monotonically across the whole ladder**,
the worst-timing arm also being the largest. That is an *independent* corroboration that a timing
ordering is real rather than placement noise -- two different measurements agreeing for the same
underlying reason. Cheap to extract, and it is the answer to "what did this cost in area?" before
anyone asks.

**Endpoint names say where a path ENDS, never where it starts.** This cost a whole wrong plan.
14,614 violating endpoints were classified by name; the `resp_buf.*` family was assumed to be
response-fed and a second pipeline cut was planned for it. It was **request**-fed, through a store
byte-merge, and one cut covered everything.

**`critical_paths.rpt` is the worst TAIL, not the population.** It holds ~20 paths. Twenty-of-twenty
sharing a startpoint proves nothing about 14,614 endpoints. Get the real distribution:

```tcl
report_timing -delay_type max -max_paths 3000 -nworst 1 -slack_lesser_than 0.0 \
              -path_type short -nosplit
```

then cross-tabulate startpoint against endpoint family. In that design the answer was **98.3% of
paths start at one input port** — which made the plan simpler, cheaper and correct.

**Segment the worst path by hierarchy** to find where a cut belongs. Parse the cell-by-cell report
into `(module, cumulative arrival, cell count)` and look for a balanced split point:

```
input port + external delay   0.309
i_req_decode                  0.071   4 cells
top: decode -> arbiter        0.449  38 cells
i_alloc_arb                   0.127   9 cells
top: arbiter -> clock gate    0.586  49 cells      <- cut at the arbiter: 0.647 / 0.586
```

**Score a transform at the ENDPOINT, never at the segment it targets.** The most expensive
lesson of a second campaign. A transform hoisted a late grant out of an FSM so it landed on one
final gate. Measured at the segment it aimed at, it worked: grant->ready went **0.082 -> 0.058 ns**.
Measured at the endpoint it made the design **worse**: WNS -0.091 -> -0.104. Removing a gate from
the grant path inserted one into *every other* path through that signal, and one of those was the
real critical path. Judged locally it was a clear win and would have shipped.

The corollary is a cost you must be willing to pay: **it justifies a full backend run per variant.**
Path reports answer "did my segment get faster", which is not the question. Of fifteen transforms in
that campaign, **three were rejected this way** -- all three improved their own segment.

**Watch for OOC modelling artifacts.** A standalone block gets `set_input_delay` (0.300 ns of a
1.2 ns budget = 26%) where the real driver is an adjacent module's flop. Before "fixing" an input
path, check the instantiation site — the register may already be there. Ours was, one level up in
`mempool_tile.sv`, so an extra input stage would have bought nothing and cost a cycle.

### Build a fast instrument, then validate it against the real thing

A full-chip run is too slow to test fifteen RTL variants. Build an **out-of-context harness around
the block plus its macros** -- for one L1D cache slice that meant 1 controller + 16 SRAMs, with all
boundary ports registered, ~50 min per run instead of hours.

**An OOC number nobody cross-checked is worthless.** Validate before you trust it: that rig
reproduced the full-group WNS to **~20 ps** (OOC -0.260 vs group -0.24, the group report carrying
only 2 dp) and reproduced the same critical endpoint family. Do this once, up front. If the rig
does *not* track, you have built a different design and every number after that is fiction.

Keep the block's hierarchy (`set_ungroup ... false`) so reports name RTL modules instead of
flattened gate soup. Being able to read an endpoint name back to a `generate` label is most of the
debugging.

**Freeze the floorplan across every arm.** Macro placement noise otherwise swamps the RTL delta you
are trying to measure. Generate one floorplan, save it, and have every subsequent run re-use it --
all six runs of one ladder shared a single frozen floorplan, which is the only reason 13 ps deltas
meant anything. Two related traps:

- **Do not source the tracks file along with a re-used floorplan** -- and check your tool actually
  *has* the command you think (`read_floorplan` does not exist in FC 2025.06; two runs died on it).
- **Macros packed into one solid array leave no placement sites over them**, so the tool cannot
  buffer across the block. One such layout measured far worse than a flanking arrangement with a
  logic channel between the macro stacks, at low utilisation, because a single net could not be
  repeated. Give the logic somewhere to live.

### Run a ladder, not a before/after

Measure **cumulative arms** -- baseline, then transforms 1-6, 1-9, 1-12, 1-13, 1-15 -- each one
variable from the last, same floorplan. What that buys:

| arm | WNS | TNS | endpoints |
|---|---|---|---|
| baseline | -0.260 | -31.90 | 1901 |
| T1-6 | -0.162 | -4.64 | 801 |
| T1-9 | -0.156 | -0.505 | 58 |
| **T1-12** | **-0.091** | **-0.266** | **28** |
| T1-13 | -0.104 | -0.261 | 22 |
| T1-15 | -0.106 | -0.385 | 45 |

The ladder localises a regression to a *specific* transform: the 15 ps lost between T1-12 and T1-15
looked like it belonged to the last two, and an isolating run proved **13 of the 15 ps came from
T3.13 alone**. Without that arm the wrong transforms get reverted.

**Monotonicity across arms is your evidence when a delta is near noise.** 13 ps on a ~75-level path
is close to placement noise and every point is a single run. What makes it credible is that the
ordering is monotone across three independent runs -- not the size of any one gap. Say exactly that
when you report it: *monotone across three points, not a repeat-confirmed margin.*

**Know your library constants.** Measure them once and reuse: ~14.6 ps per logic level, clk-to-Q
0.172 ns, setup 0.029 ns, clock network 0.024 ns. Then `required = TCK - clk_net - setup` and any
proposed cut can be checked on paper before it is built.

**Multibit flops blur attribution.** MB8/MB6 cells merge 6–8 unrelated bits, so an endpoint name can
list `state` *and* `resp_buf_cnt`. Classification by substring is approximate; only clean families
(e.g. exactly `64 entries × 4 slots × 32 bits = 8,192`) are trustworthy.

---

## 2. Restructurings that actually buy logic levels

The theme: **the tool builds what you wrote, not what you meant.** Almost every win below is
behaviour-preserving — you are expressing parallelism or sparsity that was always there.

### 2.1 Variable array index → one-hot select  (N levels → log2 N)

The biggest single win in arbitrated designs.

```systemverilog
// BEFORE: the index is a signal, so the tool must let every lane write every bank,
// resolved in lane order -> a 32-deep priority mux per bank per field.
for (lane) if (won) rec_addr[bank_of[lane]] = addr[lane];      // ~32 levels, ~0.45 ns

// AFTER: the arbiter already emits a one-hot winner per bank and its candidate already
// carries the bank match, so at most ONE lane can write a bank. OR has no ordering.
assign sel[b]   = win_oh[b] & lane_accept;
assign rec_v[b] = |sel[b];
rec_addr[b] |= {AddrW{sel[b][s]}} & lane_addr[s];              // ~5 levels
```

The chain never resolved a real conflict — it came from the variable index alone. **Prove the
one-hot first:** find the LSB-isolate (`x & (~x + 1)`) in the arbiter and confirm the candidate
carries the target match.

### 2.1b Compare-then-mux, never mux-then-compare (and reduce-then-mux)

The same idea as 2.1 seen from the data side, and it applies wherever a **late** select meets an
**early** operand. If the selector arrives late but the operands are registered, do the work on all
candidates in parallel and let the late signal pick the *result*:

```systemverilog
// BEFORE: late way index selects the tag, THEN a 92-bit compare -> compare is on the late path
tag_hit = (tag_q[sel_way] == req_tag);

// AFTER: all 4 compares run in parallel off registers; the late index picks 1 of 4 bits
for (w) tag_eq[w] = (tag_q[w] == req_tag);      // parallel, off _q
tag_hit = tag_eq[sel_way];                       // 4:1 on ONE bit
```

Same for reductions -- **reduce first, then index**: `status_valid[w] = |status_q[w]` for every `w`,
then select, rather than selecting a wide word and reducing it afterwards. A wide OR moves off the
late path and becomes a 1-bit mux. Cost is N copies of a narrow compare, which is usually free
compared with the levels removed; check the area report rather than assuming.

The general rule: **the late signal should meet the smallest, latest thing possible** -- ideally one
gate, ideally 1 bit wide. Everything it selects between should already be resolved.

### 2.1c Tie off an arbiter that can never stall

The single biggest win in one campaign was one line: a bank-access arbiter whose grant fed the
critical loop **could never deny** -- its only requester was the port being arbitrated. Passing
`.bank_gnt_i(1'b1)` deleted the whole grant cone from the path.

Look for arbiters, credit checks and ready/valid handshakes whose backpressure is **structurally
impossible** for a given instantiation, and constant them at the instance. Prove it before you do
it -- the argument must be about the instantiation, not about traffic -- and leave the parameter in
place so a future user with real contention still gets the logic.

### 2.2 Record-then-apply: get the shared array out of the lane loop

A lane loop that read-modify-writes a shared array makes lane k+1 depend on lane k. Record narrow
per-bank (or per-entry) values inside the loop; apply them **once** after it.

Two 32-deep chains sitting directly on `req_in_ready` / `req_out_valid` became one write per bank
this way. **Legality argument:** an arbiter grants at most one per bank and an entry belongs to
exactly one bank, so no two writes target the same entry. The per-lane loop simply could not express
that, because a lane's write went to "any of N".

Keep in the lane loop anything that is genuinely per-lane (an output field, a side counter) — moving
those is what breaks the transformation.

### 2.3 Compute from the REGISTER plus a narrow "fire" term

When a later pass depends only on *whether* an earlier pass fired — not on the value it wrote —
compute it from `_q` plus the fire signal, so both evaluate in **parallel**:

```systemverilog
assign alloc_fire[e] = grant_q_v[BankOf(e)] && (grant_q_way[BankOf(e)] == WayOf(e));
assign post_state[e] = fire[e] ? NEW_STATE : q[e].state;
```

In a `generate`, `BankOf(e)` / `WayOf(e)` are **compile-time constants**, so a variable-index scatter
becomes a per-entry compare with no mux at all.

**This is also the most dangerous transformation in the file — see §4.** And the converse matters
just as much: a *drive* that must see this cycle's writes may NOT be `_q`-sourced. One hoist had to
read `_d` because a byte-merge can land in the same cycle the entry drains; a `_q`-sourced version
would have emitted the pre-merge word — **silent data corruption, not a timing regression.**

### 2.4 Decide per entry, not per lane in turn

Sequential per-lane grant loops that decrement a shared credit make each lane wait on the previous
one. Invert the loop: build the per-entry **mask of lanes wanting it**, take the lowest k by index,
grant against that entry's free slots, and write once.

Exactness rests on three checks, none of them assumptions about traffic: the lane's target derives
from registered state alone (lanes are independent); the sequential form granted in increasing index
order until credits ran out, so its granted set is exactly *the first k by index*; and the decision
reads only fields this pass never writes.

### 2.5 Exploit structural sparsity in `[lane][entry]` arrays

A `[32 lanes][64 entries]` comparison array is usually mostly dead. If an entry has exactly **one**
owner lane, 63 of every 64 replications are structurally impossible. Mux in the owner's request,
run **one** test per entry, then scatter with an owner decode: **2048 tests become 128.**

Exact, not a trade: for a non-owner lane the old compare was false and the new decode is false; for
the owner the muxed operands are that lane's, so the expression is identical term for term.

### 2.6 Don't scatter and then re-mux

A producer that scatters into an N-wide vector, whose consumers index it by a **different** dynamic
index, is immediately undone by an N:1 re-mux. Expose the producer as `(valid, id)` pairs and let
consumers **compare ids** — the scatter and the mux both disappear.

Related trap: a reduction written as a function called from a continuous `assign` **does not sample
module signals it reads but does not take as arguments.** Pass everything explicitly.

### 2.7 Hoist narrow per-entry operands so per-lane reads stay narrow

Reading `array[dynamic_idx]` inside a per-lane loop is a **full-struct N:1 mux per lane** — 32 of
them — plus another N:1 for any nested index. Build a few narrow per-entry vectors once
(`drv_data`, `drv_core`, `drv_meta`, …); each per-lane read then becomes N:1 over a narrow field.

### 2.8 Retire by dropping `valid`, not by clearing the entry

A clear is a **write**, so every identity and buffer clock gate has to wait on the dealloc decision —
typically the last thing computed in the deep cone. The tell in a placed report: a field only one
early site ever writes still shows a huge arrival.

Drop `valid` alone. The clear is redundant if allocation blanks the entry before reuse **and** every
synthesised read is valid-gated — audit that site by site, including reads that look ungated but are
consumed under a valid-gated condition.

### 2.9 Keep the loop constant as the array index

When a per-bank pass addresses an entry, write it as `b*WaysPerBank + pub_w[b]` with `b` a loop
constant. The lookup stays `WaysPerBank:1` instead of collapsing to `MshrNum:1`.

### 2.10 Defer a set; sum once instead of chaining

```systemverilog
alloc_set[e] = 1'b1;                    // during the pass
d_valid = d_valid | alloc_set;          // once, at the end   -> took 130 of a 174-cell path
sum = cnt_q + g1 + g2;
cnt_d = (sum > MAX) ? MAX : sum;        // replaces two guarded saturating increments
```

### 2.11 Clock-gate enables dominate — and must over-assert

A gating check is ~0.175 ns tighter than a D-pin check, so inferred clock-gate enables are usually
the worst endpoints. Two rules:

- **The enable must follow the write it gates.** Defer a write by a cycle and leave its enable keyed
  on the old cycle and the write is silently dropped (§4).
- **A conservative superset is the right direction.** Build the enable from shallow signals even if
  it over-asserts: over-asserting costs a little power, under-asserting loses a write.

### 2.12 Don't build what synthesis never reads

A signal whose only consumers are debug fields or assertions is still fully built in the netlist.
Wrap the **computation**, not just the use.

**Use `` `ifndef TARGET_SYNTHESIS ``, not `` `pragma translate_off ``.** Simulators compile
translate_off regions and synthesis drops them, so a declaration inside with uses outside is
**invisible in simulation and fails synthesis** — one module had not been synthesisable for weeks
because the backend used a separate, older clone. Analysing the block standalone catches this in
seconds; do it before trusting any timing number.

### 2.13 An ungenerated arm costs nothing — a knobbed-off one may not

Put optional passes behind `generate ... if (Knob)`. At `Knob=0` the comparators, the LSB-isolate,
the select mux and the output OR all fold away, **and the parent's producer logic dies with them**.
A ternary inside always-generated logic does not give you this.

While there: delete qualifying muxes that re-check something already implied — e.g. gating an id
output on `has_free` when the one-hot is already all-zero.

### 2.14 Declarations

- **`logic`, never `int`,** for anything hardware-ish: `int` is 2-state, so an unassigned read
  returns 0 and hides exactly the X that would expose the bug.
- **Never a declaration initialiser** on a variable an `always_ff` drives — it is an implicit
  `initial` block, i.e. a second driver.
- **Size to the widest INTERMEDIATE, not the final range.** A sum that reaches `2*W-2` before a wrap
  needs `log2(W)+1` bits; sized to the final range it truncates, the wrap never fires, and a
  round-robin silently selects the wrong way. This truncation class recurs — check every temporary
  that holds a pre-wrap or pre-saturate value.
- Declare **outside** always/generate blocks so the signal is visible in waveforms.

### 2.15 Free wins worth grepping for

Tautological assertions (`(x != 0) == (x != 0)`), signals only ever assigned `'0` and then added to
something, functions defined and never called, knobs with one reachable arm, duplicated localparams,
`[lane][entry]` arrays whose relation is sparse.

### 2.16 Before a readability refactor, measure what is actually synthesised

One 6,028-line module was **32% comments and 34% simulation-only — only 1,902 lines of synthesised
logic.** Splitting it into submodules was not where the pain was. When you do extract, look for the
**shared algorithm**: two arbiters differing only in one gate became one 49-line module with two
instances.

## 3. Adding a pipeline stage

### 3.1 The rule

**A pipeline stage costs LATENCY. If it costs THROUGHPUT, it is not a pipeline — it is
serialisation, and it is a bug in your design.**

Cutting a path means registering an intermediate result and consuming it a cycle later. The design
must still accept a new request **every cycle**. If your interlock stalls a shared resource while
the registered value drains, you have halved that resource's rate.

### 3.2 The trap that catches you

Deferring a write makes the state array **stale for one cycle**, so stage-1 tests that read it are
wrong. The tempting fix is to stall anything touching the resource. Do not ship that:

| interlock | cycles | merge stalls |
|---|---|---|
| reference (no cut) | 4,163 | 49,447 |
| blanket per-bank hold | 4,431 (+6.4%) | 55,242 (+11.7%) |
| **precise per-line interlocks** | **4,241 (+1.9%)** | **44,495 (−10.0%)** |

The blanket hold cost **+14.8%** on the most sharing-heavy shape. Worse, the resource was
**address-hashed**, so a coalescing cohort all mapped to *one* bank — the stall landed exactly on
the operation the block exists to perform, doubling cohort assembly (16 cycles → 32).

Note the precise form's stalls are **below** the original: the stage register decouples decision
from write, so the arbiter retries *less* than the combinational version did.

### 3.3 How to build the interlocks properly

Enumerate what actually goes stale, and give each its own **precise, register-derived** term:

| stale thing | precise interlock |
|---|---|
| free-resource lookup | OR the in-flight record into the "occupied" vector |
| a read of *that* entry | per-entry `alloc_inflight[e]` / `merge_inflight[e]` compare |
| same-key duplicate | compare the request key against the in-flight record's key |
| cross-resource conflict (e.g. id-range overlap) | per-lane test against the record, not a resource stall |

Each stalls only the **genuinely colliding request**. A cohort then pays one cycle for its leader,
not one cycle per follower.

**Verify the apply's blast radius first.** Dump what the deferred apply actually writes. If it
writes only its own entry, a resource-wide stall was never justified:

```bash
awk '/if \(rec_q_v\[b\]\) begin/,/^      end$/' rtl.sv | grep -oE 'mshr_[a-z_]+\[[a-z_]+\]' | sort -u
```

### 3.4 Measure throughput, not just completion

"It finishes" is not the criterion. Find the counter that proves work was neither lost nor delayed:

- **grants unchanged** ⇒ no work lost;
- **arbiter stalls at or below reference** ⇒ no throughput lost;
- residual cycle delta ⇒ the genuine latency cost.

---

## 4. Why PPA bugs are silent (and how to catch them)

Deferring a write **voids every same-cycle invariant in the module at once**. One pipeline cut
produced **eight** defects; **seven raised no assertion at all**, and the one that did fired ~9,000
cycles after its cause.

### 4.1 Audit the invariants explicitly

Grep the file for the claims and re-test each against the new timing:

```bash
grep -nE 'cannot|never|by construction|excludes|disjoint|same cycle|only writer|the only pass' rtl.sv
```

Real examples that became false the moment the write moved:

- *"no merge target is CACHED while the flush is high"* — true same-cycle only; a merge decided
  before the flush rose now applies under it.
- *"the no-late-join gate means `d.sub_reqs == q.sub_reqs` here"* — the gate blocks the merge
  **decision**; the apply is now a cycle later.
- A veto derived from the registered fire term stands off the write being **applied**, not the one
  being **decided**. If a retire must exclude a merge, it needs the **combinational** twin.

### 4.2 Why the existing assertions don't help

**Per-entry assertions check one entry against ITSELF.** A dropped write leaves the *previous
occupant's self-consistent snapshot*, so every internal-consistency property passes. This is
structural, not bad luck.

Two more failure modes seen in one file:

- **Escape terms make an assertion vacuous exactly when the bug happens.** A "no lost write" check
  had `|| id_en || (|rb_en)`, and the allocation raised both — so it passed on precisely the cycle
  the control write was being dropped.
- **A subcase gate hides the other subcase.** A late-join check gated on `req_len > 1` was blind to
  single-beat requests — which is what the deadlock actually was, for two days.

### 4.3 Write assertions about the CUT

Add properties that check the *transformation*, firing at the cause:

```systemverilog
cut_apply_gated:      assert(!inflight[e] || ctl_en[e]);              // the enable follows the write
cut_target_free:      assert(!inflight[e] || !q_valid[e] || <reclaimable>);
cut_not_retired:      assert(!merge_inflight[e] || d_valid[e]);       // no retire swallows it
cut_reader_sees_write: assert(!(reader_fires[e] && merge_inflight[e]) || (d.cnt == q.cnt + 1));
cut_no_double_grant:  assert(!(v[b] && q_v[b] && (way[b] == q_way[b])));
```

They are simulation-only, cost nothing in hardware, and turn a week of bisecting into one run.

### 4.4 Choose the pass criterion by change class

| change | criterion |
|---|---|
| pure restructuring (one-hot, dead code, `_q` sourcing) | **bit-exact** cycle count — anything else means the equivalence argument is wrong |
| bug fix restoring prior behaviour | **bit-exact** against the pre-bug reference |
| microarchitectural change (pipeline stage) | **no hang, no fatal, correct result, modest delta** — plus throughput counters |

Expecting bit-exactness from a pipeline stage is a category error; accepting "it finished" from a
restructuring is negligence.

**Verifying the superset does not verify the subset.** Fifteen transforms were simulated and passed;
the shipped set was twelve. That result does *not* transfer, for two independent reasons, and the
second is the one people miss:

1. Subset cycle-neutrality is an **inference** from the measurement (it holds only if each transform
   is independently neutral), not the measurement.
2. **Removing three transforms is itself a code change that can be wrong.** No amount of confidence
   about neutrality catches a botched revert. Only a run does.

Re-run the reduced set. It cost ~25 minutes and it is the difference between evidence and a story.

**Pre-register the decision rule before you run the experiment.** Write down what each outcome will
mean *while you can still be surprised*. One arm was specified in advance as: "pristine also fails
at 125 -> conclusive, never mine; pristine passes -> mine, and cycle-identity has a hole." Pristine
failed identically -- same mismatch count, same end-of-computation cycle -- and the conclusion was
already agreed, so there was nothing to rationalise after the fact.

**A FAILING test can be stronger evidence than a passing one.** A kernel with an unfenced cross-core
race failed identically on pristine and modified RTL -- same count, same EOC to the cycle. RTL
simulation is deterministic, so its *output* depends on inter-core timing; passing kernels only show
you did not change correct programs, while this one shows you did not perturb a program already
sensitive to what you might have perturbed. **But state the limit:** how sensitive it really is
depends on the race window width, which the test does not measure. Cycle-identical EOC is the hard
result; the sensitivity is a reason to weight it, not an independent proof. And if the test prints
only a *count*, you have not shown the same locations mismatched -- do not let "identical failure"
be read as set-equality.

### 4.5 Probes that discriminate nothing are worse than useless

Two scoreboard warnings fired **425,831 times in a 463,459-line transcript — 89.3%** — and were
*identical* between a passing and a hung run, because the checker did not model the coalescing the
design does. They cost enormous simulation I/O and hid the one message that mattered.

Test every probe: **does its value differ between a good run and a bad one?** If not, gate it behind
a define and keep the counter. And a counter that is identically zero across every arm of a
campaign is a bug report, not background.

---

## 4.6 Proving a restructuring is equivalent

A restructuring's whole claim is "same behaviour, fewer levels". Earn it:

**Random-vector equivalence for extracted submodules.** Instantiate old and new side by side and
compare all outputs over ~200,000 random vectors, **across every parameter combination** — a
knob-gated arm that is never exercised is not verified. This is cheap and it is the strongest
evidence available for a stateless block.

**Argue exactness term by term, in the commit message.** The good arguments have a shape: *for the
case that changed, the old expression was already false / already the same*. If you cannot write
that sentence, you have not got an equivalence — you have a hope.

**Equivalence is not enough for order-sensitive rewrites; add coverage.** When a sequential loop
becomes a parallel grant, the hazard lives in the rare case where two lanes hit one entry in a
cycle — that is the only path where slot order, pointer advance and a saturating count can differ.
A workload that never produces it proves nothing. **Add a counter for the hazard case**, and treat
zero-across-a-run as "this arm did not verify that path", not as a pass.

**Beware the separate backend clone.** Timing runs may build from a different checkout than
simulation. Diff the define set and the source revision before trusting any PPA number, and analyse
the block standalone to catch synthesis-only breakage early.

## 5. Working practice

**Verify each claim against the source before acting on it.** Reviewers — human or agent — are
often right and sometimes wrong. Every removal in one cleanup pass was checked (`grep` the writes,
the reads, the enclosing `ifdef`) before deletion. Two "dead" claims elsewhere in the same report
were wrong.

**Assert match counts in scripted edits.** Do the edit in Python with
`assert s.count(old) == 1` before writing. A pattern that matched twice (a head seed and a
second-slot seed with identical text) was caught by the assertion, not by the compiler — and because
the assertion fired before the write, the file was left untouched.

**Assert declaration-before-first-read.** SystemVerilog requires it for variables; a block moved
above its declarations fails in confusing ways. Automate the check after any reordering.

**Ask the ARTEFACT what the tool did, never the config you think it read.** This is the single
highest-yield habit in the list, and it has three faces:

- A `Bender.local` override to repoint a dependency **silently lost to `Bender.lock`**, which pins
  the resolved path. Caught by grepping the *generated compile script* for the path actually
  analysed -- the run was killed 2 minutes in instead of producing a clean-looking wrong answer.
- After a build, grep the **compile log** for which files the compiler actually read
  (`grep -o '.../[^ ]*\.sv' compile.log | sort -u`). Verifying the script *would* resolve correctly
  is weaker than verifying what then happened.
- **An empty grep in the wrong log is indistinguishable from a stale-library pass.** A regression
  came back byte-identical in 20 s and the check for "did it recompile" returned nothing -- because
  the runner writes compiler output to a *different* file. A byte-identical result from a library you
  cannot prove was rebuilt is worth nothing.

**Before running anything in a new directory, grep for what it writes.** Testbench monitors used
**relative** paths (`sim/bin/logs/...`), so a run launched from elsewhere silently scatters its
output into whatever tree happens to be cwd. Nothing errors; another run's logs just acquire your
data. `grep -n '\$fopen'` before launching costs seconds.

**Recover a revert from the object store; do not retype it.** Every `git add` writes a blob, so the
exact text each experiment was built from survives even unstaged. `git fsck --dangling`, identify
candidates by a marker profile, and **validate the identification** by confirming one recovered blob
is byte-identical to a tree that actually ran. This is not fastidiousness: hand-reverting a
transform that renamed a signal at ~20 sites inside one `always_comb` is exactly how a defect gets
introduced, and the comparison immediately caught one -- a stray `begin` added around a `for` body.
Inert there because the body was a single statement, and silently loop-changing the moment someone
adds a second. Nobody would have seen it in review; it reads as tidying.

**Prove a source freeze, do not assert one.** When another agent or colleague runs a long
verification batch against your tree, hash-sample the sources on a timer for the batch's duration
(130 samples / 0 changes over three hours, in one case). Asserting a freeze and actually having one look
identical from the outside. If you leave a dirty-tree marker in a **tool-managed** checkout, make it
**self-invalidating** -- `bender checkout` restores the sources and leaves an untracked marker
standing, which then asserts "dirty" over pristine files, worse than no marker at all.

**Design confounds out rather than detecting them.** When a collaborator was rebuilding the software
in parallel, both arms were run against a **frozen, hash-manifested copy** of the binaries. Had the
live build been used, the two arms would have differed in RTL *and* software while presenting as a
single-variable comparison -- and nothing in either log would have revealed it.

**md5-gate what you commit against what you verified.** Build directories, staged copies and the
working tree drift. Record the md5 of the RTL that produced each result and compare before
committing. This caught a commit of the wrong RTL.

**Exit traps in killed scripts silently restore old files.** A background sweep with a
restore-on-exit trap, killed to free machines, overwrote an hour of edits. If a long-running script
holds a backup, either update that backup when you change the file, or don't edit while it runs.

**Delegate systematic enumeration.** "Grep every mutual-exclusion claim and test it against the new
timing" and "classify all 24 assertions as valid / vacuous / spurious" are exactly the tasks to hand
to parallel agents. Five of eight defects came from two such audits; alone they would have surfaced
one sim-hour at a time.

**Land correctness first, then optimise the interlock.** But do not *ship* the conservative version
— measure it, then make it precise. Scaffolding that reaches the backend becomes the design.

**Keep the comment honest.** Every `_q`-sourcing and every exclusion argument must carry *why it is
safe*. When a change makes such a comment false, fixing the comment is part of the change — a stale
"legal by construction" note is worse than none, because the next person believes it.

---

## 6. Comments and coding style

Not cosmetics in a PPA campaign: the comments are where the **invariants** live, and an invariant
nobody can read is an invariant the next transform breaks.

### 6.1 Write for a reader who was not in the session

- **No internal tags.** `F1`, `C3`, `opt3`, `idea-2`, `B0.3`, run names (`chain_2p0`), commit
  hashes, `§4.6` — private to the week they were written. Name the *signal* or the *property*,
  never the experiment.
- **Describe the final code, not the route to it.** "Reading `mshr_d` here put the allocation
  arbiter into the clock-gate enable" is the history of a change. "Sourced from `mshr_q`: the only
  earlier writer is the allocation, which blanks the entry" is the invariant. Keep the second.
- **Delete the measurement once the rule it justified is stated.** `129 of the path's 165 cell
  levels`, `1.233 ns / 100 cells`, `870 of the 512 shape's cycles` belong in the worklog and the
  commit message. In the RTL they date instantly and nobody can re-derive them.
- **State a repeated rule once, then reference it.** One `SOURCING DISCIPLINE` header block plus one
  line per site replaced twelve five-line restatements: same information, 45 fewer lines, and one
  place to correct when the rule changes.
- **Never cite a line number.** `(:1194)` rots on the next edit. Name the signal — `grep` still
  works.

### 6.2 A comment pass is a code change — gate it like one

`git diff <file> | grep -vE '^[+-]\s*//'` must come back **empty**, and `vlog`/`vopt` must still be
clean. Run both before committing, and keep the pass in its own commit so the gate means something.

**Reflow the BLOCK, never the line.** Wrapping each over-long line on its own pushes the tail onto a
new line and leaves a one-word orphan (`// entry`, `// floors`) above an untouched continuation.
Join the whole comment block, then re-wrap it.

**A regex that edits prose will truncate a sentence, and the truncation ships.** One pass cut nine
sentences mid-clause — `req_len is.`, `HoldSubsBurst for.`, `and by.`, `cycles,.` — and they sat in
git for days, because nothing compiles a comment. After any scripted comment edit, sweep for the
signature and read the added lines back, not the summary count:

```bash
grep -nE '^\s*//.*([,;] *\.| \.)\s*$|^\s*//.*\(\s*[,;]'          f.sv   # truncated, empty parens
grep -nE '^\s*//\s*[a-z][A-Za-z_]*( [a-z][A-Za-z_]*){0,2}\s*$'   f.sv   # orphaned fragments
git diff -U0 -- f.sv | grep '^+' | sed 's/^+//' | awk 'length>100'      # over-long additions
```

**Sentence-casing a wrapped comment renames the symbols in it.** `// Hold_cnt is sized from...`
reads as a different identifier than `hold_cnt`, so a grep for the signal misses it. Where a line
starts mid-sentence with an identifier, leave the case alone.

### 6.3 Conventions that keep the design reviewable

- **Declare at module scope, never inside a `generate` or `always` block.** Waveform scripts and
  assertions reference the hierarchical name, so a declaration inside `gen_foo` cannot be hoisted
  later without breaking them — and it is invisible in the waveform exactly where you need it.
- **`_q` / `_d` as a suffix, not an infix.** `mshr_valid_q`, not `mshr_q_valid`. Once ~100 sites
  carry the wrong form, fixing it is a pure-churn diff nobody reviews carefully. Get it right at the
  first write.
- **Prefer `generate` + `assign` to another branch in the big `always_comb`.** Each signal gets
  exactly one driver, the parallelism stays visible to the tool, and the block does not grow.
- **A module-scope variable may have only one combinational driver.** That constraint decides what
  can be lifted out of a large `always_comb` — check it while planning the extraction, not after the
  compile error.
- **One alignment column per declaration block.** Three name columns in one port list is what pushes
  lines past the limit in the first place.
- The declaration rules in §2.14 (`logic` not `int`, no declaration initialiser, size to the widest
  intermediate) are the same discipline seen from the synthesis side.

### 6.4 Rank cosmetic changes honestly, and never bundle them

Renames, re-scoping and re-alignment are **cosmetic-only-verify-after**: no PPA gain, a wide diff,
and a real chance of a silent slip. Late in a campaign that trade is bad — the module that produced
eight silent defects in a single day is not the place to rename 113 sites for tidiness. Rank them
below anything with measured value; if you do them, do them alone, in their own commit, with the
non-comment diff gated to empty.

**Do not "fix" the house style you inherited.** 225 lines over the column limit looked like debt
until it turned out every one was a declaration in the author's deliberate wide-column layout — and
the count barely moved when the comments were fixed. Check whether a violation predates you (`git
show HEAD:file`) before spending a 200-line diff on it.
