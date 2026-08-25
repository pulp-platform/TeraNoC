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

**Physical tile policy** is therefore chosen against three constraints in order — row floor, then
L1 footprint with A and B double-buffered, then measured efficiency. **§5 works this through per
operation and gives the numbers**; the two structural rules are:

- **rows:** `M ≥ 128` (4×4) / `M ≥ 512` (8×8). `M = 128` is legal at 4×4 but currently blocked by
  the fp16 M=128 wedge (§4.2), and `M = 32` decode is not expressible at either mesh (§5.3).
- **contraction:** always tiled, never full. Where an accelerator plan can use the whole 5,120
  because operands stream past the array, we cannot: A alone would be 5 MiB.

Efficiency rises with the contraction, because arithmetic intensity does — so N should be as large
as the footprint allows, and at 8×8 the current best tile leaves 10 MiB of L1 unused (§5.2).

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

## 5. Chosen tile sizes, per operation

Derived from three constraints, in this order: the **work-split row floor** (M ≥ 128 at 4×4,
M ≥ 512 at 8×8), the **L1 footprint** (§5.0), and then **measured efficiency** — picking the
highest-efficiency legal tile, because with `efficiency = ideal/actual` the total cycles for a fixed
amount of work are just `ideal_total / efficiency`, so the best tile is simply the most efficient one.

### 5.0 The L1 budget, with double buffering

A GEMM tile holds three panels — A (`M×N`), B (`N×P`) and C (`M×P`) — and the budget depends on how
many of them the kernel keeps two copies of:

| kernel | footprint | what it overlaps |
|---|---|---|
| single-buffered | `(MN + NP + MP)·b` | nothing; DMA and compute serialise |
| A/B double-buffered | `(2(MN + NP) + MP)·b` | operand fetch for tile *i+1* under compute of *i*; C accumulates in place across the N-tiles |
| **fully double-buffered** | **`2(MN + NP + MP)·b`** | also the C write-back, at M- and P-tile boundaries |

**Plan against the fully double-buffered rule** — the single-buffer tile must fit in **half of
usable L1** — because that is what the future kernel needs and because the difference is decisive at
the top of the range. `b` = 2 bytes at fp16. Budget: **1.805 MiB** at 4×4, **7.43 MiB** at 8×8.

| tile | single | A/B dbl | **full dbl** | 4×4 (3.61 MiB) | 8×8 (14.86 MiB) |
|---|---:|---:|---:|---|---|
| `256×512×512` | 1.00 | 1.75 | **2.00** | ✅ 1.61 spare | — |
| `512×512×512` | 1.50 | 2.50 | **3.00** | ✅ 0.61 spare | — |
| `512×256×512` | 1.00 | 1.50 | **2.00** | ✅ 1.61 spare | — |
| `512×256×256` | 0.62 | 1.00 | **1.25** | ✅ 2.36 spare | — |
| `512×512×128` | 0.75 | 1.38 | **1.50** | ✅ 2.11 spare | — |
| `256×1024×512` | 1.75 | 3.25 | **3.50** | ⚠️ **0.11 spare — not viable** | — |
| `1024×512×512` | 2.50 | 4.00 | **5.00** | ❌ over by 1.39 | — |
| `2048×256×512` | 3.25 | 4.50 | **6.50** | — | ✅ 8.36 spare |
| `2048×512×256` | 3.25 | 5.50 | **6.50** | — | ✅ 8.36 spare |
| `2048×512×128` | 2.62 | 4.75 | **5.25** | — | ✅ 9.61 spare |
| `2048×512×512` | 4.50 | 7.00 | **9.00** | — | ✅ 5.86 spare |
| `4096×256×512` | 6.25 | 8.50 | **12.50** | — | ✅ 2.36 spare |
| `2048×1024×512` | 7.00 | 12.00 | **14.00** | — | ⚠️ 0.86 spare — the ceiling |
| `4096×512×512` | 8.50 | 13.00 | **17.00** | — | ❌ over by 2.14 |

**Every tile chosen in §5.1 and §5.2 survives the strict rule** — 4×4 with at least 0.61 MiB spare,
8×8 with at least 5.86 MiB. The `L1` column in those two tables is the A/B-double-buffered figure.

Two consequences that do change the plan:

- **`256×1024×512` at 4×4 is out.** It needs 3.50 of 3.61 MiB fully double-buffered — 0.11 MiB
  spare, inside the error bar on "usable" and leaving nothing for stack, barriers or runtime. The
  N=1024 idea at 4×4 (§5.4) is **capacity-blocked once double buffering lands**; keep it only as
  evidence about how efficiency scales with N, not as a tile candidate.
- **8×8 still has real headroom.** `2048×512×512` costs 9.00 MiB strict and leaves 5.86, so the §5.2
  upgrade is safe under the strict rule too. The ceiling is `2048×1024×512` at 14.00 MiB, and
  `4096×256×512` (12.50 MiB, 2.36 spare) is a second unexplored direction — more rows rather than
  more contraction.

⚠️ **The measured efficiencies come from today's kernel.** A double-buffered kernel changes the
footprint *and* the efficiency — overlapping the operand DMA should raise it — so §5.1/§5.2 are a
**floor** for the double-buffered version and the ranking between tiles can reorder. Re-derive both
tables against the new kernel; do not assume the tile choice carries over.

All figures fp16. `Mcyc/model` is one full 64-layer prefill pass at `S = 2048`, projected as
`useful MAC / peak / efficiency`.

**Two numbers per tile, and they are not the same thing.** `eff` = `ideal / actual` — the honest
throughput measure, and what the tile choice is made on. `TB util` is the testbench `[FPU]`
cumulative counter at the end of the benchmark window: lane **occupancy**, which counts a lane as
busy whether or not its work was useful, is not conserved across runs of identical work, and has
inverted a real ranking before. It runs 3–11 pp above `eff` here — that gap is the redundant and
spill work occupancy cannot see. Quote `eff`; `TB util` is shown only because it is what the
hardware counter reports.

### 5.1 Prefill — 4×4 (256 cores, 3.61 MiB usable L1, peak 2048 MAC/cyc)

| operation | tile `M×N×P` | eff | TB util | tiles | L1 full-dbl | Mcyc/model |
|---|---|---:|---:|---:|---:|---:|
| FFN gate+up (fused) | `256x512x512` | 94.8% | 98.1% | 5,440 | 2.00 MiB | 12,034 |
| FFN down | `256x512x512` | 94.8% | 98.1% | 2,720 | 2.00 MiB | 6,017 |
| Attention Q+gate | `256x512x512` | 94.8% | 98.1% | 1,920 | 2.00 MiB | 1,062 |
| Attention K+V (fused) | `256x512x512` | 94.8% | 98.1% | 320 | 2.00 MiB | 177 |
| **Attention QK** (per head) | **`512x256x512`** | 86.5% | 91.9% | 384 | 2.00 MiB | 233 |
| **Attention PV** (per head) | **`512x256x256`** | 86.1% | 93.0% | 768 | 1.25 MiB | 234 |
| Attention O | `256x512x512` | 94.8% | 98.1% | 960 | 2.00 MiB | 531 |
| GDN QKV | `256x512x512` | 94.8% | 98.1% | 1,600 | 2.00 MiB | 2,655 |
| GDN Z | `256x512x512` | 94.8% | 98.1% | 960 | 2.00 MiB | 1,593 |
| **GDN a+b** (`P=96`→128) | **`512x512x128`** | 74.0% | 87.9% | 40 | 1.50 MiB | 43 |
| GDN O | `256x512x512` | 94.8% | 98.1% | 960 | 2.00 MiB | 1,593 |
| | | | | | | **26,170** |

**One tile does nine of eleven: `256×512×512`.** It is the campaign's best fp16 point (94.8%),
and it beats `512×512×512` (91.3%) on throughput — 1,942 against 1,870 MAC/cycle — so the larger row
tile is not worth taking for the sake of fewer B re-fetches.

Two operations want a different tile because their aspect ratio is different, and in both cases the
**larger** row tile wins:

- **QK** has a contraction fixed at 256 (the head dimension), so N cannot be tiled up. At N=256 the
  measured order is `512×256×512` 86.5% > `512×256×256` 86.1% > `256×256×256` 72.3% — M=512.
- **PV** has an output fixed at 256 (the head dimension), so P cannot be tiled up. At P=256:
  `512×256×256` 86.1% > `256×1024×256` 78.7% > `256×512×256` 76.2% — again M=512, and note it beats
  the tile with 4× the contraction.

