# Fused FFN (`qwen-ffn`) -- plan

Agreed with the user 2026-10-08. One decode FFN in one timed region:

    G = X . Wg,  U = X . Wu      X [B][4096], Wg/Wu [4096][16384]        (gate+up)
    H = SiLU(G) * U              [B][16384]                               (fused epilogue)
    Y = H . Wd                   Wd [16384][4096], Y [B][4096]            (down)

Canonical shapes (`canonical_shapes.md`), fp16 operands and fp16 accumulation (the fp32 C is
parked: not bit-exact on RTL, ~20% slower at 4x4 B=16). Batches: 8x8 B = 1, 2, 4, ..., 512;
4x4 B = 1 .. 256 (B=512 does not fit: H alone is 17.3 MB > 16 MiB L1). `qwen-gate-up` and
`qwen-ffn-down` stay untouched as the per-layer references.

## 1. What fusing changes

1. **G and U never leave L1.** A core computes G and U for the same (row, column) patch, so as
   soon as both projections of a strip are reduced it applies SwiGLU to its own patch and writes
   H straight into the H replicas, in the layout the down phase reads (row pad, replicas). No
   G/U write-back to L2, no G/U staging, no separate SwiGLU phase.
2. **One continuous W stream.** The DMA does not stop between the phases: the last two refills
   of gate+up launch Wd tiles 0 and 1, so the down projection starts with its first tile already
   in L1 (its stand-alone prime is 4.5k cycles at 4x4, up to 15k at 8x8).
3. **One timed region**, reported per phase (gate+up incl. SwiGLU epilogue, down) and in total,
   next to the sum of the two stand-alone apps at the same shape.

## 2. Code structure

The two phases have different compile-time shapes (`gemm_config.h` / `mshr_cfg.h` derive the
kernel size, split and MSHR tuning from `GEMM_M/N/P`), so they cannot share one translation unit.

- `qwen-common/qwen_phase.c` (since 2026-10-08, shared with the GDN mixer apps): one streamed
  projection phase -- kernel, K-tile stream, K split incl. the cross-group split, reduction, bank
  hash, MSHR tuning -- instantiated by a small wrapper per phase that defines its hooks (prefix,
  W area, external A operand, epilogue, stream hand-over, previous phase's bank hash; see the
  file header). qwen-ffn: `phase_gu.c` (SwiGLU epilogue into H, stream into down) and
  `phase_dn.c` (A = H, MSHR handover, check 1). Also in qwen-common: the kernel, `qwen_layout.h`,
  `qwen_pattern.h`, `swiglu.h`, `qwen_tu_prefix.h`, `script/gen_hash.c`, `script/fp16_host.h`
  (qwen-ffn-down uses the same files).
- `qwen-ffn/main.c`: setup, the timed region (`gu_run`, `dn_run`), report, checks.
- `script/gen_cands.c` + `gen_joint.c`: joint K-tile / strip choice for both phases under one L1 budget.
  `gen_hash.c` per phase. `gen_operands.c`: X, Wg, Wu, Wd images for checks.
- Phase boundary: MSHR off for the SwiGLU epilogue (unshared local reads), down's MSHR tuning
  written and enabled before the down phase.

## 3. Correctness

- **check 1, end to end:** X one-hot (X[b][j] = 1 iff j = b), Wg[b][k] = 16 and Wu[b][k] = 1/16
  at down's multi-hot positions of row b and 0 elsewhere, so G and U are exact single terms and
  H = fp16(SiLU(16) / 16 * 16 / 16 ...) = 1.0 exactly at the hot positions and 0 elsewhere; Wd
  is down's exact grid, so Y has down's known expectation. Catches addressing in all three steps.
  Small dims for checks (`ffn_h`, `ffn_i`, e.g. 512 / 2048) keep the preload images small.
- check 2 (ones) where it stays exact; SwiGLU accuracy is already covered by down's check 3.

## 4. Steps

1. App + build system (two phase objects, joint tiling) -- builds at every (mesh, B).
2. Fused SwiGLU epilogue, continuous stream -- GVSoC check 1 at 4x4 and 8x8, several B
   (strips and no strips, K split in and across groups).
3. RTL (latest-RTL images `build_split_vcs_pr1` 4x4, `build_ffn_vcs_8x8_v1` 8x8): check 1 at
   both meshes, then perf at B = 16 and 64 next to the stand-alone apps. <= 5 arms per submit,
   killed after harvest.
4. Full batch list on RTL, results here.
