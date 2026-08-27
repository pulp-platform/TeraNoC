#!/bin/bash
# Keep per-hart trace files from refilling node-local scratch.
#
# snitch_trace defaults to 1 (hardware/Makefile:57), so every arm writes
# trace_hart_*.dasm + trace_spatz_*.log -- ~150 KB per hart per arm, which at 1024 harts
# is 100+ GB per node and nothing in the dashboards reads any of it.  A one-off reap on
# 2026-08-27 reclaimed ~6 TB across the fleet; hours later badile15 was back to 531 GB.
# This keeps it drained instead of cleaning up after the fact.
#
# STOPGAP.  The source fix is building images with snitch_trace=0.
#
# Safety:
#   * truncate (: >), never delete -- a running simulator keeps its file handle and the
#     blocks are freed immediately; verified 2026-08-27 that sims survive it
#   * only trace_* and *.dasm under the badist run cache; NEVER transcript or stdout.log,
#     which carry the result and every probe the analysis reads
#   * skip a node we cannot reach rather than treating silence as "nothing there"
#   * only act above a threshold, so this is not a constant ssh storm
ROOT=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
MIN_GB=${TRACE_REAP_MIN_GB:-40}
cd "$ROOT" || exit 1
while true; do
  NODES=$(timeout 300 python3 - <<'PY' 2>/dev/null
import glob, json, os
seen = set()
for jf in glob.glob(os.path.expanduser("~/badist/state/*/jobs/*.jsonl")):
    try:
        for ln in open(jf):
            n = json.loads(ln).get("node")
            if n: seen.add(n)
    except Exception:
        pass
print("\n".join(sorted(seen)))
PY
)
  total=0; hit=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    out=$(ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$n" '
      b=$(find /scratch*/zexifu_cache/badist/run -type f \( -name "trace_hart_*" -o -name "trace_spatz_*" -o -name "trace_fpu_*" -o -name "*.dasm" \) -printf "%s\n" 2>/dev/null | awk "{s+=\$1} END{print int(s/1073741824)}")
      [ -z "$b" ] && b=0
      if [ "$b" -ge '"$MIN_GB"' ]; then
        k=0
        for f in $(find /scratch*/zexifu_cache/badist/run -type f \( -name "trace_hart_*" -o -name "trace_spatz_*" -o -name "trace_fpu_*" -o -name "*.dasm" \) 2>/dev/null); do
          case "$(basename $f)" in transcript|stdout.log) continue ;; esac
          : > "$f" && k=$((k+1))
        done
        echo "$b $k"
      else
        echo "$b 0"
      fi' 2>/dev/null)
    gb=${out%% *}; files=${out##* }
    [ -z "$gb" ] && continue            # unreachable: say nothing, do nothing
    if [ "${files:-0}" -gt 0 ]; then
      echo "TRACEREAP $n freed ${gb} GB ($files files)"
      total=$((total + gb)); hit=$((hit+1))
    fi
  done <<< "$NODES"
  [ "$hit" -gt 0 ] && echo "TRACEREAP pass done: ${total} GB across ${hit} node(s)"
  sleep 3600
done
