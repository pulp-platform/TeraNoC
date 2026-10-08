# Milestone A (streaming FFN) -- plan for the remaining work

Status: **AGREED with the user 2026-09-28**; steps 1-3 implemented and checked on GVSoC, RTL
confirmation running (section 11 has the results). Code: worktree `qwen_ffn_wt`, branch
`zexin/qwen-ffn`, app `software/apps/spatz_apps/qwen-ffn-down`.

Shapes: `docs/qwen3_8_27b/canonical_shapes.md` (2026-09-28 revision): hidden 4096, FFN 16384.
Memory: `l1_bank_size=4096` (L1 16 MiB at 4x4, 64 MiB at 8x8), `l2_size=536870912` (512 MiB).
Precision: fp16 storage, fp16 accumulation (open item, see step 5). Every result states all three.

```
X[B,4096] --gate/up--> G,U[B,16384] --SwiGLU--> H[B,16384] --down--> Y[B,4096]
            qwen-gate-up (done)          |---------- qwen-ffn-down (new) ----------|
            |------------------------ qwen-ffn (later, fused) ---------------------|
```

---

## 1. Ground rules (another agent is optimising qwen-gate-up in the same repo)

- Work in a separate git worktree on a new branch (`zexin/qwen-ffn`, from `97c7bb99`), with
  `install/` symlinked from the main tree. Never rebuild the main tree's `software/`.
- Do not edit: `qwen-gate-up`, `software/runtime/gemm_config.h`, `software/runtime/mshr_cfg.h`, anything
  in `hardware/src`, `hardware/tb`, `hardware/generated`, `config/`. Shared-header changes are proposed,
  not made. The app sets `GEMM_KSPLIT`, `GEMM_DECODE_RC_PER_GROUP` etc. before including them, as
  `qwen-gate-up` does.
- **One shared file does change, on my branch only:** `software/apps/spatz_apps/Makefile` gets one
  `include qwen-ffn-down/app.mk` line. All rules and make variables (prefixed `ffn_`, so they cannot
  collide with `qwen_*`) live in that fragment.
- RTL simulation only on the fleet (`scripts/badist/teranoc_fleet.py`, run prefix `ffd<n>`), on the
  existing images `hardware/build_split_vcs_mr4` (4x4) and `hardware/build_split_vcs_8x8_yx` (8x8).
  No new images. Check `teranoc_fleet.py license` before every submit. Never cancel runs I did not
  start. GVSoC runs (section 1.1) are local and read-only on the GVSoC tree.
- ELFs and their build logs are copied to `hardware/elf_ffn/<tag>.{elf,log}` (fleet-visible, never
  preloaded from `software/bin`).
- WORKLOG entry for every change. Commit messages do not mention Claude Code.

### 1.1 Simulation flow: GVSoC first, RTL for the numbers (user decision, 2026-09-28)

Every step is developed on GVSoC and only then run on RTL.

| | GVSoC | RTL (fleet) |
|---|---|---|
| used for | bring-up, all correctness patterns, first performance estimate, every iteration of the code | confirmation of correctness on a few arms, **all reported performance numbers** |
| model | `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC_gvsoc/gvsoc`, profiles `terapool_spatz4_fpu_8x8` (primary) and `terapool_spatz4_fpu` | images above |
| same ELF? | yes -- built here for `terapool_spatz4_fpu[_8x8]`, `l2_size=536870912`; the calibration ran the RTL's own ELFs byte for byte | yes |
| pass criteria | EOC `0x0` and `success!` | same |

How to run (from the GVSoC tree; work dirs go under my worktree, not into the GVSoC tree):

```sh
cd /usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC_gvsoc/gvsoc
mkdir -p /tmp/teranoc-gvsoc-py312 && ln -sf /usr/bin/python3.12 /tmp/teranoc-gvsoc-py312/python3
PATH="$PWD/install/bin:/tmp/teranoc-gvsoc-py312:$PATH" PYTHONPATH="$PWD/install/python" \
LD_LIBRARY_PATH="$PWD/install/lib" /usr/bin/python3.12 -m gvrun \
  --target=teranoc_spatz:system_config=terapool_spatz4_fpu_8x8 \
  --work-dir=<worktree>/gvsoc_runs/<tag> --parameter binary=/abs/path/app.elf run
```

**How far to trust GVSoC timing** (`gvsoc/docs/calibration/current-rtl-20260928.md`):
- 8x8 self-checking runs within 2.2% of RTL; long 8x8 B=16 K-tile intervals 3-7% FASTER than RTL.
- 4x4 short runs -6..-11% .. +6%, with the sign changing with batch: 4x4 GVSoC numbers are
  bring-up only.
