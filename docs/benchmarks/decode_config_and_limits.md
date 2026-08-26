# Decode-shape GEMM — configuration, provenance and limits

**Hand-maintained. `decode_gemm_results.md` is GENERATED** by `scripts/collect_decode_results.py`,
which rewrites it in full on every run — including from the dashboard loop. Analysis written into
that file is silently destroyed on the next collection; this happened on 2026-08-26 and the loss
was committed under a message claiming the opposite. Durable prose belongs here.

## Configuration — identical across all 8 arms

All ran under **VCS**, on two images: `build_vcs` (4x4) and `build_vcs_8x8` (8x8).

| knob | value |
|---|---|
| `NOC_ROUTER_REMAPPING` | **2** |
| `GROUP_MSHR_HOLD_WINDOW_BURST` | **2047** (`HOLD_PRESCALE_W=4`) |
| `GROUP_MSHR_SERVE_TIMEOUT` | **2047** |
| `GROUP_MSHR_HOLD_WINDOW_SINGLE` | 0 |
| `GROUP_MSHR_MERGE_REQS` | 16 |
| `KERNEL_SIZE` | **8** |

**`KERNEL_SIZE = 8` is confirmed from the runtime print, not the source default.** Every arm emits
`M, N, P, m_start, m_end, p_start, p_end`, and `m_end - m_start = 8` on all eight. The column span
puts every arm on exactly **128 B** (fp16 `64 x 2 B`, fp32 `32 x 4 B`), the burst optimum the shapes
were chosen for. Cross-check at 8x8 fp16: `I / p_span = 16384/64 = 256`, and independently
`cores x KS / B = 1024 x 8 / 32 = 256`.

## Three caveats that bound what these numbers mean

**1. The short hold window is not suspected of costing these arms anything.** `remap=2, hold=2047`
is the losing corner of `8x8_scaleup/remap_x_window_ab.md`, where 8191 was worth 1.85-2.34x. That
gain came from eliminating timeouts, and those arms carried 2,209-3,471 of them. **Every decode arm
has `tmo = 0`** — the window never expires, so lengthening it has nothing to fix. `remap=3` is
untested on decode shapes and remains open.

**2. The 4x4 and 8x8 images differ in one knob that is NOT mesh scaling.**

    AXI_WIDTH_INTERLEAVED  16 -> 32     (mesh)
    L2_BANKS               16 -> 32     (mesh)
    NUM_CORES             256 -> 1024   (mesh)
    NUM_GROUPS             16 -> 64     (mesh)
    NUM_X                   4 -> 8      (mesh)
    TERAPOOL_SPATZ4_FPU -> _8X8         (mesh)
    GROUP_MSHR_BANKFULL_BACKPRESSURE   absent -> 1    <-- NOT mesh

So **the cross-mesh scaling factors (1.29x-2.03x) cross a knob.** Per-mesh efficiencies are
unaffected, and the 8x8 numbers are safe either way because `bankfull = 0` there — the knob is inert
when banks never fill. The suspect half is 4x4, where bank-full *bypass* fired 6,759-16,399 times;
with `BACKPRESSURE=1` those would stall rather than bypass and the cycle counts could move.
**Direction unknown without a 4x4 decode arm at `BANKFULL_BACKPRESSURE=1`** — one arm settles it.

**3. The benchmark covers ONE point of the `KERNEL_SIZE` space.** `KS = 8` is correct for FFN
gate/up (`I = 17408`) at 8x8 and for every operation at 4x4. The other 8x8 decode operations need
`KS` of 4, 2 or 1 (`docs/qwen38_kernel_mapping.md` §5.6) and **none has been measured.**

## Why 8x8 utilisation is low — it is NOT the vector burst

Every 8x8 decode arm is **completely clean**: `tmo = 0`, `RH = 0`, `bankfull = 0`. There is no MSHR
stall, no response hazard, no bank contention. And the bursts form:

| arm | vector loads that burst |
|---|---|
| 4x4 fp16 `32x128x4096` | 6,187 of 6,321 — **97.9%** |
| 8x8 fp16 `32x128x16384` | 25,058 of 27,543 — **91.0%** |
| 8x8 fp32 `32x256x8192` | 25,324 of 26,869 — **94.3%** |

(`[BURSTWHY]` reports `strided=0 indexed=0 ew_ok=1 vl_ge_64=1 vl_le_256=1 align6=1 => burst=1`, so
the 128 B slice clears every burst predicate.) **The burst path is not broken.**

### The ceiling is W-streaming bandwidth, and it does not scale with the mesh

