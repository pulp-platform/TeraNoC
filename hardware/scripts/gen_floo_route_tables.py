#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Generate per-router IdTable routing tables for the FlooNoC AXI/L2 network.

Why this exists instead of using floogen's own tables:

  1. floogen's `gen_router_tables` iterates SUBORDINATE endpoints only, so
     manager-only endpoints (the TeraNoC groups) get no rules and every
     subordinate->manager response would be unroutable.

  2. floogen emits no usable table for our hand-written top at all: the maps live
     in its generated top module, which our flow discards (`--only-pkg`).

Two turn models are offered, and BOTH are gated on an explicit channel-dependency
-graph acyclicity check before anything is emitted:

  * `shortest` (default) -- floogen's own nx.shortest_path paths. Reproduces the
    historical source-routed behaviour exactly (measured cycle-identical) and
    spreads many-to-few traffic across both approach links. NOT dimension-ordered,
    so it is deadlock-free only by verification, never by construction. Measured
    on the 4x4 config: turns used are N->E, S->E, W->N, W->S -- at most 2/4 of
    either rotation, so no cycle can close.
  * `xy` -- strict x-before-y. Acyclic by construction (modulo off-mesh injection)
    and roughly half the rules per router, because `gid = x*NumY + y` makes each
    direction's destinations a contiguous id range. Costs ~1.24% on
    sp-fmatmul-opt-burst-merge at 4x4 by funnelling each destination through a
    single approach link.

Topology (mesh size, endpoint ids, endpoint placement) still comes from floogen,
so the yml remains the single source of truth. Output port indices are taken
from each router's own `outgoing` list -- the same source floogen uses -- rather
than assuming a compass ordering.

