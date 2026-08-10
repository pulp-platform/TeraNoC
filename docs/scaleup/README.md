# 8x8 / 1024-core scale-up

Working documents for the 4x4 (256-core) -> 8x8 (1024-core) scale-up, 2026-08-06/07.

| file | what it is |
|---|---|
| `mesh_plan.md` | **the plan** (2026-08-03): make mesh size a config parameter, L1+L2 NoC together. Phases, blockers, risks, open decisions. Supersedes `scaleup_8x8_plan.md`. |
| `running_sims_registry.md` | **the campaign log** (2026-08-06/07): every simulation in flight — config, purpose, keep/kill judgement — plus the running record of findings and corrections |
| `fpu_util_per_period.md` | **the data**: per-period FPU utilisation for every run, plus an equal-N ranking. **Auto-generated** — regenerate with `python3 /tmp/claude-620771/gen_util_table.py` |
| [**live dashboard**](https://claude.ai/code/artifact/0addc571-20b4-4099-aae7-e0617f22147b) | the same data as charts + tables: scope overlay, small multiples per run, ranking, MSHR counters. Regenerate with `python3 /tmp/claude-620771/gen_util_artifact.py`, then republish the emitted `util_dashboard.html` to the same URL. A watcher (`watch_util_artifact.sh`) regenerates it every 10 min and signals when the ranking or period count moves materially. |

`mesh_plan.md` is the design intent; the other two are what actually happened when the
8x8 was built and measured.

## Headline findings

| finding | effect |
|---|---|
| MSHR `hold_burst`/`serve_timeout` 255 -> 511 | **~1.9x** (A vs v9, equal-N mean) |
| NoC response channels 2 -> 3 | **+40%** (B vs C, request path held fixed) |
| >32-group wake-up bug | correctness — half the machine was idle; fixed in `45baf9e` |
| `rd1+rdwr1` demux `c % N` no-op at 1 core/tile | reads pinned to one port, 80/20 instead of 50/50; fix under test as B'/C' |
| 4th response channel | **0.92x pre-break / 1.20x post-break** — see correction below |
| 1024-core boot | 1024/1024 cores, `retval = 0` |
| 4x4 reference | 83-95% of FPU peak |

**Correction (2026-08-07):** the "4th response channel ~ 0" entry above is the average of
two opposite effects. F vs E is **0.92x pre-break** and **1.20x post-break** over 72 matched
periods -- it hurts while all groups run well and helps once the machine is imbalance-limited.

## Hold window: what the MSHR counters show

Three windows, identical config (`rd0+rdwr2 / resp2`), matched over 15 benchmark periods:

| hold | util | `mshr_timeout`/1k | `bankfull_bypass`/1k |
|---:|---:|---:|---:|
| 255 | 32.0% | 3174 | **9154** |
| 511 | 58.6% | 883 | **257** |
| 1023 | 59.0% | 277 | **155** |

- **A longer window collapses way pressure (-97%), it does not raise it** -- the opposite of
  the old W-sweep's mechanism. At 255 entries time out before merge partners arrive, so each
  request allocates its own entry and entry volume saturates the ways.
- **The benefit is fully captured at 511 FOR THE A CONFIG**; 511 -> 1023 is +0.7%. But this is
  **config-dependent**: on D (1rdwr/resp2) the ladder is 16.3% -> 28.5% -> **38.2%**
  (511/1023/2047), still climbing at 2047 (**2.35x**). D sits much further from its merge
  threshold, so it needs a far longer window. The discriminator is the `mshr_timeout` rate:
  at 1023, D shows 1050/1k versus A's 280/1k -- still starved where A is done. Pick the knob
  from that counter, not from a global constant.
- **255 is a runaway**: per-period bypass climbs 512 -> 2626 -> 9102 -> 21783 while util sags.
  At 511/1023 it stays flat. A stability difference, not just a magnitude one.

## Method notes worth keeping

Several conclusions were wrong before they were right; the causes were all windowing:

- **`cum` is not comparable across runs** at different period counts — it is a running
  average that carries the ramp forward forever. Use per-period values.
- **Offset-matched comparison is not sufficient** either: configs advance through the
  kernel at different rates, so the same cycle offset is a different algorithmic position.
  Use **mean over an equal number of periods** (work-per-time).
- **The first `[LP]` delta after the benchmark region opens covers everything since reset**
  (the `prev` cursors start at zero), so it is boot+warm-up, not a period sample.
- **A window can be correctly aligned and still too short** to contain the phenomenon --
  the 255 runs oscillate over ~60k cycles and look flat if you stop at 16k.
- **`grp_min` collapsing is not an end-of-run signature.** It looked like one on A (util
  71 -> 28% with `grp_min` 17 -> 1.2%, `[LP]` `mst_resp` halving while `slv_req` doubled),
  but it fires transiently on C, D, E and F with no drain, and A then recovered to 34%
  with `mst_resp` back up. The deep dips are store-heavy phases, not the run ending. No
  automatic marker distinguishes the two, so the dashboard marks neither.

## Regime warning — read before quoting any ratio

Four of the five 511 arms enter a **second, lower operating point** partway through the
timed region (A at offset ~42k, B and E at ~39k, F just below the detection threshold) and
**do not recover**: E has held 33% flat for 24,000 cycles. Plateaus land at 57-71% of the
pre-break level, with `grp_max` pinned at 99-100% throughout -- a work-distribution
asymmetry, not a bandwidth ceiling. C is the only arm with no break.

Ratios change across the boundary. A vs B is **1.02x** pre-break and **1.27x** post-break.
Every headline figure in this directory was measured predominantly pre-break, so treat them
as characterising the first regime only.

**Why it happens.** Group saturation splits the sweep exactly along the hold window: no group
in any 255 run ever exceeds ~39%, while every 511 arm holds some group at 99-100%
continuously. At 255 the MSHR times out ~4500x per 1000 cycles, so requests issue unmerged
and all groups are throttled identically -- none can pull ahead, and none can fall behind
either. At 511 merging completes and groups run at their own rate. The break is the cost of
that freedom: only saturating configs break. So the 2.13x is really "stop throttling
everything uniformly", and the second regime is the imbalance the throttling was masking --
which suggests the next lever is work rebalancing, not a longer window. (`D` is the control:
hold=511 but non-saturating and unbroken, because its single request channel binds first.)

## Related design docs (left in `docs/`, they have inbound references)

`mshr_request_hold_design.md`, `mshr_bank_hash_design.md`, `respbw_paritydrain_design.md`,
`respbw_2wide_design.md`, `tcdm_burst_interleave_design.md`, `teranoc_architecture.md`.
