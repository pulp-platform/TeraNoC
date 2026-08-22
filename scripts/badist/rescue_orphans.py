#!/usr/bin/env python3
"""Requeue campaign arms that nothing can dispatch any more.

A badist batch's queued jobs only move while its submit controller lives. Kill the controller --
deliberately, or as collateral (a licence-crisis sweep took out the healer's and resubmitter's
controllers along with the intended ones) -- and its queued jobs become invisible: badist still
lists them, every status view counts them as "pending", and they will never run.

Detection is deliberately NOT by controller lookup. Controllers share names (several batches are
called s8auto), so a name match reported a live controller for a batch that had none and the arm
stayed lost. Instead use the outcome: an arm with no result, no running copy, and no start for a
long time is not being dispatched by anything, whatever the process table says.

Duplicates are the acceptable risk here -- kill_duplicate_arms.py clears those, and it is far
cheaper than an arm silently never running.

  usage: rescue_orphans.py [--min-idle-min 90] [--dry-run]
"""
import concurrent.futures as cf
import glob, json, os, subprocess, sys, time

ROOT   = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE  = os.path.expanduser("~/badist/state")
CLIENT = os.path.join(ROOT, "scripts/badist/teranoc_fleet.py")
LEDGER = "/tmp/claude-620771/rescue_ledger.json"
MAX_PER_ARM = 3

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
    victims = []
    for a, when in sorted(queued_at.items()):
        if a in running:
            continue
        t = os.path.join(ROOT, "hardware", "s8_" + a, "transcript")
        try:
            if os.path.exists(t) and b"execution took" in open(t, "rb").read():
                continue
        except OSError:
            pass
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
                          "--mem-gb", "18", "--est-runtime-s", "90000", "--force"],
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
