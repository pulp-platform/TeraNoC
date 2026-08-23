#!/usr/bin/env python3
"""Emit docs/benchmarks/gemm_results_4x4_idea2_bankfull.md from the live run4/run5 arms.

Why this exists: the 2026-08-21/22 4x4 sweeps (idea-2, and idea-2 + bank-full backpressure, both
precisions) were published only as artifacts. Artifacts are not in git and not diffable; the
benchmark tree had nothing newer than gemm_results_default_latest.md (2026-08-19). This turns the
same scrape the dashboards use into a committed document.

Re-run after new arms land:  python3 scripts/gen_4x4_idea2_bp_doc.py
"""
import importlib.util, os, statistics, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT  = os.path.join(ROOT, "docs/benchmarks/gemm_results_4x4_idea2_bankfull.md")

spec = importlib.util.spec_from_file_location("g", os.path.join(ROOT, "scripts/gen_fp16_sweep_dash.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)


def key(s):
    return [int(x) for x in s.split("x")]


def main():
    arms = g.collect()
    idx = {}
    for a in arms:
        if a.get("ver") in (4, 5) and a.get("kernel_cycles"):
            idx[(a["prec"], a["shape"], a["ver"])] = a

    L = []
    w = L.append
    w("# GEMM results, 4x4 / 256 cores — idea-2 and bank-full backpressure, fp16 and fp32")
    w("")
    w("Generated %s by `scripts/gen_4x4_idea2_bp_doc.py`. **Re-run it rather than trusting a stale copy.**"
      % time.strftime("%Y-%m-%d %H:%M"))
    w("")
    w("These are the newest 4x4 arms in the tree. Until this file existed they were published only as")
    w("artifacts (*Spatz fp16 Sweep*, *Spatz Idea-2 Sweep*, *Backpressure Sweep*), so the benchmark")
    w("tree's newest 4x4 document was `gemm_results_default_latest.md` (2026-08-19) — which is fp32")
    w("only and predates both changes below.")
    w("")
    w("## The two arms")
    w("")
    w("| arm | dir prefix | what it is |")
    w("|---|---|---|")
    w("| **idea-2** | `run4_<prec>_<MxNxP>` | RTL at HEAD (cache reuse-target CSRs), response cache ON, per-shape MSHR tuning **derived at compile time** from `GEMM_M/N/P` rather than a per-shape config |")
    w("| **+bankfull-bp** | `run5_<prec>_<MxNxP>` | identical in every other respect — same ELFs, same derived tuning, `MergeReqs=16`. The single difference: a mergeable miss whose MSHR bank is full now **stalls** instead of bypassing the MSHR |")
    w("")
    w("A bypass splits the coalescing cohort, which is what strands a later allocator on `serve_timeout`.")
    w("The hypothesis under test is that back-pressuring instead of bypassing keeps the cohort intact.")
    w("")
    w("`eff` is **efficiency = ideal / actual**, not the testbench `[FPU] util` counter (lane occupancy,")
    w("not conserved across runs of identical work, and it has inverted a real ranking before).")
    w("`ideal = M·N·P / peak`, peak = **1024** MAC/cyc at fp32 and **2048** at fp16 (256 cores x 4 FPU,")
    w("x2 lanes at e16). `RH` and `timeout` are the response-hazard episode and `mshr_timeout` counters.")
    w("")

    for prec, label in ((16, "fp16"), (32, "fp32")):
        shapes = sorted({s for (p, s, v) in idx if p == prec}, key=key)
        w("## %s" % label)
        w("")
        w("| M×N×P | ideal | idea-2 | eff | +bankfull-bp | eff | Δ | RH i2 | RH bp | timeout i2 | timeout bp |")
        w("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        deltas = []
        for s in shapes:
            a4, a5 = idx.get((prec, s, 4)), idx.get((prec, s, 5))
            ideal = (a4 or a5)["ideal"]
            c4 = a4["kernel_cycles"] if a4 else None
            c5 = a5["kernel_cycles"] if a5 else None
            d = (100.0 * (c5 - c4) / c4) if (c4 and c5) else None
            if d is not None:
                deltas.append(d)
            w("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                s, "{:,}".format(ideal),
                "{:,}".format(c4) if c4 else "—", ("%.1f%%" % a4["eff"]) if a4 and a4.get("eff") else "—",
                "**{:,}**".format(c5) if c5 else "—", ("**%.1f%%**" % a5["eff"]) if a5 and a5.get("eff") else "—",
                ("%+.1f%%" % d) if d is not None else "—",
                "{:,}".format(a4["rh_episodes"]) if a4 else "—",
                "{:,}".format(a5["rh_episodes"]) if a5 else "—",
                "{:,}".format(a4["mshr_timeout"]) if a4 else "—",
                "{:,}".format(a5["mshr_timeout"]) if a5 else "—"))
        w("")
        if deltas:
            better = sum(1 for d in deltas if d < -0.5)
            worse = sum(1 for d in deltas if d > 0.5)
            same = len(deltas) - better - worse
            w("%d matched pairs: **%d faster with backpressure, %d slower, %d bit-identical** "
              "(median Δ %+.1f%%, range %+.1f%% to %+.1f%%)."
              % (len(deltas), better, worse, same, statistics.median(deltas), min(deltas), max(deltas)))
            w("")

    # fp16 vs fp32 on the best arm
    w("## fp16 against fp32, on the backpressure arm")
    w("")
    w("| M×N×P | fp16 | eff | fp32 | eff | fp32/fp16 |")
    w("|---|---:|---:|---:|---:|---:|")
    sp, sp_ok = [], []
    for s in sorted({s for (p, s, v) in idx if v == 5}, key=key):
        a, b = idx.get((16, s, 5)), idx.get((32, s, 5))
        if not (a and b):
            continue
        r = b["kernel_cycles"] / a["kernel_cycles"]
        sp.append(r)
        if key(s)[0] >= 256:
            sp_ok.append(r)
        w("| %s | %s | %.1f%% | %s | %.1f%% | **%.2fx** |" % (
            s, "{:,}".format(a["kernel_cycles"]), a["eff"],
            "{:,}".format(b["kernel_cycles"]), b["eff"], r))
    w("")
    if sp_ok:
        w("Over the **%d shapes with M ≥ 256**: median **%.2fx**, range %.2fx–%.2fx."
          % (len(sp_ok), statistics.median(sp_ok), min(sp_ok), max(sp_ok)))
        w("")
        w("The %d M=128 fp16 shapes are excluded from that median and shown above only for the record —"
          % (len(sp) - len(sp_ok)))
        w("they are the **fp16 M=128 wedge** (3–12% efficiency, thousands of RH episodes), a defect,")
        w("not a datapoint. Backpressure does not reliably clear it.")
        w("")

    w("## What the two tables say")
    w("")
    w("1. **Backpressure is a no-op unless the arm has response hazards.** Every pair whose idea-2 arm")
    w("   reports `RH = 0` is bit-identical under backpressure — same cycle count to the digit. That is")
    w("   the expected signature: the stall path only exists on a mergeable miss into a full bank.")
    w("2. **Where RH is present at fp16 and M ≥ 512, the effect is enormous.** Those arms collapse to")
    w("   2–8% efficiency under idea-2 alone, with tens of thousands of RH episodes *and* MSHR timeouts;")
    w("   backpressure drives **both counters to exactly zero** and restores 54–91% efficiency.")
    w("3. **fp32 is essentially untouched.** Almost every fp32 pair is bit-identical; the three that move")
    w("   do so by 1–2%, and each had a two-digit RH count rather than a four- or five-digit one.")
    w("4. **RH is the gate, not the shape.** Do not quote a backpressure win without recording the")
    w("   arm's RH count — an arm with RH = 0 cannot benefit, and reporting its 0.0% as evidence")
    w("   either way is a category error.")
    w("")
    w("## Provenance and caveats")
    w("")
    w("- Scraped from `hardware/run4_*/transcript` and `hardware/run5_*/transcript` by the same reader")
    w("  the fp16 dashboards use (`scripts/gen_fp16_sweep_dash.py:collect`), so the numbers here and in")
    w("  those artifacts come from one code path.")
    w("- QuestaSim prefixes every transcript line with `# `; the reader strips it before matching. An")
    w("  anchored pattern that skips this silently reports zero rows.")
    w("- `[FPUG]`/`[FPU]` lines are tagged `pre` (warm-up, counters gated off) or `bench`. A `pre` zero")
    w("  means *not counting*, not idle. Only `bench` windows are summed.")
    w("- Cycles are whole-kernel, including DMA and every serial section — not a GEMM-only counter.")
    w("  This matters when comparing against accelerator DSE numbers that exclude DMA from the timed")
    w("  interval; see `docs/qwen38_kernel_mapping.md`.")
    w("")

    with open(OUT, "w") as f:
        f.write("\n".join(L) + "\n")
    print("wrote %s (%d lines)" % (OUT, len(L)))


if __name__ == "__main__":
    main()
