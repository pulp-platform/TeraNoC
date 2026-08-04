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
         f"  localparam int unsigned NumMeshX       = {num_x};",
         f"  localparam int unsigned NumMeshY       = {num_y};",
         f"  localparam int unsigned NumL2Channels  = {num_groups};",
         "",
         "  // Value used where a (x, y, direction) triple is not an attachment point.",
         f"  localparam int unsigned NoChannel      = {no_ch};",
         "",
         "  // PerimeterChannel[x][y][dir], dir per floo_pkg: 0=North 1=East 2=South 3=West",
         "  localparam int unsigned PerimeterChannel [NumMeshX][NumMeshY][4] = '{"]
    # NOTE: the array separator must precede the trailing comment, or the comma
    # ends up inside it and the file does not parse.
    xs = []
    for x in range(num_x):
        ys = []
        for y in range(num_y):
            cells = []
            for d in (NORTH, EAST, SOUTH, WEST):
                ch = idx.get((x, y, d))
                cells.append("NoChannel" if ch is None else f"{ch}")
            sep = "" if y == num_y - 1 else ","
            ys.append("      '{" + ", ".join(f"{c:>9s}" for c in cells)
                      + f"}}{sep}  // ({x},{y})")
        sep = "" if x == num_x - 1 else ","
        xs.append("    '{\n" + "\n".join(ys) + f"\n    }}{sep}")
    L.append("\n".join(xs))
    L += ["  };", "", "endpackage : perimeter_map_pkg"]
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--num-x", type=int, required=True)
    ap.add_argument("--num-y", type=int, required=True)
    ap.add_argument("-o", "--outdir", help="write perimeter_map_pkg.sv here")
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
