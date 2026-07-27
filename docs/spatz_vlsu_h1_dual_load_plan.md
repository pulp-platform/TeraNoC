# H1 Implementation Plan — two vector loads in flight in the Spatz VLSU

All RTL paths below are rooted at
`/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz/src/` (the **compiled** Spatz, via `Bender.local`). Everything marked **FACT** was read out of the RTL in this session; everything marked **PROPOSAL** is design.

---

## 1. RTL audit summary

### 1.1 Elaborated parameters (terapool_spatz4_fpu) — FACT

| quantity | value | evidence |
|---|---|---|
| `NrOutstandingLoads` | **32** (not 16) | `spatz.sv:325-329` `.NrOutstandingLoads(32)`; the `16` at `spatz_vlsu.sv:15` is only the module default |
| `IdWidth` | 5 | `spatz_vlsu.sv:23` `idx_width(32)` |
| `NrMemPorts` = `N_FU` | 4 | `spatz_vlsu.sv:1566-1567` errors otherwise; `n_fpu=4` (`config/terapool_spatz4_fpu.mk:273`) |
| `MaxBurstWords` / `MemDataWidthB` | 16 / 4 | `generated/spatz_pkg.sv:48`, `spatz_vlsu.sv:71` |
| `FullBurstBytes` / `BurstAlignBits` | 64 B / 6 | `spatz_vlsu.sv:76-77` |
| `BurstRecvPorts` (TwinROB0) | **2, ACTIVE** | `spatz_vlsu.sv:26-27` from `NumRespPorts`; `mempool_tile.sv:265 .NumRespPorts(MshrDrainBeats)`, `group_mshr_drain_beats ?= 2` |
| `NrParallelInstructions` | 4 (`spatz_id_t` = 2 b) | `generated/spatz_pkg.sv:69,93` |
| `meta_id_t` on the wire | **5 bits** | `snitch_pkg.sv:16-17` `RobDepth=32; MetaIdWidth=idx_width(RobDepth)` |
| burst-expander contexts | 2 | `tcdm_burst_expander.sv:31`, `tcdm_burst_interleave ?= 1` |

### 1.2 State partition — FACT

**Request side (follows `mem_spatz_req`, the op-queue head).** `mem_counter_q` / `mem_idx_counter_q` (`:319-335`, reloaded on `commit_insn_push`, `:971`), `mem_max_elements`/`mem_counter_max` (`:915-926`), `mem_req_addr` (`:534-573`), `burst_alloc_q`/`burst_len_q`/`burst_alloc_cnt_q`/`burst_base_id_q` (`:582-587`, `:1051-1056`, driven at `:1141-1209`), `vs2_elem_id_q` (`:526-527`, reset on `mem_spatz_req_ready`), `mem_port_finished_q` (`:368-370`), `mem_req_all_issued` (`:685`).

**Response/commit side (follows `commit_insn_q`, the commit-FIFO head).** `commit_counter_q/_max/_delta/_en/_load` (`:482-506`, `:834-888`), `commit_pair_active` (`:511-513`), `vd_vreg_addr`, `vrf_req_d` (`:1236-1237`), `store_count_q` (`:189-214`), `commit_use_port0_burst` (`:169`).

**Already per-instruction-id (needs no change for 2 in flight).** `mem_insn_pending_q` / `mem_insn_finished_q` (`:374-379`, 4 b each, indexed by `spatz_id_t`), `burst_odd_expected_q` (`:249`, 32 b indexed by **full ROB0 id**), the commit metadata FIFO itself (`:411-427`, **32 deep**, `FALL_THROUGH`), `vrf_id_o` (`:793` — already splits request-side `mem_spatz_req.id` from commit-side `commit_insn_q.id`).

**Shared / dangerous.**
* `mem_pending_q` (`:722-723`, `:1076-1109`) — per-port union of outstanding load beats. **Wiped on every `commit_insn_push`** (`:1082-1083`).
* `burst_tail_phase_q` (`:145`, `:186`) — one bit gating *both* sides (`:168` request, `:169` commit), cleared by `mem_spatz_req_ready` (`:1133-1134`).
* `state_q` (`:181-185`, `:1014-1034`) — load/store mode, driven from the **commit** head, but selects the **request** datapath at `:1249`/`:1432` and gates burst state via `exec_is_load` (`:650`, `:1155-1163`).
* `store_drain_ready = (&rob_empty) && (store_count_q=='0)` (`:654`).

### 1.3 THE GATE — FACT

```
spatz_vlsu.sv:465-469
    // Advance operation queue only when committed metadata retires.
    if (commit_insn_pop && commit_insn_valid &&
        (commit_insn_q.id == mem_spatz_req.id))
      mem_spatz_req_ready = 1'b1;
```
`commit_insn_pop` comes only from `mem_finish_ready` (`:628-634`, `:655-658`). Because the push at `:454-458` only ever pushes the current head, and the head only advances at retire, **`i_fifo_commit_insn` never holds more than one entry today** — its depth 32 is dead capacity, not the limiter.

