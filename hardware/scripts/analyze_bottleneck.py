#!/usr/bin/env python3
"""Interconnect bottleneck analysis from [BP] profiling lines.

Parses [BP] delta/final lines and produces a detailed bottleneck report.

The profiling file produces three kinds of records:
  kind=stage:     per-pipeline-stage per-group aggregate
  kind=bank_req:  per-tile bank request contention (across 16 banks)
  kind=bank_resp: per-tile bank response egress

Output sections:
  1. Pipeline stage bottleneck ranking (hot stages)
  2. Group-level imbalance per stage
  3. Temporal evolution (top bottleneck per window)
  4. Bank-level hot-tile ranking
  5. Cross-stage correlation (does A's stall match B's offered increase?)

Usage:
  python3 analyze_bottleneck.py transcript
  python3 analyze_bottleneck.py transcript --period 10000-25000 --top 10
"""

import argparse
import re
import sys
from collections import defaultdict


def parse_bp_lines(filepath):
    """Parse [BP] lines. Returns list of dicts, one per record."""
    records = []
    # Common prefix: [BP] <tag>,kind=<kind>,cyc=<c>,active_cyc=<a>,...
    kv_re = re.compile(r'(\w+)=([-+\w.]+)')
    with open(filepath) as f:
        for line in f:
            if '[BP]' not in line:
                continue
            # Strip the "[BP] " header and optional leading "# "
            idx = line.find('[BP]')
            body = line[idx + 4:].strip()
            # First token is tag (delta/final), followed by comma-separated k=v pairs
            m = re.match(r'(\w+),(.*)', body)
            if not m:
                continue
            rec = {'tag': m.group(1)}
            for k, v in kv_re.findall(m.group(2)):
                # Try to coerce to int or float
                try:
                    if '.' in v:
                        rec[k] = float(v)
                    else:
                        rec[k] = int(v)
                except ValueError:
                    rec[k] = v
            records.append(rec)
    return records


def filter_period(records, start, end):
    out = records
    if start is not None:
        out = [r for r in out if r.get('cyc', 0) >= start]
    if end is not None:
        out = [r for r in out if r.get('cyc', 0) <= end]
    return out


def banner(title):
    print('=' * 76)
    print(f'  {title}')
    print('=' * 76)


def stage_ranking(records, top_n=10):
    """Rank pipeline stages by weighted average stall_rate, weighted by offered load."""
    stage_recs = [r for r in records if r.get('kind') == 'stage' and r['tag'] == 'delta']
    if not stage_recs:
        print("  (no stage records)")
        return
    # Aggregate per stage across groups and periods
    agg = defaultdict(lambda: {'hsk': 0, 'stall': 0, 'idle': 0})
    for r in stage_recs:
        s = agg[r['s']]
        s['hsk']   += r.get('hsk', 0)
        s['stall'] += r.get('stall', 0)
        s['idle']  += r.get('idle', 0)

    rows = []
    for stage, d in agg.items():
        total = d['hsk'] + d['stall'] + d['idle']
        offer = d['hsk'] + d['stall']
        rows.append({
            'stage': stage,
            'hsk': d['hsk'],
            'stall': d['stall'],
            'idle': d['idle'],
            'total': total,
            'util': d['hsk'] / total if total else 0,
            'stall_rate': d['stall'] / offer if offer else 0,
            'offered': offer / total if total else 0,
        })
    # Sort by absolute stall count (severity) descending
    rows.sort(key=lambda x: -x['stall'])

    banner("1. PIPELINE STAGE BOTTLENECK (sorted by absolute stall count)")
    print(f"{'Rank':>4s}  {'Stage':<18s}  {'StallRate':>10s}  {'Offered':>9s}  {'Util':>8s}  "
          f"{'Hsk':>12s}  {'Stall':>12s}")
    print('-' * 76)
    for i, r in enumerate(rows[:top_n]):
        print(f"{i+1:4d}  {r['stage']:<18s}  {r['stall_rate']:10.4f}  "
              f"{r['offered']:9.4f}  {r['util']:8.4f}  "
              f"{r['hsk']:12d}  {r['stall']:12d}")
    print()
    return rows


