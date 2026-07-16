# Bottleneck Report: sp-fmatmul-opt-burst-merge (terapool_spatz4_fpu, 256 cores)

## 0. Headline corrections to the task premise (load-bearing; agreed by 5 of 6 analyzers)

Three stated premises are wrong and are corrected before any accounting:

1. **Dimensions.** Active `data/data_gemm.h` is **M=256, N=32, P=256**, not 128³. (Total FMAs = 256·32·256 = 2²¹ = 128³ *coincidentally*, so the 8192-FMA/core count and 2048-cyc FPU floor survive — but per-core vle count and receive volume do not.)
2. **Kernel variant.** `kernel_size=8` (main.c:241) selects **`matmul_8xVL`** (double-buffers `v18`/`v20`), not the `matmul_2xVL` (`v16`/`v24`) named in the brief. Structure is identical (1 `vle32` + N `vfmacc` per reduction step, B-row reused across 8 output rows), so the analysis carries, but the variant/register names in the brief are incorrect.
3. **"Memory receive at parity with the FPU floor (4096 beats = 2048 cyc)" — REFUTED.** Per-core VLSU load volume is **1024 words** (32 vle × 32 elem, B only; the 256 scalar A `flw` go to the FP-LSU, not the VLSU). At 2-wide that is a **512-cyc receive floor = ¼ of the 2048-cyc FPU floor.** Memory delivery has **~4× headroom**, not parity. The "4096 beats" figure assumed N=128 (128 vle/core); with the real N=32 it collapses 4×. Confirmed independently by Reports 0, 3, 4, 5 and by `single_commit=0`, `req_stall=0`.

### Work-split reconciliation (closes to the instruction; all analyzers agree)
`dim_group = M/16 = 16`; `split_m_count = 16/8 = 2 < 16` → **P-split branch**; `split_p_count = 16/2 = 8`. Each core computes **one 8-row × 32-col C block, inner N=32**. `vsetvli e32, m2` on VLEN=512 → **VL=32 elements (128 B)**, so the p-loop and m-loop each run once; only the n-loop (0..31) iterates. `measure_iterations=1`, warmup precedes the timer → the trace window is exactly one full timed matmul.

Per-core instruction counts (trace-confirmed, Report 3): 32 `vle32`, 8 `vse32`, 248 `vfmacc` + 8 `vfmul` = 256 vector-FMA, 256 `flw`, 31–32 `GBAR_SYNC` (one per n-step).

**This closes every VPERF counter:** `insn_ret=40` = 32 vle + 8 vse; `pair_commit=512` = 32 vle × 16 pairs = 1024 elem at 2-wide; FPU floor 2048 = 256 ops × 8 cyc (32 elem / 4 FPU). The naive "128 vle/core" assumed N=128 and no B-reuse; **REFUTED** — real N=32, B-row reused across kernel_size=8 rows → **32 vle/core**.

---

## 1. Closed cycle accounting of the 4009-cycle kernel

Two independent, internally-consistent decompositions exist. They are **different views** (VLSU-internal occupancy vs. Snitch critical path) and do **not** sum identically; the relationship between them is the central reconciliation (§1.3).

### 1.1 VLSU-occupancy identity (Report 0 — exact, 0/256 violations, window = 3992 cyc)

| Component | Mean cyc | % window | Meaning |
|---|---|---|---|
| pair_commit | 512 | 12.8% | 2-wide beats written to VRF (the useful receive) |
| **wait_beats** | **1510** | **37.8%** | active load, ROB head beat missing (memory not delivered) |
| **no_insn** | **713** | **17.9%** | no commit insn of any kind (inter-instruction bubble) |
| store_active | 590 | 14.8% | vse32 drain (invisible to insn_act/no_insn by counter def) |
| load_resid | 640 | 16.0% | per-insn request→first-beat ramp (~20 cyc/vle, structural constant) |
| vrf_bp | 27 | 0.7% | VRF write backpressure (negligible) |
| **Total** | **3992** | 100% | identity verified 0/256 |

