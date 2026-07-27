# Raising Spatz memory-level parallelism — design & implementation plan

**Status:** DRAFT FOR REVIEW. No RTL written for this plan yet.
**Target:** `terapool_spatz4_fpu`, 256 cores. Spatz files under
`working_dir/spatz/hw/ip/spatz/src/` (the **compiled** Spatz, via `Bender.local`).
**Primary constraint (user):** minimise hardware overhead — **backend timing and area above all**.

> **FACT** = read out of the RTL and re-verified. **PROPOSAL** = not yet written.
> Line numbers are current as of this session (`spatz_vlsu.sv` shifted +11 after the
> `burst_mode_req` gate fix landed earlier today).
>
> This plan was produced from a 10-agent audit (4 RTL audits → 3 competing designs →
> 3 adversarial reviews under correctness / backend-timing / integration lenses).
> Where the reviewers disagreed, §5.0 states the disagreement and the resolution.

---

## 1. The problem

The FPU is **busy 72.6% / idle 24.5%**. Not bandwidth (NoC **15% utilised**, 6.5x headroom), not
compute headroom (floor is 69%). It is **memory-level parallelism**:

```
load latency                L = 109 cyc
FPU work fed by one load    W =  64 cyc      (kernel_size x vl / 4 FPUs = 8x32/4)
required loads in flight  L/W = 1.70
actual   loads in flight        1.23      <-- the entire deficit
predicted idle = 1 - 1.23/1.70 = 28%      (measured 24.5%; the model fits)
```

Load recurrence today `T = L/N = 88.6 cyc`; target `T = W = 64`. **We must remove ~24.6 cycles.**

**FACT (reviewer 3, from `main.c:241-243`):** at `kernel_size=8` the kernel is `e32,m2` ⇒ vl = 32
elements = 128 B = **32 words = exactly two full 16-word bursts, no tail**. This matters because the
whole payoff below is *per burst*.

---

## 2. The lever: block ROB-id reservation

**FACT** (`spatz_vlsu.sv:1190-1201`) — ROB ids are allocated **one per cycle**:

```systemverilog
// Allocate one ROB ID per cycle for the burst.
if (burst_alloc_q[port] && (burst_alloc_cnt_q[port] < burst_len_q[port])) begin
  if (!rob_full[port] && !offset_queue_full[port]) begin
    burst_alloc_fire[port]  = 1'b1;
    if (burst_alloc_cnt_q[port] == '0) burst_base_id_d[port] = rob_id[port];
    burst_alloc_cnt_d[port] = burst_alloc_cnt_q[port] + 1'b1;
  end
end
```

and `burst_send` (`:1206-1208`) waits for the **full** count before the single request handshake. So
every 16-beat burst pays a **16-cycle serial walk** before its request leaves the core:
**18 cycles from eligibility to handshake.** Block reservation makes it **3** (decide → reserve →
send), saving **15 cyc/burst = 30 cyc/load** on the exact recurrence we are short on.

Three FACTs make this cheap rather than expensive:

**2.1 The length is binary.** `burst_len_calc` (`:932-937`) emits only `MaxBurstWords`(16) or 1.
With `NumWords = 32` and `16 = NumWords/2`, `wp + 16 (mod 32) == {~wp[4], wp[3:0]}` — **one
inverter**, cheaper than the `wp+1` incrementer it parallels.
*(Audit-2 caveats: `burst_len_calc` has a third literal `'0` at `:901` that is never consumed;
`burst_len_eff` can take 2..15 via the `rob_full` clamp at `:938-941` but is consumed only as a
`> 1` predicate and never reaches a wire.)*

**2.2 Bursts are port-0 only.** `burst_mode_req` now requires `mem_use_port0_burst` (the gate added
this session); independently ports 1-3 fail `burst_addr_aligned` because their first address is
`rs1 + port*4` (`:564`). **Only ROB0 ever sees a block reservation** ⇒ new logic is 1 instance per
core, not 4.

