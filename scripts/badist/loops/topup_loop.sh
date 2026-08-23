#!/bin/bash
# Keep both simulator pools working up to their reserve lines (Questa 10 free, VCS 5 free).
# No --allow-requeue: with the campaign fully dispatched a requeue only creates a duplicate that
# dedup must kill, and the duplicate holds a scarce seat until it does. Re-add that flag only if
# arms are stuck behind a batch's own --max-parallel WHILE a pool sits above its reserve line.
cd /usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  for be in questa vcs; do
    out=$(timeout 600 python3 scripts/badist/sim_topup.py --backend $be --batch 20 2>&1)
    echo "$out" | grep -E "moving [0-9]+ queued|rror" | sed "s/^/TOPUP /"
  done
  sleep 600
done