**(wait_beats + no_insn) = 55.7% of every window** is the memory-not-feeding-VLSU time. Their **sum is spatially conserved** (~2150–2285 across all 16 groups) but trades off with NoC hop distance: corner group (1,1) wait=32.4%, far corner (3,3) wait=42.3% — a hop-distance-dependent B-response latency gradient.

### 1.2 Critical-path decomposition (Report 3 — trace, per-hart, vector-op span)

| Component | cyc | Evidence |
|---|---|---|
| FPU floor (busy) | 2048 | 256 vfma × 8 cyc; util 2048/4009 = **51% exact** |
| Steady per-vle exposure | ~480 | vle interval median **79** − FPU/step **64** = +15/vle × 32 |
| Cold-start fill (iv0+iv1) | 135–408 | first two vle intervals; hart-dependent |
| Per-n GBAR_SYNC `fence.i` wait | 217–1111 | 31–32 barriers, one per n-step; strongly core-dependent (skew) |
| Entry ramp + final barrier drain | remainder | outside the vector-op span (2794–3518 cyc); accounts for 4009 − span |

Snitch stall taxonomy corroborates: `stall_acc` (offloading vfmacc to Spatz) = **44–55%** of window; `fence.i` = the per-n barrier rendezvous; `stall_lsu ≈ 0`, `stall_raw ≈ 1%` (A-loads pipelined, NOT serialized — PC-level check shows scalar stalls on ALU address math, not flw).

### 1.3 Reconciling the two views (the one number that does NOT cleanly close)

- **`wait_beats` (1510, VLSU-internal) is largely OVERLAPPED with FPU compute on the VFU.** The VLSU counts a vle as "waiting on beats" from admission to retire, but during that window the Snitch has already offloaded the previous iteration's 8 vfmacc, which run concurrently on the VFU. So `wait_beats` is **occupancy, not critical-path exposure.**
- **The two analyzer camps disagree on how much of `wait_beats` is on the critical path.** Report 5's static Model A assumes **zero** vle-drain / vfmacc overlap → per-vle = max(L+D=117, F=64) = 117, exposed 53/vle, total 1700; it sums to 4009 but only by folding cold-start + barrier + entry/exit into an inflated "per-vle latency." Report 3 **directly measures** the vle interval at **79 cyc**, implying substantial overlap already occurs → steady exposure is only **~15/vle (~480 cyc)**, with the remaining gap coming from cold-start, the per-n barrier, and entry/exit drain.
- **FLAGGED discrepancy:** Report 5's per-iteration 117 cyc is **inconsistent** with Report 3's trace-measured 79 cyc (32×117 = 3744 would exceed the entire measured vector span of 2794–3518). We resolve in favor of the **trace**: steady-state memory exposure is modest (~480 cyc); the bulk of the 4009−2048 ≈ 1960-cyc overhead is **cold-start fill + per-n barrier tax + entry/exit drain**, not steady memory-latency exposure. Report 5's aggregate reconciliation is arithmetically correct but its causal attribution over-weights memory.
- **Minor discrepancies flagged:** the brief cites `wait_beats~1700` / `no_insn~400-600`; Report 0's rigorous per-core **means are 1510 / 713** (wait ranges 1175–1833, no_insn 264–1188). The brief's 1700 is near the per-core max; its 400–600 is below the mean. Use Report 0's means as authoritative.

### 1.4 Volume reconciliation (partial — flagged)
- VLSU B-receive: **1024 words/core**. Plus 256 flw → **1280 core-inbound words/core** expected.
- MSHR-observed remote resp beats: **1425/core** (Report 2). LP `mst_resp`: **1991/core**.
- **All three measured/derived figures are 3–4× below the refuted 4096-beat model.** The ~1425 and ~1991 exceed the 1280 clean expectation (LP taps the tile boundary and counts non-MSHR/local + store-ack + possibly window-edge traffic; MSHR counts only remote-group traffic). **This 1280→1991 gap (~1.5×) does not fully close** but is immaterial to the conclusion: every measurement puts receive volume far below the FPU floor.

