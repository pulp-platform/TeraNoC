# `bank_publish` × `hold_window_single` — a 2×2 on `128x1024x512`

Not a shape sweep, so it has no generator: four builds of **one** shape, differing only in two knobs.

## Why this exists

`128x1024x512` regressed from **67,693** cycles (96.8% of roofline) in `gemm_results.md` to **130,792**
(50.1%) by `sweepC2`/`phaseE1`. The campaign has been measuring deltas against the *regressed*
baseline. `docs/mshr_ppa_plan.md` called for bisecting opt3's two independent halves — the
bank-narrowed drain selector and the per-bank round-robin publish — *"rather than proposing another
mechanism"*, after two mechanisms proposed from symptom shape alone were refuted.

An earlier arm (`hsingle2047`, 99,879 cyc) appeared to show a large win from a long single window,
but it moved **three** knobs: `hold_window_single`, `bank_publish`, **and** `spill_req_in` — the last
inherited from being built ~4.5 h before commit `f7a7e90f` flipped that default. It is not
attributable and is not used here. All four corners below sit on the current campaign base and were
gated on a 28-define diff against `sweepC2`.

## Results

`ideal = 65,536` cycles.

| | `bank_publish = 1` | `bank_publish = 0` |
|---|---|---|
| **`hold_window_single = 0`** | **130,792** (50.1%) ← shipping default | **92,347** (70.9%) |
| **`hold_window_single = 2047`** | **91,233** (71.8%) | **93,516** (70.1%) |

Main effects, each read at the other knob's shipping value:

- `hold_window_single` 0 → 2047, at `publish=1`: **−30.2%**
- `bank_publish` 1 → 0, at `single=0`: **−29.4%**
- both together: 93,516 — **no better**, marginally worse

## The interaction is the finding

If the two effects were independent, the both-on corner would land near **64,000**. It lands at
**93,516**. The knobs are strongly sub-additive: they are two routes out of the **same** pathology,
not two separate wins.

**The collapse requires both `bank_publish = 1` and `hold_window_single = 0`.** Either knob alone
escapes it, and the shipping default is exactly the corner that has both.

This answers the plan's bisect: **`bank_publish` — one of opt3's two halves — is implicated.**

> **A reading error worth recording.** With only the `single=2047` row in hand, `bank_publish` looked
> irrelevant: 91,233 vs 93,516 is a 2.4% difference, and it was reported that way. That row is the
> one where the pathology is already escaped, so the knob genuinely does not matter *there*. Reading
> a main effect off one row of a 2×2 with a strong interaction inverts the conclusion. The fourth
> corner was necessary, not confirmatory.

## Still not a fix

The best corner, 91,233 (71.8%), is still **+34.8% slower than the original 67,693** (96.8%). These
knobs recover roughly half of a self-inflicted regression; they do not restore the shape. The root
cause remains unexplained.

## Related evidence pointing the same way

A separate accident is consistent with a single latent pathology on this shape family. A
`MshrCfgSubsW` truncation bug wrote `hold_subs_single = 0` instead of 16, crippling single merging,
and `128x128x512` ran **9,718** cycles (84.3%) instead of **16,995** (48.2%). Three unrelated-looking
configurations put that shape at ~4–5% efficiency (opt3 165,585; `hold_window_burst=2047` 185,505;
`cfg_runtime=1` 207,223), and the one thing that rescues it is *disabling single merging*.

Four independent observations now point at one latent pathology rather than several separate bugs.
The `hold_subs_single = 1` probe (the legal bypass encoding) tests that directly.
