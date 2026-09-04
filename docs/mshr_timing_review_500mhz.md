# Group-MSHR timing & design review — 500 MHz placement shakedown

**Block** `mempool_group_floonoc_wrapper` (16 tiles + group MSHR + FlooNoC routers)
**Flow** top-down Fusion Compiler X-2025.06, TSMC N7, TCK = 2.0 ns, post-placement
**Corner** `func_ssgnp_0p675v_m40c` (critical — see §0.1)
**Module** `hardware/src/mempool_group_mshr.sv` → `i_mempool_group/gen_group_mshr_i_group_mshr`

**Versions placed** TeraNoC `6fee18d8` (`zexin/teranoc_spatz_mshr`) · Spatz `f4275416` · FlooNoC `3b2f7bf`.
Elaboration defines read back from `tsmc7/fusion/tmp/analyze.tcl`:
`GROUP_MSHR_NUM=64`, `MERGE_REQS=4`, `WAYS_PER_BANK=4` (→ 16 banks), `DRAIN_BEATS=2` (ParityDrain on),
`BANK_PUBLISH=1`, `DRAIN_FROM_Q=1`, `CACHE_RECLAIMABLE=0`, `CACHE_SELF_INVAL=1`, `STALL_ON_RESP=1`,
`RESP_WAIT_SUBS_SINGLE=1`, `HOLD_WINDOW_BURST=2047`, `HOLD_WINDOW_SINGLE=0`, `SERVE_TIMEOUT=2047`,
`CFG_RUNTIME=0`, `ENABLE_STATS=0`, `TARGET_SYNTHESIS` defined.
Derived: `NumRemoteReqPortsPerTile=3`, `NumRemoteRespPortsPerTile=3` → **32 request lanes and 32
response lanes** per group (16 tiles × ports 1..2); `RespBufWords=2`.

Line anchors below are **HEAD (`aabfe319`)** unless marked *(placed)*. The always_comb of interest is
unchanged in structure between `6fee18d8` and HEAD (HEAD's +448 lines are the lane-retag /
bypass-track work); every finding applies to both.

---

## 0. Executive summary

1. **80.8 % of every violating endpoint in the block (18,400 of 22,776) is inside the group MSHR.**
2. The `-9.44 ns` cone is **not** a CAM ripple, **not** a first-free priority chain, and **not** a
   64-entry ripple. Path depth is **808–835 levels regardless of which entry the path ends at** — an
   entry ripple would make depth track the endpoint index. It is one serial chain: ~10 sequential
   read-modify-write passes over the whole `mshr_d[64]` array inside a **single 1,275-line
   `always_comb`** (`mempool_group_mshr.sv:3175-4450`), several of which are themselves 32-deep over
   the (tile, port) lanes.
3. **The clock gate is a red herring.** The CG `E` pin's required time is 1.631 ns against
   1.674–1.795 ns for the entry `D` pins — the gate costs **0.10 ns of a 9.44 ns violation**.
   Deleting every clock gate in the MSHR would move WNS from −9.436 to about −9.34.
4. **Nothing here is a constraints problem.** `constraints/base.sdc` carries only `wake_up_i*`,
   `rst_ni`, and an I$-L0 multicycle. Every path in the cone is a same-cycle valid/ready decision
   (`req_in_ready`, `resp_in_ready`, `resp_out_valid`) or the entry update that must accompany it. A
   `set_multicycle_path` on any of them would break the handshake contract. (One legitimate
   exception is listed in §5.)
5. The path is **depth-limited, not drive- or wire-limited**: 13.4 ps/level, dead flat
   (stage 50 → 1.108 ns, stage 800 → 10.600 ns), 1,640 of 1,648 cells ULVT, 100 % 2-input
   NAND/NOR/INV/AOI. The optimiser has nothing left. **Only RTL restructuring moves this.**
6. The area tells the same story: the MSHR is **175,428 µm², 23 % of `i_mempool_group`'s
   standard-cell area**, with **comb : seq = 163,207 : 6,705 = 24.3 : 1** for a structure holding
   64 × ~110 bits ≈ 7 k flops. That ratio *is* the 64-way scatter/gather network, replicated once per
   pass and then sized to ULVT max-drive to chase the depth.

---

## 0.1 Reading the two reports

The `..._m40c.rpt` and `..._125c.rpt` files are the **same multi-scenario dump** (`-report_by design`,
one row per endpoint at *its own worst* scenario): 17,452 rows worst at m40c, 5,324 worst at 125c,
22,776 total. So the 125c file does **not** show the −9.4 cone with a hot-corner number — those
endpoints are simply reported at m40c. **m40c is the critical corner** (N7 temperature inversion at
0.675 V). Everything below is the m40c figure.

