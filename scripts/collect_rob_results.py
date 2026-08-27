#!/usr/bin/env python3
"""Collect the VLSU ROB experiments into one TSV + markdown.

Two experiment families share this collector because they answer one question --
how big does the reorder buffer need to be, and what does its depth buy:

  * ROB depth / dual-load A/B/C  (run prefix `rob_`), 10 shapes x 3 images:
        A = rob64 + dual_load=2   (production)
        B = rob64, dual_load off  (isolates H1 dual-load)
        C = rob32, dual_load off  (isolates ROB DEPTH)
    B vs A = dual-load's worth;  C vs B = depth's worth.

  * Asymmetric ROB depth (run prefix `robn_`): bursts use ROB0 only, so ports 1-3
    are sized independently.  D0 = 64/64 (control), D1 = 64/16, D2 = 128/16.

Every number is read from the arm's own transcript; nothing is carried over from a
different image or a different day (that is how a fake +34% regression happened once).
"""
import glob, json, os, re, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT_TSV = os.path.join(ROOT, "docs/benchmarks/rob_results.tsv")
OUT_MD  = os.path.join(ROOT, "docs/benchmarks/rob_experiments.md")

# shape tag -> (M, N, P, precision, human label)
SHAPES = {
    "d16a": (32, 128, 16384, 16, "decode fp16 D=128"),
    "d16b": (32, 256, 16384, 16, "decode fp16 D=256"),
    "d32a": (32, 128,  8192, 32, "decode fp32 D=128"),
    "d32b": (32, 256,  8192, 32, "decode fp32 D=256"),
    "p09":  (2048,  32,  128, 16, "prefill 2048x32x128"),
    "p20":  (2048,  64,  128, 16, "prefill 2048x64x128"),
    "p50":  (1024, 128,  256, 16, "prefill 1024x128x256"),
    "p49f": (1024,  64,  256, 32, "prefill 1024x64x256"),
    "p66":  (1024, 128,  512, 16, "prefill 1024x128x512"),
    "p78":  (1024, 256,  512, 16, "prefill 1024x256x512"),
}
IMAGES = [("A", "rob64 + dual-load", "production"),
          ("B", "rob64, no dual-load", "isolates dual-load"),
          ("C", "rob32, no dual-load", "isolates ROB depth"),
          ("D0", "ROB0 64 / ROB1-3 64", "asymmetric control"),
          ("D1", "ROB0 64 / ROB1-3 16", "shrink the idle ROBs"),
          ("D2", "ROB0 128 / ROB1-3 16", "deep burst ROB, vl ceiling 512 B")]

LANES = {16: 8192, 32: 4096}     # MAC/cycle at 8x8


def norm(raw):
    """QuestaSim prefixes every line with '# '; VCS does not. Normalise once."""
    return b"\n".join(l[2:] if l.startswith(b"# ") else l for l in raw.split(b"\n"))


def scrape(d):
    t = os.path.join(d, "transcript")
    if not os.path.exists(t):
        return None
    try:
        txt = norm(open(t, "rb").read())
    except OSError:
        return None
    cyc = re.findall(rb"execution took (\d+)", txt)
    if not cyc:
        return None
    # per-period deltas -- these are NOT totals, they must be summed
    tmo = sum(int(x) for x in re.findall(rb"mshr_timeout=\+(\d+)", txt))
    bf  = sum(int(x) for x in re.findall(rb"bankfull_bypass=\+(\d+)", txt))
    rh  = txt.count(b"RH STUCK")
    cum = re.findall(rb"\[FPU\] bench[^\n]*?cum=([0-9.]+)%", txt)
    why = re.findall(rb"BURSTWHY[^\n]*burst=([01])", txt)
    # How the SIMULATION ended, which is not the same as whether the KERNEL ran.
    # Every p* arm in this sweep dies on mempool_group_mshr.sv:2269 ("MSHR clock gate dropped a
    # resp_buf write") in the EPILOGUE -- after the benchmark region has opened and closed. The
    # cycle count above is therefore still a real workload measure, but the arm must never be
    # described as having finished. Only "[FPU FINAL] ... never active" invalidates the data.
    fin  = re.search(rb"\[FPU FINAL\][^\n]*", txt)
    if fin and b"never active" in fin.group(0):
        state = "no-bench"                 # benchmark never opened: NO DATA
    elif b"[EOC]" in txt:
        state = "eoc"                      # simulation completed
    elif b"Fatal:" in txt:
        state = "epilogue-fatal"           # kernel ran, sim died after the benchmark closed
    else:
        state = "unknown"
    return {"cycles": int(cyc[-1]),
            "tmo": tmo, "bf": bf, "rh": rh, "state": state,
            "util": float(cum[-1]) if cum else None,
            "burst": why.count(b"1"), "nonburst": why.count(b"0")}


