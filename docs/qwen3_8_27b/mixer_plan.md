# Token mixers (Gated DeltaNet + gated attention) for Qwen decode -- plan

Agreed with the user 2026-10-08, point by point. Companion of `canonical_shapes.md` (shapes) and
`ffn_fused_plan.md` (the FFN half, done by the FFN effort). This file records the decisions and the
order of work; results go into the sections at the end as they land.

## 1. What is left, and why it is mostly the mixers

A decoder layer is `x -> RMSNorm -> mixer -> (+x) -> RMSNorm -> FFN -> (+x)`. 48 of 64 layers use
the Gated DeltaNet (GDN) mixer, 16 use gated attention. The FFN half is built (`qwen-ffn`).

Three kinds of data, three costs:

| kind | shared by the B sequences? | where | status |
|---|---|---|---|
| weights (100-400 MiB/layer) | yes -- batch raises reuse | L2, DMA-streamed | solved (`qwen-gate-up`, `qwen-ffn-down`) |
| activations (KiB/sequence) | -- | L1 | hand-offs between stages (section 5) |
| per-sequence memory: GDN state, KV cache | **no** -- batch adds traffic, never reuse | L2 | **new** |

Every mixer projection is one of the two solved regimes (short-K wide-P: qkvz 4096->16384 = the
gate/up shape, attention q+gate+k+v 4096->14336; long-K narrow-P: both o-projections 6144->4096).
The new kernels are the delta rule, flash-decoding attention, and the small vector operators.

## 2. Decisions

**D1 GDN state residency.** Default **option B**: the state is streamed L2 -> L1 -> L2 by the DMA
every step (any batch). **Option A** (state resident in L1, no DMA) stays as a build knob: the
kernel's best case, valid only for one layer at small B (4x4 B <= ~8, 8x8 B <= ~32 at fp16). The
A-vs-B gap is the per-sequence-memory cost and is reported.

