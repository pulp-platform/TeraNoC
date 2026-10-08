# qwen-ffn-down

The Qwen3.8-27B FFN down projection, streamed from L2 (fp16, fp16 accumulation):

```
Y = H . Wdown        H:[B][K]   Wdown:[K][P]   Y:[B][P]      K = 16384, P = 4096
```

`B` is the decode batch (independent sequences). Shapes are the canonical simplified ones
(`docs/qwen3_8_27b/canonical_shapes.md`: model 17408 -> 5120 rounded to 16384 -> 4096, so every
per-core column span is a whole 64-byte stripe). Plan and status: `docs/qwen3_8_27b/ffn_plan.md`.

**Forked from `qwen-gate-up` @ `dd6056fa`.** Its README is the reference for everything this app
inherits unchanged: the K-tile pipeline (one DMA per tile, double buffer, continuous W stream),
the decode work split with the 4x4 group patch, the K split and its reduction under an MSHR
bypass, the row pad, the sweep-aligned L2 slots, the host generators. The kernel
(`kernel/qwen-fmatmul.c`) is byte-for-byte the parent's. The A operand keeps the parent's name
(`X`, `qwen_x`) so the two apps diff cleanly; here it holds H.

What differs:
- **One projection** (`QWEN_STAGES_N = 1`).
- **Aspect ratio.** K long, P short: a core owns `B x 4096 / cores` outputs, so the K split
  (`QWEN_KSPLIT`) is on for every 8x8 batch below 128 and every 4x4 batch below 32.
- **K tile** = the tallest `K/s` (s even) whose double buffer fits L1 (`ffn_kt_max` defaults to K):
  512 at 4x4 (4.2 MB tiles), 2048 at 8x8 (16.9 MB).
- **Check pattern 1 is multi-hot** (`qwen_pattern.h`): each H row lights one column in every K part
  of every tile, so a missing or misplaced partial sum changes the result. The parent's one-hot
  pattern could not see a missing reduction at B=1.
- `[QWEN] tile_cyc=` prints cycles per K tile (barrier close to barrier close) after the region.
- **SwiGLU prologue** (`ffn_swiglu=1`, default; `swiglu.h`): H = SiLU(G) * U from G and U in L2 in
  gate-up's output layout (`[strip][B][gu_pt + gu_wpad]`), staged through the two W slots, then the
  first W tile is primed. fp32 inside (widen via `vfwadd.vf` -- this Spatz has no `vfwcvt`; Cody-Waite
  exp + degree-5 polynomial; reciprocal by seed + 2 Newton steps -- no divider). Runs with the MSHR
  held off. Max 1 ulp vs a float64 reference, 99.2% bit-exact. Timed separately:
  `[QWEN] swiglu= prime= down=`. Constants are built with `li`+`fmv`, never loaded (literals sit in
  L2 and every core fetching them cost 14k cycles at 8x8).
- **H row pad** (`ffn_hpad`, default one L1 group stride = 512 fp16): at K = 16384 an H row is a whole
  number of mesh sweeps, so without it every row's element k is in one bank and the per-step scalar
  loads collapse the MSHR (GVSoC 8x8 B=16: 12.4M -> 266k cycles).

## Building

Always through the wrapper, which fixes the memory configuration (`l1_bank_size=4096`: 16 / 64 MiB
L1; `l2_size=536870912`) and keeps ELF, dump and log (with the generated headers) together:

```sh
script/build.sh <4x4|8x8> <tag> <outdir> [ffn_var=value ...]
script/build.sh 4x4 c4_b16_k1 $OUT ffn_b=16 ffn_k=2048 ffn_check=1 ffn_preload=1   # self-check
script/build.sh 8x8 p8_b16    $OUT ffn_b=16                                        # perf, full K
```

`app.mk` refuses to build without those two memory sizes: the committed `config/config.mk`
still says `l1_bank_size=1024`, which silently builds for a 4 MiB L1.

| variable | default | meaning |
|---|---|---|
| `ffn_b` | 1 | batch |
| `ffn_k` / `ffn_p` | 16384 / 4096 | reduction / output width |
| `ffn_kt` / `ffn_kt_max` | auto / K | K tile rows (auto: tallest that fits) |
| `ffn_check` | 0 | 0 perf, 1 multi-hot, 2 ones (K a power of two <= 2048), 3 SwiGLU vs host float64 (<= 2 ulp; needs swiglu=1 preload=1), 4 Y bit-exact vs the host fp16 model (needs swiglu=0 preload=1) |
| `ffn_swiglu` | 1 | 1 = SwiGLU prologue from G/U, 0 = H loaded directly |
| `ffn_gu_pt` / `ffn_gu_wpad` | auto (K) / tile | G/U layout in L2: gate-up's strip width and row pad |
| `ffn_hpad` | auto | H row pad in elements (auto = one group stride; 0 = none) |
| `ffn_preload` | 0 | carry the operands in the ELF (use for every check build) |
| `ffn_ksplit` | auto | cores per output patch (auto: smallest power of two <= 16 filling a register block) |
| `ffn_split` | decode | decode for every batch (prefill would make every group read all of W) |
| `ffn_ks`, `ffn_span_align`, `ffn_pt`, `ffn_rc_group`, `ffn_wpad`, `ffn_repeats`, `ffn_dma_core`, `ffn_init` | as `qwen_*` | see the parent README |

## Running

```sh
[FFN_HB=1] script/gvsoc_run2.sh <4x4|8x8> <elf> <rundir> [max_seconds]   # calibrated GVSoC, local
```

RTL on the fleet: `scripts/badist/teranoc_fleet.py submit --arms <file> --run-prefix ffd<n>` with
images `build_split_vcs_mr4` (4x4) / `build_split_vcs_8x8_yx` (8x8); ELFs from
`hardware/elf_ffn/`.

`script/ffn_numerics.c` (host only) measures fp16-accumulation accuracy at full size with the same
fp16 model check 4 validates bit for bit (`FFN_CHUNK=c` models flushing into fp32 every c rows).

`script/test_burst_vl.py` checks that every W vector load is burst-eligible at the shipped shapes
(all are, with no padding).
