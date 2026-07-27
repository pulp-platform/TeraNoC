# Spatz core bottleneck analysis + improvement plan (sp-fmatmul)

**Measured on:** `build_3` (2026-07-26), `terapool_spatz4_fpu`, 254 traced cores,
`sp-fmatmul-opt-burst-merge` 256x32x256, matmul = **3959 cycles**.
Config: `group_mshr_num=128`, `ways_per_bank=16`, `bank_hash=3`, `hold_window_single=0`,
`hold_window_burst=63`, `ro_cache_r_multicast=0`.
**Instrument:** the per-Spatz-core tracer (`trace_spatz_{insn,cyc,fplsu}_hart_*.log`) +
`make spatz-trace`. See `[[reference_spatz_trace_analysis]]`-style notes in `WORKLOG.md`.

---

## 1. The picture in one paragraph

Think of each core as a chef (the FPU) and memory as a supply chain. The chef is **busy 72.6%** and
**idle 24.5%**. The pantry is **not** congested — memory bandwidth is only **15% utilised**. Each
delivery (a `vle32` B-row load) takes **109 cycles** but feeds only **64 cycles** of cooking, so the
chef needs **1.7 deliveries in flight** to never go hungry. Only **1.23 are in flight** -- about half
a delivery short, which predicts ~28% idle vs the **24.5%** measured. The chef cannot order far
enough ahead.

**Diagnosis: not bandwidth, not really latency — insufficient memory-level parallelism (MLP).**

---

## 2. The measurements

### 2.1 Stall / occupancy (fleet mean, 254 cores)

```
run   27.9%                FPU busy 72.6%
stall 72.1%                IPU busy  0.1%   (pure-FP kernel)
   vfu    53.6%   <- dominant
   idfull 31.1%
   vlsu   18.5%
   vsldu   0.0%
```
Reasons overlap (every active cause is now listed per cycle; the old priority encoder hid all but
the first — that bug is fixed).

### 2.2 `vfu` stall is mostly REAL COMPUTE, but not entirely

`vfu_stall = ~vfu_req_ready_i`, and `vfu_req_ready_i` is the **VFU operation queue's `ready_o`**
(a 2-entry spill, `spatz_vfu.sv:77-88`) — **not** a "busy computing" flag. The VFU only drains that
queue when `operands_ready` (`:133`), which depends on `vrf_rvalid_i`, which the controller
scoreboard gates while a **pending vector load** is still writing the source register. So
`vfu_stall` legitimately mixes *computing* with *waiting for data*.

Measured split of `vfu`-stall cycles (32 cores, 101,564 cycles):

| during a `vfu` stall | share |
|---|---:|
| FPU producing a result (real compute) | **95.0%** |
| FPU idle (VFU occupied, NOT computing) | **5.0%** |
| ...of those, a load in flight | **100%** |

So ~51 pp of the 53.6% is genuine throughput; ~2.7 pp is hidden memory wait.

### 2.3 What the FPU is actually waiting for (the key table)

FPU idle = **24.5%** of traced cycles. Cause breakdown:

| during FPU-idle | of idle | of traced |
|---|---:|---:|
| **a LOAD is in flight (waiting for data)** | **49.8%** | 12.2% |
| **VLSU won't accept the next load** | **39.8%** | 9.7% |
| other | 9.8% | 2.4% |
| window full (`idfull`), no load active | 0.1% | 0.0% |
| nothing in flight at all | 0.5% | 0.1% |

**~90% of FPU idle is memory-shaped.** Note `idfull` is ~never the *direct* cause of FPU idle even
though it is 31% of the stall histogram — it blocks the *issue stage*, by which time the FPU usually
still has work. It is an **enabler**, not the immediate stall.

### 2.4 Bandwidth is NOT the constraint

| per core | value |
|---|---|
| response beats | 901 over ~2950 cyc = **0.31 beats/cycle** |
| VLSU capacity | 2 ports x 1 beat/cyc = **2.0** |
| **utilisation** | **15.3%** (6.5x headroom) |

### 2.5 Latency, concurrency, and the compute floor

| | value |
|---|---|
| VLE latency (issue -> retire) | **109 cyc** median (104-120) |
| **avg vector loads in flight** | **1.23** |
| window depth / VLSU mem ports | 4 / 2 |
| FMA work fed by one load | 8 FMAs x **8 cyc THROUGHPUT** = **64 cyc** (NOT 8x18: `active`=18 is in-flight time incl. pipeline tail, and FMAs OVERLAP) |
| FPU floor (255 FMAs x vl32/4FPU = x8) | **2040 cyc** |
| traced span | **2952 cyc** -> floor is **69%**; measured busy **72.6%** |

**Little's law (corrected):** required concurrency = latency / work-per-load = **109 / 64 = 1.70**
loads in flight. We have **1.23**. Predicted FPU idle = 1 - 1.23/1.70 = **28%**; measured **24.5%** --
**the model fits**. So the latency is NOT covered: we are ~0.5 loads short of hiding it.
(An earlier note said 144 cyc of work per load and therefore 0.76 sufficed -- that used the
in-flight `active` time instead of VFU throughput and was WRONG.)

