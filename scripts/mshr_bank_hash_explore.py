#!/usr/bin/env python3
"""Explore legal MSHR field-select hashes using the dashboard's request model.

Requires an explicit burst-model version. Score distinct banks at sampled
reduction steps, independently for scalar requests (A + scalar B) and burst B.
This is a bounded bank-spread model, not a performance autotuner. The one-bit
burst selector and legal shifts remain unchanged with tile-contained bursts.
"""
import argparse, math, collections, sys

clog2 = lambda x: 0 if x <= 1 else math.ceil(math.log2(x))


def build(args):
    """Derive the work split, mirroring software/runtime/mshr_cfg.h."""
    g = argparse.Namespace(**vars(args))
    if args.groups < 1 or args.cores < args.groups or args.cores % args.groups:
        raise ValueError('Require an integral, nonempty core count per group')
    g.cpg = args.cores // args.groups                 # cores per group
    if args.split == "decode":
        g.nrow = args.M // args.ks
        if (args.M % args.ks or not g.nrow or args.cores % g.nrow or
            (g.cpg % g.nrow if g.nrow < g.cpg else g.nrow % g.cpg)):
            raise ValueError('Illegal decode partition for this kernel and core count')
        g.npb    = args.cores // g.nrow               # p blocks, machine-wide
        g.pspan  = args.P // g.npb                    # elements of P per core
        g.pb_grp = g.cpg // g.nrow                    # DISTINCT p blocks inside one group
    else:                                             # prefill: a group covers all of P
        rows = args.M // args.groups
        g.nrow = rows // args.ks
        if (args.M % args.groups or rows % args.ks or not g.nrow or
            (g.cpg % g.nrow if g.nrow < g.cpg else rows % (g.cpg * args.ks))):
            raise ValueError('Illegal prefill partition for this kernel and core count')
        g.npb    = max(1, g.cpg // max(1, g.nrow))    # split_p_count
        g.pspan  = args.P // g.npb
        g.pb_grp = g.npb
    if args.P % g.npb:
        raise ValueError('P must divide evenly across column blocks')
    g.lmul     = min(8, max(1, 16 // args.ks))
    g.vl_words = args.vlen * g.lmul // args.elen
    # a core never loads more of P than it owns
    g.load_words = min(g.vl_words, g.pspan * args.elem_bytes // 4)
    g.bankidw  = clog2(args.banks)
    g.align    = clog2(args.max_burst)
    g.ways     = args.entries // args.banks if args.banks else 0
    return g


def bank_of(word_addr, sh, bb, bankidw, align):
    if bb == 0:
        return (word_addr >> sh) & ((1 << bankidw) - 1)
    hi = (word_addr >> sh) & ((1 << (bankidw - bb)) - 1)
    lo = (word_addr >> align) & ((1 << bb) - 1)
    return (hi << bb) | lo


def spread(addrs, sh, bb, g):
    """CONCURRENCY spread, not aggregate.

    The MSHR holds requests that are OUTSTANDING AT THE SAME TIME, so the figure of merit is
    how many distinct banks one group's cores reach at a FIXED point in the k loop -- not how
    many banks the loop visits over its whole life. Those differ wildly: putting the bank field
    on the k stride visits all 16 banks over time while every core collides in ONE bank at any
    instant, which is the worst case for a structure whose job is concurrency.

    `addrs` is a list of (step, word_addr): step = the k-loop index that groups concurrent
    requests together.
    """
    per_step = collections.defaultdict(set)
    h = collections.Counter()
    for step, a in addrs:
        b = bank_of(a, sh, bb, g.bankidw, g.align)
        per_step[step].add(b)
        h[b] += 1
    if not per_step:
        return 0, 0.0, h
    avg = sum(len(v) for v in per_step.values()) / len(per_step)
    return round(avg), avg / g.banks, h


def draw(h, g, title, width=46):
    print(f"    {title}")
    if not h:
        print("      (no accesses)")
        return
    mx = max(h.values())
    for b in range(g.banks):
        n = h.get(b, 0)
        bar = "#" * int(round(width * n / mx)) if n else ""
        tag = "" if n else "  <- idle"
        print(f"      bank {b:2d} |{bar:<{width}}| {n}{tag}")


def main():
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim_dashboard'))
    from trace_dashboard.analysis import hash_explore
    p = argparse.ArgumentParser(description=__doc__)
    for dimension in ('M', 'N', 'P'):
        p.add_argument('--'+dimension, type=int, required=True)
    p.add_argument('--ks', type=int, default=8)
    p.add_argument('--elem-bytes', type=int, choices=(2, 4), default=2)
    p.add_argument('--entries', type=int, default=64)
    p.add_argument('--banks', type=int, default=16)
    p.add_argument('--cores', type=int, default=256)
    p.add_argument('--groups', type=int, default=16)
    p.add_argument('--vlen', type=int, default=512)
    p.add_argument('--elen', type=int, choices=(32,), default=32)
    p.add_argument('--split', choices=('decode', 'prefill'), default='decode')
    p.add_argument('--group', type=int, default=0)
    p.add_argument('--current', nargs=3, type=int, default=[4, 4, 0])
    p.add_argument('--burst-model', choices=('aligned-v1', 'tile-contained-v1'), required=True)
    p.add_argument('--tile-words', type=int, default=16)
    p.add_argument('--max-burst', type=int, default=16)
    p.add_argument('--lanes', type=int, default=4)
    p.add_argument('--rob-depth', type=int, default=32)
    p.add_argument('--sample-steps', type=int, default=16)
    p.add_argument('--a-base', type=lambda x: int(x, 0), default=0)
    p.add_argument('--b-base', type=lambda x: int(x, 0))
    # Accept old flags only when they describe the supported RTL contract.
    p.add_argument('--min-burst', type=int, choices=(2,), default=2)
    p.add_argument('--hw-burst-bits-max', type=int, choices=(1,), default=1)
    a = p.parse_args()
    if a.cores % a.groups or not 0 <= a.group < a.groups:
        p.error('Require integral cores/group and a valid group')
    meta = dict(mesh=[a.groups, 1], tiles_per_group=a.cores//a.groups, cores_per_tile=1,
                shape=[a.M, a.N, a.P], precision='fp16' if a.elem_bytes == 2 else 'fp32',
                vlen=a.vlen, banks_per_tile=a.tile_words, burst_model=a.burst_model,
                burst_geometry=dict(tile_words=a.tile_words, max_words=a.max_burst,
                                    lanes=a.lanes, rob_depth=a.rob_depth),
                hash=dict(kernel=a.ks, split=a.split, banks=a.banks, entries=a.entries,
                          current=a.current, max_steps=a.sample_steps, a_base=a.a_base,
                          w_base=a.b_base if a.b_base is not None else a.M*a.N*a.elem_bytes))
    try:
        result = hash_explore(meta)
    except (ValueError, ZeroDivisionError) as error:
        p.error(str(error))
    if not result['available']:
        p.error(result['reason'])
    group = result['groups'][a.group]
    print(f"Group {a.group}: {a.burst_model}, B requests {group['request_counts']}")
    print(result['note'])
    for label, key, current in [('Singles (A + scalar B)', 'singles', 'current_a'),
                                ('Bursts (B)', 'weights', 'current_w')]:
        print(label, 'current:', group[current])
        for candidate in group[key]:
            print('  candidate:', candidate)


if __name__ == '__main__':
    main()
