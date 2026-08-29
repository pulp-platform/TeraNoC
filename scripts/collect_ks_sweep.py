#!/usr/bin/env python3
"""Collect the B x KS decode sweep and score it.

Arms are named  sw_<mesh>_<prec>_ks<KS>_<B>x<D>x<I>  -- KS and precision are in the NAME because
there is no way to read kernel_size back out of a transcript (the existing collector carries the
same warning). A shape-only name would also let the four KS variants of one B overwrite each
other's ELF, so the build driver sets OUT_PREFIX from the same fields.

CORRECTNESS ORACLE: all KS variants of one (mesh, prec, B, D, I) compute the SAME C, so their
[SPOT] words must agree. That needs no golden and no torch, and it is exactly what validates the
new matmul_1xVL against the production 2xVL/4xVL/8xVL. It cannot catch an error common to every
variant -- for that, check one arm per shape against scripts/check_fp16_spot.py.

EFFICIENCY: ideal/actual, ideal = B*D*I / (cores * 4 FPU * (2 for fp16)). Rank on this, never on
the TB util counter -- that counter is lane OCCUPANCY and has inverted a real ranking before.
"""
import glob, os, re, sys, collections, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = re.compile(r"^sw_(?P<mesh>\d+x\d+)_(?P<prec>fp16|fp32)_ks(?P<ks>\d+)_"
                  r"(?P<B>\d+)x(?P<D>\d+)x(?P<I>\d+)$")
CORES = {"4x4": 256, "8x8": 1024}

def scrape(d):
    t = os.path.join(d, "transcript")
    if not os.path.isfile(t):
        t = os.path.join(d, "sim.out")
        if not os.path.isfile(t):
            return None
    b = open(t, "rb").read()
    # QuestaSim prefixes every line with "# "; VCS does not. Normalise before matching.
    b = re.sub(rb"(?m)^# ", b"", b)
    g = lambda p: (re.search(p, b).group(1).decode() if re.search(p, b) else None)
    cyc = g(rb"execution took (\d+)")
    rep = re.search(rb"\[REPEAT\] r=(\d+) total=(\d+) per_pass=(\d+)", b)
    spot = [m.group(0).decode() for m in re.finditer(rb"\[SPOT\][^\n]*", b)]
    return dict(cycles=int(cyc) if cyc else None,
                repeat=int(rep.group(1)) if rep else 1,
                raw=int(rep.group(2)) if rep else None,
                spot=spot,
                eoc=b.count(b"[EOC]") > 0,
                # gated behind csr_trace: meaningless unless the bench phase ran
                bench=b.count(b"] bench") > 0,
                tmo=len(re.findall(rb"mshr_timeout=\+[1-9]", b)),
                overcap=b.count(b"NON-BURST OVER CAPACITY"))

def main():
    rows = []
    for d in sorted(glob.glob(os.path.join(ROOT, "hardware", "sw_*"))):
        if not os.path.isdir(d): continue
        m = NAME.match(os.path.basename(d))
        if not m: continue
        f = m.groupdict()
        B, D, I, KS = int(f["B"]), int(f["D"]), int(f["I"]), int(f["ks"])
        cores = CORES[f["mesh"]]
        peak = cores * 4 * (2 if f["prec"] == "fp16" else 1)
        s = scrape(d)
        if s is None: continue
        ideal = B * D * I // peak
        eff = (100.0 * ideal / s["cycles"]) if s["cycles"] else None
        rows.append(dict(arm=os.path.basename(d), mesh=f["mesh"], prec=f["prec"],
                         B=B, D=D, I=I, KS=KS, sharers=B // KS, ideal=ideal, eff=eff, **s))

    # --- cross-KS SPOT agreement: the oracle for matmul_1xVL -------------------
    grp = collections.defaultdict(list)
    for r in rows:
        grp[(r["mesh"], r["prec"], r["B"], r["D"], r["I"])].append(r)
    for key, g in grp.items():
        have = [r for r in g if r["spot"]]
        ref = next((r for r in have if r["KS"] != 1), None)   # a production kernel is the reference
        for r in g:
            if not r["spot"] or ref is None or r is ref:
                r["spot_ok"] = "ref" if r is ref else ("no-spot" if not r["spot"] else "n/a")
            else:
                r["spot_ok"] = "MATCH" if r["spot"] == ref["spot"] else "*** MISMATCH ***"

    rows.sort(key=lambda r: (r["mesh"], r["prec"], r["B"], r["KS"]))
    print("%-34s %-5s %-5s %5s %3s %6s %9s %9s %7s %8s %s" %
          ("arm", "mesh", "prec", "B", "KS", "shar", "ideal", "cycles", "eff%", "repeat", "spot"))
    for r in rows:
        print("%-34s %-5s %-5s %5d %3d %6d %9d %9s %7s %8d %s" %
              (r["arm"], r["mesh"], r["prec"], r["B"], r["KS"], r["sharers"], r["ideal"],
               r["cycles"] if r["cycles"] else "-",
               ("%.1f" % r["eff"]) if r["eff"] else "-", r["repeat"], r.get("spot_ok", "?")))
    bad = [r for r in rows if r.get("spot_ok", "").startswith("***")]
    print("\narms=%d  with-cycles=%d  SPOT MISMATCH=%d" %
          (len(rows), sum(1 for r in rows if r["cycles"]), len(bad)))
    for r in bad: print("  MISMATCH", r["arm"])
    json.dump(rows, open("/tmp/claude-620771/ks_sweep_results.json", "w"), indent=1)

if __name__ == "__main__":
    main()