**2.3 It deletes more than it adds.** Block reservation makes `force_send` **structurally
unreachable**, which removes the `:1411-1424` rescue branch, the `burst_len_eff` clamp, and collapses
`spatz_mem_req.burst_len` to a **compile-time constant**.

---

## 3. Area

**FACT** — widths read from RTL: `ELEN=32`, `NumWords=NrOutstandingLoads=32`, `IdWidth=5`,
`NrMemPorts=4`, `NrParallelInstructions=4`, `VLEN=512` ⇒ `vlen_t=10 b`, `vreg_t=5 b`,
`spatz_id_t=2 b`, `vew_e=3 b` (`rvv_pkg.sv:13-18`) ⇒ **`commit_metadata_t` = 37 bits**
(`spatz_vlsu.sv:384-399`). Per-core VLSU flop total **7639** (1.96 M at 256 cores); dominant terms
4x `mem_q` = 4096 (53.6%), spill registers 1414 (18.5%), commit FIFO 1200 (15.7%).

### 3.1 The two reclaims that pay for everything

**R1 — `id_valid_q` is provably redundant. CONFIRMED.**
Audit 1 proved it by induction over all six state-mutating paths **and** cross-checked with a
cycle-exact model of the `always_comb` (statement order preserved) over **3 configs x 400 seeds x
800 cycles, zero violations**. Ids are allocated/freed strictly in order, so the allocated set is
always the contiguous ring `[read_pointer_q, write_pointer_q)` whose cardinality **is**
`status_cnt_q`. Therefore

```systemverilog
id_valid_o = id_valid_q[write_pointer_q] & id_valid_q[write_next_ptr]   // :83
           ==  (status_cnt_q <= NumWords-2)                             // EXACT, both boundaries
```

Boundaries check out: at `cnt==31` the only free slot is `wp` itself so `write_next_ptr == rp` is
allocated → 0, and `(31<=30)==0`. At `cnt==32` (full) → 0, and `(32<=30)==0`. The threshold must be
`NumWords-2`, not `-1`: `:1193-1195` documents that `rob_id_valid` demands **two** free ids.

Two incidental FACTs that remove concerns: **`FallThrough` is never 1** for any `reorder_buffer`
instance (not in the port map at `:256-282`, defaults to `1'b0`), and `reorder_buffer` has **exactly
one instantiation** in the repo.

**R2 — the commit FIFO is 8x oversized.** `DEPTH = NrOutstandingLoads = 32` (`:412`), but the push at
`:455` is gated on `!mem_insn_pending_q[mem_spatz_req.id]` and `spatz_id_t` is 2 bits ⇒ **at most 4
entries can ever be resident**; 28 of 32 are unreachable silicon. Measured occupancy today: 1.

### 3.2 Net area

| item | flops/core |
|---|---:|
| − `id_valid_q` removal (x4 ROBs) | −128 |
| − commit FIFO `DEPTH` 32→4 | −1045 |
| − block reservation (`burst_len_q`+`burst_alloc_cnt_q` out, `burst_reserved_q` in) | −9 |
| + H1 gate state | +7…+16 |
| **NET** | **≈ −1157** |
| **chip-wide (x256)** | **≈ −296,000 flops = −15.1% of the VLSU flop budget** |

Plus ~1300 mux2/core of combinational reclaim. **The design is decisively area-negative.**

> **Honesty note:** R1 and R2 change the netlist **even with every performance knob off**, so they
> cannot sit inside a "bit-identical when disabled" proof. They are separately knobbed and separately
> committed (§7).

---

## 4. Timing

**FACT (audit 3) — the VLSU critical path is NOT in the ROB.** Ranked, in 2-input-gate-equivalent
levels, flop-to-flop:

