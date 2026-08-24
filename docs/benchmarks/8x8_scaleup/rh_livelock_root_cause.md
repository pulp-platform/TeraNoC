# The 8×8 RH livelock — root cause

> **MECHANISM CORRECTED 2026-08-24 (evening).** Sections 1–3 below describe the livelock as a
> *cohort target derived from `M` that ignores `P`*, with the missing subscribers explained by
> arrival skew on the **A** operand. **That mechanism is wrong.** The stuck traffic is **B**, not A,
> and the cause is that B cannot form a burst. See **§0** — it supersedes §1–§3. The *predicate*
> in §4a is unchanged and still correct; §0 explains why it has the shape it does.

## 0. The real mechanism — B cannot burst, so it inherits A's merge target

Measured on `fp16_512x64x128` (target 16, 243,240 stuck episodes, 0.23% efficiency):

```
per-core B slice per row = (P / SPLIT_P) x elem_bytes = (128/16) x 2 =  16 bytes
burst threshold          = MSHR_MAX_BURST_WORDS x 4                   =  64 bytes
```

The slice is a quarter of the minimum burst, so **B never bursts**. It falls back to the
word-interleaved path and issues **single-word** requests — which are governed by
`hold_subs_single`, a target derived for the **A** operand.

A and B have opposite sharing degrees within a group:

| operand | shared by | why |
|---|---|---|
| **A** | all 16 cores | every core in the group takes the same `m_start..m_end` (`main.c:302-315`) |
| **B** | **nobody** | each core owns a distinct `p_start..p_end` |

So a 16-way cohort on B is **impossible by construction** — not merely mistimed. The transcript
confirms the stuck set is B:

```
distinct stuck addresses = 4,100   ~=  B = N*P*2/4 =  4,096 words
                                       A = M*N*2/4 = 16,384 words  (barely appears)
```

and every episode is `subs=1/16`, `peers=0`, `byp=0 stl=0` — no other core ever wants that word.

### 0a. The predicate is exactly the burst threshold

Burst is possible iff `(P / SPLIT_P) * elem_bytes >= 64`. Evaluating that per family reproduces
the empirical predicate of §4a **including the fp16/fp32 asymmetry**, which §4a had attributed to
fp16 half-word aliasing. It is simply the 2x element size moving the threshold:

| family | `SPLIT_P` | burst needs | livelock observed |
|---|---:|---|---|
| fp16, M=512 | 16 | **P >= 512** | P <= 256 (12/12) |
| fp32, M=512 | 16 | **P >= 256** | P = 128 (7/7); P=256 healthy |
| fp16, M=1024 | 8 | **P >= 256** | P = 128 (4/4) |
| fp16, M=2048 | 4 | P >= 128 | none — degraded only |

**All 26 recorded livelock arms have `(P/SPLIT_P)*elem_bytes < 64`. Every one.**

### 0b. What to fix

Not a `P` term in the cohort formula. The defect is that **one knob serves two operands with
opposite sharing degrees**, and B silently adopts A's target whenever it cannot burst. Either:

1. gate `hold_subs_single` on whether B will actually burst at this shape, or
2. size the tiling so `(P / SPLIT_P) * elem_bytes >= 64` (the burst floor), or
3. give B its own single-merge target of 1 (bypass) when its slice is sub-burst.

### 0c. What this does NOT explain

The burst failure accounts for the livelock class completely, and for nothing else. Of 127 measured
arms, **125 can burst**; their median efficiency is 36.0%. But **37 of them still sit below 25%**,
and they skew hard to small `N` (N=32: 17 arms, N=64: 9, N=128: 6, N=256: 5). That is a **second,
independent mechanism** — small contraction depth — and no MSHR or burst change addresses it.

---

2026-08-24. **It is not a deadlock, not an RTL bug, and not fp16-specific.** It is a *livelock*
caused by a **software-derived MSHR cohort target that is a function of `M` alone, while whether
the cohort can actually form is governed by `P`.** 17+ arms of the 8×8 campaign — every one with
a high cohort target and a small `P` — spent their entire wall-clock budget at 0.05–4% FPU
utilisation for this reason.

This supersedes the hypothesis in `wedge_zero_timeout.md` §5 ("traffic converging on group 0",
"`peers=0` means no merge partners", "`M = 512` is unexplained correlation"). All three are wrong;
see §6.

---

## 1. The mechanism

`software/runtime/mshr_cfg.h` derives the scalar-load cohort target at **compile time from the
GEMM shape**:

```c
MSHR_D_CPG     = NUM_CORES / NUM_GROUPS,                 // 16 at 8x8
MSHR_D_SPLIT_M = (GEMM_M / NUM_GROUPS) / MSHR_KERNEL_SIZE,
MSHR_D_SPLIT_P = (SPLIT_M > 0 && SPLIT_M < CPG) ? (CPG / SPLIT_M) : 1,
MSHR_D_MERGE   = max(SPLIT_P, SPLIT_M),
MSHR_D_HOLD_SUBS_SINGLE = (SPLIT_P <= 2) ? 1 : min(SPLIT_P, MERGE),
```

