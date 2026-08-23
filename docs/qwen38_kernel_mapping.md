# Qwen3.8-27B kernel mapping — a review of the RedMulE Stage-1 plan, and the TeraNoC counterpart

2026-08-23. Companion to `docs/qwen38_workload_analysis.md` (the 2026-08-18 feasibility study,
which was analysis-only) and `docs/paper_plan_llm_inference.md`.

**What is new here:** the 4×4 and 8×8 GEMM campaigns now have enough delivered arms to place real
measurements under the Qwen tile shapes, so this document replaces the earlier "no measurements
yet" caveat for the projection half of the model. It also reviews
`qwen3-8-primary-workload-design-plan.md` (msc26f31, the RedMulE S1/S2 Stage-1 DSE) and sets out
where the two efforts converge, where they must not be conflated, and what the deployment order is.

Source data:
- `docs/benchmarks/gemm_results_4x4_idea2_bankfull.md` — 4×4, 33 fp16 + 28 fp32 shapes (2026-08-22)
- `docs/benchmarks/8x8_scaleup/results.tsv` — 8×8, 96 of 248 arms delivered (live)
- `docs/benchmarks/gemm_results_default_latest.md` — 4×4 fp32 shipping-default reference (2026-08-19)

---

## 1. Review of the RedMulE Stage-1 plan

### 1.1 What is right and should be copied

**The logical-shape / physical-tile separation, printed at runtime.** Every app emits
`logical=MxNxP tile=MtxNtxPt map=NE_RxNE_C engines=A/64 port=PW xshift=1` before its cycle count.
This makes it impossible to read a tile result as a full-operation result six weeks later. Our
sweep prints M/N/P but does not say *what fraction of what real operation* the tile is — we should
adopt the same line.

**`U_active` / `U_chip` is our efficiency metric.** Their

```
U_active = (rows_per_engine · tile_N · cols_per_engine / (REDMULE_H · REDMULE_W)) / measured_cycles
```

is algebraically the same construction as ours: `ideal / actual`, with `ideal = M·N·P / lanes`.
Both take the denominator from the data size rather than from a hardware occupancy counter. This
matters more than it looks — our own testbench `[FPU] util` counter measures lane *occupancy*, is
not conserved across runs of identical work, and has inverted a real ranking. Two campaigns that
independently landed on the same ratio can be compared; a campaign quoting an occupancy counter
cannot be compared with either.

**The fair-comparison contract (§20.3).** One ELF hash per operation per geometry across every
platform cell, so a knob sweep isolates the knob. We arrived at the same rule the expensive way,
after three invalid runs in one day — including a fabricated +34% "regression" that was an unpinned
default. Their rule is stronger than ours in one respect worth stealing: they compute the hash into
`SHA256SUMS` in the pack directory, so provenance travels with the binaries.

**The BF16 gate (§5.2) is honest and it is the same gate we have.** They observe RedMulE's
`FpFmtConfig = 6'b001101` does not visibly enable the `FP16ALT` format bit, and refuse to label
anything BF16 until a directed `Float16Alt` test passes. Our side is identical: bf16 is one masked
bit in the fpnew configuration (`spatz_pkg.sv:392`), IEEE fp16 works and is 2× fp32, bf16 is off.
**This is one shared blocker with one owner.** The checkpoint ships BF16; both campaigns are
currently measuring FP16 traffic and shapes with non-equivalent numerics. It should be escalated
once, jointly, not twice in parallel.

### 1.2 What should be challenged

**(a) `stage=gemm` excludes DMA and the destination clear — in an interconnect study.**
§20.3 states it plainly, which is the right thing to do, but the consequence deserves more weight:
the measured interval is *one RedMulE job per active engine plus the completion barrier*. For a
Stage-1 DSE whose knobs are channel mix, remapping, ROB depth and FIFO depth — i.e. NoC knobs —
excluding the DMA excludes a large part of what those knobs act on. Our cycle counts are
whole-kernel: DMA, barriers, serial sections and all. **The two numbers are therefore not
interchangeable and must never appear in one table without a stated conversion.** The cheap fix on
their side is a second counter covering DMA+clear+GEMM, reported alongside; it costs nothing and
makes the two campaigns commensurable.

**(b) Tranche 1 has no numerical golden, and XSHIFT is on.**
§1.4 and the §21 stop-condition both say so, and the plan is to add an initialized small-tile mode
later. Our experience argues for moving that earlier, not later. Two of this project's most
expensive bugs were silent wrong-workload bugs that every rate, ratio and utilisation check passed:
a group barrier that was a no-op for the entire 8×8 campaign because a `<<14` shift was a 16-group
constant, and a packed-A load path that emitted four `lbu` where one `lw` was intended — the
consumer-side checks all passed while the fetch was wrong. **A performance-only tranche cannot
detect that its data path is wrong.** One initialized tile per operation class, checked once,
before the grid, is the cheapest insurance available.