| levels | cone |
|---:|---|
| **~30-35** | **CONE A (worst):** `mem_counter_q` → stride multiply (`:545/:562/:564`) → 32-bit `+rs1` (`:567`) → `~\|addr[5:2]` (`:946`) → `burst_mode_req` (`:960-965`) → `burst_use` (`:970`) → `mem_req_lvalid` (`:1405`) → `mem_pending_d` adder (`:1104`) |
| ~25 | **existing** `burst_len_calc` → ROB pointer route (`:932→:937→:964→:970→:1401→:1403→` ROB `:103`) |
| ~24 | retire cone (`commit_counter_q` → … → `vrf_req` spill) |
| ~14 | commit/pop loop |
| ~9 | `id_valid_o` → `mem_req_lvalid` |
| ~3 | ROB id-request path |

Three consequences, all favourable:

**T1 — R1 is a timing WIN of ~6 levels.** `id_valid_o` today is a 5-bit incrementer (~3) → two 32:1
muxes (~5) → AND (~1) ≈ **9 levels**, and it is a real closing path: it feeds `rob_id_valid` →
`mem_req_lvalid` (`:1429`) and `rob_req_id` (`:1451`), which loops back into the ROB's own
`status_cnt_d` in the same cycle. The replacement `status_cnt_q <= 30` is **2-3 levels**.
Additionally **`write_pointer_q` fanout drops ~3x** (two 31-mux2 select trees, the 5→32 decoder and
`write_next_ptr` all disappear) — the largest single fanout improvement in the plan, and free.

**T2 — the "reserve 16" input creates NO new path.** `burst_len_calc` **already** reaches the ROB
pointer today, by a **longer** route (~25 levels via `burst_use`). Driving it directly is ~16.

**T3 — the one genuine timing risk, and its exact mitigation.** If the room check is built as the
natural `(NumWords - status_cnt_q) >= id_req_len_i`, then `burst_len_calc` (~13 levels) enters
`full_o`'s cone and propagates to `mem_pending_d` ≈ **28 levels — comparable to cone A. That would be
a regression.** Mitigation is exact and cheap: the length is a **one-bit decision** (§2.1), so the
room check is not a variable comparison at all —

```systemverilog
room_block_o = (status_cnt_q <= NumWords - BlockWords);   // = (status_cnt_q <= 16)
```

~2 levels from a flop, with **zero dependence on `burst_len_calc`**, exposed as its own output.

> **⚠ The `<=` is load-bearing, not stylistic.** After burst 1's handshake `status_cnt_q` is
> **exactly 16**. A strict `<` silently **re-serialises the two bursts of every vl=32-word load** —
> and the symptom is *"the change did nothing"*, not a failure. This single character is the
> difference between the full 30 cyc/load and half of it.

---

## 5. Design

### 5.0 The reviewers' disagreement, and the resolution

Correctness and integration reviewers recommended **Option 1** (minimal, block reservation only);
the backend-timing reviewer called Option 1 "strictly dominated" and recommended **Option 2**. The
disagreement is entirely about **where the block request is driven from**:

* Option 1 put `rob_req_block` inside the `if (burst_use[port])` guard — **safe** (single source
  with `rob_req_id`, immune to the F2 divergence bug) but **slow** (+1-2 levels *after* a ~25-level
  arrival).
* Option 2 drove it from registers — **fast** (~4 levels) but split the drive across two locations,
  which is exactly the F2 silent-corruption bug.

**Resolution — take both properties, they are not actually in conflict.** Drive the reservation from
the **registered** decision (`burst_alloc_q && !burst_reserved_q`, both flops, ~4 levels), and give
the ROB its **own internal room guard** so a VLSU-side bug cannot corrupt it. This is what §5.1
specifies. It is Option 1's safety structure with Option 2's arrival time.

The 3-cycle sequence — **decide** (cyc 0, combinational) → **reserve** (cyc 1, from a register) →
**send** (cyc 2) — is what makes this possible. Collapsing it to 2 cycles is the one variant to
avoid: it drags `burst_use` (cone A) into the ROB pointer update.

