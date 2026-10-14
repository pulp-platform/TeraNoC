#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# qwen-proj results: read RTL / GVSoC transcripts, extrapolate truncated runs, write a TSV and the
# markdown tables of docs/qwen3_8_27b/linear_bench_plan.md.
#
#   proj_results.py <dir> [<dir> ...] [--tsv out.tsv] [--md out.md]
#
# Each <dir>/<tag>/transcript (badist harvest layout) or <dir>/<tag>.transcript. The program's
# lines are read with the RTL "[UART] " / QuestaSim "# " prefixes stripped. Per run:
#   cycles     the timed region (truncated runs: of the truncated region)
#   t_tile     steady K-tile interval: median of the tiles after the first of every
#              (strip, projection) segment of the stream (qwen_phase.c tile_cyc)
#   full       cycles + (steps - steps_run) x strips x stages x t_tile (= cycles when not truncated)
#   eff        ideal / full, ideal = MACs / (cores x 8)
import argparse
import os
import re
import statistics
import sys

MESH_CORES = {256: "4x4", 1024: "8x8"}


def lines(path):
    with open(path, errors="replace") as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if ln.startswith("# "):
                ln = ln[2:]
            if ln.startswith("[UART] "):
                ln = ln[7:]
            yield ln


def parse(path):
    r = {"path": path}
    for ln in lines(path):
        m = re.match(r"\[PROJ\] built for (\S+) cores=(\d+)", ln)
        if m:
            r["mesh"] = MESH_CORES.get(int(m.group(2)), m.group(2))
            r["cores"] = int(m.group(2))
        m = re.match(r"\[PROJ\] shape=(\w+) B=(\d+) K=(\d+) P=(\d+) stages=(\d+) steps_run=(\d+) "
                     r"t0=(\d+) cycles=(\d+) ideal=(\d+)", ln)
        if m:
            r.update(shape=m.group(1), B=int(m.group(2)), K=int(m.group(3)), P=int(m.group(4)),
                     stages=int(m.group(5)), steps_knob=int(m.group(6)), cycles=int(m.group(8)),
                     ideal=int(m.group(9)))
        if ln.startswith("[PROJ] min "):
            # proj_report=min: the same fields in one line, numbers in hex
            f = dict(kv.split("=", 1) for kv in ln[len("[PROJ] min "):].split() if "=" in kv)
            h = {k: int(v, 16) for k, v in f.items() if k not in ("shape", "tiles")}
            r["cores"] = h["cores"]
            r["mesh"] = MESH_CORES.get(h["cores"], str(h["cores"]))
            r.update(shape=f["shape"], B=h["B"], K=h["K"], P=h["P"], stages=h["stages"],
                     cycles=h["cycles"], kt=h["kt"], pt=h["pt"], strips=h["strips"],
                     steps=h["steps"], kernel=h["ks"], ksplit=h["ksplit"], kgroup=h["kgroup"],
                     xrep=h["xrep"], strips_run=h["strips_run"],
                     ideal=h["stages"] * h["B"] * h["K"] * h["P"] // (h["cores"] * 8))
            # steps_knob as the full report has it: 0 = every K tile
            r["steps_knob"] = 0 if h["steps_run"] == h["steps"] else h["steps_run"]
            r["tiles"] = [int(x, 16) for x in f.get("tiles", "").split(",") if x]
            w = h["warn"]
            if w:
                r["warn"] = "SPLIT MISMATCH" if w & 1 else "UNALIGNED" if w & 2 else "cfg REJECTED"
        m = re.match(r"\[FFN\] proj B=\d+ K=\d+ P=\d+ stages=\d+ kt=(\d+) pt=(\d+) strips=(\d+) "
                     r"steps=(\d+) ks=(\d+) ksplit=(\d+) kgroup=(\d+) xrep=(\d+)", ln)
        if m:
            r.update(kt=int(m.group(1)), pt=int(m.group(2)), strips=int(m.group(3)),
                     steps=int(m.group(4)), kernel=int(m.group(5)), ksplit=int(m.group(6)),
                     kgroup=int(m.group(7)), xrep=int(m.group(8)))
        m = re.match(r"\[FFN\] proj TRUNCATED steps_run=(\d+) of \d+ strips_run=(\d+)", ln)
        if m:
            r["strips_run"] = int(m.group(2))
        m = re.match(r"\[FFN\] proj tile_cyc=([\d,]+)", ln)
        if m:
            r["tiles"] = [int(x) for x in m.group(1).split(",")]
        m = re.match(r"\[FFN\] proj MSHR .*?((SPLIT MISMATCH)|(UNALIGNED)|(cfg REJECTED))", ln)
        if m:
            r["warn"] = m.group(1)
        if ln.startswith("success!"):
            r["check"] = "pass"
        if ln.startswith("FAIL:"):
            r["check"] = "FAIL"
        m = re.match(r"\[FPU FINAL\] busy=(\d+) of (\d+)", ln)
        if m:
            r["fpu_util"] = int(m.group(1)) / max(int(m.group(2)), 1)
        m = re.search(r"\[EOC\].*retval = (\d+)", ln)
        if m:
            r["eoc"] = int(m.group(1))
    if "cycles" not in r:
        return r
    steps_run = r["steps_knob"] or r.get("steps", 0)
    r["steps_run"] = steps_run
    tiles = r.get("tiles", [])
    steady = [t for i, t in enumerate(tiles) if steps_run and i % steps_run]
    r["t_tile"] = statistics.median(steady) if steady else 0
    strips = r.get("strips", 1)
    srun = r.get("strips_run", strips)
    r["strips_run"] = srun
    miss = (r.get("steps", steps_run) - steps_run) * strips * r["stages"]
    # each strip run stands for strips/strips_run of them; then the K tiles left out
    r["full"] = r["cycles"] * strips / srun + miss * r["t_tile"]
    r["truncated"] = miss > 0 or srun < strips
    r["eff"] = r["ideal"] / r["full"] if r["full"] else 0
    return r


def find(dirs):
    for d in dirs:
        for e in sorted(os.listdir(d)):
            p = os.path.join(d, e)
            if os.path.isdir(p) and os.path.isfile(os.path.join(p, "transcript")):
                yield e, os.path.join(p, "transcript"), d
            elif e.endswith(".transcript"):
                yield e[:-11], p, d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--tsv")
    ap.add_argument("--md")
    a = ap.parse_args()
    rows = []
    for tag, path, d in find(a.dirs):
        r = parse(path)
        r["tag"], r["src"] = tag, os.path.basename(os.path.normpath(d))
        rows.append(r)
    cols = ["src", "tag", "mesh", "shape", "B", "K", "P", "kt", "pt", "strips", "steps", "steps_run", "strips_run",
            "ksplit", "kgroup", "cycles", "t_tile", "full", "ideal", "eff", "fpu_util", "check",
            "eoc", "warn"]
    out = ["\t".join(cols)]
    for r in rows:
        v = []
        for c in cols:
            x = r.get(c, "")
            v.append("%.4f" % x if isinstance(x, float) else str(x))
        out.append("\t".join(v))
    txt = "\n".join(out) + "\n"
    if a.tsv:
        open(a.tsv, "w").write(txt)
    else:
        sys.stdout.write(txt)
    if a.md:
        md = ["| src | mesh | stage | B | KT x PT, strips, ks | run | cycles (full) | eff | FPU |",
              "|---|---|---|---:|---|---|---:|---:|---:|"]
        for r in rows:
            if "cycles" not in r:
                md.append("| %s | | %s | | | no result | | | |" % (r["src"], r["tag"]))
                continue
            run = ("%d/%d tiles, %d/%d strips" % (r["steps_run"], r.get("steps", 0), r["strips_run"],
                                                 r.get("strips", 0))) if r["truncated"] else "full"
            md.append("| %s | %s | %s | %d | %dx%d, %d, %d%s | %s | %s | %.1f%% | %s |" % (
                r["src"], r.get("mesh", "?"), r["shape"], r["B"], r.get("kt", 0), r.get("pt", 0),
                r.get("strips", 0), r.get("ksplit", 0), " xg" if r.get("kgroup") else "", run,
                "{:,}".format(int(round(r["full"]))), 100 * r["eff"],
                "%.1f%%" % (100 * r["fpu_util"]) if "fpu_util" in r else ""))
        open(a.md, "w").write("\n".join(md) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
