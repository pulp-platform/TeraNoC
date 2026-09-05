# Group-MSHR timing rework: two planned changes

**Status 2026-09-05 05:15.** Both items below are **planned, not decided**. No RTL is written.
The decision gate is the segmented depth report (§5) plus the three OOC runs in flight. Read §6
before implementing either: several conclusions in earlier drafts were wrong and are corrected here.

---

## 0. Why

12,855 flops with ~1.05M cells of combinational logic between them — **66–100 cells per flop**,
where a well-pipelined design runs 5–20. It is one combinational stage. F1–F6 cut depth and area
within that structure (−33.5% instances) without changing it.

The 800 MHz target allows ~**31–37 gates per stage** (1.25 ns, less ~0.25–0.41 ns of setup + POCV +
clock network, at the 13.4 ps/point measured on the 500 MHz block run).

Register retiming cannot substitute: it relocates existing flops, never creates a stage. Confirmed —
`fix2_head_8p0` passed `logic_opto / Register Retiming` with the instance count unchanged.

### Measured depths (TCK 0.2 ns, corrected SDC)

| block | path points | ~gates | note |
|---|---:|---:|---|
| `free_way` | 8 | 4 | closes at a 0.2 ns period; **not a timing consideration**, and not on the request chain — its inputs are `mshr_q_valid`, `way_reclaimable`, `victim_rr_q` |
| `req_decode` | 14 | 7 | |
| `bank_arb` | 16–18 | 8–9 | |

Everything else below is a structural estimate.

---

## 1. WORK ITEM 1 — request path cut (LOOKUP | UPDATE)

### 1.1 The cut

```
S1  LOOKUP + ARBITRATE                        deep, global, all from mshr_q
    req_decode -> bank hash -> req_addr_hit_way (64 entries x 48 lanes)
    -> hit reduce -> bank_arb x2 -> winner per bank
    -> issue the NoC request, drive req_in_ready
    ============ pipeline register: the per-bank records ============
S2  UPDATE                                    shallow, local
    apply alloc / merge / byte-merge / replay / invalidate  -> mshr_d
```

### 1.2 Why this boundary and not request | response

**Every `mshr_d` write stays in one stage.** The intuitive request|response split does not have that
property: **16 entry fields are written by both paths** — `state`, `sub_reqs`, `sub_reqs_num`,
`beats_left`, `beat_seen`, `beat_done`, `beat_pending`, `beat_pending2`, `beat2_armed`, `resp_buf`,
`resp_buf_cnt`, `resp_buf_rd_ptr`, `hold_cnt`, `cacheable`, `valid`, `base_addr`, `burst_len`.
Straddling them costs a second write port on a 64-entry array plus a per-field merge rule.

The same objection kills a `capture | drain` split on the response side: **15 fields overlap** there.
Any workable cut in this module is a *decide | apply* cut, not a *phase A | phase B* cut.

### 1.3 What crosses the register — already built

F5 (`cfa44e1e`) introduced per-bank records so the door's entry writes apply once per bank. Those
records **are** the pipeline payload; registering them is the change.
Declarations: `mempool_group_mshr.sv:1921-1941`.

| record | fields | bits/bank |
|---|---|---:|
| `mgb_*` (merge) | `v, way, tile, port, core, meta` | ~17 |
| `agb_*` (alloc) | `v, way, addr, grp, len, tile, port, core, meta` | ~42 |

At `MshrBankNum = 16`: **~944 flops, +7.3%** on 12,855. Confirm `tcdm_addr_t` and `tile_core_id_t`
against the elaborated design rather than this table.

`mgb_slot` does **not** cross — it is recomputed from `mshr_q` and must stay that way, or the merge
slot is a cycle stale.

### 1.4 The hazard, and why it is cheap

A lookup in S1 at cycle *N+1* compares against `mshr_q`, which lacks the allocation recorded at *N* —
naively a duplicate entry for a line already in flight.

`req_bank = mshr_bank_of(req_addr_key, tgt_group_id)`, so **a line always hashes to one bank**, and
with one allocation per bank per cycle there is **at most one pending record per bank**. The bypass
is therefore a comparison against *that bank's* pending record only:

* **48 comparators, one logic level** — not a 16-way CAM per lane.
* On match: merge-into-pending (preferred) or stall. **Merge-into-pending costs no throughput**;
  stalling costs a slot, so build the former.

An address-independent bank hash would need the full CAM and the bypass would rebuild the depth the
cut just removed. This property is what makes the cut affordable.

### 1.5 Depth estimate

| step | gates |
|---|---:|
| `req_decode` | **7** |
| bank hash | ~3 |
| `req_addr_hit_way` (addr + group compare) | ~6 |
| 4-way hit reduce + decision | ~2 |
| `bank_arb` | **9** |
| decision mux -> record | ~3 |
| **S1** | **~30 ≈ 60 points** |
| **S2** (4:1 way select + field update) | **~5** |

`free_way` (4) is off this chain — parallel from registered state.
**~30 against a 31–37 budget is at the edge, and 20 of the 30 gates are estimated.**

### 1.6 Cost

| | |
|---|---|
| allocation latency | **+1 cycle** |
| merge / bypass latency | unchanged — issue the NoC request from S1; it does not depend on the entry write |
| throughput | **unchanged** — still one alloc + one merge per bank per cycle |
| sequential area | ~+944 flops (+7.3%) |

A pipeline retires one decision per cycle; the rate is unchanged and only latency grows.

---

## 2. WORK ITEM 2 — derive the whole response side from `mshr_q`

### 2.1 What is inconsistent today

The drain **selects** from registered state but **fetches data** from the in-cycle value:

| signal | source | knob |
|---|---|---|
| `drain_scan_valid` / `drain_scan_ent` | `mshr_q` | `DrainFromQ`, `group_mshr_drain_from_q ?= 1` (sim **and** backend) |
| `drain2_scan_valid` / `drain2_scan_ent` | `mshr_q` | `Drain2FromQ`, `?= 1` |
| `drv_data`, `drv_burst_one` | **`mshr_d`** | none — F6 hoist |
| `drv_sub_core`, `drv_sub_meta` | **`mshr_d`** | none |
| `beat_pending` seeding (`:2801`) | **`mshr_d`** | none |

Because the drive reads `mshr_d`, **capture and drain are serial**: capture writes
`mshr_d.resp_buf`, the drive reads it. Response path depth ≈ capture + drain ≈ 23 + 29 ≈ **52 gates**.

### 2.2 The change

Move `drv_*` and the `beat_pending` seeding to `mshr_q`. Then capture and drain become
**independent cones** and the response path is `max(23, 29) ≈ **29 gates**` — inside budget, with no
pipeline stage on the response side at all.

`drv_data` is safe by construction: the scan requires `resp_buf_cnt != 0` **in `mshr_q`**, and
capture writes at `wr_ptr` which for a selected entry is a different slot — so
`mshr_d.resp_buf[rd_ptr] == mshr_q.resp_buf[rd_ptr]` already.

### 2.3 The prerequisite — block a late merge

`drv_sub_*` and `beat_pending` are **not** safe today, because a merge can land in the very cycle a
beat arrives:

```systemverilog
req_merge_valid[t][p] = req_can_merge[t][p] && req_hit_mshr_sel_valid[t][p];
                        // req_addr_hit_drain is NOT in this path
```

`req_addr_hit_drain` gates only allocation candidacy (`:1194`) and the non-merge branch (`:2150`).
`req_hit_way` permits a merge while `mshr_q` shows `MSHR_WAIT_RESP && beats_left == burst_len` —
true at the start of the cycle a beat lands. That new subscriber then joins `beat_pending` via
`mshr_d`, and reading `mshr_q` instead would silently drop it.

**The fix is one line**, using a signal that already exists and already means
"this address's entry is draining, or has a response arriving this cycle / in flight"
(`StallOnResp = 1`):

```systemverilog
req_merge_valid[t][p] = req_can_merge[t][p] && req_hit_mshr_sel_valid[t][p]
                     && !req_addr_hit_drain[t][p];   // no late join once a beat is in flight
```

Then `mshr_d.sub_reqs == mshr_q.sub_reqs` for any entry with a beat in flight, **by construction**,
and the whole response side can read `mshr_q`.

