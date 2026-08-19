#!/usr/bin/env python3
"""Parse [VPERF] lines from a QuestaSim transcript into the form the gvsoc side asked for.

Request: TeraNoC_gvsoc/docs/rtl_probe_request.md

DEFINITIONS -- deliberately reported under BOTH denominators, because their section 4 warns that
averaging over different cycle sets is the most likely way for the two sides to disagree while
appearing to measure the same thing:

  N_window = infl_sum / win        loads in flight averaged over the whole benchmark window
  N_active = infl_sum / act_cyc    averaged over cycles the VLSU has work  <- THEIR definition
  L        = infl_sum / insn_ret   Little's law; insn_ret counts commit_insn_pop, which IS their
                                   stated definition of retire (admission -> commit_insn_pop)
  T        = L / N                 issue interval

L needs no extra state: N/X with X = insn_ret/win reduces to infl_sum/insn_ret.
"""
import re, sys, statistics as st

PAT = re.compile(r'\[VPERF\]\s+(\S+)\s+(.*)')
KV  = re.compile(r'(\w+)=(\d+)')

def load(path):
    rows = []
    with open(path, 'rb') as fh:
        for raw in fh:
            if raw.startswith(b'# '):          # QuestaSim prefixes every transcript line
                raw = raw[2:]
            m = PAT.search(raw.decode('utf-8', 'replace'))
            if m:
                d = {k: int(v) for k, v in KV.findall(m.group(2))}
                d['_inst'] = m.group(1)
                rows.append(d)
    return rows

def main():
    if len(sys.argv) < 2:
        sys.exit('usage: collect_vperf.py <transcript> [--csv out.csv]')
    rows = load(sys.argv[1])
    if not rows:
        sys.exit('no [VPERF] lines found — did the benchmark window open (csr_trace)?')
    keys = [k for k in rows[0] if not k.startswith('_')]
    has_infl = 'infl_sum' in keys

    print(f'cores reporting : {len(rows)}')
    print()
    print(f'{"counter":<16}{"mean":>14}{"min":>12}{"max":>12}   (per core, over the benchmark window)')
    print('-' * 68)
    for k in keys:
        v = [r[k] for r in rows]
        print(f'{k:<16}{st.mean(v):>14.1f}{min(v):>12}{max(v):>12}')

    if has_infl:
        print()
        print('DERIVED (the numbers the request asks for)')
        print('-' * 68)
        def per_core(f):
            out = []
            for r in rows:
                try:
                    x = f(r)
                    if x == x: out.append(x)
                except ZeroDivisionError:
                    pass
            return out
        nw = per_core(lambda r: r['infl_sum'] / r['win'])
        na = per_core(lambda r: r['infl_sum'] / r['act_cyc'])
        L  = per_core(lambda r: r['infl_sum'] / r['insn_ret'])
        X  = per_core(lambda r: r['insn_ret'] / r['win'])
        for name, v, note in (
            ('N_window', nw, 'infl_sum/win      — averaged over the whole window'),
            ('N_active',  na, 'infl_sum/act_cyc  — THEIR definition of N'),
            ('L',         L, 'infl_sum/insn_ret — load latency, Little\'s law'),
            ('X',         X, 'insn_ret/win      — retire throughput'),
        ):
            if v:
                print(f'  {name:<10}{st.mean(v):>10.3f}   (min {min(v):.3f}  max {max(v):.3f})   {note}')
        if L and na:
            print(f'  {"T = L/N":<10}{st.mean(L)/st.mean(na):>10.3f}   '
                  f'issue interval, using N_active')
    if '--csv' in sys.argv:
        out = sys.argv[sys.argv.index('--csv') + 1]
        with open(out, 'w') as fh:
            fh.write('instance,' + ','.join(keys) + '\n')
            for r in rows:
                fh.write(r['_inst'] + ',' + ','.join(str(r[k]) for k in keys) + '\n')
        print(f'\nper-core CSV -> {out}')

if __name__ == '__main__':
    main()
