# Qwen3.8-27B on TeraNoC — kernel inventory, tile policy, and tranche plan

2026-08-23. Companion to `docs/qwen38_workload_analysis.md` (the 2026-08-18 feasibility study)
and `docs/paper_plan_llm_inference.md`.

**Our architecture only.** TeraNoC has no matrix accelerator: every operation in this model runs on
the same Spatz vector units out of the same shared L1, at 4×4 (256 cores) or 8×8 (1024 cores).
A parallel effort maps Qwen onto a RedMulE-based machine; this document borrows its *method* —
single-operation apps, a logical-shape/physical-tile split, now/later tranches, per-op binary
provenance — and nothing else. Where that plan reasons about engine maps, port widths and XSHIFT,
we reason about the work split, L1 capacity, and the vector unit.

**What is new:** the 4×4 and 8×8 GEMM campaigns have delivered enough arms to put real measurements
under the Qwen tile shapes, so the projection half of this model is no longer analysis.

Source data:
- `docs/benchmarks/gemm_results_4x4_idea2_bankfull.md` — 4×4, 33 fp16 + 28 fp32 shapes (2026-08-22)
- `docs/benchmarks/8x8_scaleup/results.tsv` — 8×8, 96 of 248 arms delivered (live)
- `docs/benchmarks/gemm_results_default_latest.md` — 4×4 fp32 shipping-default reference

---

## 1. What we take from the reference plan

Five practices, all machine-independent, all cheap, all things we do not currently do:

1. **Print the logical shape and the physical tile at runtime**, on every app:
   `logical=MxNxP tile=MtxNtxPt precision=… cores=…`. Our sweep prints M/N/P but never says *what
   fraction of what real operation* the tile is, so a tile result can be misread as an operation
   result months later. One `printf`.
2. **One app per operation**, named `qwen_<workload>_<operation>`, executing exactly one L1-resident
   tile and one measured iteration. Keeps a regression attributable to an operation rather than to
   "the layer got slower".
3. **`SHA256SUMS` in the binary pack**, so provenance travels with the ELFs rather than living in a
   spreadsheet. We already know what an unpinned binary costs — three invalid runs in one day,
   including a fabricated +34% "regression".
4. **Now/later tranching of the same inventory**, so a partial suite is legible as partial rather
   than looking like a complete one with holes.
5. **Efficiency from the data size, never from an occupancy counter.** Their `U_active` is
   `ideal_per_engine / measured`; ours is `ideal / actual` with `ideal = M·N·P / lanes`. Our
   testbench `[FPU] util` counter measures lane *occupancy*, is not conserved across runs of
   identical work, and has inverted a real ranking — it must not be used for this.

**One hazard to guard.** Their timed interval (`stage=gemm`) covers the matrix job plus its
completion barrier and **excludes DMA and the destination clear**. Ours is whole-kernel: DMA,
barriers, serial sections and all. If those two numbers ever land in one table, the table is wrong.

---

## 2. Geometry and tile policy

| | **4×4** | **8×8** |
|---|---:|---:|
| cores / groups | 256 / 16 | 1,024 / 64 |
| fp32 MAC/cycle | 1,024 | 4,096 |
| fp16 MAC/cycle | 2,048 | 8,192 |
| L1 usable | 3.61 MiB | 14.86 MiB |
| L2 / L2 bandwidth | 16 MB / 1,024 B/cyc | 32 MB / 2,048 B/cyc |
| **work-split row floor** | **M ≥ 128** | **M ≥ 512** |

The row floor is the constraint that shapes everything below. It is a property of how the kernel
splits work across cores, not of capacity, and it is **four times the batch that Qwen decode
supplies** (`B = 32`).

**Contraction must be tiled, and that is a real difference from an accelerator plan.** The
reference plan uses the complete 5,120-element contraction because its operands stream past a
fixed engine array. Our A, B and C panels all live in L1 simultaneously, so at `M=512, P=512` fp16
a full 5,120 contraction would need 5 MiB for A alone — more than the whole 4×4 L1. We tile N.

**Physical tile policy:**

