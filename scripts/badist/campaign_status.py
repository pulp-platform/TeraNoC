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
import glob, json, os, re, subprocess, sys, time

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

def by_node():
    """Per-MACHINE view: which arms sit on which node, and whether they are actually getting CPU.

    Needed because "running" is not "progressing": badist reports a starved job (CPU share below
    min_efficiency) but does NOT move it unless migrate_when_starved is set, so an arm can hold a
    licence and 16 GiB at 0% of a core indefinitely while every count calls it healthy.
    """
    arms = {}
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
            last, frac, note = None, None, ""
            for ln in f and open(f):
                try:
                    r = json.loads(ln)
                except Exception:
                    continue
                last = r
                if r.get("starved_cpu_frac") is not None:
                    frac = r["starved_cpu_frac"]; note = r.get("note", "")
            if not last:
                continue
            if last.get("state") == "running":
                arms[arm] = (last.get("node", "?"), frac, note, jid,
                             os.path.basename(d), last.get("ts"))
    return arms

def print_by_node():
    arms = by_node()
    loads = {}
    try:
        out = subprocess.run(["timeout", "90", os.path.expanduser("~/badist/bin/badist"), "nodes"],
                             capture_output=True, text=True).stdout
        for ln in out.splitlines()[2:]:
            f = ln.split()
            if len(f) >= 4 and not f[0].startswith("-"):
                loads.setdefault(f[0], (f[1], f[2], f[3]))
    except Exception:
        pass
    per = {}
    for arm, (node, frac, note, jid, batch, ts) in arms.items():
        per.setdefault(node, []).append((arm, frac))
    print("\n  RUNNING ARMS BY MACHINE (%d arms on %d nodes)" % (len(arms), len(per)))
    print("    %-12s %5s %8s %5s  %s" % ("NODE", "CORES", "LOAD", "ARMS", "STARVED (cpu share)"))
    nstarved = 0
    for node in sorted(per, key=lambda n: -len(per[n])):
        c, l, m = loads.get(node, ("?", "?", "?"))
        st = [(a, f) for a, f in per[node] if f is not None]
        nstarved += len(st)
        lab = ", ".join("%s %.0f%%" % (a, f * 100) for a, f in st[:2]) if st else ""
        if len(st) > 2:
            lab += " +%d more" % (len(st) - 2)
        print("    %-12s %5s %8s %5d  %s" % (node, c, l, len(per[node]), lab))
    print("    -- %d arm(s) carry a starvation record. That flag is STICKY and HISTORICAL:" % nstarved)
    print("       badist writes it when it detects a low CPU share but writes nothing when the job")
    print("       recovers, so it does not mean the arm is starved NOW. A Questa arm reads a 17 GB")
    print("       shared library over NFS at startup and is legitimately ~0%% CPU for many minutes.")
    print("       Use --by-node --probe for LIVE CPU before acting on any of these.")

def probe_live(nodes):
    """Ask the nodes themselves what our simulators are actually doing right now.

    The ledger cannot answer this: its starvation record is written once, at detection, and never
    retracted. Acting on it would have cancelled ~20 arms that were running at 83-99%.
    """
    import concurrent.futures as cf
    def one(n):
        cmd = ("ps -u $(whoami) -o stat=,pcpu=,etime=,comm= 2>/dev/null "
               "| grep -E 'vsimk|mempool_simvopt|simv' || true")
        try:
            r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                                "-o", "StrictHostKeyChecking=no", n, cmd],
                               capture_output=True, text=True, timeout=30)
            rows = [l.split(None, 3) for l in r.stdout.strip().splitlines() if l.strip()]
            cpus = [float(x[1]) for x in rows if len(x) >= 2]
            return n, cpus
        except Exception:
            return n, None
    out = {}
    with cf.ThreadPoolExecutor(max_workers=12) as ex:
        for n, c in ex.map(one, nodes):
            out[n] = c
    return out

_DELIVERED = None


