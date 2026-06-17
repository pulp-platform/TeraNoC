#!/usr/bin/env python3
"""
analyze_noc_trace.py — analyze the per-flit NoC event trace produced by
hardware/tb/tb_noc_req_resp_tracer.svh (noc_trace/events.csv).

A remote TCDM transaction carries a stable identity (owner_group, owner_tile,
core_id, meta_id) at every observation point, so this script stitches each
transaction's life across layers and reports:

  * FUNCTIONAL  — incomplete transactions (issued at the core, never completed),
                  bucketed by the LAST stage they reached  ->  where it died.
  * LATENCY     — req->resp turnaround for completed transactions.
  * CONGESTION  — busiest observation points / mesh links.
  * --focus     — the full ordered event list of one transaction (debug a hang).

Usage:
  analyze_noc_trace.py [events.csv]                     # full report
  analyze_noc_trace.py --focus G,T,CORE,MID             # one transaction
  analyze_noc_trace.py --addr 0x52c08                   # all txns to an address
  analyze_noc_trace.py --incomplete --top 40            # only the stuck ones
  analyze_noc_trace.py --owner G,T                      # filter to one core/tile

Pure stdlib (csv); no pandas required.
"""

import argparse
import csv
import os
import sys
from collections import defaultdict, Counter

# Logical pipeline order of the stages a remote load passes through.
# Request side then response side; the per-hop RTR_* stages are placed at the
# point in the pipeline where they occur.
STAGE_ORDER = {
    "CORE_REQ":      0,
    "MSHR_REQ_IN":   1,
    "MSHR_REQ_OUT":  2,
    "RTR_REQ":       3,   # one or more mesh hops (req side)
    "SLAVE_REQ_IN":  4,
    "SLAVE_RSP_OUT": 5,
    "RTR_RSP":       6,   # one or more mesh hops (resp side)
    "MSHR_RSP_IN":   7,
    "MSHR_RSP_OUT":  8,
    "CORE_RSP":      9,
}
REQ_STAGES  = {"CORE_REQ", "MSHR_REQ_IN", "MSHR_REQ_OUT", "RTR_REQ", "SLAVE_REQ_IN"}
RESP_STAGES = {"SLAVE_RSP_OUT", "RTR_RSP", "MSHR_RSP_IN", "MSHR_RSP_OUT", "CORE_RSP"}

META_MOD = 32  # meta_id wraps at 2^MetaIdWidth (=32 for Spatz RobDepth=32)


def stage_rank(stage):
    return STAGE_ORDER.get(stage, -1)


class Txn:
    """One remote transaction (possibly a burst owning several meta_ids)."""
    __slots__ = ("og", "ot", "core", "base_mid", "burst", "mids",
                 "addr", "tgt_g", "tgt_t", "tgt_bank", "wen",
                 "events", "stage_first", "beats_resp", "req_cyc")

    def __init__(self, row):
        self.og   = row["og"]
        self.ot   = row["ot"]
        self.core = row["core"]
        self.base_mid = row["mid"]
        self.burst = max(1, row["burst"])
        self.mids = {(self.base_mid + i) % META_MOD for i in range(self.burst)}
        self.addr = row["addr"]
        self.tgt_g = row["tgt_g"]
        self.tgt_t = row["tgt_t"]
        self.tgt_bank = row["tgt_bank"]
        self.wen = row["wen"]
        self.events = [row]
        self.stage_first = {row["stage"]: row["time_ns"]}
        self.beats_resp = 0
        self.req_cyc = row["cyc"]

    def add(self, row):
        self.events.append(row)
        st = row["stage"]
        if st not in self.stage_first:
            self.stage_first[st] = row["time_ns"]
        if st == "CORE_RSP":
            self.beats_resp += 1

    @property
    def complete(self):
        return self.beats_resp >= self.burst

    @property
    def last_stage(self):
        return max(self.stage_first, key=stage_rank)

    @property
    def merged(self):
        # a follower absorbed by MSHR merge never goes to the NoC/slave
        for ev in self.events:
            if ev["stage"] == "MSHR_REQ_IN" and ev["flags"] == "merge":
                return True
        return False

    @property
    def last_cyc(self):
        return max(ev["cyc"] for ev in self.events)

    def latency(self):
        if not self.complete:
            return None
        last_rsp = max(ev["cyc"] for ev in self.events if ev["stage"] == "CORE_RSP")
        return last_rsp - self.req_cyc

    def key(self):
        return (self.og, self.ot, self.core, self.base_mid)