---

## 1. Path-class map — report (1) → RTL

| # | endpoints (m40c / 125c) | WNS | max arrival | RTL source |
|---|---|---|---|---|
| **A** | 13,071 / 8 | **−9.436** | 11.23 | MSHR entry array `D` + CG `E` + `mshr_q_valid` — the finalize/dealloc tail of the big `always_comb` |
| **A′** | 1,376 / — | −9.381 | 11.51 | `i_spill_resp_out` — drained response *data* out of `mshr_d[sel].resp_buf[]` |
| **B** | 91 / 6 | −5.322 | 6.94 | `i_spill_resp_in` — `resp_in_ready` / `mshr_resp_slots` back-pressure |
| **C** | 700 / 1,988 | −1.569 | 3.77 | `i_spill_req_out` — the request door + hold-replay walker |
| **D** | — / 1,160 | −1.322 | 3.41 | `bypass_track_q` clock-gate enables |
| **E** | 1,904 / 2,067 | −2.050 | 4.21 | tile-internal: `i_spatz/i_vrf/.../wdata_q_reg` — **not the MSHR** |
| **F** | 310 / 95 | −0.269 | 2.34 | routers / DMA / L1 — marginal, closes with normal opto |

**MSHR total: 18,400 endpoints = 80.8 %.**

Note the three MSHR classes are three *different* cones, not one:

```
mshr_q[*].base_addr / state / …
   │
   ├─ CAM (bank-scoped, 4 ways) ─ allocator (per-bank, parallel) ─ 32-lane request door
   │        └──────────────► req_out ──► i_spill_req_out          arrival 3.77  (class C)
   │
   ├─ resp tag decode ─ 32-lane response capture
   │        └──────────────► resp_in_ready ──► i_spill_resp_in    arrival 6.94  (class B)
   │
   └─ … + aging sweeps + PD2 arm + drain2 select/drive + finalize/dealloc
            ├─────────────► resp_out ──► i_spill_resp_out         arrival 11.51 (class A′)
            └─────────────► mshr_d_valid / mshr_wr_all
                            → mshr_id_en[e] → CG E, entry D       arrival 11.23 (class A)
```

Classes C and B are **prefixes** of class A. That is the calibration that lets the 825 levels be
attributed: the door is worth ~280 levels (3.77 ns), the door + response capture ~515 (6.94 ns), and
the remaining ~310 levels (4.2 ns) are the tail — aging sweeps, PD2 arm, drain2, finalize.

### 1.1 What the netlist still says

Fusion's `ctmTdsLR_*` restructuring erased essentially every RTL name in the cone. Across all 100
critical paths only four RTL nets survive, and they pin the two ends and the tail:

* start: `mshr_q_16__base_addr__11_` (93 of 100 paths; entry 16 / bit 11 is placement luck, every
  entry feeds the same CAM)
* end: `mshr_id_en[*]`, `mshr_ctl_en[*]`, `mshr_d_valid[*]` — at stage ~820 of ~830
* also at stage ~825: `mshr_d_<e>__burst_len__*` and `mshr_d_<e>__sub_reqs__0__meta_id_base__*`

That last one is the decisive clue. `burst_len` and `sub_reqs[0].meta_id_base` are **identity**
fields — written only by allocation and merge, both of which live in the *door* (3.77 ns). Their `D`
pins arriving at 11.09 ns can only mean one thing: they are being muxed against the **dealloc clear**,
`mshr_d[mshr_i] = '0` (`:4390`, `:4427`), whose condition is the 825-level signal. See §3.1 — this
gives the cheapest fix in the review.

---

## 2. Q1 — which RTL constructs produce the ripple

### 2.1 Refuted: the CAM / first-free / merge chain

These have all already been flattened by earlier PPA work in this module and are **not** the problem:

* **CAM** — `gen_req_mshr_lookup_way` (`:1913-1955`) is bank-scoped: 4 comparators per lane
  (`MshrBankNum:1` mux + one 20-bit compare), 128 total, all parallel. Depth ≈ 6.
* **First-free** — `bank_has_free`/`bank_free_id` (`:2068`) is a 4-way scan per bank, 16 banks in
  parallel. `bank_win_oh` (`:2184`) is a hi/lo split about the RR base plus `x & (~x+1)` per bank,
  32 bits wide, all 16 banks parallel. Depth ≈ 10. The comment at `:2118-2122` documents that this
  replaced a 32-deep serial chain; the replacement is sound.
* **Merge rank** — `merge_same_mask` + `$countones` (`:3221`) is a mask and an adder tree, not an
  accumulate loop. Depth ≈ 8.
* **Head-beat drain** — escapes entirely because `DrainFromQ=1` makes `drain_scan_ent` read
  `mshr_q` (`:3923`).