> ⚠️ **Do not shrink `M` on the small-`P` tiles to save L1.** The MSHR scalar cohort target is
> derived from `M` alone (`MSHR_D_HOLD_SUBS_SINGLE`, `software/runtime/mshr_cfg.h`) and rises as
> `M` falls: at 4×4 it is 4 at M=512, **8 at M=256**, **16 at M=128**. A high target combined with
> a small `P` is the RH-livelock region — 0.05–4% FPU utilisation, not a slowdown but a collapse.
> See `docs/benchmarks/8x8_scaleup/rh_livelock_root_cause.md`.
>
> **GDN a+b is the exposed operation**: `P = 96 → 128` is the smallest `P` in the workload. It is
> assigned `512×512×128` (target 4) and measures 74.0%. Re-tiling it to **`256×512×128` lands on
> target 8 at P=128 — the confirmed fp16 livelock cell** (4/4 arms, 3.11% mean at 8×8). The same
> applies to the 8×8 assignment `2048×512×128`: at 8×8, `M=1024` gives target 8 and `M=512` gives
> target 16, so **both** are worse than the 2048 tile in use, not better.
>
> The L1 budget and the cohort target happen to pull the same way here — double buffering already
> pushes toward large `M`, and large `M` is what keeps the target low. That alignment is why the
> table above is safe; it is not a property to rely on if the tiles are re-derived.

### 5.2 Prefill — 8×8 (1024 cores, 14.86 MiB usable L1, peak 8192 MAC/cyc)

| operation | tile `M×N×P` | eff | TB util | tiles | L1 full-dbl | Mcyc/model |
|---|---|---:|---:|---:|---:|---:|
| FFN gate+up (fused) | `2048x256x512` | 73.5% | 78.15% | 1,360 | 6.50 MiB | 3,880 |
| FFN down | `2048x256x512` | 73.5% | 78.15% | 680 | 6.50 MiB | 1,940 |
| Attention Q+gate | `2048x256x512` | 73.5% | 78.15% | 480 | 6.50 MiB | 342 |
| Attention K+V (fused) | `2048x256x512` | 73.5% | 78.15% | 80 | 6.50 MiB | 57 |
| **Attention QK** (per head) | `2048x256x512` | 73.5% | 78.15% | 96 | 6.50 MiB | 68 |
| **Attention PV** (per head) | **`2048x512x256`** | 53.7% | 56.57% | 96 | 6.50 MiB | 94 |
| Attention O | `2048x256x512` | 73.5% | 78.15% | 240 | 6.50 MiB | 171 |
| GDN QKV | `2048x256x512` | 73.5% | 78.15% | 400 | 6.50 MiB | 856 |
| GDN Z | `2048x256x512` | 73.5% | 78.15% | 240 | 6.50 MiB | 514 |
| **GDN a+b** (`P=96`→128) | **`2048x512x128`** | 48.2% | 59.46% | 10 | 5.25 MiB | 16 |
| GDN O | `2048x256x512` | 73.5% | 78.15% | 240 | 6.50 MiB | 514 |
| | | | | | | **8,453** |

**`2048×256×512` does ten of eleven at 8×8**, and QK now shares the general tile because its N=256
contraction is exactly what the best 8×8 point already uses.

**Scale-up: 26,170 → 8,453 Mcyc = 3.10× for 4× the hardware** (77.5% of linear). Consistent with
the campaign's independent scale-up figure, and it comes from efficiency, not from capability — the
per-tile efficiency falls from 94.8% to 73.5%.

⚠️ **We are leaving L1 on the table at 8×8.** The chosen tile uses **4.50 of 14.86 MiB**. A
`2048×512×512` tile needs 7.0 MiB A/B-double-buffered and **9.0 MiB fully double-buffered** (§5.0),
still leaving 5.86 MiB; it is in the running manifest but has not been delivered. Arithmetic intensity rises with N, and 8×8 is the more bandwidth-starved mesh, so this
is the single most likely improvement to the table above. **Re-derive §5.2 when it lands.**

### 5.3 Decode (`B = 32`, `T_NEW = 1`) — and why it needs T3

Useful work for one decode step across the whole model: **779,469 M MAC**. Three ways to express it:

| | 4×4 | 8×8 |
|---|---:|---:|
| ideal, if `M = 32` were expressible | 381 Mcyc | 95 Mcyc |
| **padding M=32 up to the row floor** | ×4 → **1,522 Mcyc** | ×16 → **1,522 Mcyc** |
| **decode split (§5.6), measured per tile** | **52.2–65.9%** | **16.8–22.8%** |
| GEMV path (`gemv` / `gemv-opt`, M=1) | FFN gate/up only | no operation clears the burst floor |

**Padded decode costs exactly the same on both meshes — 1,522 Mcyc.** That is not a coincidence and
it is not a rounding: the row floor scales 4× with the mesh (128 → 512) while the peak also scales
4× (2048 → 8192), so the padding waste cancels the extra lanes exactly. **Scaling the machine 4×
buys literally nothing for a padded decode.** This is the argument for T3, and it is stronger than
"decode is inefficient".

**After T3 the floor moves from M to P.** Splitting output columns and heads instead of rows needs
`Nout ≥ cores` for full occupancy — 256 at 4×4, 1024 at 8×8. Against Qwen's decode operations:

| operation | `Nout` | 4×4 | 8×8 |
|---|---:|---|---|
| FFN gate+up | 34,816 | ✓ | ✓ |
| FFN down | 5,120 | ✓ | ✓ |
| Attention Q+gate | 12,288 | ✓ | ✓ |
| Attention K+V | 2,048 | ✓ | ✓ |
| Attention O / GDN O | 5,120 | ✓ | ✓ |
| GDN QKV | 10,240 | ✓ | ✓ |
| GDN Z | 6,144 | ✓ | ✓ |
| **GDN a+b** | **128** | 50% of cores | **12% of cores** |

Only the a/b control projection is under-parallel, and it is 0.13% of decode MACs — so the P-split
is a complete answer for this model. Arithmetic intensity at `B = 32` is 32 flop/byte, well above
the 4 (4×4) and 8 (8×8) thresholds, so a correctly-expressed decode should be **compute-bound**.

### 5.4 Shapes to add to the sweep before committing to these

| shape | mesh | why |
|---|---|---|
| ~~`256×1024×512` fp16~~ | 4×4 | **Withdrawn as a tile candidate** — 3.50 of 3.61 MiB fully double-buffered (§5.0). Worth running only as evidence on how efficiency scales with N. |
| `4096×256×512` fp16 | 8×8 | 12.50 MiB strict, 2.36 spare — the *more rows* direction, unexplored, and it clears the row floor comfortably. **Queued 2026-08-23.** |
| `2048×512×512` fp16 | 8×8 | 9.0 of 14.86 MiB fully double-buffered instead of 6.50; in the manifest, not yet delivered. |
| `512×512×96` and `512×512×64` fp16 | 4×4 | the real GDN a/b output width, `P < 128` — untested at either mesh. 1.38 / 1.25 MiB strict. Measure, do not tune. **Queued 2026-08-23.** |
| ~~`512×2048×256` fp16~~ | 4×4 | **Withdrawn** — 6.50 MiB fully double-buffered against a 3.61 MiB L1. Proposed before §5.0 existed; it fails the rule this document sets. |
| `1024×2048×256` fp16 | 8×8 | replaces the line above and asks the same question — is tiling PV's 2,048-key contraction down to 512 the right split? 11.00 MiB strict, 3.86 spare. `2048×2048×256`, which would test it at the *chosen* row tile, needs 20 MiB and does not fit. **Queued 2026-08-23.** |

### 5.5 What has and has not actually been tested

Every tile named in §5.1 and §5.2 has a delivered **fp16** measurement at its own mesh — the numbers
above are measured, not modelled. Five gaps behind them, in order of how much they matter:

**(a) Correctness is essentially unvalidated, at both meshes.** This is the important one.

- The `[SPOT]` probe reaches **group 0 only** on every arm that has it. Core 0 wedges reading
  group 1's remote C address and never emits a second line — proven on an assertion-free 4×4 run
  that idled 840k further cycles with every counter at zero. A threshold the probe cannot reach is
  not a correctness signal.
- **38 of 55 delivered fp16 arms were killed by `$fatal`** — the MSHR clock-gate assertion at
  `mempool_group_mshr.sv:2258` / `:2261` ("clock gate dropped a sub-request / resp_buf write").
  The benchmark finishes *before* the kill, so `execution took N` and `[FPU FINAL]` are real and the
  cycle counts stand; everything after the kill, including the spotcheck, is lost.
