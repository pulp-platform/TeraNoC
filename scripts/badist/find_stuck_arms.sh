#!/bin/bash
# A Questa arm can hang mid design-load: CPU ~0, RSS frozen, transcript ending in "Loading work.*"
# and no [FPU] line ever. It holds a licence and a node slot indefinitely and every status view
# calls it "running". Count them per node.
n="$1"
timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$n" '
for d in /scratch/zexifu_cache/badist/run/*/*/; do
  [ -f "$d/transcript" ] || continue
  # a running arm has reached the benchmark; a stuck one is still in the module-load phase
  if grep -aq "^# \[FPU\]\|^\[FPU\]" "$d/transcript" 2>/dev/null; then continue; fi
  last=$(tail -1 "$d/transcript" 2>/dev/null | cut -c1-40)
  age=$(( ($(date +%s) - $(stat -c %Y "$d/transcript" 2>/dev/null || echo 0)) / 60 ))
  case "$last" in *"Loading work."*) ;; *) continue;; esac
  # A KILLED job leaves its run dir behind, transcript frozen mid-load and idle growing forever,
  # so a dir-only scan reports every arm you already cleaned up as still stuck -- it re-reported
  # all 29 minutes after they were killed. Require a LIVE process whose cwd is this job dir.
  live=0
  for pp in $(ls /proc 2>/dev/null | grep -E "^[0-9]+$"); do
    [ "$(readlink /proc/$pp/cwd 2>/dev/null)" = "${d%/}" ] && live=1 && break
  done
  [ "$live" = "1" ] || continue
  echo "STUCK $(basename $(dirname $d))/$(basename $d) idle=${age}min :: $last"
done' 2>/dev/null