### 2.2 Confirmed: procedural read-modify-write over `mshr_d[64]`

The cone is the **`always_comb` at `:3175-4450`**. It opens with `mshr_d = mshr_q` and then performs
~10 passes, each of which *reads* the `mshr_d` the previous pass wrote and writes it back **at a
variable index**. Synthesis must build one 64-entry decode + 64-way write-mux (and often a 64:1 read
mux) per pass, chained in source order. Three sub-forms:

**(a) 32-lane serialisation.** A loop over `(tile, port)` that both reads and writes `mshr_d`:

| site | what it does | why it chains |
|---|---|---|
| `:3451-3479` | store → CACHED byte-merge | reads `mshr_d_valid[cache_hit_e]`, `mshr_d[cache_hit_e].state`, `.resp_buf_rd_ptr`; writes `.resp_buf[]` |
| `:3683-3712` | response capture into `resp_buf` | reads/writes `resp_push_ptr[resp_mshr_id]`, `mshr_d[..].resp_buf_cnt`, `.state` |
| `:3727-3745` | store → RESP_HOLD forced drain | reads `mshr_d[cache_hit_e].state/.base_addr` |
| drain / drain2 drive loops | clears `beat_pending`, `beat_pending2` | later lanes see earlier lanes' clears |

Each iteration is ~8 levels, so each of these is a **~250-level block on its own**.

**(b) Pass serialisation.** Whole-array sweeps, each individually shallow but stacked:
`:3505` hold-replay ready · `:3553` AMO invalidate · `:3564` cache self-invalidate ·
`:3779` serve-timeout / cache age-out · `:3821` head beat offset · `:3840` `beat_pending` arm ·
`:3853` PD2 second-slot arm · `:4333` finalize / pop / dealloc.

**(c) An arbiter sitting on `mshr_d` at the very end.** `drain2` (`:4204-4265`) is the one that hurts
most: it builds a 64-bit candidate vector from **`mshr_d`** (`drain2_ent_ok[e] = mshr_d_valid[e] && …
mshr_d[e].beat2_armed`) and then does a 64-bit LSB-isolate (`x & (~x+1)` — a 64-bit borrow chain) —
**32 instances, one per (tile, resp-port)** — *after* the response capture and the PD2 arm sweep have
already rewritten `mshr_d`. The head-beat scan next to it is off the chain because of `DrainFromQ`;
drain2 is ungated and is not.

**(d) A textual-order trap worth knowing about.** `mshr_resp_inflight` is *written* at `:3642`, in the
middle of the block, but *read* at `:1803`/`:1820` by `req_hit_way`, whose result is consumed back
inside the same block at `:3244`. Today this is benign (it derives only from `mshr_q` + `resp_in`, so
it adds ~10 levels ahead of the CAM, not hundreds) — but it means the block is **not** topologically
ordered as written, and any future edit that makes `mshr_resp_inflight` depend on `mshr_d` creates a
genuine combinational loop. Worth a comment at the write site.

### 2.3 The arithmetic

825 levels × 13.4 ps = 11.06 ns. Against 2.0 ns you need **≤ ~140 levels of this kind of logic**, a
**5.9× depth reduction**. No amount of sizing, restructuring or placement gets there — the netlist is
already 99.5 % ULVT at minimum function.

---

## 3. Q2 — where the cone can be cut, and Q3 — the clock gates

Ordered by (value ÷ risk). The MSHR's interfaces are all valid/ready with spill registers on both
sides, and its whole purpose is to *hold* requests for up to 2047 cycles — so a one-cycle pipeline
delay anywhere inside it is architecturally cheap. That is the lever.

### 3.1 **F1 — stop clearing the entry on dealloc** *(cheapest fix in this review)*

Four sites do `mshr_d[e] = '0; mshr_wr_all[e] = 1'b1;` — `:3559` (AMO), `:3586` (self-inval),
`:3815` (age-out), `:4390`/`:4427` (finalize/dealloc). The last two are the 825-level ones, and they
are why *every* identity and resp_buf flop's `D` and CG-`E` sits on the 11 ns cone.

The clear is redundant, and I audited this rather than assuming it. Allocation already does
`mshr_d[alloc_id] = '0` before writing the new entry (`:3396`), so a reused entry never carries a
previous life's residue. And every synthesised read of the array is gated on `mshr_q_valid` /
`mshr_d_valid`, either directly or at its consumer:

