#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# Decode the [QLP] lines of a qwen-layer ql_proj_skip=1 run (main.c) into the non-linear
# breakdown: the barrier-delimited stages (core 0's timer) and every part's max / mean over cores.
#
#   python3 nonlin_parts.py <transcript> [--tsv]
import re
import sys

STAGES = ['pre-mixer norm: sums of squares (+ rendezvous)', 'pre-mixer norm: reduction (+ rendezvous)',
          'in-proj phase (epilogue only)', 'mixer (skipped)', 'MSHR handover (skipped)',
          'o-proj phase (epilogue only)', 'pre-FFN norm reduction (+ rendezvous)',
          'gate+up phase (epilogue only)', 'MSHR handover (skipped)', 'down phase (epilogue only)']
# layer.h QL_PT_* order
# The rendezvous around each epilogue are in the linear bench's timed region already.
PARTS = ['in: rendezvous before epilogue', 'in: epilogue', 'in: rendezvous after epilogue',
         'op: rendezvous before epilogue', 'op: epilogue', 'op: rendezvous after epilogue',
         'gu: rendezvous before epilogue', 'gu: epilogue', 'gu: rendezvous after epilogue',
         'dn: rendezvous before epilogue', 'dn: epilogue', 'dn: rendezvous after epilogue',
         'in epilogue: 1/rms, conv1d, SiLU (q k v)', 'in epilogue: scatter q k v', 'in epilogue: z',
         'op epilogue: residual', 'op epilogue: pre-FFN sums of squares',
         'gu epilogue: 1/rms on G, U', 'gu epilogue: SwiGLU',
         'pre-mixer norm: sums of squares', 'pre-mixer norm: reduction', 'pre-FFN norm reduction']


def main():
    path, tsv = sys.argv[1], '--tsv' in sys.argv
    hdr, mx, sm = None, None, None
    for raw in open(path, 'rb'):
        ln = raw.decode('latin-1').rstrip('\n')
        ln = re.sub(r'^(# )?(\[UART\] )?', '', ln)
        if ln.startswith('[QLP] v1'):
            hdr = dict(re.findall(r'(\w+)=(\S+)', ln))
        elif ln.startswith('[QLP] max='):
            mx = [int(v, 16) for v in ln.split('=', 1)[1].split(',')]
        elif ln.startswith('[QLP] sum='):
            sm = [int(v, 16) for v in ln.split('=', 1)[1].split(',')]
    if hdr is None or mx is None or sm is None:
        sys.exit('%s: no complete [QLP] record' % path)
    cores = int(hdr['cores'], 16)
    st = [int(v, 16) for v in hdr['st'].split(',')]
    total = sum(st)
    if tsv:
        print('kind\tname\tcycles\tmean')
        for n, v in zip(STAGES, st):
            print('stage\t%s\t%d\t' % (n, v))
        for n, a, b in zip(PARTS, mx, sm):
            print('part\t%s\t%d\t%.0f' % (n, a, b / cores))
        return
    print('rows=%d cores=%d exp=%s  total=%d cycles' % (int(hdr['rows'], 16), cores, hdr['exp'], total))
    print('\nstages (core 0, each ends at a rendezvous)')
    for n, v in zip(STAGES, st):
        print('  %-48s %9d  %5.1f%%' % (n, v, 100.0 * v / total if total else 0))
    print('\nparts (per core: max, mean)')
    for n, a, b in zip(PARTS, mx, sm):
        print('  %-48s %9d %9.0f' % (n, a, b / cores))


if __name__ == '__main__':
    main()
