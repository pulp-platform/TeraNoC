# Gate/Up batch ladder

Native FP16 Gate and Up projections, with independent logical input/reference
data shared across meshes and work partitions. Synthetic operands are for
functional/performance experiments, not Qwen accuracy validation.

`data.py` generates X, Gate and Up plus full FP16 and FP32 arithmetic references.
`build.py` builds an isolated ELF and runtime; it never writes software/bin.
`partition.py` compiles the actual production gemm_config.h on the host and
records its KS, split and sharing policy before generating target ownership.

The default mapping is register for B=1 and matmul for B>1; explicit options
retain both variants for measurement. Both mappings use all 256/1024 cores. Register mapping reuses weights over up to
four rows in each core; matmul mapping preserves production full-shape row/column
ownership. Panel buffers make the complete B=1..128 ladder fit L1, including L2
output writeback. Each projection computes B × 5120 × 17408 in the full campaign.

The microkernel keeps FP16 accumulation across K tiles, with K FMACs/output.
Both W and replicated X use DMA ping-pong buffers. All readers join before a
slot is reused; a 128-cycle guard bounds stale cache lifetime. New ELFs use the
tuned standalone FP16 GEMM MSHR policy: 8191-cycle single/burst hold windows,
8191-cycle serve timeout, and cache_timeout=0 (legacy mode, which re-arms from
the serve timeout). Model coherence conveniences are
disabled in the experiment runner. Production merge targets are enabled only
for the matmul/merge variant. Bypass controls use targets one.

A private manifest records data/ELF/source hashes, actual addresses, production
KS/partition, effective expected CSRs, hash choices, L1 headroom, L2 budget,
programmed DMA bytes, padded work and barrier counts. The matching GVSoC tools
and operating procedure are in gvsoc/scripts/qwen_ladder/README.md.

## Mesh-aware tiling

The default now prefers a full-width output panel. It targets KT=40 on 4x4
and KT=160 on 8x8, then reduces KT or panel width when the complete L1/L2
budget requires it. `--kt` and `--pt` explicitly request dimensions and fail
if they do not fit. The L1 estimate reserves runtime/stack/alignment space;
the linked allocation is checked independently. This is a capacity policy,
not a claim that the selected tile is performance-optimal.

For B1, K=5120, P=17408, both meshes use PT=17408 and one panel. The two weight
buffers occupy 2.65625 MiB on 4x4 or 10.625 MiB on 8x8. Each step submits one
contiguous weight DMA and one contiguous DMA of the group-replicated input.
The full-width weight panel preserves ordinary row-major weight order. Smaller
panels are still packed offline by owner. Packing is outside benchmark timing.

Each core keeps its production column ownership (68 columns on 4x4, 17 on
8x8 for B1). Vector loads stop at the 64-byte tile bank stripe. Odd starts or
last FP16 elements use an explicit one-element vector; other requests are
word granular, so multiword loads satisfy the current contained-burst rules.
No output-padding FMACs execute. A final short K tile is padded in storage but
the kernel computes only its real reduction elements, preserving FP16 order.

The manifest records ceiling-divided step counts, exact expected work from
the assignments, programmed DMA bytes (including stored K padding), and the
actual scalar/burst address samples used by hash selection and dashboards.
Output panels remain single-buffered. Joins, cache guard and CSR policy are
unchanged. `python3 test_tiling.py` checks both mesh budgets, exact column
coverage, reduction tails and the production `gemm_burst.h` eligibility rule.

The original KT32/PT8192 campaign's frozen ELFs and source bundles are unchanged.

## Current persistent B2/B4 ELFs

The current tuned bundle is kept outside the source tree at
`/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC_gvsoc/sim_dashboard/campaigns/qwen_gateup_ladder_20260918_mshr8191/`.
All four arms are exact native-FP16 `B × 5120 × 17408` Gate/Up matmul/merge
builds with `KS=1`, `PT=17408`, one panel, the tuned
`8191/8191/8191/0` MSHR timer policy, and the production `8/2` subscriber
targets with `cache_reuse_target=16`. They are hash-checked in `SHA256SUMS`.
They are built artifacts; no full-size GVSoC simulation has been accepted yet.

| Arm | Mesh | Batch | KT | Column blocks | Active cores | `workload.elf` SHA-256 |
|---|---:|---:|---:|---:|---:|---|
| `b2_4x4_matmul_merge` | 4×4 | 2 | 40 | 128 | 256 | `55c9c8c5ab2e11cde3a0c5e50882d7059bff575c56503610c24a3b5dbbe8b381` |
| `b4_4x4_matmul_merge` | 4×4 | 4 | 40 | 64 | 256 | `10d3acc9f7131220f074a4e9fb4a2166602e099364351d551a15ede72db90563` |
| `b2_8x8_matmul_merge` | 8×8 | 2 | 160 | 512 | 1024 | `201cf53dad45a819ac81ebee1ba4756fc92cdf6252dacddc83bb2dfd38a0ea78` |
| `b4_8x8_matmul_merge` | 8×8 | 4 | 160 | 256 | 1024 | `1cbf42383ee0dabb4e2fc7d368aba123eda1230f620a3eac0476135b04c4fd9f` |

Use each arm's `manifest.json`, `csr_config.h`, `qwen_config.h` and
`build.log` as the configuration record. The 512 MiB modeled L2 capacity is
explicit in the build; it is not an external-memory model. Run the exact
`workload.elf` in a new GVSoC output directory and retain the resulting
validation and dashboard beside the arm.
