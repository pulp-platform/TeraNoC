#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
"""One table row per qwen-ffn-down run log (GVSoC log or RTL transcript).

    script/summarize.py <log> [<log> ...]

Reads the lines main.c prints after the timed region. Handles the QuestaSim '# ' prefix and
the '[UART] ' prefix of RTL transcripts. Efficiency is ideal/actual throughout (ideal = MACs /
(cores x 16 fp16 MAC/cycle)), never the FPU counter.
"""
import re
import sys


def parse(path):
    txt = open(path, 'rb').read().decode('utf-8', 'replace')
    lines = []
    for ln in txt.splitlines():
        if ln.startswith('# '):
            ln = ln[2:]
        if ln.startswith('[UART] '):
            ln = ln[7:]
        lines.append(ln)
    t = '\n'.join(lines)
    r = {'log': path}
    m = re.search(r'\[QWEN\] B=(\d+) K=(\d+) P=(\d+).*? kt=(\d+) steps=(\d+) ks=(\d+).*?check=(\d+)', t)
    if m:
        r.update(B=int(m[1]), K=int(m[2]), P=int(m[3]), KT=int(m[4]), steps=int(m[5]), KS=int(m[6]),
                 check=int(m[7]))
    m = re.search(r'ksplit=(\d+)', t)
    r['ksplit'] = int(m[1]) if m else 1
    m = re.search(r'The execution took (\d+) cycles', t)
    r['took'] = int(m[1]) if m else None
    m = re.search(r'swiglu=(\d+) prime=(\d+) down=(\d+)', t)
    if m:
        r.update(swiglu=int(m[1]), prime=int(m[2]), down=int(m[3]))
    else:
        m = re.search(r'\[QWEN\] down=(\d+)', t)
        r.update(swiglu=0, prime=0, down=int(m[1]) if m else None)
    m = re.search(r'ideal=(\d+) cycles', t)
    r['ideal'] = int(m[1]) if m else None
    m = re.search(r'tile_cyc=([\d,]+)', t)
    r['tiles'] = [int(x) for x in m[1].split(',')] if m else []
    r['verdict'] = 'success' if 'success!' in t else ('FAIL' if 'FAIL' in t else '-')
    return r


def main():
    rows = [parse(p) for p in sys.argv[1:]]
    hdr = ('run', 'B', 'K', 'KT', 'ks', 'took', 'swiglu', 'prime', 'down', 'ideal', 'eff(down)',
           'tile med', 'tile ideal', 'verdict')
    print('| ' + ' | '.join(hdr) + ' |')
    print('|' + '---|' * len(hdr))
    for r in rows:
        name = r['log'].split('/')[-1].replace('.log', '')
        tiles = sorted(r['tiles'])
        med = tiles[len(tiles) // 2] if tiles else None
        steps = r.get('steps') or 1
        tideal = r['ideal'] // steps if r.get('ideal') else None
        eff = f"{100.0 * r['ideal'] / r['down']:.1f}%" if r.get('ideal') and r.get('down') else '-'
        vals = (name, r.get('B'), r.get('K'), r.get('KT'), r.get('ksplit'), r.get('took'),
                r.get('swiglu'), r.get('prime'), r.get('down'), r.get('ideal'), eff, med, tideal,
                r['verdict'])
        print('| ' + ' | '.join('-' if v is None else f'{v:,}' if isinstance(v, int) else str(v)
                                for v in vals) + ' |')


if __name__ == '__main__':
    main()
