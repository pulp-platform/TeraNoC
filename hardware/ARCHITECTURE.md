# TeraNoC + Spatz — Architecture & Microarchitecture Reference

Terse, `file:line`-anchored map of the hardware datapath, contracts, and gotchas.
Built to accelerate debugging and onboarding. For the narrative/diagram version
(design goals, rationale, version history) see [`../docs/teranoc_architecture.md`](../docs/teranoc_architecture.md).

> **How to use this doc.** Every claim carries a `file:line` anchor — *verify it before
> trusting it*; line numbers drift as RTL changes. Before basing a conclusion on any
> file under `working_dir/spatz/` or `hardware/deps/`, **confirm it is actually compiled**
> via the relevant `Bender.yml` (a plausible-looking file can be commented out and
> superseded — see [Compiled-vs-not](#0-compiled-vs-not-read-this-first)). Sections marked
> 🔧 are under active development; treat their internals as a moving target and rely on the
> *contract*, not the implementation detail.

---

## 0. Compiled-vs-not (read this first)

The single highest-cost trap in this repo. The "obvious" file is often not the one in the design.

| You might edit… | …but the **compiled** file is | Proof |
|---|---|---|
| `working_dir/spatz/hw/ip/snitch/src/snitch.sv` / `snitch_lsu.sv` | `hardware/deps/snitch/src/snitch.sv` / `snitch_lsu.sv` | root `Bender.yml:15` `snitch: {path: hardware/deps/snitch}`; the Snitch block in `working_dir/spatz/Bender.yml:76–99` is **commented out** |
| `hardware/deps/spatz/...` | `working_dir/spatz/...` | `Bender.local:2` `spatz: {path: working_dir/spatz}` path override |
| `hardware/deps/spatz/.../spatz_mempool_cc.sv` | `working_dir/spatz/hw/ip/spatz_cc/src/spatz_mempool_cc.sv` | `working_dir/spatz/Bender.yml:162` (under `target: mempool`) |

- Spatz **IP** (`spatz_vlsu`, `spatz_fpu_sequencer`, `spatz`, `spatz_mempool_cc`) is compiled from `working_dir/spatz`.
- The **Snitch core** inside that complex is compiled from `hardware/deps/snitch` (not Spatz's vendored copy).
- All `hardware/src/*.sv` are compiled unconditionally (root `Bender.yml:26–75`).
- When in doubt, grep the live `hardware/build*/compile.tcl` for the absolute path.

---

## 1. System hierarchy

Instantiation chain (each arrow = a real instantiation site, not just a module def):

```
mempool_system                                   src/mempool_system.sv:10
└─ `CLUSTER_WRAPPER  i_mempool_cluster           mempool_system.sv:553   (macro @ :101/:351)
   │   = terapool_cluster_floonoc_wrapper  if `ifdef TERAPOOL  (:102)
   │   = mempool_cluster_floonoc_wrapper   else               (:352)
   └─ mempool_group_floonoc_wrapper  i_group     {mempool,terapool}_cluster_floonoc_wrapper.sv
      │     in genvar grid  for x in[0,NumX) × y in[0,NumY)   (mempool:113/275, terapool:113/322)
      └─ mempool_group  i_mempool_group           mempool_group_floonoc_wrapper.sv:161
         ├─ mempool_tile  i_tile  ×NumTilesPerGroup           mempool_group.sv:108 (gen_tiles), :125
         │  └─ {spatz_mempool_cc | mempool_cc}  riscv_core     mempool_tile.sv:212 (gen_cores), :221/:242
         │        spatz_mempool_cc iff `ifdef TARGET_SPATZ
         └─ mempool_group_mshr  i_group_mshr 🔧                mempool_group.sv:627 (if EnableGroupMshr), :628
              gate: parameter EnableGroupMshr=1'b1             mempool_group.sv:20
              bypass (wires through) when disabled             mempool_group.sv:654
```

- **`mempool_group_floonoc_wrapper.sv`** is the remote-traffic hub. It holds: MemPool→FlooNoC request
  remapping (`:264 gen_req_remapping`), the per-tile **crossbar** that steers arriving floo requests to
  tiles (`stream_xbar i_local_req_interco` `:519`, resp twin `:697`), FlooNoC→MemPool response remapping
  (`:577 gen_resp_remapping`), and the per-tile `floo_router` instances (below).
- **Intra-group interconnect** = a combinational logarithmic crossbar (`variable_latency_interconnect`,
  topology `LIC`, no spill regs) — `mempool_group.sv:245` (`i_local_interco`).
- **Inter-group interconnect** = FlooNoC 32-bit routers, one set per tile per channel:
  - wide-req `i_floo_tcdm_wide_req_router` `:873`(torus)/`:899`(mesh) — always present
  - resp `i_floo_tcdm_wide_resp_router` `:930`/`:956` — always present
  - narrow-req `i_floo_tcdm_narrow_req_router` `:815`/`:841` — only iff `USE_NARROW_REQ_CHANNEL`
  - AXI (L2/DMA): `floo_nw_chimney` `:994` + `floo_nw_router` `:1046`, one per group
- **2×2 group grid is hard-asserted** in the mempool wrapper (`mempool_cluster_floonoc_wrapper.sv:175 $fatal`);
  terapool supports NumX>2.

Structural counts all derive from macros in `mempool_pkg.sv` (the type/sizing source-of-truth):
`NumCores:17`, `NumCoresPerTile:18`, `NumGroups:20`, `NumTiles:23`, `NumTilesPerGroup:24`,
`NumX:372`, `NumY=NumGroups/NumX:373`.

---

## 2. Config flavors

`config/config.mk` is the master (default `mempool`); it includes `config/<flavor>.mk`. Set `config=<flavor>`.

| Flavor | cores | groups | c/tile | num_x | Spatz | NoC remap / hash | group_mshr_num | notes |
|---|---|---|---|---|---|---|---|---|
| `minpool` | 16 | 4 | 4 | 2 | – | 0 / – | (dflt) | `channel_config_mode=narrow` |
| `mempool` | 256 | 4 | 4 | 2 | – | 0 / – | (dflt) | default master flavor |
| `mempool_spatz4_fpu` | 64 | 4 | 1 | 2 | ✓ | 3 / 0 | 16 | |
| `terapool_spatz4_fpu` | 256 | 16 | 1 | 4 | ✓ | 3 / 7 | 64 | **only flavor known to boot+run on the MSHR branch** |
| `minpool_spatz4_fpu` | 4 | 4 | 1 | 2 | ✓ | 3 / – | (dflt) | smallest Spatz target (boot-broken on this branch) |
| `systolic` | 256 | 4 | 4 | – | – | (dflt) | (dflt) | XQueue ext; sets no `noc_*` |

Anchors: `config/terapool_spatz4_fpu.mk` (num_cores:16, num_groups:19, num_x:44, remapping:56, port_hash:65,
group_mshr_num:122). `channel_config_mode` (baseline/narrow/enhanced) lives in every flavor and picks the
`noc_req_*_channel_num`/`noc_resp_channel_num` split.

**Active-dev knobs** (Spatz flavors): `noc_router_remapping` 0/1/2/3 (off/req/resp/both, consumed
`mempool_group_floonoc_wrapper.sv:264,577`); `noc_port_hash` bitmask bit0=req-RR, bit1=resp temporal RR,
bit2=resp spatial RR (consumed `mempool_tile_rw_demux.sv:83`, `mempool_tile.sv:537`); `group_mshr_*`
(see §4.4). Raise `noc_router_{input,output}_fifo_dep` first when router backpressure stalls appear.

---

## 3. Datapaths

### 3.1 Remote load lifecycle (the central path)

A load whose address targets another group:

```
core ──req──▶ tile rw-demux ──▶ [req remap] ──▶ group MSHR (coalesce) 🔧 ──▶ wide-req floo_router
   ▲                                                                              │ FlooNoC mesh
   │                                                                              ▼
core ◀─resp── tile (resp-port RR) ◀── resp crossbar ◀── [resp remap] ◀── group MSHR (multicast) ◀── resp floo_router ◀── remote slave
```

1. **Tile egress.** Local vs remote split + req-port spreading in `mempool_tile_rw_demux.sv` (port-hash RR `:83`).
   Port 0 = local; ports 1..N = remote req channels.
2. **Req remapping** (if `NocRouterRemapping∈{1,3}`): build the `floo_tcdm_req_meta_t` header
   (`src_id={group,0}`, `dst_id={tgt_group,0}`, `tgt_addr`, `meta_id`, `core_id`, `mshr_tag`),
   then spread across channels via `floo_remapper` (`mempool_group_floonoc_wrapper.sv:341`).
3. **Group MSHR** 🔧 coalesces outstanding loads (§4). Egress stamps `mshr_tag=entry_id+1` (tag 0 = bypass).
4. **FlooNoC mesh** (32-bit, XY by default): `floo_router` per tile/channel. Header `dst_id` selects route
   (XY `floo_route_select.sv:120`; torus uses `routing_table_pkg::RoutingTables`).
5. **Remote slave** services the read; response carries `mshr_tag` back.
6. **Response ingress at requester group**: `mshr_tag` directly indexes the MSHR table (O(1) route,
   tag→`entry_id` at `mempool_group_mshr.sv:1444–1457`); matched → buffered+multicast to all coalesced
   followers; unmatched (tag 0) → **non-backpressurable bypass** (`resp_from_bypass:226`, staged through
   `i_spill_resp_out:518` — the HoL-deadlock surface, §4.5).
7. **Resp crossbar → tile**: `resp_tile_sel = hdr.tile_id` (`:670`), resp-port RR at tile (`mempool_tile.sv:537`).

### 3.2 Scalar FP load path (`flw`/`fsw`) — NOT the integer LSU, NOT the VLSU

- Snitch decodes `FLW`/`FSW` as **accelerator** ops: `is_acc=1`, `is_acc_mem=1`, offloaded on `acc_q*`,
  *not* `lsu_qvalid` (`deps/snitch/src/snitch.sv:2320–2348`).
- The **FPU sequencer** intercepts them (`is_local`, not forwarded to Spatz): `spatz_fpu_sequencer.sv:385–415,472`.
- Handled by the FPU sequencer's **FP-LSU = `snitch_lsu.sv`** (compiled deps copy), which is **id-based,
  out-of-order**: req `data_qid_o`, resp `data_pid_i`, metadata table `metadata_q[req_id]`
  (`deps/snitch/src/snitch_lsu.sv:99–121,203–206`). `NumOutstandingLoads=16` here
  (chain: `spatz_mempool_cc.sv:228` → `spatz.sv:146` → `spatz_fpu_sequencer.sv`).
  ⇒ **`flw` already pipeline (≤16 outstanding, OOO).** There is no 1-outstanding `flw` serialization.
- Exits the complex on **shared port 0** via `tcdm_id_remapper` (merges `{fp_lsu_req, snitch_req}`,
  `spatz_mempool_cc.sv:308–325`); `burst_len` hardwired to 1 (`:379`). VLSU uses ports 1..N.
- Result writes the **FP** regfile (`spatz_fpu_sequencer.sv:751–767`); it does **not** produce an `acc_pwrite` GPR writeback.

### 3.3 VLSU vector load/store + burst splitting 🔧

- VLSU = `working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv`. Op queue is a depth-2 `spill_register`
  (`:86`); per-ID scoreboard `NrParallelInstructions=4` (`:327`); `NrOutstandingLoads=32` (hardcoded `spatz.sv:311`).
- **Burst auto-split**: a unit-stride `EW_32` load with 64-byte-aligned base and `vl≥16 words` issues
  **16-word bursts** on the VLSU ports (`:141–151,857–860`); the misaligned/remainder tail falls back to
  single-word (`burst_tail_phase`). `MaxBurstWords=16`, `BurstLenWidth=5` (`mempool_pkg.sv:281–282`).
- **Two-state FSM** `{VLSU_RunningLoad, VLSU_RunningStore}` (`:169–173`). Loads only accepted in
  RunningLoad, stores only in RunningStore. The RunningStore→RunningLoad transition needs the ROB drained
  **and** `store_count_q==0` (`:600,943–958`) — see the `vle`-after-`vse` contract in §4.

### 3.4 Group sync barrier (held-response rendezvous) 🔧 — EXPERIMENTAL, default-on

- **What**: per-group fine-grained barrier. `arrive` = integer `lw` to a reserved L1 word (accepted
  immediately, response WITHHELD); `wait` = `fence` (stalls on `!lsu_empty`); `release` = the withheld `lw`
  response, driven back when the core's slot is complete. Reuses the TCDM datapath — no WFI/wake path.
- **Files**: slave `src/mempool_group_barrier.sv`; shim `gen_group_barrier` in `mempool_group.sv` (Option B4,
  master-side: masks barrier loads out of the local interco, `rr_arb_tree` 1/cyc into the slave, injects the
  held resp into the requester's `master_local_resp[t]` echoing `meta_id`). SW: `gbar_arrive/gbar_wait` in
  `sp-fmatmul-opt-burst-merge/kernel/sp-fmatmul.c`.
- **Address map**: SW byte addr `0x320000 | (core_id<<6)` → packed `master_local_req_tgt_addr == 0x0C80`
  = `(bank 0, word 200)` (tile-id + seq/interleaved view are stripped at `mempool_tile.sv:1143–1145`).
  Slots: core `c` → slot `c%8`, members `{c, c+8}` (8 slots/group = sp-fmatmul B-pairs).
- **⚠ default-on aliasing**: `EnableGroupBarrier` defaults ON (`-DGROUP_BARRIER_OFF` / `group_barrier=0` to
  disable). `0x0C80` aliases *any* local `(bank0,word200)` access; only `sp-fmatmul` is known clear. Reserve
  the word in the linker before running other apps default-on.
- **Status**: validated correct (no `wd_fire`/stuck, review found no deadlock/corruption) but a **no-op for
  `sp-fmatmul`** (compute-bound; cycles/coalescing unchanged). Full design + rationale: formal spec §9.

---

## 4. Contracts & invariants (the things that bite)

### 4.1 `acc` writeback: only `acc_pwrite=1` is ever acknowledged
The compiled Snitch writeback arbiter consumes an accelerator response **only** via
`(acc_pvalid_i & acc_pwrite_i)` (`deps/snitch/src/snitch.sv:2900`, also `:2937/:2946`). There is **no path**
to ack `acc_pvalid & ~acc_pwrite`. By design Spatz only raises `acc_pvalid` for ops with a scalar GPR
writeback; pure vector ops never assert it. **Footgun:** any path that produces an `acc` response with
`pwrite=0` (observed with an `fmv.x.w`-style float→int move) wedges the destination GPR's scoreboard bit
→ the next instruction reading that reg stalls forever. (This is the build_1 epilogue hang; SW workaround:
route float→int through memory `fsw`+`lw`, never `fmv.x.w`. See `project_matmul_build1_epilogue_hang`.)

### 4.2 `acc_mem_cnt` saturates at 7
3-bit counter of in-flight accelerator mem ops (vle+vse+flw+fsw); `acc_mem_stall` fires at max
(`deps/snitch/src/snitch.sv:2781–2819`). So 8 `flw` + 1 `vle` throttles to 7 combined in flight. Also: an
integer store stalls while *any* acc mem op is in flight; an integer load stalls while any acc *store* is.

### 4.3 `vle`-after-`vse` stalls until stores fully drain
VLSU can't accept a load while in `RunningStore`; the transition requires `&rob_empty && store_count_q==0`
(`spatz_vlsu.sv:600,951–954`). A `vle` immediately after a `vse` blocks until every store response is
acked. **Do not** use a `vle` as a store-drain in software — it can stall the VLSU transition.

### 4.4 A barrier does NOT fence VLSU stores
`mempool_barrier` is a scalar AMO; it does not wait for Spatz `vse32.v` to commit. Cross-core readers must
rely on a real store-completion guarantee (or enough downstream work to drain). Plain `fence` waits only on
the *integer* LSU, not the VLSU. (See `project_matmul_build1_epilogue_hang` for how store-drain margin was reasoned about.)

### 4.5 NoC response HoL-deadlock on the bufferless bypass 🔧 (known issue)
On the MSHR resp **bypass** path the depth-1 output spill `i_spill_resp_out` ties acceptance to the
consumer (`mempool_group_mshr.sv:509–518`), so a stalled in-order core drops `mshr_noc_resp_ready_o` →
head-of-line-blocks the *shared* response channel →
circular wait → permanent deadlock (`sp-fmatmul` g12 hang; onset ~cyc 8850, ~12.6k frozen txns). VCs and
deepening `resp_buf` do **not** fix it. The documented cure is a **guaranteed response sink** (a deep
per-(tile,resp-port) FIFO so the MSHR accepts every NoC response unconditionally) — see
`docs/teranoc_architecture.md §5.5` and `bottleneck_analysis/2026-06-12_noc_deadlock_fix_report.md` /
`2026-06-16_resp_sink_fifo_bug_rationale_and_overhead.md`. The current RTL still uses output spill
registers (`SpillRespOut=1`) with the hazard noted in-line (`mempool_group_mshr.sv:509–518`).

### 4.6 Two MSHR entries for one address is LEGITIMATE
When a same-address request can't merge into an already-draining entry (`no_late_join_burst`), it allocates
a **second** entry with a different `meta_id` range; responses route by `(tile_id, core_id, meta_id range)`,
not by address (`mempool_group_mshr.sv:773–780`). The single-word duplicate hazard is closed by the
`cached_entry_holds_data` invariant (a CACHED entry always holds its data, so a later same-addr single load
hits the merge path — `:697–711`). `EnableMshrSingleReq=1` is safe.

### 4.7 Virtual channels are a placeholder
`noc_virtual_channel_num` is compiled into a define but **not consumed** in `hardware/src/*.sv`; all
`floo_router` instances hardwire `NumVirtChannels=1`. `floo_vc_router` exists in deps but is never
instantiated. `O1Routing` (a 2-VC scheme) with 1 VC degenerates toward its XY sub-path.

---

## 5. Type / sizing source of truth — `mempool_pkg.sv`

Read this first when tracing any RTL type. Key items (`hardware/src/mempool_pkg.sv`):
- Counts: `NumCores:17 NumGroups:20 NumTilesPerGroup:24 NumBanks:71 (=NumCores·NumFUsPerCore·BankingFactor) NumBanksPerGroup:73`.
- TCDM addressing: `TCDMSizePerBank:70 TCDMAddrMemWidth:74 TCDMAddrWidth:75 SeqMemSizePerCore:507`.
- Burst/MSHR: `MaxBurstWords=16:281 BurstLenWidth=5:282 MshrTagNum:288 MshrTagWidth:291` (tag 0 = bypass sentinel).
- Ports: `NumRemoteReqPortsPerTile:369 (=1+narrow+wide) NumRemoteRespPortsPerTile:370 (=1+NOC_RESP_CHANNEL_NUM)`.
- NoC: `NumX:372 NocTopology:374 NocRoutingAlgorithm:375 NocRouterRemapping:376 NocPortHash:378`.
- Key structs: `tcdm_master_req_t:301 tcdm_master_resp_t:310 tcdm_slave_req_t:316 tcdm_slave_resp_t:327`
  `floo_tcdm_req_meta_t:403 floo_tcdm_rdwr_req_t:417 floo_tcdm_resp_t:476`.
- `routing_table_pkg.sv` — static precomputed torus routing tables (generated by `scripts/gen_routing_table.py`).

---

## 6. Gotchas (build / sim — will bite a fresh instance)

| # | Gotcha | Detail |
|---|---|---|
| G1 | **floogen runs every compile** | sentinel never matches; needs Python ≥3.10. Skip with `make -o update-floogen <target>`; the committed `hardware/generated/floo_terapool_noc_pkg.sv` is valid for all flavors. |
| G2 | **DRAMSys libs always linked** | vsim always gets `-sv_lib libDRAMSys_Simulator`; if `make update-deps` was skipped, vsim won't start. |
| G3 | **Terabool elaboration is slow** | `voptk2` ~7+ min before `run`; normal, not a hang. |
| G4 | **Root `riscv-tests` uses `CONFIG` (uppercase)** | not `config`; `config=...` is silently ignored there. |
| G5 | **SW config must match HW** | build `spatz_apps` with the matching `config=` or you get a silent 4-core binary on 256-core HW → barrier chaos (`project_sw_numcores_config_mismatch`). |
| G6 | **Compiled-vs-not** | §0. Verify any deps/working_dir file against `Bender.yml` before trusting it. |
| G7 | **Only `terapool_spatz4_fpu` boots** on the MSHR branch | smaller Spatz configs wedge at a host-chimney assertion; validate SW sims on terapool. |
| G8 | **`vsim -view <wlf>`** to read a live sim's WLF read-only | dataset prefix is `vsim:` not `sim:`; struct-field examine can abort the macro. |

---

## 7. Debug / profiling tooling (QuestaSim only; gated by `csr_trace_any_global`)

Counters read **zero until the benchmark SW enables tracing** (`mempool_start_benchmark`). Tags to grep:

| Tag | File | What | Anchor |
|---|---|---|---|
| `[LP]` | `tb/tb_noc_link_profiling.svh` | per-link utilization (always on) | `:118` |
| `[BP]` | `tb/tb_noc_bottleneck_profiling.svh` | 8-stage handshake/stall/idle classification | `:310` |
| `[CMS]`/`[CMS WARN]`/`[CMS FINAL]` | `tb/tb_core_mem_scoreboard.sv` (`u_cms`) | per-inflight-request scoreboard; stuck(>1000cyc)/orphan/dup-id warnings | `:217,252,313,394` |
| `[GroupMerge]` | `tb/tb_group_merge.svh` | shadow-MSHR merge efficiency (enable `group_merge_profiling=1`) | `:305` |
| (CSV) | `tb/tb_noc_req_resp_tracer.svh` | per-flit tracer → `noc_trace/events.csv`; key `(owner_g,owner_t,core,meta_id)` stable across hops | `:106` |

QuestaSim TCL in `hardware/scripts/questa/` (`wave.tcl` + specialized). For cycle-level WLF analysis use the
`waveform-analysis` skill (WAL over WLF→VCD→FST).

---

*Maintenance: keep claims `file:line`-anchored; when an anchor drifts, fix it or delete the claim. 🔧 sections
track active development — verify against current RTL. Companion narrative + diagrams: `../docs/teranoc_architecture.md`.*
