# Qwen3.8-27B on TeraNoC–Spatz

This directory owns the new Qwen software: shared kernel extensions, streaming
operators, layer applications, host references, and focused tests. The first
deliverable is a complete streaming FFN using the existing Spatz GEMM/GEMV
kernels. This is the agreed development layout; applications are not implemented
yet and no new simulation campaign has been launched.

## Layout

```text
qwen_3_8_27b/
  common/           shared kernel adapters, tiling, DMA, and synchronization
  gemm_stream/      streaming GEMM/GEMV application and accumulation checks
  ffn_stream/       complete gate/up, SiLU-product, and down projection
  gdn_layer/        later Gated DeltaNet decoder layer
  attention_layer/  later full-attention decoder layer
  reference/        host tensor packing, reference outputs, model revision
  tests/            focused correctness and data-movement tests
```

Add implementations under these paths as each milestone starts. Keep generated
ELFs, packed tensors, traces, reports, and dashboards in dedicated GVSoC campaign
directories outside the source tree. Existing campaign artifacts and the two
existing benchmark apps remain independent baselines.

The parent Spatz Makefile discovers nested `main.c` files, but its shape and
post-link hash rules currently name only the two existing GEMM applications.
Nested application discovery alone does not provide Qwen build integration;
private output paths, dependencies, and hash metadata must be wired explicitly.

## Reusable kernels and first operator

- [FP32 kernels](../sp-fmatmul-opt-burst-merge/kernel/sp-fmatmul.c).
- [FP16 kernels](../sp-fmatmul-opt-burst-merge-fp16/kernel/sp-fmatmul.c).
- Runtime `gemm_config.h`, `gemm_hash.h`, `gemm_hash_precomputed.h`,
  `gemm_burst.h`, and `mshr_cfg.h` under `software/runtime`.

Preserve the existing inner vector-load pipeline. Add an outer weight-tile DMA
pipeline, explicit first-tile/accumulate behavior, operand strides, and a work
assignment compatible with the actual participants and vector lengths. Existing
microkernels initialize with FMUL on each call; repeated calls do not accumulate
across reduction tiles. The FP16 microkernel accumulates in FP16, so mixed
precision requires an explicit implementation and numerical validation.

The initial FFN retains X and H in L1, completes gate/up reductions before
applying SiLU and multiplication, then streams the down projection. Select
tile width, active groups, kernel size, and replication together. Precompute
hash choices for both alternating buffer addresses and packed strides.

The DMA schedule is initial fill, compute-current overlapping fill-next,
completion and reader-drain before buffer reuse, and final output drain. Use a
single DMA submitter initially. Prefer host-packed contiguous weight tiles for
the existing 1D frontend.

## MSHR policy

Keep the configured MSHR coalescing/cache behavior enabled in the planned
baseline. Do not introduce a cache-disable requirement or a separate coherence
redesign as a prerequisite to software development.

Rely on the existing self-invalidation contract: the effective reuse target must
be reached and subscriber responses must have drained before a cached entry
retires. A merge arriving in the same cycle vetoes retirement in RTL.
The effective target is `cache_reuse_target` when nonzero, otherwise the
per-class merge target. The current FP16 runtime commonly selects
`cache_reuse_target = 2 * hold_subs_single` to cover both halfwords of a scalar
word. Reaching the first merge cohort alone is therefore not always enough.

Treat this as a mapping and validation invariant: complete the expected uses
of each buffer generation, drain readers, and verify correct output over at
least three distinct tiles so that each alternating address is reused. Tail
tiles and reduced participant sets must have achievable targets. A barrier
does not itself invalidate cached responses.

## DMA and L2 reference audit, 16 September 2026

Use our RTL as the hardware contract, and the colleague model at
`/usr/scratch/badile48/msc26f31/gvsoc_teranoc/gvsoc` as a reusable implementation
and evidence source. That project has different compute and L1 configurations;
its performance figures are not automatically our calibration figures.

Current source comparison between our `pulp/pulp/teranoc_spatz` and the
colleague's `pulp/pulp/teranoc_v2` found:

| File | Comparison |
|---|---|
| `dma/teranoc_dma.cpp` | Byte-identical |
| `dma/idma_me_split.cpp` | Byte-identical |
| `dma/idma_me_dist.cpp` | Byte-identical |
| `l2_subsystem.py` | Byte-identical |
| `l2_interconnect/l2_address_scrambler.py` | Import namespace differs |
| `l2_interconnect/l2_noc.py` | Colleague additionally exposes `burst_wormhole` |

This checks source files, not the complete dependency trees or installed builds.
Trace the public iDMA backend, FlooNoC, group routers, and L1 DMA acceptance
boundary before deciding whether another mechanism needs porting.

The RTL frontend's sticky completion flag receives aggregated split completion
from `idma_split_midend`. Its different bookkeeping from the model's
issued/completed counters does not alone establish a software incompatibility.
Test multiple outstanding descriptors and completion/launch ordering directly.

Useful colleague evidence:

- `docs/archive/agent-sessions/claude/2026-08-07-1530-teranoc-v2-dma-bandwidth-fix.md`:
  historical 1 MiB transfer comparison and fixes for immediate acceptance,
  spill capacity, peripheral-sharing bottlenecks, and one address flit per
  burst. Reported model/RTL cycles were 1087/1086 for L2-to-L1 and 1116/1201
  for L1-to-L2 on that configuration. These are historical, not new results.
- `docs/archive/agent-sessions/claude/2026-08-08-0430-teranoc-v2-cold-dma-gap.md`:
  concurrent scalar/instruction traffic and L2-bank contention during initial
  transfers; useful hypotheses for cold versus steady-state measurements.
- `docs/reports/calibration-benchmark-coverage-20260908.md`: explicitly excludes
  DMA timing and whole-program timing from its kernel accuracy objective.

Future focused checks should measure cold/warm transfers, both directions,
queued transfers, same-bank contention, and DMA concurrent with vector compute
on our actual 4x4 and 8x8 geometries. Separate raw DMA timing, kernel timing,
and complete operator timing. Do not apply per-workload timing multipliers.

Current source profiles provide 16 MiB L2 at 4x4 and 32 MiB at 8x8. One
5120-by-17408 16-bit projection is 170 MiB, and the three FFN matrices total
510 MiB. Full streaming still needs an explicit backing-memory arrangement;
neither initial ELF loading nor an enlarged SRAM proves calibrated external
memory performance.

The broader deployment specification is
[the Qwen deployment plan](../../../../docs/qwen3_8_27b/qwen3_8_27b_teranoc_gvsoc_deployment_prompt.md).
