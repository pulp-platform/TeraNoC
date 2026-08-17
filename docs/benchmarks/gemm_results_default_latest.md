# GEMM benchmark results — pure defaults (`dflt`) and full latest stack (`latest`)

Generated 2026-08-17 19:54. **Re-runnable**: `python3 /tmp/claude-620771/gen_dflt_latest_doc.py`.

**Status: 21/23 `dflt` complete, 19/23 `latest` complete.** This file regenerates as arms land; re-run the generator rather than trusting a stale copy.

## What these arms measure, and why neither has been run before

Every prior arm in this campaign pins `group_mshr_hold_prescale_w=0` for cycle-accurate one-knob
deltas — deliberately, since the hold/timeout counters quantise to ±16 cycles at the shipping
value of 4, which would sit on top of the sub-1% effects the campaign is resolving. But that means
**0 of 188 prior arms ever measured the shipping default.** These two sweeps are the first to.

| sweep | `cfg_runtime` | knobs passed | what it is |
|---|:--:|---|---|
| **`dflt`** | 0 | *none* — pure flavour defaults | the shipping config with the runtime CSR off |
| **`latest`** | 1 | `cfg_runtime=1` only | the shipping config with the runtime CSR on, software-configured |

Both run `group_mshr_hold_prescale_w=4`, `spatz_vlsu_commit_qmin=1`, `spatz_rob_cnt_idvalid=1` —
all from the flavour, not overridden. `latest` additionally runs on **3 shared VCS builds** rather
than 23: at `cfg_runtime=1` the software-written CSR value wins over the elaborated one for every
per-shape knob except `group_mshr_merge_reqs` (which sizes `sub_reqs[]` and is structural), so
shapes sharing a `merge_reqs` run on a bit-identical simulator. Verified before relying on it:
`latest_256x32x256` on the `merge_reqs=8` build (elaborated from `256x1024x256`'s flavour, wrong
bank shifts) reproduced `sweepCSR_256x32x256` exactly — 3,667 both times.

`p=0 twin` is each shape's existing `prescale_w=0` reference (`bypass_*` for the four `share_b=1`
shapes, `phaseE1_*` for the rest) — the only same-`cfg_runtime`, same-`hold_subs_burst` comparison
available, so `dflt`/`latest` vs that column isolates the prescaler's cost in isolation.

## Results

**`util` below is efficiency = `ideal / actual`, not the testbench's `[FPU] util` counter.**
The TB counter measures lane *occupancy* and is not conserved across runs of identical work — it
has inverted a real ranking before (see `reference_fpu_util_metric`). `ideal = M·N·P / 1024`, the
roofline for a 4×4 mesh at 1024 FPU lanes. `Δ base` is this arm against the 2026-08-03 baseline;
negative is faster.

| M×N×P | ideal | baseline | p=0 twin | **dflt (p=4)** | util | Δ base | **latest (CSR,p=4)** | util | Δ base |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 128x1024x512 | 65,536 | 67,693 | 67,005 | **67,860** | 96.6% | +0.2% | **_run_** | — | — |
| 256x1024x256 | 65,536 | 68,253 | 68,410 | **67,887** | 96.5% | -0.5% | **68,047** | 96.3% | -0.3% |
| 128x512x512 | 32,768 | 34,489 | 34,041 | **34,301** | 95.5% | -0.5% | **34,743** | 94.3% | +0.7% |
| 256x512x256 | 32,768 | 34,821 | 34,547 | **34,671** | 94.5% | -0.4% | **34,603** | 94.7% | -0.6% |
| 128x256x512 | 16,384 | 18,082 | 17,627 | **17,800** | 92.0% | -1.6% | **17,838** | 91.8% | -1.3% |
| 256x512x512 | 65,536 | 71,218 | 71,116 | **_run_** | — | — | **_run_** | — | — |
| 256x256x256 | 16,384 | 18,177 | 17,984 | **18,067** | 90.7% | -0.6% | **18,246** | 89.8% | +0.4% |
| 512x512x128 | 32,768 | 38,325 | 38,885 | **37,732** | 86.8% | -1.5% | **37,848** | 86.6% | -1.2% |
| 128x128x512 | 8,192 | 9,792 | 9,401 | **9,514** | 86.1% | -2.8% | **9,512** | 86.1% | -2.9% |
| 512x512x512 | 131,072 | 153,707 | 154,734 | **_run_** | — | — | **_run_** | — | — |
| 512x256x256 | 32,768 | 37,632 | 38,260 | **38,652** | 84.8% | +2.7% | **37,412** | 87.6% | -0.6% |
| 256x128x256 | 8,192 | 10,014 | 9,944 | **9,794** | 83.6% | -2.2% | **9,842** | 83.2% | -1.7% |
| 512x256x512 | 65,536 | 78,314 | 79,653 | **78,424** | 83.6% | +0.1% | **_run_** | — | — |
| 512x256x128 | 16,384 | 20,155 | 19,493 | **19,886** | 82.4% | -1.3% | **19,495** | 84.0% | -3.3% |
| 512x128x256 | 16,384 | 20,307 | 20,538 | **20,548** | 79.7% | +1.2% | **20,830** | 78.7% | +2.6% |
| 512x128x512 | 32,768 | 42,767 | 42,743 | **41,782** | 78.4% | -2.3% | **41,316** | 79.3% | -3.4% |
| 512x128x128 | 8,192 | 11,111 | 11,144 | **11,202** | 73.1% | +0.8% | **12,044** | 68.0% | +8.4% |
| 256x64x256 | 4,096 | 6,050 | 5,860 | **5,784** | 70.8% | -4.4% | **5,853** | 70.0% | -3.3% |
| 512x64x512 | 16,384 | 24,616 | 24,607 | **23,358** | 70.1% | -5.1% | **22,939** | 71.4% | -6.8% |
| 512x64x256 | 8,192 | 12,183 | 11,930 | **12,006** | 68.2% | -1.5% | **12,353** | 66.3% | +1.4% |
| 256x32x512 | 4,096 | 6,752 | 6,598 | **6,804** | 60.2% | +0.8% | **6,564** | 62.4% | -2.8% |
| 512x32x512 | 8,192 | 16,238 | 15,088 | **13,836** | 59.2% | -14.8% | **15,365** | 53.3% | -5.4% |
| 256x32x256 | 2,048 | 4,081 | 3,771 | **3,846** | 53.3% | -5.8% | **3,667** | 55.8% | -10.1% |