def group_imbalance(records):
    """Per-stage per-group stall_rate grid."""
    stage_recs = [r for r in records if r.get('kind') == 'stage' and r['tag'] == 'delta']
    if not stage_recs:
        return
    agg = defaultdict(lambda: {'hsk': 0, 'stall': 0})
    for r in stage_recs:
        key = (r['s'], r['g'])
        agg[key]['hsk']   += r.get('hsk', 0)
        agg[key]['stall'] += r.get('stall', 0)
    stages = sorted({k[0] for k in agg})
    groups = sorted({k[1] for k in agg})

    banner("2. GROUP IMBALANCE (stall_rate per stage per group)")
    header = f"{'Stage':<18s}" + "".join(f"  G{g:2d}" for g in groups)
    print(header)
    print('-' * len(header))
    for stage in stages:
        vals = []
        for g in groups:
            k = (stage, g)
            d = agg.get(k, {'hsk': 0, 'stall': 0})
            offer = d['hsk'] + d['stall']
            vals.append(d['stall'] / offer if offer else 0)
        # Flag imbalance if max/min > 1.5
        positive = [v for v in vals if v > 0]
        flag = ""
        if positive and max(positive) / min(positive) > 1.5:
            flag = "  *** IMBALANCED"
        line = f"{stage:<18s}" + "".join(f"  {v:.3f}" for v in vals) + flag
        print(line)
    print()


def temporal_evolution(records, windows=None):
    """Top bottleneck per window."""
    stage_recs = [r for r in records if r.get('kind') == 'stage' and r['tag'] == 'delta']
    if not stage_recs:
        return
    by_cyc = defaultdict(list)
    for r in stage_recs:
        by_cyc[r['cyc']].append(r)
    banner("3. TEMPORAL EVOLUTION (top bottleneck per window)")
    print(f"{'Cycle':>8s}  {'TopStage':<18s}  {'G':>2s}  {'StallRate':>10s}  "
          f"{'Offered':>9s}  {'Util':>8s}")
    print('-' * 76)
    for cyc in sorted(by_cyc):
        recs = by_cyc[cyc]
        # Pick record with highest stall_rate weighted by offered
        scored = []
        for r in recs:
            offer = r.get('hsk', 0) + r.get('stall', 0)
            total = offer + r.get('idle', 0)
            if total == 0:
                continue
            sr = r.get('stall_rate', 0)
            scored.append((sr, offer/total, r))
        if not scored:
            continue
        scored.sort(key=lambda x: (-x[0], -x[1]))
        _, _, top = scored[0]
        print(f"{top['cyc']:8d}  {top['s']:<18s}  {top['g']:2d}  "
              f"{top.get('stall_rate', 0):10.4f}  "
              f"{top.get('offered', 0):9.4f}  {top.get('util', 0):8.4f}")
    print()


