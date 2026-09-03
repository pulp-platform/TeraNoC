# Adopting the `spatz_vpu` VLSU burst / ROB redesign

| | |
|---|---|
| Date | 2026-09-03 |
| Their tree | `/usr/scratch/badile48/msc26f31/spatz_vpu-teranoc` @ `a209a8f`, branch `teranoc` (author Yinrong Li) |
| Their integration | `/usr/scratch/badile48/msc26f31/teranoc/TeraNoC-spatz-burst` @ `66bb6df6`, branch `spatz-burst` (on their `monster` fork, **not** ours) |
| Our tree | `working_dir/spatz` @ `bfd2bf4`, branch `zexin/rob32_partial_commit` |
| Fork point | their `9c6b498` == our `58c56d0` — **blob-identical** for `spatz_vlsu.sv`, `reorder_buffer.sv`, `spatz_vfu.sv` (verified) |
| Delta | 27 commits theirs (2026-08-27 … 2026-09-03), 6 commits ours |
| Files touched | `spatz_vlsu.sv` (+671/−…), `spatz_vfu.sv` (+497), `reorder_buffer.sv` (+96), `spatz_fpu_sequencer.sv`, `spatz_decoder.sv`, `spatz_pkg.sv{,.tpl}`, `Bender.yml`. **No new files.** Their layout is `hw/src/`, ours `hw/ip/spatz/src/` — a mechanical path rewrite, nothing else. |

Their branch is a *replay* of our history with the paths moved, so every one of their commits
cherry-picks onto our tree with `--strategy-option` path munging and no content conflict except
where our 6 post-fork commits touch the same lines (all in `spatz_vlsu.sv` / `reorder_buffer.sv`,
enumerated in §6).

---

## 1. The headline: our burst path violates Spatz's chaining contract

This is the finding that justifies the whole exercise, and it is **not** an optimisation — it is
silent wrong data in the current tree.

**Spatz chains at one-cycle granularity, not at instruction granularity.**
`spatz_controller.sv:257` — `wrote_result_q[id]` means literally *"did instruction `id` write the
VRF in the previous cycle"*. The hazard gate is

```systemverilog
sb_enable_o[port] = sb_enable_i[port] && &(~deps | wrote_result_q) &&
                    (!|deps || !prevent_chaining);          // :306-313
```

and `sb_enable_o` **is** `vrf_re` (`spatz.sv:285`). So a consumer's operand read is unblocked as
soon as its producer wrote *anything* one cycle earlier. `prevent_chaining` is set only for
`{VSLIDEUP, VLSE, VLXE, VSSE, VSXE}` (`:424-425`) — a plain unit-stride `VLE`, i.e. **exactly the
burst path**, chains.

That contract requires each VLSU write to be a **whole VRF row**. The non-burst path honours it:
`vrf_req_valid_d = &(rob_rvalid | ~mem_pending)` and all four ports' words go into one 128-bit
write, so the consumer is at most one row behind and both sides advance one row per cycle.

Our **port-0-burst** path does not:

```systemverilog
commit_port_active = commit_use_port0_burst ? {{(N_FU-1){1'b0}}, 1'b1} : {N_FU{1'b1}};  // :293
vd_vreg_addr       = (vd << …) + burst_word_idx;                                        // :835
vrf_req_d.wdata[ELEN*burst_lane_idx  +: ELEN] = rob_rdata[0];                            // :1642
vrf_req_d.wbe  [ELENB*burst_lane_idx +: ELENB] = burst_lane_wbe;                         // :1644
```

Every beat funnels into ROB0 and commits **one lane at a time** (two under `commit_pair_active` /
TwinROB0). The VRF honours `wbe` so nothing is lost as a *write* — but the producer now writes
every cycle while filling only ¼ of a row, `wrote_result_q` stays continuously high, and the
consumer reads a **full row per cycle**. It overruns the producer 4:1 and reads 3 stale lanes out
of every 4.

Their `spatz_wide_burst_adapter.sv` header records the empirical half of this:

> *"Funnelling every beat into ROB0 instead forces a row to be filled by several partial writes,
> and a consumer that reads between them sees stale lanes — measured as wrong results on every
> 8th output row."*

**This corroborates a bug we already have on file and never explained.**
`project_matmul_build1_epilogue_hang` recorded that a host replay of the same inputs verified
clean (worst diff 4.3e-4) and concluded *"wrong result is a genuine DEVICE bug"*; we then set
`MATMUL_VERIFY=0` and moved on. The mechanism above is a complete explanation, and it predicts
exactly the shape observed: partial, geometry-dependent corruption rather than a hang.

