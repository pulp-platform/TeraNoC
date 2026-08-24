#!/usr/bin/env python3
"""Requeue campaign arms that nothing can dispatch any more.

A badist batch's queued jobs only move while its submit controller lives. Kill the controller --
deliberately, or as collateral (a licence-crisis sweep took out the healer's and resubmitter's
controllers along with the intended ones) -- and its queued jobs become invisible: badist still
lists them, every status view counts them as "pending", and they will never run.

Detection is deliberately NOT by controller lookup: controllers share names (several batches are
called s8auto), so a name match reported a live controller for a batch that had none.

Nor is it by queue age alone. That was the first attempt and it was wrong: with a licence reserve
in force, waiting hours IS the normal state of the queue, so "queued 90 minutes" describes a
healthy batch. It fired on 47 perfectly good arms of a batch whose controller was alive.

The signal that actually separates the two is whether the BATCH is still making progress. A live
controller keeps starting jobs; a dead one cannot start any. So a batch counts as dispatching if
any of its jobs entered `running` recently, and only the queued jobs of a batch with no recent
start are orphans.

Duplicates are the acceptable risk here -- kill_duplicate_arms.py clears those, and it is far
cheaper than an arm silently never running.

  usage: rescue_orphans.py [--min-idle-min 90] [--dry-run]
"""
import concurrent.futures as cf
import glob, json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import time
from feasibility import stalling, stall_reason, delivered, fits, projected_hours, announce_once, save_announced

ROOT   = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE  = os.path.expanduser("~/badist/state")
CLIENT = os.path.join(ROOT, "scripts/badist/teranoc_fleet.py")
LEDGER = "/tmp/claude-620771/rescue_ledger.json"
MAX_PER_ARM = 3

def pools_have_headroom():
    """True if EITHER simulator pool can actually start another arm.

    An arm queued behind a saturated licence pool is not orphaned -- nothing anywhere can dispatch
    it, and queuing another copy just adds a duplicate that collides later. fp32_2048x32x512 hit
    the per-arm rescue cap this way: ONE real failure (packaging on a full disk) and then six
    queued copies from successive rescues, none of which could start because Questa sat at its
    reserve line and VCS at 95/100. Memory was never the constraint -- 42 nodes could host it.
    """
    import subprocess as sp
    for feat, server, reserve in (("mtiverification", "8161@lic-mentor.ethz.ch", 10),
                                  ("VCS-Base-Runtime-Pkg", "8169@lic-synopsys.ethz.ch", 5)):
        try:
            out = sp.check_output(["lmutil", "lmstat", "-c", server, "-f", feat],
                                  stderr=sp.STDOUT, text=True, timeout=120)
        except Exception:
            return True                      # cannot tell -> behave as before, do not suppress
        m = re.search(r"Total of (\d+) licenses? issued;\s*Total of (\d+) licenses? in use", out)
        if m and int(m.group(1)) - int(m.group(2)) - reserve > 0:
            return True
    return False


