#!/usr/bin/env python3
"""Scrape delivered 8x8 arm transcripts into docs/benchmarks/8x8_scaleup/results.tsv.

Keyed on the run-prefix on disk (hardware/s8_<arm>/transcript), so it is batch-agnostic and
picks up every wave without being told which batches exist.

Two habits this file exists to enforce:
  * strip QuestaSim's leading "# " before ANY anchored match -- VCS logs have no such prefix, so
    a pattern like ^\\[FPU\\] silently matches zero lines on a Questa arm and that arm reads as
    "no data" rather than "wrong filter".
  * record the spotcheck GROUP COUNT, not just presence. A perf number with no correctness
    signal is not a result; a kernel that computes garbage faster still wins a sweep.
"""
import os, re, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")
MANI = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/manifest.txt")
HDR  = "shape\tprec\tA_share\tcycles\tRH\tmshr_timeout\tbankfull\tspotcheck\tstate"

def a_share(M):
    # at 8x8 the A-row sharing degree is set by M alone
    return {512: 16, 1024: 8, 2048: 4, 4096: 2}.get(M, 1)

def scrape(arm):
    t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
    if not os.path.exists(t):
        return None
    raw = open(t, "rb").read()
    # normalise the Questa prefix once, here, before anything anchored runs
    txt = b"\n".join(l[2:] if l.startswith(b"# ") else l for l in raw.split(b"\n"))
    cyc = re.findall(rb"execution took (\d+)", txt)
    if not cyc:
        return dict(state="running")
    def tot(tag):
        return sum(int(x) for x in re.findall(tag.encode() + rb"=\+?(\d+)", txt))
    spot = len(re.findall(rb"^\[SPOT\] g=", txt, re.M))
    return dict(state="done", cycles=int(cyc[-1]), rh=txt.count(b"RH STUCK"),
                tmo=tot("mshr_timeout"), bf=tot("bankfull_bypass"), spot=spot)

def main():
    rows, ndone = [], 0
    for ln in open(MANI):
        p = ln.split()
        if len(p) != 4:
            continue
        M, N, P, PR = int(p[0]), int(p[1]), int(p[2]), p[3]
        arm = "fp%s_%dx%dx%d" % (PR, M, N, P)
        r = scrape(arm)
        if not r or r["state"] != "done":
            continue
        ndone += 1
        # 64 groups at 8x8: fewer [SPOT] lines than groups means the probe did not complete
        sc = "ok(%d)" % r["spot"] if r["spot"] >= 64 else ("PARTIAL(%d)" % r["spot"] if r["spot"] else "MISSING")
        rows.append("%dx%dx%d\tfp%s\t%d\t%d\t%d\t%d\t%d\t%s\tdone"
                    % (M, N, P, PR, a_share(M), r["cycles"], r["rh"], r["tmo"], r["bf"], sc))
    rows.sort(key=lambda s: int(s.split("\t")[3]))
    with open(OUT, "w") as f:
        f.write(HDR + "\n")
        for r in rows:
            f.write(r + "\n")
    print("  results.tsv: %d completed arm(s)" % ndone)
    bad = [r for r in rows if "ok(" not in r]
    if bad:
        print("  WITHOUT a full spotcheck (do not quote these):")
        for r in bad:
            print("    " + "\t".join(r.split("\t")[:2] + [r.split("\t")[7]]))

main()
