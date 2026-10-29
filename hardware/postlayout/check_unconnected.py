#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
"""Prove that no SYNOPSYS_UNCONNECTED net in a netlist feeds logic.

Fusion ties pins it leaves open to SYNOPSYS_UNCONNECTED_<n>: a net with no driver, i.e. Z, i.e. X
at any input that reads it. That is harmless on an output pin, and on a hierarchical input port
that the submodule never uses. Anything else is an X source. VCS reports each such net as IWNF
("Implicit wire has no fanin"), hundreds of thousands of times, which hides a real one.

For every connection that carries a SYNOPSYS_UNCONNECTED net this classifies the pin as
  leaf-output / leaf-input   (direction from the cell's Verilog model, --libs)
  module-output              (port direction in the netlist)
  module-input-unused        (the submodule never reads the floating bits of the port)
  module-input-USED          (it reads at least one of them: an X source)
and exits non-zero if any leaf-input or module-input-USED exists.

Usage: check_unconnected.py <netlist.v> --libs <cell models...>
"""

import argparse
import re
import sys
from collections import Counter, defaultdict

MOD_RE = re.compile(r'^module\s+([A-Za-z_][A-Za-z0-9_$]*)')
DIR_RE = re.compile(r'^\s*(input|output|inout)\s+(?:\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*)?(.*);')
INST_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_$]*)\s+(\\\S+|[A-Za-z_][A-Za-z0-9_$]*)\s*\(')
CONN_RE = re.compile(r'\.([A-Za-z_][A-Za-z0-9_$]*)\s*\(([^()]*)\)')
ID_RE = re.compile(r'\\\S+|[A-Za-z_][A-Za-z0-9_$]*')
# An identifier and its bit or part select, if any ("data_i[17]", "data_i[598:0]").
USE_RE = re.compile(r'(\\\S+|[A-Za-z_][A-Za-z0-9_$]*)(\s*\[\s*(\d+)\s*(?::\s*(\d+)\s*)?\])?')
UNC = 'SYNOPSYS_UNCONNECTED_'


def lib_pin_dirs(paths):
    """{cell: {pin: 'input'|'output'}} from Verilog cell models."""
    dirs = defaultdict(dict)
    cell = None
    for path in paths:
        with open(path, errors='replace') as f:
            for line in f:
                m = MOD_RE.match(line)
                if m:
                    cell = m.group(1)
                    continue
                if cell is None:
                    continue
                m = DIR_RE.match(line)
                if m:
                    for pin in m.group(4).split(','):
                        dirs[cell][pin.strip()] = m.group(1)
                elif line.startswith('endmodule'):
                    cell = None
    return dirs


ALL = -1


def floating_bits_used(expr, rng, uses):
    """True if the submodule reads any port bit that expr ties to an unconnected net."""
    if not uses:
        return False
    if ALL in uses:
        return True
    expr = expr.strip()
    elems = [e.strip() for e in expr[1:-1].split(',')] if expr.startswith('{') else [expr]
    width = abs(rng[0] - rng[1]) + 1 if rng else 1
    if len(elems) != width:
        return True  # cannot map elements to bits: assume the worst
    step = -1 if rng and rng[0] >= rng[1] else 1
    first = rng[0] if rng else 0
    floating = {first + step * i for i, e in enumerate(elems) if e.startswith(UNC)}
    return bool(floating & uses)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('netlist')
    ap.add_argument('--libs', nargs='+', required=True)
    args = ap.parse_args()

    cells = lib_pin_dirs(args.libs)

    # Per module: port direction and range, and which bits of each name its body reads (an index
    # set, or ALL for a use without a bit select). Every connection carrying an unconnected net.
    ports = defaultdict(dict)
    used = defaultdict(lambda: defaultdict(set))
    uncon = []  # (inst_type, pin, expr)

    def note_uses(mod, text):
        for name, sel, hi, lo in USE_RE.findall(text):
            if not sel:
                used[mod][name].add(ALL)
            elif lo:
                a, b = sorted((int(hi), int(lo)))
                used[mod][name].update(range(a, b + 1))
            else:
                used[mod][name].add(int(hi))

    mod = None
    stmt = []
    in_header = False
    with open(args.netlist) as f:
        for line in f:
            m = MOD_RE.match(line)
            if m:
                # The header's port list is not a use of the ports: skip it up to its ';'.
                mod, stmt, in_header = m.group(1), [], ';' not in line
                continue
            if mod is None:
                continue
            if in_header:
                in_header = ';' not in line
                continue
            if line.startswith('endmodule'):
                mod = None
                continue
            stmt.append(line)
            if ';' not in line:
                continue
            # lstrip: a blank line before the first instance would defeat the anchored INST_RE and
            # send the whole instantiation, pin names included, down the 'other statement' path.
            text = ''.join(stmt).lstrip()
            stmt = []
            d = DIR_RE.match(text)
            if d:
                rng = (int(d.group(2)), int(d.group(3))) if d.group(2) else None
                for p in re.sub(r'\s+', '', d.group(4)).split(','):
                    ports[mod][p] = (d.group(1), rng)
                continue
            if text.lstrip().startswith(('wire', 'tri', 'supply')):
                continue
            inst = INST_RE.match(text)
            if inst:
                for pin, expr in CONN_RE.findall(text):
                    note_uses(mod, expr)
                    if UNC in expr:
                        uncon.append((inst.group(1), pin, expr))
            else:
                note_uses(mod, text)

    cls = Counter()
    bad = Counter()
    for itype, pin, expr in uncon:
        if itype in ports:
            direction, rng = ports[itype].get(pin, (None, None))
            if direction != 'input':
                c = 'module-output'
            elif not floating_bits_used(expr, rng, used[itype].get(pin, set())):
                c = 'module-input-unused'
            else:
                c = 'module-input-USED'
                bad[(itype, pin)] += 1
        elif itype in cells:
            c = 'leaf-' + cells[itype].get(pin, 'UNKNOWN-PIN')
            if c != 'leaf-output':
                bad[(itype, pin)] += 1
        else:
            c = 'UNKNOWN-CELL'
            bad[(itype, pin)] += 1
        cls[c] += 1

    for c, n in sorted(cls.items()):
        print(f'check_unconnected: {n:8d} {c}')
    for (itype, pin), n in bad.most_common(30):
        print(f'check_unconnected: X SOURCE {n:6d} x {itype}.{pin}')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
