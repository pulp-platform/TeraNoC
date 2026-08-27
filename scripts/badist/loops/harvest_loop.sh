#!/bin/bash
# Harvest arms that FINISHED but will never be delivered.
#
# The matmul epilogue wedge (the same FP-verify hang that forces MATMUL_VERIFY=0 tree-wide) leaves
# the simulator running after the kernel has printed its result, so the badist job never exits and
# the result is never packaged. The arm reads "running" forever while its number sits on the node.
# 11 arms were recovered by hand this way on 2026-08-27, both times noticed by accident.
#
# This is a STOPGAP. The real fix is the FP-free integer verify that removes the wedge.
#
# Safety rules, in order:
#   * never overwrite a transcript that already carries a result
#   * an incomplete local transcript is MOVED aside, not deleted (killed-duplicate evidence)
#   * a copy is committed only if it actually contains "execution took"; otherwise the backup
#     is restored, so a failed pull can never leave us with less than we started with
#   * an unreachable node is skipped, never treated as "no processes"
ROOT=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
cd "$ROOT" || exit 1
while true; do
  LIST=$(timeout 600 python3 - <<'PY' 2>/dev/null
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("grp", "scripts/gen_run_progress.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    rows = json.load(open("docs/benchmarks/8x8_scaleup/run_progress.json"))["rows"]
except Exception:
    raise SystemExit
procs = m.node_procs(sorted({r["node"] for r in rows}))
for r in rows:
    arm, node = r["arm"], r["node"]
    # only arms whose OWN live process reports a result -- a delivered transcript needs nothing
    for a, cwd, age, marker in (procs.get(node) or []):
        if a != arm or not marker:
            continue
        t = os.path.join("hardware", "s8_" + arm, "transcript")
        try:
            if os.path.exists(t) and b"execution took" in open(t, "rb").read():
                break                      # already delivered, nothing to do
        except OSError:
            pass
        print("%s %s %s" % (arm, node, cwd))
        break
PY
)
  n=0
  while IFS=' ' read -r arm node cwd; do
    [ -n "$arm" ] || continue
    d="hardware/s8_$arm"; mkdir -p "$d"
    if [ -f "$d/transcript" ]; then mv "$d/transcript" "$d/transcript.pre_harvest.bak"; fi
    if ssh -n -o ConnectTimeout=20 -o BatchMode=yes "$node" "cat $cwd/transcript" > "$d/transcript.part" 2>/dev/null \
       && grep -aqm1 'execution took' "$d/transcript.part"; then
      mv "$d/transcript.part" "$d/transcript"
      echo "HARVEST $arm ($node) $(grep -aom1 'execution took [0-9]*' "$d/transcript")"
      n=$((n+1))
    else
      rm -f "$d/transcript.part"
      [ -f "$d/transcript.pre_harvest.bak" ] && mv "$d/transcript.pre_harvest.bak" "$d/transcript"
      echo "HARVEST $arm ($node) FAILED -- pull incomplete, local state restored"
    fi
  done <<< "$LIST"
  [ "$n" -gt 0 ] && echo "HARVEST $n arm(s) recovered this pass"
  sleep 1800
done
