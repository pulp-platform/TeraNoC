#!/usr/bin/env python3
"""Kill running arms whose result we ALREADY have -- and protect the ones still worth running.

Every healing loop is individually correct and none of them covers this: dedup resolves duplicates,
auto_resubmit handles failures, rescue_orphans handles undispatched arms, salvage_zombies recovers
untracked sims. An arm that is already DELIVERED and still RUNNING falls between all of them. It
holds a scarce licence seat for hours and then, on completion, overwrites the delivered transcript
with its own -- which is how fp16_2048x64x256 lost its per-group mesh data permanently.

Measured 2026-08-23: 18 such arms, 97.7 seat-hours, the oldest running 16.6 h for a result already
on disk.

EXCEPTION, and the reason this is not a blanket kill: an arm whose results.tsv row was CARRIED
FORWARD has lost its transcript, so its mesh data is gone from group_util.json and only a completed
re-run can restore it. Those re-runs are useful and are left alone. Killing them would destroy the
only path back to that arm's per-group data.

Guards, in order: the canonical transcript must be finished, it is backed up before the kill, the
kill matches on /proc/<pid>/cwd (the run dir is NOT in the command line) against a GLOBBED scratch
root (larain1/larain7 mount /scratch2, badile and larain13 mount /scratch), and the result is
re-verified afterwards and restored from the backup if anything disturbed it.
"""
import argparse, csv, glob, json, os, shutil, subprocess, sys, time

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE = os.path.expanduser("~/badist/state")
RES = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")
MESH = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/group_util.json")
BAK = "/tmp/claude-620771/redundant_backups"
PROCS = "vsimk|vish|vsim|mempool_simvopt|simv"


def delivered():
    out = set()
    try:
        with open(RES) as f:
            for ln in f.read().splitlines()[1:]:
                p = ln.split("\t")
                if len(p) > 1:
                    out.add(p[1] + "_" + p[0])
    except OSError:
        pass
    return out


def with_mesh():
    try:
        return set(json.load(open(MESH)))
    except Exception:
        return set()


def finished(arm):
    try:
        return b"execution took" in open(os.path.join(ROOT, "hardware", "s8_" + arm, "transcript"), "rb").read()
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--min-minutes", type=float, default=10.0,
                    help="ignore arms that only just started, in case a result landed this second")
    a = ap.parse_args()

    now = time.time()
    have, mesh = delivered(), with_mesh()
    victims = []
    for d in sorted(glob.glob(os.path.join(STATE, "*"))):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        for j in jobs:
            arm = (j.get("meta") or {}).get("arm", "")
            f = os.path.join(d, "jobs", j["job_id"] + ".jsonl")
            if not arm or not os.path.exists(f):
                continue
            last = t0 = None
            for ln in open(f):
                try:
                    r = json.loads(ln)
                except Exception:
                    continue
                if r.get("state") == "running" and t0 is None:
                    t0 = r.get("ts")
                last = r
            if not last or last.get("state") != "running":
                continue
            if arm not in have and not finished(arm):
                continue                      # no result yet -- this run is doing real work
            if arm not in mesh:
                print("  KEEP %-24s result exists but MESH DATA IS MISSING -- this re-run "
                      "is the only way to restore it" % arm)
                continue
            mins = (now - t0) / 60.0 if t0 else 0
            if mins < a.min_minutes:
                continue
            victims.append((arm, last.get("node"), mins, os.path.basename(d), j["job_id"]))

    if not victims:
        print("  no redundant running arms")
        return 0
    victims.sort(key=lambda v: -v[2])
    print("  %d redundant arm(s), %.1f seat-hours:" % (len(victims), sum(v[2] for v in victims) / 60))
    killed = 0
    os.makedirs(BAK, exist_ok=True)
    for arm, node, mins, batch, jid in victims:
        print("    %-24s %-10s %5.0f min" % (arm, node, mins))
        if a.dry_run:
            continue
        t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
        keep = os.path.join(BAK, arm + ".transcript")
        try:
            shutil.copy2(t, keep)
        except OSError:
            print("      cannot back up the result -- skipping"); continue
        cmd = ('n=0; for p in $(ls /proc 2>/dev/null | grep -E "^[0-9]+$"); do '
               'c=$(readlink /proc/$p/cwd 2>/dev/null) || continue; m=0; '
               'for cand in /scratch*/%s_cache/badist/run/%s/%s; do [ "$c" = "$cand" ] && m=1; done; '
               '[ "$m" = 1 ] || continue; '
               'case "$(cat /proc/$p/comm 2>/dev/null)" in %s) kill -9 $p 2>/dev/null && n=1;; esac; '
               'done; echo $n' % (os.environ.get("USER", "zexifu"), batch, jid, PROCS))
        try:
            r = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                                "-o", "StrictHostKeyChecking=no", node, cmd],
                               capture_output=True, timeout=90)
            if r.stdout.decode().strip().endswith("1"):
                killed += 1
                print("      killed")
        except Exception as e:
            print("      ssh failed: %s" % e)
        if not finished(arm):              # the kill must never cost us the result
            shutil.copy2(keep, t)
            print("      result was disturbed -- restored from backup")
    print("  killed %d, freeing ~%.1f seat-hours/day" % (killed, sum(v[2] for v in victims) / 60))
    return 0


if __name__ == "__main__":
    sys.exit(main())
