#!/usr/bin/env python3
"""Keep the VCS licence pool full by moving queued arms onto it.

VCS runs this design ~1.6x faster than Questa (19.4 vs 12.2 cyc/s) but has a far smaller pool
(100 seats against Questa's 200-seat mtiverification). So the cheapest throughput win is to keep
VCS at its reserve line while Questa carries the bulk -- idle VCS seats are pure loss.

Only ever submits arms that are QUEUED and not running anywhere: an arm already executing must
never be duplicated onto the other simulator, since both copies deliver to the same run dir.

Moving a queued arm does leave a stale queued copy in its old batch. That is deliberate: the old
copy cannot be cancelled safely -- cancelling a queued job in a superseded batch nudges the
scheduler into dispatching another of its jobs (measured; see KNOWN_ISSUES). If both copies do
start, kill_duplicate_arms.py keeps the older and protects the delivered result. A little
duplicate work is much cheaper than a queue that refills itself.
The submitted batch carries the normal VCS governor (reserve 5), so it self-limits; this script
only decides how many arms to hand it, never how many run.

  usage: vcs_topup.py [--reserve 5] [--batch 12] [--dry-run]
"""
import glob, json, os, re, subprocess, sys

ROOT   = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE  = os.path.expanduser("~/badist/state")
CLIENT = os.path.join(ROOT, "scripts/badist/teranoc_fleet.py")
IMAGE  = "build_vcs_8x8/mempool_simvopt"
FEAT, SERVER = "VCS-Base-Runtime-Pkg", "8169@lic-synopsys.ethz.ch"

def seats():
    try:
        out = subprocess.check_output(["lmutil", "lmstat", "-c", SERVER, "-f", FEAT],
                                      stderr=subprocess.STDOUT, text=True, timeout=90)
    except Exception:
        return None
    m = re.search(r"Total of (\d+) licenses? issued;\s*Total of (\d+) licenses? in use", out)
    return (int(m.group(1)), int(m.group(2))) if m else None

def main():
    reserve = int(sys.argv[sys.argv.index("--reserve") + 1]) if "--reserve" in sys.argv else 5
    want    = int(sys.argv[sys.argv.index("--batch") + 1]) if "--batch" in sys.argv else 12
    dry     = "--dry-run" in sys.argv

    s = seats()
    if not s:
        print("  could not read the VCS pool -- doing nothing")
        return
    issued, in_use = s
    room = issued - in_use - reserve
    print("  VCS %d/%d in use, reserve %d -> room for %d" % (in_use, issued, reserve, room))
    if room <= 0:
        print("  pool is at the reserve line; nothing to add")
        return

    running, queued = set(), []
    for d in sorted(glob.glob(os.path.join(STATE, "*"))):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        started = {os.path.basename(f)[:-6] for f in glob.glob(os.path.join(d, "jobs", "*.jsonl"))}
        for j in jobs:
            a = (j.get("meta") or {}).get("arm", "")
            if not a.startswith(("fp16_", "fp32_")):
                continue
            if j["job_id"] not in started:
                queued.append(a)
                continue
            last = None
            for ln in open(os.path.join(d, "jobs", j["job_id"] + ".jsonl")):
                try:
                    last = json.loads(ln)
                except Exception:
                    pass
            if last and last.get("state") == "running":
                running.add(a)

    pick, seen = [], set()
    for a in queued:
        # never move an arm that is already executing, and never one already finished
        if a in running or a in seen:
            continue
        t = os.path.join(ROOT, "hardware", "s8_" + a, "transcript")
        try:
            if os.path.exists(t) and b"execution took" in open(t, "rb").read():
                continue
        except OSError:
            pass
        seen.add(a); pick.append(a)
        if len(pick) >= want:
            break
    if not pick:
        print("  no queued arm is free to move")
        return
    print("  moving %d queued arm(s) to VCS: %s%s"
          % (len(pick), ", ".join(pick[:4]), " ..." if len(pick) > 4 else ""))
    if dry:
        print("  --dry-run: not submitting")
        return
    lst = "/tmp/claude-620771/arms_vcs_topup.txt"
    with open(lst, "w") as f:
        for a in pick:
            f.write("%s s8_%s.elf %s\n" % (a, a, IMAGE))
    p = subprocess.Popen([CLIENT, "submit", "--arms", lst, "--backend", "vcs",
                          "--run-prefix", "s8", "--name", "s8vtop", "--max-parallel", "30",
                          "--mem-gb", "12", "--est-runtime-s", "60000", "--force"],
                         cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=120)
    except subprocess.TimeoutExpired:
        out = "(controller running in background -- expected)"
    for ln in (out or "").splitlines():
        if "batch" in ln or "rror" in ln:
            print("  %s" % ln)

main()
