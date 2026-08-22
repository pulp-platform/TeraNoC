#!/usr/bin/env python3
"""Recover results from simulations badist has stopped tracking, and release their licences.

`badist cancel` does not kill a running simv/vsim -- it only rewrites the ledger. The sim keeps
running on the node, finishes its benchmark into node-local /scratch2, and then parks at the vsim
prompt holding an mtiverification seat forever. badist never fetches it, because the job's last
state is `cancelled`, so the work is invisible: hours of simulation and a scarce licence, spent on
a result nobody collects.

This finds those sims, copies any FINISHED transcript back to the canonical
hardware/s8_<arm>/transcript that collect_8x8_results.py reads, and only then kills the parked
process. Unfinished sims are left strictly alone -- a zombie is often further along than the live
copy that replaced it, so killing one to reclaim a seat can throw away the better run.

Hosts come from the licence server: only a host holding one of our seats can be holding a parked
sim, which keeps the scan small and self-limiting.
"""
import argparse, json, glob, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE = os.path.expanduser("~/badist/state")
LIC_SERVER = "8161@lic-mentor.ethz.ch"
DONE = b"execution took"


def sh(host, cmd, timeout=90):
    """One non-interactive ssh. -n matters: without it ssh eats the caller's stdin, which
    silently truncates any `while read` loop driving this function."""
    try:
        r = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                            "-o", "StrictHostKeyChecking=no", host, cmd],
                           capture_output=True, timeout=timeout)
        return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None
    except Exception:
        return None


def ledger():
    """(batch, job_id) -> (arm, last_state), plus the set of arms with a live running job."""
    info, live = {}, set()
    for d in sorted(glob.glob(os.path.join(STATE, "*"))):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        b = os.path.basename(d)
        for j in jobs:
            jid = j["job_id"]
            arm = (j.get("meta") or {}).get("arm", "")
            st, lf = "queued", os.path.join(d, "jobs", jid + ".jsonl")
            if os.path.exists(lf):
                for ln in open(lf):
                    try:
                        st = json.loads(ln).get("state", st)
                    except Exception:
                        pass
            info[(b, jid)] = (arm, st)
            if st == "running":
                live.add(arm)
    return info, live


def lic_hosts():
    try:
        out = subprocess.run(["lmutil", "lmstat", "-c", LIC_SERVER, "-f", "mtiverification"],
                             capture_output=True, timeout=180).stdout.decode("utf-8", "replace")
    except Exception:
        return []
    user = os.environ.get("USER", "")
    hosts = {ln.split()[1].split(".")[0] for ln in out.splitlines()
             if ln.strip().startswith(user + " ") and len(ln.split()) > 1}
    return sorted(hosts)


def canonical_is_done(arm):
    t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
    try:
        return DONE in open(t, "rb").read()
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--hosts", help="comma-separated override")
    a = ap.parse_args()

    info, live = ledger()
    hosts = a.hosts.split(",") if a.hosts else lic_hosts()
    if not hosts:
        print("  no hosts hold our Questa seats -- nothing to scan")
        return 0

    probe = (r'''ps -u $USER -o pid=,comm= 2>/dev/null | grep vsimk | while read pid c; do '''
             r'''cwd=$(readlink /proc/$pid/cwd 2>/dev/null); case "$cwd" in */run/*) ;; *) continue;; esac; '''
             r'''d=0; grep -aqm1 "execution took" "$cwd/transcript" 2>/dev/null && d=1; '''
             r'''echo "$pid|$d|$cwd"; done''')

    salvaged = killed = skipped = 0
    for h in hosts:
        out = sh(h, probe)
        if out is None:
            print("  %-10s unreachable" % h)
            continue
        for ln in out.splitlines():
            p = ln.strip().split("|")
            if len(p) != 3:
                continue
            pid, done, cwd = p[0], p[1] == "1", p[2]
            m = re.search(r"/run/([^/]+)/(\d+)/?$", cwd)
            if not m:
                continue
            arm, st = info.get((m.group(1), m.group(2)), ("", ""))
            if not arm or st == "running":
                continue          # badist still owns it; leave it entirely alone
            if not done:
                skipped += 1      # still simulating -- often AHEAD of the live copy; never kill
                continue
            if canonical_is_done(arm):
                print("  %-10s %-22s already delivered; releasing seat" % (h, arm))
                if not a.dry_run and sh(h, "kill -9 %s" % pid) is not None:
                    killed += 1
                continue
            print("  %-10s %-22s FINISHED, not collected -> salvage" % (h, arm))
            if a.dry_run:
                continue
            d = os.path.join(ROOT, "hardware", "s8_" + arm)
            os.makedirs(d, exist_ok=True)
            tmp = os.path.join(d, "transcript.salv")
            with open(tmp, "wb") as fh:
                r = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                                    h, "cat %s/transcript" % cwd], stdout=fh, timeout=900)
            ok = r.returncode == 0 and DONE in open(tmp, "rb").read()
            if not ok:                       # never trade a live sim for a truncated copy
                os.remove(tmp)
                print("      copy incomplete -- left running")
                continue
            os.replace(tmp, os.path.join(d, "transcript"))
            salvaged += 1
            if sh(h, "kill -9 %s" % pid) is not None:
                killed += 1
    print("  salvaged %d result(s), released %d seat(s), left %d still-simulating alone"
          % (salvaged, killed, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
