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
            elif st in ("running", "done", "succeeded", "completed"):
                # a later batch already re-ran it; do not resubmit again
                live.add(arm)
    return failed, live

def main():
    global MAXA
    if "--max-attempts" in sys.argv:
        MAXA = int(sys.argv[sys.argv.index("--max-attempts") + 1])
    dry = "--dry-run" in sys.argv
    led = load_ledger()
    failed, live = failed_and_live()
    todo = []
    for arm, node in sorted(failed.items()):
        if arm in live:
            continue                      # already recovered by a later batch
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
           "--name", "s8auto", "--max-parallel", "20", "--mem-gb", "18",
           "--est-runtime-s", "90000", "--force"]
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
