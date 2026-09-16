# GEMM startup before measurement

The FP32 `sp-fmatmul-opt-burst-merge` and FP16
`sp-fmatmul-opt-burst-merge-fp16` applications use the same startup policy.
The measured matrix multiplication, input data, replication layout, I-cache
warm-up, and MSHR hold/cache policy are unchanged.

## Hash selection at build time

The standard Spatz applications Makefile runs
`software/scripts/precompute_gemm_hash.py` after linking these two applications
and before writing their disassembly. Python uses only its standard library;
a native C compiler (`HOST_CC`, default `cc`) is required.

The ELF contains a versioned descriptor with the actual build's dimensions,
precision, group/core count, active-group divisor, KS, split, VLEN, burst
geometry, sample count, MSHR bank count, seed selectors, and replication layout.
The helper reads the final `a`/`a_mesh` and `b` symbol addresses and compiles
`gemm_hash.h` on the host with those exact settings. This is the same C selector
used by runtime tuning, including candidate ranking and tie-breaks. It runs once
per group; inactive groups retain their seeds just as runtime tuning does.
Only the reserved selector table is patched, with no relink or address changes.
All non-hash configuration fields still come from `MSHR_CFG_DERIVED_INIT`.

The table has a ready marker. The default application rejects an unpatched ELF
with return value -11 before entering synchronization. A custom ELF build flow
must invoke the helper after its final link and before hashing, copying, or
publishing the ELF:

```sh
python3 software/scripts/precompute_gemm_hash.py /absolute/path/workload.elf
```

For a frozen source build, pass `--runtime /absolute/path/snapshot/runtime` so
the host uses the same headers as the target. Never patch an ELF already in use
by a simulation. The helper writes `workload.elf.hash.json` with the exact
per-group selectors and inputs, available even if the simulation later hangs.

`-DMSHR_HASH_PRECOMPUTE=0` retains runtime search for comparison and custom flows.
`MSHR_HASH_SEARCH=0`, non-search hash modes, and disabled runtime configuration
retain their existing behavior. This change preserves the **current** selector;
older campaign snapshots may have different tie-break policies and must be
compared using their own frozen headers.

## Diagnostics without delaying startup with long messages

Default startup prints short `[INIT] copy`, `prepare`, `warmup`, and `benchmark`
markers. These identify phase entry, not phase completion; `warmup` is omitted
when warm-up is disabled. The benchmark marker precedes cold-start alignment
and the measurement marker. Configuration error messages remain immediate.

Detailed `DASHBOARD_META`, `GEMM_CONFIG`, `AREP`, and `GEMM_HASH` records are printed
once after measurement. The dashboard parser reads the whole transcript and
accepts metadata there. For a stalled run, use the short markers and the ELF's
`.hash.json` report; for original detailed startup logging, build with
`-DMATMUL_BOOT_VERBOSE=1`. `-DMATMUL_BOOT_PROGRESS=0` disables short markers for
controlled timing experiments. The generic `finish copy` and range print are
retained only in verbose mode.

## Synchronization and warm-up

Removed the barrier after core-local work distribution and the barrier after
core-local hash preparation. Pair-barrier and group-barrier configuration now
share one publication barrier before warm-up. DMA publication, replica
publication, warm-up completion, CSR configuration, cold-start alignment, and
benchmark completion barriers remain.

Input transfers, A replication, and the existing reduced-N warm-up are retained.
Shortening the warm-up's M/P ranges needs a separate analysis of instruction
coverage and group-barrier participation; preloading L1 would be a separate
simulation mode. The MSHR stays disabled through warm-up. This is I-cache
warm-up, not a warm MSHR response-cache experiment.

The existing timing definitions are unchanged: the printed timer includes
cold-start alignment; the benchmark instrumentation starts after alignment.

## Validation

- `python3 software/tests/gemm_config/test_config.py`: 40 configurations,
  independent partition/scoring checks, exhaustive legal hash choices, and
  invalid-configuration rejection.
- Isolated ELF builds for both precisions and both mesh sizes, plus replicated-A,
  prefill, and runtime-search/verbose variants. Shared `software/bin` and published
  campaign ELFs are untouched.
- `python3 software/tests/gemm_config/test_precomputed.py <ELF> ...` checks every
  group against the current C selector, byte-exact patch boundaries, and
  idempotence. Optional `--campaign sim_dashboard/campaigns/gemm_rtl_gvsoc_sweep_v1`
  checks matching CAL2-B/C dimensions against recorded RTL hash settings using
  the campaign's frozen selector.

No RTL timing run has been performed for this change; cycle savings and
post-change hardware execution remain to be measured. Moving work out of startup
and changing barrier spacing can change initial arrival timing even though the
configuration values and workload remain identical.
