# Overflow-pool RTL review — 2026-09-16

The overflow pool remains an independent escape for a full hashed bank. It keeps the ordinary entry's merge, hold, response and cache semantics. This review fixes acceptance and lifecycle bugs and restructures selection and stage-enable logic. The original-ELF comparison demonstrates a 9.63× benchmark speedup; post-placement timing improvement remains unmeasured.

## Source and scope

Review artifacts: `hardware/build_pool_review_20260916_194314/` (abbreviated `R/` below). `R/baseline/` preserves the source at review start, including the previous agent's pool-response bypass-forward guard and idle next-state defaults. Those earlier fixes are retained.

The current review candidate is `R/final_v6_source.sv`, SHA256 `c6e9eed8a8ac15534472fd91fc491dd2acd90268198b4fd5befb0e9d58745f2a`. The full-chip and currently running backend comparisons use the earlier frozen `R/final_v2_source.sv` (`ef42ca93196a2c99d6307ac1ab7e568b9b45d8b9b3094c63ccfdf148391cc485`); final-v6 adds a cycle-neutral merge-enable reduction and optional coherence repairs. The final statistics header is `R/final_stats.svh`, SHA256 `b920a394976c7fa71b3ed3c61934db18d4f6f7efec84df78a1ff8841ada6e7ee`. An earlier final snapshot had an undefined identifier in a new simulation assertion; the compiler caught it and it was corrected before these validation runs.

No vendored RTL, configuration, shared ELF, or existing simulator image was changed by this review. The requested Claude RTL-PPA skill was copied exactly to `/home/zexifu/.codex/skills/rtl-ppa/SKILL.md` and validated; its previous Codex copy is preserved in `R/`.

## Correctness findings and fixes

| Finding | Consequence | Repair and evidence |
| --- | --- | --- |
| Pool allocation staging ignored final request acceptance | An allocation could be recorded while egress was blocked or an owner was still in the banked allocation pipeline | Reuse the shared allocation-acceptance vector. Original source fails `alloc_stall` and `owner_inflight`; fixed source passes. |
| Pool replay marked the request issued without an egress handshake | Backpressure could lose the only downstream fetch and leave subscribers waiting forever | Require replay lane availability and output readiness. Original source fails both scalar and burst replay tests. |
| Pool capture did not derive burst beat offset, and its lane scratch index could be stale | Incorrect capture grant/data selection and repeated or incorrect subscriber response IDs | Derive beat offset from the pool owner and assign each lane index before either table uses it. Original source fails `capture_lane` and `capture_burst`. |
| Pool drain clear masks retained values between cycles | A later generation could lose its subscriber state | Default both pool clear vectors every cycle. Original source fails `clear_generations`. |
| Banked drain clear scattered a pool acknowledgment through the banked selected index | A pool response could clear an unrelated bank-zero entry | Exclude pool selections from banked clear scatter. Original source fails `cross_clear`. |
| Post-capture pool state omitted accepted merge/allocation contributions | A cached merge at the timeout boundary could be accepted and then lost | Preserve the allocation/merge state transition in the post-capture view; restore the RESP_HOLD subscriber threshold. Original source fails `cache_expiry_merge`. |
| Pool response lanes were classified as bypass occupants for drain arbitration | Independent draining could be unnecessarily blocked while the pool captured a response | Exclude both banked and pool captures from bypass lane occupancy. |
| Optional store-update and store-force-drain passes only handled banked entries | With those knobs enabled, the pool could retain stale cached data or leave held data undrained | Add constant-entry pool twins with the same acceptance, AMO and byte-priority semantics. Original source fails the enabled-knob cases; final tests include concurrent store+merge and store+capture. |
| Several counters omitted pool events | Pool merges appeared as bypasses; capture demand could be zero despite captures firing | Include pool request/cache events and capture demand. Keep banked occupancy/capacity denominators explicit. |
| Dashboard pool occupancy accumulation depended on `+dashboard_entries` | Group-only telemetry silently reported zero pool occupancy | Accumulate pool occupancy independently of whether detailed entry records are emitted. Probe output matches with and without entry detail and is nonzero. |