def bank_hot_tiles(records, top_n=16):
    """Per-tile bank request stall ranking."""
    bank_recs = [r for r in records if r.get('kind') == 'bank_req' and r['tag'] == 'delta']
    if not bank_recs:
        print("  (no bank_req records)")
        return
    agg = defaultdict(lambda: {'hsk': 0, 'stall': 0, 'idle': 0})
    for r in bank_recs:
        key = (r['g'], r['t'])
        agg[key]['hsk']   += r.get('hsk', 0)
        agg[key]['stall'] += r.get('stall', 0)
        agg[key]['idle']  += r.get('idle', 0)
    rows = []
    for (g, t), d in agg.items():
        total = d['hsk'] + d['stall'] + d['idle']
        offer = d['hsk'] + d['stall']
        rows.append({
            'g': g, 't': t,
            'hsk': d['hsk'],
            'stall': d['stall'],
            'util': d['hsk'] / total if total else 0,
            'stall_rate': d['stall'] / offer if offer else 0,
            'offered': offer / total if total else 0,
        })
    rows.sort(key=lambda x: -x['stall'])

    banner("4. BANK-LEVEL HOT TILES (superbank_req contention)")
    print(f"{'Rank':>4s}  {'Group':>5s}  {'Tile':>4s}  {'StallRate':>10s}  "
          f"{'Offered':>9s}  {'Util':>8s}  {'Hsk':>12s}  {'Stall':>12s}")
    print('-' * 76)
    for i, r in enumerate(rows[:top_n]):
        print(f"{i+1:4d}  {r['g']:5d}  {r['t']:4d}  {r['stall_rate']:10.4f}  "
              f"{r['offered']:9.4f}  {r['util']:8.4f}  "
              f"{r['hsk']:12d}  {r['stall']:12d}")
    # Summary stats
    if rows:
        avg_stall_rate = sum(r['stall_rate'] for r in rows) / len(rows)
        max_sr = max(rows, key=lambda x: x['stall_rate'])
        min_sr = min(rows, key=lambda x: x['stall_rate'])
        print()
        print(f"  Average bank_req stall_rate across all tiles: {avg_stall_rate:.4f}")
        print(f"  Max: G{max_sr['g']}T{max_sr['t']} = {max_sr['stall_rate']:.4f}")
        print(f"  Min: G{min_sr['g']}T{min_sr['t']} = {min_sr['stall_rate']:.4f}")
        if min_sr['stall_rate'] > 0:
            print(f"  Imbalance ratio: {max_sr['stall_rate'] / min_sr['stall_rate']:.2f}x")
    print()


def bank_resp_summary(records):
    """Per-tile bank response (superbank_resp) egress stall summary."""
    bank_recs = [r for r in records if r.get('kind') == 'bank_resp' and r['tag'] == 'delta']
    if not bank_recs:
        return
    # Aggregate across all tiles/groups/periods
    agg = {'hsk': 0, 'stall': 0, 'idle': 0}
    for r in bank_recs:
        agg['hsk']   += r.get('hsk', 0)
        agg['stall'] += r.get('stall', 0)
        agg['idle']  += r.get('idle', 0)
    total = agg['hsk'] + agg['stall'] + agg['idle']
    offer = agg['hsk'] + agg['stall']
    banner("5. BANK RESPONSE EGRESS (superbank_resp)")
    print(f"  Aggregate: hsk={agg['hsk']} stall={agg['stall']} idle={agg['idle']}")
    if total > 0:
        print(f"  util={agg['hsk']/total:.4f}  stall_rate={agg['stall']/offer if offer else 0:.4f}  "
              f"offered={offer/total:.4f}")
    # Top-5 hot tiles
    per_tile = defaultdict(lambda: {'hsk': 0, 'stall': 0})
    for r in bank_recs:
        key = (r['g'], r['t'])
        per_tile[key]['hsk']   += r.get('hsk', 0)
        per_tile[key]['stall'] += r.get('stall', 0)
    rows = []
    for (g, t), d in per_tile.items():
        offer = d['hsk'] + d['stall']
        rows.append((g, t, d['stall'] / offer if offer else 0, d['stall']))
    rows.sort(key=lambda x: -x[3])
    print("  Top-5 tiles by bank_resp stalls:")
    for g, t, sr, st in rows[:5]:
        print(f"    G{g}T{t}: stall_rate={sr:.4f} stall_count={st}")
    print()


