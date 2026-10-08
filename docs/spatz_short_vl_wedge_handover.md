# Handover: Spatz wedges on short vectors when switching between IPU and FPU

**Owner wanted:** an agent to root-cause and fix this in the Spatz RTL. Written 2026-09-30 by the
qwen-ffn-down (Qwen FFN down projection) software effort, which works around it in software and
continues independently. Read CLAUDE.md first: its build and simulation gotchas all apply.

---

## 1. The bug in one paragraph

A Spatz core stops forever (every later instruction stuck, the core 100% in `acc` stall) when a
vector instruction on one functional unit follows an instruction on the **other** unit -- integer
unit (IPU) after FPU, or FPU after IPU -- and the vector length is **at most one element per lane**
(vl <= 4 at e32 with 4 lanes). Dependent pairs on the SAME unit are fine at every length, and the
same cross-unit sequences run fine at vl >= 5. No error, no assertion, no timeout: the machine just
freezes. GVSoC does not model it.

Measured with a directed probe on the 4x4 image (all cores run the same sequence, e32/m4):

| phase | sequence | result |
|---|---|---|
| P0 | `vfcvt.x.f.v v16` -> `vfcvt.f.x.v v20, v16` (FPU -> FPU, dependent) | OK at vl 8..1 |
| P1 | `vadd.vx v16` -> `vsll.vi v16, v16` (IPU -> IPU, dependent) | OK at vl 8..1 |
| P2 | `vfadd.vv v16` -> `vadd.vx v16, v16` (FPU -> IPU, dependent) | **wedges at vl = 4** (8, 7, 6, 5 pass; trace-confirmed) |
| P3 | `vfcvt.x.f.v v16` -> `vadd.vx v16, v16` (conversion -> IPU) | **wedges** |
| P4 | `vfmacc` chain on v24/v28, then `vadd.vx` on unrelated v16 (NOT dependent) | no marker after ~86k cycles, cores 75-100% `acc`: **almost certainly wedges** (confirm) |
| P5 | `vadd.vx v16` -> `vfadd.vv v20, v16` (IPU -> FPU, dependent) | **wedges** |
| P6 | the qwen-ffn-down SwiGLU body (where it was found) | **wedges** at vl 2 and 4, OK at 8 |

P4 suggests the trigger is the unit SWITCH itself, not the data dependency. That is the most
important open question for the fix (section 5).

How it was found: qwen-ffn-down's SwiGLU (`software/apps/spatz_apps/qwen-ffn-down/swiglu.h`) builds
2^n with `vadd.vx`/`vsll.vi` on the output of `vfcvt.x.f.v`; with 2 or 4 elements per core every one
of 256 cores stopped with `vadd.vx v16, v16, a7` as its last issued instruction and the next
(`vsll.vi`) never issued.

## 2. Where the code is

- **Spatz RTL actually compiled:** `working_dir/spatz/hw/ip/spatz/src/` (via `Bender.local`:
  `spatz: { path: "working_dir/spatz" }`). NOT `hardware/deps/spatz`, which is stale and unused
  (CLAUDE.md). `working_dir/spatz` is its own git repo, branch `zexin/rob32_partial_commit`, HEAD
  `b040b94`; remotes `origin` (pulp-platform/spatz, only our branches fetched) and `yinrong/*`.
  HEAD is 71 commits ahead of its merge-base with `yinrong/main` (`6abaa040`).
- **Probe app:** `software/apps/spatz_apps/sp-vfu-short-vl-probe/main.c`, on branch
  `zexin/qwen-ffn`, commit `3943edea`, in the worktree `/usr/scratch/fenga1/zexifu/qwen_ffn_wt`.
  Knobs via `EXTRA_DEFINES`: `-DPROBE_FIRST_PHASE=n` (start at phase n), `-DPROBE_LMUL=1` (m1
  instead of m4), `-DPROBE_ITERS=n`.
- **Prebuilt probe ELFs (4x4):** `hardware/elf_ffn/probe/vprobe_m4.elf` (all phases) and
  `vprobe_p{2..6}.elf` (starting at that phase), each with its `.dump`.
