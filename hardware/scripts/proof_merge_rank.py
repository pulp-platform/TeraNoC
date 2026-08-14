#!/usr/bin/env python3
"""
C1 / F11(a) equivalence proof: can the 32-deep serial merge read-modify-write be
replaced by a parallel prefix-popcount rank?

RTL today (mempool_group_mshr.sv, merge accept inside the (tile,port) loop):
    ready_p = merge_ready_p && (d[e].sub_reqs_num + 1 <= MergeReqs)
    if ready_p:
        slot            = d[e].sub_reqs_num          # reads the value earlier ports left
        d[e].sub_reqs[slot] = <port p payload>
        d[e].sub_reqs_num  += 1
        d[e].served_cnt    += 1
so port p observes every earlier port's increment: a true up-to-32-link chain.

Proposed parallel form, all ports evaluated against the REGISTERED value:
    rank_p  = #{q < p : merge_valid_q && merge_ready_q && target_q == e}
    ready_p = merge_ready_p && (q[e].sub_reqs_num + rank_p + 1 <= MergeReqs)
    slot_p  = q[e].sub_reqs_num + rank_p

The subtlety this script exists to settle: in the serial form a REJECTED port does
not increment, so the next port sees the same count; in the parallel form the
rejected port still occupies a rank. Those differ unless rejection is always a
suffix of the merging ports. Decided exhaustively/randomly rather than by argument.
SECOND SECTION (added 2026-08-14) extends the proof to the STATE transitions the
merge block also chains serially: CACHED -> DRAIN_RESP, and the RespWaitSubsSingle
RESP_HOLD release whose guard reads the post-increment sub_reqs_num. Both write
identical values (state, beats_left=1, beat_pending/beat_pending2/beat2_armed
clears), so they are idempotent: the serial form fires them once from the first
qualifying port, the parallel form fires them from every qualifying port with the
same result.

Prerequisite verified separately against the RTL: state / sub_reqs_num /
served_cnt are written ZERO times before the merge door, so mshr_d == mshr_q for
exactly the fields the parallel form reads.
"""
import random, itertools, sys

def serial(start_num, targets, merge_ready, MERGE_REQS):
    """targets[p] = entry id or None; returns (accepted_slots, final_num)."""
    num = dict(start_num)
    slots, served = {}, {}
    for p, e in enumerate(targets):
        if e is None or not merge_ready[p]:
            continue
        if num[e] + 1 <= MERGE_REQS:
            slots[p] = num[e]
            num[e] += 1
            served[e] = served.get(e, 0) + 1
    return slots, num

def parallel(start_num, targets, merge_ready, MERGE_REQS):
    num = dict(start_num)
    slots = {}
    final = dict(start_num)
    for p, e in enumerate(targets):
        if e is None or not merge_ready[p]:
            continue
        rank = sum(1 for q in range(p)
                   if targets[q] == e and merge_ready[q])
        if num[e] + rank + 1 <= MERGE_REQS:
            slots[p] = num[e] + rank
    for e in set(t for t in targets if t is not None):
        cnt = sum(1 for p in slots if targets[p] == e)
        final[e] = num[e] + cnt
    return slots, final

def run(nports, nentries, MERGE_REQS, trials, rng):
    bad = []
    for _ in range(trials):
        start = {e: rng.randint(0, MERGE_REQS) for e in range(nentries)}
        targets = [rng.choice([None] + list(range(nentries))) for _ in range(nports)]
        ready = [rng.random() < 0.85 for _ in range(nports)]
        s_slots, s_num = serial(start, targets, ready, MERGE_REQS)
        p_slots, p_num = parallel(start, targets, ready, MERGE_REQS)
        if s_slots != p_slots or s_num != p_num:
            bad.append((start, targets, ready, s_slots, p_slots, s_num, p_num))
            if len(bad) >= 3:
                break
    return bad

