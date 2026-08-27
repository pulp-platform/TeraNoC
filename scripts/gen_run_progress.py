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
import collections, csv, json, glob, os, re, statistics as st, subprocess, sys, time

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


def delivered_arms():
    """Arms that already have a recorded result. An arm can be FINISHED but not yet reaped, so its
    badist ledger still says `running` while results.tsv holds its number -- 10 of 101 were in that
    state on 2026-08-24. Counting them here pulls a full log for a finished arm and skews the
    median. campaign_status.py already dedupes this way; match it."""
    have = set()
    try:
        for r in list(csv.reader(open(TSV), delimiter="\t"))[1:]:
            if len(r) > 3 and r[3].strip().isdigit():
                have.add(r[1] + "_" + r[0])
    except OSError:
        pass
    return have


def running():
    done_already = delivered_arms()
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
            if arm in done_already: continue        # finished, just not reaped yet
            be = "vcs" if "build_vcs" in j.get("command", "") else "questa"
            out.append((arm, os.path.basename(d), j["job_id"], node, be))
    return out


def node_procs(nodes):
    """One probe per NODE -> {node: [(arm, cwd, tx_age_s, last_marker), ...]} or None if unreachable.

    Two traps this exists to avoid, both of which produced a WRONG answer on 2026-08-27:

      1. `pgrep simv` misses QuestaSim, whose process is `vsimk`. Counting only simv reported six
         busy nodes as empty and called ten live arms dead.
      2. The transcript under hardware/<prefix>_<arm>/ is the DELIVERED copy. A running arm writes
         to its NODE-LOCAL run dir, so the shared one stays cold for the whole run -- and a killed
         duplicate leaves a cold shared transcript behind while a rescue copy runs happily
         elsewhere. Freshness has to be read from the process's own cwd.
    """
    script = (
        "for p in $(pgrep -u $USER -f 'simv|vsimk' 2>/dev/null); do "
        # -f (full cmdline), NOT -x (process NAME): the VCS binary is named
        # mempool_simvopt, so -x 'simv' matches nothing and every VCS arm reads as dead.

        "  a=$(tr '\\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -oE '(fp16|fp32)_[0-9]+x[0-9]+x[0-9]+' | head -1); "
        "  c=$(readlink /proc/$p/cwd 2>/dev/null); t=$c/transcript; "
        "  m=$(stat -c%Y \"$t\" 2>/dev/null || echo 0); "
        "  l=$(grep -ao 'execution took [0-9]*' \"$t\" 2>/dev/null | tail -1); "
        "  echo \"$a|$c|$m|$l\"; done")
    out = {}
    for n in nodes:
        if not n or n in ("?", "local"):
            out[n] = None
            continue
        try:
            r = subprocess.run(["ssh", "-n", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", n, script],
                               capture_output=True, text=True, timeout=40)
            if r.returncode != 0:      # unreachable/auth: NOT the same as "no processes"
                out[n] = None
                continue
            recs = []
            now = time.time()
            for ln in r.stdout.splitlines():
                f = ln.split("|")
                if len(f) < 4 or not f[0]:
                    continue
                mt = int(f[2]) if f[2].isdigit() else 0
                recs.append((f[0], f[1], (now - mt) if mt else None, f[3]))
            out[n] = recs
        except Exception:
            out[n] = None
    return out


def arm_state(arm, node, procs, hung_after=1800):
    """running | hung | done | dead | unknown -- and never guesses when evidence is missing."""
    recs = procs.get(node, None)
    if recs is None:
        return "unknown"                        # unreachable: say so, do not accuse
    for a, cwd, age, marker in recs:
        if a != arm:
            continue
        if marker:
            return "done"                       # finished; sitting in the epilogue wedge
        if age is None:
            return "running"                    # no transcript yet -> still elaborating
        return "running" if age <= hung_after else "hung"
    # No process for this arm anywhere on its node. It may still have DELIVERED.
    for d in glob.glob("hardware/*_%s" % arm):
        t = os.path.join(d, "transcript")
        try:
            if os.path.exists(t) and re.search(rb"execution took", open(t, "rb").read()):
                return "done"
        except OSError:
            pass
    return "dead"


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
        # cyc counts from SIMULATION start, so it includes the boot/DMA prefix (~57k
        # cycles on a settled 8x8 arm). `execution took` counts the BENCHMARK REGION only.
        # Anything dividing benchmark work by raw cyc understates efficiency badly --
        # fp32_1024x2048x256 read 61.8%% that way against a true 83.3%%. Emit the first
        # bench sample so consumers can subtract it: (last-first) tracks execution-took
        # to within 1.5%% on that arm.
        rh  = txt.count(b"RH STUCK")
        need = M * N * P
        prog = (tot * MULT[pr] / (need * K[pr])) if need else 0.0
        rows.append(dict(arm=arm, backend=be, node=node, M=M, N=N, P=P,
                         periods=n, fma_done=tot * MULT[pr], fma_total=need,
                         progress=round(min(prog, 1.5), 4),
                         cum_util=float(cum[-1]) if cum else None,
                         cyc=int(cyc[-1]) if cyc else None,
                         cyc0=int(cyc[0]) if cyc else None,
                         rh=rh, livelock=rh > 1000))
    # LIVENESS: the ledger says "running"; the node says whether that is still true.
    procs = node_procs(sorted({r["node"] for r in rows}))
    for r in rows:
        r["state"] = arm_state(r["arm"], r["node"], procs)
    rows.sort(key=lambda r: -(r["progress"] or 0))
    json.dump(dict(K=K, rows=rows), open(OUT, "w"), indent=1)
    by = collections.Counter(r["state"] for r in rows)
    print("wrote %s (%d tracked: %s)" % (OUT, len(rows), dict(by)))
    dead = [r for r in rows if r["state"] == "dead"]
    if dead:
        # loud, and on stdout, so a watching loop actually surfaces it
        print("DEAD ARMS: %d -- dispatched, no process on node, transcript cold" % len(dead))
        for r in sorted(dead, key=lambda x: -(x["progress"] or 0)):
            print("   %-24s %-9s progress=%.1f%%" % (r["arm"], r["node"],
                                                    100.0 * (r["progress"] or 0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