At 8×8 with `KERNEL_SIZE=8` this collapses to a pure function of `M`:

| `M` | `SPLIT_M` | `SPLIT_P` | **`hold_subs_single`** |
|---:|---:|---:|---:|
| 512 | 1 | 16 | **16** |
| 1024 | 2 | 8 | **8** |
| 2048 | 4 | 4 | **4** |
| ≥4096 | ≥8 | ≤2 | **1** (bypass) |

Verified against the transcripts: the `subs=n/D` denominator in `[RH STUCK]` is exactly `D` above
for every arm (`512x*` → 16, `1024x*` → 8, `2048x*` → 4, `4096x*`/`8192x*` → no holds at all).

The 8×8 config then makes that target **binding with no bounded escape**:

```make
group_mshr_resp_wait_subs_single ?= 1     # delivery BLOCKED until the target is met
group_mshr_hold_window_single    ?= 0     # no hold window -> no bounded release
group_mshr_serve_timeout         ?= 2047  # the ONLY release path
```

So a scalar remote load that cannot gather `hold_subs_single` co-requesters **waits 2047 cycles,
every time**. `config/terapool_spatz4_fpu_8x8.mk` already warns about this gate — it records a
measured **−25% on `2048x128x128`** (target 4). At target 16 the same gate costs 99.9%.

## 2. The cohort never forms — and nothing is even in flight

Across 187,020 `[RH STUCK]` episodes in one arm:

| field | value | share |
|---|---|---:|
| `byp` / `stl` | **`byp=0 stl=0`** | **100%** |
| `peers` | **0** | **100%** |
| `subs` | 1–5 of 16 | 100% |
| distinct `(group, entry)` | **4096 = 64 groups × 64 entries** | every MSHR entry in the machine |

`byp=0 stl=0` is the decisive field: the probe attributes *any* same-address traffic seen during
the hold, and it saw **none, in any episode, in any arm**. The remaining 11–15 cohort members were
not lost to the bypass path and were not back-pressured — **they never issued**.

4,096 distinct entries with ~46 episodes each also proves this is **not a stuck entry**: entries
enter `RESP_HOLD`, ride out `serve_timeout`, leave, and re-enter, indefinitely. Nothing is
deadlocked; every load simply costs ~2047 cycles instead of ~50.

## 3. `P` is the co-factor, and the formula ignores it

Mean `cum` FPU utilisation, all 8×8 arms with a `[RH STUCK]` sample (n in parentheses):

| `hold_subs_single` \ `P` | 128 | 256 | 512 | 1024 | 2048 |
|---:|---:|---:|---:|---:|---:|
| **4** | 32.9% (4) | 55.7% (2) | — | 66.8% (3) | 81.4% (2) |
| **8** | **7.2%** (5) | 43.4% (3) | 32.6% (1) | — | — |
| **16** | **0.83%** (13) | **1.90%** (6) | 54.2% (1) | 51.2% (9) | 37.7% (7) |

Monotone in both axes. The controlled pair is decisive — **same `M`, same `N`, same derived cohort
target of 16; only `P` differs**:

| arm | `subs` target | `RH STUCK` | `cum` util |
|---|---:|---:|---:|
| `fp16_512x256x128` | 16 | 232,618 | **0.08%** |
| `fp16_512x256x1024` | 16 | **4** | **76.64%** |

**958× utilisation difference from `P` alone.** `MSHR_D_HOLD_SUBS_SINGLE` does not reference
`GEMM_P` at all. Small `P` shortens each core's inner loop, so the 16 cores of a group sweep past
a given A element far apart in time; the arrival skew exceeds `serve_timeout` and the cohort the
formula demands can never assemble.

## 4. Blast radius

Arms with >1000 `RH STUCK` episodes, i.e. running in the livelock regime (snapshot
`rh_livelock_evidence/summary.tsv`, 249 arms):

```
subs=16, P=128 : fp16_512x{128,256,512,1024}x128   fp32_512x{32,128,256,512,1024,2048}x128
subs=16, P=256 : fp16_512x{64,128,256,512,2048}x256
subs=8,  P=128 : fp16_1024x{64,128,512}x128
```

That is ~17 arms confirmed in the snapshot and several more seen live before their transcripts
were overwritten (`fp16_512x32x128`, `fp16_512x32x256`, `fp16_1024x{32,2048}x128`). Utilisation
0.05–4.6%; several burned a full 24 h or 48 h seat and were killed by wall-clock timeout.

