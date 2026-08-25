#!/bin/bash
# Maintain results.tsv, the per-group mesh data, and the dashboard HTML.
# v4 adds extract_group_util.py to the cycle. In v3 the mesh/progress views were fed by a file
# only ever written by hand, so the run picker silently lagged the Results table as arms finished
# -- data that exists but cannot be selected reads as missing data.
# Regenerate every pass (cheap); only ASK for a republish when it is worth one:
#   * >= 5 new completions since the last ask, or
#   * >= 30 min since the last ask with at least 1 new completion, or
#   * a NEW finding: an fp32 arm hitting the assertion, or a fatal at an unseen site.
# The last clause must never be swallowed by the rate limit -- a first instance is the result a
# human is waiting for.
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
P=/tmp/claude-620771/.s8_ndone; S=/tmp/claude-620771/.s8_sites; A=/tmp/claude-620771/.s8_asked
while true; do
  # Repair anything overwritten since the last pass, THEN vault what is newly complete.
  # The live transcript is written by several paths -- fetch extraction, a killed job's gather,
  # salvage copies -- and guarding each writer has not been sufficient: three separate mechanisms
  # clobbered completed results on 2026-08-25, twice in one morning. The vault is write-once and
  # nothing else touches it, so a clobber now costs one loop cycle instead of an archive dig.
  (cd "$R" && timeout 900 python3 scripts/badist/transcript_vault.py restore 2>&1) | grep -E "RESTORED|FAIL" | sed "s/^/VAULT /"
  OUT=$(cd "$R" && timeout 600 python3 scripts/collect_8x8_results.py 2>&1)
  (cd "$R" && timeout 1800 python3 scripts/badist/transcript_vault.py vault 2>&1) | grep -E "vaulted [1-9]|FAIL" | sed "s/^/VAULT /"
  N=$(echo "$OUT" | grep -oE 'results.tsv: [0-9]+' | grep -oE '[0-9]+'); N=${N:-0}
  # per-group mesh data BEFORE the dashboard, so the page embeds the current set
  (cd "$R" && timeout 600 python3 scripts/extract_group_util.py >/dev/null 2>&1)
  (cd "$R" && timeout 300 python3 scripts/gen_8x8_dashboard.py >/dev/null 2>&1)
  T=$R/docs/benchmarks/8x8_scaleup/results.tsv
  SITES=$(awk -F'\t' 'NR>1 && $9 ~ /FATAL@/ {sub(/.*FATAL@/,"",$9); print $9}' "$T" 2>/dev/null | sort -u | paste -sd, -)
  F32=$(awk -F'\t' 'NR>1 && $2=="fp32" && $9 ~ /FATAL/' "$T" 2>/dev/null | wc -l)
  MESH=$(python3 -c "import json;print(len(json.load(open('/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/docs/benchmarks/8x8_scaleup/group_util.json'))))" 2>/dev/null || echo 0)
  OLD=$(cat "$P" 2>/dev/null); [ -z "$OLD" ] && OLD=$N && echo "$N" > "$P"
  OSITES=$(cat "$S" 2>/dev/null); ASKED=$(cat "$A" 2>/dev/null || echo 0)
  NOW=$(date +%s); NEW=$((N-OLD)); WHY=""
  [ "$NEW" -ge 5 ] && WHY="$NEW new completions"
  [ -n "$OSITES" ] && [ "$SITES" != "$OSITES" ] && WHY="NEW fatal site: $SITES"
  [ "${F32:-0}" -gt 0 ] && WHY="fp32 arm hit the assertion -- the fp16-only split is BROKEN"
  [ -z "$WHY" ] && [ "$NEW" -ge 1 ] && [ $((NOW-ASKED)) -ge 1800 ] && WHY="$NEW new since last update"
  if [ -n "$WHY" ]; then
    echo "S8RESULT $N/248 complete ($MESH with mesh data) -- $WHY -- REPUBLISH"
    echo "$N" > "$P"; echo "$SITES" > "$S"; echo "$NOW" > "$A"
  fi
  [ -z "$OSITES" ] && echo "$SITES" > "$S"
  sleep 600
done