### 5.1 Increment 0 — block ROB-id reservation *(the main lever)*

**Knob:** `spatz_vlsu_block_alloc` → `SPATZ_VLSU_BLOCK_ALLOC`, default 0. Every added statement
guarded by a `(BlockWords > 1)` elaboration constant ⇒ OFF is bit-identical.

**`reorder_buffer.sv`** — new parameter `BlockWords` (default 1 = feature absent), new ports
`id_req_block_i`, `room_block_o`, `block_mask_o`. Then:

```systemverilog
// Room for a whole block. NON-STRICT <= : see the warning in §4/T3.
assign room_block_o = (BlockWords > 1) ? (status_cnt_q <= (NumWords - BlockWords)) : 1'b0;
assign block_fire   = (BlockWords > 1) && id_req_block_i && room_block_o;
```

and the allocation becomes an **if / else-if** so block and single are mutually exclusive by
construction:

```systemverilog
if (block_fire) begin
  write_pointer_d = id_t'(write_pointer_q + BlockWords);   // = {~wp[4], wp[3:0]}
  id_valid_d      = id_valid_q & ~block_mask;              // omitted entirely under R1
  status_cnt_d    = status_cnt_q + BlockWords;
end else if (id_req_i && !full_o) begin                    // ...unchanged legacy path
```

plus the coincident-pop fixups (`+BlockWords-1` for a single pop, `-2` variant for dual-pop),
mirroring the existing `:152-155` structure.

**The window mask** (needed only if R1 is *not* taken — under R1 `id_valid_d` disappears and the mask
is needed only for `burst_odd_expected`). **Correction C1 from the timing reviewer:** the tempting
form `~({16{1'b1}} << wp[3:0])` is a **variable left shift = a 4-stage barrel shifter, ~160 GE / 4
levels — not ~20 GE / 2 levels as first written (off by 8x).** Use the per-bit compare form instead,
exploiting `BlockWords == NumWords/2` so that "(i − wp) mod N < N/2" is just the msb of the
difference:

```systemverilog
// lo half:  block_mask[i] = ~(wp[IdWidth-1] ^ lt[i % BlockWords]);
// hi half:  block_mask[i] =  (wp[IdWidth-1] ^ lt[i % BlockWords]);
```
one shared thermometer decode + one XOR per bit.

**`spatz_vlsu.sv`** — replace the walk (`:1190-1201`) on port 0 only with a registered
`burst_reserved_q`; `burst_send` becomes `burst_alloc_q && burst_reserved_q`. **Keep the legacy walk
as the `else` of the *block condition*, not of the *port test*** (correction 2 from the correctness
reviewer) — otherwise any condition that holds `room_block_o` low latches `burst_alloc_q[0]=1`,
keeps `burst_use[0]=1`, and makes the scalar arm at `:1425` unreachable.

**`burst_odd_expected`** (`:1077-1080`) must write 16 bits at once. Beat `k` has parity `k[0]` at id
`base+k`, so the set bits are the ids in the window whose LSB differs from `base[0]`:

```systemverilog
burst_odd_expected_d = (burst_odd_expected_d & ~block_mask) | (block_mask & alt);
                       //  alt[i] = i[0] ^ rob_id[0][0]  -> a 2:1 mux of two constants
```

