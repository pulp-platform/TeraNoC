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

