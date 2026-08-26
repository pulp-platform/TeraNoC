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
