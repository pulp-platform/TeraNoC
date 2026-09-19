# MSHR metadata-overlap guard removal

## Correctness argument

The original guard (introduced in `596f3f16`) prevented resident owner metadata
ranges from overlapping while response lookup scanned entries by those ranges.
Commit `30cfcb34` introduced explicit round-tripped MSHR tags but retained the
guard. Current banked and pool response classifiers select an entry by tag;
metadata validates and locates a beat only within that selected entry. Tag zero
bypasses both tables, and the banked and pool tag ranges are disjoint.

The requester reserves response IDs before issuing a load and may reuse them
after consuming the corresponding responses. An older MSHR entry can still be
serving another subscriber. Keeping that entry's original owner metadata does
not extend the requester's ID reservation. The removed check also used word
counts rather than per-lane row counts, so it stalled disjoint live ID ranges.

Tag lifetime remains protected: pending allocations reserve their entry, and
active entries retire only after their responses have drained. Same-address
lookup, drain hazards, forwarding into pending allocations, merge capacity,
and pending allocation/merge records remain intact.

The removal includes banked and pool overlap checks, their pending-allocation
extensions, admission/replay/store gating, the obsolete configuration switch,
and the owner-stall counter. Requester metadata itself remains necessary for
response validation and subscriber response construction.

## Validation

No software rebuild, full-system simulation, backend PPA run, or fleet job was
needed. Fresh private unit builds use the real RTL. VCS builds freeze sources
and project headers and record commands/hashes in `sources.json` and
`compile.log`; each case retains `run.log` and `waves.vcd`.

From the repository root, the common invocation is:

```sh
python3 hardware/scripts/burst_tests/overflow_pool/run.py \
  --compile-script hardware/build_pB1/compilevcs.sh \
  --build-dir hardware/<directory> <options>
```

| Directory | Options | Result |
| --- | --- | --- |
| `build_meta_guard_pool1_20260920_r1` | `--cases alloc_stall owner_parallel replay_scalar replay_burst` | 4 pass |
| `build_meta_guard_pool0_20260920` | `--pool-num 0 --cases pool_off` | 1 pass |
| `build_meta_guard_pool2_20260920` | `--pool-num 2 --cases owner_parallel two_entries` | 2 pass |
| `build_meta_guard_store_20260920` | `--top pool_response_tb --define GROUP_MSHR_CACHE_STORE_UPDATE=1 --define GROUP_MSHR_STORE_FORCE_DRAIN=1 --define GROUP_MSHR_CACHE_AMO_INVAL=1 --cases store_cache_update store_cache_blocked store_force_drain store_force_blocked store_cache_merge store_capture_force bank_store_drain` | 7 pass |
| `build_meta_guard_stats_20260920` | `--top pool_response_tb --define GROUP_MSHR_ENABLE_STATS=1 --define TB_CHECK_STATS=1 --cases stats_merge capture_lane capture_burst cross_clear clear_generations cache_expiry_merge` | 6 pass |

The same runner with `--cases owner_parallel` and the saved pre-change RTL
(`--rtl-file /tmp/mshr-meta-review/mempool_group_mshr.before.sv`) fails as expected
with `legal same-owner request stalled behind pending allocation`, in
`hardware/build_meta_guard_baseline_20260920`. The two bursts use disjoint
per-lane IDs; this is a negative control for the removed admission restriction.

The additional standalone test runs without a generated full-system script:

```sh
python3 hardware/scripts/run_mshr_meta_reuse.py \
  --build-dir hardware/build_meta_reuse_review_20260920_r1 \
  --rtl-file /tmp/mshr-meta-review/mempool_group_mshr.staged.sv
```

The RTL file above is exported from the Git index using
`git show :hardware/src/mempool_group_mshr.sv`. This final run checks the staged
removal without including the pre-existing, unstaged clock-gate assertion edits.
It passes 113 exactly-once response checks covering tagged bank/pool/bypass
routing, out-of-order beats, backpressure, and legal ID reuse while an old entry
still serves a subscriber. The runner freezes all sources/includes and records
commands, hashes, logs, and `vsim.wlf`. Running the same test against the saved
pre-change RTL stalls on the second legal request, as expected.

Validation uses `BankPublish=1`. An exploratory `BankPublish=0` run exposed an
existing uninitialized bank-selection path: `bank_first` and `bank_win` are
assigned only in the enabled branch but consumed in the common winner block.
The same defect is present in the saved baseline and was not changed here.
That configuration is not validated by this review. These unit tests establish
local behavior, not full-system performance or an exhaustive correctness proof.
