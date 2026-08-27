# The VLSU `vl` ceiling — what it actually guards (2026-08-27)

Investigation prompted by "why can't we just issue more 64-byte bursts?". The answer reframes the
ROB-depth decision, and it invalidates the shape of a change that looked obvious.

## The rule

`spatz_vlsu.sv:233`, inside `use_port0_burst_req`:

```systemverilog
(mem_spatz_req.vl <= (NrOutstandingLoads * MemDataWidthB))   // 256 B at ROB64
```

with the comment *"Total data must fit in one ROB batch to avoid multi-burst deadlock
(scoreboard-blocked VRF writes prevent ROB drain between batches)."*

## It is NOT about burst length

A burst is `MaxBurstWords` (16) 32-bit words = **64 B**, and long loads are already split:

```systemverilog
burst_full_bytes_req = (vl >> BurstAlignBits) << BurstAlignBits;   // BurstAlignBits = 6
burst_has_tail_req   = (burst_full_bytes_req != vl);
```

At `vl = 256 B` that is **four** 64 B bursts plus an optional tail. Issuing more bursts is what
already happens; the ceiling is not on their number.

## It is NOT about drain either — partial commit is ALREADY implemented

Both halves of what "commit each burst separately" would add are in the RTL today:

* **Writes are incremental.** The VRF write goes through a single-entry `spill_register`
  (`:1024`), formed one at a time as data arrives — not accumulated to instruction end.
* **Ids are released per beat.** `:1752`:
  ```systemverilog
  rob_pop[port] = rob_rvalid[port] &&
                  ((!mem_pending[port]) ||
                   (vrf_req_valid_d && vrf_req_ready_d && commit_counter_en[port]));
  ```
  An entry frees the cycle its element is accepted into a VRF write.

So the ROB already drains mid-instruction. There is no "wait for the whole vector" to remove.

## What it IS about: response tags

**The ROB id is the memory response tag** — which is why ROB depth moves `spatz_mem_rsp_t.id` and
`MetaIdWidth` system-wide through the group MSHR and the NoC, and why `spatz_mempool_cc` asserts the
pairing at elaboration.

The rule therefore reads: *you cannot have more outstanding words than you have distinct tags.*
Reusing a tag while its earlier request is still in flight makes a response unattributable. Raising
`NrOutstandingLoads` raises the ceiling because it adds **tags**, not buffer.

## And the deadlock it guards is real

Exceeding the ceiling means issuing in batches — issue a ROB-worth, wait for tags to free, issue
more. The hazard is that **the group MSHR can hold a response pending future requests**: that is
precisely what a hold window does. If batch 1's responses are held waiting for merge partners, and
the partner request is batch 2 which cannot issue because batch 1 holds every tag, nothing advances
until `serve_timeout` fires.

That is plausibly the same mechanism as the quiescent deadlock recorded in
`8x8_scaleup/quiescent_deadlock.md` — whose two newest instances ran the only config in the campaign
with 8191 hold windows **and** merging bypassed, so cohorts could never complete.

## The VRF grant, by contrast, cannot deadlock

`spatz_vrf.sv:89-112` is a fixed-priority **bank** arbiter (VFU > VLSU > VSLDU). `vrf_wvalid_i`
drops for the VLSU only when a higher-priority unit writes the same bank that cycle. There is no
circular path: a VFU instruction that is *writing* already has its operands and so is not waiting on
our load; one that *is* waiting is not writing. Bank conflicts are transient.

So the comment's "scoreboard-blocked VRF writes" is not the binding constraint. Tag exhaustion is.

## Consequences for the ROB decision

* "Add partial commit so we can shrink the ROB" **does not exist as a change** — it is already there.
  The real change would be *multi-batch issue with tag recycling*, whose correctness depends on the
  MSHR always releasing on a bounded timeout. That couples the VLSU to the hold-window mechanism
  that just deadlocked two arms.
* **ROB32 with `vl <= 128 B` is a coherent design point needing no new RTL** — it means KS=8 only
  (`m2`), and the decode tile policy must live within the slice floor that implies.
* Measured value of what ROB64 currently buys: H1 dual-load, **0.7-2.8% on one shape**
  (WORKLOG 2026-07-28), against **+5,150 flops/core** (+1.3 MFF at 4x4, ~5.3 MFF at 8x8), ~80% of it
  the ROB array. ROB64 alone, without dual-load, measured exactly flat.
* The 30-arm A/B/C comparison (`rob_` prefix) is running to replace that single-shape number.

**Not established:** whether the MSHR's timeout guarantees are strong enough to make multi-batch
issue safe. That is the question any tag-recycling design must answer first.
