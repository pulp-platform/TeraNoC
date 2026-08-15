# GEMM benchmark results — the four pinned shapes at `hold_window_burst = 2047`

Generated 2026-08-15 16:39. **Re-runnable**: `python3 scripts/gen_win2047_doc.py`.

## Why this file exists

The standing decision is `hold_window_burst = 2047` at both meshes. Four shapes deviate: their
flavour pins the window to **0**, so the 23-shape sweep had four holes at the shipping config.
These arms fill them with measurements instead of an argument.

All four are built on the C1 truncation fix (`7737baee`), so this is the **window's cost in
isolation** — not the truncation bug, which was separately shown not to affect these shapes.

## Results

| M×N×P | ideal | ref (win=0) | opt3 (win=0) | **win=2047** | vs ref | vs opt3 |
|---|---:|---:|---:|---:|---:|---:|
| 128x128x512 | 8,192 | 9,792 | 165,585 | **185,505** | **+1,794%** | +12% |
| 128x256x512 | 16,384 | 18,082 | 25,498 | **362,019** | **+1,902%** | +1320% |
| 128x512x512 | 32,768 | 34,489 | 46,256 | **725,967** | **+2,005%** | +1469% |
| 128x1024x512 | 65,536 | 67,693 | 139,129 | _1035p, 6.0% util_ | — | — |

**3 of 4 complete.** mean **+1,900%** vs reference.

## Why it is this bad, and why the pin exists

These four shapes have **B shared 1-way**. `hold_subs_burst` therefore clamps to 2, and a
1-way-shared line can never supply 2 subscribers — so the early-release condition is
**unreachable** and every burst allocation waits the full 2047-cycle window. The pin is a
disable, not a tuning value.

The measured magnitude matches that mechanism: `128x128x512` runs 185,505 cycles against a 9,792
reference, ~19x, on a kernel whose ideal is 8,192 cycles.

> **Correction worth carrying.** This class was long quoted at **+803%**. That figure came from
> an arm killed mid-run that never produced a `[FPU FINAL]` — an extrapolation from partial
> progress, not a measurement. The measured value is far worse. Do not cite killed-run
> extrapolations as data.

## Conclusion

`hold_window_burst = 2047` everywhere **except** these four shapes, where the flavour pin to 0
stands. The exception is now backed by measurement.

