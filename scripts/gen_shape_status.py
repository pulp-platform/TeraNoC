#!/usr/bin/env python3
"""One row per shape, every phase side by side -- the view the per-phase docs cannot give.

WHY THIS EXISTS. The PPA campaign is a CHAIN: each gemm_results_*.md compares one phase against the
one immediately before it, which is the right way to attribute a change but makes it impossible to
answer "where does shape X stand now?" without opening six files and doing arithmetic. This file is
the transpose: shapes down, phases across, best-so-far called out.

DATA SOURCE. [FPU FINAL] in the per-arm run logs under /tmp/claude-620771/, which is tree-agnostic,
so this regenerates from either checkout. Baselines come from the generated CSR doc's `baseline cyc`
column (itself sourced from gemm_results.md, 2026-08-03).

EFFICIENCY IS ideal/actual, ideal = M*N*P/1024 -- never the TB's [FPU] util counter, which is lane
occupancy and is not conserved across runs of identical work (see docs reference_fpu_util_metric).
"""
import re, os, sys, datetime

T    = '/tmp/claude-620771'
MAIN = '/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC'
OUT  = f'{MAIN}/docs/benchmarks/gemm_shape_status.md'
CSRDOC = f'{MAIN}/docs/benchmarks/gemm_results_mshr_ppa_csr.md'

# The chain, in order -- the DEFAULT configuration's history. Each entry: (tag, label, meaning).
# sweepCSR is deliberately NOT here: config/terapool_spatz4_fpu.mk ships `group_mshr_cfg_runtime ?= 0`,
# so the runtime CSR is opt-in and the shipping RTL is phaseE1. Treating CSR as "current" made every
# shape read ~25% worse than the machine actually is, and put a 3.5x outlier in the headline.
CHAIN = [
    ('sweep',     'opt2',    'drain_from_q=1'),
    ('sweepO3',   'opt3',    '+ bank_publish=1'),
    ('sweepC2',   'C2',      '+ B1b, C3, spill_req_in=0'),
    ('phaseE1',   'E1',      '+ commit-FIFO depth, ROB counter (config only) — **the default today**'),
]
# Opt-in branches. Each is a knob you must turn ON; none is in the default build.
BRANCH = [
    ('sweepCSR',  'CSR',     'cfg_runtime=1 — MSHR off at reset, software enables it'),
    ('bypass',    'BYP',     'hold_subs_burst=1 elaborated (share_b=1 family only)'),
    ('csrbypass', 'CSRBYP',  'hold_subs_burst=1 written by software, with cfg_runtime=1'),
]

STALE = 6 * 3600      # a log untouched this long with no FINAL is abandoned, not running

def final(tag, shape):
    p = f'{T}/mx_{tag}_{shape}_run.log'
    if not os.path.exists(p): return None
    t = None
    with open(p, 'rb') as fh:
        for ln in fh:
            if b'[FPU FINAL]' in ln:
                m = re.search(rb'over (\d+)', ln)
                if m: t = int(m.group(1))
    if t: return t
    # No FINAL. Three different things look alike here and must not be conflated:
    #   - live arm, still producing periods            -> 'run'
    #   - arm that died or was killed mid-benchmark    -> 'inc'
    #   - log that never reached the benchmark at all  -> None (treated as "not run")
    # The opt2 logs are all the third case: they were truncated when that phase was cleaned up, so
    # opt2 numbers are recovered from its generated doc instead (see doccol below).
    with open(p, 'rb') as fh:
        if b'[FPU] bench' not in fh.read(): return None
    fresh = (datetime.datetime.now().timestamp() - os.path.getmtime(p)) < STALE
    return 'run' if fresh else 'inc'


