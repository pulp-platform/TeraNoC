# GEMM software configuration checks

Run `python3 software/tests/gemm_config/test_config.py` from the repository.
The test compiles the actual C headers with stubbed CSR access dependencies.
It checks 36 FP16/FP32, 4x4/8x8, reduced-active-group and explicit-KS cases:
exact output coverage, balanced legal KS selection, runtime/constant CSR
agreement, and every legal hash candidate against an independent Python model.
Four invalid configurations must fail preprocessing. This does not execute RTL.

The two burst-merge apps share `software/runtime/gemm_config.h`. Default KS
minimizes the difference between within-group A and B sharer counts among
legal KS=1,2,4,8. Ties prefer burst-capable B loads, then larger KS. KS always
means rows per microkernel; the selected work partition determines sharing.
An explicit `EXTRA_DEFINES=-DKERNEL_SIZE=...` remains authoritative if legal.

For the campaign shapes, with 16 cores/group:

| Mesh | M x N x P | KS | A/B sharers |
|---|---|---|---|
| 4x4 | 16 x 128 x 4096 | 4 | 4/4 |
| 8x8 | 16 x 128 x 4096 | 4 | 4/4 |
| 4x4 | 512 x 128 x 512 | 8 | 4/4 |
| 8x8 | 512 x 128 x 512 | 2 | 4/4 |

`mshr_cfg.h` derives merge targets and legal seed hashes from this partition.
Targets remain bounded by hardware capacity; the existing scalar bypass
policy at A sharing <=2 is preserved. Before instruction-cache warm-up, each
active group's CSR writer searches mode-3 hashes using actual operand bases
(including A replication), hardware bank count, and up to 16 evenly spaced
reduction steps. Single and burst selectors maximize the sum of occupied
banks in their respective classes, keeping the seed on ties. Other hash
modes retain their seed settings. Timeouts/cache policies remain config-fed.

This bounded model covers the first row/column microtile, not an entire
execution trace. It treats accesses within a sampled step as concurrent and
does not predict arrival skew, response lifetime, NoC contention, or runtime.
A balanced KS and best modeled bank spread are not proof of fastest execution.
Use `-DMSHR_HASH_SEARCH=0` for a seed-only comparison and
`-DMSHR_HASH_SAMPLE_STEPS=...` (1..128) to vary sampling. Compare validated
RTL benchmark cycles before making a performance claim.

New `[DASHBOARD_META]` / `[GEMM_CONFIG]` lines report selected KS and sharing;
`[GEMM_HASH]` reports group 0's programmed selectors. The dashboard RTL probe
captures every group's actual CSR values. Search and printing are outside
the timed benchmark. No shared `software/bin` ELF is needed for validation.

The request model is `gemm_burst.h`, matching the current tile-contained VLSU.
Run `python3 software/tests/gemm_config/test_burst.py` for C/Python request-stream
parity, including short bursts, one-word tails, alignment, tile crossings and
capacity fallback. The configuration test also checks B bases at bank 8 and
bank 1. See [burst-model metadata and scope](../../../docs/tile_contained_burst_hash.md).
