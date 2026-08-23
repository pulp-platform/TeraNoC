#!/bin/bash
# Keep both simulator pools working up to their reserve lines (Questa 10 free, VCS 2 free).
# --batch 60 / 5-min cycle (was 20 / 10-min): sim_topup takes min(batch, room) where
# room = issued - in_use - reserve, so a bigger batch can NEVER cross the reserve line -- it only
# stops the batch size itself being the limit. It was: VCS had 24 seats of room against a batch of
# 20, so 4 seats sat idle each cycle with 54 arms queued.
# No --allow-requeue: with the campaign fully dispatched a requeue only creates a duplicate that
# dedup must kill, and the duplicate holds a scarce seat until it does. Re-add that flag only if
# arms are stuck behind a batch's own --max-parallel WHILE a pool sits above its reserve line.
cd /usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  for be in questa vcs; do
    out=$(timeout 600 python3 scripts/badist/sim_topup.py --backend $be --batch 60 2>&1)
    echo "$out" | grep -E "moving [0-9]+ queued|rror" | sed "s/^/TOPUP /"
  done
  sleep 300
done
