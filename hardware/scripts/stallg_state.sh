#!/bin/bash
# Correct reader for [STALLG] lines: SUMS all groups, and requires raw to be PEGGED for HUNG.
#
# Two traps this exists to avoid, both of which produced wrong calls on 2026-08-19:
#  1. [STALLG] prints one CSV field PER GROUP. Parsing field 0 reports a healthy run as hung --
#     group 0 is legitimately 0 in many periods. Sum across groups.
#  2. A genuine hang has raw ~= denom on EVERY group. Apps that never enable tracing
#     (csr_trace_any_global) report ins=0 with a small nonzero raw, which a "raw > 0" test
#     misclassifies as HUNG -- that nearly produced a false refutation of a live hypothesis.
#     Require raw_sum > 50% of (denom * groups).
# Also strips QuestaSim's leading "# ".
T="$1"
[ -f "$T" ] || { echo "state=NOFILE"; exit 0; }
sed 's/^# //' "$T" | grep -a '^\[STALLG\]' | tail -1 | \
awk '{
  tag=$2; cyc=""; ins=""; raw=""; denom="";
  for(i=1;i<=NF;i++){
    if($i ~ /^cyc=/)   cyc=substr($i,5);
    if($i ~ /^denom=/) denom=substr($i,7);
    if($i ~ /^ins=/)   ins=substr($i,5);
    if($i ~ /^raw=/)   raw=substr($i,5);
  }
  ni=split(ins,I,","); nr=split(raw,R,",");
  si=0; nz=0; for(k=1;k<=ni;k++){ si+=I[k]; if(I[k]+0>0) nz++ }
  sr=0; for(k=1;k<=nr;k++){ sr+=R[k] }
  cap = (denom+0) * nr;                # raw_sum if every group were fully stalled
  pegged = (cap>0) && (sr > 0.5*cap);
  if      (nz==0 && pegged) st="HUNG";
  else if (nz==0)           st="IDLE/pre-trace";
  else                      st="RUNNING";
  printf "state=%s tag=%s cyc=%s ins_sum=%d groups_retiring=%d/%d raw_sum=%d raw_cap=%d\n",
         st, tag, cyc, si, nz, ni, sr, cap;
}'
