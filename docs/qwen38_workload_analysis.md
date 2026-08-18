# Qwen3.8-27B as a target workload for TeraNoC — kernel extraction and feasibility

Investigation, 2026-08-18. Status: **analysis, no measurements yet.** Every hardware claim is
verified against RTL/config in this tree (file:line given); every model number is from
`Qwen/Qwen3.8-27B`'s published `config.json`. Nothing here has been simulated.

Both meshes are carried throughout: **4x4** (`terapool_spatz4_fpu`, 256 cores) and **8x8**
(`terapool_spatz4_fpu_8x8`, 1024 cores). They do not merely scale — several conclusions *invert*
between them, and that turns out to be the most interesting result in this document.

---

## 0. The headline

1. **Qwen3.8-27B is not a normal transformer.** 48 of its 64 layers are *Gated DeltaNet* — linear
   attention with a recurrent state — and only 16 are ordinary attention. "Extract the typical LLM
   kernels" is therefore not the usual GEMM + softmax + RoPE list.
2. **The model ships in bfloat16 and this hardware has bfloat16 switched off.** IEEE fp16 works and
   is 2x faster than fp32; bf16 is one masked-off bit in the fpnew config. Decide this before
   writing any kernel.
3. **The DeltaNet recurrent state is 3.0 MiB per sequence per layer.** At 4x4 that is 83% of the
   whole usable L1 at batch 1 — a wall. At 8x8 it is 20%, and the batch that fits (8, in fp16) is
   *exactly* the batch needed to be compute-bound. **The 8x8 mesh is what makes this model's
   dominant layer type viable at all**, and that is a scaling argument the GEMM campaign could not
   have produced.

---

## 1. What the model actually is

From `config.json` (`architectures: Qwen3_5ForConditionalGeneration`):

| | |
|---|---|
| Layers | 64 |
| Hidden size | 5120 |
| FFN intermediate | 17408, SwiGLU (`hidden_act: silu`) |
| Vocab | 248,320 (untied embeddings) |
| Norm | RMSNorm, eps 1e-6 |
| Weights dtype | **bfloat16** |
| Context | 262,144 native |
| Multimodal | yes — SigLIP-style ViT (depth 27, hidden 1152, patch 16) |
| MTP | `mtp_num_hidden_layers: 1` — native multi-token prediction |

### 1.1 The layer pattern — the important part

`full_attention_interval: 4` and the explicit `layer_types` list give a repeating block:

```
[ DeltaNet -> FFN ] x3  ->  [ Gated Attention -> FFN ]     ... x16  =  64 layers
```

**48 DeltaNet layers, 16 full-attention layers.**

**Gated Attention** (the 16): GQA, 24 query heads, 4 KV heads, `head_dim: 256`.
`attn_output_gate: true` adds a second 5120x6144 projection. `partial_rotary_factor: 0.25` — RoPE
touches only 64 of 256 head dims, mrope-interleaved (sections 11/11/10) because the model is
multimodal.

**Gated DeltaNet** (the 48): linear attention with a per-head recurrent state.
`linear_num_key_heads: 16`, `linear_num_value_heads: 48`, both head dims 128,
`linear_conv_kernel_dim: 4` (short causal conv before the recurrence), `output_gate_type: swish`,
and — critically — `mamba_ssm_dtype: float32`.

The mental model: instead of keeping every past key/value and re-scanning them (a KV cache),
DeltaNet keeps a fixed-size matrix `S` per head and updates it once per token:

```
per value head h:   S_h  <-  alpha * S_h  +  beta * k v^T        (rank-1 update, 128x128)
                    o_h  =   S_h^T q                             (matvec,        128x128)
```

`S` never grows with sequence length. That is how the model reaches 262k context without a
terabyte of cache — and why the memory behaviour of 3 in every 4 layers is unlike any GEMM
benchmark.

### 1.2 Parameter budget

| block | shape | params | fp16 |
|---|---|---:|---:|
| DeltaNet q_proj / k_proj | 5120 x 2048 | 10.5 M each | 21 MB |
| DeltaNet v_proj / o_proj / gate | 5120 x 6144 (o: 6144 x 5120) | 31.5 M each | 63 MB |
| Attn q_proj / gate | 5120 x 6144 | 31.5 M each | 63 MB |
| Attn k_proj / v_proj | 5120 x 1024 | 5.2 M each | 10 MB |
| Attn o_proj | 6144 x 5120 | 31.5 M | 63 MB |
| **FFN gate / up / down** | **5120 x 17408** | **89.1 M each** | **178 MB each** |
| embed / lm_head | 248320 x 5120 | 1.27 B each | 2.5 GB each |

