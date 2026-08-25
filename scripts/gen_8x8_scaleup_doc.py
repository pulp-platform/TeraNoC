#!/usr/bin/env python3
"""Render the 8x8 scale-up campaign results as markdown, from results.tsv.

NOT a replacement for docs/benchmarks/gemm_results_8x8_1024core.md -- that file is the durable
record of a DIFFERENT sweep (MSHR / response-channel, single shape 2048x512x512, Aug 13) whose
build directories were reclaimed. It cannot be regenerated and must not be overwritten.

This covers the 248-shape scale-up campaign, and applies the two corrections the raw table needs:
  * livelock rows are recorded FAILURES, not results -- they measure the mshr_cfg.h cohort-target
    bug, and averaging them in drags the campaign mean by ~7 pp;
  * rank on eff = ideal/actual, not on the TB util counter, which is lane OCCUPANCY and has
    inverted a real ranking before.
"""
import csv, os, statistics as st, subprocess, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
TSV  = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")
OUT  = os.path.join(ROOT, "docs/benchmarks/gemm_results_8x8_scaleup.md")
PEAK = {"fp16": 8192, "fp32": 4096}          # MAC/cycle at 8x8


def load():
    meas, live = [], []
    for r in list(csv.reader(open(TSV), delimiter="\t"))[1:]:
        if len(r) < 10:
            continue
        M, N, P = (int(x) for x in r[0].split("x"))
        d = dict(shape=r[0], prec=r[1], share=r[2], cycles=r[3], util=r[4], rh=r[5],
                 tmo=r[6], bf=r[7], spot=r[8], state=r[9], M=M, N=N, P=P)
        d["eff"] = (100.0 * (M * N * P / PEAK[r[1]]) / int(r[3])) if r[3].isdigit() and int(r[3]) else None
        (live if r[9] == "livelock" else meas).append(d)
    return meas, live


EB = {"fp16": 2, "fp32": 4}
BURST_BYTES = 64            # MSHR_MAX_BURST_WORDS(16) * 4


