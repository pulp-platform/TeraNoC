#!/usr/bin/env python3
"""Kill, clean up and requeue 8x8 arms that are certainly dead. Runs unattended.

"Certainly dead" is deliberately narrow, because this kills work:
  * a LIVE process whose cwd is the job dir (a killed job's leftover dir must never re-trigger --
    that false positive re-reported all 29 arms minutes after they were cleaned up), AND
  * the transcript's last line is still "Loading work.*" -- it never reached [FPU], AND
  * that transcript has not been written for > MIN_IDLE minutes.
A genuinely loading arm fails the third test; a running arm fails the second; a cleaned-up one
fails the first. All three must hold.

Safety rails: a per-cycle cap (a bug that matches everything must not wipe the campaign), a
per-arm attempt cap, and node-local scratch removal so killed jobs do not orphan GBs -- that is
what filled badile13's /scratch and cost 3 arms.

  usage: heal_stuck_arms.py [--min-idle 45] [--max-kill 40] [--dry-run]
"""
import glob, json, os, re, shutil, subprocess, sys

ROOT   = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE  = os.path.expanduser("~/badist/state")
LEDGER = "/tmp/claude-620771/heal_ledger.json"
CLIENT = os.path.join(ROOT, "scripts/badist/teranoc_fleet.py")
BADIST = os.path.expanduser("~/badist/bin/badist")
MIN_IDLE, MAX_KILL, MAX_ATTEMPTS = 45, 40, 3

def sh(node, cmd, timeout=60):
    try:
        r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                            "-o", "StrictHostKeyChecking=no", node, cmd],
                           capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except Exception:
        return ""

def running_arms():
    """arm -> (node, batch, job_id) for everything the ledger currently calls running."""
    out = {}
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
            if last and last.get("state") == "running" and last.get("node"):
                out[arm] = (last["node"], os.path.basename(d), jid)
    return out

PROBE = r'''
d=%s
[ -f "$d/transcript" ] || exit 0
tail -1 "$d/transcript" | grep -q "Loading work\." || exit 0
grep -aq "\[FPU\]" "$d/transcript" 2>/dev/null && exit 0
age=$(( ($(date +%%s) - $(stat -c %%Y "$d/transcript")) / 60 ))
[ "$age" -gt %d ] || exit 0
live=0
for p in $(ls /proc 2>/dev/null | grep -E "^[0-9]+$"); do
  [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$d" ] && live=1 && break
done
[ "$live" = "1" ] || exit 0
echo "STUCK $age"
'''


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
    global MIN_IDLE, MAX_KILL
    if "--min-idle" in sys.argv: MIN_IDLE = int(sys.argv[sys.argv.index("--min-idle") + 1])
    if "--max-kill" in sys.argv: MAX_KILL = int(sys.argv[sys.argv.index("--max-kill") + 1])
    dry = "--dry-run" in sys.argv
    try:
        led = json.load(open(LEDGER))
    except Exception:
        led = {}

    pending = already_requeued()        # auto-resubmit may have requeued it seconds ago
    victims = []
    for arm, (node, batch, jid) in sorted(running_arms().items()):
        if arm in pending:
            continue
        d = "/scratch/zexifu_cache/badist/run/%s/%s" % (batch, jid)
        if "STUCK" not in sh(node, PROBE % (d, MIN_IDLE)):
            continue
        if led.get(arm, 0) >= MAX_ATTEMPTS:
            print("  SKIP %-26s %d heals already -- needs a human" % (arm, led[arm]))
            continue
        victims.append((arm, node, batch, jid, d))

    if not victims:
        print("  nothing stuck")
        return
    if len(victims) > MAX_KILL:
        print("  REFUSING: %d arms match, cap is %d. That many at once looks like a probe bug,"
              " not a fleet problem -- check by hand." % (len(victims), MAX_KILL))
        return
    for arm, node, batch, jid, d in victims:
        print("  STUCK %-26s %s %s/%s" % (arm, node, batch, jid))
    if dry:
        print("  --dry-run: nothing killed")
        return

    for arm, node, batch, jid, d in victims:
        # Same hazard as the dedup path: killing a job makes badist gather and deliver whatever
        # is in its run dir, and a stuck arm's run dir holds only a partial design-load
        # transcript. If this arm already has a real result on disk, protect it.
        t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
        keep = None
        try:
            if os.path.exists(t) and b"execution took" in open(t, "rb").read():
                keep = t + ".keep"
                shutil.copy2(t, keep)
        except OSError:
            keep = None
        subprocess.run([BADIST, "cancel", batch, "--job", jid],
                       capture_output=True, timeout=60)
        # badist cancel kills the WRAPPER; the simulator survives it. Kill by cwd match.
        sh(node, 'for p in $(ls /proc 2>/dev/null | grep -E "^[0-9]+$"); do '
                 '[ "$(readlink /proc/$p/cwd 2>/dev/null)" = "%s" ] || continue; '
                 'case "$(cat /proc/$p/comm 2>/dev/null)" in '
                 'vsimk|vish|vsim|mempool_simvopt) kill -9 $p 2>/dev/null;; esac; done' % d)
        # a killed job orphans its node-local scratch; that is what filled badile13
        sh(node, 'rm -rf "%s" 2>/dev/null' % d)
        if keep:
            try:
                if not os.path.exists(t) or b"execution took" not in open(t, "rb").read():
                    shutil.copy2(keep, t)
                    print("    RESTORED %s -- a partial delivery had clobbered its result" % arm)
                os.remove(keep)
            except OSError:
                pass
        led[arm] = led.get(arm, 0) + 1
    json.dump(led, open(LEDGER, "w"), indent=1)

    lst = "/tmp/claude-620771/arms_heal.txt"
    with open(lst, "w") as f:
        for arm, _, _, _, _ in victims:
            f.write("%s s8_%s.elf build_q_8x8\n" % (arm, arm))
    p = subprocess.Popen([CLIENT, "submit", "--arms", lst, "--backend", "questa",
                          # STAGGER the requeue. Evidence: all 29 arms of the s8requeue batch
                          # started at 11:07 and all 29 hung. The hang is triggered by many arms
                          # reading the shared 17 GB Questa library over NFS at once, so requeuing
                          # the whole set at max-parallel 40 recreates the exact condition that
                          # killed them and the healer loops forever. 6 at a time lets each finish
                          # design-load before the next begins.
                          "--run-prefix", "s8", "--name", "s8heal", "--max-parallel", "6",
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
    print("  healed %d arm(s): killed, scratch removed, requeued" % len(victims))

main()
