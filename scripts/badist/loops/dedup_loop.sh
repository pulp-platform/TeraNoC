#!/bin/bash
# Clear duplicate running copies every 15 min. Frequent because a duplicate corrupts a result
# (both copies write the same hardware/s8_<arm>/ dir), and s8q keeps dispatching jobs that were
# cancelled hours ago -- badist cancel on a never-started job writes no record and does not
# reliably stop a later dispatch, so duplicates cannot be prevented at the source from here.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  OUT=$(cd "$R" && timeout 900 python3 scripts/badist/kill_duplicate_arms.py 2>&1)
  echo "$OUT" | grep -E '^\s*(DUP|killed [1-9])' | while IFS= read -r l; do echo "DEDUP $l"; done
  sleep 900
done
