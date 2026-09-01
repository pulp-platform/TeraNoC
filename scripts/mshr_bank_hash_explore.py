#!/usr/bin/env python3
"""Explore MSHR bank-hash settings for one GEMM shape, and show the resulting spread.

Answers three questions for a given (shape, kernel size, MSHR geometry):

  1. Is the load BURST-eligible at all, or does it fall back to word-interleaved singles?
  2. Which address bits, if selected, spread A and W accesses evenly over the banks
     of ONE GROUP's MSHR -- the unit that matters, because the MSHR is source-side
     (a request enters the MSHR of its SOURCE core's group, not the address's group).
  3. What does the current / proposed setting actually do, drawn as a histogram.

Model of the hardware (mempool_group_mshr.sv, BankHash==3 "field-select"):

    single : bank = word_addr[sh_single +: BankIdW]
    burst  : bank = { word_addr[sh_burst +: BankIdW-bb] , word_addr[align +: bb] }

where `align = clog2(max_burst_words)` and `bb` = bank_burst_bits, i.e. the low `bb`
bank bits come from WITHIN the load (which burst of the load this is) and the rest
from the gap between p-slices.

  !! The shipping RTL declares `input logic burst_bits` and the CSR stores
     `wr_data_i[0]` -- ONE BIT. Any derived value above 1 is silently truncated to its
     LSB. This tool reports the ideal bb and flags when the hardware cannot hold it.
"""
import argparse, math, collections, sys

clog2 = lambda x: 0 if x <= 1 else math.ceil(math.log2(x))


