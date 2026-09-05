# Group-MSHR pipelining: stage cut design

**Status 2026-09-05.** Draft. The cut point below is **provisional** — it is justified by a
structural argument plus three measured leaf depths, but the number that decides it (the depth of
each proposed stage on the current netlist) is still being measured. Do not write RTL against this
document until §7 is filled in.

---

## 1. Why a cut is needed at all

The block is **12,855 flops with ~1.05M cells of combinational logic between them** — 66–100 cells
per flop, where a well-pipelined design runs 5–20. It is a single combinational stage: everything
from one set of registers to the next.

F1–F6 reduced depth and area *within* that structure (−33.5% instances) but did not change it, and
no amount of local restructuring will. The 800 MHz target allows roughly **31–37 gates per stage**
(1.25 ns, less ~0.25–0.41 ns of setup + POCV + clock network, at the 13.4 ps/point the 500 MHz block
run measured). One stage cannot hold the whole MSHR.

Register retiming does not help: it relocates existing flops and cannot create a stage. Observed
directly — `fix2_head_8p0` passed `logic_opto / Register Retiming` with the instance count unchanged
at 1,078,569.

## 2. The cut: LOOKUP | UPDATE

```
S1  LOOKUP + ARBITRATE                    deep, global
    req_decode -> bank hash -> req_addr_hit_way (64 entries x 48 lanes)
    -> free_way -> bank_arb x2 -> winner per bank
    -> issue the NoC request, drive req_in_ready
    ================ pipeline register: the per-bank records ================
S2  UPDATE                                shallow, local
    apply alloc/merge/byte-merge/replay/invalidate
    + the entire response and drain path
    -> all mshr_d writes
```

**The load-bearing property is that every `mshr_d` write stays in one stage.** The obvious
alternative — splitting request path from response path — does not have it. Sixteen entry fields are
written by *both* paths (`state`, `sub_reqs`, `sub_reqs_num`, `beats_left`, `beat_seen`,
`beat_done`, `beat_pending`, `beat_pending2`, `beat2_armed`, `resp_buf_cnt`, `resp_buf_rd_ptr`,
`hold_cnt`, `cacheable`, `valid`, `base_addr`, `burst_len`), so straddling them costs a second write
port on a 64-entry array plus a per-field merge rule. This cut avoids that entirely.

It also cuts where the depth is. The pre-fix critical path was
`mshr_q_reg[*].base_addr[*] -> mshr_id_en[*]`: registered address out, compare against all ways,
hit/miss, free-way select, two 32x16 arbiters, allocation decision, clock-gate enable. That whole
chain is S1. What remains in S2 on the request side is "write the entry you were told to write" — a
`MshrWaysPerBank:1` select and a field update.

## 3. What crosses the register

**Already built.** F5 (`cfa44e1e`) introduced per-bank records so the door's entry writes are
applied once per bank; those records are exactly the pipeline payload. Registering them is the
change. Declarations at `mempool_group_mshr.sv:1921-1941`.

| record | fields | bits/bank |
|---|---|---:|
| `mgb_*` (merge) | `v, way, tile, port, core, meta` | ~17 |
| `agb_*` (alloc) | `v, way, addr, grp, len, tile, port, core, meta` | ~42 |

At `MshrBankNum = 16`: **~944 flops, +7.3%** on the existing 12,855. (`addr` is `tcdm_addr_t`
= `TCDMAddrMemWidth + idx_width(NumBanksPerGroup)` ~ 16 b, and `core` is `tile_core_id_t`; both
should be confirmed against the elaborated design rather than taken from this table.)

`mgb_slot` does **not** cross — it is recomputed from `mshr_q`, and must continue to be, or the
merge slot would be stale by a cycle.

## 4. The hazard, and why it is cheap here

A lookup in S1 at cycle *N+1* compares against `mshr_q`, which does not yet contain the allocation
recorded at cycle *N*. Naively that allocates a duplicate entry for a line already in flight.

**The bank hash makes the fix trivial.** `req_bank = mshr_bank_of(req_addr_key, tgt_group_id)`, so a
given line always hashes to the same bank, and with one allocation per bank per cycle there is **at
most one pending record per bank**. An incoming lane therefore compares its `addr_key` against the
pending record of *its own bank only*:

* **48 comparators, one logic level** — not a 16-way CAM per lane.
* On a match: treat as merge-into-pending, or stall the lane. Stalling is the conservative first
  implementation and costs at most one cycle on a genuine same-line collision.

A design whose bank were address-independent would need the full CAM, and the bypass would rebuild
the depth the cut just removed. This is the property that makes the cut affordable.

## 5. Cost

| | |
|---|---|
| allocation latency | **+1 cycle** |
| merge / bypass latency | unchanged, if the NoC request is issued from S1 (it does not depend on the entry write) |
| throughput | unchanged — still one alloc + one merge per bank per cycle |
| sequential area | ~+944 flops (+7.3%) |
| combinational area | expected slightly down (the cut breaks long chains the optimiser was buffering) |

The throughput cost is paid **per allocation and never on a merge**, which is why the baseline in §6
sweeps M.

## 6. Measurement plan (running)

Pre-pipeline baseline on `b07ad73f`, 4x4 / `terapool_spatz4_fpu`, one arm per shape:

| tag | shape | why |
|---|---|---|
| — | fp16 256x32x256 | **2,923** — already measured (`gfw3`/`gfw4`) |
| `bl_n64` | fp16 256x64x256 | small N, high reuse |
| `bl_128` | fp16 256x128x256 | mid |
| `bl_256` | fp16 256x256x256 | square |
| `bl_512` | fp16 512x64x256 | wide M, small N |
| `bl_p512` | fp16 256x512x512 | large N and P |
| `bl_m1k` | fp16 1024x256x256 | allocation-heavy |
| `bl_m2k` | fp16 2048x256x256 | most allocation-heavy |
| `bl_f32` | fp32 256x32x256 | precision control |

M is the axis that matters: more rows means more independent A fetches and less sharing, so the
+1-cycle allocation latency should show up as a rising cost with M and be invisible at 256x32x256.
**If the cost does not rise with M, the model is wrong and the result should not be trusted.**

> **ELF trap.** `s8_*` ELFs are built `-DNUM_GROUPS=64 -DNUM_CORES=1024` (8x8) — 248 of the 785
> under `hardware/elf/`. On this 4x4 config they produce no error, just wrong addresses and a wrong
> work split. Every ELF above was verified `-DNUM_GROUPS=16 -DNUM_CORES=256` from its own
> `/tmp/claude-620771/gemmbuild_*.log` before launch. Verify, do not infer from the filename.

## 7. What is NOT yet decided  <!-- FILL THIS IN BEFORE WRITING RTL -->

**The stage depths.** Measured so far, at TCK 0.2 ns under the corrected SDC:

| block | path points | ~gates |
|---|---:|---:|
| `free_way` | 8 | 4 — *closes at a 0.2 ns period; not a timing consideration at any clock* |
| `req_decode` | 14 | 7 |
| `bank_arb` | 16–18 | 8–9 |

Those are S1's submodules, not S1. The parent's `req_addr_hit_way` compare, hit reduction and
decision logic are not in any of them, and **S2's depth has never been measured** — it keeps the
entire 400-line drain loop (`mempool_group_mshr.sv:2833-3239`).

Estimated S1 ≈ 30 gates (7 -> hash ~3 -> compare ~6 -> reduce ~2 -> `free_way` 4 || `bank_arb` 9 ->
decision ~3). Against a 31–37 gate budget that is *at the edge*, not comfortable.

**Two things could move this cut:**

1. **If S2 is deep**, one cut is not enough and the drain loop needs its own — probably between
   drain-select (reads `mshr_q`) and drain-apply.
2. **The boundary may dominate, not the cone.** `fix2_head_8p0` reports `R2R-COST = 0.00` at 8 ns
   and `fix2_head_2p0` reports `46.95` at 2 ns, against SETUP-COST of 115,331 and 216,090. If
   register-to-register really is near-clean and the cost is boundary paths, the depth problem is at
   the **8,988-port interface** and a reg-to-reg cut buys much less than this document assumes.
   Caveat: that reading is from the first `logic_opto` row before optimisation, the OOC boundary
   budget (15% of period each side) is artificial, and `logic_opto` is known pessimistic on this
   design (−19.517 pre-placement vs −9.436 placed).

**The measurement that settles both** needs no RTL change — inserting a register splits an existing
path, so both stage depths are already in the netlist:

```tcl
# S1
report_timing -delay_type max -max_paths 5 -input_pins -nets \
  -from [get_pins mshr_q_reg*/CK] \
  -to   [get_pins {i_alloc_arb/win_oh_o* i_merge_arb/win_oh_o* i_free_way/free_id_o*}]
# S2
report_timing -delay_type max -max_paths 5 -input_pins -nets \
  -from [get_pins {i_alloc_arb/win_oh_o* i_merge_arb/win_oh_o* i_free_way/free_id_o*}] \
  -to   [get_pins mshr_q_reg*/D]
```

Automated as `ooc/depth_split.tcl`, armed to fire when `fix2_head_8p0` saves its `logic_opto` block.
A saved block can come back with **no scenario enabled for setup**, in which case `report_timing`
returns an empty report that reads like "no violations" — the script enables setup explicitly and
prints the timing-path count first.

## 8. Verification contract

Per the F-series contract, unchanged:

1. **Elaborate at both configurations** — sim (`merge_reqs=16`, `cfg_runtime=1`, `enable_stats=1`)
   and PnR (`merge_reqs=4`, `cfg_runtime=0`, `TARGET_SYNTHESIS`). `MshrMergeReqs` is an elaboration
   constant; a pipeline can be correct at 16 sub-request slots and broken at 4.
2. **Assertions live**, under QuestaSim or VCS — never Verilator, never `TARGET_SYNTHESIS`. The ones
   that bear on this change: `mshr_entry_in_its_bank` (the bank-hash property the §4 bypass relies
   on), `no_alloc_while_resp_landing`, `cached_entry_holds_data`, `resp_src_exclusive`.
3. **A new directed test for the §4 hazard**: two same-line requests in consecutive cycles, and the
   same across a bank-full boundary. This is the case the cut introduces and nothing existing covers.
4. **Cycle comparison against the §6 baseline**, same ELFs, same config — the pipeline is *not*
   expected to be cycle-identical, so record the delta per shape rather than asserting equality.
5. **Standalone synthesis** at the PnR config, and the §7 segmented report re-run on the pipelined
   RTL to confirm both stages landed inside budget.
