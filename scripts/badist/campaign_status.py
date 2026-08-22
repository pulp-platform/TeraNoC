#!/usr/bin/env python3
"""Campaign-level status across ALL badist batches of the 8x8 sweep.

Why not `badist status`: it reports ONE batch (the newest by default), and a multi-wave campaign
spans many. Batch ids also multiply as waves are dispatched, so pinning them in a watcher goes
stale silently -- that is exactly how a healthy pair once reported as failed.

The stable key is the RUN-PREFIX on disk: every arm of every wave delivers to
hardware/s8_<arm>/transcript. This walks the manifest, joins it against every batch ledger that
mentions one of our arms, and reads results from disk.

  usage: campaign_status.py [--manifest FILE] [--verbose]
"""
import glob, json, os, re, subprocess, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
HW   = os.path.join(ROOT, "hardware")
STATE = os.path.expanduser("~/badist/state")
# In-REPO, deliberately. This lived in a session scratchpad under /tmp and reported "running 0"
# from any other shell: that dir is mode 0700, session-scoped, and /tmp is node-local, so it is
# unreadable to the fleet and gone once the session ends. Override with --manifest or S8_MANIFEST.
MANIFEST = os.environ.get(
    "S8_MANIFEST", os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/manifest.txt"))

def manifest(path):
    """An unreadable manifest is a HARD error. Returning [] made every bucket print 0 -- including
    "running 0" while 47 arms were live -- which reads as a finished campaign rather than a broken
    tool. Never let a missing input degrade into a plausible number."""
    try:
        raw = open(path).read()
    except OSError as e:
        sys.exit("campaign_status: cannot read manifest %s (%s)\n"
                 "  pass --manifest FILE or set S8_MANIFEST" % (path, e.strerror))
    arms = []
    for ln in raw.splitlines():
        p = ln.split()
        if len(p) == 4:
            arms.append("fp%s_%sx%sx%s" % (p[3], p[0], p[1], p[2]))
    if not arms:
        sys.exit("campaign_status: manifest %s has 0 usable rows (want '<M> <N> <P> <prec>')" % path)
    return arms

def ledger_states():
    """arm -> (state, node, batch, ts) across EVERY batch, newest ledger wins.
    ts is the time of the last state transition, so for a running arm it is its start time."""
    out = {}
    for d in sorted(glob.glob(os.path.join(STATE, "*")), reverse=True):
        jf = os.path.join(d, "jobs.json")
        if not os.path.isdir(d) or not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        # terminal states live in the per-job jsonl, not jobs.json
        term = {}
        for f in glob.glob(os.path.join(d, "jobs", "*.jsonl")):
            last = None
            for ln in open(f):
                try: last = json.loads(ln)
                except Exception: pass
            if last:
                term[os.path.basename(f)[:-6]] = (last.get("state"), last.get("node"),
                                                  last.get("ts"))
        for j in jobs:
            arm = (j.get("meta") or {}).get("arm")
            if not arm or arm in out:
                continue
            st, node, ts = term.get(j["job_id"], (j.get("state"), j.get("node"), None))
            out[arm] = (st or "?", node or "-", os.path.basename(d), ts)
    return out

NUM = re.compile(rb"execution took (\d+)")
def disk_result(arm):
    """Read the delivered transcript. Returns dict or None."""
    t = os.path.join(HW, "s8_" + arm, "transcript")
    if not os.path.exists(t):
        return None
    try:
        raw = open(t, "rb").read()
    except Exception:
        return None
    m = NUM.findall(raw)
    r = dict(cycles=int(m[-1]) if m else None,
             rh=raw.count(b"RH STUCK"), cms=raw.count(b"CMS WARN"),
             fpu=raw.count(b"\n[FPU]") + raw.count(b"\n# [FPU]"))
    ut = re.findall(rb"util=([0-9.]+)%", raw)
    r["util"] = float(ut[-1]) if ut else None
    return r

def our_batches():
    """Every batch dir holding at least one arm of this campaign, oldest first."""
    out = []
    for d in sorted(glob.glob(os.path.join(STATE, "*"))):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        if any((j.get("meta") or {}).get("arm", "").startswith(("fp16_", "fp32_")) for j in jobs):
            out.append(os.path.basename(d))
    return out

def fetch_all(batches):
    """cmd_fetch resolves exactly ONE batch (_resolve_batch), and with no --batch it takes the
    NEWEST. A campaign spanning waves therefore needs a loop -- a bare `fetch` silently delivers
    only the last wave, leaving earlier arms' transcripts on the workers."""
    cl = os.path.join(ROOT, "scripts/badist/teranoc_fleet.py")
    tot = [0, 0]
    for b in batches:
        try:
            r = subprocess.run(["timeout", "300", cl, "fetch", b, "--quiet"],
                               capture_output=True, text=True, cwd=ROOT)
            # The client prints "extracted N, missing M". Counting MATCHING LINES instead (the
            # old bug) always yielded 1 and printed "(1)" -- which read as "fetched 1 result"
            # while the truth was "extracted 0, missing 38".
            m = re.search(r"extracted (\d+), missing (\d+)", r.stdout)
            if m:
                ex, ms = int(m.group(1)), int(m.group(2))
                tot[0] += ex; tot[1] += ms
                print("  fetch %-34s rc=%d  extracted %d, missing %d" % (b, r.returncode, ex, ms))
            else:
                print("  fetch %-34s rc=%d  (no counters in output)" % (b, r.returncode))
        except Exception as e:
            print("  fetch FAILED %s: %s" % (b, e))
    print("  fetch total: extracted %d, missing %d  (missing = still running, not an error)"
          % (tot[0], tot[1]))

def main():
    verbose = "--verbose" in sys.argv
    batches = our_batches()
    if "--fetch" in sys.argv:
        fetch_all(batches)
    mpath = MANIFEST
    if "--manifest" in sys.argv:
        mpath = sys.argv[sys.argv.index("--manifest") + 1]
    arms = manifest(mpath)
    led  = ledger_states()
    buckets = dict(done=[], running=[], pending=[], failed=[], notdispatched=[], wedged=[], noprobe=[])
    for a in arms:
        st, node, batch, ts = led.get(a, (None, "-", "-", None))
        res = disk_result(a)
        if res and res["cycles"]:
            # a completed arm with no probe output is a MEASUREMENT failure, not a quiet run
            (buckets["noprobe"] if res["fpu"] == 0 else buckets["done"]).append((a, res, node))
        elif st in ("failed", "lost", "cancelled"):
            buckets["failed"].append((a, st, node))
        elif st == "running":
            # a wedge advances cycles at full CPU while doing nothing: util ~0 with a huge
            # CMS stuck-request count is the tell, since the cycle counter keeps climbing
            if res and res["util"] is not None and res["util"] < 0.5 and res["cms"] > 50000:
                buckets["wedged"].append((a, res, node))
            else:
                buckets["running"].append((a, ts, node))
        elif st in ("submitted", "dispatched", "pending"):
            buckets["pending"].append((a, st, node))
        else:
            buckets["notdispatched"].append((a, "-", "-"))

    print("8x8 CAMPAIGN  %d arms in manifest, %d batch(es): %s"
          % (len(arms), len(batches), " ".join(b[-9:] for b in batches)))
    print("  done %d   running %d   pending %d   NOT dispatched %d   failed %d   WEDGED %d   no-probe %d"
          % (len(buckets["done"]), len(buckets["running"]), len(buckets["pending"]),
             len(buckets["notdispatched"]), len(buckets["failed"]),
             len(buckets["wedged"]), len(buckets["noprobe"])))
    for k, label in (("wedged", "WEDGED (util~0, huge CMS -- cycles still advance, looks healthy)"),
                     ("noprobe", "NO PROBE DATA (completed but zero [FPU] -- measurement failed)"),
                     ("failed", "FAILED")):
        if buckets[k]:
            print("\n  %s" % label)
            for a, r, node in buckets[k]:
                print("    %-26s %s" % (a, node))
    if verbose:
        # --verbose used to print the completed table ONLY, so with nothing finished it added
        # nothing at all and looked broken. Show every populated bucket instead.
        if buckets["done"]:
            print("\n  completed (fastest first):")
            for a, r, node in sorted(buckets["done"], key=lambda x: x[1]["cycles"]):
                print("    %-26s %10s cyc  RH=%-6d util=%-6s %s"
                      % (a, "{:,}".format(r["cycles"]), r["rh"], r["util"], node))
        if buckets["running"]:
            now = int(subprocess.run(["date", "+%s"], capture_output=True,
                                     text=True).stdout.strip() or 0)
            print("\n  running (longest first) -- cycles are unavailable until an arm finishes:")
            print("    badist delivers a transcript on completion, so `fetch` reports these as")
            print("    'missing' while they run. That is expected, not a failure.")
            for a, ts, node in sorted(buckets["running"], key=lambda x: (x[1] or 0)):
                el = "%5.1fh" % ((now - ts) / 3600.0) if ts else "    ?"
                print("    %-26s %s  %s" % (a, el, node))
        if buckets["pending"]:
            print("\n  pending (queued, awaiting a licence/slot): %d" % len(buckets["pending"]))
            for a, st, node in buckets["pending"][:10]:
                print("    %-26s %s" % (a, st))
        if buckets["notdispatched"]:
            nd = [a for a, _, _ in buckets["notdispatched"]]
            print("\n  NOT dispatched: %d  (first 8: %s)" % (len(nd), ", ".join(nd[:8])))

main()