## Summary

- **`dflt` utilisation, 21 shapes so far**: median **83.6%**, range 53.3%–96.6%. (Baseline's median over the same 21 shapes: **81.8%**.)
- **`latest` utilisation, 19 shapes so far**: median **83.2%**, range 53.3%–96.3%.
- **Prescaler cost (`dflt` vs its `p=0` twin), 21 shapes so far**: mean **-0.44%**, median **+0.46%**, range -8.30% to +3.12%.
  Not uniform — 3 of 21 exceed ±3%; treat as a per-shape effect, not a flat tax, until the full 23 land.
- **`dflt` vs 2026-08-03 baseline**: median **-1.33%**, 15/21 faster.
- **`latest` vs baseline**: median **-1.35%**, 14/19 faster.

## `512x256x512` — RESOLVED: the collapse is specific to `prescale_w = 0`

This shape carried the campaign's last unexplained regression: **+252.7%** under `cfg_runtime=1`
(`sweepCSR` 280,917 cyc vs `phaseE1` 79,653). Every other runtime-CSR outlier is accounted for by
the `share_b = 1` burst-bypass fix, but this shape is `share_b = 4` — its burst entries genuinely
merge — so bypass does not apply and the cause was open.

**`presc4_512x256x512` settles it.** That arm is the *same* `sweepCSR` configuration and the *same*
ELF with one knob changed, `group_mshr_hold_prescale_w` 0 → 4 — the shipping default:

| arm | `cfg_runtime` | `prescale_w` | cycles | efficiency | dead periods |
|---|:--:|:--:|---:|---:|---:|
| `phaseE1` | 0 | 0 | 79,653 | 82.3% | 0 |
| `sweepCSR` | 1 | **0** | **280,917** | 23.3% | **169 of 281** |
| `presc4` | 1 | **4** | **80,064** | 81.9% | **1 of 80** |

**3.51× faster than the collapsing arm, and +0.52% against the healthy reference** — so at the
shipping prescaler the runtime CSR costs essentially nothing on this shape either.

Three independent arms agree: `presc4` (batch, matched ELF), the `build_4` interactive run
(~79,127 cyc, matching the healthy reference within 0.7%), and `latest_512x256x512`.

The leading indicator was `grp_min`, not aggregate utilisation. At the same benchmark-relative
point the collapsing arm still showed 90–92% aggregate while `grp_min` oscillated between 1.5% and
13% for thousands of cycles; `presc4` held `grp_min` at 90–96% throughout with no excursions. A mean
over 16 groups hides this completely.

⚠️ **Characterised, not root-caused.** This establishes that the *shipping* configuration is
unaffected. It does not explain what `prescale_w = 0` and `cfg_runtime = 1` do to each other on this
shape, and roughly 190 earlier campaign arms were run at `prescale_w = 0` and carry that latent
behaviour. Treat the mechanism as open.

