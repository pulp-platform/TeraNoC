
---

## 2026-07-27 — DESIGN PLAN: ROB 64 + H1 (docs/spatz_rob64_h1_design_plan.md)

**Purpose:** the user wants two m2 loads co-resident (32 ids each = 64) WITHOUT a kernel change, and
explicitly accepted a full MetaIdWidth 5->6 widening even if it can't be hidden. 8-agent audit.

**HEADLINE: the widening is MOSTLY AUTOMATIC.** meta_id is rooted at exactly ONE place
(snitch_pkg.sv:16 RobDepth=32 -> MetaIdWidth=5 -> meta_id_t -> mempool_pkg.sv:293 -> every TCDM
struct, both FlooNoC flit metas (:419/:484), the whole MSHR). RobDepth 32->64 propagates 5->6 with
NO manual struct edits. NO floogen re-run (the generated floo pkg carries no meta_id).
COST: +1 bit on EVERY mesh link / router FIFO entry / group-boundary interface, both directions --
physically real wire area, PNR re-close required (user accepted).

**Contained-id (hide the 6th bit) is UNSOUND -- confirmed by audit AND by my own check of
mempool_group_mshr.sv:437-440:** the MSHR enforces (core,meta_id) response uniqueness via a
full-table cross-address check (req_meta_ovlp_map); aliasing two loads onto one 5-bit space is
rejected by exactly that guard the moment H1 makes them co-resident. So the plan is cleanly
full-widen, no clever mapping.

**Only THREE functional must-fix sites survive:** (1) spatz_mem_rsp_t.id is 5b today -> silently
aliases ids 32-63 at spatz_mempool_cc.sv:291 (widen to 6 in BOTH spatz_pkg.sv.tpl and generated,
else regen reverts); (2) reorder_buffer block-window mask uses BlockWords==NumWords/2, which breaks
at 64 (BlockWords=16=NumWords/4) -- generalize to a quarter-decode form, bit-identical at 32/16,
own commit first; (3) spatz_vlsu.sv:188 burst admission becomes <=256B at 64, silently admitting m4
(one m4 eats all 64 ids, starves H1) -- KEEP parameter-scaled, H1 design point stays m2.

**ONE NEW DEFECT the review caught (FF-1, must land in S1):** BypassTrackWays is keyed on
SPATZ_VLSU_DUAL_LOAD, but ROB64 ALONE breaks its depth-2 premise (one m4 = 4 bursts, and a single
m4 with a full MSHR bank overflows 2 ways -> assert $fatal). Fix: BypassTrackWays =
max(2, RobDepth/MaxBurstWords) = 4 at ROB64.

**Positional commit survives two co-resident loads** (no per-instruction id tagging): each
instruction's ROB0 id interval is contiguous, address-ordered, exactly vl/4 words, program-ordered,
so the commit-counter and ring boundaries coincide exactly.

**Area (R1+R2 ON, per core, x256):** +5150 flops/core = +1.32 MFF chip-wide (90% is ROB mem_q).
R1+R2 become near-mandatory at 64 (together keep ~620 kFF off the chip). Knob-off = bit-identical.

**Timing:** no new critical path (the address cone is untouched); two cones grow ~1 level each
(commit->VRF 64:1 muxes, rsp->ROB decoders+fanout) -- time them together. Control compares stay
2-level constant compares (T3 preserved).

**Staging:** S0 mask generalization alone (LEC gate) -> S1 ROB64 widening (must be cycle-identical
to 3589 for m2 -- same request stream; any delta is a bug) -> S1b/S1c R1/R2 -> S2 H1 (directed
tests first, A9 fence-underflow armed first). Validate ONLY on terapool_spatz4_fpu.
snitch_pkg.sv is hardware/deps -- PR call-out.

**Status:** plan written, NOTHING implemented. Awaiting user review/go.
