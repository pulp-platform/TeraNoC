# Known issues affecting the 8x8 campaign

Recorded 2026-08-22, at 8 of 248 arms complete. **Decision: do NOT re-run this campaign for any
of these.** The performance data is unaffected; these bound how the results may be read, and the
software ones are to be fixed for the *next* campaign.

---

## 1. RTL: `resp_buf` clock-gate assertion, fp16 only — OPEN

```
Fatal: mempool_group_mshr.sv:2258
  MSHR clock gate dropped a resp_buf write: entry=0 slot=0
```

`$fatal`, so it terminates the run — but **after** the benchmark has printed its cycle count and
`[FPU FINAL]`. Cycle counts and FPU utilisation are therefore valid on affected arms; the
spotcheck and clean shutdown are lost.

**Observed:** fp16 4/4, fp32 0/4. Two matched pairs (`512x64x512`, `512x128x512`) differ only in
precision. `2048x128x128` adds a third A-share degree and still fires — so it tracks **precision**,
not shape, A-share degree, or simulator.

**Why a store reaches the MSHR at all** (the natural objection is that stores bypass it): a store
never *allocates* an entry, but with `EnableRespCache` the MSHR **snoops single-word stores against
its response cache** (`mempool_group_mshr.sv:3332`). On a hit it byte-merges the store into the
cached line — *"a sub-word store must update only the enabled byte lanes and keep the existing
cached bytes"* — and that merge writes `resp_buf`, which is what the assertion guards. fp16 packs
two values per 32-bit word and so issues **sub-word** stores that fp32 never does. A second path
(`:3610`) invalidates a `RESP_HOLD` line on a store hit.

**This is NOT the already-fixed case.** Commit `7e58d03c` closed exactly this for the store
cache-hit merge and its comment names the same message text at `entry=8 slot=0`. That fix landed
**2026-08-21 17:25**; the 8x8 VCS image was built **2026-08-22 04:46**, so the campaign runs the
fixed RTL and still fires, at `entry=0 slot=0`. **There is a second, still-open path.**

Ruled out so far: only two sites write `resp_buf` (store byte-merge `:3349`, response capture
`:3569`) and both raise the enable; all five whole-entry clears (`mshr_d[x] = '0`) raise
`mshr_wr_all` on the next line; there is no whole-array `resp_buf` assignment.

**Cheap reproducer:** `512x64x512` fp16 vs fp32 — same shape, one variable, ~10 min each.

### Proposed SW workaround: disable the group MSHR after the benchmark — NOT YET IMPLEMENTED

The assertion fires in the **epilogue**, after the measured region. Nothing after the benchmark
needs the MSHR: the spotcheck reads a handful of words and the merge/cache machinery only exists to
help the kernel. Turning the MSHR off once the timed region closes makes the epilogue bypass it
entirely, so the store-snoop / `resp_buf` path is never exercised there.

Feasibility checked against the RTL — it works, with two constraints:

* **The CSR exists and is writable at runtime.** `MSHR_CSR_ENABLE` is index 0
  (`software/runtime/mshr_cfg.h:27`), and `group_mshr_cfg_runtime = 1` in
  `config/terapool_spatz4_fpu_8x8.mk:557` — confirmed present in the built image as
  `GROUP_MSHR_CFG_RUNTIME=1`. Without that define `cfg_mshr_enable` is hardwired to 1
  (`mempool_group_mshr.sv:521`) and the write does nothing.
* **Clearing it is ONE-WAY.** `mempool_group_mshr_cfg.sv:152` is
  `if (!wr_data_i[0]) cfg_d.enable = 1'b0;` — the CSR can only ever be cleared, never set back to
  1. Fine for a post-benchmark disable (nothing needs it again), but it cannot be used to bracket a
  region, and a multi-iteration harness would run every later iteration un-merged.
* **There is NO busy-guard on this CSR.** `mshr_busy_i` refuses a `BANK_SHIFT*` write while the
  MSHR is non-empty, but ENABLE has no such check, so the write is accepted with entries still in
  flight. Disabling sets `cfg_bypass_single`/`cfg_bypass_burst` (`:547-548`), which steers *new*
  requests around the MSHR; already-allocated entries still have to drain. **Drain first** — a
  fence after the last timed access, before the CSR write — and verify that in-flight entries
  complete rather than being stranded.

