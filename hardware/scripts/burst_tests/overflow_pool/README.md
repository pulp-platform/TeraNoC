# Overflow-pool directed regressions

`run.py` compiles the real `mempool_group_mshr` and its helper modules in a
**new private VCS library**. It does not reuse full-chip libraries, build
software, preload an ELF, modify a running simulation, or submit fleet work.
The runner refuses an existing build directory and checks the runtime licence
pool before each run, reserving 20 seats for others.

From the repository root:

```bash
python3 hardware/scripts/burst_tests/overflow_pool/run.py \
  --compile-script hardware/build_pool_review_20260916_194314/full_on/compilevcs.sh \
  --build-dir hardware/build_overflow_directed_01
```

The generated compile script supplies package order, include paths, and the
configuration. The runner overrides runtime configuration on, hold-counter
prescaling off, legacy bank hash, and noisy diagnostic knobs off. All other
defines remain those in the supplied script. The DUT is reduced to four tiles,
two usable request/response ports per tile, eight banked entries, two ways per
bank, and four subscribers per entry. All spill registers are bypassed so the
test can apply backpressure directly at the DUT's acceptance boundary. The
shipping script enables both two-beat draining and response caching.

`sources.json` records the source hashes, frozen compile paths and define
overrides. The project headers `mempool.svh` and
`mempool_group_mshr_stats.svh` are copied into a private include directory that
precedes the live include paths; dependency headers remain in their original
include directories. `compile.log` records exact commands and compiler output. Each case
has its own directory containing `run.log` and `waves.vcd`. No RTL assertions
are disabled. Use `--rtl-file /absolute/path/to/frozen/mempool_group_mshr.sv`
for a baseline or another isolated variant.

The default `overflow_pool_tb` creates actual bank-local pressure through the
request interface: two held bursts fill bank zero while six banked entries
remain free. It does not seed or force internal state. Cases are:

| Case | Check |
| --- | --- |
| `alloc_stall` | With a zero hold window and blocked egress, the pool does not allocate an unaccepted scalar request; reopening egress produces exactly one fetch and response. |
| `owner_parallel` | Two bursts with disjoint per-lane IDs but overlapping legacy metadata windows allocate consecutively into a bank and the pool. |
| `replay_scalar` | A scalar cohort survives an eight-cycle gap, merges, waits for egress readiness and delivers one fetched word to each subscriber. |
| `replay_burst` | The same sequence for an eight-beat burst, with response input/output backpressure and checks for every subscriber's data, beat ID and duplicate delivery. |
| `two_entries` | At `--pool-num 2`, two distinct requests occupy both pool entries, wait for egress, issue tags `MshrNum+1` and `MshrNum+2`, and return distinct payloads to their respective owners. |

Choose cases with `--cases alloc_stall replay_burst`. `--pool-num 0 --cases
pool_off` checks that an ordinary bank-full request remains blocked with the
pool disabled even when egress is ready. `--pool-num 2` exercises the same
handshake cases with a wider pool; add `--cases two_entries` to exercise its
second entry as well. The reviewed configuration set is pool counts 0, 1 and 2.

`--top pool_response_tb` selects the companion response-path tests. These seed
small entry snapshots away from clock edges to isolate rare state transitions,
then exercise real combinational and sequential DUT logic. Select its cases
explicitly:

```bash
python3 hardware/scripts/burst_tests/overflow_pool/run.py \
  --compile-script hardware/build_pool_review_20260916_194314/full_on/compilevcs.sh \
  --build-dir hardware/build_overflow_response_01 \
  --top pool_response_tb \
  --cases capture_lane capture_burst cross_clear clear_generations cache_expiry_merge
```

For the store-coherence paths, use another new build directory and add
`--define GROUP_MSHR_CACHE_STORE_UPDATE=1 --define GROUP_MSHR_STORE_FORCE_DRAIN=1`.
The additional cases are `store_cache_update`, `store_cache_blocked`,
`store_amo_guard`, `store_force_drain`, `store_force_blocked`,
`store_cache_merge`, and `store_capture_force`. They check accepted stores,
blocked stores, an unrelated AMO in the same cycle, and a store concurrent with
a merge or response capture.

With `--define GROUP_MSHR_CACHE_AMO_INVAL=1`, cases `amo_pool_cached` and
`amo_pool_held` check the pool's AMO paths. `amo_cache_merge` checks
invalidation during application of an accepted cached merge. `amo_hold_merge`
and `store_hold_merge` exercise a merge crossing the held-response threshold.
`amo_drain`, `store_drain`, and `amo_capture` check that a blocked or newly
captured old response drains exactly once and cannot be re-cached after the
coherence pulse. The corresponding `bank_amo_drain`, `bank_store_drain`, and
`bank_amo_capture` cases exercise the banked twins. The `stats_merge` case needs
`--define GROUP_MSHR_ENABLE_STATS=1 --define TB_CHECK_STATS=1` and checks that a
pool merge is counted as a merge rather than a bypass.

The response suite also provides deliberate negative tests:
`guard_cached_store`, `guard_held_store`, and `guard_cached_amo`. Run these with
the corresponding coherence knob disabled and check for their specific DUT
assertion failure. The runner returns failure for these cases; they are not
part of the positive regression.

Each external request/fetch/response handshake is printed with its cycle as a
`TRACE` line. Comparing those lines and the final `PASS` line between fixed RTL
and a PPA restructuring checks timing of the observed transactions as well as
their data and counts. Additional compile knobs can be overridden with repeated
`--define NAME=VALUE` arguments, which are recorded in `sources.json`.

The harness establishes local correctness. It does not measure backend timing,
full-chip application performance, or prove that every workload's hold-window
dependency is removed.