- **Trace-enabled 4x4 VCS image:** `hardware/build_ffn_dbg/mempool_simvopt` (config
  `terapool_spatz4_fpu`, current defaults, `snitch_trace=1`). The fleet image
  `hardware/build_split_vcs_mr4/mempool_simvopt` (no trace, somewhat faster) reproduces it too.
- **Existing runs to look at:** `hardware/dbg_vp2_dbg/` (P2, traced: all 256 cores' last PC
  `0x80000988` = `vadd.vx`), `hardware/dbg_vp{3,4,5,6}_mr4/`, `hardware/dbg_vprobe_mr4/`.

## 3. How to reproduce (about 10 minutes on the 4x4 image)

```sh
cd /usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware
R=my_repro; mkdir -p $R; printf 'run 40000 ns\nquit\n' > $R/cmds.tcl
cd $R && ../build_ffn_dbg/mempool_simvopt -ucli -do cmds.tcl \
    +PRELOAD=$PWD/../elf_ffn/probe/vprobe_p2.elf -l transcript > sim.out 2> sim.err
```

- **Always end with `quit` from `-ucli`** (a bounded `run`), never kill the simv: VCS buffers the
  per-hart `trace_hart_*.dasm` files and a killed run leaves them empty or stale.
- 1 cycle = 2 ns. A 4x4 run with the trace image does ~3k cycles per minute on a loaded fenga1.
- **Verdict:** each passing phase prints `[VPROBE] <phase> OK` (Questa/VCS transcript lines start
  with `# `; strip it). A wedge = no further marker AND `[STALLG]` showing `acc= 16000,...` in all
  16 groups. The probe prints `ALL_DONE` when every phase passes.
- **Which vl:** in a hart's trace, the last `vsetvli` (PC `0x80000960` in `vprobe_p2`) before the
  hang has the requested AVL in its `'opa'` field.
- 4x4 only needs `hardware/generated/` at 4x4 when BUILDING an image; running an existing image does
  not read it.

## 4. Candidate cause (unverified)

The IPU<->FPU state switch in `spatz_vfu.sv` (`control_proc`, ~l.273-293) is **unchanged from
upstream** (`fa9ef70`): an FPU instruction in `VFU_RunningIPU` stalls until `!is_ipu_busy`, an IPU
instruction in `VFU_RunningFPU` stalls until `!is_fpu_busy`. So a wedge at the switch most likely
means a **busy flag that never clears** -- `is_fpu_busy = |fpu_busy_q` (~l.1110, per-FPU-lane) or
`is_ipu_busy = |int_ipu_busy` (~l.939) -- or a result that is never retired, when the instruction
occupies a single, partially filled VRF word (vl <= lanes: some lanes are never fed). That fits
P4 (no dependency needed). It would also be consistent with vl=5..8 passing (two words: the last
word is partial but the first is full).

`spatz_vfu.sv` carries eight local commits since upstream, and several change exactly how results
are completed and retired:

| commit | date | author | subject |
|---|---|---|---|
| `f349e24` | 2026-08-28 | Yinrong Li | Record both hazards on the VFU completion mask |
| `7a547ba` | 2026-08-27 | Yinrong Li | Add word-parallel tree reduction to the Spatz VFU |
| `3ea3e17` | 2026-08-27 | Yinrong Li | Drain non-reduction Spatz VFU results during a reduction |
| `4189892` | 2026-08-27 | Yinrong Li | Emit Spatz VFU response only when the result is consumed |
| `8fa4d47` | 2026-08-27 | Yinrong Li | Describe retiring Spatz VFU results by their own tag |
| `0279d6b` | 2026-08-27 | Yinrong Li | Fix fp16 scalar-FP-extract deadlocks |
| `37c8c33` | 2026-08-19 | Zexin Fu | spatz_pkg: adapt the FPU config to cvfpu pulp-v0.3.0, move PipeConfig to INSIDE (changes FPU pipelining) |
| `5b3136f` | 2026-08-19 | Zexin Fu | spatz_vfu: take the completion mask width from result_tag, not spatz_req |

(`git -C working_dir/spatz log --since=2026-08-01 -- hw/ip/spatz/src` lists all 43 local commits;
the rest are VLSU/burst work.) Whether plain upstream `fa9ef70` also wedges is **not known** --
establishing that is the cheapest way to decide between "our regression" and "upstream bug".

