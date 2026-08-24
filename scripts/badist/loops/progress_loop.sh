#!/bin/bash
# Refresh run_progress.json (the live per-arm progress the dashboard embeds) and regenerate the
# page. SEPARATE from s8_results_loop5.sh on purpose: gen_run_progress.py pulls the full log of
# every running arm, so it is far too heavy for that loop's cadence -- and editing a running bash
# script corrupts it (bash re-reads by byte offset), so this is a new file rather than a patch.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  (cd "$R" && timeout 2400 python3 scripts/gen_run_progress.py >/dev/null 2>&1)
  (cd "$R" && timeout 300 python3 scripts/gen_8x8_dashboard.py >/dev/null 2>&1)
  echo "S8PROGRESS refreshed $(python3 -c "
import json
try:
  d=json.load(open('$R/docs/benchmarks/8x8_scaleup/run_progress.json'))
  rows=d['rows']
  import statistics as st
  print('%d running arms, median progress %d%%'%(len(rows), round(100*st.median([r['progress'] for r in rows])) if rows else 0))
except Exception as e: print('(no data)')" 2>/dev/null) -- REPUBLISH"
  sleep 2700
done