Caveat: this hides the symptom, it does not fix the RTL. The dropped `resp_buf` write is a real
bug and could bite a kernel that byte-merges inside the timed region. Do both: the workaround to
get clean full-length runs and a working spotcheck, and the RTL fix for the underlying path.

---

## 2. SW: correctness coverage is far thinner than the probe implies — FIX LATER

### fp16 checks GROUP 0 ONLY
The `[SPOT]` loop is written to cover `g = 0 .. active_groups-1` (64 at 8x8) but every observed arm
emits exactly **one** line. Core 0 wedges on the second iteration, reading group 1's remote C
address, and never returns. Proven independently of the assertion: an assertion-free 4x4 run idled
**840,000 further cycles** (113k -> 953k) after its single line, every counter at zero.

The probe's own comment says it samples per-group so that *"a single bad group is identified rather
than merely detected -- the failure mode that actually happens here (a group desynchronising)"*.
Covering only group 0 means **the failure it was written to catch is the one it cannot see**.

### fp32 has NO correctness signal at all
All **150** fp16 apps compile the probe; **0 of 122** fp32 apps do. fp32's only other check,
`MATMUL_VERIFY`, is off by default because `verify_matrix()` sums each row of C on the scalar FP
path and wedges core 0.

**Consequence for this campaign:** fp16 arms are verified on 1 group of 64; fp32 arms are
performance data only. Do not present either as a verified result.

**Fix later (software only, no RTL change):** make the `[SPOT]` loop not wedge past group 0, and
compile a probe into the fp32 apps. Both need a rebuild + re-run, which is why they are deferred.

---

## 3. badist: cancelling a never-started job can DISPATCH it — do not "clean up" a dead batch

Observed 2026-08-22 on batch `s8q`. Its controller was killed and its 105 queued jobs cancelled at
06:55 so the arms could be resubmitted as `s8q2` with a higher parallelism. The cancels reported
success but wrote **no ledger record** — the jobs still read as "never-started", so there is no way
to confirm from the ledger that a cancel stuck.

Then jobs from that cancelled set began *starting*, hours later, each one a second copy of an arm
`s8q2` was already running. **Both copies deliver to the same `hardware/s8_<arm>/` run dir**, so
this is a data-integrity problem, not just a wasted licence.

The trigger was our own cleanup. Dispatch records `0065`-`0069` are all `attempt=1` and were
written **13:30:08-13:31:46**, exactly while a second cancel loop was running over the same batch.
Killing a duplicate then produced a retry (job `0061` reached `attempt=3`), so the cycle was:
cancel -> dispatch -> duplicate -> kill -> retry -> duplicate.

**The mechanism, measured (an earlier guess here was wrong).** It is not the cancel: dispatch
records appeared at 14:33:25 and 14:48:22, exactly 15 minutes apart — the dedup loop's interval,
after the cancel had already been removed from it. **Removing a running job frees a slot and badist
immediately dispatches the next pending job of that batch into it.** Any removal refills the queue,
so the batch cannot be drained by killing its jobs faster.

**What to do instead: leave a superseded batch alone and let it drain.** It is self-limiting —
88 undispatched jobs at ~2 per dedup cycle is ~11 h, after which s8q is exhausted and quiet. The
cost is ~2 slots of ~230 held for up to 15 minutes each, under 1% of capacity.

**Why not cancel the whole batch:** its 60 originally-running arms are NOT in `s8q2` (that was
built only from the never-started set), so a batch-level cancel would kill 60 unique arms to save
a 1% overhead.

**Collision risk is low but not zero.** Both copies write `hardware/s8_<arm>/`, so a duplicate that
*completed* before the next dedup pass could overwrite a good result. The fastest arm measured is
5,315 cycles ≈ hours of wall-clock at 12-19 cyc/s, against a 15-minute dedup interval — so a
duplicate is killed long before it can deliver. Shorten the dedup interval if faster arms appear.