Converting each arm's PEAK per-period utilisation into the `W` bytes it must have been moving
(decode arithmetic intensity is `B / elem_bytes` = 16 MAC/byte at fp16, 8 at fp32):

| mesh | prec | D | peak util | peak MAC/cyc | ⇒ achieved W bandwidth |
|---|---|---:|---:|---:|---:|
| 4x4 | fp16 | 128 | 85.4% | 1,749 | **109 B/cyc** |
| 4x4 | fp16 | 256 | 89.0% | 1,822 | **114 B/cyc** |
| 4x4 | fp32 | 128 | 89.2% | 914 | **114 B/cyc** |
| 4x4 | fp32 | 256 | 90.7% | 928 | **116 B/cyc** |
| 8x8 | fp16 | 128 | 36.0% | 2,949 | **184 B/cyc** |
| 8x8 | fp16 | 256 | 48.9% | 4,003 | **250 B/cyc** |
| 8x8 | fp32 | 128 | 51.3% | 2,101 | **263 B/cyc** |
| 8x8 | fp32 | 256 | 57.7% | 2,363 | **295 B/cyc** |

**At 4x4 all four arms converge on 109–116 B/cyc** regardless of precision or `D` — a hard ceiling.
Utilisation is high (85–91%) only because the 4x4 compute peak is small enough to sit under it.

**At 8x8 the achieved bandwidth rises to 184–295 B/cyc — a factor of 1.7–2.5, not 4.** Compute
scales 4x. Utilisation is bandwidth ÷ compute, so it roughly halves. That is the whole story:

> **8x8 has ~4x the lanes but only ~2x the usable W bandwidth for this access pattern.**

**8x8 fp16 `D=128` never exceeds 36% in ANY period** (48 periods, 0 above 50%, peak 36.0%), so this
is a ceiling and not a slow tail — compare 4x4, which peaks at 85.4%. It also explains why fp32
scales better: fp16 has twice the lanes chasing the same bytes, so more of its compute idles.

⚠️ Note `bankfull = 0` at 8x8 against thousands at 4x4. Bank-full bypass fires when a bank is
contended; at 8x8 the requests never arrive fast enough to contend. **A counter reading zero here
is a symptom of starvation, not of health.**


---

## The MSHR merge was configured OFF for runs 1 and 2 (found 2026-08-26)

Every decode number in this document above the line was measured with **request merging bypassed**.
This is a software configuration defect, not a hardware limit, and it is the most likely single
explanation for the gap between the measured utilisation and the roofline ceiling.

### What went wrong

`software/runtime/mshr_cfg.h` derives the MSHR merge configuration from the kernel's work split, so
the hardware knows how many cores in a group will ask for the same line. It only ever implemented
the **prefill** split, which divides M across groups:

```c
share_W = (GEMM_M / NUM_GROUPS) / KERNEL_SIZE;
share_A = share_W ? (cores_per_group / share_W) : 1;
```

The decode kernel divides M across *cores* and P across *groups* — a different split entirely. At
decode batch B=32 on 8x8, `GEMM_M / NUM_GROUPS` is `32 / 64`, which is **0** in integer arithmetic.
`share_W` became 0, `share_A` fell to its `1` fallback, and the emitted configuration was:

| field | runs 1 & 2 | meaning | run 3 |
|---|---:|---|---:|
| `hold_subs_single` | 1 | **bypass** — do not hold, do not merge | 4 |
| `hold_subs_burst` | 0 | **off** | 4 |
| `hold_window_single` | 0 | no hold window | 8191 |
| `hold_window_burst` | 0 | no hold window | 8191 |
| `gap_words` | 8192 | wrong stride (from `GEMM_P / share_A` with `share_A = 1`) | 32 |

Zero is a *legal* answer here — it means "no sharing is available, so do not pay to look for it" —
so nothing errored and nothing warned.

### The sharing degree really is 4

From the decode work split in `main.c`: `n_row_chunks = M / KERNEL_SIZE = 32/8 = 4`, and
`row_chunk = cid % n_row_chunks` varies fastest, so the 4 cores sharing a W column-block are
consecutive `cid` and land in the same group. With 16 cores per group that gives
**share_W = 4 and share_A = 4** — for both operands, at both meshes.

### Corroborating measurement

The `[BP] kind=stage` classification already pointed here before the cause was known:

| stage | stall |
|---|---:|
| `REQ_TILE_OUT` / `REQ_MSHR_IN` | **90.2%** |
| `RESP_MSHR_IN` | 32.4% |
| everything downstream | 0.3–10.4% |
| mesh link utilisation | 9.3% busy |