**These arms measure the config bug, not the architecture.** Any 8×8 scale-up conclusion drawn
from the `P ≤ 256` region is invalid until they are re-run.

### 4a. The predicate — clean separation, 0 false positives

Grouping every completed arm that produced an `[RH STUCK]` sample by `(precision, target, P)`
separates perfectly: **23 of 23 arms inside the region livelocked, 0 of 26 outside it did.**

| precision | target | `P` | n | mean util | livelocked |
|---|---:|---:|---:|---:|---:|
| fp16 | 16 | 128 | 6 | **0.09%** | **6/6** |
| fp16 | 16 | 256 | 6 | **1.90%** | **6/6** |
| fp16 | 8 | 128 | 4 | **3.11%** | **4/4** |
| fp32 | 16 | 128 | 7 | **1.46%** | **7/7** |
| fp16 | 16 | ≥512 | 8 | 54.4% | 0/8 |
| fp16 | 8 | ≥256 | 4 | 40.7% | 0/4 |
| fp16 | 4 | any | 10 | 55.3% | 0/10 |
| fp32 | 16 | ≥1024 | 9 | 38.1% | 0/9 |
| fp32 | 8 | 128 | 1 | 23.4% | 0/1 |

```
livelock  <=>  (fp16 and target == 16 and P <= 256)
            or (fp32 and target == 16 and P == 128)
            or (fp16 and target ==  8 and P == 128)
```

> **Corrected 2026-08-24.** An earlier version of this line read `target == 16 and P <= 256` for
> *both* precisions, and listed `fp32` target-16 at `P=256` as PREDICTED-livelock. **That
> prediction is falsified.** All five delivered arms in that cell —
> `fp32_512x{32,64,128,256,512}x256` — ran at **24.07–47.77% util with `RH=0`**. It was an
> extrapolation from a cell that had no completed arm at the time; `fp32` needs `P == 128`.
> `fp16` genuinely does fail at `P=256` (6/6), so the precisions differ — consistent with
> `mshr_cfg.h`'s note that two scalar fp16 loads alias one 32-bit word, so `served_cnt` advances
> at twice the rate and the fp16 cohort target is effectively twice as hard to satisfy.

Note the fp16/fp32 asymmetry at target 8 (4/4 vs 0/1) — consistent with `mshr_cfg.h`'s own note
that two scalar fp16 loads alias one 32-bit word, so `served_cnt` advances at twice the rate. The
fp32 side is n=1; do not lean on it.

**As of 2026-08-24 01:30, 23 of the 138 running arms are inside this region.** They will each run
to a 24–48 h wall-clock kill and deliver a number that measures the config bug. (An earlier count
of 25 included the two `fp32` `P=256` arms, now excluded — see the correction above.)

**Detection must key on the `RH STUCK` episode count, not on utilisation.** A `util < 1%` test
misses **13 of the 22** recorded livelocks: they sit at 1.1–4.6% while carrying 10^5 episodes.
Healthy arms are in single digits (`2048x128x128`: 4 episodes at 41% util), so the count separates
cleanly where the utilisation proxy does not. Note also that a livelocked arm can still *complete*
— `fp16_1024x32x128` (0.59%, RH=123,743) and `fp16_512x64x128` (0.23%, RH=243,240) both printed
`execution took` — so "delivered" is not evidence of health either.

## 5. Fix

