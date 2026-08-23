#!/usr/bin/env python3
"""Resubmit failed 8x8 campaign arms, once per detection, with a per-arm attempt cap.

Failures here are mostly transport-level ("packaging failed"), not the arm being unrunnable, so
a resubmit usually recovers them. The cap exists because a genuinely broken arm would otherwise
resubmit forever and quietly consume a node slot each round -- an infinite retry is how a single
bad shape eats a fleet.

  usage: auto_resubmit.py [--max-attempts N] [--dry-run]
"""
import glob, json, os, subprocess, sys

ROOT  = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE = os.path.expanduser("~/badist/state")
LEDGER = "/tmp/claude-620771/resubmit_ledger.json"
CLIENT = os.path.join(ROOT, "scripts/badist/teranoc_fleet.py")
MAXA = 3

def load_ledger():
    try:
        return json.load(open(LEDGER))
    except Exception:
        return {}

def failed_and_live():
    """Return (failed_arms, arms_currently_running_or_done) across every batch."""
    failed, live = {}, set()
    for d in sorted(glob.glob(os.path.join(STATE, "*"))):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        ids = {j["job_id"]: (j.get("meta") or {}).get("arm", "") for j in jobs}
        for f in glob.glob(os.path.join(d, "jobs", "*.jsonl")):
            jid = os.path.basename(f)[:-6]
            arm = ids.get(jid, "")
            if not arm.startswith(("fp16_", "fp32_")):
                continue
            last = None
            for ln in open(f):
                try:
                    last = json.loads(ln)
                except Exception:
                    pass
            if not last:
                continue
            st = last.get("state")
            if st == "failed":
                failed[arm] = last.get("node", "?")
            elif st in ("done", "succeeded", "completed"):
                # "done" does NOT mean a result exists. A killed job's partial delivery lands on
                # hardware/s8_<arm>/ and badist still marks the job done, so the arm is complete
                # in the ledger, has no cycle count on disk, and is invisible to this loop (which
                # only looks at failures) AND to the healer (which only looks at running arms).
                # Six arms sat in that hole. Treat a done-with-no-result as needing a rerun.
                t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
                try:
                    ok = os.path.exists(t) and b"execution took" in open(t, "rb").read()
                except OSError:
                    ok = False
                if ok:
                    live.add(arm)
                else:
                    failed.setdefault(arm, last.get("node", "?"))
            elif st == "running":
                # a later batch already re-ran it; do not resubmit again
                live.add(arm)
    return failed, live


def already_requeued():
    """Arms that already have a never-started job in some batch.

    The healer and auto-resubmit both react to an arm that is dead: the healer kills it (so it
    reads cancelled) and auto-resubmit sees a failure. Run 70 seconds apart, they each requeued
    the SAME five arms, and the dedup loop then had to kill one copy of each. Neither is wrong on
    its own -- they just have to see each other's work. A never-started job IS the other loop's
    requeue, so treat it as covered.
    """
    import glob as _g, json as _j, os as _o
    out = set()
    for d in _g.glob(_o.path.join(STATE, "*")):
        jf = _o.path.join(d, "jobs.json")
        if not _o.path.exists(jf):
            continue
        try:
            jobs = _j.load(open(jf))
        except Exception:
            continue
        started = {_o.path.basename(f)[:-6] for f in _g.glob(_o.path.join(d, "jobs", "*.jsonl"))}
        for j in jobs:
            a = (j.get("meta") or {}).get("arm", "")
            if a.startswith(("fp16_", "fp32_")) and j["job_id"] not in started:
                out.add(a)
    return out

def main():
    global MAXA
    if "--max-attempts" in sys.argv:
        MAXA = int(sys.argv[sys.argv.index("--max-attempts") + 1])
    dry = "--dry-run" in sys.argv
    led = load_ledger()
    failed, live = failed_and_live()
    live |= already_requeued()          # the healer may have requeued it seconds ago
    todo = []
    for arm, node in sorted(failed.items()):
        if arm in live:
            continue
        # A DELIVERED RESULT ENDS IT, whatever the ledger says. An arm can complete via one copy
        # and still carry a `failed` record from another (a duplicate we killed, a node that died
        # under a second copy). Resubmitting it burns ~10 h of simulation for an answer already on
        # disk. fp16_2048x512x128 was resubmitted with `execution took 33959` sitting in its
        # transcript. The filesystem is the authority here, not the job state.
        t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
        try:
            if os.path.exists(t) and b"execution took" in open(t, "rb").read():
                continue
        except OSError:
            pass                      # already recovered by a later batch
        n = led.get(arm, 0)
        if n >= MAXA:
            print("  SKIP %-26s %d attempts already -- needs a human" % (arm, n))
            continue
        elf = os.path.join(ROOT, "hardware", "s8_%s.elf" % arm)
        if not os.path.exists(elf):
            print("  SKIP %-26s no ELF at %s" % (arm, elf))
            continue
        todo.append((arm, node, n))
    if not todo:
        print("  nothing to resubmit")
        return
    lst = "/tmp/claude-620771/arms_auto_retry.txt"
    with open(lst, "w") as f:
        for arm, _, _ in todo:
            f.write("%s s8_%s.elf build_q_8x8\n" % (arm, arm))
    for arm, node, n in todo:
        print("  RESUBMIT %-26s (failed on %s, attempt %d)" % (arm, node, n + 1))
    if dry:
        print("  --dry-run: not submitting")
        return
    cmd = [CLIENT, "submit", "--arms", lst, "--backend", "questa", "--run-prefix", "s8",
           # STAGGER, same reason as heal_stuck_arms.py: arms that start together contend on
           # the shared 17 GB Questa library over NFS and hang in design load. The s8auto batch
           # submitted at 20 and the healer then had to clear 11 of its arms. 6 at a time lets
           # each finish loading before the next begins.
           "--name", "s8auto", "--max-parallel", "6", "--mem-gb", "18",
           "--est-runtime-s", "90000", "--timeout-s", "172800", "--force"]
    p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=90)
    except subprocess.TimeoutExpired:
        out = "(controller still running in background -- expected)"
    for ln in (out or "").splitlines():
        if "batch" in ln or "rror" in ln:
            print("  %s" % ln)
    for arm, _, n in todo:
        led[arm] = n + 1
    json.dump(led, open(LEDGER, "w"), indent=1)
    print("  ledger updated for %d arm(s)" % len(todo))

main()
