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

### KS is a REQUIREMENT at 8x8, not an optimisation

At 8x8 with KS=8, `n_p_blocks = cores*KS/B = 256`, so `p_span = I/256`. Against the real shapes,
**five of six decode projections are sub-burst** (fp16, 64 B floor):

| GEMM | I | p_span | slice | |
|---|---:|---:|---:|---|
| Attn k/v | 1024 | 4 | **8 B** | sub-burst |
| DeltaNet q/k | 2048 | 8 | **16 B** | sub-burst |
| DeltaNet v/o/gate, Attn q/gate | 6144 | 24 | **48 B** | sub-burst |
| FFN down | 5120 | 20 | **40 B** | sub-burst |
| FFN gate/up | 17408 | 68 | 136 B | OK |

Only FFN gate/up clears the floor. It carries 67% of decode MACs, so it is not nothing, but every
projection would livelock. Note the direction: a BIGGER mesh divides `p_span`, so scaling up pushes
shapes *toward* the floor. The same `32x256x2048` that is fine at 4x4 (64 B fp16) is 16 B at 8x8.

### Smaller KS does NOT cost NoC traffic -- the MSHR absorbs it exactly

The obvious objection to lowering KS is losing register-level W reuse. But the cores sharing a W
slice are exactly `B/KS`, and `row_chunk` varies fastest in the split, so those sharers have
**consecutive core ids and land in the same group** -- which is what the source-side group MSHR
coalesces.

| KS | sharers/W | same group? | merged | NoC duplication | MAC per W element |
|---:|---:|---|---:|---:|---:|
| 8 | 4 | yes | 4 | **1x** | 8 |
| 4 | 8 | yes | 8 | **1x** | 4 |
| 2 | 16 | yes | 16 | **1x** | 2 |
| 1 | 32 | **no, spans 2** | 16 | **2x** | 1 |

**NoC traffic is flat from KS=8 down to KS=2.** Smaller KS creates exactly the duplication the
MSHR removes. KS=1 breaks it for two reasons at once: 32 sharers exceed both the 16-core group
and the 16-way merge capacity.

**But the merge protects the NoC hop, not the core's own load issue.** Each core owns
`KS` rows x `p_span` columns, so it loads `D*p_span` elements and does `KS*D*p_span` MACs --
arithmetic intensity is exactly **KS MACs per W element**, and total load volume is `D*I*B/KS`.
At KS=1 every element is used once: one vector load per vector FMA, making the VLSU the limit no
matter how well the NoC behaves. That cost lands on L1/TCDM bandwidth and LSU issue rate, which
merging does not touch.

**So KS=2 is the sweet spot the argument implies:** NoC still 1x, sharers exactly fill one group
and the merge capacity, `p_span` 4x larger -- clearing the floor for `I >= 2048` -- while keeping
2 MACs per element rather than 1. `I=1024` (Attn k/v) still lands at 32 B and clears only at KS=1,
so it needs either different treatment or an accepted 2x NoC cost on the model's cheapest
projection.

Worth measuring, not deciding: a KS in {8,4,2} sweep on a small-I shape tests whether the flat-NoC
prediction holds and where the VLSU cost starts to bite.

## What NOT to conclude

- Not "bigger tiles are better". I_tile cannot move, and D_tile buys efficiency only until it
  breaks double buffering.
- Not "tiling fixes the bandwidth problem". Intensity is B/elem_bytes regardless.
