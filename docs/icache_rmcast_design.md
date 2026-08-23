# R-MCAST — multicast response fan-out for the group read-only instruction cache

**Status:** design + implementation (opt-in knob `ro_cache_r_multicast`, default **0** = bit-identical
to baseline).
**Scope:** `snitch_read_only_cache` (the per-group L2 instruction cache) response path only. The
request-merge path is **unchanged** — it already works.

---

## 0. TL;DR

When N tiles of a group miss on the same instruction line, the RO cache already fetches it from L2
**once** and already computes a bit vector of exactly which tiles are waiting. It then spends that
vector **one bit per cycle** on the AXI R channel, delivering the line to one tile per cycle in fixed
ascending tile order — a measured **+1-cycle-per-tile staircase, 15 cycles first-to-last** for a
16-tile group.

R-MCAST delivers that one beat to **all eligible tiles in the same cycle**. The 512-bit datapath is
already physically replicated to every slave port, so this is a **control-only** change:
~51 flops + ~200 cells per group (~10-15 kGE chip-wide, estimated, not synthesized).

---

## 0-BIS. MEASURED OUTCOME (2026-07-26) — **FEATURE NOT ADOPTED, KNOB STAYS 0**

> This section supersedes the expectations in §5. Everything below §1 is retained as the design
> record; the numbers here are what actually happened.

**It works, and it still loses.** The refill de-skew is real (first-VLE-issue spread across a group's
16 tiles: **15 -> 0**; whole-run per-hart `stall_ins` **-9.5%**). But:

* **The benefit is structurally tiny — the premise was too narrow.** A RO-cache **HIT** responds with
  `hit_id = 'b1 << in_req_id_i` (`snitch_icache_handler.sv:191`) — a one-hot of the SINGLE requester.
  Only a **miss** emits the N-hot `pop_idmask`. The cache request port is scalar and the group
  `axi_mux` admits one AR/cycle, so **hits are structurally one-per-cycle and multicast cannot touch
  them**. Measured `[ROC]`: fanout=1 = **12057 beats (95.5%)** vs fanout=16 = 384 (3.0%); total
  `cyc_saved` = 7399 R-cycles chip-wide for the entire run. The feature accelerates ~3% of beats.
* **Intrinsic cost +4.9%** (`GROUP_MSHR_NUM=64`, each point reproduced twice): OFF **3977** vs ON
  **4171**. Front end improved (`stall_ins` -137/hart) but the back end lost more (`stall_acc` +201).
* **At `GROUP_MSHR_NUM=32` it triggered a runaway: 3905 -> 5047 (+29%)**, localized 100% to group
  (0,0). Chain: removing the 15-cyc de-skew shifts the request PHASE -> followers miss the MSHR hold
  window -> 467 burst + 67 single hold TIMEOUTS, each eating the full 63/127 cyc and squatting a way
  -> occupancy 11.4 -> 24.0 of 32 (max 32, FULL) -> `mshr_overflow` 0 -> 383 -> coalescing dies
  (`merged_burst` 351 -> 0) -> VLE latency 106.8 -> 173.2 -> tiles skew further (median spread 68 ->
  410) -> more timeouts. **N=1 runaway; quote +5%, not +29%.**
* **The all-ready `r_pop` was NOT the problem** (an early hypothesis, refuted): `roc_hold_cyc = 0` in
  16/16 groups — the join never stalls, because a tile's `slv_r_readies` is a permanently-high level
  (tile `axi_mux` `SpillR=0` + `axi_cache_slice`; `snitch_icache_l0.sv:124` MLP=1). And `acc_q`
  (`axi_mux_mcast.sv:513-521`) **already is** partial acceptance. A "partial drain" rewrite would
  recover exactly zero cycles — do not build it.

**Recurring lesson (third measurement of the same effect in this tree** — per-step barrier 3940 vs
3836; hold-the-fetch W-sweep 3836 -> 3986/4209/4229; now R-MCAST**):** capacity/occupancy is
first-order in this machine, skew is second-order, and **anything that converts skew into occupancy
loses**.

**The genuinely valuable finding is an INDEPENDENT bug this exposed:** the group-MSHR hold window has
no capacity backpressure — a held entry can starve an allocation that would otherwise merge
(`mempool_group_mshr.sv:2068-2080`). Fix: add `|| bank_ways_full` to `hold_done`. Mitigations already
validated in-tree: `group_mshr_hold_window_*=0`, and/or `group_mshr_num` 32 -> 64.

