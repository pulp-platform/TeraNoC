#!/usr/bin/env python3
"""Score the [SPOT] words an fp16 sp-fmatmul run prints against a host-computed golden.

WHY THIS EXISTS. sp-fmatmul's device verify sums each C row in scalar FP and wedges core 0 in
the epilogue, so every perf run ships MATMUL_VERIFY=0 -- i.e. with no correctness signal at all.
For the fp32 kernel that was tolerable (host replay had validated it). For a NEW fp16 kernel it
is not: a kernel that computes garbage twice as fast still wins a speed sweep. MATMUL_SPOTCHECK=1
makes core 0 print raw 32-bit words of C per group using ordinary integer loads -- no FP register,
no FP-LSU, no accumulator writeback, so it cannot reproduce the wedge -- and this scores them.

TOLERANCE. The device accumulates each C element over N terms in fp16 (11-bit mantissa,
eps = 4.9e-4), so it is legitimately ~sqrt(N)*eps away from the exactly-rounded golden. A
bit-exact compare would FAIL a correct kernel. We score relative error and flag only deviations
no amount of fp16 rounding explains.

The golden is reproduced from gen_data.py's fixed seeds (np 42 / torch 42) in the same call
order, which was verified to match the checked-in data_gemm.h element for element.
"""
import argparse, re, struct, sys

def f16(bits):
    return struct.unpack('<e', struct.pack('<H', bits & 0xFFFF))[0]

def parse_spot(path):
    # QuestaSim prefixes EVERY transcript line with '# '; VCS does not. Normalise before
    # matching or a Questa log silently yields nothing.
    pat = re.compile(r'\[SPOT\]\s+g=\s*(\d+)\s+row=\s*(\d+)\s+'
                     r'w0=([0-9a-fA-F]+)\s+w1=([0-9a-fA-F]+)\s+'
                     r'w2=([0-9a-fA-F]+)\s+w3=([0-9a-fA-F]+)')
    out = {}
    with open(path, 'rb') as fh:
        for raw in fh:
            if raw.startswith(b'# '):
                raw = raw[2:]
            m = pat.search(raw.decode('utf-8', 'replace'))
            if not m:
                continue
            g, row = int(m.group(1)), int(m.group(2))
            vals = []
            for i in (3, 4, 5, 6):                 # little-endian: low half = even column
                w = int(m.group(i), 16)
                vals += [f16(w), f16(w >> 16)]
            out[g] = (row, vals)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--json', required=True, help="the app's script/matmul.json")
    ap.add_argument('--rel-tol', type=float, default=0.05,
                    help='relative tolerance (default 0.05). fp16 accumulation over N=512 '
                         'terms is legitimately a few percent off the fp32 golden.')
    a = ap.parse_args()

    import torch, numpy as np
    txt = re.sub(r'//.*', '', open(a.json).read())
    cfg = {k: v for k, v in re.findall(r'(\w+)\s*:\s*"?([\w.]+)"?', txt)}
    M, N, P = int(cfg['M']), int(cfg['N']), int(cfg['P'])
    if int(cfg['prec']) != 16:
        sys.exit(f"matmul.json has prec={cfg['prec']}; this checker is for prec=16")

    spots = parse_spot(a.log)
    if not spots:
        sys.exit('no [SPOT] lines found -- was the ELF built with -DMATMUL_SPOTCHECK=1?')

    # Same seeds and same call order as gen_data.py (verified against data_gemm.h).
    np.random.seed(42); torch.manual_seed(42)
    A = torch.randn((M, N), requires_grad=False, dtype=torch.float16)
    B = torch.randn((N, P), requires_grad=False, dtype=torch.float16)
    _ = torch.randn((M, P), requires_grad=False, dtype=torch.float16)   # C: alpha=0, unused

    worst, bad = 0.0, []
    print(f'{"grp":>4} {"row":>5} {"col":>4} {"device":>12} {"golden":>12} {"rel":>9}')
    for g in sorted(spots):
        row, vals = spots[g]
        gold = (A[row].float() @ B.float())          # exactly-rounded reference row
        gmax = 0.0
        for col, dv in enumerate(vals):
            gv = float(gold[col])
            den = max(abs(gv), 1e-3)
            rel = abs(dv - gv) / den
            gmax = max(gmax, rel)
            if col < 2 or rel > a.rel_tol:
                flag = '  <-- FAIL' if rel > a.rel_tol else ''
                print(f'{g:4d} {row:5d} {col:4d} {dv:12.4f} {gv:12.4f} {rel:9.4f}{flag}')
        worst = max(worst, gmax)
        if gmax > a.rel_tol:
            bad.append((g, gmax))

    print(f'\ngroups sampled: {len(spots)}   worst relative error: {worst:.4f} '
          f'(tolerance {a.rel_tol})')
    if bad:
        print('FAIL - groups outside tolerance: ' +
              ', '.join(f'g{g} ({e:.3f})' for g, e in bad))
        print('A single bad group points at that group desynchronising or at a bank-hash '
              'mistake concentrating its traffic; ALL groups bad points at the kernel itself.')
        sys.exit(1)
    print('PASS - every sampled group is within fp16 accumulation error of the golden.')

if __name__ == '__main__':
    main()
