# VLSU burst receive + reorder-buffer: current design & 2-ROB pre-alloc options

> **2026-07-05 RESOLUTION.** Superseded/implemented. The final contract is NOT the `meta_id=base+b`
> described below: the MSHR emits the ABSOLUTE per-port ROB slot (`meta_id = port_base[b%N] + b/N`)
> using an `aux_base` (the port-1 ROB base) carried in the burst request's spare `wdata.data`, and the
> VLSU writes `rob_wid = rsp.id` directly (option "2-ROB pre-alloc" won). Implemented, verified
> (~1.27x single-core streaming), gated OFF by default (`group_mshr_drain_beats=2` to enable).
> See `docs/respbw_redesign_findings.md` (resolution banner) + WORKLOG 2026-07-05.


Context: Option A "2-wide burst receive". The MSHR side is done (beat b of a single-core burst is
emitted on resp port `1+(b%N)` with `core_id += (b%N)`, `meta_id` unchanged = `base+b`). What
remains is the **VLSU receive**: today a burst is received on ROB[0] only, 1 word/cyc. To hit 2
words/cyc the responses must land in **two** ROBs (port 0 = even beats, port 1 = odd beats), each
committed into a VRF lane. This doc describes the current ROB + burst flow precisely, then lays out
the options for the one hard part — getting ROB[1] a valid id run — with trade-offs.

Constants (terapool_spatz4_fpu): `N_FU=NrMemPorts=4`, `ELEN=32`, `ELENB=4`, `MaxBurstWords=16`,
`NrOutstandingLoads=32` ⇒ ROB depth 32, id width 5; a vector reg = 4 VRF rows × 4 lanes = 16 EW32
elements. `N = BurstRecvPorts = 2` (usable remote resp ports).

---

## Part 1 — current design

### 1A. `reorder_buffer.sv` — one instance per VLSU mem port

A circular buffer that **decouples out-of-order writes from strictly in-order reads**.

- **ID allocation is sequential.** `id_o = write_pointer_q` (`:60`) is the next id handed out; on
  `id_req_i && !full_o` the write pointer advances by 1 and that slot is marked taken (`:80-90`).
  IDs come out `base, base+1, base+2, …` in order.
- **Write is random-access.** `push_i` writes `mem_d[id_i] = data_i`, `valid_d[id_i]=1` (`:93-96`).
  A beat lands in **its own id's slot**, in any order — early/late arrival is fine.
- **Read is strictly in-order.** `data_o = mem_q[read_pointer_q]`, `valid_o = valid_q[read_pointer]`
  (`:76-77`); `pop_i && valid_o` advances `read_pointer` by exactly 1 and recycles the id
  (`:107-121`). **No skipping** — the head must be valid to pop.
- Occupancy `status_cnt` +1 per `id_req`, −1 per `pop`. Asserts: never `id_req` when full
  (`:157`), never `pop` when head invalid (`:161`).

**THE INVARIANT (load-bearing):** `write_pointer` (allocation) and `read_pointer` (retire) both walk
the *same* circular index space monotonically, so **allocation order = retire order**. The consumer
gets correct in-order data iff (1) every allocated id is `push`ed exactly once, and (2) the ids form
a **contiguous run** the read_pointer can walk. A gap, or a head slot that was never written, stalls
that ROB **forever** (no skip, no timeout). This is why the burst path must hand each ROB a
contiguous id run and ensure each returning beat carries the matching id.

### 1B. VLSU port-0 burst load flow (today)

1. **Eligibility** (`:151-161`): unit-stride EW32 load, `vl ≥ 64 B`, **`vl ≤ 32×4 B = 128 B`** (one
   ROB batch — keeps the id run from wrapping into occupied slots), `rs1` 64 B-aligned. Sets
   `mem_use_port0_burst`; `mem_port_active = 0001` (only port 0), `commit_port_active = 0001`.
2. **Pre-alloc** (`proc_burst_alloc`, `:1077-1145`): while a burst is in progress, allocate **one ROB
   id per cycle** on port 0 (`burst_alloc_fire[0]` → `rob_req_id[0]`), capturing
   `burst_base_id[0] = rob_id` on the first beat (`:1116-1126`). After `burst_len` ids are reserved,
   `burst_send` fires (`:1131`). `force_send` collapses the burst if the ROB fills mid-way.
3. **Request** (`:1287-1320,1419-1454`): emits **one** request carrying `id = burst_base_id[0]` and
   `burst_len = burst_len_issue` (`:1439`). **Today the three quantities are identical:** #ids
   pre-allocated == `burst_len_issue` == issued `burst_len` (= 16). `mem_counter`/`mem_operation_last`
   step by `burst_len_issue × 4 B` in one shot (`:926-929,953-956`).
