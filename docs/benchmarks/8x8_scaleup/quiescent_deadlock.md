# The quiescent deadlock — a third failure class, invisible to both detectors

2026-08-26. **16 running arms (15 Questa, 1 VCS) are completely stopped**, having burned
**687 seat-hours** between them and still holding their seats. None is recorded anywhere, because
neither existing detector can see this class.

## It is NOT the recorded livelock

| | recorded livelock (28 arms) | **quiescent deadlock (16 arms)** |
|---|---|---|
| `RH STUCK` episodes | ~10^5 | **0** |
| FPU utilisation | 0.02–4.6% | **0.00% instantaneous** (cum 0.09–2.74%) |
| `busy` lane-cycles | non-zero | **0 / 4,096,000** |
| `mshr_timeout` | 0 | 0 |
| bank req/resp links | thrashing | **idle** — `hsk=0 stall=0 idle=16000` |
| what the machine is doing | working badly | **nothing at all** |

The livelock class spins: it issues, times out, retries, and burns cycles. This class is
**quiescent** — no handshakes, no stalls, no traffic, every one of the 64 groups at 0.0%.

## Signature

```
[FPU] bench cyc=2398000 util=0.00% cum=0.09% busy=0/4096000 lane-cyc
      grp_max=0.0%(g0) grp_min=0.0%(g0)  mshr_timeout=+0 bankfull_bypass=+0
      core_spread=0/0(g0)  bar_rel=+0 bar_spread=0.0 bar_max=4913
[BP] delta,kind=bank_req,cyc=2399000,hsk=0,stall=0,idle=16000,util=0.0000
```

`bar_rel=+0` with a large `bar_max` says arrivals accumulate at the group barrier and it never
releases. `hsk=0 stall=0` says the links are not blocked — nothing is even being offered.

**How it gets there:** `[CMS WARN] STUCK_REQ` fires in a burst early (26,795 lines on
`fp32_2048x32x256`) and then **stops at cyc≈36,000** while the run continues to cyc 2,399,000. A
burst of stuck requests, then the machine freezes and stays frozen.

⚠️ **`RH = 0` here is a real measurement, not a missing probe.** Checked before concluding: 7
running arms report `rh > 0` (up to 594) and 62 recorded rows have RH > 0 (up to 471,920).

## Why nothing catches it

- **`collect_8x8_results.py`** records a livelock only when `RH STUCK > 1000`. These are at 0, so
  no row is ever written — and the comment on that detector describes exactly the consequence:
  *"With no row here it stays 'pending' forever and the retry loops re-dispatch it indefinitely,
  so the failure is invisible AND self-perpetuating."* True for this class too.
- **`campaign_status.py`** flags WEDGED on `util < 0.5 AND cms > 50000`. Both thresholds miss:
  utilisation runs to **2.74%** and the CMS count is **26,795**. It reports `WEDGED 0`.

## The arms

| arm | node | backend | cum_util | cyc | age (h) |
|---|---|---|---:|---:|---:|
| `fp32_2048x256x128` | larain7 | questa | 0.49% | 1,790,000 | 61.6 |
| `fp32_2048x128x256` | larain13 | questa | 0.47% | 1,900,000 | 61.6 |
| `fp32_512x64x2048` | badile24 | **vcs** | 0.28% | 3,829,000 | 61.5 |
| `fp32_2048x32x1024` | badile20 | questa | 0.51% | 1,782,000 | 59.7 |
| `fp16_512x128x2048` | badile19 | questa | 0.46% | 2,595,000 | 52.0 |
| `fp32_2048x64x128` | badile17 | questa | 0.10% | 2,372,000 | 49.9 |
| `fp32_2048x64x512` | badile35 | questa | 0.41% | 2,173,000 | 48.4 |
| `fp16_1024x64x2048` | badile17 | questa | 0.56% | 1,670,000 | 40.2 |
| `fp16_8192x256x256` | badile15 | questa | 2.74% | 1,449,000 | 40.0 |
| `fp16_512x64x2048` | badile06 | questa | 0.29% | 2,371,000 | 40.0 |
| `fp32_2048x32x512` | badile20 | questa | 0.33% | 1,362,000 | 40.0 |
| `fp32_2048x32x256` | badile32 | questa | 0.09% | 2,390,000 | 40.0 |
| `fp32_2048x256x256` | badile41 | questa | 1.77% | 1,023,000 | 23.5 |
| `fp32_2048x128x128` | badile49 | questa | 0.33% | 1,345,000 | 23.5 |
| `fp32_512x128x2048` | badile01 | questa | 2.67% | 852,000 | 22.7 |
| `fp32_2048x64x1024` | badile06 | questa | 2.46% | 771,000 | 22.7 |

