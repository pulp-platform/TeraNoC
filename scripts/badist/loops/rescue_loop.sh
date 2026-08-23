#!/bin/bash
# Requeue arms that nothing can dispatch. A batch's queued jobs move only while its submit
# controller lives; kill the controller and they are invisible -- badist lists them, every status
# view calls them "pending", and they never run. 64 arms sat like that after a licence sweep took
# out the healer's and resubmitter's controllers as collateral.
# Emits only when it acts, so a healthy campaign stays silent.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  OUT=$(cd "$R" && timeout 600 python3 scripts/badist/rescue_orphans.py --min-idle-min 90 2>&1)
  echo "$OUT" | grep -E 'ORPHAN|rescued|SKIP|batch |rror' | while IFS= read -r l; do echo "RESCUE $l"; done
  sleep 1800
done