def _recorded_arms():
    """Arms with a row in results.tsv -- i.e. a measurement we HAVE, whatever is on disk now.

    A delivered transcript can be destroyed after the fact: badist writes
    hardware/s8_<arm>/transcript unconditionally, so a re-run or duplicate overwrites a finished
    result with its own partial one. results.tsv is merge-only and keeps the row, so it outlives
    the evidence. Without this, an arm that HAS been measured reverts to "not done" the moment it
    is re-run -- which is exactly when the count is least trustworthy, and made this tool disagree
    with the dashboard (51 vs 53)."""
    global _DELIVERED
    if _DELIVERED is None:
        _DELIVERED = {}
        try:
            with open(os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")) as fh:
                for ln in fh.read().splitlines()[1:]:
                    p_ = ln.split("\t")
                    if len(p_) > 4:
                        try:
                            cyc = int(p_[3])
                        except ValueError:
                            continue
                        _DELIVERED[p_[1] + "_" + p_[0]] = dict(
                            cycles=cyc, util=None, rh=0, cms=0, fpu=1, recorded=True)
        except OSError:
            pass
    return _DELIVERED


def _has_result(arm):
    """True if this arm has been measured: a finished transcript now, or a recorded row."""
    t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
    try:
        if os.path.exists(t) and b"execution took" in open(t, "rb").read():
            return True
    except OSError:
        pass
    return arm in _recorded_arms()


def ledger_states():
    """arm -> (state, node, batch, ts, rank) across EVERY batch; the BEST state wins.
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
            if not arm:
                continue
            if j["job_id"] in term:
                st, node, ts = term[j["job_id"]]
                st = st or "?"
            else:
                # No jsonl = the job has never started. That is QUEUED, not unknown: after a heal
                # the arm's only other record is the cancelled copy it replaced, and ranking an
                # unstarted job below that made 15 freshly-requeued arms report as failures.
                st, node, ts = "queued", j.get("node"), None
            # An arm can have SEVERAL copies across batches (a resubmit, a heal, a duplicate that
            # was killed). Latest-timestamp is the wrong rule: killing a duplicate writes a NEWER
            # cancelled record than the surviving copy's `running`, so a perfectly healthy arm
            # reported as failed -- 22 of them at once, every poll, which trains you to ignore the
            # alarm. An arm with ANY live copy is running. Rank by what the arm actually IS, and
            # use ts only to break ties within a rank.
            # `done` outranks `running` ONLY when the arm has a real result. badist marks a job
            # done after delivering a partial (a killed job's half-written run dir), so a
            # done-without-result copy would otherwise beat a healthy running copy of the same
            # arm -- and then fail the result test and land in the catch-all bucket, reporting 7
            # perfectly live arms as "NOT dispatched".
            rank = {"running": 3, "done": 4, "succeeded": 4, "completed": 4,
                    "submitted": 2, "dispatched": 2, "pending": 2, "queued": 2}.get(st, 1)
            if rank == 4 and not _has_result(arm):
                rank = 1
            prev = out.get(arm)
            if prev is None or rank > prev[4] or (rank == prev[4] and (ts or 0) >= (prev[3] or 0)):
                out[arm] = (st, node or "-", os.path.basename(d), ts, rank)
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
    if "--by-node" in sys.argv:
        print_by_node()
        if "--probe" in sys.argv:
            arms = by_node()
            nodes = sorted({v[0] for v in arms.values()})
            print("\n  LIVE CPU probe (%d nodes, ssh):" % len(nodes))
            live = probe_live(nodes)
            hot = cold = dead = 0
            for n in nodes:
                c = live.get(n)
                if c is None:
                    dead += 1; print("    %-12s unreachable" % n); continue
                if not c:
                    dead += 1; print("    %-12s NO SIM PROCESS (%d arms claimed)"
                                     % (n, sum(1 for v in arms.values() if v[0] == n))); continue
                low = [x for x in c if x < 20.0]
                hot += len(c) - len(low); cold += len(low)
                flag = "  <-- %d below 20%%" % len(low) if low else ""
                print("    %-12s %2d proc  cpu%% %s%s"
                      % (n, len(c), " ".join("%.0f" % x for x in sorted(c, reverse=True)[:8]), flag))
            print("    -- %d process(es) >=20%% CPU, %d below, %d node(s) with none/unreachable"
                  % (hot, cold, dead))
        return
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
        st, node, batch, ts, _rank = led.get(a, (None, "-", "-", None, 0))
        res = disk_result(a)
        if not (res and res["cycles"]):
            # The transcript can be MISSING or MID-REWRITE: badist overwrites it unconditionally,
            # so a re-run replaces a finished result with a partial one. Reading during that window
            # made this tool report delivered arms as "needs a rerun" and bounced the done count
            # 51 -> 46 -> 48 -> 51 between consecutive runs. results.tsv is merge-only and keeps the
            # measurement, so fall back to it rather than un-completing an arm we have measured.
            rec = _recorded_arms().get(a)
            if rec:
                res = dict(rec)
        if res and res["cycles"]:
            # a completed arm with no probe output is a MEASUREMENT failure, not a quiet run
            (buckets["noprobe"] if res["fpu"] == 0 else buckets["done"]).append((a, res, node))
        elif st in ("failed", "lost", "cancelled"):
            buckets["failed"].append((a, st, node))
        elif st == "running":
            # a wedge advances cycles at full CPU while doing nothing: util ~0 with a huge
            # CMS stuck-request count is the tell, since the cycle counter keeps climbing.
            #
            # MIN_WEDGE_S: a freshly-started arm looks EXACTLY like a wedge and is not one. The FPU
            # probe reads zero until the benchmark region opens -- boot, DMA and several 1024-core
            # barriers come first -- and cold-start CMS stuck-request warnings are normal (every
            # completed arm in this campaign carries some). Three arms six minutes into their run
            # were reported WEDGED on 2026-08-23; acting on that would have killed healthy work.
            # The healer, which tests for lack of progress instead, correctly said nothing stuck.
            MIN_WEDGE_S = 3600
            age_s = (time.time() - ts) if ts else 0
            if (age_s > MIN_WEDGE_S and res and res["util"] is not None
                    and res["util"] < 0.5 and res["cms"] > 50000):
                buckets["wedged"].append((a, res, node))
            else:
                buckets["running"].append((a, ts, node))
        elif st in ("submitted", "dispatched", "pending", "queued"):
            buckets["pending"].append((a, st, node))
        else:
            # reached only when every copy is terminal with nothing delivered
            buckets["notdispatched"].append((a, st or "-", node))

    print("8x8 CAMPAIGN  %d arms in manifest, %d batch(es): %s"
          % (len(arms), len(batches), " ".join(b[-9:] for b in batches)))
    print("  done %d   running %d   pending %d   NOT dispatched %d   failed %d   WEDGED %d   no-probe %d"
          % (len(buckets["done"]), len(buckets["running"]), len(buckets["pending"]),
             len(buckets["notdispatched"]), len(buckets["failed"]),
             len(buckets["wedged"]), len(buckets["noprobe"])))
    for k, label in (("wedged", "WEDGED (util~0, huge CMS -- cycles still advance, looks healthy)"),
                     ("noprobe", "NO PROBE DATA (completed but zero [FPU] -- measurement failed)"),
                     ("failed", "FAILED"),
                     ("notdispatched", "NO LIVE COPY AND NO RESULT (needs a rerun)")):
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
