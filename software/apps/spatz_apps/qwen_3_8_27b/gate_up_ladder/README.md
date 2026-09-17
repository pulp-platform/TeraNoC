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
slot is reused; a 128-cycle guard bounds stale cache lifetime with a 64-cycle
serve timeout and cache_timeout=0 (inherit). Model coherence conveniences are
disabled in the experiment runner. Production merge targets are enabled only
for the matmul/merge variant. Bypass controls use targets one.

A private manifest records data/ELF/source hashes, actual addresses, production
KS/partition, effective expected CSRs, hash choices, L1 headroom, L2 budget,
programmed DMA bytes, padded work and barrier counts. The matching GVSoC tools
and operating procedure are in gvsoc/scripts/qwen_ladder/README.md.
