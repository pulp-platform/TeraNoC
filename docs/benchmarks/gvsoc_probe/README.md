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

---

## Response-path widths — three stages, TWO roots (not one)

Recorded because it was misread once and the misreading nearly became another team's design.

| stage | width | derived from |
|---|---|---|
| target-side burst expander (request → per-bank reads) | **3** | `RemoteBurstIssueWidth = NumRemoteRespPortsPerTile = 1 + NOC_RESP_CHANNEL_NUM` (`mempool_tile.sv:71`) |
| NoC response channels (beat return) | **2** | `NumRemoteRespPortsPerTile-1:1` — index 0 is the *local* port and is excluded from every response array (`mempool_pkg.sv:505`, `mempool_group.sv:88-95`) |
| MSHR ParityDrain receive + core-complex `NumRespPorts` | **2** | `MshrDrainBeats = GROUP_MSHR_DRAIN_BEATS` (`mempool_tile.sv:77`) |

⚠️ **The "single source of truth" comment at `mempool_tile.sv:72-76` documents `MshrDrainBeats` on
line 77, NOT `RemoteBurstIssueWidth` on line 71** — it sits between the two declarations. So
`MshrDrainBeats` is one root for two stages (MSHR drain + core resp ports), while the expander has
a *different* root. There are two roots here, not one.

All three expander lanes are genuinely wired — `mempool_tile.sv:1063-1068` maps
`lane = 0 .. RemoteBurstIssueWidth-1` with no gaps — so the 3 is not a dangling array. Beat
**production** at the target is 3-wide; beat **return** is 2-wide. The binding constraint on
arrivals at a requester's MSHR should therefore be the return path, and a model that takes
`RemoteBurstIssueWidth` as its emission width is reading the wrong stage's number.

⚠️ ParityDrain has hard preconditions (`mempool_tile.sv:91-95`): it `$error`s unless
`NumCoresPerTile == 1` and `NumDataPortsPerCore >= 3`, because the `core_id+(b&1)` retag assumes
one core per tile whose data port 1 is the burst-issuing VLSU port 0.

### ParityDrain is TWO retags, not one

`mempool_group_mshr.sv:124`: *"beat b of ANY burst entry leaves on resp port `1+(b&1)` with
`core_id+(b&1)` — uniform law"*.

| retag | what it changes |
|---|---|
| port `1+(b&1)` | which return channel **transports** the beat |
| core_id `+(b&1)` | the identity the beat carries, i.e. which VLSU port **steers** it at the destination |

⚠️ **Alternating the channel without retagging the identity is a half-fix that measures as a
failure of the whole idea.** `:885-888` documents it: *"under the legacy contract every beat echoes
the ORIGINAL core_id, so all beats collapse to [one port]"*. Two channels of transport, still one
beat per cycle delivered — which reads as "the return path was not the constraint after all". The
parity must be applied to the thing that STEERS at the destination, not only to the thing that
TRANSPORTS.

⚠️ **Hard precondition, asserted at `:1610-1622`:** the retag is `+1`, not a hash or modulo, so it
only lands on the right port pair when the burst's base `core_id` is exactly 1 (the VLSU burst base
port). The RTL `$fatal`s rather than misroute silently:

```
ParityDrain: burst entry %0d sub %0d core_id=%0d != 1 (retag would misroute).
```

Plus the tile-level guards at `mempool_tile.sv:91-95` — `NumCoresPerTile == 1` and
`NumDataPortsPerCore >= 3`, because the flat `+1` retag has no room to land otherwise. A
4-cores-per-tile configuration reintroduces the blocker.

### ⚠️ Reading rule: `[N-1:1]` means "remote only — index 0 is local"

The group MSHR sits **only on the NoC-facing ports**. Its request array is declared
`[NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]` — indexed from **1** — and port 0 is the
local interconnect, routed elsewhere entirely (`mempool_group.sv:304`,
`master_local_req_valid[t] = tcdm_master_req_valid[0][t]`). The response arrays use the same
`[NumRemoteRespPortsPerTile-1:1]` slice for the same reason.

**Consequence: an intra-group burst never appears in any MSHR counter, while its beats still reach
the VLSU.** So every MSHR-side instrument shares one blind spot, and no cross-check *between* MSHR
counters can reveal it — they are all on the same side of the bypass.

`[MSHRLIFE]` and `[MSHRLIFE-BEATS]` therefore measure **remote** bursts only. Label any rate
derived from them accordingly; "burst beat arrival rate" without the qualifier invites the reader
to take it as all bursts.

The generalisation worth keeping: **two instruments are only independent if they sit on different
sides of every bypass, not merely in different files.** This particular assumption was invisible
to arithmetic because it was topological — no residual, ratio, or internal consistency check could
have surfaced it. Counting at the point of delivery, downstream of where the classes rejoin, has
no such gap.

### ⚠️ Second blind spot: MSHR-BYPASSED requests have no entry

`mempool_group_mshr.sv:883-889`: a multi-beat load that finds a **full bank at allocation** is
*"forwarded to the NoC with mshr_tag=0, NO ENTRY"*. No entry means no `resp_buf` write, and all
`[MSHRLIFE*]` probes key off `|mshr_rb_we[e]` — so **bypassed traffic is invisible to them**. That
much is structural and stands.

#### The `[BYP]` counter, fully decomposed — no anomaly

