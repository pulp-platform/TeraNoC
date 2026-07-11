# 2-Wide Resp-BW — CRITICAL FINDINGS & corrected design

> **2026-07-05 RESOLUTION (supersedes the status line below).** The *corrected* contract (Option A) was
> implemented and **works**: `aux_base` (the port-1 receive-ROB base) rides the burst load's spare
> `wdata.data[IdWidth:1]` (flag in `[0]`), read pre-NoC by the MSHR; the VLSU does an N-wide receive
> routing pushes by `rsp.id`. Beat-spread completes correctly for **both distinct and same-address**
> single-core streaming, **~1.27×** each (distinct `cyc=770` vs legacy `981` for 256 words; same-addr
> `cyc=763`). The much-chased **"same-address deadlock" was a MEASUREMENT ARTIFACT** — runs were
> bounded/killed at 12–15 µs, ~1 µs before the real completion at ~16 µs (an 80 µs run prints both
> `[RESPBW]` lines). The slow tail is the post-stream `mempool_barrier` draining same-address congestion
> (beat-spread disables coalescing → 16 non-coalesced fetches to one bank); it resolves. `[CMS]`
> DUP_ALLOC/ORPHAN_RESP/STUCK are retag artifacts. **Gated OFF by default** (opt-in
> `group_mshr_drain_beats=2`) because ON disables coalescing and would regress matmul shared-B. The
> "UNIMPLEMENTABLE" verdict below is HISTORICAL — it applied to the original simple design, and Option A
> is the fix that was built. See WORKLOG 2026-07-05.

**Status: the original `docs/respbw_2wide_design.md` beat-spread design is UNIMPLEMENTABLE as written.**
Verification at Phase 1 (the step-by-step methodology) caught a fundamental datapath gap the design
deep-dive missed. This doc records the definitive trace, why the simple design fails, the corrected
contract, the (more invasive) viable options, and a value caveat. Date: 2026-06-26.

---

## 1. What the original design assumed (and got wrong)

The design assumed: *MSHR drains beat `b` of a coalesced burst onto tile resp port `1+b%N`; the tile
routes it to the right core; the VLSU reassembles N beats/cyc.* It treated the tile→VLSU path as a
transparent "the beat→lane map is carried in `meta_id`, no runtime crossbar."

**That is false.** The definitive response-path trace (all file:line verified):

1. **The tile response crossbar routes by `rdata.core_id`, NOT by the tile resp port.**
   `mempool_tile.sv:868` sets `postreg_tcdm_master_resp_ini_sel = rdata.core_id`; `:956` feeds it as
   `sel_i` to `i_remote_resp_interco` (a `stream_xbar`, NumInp=3 resp ports, NumOut=cores×dataports).
   The xbar **input** (the tile resp port the MSHR chose) is *discarded*; output = `core_id`.
2. **VLSU mem port `i` ↔ core data port `i+1`** (`spatz_mempool_cc.sv:280-293`; data port 0 = scalar
   FP-LSU). So the response lands in **VLSU ROB index = `core_id − 1`**.
3. **The VLSU pushes `spatz_mem_rsp_i[port]` into `reorder_buffer[port]`** (`spatz_vlsu.sv:1268-1277`):
   ROB index == arrival mem port; `rob_wid = rsp.id = meta_id` is only the **write slot inside that
   ROB**, never the ROB selector.
4. **`reorder_buffer` reads strictly in-order via a free-running `read_pointer`** (`reorder_buffer.sv:
   76,108-118`): `data_o = mem_q[read_pointer]`, advances on pop. The write goes to `mem_d[id_i=meta_id]`.
   **So per ROB the delivered `meta_id`s must be contiguous (base,base+1,…) or the read_pointer stalls
   on a gap.** The pointers are per-port-independent and NOT settable.

**Net:** the MSHR currently tags every beat of a lone-requester burst with the *same* `core_id`
(`sub_reqs[0].core_id`, `mempool_group_mshr.sv:1717-1719`) and `meta_id = base + b`. Therefore:
- **(a)** all beats route to the **one** ROB `core_id−1` (=ROB0). Spreading them across resp ports is a
  **no-op** — the xbar serializes same-`core_id` beats to one output, 1/cyc. (This is also why the
  enabled beat-spread *deadlocks*: the 2nd beat is back-pressured, never delivered, the entry never
  drains → `mshr_overflow`, observed in the Phase-1 enable run.)
- **(b)** even if `core_id` were retagged per beat, `meta_id = base+b` gives **strided** slots per ROB
  (ROB0 ← base+0,+2,+4 …) → gaps → the in-order `read_pointer` stalls. Wrong by construction.

---

## 2. The corrected MSHR↔VLSU contract (what 2 words/cyc actually requires)