def load_rows(path):
    intf = ("time_ns", "cyc", "loc_g", "loc_t", "loc_p", "og", "ot", "core",
            "mid", "tgt_g", "tgt_t", "tgt_bank", "wen", "burst", "amo",
            "mshr", "sub")
    with open(path, newline="") as f:
        rdr = csv.DictReader(f)
        for r in rdr:
            try:
                for k in intf:
                    r[k] = int(r[k])
                r["addr"] = int(r["addr"], 16)
                r["data"] = int(r["data"], 16)
            except (ValueError, KeyError):
                continue
            yield r


def build_transactions(rows):
    """Segment rows into transactions per (og,ot,core) lane.

    A CORE_REQ opens a transaction owning meta_ids [base, base+burst). Subsequent
    rows whose mid falls in an open transaction's mid-set attach to it; a burst
    closes once `burst` CORE_RSP beats are seen. Returns (txns, orphan_rows).
    """
    lanes = defaultdict(list)
    for r in rows:
        lanes[(r["og"], r["ot"], r["core"])].append(r)

    txns = []
    orphans = []
    for lane, lr in lanes.items():
        lr.sort(key=lambda r: (r["time_ns"], stage_rank(r["stage"])))
        open_txns = []  # most-recent-first
        for r in lr:
            st = r["stage"]
            if st == "CORE_REQ":
                t = Txn(r)
                open_txns.insert(0, t)
                txns.append(t)
                # cap: keep at most a handful of open txns per lane
                if len(open_txns) > 8:
                    open_txns.pop()
                continue
            # attach to the newest open txn that owns this mid
            placed = False
            for t in open_txns:
                if r["mid"] in t.mids:
                    t.add(r)
                    if st == "CORE_RSP" and t.complete:
                        open_txns.remove(t)
                    placed = True
                    break
            if not placed:
                orphans.append(r)
    return txns, orphans


def fmt_owner(t):
    return f"g{t.og}/t{t.ot}/c{t.core}/id{t.base_mid}"