**(c) S2 decode pads `M=32 → 64`, and that padding enters the metric.**
§1.3 pads decode projections to `M=64` on S2. §20.3 correctly forbids comparing raw S1/S2 cycles,
but `U_active` is also affected: its numerator uses `tile_M / NE_R`, i.e. the *padded* rows, so the
padding is counted as useful work. S2 decode therefore reports a higher `U_active` for doing the
same logical job. Recommend an explicit `useful_MAC / measured_cycles` column whose numerator uses
the **logical** `M=32`. Their own §7.2 makes exactly this argument against padding `B=1` to 32 rows
("would measure artificial compute rather than batch-one decode") — it applies unchanged at 32→64.

**(d) The occupancy table (§20.1) is alarming by op-count and negligible by work — say which.**
Weighting the published occupancies by the actual decoder schedule (`64×FFN + 48×GDN + 16×attn`)
and by **logical MACs per token**, prefill looks like this:

| class | MACs/token/model-pass | share | S1 occupancy | S2 occupancy |
|---|---:|---:|---:|---:|
| standard prefill GEMM | 24,530 M | **99.09%** | 100% | 100% |
| attention PV | 201 M | 0.81% | 100% | 50% |
| GDN a/b (P=48→64) | 23.6 M | **0.095%** | 25% | 12.5% |
| **total** | **24,754 M** | | **≈99.9%** | **≈99.6%** |

(FFN 64×267.4 M, GDN 48×115.8 M, attention 16×130.0 M per token at S=2048.)

So the two starved classes are **0.9% of prefill work between them**, and the S2 GDN a/b row —
1 engine of 64, 1.6% occupancy, the most eye-catching number in the table — is **0.095% of the
model's MACs**. MAC-weighted prefill occupancy is ~100% on both geometries. That should be stated,
or a reader will take away a cliff that does not exist.

**Decode is the opposite, and that is the real finding.** At decode the standard projections
themselves drop to 16 of 64 engines (25%), and standard projections are ~99% of the work — so
chip occupancy is ~25% and it is *structural*, set by RedMulE's 32-row minimum against a batch of
32. Everything interesting in this DSE is in the decode half, and the prefill half is close to a
solved problem. That is worth promoting from a table row to a conclusion.

**(e) The GDN a/b projection is a mapping mismatch, not a tuning problem.**
`[2048,5120] × [5120,96]`, padded to P=64 per shard, lands on 16 engines at S1 and 1 at S2. No
choice of `NE_R`/`NE_C` fixes a 96-column output on a 64-engine array with a 32- or 64-element
port. On a vector manycore the same operation is an ordinary strided job with no padding at all.
This is the single cleanest illustration of the architectural difference between the two machines
and it belongs in both write-ups.

---

## 2. The same model on TeraNoC: what changes when there is no RedMulE

Our machine (`terapool_spatz4_fpu`, 4×4 / 256 cores; `..._8x8`, 1024 cores) has no separate matrix
engine. Every operation in the 28-app inventory runs on the same Spatz vector units, out of the
same shared L1. The consequences are specific:

| Qwen operation class | RedMulE S1/S2 | TeraNoC |
|---|---|---|
| Large projections — FFN gate/up/down, QG, KV, QKV, Z, O | RedMulE, 64 engines, ~100% occupancy | **`sp-fmatmul-opt-burst-merge`, already measured** at both meshes |
| Prefill QK / PV | RedMulE, 100% / 50% occupancy | Spatz GEMM, short-N and short-P tiles |
| GDN a/b (`P=96`) | padded to 64, 16 or 1 engine | ordinary vector job, **no padding, no occupancy cliff** |
| RMSNorm, QK-norm, SiLU, sigmoid, softplus, softmax, RoPE, gates, residual | Spatz, deferred to a later tranche | Spatz — **to write** (needs rsqrt/exp/sigmoid polynomials) |
| Depthwise causal conv, K=4 | Spatz, deferred | Spatz `vfslide1up` — to write |
| **GDN delta rule, `[48][128][128]` FP32 state** | Spatz, deferred | **Spatz, head-parallel, L1-resident — our differentiator** |
| Decode QK/PV | assigned to Spatz deliberately (§5.1) — 32 sequences cannot form one dense GEMM | same conclusion, same reason |

Two things follow.

