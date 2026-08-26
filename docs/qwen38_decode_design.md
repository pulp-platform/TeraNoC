# Qwen3.8 decode stage — what batch, what kernel, and what the mesh can actually feed

2026-08-26. Derived from the 8 delivered decode arms (`benchmarks/decode_gemm_results.md`) and the
8x8 GEMM sweep. **Measured** and **derived** are marked throughout; the roofline below is validated
against measurement, the attention and capacity sections are arithmetic on model dimensions.

## 1. The roofline, and why it can be trusted

Decode arithmetic intensity is `B / elem_bytes` MAC per byte — **the tile dimensions cancel**, so
no work split changes it. Converting each arm's PEAK per-period utilisation into the `W` bytes it
must have been streaming gives an achieved bandwidth, and that bandwidth predicts the peaks:

| mesh | prec | achieved W bandwidth | predicted ceiling at B=32 | **measured peak** |
|---|---|---:|---:|---:|
| 4x4 | fp16 | 114 B/cyc | 89% | **85.4%** |
| 4x4 | fp32 | 116 B/cyc | 91% | **89.2%** |
| 8x8 | fp16 | 250 B/cyc | 49% | **48.9%** |
| 8x8 | fp32 | 295 B/cyc | 58% | **57.7%** |

**Four predictions, four hits within ~3 points.** ✅ MEASURED. The model is usable for planning.

**The core fact: 8x8 has 4x the lanes but only ~2x the usable W bandwidth** (114 -> 250 B/cyc
fp16). Utilisation is bandwidth / compute, so it roughly halves. Nothing in the MSHR explains it —
every 8x8 decode arm is clean (`tmo=0`, `RH=0`, `bankfull=0`) and 91% of its vector loads burst.

## 2. Projections: batch to 64, not 32

The bandwidth needed to saturate compute is `lanes / (B/elem_bytes)`, which reduces to `16384/B`
B/cyc at 8x8 for **both** precisions (fp16 doubles the lanes and the intensity together, so the
crossover batch is precision-independent).

| B | 8x8 needs | fp16 (250 B/cyc) | fp32 (295 B/cyc) |
|---:|---:|---|---|
| 32 | 512 B/cyc | bandwidth-bound, **49%** | bandwidth-bound, **58%** |
| 64 | 256 B/cyc | **98% — at the line** | **compute-bound** |
| 128 | 128 B/cyc | compute-bound | compute-bound |

**B >= 64 is the design point at 8x8; B=32 leaves half the machine idle.** At 4x4, B=32 is already
at an 89-91% ceiling — which is why 4x4 looks healthy today and 8x8 does not. ✅ DERIVED from a
validated model.

## 3. Attention: GQA gives 6x, MTP has to give the rest

Qwen3.8 has **24 Q heads / 4 KV heads** (GQA ratio 6), head_dim 256, in 16 of 64 layers. Batching
does NOT help: each sequence owns its KV, so B adds bytes and MACs equally. With MTP depth `k`,
each problem has `M = 6k` rows and **intensity = 6k/elem_bytes = 3k MAC/byte** for BOTH `QK^T` and
`PV` (the GQA 6 is already in that number; without GQA it would be `k/2`).

| MTP depth k | M | 4x4 ceiling | 8x8 ceiling |
|---:|---:|---:|---:|
| 1 | 6 | 16.7% | 9.2% |
| 4 | 24 | 66.8% | 36.6% |
| 6 | 36 | **100%** | 54.9% |
| 8 | 48 | 100% | 73.2% |
| 12 | 72 | 100% | 100% |

**4x4 reaches compute-bound at k=6; 8x8 needs k ~ 11.** ⚠️ DERIVED. This is the one place the
bigger mesh is actively worse, and it is structural.

**Attention parallelism is PROBLEM COUNT, not M** — `B x 4 KV heads` independent problems, a few
cores each. `PV` has `P = head_dim = 256`, so more batch means *fewer cores per problem* and a
*wider* slice:

| B | problems | cores each (8x8) | PV slice |
|---:|---:|---:|---:|
| 32 | 128 | 8.0 | 64 B — **exactly the burst floor** |
| 64 | 256 | 4.0 | **128 B — the optimum** |
| 128 | 512 | 2.0 | 256 B |

So batch helps attention too, by geometry rather than intensity.

## 4. The capacity wall: neither state-carrying half fits L1

| | footprint | vs 8x8 L1 (14.86 MiB) |
|---|---:|---|
| KV cache, B=32 S=2048, **one** layer | 256 MiB | **17x too big** |
| KV cache, B=64 S=2048, one layer | 512 MiB | 34x |
| GDN delta-rule state, **per sequence per layer** | 3.00 MiB | B=8 already exceeds L1 |

⚠️ DERIVED. **Both halves scale with batch and neither ever fits**, so raising `B` makes their
traffic proportionally worse. Between them they are 64 of 64 layers (16 attention + 48 GDN).

## 5. What this means for the kernel

**Two kernels, not one** — never a true GEMV, but the halves want different shapes:

| | projections | attention |
|---|---|---|
| share of decode FLOPs | ~95% | small |
| shape | ONE large problem, `M = B` | MANY small problems, `M = 6k` |
| occupancy from | rows and output columns | instance count (`B x 4`) |
| batch helps? | **yes — intensity** | yes, but only **geometry** |
| compute-bound at | **B >= 64** (8x8) | k >= 11 (8x8), k >= 6 (4x4) |

`B >= 64` serves both: it clears the projection crossover and puts the PV slice on its optimum.

## 6. Open, in priority order

1. **Head-parallel GDN placement.** 48 of 64 layers. `qwen38_kernel_mapping.md` claims the
   per-token read-modify-write generates zero NoC traffic under head-parallel placement. **Never
   measured**, and it is the only lever that attacks the capacity wall.
2. **A `B = 64` decode arm.** The crossover prediction is the most actionable claim here and rests
   entirely on the model. One arm at `B=64` either confirms it or breaks the roofline.
3. **`KERNEL_SIZE` per output width.** Every measured arm is `KS = 8`; the real 8x8 workload needs
   4, 2 and 1 for narrower projections (§5.6 of the mapping doc). Unmeasured.
4. **Attention kernel at all.** No attention decode kernel exists; §3 is arithmetic.
