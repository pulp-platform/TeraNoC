#!/usr/bin/env python3
"""Generate detailed per-link per-timeslice load balance report.

Shows traffic on all 32 individual links (16 tiles × 2 ports) for each
node pair direction, for both WideReq and Resp, per timeslice.

Usage:
    python3 gen_link_detail_report.py <trace_csv> [options]

Example:
    python3 gen_link_detail_report.py build_link_debug/v4m_out/trace_events.csv \
        --W 2 --H 2 --tiles-per-group 16 --wide-req-ch 2 --resp-ch 2 \
        --slice-cycles 1000 --start-cycle 6000 --end-cycle 22000 \
        -o link_report.txt
"""

import argparse, csv, sys
from collections import defaultdict

def main():
    ap = argparse.ArgumentParser(description="Per-link per-timeslice load balance report")
    ap.add_argument("csv", help="V4M trace CSV")
    ap.add_argument("--W", type=int, required=True, help="Mesh width")
    ap.add_argument("--H", type=int, required=True, help="Mesh height")
    ap.add_argument("--tiles-per-group", type=int, default=16)
    ap.add_argument("--narrow-req-ch", type=int, default=0)
    ap.add_argument("--wide-req-ch", type=int, default=2)
    ap.add_argument("--resp-ch", type=int, default=2)
    ap.add_argument("--slice-cycles", type=int, default=1000)
    ap.add_argument("--start-cycle", type=int, default=0)
    ap.add_argument("--end-cycle", type=int, default=0, help="0 = to end")
    ap.add_argument("-o", "--output", default=None, help="Output file (default: stdout)")
    ap.add_argument("--node-pair", default=None,
                    help="Filter to specific node pair, e.g. '0-1' for G0->G1")
    args = ap.parse_args()

    T = args.tiles_per_group
    narrow_end = args.narrow_req_ch * T
    wide_end = narrow_end + args.wide_req_ch * T
    resp_start = wide_end
    resp_end = resp_start + args.resp_ch * T

    counts = defaultdict(int)
    with open(args.csv) as f:
        cr = csv.DictReader(f)
        for r in cr:
            try:
                cycle = int(r["slice"])
                src, dst = int(r["edge_src"]), int(r["edge_dst"])
                ch, fl = int(r["ch"]), int(r["flits"])
            except:
                continue
            if args.start_cycle > 0 and cycle < args.start_cycle:
                continue
            if args.end_cycle > 0 and cycle > args.end_cycle:
                continue
            ts = cycle // args.slice_cycles
            counts[(ts, src, dst, ch)] += fl

    if not counts:
        print("No data found", file=sys.stderr)
        return

    all_ts = sorted(set(t for (t, s, d, c) in counts))
    pairs = sorted(set((s, d) for (t, s, d, c) in counts))

    if args.node_pair:
        a, b = args.node_pair.split("-")
        pairs = [(int(a), int(b))]

    out = open(args.output, "w") if args.output else sys.stdout

    out.write(f"Per-link load balance report\n")
    out.write(f"Config: {args.W}x{args.H} mesh, {T} tiles/group\n")
    out.write(f"Channels: NarrowReq [0,{narrow_end}), WideReq [{narrow_end},{wide_end}), "
              f"Resp [{resp_start},{resp_end})\n")
    out.write(f"Period: {args.slice_cycles} cycles\n\n")

    for (src, dst) in pairs:
        link_types = []
        if args.narrow_req_ch > 0:
            link_types.append(("NarrowReq", 0, args.narrow_req_ch))
        if args.wide_req_ch > 0:
            link_types.append(("WideReq", narrow_end, args.wide_req_ch))
        link_types.append(("Resp", resp_start, args.resp_ch))

        for label, ch_base, ch_per_tile in link_types:
            n_links = T * ch_per_tile
            out.write(f"=== G{src}->G{dst} {label}: {n_links} links "
                      f"({T} tiles x {ch_per_tile} ports) ===\n")

            # Header
            hdr = f"{'Period':>11}"
            for t in range(T):
                for p in range(ch_per_tile):
                    hdr += f"  T{t:02d}p{p}"
            hdr += "   TOTAL"
            for p in range(ch_per_tile):
                hdr += f" p{p}"
            hdr += " balance\n"
            out.write(hdr)

            for ts in all_ts:
                cyc = f"{ts*args.slice_cycles}-{(ts+1)*args.slice_cycles}"
                port_sums = [0] * ch_per_tile
                line = f"{cyc:>11}"
                for t in range(T):
                    for p in range(ch_per_tile):
                        ch = ch_base + t * ch_per_tile + p
                        v = counts.get((ts, src, dst, ch), 0)
                        port_sums[p] += v
                        line += f"  {v:>5}"
                total = sum(port_sums)
                if total == 0:
                    continue
                line += f"  {total:>5}"
                for p in range(ch_per_tile):
                    line += f" {port_sums[p]:>5}"
                pcts = [port_sums[p] * 100 // max(total, 1) for p in range(ch_per_tile)]
                line += " " + "/".join(f"{p}%" for p in pcts)
                out.write(line + "\n")

            out.write("\n")
        out.write("\n")

    if args.output:
        out.close()
        print(f"Report saved to {args.output}")

if __name__ == "__main__":
    main()