def wall(tag, shape):
    """Wall-clock + simulation speed for one arm, from the sidecar written by wallclock.sh.

    Speed is NOT a property of the shape -- it is dominated by how many sims shared the machine.
    The same four-arm bypass batch measured 8.9 / 5.8 / 4.1 cyc/s purely from contention. So a
    cyc/s figure is only meaningful next to its wall time, and estimated ones are marked.
    """
    f = f'{T}/_wall_{tag}_{shape}.txt' if shape else f'{T}/_wall_{tag}.txt'
    if not os.path.exists(f):
        f2 = f'{T}/_wall_{tag}.txt'
        if not os.path.exists(f2): return None
        f = f2
    d = {}
    for ln in open(f):
        if ln.startswith('#') or '=' not in ln: continue
        k, v = ln.strip().split('=', 1); d[k] = v
    if 'cyc_per_s' not in d: return None
    return dict(cps=float(d['cyc_per_s']), wall=int(d.get('wall_s', 0)),
                est=d.get('estimated') == '1')

def doccol(path, idx):
    """One numeric column, keyed by shape, out of a generated results table."""
    out = {}
    if not os.path.exists(path): return out
    for ln in open(path):
        c = [x.strip() for x in ln.split('|')]
        if len(c) <= idx or not re.fullmatch(r'\d+x\d+x\d+', c[1] if len(c) > 1 else ''): continue
        v = c[idx].replace(',', '').replace('*', '').strip()
        if v.isdigit(): out[c[1]] = int(v)
    return out

shapes = [s.strip() for s in open(f'{T}/sweep_shapes.txt') if s.strip()]
base   = doccol(CSRDOC, 7)                                   # `baseline cyc`
opt2   = doccol(f'{MAIN}/docs/benchmarks/gemm_results_mshr_ppa.md', 12)   # `new cyc`
COLS   = CHAIN + BRANCH
rows   = []
for s in shapes:
    M, N, P = map(int, s.split('x'))
    ideal = M * N * P // 1024
    vals  = {tag: final(tag, s) for tag, _, _ in COLS}
    if vals.get('sweep') is None and s in opt2: vals['sweep'] = opt2[s]
    done  = {k: v for k, v in vals.items() if isinstance(v, int)}
    # CURRENT is the LATEST CHAIN phase that produced a result -- what this shape does on the RTL as
    # it stands. BEST is the minimum over every arm ever run, which is a different question and often
    # points at a SUPERSEDED phase (opt2 wins 6 shapes). Reporting only the minimum would read as
    # "we can hit this today", which is false for anything whose best is not its current.
    cur = curtag = None
    for tag, _, _ in CHAIN:
        if isinstance(vals.get(tag), int): cur, curtag = vals[tag], tag
    bt = min(done, key=done.get) if done else None
    w = wall(curtag, s) if curtag else None
    rows.append(dict(shape=s, ideal=ideal, base=base.get(s), vals=vals, wall=w,
                     cur=cur, curtag=curtag, best=done.get(bt), besttag=bt,
                     dbase=(100.0 * (cur - base[s]) / base[s]) if (cur and base.get(s)) else None,
                     eff=(100.0 * ideal / cur) if cur else None,
                     befff=(100.0 * ideal / done[bt]) if bt else None))
rows.sort(key=lambda r: -(r['eff'] or 0))

def fmt(v):
    if v is None:  return '—'
    if v == 'run': return '_run_'
    if v == 'inc': return '_inc_'
    return f'{v:,}'

L = []
L.append('# GEMM shape status — every shape, every phase, side by side\n')
L.append(f'Generated {datetime.datetime.now():%Y-%m-%d %H:%M}. '
         '**Re-runnable**: `python3 scripts/gen_shape_status.py`.\n')