**Shape pattern:** predominantly `M = 2048` with a small contraction (`N = 32–256`), plus fp16
small-`M`/large-`P` (`512x64x2048`, `512x128x2048`, `1024x64x2048`). None of the 16 shapes has a row
in `results.tsv` — this is uncharacterised work, not redundant re-runs.

## ROOT CAUSE (2026-08-26): the request-sent fence never clears

**Where the cores actually are.** Final PC across all 1024 harts of `fp32_2048x32x256`:

| harts | PC | instruction |
|---:|---|---|
| 346 | `0x80002604` | `bne` — group-barrier spin |
| **221** | **`0x80000294`** | **`sfence.vma`** |
| **221** | `0x80000298` | `lw` — the instruction immediately after it |
| 65 | `0x80002620` / `0x80002a84` | `wfi` — parked |
| 33 | `0x80002600` | `amoadd.w` — barrier increment |

`0x80000294` is inside **`matmul_8xVL`** (confirmed by disassembling
`s8_fp32_2048x32x256.elf`). **442 of 1024 cores are stuck on the fence**; the 346 at the barrier
are simply waiting for them.

**`sfence.vma` is not a TLB op in this tree — it is the VLSU request-sent fence.**
`hardware/deps/snitch/src/snitch.sv:894-901`:

```systemverilog
riscv_instr::SFENCE_VMA: begin
  fence_stall = (|acc_mem_req_cnt_q);
end
```

**The counter and its decrement do not have the same shape.**
`snitch.sv:2865-2870` — **+1 per offloaded FP/vector mem op**, **−1 per pulse**:

```systemverilog
if (acc_qdata_rsp_i.loadstore && acc_qready_i && acc_qvalid_o) acc_mem_req_cnt_d += 1;
if (acc_mem_req_sent_i[0]) acc_mem_req_cnt_d -= 1;   // FP-LSU
if (acc_mem_req_sent_i[1]) acc_mem_req_cnt_d -= 1;   // VLSU
```

and the VLSU pulse, `working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv:875-877`, is a **rising-edge
detect on a level**:

```systemverilog
assign mem_req_all_issued   = mem_spatz_req_valid && (&mem_port_req_issued);
`FF(mem_req_all_issued_q, mem_req_all_issued, 1'b0)
assign spatz_mem_req_sent_o = mem_req_all_issued && !mem_req_all_issued_q;
```

The comment at the counter asserts *"Each offload (+1) is balanced by exactly one request-sent
(−1) on its own lane."* **A rising-edge detector cannot honour that.** If two vector mem ops are
offloaded and `mem_req_all_issued` stays continuously high across both — no low cycle in
between — the edge fires **once** for **two** increments. The counter never returns to zero,
`fence_stall` never clears, and the core is parked at that PC for the rest of the simulation.

That matches every observation: no outstanding memory anywhere (CMS silent since cyc 36,000),
no MSHR timeouts, no RH episodes, links idle rather than stalled. **Nothing is pending — the core
is waiting for a decrement that already happened, or never will.**

**Why small `N`.** All 17 quiescent arms have `N ≤ 256`. With a short contraction the vector mem
ops are short and issue back-to-back, so the level has no gap between them and pulses are lost;
with a long contraction each op takes many cycles to issue its beats, the level drops between
instructions, and every offload gets its own edge. 7 healthy arms also have `N ≤ 256`, so this is
a race whose probability rises as `N` falls, not a hard threshold.

⚠️ **Confidence.** The PCs, the disassembly, the fence semantics and both RTL fragments are
**established**. That back-to-back ops actually coalesce the level in these runs is **inferred** —
it fits all the evidence but the definitive proof is a waveform showing `acc_mem_req_cnt_q` stuck
non-zero after two offloads and one pulse. `hardware/deps/snitch/src/snitch.sv` is the **compiled**
snitch (checked against `build_q_8x8/compile.tcl`); `working_dir/spatz/hw/ip/snitch/src/snitch.sv`
is NOT built and its `SFENCE_VMA` is a plain `tlb_flush` — do not read that one.

**Fix direction:** make the VLSU emit one pulse **per completed mem instruction** rather than a
rising edge on a shared level, so every `+1` has its own `-1`. A counter-based handshake on the
VLSU side would be immune to back-to-back coalescing.

## Open

1. **A detector.** Proposed: no `execution took`, `busy=0` on the last bench line, and `bar_rel=+0`
   sustained → record `state=deadlock`, so the arm gets a terminal row and stops being
   re-dispatched. Deliberately does NOT key on RH or CMS, the two the existing detectors use.
2. **Whether to reclaim the 687 seat-hours.** These arms cannot produce a cycle count. Killing
   them is not the "don't kill healthy runs" case — they are provably quiescent — but it is the
   user's call.
3. **Root cause.** Unknown. The early CMS burst then total silence suggests a request that is
   dropped rather than retried, leaving cores blocked forever. Distinct from
   `rh_livelock_root_cause.md`, whose mechanism produces continuous RH episodes.
