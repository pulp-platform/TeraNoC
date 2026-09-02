# PLAN: 8x8 fixed runs (KS=1 pilot)   [durable — update after EVERY step]
Started 2026-09-02. Approved by user: "yes, do it".

Goal: rebuild the 8x8 VCS image on CURRENT RTL (it predates the Sep-1 hash fix) + rebuild the
16 8x8 KS=1 ELFs on current software (LOAD_LMUL derivation + mshr_cfg fix), then launch those
16 as a pilot. Hold KS=2/4/8 (36 more arms) until the 4x4 set drains.

## Invariants that must hold
- hardware/generated/*.sv is SHARED and mesh-specific; floo_terapool_noc_pkg.sv is UNTRACKED.
  It MUST end at 4x4 (NumMeshX=4, GroupX1Y0=4). Restore under a trap.
- Software must be built with CONFIG=terapool_spatz4_fpu_8x8 (script defaults to 4x4 flavour).
- Leave >= 20 VCS seats for others. Cap with licence only: --max-parallel 200.
- Never blanket git-restore; name files.

## Steps
- [x] 1. Back up hardware/generated/*.sv (all 3) to /tmp/claude-620771/gen_4x4_backup/
- [x] 2. Regenerate generated/ for 8x8 (TWO floogen passes; conda env on PATH);
         assert NumMeshX=8 AND GroupX1Y0=8
- [x] 3. Build image build_tgt8x8_hashfix (config=terapool_spatz4_fpu_8x8, snitch_trace=0,
         -o update-floogen so the build cannot re-run floogen)
- [x] 4. Restore generated/ to 4x4; assert NumMeshX=4 AND GroupX1Y0=4   <-- TRAP-PROTECTED
- [x] 5. Rebuild ALL 52 8x8 KS=1 ELFs, prefix r8_, CONFIG=terapool_spatz4_fpu_8x8
- [x] 6. Define-diff build_tgt8x8_hashfix vs build_tgt4x4_hashfix -> geometry-only or STOP
- [~] 7. Submit ALL 52 arms, run-prefix r8, --reserve-licenses 20 --max-parallel 200
- [ ] 8. Verify arms pass cyc=16000 into bench; update WORKLOG + commit

## Notes / state
(append as we go)

- 00:38 step1 OK: 3 files backed up to /tmp/claude-620771/gen_4x4_backup + MD5SUMS
- 00:40 step2 OK: two floogen passes, asserted NumMeshX=8 AND GroupX1Y0=8
- 00:40 step3 RUNNING: pid via /tmp/claude-620771/build_8x8_hashfix.sh (trap restores 4x4 on ANY exit)
  driver log /tmp/claude-620771/build8x8_driver.log ; build log /tmp/claude-620771/build8x8.log
  monitor bguve61pf watches for BUILD-OK/BUILD-FAILED/RESTORED-OK

- 00:45 step5 RUNNING (parallel with the image build; software does not touch generated/):
  /tmp/claude-620771/build_r8.sh -> 16 ELFs hardware/r8_8x8_fp{16,32}_ks1_*.elf
  MATMUL_REPEAT matched to the existing 8x8 arms: B=1->128 2->64 4->32 8/16->16 32->8 64->4 128->2
  (my first draft had 16 for B=1/2/4 -- WRONG, would have broken the ideal-cycle normalisation)
  FOUND: the OLD build_8x8_ks1.sh header claims "split 2x256 B load" but never passed
  -DSPATZ_1XVL_LOAD_LMUL=4, so every existing 8x8 KS=1 B>=8 ELF has the deadlock defect too.
  The new derivation fixes this automatically.

- 00:52 SCOPE CHANGE (user): send ALL 52 8x8 arms, not just the 16 KS=1. Cap by LICENCE only
  (--reserve-licenses 20 --max-parallel 200); badist queues the overflow and dispatches as
  seats free. 47 seats in use now, so ~33 start immediately and the rest backfill.
- 00:52 shape matrix recovered from the ORIGINAL build logs into /tmp/claude-620771/shapes8x8.txt
  (52 arms, per-shape MATMUL_REPEAT, no extra defines on any of them).
- 00:53 step5b: /tmp/claude-620771/build_r8_rest.sh builds the 36 KS=2/4/8 arms. CHAINED behind
  the KS=1 build (waits on pgrep) -- gen_decode_shape_app.sh writes matmul.json + data_gemm.h
  into the SHARED app dir, so concurrent builds would race and mis-shape an ELF.
- submission list: /tmp/claude-620771/arms_r8_all.txt (52 arms, image build_tgt8x8_hashfix)

- 01:05 ROBN A/B finished (shape 1x128x8192, p_span=64 B so the ROBN edge is NOT exercised --
  the test is void for locating the boundary, as flagged). But A-vs-C isolates LOAD_LMUL and
  the sims are deterministic, so the delta is real, not noise:
      A load8_store4  3637 cyc   (LOAD_LMUL=8, no split)
      B load8_store8  3626 cyc   (STORE_LMUL 8 vs 4: -0.3%, negligible; did not wedge --
                                  the store is only 64 B at this shape)
      C load4_store4  3754 cyc   (LOAD_LMUL=4 where the split is NOT needed: +3.2% vs A)
  => an UNCONDITIONAL LOAD_LMUL=4 default would cost ~3.2% on every shape that does not need
  the split (the runtime skips the 2nd load but the extra vsetvli pair remains). This is the
  measured justification for DERIVING the knob instead of defaulting it to 4.
- 01:05 image build progressed vlogan -> vcs elaboration (vcs -full64 -j16 mempool_tb), 24M

- 01:10 USER: results must be written into the results doc AND the artifact when they land.
  Step 8 now = verify arms past cyc=16000, THEN update docs/benchmarks/decode_gemm_results.md
  and regenerate+republish the artifact (scripts/gen_ks_sweep_artifact.py), for BOTH the 4x4
  rf_ set and the 8x8 r8_ set. Do not wait to be reminded (feedback_republish_without_asking).

## RESOLVED, NOT AN OPEN ITEM (corrected 2026-09-02 02:20)
The "cache_reuse_target=2S assumes a merge degree the single class never reaches" item below is
WITHDRAWN. It rested on free_outcome `single subs2p=0`, which does NOT mean what its name
suggests: the block samples sub_reqs_num at the instant the entry goes invalid
(mshr_q_valid && !mshr_d_valid), and the DRAIN_RESP->CACHED transition ZEROES sub_reqs_num
(mempool_group_mshr.sv:4277) before a line can ever be cached. So every cached line dies with
sub_reqs_num already 0, lands in subs1, and adds 0 to subs_sum. subs2p measures entries that died
holding >=2 UNSERVED subscribers -- a residency measure, not merge degree.
The tell was in the same line: subs_sum=0 next to cachehit_sum=131072. A class that never merged
cannot sum 131k hits.
MEASURED, fp16 ks8 16x128x4096, hold_subs_single=8:
    cachehit_sum/freed = 131072/16384 = 8.000 post-cache hits per line, exactly
plus the 8 pre-cache subscribers served and cleared at the CACHED transition = 16 = 2S.
The target is met exactly. Also withdrawn: "~2.9 hits per filled line" -- that divided a
PER-PERIOD hit count by a PER-PERIOD fill count, and cached lines live across period boundaries,
so hits in a window are not attributable to fills in the same window. Use the per-entry number
from free_outcome, which accumulates on the entry and is read once at its death.
Peer's own bug (separate): they keyed the merge on a BYTE address; ours is a WORD address, so
fp16 flh partners at addr and addr+2 are one key for us and two for them -- cache_hits=0 and
mean_served pinned at S. Their fix (base_addr = addr & ~3 for the single class) gives
mean_served=16.0 = 2S and 266,828 -> 6,472 cycles, i.e. +7.3% vs ours. Our RTL was right.

## (superseded) OPEN ITEM (raised by peer session teranoc_burst_mshr_gvsoc, 2026-09-02)
cache_reuse_target = 2 * hold_subs_single assumes a merge degree the SINGLE class never reaches.
Evidence, all 18 completed fp16 4x4 decode arms: free_outcome "single subs2p=0" on EVERY arm --
the single class always frees with exactly 1 subscriber, so the 2S target is unreachable in
practice. We do NOT show the peer's consequence (their model: 100% aged out, ways pinned for the
full 8191-cyc serve_timeout, 5.8M bank-full denials): on our fp16_ks8_16x128x4096 the cache never
fills (valid_max=0 hit=0 fill=0) and cache_aged=0. cache_aged IS live though -- non-zero on
exactly 2 of 18 arms: fp16_ks2_4x128x8192 (370) and fp16_ks4_16x128x4096 (1613).
Verified NOT the cause: fp16 A-loads really are half-words (matmul_8xVL emits 40 flh / 0 flw;
fp32 emits flw), so the half-word aliasing premise behind 2S is sound.
TODO: compare subs-per-entry histograms with the peer; decide whether 2S should be S.

- 01:25 step5 DONE: all 52 r8_8x8_*.elf built, 0 failures, 52/52 DISTINCT md5 (no shared-app-dir
  race), sizes scale with D*P as expected. Ready for step 6/7 once the image lands.

- 02:17 step3 BUILD-OK (simv 1,273,680 B). step4 RESTORED-OK NumMeshX=4 GroupX1Y0=4,
  RESTORE-CHECKSUMS-MATCH -- generated/ is safely back at 4x4 for the next 4x4 build.
- 02:25 step6 DEFINE-DIFF GATE PASSED. build_tgt8x8_hashfix vs build_tgt4x4_hashfix: 107 vs 107
  defines, differing in EXACTLY the six geometry ones and nothing else:
    AXI_WIDTH_INTERLEAVED 16->32, L2_BANKS 16->32, NUM_CORES 256->1024,
    NUM_GROUPS 16->64, NUM_X 4->8, TERAPOOL_SPATZ4_FPU -> TERAPOOL_SPATZ4_FPU_8X8
  Image built 2026-09-02 02:17, last RTL fix commit 2026-09-01 18:27 -> contains the fix.
- 02:26 step7 SUBMITTING all 52 arms, run-prefix r8, licence-only cap
  (max 200 / reserve_for_others 20). 46/100 seats in use at submit.
- REMAINING RUNTIME GATE for step 8: the RTL hash fix cannot be seen in the define set (it is a
  source change), so verify it at RUN TIME -- software prints "[MSHR] cfg REJECTED status=0x..
  -- MEASUREMENT INVALID" if any bank-shift CSR write is refused. If that appears on the r8 arms,
  the image does NOT have the BankShiftMin 5->4 fix and every r8 result is invalid. Check it on
  the first arms to reach the MSHR config point, BEFORE trusting any cycle count.