| reader | guard |
|---|---|
| `mshr_resp_seen_now` `:1861` | `mshr_q_valid[rsn_tag_cand]` |
| `req_addr_hit_way` / `req_hit_way` `:1924` | `mshr_q_valid[e_abs]` |
| `gen_req_meta_ovlp` `:1970` | `mshr_q_valid[mshr_i]` |
| `bank_has_free` pass 1/2 `:2068` | `!mshr_q_valid[e]` / `mshr_q_valid[e]` |
| `resp_is_mshr` tag re-validate `:3612` | `mshr_q_valid[resp_tag_cand]` |
| `mshr_resp_slots` `:3595` | `mshr_d_valid[mshr_i]` |
| `resp_push_ptr` `:3600`, `resp_rd_ptr2` `:3858` | ungated *read*, but only consumed under `resp_capture_fire` / `PD2 && mshr_d_valid` |
| `replay_ready` `:3505`, `drain_scan_valid` `:3923`, `drain2_ent_ok` `:4204` | `mshr_d_valid` / `mshr_q_valid` |

The `mshr_gate_*_no_lost_write` assertions also stay valid: with the clear gone, `mshr_d[e]` defaults
to `mshr_q[e]` on a free cycle, so a low enable is provably correct. So:

```systemverilog
// dealloc: retire the entry by dropping valid only. The next allocation fully
// re-initialises it (:3396), and no reader looks at an entry with valid low.
mshr_d_valid[mshr_i] = 1'b0;
// (delete)  mshr_d[mshr_i] = '0;
// (delete)  mshr_wr_all[mshr_i] = 1'b1;
```

Then `mshr_id_en[e] = mshr_wr_all[e] | mshr_id_we[e]` reduces to the **alloc + merge** terms only —
class C, 3.77 ns — and `mshr_rb_en` likewise. The `mshr_gate_*_no_lost_write` assertions stay valid
(with the clear gone, `mshr_d[e] == mshr_q[e]` on a free cycle, so a low enable is correct), and the
`MshrGateBits*` elaboration check is untouched.

Pair it with the control-group enable, which is the other half:

```systemverilog
// :2301 — today
mshr_ctl_en[e] = mshr_q_valid[e] | mshr_d_valid[e];   // mshr_d_valid is ON the 11 ns cone
// after F1 the free cycle needs no write at all (mshr_q_valid has no gate: `FF(mshr_q_valid,…)`)
mshr_ctl_en[e] = mshr_q_valid[e] | mshr_alloc_grant[e];  // grant is shallow (class C)
```

* **Effect** the class-A endpoints split by clock-gate group as **resp_buf 4,736 (36.2 %) +
  identity 4,048 (31.0 %) + CG-`E` 271 (2.1 %) = 9,055 of 13,071 (69.3 %)** — plus a share of the
  multibit-banked rows, which mix groups and defeat name attribution. All of those move from 11.07 ns
  to ~3.8 ns. **TNS falls by an estimated 60–70 %.** WNS does **not** move: the control group
  (`state`, `beats_left`, `resp_buf_cnt`, `beat_pending`, `hold_cnt`, …) keeps its deep `D` pins.
* **Cost** ~0 area (removes 64 × 145 bits of clear-mux). Small dynamic-power *increase* is possible
  because a freed entry no longer zeroes (fewer toggles, actually — a retained value toggles less
  than a clear-then-rewrite). No functional change.
* **Effort** hours. **Risk** low; validate with the existing `mshr_gate_*` assertions plus a
  regression that a freed-then-reallocated entry never serves stale data (the assertions and
  `cached_entry_holds_data` already cover this).

### 3.2 **F2 — put `drain2` and the aging sweeps on `mshr_q`** (extend the `DrainFromQ` discipline)

`DrainFromQ=1` already proved the pattern for the head-beat scan. Apply it to the rest, behind knobs
so each can be measured:

| site | change | semantic cost |
|---|---|---|
| `:4204` `drain2_ent_ok` / `drain2_sub_*` | read `mshr_q` (reuse `drain_scan_ent`) | a beat captured this cycle becomes second-slot-drainable next cycle → **measure**; with `RespBufWords=2` this could cost drain throughput |
| `:3505` `replay_ready` + the `mshr_d[replay_win_e]` field reads | read `mshr_q` | the subscriber-target *early* release fires one cycle later. A fresh alloc is already never replay-ready (`hold_ticks` never rounds a non-zero window to 0, so `hold_cnt≠0`, and `sub_reqs_num=1 < 4`), so only the merge-triggered early release moves — against a 2047-cycle window, ≈0.05 % |
| `:3564` self-invalidate, `:3779` serve-timeout / age-out | read `mshr_q` | aging decisions land one cycle later; both windows are ≥2047 cycles |
| `:3553` AMO invalidate | **keep on `mshr_d`** | correctness: a line must not survive an AMO into a same-cycle read |

