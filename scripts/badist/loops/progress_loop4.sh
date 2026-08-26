#!/bin/bash
# Refresh run_progress.json and the dashboard, and signal REPUBLISH only when something changed.
#
# v4: count the `deadlock` state separately. v3 bucketed every non-livelock row as a MEASUREMENT,
# so the 20 arms retired on 2026-08-26 as quiescent deadlocks were reported as results -- "175
# measurements" when 153 were real. Any new terminal state has to be taught to every consumer of
# results.tsv; this is one of four that needed it.
#
# The trigger key excludes median progress, which drifts and re-fired the signal every cycle.
# NEW FILE, not an edit: bash re-reads a running script by byte offset.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
prev=""
while true; do
  (cd "$R" && timeout 2400 python3 scripts/gen_run_progress.py >/dev/null 2>&1)
  (cd "$R" && timeout 300 python3 scripts/gen_8x8_dashboard.py >/dev/null 2>&1)
  read -r key msg <<< "$(cd "$R" && python3 -c "
import json,csv,statistics as st
try:
    r=json.load(open('docs/benchmarks/8x8_scaleup/run_progress.json'))['rows']
    med=round(100*st.median([x['progress'] for x in r])) if r else 0
except Exception:
    r,med=[],0
m=l=dl=0
try:
    for row in list(csv.reader(open('docs/benchmarks/8x8_scaleup/results.tsv'),delimiter='\t'))[1:]:
        if len(row)>9:
            if row[9]=='livelock': l+=1
            elif row[9]=='deadlock': dl+=1
            else: m+=1
except Exception: pass
print('%d/%d/%d/%d %d running, median progress %d%%, %d measurements + %d livelock + %d deadlock'
      % (len(r),m,l,dl,len(r),med,m,l,dl))
" 2>/dev/null)"
  if [ -n "$key" ] && [ "$key" != "$prev" ]; then
    echo "S8PROGRESS $msg -- REPUBLISH"
    prev="$key"
  fi
  sleep 2700
done
