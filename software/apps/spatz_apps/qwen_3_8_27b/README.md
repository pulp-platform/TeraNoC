# Qwen3.8-27B streaming operators

The first implementation provides a complete tiled FFN:
`H = SiLU(X Wgate) * (X Wup)`, followed by `Y = H Wdown`.
It also supplies a standalone streamed GEMM/GEMV and a queued DMA probe.
The same sources build for 4×4 and 8×8 meshes. Gated DeltaNet, attention,
normalization, pretrained weights, and full-model inference are later work.

## Source and build layout

- `common/stream.h`: native-kernel adapter, weight streaming, outer reduction,
  scalar SiLU, synchronization, and software instrumentation.
- `ffn_stream/main.c`: complete FFN application.
- `gemm_stream/main.c`: one streamed projection.
- `dma_probe/main.c`: eight transfers, two outstanding descriptors and two
  L1 buffers, with different L2 bank mappings and repeated buffer reuse.
- `build.py`: isolated build, host packing/reference, ELF and source checksums.

The builder copies runtime/config/kernel sources into its output directory.
It does not rebuild or modify the shared GEMM apps, runtime objects, or ELFs.
Use a **new absolute output directory** for each build. Python needs NumPy and pyelftools.
The current toolchain defaults come from this checkout's `install/llvm` and
`install/riscv-gcc`. A manifest preserves exact compiler commands and source
hashes; `workload.map` preserves the linker memory allocation.

```sh
/usr/bin/python3.12 build.py --out /ABS/NEW/ARM --mesh 4 \
  --app ffn_stream --precision 16 --batch 4 \
  --hidden 256 --intermediate 512 --kt 64 --pt 512 --ks 1 --overlap 1
```

Use `--mesh 8` for the larger machine and `--overlap 0` for the serialized
weight-transfer baseline. The real model dimensions are `--hidden 5120
--intermediate 17408`; the first full-size experiment uses KT=256, PT=1024,
KS=1, FP16 and batches 1/4. Its 510 MiB of synthetic weights require the
explicit `--l2-bytes 536870912` capacity experiment described below. Normal
16/32 MiB L2 builds cannot hold those three matrices.

## Reuse and scheduling

The builder takes the existing FP32 or FP16 `sp-fmatmul.c` from the sibling
burst-merge application. It adapts **only the C row stride** into a private
header, checking the expected source patterns before substitution. The vector
ASM, A/B strides and load pipeline remain intact. Calls operate on native
64-byte column chunks and accumulate their partial C results into FP32 scratch.

Weights are packed `[P tile, K tile, KT, PT]`; X is packed `[K tile, batch, KT]`.
Each projection starts by filling buffer 0. For each K tile, core 0 starts the
next transfer into the other buffer, all active cores compute the current tile,
readers drain at a barrier, and core 0 waits for DMA completion before advancing.
The two buffers alternate through the entire reduction. Gate/up finish before
SiLU; producers directly store H into the down projection's packed A layout.
The complete output remains in L1 for the host checker.

Larger FP32 wrappers remain out of line and disable unrolling in the scalar
accumulation loops to fit the 512-byte stack. Compiler `.su` files and the
manifest record frames; frames above 384 bytes fail the build. Check complete
call-chain stack usage when extending the code.

Partial results and FP32 accumulators use source-local 64-byte tile stripes.
This avoids subjecting unique scalar metadata loads to vector sharing targets.
Only core 0 accesses the tile-event index. Buffer starts and L2 operands are
aligned to a full mesh stripe (16/64 KiB); weight slots additionally preserve
the hash selector's 64 KiB address period.

The default work assignment chooses whole active groups with at least a
64-byte B vector per core. `--active-groups` can select a legal divisor.
This is a correctness-first baseline, **not an optimal mapping**: all physical
cores still participate in global barriers. The first full-size B1/B4 runs use
2/8 active groups on either mesh. Increasing the physical mesh alone therefore
does not increase participating compute. Concurrent P tiles and cheaper
participant-aware synchronization are the next mapping experiments.

## Numerical contract and telemetry

Data are deterministic synthetic values, not pretrained parameters. The model
configuration was checked at Qwen/Qwen3.8-27B revision
`1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`; its pretrained BF16 weights are not
interchangeable with the current FP16 experiments for quality claims.

Each existing kernel initializes with FMUL and accumulates the rest of its K
tile in native FP16/FP32. The wrapper adds K-tile partials in FP32. Scalar SiLU
uses range reduction, an exponential polynomial and reciprocal Newton steps.
The host reference emulates native inner rounding and FP32 outer accumulation,
uses exact host sigmoid/SiLU, and checks **every H and Y element** with a
precision-specific absolute tolerance recorded in `validation.json`.
This is not FP32 widening FMA for every FP16 product, nor a bit-exact FP32 oracle.

Completed FMAC work is counted per padded microkernel invocation: B*(KT-1)*PT.
Useful roofline work for a complete FFN is 6*B*hidden*intermediate; it excludes
activation arithmetic. Workload utilization divides this by the **physical
mesh** GEMM peak and complete benchmark duration. Vector busy-lane utilization
is a separate modeled estimate and excludes scalar activation work.

GVSoC tools live in `TeraNoC_gvsoc/gvsoc/scripts/qwen_stream/`. They collect CSR
boundaries/settings, vector work, MSHR entry states, atomic/barrier events,
software tile timestamps and complete L1 dumps. The Qwen-specific offline
renderer shows compound-operator scheduling; it leaves the shared GEMM dashboard
generator unchanged. Missing bank/link/endpoint/channel counters are labeled
unavailable. Raw JSONL keeps 1000-cycle windows; only long browser views are
coarsened, by summing deltas and retaining actual window lengths.

Campaigns, raw traces, private model builds and dashboards belong outside this
source tree. See `TeraNoC_gvsoc/gvsoc/docs/reports/qwen_stream_20260916.md` for
accepted results, exact artifact paths and model limitations.

Use `build.py --layout-only` with the intended dimensions for a quick compiler
and linker L1-fit check. It skips weight/reference generation and creates
`layout.elf` with placeholder L2 operands, explicitly marked in the manifest.
This file cannot establish L2 fit, numerical correctness, or performance; the
GVSoC runner rejects layout-only inputs. A normal build remains required before
simulation. `--source-revision` records the original RTL commit when the builder
is executed from a frozen source copy outside Git.

## MSHR policy

Keep the configured MSHR coalescing/cache behavior enabled in the streaming
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

The active native-FP16 `gate_up_ladder` builder pins the standalone GEMM timer
policy to `hold_window_single=8191`, `hold_window_burst=8191`,
`serve_timeout=8191`, and `cache_timeout=0`. The last value is the RTL legacy
mode that lets a cached entry re-arm from the serve timeout; it is intentional,
not a missing configuration. Matmul/merge arms additionally use the production
sharing targets and the address-ranked hash settings recorded in each manifest.
The older `qwen_gateup_ladder_20260917` binaries retain their historical
64-cycle timer settings and must not be mixed with the current bundle.

For the current source, the generated microkernel is emitted by
`gate_up_ladder/build.py:kernel()` into an arm's `microkernel.h`; `q_block` is
the generated inner FP16 block called by `q_compute`, not a separately
maintained source file. The ladder README and GVSoC handover identify the
persistent exact-ELF bundle and its checksums.

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
