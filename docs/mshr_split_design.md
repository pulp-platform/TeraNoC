# Disaggregated group MSHR (`GROUP_MSHR_SPLIT`)

**Status (2026-09-22):** RTL complete and validated on `terapool_spatz4_fpu` (§8): directed MSHR
test passes, 512x128x128 prefill GEMM is 9.5 % faster than the same-HEAD legacy MSHR. Legacy
single-module path untouched at `group_mshr_split=0`. **`config/terapool_spatz4_fpu.mk` ships
`group_mshr_split ?= 1`** with the per-instance entry knobs grouped under it (`ifeq`: split → 8/4/1
per slice, legacy → 64/4/8); software reads the same variables through `runtime.mk`, so nothing
needs repeating on a make line — `group_mshr_split=0` on any make line selects the legacy set for
both HW and SW.

## 1. Why

The single group MSHR sits at the group centre with 32 tile ports in and 32 router lanes out, on
top of the intra-group crossbars already there. The 500 MHz placement of
`mempool_group_floonoc_wrapper` put 18,400 of its 22,776 violating endpoints (80.8 %) inside it
(`docs/mshr_ooc_campaign_report.md`). Edge tiles have long wires to it, and the centre is already
the hardest routing region of the group.

## 2. Sharing pattern that makes a split lossless

`sp-fmatmul` has two work splits with **opposite** orientations (`main.c`):

- **decode** (`:484-485`): `row_chunk = cid % n_row_chunks`, `p_block = cid / n_row_chunks` — the
  row chunk varies fastest, so B (burst) sharers are **contiguous** tiles and A (scalar) sharers
  are **strided**.
- **prefill** (`:530-535`): `p = core_gid % split_p_count`, `m = core_gid / split_p_count` — the
  p-slice varies fastest, so A (scalar) sharers are **contiguous** and B (burst) sharers **strided**.

With 16 tiles per group as a 4x4 grid:

| slice | tiles | decode | prefill |
|---|---|---|---|
| row `R_k`, k = 0..3 | `4k .. 4k+3` | burst-B sharers | scalar-A sharers |
| column `C_k`, k = 0..3 | `k, k+4, k+8, k+12` | scalar-A sharers | burst-B sharers |

The hardware is the same for both; the class→family assignment is the CSR `steer_single_row`
(§4), and software derives it from the split it runs (§7). Getting it wrong does not error: every
single load lands in a slice with no partner and waits out the hold window — measured
512x128x128 prefill at the decode orientation: >400k benchmark cycles at 0.1 % util vs 12.4k.

Any two tiles share exactly one slice. The 4/4 split (the one `GEMM_SCORE` prefers) merges at full
degree; every other power-of-two split merges at `min(share, 4)` per class, still a 4:1 reduction.
The backend synthesis define set already used `GROUP_MSHR_MERGE_REQS=4`, so no merge capacity is
given up relative to the hardened configuration.

## 3. Structure

```
tile t, port r ──demux (class)──► R_{t/4}  ─┐            ┌─ 4 NoC lanes ──► routers/remapper
                              └► C_{t%4}  ─┘  slice m:  ─┤
                                                         └─ 4 NoC lanes ◄── resp crossbar
tile t, port r ◄──RR arbiter──── R_{t/4}, C_{t%4}
```

Per group: 8 × `mempool_group_mshr_slice` (`hardware/src/mempool_group_mshr_slice.sv`), 32 request
steer demuxes and 32 response 2:1 round-robin arbiters (`mempool_group.sv`, `gen_group_mshr_split`).

