# Decode-shape GEMM — benchmark results

> ⚠️ **THIS FILE IS GENERATED** by `scripts/collect_decode_results.py` and is rewritten in
> full on every run, including from the dashboard loop. **Do not add analysis here — it will
> be destroyed silently.** Hand-maintained prose lives in `decode_config_and_limits.md`,
> which also records the config, the `KERNEL_SIZE`, and the caveats that bound these numbers.

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

