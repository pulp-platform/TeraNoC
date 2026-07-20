# Request-Hold Merge Window ("hold-the-fetch") — design + implementation

**Status: IMPLEMENTED (2026-07-17)** in `hardware/src/mempool_group_mshr.sv`, opt-in via
`group_mshr_hold_window=W` (0/unset = off, const-folds out) + `group_mshr_hold_subs` (default 2).
See §3b for the as-built deltas vs the original sketch. Companion to
`docs/respbw_paritydrain_design.md` (the implemented 2-wide drain) and
`docs/matmul_bottleneck_report.md` §6–7 (the measurements motivating this design).

## 1. Problem and insight

The group MSHR can only merge a same-line request into an entry **before the entry's first
response beat arrives** (`req_hit_way` requires `WAIT_RESP && beats_left == burst_len`): a later
joiner would have missed drained beats (`resp_buf` holds only 2). The *effective* merge window is
therefore `issue-to-first-beat` ≈ the NoC round trip — measured at only **~10–15 cycles** for near
groups, and *shrunk* by our own 2-wide receive making responses faster.

Meanwhile the measured emission skew between the two cores of a coalescing pair (QSKEW study,
report §6) has median 4 cycles but p75 = 15, p90 = 25, and 15.6% of pairs miss by >40 — the tail is
injected *downstream* of any software rendezvous (residual VLSU drain under one-insn serialization,
the ROB allocation walk), which is why the per-step barrier could not buy merges and was removed
(report §7).

**The insight: the window closes at first-beat arrival = issue + RTT. Delaying the entry's NoC
issue by W cycles therefore extends the merge window by exactly W** — alignment applied at the one
pipeline point where it matters (the door), with zero cross-core signaling.

## 2. Mechanism

1. **Allocate immediately, hold the fetch.** A mergeable full-burst miss allocates its entry
   exactly as today (the follower's merge path requires the entry to be resident and in
   `WAIT_RESP`). The entry gains a small hold countdown (`hold_cnt`, `$clog2(W+1)` bits — sized
   from the window, so any W is supported) initialized to `W`
   (config knob `group_mshr_hold_window`, 0 = feature off). While `hold_cnt != 0`, the entry's
   outbound NoC request is withheld.
2. **Early release.** The moment the entry's subscriber count reaches the expected sharing degree
   (config `group_mshr_hold_subs`, =2 for the matmul pair split), the request issues immediately.
   An aligned pair pays only its actual skew (median 4 cycles), not W.