- **All 41 delivered fp32 arms carry no correctness probe at all** — it is not compiled into the
  fp32 apps, and their only other check (`MATMUL_VERIFY`) is off by default because it wedges core 0.

So the honest statement is: **§5 is a performance plan resting on unvalidated results.** That is
acceptable for choosing a tile — a wrong result and a right result take the same number of cycles for
the same shape — and unacceptable for anything downstream of it. See
`project_matmul_verify_fp_wedge` and the open KB task `tasks/fix-resp-buf-clockgate-assertion`.

**(b) No fp32 at 8×8 for any chosen tile.** 4×4 has both precisions for all four tiles
(fp32: 89.0 / 85.2 / 87.1 / 87.3%). At 8×8 all three fp32 counterparts are **running now** and
undelivered, so the fp16-vs-fp32 question is open exactly where the mesh matters most.

**(c) The 8×8 PV arm is dirty.** `2048×512×256` reports **RH = 80, mshr_timeout = 320**. Response
hazards are precisely what bank-full backpressure eliminates at 4×4 — 2–8% efficiency to 54–91%,
with both counters driven to zero — and that treatment has **not** been applied at 8×8. Read 53.7%
as a floor for this tile, not as its number. The other two 8×8 tiles are clean (RH = 0, timeout = 0)
and the four 4×4 tiles are clean.

**(d) Two planned tiles are approximations of the real operation.**
GDN a+b is `P = 96` padded to 128, and `P < 128` has never been run at either mesh. PV's true
contraction is 2,048 keys and we tile it to 512 with no evidence that split is right. Both are in
the §5.4 list.

**(e) Decode WAS untested by construction; it no longer is.** ✅ **Superseded 2026-08-25** by the
decode work split (`MATMUL_DECODE_SPLIT`), which divides `P` as well as `M` and so makes `M = 32`
expressible at both meshes. Six arms delivered across both meshes and both precisions — see §5.6.
The batch-1 GEMV path remains unmeasured.

**Currently running and due to close (b), (c) and part of §5.4:** `fp32 2048×256×512`,
`fp32 2048×512×256`, `fp32 2048×512×128`, and `2048×512×512` at both precisions.

---

### 5.6 Decode — measured, and the `KERNEL_SIZE` rule (added 2026-08-25)

The decode split landed, so §5.3's "not expressible" is superseded. What governs decode is **not** a
tile shape but the **per-core slice of the output row**:

    slice = I * elem_bytes * B / (cores * KERNEL_SIZE)

`I` is the operation's output width (a model fact), `B = 32`, `cores` is the mesh. **`KERNEL_SIZE` is
the only free parameter**, and note the direction: **larger KS makes the slice SMALLER**. Target 128 B;
the hard floor is 64 B, below which the load stops being a burst and the run collapses (measured
directly at 48 B and 32 B: 2.5% and 1.6% efficiency, RH ~ 10^5).

#### Required KERNEL_SIZE per decode operation (fp16, B=32)

| operation | output `I` | 4×4 KS | 4×4 slice | 8×8 KS | 8×8 slice |
|---|---:|---:|---:|---:|---:|
| FFN gate / up (each) | 17,408 | 8 | 544 B | 8 | 136 B |
| Attention Q+gate | 12,288 | 8 | 384 B | 4 | 192 B |
| GDN QKV | 10,240 | 8 | 320 B | 4 | 160 B |
| GDN Z | 6,144 | 8 | 192 B | 2 | 192 B |
| FFN down · Attn O · GDN O | 5,120 | 8 | 160 B | 2 | 160 B |
| Attention K+V (fused) | 2,048 | 4 | 128 B | 1 | 128 B |
| **GDN a+b** | 128 | 1 | ⚠️ 32 B | 1 | ⚠️ 8 B |

**At 4×4 one `KS = 8` serves every operation but two.** At 8×8 each output width needs its own,
because the same width is spread over 4× the cores. **GDN a+b cannot be spread at all**: at `I = 128`
even `KS = 1` is far under the floor, so it must be **restricted to 64 cores** (25% of 4×4, 6.25% of
8×8) with the rest idle. It is 0.13% of decode MACs, so the restriction costs nothing — but spreading
it wider is the livelock region, not a slower run.

#### Delivered decode arms

