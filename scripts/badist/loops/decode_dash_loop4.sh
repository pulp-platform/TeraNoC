#!/bin/bash
# Keep the decode dashboard current: FETCH delivered results, refresh live progress from the
# nodes, re-collect, regenerate. Signals REPUBLISH only when the numbers actually change, so the
# channel stays worth reading.
#
# The fetch step is the reason this file exists. loop2 had none: refresh_decode_progress.py reads
# the node's LIVE scratch copy and collect_decode_results.py reads LOCAL run dirs, so a finished
# arm -- whose result is a tarball in badist-results and whose scratch copy the guard reaps --
# was visible to neither. dec8_32x128x16384 sat `done` on the fleet for over an hour while the
# table still said `running`. A monitor that cannot see completion is worse than no monitor.
# loop4 (2026-08-26): the signature globbed only `hardware/dec_*` -- the run-1 dirs. Run 2 lands
# in `w8k_*` and run 3 in `fix_*`, so neither could ever change the signature and neither would
# ever have signalled REPUBLISH. Same failure shape as loop2's missing fetch: the monitor keeps
# running and says nothing, which reads as "no new results" rather than "I cannot see them".
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
SIG=/tmp/claude-620771/.decode_sig
while true; do
  # decode batches, newest first, straight from the ledger -- no hardcoded batch list
  BATCHES=$(cd "$R" && timeout 120 python3 -c "
import glob, json, os
STATE = os.path.expanduser('~/badist/state')
import re
ARM = re.compile(r'^(dec\d|d\df32|dec)[A-Za-z0-9]*_\d+x\d+x\d+' + chr(36))
out = []
for d in sorted((x for x in glob.glob(os.path.join(STATE,'*')) if os.path.isdir(x)),
                key=os.path.getmtime, reverse=True):
    jf = os.path.join(d,'jobs.json')
    if not os.path.exists(jf): continue
    try: jobs = json.load(open(jf))
    except Exception: continue
    if any(ARM.match((j.get('meta') or {}).get('arm','')) for j in jobs):
        out.append(os.path.basename(d))
print('\n'.join(out[:12]))" 2>/dev/null)
  # zsh/bash-safe: read line by line, never rely on word splitting an unquoted var
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    (cd "$R" && timeout 600 scripts/badist/teranoc_fleet.py fetch "$b" >/dev/null 2>&1)
  done <<< "$BATCHES"

  (cd "$R" && timeout 400 python3 scripts/refresh_decode_progress.py >/dev/null 2>&1)
  (cd "$R" && timeout 300 python3 scripts/collect_decode_results.py >/dev/null 2>&1)
  # per-group mesh + progress data; only delivered arms contribute, so this is cheap
  (cd "$R" && timeout 600 python3 scripts/extract_decode_group_util.py >/dev/null 2>&1)
  OUT=$(cd "$R" && timeout 300 python3 scripts/gen_decode_dashboard.py 2>&1 | tail -1)
  # signature on DELIVERED results only -- live cum-util drifts every pass and would signal forever
  NEW=$(cd "$R" && python3 -c "
import glob,os,re
s=[]
for d in (sorted(glob.glob('hardware/dec_*'))+sorted(glob.glob('hardware/w8k_*'))+sorted(glob.glob('hardware/fix_*'))):
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
