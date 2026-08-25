#!/usr/bin/env python3
"""Find batches whose results were delivered but never fetched, and fetch them.

WHY: every fetch loop in this campaign selects batches by ARM NAME -- campaign_status.our_batches
keeps a batch only if some arm starts with "fp16_"/"fp32_". A probe batch named outside that
convention is therefore invisible to every loop, and its results sit in
/usr/scratch/.../badist-results/<batch>/<job>.tar.zst forever while the watch that was waiting on
them times out. That happened to p96gap-20260823-220010-6ebb: two arms named `16_512x512x96` and
`16_512x512x64` finished 2026-08-24 04:35 and were still unfetched 33 h later, and the numbers
turned out to be the deliberate confirmation of the 64 B burst floor.

The fix cannot be another name filter. Select on STATE and EVIDENCE instead: a job the ledger
marks `done`, whose run_dir holds no complete transcript, and whose result archive exists.

  usage: find_orphan_results.py [--fetch]
"""
import glob, json, os, subprocess, sys

ROOT    = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE   = os.path.expanduser("~/badist/state")
RESULTS = "/usr/scratch/fenga1/zexifu/badist-results"
CLIENT  = os.path.join(ROOT, "scripts/badist/teranoc_fleet.py")


def complete(path, tail=64 << 20):
    try:
        sz = os.path.getsize(path)
        with open(path, "rb") as f:
            if sz > tail:
                f.seek(sz - tail)
            return b"execution took" in f.read()
    except OSError:
        return False


def main():
    do_fetch = "--fetch" in sys.argv
    orphans = {}
    for d in sorted(x for x in glob.glob(os.path.join(STATE, "*")) if os.path.isdir(x)):
        batch = os.path.basename(d)
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        for j in jobs:
            jid = j["job_id"]
            meta = j.get("meta") or {}
            rd = meta.get("run_dir")
            if not rd:
                continue
            f = os.path.join(d, "jobs", jid + ".jsonl")
            st = None
            try:
                for ln in open(f):
                    try:
                        st = json.loads(ln).get("state")
                    except Exception:
                        pass
            except OSError:
                continue
            if st != "done":
                continue
            if complete(os.path.join(rd, "transcript")):
                continue
            tar = os.path.join(RESULTS, batch, jid + ".tar.zst")
            if not os.path.exists(tar):
                continue          # nothing to recover; not an orphan, just gone
            orphans.setdefault(batch, []).append((jid, meta.get("arm", "?"), rd))

    if not orphans:
        print("  no orphaned results")
        return
    n = sum(len(v) for v in orphans.values())
    print("  %d delivered-but-unfetched result(s) in %d batch(es):" % (n, len(orphans)))
    for b, v in sorted(orphans.items()):
        for jid, arm, rd in v:
            print("    %-34s %-5s %-24s -> %s" % (b[:34], jid, arm, os.path.basename(rd)))
    if not do_fetch:
        print("  (run with --fetch to retrieve them)")
        return
    for b in sorted(orphans):
        r = subprocess.run(["timeout", "600", CLIENT, "fetch", b, "--quiet"],
                           capture_output=True, text=True, cwd=ROOT)
        print("  fetch %-34s rc=%d %s" % (b[:34], r.returncode,
                                          r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""))
    # HEAL WHAT THIS DISTURBED. Fetching an old batch re-extracts its tarballs, and a job the
    # ledger marks `done` whose archive holds a PARTIAL transcript slips past the client's
    # dest_for rule -- that rule only blocks non-`done` jobs from overwriting a complete file.
    # Measured: a sweep over 15 stale batches cost 8 completed sweep transcripts, all of which
    # the vault restored in seconds. A rare manual operation should clean up after itself rather
    # than depend on someone noticing the integrity alarm.
    v = os.path.join(ROOT, "scripts/badist/transcript_vault.py")
    if os.path.exists(v):
        out = subprocess.run(["timeout", "900", "python3", v, "restore"],
                             capture_output=True, text=True, cwd=ROOT).stdout
        for ln in out.splitlines():
            if "RESTORED" in ln or "restored" in ln:
                print("  vault %s" % ln.strip())


main()