**Cost**: a merge that would have landed in the beat-arrival cycle stalls one cycle and retries. With
burst hold windows of 2047 the collision window is ~1 cycle in hundreds — an argument, not a
measurement. Price it on the §4 baseline.

### 2.4 The consequence that decides this item: slot turnover

Admission is computed **before** the drain loop and reads `mshr_d`:

```systemverilog
mshr_resp_slots[e] = RespBufWords - mshr_d[e].resp_buf_cnt;          // :2458
cap_g1[e] = slots >= 1;   cap_g2[e] = slots >= 2;                    // :2550
resp_in_ready[t][p] = cap_first&&cap_g1 || cap_second&&cap_g2;       // :2590  -> MODULE OUTPUT
```

**CORRECTED 2026-09-05.** An earlier version of this section claimed the slot turns over inside one
cycle today "because the drain sees them in `mshr_d`". That is wrong: the drain's *scan* is
`mshr_q`-sourced (`DrainFromQ = 1` in sim and backend), so a beat captured in cycle N has
`mshr_q.resp_buf_cnt == 0` and **cannot be selected until N+1**. The turnover is ALREADY 2 cycles:

| cycle | admission sees | drain scan sees | cnt |
|---|---|---|---|
| N | 0 -> admits 2 | 0 -> drains nothing | -> 2 |
| N+1 | 2 -> **admits nothing** | 2 -> drains 2 | -> 0 |

So the design already sustains **1 beat/cycle per entry**, not 2, and `RespBufWords = 2` is sized for
that. Two consequences:

* Moving `drv_*` to `mshr_q` (§2.2) does **not** change turnover or bandwidth -- the scan already
  gates it. This objection was filed under the wrong item.
* Turnover only degrades further when a **pipeline register** pushes the scan another cycle back.
  That is where §2.5 applies, and only there.

### 2.5 Three ways to keep 2 beats/cycle — undecided

| option | mechanism | cost |
|---|---|---|
| **A. forward the freeing into admission** | `slots = RespBufWords − mshr_q.cnt + draining_this_cycle`. Legal *only* after §2.2, because the drain no longer depends on capture and can be computed first — the ordering constraint disappears | puts drain-select on the `resp_in_ready` **boundary** path: ~29+2+3+4 ≈ **39 gates to a port**, over budget |
| **B. `RespBufWords = 4`** | bandwidth × delay: 2 beats/cyc × 2 cyc | **+4,096 flops (+32% sequential)**, no depth cost |
| **C. credit-based ready** | registered handshake instead of combinational `resp_in_ready` | shortest path; an interface change beyond this module |

**A is not obviously right.** `resp_in_ready` is already a combinational module output, and the
`R2R-COST = 0.00 @ 8 ns` / `46.95 @ 2 ns` against `SETUP-COST` 115,331 / 216,090 suggests the
**boundary paths, not the reg-to-reg cone, are the binding constraint**. If `depth_split` confirms
that, A makes the real problem worse and B is the honest answer.

---

## 2A. WORK ITEM 2 — RESOLVED PLAN (2026-09-05)

§2.5 listed three options and picked none. **Decision: option B, `RespBufWords = 4`**, with the whole
response path sourced from `mshr_q` and no ready-to-ready path added.

### 2A.1 Why 4, and why it gives 2 words/cycle

The admission sees only registered state, so a slot's round trip is 2 cycles (capture -> register ->
scan sees it -> drain -> register -> admission sees it free). Bandwidth x delay: 2 beats/cycle x 2
cycles = **4 slots**. Verified in steady state:

| cycle | `mshr_q.cnt` | `slots = 4 - cnt` | admits | drain sees | drains | next cnt |
|---|---:|---:|---:|---:|---:|---:|
| N | 0 | 4 | 2 | 0 | 0 | 2 |
| N+1 | 2 | 2 | **2** | 2 | **2** | 2 |
| N+2 | 2 | 2 | **2** | 2 | **2** | 2 |

Settles at `cnt = 2` and holds **2 in / 2 out every cycle**, with no same-cycle coupling.
**3 slots does NOT work**: `slots = 3-2 = 1` caps admission at 1/cycle.