Added causal assertions for accepted allocation/merge, replay handshakes, one-hot capture/grants, known live control state, merge preservation, legal buffer counts and cached data. Added the banked workload assumptions for disabled store/AMO coherence to the pool, plus an elaboration guard for pool tag capacity. Removed temporary POOLDBG/NOALLOC diagnostics.

## Timing-oriented changes

1. Pool allocation and merge payload staging used lane-ordered overwrite loops. The arbiters already supply one-hot winners. The new code uses masked OR reductions and separate scalar valid reductions, allowing parallel selection without an artificial lane-priority chain.
2. Pool capture payloads used a variable entry index while walking response lanes. The new code gathers each entry's payload using constant entry indices and its existing one-hot first/second-lane selections. The existing capture grants still control every buffer write.

3. Pool merge stage validity now reduces the candidate vector directly. The picker returns one winner for every nonempty vector, so this is equivalent to reducing the selected winners while removing round-robin/prefix selection from the register-enable cone. Allocation stage validity retains winning-lane acceptance.

No pipeline stage, arbitration policy or request/response latency was added. The optional store hardware is generated only when enabled and folds out of the shipping disabled-knob configuration. The global pool CAM/owner checks and global grant fanout remain possible endpoint timing risks. They should be evaluated from startpoint-to-endpoint reports before adding a pipeline or more restructuring.

`R/ppa/final_priority_v2_source.sv` retains every final correctness repair and reverses only the one-hot transformations. Applying the recorded forward patch reproduces frozen final-v2 byte-for-byte. This is the proper PPA reference; the original buggy source is not a valid performance baseline.

Fusion Compiler analysis passes at pool counts zero and one. This proves synthesis parsing with the actual flow, not timing closure. Post-placement `initial_opto` WNS/TNS, violating endpoint populations, logic area and buffer counts are still required to accept a measured timing claim. Old unmatched backend numbers and pre-placement summaries must not be used as the before/after result. The old OOC summary's path-depth helper sums net rows across all reported paths; the private flow corrects that label/count and requests a larger endpoint population.

The matched final-v2 placement pair was launched on September 16 at 20:19 CEST. `R/ppa/run_fixed_pair.py` runs `fixed_final_v2_priority_k1` first, then `fixed_final_v2_onehot_k1`, admitting each only with at least 96 GiB available memory and 21 free licenses in each checked FC pool. Both source the same historical floorplan once, with automatic resizing disabled: a 343.995 by 343.92 micrometer core, exported from `ooc_tenfix` in read-only mode. The private DEF fixes the 8988 already-placed pin locations; geometry, rows and tracks are unchanged. `R/ppa/floorplan_export/floorplan_manifest.json` records its provenance and hashes. Live state, commands and PIDs are in `R/ppa/fixed_pair_status.json`, with an append-only event log beside it; each arm contains frozen-input hashes and `fc.log`. Numerical PPA results remain pending. Earlier one-hot K0/K1 elaborations are separate checks and are still running.

## Verification

The reusable harness is `hardware/scripts/burst_tests/overflow_pool/`; its README documents commands, parameters and limitations. Each build uses a new directory, frozen DUT/project headers, compiler-command logs and source hashes. Each directed case keeps a VCD. No DUT assertions are disabled.

- Final handshake/control matrix: **10/10 pass**, pool counts 0/1/2. Tests create real bank-local pressure while other banks remain free, exercise backpressure and idle gaps, and check fetch/response counts and metadata. The two-entry case uses distinct response payloads and both pool tags.
- Final response/store/AMO/statistics suite: **15/15 pass**. Rare response/cache states are seeded away from clock edges, then real DUT capture/merge/drain logic is exercised.
- Disabled-coherence guard tests: **3/3 expected targeted assertion failures**, without reaching the testbench's missing-guard fallback.
- Selector equivalence: **1.2 million vectors** across six lane/pool configurations, including 32/48-lane cases, empty grants and unknown unselected payloads. This is randomized algebraic checking, not a formal proof.
- Every external TRACE and PASS line matches the correctness reference for the K=1/K=2 handshake tests. A final matched priority-reference comparison is also recorded in `R/`.
- Dashboard probe: identical nonzero group pool occupancy with and without `+dashboard_entries`. This checks the probe harness; it does not claim full-chip dashboard integration.

