# ROB 64 + H1 dual-load — design & implementation plan

**Status:** DRAFT FOR REVIEW. No RTL written for this plan.
**Goal:** get **two `e32,m2` vector loads (32 ROB ids each = 64) simultaneously resident** in the
VLSU ROB, so the H1 dual-load gate has the ROB room it needs — on the **current m2 kernel**, no
kernel change. **Target:** `terapool_spatz4_fpu`, 256 cores.
**Constraint accepted by user:** a full system-wide `MetaIdWidth` 5→6 widening.

> **FACT** = verified in RTL this session. **PROPOSAL** = design not yet written.
> Produced from an 8-agent audit (4 audits → 2 designs → 2 adversarial reviews).

---

## 1. Why ROB 64, and why full widening (not a hidden 6th bit)

The wall from the MLP work: one `e32,m2` load = 32 words = **all 32 ROB0 ids**, so a second load
has zero room. `NrOutstandingLoads 32→64` gives two m2 loads exactly 64 ids.

**The ROB id is not internal — it is `meta_id`, stamped on every NoC request and response.**

**FACT (audit B): contained-id is UNSOUND.** A 64-deep ROB behind a 5-bit wire `meta_id`
(`meta_id = rob_id[4:0]`) aliases ids 32–63 onto 0–31. The response path disambiguates beats
**only** by `(core_id, meta_id)` — no address, no ordering, no second tag. ROB-64's entire purpose
is 64 simultaneously outstanding beats per core-port, and 64 > 32 is a hard pigeonhole. The group
MSHR even **enforces** `(core, meta_id)` uniqueness at request time (`req_meta_ovlp_map`,
`mempool_group_mshr.sv:437-440`), so contained-id would either serialize H1 to a no-op (remote),
or hang/corrupt on the same-address merge path and the unchecked intra-group local path.

**Decision: full `MetaIdWidth` 5→6.** The user has accepted this. The good news (below) is that it
is mostly automatic.

---

## 2. The headline: the widening is mostly AUTOMATIC

**FACT (audit A): `meta_id` is rooted at exactly ONE place.** `snitch_pkg.sv:16 RobDepth=32` →
`:17 MetaIdWidth=idx_width(RobDepth)=5` → `:36 meta_id_t` → re-exported at `mempool_pkg.sv:293`,
and **every** TCDM struct, both FlooNoC flit metas, and the whole MSHR are typed from it. Changing
`RobDepth 32→64` propagates 5→6 through the entire datapath with **no manual struct edits.**

**FACT: `meta_id` rides the FlooNoC mesh on BOTH directions** — request
(`floo_tcdm_req_meta_t.meta_id`, `mempool_pkg.sv:419`) and response (`floo_tcdm_resp_meta_t`,
`:484`), and all six `floo_router` instances take `flit_t` = those structs
(`mempool_group_floonoc_wrapper.sv:815/841/873/899/930/956`). So **+1 bit widens every physical
mesh link, every router FIFO entry, and both group-boundary interfaces**, per channel per
direction. RTL-automatic, physically real. **PNR re-close on the mesh is required.**

**FACT: NO floogen re-run.** The generated `hardware/generated/floo_terapool_noc_pkg.sv` carries
**no meta_id** (params only), so the fragile floogen step is untouched.

### Only THREE functional must-fix sites survive the widening

| # | site | why | fix |
|---|---|---|---|
| 1 | `spatz_mem_rsp_t.id` is **5 bits today** (`generated/spatz_pkg.sv:304`) | responses for ROB ids 32–63 would silently alias onto 0–31 at `spatz_mempool_cc.sv:291` → wrong ROB slot, **wrong data, no error** | widen to 6 (edit **both** `spatz_pkg.sv.tpl` and `generated/spatz_pkg.sv` — editing one reverts on regen) + elaboration assert |
| 2 | `reorder_buffer.sv` block-window mask uses `BlockWords==NumWords/2` | at `NumWords=64`, `BlockWords=16 = NumWords/4`, the identity **breaks** (assert fires) | generalize to a quarter-decode form, **bit-identical at 32/16**, land as its own commit first |
| 3 | `spatz_vlsu.sv:188` burst admission `vl <= NrOutstandingLoads*4B` | at 64 this becomes `<=256B`, silently admitting **m4** loads → one m4 eats all 64 ids and starves H1 | **KEEP** parameter-scaled (verified safe) and make H1's design point `m2`; documented one-line re-clamp fallback |

Everything else is parameter-derived (`AUTOMATIC`): the full list of ~40 verified sites is in the
audit, including the MSHR meta arithmetic (mod-2^MetaIdWidth wrap-safe), `tcdm_id_remapper`,
`tcdm_burst_expander`, `snitch.sv` zero-extend, and the TB scoreboard (`CMS_MaxId` auto).

**⚠ Do NOT decouple `MetaIdWidth` from `RobDepth`:** `snitch.sv:2815` hardcodes
`$clog2(RobDepth)` as the `data_qid_o` zero-extend bound. One knob moves both.

---

## 3. Design

### 3.1 Knob structure (one knob moves three roots atomically)