---

## 2. Bottleneck ranking (evidence-based)

| Rank | Bottleneck | Evidence | Recoverable? |
|---|---|---|---|
| **1** | **VLSU one-mem-insn serialization** (gates deeper prefetch) | RTL-confirmed (Report 4); `req_stall=0`, `single_commit=0`; resp fabric 80–92% idle (Reports 1,2); wait_beats+no_insn = 56% | Yes — but see §1.3: steady exposure smaller than Model A implies |
| **2** | **Per-n GBAR_SYNC group barrier** (`fence.i` rendezvous, one per reduction step) | Report 3: fence.i = 217–1111 cyc/core, core-dependent = barrier skew; 31–32 episodes | Yes — SW-only |
| **3** | **Cold-start fill + entry/exit drain** | iv1 outlier 184–408 cyc (one-time); load_resid first-vle; vector span < full window | Partial — deeper initial prefetch |
| **4** | *(Ruled out)* NoC / link bandwidth | Peak any channel **36.9%**, resp path 60–92% idle in every window incl. peak (Reports 1,2); barriers byte-identical across all 16 groups, wd_fire=0 | N/A — not a limiter |
| **5** | *(Ruled out)* 2-wide receive bandwidth | `single_commit=0` (always 2-wide, working); 4× headroom over FPU floor | N/A — widening further cannot help |
| — | *(Secondary, non-throughput)* MSHR coalescing under-performs | 1.57 vs ideal 4 cores/line, 42.9% overflow, 46.5% bypass, 13% cache hit (Report 2) | Traffic/pressure lever only — links <37% so not throughput-critical here |

The single genuine congestion point — **BANK_RESP 63% stall_rate** (the new 2-wide ParityDrain read-port conflict at the destination superbank, Report 1) — sits on a 5.3%-offered / 94.7%-idle base and is **off the critical path**.

---

## 3. Hypothesis verdict: "VLSU accepts one memory instruction at a time"

**MECHANISM: CONFIRMED at RTL (definitive, Report 4).** The op-queue is a single `spill_register`; its output `mem_spatz_req` is the *only* active-instruction context. The serializing handshake `mem_spatz_req_ready` (`spatz_vlsu.sv:449` default 0) asserts **only** at `:466-469` on `commit_insn_pop` of the current id, itself gated by `mem_finish_ready` (`:655-658`) = *all request beats issued AND all VRF writes committed AND retired*. So `request(i+1)` starts strictly **after full-completion(i)**; the next vle's request cannot leave before the current vle's responses have fully drained to the VRF. The 32-deep commit FIFO is **dead capacity** (never presented a 2nd instruction while one is active). Chaining is allowed (VLE/vfmacc not in `prevent_chaining`) but **unused** — the double-buffer makes each iteration's vfmacc read the *previous*, already-retired vle.

**CLAIM "request+flight+drain cannot overlap the next vle" — CONFIRMED with one nuance.** The next vle's *request* is fully serialized behind the current's *drain* (RTL). BUT the current vle's flight/drain **does** overlap the *previous* iteration's vfmacc (different unit, the VFU). So per-iteration is not fully serial: the 64-cyc FPU work per step hides most of one vle's latency (interval 79 = 64 + ~15 exposed). The serialization's real cost is **preventing deeper prefetch** (running 2–3 vle ahead to bury cold-start and barrier skew), not fully exposing every vle's latency.

**Net:** the hypothesis correctly identifies the architectural mechanism and the primary structural limiter. It over-states the steady-state magnitude — the kernel's double-buffer already recovers most single-vle overlap; the recoverable win is in cold-start + prefetch depth, coupled with the barrier tax (rank #2).

---

## 4. Design options to close toward the 2048-cyc floor

Ceiling (Report 5): FPU floor 2048 → hard max **1.96×**. Model B (2-in-flight) → ~2350 cyc (**1.71×**); Model C (perfect overlap) → ~2300 (**1.74×**). B≈C because latency (≤117) < 2× FPU spacing (128): just 2 outstanding vle recovers essentially all recoverable memory time; deeper yields <2%.

