#!/bin/bash
# Requeue arms that nothing can dispatch. A batch's queued jobs move only while its submit
# controller lives; kill the controller and they are invisible -- badist lists them, every status
# view calls them "pending", and they never run. 64 arms sat like that after a licence sweep took
# out the healer's and resubmitter's controllers as collateral.
#
# Emits ONE summary line per cycle, never one line per arm. A rescue of 14 arms printed 15 lines in
# a single burst and the monitor was auto-stopped for output volume -- which silently removed the
# only thing that dispatches stranded arms. Detail goes to the log file, not the event stream.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
LOG=/tmp/claude-620771/rescue_loop.log
while true; do
  OUT=$(cd "$R" && timeout 600 python3 scripts/badist/rescue_orphans.py --min-idle-min 90 2>&1)
  printf '%s\n--- %s ---\n' "$OUT" "$(date '+%F %T')" >> "$LOG"
  N=$(printf '%s' "$OUT" | grep -cE '^ *ORPHAN ')
  S=$(printf '%s' "$OUT" | grep -oE 'rescued [0-9]+ arm' | grep -oE '[0-9]+')
  SK=$(printf '%s' "$OUT" | grep -cE 'needs a human')
  ERR=$(printf '%s' "$OUT" | grep -cE 'Traceback|rror')
  # one line, and only when something happened or broke
  if [ "${S:-0}" -gt 0 ] 2>/dev/null; then
    echo "RESCUE rescued ${S} arm(s) (${N} orphaned, ${SK} at the retry cap) -- detail in $LOG"
  elif [ "$ERR" -gt 0 ]; then
    echo "RESCUE ERROR -- see $LOG"
  fi
  sleep 1800
done