```make
# config/terapool_spatz4_fpu.mk
spatz_vlsu_rob_depth ?=      # unset = 32 (bit-identical). 64 = ROB64 + meta_id 6b.
spatz_vlsu_dual_load ?=      # unset = MaxInflight 1 (bit-identical). 2 = H1 runahead.
```
```make
# hardware/Makefile -> vlog_defs -DSPATZ_VLSU_ROB_DEPTH / -DSPATZ_VLSU_DUAL_LOAD
```

The single `spatz_vlsu_rob_depth` knob drives: `snitch_pkg::RobDepth` (meta_id root),
`spatz NrOutstandingLoads` (VLSU ROB root), and `spatz_mem_rsp_t.id` width (the truncation site) —
pinned together by elaboration asserts in `spatz_mempool_cc`.

### 3.2 The width roots (land atomically)

* **`snitch_pkg.sv:16`** (a `hardware/deps` change — PR call-out / patch discipline):
  `localparam RobDepth = `ifdef SPATZ_VLSU_ROB_DEPTH `SPATZ_VLSU_ROB_DEPTH `else 32 `endif;`
* **`spatz.sv`**: add `NrVLSUOutstandingLoads` localparam (same define), pass to `:328`.
* **`spatz_pkg.sv.tpl` + `generated/spatz_pkg.sv`** (both): `MemRspIdWidth` localparam;
  `spatz_mem_rsp_t.id` = `MemRspIdWidth` bits. OFF: `$clog2(32)=5` → bit-identical.
* **`spatz_mempool_cc.sv`**: elaboration tripwires — `$bits(spatz_mem_req[0].id) >= MetaIdWidth`
  and `$bits(spatz_mem_rsp[0].id) == MetaIdWidth`.

### 3.3 ROB mask generalization (standalone first commit, config-independent)

The block-reservation window mask. Split every id `i = {i_hi, i_lo}` at `log2(BlockWords)`:
```
(i - wp) mod NumWords < BlockWords
  <=> (i_hi == wp_hi && i_lo >= wp_lo) || (i_hi == wp_hi+1 && i_lo < wp_lo)
```
At `QSelW==1` (`BlockWords==NumWords/2`, the legacy shape) this reduces **bit-identically** to the
shipped msb-XOR form (proven algebraically: `q=0 → ~(wp4^lt)`, `q=1 → (wp4^lt)`). ~3 levels, ROB0
only, **off the request cone** (only consumers are bookkeeping + an assertion — grep-verified).

### 3.4 H1 gate (every term `Runahead`-gated → knob-off bit-identical)

