# Group MSHR PPA — next-phase plan

| | |
|---|---|
| Date | 2026-08-13 |
| Branch | `zexin/mshr_ppa` @ `37177818` (3 commits ahead of `zexin/teranoc_spatz_mshr` @ `87e9446c`) |
| Inputs | `tsmc7/docs/mshr_ppa_review_2026-08-13.md` (23 confirmed findings) + our own verification |
| Target | `terapool_spatz4_fpu_backend_4x4`, 256 cores / 16 groups |

## The one thing that decides the ordering

**FC Presto has not finished elaborating.** It ground >12.5 h with its log's last flushed lines
inside `mempool_group_mshr.sv`. Until it completes there is **no `report_timing`, no area report,
and no netlist** — so every timing and area item below is ranked on *structural* argument, not
measurement.

That makes the sequencing obvious: **do the work that makes elaboration finish first.** Phase A is
not hygiene; it is the unblock. Everything in Phases B and C should be re-ranked once the tool
produces real numbers.

## Established facts (what we actually know)

| Fact | Evidence |
|---|---|
| opt1 head-scan hoist is bit-identical | `4412949d`; 35/35 periods identical, 34,715 cyc |
| opt2 (`DrainFromQ`) is **faster**, not a regression, on 1024x128x128 | 60,447 → 59,548 cyc, **-1.49%**; same ELF `efe002ef`, define-diff verified |
| The drain2 hoist **is safe** (earlier call reversed) | PD2 has two consecutive (tile,port) loops — select `:3507-3581`, drive `:3583-`; `beat_pending2` is cleared only in the drive loop, and the select loop writes nothing the scan reads |
| `req_in` spill is data-path redundant | tile already has `spill_register` (`mempool_tile.sv:838`); only two wire assigns between them (`mempool_group.sv:216`, `:569`) |
| `resp_out` spill is **not** removable | its consumer is a `fall_through_register` (combinational when empty), and `:1067-1072` documents it as deadlock-relevant |
| `util` is occupancy, not work | samples `spatz_vfu.fpu_busy_q` (`tb_fpu_util.svh:50-54`); two runs of the same ELF differed by +1.85% busy — **completion cycles are the verdict** |

## Phase A — unblock elaboration (all bit-identical)

Batch these into **one commit and one equivalence run**. Every item is provably function-preserving,
so the run must come back bit-identical; if it does not, the batch has a bug and gets bisected.

| # | Change | Site | Removes |
|---|---|---|---|
| A1 | Hoist the **drain2** entry-invariant predicate (the other half of F2) to just before `:3507` | `:3531-3547` | 8,192 predicate instances/group |
| A2 | Delete `drain_count`, `subreq_claimed`, `resp_mshr_id_dbg` (write-only, zero readers repo-wide) | `:673`, `:823`, `:605` + write sites | ~96 dynamic-index RMW sites |
| A3 | Generate-guard `mshr_hit_req` scatter and `victim_rr` on `CacheReclaimable` (their only readers are in the `CacheReclaimable=0` folded branch) | `:1611-1622`, `:2863-2870` | ~64 dynamic bit-sets + 32 dead flops |
| A4 | Delete the `DrainMultiPort==0` branch — the parameter is hardwired `1'b1` (`:47`), never overridden, and `PD2` makes `0` an `$error` (`:119-120`) | `:3615-3689` | 13 dynamic refs × 64 iterations + the `% MshrNum` chain |
| A5 | Narrow the `int` scratch temps to natural width; replace `%` with truncation; single-shifter rotate `({cand,cand} >> base)` | `:2683-2697`, `:3401-3404`, `:3415`, `:3432`, `:3549-3552`, `:3563`, `:3566` | the VER-318 flood + ~384 signed 32-bit modulo networks |

**A5 needs a guard the file does not currently have.** `:2922` only *asserts in a comment* that the
moduli are powers of two. Add an `$error` in the existing config-check style (`:113-122`) for
non-power-of-2 `MshrNum` / `MshrWaysPerBank` before relying on truncation.

**Also fold in now** (already partly done): `bank_scan_w` introduced by opt3 is an `int` with a `%` —
the exact A5 anti-pattern. It was committed as-is deliberately so the tested code and the committed
code match; fix it inside A5.

Expected: no PPA change in the final netlist (DCE removes most of it anyway) — the entire payoff is
elaboration time and warning hygiene. That is the payoff we currently need.

## Phase B0 — opt3 stage 2 (in flight, gated on its own measurement)

**opt3 as committed (`970d0cd0`) buys no area.** It is a behavioural model: it masks the existing
64-wide drain selector with `drain_published` rather than narrowing it to 16. That is deliberate —
it prices the throughput cost before any structure is committed to — but it means the work is only
half done, and the committed half is the half with no payoff.

| Step | State | Gate |
|---|---|---|
| B0.1 | `opt3off` equivalence run | in flight; must be **bit-identical** to 34,715 or the masking is not inert |
| B0.2 | `opt3on` across all four GEMM shapes | not started; needs B0.1 to pass first |
| B0.3 | **Narrow the select tree**: 16 bank-published candidates instead of 64 entries — the actual area win | only if B0.2's throughput cost is acceptable |

**The risk is real, not a formality.** Publishing one entry per bank caps *distinct entries drained
per cycle* at `MshrBankNum` (16) against up to 32 response ports. Multicast survives — an entry is
published, not a sub-request, so several ports can still drain different subscribers of the same
entry — but a workload whose ready entries cluster in few banks will throttle. `1024x128x128` is the
most informative shape here: it is the most MSHR-pressured of the four and therefore the most likely
to expose the cap.

