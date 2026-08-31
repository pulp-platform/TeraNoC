# icache warmup wedge at 8x8 (GEMM app)

A/B pair, fp32 512x32x256, same image (`build_tgt8x8`, 1024 cores, VCS), differing **only** in
`ICACHE_WARMUP`. Built by `/tmp/claude-620771/gen_gemm_iw.sh`; the knob reaches the compiler via
`software/runtime/runtime.mk:139`, which defaults it to **1**.

| file | ICACHE_WARMUP | outcome |
|---|---|---|
| `iw0_fp32_512x32x256.transcript.zst` | 0 | **completes, 5,614 cycles**, `[FPU FINAL] util=22.56%` (busy 4,755,340 of 21,078,016 lane-cycles over 5,146 benchmark cycles) |
| `iw1_fp32_512x32x256.transcript.zst` | 1 | **wedges** — killed at 447,000 cycles / 424 windows after 7 h |

## What the wedge looks like

`iw1` retired instructions in **4 of 424** benchmark windows. All 64 groups sit at `insn=0` for the
remaining 420. The simulation stays live — the transcript kept growing to 159 MB — so it is a
livelock, not a crash and not a stalled simulator.

Read it with:

```sh
zstd -dc iw1_fp32_512x32x256.transcript.zst | grep '\[INSNG\] bench' | tail -20
```

## Scope — do not over-generalise

This is **not** "warmup breaks at 8x8". The 10 decode-kernel arms (KS=8) at 8x8 all carry
`ICACHE_WARMUP=1` and ran clean. `iw1` is the **GEMM** app (`sp-fmatmul-opt-burst-merge`), a
different kernel. So the failure is specific to that app, or to that shape — **which of the two is
not yet isolated**. The 26 Wave A decode arms (`waveA8x8-20260831-023909-89fc`, KS=2/4, warmup=1)
are the discriminator: if they all come up clean, it is the GEMM app rather than the mesh.

## Instrument note

Liveness here must be judged on `[INSNG] bench insn=` summed across groups. **Not** simulator
cycles/second — a wedged design simulates *faster*. **Not** trace-file mtimes — a kill flushes
handles, so a dead run reads as healthy.
