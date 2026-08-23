# The zero-timeout wedge — evidence record

> **SUPERSEDED 2026-08-24 — read `rh_livelock_root_cause.md` first.**
> The root cause is now established: a **software-derived MSHR cohort target**
> (`MSHR_D_HOLD_SUBS_SINGLE` in `software/runtime/mshr_cfg.h`) that is a function of `M` alone,
> combined with `resp_wait_subs_single=1` + `hold_window_single=0`, so every scalar remote load
> rides out `serve_timeout=2047` when the cohort cannot form. Whether it can form depends on **`P`**,
> which the formula never references.
> This file is kept for the raw observations. **Section 5's hypothesis is wrong**, and so is the
> reading of `peers` in section 4 — `peers` counts duplicate entries, not merge partners, and is 0
> in 100% of lines in every arm. Corrections are itemised in `rh_livelock_root_cause.md` §6.

2026-08-23. Four 8×8 arms have failed this way: **`fp16_512x256x128`**, **`fp16_512x512x128`**,
`fp16_512x64x256` (earlier, same 4-attempts/0-results pattern), and **`fp32_512x32x128`** — the
last of which shows the mechanism is **not fp16-specific**. Written up for whoever debugs it,
because the arms that produced it are transient — badist overwrites `hardware/s8_<arm>/transcript`
unconditionally, so this file is the durable copy of what the transcripts said.

**It is not the MSHR desync-timeout trap.** That one announces itself with a sustained
`mshr_timeout=+N` as a desynchronised group loses its merge partners and every remote load times out
instead of merging — slow, but it finishes. This one has `mshr_timeout = 0` on **every one of the 64
groups**, for the whole run. Nothing times out; nothing recovers.

---

## 1. The signature

```
[FPU] bench cyc=299000 util=0.09% cum=0.06% busy=3868/4096000 lane-cyc
      grp_max=0.4%(g11) grp_min=0.0%(g1)  mshr_timeout=+0 bankfull_bypass=+0
```

| | `fp16_512x256x128` | `fp16_512x512x128` |
|---|---:|---:|
| ideal cycles (`M·N·P / 8192`) | 2,048 | 4,096 |
| cycles reached before the kill | 495,000 (**241×**) | 485,000 (**118×**) |
| FPU utilisation | 0.07% | 0.07% |
| `mshr_timeout` (all 64 groups) | **0** | **0** |
| `bankfull_bypass` | 0 | 0 |
| `[CMS WARN]` lines | 280,898 | 238,683 |
| `RH STUCK` lines | 232,618 | 207,909 |

Every attempt ran to its wall-clock limit and was killed — `rc=137` "timed out after 172800s" (48 h)
three times, `rc=124` after 86400 s once. No OOM, no wrong image.

## 2. It dies almost immediately, then spins

Utilisation collapses inside the first 30k cycles and never returns:

```
cyc=26000 util=0.08%      <- last sample with any activity (grp_max 5.4% on g0)
cyc=27000 util=0.00%
cyc=28000 util=0.01%
cyc=29000 util=0.00%      <- and so on for the next 460,000 cycles
```

So the run is dead at ~27k cycles; everything after that is a simulator spinning on a stalled design.
**A wall-clock timeout is the wrong detector** — it costs up to 48 h to notice a failure that is
fully visible at cycle 27,000. `util < 0.5%` sustained over a few periods would catch it in minutes.

## 3. What is stuck — the request side

`[CMS WARN] STUCK_REQ` names each inflight core request older than 1000 cycles:

```
[CMS WARN] cyc=3000   STUCK_REQ g=31 t=0 c=0 p=0 hart=0x1f0 id=3 age=1093 addr=0x00141000 R bl=1 beats=0
[CMS WARN] cyc=3000   STUCK_REQ g=31 t=1 c=0 p=0 hart=0x1f1 id=3 age=1092 addr=0x00141000 R bl=1 beats=0
[CMS WARN] cyc=485000 STUCK_REQ g=63 t=5 c=0 p=0 hart=0x3f5 id=2 age=1797 addr=0x000ff824 R bl=1 beats=0
```

- **`R bl=1 beats=0`** — single-beat **reads** that have received **zero** beats.
- **`p=0`** on every one — all on scalar port 0, the shared FP-LSU path, not a VLSU port.
- Many harts pile onto **one address**: `0x00141000` accounts for 1,457 of the sampled warnings, the
  next-commonest addresses ~86 each.

## 4. What is stuck — the MSHR side

```
[RH STUCK] cyc=26309 g=10 e=0 bank=0 addr=0x1040 tgt_g=0 subs=1/16 byp=0 stl=0 peers=0
           bank[inv=0 wait=0 drain=0 hold=4 cached=0]
```

Counting the fields across all sampled `RH STUCK` lines:

| field | dominant value | count |
|---|---|---:|
| `peers` | **0** | 1,901 |
| `subs` | **1/16** | 1,601 |
| `tgt_g` | **0** | 977 |
| `hold` | 4 | 1,004 |
| `hold` | 1 | 860 |

**The entry has no merge partners and one sub-request of sixteen, and it sits in `hold`.**
`byp=0` and `stl=0`, so it is neither bypassing nor back-pressured — it is simply waiting.

## 5. Hypothesis (not established)

An entry allocates against **group 0**, takes one of sixteen sub-request slots, finds **zero peers**
to merge with, and parks in `hold` waiting for a cohort that never forms. The hold/serve timeout that
should release it **never fires** — `mshr_timeout` stays 0 on all 64 groups for 460k cycles — so the
entry never drains, its response never returns, and every later request queues behind it. The
`tgt_g=0` concentration suggests the trigger is traffic converging on group 0.

**What would confirm or kill it:**

1. Read `serve_timeout` / `hold_window_*` as actually elaborated for these arms and check whether the
   counter is even enabled — a timeout that is configured but never counts is a different bug from a
   cohort that never forms.
2. Waveform the first `RH STUCK` at cyc≈26,309, group 10, entry 0, bank 0 — the run is dead by 27k,
   so a short trace covers the whole failure.
3. Decode `0x00141000` and `0x1040` to (group, tile, bank) and check whether the concentration on
   group 0 is a bank-hash artefact of these particular M/N/P.
4. ~~All three arms are fp16 with `M = 512`~~ — **the fp16 link is dead.** A concurrent session's
   stall gate (`scripts/badist/feasibility.py`, `KNOWN_STALL`) records **`fp32_512x32x128` at 0.32%
   utilisation with the same signature**, so the mechanism is **not precision-specific**. `M = 512`
   still holds across all four, but see `KNOWN_ISSUES.md`: completion is 37–50% at every M and there
   is exactly one FAILED fp16 arm in the whole set, so the apparent gradient is campaign progress,
   not a failure rate. Treat `M = 512` as unexplained correlation, not a cause.
5. `fp16_512x64x256` reached **565,122 cycles against ~2,442 expected (231×)** and is ~80× its own
   fp32 twin (7,138) — the widest ratio recorded, and a useful extreme for whoever bisects this.

## 6. Operational handling

Both retry ledgers were capped to stop these burning seats — `resubmit_ledger.json` (`MAXA = 3`) and
`rescue_ledger.json` (`MAX_PER_ARM = 3`). Capping one is a half-fix: the two scripts never consult
each other, and neither sees attempts made by `sim_topup` or by hand. Set both back to 0 when fixed.

The live `fp16_512x512x128` instance on badile24 was killed at 14 h 11 min elapsed, still at 0.09%
utilisation and 73× its ideal cycle count, holding a VCS seat in a pool with zero free.
