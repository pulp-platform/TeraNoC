<!-- Design doc: 2-wide response-bandwidth optimization (MSHR drain + beat-spread + VLSU multi-lane receive). -->
<!-- Status: design complete 2026-06-26; implementation in progress (autonomous). -->
<!-- Measurement basis: P0 (sp-mshr-burst-test) + sustained (sp-resp-bw-stream) confirmed the per-entry 1-beat/cyc drain is the wall and the remote banks+NoC sustain >1 beat/cyc per resp port (RESP_MSHR_IN backpressure 26-27% sustained). The matmul shared-B is the lone-requester coalesced-line case this targets. Goal task #43. -->

# 2-Wide Response-Bandwidth Optimization — Implementation Design

> **2026-07-05 RESOLUTION.** Implemented and verified (~1.27x single-core streaming; both distinct and
> same-address complete). Two corrections vs this design: (1) the response contract is the aux_base
> ABSOLUTE per-port slot (`meta_id = port_base[b%N] + b/N`, base carried in the burst request's spare
> `wdata.data`), not the plain port-spread described here; (2) the feature ships OFF by default
> (opt-in `group_mshr_drain_beats=2`) because a flagged burst is non-mergeable (disables coalescing).
> See `docs/respbw_redesign_findings.md` + WORKLOG 2026-07-05.


**Target:** raise per-core remote-burst receive throughput from **1 → 2 words/cyc** at the shipped `noc_resp_channel_num=2` (terapool_spatz4_fpu), with the datapath parameterized to N = usable resp ports and **N=1 reverting to a bit-identical legacy netlist**.

**N definition (single source of truth):** N = usable remote resp ports = `NumRemoteRespPortsPerTile - 1`. At `noc_resp_channel_num=2`, `mempool_pkg.sv:370` gives `NumRemoteRespPortsPerTile = 1 + (2|2) = 3` ⇒ **N = 2**. Port 0 is the shared/scalar port; usable resp ports are the array slice `[...-1:1]`.

---

## 1. Overview — three coupled change sites and the no-op trap

A single VLSU burst is **one MSHR entry** with **one owner `sub_req`** (one `port_id` → one `map_resp_port_id`). Three independent throttles each cap that entry at 1 word/cyc. **Removing any one or two of them yields zero measurable speedup** — the remaining throttle still serializes the burst. This is the central trap and the reason all three sites must land before effectiveness is measurable.

| # | Site | File | Throttle today | Change |
|---|------|------|----------------|--------|
| A | **MSHR drain + beat-spread** | `hardware/src/mempool_group_mshr.sv` | finalize pops exactly 1 beat/cyc from the single head slot `resp_buf[rd_ptr]` (1745-1808); scan spreads one beat across *requesters* only (1588-1622) | spread an entry's **consecutive buffered beats** across N resp ports; pop up to N in-order beats/cyc |
| B | **VLSU receive de-gate + ROB pre-alloc** | `working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv` | beats landing on ports ≥1 are stale-drained (`else if(!mem_pending[port]) rob_pop`, 1315-1319); only port0 pre-allocs ROB ids (`proc_burst_alloc`); commit reads `rob_rvalid[0]` only (1180-1191) | charge `mem_pending` to N ROBs; pre-alloc ids on ports 1..N-1; commit N ROB heads/cyc into N VRF lanes |
| C | **Parameter threading** | `mempool_tile.sv` → `spatz_mempool_cc.sv` → `spatz.sv` → `spatz_vlsu.sv`; `mempool_group_mshr.sv` localparam | N hardwired to 1 on the receive side; spatz IP cannot see `mempool_pkg` | thread `NumRespPorts = NumRemoteRespPortsPerTile-1` from the tile (only module seeing both worlds); MSHR derives `DrainBeatsPerEntry` from its own param |

**Why all three move together (the no-op proof):**
- Fix A only → MSHR emits beat `b` on port1 and beat `b+1` on port2 the same cycle, but the VLSU stale-drains the port-1/2 beats (B not done) → words lost / re-fetched → no speedup, possible corruption.
- Fix B only → VLSU is ready to receive 2 ROBs/cyc, but the MSHR still emits 1 beat/cyc → ROB1 never fills → no speedup.
- Fix C only → both datapaths still hardwired N=1.

The **legality** that makes A+B sound: `mempool_tile.sv:861` routes each remote response to a core by `rdata.core_id` (the `ini_sel`), **independent of which resp port it arrives on**; the tile already RR/hash-spreads one core's responses across resp ports (`mempool_tile.sv:501-595`). So beat `b` (meta_id `base+b`) on port1 and beat `b+1` (meta_id `base+b+1`) on port2 both route to the right core into different ROB slots. **The beat→lane mapping is carried in `meta_id`; there is no runtime crossbar.**

---

## 2. Per-file exact change list

### 2A. `hardware/src/mempool_group_mshr.sv` — drain + beat-spread

> Two interlocking mechanisms are described in the source designs (an N-wide head-slot drain, and a lone-requester beat-spread pre-pass). **The implementation unifies them under one gate.** The beat-spread pre-pass is the primitive that actually delivers 2 words/cyc for the matmul (lone-requester) case; the N-wide head-slot drain generalizes the multicast path. Ship the **beat-spread pre-pass as the core mechanism**, keep the multicast path byte-for-byte unchanged, and use `DrainBeatsPerEntry` purely as the per-cycle pop cap. Anchors below are from the current 2325-line file.

**(a) New localparam — after line 104 (`RespBufPtrW`):**
```systemverilog
// Beats of ONE entry that may drain per cycle (= usable remote resp ports).
// Cheap datapath below is HARDWIRED for N<=2 (no barrel shifter). Keep at 2.
localparam int unsigned DrainBeatsPerEntry =
  `ifdef GROUP_MSHR_DRAIN_BEATS `GROUP_MSHR_DRAIN_BEATS
  `else ((NumRemoteRespPortsPerTile > 1) ? (NumRemoteRespPortsPerTile - 1) : 1) `endif;
// initial assert (DrainBeatsPerEntry <= 2);  // synthesis guard for the cheap path
```
`RespBufWords` (43-44) is unchanged — already `= N`, so depth-N `resp_buf` already buffers ≥N beats simultaneously; this is the structural enabler, not a change.

**(b) Beat-aware port map — after `map_resp_port_id` (after line 440):**
```systemverilog
function automatic logic [RespPortIdW-1:0] map_beat_resp_port_id(
    input logic [BurstLenWidth-1:0] beat_offset);
  if (NumRemoteRespPortsPerTile <= 2)            // 1 usable port -> degenerate == today
    map_beat_resp_port_id = RespPortIdW'(1);
  else
    map_beat_resp_port_id = RespPortIdW'(
        (beat_offset % BurstLenWidth'(NumRemoteRespPortsPerTile-1)) + 1);
endfunction
```
For N=2 this is a 1-bit `beat_offset[0]`-select (`1 + b%2`), no modulo hardware. `map_resp_port_id` (429-440) kept verbatim for every non-beat-spread selection.

**(c) New transient state — near declarations 288-307:**
```systemverilog
logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][RespBufPtrW-1:0]   resp_sel_buf_ptr;
logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][BurstLenWidth-1:0] resp_sel_beat_off;
logic [MshrNum-1:0][RespBufWords-1:0]                                          slot_claimed;
logic [MshrNum-1:0][RespBufWords-1:0]                                          slot_done;
logic [MshrNum-1:0]                                                            use_beat_spread;
```
No `mempool_group_mshr_t` struct change. `resp_buf_valid[]` (181) and `resp_buf_rd_ptr` (185) already exist.

**(d) Gate compute — after the init block (after 1557, before scan 1559):**
```systemverilog
for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++)
  use_beat_spread[mshr_i] = (DrainBeatsPerEntry > 1) && mshr_d_valid[mshr_i] &&
      (mshr_d[mshr_i].state == MSHR_DRAIN_RESP) &&
      (mshr_d[mshr_i].burst_len   >  BurstLenWidth'(1)) &&
      (mshr_d[mshr_i].sub_reqs_num == SubReqCountW'(1));
```
`burst_len==1` / scalar / cached / **mixed (`burst_len>1 && sub_reqs_num>1`)** all keep `use_beat_spread=0` → existing multicast path, untouched.

**(e) Reset/clear — extend existing resets (1564-1585):** default `resp_sel_buf_ptr`/`resp_sel_beat_off` to 0 alongside the `resp_sel_*` reset (1575-1577); clear `slot_claimed`/`slot_done` in the per-entry init loop (1580-1585).

**(f) Beat-spread pre-pass — insert BEFORE the multicast scan (before 1587):**
```systemverilog
for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
  automatic int drain_base = EnableRrFairness ? int'(drain_mshr_rr_q) : 0;
  for (int kk = 0; kk < MshrNum; kk++) begin
    automatic int mshr_i = (drain_base + kk) % MshrNum;
    if (use_beat_spread[mshr_i] &&
        (mshr_d[mshr_i].sub_reqs[0].tile_id == tile_group_id_t'(tile_i))) begin
      for (int k = 0; k < RespBufWords; k++) begin
        automatic logic [RespBufPtrW-1:0] r =
            RespBufPtrW'((int'(mshr_d[mshr_i].resp_buf_rd_ptr) + k) % RespBufWords);
        if (!mshr_d[mshr_i].resp_buf_valid[r]) break;            // no more buffered beats
        automatic logic [BurstLenWidth-1:0] boff =
            mshr_d[mshr_i].resp_buf[r].rdata.meta_id - mshr_d[mshr_i].sub_reqs[0].meta_id_base;
        automatic logic [RespPortIdW-1:0] p = map_beat_resp_port_id(boff);
        if (port_taken[tile_i][p] || resp_sel_valid[tile_i][p]) break;  // IN-ORDER stop
        resp_sel_valid[tile_i][p]      = 1'b1;
        resp_sel_mshr_id[tile_i][p]    = mshr_id_t'(mshr_i);
        resp_sel_subreq_idx[tile_i][p] = '0;                     // lone requester = sub_reqs[0]
        resp_sel_buf_ptr[tile_i][p]    = r;
        resp_sel_beat_off[tile_i][p]   = boff;
        slot_claimed[mshr_i][r]        = 1'b1;
      end
    end
  end
end
```
The pre-pass owns per-entry ordering (single `rd_ptr` FIFO ⇒ in-order pop). For N=2, beats `b,b+1` map to ports `1+b%2`, `1+(b+1)%2` = **distinct** → both fire same cycle. Offset collision (`b,b+2`) or a port stolen by bypass `break`s the run; the remainder waits next cycle → bounded, never lost.

**(g) Multicast scan — two edits in 1600-1614:** add `&& !use_beat_spread[mshr_i]` to the entry eligibility (1600-1601); after 1614 set, so the drive block reads slot/offset uniformly:
```systemverilog
resp_sel_buf_ptr[tile_i][port_i]  = mshr_d[mshr_i].resp_buf_rd_ptr;   // multicast = head slot
resp_sel_beat_off[tile_i][port_i] = resp_beat_offset[mshr_i];          // multicast = head offset
```
`subreq_claimed[mshr_i][s]` (1615) unchanged — multicast claims per **sub_req**; beat-spread claims per **slot**. Two independent claim axes.

**(h) Drive — make 1629-1644 slot-driven:**
```systemverilog
... .resp_buf[resp_sel_buf_ptr[tile_i][port_i]].wen;          // was resp_buf_rd_ptr  (1631)
... .resp_buf[resp_sel_buf_ptr[tile_i][port_i]].rdata.data;   // was resp_buf_rd_ptr  (1634)
resp_out[..].rdata.meta_id = mshr_d[sel].sub_reqs[idx].meta_id_base
                           + meta_id_t'(resp_sel_beat_off[tile_i][port_i]);  // was resp_beat_offset[sel]
```
core_id (1635-1637) and amo (1642-1644) unchanged (sub_req-sourced; beat-spread idx=0).

