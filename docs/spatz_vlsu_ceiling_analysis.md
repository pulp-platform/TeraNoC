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

## The deadlock it guards — CORRECTED

Exceeding the ceiling means issuing in batches: issue a ROB-worth, wait for tags to free, issue more.

⚠️ **This section first claimed the hazard was the MSHR holding a RESPONSE pending future requests.
That is wrong.** It conflated two distinct mechanisms:

| mechanism | knob | applies to |
|---|---|---|
| **request**-side hold — delay issuing to the NoC while merge partners gather | `hold_window_single` / `hold_window_burst` | **both** classes |
| **response**-side hold — withhold returned data from the cores | `serve_timeout` (`MSHR_RESP_HOLD`) | **SINGLES ONLY** |

The response hold is gated at `mempool_group_mshr.sv:3601` on `burst_len == BurstLenWidth'(1)` (and
on `RespWaitSubsSingle`). **A burst response is never withheld from the cores.** `mshr_cfg.h:64`
documents the same thing: `serve_timeout` is "response-side, SINGLE-only (RESP_HOLD / CACHED)".

For a burst load the only MSHR-side delay is on the **request** path — before a response exists to
free tags. Whether that can starve a single core of tags is **not established**: request-side merge
partners come from the group's other 15 cores, which hold their own tags and progress independently,
so the obvious circular path does not close.

**Established:** the ceiling is a tag-uniqueness rule — no more outstanding words than distinct tags.
**Not established:** that exceeding it is actually unsafe. Settling that costs a directed test
(relax the check, issue `vl > ROB*4`, see whether anything wedges), not an RTL redesign.

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

---

## MEASURED 2026-08-27 — the ceiling is NOT over-conservative. Removing it is fatal.

The directed test in §"Not established" was run. **The ceiling is load-bearing.**

### Method

`vector-burst-test` extended with an `lmul` field and five cases whose `vl` crosses the ceiling
(m2=128 B, m4=256 B, m8=512 B, m8+tail=384 B, m8 unaligned). Same ELF against three images that
differ only in the intended defines: `build_vcs_r3` (ROB64), `build_rob32` (ROB32), and
`build_rob32_noceil` (ROB32 + `SPATZ_VLSU_NO_VL_CEILING=1`).

### Baselines — the probe is trustworthy

| image | ceiling | `BURST DROPPED` at | allowed | verdict |
|---|---:|---|---|---|
| ROB64 | 256 B | 384, 512 B | 256 B (m4) | **PASS** 15/15 |
| ROB32 | 128 B | 256, 384, 512 B | 128 B (m2) | **PASS** 15/15 |

Fires on exactly the over-ceiling cases and not the at-ceiling ones, confirming the `<=` semantics.
Both pass: over-ceiling loads return correct data via the non-burst path, so the drop is invisible
in results — which is why it needed instrumenting rather than just running.

### With the ceiling relaxed: assertion A4 fires

```
Fatal: spatz_vlsu.sv:2026
  Offending '(!(rob_req_block[0] && rob_req_id[0]))'
  [spatz_vlsu] Block and single ROB id request asserted together.
$finish at cycle 14,849 -- no UART output at all
```

A4's own comment states the consequence: *"block and single id request are mutually exclusive — the
ROB serves the block and **drops the single silently**."* A dropped id request is an unattributable
response, i.e. wrong data, which is why it is `$fatal` and not a warning.

So the answer to "what assumes one-shot allocation" is **the block-reservation allocator**. Admitting
a load whose `vl` exceeds the tag budget makes it request a `MaxBurstWords` block *and* a single id in
the same cycle, which the ROB cannot serve.

⚠️ **Read `CMS WARN` carefully here.** The relaxed run shows 508 — but the **passing** ROB32 baseline
shows **1,477**. It is not a failure signal for this workload; the discriminators are the missing
UART verdict and the `$fatal`.

### What this does and does not settle

* **Settled:** `vl <= NrOutstandingLoads*MemDataWidthB` cannot simply be deleted. With
  `SPATZ_VLSU_BLOCK_ALLOC=1` (every image here) it protects an allocator invariant.
* **Not settled:** the assertion lives inside `if (BlockWords > 1)`. Whether the one-id-per-cycle
  fallback walk (`BLOCK_ALLOC=0`) tolerates an over-ceiling `vl` is untested — but that path costs
  ~18 cycles per burst to allocate, so it trades the thing the ceiling buys.
* **Therefore:** a small ROB *and* a high ceiling needs the allocator taught to split one load across
  several block reservations, not a deleted check. That is real design work, not a knob.

`SPATZ_VLSU_NO_VL_CEILING` stays in the tree, default 0, as the reproducer.