The op queue is a `spill_register` (`:95-107`) of capacity 2, so the VLSU already *accepts* the second `vle32`; it just never generates its requests.

### 1.4 THE BINDING RESOURCE — ROB0 ids. Exact arithmetic — FACT

Kernel: `vsetvli e32, m2` at `VLEN=512` → `vl = 32` elements (`sp-fmatmul.c:143`). `proc_spatz_req` (`:109-131`) converts to **bytes**: `vl = 128 B`.

`use_port0_burst_req` (`:151-161`): load ✓, not strided/indexed ✓, EW_32 ✓, `vl >= 64` ✓, **`vl <= NrOutstandingLoads*MemDataWidthB` = `128 <= 128` ✓ passes with EQUALITY** (`:158-160`), `rs1[5:0]==0` ✓.

⇒ `mem_port_active = port 0 only` (`:172-173`, enforced by the assertion at `:1578-1585`), `mem_max_elements[0] = 128 B` = **32 words**, issued as **two 16-beat bursts** (`burst_len_calc`, `:931-935`). Each beat pre-allocates one ROB0 id (`:1179-1190`, `:1392`).

ROB0 has `NumWords = NrOutstandingLoads = 32` (`:254-262`), `full_o = (status_cnt_q == NumWords)` (`reorder_buffer.sv:77`), and an id is freed **only on a pop**, which requires the data to have arrived (`reorder_buffer.sv:137-150`, guarded by `empty_read`, `:212-214`).

> **Plainly: today a second load has ZERO ROB ids. One `vle32 e32,m2` occupies 32/32 of ROB0 exactly.** ROB1..3 (96 ids) sit idle because burst mode is port-0-only. `MetaIdWidth = 5` caps the id space system-wide.

---

## 2. Is H1 feasible, and what is the minimum change?

**Feasible: yes — but "re-key one signal" alone buys almost nothing on the shipped m2 kernel, and I want that stated up front.**

If you only replace the gate at `:465-469`, instruction B becomes the request head and immediately stalls on `rob_full[0]` (`:959-961`, `:1184`). B then allocates ids at A's *pop* rate. A drains at up to 2 words/cycle (TwinROB0 `commit_pair_active`, `:511-513`, `reorder_buffer.sv:156-169`), B allocates 1 id/cycle (`:1179-1190`), so B has its first 16 ids ≈16 cycles into A's 16-cycle drain — i.e. **B's first burst request leaves at roughly A's retire, which is where it leaves today.** The only thing genuinely removed is the retire→advance→counter-reload bubble (~2 cycles). Two loads are **never** concurrently outstanding in memory at m2. Little's law does not move.

Worse, in that regime B's alloc walk repeatedly meets `rob_full` and trips `force_send` (`:1160-1169`), truncating its 16-beat burst to whatever it has allocated (`spatz_mem_req[].burst_len = burst_len_issue`, `:1541`). That fragments exactly the burst the group MSHR exists to merge — a credible path to a *net regression*.

### The cheapest ways to free ids, ranked

