#!/usr/bin/env python3
"""Cancel a running arm whose result has ALREADY been delivered.

An arm re-dispatched after its result landed burns a licence seat for hours and can only
overwrite a good transcript with a worse one. This finds those copies and kills the simulator.

Discipline, in order -- every step exists because skipping it destroyed data before:
  1. The delivered transcript must contain `execution took` (a complete run), else it is not
     a result and the running copy is the only chance of getting one.
  2. The delivered result must PREDATE the running job's start. If the transcript was written
     after the job began, that transcript IS this job's own output -- the ledger simply has not
     caught up -- and there is nothing redundant to reclaim.
  3. Never touch a batch this campaign did not create (another agent shares the fleet).
  4. Back the transcript up before the kill and restore if a partial gather lands on it.
     `badist` gathers the run dir when a job dies, so killing writes a design-load-only
     transcript straight over the good one. This already cost two completed results once.

  usage: kill_delivered_arms.py [--dry-run]
"""
import glob, json, os, shutil, subprocess, sys, collections, time

ROOT   = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE  = os.path.expanduser("~/badist/state")
SEEN   = "/tmp/claude-620771/delivered_killed.json"
MINE   = ("s8auto", "s8heal", "s8rescue", "s8qtop", "s8vtop", "s8big", "s8rehome",
          "s8requeue", "s8vfill", "s8orph", "s8rq", "s8vcs", "s8q-", "s8q2", "teranoc")
GRACE  = 900   # s: a result written within 15 min of the job start is treated as the job's own


def running_jobs():
    run = collections.defaultdict(list)
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
            last, first = None, None
            for ln in open(f):
                try:
                    r = json.loads(ln)
                except Exception:
                    continue
                if r.get("state") == "running" and first is None:
                    first = r
                last = r
            if last and last.get("state") == "running":
                run[arm].append((first.get("ts", 0) if first else 0,
                                 os.path.basename(d), jid, last.get("node")))
    return run


def delivered(arm):
    """(complete, mtime) for hardware/s8_<arm>/transcript, or None."""
    t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
    try:
        if not os.path.exists(t):
            return None
        return (b"execution took" in open(t, "rb").read(), os.path.getmtime(t))
    except OSError:
        return None


def main():
    dry = "--dry-run" in sys.argv
    try:
        seen = set(json.load(open(SEEN)))
    except Exception:
        seen = set()
    killed = skipped = 0
    for arm, copies in sorted(running_jobs().items()):
        dv = delivered(arm)
        if not dv or not dv[0]:
            continue
        _, dmtime = dv
        for ts, batch, jid, node in sorted(copies):
            key = "%s/%s" % (batch, jid)
            if key in seen:
                continue
            if not batch.startswith(MINE):
                print("  FOREIGN %-22s %s/%s -- not ours, leaving it" % (arm, batch[:24], jid))
                continue
            # Step 2: is the result this job's own output?
            if dmtime > ts + GRACE:
                print("  OWN     %-22s result written %.0f min AFTER job start -- this job's own"
                      % (arm, (dmtime - ts) / 60.0))
                skipped += 1
                continue
            print("  DONE    %-22s kill %s/%s on %-10s (result delivered %.1f h before start)"
                  % (arm, batch[:22], jid, node, (ts - dmtime) / 3600.0))
            killed += 1
            if dry:
                continue
            seen.add(key)
            # Step 4: protect the good transcript across the kill's gather.
            t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
            bak = None
            try:
                bak = t + ".keep"
                shutil.copy2(t, bak)
            except OSError:
                bak = None
            # Glob the scratch root -- larain1/7 mount /scratch2, badile mounts /scratch.
            d = "/scratch*/zexifu_cache/badist/run/%s/%s" % (batch, jid)
            subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                            "-o", "StrictHostKeyChecking=no", node,
                            'for p in $(ls /proc 2>/dev/null | grep -E "^[0-9]+$"); do '
                            'c=$(readlink /proc/$p/cwd 2>/dev/null); m=0; '
                            'for cand in %s; do [ "$c" = "$cand" ] && m=1; done; '
                            '[ "$m" = 1 ] || continue; '
                            'case "$(cat /proc/$p/comm 2>/dev/null)" in '
                            'vsimk|vish|vsim|mempool_simvopt) kill -9 $p 2>/dev/null;; esac; done' % d],
                           capture_output=True, timeout=60)
            if bak:
                try:
                    time.sleep(2)
                    if not os.path.exists(t) or b"execution took" not in open(t, "rb").read():
                        shutil.copy2(bak, t)
                        print("      RESTORED %s -- a partial gather had clobbered it" % arm)
                    os.remove(bak)
                except OSError:
                    pass
    if not dry:
        try:
            json.dump(sorted(seen), open(SEEN, "w"))
        except OSError:
            pass
    print("  %s %d already-delivered cop%s%s"
          % ("would kill" if dry else "killed", killed, "y" if killed == 1 else "ies",
             (", %d left running (own output)" % skipped) if skipped else ""))


main()