**D2 Attention.** Flash-decoding: the KV cache streams from L2 tile by tile, online softmax, and the
history S is split across groups when `B x 4 KV heads` does not fill the mesh (the combine is a
cross-group reduction, like the FFN's cross-group K split). Context lengths **S = 512, 2048, 8192**.
The 6 query heads of a KV head act as the "batch" of a small GEMM (GQA ratio 6).

**D3 L2** -- set to 1 GiB in the configs (user, 2026-10-08), but the address map caps it at
**512 MiB**: L2 starts at `0x8000_0000` and the boot ROM / peripherals sit at `0xA000_0000`
(`gen_perimeter_map.py` refuses a larger L2, found 2026-10-09). More needs moving that window (an
RTL address-map decision, open). Every image, the GVSoC model and every ELF use 512 MiB
(`l2_size=536870912`); whole-layer perf builds share one L2 weight region (`ql_wshare`).

**D4 Fuse by default.** RMSNorm folds into the next GEMM (gamma into W offline; 1/rms, a per-sequence
scalar, scales the GEMM output so the global sum runs off the critical path); the residual is added
as o-proj / down write their outputs; gates and activations (SiLU(z), sigmoid(gate), conv1d+SiLU)
run in the producing kernel's epilogue. Stand-alone versions only for testing.

**D5 Short vectors: software, not RTL.** The Spatz IPU<->FPU wedge (vl <= 1 element/lane,
`docs/spatz_short_vl_wedge_handover.md`) is avoided in software: pad to vl >= 16, gather into fewer
cores, and an FP-only `exp` (no integer vector ops at all). RTL debugging only if a measurement shows
the workaround costs real performance.

**D6 Layout: the producer writes where the consumer reads.** No reshuffle phases. Hand-offs are one
of: replicate (`x` into a projection), stay put in the owning group/tile (element-wise, conv,
delta-rule rows), or partial sums + reduction (K split, flash-decoding combine). One chip-wide
exchange per block (the new `x`). Head -> group ownership is chosen so the projection's column split
and the o-projection's K split line up with the mixer's placement. Per-sequence memory is placed in
its owner's tile slots, and stored in L2 in the order a single contiguous DMA needs.

**D7 Precision.** fp32 ONLY for the RMSNorm sums of squares and the softmax running max / sum.
Everything else is fp16: weights, activations, KV cache, GDN state, all GEMM / PV accumulation, the
internals of exp / sigmoid / SiLU / softplus / rsqrt. Value accuracy is not a goal; performance is.
Checks are structural (exact patterns that catch addressing, missing work, hangs).

## 3. Hardware facts the kernels build on

- L1 interleave (4x4): a tile owns **64 B** per sweep (16 banks x 4 B), a group **1 KiB**, a sweep is
  **16 KiB** (8x8: 64 KiB). `NUM_BANKS_PER_TILE = cores/tile x N_FU x BANKING_FACTOR = 16`.
  A 64-B tile slot is conflict-free for one core's vector access (one word per bank).
- Spatz: VLEN 512 (e16 m1 = 32 elements), 4 FPUs, fp16 SIMD 2 -> 8 fp16 FMA/cycle/core.
  No divide / sqrt (`FDivSqrt = 0`): reciprocal and rsqrt by seed + Newton. No `vfwcvt`; reductions
  (`vfredusum`, `vfredmax`), `vfmv.f.s`, `vfslide1down`, scalar Zfh arithmetic are present.
- One cluster DMA frontend (`dma.h`), 1-D transfers; core 0 issues them in the existing apps.
- Remote single loads with one reader are held by the live MSHR for its hold window (~8k cycles):
  per-core control data lives on the core's stack, never in a shared array (WORKLOG 2026-10-08).

## 4. GDN delta rule on the cores

Per sequence, per value head h (48), state `S_h` is 128 x 128 (rows i = value dims, columns j = key
dims); 3 value heads share one key head (q, k). One decode step:

    pred_i = s_i . k ;  c_i = beta (v_i - alpha pred_i) ;  s_i <- alpha s_i + c_i k ;  o_i = s_i . q

Rows are independent, so rows go to cores and the state never crosses the NoC.

- **Chunk = 32 rows of one value head** (4 per head, 12 per (sequence, key head), 192 per sequence).
  alpha and beta are scalars for a chunk.
- **Column-major in tile slots.** Column j of a chunk (32 fp16 = 64 B) is exactly one tile slot:
  `base + j * SWEEP + tile_offset`. Every vector access of a core stays in its own tile.
- **GEMM-like, no reductions:** vectors run over the 32 rows, k_j / q_j are scalars (`vfmacc.vf`).
  Pass 1: `pred += k_j * S[:,j]`. Then `c = beta (v - alpha pred)`. Pass 2:
  `S[:,j] = alpha S[:,j] + k_j c ; o += q_j S[:,j]`. Per column: 4 vector FP ops over 32 elements,
  2 loads + 1 store of 64 B.
- **State tile** (one chunk per core per sweep column) = 256 cores x 8 KiB = 2 MiB at 4x4; option B
  streams state tiles with one contiguous DMA each, double-buffered, the L2 copy stored in L1 order.
- k / q: a per-core copy in the core's own tile slots (the projection epilogue writes replicas).
- Later variant (perf knob): lazy rank-1 update -- keep the previous step's correction (c, k, alpha)
  pending and apply it while reading S in the next step's single pass (one L1 read + one write per
  element instead of two reads + one write).

## 5. Order of work

| step | what | where |
|---|---|---|
| 0 | this plan; canonical_shapes accumulation row | -- |
| 1 | shared base `software/apps/spatz_apps/qwen-common/`: layout helpers, fp16 vector library (FP-only exp, sigmoid, SiLU, softplus; scalar rsqrt), host tests, a GVSoC + RTL smoke app | host, GVSoC, 1-2 RTL |
| 2 | delta-rule kernel alone, option A | GVSoC -> RTL 4x4 |
| 3 | option B (DMA-streamed state tiles), A vs B over B | GVSoC -> RTL |
| 4 | full GDN mixer block in one timed region (projections with head-aligned splits, conv1d/norm/gates fused, a,b per group, o-proj + residual) | GVSoC -> RTL, 8x8 |
| 5 | full GDN layer = step 4 + `qwen-ffn` | RTL both meshes |
| 6 | attention: flash-decoding kernel, then the block, then the layer | same flow |

Moving the duplicated streamed-GEMM kernel (`kernel/qwen-fmatmul.c`, 3 copies already diverging)
into `qwen-common` waits until the FFN effort finishes, and is agreed with it.

Simulation budget: GVSoC for every iteration (cleaned at each step change); RTL for performance
numbers only, **at most 10 VCS runs at once** (<= 5 per submit), killed after harvest; licence and
disk checked at every step.