For beat `b` of an `L`-beat coalesced burst, N receive ROBs:
- **Route:** `resp_out.rdata.core_id = sub_reqs[0].core_id + (b % N)` → lands in VLSU ROB `(b%N)`
  (data port `1 + (orig_port) + b%N`). Still emit on tile resp port `1 + b%N` so the xbar has N free
  output paths that cycle (one per target core-dataport).
- **Slot:** `resp_out.rdata.meta_id = port_base[b%N] + (b div N)` → per-ROB **contiguous** slots
  0,1,2,… so each `read_pointer` advances cleanly. **NOT** `meta_id_base + b`.
- **VLSU commit:** read ROB`[p]`.head → VRF lane `(burst_elem_idx + p) mod N_FU`, pop N ROBs/cyc.

**The blocker:** generating `meta_id = port_base[b%N] + (b div N)` needs the MSHR to know **each receive
ROB's base id** (`port_base[p]`). The burst request carries only **one** id (port-0's
`burst_base_id`). The N reorder_buffers have **independent, free-running, non-settable** read/write
pointers, so `port_base[0] ≠ port_base[1]` in general and cannot be aligned from the MSHR side.

This is the gap. It cannot be closed with an MSHR-only + "add per-port alloc" VLSU change (the original
Site-5 plan), because that plan never supplies the per-port bases to the MSHR.

---

## 3. Viable corrected designs (all more invasive than the original plan)

| Opt | Mechanism | Cost / risk |
|---|---|---|
| **A — request carries N bases** | VLSU pre-allocates N ROBs, embeds the N `port_base[p]` in the burst request flit; MSHR tags `meta_id=base[b%N]+(b div N)`, `core_id=base_core+(b%N)`. | Wider burst-request flit (NoC bw + `floo_tcdm_*`/`mempool_pkg` request-struct change + remapper); MSHR retag; VLSU Site-4/5/3. Cross-cuts NoC + MSHR + VLSU but no `reorder_buffer` change. |
| **B — aligned/settable ROB pointers** | Modify `reorder_buffer` so the N receive ROBs share one base at burst start (settable read+write ptr / sync); MSHR uses a single base + `(b div N)`. | Touches the **vendored Spatz `reorder_buffer.sv`**; risk to the proven single-port path; smallest NoC/MSHR footprint. |
| **C — 2-wide receive ROB** | Replace per-port ROBs (for burst) with one structure taking N writes + N reads/cyc. | Largest VLSU rewrite. |

All three also need: MSHR per-beat `core_id` retag (§2), VLSU receive de-gate + N-lane commit + per-port
active/pop (original Sites 3-4 + the *corrected* Site 5), and `commit_counter` step ×N.

**Key refinement (lowers Opt A cost a lot):** a burst **LOAD** request does not use the flit's write-`data`
field. So the N−1 extra ROB bases (≤5 b each at `NrOutstandingLoads=32`; exactly one extra for N=2) ride in
that **spare `data` field — NO flit-width / `floo` / routing / `mempool_pkg` change**. Opt A then reduces to
**MSHR + VLSU only**: VLSU pre-allocs N ROBs, puts `port_base[1..N-1]` (+ a "2-port-burst" flag) in the
spare data of the single port-0 request; MSHR burst-expansion reads them and tags each beat
`core_id=base_core+(b%N)`, `meta_id=port_base[b%N]+(b div N)`, resp port `1+b%N`; VLSU receives N ROBs and
commits N lanes/cyc. No vendored `reorder_buffer` change. Still substantial (MSHR expansion retag + VLSU
pre-alloc/embed/receive + the per-port-base contract), but contained to the two modules already in scope —
and every step is verifiable with `sp-mshr-burst-test` (correctness, esp. single-port + multicast untouched)
and `sp-resp-bw-stream` (1→2 effectiveness).

**Recommended:** **Option A (spare-data-field variant)** if resp-bw is pursued. But the §4 value caveat
(compute-bound headline; shared-B already multi-port multicast; only single-core resp-bound streaming
benefits) means this warrants a **human go/no-go** before the substantial blind implementation.

---

## 4. Value caveat (why this needs a human decision before more effort)

- The **primary target `sp-fmatmul` is compute-bound** (FPU floor ~16384 cyc/core; coalescing/resp-bw
  cannot raise its throughput — see memory `project_sp_fmatmul_compute_bound`). A working 2 words/cyc
  drain will show ~2× on the **`sp-resp-bw-stream` microbench** but **little/no speedup on the matmul**.
- Resp-bw *is* a stated architecture pillar ("multicast resp"), so it has **general/architectural value**
  for resp-bound kernels — but the headline workload won't demonstrate it.
