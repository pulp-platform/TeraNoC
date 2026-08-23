#!/bin/bash
# Watch the backpressure sweep (run5_*). Emit each arm as it completes, with the number that
# decides the experiment (bankfull_bypass -> should collapse toward 0) and RH, plus the idea-2
# (run4) figure for the same shape so every line carries its own comparison.
# Regenerate + report progress every 10 arms so the artifact can be refreshed on real milestones.
set -u
HW=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware
seen=""; n=0
for i in $(seq 1 3000); do
  for d in "$HW"/run5_*; do
    [ -d "$d" ] || continue
    tag=$(basename "$d"); T=$d/transcript
    case " $seen " in *" $tag "*) continue;; esac
    [ -f "$T" ] || continue
    if grep -aq "execution took" "$T" 2>/dev/null; then
      cyc=$(grep -a "execution took" "$T" | head -1 | grep -oE "[0-9]+")
      bf=$(grep -aoE "bankfull_bypass=[0-9]+" "$T" | tail -1 | cut -d= -f2)
      rh=$(grep -ac "RH STUCK" "$T")
      # same shape under idea-2 (run4) for a per-line comparison
      r4=$HW/run4_${tag#run5_}/transcript
      if [ -f "$r4" ]; then
        c4=$(grep -a "execution took" "$r4" | head -1 | grep -oE "[0-9]+")
        b4=$(grep -aoE "bankfull_bypass=[0-9]+" "$r4" | tail -1 | cut -d= -f2)
      else c4=""; b4=""; fi
      if [ -n "$c4" ] && [ "$c4" -gt 0 ] 2>/dev/null; then
        d100=$(( (cyc - c4) * 100 / c4 ))
        echo "${tag#run5_}: ${cyc} cyc (i2 ${c4}, ${d100}%)  RH=${rh}  bankfull=${bf:-n/a} (i2 ${b4:-n/a})"
      else
        echo "${tag#run5_}: ${cyc} cyc  RH=${rh}  bankfull=${bf:-n/a}  [no i2 arm to compare]"
      fi
      seen="$seen $tag"; n=$((n+1))
      [ $((n % 10)) -eq 0 ] && echo "--- $n arms complete ---"
    elif grep -aqE "\*\* Fatal|\*\* Error|clock gate dropped" "$T" 2>/dev/null; then
      echo "${tag#run5_}: FAILED :: $(grep -aE '\*\* Fatal|\*\* Error|clock gate dropped' "$T" | head -1 | cut -c1-120)"
      seen="$seen $tag"; n=$((n+1))
    fi
  done
  sleep 60
done
echo "bp sweep watcher timed out after $n arms"