### Option A — VLSU 2-in-flight request pipelining (RTL) `[primary structural lever]`
- **Mechanism:** decouple request-advance from commit-retire. Re-key `mem_spatz_req_ready` to fire on **`mem_insn_finished`** (all i requests issued, bitmap at `:461-463`) instead of `commit_insn_pop`, so `mem_spatz_req` presents i+1 while i still drains. Keep commit in-order (single-context).
- **Expected gain:** up to **1.71×** (Model B, 4009→~2350) *if* wait_beats is fully on the critical path. Given §1.3 (steady exposure ~480, not 1700), the **realized** VLSU-only gain is likely **smaller** — it mainly buys back cold-start and lets prefetch run ahead; the trace suggests the split between A and B (below) is what reaches ~1.7×. Flag: A-alone gain is bounded above by Model B but probably lands well under it without B.
- **Sketch:** `spatz_vlsu.sv` — change `:449`/`:466-469`; **duplicate request state** `mem_counter_q`/`mem_idx_counter_q` (`:323-335`) and burst-alloc regs `burst_alloc_q`/`burst_len_q`/`burst_alloc_cnt_q`/`burst_base_id_q` (`:582-585`). Commit context (`commit_insn_q` FIFO, `commit_counter_q`) unchanged.
- **Risks:**
  - **HARD BLOCKER:** the burst path is sized so one vle32 consumes the **entire ROB0**. `use_port0_burst_req` requires `vl ≤ NrOutstandingLoads·MemDataWidthB = 32·4 = 128 B` (`:160`); the matmul's vle32 is exactly 128 B = 32 words = all 32 ROB0 slots. **Two bursts cannot co-reside** → Option A additionally requires **Option C**.
  - **TwinROB0 `burst_odd_expected` classifier dependency:** its soundness invariant (`:1631-1633`, `|burst_odd_expected_q |-> !rob_req_id[1]`) rests explicitly on op-queue one-at-a-time serialization. For **two concurrent unit-stride bursts** it holds *trivially* (slot-exact ROB0 ids, disjoint slots, neither asserts ROB1) — **free for this all-unit-stride matmul.** It is load-bearing only for a burst overlapping a *strided/indexed* (ROB1) load, where a native ROB1 id can numerically alias a ROB0 slot with `odd_expected` set → misroute. Fix if mixed traffic is ever needed: add an explicit ROB-target (0/1) bit to the response meta.

### Option C — Enlarge ROB / cap per-vle burst (RTL) `[enabler for A]`
- **Mechanism:** either `NrOutstandingLoads 32→64` (ROB IdWidth 5→6, 64 slots/port) so two 32-word bursts fit, **or** cap per-instruction burst at ≤16 elem so two co-reside in 32 slots.
- **Expected gain:** none alone; unblocks Option A.
- **Sketch:** `spatz.sv:328` instantiation param; ROB sizing `gen_rob` (`:254-305`); the `:160` guard.
- **Risks:** doubling ROB0 doubles the TwinROB0 `burst_odd_expected_q` bitmap and read-port pressure at BANK_RESP (already the one 63%-stall point). Prefer the burst-cap variant if area/BANK_RESP contention is a concern; it keeps ROB depth but two bursts share it.