**26.9 B params, 53.7 GB fp16.** One DeltaNet layer is 115 M params, one attention layer 105 M;
the FFN attached to *every* layer is 267 M — the FFN alone is 70% of non-embedding weights.

---

## 2. Where the time goes (decode, batch 1, per token)

| kernel | MACs | share |
|---|---:|---:|
| FFN (SwiGLU) x64 | 17,113 M | **66.9%** |
| DeltaNet projections x48 | 5,537 M | 21.6% |
| Attention projections x16 | 1,678 M | 6.6% |
| lm_head (1 x 5120 x 248320) | 1,271 M | 5.0% |
| DeltaNet state update x48 | 76 M | 0.3% |
| **total** | **25,598 M** | **51.2 GFLOP/token** |

Attention scores (`QK^T`, `PV`) are absent because at decode they are O(T) and negligible; at
prefill they matter — 0.8% of a token's cost at T=1024, 11.2% at T=16384.

**~95% of the work is plain GEMM.** Good news: `sp-fmatmul-opt-burst-merge` already runs GEMM at
84-96% of roofline at 4x4 and 77.5% at 8x8. The exotic parts of the model are cheap in flops and
expensive in memory behaviour — exactly the regime TeraNoC exists to study.

---

## 3. What this hardware can and cannot do

Audited against `working_dir/spatz/hw/ip/spatz/src/` — the *compiled* Spatz, not
`hardware/deps/spatz`, which is stale and unused. **All of §3 is mesh-independent**: 4x4 and 8x8
instantiate the identical core, same `n_fpu=4`, `vlen=512`, `rvf=1`, `rvd=0`.

### 3.1 Number formats — `spatz_pkg.sv:384`

```systemverilog
//              FP32  FP64  FP16  FP8   FP16a FP8a
FpFmtMask    : {RVF,  1'b0, 1'b1, 1'b0, 1'b0, 1'b0},
//              INT8  INT16 INT32 INT64
IntFmtMask   : {1'b0, 1'b1, 1'b1, 1'b0}
```

In `fpnew_pkg.sv:52-59`, `FP16ALT` is `{8 exp, 7 mantissa}` — **that is bfloat16, and it is 0.**

| format | supported | note |
|---|---|---|
| fp32 | yes | what current kernels use |
| **fp16 (IEEE)** | **yes** | 2x throughput — see 3.3 |
| **bf16** | **NO** | the format the model ships in |
| fp8 | no | |
| **int8** | **NO** | so no int8 quantised inference |
| int16 / int32 | yes | |

**Consequence.** Weights must be converted bf16 -> fp16 offline. These are not interchangeable:
bf16 has an 8-bit exponent (range ~1e38); fp16 has 5 bits (max 65504, smallest normal 6e-5). LLM
weights usually survive; *activations* — attention logits before softmax, residual-stream outliers
— are the known overflow risk. Mitigation is per-tensor scaling: real work, and it belongs in the
plan rather than being discovered later.

**Or fix it in hardware:** enabling bf16 is flipping index 4 of `FpFmtMask` to 1. The ADDMUL unit
is already `MERGED` multi-format, so the cost is a wider format mux, not a new datapath. With a
backend flow imminent, quantifying that area delta is cheap — and "we added bf16 because the
target model needs it" is a defensible PPA story at both meshes.

### 3.2 Instructions Spatz actually decodes — `spatz_decoder.sv`

**Present and useful:**

| | |
|---|---|
| `vfmacc/vfmadd/vfmsac/…` (vv + vf) | fp32 and fp16 FMA — the GEMM inner loop |
| **`vfwmacc.vv/vf`, `vfwmul`** | fp16 x fp16 -> **fp32 accumulate**. The key fp16 GEMM primitive |
| `vfredusum / vfredosum / vfredmax / vfredmin` | softmax max+sum, RMSNorm sum-of-squares |
| `vfmax / vfmin` | clamps, softmax stabilisation |
| `vfslide1up / vfslide1down` | the DeltaNet 4-tap causal conv |
| `vlse` (strided), `vluxei / vsuxei` (indexed) | embedding gather, non-unit-stride operands |
| `vfncvt.f.f.w` | fp32 -> fp16 narrowing |
| integer compares -> mask, `vmerge` | masking, select |

