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

## 3. The idea-2 `512x256x512` 16.6x figure is OBSOLETE — no action

Reported 630,316 cycles against a 37,867 baseline (+1564%). It is **not** evidence about the
current design: that arm predates the backpressure work, and the issue it exposed is already fixed
in the current tree.

It also carries the MSHR-desync signature independent of that — **622 periods** with sustained
`mshr_timeout` against **zero** in the baseline. Desync makes large shapes bimodal on identical
config, so a single slow run indicates which mode it landed in, not a design property.

**Do not quote this number.** No re-run needed.
