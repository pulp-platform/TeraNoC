#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Derive the shape-dependent MSHR/hash knobs for sp-fmatmul from (M, N, P).

Several config knobs are NOT independent of the GEMM shape: get them wrong and the
run is silently slow (or illegal). This script derives them from one place so they
cannot drift apart, and validates the shape against the kernel's work-split guards.

Why each knob depends on the shape
----------------------------------
The work split (software/apps/spatz_apps/sp-fmatmul-opt-burst-merge/main.c) gives:

    dim_group      = M / num_groups
    split_m_count  = dim_group / KERNEL_SIZE
    split_p_count  = cores_per_group / split_m_count      (if split_m_count < cores_per_group)

* group_mshr_bank_shift_single = clog2(N)
      Scalar A loads walk a row of A, whose stride is N words. Cores differ in WHICH
      row, i.e. in the address bits at and above clog2(N); selecting those spreads
      them across MSHR banks.

* group_mshr_bank_shift_burst  = clog2(P / split_p_count)
      Sibling cores are offset in p by P/split_p_count words (their p_start gap), so
      those are the bits that distinguish concurrent B bursts.

* group_mshr_bank_burst_bits   = clog2(VL / MaxBurstWords)
      How many bursts one vector load splits into (e32,m2 -> 32/16 = 2 -> 1 bit).

* A and B have DIFFERENT sharing degrees, because the work split separates them:
      A (scalar/"single" loads of a[m][n]): cores sharing an m-block differ only in
          p, so an A line is shared by split_p_count cores.
      B (vector/"burst" loads of b[n][p..p+VL]): cores sharing a p-range differ only
          in m, so a B line is shared by split_m_count cores.
  hence
      group_mshr_hold_subs_single = split_p_count      (A / single target)
      group_mshr_hold_subs_burst  = split_m_count      (B / burst  target)
      group_mshr_merge_reqs       = max(the two)       <-- one entry pool serves both

      Note the degrees INVERT with M: at M=512 both are 4 (which is why the shipped
      config works), but at M=2048 A is private (1) while B is shared 16 ways. Sizing
      merge_reqs from split_p_count alone silently under-provisions large-M shapes.
      If merge_reqs < the sharing degree the surplus requests cannot coalesce and
      issue individually.
      MEASURED (2026-08-01, 22-shape sweep): under-provisioning this does not merely
      slow things down, it REMOVES the benefit of a deeper reduction entirely --
      utilization goes flat at ~24% for every N, because the un-coalesced traffic
      grows with N and cancels the amortization. Same N=128, P=256, only M differing:
          M=256 (8 sharers, 4 slots) -> 24.3%
          M=512 (4 sharers, 4 slots) -> 80.7%    (3.3x, from this knob alone)

Usage
-----
    scripts/gemm_autotune.py -M 512 -N 512 -P 512
    scripts/gemm_autotune.py --json software/apps/spatz_apps/<app>/script/matmul.json
    make ... $(scripts/gemm_autotune.py -M 512 -N 512 -P 512 --make)