---

## 3. Recommendations

### 3.1 SOFTWARE (try first — no RTL, fastest turnaround)

**S1. Increase work per load: raise LMUL (vl 32 -> 64).**
Today `e32, m2` => `vl=32`, so one `vfmadd` ~ 18 cycles of FPU work. `m4` => `vl=64` doubles the work
each instruction represents:
* per-load FPU work goes 64 -> **128 cyc**, so required concurrency drops 1.70 -> **0.85** -- i.e.
  the CURRENT 1.23 loads in flight would already be enough;
* **half as many instructions** => much less pressure on the 4-deep window (helps H2 for free).
*Caveat:* LMUL=4 halves the usable architectural vector registers. The 8xVL kernel already spends
many on C accumulators, so this likely means dropping to **4 accumulators** (4xVL with m4). Net
arithmetic intensity per load stays similar; the win is fewer, longer instructions.

**S2. Software-pipeline one iteration deeper (triple buffer).**
The kernel already double-buffers B rows (`v18`/`v20`, `kernel/sp-fmatmul.c:186,211,239`) -- it
issues load *n+1* before the 8 FMAs on row *n*. That yields the measured 1.23 in flight, but 1.70 is
needed. Adding a THIRD buffer (`v22`, free at LMUL=2) and issuing load *n+2* targets exactly that
gap. Costs no RTL. Risk: if the VLSU refuses the extra outstanding op (the 39.8% 'VLSU not ready'),
the third buffer buys nothing and H1 is required -- which is itself a useful, cheap experiment.

**S3. Do NOT add barriers / do not try to align cores.** Measured net-negative **three times**
(per-step barrier 3940 vs 3836; hold-the-fetch W-sweep; icache R-MCAST +5%).
**Lesson: capacity/occupancy is first-order here, skew is second-order, and anything that converts
skew into occupancy loses.**

**S4. For honest measurement, build with `-DICACHE_WARMUP=0`.** The warm-up pass runs before the
timer, so instruction-fetch cost (10-23% of wall clock) is invisible in every published number.

### 3.2 HARDWARE (after the software experiments)

**H1. Two vector memory instructions in flight (roadmap A+C) — highest value.**
Re-key `mem_spatz_req_ready` from "previous op is DONE" to "previous op's requests are all ISSUED",
so a second load starts while the first is still returning.
* Attacks the **39.8%** "VLSU won't accept the next load" directly — the largest actionable slice.
* The software *already* double-buffers, so the intent to overlap exists; the hardware refuses.
* Roadmap models ~2350 cycles.

**H2. Deepen the vector instruction window (`NrParallelInstructions` 4 -> 6/8).**
Window full 31% of cycles. **Do it WITH H1, not instead of it** — the data shows `idfull` is an
enabler, not the direct stall.

**H3. Capacity-aware MSHR hold abort (robustness, not speed).**
A held entry has no backpressure from free-way count and can starve an allocation that would
otherwise merge — this caused the group-(0,0) runaway. Add `|| bank_ways_full` to `hold_done`
(`mempool_group_mshr.sv:2068-2080`).

### 3.3 Do NOT spend effort on

| | evidence |
|---|---|
| more NoC bandwidth / channels | **15% utilised**, 6.5x headroom |
| icache response multicast (R-MCAST) | measured **+4.9%** slower; 95% of beats are single-requester hits it cannot help |
| more MSHR entries | `overflow = 0` already at num=32 **and** 128 |
| more/faster FPUs | FPU at **72.6%** vs a **69%** floor — not the scarce resource |
| MSHR merge-window tuning for speed | latency is already coverable; merge tuning moves ~0 |

---

## 4. Expected outcome

FPU floor ~2040 cyc of a ~2950-cycle traced region. With loads properly overlapped the traced region
should approach that floor => **~2050-2400 cycles vs 3959 today**, consistent with the roadmap's
2048 FPU wall.

**Order of work:** S1/S2 (days, no RTL) -> H1 (the real fix) -> H2 alongside.

---

## 5. Measurement notes / caveats

* `active` in the insn trace is an **in-flight window**, not exclusive FU occupancy (overlapping
  instructions are both credited). The concurrency, bandwidth and FPU-busy numbers are direct
  measurements; the "8 FMAs per load" figure is structural from the kernel.
* The new `vfu_ins` / `vfu_opr` / `vfu_stl` / `sb_deps` fields (added 2026-07-26) make
  "computing vs waiting for data" a **direct** measurement instead of the `fpu_vld` inference used
  for the table in 2.3. Re-measure with them after the next run.
* Traced span (2952) < matmul cycles (3959): the timed region includes prologue/barrier time outside
  the per-core csr_trace window. Compare like with like.