**Absent — each costs you something:**

| missing | why it hurts | workaround |
|---|---|---|
| `vfdiv`, `vfsqrt` | softmax divide, RMSNorm rsqrt | software |
| **`vfrec7`, `vfrsqrt7`** | RVV's cheap 7-bit Newton seeds | full polynomial instead |
| **fp compare -> mask** (`vmflt/vmfeq/vmfle`) | causal masking, any FP conditional | additive -inf mask (standard anyway), or compare the integer bit pattern |
| `vrgather` | arbitrary permute — RoPE pairing | strided loads (`vlse`) or split half-vectors |
| `vfwcvt.f.f.v` | fp16 -> fp32 widening | `vfwadd.vf` against 0.0 |

`fpnew` also has `DIVSQRT: DISABLED` and `FDivSqrt = 1'b0` (`spatz_pkg.sv:360,401`) — there is
genuinely no divider in the vector unit, not merely no instruction for one.

**Trap:** `VFWDOTP_VV/VF` *is* in the decoder, but fpnew's `SDOTP` unit is `DISABLED`
(`spatz_pkg.sv:405`). Do not use it — it decodes into a unit that isn't there.

### 3.3 fp16 really is 2x — verified

`spatz_vfu.sv:137` gates lanes on element width:

```systemverilog
(spatz_req.vtype.vsew == EW_32 ? 4'hf : 8'hff)
```

The VFU processes `N_FU * ELEN = 128` bits/cycle regardless of format — 4 lanes at fp32,
**8 lanes at fp16**. Per core: 4 fp32 FMA/cycle or 8 fp16 FMA/cycle.

fp16 buys three things at once: 2x arithmetic, 2x weights per L1 byte, and 2x payload per NoC
burst (a 16-word burst carries 32 fp16 values instead of 16 fp32). Highest value-per-effort item
in this plan, at either mesh.

### 3.4 The transcendentals you must write

None exist for Spatz today. The `mempool_softmax_f16.h` / `mempool_layernorm_f16.h` kernels in
`software/kernels/baremetal/` **cannot be reused** — they are built on XpulpV2 SIMD
(`pv.shuffle2.h`, `vfmax.h`, `vfcpka.h`), and Spatz configs set `xpulpimg = 0` and compile
`-march=rv32imafvzfh`. Those instructions do not exist on this target.

| needed by | function | approach |
|---|---|---|
| RMSNorm | `1/sqrt(x)` | fast-inverse-sqrt bit trick + 2 Newton iterations, all in vector regs |
| SwiGLU | `sigmoid(x)` (SiLU) | polynomial, or `exp` + one reciprocal |
| Softmax (16 layers) | `exp(x)`, `1/sum` | exponent-manipulation `exp2` + mantissa polynomial; Newton reciprocal |
| DeltaNet gates | `swish`, `sigmoid` | shares the SwiGLU code |

~10-20 vector instructions each; budget them as one focused task, not an afterthought inside each
kernel.

---

## 4. The two meshes, side by side

Derived from `config/terapool_spatz4_fpu.mk`, `config/terapool_spatz4_fpu_8x8.mk`,
`config/config.mk`, and `software/runtime/arch.ld.c`.

| | **4x4** | **8x8** | ratio |
|---|---:|---:|---:|
| cores / groups | 256 / 16 | 1,024 / 64 | 4x |
| fp32 FMA/cycle | 1,024 | 4,096 | 4x |
| fp32 peak flop/cyc | 2,048 | 8,192 | 4x |
| **fp16 peak flop/cyc** | **4,096** | **16,384** | 4x |
| L1 total | 4 MiB | 16 MiB | 4x |
| L1 addressable | 3.75 MiB | 15.00 MiB | 4x |
| L1 usable (autotune) | **3.61 MiB** | **14.86 MiB** | 4x |
| L1 bandwidth | 16 KiB/cyc | 64 KiB/cyc | 4x |
| L2 banks / size | 16 / 16 MB | 32 / 32 MB | 2x |
| **L2 bandwidth** | **1,024 B/cyc** | **2,048 B/cyc** | **2x** |
| word stride (address layout) | 16,384 | 65,536 | 4x |
| **kernel work-split floor `M >=`** | **128** | **512** | 4x |

