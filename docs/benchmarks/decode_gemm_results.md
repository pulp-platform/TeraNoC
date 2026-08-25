# Decode-shape GEMM — benchmark results

`C[B][I] = A[B][D] x W[D][I]`, mapped to GEMM as `M=B, N=D, P=I`. Batch is 32 throughout,
which is why the prefill work split cannot be used: it would give `M/KERNEL_SIZE = 4`
row-chunks for the whole mesh. The decode split divides `P` as well as `M`.

**No transpose is required.** `A[b][d]` is contiguous for the scalar load and
`W[d][p:p+VL]` is contiguous for the vector load, so the inner loop is the prefill kernel's
unchanged (`MATMUL_DECODE_SPLIT` selects only the work split).

Efficiency is `ideal/actual`; peak is `cores * 4 FPU * (2 for fp16)`. Rank on it, not on
the TB `util` column, which is lane occupancy.

| mesh | prec | B x D x I | B slice | cycles | ideal | efficiency | util | state |
|---|---|---|---:|---:|---:|---:|---:|---|
| 4x4 | fp32 | `32x128x2048` | 128 B | 13,291 | 8192 | **61.6%** | 66.78% | done |
| 8x8 | fp16 | `32x128x16384` | 128 B | — | 8192 | — | — | running |
| 8x8 | fp16 | `32x256x16384` | 128 B | — | 16384 | — | — | running |
