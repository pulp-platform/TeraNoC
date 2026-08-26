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

## ⚠️ RETRACTED: "the request-sent fence never clears"

An earlier version of this file blamed the VLSU request-sent fence — `fence_stall =
(|acc_mem_req_cnt_q)` decremented by a rising-edge pulse that back-to-back mem ops could
coalesce. **That is refuted.** The per-hart `.dasm` trace records *retired* instructions, and the
fence retires normally: on hart `0x202` `sfence.vma` appears 6 times with per-instruction
`stall_tot` of 0x00, 0x23, 0x13c and **0x0a** — ten cycles, not a hang. The counter/pulse shape
mismatch may still be a latent defect, but **it is not what stops these arms.**

Kept as a worked example of a plausible mechanism that fits a summary and dies on the raw trace.

## What IS established: a remote scalar load that never gets a response

**Where the cores stop.** Final *retired* PC across all 1024 harts of `fp32_2048x32x256`:

| harts | last retired PC | instruction | ⇒ blocked on |
|---:|---|---|---|
| 221 | `0x80000294` | `sfence.vma` | `0x80000298` `lw t1, 0(a0)` |
| 221 | `0x80000298` | `lw t1, 0(a0)` | `0x8000029c` `fence.i` |
| 346 | `0x80002604` | `bne` — barrier spin | waiting on the 442 above |
| 65 | — | `wfi` | parked |

`0x80000294`–`0x8000029c` is the barrier-entry sequence inside **`matmul_8xVL`**
(`sfence.vma; lw; fence.i`), confirmed by disassembling `s8_fp32_2048x32x256.elf`.

**The blocking event, from the CMS scoreboard.** Hart `0x202` (group 32, tile 2) has exactly two
`STUCK_REQ` records, and they are **the same request**:

```
cyc=21000 STUCK_REQ g=32 t=2 p=0 hart=0x202 id=0 age=1053 addr=0x00f880c0 R bl=1 beats=0
cyc=33000 STUCK_REQ g=32 t=2 p=0 hart=0x202 id=0 age=1935 addr=0x00f880c0 R bl=1 beats=0
```

Same `id`, same address, `beats=0` throughout, age growing. `p=0` is the shared scalar port and
`addr=0x00f880c0` decodes to **group 0, tile 12** — a remote scalar read. The hart's last
instruction retired at cycle **31,064**, and the second warning at cyc 33,000 carries age 1935,
placing the request's start at ~31,065. **The core issued that load and never got an answer.**

Everything else follows: ~442 cores blocked this way, the 346 at the barrier waiting on them, no
FPU work, links idle rather than stalled, and the machine quiescent from ~cyc 36,000 onward.

**What does NOT explain it.** `mshr_timeout=+0` in **both** the `pre` and `bench` phases, and
`RH STUCK = 0`. So the request is neither timing out nor riding a hold window — the two mechanisms
in `rh_livelock_root_cause.md`. Why the response is lost is **not yet established**; candidates are
a response dropped in the NoC, an MSHR entry that never completes without arming the timeout, or a
request that never reached the MSHR at all.

**Next step that would settle it:** a waveform on one stuck arm following `addr=0x00f880c0` from
the tile port through the group MSHR to the NoC and back — the request is identified precisely
enough (`g=32 t=2 p=0 id=0`) to trace directly.

## Blast radius

| | count |
|---|---:|
| arms hung right now | **17** (16 Questa, 1 VCS) |
| delivered results contaminated | **0** — a hung arm never prints `execution took`, so no published number comes from one |
| at-risk population (`N ≤ 256`) | 163 of 248 |
| of those, completed cleanly | **118** |
| hit rate among settled small-`N` arms | **~11%** |
| arms with `N ≥ 512` ever hung | **0 of 35 settled** |

Quiescence rate by contraction, over the whole manifest:

| `N` | done | livelock | quiescent | rate |
|---:|---:|---:|---:|---:|
| 32 | 29 | 4 | 3 | 8.3% |
| 64 | 30 | 4 | 7 | 17.1% |
| 128 | 32 | 4 | 4 | 10.0% |
| 256 | 27 | 4 | 3 | 8.8% |
| 512 | 19 | 4 | 0 | **0%** |
| 1024 | 12 | 4 | 0 | **0%** |
| 2048 | 4 | 4 | 0 | **0%** |

A hard floor at `N ≥ 512` and a roughly flat ~11% below it: **a race that only becomes reachable
when the contraction is short**, not a size threshold. The 16 small-`N` arms recorded as `livelock`
carry RH ~10^5 and are a different signature.

**Cost of a fix: not estimable yet.** It depends entirely on which of the three candidates above is
true — a timeout that should have armed is a logic fix with essentially no area, whereas a dropped
NoC response could be materially more. Any number quoted before the waveform would be invented.

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
