#!/usr/bin/env python3
"""
Parse [MSHR stats (period)] blocks from a QuestaSim transcript produced by
mempool_group_mshr with EnableStats=1. Summarizes per-period and per-group
MSHR utilization, merge efficiency, overflow pressure, and response cache
behavior.

Usage: analyze_mshr_stats.py <transcript>
"""
from __future__ import annotations

import argparse
import re
import statistics
from collections import defaultdict
from pathlib import Path

BLOCK_HEAD = re.compile(
    r"gen_groups_x\[(\d+)\]\.gen_groups_y\[(\d+)\].*MSHR stats \((\w+)\)"
)
KV_FLOAT = re.compile(r"([a-zA-Z_]+)=([-+]?\d+\.\d+)")
KV_INT = re.compile(r"([a-zA-Z_]+)=(\d+)")


def parse_transcript(path: Path):
    records = []
    with path.open() as f:
        cur = None
        for raw in f:
            line = raw.rstrip("\n")
            m = BLOCK_HEAD.search(line)
            if m:
                if cur is not None:
                    records.append(cur)
                gx, gy, tag = m.groups()
                cur = {"gx": int(gx), "gy": int(gy), "tag": tag}
                continue
            if cur is None:
                continue
            # Stop block when we see a non-continuation line (rough heuristic).
            if not line.lstrip("#").strip().startswith(("cycles=", "mshr_", "subreq_", "reqs:", "resps:", "cache:")):
                continue
            for k, v in KV_FLOAT.findall(line):
                cur[k] = float(v)
            for k, v in KV_INT.findall(line):
                if k not in cur:
                    cur[k] = int(v)
        if cur is not None:
            records.append(cur)
    return records


def mean(xs):
    return statistics.mean(xs) if xs else 0.0


def pmean(recs, key):
    vals = [r[key] for r in recs if key in r]
    return mean(vals)


