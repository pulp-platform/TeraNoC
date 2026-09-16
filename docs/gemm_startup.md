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
During target compilation, `runtime.mk` invokes `gemm_hash_fingerprint.py` to
embed the selector ABI, SHA-256 of `gemm_hash.h`, `gemm_config.h`, and
`gemm_burst.h`, and the build runtime path in the ELF. These headers are object
prerequisites. The wrapper also rejects changes to them during compilation.
The post-link helper verifies the fingerprint before writing anything; the
native selector compiles a private snapshot of exactly the verified headers.
A mismatch fails with the expected build runtime and the supplied runtime path.
Legacy descriptors lacking a fingerprint are also refused by default.

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
the host uses the same headers as the target. Custom compile flows must also
use the `gemm_hash_fingerprint.py --runtime <runtime> -- <compiler> <args>`
wrapper; fingerprints cannot be supplied for the first time at patch time.
Never patch an ELF already in use
by a simulation. The helper writes `workload.elf.hash.json` with the exact
per-group selectors and inputs, available even if the simulation later hangs.

For deliberate cross-version experiments, the patch helper accepts
`--allow-header-mismatch`. This is not a normal build option. It prints an
explicit override notice and records both fingerprints, the original runtime
path, and the override in `.hash.json`. It does not claim configuration parity.

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

`DASHBOARD_META` and `GEMM_CONFIG` are always printed by core 0 early in main;
`AREP` follows replication, and `GEMM_HASH` follows hash preparation before
warm-up. They are never deferred to the epilogue or suppressed by either boot
logging switch. A run stalled in the measured kernel therefore already has its
interpretation metadata in the transcript. A run stalled earlier can only
contain the records reached so far; the INIT markers identify that phase.

`-DMATMUL_BOOT_VERBOSE=1` additionally prints `finish copy` and work ranges.
`-DMATMUL_BOOT_PROGRESS=0` suppresses only the short INIT markers. The ELF's
`.hash.json` report provides all per-group selectors independently of progress.

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
  idempotence. It also checks rejection of each changed header and a changed
  selector ABI without modifying the ELF, and checks the explicit override audit.
  Optional `--campaign sim_dashboard/campaigns/gemm_rtl_gvsoc_sweep_v1`
  checks matching CAL2-B/C dimensions against recorded RTL hash settings using
  the campaign's frozen selector.

No RTL timing run has been performed for this change; cycle savings and
post-change hardware execution remain to be measured. Moving work out of startup
and changing barrier spacing can change initial arrival timing even though the
configuration values and workload remain identical.

The startup-metadata/fingerprint follow-up preserves the timed-loop source
exactly and adds no barriers. It restores only core-0 metadata printing to the
pre-measurement path. Identical simulated cycle counts are not asserted without
an RTL comparison: startup changes may affect arrival timing and instruction
placement even when the timed code is unchanged.
