# Decode GEMM — can we use larger tiles?

Analysis against the real Qwen3.8 decode shapes (`docs/qwen38_workload_analysis.md`: hidden 5120,
FFN intermediate 17408) and the measured decode arms.

## 1. Tiling is mandatory, not an optimisation

| GEMM | D x I | W |
|---|---|---:|
| FFN gate / up | 5120 x 17408 | **170 MiB** |
| FFN down | 17408 x 5120 | 170 MiB |
| DeltaNet v/o/gate, Attn q/gate | 5120 x 6144 | 60 MiB |
| DeltaNet q/k | 5120 x 2048 | 20 MiB |
| Attn k/v | 5120 x 1024 | 10 MiB |

L1 is **4 MiB at 4x4 and 16 MiB at 8x8**. Every one of these is 2.5-42x over, so W streams and
the kernel tiles. A (32 x D) and C (32 x I) are small and stay resident.

## 2. The benchmarked shapes ARE the tile shapes

`32x256x16384` at 8x8 is exactly one `(D_tile=256, I_tile=16384)` tile of the FFN GEMM. The
measured per-tile efficiencies (65.9% at D=256, 52.2% at D=128, 4x4 fp16) are therefore what a
tiled kernel inherits, not toy numbers.

## 3. I_tile is PINNED by the burst floor -- it is not a free parameter

    I_tile = n_p_blocks * (128 / elem_bytes)      n_p_blocks = cores * KERNEL_SIZE / B

At 8x8 fp16 with KS=8 that is exactly **16384**. Shrink it and the per-core B slice falls under
the 64 B burst floor, into the livelock regime confirmed directly at 48 B and 32 B
(`512x512x96` and `512x512x64`: RH ~ 10^5, 2.5% and 1.6% efficiency). Grow it and L1 overflows
with no gain, because the slice is already at its optimum.

## 4. So the only free axis is D_tile, and it is tight

8x8 fp16, I_tile = 16384:

| D_tile | W_tile | 1-buffered | 2-buffered | verdict |
|---:|---:|---:|---:|---|
| 128 | 4 MiB | 5.0 MiB | 9.0 MiB | fits |
| 256 | 8 MiB | 9.0 MiB | 17.0 MiB | single-buffer only |
| 512 | 16 MiB | 17.0 MiB | 33.0 MiB | too big |

**The trade:** D_tile=256 is worth +26% efficiency (65.9 vs 52.2) but forces single buffering,
so the W DMA stops hiding behind compute.

## 5. The result that constrains everything: intensity is independent of tile size

    MACs = B * D_t * I_t        W bytes = D_t * I_t * elem_bytes
    intensity = B / elem_bytes          <- D_t and I_t cancel

At B=32 fp16 that is **16 MAC/byte**, requiring **512 B/cycle** of W bandwidth to keep the 8x8
peak (8192 MAC/cyc) fed. **No tiling scheme can make decode compute-bound.** Tiling lets the real
shapes run at all and lets streaming overlap; it cannot change the ratio. Only batch can:

| B | fp16 intensity | W bandwidth to saturate 8x8 |
|---:|---:|---:|
| 32 | 16 MAC/byte | 512 B/cyc |
| 64 | 32 | 256 B/cyc |
| 128 | 64 | 128 B/cyc |
| 256 | 128 | 64 B/cyc |

This matches the workload doc's own reading that decode at small batch is weight-streaming-bound.

## 6. The lever that is actually available: KERNEL_SIZE

KS sets rows of B per core, so it trades per-core W reuse against tile footprint:

| KS | W reuse / core | I_tile (8x8 fp16) | max D_tile, double-buffered |
|---:|---:|---:|---:|
| 8 (current) | 8x | 16384 | 128 |
| **4** | 4x | 8192 | **256** |
| 2 | 2x | 4096 | 512 |
| 1 | 1x | 2048 | 1024 |

**KS=4 is the interesting point:** it reaches D_tile=256's efficiency *and* keeps double
buffering, at half the register-level W reuse. Whether that nets out is an experiment, not a
derivation -- one A/B pair at fixed I_tile settles it.

## What NOT to conclude

- Not "bigger tiles are better". I_tile cannot move, and D_tile buys efficiency only until it
  breaks double buffering.
- Not "tiling fixes the bandwidth problem". Intensity is B/elem_bytes regardless.
