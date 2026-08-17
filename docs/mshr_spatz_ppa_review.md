# Group MSHR + Spatz — backend PPA review

2026-08-17. A read of `mempool_group_mshr.sv` (5,000 lines, 10 `always_ff`) and the Spatz VLSU/ROB
knobs, looking for area the design does not need. Findings are separated into **already harvested**,
**ruled out** (so nobody re-investigates), and **candidates** — and the candidates are ranked by
flops/cluster with their cost stated, because two of the three are area-vs-timing trades rather than
free wins.

Sizing basis throughout: `terapool_spatz4_fpu` 4×4 — 16 groups, `MshrNum=64`, 16 tiles/group,
1 core/tile, 5 data ports/core, 3 remote resp ports. Field widths taken from the `pinprobe` dump
(`tcdm_addr=16 meta_id=6 tile_core_id=3 tile_group_id=4 BurstLenW=5`) rather than assumed.

## The flop budget, so effort goes where the mass is

Per MSHR entry the dominant structure is the sub-request array — one record per *requester*:

| structure | width | ×`MshrNum`×groups |
|---|---:|---:|
| `sub_reqs[]` @ `MshrMergeReqs=16` | 256 b/entry | **262,144** |
| `sub_reqs[]` @ `MshrMergeReqs=8` | 128 b/entry | 131,072 |
| `sub_reqs[]` @ `MshrMergeReqs=4` | 64 b/entry | 65,536 |
| `beat_pending` + `beat_pending2` + `beat_seen` + `beat_done` | 64 b/entry | 65,536 |

One sub-request record is 16 b: `valid`(1) + `tile_id`(4) + `port_id`(2) + `core_id`(3) +
`meta_id_base`(6). `MshrMergeReqs` is already autotuned per shape (4 / 8 / 16), so the array is
sized to the actual share degree — that lever is spent.

## Already harvested

Visible in the RTL comments; recorded here so the review does not re-propose them.

- **`amo` dropped from the sub-request record.** A sub-request can only exist behind `req_can_merge`,
  which requires `req_is_load` (`valid && ~wen && wdata.amo == '0'`). The stored AMO code was
  provably constant zero — 4 b × `MshrMergeReqs` = 16 flops/entry recording nothing.
- **`core_id`, `amo`, `mshr_tag` dropped from each response-buffer slot** — 14 of 53 b per slot,
  × 2 slots × 64 entries = **1,792 flops/group**. `mshr_tag` was the entry's own index, known from
  where the slot lives.
- **`group_mshr_hold_prescale_w = 4`** — each hold counter ticks once per 16 cycles, so every
  `hold_cnt` is 4 bits narrower than a cycle-accurate one.
- **`spatz_rob_cnt_idvalid` / `spatz_vlsu_commit_qmin`** — defaulted ON 2026-08-17 (commit
  `8d199128`). Commit FIFO 32→4 (−28×37 flops + a 37 b 32:1 read mux) and the ROB free-id bitmap
  replaced by `status_cnt_q` (−NumWords flops, −1 decoder, −2 32:1 muxes per ROB, ×4 ROBs/core,
  ~6 logic levels off the `id_valid_o → mem_req_lvalid` path). Both measured cycle-identical by
  phaseE1 across all 23 shapes.

## Ruled out during this review

- **Narrowing `burst_len` below 5 b.** The obvious hypothesis is that bursts are only ever 1 or 16,
  which would need 1 bit. False: `spatz_vlsu.sv:1134` sets `burst_len_eff = burst_alloc_cnt_q`, a
  running allocation count, so a partial/tail burst takes any value in 1..16. The field rides the
  NoC request channel too, so this would have been worth several thousand flops — but it is not
  available.
- **Dead bits in `tile_core_id_t` at 1 core/tile.** `idx_width(NumCoresPerTile * NumDataPortsPerCore)`
  = `idx_width(1 × 5)` = 3 b. It encodes the *port*, not the core, and is correctly sized.

## Candidates

### 1. `port_id` may be derivable from `core_id` — up to 32,768 flops/cluster

Each sub-request stores both `port_id` (2 b, `idx_width(NumRemoteRespPortsPerTile)`) and `core_id`
(3 b, the requester's core×port index at the tile TCDM interface). They are not the same thing —
`port_id` is *which remote request port it arrived on* (`:3103`, `= port_i`), `core_id` is *who
asked* — but the tile's `tcdm_id_remapper` maps core ports onto remote ports by a fixed rule
(scalar FP traffic on shared port 0, VLSU on 1–4). **If that map is static, `port_id` is a pure
function of `core_id` and does not need storing.**

- Prize: 2 b × `MshrMergeReqs` × 64 × 16 = **32,768 flops** at `MergeReqs=16`, 8,192 at 4.
- Cost: a small decode in the drain path, on a path that already muxes on `core_id`.
- **Not yet verified.** Confirm the remap is static and injective in the needed direction before
  acting; if any dynamic arbitration picks the remote port, this is dead.

### 2. `beats_left` is derivable — 5,120 flops/cluster

`beats_left` (5 b) counts down from `burst_len` while `beat_done` (16 b) already records exactly
which beats completed. `beats_left == burst_len - popcount(beat_done)` by construction.

- Prize: 5 b × 64 × 16 = **5,120 flops**.
- Cost: a 16-bit popcount plus a subtract in whatever path currently tests `beats_left`. On a
  16-wide vector that is ~4 levels — this is an **area-for-timing trade**, and the drain path is
  already the timing-critical one. Only worth it if that path has slack.

### 3. `beat_seen` / `beat_done` containment — up to 32,768 flops/cluster, hardest to exploit

`mempool_group_mshr.sv:1527` asserts the invariant `(beat_done & ~beat_seen) == '0'`, i.e.
**`beat_done ⊆ beat_seen` always**. Two 16-bit vectors with a proven containment relation is a
strong hint of redundancy — a subset can often be re-encoded (e.g. as a count, or a single vector
plus a pointer) when the sets are contiguous.

- Prize: up to 32 b × 64 × 16 = **32,768 flops** if one vector can be eliminated.
- Cost: unknown until the two are shown to be contiguous rather than arbitrary. Out-of-order beat
  return would make them genuinely independent sets, in which case this is not available at all.
- **Investigate before designing.** The question to answer first: can beats be *seen* out of order?
  If the NoC delivers beats in order per entry, both vectors collapse to counters.

## Recommended order

1. **Verify candidate 1** — largest prize, and the only one that is plausibly free (no timing cost).
2. **Answer the ordering question behind candidate 3** — cheap to determine, and it either unlocks
   32k flops or closes the item permanently.
3. **Leave candidate 2** unless the drain path is shown to have timing slack; 5,120 flops is not
   worth pressure on the critical path.

None of these should be implemented against the current RTL until the in-flight default-config
sweep completes — that sweep is the first measurement of the shipping configuration, and it is the
baseline any PPA change must be shown not to regress.
