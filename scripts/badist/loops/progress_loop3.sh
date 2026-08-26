#!/bin/bash
# Refresh run_progress.json and the dashboard, and signal REPUBLISH **only when something changed**.
#
# v2 keyed on (running, median progress, measurements, livelock). Median progress DRIFTS -- every
# running arm advances a little each cycle -- so it re-fired on 33% -> 34% -> 35% with no new
# measurement, which is the same "noise every 45 min" v2 was written to stop. A reader who is
# paged three times for nothing stops reading the fourth.
#
# Key on what would make a reader LOOK: measurement count, livelock count, running count. Median is
# still reported in the message, it just no longer triggers it. NEW FILE, not an edit: bash re-reads
# a running script by byte offset, so patching one in place corrupts it mid-flight.
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
m=l=0
try:
    for row in list(csv.reader(open('docs/benchmarks/8x8_scaleup/results.tsv'),delimiter='\t'))[1:]:
        if len(row)>9:
            if row[9]=='livelock': l+=1
            else: m+=1
except Exception: pass
# field 1 = trigger key (no median); the rest is the human message
print('%d/%d/%d %d running, median progress %d%%, %d measurements + %d livelock'
      % (len(r),m,l,len(r),med,m,l))
" 2>/dev/null)"
  if [ -n "$key" ] && [ "$key" != "$prev" ]; then
    echo "S8PROGRESS $msg -- REPUBLISH"
    prev="$key"
  fi
  sleep 2700
done
