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
TSV  = f'{MAIN}/docs/benchmarks/gemm_results_vs_nofeature.tsv'
SB1  = {'128x128x512', '128x256x512', '128x512x512', '128x1024x512'}

def fin(p):
    if not os.path.exists(p): return None
    d = open(p, 'rb').read()
    m = re.findall(rb'\[FPU FINAL\].*?over (\d+) benchmark', d)
    if m: return int(m[-1])
    return 'run' if b'[FPU] bench' in d else None

# ---- desync-timeout-trap detector -------------------------------------------------------------
# A group whose own 16 cores drift apart loses every intra-group merge partner, so each remote
# burst load waits out the full hold window and TIMES OUT instead of merging. That is ~12x slower
# and self-reinforcing, and the barrier then serialises the fleet behind the straggler. Two arms
# of one shape at one config can differ by >1.9x purely on whether this fired, so a cycle count
# quoted without checking it is not a point estimate.
#
# `mshr_timeout=+N` is per-1000-cycle-window and is 0 in a healthy run (single digits total).
# The alarm is SUSTAINED nonzero, not the total: a brief spike at a phase change is normal.
TRAP_RUN = 10          # consecutive windows with a timeout before we call it trapped

# Both counters are per-1000-cycle-window deltas on the [FPU] line. Only the `bench` lines are
# summed: the `pre` phase is boot and data-init, which is NOT part of the measured cycle count and
# differs structurally between the arms (see the pre-phase note emitted below the table).
_CNT = re.compile(rb'^\[FPU\] (bench|pre) .*?mshr_timeout=\+(\d+) bankfull_bypass=\+(\d+)', re.M)

def diag(p):
    """-> dict(to, bfb, run, trapped, pre_to, pre_bfb) or None if no log.

    to   MSHR hold-window timeouts: a request found no merge partner and waited out the whole
         window before issuing.  0 in a healthy run -- sustained nonzero is the desync trap.
    bfb  bankfull bypasses: the target MSHR bank had no free way, so the request skipped the MSHR
         entirely.  Uncoalesced traffic straight to the NoC -- the capacity-pressure counter.
    """
    if not os.path.exists(p): return None
    d = open(p, 'rb').read().replace(b'\n# ', b'\n')     # Questa prefixes every line with '# '
    m = _CNT.findall(d)
    if not m: return None
    b = [(int(t), int(f)) for ph, t, f in m if ph == b'bench']
    pre = [(int(t), int(f)) for ph, t, f in m if ph == b'pre']
    best = cur = 0
    for t, _ in b:
        cur = cur + 1 if t else 0
        best = max(best, cur)
    return dict(to=sum(t for t, _ in b), bfb=sum(f for _, f in b), run=best,
                trapped=best >= TRAP_RUN,
                pre_to=sum(t for t, _ in pre), pre_bfb=sum(f for _, f in pre))

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
                     latest=fin(f'{T}/mx_latest_{s}_run.log'),
                     dflt_trap=diag(f'{T}/mx_dflt_{s}_run.log'),
                     latest_trap=diag(f'{T}/mx_latest_{s}_run.log')))
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
L.append('to/bfb   = MSHR diagnostics, summed over the BENCHMARK window only (perf debug):')
L.append('             to  hold-window TIMEOUTS -- the request found no merge partner and waited')
L.append('                 out the whole window before issuing.  Healthy = 0.')
L.append('            bfb  BANKFULL BYPASSES -- the target MSHR bank had no free way, so the')
L.append('                 request skipped the MSHR: uncoalesced traffic straight to the NoC.')
L.append('                 This is the capacity-pressure counter; healthy = 0.')
L.append('!        = DESYNC-TIMEOUT TRAP fired in that arm: >=10 consecutive 1000-cycle windows')
L.append('           with mshr_timeout>0.  The group lost its intra-group merge partners, so every')
L.append('           remote load waits out the full hold window instead of merging (~12x slower,')
L.append('           self-reinforcing) and the barrier serialises the fleet behind it.  A flagged')
L.append('           cycle count is NOT a point estimate -- the same config can run ~1.9x faster.')
L.append('')
hdr = (f"{'shape':<15}{'floor':>9}{'baseline':>10}{'base%':>7}"
       f"{'dflt':>10}{'dflt%':>7}{'spdup':>7} {'to/bfb':>11}"
       f"{'latest':>10}{'lat%':>7}{'spdup':>7} {'to/bfb':>11}" + "  lim")
L.append(hdr)
L.append('-' * len(hdr))

def flag(t):
    return '!' if t and t['trapped'] else ' '

def tb(t):
    return f"{t['to']}/{t['bfb']}" if t else '-'

sd = sl = 0
for r in rows:
    L.append(f"{r['shape']:<15}{r['floor']:>9,}{r['base']:>10,}{100*r['floor']/r['base']:>7.1f}"
             f"{cyc(r['dflt']):>10}{pct(r['floor'], r['dflt']):>7}{spd(r['base'], r['dflt']):>7}"
             f"{flag(r['dflt_trap'])}{tb(r['dflt_trap']):>11}"
             f"{cyc(r['latest']):>10}{pct(r['floor'], r['latest']):>7}{spd(r['base'], r['latest']):>7}"
             f"{flag(r['latest_trap'])}{tb(r['latest_trap']):>11}"
             f"  {r['lim']}")