**First, 24 of their 28 "now" apps are operations we already have a kernel for.** Counting from
their inventory: 3 FFN prefill + 3 FFN decode + 6 attention prefill + 6 attention decode + 5 GDN
prefill + 5 GDN decode = 28, of which only the four GDN a/b control projections (`P = 96`, prefill
and decode) fall outside a shape our GEMM already tiles onto. Their first
tranche is the half of the layer we have measured for months; the half they defer to "later" is the
half nobody has measured on a shared-L1 manycore. Those are complementary, not competing, and the
overlap is small enough that neither campaign is redundant.

**Second, both machines are forced to the same decode mapping, for different reasons.** RedMulE has
a hard 32-row minimum, so decode must split output columns (`NE_R=1, NE_C=16`). Our GEMM's work
split has a row floor of `M ≥ 128` at 4×4 and `M ≥ 512` at 8×8 — four times the batch that Qwen
decode supplies. Both machines therefore have to tile decode along **P and heads, never along M**.
That convergence is a genuine result: it is a property of the workload (batch 32 against a
5120-wide residual), not of either microarchitecture.

---

## 3. Qwen tile shapes against measured data

Our GEMM convention is `M × N × P` = rows × contraction × output columns, the same convention the
RedMulE plan uses for `logical=MxNxP`. Prefill uses `S = 2048` rows; decode uses `B = 32`.

### 3.1 Prefill — every projection reduces to one of three tiles

| Qwen operation | logical `M×N×P` | tile used | 4×4 fp16 anchor | 8×8 fp16 anchor |
|---|---|---|---|---|
| FFN gate/up (fused) | 2048×5120×34816 | `512×512×512` | **71,755 cyc, 91.3%** | `512×512×512` 34,568, 47.4% |
| FFN down | 2048×17408×5120 | `512×512×512` | as above | as above |
| Attention Q+gate | 2048×5120×12288 | `512×512×512` | as above | as above |
| Attention K+V | 2048×5120×2048 | `512×512×512` | as above | as above |
| Attention output | 2048×6144×5120 | `512×512×512` | as above | as above |
| GDN QKV | 2048×5120×10240 | `512×512×512` | as above | as above |
| GDN Z | 2048×5120×6144 | `512×512×512` | as above | as above |
| GDN output | 2048×6144×5120 | `512×512×512` | as above | as above |
| Attention QK (per head) | 2048×256×2048 | `512×256×512` | **37,861 cyc, 86.5%** | 18,322, 44.7% |
| Attention PV (per head) | 2048×2048×256 | `512×512×256` | *(N=512 tile of a 2048 contraction)* | 8×8 has `N=2048` shapes in flight |
| GDN a/b (fused) | 2048×5120×96 | `512×512×96` | **no measurement — P < 128** | none |

**Nine of the eleven prefill projections collapse onto one tile.** `512×512×512` at 4×4 fp16 runs
at **91.3% of roofline**; the whole prefill projection half of Qwen3.8 is, on our machine,
one already-measured shape. That is the cheapest headline available and it needs no new kernel.

At 8×8 the same tile is at 47.4% and the best delivered fp16 point is `2048×256×512` at **73.5%** —
the 248-arm campaign is still running and the large-M rungs that Qwen prefill actually wants
(`2048×512×512` and up) have not landed yet.

### 3.2 fp16 against fp32 — the number that carries the FFN story

| mesh | shapes | median fp32/fp16 | best efficiency |
|---|---:|---:|---:|
| 4×4 (M ≥ 256) | 23 | **1.72×** | 94.8% (`256×512×512`) |
| 8×8 (paired) | 26 | **1.51×** | 73.5% (`2048×256×512`) |

The 4×4 fp16 arms at **M = 128** are excluded: they are the fp16 M=128 wedge (3–12% efficiency,
thousands of response-hazard episodes), a defect rather than a datapoint, and bank-full
backpressure does not reliably clear it. This matters for Qwen because `M = 128` is a legal
prefill row tile — it must be fixed or avoided before any Qwen prefill number is quoted at 4×4.

### 3.3 Coverage gaps that Qwen exposes

| regime | why Qwen needs it | 4×4 coverage | 8×8 coverage |
|---|---|---|---|
| **`M = 32`** | decode, `B = 32` independent sequences | none (`M ≥ 128`) | none (`M ≥ 512`) |
| **`P < 128`** | GDN a/b (`P = 96`) | none (`P ≥ 128`) | none (`P ≥ 128`) |
| `N ≥ 2048` | attention PV over a 2048-key tile | none (`N ≤ 1024`) | **in the running manifest** |
| `P ≥ 1024` | wide fused projections before tiling | none (`P ≤ 512`) | **in the running manifest** |

