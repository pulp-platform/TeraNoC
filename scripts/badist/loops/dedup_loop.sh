#!/bin/bash
# Clear duplicate running copies every 15 min. Frequent because a duplicate corrupts a result
# (both copies write the same hardware/s8_<arm>/ dir), and s8q keeps dispatching jobs that were
# cancelled hours ago -- badist cancel on a never-started job writes no record and does not
# reliably stop a later dispatch, so duplicates cannot be prevented at the source from here.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
LOG=/tmp/claude-620771/dedup_loop.log
while true; do
  OUT=$(cd "$R" && timeout 900 python3 scripts/badist/kill_duplicate_arms.py 2>&1)
  # ONE summary line, never one per duplicate. The rescue loop was auto-stopped for output volume
  # after printing a line per arm, and its loss went unnoticed; dedup bursts the same way whenever
  # a retired batch dispatches a wave. Detail goes to the log.
  printf '%s\n--- %s ---\n' "$OUT" "$(date '+%F %T')" >> "$LOG"
  N=$(printf '%s' "$OUT" | grep -cE '^ *DUP ')
  ERR=$(printf '%s' "$OUT" | grep -cE 'Traceback|rror')
  [ "$N" -gt 0 ] && echo "DEDUP killed ${N} duplicate copy(ies) -- detail in $LOG"
  [ "$ERR" -gt 0 ] && echo "DEDUP ERROR -- see $LOG"
  sleep 900
done