The rejected alternative (option A, feed the drain handshake back into admission) costs ~33 gates
`mshr_q -> resp_in_ready` **and** creates a combinational `resp_out_ready -> resp_in_ready` path
through the module -- an in2out ready chain that composes badly with whatever the tile side does.
4 slots costs ~3.1% area and no depth. On a design that is timing-limited, not area-limited, that is
the right trade.

### 2A.2 The change set

| # | site | now | becomes | note |
|---|---|---|---|---|
| 1 | `RespBufWords` `:33` | `NumRemoteRespPortsPerTile-1` = 2 | **4**, its own knob | the tie to port count is why it was 2 |
| 2 | `mshr_resp_slot_t.beat_off` `:465` | `[BurstLenWidth-1:0]` = 5 b | **4 b** (`$clog2(MaxBurstWords)`) + assertion | provably 0..15 when written |
| 3 | `drv_data`, `drv_burst_one` | `mshr_d` | `mshr_q` | |
| 4 | `drv_sub_core`, `drv_sub_meta` | `mshr_d` | `mshr_q` | |
| 5 | `mshr_resp_slots` `:2458` | `RespBufWords - mshr_d[e].resp_buf_cnt` | `mshr_q[e].resp_buf_cnt` | |
| 6 | `beat_pending` seeding `:2795` | `mshr_d` | `mshr_q` | **needs #7** |
| 7 | `req_merge_valid` `:1305` | `req_can_merge && req_hit_mshr_sel_valid` | `&& !req_addr_hit_drain[t][p]` | no late join once a beat is in flight |

**Commit split.** #1-#5 as one commit (expected cycle-identical except for the deeper buffer);
#6-#7 as a second (NOT cycle-identical -- it converts some merges into stall-and-retry). Splitting
lets the cycle-identity check attribute a regression.

**Not in scope:** the bypass `resp_in_ready = resp_out_ready` (`:2504`). Its ready path is 1-2 gates
(a `resp_is_mshr` mux) and its data path is a direct `resp_out = resp_in`. Nothing to gain; buffering
it would add latency where there is none.

### 2A.3 Cost

