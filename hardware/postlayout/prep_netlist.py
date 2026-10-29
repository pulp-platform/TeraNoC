#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
"""Prepare a Fusion Compiler netlist of mempool_group_floonoc_wrapper for post-layout simulation.

1. Renames the top to mempool_group_floonoc_wrapper_postlayout, the module the cluster wrapper
   instantiates for group (0,0). The netlist's own top carries the RTL name, which the other 15
   RTL groups use.
2. Prefixes every other netlist module with --prefix. Fusion uniquifies most names, but some come
   out verbatim (e.g. spatz_vsldu) and would replace the RTL module of the same name.
3. Overrides the delay parameters of every SRAM macro instance (--sram-params), so the macros
   simulate zero-delay without editing the vendor models.

Usage: prep_netlist.py <netlist.v[.gz]> <out.v>
Reads the input twice (module names first, then the rewrite), streaming.
"""

import argparse
import gzip
import re
import sys

TOP_RTL = 'mempool_group_floonoc_wrapper'
TOP_PL = 'mempool_group_floonoc_wrapper_postlayout'

MODULE_RE = re.compile(r'^module\s+([A-Za-z_][A-Za-z0-9_$]*)')
# Fusion writes every instance at column 0: "<type> <instance> ( ..."
INST_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_$]*)(\s+)')


def open_text(path, mode='rt'):
    return gzip.open(path, mode) if path.endswith('.gz') else open(path, mode)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('netlist')
    ap.add_argument('out')
    ap.add_argument('--prefix', default='pl_')
    ap.add_argument('--sram-re', default=r'tsn7_l1cache_\w+',
                    help='regex matching SRAM macro cell names')
    ap.add_argument('--sram-params', default='delay_reset=0,delay_racing=0,SRAM_DELAY=0',
                    help='parameter overrides for every SRAM instance; empty to skip')
    args = ap.parse_args()

    modules = set()
    with open_text(args.netlist) as f:
        for line in f:
            m = MODULE_RE.match(line)
            if m:
                modules.add(m.group(1))
    if TOP_RTL not in modules:
        sys.exit(f'prep_netlist: no module {TOP_RTL} in {args.netlist}')

    def new_name(name):
        return TOP_PL if name == TOP_RTL else args.prefix + name

    sram_re = re.compile(r'^(?:' + args.sram_re + r')$')
    overrides = ', '.join(f'.{k}({v})' for k, v in
                          (kv.split('=') for kv in args.sram_params.split(',') if kv))
    n_mod = n_inst = 0
    srams = {}
    with open_text(args.netlist) as f, open(args.out, 'w') as o:
        o.write(f'// Prepared by prep_netlist.py from {args.netlist}\n')
        for line in f:
            m = MODULE_RE.match(line)
            if m:
                line = 'module ' + new_name(m.group(1)) + line[m.end():]
                n_mod += 1
            else:
                m = INST_RE.match(line)
                if m and m.group(1) in modules:
                    line = new_name(m.group(1)) + line[m.end(1):]
                    n_inst += 1
                elif m and overrides and sram_re.match(m.group(1)):
                    line = m.group(1) + f' #({overrides})' + line[m.end(1):]
                    srams[m.group(1)] = srams.get(m.group(1), 0) + 1
            o.write(line)

    print(f'prep_netlist: {n_mod} modules renamed (top -> {TOP_PL}, others prefixed '
          f'{args.prefix!r}), {n_inst} module instances retargeted')
    for cell, n in sorted(srams.items()):
        print(f'prep_netlist: {n:6d} x {cell} with #({overrides})')
    if n_mod != len(modules):
        sys.exit(f'prep_netlist: renamed {n_mod} definitions but found {len(modules)} module names')
    if n_inst < len(modules) - 1:
        sys.exit(f'prep_netlist: only {n_inst} instances for {len(modules) - 1} submodules')


if __name__ == '__main__':
    main()