L.append("""
The other `gemm_results_*.md` files are a **chain**: each measures one phase against the phase
immediately before it. That is the right way to attribute a change, but it means answering "where
does this shape stand now?" takes six files and some arithmetic. This file is the transpose —
shapes down, phases across — and it is generated from the same `[FPU FINAL]` lines, so it cannot
drift from them.

`_run_` means the arm is still running and has produced no FINAL; `_inc_` means it reached the
benchmark but died or was killed before one. Neither is a result. `—` means that arm was never run
for that shape — the `BYP` and `CSRBYP` columns exist only for the four `128x*x512` shapes, where
`share_b = 1` makes B private and a burst MSHR entry can never find a second subscriber.

**Efficiency is `ideal / actual`**, `ideal = M·N·P / 1024`. Not the testbench's `[FPU] util`
counter, which measures lane occupancy and is not conserved across runs of identical work.
""")
L.append('## Phases\n')
L.append('The chain — the default build\'s history, each step adding to the one above:\n')
L.append('| column | what it adds |')
L.append('|---|---|')
for _, lab, meaning in CHAIN:  L.append(f'| `{lab}` | {meaning} |')
L.append('')
L.append("""Opt-in branches. **None of these is in the default build** — each is a knob you turn on,
so their columns are alternatives to `current`, not successors to it:
""")
L.append('| column | what it is |')
L.append('|---|---|')
for _, lab, meaning in BRANCH: L.append(f'| `{lab}` | {meaning} |')
L.append('')

LAB = {t: l for t, l, _ in COLS}
L.append('## Current status\n')
L.append("""**`current`** is the latest phase of the **default build** (`group_mshr_cfg_runtime = 0`) — what
you get today without turning anything on. The `CSR`, `BYP` and `CSRBYP` columns are **opt-in
alternatives**, not later states: a number there is what that shape would do *if you enabled that
knob*, and it is frequently worse.

**`best`** is the minimum over every arm ever run. Where it differs from `current` the best often
sits on a **superseded** phase, so it is not performance you can have today without reverting
something — treat a large gap as a regression to explain, not as headroom.

Sorted by current efficiency, best first.
""")
hdr = ['M×N×P', 'ideal', 'baseline'] + [lab for _, lab, _ in COLS] + \
      ['**current**', 'from', '**eff**', '**Δ vs base**', 'wall', 'cyc/s', 'best', 'from']
L.append('| ' + ' | '.join(hdr) + ' |')
L.append('|' + '---|' * 3 + '---:|' * len(COLS) + '---:|:--|---:|---:|---:|---:|---:|:--|')
for r in rows:
    gap = r['best'] and r['cur'] and r['best'] < r['cur']
    d   = r['dbase']
    cells = [r['shape'], f"{r['ideal']:,}", fmt(r['base'])] + \
            [fmt(r['vals'][tag]) for tag, _, _ in COLS] + \
            [f"**{r['cur']:,}**" if r['cur'] else '—',
             LAB.get(r['curtag'], '—'),
             f"**{r['eff']:.1f}%**" if r['eff'] else '—',
             ('—' if d is None else f"**{d:+.1f}%**"),
             ('—' if not r['wall'] else f"{r['wall']['wall']//60}m"),
             ('—' if not r['wall'] else f"{r['wall']['cps']:.1f}{'*' if r['wall']['est'] else ''}"),
             (f"{r['best']:,}" if gap else '=') if r['best'] else '—',
             LAB.get(r['besttag'], '—') if gap else '']
    L.append('| ' + ' | '.join(cells) + ' |')
L.append('')
L.append("""`Δ vs base` is `current` against the 2026-08-03 pre-campaign baseline in `gemm_results.md`.
**Negative is faster.** It bundles every change since that date, so it is a "where did we end up"
number, not an attribution — for what any single phase cost or bought, use that phase's own file.

`wall` and `cyc/s` are the wall-clock runtime and simulation speed of the `current` arm.
**Speed is not a property of the shape** — it is dominated by how many simulations shared the
machine, and the same four-arm batch has measured 8.9 / 5.8 / 4.1 cyc/s from contention alone.
A `*` marks a value estimated from file mtimes rather than measured; those overstate wall time
(the build log is touched at compile end, not at sim start) and so understate cyc/s.

`=` in the `best` column means current *is* the best ever measured for that shape.
""")