An earlier revision claimed *"50.5% of the workload bypasses, congestion-driven"*. **Retracted.**
`[BYP] fwd` gates only on `(mshr_tag == '0) && (req_len == 1)` (`:2541-2547`) — single-word
requests, **no load/store filter**. Differencing the cumulative counter against the benchmark-window
boundaries splits its 132,420 into two unrelated mechanisms:

| | count | share | why |
|---|---|---|---|
| before the window | 68,481 | 51.7% | **init/copy STORES** — `main.c:329-340` DMA-copies A and B then `init_matrix()` writes A, B and the checksum |
| during the window | 63,939 | 48.3% | the **C store stream** — C = M·P = 65,536 elements, a 97.6% match |

Both shares are the **same** mechanism: MSHR admission requires `req_is_load` (`:1387`), so every
store bypasses a read coalescer by construction, and the `[BYP]` counter has no load/store filter.

⚠️ **An earlier revision attributed the pre-window share to `CFG_ENABLE = 0` being the MSHR's reset
state (`:1380`). That is wrong for these builds.** That comment describes the **CSR flow**
(`MshrCfgRuntime=1`). Our runs set `GROUP_MSHR_CFG_RUNTIME=0`, and `:491` reads

```systemverilog
assign cfg_mshr_enable = mempool_pkg::MshrCfgRuntime ? cfg_i.enable : 1'b1;
```

which collapses to `1'b1` — **the MSHR is enabled from reset here**, so nothing bypasses for that
reason. Quoting a comment that describes a configuration the build does not select.

Corroborating that it was never congestion: `[BFBHASH] full_events = 0`,
`avg_free_banks = 13.4 of 16`, `bank_ovf_hist` all zeros, and `bank_alloc_hist` uniform at **62 on
every one of the 16 banks**. The real bank-full counter is `bankfull_bypass = 432` per group
(~6,900 total), not 132,420.

⚠️ **Method:** a cumulative counter's *total* is an average over regimes that may share nothing.
Difference it against the phase boundaries before quoting it — here a single total concealed a
52/48 split that no consistency check on the total could have separated.

### ⚠️ 256x32x256 is INSENSITIVE to concurrency effects — do not A/B channel changes on it alone

Reported by the GVSOC side after building the transport half of ParityDrain in their model. Their
measured deltas against the RTL goldens:

| shape | before | after | change |
|---|---|---|---|
| 128x128x512 | +64.7% | +38.8% | large |
| 512x512x128 | +16.2% | −1.4% | large |
| **256x32x256 (our reference)** | — | — | **0.5%** (6,185 → 6,153) |

The reference shape has little **concurrent** burst traffic, so a change that spreads beats of
*different* bursts across channels has almost nothing to relieve there. Any channel-assignment or
port-arbitration A/B run only on 256x32x256 will look inert whether or not it works.

**And the distinction that produced it is worth keeping separately:** alternating channels did
*not* change the per-burst beat rate (still 1.00/cycle) — one burst's beats still serialise at the
requester — yet wall-clock improved ~15% on the concurrent shapes. **Contention relief and
per-burst width are different quantities**, and an unchanged rate is not evidence a
channel/arbitration change did nothing. Reading the flat rate as a refutation would have reverted a
change that halved their calibration error.

Pick a shape with real concurrent burst traffic when the mechanism under test is about sharing a
resource between *different* transactions.

### `[MSHRLIFE-OCC]` — time-averaged entry occupancy

```
[MSHRLIFE-OCC] <hier> MshrNum=64 cycles=.. occ_sum=.. active_cycles=..
```
  * mean occupancy (whole run)    = `occ_sum / cycles`
  * mean occupancy (active only)  = `occ_sum / active_cycles`

⚠️ **Accumulated every cycle, never sampled.** The GVSOC side quoted an instantaneous count taken
at 8192-cycle window boundaries as if it were a mean; rebuilding it as a per-cycle accumulator
changed **6.0 → 2.99**, a clean 2× bias. Sampling a time-varying quantity at fixed points and
calling it a mean is wrong, and period boundaries are the worst available phase because they
correlate with whatever the workload does periodically.

Both denominators are reported because my entry counts span the **whole sim**, not just the
3,845-cycle benchmark window — deriving occupancy from an entry count against a window denominator
that does not match it produced a 4.6-to-39 range on this very question, which is why it had to be
measured rather than inferred.

**Generalisation worth keeping:** two failures on this thread came from attributing a quantity to
the stage where it *surfaced* rather than where it *originated* — a wedge PC (where the core
stopped, not what stopped it) and a serialisation read at the drain (where it showed, not where it
was caused). Same error in different domains.

### ⚠️ Two window numbers, two spans — state which

| number | span |
|---|---|
| **3,845** | `[VPERF] win` — cycles with `csr_trace_any_global` high (the TB's traced region) |
| **4,188** | the app's own timer, `mempool_start_benchmark()` … end ("The execution took N cycles") |

343 cycles apart (8.9%). The app timer opens slightly before tracing and closes after. **Use 4,188
for wall-clock comparison against another simulator's elapsed time**; per-window rates
(`pair_commit`, `N_active`, `arr_*`) are normalised by 3,845 and stay internally consistent.

Three denominator collisions arose in this collaboration — the I$ warm-up, whole-sim vs window, and
traced-region vs app-timer. **None was an implementation bug**; every one was two correct
instruments measuring spans differing by a phase. Standing rule: state the span with every number.