| | |
|---|---|
| `resp_buf` today | 2 x 64 x 37 b = 4,736 flops |
| after (#1 + #2) | 4 x 64 x 36 b = 9,216 flops |
| **net** | **+4,480 flops**, +32% on 13,988 registers, **~+3.1% total area** (sequential is 9.8% of 99,280 um2) |

`RespBufCountW` 2->3 b, `RespBufPtrW` 1->2 b, `mshr_rb_en[64][RespBufWords]` widens. The elaboration
guard `DrainBeatsPerEntry <= NumRemoteRespPortsPerTile-1` stays satisfied (2 <= 2).

### 2A.4 Three traps, all verified

1. **Do NOT narrow `burst_beat_of()`'s return type.** It is called inside `burst_beat_valid` on
   responses not yet proven in range; the 5-bit width is what makes an out-of-range raw value (16..31)
   fail `beat_of < len`. At 4 bits a raw 16 truncates to 0, passes the check, and a bogus response is
   accepted as beat 0 -- silent burst corruption. **Only the stored struct field narrows**, because a
   value is written there only after `burst_beat_valid` passed.
2. **`beat_off` cannot be shared or dropped.** Beats arrive out of order (`:31`, `:497` --
   multi-channel returns), so slot index != beat index. And it is not about ordering: the MSHR
   **multicasts**, retagging each beat per subscriber under the lane law
   (`core_id + beat%BurstLanes`, `meta_id_base + beat/BurstLanes`) -- the ROB places by tag, so a
   wrong tag is data corruption, not a reordering hiccup. It also selects the ParityDrain port
   (`1 + (beat & 1)`). The design already rejected the alternative (store `meta_id` + `core_id`,
   8 b vs 4 b).
3. **#5 reads a freshly-allocated entry's count from `mshr_q`**, i.e. the previous occupant's.
   `no_alloc_while_resp_landing` should make that unreachable -- **confirm the assertion actually
   covers it** before relying on it.

### 2A.5 Verification

1. Elaborate at both `MshrMergeReqs` (sim 16, PnR 4) -- `RespBufWords` interacts with neither, but
   the widened pointers touch the drain arithmetic.
2. Assertions live under Questa/VCS: `resp_src_exclusive`, `head_beat_must_match_subreq`,
   `beat_done_subset_seen`, `cached_entry_holds_data`, plus the new `beat_off < MaxBurstWords`.
3. **Cycle-identity for #1-#5** against the 8 baseline arms. A deeper buffer can only remove stalls,
   so cycles should be identical or better; a *slower* result means the disjointness argument behind
   #3/#4 is wrong somewhere.
4. **#6-#7 measured, not asserted** -- record the delta per shape.
5. Directed test: a burst sustaining 2 beats/cycle into one entry, to prove 2A.1 holds in RTL and not
   just on paper. Nothing existing covers it.
6. Re-run the segmented depth report on the changed RTL.

## 3. How the two items interact

They are independent and can land in either order.

* **Item 2 alone** reduces response-path depth ~52 -> ~29 with **no pipeline stage and no latency
  cost** — subject to resolving §2.5. It is worth doing even if item 1 never happens.
* **Item 1 alone** splits the request cone. It does **nothing** for the response path: `win_oh` and
  `free_id` appear **zero times** in the drain loop (`:2833-3239`). Verified.
* **Together** the module is `DECIDE | APPLY`: three parallel decide cones (request ~30, capture ~14,
  drain ~18) and one apply stage (~10–12). Stage 1 depth = max = ~30, not the sum.

If a third stage is ever needed, it goes **inside the request cone** (split compare from arbitrate) —
the capture and drain cones have 12–16 gates of headroom.

---

## 4. Pre-change baseline (running)

`b07ad73f`, 4x4 / `terapool_spatz4_fpu`, one arm per shape. The pipeline costs +1 cycle **per
allocation** and nothing on a merge, so M is the axis that matters — more rows means more independent
A fetches and less sharing.

| tag | shape | regime |
|---|---|---|
| — | fp16 256x32x256 | **2,923** measured (`gfw3`/`gfw4`) |
| `bl_n64` | fp16 256x64x256 | small N, high reuse |
| `bl_128` | fp16 256x128x256 | mid |
| `bl_256` | fp16 256x256x256 | square |
| `bl_512` | fp16 512x64x256 | wide M, small N |
| `bl_p512` | fp16 256x512x512 | large N and P |
| `bl_m1k` | fp16 1024x256x256 | allocation-heavy |
| `bl_m2k` | fp16 2048x256x256 | most allocation-heavy |
| `bl_f32` | fp32 256x32x256 | precision control |

**If the cost does not rise with M, the model is wrong and the result should not be trusted.**

> **ELF trap.** `s8_*` ELFs build `-DNUM_GROUPS=64 -DNUM_CORES=1024` (8x8) — **248 of the 785** under
> `hardware/elf/`. On this 4x4 config they produce no error, just wrong addresses and a wrong work
> split. Every ELF above was verified `-DNUM_GROUPS=16 -DNUM_CORES=256` from its own
> `/tmp/claude-620771/gemmbuild_*.log`. Verify; never infer from the filename.

Arm provenance now records **all four** MSHR source md5s plus the git SHA — the parent md5 alone is
unchanged by a submodule edit, which is why `gfw3`/`gfw4` had to be told apart by vlog start time.

---

## 5. The decision gate

Neither item is decided until `ooc/depth_split.tcl` runs. It needs **no RTL change** — inserting a
register splits an existing path, so both stage depths are already in the netlist:

```tcl
# S1
report_timing -delay_type max -max_paths 5 -input_pins -nets \
  -from [get_pins mshr_q_reg*/CK] \
  -to   [get_pins {i_alloc_arb/win_oh_o* i_merge_arb/win_oh_o* i_free_way/free_id_o*}]
# S2
report_timing -delay_type max -max_paths 5 -input_pins -nets \
  -from [get_pins {i_alloc_arb/win_oh_o* i_merge_arb/win_oh_o* i_free_way/free_id_o*}] \
  -to   [get_pins mshr_q_reg*/D]
```

Armed to fire when `fix2_head_8p0` saves its `logic_opto` block.

**A saved block can come back with no scenario enabled for setup**, in which case `report_timing`
returns an empty report that reads like "no violations" — the script enables setup explicitly and
prints the timing-path count first.

### What each outcome implies

| `depth_split` says | do |
|---|---|
| request cone critical, S1 ≈ 30 | build item 1; item 2 optional |
| drain cone critical | item 2 first — item 1 cannot help it |
| **boundary paths critical** | neither cut first; §2.5 option A is counter-productive, and the 8,988-port interface is the real problem |

Three OOC runs are in flight: `fix2_head_8p0` / `fix2_head_2p0` (HEAD, 8 ns and 2 ns, both in
`logic_opto / Optimization (2)`, 1,078,569 instances) and `base2_8p0` (baseline, tech mapping,
1,269,127). Post-mapping HEAD is +27.8% over its constant-propagation count, matching the +26.4% the
old F6 run showed.

---

## 6. Corrections to earlier drafts

Recorded because each was wrong in a way that would have led to a wrong design.

1. **"`capture | drain` is a clean split."** False — 15 fields overlap, same as request|response.
2. **"A beat holds its slot ~1 cycle, so merging makes residency longer."** Both halves wrong.
   `num_cores_per_tile = 1`, so subscribers of one entry are in **different tiles**, and
   `DrainMultiPort = 1` serves them **all in one cycle**. Merging does not extend residency.
3. **"`resp_buf` could be replaced by the pipeline register."** No: `beat_done[b]` means "drained to
   **all** merged requesters", and `beat_pending` is a per-subscriber bitmap. It is **fan-out
   storage** held for a variable number of cycles, not a pipeline stage.
4. **"Today's residency is 0 — the beat passes through combinationally."** No: the scan is already
   `mshr_q`-sourced, so a beat captured in cycle N is not selectable until N+1. Residency is exactly
   1 cycle and the 2-slot buffer is sized precisely for it.
5. **"The pipeline reduces bandwidth."** It does not. A pipeline retires one item per cycle. What
   reduces bandwidth is a **buffer sized for the old latency** — bandwidth × delay. Fix the buffer
   (or the turnover) and full bandwidth returns.
6. **"Forward capture into drain."** Wrong direction once §2.2 lands: the drain no longer depends on
   capture, so it is the **admission** that must see the drain (§2.5 A).
7. **"Today the slot turns over inside one cycle."** No -- the drain scan is already `mshr_q`-sourced,
   so turnover is already 2 cycles and the per-entry rate is already 1 beat/cycle. See the correction
   in §2.4. The bandwidth objection belongs to the pipeline register, not to the `mshr_q` conversion.
8. **"The `mshr_q` conversion buys ~52 -> ~29 gates."** That figure is for the FULL decoupling
   (including the `beat_pending` seeding and the merge gate). The conversion alone leaves the
   scan->select cone shared between the drive and the `resp_buf` update, so the realistic gain is
   ~26 -> ~20 gates on that path. Modest and bounded, not the headline number.

---

## 7. Verification contract

1. **Elaborate at both configurations** — sim (`merge_reqs=16`, `cfg_runtime=1`, `enable_stats=1`)
   and PnR (`merge_reqs=4`, `cfg_runtime=0`, `TARGET_SYNTHESIS`). `MshrMergeReqs` is an elaboration
   constant; a change can be correct at 16 sub-request slots and broken at 4.
2. **Assertions live**, under QuestaSim or VCS — never Verilator, never `TARGET_SYNTHESIS`.
   Relevant here: `mshr_entry_in_its_bank` (the bank-hash property §1.4 relies on),
   `no_alloc_while_resp_landing`, `cached_entry_holds_data`, `resp_src_exclusive`,
   `head_beat_must_match_subreq`, and the `no_late_join_burst` rule under the stricter §2.3 gate.
3. **New directed tests** for the cases these changes introduce:
   * two same-line requests in consecutive cycles, and across a bank-full boundary (§1.4);
   * a merge attempt in the exact cycle a beat arrives (§2.3) — must now stall and retry;
   * a burst sustaining 2 beats/cycle into one entry, to prove §2.5 keeps the rate.
4. **Cycle comparison against §4**, same ELFs and config. These are **not** expected to be
   cycle-identical — record the delta per shape rather than asserting equality. The §2.2 `mshr_q`
   conversion *alone* should be cycle-identical; check that separately, first.
5. **Standalone synthesis** at the PnR config, and re-run §5 on the changed RTL to confirm both
   stages land inside budget.