| | 4×4 | 8×8 |
|---|---|---|
| projections and output (ordinary P) | `M × 512 × 512`, M ∈ {256, 512} | `M × 512 × 512`, M ∈ {512, 2048} |
| attention QK (short contraction) | `M × 256 × 512` | `M × 256 × 512` |
| attention PV (long contraction) | `M × 512 × 256` | `M × 1024 × 256` |
| GDN a/b (`P = 96`) | `M × 512 × 96` — **untested regime** | — |
| decode (`M = 32`) | **not expressible** — see §5 | **not expressible** |

`M = 128` is legal at 4×4 by the work split but is currently blocked by the fp16 M=128 wedge (§4.2).
At 8×8, 14.86 MiB of L1 also admits `N = 1024`, which is worth using: efficiency rises with the
contraction because arithmetic intensity does.

---

## 3. Application inventory

Same six workloads and the same operation decomposition as the reference plan, re-attributed to our
units. **Every operation is Spatz**; Snitch does address generation, tile scheduling, DMA issue and
barriers. There is no engine map, no port width, and no padding to an engine minimum.

`have` = an existing kernel covers it. `write` = new code. Tranche numbering is ours (§6).

### FFN — prefill (S=2048) and decode (B=32)

| Operation | Logical | Status | Tranche |
|---|---|---|---|
| `qwen_ffn_{prefill,decode}_rmsnorm` | `[S,5120]` offset RMSNorm | write (needs rsqrt) | T1 |
| `qwen_ffn_{prefill,decode}_gate_gemm` | `[S,5120]×[5120,17408]` | **have** | T0 |
| `qwen_ffn_{prefill,decode}_up_gemm` | `[S,5120]×[5120,17408]` | **have** | T0 |
| `qwen_ffn_{prefill,decode}_silu_mul` | `SiLU(gate)·up`, `[S,17408]` | write (needs sigmoid) | T1 |
| `qwen_ffn_{prefill,decode}_down_gemm` | `[S,17408]×[17408,5120]` | **have** | T0 |
| `qwen_ffn_{prefill,decode}_residual` | `[S,5120]` vector add | **have** | T0 |

### Gated full attention — 16 of 64 layers

| Operation | Logical | Status | Tranche |
|---|---|---|---|
| `…_rmsnorm` | `[S,5120]` | write | T1 |
| `…_qg_gemm` | `[S,5120]×[5120,12288]` (Q + output gate) | **have** | T0 |
| `…_k_gemm` / `…_v_gemm` | `[S,5120]×[5120,1024]` each | **have** | T0 |
| `…_qk_norm` | per-head RMSNorm, 24 Q + 4 K heads, width 256 | write | T1 |
| `…_rope` | partial MRoPE, dims `[0:64]` only, sections 11/11/10 | write | T1 |
| `…_qk_gemm` | one head, `[S,256]×[256,S]` | **have** | T0 |
| `…_scale_mask` | scale 1/16 + causal mask | write | T1 |
| `…_softmax` | online row softmax, FP32 accumulators | write | T1 |
| `…_pv_gemm` | one head, `[S,S]×[S,256]` | **have** | T0 |
| `…_output_gate` | `ctx · sigmoid(gate)` | write | T1 |
| `…_o_gemm` | `[S,6144]×[6144,5120]` | **have** | T0 |
| `…_residual` | `[S,5120]` | **have** | T0 |
| `…_kv_append` / `…_kv_load` (decode only) | tile-major KV cache scatter / stream | write | T2 |

### Gated DeltaNet — 48 of 64 layers