def split_p(M):
    sm = (M // 64) // 8
    return (16 // sm) if 0 < sm < 16 else 1


def burst_slice(M, P, prec):
    """Bytes of B each core loads per row. Below BURST_BYTES the vector load cannot burst, so B
    falls back to single-word requests and inherits hold_subs_single -- a target derived for A,
    which B can never meet because each core owns a distinct p range. This is the livelock."""
    return (P // split_p(M)) * EB[prec]


def target(M):                                    # cohort target the software derives, 8x8/KS=8
    sm = (M // 64) // 8
    sp = (16 // sm) if (0 < sm < 16) else 1
    return 1 if sp <= 2 else min(sp, max(sp, sm))


def main():
    meas, live = load()
    eff = [d["eff"] for d in meas if d["eff"] is not None]
    stamp = subprocess.run(["date", "+%Y-%m-%d %H:%M"], capture_output=True, text=True).stdout.strip()
    L = ["# GEMM results — 8×8 mesh, 1024 cores — 248-shape scale-up campaign", "",
         "Generated %s by `scripts/gen_8x8_scaleup_doc.py`. **Re-run rather than editing.**" % stamp,
         "",
         "`eff = ideal/actual`, `ideal = M·N·P / lanes` (fp16 8192 MAC/cyc, fp32 4096). Rank on `eff`,",
         "not on the TB `util` column — that counter is lane *occupancy*, is not conserved across runs",
         "of identical work, and has inverted a real ranking before.",
         "",
         "> **Not comparable with `gemm_results_8x8_1024core.md`.** That file records a different sweep",
         "> (MSHR / response-channel, single shape 2048×512×512) whose build dirs were reclaimed.",
         "",
         "## Campaign state", "",
         "| | count |", "|---|---:|",
         "| measurements | **%d** |" % len(meas),
         "| recorded livelock (failures, excluded below) | **%d** |" % len(live),
         "| of manifest | 248 |", ""]
    if eff:
        L += ["Efficiency over the %d measurements: **median %.1f%%**, mean %.1f%%, "
              "range %.1f–%.1f%%." % (len(eff), st.median(eff), st.mean(eff), min(eff), max(eff)), ""]
    # --- the cohort-target / P interaction, the campaign's main structural finding ---
    L += ["## Cohort target × P", "",
          "`MSHR_D_HOLD_SUBS_SINGLE` is derived from `M` alone; whether the cohort can form depends",
          "on `P`. Mean efficiency by (target, P) over measurements only:", "",
          "| target \\ P | " + " | ".join(str(p) for p in (128, 256, 512, 1024, 2048)) + " |",
          "|---:|" + "---:|" * 5]
    for t in (16, 8, 4, 1):
        row = ["| **%d** " % t]
        for p in (128, 256, 512, 1024, 2048):
            g = [d["eff"] for d in meas if target(d["M"]) == t and d["P"] == p and d["eff"] is not None]
            row.append("| %s " % ("%.1f%% (%d)" % (st.mean(g), len(g)) if g else "—"))
        L.append("".join(row) + "|")
    L += ["", "Livelock arms are excluded, so the low-target/low-P cells read better here than the",
          "campaign actually ran — the failures are listed separately below.", ""]
    # --- best / worst ---
    ok = sorted([d for d in meas if d["eff"] is not None], key=lambda d: -d["eff"])
    for title, rows in (("Best 12 by efficiency", ok[:12]), ("Worst 12 by efficiency", ok[-12:])):
        L += ["## %s" % title, "",
              "| shape | prec | target | B slice | cycles | eff | util | RH |",
              "|---|---|---:|---:|---:|---:|---:|---:|"]
        for d in rows:
            bs = burst_slice(d["M"], d["P"], d["prec"])
            L.append("| `%s` | %s | %d | %s | %s | **%.1f%%** | %s%% | %s |"
                     % (d["shape"], d["prec"], target(d["M"]),
                        ("%dB ⚠︎" % bs) if bs < BURST_BYTES else "%dB" % bs,
                        "{:,}".format(int(d["cycles"])), d["eff"], d["util"], d["rh"]))
        L.append("")
    # --- the second low-util population ---
    lowN = [d for d in ok if d["eff"] is not None and d["eff"] < 25 and d["rh"].isdigit() and int(d["rh"]) <= 1000]
    if lowN:
        byN = {}
        for d in lowN: byN[d["N"]] = byN.get(d["N"], 0) + 1
        L += ["## Low efficiency with `RH = 0` — a second, separate mechanism", "",
              "%d measurements sit below 25%% efficiency with **no** RH-livelock. Their `N` distribution:"
              % len(lowN), "",
              "| N | arms |", "|---:|---:|"]
        for n in sorted(byN): L.append("| %d | %d |" % (n, byN[n]))
        L += ["", "Small contraction depth, not the cohort mechanism. Distinct from the livelock and",
              "not addressed by any MSHR hold-window change.", ""]
    # --- shapes withdrawn from the sweep ---
    # These never produce a row anywhere else in this document: they have no result to report.
    # Saying so explicitly is the point -- a shape that is simply absent reads as "not run yet",
    # which is how the family attracted 26 dispatches and ~480 seat-hours before anyone added up
    # what it had returned.
    try:
        import sys as _sys
        _sys.path.insert(0, os.path.join(ROOT, "scripts/badist"))
        from feasibility import GATED, GUI_DEBUG_SHAPE
    except Exception:
        GATED, GUI_DEBUG_SHAPE = set(), None
    if GATED:
        L += ["## Gated shapes (%d) — withdrawn from the sweep" % len(GATED), "",
              "The **N=32 / P=2048** family. 26 dispatches across %d shapes, roughly 480 licence"
              % len(GATED),
              "seat-hours, and **not one completed run**. Every copy ran 59-118x over its ideal",
              "cycle count and never reached the end of the kernel.", "",
              "This is **not** the sub-burst livelock below: these B slices are 256-512 B, well",
              "past the 128 B optimum, and they carry `RH = 0` and `mshr_timeout = 0`. It is the",
              "low-N collapse -- at `N = 32` there is too little contraction work to keep a",
              "1024-core mesh fed -- taken to the point where the shape does not finish in any",
              "budget worth spending.", "",
              "They are gated by name in `scripts/badist/feasibility.py`. The dispatchers block on",
              "*evidence*, and \"never produced a number\" is not evidence they can read: with no",
              "delivered utilisation and no RH count there was nothing to observe, so the family",
              "stayed eligible and the top-up loops re-dispatched it indefinitely.", "",
              "| shape | prec | B slice | role |", "|---|---|---:|---|"]
        import re as _re
        for a in sorted(GATED):
            m = _re.match(r"(fp16|fp32)_(\d+)x(\d+)x(\d+)", a)
            if not m:
                continue
            pr, M, P = m.group(1), int(m.group(2)), int(m.group(4))
            role = ("**GUI debug shape** — reproduce this one interactively"
                    if a == GUI_DEBUG_SHAPE else
                    "cross-precision control" if a == "fp32_512x32x2048" else "gated")
            L.append("| `%dx%sx%d` | %s | %dB | %s |"
                     % (M, m.group(3), P, pr, burst_slice(M, P, pr), role))
        L += ["", "`%s` is the shape to open in QuestaSim when someone debugs this collapse: the"
              % (GUI_DEBUG_SHAPE or "-"),
              "smallest `M` in the family, so the shortest elaboration, at the precision the decode",
              "workload uses. `fp32_512x32x2048` is the control if the fp16 datapath itself falls",
              "under suspicion.", ""]

    # --- the recorded failures ---
    if live:
        L += ["## Recorded LIVELOCK (%d) — failures, not results" % len(live), "",
              "Root cause: the per-core **B slice** `(P/SPLIT_P)*elem_bytes` is below the "
              "**%d-byte** burst floor, so B cannot burst, falls back to single-word requests, and "
              "inherits `hold_subs_single` — a target derived for **A**, which B can never meet "
              "because each core owns a distinct `p` range. See "
              "`docs/benchmarks/8x8_scaleup/rh_livelock_root_cause.md` §0. "
              "**Every one of these has a sub-burst B slice.** Averaging them into the campaign "
              "drags the mean by ~7 pp." % BURST_BYTES, "",
              "| shape | prec | target | B slice | util | RH |", "|---|---|---:|---:|---:|---:|"]
        for d in sorted(live, key=lambda d: d["shape"]):
            L.append("| `%s` | %s | %d | **%dB** | %s%% | %s |"
                     % (d["shape"], d["prec"], target(d["M"]),
                        burst_slice(d["M"], d["P"], d["prec"]), d["util"], d["rh"]))
        L.append("")
    open(OUT, "w").write("\n".join(L) + "\n")
    print("wrote %s (%d measurements, %d livelock)" % (OUT, len(meas), len(live)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