def run_slot_proof():
    rng = random.Random(20260813)
    total_bad = 0
    # This config: 16 tiles x 2 req ports = 32 merging ports, MshrMergeReqs = 8.
    for nports, nentries, MR in ((32, 4, 8), (32, 1, 8), (8, 2, 4), (8, 1, 2), (4, 1, 1)):
        bad = run(nports, nentries, MR, 20000, rng)
        tag = f"ports={nports} entries={nentries} MergeReqs={MR}"
        print(f"  {tag:<40} {'MATCHES' if not bad else 'MISMATCH'}")
        for b in bad:
            total_bad += 1
            print(f"    start={b[0]} targets={b[1]}")
            print(f"    ready={b[2]}")
            print(f"    serial slots={b[3]} num={b[5]}")
            print(f"    parall slots={b[4]} num={b[6]}")
    # Exhaustive small case: every target/ready assignment for 4 ports, 1 entry.
    print("\n  exhaustive: 4 ports, 1 entry, MergeReqs 1..4, all start counts")
    ex_bad = 0
    for MR in range(1, 5):
        for start in range(0, MR + 1):
            for targets in itertools.product([None, 0], repeat=4):
                for ready in itertools.product([False, True], repeat=4):
                    s = serial({0: start}, list(targets), list(ready), MR)
                    p = parallel({0: start}, list(targets), list(ready), MR)
                    if s != p:
                        ex_bad += 1
                        if ex_bad <= 3:
                            print(f"    MISMATCH MR={MR} start={start} t={targets} r={ready}")
                            print(f"      serial={s}  parallel={p}")
    print(f"  exhaustive small case: {'MATCHES' if ex_bad == 0 else f'{ex_bad} MISMATCHES'}")
    return total_bad + ex_bad


# ---------------------------------------------------------------------------
# Section 2: state transitions (see the docstring).
# ---------------------------------------------------------------------------
CACHED, RESP_HOLD, DRAIN = 'CACHED', 'RESP_HOLD', 'DRAIN_RESP'

def serial_st(q_num, q_state, targets, ready, MR, HSS):
    num, st, slots = dict(q_num), dict(q_state), {}
    for p, e in enumerate(targets):
        if e is None or not ready[p]: continue
        if num[e] + 1 <= MR:
            slots[p] = num[e]; num[e] += 1
            if st[e] == CACHED:                        st[e] = DRAIN
            elif st[e] == RESP_HOLD and num[e] >= HSS: st[e] = DRAIN
    return slots, num, st

def parallel_st(q_num, q_state, targets, ready, MR, HSS):
    num, st, slots = dict(q_num), dict(q_state), {}
    rankof = {}
    for p, e in enumerate(targets):
        if e is None or not ready[p]: continue
        r = sum(1 for x in range(p) if targets[x] == e and ready[x])
        rankof[p] = r
        if num[e] + r + 1 <= MR: slots[p] = num[e] + r
    for e in set(t for t in targets if t is not None):
        acc = [p for p in slots if targets[p] == e]
        if not acc: continue
        if st[e] == CACHED: st[e] = DRAIN
        elif st[e] == RESP_HOLD and any(num[e] + rankof[p] + 1 >= HSS for p in acc): st[e] = DRAIN
        num[e] = num[e] + len(acc)
    return slots, num, st

def run_state_proof(trials=200000, seed=20260814):
    rng = random.Random(seed); bad = 0
    for _ in range(trials):
        NE, NP, MR = 4, 32, 8
        HSS = rng.choice([2, 4, 8])
        qn = {e: rng.randint(0, MR) for e in range(NE)}
        qs = {e: rng.choice([CACHED, RESP_HOLD, DRAIN]) for e in range(NE)}
        tg = [rng.choice([None] + list(range(NE))) for _ in range(NP)]
        rd = [rng.random() < 0.85 for _ in range(NP)]
        if serial_st(qn, qs, tg, rd, MR, HSS) != parallel_st(qn, qs, tg, rd, MR, HSS):
            bad += 1
    print(f"\n  state-transition proof: {trials:,} configs -> "
          f"{'ALL MATCH' if bad == 0 else f'{bad} MISMATCHES'}")
    return bad

