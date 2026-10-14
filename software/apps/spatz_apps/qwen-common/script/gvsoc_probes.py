#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# Turn one GVSoC run into an RTL-style transcript, so the RTL scrapers and dashboards read GVSoC
# runs unchanged (python 3.6: runs on the fleet nodes).
#
#   gvsoc_probes.py --mesh 4x4|8x8 --log run.log [--fpu run.fpu] [--dma run.dma]
#                   [--bench START:CYCLES] [--period 1000] -o transcript
#
# Inputs: the model's stdout (run.log), and the two probe files gvsoc_run.sh asks the model for
# (TERANOC_FPU_UTIL_PATH: "[FPUC] path= win= cyc= elems=" per core per window, vf* elements;
# TERANOC_DMA_STATS_PATH: one CSV line per DMA transfer).
#
# Output, in the RTL testbench's formats (hardware/tb):
#   [UART] <line>      every line the program printed
#   [FPU] pre|bench    cyc= util= cum= busy=<lane-cyc>/<capacity> lane-cyc grp_max= grp_min=
#   [FPUG] pre|bench   cyc= denom= busy= <per group, comma separated>
#   [FPU FINAL]        busy=X of Y lane-cycles over N benchmark cycles -> util=Z%
#   [DMAP]             cyc= busy= <per group> r= <per group, 64 B beats>
#   [EOC]              the exit code
# Derived, not measured like the RTL's (stated in the [GVSOC] header line):
#   * FPU lane-cycles = vf* elements / 2 (fp16: two elements per FPU lane per cycle; --epl);
#   * [DMAP]: each transfer's bytes spread evenly over its life and over the groups (the L1
#     interleave puts a long transfer on every group alike); busy = cycles a transfer was live.
# The RTL's NoC / MSHR micro-architecture probes ([BP], [LP], [NPP*], [MSHRG], [STALLG], ...)
# have no GVSoC counterpart; the model's own MSHR / barrier statistics are kept as they are
# (mshr_stats.log, gbar_stats.log in the run directory).
#
# Bench window: "[PROJ] ... t0=<start> cycles=<n>" (decimal, or hex in "[PROJ] min") from the
# program (qwen-proj), else --bench,
# else the whole run.
import argparse
import re
import sys
from collections import defaultdict

