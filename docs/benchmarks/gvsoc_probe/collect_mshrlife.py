#!/usr/bin/env python3
"""Reduce [MSHRLIFE] lines into the hold/flight/drain split for the GVSOC calibration.

Usage: collect_mshrlife.py <transcript> [--csv out.csv]

Emits per-instance rows and a fleet summary. The key check it performs -- and the reason the
probe stamps `life` independently -- is whether hold+flight+drain reconciles to the measured
entry lifetime. If it does not, the spans are missing a path (an entry freed before any beat,
or a CACHED-state revisit) and the means must NOT be compared against another model's spans
until that is understood.

QuestaSim prefixes every transcript line with '# '; that is stripped here.
"""
import re, sys, csv, statistics as st

def parse(path):
    rows = []
    for raw in open(path, 'rb'):
        if raw.startswith(b'# '):
            raw = raw[2:]
        if b'[MSHRLIFE]' not in raw:
            continue
        t = raw.decode('utf8', 'replace')
        d = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', t)}
        m = re.search(r'\[MSHRLIFE\]\s+(\S+)', t)
        if m:
            d['inst'] = m.group(1)
        g = re.search(r'gen_groups_x\[(\d+)\]\.gen_groups_y\[(\d+)\]', t)
        d['gx'], d['gy'] = (int(g.group(1)), int(g.group(2))) if g else (-1, -1)
        if 'life_n' in d:
            rows.append(d)
    return rows

def mean(sum_k, n_k, rows):
    n = sum(r.get(n_k, 0) for r in rows)
    return (sum(r.get(sum_k, 0) for r in rows) / n) if n else float('nan'), n

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rows = parse(sys.argv[1])
    if not rows:
        sys.exit("no [MSHRLIFE] lines found -- run not finished, or probe not compiled in")

    print("instances: %d" % len(rows))
    hold, hn     = mean('hold_sum',   'hold_n',   rows)
    flight, fn   = mean('flight_sum', 'flight_n', rows)
    drain, dn    = mean('drain_sum',  'drain_n',  rows)
    life, ln     = mean('life_sum',   'life_n',   rows)
    nobeat = sum(r.get('freed_without_beat', 0) for r in rows)

    print("\n=== FLEET MEANS (cycles) ===")
    print("  hold   = %8.2f   (n=%d)   alloc -> request issued" % (hold, hn))
    print("  flight = %8.2f   (n=%d)   issued -> FIRST response beat" % (flight, fn))
    print("  drain  = %8.2f   (n=%d)   first beat -> entry freed" % (drain, dn))
    print("  ---------------------------------")
    print("  sum    = %8.2f" % (hold + flight + drain))
    print("  life   = %8.2f   (n=%d)   alloc -> freed, stamped INDEPENDENTLY" % (life, ln))
    resid = life - (hold + flight + drain)
    print("  resid  = %8.2f   (%.1f%% of life)" % (resid, 100.0 * resid / life if life else 0))
    print("  freed_without_beat = %d  (excluded from drain_n, so drain is not diluted)" % nobeat)

    if abs(resid) > 0.05 * life:
        print("\n  !! RESIDUAL > 5%% OF LIFE. The three spans do not reconcile to the measured")
        print("     lifetime, so some entries take a path the spans miss. Do NOT compare these")
        print("     means against another model's hold/flight/drain until this is explained.")
    else:
        print("\n  spans reconcile to the independently-stamped lifetime -- safe to compare.")

    if '--csv' in sys.argv:
        out = sys.argv[sys.argv.index('--csv') + 1]
        cols = ['gx', 'gy', 'inst', 'MshrNum', 'hold_n', 'hold_sum', 'flight_n', 'flight_sum',
                'drain_n', 'drain_sum', 'life_n', 'life_sum', 'freed_without_beat']
        with open(out, 'w', newline='') as f:
            w = csv.DictWriter(f, fieldnames=cols, extrasaction='ignore')
            w.writeheader()
            for r in sorted(rows, key=lambda r: (r['gx'], r['gy'])):
                w.writerow(r)
        print("\nwrote %s" % out)

if __name__ == '__main__':
    main()