* **Effect** removes the drain2 select (32 × 64-bit LSB-isolate) and four sweeps from the tail. My
  estimate: arrival 11.07 → **~7 ns**, i.e. WNS −9.44 → ~−5.4. It also fixes class A′
  (`spill_resp_out`), which becomes `mshr_q[sel].resp_buf[ptr]` — a 64:1 mux behind a shallow
  arbiter, ~15 levels.
* **Cost** area roughly neutral (a second read port on `mshr_q` vs. the `mshr_d` muxes it removes).
  Throughput cost is real but small and **must be measured** — recommend `group_mshr_drain2_from_q`
  as a knob defaulting to the current behaviour, sweep it on the standard GEMM shapes, then flip the
  default. Do **not** ship it unmeasured.
* **Effort** 1–2 days RTL + a fleet sweep.

### 3.3 **F3 — parallelise the 32-lane scatters**

Replace the four `for (tile) for (port)` read-modify-write loops of §2.2(a) with: compute a per-lane
one-hot target from `mshr_q` **outside** the loop, then apply all 32 lanes to the array in **one**
parallel reduction.

* Store→cache passes (`:3451`, `:3727`): the target way is a 4-bit one-hot from `mshr_q`; two lanes
  hitting the same word in one cycle is already a door-stalled hazard, so an OR-of-masked-data tree
  (depth 5) is exact.
* Response capture (`:3683`): `resp_mshr_id` comes from the tier-b tag and `mshr_q` alone, so the
  lanes can be scattered in parallel. **Care:** with `RespBufWords=2` two beats for the same entry
  *can* land in one cycle today (successive `resp_push_ptr` slots). The parallel form must keep that
  — per entry, LSB-isolate twice over the 32 lanes (depth ≈ 12) rather than rely on the implicit
  32-deep priority chain.

* **Effect** four ~250-level blocks become four ~12-level blocks. Combined with F2 my estimate is
  arrival ~7 ns → **~4.5 ns**.
* **Cost** area roughly −10 to −20 % of the MSHR's combinational logic (32-deep chains out,
  32→1/32→2 arbiters in). **Effort** 3–5 days. **Risk** medium — the two-beats-per-entry case is the
  one to get right; add a directed test.

### 3.4 **F4 — bank-partition the entry array** *(the structural fix, and the area fix)*

The array is already bank-organised (`e = bank*4 + way`), allocation is per-bank (`bank_win_oh`), the
CAM is bank-scoped, and the drain publish is per-bank (`BankPublish=1`). Yet `mshr_d` is still one
flat 64-entry array that every pass scatters into 64-wide. Split it into `MshrBankNum = 16`
independent 4-entry sub-arrays with their own next-state logic, and route each lane through a 32→16
lane/bank crossbar. Every indexed write becomes a 4-way scatter inside a bank.

Only two things are genuinely cross-bank and stay outside: the full-table meta-overlap check
(`gen_req_meta_ovlp :1970`, 32 × 64) and the drain arbiters.

* **Effect** this is where the **24.3 : 1 comb/seq ratio** comes from. My estimate: MSHR combinational
  area **−50 to −65 %** (163 k → 60–80 k µm²), and with the depth gone the flow can drop from ULVT
  back to LVT/SVT, so the block's share of the 225 mW leakage falls further. Timing ~4.5 → **~2.5-3 ns**.
* **Effort** 1–2 weeks. **Risk** medium-high; it is a refactor, not a patch. Do it after F1–F3 have
  proven the depth model.

### 3.5 **F5 — a second pipeline stage for the door** (needed to actually reach 2.0 ns)

Even with F1–F4 the residual is class C: CAM → allocator → 32-lane door → `req_out` spill, **3.77 ns
measured today**. That is irreducible in one cycle. Make the MSHR a **2-stage pipeline**: cycle 1
decides (CAM hit, bank grant, merge slot) into registers; cycle 2 acts (write the entry, drive
`req_out`). The `req_out` spill registers already exist — the change is to register the *decision*
rather than the *data*.

Cost: one extra cycle of allocation latency per remote miss, and the same-cycle merge window shifts
by one cycle. Both are absorbed by the hold window, which exists precisely to widen that window. This
is the one change that needs an architectural sign-off, so it should be specified and simulated
before it is built.

### 3.6 Q3, directly: **can the clock-gate enables be pre-registered a cycle early?**

**Not as they stand, and it would not help.** `mshr_id_en[e]` must reflect *this* cycle's
`req_in_valid` because the entry is written this cycle; a registered enable would gate off the write
that accompanies its own handshake. And the arithmetic says it is not worth chasing: the CG `E`
required time is 1.631 ns vs 1.674–1.795 ns at the `D` pins, so the entire clock-gating structure
costs **0.10 ns of a 9.44 ns violation (1 %)**.

