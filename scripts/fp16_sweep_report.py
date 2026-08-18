#!/usr/bin/env python3
"""Collect the fp16 burst-gate sweep into one table.

EFFICIENCY. Always ideal/actual, never the testbench's [FPU] util counter (that counter is lane
OCCUPANCY and has inverted a real ranking before). The denominator differs by PRECISION, which is
the whole point of the experiment:

    fp32:  1024 MAC/cycle at 4x4  (256 cores x 4 FPUs x 1 fp32 lane)
    fp16:  2048 MAC/cycle at 4x4  (the FPU is 128 b wide; 8 fp16 lanes vs 4 fp32)

so ideal_cycles = M*N*P / peak_mac. Using the fp32 denominator for an fp16 arm would report a
correct kernel as 170% efficient.
"""
import re, sys, os, argparse

ARMS = [
    ("A_fp32ref", "build_fp32ref", 32, "fp32 baseline, burst gate OFF"),
    ("B_fp16nb",  "build_fp16nb",  16, "fp16, burst gate OFF  (arithmetic only)"),
    ("C_fp16b",   "build_fp16b",   16, "fp16, burst gate ON   (+ burst recovery)"),
    ("D_inert",   "build_inert",   32, "fp32, burst gate ON   (must equal A)"),
]
PEAK = {32: 1024, 16: 2048}

def norm(b):
    return b[2:] if b.startswith(b'# ') else b     # QuestaSim prefixes every line with '# '

def scan(path):
    d = dict(cycles=None, done=False, fatal=None, dropped=0,
             timeout=0, bfb=0, amerge=None, bmerge=None, last_cyc=None,
             pre_cyc=None, in_bench=False)
    if not os.path.exists(path):
        return d
    with open(path, 'rb') as fh:
        for raw in fh:
            ln = norm(raw).decode('utf-8', 'replace')
            m = re.search(r'The execution took\s+(\d+)\s+cycles', ln)
            if m:
                d['cycles'] = int(m.group(1)); d['done'] = True
            if 'BURST DROPPED' in ln:
                d['dropped'] += 1
            if re.search(r'\bFatal\b|Error:', ln) and 'Errors: 0' not in ln:
                d['fatal'] = ln.strip()[:100]
            # Progress: [FPU] bench only appears once the TIMED region opens, which is tens of
            # thousands of cycles in. Before that the run is in icache warmup and looks
            # identical to 'still elaborating' unless we also read the pre-bench probes.
            m = re.search(r'cyc=(\d+)', ln)
            if m:
                c = int(m.group(1))
                if '[FPU] bench' in ln:
                    d['last_cyc'] = c; d['in_bench'] = True
                elif not d.get('in_bench'):
                    d['pre_cyc'] = c
            for k, pat in (('timeout', r'mshr_timeout=\+?(\d+)'),
                           ('bfb',     r'bankfull_bypass=\+?(\d+)')):
                mm = re.search(pat, ln)
                if mm:
                    d[k] += int(mm.group(1))
            mm = re.search(r'burst\s+merge[^0-9]*([\d.]+)x', ln, re.I)
            if mm:
                d['bmerge'] = float(mm.group(1))
    return d

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--M', type=int, default=512)
    ap.add_argument('--N', type=int, default=512)
    ap.add_argument('--P', type=int, default=512)
    ap.add_argument('--hw', default='hardware')
    a = ap.parse_args()
    macs = a.M * a.N * a.P

    rows = []
    for tag, bd, prec, desc in ARMS:
        r = scan(os.path.join(a.hw, bd, 'transcript'))
        ideal = macs / PEAK[prec]
        eff = (ideal / r['cycles'] * 100) if r['cycles'] else None
        rows.append((tag, prec, desc, r, ideal, eff))

    print(f"GEMM {a.M}x{a.N}x{a.P}  ({macs/1e6:.1f} M MAC)   4x4, 256 cores\n")
    hdr = f"{'arm':<10} {'prec':>5} {'ideal':>9} {'cycles':>10} {'eff':>7} {'status'}"
    print(hdr); print('-' * len(hdr))
    for tag, prec, desc, r, ideal, eff in rows:
        if r['fatal']:
            st = 'FATAL: ' + r['fatal']
        elif r['done']:
            st = 'done'
        elif r['last_cyc']:
            st = f"in timed region (cyc={r['last_cyc']:,})"
        elif r['pre_cyc']:
            st = f"pre-benchmark warmup (cyc={r['pre_cyc']:,})"
        else:
            st = 'elaborating'
        if r['dropped']:
            st += f"   !! {r['dropped']} BURST DROPPED"
        print(f"{tag:<10} {'fp'+str(prec):>5} {ideal:>9,.0f} "
              f"{(r['cycles'] or 0):>10,} {(f'{eff:.1f}%' if eff else '-'):>7} {st}")

    a_c = next((r['cycles'] for t, _, _, r, _, _ in rows if t == 'A_fp32ref'), None)
    b_c = next((r['cycles'] for t, _, _, r, _, _ in rows if t == 'B_fp16nb'), None)
    c_c = next((r['cycles'] for t, _, _, r, _, _ in rows if t == 'C_fp16b'), None)
    d_c = next((r['cycles'] for t, _, _, r, _, _ in rows if t == 'D_inert'), None)

    print()
    if a_c and b_c:
        print(f"  fp16 arithmetic alone (A->B):   {a_c/b_c:.3f}x")
    if b_c and c_c:
        print(f"  burst recovery       (B->C):   {b_c/c_c:.3f}x")
    if a_c and c_c:
        print(f"  combined             (A->C):   {a_c/c_c:.3f}x")
    if a_c and d_c:
        verdict = 'INERT (bit-identical behaviour)' if a_c == d_c else \
                  f'NOT INERT -- differs by {d_c - a_c:+,} cycles'
        print(f"  knob inertness on fp32 (A vs D): {verdict}")
    for tag, _, _, r, _, _ in rows:
        if not r['in_bench']:
            continue          # pre-bench counters are icache-warmup noise, not a result
        if r['timeout'] or r['bfb']:
            print(f"  {tag}: mshr_timeout={r['timeout']:,}  bankfull_bypass={r['bfb']:,}"
                  + ("   <- bfb >> timeouts = capacity saturation, check the knobs"
                     if r['bfb'] > 10 * max(r['timeout'], 1) else ""))

if __name__ == '__main__':
    main()
