#!/usr/bin/env python3
"""A/B comparison of two QuestaSim transcripts for the Spatz MLP work.

Aggregates the per-core [VPERF] counters emitted by spatz_vlsu.sv and the benchmark
cycle count, then prints the deltas with a PASS/FAIL read on the expected signature.

Usage:
    ./compare_vperf.py <baseline>/transcript <candidate>/transcript
    ./compare_vperf.py build_base/transcript build_blockalloc/transcript

Expected signature for the block-ROB-reservation change (docs/spatz_mlp_design_plan.md):
    cycles      DOWN     the headline
    win         DOWN     traced VLSU window shrinks
    insn_act    DOWN     <- the mechanism: the 16-cycle alloc walk happens while the
                            instruction IS active (burst_alloc_q set), so the walk is
                            inside insn_act, NOT inside no_insn.
    wait_beats  FLAT     real NoC latency; a >5% move means something other than issue
                            timing changed
    insn_ret    SAME     correctness guard: same work retired, or the kernel changed

no_insn (the retire -> accept turnaround) is reported but NOT checked: its direction is
ambiguous for this change. Removing the walk shortens each instruction's active time, which
can leave the VLSU idle a larger fraction of a now-shorter window. Judge it against win.
"""
import re
import sys
from statistics import mean

VPERF_RE = re.compile(r"\[VPERF\].*?\bwin=(\d+)\s+insn_act=(\d+)\s+no_insn=(\d+)\s+"
                      r"pair_commit=(\d+)\s+single_commit=(\d+)\s+wait_beats=(\d+)\s+"
                      r"vrf_bp=(\d+)\s+req_stall=(\d+)\s+insn_ret=(\d+)")
FIELDS = ["win", "insn_act", "no_insn", "pair_commit", "single_commit",
          "wait_beats", "vrf_bp", "req_stall", "insn_ret"]
CYCLES_RE = re.compile(r"execution took (\d+) cycles")


def parse(path):
    cores, cycles = [], None
    with open(path, errors="replace") as fh:
        for line in fh:
            m = VPERF_RE.search(line)
            if m:
                cores.append({k: int(v) for k, v in zip(FIELDS, m.groups())})
            m = CYCLES_RE.search(line)
            if m:
                cycles = int(m.group(1))
    return cores, cycles


def agg(cores):
    if not cores:
        return {}
    return {f: mean(c[f] for c in cores) for f in FIELDS}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    (a_cores, a_cyc), (b_cores, b_cyc) = parse(sys.argv[1]), parse(sys.argv[2])

    print(f"baseline : {sys.argv[1]}   cores={len(a_cores)}")
    print(f"candidate: {sys.argv[2]}   cores={len(b_cores)}")
    if len(a_cores) != len(b_cores):
        print(f"  !! core-count mismatch ({len(a_cores)} vs {len(b_cores)}) -- if either is < 256, "
              f"the run hit the fd limit; check `ulimit -n` (Makefile sim_ulimit_n).")

    if a_cyc is None or b_cyc is None:
        print("  !! no 'execution took' line in one transcript -- did the run complete?")
    else:
        d = b_cyc - a_cyc
        print(f"\n  CYCLES   {a_cyc:>8}  ->{b_cyc:>8}   {d:+6d}  ({100.0*d/a_cyc:+.2f}%)"
              f"   {'FASTER' if d < 0 else 'SLOWER' if d > 0 else 'same'}")

    A, B = agg(a_cores), agg(b_cores)
    if not A or not B:
        print("  !! no [VPERF] lines -- counters are gated on csr_trace_any_global; "
              "did the benchmark enable tracing?")
        return

    print(f"\n  {'field':<14}{'baseline':>12}{'candidate':>12}{'delta':>12}{'%':>9}")
    for f in FIELDS:
        d = B[f] - A[f]
        pct = (100.0 * d / A[f]) if A[f] else 0.0
        print(f"  {f:<14}{A[f]:>12.1f}{B[f]:>12.1f}{d:>+12.1f}{pct:>+8.1f}%")

    print("\n  SIGNATURE CHECK")
    ok = True

    def check(name, cond, msg):
        nonlocal ok
        ok &= cond
        print(f"    [{'PASS' if cond else 'FAIL'}] {name}: {msg}")

    check("insn_ret unchanged", abs(B["insn_ret"] - A["insn_ret"]) < 0.5,
          f"{A['insn_ret']:.1f} -> {B['insn_ret']:.1f} (must be identical: same work retired)")
    check("no_insn down", B["no_insn"] < A["no_insn"],
          f"{A['no_insn']:.1f} -> {B['no_insn']:.1f} (the direct gap metric)")
    check("wait_beats flat", abs(B["wait_beats"] - A["wait_beats"]) / max(A["wait_beats"], 1) < 0.05,
          f"{A['wait_beats']:.1f} -> {B['wait_beats']:.1f} (>5% move means NoC latency changed, "
          f"not just issue timing)")

    print(f"\n  => {'SIGNATURE MATCHES' if ok else 'SIGNATURE DOES NOT MATCH - investigate before believing the cycle count'}")


if __name__ == "__main__":
    main()
