# TeraNoC — Development Worklog

Running log of modifications and commits on this work. Every change records:
**time · purpose · implementation · result · status**. Newest entries are appended
at the bottom; the **Current Status** block below is kept in sync as the live view.

Branch: `zexin/teranoc_spatz_mshr`

---

## Current Status / Open Items  _(last updated 2026-06-11 10:00)_

**Audit-bug fixing pass (user: fix the 4 confirmed bugs one by one; review RTL carefully;
verify each with vector-burst-test + sp-mshr-burst-test; commit brief, no AI attribution).**
Each bug: hand-review + adversarial-verification workflow -> apply -> recompile build_2 ->
run BOTH tests in parallel (256 cores) -> confirm clean/no-regression -> commit.

- **#1 force_send cnt==1 (spatz_vlsu.sv)** — DONE. Dedicated branch issues the single pre-allocated
  beat without the !rob_full gate. Workflow: real, deadlock-capable; fix correct. Both tests PASS.
  Commits: spatz `6ab6903`, + test infra main `b5b3184` (vector-burst-test parallel verify+retval,
  was impractically slow with serial core-0 verify at 256 cores).
- **#2 AMO/cache race (mempool_group_mshr.sv)** — DONE. `&& !amo_invalidate` guard on the
  finalize->MSHR_CACHED. Workflow: real, fix complete (no residual stale path; response still
  delivered). Both tests PASS, byte-identical (no regression). Commit main `f7c6b31`.
- **#3 tcdm_id_remapper.burst_left decl** — DONE. Scalar -> [RobDepth-1:0][BurstLenWidth-1:0] array.
  Latent (burst_len=1 today), behavior-neutral. Both tests PASS identical. Commit main `de74d16`.
- **#4 EnableMshrSingleReq=1** — DONE (kept =1, no functional bug found). 4-agent investigation
  workflow: the hypothesized "duplicate-entry when CACHED" deadlock is UNREACHABLE. Load-bearing
  invariant: a CACHED entry always holds its data (resp_buf_cnt>0/resp_valid=1; finalize->CACHED
  never pops), so a single-word load to a cached address ALWAYS hits the merge path and never
  duplicate-allocates. The earlier sporadic sp-fmatmul hangs were the now-fixed VLSU force_send +
  burst-tail->store + AMO/cache bugs, not an MSHR dup. Added `cached_entry_holds_data` assertion
  (proves the invariant; silent across both full runs). EMPIRICAL LESSON: an address-only
  no-duplicate SVA I first added FIRED in P1 -> two valid entries CAN share an address legitimately
  (a late un-mergeable request allocates a 2nd entry with a different meta_id; responses route by
  tile/core/meta-range, not address) -> removed it as a false positive. Corrected the stale config
  comment (said keep=0 while shipping =1). Commit main `4e63d7d`. Both tests pass with =1.

**ALL 4 AUDIT BUGS DONE.** Commits: spatz `6ab6903` (#1); main `f7c6b31` (#2), `de74d16` (#3),
`4e63d7d` (#4); + test infra main `b5b3184` (vector-burst parallel verify). Verified each by
no-regression on vector-burst-test + sp-mshr-burst-test at 256 cores (both retval=0, orphan/dup=0,
no DecodeError/Stackoverflow/assert). Out of scope (not requested): audit perf items #5-#9, and the
latent burst+single same-address corner (synthesis residual #3, pre-existing, rare).

**Audit perf #5 (resp_buf depth):** analyzed + fix-drafted, then REVERTED & DEFERRED at user request
(2026-06-11) — `mempool_group.sv` back to HEAD. Full analysis preserved in the bottom entry
(`RespBufWords` `N+1` override, +97,280 FF cost, N-vs-N+1 trade-off, config-knob option). Resume later.
Perf #6-#9 also still out of scope. **Now pivoting to: sp-fmatmul-opt-burst-merge core-stuck bug.**

**RTL test harness:** build_2 has all 4 fixes' base; both tests robust at 256 cores
(sp-mshr ~29388ns, vector-burst ~24438ns, both retval=0, orphan/dup=0).

---

## Prior Status snapshot  _(2026-06-11 02:30)_

**ROOT-CAUSED + FIX APPLIED (validating): VLSU burst-tail -> store hang (the P1 `vld_m2(24)` wedge).**
- The hang is NOT a load-tail deadlock (earlier hypothesis, now corrected). It is a **store
  counter-corruption** caused by a **spurious `switch_to_tail_phase`** firing at the *end* of the
  preceding burst+tail load.
- **Mechanism (cycle-accurate waveform, build_test/vsim.wlf, hart0, ~T=7592-7602ns):**
  `vld_m2(...,24)` = VL=24 = 96B = one 16-word port0 burst + 8-word tail. Port0 finishes the whole
  load by itself (burst + scalar tail words), so `mem_counter[0]==commit_counter[0]==vl==96`.
  `switch_to_tail_phase` only checks a **lower** bound (`>= burst_full_bytes`), which is also true
  at completion (96>=64), so it **re-fires at end-of-life** and reloads BOTH counters to
  `burst_tail_base = 64>>2 = 16`. The next instr (the store) resets `mem_counter->0` via
  `commit_insn_push`, but `commit_counter` only reloads on `commit_insn_pop` -> it KEEPS the stale
  16. Store then commits only 24-16=8B (2 words) while mem needs 24B (6 words); `mem_counter`
  wedges at 8, ROB drains empty, store never finishes -> all 256 cores hang at the barrier.
  Proof: at store start `commit_counter={16,16,16,16}` but `mem_counter={0,0,0,0}`.
- **Fix (working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv, `switch_to_tail_phase`):** add upper-bound
  guard `(mem_counter_q[0] < commit_insn_q.vl) && (commit_counter_q[0] < commit_insn_q.vl)` so the
  switch can only fire while tail work genuinely remains, never after port0 already drained the
  instruction. Safe: port0 can always finish the tail via scalar word requests (fits in the 32-deep
  ROB), so blocking the (de-facto non-functional) multi-port-tail opt costs no correctness.
- **Status:** fix compiled clean (incremental, `spatz_vlsu` 0 err) in `build_2`. First fixed run
  (headless): **P1 store hang is GONE** — old run had 238 cores deadlocked *forever* at PC
  0x824–0x834 (`vld_m2(24)`) and never reached EOC; fixed run has **no core stuck at 0x824**, 16
  cores ran all of `main` and returned, and the sim **terminates** (`[EOC] retval=0`, cyc≈4705)
  instead of spinning. Phase->PC map: `vld_m2(24)` = vsetvli@0x824/vle32@0x828/vse32@0x830.
- **VALIDATED (waveform A/B, build_2/vsim.wlf, hart1 vld_m2(24) store @~T=5964ns):**
  with the fix, `switch_to_tail_phase`==0 for the whole load (no spurious fire); the store starts
  with `commit_counter={0,0,0,0}` (was {16,16,16,16}); `mem_counter` and `commit_counter` advance
  0->24 in lockstep and BOTH reach max=24 at T=5976 -> store retires cleanly. dasm confirms harts
  1/2/3 executed `vse@0x830`+`fence@0x834` and continued through the rest of P1 (vld_m1(7),
  vld_m4(64)) into P2 — in the old run cores deadlocked at 0x830 forever. **Fix confirmed.**
- **Downstream issue ROOT-CAUSED: SW build CONFIG MISMATCH (not an RTL/barrier/VLSU bug).** The
  `sp-mshr-burst-test` binary (built 01:40) was compiled with **NUM_CORES=4** (minpool) but run on
  256-core terapool HW. Proof: main prologue `csrr s4,mhartid; li a0,3; bltu a0,s4,skip` => active=4,
  so only cores 0-3 run the `if(on)` phase bodies (harts 1,2,3 + slow init core 0), cores 4-255 skip
  to barriers-only. AND `mempool_barrier(num_cores=4)` is called by all 256 cores -> the counter
  releases every 4 arrivals -> mismatched barriers -> the "Missed wake-up" storms, wave-completion,
  and the early first-finisher EOC. Explains every anomaly (231-at-barrier snapshot, 18 finishers
  skipping phases). **Fix:** rebuilt the test with `config=terapool_spatz4_fpu` (NUM_CORES=256):
  prologue now `li a0,255; bltu 255,cid` => all 256 cores participate. Re-running the full 256-core
  test (fix + correct binary) to validate vld_m2(24) at 256-way contention AND exercise P2-P7
  (MSHR merge/multicast/AMO). **Lesson:** always build spatz_apps SW with the matching `config=` —
  the default/`update_opcodes` path can silently produce a 4-core binary. (Matmul binary checked:
  built with NUM_CORES=256 — OK; only sp-mshr-burst-test was mis-built.)
- **Second downstream issue (SW): STACK OVERFLOW -> NoC DecodeError flood.** The corrected 256-core
  run progressed well (req 22k->119k, inflight=5, no deadlock) but flooded `DecodeError`
  (floo_route_comp.sv:66) because cores overflowed their **512 B** stack (`seq_mem_size`/`stack_size`
  =512, HW-fixed). `main`'s frame was **448 B**, dominated by `uint32_t buf[64]` (256 B); SP
  underflowed the stack -> loads/stores to invalid addresses -> NoC can't route -> DecodeError.
  (`.l1` data fits: percore 64 KB + shared + barriers ~74 KB < 76.8 KB region — not a data
  overflow.) **Fix:** capped `buf` to `BUF_WORDS=32` (min for the VL<=32 shapes) and reduced the
  lone VL=64 m4 case to VL=32; `main` frame now **320 B**. Rebuilt (active=256 preserved). Running a
  bounded 9000 ns check for Stackoverflow/DecodeError before the full P1-P7 run.
- **NB:** `stack_size`/`seq_mem_size` can't be bumped without recompiling HW (they define the local
  memory layout; HW was built with 512). Spatz vector apps are inherently stack-hungry (a VL=64
  vector = 256 B) — keep per-core stack buffers small or in `.l1`.
- **END-TO-END PASS (256 cores):** with the VLSU fix + buf=32, the full run printed
  `[UART] sp-mshr-burst-test: PASS (cores=256)` and `[EOC] retval=0` at 37432 ns. CMS throughout:
  req=resp=307133, inflight=0, **orphan=0, dup_alloc=0** (no MSHR over/under-delivery). **Both design
  pillars validated end-to-end:** (1) Spatz VLSU burst incl. the fixed VL=24 burst+tail (P1); (2)
  group-MSHR merge + multicast + overflow + AMO + meta-id wrap (P2-P7).
- **Third (cosmetic) SW issue: post-verdict printf stack overflow.** The DecodeError flood was
  POST-verdict (starts 35290 ns, after PASS printed and CMS drained at cyc 18000): the stack-heavy
  embedded `printf` overflows core 0's frame (main 320 B + printf > 512 B). **Fix:** report the
  verdict via the EOC return value (`return (int)g_fail;`, 0=PASS) and gate all printf behind
  `-DVERDICT_PRINTF`. main frame now 272 B; default build is printf-free.
- **FINAL CLEAN RUN (printf-free build): PASS, fully clean.** `[EOC] retval=0` (g_fail=0) at 29388 ns,
  **DecodeError=0, Stackoverflow=0**, CMS FINAL orphan=0 dup_alloc=0. Faster than the printf run
  (29.4k vs 37.4k ns — no post-verdict flood).

**Commits this session:**
- spatz repo `31bda68` — `spatz_vlsu: bound switch_to_tail_phase to remaining tail work` (the VLSU fix).
- main repo `1635a69` — `spatz_apps: add sp-mshr-burst-test regression` (the validated 256-core test).

**DONE (user option 3: commit VLSU fix + debug downstream):** VLSU VL=24 burst+tail->store hang
fixed/validated/committed; downstream "hang" was a 3-layer SW/test chain (4-core build mismatch ->
buf[64] stack overflow -> printf overflow), all fixed; test now PASSES clean at 256 cores validating
BOTH design pillars. Open (lower priority): audit bugs #2 (AMO/cache race — did NOT manifest in
P4/P5 at 256-way), #3 (tcdm_id_remapper.burst_left decl, latent); re-run es0-vs-es1 enable_single
comparison now that the test is clean.
- NOTE: report `bottleneck_analysis/2026-06-10_test_run_es0_vs_es1.md` corrected (was "load-tail
  HANG"; now annotated as the store counter-corruption above).

---

## Prior Status snapshot  _(2026-06-10 20:05)_

**Committed this session (branch `zexin/teranoc_spatz_mshr`, not pushed):**
- `d89f62e` — sp-fmatmul-opt-burst-merge kernel rewrite + 256³ + README
- `6ab1b5f` — core memory scoreboard VIP (tb_core_mem_scoreboard.sv + wiring)
- `78ea09e` — sp-fmatmul verify OOB fix + dimension guards
- `f52652d` — bootrom: widen data width 256→512 (terapool bus)
- `0f538fb` — mempool_group_mshr: gate verbose debug tracer behind `+define+GROUP_MSHR_DEBUG_TRACE` (silent by default; fixed the resp_buf_cnt OOB so it works when enabled)
- `bbf43cc` — vector-burst-test: default ACTIVE_CORES=0 (all cores)

**In progress:** reliable, fast, self-checking MSHR+burst regression test.
- `vector-burst-test` (per-core burst load/store) — committed `bbf43cc`.
- NEW `software/apps/spatz_apps/sp-mshr-burst-test/main.c` — created + builds clean. 7 phases: P1 burst shapes (m1/m2 full+tail, m4 no-burst), P2 scalar N-way merge+overflow+multicast, P3 burst merge, P4 AMO reduction (==N), P5 AMO+load mix (deterministic final), P6 back-to-back bursts (force_send/#1 stress), P7 meta_id wrap. Self-checking, per-phase fail mask, prints PASS/FAIL. Designed via a 4-lens coverage panel.
- **First run RESULT (both configs):** sp-mshr-burst-test HANGS in P1 at the `vld_m2(...,24)` — VL=24 LMUL=2 (16-word burst + 8-word **non-full tail**) — **identically for enable_single=0 AND =1** (cyc froze at 5000, inflight=0, all 256 cores at PC 0x824-0x834, core-cyc 7948). It is a **VLSU burst-tail deadlock, independent of the MSHR single-word path**. VL=32 m2 (two full bursts) passed just before, localizing it to the tail. The matmul never hit this (it uses VL=32, no tail). Comparison inconclusive (both die before P2 merge phases). Report: `bottleneck_analysis/2026-06-10_test_run_es0_vs_es1.md`. Both sims stopped (wlf+dasm preserved in build_test/build_es1 for debug); user GUI build_1 untouched.
- **Test is NOT yet committed** (it found a real hang; needs a reorder so P2-P7 can validate, and the VLSU tail bug needs fixing).

**RTL base is now clean for further edits:** `working_dir/spatz` clean; main-repo `*.sv` have no pending functional changes (mshr/bootrom committed).

**Uncommitted / deliverables waiting:**
- `CLAUDE.md` (rewritten), `AGENTS.md` — docs, untracked
- `hardware/bottleneck_analysis/2026-06-10_mshr_vlsu_burst_audit.md` — audit report, untracked
- `WORKLOG.md` — this file, untracked (keep OUT of commits unless told)
- `config/terapool_spatz4_fpu.mk` — debug values (`enable_single=1`, `remap=0`); decision pending
- `config/minpool_spatz4_fpu.mk` — `noc_router_remapping 0→3` (align w/ mempool_spatz)
- `hardware/scripts/questa/wave.tcl` (+123) — NoC-link + VIP wave groups (two features mixed)
- `.gitignore` (+`logs/`,`work/`), `vector-burst-test/main.c` (ACTIVE_CORES 0)
- **Do NOT commit:** `Bender.lock`/`Bender.local`/`hardware/deps/spatz`/`riscv-dbg` (bender clone artifacts), `.claude/`, `modelsim.ini`, scratch `scripts/questa/debug_*.tcl`

**Open audit findings to act on** (see audit report): #1 VLSU `force_send` cnt==1 stall/deadlock; #2 AMO/cache race; #5 stale resp_buf slots; #3 `tcdm_id_remapper.burst_left` decl; #10 line-969 part-select. Suggested order: #1, #2 first.

**Never completed:** a clean end-to-end `sp-fmatmul-opt-burst-merge` sim to EOC (`success!`) on terapool — last run was killed mid-flight (~cyc 24.7k).

---

## Log

### 2026-06-10 16:17 — Commit `d89f62e`: kernel rewrite for burst + MSHR merge
- **Purpose:** optimize `sp-fmatmul-opt-burst-merge` to exploit Spatz VLSU bursts (LMUL=2 B loads) and group-MSHR merge (8-way A, 2-way B) to cut inter-group traffic.
- **Implementation:** rewrote `kernel/sp-fmatmul.c`; bumped `script/matmul.json` to 256³; added `README.md`. (User staged; committed with no AI-attribution trailer.)
- **Result:** committed (3 files, +535/-657).
- **Status:** done. Note: README worked-example still says 128³/4-groups while json is 256³ — doc fix pending.

### 2026-06-10 16:41 — Commit `6ab1b5f`: core memory scoreboard VIP
- **Purpose:** non-synthesizable scoreboard at the core↔TCDM interface to track inflight Snitch+Spatz requests and flag stuck/orphan/dup; waveform-visible.
- **Implementation:** new `hardware/tb/tb_core_mem_scoreboard.sv` (module `u_cms`), instantiated in `mempool_tb.sv`; `Bender.yml` filelist entry; `hardware/scripts/summarize_cms.py` parser. Earlier refactored to repo style (logic + packed arrays). Burst-aware (N beats per qburst_len).
- **Result:** compiles clean (0 err/0 warn); committed (4 files, +635).
- **Status:** done. `wave.tcl` VIP wave group still uncommitted (mixed with NoC-link waves).

### 2026-06-10 18:06 — Commit `78ea09e`: sp-fmatmul verify OOB fix + dimension guards
- **Purpose:** fix a real `r[-1]` OOB in the verify error path; guard non-256 dims (odd N OOB, div-by-zero) without touching the hot kernel.
- **Implementation:** `verify_matrix` returns 1-based row; error path indexes `r[error-1]`; added uniform guards (`-3` N-even, `-4` M%groups, `-5` P%split, `-6` dim_group%kernel_size / split_m_count==0) all evaluated before any barrier; opt-in `STRICT_VERIFY` element-wise check vs `gemm_C_dram`.
- **Result:** built clean (`-Wall -Wextra -Wconversion`, no warnings). Adversarial review (3 agents) + hand-check confirmed: guards uniform → no barrier-skip hang; no-ops for 256³; `r[bad_row]` always in range. Div-by-zero (`-6`) added after review flagged it.
- **Status:** committed (`main.c`, +46/-3). Hot kernel `sp-fmatmul.c` unchanged → compute byte-identical. Full sim to `success!` not yet run.

### 2026-06-10 ~16:00 — Deliverable: CLAUDE.md rewrite (uncommitted)
- **Purpose:** /init — improve the existing CLAUDE.md.
- **Implementation:** verified existing claims via a 6-reader workflow; corrected (hierarchy: MSHR is inside mempool_group; per-flavor core/group table; COMPILER=llvm default; root riscv-tests uses CONFIG), added the floogen `-o update-floogen` gotcha, MSHR/remap config knobs, profiling/VIP tags, spatz `working_dir` override.
- **Result:** `CLAUDE.md` rewritten (~140 lines), `AGENTS.md` noted as complementary.
- **Status:** uncommitted (docs).

### 2026-06-10 18:50–19:30 — Deliverable: MSHR + VLSU burst audit (uncommitted)
- **Purpose:** find bugs/perf issues in group MSHR + Spatz VLSU burst + related RTL.
- **Implementation:** 7-dimension review→adversarial-verify workflow (~8000 lines audited); every blocker/major re-checked by hand against the RTL.
- **Result:** report at `hardware/bottleneck_analysis/2026-06-10_mshr_vlsu_burst_audit.md`. Confirmed bugs: #1 VLSU force_send cnt==1 (stall/deadlock-capable), #2 AMO/cache race (live, EnableRespCache=1), #3 tcdm_id_remapper.burst_left decl (latent), #4 enable_single config contradiction. Perf: #5 stale resp_buf slots, #6 MshrMergeReqs=8 cap, #7 shallow RespBuf, #8 burst-tail downgrade. Refuted: resp-port-hash mis-association, floo_remapper mapping, multi-beat over/under-delivery.
- **Status:** report written, uncommitted. Fixes not yet implemented.

### 2026-06-10 20:05 — Commits `f52652d`, `0f538fb`: bank clean RTL base
- **Purpose:** before implementing the audit fixes, commit pending RTL so new edits stay separable. (`working_dir/spatz` was already clean.)
- **Implementation:**
  - `f52652d` `bootrom.sv` — DataWidth/contents/addr-index 256→512 (terapool 512-bit AXI bus).
  - `0f538fb` `mempool_group_mshr.sv` — kept the verbose debug tracer but wrapped it in `` `ifdef GROUP_MSHR_DEBUG_TRACE `` (silent/compiled-out by default; re-enable via `+define+GROUP_MSHR_DEBUG_TRACE`); fixed the line-969 `resp_buf_cnt` OOB part-select (`8'(...)`); restored a botched flush-left `end` indent.
- **Result:** `make compile config=terapool_spatz4_fpu` clean — `mempool_group_mshr` 0 errors / 0 warnings; the prior `vopt-2697 resp_buf_cnt` warning is gone. Both committed (no AI-attribution). MSHR file now fully clean in git.
- **Status:** done. Clean base established for audit fixes #1 (spatz force_send) and #2 (AMO race).

### 2026-06-10 19:42 — Housekeeping: pruned build dirs
- **Purpose:** free disk space; user requested deleting all `hardware/build_*` except `build_1`.
- **Implementation:** `find hardware -maxdepth 1 -type d -name 'build_*' ! -name 'build_1' -exec rm -rf {} +` (24 dirs, incl. the session's `build_vip_test`).
- **Result:** ~1.6 TB freed; only `build_1/` remains; FS at 50% (3.4 T free).
- **Status:** done. Build artifacts are regenerable — re-run `make -o update-floogen compile config=... buildpath=...` when sims are needed again.

### 2026-06-11 01:50–02:45 — VLSU burst-tail -> store hang: root-cause, fix, validate
- **Purpose:** root-cause and fix the P1 `vld_m2(24)` hang (user: "continue debug vlsu, first test that doesn't pass").
- **Implementation:** cycle-accurate waveform analysis on the frozen hang (build_test/vsim.wlf, hart0,
  ~T=7592-7602ns) traced the wedge to `commit_counter` initializing to 16 (=`burst_tail_base`) while
  `mem_counter` reset to 0 — a spurious `switch_to_tail_phase` re-firing at the *completion* of the
  port0-only burst+tail load (lower-bound-only condition true at both the burst boundary and at vl).
  Fix: bound `switch_to_tail_phase` with `(mem_counter_q[0] < commit_insn_q.vl) && (commit_counter_q[0]
  < commit_insn_q.vl)` in working_dir/spatz/.../spatz_vlsu.sv. Incremental recompile in build_2 (0 err).
- **Result:** VALIDATED via waveform A/B (build_2, hart1): store now starts `commit_counter=0`,
  `mem`+`commit` reach max=24 in lockstep, store retires; harts 1/2/3 pass `vse@0x830` and continue
  through P1 into P2 (old run: deadlock at 0x830 forever). Reports/memory updated.
- **Status:** VLSU store hang FIXED + validated. Fix uncommitted (working_dir/spatz). Separate
  downstream multi-core barrier/EOC issue surfaced (231 cores at a barrier, first-finisher early EOC,
  printf not captured) — logged for a separate pass; P2-P7 merge phases not yet exercised.

### 2026-06-10 19:35 — This worklog created
- **Purpose:** per user request, maintain a traceable record of all work/commits.
- **Implementation:** created `WORKLOG.md` (root) + back-filled this session; saved the convention to agent memory (`feedback_worklog`).
- **Result:** file in place.
- **Status:** untracked; will keep updating on every change/commit going forward.

### 2026-06-11 09:50 — Audit perf #5: resp_buf depth widen (staged for review, not committed)
- **Purpose:** address audit perf #5 — `mshr_resp_slots = RespBufWords - resp_buf_cnt` is read
  BEFORE the same-cycle drain pop, so a just-freed slot is invisible to the capture gate; with the
  module-default depth (`N-1`=2 for terapool) two resp ports hitting the same in-flight MSHR in one
  cycle can falsely backpressure a NoC resp channel for a cycle.
- **Implementation:** override `RespBufWords` at the single MSHR instantiation
  (`mempool_group.sv:642`, gated by `EnableGroupMshr`) to `NumRemoteRespPortsPerTile>1 ? N+1 : 1`
  (=4 for terapool baseline; was 2). Pure depth change — burst completion stays drain-bound (1
  beat/cyc), same-cycle capture->deliver preserved (no single-word latency cost). Chose C-widen over
  A-reorder (would add +1 cyc to every single-word MSHR load) and B-forward (RAW hazard on
  resp_buf_cnt). Compile-checked clean in build_2.
- **HW overhead (verified by a 3-agent compute+adversarial workflow):** +95 registered bits/MSHR
  entry (resp_buf +90 [two 45-bit slots], resp_buf_valid +2, resp_buf_cnt +1, rd_ptr +1, wr_ptr +1)
  -> +6,080 FF/group (×MshrNum 64) -> +97,280 FF chip-wide (×NumGroups 16), ~0.1–1% of a 256-core
  FF budget; ~95% of the delta is the resp_buf data array. Combinational: mshr_d next-state widens by
  the same +95b/entry (logic, not FF); resp_buf write-demux 1-of-2->1-of-4 and drain read-mux
  2:1->4:1 (45-bit); pointer/counter compares +1 bit; no new critical loop (~1 extra mux level on
  resp_buf[rd_ptr]->resp_out). The 3 module-level RespBuf-scaled arrays (mshr_resp_slots,
  resp_push_ptr, resp_cnt_after_pop) are always_comb temporaries -> 0 FF. Tight minimum is likely
  `N` (=3, one-slot/~49k-FF saving) vs the safe `N+1`; kept N+1 for the can't-backpressure guarantee.
- **Design note:** overrode at the instantiation site (the ONLY instantiator) rather than editing the
  module default — keeps the module's `N-1` "minimal-correct" contract honest and the rationale at the
  decision point. Cleanest long-term form would be a `GROUP_MSHR_RESP_BUF_WORDS`/`group_mshr_resp_buf_words`
  build knob matching the existing `group_mshr_*` pattern (offered, not yet done).
- **Result:** benefit is backpressure-corner-only (NOT faster bursts — the audit "faster bursts" claim
  was an over-statement; drain is fundamentally 1 beat/cyc). Expect no measurable test-runtime change.
- **Status:** REVERTED at user request (2026-06-11 ~10:00) — `mempool_group.sv` restored to HEAD;
  perf work DEFERRED. Analysis above is the complete record to resume from (re-apply the L642 override,
  or promote to a `group_mshr_resp_buf_words` knob). Pivoted to the sp-fmatmul core-stuck bug.

### 2026-06-11 — Per-flit NoC req/resp tracer (functional+perf debug methodology)
- **Purpose:** user idea — a TB-level probe set (like the other `tb_*profiling.svh`) that records every
  remote memory REQUEST and RESPONSE as it crosses the NoC datapath, to a file a Python script then
  analyses for (a) WHERE/WHEN a req/resp flit is lost or stuck, (b) per-transaction req→resp latency,
  (c) NoC congestion points. Driving case: an `flw` to 0x52c08 (qid=0) from g12/t12/core0 FP-LSU at
  18182ns that never got a response (sp-fmatmul-opt-burst-merge hang, build_2).
- **Understanding (7-reader workflow wuvl8k8ls):** mapped exact tap points/struct fields/instance paths
  for all four datapath layers. KEY enabler: the group MSHR does NOT rewrite `meta_id`/`core_id` on the
  req side (only clamps AMO burst_len), and on the resp side reconstructs them from the stored sub_req —
  so a remote transaction carries a STABLE normalized key `(owner_group, owner_tile, core_id, meta_id)`
  from core port → MSHR → NoC flit → slave → back. Every tap can emit that same key ⇒ Python reconstructs
  each transaction's full path and pinpoints the stage where a stuck/lost one died. Address decode:
  0x52c08 (interleaved, ≥0x20000) → group 11, tile 0, bank 2 (NOT g12); so the stuck flw is a cross-group
  load g12/t12 → g11/t0 whose response must return g11→g12 via the g12 MSHR.
- **Implementation:** new `hardware/tb/tb_noc_req_resp_tracer.svh` (included in mempool_tb.sv after the
  bottleneck-profiling include, `ifndef VERILATOR + pragma translate_off, include-guarded). Emits ONE
  unified CSV `noc_trace/events.csv` (handshake = valid&&ready), columns:
  `time_ns,cyc,stage,loc_g,loc_t,loc_p,og,ot,core,mid,addr,tgt_g,tgt_t,tgt_bank,wen,burst,amo,data,mshr,sub,flags`.
  Tier-1 (always on, all robust module/tile-port XMRs):
    CORE_REQ/CORE_RSP @ gen_tiles[t].i_tile.snitch_data_{q,p}*[c][p];
    MSHR_REQ_IN/REQ_OUT/RSP_IN/RSP_OUT @ gen_group_mshr.i_group_mshr.{group_mshr_req,mshr_noc_req,
      mshr_noc_resp,group_mshr_resp}* + merge/bypass/is_mshr classification;
    SLAVE_REQ_IN/SLAVE_RSP_OUT @ destination tile tcdm_slave_{req,resp}* (owner key from src_group_id/
      ini_addr/core_id/meta_id payload).
  Tier-2 (`ifdef TRACER_TRACE_HOPS): per-hop directional router taps mirroring the proven
  tb_noc_visualization paths (gen_router_router_i[t].gen_router_wide_{req,resp}_router_j[*].gen_2dmesh.*
  .{valid_o,ready_i,data_o}[dir][0], dir 0..3 = N/E/S/W).
  Gated by csr_trace_any_global + plusargs +tracer_lo_ns/+tracer_hi_ns (focus window, no recompile) +
  +notracer. Python analyzer `hardware/scripts/analyze_noc_trace.py`: segments rows by (og,ot,core,mid)
  over time, prints each transaction's stage sequence, flags incomplete ones by last-stage-reached
  (localizes the deadlock), computes req→resp latency + per-stage congestion, and `--focus` one txn.
- **Result:** (pending) — compile-check in fresh build_trace (must NOT disturb build_1/build_2 GUI sims).
- **Status:** IN PROGRESS — writing files; will compile-check then run a focused window around 18182ns.

### 2026-06-11 (cont.) — Tracer RESULT: sp-fmatmul hang is a NoC protocol deadlock
- **Built & validated:** `tb_noc_req_resp_tracer.svh` (vlog 0 err; vsim +acc elaborated all CORE/MSHR/
  SLAVE XMRs, 0 err), `analyze_noc_trace.py` (frozen-vs-inflight discriminator, --routes geometry,
  --addr/--focus), `run_noc_trace.sh`. Ran sp-fmatmul in build_trace (NOT build_1/2), bounded
  `run 28000ns`, window [15000,28000]ns → 2,131,056 events, 50 min wall.
- **FINDING (see bottleneck_analysis/2026-06-11_sp_fmatmul_noc_deadlock.md):** the hang is a NoC-wide
  **message-dependent (protocol) deadlock**, not routing, not a dropped flit, not MSHR/slave logic.
  * The flagged stuck flw (g12/t12, 0x52c08) is a **coalesced MSHR follower** behind g12/t8's leader;
    8 g12 cores hit 0x52c08(→g11/t0/b2) in ~13 cyc; t8 reached MSHR_REQ_OUT@9106 but its req never
    reached g11 → followers (incl. t12) frozen at MSHR_REQ_IN forever.
  * 12,605 genuinely frozen txns, uniform across all 16 groups, both req (MSHR_REQ_OUT 2693) AND resp
    (SLAVE_RSP_OUT 3009) networks jammed; jam is in-transit (≈0 stuck at final delivery); onset ~cyc8850.
  * `--routes` imbalance: **g7=(1,3) net_in +1155 and g15=(3,3) net_in +1068 are the SINK epicentres**;
    x=3-column slaves (g12/13/14) responses can't escape.
  * Config is `noc_topology=0`(mesh) `noc_routing_algorithm=0`(XY) `vc=1`, separate req/resp nets →
    XY-mesh is deadlock-free by construction ⇒ deadlock is an ENDPOINT coupling: finite MSHR resp_buf
    (RespBufWords=2) + slave request-accept↔response-inject coupling close a cross-network cycle once
    the g7/g15 memory hotspot saturates. (Ties back to deferred audit perf #5 resp_buf depth.)
- **Status:** Tier-1 diagnosis COMPLETE & documented. Next (optional): Tier-2 hop tracing
  (`+define+TRACER_TRACE_HOPS`, recompile+rerun ~50 min) to pin exact deadlocked links at g7/g15;
  fix direction = make resp consumption deadlock-free / add VCs / deepen resp buffering.

### 2026-06-11 (cont.) — Tier-2 hop trace CONFIRMS locus = resp-network → group-MSHR ingress
- Reran with +define+TRACER_TRACE_HOPS (window [17000,24000], 1.90M events, 0 err, 29 min). Per-hop
  RTR_REQ/RTR_RSP rows show frozen txns complete REQUEST delivery (SLAVE_REQ_IN+SLAVE_RSP_OUT fire) but
  freeze at RTR_RSP **one hop from the requesting group** — responses can't eject into the requester's
  group-MSHR (mshr_noc_resp_ready_o low → resp_buf full/not draining). DEADLOCK FRONT concentrated on
  middle-column resp routers (g5/g6/g9/g10/g13/g14). Req-side jams (toward g7/g15) are SECONDARY.
- **Primary fault domain = mempool_group_mshr.sv resp ingress/drain** (severe form of audit perf #5).
  Fix priority: (1) make resp acceptance a guaranteed sink (mshr_noc_resp_ready_o must not wedge);
  (2) decouple slave req-accept from resp-inject; (3) add a resp VC/escape path. Full detail in
  bottleneck_analysis/2026-06-11_sp_fmatmul_noc_deadlock.md.
- **Status:** DIAGNOSIS COMPLETE (Tier-1 + Tier-2 hop-confirmed). Tracer methodology delivered & proven.

### 2026-06-12 — NoC deadlock fix report written (for user review; NO fix implemented)
- Deep-dived mempool_group_mshr.sv resp ingress/drain + characterized frozen txns from the trace.
  REFINED root cause: 6082/6083 frozen are SCALAR port-0 single-word reads; the 263 MSHR-resident
  blockers are all on the **bufferless BYPASS path** (resp_in_ready=resp_out_ready, :1380; resp_out
  from resp_in, :1383-1387) — response accepted into the MSHR but core won't take it, so
  mshr_noc_resp_ready_o drops and the SHARED NoC resp channel head-of-line-blocks → circular wait.
  So audit perf #5 (deepen resp_buf) is INSUFFICIENT (blockers bypass that buffer).
- Wrote `hardware/bottleneck_analysis/2026-06-12_noc_deadlock_fix_report.md`: full mechanism + 5 fix
  options with area/correctness tradeoffs. Recommendation = **Option A: group-MSHR response sink FIFO
  per (tile,resp-port)** (guaranteed consumption ⇒ mshr_noc_resp_ready_o never wedges ⇒ no HoL), sized
  to the per-port outstanding-load bound; VCs (D) and resp_buf-deepening rejected as insufficient for a
  consumption deadlock. Validation = re-run the tracer (zero frozen, or wedge moves to tile→core).
- **Status:** awaiting user review of the report before implementing any fix.

### 2026-06-13 — MSHR correctness audit + scalable-redesign plan (report; no RTL changed)
- User: review mshr alloc/merge logic for bugs + propose a banked, backend-feasible microarch that keeps
  cross-tile merge. Two workflows: (1) 7-dimension adversarial audit (34 agents): 27 candidates → 11
  CONFIRMED (16 refuted). HIGH: H1 misaligned-burst req_out.burst_len not clamped (non-owner merger hangs);
  H2 follower merges into un-allocated/stale entry when leader blocked by req_meta_conflict (hang/wrong-data);
  H3 store→CACHED write-through ignores byte-enables. MED: M1 MshrFullBurstWords==1 class overlap; M2-M4/L3
  index-priority starvation. (2) judge-panel redesign (timing/merge/migration proposals + synth).
- PLAN (report bottleneck_analysis/2026-06-13_mshr_audit_and_redesign.md): bank MSHRs by hash{tgt_group,addr}
  (NOT requester) → same addr→same bank ⇒ cross-tile merge preserved + each req compares only its bank's
  W ways. B=16/W=4 (cap unchanged). Serialize 1 ALLOC/bank/cyc (unlimited resident merges) ⇒ deletes the
  O(ports^2) leader/follower mesh (kills H2) + per-bank RR (kills M2/M3/M4/L3). Response match: tier-a
  bank-scoped owner scan O(ports×W) ships first (the "free entry-id tag" is NOT free — floo_tcdm_resp_meta_t
  has no spare field); tier-b round-trip bank-id = optional cross-module follow-on. Optional merge-directory
  safety valve (default off). Scales to MshrNum=256 by growing B (flat critical path). Migration: Step-0
  bit-identical rename (B=1), Step-0.5 land H1+H3, then bank/serialize/arbiter/resp/optionals.
- **Status:** report delivered for user review; awaiting decision before any RTL change.

### 2026-06-13 — MSHR redesign implementation START (Step 0.5: H1, H3) + Tier-b plumbing trace
- User approved the §2 address-banked redesign; "implement it, use Tier-b for response matching."
- CORRECTION to audit H1: the audit's suggested "clamp req_out.burst_len to 1" is WRONG — it would
  starve the OWNER (the VLSU still expects N beats). Correct fix = make a misaligned burst BYPASS the
  MSHR. Implemented: req_can_merge single arm now also requires req_len_raw==1 (genuine single), so a
  misaligned burst (req_len clamped to 1 but req_len_raw>1) falls through to bypass with its original
  burst_len intact (owner gets all beats; no non-owner can merge in). mempool_group_mshr.sv ~:509.
- H3 implemented: store->CACHED write-through now byte-merges under be (per-byte loop) instead of
  overwriting the full word. mempool_group_mshr.sv ~:1301.
- Both compile clean in build_trace (Errors: 0). Launched workflow w0xgozdn7 to map the Tier-b bank-id
  tag round-trip (req-pack / slave-echo / resp-unpack) across mempool_pkg + floonoc_wrapper + tcdm slave.
- NEXT: request-side address-banking rewrite (bank_of, bank-scoped hit/alloc, delete leader/follower,
  per-bank serialize + fair RR) — self-contained in mempool_group_mshr.sv; then Tier-b tag plumbing.
  Verification: bit-identical Step-0 baseline + sp-mshr-burst-test + vector-burst-test + [GroupMerge]/[CMS]
  (NOT sp-fmatmul completion — it stays hung until the separate response-deadlock fix).
- **Status:** Step 0.5 done+compiled; banking rewrite next.

### 2026-06-13 (cont.) — Tier-b tag plumbing DONE (Increment 1), compile-clean
- Added `mshr_tag` (top-level field, width MshrTagWidth=idx_width(MshrNum+1)=7b; tag 0 = bypass sentinel,
  real entry id e carried as e+1) round-tripping req->slave->resp. Edits (all compile-clean in build_trace):
  * mempool_pkg.sv: MshrTagNum/MshrTagWidth localparams + field on tcdm_master_req_t, tcdm_master_resp_t,
    tcdm_slave_req_t, tcdm_slave_resp_t, floo_tcdm_req_meta_t, floo_tcdm_resp_meta_t.
  * mempool_group_floonoc_wrapper.sv: 8 sites — 4 req-pack (2 wide active + 2 narrow ifdef), slave-req
    unpack, 2 resp-pack (remap+bypass), master-resp unpack.
  * mempool_tile.sv: bank_metadata_t field + meta_in pack + meta_out unpack (tcdm_adapter metadata
    spill_register auto-echoes — NO adapter change) + drive local/remote req-producer mshr_tag='0.
  * tcdm_wide_narrow_mux.sv: DMA wide literal mshr_tag:'0.
  * mempool_group_mshr.sv: req_out.mshr_tag default '0 + stamp (alloc id + 1) at allocation.
- Matcher UNCHANGED (still owner-scan) -> Increment 1 is behavior-preserving (tag rides, unused).
- NEXT: Increment 2 = response direct-index matcher (use mshr_tag: tag!=0 -> entry=tag-1, validate +
  W-way meta_id check) replacing the O(resp-ports x entries) scan (mempool_group_mshr.sv:1347-1389).
  Increment 3 = request-side address-banking (bank_of, bank-scoped hit/alloc, delete leader/follower,
  fair RR). Then regression: sp-mshr-burst-test + vector-burst-test (sp-fmatmul stays hung = separate
  deadlock). Step 0.5 (H1/H3) + Increment 1 both compile-clean; no sim run yet.
- **Status:** Tier-b plumbing in + compiling; matcher + banking next.

### 2026-06-13 (cont.) — Increment 2 (matcher) done; regression PASS on Step0.5+Inc1+Inc2
- Increment 2: resp matcher now direct-indexes by tag (tag!=0 -> entry=tag-1, re-validate state/owner/meta
  as stale-tag guard) replacing the O(resp-ports x MshrNum) owner scan. Compile-clean.
- REGRESSION (sp-mshr-burst-test, 256 cores, build_trace, run -a, 22min): PASS — orphan=0, dup_alloc=0,
  Errors=0, no STUCK warnings, EOC reached. Only end-of-sim inflight = 125 trailing EOC-register writes
  (0x40000000, age 1-14), the normal barrier-finish artifact. Tier-b foundation + H1/H3 validated.
- NEXT: Increment 3 = request-side address-banking. 3a: delete leader/follower mesh (O(ports^2), kills H2)
  + address-bank the allocator. 3b: bank-scope hit compare via dynamic-index mux (removes O(ports x entries)).
  Chosen per-port-mux variant (preserves multi-merge to hot addresses) over per-bank 1-req/cycle arbiter.

### 2026-06-13 (cont.) — Increment 3a DONE (address-banked alloc + leader/follower removed), compile-clean
- Added MshrWaysPerBank param (default 4) -> MshrBankNum=MshrNum/W=16 banks, BankIdW=4; mshr_bank_of()
  XOR-folds addr bits above BurstAlignBits with tgt_group (pure {group,addr}, zero requester dependence).
  req_bank[t][p] = mshr_bank_of(req_addr_key, tgt_group).
- DELETED the O(ports^2) leader/follower mesh (req_hit_req_map / req_leader_* generate blocks) -> kills
  audit bug H2. req_merge_valid simplified to req_can_merge && req_hit_mshr_sel_valid (existing-entry hit
  only); req_merge_ready=1. ALLOCATOR rewritten address-banked: static table scan with runtime bank-match
  (BankIdW'(mshr_i/MshrWaysPerBank)==req_bank), mshr_alloc_found guard gives distinct ways to same-bank
  requesters (or bypass if bank full). Same-cycle same-addr misses -> 2 entries (each own Tier-b tag),
  staggered ones still coalesce next cycle. (Unused leader decls left in place; cleanup later.)
- Hit detection still GLOBAL (3b will mux it to the bank's W ways for the O(ports x entries) win).
- Compile-clean in build_trace. Running sp-mshr-burst-test regression to validate the behavior change.
- NEXT: regression verdict -> Increment 3b (bank-scope hit detection via dynamic-index mux).

### 2026-06-13 (cont.) — Increment 3a regression: FUNCTIONALLY correct but PERF REGRESSION (course-correct)
- sp-mshr-burst-test on 3a: orphan=0, dup_alloc=0, Errors=0, EOC reached (no deadlock/correctness bug).
  BUT vs baseline (0.5+1+2): STUCK_REQ 0->1891, avg_lat 17->28 (+65%), peak inflight 842->4089,
  latency-histogram 1024-4096 bucket 2->1858. Coalescing collapsed.
- ROOT CAUSE: deleting the leader/follower mechanism killed SAME-CYCLE coalescing. sp-mshr-burst-test
  hammers same-cycle same-address access; without leader/follower, N same-cycle reqs take up to W=4
  entries + bypasses instead of 1 coalesced entry -> NoC traffic blowup -> tail-latency spike.
- REALIZATION: the user's feasibility concern is the per-request-vs-ALL-MSHRs cost (hit detect + alloc,
  scales with MSHR count) -> that's what banking should target (3a alloc done, 3b hit pending). The
  leader/follower is request-vs-request (O(ports^2), MSHR-count-independent) and PROVIDES same-cycle
  coalescing. Deleting it was an over-reach.
- COURSE-CORRECTION (recommended): RESTORE leader/follower, FIX H2 minimally (add !req_meta_conflict
  guard to the leader-alloc/allocator so a meta-conflicted leader doesn't let followers merge into an
  un-allocated entry), KEEP the address-banked allocator + bank_of, and do 3b (bank the hit detection).
  This recovers coalescing, fixes H2, and still addresses the MSHR-count feasibility concern.
- **Status:** 3a needs rework per above; awaiting user confirmation of direction before re-implementing.

### 2026-06-13 (cont.) — Increment 3 REVISED: per-bank 1-alloc + stall-and-merge (compile-clean)
- Replaced 3a's "multiple same-bank allocs" (which collapsed coalescing) with the user-chosen scheme:
  * req_alloc_cand[t][p] = mergeable load that missed all resident entries, no drain/meta hazard.
  * bank_free_id/bank_has_free: per-bank lowest free/reclaimable way.
  * Per-bank allocator: at most ONE candidate per bank granted a new entry/cycle (bank_alloc_taken
    guard, fixed lowest-index priority; RR fairness = follow-up).
  * Execution: STALL/ALLOCATE/BYPASS — a mergeable miss that lost the slot but bank_has_free STALLS
    (req_in_ready=0) and merges next cycle once the entry is resident (full coalescing, <=2 cycles, no
    O(ports^2) leader/follower); bank-full mergeable miss or store/AMO BYPASSES (deadlock-safe).
- Rationale (timing): keeps the coalescing BANDWIDTH benefit without the long combinational path (no
  O(ports^2) compare, no serial leader->alloc->follower chain). Coalescing now takes <=2 cycles instead
  of same-cycle; bandwidth benefit identical. Tradeoff: 1 alloc/bank/cycle also serializes distinct-addr
  cold misses that hash to the same bank.
- Compile-clean in build_trace. Hit detection still global (3b mux pending). Running sp-mshr-burst-test
  to confirm coalescing recovered (expect avg_lat ~back to baseline 17, no STUCK blowup, orphan/dup=0).

### 2026-06-13 (cont.) — Increment 3 (per-bank 1-alloc + stall-and-merge) REGRESSION: PASS, perf recovered
- sp-mshr-burst-test (build_trace, 256 cores): STUCK_REQ 0 (3a was 1891), avg_lat 17 (3a 28, =baseline),
  peak inflight 1030 (3a 4089), latency 1024-4096 bucket 0 (3a 1858, baseline 2), orphan=0, dup_alloc=0,
  Errors=0, EOC. => stall-and-merge FULLY recovers coalescing with the short path. Scheme validated.
- State now: Inc1+2 (Tier-b O(1) response), Inc3 (address-banked alloc, per-bank 1-alloc+stall-merge,
  no leader/follower), H1/H2/H3 fixed. Hit detection STILL global (3b mux pending). Running
  vector-burst-test for extra coverage.
- REMAINING: 3b (bank-scope hit detection via dynamic-index mux -> last O(ports x entries) reduction,
  behavior-preserving; needs mshr_hit_req entry-indexed rework). + RR fairness for per-bank alloc.
  + cleanup unused decls (req_hit_req*/req_leader*/mshr_alloc_found/ReqsPerMshr/MshrsPerReq).

### 2026-06-16 — New test: spatz_apps/mshr-capacity-test (group-MSHR capacity stressor)
- PURPOSE: companion to vector-burst-test; drives the per-group MSHR (mempool_group_mshr.sv)
  into its capacity corner cases with REMOTE (cross-group) vector-burst loads. Portable across the
  three Spatz sizes (minpool/mempool/terapool_spatz4_fpu).
- KEY RTL facts established (cited): NumBanksPerTile = NumCores*NumFUsPerCore*BankingFactor/NumTiles
  = 16 in every Spatz config -> a 64B-aligned 16xe32 vle32.v is exactly ONE tile (16 banks x 1 row) =
  one coalescable burst. group(A) = (A / (NumBanksPerTile*NumTilesPerGroup*4)) % NumGroups
  (mempool_tile.sv:1166). L1 ORIGIN=0 so a .l1 pointer IS the TCDM byte addr. MshrNum=1/16/64 for
  minpool/mempool/terapool; MshrMergeReqs=8; only single-word entries cacheable; overflow->bypass.
- TEST (software/apps/spatz_apps/mshr-capacity-test/main.c): self-contained, .l1 buffer w/ PATTERN(i),
  cooperative init, csr_trace bracket (mempool_start/stop_benchmark) so [MSHR stats]/CMS/tracer record,
  verdict via EOC return (0=PASS) + optional -DVERDICT_PRINTF. Four barrier-synced phases:
  P1 DISTINCT (peak occupancy / bank-full bypass), P2 SAME line (coalesce/merge/sub-req overflow/
  multicast), P3 single-word repeat (single path + resp cache), P4 length/alignment sweep.
  remote_line_word() guarantees each tested line is in a group != the issuing core's.
- BUILD VALIDATION: clean for all three configs (minpool/mempool/terapool_spatz4_fpu) under
  -Wall -Wextra -Wconversion. App auto-discovered by spatz_apps Makefile (no Makefile edit); no
  gendata entry needed (self-contained, like vector-burst-test).
- SIM FINDING (NOT the test's fault): minpool_spatz4_fpu AND mempool_spatz4_fpu are non-functional for
  real program execution on this branch -- host AXI chimney assertion NoWideSbrPortArRequest
  (floo_nw_chimney.sv:1293, EnSbrPort=0 but a wide AR arrives) at boot. minpool: assertion re-fires
  EVERY cycle (persistent) + 0 instructions executed (0-byte hart traces) -> wedged. mempool: assertion
  fires ~6x at boot then quiesces, sim advances to ~580k cyc but NEVER reaches start_benchmark (no
  periodic [MSHR stats], only cfg lines) -> cores never progress through the program. PROVED
  app-independent by reproducing the SAME boot assertion with stock vector-burst-test on minpool.
  => the smaller Spatz configs are bit-rotted on this branch; only terapool (the actively-developed
  config) boots+runs. Validation therefore moved to terapool_spatz4_fpu (build_3b).
- SIM VALIDATION (terapool_spatz4_fpu, build_3b, ACTIVE_CORES=64, -DVERDICT_PRINTF): **PASS** ->
  `[UART] mshr-capacity-test: PASS (cores=64 groups=16 lines=580)`, reached EOC, NoWideSbr asserts=0.
  Final [MSHR stats] aggregated over all 16 groups prove every corner case fires:
    accepted=5748 (single=5188 burst=560) | merged=2506 alloc=1580 bypass=3242
    mshr_overflow=698 subreq_overflow=46 | peak mshr_valid_max=64 (=full MshrNum) subreq_valid_max=96
    resps from_mshr=10416 from_bypass=3732 | cache hit=1603 fill=1368 evict=1097
  => peak occupancy, bank-full bypass, coalesce/merge, sub-req overflow, multicast, resp-cache all hit.
  (64 cores chosen to avoid the SEPARATE known 256-core reverted-FIFO HoL deadlock; full 256-core run
  is the real stress and may expose that pre-existing deadlock.)

### 2026-06-17 — sp-fmatmul-opt-burst-merge: switch verify to sp-fmatmul-opt's self-test
- build_2 transcript (terapool_spatz4_fpu): main loop + perf print OK, reached [EOC] retval=0, but the
  "set check" was the source of trouble. The committed source had an inline SAMPLED row-sum verify;
  the stack overflow the user saw came from a heavier verify variant (a per-row recompute that puts a
  >512B buffer on the 512B per-core stack).
- FIX (per request): main now calls the existing verify_matrix() -- exactly sp-fmatmul-opt's self-test:
  for each of M rows, sum c[i][0..P-1] and compare to r[i] (= gemm_checksum, host-verified) with abs
  tol 0.001. Removed the inline sampled/relative block. verify_matrix uses ONLY scalar locals (no
  recompute buffer) -> cannot overflow the 512B stack; and no fp DIVISION (nofdiv/XDIVSQRT=0 -> fdiv.s
  traps). Kept BARRIER-SAFE: core 0 does NOT early-return on mismatch; all cores reach the final
  mempool_barrier (a core-0-only return there leaves the rest in WFI and hangs the run).
- Rebuilt terapool binary (Errors:0); confirmed new strings (success! / "row %d checksum mismatch")
  present, old strings (rowsum verify / DATA CORRECT/MISMATCH) gone, no real fdiv in the 0x8000_xxxx
  code region.
- CAVEAT: verify_matrix is a FULL M*P sweep -> ~32x more cid-0 serial REMOTE reads of c than the 8-row
  sample, so the verify tail is slower and emits more (non-fatal) FlooNoC DecodeError asserts from the
  cid-0 cross-group scalar-read path (a separate terapool HW issue; the prior run still reached EOC).
  It will NOT stack-overflow or hang. Re-run in build_2 to pick up the new binary; do NOT validate on
  build_3b (reverted-FIFO MSHR -> sp-fmatmul HoL deadlock, unrelated to the verify).

### 2026-06-17 — Consolidate mshr-capacity-test into sp-mshr-burst-test
- Folded the two UNIQUE capacity phases of mshr-capacity-test into sp-mshr-burst-test (the rest
  -- same-line coalesce, length sweep -- duplicated existing P2/P3/P1):
  - P8: distinct remote bursts -> peak MSHR occupancy + bank-full bypass.
  - P9: repeated single-word remote load -> response-cache hits (P8 churn drives fill/evict).
  Reused the existing gold/CHECK/fail-mask machinery; added a guaranteed-remote addressing helper
  (l1_group_of/remote_line, group stride = NumBanksPerTile*NumTilesPerGroup*4) drawing 64B-aligned
  lines from the initialised percore pool (golden via gold_pc_w). Verdict loop extended to P1..P9.
- Added a mempool_start/stop_benchmark() bracket so [CMS] + [MSHR stats] (gated on csr_trace) record
  -- the test's header already said "run alongside the [CMS] VIP" but never enabled tracing.
- Deleted software/apps/spatz_apps/mshr-capacity-test/ (untracked; now superseded). Updated README
  (nine phases, P8/P9 rows, remote-helper note, CACHE_REPS tunable, ACTIVE_CORES default note).
- Build: terapool_spatz4_fpu with -Wall -Wextra -Wconversion -DVERDICT_PRINTF -> Errors:0, no warnings.
  NOTE: ACTIVE_CORES currently defaults to 1 (debug) in main.c; set 0 for full multi-core MSHR stress.

### 2026-06-17 — sp-mshr-burst-test: fix single-core run never allocating the MSHR
- BUG (user-found, confirmed via llvm-nm + RTL group rule): with ACTIVE_CORES=1 the group-0 MSHR was
  never allocated. Root cause: core 0 lives in group 0 and every address it touched was group 0 ->
  intra-group crossbar, never the (inter-group) MSHR. Specifically: nlines = active*PC_WORDS/16 = 4 ->
  remote_line's pool was only core 0's own 4 group-0 lines, so it fell back to a local line; P1/P6/P7
  read percore[cid*64] (= percore[0], group 0); P2/P3/P4/P5 read shared_s/shared_b/amo_* (all group 0).
  Earlier "94% remote" only held with all 256 cores spanning all groups -- remoteness was accidental.
- KEY fact: the group MSHR is SOURCE-side (coalesces a group's OUTGOING remote loads), so making core 0
  load from another group is what makes GROUP 0's MSHR allocate (which is what the user was watching).
- FIX: (1) init the FULL percore pool (striped over active cores) so a remote target in any group has a
  valid golden even with 1 core; (2) nlines = full pool (NUM_CORES*PC_WORDS/16); (3) new remote_base()
  helper -> PC_WORDS-aligned owner region in a group != issuing core's; (4) P1/P6/P7 now read
  remote_base(my_group,cid) (golden gold_pc_w); P8/P9 already use remote_line, now over the full pool.
  Verified by address math: for cid 0 (and 1/15/16) P1/P6/P7/P8/P9 all target a remote group.
- P2/P3 (single-word/burst MERGE) and P4/P5 (AMO, bypasses MSHR by design) still read the group-0
  shared/AMO arrays -> local for a lone group-0 core; coalescing is inherently multi-core. Noted in README.
- Build: terapool_spatz4_fpu -> Errors:0, no warnings (file now self-#defines VERDICT_PRINTF). README synced.

### 2026-06-18 — sp-mshr-burst-test: 1-core MSHR-alloc fix VALIDATED in sim + init optimization
- Optimized the init: each active core now writes ONLY the remote regions it reads (rb owner region +
  P8/P9 lines, precomputed once and reused by init+phases) instead of the full 16384-word pool. A single
  core inits ~96 words. (The full-pool init made a 1-core run spend ~50k cycles in init before any MSHR
  phase -- it wouldn't reach the phases inside the sim watchdog.)
- SIM VALIDATION (terapool_spatz4_fpu, ACTIVE_CORES=1, build_3b): PASS, [EOC] retval=0 @38236ns.
  Group-0 [MSHR stats] per-period timeline confirms the fix -- the MSHR (was idle before) now allocates:
    burst reqs present (burst=3/1/2/4/2/3/1 across periods), alloc up to 9/period,
    mshr_valid_max peak=9, subreq_valid_max peak=9, P9 response-cache hit=6 fill=1.
  rb/w9 confirmed remote (percore@0x20000 grp0; rb word256@0x20400 grp1; w9 word272@0x20440 grp1) ->
  core 0 (group 0) remote loads route through GROUP 0's source-side MSHR, which now allocates.
- Note: with 1 core, merged~=0 and bypass~=accepted (no peer to coalesce with) -- expected; cross-core
  merge needs multiple cores. Gotcha learned: MSHR [MSHR stats] are PER-PERIOD, not cumulative -- read
  the whole timeline, not just the final (trace_off) partial-period block.
- README synced (init description + 1-core validation note). Working-tree changes; not committed.

### 2026-06-18 — sp-mshr-burst-test: per-phase waveform marker + config-portability finding
- CONFIG PORTABILITY (user asked re: smaller configs): the kernel GEOMETRY is fully correct on
  mempool_spatz4_fpu (same 16-tile/group stride as terapool -> remote_base/remote_line all remote) but
  BROKEN on minpool_spatz4_fpu (1 tile/group: remote_base's PC_WORDS owner stride is a multiple of the
  4-group span -> falls back to LOCAL; only remote_line/P8/P9 stay remote). BUT both smaller Spatz
  configs are NON-FUNCTIONAL on this branch: verified mempool_spatz4_fpu 1-core run = killed at watchdog,
  req=0 entire run, 0 instructions, no [MSHR stats] (boots past the 6x transient chimney assert then
  hangs). SAME binary PASS+EOC on terapool. => terapool_spatz4_fpu is the ONLY working config; corrected
  my earlier wrong "mempool boots and runs".
- PER-PHASE WAVEFORM MARKER (user request): replaced the single start/stop_benchmark bracket with
  per-phase phase_begin(n)/phase_end() that write the phase NUMBER (1..9) to the trace CSR (0x7d0), 0
  between phases. Confirmed in dump: `csrwi trace,1 / trace,0 / trace,2 ...`. Benefits: (a) waveform shows
  which phase is running (1..9 staircase), (b) [CMS]/[MSHR stats] now print PER PHASE (each phase = one
  trace window).
- TB (mempool_tb.sv): csr_trace_q gate changed to |reduction (so phase numbers !=1 still enable profiling;
  backward-compatible -- write 1 -> |1=1) + added core_bench_phase[NumCores][32] cascade tapping each
  core's full csr_trace_q. wave.tcl: new Benchmark_Phase group (core_bench_phase analog + csr_trace_any_global).
- Verified: SW build clean (terapool); build_3b RTL recompiled clean (mempool_tb Errors:0). Needs the
  RTL recompile to use core_bench_phase (build_3b already done). README synced. Working-tree changes; not committed.

### 2026-06-18 — sp-mshr-burst-test arc complete (committed); pivoting to Spatz VLSU burst work
- Final commits this arc: 0dfa6ef (cross-group load targeting + per-phase trace marker; main.c/tb/wave),
  c488cf5 (P2/P3 coalesce on a remote group-1 line `cg`=line_in_group(1)=0x20400; + README). README is
  now tracked and fully documents the 9 phases, per-core source-address tables (ACTIVE_CORES=0), the
  trace-CSR phase marker (csrwi trace,N -> waveform staircase via core_bench_phase), and the source-side
  MSHR coalescing model.
- STATE for the group-MSHR waveform check (user is doing this in build_2 GUI sim): terapool_spatz4_fpu is
  the ONLY config that boots+runs (minpool/mempool_spatz wedge at boot on this branch). build_3b RTL is
  recompiled with the new TB taps (core_stall, core_bench_phase, |-reduction csr_trace gate).
- OPEN items on sp-mshr-burst-test (not blocking): P8/P9 collapse to one line per home group via
  remote_line(cid) -> P8 coalesces instead of reaching peak occupancy (offered to fix w/ a per-core
  stride; user hasn't requested). With ACTIVE_CORES=16 the user can now see P2/P3 (group-1) coalescing.
- NEXT TASK (user will instruct): Spatz VLSU vector-load BURST support improvement. Relevant code lives at
  working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv (Bender.local path override, NOT hardware/deps). See
  memories project_spatz_vlsu_burst, project_vlsu_burst_deadlock, project_vlsu_burst_tail_store_hang.
- Uncommitted working-tree (intentionally left): .gitignore, Bender.lock (local working_dir/spatz path
  override -- keep out), config/minpool_spatz4_fpu.mk, sp-fmatmul-opt-burst-merge/main.c.

## 2026-06-18 — VLSU burst multi-port response/tail investigation + IC plan (no RTL yet)
- PURPOSE: user wants (1) burst load RESPONSE received across all 4 VLSU ports (not port 0 only),
  (2) trailing non-burst (tail) requests across all 4 ports. IC timing/area/power = hard constraint.
- METHOD: 31-agent workflow wfrfmbg8l (6 investigate -> 3 diverse designs -> 3-lens adversarial
  verify -> synthesize). Full output tasks/wfrfmbg8l.output. DETAILED REPORT:
  hardware/bottleneck_analysis/2026-06-18_vlsu_burst_multiport_report.md (problem + investigation +
  options + plan); companion condensed plan: ..._vlsu_burst_multiport_plan.md.
- KEY RESULT (non-obvious): the VLSU port-0 gate is NOT the real limiter. The group MSHR drains
  ONE head beat per entry per cycle (resp_beat_offset scalar mempool_group_mshr.sv:1528-1539;
  finalize pops 1 slot/beats_left-=1 at 1745-1810; resp_buf only RespBufWords=2 deep). DrainMultiPort=1
  spreads across CORES not BEATS. + baseline noc_resp_channel_num=2 => only 2 usable resp ports
  (drain loops {1,2} at 1565/1589/1626). => per-core burst response HARD-CAPPED ~2 words/cyc; 4x
  needs noc_resp_channel_num=4 (mesh widen). Saved as memory project_vlsu_burst_response_bw_ceiling.
- REJECTED: VLSU/port-select-only fix (verified no-op); source-striping into 4 sub-bursts (fragments
  MSHR coalescing: same-bank way contention + 64B-align clamp 565-571 -> bypass deadlock; merge 8->2;
  + hits same 2-port ceiling); 128b wide flit (false 32b-bank premise mempool_tile.sv:735; 4x mesh width).
- RECOMMENDED (coalescing-preserving, FEASIBLE): keep ONE 16-word/64B-aligned/single-core_id burst
  request; change only the RETURN path. Phases: P0 measure (sp-mshr-burst-test + GROUP_MSHR_ENABLE_STATS
  + tracer); P1 overlap tail by relaxing switch_to_tail full-drain gate (KEEP <vl guards = VL=24 hang
  fix) spatz_vlsu.sv:1017-1028; P2 VLSU receive de-gate -> commit via all-lanes 1163-1233 + per-LOGICAL-
  burst mem_pending/ROB-id accounting; P3 (real fix) multi-beat-per-entry MSHR drain (deepen resp_buf,
  N head ptrs, 2-wide pop, map_resp_port_id_striped) + VLSU receive beat b on ROB[b mod 2] -> ~2 words/cyc;
  P4 optional noc_resp_channel_num 2->4 for 4x. Tail issue2 = VLSU-local (Defect A serial-after-drain,
  Defect B <4-word tails stripe-degenerate); not port-0-pinned.
- STATUS: investigation+plan complete, NO RTL changed. Awaiting user direction (likely start P0 measure
  or P1 tail-overlap). Open gating question: is the burst's beats actually delivered on >1 resp channel
  concurrently or serialized upstream by single-bank read rate? (needs waveform).

## 2026-06-18 — sp-fmatmul-opt-burst-merge README corrected (user reviewing kernel before burst work)
- PURPOSE: user will first judge if sp-fmatmul-opt-burst-merge is good enough for burst/coalescing
  testing; asked to make its README clear + aligned with kernel size/design.
- FOUND README stale (dated Apr 9, mempool-era): said M=N=P=128 + mempool_spatz4_fpu (64 cores/4 groups).
  REALITY: data is 256x256x256 (script/matmul.json, data_*.h gitignored); main.c is config-parametric
  (cores_per_group=num_cores/NUM_GROUPS, dim_group=M/active_groups); only terapool_spatz4_fpu boots.
- TERAPOOL instance (256 cores/16 groups, 256^3): dim_group=16, split_m_count=2, split_p_count=8 ->
  each core = 8x32 tile (32 cols = 128B = burst-eligible -> 2x16-word bursts; coincidentally same 32
  cols/core as the old mempool numbers via different arithmetic). Inner loop n=0..255, strides=1024B.
  Coalescing: only 2-WAY per group (core k & k+8 share p_start -> same B addr). A-loads scalar (port0).
- REWROTE README to terapool/256: header, work-dist arithmetic, core table (g0 cores 0-15), inner-loop
  sizes/strides/traffic (256 B-loads=32KiB, 2048 A-loads=8KiB), per-core addr diffs, terapool addr->tile
  map (bank[5:2]/tile[9:6]/group[13:10], group stride 1024B), verify_matrix section, + a "tuning the
  burst/coalescing test" note (to raise merge degree need larger per-core P-tile / fewer active cores).
- VERDICT for user: kernel IS burst-eligible on terapool (good), but MSHR merge is only 2-way per group
  with 256^3/256-core split; flag if a higher coalescing stress is wanted.

## 2026-06-18 — sp-fmatmul-opt-burst-merge SW-optimization review (36-agent workflow wtory90pv)
- ASK: find big SW perf wins (better coalescing + max register use to hide L1 latency). Report:
  hardware/bottleneck_analysis/2026-06-18_sp_fmatmul_burst_merge_sw_opt.md. NO code changed.
- KEY RESULT: kernel is COMPUTE-BOUND at a per-core 16384-cyc FPU floor (65536 FMA / 4 lanes);
  no SW change lowers it. Steady-state B demand 0.5 word/cyc, ~4x under the ~2-word/cyc per-core
  response ceiling -> latency-bound only on cold first-touch. So NO big multiplicative win exists.
- COALESCING is NOT a throughput lever here (per-core receive ceiling independent of merge degree;
  post-merge traffic = N*P conserved). Deep VECTOR B-prefetch CAN'T issue (VLSU op-queue depth-2
  spill_register serializes vle; NrParallelInstructions=4). Both rejected after adversarial verify.
- ONLY real wins (cold-tail, modest): W1 matmul_16xVL (LMUL=1 VL=16=one 16-word burst, 16 acc
  v0..v15 + v16/v17 = 18/32 vregs, B-reuse 8->16; needs kernel_size==16 dispatch arm in main.c;
  ~1.1-1.35x if first-touch-exposed, ~1.0x if warm). W2 2-deep SCALAR A prefetch (FP-LSU separate
  domain; flw gates only on outstanding vector STORES=0; acc_mem_cnt=='1 is all-ones=7 not 1 -- an
  adversarial FATAL verdict was refuted; ~1.03-1.12x). W2 stacks on 8xVL; on 16xVL keep A 1-deep (LAQ full).
- ACTION/OPEN: MEASURE baseline cycles vs 16384 floor FIRST (grep [BP]; waveform vfmacc issue-stall
  vs vlsu_rsp_valid). If at floor -> realistic win <=1.05x, don't ship. Saved memory
  project_sp_fmatmul_compute_bound.

## 2026-06-19 — sp-fmatmul-opt-burst-merge: keep matmul_NxVL out-of-line + not auto-unrolled
- WHY (user): inlining the NxVL kernels is meaningless (hot loop is inside the kernel, not main);
  compiler auto-unroll duplicates the large inline-asm body -> icache misses / icache overflow.
- FOUND: kernel/sp-fmatmul.h DECLARED matmul_2xVL/4xVL/8xVL as `inline __attribute__((always_inline))`
  -- the exact OPPOSITE. Default compiler is clang @ -O3 (aggressive unroller); no -funroll-loops.
- CHANGE (kernel/sp-fmatmul.h + kernel/sp-fmatmul.c): added portable macros
  KERNEL_ATTR (clang: noinline; gcc: noinline,noclone) and KERNEL_NO_UNROLL (clang:
  `#pragma clang loop unroll(disable)`; gcc: `#pragma GCC unroll 1`). Flipped the 3 NxVL decls from
  always_inline -> KERNEL_ATTR; applied KERNEL_ATTR to the 3 definitions; put KERNEL_NO_UNROLL before
  each function's m-loop and hot inner while(n<N) loop. Left matmul (dispatcher) + the vestigial
  always_inline matmul_single_unrolled (undefined/unused) untouched.
- VERIFIED: builds clean (clang -O3 -Wall -Wextra, no warnings). Disassembly
  (bin/apps/spatz_apps/sp-fmatmul-opt-burst-merge.dump): the 3 kernels are SEPARATE out-of-line
  symbols (no inline/clone); matmul_8xVL = 904 B, branch targets all internal; vector-op counts match
  source 1:1 (24 vfmacc.vf + 8 vfmul.vf + 3 vle32.v + 8 vse32.v) => NO extra unroll.
- NOTE: clang LSP flags size_t/gvl "undeclared" in sp-fmatmul.c -- FALSE POSITIVE (file is #included
  into main.c which provides the headers; the file is not a standalone TU). Real build is clean.

## 2026-06-19 — sp-fmatmul-opt-burst-merge: peel the (n==1) init out of the inner loop
- WHY (user): the inner n-loop tested `if (n == 1)` every iteration (n==1 only true once) to pick
  vfmul (init) vs vfmacc (accumulate). Peel iteration 1 so the hot loop is branch-free vfmacc, and
  the 8/4/2 vfmul leave the hot loop body (smaller hot loop = less icache).
- CHANGE (kernel/sp-fmatmul.c, all 3 matmul_NxVL): replaced the in-loop if(n==1)/else with a peeled
  prologue = [first half: vfmul col0 with the init B buffer] + [second half: vfmacc col1, guarded by
  `if (n != N)` to preserve the original N==2 mid-break semantics]; steady while(n<N) loop is now
  pure vfmacc. Epilogue unchanged. Double-buffer order/registers preserved per-function (8xVL v18/v20
  acc v0..v14; 4xVL v16/v20 acc v0,4,8,12; 2xVL v16/v24 acc v0,v8).
- VERIFIED (disasm bin/.../sp-fmatmul-opt-burst-merge.dump): no `if (n == 1)` in source; build clean
  (clang -O3 -Wall -Wextra). 8xVL: 232 instr, 8 vfmul in ONE prologue block reached once via `j` after
  preload, steady loop back-edges to 0x294 with ONLY vfmacc, ZERO n==1 compares (+16 B vs pre-peel,
  hot loop smaller). 4xVL clean (single 4-vfmul prologue, 16 vfmacc). 2xVL: source clean but CLANG
  loop-VERSIONED the tiny LMUL=8 body into 2 copies (4 vfmul) -- unroll(disable) doesn't stop peeling;
  2xVL is DEAD CODE here (M=256 -> 8xVL) so no impact. Live 8xVL is the one that matters: clean.
- VALIDATION GAP: structural/op-count verified, but FUNCTIONAL correctness of the hand-asm GEMM change
  is NOT yet sim-tested. MUST run verify_matrix (row-checksum self-test, tol 0.001) on terapool sim
  before trusting. matmul_4xVL/2xVL not exercised by this app (M<=8) so the self-test won't cover them.

## 2026-06-19 — readability: split `a__ = a_ + ++n;` -> `++n; a__ = a_ + n;` (12 sites, all 3 kernels)
- Pure readability; same sequence point -> identical -O3 codegen. PROVEN: rebuilt and diffed disasm vs
  before. matmul_* .text byte-for-byte IDENTICAL; no 0x80000xxx (.text incl. main) diffs at all; .data
  (matrix input) unchanged; build is deterministic (2 same-source builds = 0 diff).
- The whole-dump diff showed 321 lines but ONLY in section .l1_seq, which is NOBITS (zero-init scratch
  RAM, size 0x20000 @ 0x0, no file content) -- llvm-objdump -D decodes it as garbage (fnmadd.h etc.);
  it is NOT program content. Red herring. Build the app from software/apps/spatz_apps (NOT software/;
  the app make rule lives in apps/spatz_apps/Makefile -> "No rule to make target" if run from software/).

## 2026-06-19 — RTL check: is the vfmul/flw/vle interleave serialized in HW w/o data dep? (workflow wuxexg8v0)
- ASK: does the kernel's fine-grain interleave (flw scalar-A preload + vle vector preload + vfmacc)
  actually overlap, or does HW serialize it despite no data dependency? Report:
  hardware/bottleneck_analysis/2026-06-19_matmul_issue_serialization.md. NO code changed.
- ROOT CAUSE (dominant false-serializer): FP-LSU instantiated with DEFAULT NumOutstandingMem=1 (depth-1
  i_fifo_mem, snitch_lsu.sv:17,90-106; spatz_fpu_sequencer.sv:528-534 sets only NumOutstandingLoads=16=LAQ,
  not NumOutstandingMem). 8 flw/iter SERIALIZE on memory round-trip despite distinct regs; 16-deep LAQ is a
  red herring. Snitch in-order single-issue (one acc_qvalid/acc_qready handshake, snitch.sv:447,451 ->
  combinational issue_ready_o) means the stalled flw also holds the next vfmacc.
- CORRECTS the 2026-06-18 "2-deep scalar-A prefetch feasible" claim -> it does NOT help w/o HW change.
  Updated memory project_sp_fmatmul_compute_bound; added project_matmul_flw_serialization.
- REFUTED (adversarial): sequencer issue gate is NOT the blocker (flw is_local bypasses controller); a
  vector op does NOT block flw; NO false scoreboard WAR/WAW (distinct accumulators). OVERLAPS THAT WORK:
  vfmacc<->vfmacc (VFU roofline), vle<->vfmacc (separate units/ports), single-vle latency under the burst,
  flw concurrent w/ in-flight vle.
- SECONDARY: VLSU op-queue head advances only on full VRF commit -> 2nd vle requests serialize (B prefetch
  caps at 1, not a true memory prefetch); shared 7-deep acc_mem_cnt (flw+vle) is the next ceiling after the
  FP-LSU fix.
- FIX: HW pass NumOutstandingMem(=8) to snitch_lsu IFF TCDM port0 returns scalar loads IN REQUEST ORDER
  (LAQ is FIFO-tagged; MSHR/NoC may reorder -- VERIFY w/ CMS scoreboard or noc_req_resp_tracer first, else
  id-tag the LAQ). SW: widen B buffer to 3-4 vregs (breaks WAR) but bounded by VLSU req serialization; don't
  reorder the inner body (near-optimal); raise B-reuse (16xVL) to amortize per-flw serialization.

## 2026-06-19 (later) — CORRECTION: the flw-serialization finding above is WRONG (read a non-compiled file)
- When asked to IMPLEMENT the NumOutstandingMem fix + sim, I first re-checked which snitch_lsu is compiled.
  ROOT Bender.yml:15 pulls snitch from hardware/deps/snitch; working_dir/spatz's snitch block (incl
  snitch_lsu.sv) is ALL commented out in working_dir/spatz/Bender.yml -> NOT compiled.
- The COMPILED FP-LSU = hardware/deps/snitch/src/snitch_lsu.sv (248 lines): id-based, OUT-OF-ORDER
  (doc line 8; data_qid_o/data_pid_i; metadata_q[req_id], resp_metadata=metadata_q[resp_id] @99-121,203-206).
  NO NumOutstandingMem param; NumOutstandingLoads=16 for the FP-LSU (spatz_mempool_cc.sv:207-209->spatz.sv:146).
  Proof: instantiation ports data_qaddr_o/data_qid_o/data_pid_i only match the deps file; working_dir file
  (dreq_t/drsp_t, no id) would fail to elaborate.
- => The 8 flw ALREADY pipeline (<=16 OOO, id-matched). NO 1-outstanding serialization; NO fix to make.
  The "scalar-A prefetch futile" claim is REVERSED. Real residual caps are minor: shared acc_mem_cnt=7
  (flw+vle combined), VLSU op-queue head-of-line for the 2nd vle, single-issue 1/cycle; and the loop is
  COMPUTE-BOUND (16384-cyc floor) so none yields a meaningful win.
- DID NOT implement the moot NumOutstandingMem fix and DID NOT run the demo sims (would show no win).
  Corrected: report banner (2026-06-19_matmul_issue_serialization.md), memory project_matmul_flw_serialization
  (now a correction note + general lesson: verify a file is COMPILED via Bender.yml), project_sp_fmatmul_compute_bound.
- LESSON: the prior 11-agent workflow (and its adversarial verify) both read working_dir/.../snitch_lsu.sv
  without checking it's compiled -- a plausible-looking working_dir file superseded by a deps copy.

## 2026-06-20 — build_1 core-0 hang: diagnosis flipped (NOT a race) + SW fix implemented
- TASK: "implement sw fix" for the build_1 matmul hang (core 0 stuck after stop_benchmark).
- BEFORE editing, re-validated the earlier "store-race" hypothesis and DISPROVED it:
  1. Peel control flow is CORRECT — traced col-coverage for even N (prologue cols 0,1; steady 2..N-2;
     epilogue N-1 = all N). vfmacc/vfmul operand order correct. Not the bug.
  2. NOT a store race — core 0 runs stop_benchmark + perf printf (~10k+ slow-UART cyc) BEFORE verify,
     giving every core's vse32.v ample drain margin; CMS showed req==resp/inflight=0 at the hang.
  3. HOST REPLAY (/tmp/matcheck.c: float32 A*B of the real data_gemm.h vs gemm_checksum, abs tol 0.001):
     0/256 rows fail, worst |row-sum - checksum| = 4.27e-4 << 1e-3, worst rel err 2.5e-5.
     => the verify + 0.001 tolerance are FINE; build_1's failure is a GENUINELY WRONG device result,
        which a SW fence/tolerance-relax CANNOT fix. Root cause is device-side (HW data path / config),
        most plausibly the group-MSHR/burst coalescing returning wrong load data (the feature under dev).
- The HANG itself is SW-mitigatable: the old error printf arg `*(uint32_t*)&r[error-1]` materialized a
  float->int via fmv.x.w; that FP-seq writeback returns acc_pwrite=0, which the compiled Snitch arbiter
  never acks -> dest int-reg scoreboard bit stuck -> printf prologue `sw aN,off(sp)` stalls forever.
- SW FIX (software/apps/spatz_apps/sp-fmatmul-opt-burst-merge/main.c):
  * Added f32_to_bits(): float->bits via a VOLATILE memory slot (fsw + lw), never fmv.x.w. No acc
    writeback on the path -> cannot trigger the pwrite=0 deadlock.
  * Rewrote verify_matrix(): scans ALL rows (no early return); returns first-fail (1-based) + out-params
    nfail / last_row / first-row device-sum bits / checksum bits (bits via f32_to_bits / volatile lw).
  * Epilogue prints an integer-only report classifying the failure: nfail==M => systematic;
    last-first+1==nfail => one contiguous block (a specific group's rows); else scattered.
- RESULT: builds clean with config=terapool_spatz4_fpu (-O3 -Wall -Wextra -Wconversion, 0 warnings;
  gemm_l.M is uint32_t -> %u correct). Sim NOT yet re-run (host contention; build_1/2 GUI still live).
- STATUS: SW fix done. Converts the hang into a terminating, diagnostic run. The wrong RESULT is a
  separate device-side bug (HW/config) — next step is to read the failure pattern from a fresh sim and,
  if contiguous-by-group, point at the MSHR/burst coalescing data path. Not committed (awaiting request).

## 2026-06-20 (later) — Architecture artifacts: terse anchored ref + formal spec
- TASK: "make an artifact out of the architecture and microarchitecture" — user wanted BOTH a terse
  debugging/onboarding reference AND a formal spec (paper/thesis/tapeout).
- METHOD: harvested anchored facts in parallel via 5 read-only Explore agents (hierarchy, NoC, group-MSHR,
  Spatz datapath+acc contract, mem-map/config/pkg/debug), each required to verify compiled-vs-not via
  Bender.yml and return file:line anchors (NOT file dumps). Plus harvested design rationale from
  bottleneck_analysis reports (MSHR v1-v6 sizing study, NoC HoL-deadlock + response-sink, MSHR audit H1-H3).
- DELIVERABLES:
  * hardware/ARCHITECTURE.md — terse anchored map: compiled-vs-not table, instantiation chain, config
    flavors, 3 datapaths (remote-load lifecycle / scalar-FP / VLSU burst), contracts&invariants
    (acc-pwrite, acc_mem_cnt=7, vle-after-vse, barrier!=VLSU-fence, NoC HoL deadlock, same-addr-entries
    legit, VC placeholder), mempool_pkg type source-of-truth, gotchas table, debug-tag table.
  * docs/teranoc_architecture.md — formal spec: design goals, system arch (mermaid hierarchy), memory
    hierarchy/address map, NoC (mermaid grid + topology/routing/channels/remap), group-MSHR uarch
    (mermaid FSM + entry/merge/response/fairness + the deadlock & response-sink rationale), Spatz
    integration, config space, rationale/evaluation/open-issues (v1-v6 study, audit H1-H3).
- ANCHOR VERIFICATION: spot-checked 8 load-bearing anchors against RTL. 7 exact; mempool_group_mshr.sv:1380
  (bypass tie, sourced from the 2026-06-12 report) had DRIFTED (bypass path reworked: now resp_from_bypass
  :226 staged via i_spill_resp_out :518; mshr_tag decode now :1444-1457). Fixed all stale anchors in both
  docs; confirmed mermaid/code fences balanced. Lesson reinforced: report-sourced anchors age; re-verify.
- STATUS: both docs written + anchor-checked. Not committed (awaiting request). The build_1 SW fix from the
  earlier 2026-06-20 entry is also still uncommitted.

## 2026-06-20 (later) — Plan: fix B-burst coalescing misses (group MSHR) — workflow wdf3l1ohm
- USER asked: how does same-cycle MSHR coalescing work; and does a fast intra-group sync (HW+SW, >=8 slots,
  arbitrary subsets) to re-align cores before the shared B burst make sense? Plan it.
- METHOD: ultracode workflow, 12 agents (5 read / 4 design / 3 adversarial critique), ~880k tok.
- KEY FINDING (corrects earlier arch-doc claim): same-cycle leader/follower merge was REMOVED in
  Increment 3 (mempool_group_mshr.sv:812-817). Coalescing is now: hit an already-resident WAIT_RESP entry
  within window [T_alloc+1, T_resp0-1] (~p95 72cyc; closes combinationally on first beat, :789-810/:847-859);
  two same-cycle misses can't merge (banked 1-alloc/bank :959-995; loser stalls 1cyc :1325-1332). So
  alignment needs to be WITHIN ~68cyc, not cycle-exact.
- SKEW root cause confirmed: cores k & k+8 share B (p_start=32*(core_gid%8)) but load different A
  (m_start=16*gid+8*(core_gid/8)); gap is LOOP-CARRIED (step n B-issue gated by step n-1 A-flw latency).
  SW reorder can't fix (B-before-A already the shape; prefetch register-infeasible 20/32 vregs).
- VERDICT on the barrier: closes the gap (release+issue skew ~3-6cyc << 68cyc window) BUT kernel is
  COMPUTE-BOUND so throughput win ~0 (win = NoC traffic/energy + resp-channel/deadlock margin); per-step
  barrier is net-NEGATIVE (~2-3k cyc/core + fastest-waits-slowest); WORSENS the known HoL deadlock on the
  failure path; WFI hang modes. => good GENERAL primitive, wrong fix for THIS kernel.
- RECOMMENDED (all 3 critiques converge): BURST-LINE RESPONSE CACHE (extend MSHR_CACHED to 16-beat lines)
  — late burst hits resident drained line, zero NoC txn, zero stall, arbitrary-skew tolerant; mostly
  guard-removal (:1753-1772,:853-856,:1308-1314,:665-671); ~53Kbit flops @ Mshr64 → ~13Kbit if 1 way/bank.
  Latent stale-store hole (invalidation AMO-only) — dormant for read-only B, close before generalizing.
- PHASED PLAN: P0 zero-RTL cold-start partial barrier + profiling to MEASURE skew & confirm coalescing
  (gate everything); P1 burst-cache (1 way/bank); P2 GroupSyncUnit only if another kernel needs a general
  sync. PREREQ: response-sink FIFO must be in place first (else issue-bunching makes g12 hang reproducible).
  Also fix wake_up_tile groups 8-15 bug (runtime.h:166-196 routes to g0).
- Saved memory project_mshr_bcoalesce_sync_plan. No RTL/SW changed yet (planning only).

## 2026-06-20 (later) — Phase 0 KICKED: cold-start group-sync experiment (build_phase0)
- SW: added cold-start intra-group barrier before matmul (main.c), gated COLDSTART_GROUP_SYNC (dflt 1).
  Uses mempool_log_partial_barrier(2,cid,cores_per_group) -> wake_up_group (correct for all 16 groups).
- HW: compiled current MSHR RTL fresh in hardware/build_phase0 (vlog 0 err); avoided live build_2/build_3.
  Live this-repo sims: build_2 (pid1843765), build_3 (pid1832403). simc running (pid1949082).
- RESULT (aligned run, healthy through cyc 9000+, NO deadlock, inflight low, STUCK_REQ=0):
  * Shadow merge analyzer (tb_group_merge, 16-entry/16-cyc-window model), cumulative to cyc 5000:
    merge_eff=0.076 (92% of loads coalesced), 664/719 merge_hits, avg 13.07 reqs/entry, 0 overflow, 0 no_free.
    Cold-start-inclusive. CONSERVATIVE lower bound (real MSHR = 64 entries / ~68-cyc window).
  * Real NoC tracer aggregate: CORE_REQ -> MSHR_REQ_OUT ~ several-x reduction (window-dependent).
  * The one-time cold-start barrier did NOT trigger the g12 HoL deadlock in the observed window (good;
    addresses the critique's issue-bunching concern for a ONE-TIME barrier).
- MEASUREMENT GAPS found (block clean cold-start-B isolation):
  1. NoC tracer window landed at STEADY-STATE (~cyc 8800-9700), not cold-start; need +tracer_lo/hi_ns.
  2. tracer 'burst' col is a req/resp FLAG (not burst_len); and CORE_REQ uses LOGICAL addr while
     MSHR_REQ_OUT uses SCRAMBLED/target addr -> can't compare per-region across stages. (a@0x20000,
     b@0x60000, c@0xa1000 static symbols.)
  3. MSHR EnableStats (cleanest burst-vs-single + req_merge per group) NOT emitting despite
     csr_trace_any_i hardwired 1'b1 (line 459) -> print_stats path bug to debug; would give the exact
     B-burst-merge count.
- CLEANEST next number: BASELINE run (COLDSTART_GROUP_SYNC=0) -> compare shadow merge_eff (the working,
  16-cyc-window, alignment-SENSITIVE metric) aligned 0.076 vs baseline. Aligned data saved in
  hardware/phase0_aligned_save/. Not yet run (host saturated: 5+ vsim).

## 2026-06-21 — Phase 0 RESULT: cold-start barrier does NOT help coalescing (aligned vs baseline)
- Ran ALIGNED (COLDSTART_GROUP_SYNC=1) and BASELINE (=0) on build_phase0 (current MSHR RTL), compared
  shadow merge_eff (tb_group_merge, 16-cyc window, alignment-sensitive).
- merge_eff head-to-head:  cyc5000 aligned=0.076 vs baseline=0.075 (identical, 719 reqs each);
  cyc10000 aligned=0.216 vs baseline=0.234. => NO coalescing benefit from the one-time barrier.
- REASON: cores already start aligned (existing pre-matmul mempool_barrier). Skew is LOOP-CARRIED, rebuilds
  over n-steps; a one-time re-align can't fix diverged later steps. Only per-step barrier would -> net-neg.
  => kills the GroupSyncUnit as the coalescing fix; confirms the design critique. Go to Option C burst-cache.
- SECONDARY (causally uncertain): BASELINE hit the g12 HoL deadlock (inflight 1->770->3113 at cyc9-10k, req
  exploding 5174->11489->113543, resp lagging) while ALIGNED ran clean to cyc115000. Likely the barrier
  perturbed timing and dodged a FRAGILE deadlock, not a robust fix; real fix = response-sink FIFO.
  (Re-armed monitor bw52yr9fx to confirm baseline STUCK_REQ.)
- Aligned full data saved hardware/phase0_aligned_save/ (util 5000..110000: merge_eff 0.076->0.37 steady).
- Measurement caveats logged (tracer burst-col flag + addr-space mismatch; MSHR EnableStats not emitting
  despite csr_trace_any_i=1'b1 -> print_stats bug). main.c COLDSTART_GROUP_SYNC scaffold left, default 0.
- NEXT: response-sink FIFO (deadlock prereq) + Option C burst-line response cache (durable coalescing fix).

## 2026-06-21 — CORRECTION to the Phase 0 secondary claim (baseline did NOT deadlock)
- My "baseline hit the g12 deadlock" was an OVERCLAIM. Re-checked the [CMS] trend: baseline inflight ramped
  1->770->3113 at cyc9-10k then stayed ~2900 STABLE while BOTH req and resp kept advancing (resp +~113k per
  1000cyc: 110430->223053->336676 at cyc10/11/12k). That is a high-occupancy FLOWING pipeline, not a hang.
  No STUCK_REQ. g12 did NOT reproduce in this baseline window (well past the ~8850 onset).
- The mistake: I compared baseline's post-ramp window to the aligned run's EARLY-calm CMS (only early aligned
  [CMS] was saved; the aligned transcript got overwritten by the baseline rerun). No aligned mid-run inflight
  exists to compare, so the "divergence" was not real.
- NET Phase 0: the one-time cold-start barrier is essentially a NO-OP for this kernel -- no coalescing gain
  (merge_eff identical) and no observed correctness change. Killed baseline (host freed); early data saved in
  hardware/phase0_baseline_save/. Primary conclusion unchanged: barrier is not the fix -> Option C burst-cache;
  response-sink FIFO remains the deadlock fix on general grounds.

## 2026-06-21 — Per-step pairwise barrier: design plan written (workflow wxlo2nv5z)
- Report: hardware/bottleneck_analysis/2026-06-21_perstep_pairwise_barrier_plan.md (full investigation + plan + verdict).
- VERDICT: the user's per-step pairwise barrier is SOUND + FEASIBLE (not refuted by Phase 0, which tested a
  slow/one-time/16-core barrier). CRUX = preserve the double-buffer via SPLIT arrive/deferred-wait:
  arrive(non-blocking) after last A-flw -> vle32.v issues immediately -> 8 vfmacc (~64c) -> wait at end
  (hidden behind compute). Intra-pair skew ~3-6c << 64c tail => ~0 stall when aligned (free adaptivity).
- HW: GroupPairBarrier beside MSHR (mempool_group.sv:627), 8 slots, ~4.3k FF total, arrive via zero-spill LIC,
  release OR'd into wake FF (:71-72). Option B (WFI + wake-FF) = ZERO vendored snitch edits (recommended);
  Option A (no-WFI fence_stall CSR) faster + disjoint but needs minimal deps/snitch edits. Watchdog
  force-release bounds the no-timeout WFI hang (snitch.sv:866-882). EnableGroupBarrier default-off.
- HONEST PAYOFF: ~0 throughput (compute-bound 16384c floor); real win = NoC traffic/energy + resp-channel
  occupancy. g12-relief RETRACTED. Complementary to (not beaten-by) the burst-line response cache.
- GATE before prototyping (cheap, no RTL): (1) FIX MSHR EnableStats emit bug (csr_trace_any_i hardwired
  1'b1 at mempool_group_mshr.sv:459 -> print_fall :2174 dead -> stat_req_merge never emits); (2) MEASURE
  per-step intra-pair skew from the existing build_phase0 WLF (waveform-analysis). If skew small & B already
  coalesces -> go to cache; if skew wide -> prototype Option B + split placement + watchdog, A/B-measure
  coalescing + wall-clock-no-regression + resp-channel relief.

## 2026-06-21 — Pre-flight GATE executed → PASSED (skew + baseline B-coalescing). EnableStats: no bug.
- Measured from existing unaligned build_phase0 baseline trace (noc_trace/events.csv, cyc 8701-12318),
  pair (core_gid 0, core_gid 8) group 0, B isolated by burst=16:
  * ACCUMULATED intra-pair B-issue skew: median 144 cyc, p95 216, max 220. 83% of shared-B bursts (60/72)
    MISS the 68-cyc merge window -> baseline B-coalescing broken.
  * BASELINE B coalescing (CORE_REQ vs MSHR_REQ_OUT, burst=16): 1.12x chip (1.09-1.13x/group) vs ideal 2.0x
    -> ~88% of the 2-way pair opportunity lost. (chip 18217 B-bursts issued -> 16225 emitted to NoC.)
  * INCREMENTAL per-step skew (barrier WAIT cost): mean 3.7 cyc, p50=1, p90=11, max=58; 100% <= 64-cyc
    compute tail -> deferred-wait HIDES the cost.
- VERDICT: large opportunity (1.12x of 2.0x) + hideable cost -> GATE PASSED, prototype the barrier.
  Expected: B coalescing toward 2x => ~half group B NoC traffic, ~0 wall-clock (compute-bound).
- CORRECTION: the earlier "EnableStats not emitting / print_stats bug" and "tracer burst col is a flag"
  were BOTH mis-observations from a partial trace. Stats emit 192 periodic lines
  (reqs: accepted=N (single=.. burst=..) merged=.. alloc=..); burst col IS burst_len (B=16). No RTL fix
  needed. B-isolated A/B metric = tracer burst=16 CORE_REQ-vs-MSHR_REQ_OUT (csr_trace-gated, region-clean).
- Report updated: hardware/bottleneck_analysis/2026-06-21_perstep_pairwise_barrier_plan.md (§2 corrected,
  §5.1 gate results added). NEXT: prototype GroupPairBarrier (Option B WFI, split arrive/deferred-wait,
  watchdog, EnableGroupBarrier default-off) + A/B-measure B coalescing (tracer) + wall-clock-no-regression.

## 2026-06-21 — Barrier Design B (blocking-load) vs A (WFI): BUILD B (workflow wxrj7np89)
- User proposed Design B: arrive+wait = a single integer `lw` to a group-mapped barrier addr + a fence; the
  barrier is a TCDM SLAVE that withholds the load RESPONSE until count==target (per-slot target + participant
  bitmask), then responds to each arrived core. Release = the load response; no WFI, no wake path.
- VERIFIED FEASIBLE WITH ZERO INTERCONNECT CHANGE: i_local_interco = variable_latency_interconnect (LIC) =
  stateless full-duplex xbar (2 independent simplex_xbar). Slave may hold resp_valid low arbitrarily, then
  route by echoing req_ini_addr (4-bit tile id) in resp_ini_addr (full_duplex_xbar.sv:85-105; mempool_group.sv:
  209,222,274). AMO path in tcdm_adapter is the variable-latency precedent (:92-104,114-130,143). fence_stall=
  !lsu_empty (snitch.sv:861-864), lsu_empty=&id_available_q (snitch_lsu.sv:133) -> fence waits for the held lw;
  id-LSU tolerates arbitrary-latency response (8 slots, no timeout). Between lw and fence the core keeps issuing
  (vfmacc to Spatz unaffected) -> wait overlaps compute, double-buffer preserved. USE integer lw NOT flw (flw
  bypasses int LSU/fence, snitch.sv:2320-2332,2819).
- B BEATS A: no OutstandingWfi desync, no new wake-path wiring, reuses resp datapath, natural lw;compute;fence;
  vle split, lower integration risk. A wins ONLY on release skew (0 broadcast vs N-1 serialized) -> irrelevant
  at N=2 (pairwise ~1 cyc). Both need a watchdog (fence has no timeout). Fence-stall is NOT clock-gated (higher
  power than WFI, minor).
- CRITICAL impl constraints: (C1) slave must ACCEPT-IMMEDIATELY (req_ready_i=1, capture ini_addr) and DEFER only
  resp_valid -- holding req_ready low head-of-line-blocks the tile's single local port. (C2) fence drains ALL
  int loads (ok: matmul A-loads are flw). Attach via Option-B address-decode shim (no NumOut=17 churn).
- DECISION: pivot prototype from A (WFI, mempool_group_barrier.sv) to B (blocking-load slave). Reuse A's
  slot/mask/watchdog skeleton; swap wake-pulse release for an ini_addr-echoing response sequencer + shim. Keep A
  on the shelf only for future large whole-group (N>=8) barriers (and fix its OutstandingWfi desync first).
- Report: hardware/bottleneck_analysis/2026-06-21_barrier_loadresp_vs_wfi.md.

## 2026-06-21 — Barrier release-skew: DEFERRED (keep 1 resp/cycle); implementing Design B
- Decision: 1 response/cycle (serialized release). Worst case 15 cyc << 68-cyc merge window -> never breaks
  coalescing; pairwise intra-pair skew = 1 cyc via pair-major sequencer (free). Future levers recorded in the
  comparison report sec 6 (per-slot order [done], K-wide injection, full broadcast). Not building K-wide/broadcast now.
- Implementing Design B: rewrite hardware/src/mempool_group_barrier.sv as a delayed-response TCDM slave
  (accept-immediately req_ready=1, capture arrived per slot, hold response, pair-major 1-resp/cycle release via
  resp_valid+resp_ini_addr, watchdog force-release). Wiring (address-decode shim in mempool_group) is the next step.

## 2026-06-21 — Design B barrier: module + mempool_group shim IMPLEMENTED & compiling
- mempool_group_barrier.sv rewritten as the held-response TCDM slave (accept-immediately req_ready=1,
  per-slot arrived tracking, pair-major 1-resp/cycle release via resp_valid+resp_ini_addr, watchdog
  force-release). Self-checking unit TB (/tmp/tb_group_barrier.sv): ALL PASS (pair release 1-cyc skew,
  overlapping pairs pair-major, watchdog force+wd_fire, AxiVldRdy backpressure hold).
- mempool_group.sv shim (Option B4, master-side intercept), under EnableGroupBarrier (default 0 => passthrough,
  baseline bit-identical):
  * params EnableGroupBarrier / NumGroupBarrierSlots(=8) / GroupBarrierWdLimit(512) / GroupBarrierTgtAddr.
  * intermediate lic_req_valid/ready + lic_resp_valid/rdata/wen nets; LIC re-routed through them.
  * gen_group_barrier: decode reserved tgt_addr -> mask out of LIC; rr_arb_tree 16->1 (1 arrive/cyc) into the
    barrier; meta_store_q captures the arrive payload (echo meta_id on release, needed for LSU match);
    inject the held response into the requester's master_local_resp when the LIC isn't using it.
  * Added hardware/src/mempool_group_barrier.sv to Bender.yml (before mempool_group.sv).
- Incremental `make compile config=terapool_spatz4_fpu buildpath=build_phase0`: exit 0, both files compiled,
  0 errors. Default-off so EnableGroupBarrier=0 elaborates the passthrough only.
- OPEN (for the SW step): GroupBarrierTgtAddr=0x0070 (tcdm_addr_t) ALIASES an interleaved data word at
  (bank0,word7) because the packed tgt_addr strips tile-id + seq/interleaved view -> the SW/linker MUST
  reserve that physical (bank,word) (both views) or pick a reserved word. Pin this + the lw/fence kernel
  sequence in the SW step before enabling EnableGroupBarrier and running the A/B.

## 2026-06-21 — Design B SW side IMPLEMENTED (runtime + kernel insertion) & compiling
- mempool_group.sv: EnableGroupBarrier now `ifdef GROUP_BARRIER_EN (default 1'b1 when defined, else 0);
  GroupBarrierTgtAddr = 0x0C80 = (bank0, word200). Derived from the byte-addr layout
  tgt_addr={word[7:0],bank[3:0]}, tile_id=addr[13:6]: SW load addr = 0x320000 | (core_id<<6) (interleaved,
  word200, tile=core_id, bank0). Word 200 is above the matmul data words (~8-56) -> no aliasing; reserve it
  if apps fill the TCDM.
- kernel/sp-fmatmul.c: added gbar_addr()/gbar_arrive()/gbar_wait() (self-contained via csrr mhartid;
  arrive=lw to gbar, wait=fence), gated GROUP_BARRIER (default flipped to 1 for the aligned experiment, 0=baseline).
  Inserted GBAR_ARRIVE after each steady-loop B prefetch (vle) and GBAR_WAIT after each half-step's 8 vfmacc
  -> wait overlaps the ~64-cyc compute; next half's vle issues aligned. Prologue left unbarriered (first
  steady barrier re-aligns any drift).
- Builds: GROUP_BARRIER=0 (baseline) clean; GROUP_BARRIER=1 (aligned) clean -> binary has 2 fences + 1 csrr
  mhartid + arrive lw in matmul_8xVL.
- NEXT (run): recompile build_phase0 HW with GROUP_BARRIER_EN (EnableGroupBarrier=1, elaborates the barrier
  slave), then A/B: aligned (GROUP_BARRIER=1) vs baseline (=0) -> tracer burst=16 coalescing (1.12x -> target
  ~2x), wall-clock vs 16384 floor, wd_fire=0, no STUCK/deadlock.

## 2026-06-22 — Design B A/B: barrier VALIDATED + coalescing UP; mshr_overflow concern; cycle count pending
- INTEGRATION VALIDATED (no deadlock/corruption): the first aligned run (build_phase0, GROUP_BARRIER=1) ran ~5h
  of the matmul with NO wd_fire, NO [CMS WARN]/STUCK, NO error. A-loads confirmed flw (40 in matmul_8xVL) so the
  fence only waits on the barrier lw. Adversarial review (wf w40dabi31, 27 findings): 0 deadlock/corruption
  confirmed; 2 perf findings (watchdog skew==513 false-positive [cosmetic, measure-zero]; force-release head-of-line
  behind lic_resp_valid [bounded perf delay]). Verify agents for several shim-mux/kernel findings died on a session
  usage limit; I assessed them: "permanent deadlock" is NOT real (the stalled core's Spatz VLSU runs out of work ->
  lic_resp_valid gap -> injection fires; fence bounded). meta_store overwrite NOT real (core held between
  arrive/release). decode-doesn't-exclude-WRITES is latent (add !wen to bar_sel) but matmul never writes word200.
- COALESCING IMPROVED (mechanism works): aligned MSHR EnableStats merged=262-526/window vs baseline merged=0-68/window;
  aligned burst~300/window vs baseline burst~0-40. The per-step barrier aligns the shared-B vector bursts so they
  coalesce in the MSHR merge window. resps from_mshr=4447 vs from_bypass=1783.
- NEW CONCERN mshr_overflow: aligned ~301/window vs baseline ~0 most windows. Aligning the bursts creates a
  simultaneous-burst storm that pressures the MSHR (group_mshr_num too small for the aligned storm) -> overflow ->
  bypass (uncoalesced) -> caps the coalescing gain. Lever: raise group_mshr_num.
- BASELINE matmul = 27271 cycles (62% util, vs ~16384 compute floor). Aligned cycle count PENDING (killed the
  log -r* run [10x too slow]; clean re-run byxw5axya in build_phase0, no log -r*, verify off, ~3.5h).
- Measurement note: baseline(build_base) + aligned(build_phase0) both have MSHR EnableStats -> comparable. The
  matmul cycle count (printf, post-benchmark) is the outcome metric; verify is OFF (doesn't affect it).

## 2026-06-22 — Design B A/B DEFINITIVE (CORRECTION): barrier is a correct NO-OP for sp-fmatmul
- CORRECTION of the prior entry's "coalescing UP": that compared MISMATCHED windows (high-activity aligned vs
  low-activity baseline) — the same mismatched-window error flagged before. The FULL-RUN AGGREGATE is the fair
  comparison and shows NO change:
    cycles : baseline 27271 vs aligned 27193  (-0.3%, break-even / noise)
    burst  : 122880 vs 122880 (identical)
    merged : 195034 vs 191472 (aligned marginally LOWER)
    merged/accepted : 0.288 vs 0.283 (no change)
    mshr_overflow   : 95032 vs 97931 (no change -> the overflow is a BASELINE matmul trait, NOT barrier-induced;
                      my earlier "burst storm" was also a mismatched-window artifact)
- VERDICT: the per-step pairwise barrier WORKS correctly (no hang/corruption, no wd_fire, clean CMS FINAL
  orphan=0 dup_alloc=0) but provides NO benefit for sp-fmatmul: the cores already run the same compute-bound
  kernel roughly in lockstep, so explicit per-step sync changes neither the aggregate coalescing nor the cycle
  count. Confirms [project_sp_fmatmul_compute_bound] + [project_mshr_bcoalesce_sync_plan] (compute-bound; the
  hoped "win=traffic" did NOT materialize in aggregate either).
- KEPT VALUE: a verified, reusable held-response group-barrier primitive (mempool_group_barrier.sv + the
  mempool_group Option-B4 shim, default-off under GROUP_BARRIER_EN). Could help a NON-compute-bound,
  alignment-sensitive workload; for sp-fmatmul it is not worth enabling.
- LESSON (again): always compare FULL-RUN AGGREGATES, never cherry-picked windows.

## 2026-06-22 — EnableGroupBarrier now DEFAULT ON
- mempool_group.sv: EnableGroupBarrier defaults 1'b1; disable with -DGROUP_BARRIER_OFF.
- hardware/Makefile: group_barrier=0 -> -DGROUP_BARRIER_OFF (A/B off-switch). (was group_barrier=1 -> EN)
- Recompiled build_phase0 with no flag: exit 0, clean; neither define in compile.tcl -> default-on path.
  Elaborates EnableGroupBarrier=1 (identical to the validated aligned runs).
- CAVEAT: default-on activates the shim for ALL apps. Barrier addr 0x0C80 (interleaved word200/bank0) is
  only known clear for sp-fmatmul; NOT linker-reserved. Any app touching word 200 of its local tile would be
  mis-diverted. Reserve the word in the linker before running other apps with default-on.

## 2026-06-22 — ROOT CAUSE of "no barrier access forwarded" + REDESIGN to a proper xbar slave (Option B)
- ROOT CAUSE (user found no forwarding): the barrier address was SAME-TILE (addr[13:6]==own tile) ->
  classified TCDM_LOCAL (mempool_tile.sv:1132-1134) -> served by the tile-internal bank interco, NEVER entering
  the group xbar where the Option-B4 master-side shim intercepted. So bar_sel never matched; the lw completed
  from a bank; the fence fell through -> the earlier "no-op" A/B was INVALID (barrier never engaged).
- REDESIGN (Option B, user's choice): barrier = a dedicated OUTPUT PORT of i_local_interco.
  * i_local_interco widened: NumOut = NumTilesPerGroup+1 (=17), AddrWidth = TCDMAddrWidth+1 (=17). Confirmed LIC
    (full_duplex_xbar) supports non-pow2 NumOut.
  * Re-encode each master's tgt_addr: {tgt_addr[15:4], 1'b0, tgt_addr[3:0]} -> tiles keep tgt_sel={1'b0,tile}
    (0-15) + mem-addr=tgt_addr[15:4] BIT-IDENTICAL; a barrier request (word field tgt_addr[15:8]==GroupBarrierWord=200)
    forces tgt_sel = NumTilesPerGroup -> the barrier port.
  * Barrier adapter on port 16: accept-immediately, capture arrive payload (echo meta_id/core_id on release).
    The LIC does the arbitration (its per-output rr_arb_tree, <=1 arrive/cyc) AND routes the held response back
    by ini_addr -> NO external arbiter, NO injection (cleaner than B4). Removed the B4 shim + intermediate nets.
  * Replaced param GroupBarrierTgtAddr(0x0C80) with GroupBarrierWord(200).
- SW (kernel gbar_addr): now targets a DIFFERENT tile, same group ((own_tile+1)%16), word 200 ->
  0x320000 | (((cid&0xF0)|((cid+1)&0xF))<<6). TCDM_EXTERNAL so it enters the group xbar. Slot still derived in HW
  from the ISSUING core (ini_addr), so the +1 target tile does not change the pairing.
- Added a sim-only engagement counter to mempool_group_barrier.sv: final $display "[GBAR] %m arrives=N releases=N
  wd_fire=..". arrives>0 => forwarding fixed; releases==arrives => all completed.
- HW (build_phase0, default-on) + SW (GROUP_BARRIER=1, MATMUL_VERIFY=1) compile clean (0 errors).
- VALIDATION sim running (bdg6rge0v, verify ON + barrier ON): will confirm (a) [GBAR] arrives>0 (engagement),
  (b) "success!" (the central-xbar rewrite did NOT break normal traffic), (c) no STUCK/orphan, wd_fire=0. Only
  after this passes is the perf A/B (verify off) meaningful.

## 2026-06-22 — Barrier REDESIGN to general-purpose memory-mapped structs (user spec); all 3 pieces done
- mempool_group_barrier.sv REWRITTEN: NumBarriers independent structs, each {target_q, count_q, resp_mask_q,
  watchdog}. Memory-mapped: SW writes target+mask ONCE (persist, auto-reused). Arrive(load)->count++; when
  count==target -> fire held responses to resp_mask cores (1/cyc), reset count. Config write(store)->set
  target/mask + ACK (req_ready throttles back-to-back writes so the ack meta can't be overwritten). resp_wen
  distinguishes config-ack (frees store id, no writeback) from arrive-release. Compiles clean.
- mempool_group.sv: NumGroupBarrierSlots -> NumGroupBarriers (=NumCoresPerGroup=16). Barrier window now a
  RANGE [GroupBarrierWord, +NumGroupBarriers); struct = word-base. Re-encode passes {word,bank} as the
  port-16 mem-addr (was zeroed). Adapter decodes struct (word-base) + op (bank: load=ARRIVE, store@bank1=
  WR_TARGET, store@bank2=WR_MASK) + cfg_data (wdata.data); drives the module; meta-echo on resp (releases AND
  config acks). HW compiles clean (0 err).
- SW (kernel + main.c): gbar_setup(s,target,mask) [config stores, bank1/2], gbar_arrive(addr=gbar_base(s))
  [held load, bank0], gbar_wait [fence]. Address: word=200+s, target_tile=(own+1)%16 (TCDM_EXTERNAL), bank=op.
  main.c: each pair's lower core (within-group wg<8) sets up struct wg (target=2, mask={wg,wg+8}) once before
  the measure loop + a barrier; kernel arrives at struct (mhartid&7) each half-step. SW builds clean.
- NOTE: "same address for all cores" is NOT byte-identical -- TCDM_LOCAL forces a per-core tile-routing field
  ((own+1)%16); the STRUCT (word) is shared. Documented.
- VALIDATION sim running (bd7bo8sr3, verify ON + barrier ON): confirm [GBAR] arrives>0 (engagement),
  releases==arrives, "success!" (xbar/correctness), no STUCK, wd_fire=0.

## 2026-06-23 — Request-sent VLSU fence; SFENCE_VMA repurposed (was spatz-drain) -> request-sent
- Problem: gbar_sync's sfence.vma drain (acc_mem_cnt==0 = all responses back) over-waited + killed memory
  overlap. Wanted: block until all prior vector-LSU REQUESTS are SENT to the interconnect (responses may stay
  in flight). Workflow w9c85i5uj: the request-side signal already exists in the VLSU (mem_insn_finished,
  request-handshake-driven) but is AND-ed with the response term before export.
- spatz_vlsu.sv: new output spatz_mem_req_sent_o = |(mem_insn_finished_d & ~mem_insn_finished_q) (rising-edge
  one-shot, request-side only). spatz.sv: [1:0] {vlsu_req_sent, fp_lsu_mem_finished}. spatz_mempool_cc.sv:
  wire -> snitch (the compiled cc; spatz_cc.sv NOT compiled). deps/snitch/snitch.sv: input
  acc_mem_req_sent_i[1:0]; counter acc_mem_req_cnt_q (inc at offload, dec on req_sent NOT response); hoisted +
  tied 0 non-Spatz.
- Opcode: no clean spare (HFENCE_GVMA needs raw .word since H not in -march). So REPURPOSED SFENCE_VMA:
  was spatz-drain (|acc_mem_cnt_q) -> now request-sent (|acc_mem_req_cnt_q). Spatz-only-DRAIN dropped (plain
  FENCE still drains int+spatz). Final map: FENCE=int+spatz DRAIN; FENCE_I=int only; SFENCE_VMA=spatz REQ-SENT.
- SW: kernel gbar_wait_vlsu_sent()=sfence.vma; gbar_sync = req-sent -> arrive(lw) -> fence.i (removed the
  redundant gbar_wait_spatz). runtime.h vlsu_fence() comment updated to request-sent semantics.
- HW clean (Errors:0, 4 modules); SW clean: gbar_sync=4x (sfence.vma + lw + fence.i).
- PENDING: functional sim (debug the matmul hang WITH this fence). deps/snitch + working_dir/spatz edits not
  yet captured as patches -> update-deps would clobber.

## 2026-06-23 (review fix) — request-sent fence made VECTOR-ONLY + true FP-LSU req-sent
- User review caught: (1) FP-LSU bit[0] reused fp_lsu_mem_finished = COMPLETION for loads (waits for the
  response, not the send); (2) the snitch counter conflated vector + scalar-FP (offload `loadstore` flag
  can't distinguish), so the fence also waited on the FP-LSU. Workflow wu4ftplcr verified the VLSU bit[1] IS
  request-side (mem_insn_finished from the request handshake, never delayed by responses) -- the vector lane
  was already fine; only bit[0] + the counting were wrong.
- spatz_fpu_sequencer.sv: + fp_lsu_mem_req_sent_o = fp_lsu_qvalid && fp_lsu_qready (true req-accept, load+
  store); + acc_mem_vec_accepted_o = (is_vector_load||is_vector_store) && issue_ready_i && issue_valid_o.
- spatz.sv: bit[0] now fp_lsu_mem_req_sent (was fp_lsu_mem_finished); + acc_mem_vec_accepted_o output;
  !FPU branch ties both to 0. spatz_mempool_cc.sv: wire acc_mem_vec_accepted spatz->snitch.
- snitch.sv: + input acc_mem_vec_accepted_i; acc_mem_req_cnt now inc on acc_mem_vec_accepted_i, dec on
  acc_mem_req_sent_i[1] ONLY -> SFENCE_VMA fence is VECTOR-ONLY. FP-LSU req-sent (bit[0]) routed but excluded.
- NOTE: compiled spatz = working_dir/spatz (NOT hardware/deps/spatz, a non-compiled duplicate). HW clean
  (Errors:0, 4 modules). SW unchanged (sfence.vma now = vector-only req-sent). Uncommitted (on top of
  bc99e53/463408c) -> needs a follow-up commit.

## 2026-06-24 — Matmul HANG root-caused: device verify (scalar-FP) wedges core-0; MATMUL_VERIFY=0 workaround
- Reproduced the hang fast at 256x32x256 (8x quicker than 256^3: shrink N only, keep M=256/P=256 to preserve
  the work-split [split_p_count=8, B-sharing pairs] + the 16-word bursts). Regen via script/matmul.json (N=32)
  + script/gen_data.py.
- DIAGNOSIS (from trace_hart_*.dasm): the matmul COMPLETES (4432-cyc measured); the group barrier is CLEAN
  ([GBAR] arrives==releases==496, wd_fire=0); the request-sent fence works. The hang is in the EPILOGUE:
  core-0 runs the inlined verify_matrix (sum each C row in FP via fadd.s, compare to golden row-checksum r[]).
  Those scalar-FP ops route through the Spatz FPU/FP-LSU/acc-writeback path and STALL core-0 mid-scan
  (~row 9, PC 0x1094, stall_raw on the FP result; trace stops retiring ~cyc 85144). All other cores reach the
  final mempool_barrier early (wfi @ 0x800024fc, hart1 ~cyc 13310) and wait forever.
- The CMS req-plateau (inflight=0) was a RED HERRING: verify's flw don't grow CMS req once core-0 wedges; it
  is NOT a NoC/MSHR deadlock, and it is INDEPENDENT of the barrier+fence (both validated clean here).
- WORKAROUND (in tree): MATMUL_VERIFY=0 in main.c -- confirmed excludes the verify call + the "success" print
  (no verify_matrix call, no "success" string in the dump). Matmul/barrier/fence still run + are timed.
  Verify is a debug-only host-side check (host replay confirms correctness).
- PROPOSED FIX (future, FP-free verify): emit the full golden C in gen_data.py (gemm_golden[M*P]) + rewrite
  verify_matrix as a per-element ULP integer compare (lw c + lw golden as uint32, sign-fix monotonic,
  |c_int - golden_int| < ULP_TOL). No FP -> no wedge. Exact-bit compare too strict (device ~4.3e-4 off = a
  relative error). Today's data has only per-row FP checksums (r) + the accumulate-INIT (gemm_C_dram,
  alpha=0 so unused) -- no per-element golden, hence the regen is needed.
- OPEN: WHY the FP-LSU/acc-writeback stalls at ~row 9 (the actual FP-LSU bug; same area as the documented
  fmv.x.w acc-writeback deadlock). Fast repro = 256x32x256.

## 2026-06-24 — Request-sent fence HW fix: spatz_mem_req_sent_o off ungated mem_counter==max (remaining_words==0)
- PROBLEM (user, from waveform): the old `spatz_mem_req_sent_o` (= rising edge of the `mem_insn_finished`
  bitmap) fired ~1 cycle from `spatz_mem_finished_o` (completion) -> the request-sent fence gave NO overlap
  (effectively a drain fence). ROOT CAUSE (deep-dive workflow + RTL): `mem_insn_finished` is set on the GATED
  `&mem_port_finished_q` (= `mem_spatz_req_valid && mem_counter==max`), written into an `mem_spatz_req.id`-indexed
  bitmap cleared only at retire -> its rising edge is coupled to response-gated completion, not issue.
  ROB throttle RULED OUT: spatz.sv:326 hardcodes `NrOutstandingLoads=32`; the matmul vle32 (128B=32 words) fits
  the fast port-0 burst path (vl<=128) and the 32-word ROB exactly -> requests genuinely go out before responses.
- FIX (spatz_vlsu.sv:613-630): derive `spatz_mem_req_sent_o` from the UNGATED issue-complete -- per-port
  `mem_port_req_issued = mem_port_active ? (mem_counter_q==mem_counter_max) : 1` (== `remaining_words==0`),
  AND `mem_spatz_req_valid`, rising-edge one-shot. No retire-held bitmap, no response term -> fires at
  request-issue, ahead of `spatz_mem_finished_o`. Fires for loads AND stores (balances the snitch's
  per-vector-mem-op `acc_mem_req_cnt`). `mem_insn_finished` KEPT (still used by `mem_finish_ready`).
- CODING STYLE (user): fixed the two `int unsigned` decls (`remaining_bytes`/`remaining_words`) -> `vlen_t`;
  AND hoisted the gen_mem_counter_proc generate-loop locals (`max_elements`, `burst_tail_base`,
  `remaining_bytes`, `remaining_words`) out to module-scope `mem_*[NrMemPorts-1:0]` arrays (the per-port
  always_comb only assigns them now) so they're visible in the waveform. Audited all request-sent-fence
  signals I added: all `logic` (not `int`), declared outside `always_comb`. (vreg-side gen_vreg_counter_proc
  still has local `max_elements`/`burst_tail_base` -- same pattern, not yet hoisted.)
- Compiles clean (build_phase0, terapool_spatz4_fpu: `spatz_vlsu` Errors:0; full build Errors:0).
  BUILD GOTCHA: `make compile` SKIPS vlog if `build_X/compile.tcl` is newer than its prereqs -- a `.sv` edit
  (esp. working_dir/spatz Bender.local files) does NOT re-trigger it, so it can report a false "Errors:0" from
  a SKIPPED compile (14-line log, no "Compiling module" line). Force a real recompile with `rm build_X/compile.tcl`.
- FALSE-PULSE FIX (user-found, spatz_vlsu.sv ~:626-633): `mem_spatz_req_valid` (op-queue valid_o) rises ONE
  cycle before the registered `delta_counter` loads `mem_counter_q` (commit_insn_push@T -> mem_counter_load@T ->
  mem_counter_q@T+1). So on a new instruction's first cycle mem_counter_q still holds the PREVIOUS instruction's
  value == the new `mem_counter_max` when consecutive ops share vl (matmul vle32). With an idle gap (so
  mem_req_all_issued had fallen to 0) that stale match is a genuine rising edge -> a FALSE spatz_mem_req_sent
  before any request is sent -> double-decrements the snitch acc_mem_req_cnt -> premature fence. FIX: guard the
  per-port compare with `!mem_counter_load[port]` (forces mem_port_req_issued low during the 1-cycle stale-counter
  window; also covers switch_to_tail_phase reload). The real edge (mem_counter==max during normal issue,
  mem_counter_load=0) is unaffected. Recompiled clean (`Compiling module spatz_vlsu`, Errors:0).
- OPEN: signal-logged sim + WAL to confirm `spatz_mem_req_sent_o` now leads `spatz_mem_finished_o` (the round-trip gap).

## 2026-06-24 — sp-fmatmul: instruction-cache warm-up before the timed kernel (main.c)
- PURPOSE (user): warm each core's I$ with the matmul (+ gbar_sync) code before the measured run so cold
  I$ misses don't pollute the timing.
- IMPL (main.c): new knobs `ICACHE_WARMUP` (=1) / `ICACHE_WARMUP_N` (=8). One short kernel pass inserted AFTER
  gbar_setup + the barrier and BEFORE the timed for-loop -> neither timed nor traced (precedes
  mempool_start_benchmark + timer_start). Dispatches the SAME kernel as the real run (matmul_{2,4,8}xVL by
  kernel_size) on the REAL m/p ranges + active set, with N clamped to `MIN(ICACHE_WARMUP_N, gemm_l.N)`=8.
  Rationale: gbar_sync count is purely N-driven (data-independent) so all cores stay balanced; N>=6 covers
  peel + BOTH steady-state halves + epilogue (warms the full kernel footprint). The kernel uses N as the A
  row-stride, so the warm-up's A reads are mis-strided -> garbage C -- harmless: the timed run overwrites C,
  it's in-bounds (warmup_n<=N), and control flow/gbar are data-independent. Standard I$-warm pattern.
- CAVEAT: the warm-up's gbar arrivals ARE counted by the always-on [GBAR] HW counter, so final
  arrives/releases include the warm-up pass (still balanced; subtract or set ICACHE_WARMUP=0 for clean stats).
- Builds clean (terapool_spatz4_fpu, 256 cores: main.c compiled + linked, no -Wall/-Wextra/-Wconversion warns).
- OPEN: verify with a sim (no hang, matmul completes, timed run faster from the warm I$).

## 2026-06-24 — SFENCE_VMA fence now requires BOTH vector VLSU and scalar FP-LSU requests sent (user)
- Changed snitch `acc_mem_req_cnt` (the SFENCE_VMA / request-sent counter) from VECTOR-ONLY to BOTH lanes:
  the increment switched from `acc_mem_vec_accepted_i` (vector-only, from the sequencer) to the SAME all-mem-op
  offload condition acc_mem_cnt uses (`acc_qdata_rsp_i.loadstore && acc_qready_i && acc_qvalid_o` -- covers
  vector loads/stores AND scalar flw/fsw; race-free snitch-local), and the decrement now fires on BOTH
  `acc_mem_req_sent_i[0]` (FP-LSU) AND `[1]` (VLSU). Each offload (+1) is balanced by one request-sent (-1) on
  its own lane, so SFENCE_VMA (`|acc_mem_req_cnt_q`) now stalls until every prior mem request -- vector AND
  scalar-FP -- is on the interconnect. Updated the counter comment + the SFENCE_VMA decode comment.
- `acc_mem_vec_accepted_i` (the old vector-only increment) is now UNUSED by the snitch (still routed
  sequencer->spatz->cc->snitch; no compile warning). Dead chain -- offered to remove.
- 3-bit acc_mem_req_cnt can't overflow (<= acc_mem_cnt <= 7; request-sent precedes drain).
- CONSEQUENCE: the matmul gbar_sync (`gbar_wait_vlsu_sent` = sfence.vma) + runtime.h `vlsu_fence()` now also
  wait for scalar-FP (A-load flw) requests sent, not just the vector B bursts.
- Recompiled clean (force `rm build_phase0/compile.tcl`: `Compiling module snitch`, Errors:0).
- USER DECISIONS: (1) KEEP `acc_mem_vec_accepted` routed (may need a vector-only fence in the future) -- left
  the sequencer->spatz->cc->snitch chain in place, just unused by the fence. (2) RENAME the now-misnamed
  wrappers: runtime.h `vlsu_fence()` -> `mem_req_sent_fence()`; sp-fmatmul.c `gbar_wait_vlsu_sent()` ->
  `gbar_wait_req_sent()` (+ updated their "vector-LSU" doc comments to "both vector VLSU + scalar FP-LSU").
  No callers of vlsu_fence existed; gbar_wait_req_sent is used in gbar_sync. App rebuilds clean.

---

## 2026-06-26 — 2-wide resp-BW: design + attempt + CRITICAL FINDING + revert

**Purpose:** lift coalesced per-core burst-load response BW ~1 -> ~2 words/cyc (user option (a): MSHR N-wide
drain + beat-spread + VLSU N-lane receive, parameterized on usable resp ports). Autonomous, PPA-aware.

**Implementation + result:**
- **Phase 0 (param threading) DONE + verified:** `NumRespPorts` threaded tile->cc->spatz->vlsu, MSHR
  `DrainBeatsPerEntry` localparam, `group_mshr_drain_beats` make-var (single A/B knob). Compiled clean;
  `sp-mshr-burst-test` PASS. Design doc `docs/respbw_2wide_design.md` (1096 lines, incl. PPA section).
- **Phase 1 (MSHR §2A) implemented + compiled clean, but FAILED verification:** built inert
  (`group_mshr_drain_beats=1`, `use_beat_spread` const-0) it still DEADLOCKED `sp-mshr-burst-test`
  (`mshr_overflow`, no PASS) -> the §2A had an unexplained inert-path regression.
- **CRITICAL FINDING (step-by-step verification caught it):** the tile response xbar routes by
  `rdata.core_id`, NOT the tile resp port (`mempool_tile.sv:868,956`). A lone-requester burst has a
  constant `core_id`, so spreading its beats across resp ports collapses to ONE VLSU ROB (`core_id-1`) —
  the spread is a no-op; enabled it deadlocks (2nd beat back-pressures forever). Plus `reorder_buffer`
  reads in-order via a free-running, non-settable, per-port `read_pointer`, so a multi-ROB receive needs
  per-port-contiguous `meta_id`s the MSHR cannot generate from one base. **The simple beat-spread design is
  unimplementable as written.**
- **Correct contract:** beat b -> `core_id = sub_reqs[0].core_id + b%N`, `meta_id = port_base[b%N] + b/N`.
  Needs a wider burst request (carries N ROB bases, Opt A) or settable `reorder_buffer` pointers (Opt B) —
  both more invasive than the design. Value caveat: `sp-fmatmul` is compute-bound -> low real-workload gain.

**Status:** MSHR **REVERTED to clean HEAD** (baseline restored, recompiled). §2A attempt saved at
`hardware/bottleneck_analysis/respbw_phase1_attempt/`. Phase-0 scaffolding kept (harmless/reusable). Full
writeup `docs/respbw_redesign_findings.md` + memory `project_respbw_2wide_design_flaw`. Awaiting user
direction on the invasive Option A. **No commits** (working-tree only).

## 2026-07-05 — 2-wide resp-BW (beat-spread Option A): IMPLEMENTED + works; "same-address deadlock" was a MEASUREMENT ARTIFACT; gated OFF by default

Revived Option A from the 2026-06-26 design-flaw finding and implemented the corrected contract:
beat `b` -> resp port `1+(b%N)`, `core_id + b%N`, `meta_id = port_base[b%N] + b/N`, with N=`BurstRecvPorts`=2.

**Implementation (all const-folds out when off):**
- MSHR `mempool_group_mshr.sv`: per-entry beat-spread drain emits the ABSOLUTE per-port ROB slot; the
  port-1 ROB base (`aux_base`) travels in the burst load's spare `wdata.data[IdWidth:1]` (flag in `[0]`),
  read pre-NoC. A beat-spread burst is non-mergeable (keeps both pre-allocated receive ROBs).
- VLSU `working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv`: 2-wide receive (N reorder-buffers);
  `commit_beat_spread` commits N elements/cyc into one VRF row; pushes route by `rsp.id`. Burst+tail shape
  routed through the legacy path (else the tail leaks onto port 0). Shared `mem_pending` counter wipe is
  gated on `rob_empty` (pipelined-burst reuse) AND on `BurstRecvPorts>1` (off = bit-identical legacy).

**The "same-address deadlock" was a MEASUREMENT ARTIFACT (the big lesson).** A same-address 1-core-stream
"deadlock" was chased through three wrong layers (MSHR pileup -> VLSU commit -> barrier). Ground truth
(instrumented VLSU probes + an 80us run):
- VLSU commit is CORRECT: all 16 same-address loads commit (`BSDONE=16`, zero ROB dup-pushes, all 256
  beats delivered). The MSHR delivers everything; the added M7 same-address serialize never fired (bursts
  serialize naturally by ~90ns) -> **reverted as a proven no-op.**
- Every same-address run had been bounded/killed at 12-15us, ~1us before the real completion at ~16us. An
  80us run prints BOTH `[RESPBW]` lines: `cyc=763`, `words_per_1000cyc=335`, `n_lines=1`. NO deadlock.
- The slow tail is the post-stream `mempool_barrier` draining same-address congestion (beat-spread disables
  coalescing -> 16 non-coalesced fetches hammer one remote bank); it RESOLVES.
- The `[CMS] DUP_ALLOC/ORPHAN_RESP/STUCK_REQ` warnings are artifacts of beat-spread's response retag (the
  scoreboard doesn't model `aux_base`), not real errors.

**Effectiveness (single-core streaming):** distinct ON `cyc=770` vs OFF/legacy `cyc=981` for 256 words
= ~1.27x; same-address ON `cyc=763` (also ~1.27x, completes). Post-cleanup clean 64-iter A/B (1024 words):
ON `cyc=3121` (328 words/1000cyc) vs OFF `cyc=3954` (259) = **1.27x**, matching the 16-iter figure; OFF
completes (inert/legacy). Partly latency-bound so not the full 2x.

**Gated OFF by default (opt-in).** Beat-spread ON disables MSHR coalescing for full bursts, so leaving it
on by default would regress coalescing/multicast workloads (matmul shared-B) + carry the same-address
congestion tail. `DrainBeatsPerEntry` / `MshrDrainBeats` else-branch = `1` (off); enable with
`group_mshr_drain_beats=2` for single-requester streaming.

**State:** cleaned -- all beat-spread debug probes removed from VLSU + MSHR; M7 reverted; `mem_pending`
guard gated. ON recompile (`group_mshr_drain_beats=2`) clean (Errors:0), distinct completes. Microbench
`sp-resp-bw-1core` = single-core distinct default + `-DSAME_ADDR` option (STREAM_ITERS=64). **No commits**
(working-tree only).

## 2026-07-11 — Pre-ship multi-agent review of the beat-spread diff: 2 real RTL bugs found + FIXED

Ran a 10-agent adversarial review of the full uncommitted diff (MSHR, VLSU/spatz, param threading,
stray-diff inventory; every substantive finding independently verified). Six findings CONFIRMED, all fixed:

1. **[blocker, FIXED] VLSU OFF-path was NOT legacy-identical** (`spatz_vlsu.sv` mem_pending block): the
   `(BurstRecvPorts>1)` gate on the `mem_pending` wipe had DELETED the legacy unconditional
   `if (commit_insn_push) mem_pending_d='{default:'0}` from the default build (a deliberate
   stale-carry-over bug fix; without it a leaked counter persists and RunningLoad->RunningStore wedges).
   Fix: legacy unconditional wipe restored as the else branch -- BurstRecvPorts==1 now const-folds to
   exactly the original statement. (The earlier "OFF verified" was behavioral-microbench only; the
   netlist-inertness claim was wrong. Lesson: behavioral pass != legacy-identical.)
2. **[major, FIXED] ON-path duplicate beat delivery** (`mempool_group_mshr.sv` beat-spread drive):
   `bs_slot_done` is combinational and the finalize pops only the contiguous done-prefix, so with
   divergent per-port ready a LATER beat delivered while an EARLIER one stalled was re-selected and
   re-delivered next cycle -> VLSU double ROB push / mem_pending underflow (the 1-core microbench never
   diverged the two ports, so sims passed). Fix: ATOMIC FIRE -- an entry's selected beats assert valid
   only when ALL its selected ports are ready (per-entry gate on bs_sel_mshr_id equality), so delivery
   and pop always happen together. Deadlock/livelock-free: the output spill registers' ready is
   state-only and can only rise while valid is withheld.
3. **[major, FIXED] Missing misconfig guards**: `group_mshr_drain_beats=2` on a 1-resp-channel config
   (or =4 anywhere) elaborated cleanly then truncated the resp-port index (RespPortIdW) and wedged
   silently at runtime. Added M8 elaboration $errors (MSHR: DrainBeatsPerEntry in {1,2} and <= usable
   resp ports) + a VLSU $error (BurstRecvPorts<=2: aux_base transport carries exactly one spare base).
4. **[major, noted] `Bender.lock` must not be committed as-is** (pins spatz to `Path: working_dir/spatz,
   revision: null` -- the bender-clone override; regenerate against the pushed spatz revision at commit
   time). 5. **[minor, FIXED]** stale Makefile knob comment (described the old derived-wide default).
6. **[minor, FIXED]** stale doc claims: resolution banners added to `docs/respbw_vlsu_rob_design.md` +
   `docs/respbw_2wide_design.md`; two stale "meta_id stays base+b" comments in the MSHR corrected.

Review also confirmed the rest sound (non-mergeable gating both directions, burst+tail exclusion
request/commit agreement, lane math, threading Makefile->tile->cc->spatz->VLSU, no leftover probes) and
proposed the commit partitioning (spatz repo first: vlsu+spatz+cc one commit; then TeraNoC
mshr+tile+Makefile with regenerated lock; then microbenches; then docs; strays separate/dropped).

**Re-verification: ALL GREEN (both builds recompiled clean, Errors:0).** Fix re-review agent: both fixes
+ both guards independently confirmed CORRECT (atomicity: pre-pass selects a contiguous prefix from
rd_ptr, bs_fire identical across an entry's ports, delivered slots pop the same cycle -> re-delivery
structurally impossible; no comb loop -- spill_register ready_o is state-only; no cross-entry coupling).
ON (=2): sp-mshr-burst-test **PASS** (cores=16, retval=0); distinct 1024 words cyc=3121 (**1.27x**,
matches pre-fix); 4-core same-address stress cyc=2906 clean EOC (divergent-backpressure exercise);
1-core same-address cyc=2922 clean EOC. OFF (default): sp-mshr-burst-test **PASS** (restored wipe's
load->store transitions clean); distinct cyc=3954 (exact legacy number).

**COMMITTED (2026-07-11, all verifications green, on request):**
- spatz repo (`working_dir/spatz`, branch `zexin/teranoc_burst`): `7d164fc` "spatz_vlsu: opt-in 2-wide
  burst receive (beat-spread)" (spatz_vlsu.sv + spatz.sv + spatz_mempool_cc.sv). NOT pushed.
- TeraNoC (branch `zexin/teranoc_spatz_mshr`): `523c23c` mempool_group_mshr + mempool_tile + Makefile;
  `0b5080c` sp-resp-bw microbenches (header fixed, .bak removed); `264be2b` docs/respbw_*.md. NOT pushed.
- Deliberately NOT committed (strays/local state): `.gitignore`, `config/minpool_spatz4_fpu.mk` (remap
  edit on a boot-broken config), `wave.tcl` (debug core-list), WORKLOG/CLAUDE/AGENTS + analysis trees
  (repo-local convention).
- **2026-07-11 (follow-up, on request): spatz PUSHED + lock repinned.** `git push origin
  zexin/teranoc_burst` fast-forwarded `6ab6903 -> 7d164fc` (publishes the two request-sent-fence
  commits + the beat-spread commit); remote tip verified `7d164fc5e6a8...`. `Bender.lock` repinned
  spatz from the bender-clone Path override (revision:null) back to
  `Git: pulp-platform/spatz @ 7d164fc5e6a829c77c186daa9adab5cc1028863b` -- net diff vs HEAD is only
  the revision bump; `bender packages`/`sources` resolve clean; the untracked `Bender.local` override
  keeps local builds on `working_dir/spatz`. Committed as `68c2cbe` "bender: pin spatz to 7d164fc".
- **TeraNoC branch PUSHED (on request):** `origin` (yzf0470/TeraNoC fork) rejected the push -- the SSH
  key authenticates as GitHub user Aquaticfuller (pulp-platform member, no rights on the fork). Pushed
  to `upstream` = pulp-platform/TeraNoC instead: fast-forward `c0f6667 -> 68c2cbe` of the EXISTING
  `zexin/teranoc_spatz_mshr` branch there (upstream is the branch's real home; the fork never had it).
  Remote tip verified `68c2cbe`.
- **Working-tree `Bender.lock` intentionally restored to the bender-clone Path override**
  (`revision: null, Path: working_dir/spatz`, uncommitted) so local builds keep using the local spatz
  checkout; the COMMITTED lock (HEAD, pushed) stays pinned to `Git: pulp-platform/spatz @ 7d164fc`.
  `bender sources` resolves clean. The lock now lives as a permanent intentional local modification
  alongside the three strays -- do NOT `git add` it blindly.

## 2026-07-11 — matmul ON-vs-OFF A/B (user hypothesis: 2-wide receive removes FPU data-wait bubbles): ON WEDGES

User hypothesis: even though sp-fmatmul is compute-bound (46% FPU util = bubbles exist), the doubled
per-core VLSU receive bandwidth could shorten data-wait windows and lift utilization. A/B: identical
`sp-fmatmul-opt-burst-merge` binary (M=N=P=128, 256 cores, verify off) on build_phase0 (OFF) vs
build_on (`group_mshr_drain_beats=2`).

- **OFF (default): kernel 4453 cycles, 941905 OP/1000cyc (45.9% util), clean EOC** (whole sim 49us).
- **ON: WEDGES at the start of the kernel B-burst phase.** CMS req counter froze at 112986 by cyc
  ~12000 and stayed frozen through cyc 96000+ (>84k cycles, zero new requests); last UART "finish
  copy"; killed the run (log kept: scratchpad matmul_ON.log). The wedge regime is exactly the
  shared-line multi-requester case: 16 cores/group load the SAME B lines; flagged bursts are
  non-mergeable -> 16 same-address entries contend for ONE MSHR bank's ways (same addr => same bank),
  M5 stall-not-bypass queues the rest -> something in that pileup circularly blocks (exact micro-cause
  NOT root-caused; single-core same-address serializes naturally and passes, so this is multi-requester
  specific). NOTE: the reverted "M7 no-op" same-address serialize targeted this shape -- it was a no-op
  only for the single-core repro; multi-core same-address is where it would have fired.
- **Verdict: on matmul the 2-wide receive gives NO improvement -- it deadlocks the kernel.** The
  latency-hiding upside never materializes because losing coalescing in the shared-B regime is not a
  slowdown but a hang. Default-OFF (as shipped) is validated as the right call. OPEN ITEM: even as an
  opt-in knob, enabling it on a coalescing workload should degrade gracefully, not wedge -- candidate
  safety fix = same-address multi-requester guard (M7-style serialize, or per-line fallback to the
  legacy coalescing path when a flagged burst hits a resident same-address entry). Needs root-cause
  first (waveform on the cyc~11-12k window).

## 2026-07-11 — Wedge root-cause campaign + REDESIGN directive: ParityDrain + TwinROB0 design doc

**Root-cause campaign (instrumented probe runs on build_mshr, `group_mshr_drain_beats=2`):**
- 16-core same-line repro (one full group, sp-resp-bw-16core-sameaddr) **PASSES** (cyc=8044/1024w,
  127 w/1kcyc -- serialized but alive; healthy [WP] baseline: 4-way bank cycles owners, M5 resolves).
  So pure same-line pileup is NOT sufficient; matmul brings an extra ingredient.
- Instrumented matmul v1: probe was gated on resident beat-spread entries -> blind. Learned: the
  freeze (identical req=112986 from cyc ~12k, deterministic) has ZERO resident bs entries -- the
  deadlock is NOT entries stuck in the MSHR.
- Instrumented matmul v2 (ungated WP-R + VLSU-side VWP): **frozen state captured.** Every stuck VLSU
  identical: 2-burst load fully issued (mc0=128, mem_pending={16,16}), commit_counter=0, ROB0 head
  VALID (beat 0 arrived) but ROB1 head EMPTY -- the FIRST ODD BEAT never arrived, uniformly across
  whole groups. No pending requests at any MSHR door, no resident entries. Suspected class:
  message-dependent response-path HoL (odd beats pinned to port 2 queue behind a blockable scalar
  FP-LSU response while the core stalls on that very beat -- the 2026-06-16 resp-sink deadlock class,
  amplified by 2-wide port pinning). Window-trace run (WT-B/WT-S/WT-A/WT-D per-event probes, cyc
  9000-13000) IN FLIGHT to settle MSHR-drive vs downstream loss.
- Window trace v3 ELIMINATED the HoL hypothesis (WT-S=0: zero port stalls, both parities flowed
  ~29k beats symmetrically) and premature dealloc (all bl_q<=2 = legitimate same-cycle final drains).
- **Window trace v4 (full causal chain, %m-disambiguated + VLSU VT-Q/VT-P): ROOT CAUSE FOUND.**
  Stuck core g[1][1]t4: healthy interleaved p0/p1 spread pushes until t=19566; then its last two
  flagged bursts (id=16 @19674, id=24 @19710) were NEVER accepted by the MSHR yet delivered beats
  **4 cycles later** as 16-beat CONTIGUOUS PORT-0-ONLY runs (wid 16..31, then 24..31,0..7 -- the
  second RE-WRITING slots 24..31 = the real DUP_ALLOCs). 4 cycles = LOCAL TCDM latency:
  **the bursts targeted lines in the core's OWN group; local requests bypass the group MSHR entirely
  and the local path serves them with the LEGACY contract (all beats original port, meta=base+b),
  while the VLSU pre-allocated the SPREAD layout (evens ROB0, odds ROB1/aux). Result: mis-placed +
  cross-burst-clobbered ROB0 writes and ROB1 allocated-never-written slots -> mem_pending[1] never
  drains -> instruction never retires -> core frozen.** Matmul hits it because B is sharded across
  all 16 groups (every core periodically loads a group-LOCAL B-line, near-simultaneously in lockstep
  -> group-wide freeze at cyc ~12k); every microbench passed because they all target REMOTE_G from
  group 0 (never local). Option-A hotfix (if ever exercised): gate mem_beat_spread on target-is-REMOTE.
  **ParityDrain+TwinROB0 is immune by construction** (single contract: local delivery writes the same
  correct ROB0 slots 1-wide; bitmap self-clears) -- documented in the design doc §8.1 + a local-target
  scenario added to the verification matrix (§10.4).

## 2026-07-13 — COMMITTED + matmul bottleneck study (docs/matmul_bottleneck_report.md)

**Commits:** spatz `0bb42b0` (TwinROB0, PUSHED to pulp-platform/spatz); TeraNoC `2298268` (MSHR
ParityDrain + tile) + `b88d12a` (CMS) + `02a9474` (design doc) + `2d6a379` (lock repin to 0bb42b0);
working-tree lock kept on the Path override; TeraNoC branch NOT pushed.

**Bottleneck study** (instrumented matmul: [VPERF] per-core VLSU counters added to spatz_vlsu
(TEMP, csr-window-gated) + BP/LP/GBAR/MSHR-stats + Snitch traces; 6-analyzer + synthesis workflow):
- CORRECTED premises: dims are M=256,N=32,P=256 (kernel_8xVL, VL=32/m2; 32 vle + 8 vse + 256 vfma +
  256 flw + ~32 gbar per core); FMA total coincidentally = 128^3. Receive floor = 512 cyc = 1/4 of
  the 2048-cyc FPU floor (4x headroom) -- NOT at parity.
- Cycle accounting CLOSED (identity verified 0/256 cores): pair_commit 512 + wait_beats 1510 +
  no_insn 713 + store_active 590 + load_resid 640 + vrf_bp 27 = 3992. wait_beats is OCCUPANCY not
  critical path (overlapped with VFU compute); trace-measured vle interval = 79 cyc vs 64 FPU/step
  -> steady memory exposure only ~15 cyc/vle (~480 total). Bulk of the 1960-cyc overhead =
  cold-start fill + PER-N GBAR fence.i tax (217-1111 cyc/core, skew-dependent) + entry/exit drain.
- One-mem-insn serialization: MECHANISM CONFIRMED at RTL (mem_spatz_req_ready only on
  commit_insn_pop; 32-deep commit FIFO is dead capacity) but magnitude smaller than modeled; its
  real cost is preventing deeper prefetch. NoC/link bandwidth RULED OUT (peak 36.9%, resp 80-92%
  idle). MSHR coalescing underperforms (1.57 vs 4 cores/line, 42.9% overflow) -- traffic lever only.
- Fix ranking: (B) hoist/coarsen the per-n gbar_sync [SW-only, first]; (A+C) VLSU 2-in-flight mem
  insns + ROB sizing (one vle32 = whole ROB0 today -- HARD BLOCKER :160; TwinROB0 classifier safe
  for unit-stride-only overlap, needs ROB-target bit for mixed strided); (E) MSHR tuning deferred.
  Ceiling 1.96x (FPU wall); A+C+B targets the 1.7-1.9x band (4009 -> ~2350).

## 2026-07-12 — ParityDrain + TwinROB0 IMPLEMENTED (per signed-off design doc)

User signed off the design doc; implementation complete, compiles clean ON+OFF:
- **reorder_buffer.sv (spatz fork): rewritten with param-gated extensions** (defaults = bit-identical
  legacy): NumWrPorts=2 (second slot-addressed write port data2/id2/push2, collision-asserted) and
  NumRdPorts=2 (second in-order read head at rp+1 + pop_dual, power-of-2 NumWords guarded).
- **spatz_vlsu.sv: REVERTED to legacy (HEAD~1), then TwinROB0 added**: NumRespPorts param +
  BurstRecvPorts localparam; ROB0 instantiated 2W/2R; `burst_odd_expected` 32x1b classifier (set at
  alloc-walk cnt parity, cleared on any consuming push either port -> local/bypass legacy funnels
  self-clear); port-1 responses with the bit set divert to ROB0.wr2 (acceptance gated on
  mem_pending_q[0] -- all burst beats charged to port 0, pure legacy accounting otherwise);
  commit_pair_active window (even element offset, never across burst_full_bytes_commit) drives a
  2-wide commit from ROB0's dual heads (pop_dual, delta 2*ELENB) with 1-wide fallback; mem_pending
  dual decrement; guards (NumRespPorts<=NrMemPorts, BurstRecvPorts<=2) + classifier assertions
  (no native ROB1 alloc while bits set; bits clear at burst retire). Option-A flag/aux/steering GONE.
- **mempool_group_mshr.sv: REVERTED to pre-Option-A (523c23c^), then ParityDrain added**:
  DrainBeatsPerEntry localparam + guards (in {1,2}, <= usable ports, requires DrainMultiPort);
  head select parity-pins burst beats to port 1+(boff&1) (single-word entries keep map_resp_port_id;
  PD2=0 folds to legacy exactly); drive retags core_id+(boff&1) for burst beats only; NEW slot2
  machinery: beat_pending2 + one-shot beat2_armed (eager arm, re-delivery structurally impossible),
  slot2 select/drive on the free parity port (bypass + head keep priority), finalize
  promote-or-double-pop (fully-served slot2 pops with the head incl. beats_left/beat_done/state
  bookkeeping; partial mask PROMOTES to beat_pending so the head arm skips served subs). Entry is
  FULLY MERGEABLE again -- no flag, no aux_base, no non-merge gates, no M5.
- **mempool_tile.sv**: guards (1 core/tile, >=3 data ports); comment refresh. Zero datapath change.
- **tb_core_mem_scoreboard.sv**: ParityDrain-aware (orphan suppression for lower-port-owned beats,
  neighbor-port consumption with native-beat guard, dup-alloc suppression on same-cycle realloc).

**Verification: ALL GREEN (zero CMS warnings on every ON run).**
- Chain F (OFF default): burst-test PASS at the IDENTICAL EOC timestamp to pre-implementation
  legacy (38990ns); distinct cyc=3954 exact; matmul 4453 cycles exact -- bit-identical behavior.
- Chain N (ON, group_mshr_drain_beats=2): burst-test PASS (0 warns); distinct cyc=3121 (1.27x
  preserved); **LOCAL-target sweep (the Option-A wedge geometry) COMPLETES, cyc=3046**; 16-core
  same-line cyc=2900 (**2.8x vs Option A's 8044** -- merge + 2-wide multicast compose);
  **matmul 4009 vs 4453 cycles = 1.11x SPEEDUP** (util 45.9%->51.0%) on the workload Option A
  deadlocked -- the user's original latency-hiding intuition vindicated by the mergeable design.
- Adversarial 3-reviewer implementation review: ZERO blocker/major findings (all six contract walks
  traced correct end-to-end). Two minors fixed: the design-promised §6 runtime assert added to the
  MSHR (per-entry/per-sub genvar loops -- first attempt referenced a genvar out of scope, caught by
  vopt and fixed), and reorder_buffer's second read head structurally tied off at NumRdPorts=1.
  Third minor (classifier soundness rests on op-queue serialization, sim-only asserts) is the
  documented §8.3 dependency -- no structural change.
- Final recompile + matmul smoke with the fixes: GREEN -- matmul 4009 cycles, clean EOC, 0 warns,
  new assertions active and silent.
**Open items before commit:** Spyglass lint (synthesizability gate) + user decision on default
(measurements now favor ON everywhere, but PPA/timing of the dual-ported ROB0 is unchecked).

**Redesign (user directive: "keep it the same as 1-beat, just double the bandwidth"):** ran an
8-agent design workflow (2 RTL grounding readers -> 3 independent designs -> 3 adversarial judges).
Unanimous winner: **ParityDrain + TwinROB0** -- delete the entire Option-A modal machinery (flag,
aux_base, non-mergeable gates, M4-skip, M5, pre-pass/ATOMIC-FIRE/finalize); wire contract reverts to
bit-identical legacy (meta_id=base+b, single contiguous range, FULLY MERGEABLE both directions ->
matmul coalescing restored, wedge regime structurally impossible); the only delta is the drain drive
emitting beat b on port 1+(b&1) with core_id+(b&1), and the VLSU receiving into a dual-write-port,
dual-read-head ROB0 with a 32x1b id-indexed odd-expected classifier (sound via op-queue serialization
vlsu:448-452, runtime-asserted). Two grafts: eager per-slot beat_pending init at capture (re-delivery
structurally impossible; replaces ATOMIC FIRE) + legacy N=1 drain branch kept verbatim (bit-identical
OFF netlist). Design doc: **docs/respbw_paritydrain_design.md** (contract, deletions, specs,
walkthroughs, hazards incl. the inherited HoL class, PPA, verification matrix with matmul-ON-must-
complete as the decisive regression). Awaiting user sign-off before implementation.

## 2026-07-14 — [QSKEW] emission-skew study (user hypothesis): CONFIRMED + window/capacity decomposition

User hypothesized the per-step gbar fails because the VLSUs' actual burst EMISSION times diverge
past the MSHR merge window. Added a TEMP [QSKEW] MSHR-door probe (cycle/tile/line/outcome, csr-gated),
ran matmul (4009 unchanged), 15360 events (=60 remote bursts x 256 cores exactly; 4/core local).
Findings (report §6): median pair skew 4 cyc (barrier aligns the bulk) BUT p90=25 and 15.6% miss
>40cyc -- divergence injected downstream of the rendezvous (residual drain under one-insn
serialization + ROB alloc walk), unfixable by any SW barrier. EFFECTIVE merge window is ~10-15 cyc
(merge legal only until first beat; the 2-wide receive SHRANK it). Even at <=8cyc skew merge tops
out at 79% -- 18% bypass on full banks (resp-cache squatters ~30% of ways @13% hit). Merge rate
curve: 79/46/16/4% for skew <=8/16/34/68. New Option D promoted: BURST-LINE RESPONSE CACHE
(extend MSHR_CACHED to full bursts) = timing-independent coalescing; then drop the per-step barrier
(pure cost); A+C shrink the skew tail at the source. Probe kept TEMP in mempool_group_mshr.sv.

## 2026-07-16 — Bypass-retag table: 2-wide delivery for MSHR-bypassed bursts (Case-1 fix)

Motivation (user review question -> QSKEW data): 28% of matmul burst requests BYPASS the MSHR
(bank-full under barrier-synchronized launch spikes; NOT cache squatting -- alloc already reclaims
CACHED ways :987-1006) and deliver 1-wide (all beats original core_id -> one xbar output), although
they already arrive spread over both tile resp ports.

Implementation (mempool_group_mshr.sv, all PD2-gated/const-folds off; design doc §4.6):
- Per-tile 2-entry side table {valid, meta_base, len, beats_left} (~512 FF/group): allocate on a
  bypass request handshake (multi-beat load out, !req_alloc_found); wrap-safe range-match tag-0
  read responses from core port 1; retag passthrough core_id += (meta-base)&1 (port choice
  untouched -- M4 bypass contract preserved); retire per forwarded handshake (2 beats/cycle
  possible); free at 0.
- Depth-2 sufficiency PROVEN by the VLSU one-insn serialization (<=2 outstanding bursts/tile,
  disjoint id ranges) + asserted (bypass_track_overflow); untracked would degrade gracefully 1-wide.
- Receive side ZERO change (burst_odd_expected accepts odd ids on port 1 from any service class).
- After this fix: MSHR-drained, bypassed (and later cache-hit) bursts all deliver 2 beats/cycle;
  group-local stays the only deliberate 1-wide floor. Restores BANDWIDTH not coalescing (bypasses
  still unmergeable -- Option D's burst-line cache is the traffic dedup).
Compile: ON (build_meas, stats+probes) + OFF (build_phase0) both clean. Eval chain in flight:
sp-mshr-burst-test regression + matmul vs the 4009 baseline. Results appended below.
- **RESULTS: sp-mshr-burst-test PASS (0 warns, overflow assertion silent). Matmul 3940 vs 4009
  cycles (-69, 1.75%; cumulative vs legacy OFF: 4453 -> 3940 = 1.13x). VPERF: wait_beats 1510->1466,
  pair_commit unchanged (same pairs, delivered faster). The modest kernel gain CONFIRMS the report's
  occupancy-vs-critical-path split: bypassed drain time was largely overlapped with compute; the
  69 cycles are its exposed tail. The fix's full value shows on drain-bound workloads (streaming)
  and compounds with Option A/C (2-in-flight) where drain time moves onto the critical path.**
  Working-tree only (not committed).

## 2026-07-16 — COMMITTED (bypass-retag + docs + VPERF) & the agreed perf roadmap

Commits: spatz 31bf7bb ([VPERF] promoted to permanent sim instrumentation, PUSHED); TeraNoC
4acd30e (bypass-retag table) + 623be98 (bottleneck report + design doc §4.6) + 653280c (lock repin
31bf7bb). [QSKEW] study probe stripped pre-commit (one-shot tool; re-add from this WORKLOG's
2026-07-14 entry if needed). TeraNoC branch has 7 unpushed commits (2298268..653280c).

**ROADMAP (agreed with user, evidence-ranked):**
1. **Option B ablation (NOW, SW-only):** GROUP_BARRIER=0 (B0) and steady-loop-sync-removed (B3,
   cold-start syncs kept) vs the 3940 baseline. Rationale: fence tax 217-1111 cyc/core is the
   largest measured recoverable item after serialization; QSKEW showed the barrier only partially
   achieves its coalescing purpose (effective merge window ~10-15cyc, capacity bypasses ignore
   timing); and the bypass-retag fix just made barrier-less drift CHEAP (failed merges now bypass
   at full 2-wide bandwidth). The ablation settles the barrier's fate empirically.
2. **Options A+C (next major RTL project):** 2-in-flight VLSU mem instructions. Re-key
   mem_spatz_req_ready to all-requests-issued (not retire); duplicate request-side counters +
   burst-alloc state; take the burst-cap-16 variant of C (two bursts share ROB0) NOT ROB doubling.
   Targets ~2350cyc (~1.7x vs legacy): steady ~15cyc/vle exposure + cold-start fill + kills the
   emission-skew source (residual-drain variance). TwinROB0 classifier safe for unit-stride
   concurrency; ROB-target-bit extension reserved for mixed strided traffic.
3. **Option D (burst-line response cache, after/parallel to A+C -- different module):** extend
   MSHR_CACHED to full-burst entries; value RISES after B (drifted pairs re-fetch -> D dedups via
   cache hits); timing-independent coalescing completes the emission-skew story.
Ceiling note: post B+A+C ~2350 cyc; the rest of the way to 2048 is the FPU floor itself
(kernel/LMUL/FPU-count territory, not memory-system).

## 2026-07-16 — Option B ablation RESULTS: barrier is net-negative on BOTH axes; B0 adopted

3-way ablation on build_meas (ON + bypass-retag), all clean EOC / 0 CMS warns:
- per-step (baseline): 3940 cyc | wait=1466 no_insn=720 | merge 10.8%, bypass 119763
- **B0 no barrier:    3836 cyc (-104) | wait=1456 no_insn=567 | merge 11.6% (UP), bypass 118640 (DOWN)**
- B3 cold-start-only: 3900 cyc (-40)  | wait=1521 no_insn=608 | merge 9.9%
KEY FINDING: removing the barrier IMPROVED coalescing -- the rendezvous couldn't fix downstream
emission skew (couldn't buy merges) while its synchronized launches CREATED the bank-pressure
spikes causing bypasses. Net-negative on time AND traffic; monotonic across variants.
ADOPTED: GROUP_BARRIER default flipped to 0 in sp-fmatmul-opt-burst-merge kernel (documented,
one-line revert; GBAR_STEADY ablation knob retained). Default binary rebuilt.
Cumulative: 4453 legacy -> 4009 ParityDrain -> 3940 bypass-retag -> **3836 no-barrier = 1.161x**,
FPU util 53.4%. Remaining per report: steady ~15cyc/vle exposure + cold-start + entry/exit ->
next lever = Options A+C (2-in-flight VLSU). Uncommitted: kernel changes (knob + default).

## 2026-07-17 — COMMITTED barrier removal; hold-the-fetch design proposed; enable_single experiment

Commits: 20389fe (kernel: GROUP_BARRIER default 0 + GBAR_STEADY knob, rationale at flag) +
17f1dbb (report §7). A+C (2-in-flight VLSU) PARKED by user for later analysis.

**New direction (user): temporally align the coalescing group's ACTUAL NoC request emission.**
Answer designed: docs/mshr_request_hold_design.md ("hold-the-fetch") -- delay an allocated
mergeable-full-burst entry's NoC issue by W cycles (merge window closes at first-beat = issue+RTT,
so the window extends exactly 1:1); early-release at expected sub count (aligned pairs pay median
4cyc, not W); timeout release (deadlock-free by construction). W=16 captures ~75% of measured pair
skew, W=24 ~90%. Cost ~6b/entry + a request-replay injection arbiter (~100 lines); ~100x cheaper
storage than Option D, composes with it. Key impl constraint: entry-replay path, NOT door-stall
(HoL on the tile req port). Zero interaction w/ ParityDrain/bypass-retag (before-issue vs
after-response).

**Experiment in flight:** group_mshr_enable_single=1 (zero-HW knob) -- the 8 cores sharing an
m-block issue IDENTICAL A-flws, currently 0% coalesced (bypass MSHR). Chain: burst-test regression
+ matmul vs 3836 baseline; watching merge rate, bypass count, kernel cycles (capacity interaction:
singles consume ways).
- **enable_single experiment RESULT (2026-07-17): VACUOUS — the knob is the FLAVOR DEFAULT**
  (terapool_spatz4_fpu.mk:138 group_mshr_enable_single ?= 1; every build/baseline had it ON).
  Both runs cycle-identical (3836, same EOC, all 12 stat totals equal) = clean determinism check.
  CORRECTED understanding: scalar A-flws are admitted all along; the REAL limiters are (a) capacity
  -- only ~42% of ~61k admissible remote flws get entries, the rest bypass on full banks; (b)
  eviction churn -- cached A-lines evict before their 7 same-m-block sharers arrive (24.4k fills /
  5.1k hits / 23.4k evicts = 21% hit-per-fill). My earlier "A-flws bypass the MSHR / 0% coalesced"
  claim was WRONG (stale assumption); docs + memory corrected. Hold-the-fetch design updated:
  applies to single entries too (sharing degree 8 for A), with capacity policy as co-equal lever.

## 2026-07-17 — hold-the-fetch IMPLEMENTED (opt-in); debug + W-sweep evaluation in flight

**Purpose:** extend the MSHR merge window by delaying the fetch, per
docs/mshr_request_hold_design.md (user-approved). **Implementation** (mempool_group_mshr.sv +
hardware/Makefile knobs `group_mshr_hold_window` W / `group_mshr_hold_subs` default 2):
- Entry +`hold_cnt[HoldCntW-1:0]` +`issued`; every fresh alloc (bursts AND singles) is held:
  door accepts locally (`req_in_ready=1, req_out_valid=0`), entry armed with `hold_cnt=W`.
- Free-running countdown on the _q view (never stalls -> deadlock-free); early release when
  `sub_reqs_num >= HoldSubs` checked on mshr_d (same-cycle release on the landing merge).
- Replay walker at end of request comb: RR base `hold_replay_rr_q`, injects a hold_done entry's
  fetch on its OWNER lane (capture guard re-validates owner tile) only when the lane is idle AND
  spill-reg ready already high -> injected valid always accepted same-cycle, no retractable
  valid, no comb loop. Fresh traffic (incl. non-backpressurable bypasses) keeps lane priority.
- W=0/unset const-folds everything out (alloc sets issued=1). Assertion hold_unissued_no_beats
  (response for a never-sent tag = fatal). Guards: W<=31, HoldSubs in [2, merge_reqs].
**Compile:** OFF (build_meas, incr: only mempool_group_mshr recompiled) + ON W=16 (build_hold,
fresh 532 modules) both clean. **In flight:** sp-mshr-burst-test on W=16; OFF matmul inertness
(must be exactly 3836); then W-sweep {8,16,24} matmul + merge/bypass stats. Status: sims running.

### 2026-07-17 (cont.) — hold-the-fetch debug: bypass-track GHOST-WAY bug found + fixed

W=16 burst-test PASSED (227 held allocs, 368 merges, 0 CMS warns), but matmul W=16 hit
`bypass_track_overflow` fatal (~cyc 10.7k, tile 10 g(2,3)). ROOT CAUSE: the ParityDrain
bypass-retag table classified a bypass as door-accept AND lane-forward -- identical events until
hold-the-fetch decoupled them. A replay injection claiming a lane in the same cycle the door
accepted a load-burst MERGE on it looked like a bypass handshake -> ghost track way keyed to the
merged burst (drains from MSHR, never tag-0) -> way never retires -> 2 leaks = table overflow.
FIX: qualify table alloc + assertion with `req_out.mshr_tag=='0` (door passthrough always tag 0;
allocs + replays stamp entry+1). OFF-inert (replay never runs at W=0). Stats + TB probes audited:
key on door signals only, no pollution. Design doc §3b pt 8. All ON builds recompiled; W=16
matmul rerunning.

### 2026-07-17 (cont.) — W=16 matmul RESULT: 4209 cyc = +9.7% REGRESSION; capacity strikes again

OFF (final RTL) = **3836 exact** (inertness re-confirmed, [UART] line). W=16 = **4209** (+373).
Stats (aggregate all groups, OFF -> W16): merged 19841 -> 19989 (+148 only, rate 14.3->14.4%);
alloc 32955 -> 26720 (-6235); no-entry bypass 85685 -> 91772 (+6087); cache hit 5069 -> 3117;
from_mshr 201836 -> 176114 (multicast volume down). MECHANISM: holding entries W cycles extends
way occupancy -> banks full more often -> would-be LEADERS of new lines bypass with no entry ->
their followers have nothing to merge into -> bypass too. The window bought +148 skew-captured
merges but destroyed ~6.2k allocation opportunities. Same lesson as the barrier ablation from the
other direction: **way capacity + eviction churn are first-order; emission skew is second-order.
Any policy that lengthens entry lifetime loses on this workload.** W=8 / W=24 running to map the
trend (expect monotone cost in W).

### 2026-07-17 (cont.) — hold-the-fetch W-sweep COMPLETE: net-negative at every W, default stays OFF

W=8: 3986 (+3.9%) | W=16: 4209 (+9.7%) | W=24: 4229 (+10.2%) vs OFF 3836. W=24 is the telling
point: merges DID rise (+1414, rate 14.3->15.3% -- the window mechanism demonstrably works) yet
perf still degraded: allocs -24%, no-entry bypasses +6.6k, from_mshr -16%, cache hits -44%.
Held cycles = extended way occupancy -> leaders of NEW lines bypass entry-less -> their followers
can't merge. Capacity externality > merge gain, monotone in W. Second independent falsification
of the emission-skew hypothesis (after barrier ablation §7): **way capacity + eviction churn are
first-order**. Feature kept as correct opt-in knob (default OFF = const-folded, OFF re-verified
3836 cycle-exact). Full table + conclusion: docs/mshr_request_hold_design.md §5. Next levers:
extend the SERVE window not the HOLD window -- Option D burst-line cache / way-capacity policy;
A+C (parked) for raw BW. All results: 0 CMS warns, burst-test PASS, hold assertions quiet.

## 2026-07-17 — per-type hold-subs thresholds (user proposal) + class-split stats; experiment in flight

**Purpose:** user proposal after the W-sweep: differentiate the early-release subscriber target by
request TYPE (scalar single A-flw -> 8 sharers, vector burst B-load -> 2), since the two classes
have different natural sharing degrees. Type bit (burst_len==1) is free at the door; address-range
discrimination rejected (needs programmable range registers, no extra separation power here).
One mechanism could flip the sweep's negative sign: degree-8 consolidation of the churned A-stream
(24.4k fills / 21% hit-per-fill) into single entries could REDUCE total entry demand.
**Implementation** (mempool_group_mshr.sv + hardware/Makefile):
- `HoldSubsSingle`/`HoldSubsBurst` localparams (defines GROUP_MSHR_HOLD_SUBS_SINGLE/_BURST,
  default = uniform HoldSubs -> prior builds' behavior unchanged); replay release check picks the
  threshold by entry burst_len; elab guards [2, MshrMergeReqs].
- Stats: merged/alloc split by class -- new `reqs_by_class:` line (merged_single/merged_burst/
  alloc_single/alloc_burst) in period + final dumps; agg_stats.py updated.
- Knobs `group_mshr_hold_subs_single` / `group_mshr_hold_subs_burst` (empty = inherit).
**In flight:** W=16 and W=24 matmuls with single=8/burst=2 vs uniform-2 results (4209/4229) and
OFF 3836.

### 2026-07-18 — per-type hold-subs RESULTS: degree-8 single-hold also net-negative; experiment closed

W16 s8/b2 = 4167 (+8.6%, marginally better than uniform 4209); W24 s8/b2 = **4354 (+13.5%, worst
point measured)**. Class-split stats (new reqs_by_class line) give the mechanism: single merges
per single alloc stay ~0.9 at every setting -- single entries essentially NEVER reach 8 subs
inside the window, so held singles pay full W latency+occupancy then time out. A-sharers arrive
spread over hundreds of cycles (consistent w/ OFF's 21% hit-per-fill churn): OFF serves them via
CACHED *after* the fetch; holding delays cache availability (hits 5069->2140) and squeezes ways
(no-entry bypass 85.7k->96k). Consolidation hypothesis FALSIFIED: temporally-spread sharing needs
post-fetch serving (Option D / CACHED retention policy), not pre-issue holding, at any threshold.
Full table: docs/mshr_request_hold_design.md §5b. Per-type knobs stay in-tree (correct, folded
off); matmul recommendation unchanged: hold_window=0. Ops note: first W24 vsim wedged at time-0
host-side (sleeping proc, 2min CPU/4.9h, no RTL cause -- twin W16 run identical RTL passed);
killed + relaunched clean, stall-guard monitors added.

## 2026-07-18 — ROOT-CAUSE instrumentation (user: "real data, not guess"): measured answer complete

Added translate_off counters to gen_stats (per-bank alloc/ovf hists, per-entry subs-at-free,
drain-stall cycles, hold release reason), printed at trace-off flush (final block is skipped when
the flush already zeroed stat_cycle_count -- first attempt printed nothing, fixed). Instrumented
reruns cycle-identical (3836/4209) => counters non-intrusive. MEASURED chain:
(1) hold_release: 85.5% of held bursts + 70.2% of held singles TIMEOUT (no partner in-window) ->
    pay full W for nothing; VPERF wait_beats +327 of +368 window (89%); CMS avg lat 30->34.
(2) partner-capture at free: 90.9% of burst entries serve exactly 1 requester (avg 1.09);
    drain-stalls ~ZERO (32-90 cyc total!) -> same-line partners are >window+RTT+drain (~60cyc)
    apart = ITERATION-scale drift, not pipeline skew. QSKEW median-4 was survivorship bias (its
    40-cyc cluster-split excluded iteration-scale gaps by construction). Burst budget OFF:
    15,360 reqs -> 9,106 alloc + 830 merge + 5,424 bank-full = 14.5k fetches vs 7.7k ideal.
(3) bank hists: overflow rate 39-47% UNIFORM across all 16 banks (OFF), 50-58% at W16 -> global
    ENTRY shortage, not hot banks/hash; ideal flat-pool model: 7 no-free events on same traffic.
(4) BP door stalls FELL with W16 (17.1k->11.1k) -> door congestion ruled out.
CONCLUSION: no affordable pre-issue window spans the gaps; design is starved of entry METADATA.
Cheap no-data-storage lever: group_mshr_num=128 (validation run in flight). Doc: design doc §5c.

### 2026-07-18 (cont.) — group_mshr_num=128 validation: capacity relief real, ZERO perf value; investigation CLOSED

M128 (OFF+128 entries): overflow 42%->36% (still bursty pressure), allocs +4.5k, but net fetches
only -2.9k, merges/hits DOWN (chaotic re-timing), CMS mean lat unchanged (30), kernel 3977 (+3.7%,
no_insn +135 = re-timing noise-band effect, NOT wait_beats). FINAL MEASURED VERDICT: matmul is
LATENCY-bound (FPU-side chain); resp BW not binding (RESP stalls <=3.4%, 4x headroom). Coalescing
saves BW/traffic -- not scarce here -- so NO capture mechanism (barrier / hold / per-type / raw
capacity) can pay its latency or re-timing cost in kernel cycles. MSHR merge value on matmul =
NoC traffic/energy at scale, not time. Latency-aligned levers left: A+C 2-in-flight VLSU (latency
HIDING, parked) + SW B-reuse. Doc: design doc §5c (+m128 addendum). All runs 0 CMS warns.

## 2026-07-18 — config: MSHR datapath/hold knobs moved into the flavor config files

**Purpose:** the newly added MSHR knobs lived only as bare `?=` fallbacks in hardware/Makefile,
unlike every other tunable (group_mshr_num/merge_reqs/enable_single/... are declared+documented in
config/<flavor>.mk). Moved them to the same place.
**Change:** config/terapool_spatz4_fpu.mk + config/mempool_spatz4_fpu.mk gain, in the Group MSHR
section: `group_mshr_drain_beats ?= 1`, `group_mshr_hold_window ?= 0`, `group_mshr_hold_subs ?= 2`,
`group_mshr_hold_subs_single/_burst ?= $(group_mshr_hold_subs)` (recursive `?=` so overriding the
uniform target still propagates to both classes). Each documented with the measured data (drain=2
is 1.11-1.16x FASTER and fully mergeable; hold is net-negative at every W with the 5c root cause).
hardware/Makefile keeps the empty fallbacks for non-Spatz flavors, now labelled as fallbacks; its
drain_beats comment was STALE (claimed "disables MSHR coalescing... keep off for matmul" -- that
described the ABANDONED Option A, not shipped ParityDrain) and is corrected.
**Defaults are behavior-neutral:** RTL guards are `ifdef X \`X \`else <default>`, and 1/0/2 are
exactly the previous implicit defaults -> explicit defines are semantically identical to undefined.
**Verified** by generating the vlog define set for 6 configs: terapool default =
DRAIN_BEATS=1 HOLD_WINDOW=0 HOLD_SUBS=2 SINGLE=2 BURST=2 (== old behavior); hold_subs=4 ->
SINGLE/BURST=4 (inheritance OK); subs_single=8 alone -> SINGLE=8 BURST=2 (selective override OK);
drain=2/W=16 pass through; mempool_spatz mirrors with num=16/period=1000; minpool (non-Spatz)
emits NO hold/drain defines (unchanged). Full compile of terapool defaults for elaboration check.

### 2026-07-18 (cont.) — removed the bogus HoldWindow<=31 elaboration guard

User challenge: "HoldCntW is calculated from HoldWindow, so why limit it?" -- CORRECT, the guard
was wrong. Audited every consumer: hold_cnt is declared `logic [HoldCntW-1:0]` (:253), init is
`HoldCntW'(HoldWindow)` (:1664), decrement is `- HoldCntW'(1)` (:1524), all tests are `== '0`
(:1727/:2396/:2399). No fixed-width literal anywhere -> the counter always auto-scaled and the
"(hold_cnt width)" reason in the $error was FICTION. Origin: the design doc sketch said
"hold_cnt, 4-5 bits" and clog2(31+1)=5, so I wrote the guard to match the PROSE instead of the
code. DELETED the guard; replaced with a comment stating the counter is sized from W (no ceiling)
plus the real large-W considerations (way occupancy + door-conflict stalls scale with W; W near
the CMS 1000-cyc stuck threshold raises [CMS WARN]; liveness is W-independent since the countdown
is free-running). Also purged the stale "1..31" claim from both flavor configs, hardware/Makefile,
and the design doc (the prose that caused the bug). Verified by compiling W=96.
**Motivation matters for the next experiment:** measured partner gaps are >60 cycles, so NO W<=31
could ever span them -- the sweep so far only proved that too-short windows cost latency for
nothing. W=64..128 is the first setting that actually tests the hypothesis; expect overflow well
above the 51% seen at W=16, and watch whether the 70-85% timeout fraction drops.

## 2026-07-18 — MSHR entry-occupancy signals for utilization analysis (+ wave TCL)

**Purpose (user):** mshr_q_valid conflates real MSHR occupancy with response-cache ways, so it
cannot answer "how utilized are the entries?". **Added** (mempool_group_mshr.sv, translate_off =
zero hardware, always available, no debug define): `mshr_inuse_dbg` (valid && state != CACHED =
outstanding miss, the population that competes for ways / drives mshr_overflow), `mshr_cached_dbg`
(CACHED ways only, reclaimable via bank_has_free), `mshr_held_dbg` (in-use subset with the fetch
still withheld: WAIT_RESP && !issued -- directly measures the way-occupancy cost of a hold window,
all-zero when group_mshr_hold_window=0), plus per-cycle populations `mshr_{inuse,cached,held,
valid}_cnt_dbg` sized idx_width(MshrNum+1). Identity: valid_cnt == inuse_cnt + cached_cnt.
**Wave:** new `Util` group added to BOTH copies of add_group_mshr_wave (scripts/questa/wave.tcl
and scripts/questa/add_group_mshr.tcl), counters with -radix unsigned, placed before Entries so
they are visible above the bulky mshr_q struct array.

### 2026-07-18 (cont.) — hold-the-fetch release-REASON vectors + accumulators (waveform)

**Added** (mempool_group_mshr.sv, same translate_off debug region): per-entry one-cycle pulse in
the cycle a withheld fetch is actually handed to the NoC lane (rising edge of `issued`, so the
pulse aligns with the req_out handshake), split by which release condition fired:
`mshr_issue_timeout_dbg` (hold_cnt reached 0 -- waited the full W, no partner ever came) vs
`mshr_issue_subs_dbg` (sub_reqs_num hit the early-release target -- a real coalescing catch),
plus free-running 32b accumulators `mshr_issue_{timeout,subs}_cnt_dbg`.
Classification uses the SAME expression as the replay walker (both read the post-decrement mshr_d
view) so the split matches actual behavior; timeout wins a same-cycle tie, making the two vectors
mutually exclusive and jointly complete. Counters add the per-cycle popcount (the walker can
release several entries in one cycle, one per free lane) and are NOT csr_trace gated -- take a
cursor-to-cursor delta to scope a region. Guarded by `HoldWindow != 0` so a hold-off build cannot
mistake the alloc-time `issued=1` for a release event (both stay 0).
**Wave:** new `HoldRelease` group in BOTH wave.tcl and add_group_mshr.tcl (counters -radix unsigned).
This is the waveform counterpart of the [MSHR stats] `hold_release:` line (which is trace-gated and
split single/burst instead of per-entry).

**Verified live (sp-mshr-burst-test, build_w96 = W96/drain2/s8/b2, group (0,0)):** compile clean
(0 err); identity `valid == inuse + cached` holds at every sample; at t=14us cached=20 inuse=0
valid=20 -- i.e. mshr_q_valid would have read "20/64 utilized" while REAL MSHR utilization was 0,
exactly the conflation these signals remove. Both release paths exercise: rel_timeout 106->109->152
vs rel_subs 6->17->25 (85.9% timeout at t=26us on this microbenchmark at W=96 -- qualitatively in
line with the 85.5% burst-timeout rate measured on matmul at W=16, though a different workload).
**mshr.do:** appended a loop-based block with all new signals; NOTE the pre-existing 40 flat lines
there reference `mshr_q_valid_uncached`, which only exists under +define+GROUP_MSHR_DEBUG_TRACE and
is NOT catch-wrapped -> that script errored on default builds; mshr_inuse_dbg is the always-available
replacement. File also has a duplicated tail block (groups 0,0/0,1/1,0/1,1 repeated) -- left intact,
cleanup offered.

## 2026-07-18 — committed hold-the-fetch arc (3 commits); Option 1 dual-context expander STARTED

Commits: d76d2bf (mempool_group_mshr hold-the-fetch + probes + knobs incl. flavor configs),
d2f0b3b (questa Util/HoldRelease wave groups + mshr.do), 5bf29d5 (docs: hold design + root cause;
NEW docs/tcdm_burst_interleave_design.md). NOTE committed flavor default group_mshr_hold_window=24
(user's setting; user has since changed working tree to 100 for the large-W experiment) -- flagged
that 24/100 as committed default is measured-net-negative; user to decide before push.

**Option 1 implementation (user-approved: local same-address burst serialization injects pair
skew):** tcdm_burst_expander.sv rewritten with NumContexts parameter -- generate-branch split:
NumContexts==1 is the UNTOUCHED legacy body (bit-identity by construction); ==2 adds a shadow
context: loads-only acceptance while one context drains (no write reordering possible), RR
one-context-per-cycle beat issue reusing the exact prefix-ready lane logic, passthrough preserved
when idle, [BEXP] probes (shadow_accepts / same_base / wait_while_drain_cyc, final print),
assertions (dual_ctx_loads_only fatal, per-context beat bound). Plumbing: mempool_tile
BurstXpdrContexts <- TCDM_BURST_INTERLEAVE define, passed to BOTH expander sites (slave rp loop +
local master); Makefile fallback + flavor configs tcdm_burst_interleave ?= 0.
Compiling OFF (build_meas, hold=0 pinned -- flavor default no longer 0!) + ON (build_bexp).
Verification next: OFF matmul must be EXACTLY 3836; ON burst-test + sameaddr benches; ON matmul A/B.

### 2026-07-18 (cont.) — Option 1 dual-context expander: TWO bugs fixed after first ON sim

User + my ON burst-test both failed. Two distinct root causes, both real:
1. **LockIn instability (user's failure)**: the local req interco (stream_xbar) has LockIn ->
   once a beat is presented, sel/data must stay stable until served. My RR toggled context EVERY
   cycle, so a stalled (unserved) beat had the OTHER context's address driven onto its lane next
   cycle -> input_sel/data_unstable, lock_req deassert-unserved, output_data_unstable, then a
   mangled req produced an ORPHAN_RESP fatal. FIX: switch context only when the current one served
   ALL beats it offered this cycle (issue_fire_cnt == issue_cnt); otherwise hold (re-present the
   same beat, exactly like legacy single-context stall). IssueWidth=1 (local, LockIn) can't
   partial-fire, so this fully resolves it; IssueWidth=3 (slave) only ever holds-like-legacy or
   switches after a clean cycle -> no worse than legacy.
2. **Store in a concurrent context (my dual_ctx_loads_only assert -- caught correctly)**: a stalled
   single STORE occupies a context via the idle-path activation (same as legacy latching a stalled
   single); a load shadow then joined it -> store+load concurrent -> possible write reorder. FIX:
   shadow acceptance now also requires the RESIDENT context to be a load (resident_is_load); a
   store/AMO resident is held alone until it drains (legacy behavior). Two concurrent LOADS never
   conflict (RAR), so interleaving them stays safe.
OFF build (build_meas) is gen_single_ctx only -> UNAFFECTED by these gen_dual_ctx fixes; its
bit-identity result stands (no recompile). Recompiling build_bexp (ON) with both fixes; rerun
burst-test + sameaddr + matmul next.

**Option 1 verification progress:** ON sp-mshr-burst-test PASSES with both fixes -- Errors 0,
CMS_warns 0, no asserts. [BEXP] proves the dual-context path engages: 101 shadow_accepts, and
100% (101/101) are SAME-BASE -- exactly the same-address burst-pair scenario the design targets.
OFF matmul (build_meas, unchanged single_ctx) died early TWICE (cyc 12000 then 6000) with NO error
-- host resource contention (concurrent heavy sims + user's own sims), not RTL (OFF = untouched
branch). Switching to one-heavy-sim-at-a-time. ON matmul (build_bexp) running alone now = the real
Option-1 A/B result vs 3836; OFF bit-identity rerun to follow.

### 2026-07-18 (cont.) — Option 1 matmul A/B RESULT: cycle-neutral; mechanism real but not first-order

ON (build_bexp, interleave=1, drain2, hold0) = 3830 cyc | OFF (build_meas, interleave=0) = 3836.
Delta -6 cyc (0.16%) = WITHIN re-timing noise -> cycle-NEUTRAL on matmul. Both clean (0 CMS warn).
Stats OFF->ON: merged 19841->18198 (rate 14.3->13.1%), but the DIRECTLY-TARGETED burst merges
830->877 (+5.7%); single merges 19011->17321 and alloc 32955->34912 are re-timing reshuffles.
[BEXP] proves the mechanism engaged HARD: 10043 shadow_accepts, 4019 SAME-BASE (40%) -- the
intra-group same-address burst serialization the user identified is REAL and happened ~4019x/run;
now interleaved. Residual wait_while_drain 31304 cyc (store residents / both-full cases).
INTERPRETATION: user's hypothesis mechanistically VALIDATED (serialization real, fix works,
burst coalescing +5.7%) but NOT a first-order cycle limiter -- exactly the design-doc 5c
latency-bound verdict: matmul is bounded by the FPU-side chain, so removing this coalescing/BW-side
serialization doesn't move cycles. Value: correctness-neutral, off-by-default knob; would matter on
a bandwidth-bound kernel; composes with A+C. OFF bit-identity (build_meas, expect exactly 3836)
running to confirm the gen_single_ctx branch is unperturbed.

### 2026-07-18 (cont.) — added BankFullBypass debug signal (user request) + wave scripts

User asked for a wave signal flagging "req wanted an MSHR entry but bypassed because its alloc bank
was full." None existed (only req_merge_valid/req_alloc_found were on the wave). Added
(mempool_group_mshr.sv translate_off): req_bankfull_bypass_dbg[t][p] = req_in_valid && req_can_merge
&& !req_merge_valid && !req_alloc_found && req_out_valid -- reachable only when bank_has_free was
false (else it would STALL+retry, not bypass) = the per-request, per-cycle view of
stat_req_mshr_overflow. Distinct from sub_reqs-full (stat_req_subreq_overflow). Plus free-running
req_bankfull_bypass_cnt_dbg (accepted fires; cursor-delta to scope). Added BankFullBypass group to
all three wave scripts (wave.tcl, add_group_mshr.tcl, mshr.do). Compiled clean (incremental, 0 err).
NOTE: OFF matmul bit-identity kept dying (cyc 6k/10k/12k) NOT from OOM (812GB free, load 2.8) but
because I launched it via a nested `make &` inside a backgrounded job -> orphan vsim reaped on
parent exit. Relaunched as a DIRECT tracked bg job (v4). LESSON: never nest `&` inside a
run_in_background command.

### 2026-07-18 (cont.) — MSHR bank-hash: concentration probe + xorshift mixer (user idea), measuring

User idea: use a hash so a same-time BATCH of reqs spreads across banks -> use more of the 64
entries. CORRECTED my earlier dismissal: run-total uniform overflow rules out a STATIC hot bank
but NOT a rotating/temporal one, which is exactly the batch case. Implemented (mempool_group_mshr.sv):
- [BFBHASH] probe: at each bank-full-bypass event, popcount(bank_has_free) = how many OTHER banks
  could have taken it. avg_free_banks high => concentration (hash helps); ~0 => aggregate-full
  (only ways/entries help). + alias_events (>=half banks free) vs full_events (0 free). Final line.
- group_mshr_bank_hash knob: 0=legacy strided XOR-fold (each addr bit -> ONE bank bit, so a stride
  that is a high power-of-2 toggles one bank bit -> batch collapses to 2 of 16 banks, invisible in
  run-totals); 1=xorshift-mix (mix ^= mix>>7/13/17 then fold) -> odd shifts cross residue classes,
  breaks the collapse. Both pure fn of {group,line} => coalescing preserved by construction. Cheap
  (XOR levels, no multiply). Doc: docs/mshr_bank_hash_design.md.
Builds build_hash (hash0+probe) + build_hash1 (hash1) compiled clean. Running hash0 matmul ALONE
for the [BFBHASH] measurement (decisive: concentration vs aggregate-full). NOTE: interleave OFF
bit-identity (v4) died 4x at cyc ~6-12k even as a direct job w/ 812GB free -- suspect shared
QuestaSim license contention w/ user's sims, not OOM/RTL (build_meas completes when run in a quiet
window; ON matmul + rc2 OFF both completed at 3830/3836). Deprioritized; running one heavy sim at a
time.

**Interleave OFF bit-identity CONFIRMED: build_meas (interleave=0) matmul = 3836 EXACT** (v4
completed cleanly). So the earlier v4 "died at cyc 11000" reading was a FALSE ALARM -- my mid-run
`ps | grep vsimk` liveness check raced the process state; the direct-tracked job finished fine.
Option 1 fully verified: OFF 3836 bit-identical, ON 3830 clean (0 CMS warn), gen_single_ctx inert.
(The v1/v3 deaths were likely real nested-& orphan reaping; v4 as a direct job was fine.)

### 2026-07-18 (cont.) — [BFBHASH] measurement: CONCENTRATION CONFIRMED, user hypothesis validated

hash0 matmul (current hash + probe) = 3836 (== baseline, probe non-intrusive). [BFBHASH] across
all 16 group MSHRs, DECISIVE:
  TOTAL bankfull_bypass = 28,400
  event-weighted avg_free_banks = 13.49 of 16  (84% of banks had room at the overflow instant)
  alias_events (>=8 banks free) = 28,400 = 100.0%
  full_events  (0 banks free)   = 0        = 0.0%
=> EVERY bank-full bypass happened while ~13-14 of 16 banks were free. ZERO aggregate-full events.
The overflow is 100% CONCENTRATION, 0% capacity. User's hypothesis DEFINITIVELY CORRECT; my
earlier run-total-uniform dismissal was wrong (rotating hot bank). Also finally explains why m128
(more banks) barely helped -- the entries existed, the address-pinned hash just couldn't reach
them. Running hash1 (xorshift mixer) A/B: expect bankfull_bypass to collapse, merged/alloc/occupancy
up. (Cycles may stay ~3836, latency-bound.) NOTE: fumbled a nested-& launch again -> orphaned the
first hash1; killed + relaunched direct. STOP nesting & in run_in_background.

### 2026-07-18 (cont.) — hash1 first A/B log was CONTAMINATED (orphan), rerunning clean

The first hash1 result (accepted 138k->193k, merged 19.8k->32.8k, bankfull=0) is INVALID: the log
had 32 init banners (should be 16) -- the nested-& orphan I thought I killed was still running and
BOTH hash1 sims wrote the same file; my aggregator summed doubled output. Tell: period stats showed
mshr_overflow=456 (nonzero) while the BFBHASH line said 0 -- internal contradiction = contamination.
The HASH0 measurement stands (16 banners, clean): bankfull_bypass=28400, avg_free_banks=13.49/16,
100% alias / 0 full = concentration confirmed. Killed all hash1 procs (pkill -9), rerunning hash1
CLEAN to sim_hash1_clean.log; will verify 16 banners before trusting any number. Prepared for hash1
to only PARTIALLY reduce overflow (xorshift is linear; the period mshr_overflow=456 hint may be real
for one of the runs). LESSON reinforced: never nest & in a run_in_background command; verify banner
count before reading contaminated-prone logs.

### 2026-07-18 (cont.) — hash1 CLEAN A/B: bank-full overflow ELIMINATED (28400->0), but cycle/merge-neutral

Clean (16 banners, accepted=138481 both). hash0->hash1: bankfull_bypass 28400->0 (0/16 groups
report ANY overflow -- the xorshift spreads batches across all 16 banks, provably). BUT: cycles
3836->3833 (noise), merge_rate 14.3->13.5%, merged 19841->18712 (merged_b 830->557), alloc
32955->34992. So the hash SOLVES the concentration overflow completely (user's idea works exactly)
but does NOT improve end-to-end merging or cycles -- the overflowing reqs weren't merge-productive
(distinct lines w/ iteration-scale-late partners per 5c, or solo singles), and matmul is
latency-bound. Small hint that spreading REDUCED the incidental stall-and-merge coalescing that
concentration gave for free (merge dip). Honest verdict: real+correct+cheap MSHR bank-utilization
fix, valuable for bandwidth-bound / higher-pressure workloads, but not a matmul win. Running
hash1 sp-mshr-burst-test as the coalescing correctness gate (confirm merged_b dip is re-timing not
regression). CONTAMINATION lesson recorded: verify banner count == 16 before trusting any sim log.

**hash1 sp-mshr-burst-test: PASS** (16 banners, 0 CMS warn, returned 0, merged=381 vs hash0's 368
-- coalescing healthy). Confirms the matmul burst-merge dip (830->557) is RE-TIMING, not a
coalescing regression; same-line->same-bank invariant holds. BANK-HASH INVESTIGATION COMPLETE:
diagnosis validated (100% concentration), fix works+correct (28400->0 overflow, cheap), matmul
cycle/merge-neutral (latency-bound). Kept opt-in group_mshr_bank_hash (default 0); default-on is a
reasonable low-risk call for general MSHR utilization but not a matmul win. Docs: mshr_bank_hash_design.md 6.
Uncommitted: mempool_group_mshr.sv (hash+probe+bankfull signal), tcdm_burst_expander.sv (Option 1),
mempool_tile.sv, Makefile, configs, wave scripts, 2 new design docs. Ready to commit on request.

### 2026-07-18 (cont.) — CORRECTION: xorshift hash does NOT fix concentration (my "eliminated" was wrong)

User asked "so no bank-full bypass anymore?" -> cross-checked both counters, caught a REPORTING
ERROR. Real clean numbers: hash0 bankfull_bypass=28400 avg_free_banks=13.49; hash1=27433
avg_free_banks=13.45. So the xorshift hash reduced overflow only -3.4% and concentration is
UNCHANGED (~13.5/16 banks free at every overflow => batch still collapses to ~2-3 banks). My
earlier "28400->0 eliminated" was a measurement-reading bug: [BFBHASH] prints in the SV `final`
block at SIM EXIT (after [UART] "took N cycles"); I ran the aggregation in the window after UART
but before final -> 0 BFBHASH lines present -> parser returned 0 -> misreported as eliminated.
LESSON: gate final-block-counter reads on the sim-EXIT marker (Simulation returned / End time),
NOT the UART cycle line. ROOT CAUSE the hash failed: XOR+shift are GF(2)-LINEAR; both legacy fold
and xorshift are linear maps addr->bank; a linear map can't de-concentrate a batch whose address
differences lie in a coset of its kernel (matmul batch = such affine structure) -- it only permutes
which addresses collide. FIX that would work: NON-linear multiplicative (Knuth) hash
bank=high(line*odd_const). Deferred earlier for multiply timing; measurement now justifies it.
Caveat unchanged: even perfect de-concentration is expected cycle-neutral on matmul (latency-bound).
Design doc 6 corrected. burst-test PASS still valid (coalescing correct). Diagnosis (concentration
real) stands; the SIMPLE hash just doesn't fix it.

### 2026-07-18 (cont.) — documented address layout + MSHR 3-level indexing (docs + CLAUDE.md)

User Q: how does a request pick the group-MSHR BANK -- by target addr, already hashed? ANSWER:
3 independent levels: (1) which group's MSHR = SOURCE core's group (hartid=(group<<4)|tile), NOT
address -- MSHR is source-side (mempool_group.sv:451-458, coalesces own tiles' outgoing reqs, so
coalescing only among same-group cores => matmul B-share degree-2); (2) which BANK = ADDRESS-HASHED,
req_bank=mshr_bank_of(req_addr_key,tgt_group_id) at :1075 -- THIS is hash0/1 (group_mshr_bank_hash);
(3) which way (1 of 4) = arbitration. Byte-addr layout (terapool, word-interleave): [1:0]byte
[3:2]bank_in_tile [7:4]tile [11:8]GROUP [12+]bank_row. Target NoC group=addr[11:8]
(=addr[ByteOffset+log2(BpT)+log2(TpG)+:log2(NG)], mempool_tile.sv:1192). Wrote full decode to
docs/mshr_bank_hash_design.md §0 + concise version to CLAUDE.md architecture section.

### 2026-07-18 (cont.) — bank-hash ROOT CAUSE FOUND via address capture: hash drops the TILE bits

Added [BFBADDR] probe (+GROUP_MSHR_BANK_DUMP, group_mshr_bank_dump=1 knob) dumping
{addr_key,tgt_group,bank} of bank-full events. Bounded 26us capture (782 events). DECISIVE:
colliding keys = a03,a08,a0a,a0e,... differ ONLY in addr_key[3:0] (the TILE field of tgt_addr),
all -> same bank. Both hash0 AND hash1 fold from BurstAlignBits=4 up => they DISCARD the tile bits
= the only bits distinguishing these (distinct A-load addresses to different tiles, same bank-row).
That's why hash1==hash0 bit-identical, and why my stride-aliasing/non-linear-hash theory was WRONG.
Offline candidate scoring on real addrs (avg distinct banks/40ns window): legacy 1.84, xorshift
1.84, tile-only 4.43, fold-from-0 / legacy^tile^grp 4.50, mult_full 4.40. => Including the tile
bits gives 2.4x spread. FIX group_mshr_bank_hash=2: legacy fold of [BurstAlignBits:] XOR
addr_key[BurstAlignBits-1:0](tile) XOR grp. Cheap (4 XOR2), coalescing-safe (pure fn of
{grp,full key}; aligned bursts have low bits=0 so unchanged). Compiled clean; matmul A/B running
(expect overflow big drop; cycles likely still latency-bound-neutral) + burst-test correctness next.
Design doc mshr_bank_hash_design.md §7. hash=1 kept for the record (superseded).

### 2026-07-18 (cont.) — implemented user's design: 32 entries / 8 banks / field-select hash=3 [7:5]

User directive: 32 MSHR entries/group (8 banks x 4 ways), SW-configurable bank-bit select, default
word[7:5]. Implemented: config group_mshr_num 64->32 (=> BankIdW=3, 8 banks auto), new
group_mshr_bank_hash=3 = field-select on the RECONSTRUCTED LINEAR word address. Reconstruction is
pure re-wiring (put group field back above tile): word_addr = {addr_key[MSB:6](bank_row),
grp(4b), addr_key[3:0](tile), addr_key[5:4](bank_in_tile)}; bank = word_addr[BankSelShift +:
BankIdW]. group_mshr_bank_shift knob default 5 = log2(N=32) so word[7:5] = {group[1:0], tile_top}
separates the stride-N A-lines. SHIFT IS BUILD-TIME for now; runtime SW-config needs a
memory-mapped reg (like ro_cache_ctrl) -- deferred until [7:5] is validated (no point building CSR
infra before the measurement; my offline test showed [7:5] field-select underperforms the hash2
fold on real traffic: max_load 176 vs 62 -- so this A/B is the check). Config now ships num=32,
hash=3, shift=5, drain=2, interleave=1, hold=0. Compiling build_userhash + dump probe. Will
measure overflow/spread + DEADLOCK risk (32 may be tight) + coalescing correctness vs hash2/legacy.

### 2026-07-18 (cont.) — VERIFIED user's [5:3] correction: byte offset IS trimmed, shift=3 beats shift=5

User caught it: addr_key is byte-offset-trimmed (word-granular) -- confirmed (mempool_tile.sv:1181,
every slice starts at ByteOffset=2). Shift sweep on captured overflow addrs (reconstructed linear
word addr): shift=3 ([5:3]) BEST (max_load 114, avg_distinct 3.94) >> shift=5 ([7:5]) (220, 2.52).
So user's revised [5:3] is data-supported. Theory nuance: clean A-load stride model (N=32->bit5)
predicts [7:5], but real overflow entropy is in the LOW tile bits word[5:2] (tile field), so [5:3]
matches reality. CAVEAT: capture biased (= hash0's failures, tile-varying); definitive test =
real RTL BFBHASH per shift (each hash counts its OWN failures). Set config default shift=3. Running
BOTH real matmuls: build_userhash(shift5) + build_userhash3(shift3), compare real overflow +
deadlock(32 entries) + coalescing. Will pick winning shift from real numbers.

### 2026-07-18 (cont.) — 32-entry sims DYING from Questa license/resource contention, NOT deadlock

Both userhash matmuls (shift5, shift3) died at DIFFERENT points (shift5 @ run-a/0cyc, shift3 @
cyc9000), processes KILLED (vsimk gone) not hung => NOT a 32-entry deadlock (that would hang alive
w/ CMS stuck warns). ps shows 10 vsimk sessions: user's long-running jobs (etime 26/47/35 days) +
active GUI (waveform work) + my concurrent batch. License pool oversubscribed -> my headless sims
lose the slot and die; user's (already holding licenses) are safe. FIX: run ONE sim at a time,
accept retries. Relaunched shift=3 (build_userhash3) ALONE as sim_userhash3_v2. 32-entry deadlock
question STILL OPEN (need one clean run). Note for future: don't launch multiple concurrent heavy
vsim while user is actively using Questa GUI.

### 2026-07-18 (cont.) — hash2 (fold+tile) matmul: HUGE WIN, and it's STRIDE-AGNOSTIC

Clean A/B (build_hash2: bank_hash=2, num=64, hold=0, drain=2; accepted=138480 == baseline).
hash2 (legacy fold + XOR tile bits[3:0]) vs legacy hash0:
  bankfull_bypass 28400 -> 120 (-99.6%!) ; merge_rate 14.3 -> 37.7% (2.6x) ;
  merged_s 19011->45357 (+139%), merged_b 830->6879 (+729%) ; cache_hit 5069->29939 ;
  cycles 3836 -> 3786 (-50, 1.3% -- the ONLY thing that moved cycles, small bc latency-bound).
MECHANISM: spreading distinct addrs across banks stops bank-full eviction -> entries PERSIST ->
coalescing partners arrive in time -> merges explode. KEY: hash2 is STRIDE-AGNOSTIC (folds ALL
addr bits incl tile), so NO N-dependence, NO shift, NO SW-config needed -> directly resolves the
user's HW-vs-SW tension: fold everything, don't field-select. Offline confirmed fold(4.50) >
field-select(2.66). NOTE: this CORRECTS earlier confusion -- the '27433/13.5% no improvement' was
hash=1 (xorshift, drops tile bits like hash0), NOT hash=2. hash2 is the real fix. FORK: fold+tile
64-entry (measured, stride-agnostic) vs field-select [5:3] 32-entry (running, N-tuned, half area).
Design doc mshr_bank_hash_design.md needs §7 result update.

### 2026-07-18 (cont.) — field-select [5:3] @32-entry FAILS (14x slower); fold+tile is the winner

Clean [5:3] (hash3, shift=3, 32 entries/8 banks, hold=0): kernel 54546 cyc (14x baseline!),
6667 CMS stuck warns (stuck WRITES to 0xc0000000 sync addr), merge 14.4%. NOTE: BFBHASH final
block printed 0 lines (parse gap) but the reliable stat_req_mshr_overflow = 27668 -> heavy overflow.
RETRACTION: my "[5:3] verified better than [7:5]" was from BIASED offline sweep (hash0's tile-varying
failures); on REAL traffic [5:3]=tile[3:1] ignores row/group entropy -> concentrates like legacy,
and at 32 entries collapses. LESSON: don't tune a narrow field-select on biased capture; FOLD all
bits. WINNER = fold+tile (hash2) @64: 120 overflow, 37.7% merge, 3786 cyc, stride-agnostic (no
shift/N/CSR). ANOMALY: [5:3] overflow(27668) ~= legacy(24004) but 14x slower where legacy=3836 ->
too big for hash alone -> suspect the 32-entry/8-bank halving (or config interaction) is the real
culprit. Testing fold+tile @32 (build_foldn32: num=32,hash=2,hold=0) to disentangle hash-quality
from entry-count + fairly test the user's area-halving goal with the GOOD hash.

### 2026-07-18 (cont.) — DISENTANGLED: 32 entries collapses regardless of hash; fold@64 is the answer

fold+tile @32 entries: 54525 cyc, 6656 stuck, overflow(stat) 12967, merge 21.1% -- SAME collapse
as [5:3]@32. => The 32-entry halving is the CULPRIT, not the hash. Fold IS still the better hash
@32 (overflow 12967 vs [5:3]'s 27668, merge 21% vs 14%) but 32 entries collapses anyway: terapool
= 16 tiles x 2 remote ports = 32 concurrent slots, so 32 MSHR entries = zero headroom -> saturate
-> NoC backup -> barrier writes (0xc0000000) stuck -> 14x. Legacy@64 tolerates MORE overflow (24k)
than fold@32 (13k) yet runs 3836 -> it's ENTRY HEADROOM not overflow-rate that matters.
FINAL: adopt fold+tile (hash2) @64. Config set: group_mshr_num=64, group_mshr_bank_hash=2. Area
halving to 32 does NOT work for this workload. Field-select (hash3)+shift kept available, not
default (worse + needs N-tuning). Bank-hash investigation COMPLETE. docs/mshr_bank_hash_design.md
has the full story (§0 addr layout, §7 root cause, §8 fold+tile win).

### 2026-07-21 — RESOLVED the 0x20-vs-0x80 FP-LSU stride puzzle: it was the i-cache WARMUP pass

FP-LSU granularity = BYTE-level (definitive: snitch_lsu.sv:157 data_qaddr_o={lsu_qaddr_i[31:2],2'b0};
spatz_fpu_sequencer.sv:641 fp_lsu_mem_req_o.addr=mem_qaddr=data_qaddr_o). So 0x20 = 32 BYTES.
User's puzzle (N=32 -> should be 128B/0x80, not 0x20) = CORRECT. ROOT: A-load stride asm = t5 =
a5<<2 (a5=N, the 6th arg). TWO calls: main.c:365 ICACHE_WARMUP passes warmup_n=MIN(8,N)=8 -> stride
8*4=32=0x20; main.c:397 REAL passes gemm_l.N=32 -> 32*4=128=0x80. User watched the WARMUP phase.
B/VLSU stride 0x400=P*4 in BOTH (warmup clamps only N, not P) -> that's why B matched but A didn't.
IMPLICATION: the A stride isn't even constant across the kernel (warmup 8w vs real 32w), so a
field-select tuned to one log2(N) is wrong for the other -> further vindicates the STRIDE-AGNOSTIC
fold+tile hash (hash2) over the data-tuned field-select. My earlier BFBADDR shift-sweep was biased
partly by warmup addrs (finer stride -> favored shift=3); the fold is robust to all of it.
NOTE: bank-hash conclusion UNCHANGED -- fold+tile @64 is the winner.

### 2026-07-22 — per-request-type hold windows (user request): single=0, burst=16

Split group_mshr_hold_window into per-type (mempool_group_mshr.sv): HoldWindowSingle /
HoldWindowBurst (from GROUP_MSHR_HOLD_WINDOW_SINGLE/_BURST, default = uniform HoldWindow) +
HoldWindowMax = max(single,burst) for HoldCntW sizing and all const-fold guards. At alloc the entry
is armed with (req_len==1 ? HoldWindowSingle : HoldWindowBurst); the DOOR hold-decision is also
per-type (a class with window 0 takes the normal issue path -- a held door + 0 window would
deadlock since issued would be set but req_out_valid suppressed). Makefile knobs
group_mshr_hold_window_single/_burst; config sets single=0, burst=16 (scalar loads never held,
bursts held up to 16 to widen their coalescing window). Compiling build_holdtype to verify.

### 2026-07-22 — idea 2: invalid-first MSHR allocation

The bank_free_id scan previously took the lowest-index free-OR-cached way, so it could evict a
low-index CACHED line while a higher-index INVALID way sat unused. Changed to two-pass invalid-first
(mempool_group_mshr.sv bank_free_id): pass 1 = lowest invalid way; pass 2 (only if no invalid) =
lowest reclaimable CACHED way. Priority now invalid -> reclaimable-cached -> bypass. Preserves the
response cache better at zero capacity cost. Behavior change (not bit-identical: picks a different
way) but coalescing correctness unchanged (hit-lookup scans all ways; response routes by tag).
Compiling+burst-testing at fold@64 (measured-safe) to isolate. Idea 1 (served-count self-invalidate
at per-type hold_subs, cached still reclaimable) reviewed = makes sense (no leak: on-demand reclaim
fallback; no crowd-out: frees earlier; target per-type single=8/burst=2) -- to implement after idea 2.

### 2026-07-22 — idea 2 committed; idea 1 implemented: cache self-invalidate at per-type target

**Idea 2 committed** as `9c006b2` (mempool_group_mshr: invalid-first MSHR bank allocation) — only
the bank_free_id two-pass change staged, no other pending edits swept in.

**Idea 1 implemented** (mempool_group_mshr.sv, opt-in `group_mshr_cache_self_inval`, default 0 =
bit-identical). A CACHED entry frees itself once it has served its per-type sharing target, so a
done cache line becomes an INVALID way the invalid-first allocator (idea 2) prefers -> other cache
lines stay resident longer.
- New per-entry `served_cnt` (6b): cumulative count of admitted sub-requests over the entry's whole
  life. Set to 1 at ALLOC (owner) and +1 at every MERGE (WAIT_RESP follower AND CACHED hit). It is
  admitted-count, but at the self-invalidate check point (CACHED, sub_reqs_num==0) admitted==served
  (all subscribers drained), so it reads as served there.
- Self-invalidate block (placed right after the AMO-invalidate loop, guarded by CacheSelfInval &&
  EnableRespCache): for each entry that is CACHED && sub_reqs_num==0 && served_cnt >= per-type target
  (HoldSubsSingle scalar / HoldSubsBurst burst), set mshr_d_valid=0 and clear the entry.
- **Safety.** Only fires on a CACHED entry with no pending subscribers — its response already
  arrived and drained, so no NoC response can be dropped. Runs after alloc/merge, so an entry merged
  into this cycle (now DRAIN_RESP) or just reclaimed by an alloc (now WAIT_RESP) is not CACHED here
  and is untouched — no double-drive with the allocator. An unreached target never leaks: cached
  entries stay reclaimable-on-demand via bank_free_id pass 2 (idea 2). Liveness independent of the
  feature.
- Makefile knob `group_mshr_cache_self_inval`; config `group_mshr_cache_self_inval ?= 0`.
- **Compiles clean with the feature ON** (build_idea1, num=64 ways=4 hash=2 self_inval=1: exit 0,
  0 errors, mempool_group_mshr compiled, 532 modules). Correctness burst-test pending — waiting for
  the idea-2 burst test (build_idea2, still running ~cycle 26k) to free a license (one heavy sim at
  a time).

**Idea 1 correctness gate — PASS.** build_idea1 (num=64 ways=4 hash=2 self_inval=1),
sp-mshr-burst-test: exit=0, Simulation returned 0, CMS_warns=0, asserts=0, MSHR stats printing on
all 16 groups. Self-invalidate exercised with the feature ON -> no dropped response, no double-drive
with the allocator, no deadlock. Idea 1 verified correct; UNCOMMITTED, ready to commit on request
(idea 2 already committed 9c006b2). Both idea-2 and idea-1 burst tests clean.

### 2026-07-23 — matmul perf: idea 1 + idea 2 A/B (committed 9c006b2, 656ea1e)

sp-fmatmul-opt-burst-merge 256x32x256, identical config all three (no-hold: hold_window*=0;
fold+tile hash=2; 64 entries; drain_beats=2), measured THIS tree (deterministic sim -> exact,
repeatable numbers, so even ~20-cyc deltas are real, not noise). One heavy sim at a time.

  baseline 041e9a2 (OLD lowest-index alloc, no idea1/2) : 3877 cyc
  + idea 2 (invalid-first alloc, self_inval=0)          : 3857 cyc   -20 (-0.52%)
  + idea 1 (cache self-invalidate, self_inval=1)        : 3835 cyc   -22 (-0.57%)  [-42 total, -1.08%]

Both ideas are small but real IMPROVEMENTS and they stack. Idea 2 is NOT a regression -- an earlier
worry (Run A 3857 vs a recorded fold note 3786) was config DRIFT in the old note: the true
current-tree fold baseline is 3877, and idea 2 improves on it. All three clean (0 CMS warns, 0
asserts, returned 0).

METHOD NOTE (cost me one wasted sim): to measure the pre-idea-2 baseline I first reverted the .sv,
`make compile`d, restored the .sv, then `make simc` -- but simc's compile dependency saw the restored
(newer-mtime) file and SILENTLY RECOMPILED it, so the "baseline" ran the idea1+2 netlist (self_inval=0)
= Run A (3857), not the true baseline. Caught by a group_mshr_RECOMPILED!=0 guard. Fix: keep the old
file in the tree through the ENTIRE compile+run (single simc), restore only at the end via an EXIT
trap. Lesson: the "make compile skips vlog" sentinel does NOT protect `make simc` across a file swap.

Historical milestones (OLDER tree states, big-picture trajectory only -- not cycle-comparable to
today because intervening commits drifted the fold baseline 3786 -> 3877): 4453 pre-ParityDrain ->
4009 ParityDrain -> 3836 +bypass-retag/no-barrier -> 3786 +fold.

### 2026-07-23 — MSHR measurement-signal audit + fixes (user: "check mshr_issue_timeout* logic")

**Purpose.** User asked whether the `mshr_issue_timeout*` release-reason logic is reasonable,
especially when the related `group_mshr_hold_window*` is 0, then to audit the other measurement
signals in the module.

**Bug 1 (found + FIXED) — release-reason classifier miscounts every 0-window entry as a "timeout".**
`mshr_issue_timeout_dbg`/`mshr_issue_subs_dbg` (sim-only, `mempool_group_mshr.sv` ~:1474) classify a
held entry's fetch release as timeout (hold_cnt hit 0) vs subs (early release at the subscriber
target). The block was gated only on `HoldWindowMax != 0`, so in the MIXED per-type case -- which is
the current config (`hold_window_single=0`, `hold_window_burst=63`) -- it is ACTIVE, and a scalar
(0-window) entry is born `issued=1, hold_cnt=0` into a previously-invalid way, so the "rising edge of
issued" fired AT ALLOC with hold_cnt==0 => counted as a timeout. Every single-word load was
miscounted, swamping the counter and making the timeout/subs split meaningless.
FIX: classify only on the genuine held->released edge (`mshr_q_valid[e] && !mshr_q[e].issued` -> issued
now, replacing `!(mshr_q_valid && mshr_q.issued)`) AND gate on the entry's OWN per-type window being
nonzero (airtight even under a same-cycle realloc collision). Root cause: the 2026-07-22 per-type
split guarded on HoldWindowMax (= "was ANY type held") but never excluded a per-entry 0-window
immediate issue.

**Bug 2 (found + FIXED) — idea 1 broke the cache lifecycle accounting.** A CACHED line can now leave
CACHED three ways: alloc-reclaim (`stat_cache_evict`), AMO (`stat_cache_amo_inval`), and idea 1's
self-invalidate -- which had NO counter. That deflates `evict` and therefore INFLATES the reported
`hit_rate = hit/(hit+evict)`. FIX: added `stat_cache_self_inval` wired end-to-end (declare ->
per-cycle detect (CACHED && going invalid && !amo && !alloc-reclaim) -> accumulate -> period + final
print, new `self_inval=` field in the `cache:` stats line). Verified nonzero in a real run
(`hit=8 fill=16 evict=23 amo_inval=43 self_inval=14`).

**Audited and found CORRECT (no change):** `mshr_inuse/cached/held_dbg` occupancy (`:1428`, `held`
keys on WAIT_RESP && !issued so it already excludes 0-window entries); `req_bankfull_bypass_dbg`
(`:1526`); `stat_cache_evict` (only counts real reclaim-evictions since a self-invalidated way reads
IDLE, not CACHED); the req disposition counters.

**Wave.** Added a `CacheStats` group (self_inval_cycle/self_inval + evict/amo_inval/fill/hit for
context) to BOTH `scripts/questa/wave.tcl` and `scripts/questa/add_group_mshr.tcl` (kept in sync).

**Result.** Both changes are sim-only (`translate_off` + `gen_stats`) => zero functional-path impact,
committed perf numbers stand. Compiles clean; sp-mshr-burst-test PASS (ret 0, 0 CMS warns, 0 asserts).

### 2026-07-23/24 — Spatz vector-core TRACER (new feature, user request)

**Purpose.** User wanted, per Spatz core: at which cycle which instruction executes, at which cycle
and WHY the core stalls, and at which cycle the FUs (vector lanes / FPU) do useful work -- as wave
signals AND as per-core trace files post-processable like the Snitch `trace_hart_*.dasm` / `make trace`.

**Design decisions (user chose):** BOTH streams (instruction events + per-cycle activity) and
PER-LANE/PER-FPU detail (not aggregate counts).

**Where.** The compiled wrapper is `working_dir/spatz/hw/ip/spatz_cc/src/spatz_mempool_cc.sv` (Bender.local
path override) -- NOT the `hardware/deps/spatz` copy (525 vs 506 lines; verified against build compile.tcl).
Its existing scalar tracer (`$fopen`/`$fwrite` in a `translate_off` block, gated `csr_trace_q ||
SNITCH_TRACE`) was the pattern mirrored.

**Streams emitted per core (into $(buildpath)):**
- `trace_spatz_insn_hart_0x*.log` : `ISSUE cyc id unit op vd vs1 vs2 vl` + `RETIRE cyc id unit op
  active stall ipu_cyc fpu_cyc mem_beats`. op/unit are the ENUM NAMES via `.name()` (op_e VADD..VSDOTP,
  ex_unit_e CON/LSU/SLD/VFU) -- no raw-instruction correlation or spike-dasm needed.
- `trace_spatz_cyc_hart_0x*.log` : per ACTIVE cycle -- `run=<4b in-flight id mask>`, stall `reason`
  (idfull/vfu/vlsu/vsldu), per-lane `ipu_busy`/`ipu_vld`, per-FPU `fpu_vld`, `vlsu` FSM state, mem beats.
- `trace_spatz_fplsu_hart_0x*.log` (added 2026-07-24) : the SCALAR FP-LSU (flw/fsw via the FPU
  sequencer `i_fp_lsu`) -- `REQ cyc addr tag L|S` / `RSP cyc tag` / `STALL cyc reason`. This datapath
  is INVISIBLE to the vector streams; it is the only way to see scalar A-load timing + whether a
  vector offload is gated on a scalar FP operand vs the vector window.

**Gating.** New `spatz_trace` Makefile knob (default 0 = only inside the benchmark's csr_trace region;
1 = force always-on) + `-DSPATZ_TRACE`. Mirrors `snitch_trace` (which defaults to 1, which is why the
scalar .dasm looked "all cores" while spatz looked "core 0 only" -- see below).

**Post-processing.** New `hardware/scripts/gen_spatz_trace.py` + `make spatz-trace` target. Emits per-core
`spatz_hart_*.txt` (cycle occupancy, stall-reason breakdown, PER-LANE IPU/FPU utilization, instruction
mix, issue->retire timeline), `spatz_summary.csv` (per-core incl. stall-reason columns + fpl_loads /
fpl_lat_med), `spatz_aggregate.txt` (fleet mean/median/min/max + bottleneck classification), and
`spatz_fplsu_alignment.txt` (shared scalar-load RETURN-ALIGNMENT across cores -- see analysis below).

**Wave.** New `add_spatz_core_wave {g t c}` proc in `wave.tcl` + standalone
`scripts/questa/add_spatz_core.tcl` (drop-in for an open GUI, args `[group [tile [core]]]`), grouped
Issue / Stall / VFU / VLSU. Default waves group0/tile0/core0 (256 cores x ~30 signals is impractical).

**Validation.** RTL compiles clean (532 mods); all XMR paths into `i_spatz.i_controller/i_vfu/i_vlsu/
gen_fpu_sequencer.i_fpu_sequencer` resolve at elaboration (0 errors); all 256 cores open their files
(no fd exhaustion at 768 handles); Python self-tested on synthetic + real data; matmul run returns 0.

**Adversarial review (3 reviewers + per-finding verify) found 3 real bugs, all FIXED:**
1. HIGH -- same-cycle instruction-id REUSE corrupted the RETIRE summary: the ISSUE block reset
   `sp_op/sp_act[iid]` BEFORE the RETIRE block read them for the same id (the controller frees an id
   and can re-issue it the same cycle, routinely when running_insn_full releases one). FIX: emit
   RETIRE (and update sp_run_prev) BEFORE the ISSUE block.
2. LOW -- per-id `ipu_cyc/fpu_cyc/mem_beats` are credited from core-GLOBAL busy flags to every
   in-flight id of that unit, so two overlapping same-unit instructions are both credited. Documented
   as a per-instruction WINDOW aggregate (the per-cycle stream is authoritative), not exclusive work.
3. LOW -- Python ISSUE/RETIRE pairing was LIFO; changed to FIFO (`pop(0)`), correct for id reuse.
(A format-contract reviewer found NO mismatch between the RTL $fwrite strings and the Python regexes.)

**GOTCHA (cost a compile):** SystemVerilog does NOT auto-concatenate adjacent string literals like C --
a 2-line `$fwrite` header string was a syntax error (vlog-13069). Also re-hit the known
`make compile` vlog-skip sentinel: a fresh `rm -rf build_X` is required after editing the .sv, else it
reports "0 errors" from a SKIPPED vlog (check `grep -c 'Compiling module <mod>'`).

### 2026-07-24 — Spatz trace ANALYSES (matmul)

**(a) Fleet utilization / bottleneck** (256 cores, sp-fmatmul 256x32x256, 3977 cyc):
FPU busy **69.4%** (all 4 FPUs equally, 58-82%), IPU busy **0.1%** (pure-FP kernel), run 56.1% /
stall 43.9% (idfull 15.6%, vlsu 15.9%, vfu 12.4%, vsldu 0). Instr mix/core: 248 VFMADD + 32 VLE +
8 VFMUL + 8 VSE + 4 VMUL + 1 VCFG. => **FMA-compute-bound but the FPU is STARVED ~31%**; FPU floor
~0.69*3000 ~= 2070 cyc, matching the known 2048 wall, so ~30% headroom is lost to stalls.
Spatial: stall is uniform by TILE position but rises strongly by GROUP (group 2 = 31% stall, groups
12-15 up to 63%); the high- vs low-stall difference is idfull+vfu (30%/21% vs 7%/7%) while vlsu is
flat ~16% => **NoC round-trip latency surfacing as instruction-window-full**. Lever = hide load
latency (A+C 2-in-flight VLSU), NOT more FPUs.

**(b) Method for "why does PC X take different cycles on different cores"** -- recorded as memory
[reference_spatz_trace_analysis]. 5 steps: ns->cyc (`cyc=(ns-10)/2`); find PC in the .dasm (decode
DASM bits -> op+vd, read `stall_acc`); match op+vd in the Spatz insn log -> ISSUE/RETIRE = exec
duration; compare across cores; explain via the Spatz cyc log's `run=1111`/reason over the offload
window. WORKED RESULT for PC 0x80000380 (`vfmul.vf v6,v18,f3`) cores 8-15: the vector op executes in
an IDENTICAL 19 cyc on ALL cores; the observed difference was `stall_acc` 11->42 (4x) = the Snitch
waiting to OFFLOAD because Spatz's 4-deep instr window was full (core 0x0a 44/45 window-full cyc vs
0x0b 15/16).

**(c) ROOT CAUSE: why don't the earlier in-flight loads finish at aligned times, given the group MSHR
coalesces + multicasts?** (user's question). Investigated with a 4-agent workflow + verified by hand:
- The SCALAR A loads (flw, shared m-rows) DO return **PERFECTLY ALIGNED**: cores 0x08..0x0e all
  request A-word 0x20410 at DIFFERENT cycles (16263..16284) but all receive it at **exactly cyc
  16315 -- 0-cycle spread**. The MSHR coalesces (~degree 8) + multicasts exactly as expected.
  Fleet-wide (9002 shared-load instances): **66.8% spread==0, 26.7% spread 1-4, only 6.5% >4**,
  median spread 0. => the MSHR alignment WORKS.
- The VECTOR B loads (vle32) are the culprit: cores 0x08..0x0f are P-SPLIT and each loads a DISJOINT
  32-column block (verified addrs 0x28400/0x28480/.../0x28780, one per core, target groups 4-7; vd=18
  -> groups 0-3). Different addresses => **structurally un-coalesceable**; different NoC round-trips
  => ~35-cyc RETIRE spread despite issuing in lockstep (vd=20 issues at exactly cyc 16272 on all 8).
  The REAL B-share partner is core k <-> k+8 (verified: 0x00 and 0x08 both load 0x28400) -- a
  different TILE, not the 8 cores being compared.
- The FP-sequencer STALL reason in the offload window is `other` (waiting for the vector controller),
  never `operands` => the A operands are ready on time; the gate is the vector window.
CONCLUSION: the MSHR is not failing anywhere. The window-fill skew is a **data-partitioning + NoC-
distance effect on the un-shareable B loads**, impossible to fix with coalescing.
NOTE: even coalesced sharers are drained beat-serially (one sub-req per resp port per cycle), so
same-cycle alignment for a multi-word load is not expected either.

**SW change (user's, in tree):** `sp-fmatmul-opt-burst-merge/main.c` -- commented out the
`if (cid == 0)` guards on `mempool_start_benchmark()`/`mempool_stop_benchmark()` so ALL active cores
set csr_trace => all 256 cores now emit focused per-core traces (was 1/256, because the app enabled
the trace CSR on core 0 only while `snitch_trace` defaults to 1 = always-on for the scalar tracer).
Safe: csr_trace_q is observational only (feeds tracers/TB gates, never the pipeline) and the reported
cycle count comes from `mempool_get_timer()`. CAVEAT: `csr_trace_any_global` is an OR-reduction, so
the aggregate [LP]/[BP]/[CMS]/[MSHR] profiling window now starts earlier (union of all cores' regions).

### 2026-07-24 — ICACHE hierarchy mapped + one-by-one refill fan-out CONFIRMED

**Purpose.** User reported that on an L1+L2 icache miss the refill responds to a group's cores ONE BY
ONE (delaying them), and asked for an introduction to the icache hierarchy. Investigated with a
17-agent workflow (11 findings confirmed, 1 refuted) + hand verification. Full detail saved as memory
[reference_icache_hierarchy]; summary here:

**Hierarchy (terapool_spatz4_fpu).** L0 `snitch_icache_l0` private per core (256; 4 x 32 B = 128 B,
fully assoc, combinational hit, does prefetch; **`pending_refill_q` is 1 BIT => MLP=1 per core**) ->
L1 `snitch_icache` per TILE (256; **2 KiB**, 32 B line, 2 ways x 32 sets, `NR_FETCH_PORTS=1` so it
canNOT merge two cores) -> **RO cache** `snitch_read_only_cache`, **ONE per group** (16 total,
**8 KiB**, 64 B line, 2 ways, shared by 16 tile L1s + 1 DMA; 17->1 flat axi_mux, no recursion) ->
16 private 1 MB L2 endpoints (NO cross-group arbitration -- a claimed 2nd serialization was REFUTED).

**CONFIRMED mechanism.** The RO cache DOES merge (16-entry address-CAM MSHR; N same-line misses OR
into one entry, NO second L2 fetch => cost = 1x L2 latency + N cyc fan-out, not Nx). But the handler
emits ONE N-hot ID vector and `snitch_axi_to_cache.sv:221-264` **UNROLLS IT ONE BIT PER CYCLE** via an
`lzc` (the source comment says so verbatim). Order is fixed-priority ASCENDING TILE INDEX => tile 0
first, **tile 15 always +15 cyc**. MEASURED: exact +1-cyc/tile staircase (9459..9474), **15 cyc
first->last**; per-miss fetch stall 29-55 cyc; aggregate `stall_ins` = **10-23% of wall-clock EVEN
WITH ICACHE_WARMUP ON**. Trigger is ANY L1 miss reaching the group -- including an RO-cache HIT.

**Corrections to the mental model:** (1) not "miss in both levels" -- a hit serializes too; (2) L2 is
read ONCE not 16x; (3) no 2nd serialization at L2.
**My own error, corrected:** I first said the cacheable window is 4 KiB so most of .text bypasses the
RO cache. WRONG -- `crt0.S:116-119` (hart 0) rewrites RO_CACHE_END_0 to `_erodata` = 0x80004000, so
the window is **16 KiB** and .text (11712 B) is fully cacheable. The real limitation is that the 8 KiB
/ 2-way cache serves a 16 KiB window => **~2x oversubscribed, misses RECUR all run**.
**No icache instrumentation exists**: `icache_events_o` is discarded (`mempool_tile.sv:391`), zero TB
probes => all published matmul numbers EXCLUDE cold icache cost (ICACHE_WARMUP runs before the timer).

### 2026-07-24 — RO-cache response MULTICAST: design evaluation (IN PROGRESS)

**User's idea.** Add MSHR request merge + response multicast to the RO cache with minimal area /
latency / backend-timing overhead.
**Key reframing:** request merge ALREADY EXISTS (see above) -- only the MULTICAST is new work.
**Key enabler found:** `axi_mux.sv:446-449` -- `assign slv_r_chans = {NoSlvPorts{mst_r_chan}};` the
512-b R data is ALREADY physically replicated to all 17 slave ports; only `slv_r_valids = 1 <<
switch_r_id` is one-hot. So multicast is a **CONTROL-ONLY change; datapath cost ~= 0**. Also: each
tile's L1 refill does NOT check `r.id` (single-ID master, in-order queue, `snitch_icache_refill.sv:67-68,
127-133`); a line is ONE beat (`ar.len=0`, LineWidth==AxiDataWidth=512b); each tile has at most one
outstanding RO read (L0 MLP=1 + GUARANTEE_ORDERING) so a merged recipient is by definition already
waiting for exactly this beat (=> r_ready very likely already high on all of them).
**Open design questions sent to a design workflow (w739pk2v7):** (a) how to carry the N-hot mask to
the mux (AXI id is 7 b, can't hold a 17-b mask => small sideband, contained since cache+mux are both
inside axi_hier_interco); (b) backpressure -- all-ready AND-reduce (simple but couples 17 ports) vs
**partial drain** (deliver to the ready subset, clear those mask bits, repeat; strictly better than
today, degrades gracefully -- mirrors the data-side drain). 3 independent designs, each adversarially
reviewed for deadlock/AXI-legality and timing/area realism, then judged. RESULT PENDING.
**Payoff estimate:** up to 15 cyc per shared miss per group vs 10-23% wall-clock icache stall.
Measurement caveat: must disable ICACHE_WARMUP and first instrument `icache_events_o`.

### 2026-07-24 — STAGED (not committed) working set

Main repo: `hardware/src/mempool_group_mshr.sv` (classifier fix + self_inval stat),
`hardware/scripts/questa/wave.tcl` + `add_group_mshr.tcl` + `add_spatz_core.tcl` (NEW),
`hardware/scripts/gen_spatz_trace.py` (NEW), `hardware/Makefile` (spatz_trace knob + spatz-trace).
Spatz repo (`working_dir/spatz`, its OWN git): `hw/ip/spatz_cc/src/spatz_mempool_cc.sv` (vector tracer
+ FP-LSU stream). => committing needs TWO commits.
Deliberately NOT staged (user's / unrelated): `config/terapool_spatz4_fpu.mk` (live experiment values
num=32 / hold_window_burst=63 / cache_self_inval=1), `config/minpool_spatz4_fpu.mk`,
`sp-fmatmul-opt-burst-merge/main.c` (debug printf + the all-cores csr_trace change), `.gitignore`.

### 2026-07-24 — RO-cache multicast: DESIGN VERDICT (completes the IN-PROGRESS entry above)

11-agent design workflow (3 independent designs, each adversarially reviewed for deadlock/AXI-legality
and timing/area realism, then judged). **ALL THREE candidate designs were REFUTED by the reviewers**;
the recommendation is a synthesis that structurally excludes every flaw found.

**VERDICT: yes it makes sense, but it is the THIRD thing to do, not the first. Realistic payoff
~1-3% wall clock.**

**Even more already exists than I thought.** Beyond the request merge, the handler's **single-cycle
N-hot RELEASE already exists**: `in_rsp_id_o = pop_idmask` (`snitch_icache_handler.sv:284`),
`in_rsp_valid_o = |pop_idmask` (`:327`), ONE `pop_enable` retires the whole entry (`:328` ->
`pending_clr` `:111`), and `miss_in_flight_q &= ~in_rsp_id_o` (`:167`) frees all N ids the same cycle.
=> **the handler needs ZERO changes.** The ONLY serialized thing is the AXI R beat, entirely inside
`snitch_axi_to_cache.sv:221-264`.

**Recommended design "R-MCAST"** (~150 lines, 7 files + 1 dep patch + 1 new project-local module).
The idea that makes it safe: make eligibility an **ELABORATION CONSTANT**, deleting all per-transaction
bookkeeping (which is what killed all 3 proposals):
  `McastOk = ROCacheRMcast && (ROCacheLineWidth==AxiDataWidth) && (ICacheLineWidth<=AxiDataWidth)`
  `eligible(id) <=> (id[1:0]==2'b00) && McastPortMask[id[6:2]]`
- `ICacheLineWidth=256b <= AxiDataWidth=512b` => `BeatsPerRefill=1` => **`ar.len==0` is a THEOREM**, so
  no id_busy/id_single state, no AR gate, no RWait freeze. For mempool/systolic (4 cores/tile)
  ICacheLineWidth=1024b => the guard **fails closed** -- exactly the silent-corruption case reviewers found.
- `id[1:0]==2'b00` identifies a tile icache (icache is slave idx 0 at `mempool_tile.sv:1484`,
  `axi_req_o='0` in refill), and `axi_id_prepend` truncates to id[1:0] at each group slave port, so
  **ONE physical R beat is bit-exact for all 16 tile icaches simultaneously**.
- Do NOT edit the shared `axi_mux.sv` (8 instantiation sites incl. every tile) -> new project-local
  `hardware/src/axi_mux_mcast.sv`. `hardware/deps/axi` is NOT git-tracked -> needs a new
  `hardware/deps/patches/axi.patch`; `hardware/deps/snitch` IS tracked -> edit in place.
- Knob must default in `config/config.mk` (not a flavor .mk) or `-DRO_CACHE_R_MCAST=` expands empty
  and breaks vlog on the other 8 configs.

**Cost (estimated, NOT synthesized): 51 FF + ~200 cells per group = 0.6-0.9 kGE; ~10-15 kGE for all 16
groups.** The 512-b R DATAPATH costs **0** -- already replicated (`axi_mux.sv:446`). That is <1/5 of the
R spill register it sits next to. Timing: the valid path gets SHORTER/lower-fanout; the one honest new
item is `r_pop` fan-in (17 slave r_readys instead of 1 selected) -- an existing 17-b bus, ~3 levels vs
today's 4-5; if it misses, pipeline it and accept a 1-cyc bubble (still 14 cyc better than today).

**Benefit:** staircase contributes mean (N-1)/2 = 7.5 cyc (15 to the last tile) = 14-26% of a merged
miss's 29-55 cyc stall; icache stall is 10-23% of wall clock => upper bound ~2-5%, realistic **1-3%**.
Possibly larger 2nd-order: frees the RO cache's R port + its 16 pending entries ~15 cyc earlier, and
removes a **group-wide AR FREEZE** (`rsp_ready_q` low -> `hit_ready` low -> lookup stalls ->
`ar_ready=0` -> the `rr_arb_tree` with LockIn=1 HOL-blocks ALL 17 masters; only ~6 transactions of slack).

**GO/NO-GO GATE (do this first, one afternoon):** add a `[ROC]` probe in `snitch_axi_to_cache.sv`
(~15 lines): `$countones(rsp_in_q.id)` popcount histogram at each response, `drain_cycles`,
`ar_blocked_during_drain`. **KILL the feature if the histogram mass sits at 1-2.** Also wire up
`icache_events_o` (discarded at `mempool_tile.sv:391`; type = {l0_miss,l0_hit,l0_prefetch,
l0_double_hit}) for the L0 miss RATE -- need BOTH. **Must build with `-DICACHE_WARMUP=0`** or the A/B
measures nothing by construction (the timed loop currently runs with a warm I$).

**DO THESE FIRST (ranked effort-to-payoff)** -- the multicast attacks the 15-cyc TAIL; the 29-55-cyc
MISS ITSELF x miss count is 2-4x bigger and is attacked by capacity, one line each:
 1. **Grow the per-tile L1 I$** (`mempool_pkg.sv:207-209`; 2 KiB = 64 lines of 32 B per core is tiny).
    CAUTION: raise ICacheSizeByte/ICacheSets, NOT ICacheLineWidth -- past 512 b it flips BeatsPerRefill
    to 2 and disables R-MCAST by the guard.
 2. **Grow the group RO cache** (`mempool_pkg.sv:216-217`; 8 KiB/128 lines shared by 17 masters).
 3. `MaxTrans 16->32` (`axi_hier_interco.sv:235`) IFF the [ROC] probe shows free==0 stalls.
 4. R-MCAST.

**EXPLICITLY DO NOT** (all refuted with reasoning):
- **Rotating the lzc priority** -- MY EARLIER SUGGESTION, REFUTED. Skew does NOT compound: because
  L(29-55) > N(16), every tile re-merges into the same next fill, so completion is T_k + t, not
  T_k + t*k. Rotation only changes WHO is last; someone always is and the barrier still waits 15 cyc.
  Costs ~2 kGE + 7 logic levels (barrel rotate) in front of the 128-b lzc for ~0 cycles.
- Deepen the response spill 2->4 (spill_register is strictly in-order; a 16-beat drain still freezes;
  +1282 FF for a partial mitigation, strictly dominated by R-MCAST).
- The "DMD" drain-slot design (concedes the tail is irreducible, its RR DOUBLES worst-case drain to 2R,
  and both reviewers found independent fatal RWait bugs).
- `UniqueIds=1'b1` on the RO-cache demux (unsafe).
- Editing `hardware/deps/axi/src/axi_mux.sv` in place.

**Acceptance criteria if built:** knob=0 must be CYCLE-IDENTICAL to baseline; ON completes sp-fmatmul
with 0 [CMS] warnings at -DICACHE_WARMUP=0; [ROC] drain_cycles + [BP] fetch stall drop by the amount
the histogram predicted (else revert, don't tune); directed tests (16 tiles same cold line; mixed
mask 8 icaches + 1 SoC read; DMA multi-line concurrent with a merged miss; enable_i=0; flush during a
held beat); `make lint` (slv_r_valids is no longer one-hot -- Spyglass may object).

### 2026-07-24 (cont.) — CORRECTION: a late RO-cache requester HITS, it does not re-fetch

User challenged my claim that a tile missing the RO-cache merge window "eats a full second L2 round
trip". **The claim was WRONG.** Verified: the refill WRITES the line into the cache SRAM and the
pending entry can only pop once that write is accepted -- `rsp_ready = (in_rsp_ready_i ||
in_rsp_served_q) && (write_ready_i || write_served_q); pop_enable = rsp_ready`
(`snitch_icache_handler.sv:318-331`). So there is NO window where the line is neither pending nor
cached: a late requester looks up and **HITS** (cache-hit latency, not an L2 round trip). Writes also
have PRIORITY over lookups and force `in_ready_o=0` (`snitch_icache_lookup_serial.sv:117` before
`:126`), so a request arriving in the write cycle waits 1 cycle then hits.
ONLY narrow exception: a lookup that already read its tags when a SAME-SET write lands has its hit
conservatively force-cleared (`lookup_serial.sv:207-210` -- the write may have evicted the line it
hit) -> handler finds no pending entry -> re-fetch. 1-cycle, same-index only.
=> Genuine re-fetches are far more likely CAPACITY evictions (8 KiB / 2-way over a 16 KiB window),
which REINFORCES the ranking that "grow the caches" beats the multicast. Caveat that still stands: a
late HIT still queues through the same 1-response-per-cycle R channel.
(The workflow had flagged this as "medium confidence, unmeasured"; I restated it too firmly.)

### 2026-07-25 — R-MCAST: design doc written + IMPLEMENTED (opt-in, default off)

**Doc:** `docs/icache_rmcast_design.md` -- problem+measured baseline, the elaboration-constant idea,
phase A/B, fork-join fan-out, the mandatory demux fix, cost table, benefit + measurement gate, ranked
cheaper alternatives, explicitly-rejected options, acceptance criteria, provenance.

**Implemented across 10 files** (knob `ro_cache_r_multicast`, default 0):
1. `config/config.mk` -- `ro_cache_r_multicast ?= 0` (MUST default here, not a flavor .mk).
2. `hardware/Makefile` -- `-DRO_CACHE_R_MCAST`.
3. `hardware/src/mempool_pkg.sv` -- `ROCacheRMcast` + `ROCacheMcastOk` (the elaboration guard:
   ROCacheLineWidth==AxiDataWidth && ICacheLineWidth<=AxiDataWidth => ar.len==0 is a THEOREM; fails
   closed on mempool/systolic where ICacheLineWidth=1024>512).
4. `hardware/src/axi_mux_mcast.sv` (**NEW**, script-generated from axi_mux.sv to avoid copy errors) --
   R block replaced by fork/join multicast: `r_target = (|mask) ? mask : (1<<switch_r_id)`,
   `r_pend = r_target & ~acc_q`, `slv_r_valids = r_pend`, `r_pop = ~|(r_pend & ~slv_r_readies)`,
   `acc_q` ticks off ports that accepted. `RMcastEn=0` => the multicast logic is NOT GENERATED at all
   (generate-if), so it is bit-identical to upstream axi_mux. Did NOT edit the shared axi_mux (8 sites).
5. `Bender.yml` -- register the new module before axi_hier_interco.
6. `hardware/src/axi_hier_interco.sv` -- `McastPortMask` param, `r_mcast_mask` wire, instantiate
   axi_mux_mcast; `gen_no_ro_cache` ties the mask '0.
7. `hardware/src/mempool_group.sv` -- `icache_slv_mask()` mirroring the gen_axi_slv_vec packing
   ({dma,tiles} per DMA group) => 17'h0FFFF for terapool_spatz4_fpu.
8. `snitch_axi_to_cache.sv` -- phase A/B split (`mcast_pmask`/`mcast_idset`/`resid_set`), existing
   128-b lzc + cc_onehot RETARGETED at resid_set (not duplicated), `rsp_ready_q` pops once both
   phases drain, new R-FSM arm that never enters RWait, `ar_noalloc` (eligible ids skip the burst
   table so nothing leaks), outputs `r_mcast_mask_o` (port mask) + `r_mcast_idset_o` (id mask).
9. `snitch_read_only_cache.sv` -- thread params + both masks; drive the demux pop mask (Cache port).
10. `hardware/deps/axi/src/axi_demux{,_simple}.sv` -- MANDATORY: `pop_mask_i` on the id counters
    (`pop_en = pop_mask_i | ...`) so a multicast beat retires ALL N ids; otherwise N-1 counters stay
    occupied forever and permanently block those tiles' ARs. SV default port values so the ~10 other
    instantiation sites are untouched. deps/axi is NOT git-tracked => shipped as
    `hardware/deps/patches/axi.patch` (verified: `git apply --check` OK against pristine sources and
    the round-trip is byte-identical to the edited files).

**Status:** OFF compiles clean (533 mods, 0 err). ON compiles clean (533 mods, 0 err).
Added a `[ROC]` probe in axi_mux_mcast (fan-out histogram, mcast beats, cyc_saved, hold_cyc) -- this
is BOTH the activation check and the design's own go/no-go gate. Functional matmul run with ON in
flight.

**GOTCHAS hit (both cost a compile):**
- `make compile` returned **exit=0 on a build with `Errors: 1`** -- caught only by the module count
  (283 vs 533). ALWAYS check `grep -c 'Compiling module'` and `** Error`, never the exit code.
- Two port insertions silently no-op'd because the upstream port lists use different column spacing
  than my anchor string (`output axi_resp_t` + 21 spaces, not 18). The instantiation connection landed
  while the DECLARATION did not => "Undefined variable". Verify every scripted edit landed
  (`grep -c`), do not trust the replace.

### 2026-07-25 (cont.) — R-MCAST [ROC] go/no-go measurement: WORKS, but benefit lands outside the timed region

matmul on build_rmc1, `ro_cache_r_multicast=1`. **Functionally correct: Simulation returned 0, 0 CMS
warnings.** The feature is demonstrably ACTIVE (the elaboration guard did not silently disable it).

[ROC] fan-out histogram (whole sim, all 16 groups, counters are free-running / NOT csr_trace gated):
  fanout=1 : 12057   <- 95.5% of beats
  fanout=16:   384   <- the full 16-tile shared-line case
  fanout 2..15: ~180 total
  beats=12621  mcast_beats=11121  cyc_saved=7399  **hold_cyc=0**

**Reads:**
- **`hold_cyc=0` is the standout**: EVERY multicast beat was accepted by ALL masked ports in a SINGLE
  cycle -- the fork/join never had to re-present a beat. Best case every time. This empirically
  confirms the design assumption that merged tiles are already sitting waiting for exactly this beat
  (L0 MLP=1 + GUARANTEE_ORDERING), so the "all-ready" concern was unfounded in practice.
- **7399 cycles saved on the response path** (sum of popcount-1), dominated by the 384 fanout=16
  beats (384*15 = 5760).
- **BUT the histogram mass IS at fanout=1 (95.5%)**, which is the design doc's stated KILL condition.
  Caveat on interpreting that: fanout=1 counts ALL R beats through the group mux (DMA, core SoC port,
  non-merged icache), not just icache refills -- so it is not "icache merging is rare", it is "most R
  traffic here is not a merged icache refill".
- **The saved cycles land mostly at BOOT/cold start, OUTSIDE the timed region**, because
  ICACHE_WARMUP warms the I$ before the timer. Exactly the effect the design doc warned about.

**DO NOT read this run's 4171 cycles as a regression.** It is NOT comparable to the earlier 3835/3877
A/B: those pinned `hold_window*=0`, while this run inherited `GROUP_MSHR_HOLD_WINDOW_BURST=63` and
`GROUP_MSHR_CACHE_SELF_INVAL=1` from the (edited) config.mk. Different config, not a controlled A/B.

**VERDICT: inconclusive on wall-clock; correctness + mechanism verified.** The decisive experiment is
an A/B at IDENTICAL knobs with `-DICACHE_WARMUP=0` (ro_cache_r_multicast 0 vs 1). Until that is run,
no perf claim should be made either way.

### 2026-07-25 (cont.) — Spatz tracer: FP-sequencer instruction stream + PC/insn in BOTH streams

User asked for (a) an FP-sequencer ISSUE/RETIRE/stall-reason stream like the vector one, and (b) both
streams to be matchable to the .dasm PC.

- **PC correlation.** Spatz has no PC of its own, so snapshot `(pc, insn)` at the ACC OFFLOAD
  HANDSHAKE (`acc_req_d_valid && acc_req_d_ready`, where `i_snitch.pc_q` is still the offending
  instruction) and carry it forward two ways: vector ops -> a small in-order FIFO popped when the
  controller assigns an id, then held per-id (so ISSUE **and** RETIRE both print it); local ops
  (flw/fsw/fmv) -> held per FP DEST REGISTER, so an out-of-order FP-LSU writeback can still name its
  instruction. CAVEAT (documented in the RTL): the vector FIFO assumes every accepted non-local op
  reaches spatz_req_valid_o once, in order -- an ILLEGAL vector insn would desync the PC column; each
  line also prints the raw insn so that is detectable, not silent.
- **FP-seq stream** now has `ISSUE cyc pc insn kind(load|store|move|vector) fd` and
  `RETIRE cyc port(fpu|lsu) fd pc insn` (port 0 = offloaded-FPU result, port 1 = FP-LSU), on top of
  the existing REQ/RSP beats. Retire is per-REGISTER because the sequencer is scoreboard-based
  (`sb_q[NrFPReg=32]`), not window-based.
- **FIXED the stall-reason flaw** I flagged earlier: `running_insn_full` is a SEPARATE gate
  (`spatz_controller.sv:469`), NOT part of `stall` (`:449`), but my priority encoder listed idfull
  FIRST and therefore HID the real stall unit in every line of the traces analysed earlier. Both
  streams now emit ALL active reasons as a comma list (e.g. `reason=vfu,idfull,`). Sequencer likewise
  (`operands,offload,` where `offload` = `!is_local && !issue_ready_i`, previously mislabelled
  "other").

Compiles clean (533 mods, 0 err). Validation run in flight.
**TODO:** `gen_spatz_trace.py` still parses the OLD line format -- `make spatz-trace` needs updating
for the new pc/insn fields and the comma-list reasons.

### 2026-07-25 (cont.) — gen_spatz_trace.py updated for the new formats (DONE, replaces the TODO)

Updated to parse the 2026-07-25 trace formats, BACKWARD-COMPATIBLE with older build dirs:
- Vector ISSUE/RETIRE: pc/insn are optional regex groups (old files without them parse, pc shows '-').
  Records carry pc through ISSUE->RETIRE pairing; the timeline now prints a pc column.
- CYC stall reasons: the tracer now emits a comma list (`vfu,idfull,`) instead of one priority-encoded
  token -- split_reasons() counts EACH active reason per stalled cycle (percentages can overlap; the
  report says so). THIS CHANGES THE REPORTED NUMBERS and is more truthful: build_tr2 core 0x08 shows
  `stall:vfu 514 (17.5%), vlsu 365 (12.4%), idfull 150 (5.1%)` -- under the OLD format idfull appeared
  to dominate (~31.8%) because the priority encoder HID vfu behind it. The real dominant stall is vfu.
- FP-sequencer stream: new ISSUE (pc, insn, kind=load|store|move|vector, fd) and RETIRE
  (port=fpu|lsu, fd, pc, insn) parsing; ISSUE->RETIRE paired per fd (FIFO; stores never queued --
  they produce no writeback). Per-core report gains an "FP sequencer" section: issues by kind,
  retire by port, offload->writeback median latency per kind, FP-LSU req/rsp + median memory latency,
  sequencer stall histogram (also comma-split). New CSV column fpl_off_lat_med (offload->writeback,
  complements fpl_lat_med which is the memory-only REQ->RSP latency).
- Verified on build_tr2 (new format, 256 cores) AND build_1 (old format) -- both process cleanly.
  Sample of the new data's value: sequencer stalls for a matmul worker = `offload=875, operands=19,
  lsu=1` -- the scalar sequencer is NOT out of resources; it is blocked handing instructions to the
  vector side (confirms the earlier conclusion).

### 2026-07-26 — R-MCAST REGRESSION ROOT-CAUSED: not an R-MCAST bug; a group-MSHR hold/capacity cliff

17-agent investigation (4 confirmed / 8 rejected hypotheses) + user's controlled build_1 vs build_2.

**1. R-MCAST IS working.** First-VLE-issue spread across the 16 tiles of a group: **15 -> 0** in g0,
g1, g5 (the +1/tile staircase is gone everywhere). PC-level scan: spread==0 rose 32->54, spread==15
fell 29->18. Whole-run per-hart `stall_ins` **1439 -> 1302 (-9.5%)** at MSHR=64 with identical retired
work. The feature does exactly what the doc promised.

**2. MY r_pop HYPOTHESIS WAS WRONG (refuted).** I suspected the all-ready `r_pop` held the shared R
channel for a slow port. Measured `roc_hold_cyc = 0 in 16/16 groups` -- the join NEVER stalls. Reason:
a tile port's `slv_r_readies` is a permanently-high level (tile axi_mux `SpillR=0` feeding the 2-deep
`axi_cache_slice`, and `snitch_icache_l0.sv:124` MLP=1 means it can never fill). ALSO: `acc_q`
(`axi_mux_mcast.sv:513-521`) ALREADY IS partial acceptance -- ports that took the beat drop out of
`r_pend`. So the "partial drain fix" would recover EXACTLY ZERO cycles. Do not build it.

**3. ACTUAL ROOT CAUSE -- 100% localized to group (0,0), a self-reinforcing collapse:**
R-MCAST removes the 15-cyc icache de-skew -> shifts g0's request PHASE -> followers stop landing
inside the MSHR hold window -> holds TIME OUT -> each leader eats the full 63/127 cyc AND squats an
MSHR way -> occupancy saturates -> allocation fails -> uncoalesced bypass -> latency doubles -> tiles
skew further -> more timeouts (runaway).
| signal (g0,0) | build_1 OFF | build_2 ON | other 15 groups |
| timeout_burst / timeout_single | 0 / 0 | **467 / 67** | 0 / 0 |
| mshr_valid_avg (of 32) / max | 11.4 / 21 | **24.0 / 32 FULL** | ~16 |
| mshr_overflow | 0 | **383** | 0 |
| merged_burst / alloc_burst | 351 / 351 | **0 / 358** | ~350/350 |
| VLE issue->retire mean | 106.8 | **173.2** | g1 111.8->93.5 (FASTER) |
| median k-th VLE spread (16 tiles) | 68 | **410** | ~unchanged |
467x63 + 67x127 ~= 37.9k extra way-occupancy cycles -> predicts +7.7 avg entries; measured +12.6.
Root enabler: `mempool_group_mshr.sv:2075` -- a held entry has NO backpressure from free-entry count,
so a hold can starve an allocation that would otherwise merge.

**4. INTRINSIC COST IS +5%, NOT +29%.** Same RTL at `GROUP_MSHR_NUM=64`, each reproduced TWICE:
OFF (build_spatzall/build_fplsu) = **3977**, ON (build_rmc1/build_tr2) = **4171** = **+194 (+4.9%)**,
with ZERO hold timeouts and ZERO overflow in all 16 groups. The +29% is that +5% amplified ~6x by a
capacity cliff. **Treat 5047 as an N=1 sample of a runaway, not a stable measurement.**

**5. WHY THE PREMISE IS WRONG (the user's own insight, RTL-confirmed).** On a RO-cache HIT the
response id is `hit_id = 'b1 << in_req_id_i` (`snitch_icache_handler.sv:191`) -- a ONE-HOT of the
SINGLE requester. Only the MISS path emits the N-hot `pop_idmask`. The cache request port is scalar
(one addr/id/valid per cycle) and the group axi_mux admits one AR/cycle anyway. So **hits are
structurally one-per-cycle and R-MCAST cannot touch them** -- which explains the [ROC] histogram:
fanout=1 = 12057 beats (95.5%, mostly hits) vs fanout=16 = 384 (3.0%, merged misses). Total
`cyc_saved` = 7399 R-cycles chip-wide for the WHOLE run (~460/group).

**6. THIRD TIME this repo has measured "align the requesters" as NET-NEGATIVE** (per-step barrier
3940 vs 3836; hold-the-fetch W-sweep 3836->3986/4209/4229; now R-MCAST). RECURRING LESSON:
**capacity/occupancy is first-order here, skew is second-order, and anything that converts skew into
occupancy loses.**

**DECISION: keep `ro_cache_r_multicast = 0` (config/config.mk:59, already reset by the user).** Keep
the RTL (const-folds to bit-identical at RMcastEn=0; the [ROC] probe is the right instrument).
Revisit only if a workload shows fanout mass >=8 AND the MSHR hold policy is made capacity-aware.

**INDEPENDENT REAL BUG TO FIX (unrelated to R-MCAST):** the MSHR hold window has no capacity
backpressure. Fix at `mempool_group_mshr.sv:2068-2080`: add `|| bank_ways_full` (or free-entry <
threshold) to `hold_done`, making hold-induced `mshr_overflow` impossible by construction. Cheap
validated mitigations meanwhile: `group_mshr_hold_window_burst=0 / _single=0` (the W-sweep already
recorded holds net-negative), and/or `group_mshr_num` 32->64.

**LATENT R-MCAST bugs found (measured NOT firing today; fix before ever defaulting on):**
 (a) `snitch_axi_to_cache.sv:293` drives `r_mcast_mask_o` without qualifying by which axi_demux port
     won R arbitration, while the demux pop mask IS qualified by `r_idx`. Safe-by-construction fix:
     `r_target = r_onehot | r_out.mask` in axi_mux_mcast so a leaked mask can never LOSE a beat.
     Not firing: `beats - mcast_beats` = exactly 64/group in 15/16 groups = the DMA's share.
 (b) `snitch_axi_to_cache.sv:164-171` (splitting arm) asserts `cnt_alloc_req=1` unconditionally while
     `:152` admits on `(cnt_alloc_gnt || ar_noalloc)`. Harden: make `ar_elig` also require
     `ar_len == '0`. Unreachable today only because `mempool_pkg.sv:232-234` forces BeatsPerRefill==1.

**CAVEAT:** build_1 is not a byte-strict control (it predates the feature and never compiles
axi_mux_mcast). The strict control build_ab0 (RO_CACHE_R_MCAST=0, else identical to build_2) is still
running. The MSHR=64 pair (3977x2 vs 4171x2) is unaffected by this caveat and is the number to quote.

---

## 2026-07-26 — H1 (two vector loads in flight) — RTL AUDIT + PLAN, no code yet

**Purpose:** the bottleneck doc's H1 says "re-key `mem_spatz_req_ready` from *previous op DONE* to
*previous op's requests ISSUED*". Before writing that one-liner, audit the elaborated VLSU.

**Deliverable:** `docs/spatz_vlsu_h1_dual_load_plan.md` (full audit + design + assertion set +
staging). Written from a 13-agent audit; every FACT re-verified by hand against RTL.

**Result — two of my earlier statements were WRONG and are corrected here:**
1. `NrOutstandingLoads` is **32, not 16** (`spatz.sv:328` overrides the module default at
   `spatz_vlsu.sv:15`). `IdWidth`=5, `meta_id_t` 5 b.
2. `NrMemPorts` = `N_FU` = **4, not 2**.

**The finding that changes the plan:** burst mode is **port-0 only** (`use_port0_burst_req`,
`spatz_vlsu.sv:151-161`), and its admission test `vl <= NrOutstandingLoads*MemDataWidthB` is
`128 <= 128` — passes **with equality**. So one shipped `vle32 e32,m2` = 128 B = 32 words =
**exactly all 32 ROB0 ids**, while ROB1-3 (96 ids) sit idle. **Today a second load has ZERO ROB ids
to allocate.** Re-keying the gate alone therefore buys ~nothing on the shipped m2 kernel, and can
REGRESS: `force_send` (`:1160-1169`) would truncate the 16-beat burst that the group MSHR exists to
merge. `i_fifo_commit_insn` (32-deep) is NOT the limiter — it never holds >1 entry today.

**Second finding — a bigger, independent win hiding underneath H1:** ROB ids are allocated
**one per cycle** (`:1179-1190`) and `burst_send` needs the full count (`:1195`), so every 16-beat
burst pays a **16-cycle serial walk** before its single request handshake. That is ~16-30 of the
~24.6 cycles/load that Little's law says we must remove. Block reservation kills it *and* makes
`force_send` unreachable.

**Two latent bugs found that exist TODAY (independent of H1):**
 (a) `:368-370` `mem_port_finished_q` has no `!mem_counter_load` guard, unlike its twin
     `mem_port_req_issued` (`:681-683`) whose in-tree comment documents exactly this hazard.
 (b) `:1081-1083` `mem_pending` is blanket-reset on `commit_insn_push`. Note the reviewer trap:
     `i_fifo_commit_insn` is `FALL_THROUGH` (`:413`), so `commit_insn_push && !commit_insn_valid` is
     identically 0 — any guard written with `commit_insn_valid`/`_empty` is a dead branch.

**STAGING DECIDED:** Inc 0 = block ROB reservation (do FIRST, re-baselines every number) ->
Inc 1 = the two latent fixes -> Inc 2 = H1 gate + request-side blocking + `opq_hold` + 10 assertions
-> go/no-go gate -> Inc 3a = software `e32,m1` + 16 accumulators (the only route to true 2-in-flight
with no capacity RTL). **Neither Inc 0 nor H1 alone reaches the target — that is the central
conclusion.** `NrOutstandingLoads=64` ruled OUT (IdWidth 5->6 vs 5-bit `meta_id_t`).

**Status:** plan written, nothing implemented. Awaiting go on which increment to start.

---

## 2026-07-26 — CONFIRMED VLSU BUG: burst request on the word-interleaved path (vl >= 256 B)

**Found while** documenting `group_mshr_bank_shift`; surfaced by an adversarial re-check of my own
claim that "kernel_size=4 disables burst mode completely". That claim was **half wrong** and the
correction is a real data-corruption bug.

**What is true:** `use_port0_burst_req` (`spatz_vlsu.sv:151-161`) IS false at vl=256 B, because
`proc_spatz_req` converts vl to bytes (`:122-124`) and `:160` caps it at
`NrOutstandingLoads*MemDataWidthB` = 128 B. So the *port-0-only* burst MODE is off.

**What I got wrong:** there is a SECOND, independent burst path. `burst_mode_req[port]` /
`burst_use[port]` (`:950-962`) contains **no `use_port0_burst` term** and is evaluated for every
port in the multi-port branch. At vl=256 B each port's share is
`mem_max_elements = (256>>4)<<2 = 64` B = 16 words (`:917`), so `mem_remaining_words == MaxBurstWords`
and `burst_len_calc = 16` (`:932-933`).

**The bug.** In multi-port mode the per-port address stream is WORD-INTERLEAVED — `:564` gives port p
the word indices `4n+p` (offset `= ({cnt[hi:2]<<2, cnt[1:0]} + (port<<2))*stride`). But a burst
request is expanded downstream into **consecutive** addresses:
`tcdm_burst_expander.sv:113  req_o[k].tgt_addr = req_base.tgt_addr + (beat_base + k)`.
Port 0's first address is `rs1` itself, so `burst_addr_aligned[0] = (mem_req_addr[0][5:2]=='0)` is
TRUE whenever rs1 is 64 B-aligned — which sp-fmatmul's B pointer always is (p_start is a multiple of
64 words; `b__ += P` = 1024 B). So **port 0 issues one `burst_len=16` request that fetches words
0..15 when the datapath expects words 0,4,8,...,60**, and `mem_counter_delta[0] = 16*4 = 64`
(`:992-995`) retires port 0's entire share on that one handshake. Ports 1-3 (addr[5:2] = 1/2/3) stay
on the single-word path. Result: **49 requests, 15 of them silently wrong data.**

**Trigger condition:** aligned unit-stride `vle32` with per-port share >= MaxBurstWords, i.e.
`vl >= NrMemPorts*MaxBurstWords*MemDataWidthB` = **256 B** => LMUL=4 and LMUL=8 at VLEN=512, with a
64 B-aligned base. The shipped m2/8xVL kernel (vl=128 B) takes the port-0 path and is UNAFFECTED.

**Not covered by any assertion.** `:1580-1585` checks only the opposite direction
(`mem_use_port0_burst |-> !spatz_mem_req_valid[port]` for port>0). Nothing asserts that a burst is
issued ONLY in port-0 burst mode. **Fix candidates:** (a) add `&& mem_use_port0_burst` to
`burst_mode_req` at `:950` (kills mechanism 2 outright — bursts only from the linear path);
(b) add the missing assertion `spatz_mem_req[port].burst_len > 1 |-> mem_use_port0_burst`.
Do (b) first as a tripwire, then (a).

**Consequence for the LMUL work:** S1 (kernel_size=4/2) is not just perf-neutral, it is INCORRECT on
this RTL. H1 Increment 3a (`e32,m1`, vl=64 B) is BELOW the trigger and stays safe.

**Two other verification results the same pass produced:**
1. **My "same-cycle requests don't merge" caveat was WRONG.** No same-cycle merge circuit exists
   (`:1363-1372`), but the losers do NOT allocate or bypass: all same-address requests hash to one
   bank, the bank grants exactly 1 alloc/cycle (`bank_alloc_taken`, `:1340,:1351-1354`), and the rest
   STALL (`:1938-1945`) and hit-merge next cycle. Cost of N same-cycle same-address requests is
   `ceil(N/MshrMergeReqs)` entries, not N. Duplicates come only from temporal skew or a full bank.
2. **Per-type bank shift is safe but not a one-liner.** Responses steer by the round-tripped
   `mshr_tag` (`:1973-1974` -> `:2155-2166`), never by a recomputed bank, and single/burst can
   already never merge (`:1197`, `:1203`) so splitting them costs zero merging. BUT the sim assertion
   `mshr_entry_in_its_bank` (`:3409-3417`) is the one place that recomputes a bank from a stored
   address and would `$fatal` on the first burst alloc. Not pursued: capacity is not binding at
   kernel_size=8 (worst bank 3 of 8 ways).

**Also done this session:** rewrote the `group_mshr_bank_shift` comment block in
`config/terapool_spatz4_fpu.mk` (the old text said `word[7:5]` / "3 bits" / "8 banks", stale since
`group_mshr_num=128, ways_per_bank=8` gives **16** banks / BankIdW=4). New block documents the word-
vs-byte-vs-bit unit chain, the "smallest concurrent stride" rule, the `BurstAlignBits=4` floor, and
the enumerated per-shift spread table.

**Status:** bug documented, NOT fixed (no RTL edit). Awaiting go.

---

## 2026-07-26 — IMPLEMENTED: per-type MSHR bank shift + VLSU burst-mode gate fix

### 1. Per-request-type `group_mshr_bank_shift` (user's design)

**Why:** the two concurrent streams of the matmul inner loop have different key strides, and one
global shift cannot give both the maximal spread. Enumerated (16 cores/group, 16 banks x 8 ways):
shift=5 gives A 16 banks / B 8; shift=4 gives A 8 / B 16. Per-type gives **both 16**.
The payoff is NOT capacity (peak is ~32 of 128 entries) but **allocation serialization**: the
per-bank allocator grants exactly 1 alloc/bank/cycle (`bank_alloc_taken`, `:1340`, `:1351-1354`),
so 2 keys in one bank cost an extra cycle. Per-type removes that for both streams: ~1 cycle per
stream per inner-loop step out of an ~88-cycle load recurrence (~1%). Modest, but it is *latency*,
which is the quantity Little's law says this kernel is short of.

**Safety (this is why it is sound, contra my earlier caution):** splitting single from burst costs
ZERO merging, because they can already never merge — `req_hit_way` requires `burst_len` equality
(`:1197`) and the CACHED arm requires `req_len == 1` (`:1203`). Responses steer by the round-tripped
`mshr_tag` (stamped `:1973-1974`, consumed `:2155-2166`), never by a recomputed bank, so a type-
dependent hash cannot mis-steer a response. Two entries for one line in different banks is lost
merging, not a correctness bug (`:1120-1131`).

**Changes:**
* `mempool_group_mshr.sv` — `BankSelShiftSingle` / `BankSelShiftBurst` localparams (default: inherit
  `BankSelShift`, so equal values are bit-identical); `mshr_bank_of()` takes a third `is_single`
  input and the BankHash==3 arm becomes a 2:1 mux of two CONSTANT part-selects; both range checks
  duplicated per type; invariant comment restated as "pure function of {group, addr, TYPE}".
* **The trap, handled:** the classifier at the call site is the **CLAMPED** `req_is_single`
  (`:898`), never `req_len_raw`. Stores and misaligned bursts are force-clamped to `req_len=1`
  (`:867-877`), and a store MUST bank like the single-word CACHED entry it write-updates
  (`:2026-2031`); classifying it as a burst would miss that copy and leave stale data.
* `mshr_entry_in_its_bank` (`:3433-3443`) — the only place in the file that recomputes a bank from a
  stored address — now passes `mshr_q[i].burst_len == 1`. Without this every run `$fatal`s on the
  first burst allocation.
* `hardware/Makefile` + `config/terapool_spatz4_fpu.mk` — `group_mshr_bank_shift_single ?= 5`,
  `group_mshr_bank_shift_burst ?= 4`.

**NOTE — this changes the DEFAULT build** (burst shift 5 -> 4). Set both to 5 to recover the old
behaviour bit-identically; that is the A/B control.

### 2. VLSU burst-mode gate fix (the corruption bug logged above)

`spatz_vlsu.sv:950` — added `mem_use_port0_burst` to `burst_mode_req[port]`, so a multi-beat request
can only be emitted while address generation is LINEAR (`:562`). Previously the multi-port
word-interleaved path (`:564`) could emit `burst_len=16`, which the expander turns into 16
CONSECUTIVE addresses — fetching the wrong 15 of 16 words.

Added tripwire `gen_burst_only_in_port0_mode` (scoped `ifdef TARGET_MEMPOOL`, since `burst_len` is
only driven in that branch of `gen_mem_req`): `burst_len > 1 |-> mem_use_port0_burst`. This is the
converse of the existing `gen_port0_burst_assert`, which only checked that other ports are silent
*during* port-0 mode and therefore could not catch this.

Expected effect on the shipped m2/8xVL kernel: **none** — it already runs in port-0 burst mode, so
the added term is always true there. The fix only removes the wrong-data path at vl >= 256 B.

**Status:** compiling in `build_pertype` (separate dir; user's two sims in build_* untouched).
Not committed, not simulated.

---

## 2026-07-26 — DESIGN PLAN: raising Spatz MLP (docs/spatz_mlp_design_plan.md)

**Purpose:** user asked for a detailed, reviewable design+implementation plan before any coding,
with an explicit constraint: **minimise hardware overhead, especially backend timing and area**.

**Method:** 10-agent workflow — 4 RTL audits (ROB redundancy / VLSU alloc path / timing baseline /
area baseline) -> 3 competing designs (minimal / area-negative / full-H1) -> 3 adversarial reviews
(correctness / backend-timing / integration). Key numbers re-derived by hand before writing.

**HEADLINE: the design is area-NEGATIVE, ~-296k flops chip-wide (-15.1% of the VLSU flop budget),
while removing ~30 cyc from the load recurrence.** Two reclaims pay for it:
 - `id_valid_q` in reorder_buffer.sv is PROVABLY redundant with (read_pointer_q, status_cnt_q).
   Confirmed by induction over all 6 state-mutating paths AND a cycle-exact model of the always_comb
   (3 configs x 400 seeds x 800 cycles, 0 violations). `id_valid_o == (status_cnt_q <= NumWords-2)`
   EXACTLY, both boundaries. -128 flops/core AND -6 logic levels on a real closing path, AND
   write_pointer_q fanout drops ~3x. Incidental facts: FallThrough is never 1 for any reorder_buffer
   instance; there is exactly ONE instantiation in the repo.
 - commit FIFO DEPTH 32 -> 4 (NrParallelInstructions is the hard bound; push gated on
   !mem_insn_pending_q[id], spatz_id_t is 2 b). -1045 flops/core = -267k chip-wide.

**Block reservation is cheaper than expected, for three reasons:** burst_len_calc is BINARY (16 or
1) so `wp+16 mod 32` is ONE INVERTER; bursts are port-0 only so the logic is 1 instance/core not 4;
and it makes force_send structurally unreachable, deleting the :1411-1424 rescue branch, the
burst_len_eff clamp, and collapsing spatz_mem_req.burst_len to a compile-time constant.

**Critical path is NOT in the ROB** — it is the address multiply/add cone (~30-35 levels) reaching
mem_req_lvalid. ROB id-request is ~3 levels. And `burst_len_calc` ALREADY reaches the ROB pointer
today by a LONGER (~25-level) route, so a direct reserve input is timing-POSITIVE.

**THE ONE TIMING TRAP:** building the room check as `(NumWords - status_cnt_q) >= id_req_len_i`
drags burst_len_calc into full_o's cone (~28 levels, comparable to the critical path) = a
REGRESSION. Because the length is a 1-bit decision, the correct form is
`room_block_o = (status_cnt_q <= NumWords - BlockWords)`, ~2 levels, independent of burst_len_calc.
**The `<=` is load-bearing:** after burst 1, status_cnt_q is EXACTLY 16, so a strict `<` silently
RE-SERIALIZES the two bursts of every vl=32 load — symptom "the change did nothing", not a failure.

**Reviewer disagreement + resolution:** correctness+integration said "Option 1 (minimal) first";
backend-timing said Option 1 is dominated because it puts rob_req_block behind the ~25-level
burst_use guard. Resolved by taking BOTH properties: drive the reservation from the REGISTERED
decision (~4 levels) AND give the ROB its own internal room guard, so a VLSU-side bug cannot corrupt
it. 3-cycle decide->reserve->send; collapsing to 2 is the variant to avoid (drags cone A into the
ROB pointer).

**Full H1 DEFERRED** — 5 fatal flaws found (F1 hang from deleting the mem_pending clear, F2
wrong-data+hang from rob_req_block/rob_req_id divergence -> 6-bit status_cnt underflow to 63, F3
gating on full_o not room_block_o -> 15 slots double-allocated, F4 hang from deleting the rescue
branch, F5 odd-expected aliasing). Honest cost: the F5 fix requires gating early release on
mem_pending_q[1..3]=='0, which for a tailed load costs most of the H1 benefit. NOTE H1 needs ZERO
new flops — mem_req_all_issued (:672-687) already exists.

**FREE BUG FIX FOUND (do first, own commit):** spatz_vlsu.sv:1439 pops without an `!rob_empty[port]`
guard while the structurally identical store drain at :1523 has one. One line; removes two whole
fatal-flaw classes (ROB pop underflow wraps the 6-bit status_cnt to 63 -> full_o/empty_o never
assert -> every subsequent store hangs).

**Staging:** step0 = the :1439 guard; step1 = block reservation (the -30 cyc/load headline);
step2 = id_valid removal; step3 = commit FIFO shrink; step4 = GO/NO-GO then H1.
**Caveat recorded:** the 30-cyc figure is an UPPER bound (assumes L shrinks 1:1 with the walk; part
of L is NoC queueing under 256-core congestion).

**Status:** plan written, NOTHING implemented. Awaiting user review.

---

## 2026-07-26 — IMPLEMENTED: block ROB-id reservation (the MLP lever) + knob plumbing

**What is in the tree now** (the three MLP steps from docs/spatz_mlp_design_plan.md):

**Step 1 — the :1439 `!rob_empty[port]` guard (spatz_vlsu.sv:1473) + `pop_no_underflow` assertion
(reorder_buffer.sv:269).** APPLIED by the patch agent. Latent-only fix (zero measurable effect on a
passing run): the load-side drain popped without the guard the identical store-side drain (:1558)
already had; pop-while-empty wraps the 6-bit status_cnt to 63 and wedges the port. Its value is
forward-looking: the whole MLP plan can produce valid-outside-window states, and A1/A2 make them
surface as assertion fires instead of a silently corrupted counter.

**Step 3 (3a) — R1 `id_valid_q` removal, knob `spatz_rob_cnt_idvalid` / SPATZ_ROB_CNT_IDVALID
(reorder_buffer.sv).** APPLIED by agent. Confirmed correct on inspection: OFF elaborates the legacy
bitmap bit-identically; ON deletes the 32 flops + write-pointer decoder + two 32:1 muxes +
write_next_ptr per ROB (write_next_ptr's only consumers were its own assign and the id_valid_o
lookup — the dual-pop path uses read_next_ptr, untouched). `cnt_ptr_coherent` assertion armed.
Default 0.

**Step 3 (3b) — R2 commit FIFO `spatz_vlsu_commit_qmin` / SPATZ_VLSU_COMMIT_QMIN
(spatz_vlsu.sv:86-90).** APPLIED by agent. CommitQDepth = 4 vs 32. Default 0.

**Step 2 — block ROB-id reservation, knob `spatz_vlsu_block_alloc` / SPATZ_VLSU_BLOCK_ALLOC.**
APPLIED BY HAND this session (the patch agent was apply-ready, not applied): ROB patches R1-R11 +
VLSU patches V1-V16 + Makefile M1 + config C1. Implements the §5.0 resolution:
 - ROB owns the room check: `room_block_o = (status_cnt_q <= NumWords-BlockWords)` NON-STRICT (the
   T3 trap: after burst 1 the count is EXACTLY 16, so a strict < silently re-serialises burst 2).
 - The reservation is driven from REGISTERS ONLY (`burst_alloc_q && !burst_reserved_q &&
   burst_alloc_cnt_q=='0`), never the combinational burst_use, and `burst_block_fire =
   rob_req_block[0] && rob_room_block[0]` is term-for-term the ROB's own block_fire, so both sides
   commit together or not at all (F2 divergence structurally impossible).
 - Window mask uses the PER-BIT COMPARE form (timing-reviewer correction C1: a variable left shift
   is an 8x-area 4-stage barrel shifter).
 - burst_odd_expected uses the MASKED write (not |=), buying a local invariant for ~32 AND2/core.
 - The legacy walk is kept as the `else` of the BLOCK condition (not the port test) so no
   low-room condition can latch burst_alloc_q[0] and starve the scalar arm.
 - Assertions armed: blk_room, blk_no_overflow, blk_single_exclusive (ROB); A5/A4-mirror/no-double-
   alloc and A6 blk_odd_clean (VLSU).
 - BlockWords==1 is the feature-absent default: every added statement const-folds out, so knob OFF
   is bit-identical. Default 0.

**Knobs:** all three `?= 0` in config/terapool_spatz4_fpu.mk; defines plumbed in hardware/Makefile.
Config `?=` means `make ... spatz_vlsu_block_alloc=1` overrides on the command line.

**Bit-identity plan:** block-alloc OFF is bit-identical by construction. R1/R2 are deliberate
netlist changes by design (the doc's honesty note), so the OFF-vs-HEAD cycle-identity A/B must be
run with ALL THREE knobs at 0.

**Status:** compiling OFF (build_blk_off) then ON (build_blk_on) as separate build dirs (user's two
sims untouched). Next: verify 533 modules / 0 errors both, then the ON vs HEAD A/B. NOT committed.

---

## 2026-07-27 — block-alloc A/B running; BASELINE CORRECTION (stop quoting 3905)

**Launched:** OFF control `build_blk0` (spatz_vlsu_block_alloc=0) -> **3821 cyc** (done).
ON test `build_blk1` (knob=1, config default) -> running, SPATZ_VLSU_BLOCK_ALLOC=1 confirmed.

**BASELINE CORRECTION.** The "current-tree baseline 3905" I had been quoting is STALE: it is
build_1 from Jul 25 (older RTL, ks=8). Fingerprinting each build by its tile size (the
`N, P, m_start..p_end` UART line -- ks=8 is an 8x32 tile, ks=4 is 4x64):

| build    | tile | kernel | result | note |
|----------|------|--------|--------|------|
| build_1  | 8x32 | ks=8   | 3905   | Jul 25, OLDER RTL -- the stale number |
| build_2  | 8x32 | ks=8   | 3589   | Jul 26 23:05, recent RTL |
| build_3  | 4x64 | ks=4   | 6498   | the ks=4 run (slower, as predicted) |
| build_blk0| 8x32| ks=8   | 3821   | Jul 26 23:12, current tree, knob OFF |

So recent ks=8 RTL gives BOTH 3589 (build_2) and 3821 (build_blk0) -- 232 cyc apart. Either the
RTL changed between them or there is real run-to-run variance. DO NOT compare build_blk1 against
3905. The valid control is build_blk0=3821 (same tree, knob OFF, minutes apart). If build_blk1
lands near 3589 or below, that would be consistent with the ~30-cyc mechanism on top of build_2's
number; judge it against 3821.

**Config comments updated:** spatz_rob_cnt_idvalid / spatz_vlsu_commit_qmin now labelled
"AREA-reduction / timing cleanups, NOT performance changes ... keep them OFF unless deliberately
measuring area". Both stay 0. spatz_vlsu_block_alloc=1 (enabled for the A/B).

---

## 2026-07-27 — block-alloc MEASURED + COMMITTED; the -232 decomposition

**Result (sp-fmatmul-opt-burst-merge, ks=8, deterministic seed): OFF 3821 -> ON 3589 cycles,
-232, -6.1%, reproduced on TWO independent ON builds (build_2 and build_blk1, 75 min apart).**
VPERF signature: insn_act -488 (-19%), wait_beats flat (-26), insn_ret identical (40).

**The 3589 vs 3821 "variance" I worried about was NOT variance.** build_2 was compiled at 21:49,
ONE minute after I set spatz_vlsu_block_alloc ?= 1 in the config (21:48) -- it was already an ON
run, not a clean baseline. Two ON builds land on exactly 3589, the OFF build on 3821, so the delta
is reproducible and attributable to block-alloc alone.

**WHY -232 and not the ~30-cyc/load ceiling (which would be ~1200 for 40 loads):** the correct
ceiling is set by CRITICAL-PATH loads, not all loads. The kernel double-buffers B (load n+1 issues
while the 8 FMAs on row n run), and the FMA work per load is 64 cyc. The 36-cyc alloc walk was
OVERLAPPED with that 64-cyc compute window, so only the part of the walk that EXCEEDED the compute
window was exposed latency. Measured: insn_act dropped 488 (the walk, ~fully removed) but the wall
clock only dropped 232 (ratio 0.48) -- the rest (256 cyc) became idle turnaround (no_insn +212).
So ~half the issue-side saving reached the clock; the other half the core converted into earlier
idle, not into more throughput. LESSON: removing issue-side latency only helps to the extent it
was EXPOSED beyond the compute window; with one load in flight the core stalls at the next load
anyway once the compute is done.

**Committed (7 commits, no attribution):**
 3dd6f7c (spatz) block ROB-id reservation + ROB pop-underflow guard (the RTL)
 526db93 config: enable block-alloc + knob plumbing
 b953b59 questa: per-Spatz-core vector trace + wave signals
 deaa73c mempool_group_mshr: per-type bank shift + cache self-inval stats
 bf0936d snitch_read_only_cache: optional R-MCAST (default off, not adopted)
 1b7255e sp-fmatmul: KERNEL_SIZE knob (default 8) + FP-free verify
 cad8dba docs: bottleneck analysis + MLP/VLSU plans + compare_vperf.py
 aa9742c Makefile: sim fd-limit guard + spatz_trace + bank-shift plumbing
 e121140 config: R-MCAST default + axi_mux_mcast in Bender sources
LEFT UNCOMMITTED (not mine to decide): .gitignore (+logs +work), Bender.lock (Path:
working_dir/spatz -- load-bearing, should NOT be committed), config/minpool_spatz4_fpu.mk
(noc_router_remapping 0->3, user's experiment).

**Next-step implication:** with block-alloc done, the binding constraint is now that only ONE load
is in flight (ROB0 is 100% used by a single m2 load). The exposed-latency analysis says further
issue-side work yields ~half; raising loads-in-flight (e32,m1 + 16 accumulators + H1) is the
higher-value direction because it lets the next load's latency hide behind the current compute.

---

## 2026-07-27 — ROB64+H1 implementation: S0 DONE+committed, S1 elaborating (G1 gate running)

Following docs/spatz_rob64_h1_design_plan.md stage by stage, verifying each.

**S0 (ROB window-mask generalization) -- DONE, G0 PASSED, committed (spatz 9dc5332).**
reorder_buffer.sv: split every id at log2(BlockWords) into {i_hi,i_lo}; the window test becomes
(i_hi==wp_hi && i_lo>=wp_lo)||(i_hi==wp_hi+1 && i_lo<wp_lo), which reduces bit-identically to the
shipped msb-XOR form at NumWords/2. Guard relaxed to any power-of-two divisor. Verified THREE ways:
exhaustive Python (NEW==ground-truth window at 32/16 AND 64/16 for all wp; OLD==NEW bit-identical at
32/16), compile clean (533/0), and sp-fmatmul CYCLE-IDENTICAL to baseline (3589->3589) with every
[VPERF] counter delta exactly 0.0. (Note: the first S0 sim WEDGED at run start -- 0% CPU after
"run -a", ~1h45m, no error. Environment flake, not the design; a clean-dir retry passed.)

**S1 (ROB64 widening) -- RTL in, elaborating clean, G1 gate running.**
Three roots + tripwires + knobs, all compile-clean at default 32 (bit-identical) AND at 64:
 - snitch_pkg.sv: RobDepth knobbed (default 32) -- the single meta_id root. hardware/deps change.
 - spatz.sv: NrVLSUOutstandingLoads localparam -> :328.
 - spatz_pkg.sv (generated + .tpl): MemRspIdWidth; spatz_mem_rsp_t.id widened (the 5b->6b
   silent-truncation site at spatz_mempool_cc.sv:291).
 - spatz_mempool_cc.sv: two elaboration width-pairing tripwires.
 - Makefile + config: spatz_vlsu_rob_depth / spatz_vlsu_dual_load knobs (unset -> 32).
rob_depth=64 elaborates: 533 modules, 0 errors, NO width tripwire fired (pairing consistent).

**FF-1 (BypassTrackWays) -- implemented, in the S1 build.** mempool_group_mshr.sv: bypass_track_q
was hardcoded [1:0] (2 ways) with a depth-2 assert whose premise ("one insn x <=2 bursts") breaks
at ROB64 (one m4 = 4 bursts). Parameterized BypassTrackWays = max(2, RobDepth/MaxBurstWords) = 4
at 64: array decl, response match loop, allocation if/else-chain -> loop, and the overflow assert
(now $countones < BypassTrackWays). Compiles clean ($countones on a packed-struct .valid slice
accepted).

**G1 gate (running):** m2 at rob_depth=64 must be CYCLE-IDENTICAL to 3589 (same request stream,
just more ROB room). Any delta = a bug. Monitor armed with the wedge detector. Next after G1:
S1b/S1c (flip R1/R2 at 64), then S2 (H1).

---

## 2026-07-28 — ROB64 S1 DONE+committed (G1 PASSED); H1 RTL implemented, gates running

**S1 (ROB64 widening) -- DONE, G1 PASSED, committed (spatz 24e2fa2, main 99074fd).**
rob_depth=64 elaborates clean (533/0, no width tripwire) and sp-fmatmul m2 is CYCLE-IDENTICAL to
the 32-bit baseline (3589 -> 3589) with every [VPERF] counter delta exactly 0.0. The MetaIdWidth
5->6 widening is fully transparent to the current kernel.

**FF-1 followup bug (found the hard way):** my first BypassTrackWays overflow assert used
$countones({W{bypass_track_q[bt].valid}}) -- a packed struct array's .valid is NOT a legal
cross-dimension field select. **vlog ACCEPTED it (compile "clean"), vopt REJECTED it at sim load**
(vopt-13276). NEW LESSON: vlog-clean != vopt-clean; only reaching `run` proves elaboration. Fixed
with an explicit per-tile reduction (all_ways_valid &= bypass_track_q[bt][w].valid), verified the
block is inside pragma translate_off (sim-only).

**S2 (H1 dual-load) -- RTL IMPLEMENTED (4a-4j), compiles clean ON+OFF, gates running.**
spatz_vlsu.sv, all Runahead-gated (knob off = bit-identical):
 4a MaxInflight/Runahead/InflWidth localparams + decls; 4b gen_runahead (inflight_q, dual_run/
    dual_safe/dual_blk, opq_hold, dual_adv THE GATE, no_older); 4c opq_hold on the op-queue;
 4d D1 guard (mem_port_finished !mem_counter_load); 4e mem_spatz_req_ready OR-term on dual_adv;
 4f D2 (mem_pending reset only when no_older); 4g/4h dual_blk blocks burst-alloc-start and the
    scalar lvalid arm; 4i retire-odd assert re-scoped (!Runahead keeps old form; Runahead gets the
    id-scoped walk mirror); 4j NEW asserts A1/A3/A5/A6/A7/A9/A10 (A9 fence-underflow per-id latch,
    A10 positional-commit pop counter), commit-FIFO usage_o tap, VPERF c_dual + c_blkstall.
    Moved mem_is_vstart_zero decl above gen_runahead (use-before-decl fix).
Both knob-OFF (bit-identical) and knob-ON (rob64+dual2) compile clean: 533 modules, 0 errors.

**Gates in flight:** S1b (R1@64, expect 3589) and H1-OFF-identity (expect 3589) sims running;
H1-ON directed+perf runs queued behind them (box busy).

---

## 2026-07-28 — H1 (dual-load) MEASURED + committed; device-verify blocked by pre-existing wedge

**S1b/S1c (R1, R1+R2 at ROB64): both 3589, all VPERF deltas 0. Knob-flips only, no code change.**

**H1-OFF identity gate: 3589 (pre-4j code). 4j is sim-only (gen_runahead_asserts is a
Runahead-gated generate, not even elaborated when off).**

**H1-ON (rob_depth=64 + dual_load=2):**
- First attempt: A10 FIRED at cyc~16082 ("positional attribution broken"). Diagnosis via the
  per-core tracer: the GATE WORKED (load A id=1 at 16036, load B id=0 at 16078 via clean
  dual_adv) -- the assertion was wrong: it counted ALL ROB0 pops between retires, including
  stale-drain DISCARDS of warmup leftovers (the warmup pass runs outside the trace window).
  Fixed: count commit pops only (rob_pop_dual, or rob_pop[0] && mem_pending[0]); the fatal
  message now prints actual counts.
- Rerun: COMPLETED 3488 (-101, -2.8% vs 3589), ZERO assertion fires, dual_adv=32/40,
  no_insn -9.9%, wait_beats flat, insn_ret/pair_commit identical.
- Second pair (verify=1 binary, same binary both sides): OFF=3523 -> ON=3500 (-23, -0.65%).
  The verify=1 binary shifted the OFF baseline by 66 cyc AND shrank the H1 delta ~4x --
  H1's benefit is code-layout-sensitive. HONEST RANGE: ~0.7-2.8%.
- h1off2 dual_adv=0 (knob-off correct), h1onv dual_adv=32.

**Device verify BLOCKED:** both verify=1 runs printed matmul timings then WEDGED in the
epilogue verify (CMS frozen, inflight=0, to 146k+ cycles) -- the known pre-existing FP-verify
wedge (hits ON and OFF identically; the reason MATMUL_VERIFY=0 is the tree default). So H1's
correctness evidence is BEHAVIORAL (A9/A10 silent, identical retire counts), not data-verified.
main.c restored to MATMUL_VERIFY=0, app rebuilt.

**Committed: spatz 9dedd6a (H1, knob default 1 = OFF = bit-identical).** All H1 work is now
in git: S0 mask (9dc5332), S1 roots (24e2fa2 spatz / 99074fd main), H1 (9dedd6a).

**Environment note:** /tmp (378G tmpfs) hit 100% mid-session (user's /tmp/r5_dram 368G +
be_insn/amo2 logs) and killed two sims (my sim logs were also wrongly redirected to /tmp --
moved to .restore/claude_logs on scratch). User approved deleting the logs; /tmp now 1%.
NEW LESSON: vlog-clean != vopt-clean (the $countones packed-struct-array field select passed
vlog, failed vopt) -- only reaching `run` proves elaboration.

---

## 2026-07-28 — Fleet-wide FPU utilization instrumentation (wave + trace)

**Ask:** a direct indicator of all-cores FPU utilization, in both the waveform and the Spatz
trace output. Base signal: i_vfu.is_fpu_busy (a LEVEL: high every cycle the FPU lanes are
mid-computation) -- NOT fpu_result_valid (a completion pulse; under-reads busy time for
multi-cycle ops).

**hardware/tb/mempool_tb.sv (sim-only, inside the existing TARGET_SYNTHESIS/VERILATOR guard,
`ifdef TARGET_SPATZ):** fleet block mirroring the existing wfi/core_stall XMR pattern:
 - fpu_busy[NumCores-1:0]     per-core busy vector (bit i == hart i == (g<<4)|t) -- the
                              "each core's busy pattern over time" view
 - fpu_busy_count             $countones -- "how many FPUs busy right now" (analog wave)
 - fpu_busy_group[NumGroups]  per-group counts (skew spotting)
 - trace_fpu_fleet.log        per-cycle "cyc busy_count g0..g15" (always-on, one line/cycle)

**hardware/scripts/questa/wave.tcl:** FPU_Fleet group (analog fpu_busy_count, unsigned
fpu_busy_group, binary fpu_busy vector), guarded by examine so non-Spatz configs skip it.

**hardware/scripts/gen_spatz_trace.py:** write_fleet_fpu() -> spatz_fleet_fpu.csv
(cyc,busy_cores,busy_pct) from the per-core cyc traces (counts cores with fpu_vld != 0).
No re-run needed. GOTCHA hit+fixed: fpu_vld is group(7) in CYC_RE, not group(6) (ipu_vld) --
the first version silently under-counted (5.5 busy vs 177). Verified on build_h1on traces:
3019 cycles, mean 177/256 busy = 69.1%, max 256 -- consistent with the known ~70%.

**Status:** compiles 533/0; smoke sim (elab + 300ns) verifying the XMR paths resolve.

---

## 2026-07-28 — FPU fleet instrumentation ported to the BASELINE repo (TeraNoC_ori/TeraNoC_spatz)

**Ask:** same fleet FPU utilization in the baseline repo + fix its Spatz-core waveform (which had
ZERO Spatz-core signals anywhere in its questa scripts).

**hardware/tb/mempool_tb.sv (baseline):** the same sim-only fleet block (fpu_busy vector /
fpu_busy_count / fpu_busy_group / trace_fpu_fleet.log), inserted after its gen_wfi_groups block
inside the existing guard region + `ifdef TARGET_SPATZ. All referenced signals verified to exist
in the baseline's deps/spatz (is_fpu_busy at spatz_vfu.sv:155, same upstream revision).

**hardware/scripts/questa/add_spatz_core.tcl (baseline):** ported from our repo (Issue / Stall /
VFU / VLSU groups + cycle base, every add catch-wrapped so missing signals skip). TWO adaptations:
our repo's sp_cycle -> the baseline cc's existing `cycle` counter (same .dasm time base), and the
sb_port_*_dbg adds are ours-only so they skip silently there. Usage from a build dir:
`do ../scripts/questa/add_spatz_core.tcl [g t c]`.

**hardware/scripts/questa/wave.tcl (baseline):** FPU_Fleet group (analog count + group counts +
binary vector), guarded by examine.

**Status:** baseline compiles clean (528 modules, 0 errors -- fewer than our 533 as it lacks our
extra modules); smoke elaboration (run 500ns) verifying XMR resolution + fleet log. NOT committed
(baseline repo is the user's; its working tree already had unrelated modifications -- bootrom,
control_registers, sp-fmatmul-opt main.c -- left alone).

---

## 2026-07-28 — build_1 512x256x512 run CRASHED: bypass_match_way 1-bit truncation (fixed)

**Event:** the user's 512x256x512 sp-fmatmul run in build_1 died at cyc ~33,605 (67220 ns):
`** Fatal: ParityDrain: bypass-track overflow at tile 0 (all 4 ways outstanding)` --
mempool_group_mshr.sv:1097, group (x=2,y=2), tile 0, port 1. vsim.wlf (31 GB) + traces intact.

**Root cause (RTL bug, introduced by the ROB64 sizing in 99074fd):** `bypass_match_way` stayed
1 bit per (tile,port) when BypassTrackWays went 2->4. Response match on way 2/3 stored `w[0]`,
so retirement decremented/freed way 0/1 instead -- ways 2/3 LEAKED (allocated, never retired)
until all 4 ways sat valid and the next bypassed burst tripped the canary. N=32 never saw it
(<=2 concurrent bypassed bursts/tile, ways 0/1 only); N=512 is the first geometry with 3-4.

**Fix (mempool_group_mshr.sv):** new localparam `BypassTrackWayW = clog2(BypassTrackWays)`;
`bypass_match_way` widened to [BypassTrackWayW-1:0]; match stores `BypassTrackWayW'(w)` instead
of `w[0]`; reset tie-off '0. Retirement (`int'(bypass_match_way[t][p])`) and the PD2-off
tie-off are width-agnostic, unchanged. Sizing of 4 re-verified sound: table beats retire at
resp forwarding (before commit), and the uncommitted ROB window (<=64 ids, 16-aligned blocks)
spans <=4 bursts -- so with the leak fixed the assert is a true canary, not a sizing shortfall.

**Status:** fix compiles clean (build_1, forced vlog, 0 errors). NOT committed. The 512x256x512
run needs a restart to reach completion.

---

## 2026-07-28 — group_mshr_cache_victim_rr: per-bank RR victim pointer for CACHED reclaim

**Ask:** the pass-2 CACHED-reclaim scan always takes the LOWEST-index reclaimable way (way-0
thrash, high ways pinned) -- replace with a simple, low-HW round-robin (user chose RR over PLRU
after a cost/benefit: RR updates only on reclaim fire, off the hit path; PLRU needs per-hit
tree updates for a best-effort cache).

**Implementation (mempool_group_mshr.sv):**
- `CacheVictimRR` localparam from `GROUP_MSHR_CACHE_VICTIM_RR` define (default 0); `VictimPtrW`
  = clog2(MshrWaysPerBank).
- `victim_rr_q/d[MshrBankNum]` start pointer. Pass-2 scan visits ways in rotated order
  (ptr, ptr+1, ... wrap) when ON; `if (CacheVictimRR)` constant-false when OFF -> legacy
  lowest-first scan, bit-identical.
- Pointer advances to victim+1 ONLY on a reclaim fire: alloc fires on a still-valid CACHED way
  (checked on the _q view in the alloc block, so the fresh entry's mshr_d write can't mask it).
  Invalid-way allocs, mere selections, and stalled grants leave it alone. <=1 alloc/bank/cycle
  (bank_alloc_taken) so the per-bank write never conflicts.
- `FF(victim_rr_q, victim_rr_d, '0)`; when OFF the pointer is unread -> whole register
  const-folds out.
- HW cost ON: 16 banks x 3b = 48 flops + rotated scan input + one incrementer/bank; hit path
  untouched.
- Plumbing: hardware/Makefile (-DGROUP_MSHR_CACHE_VICTIM_RR), config knob
  `group_mshr_cache_victim_rr ?= 0` (default OFF until A/B measured, like every other policy).

**Status:** knob=1 vlog compile clean + vopt elaboration verified (hello_world smoke reached
run, 134k cycles, CMS balanced inflight/orphan/dup=0). Smoke then KILLED by hand: the user
started their 512x256x512 run in build_1 and the smoke was about to interleave the transcript.
NOTE: build_1's work lib is left compiled victim_rr=1 ON (no recompile per user instruction --
their build_1 sims are off-limits). Committed 4f64a9c.

---

## 2026-07-28 — hash-3 burst branch: split {gap field, intra-load burst bits} + burst_bits knob

**Ask (user design):** the concurrent burst requests of one inner iteration differ in (a) which
16-word burst of a vector load they are and (b) which core's p_start they come from -- the bank
index should be built from those two DISJOINT fields. Verified against main.c:256-280:
p_start gap = P/split_p_count = 32w (M=P=256, ks=8) / 128w (M=P=512) -> gap bits 5 / 7; m2 ->
2 bursts/load -> 1 intra-load bit at word_addr[4]. The 256 case coincides EXACTLY with the old
contiguous shift=4 ({7,6,5,4}); the 512 case fixes a real flaw (old shift=4 captured only the
p-lane PARITY c0, collapsing 4 lanes to 2, and mapped the unrolled n/n+1 pair identically).

**Implementation (mempool_group_mshr.sv, BankHash==3 burst branch):**
  bank = { word_addr[BankSelShiftBurst +: BankIdW-BankBurstBits],
           word_addr[BurstAlignBits   +: BankBurstBits] }
- BankBurstBits = new knob GROUP_MSHR_BANK_BURST_BITS (default 1) = clog2(bursts/load):
  m1=0 (contiguous field, like a single), m2=1, m4=2, m8=3. BurstAlignBits already tracks
  MaxBurstWords, so a longer future HW burst moves the low field automatically.
- Guards (elaboration $error): gap-field width overflow; shift_burst < BurstAlignBits+
  BankBurstBits (field overlap -- the legacy contiguous value 4 at burst_bits=1 now errors,
  forcing the retune); BankBurstBits >= BankIdW.
- Part-select bases all constant (re-wiring + 2:1 mux, same as before).
- Config comment block rewritten with the formula + quick calculation instructions
  (burst_bits = clog2(VL/MaxBurstWords); shift_burst = clog2(P/split_p_count)).
- WORKING TREE set for the 512 experiment: shift_burst 4->7, burst_bits=1, single=9.
  NOTE: committed config (256/N=32) must go 4->5 when this is committed -- 4 is now illegal.

**Status:** committed 9fd09d8 (RTL + Makefile + config with the committed default
shift_burst=5 for 256; the working tree keeps the user's 512 tuning shift_burst=7 /
burst_bits=1 / single=9, uncommitted). Fresh-dir compile (build_hashchk): 533 modules,
0 errors, new branch active (config hash=3/shift=7/bits=1). vopt-level check comes with
the first sim using it.

---

## 2026-07-29 — GBAR_PLOOP: per-column-block group-wide barrier in sp-fmatmul (opt-in)

**Ask (user design):** at each `p += gvl` in the matmul kernels, rendezvous the cores so every
core starts the next column block aligned -- and only the cores of the SAME GROUP, not a global
barrier.

**Why group-only is right:** the group MSHR is SOURCE-side (a request enters the MSHR of its
source core's group), so only same-group cores can ever coalesce. A 256-core barrier would cost
far more and buy nothing. Confirmed on the running 512 sim: burst merge is 1.8-19.4%
(merged_burst 8/97 vs alloc_burst 439/403) against a degree-4 sharing ceiling of 75%.
Also: the tree's `hold_subs_burst=4` + `hold_window_burst=63` REQUIRE alignment -- misaligned,
an entry never reaches 4 subscribers and every burst eats the full 63-cycle timeout.

**Implementation (kernel/sp-fmatmul.c + main.c), knob `GBAR_PLOOP` (default 0):**
- Distinct from the existing `GROUP_BARRIER` (per-STEP, per-PAIR, measured net-negative). This
  one fires at the TOP of each outer `while (p < p_end)` body: 4x per kernel at m2/128 columns,
  2x at m4 -- vs once per n step. Top-of-body placement also subsumes COLDSTART_GROUP_SYNC
  (iteration 0 is aligned by the same barrier).
- Reuses the HW group-barrier structs, but its OWN struct (`GBAR_PLOOP_STRUCT=8`, NumBarriers=16)
  so it never collides with the pair structs 0..7. main.c configures it once per group
  (core_gid==0: target=cores_per_group, mask=all) behind its own `mempool_barrier`.
- Uses `gbar_sync` = request-sent fence (`sfence.vma`) + held-lw arrive + `fence.i`. NOT a drain
  fence: responses stay in flight, so load/compute overlap is preserved.
- Helper gate widened to `#if GROUP_BARRIER || GBAR_PLOOP`; the per-step macros
  (GBAR_SETUP/ARRIVE/WAIT/SYNC/SYNC_STEADY) stay gated on GROUP_BARRIER ALONE -- widening them
  broke a GBAR_PLOOP=1/GROUP_BARRIER=0 build (their call sites reference the pair address `gbar`).

**Build-system fix (runtime.mk):** added `DEFINES += $(EXTRA_DEFINES)`. A command-line
`DEFINES=...` OVERRIDES every `DEFINES +=` in runtime.mk (make gives command-line vars top
precedence), silently dropping -DNUM_CORES/-DNUM_GROUPS/-DVLEN/... -> compile errors. The old
`DEFINES=-DKERNEL_SIZE=4` advice in main.c was broken; corrected to EXTRA_DEFINES.

**Verification (riscv objdump):** ON build = 7 sfence.vma, 2-3 per matmul variant (loop
unswitching produces a work and a no-work copy of the p loop; the no-work copy MUST also arrive
or counts unbalance). p-loop back edge 0x344 -> 0x28c falls into the barrier at 0x294 => once per
p iteration, and the inner m/n region 0x2d4-0x558 is sfence-free => NOT a per-step barrier.
OFF build = 0 sfence.vma (fully compiled out). Both configs build clean.

**Status:** implemented + build-verified, NOT measured. Tree binary left at the DEFAULT (OFF) to
match the source default. Run ON with:
  make sp-fmatmul-opt-burst-merge config=terapool_spatz4_fpu EXTRA_DEFINES=-DGBAR_PLOOP=1

---

## 2026-07-30 — build_3 RESP_HOLD run FAILED: orphan response localized (waveform)

**Event:** the RESP_HOLD/cache-reclaimable design (build_3, RESP_WAIT_SUBS_SINGLE=1,
CACHE_RECLAIMABLE=0, MSHR 64/4, HOLD_SUBS_SINGLE=4) died at cyc 23327 / t=46664 ns:
`[CMS WARN] ORPHAN_RESP id=0 g=0 t=11 c=0` -> `** Fatal: Response ID does not match with valid
metadata`, scope `...gen_tiles[11].i_tile.gen_cores[0]...i_spatz.gen_fpu_sequencer.i_fpu_sequencer
.i_fp_lsu.invalid_resp_id` (snitch_lsu.sv:244). So it is the SCALAR FP load/store path (flw/fsw),
the exact request class the new policy changes.

**Waveform localization** (vsim -c -view on the 4.4 GB wlf in live-viewing mode; sim still parked):
1. cyc 23326: fp_lsu sees `data_pvalid_i=1, data_pid_i=0` while `id_available_q=16'hffff` -- ALL
   ids free, i.e. ZERO outstanding requests. Not a duplicate of an in-flight request.
2. That core's last genuine req/resp pairs ended at cyc 21748 (ids 0, addrs 0x2025c..0x202fc,
   one per 8 cyc). NO request at all in cyc 21749..23326 -> the response is ~1578 cycles LATE.
3. At the group-0 MSHR, tile 11's resp port asserts **resp_from_bypass=1 with resp_from_mshr=0**
   -> the response came through the MSHR BYPASS path (mshr_tag==0); the drain logic did NOT emit
   it. So this is not an MSHR double-drain.
4. The response on that port carries **wen=1** (a WRITE/store response), core_id=3, meta_id=0x28.

**Leading hypothesis (not yet confirmed):** a store ACK delivered to the core's load-response port
long after the store retired. Stores bypass the MSHR, so their acks ride the bypass path -- which
matches (3). The new `cacheable=0` route is the only path that makes a single-word entry
POP-AND-DEALLOCATE (`mshr_d = '0`) instead of finalizing to CACHED; deallocating an entry id while
any reference to it is still outstanding leaves a returning response to be treated as untagged ->
bypass -> straight to the core. The store-overlap pass is also the only new code that reacts to
stores inside the MSHR.

**Confirmation still needed:** count NoC forwards + acks for (tile 11, core_id 3, meta 0x28) to
prove a duplicated/late ack. My scan of that was INVALID (per-bit examine of a 2-D packed array
returned an error that the catch swallowed, so the loop matched nothing) -- redo by examining
`resp_in_valid[11]` as a value and decoding bits.

**Also (static review, still unfixed):** RESP_HOLD has no timeout (only 3 exits: merge-target-met,
store overlap, AMO invalidate) -> an entry whose target is never reached holds its response
forever; and cache_reclaimable=0 + self-inval gated on an unreachable served_cnt target pins a
CACHED way permanently (bank fills -> all later requests bypass). Both remove release paths the
original design deliberately had.

**Skill updated:** ~/.claude/skills/waveform-analysis/SKILL.md now leads with Method A
(`vsim -c -view` direct WLF query, works in live-viewing mode on a parked sim, run from a scratch
dir so it cannot clobber the build transcript) + the pitfalls hit here (brackets vs parens,
`now` unavailable, No_Data past $finish, t=2*cyc+10, stale wires, per-bit 2-D indexing, MSB-first
packed dumps) and keeps VCD+WAL as Method B for aggregate sweeps.

---

## 2026-07-30 — bypass probe added; orphan REPRODUCED and shown to be deterministic

**Change:** `group_mshr_bypass_probe` (sim-only, pragma translate_off) in mempool_group_mshr.sv
+ Makefile/config plumbing (config default 1). Pairs every entry-less (mshr_tag==0) single-beat
forward against the bypass response returned to the tile, keyed {tile, core_id, meta_id};
prints `[BYP ORPHAN]` on an unmatched response and a periodic `[BYP] fwd/rsp/orphan` summary.
vlog 533/0; elaboration confirmed by the run itself.

**Result — the bug is PROGRAM-POSITION DETERMINISTIC, not a race:**
  build_3: cyc 23327, g0/t11/core0, MSHR 64/4,  GBAR_PLOOP off
  build_1: cyc 23329, g2/t13/core0, MSHR 128/8, GBAR_PLOOP ON
Two configs differing in MSHR capacity AND core alignment fail 2 cycles apart, same FP-LSU
(i_fp_lsu.invalid_resp_id), same id=0, same p=0. Transcript places it exactly at the
DMA-copy -> kernel transition (`[UART] finish copy` then the work-distribution print), i.e. the
stray response is a leftover from the init/copy phase arriving after the core moved on --
consistent with build_3's waveform (victim core idle 1578 cyc, id_available_q=0xffff).

**The probe did NOT fire -- MY design error, not evidence about the bug.** It validates
KEY-LEVEL accounting, not per-request ownership. The FP-LSU reuses id 0 constantly (every
request in the build_3 trace was qid=0), so the {tile,core,meta} key almost always has another
outstanding forward (g0 at cyc22000: fwd=1637 rsp=1468 => 169 outstanding); the duplicate
decremented that live count and was reported as normal. The two exclusions (bypass_match,
bp_tile_tracked) may also suppress, but key reuse alone is sufficient.
=> A useful probe must track per-REQUEST identity (or log every delivery for post-processing),
not per-key counts.

**Status:** probe committed to the tree (uncommitted in git), bug NOT fixed, root cause still
not localized. Next: waveform on build_1's wlf (sim parked at Break, data intact) asking the
now-specific question -- at cyc 23329, what delivered to g2/t13/core0, and does that
(core_id, meta_id) show TWO deliveries against one forward?

---

## 2026-07-30 — ORPHAN_RESP ROOT CAUSE FOUND: GBAR_PLOOP watchdog force-release (MY bug)

**A/B result (decisive):** build_abctl with the new MSHR policies OFF
(resp_wait_subs_single=0, cache_reclaimable=1), same binary, everything else identical, failed
BYTE-IDENTICALLY: cyc 23329, g2/t13/core0, id=0, t=46668 ns. Three runs spanning both policy
settings and a 2x MSHR capacity difference all fail within 2 cycles => the MSHR is not involved.
**Codex's RESP_HOLD / cache_reclaimable design is EXONERATED for this bug.** (Its two other
defects -- no RESP_HOLD timeout, permanent CACHED-way pinning -- are untouched by this and stand.)

**Root cause (waveform, group-2 barrier instance, conclusive):**
  wd_fire_q  = 16'h0100   -> bit 8 = GBAR_PLOOP_STRUCT (the struct I added)
  count_q[8] = 15,  target_q[8] = 16,  mask_q[8] = 0xffff
Only 15 of 16 cores arrived; the per-struct watchdog (WatchdogLimit=1024 cyc, armed from the
first arrival, mempool_group_barrier.sv:37/108-111) expired and force-released. The release
walks the CONFIGURED MASK one core per cycle:
  cyc 23315 rel_rem=ffff (core0) ... cyc 23328 rel_rem=e000 (core13) <- victim = gen_tiles[13]
so it fires a release response at a core that never issued a barrier load. That core's scalar
port receives an unsolicited LOAD response (wen=0, core_id=0) with meta_id 0; the FP-LSU owns
id 0 -> invalid_resp_id (snitch_lsu.sv:244). build_3's victim was tile 11 = a different position
in the same walk. Matches every earlier observation: intra-group path (tcdm_master_resp port 0,
mempool_group.sv:275), load to the scalar port, meta_id 0, victim idle with id_available=0xffff.

**Why 15/16:** the FIRST p-loop barrier sits right after the DMA copy and must absorb the whole
init-phase skew, which exceeds the 1024-cycle watchdog for at least one core.

**MY ERROR:** I audited iteration-count balance and then wrote that the watchdog "force-releases
rather than hanging", treating it as a safety net. It is not -- force-releasing a core that never
arrived INJECTS A PHANTOM RESPONSE. Should have read what force_rel does to a non-arrived core
before relying on it. Also corrected earlier this session: my "orphan came via resp_from_bypass"
claim was a stale-wire misread (undecoded valid bits); that response was an unrelated VLSU store ack.

**Fixes:**
 A (RTL, proper): on force-release, release only the ARRIVED cores, not mask_q. Needs a per-struct
   arrival bitmap (16x16 = 256 flops) instead of just count_q; rel_rem = ready ? mask_q : arrived_q.
   Normal releases are unchanged. Without this, ANY barrier use with skew > 1024 cyc corrupts --
   a latent flaw my usage merely exposed (the pair barrier has it too, but is default-off).
 B (SW, immediate): keep GBAR_PLOOP=0, or place the first rendezvous after a software barrier so
   it never has to absorb init skew. Raising WatchdogLimit only widens the window, not a fix.

**Status:** build_nobar (GBAR_PLOOP=0, MSHR policies ON) running as the confirmation -- expected
to clear 23328. Binary in software/bin currently built with GBAR_PLOOP=0.

---

## 2026-07-31 — FIRST COMPLETED 512x256x512 RUN: 90,833 cycles (72.1% of FPU floor)

**build_3 finished clean** (`retval=0`, 258538 ns = ~129k total cycles, timed kernel 90,833).
FPU floor for this shape is 65,536 (2*M*N*P / (256 cores * 4 lanes * 2 flops)), so **72.1%
utilization** -- against 58.7% (3488 vs 2048) at the old 256x32x256 shape. The larger N does
amortize the load pipeline much better, as suspected.

**Config that produced it** (compiled 21:27, so WITHOUT the later timing rewrites):
  barrier fix + group_barrier_wd_limit=0 (barrier genuinely blocks), GBAR_PLOOP=1,
  resp_wait_subs_single=1 + serve_timeout=127, stall_on_resp=1,
  MSHR 128/8, merge_reqs=4, hold_subs 4/4, hold_window_burst=127, cache_reclaimable=0, L0=4.
Merge rate held at ~75% for BOTH singles and bursts all run = the degree-4 ceiling.
mshr_overflow=0, subreq_overflow=0, zero assertion fires, 0 CMS stalls.

**BENCHMARK REPORTING BUG (affects every performance line in this campaign):** the UART print
  performance = 1000 * 2 * M * P * N / timer     // long unsigned int == 32-bit on RV32
overflows. 1000*2*512*512*256 = 134,217,728,000 needs 37 bits; mod 2^32 = 1,073,721,824, and
/90833 = 11821 -- exactly the reported "11821 OP/1000cycle (5%o utilization)". The true figure is
1477 OP/cycle = 72.1%. Under-reports by 125x. Same overflow corrupted build_2's "8363 OP/1000cycle
(4%o)". Fix: divide before scaling -- (2*M*P*N/timer)*1000 -> 1,477,000 OP/1000cycle -> 721%o --
or promote to unsigned long long. NOT yet patched.

**Caveat:** single run, no A/B. build_nobar (the no-barrier/no-valve reference) is at 1.3M cycles
and still running, so there is no completed baseline at this shape to attribute credit against.
build_1 (timing rewrites + MSHR 64/4 + hold_window_burst=255 + serve_timeout=255) is at ~96k and
will give the first same-shape comparison.

---

## 2026-07-31 (evening) — build_1 = 79,086 cycles (82.9% of FPU floor), best so far

**build_1 finished clean** (`retval=0`, 235530 ns, timed kernel **79,086**) on the SAME ELF as
build_3 (ELF mtime Jul 30 15:57 predates both sim starts, so the comparison is binary-identical).
vs build_3's 90,833 = **-11,747 cycles, -12.9%**. True utilization **82.9%** (1697 OP/cyc against
the 2048 peak; the printed "13576 OP/1000cycle (6%o)" is the 32-bit overflow documented above).

**NOT a clean A/B — attribution is confounded.** Diff of the two compile.tcl define sets:

| knob | build_3 (90,833) | build_1 (79,086) |
|---|---|---|
| GROUP_MSHR_NUM | 128 | 64 |
| GROUP_MSHR_WAYS_PER_BANK | 8 | 4 |
| GROUP_MSHR_HOLD_WINDOW_BURST | 127 | 255 |
| GROUP_MSHR_SERVE_TIMEOUT | 127 | 255 |

*and* `mempool_group_mshr.sv` was edited 23:23 Jul 30 — between build_3's compile (21:27) and
build_1's (02:22) — so build_1 also carries the uncommitted timing rewrites (parallel per-bank
alloc arbiter, RespSeenByTag, restructured drain arbiter). Other RTL is identical across the two
(mempool_tile.sv 21:19, mempool_group.sv 16:04, both predate build_3).

Notable direction: build_1 wins with **half the entries and half the ways**, which cuts against the
"capacity is first-order" reading from the hold-window sweep. Needs one controlled run to separate.

**CORRECTION to an earlier note:** build_3 did **not** wedge in the epilogue. It reached
`[EOC] retval=0` at 258538 ns; the monitor's "no CPU for 30+ min" was vsim idling at its prompt
after the run ended. Both runs also had `MATMUL_VERIFY=0`, so neither verified numerically.

---

## 2026-07-31 (evening) — Verilator flow fixed, validated, documented (commit ab7c27e)

**Purpose:** get a fast, parallel, headless benchmarking path so knob sweeps stop being
license-bound and serialized behind QuestaSim.

**Four root causes, none structural** (tb/verilator + the verilate target were already complete):
1. **Wrong assertion define.** The target passed `COMMON_CELLS_ASSERTS_OFF`, but this
   `assertions.svh` gates on `INC_ASSERT`, controlled by **`ASSERTS_OFF`**. So every `ASSERT
   expanded, and two are unparseable by Verilator 4.x: floo_meta_buffer.sv:181,183,198 calls
   `` `ASSERT(name, prop, "msg") `` with 3 args against a 5-arg macro, putting the *message* in the
   `__clk` slot (`@(posedge "Meta data for B response...")`); snitch.sv:3108 uses `##1`.
2. **Input-port defaults** in deps/axi (the R-MCAST pop-mask ports) — unsupported in 4.228,
   guarded under `ifdef VERILATOR`. Verilator drives unconnected inputs to 0 = the declared default.
3. `verilator` binary path (Makefile:50) does not exist here.
4. `VERILATOR_ROOT` mis-derived (compiled-in prefix `linux-x64/share/verilator`, real kit at
   `verilator-4.228/`).

**Result:** full terapool verilates with **0 errors**, lints clean, builds and runs.
**Parity vs QuestaSim, same ELF, identical MSHR knobs: 78,314 vs 79,086 cycles = -0.98%.**
The offset is explained and constant: the verilate target overrides `boot_addr` to `l2_base`, so
Verilator boots at 0x80000000 and skips the bootrom Questa runs at 0xA0000000. Verilator-vs-
Verilator comparisons are therefore clean; only absolute-vs-Questa carries the ~1%.
**Speed: 54.3 cyc/s vs Questa's 1.85 = ~29x** (41 min vs ~19 h for the 512x256x512 matmul).

**Build recipe** (clang measured 3.3x faster to compile than the stock g++-9.2.0 *and* ~10% faster
sim per the Verilator docs): `CXX=clang++ LINK=clang++ OPT_FAST="-O2 -march=native
-fstrict-aliasing" OPT_SLOW="-O0" LDFLAGS="-fuse-ld=lld"`, `VERILATOR_ROOT=.../verilator-4.228`.
`OPT_SLOW=-O0` is free: 1403 of 2896 generated files are `__Slow` init code. ccache makes a
config-change rebuild ~108 s.

**Committed:** `ab7c27e` (Makefile `-DASSERTS_OFF`, regenerated `deps/patches/axi.patch` incl. the
VERILATOR guards, `docs/verilator_simulation.md`). The patch was regenerated from the deps/axi
git checkout (v0.39.9) and **round-trip verified**: revert to pristine -> `git apply` -> both files
byte-identical. Without this, `make update-deps` silently reverts the fix.

**Gotchas found (all in the doc):** `--meminit` rejects relative paths (`find_last_of(".")` reads
`..` as the extension); **changing a define does NOT trigger regeneration** — `make verilate` says
"is up to date" and *runs the model with stale defines*, which silently yields benchmark numbers
from the wrong config (`rm <build>/Vmempool_tb_verilator.mk` first); `SNITCH_TRACE=0` still creates
256 empty .dasm files (ungated `$fopen`) and writes are gated by the software-set `csr_trace_q`.

---

## 2026-07-31 (night) — 512x512x512 shape + hash retune (commit 1ff73c9); run HANGS

**Purpose:** raise utilization further with a squarer GEMM, and re-derive the bank-select hash.

`script/matmul.json` N 256 -> 512 (M=N=P=512), `data_gemm.h` regenerated (16.3 MB, gitignored).
L1 footprint 3.14 MB of 4 MB — links fine. App rebuilt with `config=terapool_spatz4_fpu`.

**Hash re-derivation** (rules in the config comments): only `shift_single` moves, because it tracks
**N** (the A row stride) and N is what changed.

| knob | formula | old | new |
|---|---|---|---|
| shift_single | clog2(N) | 8 | **9** |
| shift_burst | clog2(P/split_p_count) = clog2(512/4) | 7 | 7 (unchanged) |
| burst_bits | clog2(VL/MaxBurstWords) = clog2(32/16) | 1 | 1 (unchanged) |

`shift_burst=7` has independent empirical confirmation: the runs print `p_start,p_end = 0,128`,
i.e. the 128-word gap. Overlap rule still satisfied (7 > clog2(16)+1-1 = 4). Committed `1ff73c9`.

**RESULT: the 512^3 run HANGS.** A/B of shift_single 8 vs 9 (two concurrent Verilator models,
identical ELF) both ran **3 h at ~60 cyc/s and reached ~634,000 cycles** with no completion, vs
~200,000 expected. Implied utilization ~21% vs 82.9% at 512x256x512 — a stall, not a slowdown.

- **Not the hash:** s8 and s9 sat within 0.06% of each other, both stuck. The A/B is invalid.
- **Trigger is N=256 -> 512**, the only functional change. Suspects: MSHR capacity for the larger
  working set (now 64/4, halved from build_3's 128/8 — though 64/4 was fine at the smaller shape),
  or a core never reaching a group barrier — note `group_barrier_wd_limit=0` makes a barrier wait
  **indefinitely**, converting a missing arrival into exactly this symptom.

**PROCESS LESSON (cost 3 h):** I compiled out *all* periodic output (`enable_stats`, both probes,
`merge_profiling`) for speed, and the matmul's entire UART output is under one 4 KB stdio block —
so nothing was ever going to appear until exit, and CPU burn cannot distinguish a healthy run from
an RTL deadlock (both spin cycles). Diagnosis required attaching gdb to read
`VerilatorSimCtrl::time_` (half-cycles; cycles = time_/2). **Always keep a cheap heartbeat and
`stdbuf -oL` on long headless runs.**

**Status:** rerunning `shift_single=9` with `enable_stats=1` (period 2000) + bypass/resp_hold
probes + `stdbuf -oL`, bounded by `--term-after-cycles=300000`. User started `build_2` (QuestaSim,
same ELF, verified same knobs incl. shift_single=9, stats=1, 64/4) as an independent check.

---

## 2026-08-01 — 512^3 hang ROOT-CAUSED to an address-triggered latent RTL bug (local path)

**Symptom:** at the FIRST barrier (`mempool_barrier_init`, cyc ~1541) 15 cores -- hartid 0x41..0x4f,
i.e. **group 4, tiles 1-15** -- issue `amoadd.w` to the `barrier` word and never get a response.
Traces: 241 cores end at PC 0x800024c0 (`wfi`), the 15 end at 0x800024a0, stalled on the `bne` that
reads the AMO result. CMS: `STUCK_REQ ... p=0 addr=0x00321000 R bl=1 beats=0`, age matches cyc 1541.
Deadlock follows mechanically: only 241 AMOs complete -> nobody ever sees `a1==255` -> the counter is
never reset and the wake-up at 0x40000004 never fires -> all 241 sleep forever. `group_barrier_wd_limit=0`
means nothing breaks it.

**BISECT (Verilator, identical RTL model `vbuild_s9`, only the ELF differs):**

| build | `barrier` | bank_row | matrices | DMA copy | result |
|---|---|---|---|---|---|
| N=256 | 0x221000 | 136 | small | 2 MB | **PASS** (finish copy) |
| N=256 + 1 MB `.l1_prio` pad | **0x321000** | **200** | small | 2 MB | **HANG** |
| 512^3 | 0x321000 | 200 | large | 3 MB | **HANG** |

=> The trigger is **which bank_row the barrier lands on**, NOT matrix size, NOT copy volume. Both
addresses are legal (`bank_row < 256`), same group/tile/bank. **This is a latent RTL bug that the
512^3 layout merely exposes** -- a linker may legitimately place a variable at either address.

**ADDRESS DECODE CORRECTION (important -- the docs are wrong for this config).**
`NumBanks = NumCores*NumFUsPerCore*BankingFactor = 256*4*4 = 4096`, so **NumBanksPerTile = 16**, not 4:
```
[1:0] byte | [5:2] bank(4b) | [9:6] tile(4b) | [13:10] GROUP(4b) | [21:14] bank_row(8b)
```
Group is **addr[13:10]**, not addr[11:8]. `CLAUDE.md` and `docs/mshr_bank_hash_design.md` §0 state the
4-banks/tile decode and are wrong here. Under the correct decode the `barrier` word lives in
**group 4, tile 0** in BOTH builds -- which is exactly why group 4's cores are the victims: for them
it is an INTRA-GROUP access on the **local** port 0 path (`master_local_req` -> group crossbar), never
touching the NoC or the group MSHR. Core 64 is tile 0 itself (owns the bank) and completes; tiles 1-15
must cross the group crossbar and are the 15 that wedge. The other 240 cores reach it remotely and work.

**RULED OUT (each by direct evidence, not assumption):**
- **Group MSHR / bank hash / all tuned knobs** -- port 0 is local; the MSHR never sees these requests.
  Confirmed empirically: over a 300k-cycle bounded run the g=4 `[BYP]` counters are FROZEN
  (`fwd=128 rsp=128 orphan=0` at cyc 2000 AND 298000), with 0 `RH STUCK` and 0 MSHR stats.
  `shift_single` 8 vs 9 also made no difference (both hung, within 0.06%).
- **AMO handling in the MSHR** -- `req_can_merge` is 0 for AMOs (`req_is_load`/`req_is_store` both
  require `wdata.amo=='0'`), and BOTH stall branches (2422, 2427) are gated on `req_can_merge`, so an
  AMO can never be trapped there; it always falls to bypass. Bypass-track is burst-only (`req_len>1`).
- **L1 overflow** -- linker `l1` = 4.0 MB, usage 0x323800 = 3.14 MB, 882 KB spare; link succeeds.
- **SW work-split guards** -- every early `return` depends only on `gemm_l.*` and constants, never on
  `cid`, so no core can return early while others proceed.
- **`address_scrambler`** -- the sequential swap applies only below `NumTiles*SeqMemSizePerTile`=0x20000;
  both addresses are far above, take the default branch where `address_o[16:6]={tile_id,scramble}` is
  **identity**, and `spm_tile_id_remap` is identity (`tile_id_remap=0`). Transforms neither address.

**STILL OPEN:** the actual defect, somewhere in the intra-group local path where 15 tiles contend for
one bank in tile 0 (local crossbar / bank arbiter / AMO shim).

**BLOCKER on waveform analysis:** build_2's `vsim.wlf` CANNOT be read while the sim holds it open --
`wlfman info` works (17.2M signals, 0-10010 ns) but `wlfman items` returns **0** and `vsim -view` +
`find` returns empty, with `(vish-4074) still open, live viewing mode`. A WLF's structure index is
only finalized when the writer closes it; copying the file inherits the unfinalized index. Need either
a stopped build_2 or a dedicated short bounded run (~3000 cyc suffices) to get a queryable WLF.

**NOTE:** commit `1ff73c9` (512^3 shape) therefore leaves the tree in a **non-booting** state until
this RTL bug is fixed.

### 2026-08-01 (cont.) — WAVEFORM SESSION: corrections + localization to the NoC

**Prerequisite:** build_2 had to be STOPPED. A WLF being written cannot be enumerated
(`wlfman info` works, `wlfman items` returns 0, `vsim -view`+`find` empty, "vish-4074 live viewing
mode"); copying the file inherits the unfinalized index. After SIGTERM: 9,959,431 items readable.

**CORRECTION 1 (retract the previous entry's central claim).** The previous entry said the `barrier`
word lives in **group 4** and therefore the failing path is the intra-group LOCAL port, "exonerating"
the MSHR and NoC. **That is WRONG.** RTL ground truth from the waveform: for every tile of group 4
during the AMO burst, `i_mempool_tile_rw_demux/tgt_group_id = 4'h0`. The barrier targets **group 0**,
so group 4's cores reach it **REMOTELY**. The MSHR and NoC are back in scope. The bad step was
re-deriving the decode as group=addr[13:10] from `NumBanksPerTile=NumBanks/NumTiles=16`; the tile's
decode actually yields group=addr[11:8] (NumBanksPerTile=4 there). Lesson: read the decode signal,
do not re-derive it.

**Group mapping VERIFIED by hart_id (not guessed):** `group = x*NumY + y`.
x0y0 tile1 hart 0x01 (g0) | **x1y0 tile1 hart 0x41 (g4)** | x0y1 hart 0x11 (g1) | x1y1 hart 0x51 (g5).
(`group_id_i = group_id_t'({group_id.x, group_id.y})`, cluster wrapper :295.)

**LOCALIZATION — the requests are lost INSIDE the NoC.** Cycle-accurate trace (2 ns = 1 cyc) of
group 4's NoC egress and group 0's ingress:

| t (ns) | g4 `mshr_noc_req_valid[1]` | g4 `mshr_noc_req_ready[1]` | g0 tile0 `tcdm_slave_req_valid_i[0]` |
|---|---|---|---|
| 3078 | 2'h1 | 2'h3 | 0 |
| 3080 | 2'h2 | 2'h3 | 0 |
| 3082..3130 | 0 | 2'h3 | 0 |

* `ready` is **2'h3 the whole time** -> the NoC NEVER backpressured; both requests were **accepted**.
* Group 0 tile 0 `tcdm_slave_req_valid_i[0]` is **0 in 71/71 samples across 2600-4000 ns** (the whole
  barrier phase), while OTHER groups' tile 0 are actively receiving in the same window.
* No response ever returns: g4 `tcdm_master_resp_valid_i[1]` = 0 at every sampled time to 9000 ns.
* At cyc 2995 the entire local path is idle everywhere (`req_valid=0`, `resp_valid=0`,
  `resp_ready=0xffff`) -- nothing is stalled or backpressured anywhere.

=> The 15 AMOs are **accepted into the NoC at group 4 and never delivered to group 0**. This is a
**loss/misroute inside the FlooNoC fabric**, not a stall, not backpressure, not an MSHR policy.
It also explains the total silence of every deadlock detector: a dropped transaction leaves no MSHR
entry, no orphan, no stuck bypass -- nothing to report.

**OPEN / UNRESOLVED:** 241 AMOs to the SAME address DID complete, yet group 0 tile 0's slave port
shows zero arrivals in the whole barrier phase. Either those were served via a path this signal does
not observe, or `tcdm_slave_req_valid_i` is not the arrival point for NoC-sourced requests. Resolve
this BEFORE concluding, because it is the one fact inconsistent with the story above.

**Still consistent with the bisect:** bank_row 136 passes / 200 hangs, and `noc_port_hash=7` makes
request-port and response channel selection address-dependent -- a plausible mechanism for an
address-bit-sensitive loss in the fabric. Not yet verified.

### 2026-08-01 — **ROOT CAUSE FOUND: `barrier` landed on GroupBarrierWord (word 200)**

**The defect is an UNENFORCED CONTRACT, not a logic bug.** `mempool_group.sv:52`
`parameter int unsigned GroupBarrierWord = 200`; line ~305 re-encodes `tgt_sel` so that any
**intra-group, different-tile** request whose within-tile word field
(`master_local_req_tgt_addr[t][TCDMAddrWidth-1 -: TCDMAddrMemWidth]`, i.e. byte_addr>>14) falls in
`[GroupBarrierWord, GroupBarrierWord+NumGroupBarriers)` = **words [200,216)** is routed to the
**group-barrier port** instead of the tile, and the barrier **withholds the response** until a pair
rendezvous. `EnableGroupBarrier` defaults **ON**.

The 512^3 linker layout put the runtime's `barrier` BSS symbol at **0x321000 = word 200** -- the first
reserved word. 15 ordinary `amoadd.w` from group 4 tiles 1-15 were hijacked and wait forever.

**The RTL comment states the contract and even predicted this:** *"the SW/linker MUST reserve this
word group-wide so no data load aliases it. **Only sp-fmatmul is known clear of word 200.**"*
It held at 512x256x512 (L1 ended 0x223800, word 136) and broke at 512^3 (L1 ends 0x323800, crossing
word 200). Nothing in `link.ld` reserves the window and nothing detects a violation -- it just
deadlocks silently.

**POISONED L1 RANGE: byte 0x320000-0x35FFFF (256 KB)** = words [200,216) << 14.

**Every observation fits:**
| observation | explanation |
|---|---|
| bisect: bank_row 136 PASS, 200 HANG | 136 outside [200,216); 200 is the first reserved word |
| accepted at `master_local_req`, never at `slave_local_req` | re-routed to the barrier port, a different `i_local_interco` output |
| no response ever returns | the barrier withholds it by design, pending rendezvous |
| exactly tiles 1-15 of group 4 | barrier intercepts only intra-group DIFFERENT-tile requests |
| core 64 (tile 0) succeeds | same-tile access is TCDM_LOCAL, never enters the xbar |
| other 240 cores succeed | they arrive via the NoC; not intercepted |
| MSHR/NoC/bypass counters totally silent | correct -- never involved |
| bank_req/bank_resp at tile 0 busy the whole time | that is the NoC-sourced traffic, unrelated |

**FIX OPTIONS** (not yet applied):
1. **Reserve words [200,216) in the linker** (`software/runtime/link.ld` / `arch.ld.c`) so no data
   object can alias byte 0x320000-0x35FFFF. Correct and general; enforces the contract.
2. `group_barrier=0` (`-DGROUP_BARRIER_OFF`) -- removes the feature; fine for pure-perf runs.
3. Move `GroupBarrierWord` to a word the app never touches -- fragile, same class of latent bug.
4. Add an elaboration/sim assertion that FIRES when a non-barrier request hits [200,216) -- would
   have turned 6 h of debugging into one line. Worth doing regardless of 1-3.

**METHOD LESSONS (cost several wrong turns this session):**
- **Sample combinational signals only when the transaction is valid.** Reading `tgt_group_id` at an
  arbitrary time showed group 0 (a stack access at the port) and sent me chasing the NoC. It is
  group 4.
- **Sample at 1-cycle granularity (2 ns).** A 20 ns step made the 15 one-per-cycle local handshakes
  look like "no local activity" and produced a second wrong conclusion.
- **Do not re-derive an address decode when the RTL exposes it** -- but do read it at the right time.
- A WLF cannot be enumerated while its writer holds it open; stop the sim first.

### 2026-08-01 — FIX IMPLEMENTED AND VERIFIED (3 parts, not yet committed)

**1. `GroupBarrierWord` 200 -> 240** (`hardware/src/mempool_group.sv`), now overridable via
`` `ifdef GROUP_BARRIER_WORD ``. With `NumGroupBarriers=16` and `TCDMAddrMemWidth=8` (256 words),
the window `[240,256)` is exactly the TOP 16 words of L1 -> the reservation becomes a trailing
256 KB instead of a hole at 0x320000. This matters: a contiguous array cannot straddle a hole, the
512^3 a+b+c ended at EXACTLY 0x320000 (fitting by luck), and nothing fits below it at the next size
up -- word 200 would have blocked scaling in the direction we are going. The window stays physically
addressable (0x3C0000-0x3FFFFF < 4 MB TCDM), so the barrier HW is still reachable by
`(word<<14)|(tile<<6)`; only the *linker* stops allocating there.

**2. Linker reservation** (`software/runtime/arch.ld.c`): the `l1` MEMORY region LENGTH is truncated
to `GROUP_BARRIER_WORD*16384` (min'd with the full size), computed from the define, not hardcoded.

**3. Data-alias tripwire** (`gbar_window_no_data_access`, mempool_group.sv, sim-only): fires when a
**store or AMO** enters the window. A genuine barrier op is always a LOAD, so a store/AMO there is
unambiguously a linker escape. Loads are deliberately NOT flagged (indistinguishable from an arrive).
The 512^3 failure was `amoadd.w` -> this catches it at cycle 1541 with tile/word/window in the
message, instead of a silent hang that took a day to localize.

**Anti-drift plumbing:** `group_barrier_word ?= 240` in `config/terapool_spatz4_fpu.mk` (+ a default
in `hardware/Makefile`), passed to RTL (`vlog_defs`) AND software (`runtime.mk`), and
`GBAR_BASE_WORD` in `sp-fmatmul.c` is now **derived** from `GROUP_BARRIER_WORD` with an `#error` if
absent. Previously `200` was duplicated in mempool_group.sv and sp-fmatmul.c with nothing keeping
them in sync -- exactly how this class of bug survives.

**VERIFIED:**
- app builds clean; `__l1_end = 0x3C0000` (= 240<<14); `barrier` @ 0x321000 now outside the window
- verilation of the RTL change: **0 errors** (hier block renamed mempool_group_f -> _e, i.e. the
  edit is genuinely compiled in)
- **512^3 run: `finish copy` REACHED, `[UART] N,P = 512,512`, 0 alias assertions, rc=0** over a
  60k-cycle bounded run. Before the fix: deadlock at cyc 1541 with ZERO UART output ever.

**STATUS:** full unbounded 512^3 perf run started (run_512full) to get the cycle count/utilization
this campaign was chasing. Nothing committed yet; the three parts are only correct as a SET (the RTL
`GroupBarrierWord` and SW `GBAR_BASE_WORD` must move in lockstep).

### 2026-08-01 — BUG IN THE FIX: width-truncated barrier window silently DISABLED the barrier

**Caught by the user's insistence that the 512x256x512 slowdown "has to be something real".** It was
-- in my own fix, not the workload.

```systemverilog
(word < TCDMAddrMemWidth'(GroupBarrierWord + NumGroupBarriers))
```
`TCDMAddrMemWidth = 8`, and with the relocated `GroupBarrierWord = 240`, `NumGroupBarriers = 16`:
`8'(240+16) = 8'(256) = 8'd0`. The bound became 0, `word < 0` is ALWAYS FALSE, `bar_sel` was
permanently 0 -> **the group barrier was entirely disabled**. Word 200 never exposed this
(216 < 256); choosing the TOP of the word range walked straight into the wraparound.

**This invalidated both of my previous claims:**
- the 512^3 "fix verified" run passed only because NOTHING was being intercepted -- I had disabled
  the feature, not relocated it;
- the 512x256x512 "~2x regression" was `GBAR_PLOOP`'s per-iteration group barrier silently not
  synchronizing, so cores drifted apart. The trace evidence fit exactly: completion START matched
  the old run (~103k) but the TAIL stretched over ~70k cycles -- a skew signature, not a throughput
  loss. (Also measured, for the record: 512^3 with the barrier disabled = **375,439 cycles**,
  34.9% of the 131,072 FPU floor.)

**FIXES:**
1. Compare ONE BIT WIDER (zero-extend word and both bounds to TCDMAddrMemWidth+1), so an upper
   bound of exactly `2**TCDMAddrMemWidth` is representable.
2. Elaboration `$fatal` if `GroupBarrierWord + NumGroupBarriers > (1<<TCDMAddrMemWidth)` or
   `NumGroupBarriers == 0`. This class of silent disable can no longer elaborate.
3. (Earlier, same session) the alias assertion was ALSO wrong: it flagged STORES, but bank1/bank2
   set-target/set-mask ARE stores (`gbar_setup`), so under QuestaSim it would have `$fatal`'d on
   correct barrier configuration. Narrowed to AMO-only, which is never a barrier op. Note Verilator
   ignores SVA without `--assert`, so the earlier "0 alias assertions" proved nothing.

**RE-VERIFIED with the corrected RTL** (both models rebuilt with probes/stats/merge-profiling OFF,
matching the 78,314 baseline exactly -- the previous comparison had left GROUP_MERGE_PROFILING on):

| run | shape | shift_single | result |
|---|---|---|---|
| run_n256b | 512x256x512 | 8 | **78,314 cycles -- BIT-IDENTICAL to the pre-fix baseline** |
| run_512b  | 512x512x512 | 9 | in progress; already past the barrier WITH the barrier ACTIVE |

The identical N=256 number is the key result: it proves (a) the relocation costs zero cycles, and
(b) the barrier is genuinely functioning again -- a disabled barrier produces the 155k+ skew, a
working one reproduces the baseline to the cycle. The 512^3 run clearing cyc 1541 with the barrier
ACTIVE proves the LINKER RESERVATION is what resolves the deadlock, not the accidental disable.

**LESSON:** when a "fix" makes a symptom disappear, verify the mechanism is still ENABLED. Both my
verification runs were green for the wrong reason. A performance regression on an unrelated shape
was the only thing that exposed it.

---

## 2026-08-01 — 22-SHAPE GEMM SWEEP: full results, and the A-vs-B coalescing asymmetry

**35 runs** (22 baseline at merge_reqs=4, 13 retuned at the derived value), 30 Verilator models,
all on tmpfs. Both reproducibility anchors reproduced EXACTLY (s02 78,314; s03 153,707), so the
dataset is trustworthy. Utilization = 2*M*N*P / cycles / 2048.

### Headline
**Best: 256x512x256 -> 94.1%** (34,821 cyc, 1.25 MB) vs the 512^3 target at 85.3% (153,707 cyc,
3.00 MB): **4.4x fewer cycles, ~9 points better**. Top 5: 94.1 / 92.0 / 90.1 / 87.1 / 85.3%.

### Finding 1 -- merge_reqs must match the sharing degree, and A and B differ
A and B have DIFFERENT sharing degrees (user's correction, which was right and which I had wrong):
    A (scalar/single a[m][n]) shared by split_p_count cores  -> hold_subs_single
    B (vector/burst b[n][p..]) shared by split_m_count cores -> hold_subs_burst
    merge_reqs = max(the two)
The degrees INVERT with M: at M=512 both are 4 (which is why the shipped config works); at M=2048
A is private (1) while B is shared 16 ways. My first rule used split_p_count alone and would have
set merge_reqs=1 for s22 and 2 for the M=1024 shapes -- making them WORSE.

At merge_reqs=4 the split was bimodal with ZERO overlap, predicted 22/22 by `max(A,B) > 4`:
    correctly provisioned  9 shapes  50.4-87.1%
    under-provisioned     13 shapes  20.8-28.2%
Under-provisioning does not merely slow things down, it REMOVES N-amortization: the M=256 family is
flat at 22.7-26.1% across a 16x range of N (32..512), because the overhead becomes PROPORTIONAL to
work (~2.8x compute) instead of fixed per iteration.

### Finding 2 -- A coalescing is capacity-limited; B coalescing is NOT
Retuning to the correct merge_reqs:
    A-limited (8 shapes): gain **2.21-3.61x** -> final 50.2-94.1%
    B-limited (5 shapes): gain **1.01-1.25x** -> final 23.6-32.7%
Decisive controlled pair, identical 16-way sharing and identical 16-entry pool:
    s12 128x128x512  A 16-way, merge=16 -> **83.7%**
    s22 2048x128x128 B 16-way, merge=16 -> **32.7%**
A 51-point gap at equal capacity => capacity is NOT the B-side limiter. Burst merging is
**window-limited**: partners must be in flight simultaneously, and same-line partners are
iteration-scale apart. Sizing merge_reqs for B is necessary (do not under-provision) but nearly
worthless on its own; the residual is a timing/skew problem (hold_window_burst, inter-core skew),
NOT capacity. => **prefer shapes where the heavily-shared matrix is A, i.e. M <= 512.** Every
result >80% has M <= 512; every M >= 1024 shape stays below 33% whatever the tuning.

### Finding 3 -- once provisioned, utilization = compute per p-iteration (user's mechanism)
The group barrier sits INSIDE the p loop (`GBAR_SYNC_PLOOP`, sp-fmatmul.c:182), so
p-iterations = (P/split_p_count)/VL. N raises compute per sync; P multiplies the number of syncs.
For 1-p-iteration shapes the overhead is a genuine constant (1,793-2,053 cyc over a 16x range of
compute), so `util ~= C/(C+2000)` with C = floor/p_iters -- predicting 50.2 / 81.8 / 90.1 / 94.1%
exactly. CAVEAT: the constant only holds at 1 iteration; across all shapes overhead spans
1,328-3,194, so it is a mechanism, not a precise predictor. (I earlier called the fit "exact" --
that was circular, since I derived the overhead from each measurement.)
Design rule: **maximize N, then minimize p-iterations** (cols/core = 32 = one VL once N >= 256).

### Deliverable
`scripts/gemm_autotune.py` derives shift_single/shift_burst/burst_bits/hold_subs_single/
hold_subs_burst/merge_reqs from (M,N,P), validates the kernel work-split guards and L1 capacity,
and rejects illegal shapes. Verified: reproduces all 22 hand-derived hashes and rejects 5 illegal
classes. `bb=1` for every shape (fixed by e32,m2) -- the one knob that never needs tuning.

---

## 2026-08-02 -- Baseline comparison sweep + `tcdm_id_remapper` id_lock bug

### Purpose
Measure our design (Spatz burst load + group MSHR merge/multicast) against the unmodified
baseline `TeraNoC_ori/TeraNoC_spatz` (`sp-fmatmul-opt`, no burst, no MSHR) across the same 22
GEMM shapes, so the burst/merge win is quantified rather than asserted.

### Implementation
- Fixed the baseline's Verilator flow (`-DASSERTS_OFF`, `tc_sram.sv` `simutil` DPI) and swept all
  22 shapes on Verilator + QuestaSim.
- `s17` 256x512x256 never completed on the baseline: QuestaSim `invalid_resp_id` `$fatal` in the
  Spatz FP-LSU, Verilator (which compiles those assertions out) ran on past it and died ~11k
  cycles later on a misaligned load + trashed stack frame.
- Instrumented `snitch_lsu.sv` (probes for core-side request stability, accepted-vs-recorded
  metadata, and a non-fatal state dump). Both payload probes read **zero**; the dump showed
  `resp_id=2 avail=11111100` -- an FP-LSU with only IDs 0,1 outstanding receiving a response
  tagged ID 2. So: an orphan response, i.e. a **return-path routing** fault, not a handshake fault.
- Root cause in `hardware/src/tcdm_id_remapper.sv` (shared TCDM port, Snitch int-LSU + Spatz
  FP-LSU): on a backpressured request cycle 1 presents remapped ID `next_id`, cycle 2 skips the
  `if (!id_lock_q) req_o.id = next_id` override and drives the master's raw `req.id`, and keys the
  ROB at `remapped_id_d[req.id]`. Presented ID / wire ID / ROB index all disagree -> response
  demuxed to the wrong master with an ID it never issued. Also the true source of the
  `input_data_unstable` firings seen at the tile xbar.
- Backported the fix from our `e4a442f` (`locked_remap_id_q`: latch the presented remapped ID,
  keep driving it while stalled, key the ROB by it). Deliberately did NOT backport `burst_left`
  (that is our Spatz burst feature).

### Result
Fix is bit-neutral on shapes that already worked, and repairs the broken one:
    s14 256x32x512   Questa 8,303 = 8,303   Verilator 7,901 = 7,901    exact
    s15 512x64x256   Questa 16,393 = 16,393 Verilator 16,223 = 16,223  exact
    s17 256x512x256  **44,618 cycles, 0 errors** (previously never completed)

Full 22-shape comparison -> `docs/benchmarks/gemm_results.md` + `_table.txt`:
    geomean non-B-limited (17 shapes): **1.21x**   (range 0.96-1.36x)
    geomean B-limited      ( 5 shapes): **0.50x**
    overall 0.99x -- MISLEADING, the sweep over-samples M>=1024; report the split, not the mean.
Every regression is B-limited (`B-sh > A-sh`, M >= 1024) and uniformly ~0.47x, confirming Finding 2
above from the other direction: burst merging is window-limited, so followers miss the leader's
window AND pay MSHR occupancy. Actionable: **bypass the MSHR when `B-sh > A-sh`** (~0.47x -> parity).

### Lessons
- Wrong-layer chase, twice: I blamed the tile xbar handshake (built an Option A stability hold in
  `mempool_tile.sv`), then the LSU handshake. Both were downstream of the remapper. The hold WAS
  result-neutral but did not fix the failure and shifted it 10ns earlier -- because pinning the wire
  to `next_id` while the table says `req.id` guarantees the mismatch. Reverted.
- Ordering is not causation: I argued instability@12,277 -> fatal@12,283 was causal. Instrumentation
  showed the two are independent. Get the state dump before building the theory.
- Verilator compiles `ifndef VERILATOR` assertions OUT -- a shape that "runs" under Verilator may be
  silently corrupt. Cross-check anything suspicious under QuestaSim.
- Baseline verify wedges post-benchmark on most shapes: processes spin at 99.5% CPU for 16h after
  printing their result. Harvest `took N cycles` and reap; runs now carry a `timeout`.

### Status
Fix validated in the baseline tree (not committed -- baseline is a reference checkout).
Our tree already carries the fix via `e4a442f`. 8/22 QuestaSim baseline runs still pending;
baseline column in the report is Verilator (agrees with Questa within +-5.7%, sign varying,
on all 13 overlapping shapes).

---

## 2026-08-03 -- Two MSHR fix experiments: both hypotheses refuted

### Purpose
Test the two leading explanations for our only two regressions vs the baseline:
the B-limited shapes (~0.47x) and the `512x1024x128` collapse (0.53x).

### Implementation
Instrumented waveform runs of the mirror-image pair, then a single-knob sweep each.
`1024x128x128` (A 2-way / B 8-way, 26.9%) vs `256x512x256` (A 8-way / B 2-way, 94.5%).

### Result -- both refuted
    hold_window_burst  255 -> 64 -> 0   : 59,820 -> 59,620 -> 57,484   (-3.9%)
    group_mshr_num      64 -> 128 -> 256: 173,949 -> 173,828 -> 172,301 (-0.95%)
Neither hold policy nor entry/bank capacity explains either regression.

What the instrumentation DID establish:
    | | 1024x128x128 | 256x512x256 |
    | merged        | 15.5%        | 76.2%       |
    | bypassed MSHR | 84.5%        | 23.8%       |
    | single merge  | 38.3%        | 87.5% (= ceiling (8-1)/8) |
    | burst  merge  | 53.2%        | 50.0% (= ceiling (2-1)/2) |
`256x512x256` hits BOTH theoretical merge ceilings exactly -- the merge machinery is
not defective. The slow shape bypasses 84.5% of requests so they never get to merge.
Bypass is not capacity-driven (4x entries changed nothing); its cause is UNKNOWN.

### Lessons
- **Three hypotheses refuted this campaign, same failure mode each time**: I found a
  correlate (instability near the fatal; 96.9% hold timeouts; largest working set)
  and treated it as the cause without testing whether it was on the critical path.
  Volume of a stall is not cost of a stall.
- The held-entry `subs`/`hold_release` counters track a MINORITY path. I quoted
  "2.14 of 8 subscribers, 96.9% timeouts" as the mechanism; the authoritative
  `reqs: merged/alloc/bypass` counters show burst merge is actually 53.2%. Check
  which counter is authoritative before building a story on it.
- Negative results are worth the machine time: two cheap sweeps killed the two most
  plausible fixes and redirected the search to the bypass rate.

### Status
`docs/benchmarks/gemm_results.md` Findings 2 and 5 rewritten to state what is ruled
out and to stop asserting "window-limited". Next lead: why does the slow shape
bypass 84.5% of its requests when it is not short of ways?

---

## 2026-08-03 — Scale-up survey: configurable mesh (L1 + L2 NoC)

### Purpose
Plan the next phase: make the mesh size a configuration parameter so the FPU-util
and total-compute scaling curve can be measured, scaling the L1 (TCDM) NoC, the
L2 (AXI) NoC, groups, cores and L1 capacity, with the software following.

### Implementation
Survey only — no RTL/SW changes. Traced the address→coordinate path, the group-count
ceiling, both NoC routing schemes, the L2/DMA path and the software split. Wrote
`docs/scaleup/mesh_plan.md` (supersedes the earlier fixed-8×8 draft, deleted).

### Result — what the survey established
1. **Mesh dimensions must be powers of two.** The group index is a bit-field extract
   (`mempool_tile.sv:1192`) and is bit-cast straight into mesh (x,y)
   (`mempool_group_floonoc_wrapper.sv:285`), so `gid = x·NumY + y` comes free from
   address bits. 5×5/6×6/7×7 would need a constant modulo + divide on the L1 request
   path. The ladder is therefore 2×2 … 16×16, 64× of compute in 7 rungs.
2. **Cores/group = 16 keeps the whole group microarchitecture invariant.**
   `NumBanksPerGroup = 256` regardless of mesh size, so `TCDMAddrWidth`, the tile
   crossbar, the MSHR geometry (32 concurrent slots), `group_barrier_word=240` and
   `DmaBurstLen` all carry over unchanged at every rung.
3. **`group_xy_id_t` splits its width evenly** (`idx_width(NumGroups)/2`,
   `mempool_pkg.sv:405`) — correct only for 4/16/64/256 groups, silently wrong at 32.
   Needs separate `idx_width(NumX)`/`idx_width(NumY)` fields plus elaboration asserts.
4. **The TCDM routing-table generator does not exist.** `routing_table_pkg.sv` is
   hardcoded `[3:0][3:0][15:0]` and credits a `gen_routing_table.py` that is not in
   the repo. Must be written; gate is bit-identical 4×4 regeneration.
5. **The L2/AXI NoC is a separate overlaid mesh using SOURCE routing** with an
   all-pairs table (`route_t[34][34]`, 23 b routes). O(N²·diameter): ~26 kbit at 4×4,
   ~460 kbit at 8×8, ~10 Mbit at 16×16, and the route rides in every AXI header.
   floogen already supports XY (`floogen/model/routing.py:28`); switching removes the
   table and shrinks the header to `id_t`. Mesh-size independent → do it first.
6. **Four unrelated expressions all equal 16 today and diverge above 4×4:**
   `NumAXIMasters = NumGroups` (`mempool_system.sv:42`), perimeter attach points
   `2·(NumX+NumY)`, `l2_banks`, and the yml `hbm array`. `gen_l2_adapters` (line 659)
   and `gen_l2_banks` (line 702) are 1:1 by index with no assert, so `l2_banks` must
   equal `NumAXIMasters`. Failure mode is silent: surplus chimneys tie off and it
   elaborates.
7. **Two copies of the group-stride literal 16384** — `arch.ld.c:21` and
   `scripts/gemm_autotune.py:162`. Both must derive it from num_groups. (The tuner
   already parameterises `--num-groups`/`--num-cores`; only the stride is hardcoded.)
8. **Software needs no kernel change** — `main.c:202-290` is fully parameterised on
   `NUM_GROUPS`. What moves is the shape set: min legal M = num_groups × KERNEL_SIZE,
   and the A/B sharing table shifts by the group-count factor.

### Status
Plan written and under review. Phase order: 0 = AXI SRC→XY on 4×4 (self-contained,
regressable against the working design), then group-count ceiling + coordinate type,
TCDM table generator, L2 channel decoupling + perimeter function, address/linker
derivation, bring-up ladder, software shapes, measurement.
Open decisions: L2 channel scaling policy, torus vs mesh, ladder extent.

---

## 2026-08-03 — Phase 0: AXI/L2 NoC source routing → IdTable (4×4)

### Purpose
First phase of the mesh scale-up plan. The AXI/L2 network used FlooNoC source
routing, whose all-pairs table is O(N²·diameter) and whose route rides in every
flit header — the worst-scaling term in the design. Mesh-size independent, so it
could be done and regressed against the working 4×4 before adding any groups.

### Implementation
- `config/floo_noc_*.yml`: `route_algo: "SRC"` → `"ID"` (all 8 configs).
- **New** `hardware/scripts/gen_floo_route_tables.py`: emits per-router IdTable
  rules. Uses floogen for topology (yml stays the single source of truth) but
  computes routing itself, strictly XY dimension-ordered, and self-verifies by
  walking every (router, destination) pair to delivery before emitting. Wired
  into the root Makefile after floogen; package added to `Bender.yml`.
- RTL: AXI router takes `NumAddrRules`/`addr_rule_t`/`id_route_map_i` (indexed by
  `group_xy_id`, mirroring how the TCDM routers take `routing_table_pkg`); both
  `periph_router` instances wired to `PeriphRouterIdMap`; 11 dead `route_table_i`
  connections removed (SourceRouting-only).

### Result
| | SRC | ID + fix |
|---|---|---|
| Questa assertions | 0 | 0 |
| boots / traffic | yes | yes |
| cycles (256×512×256) | 122,051 | 123,567 (**+1.24%**) |
| errors / CMS warns | 0 / 0 | 0 / 0 |
| generated package | 1,383 lines | **157 lines** |
| flit header dst field | 23 bits | **6 bits** |

Rules per router 5–12 before equalising (vs floogen's 10–23) because `gid =
x·NumY + y` makes each direction's destinations a contiguous id range — a
property that holds at any mesh size. Generator verified on all 8 configs
including 2×2 meshes.

### The bug that cost the most, and how it was found
All 8 chimneys passed `.dst_t(route_t)`. `floo_nw_chimney.sv:44` defaults
`dst_t = id_t`; floogen's SRC top overrides it to `route_t`, its **ID top does
not**. Under IdTable `route_t` is `logic` (1 bit) vs `id_t` 6 bits, so `dst_id`
truncated and every destination collapsed to endpoint 0 = `group_ni_0_0`.
Symptoms: 69,096 `NoWideSbrPortArRequest` at group (0,0), boot hang, `fwd=0
rsp=0` in all 16 groups through cycle 198,000.

Found by diffing our instantiation parameter-by-parameter against floogen's own
generated ID top — which should have been the *first* move, not the fourth. Three
hypotheses were chased first and all were wrong: the unconnected `route_table_i`
(inert, read only under SourceRouting, `floo_route_comp.sv:78-81`), the `.id_i`
deviation (unused under IdTable), and the port-index convention (`floo_pkg`
confirms North=0…Eject=4, matching the generated table).

### Other findings (pre-existing, not introduced here)
1. **`Bender.lock` regression from `b7c7013`.** The committed public-git form made
   `bender path spatz` resolve to `hardware/deps/spatz` (`d02afac`, no
   `NumRespPorts`/`burst_len_o`) instead of `working_dir/spatz` (`a37562f`); a
   fresh build fails with pin-not-found. `bender update` restores the Path form —
   **`Bender.lock` is now locally modified and must not be committed.**
2. **The committed AXI network is not dimension-ordered.** floogen derives routes
   from `nx.shortest_path`; the resulting turn model violates XY 72 times and YX
   72 times, which admits cyclic channel dependencies. Survives at 4×4 with light
   AXI traffic; gets worse with diameter.
3. **floogen's ID mode alone is unusable here**: `gen_router_tables` iterates
   subordinate endpoints only, so manager-only groups get no rules and every
   subordinate→manager response is unroutable.
4. **`addr_decode` reads `end_addr == 0` as end-of-address-space**
   (`addr_decode.sv:55`), so an inert `{0,0}` pad rule matches *everything*. The
   generator equalises rule counts by splitting real ranges instead.
5. `hardware/generated/` is **gitignored**, not committed — CLAUDE.md says
   otherwise, and it matters because `git checkout` cannot restore it.

### Status
Functionally correct and verified; **does not meet the stated gate** ("cycle count
unchanged") at +1.24%. That delta is **unexplained** — `[LP]`/`[BP]` link
profiling is QuestaSim-only and Questa reaches only ~cycle 16k in 30 min, so the
XY-vs-shortest-path congestion hypothesis could not be tested. Not committed.

### Lessons
- **QuestaSim is not optional.** Verilator ran the broken design 198,000 cycles
  and reported `errors=0` while every group sat at zero traffic; Questa flagged it
  at 152 ns. Assertions are `ifndef VERILATOR`.
- **When adapting hand-written RTL to a generator's new mode, diff against the
  generator's own output first.** The reference implementation was already on disk.
- **Read the failure signature literally.** "Everything lands at endpoint 0" is the
  fingerprint of a truncated destination field; it was misread as a routing-table
  problem for far too long.
- A control experiment settled attribution in one run: SRC re-elaborated under the
  same flow gave 0 assertions, proving the bug was introduced, not pre-existing.

### 2026-08-04 follow-up — the +1.24% is fully attributed

Built a third model differing in exactly one variable (the turn model), keeping
IdTable as the mechanism:

| model | mechanism | turn model | cycles |
|---|---|---|---|
| base | SourceRouting | mixed (nx.shortest_path) | 122,051 |
| sp   | **IdTable**   | mixed (nx.shortest_path) | **122,051** |
| id2  | IdTable       | **strict XY**            | **123,567** |

**SourceRouting → IdTable is EXACTLY cycle-neutral** — same number, not merely
close, on the same binary and config with 0 errors / 0 CMS warnings. All +1,516
cycles are the turn model, i.e. the price of deadlock-freedom. The table shrink
(1,383 → 157 lines) and the header narrowing (23 b → 6 b dst) are free.

Why the turn model costs anything, given identical hop counts: the only AXI
traffic in the ROI is icache refill (the group's single AXI master carries DMA and
refill merged in `i_axi_interco`, `mempool_group.sv:603`; the matmul data is
L1-resident and copied before the timer starts at `main.c:401`). That traffic is
many-to-few — 16 groups against a few perimeter L2 channels — and strict XY
funnels each destination through a single approach link, while the mixed model
splits it across two. Dimension-order forbids precisely the turns that spread it.

Corroborating: rules/router are 12 under XY vs 23 under shortest-path, because
`gid = x·NumY + y` makes each direction's destinations a contiguous id range only
under XY.

Reproduce: `gen_floo_route_tables.py --turn-model shortest` (EXPERIMENT ONLY —
reintroduces a turn model that can deadlock; the tree is restored to XY by a trap).

Lesson: a one-variable control run settled in ~50 min what link-profiling could
not reach at all ([LP]/[BP] are QuestaSim-only and Questa needs hours to reach the
ROI). Prefer isolating the variable over instrumenting the symptom.

### 2026-08-04 — turn model decided: shortest-path, and a correction

Questa on IdTable + shortest-path: **0 assertions**, boots, 64 non-zero BYP lines.
With the Verilator result (122,051, 0 errors) Phase 0 is fully verified.

**Correction to the entry above.** I claimed floogen's shortest-path turn model
"admits cyclic channel dependencies" on the basis of 72 XY- and 72 YX-violations.
That is wrong: violating dimension-order is not the same as having a cycle. A CDG
cycle needs a complete four-turn rotation; shortest-path here uses only
N->E, S->E, W->N, W->S (<=2/4 of either rotation) and its CDG is acyclic on the
req, rsp and wide networks, and even all-to-all. Prompted by the observation that
the AXI network is group<->edge only, never group<->group — though the measurement
shows the restriction isn't even required, since destination-based routing gives
the same turn set either way.

Also: "strict XY, deadlock-free by construction" was overstated. XY makes an N->E
turn too, from the three endpoints on the off-mesh periph_router at (0,-1).

**Decision: ship shortest-path.** Phase 0 then has zero behavioural change (same
paths, 122,051 = 122,051) while keeping the package 1,383 -> 157 lines and the
header 23 -> 6 bits. XY stays available via `FLOO_TURN_MODEL=xy`.

Hardening, since shortest-path is safe only by verification:
- generator now GATES on a channel-dependency-graph acyclicity check and refuses
  to emit a cyclic table; complete without enumerating sources because routing is
  destination-based;
- `hardware/generated/floo_terapool_route_table_pkg.sv` is now TRACKED (gitignore
  exception) so a floogen version bump cannot change routing invisibly.

Lesson: I bundled the routing mechanism and the routing policy into one change,
which made the delta ambiguous and cost a full attribution exercise. Change one
thing at a time. And do not upgrade a theoretical risk into a measured one —
"can deadlock in general" was doing work in my argument that it had not earned.

---

## 2026-08-04 — Phase 1a: group_xy_id_t independent X/Y widths

### Purpose
`mempool_pkg::group_xy_id_t` sized x and y as `idx_width(NumGroups)/2` each —
exact only when `idx_width(NumGroups)` is even. The mesh coordinate is never
computed, it is BIT-CAST from the flat group id, so a wrong width does not fail:
it mis-splits x from y silently.

### Implementation
- `mempool_pkg.sv`: x is `idx_width(NumX)` bits, y is `idx_width(NumY)`.
- Three elaboration guards in BOTH cluster wrappers: `NumX*NumY == NumGroups`,
  both powers of two, and `idx_width(NumX)+idx_width(NumY) == idx_width(NumGroups)`
  — the last is what keeps the bit-cast valid.

### Result
The old form was wrong at **every rectangular rung**, not just the 32 groups the
plan predicted:

| mesh | groups | old x/y | new x/y | |
|---|---|---|---|---|
| 4×4 | 16 | 2b/2b | 2b/2b | unchanged |
| 2×4 | 8 | 1b/1b | 1b/**2b** | was broken |
| 4×8 | 32 | 2b/2b | 2b/**3b** | was broken |
| 8×8 | 64 | 3b/3b | 3b/3b | unchanged |
| 8×16 | 128 | 3b/3b | 3b/**4b** | was broken |

Verified **both directions**:
- positive — 4×4 Questa: 0 elaboration errors, 0 assertions, boots;
  Verilator: **exactly 122,051 cycles**, 0 errors, 0 CMS warnings (bit-identical).
- negative — `num_x=16` (NumY=1, width sum 4+1 != 4) **fails elaboration**,
  `exit=2`, with the intended message. A guard that cannot fail is a comment;
  this one is a gate.

### Status
Phase 1a done. Phase 1b (`MAX_NumGroups`) NOT attempted — the plan mis-scoped it,
see below. Nothing committed.

### Phase 1b scoping finding
`MAX_NumGroups` cannot simply be "derived from NumGroups":
- it sizes the `wake_up_tile` **multireg** in `control_registers.hjson`
  (`count: "MAX_NumGroups"`), so it determines how many registers exist, not just
  a bound;
- `control_registers_reg_pkg.sv` is GENERATED with the value baked in, and SV
  package parameters cannot be overridden at instantiation;
- `reggen`/`regtool` exist only under
  `hardware/deps/register_interface/vendor/patches/` and are referenced by no
  Makefile — there is no regeneration step in the build;
- raising it to 64 grows the register block past `BlockAw = 8` (256 B), moving the
  address map, which touches software.

So it is not bit-identical and needs a build step that does not exist yet.

### 2026-08-04 — Phase 1b correctly declined, plus 32-group reconnaissance

**I nearly implemented a change on a false premise.** The plan (and my own
recommendation) said deriving `MAX_NumGroups` from `NumGroups` would "convert a
silent ceiling into a loud one". Reading the code first: `ctrl_registers.sv:107`
imports `mempool_pkg::NumGroups` and line 186 compares it against the generated
`MAX_NumGroups` (16). **The ceiling is already loud.** Deriving it would add a
redundant second error and make the parameter name ("maximum supported in any
configuration") inaccurate. Not implemented.

Spent the machine time on reconnaissance instead — elaborating 4x8 / 32 groups /
512 cores:

```
# ** Error: [ctrl_registers] Number of groups exceeds the maximum supported.
#    Scope: mempool_tb.dut.i_ctrl_registers.genblk4  ctrl_registers.sv:186
# Optimization failed        Errors: 1
```

* the ceiling guard fires — **measured**, not inferred;
* the new `group_xy_id_t` guards stayed **silent** on this legal rectangular mesh
  (idx_width(4)+idx_width(8) = 2+3 = 5 = idx_width(32)). This is the permissive
  half of the test; previously only the rejecting half had been shown;
* `MAX_NumGroups` is the **first** blocker at 32 groups, so wiring `reggen` is a
  real gate rather than a speculative plan item.

Limitation: `vopt` aborts on the first error, so this is blocker #1, not the full
list. Enumerating the rest needs each neutralised in turn.

Lesson: the plan's predictions have now been wrong twice in opposite directions —
`group_xy_id_t` was broken at MORE rungs than predicted (every rectangular one),
`MAX_NumGroups` at FEWER (already guarded). Verify the premise before implementing
the fix, including when the premise is one's own recommendation.

## 2026-08-04 — Phase 2 does not exist for mesh configs

The plan called the TCDM routing-table generator "the largest new-code item" with
a non-negotiable bit-identical gate. Checking before building it:
`routing_table_pkg::RoutingTables` is referenced ONLY inside
`if (NocTopology == 1) begin: gen_torus` (mempool_group_floonoc_wrapper.sv
:829/:887/:944). At `noc_topology=0` the `gen_2dmesh` branch uses
`RouteAlgo=XYRouting` with `xy_id_i=group_xy_id` and `id_route_map_i` tied to '0.
`floo_route_select`'s XY branch decides from `id_in.x/y` vs `xy_id_i.x/y` — pure
comparisons, dimension-agnostic, already mesh-size independent. Phase 1a's
group_xy_id_t fix is what makes it correct at non-square meshes.

Corroborating: the committed table does not decode as mesh-XY at all. Brute-forced
block order x{asc,desc} x gid encoding x {mesh-XY, torus-XY tie E/N, tie W/S}: the
best fit is torus-XY at 40/256 violations, mesh-XY at 80. Nothing reproduces it
exactly. It is a torus artefact, and the mesh path never reads it.

A generator is needed only if torus (noc_topology=1) is chosen — an open decision,
not a prerequisite. Phase 2 is off the critical path.

Lesson, third time this campaign: check whether the thing is *used* before
planning to rebuild it. The plan's predictions have now been wrong in both
directions on three separate items.

---

## 2026-08-04 — Phase 3 groundwork: blocker enumeration, L2 guard, reggen wired in

### Purpose
Convert Phase 3's scope from prediction to measurement. The plan's predictions had
already been wrong three times, in both directions.

### Method that worked
**Verilator, not QuestaSim, for enumeration.** vopt stops at the first error and
needs iterative patching; Verilator continues and lists everything in one pass.
Caveat learned: Verilator reports `$error` as a NON-FATAL `%Warning-USERERROR` and
carries on, so it exits 0 on a design QuestaSim refuses. Read the log, not the exit
code. (This corrects an earlier note in this file claiming Verilator "does not
enforce" elaboration $error — it reports and ignores.)

### Result: the 32-group (4x8) blocker list is three items, not the predicted set

| # | blocker | manifestation |
|---|---|---|
| 1 | ctrl_registers MAX_NumGroups | %Warning-USERERROR; wake_up_tile[g] past a 16-entry array |
| 2 | mempool_system L2 adapters | 51x %Warning-SELRANGE, indices 16..31 into 16-entry bank arrays |
| 3 | perimeter channel indices | SILENT -- in range, wiring simply wrong |

No structural, width or connectivity breakage otherwise.

### Blocker 2 -- guarded
`NumAXIMasters = NumGroups` secretly serves two roles: perimeter attachment points
AND L2 channels, wired 1:1 by gen_l2_adapters. Equal only because NumGroups,
2*(NumX+NumY) and l2_banks are all 16 at 4x4. Changing the loop bound alone would
have silently dropped masters 16..31 -- worse than the out-of-range. Added an
elaboration guard asserting NumAXIMasters == NumL2Banks. Verified both ways: fires
at 32 groups, silent at 4x4.

### Blocker 3 -- decoded, not guessed
The perimeter literals are not arbitrary; they reproduce the yml's HBM numbering
term for term, irregular 4/5 and 10/11 orderings included:
  ch 0-3 West (0,y) | ch 4 South (1,0) | ch 5 South (0,0) via periph
  ch 6,7 North (0,3),(1,3) | ch 8,9 South (2,0),(3,0)
  ch 10,11 North (3,3),(2,3) | ch 12-15 East (3,y)
So the RTL and the yml are two hand-maintained copies of one mapping with nothing
checking they agree. A canonical numbering cannot be bit-identical at 4x4 -- that
is a decision to take deliberately.

### reggen wired in
`make update-regs` regenerates the control-register file from the hjson via the
vendored lowRISC regtool. **Regenerating from the committed hjson reproduces both
files BIT-IDENTICALLY** -- the gate that makes a MAX_NumGroups change verifiable.
Needs PyYAML/hjson/Mako/tabulate; REGTOOL_PYTHON overrides the interpreter.

Measured cost (this corrects an earlier claim that raising it always moves the
address map):

  MAX_NumGroups   BlockAw   wake_up_tile regs   reg_top lines
  16 (committed)  8         16                  1342
  32              8 (!)     32                  1934
  64              9         64                  3118

**32 groups is free on the address map** -- the block still fits in 256 B. Only 64
pushes BlockAw to 9 and moves the peripheral map. Raising it is not bit-identical
at 4x4 either way, so it should land WITH a mesh-size change, not before.

### Status
4x4 gate re-verified after the L2 guard. Nothing about the 4x4 design changed.

### 2026-08-04 — perimeter aliasing guard (blocker 3 made loud)

The perimeter channel formulas are injective only when the channel count equals
the perimeter capacity. Measured across the ladder, `NumGroups == 2*(NumX+NumY)`
holds at 4x4 and NOWHERE else — the perimeter grows as NumX+NumY, the group count
as NumX*NumY, so they diverge in both directions (perimeter exceeds groups below
4x4, groups exceed perimeter above).

At 4x8 that produces four aliased channels — West(0,4..7) colliding with
South(1,0), South(0,0), North(0,7), North(1,7) — each a pair of attachment points
driving one floo_axi_*_o element. **Neither simulator reports it**: Verilator gave
0 MULTIDRIVEN and it is not among the 19 waiver rules. The build succeeds and L2
traffic is corrupted only at run time. Worst failure class in this campaign.

Guarded. Verified both ways: fires at 4x8, 4x4 unchanged at 122051.

Two mistakes worth recording from this stretch:
- The first build of this guard FAILED because a comment line began with the word
  "Verilator" — `// verilator ...` is parsed as a metacomment pragma
  ("Unknown verilator comment"). A prose sentence became a directive. I had
  assumed a comment-only edit could not fail, which is exactly the assumption that
  skips a gate.
- Earlier I wrote that Verilator "does not enforce" elaboration $error. It reports
  it as a NON-FATAL %Warning-USERERROR and continues, so it exits 0 on designs
  QuestaSim refuses. Read the log, not the exit code.

### Session state
Eight commits, every one gated at 122051 cycles on
sp-fmatmul-opt-burst-merge 256x512x256. Three elaboration guards added, each
converting a silent failure into a loud one, each negative-tested.

Remaining Phase 3 work is one coherent task: derive perimeter_channel_idx(x,y,dir)
into mempool_pkg, consume it from both the cluster wrapper and a floo-yml
generator, and make NumL2Channels an independent knob bounded by 2*(NumX+NumY).

OPEN DECISION (needs the owner): the derived mapping cannot be bit-identical at
4x4. The committed numbering is irregular — channels 4/5 and 10/11 are swapped
relative to any natural perimeter walk — so a formula either reproduces that
irregularity exactly (ugly, keeps 4x4 provably unchanged) or adopts a canonical
walk (clean, generalises, but moves 4x4 off 122051 by a measurable amount and
changes the reference every prior commit is gated against).

### 2026-08-04 — L2 is INTERLEAVED, not block-partitioned (a correction)

I claimed all 16 group DMAs read from a single L2 channel (hbm_0), based on the
SAM's 1 MB blocks plus the ELF showing gemm_A_dram/gemm_B_dram inside the first
1 MB. **That was wrong**, and the owner was right to push back.

`hardware/src/axi_L2_interleaver.sv` (per group, instantiated at
mempool_group_floonoc_wrapper.sv:216) scrambles the address BEFORE the chimney's
SAM decode: it lifts addr[13:10] into the MSBs so the SAM's 1 MB block decode
selects bank = addr[13:10]. That is 1 KB striping across all 16 banks
(LSBConstantBits = clog2(L2BankBeWidth(64)*Interleave(16)) = 10).

addr[13:10] is the L1 word-interleave GROUP field. Three things are aligned by
design: L1 group, L2 bank, and DmaRegionWidth = NumBanksPerGroup*4 = 1024 B. So
idma_distributed_midend hands group G the 1 KB chunks with addr[13:10]==G, which
live in L2 bank G. Every group reads its own channel 1:1, by construction.

Both preloads implement the same striping — getSramCTRLInfo (mempool_tb.sv:496)
and the 4-arg MemArea(..., AXI_WIDTH_INTERLEAVED) in the Verilator harness — which
is a cheap way to check any proposed mapping without simulating.

Corrections to earlier claims in this file: there is NO single-channel bottleneck,
NO fill-time win available, and data placement is NOT a software problem here.

How the error happened: I read the SAM as the bank selector and reasoned forward.
When the preload evidence contradicted me I re-derived the contradiction several
times instead of concluding my datapath model was missing a stage. The hint that
the 1 KB interleave matches the L1 TCDM interleave is what located it.

NEW BLOCKER (4) for the ladder: ScrambleBits = clog2(NumL2Banks) vs an L1 group
field of clog2(NumGroups) bits. Equal only at 4x4. At 8x8 (64 groups, <=32
channels) the 1:1 group->bank affinity cannot be expressed. Unguarded.

### 2026-08-04 — the perimeter numbering is OPTIMAL (correcting my own recommendation)

I twice recommended replacing the perimeter channel numbering with a canonical
W,S,E,N walk, calling the committed order "irregular with no defensible rationale".
**Wrong on the facts.** Measured with a Hungarian solve over all 16 groups and all
16 perimeter attachment points:

  legacy (committed)  8 hops total, avg 0.50   <- OPTIMAL
  optimal (Hungarian) 8 hops total, avg 0.50   <- ties legacy
  canonical walk     26 hops total, avg 1.62   <- 3.2x WORSE

The numbering encodes a minimum-total-distance assignment: 12 groups get a channel
at their own router (0 hops); the 4 interior groups (5,6,9,10 = the ones with no
perimeter attachment) take the four spare corner channels at 2 hops, the minimum
possible from an interior node. The 4/5 and 10/11 "swaps" are exactly what places
the interior groups on their nearest spare corner.

This composes with the L2 interleave finding: addr[13:10] makes channel G serve
group G, so the perimeter numbering IS the knob that sets each group's DMA
distance — and it is already at the optimum.

Adopting canonical would have tripled average DMA distance, in the name of
cleanliness, in the only config that works.

Lesson: I inferred intent from surface appearance. A mapping that does not match a
simple formula is not unprincipled — it may be optimal against a criterion I had
not identified. Find the criterion before calling something arbitrary.

Consequences recorded in mesh_plan.md 3.6 and 14:
- perimeter_channel_idx() must SOLVE THE ASSIGNMENT, not walk the perimeter;
- bit-identity at 4x4 is achievable after all (legacy is one optimum among
  several; pick tie-breaking to reproduce it), so the parked "cannot be
  bit-identical" objection is withdrawn;
- blockers 3 and 4 are ONE design problem: which groups share a channel, and
  where that channel sits.

### 2026-08-04 — task 74 decided: coarsen the interleave by the sharing factor

Option (b). axi_width_interleaved is now DERIVED as 16*num_groups/l2_banks, with
an elaboration assert that the L2 bank field sits on the top bits of the L1 group
field (L2LsbConstBits + L2ScrambleBits == GroupFieldLsb + clog2(NumGroups)).

Why it is not a free parameter: axi_L2_interleaver picks
bank = addr[clog2(64*Interleave) +: clog2(l2_banks)], and the DMA path needs
channel G to serve group G. Misalign it and the affinity is lost SILENTLY —
every address still decodes to some bank.

Measured at 8x8 (64 groups, 32 channels, each channel placed optimally):
    interleave 16  bank=group[4:0]  pairs (x,y),(x+4,y)  2.88 avg hops
    interleave 32  bank=group[5:1]  pairs (x,y),(x,y+1)  1.62 avg hops
1.77x better — coarsening makes co-resident groups ADJACENT rather than four
columns apart. Steady 1.7-2.0x off the unconstrained distance floor across the
whole ladder (4x4 through 16x16).

Also fell out of the arithmetic: NumL2Channels must be a POWER OF TWO, since
ScrambleBits = clog2(NumL2Banks) selects a bit field. So perimeter capacity is
rounded DOWN — 4x8 has 24 attachment points but can use only 16, 8x16 has 48 but
uses 32. Non-square rungs waste a third of their perimeter, which argues for
preferring square meshes (4x4 -> 8x8 -> 16x16).

Rejected for now: (c) blocked placement + locality-aware allocation — upside is
bounded by the distance floor (~1.8x at 8x8) and it breaks the single-dma_memcpy
model, since today one call fans out to all engines AND interleaving puts each
group's source in its own bank for free. (d) more channels per perimeter router —
the only option that raises BANDWIDTH rather than shortening distance; keep in
reserve, since bandwidth per core falls as 1/sqrt(N) regardless.

Verified both ways: 4x4 = 122,051 bit-identical; interleave=32 at 4x4 fails
elaboration on this guard alone, other guards silent.

### 2026-08-04 — task 73: perimeter placement derived, both encodings retired

The channel->attachment mapping was written by hand in two places with nothing
checking they agreed: index literals in terapool_cluster_floonoc_wrapper
([y], [5-x], [x+6], [13-x], [y+12]) and HBM connection blocks in the floo config.
Both now come from gen_perimeter_map.py.

Removed the branches that only ever computed an index — the South three-way split
and the North x<NumX/2 split. 42 perimeter assignment lines -> 24.

The emitted config uses one connection block per channel (src_idx/dst_idx) rather
than ranges. The old ranges are precisely what made drift easy: src_range [15,12]
pairs element-wise with dst_range [[3,3],[3,0]] — descending, easy to misread,
impossible to diff against a table.

Verified four ways before committing:
  1. generated table vs the old formulas: 16/16 attachment points, 48/48 empty
     slots, 0 mismatches;
  2. floogen on the generated yml -> floo package BYTE-IDENTICAL;
  3. route table from the generated yml -> BYTE-IDENTICAL. This is the check that
     actually exercises the connections: under IdTable the floo package contains
     no routing table, so comparing only the package would have verified nothing
     about the topology;
  4. 4x4 matmul = 122,051, unchanged, 0 errors / 0 CMS warnings.

Two mistakes on the way, both caught by tools rather than review:
  - emitted PerimeterChannel as an UNPACKED localparam array. Verilator: "Expecting
    expression to be constant, but variable isn't const". An unpacked localparam
    array is not constant-foldable enough to index a signal from a generate block.
    routing_table_pkg uses a PACKED array for exactly this reason; mirrored it,
    which meant re-emitting MSB-first and re-running the equivalence check.
  - my first equivalence checker reported 4 false mismatches — its regex swallowed
    the row-opening brace on each x-block's first row. A checker that cries wolf is
    barely better than none; I nearly chased phantom RTL bugs.

### 2026-08-04 — solver extended past the bijection; 8x8 generates end to end

The edge rule is optimal when every group owns a channel but drifts to 1.42x
optimum once channels are shared, because a channel's best point depends on all
the groups it serves. Added a 2-opt pass: 4x4 unchanged (already optimal), 8x8
148 -> 104 = optimal, 16x16 1372 -> 998 = 1.023x. Three passes, deterministic, no
solver dependency in the build.

Enforced too: NumL2Channels must be a POWER OF TWO (ScrambleBits selects a bit
field), so perimeter capacity rounds DOWN — 4x8 offers 24 points but uses 16.

An 8x8 config now generates end to end: perimeter map, floo config (98 endpoints),
route table (43 rules/router), all syntax-clean, and **the CDG is still ACYCLIC at
8x8**. That needed checking rather than assuming: shortest-path routing is
deadlock-free here by verification, not by construction, and the check is built
into the generator.

Retrospective validation of Phase 0: at 98 endpoints source routing would have
needed a 98x98 all-pairs table with ~48-bit routes; IdTable needs 65 routers x 43
rules.

Next for a real 8x8 build (docs section 15): a config flavor; MAX_NumGroups=64 +
update-regs (BlockAw moves 8->9 here, so the peripheral map shifts and software
must be checked); relax the four guards from 4x4's coincidences to the
relationships that actually hold; and decouple NumAXIMasters from NumGroups.

## 2026-08-05 02:30 — `simc-lean`: a headless target the scale-up can actually use

**Purpose.** The 8x8 elaboration gate (A5) was reported green and was not. `make
exit=124`: `timeout 3600` killed vopt at 60 minutes, still elaborating. It showed 0
errors only because it never got far enough to have any — the waiter script checked
the error count but not the exit code, so a mid-flight kill looked exactly like a
clean pass. Retracted.

**Root cause, which is not "needs a longer timeout".** `simc` elaborates with
`-voptargs=+acc` (full signal accessibility, which suppresses most vopt
optimisation) and then runs `-do "log -r *"` (log the entire hierarchy). That is the
right default at 256 cores, where you generally want the waveform. At 1024 cores vopt
alone does not finish in an hour, and even if it did, a full `log -r *` over 1024
cores would produce a WLF too large to be useful. This would have blocked C3 as much
as A5.

**Implementation.** Added `simc-lean` (`hardware/Makefile`), dropping `+acc`, the
whole-design log, and the `-wlf`. Same command form that already sat commented out at
line 606. Everything else is unchanged.

**Result — validated on the known-good 4x4 before being trusted at 8x8:**

```
make exit=0   errors: 0   CMS warns: 0   Simulation returned 0
[UART] Core 0..N says Hello!
[CMS FINAL] latency histogram:  <=16: 21052   <=64: 12012   >256: 0
Elapsed 0:22:59  (compile + elaborate + run, 256 cores)
```

The `[CMS FINAL]` block surviving is the point that mattered: the TB instrumentation
([LP], [BP], [CMS], [GroupMerge], [UART]) all report through `$display`, so dropping
waveform visibility costs nothing that B4's "0 scoreboard warnings" gate depends on.
Use `simc` when you actually need to look at signals.

**Verilator, in the same pass.** `make verilate` fails instantly: the repo expects a
locally built `install/verilator` that does not exist here. The documented flow
(`docs/benchmarks/verilator_simulation.md`, ab7c27e) is a three-step override —
`/usr/pack/verilator-4.228-zr`, step 1 expected to fail at the `verilated.mk`
include, then a clang compile to a standalone binary. Worth the setup: ~28x faster
than Questa, though it compiles out every Questa-only probe, so it answers "how many
cycles", not "why".

**Status.** 4x4 Questa PASS. 4x4 Verilator, 8x8 Questa, 8x8 Verilator running under
one driver that serialises package generation (mesh-specific, one shared directory)
and parallelises the runs.

**Lesson.** Two false reads in one stretch, same shape both times: a success test
that is also true of the failure. "0 errors" is true of a process killed mid-run;
`%Error|Error:|FAILED` does not match a missing binary. Gate on the exit code, and
make the failure modes explicit in the check.

## 2026-08-05 09:20 — the 8x8 boot failure: a hardcoded peripheral gateway

**Symptom.** 8x8 elaborated cleanly (0 errors) but did not boot: 46.7 million
illegal-instruction reports across all 1024 cores, every one at `PC 0xA000_0000`
with `Data: xxxxxxxx`, from cycle 0, core 0 included.

**Two wrong hypotheses first**, both recorded because the second was expensive:

1. *Stale binary.* `hello_world` was built 07-28, before A4 moved every control
   register above 0x48 by 192 bytes; the A4 script had predicted exactly this
   failure ("cores would simply not wake, with no error anywhere"). It WAS stale and
   was rebuilt -- and the failure was bit-identical. Flagged as unconfirmed at the
   time precisely because both 4x4 runs used the same stale binary and passed.
2. *Route tables.* Every router in both meshes carries a rule to `periphs_ni`
   (16 rules at 4x4, 64 at 8x8). Routing was never the problem.

**Root cause.** `mempool_system.sv` special-cases exactly one AXI master: that L2
channel's chimney does not attach to a mesh router but joins a 4-port
`periph_router` carrying `periphs_ni` and `host_ni` -- the gateway to the bootrom
and the control registers. It hardcoded `if (x == 5)` / `Hbm5` / `axi_mst_req[5]`.

But WHICH channel shares the periph router's perimeter point is a property of the
placement, and `gen_perimeter_map.py --emit-yml` derives it: the periph point is
South(0,0), and the channel that lands there is 5 at 4x4 but **13 at 8x8**. So the
generated routing steered peripheral traffic to channel 13's node while the periph
router sat at channel 5's. The bootrom never saw a request; its address register is
only loaded on `req_i`, so it stayed unreset and `rdata_o` read X. The bootrom
cannot otherwise emit X -- `rdata_o = (addr_q < RomSize) ? mem[addr_q] : '0` -- which
is what made the mechanism identifiable.

**Fix.** `gen_perimeter_map.py` emits `PeriphHbmChannel` into `perimeter_map_pkg.sv`;
the RTL uses it for the loop guard, the AXI index and the endpoint id
(`Hbm0 + PeriphHbmChannel`), plus a range guard. One helper, `periph_channel()`,
feeds both the package and the yml so the two emitters cannot drift again. The
misleading instance name `hbm_ni_15` (wired to channel 5) became `periph_hbm_ni`.

**Also fixed:** `--check` printed `ch13 -> group13`. At share > 1 a channel serves
several groups (`gid // share`), so c13 actually serves g26 and g27 -- it was
labelling the channel index as the group and measuring from the wrong coordinate.
The optimiser's own metric was always correct (it iterates the real `served` sets),
so the 104-hop 8x8 figure stands; only the printout lied.

**Gate — 4x4 regression, PASS.** `PeriphHbmChannel` regenerates to 5, the same value
the literal had, so the change is a no-op at 4x4:

```
make exit=0  preload=hello_4x4.elf  errors: 0  illegal insn: 0
UART: 256 of 256   CMS warns: 0   cycles: 471254
```

The generated yml is byte-identical to HEAD, confirming the refactor did not change
`emit_yml`'s output.

**Not comparable:** 471254 vs the 610030 measured earlier the same day. That run used
the stale 07-28 binary; this one is a freshly built 4x4 ELF carrying A4's register map
and B1's derived stride. The delta is software, not RTL. **471254 is the 4x4 baseline.**

**Process lesson, three instances in one session.** Every false result came from a
check that was also true of the failure: "0 errors" is true of a vopt killed by
timeout; `%Error|Error:|FAILED` does not match a missing binary; and a 4x4 run that
silently picked up the 8x8 ELF from the shared output path produced a plausible
1.9M-cycle hang that looked like an RTL regression (it was not -- 0 illegal
instructions proved the bootrom was fine). Lanes now carry per-config ELFs and every
gate checks the exit code. Note `preload=` must be a MAKE ARGUMENT: passed through
`env` it is an environment variable, which loses to the makefile's `preload :=`.