def main():
    idle_min = 90
    if "--min-idle-min" in sys.argv:
        idle_min = int(sys.argv[sys.argv.index("--min-idle-min") + 1])
    dry = "--dry-run" in sys.argv
    try:
        led = json.load(open(LEDGER))
    except Exception:
        led = {}

    running, queued_at, run_node = set(), {}, {}
    batch_last_start, batch_queued = {}, {}
    for d in sorted(glob.glob(os.path.join(STATE, "*"))):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        started = {os.path.basename(f)[:-6] for f in glob.glob(os.path.join(d, "jobs", "*.jsonl"))}
        # the batch dir's own mtime is when it was created/last touched
        bmt = os.path.getmtime(jf)
        for j in jobs:
            a = (j.get("meta") or {}).get("arm", "")
            if not a.startswith(("fp16_", "fp32_")):
                continue
            jid = j["job_id"]
            if jid not in started:
                queued_at[a] = max(queued_at.get(a, 0), bmt)
                batch_queued.setdefault(os.path.basename(d), []).append(a)
                continue
            last = None
            for ln in open(os.path.join(d, "jobs", jid + ".jsonl")):
                try:
                    last = json.loads(ln)
                except Exception:
                    pass
            if last and last.get("state") == "running":
                running.add(a)
                if last.get("node"):
                    run_node.setdefault(last["node"], []).append(a)
            # when did THIS batch last put a job into `running`? a live controller keeps doing it
            for r in (json.loads(x) for x in open(os.path.join(d, "jobs", jid + ".jsonl"))
                      if x.strip()):
                if r.get("state") == "running":
                    b = os.path.basename(d)
                    batch_last_start[b] = max(batch_last_start.get(b, 0), r.get("ts") or 0)

    # An arm "running" on an unreachable node is the worst case: the healer needs a live-process
    # check it cannot make, auto-resubmit only looks at failures, and the queued-arm path below
    # never sees it. badile48 went down holding one arm and nothing would have noticed.
    dead = set()
    if run_node:
        def alive(n):
            for _ in range(2):                     # one retry: a single timeout is not evidence
                try:
                    if subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                       "-o", "StrictHostKeyChecking=no", n, "true"],
                                      capture_output=True, timeout=25).returncode == 0:
                        return n, True
                except Exception:
                    pass
                time.sleep(3)
            return n, False
        # LIMITED concurrency: 47 simultaneous ssh connections tripped a rate limit and 36 healthy
        # nodes reported unreachable -- a probe that lies is worse than no probe.
        with cf.ThreadPoolExecutor(max_workers=8) as ex:
            for n, ok in ex.map(alive, sorted(run_node)):
                if not ok:
                    dead.add(n)
    for n in sorted(dead):
        for a in run_node[n]:
            print("  DEAD NODE %-12s holds %s (marked running)" % (n, a))
            running.discard(a)
            queued_at.setdefault(a, 0)             # 0 => older than any threshold, rescue now

    now = time.time()
    # a batch that started a job within STALE_MIN is still being dispatched; its queue is fine
    STALE_MIN = 60
    live_batches = {b for b, ts in batch_last_start.items()
                    if (now - ts) / 60.0 < STALE_MIN}
    protected = set()
    for b, arms_ in batch_queued.items():
        if b in live_batches:
            protected.update(arms_)
    if protected:
        print("  %d queued arm(s) are in batches that started a job in the last %d min -- "
              "held by the governor, not orphaned" % (len(protected), STALE_MIN))

    if not pools_have_headroom():
        print("  both licence pools are at their reserve line -- queued arms are waiting, not "
              "orphaned; rescuing now would only add duplicates")
        return

    victims = []
    for a, when in sorted(queued_at.items()):
        if a in running or a in protected:
            continue
        if stalling(a):
            announce_once("stall:" + a,
                          "  KNOWN-STALL %-22s %s -- held back (see rh_livelock_root_cause.md)"
                          % (a, stall_reason(a)))
            continue
        if not fits(a):
            # A shape the deadline cannot hold burns a seat for the full 48h and then fails. The
            # rescuer lacked this guard while auto_resubmit and sim_topup had it, and dispatched
            # 38 infeasible arms in one pass -- 4,255 projected hours, every one of them doomed.
            announce_once("infeasible:" + a,
                          "  INFEASIBLE %-24s ~%.0f h projected -- not rescued"
                          % (a, projected_hours(a) or 0))
            continue
        if delivered(a):
            # durable record, not the overwritable transcript: delivered() handles its own
            # errors, so the old try/except around the transcript read is gone.
            continue
        if (now - when) / 60.0 < idle_min:
            continue
        if led.get(a, 0) >= MAX_PER_ARM:
            print("  SKIP %-26s %d rescues already -- needs a human" % (a, led[a]))
            continue
        victims.append(a)

    if not victims:
        print("  no orphaned arms")
        return
    for a in victims:
        print("  ORPHAN %-26s queued %.0f min with nothing dispatching it" % (a, (now - queued_at[a]) / 60.0))
    if dry:
        print("  --dry-run: not resubmitting")
        return
    lst = "/tmp/claude-620771/arms_rescue.txt"
    with open(lst, "w") as f:
        for a in victims:
            f.write("%s s8_%s.elf build_q_8x8\n" % (a, a))
    p = subprocess.Popen([CLIENT, "submit", "--arms", lst, "--backend", "questa",
                          "--run-prefix", "s8", "--name", "s8rescue", "--max-parallel", "40",
                          "--mem-gb", "18", "--est-runtime-s", "90000",
                          # deadline must EXCEED the predicted runtime: the default 86400 killed
                          # eight of the largest arms at exactly 24 h after a full day of work.
                          "--timeout-s", "2592000", "--force"],
                         cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=120)
    except subprocess.TimeoutExpired:
        out = "(controller running in background -- expected)"
    for ln in (out or "").splitlines():
        if "batch" in ln or "rror" in ln:
            print("  %s" % ln)
    for a in victims:
        led[a] = led.get(a, 0) + 1
    json.dump(led, open(LEDGER, "w"), indent=1)
    print("  rescued %d arm(s)" % len(victims))

main()
save_announced()
