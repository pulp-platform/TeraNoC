# Running simulation registry — 2026-08-06

Live record of every simulation in flight, what question it answers, and whether it is
still worth its CPU. **Do not kill a run without checking this first** — each takes hours,
and several are the only instance of their configuration.

All runs are 8×8 / 1024 cores / 64 groups, matmul `sp-fmatmul-opt-burst-merge`
2048×512×512, and all carry the >32-group wake-up fix (commit `45baf9e`).

---

## ELF legend

| ELF | md5 | COLDSTART_GROUP_SYNC | note |
|---|---|---|---|
| `matmul_8x8_fixed.elf` | `f4dc958387be` | **0** — barrier compiled out | control from when the wake-up fix was unvalidated. **Degraded config** — see below. |
| `matmul_8x8_wakefix.elf` | `6ed1a8367ed2` | 1 | first fix, before the 32-span `gwidth` guard |
| `matmul_8x8_wakefix2.elf` | `0cb58f5d1811` | 1 | **current**; both shift guards. Same file as `software/bin/.../sp-fmatmul-opt-burst-merge` |

`COLDSTART=0` is **not neutral**: the group MSHR coalesces loads only, so uncoalesced
vector stores to C drift cores apart and they miss each other's ~68-cycle merge window.
The barrier is worth ~14%. Treat `COLDSTART=0` runs as a degraded arm, never as the
headline.

---

## The runs

