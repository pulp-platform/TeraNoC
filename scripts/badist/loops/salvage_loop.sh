#!/bin/bash
# Recover results from sims badist stopped tracking, and release their Questa seats.
# Silent unless it recovers something or errors: a 30-min "nothing to do" line would be 48 no-op
# events a day, and a noisy monitor gets auto-stopped, which would silently lose this loop.
cd /usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  out=$(timeout 1500 python3 scripts/badist/salvage_zombies.py 2>&1)
  n=$(printf '%s' "$out" | grep -oE "salvaged [0-9]+" | awk '{print $2}')
  s=$(printf '%s' "$out" | grep -oE "released [0-9]+" | awk '{print $2}')
  if [ "${n:-0}" -gt 0 ] || [ "${s:-0}" -gt 0 ]; then
    printf '%s' "$out" | grep -E "salvage$|-> salvage|releasing seat" | sed 's/^/SALVAGE /'
    echo "SALVAGE recovered ${n:-0} result(s), freed ${s:-0} seat(s)"
    python3 scripts/collect_8x8_results.py >/dev/null 2>&1
    python3 scripts/extract_group_util.py >/dev/null 2>&1
  fi
  printf '%s' "$out" | grep -E "Traceback|ModuleNotFound|No such file" | head -3 | sed 's/^/SALVAGE-ERR /'
  sleep 1800
done