**(i) Handshake — branch at 1648-1667:**
```systemverilog
if (resp_out_ready[tile_i][port_i]) begin
  automatic mshr_id_t sel = resp_sel_mshr_id[tile_i][port_i];
  drain_count[sel] = drain_count[sel] + 1'b1;
  if (use_beat_spread[sel])
    slot_done[sel][resp_sel_buf_ptr[tile_i][port_i]] = 1'b1;       // finalize pops the run
  else begin
    mshr_d[sel].beat_pending[resp_sel_subreq_idx[tile_i][port_i]] = 1'b0;   // existing
    if (mshr_d[sel].burst_len == BurstLenWidth'(1))
      mshr_d[sel].sub_reqs[resp_sel_subreq_idx[tile_i][port_i]].valid = 1'b0;
  end
end
```

**(j) Finalize — beat-spread branch at front of per-entry body (1746-1750); existing 1751-1806 becomes the `else`:**
```systemverilog
if (use_beat_spread[mshr_i]) begin
  automatic int popped = 0;
  for (int k = 0; k < RespBufWords; k++) begin
    automatic logic [RespBufPtrW-1:0] r =
        RespBufPtrW'((int'(mshr_d[mshr_i].resp_buf_rd_ptr) + k) % RespBufWords);
    if (!slot_done[mshr_i][r]) break;                              // in-order: stop at first gap
    mshr_d[mshr_i].beat_done[ mshr_d[mshr_i].resp_buf[r].rdata.meta_id
                            - mshr_d[mshr_i].sub_reqs[0].meta_id_base ] = 1'b1;
    mshr_d[mshr_i].resp_buf_valid[r] = 1'b0;
    popped++;
  end
  if (popped != 0) begin
    mshr_d[mshr_i].resp_buf_rd_ptr =
        RespBufPtrW'((int'(mshr_d[mshr_i].resp_buf_rd_ptr) + popped) % RespBufWords);
    mshr_d[mshr_i].resp_buf_cnt = mshr_d[mshr_i].resp_buf_cnt - RespBufCountW'(popped);
    mshr_d[mshr_i].beat_pending = '0;
    if (mshr_d[mshr_i].beats_left <= BurstLenWidth'(popped)) begin
      mshr_d_valid[mshr_i] = 1'b0; mshr_d[mshr_i] = '0;            // burst drained -> dealloc
    end else begin
      mshr_d[mshr_i].beats_left = mshr_d[mshr_i].beats_left - BurstLenWidth'(popped);
      mshr_d[mshr_i].resp_valid = (mshr_d[mshr_i].resp_buf_cnt != '0);  // test POST-decrement cnt
      mshr_d[mshr_i].state =
          (mshr_d[mshr_i].resp_buf_cnt != '0) ? MSHR_DRAIN_RESP : MSHR_WAIT_RESP;
    end
  end
end else begin
  // ... existing 1751-1806 (head_beat_pending / cache-keep / single-pop) untouched ...
end
```
Impl note: write `resp_buf_cnt` first, then test `!=0`, mirroring 1797-1803.

**(k) Assertion `head_beat_must_match_subreq` (729-744):** add a disable term so the head-beat invariant is not falsely asserted on a beat-spread entry (which intentionally leaves `beat_pending==0`):
```systemverilog
... ||
(mshr_d[mshr_i].burst_len > BurstLenWidth'(1) && mshr_d[mshr_i].sub_reqs_num == SubReqCountW'(1)) ||
(resp_head_beat_pending[mshr_i]))
```

### 2B. `working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv` — receive + commit

Confirmed: `N_FU=4`, `ELEN=32`, `ELENB=4`, `vrf_data_t=128b` (4 lanes); `NrMemPorts=4`; `NrOutstandingLoads=16`; `MaxBurstWords=16`. **128b absorbs N lanes/cyc with no widening**: each cycle writes N ELEN lanes via `wbe`; `burst_word_idx` advances once per `N_FU/N` cycles, so two cycles complete a 128b row.

**Site 1 — localparam after line 70 (`FullBurstBytes`):**
```systemverilog
localparam int unsigned BurstRecvPorts = (NrMemPorts < NumRespPorts) ? NrMemPorts : NumRespPorts;
```
`NumRespPorts` is a new threaded parameter (§2C). At baseline `min(4,2)=2`.

**Site 2 — commit-counter step (831-836, `gen_vreg_counter_proc`):** burst commits `BurstRecvPorts` words/VRF-write, so `commit_counter_q[0]` steps by `BurstRecvPorts*ELENB`:
```systemverilog
automatic int unsigned grp_bytes =
    (commit_use_port0_burst && !commit_is_single_element_operation)
      ? (BurstRecvPorts*ELENB) : ELENB;
commit_operation_last[fu] = commit_operation_valid[fu] &&
    ((max_elements - commit_counter_q[fu]) <=
     (commit_is_single_element_operation ? commit_single_element_size : grp_bytes));
commit_counter_delta[fu] = !commit_operation_valid[fu] ? vlen_t'('d0) :
    commit_is_single_element_operation ? vlen_t'(commit_single_element_size) :
    commit_operation_last[fu] ? (max_elements - commit_counter_q[fu]) : vlen_t'(grp_bytes);
```
`burst_word_idx`/`vd_vreg_addr` (767-769, 547) need **no change** — `burst_elem_idx` now advances by `BurstRecvPorts` (the group base beat index).

**Site 3 — N-lane burst commit (replace `commit_use_port0_burst` block, 1180-1191):**
```systemverilog
if (commit_use_port0_burst) begin
  vrf_req_d.waddr = vd_vreg_addr;
  vrf_req_d.wdata = '0;
  vrf_req_d.wbe   = '0;
  vrf_req_valid_d = 1'b0;
  for (int unsigned p = 0; p < BurstRecvPorts; p++)
    if (mem_pending[p]) vrf_req_valid_d = 1'b1;                       // |pending
  for (int unsigned p = 0; p < BurstRecvPorts; p++)
    if (mem_pending[p] && !rob_rvalid[p]) vrf_req_valid_d = 1'b0;     // all pending heads ready
  for (int unsigned p = 0; p < BurstRecvPorts; p++) begin
    automatic logic [LaneIdxWidth-1:0] lane = (burst_elem_idx + p);   // mod N_FU (pow2 truncation)
    rob_pop[p] = rob_rvalid[p] &&
                 ((!mem_pending[p]) ||
                  (vrf_req_valid_d && vrf_req_ready_d && commit_counter_en[0]));
    if (mem_pending[p]) begin
      vrf_req_d.wdata[ELEN*lane  +: ELEN ] = rob_rdata[p];
      vrf_req_d.wbe  [ELENB*lane +: ELENB] = burst_lane_wbe;
    end
  end
end else begin
  // ... existing non-burst multi-lane path (1192-1262) unchanged ...
```
`LaneIdxWidth = $clog2(N_FU)`; pow2 `N_FU=4` ⇒ `[LaneIdxWidth-1:0]` truncation = mod N_FU.

**Site 4 — `mem_pending` spread (1020-1029):** charge the single port0 burst request to `BurstRecvPorts` ROBs (matching the MSHR spread); this is what **kills the 1315-1319 stale-drain** on receive ports:
```systemverilog
if (spatz_mem_req_valid[port] && spatz_mem_req_ready[port] && mem_req_lvalid[port]) begin
  if (mem_use_port0_burst && port == 0) begin
    for (int unsigned rp = 0; rp < BurstRecvPorts; rp++)
      mem_pending_d[rp] = mem_pending_d[rp] +
        (spatz_mem_req[0].burst_len / BurstRecvPorts) +
        ((spatz_mem_req[0].burst_len % BurstRecvPorts) > rp);
  end else
    mem_pending_d[port] = mem_pending_d[port] + spatz_mem_req[port].burst_len;
end
```

**Site 5 — pre-allocate ROB ids on receive ports 1..N-1 (the load-bearing addition; `proc_burst_alloc` 1079-1138 + `rob_req_id` wiring 1283/1311):** a port's `reorder_buffer` only returns beats if ids are allocated on that port (`read_pointer`/`burst_base_id` else stuck at 0 — `reorder_buffer.sv:61,76,108`). Mirror the port0 alloc FSM onto `p∈[1,BurstRecvPorts)` while `mem_use_port0_burst`, with per-port target `beats_per_port[p] = burst_len/N + (burst_len%N > p)`, **without ever asserting `mem_req_lvalid[p]`/`burst_send[p]`** (no request issued ⇒ issue assertion 1464-1469 stays satisfied):
```systemverilog
// in proc_burst_alloc, p in 1..BurstRecvPorts-1 when mem_use_port0_burst & is_load:
if (recv_alloc_q[p] && (recv_alloc_cnt_q[p] < beats_per_port[p]) &&
    !rob_full[p] && !offset_queue_full[p]) begin
  burst_alloc_fire[p] = 1'b1;                       // -> rob_req_id[p]
  if (recv_alloc_cnt_q[p] == '0) burst_base_id_d[p] = rob_id[p];
  recv_alloc_cnt_d[p] = recv_alloc_cnt_q[p] + 1'b1;
end
```
and at 1283 allow `rob_req_id[p] = burst_alloc_fire[p]` for receive ports even though `mem_operation_valid[p]==0` (today gated false at 857/1280).

**Site 6 — issue assertion (1464-1469): unchanged** — already keys only on `spatz_mem_req_valid[port]` (request side); request stays port0-only.

**MSHR↔VLSU contract this implies (must match §2A):** for the port0 burst of `burst_len` beats, the MSHR returns beat `b` on resp port `1 + b mod N` tagged `meta_id = meta_id_base + b`. The VLSU decodes `(port, ROB-id)` from the arrival port and `rsp.id` (pushed `rob_wid[p]=rsp.id` at 1269), reads each ROB head in id order, and maps to VRF lane `(burst_elem_idx+p) mod N_FU`.

### 2C. Parameter threading (`mempool_tile.sv` → cc → spatz → vlsu); **no `mempool_pkg.sv` change**

`mempool_pkg` is **not** visible inside the spatz IP (`grep -rln mempool_pkg working_dir/spatz/hw/ip/` ⇒ empty) and must not be — importing it inverts the IP→top-package dependency and breaks standalone spatz CI. Thread the usable-port count as a typed parameter from `mempool_tile.sv`, the lowest module that sees both `mempool_pkg` and the cc instance.

- **`spatz_vlsu.sv`** param block (~14-18): add `parameter int unsigned NumRespPorts = 1,`.
- **`spatz.sv`** (~17): add `parameter int unsigned NumRespPorts = 1,`; forward at the vlsu instance (324): `.NumRespPorts(NumRespPorts)`.
- **`spatz_mempool_cc.sv`** (~32): add `parameter int unsigned NumRespPorts = 1`; forward at the spatz instance (230): `.NumRespPorts(NumRespPorts)`.
- **`mempool_tile.sv`** cc instance (~239): `.NumRespPorts(MshrDrainBeats)` where, near the tile localparams:
```systemverilog
localparam int unsigned MshrDrainBeats =
  `ifdef GROUP_MSHR_DRAIN_BEATS `GROUP_MSHR_DRAIN_BEATS
  `else (mempool_pkg::NumRemoteRespPortsPerTile - 1) `endif;
```
- **`hardware/Makefile`** (~168-178, beside the other `group_mshr_*`):
```makefile
group_mshr_drain_beats ?=          # empty = derived (wide). =1 -> legacy single-beat A/B.
ifneq ($(strip $(group_mshr_drain_beats)),)
  vlog_defs += -DGROUP_MSHR_DRAIN_BEATS=$(group_mshr_drain_beats)
endif
```
The **same** `GROUP_MSHR_DRAIN_BEATS` define feeds both the MSHR `DrainBeatsPerEntry` localparam (§2A-a) and the tile `MshrDrainBeats` → VLSU `NumRespPorts`, so both ends move together — single source of truth.

---

## 3. Parameterization summary

| Param | Where declared | Value (baseline) | Meaning |
|-------|----------------|------------------|---------|
| `NumRemoteRespPortsPerTile` | `mempool_pkg.sv:370` (existing) | 3 | physical resp ports incl. shared port0 |
| `DrainBeatsPerEntry` | `mempool_group_mshr.sv` localparam (§2A-a) | 2 | MSHR beats popped per entry per cycle |
| `NumRespPorts` | threaded param, tile→cc→spatz→vlsu (§2C) | 2 | usable resp ports seen by spatz IP |
| `BurstRecvPorts` | `spatz_vlsu.sv` localparam (§2B-1) | `min(NrMemPorts, NumRespPorts)=2` | ROBs receiving one burst |
| `GROUP_MSHR_DRAIN_BEATS` | make-var → vlog define | unset (derived) | A/B clamp; `=1` → legacy |