def report_summary(txns, orphans, max_cyc, stuck_gap):
    total = len(txns)
    complete = [t for t in txns if t.complete]
    incomplete = [t for t in txns if not t.complete]
    merged = sum(1 for t in txns if t.merged)
    # Discriminate GENUINELY FROZEN (no progress for >stuck_gap cyc before the
    # trace cutoff) from transactions merely IN-FLIGHT at the window end.
    stuck_thresh = max_cyc - stuck_gap
    frozen   = [t for t in incomplete if t.last_cyc < stuck_thresh]
    inflight = [t for t in incomplete if t.last_cyc >= stuck_thresh]
    print("=" * 78)
    print("NoC transaction summary")
    print("=" * 78)
    print(f"  transactions (CORE_REQ seen) : {total}")
    print(f"  completed (CORE_RSP)         : {len(complete)}")
    print(f"  incomplete                   : {len(incomplete)}")
    print(f"    -> FROZEN (no progress for >{stuck_gap} cyc, last<cyc{stuck_thresh}): {len(frozen)}")
    print(f"    -> in-flight at cutoff (cyc{max_cyc})                  : {len(inflight)}")
    print(f"  merged-followers (MSHR)      : {merged}")
    print(f"  orphan rows (no owning REQ)  : {len(orphans)}")
    print()

    if frozen:
        print("-" * 78)
        print(f"FROZEN transactions bucketed by LAST stage reached (== the deadlock)")
        print("-" * 78)
        buckets = Counter(t.last_stage for t in frozen)
        for stage in sorted(buckets, key=stage_rank):
            print(f"  {stage:<14} {buckets[stage]:>6}   "
                  f"(frozen — never entered the NEXT stage)")
        print()
        # group frozen by (owner group) to see the spatial epicentre
        by_g = Counter(t.og for t in frozen)
        print("  frozen transactions by OWNER group:")
        for g, c in by_g.most_common():
            print(f"    g{g:<2} : {c}")
        print()
        # earliest-frozen example per bucket — the deadlock roots
        print("  earliest-issued FROZEN txn per stage-bucket (deadlock roots):")
        by_bucket = defaultdict(list)
        for t in frozen:
            by_bucket[t.last_stage].append(t)
        for stage in sorted(by_bucket, key=stage_rank):
            ex = min(by_bucket[stage], key=lambda t: t.req_cyc)
            print(f"    [{stage:<13}] {fmt_owner(ex):<22} "
                  f"req@cyc{ex.req_cyc} last@cyc{ex.last_cyc} addr=0x{ex.addr:05x} "
                  f"-> tgt g{ex.tgt_g}/t{ex.tgt_t}/b{ex.tgt_bank} "
                  f"({'wr' if ex.wen else 'rd'}, burst={ex.burst})")
        print()
    return frozen