A slice reuses `mempool_group_mshr` elaborated with `NumTilesPerGroup=4` lane-tiles
and `NumAddrTiles=16` (address geometry; `TileIdBits` was the only place the two were
conflated), plus two lane folds. Its two-bank hash path is specialized by `SliceFamily` (§9b).
The core is strictly lane-keyed (a bypass beat leaves on the lane
it entered; a merged beat must arrive on its owner's lane, `mempool_group_mshr.sv:4479`), so the
folds live outside it:

- **Request fold 8→4.** NoC lane `(k, p)` = RR between lane-local tiles `{2k, 2k+1}` on port `p`.
  Stamps `src_tile_id` (global tile) and the slice id into the tag (§5).
- **Response steer 4→8.** NoC lane `(k, p)` → local tile `{2k, 2k+1}` by the low bit of the tile's
  slice-local index; the group crossbar already chose `k` = high bit. Strips the slice id.

Entries: `group_mshr_num` and `group_mshr_overflow_num` are **per slice** when split. `8` + `1`
reproduces the legacy `64 + 8` per group, in 2 banks of 4 ways per slice.

## 4. Steering (per tile port, `mempool_group.sv`)

| request | slice |
|---|---|
| store / AMO | bypass slice of `t` |
| load, single class, class merges | `steer_single_row ? R : C` |
| load, burst class, class merges | `steer_single_row ? C : R` |
| load whose class is bypassed (`hold_subs == 1`, MSHR disabled, `EnableMshrSingleReq=0`) | bypass slice of `t` |

**Bypass slice of `t` = `(t[0]^t[2]) ? C_{t[1:0]} : R_{t[3:2]}`.** No single bit of `t` varies
inside both a row (`t[3:2]` fixed) and a column (`t[1:0]` fixed); the XOR does. Each slice thus
carries bypass for exactly 2 of its 4 tiles, i.e. 2 tiles × 2 ports = 4 bypass sources against 4
NoC lanes — bypass keeps full rate. Those two tiles have lane-local indices of equal parity
(`{0,2}` or `{1,3}`), so the request fold pairing `{2k, 2k+1}` never puts them on one lane.

Bank-full bypass inside a class slice stays on that slice's lanes (rare, degraded case).

`steer_single_row` is CSR index 12 (`MSHR_CSR_STEER_SINGLE_ROW`), refused while any slice is busy,
reset value from `group_mshr_steer_single_row` (default 0 = singles→column = the **decode**
orientation; prefill needs 1). Software always writes it (§7), so the reset value only matters for
a kernel that does not program the MSHR.

## 5. Tag and headers

- `mshr_tag = {slice[2:0], local}`; `local` = 0 (bypass) or entry+1 / `MshrNum+1+pool`. Width
  `MshrSliceIdW + idx_width(MshrNum + PoolNum + 1)` = 3 + 4 = 7 bits at 8+1 — the same 7 bits the
  legacy 64-entry tag used, so no NoC header growth.
- The slice id is stamped on **every** request, bypass included, so a response always returns to
  the slice that sent it. The group response crossbar selects on the tag alone (§6).
- New struct fields: `tcdm_master_req_t.src_tile_id` (a NoC lane no longer identifies a tile; the
  wrapper used to write `src_tile_id: i`) and `tcdm_master_resp_t.tile_id` (echoed `hdr.tile_id`,
  for the slice's steer).

## 6. NoC face (`mempool_group_floonoc_wrapper.sv`)

- Group lane of slice `m`, lane `k`: **`mshr_noc_lane(m, k) = {m[2], k, m[1:0]}`**. The existing
  `floo_remapper` (`Interleaved=1`, `GroupSize=4`) groups flat lanes `{i, i+4, i+8, i+12}` at one
  port; with this placement each remap group is `R_k`'s two port-`p` lanes + `C_k`'s two, i.e. the
  (R_k, C_k) × port pairing — **no remapper change**.
- Response crossbar (`i_local_resp_interco`, 16×16 per port, unchanged size) select:
  `mshr_noc_lane(tag.slice, mshr_slice_local(tag.slice, hdr.tile_id)[1])`.

## 7. Software

- `MSHR_CFG_SPLIT` (from `group_mshr_split`) caps every derived merge target at
  `MSHR_MERGE_CAP = min(MSHR_MERGE_REQS, 4)` (`runtime/mshr_cfg.h`): a per-class target above 4 can
  never assemble in a 4-tile slice and would run every hold window to timeout (the 8x8 RH-livelock
  signature).
- `mshr_cfg_apply_group` writes CSR 12 when split; `MSHR_D_STEER_SINGLE_ROW` (compile-time) and
  `mshr_cfg_derive` (runtime) both set it from the split: **1 for prefill, 0 for decode**.
- `MSHR_CFG_ENTRIES` must be the per-slice `group_mshr_num` (8). Both come from the config's
  `group_mshr_split` block, so a plain `make <app> config=terapool_spatz4_fpu` matches a plain RTL
  build; only override `group_mshr_split` on BOTH sides if you change it at all.

## 8. Validation

| check | result |
|---|---|
| `sp-mshr-burst-test` (9 phases), split image, Questa and VCS | EOC retval 0 = all phases PASS, both simulators end at 38,554 ns. **Caveat, found 2026-09-22: this test never writes the MSHR CSRs** (0 uses of `mshr_cfg_apply_group`) and at the shipped `group_mshr_cfg_runtime=1` the CSR `enable` resets to **0**, so it runs FULLY BYPASSED. It therefore validates the split's steer demuxes, lane fold, response demux, per-tile arbiters and the group crossbar's tag-based routing under heavy traffic — **not** MSHR merging. Merging is validated by the GEMM and qwen arms below, which do program the CSRs. |
| `sp-mshr-burst-test` on the legacy image, same HEAD | EOC retval 0; identical `[CMS]` artefact pattern (test-specific), same bypass caveat |
| `sp-fmatmul-opt-burst-merge` 512x128x128 fp32 prefill, legacy image, same HEAD | **12,374** benchmark cycles, util 75.35 % |
| same, split image, WRONG orientation (steer=0) | >400k cycles, util 0.1 %, `mshr_timeout` +610/kcyc — the failure mode §2 describes |
| `qwen-gate-up` B=16 K=160 P=16384 KT=16 (decode split, share W=2, X=8), legacy image, fleet `qwen1` | **80,559** cycles (gate 40,084 / up 40,473), `subs=8/2`, 0 timeouts |
| same, split image | **81,467** cycles (gate 40,755 / up 40,692), `subs=4/2`, 0 timeouts, 0 slice assertion hits — **+1.1 %**: X is shared by 8 cores here, so the 4-tile slice merges it 4:1 instead of 8:1 (the `min(share, 4)` cost of a non-4/4 split); W (share 2) is unaffected |
| same, split image, steer=1 (fleet batch `split2`) | **11,199** benchmark cycles, util 79.70 %, retval 0 — **9.5 % faster than legacy**; kernel's own counter 12,775 → 11,599 (−9.2 %); `[SPOT]` result words bit-identical; 0 `mshr_timeout`, 0 bank-full bypass, 0 RH-stuck, 0 slice assertion hits on both |

Whole-sim time also drops (417 µs vs 545 µs): the runtime bank-hash search has 2 banks per slice
to score instead of 16.

## 9. Testbench probes that bind to the MSHR by hierarchical name

`mempool_tb.sv` (trace-enable force), `tb_fpu_util.svh` (timeout / bank-full counters, summed
over slices), `tb_noc_bottleneck_profiling.svh` (now taps the group-level wires, which are the
MSHR's own port nets in the legacy build), `tb_noc_req_resp_tracer.svh` (`TR_MSHR_S(G,M)`),
`sim_dashboard/rtl/dashboard_probe.svh` (`SD_MSHR_S`; group entry `e` = slice `e/8`, local `e%8`).
The `[BYP]`/`[RH]`/stats `$display` lines keep their format and print once **per slice**, with
the same `g=`; a per-group reading must sum the eight. ~20 `scripts/questa/*.tcl` still name the
legacy path (GUI only).

## 9a. Tooling adapted to the split

| tool | change |
|---|---|
| runtime hash search `software/runtime/gemm_hash.h` | under `MSHR_CFG_SPLIT` each class is scored on slice 0 of its family (row cores `{0..3}`, column `{0,4,8,12}`) over the slice's own banks; legacy `.text` byte-identical |
| shared model `sim_dashboard/trace_dashboard/analysis.py` (`hash_explore`) | `hash.mshr_split`, `hash.steer_single_row` (default from the split), `hash.slice_tiles`; same per-class core filter |
| `scripts/mshr_bank_hash_explore.py` | `--mshr-split [--steer-single-row 0/1]`, pass `--banks 2 --entries 8`. On 512x128x128 the compile-time defaults (single 7, burst 4) already reach both banks 4/4 within one cohort — the 2-bank problem is a within-cohort spread and any row-stride bit (7–9) solves it |
| dashboard reader `trace_dashboard/rtl.py` | folds the eight per-slice `[MSHRU]` lines of a group/window into one `mshr` record (occupancy/capacity/full/entries add, peak = max), sets `info.mshr_slices`; without it the model raised `Duplicate record` on every split transcript. `generate.py` verified on both the split and the legacy 512x128x128 transcripts |
| `scripts/questa/wave.tcl`, `add_group_mshr.tcl` | `add_group_mshr_wave` now dispatches: legacy instance, or eight slice cores labelled `MSHR_G<g>_X<x>Y<y>_{R0..R3,C0..C3}` via the shared `add_mshr_core_wave`, plus each slice's NoC/tile face under `Slice`, plus a `MSHR_G<g>_..._Steer` group with the CSR steering bit, per-tile `is_burst`/`to_col`, the tile→slice and slice→tile handshakes and the slices' NoC face |

| `qwen-gate-up` | uses the same `MATMUL_DECODE_SPLIT` / `MSHR_CFG_DERIVED_INIT` path, so the steering CSR follows the split automatically; its HOST-side hash chooser `script/gen_hash.c` now counts the blocks ONE slice's 4 cores hold (`cores/bankset=4`) and `gemm_hash.h` is self-sufficient without `mshr_cfg.h`. Build with the same three knobs appended to the usual command: `make qwen-gate-up config=terapool_spatz4_fpu qwen_b=16 qwen_k=160 qwen_p=16384 qwen_kt=16 l2_size=536870912 icache_warmup=1 group_mshr_split=1 group_mshr_num=8 group_mshr_overflow_num=1 -B` → `QWEN_HASH_BANKS 2`, `{4,4,0}`, decode split, steer 0 (X singles → column slices, where the 4 same-parity cores share X; W bursts → rows, 2 cohorts of 2 per slice) |

Not adapted (GUI debug one-offs): the other 16 `scripts/questa/*.tcl` still name `gen_group_mshr/i_group_mshr`.

## 9b. Bank select inside a slice (2026-09-22)

**RTL.** A slice's *allocating* traffic is a single request class: the steer demux sends singles to
one family and bursts to the other, and anything of the other class that reaches a slice is bypass
traffic that never allocates (asserted: `slice_class_only`). So a slice needs no per-request class
select on its bank. The core (`SliceFamily` parameter, set by the slice wrapper) decodes ONE shift
per slice from the CSRs — `steer_single_row` + family pick `bank_shift_single` or
`bank_shift_burst`, and `bank_burst_bits=1` folds to shift 4, which is what it means at one bank
bit — into a 7-bit one-hot over the legal range [4, 10]. Each lane's bank is then a 7-input AND-OR
on its linear word address. Removed from the per-lane path: the second-class hash, the burst-bits
arm and the `req_is_single` mux on both the bank and its one-hot. Every request of the slice
(stores and bypassed loads included) banks with the slice's class, so draining-entry and store
cache-hit lookups search the bank where the slice's entry for that address actually lives. Active
only when the slice has 2 banks and hash mode 3 (`SliceBank1`); otherwise the general hash is
used unchanged. Asserted equal to `mshr_bank_of(..., slice class)` on every valid lane
(`req_bank_split_equiv`), and that the one-hot is legal (`slice_shift_in_range`).

**Why the bit must stay runtime-selectable.** The right bit is the lowest set bit of the stride
between the addresses a slice has in flight at once, which depends on the shape: for qwen's scalar
X loads the 8 concurrent rows are K elements apart — K=160 fp16 → 80 words → bit 4; K=5120 → 2560
words (bits 9, 11) → bit 9. A fixed bit is wrong for one of them.

**Software bug found with it.** `qwen-gate-up/script/gen_hash.c` capped the candidate shift at a
fixed 8, the limit for 16 banks (4 index bits below word bit 12, where the mesh-sweep alignment
makes the score exact). With 2 banks only 1 bit must fit, so the cap is now derived:
`min(log2(MESH_SWEEP/4) - log2(banks), 10)` = 10 split, 8 legacy (legacy output unchanged). At
K=5120 the old cap left every shift in 4..8 putting all 8 X rows of a core in ONE bank of the
column slice (observed in the waveform); the chooser now picks 9 (4 rows per bank).

**Measured (fleet batch `hash1`).** qwen K=5120 at shift 4: column slices `400,0`, 1.13 %
cumulative util over 114k benchmark cycles, 1,609 hold timeouts, 52 `RH STUCK` (livelock). At
shift 9: both banks used, ~99 % steady-state util. The RTL change is cycle-identical on the
validated workloads (GEMM 512x128x128 11,199; qwen K=160 81,467) with zero assertion hits.

**Telemetry.** `[MSHRU]` gained a trailing `bank_avg_x100=` field: per-bank mean occupancy ×100
over the window, per MSHR instance. A hash that parks a slice's traffic in one bank now shows as
`N,0` in any transcript. Appended last, so the existing parsers are unaffected.

## 9c. Bypass probe

`group_mshr_bypass_probe`'s `[BYP ORPHAN]` accounting now runs **only while `cfg_mshr_enable` is
set** (`mempool_group_mshr.sv`, `gen_bypass_probe`). With the MSHR off every request bypasses by
construction, so "a response with no outstanding forward" is not a finding, and it fired on every
beat of every bypassed burst because the forward side counts single-beat requests only — 2,771
lines in one 19k-cycle directed-test run, 2.7 M in a legacy sweep arm. Arming the MSHR clears the
tracking table, so a request forwarded while it was off cannot be reported by the response that
arrives after. At `MshrCfgRuntime=0` (backend builds) `cfg_mshr_enable` folds to 1 and the gate
disappears. Verified: same ELF, 2,771 -> **0** orphan lines, retval 0, identical end time.

Still open: while the MSHR **is** enabled, a bypassed *burst* (class bypassed, or a bank-full
bypass) still orphans, because the forward side does not model the burst lane law. Fixing that
needs per-beat forward accounting; the gate above removes the dominant source.

## 10. Known limits / follow-ups

- `CacheStoreUpdate` / `CacheAmoInval` (both off) assume a store sees the cached line; under
  class steering a store passes through a different slice than the line it would update.
- Channel modes with a narrow read-only request channel: a slice's 4 output lanes are 2 narrow +
  2 wide and bypass stores may only use the wide two; not the shipped mode.
- OOC synthesis of one slice is the next backend step. The slice (folds included) is the unit;
  against the campaign's elaboration line (`docs/mshr_ooc_campaign_report.md` §2):
  ```tcl
  elaborate mempool_group_mshr_slice -param "NumGroups=>16, NumTilesPerGroup=>16, \
      NumRemoteReqPortsPerTile=>3, NumRemoteRespPortsPerTile=>3, SliceId=>0"
  ```
  with the campaign define set plus `GROUP_MSHR_SPLIT=1 GROUP_MSHR_NUM=8 GROUP_MSHR_OVERFLOW_NUM=1`
  (`GROUP_MSHR_MERGE_REQS=4` as before). All eight slices are the same netlist except the constant
  `SliceId` stamped into the tag/`src_tile_id`; hardening one and replicating it needs `SliceId`
  turned into a port, which is 7 bits of constant per instance.