**Cross-repo rule:** the spatz IP stays self-describing (typed params only); the usable-resp-port count is a **parameter**, never read from `mempool_pkg`. The MSHR derives `DrainBeatsPerEntry` from its own `NumRemoteRespPortsPerTile` parameter. `N=1` (or `group_mshr_drain_beats=1`) reverts both sides to the bit-identical single-beat netlist via the `if (DrainBeatsPerEntry > 1)` / `use_beat_spread` gates and `BurstRecvPorts=min(...,1)=1`.

---

## 4. Correctness invariants

1. **Request side untouched.** One coalescable 16-word / single-core / `burst_len=16` request still issues on port0 only; `spatz_mem_req_valid[≥1]=0` (issue assertion 1464-1469 holds). MSHR alloc/merge/`sub_req` reservation logic is unchanged. The optimization is **receive-only**.
2. **Coalesced multicast still works.** `use_beat_spread` is gated to `sub_reqs_num==1`; any multi-requester entry stays on the existing per-(tile,port) scan (1588-1622) with `map_resp_port_id` and `subreq_claimed` — byte-for-byte unchanged. The two claim axes (`slot_claimed` per beat-slot vs `subreq_claimed` per sub_req) never interfere.
3. **Mixed coalesced+multibeat (`burst_len>1 && sub_reqs_num>1`) → multicast.** Applying beat-spread here would map all N requesters of head beat `b` onto the single port `map_beat(b)`, serializing the multicast and idling the rest — a regression of the very bandwidth multicast protects. Gating on `sub_reqs_num==1` routes mixed entries to the head-beat multicast (per-requester port spread, one beat popped per fully-multicast beat). A burst that starts lone-requester and later coalesces a 2nd requester flips `use_beat_spread→0` the next cycle and continues on multicast with **no in-flight slot lost** (`slot_done`/`slot_claimed` recomputed every cycle; `beat_pending` re-inits from `sub_reqs[*].valid`).
4. **`meta_id` carries the beat→lane map — no runtime crossbar.** MSHR tags beat `b` with `meta_id_base + b` on port `1+b%N`; the tile routes by `rdata.core_id` independent of arrival port (`mempool_tile.sv:861`); the VLSU decodes lane `(burst_elem_idx+p) mod N_FU` from arrival port + `rsp.id`. All mapping is static index arithmetic.
5. **In-order FIFO preserved.** Both the MSHR pre-pass (run from `rd_ptr`, `break` on first gap) and finalize (contiguous `slot_done` run from `rd_ptr`) keep the single-`rd_ptr` `resp_buf` strictly in order; a not-ready port stalls the run, never reorders it.
6. **Buffer invariant.** `resp_buf_cnt ≤ RespBufWords = N` holds (capture fills ≤N, drain frees ≤N/cyc); `resp_buf_cnt_in_range` (682-687) unchanged.
7. **VLSU completion.** `mem_pending` is charged across N ROBs (`burst_len/N + remainder`) and drained by N `rob_pop`/cyc; the VRF row completes after `N_FU/N` cycles; `commit_operation_last` accounts for the `grp_bytes` step so the final (possibly odd-tail) group terminates exactly at `vl`.

---

## 5. Risks (ordered, with mitigations)

1. **STA on the widened MSHR drain scan (highest).** The selection scan is the module's critical path: `O(NumTiles × (N) × MshrNum × MshrMergeReqs)` comparators → per-(tile,port) priority mux. Adding a slot axis + 2nd `resp_buf` read risks a critical-path blow-up.
   - *Mitigations:* (a) **Hoist the 2nd read out of the scan** — `resp_beat_offset[mshr_i][0..1]` and slot pointers precomputed once per entry; the scan only muxes a precomputed 2:1 (`sl==0 ? rdp : nxt`), and `nxt` for depth-2 is `rd_ptr^1` (a wire, no adder). This is the single biggest saver. (b) **Fix N=2, no barrel shifter** — `(rd_ptr+j)%depth`, `map_beat_resp_port_id`'s `%(N-1)`, and the leading-done priority all degenerate to 1-bit selects/inverts at N=2. (c) **Gate everything under `if (DrainBeatsPerEntry > 1)`** so N=1 is the untouched netlist. (d) Do **not** generalize to arbitrary N — each generalization stacks a barrel shifter on the heavy scan. Verify with a post-`make compile` STA/timing report on `mempool_group_mshr` before and after.
