#!/bin/bash
# Poll for failed campaign arms and resubmit them, per the standing instruction to always
# resubmit failures. Emits ONLY when it acts or when an arm exhausts its attempts, so a healthy
# campaign stays silent -- this loop must not become another per-tick notifier.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  OUT=$(cd "$R" && timeout 300 python3 scripts/badist/auto_resubmit.py 2>&1)
  echo "$OUT" | grep -E 'RESUBMIT|SKIP|batch |rror' | while IFS= read -r l; do echo "AUTORESUB $l"; done
  sleep 600
done
