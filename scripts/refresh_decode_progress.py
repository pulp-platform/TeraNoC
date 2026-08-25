#!/usr/bin/env python3
"""Refresh live progress for running decode arms into docs/benchmarks/decode_progress.json.

Kept SEPARATE from the dashboard generator on purpose: this is the only step that touches the
network, so the generator stays fast and can always run offline from whatever this last wrote.
Discovers arms from the badist ledger -- no hardcoded arm list, so a new run or a new mesh is
picked up without editing anything.
"""
import glob, json, os, re, subprocess, time

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE = os.path.expanduser("~/badist/state")
OUT = os.path.join(ROOT, "docs/benchmarks/decode_progress.json")
# Any arm whose name matches this is a decode arm. Extend the alternation for a new family.
ARM_RE = re.compile(r"^(dec\d|d\df32|dec)[A-Za-z0-9]*_\d+x\d+x\d+$")


def running_arms():
    out = {}
    for d in sorted((x for x in glob.glob(os.path.join(STATE, "*")) if os.path.isdir(x)),
                    key=os.path.getmtime, reverse=True):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        for j in jobs:
            arm = (j.get("meta") or {}).get("arm", "")
            if not ARM_RE.match(arm):
                continue
            f = os.path.join(d, "jobs", j["job_id"] + ".jsonl")
            st = node = None
            try:
                for ln in open(f):
                    r = json.loads(ln)
                    st = r.get("state"); node = r.get("node") or node
            except OSError:
                continue
            if st == "running" and arm not in out:
                out[arm] = (node, os.path.basename(d), j["job_id"])
    return out


prog = {}
for arm, (node, batch, jid) in sorted(running_arms().items()):
    if not node:
        continue
    cmd = ("d=$(ls -d /scratch*/zexifu_cache/badist/run/%s/%s 2>/dev/null|head -1); "
           "[ -n \"$d\" ] || exit; "
           "grep -a '\\[FPU\\] bench' $d/transcript 2>/dev/null | tail -1 | sed 's/^# //'" % (batch, jid))
    try:
        r = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=12",
                            "-o", "StrictHostKeyChecking=no", node, cmd],
                           capture_output=True, text=True, timeout=40)
        line = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    except Exception:
        line = ""
    m = re.search(r"cyc=(\d+)\s+util=([0-9.]+)%\s+cum=([0-9.]+)%", line)
    prog[arm] = {"node": node, "cyc": int(m.group(1)) if m else None,
                 "util": float(m.group(2)) if m else None,
                 "cum": float(m.group(3)) if m else None,
                 "state": "running"}
os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump({"ts": int(time.time()), "arms": prog}, open(OUT, "w"), indent=1)
print("wrote %s (%d running arm(s))" % (OUT, len(prog)))