- **Not modelled:** the RTL's split physical NoC request fold / response steer and parity-based
  bypass slice routing. The small-batch ceiling (per-core W delivery, root-caused on 2026-09-28 to
  the destination-side local response crossbar) sits exactly there, so **B < 8 performance from
  GVSoC is not evidence** -- only RTL answers it.
- `--parameter binary=`, never `--target-opt=binary=` (the run never ends); never set
  `TERANOC_MSHR_WIN_PATH` on an unbounded run (GBs in minutes).

---

## 2. Step 1 -- `qwen-ffn-down`: the down projection `Y = H . Wdown`

### 2.1 What is reused

Forked from `qwen-gate-up` at `dd6056fa` (provenance line in the README and in the file headers):
the vector kernel `kernel/qwen-fmatmul.c` unchanged, the K-tile pipeline (one DMA per tile,
double buffer, continuous W stream, DMA wait absorbed by the first barrier arrival), the decode work
split with the group patch and the K split, the partial-sum reduction under an MSHR bypass, X
replication (here: H), sweep-aligned L2 tile slots, the host generators `gen_tiles.c`, `gen_hash.c`,
`gen_operands.c` and `test_burst_vl.py`. **What is new** is only the shape, the SwiGLU prologue
(step 2) and the check patterns (section 4).

### 2.2 Work split at `K=16384, P=4096` (existing gate-up rules, unchanged)

`KS` = kernel rows (1/2/4/8), `ks` = K split (cores sharing one output patch), register block
512 outputs (256 at KS=1). Span = columns per core. `sharers` = cores of one group reading the same
address (merge degree in the group MSHR).

| mesh | B | outputs/core | KS | ks | vector fill | column blocks | span | W / H sharers |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| 4x4 | 1 | 16 | 1 | 16 | 100% | 16 | 256 | 1 / 1 |
| 4x4 | 4 | 64 | 4 | 8 | 100% | 32 | 128 | 1 / 2 |
| 4x4 | 16 | 256 | 8 | 2 | 100% | 64 | 64 | 2 / 4 |
| 4x4 | 32 | 512 | 8 | 1 | 100% | 64 | 64 | 4 / 4 |
| 4x4 | 64 | 1024 | 8 | 1 | 100% | 32 | 128 | 4 / 4 |
| 8x8 | 1 | 4 | 1 | 16 | 25% | 64 | 64 | 1 / 1 |
| 8x8 | 4 | 16 | 4 | 16 | 50% | 64 | 64 | 1 / 1 |
| 8x8 | 16 | 64 | 8 | 8 | 100% | 64 | 64 | 2 / 1 |
| 8x8 | 32 | 128 | 8 | 4 | 100% | 64 | 64 | 4 / 1 |
| 8x8 | 64 | 256 | 8 | 2 | 100% | 64 | 64 | 4 / 2 |
| 8x8 | 128 | 512 | 8 | 1 | 100% | 64 | 64 | 4 / 4 |

Every span is a whole number of stripes: no padding (`LDP = 4096`). 8x8 B<8 runs part-full
vectors; fixing that needs a K split across groups, **decided NOT to build** (2026-09-28) -- those
batches are limited by per-core W delivery from L1 anyway. Compared with gate-up, the down
projection needs the K split at every 8x8 batch below 128.

### 2.3 K tiles and L1 budget