The constructive version is **F1**: don't pre-register the enable, *remove its deep term*. After F1,
`mshr_id_en` is a function of the door only. And the *dealloc* decision — the deep term — genuinely
can be registered a cycle early if you ever want it back: it is a decision about an entry that has
finished draining, computable from `mshr_q` and held in `dealloc_pending_q[e]`.

---

## 4. Q4 — false / multicycle paths

**None of the cone is false or multicycle by design intent.** Every path in classes A/A′/B/C ends at
a same-cycle handshake decision or the entry update that must accompany it. `set_multicycle_path` on
any of them would silently break the valid/ready contract. `constraints/base.sdc` is clean and should
stay clean here.

Three genuine constraint-side items, none of which is the fix:

1. **`cfg_*` runtime-config fan-out.** The placed build has `GROUP_MSHR_CFG_RUNTIME=0`, so
   `cfg_hold_window_*`, `cfg_bank_shift_*`, `cfg_hold_subs_*` are elaboration constants and this is
   moot — **but every simulation image runs `CFG_RUNTIME=1`**, where those CSR outputs fan into the
   door, the bank hash and the aging sweeps. They are written once at boot and never during a
   kernel. When the PnR flow moves to `CFG_RUNTIME=1`, they are legitimately
   `set_multicycle_path`-able — or better, staged through a shadow register with an explicit
   hardware handshake so the exception is structural rather than an SDC promise.
2. **`hold_cnt` / `served_cnt` / the `hold_prescale_q` phase decode** are slow counters and look like
   multicycle candidates. **They are not** — `hold_cnt` is the *liveness guarantee* (the free-running
   countdown is what makes the hold window deadlock-free), so it must land every cycle it ticks.
   They are not on the critical path anyway.
3. **`EnableStats`** is 0 in this build; keep it 0 for PnR (`gen_stats` is `translate_off`'d, but the
   `-define` should not drift).

---

## 5. Recommended order of work

**Step 0 (do this first — 3 re-syntheses, no RTL change).** The netlist restructuring erased the RTL
names, so the 825 levels cannot be attributed from the reports alone. Attribute them by const-folding
instead, and re-run to placement WNS:

| ablation | folds away | expected to isolate |
|---|---|---|
| `group_mshr_drain_beats=1` | drain2 select + drive + PD2 arm | §2.2(c) |
| `group_mshr_hold_window_burst=0` (and `_single=0`) | hold-replay walker + hold countdown | class C contribution |
| `group_mshr_cache_self_inval=0` + `group_mshr_resp_wait_subs_single=0` | self-inval + RESP_HOLD/serve-timeout sweeps | §2.2(b) |

These are *diagnostics*, not proposals — each costs real throughput (ParityDrain in particular). But
they turn "~825 levels somewhere in a 1,275-line process" into a per-feature budget, for the price of
a synthesis run each, before anyone spends a week on F4.

**Then:**

| | change | Δ arrival (est.) | Δ MSHR comb area (est.) | effort | risk |
|---|---|---|---|---|---|
| F1 | drop the dealloc clear; `mshr_ctl_en` off `mshr_d_valid` | WNS flat, **TNS −60…70 %** | ≈0 | hours | low |
| F2 | drain2 + aging sweeps read `mshr_q` (behind knobs) | 11.07 → **~7** | ≈0 | 1–2 d + sweep | low-med |
| F3 | parallelise the 4 × 32-lane scatters | ~7 → **~4.5** | −10…20 % | 3–5 d | med |
| F4 | bank-partition `mshr_d` into 16 × 4 | ~4.5 → **~2.5–3** | **−50…65 %** | 1–2 w | med-high |
| F5 | 2-stage door pipeline | ~3 → **≤2.0** | +small | spec first | arch |

All Δ figures are **estimates from the depth model** (13.4 ps/level, calibrated against the measured
class-B and class-C prefixes), not from a synthesis run. Re-measure after each step.

Independently of the MSHR, class **E** (Spatz VRF `wdata_q_reg`, −2.05 ns, 3,971 endpoints) is a
separate closure item in `i_spatz/i_vrf` and will become the block WNS once F1–F4 land.

### Knob-level mitigation, honestly

There isn't one. Dropping `group_mshr_num` 64 → 16 shrinks the per-pass muxes but not the pass count
and not the 32-lane chains; expect ~11 → ~8 ns, still 4× over. `drain_beats=1` is the single biggest
const-fold available and is worth measuring in step 0, but shipping it costs the 2-wide response
delivery. **No knob closes this block at 500 MHz.**

---

## 6. Data appendix