"""

import argparse
import json
import math
import re
import sys


def clog2(x):
    return math.ceil(math.log2(x))


def derive(M, N, P, *, num_groups=16, num_cores=256, kernel_size=8,
           vlen=512, elen=32, lmul=2, max_burst_words=16, l1_bytes=None,
           seq_bytes=0x20000, gbar_word=240):
    """Return (knobs, errors, info). errors non-empty => the shape is ILLEGAL."""
    err, info = [], {}
    cores_per_group = num_cores // num_groups

    # ---- kernel work-split guards (mirrored from main.c; a violation makes the
    # cores return early at different points, or divide by zero) ----------------
    if N % 2:
        err.append(f"N={N} must be even (inner loop unrolls n by 2)")
    if M % num_groups:
        err.append(f"M={M} must be a multiple of num_groups={num_groups}")

    dim_group = M // num_groups if num_groups else 0
    if dim_group == 0 or dim_group % kernel_size:
        err.append(f"dim_group=M/{num_groups}={dim_group} must be a multiple of "
                   f"KERNEL_SIZE={kernel_size} (=> M multiple of {num_groups*kernel_size})")
        split_m_count = 0
    else:
        split_m_count = dim_group // kernel_size

    if split_m_count == 0:
        err.append("split_m_count == 0 (dim_group < KERNEL_SIZE)")
        split_p_count = 1
    elif split_m_count < cores_per_group:
        if cores_per_group % split_m_count:
            err.append(f"cores_per_group={cores_per_group} not divisible by "
                       f"split_m_count={split_m_count} -> non-integer split_p_count")
        split_p_count = cores_per_group // split_m_count or 1
        if P % split_p_count:
            err.append(f"P={P} must be divisible by split_p_count={split_p_count}")
    else:
        split_p_count = 1  # else-branch: no P split, every core owns full P

    info.update(dim_group=dim_group, split_m_count=split_m_count,
                split_p_count=split_p_count, cores_per_group=cores_per_group)

    # ---- derived knobs --------------------------------------------------------
    vl_words = (vlen * lmul) // elen            # e32,m2 with VLEN=512 -> 32 words
    gap = (P // split_p_count) if split_p_count else 0

    # A is shared by split_p_count cores, B by split_m_count; one entry pool serves
    # both, so it must cover the larger of the two.
    share_a = split_p_count or 1
    share_b = split_m_count or 1
    merge   = max(share_a, share_b)

    # mempool_group_mshr.sv requires hold_subs in [2, merge_reqs] (elaboration
    # $error). A share degree of 1 means no second requester for that class can
    # EVER arrive, so the legal minimum of 2 has to be paired with a zero hold
    # window -- otherwise every entry of that class waits out the full window for a
    # partner that cannot come. Emitting a bare 1 (as this script used to) builds
    # under Verilator, which does not enforce the elaboration $error, but Questa
    # refuses to elaborate it.
    subs_a = min(max(share_a, 2), merge)
    subs_b = min(max(share_b, 2), merge)

    knobs = {
        "group_mshr_bank_shift_single": clog2(N) if N > 0 else 0,
        "group_mshr_bank_shift_burst": clog2(gap) if gap > 0 else 0,
        "group_mshr_bank_burst_bits": clog2(vl_words // max_burst_words)
                                      if vl_words > max_burst_words else 0,
        "group_mshr_hold_subs_single": subs_a,
        "group_mshr_hold_subs_burst": subs_b,
        "group_mshr_merge_reqs": merge,
    }
    if share_a < 2:
        knobs["group_mshr_hold_window_single"] = 0
        # group_mshr_resp_wait_subs_single gates response DELIVERY on reaching
        # hold_subs_single subscribers, independently of the hold window (see the
        # note at terapool_spatz4_fpu.mk:324). With A private there is no second
        # subscriber, so every scalar entry would ride out group_mshr_serve_timeout
        # -- measured as a 25% regression on 2048x128x128 (100,161 -> 125,433
        # cycles). Disable the delivery gate rather than let it time out.
        knobs["group_mshr_resp_wait_subs_single"] = 0
    if share_b < 2:
        knobs["group_mshr_hold_window_burst"] = 0

    info.update(vl_words=vl_words, p_start_gap_words=gap,
                share_a=share_a, share_b=share_b)

    # RTL elaboration rule: the burst field must sit above the burst-align bits.
    lo = clog2(max_burst_words) + knobs["group_mshr_bank_burst_bits"] - 1
    if knobs["group_mshr_bank_shift_burst"] <= lo:
        err.append(f"shift_burst={knobs['group_mshr_bank_shift_burst']} must be > {lo} "
                   f"(clog2(MaxBurstWords)+burst_bits-1); needs P/split_p_count >= "
                   f"{2**(lo+1)} words")

    # ---- L1 capacity ----------------------------------------------------------
    if l1_bytes is None:
        l1_bytes = gbar_word * 16384          # linker truncates L1 at GROUP_BARRIER_WORD<<14
    usable = l1_bytes - seq_bytes - 16 * 1024  # minus sequential region and small syms
    need = 4 * (M * N + N * P + M * P)
    info.update(l1_need=need, l1_usable=usable)
    if need > usable:
        err.append(f"a+b+c = {need/2**20:.2f} MB exceeds usable L1 {usable/2**20:.2f} MB")

    if N & (N - 1) or P & (P - 1):
        info["warn"] = ("N and/or P is not a power of two: clog2() rounds up, so the "
                        "hash fields are approximate for this shape")
    return knobs, err, info


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-M", type=int); ap.add_argument("-N", type=int)
    ap.add_argument("-P", type=int)
    ap.add_argument("--json", help="matmul.json to read M/N/P from")
    ap.add_argument("--make", action="store_true",
                    help="emit 'k=v' on one line, for splicing into a make command")
    ap.add_argument("--num-groups", type=int, default=16)
    ap.add_argument("--num-cores", type=int, default=256)
    ap.add_argument("--kernel-size", type=int, default=8)
    ap.add_argument("--lmul", type=int, default=2)
    ap.add_argument("--vlen", type=int, default=512)
    args = ap.parse_args()

    if args.json:
        txt = re.sub(r"//.*", "", open(args.json).read())   # matmul.json has // comments
        cfg = json.loads(txt)
        M, N, P = cfg["M"], cfg["N"], cfg["P"]
    elif args.M and args.N and args.P:
        M, N, P = args.M, args.N, args.P
    else:
        ap.error("give -M/-N/-P or --json")

    knobs, err, info = derive(M, N, P, num_groups=args.num_groups,
                              num_cores=args.num_cores, kernel_size=args.kernel_size,
                              vlen=args.vlen, lmul=args.lmul)

    if args.make:
        if err:
            print("ILLEGAL_SHAPE=1", file=sys.stderr)
            for e in err:
                print(f"  ERROR: {e}", file=sys.stderr)
            return 1
        print(" ".join(f"{k}={v}" for k, v in knobs.items()))
        return 0

    print(f"GEMM {M}x{N}x{P}  ({args.num_cores} cores, {args.num_groups} groups, "
          f"KERNEL_SIZE={args.kernel_size}, e{32},m{args.lmul})")
    print(f"  dim_group={info['dim_group']}  split_m_count={info['split_m_count']}  "
          f"split_p_count={info['split_p_count']}  p_start gap={info['p_start_gap_words']} words")
    print(f"  L1 a+b+c = {info['l1_need']/2**20:.2f} MB of {info['l1_usable']/2**20:.2f} MB usable")
    if "warn" in info:
        print(f"  WARNING: {info['warn']}")
    print()
    for k, v in knobs.items():
        print(f"  {k:<32} = {v}")
    if knobs["group_mshr_merge_reqs"] != 4:
        merge = knobs["group_mshr_merge_reqs"]
        # Name the matrix that actually drives the pool size. The degrees INVERT
        # with M: at M<=256 A is the shared one, at M>=1024 it is B. Saying "A"
        # unconditionally is wrong in exactly the B-limited cases.
        which = "each A line" if info["share_a"] >= info["share_b"] else "each B line"
        print(f"\n  NOTE: merge_reqs={merge} (not the default 4). "
              f"{merge} cores share {which} at M={M}\n"
              f"        (A shared {info['share_a']}-way, B shared {info['share_b']}-way);\n"
              f"        leaving it at 4 caps utilization at ~24% regardless of N.")
    if info["share_b"] > info["share_a"]:
        print("\n  WARNING: B is the heavily-shared matrix (M >= 1024). Burst merging is\n"
              "        window-limited, not capacity-limited: sizing merge_reqs is necessary\n"
              "        but buys little (measured 1.01-1.25x). Expect <35% utilization.")
    if err:
        print("\nILLEGAL SHAPE:")
        for e in err:
            print(f"  ERROR: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