**The one asymmetry that matters: compute and L1 scale 4x, but L2 bandwidth only 2x.** Everything
in §4.2 follows from that single line.

### 4.1 Capacity — weights do not fit, at either mesh

| | fp16 size | vs 4x4 L1 | vs 8x8 L1 |
|---|---:|---:|---:|
| one FFN matrix (5120 x 17408) | 170 MiB | 47x | 11x |
| one full FFN | 510 MiB | 141x | 34x |
| one DeltaNet layer's weights | 220 MiB | 61x | 15x |
| whole model | 53.7 GB | 15,000x | 3,700x |

So every kernel is a *tile* of a layer at both meshes, and the honest framing stays what the paper
plan already says: **we measure the on-chip tile.** L2 is 16/32 MB — also far short of a layer —
so a real deployment streams DRAM -> L2 -> DMA -> L1. That path exists and is already used
(`dma_memcpy_blocking`, `sp-fmatmul.../main.c:329`).

### 4.2 Bandwidth — and why the batch threshold *doubles* at 8x8

Decode arithmetic intensity is just the batch size: each weight is loaded once and used B times,
so `AI = 2*B*K*N / (2*K*N) = B` flop/byte in fp16.

| mesh | fp16 peak | L2 BW | flop/byte needed | **compute-bound at** |
|---|---:|---:|---:|---:|
| 4x4 | 4,096 flop/cyc | 1,024 B/cyc | 4 | **B >= 4** |
| 8x8 | 16,384 flop/cyc | 2,048 B/cyc | 8 | **B >= 8** |

> **Scaling the mesh 4x doubles the batch you must supply just to keep the machine fed.**

That is the same claim as §3.3 of the paper plan ("scaling out raises the batch requirement"), but
derived from bandwidth rather than from the kernel's work split — an *independent* second route to
it. Note the two routes give different numbers (bandwidth says B>=4/8, the work split says
M>=128/512) and the work split is the binding constraint today.

At B=1, 4x4: 51.2 GB of weights per token against 12.5 M cycles of compute — **4x more time
streaming than computing**, even fully L2-resident. At 8x8 the same token needs 3.1 M cycles of
compute against 25 M cycles of streaming — **8x**. Decode without batch gets *worse* with scale.

### 4.3 The new wall — DeltaNet state, and how the meshes differ

`48 value heads x 128 x 128 x 4 B (fp32) = 3.00 MiB` **per sequence, per layer** (1.50 MiB fp16).

Percentage of *usable* L1:

| mesh | dtype | B=1 | B=2 | B=4 | B=8 |
|---|---|---:|---:|---:|---:|
| 4x4 | fp32 | **83%** | 166% | 332% | 665% |
| 4x4 | fp16 | 42% | 83% | 166% | 332% |
| 8x8 | fp32 | 20% | 40% | 81% | 162% |
| **8x8** | **fp16** | **10%** | **20%** | **40%** | **81%** |

**This is where the two meshes genuinely diverge.**

- **At 4x4 the state and the batch are in direct conflict.** Compute-boundness needs B >= 4; the
  state does not fit past B=1 in fp32 or B=2 in fp16. There is no batch that satisfies both.
- **At 8x8 they line up.** B=8 in fp16 puts the state at 81% of L1 — and B >= 8 is exactly the
  compute-bound threshold from §4.2. The mesh that makes the bandwidth problem *harder* is the
  mesh that makes the capacity problem *solvable*, and the two land on the same number.

The remaining conflict at 8x8 is the kernel's own floor, `M >= 512`, which is 64x the batch the
state allows. That is not fatal — it says the DeltaNet layer must be tiled along **heads**, not
along batch (§5, item 6), which is a different work split from the GEMM kernel's.