| mesh | prec | `B×D×I` | slice | cycles | efficiency | TB util | state |
|---|---|---|---:|---:|---:|---:|---|
| 4×4 | fp16 | `32x128x4096` | 128 B | 15,697 | **52.2%** | — | done |
| 4×4 | fp16 | `32x256x4096` | 128 B | 24,867 | **65.9%** | — | done |
| 4×4 | fp32 | `32x128x2048` | 128 B | 13,291 | **61.6%** | 66.78% | done |
| 4×4 | fp32 | `32x256x2048` | 128 B | 25,768 | **63.6%** | 66.61% | done |
| 8×8 | fp16 | `32x128x16384` | 128 B | 48,825 | **16.8%** | 18.87% | done |
| 8×8 | fp16 | `32x256x16384` | 128 B | — | — | — | running |
| 8×8 | fp32 | `32x128x8192` | 128 B | 35,946 | **22.8%** | 26.01% | done |
| 8×8 | fp32 | `32x256x8192` | 128 B | — | — | — | running |

`D` is the contraction tile; the real operations contract over 5,120 / 6,144 / 17,408, so a full
operation is `D/D_tile` of these back to back. `D = 256` is worth **+26%** over `D = 128` at 4×4, but
at 8×8 fp16 it needs 8 MiB for `W` alone and therefore forces single buffering.

#### Decode does not scale with the mesh

Each 8×8 arm runs 4× the work on 4× the cores, so equal cycles would be perfect scaling:

| prec | 4×4 cycles | 8×8 cycles | throughput | of ideal 4.00× |
|---|---:|---:|---:|---:|
| fp16 | 15,697 | 48,825 | **1.29×** | 32% |
| fp32 | 13,291 | 35,946 | **1.48×** | 37% |

Prefill returns **3.10×** on the same hardware. The reason is structural: decode arithmetic intensity
is `B / elem_bytes` — **the tile dimensions cancel** — so no tiling scheme can make decode
compute-bound. Only batch can: 16 MAC/byte at `B=32`, 32 at `B=64`, 64 at `B=128`.

Full derivation: `docs/decode_tiling_analysis.md`. Live results: `docs/benchmarks/decode_gemm_results.md`.

---

## 6. Two flavours, one config each

4×4 and 8×8 are **not** a partition of one machine: the DMA has no support for carving an 8×8
cluster into 4×4 sub-clusters, so each is a separate flavour running the **whole** Qwen inference
end to end, under a **single hardware configuration held across every inference stage**. That
constraint is stronger than §5 assumed, and it has one real consequence plus one that turns out to
be free.

### 6.1 The consequence that is real: one MSHR tuning, not eleven

Every efficiency in §5 comes from a build whose MSHR tuning was **derived at compile time from that
shape's own `GEMM_M/N/P`** (`software/runtime/mshr_cfg.h`). In simulation that is fine — the base
configs ship `group_mshr_cfg_runtime := 1`, so software owns the tuning through CSR 11 and can
retune per operation at runtime.

**The tape-out configs used to pin it back to 0** — `config/terapool_spatz4_fpu_backend_{4x4,8x8}.mk`
argued that at `CfgRuntime=1` `mempool_group_mshr_cfg` stops const-folding and becomes real CSR flops
per group, "area this design does not need to tape out". That would have left silicon with **one
elaborated MSHR tuning for all eleven operations**, ten of them mistuned, and would have made every
per-shape number measured in simulation evidence for a part we were not building.

✅ **RESOLVED 2026-08-23 (user decision): the tape-out enables the runtime CSR config.** Both backend
configs now ship `group_mshr_cfg_runtime := 1`. Software retunes per operation through CSR 11, so
§5's per-shape numbers transfer to silicon and the one-config constraint stops costing anything on
the tuning axis. The price is CSR flops per group — ×16 at 4×4, ×64 at 8×8 — to be quantified in the
next backend run; if it proves large the fallback is to narrow the CSR fields, not to return to
const-folding.

**Which is cheap, because the work is not spread evenly.** Tuning for the dominant tile costs
degradation only on the special tiles, and those are almost nothing:

| flavour | dominant tile | share of prefill cycles | special tiles | share |
|---|---|---:|---|---:|
| 4×4 | `256×512×512` | **98.1%** | QK, PV, a+b | 1.9% |
| 8×8 | `2048×256×512` | **98.7%** | PV, a+b | 1.3% |

