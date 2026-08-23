#!/bin/bash
# Submit Questa arms ONE AT A TIME, spaced apart.
#
# Every Questa arm opens the same 17 GB work library over NFS. badist starts up to --max-parallel
# jobs at once, so max-parallel IS the simultaneous-start count, and simultaneous starts contend at
# design load: the job dies after ~17 min of vopt with "Error loading design", recorded as rc 12
# with "Errors: 0, Warnings: 0". Measured: 5 at once lost 2; 4 at once lost ALL FOUR, every one at
# wall=1003s.
#
# One arm per batch, GAP seconds apart, gives full concurrency across the fleet with no shared
# start-up burst. Usage: stagger_submit.sh <arms-file> <name> [gap_s]
set -u
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
ARMS=${1:?arms file}; NAME=${2:?batch name}; GAP=${3:-240}
cd "$R" || exit 1
n=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  arm=${line%% *}
  tmp=$(mktemp /tmp/claude-620771/stagger_XXXX.txt)
  printf '%s\n' "$line" > "$tmp"
  timeout 300 python3 scripts/badist/teranoc_fleet.py submit \
    --arms "$tmp" --backend questa --run-prefix s8 --name "$NAME" \
    --max-parallel 1 --mem-gb 18 --est-runtime-s 90000 --timeout-s 172800 \
    --reserve-licenses 10 --force >/dev/null 2>&1 &
  n=$((n+1))
  echo "STAGGER queued $arm ($n)"
  sleep "$GAP"
done < "$ARMS"
echo "STAGGER submitted $n arm(s), ${GAP}s apart"
