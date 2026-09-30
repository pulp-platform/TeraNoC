# Spatz short-vector completion and load retirement

The real VFU accepts an FPU word into `fpu_in_valid_q` before the registered
`fpnew` busy indication reaches `fpu_busy_q`. When the following instruction
uses IPU, the original switch logic sees an idle FPU and switches away. An
IPU writeback then asserts the shared `result_ready`, consuming the hidden
FPU result without its VRF write or VFU completion response. Its controller
scoreboard entry stays allocated. Neither busy signal needs to stay high.

At e32 with four lanes, vl <= 4 needs just one word and exposes this gap.
Ordinary vector operations feed every lane, including inactive tail lanes;
this is not a missing tail-lane result. Longer instructions issue another
word while the FPU busy indication catches up. Same-unit sequences retain
the result selection. Repeated IPU/FPU pairs also contain FPU/IPU switches.

The fix includes the valid bits of the FPU input registers in `is_fpu_busy`.
The upstream VFU at `fa9ef70`, tested with today's packages and FPU
implementation, has the same lost-completion behavior. This does not prove
that the complete historical upstream configuration reproduces it.

Two additional hazards appeared during validation:

- Scalar FPU work uses lane 0. Retiring a scalar through the shared ready
  signal could consume a younger vector result on the other lanes. FPU
  output ready is now masked by the retiring instruction's lane mask.
- A backpressured lane could prevent a vector word from issuing while
  other lanes independently accepted it. Input acceptance is now atomic
  across the participating lanes. The lane-skew test catches this even
  when the duplicated word happens to produce the expected numeric data.

The SwiGLU sequence also exposed a slide-unit completion bug. Vector moves
execute in `spatz_vsldu`, whose output spill register holds two writes,
while its old response FSM stored one completion ID. A second one-word
move could finish before the first write was granted, losing its completion
or mislabelling a buffered write. Each buffered write now carries its own
ID and final-word marker; completion follows the final write grant.

## Focused regression

From the repository root:

```sh
python3 hardware/tb/spatz_short_vl/run.py \
  --buildpath hardware/build_spatz_short_vl_verified_v2 --trace
```

The testbench models VRF data, byte readiness, and backpressure around the
real VFU, IPUs, and cvfpu. It checks 705 cases, including e32 vl 1..8, e16
vl 1..16, both unit orderings, same-unit controls, dependent and independent
registers, conversion, FMA, widening add and narrowing conversion. Every
case requires both completions, rejects duplicate responses, and checks
active destination bytes. Widening requests use the controller's doubled
VL convention. `--rtl-file` selects an alternative VFU for comparison;
`--long-only` runs 352 multiword cases and prints their cycle counts.

The build directory contains source snapshots, SHA256 hashes, commands,
compile/run logs, and `vfu.wlf`. The baseline fails the first independent
FPU/IPU case with `completed=0010`. The fixed RTL passes all 705 cases.
All 352 multiword cases have identical original/fixed cycle counts.

Additional tests:

```sh
python3 hardware/tb/spatz_short_vl/run.py \
  --buildpath hardware/build_spatz_short_vl_skew_verified_v2 --skew
python3 hardware/tb/spatz_short_vl/run.py \
  --buildpath hardware/build_spatz_short_vl_mixed_verified_v2 --mixed
python3 hardware/tb/spatz_short_vl/run.py \
  --buildpath hardware/build_spatz_short_vl_skew_add_verified --skew-add
python3 hardware/tb/spatz_short_vl/run.py \
  --buildpath hardware/build_spatz_short_vl_chain_full --integration
```

The integration test uses the real decoder, controller, VRF, VFU, and slide
unit. It varies instruction spacing and exercises repeated FMA/IPU chains
and vector-move/FMA pairs at e32/e16 and m4/m1, including full-register and
tailed multiword lengths. It checks 9,600 moves for write IDs, addresses,
byte enables, data, and completions. The original slide RTL fails with
`slide completed before all writes`. `--slide-file` selects an alternative
slide RTL for comparison. `chain.vrf` and `chain.con.scoreboard_q` expose
the real dependencies; all signals are recorded in `vfu.wlf`.

Useful wave paths:

- `tb.dut.state_q`, `tb.dut.is_fpu_busy`, `tb.dut.gen_fpu.fpu_busy_q`
- `tb.dut.gen_fpu.gen_fpnew[0].fpu_in_valid_q`
- `tb.dut.fpu_result_valid`, `tb.dut.result_valid`, `tb.dut.result_ready`
- `tb.dut.vfu_rsp_valid_o`, `tb.completed`

## Load-path regression

The original raw-load probe exposed two independent VLSU hazards:

- Non-burst padding compared lane byte counts before rounding to memory
  words. For e16 VL=15, every lane needs two requests, although lane 3 has
  six active bytes versus eight on the other lanes. The old logic created
  an extra dummy on lane 3. Three loads explain the observed ROB allocation
  divergence `[13,13,13,16]`.
- A partial burst row creates dummy entries on its unused lanes. The old
  dummy drain ran only in store mode. A dummy left at the ROB head could
  satisfy a younger load's data-ready check and write zeros. Dummy entries
  now drain in both modes and cannot qualify as load data, decrement a
  pending-beat count, or pop a real response's offset.

The isolated `build_spatz_load_followup/` reproducer writes all 30 active
bytes but leaves ROB IDs `[2,2,2,3]`; its nonburst VL=16 control leaves
`[2,2,2,2]`. The original VLSU also fails the e32 sweep with a zero write
at offset 12 of the second load. Fixing padding alone still fails that
case, so both changes are required.

```sh
python3 hardware/tb/spatz_short_vl/run.py --loads --trace \
  --buildpath hardware/build_spatz_load_sweep_verified
python3 hardware/tb/spatz_short_vl/run.py --loads --load-dual 1 \
  --buildpath hardware/build_spatz_load_sweep_serial
python3 hardware/tb/spatz_short_vl/run.py --loads --load-block-alloc 0 \
  --buildpath hardware/build_spatz_load_sweep_walk
python3 hardware/tb/spatz_short_vl/run.py --loads --rob-count-id 0 \
  --buildpath hardware/build_spatz_load_sweep_legacy_ids
```

All four configurations pass 1,728 cases and 5,184 completions each. The
real VLSU and ROBs receive three consecutive loads with distinct source
addresses. The backend expands bursts into lanes/ROB rows, delays and
reorders responses, and applies memory and VRF backpressure. The checker
requires correct active bytes exactly once, correct destination IDs and
addresses, completion after all writes, no remaining responses or pending
beats, and equal lane allocation pointers after draining. The default sweep covers
e8 VL=1..64, e16 VL=1..32, e32 VL=1..16, word and supported subword offsets,
bank-stripe crossings, and two strided profiles. It does not exercise
indexed loads, stores, or nonzero vstart.

The maximum m4 sweep also passes 6,912 cases / 20,736 completions and
requires a full ROB to have been observed. It extends the ranges to e8
VL=256, e16 VL=128, and e32 VL=64:

```sh
python3 hardware/tb/spatz_short_vl/run.py --loads --load-long \
  --buildpath hardware/build_spatz_load_sweep_m4_capacity_verified
```

Each directory preserves the exact Questa commands, sources, hashes,
logs, and `vfu.wlf`. Useful paths are
`mempool_tb.dut.rob_dummy`, `rob_pop`, `rob_id`, `mem_pending_q`,
`commit_insn_q`, `commit_counter_q`, and `vrf_req_d`.
`--load-file` selects alternative VLSU RTL; `--load-e32` skips e8/e16 to
reproduce the original partial-burst failure independently of padding.

## Full-system validation

`probe.c` extends the handover probe with `PROBE_SEW=16|32` and
`PROBE_LMUL=1|4`, and adds P7 for widening/narrowing. Build it as the
`sp-vfu-short-vl-probe` app in a private software worktree. Preserved ELFs
and the software manifest live in `hardware/elf_spatzfix/`.
The arithmetic probes under `arithmetic/` initialize registers once per
phase with VL=16 loads and fence before varying arithmetic VL. All four
iterations per VL are retained. They isolate the VFU and slide changes
from the load-path defects. The original extended variable-length-load
source is preserved as `probe_unaligned.c`, with its four ELFs directly
under `elf_spatzfix/`; the final image must also pass these raw probes.
Set `PROBE_RAW_LOADS=1` to build that original load sequence from the same
regression source; the default isolates arithmetic. All eight rebuilt
variants have `.text` sections identical to their preserved test ELFs
(`elf_spatzfix/source_equivalence/manifest.json`).