def summarize(records):
    if not records:
        print("No [MSHR stats] records found.")
        return

    periods = sorted({r["cycles"] for r in records if "cycles" in r})
    groups = sorted({(r["gx"], r["gy"]) for r in records})

    print("=" * 78)
    print(f"  MSHR stats summary — {len(records)} records across {len(groups)} groups")
    print("=" * 78)

    # 1. Aggregate utilization
    print("\n1. MSHR utilization (aggregate over all records):")
    print(f"   mshr_util_avg           : {pmean(records, 'mshr_util_avg'):.3f}")
    print(f"   mshr_util_uncached_avg  : {pmean(records, 'mshr_util_uncached_avg'):.3f}")
    print(f"   mshr_valid_avg          : {pmean(records, 'mshr_valid_avg'):.2f}")
    print(f"   mshr_valid_max  (peak)  : {max(r.get('mshr_valid_max', 0) for r in records)}")
    print(f"   subreq_util_avg         : {pmean(records, 'subreq_util_avg'):.3f}")
    print(f"   subreq_per_valid_mshr_avg: {pmean(records, 'subreq_per_valid_mshr_avg'):.2f}")

    # 2. Request admission / merging
    total_acc = sum(r.get("accepted", 0) for r in records)
    total_single = sum(r.get("single", 0) for r in records)
    total_burst = sum(r.get("burst", 0) for r in records)
    total_merged = sum(r.get("merged", 0) for r in records)
    total_alloc = sum(r.get("alloc", 0) for r in records)
    total_bypass = sum(r.get("bypass", 0) for r in records)
    total_mshr_ovf = sum(r.get("mshr_overflow", 0) for r in records)
    total_subreq_ovf = sum(r.get("subreq_overflow", 0) for r in records)
    total_resp_mshr = sum(r.get("from_mshr", 0) for r in records)
    total_resp_bypass = sum(r.get("from_bypass", 0) for r in records)

    print("\n2. Request admission (summed over all samples):")
    print(f"   accepted        : {total_acc:>10d}")
    print(f"     single        : {total_single:>10d}  ({total_single/total_acc*100:.1f}%)")
    print(f"     burst         : {total_burst:>10d}  ({total_burst/total_acc*100:.1f}%)")
    print(f"   merged          : {total_merged:>10d}  (joined existing entry)")
    print(f"   alloc           : {total_alloc:>10d}  (new MSHR entry)")
    print(f"   bypass          : {total_bypass:>10d}  (went around MSHR)")
    print(f"   mshr_overflow   : {total_mshr_ovf:>10d}  <-- MSHR full, requests diverted")
    print(f"   subreq_overflow : {total_subreq_ovf:>10d}  (per-entry subreq queue full)")

    if total_merged + total_alloc > 0:
        merge_rate = total_merged / (total_merged + total_alloc)
        print(f"\n   Merge rate = merged/(merged+alloc) = {merge_rate:.3f}")
    if total_acc > 0:
        overflow_rate = total_mshr_ovf / total_acc
        print(f"   Overflow rate = mshr_overflow/accepted = {overflow_rate:.3f}")

    # 3. Response path
    print("\n3. Response path:")
    total_resp = total_resp_mshr + total_resp_bypass
    if total_resp > 0:
        print(f"   from_mshr        : {total_resp_mshr:>10d}  ({total_resp_mshr/total_resp*100:.1f}%)")
        print(f"   from_bypass      : {total_resp_bypass:>10d}  ({total_resp_bypass/total_resp*100:.1f}%)")

    # 4. Response cache
    total_hit = sum(r.get("hit", 0) for r in records)
    total_fill = sum(r.get("fill", 0) for r in records)
    total_evict = sum(r.get("evict", 0) for r in records)
    print("\n4. Response cache:")
    print(f"   hit              : {total_hit}")
    print(f"   fill             : {total_fill}")
    print(f"   evict            : {total_evict}")
    if total_hit + total_evict > 0:
        print(f"   hit_rate = hit/(hit+evict) = {total_hit/(total_hit+total_evict):.3f}")

    # 5. Per-group imbalance
    print("\n5. Per-group MSHR utilization (averaged across periods):")
    print(f"   {'G':>3} {'util':>8} {'overflow':>10} {'merge_rate':>11} {'valid_max':>10}")
    per_group = defaultdict(list)
    for r in records:
        per_group[(r["gx"], r["gy"])].append(r)
    for g, recs in sorted(per_group.items()):
        u = pmean(recs, "mshr_util_avg")
        ovf = sum(r.get("mshr_overflow", 0) for r in recs)
        m = sum(r.get("merged", 0) for r in recs)
        a = sum(r.get("alloc", 0) for r in recs)
        mr = m / (m + a) if (m + a) > 0 else 0.0
        vmax = max(r.get("mshr_valid_max", 0) for r in recs)
        print(f"   ({g[0]},{g[1]}) {u:>8.3f} {ovf:>10d} {mr:>11.3f} {vmax:>10d}")

    # 6. Temporal evolution (first 10 periods per group (0,0) if available)
    g0_recs = sorted(per_group[(0, 0)], key=lambda r: r.get("cycles", 0))
    if len(g0_recs) > 1:
        print("\n6. Temporal evolution for group (0,0) (MSHR util & overflow):")
        for r in g0_recs[:20]:
            print(f"   period #{g0_recs.index(r)+1}: "
                  f"util={r.get('mshr_util_avg', 0):.3f}  "
                  f"overflow={r.get('mshr_overflow', 0):>4}  "
                  f"merged={r.get('merged', 0):>4}  "
                  f"bypass={r.get('bypass', 0):>4}  "
                  f"valid_max={r.get('mshr_valid_max', 0):>3}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("transcript", type=Path)
    ap.add_argument("--min-accepted", type=int, default=0,
                    help="Drop records with `accepted` below this (filter idle periods)")
    args = ap.parse_args()
    records = parse_transcript(args.transcript)
    if args.min_accepted > 0:
        before = len(records)
        records = [r for r in records if r.get("accepted", 0) >= args.min_accepted]
        print(f"Filtered records with accepted >= {args.min_accepted}: "
              f"{before} -> {len(records)}")
    summarize(records)


if __name__ == "__main__":
    main()