A router outside the mesh array (TeraNoC's `periph_router`) is placed just
outside the mesh in the direction it hangs off its anchor. XY cannot be applied
from such a node, so it forwards everything non-local up its single mesh-facing
link.

Usage:
    gen_floo_route_tables.py -c <floo_noc_*.yml> -o <outdir> [--check-only]
"""

import argparse
import sys
from pathlib import Path

# Compass encoding used by the mesh links, matching floo_pkg / mempool_pkg.
NORTH, EAST, SOUTH, WEST, EJECT = 0, 1, 2, 3, 4
DIR_NAME = {NORTH: "North", EAST: "East", SOUTH: "South", WEST: "West", EJECT: "Eject"}
STEP = {NORTH: (0, 1), EAST: (1, 0), SOUTH: (0, -1), WEST: (-1, 0), EJECT: (0, 0)}


def build_network(cfg):
    """Parse the yml through floogen and return the compiled network."""
    from floogen.config_parser import parse_config
    from floogen.model.network import Network

    net = parse_config(Network, cfg)
    net.create_network()
    net.compile_network()
    net.gen_routing_info()
    return net


def link_dir(g, a, b):
    """Direction that the link a->b occupies ON b, or None if undirected."""
    d = g.edges.get((a, b), {}).get("dst_dir")
    if d is None:
        d = g.edges.get((b, a), {}).get("src_dir")
    return None if d is None else int(d)


def port_index(g, rt_name, rt_obj, nb_name):
    """Output port index of rt_name's link to nb_name, per the router's own list."""
    link = g.get_edge_obj((rt_name, nb_name))
    return rt_obj.outgoing.index(link)


def collect_topology(net):
    """Router coordinates, port maps, and endpoint (id, anchor, port)."""
    g = net.graph
    rt_obj = dict(g.get_rt_nodes(with_name=True))
    graph = g

    coord, off_mesh = {}, []
    for name in rt_obj:
        try:
            coord[name] = g.get_node_arr_idx(name)
        except KeyError:
            off_mesh.append(name)
    if not coord:
        sys.exit("error: no routers with an array index -- is this a mesh config?")
    num_x = max(x for x, _ in coord.values()) + 1
    num_y = max(y for _, y in coord.values()) + 1

    # Place each off-mesh router just outside the mesh, in the direction its
    # link occupies on the meshed router it attaches to.
    for name in off_mesh:
        for nb in g.neighbors(name):
            if nb not in coord:
                continue
            d = link_dir(g, name, nb)
            if d is None:
                continue
            bx, by = coord[nb]
            dx, dy = STEP[d]
            coord[name] = (bx + dx, by + dy)
            break
        if name not in coord:
            sys.exit(f"error: cannot place off-mesh router {name} -- no directed link to a "
                     f"meshed router. XY routing needs a coordinate for every router.")

    by_coord = {c: r for r, c in coord.items()}

    # Endpoints: id, the router they attach to, and that router's port for them.
    eps = []
    for name, node in g.get_ni_nodes(with_name=True):
        anchor = next((nb for nb in g.neighbors(name) if nb in rt_obj), None)
        if anchor is None:
            sys.exit(f"error: endpoint {name} attaches to no router")
        eps.append({"name": name, "id": node.id.id, "anchor": anchor,
                    "port": port_index(g, anchor, rt_obj[anchor], name)})
    eps.sort(key=lambda e: e["id"])

    # For every router, the port index reached by stepping in each direction.
    step_port = {}
    for name, obj in rt_obj.items():
        cx, cy = coord[name]
        m = {}
        for d, (dx, dy) in STEP.items():
            if d == EJECT:
                continue
            nb = by_coord.get((cx + dx, cy + dy))
            if nb is not None and g.has_edge(name, nb):
                m[d] = port_index(g, name, obj, nb)
        step_port[name] = m

    return {"coord": coord, "by_coord": by_coord, "off_mesh": set(off_mesh),
            "eps": eps, "step_port": step_port, "num_x": num_x, "num_y": num_y,
            "graph": graph, "rt_obj": rt_obj}


def xy_dir(src, dst):
    """Compass direction of the first XY hop from src to dst, x before y."""
    sx, sy = src
    dx, dy = dst
    if sx != dx:
        return EAST if dx > sx else WEST
    if sy != dy:
        return NORTH if dy > sy else SOUTH
    return None  # already there


def next_port_shortest(topo, rt, ep):
    """First hop under nx.shortest_path -- floogen's own turn model.

    This is the default. It reproduces the paths the historical source-routed
    design took, so changing the routing MECHANISM to IdTable is behaviourally
    invisible -- measured cycle-identical at 122,051 on sp-fmatmul-opt-burst-merge
    256x512x256, versus 123,567 for strict XY.

    It is NOT dimension-ordered, so it is deadlock-free only where
    `check_deadlock_free` says so, which depends on the topology and on nx
    tie-breaking. That gate is mandatory, not advisory: if it ever fails, use
    `--turn-model xy`, which is acyclic by construction.
    """
    import networkx as nx
    g = topo["graph"]
    if rt == ep["anchor"]:
        return ep["port"]
    path = nx.shortest_path(g, rt, ep["name"])
    nxt = path[1]
    return topo["rt_obj"][rt].outgoing.index(g.get_edge_obj((rt, nxt)))


def next_port(topo, rt, ep):
    """Output port at router `rt` for endpoint `ep`, or None if unroutable."""
    if topo.get("turn_model") == "shortest":
        return next_port_shortest(topo, rt, ep)
    if rt == ep["anchor"]:
        return ep["port"]
    if rt in topo["off_mesh"]:
        # Cannot apply XY from outside the mesh: forward up the single mesh link.
        uplinks = [d for d in topo["step_port"][rt]]
        if len(uplinks) != 1:
            sys.exit(f"error: off-mesh router {rt} has {len(uplinks)} mesh links; "
                     f"expected exactly 1")
        return topo["step_port"][rt][uplinks[0]]
    d = xy_dir(topo["coord"][rt], topo["coord"][ep["anchor"]])
    if d is None or d not in topo["step_port"][rt]:
        return None
    return topo["step_port"][rt][d]


def build_tables(topo):
    """Per-router rules [(port, start, end)) merged over contiguous ids."""
    tables = {}
    for rt in topo["coord"]:
        by_port = {}
        for ep in topo["eps"]:
            p = next_port(topo, rt, ep)
            if p is None:
                sys.exit(f"error: no XY route from {rt} to {ep['name']}")
            by_port.setdefault(p, []).append(ep["id"])
        rules = []
        for port, ids in by_port.items():
            ids.sort()
            lo = prev = ids[0]
            for i in ids[1:]:
                if i == prev + 1:
                    prev = i
                    continue
                rules.append((port, lo, prev + 1))
                lo = prev = i
            rules.append((port, lo, prev + 1))
        tables[rt] = sorted(rules, key=lambda r: r[1])
    return equalise(tables)


def equalise(tables):
    """Pad every router to the same rule count by SPLITTING ranges, not by
    appending inert entries.

    common_cells/addr_decode treats `end_addr == 0` as "end of address space"
    (addr_decode.sv:55), so a {0,0} pad rule would match every destination and
    swallow all traffic. Splitting an existing range keeps every rule valid,
    non-overlapping and semantically identical, which lets all routers share one
    NumAddrRules parameter.
    """
    target = max(len(r) for r in tables.values())
    for rt, rules in tables.items():
        rules = list(rules)
        while len(rules) < target:
            # Split the widest range in half; both halves keep the same port.
            i = max(range(len(rules)), key=lambda k: rules[k][2] - rules[k][1])
            port, lo, hi = rules[i]
            if hi - lo < 2:
                sys.exit(f"error: cannot pad {rt} to {target} rules -- no range left to "
                         f"split. Give each router its own NumAddrRules instead.")
            mid = lo + (hi - lo) // 2
            rules[i:i + 1] = [(port, lo, mid), (port, mid, hi)]
        tables[rt] = sorted(rules, key=lambda r: r[1])
    return tables


def check_rule_sanity(tables, num_eps):
    """Every table must be non-overlapping, ordered and cover all ids exactly once."""
    problems = []
    for rt, rules in tables.items():
        prev_hi = 0
        for port, lo, hi in rules:
            if hi <= lo:
                problems.append(f"{rt}: degenerate rule [{lo},{hi}) -- addr_decode reads "
                                f"end_addr==0 as end-of-space")
            if lo < prev_hi:
                problems.append(f"{rt}: rule [{lo},{hi}) overlaps the previous one")
            if lo > prev_hi:
                problems.append(f"{rt}: ids [{prev_hi},{lo}) have no rule")
            prev_hi = max(prev_hi, hi)
        if prev_hi != num_eps:
            problems.append(f"{rt}: coverage ends at {prev_hi}, expected {num_eps}")
    return problems


def check_tables(tables, topo):
    """Walk every (router, destination) pair to delivery. Empty list = sound."""
    problems = []
    max_hops = 4 * (len(tables) + 1)

    def lookup(rt, dst_id):
        for port, lo, hi in tables[rt]:
            if lo <= dst_id < hi:
                return port
        return None

    for start in tables:
        for ep in topo["eps"]:
            rt, hops, seen = start, 0, set()
            while True:
                hops += 1
                if hops > max_hops:
                    problems.append(f"{start} -> {ep['name']}: undelivered after {max_hops} hops")
                    break
                if rt in seen:
                    problems.append(f"{start} -> {ep['name']}: loops at {rt}")
                    break
                seen.add(rt)
                port = lookup(rt, ep["id"])
                if port is None:
                    problems.append(f"{rt}: no rule for {ep['name']} (id {ep['id']})")
                    break
                if port != next_port(topo, rt, ep):
                    problems.append(f"{rt} -> {ep['name']}: table port {port} disagrees with XY")
                    break
                if rt == ep["anchor"]:
                    break  # delivered
                nxt = next((topo["by_coord"].get(
                    (topo["coord"][rt][0] + STEP[d][0], topo["coord"][rt][1] + STEP[d][1]))
                    for d, p in topo["step_port"][rt].items() if p == port), None)
                if nxt is None:
                    problems.append(f"{rt} -> {ep['name']}: port {port} leads nowhere")
                    break
                rt = nxt
    return problems


def check_deadlock_free(tables, topo):
    """Hard gate: the channel dependency graph must be acyclic.

    A routing function deadlocks iff its CDG contains a cycle. Dimension-order
    (XY) is acyclic *by construction*; any other turn model is acyclic only if it
    happens to be, which depends on the topology and — for the shortest-path model
    — on nx tie-breaking. So this is verified rather than assumed, for every
    topology and every turn model, and emission is refused on failure.

    Complete without enumerating sources: routing here is destination-based, so
    for every link (A->B) and every destination D routed through it, the only
    possible continuation is B's own next hop toward D.
    """
    import networkx as nx

    def port_at(rt, dst_id):
        for port, lo, hi in tables[rt]:
            if lo <= dst_id < hi:
                return port
        return None

    def hop(rt, port):
        c = topo["coord"][rt]
        for d, p in topo["step_port"][rt].items():
            if p == port:
                return topo["by_coord"].get((c[0] + STEP[d][0], c[1] + STEP[d][1]))
        return None

    dep = nx.DiGraph()
    for a in tables:
        for ep in topo["eps"]:
            b = hop(a, port_at(a, ep["id"])) if a != ep["anchor"] else None
            if b is None or b == ep["anchor"]:
                continue
            c = hop(b, port_at(b, ep["id"]))
            if c is not None:
                dep.add_edge((a, b), (b, c))
    try:
        cyc = nx.find_cycle(dep, orientation="original")
        return [f"CDG CYCLE of length {len(cyc)} -- this routing CAN DEADLOCK:"] + \
               [f"    {e[0][0]} -> {e[0][1]}   then   {e[1][0]} -> {e[1][1]}" for e in cyc]
    except nx.NetworkXNoCycle:
        return []


def turn_set(tables, topo):
    """Turns actually exercised, as (in_dir, out_dir) pairs -- for the report."""
    def port_at(rt, dst_id):
        return next((p for p, lo, hi in tables[rt] if lo <= dst_id < hi), None)

    def hop(rt, port):
        c = topo["coord"][rt]
        for d, p in topo["step_port"][rt].items():
            if p == port:
                return d, topo["by_coord"].get((c[0] + STEP[d][0], c[1] + STEP[d][1]))
        return None, None

    used = set()
    for a in tables:
        for ep in topo["eps"]:
            if a == ep["anchor"]:
                continue
            din, b = hop(a, port_at(a, ep["id"]))
            if b is None or b == ep["anchor"]:
                continue
            dout, _ = hop(b, port_at(b, ep["id"]))
            if dout is not None and din != dout:
                used.add((din, dout))
    return used


def sv_name(rt):
    """group_router_1_2 -> GroupRouter12"""
    return "".join(p.capitalize() for p in rt.split("_"))


def render(tables, topo, net_name):
    eps, coord = topo["eps"], topo["coord"]
    num_x, num_y = topo["num_x"], topo["num_y"]
    max_rules = max(len(r) for r in tables.values())
    id_bits = max(1, (len(eps) - 1).bit_length())
    mesh = {c: r for r, c in coord.items() if r not in topo["off_mesh"]}
    off = sorted(topo["off_mesh"])
    name_of = {e["id"]: e["name"] for e in eps}

    def rule_sv(rule, indent, last):
        """One array entry. The separating comma must precede the comment."""
        pad, sep = " " * indent, "" if last else ","
        port, lo, hi = rule
        span = name_of.get(lo, "")
        if hi - lo > 1:
            span += ".." + name_of.get(hi - 1, "")
        return (f"{pad}'{{idx: 3'd{port}, start_addr: {id_bits}'d{lo}, "
                f"end_addr: {id_bits}'d{hi}}}{sep}  // port {port} -> {span}")

    def rules_sv(rules, indent):
        rev = list(reversed(rules))
        return "\n".join(rule_sv(r, indent, i == len(rev) - 1) for i, r in enumerate(rev))

    L = ["// Copyright 2026 ETH Zurich and University of Bologna.",
         "// Solderpad Hardware License, Version 0.51, see LICENSE for details.",
         "// SPDX-License-Identifier: SHL-0.51",
         "//",
         "// AUTOMATICALLY GENERATED by hardware/scripts/gen_floo_route_tables.py -- do not edit.",
         "//",
         "// Per-router IdTable routing tables for the FlooNoC AXI/L2 network.",
         "//"] + ([
         "// Turn model: STRICT XY (x before y). Acyclic by construction within the mesh.",
         ] if topo.get("turn_model") != "shortest" else [
         "// Turn model: SHORTEST-PATH (floogen's nx.shortest_path). This reproduces the",
         "// historical source-routed paths exactly. It is NOT dimension-ordered, so it is",
         "// deadlock-free only by verification -- see the acyclicity check below.",
         ]) + [
         "//",
         "// Verified before this file was written:",
         "//   * every (router, destination) pair walked to delivery, no loops",
         "//   * the channel dependency graph is ACYCLIC (the generator refuses to emit",
         "//     a routing function that can deadlock)",
         f"//   * turns exercised: "
         + " ".join(f"{DIR_NAME[a]}->{DIR_NAME[b]}" for a, b in sorted(turn_set(tables, topo))),
         "",
         f"package floo_{net_name}_route_table_pkg;",
         "",
         f"  localparam int unsigned NumRouterX   = {num_x};",
         f"  localparam int unsigned NumRouterY   = {num_y};",
         f"  localparam int unsigned NumEndpoints = {len(eps)};",
         f"  localparam int unsigned RouteIdWidth = {id_bits};",
         f"  localparam int unsigned MaxNumRules  = {max_rules};",
         "",
         "  typedef logic [RouteIdWidth-1:0] route_id_t;",
         "",
         "  typedef struct packed {",
         "    logic [2:0] idx;        // router output port index",
         "    route_id_t  start_addr;",
         "    route_id_t  end_addr;",
         "  } floo_id_rule_t;",
         "",
         "  // Every router carries exactly MaxNumRules rules: routers needing fewer have",
         "  // a range SPLIT rather than padded, because addr_decode reads end_addr == 0 as",
         "  // end-of-address-space (a {0,0} pad would match every destination). So all",
         "  // routers share one NumAddrRules parameter and every rule is a real route.",
         ""]

    L.append("  localparam floo_id_rule_t "
             "[NumRouterX-1:0][NumRouterY-1:0][MaxNumRules-1:0] RouterIdMaps = '{")
    L.append(",\n".join(
        "    '{\n" + ",\n".join(
            f"      '{{  // {mesh[(x, y)]}\n{rules_sv(tables[mesh[(x, y)]], 8)}\n      }}"
            for y in reversed(range(num_y))) + "\n    }"
        for x in reversed(range(num_x))))
    L += ["  };", ""]

    for rt in off:
        rules = tables[rt]
        L.append(f"  localparam int unsigned {sv_name(rt)}NumRules = {len(rules)};")
        L.append(f"  localparam floo_id_rule_t [{sv_name(rt)}NumRules-1:0] "
                 f"{sv_name(rt)}IdMap = '{{")
        rev = list(reversed(rules))
        L.append("\n".join(rule_sv(r, 4, i == len(rev) - 1) for i, r in enumerate(rev)))
        L += ["  };", ""]

    L.append(f"endpackage : floo_{net_name}_route_table_pkg")
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--config", type=Path, required=True, help="FlooNoC yml config")
    ap.add_argument("-o", "--outdir", type=Path, help="output directory")
    ap.add_argument("--check-only", action="store_true",
                    help="verify the turn model and report, emit nothing")
    ap.add_argument("--turn-model", choices=("xy", "shortest"), default="shortest",
                    help="shortest (default): floogen's nx.shortest_path paths -- matches "
                         "the historical source-routed behaviour exactly and spreads "
                         "many-to-few traffic better. xy: strict dimension-order, acyclic "
                         "by construction and ~half the rules/router, but concentrates "
                         "many-to-few traffic. BOTH are gated on the CDG acyclicity check "
                         "below; shortest is not deadlock-free by construction, only by "
                         "verification, so the gate is what makes it safe.")
    args = ap.parse_args()

    net = build_network(args.config)
    topo = collect_topology(net)
    topo["turn_model"] = args.turn_model
    tables = build_tables(topo)

    problems = check_tables(tables, topo) + check_rule_sanity(tables, len(topo["eps"]))
    print(f"mesh {topo['num_x']}x{topo['num_y']}, {len(tables)} routers "
          f"({len(topo['off_mesh'])} off-mesh), {len(topo['eps'])} endpoints, "
          f"{len(tables) * len(topo['eps'])} (router,destination) pairs checked")
    print(f"rules per router: {max(len(r) for r in tables.values())} (uniform, "
          f"ranges split to equalise)")
    if problems:
        print(f"\nFAILED: {len(problems)} problem(s):")
        for p in problems[:20]:
            print("   ", p)
        sys.exit(1)
    # Hard gate: refuse to emit a routing function whose CDG has a cycle.
    dead = check_deadlock_free(tables, topo)
    turns = " ".join(f"{DIR_NAME[a]}->{DIR_NAME[b]}" for a, b in sorted(turn_set(tables, topo)))
    print(f"turn model: {args.turn_model}; turns exercised: {turns}")
    if dead:
        print("\nFAILED deadlock check:")
        for line in dead:
            print("   ", line)
        sys.exit(1)
    print("channel dependency graph: ACYCLIC -- deadlock-free on this topology")

    if args.check_only:
        return
    text = render(tables, topo, net.name)
    if args.outdir:
        args.outdir.mkdir(parents=True, exist_ok=True)
        out = args.outdir / f"floo_{net.name}_route_table_pkg.sv"
        out.write_text(text)
        print(f"wrote {out} ({len(text.splitlines())} lines)")
    else:
        print(text)


if __name__ == "__main__":
    main()