### Option B — Hoist / coarsen the per-n GBAR_SYNC group barrier (SW) `[cheapest; do first to isolate]`
- **Mechanism:** the kernel inserts a group barrier (sfence.vma + arrive-lw + fence.i) **before every vle** (31 syncs). Hoist it out of the n-loop (one barrier per m-block, or a phase barrier) or replace with a lighter request-sent fence where full rendezvous is unnecessary.
- **Expected gain:** removes the per-n `fence.i` tax (217–1111 cyc/core, Report 3) + the one-time iv1 cold-start rendezvous skew (184–408). Independent of A/C. Order-of-magnitude few-hundred cyc; on the skew-heavy far harts (0xff, +1470 over floor) potentially more.
- **Sketch:** `kernel/sp-fmatmul.c` (matmul_8xVL n-loop, the GBAR_SYNC before each vle) + `runtime.h` `gbar_sync`/`vlsu_fence`.
- **Risks:** the per-step barrier exists to enforce B-line availability / MSHR coalescing windows; hoisting must not break correctness of the double-buffer or the request-sent fence semantics. Validate against the known matmul verify-wedge (`MATMUL_VERIFY=0` path). Low RTL risk — no TwinROB0 interaction.

### Option E — MSHR coalescing tuning (RTL knobs) `[traffic lever, not throughput here]`
- **Mechanism:** cut the 42.9% MSHR overflow / 46.5% bypass by raising `group_mshr_num` or shrinking the response-cache slot pressure (cache holds ~30% of 64 slots for only ~13% hit-rate, starving merge capacity).
- **Expected gain:** ~0 on *this* compute-bound, link-idle kernel (links <37%). Value is at larger problem sizes / higher core counts where NoC pressure rises.
- **Sketch:** `mempool_group_mshr.sv`; config `group_mshr_num`, resp-cache enable.
- **Risks:** low; a tuning study, not a critical-path fix.

### Recommendation order
1. **Option B first** — SW-only, low-risk, no TwinROB0 interaction; it *isolates and removes* the per-n barrier tax and cold-start skew, and lets us re-measure to settle the §1.3 attribution tension (how much of the gap is memory vs. barrier) before touching RTL.
2. **Option A + C together** — the structural memory-overlap lever (C unblocks A). For this all-unit-stride kernel the TwinROB0 classifier is safe as-is; keep the ROB-target-bit fix in reserve for mixed strided/indexed workloads. Prefer the burst-cap variant of C to avoid aggravating BANK_RESP.
3. **Option E** — defer; revisit only if scaling to larger matrices / more cores pushes links toward saturation.

Combined A+C+B target: approach the 1.7–1.9× band toward the 2048-cyc FPU wall; the last few % to the 1.96× ceiling is bounded by the FPU floor itself and is not recoverable by memory or barrier work.

---

## 5. Appendix — measurement infrastructure

**VPERF (spatz_vlsu.sv:1592-1619 counters) — the anchor.** Per-core, identity `win = pair_commit + wait_beats + no_insn + store_active + load_resid + vrf_bp` verified **0/256 violations**. Keep: `insn_ret`, `pair_commit`/`single_commit`, `wait_beats`, `no_insn`, `req_stall`, `vrf_bp`. Semantics that must be remembered: `insn_act` = load-active only (stores excluded), so store drain lands in `load_resid`/`other`, not `no_insn`; `wait_beats` is VLSU *occupancy*, not critical-path exposure (§1.3). Values: `insn_ret=40`, `pair_commit=512`, `single_commit=0`, `req_stall=0` (all constant across 256 cores); `wait_beats` mean 1510 (1175–1833, mesh-graded), `no_insn` mean 713 (264–1188).

**Snitch trace decomposition — indispensable for the critical-path view.** It is the only source that measures the true per-vle interval (79 cyc), the vfmacc cadence (median 8 cyc = full FPU rate when fed), and the per-class stall attribution (stall_acc 44–55%, fence.i as a first-class cost). Without it, the VLSU-counter analyzers over-attribute the gap to memory latency. Keep the per-PC / per-class stall taxonomy.

**BP (tb_noc_bottleneck_profiling) — ruled out NoC as the limiter.** 3-state per-port (hsk/stall/idle). Every stage 79–93% idle; RESP_TILE_BACK peak-window util 24%, stall ≤3.2%. Surfaced the one real congestion point (BANK_RESP 63% stall_rate, the 2-wide ParityDrain port conflict) and proved it off the critical path. Note the 2-port/tile sample — trust the *rates*, not absolute counts.