def causal_chain(records):
    """Show side-by-side stall_rate for consecutive stages to reveal
    backpressure propagation.  For request path: chain = [TILE_OUT, MSHR_IN,
    MSHR_OUT, SLAVE_IN, BANK_REQ]. For response path: [BANK_RESP, SLAVE_OUT,
    MSHR_IN, MSHR_OUT, TILE_BACK]."""
    # Aggregate stage stall rates (weighted)
    stage_recs = [r for r in records if r.get('kind') == 'stage' and r['tag'] == 'delta']
    bank_req  = [r for r in records if r.get('kind') == 'bank_req' and r['tag'] == 'delta']
    bank_resp = [r for r in records if r.get('kind') == 'bank_resp' and r['tag'] == 'delta']

    def agg_stage(name):
        h = s = 0
        for r in stage_recs:
            if r['s'] == name:
                h += r.get('hsk', 0)
                s += r.get('stall', 0)
        return s / (h + s) if (h + s) > 0 else 0

    def agg_bank(recs):
        h = s = 0
        for r in recs:
            h += r.get('hsk', 0)
            s += r.get('stall', 0)
        return s / (h + s) if (h + s) > 0 else 0

    req_chain = [
        ("Core->Tile     (REQ_TILE_OUT)",   agg_stage("REQ_TILE_OUT")),
        ("Tile->MSHR     (REQ_MSHR_IN)",    agg_stage("REQ_MSHR_IN")),
        ("MSHR->NoC      (REQ_MSHR_OUT)",   agg_stage("REQ_MSHR_OUT")),
        ("NoC->Tile      (REQ_SLAVE_IN)",   agg_stage("REQ_SLAVE_IN")),
        ("Tile->Bank     (BANK_REQ)",       agg_bank(bank_req)),
    ]
    rsp_chain = [
        ("Bank->Tile     (BANK_RESP)",      agg_bank(bank_resp)),
        ("Tile->NoC      (RESP_SLAVE_OUT)", agg_stage("RESP_SLAVE_OUT")),
        ("NoC->MSHR      (RESP_MSHR_IN)",   agg_stage("RESP_MSHR_IN")),
        ("MSHR->Tile     (RESP_MSHR_OUT)",  agg_stage("RESP_MSHR_OUT")),
        ("Tile->Core     (RESP_TILE_BACK)", agg_stage("RESP_TILE_BACK")),
    ]

    banner("6. CAUSAL CHAIN (stall propagation along the pipeline)")
    print("  Request path:")
    for name, sr in req_chain:
        bar = '|' * min(int(sr * 50), 50)
        print(f"    {name:<35s} {sr:7.4f}  {bar}")
    print()
    print("  Response path:")
    for name, sr in rsp_chain:
        bar = '|' * min(int(sr * 50), 50)
        print(f"    {name:<35s} {sr:7.4f}  {bar}")
    print()
    print("  Reading: the bottleneck is the HIGHEST bar. Upstream stages with")
    print("  lower stalls indicate their backpressure is masked (e.g. by buffers).")
    print()


def main():
    parser = argparse.ArgumentParser(description="Interconnect bottleneck analysis")
    parser.add_argument("input", help="Simulation transcript file")
    parser.add_argument("--top", type=int, default=12, help="Top N rows in rankings")
    parser.add_argument("--period", help="Cycle range filter, e.g. 10000-25000")
    args = parser.parse_args()

    records = parse_bp_lines(args.input)
    if not records:
        print(f"No [BP] lines found in {args.input}", file=sys.stderr)
        sys.exit(1)
    print(f"Parsed {len(records)} [BP] records from {args.input}")
    print(f"  stage records: {sum(1 for r in records if r.get('kind') == 'stage')}")
    print(f"  bank_req records: {sum(1 for r in records if r.get('kind') == 'bank_req')}")
    print(f"  bank_resp records: {sum(1 for r in records if r.get('kind') == 'bank_resp')}")
    print()

    start, end = None, None
    if args.period:
        parts = args.period.split('-')
        start = int(parts[0])
        end = int(parts[1]) if len(parts) > 1 and parts[1] else None

    filtered = filter_period(records, start, end)
    if not filtered:
        print("No records in specified period range", file=sys.stderr)
        sys.exit(1)

    stage_ranking(filtered, args.top)
    group_imbalance(filtered)
    temporal_evolution(filtered)
    bank_hot_tiles(filtered, args.top)
    bank_resp_summary(filtered)
    causal_chain(filtered)


if __name__ == "__main__":
    main()
