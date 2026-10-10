# qwen-layer — one Qwen3.8-27B decoder layer (decode) in one timed region

Plan and decisions: `docs/qwen3_8_27b/mixer_plan.md`. Shapes: `docs/qwen3_8_27b/canonical_shapes.md`.

```
x ──RMSNorm(folded)──► in-projection ──► mixer ──► o-proj (+x) ──RMSNorm(folded)──► gate+up → SwiGLU → down (+x) ──► x
                       qz (GDN) / qa (attention)                    └──────────── ql_ffn=1 ────────────┘
```

| file | what |
|---|---|
| `phase_qz.c` | GDN in-projection x·W (4096→16384, q k v z); epilogue: 1/rms, conv1d + SiLU, scatter into the delta-rule chunk slots |
| `phase_qa.c` | attention in-projection (4096→14336, q gate k v); epilogue: 1/rms, scatter q/gate to each problem's part-0 core, the new k/v to its last-part core |
| `mixer_gdn.c` | a,b dot products (in the state DMA's shadow), q/k L2-norm, gates, delta rule (`qwen-common/qc_gdn.h`), gated RMSNorm → o' |
| `mixer_attn.c` | q/k RMSNorm + partial RoPE, KV append, flash-decoding (`qwen-common/qc_attn.h`), split-S tree, sigmoid gate → o' |
| `phase_op.c` | o-proj (6144→4096); epilogue: residual into x's replicas, pre-FFN norm partials |
| `phase_gu.c`, `phase_dn.c` | FFN (qwen-ffn's SwiGLU) — only with `ql_ffn=1` |
| `norms.c` | fp32 sums of squares and 1/rms per sequence |
| `script/gen_joint.c` | K tile / strip of every phase under one L1 budget incl. the mixer |
| `script/gen_cands.c` | legal (KT, PT) per phase (any even K-tile count) |

All projections are `qwen-common/qwen_phase.c` (the FFN effort's engine) instantiated per phase.

## Build and run

```sh
S=software/apps/spatz_apps/qwen-common/script
$S/build_app.sh qwen-layer 4x4 gdn_b4   hardware/elf_mixer ql_b=4 ql_ffn=1 icache_warmup=1
$S/build_app.sh qwen-layer 4x4 attn_b4  hardware/elf_mixer ql_b=4 ql_mixer=attn ql_s=2048 ql_ffn=1 icache_warmup=1
$S/gvsoc_run.sh 4x4 hardware/elf_mixer/gdn_b4.elf /path/run 3600
```

Knobs: `ql_b` batch, `ql_mixer=gdn|attn`, `ql_s` attention history, `ql_ffn=1` whole layer
(else the mixer block), `ql_stream=0` GDN state resident in L1 (small B only), `ql_wshare`
(default = `ql_ffn`) all phases stream one shared L2 weight region — perf builds only; a layer's
~560 MiB does not fit the 512 MiB L2 of the current RTL images, and L2 is flat SRAM so the timing is
the same. `ql_t` tokens per sequence per step (MTP: 1 + drafts verified together; projections see
`ql_b * ql_t` rows), `ql_tg` (attention) tokens sharing one core's K/V tile (1 or 2; 4 does not fit
L1), `ql_mixer_only=1` time the mixer alone (waveform runs; `ql_t > 1` currently needs it).
`ql_check=1` structural check (identity values through the in-projection scatter and the
o' hand-off).

## Open

- (fixed 2026-10-09) The attention "hangs" were a stack overflow: the 512 B per-core stack also
  holds the log-barrier counter. `build_app.sh` now runs `qwen-common/script/stack_depth.py` and
  refuses a build over 500 B -- keep per-round kernels `noinline` so their frames do not nest.
- (fixed 2026-10-09) `ql_check=1` B=4 GDN had 233 o' mismatches: reduction read-backs went through
  a 64 B scratch slot at full vl (128-256 B), clobbering the next cores' slots. Every zero load and
  read-back store is now vl = 1 (`QC_VL1`); the check passes on GVSoC.
- Efficiency: the delta rule and the attention core run short vectors (vl = 32): the attention
  rounds are compute-bound at ~45% of FPU peak (QK / PV scalar operand feed).
- `ql_check=1` attention also checks the new token's k in the L2 KV cache. Build with
  `EXTRA_DEFINES=-DQL_PROF` for per-core prep / round compute-vs-wait timers ([ATTP]).
