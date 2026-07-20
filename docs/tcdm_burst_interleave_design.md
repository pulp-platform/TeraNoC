# TCDM Burst-Expander Beat Interleaving ("dual-context expander")

**Status: PLANNED (2026-07-18), user-approved (Option 1 of the local-burst skew discussion).**
Companion to `docs/mshr_request_hold_design.md` §5c (the measured >60-cycle same-line partner
gap this design attacks at its source) and `docs/respbw_paritydrain_design.md`.

## 1. Problem: intra-group same-address bursts serialize and inject pair skew

The group MSHR taps only the NoC-bound request lanes (`[2:1]`); intra-group traffic rides
lane 0 through the local logarithmic crossbar (LIC) and reaches the destination tile's slave
port with `burst_len` rebuilt from sideband (`mempool_group.sv:285-289`). Burst expansion to
single-word bank requests happens in `tcdm_burst_expander`, whose input contract is:

> "Issues up to IssueWidth beats per cycle. **The input port is stalled while draining a
> burst.**" (`tcdm_burst_expander.sv:9`)

Two cores loading the *same* line homed in their *own* group necessarily converge on the same
expander (same destination tile). The second burst therefore waits out the first's entire
drain, then re-walks the same banks: full serialization. The second core's responses complete
a full drain-time later (user-observed: >= 16 cycles), and **nothing ever re-aligns the pair**.