`MaxInflight` knob; `inflight_q` (2 flops, in `gen_runahead`); `dual_adv` re-keys
`mem_spatz_req_ready` to fire on `mem_req_all_issued` (`:672-687`, already exists, zero new flops)
plus the **cap** `commit_insn_q.id == mem_spatz_req.id` (true iff exactly 1 in flight → caps at 2).
Plus `dual_blk` (request-side blocking of an unsafe younger op) and `opq_hold` (Spatz-id pressure —
**both still required at ROB 64**, they guard control resources that don't scale with ROB capacity).
The `mem_pending` blanket-clear becomes `no_older`-guarded (the FALL_THROUGH FIFO trap).

### 3.5 The positional commit proof survives two co-resident loads

**FACT (audit D): no per-instruction id tagging needed.** Each instruction's ROB0 id interval is
contiguous, address-ordered, exactly `vl/4` words long, and program-ordered, so the commit-counter
boundary and the ring boundary **coincide exactly**. The single commit engine works unchanged when
load A (ids 0–31) and load B (ids 32–63) interleave responses.

---

## 4. The two defects the review found (must-fix)

**FF-1 (will fire in stage S1; sim-fatal):** `BypassTrackWays` is keyed on `SPATZ_VLSU_DUAL_LOAD`,
but **ROB64 alone** breaks its depth-2 premise. The premise (`mempool_group_mshr.sv:489-493`) is
"one instruction in flight × ≤2 bursts"; ROB64's widened clamp admits **one m4 = 4 bursts**.
Sequence: a single m4 load with a full MSHR bank bypasses 4 bursts → the 3rd overflows 2 ways →
the `:1070-1077` assert `$fatal`s. **Fix:** `BypassTrackWays = max(2, RobDepth/MaxBurstWords)` (=4
at ROB64, with or without H1). Proof that 4 suffices: outstanding bypass ways ≤
`floor(RobDepth/MaxBurstWords)` because pops are strictly in-order.

**FF-2 (contained-design only; N/A to full-widen).** Window grant doesn't check the 32 kind bits
are free before overwriting. Only relevant to the alternative design; noted for completeness.

---

## 5. Area & timing

### 5.1 Flop budget (32→64, per core, with R1+R2 ON; ×256 cores)

| item | Δ flops/core |
|---|---:|
| ROB `mem_q` (4 × +32 words × 32b) | **+4096** (90% — THE cost) |
| `valid_q`, ptrs, `status_cnt` (6→7b) | +140 |
| `burst_odd_expected_q` (32→64b) + misc | +44 |
| offset queues (scale to 64) | +268 |
| `tcdm_id_remapper` tables (64 entries) | +608 |
| `id_valid` bitmap (deleted by R1), commit FIFO (R2) | +0 |
| **NET (R1+R2 on)** | **≈ +5150/core = +1.32 MFF chip-wide** |
| (without R1+R2) | ≈ +5830/core = +1.49 MFF |

**R1+R2 become near-mandatory at 64:** R1's saving doubles (256 FF/core), R2 avoids 2160 FF/core —
together they keep ~620 kFF off the chip. Knob-off builds: +0 (bit-identical).

NoC/MSHR: +1 bit per flit on every link/FIFO — negligible in flops (~2–4 kFF chip-wide) but
physically real wire/link area.

### 5.2 Timing (backend re-close required)

**No new critical path** — the VLSU address multiply/add cone (~30–35 levels) is untouched. Two
cones grow ~1 level each, to be timed **together**:
* **commit→VRF cone:** two 64:1 read muxes (`data_o`/`data2_o`) into `vrf_req_d.wdata`.
* **rsp→ROB cone:** doubled write-data fanout, two 6→64 write decoders, and the 64:1
  `burst_odd_expected_q[id]` steering mux.

Control compares (`full_o==64`, `room_block_o<=48`, `id_valid_o` under R1) stay **2-level constant
compares** — the T3 property is preserved (the mask is the only new logic and it's off the request
cone). Mitigations if a cone fails: register `rob_rdata`, bank `mem_q` into two 32-word halves
selected by `id[5]`, or a latch-based RF macro.

---

## 6. Staging (validate ONLY on terapool_spatz4_fpu — the smaller Spatz flavors are boot-broken)

Build discipline **every** step: `rm hardware/build_X/compile.tcl` after any `.sv` edit (make
compile silently skips `vlog` otherwise); confirm with `grep "Compiling module <mod>"` (expect 533
modules, 0 errors). `make -o update-floogen` safe; floo regen NOT needed.

| stage | change | gate |
|---|---|---|
| **S0** | ROB mask generalization ALONE (both knobs unset) | **G0:** LEC old-vs-new at 32/16 + elaborate at 64/16 + directed wrap test (wp 63→0). Cycle-identical to **3589**. **No-go → stop** (the mask is the single point where a width bug becomes silent wrong data) |
| **S1** | ROB64 widening (atomic: roots + mask + cc tripwires; `rob_depth=64`, dual_load unset) | **G1:** width asserts clean, `MetaIdWidth=6` propagates, `MATMUL_VERIFY=1` pass, meta-wrap directed test, **m2 cycles == 3589** (identical request stream — any delta is a bug), m4 functional pass recorded separately |
| **S1b/S1c** | flip `spatz_rob_cnt_idvalid=1`, then `spatz_vlsu_commit_qmin=1` | each own commit, cycle-identical A/B + area report |
| **S2** | H1 (`dual_load=2`) + FF-1 fix | **Step 1 OFF-identity:** LEC/elab-diff vs S1 netlist must be bit-identical. **Step 2 ON, directed tests first (A9 armed FIRST — fence underflow is the hang to watch):** two m2 diff-address; same-core same-address dual load (the MSHR-merge deadlock class the widening fixes); load→store epilogue + strided/tailed successor (`dual_blk` degrade); m4 resident + m2 candidate; force_send corner; gbar_sync after dual loads. **Success:** `c_dual` large, `c_rob0full` LOW, `c_forcesend==0` (pure m2), `[GroupMerge]` flat, `insn_ret` unchanged, A1–A10 silent, 0 `[CMS WARN]`. **A/B: 3589 → S1 (flat) → S2.** |

**GO/NO-GO G2 (keep H1 on):** 0 assertion fires + the cycle delta is real. If `c_dual` is small
the gate is still closed; if `c_rob0full` stays high the mask/clamp is wrong; if `[GroupMerge]`
degrades the widened traffic is fragmenting.

---

## 7. Expected gain, honestly

Baseline **3589** (block-alloc ON, m2). S1 (ROB64 alone) should be **flat** — same request stream,
just more room. S2 (H1) is where the gain lives: B's latency hides under A's commit. The audit's
optimistic estimate is toward the FPU floor (~2040), but the honest framing from the −232 lesson:
the exposed-latency overlap means the *measured* win is likely a fraction of the theoretical ceiling.
Watch `c_waitbeat` reduction (B's latency hidden) as the leading indicator, not the cycle count
alone. Re-measure the baseline at every stage (old numbers are not cycle-comparable across tree
changes).

---

## 8. Deps call-outs and risks

* **`snitch_pkg.sv` is `hardware/deps`** — flag in the PR; follows the patch discipline.
* The widening touches **every mesh link** — PNR re-close is the largest real cost; it is wire
  area, not logic depth (router compute/arbitration untouched).
* `BypassTrackWays` (FF-1) must land in S1, not S2 — ROB64 alone trips it.
* One stale assert (`mempool_group_mshr.sv:183 SpatzNumOutstandingLoads=8`) feeds only a
  commented-out assertion — rebind only if ever re-enabled.