`M = 32` is the important one and it is not a sweep gap — it is the gap
`docs/paper_plan_llm_inference.md` §3.1 already names: *decode shapes are not measurable under the
current work split*. Adding `M = 32` rows to the shape list will not produce a decode measurement;
it needs the kernel change first. `P < 128` is a genuine sweep gap and is cheap to close.

---

## 4. Deployment plan

Ordered so that each phase produces a quotable result and none blocks on the phase after it.

### Phase 0 — close the reporting gaps (done / in progress)

1. ✅ 4×4 idea-2 + backpressure results committed to
   `docs/benchmarks/gemm_results_4x4_idea2_bankfull.md` (they existed only as artifacts).
2. Finish the 248-arm 8×8 campaign; the large-M rungs are what Qwen prefill needs.
3. Add `P = 96` and `P = 64` columns to the 4×4 shape list — one afternoon, closes the GDN a/b gap
   and is the exact regime that starves the RedMulE array.

### Phase 1 — the prefill claim, no new kernel (days)

Publish "the Qwen3.8 prefill projection set runs at *X*% of roofline on TeraNoC at both meshes,"
built from the `512×512×512` and `512×256×512` anchors already in hand. Needs only the runtime
`logical=… tile=…` provenance line so the tile cannot later be mistaken for the full operation.
**Blocker to clear first:** the fp16 M=128 wedge, if `M = 128` tiles are to be used at 4×4.

### Phase 2 — the serial half (weeks)

RMSNorm, SiLU/SwiGLU, softmax, partial MRoPE, sigmoid gates, and the shared transcendental
library. Individually tiny; they **serialise between GEMMs**, so they set the floor on what a real
layer achieves, and the penalty is *larger at 8×8* where the same serial section sits in front of
four times the lanes. Nobody publishes this number. Measure it as a fraction of layer time at both
meshes — the mesh-dependence is the result.

### Phase 3 — the Gated DeltaNet step (the paper)

48 of 64 layers. Decode form: rank-1 state update plus a matvec per head, entirely L1-resident,
tiled head-parallel (3 heads/group at 4×4). The state is 3.0 MiB per sequence per layer in FP32 —
**83% of usable L1 at 4×4 batch 1, and 10% at 8×8 in fp16**, so `B = 8` fits at 8×8, which is
exactly the batch the bandwidth analysis says is needed to be compute-bound. The 8×8 mesh is what
makes this model's dominant layer type viable at all.

Bring it up at 4×4 (7-minute elaboration against hours at 8×8, and 48/16 = 3 heads per group
divides cleanly); take the measurement to 8×8.

### Phase 4 — BF16, jointly

Neither campaign can claim BF16 today. One RTL decision — enabling the alternate 16-bit format in
fpnew on our side, `FP16ALT` in RedMulE's `FpFmtConfig` on theirs — unblocks both. Escalate once.

### Phase 5 — one full GDN layer, end to end

Projections (Phase 1) + serial ops (Phase 2) + recurrence (Phase 3) composed, measured against the
sum of its parts. The gap between them is the layer-integration cost, and it is the number an
architecture paper is actually asked for.

---

## 5. Storyline

Three claims, in the order the evidence supports them.

**1. The projection substrate is measured and it is good.** 4×4: median **1.72×** for fp16 over
fp32 across 23 shapes, up to **94.8%** of roofline; the nine large Qwen prefill projections all
reduce to one tile that runs at **91.3%**. 8×8: 1024 cores, campaign live, best fp16 point
**73.5%**. This is the table-stakes claim and it is already paid for.

**2. The interesting cost is not in the GEMM.** Two independent lines of evidence: the serial ops
between GEMMs get relatively *worse* as the mesh grows (Amdahl against 4× the lanes), and decode
occupancy is structurally capped on *both* architectures by a row-granularity floor meeting a batch
of 32. A GEMM-only number overstates what a layer achieves, and overstates it more at 8×8.

**3. The differentiator is the Gated DeltaNet recurrence, and it needs the big mesh.** 48 of 64
layers carry a 3 MiB FP32 recurrent state per sequence. At 4×4 the batch that fits and the batch
that keeps the machine fed are in direct conflict and there is no batch satisfying both. At 8×8 in
fp16 they land on the same number, `B = 8`. Head-parallel placement makes the per-token
read-modify-write generate **zero NoC traffic**. This is the claim that needs our machine
specifically, it is unclaimed by the RedMulE plan (which defers the delta rule), and it is the
paper.

The RedMulE Stage-1 DSE and this work are complementary: theirs answers *how well does a 64-engine
matrix array schedule Qwen's projections*, ours answers *what does the other 30% of the layer cost
on a shared-L1 vector manycore, and does the recurrent state fit*. The one thing to guard is the
timed interval — their `stage=gemm` excludes DMA, ours does not — so no table may mix them without
saying so.
