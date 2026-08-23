#!/bin/bash
# Requeue arms that nothing can dispatch. A batch's queued jobs move only while its submit
# controller lives; kill the controller and they are invisible -- badist lists them, every status
# view calls them "pending", and they never run.
#
# COLD START: fetch BEFORE the first rescue, and skip that first pass.
# A restart leaves delivered-but-unfetched results on the fleet, so the rescuer's view of "which
# arms are done" is stale, and it requeues completed work. That happened on 2026-08-23: six
# already-delivered arms were resubmitted and four started before being killed. The tell is that
# the transcripts' ctime was ~2 min old while their mtime was hours old -- tar preserves mtime on
# extraction, so mtime cannot be used to reason about when a result arrived.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
cd "$R" || exit 1

# one fetch pass, then a dry run whose output is reported but never acted on
timeout 900 python3 scripts/badist/campaign_status.py --fetch >/dev/null 2>&1
OUT=$(timeout 600 python3 scripts/badist/rescue_orphans.py --min-idle-min 90 --dry-run 2>&1)
echo "$OUT" | grep -E 'ORPHAN|rescued' | while IFS= read -r l; do echo "RESCUE (cold start, not acting) $l"; done
sleep 900

while true; do
  OUT=$(cd "$R" && timeout 600 python3 scripts/badist/rescue_orphans.py --min-idle-min 90 2>&1)
  echo "$OUT" | grep -E 'ORPHAN|rescued|SKIP|batch |rror' | while IFS= read -r l; do echo "RESCUE $l"; done
  sleep 1800
done