**Use the masked write, not `|=`.** Both the correctness and integration reviewers flagged this
independently: the OR is provably exact *today* but relies on a **whole-module** invariant ("a free
id always has its odd bit clear") that a future edit to the drain paths (`:1443`, `:1522`) can break
without touching this line — and its failure mode is **silent wrong data** on 256 cores. The masked
form is a **local** invariant for ~32 AND2/core (~0.03% of the VLSU). Note the legacy line it
replaces *did* write 0 for even beats, so `|=` would be a behavioural downgrade.

### 5.2 Increment 1 — R1, `id_valid_q` removal *(area + timing, independent)*

Knob `spatz_rob_cnt_idvalid`. Replaces `:83` with `status_cnt_q <= NumWords-2` and deletes the
bitmap, its 5→32 decoder, two 32:1 muxes and `write_next_ptr`. Independently LEC-able against the
legacy ROB. Synergy: it also removes the `id_valid_d &= ~block_mask` term from Increment 0.

### 5.3 Increment 2 — R2, commit FIFO `DEPTH` 32→4 *(area, independent)*

Knob `spatz_vlsu_commit_qmin`. `DEPTH = NrParallelInstructions`. Also removes a 37-bit 32:1 read mux
(~3 levels) from the retire cone head.

### 5.4 Increment 3 — H1 dual load in flight *(defer; see §6.2)*

**FACT (audit 4): H1 needs ZERO new flops.** The exact trigger — "previous op's requests all
issued" — already exists, registered and validated, as `mem_req_all_issued` / `spatz_mem_req_sent_o`
(`:672-687`); the request/commit counter split (`mem_counter_load = commit_insn_push` `:982` vs
`commit_counter_load = commit_insn_pop` `:855`) and the id-indexed 4-wide bitmaps (`:374/:378`) were
**already designed for multiple in-flight instructions**. H1 is a *re-keying of existing state*.

It is nonetheless **deferred**, because the review found five fatal flaws in the full-H1 design
(§6.2) and one honest structural cost: the odd-expected aliasing fix requires gating the early
release on `mem_pending_q[1..3] == 0`, **which for a tailed load costs most of the H1 benefit**.
That price should be understood before anyone starts.

### 5.5 Increment 4 — software `e32,m1` + 16 accumulators

Unchanged from the earlier plan; MSHR-profile-neutral (16 B keys + 16 A keys per step, same as
`ks=8`). Only route to two loads simultaneously ROB-resident. Blocked behind the `ks=4` hang debug.

---

## 6. Correctness

### 6.1 Assertions to arm before the first A/B run

| # | property | catches |
|---|---|---|
| **A1** | `spatz_vlsu.sv:1439` — **fix the source**, don't just assert: add the `!rob_empty[port]` guard that the structurally identical store drain at `:1523` already has | ROB pop underflow. `status_cnt_d = cnt-1` at `cnt==0` wraps a 6-bit counter to **63**, after which `full_o` never asserts, `empty_o` never asserts, and every subsequent store hangs. One line; removes two whole fatal-flaw classes |
| **A2** | `pop_no_underflow`: `(pop_i \|\| pop_dual_i) \|-> !empty_o` | the same, defensively, inside the ROB |
| **A3** | `block_fire \|-> room_block_o` (**non-strict**) | the ROB gating on `full_o` (cnt≤31) instead of room (cnt≤16) → `status_cnt_d = 47`, no wrap, **15 slots double-allocated** |
| **A4** | `!(id_req_block_i && id_req_i)` | block/single divergence → silently dropped single-id alloc → wedged scalar path |
| **A5** | `rob_req_block[0] \|-> (mem_operation_valid[0] && burst_use[0])` | the F2 class: block reserved but `rob_req_id` not asserted → ROB never advances → 16 responses push into slots it believes free |
| **A6** | `blk_odd_clean`: `block_fire \|-> ((burst_odd_expected_q & block_mask) == '0)` | window overlapping live odd-expected bits → a port-1 response diverted into ROB0 while ROB1's real entry never arrives: **wrong data in vd AND a stalled ROB1** |
| **A7** | `cnt_ptr_coherent`: `status_cnt_q` vs `(wp − rp) mod N` | the invariant the whole of R1 rests on |
| **A8** | keep `:1660-1662` (`(\|burst_odd_expected_q) \|-> !rob_req_id[1]`) armed | its own comment names H1 as the tripwire condition |

**Do not weaken any of these to make a build pass.**

### 6.2 The five fatal flaws found in full-H1 (why §5.4 is deferred)

All are in the full-H1 option; **Options 1 and 2 had no wrong-data or hang path any reviewer could
construct**.

* **F1 (hang, no assertion fires).** Deleting the `mem_pending` clear at `:1093-1094` removes the
  only escape from a self-locking state: `:1435` is the *only* drain for an inactive port and
  `:1110`'s decrement requires `rob_pop`. The proposed tripwire cannot fire in the wedge because
  `commit_insn_valid` is 1 there.
* **F2 (wrong data → hang).** `rob_req_block` and `rob_req_id` driven from different places with
  different guards → `status_cnt` underflow (see A1/A5). The ROB's existing `full_write` assertion
  only checks `id_req_i`, so it stays silent.
* **F3 (wrong data).** Block branch gated on `!full_o` rather than `room_block_o` (see A3).
* **F4 (hang).** Deleting the `:1411-1424` rescue branch while the burst clear still requires
  `mem_req_lvalid`.
* **F5 (silent wrong data).** Odd-expected aliasing with the previous instruction's in-flight
  port-1..3 responses; the proposed `opq_odd_block` is insufficient (see §5.4).

---

## 7. Staging

Each step is independently revertible, independently measurable, and separately committed.

| # | change | knob | risk | expected |
|---|---|---|---|---|
| **0** | `A1` — the `!rob_empty` guard at `:1439` | none (bug fix) | none | no perf change; removes two fatal classes |
| **1** | **Increment 0** block reservation + A3-A6 | `spatz_vlsu_block_alloc` | low | **−30 cyc/load**; the headline |
| **2** | **Increment 1** `id_valid_q` removal + A7 | `spatz_rob_cnt_idvalid` | low (proven + modelled) | −32.8 k flops, −6 levels |
| **3** | **Increment 2** commit FIFO 32→4 | `spatz_vlsu_commit_qmin` | low | −267 k flops, −3 levels |
| **4** | GO/NO-GO on measurement, then H1 | — | high | see §5.4 |

**Bring-up order for step 1:** (i) knob OFF ⇒ cycle-identical to HEAD, zero `[VPERF]`/`[CMS]`/`[LP]`/
`[BP]` deltas; (ii) knob ON with a store-heavy and a strided kernel — must be a no-op; (iii) knob ON
with sp-fmatmul, watching A1-A6, then `[GroupMerge]`, then wall clock.

**Reminder:** `make compile` silently skips `vlog` after a `.sv` edit. `rm build_X/compile.tcl` and
confirm with `grep -c "Compiling module"` (expect **533**) and `grep "** Error"`. Exit code 0 is not
evidence.

---

## 8. Risks and honest caveats

1. **The 30-cycle figure is an upper bound.** It assumes `L` shrinks 1:1 with the walk. Under
   256-core NoC congestion part of `L` is *queueing*, which does not shrink linearly when the
   offered rate rises. Two bursts x 15 cyc = 30 against a 24.6-cycle gap says block reservation
   *could* close it alone — treat that as the optimistic end, not the estimate.
2. **`<=` vs `<` in the room check** (§4/T3). Getting this wrong halves the win and looks like a
   null result rather than a bug.
3. **Forward progress at the new threshold.** The start gate moves from "1 free slot" to "16 free
   slots"; the fallback to the legacy walk must remain reachable (§5.1).
4. **Integration is clean — verified, not assumed.** MSHR traffic *shape* is bit-identical (only
   arrival time moves); the merge window is safe because the legacy walk is deterministically 16
   cycles for every core, so all cores translate by the same −15/−30 and **inter-core skew, which is
   what merging keys on, is preserved exactly**; ParityDrain margin *grows* by 15 cycles; the
   per-type bank shift mapping is unchanged (the two bursts of a load are 16 words apart ⇒
   `word[7:4]` differs by 1 ⇒ adjacent distinct banks, so a core never self-conflicts).
5. **R1/R2 are not bit-identical when disabled** — they are netlist changes by construction, hence
   their own commits and their own LEC runs.
