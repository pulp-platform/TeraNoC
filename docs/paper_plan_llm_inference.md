# Paper plan — group-level request coalescing for LLM inference on a shared-L1 manycore

Working notes, 2026-08-17. Status: **plan, not results.** Everything under "Measured" is from the
4×4 / 8×8 campaigns; everything under "Proposed" is unrun. The point of separating them is that the
decode half of the story — the half that makes it an LLM paper rather than a GEMM paper — has no
data yet.

---

## 1. What is already measured, and what it actually says

| | |
|---|---|
| Platform | 4×4 mesh, 256 cores, 1024 FPU lanes; plus 8×8, 1024 cores, 4096 lanes |
| Workload | `sp-fmatmul-opt-burst-merge`, 22 completed GEMM shapes |
| vs. no-burst / no-MSHR baseline | **median 1.25× speedup**, efficiency **67% → 84%** |
| Best shapes | 96.6% (`128×1024×512`), 96.5% (`256×1024×256`) of roofline |
| 1024 cores | **77.5%** efficiency on `2048×512×512` (efficiency = ideal/actual, *not* the 82.2% fleet-util counter) |

### 1.1 Two findings that shape the paper

**Absolute efficiency is set by arithmetic intensity, not by our design.** Across 22 shapes,
`corr(efficiency, log AI) = +0.876`. AI is dominated by N, the reduction dimension: 96.6% at
N=1024, 53.3% at N=32. Coalescing shifts the whole curve up; it does not change what the curve is
a function of. Any claim of the form "our design makes low-AI shapes fast" is not supported.

**The speedup is flat across sharing configurations, and that is a result in itself.**

| B-sharing degree | n | mean speedup |
|---:|---:|---:|
| 1 | 4 | 1.215× |
| 2 | 8 | 1.210× |
| 4 | 10 | 1.246× |

`corr(speedup, share_b) = +0.18` — essentially nothing. The reason is structural: the two sharing
degrees are constrained by `s_A × s_B = cores_per_group = 16`, so as B-sharing falls A-sharing
rises to compensate, and the traffic-weighted aggregate only moves between 4.0× and 5.0×.

⚠️ **Do not claim "more sharing ⇒ more benefit."** The data says the opposite of interesting: the
benefit is *robust* to shape. That is the honest and still-attractive claim.

---

## 2. The thesis

Three steps, of which only the first two are currently evidenced:

1. **Reuse in GEMM is structural.** Computing `C[m][p]` requires all of row `m` of A and column `p`
   of B, so cores sharing a grid row need the same A and cores sharing a grid column need the same
   B. This is the structure Cannon and SUMMA are built on, and why the matmul communication lower
   bounds (Hong & Kung 1981; Irony, Toledo & Tiskin 2004) take their form.

2. **A group MSHR recovers SUMMA's broadcast in hardware.** In a shared-L1 machine there is no
   broadcast to orchestrate — every core issues an ordinary load and the sharing is latent in the
   address stream. Merging same-line requests and multicasting the reply obtains the same
   communication pattern with no change to the program, and degrades to ordinary loads when the
   sharing is absent.

3. **The optimal core grid is traffic-weighted, and it flips between prefill and decode.**
   Minimising `w_A/s_A + w_B/s_B` subject to `s_A·s_B = p` gives

   ```
   s_A : s_B  =  w_A : w_B      "share each operand as many ways as it generates traffic"
   ```

   Measured in prefill, A is scalar and B is a 16-word burst, so A issues ≈4× the requests and the
   optimum is a 2×8 grid, not the square 4×4 — worth 5.0× against 4.0×. **In decode the weights
   dominate overwhelmingly, so the optimum should flip to wide-in-m — and m is the batch
   dimension.** Step 3's decode half is the unrun part.

**One-line claim:** *batch size converts directly into NoC traffic reduction, through hardware that
does not change between the two phases — only the work split does.*

---

## 3. The gap that makes this a plan and not a paper

### 3.1 Decode shapes are not measurable under the current work split

The kernel requires `M ≥ num_groups × KERNEL_SIZE`: **128 at 4×4, 512 at 8×8.**

```
M=64   REJECTED: dim_group=M/16=4 must be a multiple of KERNEL_SIZE=8
M=128  split_m=1, split_p=16  ->  share_a=16, share_b=1
```

At the smallest legal M we land in exactly the **wrong** grid for decode — B private, all sharing
on A — when B (the weights) is the operand that matters. Reaching the decode regime needs either a
different tiling (split P across groups, split cores across the batch) or a large effective batch.

### 3.2 Weight matrices do not fit in L1

Usable L1 is **3.61 MB**. A single 1024×1024 fp32 weight matrix is 4 MB; 4096×4096 is 64 MB. So
**our measured shapes are on-chip tiles, not whole layers**, and any LLM framing must say so. A
real deployment streams weights from L2/HBM and our numbers describe the resident tile.