# ---- summary. MEDIAN and a split, never a bare mean: one +252% arm drags the CSR mean to +14%
# while 18 of 21 sit under +5%, and a bare mean has already misled this campaign three times.
def med(a):
    a = sorted(a)
    if not a: return None
    h = len(a) // 2
    return a[h] if len(a) % 2 else (a[h-1] + a[h]) / 2

comp = [r for r in rows if r['cur']]
L.append('## Summary\n')
L.append(f'- **{len(comp)} of {len(rows)} shapes** have a result on a chain phase.')
if comp:
    effs = [r['eff'] for r in comp]
    L.append(f"- Current efficiency: median **{med(effs):.1f}%**, "
             f"range {min(effs):.1f}%–{max(effs):.1f}%.")
    at = {}
    for r in comp: at[r['curtag']] = at.get(r['curtag'], 0) + 1
    L.append('- Current result comes from: ' +
             ', '.join(f'`{LAB[k]}` ×{v}' for k, v in sorted(at.items(), key=lambda kv: -kv[1])) + '.')
    ds  = [r['dbase'] for r in comp if r['dbase'] is not None]
    imp = [r for r in comp if r['dbase'] is not None and r['dbase'] < 0]
    if ds:
        L.append(f'- **vs the 2026-08-03 baseline: median {med(ds):+.1f}%** '
                 f'(negative is faster), range {min(ds):+.1f}% to {max(ds):+.1f}%. '
                 f'**{len(imp)} of {len(ds)}** shapes are faster, {len(ds)-len(imp)} slower.')
        wins = sorted((r for r in comp if r['dbase'] is not None), key=lambda r: r['dbase'])
        L.append('  - biggest gains: ' +
                 ', '.join(f"`{r['shape']}` {r['dbase']:+.1f}%" for r in wins[:3]) + '.')
        L.append('  - biggest regressions: ' +
                 ', '.join(f"`{r['shape']}` {r['dbase']:+.1f}%" for r in reversed(wins[-3:])) + '.')
    csrd = [(r, 100*(r['vals']['sweepCSR']-r['cur'])/r['cur'])
            for r in comp if isinstance(r['vals'].get('sweepCSR'), int)]
    if csrd:
        ds = sorted(d for _, d in csrd)
        h = len(ds)//2
        L.append(f"- Enabling the runtime CSR (`CSR`) costs a median **{(ds[h] if len(ds)%2 else (ds[h-1]+ds[h])/2):+.2f}%** "
                 f"over {len(ds)} shapes, but the spread is what matters: "
                 + ', '.join(f"`{r['shape']}` {d:+.1f}%" for r, d in sorted(csrd, key=lambda x:-x[1])[:3]) + '.')
    reg = sorted((r for r in comp if r['best'] and r['best'] < r['cur']),
                 key=lambda r: -(r['cur'] / r['best']))
    if reg:
        L.append(f'- **{len(reg)} shapes are slower now than their best-ever arm.** Largest gaps: ' +
                 ', '.join(f"`{r['shape']}` {r['cur']/r['best']:.2f}× "
                           f"({LAB[r['curtag']]} {r['cur']:,} vs {LAB[r['besttag']]} {r['best']:,})"
                           for r in reg[:4]) + '.')
    byp = [r for r in rows if isinstance(r['vals'].get('bypass'), int)]
    if byp:
        L.append('- Burst bypass (`BYP`), on the `share_b = 1` family: ' +
                 ', '.join(f"`{r['shape']}` {100*(r['vals']['bypass']-r['cur'])/r['cur']:+.1f}% vs current"
                           for r in byp) + '.')
L.append('')
L.append('Generated from `[FPU FINAL]` in the per-arm run logs. Re-run the script after any new arm '
         'lands rather than editing this table by hand.')

open(OUT, 'w').write('\n'.join(L) + '\n')
print(f'wrote {OUT}: {len(rows)} shapes, {len(comp)} with a completed arm')