2. **VLSU receive/commit ROB accounting (Site 5 is load-bearing).** A naive "push to ROB[p]" without per-port id pre-allocation silently never reads (`read_pointer` stuck at 0) — words are accepted but never written to VRF → wrong results, not a hang.
   - *Mitigation:* implement Site 5 (pre-alloc ids on ports 1..N-1, capture `burst_base_id_d[p]`, never assert `mem_req_lvalid[p]`) **as part of the same phase** as Sites 3-4; never ship Site 3 without Site 5. Cross-check the MSHR beat→(port,id) tagging against the VLSU decode with a directed `sp-mshr-burst-test` waveform (confirm each ROB head's `rsp.id == burst_base_id[p] + (b div N)`).
3. **Mixed-case regression (functional).** If the `sub_reqs_num==1` gate is wrong (e.g. evaluated against `mshr_q` instead of `mshr_d`, or a stale `sub_reqs_num`), a multi-requester burst could enter beat-spread and serialize/lose multicast beats.
   - *Mitigation:* gate on `mshr_d` (live) `sub_reqs_num`; assertion (§2A-k) covers the head-beat invariant; add a directed coalesced-burst case to `sp-mshr-burst-test` (P2/P3 already coalesce a remote line) and confirm multicast bandwidth unchanged.
4. **Deadlock-freedom of the wider drain (lowest, but fatal if wrong).** The pre-pass `break`-on-gap and finalize `break`-on-first-undelivered are what bound progress; a mis-ordered pop (popping slot1 before slot0) would corrupt `rd_ptr` and wedge the entry.
   - *Mitigation:* both loops start at `rd_ptr` and stop at the first non-ready/non-done slot — strictly in-order, so `rd_ptr` always advances by a contiguous prefix. The `beat_done` marking on held-ahead slots prevents re-init churn. Verify no new `[CMS WARN]` stuck-request (>1000 cyc) or `[GroupMerge]` anomalies on a full `sp-fmatmul` run; confirm `[GBAR]` arrives==releases.

---

## 6. Phased implementation plan

**Correctness vs effectiveness:** every phase is independently **compilable** and **correctness-verifiable** via `sp-mshr-burst-test` (must PASS) and `sp-fmatmul` (must complete + verify). **Effectiveness (1→2 words/cyc) is only measurable after all three sites land**, via `sp-resp-bw-stream` (single-core lone-requester burst stream) reading the MSHR `EnableStats` drain counters and per-core burst-receive cycles. State this up front to set expectations: **Phases 0-3 prove "no regression"; only Phase 4 shows speedup.** All sims run on `terapool_spatz4_fpu` (only flavor that boots on this branch). Use `make -o update-floogen` and force vlog with `rm build_X/compile.tcl` to dodge the known build gotchas.

### Phase 0 — Parameter threading only (no behavior change)
- **Edits:** §2C in full — add `NumRespPorts` params to vlsu/spatz/cc (default 1), thread from `mempool_tile.sv`; add `DrainBeatsPerEntry` localparam to MSHR (§2A-a) but **do not** yet use it; add the `group_mshr_drain_beats` make-var/define. No datapath touched.
- **Compile:** `cd hardware && app=apps/spatz_apps/sp-mshr-burst-test make -o update-floogen simc config=terapool_spatz4_fpu buildpath=build_p0` (confirm `Compiling module mempool_group_mshr`, `spatz_vlsu`, `mempool_tile`).
- **Regression:** `sp-mshr-burst-test` PASS; `sp-fmatmul` (256x32x256) completes + verifies.
- **Observable:** netlist bit-identical to today (params default-on but unused on receive side, MSHR gated `>1` paths cold). No counter change.

### Phase 1 — MSHR drain + beat-spread, behind the gate (correctness only)
- **Edits:** §2A-b…k in full. Default `DrainBeatsPerEntry=2`. The VLSU receive side is still legacy (stale-drains ports ≥1), so the **MSHR will emit 2 beats/cyc but the VLSU drops the port-1 beat** — to keep this phase correct, **build it with `group_mshr_drain_beats=1`** so `use_beat_spread` stays 0 and the MSHR is byte-for-byte legacy; this validates that the *added code compiles and is inert when gated off*.
- **Compile:** `... make -o update-floogen simc config=terapool_spatz4_fpu group_mshr_drain_beats=1 buildpath=build_p1` (confirm `Compiling module mempool_group_mshr`).
- **Regression:** `sp-mshr-burst-test` PASS; `sp-fmatmul` completes + verifies; no new `[CMS WARN]`.
- **Observable:** identical to Phase 0. (This phase de-risks the large MSHR diff in isolation — it proves the new code is correctly gated before any datapath actually widens.)

### Phase 2 — VLSU receive de-gate + ROB pre-alloc, behind the gate (correctness only)
- **Edits:** §2B Sites 1-6 in full. Still built with `group_mshr_drain_beats=1` ⇒ `NumRespPorts=1` ⇒ `BurstRecvPorts=min(4,1)=1` ⇒ the new `for p<BurstRecvPorts` loops degenerate to the single-port body, Site 5 pre-alloc loop is empty (`p∈[1,1)`), Site 4 spread is a single-ROB add. Datapath functionally legacy.
- **Compile:** `... make -o update-floogen simc config=terapool_spatz4_fpu group_mshr_drain_beats=1 buildpath=build_p2` (confirm `Compiling module spatz_vlsu`).
- **Regression:** `sp-mshr-burst-test` PASS; `sp-fmatmul` completes + verifies.
- **Observable:** identical to Phase 0/1. Both repos now contain the full feature, provably inert at N=1.

### Phase 3 — Enable N=2 on the MSHR side only (negative control / de-risk)
- **Edits:** none. Build the **Phase 1 RTL alone** (VLSU still legacy) with `group_mshr_drain_beats` unset (derived → 2). This is the **no-op-trap demonstration**: MSHR emits 2 beats/cyc, VLSU receive-gate intact.
- **Compile:** `... make -o update-floogen simc config=terapool_spatz4_fpu buildpath=build_p3` against a build that has only §2A (not §2B). *(If §2A and §2B share a working tree, skip Phase 3 and rely on Phase 4 + the no-op argument in §1.)*
- **Expected:** `sp-mshr-burst-test` may show dropped/refetched beats or, with the de-gate absent, **no speedup** on `sp-resp-bw-stream` — confirming the coupling. If it instead corrupts, that flags a missing VLSU drop-gate, caught before the full enable.

### Phase 4 — Full enable (effectiveness measurable)
- **Edits:** none. Build the complete tree (§2A+§2B+§2C) with `group_mshr_drain_beats` unset (derived → 2) ⇒ `DrainBeatsPerEntry=2`, `NumRespPorts=2`, `BurstRecvPorts=2`.
- **Compile:** `... make -o update-floogen simc config=terapool_spatz4_fpu buildpath=build_p4` (confirm all three modules recompiled).
- **Regression (correctness gate):** `sp-mshr-burst-test` PASS; `sp-fmatmul` completes + verifies (worst diff within tol); no new `[CMS WARN]` stuck (>1000 cyc), no orphan/dup-id; `[GroupMerge]` merge efficiency unchanged for the coalesced cases; `[GBAR]` arrives==releases.
- **Effectiveness (the payoff):** `sp-resp-bw-stream` — single-core lone-requester `burst_len=16` stream — with MSHR `group_mshr_enable_stats=1`. **A/B on identical RTL/NoC:** run once with `group_mshr_drain_beats=1` (= A, legacy 1 word/cyc) and once unset (= B, wide). Expected: per-burst receive cycles ≈ halve (16→~8), MSHR `drain_count` reaching 2/cyc, per-core resp throughput **~1→~2 words/cyc**. Because the A/B knob holds the hardware and NoC fixed, the delta is a clean speedup attributable solely to the drain width — **not** confounded by `noc_resp_channel_num` (which would also change NoC bandwidth).

**Recommended ordering rationale:** params first (Phase 0, zero-risk scaffolding) → big MSHR diff inert-gated (Phase 1) → VLSU receive de-gate inert-gated (Phase 2) → optional negative control (Phase 3) → flip the single `group_mshr_drain_beats` knob to enable and measure (Phase 4). Each phase compiles and passes `sp-mshr-burst-test` before the next; the only phase that *can* regress correctness (Phase 4) is reached only after both datapaths are proven inert at N=1, and it carries a built-in A/B back-out (`group_mshr_drain_beats=1`) with no RTL revert.

---

### Files touched (absolute)
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/src/mempool_group_mshr.sv` — §2A (localparam ~104; `map_beat_resp_port_id` after 440; transient state 288-307; gate after 1557; resets 1564-1585; pre-pass before 1587; scan edits 1600-1614; drive 1629-1644; handshake 1648-1667; finalize 1746-1750; assertion 729-744).
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv` — §2B Sites 1-6 (localparam after 70; counter 831-836; commit 1180-1191; pending 1020-1029; `proc_burst_alloc` 1079-1138 + `rob_req_id` 1283/1311; param block 14-18).
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz/src/spatz.sv` — param ~17 + forward 324.
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz_cc/src/spatz_mempool_cc.sv` — param ~32 + forward 230.
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/src/mempool_tile.sv` — `MshrDrainBeats` localparam + `.NumRespPorts` on cc instance ~239.
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/Makefile` — `group_mshr_drain_beats` → `-DGROUP_MSHR_DRAIN_BEATS` ~168-178.
- **No `mempool_pkg.sv` change; no config `.mk` knob** (A/B is a transient make-var override on fixed RTL).

Reorder-buffer constraint reference: `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz/src/reorder_buffer.sv:61,76,108`. Resp-port routing reference: `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/src/mempool_tile.sv:861,501-595`.
---

## 7. PPA feasibility analysis (HW project — explicit budget)

No DC/Genus in this environment, so feasibility is argued by FF/gate count + critical-path reasoning and gated by **Spyglass `make lint`** at each phase. The design is reuse-first and N=2-fixed by construction.

### Area
- **MSHR: zero new flip-flops.** Every new signal (`use_beat_spread`, `slot_claimed`, `slot_done`, `resp_sel_buf_ptr`, `resp_sel_beat_off`, the per-slot offsets) is **transient/combinational** — recomputed each cycle inside the existing drain `always_comb`, not registered. The `mempool_group_mshr_t` struct is **unchanged** (no per-entry FF growth across MshrNum=64). `resp_buf` is already `RespBufWords=N=2` deep — **no storage added** for the widening. Net MSHR area = a few hundred extra combinational gates per group (the pre-pass loop + the scan slot-axis unroll + the finalize beat-spread branch), ×16 groups.
- **VLSU: reuse only.** The 4 `reorder_buffer`s, 4 address generators, 4 counters, and the per-port `proc_burst_alloc` FSM are **already instantiated** (NrMemPorts=N_FU=4). Site 5 mirrors the existing port-0 alloc FSM onto port 1 (one extra port active for receive) — no new structure type. The **128b `vrf_data_t` write port already exists** (4 lanes; only 1 used in burst today) — the N-lane commit writes 2 lanes/cyc into it, **no port widening**. Net VLSU area = a small commit-loop (N=2 unroll) + the receive-port alloc enable.

### Timing (the one real STA item)
The MSHR drain **selection scan** is the module's critical path: `O(NumTilesPerGroup × N × MshrNum × MshrMergeReqs)` comparators → per-(tile,port) priority mux. The change adds (i) a beat-spread **pre-pass** combinational loop before the scan and (ii) a slot axis + a 2nd `resp_buf` read.
- **Mitigations baked in:** (a) **hoist the 2nd read out of the scan** — `resp_beat_offset[*][0..1]` and slot pointers precomputed once per entry; the scan only muxes a precomputed 2:1, and for depth-2 `nxt = rd_ptr ^ 1` is a *wire* (no adder). (b) **N=2 fixed** → every `%(N-1)`, `(rd_ptr+j)%depth`, `map_beat_resp_port_id` `%`, and the leading-done priority degenerate to **1-bit selects/inverts** — no barrel shifter, no variable modulo. (c) **gate under `DrainBeatsPerEntry>1`** so N=1 is the *bit-identical untouched netlist*. (d) **do not generalize to arbitrary N** (each generalization stacks a barrel shifter on the heavy scan).
- **Sign-off action:** capture the QuestaSim `voptk2`/elaboration timing and, where available, a static timing estimate on `mempool_group_mshr` before/after; if the pre-pass+scan extends the critical path, register the pre-pass result (pipeline the selection by one cycle — the drain FSM already spans multiple cycles in `MSHR_DRAIN_RESP`, so a 1-cycle selection pipe is latency-tolerant).

### Power
The 2nd drain lane and the 2nd VLSU receive port **toggle only during burst-response drains** (data-gated by traffic) — no always-on dynamic cost. The `DrainBeatsPerEntry=1` / `group_mshr_drain_beats=1` build adds **zero** toggling (gated off, netlist-identical), so the feature is free when disabled.

### Verdict
Area: negligible (no FF, combinational + reuse). Power: traffic-gated. Timing: one scan critical-path item, mitigated by hoisting + N=2-fixed + the latency-tolerant pipeline fallback. **PPA-feasible.** Re-evaluate the scan timing empirically at Phase 4.


---

## Appendix A — MSHR N-wide drain (detailed)

Complete. Below is the exact implementation design. File: `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/src/mempool_group_mshr.sv` (2325 lines; all anchors confirmed against the current file).

---

## Validated premise (load-bearing)

A single VLSU burst = ONE entry with ONE owner `sub_req` (one `port_id` → one `map_resp_port_id`). The current finalize (1745-1808) pops exactly ONE buffered beat/cycle, so that entry delivers 1 word/cyc on 1 port. To reach N words/cyc the SAME entry must drive N usable resp ports in one cycle. That is legal: `mempool_tile.sv:861` routes each remote response to a core by `rdata.core_id` (the `ini_sel`), **independent of which resp port it arrives on**, and the tile already RR/hash-spreads one core's responses across resp ports (`mempool_tile.sv:501-595`). So beat `b` on port p1 and beat `b+1` on port p2 (same `core_id`, `meta_id = base+b` / `base+b+1`) both route to the right core, different ROB slots. The design below spreads an entry's consecutive beats across the N usable ports.

---

## 0. New localparam — fix N=2, gate the whole feature

Add near the width localparams (after line 104, `RespBufPtrW`):

```systemverilog
// N-wide per-entry response drain. Default = usable resp ports (== RespBufWords),
// but the cheap datapath below is HARDWIRED for N<=2 (no barrel shifter). Keep at 2.
localparam int unsigned DrainBeatsPerEntry =
    `ifdef GROUP_MSHR_DRAIN_BEATS `GROUP_MSHR_DRAIN_BEATS
    `else ((RespBufWords < 2) ? 1 : 2) `endif;
localparam int unsigned DrainSlotW = (DrainBeatsPerEntry > 1) ? $clog2(DrainBeatsPerEntry) : 1;
// synthesis guard: the cheap path assumes N<=2.
// initial assert (DrainBeatsPerEntry <= 2);
```

Wrap every multi-beat addition below in `if (DrainBeatsPerEntry > 1)` so **N=1 stays bit-identical** to today's netlist (no 2nd read port, no slot loop, no 2-bit claimed).

## 1. resp_buf depth — NO change (confirmed)

`RespBufWords` (lines 43-44) `= NumRemoteRespPortsPerTile-1 = N`. For N=2, depth=2. We read slots `rd_ptr` and `(rd_ptr+1)%2` = all of `resp_buf`; capture (1432-1438, 1508-1519) still fills ≤ `RespBufWords`; drain frees ≤ N/cyc. Invariant `resp_buf_cnt ≤ RespBufWords = N` holds, so K ≤ cnt ≤ depth. **No depth change for N=2.** `resp_buf_cnt_in_range` (682-687) is unchanged.

## 2. N `beat_pending` bitmaps (struct field, line 168)

```systemverilog
// before: logic [MshrMergeReqs-1:0] beat_pending;
logic [DrainBeatsPerEntry-1:0][MshrMergeReqs-1:0] beat_pending;  // [slot][requester]
```
`beat_pending[0]` == today's head bitmap (slot at `rd_ptr`); `beat_pending[1]` tracks the slot at `(rd_ptr+1)%depth`. The req-side resets `... .beat_pending = '0;` (1311, 1359) still clear all slots — unchanged. Ripple (all index `[0]` = head, to stay semantically identical):
- Assertion `head_beat_must_match_subreq` (744): `...beat_pending` → `...beat_pending[0]`.
- `$display` debug (1068, 1089, 1127, 1193, 1210, 1219, 1222, 1234): `beat_pending` → `beat_pending[0]` (head); optionally add a `[1]` print.

## 2b. N `resp_beat_offset` values (decl line 293; compute 1528-1544)

```systemverilog
// decl (293):
logic [MshrNum-1:0][DrainBeatsPerEntry-1:0][BurstLenWidth-1:0] resp_beat_offset;
```
```systemverilog
// compute (replace 1528-1544): both head slots' offsets, no barrel shifter
for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
  automatic logic [RespBufPtrW-1:0] rdp = mshr_d[mshr_i].resp_buf_rd_ptr;
  automatic logic [RespBufPtrW-1:0] nxt = (rdp == RespBufPtrW'(RespBufWords-1)) ? '0 : rdp + 1'b1;
  for (int j = 0; j < DrainBeatsPerEntry; j++) begin
    automatic logic [RespBufPtrW-1:0] sp = (j == 0) ? rdp : nxt;     // 2:1 mux only
    resp_beat_offset[mshr_i][j] = '0;
    if (mshr_d_valid[mshr_i] && (RespBufCountW'(j) < mshr_d[mshr_i].resp_buf_cnt)) begin
      if (mshr_d[mshr_i].burst_len != BurstLenWidth'(1))
        resp_beat_offset[mshr_i][j] =
            mshr_d[mshr_i].resp_buf[sp].rdata.meta_id - mshr_d[mshr_i].sub_reqs[0].meta_id_base;
    end
  end
end
```
Ripple: assertion `resp_offset_in_range` (678, 680) → `resp_beat_offset[mshr_i][0]`. The DrainMultiPort=0 path (1726) → `resp_beat_offset[mshr_i][0]`.

## 2c. Per-slot init guard (replace 1546-1557)

Slot 0 keeps the EXACT original guard (`beat_pending[0]=='0`) so single-word / N=1 / atomic pop-reinit is unchanged. Higher slots add a `!beat_done[offset_j]` guard so a **drained-but-held** slot1 is not re-initialized across the cycle boundary:

```systemverilog
for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
  if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].state == MSHR_DRAIN_RESP) &&
      (mshr_d[mshr_i].resp_buf_cnt != '0) && (mshr_d[mshr_i].sub_reqs_num != '0)) begin
    for (int j = 0; j < DrainBeatsPerEntry; j++) begin
      automatic logic fresh = (j == 0)
          ? (mshr_d[mshr_i].beat_pending[0] == '0)                       // head: original guard
          : ((RespBufCountW'(j) < mshr_d[mshr_i].resp_buf_cnt) &&
             (mshr_d[mshr_i].beat_pending[j] == '0) &&
             !mshr_d[mshr_i].beat_done[resp_beat_offset[mshr_i][j]]);    // held-slot guard
      if (fresh)
        for (int s = 0; s < MshrMergeReqs; s++)
          mshr_d[mshr_i].beat_pending[j][s] = mshr_d[mshr_i].sub_reqs[s].valid;
    end
  end
end
```

## 3. Selection scan + drive — add the slot axis (DrainMultiPort=1 path, 1573-1670)

New helper (next to `map_resp_port_id`, ~440): per-slot port = natural port shifted by slot index across the N usable ports. For N=2/usable=2 this is just "the other port" (1-bit invert, no barrel):

```systemverilog
function automatic logic [RespPortIdW-1:0] drain_port_of(
    input logic [RespPortIdW-1:0] req_port_id, input int j);
  automatic int usable = NumRemoteRespPortsPerTile - 1;          // = N
  automatic int base0  = int'(map_resp_port_id(req_port_id));    // 1..usable
  drain_port_of = RespPortIdW'(((base0 - 1 + j) % usable) + 1);
endfunction
```

New scheduling decls (after 291 / 307):
```systemverilog
logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][DrainSlotW-1:0]    resp_sel_slot;
logic [MshrNum-1:0][DrainBeatsPerEntry-1:0][MshrMergeReqs-1:0]                 subreq_claimed; // was [MshrNum][MshrMergeReqs]
```
Reset `subreq_claimed` (1582-1584) gains a `j` loop. Scan inner body (1605-1616) wraps the eligibility in a slot loop (unrolled, j∈{0,1}); `beat_pending` and `subreq_claimed` indexed by slot, port matched per-slot:

```systemverilog
for (int j = 0; j < DrainBeatsPerEntry; j++) begin
  if (!resp_sel_valid[tile_i][port_i] &&
      (RespBufCountW'(j) < mshr_d[mshr_i].resp_buf_cnt) &&        // slot j present
      mshr_d[mshr_i].sub_reqs[s].valid &&
      mshr_d[mshr_i].beat_pending[j][s] &&
      !subreq_claimed[mshr_i][j][s] &&
      (mshr_d[mshr_i].sub_reqs[s].tile_id == tile_group_id_t'(tile_i)) &&
      (drain_port_of(mshr_d[mshr_i].sub_reqs[s].port_id, j) == port_i[RespPortIdW-1:0])) begin
    resp_sel_valid[tile_i][port_i]      = 1'b1;
    resp_sel_mshr_id[tile_i][port_i]    = mshr_id_t'(mshr_i);
    resp_sel_subreq_idx[tile_i][port_i] = s[idx_width(MshrMergeReqs)-1:0];
    resp_sel_slot[tile_i][port_i]       = DrainSlotW'(j);
    subreq_claimed[mshr_i][j][s]        = 1'b1;
  end
end
```
A given owner `s` can now be selected on TWO ports the same cycle (slot 0 on its natural port, slot 1 on the other) — `drain_port_of(.,0) != drain_port_of(.,1)` guarantees no port double-drive; the per-(tile,port) first-match mux still serializes one delivery per port.

Drive (1627-1667): pick the slot's buffer pointer + offset, clear the slot's bit:
```systemverilog
automatic logic [DrainSlotW-1:0]   sl  = resp_sel_slot[tile_i][port_i];
automatic logic [RespBufPtrW-1:0]  rdp = mshr_d[id].resp_buf_rd_ptr;
automatic logic [RespBufPtrW-1:0]  sp  = (sl == '0) ? rdp
                       : ((rdp == RespBufPtrW'(RespBufWords-1)) ? '0 : rdp + 1'b1);  // 2:1 mux
resp_out[..].wen        = mshr_d[id].resp_buf[sp].wen;
resp_out[..].rdata.data = mshr_d[id].resp_buf[sp].rdata.data;
resp_out[..].rdata.meta_id = mshr_d[id].sub_reqs[idx].meta_id_base
                           + meta_id_t'(resp_beat_offset[id][sl]);
// on resp_out_ready:
mshr_d[id].beat_pending[sl][idx] = 1'b0;
if (mshr_d[id].burst_len == BurstLenWidth'(1)) mshr_d[id].sub_reqs[idx].valid = 1'b0; // single only
drain_count[id] = drain_count[id] + 1'b1;
```
(`id`=`resp_sel_mshr_id[tile_i][port_i]`, `idx`=`resp_sel_subreq_idx[...]`.) The DrainMultiPort=0 legacy path (1672-1742) just gets `beat_pending`→`beat_pending[0]`, `resp_beat_offset[mshr_i]`→`resp_beat_offset[mshr_i][0]` — single-slot, unchanged behavior.

## 3b. K-saturating N-wide pop (rewrite finalize 1745-1808)

`K = leading count of in-order "done" slots`, clamped by `beats_left`. A slot is "done" iff present AND its bitmap fully drained (the "#ports-that-drained" term is *implicit*: a slot's bitmap only clears when all its sub_reqs handshaked across their ports). Held-ahead slot1 is marked `beat_done` but not popped until slot0 catches up; K==1 SHIFTS `beat_pending[1]→[0]` to preserve slot1's partial progress.

```systemverilog
for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
  resp_head_beat_pending[mshr_i] = 1'b0;
  resp_cnt_after_pop[mshr_i]     = mshr_d[mshr_i].resp_buf_cnt;
  if (mshr_d_valid[mshr_i] && (mshr_d[mshr_i].resp_buf_cnt != '0) &&
      (mshr_d[mshr_i].state == MSHR_DRAIN_RESP)) begin
    automatic logic [RespBufPtrW-1:0] rdp = mshr_d[mshr_i].resp_buf_rd_ptr;
    automatic logic [RespBufPtrW-1:0] nxt = (rdp==RespBufPtrW'(RespBufWords-1)) ? '0 : rdp+1'b1;
    // per-slot done (present, fully drained, within remaining burst)
    automatic logic d0 = (mshr_d[mshr_i].beat_pending[0] == '0);
    automatic logic d1 = (DrainBeatsPerEntry > 1) &&
                         (RespBufCountW'(1) < mshr_d[mshr_i].resp_buf_cnt) &&
                         (BurstLenWidth'(1) < mshr_d[mshr_i].beats_left) &&
                         (mshr_d[mshr_i].beat_pending[1] == '0);
    automatic int K = d0 ? (d1 ? 2 : 1) : 0;            // priority encoder over 2 bits
    resp_head_beat_pending[mshr_i] = ~d0;
    if (d0) mshr_d[mshr_i].beat_done[resp_beat_offset[mshr_i][0]] = 1'b1; // mark even if held
    if (d1) mshr_d[mshr_i].beat_done[resp_beat_offset[mshr_i][1]] = 1'b1;

    if (K != 0) begin
      // --- CACHED special case: ONLY single-word final beat (K is necessarily 1 here:
      //     burst_len==1 => cnt<=1 => d1==0). Keep existing 1764-1772 body verbatim. ---
      if ((mshr_d[mshr_i].beats_left == BurstLenWidth'(1)) && EnableRespCache &&
          !amo_invalidate && (mshr_d[mshr_i].burst_len == BurstLenWidth'(1))) begin
        for (int s=0;s<MshrMergeReqs;s++) mshr_d[mshr_i].sub_reqs[s].valid = 1'b0;
        mshr_d[mshr_i].sub_reqs_num = '0;
        mshr_d[mshr_i].beat_pending = '0;
        mshr_d[mshr_i].beats_left   = '0;
        mshr_d[mshr_i].state        = MSHR_CACHED;
        mshr_d[mshr_i].resp_valid   = (mshr_d[mshr_i].resp_buf_cnt != '0);
      end else begin
        // --- pop K beats (N<=2: no barrel shifter) ---
        mshr_d[mshr_i].resp_buf_valid[rdp] = 1'b0;
        if (K == 2) mshr_d[mshr_i].resp_buf_valid[nxt] = 1'b0;
        if (RespBufWords > 1)
          mshr_d[mshr_i].resp_buf_rd_ptr = (K == 2) ? rdp        // +2 mod 2 == rdp
                                                    : nxt;       // +1
        resp_cnt_after_pop[mshr_i]   = mshr_d[mshr_i].resp_buf_cnt - RespBufCountW'(K);
        mshr_d[mshr_i].resp_buf_cnt  = resp_cnt_after_pop[mshr_i];
        // shift held/partial slot1 into the new head, clear the now-vacant top slot
        if (K == 1) mshr_d[mshr_i].beat_pending[0] = mshr_d[mshr_i].beat_pending[1];
        mshr_d[mshr_i].beat_pending[DrainBeatsPerEntry-1] = '0;
        if (K == 2) mshr_d[mshr_i].beat_pending[0] = '0;
        // beats_left / dealloc
        if (mshr_d[mshr_i].beats_left <= BurstLenWidth'(K)) begin
          mshr_d_valid[mshr_i] = 1'b0;  mshr_d[mshr_i] = '0;          // last beats
        end else begin
          mshr_d[mshr_i].beats_left = mshr_d[mshr_i].beats_left - BurstLenWidth'(K);
          mshr_d[mshr_i].state      = (resp_cnt_after_pop[mshr_i] != '0) ? MSHR_DRAIN_RESP
                                                                         : MSHR_WAIT_RESP;
          mshr_d[mshr_i].resp_valid = (resp_cnt_after_pop[mshr_i] != '0);
        end
      end
    end
  end
end
```

Why the SHIFT + `beat_done` guard are both needed (the only correctness subtlety):
- **K==1 (slot0 done, slot1 partial):** rd_ptr+1 makes old slot1 the new head; `beat_pending[0] ← beat_pending[1]` carries its partial mask. Next cycle init sees `beat_pending[0]!=0` → skips (no re-init, progress kept).
- **K==0 with slot1 done (held ahead):** nothing pops; `beat_done[offset1]` set this cycle → next-cycle init's `!beat_done[offset_j]` guard skips re-init of the held slot1. When slot0 finally drains, d0&d1 → K==2, both pop.
- **K==2:** both popped, rd_ptr wraps full circle (depth-2), both bitmaps cleared; next-cycle init repopulates genuinely-new head slots (`beat_done` clear for new offsets).

Assertion `head_beat_must_match_subreq` (738/744): `resp_head_beat_pending` now `= ~d0` (head=slot0), so it still holds; change `beat_pending` at 744 → `beat_pending[0]`.

---

## STA risk + how to keep it cheap

The selection scan (1588-1622) is the module's critical path: `O(NumTiles × (Nports-1) × MshrNum × MshrMergeReqs)` candidate comparators → per-(tile,port) priority mux. The change adds, per candidate, a **slot axis (×DrainBeatsPerEntry)** plus a **2nd resp_buf read** and a **2-way pop**.

Risk items and mitigations (all rely on **fixing N=2**, never a runtime barrel shifter):
1. **2nd read port on resp_buf inside the heavy scan** → would put a port-dependent `resp_buf[(rd_ptr+j)%depth]` index in the inner loop. **Mitigation: hoist it.** `resp_beat_offset[mshr_i][0..1]` and the two slot pointers are precomputed once per entry in 2b/2c (outside the tile×port×s loops); the scan/drive only mux a precomputed 2:1 (`sl==0 ? rdp : nxt`). `nxt` for depth-2 is `rd_ptr ^ 1` (a wire), not an adder. This is the single biggest STA saver.
2. **Slot loop doubles the candidate count** (×2). It is statically unrolled (j∈{0,1}); the extra term is one `drain_port_of(.,1)` which for usable=2 is a constant "other port" (1-bit invert) `==` compare — not a modulo.
3. **`subreq_claimed` 1→2 bits, `resp_sel_slot` new 1-bit field** — negligible.
4. **2-way pop** = a 2-input priority encoder (`K∈{0,1,2}`), `cnt-K`/`beats_left-K` (≤4-bit subtractors), `rd_ptr` advance as a 2:1 mux. No shifter.

Do **not** generalize to arbitrary N: `(rd_ptr+j)%depth`, `drain_port_of`'s `%usable`, and a width-N leading-done priority/rotate would each become a barrel shifter stacked on the already-heavy scan → critical-path blow-up. **Keep `DrainBeatsPerEntry=2`, gate all of the above under `if (DrainBeatsPerEntry > 1)` so N=1 reverts to the bit-identical single-beat netlist**, and keep the resp_buf reads hoisted out of the scan.
---

## Appendix B — MSHR beat-spread + selection (detailed)

I have the full picture. Here is the distilled, anchored design.

---

# Beat-spread MSHR drain — exact change

## Mechanism today (why 1 beat/cyc for a lone-requester burst)

`resp_buf` is a per-entry FIFO of depth `RespBufWords = NumRemoteRespPortsPerTile-1` (line 43-44, 179). The drain only ever consults the **single head slot** `resp_buf[resp_buf_rd_ptr]` (reads at 1631/1634, offset at 1537-1539), and `beat_pending` (168) tracks which *sub_reqs* still need **that one head beat**. The per-(tile,port) scan (1588-1622) therefore spreads **one beat across requesters** (multicast). With one requester there is one sub_req, `subreq_claimed` (307,1615) lets only one port win, finalize (1745-1808) pops exactly one beat → **1 beat/cyc regardless of port count**. The fix: for a lone-requester multi-beat entry, spread the *buffered beats themselves* across ports.

Decision gate (honors your point 1 *and* point 3):
```
use_beat_spread = (burst_len > 1) && (sub_reqs_num == 1)
```
`burst_len==1`, scalar/single, cached, AND **mixed (burst_len>1 && sub_reqs_num>1)** all stay on the existing per-requester multicast path → multicast is untouched (point 3).

---

## 1. Beat-aware port map — add after `map_resp_port_id` (after line 440)

```systemverilog
// Beat-spread port map: consecutive beats of ONE requester's burst land on
// consecutive resp ports. Only used when use_beat_spread (burst_len>1 & 1 requester).
function automatic logic [RespPortIdW-1:0] map_beat_resp_port_id(input logic [BurstLenWidth-1:0] beat_offset);
  if (NumRemoteRespPortsPerTile <= 2) begin
    map_beat_resp_port_id = RespPortIdW'(1);                      // 1 spread port -> degenerate, == today
  end else begin
    map_beat_resp_port_id = RespPortIdW'((beat_offset %
                            BurstLenWidth'(NumRemoteRespPortsPerTile - 1)) + 1);
  end
endfunction
```
`map_resp_port_id(req_port_id)` (429-440) is kept verbatim for every non-beat-spread selection.

---

## 2. Scan selects a `(sub_req, beat-slot)` PAIR per port

### New transient state — declare near 288-307
```systemverilog
logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][RespBufPtrW-1:0]  resp_sel_buf_ptr;   // which resp_buf slot the port reads
logic [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1][BurstLenWidth-1:0] resp_sel_beat_off; // that slot's beat offset (for meta_id)
logic [MshrNum-1:0][RespBufWords-1:0]                                          slot_claimed;       // beat-spread: claim per (entry,slot)
logic [MshrNum-1:0][RespBufWords-1:0]                                          slot_done;          // beat-spread: slot handshaked this cycle
logic [MshrNum-1:0]                                                            use_beat_spread;
```
No struct change — `resp_buf_valid[]` (181) and `resp_buf_rd_ptr` (185) already exist.

### Compute the gate — insert between the init block (ends 1557) and the scan (1559)
```systemverilog
for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
  use_beat_spread[mshr_i] = mshr_d_valid[mshr_i] &&
                            (mshr_d[mshr_i].state == MSHR_DRAIN_RESP) &&
                            (mshr_d[mshr_i].burst_len  >  BurstLenWidth'(1)) &&
                            (mshr_d[mshr_i].sub_reqs_num == SubReqCountW'(1));
end
```

### Init the new claims — extend the existing init at 1580-1585
```systemverilog
for (int mshr_i = 0; mshr_i < MshrNum; mshr_i++) begin
  drain_count[mshr_i] = '0;
  for (int s = 0; s < MshrMergeReqs; s++) subreq_claimed[mshr_i][s] = 1'b0;
  for (int r = 0; r < RespBufWords;  r++) begin slot_claimed[mshr_i][r]=1'b0; slot_done[mshr_i][r]=1'b0; end
end
```
Also default `resp_sel_buf_ptr`/`resp_sel_beat_off` to 0 in the per-(tile,port) reset that already clears `resp_sel_*` at 1575-1577.

### (a) NEW beat-spread pre-pass — insert immediately BEFORE the multicast scan (before 1587)

The pre-pass owns the per-entry ordering (single `rd_ptr` FIFO ⇒ pop must stay in-order), so it assigns a **contiguous run of buffered beats from `rd_ptr`** to distinct ports. The existing per-(tile,port) loop cannot do this because it is port-independent.
```systemverilog
for (int tile_i = 0; tile_i < NumTilesPerGroup; tile_i++) begin
  automatic int drain_base = EnableRrFairness ? int'(drain_mshr_rr_q) : 0;
  for (int kk = 0; kk < MshrNum; kk++) begin
    automatic int mshr_i = (drain_base + kk) % MshrNum;
    if (use_beat_spread[mshr_i] &&
        (mshr_d[mshr_i].sub_reqs[0].tile_id == tile_group_id_t'(tile_i))) begin
      // sub_reqs[0] is the reserved anchor; for a 1-requester entry it is the lone valid req.
      for (int k = 0; k < RespBufWords; k++) begin
        automatic logic [RespBufPtrW-1:0] r =
            RespBufPtrW'((int'(mshr_d[mshr_i].resp_buf_rd_ptr) + k) % RespBufWords);
        if (!mshr_d[mshr_i].resp_buf_valid[r]) break;             // no more buffered beats
        automatic logic [BurstLenWidth-1:0] boff =
            mshr_d[mshr_i].resp_buf[r].rdata.meta_id - mshr_d[mshr_i].sub_reqs[0].meta_id_base;
        automatic logic [RespPortIdW-1:0] p = map_beat_resp_port_id(boff);
        // IN-ORDER stop: bypass owns p, or p already taken, or offset collides onto a used port.
        if (port_taken[tile_i][p] || resp_sel_valid[tile_i][p]) break;
        resp_sel_valid[tile_i][p]      = 1'b1;
        resp_sel_mshr_id[tile_i][p]    = mshr_id_t'(mshr_i);
        resp_sel_subreq_idx[tile_i][p] = '0;                      // s0 = sub_reqs[0]
        resp_sel_buf_ptr[tile_i][p]    = r;
        resp_sel_beat_off[tile_i][p]   = boff;
        slot_claimed[mshr_i][r]        = 1'b1;
      end
    end
  end
end
```
For `ports-1==2`, two buffered beats `b,b+1` map to ports `1+b%2` and `1+(b+1)%2` = **distinct** → both fire same cycle. Offset collision (`b,b+2`) or a port stolen by bypass just `break`s the run; the rest waits → bounded, never lost.

### (b) Multicast scan — two one-line edits in 1600-1614
- Add `&& !use_beat_spread[mshr_i]` to the entry eligibility at **1600-1601** so beat-spread entries are not double-served. (It already skips ports the pre-pass took via `!resp_sel_valid` at 1605.)
- After 1614 set the slot/offset so the **drive block reads them uniformly** (no per-path branch downstream):
```systemverilog
resp_sel_buf_ptr[tile_i][port_i]  = mshr_d[mshr_i].resp_buf_rd_ptr;   // multicast = head slot
resp_sel_beat_off[tile_i][port_i] = resp_beat_offset[mshr_i];          // multicast = head offset
```
`subreq_claimed[mshr_i][s]` (1615) is unchanged — multicast still claims per **sub_req**; beat-spread claims per **slot** (`slot_claimed`). Two independent claim axes, no interference.

---

## 3. Drive + handshake — make 1629-1667 slot-driven

### Reads (1629-1644): replace head `resp_buf_rd_ptr` with the selected slot, and the head offset with the per-port offset
```systemverilog
... .resp_buf[resp_sel_buf_ptr[tile_i][port_i]].wen;          // was .resp_buf_rd_ptr  (1631)
... .resp_buf[resp_sel_buf_ptr[tile_i][port_i]].rdata.data;   // was .resp_buf_rd_ptr  (1634)
resp_out[..].rdata.meta_id = mshr_d[sel].sub_reqs[idx].meta_id_base
                           + meta_id_t'(resp_sel_beat_off[tile_i][port_i]);  // was resp_beat_offset[sel] (1641)
```
core_id (1635-1637) and amo (1642-1644) are unchanged (sub_req-sourced; beat-spread idx=0).

### Handshake (1648-1667): branch the bookkeeping
```systemverilog
if (resp_out_ready[tile_i][port_i]) begin
  automatic mshr_id_t sel = resp_sel_mshr_id[tile_i][port_i];
  drain_count[sel] = drain_count[sel] + 1'b1;                  // keep (stats / count)
  if (use_beat_spread[sel]) begin
    slot_done[sel][resp_sel_buf_ptr[tile_i][port_i]] = 1'b1;   // finalize pops the run; do NOT touch beat_pending
  end else begin
    mshr_d[sel].beat_pending[resp_sel_subreq_idx[tile_i][port_i]] = 1'b0;   // existing 1649-1650
    if (mshr_d[sel].burst_len == BurstLenWidth'(1))                          // existing 1661-1664
      mshr_d[sel].sub_reqs[resp_sel_subreq_idx[tile_i][port_i]].valid = 1'b0;
  end
end
```

### Finalize — add a beat-spread branch (front of the per-entry body, 1746-1750)

Pop the **maximal contiguous `slot_done` run from `rd_ptr`** (robust to a port not being ready: stop at the first gap, keeps the single-`rd_ptr` FIFO in-order). The existing 1751-1806 (head_beat_pending / cache-keep / single-pop) runs only in the `else`.
```systemverilog
if (use_beat_spread[mshr_i]) begin
  automatic int popped = 0;
  for (int k = 0; k < RespBufWords; k++) begin
    automatic logic [RespBufPtrW-1:0] r =
        RespBufPtrW'((int'(mshr_d[mshr_i].resp_buf_rd_ptr) + k) % RespBufWords);
    if (!slot_done[mshr_i][r]) break;                          // in-order: stop at first undelivered slot
    mshr_d[mshr_i].beat_done[ mshr_d[mshr_i].resp_buf[r].rdata.meta_id
                            - mshr_d[mshr_i].sub_reqs[0].meta_id_base ] = 1'b1;
    mshr_d[mshr_i].resp_buf_valid[r] = 1'b0;
    popped++;
  end
  if (popped != 0) begin
    mshr_d[mshr_i].resp_buf_rd_ptr =
        RespBufPtrW'((int'(mshr_d[mshr_i].resp_buf_rd_ptr) + popped) % RespBufWords);
    mshr_d[mshr_i].resp_buf_cnt    = mshr_d[mshr_i].resp_buf_cnt - RespBufCountW'(popped);
    mshr_d[mshr_i].beat_pending    = '0;
    if (mshr_d[mshr_i].beats_left <= BurstLenWidth'(popped)) begin
      mshr_d_valid[mshr_i] = 1'b0; mshr_d[mshr_i] = '0;        // whole burst drained -> dealloc
    end else begin
      mshr_d[mshr_i].beats_left = mshr_d[mshr_i].beats_left - BurstLenWidth'(popped);
      mshr_d[mshr_i].resp_valid = (mshr_d[mshr_i].resp_buf_cnt != RespBufCountW'(popped)); // cnt already pre-decrement here -> recompute vs new cnt
      mshr_d[mshr_i].state      = (mshr_d[mshr_i].resp_buf_cnt != '0) ? MSHR_DRAIN_RESP : MSHR_WAIT_RESP;
    end
  end
end else begin
  // ... existing 1751-1806 untouched ...
end
```
(Note for impl: compute `resp_valid`/`state` against the post-decrement `resp_buf_cnt`, mirroring 1797-1803 — write `resp_buf_cnt` first, then test `!=0`.)

---

## 3 (cont). MIXED case correctness — explicit interaction

| Entry kind | `use_beat_spread` | Path | Port axis | Claim |
|---|---|---|---|---|
| single / scalar / cached / `burst_len==1` | 0 | multicast (1588-1622) | `map_resp_port_id(req_port_id)` | `subreq_claimed[s]` |
| **lone-requester burst** (matmul) | 1 | pre-pass (new) | `map_beat_resp_port_id(beat_off)` | `slot_claimed[r]` |
| **mixed: burst>1 AND >1 requester** | **0** | multicast (1588-1622) | `map_resp_port_id(req_port_id)` | `subreq_claimed[s]` |

Why the mixed case must stay on multicast: with only `ports-1` physical ports you cannot simultaneously fan one beat to N requesters **and** spread beats across ports. If beat-spread were applied to the mixed case, all N requesters of head beat `b` map to the single port `map_beat(b)`, serializing the multicast onto one port and idling the rest — a **regression** of exactly the multicast bandwidth point 3 protects. Gating on `sub_reqs_num==1` routes mixed entries to the existing head-beat multicast (per-requester port spread, one beat popped per fully-multicast beat), which is byte-for-byte unchanged. A burst that *starts* lone-requester and later coalesces a second requester (`sub_reqs_num` rises to 2) flips `use_beat_spread` to 0 on the next cycle and seamlessly continues on the multicast path — no in-flight slot is lost because `slot_done`/`slot_claimed` are recomputed every cycle and `beat_pending` re-inits from `sub_reqs[*].valid` (1547-1557).

---

## Supporting edit — assertion (729-744)

`head_beat_must_match_subreq` uses `resp_head_beat_pending` (=`|beat_pending`) as a disable term, but beat-spread entries intentionally leave `beat_pending==0`. Steady-state DRAIN_RESP is already covered by the `mshr_q.state==MSHR_DRAIN_RESP` term (736) and the first cycle by `mshr_resp_inflight` (737); add an explicit guard so the head-beat invariant is not falsely asserted on a beat-spread entry:
```systemverilog
... ||
(mshr_d[mshr_i].burst_len > BurstLenWidth'(1) && mshr_d[mshr_i].sub_reqs_num == SubReqCountW'(1)) ||
(resp_head_beat_pending[mshr_i]))
```

---

## File / anchor summary (all in `hardware/src/mempool_group_mshr.sv`)

- 43-44 `RespBufWords` (already = ports-1; this is what makes ≥2 beats buffer simultaneously — no change, just the enabler).
- after **440**: add `map_beat_resp_port_id`.
- **288-307**: add `resp_sel_buf_ptr`, `resp_sel_beat_off`, `slot_claimed`, `slot_done`, `use_beat_spread`.
- **after 1557 / before 1559**: compute `use_beat_spread`.
- **1564-1578**: also reset `resp_sel_buf_ptr`/`resp_sel_beat_off`.
- **1580-1585**: also clear `slot_claimed`/`slot_done`.
- **before 1587**: new beat-spread pre-pass.
- **1600-1601**: add `&& !use_beat_spread[mshr_i]`; **after 1614**: set `resp_sel_buf_ptr`/`resp_sel_beat_off` for multicast.
- **1631/1634**: read `resp_buf[resp_sel_buf_ptr]`; **1638-1641**: meta_id uses `resp_sel_beat_off`.
- **1648-1667**: branch handshake (beat-spread → `slot_done`; multicast → existing).
- **1746-1750**: add beat-spread finalize branch (contiguous `slot_done` pop); existing 1751-1806 becomes the `else`.
- **729-744**: add `use_beat_spread` disable term.

No change to `mempool_group_mshr_t` struct, request/alloc/merge logic, or the `DrainMultiPort==0` path.
---

## Appendix C — VLSU multi-lane receive (detailed)

I have the full picture. Here is the distilled, line-anchored change set.

---

## Confirmed facts (current `working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv`)

- `N_FU=4`, `ELEN=32`, `ELENB=4` ⇒ `vrf_data_t = N_FU*ELEN = 128 b`, 4 lanes (`spatz_pkg.sv:52,90`). `NrMemPorts=N_FU=4`, `NrOutstandingLoads=16`, `MaxBurstWords=16`.
- One ROB per port (`reorder_buffer`, `gen_rob` 228‑269). **Critical reorder_buffer semantic**: read side returns `mem_q[read_pointer_q]` and walks `read_pointer` on pop (lines 61,76‑77,108‑118). A port's ROB only returns beats if ids are **allocated on that port** (`id_req_i`→`id_o`/`burst_base_id`). Today only port0 pre‑allocates (`proc_burst_alloc`), so ports ≥1 cannot act as a receive ROB without added per‑port id pre‑allocation.
- Single‑port burst today: request port0 only; `mem_pending_d[0] += burst_len` (1026‑1028); 1 word/cyc commit (1180‑1191): `vrf_req_valid_d = rob_rvalid[0] && mem_pending[0]`, `wdata[ELEN*burst_lane_idx +: ELEN]=rob_rdata[0]`, `rob_pop[0]`.
- `burst_word_idx = (commit_counter_q[0]>>clog2(ELENB))>>clog2(N_FU)` (767‑769) feeds `vd_vreg_addr` (547) = VRF row. `burst_lane_idx = burst_elem_idx[clog2(N_FU)-1:0]`.
- Receive drop‑gate for ports ≥1 is **not** `mem_port_active`; it is line **1315** `else if (!mem_pending[port]) rob_pop[port]=rob_rvalid[port]` (1319) — stale‑drains any beat that lands on a port with `mem_pending==0`. `mem_port_active` (142‑166) is request/finish‑side only.
- Issue assertion (1464‑1469) keys on `spatz_mem_req_valid[port]` (request) — already issue‑only; **leave unchanged**.

**128 b absorbs N lanes/cyc — confirmed:** with `N=BurstRecvPorts=2`, each cycle writes 2 ELEN lanes (64 b) into the 128 b `vrf_data_t` row via `wbe`; `burst_word_idx` advances once per `N_FU/N=2` cycles, so two cycles complete a 128 b row (lanes {0,1} then {2,3}). No widening of `vrf_data_t`, `vrf_wdata_o`, or the VRF write port.

---

## Edits

### Site 1 — new localparam (after line 70, `FullBurstBytes`)
```systemverilog
// Receive a single-port burst response at N words/cyc across N ROBs.
// N = min(NrMemPorts, usable resp ports). Must divide N_FU.
localparam int unsigned BurstRecvPorts = (NrMemPorts < 2) ? NrMemPorts : 2;
```

### Site 2 — N words/cyc commit-counter step (lines 831‑836, `gen_vreg_counter_proc`)
Burst commits `BurstRecvPorts` words per VRF write, so `commit_counter_q[0]` (which carries the whole `vl` for fu0) must step by `BurstRecvPorts*ELENB`:
```systemverilog
automatic int unsigned grp_bytes =
    (commit_use_port0_burst && !commit_is_single_element_operation)
      ? (BurstRecvPorts*ELENB) : ELENB;
commit_operation_last[fu] = commit_operation_valid[fu] &&
    ((max_elements - commit_counter_q[fu]) <=
     (commit_is_single_element_operation ? commit_single_element_size : grp_bytes));
commit_counter_delta[fu]  = !commit_operation_valid[fu] ? vlen_t'('d0) :
    commit_is_single_element_operation ? vlen_t'(commit_single_element_size) :
    commit_operation_last[fu] ? (max_elements - commit_counter_q[fu]) : vlen_t'(grp_bytes);
```
This makes `burst_elem_idx` (=`commit_counter_q[0]>>clog2(ELENB)`) advance by `BurstRecvPorts` per cycle = first beat index of the group; `burst_word_idx`/`vd_vreg_addr` (767‑769, 547) need **no change**.

### Site 3 — N-lane burst commit (replace the `commit_use_port0_burst` block, lines 1180‑1191)
```systemverilog
if (commit_use_port0_burst) begin
  // Burst RECEIVE: BurstRecvPorts ROBs each present one beat of the group.
  // group base beat = burst_elem_idx (advances by BurstRecvPorts via Site 2);
  // beat (group*N+p) lands on ROB p (MSHR beat-spread) -> VRF lane (burst_elem_idx+p) mod N_FU,
  // all sharing VRF row burst_word_idx because N | N_FU.
  vrf_req_d.waddr = vd_vreg_addr;
  vrf_req_d.wdata = '0;
  vrf_req_d.wbe   = '0;

  // Fire only when every still-pending receive port has its head beat
  // (ports already drained at an odd burst tail are masked out).
  vrf_req_valid_d = 1'b0;
  for (int unsigned p = 0; p < BurstRecvPorts; p++)
    if (mem_pending[p]) vrf_req_valid_d = 1'b1;          // |pending
  for (int unsigned p = 0; p < BurstRecvPorts; p++)
    if (mem_pending[p] && !rob_rvalid[p]) vrf_req_valid_d = 1'b0; // all pending heads valid

  for (int unsigned p = 0; p < BurstRecvPorts; p++) begin
    automatic logic [LaneIdxWidth-1:0] lane = (burst_elem_idx + p);  // mod N_FU by width
    rob_pop[p] = rob_rvalid[p] &&
                 ((!mem_pending[p]) ||
                  (vrf_req_valid_d && vrf_req_ready_d && commit_counter_en[0]));
    if (mem_pending[p]) begin
      vrf_req_d.wdata[ELEN*lane  +: ELEN ] = rob_rdata[p];
      vrf_req_d.wbe  [ELENB*lane +: ELENB] = burst_lane_wbe;
    end
  end
end else begin
  // ... existing multi-lane non-burst path (1192-1262) unchanged ...
```
(`burst_lane_idx`, 768, becomes dead for this path; keep or delete.) Note `LaneIdxWidth = $clog2(N_FU)` so the add wraps mod `N_FU` naturally only when `LaneIdxWidth` exactly covers `N_FU`; if `N_FU` is a power of two (it is, =4) the truncation to `[LaneIdxWidth-1:0]` gives the mod.

### Site 4 — per-logical-burst `mem_pending` spread (lines 1020‑1029)
The single port0 burst request must charge pending to `BurstRecvPorts` ROBs (matching the MSHR spread). Keep decrement loop as‑is (it now drains ports 0..N‑1 via Site 3's `rob_pop`):
```systemverilog
if (spatz_mem_req_valid[port] && spatz_mem_req_ready[port] && mem_req_lvalid[port]) begin
  if (mem_use_port0_burst && port == 0) begin
    // Request is single-port; responses beat-spread round-robin across BurstRecvPorts ROBs.
    for (int unsigned rp = 0; rp < BurstRecvPorts; rp++)
      mem_pending_d[rp] = mem_pending_d[rp] +
        (spatz_mem_req[0].burst_len / BurstRecvPorts) +
        ((spatz_mem_req[0].burst_len % BurstRecvPorts) > rp);
  end else
    mem_pending_d[port] = mem_pending_d[port] + spatz_mem_req[port].burst_len;
end
```
Making `mem_pending[p]!=0` for `p<BurstRecvPorts` is exactly what **relaxes the receive gate**: the stale‑drain at line 1315‑1319 (`else if (!mem_pending[port])`) is now skipped for receive ports, so beats that land there are kept (pushed by the already‑general `rob_push[port]` at 1267‑1274), not dropped. `mem_port_active` is untouched.

### Site 5 — pre-allocate ROB ids on receive ports 1..N‑1 (the load-bearing addition; `proc_burst_alloc` 1079‑1138 + `rob_req_id` wiring 1283/1311)
Ports ≥1 must `id_req` their share so each ROB's `read_pointer`/`burst_base_id` track (else the ROB never reads — `read_pointer` stuck at 0). Mirror the port0 allocation FSM onto `p∈[1,BurstRecvPorts)` while `mem_use_port0_burst`, with per‑port target `beats_per_port[p] = burst_len/N + (burst_len%N > p)`, **but never assert `mem_req_lvalid[p]`/`burst_send[p]`** (no request issued ⇒ issue assertion stays satisfied). Capture `burst_base_id_d[p]=rob_id[p]` on the first fire. Concretely, drive the existing reorder‑buffer id request for these ports:
```systemverilog
// inside proc_burst_alloc, for p in 1..BurstRecvPorts-1 when mem_use_port0_burst & is_load:
if (recv_alloc_q[p] && (recv_alloc_cnt_q[p] < beats_per_port[p]) &&
    !rob_full[p] && !offset_queue_full[p]) begin
  burst_alloc_fire[p] = 1'b1;                  // -> rob_req_id[p] (Site: relax 1283/1311 gate)
  if (recv_alloc_cnt_q[p] == '0) burst_base_id_d[p] = rob_id[p];
  recv_alloc_cnt_d[p] = recv_alloc_cnt_q[p] + 1'b1;
end
```
and at line 1283 allow `rob_req_id[p] = burst_alloc_fire[p]` for receive ports even though `mem_operation_valid[p]==0` (today gated false at 857/1280). **MSHR contract this implies:** for the port0 burst of `burst_len` beats, the MSHR returns beat `b` on resp port `b mod BurstRecvPorts` tagged `id = burst_base_id[b mod N] + (b div N)` — i.e. the "beat index carried in meta_id" decoded to (port, ROB‑id). The VLSU then pushes `rob_wid[p]=rsp.id` (already at 1269) and reads each ROB head in id order.

### Site 6 — issue assertion (1464‑1469): unchanged
It already constrains only `spatz_mem_req_valid[port]` (the request). Receive needs no relaxation here. Confirm the request still goes out on port0 only (it does: `mem_req_lvalid[p]`/`burst_send[p]` stay 0 for p≥1 per Site 5).

---

## Summary of behavior
- **Request:** unchanged — one burst on port0, `burst_len=16`, `mem_req_valid[≥1]=0` (assertion holds).
- **Receive:** MSHR spreads the 16 beats across `BurstRecvPorts=2` ROBs (8+8); `mem_pending` spread (Site 4) keeps them (kills the 1315 drain); per‑port id pre‑allocation (Site 5) makes ROB1 a valid reorder buffer.
- **Commit:** `BurstRecvPorts` ROB heads → lanes `(burst_elem_idx+p) mod N_FU`, one 128 b `vrf_data_t` row across `N_FU/N` cycles, `BurstRecvPorts` ROBs popped per cycle ⇒ **2 words/cyc** (4 for `N=4`), no datapath widening.

File: `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv` (all anchors above). Reorder‑buffer constraint reference: `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz/src/reorder_buffer.sv:61,76,108`.

**Biggest risk / must‑verify:** Site 5 (per‑port id pre‑allocation) + the MSHR's beat→(port,id) tagging are the load‑bearing parts; Sites 2‑4 are mechanical. A naive "just push to ROB[p]" without Site 5 silently never reads (read_pointer stuck at 0). Requires the matching `mempool_group_mshr.sv` change to actually beat‑spread + tag responses.
---

## Appendix D — Parameterization (detailed)

Confirmed all wiring facts. Here is the distilled parameterization spec.

---

## 0. Ground truth (verified)

- `mempool_pkg.sv:370`: `NumRemoteRespPortsPerTile = 1 + (NOC_RESP_CHANNEL_NUM | 2)`. Port 0 is the shared/scalar port; usable remote resp ports = `NumRemoteRespPortsPerTile-1` (arrays are `[...-1:1]`). terapool baseline `noc_resp_channel_num=2` → `NumRemoteRespPortsPerTile=3` → **usable = 2**.
- MSHR `mempool_group_mshr.sv:43-44` already has `RespBufWords = (N>1)?(N-1):1` as a **module parameter**, plus a `DrainMultiPort` bit (line 47) that already lets one drain cycle touch multiple resp ports.
- VLSU port count: `spatz_vlsu.NrMemPorts` ← `spatz.NrMemPorts` ← `spatz_mempool_cc.NumMemPortsPerSpatz` ← `mempool_tile` passes `mempool_pkg::NumMemPortsPerSpatz (= NumFUsPerCore = 4 for spatz4)`. So `NrMemPorts=4`, and today the burst path commits **1 beat/cyc** (`commit_use_port0_burst` → `rob_rvalid[0]` only, vlsu:1180-1191).
- **Repo/build separation (part 4) confirmed**: MSHR is in the TeraNoC top repo (`hardware/src/`, imports `mempool_pkg`). VLSU/spatz/cc are a **separate IP** mounted by `Bender.local: spatz → working_dir/spatz`. `grep -rln mempool_pkg working_dir/spatz/hw/ip/` returns **nothing** — `mempool_pkg` is not, and must not be, visible inside the spatz IP. `mempool_tile.sv` is the lowest module that sees both `mempool_pkg` and the cc instance.

---

## 1. MSHR `DrainBeatsPerEntry` — declare as MSHR **localparam** (not in mempool_pkg)

It is a pure function of `NumRemoteRespPortsPerTile`, which is already an MSHR parameter — derive it locally, mirroring the existing `RespBufWords`. Do **not** add a second derived name to `mempool_pkg` (redundant export; the tile/MSHR each derive what they need). It is semantically distinct from `RespBufWords` (buffer depth) even though the expression is identical: `DrainBeatsPerEntry` = how many buffered beats of one entry may pop to sub-requesters per cycle = number of usable resp ports.

Add right after the localparam block (~line 104), inside `mempool_group_mshr`:

```systemverilog
// Beats of a single MSHR entry that may drain per cycle (= usable remote resp ports).
// Default tracks resp bandwidth; overridable for A/B (see §3).
localparam int unsigned DrainBeatsPerEntry =
  `ifdef GROUP_MSHR_DRAIN_BEATS `GROUP_MSHR_DRAIN_BEATS
  `else ((NumRemoteRespPortsPerTile > 1) ? (NumRemoteRespPortsPerTile - 1) : 1) `endif;
```

Then clamp the existing `DrainMultiPort` beat-advance to this in the drain loop (the `if (DrainMultiPort)` block at line 1562): cap the per-entry beats emitted per cycle at `DrainBeatsPerEntry` instead of unbounded/port-count. `DrainMultiPort` stays as the on/off master; `DrainBeatsPerEntry` is the width.

---

## 2. VLSU `BurstRecvPorts` + the threaded param (exact decls)

New parameter name: **`NumRespPorts`** (= usable remote resp ports). Threaded tile → cc → spatz → vlsu.

**`spatz_vlsu.sv` (param block ~line 14-18):**
```systemverilog
parameter int unsigned   NrMemPorts         = 1,
parameter int unsigned   NumRespPorts       = 1,   // usable remote resp ports (NumRemoteRespPortsPerTile-1)
parameter int unsigned   NrOutstandingLoads = 16,
```
local cap (next to the other localparams ~line 65):
```systemverilog
localparam int unsigned BurstRecvPorts = (NrMemPorts < NumRespPorts) ? NrMemPorts : NumRespPorts;
```
Use `BurstRecvPorts` in the burst commit path (vlsu:1180-1191): instead of committing only `rob_rvalid[0]`, accept beats from ports `0 .. BurstRecvPorts-1` and write `BurstRecvPorts` lanes/cyc.

**`spatz.sv`** — add param (after `NrMemPorts`, ~line 17) and forward to the vlsu instance (line 324):
```systemverilog
parameter int unsigned NumRespPorts = 1,
...
spatz_vlsu #(
  .NrMemPorts        (NrMemPorts  ),
  .NumRespPorts      (NumRespPorts),
  .NrOutstandingLoads(32          ),
  .spatz_mem_req_t   (spatz_mem_req_t),
  .spatz_mem_rsp_t   (spatz_mem_rsp_t)
) i_vlsu ( ... );
```

**`spatz_mempool_cc.sv`** — add param (after `NumMemPortsPerSpatz`, line 32) and forward to spatz (line 230):
```systemverilog
parameter int unsigned NumMemPortsPerSpatz = 1,
parameter int unsigned NumRespPorts        = 1   // = NumRemoteRespPortsPerTile-1, supplied by tile
...
spatz #(
  .NrMemPorts ( NumMemPortsPerSpatz ),
  .NumRespPorts ( NumRespPorts       ),
  ...
) i_spatz ( ... );
```

**`mempool_tile.sv`** (the boundary that sees `mempool_pkg`) — supply the value at the cc instance (line 239):
```systemverilog
spatz_mempool_cc #(
  ...
  .NumMemPortsPerSpatz ( NumMemPortsPerSpatz                    ),
  .NumRespPorts        ( mempool_pkg::NumRemoteRespPortsPerTile - 1 ),
  ...
) riscv_core ( ... );
```

Net for terapool baseline: `NumRespPorts=2`, `NrMemPorts=4` → `BurstRecvPorts = min(4,2) = 2` (2 beats/cyc, matching the 2-usable-port ceiling); enhanced mode (`noc_resp_channel_num=3`) → `NumRespPorts=3` → `BurstRecvPorts=3`.

> Correction to the prompt's premise: the cc does **not** "know `NumRemoteRespPortsPerTile` from mempool_pkg" — it can't import it (see §4). The tile passes `NumRemoteRespPortsPerTile-1`; cc/spatz are pure pass-throughs; vlsu does the `min`.

---

## 3. A/B knob — recommend: structure derived (no knob) + one behavioral guard

- **Structural width** (port arrays, `RespBufWords`, the `[...-1:1]` buffers, `NumRespPorts`) stays **derived, default-on, no knob** — it must track `noc_resp_channel_num`; you cannot shrink physical ports with a flag.
- **For A vs B benchmarking**, do **not** toggle via `noc_resp_channel_num` (that also changes NoC bandwidth and confounds the comparison). Add **one** behavioral clamp that holds the hardware fixed and only caps beats/cycle:

`hardware/Makefile` (next to the other `group_mshr_*`, ~line 168-178):
```makefile
group_mshr_drain_beats   ?=          # empty = derived (wide). Set =1 for legacy single-beat A/B.
ifneq ($(strip $(group_mshr_drain_beats)),)
  vlog_defs += -DGROUP_MSHR_DRAIN_BEATS=$(group_mshr_drain_beats)
endif
```
- MSHR consumes it directly in the `DrainBeatsPerEntry` localparam above (default = derived width).
- VLSU consumes the **same** clamp at the tile, so both sides move together:
```systemverilog
// mempool_tile.sv
localparam int unsigned MshrDrainBeats =
  `ifdef GROUP_MSHR_DRAIN_BEATS `GROUP_MSHR_DRAIN_BEATS
  `else (mempool_pkg::NumRemoteRespPortsPerTile - 1) `endif;
...
.NumRespPorts ( MshrDrainBeats ),
```

**Recommendation:** ship the derived, default-on width (no permanent knob in the config `.mk`), and use `group_mshr_drain_beats=1` purely as a transient A/B override on identical RTL/NoC. `B = wide` is the default; `A = group_mshr_drain_beats=1` reproduces today's 1-beat/cyc behavior for a clean speedup measurement. Avoid a `bit DrainWide` parameter — the single integer cap subsumes on/off and is the one source of truth feeding both repos.

---

## 4. Repo separation — resolution

- **Different build paths, yes.** MSHR: `hardware/src/mempool_group_mshr.sv` (top repo, imports `mempool_pkg`). VLSU: `working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv` (separate `spatz` IP via `Bender.local` path override).
- **`mempool_pkg::NumRemoteRespPortsPerTile` does NOT reach the VLSU and must not.** Importing `mempool_pkg` into the spatz IP would invert the dependency (IP → top package) and break standalone spatz builds/CI. (Global `+define+NOC_RESP_CHANNEL_NUM` technically *is* visible to the spatz IP at vlog time, but using it there duplicates the derivation across two repos and silently couples them — reject.)
- **Clean fix = parameter threading** from the only module that legitimately sees both worlds (`mempool_tile.sv`): `NumRemoteRespPortsPerTile-1` → `cc.NumRespPorts` → `spatz.NumRespPorts` → `vlsu.NumRespPorts` → `BurstRecvPorts = min(NrMemPorts, NumRespPorts)`. The spatz IP stays self-describing (typed params, no top-package leak); the MSHR derives `DrainBeatsPerEntry` from its own `NumRemoteRespPortsPerTile` param. Both ends are clamped by the single `GROUP_MSHR_DRAIN_BEATS` define for A/B.

---

### Files to touch (absolute)
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/src/mempool_group_mshr.sv` — add `DrainBeatsPerEntry` localparam (~after :104); clamp `DrainMultiPort` loop (:1562).
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/src/mempool_tile.sv` — `MshrDrainBeats` localparam + `.NumRespPorts` on cc instance (:225-241).
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz_cc/src/spatz_mempool_cc.sv` — add `NumRespPorts` param (:32) + forward to spatz (:230).
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz/src/spatz.sv` — add `NumRespPorts` param (:17) + forward to vlsu (:324).
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv` — add `NumRespPorts` param (:14) + `BurstRecvPorts` localparam (:65) + widen burst commit (:1180-1191).
- `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/Makefile` — `group_mshr_drain_beats` → `-DGROUP_MSHR_DRAIN_BEATS` (~:168-178).

No `mempool_pkg.sv` change required; no new config `.mk` knob required (A/B is a transient make-var override).