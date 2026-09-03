# PNR re-close — what changed, 2026-09-03

Hand-off note for the backend flow after adopting the `spatz_vpu` VLSU/ROB redesign
(`docs/spatz_vpu_burst_adoption_review.md`, branch `zexin/teranoc_spatz_mshr` +
`working_dir/spatz` @ `232acc8`).

**Read §4 first — the re-close splits into two parts, and only one of them is ready.**

---

## 1. The interface change: `MetaIdWidth` 7 → 5

`snitch_pkg.sv:26-27`

```systemverilog
localparam RobDepth     = `ifdef SPATZ_VLSU_ROB_DEPTH `SPATZ_VLSU_ROB_DEPTH `else 32 `endif;
localparam MetaIdWidth  = `ifdef TARGET_SPATZ idx_width(RobDepth) `else … `endif;
```

`spatz_vlsu_rob_depth` went **128 → 32**, so `MetaIdWidth` goes **7 → 5**. `meta_id_t`
(`mempool_pkg.sv:281`) reaches **every TCDM struct and both FlooNoC flit metas**, so this is a
link-width change across the whole mesh — it **un-does** the ROB64 → ROB128 widening that the
previous re-close absorbed.

| | ROB128 (before) | ROB32 (now) |
|---|---:|---:|
| `MetaIdWidth` | 7 b | **5 b** |
| `floo_tcdm_resp_meta_t` + payload | ~63 b | **~61 b** |

The **−2 b delta is exact**; the absolute flit widths above are computed from the struct fields
(`data` 32 + `wen` 1 + `meta_id` + `core_id` 3 + `tile_id` 4 + `src_id`/`dst_id` + `last` 1 +
`mshr_tag` 7) and depend on `group_xy_id_t`, so treat them as indicative until dumped from the
elaborated design. Field widths verified against `mempool_pkg.sv`:
`tile_core_id_t = idx_width(NumCoresPerTile*NumDataPortsPerCore) = idx_width(5) = 3`,
`tile_group_id_t = idx_width(16) = 4`, `MshrTagWidth = idx_width(65) = 7`.

Where the 2 bits land:

* one `meta_id` per **narrow-request** flit and one per **response** flit, on every mesh link,
  in both directions;
* every router input/output FIFO carrying those flits (depth 2, five directions);
* `mempool_group_mshr.sv` `sub_reqs[].meta_id_base` — 64 entries × 16 merge slots × 2 b =
  **2,048 b per group** → **32 kb at 4×4**, **128 kb at 8×8**;
* `tcdm_id_remapper` id tables.

**This part is final and independent of everything in §4.** If the re-close is being scheduled
around link widths, it can start now.

## 2. Inside the replicable unit (`mempool_group_floonoc_wrapper`)

Per Spatz core, exact flop counts (structural; no netlist in this repo):

| | before | after | Δ |
|---|---:|---:|---:|
| reorder buffers (`mem_q`, `valid_q`, `dummy_q`, pointers, `status_cnt_q`) | ROB0=128 + 3×ROBN=16 | uniform 4×32 | |
| — data + status subtotal | 6,022 | 4,433 | **−1,589** |
| `burst_odd_expected_q` (TwinROB0 parity bitmap) | 128 | 0 | **−128** |
| generation tag (`entry_gen_q`, `gen_q`) | 153 | 0 | **−153** |
| `dummy_q`, `pad_bytes_q`, `burst_total_q` (new) | — | +145 | **+145** |
| **reorder-buffer total** | **6,150** | **4,433** | **−1,717 (−28%)** |
| VFU word-parallel tree reduction (new) | — | — | **+363** |
| **net per core** | | | **≈ −1,354** |

Combinational, per core: the ROB read head is a `NumWords:1 × DataWidth` mux, and depth enters it
linearly — **9,568 → 3,968** 2:1 mux cells (**−5,600**, ≈ −14 kGE at ~2.5 GE each), because
TwinROB0's second 128:1 head disappears and the remaining four heads are 32:1 rather than one
128:1 plus three 16:1. Added: a 128-bit variable shifter for the tree reduction (7 select bits)
and its combine stages.

The timing-critical `id_valid_o → mem_req_lvalid` path is **unchanged** — still derived from
`status_cnt_q`.

## 3. Build

Both backend flavours inherit the new settings through `?=`; verified with `make -n`:

```
terapool_spatz4_fpu_backend_4x4   SPATZ_VLSU_ROB_DEPTH=32  SPATZ_VLSU_BURST=0
terapool_spatz4_fpu_backend_8x8   SPATZ_VLSU_ROB_DEPTH=32  SPATZ_VLSU_BURST=0
```

`SPATZ_VLSU_ROBN_DEPTH` **no longer exists** — the define was deleted, not defaulted, because the
four reorder buffers must now be the same depth (the single base id every burst beat is derived
from is only valid while their allocators agree). A stale `spatz_vlsu_robn_depth=…` on a command
line is silently ignored.

**Still open from the previous review** (`docs/mshr_spatz_ppa_review.md`): confirm the flow passes
`bender script … -t synthesis` so `TARGET_SYNTHESIS` is defined. Nothing in this repository sets
it, and it excludes ~64 b/entry of assertion-only state in the MSHR — **65,536 flops at 4×4,
262,144 at 8×8**. Worth more than anything else in this note.

## 4. ⚠️ Why this re-close is provisional

**`spatz_vlsu_burst=0` today** (`config/config.mk`), so the VLSU emits no burst requests and the
burst datapath **const-folds out of the netlist**: the per-lane burst allocator (`burst_alloc_q`,
`burst_len_q`, `burst_alloc_cnt_q`, `burst_base_id_q`, `burst_total_q`) and the block-reservation
window in all four reorder buffers all sit behind `use_port0_burst_req`, which is constant 0.

That gate exists because the VLSU now distributes a burst's beats across its four reorder buffers
and **the memory side does not yet deliver them that way** — the tile-side lane retag is not
implemented (`docs/spatz_vpu_burst_adoption_review.md` §5). `mempool_tile.sv` carries an
elaboration `$error` on the pair, verified firing (`vopt` exits 2).

So:

* **§1 and the reorder-buffer half of §2 are final** — depth, `MetaIdWidth`, the deleted
  generation tag and the removed TwinROB0 second port do not depend on the gate.
* **The burst allocator and block reservation are missing from any netlist built today**, and
  will come back when the retag lands. Hundreds of flops per core plus four block-reservation
  windows — modest next to the arrays above, but not nothing for timing.
* `dummy_q` and `pad_bytes_q` **do** survive the gate: the non-burst padding path
  (`pad_fire`) is not gated on burst emission.

**Recommendation:** start the re-close on the link/interface change now, and treat area/timing
signoff as a second pass once `spatz_vlsu_burst=1` is unblocked. Do not tape out a
burst-disabled netlist as final.

## 5. Provenance

- Spatz: `working_dir/spatz` @ `232acc8` (22 commits from `bfd2bf4`), authorship preserved from
  `msc26f31/spatz_vpu-teranoc`.
- Integration: `zexin/teranoc_spatz_mshr` — `7e340653` (`snitch_lsu` `lsu_pwrite_o`),
  `cd07439a` (depth + gate + tripwire).
- Verified: `make compile` clean; **full 4×4 elaboration `vopt` exit 0**; tripwire proven to fire
  at `spatz_vlsu_burst=1`. `hardware/generated/` is shared and mesh-specific — it was backed up,
  regenerated for 4×4, and restored to 8×8, byte-identical to the originals (checked twice; the
  restore is fragile, always re-verify `NumMeshX` after any floogen run).
- **Not yet simulated.** No cycle counts or correctness runs on this state.