Principal result directories: `R/final_v2_handshake_k{0,1,2}`, `R/test_response_final_v2`, `R/test_response_final_v2_coherence_off`, `R/select_equiv`, and `R/probe`. Original-source negative controls are preserved beside them.

## Integration and remaining limits

The final full-chip pool-ON validation uses a separate 532-file snapshot under `R/full_on`, with the existing `dec_ffnup_b032_fp16_4x4_pc.elf` copied to a private `workload.elf`. Its exact analysis/link commands are in `commands.json`; the simulation command and status are in `sim_command.json` and `status.json` once built. The optimized integration image has no new waveform instrumentation; the focused tests retain waveforms.

The existing `vcsrun_on4` failed at cycle 50071 in Snitch's response-ID assertion. The earlier pool-forward fix is already in this review's baseline. Both frozen integration arms and both original-ELF arms have now finished without a fatal assertion. Existing `vcsrun_on5` and other agents' runs are not the frozen review image.

Pool second-head draining is not implemented: `beat2_armed` is never set for pool entries, so the pool still drains a single head at a time. The dormant pool `fin_second` expression counts capture grants on an already post-capture count and must be revisited before enabling that path. This review does not claim pool PD2 throughput. `DrainMultiPort=0` support has a preexisting unrelated limitation and is outside the reviewed configuration.

The matching frozen RTL/configuration comparison is now complete:

| ELF | Pool OFF benchmark cycles | Pool ON benchmark cycles | Result |
| --- | ---: | ---: | --- |
| Precomputed | 23,556 | 23,482 | Both complete cleanly; little pool benefit in this timing regime. |
| Original | 223,675 | 23,217 | 9.63× speedup; benchmark timeout releases fall from 290 to zero. |

All four runs finish with exit status zero and no fatal assertions. Their 16 printed output spot checks agree; this is not full-matrix numerical verification. The original ELF reproduces the circular-wait/timeout regime on the same final-v2 RTL, showing why the precomputed ELF alone was insufficient evidence. Exact hashes and extracted results are in `R/completed_application_results.json`.

The September 17 audit additionally repairs cached-merge AMO invalidation: retain the accepted subscriber but clear cacheable so draining cannot re-cache the pre-AMO word. It also recognizes a registered RESP_HOLD entry when a staged merge has already changed the post-capture state to DRAIN_RESP, preventing AMO/store coherence from missing the held word. Both banked and pool twins are covered. These optional passes fold out of the shipping disabled-knob configuration. Final-v5 focused regression results are recorded below when complete.

Future dashboard validation must compile the dashboard probe and launch with private `+dashboard_file`, `+dashboard_entries`, `+dashboard_banks`, and `+dashboard_links` options. This requirement is persisted in `AGENTS.md`; existing full-chip transcripts do not contain every detailed panel's data. Final-v5 has focused validation; the full-chip measurements above are explicitly final-v2. Backend signoff is still pending, and the running placement pair does not measure the final-v6 enable reduction.

The frozen final-v6 backend arm is queued by `R/ppa/run_final_v6.py` after the existing matched pair and positive final-v6 validation gate. It reuses the same defines, floorplan and flow; shipping coherence knobs are zero. Its comparison with the preceding one-hot arm isolates the candidate-to-merge-enable reduction. Commands, source hashes, admission checks and status are retained under `R/ppa/fixed_final_v6_onehot_k1` and `R/ppa/final_v6_status.json`. No final-v6 timing result is available yet.

Final-v6 handshake/control validation is **10/10 pass** at pool counts zero, one and two. All external TRACE/PASS lines match final-v2 exactly, including transaction cycles. The source compiled by each private build matches the frozen final-v6 RTL; comparisons are in `R/final_v6_handshake_results.json`. The expanded coherence suite includes already-draining responses and capture concurrent with AMO in both banked and pool entries. No-recache is separate from response release so pending beat ownership remains intact.

Final-v6 expanded response/coherence/statistics validation: **24/24 pass**. The six already-draining/capture negative controls all fail on final-v5 and pass on final-v6, with original response data/metadata delivered exactly once and the old word retired. Cached-merge and held-threshold negative controls are also preserved. `R/final_v6_validation.json` records the final source hash and validation gate. The exact commands and source/define manifests are in each result directory’s `compile.log` and `sources.json`.
