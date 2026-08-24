#!/bin/bash
# Refresh run_progress.json and the dashboard, and signal REPUBLISH **only when something changed**.
#
# v1 emitted every cycle regardless. An unchanged "90 running, median 34%" repeated every 45 min is
# noise, and noise is how a real event gets skimmed past -- the same reason scratch_guard.py now
# announces an unactionable state once. Key on (running count, median, measurement count): those are
# what would make a reader look. NEW FILE, not an edit: bash re-reads a running script by byte
# offset, so patching one in place corrupts it mid-flight.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
prev=""
while true; do
  (cd "$R" && timeout 2400 python3 scripts/gen_run_progress.py >/dev/null 2>&1)
  (cd "$R" && timeout 300 python3 scripts/gen_8x8_dashboard.py >/dev/null 2>&1)
  cur=$(cd "$R" && python3 -c "
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
print('%d running, median progress %d%%, %d measurements + %d livelock'%(len(r),med,m,l))
" 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then
    echo "S8PROGRESS $cur -- REPUBLISH"
    prev="$cur"
  fi
  sleep 2700
done
