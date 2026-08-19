#!/bin/bash
# Correct reader for [STALLG] lines: SUMS all 16 groups.
# Reading only field 0 (ins=([0-9]+),) reports one group and mistakes a healthy
# run for a hang -- group 0 is legitimately 0 in many periods. Cost one wrong
# "build_vperf is hung" call on 2026-08-19.
# Also strips QuestaSim's leading "# " before matching.
T="$1"
[ -f "$T" ] || { echo "state=NOFILE"; exit 0; }
sed 's/^# //' "$T" | grep -a '^\[STALLG\]' | tail -1 | \
awk '{
  tag=$2; cyc=""; ins=""; raw="";
  for(i=1;i<=NF;i++){
    if($i ~ /^cyc=/) cyc=substr($i,5);
    if($i ~ /^ins=/) ins=substr($i,5);
    if($i ~ /^raw=/) raw=substr($i,5);
  }
  ni=split(ins,I,","); nr=split(raw,R,",");
  si=0; nz=0; for(k=1;k<=ni;k++){ si+=I[k]; if(I[k]+0>0) nz++ }
  sr=0; for(k=1;k<=nr;k++){ sr+=R[k] }
  st = (nz==0 && sr>0) ? "HUNG" : (nz==0 ? "IDLE/pre-trace" : "RUNNING");
  printf "state=%s tag=%s cyc=%s ins_sum=%d groups_retiring=%d/%d raw_sum=%d\n", st, tag, cyc, si, nz, ni, sr;
}'