**Latent R-MCAST defects (measured NOT firing; fix before ever defaulting on):**
1. `snitch_axi_to_cache.sv:293` drives `r_mcast_mask_o` unqualified by the demux R-arbitration winner
   (`r_idx`), unlike the demux pop mask. Safe-by-construction: `r_target = r_onehot | r_out.mask`.
2. `snitch_axi_to_cache.sv:164-171` (splitting arm) asserts `cnt_alloc_req` unconditionally while
   `:152` admits on `(cnt_alloc_gnt || ar_noalloc)`. Harden `ar_elig` to also require `ar_len == '0`.
   Unreachable today only because `mempool_pkg.sv:232-234` forces `BeatsPerRefill == 1`.

**Status: RTL kept (const-folds to bit-identical baseline at `RMcastEn=0`), knob default 0. Revisit
only if a workload shows fanout-histogram mass >= 8 AND the MSHR hold policy is capacity-aware.**

---

## 1. The problem, measured

Per group there is ONE `snitch_read_only_cache` shared by 17 AXI masters (16 tile L1 icaches + 1 DMA),
instantiated at `hardware/src/axi_hier_interco.sv:224-254` from `hardware/src/mempool_group.sv:495-522`
(`NumSlvPorts=17`, `Radix=17`, `NumMstPorts=1` ⇒ one flat 17→1 `axi_mux` + one cache, no recursion).

**What already works — request merge.** `snitch_icache_handler.sv` holds a 16-entry pending table
keyed on the line address:

```systemverilog
typedef struct packed {
    logic                         valid;
    logic [CFG.FETCH_AW-1:0]      addr;     // which line
    logic [CFG.ID_WIDTH_RESP-1:0] idmask;   // WHO asked for it
} pending_t;                                                   // :59-64
```

A new miss CAM-matches every valid entry (`:139-153`); on a match the requester's bit is OR-ed into the
existing entry (`idmask <= push_idmask | pending_q[i].idmask`, `:99`) and **no second L2 fetch is
issued**. So N same-line misses cost **1× L2 latency**, not N×.

**What already works — single-cycle release.** The response carries the whole accumulated vector and
one handshake retires the entry and frees every id at once:

```systemverilog
in_rsp_id_o    = pop_idmask;                  // :284
in_rsp_valid_o = |pop_idmask;                 // :327
pop_enable     = rsp_ready;                   // :328 -> pending_clr :111
miss_in_flight_q &= ~in_rsp_id_o;             // :167  all N ids freed same cycle
```

**⇒ `snitch_icache_handler.sv` needs ZERO changes.**

**What is serialized — and the only thing that is.** `snitch_axi_to_cache.sv:221-264` walks that
ready-made vector one bit per cycle with an `lzc`; the source comment says it outright:

```systemverilog
// Reconstruct `id` by splitting cache's ID vector into multiple responses      // :221
assign rsp_ready_q   = (rsp_id_onehot | rsp_id_empty) & rsp_ready;              // :231
assign rsp_id_masked = rsp_in_q.id & ~rsp_id_mask;                              // :233
lzc #(.WIDTH(CFG.ID_WIDTH_RESP), .MODE(0)) i_lzc (...);                         // :235-242
rsp_id_mask <= rsp_id_mask | (1 << rsp_id);                                     // :257
slv_rsp_o.r.id = rsp_id;                                                        // :287
```

The pending entry is only released when the residual mask is one-hot/empty, i.e. after N cycles.

**Measured cost** (`build_w96`, `sp-fmatmul-opt-burst-merge`, first retirement of PC `0x80001994`):

| tile | 0 | 1 | 2 | … | 14 | 15 |
|---|---|---|---|---|---|---|
| cycle | 9459 | 9460 | 9461 | … | 9473 | 9474 |

