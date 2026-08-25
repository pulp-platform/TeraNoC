#!/bin/bash
# Keep the decode dashboard current: refresh live progress from the nodes, re-collect delivered
# results, regenerate. Signals REPUBLISH only when the numbers actually change, so the channel
# stays worth reading.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
SIG=/tmp/claude-620771/.decode_sig
while true; do
  (cd "$R" && timeout 400 python3 scripts/refresh_decode_progress.py >/dev/null 2>&1)
  (cd "$R" && timeout 300 python3 scripts/collect_decode_results.py >/dev/null 2>&1)
  OUT=$(cd "$R" && timeout 300 python3 scripts/gen_decode_dashboard.py 2>&1 | tail -1)
  # signature on DELIVERED results only -- live cum-util drifts every pass and would signal forever
  NEW=$(cd "$R" && python3 -c "
import glob,os,re
s=[]
for d in sorted(glob.glob('hardware/dec_*')):
    try: b=open(os.path.join(d,'transcript'),'rb').read()
    except OSError: continue
    m=re.search(rb'execution took (\d+)',b)
    if m: s.append(os.path.basename(d)+':'+m.group(1).decode())
print('|'.join(s))" 2>/dev/null)
  OLD=$(cat "$SIG" 2>/dev/null)
  if [ "$NEW" != "$OLD" ] && [ -n "$NEW" ]; then
    echo "DECODE $OUT -- results changed, REPUBLISH"
    echo "$NEW" > "$SIG"
  fi
  sleep 900
done