L.append('-' * len(hdr))

# ---- trap summary: name every flagged arm explicitly, so it can never be read as background ----
_tr = [(r['shape'], nm, r[f'{nm}_trap'])
       for r in rows for nm in ('dflt', 'latest') if r[f'{nm}_trap'] and r[f'{nm}_trap']['trapped']]
if _tr:
    L.append('DESYNC-TIMEOUT TRAP fired in the following arms -- do not quote these as point '
             'estimates:')
    for sh, nm, d in sorted(_tr, key=lambda x: -x[2]['run']):
        L.append(f"   {sh:<15} {nm:<7} {d['to']:>6} timeouts, {d['bfb']:>6} bankfull bypasses, "
                 f"longest sustained run {d['run']} windows")
    L.append('')

# ---- pre-benchmark asymmetry ------------------------------------------------------------------
# Not a defect, but it must not be rediscovered as one: at cfg_runtime=1 the MSHR is inert until
# software writes the CSRs, so `latest` sees NO MSHR activity during boot/data-init while `dflt`,
# configured from reset, does. The measured window is unaffected (these are `pre` counters), but
# the two arms therefore ENTER the benchmark from different MSHR/cache states -- a candidate
# mechanism for the run-to-run spread between two otherwise identical configurations.
_pd = sum(r['dflt_trap']['pre_bfb'] for r in rows if r['dflt_trap'])
_pl = sum(r['latest_trap']['pre_bfb'] for r in rows if r['latest_trap'])
L.append(f'PRE-BENCHMARK (boot/data-init, OUTSIDE every number above): dflt logs {_pd:,} bankfull')
L.append(f'bypasses across the sweep, latest logs {_pl:,}. At cfg_runtime=1 the MSHR is inert until')
L.append('software writes the CSRs, so latest enters the benchmark cold and dflt enters warm. This')
L.append('is why dflt arms carry thousands of pre-window [CMS WARN] STUCK_REQ lines and latest arms')
L.append('do not -- benign, but it is a real difference in starting state between the two arms.')
L.append('')

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

# ---- TSV for pasting straight into a Google Doc / Sheets table -------------------------------
# Tab-separated, header row, nothing else -- no legend, no rule lines, no ASCII art, because any
# of those become stray rows when the paste is converted to a table.
# Numbers carry NO thousands separators: "67,860" pastes as text and silently breaks any later
# arithmetic, whereas 67860 is parsed as a number. Percentages keep their % for readability.
# In Docs: paste, select the pasted block, Format > Convert > Convert text to table (or paste
# into Sheets first, then copy that range into the Doc).
def tsv_num(v):  return str(v) if isinstance(v, int) else ('running' if v == 'run' else '')
def tsv_pct(fl, v): return f'{100*fl/v:.1f}%' if isinstance(v, int) else ''
def tsv_spd(b, v):  return f'{b/v:.2f}' if isinstance(v, int) else ''

TH = ['M', 'N', 'P', 'Ideal cycles', 'Baseline (no MSHR/burst)', 'Baseline eff.',
      'Default', 'Default eff.', 'Default speedup',
      'Runtime CSR', 'Runtime CSR eff.', 'Runtime CSR speedup', 'Limited by',
      'Default MSHR timeouts', 'Default bankfull bypass',
      'Runtime CSR MSHR timeouts', 'Runtime CSR bankfull bypass', 'Desync trap']
TL = ['\t'.join(TH)]
for r in rows:
    M, N, P = r['shape'].split('x')          # split so each dimension sorts numerically in a table
    tp = [nm for nm in ('dflt', 'latest') if r[f'{nm}_trap'] and r[f'{nm}_trap']['trapped']]
    d, l = r['dflt_trap'], r['latest_trap']
    TL.append('\t'.join([
        M, N, P, str(r['floor']), str(r['base']), f"{100*r['floor']/r['base']:.1f}%",
        tsv_num(r['dflt']),   tsv_pct(r['floor'], r['dflt']),   tsv_spd(r['base'], r['dflt']),
        tsv_num(r['latest']), tsv_pct(r['floor'], r['latest']), tsv_spd(r['base'], r['latest']),
        r['lim'] if r['lim'] in ('A', 'B') else '—',
        str(d['to']) if d else '', str(d['bfb']) if d else '',
        str(l['to']) if l else '', str(l['bfb']) if l else '',
        ', '.join(tp) if tp else '']))
open(TSV, 'w').write('\n'.join(TL) + '\n')

print(f'wrote {TSV}')
print(f'wrote {OUT}  ({sum(1 for r in rows if isinstance(r["dflt"], int))}/{len(rows)} dflt, '
      f'{sum(1 for r in rows if isinstance(r["latest"], int))}/{len(rows)} latest)')
