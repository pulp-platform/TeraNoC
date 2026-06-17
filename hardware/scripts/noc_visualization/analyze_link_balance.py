#!/usr/bin/env python3
"""Analyze per-link per-timeslice load balance from the V4M trace CSV.

For each node pair (group→group), shows the traffic on all 32 req and 32 resp
router channels per timeslice. Flags timeslices where the balance is poor.

Usage:
    python3 analyze_link_balance.py <trace_csv> --W 2 --H 2 \
        --tiles-per-group 16 --wide-req-ch 2 --resp-ch 2 \
        --slice-cycles 1000 [--start-cycle N] [--end-cycle N]
"""

import argparse, csv, sys
from collections import defaultdict

def main():
    ap = argparse.ArgumentParser(description="Analyze NoC link balance per timeslice")
    ap.add_argument("csv", help="V4M trace CSV")
    ap.add_argument("--W", type=int, required=True, help="Mesh width")
    ap.add_argument("--H", type=int, required=True, help="Mesh height")
    ap.add_argument("--tiles-per-group", type=int, default=16)
    ap.add_argument("--narrow-req-ch", type=int, default=0)
    ap.add_argument("--wide-req-ch", type=int, default=2)
    ap.add_argument("--resp-ch", type=int, default=2)
    ap.add_argument("--slice-cycles", type=int, default=1000,
                    help="Aggregate into timeslices of this many cycles")
    ap.add_argument("--start-cycle", type=int, default=0,
                    help="Only analyze from this cycle (0=from start)")
    ap.add_argument("--end-cycle", type=int, default=0,
                    help="Only analyze up to this cycle (0=to end)")
    ap.add_argument("--threshold", type=float, default=60.0,
                    help="Flag timeslices where any port exceeds this %% (default 60)")
    ap.add_argument("--summary-only", action="store_true",
                    help="Only print flagged (imbalanced) timeslices")
    args = ap.parse_args()

    T = args.tiles_per_group
    narrow_end = args.narrow_req_ch * T
    wide_end = narrow_end + args.wide_req_ch * T
    num_channels = (args.narrow_req_ch + args.wide_req_ch + args.resp_ch) * T
    num_groups = args.W * args.H
    slice_cycles = args.slice_cycles

    # Classify channels
    def ch_type(ch):
        if ch < narrow_end:
            return "NarrowReq"
        elif ch < wide_end:
            return "WideReq"
        else:
            return "Resp"

    def ch_port(ch):
        """Which port (0 or 1) within the channel type for this tile"""
        if ch < narrow_end:
            return ch % args.narrow_req_ch if args.narrow_req_ch > 0 else 0
        elif ch < wide_end:
            return (ch - narrow_end) % args.wide_req_ch
        else:
            return (ch - wide_end) % args.resp_ch

    # Read CSV and bin into timeslices
    # Key: (timeslice, edge_src, edge_dst, channel_type, port) → count
    data = defaultdict(int)
    max_slice = 0
    min_slice = 999999999

    with open(args.csv) as f:
        cr = csv.DictReader(f)
        for r in cr:
            try:
                orig_slice = int(r["slice"])
                src = int(r["edge_src"])
                dst = int(r["edge_dst"])
                ch = int(r["ch"])
                flits = int(r["flits"])
            except (ValueError, KeyError):
                continue

            # Convert original slice to our timeslice
            cycle = orig_slice  # slice in CSV is already in cycles if V4M_SLICE_CYCLES=1
            if args.start_cycle > 0 and cycle < args.start_cycle:
                continue
            if args.end_cycle > 0 and cycle > args.end_cycle:
                continue

            ts = cycle // slice_cycles
            ct = ch_type(ch)
            port = ch_port(ch)

            data[(ts, src, dst, ct, port)] += flits
            max_slice = max(max_slice, ts)
            min_slice = min(min_slice, ts)

    if not data:
        print("No data found in CSV (check --start-cycle/--end-cycle)")
        return

    print(f"Trace spans timeslices {min_slice}..{max_slice} ({slice_cycles} cycles each)")
    print(f"Channels: NarrowReq [0,{narrow_end}), WideReq [{narrow_end},{wide_end}), Resp [{wide_end},{num_channels})")
    print(f"Node pairs: {num_groups} groups in {args.W}x{args.H} mesh")
    print()

    # For each timeslice, for each node pair, print req p0/p1 and resp p0/p1
    # Collect all node pairs seen
    pairs = set()
    for (ts, src, dst, ct, port) in data:
        pairs.add((src, dst))
    pairs = sorted(pairs)

    flagged = 0
    total_slices = 0

    for ts in range(min_slice, max_slice + 1):
        # Check if this timeslice has any traffic
        ts_total = sum(v for (t, s, d, c, p), v in data.items() if t == ts)
        if ts_total == 0:
            continue
        total_slices += 1

        lines = []
        is_flagged = False

        for (src, dst) in pairs:
            # WideReq port balance
            wr0 = data.get((ts, src, dst, "WideReq", 0), 0)
            wr1 = data.get((ts, src, dst, "WideReq", 1), 0)
            wr_total = wr0 + wr1
            wr_pct = 100.0 * wr0 / wr_total if wr_total > 0 else 50.0

            # Resp port balance
            rp0 = data.get((ts, src, dst, "Resp", 0), 0)
            rp1 = data.get((ts, src, dst, "Resp", 1), 0)
            rp_total = rp0 + rp1
            rp_pct = 100.0 * rp0 / rp_total if rp_total > 0 else 50.0

            # NarrowReq (if any)
            nr0 = data.get((ts, src, dst, "NarrowReq", 0), 0)
            nr1 = data.get((ts, src, dst, "NarrowReq", 1), 0)

            flag = ""
            if wr_total > 10 and (wr_pct > args.threshold or wr_pct < (100-args.threshold)):
                flag = " *** REQ IMBALANCE"
                is_flagged = True
            if rp_total > 10 and (rp_pct > args.threshold or rp_pct < (100-args.threshold)):
                flag += " *** RESP IMBALANCE"
                is_flagged = True

            lines.append(
                f"  G{src}→G{dst}: WideReq={wr0}/{wr1}({wr_pct:.0f}%) "
                f"Resp={rp0}/{rp1}({rp_pct:.0f}%)"
                f"{' NarrowReq=' + str(nr0) + '/' + str(nr1) if (nr0+nr1) > 0 else ''}"
                f"{flag}")

        if is_flagged:
            flagged += 1

        if not args.summary_only or is_flagged:
            cycle_start = ts * slice_cycles
            cycle_end = (ts + 1) * slice_cycles
            marker = " <<<IMBALANCED>>>" if is_flagged else ""
            print(f"[Slice {ts}] cycles {cycle_start}-{cycle_end} (total={ts_total}){marker}")
            for line in lines:
                print(line)
            print()

    print(f"=== Summary: {flagged}/{total_slices} timeslices flagged "
          f"(>{args.threshold:.0f}% imbalance on any link pair) ===")

if __name__ == "__main__":
    main()