**This mattered while the pin stood, and it is now a safety margin rather than a constraint.** Even
if the CSR retune were unavailable, tuning the single config for the dominant tile would put the
whole cost on under 2% of the work. With `CfgRuntime = 1` shipping, each operation gets its own
tuning and the §5 arms are directly transferable — no re-run under a shared tuning is required.

### 6.2 The one that is free: off-chip bandwidth does not bind in prefill

The intuition that a smaller L1 forces smaller tiles and therefore more off-chip traffic is correct
in its first half and inverts in its second. Traffic for a tiled GEMM is
`A·⌈Nout/P⌉ + B·⌈S/M⌉ + C` — **the row tile M sets how many times every weight matrix is re-read.**

| flavour | tile | weight (B) traffic | total off-chip | compute | required BW | vs L2 BW |
|---|---|---:|---:|---:|---:|---|
| 4×4 | `256×512×512` | 396 GB | **616 GB** | 26,119 Mcyc | 23.6 B/cyc | 1,024 → **43× headroom** |
| 8×8 | `2048×256×512` | 178 GB | **270 GB** | 8,453 Mcyc | 31.9 B/cyc | 2,048 → **64× headroom** |

So 4×4 moves **2.3× more bytes** — `M = 256` makes eight passes over every weight matrix where
8×8's `M = 2048` covers the whole `S = 2048` sequence in one — but it also takes 3.1× longer, so its
required *rate* is **lower**, not higher. Arithmetic intensity is 83 MAC/byte at 4×4 and 188 at 8×8.

**Both are compute-bound by more than an order of magnitude.** At 1 GHz the requirement is ~24 GB/s
and ~32 GB/s, which any DRAM interface supplies — and it must be DRAM, not L2: one FFN matrix is
170 MiB against a 16/32 MB L2, so no layer's weights are ever L2-resident.

**This settles a trade in §5.1.** At 4×4, `M = 512` would halve weight traffic — four passes instead
of eight, 616 → 418 GB, 23.6 → 15.4 B/cyc — for 3.5 pp of efficiency (91.3% against 94.8%, +3.8%
cycles). With 43× bandwidth headroom that trade is not worth taking: **`M = 256` is right, and now
for a stated reason rather than because it measured highest.** Revisit only if a real memory system
turns out to be far weaker than L2, or at decode.

⚠️ **Decode is where this could invert and it is unmeasured.** At `B = 32` each weight is reused 32
times — 16 MAC/byte at fp16, against thresholds of 2 (4×4) and 4 (8×8) MAC/byte — so a correctly
expressed decode is also compute-bound. But nothing here is measured (§5.3), and at `B = 1` the
reuse collapses to 0.5 MAC/byte and both flavours become firmly memory-bound.

### 6.3 The two flavours, side by side

| | **4×4** | **8×8** |
|---|---|---|
| dominant tile | `256×512×512` | `2048×256×512` |
| efficiency on it | **94.8%** | 73.5% |
| whole prefill pass | 26,170 Mcyc | **8,453 Mcyc** |
| off-chip traffic | 616 GB | **270 GB** |
| required bandwidth | **23.6 B/cyc** | 31.9 B/cyc |
| GDN state, fp16, per sequence per layer | 1.50 MiB = **42% of L1** | **10% of L1** |
| batch that fits alongside the state | 1–2 | **8** |

The efficiency gap is real and it is the price of the mesh. What buys it back is not throughput on
the GEMM — it is that **only 8×8 can hold the Gated DeltaNet recurrent state at a useful batch**
(§8), and 48 of 64 layers are DeltaNet. A flavour that runs the projections 21 pp more efficiently
but cannot hold the state of three quarters of the model's layers is not the better machine for
*this* workload.

---

## 7. Coverage gaps Qwen exposes

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

## 8. Tranche plan

**T0 — shape mapping, no new kernel (days).**
Wrap the existing GEMM as `qwen_<workload>_<operation>` apps with the runtime
`logical=… tile=…` provenance line and `SHA256SUMS`. Publish the prefill projection claim from the
§4.1 anchors. *Blocker:* the fp16 M=128 wedge, if M=128 tiles are used at 4×4.
*Cheap addition:* the four sweep shapes in §5.4 — two of them can change the tile choice for nine operations.

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

## 9. Storyline

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
