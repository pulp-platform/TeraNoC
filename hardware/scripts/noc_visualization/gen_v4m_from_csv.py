#!/usr/bin/env python3
import argparse, csv, json, math, os
from collections import defaultdict

# ---------------- Fixed enums (your 4 msg types & 4 transfer types) ----------
MSG_TYPES = {
    0: "*mem.DataReadyRsp",
    1: "*mem.ReadReq",
    2: "*mem.WriteDoneRsp",
    3: "*mem.WriteReq",
}
MSG_GROUP = {
    0: "Read",  # DataReadyRsp
    1: "Read",  # ReadReq
    2: "Write",  # WriteDoneRsp
    3: "Write",  # WriteReq
}
MSG_DOC = {
    0: "D",
    1: "C",
    2: "C",
    3: "D",
}
TRANSFER_TYPES = ["mesh_send", "mesh_relay", "mesh_recv", "peripheral"]

NUM_TRANSFERS = 4
NUM_MSG_TYPES = 4


# ---------------- Helpers -----------------------------------------------------
def dump_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        if indent is None:
            json.dump(obj, f, separators=(",", ":"))
        else:
            json.dump(obj, f, indent=indent)


def id2xy(nid, W):
    return (nid % W, nid // W)


def manhattan(a, b, W):
    ax, ay = id2xy(a, W)
    bx, by = id2xy(b, W)
    return abs(ax - bx) + abs(ay - by)


def is_neighbors(u, v, W, H):
    ux, uy = id2xy(u, W)
    vx, vy = id2xy(v, W)
    return (ux == vx and abs(uy - vy) == 1) or (uy == vy and abs(ux - vx) == 1)


def build_neighbor_edges(W, H):
    edges = []
    for y in range(H):
        for x in range(W):
            u = y * W + x
            if y + 1 < H:
                edges.append((u, (y + 1) * W + x))  # N
            if x + 1 < W:
                edges.append((u, y * W + (x + 1)))  # E
            if y - 1 >= 0:
                edges.append((u, (y - 1) * W + x))  # S
            if x - 1 >= 0:
                edges.append((u, y * W + (x - 1)))  # W
    return edges


def chan_labels_from_set(chs):
    sorted_ch = sorted(chs)
    remap = {c: i for i, c in enumerate(sorted_ch)}
    labels = [f"ch{c}" for c in sorted_ch]
    return remap, labels


def build_channel_groups_and_labels(num_channels, tiles_per_group,
                                     narrow_req_ch, wide_req_ch, resp_ch):
    """Build descriptive channel labels and group definitions from the NoC config.

    The RTL tracer assigns router_id as the channel. Routers are ordered:
      [0, narrow_end):           Narrow Req routers
      [narrow_end, wide_end):    Wide Req (RDWR) routers
      [wide_end, num_channels):  Wide Resp routers

    Within each range: tiles_per_group × channels_per_tile routers.
    """
    narrow_end = narrow_req_ch * tiles_per_group
    wide_end = narrow_end + wide_req_ch * tiles_per_group
    # resp fills the rest

    labels = []
    groups = []

    if narrow_end > 0:
        narrow_chs = []
        for i in range(narrow_end):
            t, c = divmod(i, narrow_req_ch)
            labels.append(f"NarrowReq_T{t}_C{c}")
            narrow_chs.append(i)
        groups.append({"name": "Narrow Req", "channels": narrow_chs})

    if wide_end > narrow_end:
        wide_chs = []
        for i in range(narrow_end, wide_end):
            off = i - narrow_end
            t, c = divmod(off, wide_req_ch)
            labels.append(f"WideReq_T{t}_C{c}")
            wide_chs.append(i)
        groups.append({"name": "Wide Req", "channels": wide_chs})

    if num_channels > wide_end:
        resp_chs = []
        for i in range(wide_end, num_channels):
            off = i - wide_end
            t, c = divmod(off, resp_ch)
            labels.append(f"Resp_T{t}_C{c}")
            resp_chs.append(i)
        groups.append({"name": "Response", "channels": resp_chs})

    return labels, groups


# Flattened index: value[ tt, hop_bin, mt, ch ] in that order
def offset(tt, hop_bin, mt, ch, num_hop_units, num_channels):
    return (
        tt * (num_hop_units * NUM_MSG_TYPES * num_channels)
        + hop_bin * (NUM_MSG_TYPES * num_channels)
        + mt * num_channels
        + ch
    )


# ---------------- Core builder ------------------------------------------------
def build_dataset(
    rows,
    outdir,
    W,
    H,
    num_hop_units,
    hops_per_unit,
    num_channels,
    channel_labels,
    indent_general=None,
    indent_edges=None,
    debug=False,
    cycles_per_slice=None,
    channel_groups=None,
):
    os.makedirs(os.path.join(outdir, "edge_prefix_sum"), exist_ok=True)

    # Preserve original slice numbering
    slice_set = sorted({s for (s, *_rest) in rows})
    min_slice = min(slice_set)
    max_slice = max(slice_set)

    # Graph edges & indexing
    nb_edges = build_neighbor_edges(W, H)
    E = len(nb_edges)

    # Axis sizes (order = [tt][hop_bin][mt][ch])
    A_tt = NUM_TRANSFERS
    A_hop = num_hop_units
    A_mt = NUM_MSG_TYPES
    A_ch = num_channels

    # Strides for the flattened "value" vector (kept for debugging)
    stride_ch = 1
    stride_mt = A_ch
    stride_hop = A_mt * A_ch
    stride_tt = A_hop * A_mt * A_ch
    val_len = A_tt * A_hop * A_mt * A_ch

    if debug:
        print("=== DEBUG: value layout & strides ===")
        print(" value order: [tt][hop_bin][mt][ch]")
        print(f" axes sizes : tt={A_tt}, hop={A_hop}, mt={A_mt}, ch={A_ch}")
        print(
            f" strides    : stride_tt={stride_tt}, stride_hop={stride_hop}, "
            f"stride_mt={stride_mt}, stride_ch={stride_ch}"
        )
        print(f" value_len  : {val_len}")
        print(f" hops_per_unit={hops_per_unit}, num_hop_units={num_hop_units}")
        print(f" grid       : W={W}, H={H}, nodes={W*H}, edges={E}")
        if channel_labels:
            print(f" channel_labels: {channel_labels}")
        examples = [
            (0, 0, 0, 0),
            (0, 0, 1, 0),
            (0, 1, 0, 0),
            (1, 0, 0, 0),
            (0, 0, 0, min(A_ch - 1, 1)),
        ]
        for tt_, hb_, mt_, ch_ in examples:
            off = offset(tt_, hb_, mt_, ch_, num_hop_units, num_channels)
            print(f" offset(tt={tt_}, hop={hb_}, mt={mt_}, ch={ch_}) = {off}")
        print("=====================================")

    # Accumulators keyed by ORIGINAL slice number (per-slice *deltas*)
    deltas = defaultdict(lambda: defaultdict(lambda: [0] * val_len))
    flat_counts = defaultdict(lambda: defaultdict(int))  # s -> (mt,tt) -> cnt
    per_slice_edge_sum = defaultdict(
        lambda: defaultdict(int)
    )  # s -> (u,v)-> flits

    # Ingest rows → fill per-slice deltas
    out_of_bounds = 0
    non_neighbor = 0
    for s, u, v, tt, mt, ch, fl, ps, pd in rows:
        if not (
            0 <= u < W * H
            and 0 <= v < W * H
            and 0 <= ps < W * H
            and 0 <= pd < W * H
        ):
            out_of_bounds += 1
            continue
        if not is_neighbors(u, v, W, H):
            non_neighbor += 1
            continue

        # Hop bucket by shortest path (packet NI → packet NI)
        L = manhattan(ps, pd, W)
        hb = min(
            L // hops_per_unit if hops_per_unit > 0 else 0,
            max(0, num_hop_units - 1),
        )

        key = (str(u), str(v))
        off = offset(tt, hb, mt, ch, num_hop_units, num_channels)
        deltas[s][key][off] += fl

        flat_counts[s][(mt, tt)] += fl
        per_slice_edge_sum[s][key] += fl

    # Write a baseline "-1.json" with all-zero edge values (prefix-sum baseline)
    zeros_out = [
        {
            "source": str(u),
            "target": str(v),
            "value": [0] * val_len,
            "detail": "",
        }
        for (u, v) in nb_edges
    ]
    dump_json(
        os.path.join(outdir, "edge_prefix_sum", "-1.json"),
        zeros_out,
        indent_edges,
    )

    # --------- WRITE PREFIX SUM SNAPSHOTS FOR EVERY SLICE ---------
    # Running cumulative vector per edge (0..current slice)
    cum_by_key = {(str(u), str(v)): [0] * val_len for (u, v) in nb_edges}

    written_slices = 0
    skipped_empty = 0

    for s in range(min_slice, max_slice + 1):
        # skip writing if this original slice has no traffic
        if not per_slice_edge_sum[s]:
            skipped_empty += 1
            continue

        # Add this slice's *delta* into the cumulative totals
        for key, vec in deltas[
            s
        ].items():  # only edges that changed this slice
            cv = cum_by_key[key]
            # element-wise add
            for j in range(val_len):
                cv[j] += vec[j]

        # Emit cumulative snapshot S[s] (prefix sum)
        edges_out = []
        for u, v in nb_edges:
            key = (str(u), str(v))
            edges_out.append(
                {
                    "source": key[0],
                    "target": key[1],
                    "value": cum_by_key[key][:],  # copy for safety
                    "detail": "",
                }
            )

        dump_json(
            os.path.join(outdir, "edge_prefix_sum", f"{s}.json"),
            edges_out,
            indent_edges,
        )
        written_slices += 1

    # nodes.json
    nodes = [
        {"id": str(i), "label": f"G{i}", "detail": ""} for i in range(W * H)
    ]
    dump_json(os.path.join(outdir, "nodes.json"), nodes, indent_general)

    # meta.json (keep elapse = max original slice; slice=arg.cycle_per_slice)
    meta = {
        "width": W,
        "height": H,
        "slice": cycles_per_slice,
        "elapse": max_slice + 1,
        "hops_per_unit": hops_per_unit,
        "num_hop_units": num_hop_units,
        "num_channels": num_channels,
        "channel_labels": channel_labels,
        "transfer_types": TRANSFER_TYPES,
    }
    if channel_groups:
        meta["channel_groups"] = channel_groups
    dump_json(os.path.join(outdir, "meta.json"), meta, indent_general)

    # flat.json (use original slice ids; keep your explicit-zero policy)
    flat = []
    for s in range(min_slice, max_slice + 1):
        max_flits = (
            max(per_slice_edge_sum[s].values()) if per_slice_edge_sum[s] else 0
        )

        if not flat_counts[s]:
            # explicit empty entry for slices with no traffic
            mt = 0  # "*mem.DataReadyRsp"
            tt = 0  # transfer_type = 0
            flat.append(
                {
                    "id": s,
                    "type": MSG_TYPES[mt],
                    "group": MSG_GROUP[mt],
                    "doc": MSG_DOC[mt],
                    "count": 0,
                    "max_flits": max_flits,
                    "hop_units": 0,
                    "transfer_type": tt,
                }
            )
            continue

        for (mt, tt), cnt in flat_counts[s].items():
            flat.append(
                {
                    "id": s,  # original slice id
                    "type": MSG_TYPES[mt],
                    "group": MSG_GROUP[mt],
                    "doc": MSG_DOC[mt],
                    "count": cnt,
                    "max_flits": max_flits,
                    "hop_units": 0,
                    "transfer_type": tt,
                }
            )
    dump_json(os.path.join(outdir, "flat.json"), flat, indent_general)

    print(f"✔ wrote {outdir}  (slices: {min_slice}..{max_slice}, edges={E})")
    print(
        f"  edge_prefix_sum (prefix): wrote={written_slices}, skipped_empty={skipped_empty}"
    )
    if out_of_bounds or non_neighbor:
        print(
            f"  skipped rows: out_of_bounds={out_of_bounds}, non_neighbor={non_neighbor}"
        )


# ---------------- CLI ---------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description=(
            "Build Vis4Mesh (channel-aware) from RTL CSV, "
            "preserving original slice numbers (writes PREFIX SUM edges)."
        )
    )
    ap.add_argument(
        "csv",
        help="source CSV: slice,edge_src,edge_dst,tt,mt,ch,flits,pkt_src,pkt_dst",
    )
    ap.add_argument("outdir", help="output folder")
    ap.add_argument("--W", type=int, required=True)
    ap.add_argument("--H", type=int, required=True)
    ap.add_argument("--num-hop-units", type=int, default=4)
    ap.add_argument(
        "--hops-per-unit",
        type=int,
        default=0,
        help="0 = auto ceil((W-1+H-1)/num-hop-units)",
    )
    ap.add_argument(
        "--num-channels",
        type=int,
        default=None,
        help="default = max(ch)+1 or remapped",
    )
    ap.add_argument(
        "--channel-map",
        choices=["auto", "identity"],
        default="auto",
        help="auto: remap sparse channel ids to 0..C-1; identity: require dense 0..C-1",
    )
    ap.add_argument(
        "--pretty",
        action="store_true",
        default=True,
        help="Pretty-print meta/nodes/flat.json",
    )
    ap.add_argument(
        "--pretty-edges",
        action="store_true",
        default=False,
        help="Pretty-print edge_prefix_sum/*.json too",
    )
    ap.add_argument(
        "--indent", type=int, default=2, help="Indent size (default: 2)"
    )
    ap.add_argument(
        "--debug",
        action="store_true",
        help="Print stride_tt/stride_hop/stride_mt/stride_ch etc.",
    )
    ap.add_argument(
        "--cycles-per-slice",
        type=int,
        default=10,
        help="Cycles per slice, set 'slice' field in meta.json to this value (default: 10)",
    )
    # TeraNoC-specific: auto-generate channel groups from NoC config
    ap.add_argument(
        "--tiles-per-group",
        type=int,
        default=0,
        help="Tiles per group (enables auto channel labeling/grouping)",
    )
    ap.add_argument(
        "--narrow-req-ch",
        type=int,
        default=0,
        help="Narrow (read-only) request channels per tile",
    )
    ap.add_argument(
        "--wide-req-ch",
        type=int,
        default=2,
        help="Wide (read-write) request channels per tile",
    )
    ap.add_argument(
        "--resp-ch",
        type=int,
        default=2,
        help="Response channels per tile",
    )
    args = ap.parse_args()

    # Load CSV
    rows_raw = []
    with open(args.csv) as f:
        cr = csv.DictReader(f)
        needed = [
            "slice",
            "edge_src",
            "edge_dst",
            "tt",
            "mt",
            "ch",
            "flits",
            "pkt_src",
            "pkt_dst",
        ]
        for k in needed:
            if k not in cr.fieldnames:
                raise RuntimeError(f"CSV missing column: {k}")
        for r in cr:
            rows_raw.append(
                (
                    int(r["slice"]),
                    int(r["edge_src"]),
                    int(r["edge_dst"]),
                    int(r["tt"]),
                    int(r["mt"]),
                    int(r["ch"]),
                    int(r["flits"]),
                    int(r["pkt_src"]),
                    int(r["pkt_dst"]),
                )
            )
    if not rows_raw:
        raise RuntimeError("empty CSV")

    # Channel axis sizing & optional remap
    ch_set = {ch for (_s, _u, _v, _tt, _mt, ch, _fl, _ps, _pd) in rows_raw}
    if args.num_channels is None:
        if args.channel_map == "auto":
            remap, labels = chan_labels_from_set(ch_set)
            rows = [
                (s, u, v, tt, mt, remap[ch], fl, ps, pd)
                for (s, u, v, tt, mt, ch, fl, ps, pd) in rows_raw
            ]
            num_channels = len(remap)
        else:
            num_channels = (max(ch_set) + 1) if ch_set else 1
            if ch_set != set(range(num_channels)):
                raise RuntimeError(
                    f"channel ids not dense 0..{num_channels-1}: {sorted(ch_set)}"
                )
            labels = [f"ch{i}" for i in range(num_channels)]
            rows = rows_raw
    else:
        num_channels = args.num_channels
        if args.channel_map == "auto":
            remap, labels = chan_labels_from_set(ch_set)
            rows = [
                (s, u, v, tt, mt, remap[ch], fl, ps, pd)
                for (s, u, v, tt, mt, ch, fl, ps, pd) in rows_raw
            ]
        else:
            labels = [f"ch{i}" for i in range(num_channels)]
            rows = rows_raw

    # Hop bucketing
    max_possible_hops = (args.W - 1) + (args.H - 1)
    if args.hops_per_unit > 0:
        hops_per_unit = args.hops_per_unit
    else:
        hops_per_unit = max(
            1, math.ceil(max_possible_hops / max(1, args.num_hop_units))
        )

    indent_general = args.indent if args.pretty else None
    indent_edges = args.indent if args.pretty_edges else None

    # Auto-generate channel labels and groups from TeraNoC config
    channel_groups = None
    if args.tiles_per_group > 0:
        labels, channel_groups = build_channel_groups_and_labels(
            num_channels, args.tiles_per_group,
            args.narrow_req_ch, args.wide_req_ch, args.resp_ch,
        )
        if args.debug:
            grp_summary = [g['name'] + '(' + str(len(g['channels'])) + ')' for g in channel_groups]
            print(f"  channel_groups: {grp_summary}")

    build_dataset(
        rows=rows,
        outdir=args.outdir,
        W=args.W,
        H=args.H,
        num_hop_units=args.num_hop_units,
        hops_per_unit=hops_per_unit,
        num_channels=num_channels,
        channel_labels=labels,
        indent_general=indent_general,
        indent_edges=indent_edges,
        debug=args.debug,
        cycles_per_slice=args.cycles_per_slice,
        channel_groups=channel_groups,
    )


if __name__ == "__main__":
    main()