Requests could not get *into* the MSHR while the network sat almost idle, and measured merge
capture was **1.06x** against an available 4x — consistent with the merge path being bypassed
rather than merely ineffective.

### Fix and verification

`mshr_cfg.h` gained a `MATMUL_DECODE_SPLIT` branch deriving from the decode split, and
`mshr_cfg_check_splits()` — which existed but **had no caller** — is now invoked from core 0 in
both burst-merge kernels, printing `[MSHR] SPLIT MISMATCH` if the compile-time derivation ever
disagrees with the kernel's run-time split again.

Values were verified **out of the built ELFs** rather than from the source, by emitting each
derived value as an array whose size is the value and reading it back with `nm -S`. Both
`32x256x16384` (8x8) and `32x256x4096` (4x4) give `subs 4/4`, windows `8191/8191`, `gap_words=32`,
splits 4/4.

Run 3 re-runs all 8 arms on **byte-identical hardware images** to run 2 (`build_vcs_r3`,
`build_vcs_r3_4x4`), so the CSR configuration is the only variable. Results land in the generated
`decode_gemm_results.md` "Run 3" section.

**What this does not yet tell us.** Merging being off explains why capture was 1.06x; it does not
by itself prove admission pressure is what caps these kernels. If run 3 comes back flat, the
ceiling is elsewhere and the W-streaming bandwidth argument above stands unchanged.

### Correction (2026-08-27) — what the hardware actually did with `hold_subs_burst = 0`

The section above says bursts ran with a merge target of 0. **That is wrong**, and the RTL is the
one part of this that behaved correctly.

`mempool_group_mshr_cfg.sv:128` validates every write to the two `HOLD_SUBS` CSRs:

```systemverilog
assign subs_ok = (wr_data_i >= 32'd1) && (wr_data_i <= MergeReqs);
...
IdxW'(MSHR_CSR_HOLD_SUBS_BURST) : if (subs_ok) cfg_d.hold_subs_burst = MshrCfgSubsW'(wr_data_i);
                                  else status_d[MSHR_STATUS_RANGE] = 1'b1;
```

A write of 0 is **rejected**: the field keeps its reset value and a sticky `MSHR_STATUS_RANGE` bit
is raised. So `hold_subs_burst` stayed at the image default of **4**, never 0. What actually
differed between run 2 and run 3 was this:

| CSR | run 2 wrote | accepted? | in effect (run 2) | run 3 |
|---|---:|---|---:|---:|
| `hold_subs_single` | 1 | yes — 1 is the legal *bypass* encoding | 1 → **singles bypassed** | 4 |
| `hold_subs_burst` | 0 | **no** — out of range | **4** (image default) | 4 |
| `hold_window_single` | 0 | yes — 0 is in range | 0 | 8191 |
| `hold_window_burst` | 0 | yes | 0 | 8191 |

Bursts therefore *could* merge (target 4) but were never *held*: with `hold_window_burst = 0`,
`replay_ready` (`mempool_group_mshr.sv:3405`) fires the moment an entry allocates, so it issues to
the NoC without waiting to accumulate its four sharers. Only requests that happened to overlap an
entry's live window merged — which is exactly the measured **1.06x**.

**Independent cross-check.** The hardware image defaults are `HOLD_SUBS_SINGLE/BURST = 4` and
`HOLD_WINDOW_SINGLE/BURST = 8191` — *identical to run 3's values*. If every run-2 write had been
rejected, run 2 would equal run 3. It does not (15,759 vs 10,344 on `dec4_32x128x4096`), so exactly
the accepted subset took effect and no more.

**So run 3 vs run 2 measures**: open both hold windows, and stop bypassing singles. It does **not**
measure a merge target going 0 → 4.

**The open defect is reporting, not policy.** Run 2 wrote a value the RTL is documented to reject,
which should have raised `MSHR_STATUS_RANGE` and tripped the kernel's
`[MSHR] cfg REJECTED ... MEASUREMENT INVALID` printf. That message appears **zero** times in a
transcript carrying 19,980 other printf lines. Either the sticky bit did not reach software or the
guard did not fire; the read path is wired (`mempool_group.sv:584`), so this needs a targeted test.
The design already ships one — the `MSHR_CFG_NEGTEST` / `[V5A]` block writes a deliberately
out-of-range value and asserts reject-and-report — and it is compiled out (`MSHR_CFG_NEGTEST=0`).
Running one arm with it on is the cheapest way to settle it.
