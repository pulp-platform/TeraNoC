#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Merge two `parse_opcodes` outputs (riscv_instr.sv or encoding.h) into one
# superset so a parameterized Snitch can host cores with mutually exclusive
# ISA extensions (Xpulp XOR RVV). The Xpulp PV_* and RVV V* ops share the
# OP-V space, so parse_opcodes refuses their union in one pass; each table is
# generated separately (internally collision-free) and the named symbols are
# unioned here. Where a small-float symbol is defined in both inputs the RVV
# value wins, except FLB/FSB, which stay at the default scalar funct3=000
# (the value the compiler, GVSoC and upstream emit); the RVV byte-load alias
# is resolved in the RVV-gated decoder, not here. Run for both files from the
# same inputs so HW decode literals and assembler bytes stay in lockstep.
#
# CONTRACT: the merged riscv_instr.sv is the SINGLE opcode source for TWO
# decoders -- snitch.sv (main + RVV-override + V-CSR-override casez) and
# spatz_fpu_sequencer.sv (FP-LSU casez). funct3=000 LOAD-FP/STORE-FP (FLB/FSB)
# aliases the RVV byte mem ops (VLE8_V/VSE8_V/VLUXEI8/...), so FLB/FSB are
# scalar-only and MUST stay excluded from the Spatz sequencer (FLH/FLW/FLD,
# funct3 001/010/011, do not alias). Re-check any encoding edit against BOTH
# decoders and BOTH a scalar and a Spatz config.
#
# Usage:  merge_opcode_tables.py <default.{sv,h}> <rvv.{sv,h}>  (order matters)

import re
import sys

# Symbols where the DEFAULT encoding wins over RVV (FLB/FSB; see header).
DEFAULT_WINS = {'FLB', 'FSB'}

LOCALPARAM_RE = re.compile(
    r'^\s*localparam\s+logic\s+\[\d+:\d+\]\s+(\w+)\s*=\s*(.+?);\s*$')


def log(msg):
    sys.stderr.write(msg + '\n')


# ----------------------------------------------------------- SystemVerilog
def merge_sv(default_path, rvv_path):
    def collect(path):
        out = []
        for line in open(path).read().splitlines():
            m = LOCALPARAM_RE.match(line)
            if m:
                out.append(
                    (m.group(1), m.group(2), line, '[11:0]' in line))
        return out

    table, order = {}, []
    for name, value, line, is_csr in collect(default_path):
        if name not in table:
            order.append(name)
        table[name] = (value, line, is_csr)

    resolved_rvv, kept_default = [], []
    for name, value, line, is_csr in collect(rvv_path):
        if name not in table:
            table[name] = (value, line, is_csr)
            order.append(name)
        elif table[name][0] != value:
            if name in DEFAULT_WINS:
                kept_default.append(name)
            else:
                table[name] = (value, line, is_csr)
                resolved_rvv.append(name)

    instr = [table[n][1] for n in order if not table[n][2]]
    csr = [table[n][1] for n in order if table[n][2]]
    out = ['/* Auto-generated Xpulp+RVV opcode superset, merged by',
           ' * scripts/merge_opcode_tables.py -- see that script for the',
           ' * FLB/FSB scalar-vs-RVV decode contract. Do not edit by hand. */',
           'package riscv_instr;'] + instr + \
        ['  /* CSR Addresses */'] + csr + ['endpackage']
    sys.stdout.write('\n'.join(out) + '\n')
    log(f'[merge:sv] {len(order)} localparams; {len(resolved_rvv)} '
        f'conflicts -> RVV; kept default for {sorted(kept_default)}')


# ----------------------------------------------------------------- encoding.h
DEFINE_RE = re.compile(r'^#define (MATCH|MASK)_(\w+)\s+(0x[0-9a-fA-F]+)\s*$')
DECL_RE = re.compile(r'^DECLARE_INSN\((\w+),')


def merge_h(default_path, rvv_path):
    def collect(path):
        lines = open(path).read().splitlines()
        match, mask, decl = {}, {}, {}
        for ln in lines:
            m = DEFINE_RE.match(ln)
            if m:
                tgt = match if m.group(1) == 'MATCH' else mask
                tgt[m.group(2)] = m.group(3)
                continue
            d = DECL_RE.match(ln)
            if d:
                decl[d.group(1).upper()] = ln
        return lines, match, mask, decl

    dlines, dmatch, dmask, ddecl = collect(default_path)
    _, rmatch, rmask, rdecl = collect(rvv_path)

    # which ops conflict (MATCH or MASK differ) and how to resolve
    common = set(dmatch) & set(rmatch)
    conflicts = {x for x in common
                 if dmatch[x] != rmatch[x] or dmask.get(x) != rmask.get(x)}
    # replace with RVV value
    to_rvv = {x for x in conflicts if x not in DEFAULT_WINS}
    # add (e.g. the V* ops)
    rvv_only = sorted(set(rmatch) - set(dmatch))

    # rewrite default lines, swapping the MATCH/MASK value for to_rvv ops
    out = []
    for ln in dlines:
        m = DEFINE_RE.match(ln)
        if m and m.group(2) in to_rvv:
            kind, name = m.group(1), m.group(2)
            newval = (rmatch if kind == 'MATCH' else rmask)[name]
            out.append(f'#define {kind}_{name} {newval}')
        else:
            out.append(ln)

    # build the RVV-only additions (MATCH, MASK, DECLARE_INSN) and splice
    # before final #endif
    add = []
    for x in rvv_only:
        add.append(f'#define MATCH_{x} {rmatch[x]}')
        if x in rmask:
            add.append(f'#define MASK_{x} {rmask[x]}')
        if x.upper() in rdecl:
            add.append(rdecl[x.upper()])
    last_endif = max(i for i, l in enumerate(out) if l.strip() == '#endif')
    header = '/* --- RVV superset additions (merge_opcode_tables.py) --- */'
    out = out[:last_endif] + [header] + add + out[last_endif:]

    sys.stdout.write('\n'.join(out) + '\n')
    log(f'[merge:h] {len(dmatch)} default + {len(rvv_only)} rvv-only ops; '
        f'{len(to_rvv)} conflicts -> RVV; '
        f'kept default for {sorted(conflicts & DEFAULT_WINS)}')


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: merge_opcode_tables.py <default.{sv,h}> '
                 '<rvv.{sv,h}>')
    head = open(sys.argv[1]).read(4096)
    if 'localparam' in head:
        merge_sv(sys.argv[1], sys.argv[2])
    elif '#define' in head or 'RISCV_CSR_ENCODING_H' in head:
        merge_h(sys.argv[1], sys.argv[2])
    else:
        sys.exit('cannot detect format (expected SystemVerilog '
                 'localparams or C #defines)')


if __name__ == '__main__':
    main()
