# GEMM benchmark results — pure defaults (`dflt`) and full latest stack (`latest`)

Generated 2026-08-17 16:08. **Re-runnable**: `python3 /tmp/claude-620771/gen_dflt_latest_doc.py`.

**Status: 16/23 `dflt` complete, 14/23 `latest` complete.** This file regenerates as arms land; re-run the generator rather than trusting a stale copy.

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
| 128x1024x512 | 65,536 | 67,693 | 67,005 | **_run_** | — | — | **_run_** | — | — |
| 256x1024x256 | 65,536 | 68,253 | 68,410 | **_run_** | — | — | **_run_** | — | — |
| 128x512x512 | 32,768 | 34,489 | 34,041 | **34,301** | 95.5% | -0.5% | **_run_** | — | — |
| 256x512x256 | 32,768 | 34,821 | 34,547 | **34,671** | 94.5% | -0.4% | **34,603** | 94.7% | -0.6% |
| 128x256x512 | 16,384 | 18,082 | 17,627 | **17,800** | 92.0% | -1.6% | **17,838** | 91.8% | -1.3% |
| 256x512x512 | 65,536 | 71,218 | 71,116 | **_run_** | — | — | **_run_** | — | — |
| 256x256x256 | 16,384 | 18,177 | 17,984 | **18,067** | 90.7% | -0.6% | **18,246** | 89.8% | +0.4% |
| 512x256x256 | 32,768 | 37,632 | 38,260 | **_run_** | — | — | **_run_** | — | — |
| 512x512x128 | 32,768 | 38,325 | 38,885 | **37,732** | 86.8% | -1.5% | **_run_** | — | — |
| 128x128x512 | 8,192 | 9,792 | 9,401 | **9,514** | 86.1% | -2.8% | **9,512** | 86.1% | -2.9% |
| 512x512x512 | 131,072 | 153,707 | 154,734 | **_run_** | — | — | **_run_** | — | — |
| 512x256x512 | 65,536 | 78,314 | 79,653 | **_run_** | — | — | **_run_** | — | — |
| 256x128x256 | 8,192 | 10,014 | 9,944 | **9,794** | 83.6% | -2.2% | **9,842** | 83.2% | -1.7% |
| 512x256x128 | 16,384 | 20,155 | 19,493 | **19,886** | 82.4% | -1.3% | **19,495** | 84.0% | -3.3% |
| 512x128x256 | 16,384 | 20,307 | 20,538 | **20,548** | 79.7% | +1.2% | **20,830** | 78.7% | +2.6% |
| 512x128x512 | 32,768 | 42,767 | 42,743 | **_run_** | — | — | **_run_** | — | — |
| 512x128x128 | 8,192 | 11,111 | 11,144 | **11,202** | 73.1% | +0.8% | **12,044** | 68.0% | +8.4% |
| 256x64x256 | 4,096 | 6,050 | 5,860 | **5,784** | 70.8% | -4.4% | **5,853** | 70.0% | -3.3% |
| 512x64x512 | 16,384 | 24,616 | 24,607 | **23,358** | 70.1% | -5.1% | **22,939** | 71.4% | -6.8% |
| 512x64x256 | 8,192 | 12,183 | 11,930 | **12,006** | 68.2% | -1.5% | **12,353** | 66.3% | +1.4% |
| 256x32x512 | 4,096 | 6,752 | 6,598 | **6,804** | 60.2% | +0.8% | **6,564** | 62.4% | -2.8% |
| 512x32x512 | 8,192 | 16,238 | 15,088 | **13,836** | 59.2% | -14.8% | **15,365** | 53.3% | -5.4% |
| 256x32x256 | 2,048 | 4,081 | 3,771 | **3,846** | 53.3% | -5.8% | **3,667** | 55.8% | -10.1% |

## Summary

- **`dflt` utilisation, 16 shapes so far**: median **81.1%**, range 53.3%–95.5%. (Baseline's median over the same 16 shapes: **81.0%**.)
- **`latest` utilisation, 14 shapes so far**: median **75.0%**, range 53.3%–94.7%.
- **Prescaler cost (`dflt` vs its `p=0` twin), 16 shapes so far**: mean **-0.44%**, median **+0.49%**, range -8.30% to +3.12%.
  Not uniform — 3 of 16 exceed ±3%; treat as a per-shape effect, not a flat tax, until the full 23 land.
- **`dflt` vs 2026-08-03 baseline**: median **-1.50%**, 13/16 faster.
- **`latest` vs baseline**: median **-2.25%**, 10/14 faster.

## `512x256x512` — the one shape this sweep cannot yet settle

Not in the table above with a result: `latest_512x256x512` and its unshared-build cousin
`presc4_512x256x512` (the `sweepCSR` config re-run at `prescale_w=4` instead of 0) are both still
running. This is the shape that showed +252.7% under `cfg_runtime=1` at `prescale_w=0`
(`sweepCSR`: 280,917 vs `phaseE1` 79,653) — every other CSR regression in the 23-shape sweep is
explained by the `share_b=1` burst-bypass fix, but this one is `share_b=4` and bypass does not apply.

The `build_4` GUI run (same shape, `cfg_runtime=1`, `prescale_w=4`) **completed cleanly** at
approximately 79,127 benchmark cycles (benchmark window 20,873→~100,000) — matching the healthy
`phaseE1` reference to within 0.7%, with `retval=0`. That is one data point suggesting the
+252.7% collapse is specific to `prescale_w=0` and does not reproduce at the shipping default, but
it used a different ELF than the batch arms (`d852037a2d4c` vs `4ed3124f52a1`) and is not yet
corroborated by a comparable batch measurement. `presc4` and `latest` on the batch ELF are the
confirmation; neither has reached the benchmark-relative cycle where the `prescale_w=0` arm
collapsed (76,069) as of this generation.