def report_routes(frozen, top):
    """Map the gridlock geometry: which inter-group routes are jammed, split by
    the stage the transaction froze at. og = requester group; tgt_g = target
    group (req side) / for resp the route is slave-group(loc_g) -> requester(og)."""
    NY = 4  # group grid is NumX x NumY = 4 x 4 for terapool
    def xy(g):
        return (g // NY, g % NY)
    req_routes = Counter()   # requests stuck in the req mesh (og -> tgt)
    rsp_routes = Counter()   # responses stuck in the resp mesh (slave -> og)
    slave_stall = Counter()  # reached slave, never answered (which slave group)
    for t in frozen:
        st = t.last_stage
        if st in ("MSHR_REQ_OUT", "SLAVE_REQ_IN"):
            # request injected but never delivered: route og -> tgt_g
            if t.tgt_g >= 0:
                req_routes[(t.og, t.tgt_g)] += 1
            if st == "SLAVE_REQ_IN":
                slave_stall[t.tgt_g] += 1
        elif st in ("SLAVE_RSP_OUT", "MSHR_RSP_IN"):
            # response injected (at the slave = tgt_g) but never delivered to og
            if t.tgt_g >= 0:
                rsp_routes[(t.tgt_g, t.og)] += 1
    print("-" * 78)
    print("GRIDLOCK GEOMETRY — frozen REQUEST routes  src_g -> tgt_g  "
          "(req injected, never delivered)")
    print("-" * 78)
    for (s, d), c in req_routes.most_common(top):
        print(f"  g{s:<2}{str(xy(s)):>7} -> g{d:<2}{str(xy(d)):>7} : {c}")
    print()
    print("-" * 78)
    print("GRIDLOCK GEOMETRY — frozen RESPONSE routes  slave_g -> req_g  "
          "(resp injected, never delivered)")
    print("-" * 78)
    for (s, d), c in rsp_routes.most_common(top):
        print(f"  g{s:<2}{str(xy(s)):>7} -> g{d:<2}{str(xy(d)):>7} : {c}")
    print()
    # net imbalance per group: is a group a sink (reqs pile up heading in) or
    # source of stuck traffic?
    indeg = Counter(); outdeg = Counter()
    for (s, d), c in list(req_routes.items()) + list(rsp_routes.items()):
        outdeg[s] += c; indeg[d] += c
    print("frozen-flit imbalance per group (in=dst of stuck flits, out=src):")
    for g in range(16):
        print(f"    g{g:<2}{str(xy(g)):>7}  in={indeg[g]:<5} out={outdeg[g]:<5} "
              f"net_in={indeg[g]-outdeg[g]}")
    print()

    # ---- hop-level deadlock front (only present with TRACER_TRACE_HOPS) ----
    DIRS = {0: "N", 1: "E", 2: "S", 3: "W"}
    front = Counter()       # last successful hop of mesh-stuck frozen flits
    for t in frozen:
        if t.last_stage in ("RTR_REQ", "RTR_RSP"):
            rtr = [e for e in t.events if e["stage"] in ("RTR_REQ", "RTR_RSP")]
            if rtr:
                le = max(rtr, key=lambda e: e["cyc"])
                front[(le["stage"], le["loc_g"], le["loc_t"], le["sub"])] += 1
    if front:
        print("-" * 78)
        print("DEADLOCK FRONT — last successful hop of mesh-frozen flits "
              "(router that could not forward to the NEXT hop)")
        print("-" * 78)
        for (st, g, t, d), c in front.most_common(top):
            print(f"  {st:<8} @ g{g:<2}{str(xy(g)):>7} tile{t:<2} out-dir={DIRS.get(d, d)} "
                  f": {c}  -> jammed link toward "
                  f"{('North' if d==0 else 'East' if d==1 else 'South' if d==2 else 'West')}")
        print()


def report_latency(txns):
    lats = [t.latency() for t in txns if t.complete and t.latency() is not None]
    lats = [l for l in lats if l >= 0]
    if not lats:
        print("  (no completed transactions for latency stats)\n")
        return
    lats.sort()
    n = len(lats)
    mean = sum(lats) / n
    print("-" * 78)
    print("LATENCY (CORE_REQ -> last CORE_RSP, cycles) over "
          f"{n} completed transactions")
    print("-" * 78)
    print(f"  min={lats[0]}  p50={lats[n//2]}  mean={mean:.1f}  "
          f"p95={lats[min(n-1, int(0.95*n))]}  max={lats[-1]}")
    print()


def report_congestion(rows_path, top):
    # one streaming pass for per-point event counts (keeps memory low)
    point = Counter()
    link = Counter()
    stage_count = Counter()
    for r in load_rows(rows_path):
        st = r["stage"]
        stage_count[st] += 1
        point[(r["loc_g"], r["loc_t"], r["loc_p"], st)] += 1
        if st in ("RTR_REQ", "RTR_RSP"):
            link[(r["loc_g"], r["loc_t"], r["sub"], st)] += 1
    print("-" * 78)
    print("EVENT COUNTS per stage")
    print("-" * 78)
    for st in sorted(stage_count, key=stage_rank):
        print(f"  {st:<14} {stage_count[st]:>10}")
    print()
    print(f"BUSIEST observation points (top {top})")
    print("-" * 78)
    for (g, t, p, st), c in point.most_common(top):
        print(f"  g{g:<2} t{t:<2} p{p}  {st:<14} {c:>9}")
    print()
    if link:
        dirs = {0: "N", 1: "E", 2: "S", 3: "W"}
        print(f"BUSIEST mesh links (top {top})  [hop tracing]")
        print("-" * 78)
        for (g, t, d, st), c in link.most_common(top):
            print(f"  g{g:<2} t{t:<2} dir={dirs.get(d, d):<2} {st:<8} {c:>9}")
        print()


def print_txn(t):
    print(f"### transaction {fmt_owner(t)}  "
          f"addr=0x{t.addr:05x} tgt=g{t.tgt_g}/t{t.tgt_t}/b{t.tgt_bank} "
          f"{'WRITE' if t.wen else 'READ'} burst={t.burst} "
          f"{'[MERGED]' if t.merged else ''} "
          f"{'COMPLETE' if t.complete else '*** INCOMPLETE ***'}")
    print(f"    last stage reached: {t.last_stage}")
    lat = t.latency()
    if lat is not None:
        print(f"    latency: {lat} cycles")
    print(f"    {'cyc':>8} {'ns':>8}  {'stage':<14} "
          f"{'@loc':<12} {'mid':>3} {'flags':<10} data")
    for ev in sorted(t.events, key=lambda e: (e["cyc"], stage_rank(e["stage"]))):
        loc = f"g{ev['loc_g']}/t{ev['loc_t']}/p{ev['loc_p']}"
        print(f"    {ev['cyc']:>8} {ev['time_ns']:>8}  {ev['stage']:<14} "
              f"{loc:<12} {ev['mid']:>3} {ev['flags']:<10} "
              f"0x{ev['data']:08x}")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="?", default="noc_trace/events.csv",
                    help="path to events.csv (default noc_trace/events.csv)")
    ap.add_argument("--focus", help="G,T,CORE,MID — print one transaction's life")
    ap.add_argument("--addr", help="hex address — focus all transactions to it")
    ap.add_argument("--owner", help="G,T — restrict to one tile's transactions")
    ap.add_argument("--incomplete", action="store_true",
                    help="list FROZEN transactions in detail")
    ap.add_argument("--stuck-gap", type=int, default=1200,
                    help="a txn is FROZEN if its last event is >this many cycles "
                         "before the trace cutoff (default 1200; > max normal latency)")
    ap.add_argument("--routes", action="store_true",
                    help="map the gridlock geometry of FROZEN transactions")
    ap.add_argument("--top", type=int, default=20, help="top-N for congestion/lists")
    args = ap.parse_args()

    if not os.path.exists(args.csv):
        sys.exit(f"trace file not found: {args.csv}")

    rows = list(load_rows(args.csv))
    if not rows:
        sys.exit(f"no parseable rows in {args.csv} "
                 "(did the benchmark enable csr_trace, and is the window right?)")
    span = (min(r["time_ns"] for r in rows), max(r["time_ns"] for r in rows))
    print(f"loaded {len(rows)} events spanning {span[0]}..{span[1]} ns\n")

    txns, orphans = build_transactions(rows)

    # ---- focused views ----
    if args.focus:
        g, t, c, m = (int(x, 0) for x in args.focus.split(","))
        hits = [x for x in txns if x.key() == (g, t, c, m)]
        if not hits:
            # fall back: any txn owning that mid for that owner
            hits = [x for x in txns if x.og == g and x.ot == t and x.core == c
                    and m in x.mids]
        if not hits:
            sys.exit(f"no transaction matching {args.focus}")
        for x in sorted(hits, key=lambda z: z.req_cyc):
            print_txn(x)
        return

    if args.addr:
        a = int(args.addr, 0)
        hits = [x for x in txns if x.addr == a]
        if not hits:
            sys.exit(f"no CORE_REQ transaction to addr {args.addr}")
        print(f"{len(hits)} transaction(s) to addr {args.addr}:\n")
        for x in sorted(hits, key=lambda z: z.req_cyc):
            print_txn(x)
        return

    if args.owner:
        g, t = (int(x, 0) for x in args.owner.split(","))
        txns = [x for x in txns if x.og == g and x.ot == t]

    # ---- full report ----
    max_cyc = max(x.last_cyc for x in txns)
    frozen = report_summary(txns, orphans, max_cyc, args.stuck_gap)
    if args.routes:
        report_routes(frozen, args.top)
    report_latency(txns)

    if args.incomplete:
        inc = sorted(frozen, key=lambda z: z.req_cyc)
        print("-" * 78)
        print(f"FROZEN transactions in detail (showing up to {args.top}, "
              "earliest first)")
        print("-" * 78)
        for x in inc[:args.top]:
            print_txn(x)

    report_congestion(args.csv, args.top)


if __name__ == "__main__":
    main()
