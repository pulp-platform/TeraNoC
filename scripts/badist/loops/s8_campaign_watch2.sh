#!/bin/bash
# Campaign watcher, batch-agnostic (keys on hardware/s8_<arm>/ on disk, so new waves are picked up
# without being told the batch ids -- badist status/fetch are single-batch and a pinned id goes
# stale on the next dispatch).
# v2: v1 emitted on any change to the counts line, i.e. once per completion -- 248 interruptions
# for a campaign whose interesting events are far rarer. Now:
#   * problem arms (failed / WEDGED / no-probe)  -> ALWAYS, immediately
#   * routine progress                            -> every 10th completion, or hourly
# Fetch still runs every pass, so delivery is unaffected by the reporting cadence.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
CS="$R/scripts/badist/campaign_status.py"
P=/tmp/claude-620771/.s8c_done; Q=/tmp/claude-620771/.s8c_prob; A=/tmp/claude-620771/.s8c_asked
while true; do
  OUT=$(cd "$R" && timeout 900 python3 "$CS" --fetch 2>&1)
  LINE=$(printf '%s\n' "$OUT" | grep -m1 '^  done ')
  DONE=$(printf '%s' "$LINE" | grep -oE 'done [0-9]+' | grep -oE '[0-9]+'); DONE=${DONE:-0}
  PROB=$(printf '%s\n' "$OUT" | grep -A99 -E '^  (WEDGED|NO PROBE|FAILED)' | grep -E '^    fp(16|32)_' | tr -s ' ' | paste -sd' ' -)
  OLD=$(cat "$P" 2>/dev/null || echo -1); OPROB=$(cat "$Q" 2>/dev/null); ASKED=$(cat "$A" 2>/dev/null || echo 0)
  NOW=$(date +%s); SAY=""
  # a problem arm is always worth a line, and a CHANGED problem set always worth repeating
  [ -n "$PROB" ] && [ "$PROB" != "$OPROB" ] && SAY="problem"
  # routine: every 10th completion, or hourly if anything moved at all
  [ -z "$SAY" ] && [ "$OLD" -ge 0 ] && [ $((DONE/10)) -ne $((OLD/10)) ] && SAY="milestone"
  [ -z "$SAY" ] && [ "$DONE" -ne "$OLD" ] && [ $((NOW-ASKED)) -ge 3600 ] && SAY="hourly"
  [ "$OLD" -lt 0 ] && SAY="first"
  if [ -n "$SAY" ]; then
    echo "S8 ${LINE# }"
    [ -n "$PROB" ] && echo "S8 PROBLEM ARMS:$PROB"
    echo "$DONE" > "$P"; echo "$PROB" > "$Q"; echo "$NOW" > "$A"
  fi
  sleep 300
done
