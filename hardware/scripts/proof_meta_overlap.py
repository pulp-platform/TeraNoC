#!/usr/bin/env python3
"""
B2 / F7 equivalence proof: can the 2,048 replicated 32-bit mask AND + OR-reduce
overlap tests be replaced by a two-sided modular range test?

RTL today (mempool_group_mshr.sv:1671-1681):
    ovlp = |(req_meta_mask[t][p] & mshr_meta_mask[e])
with (mempool_group_mshr.sv:1071-1078)
    mask(base, len)[k] = ((k - base) mod M) < len      # meta_id_t unsigned wrap

Proposed:
    ovlp = ((baseB - baseA) mod M) < lenA  ||  ((baseA - baseB) mod M) < lenB

This script decides the question exhaustively rather than by argument, matching
the precedent the file set for the mask form itself.
"""
import sys

def mask(base, ln, M):
    return {k for k in range(M) if ((k - base) % M) < ln}

def ref_overlap(bA, lA, bB, lB, M):
    return bool(mask(bA, lA, M) & mask(bB, lB, M))

def naive(bA, lA, bB, lB, M):
    return ((bB - bA) % M) < lA or ((bA - bB) % M) < lB

def guarded(bA, lA, bB, lB, M):
    if lA == 0 or lB == 0:
        return False
    return ((bB - bA) % M) < lA or ((bA - bB) % M) < lB

def sweep(M, maxlen, fn, name):
    bad = []
    n = 0
    for bA in range(M):
        for lA in range(0, maxlen + 1):
            for bB in range(M):
                for lB in range(0, maxlen + 1):
                    n += 1
                    if fn(bA, lA, bB, lB, M) != ref_overlap(bA, lA, bB, lB, M):
                        if len(bad) < 5:
                            bad.append((bA, lA, bB, lB))
    return n, bad, name

if __name__ == "__main__":
    # This config: meta_id_t is MetaIdWidth=6 (spatz_vlsu_rob_depth=64) -> M=64.
    # MaxBurstWords=16, so len in [0,16]; the len>M case cannot arise here but is
    # swept anyway at the smaller M to confirm the reasoning does not depend on it.
    for M, maxlen in ((64, 16), (32, 16), (8, 16)):
        print(f"\n=== MetaSpace M={M}, len 0..{maxlen} ===")
        for fn, name in ((naive, "naive two-sided"), (guarded, "guarded (len>0)")):
            n, bad, nm = sweep(M, maxlen, fn, name)
            status = "MATCHES" if not bad else f"MISMATCH ({len(bad)}+ shown)"
            print(f"  {nm:<20} {n:>9} cases   {status}")
            for b in bad:
                bA, lA, bB, lB = b
                print(f"      baseA={bA} lenA={lA}  baseB={bB} lenB={lB} "
                      f"-> ref={ref_overlap(bA,lA,bB,lB,M)} got={fn(bA,lA,bB,lB,M)}")