| Operation | Logical | Status | Tranche |
|---|---|---|---|
| `…_rmsnorm` | `[S,5120]` | write | T1 |
| `…_qkv_gemm` | `[S,5120]×[5120,10240]` | **have** | T0 |
| `…_z_gemm` | `[S,5120]×[5120,6144]` | **have** | T0 |
| `…_ab_gemm` | `[S,5120]×[5120,96]` — fused a+b | **have**, `P<128` untested | T0 |
| `…_conv1d` | depthwise causal conv, 10,240 channels, K=4 | write (`vfslide1up`) | T1 |
| `…_qk_l2norm` | 16 Q/K heads, width 128 | write | T1 |
| `…_beta_sigmoid` / `…_decay_softplus` | over 48 heads | write | T1 |
| **`…_delta_rule`** | **recurrent `[48,128,128]` FP32 state update** | **write — the differentiator** | **T2** |
| `…_gated_rmsnorm` | head RMSNorm × `SiLU(z)` | write | T1 |
| `…_state_{load,store}` (decode only) | recurrent + convolution state | write | T2 |
| `…_o_gemm` | `[S,6144]×[6144,5120]` | **have** | T0 |
| `…_residual` | `[S,5120]` | **have** | T0 |

**The tranching inverts relative to the reference plan.** Theirs starts with the matrix operations
because those are what its accelerator does; for us those are already built and measured. **Their
tranche 1 is our tranche 0.** Our first tranche of new code is the vector half they defer.

---

## 4. Measured anchors

Our convention is `M × N × P` = rows × contraction × output columns.

### 4.1 Nine of eleven prefill projections are one tile

FFN gate/up, FFN down, attention Q+gate, K+V and output, GDN QKV, Z and output all reduce to
`512×512×512` after L1 tiling.

| tile | 4×4 fp16 | 8×8 fp16 |
|---|---|---|
| `512×512×512` — nine projections | **71,755 cyc, 91.3%** | 34,568 cyc, 47.4% |
| `512×256×512` — attention QK | **37,861 cyc, 86.5%** | 18,322 cyc, 44.7% |
| best measured point | 94.8% (`256×512×512`) | **73.5%** (`2048×256×512`) |

The prefill projection half of Qwen3.8 is, on this machine, one already-measured shape requiring no
new kernel. The 8×8 campaign is 96 of 248 arms; the large-M rungs Qwen prefill actually wants have
not landed, so 47.4% is not the 8×8 answer.

### 4.2 fp16 against fp32

| mesh | shapes | median fp32/fp16 | best efficiency |
|---|---:|---:|---:|
| 4×4 (M ≥ 256) | 23 | **1.72×** | 94.8% |
| 8×8 (paired) | 26 | **1.51×** | 73.5% |

⚠️ The four 4×4 fp16 `M = 128` shapes are excluded: 3–12% efficiency with thousands of
response-hazard episodes — the **fp16 M=128 wedge**, a defect rather than a datapoint, which
bank-full backpressure does not reliably clear. `M = 128` is a legal prefill row tile, so this
blocks quoting an M=128 prefill number at 4×4.

### 4.3 Where the work actually is

Weighting each operation by logical MACs per token over the real schedule
(`64×FFN + 48×GDN + 16×attention`, S=2048):

| class | MACs/token | share |
|---|---:|---:|
| FFN (64 layers × 267.4 M) | 17,114 M | **69.1%** |
| GDN (48 × 115.8 M) | 5,560 M | 22.5% |
| attention (16 × 130.0 M) | 2,080 M | 8.4% |
| — of which attention PV | 201 M | 0.81% |
| — of which GDN a/b (`P = 96`) | 23.6 M | **0.095%** |

**Optimisation follows this table, not the operation count.** The GDN a/b control projection is
0.095% of the model's MACs: its awkward `P = 96` shape is worth *measuring* (it is a regime nothing
in either sweep covers) but never worth *tuning*. The FFN is 69% of the work and reduces to the one
tile in §4.1, which is why the prefill claim is nearly free.

---

## 5. Coverage gaps Qwen exposes

| regime | needed for | 4×4 | 8×8 |
|---|---|---|---|
| **`M = 32`** | decode — 32 independent sequences, one new token each | none (floor 128) | none (floor 512) |
| **`P < 128`** | GDN a/b control projection (`P = 96`) | none | none |
| `N ≥ 2048` | attention PV over a 2048-key tile | none | in the running manifest |
| `P ≥ 1024` | wide fused projections before tiling | none | in the running manifest |

`P < 128` is a cheap sweep addition — one afternoon of arms — and closes the only shape regime the
model asks for that we have never run.

