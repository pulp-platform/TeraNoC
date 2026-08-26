#!/bin/bash
# Node-local disk guard: reclaim our spent run dirs, rescue finished results off an at-risk disk.
# Emits only exposure or action -- the dangerous case is a node we CANNOT free, where finished
# arms are discarded by `tar | zstd` at the end of the job.
cd /usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
while true; do
  out=$(timeout 1500 python3 scripts/badist/scratch_guard.py 2>&1)
  # NOTE lines carry the personal-scratch figures the guard learned to emit on 2026-08-26.
  # They were written by the guard and then DROPPED HERE, because this filter predates them,
  # so the alert still could not say the one thing that would let a human act. Any new line
  # the guard learns to emit must be added to this alternation as well.
  echo "$out" | grep -E "at risk --|STILL BELOW|will lose their results|reclaiming [0-9]+|rescuing |rescued [0-9]+|NOTE |Traceback" | sed 's/^/SCRATCH /'
  sleep 1200
done
