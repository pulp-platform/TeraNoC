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
server, not a soft target -- but only while OUR OWN seat count is still GROWING. Over the line and
shrinking is a wait, not a fault: at 8x8 the arms run for hours, so alerting every cycle on a state
with no available action just teaches the reader to ignore the loop. That case prints under -v as
"draining". The previous per-pool sample lives in ~/.badist_licwatch.json.
"""
import glob, json, os, re, subprocess, sys, time

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE = os.path.expanduser("~/badist/state")
IDLE_ALERT_MIN = 3
POOLS = [("mtiverification", "8161@lic-mentor.ethz.ch", 10),
         ("VCS-Base-Runtime-Pkg", "8169@lic-synopsys.ethz.ch", 2)]


USER = os.environ.get("USER", "zexifu")
SEEN = os.path.expanduser("~/.badist_licwatch.json")


def pool(feature, server):
    """(issued, in_use, ours) -- `ours` is how many of the in-use seats this user holds."""
    try:
        out = subprocess.check_output(["lmutil", "lmstat", "-c", server, "-f", feature],
                                      stderr=subprocess.STDOUT, text=True, timeout=120)
    except Exception:
        return None
    m = re.search(r"Total of (\d+) licenses? issued;\s*Total of (\d+) licenses? in use", out)
    if not m:
        return None
    # Anchor to the user FIELD, not a substring anywhere on the line: lmstat user rows are
    # "    <user> <host> <handle> ...". A bare `USER in ln` would also count a host or handle that
    # happened to contain the name. (Verified 2026-08-23: every match on this server is a user row,
    # so the two agree today -- anchoring keeps that true.)
    ours = sum(1 for ln in out.splitlines() if ln.startswith(" ") and ln.split()[:1] == [USER])
    return (int(m.group(1)), int(m.group(2)), ours)


def last_sample():
    try:
        return json.load(open(SEEN))
    except Exception:
        return {}


def save_sample(d):
    try:
        json.dump(d, open(SEEN, "w"))
    except OSError:
        pass


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
    prev, now = last_sample(), {}
    alerts, idle_total, draining = [], 0, []
    for feat, server, reserve in POOLS:
        p = pool(server=server, feature=feat)
        if not p:
            continue
        issued, used, ours = p
        now[feat] = ours
        usable = issued - used - reserve
        if usable > 0:
            idle_total += usable
        # Likewise 2+ over, not 1. badist dispatches ALREADY-QUEUED jobs into freeing slots without
        # consulting our governor (which only gates new submissions), so brief one-seat excursions
        # past the line are structural and self-correct within minutes as arms finish.
        # Over the line is only an ALERT while OUR OWN holding is still growing -- that means
        # something is still dispatching and there is something to stop. Once it is flat or
        # falling we are simply waiting for arms to finish, which takes hours at 8x8: re-alerting
        # every cycle for a state with no available action is how a reader learns to ignore the
        # loop, and that is how a real stall gets missed. It is then reported under -v instead.
        if usable <= -2:
            grew = feat not in prev or ours > prev[feat]
            msg = ("OVER RESERVE %s: %d/%d used, only %d free but we promised %d (ours %d%s)"
                   % (feat, used, issued, issued - used, reserve, ours,
                      ", was %d" % prev[feat] if feat in prev else ""))
            (alerts if grew else draining).append(msg)
    # THRESHOLD 3, not 1. A one- or two-seat gap is the normal beat of the fleet: an arm finishes,
    # its seat is free until the next dispatch cycle, and the waiting arms are usually already queued
    # on that same backend so neither the top-up (which moves arms BETWEEN backends) nor the rescuer
    # (which only touches batches idle >90 min) can place them. Alerting on that fired every cycle
    # and taught the reader to ignore the loop -- which is how a real stall gets missed. Three or
    # more idle seats is beyond normal churn and means dispatch is genuinely stuck.
    # What matters is how many arms could ACTUALLY be placed -- min(idle seats, waiting arms) --
    # not the seat count alone. At the end of a campaign the queue runs dry and plenty of seats sit
    # free with nothing to put in them: that is success, not a stall. Alerting on 5 idle seats while
    # 1 arm waited was reporting a full fleet as a failure.
    placeable = min(idle_total, wait_n)
    if placeable >= IDLE_ALERT_MIN:
        alerts.append("IDLE SEATS: %d arm(s) could start now (%d seats free, %d waiting) -- "
                      "dispatch is not keeping up" % (placeable, idle_total, wait_n))
    save_sample(now)
    for a in alerts:
        print("LICWATCH %s" % a)
    if "-v" in sys.argv:
        for d in draining:
            print("LICWATCH draining %s" % d)
        if not alerts:
            print("LICWATCH ok: %d waiting, %d running, %d idle seats"
                  % (wait_n, run_n, idle_total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
