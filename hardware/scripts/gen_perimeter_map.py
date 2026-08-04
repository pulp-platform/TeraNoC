#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Derive the perimeter placement of the L2 channels.

WHY THIS IS NOT A FREE CHOICE
-----------------------------
`axi_L2_interleaver` scrambles the L2 address on `addr[13:10]` -- the L1
word-interleave GROUP field -- so **L2 channel G serves group G**, and
`DmaRegionWidth = NumBanksPerGroup*4 = 1024 B` aligns the DMA split to the same
granularity. Consequently `idma_distributed_midend` hands group G exactly the
chunks living in bank G, and where channel G physically sits on the perimeter
*is* that group's DMA distance. See docs/scaleup/mesh_plan.md sections 13 and 3.6.

The committed 4x4 placement therefore is not arbitrary. Measured against a
Hungarian solve over all 16 groups and all 16 attachment points:

    committed          8 hops total, avg 0.50   <- optimal
    optimal (Hungarian) 8 hops total, avg 0.50
    canonical W,S,E,N walk  26 hops, avg 1.62   <- 3.2x worse

THE RULE
--------
Reproduces the committed 4x4 mapping EXACTLY and generalises:

    1. x == 0          -> West (0, y)
    2. x == NumX-1     -> East (NumX-1, y)
    3. else y == 0     -> South(x, 0)
    4. else y == NumY-1-> North(x, NumY-1)
    5. interior groups -> nearest unassigned point, visited in group order

Corner groups take their x-edge point, which frees the corner's y-edge point for
the nearest interior group -- that is what the "irregular" 4/5 and 10/11 orderings
in the committed wrapper actually encode.

SUPPORTED CONFIGURATIONS
------------------------
The L2 interleaver's group->bank identity requires NumL2Channels == NumGroups,
which requires NumGroups <= perimeter capacity 2*(NumX+NumY). That holds at 2x2,
2x4 and 4x4 and fails from 4x8 upward (32 groups vs 24 points). Above that the
mapping stops being a bijection and *which groups share a channel* becomes a
design decision -- see mesh_plan.md section 14 step 3. This script refuses those
cases rather than inventing an answer.

Usage:
    gen_perimeter_map.py --num-x 4 --num-y 4 [--check] [-o <outdir>]
