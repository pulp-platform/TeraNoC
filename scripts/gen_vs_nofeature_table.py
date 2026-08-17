#!/usr/bin/env python3
"""Compare the latest sweeps against the NO-FEATURE baseline (no Spatz burst, no group MSHR).

    python3 scripts/gen_vs_nofeature_table.py

Writes docs/benchmarks/gemm_results_vs_nofeature.txt.

WHICH BASELINE. docs/benchmarks/gemm_results_table.txt carries two reference columns and they are
easy to confuse:

    baseline   the build WITHOUT Spatz burst support and WITHOUT the group MSHR  <-- used here
    ours       the tuned 2026-08-03 build, which already has both

Every other file in docs/benchmarks/ compares against `ours`, because those sweeps are measuring
one incremental knob at a time. This file is the only one that answers "what did the whole
mechanism buy?", so it uses `baseline`. Speedup > 1.00 means the feature is faster.

Reads run logs from /tmp/claude-620771/ (tree-agnostic).
"""
import re, os, datetime

T    = '/tmp/claude-620771'
MAIN = '/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC'
SRC  = f'{MAIN}/docs/benchmarks/gemm_results_table.txt'
OUT  = f'{MAIN}/docs/benchmarks/gemm_results_vs_nofeature.txt'
SB1  = {'128x128x512', '128x256x512', '128x512x512', '128x1024x512'}

def fin(p):
    if not os.path.exists(p): return None
    d = open(p, 'rb').read()
    m = re.findall(rb'\[FPU FINAL\].*?over (\d+) benchmark', d)
    if m: return int(m[-1])
    return 'run' if b'[FPU] bench' in d else None

# ---- parse the no-feature baseline out of the plain-text table -------------------------------
ref = {}
for ln in open(SRC):
    f = ln.split()
    if len(f) < 15 or not re.fullmatch(r'\d+x\d+x\d+', f[0]): continue
    try:
        # columns: shape L1MB ss sb bb Ash Bsh mrg it floor ours ours% baseline base% spdup lim
        #          0     1    2  3  4  5   6   7   8  9     10   11    12       13    14    15
        ref[f[0]] = dict(floor=int(f[9].replace(',', '')),
                         ours=int(f[10].replace(',', '')),
                         base=int(f[12].replace(',', '')),
                         lim=f[-1])
    except (ValueError, IndexError):
        continue

shapes = [s.strip() for s in open(f'{T}/sweep_shapes.txt') if s.strip()]
rows = []
for s in shapes:
    r = ref.get(s)
    if not r: continue
    rows.append(dict(shape=s, **r,
                     dflt=fin(f'{T}/mx_dflt_{s}_run.log'),
                     latest=fin(f'{T}/mx_latest_{s}_run.log')))
rows.sort(key=lambda r: -(r['floor'] / r['dflt']) if isinstance(r['dflt'], int) else 1)

def cyc(v):  return f"{v:,}" if isinstance(v, int) else ('run' if v == 'run' else '-')
def pct(fl, v): return f"{100*fl/v:.1f}" if isinstance(v, int) else '-'
def spd(b, v):  return f"{b/v:.2f}" if isinstance(v, int) else '-'

L = []
L.append('Latest sweeps vs. the NO-FEATURE baseline (no Spatz burst, no group MSHR)')
L.append(f'Generated {datetime.datetime.now():%Y-%m-%d %H:%M} · '
         'python3 scripts/gen_vs_nofeature_table.py')
L.append('')
L.append('baseline = the build with neither Spatz burst support nor the group MSHR.')
L.append('           (NOT the "ours" column of gemm_results_table.txt, which already has both.)')
L.append('dflt     = current shipping default            : cfg_runtime=0, prescale_w=4')
L.append('latest   = shipping default + runtime MSHR CSR : cfg_runtime=1, prescale_w=4')
L.append('%        = efficiency, floor/actual, floor = M*N*P/1024 (1024 FPU lanes)')
L.append('spdup    = baseline / arm.  >1.00 means the feature is faster.')
L.append('lim      = operand that limits the shape (A / B / - none), from the source table.')
L.append('')
hdr = (f"{'shape':<15}{'floor':>9}{'baseline':>10}{'base%':>7}"
       f"{'dflt':>10}{'dflt%':>7}{'spdup':>7}"
       f"{'latest':>10}{'lat%':>7}{'spdup':>7}  lim")
L.append(hdr)
L.append('-' * len(hdr))
sd = sl = 0
for r in rows:
    L.append(f"{r['shape']:<15}{r['floor']:>9,}{r['base']:>10,}{100*r['floor']/r['base']:>7.1f}"
             f"{cyc(r['dflt']):>10}{pct(r['floor'], r['dflt']):>7}{spd(r['base'], r['dflt']):>7}"
             f"{cyc(r['latest']):>10}{pct(r['floor'], r['latest']):>7}{spd(r['base'], r['latest']):>7}"
             f"  {r['lim']}")
L.append('-' * len(hdr))

def med(a):
    a = sorted(a); h = len(a)//2
    return a[h] if len(a) % 2 else (a[h-1]+a[h])/2

for nm, key in (('dflt', 'dflt'), ('latest', 'latest')):
    sp = [r['base']/r[key] for r in rows if isinstance(r[key], int)]
    ef = [100*r['floor']/r[key] for r in rows if isinstance(r[key], int)]
    bf = [100*r['floor']/r['base'] for r in rows if isinstance(r[key], int)]
    if not sp: continue
    L.append(f"{nm:<8} {len(sp)}/{len(rows)} shapes | speedup vs baseline: "
             f"median {med(sp):.2f}x, range {min(sp):.2f}-{max(sp):.2f}x | "
             f"efficiency {med(bf):.1f}% -> {med(ef):.1f}% (median)")
L.append('')
L.append('NOTE: shapes still running show "run". Re-run the generator as arms land.')
open(OUT, 'w').write('\n'.join(L) + '\n')
print(f'wrote {OUT}  ({sum(1 for r in rows if isinstance(r["dflt"], int))}/{len(rows)} dflt, '
      f'{sum(1 for r in rows if isinstance(r["latest"], int))}/{len(rows)} latest)')