Why this matters beyond the local line itself: it is a *skew injector* for the MSHR. With B
interleaved across 16 groups, ~1/16 of a coalescing pair's shared lines are homed in their own
group. Each such event knocks the pair ~a-drain-time apart; the pair's *next several remote*
shared lines then arrive outside the MSHR merge window and miss coalescing. The measured
partner gap (>60 cycles, design doc §5c: 90.9% of burst entries serve exactly one requester)
is fed by exactly this kind of repeated, never-corrected injection. Unlike the pre-issue hold
mechanisms (all measured net-negative because they only save non-scarce bandwidth), this fix
removes a genuine *latency* penalty (the +drain-time on the second core's burst), so it can
pay off even under the latency-bound verdict.

There are two expander instantiation sites, both affected:
- `mempool_tile.sv:1062` `gen_remote_burst_expander` (per slave port rp = 0..2,
  IssueWidth = RemoteBurstIssueWidth = 3): expands NoC-arriving *and* LIC-arriving
  (slave port 0) bursts in front of the bank crossbar. **This is where same-address
  intra-group bursts serialize.** 16-beat drain ~6 cycles at width 3 (more under bank
  contention).
- `mempool_tile.sv:1340` `i_local_burst_expander` (per core local port, IssueWidth = 1):
  16-beat drain = 16 cycles; serializes back-to-back bursts of one core (and holds the LIC
  port meanwhile).

## 2. Design: two-context expander with round-robin beat issue

Upgrade `tcdm_burst_expander` itself (both sites inherit the fix), opt-in via a new parameter.

### 2.1 Interface & knobs
- New module parameter `NumContexts` (1 = legacy, 2 = interleaving). Legal values 1/2 only
  (elaboration `$error` otherwise).
- Plumbing follows the established knob pattern: flavor config `tcdm_burst_interleave ?= 0`
  -> `hardware/Makefile` fallback + `-DTCDM_BURST_INTERLEAVE` -> `mempool_tile.sv` localparam
  -> parameter at both instantiation sites. 0/unset = NumContexts 1 = **bit-identical legacy**
  (all second-context logic const-folds out; verified by EOC-identity regression).

### 2.2 Context state
Per context c in {0,1}: `req_q[c]`, `active_q[c]`, `beat_q[c]`, `len_q[c]` (context 0 =
today's registers). One RR toggle `issue_ctx_q` selects the issuing context each cycle.

### 2.3 Acceptance rule (`ready_o`)
- No context active: exactly today's behavior — singles pass through combinationally
  (zero added latency), bursts latch into context 0.
- One context active (draining): accept a new request into the free context **only if the
  incoming request is a load** (`!wen && amo == '0`; the existing `req_is_load` signal).
  Stores and AMOs wait for full drain, exactly as today.
- Both contexts active: `ready_o = 0`.

The loads-only rule kills the only ordering hazard interleaving could introduce: a store
entering the shadow context could overtake un-issued beats of the draining load burst to an
overlapping address. Between *different* masters no ordering guarantee exists today (bank
arbitration already races them), and a *single* master cannot have a dependent store in
flight concurrently with its own load burst (the VLSU serializes per-instruction; scalar
same-address traffic is fence-synchronized; the MSHR additionally holds same-address traffic
during drain). Restricting the second context to loads makes the change conservative without
giving up the target scenario (same-address load bursts).

### 2.4 Issue scheduling
- Each cycle, the RR-selected context (if active and issuable) drives up to IssueWidth beats
  with today's prefix-ready semantics; per-context `beat`/`len` counters advance, per-beat
  `tgt_addr`/`meta_id` increment as today.
- If the selected context is inactive (or fully drained), the other context issues — no idle
  cycle is introduced when only one context is active (single-burst latency unchanged).
- Toggle `issue_ctx_q` every cycle in which the *selected* context issued at least one beat
  and the other context is active.

Effect on a same-cycle same-address pair (16 beats each):
- IssueWidth 3 (slave site): today completes (~6, ~12) -> interleaved (~11, ~12): completion
  skew 6 -> ~1. IssueWidth 1 (local site): (16, 32) -> (~31, ~32): skew 16 -> ~1.
- The leader finishes later (equalize, not accelerate): acceptable because the consumer is
  the per-beat latency-tolerant VLSU ROB, and pair alignment is precisely the objective.

### 2.5 Response-path safety
Interleaving reorders beats *between two loads* only. Every consumer of expanded-load
responses is order-insensitive by construction:
- group MSHR capture: per-beat `beat_seen` bitmap, explicitly out-of-order safe;
- ParityDrain bypass-retag: wrap-safe meta-id *range* match, order-insensitive;
- VLSU ROB0/TwinROB0: id-indexed writes;
- LIC response routing: per-beat `ini_addr`/`meta_id`, no ordering assumption.

### 2.6 Probes (translate_off, in the expander)
The same change carries the measurement of the phenomenon it fixes:
- `exp_wait_while_drain_cnt` : cycles a valid input waited while a burst drained (the raw
  skew-injection metric; free-running accumulator + max-single-wait).
- `exp_shadow_accept_cnt` / `exp_shadow_same_base_cnt` : second-context accepts, and the
  subset whose base address equals the draining context's base (the same-line pair case).
A `[BEXP]` one-line summary per instance at final, non-zero only.

## 3. Hardware cost
Per expander: one extra `req_t` register (~$bits(tcdm_slave_req_t) FF), one beat/len counter
pair, the RR toggle, and a 2:1 mux on the issue path. No new memories, no CAM, no response
path change. Instances: 3 slave + per-core local expanders per tile; cost is dwarfed by the
existing per-tile spill registers (and is zero when the knob is off).

## 4. Verification plan
1. Knob OFF: `sp-fmatmul-opt-burst-merge` EOC bit-identical (3836 with drain_beats=2,
   hold_window=0) — proves const-fold inertness.
2. Knob ON correctness: `sp-mshr-burst-test` PASS, 0 CMS warnings (CMS covers every core
   memory request incl. reordered beats); `sp-resp-bw-16core-sameaddr` and
   `sp-resp-bw-1core-local` microbenches.
3. Knob ON, matmul A/B vs 3836 (hold_window=0 pinned to isolate the variable): kernel
   cycles, MSHR merge rate + no-entry bypasses (expect merges UP if pair-skew is the
   coalescing limiter), `[BEXP]` wait/same-base counts (expect same-base accepts > 0 and
   wait-cycles collapsing vs OFF).
4. Assertions: both-active implies both loads; a context never issues beyond its len;
   ready_o never high with both contexts active.

## 5. Expected outcome / decision rule
If pair-skew injection at local lines is a first-order coalescing limiter, ON should raise
the burst merge rate above the 9.1%-of-entries baseline and cut cycles below 3836. If merges
move but cycles do not, the coalescing-vs-latency verdict of §5c stands and the win is
traffic/energy only. If the `[BEXP]` counters show same-base shadow accepts are rare on
matmul, the hypothesis is refuted cheaply — before any bigger investment (Option 2:
local-turnaround through the group MSHR, which composes with this change and additionally
dedups the bank traffic).
