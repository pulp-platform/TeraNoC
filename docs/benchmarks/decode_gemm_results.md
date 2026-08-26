# Decode-shape GEMM — benchmark results

`C[B][I] = A[B][D] x W[D][I]`, mapped to GEMM as `M=B, N=D, P=I`. Batch is 32 throughout,
which is why the prefill work split cannot be used: it would give `M/KERNEL_SIZE = 4`
row-chunks for the whole mesh. The decode split divides `P` as well as `M`.

**No transpose is required.** `A[b][d]` is contiguous for the scalar load and
`W[d][p:p+VL]` is contiguous for the vector load, so the inner loop is the prefill kernel's
unchanged (`MATMUL_DECODE_SPLIT` selects only the work split).

Efficiency is `ideal/actual`; peak is `cores * 4 FPU * (2 for fp16)`. Rank on it, not on
the TB `util` column, which is lane occupancy.

| mesh | prec | B x D x I | B slice | cycles | ideal | efficiency | util | tmo | bankfull | RH | state |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 4x4 | fp16 | `32x128x4096` | 128 B | 15,697 | 8192 | **52.2%** | — | 0 | 6,759 | 0 | done (fleet: failed) |
| 4x4 | fp16 | `32x256x4096` | 128 B | 24,867 | 16384 | **65.9%** | — | 0 | 16,399 | 0 | done (fleet: failed) |
| 4x4 | fp32 | `32x128x2048` | 128 B | 13,291 | 8192 | **61.6%** | 66.78% | 0 | 7,493 | 0 | done |
| 4x4 | fp32 | `32x256x2048` | 128 B | 25,768 | 16384 | **63.6%** | 66.61% | 0 | 13,713 | 0 | done |
| 8x8 | fp16 | `32x128x16384` | 128 B | 48,825 | 8192 | **16.8%** | 18.87% | 0 | 0 | 0 | done |
| 8x8 | fp16 | `32x256x16384` | 128 B | 66,868 | 16384 | **24.5%** | 27.87% | 0 | 0 | 0 | done (fleet: cancelled) |
| 8x8 | fp32 | `32x128x8192` | 128 B | 35,946 | 8192 | **22.8%** | 26.01% | 0 | 0 | 0 | done |
| 8x8 | fp32 | `32x256x8192` | 128 B | 50,747 | 16384 | **32.3%** | 36.31% | 0 | 0 | 0 | done |

## Notes

* 4x4 fp16: D=128 gives 52.2%, D=256 gives 65.9% — the wider hidden dimension amortises the fixed per-iteration cost.
* 4x4 fp32: D=128 gives 61.6%, D=256 gives 63.6% — the wider hidden dimension amortises the fixed per-iteration cost.
* 8x8 fp16: D=128 gives 16.8%, D=256 gives 24.5% — the wider hidden dimension amortises the fixed per-iteration cost.
* 8x8 fp32: D=128 gives 22.8%, D=256 gives 32.3% — the wider hidden dimension amortises the fixed per-iteration cost.

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

## Scaling 4x4 -> 8x8

Both meshes run the SAME work per core: the 8x8 arm has 4x the cores and 4x the
`I`, so equal cycle counts would be perfect scaling. `speedup` is throughput —
`4 * cycles(4x4) / cycles(8x8)` — where 4.00x is ideal and 1.00x means the extra
768 cores bought nothing.

| prec | D | 4x4 cycles | 8x8 cycles | speedup | of ideal |
|---|---:|---:|---:|---:|---:|
| fp16 | 128 | 15,697 | 48,825 | **1.29x** | 32% |
| fp16 | 256 | 24,867 | 66,868 | **1.49x** | 37% |
| fp32 | 128 | 13,291 | 35,946 | **1.48x** | 37% |
| fp32 | 256 | 25,768 | 50,747 | **2.03x** | 51% |