def _main():
    # NOTE: section 3 lives below and used to sit behind its OWN `if __name__` block, which the
    # sys.exit() here made unreachable -- the same defect fd655237 fixed for sections 1/2. One
    # entry point now, so adding a section cannot silently stop it from running.
    print("  === section 1: slot assignment and count accumulation ===")
    bad1 = run_slot_proof()
    print("\n  === section 2: state transitions ===")
    bad2 = run_state_proof()
    bad3 = _section3_report()
    sys.exit(1 if (bad1 or bad2 or bad3) else 0)


# =============================================================================
# SECTION 3 (added 2026-08-14, after an external review found a REAL bug this
# script had missed): BOUNDED-WIDTH rank and slot.
#
# Why sections 1-2 could not see it. They model rank and slot as Python ints --
# unbounded. The shipped RTL stored both in SubReqCountW = idx_width(MergeReqs+1)
# bits, and computed the rank as SubReqCountW'($countones(<32-bit mask>)). So a
# rank above the field range WRAPPED, slot = sub_reqs_num + rank wrapped again,
# and the capacity check ran on the wrapped value: a slot that wrapped to a small
# number PASSES the check and overwrites a LIVE sub_reqs[] record, orphaning the
# owner's response. Modelling the arithmetic as unbounded hides exactly this.
#
# Lesson worth keeping: an equivalence proof must model the WIDTHS the RTL uses,
# not just the algorithm. This section fails against the old widths and passes
# against the fix (saturate rank at MergeReqs; size rank/slot for 2*MergeReqs).
# =============================================================================

def _w(n):
    import math
    return max(1, math.ceil(math.log2(n)))


def section3(merge_reqs, alloc_slots=32, trials=200000, buggy=False, seed=99):
    """Return the first counterexample where the bounded form corrupts a live slot."""
    import random
    rnd = random.Random(seed)
    sub_w = _w(merge_reqs + 1)
    if buggy:
        rank_w = slot_w = sub_w                      # the shipped widths
    else:
        rank_w = slot_w = _w(2 * merge_reqs + 1)     # the fix
    cnt_w = _w(alloc_slots + 1)

    for _ in range(trials):
        num = rnd.randint(0, merge_reqs)             # registered sub_reqs_num
        true_rank = rnd.randint(0, alloc_slots - 1)  # capacity-BLIND, so it can be large

        if buggy:
            rank = true_rank % (1 << rank_w)
        else:
            raw = true_rank % (1 << cnt_w)
            rank = merge_reqs if raw >= merge_reqs else raw   # saturate

        slot = (num + rank) % (1 << slot_w)
        accepted = (slot + 1) <= merge_reqs

        # Reference: unbounded arithmetic, the intended behaviour.
        ref_slot = num + true_rank
        ref_accepted = (ref_slot + 1) <= merge_reqs

        if accepted != ref_accepted or (accepted and slot != ref_slot):
            return dict(merge_reqs=merge_reqs, sub_reqs_num=num, true_rank=true_rank,
                        rank=rank, slot=slot, accepted=accepted,
                        ref_slot=ref_slot, ref_accepted=ref_accepted,
                        corrupts_live_slot=accepted and slot < num)
    return None


def _section3_report():
    print("\n  === section 3: bounded-width rank/slot ===")
    any_fix_fail = False
    for mr in (4, 8, 16):
        bad = section3(mr, buggy=True)
        good = section3(mr, buggy=False)
        print(f"\n  merge_reqs={mr}")
        print(f"    OLD widths   {'FAIL (bug reproduced) -> ' + str(bad) if bad else 'pass -- raise trials'}")
        print(f"    FIXED widths {'pass' if good is None else 'FAIL -> ' + str(good)}")
        if good is not None:
            any_fix_fail = True
    return any_fix_fail


if __name__ == '__main__':
    _main()