MESH = {"4x4": (256, 16, 4), "8x8": (1024, 64, 8)}  # cores, groups, groups per mesh column
LANES = 4  # FPU lanes per core (the RTL's [FPU] capacity unit)
BEAT = 64
TRACE = re.compile(r"^\s*\d+: +\d+: \[")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mesh", required=True, choices=sorted(MESH))
    ap.add_argument("--log", required=True)
    ap.add_argument("--fpu")
    ap.add_argument("--dma")
    ap.add_argument("--bench", help="START:CYCLES (default: from the [PROJ] line)")
    ap.add_argument("--period", type=int, default=1000)
    ap.add_argument("--epl", type=float, default=2.0, help="vf* elements per FPU lane-cycle")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    cores, groups, ny = MESH[a.mesh]
    cpg = cores // groups
    per = a.period
    out = []

    # ---- program output ------------------------------------------------------------------------
    bench = None
    eoc = None
    uart = []
    with open(a.log, errors="replace") as f:
        for ln in f:
            ln = ln.rstrip("\n")
            m = re.search(r"EOC register return value: (0x[0-9a-fA-F]+)", ln)
            if m:
                eoc = int(m.group(1), 16)
                continue
            if TRACE.match(ln) or ln.startswith("Input error") or ln.startswith("Traceback"):
                continue
            uart.append(ln)
            m = re.search(r"^\[PROJ\] shape=.* t0=(\d+) cycles=(\d+)", ln)
            if m:
                bench = (int(m.group(1)), int(m.group(2)))
            m = re.search(r"^\[PROJ\] min .* t0=([0-9a-f]+) cycles=([0-9a-f]+)", ln)  # hex
            if m:
                bench = (int(m.group(1), 16), int(m.group(2), 16))
    if a.bench:
        s, n = a.bench.split(":")
        bench = (int(s), int(n))

    out.append("[GVSOC] transcript converted by qwen-common/script/gvsoc_probes.py from %s; mesh %s, "
               "%d-cycle windows; FPU lane-cycles = vf* elements / %g; [DMAP] r= derived from the DMA "
               "transfer log (bytes spread over each transfer's life and over the groups); bench=%s"
               % (a.log, a.mesh, per, a.epl, "%d:%d" % bench if bench else "whole run"))
    out.extend("[UART] " + u for u in uart)

    def in_bench(w):  # window w covers [w*per, (w+1)*per)
        if not bench:
            return True
        return (w + 1) * per > bench[0] and w * per < bench[0] + bench[1]

    # ---- FPU ------------------------------------------------------------------------------------
    if a.fpu:
        grp = defaultdict(lambda: [0] * groups)  # window -> per-group elements
        rx = re.compile(r"group_(\d+)_(\d+)/.* win=(\d+) cyc=\d+ elems=(\d+)")
        with open(a.fpu, errors="replace") as f:
            for ln in f:
                m = rx.search(ln)
                if m:
                    i, j, w, e = (int(x) for x in m.groups())
                    grp[w][i * ny + j] += e
        if grp:
            cap_g = cpg * LANES * per
            cap = cores * LANES * per
            cum_b = cum_c = 0
            fin_b = fin_w = 0
            for w in range(min(grp), max(grp) + 1):
                g = [int(round(x / a.epl)) for x in grp.get(w, [0] * groups)]
                busy = sum(g)
                cum_b += busy
                cum_c += cap
                kind = "bench" if in_bench(w) else "pre"
                if kind == "bench":
                    fin_b += busy
                    fin_w += 1
                gmax = max(range(groups), key=lambda k: g[k])
                gmin = min(range(groups), key=lambda k: g[k])
                cyc = (w + 1) * per
                out.append("[FPU] %s cyc=%d util=%.2f%% cum=%.2f%% busy=%d/%d lane-cyc  "
                           "grp_max=%.1f%%(g%d) grp_min=%.1f%%(g%d)"
                           % (kind, cyc, 100.0 * busy / cap, 100.0 * cum_b / cum_c, busy, cap,
                              100.0 * g[gmax] / cap_g, gmax, 100.0 * g[gmin] / cap_g, gmin))
                out.append("[FPUG] %s cyc=%d denom=%d busy= %s" % (kind, cyc, cap_g,
                                                                   ",".join(str(x) for x in g)))
            n = bench[1] if bench else fin_w * per
            tot = cores * LANES * n
            out.append("[FPU FINAL] busy=%d of %d lane-cycles over %d benchmark cycles -> util=%.2f%%  "
                       "(%d lanes = %d cores x %d FPU)" % (fin_b, tot, n, 100.0 * fin_b / max(tot, 1),
                                                          cores * LANES, cores, LANES))

    # ---- DMA ------------------------------------------------------------------------------------
    if a.dma:
        beats = defaultdict(float)
        live = defaultdict(int)
        with open(a.dma, errors="replace") as f:
            next(f, None)
            for ln in f:
                p = ln.strip().split(",")
                if len(p) < 7:
                    continue
                nbytes, t0, t1 = int(p[3]), int(p[4]), int(p[5])
                t1 = max(t1, t0 + 1)
                rate = nbytes / float(BEAT) / (t1 - t0)
                for w in range(t0 // per, (t1 - 1) // per + 1):
                    lo, hi = max(t0, w * per), min(t1, (w + 1) * per)
                    if hi > lo:
                        beats[w] += rate * (hi - lo)
                        live[w] += hi - lo
        for w in sorted(beats):
            r = int(round(beats[w] / groups))
            b = min(live[w], per)
            out.append("[DMAP] cyc=%d busy= %s r= %s" % ((w + 1) * per, ",".join([str(b)] * groups),
                                                         ",".join([str(r)] * groups)))

    if eoc is not None:
        out.append("[EOC] Simulation ended on GVSoC (retval = %d)." % eoc)
    with open(a.out, "w") as f:
        f.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