For example, after copying `probe.c` into the probe app's `main.c` in the
private validation worktree, the exact raw e16/m4 build is:

```sh
make -C /usr/scratch/fenga1/zexifu/spatz_short_vl_validation_wt/software/apps/spatz_apps \
  sp-vfu-short-vl-probe config=terapool_spatz4_fpu -B \
  'EXTRA_DEFINES=-DPROBE_LMUL=4 -DPROBE_SEW=16 -DPROBE_RAW_LOADS=1'
```

Repeat for SEW=32 and LMUL=1. Copy each resulting ELF from that worktree's
`software/bin/` into a private absolute path before starting a simulation.

The VFU/slide image v2 passes all four arithmetic probes, the unchanged
SwiGLU application with two elements per core (`FFN_SW_MIN=2`), and the
first calibration. Its original `vprobe_p4.elf` run stalls on five cores
at the setup `vadd.vx` (PC `0x80000764`, AVL=4..6), before entering the
FMA chain. `spatzfix_v2_original_p4/stall_audit.json` records those harts.
This observation motivated the separate load-path regression above.

The complete image is built with:

```sh
make -C hardware -o update-floogen compile_vcs_simvopt \
  config=terapool_spatz4_fpu buildpath=build_spatzfix_vcs_4x4_v3 \
  snitch_trace=1 noc_resp_local_extra_fifo_dep= vcs_jobs=4
```

This requires the existing generated packages to be 4x4. Its define set
matches v2 and differs from `build_split_vcs_mr4` only in `SNITCH_TRACE=1`.
It includes Snitch revision `df049c78`. The image's `manifest.json` records
all compiled source hashes and defines; the only source change from v2
is `spatz_vlsu.sv`. The empty FIFO override preserves the calibration
image's setting; the current config otherwise adds a six-entry FIFO.

For a local run with available VCS seats:

```sh
python3 hardware/tb/spatz_short_vl/run_system.py \
  --image hardware/build_spatzfix_vcs_4x4_v3/mempool_simvopt \
  --prefix spatzfix_raw --elf-dir hardware/elf_spatzfix \
  --max-parallel 1 --cases original_p4 \
    probe_e32_m4 probe_e16_m4 probe_e32_m1 probe_e16_m1
```

Each run uses an absolute private ELF and bounded UCLI commands ending in
`quit`. The checker requires all expected phase markers and `ALL_DONE`,
SwiGLU success, exact calibration cycles, and `[EOC]` return value zero.
The handover P4 ELF contains phases P4..P6; the extended ELFs contain
P0..P7. The first calibration ELF prints QWEN B=1/K=128/P=16384; retain
its exact identity rather than the handover's fp16 GEMM label.

V3 full-system validation runs as fleet batch
`spatzfix-v3-20260930-125959-cd25`, using the private bounded-run spec
`hardware/badist_specs/spatzfix_v3/spec.json`. Placement was dry-run first,
restricted to badile01..49, and initially governed by two VCS seats. After
license headroom improved and a second dry run passed, the cap increased
to four; one seat remains reserved for colleagues. The private `resume.py`
restores in-flight accounting without restarting any simulator. All outputs are collected from node-local job
directories into private `hardware/spatzfix_v3_<case>/` directories.

| Check | V2 result | V3 result |
|---|---|---|
| e32/m4 P0..P7 | arithmetic ALL_DONE, EOC=0 | raw ALL_DONE, EOC=0 |
| e16/m4 P0..P7 | arithmetic ALL_DONE, EOC=0 | raw ALL_DONE, EOC=0 |
| e32/m1 P0..P7 | arithmetic ALL_DONE, EOC=0 | raw ALL_DONE, EOC=0 |
| e16/m1 P0..P7 | arithmetic ALL_DONE, EOC=0 | raw ALL_DONE, EOC=0 |
| original P4..P6 | stalled during setup loads | ALL_DONE, EOC=0 |
| SwiGLU, two elements/core | success!, 14,991 cycles, EOC=0 | same, EOC=0 |
| `ks2/c4_b1_p1.elf` | success!, 23,851 cycles, EOC=0 | same, EOC=0 |
| `kt/kc4_auto_small.elf` | 74,834 cycles; checking exceeded old bound | success!, 74,834 cycles, EOC=0; timing difference below |