Detect duplicates by outcome (`scripts/badist/find_duplicate_arms.py`,
`kill_duplicate_arms.py`) rather than trying to prevent them at the source.

**Reporting consequence:** killing a duplicate writes a *newer* cancelled record than the surviving
copy's `running` record, so an arm reads as failed while a healthy copy runs. `campaign_status`
resolves by latest timestamp and is therefore pessimistic. The truthful test is "does this arm have
ANY running copy, or a delivered result" — by that measure the campaign stayed intact throughout
(218 running + 15 delivered + 15 staggering in = 248).

## 4. The idea-2 `512x256x512` 16.6x figure is OBSOLETE — no action

Reported 630,316 cycles against a 37,867 baseline (+1564%). It is **not** evidence about the
current design: that arm predates the backpressure work, and the issue it exposed is already fixed
in the current tree.

It also carries the MSHR-desync signature independent of that — **622 periods** with sustained
`mshr_timeout` against **zero** in the baseline. Desync makes large shapes bimodal on identical
config, so a single slow run indicates which mode it landed in, not a design property.

**Do not quote this number.** No re-run needed.

## A salvaged arm's FPU util is reconstructed, and marked `~`

`[FPU FINAL]` is printed from a SystemVerilog `final` block, so it only appears when the simulation
reaches `$finish`. An arm salvaged from a parked sim finished its *program* (`execution took N
cycles`) but was killed at the vsim prompt before `final` ran, so that line never existed -- the
cycle count is real, the util was simply never printed.

It is rebuilt from the per-period `[FPUG]` lines, which carry a `bench`/`pre` tag and their own
denominator, so the same quantity can be summed over the benchmark windows only. Counting the `pre`
windows too is what made a first attempt disagree with `FINAL`; the tag is not optional.

Validated against the 35 arms that have both: **mean error 1.10 pp**. The error is pure window
quantisation -- the benchmark region does not begin and end on window boundaries -- and scales as
1/windows:

| bench windows | n | mean err | max err |
|---|---|---|---|
| < 20 | 20 | 1.61 pp | 6.12 pp |
| 20-40 | 9 | 0.51 pp | 1.27 pp |
| 40-80 | 4 | 0.39 pp | 0.43 pp |
| 80+ | 2 | 0.15 pp | 0.16 pp |

So a long run reconstructs to better than half a point, and a short one only to a few points. These
values are written to `results.tsv` with a leading `~` and rendered in the dashboard in italic with
a hover note, so a reconstructed number can never be quoted as a measured one. They are also
excluded from the computed best/worst-util headline for the same reason.

## `packaging failed`: node-local disks fill with output we never collect

badist packages results as the LAST step of a job (`tar | zstd` onto node-local scratch), so a full
disk discards a simulation that has already run to completion. It was the campaign's largest
failure mode: 24 of 51 failures, with wall times up to 24,344 s on the lost jobs.

**It is not packaging size.** The collect list is already minimal -- `['transcript',
'.sim_backend']` -- so the tarball is ~10 MB. The disk pressure is output we generate and never
collect: each arm leaves `v4m_out/trace_events.csv` at **428 MB** plus 1,024 per-hart
`trace_*.dasm`/`trace_spatz_insn_*` files in its run dir. Ten arms on a node is ~5 GB of waste, and
the run dirs are not cleaned when a job ends.

**Do not read it as a big-shape problem.** 18 of the 24 failures were on shapes with a >=2048
dimension, which is convincing and wrong -- long arms are simply likelier to be resident when a
node fills. By node, 16 of 24 were larain2 alone (7 TB, 224 KB free).

`scripts/badist/scratch_guard.py` reclaims spent run dirs on nodes we have work on, and rescues
finished-but-undelivered transcripts off an at-risk disk first. It cannot help when the disk is held
by other users -- then it names the running arms that will lose their results instead of reporting
a clean sweep.

**`packaging failed` also masks the real cause.** `fp32_2048x32x512` on badile44 recorded it after
7,879 s, but its transcript has no `execution took`: the simulation had already died for some other
reason, and packaging merely failed afterwards. Check the transcript before believing the error.
