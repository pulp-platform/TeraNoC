#!/bin/bash
# Node-local disk guard: reclaim our spent run dirs, rescue finished results off an at-risk disk.
# Emits only exposure or action -- the dangerous case is a node we CANNOT free, where finished
# arms are discarded by `tar | zstd` at the end of the job.
cd /usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  out=$(timeout 1500 python3 scripts/badist/scratch_guard.py 2>&1)
  echo "$out" | grep -E "at risk --|STILL BELOW|will lose their results|reclaiming [0-9]+|rescuing |rescued [0-9]+|Traceback" | sed 's/^/SCRATCH /'
  sleep 1200
done