Tallest `KT = K/s` (s even, for the stream's slot parity) whose W double buffer fits beside the rest:

| mesh | KT | tiles | W tile | W x2 | per-tile ideal compute | per-tile DMA only |
|---|---:|---:|---:|---:|---:|---:|
| 4x4 | 512 | 32 | 4.2 MB | 8.5 MB | 1,024 x B cyc | ~4.1k cyc (1024 B/cyc) |
| 8x8 | 2048 | 8 | 16.9 MB | 33.8 MB | 1,024 x B cyc | ~8.8k cyc (1926 B/cyc) |

(ideal = B.KT.P / (cores x 8 fp16 FMA/cyc); both meshes have the same per-tile compute.)
Next taller tile does not fit (4x4 KT=1024: 17 MB double buffer). Beside W: H `B x 32 KiB` per
replica, the partial-sum buffers `(ks-1) x B x 4096 x 2 B` (<= 1 MB at every shape above), Y
`B x 8 KiB`, stacks. Largest case 8x8 B=128: 34 + 4 + 1 MB of 64 MiB.

The one-stripe row pad (`wpad`) is kept as a knob: an 8 KiB W row is half a 4x4 mesh sweep, so
without it successive K rows alternate between only two group positions. `gen_hash.c` scores both.

### 2.4 Timing boundaries

The timed region is the down projection, including the partial-sum reduction. As in gate-up, the
first W tile's prime is outside (cold start: nothing to overlap with); the fused app (step 4)
removes that exception. The SwiGLU prologue is timed separately (step 2).

Full-size runs (32 or 8 tiles at up to 16k cycles each) will not finish in a day on RTL, as with
gate-up. Two kinds of perf arm: **full K**, measured as steady-state cycles per K tile from the
`[DMAP]` probe; and **K=2048** (4x4: 4 tiles, 8x8: 1 tile), which completes and gives end-to-end
cycles including the reduction.

### 2.5 Exit criteria

Check patterns 1 and 2 pass at 4x4 B = 1, 4, 16, 32 (covers ks = 16, 8, 2, 1). No
`SPLIT MISMATCH` / `cfg REJECTED`. `test_burst_vl.py` reports zero non-burst vectors and
`mshr_bank_hash_explore.py` reaches all banks concurrently. Then full-K perf arms at 4x4 B = 1, 4,
16, 32, 64, compared with gate-up's per-tile numbers (`gvsoc_rtl_calibration_handover.md` §5.2).

---

## 3. Step 2 -- SwiGLU prologue `H = SiLU(G) * U`

- **Input contract:** G and U in L2 in `qwen-gate-up`'s output layout (`[strip][B][PT + wpad]`,
  one strip = row-major with a one-stripe row pad), so the fused app needs no converter.
- **Where:** in `qwen-ffn-down`, before the down projection. The G and U blocks are DMA'd into the
  two W slots (not yet primed; `B x 32 KiB` each, fits for any B <= 128), every core computes a
  contiguous slice of H and stores it into every H replica, barrier, then the W prime starts.
- **Algorithm (per element, vector, fp32 internally):** widen g, u to fp32; `e = exp(-g)` with
  the argument clamped, range reduction `n = round(x/ln2)`, `r = x - n.ln2` (two-constant
  Cody-Waite), degree-4 polynomial, `2^n` by an integer add into the exponent field;
  `s = 1/(1+e)` by a bit-trick initial guess plus two Newton steps (Spatz has no divider,
  `FDivSqrt=0`); `h = g.u.s`, narrow to fp16. About 20 vector ops per element; estimated ~1% of the
  down projection at B=16. **To verify before writing it:** the vector convert / widen / narrow
  instructions the compiled Spatz decodes (`spatz_decoder.sv`).
- **Timing:** `[FFN] swiglu=<cyc> down=<cyc>`: G/U fetch, compute and the barrier in the first.
- **Later:** in the fused app, SwiGLU moves into the gap between up's last tile and down's
  first, overlapping the down prefetch.

---

## 4. Correctness plan

Integer compares of raw halfwords wherever the result is exact; no scalar FP on the check path (it
wedges the FP-LSU in long core-0 loops). All cores verify their share in parallel.