**Consequence for our published numbers:** every burst-path GEMM cycle count remains valid (the
corruption does not change timing), but any *result* produced with `commit_use_port0_burst` active
is suspect. Device-side verification has been off, so we have no coverage either way.

---

## 2. What they actually changed

One idea, applied consistently: **stop funnelling. Send beat `k` to lane `k % NrMemPorts`** —
the ordinary word→port rule the non-burst path already uses (`offset = 4n + port`).

* ROB `p` receives words `p, p+4, p+8, …` as its own consecutive entries.
* One element from each ROB fills a VRF row in **one** write → the burst commits through the
  *ordinary* path. The entire dedicated burst commit branch is deleted; `vrf_req_valid_d` is now
  `&(rob_rvalid | commit_finished_q) && !(&commit_finished_q) && |mem_pending` for every load.
* **TwinROB0 goes away** (`BurstRecvPorts` pinned to 1, `commit_pair_active` tied to 0). It only
  ever existed to feed the funnel: a second write port + second read head on ROB0 plus the
  `burst_odd_expected_q` parity bitmap.
* **`commit_port_active = {N_FU{1'b1}}` unconditionally.**

Making that work needed three supporting pieces:

1. **Every port allocates and is charged.** A burst is still one request on port 0, but all four
   ROBs reserve ids and `mem_pending[p]` is credited `burst_port_share(len, p)`. The request may
   only leave once *all* ROBs hold their ids (`burst_alloc_ready`) — no partial bursts, because
   unequal shares desynchronise the allocators.
2. **One base id for the whole burst, held by dummy padding** (`3e35ea9`, `a209a8f`). Each lane
   allocates `ceil(len/NrMemPorts)` ids; lanes a short last row does not reach take a **dummy** —
   a new `reorder_buffer` input `id_dummy_i` marks the entry valid at allocation with no data, and
   `dummy_o` tells the VLSU to pop it at the head without committing. `a209a8f` extends the same
   padding to indexed/strided/non-eligible loads **and stores**, whose remainder distribution also
   leaves the lanes uneven. An SVA on `rob_id[0..3]` equality is the tripwire.
   *This replaced an earlier per-lane-base-id design (`c868298`) that carried
   `burst_base_ids[N_FU]` on `spatz_mem_req_t`; that field is gone again — good, it would have
   widened every TCDM request struct by 4×`MemRspIdWidth`.*