| # | dir | req / resp ch | MSHR hold / timeout | ELF (CS) | purpose | keep? |
|---|---|---|---|---|---|---|
| **VCS8** | `build_vcs5` | 0rd+2rdwr / 2 | 255 / 255 | fixed (0) | original baseline; now only the paired control for VCS10 | yes — VCS10 is meaningless without it |
| **VCS9** | `build_vcs6` | 0rd+2rdwr / 2 | 255 / 255 | wakefix (1) | **the reference 1024-core number**; furthest along | **highest value** |
| **VCS10** | `build_e8` | 1rd+1rdwr / 3 | 255 / 255 | fixed (0) | resp A/B in the drifting regime; gave **+38.6%** | yes — already produced a result |
| **VCS12** | `build_e8c1` | 1rd+1rdwr / 3 | 255 / 255 | wakefix2 (1) | same A/B with cores aligned — the trustworthy version | high |
| **VCS11 = TEST A** | `build_h511` | 0rd+2rdwr / 2 | **511 / 511** | wakefix2 (1) | headless twin of the GUI; A-F suite baseline; answers the 511 knobs fastest | high |
| **VCS13 = TEST B** | `build_e511` | 1rd+1rdwr / **3** | 511 / 511 | wakefix2 (1) | A-F suite; B<->C isolates resp 2 vs 3 with req fixed | high |
| **VCS14 = TEST C** | `build_n511` | 1rd+1rdwr / **2** | 511 / 511 | wakefix2 (1) | A-F suite; pairs with B | high |
| **QFPU511** | `build_q511` | 0rd+2rdwr / 2 | 511 / 511 | wakefix2 (1) | Questa-lean cross-check of VCS11 + speed comparison | medium |
| **build_2 GUI** | `build_2` | 0rd+2rdwr / 2 | 511 / 511 | wakefix2 (1) | waveform inspection (user's session) | user's call |
| **hello_world** | `build_f8` | — | — | `hello_8x8.elf` | 1024-core boot validation, 21 h in | lowest — question answered long ago |

---

## Which comparison answers what

**Response channels, request path held constant — the clean test (user's design):**
- **TEST C (VCS14) vs TEST B (VCS13)** — both `1rd+1rdwr`, both 511/511, both COLDSTART=1.
  Only `resp` moves, 2 → 3.
- Supersedes baseline-vs-enhanced, which moved **two** things at once (`rd=0,rdwr=2,resp=2`
  → `rd=1,rdwr=1,resp=3`), so the **+38.6%** from VCS8→VCS10 confounds response count with a
  restructured request path.

**Response channels, older 255 config:** VCS9 vs VCS12 (aligned) and VCS8 vs VCS10
(drifting). The gap between those two A/Bs measures how much core alignment changes the
response-channel answer.

**MSHR hold window 255 → 511:** **VCS9 vs VCS11** — both `resp=2`, both COLDSTART=1, only
the hold/timeout differ. This is the user's original 511 question and it falls out free.
Judge it on `[BFBHASH] bankfull_bypass`, not throughput alone: a prior W-sweep was
net-negative because held entries occupy MSHR ways so later leaders bypass.

**Simulator cross-check + speed:** VCS11 vs QFPU511 — identical config, different
simulators. They were previously cycle-exact on FPU activity, so divergence is signal.
Speed must be compared **phase-matched** (boot simulates far faster than the kernel).

---

## Results so far

- **Wake-up fix validated**: all 64 groups compute; `grp_min` 27.8% on g59 vs 0.0% pinned
  on g32 before. Broken config converged at 30.08% of 1024 cores with g32 at exactly 0.0%
  for 32,000 consecutive cycles.
- **4×4 baseline: 83–95% of FPU peak** (`build_1` 82.9%, `build_3` 94.5%) — recovered from
  existing runs, unaffected by the bug (16 groups never trips it).
- **8×8 is response-path bound**: `bank_resp` stalls 76.7% vs `bank_req` 37.3%, banks 98%
  idle. Doubling working cores bought only ~+5.6% (same-length window) — saturation.
- **resp 2→3 gave +38.6%** (drifting regime, confounded — see above).

## Known instrumentation limits

- `[LP]` link profiling is clamped to two ports (`for (... && p < 2 ...)`, summary arrays
  `[2]`), so **no `resp_ch=3` run has ever reported its third channel's traffic**. The
  per-tile counters are correctly sized (`LP_NumRespPorts`), so the data is collected and
  discarded at aggregation — a ~10-line TB fix, no RTL impact.
- With `resp_ch=3` the slave-side channel hash bins **5/5/6 of 16** → 31.25 / 31.25 /
  **37.5%**. All flit types (scalar and burst beats alike) can reach all channels — the
  selection is gated only on "is this remote" — but the third channel is 20% overloaded.
- `noc_router_remapping=0` in **every** build, so the resp remapping stage
  (`mempool_group_floonoc_wrapper.sv:576`, needs 2 or 3) has never been exercised.

## Untested levers, in rough value order

1. `noc_router_remapping=2` — enables the bypassed resp remapping stage. No RTL change.
2. Fix the `resp_ch=3` hash binning so it divides evenly.
3. Widen the ParityDrain beyond 2 beats (`1+(b&1)` → `1 + (b % (NumRemoteRespPortsPerTile-1))`
   plus the `core_id` retag and TwinROB0 receive side). Real RTL work; targets the
   first-order bottleneck.

---

# A–F channel suite (all at hold_burst=511 / serve_timeout=511, COLDSTART=1, ELF 0cb58f5d1811)

Designed to be mutually comparable: identical MSHR config, identical software, only the
NoC channel split moves.

| test | rd | rdwr | resp | run | dir | notes |
|---|---|---|---|---|---|---|
| **A** | 0 | 2 | 2 | VCS11 | `build_h511` | baseline preset; twin of the build_2 GUI |
| **B** | 1 | 1 | 3 | VCS13 | `build_e511` | `enhanced` preset |
| **C** | 1 | 1 | 2 | VCS14 | `build_n511` | `narrow` preset; C↔B isolates resp 2 vs 3 with req fixed |
| **D** | 0 | 1 | 2 | vcsD | `build_d511` | 1-req control for E/F |
| **E** | 0 | 1 | 3 | vcsE | `build_ee511` | |
| **F** | 0 | 1 | 4 | vcsF | `build_f511` | matches the measured 4:1 resp:req ratio |

## Why D/E/F

Measured on the NoC in the timed region: `mst_req ≈ 27,149` vs `mst_resp ≈ 109,182` per
1000 cycles — **~4:1 resp:req** — yet test A gives them equal channels. The group MSHR
collapses N core requests into one NoC request while the response returns as a full
multi-beat burst, so coalescing *widens* the asymmetry. Requests are the over-provisioned
resource.

## Hash behaviour per config (slave-side channel selection, `mempool_tile.sv`)

| config | req_p | resp_p | branch | hash_width | step | distribution | custom hash |
|---|---|---|---|---|---|---|---|
| A | 3 | 3 | RR (req==resp) | — | — | even | n/a |
| C | 3 | 3 | RR (req==resp) | — | — | even | n/a |
| B | 3 | 4 | hash | 4 | 5 | 31.2 / 31.2 / **37.5** | yes |
| D | 2 | 3 | hash | 3 | 4 | 50 / 50 | **no** → `gen_general_hash` + `$warning` |
| E | 2 | 4 | hash | 4 | 5 | 31.2 / 31.2 / **37.5** | yes |
| **F** | 2 | 5 | hash | 4 | 4 | **25 / 25 / 25 / 25** | yes |

**F is the only config that is both fairly binned and on the custom-hash path**, and it is
the one matching the measured traffic ratio.

**Interpretation caveat for D:** `hash_width` 3 falls off the custom-hash path and triggers
the "performance may degrade" warning, so a weak D result may be a hash artifact rather
than a channel-count effect.

**Risk being tested:** halving req 2→1. The 4:1 ratio suggests headroom, and `bank_req`'s
37% stall was shown to be downstream backpressure from the response path rather than an
independent limit — but that was measured *with* 2 req channels.

## Instrumentation note

D/E/F pick up the **fixed `[LP]` profiler**. It was clamped to 2 ports in four places
(`&& p < 2`, accumulators `[2]`), so any resp_ch>2 run counted the extra channels per-tile
then discarded them at aggregation. It now prints all ports with per-channel shares plus a
live `resp_per_req`. **A, B and C were built before the fix**, so they report only p0/p1 —
B's third channel will not appear in its `[LP]` output.


---

## Status snapshot — 19:19

| run | test | config | state | cyc | bench | cum |
|---|---|---|---|---|---|---|
| VCS11 `build_h511` | **A** | rd0 rdwr2 resp2, 511 | running 10 m | 11,550 | 0 | — |
| VCS13 `build_e511` | **B** | rd1 rdwr1 resp3, 511 | building | — | — | — |
| VCS14 `build_n511` | **C** | rd1 rdwr1 resp2, 511 | building | — | — | — |
| vcsD `build_d511` | **D** | rd0 rdwr1 resp2, 511 | building (32 MB) | — | — | — |
| vcsE `build_ee511` | **E** | rd0 rdwr1 resp3, 511 | building (32 MB) | — | — | — |
| vcsF `build_f511` | **F** | rd0 rdwr1 resp4, 511 | building (32 MB) | — | — | — |
| VCS9 `build_vcs6` | ref | rd0 rdwr2 resp2, 255 | running 5 h 43 m | 97,597 | 44 | 29.00% |
| VCS8 `build_vcs5` | ctrl | same, COLDSTART=0 | running 5 h 45 m | 94,730 | 42 | 28.97% |
| VCS10 `build_e8` | — | rd1 rdwr1 resp3, 255, CS0 | running 2 h 56 m | 70,137 | 12 | **36.62%** |
| VCS12 `build_e8c1` | — | rd1 rdwr1 resp3, 255, CS1 | running 43 m | 36,218 | 0 | — |
| QFPU511 `build_q511` | A (Questa) | rd0 rdwr2 resp2, 511 | running 50 m | 35,000 | 0 | — |
| build_2 GUI | A (waveform) | rd0 rdwr2 resp2, 511 | elaborating 2 h 42 m of ~4 h | — | — | — |
| hello_world `build_f8` | — | boot check | running 22 h 24 m | 1,744,000 | — | 920/1024 |

Notable so far: **VCS10 (resp=3) sits at cum 36.62% vs VCS8/VCS9's ~29%** — the largest
separation yet, though VCS10 is COLDSTART=0 and only 12 bench periods in, so it is not yet
a trustworthy number. VCS12 is the aligned version of the same config and will settle it.


---

## Update 20:05 — all six A–F arms running

| test | rd | rdwr | resp | dir | started | note |
|---|---|---|---|---|---|---|
| A | 0 | 2 | 2 | `build_h511` | 19:09 | |
| B | 1 | 1 | 3 | `build_e511` | 19:33 | |
| C | 1 | 1 | 2 | `build_n511` | 19:46 | |
| D | 0 | 1 | 2 | `build_d511` | 19:58 | fixed `[LP]` profiler |
| E | 0 | 1 | 3 | `build_ee511` | 19:58 | fixed `[LP]` profiler |
| F | 0 | 1 | **4** | `build_f511` | 19:59 | fixed `[LP]` profiler; `resp=4` elaborates fine — no hidden guard |

### CORRECTION: the +38.6% resp=3 result does not survive phase alignment

Per-period util at matched offsets into each run's own timed region:

| offset | VCS8 (resp2/cs0) | VCS9 (resp2/cs1) | VCS10 (resp3/cs0) |
|---|---|---|---|
| 10,000 | 32.27% | 32.44% | 36.00% |
| 14,000 | 34.13% | **36.11%** | 35.32% |
| 16,000 | 33.65% | 31.29% | 34.91% |

**The advantage is 0–11%, not 38%**, and at offset 14,000 resp=2 is ahead. The +38.6% came
from offset 1,000–5,000 — the ramp, where the extra channel helps most because everything
bursts at once. `cum` still shows a gap (36.24 vs 30.80) only because it is a running
average that carries the ramp advantage forward forever.

Current honest reading: **the extra response channel helps materially during the ramp and
only marginally in steady state.** Confirm against VCS12 (resp=3, aligned) and B-vs-C.

This is the third time in this session that a window straddling a phase boundary produced a
misleading result (cumulative `[BYP]` counters; the `cyc>=100000` average in build_2; now
this). **Always align to the phase boundary and compare per-period, never cumulative.**

### CORRECTION: the VCS-vs-Questa 3.32x speed ratio is not stable

```
19:48  VCS11 9.3 / QFPU511 2.8  -> 3.32x
20:03  VCS11 4.3 / QFPU511 2.8  -> 1.54x
```

VCS11 halved while QuestaSim held steady when the VCS sim count went 5 -> 10. Two earlier
measurements landing on 3.32x was partly coincidence. **VCS appears more sensitive to CPU
contention than QuestaSim-lean**; a clean simulator comparison needs a quiet machine.


---

## First empirical NoC channel-fairness data (fixed `[LP]` profiler, 21:5x)

The profiler fix paid off immediately — this is the first per-channel distribution ever
measured on this design.

**TEST E (1rw + 3resp), slave side:**
```
slv_resp = 511249(31.5%) / 508039(31.3%) / 601736(37.1%)
```
Predicted from the binning arithmetic: **31.25 / 31.25 / 37.5%**. Confirmed. The 5/5/6
split of 16 hash values (`hash_binning_step = 16/3 = 5`, integer truncation) is real.

**TEST D (1rw + 2resp), slave side — PREDICTION WAS WRONG:**
```
slv_resp = 1473342(88.6%) / 189766(11.4%)
```
Predicted **50/50 "FAIR"**. Actual **88.6 / 11.4** — D uses roughly 1.1 of its 2 channels.

**Why the prediction failed:** I analysed only the *binning* (`step = 8/2 = 4`, bins 4/4)
and assumed uniformly distributed hash values. D falls to `gen_general_hash`, which takes
raw payload bits:
```systemverilog
assign hash_src0 = bank_resp_payload_raw[0 +: hash_width];
assign hash_src1 = bank_resp_payload_raw[hash_width +: hash_width];
```
Those low payload bits are strongly correlated, so the hash barely varies. **Even binning of
a degenerate hash is still degenerate.** The custom hash exists precisely because it selects
fields that DO vary per response (`meta_id`, `ini_addr`, `src_group_id`, `core_id`).

**Lesson:** hash *fairness* has two independent factors — bin-boundary arithmetic AND input
entropy. Checking only the first gives a confidently wrong answer.

**Consequences:**
- TEST D is far more handicapped than the earlier "may degrade" note suggested; it is
  effectively near-single-channel. Read it as a lower bound only.
- **E vs F is the clean 1-req comparison.**
- The 256 elaboration warnings in D's build log are a real signal, not noise.

**Also confirmed:** `resp_per_req = 3.47` in the timed region, matching the ~4:1 ratio that
motivated the D/E/F design.

**Open:** the master (receiving) side skews differently from the slave side — E shows
38.6/37.7/23.7 and D 82.3/17.7 — so it follows different logic than the slave-side hash.
Worth investigating once the suite lands.

**Cosmetic RTL bug:** the `$warning` in `mempool_tile.sv:609` has a stray comma splitting the
format string, so it prints the next string argument as binary instead of `hash_width`. The
message is useless as printed but the condition it flags is correct.


---

## CORRECTION + the complete response-path mechanism, measured end to end

### Correction: the 88.6/11.4 figure for TEST D was phase-contaminated

**The first `[LP]` delta after the benchmark region opens covers ALL traffic since reset**,
because `lp_*_prev` is still zero at that point — so it is boot+warm-up, not a period
sample. I read it as steady state. Fourth instance of the phase trap in this session.

Steady-state slave-side shares (true per-period deltas):

| test | measured | predicted | verdict |
|---|---|---|---|
| D (2 resp) | 54.8 / 45.2 | 50/50 | roughly right after all |
| E (3 resp) | 32.0 / 31.6 / **36.4** | 31.25 / 31.25 / **37.5** | confirmed |
| **F (4 resp)** | **25.4 / 25.0 / 24.9 / 24.8** | 25 / 25 / 25 / 25 | **confirmed, essentially perfect** |

So the earlier "prediction was WRONG" entry for D is itself withdrawn — the binning analysis
was sound; the measurement was taken over the wrong window. The two-factor lesson (binning
arithmetic AND input entropy) still stands as a caution, but D's generic hash is evidently
adequate in steady state.

### The complete mechanism (this is the important result)

TEST F master side, steady state:
```
mst_resp = 119184(59.4%) / 79699(39.7%) / 802(0.4%) / 836(0.4%)
```

**Channels 3 and 4 carry 0.4% each on the RECEIVING side** — empirical confirmation of the
ParityDrain `1+(beat_offset&1)` hardwiring found earlier by code reading.

End to end:
1. Responses **enter** the NoC fairly spread over all channels (slave-side hash: 25% each on F)
2. They traverse the mesh on N independent per-channel router networks
3. They **exit** to the cores through only **2** ports (ParityDrain: 59/40/0.4/0.4)

**Extra response channels buy mesh bandwidth but hit a 2-wide drain at delivery.** This is
why resp 2->3 showed a large ramp benefit and little steady-state benefit, and it makes
widening the ParityDrain the change that would unlock the rest:

  `1 + (b & 1)` -> `1 + (b % (NumRemoteRespPortsPerTile - 1))`
  plus the matching `core_id` retag and extending the TwinROB0 receive side from 2 to N.

`resp_per_req` confirmed at **4.21 / 4.01 / 3.93** across D/E/F — the ~4:1 ratio that
motivated the 1-req design, now measured in three independent configs.


---

## ROOT CAUSE: why A (rd0+rdwr2) beats C (rd1+rdwr1) — a latent bug at NumCoresPerTile=1

Measured request-channel split, stable across every period:

```
A (rd0+rdwr2):  50% / 50%    balanced
C (rd1+rdwr1):  80% / 20%    locked
B (rd1+rdwr1):  80% / 20%    locked (same)
D/E/F (1rdwr):  100%          single channel
```

`mempool_tile_rw_demux.sv` takes different branches:

```systemverilog
if ((NumRdRemoteReqPortsPerTile > 0) || (NumWrRemoteReqPortsPerTile > 0)) begin
   // TYPE-BASED -- taken by B and C (rd=1)
   ... ~(wen|amoen) ? (1 + (c % (NumRd + NumRdWr)))     // READ
                    : (1 + NumRd + (c % NumWide));       // WRITE
end else if (NocPortHash[0] && (NumRemoteReqPortsPerTile > 2)) begin
   // ROUND-ROBIN -- taken by A (rd=0, wr=0)
   ... (1 + req_rr_q);       // advances on every handshake
end
```

**A** has `rd=0, wr=0`, so it falls through to **round-robin on `req_rr_q`** — balanced 50/50
regardless of the read/write mix.

**C/B** take the **type-based** branch, whose spreading is `c % N` with `c` = core-index
*within the tile*. **Every Spatz flavour runs `NumCoresPerTile = 1`**, so `c` is always 0:

```
READ  port = 1 + (0 % 2)     = 1     every read  -> port 1
WRITE port = 1 + 1 + (0 % 1) = 2     every write -> port 2
```

**The 80/20 is not a routing imbalance — it IS the workload's read:write ratio**, projected
onto the channels with no spreading at all.

**This is a latent bug, not a design intent.** The `c % N` spreading was written for classic
MemPool with 4 cores/tile, where it genuinely distributes. At 1 core/tile it is a no-op —
the code silently lost its mechanism when the tile shrank to one core.

**Consequences:**
- `narrow` and `enhanced` modes **cannot load-balance requests on any Spatz config**. Their
  second channel helps only insofar as the traffic mix matches the channel mix.
- A load-dominated kernel wants ~80% read-capable channels; the type split gives 50%.
- **B, C, VCS10 and VCS12 all carry this handicap.** Some of what looked like a resp=3
  benefit in those arms was compensation for a request path pinned at 80/20.
- **A and D/E/F are clean** on this axis (round-robin, and single-channel respectively).

**Proposed cheap fix (untested):** route reads by the existing round-robin pointer instead
of the core index — `1 + (req_rr_q % (NumRd + NumRdWr))` — so reads can use *both* the
rd-only and the rdwr channel (legal: rdwr accepts reads). That would tell us whether
narrow/enhanced are genuinely inferior or merely mis-routed.

**Revised reading of the suite:** the meaningful comparison is now **A (2 universal req +
2 resp) vs E (1 universal req + 3 resp)** — the two configs without a structural request
handicap. Currently A 67.7% vs E 60.4% at off8k.


---

## MAJOR CORRECTION: the kernel has two regimes, and everything was measured in the easy one

Around **offset ~32k** into the timed region the kernel enters a substantially harder
regime. In v9 the per-period util falls 33% -> 19% over ~5k cycles and stays there. It is
**not load imbalance**: `grp_max` and `grp_min` fall together (cyc 85k: 38.4/25.3, cyc 90k:
26.8/14.9), so the whole machine slows uniformly.

**The two response configs behave completely differently across the two regimes:**

| run | config | early 12k-28k | HARD 34k-46k |
|---|---|---|---|
| v8 | resp2, CS0 | 34.0% | **20.0%** |
| v10 | resp3, CS0 | 34.3% | **29.1%** |
| v9 | resp2, CS1 | 34.0% | 20.1% |
| v12 | resp3, CS1 | 35.9% | (not there yet) |

Paired, same COLDSTART: **early +1%, hard +46%.**

### What this invalidates

I previously reported, from the VCS9-vs-VCS12 comparison at offsets 4k-16k, that "the
resp=3 benefit is a ramp transient, gone by offset 16,000" and concluded that
`noc_resp_channel_num` **is not the lever** for the scale-up. **That conclusion was wrong.**
It was drawn from a window that stopped at 16k — inside the easy regime, where the configs
genuinely are equivalent. In the hard regime resp=2 collapses to 20% while resp=3 holds at
29%.

The corrected reading: **extra response bandwidth does nothing while the machine is
comfortable and a great deal once the response path saturates** — which is consistent with
the 76% `bank_resp` stall rate, and never was consistent with "no benefit".

### Every A-F number reported so far is from the easy regime

| test | max offset reached | in the hard regime? |
|---|---|---|
| A | 16k | no |
| B | 10k | no |
| C | 14k | no |
| D | 26k | approaching |
| E | 12k | no |
| F | 10k | no |

So the rankings given earlier — "F ~ E", "A leads", "D is starved" — are all measured where
configs differentiate least. They may survive; they are simply not yet evidence.

### Method note

This is the FIFTH time in this session that a windowing choice produced a wrong answer
(cumulative `[BYP]`; the `cyc>=100000` average in build_2; the absolute-cycle "fix made it
slower"; the first `[LP]` delta covering boot; now stopping at offset 16k). The first four
were fixed by aligning to the phase boundary. This one is different in kind: the window was
correctly aligned but **too short to contain the phenomenon**. Aligning is necessary but not
sufficient — the window must also span the regimes that exist.

All comparisons re-armed for offset >= 34k, reporting early and hard side by side.

---

## THE CLEAN RESPONSE-CHANNEL RESULT (B vs C) — supersedes the v9/v12 comparison

B and C differ in **one** variable: `resp` 3 vs 2. Both `rd1+rdwr1` (both measured at the
same 80/20 request split), both 511/511, same ELF.

| offset | C (resp=2) | B (resp=3) | delta |
|---|---|---|---|
| 2,000 | 36.44% | 48.76% | +12.3pp |
| 4,000 | 42.78% | 56.54% | +13.8pp |
| 6,000 | 45.03% | **67.70%** | **+22.7pp** |
| 8,000 | 45.10% | 67.50% | +22.4pp |
| 10,000 | 45.10% | 66.76% | +21.7pp |
| 12,000 | 42.68% | 57.08% | +14.4pp |

**Consistently +34% to +50% relative, in the EASY regime.**

### Why the earlier v9-vs-v12 comparison misled

v9 vs v12 crossed **two** variables: v9 has a balanced 50/50 request path, v12 carries the
80/20 handicap from the `rd1+rdwr1` demux bug. v12's response advantage was cancelled by its
request disadvantage, netting +1-5%. I read that as "response channels don't help in the easy
regime" and then, after seeing the hard-regime data, as "they only help under saturation."

**Both readings were artefacts of a confounded pair.** B vs C holds the request handicap
constant, and the response effect appears cleanly and consistently.

### Corrected, simpler conclusion

- **resp 2 -> 3 is worth roughly +40%**, consistently, not regime-dependent.
- The hard-regime v8/v10 result (+46%) is the *same* effect, visible there because once
  everything is response-bound the request-split confound matters less.
- My earlier claim that `noc_resp_channel_num` "is not the lever" was wrong twice over: once
  from too short a window, once from a confounded pair.

### Method note

The confound was knowable in advance: v9 is `rd0+rdwr2` and v12 is `rd1+rdwr1`, which the
registry already recorded as a 50/50-vs-80/20 difference. I compared them anyway because they
were the runs that happened to be furthest along. **Convenience of available data is not a
reason to accept a confounded comparison** — the user's A-F design existed precisely to avoid
this, and every conclusion drawn from the properly-controlled pairs (B/C, E/F) has held up
while the ones from the convenient pair have not.

---

## HEADLINE RESULT: hold_burst/serve_timeout 255 -> 511 is worth +75% to +170%

v9 (255) vs test A (511). Both `resp2`, both `rd0+rdwr2` (balanced 50/50 request split),
both `COLDSTART=1`. Per-period util at matched offsets:

| offset | v9 (255) | A (511) | delta |
|---|---|---|---|
| 4,000 | 34.02% | 53.33% | +19.3pp |
| 8,000 | 25.17% | **67.74%** | **+42.6pp** |
| 12,000 | 32.44% | 64.08% | +31.6pp |
| 16,000 | 36.11% | 63.89% | +27.8pp |
| 20,000 | 33.38% | **72.97%** | **+39.6pp** |
| 24,000 | 32.83% | 57.18% | +24.4pp |

### Confound check (done before believing it)

- **Define diff between the two builds: exactly two lines** —
  `GROUP_MSHR_HOLD_WINDOW_BURST 255->511` and `GROUP_MSHR_SERVE_TIMEOUT 255->511`.
  Nothing else differs.
- Three RTL files had newer mtimes in the window (`bootrom.sv`,
  `control_registers_reg_pkg.sv`, `control_registers_reg_top.sv`) but **all match git HEAD**
  — regeneration touched the timestamps, not the content (`bootrom.sv` is regenerated per
  build, Makefile:879). No commits touched them in that window.
- ELF differs only in the `gwidth` guard, which is unreachable in this workload
  (single-group barriers, gwidth=1).

### This REVERSES the earlier W-sweep

The prior sweep found hold windows net-negative (3836 -> 3986/4209/4229). That was measured
at **4x4**. Plausible reason for the reversal at 1024 cores: the merge opportunity is far
richer (64 groups issuing shared-B bursts), so a longer hold catches many more subscribers,
while the way-capacity cost that dominated at small scale is amortised across a much larger
MSHR population. **A scale-dependent knob whose sign flips between 4x4 and 8x8.**

### Caveats

1. A has not reached the hard regime (offset ~25k; transition ~32k). v9 falls 33% -> 20%
   there. A would have to fall very far to erase a 2x lead, but it is unverified.
2. `[BFBHASH]` printed nothing in either run, so `bankfull_bypass` could not be checked —
   the *what* is measured, the *why* (way-capacity amortisation) is inferred.

**This is the largest single effect found in the session**, ahead of the response-channel
change (+40%) and the demux bug. It was the user's own change, not something the existing
sweep data would have suggested.

---

## Response-channel question SETTLED — three independent measurements agree

| comparison | what is controlled | early | hard (34-46k) |
|---|---|---|---|
| **B vs C** | req split fixed at 80/20 both arms, 511 config | **+34-50%** at all offsets | (not there yet) |
| v9 vs v12 (CS1) | balanced-vs-80/20 req — CONFOUNDED | +4% | **+44%** |
| v8 vs v10 (CS0) | same confound, no alignment | +1% | **+46%** |

The CS1 and CS0 pairs give **+44% and +46%** — near-identical, so the benefit is
**independent of core alignment**; it is not entangled with the COLDSTART barrier.

**The three now form one coherent picture rather than three conflicting ones:**
- In the easy regime the confounded pairs show ~+1-4%, because the resp=3 arm's 80/20
  request handicap cancels its response advantage.
- In the hard regime everything is response-bound, the request handicap stops mattering,
  and the confounded pairs converge on the same ~+45% that the clean B/C pair shows
  throughout.
- **resp 2 -> 3 is worth roughly +40-45%.** My original "+38.6%" was, by luck, about the
  right magnitude for entirely the wrong reason (it came from a ramp window on a pair that
  moved two variables).

## Session findings ranked by effect

| finding | effect | evidence |
|---|---|---|
| `hold_burst`/`serve_timeout` 255 -> 511 | **+75% to +170%** (possibly ~3.5x in the hard regime) | v9 vs A, define-diff audited, 2 files confirmed content-identical |
| `resp` 2 -> 3 | **+40-45%** | three pairs, two regimes |
| wake-up bug fix | correctness: half the machine idle, half of C never computed | committed `45baf9e`, all 64 groups now compute |
| `rd1+rdwr1` demux `c%N` no-op at 1 core/tile | reads pinned to one port (80/20 vs 50/50) | fixed; B'/C' running for before/after |
| 4th response channel | ~0 | E ~ F; ParityDrain caps delivery at 2 ports (0.4% on ch3/4) |

**Open:** whether test A's 2.2x lead over v9 survives past the ~32k regime transition. A is
at offset 28k and showed a dip-and-recover (72 -> 57 -> 72) where v9 collapsed monotonically.

---

## REFRAME: the "hard regime" is not a kernel phase — it is the 255 hold window failing

Test C (511, resp2) crossing the same offsets where v9 (255, resp2) collapsed:

```
C  (511):  offset 24k-34k:  46.9 48.4 48.2 48.1 48.1 47.5 46.1 44.3 46.5 46.7 47.9
v9 (255):  offset 24k-34k:  32.8 36.6 35.7 35.1 33.4 34.0 33.0 32.4 29.2 24.7 21.2
```

At offset 34k: **C = 47.9%, v9 = 21.2% (2.3x)**, and **C shows no downward trend at all**.

Same workload, same request split (both rd0+rdwr2... note: C is rd1+rdwr1, see caveat
below), same response channels, same alignment. v9 collapses at ~32k; C does not flinch.

**Therefore what was called a "regime transition in the kernel" is better explained as the
255-cycle hold window ceasing to catch merges** once the access pattern shifts, while 511
still does. The kernel does not get harder; the short window stops working.

### Consequences for earlier conclusions

- The response-channel "hard regime" results (v9/v12 +44%, v8/v10 +46%) were all measured on
  **255-config runs**, i.e. in the regime where 255 is failing. Part of what the extra
  response channel bought there was **compensation for the hold-window collapse**, not pure
  response bandwidth. The clean B/C pair (both 511) still shows +34-50%, so the response
  effect is real — but the +44/46% figures are inflated by the 255 breakdown.
- The 511 change looks **better** than the +75-170% reported: it appears to *remove* the
  collapse rather than merely raise throughput.

### Caveat on this comparison

C is `rd1+rdwr1` (80/20 request split) while v9 is `rd0+rdwr2` (50/50). So C is compared
here **despite** carrying the demux handicap and still wins by 2.3x. Test A (511,
rd0+rdwr2, balanced) is the like-for-like partner for v9 and is ~4k cycles from the same
offsets — that is the one to confirm on.

---

## VERDICT (03:07): the 255 hold window collapses; 511 does not

v9 (255) vs test A (511). Identical in every other respect: `rd0+rdwr2 / resp2`,
`COLDSTART=1`, same ELF, define-diff audited to exactly two lines.

| offset | v9 (255) | A (511) | ratio |
|---|---|---|---|
| 28,000 | 33.35% | 72.31% | 2.17x |
| 32,000 | 29.22% | 68.08% | 2.33x |
| 34,000 | 21.16% | 61.59% | 2.91x |
| 36,000 | 19.47% | 59.84% | 3.07x |
| 38,000 | 19.54% | **71.35%** | **3.65x** |

| window | 255 | 511 | ratio |
|---|---|---|---|
| pre-transition 24-31k | 34.1% | 67.5% | **1.98x** |
| post-transition 34-38k | **20.1%** | **63.9%** | **3.17x** |

A dips to ~60% and recovers to 71%; v9 falls to 19.5% and stays there for ~15k cycles.
**The ratio widens through the transition (2.0x -> 3.65x) because 255 collapses and 511
does not.**

### What this settles

The "hard regime" earlier attributed to the kernel is **the 255-cycle hold window failing**
once the access pattern shifts. Same workload, same channels, same alignment -- only the
window differs, and one config is unaffected by what halves the other. Test C (511, and
carrying the 80/20 demux handicap) also sails through the same offsets at a flat ~48%,
independently confirming it.

### Why the earlier W-sweep concluded the opposite

That sweep ran at **4x4**, where the merge opportunity is a quarter the size and
way-capacity pressure dominates the longer hold. At 1024 cores the merge opportunity is
far richer, so the same knob reverses sign. **This is a scale-dependent parameter whose
optimum moves with mesh size** -- a 4x4 result about it does not transfer to 8x8.

### Consequence for the response-channel numbers

The +44/+46% "hard regime" resp2->resp3 figures were all measured on **255** runs, i.e.
inside the window where 255 is failing, so part of what the extra response channel bought
there was compensation for the collapse. The clean B-vs-C pair (both 511) shows **+34-50%**,
which is the figure to trust.

**Open:** whether 1023 (A1023, and the build_4 GUI) improves further or overshoots. The
probe counters (`mshr_timeout`, `bankfull_bypass`) on those runs will show whether a longer
window is still catching merges or just occupying ways.

---

## Unifying observation: utilisation tracks response-beats-per-request

TEST F through a dip and recovery, util and `[LP] resp_per_req` side by side:

| offset | util | resp_per_req |
|---|---|---|
| 34,000 | 58.79% | 4.00 |
| 36,000 | 40.03% | 3.06 |
| 37,000 | 31.37% | **2.80** (trough) |
| 38,000 | 31.39% | 2.99 |
| 39,000 | 36.66% | 3.41 (recovering) |

They move together, and the ratio's recovery **leads** the utilisation recovery. When the
traffic carries ~4 response flits per request the machine runs at ~58%; at 2.8 it runs at
~31%. **The FPUs are fed in direct proportion to how much response bandwidth each request
buys.**

This reframes every result in the session:

- **What helped, helped by keeping resp-beats-per-request high**: longer hold window (more
  subscribers merged onto one request), the 3rd response channel (more beats delivered per
  cycle), balanced request routing (requests not queued behind a starved channel).
- **What did not help, failed for the matching reason**: the 4th response channel cannot be
  drained past the 2-wide ParityDrain, so extra beats have nowhere to go; a single request
  channel starves the request side before responses ever become the limit.

Also note: **F dips but does not collapse** (31% -> 36.7% and rising), unlike v9 at 255
which fell to ~19% and stayed for ~15k cycles. Earlier wording implying F "collapsed" was
premature -- the recovery was simply not yet visible.

### Caveat on the earlier mechanism claim

Two competing readings of a falling `resp_per_req` remain unseparated:
1. bursts genuinely get shorter (workload phase), or
2. the MSHR stops merging, so requests that used to collapse into one now issue separately.

Reading 2 predicts request count RISES; F's requests FELL 16% while responses fell 41%, so
neither reading fits cleanly on its own. The `mshr_timeout` / `bankfull_bypass` counters on
the ^ and P runs are what separate them.

---

## rw-demux fix measured: +17.5%, replicated on two independent pairs

Matched-offset per-period util. Only the `mempool_tile_rw_demux.sv` change differs
(`c % N` -> `(c + req_rr_q) % N`), which takes the request split from 80/20 to 50/50.

| pair | unfixed mean | FIXED mean | gain |
|---|---|---|---|
| **B -> B'** (resp3) | 60.0% | **70.5%** | **+17.5%** |
| **C -> C'** (resp2) | 42.7% | **50.3%** | **+17.6%** |

Two different response-channel counts producing the same +17.5% is strong evidence the
gain is the request rebalancing itself, not something incidental to one config.

**B' peaks at 82.8%** (offset 9k) -- the highest utilisation recorded in the campaign.
Reference: 4x4 reached 96.8%.

Shape detail worth noting: both fixed runs start marginally BEHIND (C' is -1.8pp at offsets
1-2k) and pull ahead from ~4k, widening to +12-15pp. Consistent with the mechanism --
round-robin spreading needs some traffic history before it beats type-pinning, which is
briefly optimal while only one request type is in flight.

### Final ranking of session findings

| finding | effect | evidence |
|---|---|---|
| `hold_burst`/`serve_timeout` 255 -> 511 | **2.0x pre / 3.2x post-transition** | v9 vs A, define-diff audited |
| resp channels 2 -> 3 | **+40%** | B vs C (clean pair) |
| **rw-demux fix** | **+17.5%** | B/B' and C/C', two independent pairs |
| >32-group wake-up bug | correctness -- half the machine idle | committed `45baf9e` |
| 4th response channel | ~0 (slightly negative) | E ~ F; ParityDrain caps delivery at 2 ports |
| 1 request channel (D) | **-48%** vs baseline | D is the only config below the 255 baseline |

Three are configuration choices. **The demux fix is the only one that required finding an
actual RTL defect**, and it originated from the user's observation that tests A and C ought
not to differ for load-dominated traffic -- chasing *why* they did exposed the bug.

---

# 2026-08-07 05:35 — hold-window ladder extended to 2047 (extreme-merge arm)

Six new arms at `group_mshr_hold_window_burst = group_mshr_serve_timeout = 2047`,
completing the ladder **255 -> 511 -> 1023 -> 2047**. Channel arguments copied verbatim
from each `build_?1023/compilevcs.sh`, so the hold window is the only variable.

| arm | req split | resp ch | build dir | log stem |
|---|---|---|---|---|
| `A*` | rd0+rdwr2 | 2 | `build_a2047` | `vcsA2047` |
| `B*` | rd1+rdwr1 | 3 | `build_b2047` | `vcsB2047` |
| `C*` | rd1+rdwr1 | 2 | `build_c2047` | `vcsC2047` |
| `D*` | 1rdwr | 2 | `build_d2047` | `vcsD2047` |
| `E*` | 1rdwr | 3 | `build_e2047` | `vcsE2047` |
| `F*` | 1rdwr | 4 | `build_f2047` | `vcsF2047` |

Launcher `/tmp/claude-620771/vcs_2047.sh` + driver `run_2047_all.sh`. All six at **nice 0**
(the `nohup bash script &` path does not inherit the tool wrapper's nice 5 -- a bare
backgrounded command in a foreground shell does, which is what made an earlier probe of this
report 5).

**Two pre-launch checks, both worth repeating for any future window value:**

1. **2047 does not truncate.** `mempool_group_mshr.sv:216-217` derives
   `HoldCntMax = max(HoldWindowMax, ServeTimeout)` then `HoldCntW = $clog2(HoldCntMax+1)`,
   so `hold_cnt` self-sizes to 11 bits. A wrapped counter would have produced a
   plausible-looking but meaningless run.
2. **The override actually lands.** `terapool_spatz4_fpu_8x8.mk` already defaults both knobs
   to 1023, so `make -n` was used to confirm `GROUP_MSHR_HOLD_WINDOW_BURST=2047` and
   `GROUP_MSHR_SERVE_TIMEOUT=2047` reach `vlog`. The launcher re-checks the defines in the
   built `compilevcs.sh` and **aborts rather than run** if they did not take -- a 1023 run
   wearing a 2047 label is worse than no run.

Machine at launch: 96 CPUs, load 43, 1071 GB RAM available, 20 sims using 163 GB.
Nothing existing was stopped.

## Campaign state at this point

26 runs registered, 16 with benchmark-region data, 20 live. Equal-N ranking (N=48):
`A, B, E, F, C, v12, v10, v9, v8, D`. Live dashboard:
https://claude.ai/code/artifact/0addc571-20b4-4099-aae7-e0617f22147b

**Four corrections landed since the last registry entry** -- all recorded in `WORKLOG.md`
and, where they are reusable method lessons, in `README.md`:

- **A's offset-42k dip is not the epilogue.** `grp_min` collapsing looked diagnostic but
  fires transiently on C, D, E and F with no drain; A recovered. It is a store-heavy phase.
- **The ~40k regime break is the kernel, not a config.** B and E break at offset 39000,
  A at ~42000, across three different request/response configurations.
- **"bypass is nearly absent in the matmul" is retracted.** It read two periods of a signal
  that swings 14x between adjacent periods. Matmul-phase *timeouts* (~4500/1000 cyc vs
  ~231-701 in boot) survive; the way-capacity question is open.
- **COLDSTART is worth ~1% at 8x8, not the ~14% measured at 4x4.** v9/v8 = 1.01x over 134
  equal periods, v12/v10 = 1.00x over 71 -- the two longest series in the sweep.

Plus one methodology fix: **the equal-N window must never shrink.** A newly-qualifying run
dragged N from 40 to 20 and reordered the whole table with no run having changed. The
window now ratchets, and matched pairs (each at its own N) carry the comparisons a
ratcheting window structurally cannot make.

---

# 2026-08-07 20:30 — core-drift / alignment investigation

Prompted by: A and the other barrier-carrying runs never recover utilisation after the
p-iteration boundary, while GB0 (barrier removed) peaks 18 pp higher. Three experiments, in
the order they were run.

## 1. Ablation — is the barrier the problem?

| run | dir | config | started |
|---|---|---|---|
| `GB0` | `build_gbar0` | A cfg 511, `GBAR_PLOOP=0` | 07:53 |

Reuses `build_h511`'s simulator by symlink (RTL identical, only the ELF differs) -- no
rebuild, no extra disk.

**Answered: yes.** GB0 peaks 90.9% vs A's 73.2% all-time best, `cum` 72.4% vs 62.4% = 1.16x.
It is also far more VOLATILE: through a trough it fell 25.3 pp where A fell 8.5, crossing
below A three times while staying ahead cumulatively.

## 2. Broadcast release — is the 16-cycle release staircase the problem?

Eight arms, `build_x*`, started 14:08-14:19. `X-A511N` is the control
(`-DGROUP_BARRIER_BCAST_OFF`); the other seven have the broadcast release active.

| arm | cfg | hold |
|---|---|---|
| X-A511N | A | 511 (control) |
| X-A511 | A | 511 |
| X-A1023 | A | 1023 |
| X-B1023 / X-C1023 / X-E1023 / X-F1023 | B/C/E/F | 1023 |
| X-D2047 | D | 2047 |

**Answered: no.** 8/8 arms bit-identical to their no-fix twins over 69 matched periods, exact
on busy lane-cycles. The RTL fix is correct and provably inert when disabled (X-A511N == A
bit-for-bit), but the staircase is not what costs the 18 pp.

## 3. Alignment probes — how far apart ARE the cores?

| run | dir | config | probes |
|---|---|---|---|
| `P-A511` | `build_pa511` | A 511 | 1+2 |
| `P-A1023` | `build_pa1023` | A 1023 | 1+2 |
| `P-C1023` | `build_pc1023` | C 1023 | 1+2 |
| `P-D1023` | `build_pd1023` | D 1023 | 1+2 |
| **`P-GB0`** | `build_pgb0` | A 511, **barrier ablated** | 1+2 |

Probes (see WORKLOG 2026-08-07 19:xx):
- **1** `mempool_group_barrier.sv`: barrier ARRIVAL SPREAD -- cycles between a struct's first
  and last arrival. Reported as `bar_rel=+N bar_spread=X bar_max=Y`.
- **2** `tb_fpu_util.svh`: intra-group CORE SPREAD from per-core busy FPU-lane-cycles,
  ungated. Reported as `core_spread=avg/worst(gN)`.
- **3** (in source, not in these builds) per-core RETIRED-INSTRUCTION drift, benchmark-gated.

`P-GB0` is the control: barrier ablated, so `bar_rel` must read 0 while `core_spread` still
reports -- separating "cores drift on their own" from "the barrier leaves them drifted". It
reuses `build_pa511`'s simulator by symlink, so it cost no build. **It should have been in the
first probe batch and was not.**

## 4. Inter-group traffic distribution (the batch that targets the actual finding)

| run | dir | varies |
|---|---|---|
| `I-HASH0` | `build_ihash0` | `noc_port_hash=0` (default 7) |
| `I-REMAP2` | `build_iremap2` | `noc_router_remapping=2` (default 0) |

Both A cfg / 1023, so they differ from `P-A1023` in exactly one knob.

**Why these:** the `.dasm` check (WORKLOG 19:40) showed intra-group cores agree to **0.14%**
while GROUPS differ by **4x** -- the imbalance is inter-group, which no barrier controls and
which experiments 1-3 do not target. `noc_port_hash` controls request-port hashing and
response round-robin; `noc_router_remapping=2` enables the response remapping stage that the
8x8 config leaves bypassed. Both change how traffic distributes across the mesh, the plausible
cause of groups diverging.

**Expectation, stated in advance:** probes 1 and 2 are both WITHIN-group instruments and will
most likely report "already aligned", confirming the `.dasm` result rather than explaining the
18 pp. The inter-group arms are the ones that could move it.

All previously running simulations were kept; nothing was stopped for this batch.

### 2026-08-07 23:20 — first inter-group result: noc_port_hash and the DMA phase

Cycle at which the benchmark region opens (SW enables csr_trace, i.e. DMA/
preload complete):

    PGB0     hash=7 (default), matmul_gbar0.elf    57,000
    IREMAP2  hash=7, noc_router_remapping=2        58,000
    IHASH0   hash=0                                still "pre" at 65,000, util 0.01 %

Disabling noc_port_hash lengthens the DMA/preload phase by AT LEAST 12-14 %.
IHASH0 has not opened yet, so that is a lower bound. The arm is healthy --
err=0, and util 0.01 % is correct for a DMA-only phase with idle FPUs.

Plausible: preload streams A and B from L2 into L1 and is the most bandwidth-
saturating part of the run, exactly where spreading requests across NoC ports
should matter. hash=7 enables req-port hash + resp temporal RR + resp spatial
RR; hash=0 disables all three.

Attribution caveat: not perfectly isolated. IREMAP2 also differs in
noc_router_remapping, and PGB0 runs matmul_gbar0.elf -- though the barrier
ablation lives inside the p-loop, well after DMA, so the preload path should be
identical. Cleanest read is IHASH0 vs PGB0's 57,000.

UPDATE (IHASH0 opened): exact benchmark-open cycles --

    PA511    hash=7 (standard)     57,000
    PGB0     hash=7, no barrier    57,000
    IREMAP2  hash=7, remap=2       58,000   (+1,000, noise-level)
    IHASH0   hash=0                66,000   (+9,000 = +15.8 %)

So noc_port_hash=0 costs 9,000 cycles / 15.8 % on the DMA/preload phase. The
earlier ">=12-14 %" lower bound resolves to 15.8 %.

Also: P-GB0 reached 88.27 % util, matching GB0's ~90 % peaks on an independent
run -- corroborates the barrier arrival-window mechanism.

### 2026-08-08 — noc_router_remapping=2 is worth +7-12 pp (CLEAN comparison)

Confound check first. IREMAP2 vs A/511 is NOT a remap comparison -- it differs in
FOUR defines (hold 511->1023, serve_timeout 511->1023, remap 0->2, SNITCH_TRACE
1->0). The valid control is A1023, which differs from IREMAP2 ONLY in
NOC_ROUTER_REMAPPING (0 vs 2) plus SNITCH_TRACE / V4M_ENABLE, both of which gate
$fwrite in the TB and cannot feed back into the DUT.

    offset   remap=2   remap=0    delta
       0       0.0 %     4.7 %     -4.7   <- startup artifact, different open cycles
    1000      25.4      27.5       -2.1
    2000      50.7      31.9      +18.8
    3000      58.8      34.5      +24.2
    4000      66.3      49.3      +17.0
    5000      82.0      60.1      +21.9
    6000      85.6      62.7      +22.9
    7000      84.7      73.4      +11.3
    8000      83.9      76.0       +8.0
    9000      84.7      77.6       +7.2
   10000      85.4      77.6       +7.7

    mean over 11 matched periods: +12.0 pp

SHAPE MATTERS: huge during ramp-up (+19 to +24), narrowing to +7-8 pp by offset
10k as remap=0 catches up. Honest steady-state number is +7-8 pp; remap=2 mainly
reaches full utilisation much FASTER and holds a smaller sustained edge.

ACTIONABLE: terapool_spatz4_fpu ships noc_router_remapping=0 while
mempool_spatz4_fpu ships 3. The 8x8 config runs with response-path remapping OFF.

Caveats: 11 periods, all inside the FIRST p iteration -- neither arm has reached
the collapse, so this says nothing about the degradation. Needs more periods.

### noc_port_hash=0 costs -16.2 pp (clean comparison vs A1023)

IHASH0 vs A1023 differ ONLY in NOC_PORT_HASH (0 vs 7) plus SNITCH_TRACE /
V4M_ENABLE (TB-only $fwrite gates).

    offset  hash=0   hash=7    delta        offset  hash=0  hash=7   delta
       0     5.6 %    4.7 %    +0.9          10000   57.5    77.6    -20.2
    2000    29.4     31.9      -2.5          11000   51.7    77.0    -25.3
    4000    36.0     49.3     -13.4          12000   45.5    66.8    -21.3
    6000    34.8     62.7     -27.8          14000   50.5    56.9     -6.4
    7000    38.5     73.4     -34.9  <-worst 16000   48.2    59.1    -10.8
    8000    41.3     76.0     -34.7          18000   53.8    78.8    -25.0

    mean over 19 matched periods: -16.2 pp

IHASH0 is stuck in a 30-57 % band while A1023 reaches 78 %.

NEGATIVE CONTROL, not an opportunity -- terapool_spatz4_fpu ALREADY ships
noc_port_hash=7. This quantifies what the existing default is worth.

### Summary of the two inter-group knobs

    knob                    terapool ships   measured effect
    noc_port_hash           7  (ON)          off costs -16.2 pp, +15.8 % DMA
    noc_router_remapping    0  (OFF)         =2 gains +7-12 pp

noc_router_remapping is the one leaving performance on the table.
mempool_spatz4_fpu ships 3; the 8x8 config ships 0.

Caveats on both: 19 and 11 matched periods, all inside the FIRST p iteration.
Neither says anything yet about the collapse or the post-collapse plateau.

### 2026-08-08 — IR2 (noc_router_remapping=2) strengthens: +15.7 pp cum, and FLAT

Started Fri Aug 7 20:48 (inter-group batch), build_iremap2, standard ELF,
hold=1023. Only real diff vs A1023: NOC_ROUTER_REMAPPING 0 -> 2. (SNITCH_TRACE
and V4M_ENABLE also differ but only gate $fwrite in the TB.)

At matched 36 periods:
    IR2   cum = 80.79 %
    A1023 cum = 65.07 %      -> +15.7 pp
    per-period mean          -> +15.4 pp (excl. ramp)

    offset   IR2     A1023
      5000  82.0 %   60.1 %
     10000  85.4     77.6   <- A peak
     15000  86.2     53.4   <- A dip
     20000  85.5     78.7
     25000  86.2     59.4
     30000  82.8     78.5
     35000  86.0     57.6

IR2 sits FLAT at 82-86 %, ABOVE A1023's peaks, with no oscillation. A1023 swings
53<->79 on a ~10k period; IR2 does not. (Same flatness the quarter-load run
shows.)

**CRITICAL CAVEAT: IR2 is at offset 36,000; A1023 collapsed at offset 46,000.**
All of the +15.7 pp is PRE-COLLAPSE. Whether remap=2 also AVOIDS the collapse --
as the quarter-load run does -- is unknown for ~10,000 more cycles (~1 h).
"Raises the plateau" and "prevents the collapse" have very different
implications; do not conflate them until IR2 passes offset 46,000.

Supersedes the earlier "+7-12 pp" entry, which was measured over only 11 periods
during the ramp.

### 2026-08-08 — BR2: B config (1r+1rw req, 3 resp) + noc_router_remapping=2

User request. build_bremap2, log vcsBREMAP2_run.log, hold=1023.

    noc_req_rd_channel_num=1  noc_req_rdwr_channel_num=1  noc_req_wr_channel_num=0
    noc_resp_channel_num=3    noc_router_remapping=2

**Genuinely a new cell.** A survey of all 37 build dirs found rd=1/rdwr=1/resp=3
in six of them (b1023, b2047, bfix, e511, e8, xb1023 -- the "B" split) and
remap=2 in exactly one (build_iremap2, which is the A split rd0/rdwr2/resp2).
The intersection was empty.

Rationale: remap=2 is worth +15.7 pp cum on the A split, and B is the
second-best channel split in the ranking. Never combined.

Two comparisons:
  vs IR2   -- EXACT control. Same builder (vcs_ig.sh), same trace gates
              (TRACE_FORCE_OFF, V4M_ENABLE=0, snitch/spatz_trace=0), same
              hold=1023. Only the channel split differs. Isolates
              rd1+rdwr1/3resp vs rd0+rdwr2/2resp AT remap=2.
  vs B1023 -- isolates remap on the B split, but B1023 came from the A-F suite
              and also differs in SNITCH_TRACE / V4M_ENABLE / TRACE_FORCE_OFF.
              Those gate $fwrite in the TB only and have been shown bit-identical
              three times (broadcast release, probes 1+2, build_4 demux fix), so
              sound but one step weaker than the IR2 comparison.

hold=1023 matches both IR2 and B1023, so neither comparison is confounded by the
MSHR window.

Status: building (~20-40 min), then ~57k cycles to its benchmark region.

### CORRECTION 2026-08-08 — IR2 DOES collapse; "flat, no oscillation" was a window artifact

Earlier entry said IR2 "sits FLAT at 82-86 %, above A1023's peaks, with no
oscillation". That was based on data through offset 36,000 only. Full series:

    off  5000-36000   82-87 %   genuinely flat for 31,000 cycles
    off  37000        71.8      <- onset
    off  38000        55.0
    off  40000        52.9      <- floor
    off  41000        52.9
    off  42000        63.9      recovering
    off  43000        68.2
    off  44000        65.8

                     IR2                  A1023
    pre-collapse     82-87 % FLAT (31k)   53<->79 oscillating
    onset            offset 37,000        offset 46,000
    floor            52.9 %               28.2 %
    recovery so far  68.2 %               51.3 %

What survives: the plateau is much higher AND genuinely flat where A1023
oscillates; the floor is 24 pp shallower; the recovery is higher.
What does NOT: IR2 collapses EARLIER (37k vs 46k), not later, and it does not
avoid the collapse.

The +15.7 pp cum figure stands but its EXPLANATION changes -- not "remap=2 avoids
the collapse" but "remap=2 runs a higher, steadier plateau and takes a shallower
hit". Do not quote it as collapse-avoidance.

Lesson repeated from the quarter-load run: a flat stretch is not a flat run.
Characterise shape only after the arm has passed the offset where its control
collapsed.

### CORRECTION 2026-08-08 — hash DMA cost is +10 %, not +15.8 % (control had wrong hold)

Benchmark-open cycle (= end of DMA/preload), same ELF throughout:

    A split, hash=7, hold=511    PA511     57,000
    A split, hash=7, hold=1023   A1023     60,000   <- hold window alone: +3,000
    A split, hash=0, hold=1023   IHASH0    66,000
    B split, hash=7, hold=1023   B1023     66,000
    B split, hash=7 + remap=2    BR2       66,000

The earlier entry reported noc_port_hash=0 costing +9,000 cyc / +15.8 %, measured
against the 57,000 arms. Those are hold=511, and the hold window ALONE moves the
open by 3,000 cycles. Against the correct control (A1023: same split, same hold,
hash=7) the hash costs **+6,000 = +10 %**.

Direction and significance unchanged; the magnitude was inflated by conflating
the hold window with the hash.

ALSO: BR2 opens at exactly B1023's 66,000, so remap=2 costs nothing on the DMA
phase -- the later open is a property of the B channel split (rd1+rdwr1/3resp),
which is itself +6,000 vs the A split at matched hold.

### 2026-08-08 — cross-arm equal-N standing (N=74, IR2's period count)

Mean util over each arm's FIRST 74 benchmark periods. This window, not lifetime
cum: IR2 has only 74 periods against 400+ for most arms, so its cum covers just
its plateau while theirs span collapse + plateau + drain. QTR scaled x4.

    IREMAP2   76.52 %   remap=2 on the A split
    GBAR0     68.10     barrier ablated
    PGB0      68.10     same, probe build -- identical, as expected
    QUARTER   63.85     16/64 groups, x4 normalised
    A1023     58.49     <- IR2's clean control
    F1023     57.83
    B1023     55.92
    VCS11     55.41
    C1023     52.60
    IHASH0    46.93     hash off
    v9 / v8   28.2 / 27.9   ch2 arms

**IR2 beats its own clean control (A1023) by +18.0 pp** from one knob the 8x8
config ships DISABLED. That is the actionable result of the campaign.

Three caveats against reading this as a simple leaderboard:
  - QTR's 63.85 % understates its value. It does a QUARTER of the total work; the
    point is not the level but that it finished the whole kernel with NO
    p-boundary collapse, +15.5 pp ahead of A/511 on whole-kernel cum. IR2 does
    collapse, at offset 37k -- EARLIER than its control.
  - v9 tops the dashboard's N=392 ranking while sitting LAST here. Same data,
    different window: N=392 includes the drains, N=74 excludes them. Neither is
    wrong; N=74 is the right one for "which config runs the kernel fastest".
  - BR2 (B split + remap=2) is at 19 periods / 77.25 % -- tracking IR2 closely but
    far too early to compare.
