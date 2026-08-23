#!/usr/bin/env python3
"""Alert when licence seats sit IDLE while arms are waiting -- and when we cross the courtesy line.

Silent in the healthy states, which are two and must not be confused:
  * seats free but nothing waiting  -> the sweep is simply finishing, not stalled
  * arms waiting but no seats free  -> correctly queued behind the reserve line
The alarm is the intersection: usable seats AND waiting arms at the same time, which means the
dispatch path is broken (a dead controller, a gate refusing arms, a governor mis-reading the pool)
rather than the fleet being busy. That state has occurred twice today -- once from a feasibility
gate refusing 22 arms on a wrong model, once from batches whose controllers had died.

Also alerts when we are OVER the reserve, since that is a promise to other people on a shared
server, not a soft target.
"""
import glob, json, os, re, subprocess, sys, time

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE = os.path.expanduser("~/badist/state")
POOLS = [("mtiverification", "8161@lic-mentor.ethz.ch", 10),
         ("VCS-Base-Runtime-Pkg", "8169@lic-synopsys.ethz.ch", 2)]


def pool(feature, server):
    try:
        out = subprocess.check_output(["lmutil", "lmstat", "-c", server, "-f", feature],
                                      stderr=subprocess.STDOUT, text=True, timeout=120)
    except Exception:
        return None
    m = re.search(r"Total of (\d+) licenses? issued;\s*Total of (\d+) licenses? in use", out)
    return (int(m.group(1)), int(m.group(2))) if m else None


def waiting():
    """Arms with no result that are not running -- i.e. arms a free seat could start."""
    res = set()
    try:
        with open(os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")) as f:
            for ln in f.read().splitlines()[1:]:
                p = ln.split("\t")
                if len(p) > 1:
                    res.add(p[1] + "_" + p[0])
    except OSError:
        pass
    run, pend = set(), set()
    for d in sorted(glob.glob(os.path.join(STATE, "*"))):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        started = {os.path.basename(f)[:-6] for f in glob.glob(os.path.join(d, "jobs", "*.jsonl"))}
        for j in jobs:
            a = (j.get("meta") or {}).get("arm", "")
            if not a.startswith(("fp16_", "fp32_")):
                continue
            if j["job_id"] not in started:
                pend.add(a)
                continue
            st = None
            for ln in open(os.path.join(d, "jobs", j["job_id"] + ".jsonl")):
                try:
                    st = json.loads(ln).get("state", st)
                except Exception:
                    pass
            if st == "running":
                run.add(a)
    return len(pend - run - res), len(run)


def main():
    wait_n, run_n = waiting()
    alerts, idle_total = [], 0
    for feat, server, reserve in POOLS:
        p = pool(server=server, feature=feat)
        if not p:
            continue
        issued, used = p
        usable = issued - used - reserve
        if usable > 0:
            idle_total += usable
        if usable < 0:
            alerts.append("OVER RESERVE %s: %d/%d used, only %d free but we promised %d"
                          % (feat, used, issued, issued - used, reserve))
    if idle_total > 0 and wait_n > 0:
        alerts.append("IDLE SEATS: %d usable seat(s) while %d arm(s) wait -- dispatch is not keeping up"
                      % (idle_total, wait_n))
    for a in alerts:
        print("LICWATCH %s" % a)
    if "-v" in sys.argv and not alerts:
        print("LICWATCH ok: %d waiting, %d running, %d idle seats" % (wait_n, run_n, idle_total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