* Worst path: `mshr_q_reg_16__base_addr__11_/CP` → 823 nets / 831 cell-output stages →
  `mshr_id_en[61]` → `clock_gate_mshr_q_reg_61__base_addr__0_/E`.
  Arrival 11.0675, required 1.6314, CRP 0, **slack −9.4361**.
* Delay is linear in depth: stage 50 → 1.108, 100 → 1.770, 200 → 3.059, 400 → 5.449, 600 → 8.011,
  800 → 10.600 ns. **13.4 ps/stage, no hot spot, no wire problem.**
* Cell mix on the path: 132 ND2, 114 NR2SKR, 108 NR2, 108 ND2SKF, 76 INVSKF, 70 INVSKR, … —
  all 2-input. VT: **1,640 ULVT / 8 LVT**.
* Block QoR (placement): WNS −9.4361, TNS −134,089.58 ns, NSV 22,776, WHV 0.4220 / THV −2,671.02 /
  NHV 38,339, leakage 225.1 mW, area 1,118,561 µm² (macros 277,915), instances 7,089,284.
* Area: `i_mempool_group` 1,041,898 µm² → `gen_group_mshr_i_group_mshr` **175,428 µm²**
  (comb 163,207 / seq 6,705) = **23.0 % of the group's standard-cell area**.

---

# Addendum — 2026-09-04: corrections from standing the work up

Four things in the review above are wrong or incomplete once the real target and the real flow are
taken into account. This section supersedes them; the body is left as written so the change is
visible.

## A1. The target is 800 MHz, not 500 — the budget is ~4× tighter than §5 implies

The 2.0 ns of the shakedown was a first-pass convenience. At the real target, TCK = 1.25 ns:

| | TCK | logic budget | levels @ 13.4 ps |
|---|---|---|---|
| this run | 2.00 ns | ~1.53–1.70 ns | 115–127 |
| real target | 1.25 ns | ~0.78–0.95 ns | **58–71** |
| today | — | 11.07 ns | **822** |

Derived from the report itself: required times were 1.631–1.795 ns against a 0.044 ns clock
network, so the fixed setup + POCV overhead is 0.25–0.41 ns and does **not** shrink with the
period. So the required depth reduction is **12–14×**, not the ~6× a 2.0 ns target implies.

Two consequences the body does not draw:

* **F5 is not optional and is not one stage.** After F2+F3+F4 the door alone is ~42–44 levels
  (CAM ≈13, allocation arbitration ≈13, merge-slot arithmetic ≈8, output mux ≈8). That fits 58 but
  not the ~35 levels that ordinary 20–25 ps/level logic gets. The MSHR likely needs to become a
  3–4 stage pipeline, which brings a **merge shadow**: an entry allocated in stage 1 is invisible to
  the CAM for 2–3 cycles, so two cores asking for the same line a cycle apart would each allocate
  and each fetch. That needs a small in-flight scoreboard designed in, not discovered.
* **Classes E and F stop being minor.** At 1.25 ns the same arrivals give ≈ −1.1 to −1.3 ns on the
  Spatz VRF write path in **all 16 tiles**, the L1 SRAM D pins, the routers, the DMA mux and the
  TCDM adapter. And this report cannot scope that: it lists only endpoints above ~1.63 ns, so
  everything between 1.05 and 1.63 ns is invisible here and fails at 800 MHz.

## A2. Class E is a placement outlier, not an RTL defect

§1 lists class E (Spatz VRF `wdata_q`, −2.05 ns) as a separate closure item. It is one — but not an
RTL one. The identical register in all 16 tiles reports:

| | arrival |
|---|---|
| tile 10 | **4.207 ns** |
| the other 15 tiles | 2.137 – 2.255 ns (worst slack −0.087) |

Sixteen copies of the same RTL; fifteen close, one is 2 ns off. That is one tile being squeezed —
very plausibly by the MSHR's own 175,428 µm² of ULVT logic sitting next to it. The genuine logic
shortfall on that path is only ~0.15–0.25 ns. **Shrink the MSHR (F4) and re-measure before spending
any effort in `i_spatz/i_vrf`.**

## A3. RETRACTED: "Step 0 — attribute with three const-fold ablations"

§5 recommends three full re-syntheses to attribute the 822 levels per feature. At two weeks each
that is six weeks, and the recommendation is withdrawn.

Replaced by **out-of-context synthesis of `mempool_group_mshr` alone**
(`tsmc7/fusion/ooc/` in the backend repo: `ooc_mshr.tcl`, `view_ooc.tcl`, `base_ooc.sdc`,
`run_ooc.sh`, `continue_place.sh`). The module instantiates only `spill_register` and imports
`mempool_pkg` / `cf_math_pkg` — no macros, no SRAM, no cores — so it needs standard cells only.
Traps worth knowing, all of which cost time to find:

