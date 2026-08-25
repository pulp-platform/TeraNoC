#!/usr/bin/env python3
"""Write-once vault for completed transcripts, and a self-healing restore.

WHY THIS EXISTS. `hardware/s8_<arm>/transcript` is the system of record for the 8x8 campaign,
but it is not owned by anything: `fetch` unpacks over it, a killed job's gather lands on it,
and salvage paths copy onto it. On 2026-08-25 three separate mechanisms overwrote completed
results with partial ones, twice in one morning. Guarding each writer is necessary but has
turned out not to be sufficient -- each guard has its own window, and a guard that must be
correct in every caller eventually is not.

So stop relying on the live file being intact. The moment a transcript is observed complete it
is compressed into the vault, which nothing else writes. `restore()` then repairs any live file
that has lost its banner, from local disk, in seconds -- no node archives, no ledger archaeology.

  vault    -- add every complete transcript not already vaulted
  restore  -- repair every incomplete live transcript that the vault can cover
  status   -- counts

Both are idempotent and safe to run from a loop.
"""
import glob, os, subprocess, sys

ROOT  = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
VAULT = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/transcript_vault")
MARK  = b"execution took"


def complete(path, tail=64 << 20):
    """Banner sits ~1 MB from EOF even on a 376 MB transcript; a full read is too slow to keep."""
    try:
        sz = os.path.getsize(path)
        with open(path, "rb") as f:
            if sz > tail:
                f.seek(sz - tail)
            return MARK in f.read()
    except OSError:
        return False


def vault_path(arm):
    return os.path.join(VAULT, arm + ".transcript.zst")


def arms():
    for d in sorted(glob.glob(os.path.join(ROOT, "hardware", "s8_*"))):
        yield os.path.basename(d)[3:], os.path.join(d, "transcript")


def do_vault():
    os.makedirs(VAULT, exist_ok=True)
    added = skipped = 0
    for arm, live in arms():
        if not os.path.exists(live) or not complete(live):
            continue
        v = vault_path(arm)
        # Vault the LARGER copy. A re-delivery of the same run can differ in length; the longer
        # complete transcript carries strictly more probe output.
        #
        # Record the SOURCE size in a sidecar rather than parsing `zstd -l`: that parse silently
        # yielded 0 for every entry, so the first loop pass re-compressed all 138 transcripts
        # instead of skipping them. A freshness check that always says "stale" is a busy loop
        # wearing the disk, and it hides genuine re-vaults in the noise.
        idx = v + ".size"
        if os.path.exists(v):
            try:
                have = int(open(idx).read().strip())
            except Exception:
                have = 0
            if have >= os.path.getsize(live):
                skipped += 1
                continue
        tmp = v + ".part"
        try:
            with open(live, "rb") as fin, open(tmp, "wb") as fout:
                subprocess.run(["zstd", "-q", "-3", "-T2", "-c"], stdin=fin, stdout=fout,
                               check=True, timeout=1800)
            os.replace(tmp, v)                      # atomic: a killed vault never leaves a stub
            with open(idx, "w") as fh:
                fh.write(str(os.path.getsize(live)))
            added += 1
        except Exception as e:
            print("  VAULT FAIL %-24s %s" % (arm, e))
            try:
                os.remove(tmp)
            except OSError:
                pass
    print("  vaulted %d new, %d already current" % (added, skipped))


def do_restore():
    fixed = miss = 0
    for arm, live in arms():
        if os.path.exists(live) and complete(live):
            continue
        v = vault_path(arm)
        if not os.path.exists(v):
            # Only arms we ever completed matter; a never-run arm has no live file either.
            if os.path.exists(live):
                miss += 1
            continue
        tmp = live + ".vrestore"
        try:
            with open(tmp, "wb") as fout:
                subprocess.run(["zstd", "-dcq", v], stdout=fout, check=True, timeout=1800)
            if not complete(tmp):
                os.remove(tmp)
                print("  VAULT COPY INCOMPLETE %s -- left the live file alone" % arm)
                continue
            os.replace(tmp, live)
            print("  RESTORED %-24s %.1f MB from the vault" % (arm, os.path.getsize(live) / 1e6))
            fixed += 1
        except Exception as e:
            print("  RESTORE FAIL %-22s %s" % (arm, e))
            try:
                os.remove(tmp)
            except OSError:
                pass
    print("  restored %d, %d incomplete with no vault copy" % (fixed, miss))


def do_status():
    n = sum(1 for _ in glob.glob(os.path.join(VAULT, "*.transcript.zst")))
    live = sum(1 for a, p in arms() if os.path.exists(p) and complete(p))
    tot = sum(os.path.getsize(f) for f in glob.glob(os.path.join(VAULT, "*.zst")))
    print("  vault %d arms, %.2f GB   live complete %d" % (n, tot / 1e9, live))


cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
{"vault": do_vault, "restore": do_restore, "status": do_status}.get(cmd, do_status)()