The longer calibration is QWEN B=32/K=256/P=8192. Its preserved historical
run (`spatzfix_reference_mr4/`) measured 74,122 kernel cycles and finished
checking at 282,834 total cycles. V2 measured 74,834 kernel cycles, then
reached its older 200,000-cycle bound during checking. V3 uses a
400,000-cycle bound. Its hart-0 timer reads at PC `0x80001808` and
`0x80001bd8` are 8,602 and 83,436, confirming the same 74,834-cycle
measurement before the UART report (`v3_long_calibration_timer.json`).
A matched baseline retains the V3 source/define set and Snitch fix, with
only the three Spatz modules restored to `b040b94`. It measures 74,780
cycles: 658 more than the historical image, and 54 fewer than the fixed
image (0.072%). The first stage matches exactly at 37,447 cycles; the
second stage measures 37,320 baseline versus 37,374 fixed. The historical
image is not a same-source baseline; it lacks the Snitch fix and a source
manifest. The 658-cycle difference cannot be attributed to these three
Spatz repairs. V2 and V3 kernel counts match, so the VLSU follow-up adds no
observed calibration-cycle cost.

The matched timer reads and instruction comparison are preserved in
`elf_spatzfix/matched_calibration_timing.json` and
`calibration_hart0_timing_diff.json`. Hart 0 executes the same 29,867
instructions through cycle 84,000; its first timing difference is at
`vfmacc.vf v6, ft4, v18` (PC `0x8000062c`) in the second stage. The final
54-cycle gap includes the group barrier. These observations localize the
difference but do not identify which of the VFU/slide corrections causes
it. The handover's exact-cycle requirement is not met for this calibration.

On 2026-09-30 at 17:04, the license server restarted. The V3 calibration
paused at about 276,137 total cycles and the matched baseline at about
43,000 cycles. Both clients retried license checkout every 20 seconds
without holding runtime seats. After the recovery results were gathered,
native UCLI interrupts ended these superseded clients and flushed their
traces. Both returned 255 from the interrupted license wait and emitted a
VCS simulation report; their `early_stop.json` records distinguish these
stopped runs from validation verdicts. The fresh runs below resolve the
timing comparison and pass numerical checking. The matched baseline image is
`build_spatzfix_vcs_4x4_baseline/`, fleet batch
`spatzfix-baseline-20260930-155608-dc98`. Its 100,000-cycle bound captures
the kernel timer reads; it intentionally ends before UART reporting and
numerical checking. Compare its hart-0 CSR reads at the same PCs rather
than requiring `success!` from that timing-only run.

A fresh two-nanosecond VCS smoke run obtained a runtime seat and quit
normally after the restart. Fresh bounded validations therefore run as
`spatzfix-recovery-20260930-174104-9b53`, initially retaining the original
clients.
They use the same images and ELFs, hart tracing, and `+notracer` to disable
only the optional NoC CSV logger. The private spec reserves two seats,
5 GB RAM and 32 GB scratch per job, informed by the observed runtime
footprint. `hardware/badist_specs/spatzfix_recovery/watch_results.py`
collects and checks both results automatically, preserving the historical
cycle expectation and reporting the matched baseline separately. The
fresh baseline exited normally at its bound. The fixed run printed
`success!` and exited at 567,116 ns (283,558 total cycles), EOC=0. All
seven other full-system cases also pass. `elf_spatzfix/results.json`
records numerical success separately from the failed historical exact-cycle
expectation; `calibration_assessment` reports the 54-cycle matched-baseline
difference. No VCS processes or runtime seats remain in use by this
investigation. Fleet statistics measured at most 3.65 GiB RSS and 3h51m
wall time; the next equivalent spec can use 5 GB RAM, 7 GB scratch, and
16,624 seconds estimated runtime. All collected outputs remain local.

The local runner retains the historical reference by default;
`--gate-up-cycles N` selects an explicit alternative reference. Do not
replace the historical count merely to make the checker pass: establish
the matched baseline first.

The RTL commits in `working_dir/spatz` are `7c98455` (VFU), `ee4db56`
(slide), and `fa77858` (VLSU). Their source hashes are recorded in the
private images and focused test artifacts. Older superseded runs retain
`early_stop.json` explaining their native UCLI interrupt and normal exit;
their missing success marker is not a regression verdict.
