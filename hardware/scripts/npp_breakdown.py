#!/usr/bin/env python3
"""Bandwidth / latency breakdown of the remote TCDM path from tb_noc_path_probe.svh.

usage: npp_breakdown.py <transcript-or-filtered-log> [more logs ...] [--min-wpc 0.3]

Averages the [NPP]/[NPPL]/[NPPX] periods whose [LDP] per-core delivery is at least --min-wpc
(the streaming phase; barriers and the epilogue dilute everything else) and prints, per log:
  * each tap point: words/cycle machine-wide, per-port utilisation mean / max, stall per port-cycle
    and per handshake;
  * each segment's mean read latency (Little's law) and its share of the NoC round trip, next to
    the core-side latency from [LDP] (ROB occupancy / delivery);
  * the two local crossbars: conflict share and stall share of valid inputs.
Several logs print side by side on the latency table for A/B comparison.
"""
import re
import sys
from collections import defaultdict

PTS = ["MIN", "MOUT", "RINJ", "REJ", "SIN", "SOUT", "PINJ", "PEJ", "PLANE", "MRSP", "MRO"]
SEGS = ["MOUT_RINJ", "RINJ_REJ", "REJ_SIN", "SIN_SOUT", "SOUT_PINJ", "PINJ_PEJ", "PEJ_PLANE",
        "PLANE_MRSP"]
SEG_DESC = {
    "MOUT_RINJ": "src: req remap -> router",
    "RINJ_REJ": "req mesh",
    "REJ_SIN": "dst: req xbar -> tile",
    "SIN_SOUT": "tile: bank + burst serialise",
    "SOUT_PINJ": "tile resp -> resp remap -> router",
    "PINJ_PEJ": "resp mesh",
    "PEJ_PLANE": "local resp FIFO",
    "PLANE_MRSP": "local resp xbar -> MSHR",
}


def kv(line):
    out = {}
    for k, v in re.findall(r"(\w+)=\s*([^\s]+)", line):
        out[k] = v
    return out


def load(path, min_wpc):
    ldp, npp, nppl, nppx = {}, defaultdict(dict), {}, defaultdict(dict)
    with open(path, errors="replace") as f:
        for ln in f:
            if ln.startswith("# "):
                ln = ln[2:]
            if ln.startswith("[LDP]"):
                d = kv(ln)
                try:
                    ldp[int(d["cyc"])] = (float(d["rsp_wpc_core"]), float(d["occ_words_core"]),
                                          float(d["lat"]))
                except (KeyError, ValueError):
                    pass
            elif ln.startswith("[NPP] "):
                d = kv(ln)
                try:
                    c = int(d["cyc"])
                    npp[c][d["pt"]] = d
                except (KeyError, ValueError):
                    pass
            elif ln.startswith("[NPPL]"):
                d = kv(ln)
                try:
                    nppl[int(d["cyc"])] = d
                except (KeyError, ValueError):
                    pass
            elif ln.startswith("[NPPX]"):
                d = kv(ln)
                try:
                    nppx[int(d["cyc"])][d["xbar"]] = d
                except (KeyError, ValueError):
                    pass
    cyc = sorted(c for c in nppl if c in ldp and ldp[c][0] >= min_wpc)
    return ldp, npp, nppl, nppx, cyc


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else float("nan")


def report(path, min_wpc):
    ldp, npp, nppl, nppx, cyc = load(path, min_wpc)
    print(f"\n=== {path}")
    if not cyc:
        print(f"  no [NPPL] period with [LDP] delivery >= {min_wpc} (probe compiled in?)")
        return None
    e2e_rate = mean(ldp[c][0] for c in cyc)
    e2e_occ = mean(ldp[c][1] for c in cyc)
    e2e_lat = mean(ldp[c][2] for c in cyc)
    print(f"  periods={len(cyc)}  core: delivery={e2e_rate:.3f} w/c/core  "
          f"in flight={e2e_occ:.1f} words  latency={e2e_lat:.0f} cyc")
    print(f"  {'point':6} {'w/c':>7} {'rd w/c':>7} {'ports':>5} {'util':>6} {'umax':>6} "
          f"{'hot':>9} {'stall/pc':>8} {'stall/hs':>8}")
    for p in PTS:
        rows = [npp[c][p] for c in cyc if p in npp[c]]
        if not rows:
            continue
        g = lambda k: mean(float(r[k]) for r in rows)
        hot = rows[-1]["umax"].split("@")[1] if "@" in rows[-1]["umax"] else ""
        print(f"  {p:6} {g('wpc'):7.2f} {g('rd_wpc'):7.2f} {rows[0]['ports']:>5} {g('util'):6.3f} "
              f"{mean(float(r['umax'].split('@')[0]) for r in rows):6.3f} {hot:>9} "
              f"{g('stall_pc'):8.3f} {g('stall_ph'):8.2f}")
    lat = {s: mean(float(nppl[c][s]) for c in cyc) for s in SEGS}
    net = sum(lat.values())
    print(f"  {'segment':12} {'cyc':>6} {'share':>6}  what")
    for s in SEGS:
        print(f"  {s:12} {lat[s]:6.1f} {100 * lat[s] / net if net else 0:5.1f}%  {SEG_DESC[s]}")
    merge = mean(float(nppl[c]["merge"]) for c in cyc)
    mcast = mean(float(nppl[c]["mcast"]) for c in cyc)
    drift = [int(nppl[c]["drift"]) for c in cyc]
    print(f"  NoC round trip (MOUT->MRSP) {net:.1f} cyc; core latency {e2e_lat:.0f} cyc -> "
          f"outside the NoC (MSHR + tile + core) {e2e_lat - net:.1f} cyc")
    print(f"  merge MIN/MOUT={merge:.2f}  multicast MRO/MRSP={mcast:.2f}  "
          f"drift min/max={min(drift)}/{max(drift)}")
    for x in ("req", "resp"):
        rows = [nppx[c][x] for c in cyc if x in nppx[c]]
        if rows:
            g = lambda k: mean(float(r[k]) for r in rows)
            print(f"  xbar {x:4}: valid in/cyc/group={g('in_pc'):.2f} conflict={g('conflict'):.3f} "
                  f"stall={g('stall'):.3f} out/cyc/group={g('out_pc'):.2f} (lanes {rows[0]['lanes']})")
    return dict(e2e_rate=e2e_rate, e2e_lat=e2e_lat, net=net, lat=lat)


def main():
    args = sys.argv[1:]
    min_wpc = 0.3
    if "--min-wpc" in args:
        i = args.index("--min-wpc")
        min_wpc = float(args[i + 1])
        del args[i:i + 2]
    res = {p: report(p, min_wpc) for p in args}
    res = {p: r for p, r in res.items() if r}
    if len(res) > 1:
        names = list(res)
        print("\n=== latency side by side (cycles)")
        print(f"  {'segment':12}" + "".join(f" {n.split('/')[-1][:14]:>14}" for n in names))
        for s in SEGS + ["net", "e2e_lat", "e2e_rate"]:
            vals = [res[n]["lat"][s] if s in SEGS else res[n][s] for n in names]
            print(f"  {s:12}" + "".join(f" {v:14.3f}" if s == "e2e_rate" else f" {v:14.1f}"
                                        for v in vals))


if __name__ == "__main__":
    main()