Two consequences worth stating rather than hiding:
- The paper measures the **on-chip tile**; end-to-end layer performance needs an L2 streaming study
  we have not done.
- The kernel is **fp32**. LLM inference is fp16/int8, which quadruples the tile that fits and
  changes both the burst geometry and the sharing arithmetic. Currently unmodelled.

### 3.3 Where the LLM serving techniques enter

The batch-enlarging techniques are not a convenience — they are a **requirement the architecture
places on the serving stack**, and that is a more interesting way to present them:

| technique | effect on effective M |
|---|---|
| continuous / in-flight batching | batch 32–256 |
| speculative decoding | × k (4–8 draft tokens verified per pass) |
| multi-token prediction (Medusa-style) | × number of heads |
| chunked prefill mixed with decode | raises M by folding prefill rows into the batch |

Batch 32 with 4-way speculation gives effective M = 128 — exactly our current 4×4 floor. At 8×8 the
floor is 512, so **scaling the machine out raises the batch the serving stack must supply**. That
is a quantitative, falsifiable systems claim and probably the most novel thing available here.

---

## 4. Proposed experiments

### 4.1 The batch ladder — the core new experiment

Hold `(N, P)` fixed, sweep M so that `share_b` goes 1 → 2 → 4 → 8 → 16 while `share_a` falls
inversely. This directly tests whether traffic tracks the B-sharing degree, which is the decode
claim. Best ladders (feasible under both the work-split guard and L1 capacity):

**Ladder A — N=128, P=256** (4 rungs, cheap: ideal 8k–65k)

| M | share_a | share_b | ideal | status |
|---:|---:|---:|---:|---|
| 256 | 8 | 2 | 8,192 | measured |
| 512 | 4 | 4 | 16,384 | measured |
| 1024 | 2 | 8 | 32,768 | **new** |
| 2048 | 1 | 16 | 65,536 | **new** |

**Ladder B — N=256, P=512** (4 rungs, spans 16k–131k)

| M | share_a | share_b | ideal | status |
|---:|---:|---:|---:|---|
| 128 | 16 | 1 | 16,384 | measured |
| 256 | 8 | 2 | 32,768 | **new** |
| 512 | 4 | 4 | 65,536 | measured |
| 1024 | 2 | 8 | 131,072 | **new** |

**4 new arms total.** Both ladders reuse already-measured rungs as anchors, so a discrepancy on
those is an immediate red flag rather than a silent inconsistency.

What to record per rung, beyond cycles: `alloc_single` / `merged_single` / `alloc_burst` /
`merged_burst`, so the achieved merge ratio can be checked against the predicted degree — that
prediction has matched exactly on every shape so far and is the paper's quantitative backbone.

### 4.2 Decode tiling (requires a kernel change)

Split **P** across groups instead of M, so a group owns all M rows for a P-slice and its 16 cores
divide along m. This should make `share_b` reachable at small M. Unscoped — needs a `sp-fmatmul`
variant, and is the largest piece of work in this plan.

### 4.3 8×8 confirmation

Repeat one ladder at 8×8, where the floor is M ≥ 512. This is what substantiates "scaling out
raises the batch requirement" rather than asserting it.

### 4.4 Cheap additions worth having

- **`hold_subs_burst` sensitivity per rung** — the runtime CSR makes this configs-per-simulation
  rather than a rebuild each, which is precisely what that feature was built for.
- **fp16 tile** — quadruples the resident tile and changes the burst geometry; even one point would
  show whether the fp32 result transfers.

---

## 5. Risks

| risk | note |
|---|---|
| Decode tiling may not reach high `share_b` | If cores cannot be split along a small batch, the whole decode story collapses to "use bigger batches", which is weaker |
| The `s_A × s_B = 16` constraint caps the aggregate | Total reduction stays in the 4–5× band regardless of grid, so the flip may move *which* operand benefits without moving total traffic much. **Test this before building the narrative on it.** |
| fp32 → fp16 may change the conclusion | Burst covers 16 words either way, so a fp16 burst spans 2× the elements and the sharing arithmetic shifts |
| On-chip-tile framing may be seen as not-really-LLM | Pre-empt by stating it plainly and scoping the claim to the tile |

---

## 6. What to reuse

- `docs/benchmarks/gemm_results_vs_nofeature.{txt,tsv}` — the headline comparison, regenerable
- `docs/progress_report_2026-08.html` — §1.1 has the reuse derivation and the traffic-weighted
  optimum in presentable form
- `docs/benchmarks/gemm_results_8x8_1024core.md` — the scaling data and its caveats
- `scripts/gemm_autotune.py` — derives the sharing degrees; `derive(M,N,P)` also reports why a
  shape is rejected, which is how the ladders above were found
