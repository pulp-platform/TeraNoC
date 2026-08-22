#!/usr/bin/env python3
"""Kill the younger copy when an arm is running in more than one batch.

Both copies deliver to the same hardware/s8_<arm>/ run dir, so leaving them racing can interleave
two simulators' output into one result file. That is worse than the wasted licence.

Why this must be automatic: `badist cancel` on a never-started job writes no ledger record and
does NOT reliably stop a later dispatch -- 102 jobs cancelled at 06:55 kept starting hours
afterwards. So the duplicates cannot be prevented at the source from here; detect and clear them.

Keeps the copy that started EARLIEST (most progress) and kills the rest.
  usage: kill_duplicate_arms.py [--dry-run]
"""
import glob, json, os, shutil, subprocess, sys, collections

ROOT   = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE  = os.path.expanduser("~/badist/state")
BADIST = os.path.expanduser("~/badist/bin/badist")

def main():
    dry = "--dry-run" in sys.argv
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
    killed = 0
    for arm, v in sorted(run.items()):
        if len(v) < 2:
            continue
        v.sort()
        keep = v[0]
        for ts, batch, jid, node in v[1:]:
            print("  DUP %-22s kill %s/%s on %-10s (keeping %s, started earlier)"
                  % (arm, batch[:24], jid, node, keep[1][:24]))
            if dry:
                continue
            # DO NOT `badist cancel` here. Measured: this batch's dispatch records grew 70 -> 73
            # at 13:46:57 and 14:18:10, exactly when this loop ran. Cancelling a job in a
            # superseded batch nudges the scheduler into dispatching another of its pending jobs,
            # which becomes the next duplicate -- so the cleanup fed the problem it removes.
            # Killing the process alone ends this copy without touching the batch's queue.
            # PROTECT THE DELIVERED RESULT FIRST. Killing a duplicate makes badist gather
            # whatever is in its run dir and deliver it -- a partial, design-load-only transcript
            # -- straight over hardware/s8_<arm>/transcript. That destroyed two completed results
            # (the campaign's done count fell 19 -> 18) before this guard existed.
            t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
            keep = None
            try:
                if os.path.exists(t) and b"execution took" in open(t, "rb").read():
                    keep = t + ".keep"
                    shutil.copy2(t, keep)
            except OSError:
                keep = None
            d = "/scratch/zexifu_cache/badist/run/%s/%s" % (batch, jid)
            # cancel kills the wrapper only; the simulator survives it
            subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                            "-o", "StrictHostKeyChecking=no", node,
                            'for p in $(ls /proc 2>/dev/null | grep -E "^[0-9]+$"); do '
                            '[ "$(readlink /proc/$p/cwd 2>/dev/null)" = "%s" ] || continue; '
                            'case "$(cat /proc/$p/comm 2>/dev/null)" in '
                            'vsimk|vish|vsim|mempool_simvopt) kill -9 $p 2>/dev/null;; esac; done' % d],
                           capture_output=True, timeout=60)
            # restore if the kill caused a partial to land on top of a good result
            if keep:
                try:
                    if not os.path.exists(t) or b"execution took" not in open(t, "rb").read():
                        shutil.copy2(keep, t)
                        print("      RESTORED %s -- a partial delivery had clobbered it" % arm)
                    os.remove(keep)
                except OSError:
                    pass
            killed += 1
    print("  killed %d duplicate cop%s" % (killed, "y" if killed == 1 else "ies") if killed
          else "  no duplicates" if not any(len(v) > 1 for v in run.values()) else "  (dry run)")

main()