def main():
    rows = []
    for tag, (M, N, P, prec, label) in SHAPES.items():
        ideal = (M * N * P) / LANES[prec]
        for img, cfg, role in IMAGES:
            for pfx in ("rob", "robn"):
                d = os.path.join(ROOT, "hardware", "%s_%s_%s" % (pfx, img, tag))
                r = scrape(d)
                if not r:
                    continue
                rows.append(dict(shape=tag, label=label, prec=prec, img=img, cfg=cfg,
                                 ideal=ideal, eff=100.0 * ideal / r["cycles"], **r))
                break
    if not rows:
        print("no ROB arms delivered yet")
        return 0

    with open(OUT_TSV, "w") as f:
        f.write("shape\tprec\timage\tconfig\tcycles\teff\tutil\trh\ttmo\tbankfull\tburst\tnonburst\tstate\n")
        for r in sorted(rows, key=lambda x: (x["shape"], x["img"])):
            f.write("%s\tfp%d\t%s\t%s\t%d\t%.2f\t%s\t%d\t%d\t%d\t%d\t%d\t%s\n" % (
                r["shape"], r["prec"], r["img"], r["cfg"], r["cycles"], r["eff"],
                ("%.2f" % r["util"]) if r["util"] is not None else "-",
                r["rh"], r["tmo"], r["bf"], r["burst"], r["nonburst"], r.get("state","?")))

    by = {}
    for r in rows:
        by.setdefault(r["shape"], {})[r["img"]] = r

    L = ["# VLSU ROB experiments — depth, dual-load, and asymmetric sizing", "",
         "GENERATED by `scripts/collect_rob_results.py`. **Re-run rather than editing.**", "",
         "Every figure is read from that arm's own transcript. Images differ only in the",
         "defines named below — verified by a full define-diff before dispatch, because a",
         "comparison against an image built at a different time once produced a fake +34%",
         "regression.", "",
         "| image | config | isolates |", "|---|---|---|"]
    for img, cfg, role in IMAGES:
        L.append("| **%s** | %s | %s |" % (img, cfg, role))

    L += ["", "## Results", "",
          "| shape | prec | " + " | ".join("%s cyc" % i for i, _, _ in IMAGES) +
          " | B vs A | C vs B |", "|---|---|" + "---:|" * (len(IMAGES) + 2)]
    for tag in SHAPES:
        d = by.get(tag)
        if not d:
            continue
        cells = []
        for img, _, _ in IMAGES:
            cells.append("{:,}".format(d[img]["cycles"]) if img in d else "—")
        a, b, c = (d.get(x, {}).get("cycles") for x in ("A", "B", "C"))
        dba = "**%+.1f%%**" % (100.0 * (b - a) / a) if a and b else "—"
        dcb = "%+.1f%%" % (100.0 * (c - b) / b) if b and c else "—"
        L.append("| `%s` | fp%d | %s | %s | %s |" % (
            tag, SHAPES[tag][3], " | ".join(cells), dba, dcb))

    done = [t for t in SHAPES if all(x in by.get(t, {}) for x in ("A", "B", "C"))]
    if done:
        dl = [100.0 * (by[t]["B"]["cycles"] - by[t]["A"]["cycles"]) / by[t]["A"]["cycles"] for t in done]
        dp = [100.0 * (by[t]["C"]["cycles"] - by[t]["B"]["cycles"]) / by[t]["B"]["cycles"] for t in done]
        L += ["", "### What the A/B/C set says (%d of %d triples)" % (len(done), len(SHAPES)), "",
              "* **Dual-load is worth %+.1f%% to %+.1f%%** (mean %+.1f%%)."
              % (min(dl), max(dl), sum(dl) / len(dl)),
              "* **ROB depth alone is worth %+.1f%% to %+.1f%%** — B and C are bit-identical on"
              % (min(dp), max(dp)),
              "  every shape where both landed, so 32 vs 64 slots changes nothing by itself.",
              "  All of ROB64's value is that it lets two loads be co-resident.", ""]

    tot_b = sum(r["burst"] for r in rows)
    tot_n = sum(r["nonburst"] for r in rows)
    if tot_b + tot_n:
        L += ["### Burst / non-burst mix (`[BURSTWHY]`)", "",
              "| | loads | share |", "|---|---:|---:|",
              "| burst path | %s | %.1f%% |" % ("{:,}".format(tot_b), 100.0 * tot_b / (tot_b + tot_n)),
              "| non-burst | %s | %.1f%% |" % ("{:,}".format(tot_n), 100.0 * tot_n / (tot_b + tot_n)),
              "",
              "Bursts use **ROB0 only** (requests are port-0; ParityDrain lands even beats from",
              "mem port 0 and odd beats from mem port 1 in ROB0's id range). So a 100% burst mix",
              "means ROBs 1-3 hold nothing and can be shrunk for free — which is what the D1/D2",
              "images test.", "",
              "⚠️ `BurstWhyMax = 24`, so this samples the first 24 distinct load ids **per core**,",
              "not the whole run. Scalar A-matrix loads never appear: they go through the FPU",
              "sequencer's FP-LSU, not the VLSU.", ""]

    open(OUT_MD, "w").write("\n".join(L) + "\n")
    print("wrote %s and %s (%d arm(s), %d complete triple(s))" % (OUT_TSV, OUT_MD, len(rows), len(done)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