3. **Timeout release.** `hold_cnt` decrements every cycle; at 0 the request issues regardless. A
   singleton line pays W once. The countdown always expires → **trivially deadlock-free** (no
   request ever waits on another core's action).

### Sizing from measured data
`W=16` captures ~75% of drifted pairs, `W=24` ~90% (report §6 skew distribution). Expected cost on
unpaired lines: +W cycles of leader latency, hidden in this kernel by the ~64-cycle FPU work per
iteration and the VLSU's latency-tolerant receive.

## 3. Implementation sketch

The nontrivial part: today `req_out` is a **same-cycle passthrough** of `req_in` — an allocated
request and its NoC issue are the same event. A held entry must issue *later*, from its own fields
(all present: `base_addr`, `tgt_group_id`, `burst_len`, its Tier-b tag = entry index + 1):

- **Entry:** `+hold_cnt[HoldCntW-1:0]` (init W on mergeable-full-burst alloc; 0 on all other alloc kinds so
  singles/AMOs/stores and bypasses are untouched).
- **Release logic:** `hold_done = (hold_cnt == 0) || (sub_reqs_num >= hold_subs)`; decrement per
  cycle while nonzero.
- **Replay injection:** a per-group request-replay port — a small arbiter that walks entries with
  `state == WAIT_RESP && !issued && hold_done` and injects one request per free outbound lane per
  cycle, arbitrating with fresh passthrough traffic (fresh bypasses keep priority: they are
  non-backpressurable end-to-end). One new `issued` bit per entry marks the fetch as sent.
- **What must NOT be done:** holding `req_in_ready` low at the door. That would head-of-line-block
  the tile request port (scalar loads/stores behind the burst) for W cycles — the cheap variant is
  the wrong variant.
- **Interaction with ParityDrain / bypass-retag:** none by construction. The hold happens strictly
  before issue; the drain and the retag act strictly after responses return. The merge that the
  hold enables produces a normal multi-subscriber entry served by the existing 2-wide multicast.

Estimated cost: ~6 bits/entry (+ `issued`) ≈ 400 FF/group, one replay arbiter/mux (~100 lines).

## 3b. As-built implementation notes (2026-07-17)

All in `mempool_group_mshr.sv`; knobs `group_mshr_hold_window` (W, 0/unset = off) and
`group_mshr_hold_subs` (default 2, legal [2, merge_reqs]) plumbed through `hardware/Makefile` as
`GROUP_MSHR_HOLD_WINDOW` / `GROUP_MSHR_HOLD_SUBS`. Deltas vs the §3 sketch, each load-bearing:

1. **Hold covers every fresh MSHR allocation** — bursts *and* singles (§4 said singles matter:
   degree-8 A-lines). Only `req_alloc_found` winners are held; bank-full bypasses and stores/AMOs
   take the legacy same-cycle passthrough untouched.
2. **Held allocation decouples the door from the NoC**: `req_in_ready = 1` (unconditional accept),
   `req_out_valid = 0`. The entry is created exactly as before plus `hold_cnt = W`, `issued = 0`.
   With the feature off every alloc sets `issued = 1` and all hold logic const-folds away.
3. **Ready-gated single-cycle injection instead of a stateful replay arbiter.** The replay walker
   (end of the request path, same comb) visits entries from a free-running RR base
   (`hold_replay_rr_q`) and injects a held entry's fetch **only when its owner lane is idle
   (`!req_out_valid`) and the lane's spill-register `ready` is already high** — the injected
   `valid` is accepted in the same cycle by construction, so no lane ever presents a retractable
   or payload-mutating `valid` (spill-reg ready is state-only → no comb loop). Fresh door traffic
   (including non-backpressurable bypasses) claims lanes first; a door-stalled lane's idle cycle
   is usable by replay.
4. **Owner-lane replay is mandatory, not a preference**: the tier-b response-capture guard
   re-validates `sub_reqs[0].tile_id` against the arrival lane, so the fetch must egress on the
   owner's original (tile, port) lane — which the entry already records.
5. **Early release checks `mshr_d`** (post-merge view): a subscriber landing this cycle that
   reaches `hold_subs` releases the fetch in the *same* cycle.
6. **Countdown runs on the `_q` view before this cycle's allocations**, so a fresh alloc keeps
   its full window; the countdown never stalls → release within W cycles guaranteed
   (deadlock-free), even if lane contention then delays injection a few extra cycles
   (self-limiting: the subscriber cores are stalled waiting on this very load).
7. **Assertion** `hold_unissued_no_beats`: a valid un-issued entry must be `WAIT_RESP` with
   `beat_seen == 0` — response activity for a never-sent tag is fatal (tag-aliasing guard).
8. **Bug found in debug (matmul W=16 wedge): bypass-track ghost ways.** The ParityDrain
   bypass-retag table classified "a bypassed burst" as *door accepted* (`req_in_valid && ready`)
   *and lane forwarding* (`req_out_valid`) — two events that were the same thing until replay
   existed. A replay injection claiming a lane in the same cycle the door locally accepted a
   load-burst **merge** on that lane satisfied both, allocating a ghost track way keyed to the
   merged burst, whose beats drain from the MSHR (never as tag-0 bypass responses) → the way
   never retires. Two leaks at one tile → the 2-deep table overflows (`bypass_track_overflow`
   fatal, matmul W=16 at ~cyc 10.7k). Fix: qualify the table allocation (and the assertion) with
   `req_out.mshr_tag == '0` — a genuine door passthrough always carries tag 0, while entry
   allocations and replay injections stamp (entry + 1). Lesson: every consumer of the door
   handshake had to be re-audited once accept and forward were decoupled (stats and TB probes
   audited clean — they key on door signals only).
For comparison, Option D (burst-line response cache) needs 512 *data* bits per cached line —
~100× the storage — and additionally serves arbitrarily-late requesters and repeat lines; the two
compose, but for temporally-clustered sharing (matmul) the hold window captures most of D's merge
benefit at a fraction of the cost.

## 4. Companion finding (2026-07-17, corrected): scalar A-loads are ALREADY admitted — capacity
## is what starves them

`group_mshr_enable_single=1` turned out to be the **flavor default** (`terapool_spatz4_fpu.mk:138`)
— the "knob experiment" was vacuous (cycle-identical rerun, independently confirming determinism).
The corrected picture from the run's own stats: of ~61k admissible remote A-`flw`s, only **~42%
obtain entries** (the rest bypass on full banks), and cached A-lines are **evicted before their
7 same-m-block sharers arrive** (24.4k fills, 5.1k hits, 23.4k evicts — 21% hit-per-fill). So the
8-way A-sharing opportunity is real but throttled by way capacity and eviction churn, not by
admission. Consequences for this design: (a) the hold window applies to single-word entries too
(expected sharing degree 8 for A-lines — early-release at 8 subs or timeout), turning the churned
cache pattern into direct multicast; (b) the capacity policy (way reservation / eviction priority)
is a co-equal lever; (c) any claim that scalars "bypass the MSHR by configuration" is wrong and
was corrected in the project records.

## 5. Evaluation results (2026-07-17): mechanism works, NET-NEGATIVE on matmul at every W

All runs: `sp-fmatmul-opt-burst-merge` 256×32×256, terapool_spatz4_fpu, drain_beats=2,
enable_single=1, stats aggregated over all 16 groups. Correctness clean everywhere
(sp-mshr-burst-test PASS; 0 CMS warnings; `hold_unissued_no_beats` quiet; OFF re-verified
cycle-exact at 3836 on the final RTL).

| W  | kernel cyc | Δ vs OFF | merged | allocs | no-entry bypasses | resp from_mshr | cache hits |
|----|-----------|----------|--------|--------|-------------------|----------------|------------|
| 0  | **3836**  | —        | 19,841 | 32,955 | 85,685            | 201,836        | 5,069      |
| 8  | 3986      | +3.9%    | 20,057 | 29,247 | 89,177            | 191,894        | 3,644      |
| 16 | 4209      | +9.7%    | 19,989 | 26,720 | 91,772            | 176,114        | 3,117      |
| 24 | 4229      | +10.2%   | 21,255 | 24,899 | 92,327            | 169,514        | 2,831      |

**Mechanism verified, hypothesis falsified.** The window extension does what it was designed to
do — at W=24 it captures +1,414 extra merges (rate 14.3% → 15.3%) — but every held cycle extends
the entry's *way occupancy* by the same amount. Banks saturate, would-be leaders of **new** lines
bypass entry-less (allocs −24% at W=24), their followers then have nothing to merge into
(no-entry bypasses +6.6k), multicast volume drops 16%, and the response cache starves (hits
−44%). The capacity externality outweighs the merge gain at every W, monotonically in W.

**Conclusion.** This is the second independent experiment (after the report §7 barrier ablation)
falsifying temporal alignment as the limiter: **on this workload MSHR way capacity + eviction
churn are first-order; emission skew is second-order.** Any policy that lengthens entry lifetime
loses. The feature stays in-tree as a correct, opt-in, const-folded-off knob (useful for
latency-tolerant streaming workloads with strong same-line locality and low bank pressure), with
default OFF. The productive next levers extend the **serve** window without extending the
**hold** window: Option D (burst-line response cache — followers hit *after* the fetch
completes, no WAIT_RESP extension) and way-capacity policy (reservation / eviction priority),
plus parked A+C for raw bandwidth.

## 5b. Per-type early-release targets (2026-07-18): implemented; degree-8 single-hold also loses

User-proposed refinement: the early-release subscriber target differentiated by request TYPE —
scalar singles (A-lines, natural sharing degree 8) vs vector bursts (B-lines, degree 2). The type
bit (`burst_len == 1`) is free at the door, so the split costs one mux; address-range
discrimination was rejected (programmable range registers + hot-path comparators for no extra
separation power on this traffic). Knobs `group_mshr_hold_subs_single` / `_burst` (default =
uniform `group_mshr_hold_subs`); class-split stats (`reqs_by_class:` merged/alloc × single/burst)
added to the period + final dumps.

Results (single=8, burst=2), alongside §5:

| config          | kernel cyc | Δ vs OFF | merged (s / b)          | allocs (s / b)          | no-entry byp | cache hits |
|-----------------|-----------|----------|--------------------------|--------------------------|--------------|------------|
| OFF             | **3836**  | —        | 19,841                   | 32,955                   | 85,685       | 5,069      |
| W16 uniform-2   | 4209      | +9.7%    | 19,989                   | 26,720                   | 91,772       | 3,117      |
| W16 s8/b2       | 4167      | +8.6%    | 18,381 (17,089 / 1,292)  | 26,444 (18,910 / 7,534)  | 93,656       | 2,490      |
| W24 uniform-2   | 4229      | +10.2%   | 21,255                   | 24,899                   | 92,327       | 2,831      |
| W24 s8/b2       | 4354      | +13.5%   | 17,776 (16,189 / 1,587)  | 24,692 (17,722 / 6,970)  | 96,013       | 2,140      |

**Why degree-8 single-holding loses.** The class split shows single merges per single alloc stay
≈0.9 at every setting — single entries essentially **never reach 8 subscribers inside the hold
window**, so nearly every held single pays the FULL W (latency and occupancy) and then times out.
The A-sharers arrive spread over hundreds of cycles (already implied by the OFF baseline's 21%
hit-per-fill cache churn): in the OFF design the late sharers are served by the CACHED state
*after* the fetch, and holding the fetch both delays that cache availability (hits 5,069 → 2,140)
and squeezes way capacity (no-entry bypasses 85.7k → 96k). The consolidation hypothesis is
falsified: temporally-spread sharing cannot be bridged by pre-issue holding at any threshold —
only by post-fetch serving (Option D burst-line cache, longer CACHED retention / eviction
priority).

**Disposition.** Per-type thresholds stay in-tree (correct, const-folded when off, and the right
shape of knob if a latency-tolerant workload ever wants holds); for matmul the recommendation is
unchanged: `group_mshr_hold_window=0`. Capacity-side levers are the roadmap.

## 5c. Measured root cause (2026-07-18): why "more merge window" ≠ more coalescing here

Direct-counter instrumentation added to `gen_stats` (per-bank alloc/overflow histograms, per-entry
requester tally at free, drain-hit stall cycles, hold release reason; all translate_off, printed
at the trace-off flush). Instrumented reruns are cycle-identical to the originals (OFF 3836 /
W16 4209, all totals equal) — the counters are non-intrusive. Findings, each a measurement:

1. **The regression is the held data itself.** 85.5% of held burst entries and 70.2% of held
   singles hit the TIMEOUT release (`hold_release` counter) — no partner arrived in-window — so
   they pay the full W in latency for nothing. VPERF: +327 of the +368 window growth (89%) is
   `wait_beats` (VLSU waiting for its own beats). CMS: mean request latency 30 → 34 cyc.
2. **Same-line burst partners are separated by iteration-scale time, not pipeline skew.** At
   entry free, 90.9% of burst entries served exactly one requester (avg 1.09 subs; W16 raises
   capture only to 18.4%). Drain-hit stall cycles ≈ 0 (32–90 cycles TOTAL across 16 groups):
   partners do not even arrive during the ~16-cycle drain right after the window — the gap
   between same-line requests exceeds window+RTT+drain ≈ 60 cycles. Burst budget (OFF): 15,360
   burst reqs → 9,106 allocs + 830 merges + 5,424 bank-full bypasses = ~14.5k line fetches where
   perfect pairing would need ~7.7k. The sharing exists but is spread across loop iterations
   (cores drift apart at ~64+ cyc/iteration with no resync — consistent with the §7 barrier
   ablation). **The earlier QSKEW "median pair skew 4" was survivorship-biased**: that analysis
   time-clustered same-line requests with a 40-cycle split threshold, so iteration-scale gaps
   were excluded from its "pairs" by construction.
3. **Entry capacity is the global limiter, and it is uniform — not a hot-bank/hash problem.**
   Per-bank histograms: overflow (mergeable miss, bank full) rate is 39–47% on EVERY bank at OFF,
   rising uniformly to 50–58% at W16. No concentration → more total ways helps, a better hash
   does not. The idealized line-granular model profiler corroborates: flat pool of 16 entries
   sees only 7 no-free events on the same traffic (its 4.53 reqs/line is inflated vs the real
   word-exact singles, but its capacity contrast is valid).
4. **Hold's second-order damage confirmed causal**: unreclaimable occupancy 16.4 → 18.1 avg
   (max 38 → 43 of 64) during the kernel → +6.1k overflow events → −6.2k allocs, −1.9k cache
   hits. Door congestion is ruled out (BP door stalls FELL 17.1k → 11.1k with W16).

**Implication.** On this kernel, no affordable pre-issue window can span the ~60+ cycle gaps
between same-line requests; meanwhile 40–47% overflow at OFF says the design is starved of
*entries* (metadata), not of merge opportunity mechanics. The cheap, no-data-storage lever is
raising `group_mshr_num` (an entry costs ~metadata + 2-beat resp_buf, ~100× less than a
528-bit burst-line cache way): predicted to cut overflows, recover allocs/merges/cache-hits, and
reduce NoC traffic. Validation run `group_mshr_num=128` in flight; results below.

**`group_mshr_num=128` validation result — capacity relief is real but buys nothing:** overflow
rate 42% → 36% (still high: the pressure is bursty — synchronized kernel-start fetch waves),
allocs +4.5k, yet net NoC fetches fell only 2.9k, merges/hits did NOT recover (chaotic re-timing
moved them −2.1k/−0.4k), CMS mean latency unchanged (30), and the kernel came out 3977 (+3.7%,
`no_insn` +135 — re-timing sensitivity, not a latency mechanism). **Combined verdict of the whole
investigation: this kernel is LATENCY-bound on the FPU-side chain, and response bandwidth is not
binding (RESP-stage stall rates ≤3.4%, 4× receive headroom). Coalescing saves bandwidth/traffic
— a resource that is not scarce here — so no coalescing-capture mechanism (barrier, pre-issue
hold, per-type thresholds, or raw entry capacity) can pay for even small latency or re-timing
costs on matmul.** The MSHR merge path's value on this workload is NoC traffic/energy/congestion
at scale, not kernel cycles. The one latency-aligned lever left in the roadmap is A+C
(2-in-flight VLSU mem insns — latency *hiding*), plus software-side B-reuse.

## 6. Verification plan

1. Regression: `sp-mshr-burst-test` ON/OFF; OFF build bit-identity (knob=0 const-folds).
2. Merge-rate + bypass counts (MSHR stats) and QSKEW-style pair-outcome curve vs W ∈ {0, 8, 16, 24}.
3. Matmul kernel cycles (guard against leader-latency regression) + streaming microbench
   (unpaired workload: measures the pure W cost on singletons).
4. Assertions: hold only in `WAIT_RESP` with no beats seen; `issued` set exactly once per entry
   generation; countdown-zero implies issue within bounded cycles (liveness).