| option | cost | verdict |
|---|---|---|
| **(A) Kill the 1-id/cycle alloc walk (block reservation)** — reserve `burst_len` ids in one cycle (`reorder_buffer.sv:103-113` + `spatz_vlsu.sv:1179-1190`) | ~1 day, **no signal crosses the request/commit boundary** | **Do this FIRST.** It does not free ids, but it removes 16-32 cycles of pure request-side latency per `vle32` and makes `force_send` unreachable. It is a bigger, safer win than H1 itself and it *moves the baseline every H1 number is compared against*. |
| **(B) Software: `e32,m1` + 16 accumulators** | kernel rewrite, 0 lines of capacity RTL | `vl = 16 elem = 64 B = 16 words = exactly one full burst` ⇒ `burst_has_tail_req ≡ 0`, and **two loads = 16+16 = 32 = ROB0 exactly**. FPU work per load unchanged (16 acc × 16 elem / 4 FU = 64 cyc = today's 8 × 32 / 4). 16 acc + 2 buffers = 18 of `NRVREG=32`. **This is the only way to reach true 2-in-flight without new capacity RTL.** Risk: doubles vector-insn count and scalar `flw` count per load (see §5 id pressure). |
| (C) Port-pair burst engines: A→ROB0/ports{0,1}, B→ROB2/ports{2,3} | ~1-1.5 wk, re-opens the ParityDrain contract (`mempool_group_mshr.sv:1063-1077` asserts `core_id==1`), `spatz_vlsu.sv:1578-1585`, and the hardwired TwinROB0 steering at `:1375-1383` | Defer. Keeps m2, needs no `meta_id` change, but touches the datapath the ParityDrain/TwinROB0 work stabilised. |
| (D) `NrOutstandingLoads = 64` | system-wide | **Rule out.** `IdWidth`→6 while `meta_id_t` is 5 b (`snitch_pkg.sv:16-17`, `mempool_pkg.sv:293`) and the VLSU id goes on the wire unremapped (`spatz_mempool_cc.sv:269`) ⇒ silent truncation, no assertion, plus a NoC resp-flit widening. |
| (E) "BURST-CAP-16, two bursts share ROB0" | — | **Rule out on correctness.** A capped instruction must re-enter the request engine for its second batch after B has taken it ⇒ hold-and-wait cycle ⇒ deadlock. It also contradicts `mem_req_all_issued` as the advance point. |

**Minimum change that actually raises MLP = (A) + H1 gate + (B).** (A) and the gate compose: with one-cycle reservation, B reserves its 16 ids the moment 16 are free — 8 pop-cycles into A's drain, i.e. **before** A retires. With (B) the two loads are fully co-resident and the ROB stops being the limiter at all.

---

## 3. Recommended design

Name: **runahead-issue with request-side blocking**. One request generator, one commit engine, no ROB partition, no id tagging, `meta_id_t` untouched.

**Why no tagging is needed (the load-bearing argument) — FACT.** There is exactly one request generator ⇒ ROB id allocation order == program order (`reorder_buffer.sv:79` `id_o = write_pointer_q`, `:103-113`). The ROB read side is strictly pointer-ordered (`reorder_buffer.sv:96-97`, `:137-150`). The commit engine consumes exactly `commit_counter_max` bytes of the head, derived only from `commit_insn_q` (`:834-888`), then pops. So A's words are by construction the first `A.vl/ELENB` entries the commit engine sees. **Attribution is positional.** Invariant to write into the code: *never add a second commit engine.*

### 3.0 Knob (PROPOSAL)

In `spatz_vlsu.sv`, next to the other localparams (`:69-77`) — no change to `spatz.sv` or the generated package:

```systemverilog
localparam int unsigned MaxInflight = `ifdef SPATZ_VLSU_DUAL_LOAD `SPATZ_VLSU_DUAL_LOAD `else 1 `endif;
localparam bit          Runahead    = (MaxInflight > 1);
localparam int unsigned InflWidth   = idx_width(MaxInflight+1);
```
`hardware/Makefile` (beside the existing `vlog_defs` block, `:132-165`):
```make
spatz_vlsu_dual_load ?=
ifneq ($(strip $(spatz_vlsu_dual_load)),)
  vlog_defs += -DSPATZ_VLSU_DUAL_LOAD=$(spatz_vlsu_dual_load)
endif
```
Leave unset in `config/terapool_spatz4_fpu.mk` until measured. Spatz compiles in the same `vlog` invocation, so the define reaches it exactly like `GROUP_MSHR_DRAIN_BEATS` reaches `mempool_tile.sv`.

### 3.1 New state (PROPOSAL) — 2 flops

```systemverilog
logic [InflWidth-1:0] inflight_q, inflight_d;   // ++ on commit_insn_push, -- on commit_insn_pop
logic dual_adv, dual_run, dual_safe, dual_blk, opq_hold;
```
All inside `if (Runahead) generate`, with `assign {dual_adv,dual_run,dual_blk,opq_hold} = '0;` in the `else`.

### 3.2 D1 — guard `mem_port_finished_q` (`:368-370`) — mandatory

`mem_port_finished_q` has **no** `!mem_counter_load` guard, unlike its twin `mem_port_req_issued` (`:681-683`), whose in-tree comment documents exactly this hazard. Its **only** consumer is `:461` (verified by grep). Change:

```systemverilog
assign mem_port_finished_q[port] = mem_spatz_req_valid &&
    (mem_port_active[port] ? ((!Runahead || !mem_counter_load[port]) &&
                              (mem_counter_q[port] == mem_counter_max[port])) : 1'b1);
```
Without it, on B's first cycle at the head the stale counter equals B's `mem_counter_max` whenever consecutive ops share `vl` (**the matmul case**) and `mem_insn_finished_d[B.id]` is set before B issues a beat. Const-folds to the current expression when off.

### 3.3 D2 — `mem_pending` reset (`:1081-1083`) — the one true showstopper

Today: `if (commit_insn_push) mem_pending_d = '{default:'0};`

**Reviewer flaw confirmed in RTL:** `i_fifo_commit_insn` is `FALL_THROUGH(1'b1)` (`:413`) and `fifo_v3.sv:58` is `empty_o = (status_cnt_q==0) & ~(FALL_THROUGH & push_i)`, so **`commit_insn_push && !commit_insn_valid` is identically 0**. Any guard written in terms of `commit_insn_valid`/`commit_insn_empty` is a dead branch and silently deletes the reset for *every* instruction shape. Use the registered occupancy instead:

```systemverilog
// Reset only at the START of a train (no older instruction remains in flight after
// this cycle).  NOTE: commit_insn_empty is FALL_THROUGH and sees the same-cycle push -
// it CANNOT be used here.
wire no_older = (inflight_q == '0) || ((inflight_q == InflWidth'(1)) && commit_insn_pop);
if (commit_insn_push && (!Runahead || no_older))
  mem_pending_d = '{default: '0};
```
With `Runahead=0` a push can only occur one cycle after a pop (the legacy gate), so `inflight_q == 0` always holds at push ⇒ **identical behaviour, bit-identical netlist**.

Why mandatory: without it, B's push zeroes A's outstanding count, `vrf_req_valid_d` (`:1261`/`:1275`) drops **and** the stale-drain escapes (`:1264`, `:1424-1427`) begin popping and discarding A's arriving burst beats. Silent wrong data, no assertion.

`mem_pending` stays a per-port **union** counter (no per-id split). Under the load-after-load burst restriction every charged beat (`:1090-1093`, `+= burst_len`) is consumed by exactly one commit pop (`:1098-1101` −1, `:1103-1107` −2), and the reset is retained at every train boundary, so any hypothetical leak is bounded to one train and is caught by assertion **A6** below.

### 3.4 D3 — the gate (`:465-469`)

Keep the retire term verbatim as the fallback; add one OR-term:

```systemverilog
assign dual_adv = Runahead &&
    mem_req_all_issued              &&   // :685 - ALREADY !mem_counter_load-guarded
    mem_insn_pending_q[mem_spatz_req.id] &&   // the head was really admitted (see note)
    !(|burst_alloc_q)               &&   // :582 - never advance mid-alloc-walk
    !commit_insn_push && !commit_insn_full &&
    commit_insn_valid && (commit_insn_q.id == mem_spatz_req.id) &&  // exactly 1 in flight
    commit_insn_q.is_load && (state_q == VLSU_RunningLoad) &&
    use_port0_burst_req && !burst_has_tail_req &&
    !burst_tail_phase_q && !switch_to_tail_phase &&
    mem_is_vstart_zero;
...
if (dual_adv) mem_spatz_req_ready = 1'b1;
```

Notes, each closing a reviewer flaw:
* **Reuse `mem_req_all_issued` (`:685`), not `&mem_port_finished_q`.** It is the same per-port comparison *plus* the `!mem_counter_load` guard, and it is the identical signal the fence one-shot uses — so advance and fence can never drift apart.
* **`mem_insn_pending_q[mem_spatz_req.id]`** replaces the structural "was pushed and retired" guarantee the old id-equality gate gave for free. Without it a head that was never pushed (e.g. `commit_insn_full` at `:455`) could be *skipped*, never issuing, never retiring, never releasing its Spatz id → hang.
* **`commit_insn_q.id == mem_spatz_req.id`** caps in-flight at exactly 2 with no counter, and it makes `burst_has_tail_commit` (`:165-166`) *identically equal* to `burst_has_tail_req` — same `vl`, same snapshotted `use_port0_burst` (`:440`) — so the tail-phase family is excluded by construction, not by hope. Deleting this term is the future 3-deep relaxation, and it must not be deleted casually.

### 3.5 D4 — request-side blocking (the SLOT2/H1-MIN fatal flaw, avoided)

The spill register exposes only its head, so B's eligibility is **not** knowable at advance time. Therefore: **always allow the advance based on A alone, then block B's request generation until A retires if B turns out to be unsafe.** An unsafe B degrades to today's behaviour, never to a hazard. Do **not** gate `commit_insn_push` — an unpushed-but-live head is exactly the runaway that killed the slot-partition design.

```systemverilog
assign dual_run  = Runahead && mem_spatz_req_valid && commit_insn_valid &&
                   (commit_insn_q.id != mem_spatz_req.id);
assign dual_safe = mem_spatz_req.op_mem.is_load && use_port0_burst_req &&
                   !burst_has_tail_req && mem_is_vstart_zero &&
                   (state_q == VLSU_RunningLoad) && commit_insn_q.is_load;
assign dual_blk  = dual_run && !dual_safe;
```
Two edits, and they are **provably sufficient** (I walked every request-emitting path in the load branch `:1249-1429`):

1. **`:1173`** burst-alloc start → `if (!burst_alloc_q[port] && mem_operation_valid[port] && burst_use[port] && !dual_blk)`
2. **`:1416`** scalar/word load valid → add `&& !dual_blk` to `mem_req_lvalid[port]`

Coverage proof: with the start blocked, `burst_alloc_q` stays 0, so `burst_alloc_fire` = 0 ⇒ `rob_req_id[port] = burst_alloc_fire` (`:1392`) = 0 and `burst_send` = 0 ⇒ the `:1394` and `:1409` lvalid sites are unreachable. If `burst_mode_req` is false for B, control falls to the third branch (`:1414-1421`) where both `mem_req_lvalid` and `rob_req_id` (`:1420`) are killed by edit 2. The store branch (`:1432-1514`) is unreachable while the commit head is a load (`:1249`). **`dual_blk` cannot toggle mid-burst** — it is a pure function of the head's own fields, and the head only changes when `!(|burst_alloc_q)`.

This is what makes the **store-after-load** case safe. Concretely: last `vle32` advances early, the `vse32` becomes the head, is pushed into the commit FIFO behind A (harmless — in-order), and issues **nothing** until A retires. Without edit 1+2 it would emit genuine **load** requests at the store's addresses, because all three lvalid sites are gated on `commit_insn_q.is_load` (= A, a load).

### 3.6 D5 — Spatz-id pressure guard (new; not in any reviewed design)

`spatz_mempool_cc.sv:646` already traces `idfull` = `running_insn_full`, and `spatz_controller.sv:469` `req_buffer_pop = ~stall & req_buffer_valid && !running_insn_full` blocks **all** issue, vfmacc included. Today the LSU holds 2 of 4 ids (head + spill). Under naive runahead it holds **3** (A in the commit FIFO, B at the head, C refilling the spill), leaving 1 for the VFU — and `spatz_controller.sv:240-254,534-548` shows VFU ids are released late and *do* overlap. That would relocate the stall, not remove it.

Fix — hold the third load out of the op queue so LSU id residency stays at 2:

```systemverilog
assign opq_hold = Runahead && (inflight_q >= InflWidth'(MaxInflight));
// i_operation_queue (:95-107):
  .valid_i(spatz_req_valid_i && (spatz_req_i.ex_unit == LSU) && !opq_hold),
  .ready_o(opq_ready_int),
assign spatz_req_ready_o = opq_ready_int && !opq_hold;
```
Deadlock-free: `inflight_q` drops when A retires, which does not depend on C. In this kernel the instructions behind C are the 8 `vfmacc` reading the buffer B is loading, so they would stall on the scoreboard anyway.

### 3.7 D6 — burst-start room check (fold into Increment 0)

Gate the burst start at `:1173` on **enough free ROB ids for the whole burst**, so `force_send` (`:1160-1169`) — the historically fragile truncation path — becomes unreachable and B never emits fragmented 1-beat "bursts" that bypass MSHR merging. This requires a `free_cnt_o = NumWords - status_cnt_q` output on `reorder_buffer` (next to `:77`), and it is the natural companion of block reservation (which needs the same comparison). Keep the `force_send` code and add assertion **A8**.

### 3.8 Deliberately NOT changed, with reasons

* `burst_tail_phase_q` (`:145`/`:186`/`:1130-1138`) — **not split.** `dual_adv` requires `!burst_has_tail_req`, and with `commit_insn_q.id == mem_spatz_req.id` at advance time `burst_has_tail_commit ≡ burst_has_tail_req`, so `switch_to_tail_phase` (`:1111-1128`) is provably 0 across the whole runahead window and the `:1134` clear is a no-op. The shipped "VL=24 m2 burst+tail load → store hang" documented at `:1119-1127` stays unreachable.
* Commit counters (`:834-888`) — stay single. `commit_counter_load = commit_insn_pop` reloads from the *retiring* metadata in both modes (`FALL_THROUGH` `data_o` still shows A at the pop cycle); `mem_is_vstart_zero` in `dual_adv` makes that reload value 0 either way. This is why the `vstart` conjunct is required, not cosmetic.
* `mem_counter_q` / `mem_idx_counter_q` / `vs2_elem_id_q` / `store_count_q` / `state_q` / offset queues / `vrf_id_o` / the commit metadata FIFO — unchanged. `reorder_buffer.sv` unchanged by H1 itself (only by Increment 0).
* `mempool_group_mshr.sv`, `mempool_tile.sv`, `snitch_pkg.sv`, `mempool_pkg.sv` — **unchanged.** `MetaIdWidth` stays 5.
* Commit-FIFO depth (`:412`, 32 × ~37 b ≈ 1.2 kflop, only ever needs `NrParallelInstructions=4`) — a ~1 kflop reclaim, but it changes the netlist with the knob OFF. Separate commit, not part of the bit-identity proof.

### 3.9 Const-fold to bit-identical

Every added term is `Runahead && X`, `(!Runahead || X)`, or a `Runahead ? new : old` mux on a constant-0 parameter; the two new flops live inside `if (Runahead) generate`. D2 degenerates to the exact original expression (proved in §3.3). **Prove it, do not assume it:** build with the knob unset, run sp-fmatmul, require a *cycle-identical* result and zero `[VPERF]`/`[CMS]`/`[LP]`/`[BP]` deltas against current HEAD. Remember `make compile` silently skips `vlog` after a `.sv` edit — `rm build_X/compile.tcl` and confirm with `grep "Compiling module spatz_vlsu"`.

---

## 4. Correctness checklist — arm BEFORE trusting anything

All new asserts inside the existing `` `ifndef SYNTHESIS `` block (`:1576-1642`), under `if (Runahead)`.

| # | property | guards |
|---|---|---|
| **A1** | `mem_spatz_req_ready \|-> !(\|burst_alloc_q)` | never advance mid-alloc-walk |
| **A2** | `dual_run \|-> (commit_insn_q.is_load && commit_insn_q.use_port0_burst && mem_spatz_req.op_mem.is_load && !burst_tail_phase_q && !switch_to_tail_phase && (state_q==VLSU_RunningLoad))` **or** `dual_blk` | the entire exclusion contract, restated as a checked property |
| **A3** | `dual_run \|-> !(\|rob_req_id[NrMemPorts-1:1])` | only ROB0 allocates during runahead |
| **A4** | `(state_q==VLSU_RunningLoad) \|-> !(rob_rvalid[0] && !mem_pending[0])` | **the direct guard on D2** — no stale drain of A's live beats |
| **A5** | commit-FIFO `usage_o` (currently unconnected, `:426`) `<= MaxInflight`, and `inflight_q == usage` | in-flight cap |
| **A6** | `mem_pending_q[0] <= NrOutstandingLoads`, and `(commit_insn_push && no_older) \|-> (mem_pending_q=='0)` | charge/discharge balance after removing the blanket reset |
| **A7** | `rob_pop_dual[0] \|-> (mem_pending_q[0] >= 2)` | the −2 branch at `:1103-1107` has no −1 fallback ⇒ would leak |
| **A8** | `!force_send` (once D6 lands) | the historic force_send deadlock class; if it fires, D6's room check is wrong |
| **A9** | fence one-shot: `sent_armed_q` set on `commit_insn_push`, cleared on `spatz_mem_req_sent_o`; `spatz_mem_req_sent_o \|-> sent_armed_q`; exactly one pulse between push and pop of each id | see §4.1 |
| **A10** | positional attribution: a counter of ROB0 pops attributed to the commit head equals `commit_insn_q.vl >> $clog2(ELENB)` at `commit_insn_pop` | the whole no-tagging argument |

**Keep armed, do NOT weaken to make a build pass:** `:1578-1585` (port-0-only burst), `:1627-1636` (`(|burst_odd_expected_q) |-> !rob_req_id[1]` — the in-tree tripwire whose comment names this exact change; under this design it must **never** fire), `reorder_buffer.sv:208-228` (`full_write`, `empty_read`, `wr2_id_collision`, `dual_pop_valid`, `pop_exclusive`), `mempool_group_mshr.sv:1063-1077`, and the `[CMS]` TB scoreboard at `/mempool_tb/u_cms/`.

**One assertion must be re-scoped:** `:1637-1640` `(commit_insn_pop && commit_insn_q.use_port0_burst) |-> !(|burst_odd_expected_d)` will **false-positive** on the first successful dual issue (A retires while B's odd bits are legitimately set). Replace under `Runahead` with an id-range form, not with a vacuous one:
```
burst_alloc_fire[0] |-> !burst_odd_expected_q[rob_id[0]]      // no set bit is ever re-allocated
```
(Do **not** use `(rob_empty[0] && !mem_pending[0]) |-> …` — in the H1 steady state that antecedent is essentially never true, so it polices nothing.)

### 4.1 Fence semantics — `spatz_mem_req_sent_o`

**FACT:** `:672-687` is already the *ungated request-issue-complete* one-shot: `mem_port_req_issued` (with the `!mem_counter_load` guard), `mem_req_all_issued`, `FF`, rising edge. It carries no response term, so `SFENCE_VMA` / `gbar_sync` / `vlsu_fence()` semantics ("requests sent, responses may still be in flight") are **preserved exactly**. H1 reuses the same level as the advance condition, so the pulse does not move relative to its instruction — it only stops trailing the previous instruction's retire.

**The thing to verify is re-arming.** Trace: cycle *t*, `mem_req_all_issued` high for A → A's pulse already emitted; `dual_adv` fires. Cycle *t+1*, B is at the head, `:454-458` fires → `commit_insn_push` → `mem_counter_load[0]` (`:971`) → `mem_port_req_issued[0]` forced low → level drops → re-armed. The only way to lose the low cycle is a deferred push (`commit_insn_full` at `:455`); `dual_adv` already requires `!commit_insn_full` and the FIFO holds ≤2 of 32, so it cannot happen. **A9 pins it down.** A lost low cycle ⇒ two loads emit one pulse ⇒ `snitch.sv:2855-2859` `acc_mem_req_cnt` never returns to zero ⇒ `snitch.sv:901` `fence_stall` hangs the next `gbar_sync` — this is the single most important thing to watch in the first simulation. If A9 fires, replace the edge detector with a per-id latch (`mem_insn_reqsent_q[NrParallelInstructions]`, set once, cleared at that id's pop).

`spatz_mem_finished_o` / `spatz_mem_str_finished_o` (`:661-663`) are commit-side, one pulse per cycle max — unchanged. The sequencer's 3-bit `acc_mem_cnt_q` reaches 2 instead of 1, far from the `== '1` cap at `spatz_fpu_sequencer.sv:609`. **Second-order effect to watch:** that same line blocks a scalar `fsw` while *any* vector mem op is outstanding, and H1 keeps `acc_mem_cnt_q` nonzero longer. sp-fmatmul's inner loop has no `fsw` (stores are in the epilogue), but another kernel could regress there. Scalar `flw` is gated on `acc_mem_str_cnt_q` (vector **stores**) only ⇒ unaffected.

### 4.2 ParityDrain / `burst_odd_expected` interaction

**FACT — safe for burst+burst.** `burst_odd_expected_q` (`:249`) is a bitmap over **full ROB0 ids**, set at allocation from the intra-burst beat parity (`:1069-1071`) and cleared on any consuming push (`:1064-1068`), consumed at `:1375-1383` to divert a port-1 response into ROB0's second write port. `burst_alloc_q[0]` is a single per-port FSM, so only one burst allocates at a time and each restarts its count at 0 ⇒ the parity is **per-burst**, and two instructions' bursts hold disjoint ids (an id is re-allocated only after its data was popped). No aliasing.

**The dangerous case is burst + non-burst**: a non-burst B natively allocating ROB1 ids from the same 0..31 numbering, whose genuine port-1 response could be stolen into ROB0. Excluded by `dual_safe` (both must be port-0 bursts ⇒ `mem_port_active` is port 0 only ⇒ `mem_max_elements[1..3] = 0`, `:896-911`) and by **A3**. Tripwire `:1627-1636` stays armed.

**Downstream:** `tcdm_burst_expander` has `NumContexts = 2` (`:31`, `tcdm_burst_interleave ?= 1`) and its header states that between two loads every response consumer (MSHR `beat_seen` bitmap, bypass-retag range match, VLSU ROB) is order-insensitive by construction. But **an m2 instruction is two bursts**, so two in-flight m2 loads want up to 4 contexts — the 3rd/4th simply backpressure `spatz_mem_req_ready[0]`. With the m1 kernel (one burst per load) it fits exactly. Watch tile resp port 1 for new contention (both instructions' odd beats land there under ParityDrain) and confirm no MSHR entry collision — entries key on `(core_id, meta_id)` and the two bursts have disjoint 5-bit id ranges by ROB construction.

### 4.3 Directed tests

1. Knob OFF vs HEAD: cycle-identical sp-fmatmul + zero counter deltas.
2. Knob ON, `riscv-tests` + a **store-heavy** kernel + a **strided/indexed** kernel: the knob must be a no-op (all fall outside `dual_safe`), all assertions silent. A green suite here proves less than it looks — most code never takes the early advance.
3. A **directed** back-to-back aligned `vle32` test at 64 B and 128 B, plus `load → store` and `burst-load → non-burst-load` transitions (the two shapes `dual_blk` exists for).
4. sp-fmatmul with `MATMUL_VERIFY` on a small geometry (256×32×256) — the failure mode of a mis-done D2 is *wrong data*, not a hang.

---

## 5. Expected gain and how to measure

### 5.1 The arithmetic

Reported: VLE latency `L = 109`, FPU work per load `W = 64`, loads-in-flight `N = 1.23` ⇒ load interval `T = L/N = 88.6` cyc, FPU busy `W/T = 72.2%` (matches the reported 72.6%). Target `T = W = 64` ⇒ `N = 109/64 = 1.70`. **We must cut ~24.6 cycles from an 88.6-cycle recurrence.**

Identifiable serial components of `T` (all FACT from the RTL):
* ~2 cyc: retire → advance → `commit_insn_push` → counter reload.
* **16 cyc**: the 1-id-per-cycle alloc walk before burst 1's single request handshake (`:1179-1190`, `burst_send` needs the full count, `:1195-1197`).
* a further 16 cyc for burst 2 (partially overlapped with burst 1's flight).

Honest per-lever prediction:

| lever | ΔT | N | FPU idle |
|---|---|---|---|
| Increment 0 alone (block reservation) | −16…−30 | 1.23 → ~1.5-1.7 | 24.5% → ~12-18% |
| H1 gate alone, m2, **no** Inc 0 | −2…−10 (B's walk overlaps A's drain but is id-starved at 1/cyc) | ~1.25-1.4 | marginal; **and** `force_send` fragmentation can make it net-negative |
| Inc 0 + H1 gate, m2 | −26 (B reserves 16 ids ~8 pop-cycles into A's 16-cycle drain ⇒ burst 1 leaves **before** A retires) | ~1.5-1.7 | ~8-14% |
| + m1/16-acc kernel | `T → W = 64` robustly (both loads fully ROB-resident) | ~1.70 | FPU-bound |

**Neither lever alone reaches the goal. That is the central conclusion of this audit.**

### 5.2 Instrumentation to add to `[VPERF]` (`:1590-1625`)

Extend the existing block (already gated by `mempool_tb.csr_trace_any_global`):
* `c_dual` — cycles with `dual_run` (**the direct Little's-law metric**).
* `c_blk` — cycles with `dual_blk` (wasted runahead).
* `c_rob0full` — cycles with `rob_full[0]`, plus a `status_cnt` occupancy histogram. **This is what distinguishes "gate still closed" from "gate open, no ids".** Without it the experiment is uninterpretable.
* `c_forcesend` — force_send truncations (fragmentation detector).
* `c_hold` — cycles with `opq_hold` (D5's cost).

Success signature: `c_dual` large, `no_insn` collapsing, `wait_beats` flat, `insn_ret` unchanged, `c_forcesend` ≈ 0.

### 5.3 From the per-core Spatz tracer

`gen_spatz_trace.py` parses `ISSUE <cyc> id=… <unit> <op> … vl=…` / `RETIRE <cyc> id=… active= stall= ipu_cyc= fpu_cyc= mem_beats=` and a per-cycle stream with `reason=`, `vfu_ins/vfu_opr/vfu_stl/sb_deps`.

* **Loads in flight** = `Σ_over_vle (retire − issue) / window` — Little's law directly from the ISSUE/RETIRE pairs. Also report the max concurrent overlap.
* **VLE issue→retire latency** = the same `retire − issue` distribution (should stay ~109; if it *grows* while `c_dual` grows, you have created downstream contention).
* **FPU idle attribution**: the per-cycle `reason=` list is a *comma list of all active reasons*. The three buckets to compare before/after are `vlsu` (`vlsu_stall` — "VLSU won't accept", today 39.8% of idle), `vfu`, and **`idfull`** (`running_insn_full`).
* **`idfull` is the regression tripwire for D5.** If `idfull` rises, the stall has merely relocated from the VLSU ready signal to the controller's 4-entry id pool.
* `vfu_ins=1 & vfu_opr=0` = VFU occupied but waiting for data — that is the "waiting on an in-flight load" bucket (49.8%); it should shrink as `N` rises.
* Also watch `[GroupMerge]` (`group_merge_profiling=1`) for burst-merge quality — an MSHR-merge regression from fragmentation would show there first, and would not show in `[VPERF]` at all.

---

## 6. Staging and go/no-go

**Increment 0 — block ROB-id reservation (do this FIRST, ~2-3 days, own knob).**
`reorder_buffer.sv:103-113` gains `id_req_len_i`: reserve `len` ids in one cycle when `status_cnt_q + len <= NumWords` (`write_pointer += len` with wrap, `id_valid_d` cleared for the `len` slots), plus `free_cnt_o` at `:77`. `spatz_vlsu.sv:1172-1190` sets `burst_alloc_cnt_d = burst_len_q` in one cycle; `burst_odd_expected_d` (`:1063-1075`) is written for the whole range at once with parity `k[0]`. No signal crosses the request/commit boundary. Makes `force_send` unreachable. **Re-measure the baseline — this changes every number H1 is compared against.**

**Increment 1 — the two standalone correctness fixes (~1 day).** D1 (`:368-370` guard) and D2 (`:1081-1083` reset). Both are latent bugs that exist *today*; both const-fold to the current netlist with the knob off. Land with assertions A4, A6, A7 armed. Independently reviewable and testable.

**Increment 2 — H1 proper (~2-3 days RTL, 3-5 days bring-up).** Knob, `inflight_q`, D3 (gate), D4 (`:1173` + `:1416` blocking), D5 (`opq_hold`), D6 (room check), A1-A3/A5/A8-A10, the `:1637-1640` re-scope. Bring-up order: (i) OFF bit-identity; (ii) ON with store/strided kernels — knob must be a no-op; (iii) ON with sp-fmatmul, **watch A9/fence first**, then `[VPERF]`, then `[GroupMerge]`, then wall clock against a freshly re-measured same-build baseline.

**GO/NO-GO GATE (after Increment 2, before any further RTL):**
* **GO to Increment 3** if `c_dual` is a large fraction of the window and `c_rob0full` is high ⇒ the gate is open and **capacity** is now the limiter.
* **STOP and re-diagnose** if `c_dual` is small (the gate is still closed — find out why), or if `idfull` rose (the stall relocated — revisit D5), or if `c_forcesend`/`[GroupMerge]` degraded (fragmentation — D6 is wrong).
* **HARD STOP** on any of: assertion A3 or `:1627-1636` firing (the exclusion set is wrong, *not* the assertion being too strict), A4/A6 firing (D2 needs the per-id split after all), A9 firing (fence underflow), or any `[CMS WARN]`/orphan response.

**Increment 3 — capacity (choose after the gate).**
* **3a (recommended): software `e32,m1` + 16 accumulators** in `sp-fmatmul.c:143` and the accumulator block at `:151-260` (~2-3 days). Zero capacity RTL, both loads fully ROB-resident, `burst_has_tail_req ≡ 0` by construction. **Budget explicit measurement of `idfull` and scalar-`flw` pressure** — m1 doubles the vector-instruction count (16 × 4-cycle vfmacc) and doubles the per-step scalar `flw` count, and that is the most likely way this variant disappoints.
* **3b (fallback): port-pair burst engines** (~1-1.5 wk) — generalize `mempool_group_mshr.sv:1063-1077` from `core_id==1`, relax `spatz_vlsu.sv:1578-1585` to per-pair, parameterize the TwinROB0 steering at `:1375-1383` by a burst base port. Keeps m2, no `meta_id` change, but re-opens a contract that took effort to stabilise. **Never in the same commit as Increment 2.**

**Explicitly out of scope / do not start here:** `NrOutstandingLoads = 64` (system-wide `MetaIdWidth` 5→6 with a silent truncation at `spatz_mempool_cc.sv:269` and a NoC resp-flit widening); ROB id-space partitioning by instruction (fragments capacity and breaks the in-order read the commit path depends on); BURST-CAP-16 (request-engine re-entry ⇒ deadlock); shrinking the commit FIFO to 4 (separate commit, breaks bit-identity).

**Practical note:** only `terapool_spatz4_fpu` boots on this branch, so every iteration costs a full terabool elaboration (~7+ min before `run`). Budget accordingly, and use `make -o update-floogen`.