## 6. Results

**Step 1 (2026-10-08).** `qwen-common/qc_vec.h` + `qwen-vec-test`: bit-exact against the host
model on GVSoC and RTL, including n = 1..5 (no wedge). In-register cost per 64 fp16 (RTL): exp 112,
SiLU 192, softplus 177 cycles. Worst-case error: exp 2.6%, SiLU 2.1%, softplus 1.8%.

**Step 2/3 (2026-10-08, B=4, 4x4).** Delta rule `qwen-gdn`: option A 20,775 cycles RTL (30% of FPU
peak: vl = 32 vectors, ~4 cycles per vector instruction); option B 44,473 RTL, DMA-bound
(~395 B/cycle). The delta rule is ~5% of a GDN layer even at B=64 (GVSoC sweep: B=64 option B
432k cycles), so longer vectors / the lazy update are parked.

**Step 4 (2026-10-09, GVSoC 4x4).** `qwen-gdn-block`, one timed region: B=4 357k cycles
(qkvz 57%, o-proj 66% FPU), B=16 1.06M (79%, 91%). Mixer share 14-17%: the DMA-bound state
streaming, plus the a,b dot products (moved into the DMA shadow).

**Step 5 (2026-10-09, GVSoC).** `qwen-layer ql_ffn=1`: one whole GDN decoder layer in one timed
region (pre-mixer norm folded into qkvz, qkvz + conv/SiLU epilogue, mixer, o-proj + residual,
pre-FFN norm, gate+up + SwiGLU, down + residual). Weights alias one shared L2 region (perf builds;
a layer's 560 MiB exceeds the 512 MiB RTL images).

| mesh, B | total | qkvz | mixer | o-proj | gate+up | down | vs projections-only ideal |
|---|---:|---:|---:|---:|---:|---:|---:|
| 4x4, 4 | 944k | 231k (57%) | 53k | 78k (63%) | 381k (69%) | 196k (67%) | 61% |
| 8x8, 16 | 906k | 209k (63%) | 89k | 78k (63%) | 339k (77%) | 175k (75%) | 63% |

The mixer is 6% (4x4 B=4) to 10% (8x8 B=16) of the layer; handovers and norms < 2%.

**Step 6b/6c (2026-10-09, GVSoC 4x4).** `qwen-layer ql_mixer=attn`: the attention block and the
whole attention layer (`ql_ffn=1`) run. The earlier "hang in the q norm" was a **stack overflow**:
each core's 512 B stack also holds the log-barrier counter, and with every kernel inlined
`main + ql_mixer_run` reached 528-560 B (WORKLOG 2026-10-09 07:45). Kernels are now `noinline`
and `qwen-common/script/stack_depth.py` (run by `build_app.sh`) refuses any build over 500 B.

Attention mixer, B=4 (16 problems x 16 cores), cycles:

| step | S=512 mixer | S=2048 mixer | what changed |
|---|---:|---:|---|
| first working build | 77.7k | 160.1k | prep 17.5k, rounds 35k / 4 x 30k, tree combine 15k + gate 2.5k, o-proj tile 0 exposed |
| flat combine fused with the gate | 65.4k | 149.0k | one pass over all parts' partials: 17.4k -> 7.3k |
| K tile 0 / o-proj tile 0 under prep / combine | 62.2k | 146.4k | the exposed DMA hidden (combine shares the DMA: 7.3k -> 9.8k) |
| each norm core writes its head to every part | 52.3k | 136.3k | prep 16.4k -> 6.4k: 15 parts reading part 0's slots serialised on its tile |
| new k: strided L1 insert, L2 write-back split over the parts | -- | 131.3k | the last part held every barrier (~7.5k); profiled build |
| QK / PV inner loops: per-head pointers, 8-row unroll | -- | 117.8k | 14 instructions per row (was ~25: lui + add per q / p scalar, heads 8 sweeps apart); round compute 110k -> 96k |

Rounds are compute-bound (core profile: 96k compute, 4k barrier wait over 4 rounds; QK + PV FPU
ideal 49k, softmax ~13k). The qwen-attn exact check passes with the rewritten loops.

| layer (GVSoC 4x4, B=4, S=2048) | total | in-proj | mixer | o-proj | gate+up | down |
|---|---:|---:|---:|---:|---:|---:|
| first working build | 1,034,902 | 215k | 160k | 81k | 381k | 195k |
| optimised (before the k write-back change) | 1,012,110 | 215k | 135k | 81k | 381k | 196k |
| + k write-back split | 1,006,291 | 214k | 130k | 81k | 380k | 196k |
| + QK / PV loops (final) | 992,221 | 215k | 116k | 81k | 381k | 196k |

| layer (GVSoC 8x8, B=16, S=2048) | total | in-proj | mixer | o-proj | gate+up | down |
|---|---:|---:|---:|---:|---:|---:|
| first working build | 990,983 | 208k | 184k (prep 22k, rounds 128k, combine 16k + 3.7k) | 76k | 342k | 175k |
| before the QK / PV loop rewrite | 966,571 | 207k | 160k (prep 16k, rounds 129k, combine+gate 11k) | 75k | 342k | 174k |
| final | 959,652 | 207k | 152k (prep 16k, rounds 122k, combine+gate 12k) | 75k | 342k | 174k |

8x8 final code: B=16 S=512 874,898 (mixer 66k, 8%); B=4 S=8192 727,251 (mixer 154k, 21%; 64 cores
per problem). B >= 8 at S=8192 needs more than the 512 MiB L2 of the current images/model.
Profile (8x8 B=16 S=2048 block): prep is bounded by the 16 MiB K tile 0 DMA (it also slows the
norm cores), rounds 106k compute + 10k wait -- 32 MiB per round at ~1.1 KB/cycle, DMA-bound.

At 8x8 a round streams a 16 MiB K and a 16 MiB V tile (sweep = 64 KiB): 32.2k cycles per round
= ~1 KB/cycle, i.e. DMA-bound -- the loop rewrite should matter less there than at 4x4.

Context / batch sweep, final code (GVSoC 4x4, whole layer):

| B, S | total | mixer | mixer share | per round | note |
|---|---:|---:|---:|---:|---|
| 4, 512 | 921,687 | 44.4k | 5% | 28.5k | 1 round |
| 4, 2048 | 992,221 | 115.6k | 12% | 25.0k | |
| 4, 8192 | 1,268,177 | 390.4k | 31% | 23.4k | 8 MiB / round = 358 B/cycle: near the DMA (~470 GVSoC, ~395 RTL) |
| 1, 8192 | 1,306,176 | 132.9k | 10% | 25.2k | 64 cores per problem: prep 16.5k, combine 14.8k |
| 16, 2048 | 2,916,298 | 390.8k | 13% | 23.6k | 4 cores per problem, 16 rounds |

At long context the attention rounds approach the KV streaming bound on both meshes; what is
left above the bound at 4x4 is the softmax (~3k per round) and the per-round barrier.

Checks (GVSoC, `ql_check=1`): o' structural check and the new-k-in-the-KV-cache check pass at
B=4 S=2048 (16 cores per problem) and B=16 S=512 (4 cores per problem).

**RTL vs GVSoC (VCS pr1 image, 4x4, same ELFs, 2026-10-09).**

| run | RTL | GVSoC | RTL / GVSoC |
|---|---:|---:|---:|
| GDN block B=1 (qkvz / mixer / o-proj) | 363,902 (246k / 23k / 92k) | 404,163 (276k / 29k / 99k) | 0.90 |
| GDN block B=4 (qkvz / mixer / o-proj) | 435,633 (271k / 61k / 102k) | 362,039 (231k / 54k / 75k) | 1.20 |
| qwen-gdn delta rule B=4, option A / B | 20,775 / 44,473 | -- | -- |
| qwen-attn B=16 S=1024 (8 rounds, exact check) | 286,908, PASS | -- | -- |

The multi-round attention kernel passes its exact check on RTL, so the earlier GVSoC multi-round
failures were model artifacts. At B < 8 GVSoC timing is not evidence (gvsoc_run.sh: the RTL's
split-NoC fold/steer is not modelled); the 4x4 projections run 17-35% slower on RTL at B=4 and
10% faster at B=1. RTL layer runs (attention, GDN) are in flight at ~40k cycles/hour.

**Step 6a (2026-10-09).** `qwen-attn` flash-decoding core: GVSoC checks pass for single-round
cases; multi-round cases pending RTL (GVSoC ordering issues, see WORKLOG).