An exact +1-cycle staircase in **fixed ascending tile order** (`lzc MODE=0` = lowest set bit first;
tile *t*'s AXI ID is `t<<2`), so **tile 15 always pays +15 cycles**. Per-miss fetch stall is 29-55
cycles; aggregate `stall_ins` is **10-23 % of wall clock even with `ICACHE_WARMUP` on**.

**Aggravators (why the tail costs more than 15 cycles of one tile's time).** While a multi-hot
response drains, the handler's response arbiter locks and forces `hit_ready=0`
(`snitch_icache_handler.sv:294-332`), which stalls the shared lookup pipeline, which drops
`slv_rsp_o.ar_ready` (`snitch_axi_to_cache.sv:139`), which HOL-blocks **all 17 masters** through the
group `axi_mux`'s `rr_arb_tree` (`LockIn=1'b1`). Slack before that freeze is only ~6 transactions.

---

## 2. The enabler: the datapath is already replicated

`hardware/deps/axi/src/axi_mux.sv:445-449`:

```systemverilog
assign slv_r_chans  = {NoSlvPorts{mst_r_chan}};                   // 512b data -> ALL 17 ports already
assign switch_r_id  = mst_r_chan.id[SlvAxiIDWidth+:MstIdxBits];
assign slv_r_valids = (mst_r_valid) ? (1 << switch_r_id) : '0;    // only the VALID is unicast
```

Multicast therefore adds **no** datapath: it changes which `valid` bits rise and how `ready` is
collected. Receiver side is equally friendly: a tile's L1 refill does **not** inspect `r.id`
(single-ID master with an in-order queue, `snitch_icache_refill.sv:67-68,127-135`), and a line is one
beat (`LineWidth == AxiDataWidth == 512`, `ar.len=0`).

---

## 3. Design

### 3.1 The key idea — eligibility is an elaboration constant

Every failure mode found while reviewing alternative designs came from **per-transaction
bookkeeping** (id-busy vectors with wrong clear conditions, AR-side vs R-side predicate asymmetry,
freeze registers that did not freeze). R-MCAST removes that state entirely:

```systemverilog
McastOk       = ro_cache_r_multicast
             && (ROCacheLineWidth == AxiDataWidth)    // 512 == 512  -> r_offset tied '1
             && (ICacheLineWidth  <= AxiDataWidth);   // 256 <= 512  -> BeatsPerRefill == 1
eligible(id) <=> (id[1:0] == 2'b00) && McastPortMask[id[6:2]];
```

Two consequences, **proved at elaboration** rather than checked at runtime:

1. **`ar.len == 0` is a theorem for every eligible transaction.**
   `ICacheLineWidth = 32*2*NumFUsPerTile*NumCoresPerCache` (`mempool_pkg.sv:209`) = **256 b** for
   `terapool_spatz4_fpu` vs `AxiDataWidth = 512` ⇒ `BeatsPerRefill = 1`
   (`snitch_icache_refill.sv:37-39`) ⇒ `ar.len = 0` (`:117`). Therefore `r.last = 1` is structural —
   no burst tracking, no premature-`last` hazard, no table slot to leak.
   For `mempool` / `systolic` (4 cores/tile) `ICacheLineWidth = 1024 > 512` ⇒ the guard **fails
   closed**, which is exactly the reachable silent-corruption case.

2. **One beat is bit-exact for all 16 tile icaches.** A tile's icache is slave index 0 of its tile mux
   (`mempool_tile.sv:1484`) with `ar.id = '0` (`snitch_icache_refill.sv:112`), so its id at the group
   is `t<<2` ⇒ `id[1:0] == 2'b00` for every tile icache (the core SoC port is index 1 ⇒ `2'b10`).
   `axi_id_prepend` truncates to `id[1:0]` at each group slave port, so **a single physical R beat
   carries the correct `r.id` for every member simultaneously**.

`McastPortMask` is computed at elaboration in `mempool_group.sv` from the same loop that packs
`axi_slv_req`, so it tracks `NumDmasPerGroup` and excludes the DMA. For `terapool_spatz4_fpu` it is
`17'h0FFFF`.

### 3.2 Two phases — multicast, then residual

A pending entry's `idmask` may mix eligible (tile icache) and ineligible (DMA / SoC) requesters, so
the mask is **exactly partitioned**:

```
pop_idmask  =  mcast_idset  (+)  resid_set          disjoint, union = pop_idmask
                    |                 |
             phase A: ONE beat   phase B: the existing one-per-cycle lzc walk
             to all eligible     (unchanged logic, retargeted at resid_set)
```

Phase A always precedes phase B, and `resid_set` provably contains no eligible bit, so an eligible id
can never reach the lzc/table path. The existing 128-bit `lzc` and `cc_onehot` are **retargeted, not
duplicated** — this is why the area is small.

`mcast_pmask` is a **constant wire-pick off flops** (`rsp_id_masked[p<<2] & McastPortMask[p]`), so 112
of 128 mask bits fold away; the new 17-bit `lzc` (which only picks a representative `r.id`) sits in
the shadow of the existing 128-bit one and adds no depth.

### 3.3 Fan-out: fork/join, not "wait for everyone"

In the new project-local `axi_mux_mcast.sv` (replacing `axi_mux.sv:445-463`):

```
  R spill payload widened by 17 b:   T = {mcast_mask, mst_r_chan}
      |
      +-- slv_r_chans  = {17{r_out.chan}}                    <- unchanged, already exists
      +-- r_target     = (|mask) ? mask : (1 << switch_r_id) <- degenerates to TODAY when mask==0
      +-- r_pend       = r_target & ~acc_q                   <- acc_q: 17 FF "already accepted"
      +-- slv_r_valids = mst_r_valid ? r_pend : '0           <- driven from FLOPS
      +-- r_pop        = ~|(r_pend & ~slv_r_readies)         <- REPLACES the 17:1 ready mux
      acc_q <= mst_r_valid ? (r_pop ? '0 : acc_q | (slv_r_readies & r_pend)) : '0
```

A port that accepts has its `valid` dropped next cycle; ports that did not are re-presented with an
identical payload. **AXI never requires simultaneous acceptance.** Best case 1 cycle, worst case N —
**Pareto: never worse than today.**

> **Why a shared valid + AND-reduce is WRONG.** The *tile-level* `axi_mux` leaves `SpillR = 1'b0`, so a
> tile's `r_ready` is the icache `axi_cut`'s level "has space", not "I am consuming this beat now".
> Holding one beat valid across cycles against that level would let a tile **capture it twice**, and
> `snitch_icache_refill.sv:127-135` would pop its id FIFO twice ⇒ **silent instruction corruption**.
> The per-port `acc_q` is what prevents this.

### 3.4 Mandatory correctness edit — `axi_demux` id counters

`axi_demux_simple.sv` does `pop_en = (pop_i) ? (1 << pop_axi_id_i) : '0` (`:556`) with
`pop_i = r_valid & r_ready & r.last` (`:370-371`). A multicast beat would decrement **one** of 128
counters and **strand the other 15 forever** ⇒ `lookup_mst_select_occupied_o` stuck ⇒ every future AR
from those tiles blocked (`:325-326`).

Fix (with SV default port values so the other ~10 instantiation sites are untouched):

```systemverilog
// axi_demux_id_counters
assign pop_en = pop_mask_i | ((pop_i) ? (1 << pop_axi_id_i) : '0);
// axi_demux_simple, gen_ar_id_counter
wire         r_hs = slv_resp_o.r_valid & slv_req_i.r_ready & slv_resp_o.r.last;
wire [127:0] pm   = r_hs ? mst_r_pop_mask_i[r_idx] : '0;
.pop_mask_i(pm), .pop_i(r_hs & ~|pm)          // suppress the single pop when masked
```

**Do NOT "fix" this with `UniqueIds = 1'b1`.** The per-id port lock is load-bearing: the core SoC port
issues multi-outstanding reads with `ar.id='0`, and `snitch_read_only_cache.sv:161-177` can route two
same-id reads to *different* master ports (Bypass on `ar.lock`, `BURST_WRAP`, sub-width bursts, or
`enable_i=0`).

### 3.5 Pending-entry release — unchanged

`rsp_ready_q` still fires exactly **once**, when `resid_set` is empty after phase A, whatever mix of A
and B beats occurred. That single handshake drives `rsp_ready_o` → `in_rsp_ready_i` → `pop_enable`
(`handler:328`) → `pending_clr` (`:111`), and `miss_in_flight_q &= ~in_rsp_id_o` (`:167`).

### 3.6 Backpressure summary

| Interface | Behaviour |
|---|---|
| tile port *p* | fully legal single-master AXI R stream; `valid` drops only after **its own** `ready` |
| group mux spill `ready_i` | `~\|(r_pend & ~slv_r_readies)` — pops when the residual empties |
| group mux `mst_req_o.r_ready` | **unchanged** (spill `ready_o`, register-only). The RO cache is *not* combinationally back-pressured, and the 17-way tree does not back-propagate into the cache |
| Bypass / DMA R | still shares the demux `rr_arb_tree`; HOL-blocked for the drain = **~1 cycle instead of ~16** (strict improvement) |

---

## 4. Cost

Estimated from cell counts — **not synthesized**.

| Item | Flops | Comb. |
|---|---|---|
| 512-bit R datapath fan-out | 0 | **0** — already in the netlist (`axi_mux.sv:446`) |
| `axi_mux_mcast`: `acc_q` | 17 FF | — |
| `axi_mux_mcast`: mask in R spill (2 slots × 17 b) | 34 FF | — |
| `axi_mux_mcast`: `r_target`/`r_pend`/`r_pop` | 0 | ~90 cells |
| `snitch_axi_to_cache`: mask/scatter/residue | 0 | ~60 cells (112/128 bits fold away) |
| `axi_demux_id_counters` pop mask | 0 | ~50 cells |
| **per group** | **51 FF** | **~200 cells ≈ 0.6-0.9 kGE** |
| **×16 groups** | 816 FF | **≈ 10-15 kGE** |

For scale: the R spill in that same `axi_mux` is ~1046 FF ≈ 6 kGE, so the whole feature is under 1/5
of the register it sits next to.

**Timing.** The *valid* path gets **shorter and lower-fanout** (2 levels off flops, fanout ≈2/bit, vs
today's 5-bit `switch_r_id` broadcast into a 17-way decoder + 17:1 mux). The one honest new item is
`r_pop` fan-in: `ready_i` of the group R spill now depends on all 17 slave `r_ready`s instead of one
selected one — but `slv_r_readies` is *already* a 17-bit bus into this mux (`:461`), it is a fan-in
change on an existing net, and `r_target` **replaces** the 17:1 mux rather than stacking on it.
Mitigation if it misses: pipeline `r_pop` and accept a 1-cycle bubble between multicast beats — still
14 cycles better than today, and the residual form is correctness-robust to a stale not-ready (costs a
cycle, never a beat).

---

## 5. Expected benefit, and the measurement gate

The staircase contributes a mean of `(N-1)/2 = 7.5` cycles at N=16 (and **15 to the last tile**),
i.e. **14-26 % of a merged miss's 29-55-cycle stall**. Instruction fetch is 10-23 % of wall clock ⇒
**upper bound ~2-5 %, realistic 1-3 %**, since only the merged fraction benefits.

Plausibly larger second-order effects: the RO cache's R port and its 16 pending entries are freed ~15
cycles earlier per merged miss; the **group-wide AR freeze** (§1) is removed; Bypass/DMA HOL-blocking
drops 16 → ~1 cycle; and a *deterministic* per-group skew (tile 15 always last) that compounds into
barrier wait in SPMD code disappears.

### ⚠ Measure before believing

`sp-fmatmul-opt-burst-merge/main.c:71-85` defines `ICACHE_WARMUP 1`, and `:351-369` runs a clamped-N
pass **before the timer** — the timed loop runs with a warm I$. **Any A/B of this feature on the
current app measures ≈ nothing.** Build with `-DICACHE_WARMUP=0`.

**Go/no-go probe (do this first):** a `[ROC]` counter block in `snitch_axi_to_cache.sv` —
`$countones(rsp_in_q.id)` **merge-degree histogram** at each response, `drain_cycles`, and
`ar_blocked_during_drain`. **If the histogram mass sits at 1-2, do not build this.** (Precedent: the
`hold-the-fetch` result in this tree — a plausible second-order effect optimized before the
first-order one was measured, net-negative.)

Also wire up `icache_events_o`, currently discarded at `mempool_tile.sv:391` — it gives the **L0 miss
rate**, the multiplier that converts "cycles saved per miss" into wall clock. Both probes are needed;
neither alone is sufficient.

### Cheaper things to do first (ranked)

The multicast attacks the **15-cycle tail**. The **29-55-cycle miss itself × miss count** is 2-4×
bigger and is attacked by capacity, one line each:

1. **Grow the per-tile L1 I$** — `mempool_pkg.sv:207-209`; today **2 KiB** = 64 lines of 32 B *per
   core*. ⚠ Raise `ICacheSizeByte` / `ICacheSets`, **not** `ICacheLineWidth`: past 512 b it flips
   `BeatsPerRefill` to 2 and disables R-MCAST by the §3.1 guard.
2. **Grow the group RO cache** — `mempool_pkg.sv:216-217`; today **8 KiB** / 128 lines shared by 17
   masters, serving a 16 KiB cacheable window (≈2× oversubscribed, so misses recur all run).
3. `MaxTrans 16 → 32` (`axi_hier_interco.sv:235`) **iff** the `[ROC]` probe shows `free==0` stalls.
4. R-MCAST.

### Explicitly rejected

- **Rotating the `lzc` priority.** Skew does **not** compound: because miss latency L (29-55) > N (16),
  every tile re-merges into the same next fill, so completion is `T_k + t`, not `T_k + t·k`. Rotation
  only changes *who* is last; someone always is and the barrier still waits 15 cycles. Costs ~2 kGE
  and ~7 logic levels (barrel rotate) in front of the 128-bit lzc for ≈0 cycles.
- **Deepening the response spill 2 → 4.** `spill_register` is strictly in-order; a 16-beat drain still
  freezes. +1282 FF for a partial mitigation, strictly dominated by R-MCAST.
- **A separate drain-slot / decoupled multicast buffer.** Concedes the tail is irreducible, its
  round-robin **doubles** worst-case drain to 2R (worse tail latency — the metric that matters), and
  review found independent fatal bugs in its wait-state handling.
- **Editing the shared `hardware/deps/axi/src/axi_mux.sv` in place** — ~8 instantiation sites including
  every tile.

---

## 6. Implementation

### 6.1 File-by-file

| # | File | Change |
|---|---|---|
| 1 | `config/config.mk` | `ro_cache_r_multicast ?= 0` — **must default here**, not in a flavor `.mk`, or `-DRO_CACHE_R_MCAST=` expands empty and breaks vlog on the other configs |
| 2 | `hardware/Makefile` | `vlog_defs += -DRO_CACHE_R_MCAST=$(ro_cache_r_multicast)` |
| 3 | `hardware/src/mempool_pkg.sv` | `ROCacheRMcast`, `ROCacheMcastOk` localparams |
| 4 | `hardware/src/axi_mux_mcast.sv` (**new**) | project-local `axi_mux` with the R block replaced (§3.3) |
| 5 | `hardware/deps/axi/src/axi_demux_simple.sv` (**patch**) | `pop_mask_i` + R sideband (§3.4) |
| 6 | `hardware/deps/snitch/.../snitch_axi_to_cache.sv` | phase A/B, `ar_noalloc`, `rsp_mcast_mask_o` |
| 7 | `hardware/deps/snitch/.../snitch_read_only_cache.sv` | thread the sideband through |
| 8 | `hardware/src/axi_hier_interco.sv` | thread `McastPortMask`, instantiate `axi_mux_mcast` |
| 9 | `hardware/src/mempool_group.sv` | compute `IcacheSlvMask`, pass it down |

**Provenance:** `hardware/deps/snitch` is a Bender `path:` dep whose files **are git-tracked** → edit in
place and call it out in the PR. `hardware/deps/axi` is **not tracked** → ships as
`hardware/deps/patches/axi.patch`, applied by `make update-deps` (`Makefile:211 git apply
hardware/deps/patches/*`).

### 6.2 Acceptance criteria

1. `ro_cache_r_multicast=0` ⇒ **cycle-identical** to baseline (every new term constant-folds;
   `r_target` degenerates to `1 << switch_r_id`).
2. ON completes `sp-fmatmul` with **zero `[CMS]` warnings**, built `-DICACHE_WARMUP=0`.
3. `[ROC] drain_cycles` and `[BP]` fetch stall drop by the amount the histogram predicted — if not,
   **revert rather than tune**.
4. Directed tests: 16 tiles branch to the same cold line; mixed mask (8 icaches + 1 SoC read on the
   same line, exercising phase B); DMA multi-line read concurrent with a merged miss; `enable_i=0`;
   flush during a held beat.
5. `cd hardware && make lint` — `slv_r_valids` is no longer one-hot, Spyglass may object.

### 6.3 Build gotchas

- `make compile` reports a false `Errors: 0` from a **skipped** vlog after a `.sv`-only edit — always
  `rm -rf build_X` and confirm with `grep -c 'Compiling module <mod>'`.
- SystemVerilog does **not** concatenate adjacent string literals like C (a 2-line `$fwrite` header is
  a `vlog-13069` syntax error).

---

## 7. Provenance

Design produced by an 11-agent workflow: three independent proposals (sideband fork/join, residual
partial-drain, no-AXI-change drain-slot), each adversarially reviewed on two lenses
(correctness/deadlock/AXI-protocol and backend-timing/area realism). **All three were refuted**; this
document is the synthesis that structurally excludes every flaw found. The preceding hierarchy
investigation (17 agents, 11 findings confirmed / 1 refuted) established the measured baseline in §1.

Related: `docs/respbw_paritydrain_design.md` (the data-side analogue — same 1-beat-per-cycle drain
limitation, attacked with parity-pinned dual-port delivery).