3. **Any burst length.** `burst_len_calc = min(MaxBurstWords, remaining)` instead of
   "MaxBurstWords or 1", and `MaxBurstWords` becomes `SPATZ_MAX_BURST_WORDS` (they derive it from
   their wide plane's width). The `EW_32`-only eligibility test and `SPATZ_VLSU_BURST_EW16` are
   deleted: the path is word-granular end to end, so element width never enters the lane mapping.
   The admission ceiling rises 4× — `vl <= NrOutstandingLoads * MemDataWidthB * NrMemPorts` —
   because the capacity is now the whole buffer set, not ROB0 alone.

Plus one latent-bug fix that only exists *because* of the redistribution: `23f785e`, don't burst
with non-zero `vstart` (the `k % NrMemPorts` lane rule only equals the address-derived lane when
the burst starts at an element index that is a multiple of `NrMemPorts`).

### The architectural asymmetry — read this before believing any speedup number

Their validated configuration (from `build_dmy/compile.tcl`) is:

```
mempool_spatz4_fpu   NUM_CORES=64   NUM_GROUPS=4   VLEN=512
USE_WIDE_TCDM_PLANE  WIDE_TCDM_DATA_WIDTH=512  SPATZ_MAX_BURST_WORDS=16
SPATZ_VLSU_ROB_DEPTH=16  SPATZ_VLSU_BURST=1
(no ROBN_DEPTH, no DUAL_LOAD, no BLOCK_ALLOC, no GROUP_MSHR_*)
```

**A burst on their side is one 512-bit access to a wide TCDM superbank in the same tile.**
`spatz_wide_burst_adapter.sv` unpacks that single wide response into 16 beats and hands 4 per cycle
to the 4 VLSU ports. Distributing beats across lanes is the *only* way to consume a 512-bit return
at rate — for them it is a necessity, not a tuning choice.

**A burst on our side is 16 word requests on a 32-bit mesh**, coalesced by
`mempool_group_mshr.sv` (or expanded locally by `tcdm_burst_expander.sv`), and the return rate is
capped by the number of NoC response channels. We ship `channel_config_mode=baseline` →
`noc_resp_channel_num=2` → `NumRemoteRespPortsPerTile=3` → **2 usable response ports**, and
`group_mshr_drain_beats=2` already sits exactly at that cap.

So: the *correctness* fix and the *area* saving are architecture-neutral and available to us now.
The *4 words/cycle* is not — see §5.

---

## 3. What it buys us structurally

Our current shape is a workaround stack built entirely around the funnel:

| our knob | why it exists | what the redistribution does to it |
|---|---|---|
| `spatz_vlsu_rob_depth=128` | ROB0 alone must hold a whole 512 B burst | a 512 B burst needs `128/4 = 32` per ROB → **uniform 32** |
| `spatz_vlsu_robn_depth=16` | ROB1-3 never see a burst, so don't pay for one | asymmetry disappears |
| `reorder_buffer` generation tag (`GenBits`) | only needed *because* ROB1-3 are shallower than the id width | `GenBits = 0` everywhere → **whole mechanism deletes** |
| `e845ac3` (gen stamp on same-cycle alloc+push) | a bug *in* that mechanism (768 dropped responses/run) | moot |
| `61141df` / `bfd2bf4` (non-burst capacity guard + flood cap) | a 512 B **store** cannot burst and wedges at ROBN=16 | a uniform 32 removes the wedge; the guard becomes a tripwire, not a live constraint |
| `group_mshr_drain_beats=2` + TwinROB0 | 2-wide receive bolted onto a 1-lane commit | the commit is row-wide again; the drain width becomes a pure bandwidth knob |
| `spatz_vlsu_block_alloc=1` (−6.1%) | the walk costs 16 cycles per burst | the walk is now `ceil(16/4) = 4` cycles → most of BlockAlloc's benefit is subsumed |

Their own measurement supports the depth claim directly: `build_hist16`, `build_hist32`,
`build_hist64` all return **3996 cycles** on `sp_gemv_f16` — ROB depth 16 vs 64 is
cycle-identical, i.e. the burst path no longer needs a deep buffer.

---

## 4. Backend PPA

No netlist is produced in this repo (backend is `tsmc7`'s flow), so this is a structural count in
the same style as `docs/mshr_spatz_ppa_review.md`. Basis: `terapool_spatz4_fpu`, `N_FU =
NrMemPorts = 4`, `ELEN = 32`, `VLEN = 512`, `MaxBurstWords = 16`, current knobs as shipped.

### 4.1 Sequential state, per Spatz core

| structure | now (ROB0=128, ROBN=16) | theirs, uniform 32 | theirs, uniform 16 |
|---|---:|---:|---:|
| `mem_q` (data) | 4096 + 1536 = 5632 | 4096 | 2048 |
| `valid_q` | 128 + 48 = 176 | 128 | 64 |
| `dummy_q` (**new**) | — | +128 | +64 |
| `entry_gen_q` + `gen_q` (generation tag) | 144 + 9 = 153 | 0 | 0 |
| pointers + `status_cnt_q` | 22 + 39 = 61 | 64 | 52 |
| `burst_odd_expected_q` (TwinROB0 parity) | 128 | 0 | 0 |
| `pad_bytes_q` + `burst_total_q` (**new**) | — | +17 | +17 |
| **total** | **6150** | **4433** | **2245** |

* uniform 32 — same 512 B burst ceiling as today: **−1717 flops/core, −28%**
* uniform 16 — their validated point, 256 B ceiling: **−3905 flops/core, −63%**

At 5–7 GE per flop including clocking that is roughly **−9 to −12 kGE/core** at depth 32, so
**−2.3 to −3.1 MGE at 4×4 (256 cores)** and **−9 to −12 MGE at 8×8 (1024 cores)**. Treat the GE
figure as an estimate; the flop count is exact.

`stale_drop_q` (32 b/ROB) is correctly inside `ifndef TARGET_SYNTHESIS` and `entry_gen_q` at
`GenBits==0` is reset-constant, so neither is a hidden cost today — checked, not assumed.

### 4.2 Combinational — the larger half

The ROB's read head is a `NumWords:1` `DataWidth`-wide mux, and depth enters it linearly:

| | now | uniform 32 |
|---|---:|---:|
| ROB0 head `data_o` (128:1 × 32 b) | 4064 mux2 | — |
| ROB0 second head `data2_o` (TwinROB0) | 4064 mux2 | **0** |
| ROB1-3 heads (3 × 16:1 × 32 b) | 1440 mux2 | — |
| 4 × 32:1 × 32 b | — | 3968 mux2 |
| **total** | **9568** | **3968** |

**−5600 2:1 mux cells/core ≈ −14 kGE/core** at ~2.5 GE each — larger than the flop saving. Also
gone: ROB0's second write decoder, the `entry_gen_q` push-time 16:1 × 3 b compare muxes on three
ROBs, and the `commit_pair_active` / `burst_lane_idx+1` 2-wide write-data steering.

Added: a `burst_rows` / `burst_port_share` add-and-shift (a handful of gates, off the request
critical path), and the `dummy_o` term on `rob_pop` / `mem_req_svalid`.

The timing-critical `id_valid_o → mem_req_lvalid` path is **unchanged** — it still comes from
`status_cnt_q` (our `rob_cnt_idvalid=1`, which they simply hardwired on).

### 4.3 System-level: `meta_id_t` narrows

`snitch_pkg.sv:26-27` — `MetaIdWidth = idx_width(SPATZ_VLSU_ROB_DEPTH)`, and `meta_id_t` reaches
**every TCDM struct and both FlooNoC flit metas** (`mempool_pkg.sv:281`, `floo_tcdm_resp_meta_t`).

* 128 → 32: **7 → 5 bits, −2 b**
* 128 → 16: **7 → 4 bits, −3 b**

Where those bits land:

* every narrow-req and every resp flit on every mesh link, plus each router's input/output FIFOs
  (depth 2, 5 directions);
* `mempool_group_mshr.sv` `sub_reqs[].meta_id_base`: 64 entries × 16 merge slots × 2 b =
  **2048 b/group** → 32 kb at 4×4, **131 kb at 8×8**;
* `tcdm_id_remapper` id tables.

This reverses the ROB64→ROB128 link widening that our own notes flag as needing a PNR re-close —
it is the one item here that is worth more than everything else combined, and it is free with the
depth reduction.

### 4.4 The counterweight: 4-wide receive is not free

Consuming 4 beats/cycle requires 4 usable response ports, i.e. `noc_resp_channel_num` **2 → 4** —
two additional full response links (~66 b each: `data` 32 + `wen` + `meta_id` + `core_id` 3 +
`tile_id` 4 + `src/dst_id` + `last` + `mshr_tag` 6) on every mesh edge, with their router FIFOs and
crossbar share. That roughly **doubles response-side NoC area** and dwarfs the −14 kGE/core saved
in the cores.

Our own evidence says do not buy it yet:

* the 1-wide → 2-wide step (`respbw_paritydrain`) measured **1.27× VLSU / 1.11× matmul**;
* `project_sp_fmatmul_compute_bound` — sp-fmatmul sits on a 16384-cyc/core FPU floor, so response
  bandwidth is not the binding constraint on the shape we publish.

**Recommendation: adopt at `drain_beats=2`.** With 2-wide drain and beat `b` → lane `b & 3`, the
existing PD2 pairing delivers consecutive lanes (0,1) then (2,3), a full row every two cycles =
**2 words/cycle sustained — identical to today's TwinROB0 throughput**, with the corruption fixed
and the area gone. Then price 3-wide (`channel_config_mode=enhanced`, already exists) and 4-wide
against measurement, which is the open KB task *"Generalize ParityDrain to N response ports"*.

---

## 5. Changes required on **our** side — CORRECTED 2026-09-03

Their integration consumes the contract in `spatz_wide_burst_adapter.sv`. Ours must **produce**
it: **beat `b` → core data port `base_core + (b & 3)`, `meta_id = base_meta + (b >> 2)`**,
replacing today's `+ (b & 1)` / `+ b`.

**The first version of this section put those edits in the group MSHR. That is wrong, and the
reason is worth writing down: an intra-group burst never passes the MSHR.** `mempool_group.sv`
taps `group_mshr_req[t][r]` only for `r >= 1`; lane 0 — every same-group target — rides the group
LIC straight to the destination tile's slave port and back, so a retag inside the MSHR is
invisible to it. At 4×4 that is 1/16 of all lines and at 8×8 1/64, i.e. a steady stream of
silently misplaced beats, not a corner case. Two further paths have the same property: an
own-tile burst goes through `i_local_burst_expander` to the local banks, and its response
returns through the LIC **by structural initiator index**, so no core_id retag can re-route it
at all.

### The single point where every return path has converged

`mempool_tile.sv`, `gen_tcdm_registers_resp` — the master-response fall-through register, ahead
of `postreg_tcdm_master_resp_ini_sel` (which is `rdata.core_id`, so retagging there *is* the
re-route). Four kinds of burst response arrive on those ports:

| path | how it gets there | carries |
|---|---|---|
| MSHR-merged | the MSHR re-emits per requester from `sub_reqs[].meta_id_base + b` | `base + b`, issuing port |
| MSHR-bypassed | expanded at the destination tile | `base + b`, issuing port |
| intra-group | master lane 0 → group LIC → destination slave port → back | `base + b`, issuing port |
| own-tile | *does not arrive here* — LIC, routed by initiator index | — |

So the work is:

1. **A burst never takes the own-tile local path.** In `gen_core_port_mux`, divert a
   `burst_len > 1` request from `local_req_interco_valid_raw[idx]` to
   `remote_req_interco_valid_raw[idx]`, and feed the shim's local `ready` from the remote path
   while diverted. Cheap because the remote payload is *already fully formed* — the shim
   computes both and only `valid` differs (`mempool_tile.sv:1169-1195`). The group LIC has all
   `NumTilesPerGroup` tiles as destinations, the source tile among them. Cost: a group-LIC round
   trip instead of a direct local access, on the small fraction of lines homed in the core's own
   tile.
2. **One retag table per tile.** Allocate on a burst request handshake out of
   `prereg_tcdm_master_req` (load, `burst_len > 1`), recording `{core_id, meta_base, len}`; match
   an arriving response by `core_id` and `meta_id - meta_base < len`; rewrite `core_id` and
   `meta_id` per the lane law; retire on the response handshake. This is the same structure as
   the MSHR's existing bypass-track table — reuse its shape, including the way-index width trap.
   Depth bound: `RobDepth / (MaxBurstWords / NrMemPorts)` = 32/4 = **8 ways**. Note a burst
   occupies `burst_rows` ids per buffer rather than `MaxBurstWords` in one, so this is
   `NrMemPorts` times the old figure — the shrunken buffers do **not** shrink this table.
3. **Delete the MSHR's ParityDrain `core_id` retag** (`mempool_group_mshr.sv:4068`, `:4228`) and
   with it the whole `gen_bypass_retag` table and its assertions. Once the tile retags, the MSHR
   adding `+ (b & 1)` would double-count. Its per-requester `meta_id_base + b` re-emission
   stays — that is the multicast, not a retag. This is a net **simplification** and a flop
   saving; 2-wide delivery still works, because the tile assigns two beats drained in one cycle
   to different lanes by their own `b`.
4. **`tcdm_burst_expander` needs no change.** Its `meta_id = base + beat` is the wire encoding
   the MSHR decodes (`resp_beat_offset = arriving meta_id − sub_reqs[0].meta_id_base`), so
   changing it there would break the MSHR's beat bookkeeping. The earlier version of this
   section had this backwards.

**Until this lands, `spatz_vlsu_burst=0`.** `mempool_tile.sv` carries an elaboration `$error` for
the pair, so the combination cannot be built. At 0 every vector load takes the 4-port
word-interleaved path, which is row-atomic and correct; what it costs is the group MSHR's burst
class — no burst merging, no ParityDrain, no block allocation.

Guards to revisit when it lands: `mempool_tile.sv:88-95` (`group_mshr_drain_beats=2 requires
NumCoresPerTile==1` / `needs core data ports {1,2}`) and `mempool_group_mshr.sv:137-144`.
`mempool_pkg::MaxBurstWords` stays 16 — do **not** import their `SPATZ_MAX_BURST_WORDS`
parameterisation without making the TeraNoC-side constant follow it; they are the same quantity
and a mismatch is silent.

## 6. Defects in their tree that must be fixed before adoption

Found by inspection; each is dead code in *their* configuration, which is why their sims pass.

### 6.1 `SPATZ_VLSU_BLOCK_ALLOC=1` hangs — and it is our shipped default

`c868298` deleted the branch that consumed the block grant:

```systemverilog
if ((BlockWords > 1) && (port == 0) && burst_block_fire) begin
  burst_reserved_d        = 1'b1;        // ← the ONLY setter, now gone
  burst_base_id_d[port]   = rob_id[port];
  burst_alloc_cnt_d[port] = burst_len_q[port];
end else if (…)
```

`grep burst_reserved_d` on their `spatz_vlsu.sv` returns only the two clear sites and the
`= burst_reserved_q` default. So with `BlockWords > 1`: `burst_reserved_q` never sets →
`rob_req_block[0]` stays asserted → the ROB fires `block_fire` and advances `write_pointer` by 16
**every cycle it has room**, while the VLSU walks ids one at a time and never captures the base.
The reserved entries are never pushed, `valid_q` never sets under the read head, and ROB0 wedges
permanently. `spatz_vlsu_block_alloc ?= 1` in `config/terapool_spatz4_fpu.mk:646`.

**Fix:** either restore a block path that reserves `burst_rows()` per ROB in one cycle (the right
answer — it is worth ~3 cycles/burst now, not 15), or hard-`$error` on `BlockAlloc != 0`. Do not
adopt with the knob silently broken.

### 6.2 Inferred latch on `pad_init[1..3]`

`a209a8f` puts `pad_init[port] = mem_max_elements[0] - mem_max_elements[port]` (`:1231`) inside the
`else` arm of the per-port `always_comb` in `gen_mem_counter_proc`. The `if` arm
(`mem_use_port0_burst && port != 0`) assigns every other output on that path *specifically to avoid
this* — see the SYNTH_12608 comment 25 lines above — but not `pad_init`. Latch on 3×3 bits/core,
and `pad_bytes_d` loads whatever was held at the next `mem_counter_load`. Benign today only because
`pad_fire` demands `!mem_use_port0_burst`. One-line fix; violates our own
`feedback_rtl_decl_conventions`.

### 6.3 `dual_load=2` is unvalidated against the alignment invariant

`spatz_vlsu_dual_load ?= 2` is our shipped default (−2.8%). `fe49caa`'s original assertion comment
said outright: *"Enabling dual-load would overlap one instruction's tail with the next's bursts and
break it."* `3e35ea9` moved to the `rob_id`-equality invariant and `a209a8f` claims to close it on
every path — but `pad_bytes_d` is reloaded on `mem_counter_load[port] = commit_insn_push ||
switch_to_tail_phase`, which under `dual_adv` fires for the *younger* instruction while the elder
still drains. Their build sets no `DUAL_LOAD`. **Must be re-derived and simulated with
`dual_load=2` before it goes near a sweep image**; the SVA will catch it loudly if it breaks, which
is the one good thing here.

### 6.4 Residual `switch_to_tail_phase`

`burst_len_calc = min(MaxBurstWords, remaining)` makes a tail a short burst, yet
`switch_to_tail_phase` (`:1473`) is still live and still re-bases the counters onto the
word-interleaved tail path — and `a209a8f`'s word-path dummy padding exists precisely to serve it.
Two paths now race for the same remainder (the tail phase additionally requires
`mem_pending_q[0]=='0'`). Not obviously wrong, but it is unreviewed dead-ish state on the path that
`project_vlsu_burst_tail_store_hang` already bit us on once. Decide: keep the tail phase and delete
the short-burst arm, or the reverse.

### 6.5 Do not take `Bender.yml` wholesale

Their manifest drops `hw/ip/spatz_cc/src/spatz_mempool_cc.sv` from the compile (`5a79099`) because
their TeraNoC has its own `mempool_cc.sv`. **We instantiate `spatz_mempool_cc`** and it carries our
`data_qburst_len_o` plumbing, the per-core tracers, `[VPERF]`, and the ROB64 tripwires. Their
dependency-version deletions are also theirs, not ours. Take only the `rvv_pkg`/`spatz_pkg`
unconditional-compile hunk (harmless, arguably correct) and nothing else.

### 6.6 `2212318` is not adoptable

It rebinds `spatz_fpu_sequencer`'s `i_fp_lsu` to a **unified `snitch_lsu`** that only *their*
`monster` fork has (`rst_ni` instead of `rst_i`, no `dreq_t`/`drsp_t`/`DataWidth`, `lsu_qwrite`
instead of `lsu_qwrite_i`, plus a new `lsu_pwrite_o`). Our `hardware/deps/snitch/src/snitch_lsu.sv`
still has the upstream interface — verified. Taking this commit breaks elaboration.

It matters because **`549f242` depends on `lsu_pwrite_o`**: driving scalar-FP store completion from
the LSU's write response instead of request acceptance. The bug is real (Snitch decrements its
outstanding-store counter on that pulse, so an early release lets a scalar load read stale L1) and
it is the same class as `reference_request_sent_fence`. Adopting it means adding `lsu_pwrite_o` to
our `snitch_lsu.sv` ourselves — contained, but it is a `deps/` change and needs to be called out in
the PR per `AGENTS.md`.

---

## 7. Second high-value find: `dae5a9e` fixes a bug we papered over in software

Independent of the burst work, and 6 lines:

```systemverilog
// spatz_fpu_sequencer.sv, fp_move_result_i
`ifdef TARGET_MEMPOOL
  fp_move_result_i.write = 1'b1;   // MemPool's Snitch retires an acc response only on acc_pwrite=1
`endif
```

Our tree builds that response with `default: '0`, so `write = 0` — **verified in
`working_dir/spatz/hw/ip/spatz/src/spatz_fpu_sequencer.sv:729-733`.** `fmv.x.w`'s GPR result is
therefore never written back and a dependent instruction deadlocks the core.

That is verbatim our own `project_matmul_build1_epilogue_hang`: *"core-0 hang is in the EPILOGUE:
`fmv.x.w` in error printf deadlocks on `pwrite=0` acc writeback"*. We worked around it in C
(`f32_to_bits` via `fsw`+`lw`) and disabled `MATMUL_VERIFY`. **Adopting this lets us delete the
software workaround and turn device-side verification back on** — which we now urgently want,
given §1.

The same commit carries two more of the same family:

* `spatz_decoder.sv` — `VMV_X_S` never set `vtype.vsew`, so it defaulted to `EW_8` and the VFU
  completion mask expected `8'hff` for a 4-byte IPU scalar result. Mirrors `VFMV_F_S`.
* `spatz_vfu.sv` — `valid_operations` / `pending_results` keyed the scalar mask off `vsew == EW_32`,
  so every `e8`/`e16` scalar op (`vmv.x.s`, `fcvt.h.s`) deadlocked. Correct predicate is
  `vsew == EW_64 ? 8'hff : 4'hf`. **This is the other half of our own `5b3136f`** — we fixed the
  *width source* (`result_tag` vs live `spatz_req`); this fixes the *predicate*. `5bbcd5a`'s only
  content is a comment recording that neither subsumes the other, which is worth taking as-is.

`f38eac2` extends `5b3136f` to the three remaining `spatz_req`-instead-of-`result_tag` reads
(`pending_results` width, `scalar_result`'s `is_scalar` gate — which can report `wb=1` with data 0
for `vmv.x.s`/`vfmv.f.s` — and `ipu_result_pnt_d`'s reduction reset). Same root cause as our
confirmed fp16 hang; take it.

---

## 8. Commit-by-commit verdict

| # | commit | verdict | note |
|---|---|---|---|
| 1 | `2212318` bind FP sequencer to unified `snitch_lsu` | **no** | their fork's interface; breaks our build (§6.6) |
| 2 | `e32ace8` drop FLB/FSB from scalar-FP decode | **yes** | `funct3=000` collides with `VLE8_V`/`VSE8_V`/`VLUXEI8`; real mis-route |
| 3 | `549f242` scalar FP store completes on write response | **yes, after** adding `lsu_pwrite_o` to our `snitch_lsu.sv` |
| 4 | `dae5a9e` fp16 scalar-FP-extract deadlocks | **yes — priority** | §7; fixes our known `pwrite=0` hang |
| 5 | `22637ee` `vmv.s.x` insert + drop bogus `vmv` `vs2` reads | **yes** | wrong result *and* a false RAW dep + wasted VRF read port |
| 6 | `f38eac2` retire VFU results by their own tag | **yes** | completes our `5b3136f` |
| 7 | `61a3fef` VFU response only when consumed | **yes** | duplicate GPR writeback + scoreboard clear on a reallocated id |
| 8 | `9fd733b` drain non-reduction results during a reduction | **yes** | wedge; also affects `n_fpu=0` builds |
| 9 | `05c6175` word-parallel tree reduction | **defer** | +~420 flops & a variable shifter per core; a *reduction latency* win. GEMM has none; Qwen3.8 RMSNorm/softmax do. Decide on its own measurement, not as part of this |
| 10 | `5ec9732` widen + re-site outstanding-store counter | **yes** | ours is `id_t` = 7 b at ROB128 and counted *after* the spill register; 128 outstanding e8 stores/port wraps it exactly, and a buffered store is invisible to `store_drain_ready` |
| 11 | `5a79099` drop `spatz_mempool_cc` from compile | **no** | we instantiate it (§6.5) |
| 12 | `6a3803d` gate `[VPERF]` on `SPATZ_VPERF` | **maybe** | ours already `ifdef SPATZ_VPERF`; check for drift only |
| 13 | `0645440` type on `IdWidth` parameter | **yes** | `parameter int unsigned IdWidth`; trivial |
| 14 | `54f6c9e` gate load writeback on commit counters | **yes — priority** | our `:1648` is still the buggy `&(rob_rvalid \| ~mem_pending) && \|mem_pending`; early commit with garbage lanes → dropped responses → wedge in `RunningLoad`. **Independent of the burst work** |
| 15 | `655dc50` remove ROB free-id bitmap | **yes** | this is our `rob_cnt_idvalid=1` hardwired on. We already ship it; taking the commit removes the dead `else` branch |
| 16 | `fbbd129` compile `rvv_pkg`/`spatz_pkg` unconditionally | **yes** | harmless |
| 17 | `5bbcd5a` record both hazards on the completion mask | **yes** | comment only; keep the reasoning |
| 18 | `b8484db` gate burst emission on `SPATZ_VLSU_BURST` | **optional** | portability knob for word-granular memories; costs nothing |
| 19 | `84b5060` keep the `\|mem_pending` qualifier | **yes** | must land with #14 — the offset-queue leak |
| 20 | `315f234` gate burst-eligibility probe on `SPATZ_BURST_DEBUG` | **yes** | ours already has `BurstWhyMax`; check for drift |
| 21 | `fe49caa` **distribute burst beats across the ROBs** | **yes — the core change** | needs §5 |
| 22 | `23f785e` no burst with non-zero `vstart` | **yes** | required by #21 |
| 23 | `c868298` burst any length, per-lane ROB base | **partially** | take the `min(MaxBurstWords, remaining)` length and the element-width generalisation; the `burst_base_ids` struct field is reverted by #26 anyway. **Re-add `burst_reserved_d = 1'b1`** (§6.1) |
| 24 | `fa66980` trim rationale comments | **no** | it strips the design-doc cross-references and the *reasons* our commits recorded (e.g. why the `<=` in `room_block_o` is load-bearing). Keep our comments |
| 25 | `cfc92fb` trim the manifest | **no** | §6.5 |
| 26 | `3e35ea9` keep the ROBs aligned with dummy entries | **yes** | the enabler for one base id; removes `burst_base_ids` from the request struct |
| 27 | `a209a8f` pad the non-burst paths | **yes, with the latch fixed** | §6.2 |

Our 6 post-fork commits: `e3030c3` (`NO_VL_CEILING`) and `baf447d` (`ROBN_DEPTH` + widened request
id) are **superseded** — drop both. `e845ac3` (gen stamp) becomes dead with `GenBits=0`; keep the
file change only if we retain `GenBits` for another reason. `61141df` / `bfd2bf4` / `9b9d0bb` are
guard/assertion work that survives unchanged.

---

## 9. Recommended sequencing

1. **Now, zero risk, unblocks everything else:** cherry-pick the correctness set that does not touch
   the burst datapath — #2, #4, #5, #6, #7, #8, #10, #13, #14, #17, #19. Add `lsu_pwrite_o` to
   `snitch_lsu.sv` and take #3. Delete the `f32_to_bits` workaround and **turn `MATMUL_VERIFY` back
   on**. #14+#19 alone are worth the trip: our current writeback gate can commit an instruction
   with garbage lanes.
2. **Establish the §1 corruption on our own tree** before changing the datapath: with
   `MATMUL_VERIFY=1`, run one shape with `spatz_vlsu_burst_ew16=0` (burst path off for fp16, word
   path only) against the same shape with it on. If §1 is right, the burst arm mismatches and the
   word arm does not. That is the A/B that makes the rest non-negotiable.
3. **Then the burst redesign** — #21, #22, #23 (repaired), #26, #27 (repaired) — plus the four §5
   TeraNoC sites, with `group_mshr_drain_beats=2` unchanged and `spatz_vlsu_rob_depth=32`,
   `spatz_vlsu_robn_depth` **unset**. Expect: correctness fixed, cycles ≈ unchanged, `MetaIdWidth`
   7→5. Re-validate `dual_load=2` explicitly (§6.3), and either repair or `$error` `block_alloc`
   (§6.1).
4. **Only then** price wider receive: 3-wide via `channel_config_mode=enhanced`, 4-wide via a new
   `noc_resp_channel_num=4` mode, each measured against the response-NoC area in §4.4.
5. `05c6175` (tree reduction) on its own track, driven by the Qwen3.8 decode kernels.

---

## 10. Open questions for Yinrong

1. Was the "every 8th output row" corruption measured on the **funnel** path with a wide plane, or
   reproduced on a narrow/NoC integration too? If the latter, which kernel — we would like to reuse
   it as our A/B in step 2.
2. Was `SPATZ_VLSU_BLOCK_ALLOC` ever exercised after `c868298`? We read `burst_reserved_d = 1'b1`
   as deleted (§6.1) and would like that confirmed rather than assumed.
3. Any run with `SPATZ_VLSU_DUAL_LOAD=2`? The `rob_id`-equality SVA is the thing we care about.
4. Is `switch_to_tail_phase` intended to stay live now that a tail is a short burst (§6.4)?
5. `SPATZ_MAX_BURST_WORDS` — do you also drive the integration-side `MaxBurstWords` from the same
   variable? On our side that is `mempool_pkg::MaxBurstWords` and a mismatch is silent.