def build(args):
    """Derive the work split, mirroring software/runtime/mshr_cfg.h."""
    g = argparse.Namespace(**vars(args))
    g.cpg = args.cores // args.groups                 # cores per group
    if args.split == "decode":
        g.nrow   = max(1, args.M // args.ks)          # row chunks
        g.npb    = args.cores // g.nrow               # p blocks, machine-wide
        g.pspan  = args.P // g.npb                    # elements of P per core
        g.pb_grp = g.cpg // g.nrow                    # DISTINCT p blocks inside one group
    else:                                             # prefill: a group covers all of P
        g.nrow   = max(1, (args.M // args.groups) // args.ks)
        g.npb    = max(1, g.cpg // max(1, g.nrow))    # split_p_count
        g.pspan  = args.P // g.npb
        g.pb_grp = g.npb
    g.lmul     = max(1, 16 // args.ks)
    g.vl_words = args.vlen * g.lmul // args.elen
    # a core never loads more of P than it owns
    g.load_words = min(g.vl_words, g.pspan * args.elem_bytes // 4)
    g.bankidw  = clog2(args.banks)
    g.align    = clog2(args.max_burst)
    g.ways     = args.entries // args.banks if args.banks else 0
    return g


def burst_feasible(g):
    """Bursts are LOADS of at least min_burst contiguous words, capped at max_burst."""
    reasons = []
    ok = True
    if g.load_words < g.min_burst:
        ok = False
        reasons.append(f"per-core contiguous run is {g.load_words} words < min_burst {g.min_burst}")
    if g.pspan * g.elem_bytes // 4 < g.min_burst:
        ok = False
        reasons.append(f"p_span is only {g.pspan} elements = {g.pspan*g.elem_bytes//4} words")
    nb = g.load_words // g.max_burst if g.max_burst else 0
    if ok and nb == 0:
        reasons.append(f"one partial burst of {g.load_words} words (< max_burst {g.max_burst})")
    elif ok:
        reasons.append(f"{nb} full burst(s) of {g.max_burst} words per load")
    return ok, nb, reasons


def bank_of(word_addr, sh, bb, bankidw, align):
    if bb == 0:
        return (word_addr >> sh) & ((1 << bankidw) - 1)
    hi = (word_addr >> sh) & ((1 << (bankidw - bb)) - 1)
    lo = (word_addr >> align) & ((1 << bb) - 1)
    return (hi << bb) | lo


def accesses(g, grp):
    """Word addresses one GROUP's cores issue in the inner loop, split by class."""
    A, W = [], []
    wbase = g.a_words                     # W starts after A in the linear model
    for c in range(g.cpg):
        cid  = grp * g.cpg + c
        if g.split == "decode":
            pblk = cid // g.nrow
            rc   = cid % g.nrow
        else:
            pblk = (cid % g.cpg) % g.npb
            rc   = (cid % g.cpg) // max(1, g.npb)
        p0 = pblk * g.pspan
        m0 = rc * g.ks
        for d in range(g.N):
            # W[d][p0 ...] -- one burst-class load per d per core, split into its bursts so the
            # intra-load bits (what bank_burst_bits selects) are represented.
            base = wbase + (d * g.P + p0) * g.elem_bytes // 4
            nb = max(1, g.load_words // g.max_burst)
            for k in range(nb):
                W.append((d, base + k * g.max_burst))
        for b in range(m0, min(m0 + g.ks, g.M)):
            for d in range(0, g.N, 8):
                A.append((d, (b * g.N + d) * g.elem_bytes // 4))
    return A, W


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
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--M", type=int, required=True, help="GEMM M (= decode batch B)")
    p.add_argument("--N", type=int, required=True, help="GEMM N (= D, the inner/reduction dim)")
    p.add_argument("--P", type=int, required=True, help="GEMM P (= I, the output dim)")
    p.add_argument("--ks", type=int, default=8, help="KERNEL_SIZE (8/4/2/1)")
    p.add_argument("--elem-bytes", type=int, default=2, help="2=fp16, 4=fp32")
    p.add_argument("--min-burst", type=int, default=16, dest="min_burst",
                   help="minimum contiguous words for a burst")
    p.add_argument("--max-burst", type=int, default=16, dest="max_burst",
                   help="MaxBurstWords: words per burst beat group")
    p.add_argument("--entries", type=int, default=64, help="MSHR entries per group (MshrNum)")
    p.add_argument("--banks", type=int, default=16, help="MSHR banks per group")
    p.add_argument("--cores", type=int, default=256)
    p.add_argument("--groups", type=int, default=16)
    p.add_argument("--vlen", type=int, default=512)
    p.add_argument("--elen", type=int, default=32)
    p.add_argument("--split", choices=("decode", "prefill"), default="decode")
    p.add_argument("--group", type=int, default=0, help="which group's MSHR to analyse")
    p.add_argument("--current", nargs=3, type=int, metavar=("SH_S", "SH_B", "BB"),
                   help="also evaluate this current setting")
    p.add_argument("--hw-burst-bits-max", type=int, default=1, dest="hwbb",
                   help="what the CSR field can actually hold (shipping RTL: 1)")
    a = p.parse_args()
    a.a_words = 0  # A at 0; W placed after A below
    g = build(a)
    g.a_words = (g.M * g.N * g.elem_bytes // 4)

    print(f"\n  SHAPE {g.M}x{g.N}x{g.P}  ks={g.ks}  {'fp16' if g.elem_bytes==2 else 'fp32'}"
          f"  split={g.split}  {g.cores} cores / {g.groups} groups")
    print(f"  work split : row_chunks={g.nrow}  p_blocks(machine)={g.npb}  p_span={g.pspan} elem"
          f"  p_blocks in ONE group={g.pb_grp}")
    print(f"  vector     : LMUL=m{g.lmul}  vl={g.vl_words} words  per-core contiguous run="
          f"{g.load_words} words")
    print(f"  MSHR       : {g.entries} entries / {g.banks} banks = {g.ways} ways, BankIdW={g.bankidw},"
          f" burst align bit={g.align}")

    ok, nb, why = burst_feasible(g)
    print(f"\n  BURST FEASIBLE: {'YES' if ok else 'NO'}")
    for r in why:
        print(f"    - {r}")

    A, W = accesses(g, a.group)
    print(f"\n  ceiling on distinct banks reachable in group {a.group}:")
    print(f"    W (burst) : {g.pb_grp} distinct p-slices  -> at most {g.pb_grp} banks from p alone")
    print(f"    the k loop stride is {g.P*g.elem_bytes//4} words; it moves a bank bit only if the"
          f" selected field overlaps bit {clog2(g.P*g.elem_bytes//4)}+")

    # ---- search ------------------------------------------------------------------
    best = []
    for bb in range(0, g.bankidw):
        for sh in range(g.align + bb, 21):
            uW, eW, _ = spread(W, sh, bb, g)
            best.append((uW, round(eW, 4), sh, bb))
    best.sort(key=lambda t: (-t[0], -t[1], t[2], t[3]))
    print(f"\n  BEST BURST (W) SETTINGS  [shift, burst_bits] -> banks reached CONCURRENTLY")
    seen = set()
    for uW, eW, sh, bb in best:
        if (uW, bb) in seen:
            continue
        seen.add((uW, bb))
        flag = "" if bb <= g.hwbb else f"   !! CSR holds only {g.hwbb} bit -> truncates to {bb & ((1<<g.hwbb)-1)}"
        print(f"    sh_burst={sh:2d}  bb={bb}  ->  {uW:2d}/{g.banks} banks concurrently, frac={eW:.3f}{flag}")
        if len(seen) >= 6:
            break

    bestA = []
    for sh in range(0, 21):
        uA, eA, _ = spread(A, sh, 0, g)
        bestA.append((uA, round(eA, 4), sh))
    bestA.sort(key=lambda t: (-t[0], -t[1], t[2]))
    print(f"\n  BEST SINGLE (A) SHIFT -> banks reached CONCURRENTLY")
    for uA, eA, sh in bestA[:4]:
        print(f"    sh_single={sh:2d}  ->  {uA:2d}/{g.banks} banks concurrently, frac={eA:.3f}")

    # ---- illustration ------------------------------------------------------------
    if a.current:
        shs, shb, bb = a.current
        eff = bb & ((1 << g.hwbb) - 1)
        print(f"\n  CURRENT SETTING  sh_single={shs} sh_burst={shb} burst_bits={bb}"
              + (f"  (hardware truncates to {eff})" if eff != bb else ""))
        uW, eW, hW = spread(W, shb, eff, g)
        uA, eA, hA = spread(A, shs, 0, g)
        print(f"    W bursts : {uW}/{g.banks} banks CONCURRENTLY (fraction {eW:.3f})")
        draw(hW, g, "W (burst) bank occupancy")
        print(f"    A singles: {uA}/{g.banks} banks CONCURRENTLY (fraction {eA:.3f})")
        draw(hA, g, "A (single) bank occupancy")

    if best:
        uW, eW, sh, bb = best[0]
        bb_hw = min(bb, g.hwbb)
        uW2, eW2, hW2 = spread(W, sh, bb_hw, g)
        print(f"\n  BEST ACHIEVABLE ON THIS HARDWARE  sh_burst={sh} burst_bits={bb_hw}"
              f"  -> {uW2}/{g.banks} banks concurrently, frac {eW2:.3f}")
        draw(hW2, g, "W (burst) bank occupancy at the best hardware-representable setting")
        if bb > g.hwbb:
            print(f"\n    !! ideal burst_bits is {bb}; the CSR field is {g.hwbb} bit"
                  f" (mempool_group_mshr_cfg.sv:179 stores wr_data_i[0]).")
            print(f"       Widening that field would give {uW}/{g.banks} banks"
                  f" (frac {eW:.3f}).")
    print()


if __name__ == "__main__":
    main()