"""

import argparse
import sys

# floo_pkg::route_direction_e
NORTH, EAST, SOUTH, WEST = 0, 1, 2, 3
DIR_NAME = {NORTH: "North", EAST: "East", SOUTH: "South", WEST: "West"}

# The committed 4x4 placement, decoded from terapool_cluster_floonoc_wrapper.sv
# (floo_axi_req_i[y], [5-x], [x+6], [13-x], [y+12]). This is the regression gate:
# the rule must reproduce it exactly, so 4x4 stays bit-identical.
COMMITTED_4X4 = {
    0: ((0, 0), WEST),  1: ((0, 1), WEST),  2: ((0, 2), WEST),  3: ((0, 3), WEST),
    4: ((1, 0), SOUTH), 5: ((0, 0), SOUTH), 6: ((0, 3), NORTH), 7: ((1, 3), NORTH),
    8: ((2, 0), SOUTH), 9: ((3, 0), SOUTH), 10: ((3, 3), NORTH), 11: ((2, 3), NORTH),
    12: ((3, 0), EAST), 13: ((3, 1), EAST), 14: ((3, 2), EAST), 15: ((3, 3), EAST),
}


def group_coord(gid, num_y):
    """gid = x*NumY + y -- the encoding the address bit-cast implies."""
    return (gid // num_y, gid % num_y)


def manhattan(a, b):
    return abs(a[0] - b[0]) + abs(a[1] - b[1])


def perimeter_points(num_x, num_y):
    """Every off-cluster attachment point. Corners contribute two, on different edges."""
    pts = [((0, y), WEST) for y in range(num_y)]
    pts += [((num_x - 1, y), EAST) for y in range(num_y)]
    pts += [((x, 0), SOUTH) for x in range(num_x)]
    pts += [((x, num_y - 1), NORTH) for x in range(num_x)]
    return pts


def assign(num_x, num_y):
    """Channel G -> attachment point, minimising total group->channel distance."""
    num_groups = num_x * num_y
    capacity = 2 * (num_x + num_y)
    if num_groups > capacity:
        sys.exit(
            f"error: {num_x}x{num_y} has {num_groups} groups but only {capacity} perimeter\n"
            f"       attachment points, so L2 channel G cannot serve group G one-to-one.\n"
            f"       Which groups share a channel is an open design decision --\n"
            f"       see docs/scaleup/mesh_plan.md section 14 step 3. Refusing to invent one.")

    free = set(perimeter_points(num_x, num_y))
    placement, interior = {}, []
    for gid in range(num_groups):
        x, y = group_coord(gid, num_y)
        if x == 0:
            pt = ((0, y), WEST)
        elif x == num_x - 1:
            pt = ((num_x - 1, y), EAST)
        elif y == 0:
            pt = ((x, 0), SOUTH)
        elif y == num_y - 1:
            pt = ((x, num_y - 1), NORTH)
        else:
            interior.append(gid)
            continue
        placement[gid] = pt
        free.discard(pt)

    # Interior groups have no attachment of their own; give each the nearest one
    # still free. Deterministic: groups in id order, ties by (direction, x, y).
    for gid in interior:
        here = group_coord(gid, num_y)
        pt = min(sorted(free), key=lambda q: (manhattan(here, q[0]), q[1], q[0]))
        placement[gid] = pt
        free.discard(pt)
    return placement


def check_committed(placement, num_x, num_y):
    """Gate: at 4x4 the rule must reproduce the committed wrapper mapping exactly."""
    if (num_x, num_y) != (4, 4):
        return None
    bad = [g for g in COMMITTED_4X4 if placement.get(g) != COMMITTED_4X4[g]]
    return bad


def render(placement, num_x, num_y):
    num_groups = num_x * num_y
    no_ch = num_groups  # sentinel: one past the last valid channel
    # (x, y, dir) -> channel
    idx = {}
    for gid, (pos, d) in placement.items():
        idx[(pos[0], pos[1], d)] = gid

    L = ["// Copyright 2026 ETH Zurich and University of Bologna.",
         "// Solderpad Hardware License, Version 0.51, see LICENSE for details.",
         "// SPDX-License-Identifier: SHL-0.51",
         "//",
         "// AUTOMATICALLY GENERATED by hardware/scripts/gen_perimeter_map.py -- do not edit.",
         "//",
         "// Perimeter placement of the L2 channels.",
         "//",
         "// axi_L2_interleaver keys the L2 bank on addr[13:10], the L1 group field, so",
         "// channel G serves group G and this placement IS each group's DMA distance.",
         "// The mapping minimises total group->channel distance; at 4x4 it reproduces the",
         "// historical hand-written placement exactly (8 hops total, optimal -- a naive",
         "// perimeter walk costs 26). See docs/scaleup/mesh_plan.md sections 3.6, 13, 14.",
         "",
         "package perimeter_map_pkg;",
         "",
         f"  localparam int unsigned NumMeshX      = {num_x};",
         f"  localparam int unsigned NumMeshY      = {num_y};",
         f"  localparam int unsigned NumL2Channels = {num_groups};",
         "",
         "  // Value used where a (x, y, direction) triple is not an attachment point.",
         f"  localparam int unsigned NoChannel     = {no_ch};",
         "",
         "  typedef logic [7:0] perim_ch_t;",
         "",
         "  // PACKED, like routing_table_pkg::RoutingTables -- an unpacked localparam array",
         "  // is not constant-foldable enough to index a signal in a generate block.",
         "  // Packed literals are written MSB-FIRST, so x and y run high->low and the",
         "  // innermost row is {West, South, East, North} (floo_pkg 3,2,1,0).",
         "  localparam perim_ch_t [NumMeshX-1:0][NumMeshY-1:0][3:0] PerimeterChannel = '{"]
    def cell(x, y, d):
        ch = idx.get((x, y, d))
        return "NoChannel" if ch is None else f"8'd{ch}"
    xs = []
    for x in reversed(range(num_x)):
        ys = []
        for y in reversed(range(num_y)):
            row = ", ".join(f"{cell(x, y, d):>9s}" for d in (WEST, SOUTH, EAST, NORTH))
            sep = "" if y == 0 else ","
            ys.append(f"      '{{{row}}}{sep}  // ({x},{y}) W,S,E,N")
        sep = "" if x == 0 else ","
        xs.append("    '{\n" + "\n".join(ys) + f"\n    }}{sep}")
    L.append("\n".join(xs))
    L += ["  };", "", "endpackage : perimeter_map_pkg"]
    return "\n".join(L) + "\n"


PROTOCOLS = """protocols:
  - name: "narrow_in"
    type: "narrow"
    protocol: "AXI4"
    data_width: 64
    addr_width: 32
    id_width: 1
    user_width: 1
    direction: "input"
  - name: "narrow_out"
    type: "narrow"
    protocol: "AXI4"
    data_width: 64
    addr_width: 32
    id_width: 1
    user_width: 1
    direction: "output"
  - name: "wide_in"
    type: "wide"
    protocol: "AXI4"
    data_width: 512
    addr_width: 32
    id_width: 2
    user_width: 1
  - name: "wide_out"
    type: "wide"
    protocol: "AXI4"
    data_width: 512
    addr_width: 32
    id_width: 2
    user_width: 1
