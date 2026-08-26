#!/usr/bin/env python3
"""Stop a full node-local disk from silently destroying finished simulations.

badist's worker packages results with `tar -cf - | zstd -o $OUTDIR/$JOB.tar.zst` onto node-local
/scratch2. If that disk is full the tar fails with ENOSPC and the job is recorded as
`packaging failed` -- AFTER the simulation has run to completion. The arm delivers nothing and the
hours are gone. It was the campaign's single largest failure mode: 24 occurrences, 16 of them on
larain2 alone, whose 7 TB /scratch2 had 224 KB free.

The concentration is the tell. It first reads as a big-shape problem (18 of 24 had a >=2048
dimension) but that is confounded -- long arms are simply likelier to be resident when a node fills
up. Group by node before believing a shape story.

This checks the disk on every node we have work on, and when one is low it reclaims OUR spent run
directories. Three guards, because deleting the wrong directory destroys a running simulation:
  1. the node must have no live simulator of ours whose /proc/<pid>/cwd IS that directory
     (a command-line match does NOT work -- the run dir is never in vsim's argv),
  2. the owning job must be terminal in the ledger (never queued/running),
  3. a transcript that FINISHED but was never delivered is salvaged to
     hardware/s8_<arm>/transcript before anything is removed.
Other users' data is never touched -- only /scratch2/$USER_cache/badist/run.
"""
import json as _json
import time as _time
import os as _os
import argparse, glob, json, os, re, subprocess, sys

ROOT  = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE = os.path.expanduser("~/badist/state")
USER  = os.environ.get("USER", "zexifu")
# The node-local scratch path DIFFERS BY MACHINE: larain/fenga hosts mount /scratch2, the badile
# fleet mounts /scratch. Hardcoding one silently skips every node using the other -- the first
# version checked /scratch2 only and so never looked at any of the 42 badile nodes, including the
# one with four packaging failures. Resolve it per host instead.
CACHE_GLOB = "/scratch*/%s_cache/badist/run" % USER
DONE  = b"execution took"
LOW_GB = 25          # a tarball is a few GB; below this, packaging is at risk


def sh(host, cmd, timeout=120):
    try:
        r = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                            "-o", "StrictHostKeyChecking=no", host, cmd],
                           capture_output=True, timeout=timeout)
        return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None
    except Exception:
        return None


def ledger():
    """(batch, job) -> (arm, state) and the nodes we currently have work on."""
    info, nodes = {}, set()
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
            jid, arm = j["job_id"], (j.get("meta") or {}).get("arm", "")
            lf = os.path.join(d, "jobs", jid + ".jsonl")
            st, node = "queued", None
            if os.path.exists(lf):
                for ln in open(lf):
                    try:
                        r = json.loads(ln)
                    except Exception:
                        continue
                    st, node = r.get("state", st), r.get("node") or node
            info[(b, jid)] = (arm, st, node)
            if st == "running" and node:
                nodes.add(node.split(".")[0])
    return info, nodes



# Free-space history, so risk can be judged in TIME without an expensive du.
AVAIL_HIST = _os.path.expanduser("~/.badist_scratch_avail.json")


def _avail_hist():
    try:
        return _json.load(open(AVAIL_HIST))
    except Exception:
        return {}