The derivation guards the *low* end (`SPLIT_P <= 2 -> 1`, with the comment *"NON-MONOTONIC: 1 fine,
2 catastrophic, >=4 fine"*) but has **no guard on the high end and no `P` term**. Options, cheapest
first:

1. **Clamp the target by `P`** in `MSHR_D_HOLD_SUBS_SINGLE` — a cohort of 16 is only reachable when
   each core's per-element residency is long enough to cover the skew. `P` is the term that sets it.
2. **`group_mshr_hold_window_single != 0`** so a short bounded window releases the entry instead of
   the 2047-cycle `serve_timeout`.
3. **`group_mshr_resp_wait_subs_single = 0`** for high-target shapes — delivery stops being gated on
   the subscriber count. The config comments already record this as the safer default.

(1) is the real fix; (2)/(3) are mitigations that do not require re-deriving the formula.

A cheap regression detector, independent of the fix: **`RH STUCK` episode count**. A healthy arm has
single digits (`2048x128x128`: **4** episodes at 41% util); every livelocked arm has 10^5. Add it to
the per-arm scrape.

## 6. What this corrects in `wedge_zero_timeout.md`

- **"`peers=0` means the entry has no merge partners"** — wrong. `peers` counts *duplicate MSHR
  entries* holding the same `(base_addr, tgt_group_id)` (`mempool_group_mshr.sv:2510`). Merge
  partners are counted by `subs`, not `peers`. `peers=0` is the *healthy* state and is 100% of all
  lines in every arm — it carries no information.
- **"traffic converging on group 0"** — wrong; an artefact of sampling ~1,900 of 232,618 lines.
  Over full files the `tgt_g` histogram is a contiguous hot block that differs per arm
  (`fp16_512x32x128` peaks on **g32–g39**, not g0) over a uniform background.
- **"`M = 512` is unexplained correlation, not a cause"** — it *is* causal, but through the software
  derivation above, not through the GEMM: `M=512` is exactly the `M` that yields `hold_subs_single=16`.
- **"dead at ~27k cycles, everything after is a spinning simulator"** — it is crawling, not dead:
  utilisation oscillates 0.0–0.2% and entries cycle in and out of hold ~46 times each.
- **"a wall-clock timeout is the wrong detector"** — still true, and §5 gives a better one.

## 7. The 4095 experiment — VOID, do not cite

> **RETRACTED 2026-08-24 (evening). This experiment did not test what it claimed to.**
> `mempool_group_mshr_cfg`'s `HoldCntHwMax` parameter (default **2047**) was never passed at the
> instantiation, so the CSR write path **refused** every value above 2047 and kept the reset
> default. Widening `MshrCfgHoldCntMax` in the package widened the *storage field*, not the *write
> bound*. **Every s8w4 arm ran at 2047 — identical to its baseline**, which is exactly why "6 of 6
> matched pairs were indistinguishable": they were the same configuration.
>
> The verification could not have caught it: it grepped transcripts for `RANGE`, but
> `MSHR_STATUS_RANGE` is never `$display`ed anywhere in RTL or TB, so that grep can only ever
> return 0. The real observable is software's
> `[MSHR] cfg REJECTED status=0x%x ... MEASUREMENT INVALID` — gate on that.
>
> Fixed in `3756ac13` (wire the bound; 8191/13; prescale 6).
>
> **The conclusion happens to hold for these particular arms anyway, for a better reason:** all 26
> were burst-broken (§0), so no window length can help them. That is why §0 does not depend on
> this experiment — it rests on transcript evidence, not on the s8w4 arms.
>
> A window change must be re-tested on shapes that CAN burst.

### 7-old. What the (void) run recorded

2026-08-24. 26 arms re-run with `serve_timeout` and `hold_window_single` at **4095** instead of
2047, to test whether a longer window lets the cohort assemble. Needed an RTL change, not just a
CSR write: `MshrCfgHoldCntMax/W` were 2047/11 and the CSR path **refuses** anything above the max
(`mempool_group_mshr_cfg.sv` `cnt_ok`, :129), so a 4095 write against the old build kept the reset
default and set the sticky RANGE bit — an arm that looks configured and is not. Widened to 4095/12;
images `build_{vcs,q}_8x8_w4`. Confirmed accepted at runtime: `[MSHRCFG] all 64 groups ENABLED`
with **zero RANGE** on 11 arms.

**It does not help.** Three independent lines, all still mid-flight:

1. **Six of six matched pairs are indistinguishable.** Cumulative utilisation at equal windows past
   benchmark-open: 0.01/0.01, 0.02/0.02, 0.03/0.02, 0.02/0.03, 0.02/0.02, 0.01/0.01 (4095/2047).
   Scatter below the counter's resolution.
2. **The pre-phase costs +36%.** `[MSHRCFG]` at cyc 32,213 vs the baseline's 23,606 on
   `fp16_1024x128x128` — the I$ warm-up runs the same kernel, so its loads pay the longer window too.
3. **Arms cross the livelock threshold anyway**, and that understates it: the RH>1000 threshold was
   calibrated at 2047, and 4095 halves the episode count for identical stalling (§7a).

Which is what §3's arithmetic predicted: at a median inter-arrival of ~2,900 cycles, 4095 moves
expected extra arrivals per window from 0.42 to ~0.84, when a 16-cohort needs 15.

### 7a. The RH count is NOT comparable across hold windows

The probe fires once per hold **episode**, and an episode ends when the entry leaves hold, so the
count scales as `1/hold_duration` for the same stalling. Measured on `fp16_1024x128x128`, first
2800 benchmark cycles: **257 episodes at 2047 vs 73 at 4095 — 3.5x fewer — at an IDENTICAL 0.04%
utilisation.** Read as an improvement that is exactly backwards. RH stays valid *within* one config
(single digits healthy, 10^5 livelocked); across configs rank on cycles and utilisation only.

### 7b. What the arithmetic says to try instead

Lower the target so the observed timing can actually deliver it — the opposite direction:

| target | window needed | window in place |
|---:|---:|---:|
| 2 | ~2,800 | 2,047 |
| 4 | ~8,400 | 2,047 |
| 16 | ~41,800 | 2,047 |

**Target 2 is nearly reachable with the existing 2047**, needs no RTL change and no new image —
`hold_subs_single` is a CSR the software already writes.