**Head-parallel tiling — locality, not capacity.** Splitting the 48 v-heads across groups gives
exactly **3 heads/group at 4x4** (48/16) and **0.75 at 8x8** (48/64, so 16 groups idle unless a
head's 128x128 state is itself split, or unless batch >= 2 supplies 96 head-instances). To be
precise about what this buys: L1 is one shared pool, so head-parallelism does **not** reduce the
aggregate footprint above — it makes each group's state live in *its own* banks, so the
read-modify-write that happens every token generates **zero NoC traffic**. Given the state is
touched twice per token per layer, that is a large win and it is the natural mapping.

### 4.4 KV cache, for completeness

The 16 full-attention layers cache `2 x 4 heads x 256 dims x 2 B = 4 KiB` per token per layer =
**64 KiB/token** model-wide. At T=4096 that is 256 MiB — 71x the 4x4 L1, 17x the 8x8 L1. The
hybrid design is what keeps this from dominating; an all-attention 64-layer model of this width
would be 4x worse.

---

## 5. Kernel inventory — what exists, what must be written

| # | kernel | layers | % decode flops | status |
|---|---|---|---:|---|
| 1 | **GEMM / skinny-GEMM** (all projections + FFN) | all | ~95% | **exists**, fp32: `sp-fmatmul-opt-burst-merge`, 84-96% at 4x4, 77.5% at 8x8 |
| 2 | **GEMV** (batch-1 decode) | all | — | exists: `gemv-opt` (fp32), `gemv` (fp16) |
| 3 | **fp16 GEMM** with `vfwmacc` | all | — | **to write** — 2x everything |
| 4 | **RMSNorm** | all | <1% | **to write** (needs rsqrt) |
| 5 | **SwiGLU** | all | <1% | **to write** (needs sigmoid) |
| 6 | **Gated DeltaNet step** | 48 | 0.3% flops, high memory | **to write** — the distinguishing kernel; head-parallel work split |
| 7 | **Causal conv1d, k=4** | 48 | tiny | **to write** (`vfslide1up`) |
| 8 | **GQA attention + softmax** | 16 | O(T) | **to write** |
| 9 | **Partial RoPE (25%, mrope)** | 16 | tiny | **to write** |
| 10 | Embedding gather / lm_head + argmax | 1 each | 5% | **to write** (`vluxei`) |
| 11 | Vision tower (ViT depth 27) | — | prefill only | out of scope for now |

Items 4, 5, 8, 9 are individually small but they **serialise between GEMMs**, so they set the floor
on how close a real layer gets to the GEMM-only roofline. Worth measuring precisely because the
GEMM number alone will overstate what a layer achieves — and the overstatement is *larger at 8x8*,
where the same serial section sits in front of 4x the lanes (Amdahl).

---

## 6. Proposed staging

### Stage A — map real Qwen shapes onto the GEMM you already have (days, no new code)

The FFN is 67% of decode flops and is plain GEMM. Pick L1-legal tiles matching Qwen's aspect
ratios; several are already-measured shapes, so they come with anchors.

| Qwen op | full shape | 4x4 tile | 8x8 tile |
|---|---|---|---|
| FFN gate/up | [B x 5120] x [5120 x 17408] | `M x 512 x 512`, M=128/256/512 | `M x 512 x 512`, M>=512 |
| FFN down | [B x 17408] x [17408 x 5120] | same | same |
| DeltaNet v/o/gate proj | [B x 5120] x [5120 x 6144] | same | same |
| Attn q/gate proj | [B x 5120] x [5120 x 6144] | same | same |

At 4x4, M=128/256/512 at N=P=512 are exactly the campaign's measured rungs — the mapping costs
nothing. At 8x8 the floor is M>=512, and the campaign's `2048x512x512` point (77.5%) is the
anchor; 14.86 MiB of usable L1 also permits considerably larger tiles than 4x4, which is worth
sweeping since bigger tiles raise arithmetic intensity and 8x8 needs it more (§4.2).

Deliverable: "the Qwen3.8 FFN tile runs at X% of roofline on TeraNoC, at both meshes" with
essentially zero new kernel work.

Watch the `share_a = 2` regime — fixed in `gemm_autotune.py` on 2026-08-18, and §7 of the paper
plan notes it sits *directly* on the decode path.

### Stage B — fp16 GEMM (the biggest single win, and it matters more at 8x8)

`vfwmacc.vv` gives fp16 x fp16 -> fp32 accumulation, so numerics stay respectable while
throughput, L1 capacity and NoC payload all double. It is worth more at 8x8 because that mesh is
the more bandwidth-starved of the two (§4.2) and because fp16 state is what makes B=8 fit (§4.3).
Prerequisite: decide the bf16 -> fp16 conversion + scaling story (§3.1).

### Stage C — the glue kernels

RMSNorm, SwiGLU, softmax, RoPE, plus the shared transcendental library (§3.4). Write the
polynomials once, test standalone against a host reference, reuse everywhere.

### Stage D — the Gated DeltaNet step

The model's distinguishing kernel and the one that exercises the L1-resident-state regime this
machine should be good at. Decode form: rank-1 update + matvec per head, all L1-resident, tiled
head-parallel (3 heads/group at 4x4). Prefill form: the chunked scan, which turns the recurrence
into small GEMMs.

### Stage E — one full layer

**Do a DeltaNet layer, not an attention layer.** 48 of 64 layers are DeltaNet, its state is
L1-resident, and it is the piece nobody has measured on a shared-L1 manycore. Attention is the
more familiar kernel and can follow.

**Which mesh?** Bring it up at **4x4** — faster elaboration (~7 min vs hours), 3 heads/group
divides cleanly, and the shorter turnaround matters while the kernel is still wrong. Then take the
*measurement* to **8x8**, because §4.3 says 8x8 is the only mesh where a useful batch and the
state both fit. Expect the interesting result to be at 8x8 and the debugging to happen at 4x4.

### Stage F — end-to-end / GVSOC

No GVSOC model in this tree — out-of-repo work. Decide early whether GVSOC is for functional
bring-up (fast, approximate) with RTL reserved for the performance claims; that split usually
works, and it is the only tractable way to run 64 layers.

---

## 7. Open questions

1. **bf16 or fp16?** Convert offline and accept the range risk, or spend area to enable
   `FP16ALT`? A backend flow is imminent at both meshes, so the area number is cheap now.
2. **What precision is the DeltaNet state?** The config says fp32. fp16 halves a 3 MiB/seq/layer
   footprint — at 8x8 that is the difference between B=4 and B=8 fitting, i.e. between
   bandwidth-bound and compute-bound. Needs an accuracy check.
3. **Verify the state layout.** The 3.00 MiB figure assumes 48 states of `d_k x d_v` = 128x128,
   inferred from `linear_num_value_heads` / `linear_key_head_dim` / `linear_value_head_dim`.
   Confirm against the reference implementation before building on it.
4. **Batch source.** The kernel needs M >= 128 at 4x4, >= 512 at 8x8. Qwen3.8 has native MTP
   (`mtp_num_hidden_layers: 1`), which multiplies effective batch for free — worth folding into
   the paper plan's §3.3 table, since it is a property of *this model* rather than a serving-stack
   assumption.
5. **Does 8x8 need more L2 bandwidth?** `l2_banks` is 16 at 4x4 and 32 at 8x8 while compute goes
   4x. If the Qwen decode shapes prove L2-bound at 8x8 — which §4.2 predicts — then `l2_banks`
   is a first-class knob for this workload and belongs in the sweep.
6. **Does the vision tower matter?** Prefill-only and a different shape regime (ViT, patch 16,
   depth 27). Probably out of scope, but it is why the model is interesting to deploy.

---

## 8. Sources

- `Qwen/Qwen3.8-27B` `config.json` and model card (huggingface.co) — released 2026-08-14
- `working_dir/spatz/hw/ip/spatz/src/generated/spatz_pkg.sv` — FPU format masks, unit enables
- `working_dir/spatz/hw/ip/spatz/src/spatz_decoder.sv` — decoded instruction set
- `working_dir/spatz/hw/ip/spatz/src/spatz_vfu.sv:137` — fp16 lane doubling
- `hardware/deps/fpnew/src/fpnew_pkg.sv:52-59` — FP16ALT is bfloat16
- `config/terapool_spatz4_fpu.mk`, `config/terapool_spatz4_fpu_8x8.mk`, `config/config.mk`
- `software/runtime/arch.ld.c`, `scripts/gemm_autotune.py` — L1 capacity model
- `docs/paper_plan_llm_inference.md` — the batch/sharing thesis this feeds into