"""

DIR_YML = {NORTH: "North", EAST: "East", SOUTH: "South", WEST: "West"}


def emit_yml(placement, num_x, num_y, periph_at, l2_base, l2_chan_size, route_algo):
    """Emit the floo config, with the HBM placement taken from `placement`.

    The connections are written one channel at a time (src_idx/dst_idx) rather
    than as ranges. Ranges are how this file was maintained by hand and they are
    what made it hard to keep in step with the RTL -- a range pairs src and dst
    element-wise, including descending ones like [15,12] against [[3,3],[3,0]],
    which is easy to misread and impossible to diff against a table.
    """
    n = len(placement)
    periph_ch = next((g for g, v in placement.items() if v == periph_at), None)
    if periph_ch is None:
        sys.exit(f"error: no channel placed at the periph router point {periph_at}")

    L = ['# AUTOMATICALLY GENERATED by hardware/scripts/gen_perimeter_map.py -- do not edit.',
         '#',
         '# The HBM placement below is derived: L2 channel G serves group G (the L2',
         '# interleaver keys on the L1 group field), so each channel sits at the perimeter',
         '# point nearest its group. See docs/scaleup/mesh_plan.md sections 3.6, 13, 14.',
         '',
         'name: terapool',
         'description: "Terapool AXI NoC"',
         'network_type: "narrow-wide"',
         '',
         'routing:',
         f'  route_algo: "{route_algo}"',
         '  use_id_table: true',
         '',
         PROTOCOLS.rstrip(),
         '',
         'endpoints:',
         '  - name: "group"',
         f'    array: [{num_x}, {num_y}]',
         '    mgr_port_protocol:',
         '      - "wide_in"',
         '  - name: "hbm"',
         f'    array: [{n}]',
         '    addr_range:',
         f'      base: {l2_base}',
         f'      size: {l2_chan_size}',
         '    sbr_port_protocol:',
         '      - "wide_out"',
         '  - name: "periphs"',
         '    addr_range:',
         '      - start: 0x0000_0000',
         '        end: 0x7FFF_FFFF',
         '      - start: 0xA000_0000',
         '        end: 0xC000_FFFF',
         '    sbr_port_protocol:',
         '      - "wide_out"',
         '  - name: "host"',
         '    mgr_port_protocol:',
         '      - "wide_in"',
         '',
         'routers:',
         '  - name: "group_router"',
         f'    array: [{num_x}, {num_y}]',
         '    degree: 5',
         '  - name: "periph_router"',
         '',
         'connections:',
         '  - src: "group"',
         '    dst: "group_router"',
         '    src_range:',
         f'    - [0, {num_x - 1}]',
         f'    - [0, {num_y - 1}]',
         '    dst_range:',
         f'    - [0, {num_x - 1}]',
         f'    - [0, {num_y - 1}]',
         '    dst_dir: "Eject"']

    for ch in sorted(placement):
        if ch == periph_ch:
            continue                       # rides on the periph router, below
        (x, y), d = placement[ch]
        L += ['  - src: "hbm"',
              f'    src_idx: [{ch}]',
              '    dst: "group_router"',
              f'    dst_idx: [{x}, {y}]',
              f'    dst_dir: "{DIR_YML[d]}"']

    (px, py), pd = periph_at
    L += ['  # The periph router occupies one perimeter point and carries the peripherals,',
          f'  # the host, and L2 channel {periph_ch}.',
          '  - src: "periph_router"',
          '    dst: "group_router"',
          f'    dst_idx: [{px}, {py}]',
          f'    dst_dir: "{DIR_YML[pd]}"',
          '  - src: "periph_router"',
          '    dst: "hbm"',
          f'    dst_idx: [{periph_ch}]',
          '  - src: "periph_router"',
          '    dst: "periphs"',
          '  - src: "periph_router"',
          '    dst: "host"']
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--num-x", type=int, required=True)
    ap.add_argument("--num-y", type=int, required=True)
    ap.add_argument("-o", "--outdir", help="write perimeter_map_pkg.sv here")
    ap.add_argument("--emit-yml", metavar="FILE",
                    help="write the floo config with the derived HBM placement")
    ap.add_argument("--periph-dir", default="South",
                    help="edge the periph router occupies at (0,0) (default South)")
    ap.add_argument("--route-algo", default="ID")
    ap.add_argument("--check", action="store_true",
                    help="verify against the committed 4x4 placement and report distances")
    args = ap.parse_args()

    nx, ny = args.num_x, args.num_y
    placement = assign(nx, ny)

    total = sum(manhattan(group_coord(g, ny), p[0]) for g, p in placement.items())
    n = len(placement)
    print(f"mesh {nx}x{ny}: {n} groups, {2*(nx+ny)} perimeter points, "
          f"total {total} hops, avg {total/n:.2f}")

    bad = check_committed(placement, nx, ny)
    if bad is not None:
        if bad:
            print(f"FAILED: differs from the committed 4x4 placement at groups {bad}")
            for g in bad:
                got, exp = placement[g], COMMITTED_4X4[g]
                print(f"    grp{g:2d}: got {DIR_NAME[got[1]]}{got[0]}, "
                      f"committed {DIR_NAME[exp[1]]}{exp[0]}")
            sys.exit(1)
        print("gate: reproduces the committed 4x4 placement EXACTLY")

    if args.check:
        for g in sorted(placement):
            pos, d = placement[g]
            print(f"    ch{g:2d} -> {DIR_NAME[d]:5s}{pos}  group{g:2d}{group_coord(g, ny)}  "
                  f"d={manhattan(group_coord(g, ny), pos)}")
        return

    if args.emit_yml:
        pd = {"North": NORTH, "East": EAST, "South": SOUTH, "West": WEST}[args.periph_dir]
        txt = emit_yml(placement, nx, ny, ((0, 0), pd),
                       "0x8000_0000", "0x0010_0000", args.route_algo)
        from pathlib import Path
        Path(args.emit_yml).write_text(txt)
        print(f"wrote {args.emit_yml}")

    if args.outdir:
        from pathlib import Path
        out = Path(args.outdir); out.mkdir(parents=True, exist_ok=True)
        f = out / "perimeter_map_pkg.sv"
        f.write_text(render(placement, nx, ny))
        print(f"wrote {f}")
    else:
        print(render(placement, nx, ny))


if __name__ == "__main__":
    main()
