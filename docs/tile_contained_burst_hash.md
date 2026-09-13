# GEMM hash tuning for tile-contained bursts

The burst-merge FP16 and FP32 applications use `gemm_burst.h` to enumerate
requests for `gemm_hash.h`. The dashboard uses the matching Python adapter in
`sim_dashboard/trace_dashboard/burst.py`; the standalone hash explorer calls
the dashboard analysis. The host parity check compares both implementations.
No RTL or hash CSR encoding is changed by this software update.

For an unmasked, unit-stride GEMM vector load with vstart=0:

- The start and byte count must be word aligned, with at least two words.
- Total bytes must fit the VLSU's combined ROB capacity.
- A contained load may end on any lane. A crossing load takes the burst path
  only when internal splits preserve complete ROB rows. Otherwise the whole
  load uses scalar word requests, matching the current VLSU fallback.
- Each emitted burst is limited by the remaining words, tile space and
  maximum burst length. One-word tails use the scalar hash.

For 16 banks, four lanes and max burst 16, a 32-byte load starting at bank 8
is one eight-word burst. A 64-byte load starting at bank 4 becomes bursts of
12 and four words. At bank 1 the same 64-byte load takes the scalar fallback.
A 36-byte load at bank 8 emits an eight-word burst and one scalar request.

The tuner scores scalar A and scalar B requests together, and burst B requests
separately. Identical subscribers do not multiply the occupied-bank score.
It samples the first row/column microtile at up to 16 evenly spaced reduction
steps, searches legal shifts 4..10 and burst-selector values 0..1, and keeps
the seed on score ties. Its early-exit ceiling is sampled steps times banks,
which remains safe for short bursts and mixed classes. Sparse patterns can
therefore require more startup search than before. Search occurs outside the
benchmark zone. This is best sampled bank spread, not optimal execution time.

`mshr_cfg.h` still provides legal shape-derived seed values and existing
hold/cache policies. `gemm_config.h` ranks legal KS values by sharing balance,
then potential two-word-or-longer burst eligibility, then larger KS. This
static tie-breaker cannot know allocation addresses or guarantee burst use.
The runtime request model handles the actual bases and hardware limits.

The field-select hash still uses `clog2(MaxBurstWords)` for the burst-selector
bit; word alignment does not move that selector to bit zero. For the current
16-word maximum, start banks 0 and 8 can have distinct merge keys but identical
MSHR bank indices under all legal shifts. Software must expose this limitation,
not recommend an unsupported CSR setting.

## Run metadata and historical traces

Future applications print a `[DASHBOARD_META]` JSON line containing:

```json
{
  "kernel_size": 4,
  "burst_model": "tile-contained-v1",
  "burst_geometry": {
    "tile_words": 16,
    "max_words": 16,
    "lanes": 4,
    "rob_depth": 32,
    "enabled": 1
  }
}
```

`runtime.mk` propagates `spatz_vlsu_burst` and `spatz_vlsu_rob_depth` to the
software model. Tile banks derive from cores/tile, N_FU and banking factor;
lanes derive from N_FU. The maximum defaults to the integration's 16 words.
Nonstandard hardware overrides must be reflected in the `GEMM_BURST_*`
software defines. These prints describe the software's intended hardware
contract: the ELF must still be paired with matching RTL/configuration.

For older traces, supply these fields in a manifest using the captured build
geometry. `aligned-v1` describes the preceding 64-byte-start-aligned VLSU with
short-burst support (for a 16-word maximum). It does not mean a 16-word minimum.
Unversioned runs keep measured charts but report modeled hash analysis as
unavailable until the burst model is specified. Never infer it from mesh size,
load length or the generation date. The profile covers GEMM word-granular loads;
it is not a general simulator for strided/indexed/masked instructions.

Both `generate.py` and `upgrade_full.py` use the versioned model for hash analysis
and diagnosis. The upgrader still preserves compressed detail blocks byte for
byte. Regenerating HTML does not change recorded counters or historical ELFs.

The standalone explorer uses the same analysis:

```sh
python3 scripts/mshr_bank_hash_explore.py --M 16 --N 128 --P 4096 \
  --ks 4 --cores 1024 --groups 64 --burst-model tile-contained-v1 \
  --tile-words 16 --lanes 4 --rob-depth 32 --max-burst 16 --current 6 4 0
```

The old `--min-burst 16` assumption is no longer accepted. Two words is the
protocol's minimum burst length; actual eligibility requires the rules above.

## Host validation

```sh
python3 software/tests/gemm_config/test_burst.py
python3 software/tests/gemm_config/test_config.py
```

These compile C helpers for the host and compare their output with Python;
they do not build simulation ELFs or run RTL/synthesis tools. The first check
covers 118,560 request streams across 1/8/16/32-bank tiles, byte offsets,
lengths, short tails and ROB capacity limits. The second covers 36 shape,
precision, partition and KS configurations, compares every legal candidate,
and verifies that the selected candidate attains the maximum sampled score.