4. **Receive** (`:1272-1286`): `rob_wid[port] = spatz_mem_rsp_i[port].id`, `rob_push` on a valid load
   response. The responder returns beats with ids `base…base+15`; each lands in `mem_q[id]`; ROB[0]'s
   read_pointer (= base, since the batch started empty) drains them in order.
5. **Commit** (`commit_use_port0_burst`, `:1187-1198`): **one word/cyc** — `rob_rdata[0]` →
   `vrf_req_d.wdata[ELEN × burst_lane_idx]`, `rob_pop[0]` on the accepted VRF write. Element math
   (`:768-790`): `burst_elem_idx = commit_counter_q[0] >> 2`; **lane = elem mod 4**, **row = elem/4**;
   `vd_vreg_addr = vd×4 + row`. The commit counter walks `commit_counter_q[0]` by 4 B (one element)
   per accepted VRF write (`:796-849`) until `vl` (`commit_operation_last`). This serial one-word/cyc
   drain is the throughput ceiling we're removing.
6. **Guard** (`:1471-1476`): during a burst, ports 1..3 must not assert `spatz_mem_req_valid`.

---

## Part 2 — what 2-ROB receive requires

Beat b → ROB `(b%N)`. For N=2: ROB[0] gets even beats {0,2,…,14}, ROB[1] gets odd beats {1,3,…,15}.
By the ROB **invariant**, each ROB needs a **contiguous id run** in retire order:
- ROB[0]: ids `base0 … base0+7` for beats 0,2,4,…,14 (in that order).
- ROB[1]: ids `base1 … base1+7` for beats 1,3,5,…,15.

The MSHR sends beat b with `meta_id = base0 + b` (unchanged). So on receive the VLSU must **re-map**
the arriving id to the dense per-port slot:

```
rob_wid[p] = burst_base_id[p] + ((rsp.id - burst_base_id[0]) >> log2(N))
           = burst_base_id[p] + ( b >> 1 )        // b = rsp.id - base0,  p = b%2
```
ROB[0]: b∈{0,2,…} → slot base0+{0,1,…,7}. ROB[1]: b∈{1,3,…} → slot base1+{0,1,…,7}. Both contiguous ✓.

**Commit** then reads ROB[0].head → lane (burst_elem_idx+0) and ROB[1].head → lane (burst_elem_idx+1)
the same cycle, with `burst_elem_idx` advancing by N=2 per cycle (so lanes go {0,1},{2,3},{0,1}@row1…).
`mem_pending` is split (port 0 += 8, port 1 += 8). This part is mechanical.

**The hard part:** ROB[1] must be handed a contiguous 8-id run *before its beats arrive*. Today only
port 0 pre-allocates, and the burst FSM ties **#ids pre-allocated == request `burst_len`**. For
beat-spread these decouple: each port pre-allocs **8**, but the single request still asks for **16**
(it fetches the whole line; the responder spreads the 16 beats). So whatever option we pick must (a)
give ROB[1] its 8-id run, and (b) break the "alloc-count == request-burst_len" coupling: keep the
issued request `burst_len = 16` and `mem_counter` stepping by 16, while each port's alloc target is 8.

---

## Part 3 — options for ROB[1]'s id run

### Option A — separate port-1 pre-alloc FSM (eager)
A new beat-spread-gated allocation path mirrors port 0 onto port 1: `rob_req_id[1] = prealloc_fire[1]`
for 8 beats, capture `burst_base_id[1]`, **never** assert `mem_req_lvalid[1]`/`burst_send[1]` (no
request on port 1 — the guard at `:1471` stays satisfied). `burst_send[0]` waits for *both* ports'
8-id allocs. Request `burst_len = 16`, `mem_pending` split 8/8.
- **+** Explicit, easy to reason about per port.
- **−** Duplicates the alloc FSM logic; new cross-port `burst_send` term; a second place to keep in
  sync with port 0's force_send/clear behaviour.

### Option B — extend the existing per-port loop (eager, unified)  ← my lean
`proc_burst_alloc` already loops `for (port…)`; only port 0 starts because only it has
`mem_operation_valid[port] && burst_use[port]`. For beat-spread, **also start port 1** (gate it on
`mem_use_port0_burst && BurstRecvPorts>1`), set each port's alloc target to its share
(`burst_len_q[0]=⌈16/2⌉=8`, `burst_len_q[1]=⌊16/2⌋=8`), and let the *same* loop allocate one id/cycle
on each port in parallel (8 cycles instead of 16 → also a small latency win). Capture both bases. Only
port 0 drives `mem_req_lvalid`/the request (`burst_len=16`); `burst_send[0]` gated on both `cnt==8`.
- **+** Fewest new signals — reuses the proven alloc/force_send/clear loop; one mechanism, both ports;
  faster alloc.
- **−** Must split the alloc target (8) from the request length (16) and from `burst_len_issue`
  cleanly (the one real subtlety); the loop now drives `rob_req_id[1]`.

