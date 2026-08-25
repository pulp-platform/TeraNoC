#!/bin/bash
# Clear redundant running copies every 15 min. Two distinct kinds, both of which cost a licence
# seat for hours and can only make a result worse:
#
#   * DUPLICATES -- the same arm running in two batches at once. Both deliver to the same
#     hardware/s8_<arm>/ dir, so leaving them racing can interleave two simulators' output into
#     one result file.
#   * ALREADY DELIVERED -- an arm re-dispatched after its result landed, usually because a
#     top-up loop worked from a list built before the delivery. Nothing it produces can be
#     better than what is already on disk.
#
# Neither can be prevented at the source from here: `badist cancel` on a never-started job
# writes no record and does not reliably stop a later dispatch.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  OUT=$(cd "$R" && timeout 900 python3 scripts/badist/kill_duplicate_arms.py 2>&1)
  echo "$OUT" | grep -E '^\s*(DUP|NODE DOWN|FOREIGN|killed [1-9])' | while IFS= read -r l; do echo "DEDUP $l"; done
  # Runs second: a duplicate pair should be resolved down to one copy before asking whether
  # that copy is redundant, otherwise both get killed in the same pass on the same evidence.
  OUT2=$(cd "$R" && timeout 1800 python3 scripts/badist/kill_delivered_arms.py 2>&1)
  echo "$OUT2" | grep -E '^\s*(DONE|UNPROVEN|FOREIGN|killed [1-9])' | while IFS= read -r l; do echo "DEDUP $l"; done
  sleep 900
done
