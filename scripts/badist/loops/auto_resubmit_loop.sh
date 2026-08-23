#!/bin/bash
# Poll for failed campaign arms and resubmit them, per the standing instruction to always resubmit
# failures.
#
# Emits ONE summary line per cycle, never one per arm. It printed one line per RESUBMIT and burst 16
# events in a single cycle after the 24h cohort expiry; the rescue loop was auto-stopped for exactly
# that and its loss went unnoticed. Losing THIS loop is worse -- failed arms would simply never be
# requeued. Detail goes to the log, not the event stream.
#
# Arms at the retry cap are always named: that is the one case needing a human, and there are never
# many of them.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
LOG=/tmp/claude-620771/auto_resubmit_loop.log
while true; do
  OUT=$(cd "$R" && timeout 300 python3 scripts/badist/auto_resubmit.py 2>&1)
  printf '%s\n--- %s ---\n' "$OUT" "$(date '+%F %T')" >> "$LOG"
  N=$(printf '%s' "$OUT" | grep -cE 'RESUBMIT ')
  ERR=$(printf '%s' "$OUT" | grep -cE 'Traceback|rror')
  CAP=$(printf '%s' "$OUT" | grep -E 'needs a human' | sed 's/^ *//' | tr '\n' ';')
  [ "$N" -gt 0 ] && echo "AUTORESUB resubmitted ${N} failed arm(s) -- detail in $LOG"
  [ -n "$CAP" ] && echo "AUTORESUB at the retry cap: ${CAP}"
  [ "$ERR" -gt 0 ] && echo "AUTORESUB ERROR -- see $LOG"
  sleep 600
done