**LP (link profiling) + [GBAR] + MSHR EnableStats — ruled out bandwidth and barrier-imbalance.** LP: peak any channel 36.9%, resp 60–85% idle; p0/p1 spatial split 50/50 (noc_port_hash balanced). GBAR: arrives==releases==608 byte-identical across all 16 groups, wd_fire=0 → zero structural imbalance, no barrier deadlock (but cumulative only — cannot see per-episode skew; that needed the Snitch trace). MSHR: coalescing at 1.57 vs 4 cores/line, 42.9% overflow, 13% cache hit — a real inefficiency, quantified for Option E, but not throughput-critical.

**What to keep:** VPERF (primary) + Snitch trace (critical-path) are the two that jointly close the accounting and must both be retained — they are the pair that exposed the occupancy-vs-exposure distinction. BP and LP/GBAR/MSHR are the *exclusion* instruments (ruled out NoC/barrier/bandwidth) — keep them running to guard against regressions when Options A/C change the response path. All are QuestaSim-gated on `csr_trace_any_global` and align to the same ~3992–4009-cyc window.

**Unreconciled numbers flagged:** (1) steady per-vle memory exposure — Report 5 model 53/vle vs. Report 3 trace 15/vle (resolved toward trace); (2) per-core resp volume — 1280 clean expectation vs. LP 1991 (~1.5× gap, immaterial to conclusion); (3) brief's wait_beats~1700/no_insn~400-600 vs. Report 0 means 1510/713 (within per-core range, means authoritative).

---

## 6. Addendum (measured 2026-07-14): why coalescing fails — emission skew vs the real merge window

A dedicated [QSKEW] probe logged every remote burst request's arrival at its group MSHR door
(cycle, tile, line, merged/alloc/bypass) during the kernel; 15,360 events = the exact expected
60 remote bursts x 256 cores. Pairing same-line requests (the gbar-paired cores, tile s / s+8,
confirmed by the tile identities):

| pair emission skew | pairs | 2nd-request MERGE | 2nd-request BYPASS |
|---|---|---|---|
| <=8 cyc  | 4152 | **79.4%** | 18.2% |
| 9-16     | 1429 | 46.1% | 27.8% |
| 17-34    | 1231 | 15.5% | 37.9% |
| 35-68    |  218 |  3.7% | 32.6% |
| >40 (missed) | 1296 clusters | ~0 | - |

Median pair skew is 4 cyc (the per-step barrier aligns the bulk), p90=25, 15.6% miss entirely --
the divergence is injected DOWNSTREAM of the rendezvous (residual VLSU drain before the next
vle acceptance under one-insn serialization, plus the 1-id/cycle ROB allocation walk), so no
software barrier can close the tail.

**The effective merge window is ~10-15 cycles, not the nominal ~68**: merging is legal only until
the entry's FIRST beat arrives (`WAIT_RESP && beats_left==burst_len`), and the ParityDrain 2-wide
receive made first beats arrive faster -- the receive speedup itself shrank the coalescing window.

**Capacity is a co-equal killer**: even at <=8 cyc skew, 18.2% of second requests BYPASS on a full
MSHR bank (single-word response-cache entries squat ~30% of ways at 13% hit-rate; 28% of ALL burst
requests bypass). A bypassed request can never merge at any skew.

### Consequences for the option ranking
- **Option D (new, promoted): burst-line response cache.** Extend MSHR_CACHED to full burst
  entries: a fully-drained line parks its 16 words; a late same-line requester HITS the cache and
  is served by a fresh drain -- coalescing-by-cache, timing-independent. Directly removes the
  window constraint that skew + faster receive created. Pairs with a capacity fix (cache-way
  partition or burst-priority eviction) to convert the bypass share too.
- Option B (drop the per-step barrier) is then strictly correct: with timing-independent
  coalescing the barrier's alignment value -> 0 and only its 217-1111 cyc/core cost remains.
- Options A+C (2-in-flight) additionally shrink the skew tail at its source (residual-drain
  variance disappears when acceptance decouples from retire).