def _record_avail(host, avail):
    d = _avail_hist()
    d[host] = [_time.time(), avail]
    try:
        _json.dump(d, open(AVAIL_HIST, "w"))
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--low-gb", type=int, default=LOW_GB)

    ap.add_argument("--low-hours", type=float, default=24.0,

                   help="flag a host projected to fill within this many hours, whatever its free bytes")
    ap.add_argument("--hosts", help="comma-separated override")
    a = ap.parse_args()

    info, nodes = ledger()
    hosts = a.hosts.split(",") if a.hosts else sorted(nodes)
    if not hosts:
        print("  no nodes with running work")
        return 0

    def rescue_exposed(h, cache):
        """Deliver a finished result out of an at-risk node BEFORE packaging can lose it.

        Packaging is the last step of a job, so on a full disk the simulation completes and then
        the tar fails: the transcript exists on the node, intact, and is thrown away. Copying it
        straight out turns a guaranteed loss into a delivered result. Safe to do while the job is
        still running -- reading the file changes nothing, and the canonical path is only written
        once the copy is verified complete."""
        saved = 0
        listing = sh(h, 'for d in %s/*/*/; do [ -f "$d/transcript" ] || continue; '
                        'grep -aqm1 "execution took" "$d/transcript" 2>/dev/null && echo "$d"; done'
                        % cache, timeout=240)
        for d in (listing or "").splitlines():
            m = re.search(r"/run/([^/]+)/(\d+)/?$", d.strip())
            if not m:
                continue
            arm, st, _ = info.get((m.group(1), m.group(2)), ("", "", None))
            if not re.match(r"^fp(16|32)_", arm or ""):
                continue
            t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
            try:
                if DONE in open(t, "rb").read():
                    continue                      # already delivered
            except Exception:
                pass
            print("      rescuing %s off the full disk before packaging loses it" % arm)
            if a.dry_run:
                continue
            os.makedirs(os.path.dirname(t), exist_ok=True)
            with open(t + ".sg", "wb") as fh:
                r = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", h,
                                    "cat %s/transcript" % d.strip()], stdout=fh, timeout=900)
            if r.returncode == 0 and DONE in open(t + ".sg", "rb").read():
                os.replace(t + ".sg", t); saved += 1
            else:
                os.path.exists(t + ".sg") and os.remove(t + ".sg")
                print("      copy incomplete -- left in place")
        return saved

    # A host whose disk is full of OTHER people's data, with nothing of ours left to reclaim, is a
    # state we cannot act on. Re-announcing it every cycle is how a reader learns to skim past this
    # loop -- and then misses the cycle where the free space actually collapses. So: announce once
    # per (host, at-risk arm set), and again only if free space has HALVED since that announcement.
    # State in ~/.badist_scratch_warned.json so it survives the per-cycle process restart.
    WARNED = _os.path.expanduser("~/.badist_scratch_warned.json")

    def _warn_state():
        try:
            return _json.load(open(WARNED))
        except Exception:
            return {}

    def warn_exposed(h, free_gb=None):
        at_risk = sorted({arm for (b, j), (arm, st, node) in info.items()
                          if st == "running" and (node or "").split(".")[0] == h
                          and re.match(r"^fp(16|32)_", arm or "")})
        st_all = _warn_state()
        key = h + "|" + ",".join(at_risk)
        prev = st_all.get(key)
        worse = (prev is not None and free_gb is not None
                 and isinstance(prev, (int, float)) and free_gb <= prev / 2.0)
        if prev is None or worse:
            print("      STILL BELOW THRESHOLD -- not ours to free (other users hold the disk)"
                  + ("  [free HALVED since last notice]" if worse else ""))
            if at_risk:
                print("      %d running arm(s) here will lose their results to packaging: %s"
                      % (len(at_risk), ", ".join(at_risk[:6])))
            st_all[key] = free_gb if free_gb is not None else 0
            try:
                _json.dump(st_all, open(WARNED, "w"))
            except OSError:
                pass
        return at_risk

    freed_hosts = 0
    rescued = 0
    exposed = {}
    for h in hosts:
        # resolve this host's cache dir, then measure the filesystem it actually lives on
        out = sh(h, 'd=$(ls -d %s 2>/dev/null | head -1); [ -n "$d" ] || exit 1; '
                    'echo "$d"; df -BG --output=avail "$d" 2>/dev/null | tail -1' % CACHE_GLOB)
        if not out or len(out.split()) < 2:
            continue
        cache = out.split()[0]
        try:
            avail = int(re.sub(r"[^0-9]", "", out.split()[-1]) or -1)
        except ValueError:
            continue

        # Judge risk in TIME as well as in bytes. Free space alone ranks the wrong host: on
        # 2026-08-26 badile35 had 41 GB free against larain12's 22 GB and so was never examined --
        # but badile35 was filling at 3.3 GiB/h and larain12 at 1.1, so badile35 was 12 h from full
        # and larain12 was 21 h. The host that looked safer was the one about to die.
        #
        # The rate comes from the PREVIOUS run's free-space sample, not from du. A first attempt
        # summed `du -sb` over every run dir; that is minutes per host on 100 GB dirs, so the ssh
        # timed out on all 29 hosts and the guard printed "0 nodes still at risk" while doing
        # nothing at all. A check that degrades into SILENCE is worse than no check, because the
        # silence reads as all-clear. df is one syscall and costs nothing.
        hours_left = None
        prev = _avail_hist().get(h)
        if prev:
            p_ts, p_av = prev
            dt = (_time.time() - p_ts) / 3600.0
            if 0.2 < dt < 12 and p_av > avail:
                rate = (p_av - avail) / dt              # GB/h
                if rate > 0.01:
                    hours_left = avail / rate
        _record_avail(h, avail)

        at_risk = (0 <= avail < a.low_gb) or (hours_left is not None
                                              and hours_left < a.low_hours)
        if avail < 0 or not at_risk:
            continue
        print("  %-12s %s has %d GB free%s -- packaging is at risk"
              % (h, cache, avail,
                 "" if hours_left is None else ", filling -> full in %.0f h" % hours_left))

        # LIVE-PROCESS GUARD -- match on /proc/<pid>/cwd, NOT on the command line.
        # This was `pgrep -u $USER -f "$d"`, which is a NO-OP for the simulators we run: a run
        # directory NEVER appears in vsim's argv (badist chdir()s into it), so the guard reported
        # "none" for every directory including live ones. On 2026-08-23 it deleted the run dir of a
        # LIVE vsimk on badile44 (pid 3373011, 9h42m in, 14.9 GB RSS) -- the exact outcome guard 1
        # exists to prevent. The same mistake had already been found and fixed in the kill scripts;
        # it was never carried across to here.
        listing = sh(h, 'live=$(for q in $(ps -u %s -o pid=); do c=$(readlink /proc/$q/cwd '
                        '2>/dev/null); [ -n "$c" ] && echo "${c%% (deleted)}"; done | sort -u); '
                        'for d in %s/*/*/; do [ -d "$d" ] || continue; dd=${d%%/}; '
                        'if printf "%%s\\n" "$live" | grep -Fxq "$dd"; then p=live; else p=none; fi; '
                        'f=no; grep -aqm1 "execution took" "$d/transcript" 2>/dev/null && f=yes; '
                        'echo "$dd/|$p|$f"; done' % (USER, cache), timeout=240)
        if not listing:
            print("      (nothing of ours here to reclaim)")
            continue
        victims = []
        for ln in listing.splitlines():
            p = ln.strip().split("|")
            if len(p) != 3:
                continue
            d, pid, fin = p[0], p[1], p[2] == "yes"
            m = re.search(r"/run/([^/]+)/(\d+)/?$", d)
            if not m:
                continue
            arm, st, _ = info.get((m.group(1), m.group(2)), ("", "queued", None))
            # ONLY the 8x8 campaign. The same scratch dir holds other campaigns (bp-revive,
            # reuse32, teranoc/qpilot) whose arms are named differently and whose results are
            # delivered elsewhere -- salvaging those into hardware/s8_<arm>/ would file them under
            # the wrong campaign, and reclaiming their directories would destroy work this script
            # knows nothing about.
            if not re.match(r"^fp(16|32)_", arm or ""):
                continue
            if pid != "none":
                continue                       # a live process owns this directory
            if st in ("running", "queued"):
                continue                       # badist still expects this job to deliver
            if fin and arm:
                t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
                delivered = False
                try:
                    delivered = DONE in open(t, "rb").read()
                except Exception:
                    pass
                if not delivered:
                    print("      salvaging %s before reclaiming its directory" % arm)
                    if not a.dry_run:
                        os.makedirs(os.path.dirname(t), exist_ok=True)
                        with open(t + ".sg", "wb") as fh:
                            r = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", h,
                                                "cat %s/transcript" % d], stdout=fh, timeout=900)
                        if r.returncode == 0 and DONE in open(t + ".sg", "rb").read():
                            os.replace(t + ".sg", t)
                        else:
                            os.path.exists(t + ".sg") and os.remove(t + ".sg")
                            print("      salvage incomplete -- KEEPING %s" % d)
                            continue
            victims.append(d)
        if not victims:
            print("      nothing safe to reclaim (all dirs live or still owed to badist)")
            exposed[h] = warn_exposed(h, avail)
            rescued += rescue_exposed(h, cache)
            continue
        print("      reclaiming %d spent run dir(s)" % len(victims))
        if a.dry_run:
            continue
        sh(h, "rm -rf %s" % " ".join("'%s'" % v for v in victims), timeout=600)
        after = sh(h, 'df -BG --output=avail "%s" 2>/dev/null | tail -1' % cache)
        now_gb = re.sub(r"[^0-9]", "", (after or "").strip())
        print("      %s GB free now" % (now_gb or "?"))
        freed_hosts += 1
        # Our leftovers are often a small share of a shared disk -- reclaiming them all can still
        # leave the node full. Say so explicitly and name what is exposed: an arm that finishes
        # here delivers NOTHING, because packaging is the last step and it fails on ENOSPC.
        if now_gb and int(now_gb) < a.low_gb:
            exposed[h] = warn_exposed(h, int(now_gb))
            rescued += rescue_exposed(h, cache)
    n_arms = sum(len(v) for v in exposed.values())
    print("  checked %d node(s), reclaimed space on %d, %d node(s) still at risk (%d arm(s) exposed)"
          % (len(hosts), freed_hosts, len(exposed), n_arms))
    if rescued:
        print("  rescued %d finished result(s) off at-risk disks" % rescued)
    return 0


if __name__ == "__main__":
    sys.exit(main())
