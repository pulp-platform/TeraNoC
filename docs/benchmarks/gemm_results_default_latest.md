# GEMM benchmark results — pure defaults (`dflt`) and full latest stack (`latest`)

Generated 2026-08-17 16:05. **Re-runnable**: `python3 /tmp/claude-620771/gen_dflt_latest_doc.py`.

**Status: 15/23 `dflt` complete, 13/23 `latest` complete.** This file regenerates as arms land; re-run the generator rather than trusting a stale copy.

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

| M×N×P | ideal | baseline | p=0 twin | **dflt (p=4)** | **latest (CSR, p=4)** |
|---|---:|---:|---:|---:|---:|
| 128x1024x512 | 65,536 | 67,693 | 67,005 | **_run_** | **_run_** |
| 256x1024x256 | 65,536 | 68,253 | 68,410 | **_run_** | **_run_** |
| 128x512x512 | 32,768 | 34,489 | 34,041 | **_run_** | **_run_** |
| 256x512x256 | 32,768 | 34,821 | 34,547 | **34,671** | **_run_** |
| 128x256x512 | 16,384 | 18,082 | 17,627 | **17,800** | **17,838** |
| 256x512x512 | 65,536 | 71,218 | 71,116 | **_run_** | **_run_** |
| 256x256x256 | 16,384 | 18,177 | 17,984 | **18,067** | **18,246** |
| 512x256x256 | 32,768 | 37,632 | 38,260 | **_run_** | **_run_** |
| 512x512x128 | 32,768 | 38,325 | 38,885 | **37,732** | **_run_** |
| 128x128x512 | 8,192 | 9,792 | 9,401 | **9,514** | **9,512** |
| 512x512x512 | 131,072 | 153,707 | 154,734 | **_run_** | **_run_** |
| 512x256x512 | 65,536 | 78,314 | 79,653 | **_run_** | **_run_** |
| 256x128x256 | 8,192 | 10,014 | 9,944 | **9,794** | **9,842** |
| 512x256x128 | 16,384 | 20,155 | 19,493 | **19,886** | **19,495** |
| 512x128x256 | 16,384 | 20,307 | 20,538 | **20,548** | **20,830** |
| 512x128x512 | 32,768 | 42,767 | 42,743 | **_run_** | **_run_** |
| 512x128x128 | 8,192 | 11,111 | 11,144 | **11,202** | **12,044** |
| 256x64x256 | 4,096 | 6,050 | 5,860 | **5,784** | **5,853** |
| 512x64x512 | 16,384 | 24,616 | 24,607 | **23,358** | **22,939** |
| 512x64x256 | 8,192 | 12,183 | 11,930 | **12,006** | **12,353** |
| 256x32x512 | 4,096 | 6,752 | 6,598 | **6,804** | **6,564** |
| 512x32x512 | 8,192 | 16,238 | 15,088 | **13,836** | **15,365** |
| 256x32x256 | 2,048 | 4,081 | 3,771 | **3,846** | **3,667** |

## Summary

- **Prescaler cost (`dflt` vs its `p=0` twin), 15 shapes so far**: mean **-0.52%**, median **+0.46%**, range -8.30% to +3.12%.
  Not uniform — 3 of 15 exceed ±3%; treat as a per-shape effect, not a flat tax, until the full 23 land.
- **`dflt` vs 2026-08-03 baseline**: median **-1.55%**, 12/15 faster.
- **`latest` vs baseline**: median **-2.78%**, 9/13 faster.

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