**If B0.2 shows an unacceptable cost**, the fallback the design discussion already identified is
*two* candidates per bank rather than one, which doubles the cap to 32 (matching the port count)
while still cutting the selector from 64 to 32 inputs. That is a smaller area win for a much smaller
throughput risk, and it is the version to fall back to rather than abandoning the idea.

## Phase B — area (bit-identical or provable)

Re-rank after the first real area report. Ordered by confidence × size.

| # | Change | Expected | Risk |
|---|---|---|---|
| B1 | F8: swap both drain arbiters to the allocator's mask + LSB-isolate form (`:1762-1777`); select `elig_all[drain_win_e]` instead of re-evaluating the predicate on a 64:1 struct read | ~350-450k GE/group pre-opt | low — in-file precedent with a transferable equivalence argument (`:1717-1722`) |
| B2 | F7: meta-overlap mask AND/OR-reduce → two-sided modular range test | ~129k → ~72-92k GE/group (**~2x, not the report's 2.6x**) | medium — needs the exhaustive proof over 32 bases × 32 lens, matching `:986-987`'s precedent |
| B3 | F22: per-way write enable on `bypass_track_q` | 1,088 flops/group stop clocking unconditionally | low — `d` defaults to `q`, so enable is bit-identical |
| B4 | F15: `resp_buf` → latch-based SCM | ~2-2.4k DFF-area-eq/group | **backend-flow risk** — hold-time fixing + scan insertion; defer until timing closes |

Explicitly **not** doing: SRAM for `resp_buf`. The drain needs 32 concurrent asynchronous read ports;
no macro provides that. The report is right to rule it out.

## Phase C — timing (blocked on the timing report)

| # | Change | Why it waits |
|---|---|---|
| C1 | F11: merge RMW → parallel-rank (prefix-popcount) form | Claimed bit-identical. **Prerequisite for C2.** |
| C2 | Bypass the `req_in` spill (`SpillReqIn=0`) — **5,312 flops/group, ~85k cluster** | Data path is genuinely redundant, but bypassing exposes the tile's spill to C1's up-to-32-deep chain. Do C1 first, then re-measure. |
| C3 | F9: replay walker → per-lane parallel first-match | The worst structure in the module (~400 logic levels into the NoC request register). Bit-identical per the in-file precedent at `:1710-1722`. |

**Do NOT** bypass `resp_in` (the report's other half of "bypass both inputs"). Its data side is
shallow, but bypassing composes the router output xbar onto the MSHR capture logic, which per F10
feeds *through* to `resp_out` in the same cycle. That lengthens an already 40-55-level NoC-in →
tile-out arc. This is the one place the report's recommendation is wrong.

**`req_out` and `resp_out` stay.** `req_out` is the only register between F9's walker and the NoC;
`resp_out` is load-bearing for deadlock.

## Phase D — config and process decisions (need your call)

| # | Decision | Status |
|---|---|---|
| D1 | `group_mshr_hold_window_burst`: 2047 (backend) vs 255 (shipped) vs **0** | **Open, and the data conflicts.** 0 removes F9's walker entirely — no RTL change, whole timing hazard gone. But the 4x4 sweep called the window net-negative (3836→3986/4209/4229) while the 8x8 matched pairs found 511 **+81% worse** than 1023. Needs a decision, not a default. |
| D2 | `group_mshr_enable_stats=0` for PPA runs | Cheap insurance. The stats blocks are guarded only by a bare `// pragma translate_off`, and this file's own history (`:2330-2338`) records that guard style leaking into synthesis once. |
| D3 | After elaboration: `sizeof_collection [get_cells -hier *stat_*]` | If non-zero, D2 was not optional. |
| D4 | `backend_4x4.mk` comment says hold=511 while the assignment is 2047 | Stale comment; fix with D1. |

## Verification protocol (non-negotiable — every one of these has burned us)

1. **Matched pair or nothing.** Two builds may differ by exactly one change. The R-MCAST
   investigation produced three wrong answers because three commits separated the pair and I checked
   only the define diff — *defines are not the configuration; the source tree moves underneath.*
2. **md5 the ELF in every arm.** A whole day of PPA and attribution data was invalid because the
   arms preloaded a different binary than the reference.
3. **Verify the define actually reached the compiler**, not just the make command line — grep the
   build log for `GROUP_MSHR_*=<value>`. The knobs were nested under an unrelated guard until
   `970d0cd0`; a config without the prescaler would have silently dropped them.
4. **"Bit-identical" means every period** of util/cum/busy/grp_max/grp_min, not the final number.
5. **Score on completion cycles.** `util` is FPU-lane occupancy and is not conserved across runs of
   the same workload.
6. **Never `git checkout -- .`** in a cleanup path. It destroyed uncommitted user files on
   2026-08-13. Cleanup paths name files explicitly.

## What this plan does not claim

- **No timing or area measurement exists yet.** Every gate-count and logic-level figure is the
  review's structural estimate. Several of its numbers were found exaggerated on verification
  (F7's 2.6x is ~2x) and several understated (F1's modulo count, F5/F6's flop widths).
- **~6 of the review's findings were never verified** — their verify agents died on an API error.
  One of them ("unnecessary async reset on ~80% of entry flops") would be a large area item if true
  and is worth one manual pass before it is either used or dismissed.
- **opt3 ON has never been measured** (see Phase B0), and opt3 as committed buys no area at all.
- **opt2's PPA benefit is likewise unmeasured.** Its cycle effect is now known to be shape-dependent
  — `256x512x256` -0.40% and `1024x128x128` -1.49% (both faster), while `512x512x512` and
  `128x1024x512` are trending the other way. But cycles were never the point: opt2 exists to shorten
  the drain cone by removing its dependence on the same-cycle allocate/merge logic, and that benefit
  appears only in a timing report. Keep the default `off` and enable per shape until there is one.
