#!/usr/bin/env python3
"""Period-by-period equivalence between two arms that should be bit-identical.

Used for the matched-pair test the repo relies on: two builds one define apart, where the
define is expected to const-fold away for the traffic under test. A final cycle count matching
is weak evidence -- two runs can diverge and reconverge. Comparing every probe line at every
period is what actually establishes equivalence, and it localises the FIRST divergence.

Compares the per-group probe lines ([INSNG], [FPU], [STALLG], [MSHRG], [MEMOG]) keyed by cycle.
"""
import re, sys, argparse
from collections import defaultdict

TAGS = ['INSNG', 'FPU', 'STALLG', 'MSHRG', 'MEMOG']

def load(path, tag):
    out = {}
    pat = re.compile(r'\[' + tag + r'\]\s+\S+\s+cyc=(\d+)\s+(.*)')
    with open(path, 'rb') as fh:
        for raw in fh:
            if raw.startswith(b'# '):
                raw = raw[2:]                       # QuestaSim prefixes every line
            m = pat.search(raw.decode('utf-8', 'replace').rstrip())
            if m:
                out[int(m.group(1))] = m.group(2).strip()
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a'); ap.add_argument('b')
    ap.add_argument('--from-cyc', type=int, default=0,
                    help='ignore periods before this (warmup is not always deterministic)')
    args = ap.parse_args()

    total_cmp = 0
    first_div = None
    for tag in TAGS:
        A, B = load(args.a, tag), load(args.b, tag)
        common = sorted(set(A) & set(B))
        common = [c for c in common if c >= args.from_cyc]
        diffs = [c for c in common if A[c] != B[c]]
        total_cmp += len(common)
        status = 'IDENTICAL' if not diffs else f'DIVERGES at cyc={diffs[0]}'
        print(f'  [{tag}]  {len(common):4d} periods compared   {status}')
        if diffs:
            c = diffs[0]
            if first_div is None or c < first_div:
                first_div = c
            print(f'      A: {A[c][:110]}')
            print(f'      B: {B[c][:110]}')

    print()
    if total_cmp == 0:
        print('NO OVERLAPPING PERIODS -- nothing was actually compared. Not a pass.')
        sys.exit(2)
    if first_div is None:
        print(f'EQUIVALENT over {total_cmp} probe-periods '
              f'(from cyc={args.from_cyc}). The define is inert for this traffic.')
        sys.exit(0)
    print(f'NOT EQUIVALENT - first divergence at cyc={first_div}')
    sys.exit(1)

if __name__ == '__main__':
    main()
