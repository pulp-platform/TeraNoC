# Qwen3.8-27B decode on TeraNoC -- canonical (simplified) operator shapes

Living document. Created 2026-09-28; update the table and the changelog at the bottom whenever a
dimension changes. Every app and every result should state which revision of this table it uses.

## Why simplified shapes

The goal is to show that TeraNoC+Spatz runs **workloads like** Qwen3.8-27B decode efficiently, not
to reproduce the checkpoint bit for bit (the software is still changing fast, and the weights are
synthetic). So dimensions that make the mapping awkward are rounded to a nearby value that maps
cleanly (user decision, 2026-09-28). The model's STRUCTURE is kept: layer pattern, head counts,
head dimensions, which operators exist and in what order.

**The mapping rule behind the choices.** A decode projection gives each core a column span of
`P / column_blocks` outputs, and at both meshes the work split lands on ~64 column blocks. Every
weight load bursts in full only if that span is a whole number of 64-byte stripes (32 fp16), so
**an output width `P` maps cleanly iff it is a multiple of 2048.** 5120 is not (80-column spans:
padding +20% W traffic, shorter bursts, or giving up MSHR merging), which is why hidden changes.
Contraction lengths `K` only need to split into an even number of K tiles, so they are unconstrained.

## Model dimensions

| dimension | real Qwen3.8-27B | **canonical** | note |
|---|---:|---:|---|
| hidden `d` | 5120 | **4096** | the one structural rounding: it is the output width of down and both o-projections |
| FFN intermediate `I` | 17408 | **16384** | = 2^14 (already used by `qwen-gate-up` as stored P) |
| layers | 64: [GDN, FFN] x3 + [attention, FFN], x16 | same | 48 GDN + 16 attention |
| attention Q heads x head_dim | 24 x 256 = 6144 | same | output gate adds another 6144 |
| attention KV heads x head_dim | 4 x 256 = 1024 | same | GQA ratio 6 |
| partial RoPE | first 64 of 256 dims, mrope 11/11/10 | same | |
| GDN key heads x dim (q, k) | 16 x 128 = 2048 | same | |
| GDN value heads x dim (v, z) | 48 x 128 = 6144 | same | |
| GDN a, b | 48 each | same | |
| GDN conv kernel | 4 | same | depthwise causal over the 10240 qkv channels |
| vocab | 248,320 | **deferred** | lm_head alone is 1.9 GiB at d=4096; > the 512 MiB simulated L2 |
| weights / activations | bf16 | **fp16** | bf16 is masked off in the compiled fpnew (T4) |
| accumulation | (reference: fp32) | **fp16** | open: validate against a host reference before any model-level claim |

## Projections (decode: `[B, K] x [K, P]`, B = independent sequences)

| operator | real `K -> P` | **canonical `K -> P`** | W fp16 | P % 2048 | status |
|---|---|---|---:|---|---|
| FFN gate | 5120 -> 17408 | **4096 -> 16384** | 128 MiB | yes | `qwen-gate-up` (measured at K=5120; rebuild with `qwen_k=4096`) |
| FFN up | 5120 -> 17408 | **4096 -> 16384** | 128 MiB | yes | `qwen-gate-up` |
| FFN down | 17408 -> 5120 | **16384 -> 4096** | 128 MiB | yes | planned: `qwen-ffn-down` |
| attn q + output gate (fused) | 5120 -> 12288 | **4096 -> 12288** | 96 MiB | yes | not started |
| attn k + v (fused) | 5120 -> 2048 | **4096 -> 2048** | 16 MiB | yes, but few outputs per core | not started |
| attn o | 6144 -> 5120 | **6144 -> 4096** | 48 MiB | yes | not started |
| GDN q + k + v (fused) | 5120 -> 10240 | **4096 -> 10240** | 80 MiB | yes | not started |
| GDN z (output gate) | 5120 -> 6144 | **4096 -> 6144** | 48 MiB | yes | not started |
| GDN a + b (fused) | 5120 -> 96 | **4096 -> 96** | 0.75 MiB | **no** -- tiny, needs its own mapping | not started |
| GDN o | 6144 -> 5120 | **6144 -> 4096** | 48 MiB | yes | not started |

Two fusions worth keeping in mind (same input X, one streamed GEMM): GDN q+k+v+z is
`4096 -> 16384`, exactly the gate/up shape; attention q+gate+k+v is `4096 -> 14336`.

Aspect ratios: gate/up, q+gate, qkv, z are **short K, wide P** (the `qwen-gate-up` regime); down and
both o-projections are **long K, narrow P** (the `qwen-ffn-down` regime -- the K split is the norm).

## Non-GEMM operators (per decode step)

| operator | canonical shape | where |
|---|---|---|
| RMSNorm (pre-mixer, pre-FFN) | `[B, 4096]`, eps 1e-6 | every layer, x2 |
| residual add | `[B, 4096]` | every layer, x2 |
| SwiGLU `SiLU(G) * U` | `[B, 16384]` | every FFN |
| GDN causal conv1d + SiLU | 10240 channels, kernel 4, state `[B, 10240, 3]` | GDN |
| GDN q/k L2-norm | 16 heads x 128 | GDN |
| GDN beta = sigmoid(b), decay from softplus(a) | 48 | GDN |
| GDN delta-rule state update + readout | 48 heads x `[128 x 128]` fp32 state | GDN |
| GDN gated RMSNorm `norm(o) * SiLU(z)` | 48 x 128 | GDN |
| attention q/k RMSNorm | 24 + 4 heads x 256 | attention |
| partial RoPE | 64 of 256 dims, q and k | attention |
| KV append + GQA attention (QK^T, online softmax, PV) | 24 q / 4 kv heads x 256, history S | attention |
| output gate `ctx * sigmoid(gate)` | `[B, 6144]` | attention |

## Capacity at canonical dims (simulated: L1 16 MiB 4x4 / 64 MiB 8x8, L2 512 MiB)

| item | size |
|---|---:|
| FFN weights (gate + up + down) | 384 MiB -- fit L2 together |
| attention-layer weights (without FFN) | 160 MiB |
| GDN-layer weights (without FFN) | 177 MiB |
| **one full decoder layer incl. FFN** | **544 MiB (attention) / 561 MiB (GDN) -- does NOT fit 512 MiB L2** |
| GDN recurrent state, per sequence per layer | 3 MiB (fp32) |
| GDN conv state, per sequence per layer | 60 KiB |
| KV cache, per sequence per attention layer per token | 4 KiB (fp16 K + V) |

The "full decoder layer" row is a Milestone B item, **resolved by decision (2026-09-28): give L2 a
larger `l2_size` when a kernel needs it** (a new RTL image and GVSoC profile at that point).

## Changelog

- 2026-09-28 -- created. hidden 5120 -> 4096, FFN intermediate 17408 -> 16384; all head counts and
  head dims unchanged; lm_head deferred. Same day: L2 will be enlarged when a layer needs it.