**`M = 32` is not a sweep gap.** It is the work-split row floor, the same constraint
`docs/paper_plan_llm_inference.md` §3.1 already names: decode shapes are not measurable under the
current work split. Adding `M = 32` shapes to the list produces nothing. Decode must be tiled along
**output columns and heads, never rows** — which is a kernel change, and it is the one piece of new
GEMM work this model requires.

---

## 6. Tranche plan

**T0 — shape mapping, no new kernel (days).**
Wrap the existing GEMM as `qwen_<workload>_<operation>` apps with the runtime
`logical=… tile=…` provenance line and `SHA256SUMS`. Publish the prefill projection claim from the
§4.1 anchors. *Blocker:* the fp16 M=128 wedge, if M=128 tiles are used at 4×4.
*Cheap addition:* `P = 96 / 64` arms, closing the §5 gap.

**T1 — the vector half (weeks).**
RMSNorm, QK-norm, SiLU/SwiGLU, sigmoid, softplus, online softmax, partial MRoPE, output gates,
depthwise conv, residual — plus the shared transcendental library underneath them (rsqrt, exp,
sigmoid, reciprocal polynomials, written once and tested standalone against a host reference).
These are individually tiny and they **serialise between GEMMs**, so they set the floor on what a
real layer achieves — and the penalty is *larger at 8×8*, where the same serial section sits in
front of four times the lanes. Report each as a fraction of layer time at both meshes; the
mesh-dependence is the result.

**T2 — the Gated DeltaNet step (the paper).**
Decode form: rank-1 state update plus a matvec per head, entirely L1-resident, tiled head-parallel
(48/16 = 3 heads per group at 4×4, which divides cleanly). Prefill form: the chunked scan, which
turns the recurrence back into small GEMMs. Plus the decode KV-cache and state load/store paths.
Bring up at 4×4 — 7-minute elaboration against hours at 8×8, and the turnaround matters while the
kernel is still wrong. Take the *measurement* to 8×8, because that is the only mesh where a useful
batch and the state both fit.

**T3 — decode tiling.**
The kernel change that makes `M = 32` expressible: split along P and heads instead of rows. Without
it there is no decode measurement at either mesh, and decode is the half that makes this an LLM
result rather than a GEMM result.

**T4 — BF16.**
The checkpoint ships BF16; our fpnew configuration has it masked off (`spatz_pkg.sv:392`), so
everything above is IEEE fp16 — same traffic and shapes, not numerically equivalent. Nothing may be
labelled BF16 until a directed alternate-format arithmetic test passes. A backend flow is imminent
at both meshes, so the area cost of enabling it is cheap to obtain right now.

**T5 — one full GDN layer.**
T0 + T1 + T2 composed and measured against the sum of its parts. The gap between them is the
layer-integration cost, which is the number an architecture paper is actually asked for.

---

## 7. Storyline

Three claims, in the order the evidence supports them.

**1. The projection substrate is measured and it is good.** 4×4: median **1.72×** for fp16 over
fp32 across 23 shapes, up to **94.8%** of roofline; the nine large Qwen prefill projections all
reduce to one tile that runs at **91.3%**. 8×8: 1024 cores, campaign live, best fp16 point
**73.5%**. Table stakes, and already paid for.

**2. The interesting cost is not in the GEMM.** The vector operations between GEMMs serialise, and
their relative cost *grows* with the mesh — the same serial section in front of four times the
lanes. A GEMM-only number overstates what a layer achieves, and overstates it more at 8×8. Nobody
publishes this number for a shared-L1 manycore.

**3. The differentiator is the Gated DeltaNet recurrence, and it needs the big mesh.** 48 of 64
layers carry a 3.0 MiB FP32 recurrent state per sequence per layer. At 4×4 that is 83% of usable L1
at batch 1: the batch that fits and the batch that keeps the machine fed are in direct conflict,
with no batch satisfying both. At 8×8 in fp16 they land on the same number, `B = 8`. Head-parallel
placement puts each group's state in its own banks, so the per-token read-modify-write generates
**zero NoC traffic**. This is the claim that needs our machine specifically, and it is the paper.