- Given the invasiveness (§3) and this caveat, the cost/benefit warrants a **human call on whether to
  spend it on Option A**, vs. parking the param scaffolding and moving on.

---

## 5. State of the tree after this finding

- **MSHR reverted to clean HEAD.** My §2A beat-spread attempt is saved at
  `hardware/bottleneck_analysis/respbw_phase1_attempt/mempool_group_mshr.sv.2A_attempt` (2434 lines).
  Note: that attempt also had an **unexplained inert-path regression** — it deadlocked the benchmark even
  built with `group_mshr_drain_beats=1` (`use_beat_spread` constant-0). The legacy-path edits (drive
  reads `resp_sel_buf_ptr`/`resp_sel_beat_off`) *looked* equivalent but were not; if reused, debug that
  first (suspect: the `resp_sel_buf_ptr` capture-vs-drive timing in the combinational drain pass).
- **Phase-0 scaffolding kept** (harmless, default-off, reusable): `NumRespPorts` threaded
  tile→cc→spatz→vlsu, the `MshrDrainBeats` tile localparam, the `group_mshr_drain_beats` make-var. The
  MSHR `DrainBeatsPerEntry` localparam was reverted with the datapath.
- `docs/respbw_2wide_design.md` (the original design) is retained for reference but is **superseded by
  this doc** for the receive-path contract.

---

## 6. Recommendation / next step

1. Treat the original `respbw_2wide_design.md` Sites/phasing as **incorrect on the receive contract**.
2. If resp-bw is to be pursued: implement **Option A** (request carries N ROB bases) — it is the least
   invasive correct path; budget a NoC-request-width change + MSHR retag + VLSU multi-ROB receive, and
   verify with `sp-resp-bw-stream` (effectiveness) and `sp-mshr-burst-test` (correctness, esp. that the
   single-port and multi-requester-multicast paths are untouched).
3. Otherwise, park here: the param scaffolding is in place and the tree is clean/working.

---

## 7. Implementation attempt (2026-06-27) — Option A is far deeper than "MSHR+VLSU-only"

Per the go-ahead I traced the request side (CLEAN, no blocker: a burst load's 32-bit spare `wdata.data`
carries the 5-bit ROB base + flag; the MSHR is pre-NoC and reads `req_in.wdata.data` directly) and started
the MSHR side. Implementing immediately surfaced TWO more layers the design assumed away:

**(3) beat_spread is incompatible with the MSHR's coalescing.** A single-core 2-ROB burst cannot also be a
multi-core multicast: the owner pre-allocated 2 ROBs, so if its entry is merged (another core requests the
same line) the owner's 2nd ROB is stranded (allocated, never filled) and its VLSU hangs. So beat_spread
entries must be NON-mergeable. But the VLSU flags ALL full bursts and the MSHR's whole value is coalescing
those — so the enabled feature DISABLES coalescing for full bursts, regressing every coalescing workload
(incl. `sp-fmatmul`'s shared-B, which RELIES on it). Avoiding that regression needs a runtime SW opt-in (a
CSR the streaming kernel sets) routed snitch->controller->VLSU — the change spreads well beyond MSHR+VLSU.

**(4) The MSHR merge + hazard logic assumes ONE contiguous meta_id range per requester.** beat_spread gives
a requester TWO ROB id ranges (port0 base0..+7, port1 base1..+7) and TWO core_ids (core_id, core_id+1). The
merge-match (`req_hit_way`, :853-865) and the cross-entry meta-overlap hazard (`req_meta_ovlp_map`,
:876-888) both reason over a single (core_id, meta_id, burst_len) range; beat_spread violates that and would
false-conflict/stall. Every such check (merge-match, meta-overlap, head-beat assertion, drain
selection-by-port_id, the 2-wide retag drain itself) must be re-gated for the 2-range case — deep surgery on
the MSHR's carefully tuned coalescing core, not a localized add.

**Architecture mismatch (the root cause).** TeraNoC's response path is coalescing/multicast-oriented: route
by core_id, one ROB per core, one contiguous meta_id range per requester. The single-core / multi-port /
multi-ROB beat_spread fights every one of those invariants — which is why each implementation step uncovers
a new conflict (core_id routing -> per-port base -> coalescing -> merge/hazard ranges).

**RECOMMENDATION: PARK.** The cost (deep MSHR surgery + a coalescing regression OR a cross-module runtime
opt-in) has grown well past the narrow value: only single-core resp-bound streaming benefits, while the
headline matmul is compute-bound AND relies on the coalescing this would disable. The corrected contract +
request-side spec are fully captured above for a future scoped effort. Tree is clean; the only kept change
is an independent `sp-resp-bw-stream` barrier fix.
