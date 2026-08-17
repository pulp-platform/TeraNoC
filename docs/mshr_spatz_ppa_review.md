# Group MSHR + Spatz — backend PPA review

2026-08-17. A read of `mempool_group_mshr.sv` (5,000 lines, 10 `always_ff`) and the Spatz VLSU/ROB
knobs, looking for area the design does not need.

**Headline: the MSHR has already been swept thoroughly, and every structural candidate I raised died
on inspection.** That is the useful result — the reasons are recorded below so nobody re-opens them.
The one open item is not a redundancy at all: it is whether the 44 `` `ifndef TARGET_SYNTHESIS ``
guards that carry the existing savings are actually **armed in the backend flow**, because nothing
in this repository defines that macro.

Sizing basis: `terapool_spatz4_fpu` 4×4 — 16 groups, `MshrNum=64`, 16 tiles/group, 1 core/tile,
5 data ports/core, 3 remote resp ports. Widths from the `pinprobe` dump
(`tcdm_addr=16 meta_id=6 tile_core_id=3 tile_group_id=4 BurstLenW=5`), not assumed.

## ⚠️ The one open item: are the guards armed?

`mempool_group_mshr.sv` alone has **37** `` `ifndef TARGET_SYNTHESIS `` guards; five more files add
7. Inside the MSHR entry they exclude, per entry:

| field | width | why excluded |
|---|---:|---|
| `beat_seen` | 16 b | every read is an assertion |
| `beat_done` | 16 b | only reader is the `beat_done_subset_seen` assertion |
| `cache_hit_cnt` | 32 b | statistics |

**64 b/entry → 65,536 flops at 4×4, 262,144 at 8×8.**

`TARGET_SYNTHESIS` is **not defined by anything in this repository** — no `.mk`, Makefile, `.tcl`,
`.sh`, or `.yml` sets it, and the simulation flow never exercises the guarded-out path. The macro is
the Bender convention (`bender script … -t synthesis` emits `TARGET_SYNTHESIS` automatically), so
this is very likely fine — but it is fine *by convention held in another team's flow*, and nothing
here checks it.

**Action: confirm with whoever runs synthesis that their `bender script` invocation passes
`-t synthesis`.** If it does not, that is a quarter of a million flops of assertion state in the
8×8 netlist, and it costs one flag to fix. This is worth more than any remaining micro-optimisation
in this file.

A cheap guard against regression: have the backend flow fail if `TARGET_SYNTHESIS` is unset, or add
an elaboration `$fatal` in a synthesis-only branch.

## Already harvested

Recorded so the review does not re-propose them.

- **`amo` dropped from the sub-request record.** A sub-request only exists behind `req_can_merge`,
  which requires `req_is_load` (`valid && ~wen && wdata.amo == '0'`), so the stored AMO code was
  provably constant — 4 b × `MshrMergeReqs` = 16 flops/entry recording nothing.
- **`core_id`, `amo`, `mshr_tag` dropped from each response-buffer slot** — 14 of 53 b per slot,
  × 2 slots × 64 entries = **1,792 flops/group**. `mshr_tag` was the entry's own index.
- **`beat_seen`, `beat_done`, `cache_hit_cnt` excluded from synthesis** — see above.
- **`group_mshr_hold_prescale_w = 4`** — hold counters tick once per 16 cycles, so each `hold_cnt`
  is 4 b narrower than cycle-accurate.
- **`spatz_rob_cnt_idvalid` / `spatz_vlsu_commit_qmin`** — defaulted ON 2026-08-17 (`8d199128`).
  Commit FIFO 32→4 (−28×37 flops + a 37 b 32:1 read mux); ROB free-id bitmap replaced by
  `status_cnt_q` (−NumWords flops, −1 decoder, −2 32:1 muxes per ROB, ×4 ROBs/core, ~6 logic levels
  off the `id_valid_o → mem_req_lvalid` path). phaseE1 measured both cycle-identical on all 23 shapes.

## Ruled out — with the reason, so they stay closed

**Narrowing `burst_len` below 5 b.** Bursts look like they are only ever 1 or 16, which would need
1 bit and would also narrow the NoC request channel. False: `spatz_vlsu.sv:1134` sets
`burst_len_eff = burst_alloc_cnt_q`, a running allocation count, so a partial/tail burst takes any
value in 1..16.

**Dead bits in `tile_core_id_t` at 1 core/tile.** It is `idx_width(NumCoresPerTile ×
NumDataPortsPerCore)` = `idx_width(5)` = 3 b, encoding the *port*, not the core. Correctly sized.

**`port_id` derivable from `core_id`** (would have been up to 32,768 flops — the largest candidate).
Dead: the port is **dynamically arbitrated**, not a static function of the requester.
`tcdm_id_remapper.sv` stores `id_d[next_id] = id` — the input port that won arbitration — indexed by
an LZC-allocated ROB id, for exactly the reason the MSHR does. Even the remapper cannot recompute it.

**`beats_left` = `burst_len − popcount(beat_done)`.** Backwards: `beats_left` *is* the synthesised
completion counter that the state machine tests; `beat_done` is the verification-only bitmap that
exists so an assertion can check the subset property. Removing `beats_left` would mean synthesising
`beat_done` — strictly worse.

**Re-encoding `beat_seen`/`beat_done` given `beat_done ⊆ beat_seen` (`:1527`).** Dead twice over:
they are already excluded from synthesis, and `:688` states beats are captured **out of order**
(`resp_capture_beat_offset`, not a sequential counter), so the two are genuinely independent sets
that could not collapse to counters anyway.

## What is actually left

After the above, the synthesised per-entry state is dominated by one structure:

| structure | width | ×`MshrNum`×groups (4×4) |
|---|---:|---:|
| `sub_reqs[]` @ `MshrMergeReqs=16` | 256 b/entry | **262,144** |
| `sub_reqs[]` @ `MshrMergeReqs=8` | 128 b/entry | 131,072 |
| `sub_reqs[]` @ `MshrMergeReqs=4` | 64 b/entry | 65,536 |

One record is 16 b: `valid`(1) + `tile_id`(4) + `port_id`(2) + `core_id`(3) + `meta_id_base`(6).
Every field is load-bearing (see the `port_id` finding above), and `MshrMergeReqs` is already
autotuned per shape to the actual share degree — so the array is sized to what the kernel needs and
that lever is spent.

**The remaining lever is therefore `MshrMergeReqs` itself, not the record.** It is set to
`max(share_a, share_b)`; if a shape's true merge degree is lower than that bound in practice, the
array is oversized. That is a measurement question, not an inspection one: instrument the observed
maximum `sub_reqs_num` per entry across the sweep and compare against the elaborated
`MshrMergeReqs`. If the observed maximum is consistently below the bound, the array can be
narrowed — at 16 b per record per entry per group, each unit of `MshrMergeReqs` removed is
**16,384 flops/cluster** at 4×4.

## Recommended order

1. **Confirm `-t synthesis` is passed by the backend flow.** Largest effect, costs one question.
2. **Instrument observed `sub_reqs_num` maxima** during the running sweeps; it is the only remaining
   lever with real mass, and the data is nearly free to collect.
3. Nothing else in this file is worth touching on area grounds.

Nothing should land until the in-flight default-config and `cfg_runtime=1` sweeps complete — they
are the first measurements of the shipping configuration and are the baseline any PPA change must
be shown not to regress.
