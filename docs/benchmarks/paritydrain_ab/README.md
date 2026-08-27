# ParityDrain A/B — rescued from two wedged local sims (2026-08-27)

`run_pa_off` and `run_pa_on` were launched 2026-08-21 and were still running six days later,
80x past their own result cycle (7.3M vs ~92k), emitting nothing but zero-valued profiling
(`util=0.00%`, `insn=0,...`, `inflight=0`). That is the known matmul **epilogue wedge**: the
benchmark completes and prints its result, then core 0 hangs and the TB keeps ticking forever.

Neither cycle count existed anywhere in the repo, so both were snapshotted before the processes
were killed.

| arm | cycles | cum FPU util | note |
|---|---:|---:|---|
| `run_pa_off` | **91,859** | 5.17% | ParityDrain OFF |
| `run_pa_on` | **82,859** | 6.08% | ParityDrain ON |

**ParityDrain is worth 1.109x here** (91,859 / 82,859), consistent with the 1.11x recorded for the
`matmul 4009 vs 4453` pair. 91,859 also matches the VCS-vs-QuestaSim equivalence check, where both
simulators returned bit-identical cycle counts for this workload.

`build_1_gui_4096x32x512.result.txt` is a third rescue from the same sweep: `4096x32x512`,
**48,987** cycles, cum util 19.41%, `grp_max=96.5%(g30)` against `grp_min=0.0%(g0)` — the fixed
spatial slow-set signature. That figure was already in `8x8_scaleup/results.tsv`; the snapshot adds
the per-group context.

Raw transcripts remain in `hardware/run_pa_{off,on}/` and `hardware/build_1_gui_4096x32x512/`.