## 5. Suggested plan

1. **Look before bisecting.** Dump the VFU state of one wedged core: `state_q`, `is_fpu_busy`,
   `fpu_busy_q`, `is_ipu_busy`, `int_ipu_busy`, `result_valid`, `pending_results`, `running_q`,
   `spatz_req_valid`, `stall`. Either a Questa GUI run of `vprobe_p2.elf` (`make sim ... preload=`),
   or a `$display` probe in the TB. If a busy bit is stuck, the fix location is immediate.
2. **If not obvious, bisect** the eight commits above (upstream `fa9ef70` as the known-old point)
   with `vprobe_p2.elf` as the test: each step is a 4x4 VCS image build (~10 min compile) plus a
   ~10 min run.
3. **Confirm P4** (independent) with the traced image; it decides whether the fix is about the unit
   switch or about dependency tracking.
4. **Extend the probe** before calling it fixed: e16 (one VRF word = 8 elements, so the boundary may
   be vl <= 8), m1 (`-DPROBE_LMUL=1`), and widening/narrowing ops (`vfwadd`, `vfncvt`), which the
   SwiGLU code also uses.

## 6. Definition of done

- The probe prints `ALL_DONE` with all 7 phases OK at m4 and m1, and at e16 once added.
- qwen-ffn-down's SwiGLU works WITHOUT its workaround (2 elements per core):
  ```sh
  cd /usr/scratch/fenga1/zexifu/qwen_ffn_wt/software/apps/spatz_apps/qwen-ffn-down
  script/build.sh 4x4 nowa_b1_k512 $OUT ffn_b=1 ffn_k=512 ffn_check=1 ffn_preload=1 \
      EXTRA_DEFINES=-DFFN_SW_MIN=2
  ```
  must print `success!` on the fixed image (it wedges on today's images).
- No regression: `sp-fmatmul-opt-burst-merge-fp16` and `qwen-gate-up` calibration ELFs
  (`hardware/elf_split/ks2/c4_b1_p1.elf` = 23,851 cycles, `kt/kc4_auto_small.elf` = 74,122 on
  `build_split_vcs_mr4`) give identical cycle counts on the fixed image (the fix should not touch
  the vl >= 5 path).
- Committed in `working_dir/spatz` with a brief imperative message (no AI-tool mentions), the
  Spatz revision bumped where the main repo pins it (stage only that hunk of `Bender.lock` -- see
  CLAUDE.md, the working-tree lock is not the committed one), WORKLOG entry in the main repo.

## 7. Constraints (other agents share this repo)

- **`hardware/generated/` is shared** by every build dir and is mesh-specific (CLAUDE.md). Check
  `grep NumMeshX hardware/generated/perimeter_map_pkg.sv` and `pgrep -alf 'vlog|vcs|vopt'` before
  building; back up and restore around a regeneration. For a bisect, an isolated clone of
  `working_dir/spatz` checked out per step is safer than moving the shared checkout's HEAD while
  others build from it -- coordinate with the user before changing what `working_dir/spatz` points at.
- **VCS licences** (`scripts/badist/teranoc_fleet.py license`) are shared; local debug runs each hold
  a seat. Never cancel or kill runs you did not start.
- New images: name them clearly (e.g. `build_spatzfix_vcs_4x4`), keep the `+define+` set identical
  to `build_split_vcs_mr4` apart from what the fix needs, and record the diff.
- **Include the Snitch fix `df049c78`** in any new image: `fmv.w.x` / `fcvt.s.w` used to also write
  the integer register x[rd] (`hardware/deps/snitch/src/snitch.sv`). Existing images do NOT have it,
  and any C int-to-float conversion corrupts a register on them. The probe avoids both.

## 8. Related context

- Spatz VFU completion-mask history: `spatz_vfu.sv` ~l.153-180 (long comment) and the memory note
  on the August fp16 wedge (a different hazard, already fixed at l.179).
- The software workaround in qwen-ffn-down: `FFN_SW_MIN = 16` in `main.c` (commits `ac6769dc` and `934e40fe`)
  on `zexin/qwen-ffn` -- keep it after the fix; it costs nothing at real sizes.
- WORKLOG.md entries of 2026-09-29/30 describe the investigation.
