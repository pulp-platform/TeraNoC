#!/usr/bin/env python3
"""Estimate how far each RUNNING 8x8 arm has got, from FPU lane-cycles actually accumulated.

Progress cannot be read off the cycle count -- an arm has no idea how many cycles it will need.
What it does emit is `[FPU] bench ... busy=B/D lane-cyc` per period, and B accumulates roughly in
proportion to the work done. So:

    fma_done  ~=  sum(B) * macs_per_lane_cycle          (fp16 = 2, fp32 = 1)
    fma_total  =  M * N * P
    progress   =  fma_done / (fma_total * K)

K is an EMPIRICAL correction, not 1.0: `busy` is lane OCCUPANCY, not a MAC counter, so a finished
arm has accumulated ~15% more lane-cycles than it had MACs to execute (pipeline occupancy, non-FMA
kernel work, the spotcheck). Calibrated over completed, $finish-reaching, non-livelocked arms.

LIVELOCKED ARMS ARE EXCLUDED FROM CALIBRATION and flagged in the output: they accumulate lane-cycles
wildly out of proportion to their MACs (fp16_1024x32x128 finished at ratio 3.37 against a 1.16
median), so a single K cannot describe both populations. For those arms progress is reported but
marked unreliable.
"""
import csv, json, glob, os, re, statistics as st, subprocess, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
TSV  = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")
OUT  = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/run_progress.json")
MULT = {"fp16": 2, "fp32": 1}          # MACs per lane-cycle at peak


def lanecycles(txt):
    tot = n = 0
    for m in re.finditer(rb"\[FPU\] bench[^\n]*?busy=(\d+)/(\d+) lane-cyc", txt):
        tot += int(m.group(1)); n += 1
    return tot, n


def norm(raw):
    return b"\n".join(l[2:] if l.startswith(b"# ") else l for l in raw.split(b"\n"))


def calibrate():
    """K per precision, from complete non-livelocked runs."""
    cal = {"fp16": [], "fp32": []}
    for r in list(csv.reader(open(TSV), delimiter="\t"))[1:]:
        if len(r) < 10 or r[9] != "done":
            continue
        if r[5].isdigit() and int(r[5]) > 1000:      # livelocked -> not representative
            continue
        arm, pr = r[1] + "_" + r[0], r[1]
        M, N, P = (int(x) for x in r[0].split("x"))
        t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
        if not os.path.exists(t):
            continue
        txt = norm(open(t, "rb").read())
        if b"execution took" not in txt or b"[FPU FINAL]" not in txt:
            continue
        tot, n = lanecycles(txt)
        if n < 3 or tot == 0:
            continue
        cal[pr].append(tot * MULT[pr] / (M * N * P))
    return {p: (st.median(v) if v else 1.16) for p, v in cal.items()}, {p: len(v) for p, v in cal.items()}


def running():
    out = []
    for jf in glob.glob(os.path.expanduser("~/badist/state/*/jobs.json")):
        d = os.path.dirname(jf)
        try: jobs = json.load(open(jf))
        except Exception: continue
        started = {os.path.basename(f)[:-6] for f in glob.glob(os.path.join(d, "jobs", "*.jsonl"))}
        for j in jobs:
            if j["job_id"] not in started: continue
            stt = node = None
            for ln in open(os.path.join(d, "jobs", j["job_id"] + ".jsonl")):
                try:
                    r = json.loads(ln); stt = r.get("state", stt); node = r.get("node", node)
                except Exception: pass
            if stt != "running": continue
            arm = (j.get("meta") or {}).get("arm", "")
            if not arm.startswith(("fp16_", "fp32_")): continue
            be = "vcs" if "build_vcs" in j.get("command", "") else "questa"
            out.append((arm, os.path.basename(d), j["job_id"], node, be))
    return out


def main():
    K, ncal = calibrate()
    sys.stderr.write("  calibration K: %s   (from %s complete non-livelock arms)\n" % (
        {p: round(v, 3) for p, v in K.items()}, ncal))
    rows = []
    for arm, batch, jid, node, be in running():
        pr = arm.split("_")[0]
        M, N, P = (int(x) for x in arm.split("_")[1].split("x"))
        try:
            o = subprocess.run(["/home/zexifu/badist/bin/badist", "logs", jid, batch, "-n", "600000"],
                               capture_output=True, timeout=180).stdout
        except Exception:
            o = b""
        txt = norm(o)
        tot, n = lanecycles(txt)
        cum = re.findall(rb"\[FPU\] bench[^\n]*?cum=([0-9.]+)%", txt)
        cyc = re.findall(rb"\[FPU\] bench cyc=(\d+)", txt)
        rh  = txt.count(b"RH STUCK")
        need = M * N * P
        prog = (tot * MULT[pr] / (need * K[pr])) if need else 0.0
        rows.append(dict(arm=arm, backend=be, node=node, M=M, N=N, P=P,
                         periods=n, fma_done=tot * MULT[pr], fma_total=need,
                         progress=round(min(prog, 1.5), 4),
                         cum_util=float(cum[-1]) if cum else None,
                         cyc=int(cyc[-1]) if cyc else None,
                         rh=rh, livelock=rh > 1000))
    rows.sort(key=lambda r: -(r["progress"] or 0))
    json.dump(dict(K=K, rows=rows), open(OUT, "w"), indent=1)
    print("wrote %s (%d running arms)" % (OUT, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
