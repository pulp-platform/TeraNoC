#!/usr/bin/env python3
"""Report arms RUNNING in more than one batch at once.

This is not merely wasted licences and slots: both copies deliver to the same
hardware/s8_<arm>/ run dir, so two simulators can interleave writes into one result.

How it happens: a batch's queued jobs are cancelled and resubmitted as a new batch, but a job
that started between the snapshot and the cancel keeps running -- and `badist cancel` on a
never-started job writes no ledger record, so it cannot be confirmed to have stuck. Detect the
outcome rather than trusting the cancel.
"""
import glob, json, os, collections

STATE = os.path.expanduser("~/badist/state")

def main():
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
    dup = {a: sorted(v) for a, v in run.items() if len(v) > 1}
    if not dup:
        print("  no duplicate running arms")
        return
    print("  %d arm(s) running in more than one batch:" % len(dup))
    for a, v in sorted(dup.items()):
        print("    %s" % a)
        for i, (ts, b, jid, node) in enumerate(v):
            # keep the earliest start (most progress); the rest are the ones to kill
            tag = "KEEP (oldest)" if i == 0 else "kill"
            print("      %-28s job=%s %-10s  %s" % (b[:28], jid, node, tag))

main()