* The module's own `NumRemote{Req,Resp}PortsPerTile` defaults are **2**; `mempool_pkg` computes
  **3** and **3** for this configuration. Elaborating with bare defaults silently builds a smaller,
  wrong MSHR — the script derives them and asserts a port-count floor.
* UPF must be committed **before** `set_corners`, whose `set_voltage` needs `[get_supply_nets VDD]`.
* `base.sdc` errors on four block-only statements (`wake_up_i*`, the two I$ multicycles); `ooc/`
  carries a trimmed copy.
* `config=terapool_spatz4_fpu` yields `GROUP_MSHR_ENABLE_STATS=1` where the placed build used 0 —
  the define set is otherwise identical, and the script pins it. Ground truth is
  `fusion/tmp/analyze.tcl` from the placed run, not either repo's `?=` defaults.
* **The backend has its own `mempool/` clone**, at `6fee18d8`, which does not carry the frontend's
  commits. `run_ooc.sh` swaps the source under an EXIT/INT/TERM trap and prints the md5 in use.
  This checkout must be synced before the next block run, independently of this work.

## A4. `logic_opto` is not a trustworthy yardstick for this design

The obvious cheap loop — synthesise to `logic_opto` and compare — would have ranked the fixes with
a broken ruler. The 500 MHz run has QoR at both labels for the same design:

| label | m40c WNS | m40c TNS | 125c WNS |
|---|---|---|---|
| `logic_opto` | **−19.517** | −287,642 | **−262.772** |
| `placed` | **−9.436** | −131,421 | **−1.564** |

Placement did not refine the number, it **halved it** (+10.08 ns), and the hot corner moved by
**168×**. Before placement there are no buffer trees and no real wire estimates, so a huge-fanout
net gets an absurd delay — and a 64-entry array broadcast is exactly that shape. `logic_opto` is
therefore pessimistic on **precisely the structures F1–F3 restructure**.

So the OOC flow stops at **`initial_opto`** by default, with the floorplan utilization pinned to
**0.4626** (what the placed block actually reached) rather than left to auto-floorplan.
`logic_opto` is kept only as a fast screen for **logic depth**, which is placement-independent and
is the primary quantity being reduced. One `final_opto` run before the block run.

**Caveat:** a placed *standalone* MSHR is still optimistic versus in-block — standalone it gets its
own floorplan at comfortable utilization, in the group it competes with 16 tiles and 293 macros
(see A2). Treat OOC-placed WNS as a lower bound; the **relative ranking** and the **depth** are what
transfer.

## A5. Verification: the MSHR is bypassed by default in simulation

Not a timing point, but it invalidates any functional check made without it.

`config/terapool_spatz4_fpu.mk` sets `group_mshr_cfg_runtime ?= 1`, and with that define
`cfg_mshr_enable` comes from a CSR that **resets to 0** (`mempool_group_mshr.sv:588`). Neither
`vector-burst-test` nor `sp-mshr-burst-test` calls `mshr_cfg_apply_group` — only the GEMM apps do.
So a burst-test run on the stock config exercises the **bypass** path end to end while reporting
`retval = 0`.

Measured, same workload, same host:

| | `[CMS]` at ~cycle 5,000 |
|---|---|
| `cfg_runtime=1` (MSHR bypassed) | `inflight=142133 orphan=141684 dup_alloc=37623` — wedged |
| `cfg_runtime=0` (MSHR live) | `req=179682 resp=178240 inflight=1442 orphan=0 dup_alloc=0` |

The two verification arms therefore mean different things, and both are wanted:

* **`cfg_runtime=0` + burst tests** — MSHR live but at its *untuned* static defaults. The bank hash
  spreads badly and entries miss their sharing target, so this is a deliberate stress point with
  good corner coverage. Its `orphan`/`total_stuck` counts are not a design signal.
* **`cfg_runtime=1` + a small GEMM** — the tuned operating point (`mshr_cfg.h` derives the bank
  shifts and merge targets from `GEMM_M/N/P` and the app writes the CSRs). The only arm whose cycle
  count is meaningful for a performance call.

`scripts/check_arm_equivalence.py` is the cycle-identity gate — it compares every probe line at
every period and localises the first divergence, and exits 2 rather than passing vacuously when
there is no overlap. A matching final cycle count is not sufficient: two runs can diverge and
reconverge.

**Unrelated bug found and fixed while standing this up** (`7aa98559`): `a_fill_cyc` was declared
inside `#if MATMUL_A_REPLICAS > 1` but read outside it, and that macro collapses to 1 exactly when
`A_SPAN >= NUM_GROUPS` — the definition of a prefill shape. Every prefill shape failed to compile in
both GEMM apps; only decode shapes built, which hid it.
