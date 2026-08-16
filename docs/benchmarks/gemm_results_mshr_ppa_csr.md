# GEMM benchmark results — Phase CSR — runtime-configurable group MSHR, software-enabled

Generated 2026-08-16 05:22 from `c30814d7`. **Re-runnable**: `python3 scripts/gen_sweep_doc_phase.py sweepCSR phaseE1 gemm_results_mshr_ppa_csr.md "Phase CSR — runtime-configurable group MSHR, software-enabled" "group_mshr_cfg_runtime=1: the MSHR ships DISABLED and software programs+enables it before the timed region"`.

**What changed in this phase:** group_mshr_cfg_runtime=1: the MSHR ships DISABLED and software programs+enables it before the timed region

Part of the chained PPA campaign — see [`README.md`](README.md). The **`Δ vs phaseE1`** column is this phase measured alone, against the arm immediately before it; that is the number to quote. `Δ vs old` compares against `gemm_results.md` and bundles everything since 2026-08-03.

## Results

| M×N×P | ideal | A-sh | B-sh | merge | ELF | old cyc | old % | phaseE1 cyc | new cyc | new % | Δ vs old | **Δ vs phaseE1** |
|---|---:|---:|---:|---:|:--|---:|---:|---:|---:|---:|---:|---:|
| 128x1024x512 | 65,536 | 16 | 1 | 16 | `b347f729` | 67,693 | 96.8% | 130,792 | _0p_ | — | — | **—** |
| 256x1024x256 | 65,536 | 8 | 2 | 8 | `b132b25e` | 68,253 | 96.0% | 68,410 | _0p_ | — | — | **—** |
| 128x512x512 | 32,768 | 16 | 1 | 16 | `3585610a` | 34,489 | 95.0% | 41,943 | _0p_ | — | — | **—** |
| 256x512x256 | 32,768 | 8 | 2 | 8 | `40ec869f` | 34,821 | 94.1% | 34,547 | _0p_ | — | — | **—** |
| 256x512x512 | 65,536 | 8 | 2 | 8 | `d3403f61` | 71,218 | 92.0% | 71,116 | _0p_ | — | — | **—** |
| 128x256x512 | 16,384 | 16 | 1 | 16 | `17d5e01b` | 18,082 | 90.6% | 21,614 | _0p_ | — | — | **—** |
| 256x256x256 | 16,384 | 8 | 2 | 8 | `1f770128` | 18,177 | 90.1% | 17,984 | _0p_ | — | — | **—** |
| 512x256x256 | 32,768 | 4 | 4 | 4 | `42a4a176` | 37,632 | 87.1% | 38,260 | _0p_ | — | — | **—** |
| 512x512x128 | 32,768 | 4 | 4 | 4 | `2c8d9b30` | 38,325 | 85.5% | 38,885 | _0p_ | — | — | **—** |
| 512x512x512 | 131,072 | 4 | 4 | 4 | `51cf3dbc` | 153,707 | 85.3% | 154,734 | _0p_ | — | — | **—** |
| 512x256x512 | 65,536 | 4 | 4 | 4 | `4ed3124f` | 78,314 | 83.7% | 79,653 | _0p_ | — | — | **—** |
| 128x128x512 | 8,192 | 16 | 1 | 16 | `5cbaf0b3` | 9,792 | 83.7% | 16,995 | _0p_ | — | — | **—** |
| 256x128x256 | 8,192 | 8 | 2 | 8 | `506c097b` | 10,014 | 81.8% | 9,944 | _0p_ | — | — | **—** |
| 512x256x128 | 16,384 | 4 | 4 | 4 | `9b58c096` | 20,155 | 81.3% | 19,493 | _0p_ | — | — | **—** |
| 512x128x256 | 16,384 | 4 | 4 | 4 | `3c0223fb` | 20,307 | 80.7% | 20,538 | _0p_ | — | — | **—** |
| 512x128x512 | 32,768 | 4 | 4 | 4 | `b41e3eb6` | 42,767 | 76.6% | 42,743 | _0p_ | — | — | **—** |
| 512x128x128 | 8,192 | 4 | 4 | 4 | `3e31135c` | 11,111 | 73.7% | 11,144 | _0p_ | — | — | **—** |
| 256x64x256 | 4,096 | 8 | 2 | 8 | `2145eecf` | 6,050 | 67.7% | 5,860 | _0p_ | — | — | **—** |
| 512x64x256 | 8,192 | 4 | 4 | 4 | `5275b834` | 12,183 | 67.2% | 11,930 | _0p_ | — | — | **—** |
| 512x64x512 | 16,384 | 4 | 4 | 4 | `4738c39f` | 24,616 | 66.6% | 24,607 | _0p_ | — | — | **—** |
| 256x32x512 | 4,096 | 8 | 2 | 8 | `e11c953f` | 6,752 | 60.7% | 6,598 | _0p_ | — | — | **—** |
| 512x32x512 | 8,192 | 4 | 4 | 4 | `126121b3` | 16,238 | 50.4% | 15,088 | _0p_ | — | — | **—** |
| 256x32x256 | 2,048 | 8 | 2 | 8 | `11b4dcfc` | 4,081 | 50.2% | 3,771 | _0p_ | — | — | **—** |

**0 of 23 complete.**

`ideal = M·N·P / 1024` (MACs ÷ 1024 FMA lanes = 256 cores × 4 FPU). Efficiency is `ideal / actual`;
the denominator comes from the data size, never from simulation. **Do not rank on the TB's
`[FPU] util`** — it samples lane occupancy, which is not conserved across runs of identical work,
and it once ranked an arm that finished 434 cycles later as higher.

## Known caveat on four shapes

`128x1024x512`, `128x512x512`, `128x256x512`, `128x128x512` have **B shared 1-way** and their
flavour pins `hold_window_burst := 0`. Their `Δ vs old` also carries a `serve_timeout` 255→2047
difference from `gemm_results.md`, so that column is **two-variable** on those rows. The
`Δ vs phaseE1` column is unaffected — both arms use the same timeout.

