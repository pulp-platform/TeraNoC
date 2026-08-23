#!/bin/bash
# Autonomous heal loop: find arms that are CERTAINLY dead, kill them, remove their node-local
# scratch, and requeue. Emits only when it acts or refuses, so a healthy campaign is silent.
# Every 30 min -- long enough that a slow loader is never mistaken for a hang.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  OUT=$(cd "$R" && timeout 1500 python3 scripts/badist/heal_stuck_arms.py --min-idle 45 --max-kill 40 2>&1)
  echo "$OUT" | grep -E 'STUCK|healed|REFUSING|SKIP|batch |rror' | while IFS= read -r l; do echo "HEAL $l"; done
  sleep 1800
done