| `ffn_check` | pattern | expected | catches |
|---|---|---|---|
| 1 | **multi-hot**: each H row lights one column in EVERY K part of EVERY tile, at a position varying with row, tile and part; W the small exact grid | exact small sum of W grid values (multiples of 1/8, magnitude < 256: exact in fp16; static-asserted) | addressing, tiling, DMA, burst path **and a missing or duplicated K part** -- the plain one-hot at B=1 cannot see the reduction (gate-up's B=1 lesson) |
| 2 | ones: H = W = 1 | `Y == K` | MAC count and accumulation across tiles and parts; needs K <= 2048 -> run at K=2048 |
| 3 | SwiGLU: host-generated G, U incl. edge values (0, +-large, subnormal, max) | host reference (float64, rounded to fp16) within 2 ulp | the transcendental path |
| 4 | random H, W (preloaded, small K) | **bit-exact** vs a host emulator of the kernel's fp16 accumulation order (vfmacc per K step per part, fp16 store/reload between tiles, partials summed in order) | the arithmetic itself; validates the emulator used in step 5 |

Patterns 1 and 2 run **through** the SwiGLU prologue by default: G = 16, U = 1/16 gives H = 1.0
exactly after fp16 rounding, and G = 0 gives H = 0 exactly, so the plumbing from G/U to H to Y is
covered. `ffn_swiglu=0` (H loaded directly) isolates the down projection if a check fails.

---

## 5. Step 3 -- fp16 accumulation: how accurate is it?

Open since gate-up. Plan: run check 4 bit-exact on RTL at small shapes (4x4 B=4 and 16), which
proves the host emulator reproduces the hardware exactly. Then run the emulator on the host at the
full sizes (K=4096 gate/up, K=16384 down) with realistic value distributions and compare against
float64: max and RMS relative error of Y. No simulation needed for the full-size numbers. If fp16
accumulation is not good enough, the alternative is widening accumulation (`vfwmacc`, fp32
accumulators, half throughput) as a knob: a separate decision.

---

## 6. Step 4 -- 8x8

Checks 1 and 2 at B = 1, 16, 64 (ks = 16, 8, 2); full-K perf arms at B = 1, 4, 16, 32, 64, 128.

---

## 7. Step 5 -- fused `qwen-ffn` (gate + up + SwiGLU + down, one timed region)

Sketch only; **gated on the gate-up pipeline being frozen** by the other agent / you.
- One continuous W stream through all three projections (gate, up, down tiles in one sequence), so
  down's first tiles prefetch while up finishes and SwiGLU runs. All three weights fit L2 together
  (384 MiB).
- G/U stay in L1 when gate-up runs one strip; H is computed in L1 with no L2 round trip.
- L1: gate-up's and down's buffers are never live together, so they share one region.
- Open: how to share code with `qwen-gate-up` -- fork again, or factor the pipeline into a shared
  header once gate-up stops changing (my preference).

---

## 8. Simulation budget

Everything below first passes on GVSoC (local, minutes to hours per run); the RTL column is what
then goes to the fleet.

| step | GVSoC | RTL arms |
|---|---|---:|
| 1 checks (B 1/4/16/32 x checks 1/2) | 4x4 and 8x8 profiles, all | 4 (4x4 B=1/16, one per check) |
| 1 perf | 8x8 full-K estimates, B 1..128 | 4x4 B 1/4/16/32/64 full K + K=2048: 10 |
| 2 SwiGLU (check 3; checks 1/2 through SwiGLU) | all | 2 |
| 3 check 4 (bit-exact) | all | 2 |
| 4 8x8 | checks + perf, done in step 1 already | 3 checks + 6 perf |
| **total RTL** | | **~27**, in waves of <= 10 |

---

## 9. Known risks

- **B=1 K-split hang** (open in gate-up): the post-kernel check hangs at B=1 with the K split.
  Down uses ks=16 at B=1 on both meshes, so it may hit the same thing. Treat it as a gate-up issue
  first; do not debug it in parallel.
- **4x4 B=1 K split: 4 MSHR serve timeouts then ~8k idle cycles** at the end of the first tile (once
  per run). Expected here too.
- **Small batches are capped by per-core W delivery** (~0.6 words/cyc/core, under investigation in
  the NoC). Down at B < 8 will show the same ceiling; report it, do not chase it.
- **Per-tile time at small B is short** (4x4 B=1: 1k cycles of compute against a 4k-cycle DMA and
  a barrier), so small batches are DMA/barrier-bound by construction.
- An image built before 2026-09-28 02:30 reports FPU occupancy, not issued ops; rank on
  ideal/actual either way.

---

## 10. Decisions (agreed 2026-09-28)

1. `qwen-ffn-down` (SwiGLU + down) now, fused `qwen-ffn` later.
2. SwiGLU fp32 internally, fp16 in and out.
3. The four check patterns; patterns 1/2 run through SwiGLU by default.
4. Accuracy study on a host emulator validated bit-exactly on RTL.
5. Fused app waits for gate-up to freeze; shared code by factoring, not a second fork.
6. One shared-file touch: the Makefile include line, on my branch.
7. GVSoC for bring-up and first estimates, RTL on the fleet for reported numbers (section 1.1).
8. L2 is enlarged when a later kernel needs it (canonical_shapes.md).

---

## 11. Results (2026-09-28)

Configuration for every number below: canonical shapes (hidden 4096, FFN 16384), L1 16 / 64 MiB
(`l1_bank_size=4096`), L2 512 MiB, fp16 storage and accumulation, RTL images `build_split_vcs_mr4`
/ `build_split_vcs_8x8_yx`, GVSoC `TeraNoC_gvsoc/gvsoc` (calibration 2026-09-28).
Efficiency = ideal / actual, ideal = MACs / (cores x 16 fp16 MAC/cycle), for the down projection
alone (SwiGLU prologue and the cold first-tile prime reported separately).

### 11.1 Correctness

| check | GVSoC | RTL |
|---|---|---|
| 1 multi-hot (every K part), 2 ones | 4x4 + 8x8, B = 1/4/16/32 (+ 8x8 B=64 through SwiGLU): all pass | 4x4 B=1/4 both, B=16 check 2: pass; rest running |
| 1/2 through SwiGLU | 4x4 + 8x8, B = 1/16: pass | running (ffd3) |
| 3 SwiGLU vs float64 | max 1 ulp, 99.2% bit-exact (4x4 B=4/16, 8x8 B=16) | running |
| 4 Y bit-exact vs host fp16 model | pass at K split 16, 8, 2 (4x4) and 16, 8 (8x8) | running |

### 11.2 Four defects found by the checks and fixed

1. **The 16 MiB L1 is an uncommitted edit** in the main tree's `config/config.mk`; a worktree built
   a 4 MiB L1. `app.mk` now refuses to build without `l1_bank_size=4096 l2_size=536870912`.
2. **Generated headers went stale across meshes** (same B/K/P, other mesh -> 4x4 tiles and a 16-row
   hash table in an 8x8 ELF). The shape header names the machine; `main.c` asserts the hash table
   size. qwen-gate-up's Makefile has the same latent issue.
3. **H row stride = whole mesh sweeps** (32 KiB): every row's element k in one bank. Fixed with a
   one-group row pad (`ffn_hpad`). GVSoC 8x8 B=16: 12.4M -> 266k cycles.
4. **Single-class MSHR bank hash chosen on the wrong layout** (shared `gemm_hash.h` models A as
   unpadded [M][N], no K split; with the shift cap every candidate tied at K >= 4096 and shift 4
   put all of a core's H row loads in one bank). With 4 sharers per H word (4x4 B>=16, 8x8 B=128)
   the bank filled and every tile retried every cycle. **Confirmed on RTL**: the old-hash 4x4 B=16
   full-K arm ran at 2.6% FPU utilisation. `gen_hash.c` now scores the single class on the real
   addresses. 4x4 B=16 K=4096: stuck past 5M cycles -> 173,922.
Also: SwiGLU constants were loaded from L2 by every core (14k cycles at 8x8); built in registers now.

### 11.3 Performance, full size (GVSoC; RTL steady state running as ffd4)

| mesh | B | ks | down cycles | eff | per K tile (median) | ideal per tile | SwiGLU | prime |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 4x4 | 1 | 16 | 349,532 | 9.4% | 11.1k | 1.0k | 0.9k | 8.7k |
| 4x4 | 4 | 8 | 330,585 | 39.6% | 10.5k | 4.1k | 3.4k | 8.6k |
| 4x4 | 16 | 2 | 665,585 | 78.8% | 21.0k | 16.4k | 12.8k | 8.5k |
| 4x4 | 32 | 1 | 1,197,194 | 87.6% | 37.6k | 32.8k | 24.8k | 8.6k |
| 8x8 | 1 | 16 | 129,648 | 6.3% | 16.0k | 1.0k | 0.6k | 14.1k |
| 8x8 | 4 | 16 | 161,415 | 20.3% | 19.6k | 4.1k | 1.1k | 14.4k |
| 8x8 | 16 | 8 | 271,254 | 48.3% | 33.0k | 16.4k | 4.0k | 13.5k |

(4x4 B=1/4 and 8x8 rows: ELFs from before the hash fix, which at these shapes -- 1-2 sharers per H
word -- did not trap; to be re-run with the fixed hash. 8x8 B=16: K split 4 instead of 8 is 2.3x
slower, 2 pads W to 8192 columns.)

Observations:
- Small batches are bound by per-core W delivery and by DMA/compute interference (4x4 B=1: the
  first and last tiles, with no DMA in flight, take 7.3k; the middle ones 11.1k), the same regime
  as qwen-gate-up.
- 8x8 B=16 at 48%: each core's scalar H loads are unshared at K split 8 (one sharer per group).
- SwiGLU is 1.5-2% of the down projection; the cold prime (one W tile) 1-10%, and in a fused FFN
  it overlaps the up projection.

### 11.4 fp16 accumulation (host model, bit-exact to the hardware by check 4)

Down K=16384 B=16, error relative to rms(y): fp16 ks=1 1.8e-2 (45% of outputs off by >1%), ks=2
1.3e-2 (38%), ks=8 6.7e-3 (13%), ks=16 4.7e-3 (3.6%); fp32 accumulation 2.1e-4 (= the fp16
output-rounding floor). Chunked fp16 -> fp32 flush every 256 / 64 / 16 rows: 2.4e-3 / 1.2e-3 /
6.4e-4, 0% of outputs >1%. Gate/up K=4096 ks=1: 9.0e-3 (20% >1%). **Decision pending.**