A and B are the *same eager mechanism* (per-port contiguous pre-alloc); A spells it as a parallel FSM,
B reuses the existing loop. B is less code and less divergence risk.

### Option C — lazy port-1 alloc (reactive)
Port 0 pre-allocs 8; port 1 pre-allocs nothing. On the **first odd-beat arrival**, allocate a port-1
id (`id_req[1]`) and `push` it the same cycle; ditto for each subsequent odd beat.
- **+** No pre-alloc delay, no cross-port `burst_send` coordination.
- **−** **Risky.** (1) The ROB allocates ids in **arrival order**, so this only works if odd beats
  arrive **strictly in beat order** — if the NoC/MSHR can reorder them, ROB[1] gets ids in the wrong
  order and the in-order read returns garbage. (2) Allocation moves to **response** time, which the
  ROB's `id_req`→`push` path wasn't designed around (id_req advances write_pointer; doing it in lockstep
  with push on every beat is untested and tight on timing). (3) `mem_pending[1]` accounting becomes
  arrival-driven. I'd avoid this unless beat ordering on port 1 is guaranteed.

### Recommendation
**Option B.** It satisfies the ROB invariant with the least new logic, reuses the hardened alloc loop
(including its force_send/clear corner cases), and is a clean parametric extension (`BurstRecvPorts=1`
⇒ exactly today's port-0-only behaviour). The only real work is decoupling *alloc target (8)* from
*request burst_len (16)* — a localized change in `proc_burst_alloc`/`gen_mem_req`/`mem_pending` — plus
the `rob_wid` re-map and the 2-lane commit, which are common to all options.

Open question worth your call: the eager options delay the request until both ROBs are pre-allocated
(8 cyc). That's fine and even faster than today's 16, but if you'd rather the request fire as soon as
port 0 is ready (and trust port 1's parallel alloc to finish first), that's a one-line relaxation of
`burst_send` — slightly racier, slightly lower latency.

---

## Part 4 — CORRECTION: the VLSU `rob_wid` re-map cannot survive pipelined bursts → use `aux_base`

While implementing the receive I found that the "MSHR sends `meta_id = base+b`, VLSU re-maps"
scheme (the simplification that dropped `aux_base`) is **not correct for back-to-back bursts**, which
is exactly the streaming case.

**Why.** The request's `meta_id` is port-0's ROB base, `burst_base_id[0]`. With beat-spread, port 0
pre-allocs only **8** ids/burst, so that base advances by **8** each burst — yet the request still
issues `burst_len = 16`, so the MSHR emits `meta_id = base … base+15`. Consecutive bursts therefore
have **overlapping `meta_id` ranges**: burst N = `8N … 8N+15`, burst N+1 = `8N+8 … 8N+23`. A response
carrying `meta_id = 8N+10` is **ambiguous** — burst N beat 10 or burst N+1 beat 2 — and the per-burst
base the VLSU would subtract to disambiguate has **already been overwritten** (bursts pipeline: the
alloc clears at request-send, ~8 cyc later, long before the ~50-cyc-later responses). A separate
16-stride `meta_id` counter removes the *ambiguity* but the re-map still needs the per-burst base,
which is still overwritten. **Legacy is immune only because its `meta_id` IS the absolute ROB slot —
no re-map, no base needed.**

**Fix — `aux_base` (restore it).** Have the MSHR emit the **absolute per-port slot**:
`meta_id = (b%N==0 ? base0 : base1) + (b/N)`. Then port 0's meta_ids are dense `base0..base0+7`,
port 1's are `base1..base1+7` — **sequential per burst, never overlapping** — and the VLSU writes
`rob_wid = rsp.id` **directly** (no re-map, robust to pipelining, exactly like legacy). Cost:
- VLSU: pass **base1** (= `burst_base_id[1]`) in the request's spare `wdata.data` field (already free
  on a burst load), alongside the beat-spread flag. **The receive gets simpler — no re-map.**
- MSHR (moderate, on top of what's already built): re-add a 1-field `aux_base` to the entry, capture
  it from `wdata.data` at alloc, and change the beat-spread drive's `meta_id` from
  `meta_id_base + boff` to `(boff%N==0 ? meta_id_base : aux_base) + (boff/N)`. The `core_id` retag,
  the 2-wide drain structure, and non-mergeable all stay. The cross-entry meta-overlap hazard check
  is gated for beat-spread entries (it assumes one contiguous range; beat-spread now spans two — for
  single-core streaming there is no other entry to conflict with).

**Net:** I was too quick to drop `aux_base` — point-1 is correct for a *single* burst, but the
per-burst base is unrecoverable once bursts pipeline. `aux_base` makes `meta_id` self-describing (the
slot), which is what the ROB's "data only comes out in allocation order, by absolute slot" invariant
actually needs. This is a small MSHR addition and a *simpler* VLSU receive.
