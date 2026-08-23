#!/bin/bash
# Dispatch the two P<128 probe arms when a VCS seat actually frees.
#
# Why this exists rather than a long-lived `submit`: the badist controller polls for a seat and
# EXITS if it cannot place anything (observed 2026-08-23 — four polls at 100/100, then exit 0),
# which strands its queue. The 8x8 automation cannot rescue these: both sim_topup.py and
# rescue_orphans.py filter arms to names starting fp16_/fp32_, and these are named 16_<shape> so
# their results land in hardware/run5_16_<shape>/ where the fp16 scraper already parses them.
# So: wait for the seat first, submit second, exit. One line of output when it acts.
set -u
ROOT=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
ARMS=/tmp/claude-620771/arms_pgap.txt
RESERVE=2
cd "$ROOT" || exit 1
for _ in $(seq 1 480); do          # ~40 h at 5 min, then give up rather than linger forever
  out=$(lmutil lmstat -c 8169@lic-synopsys.ethz.ch -f VCS-Base-Runtime-Pkg 2>/dev/null)
  iss=$(sed -n 's/.*Total of \([0-9]*\) licenses\? issued.*/\1/p' <<< "$out" | head -1)
  use=$(sed -n 's/.*Total of \([0-9]*\) licenses\? in use.*/\1/p' <<< "$out" | head -1)
  if [ -n "${iss:-}" ] && [ -n "${use:-}" ]; then
    room=$(( iss - use - RESERVE ))
    if [ "$room" -ge 1 ]; then
      echo "PGAP $room VCS seat(s) free -- submitting the two P<128 probe arms"
      timeout 900 scripts/badist/teranoc_fleet.py submit --arms "$ARMS" \
        --backend vcs --run-prefix run5 --name p96gap \
        --max-parallel 2 --mem-gb 12 --reserve-licenses "$RESERVE" \
        --est-runtime-s 20000 --timeout-s 2592000 --force >/tmp/claude-620771/pgap_submit.log 2>&1
      echo "PGAP submit returned $? -- see /tmp/claude-620771/pgap_submit.log"
      exit 0
    fi
  fi
  sleep 300
done
echo "PGAP gave up after ~40 h without a free VCS seat"
