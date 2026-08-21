#!/bin/bash
# One command for "what is running, where, and what is blocking it".
#
#   scripts/badist/workload.sh            # everything
#   scripts/badist/workload.sh lic        # just the VCS seats
#   scripts/badist/workload.sh fleet      # just the badile jobs
#   scripts/badist/workload.sh local      # just this machine
#   scripts/badist/workload.sh arms       # per-arm phase of the run5 sweep
#
# The three things that actually stall a sweep, in the order they bite:
#   1. VCS runtime seats  -- a refused simv DIES; it does not queue (unless +vcs+lic+wait)
#   2. fenga1 CPU         -- 96 threads shared with everyone
#   3. badile availability
set -u
ROOT=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
HW=$ROOT/hardware
LIC_SRV=8169@lic-synopsys.ethz.ch
LIC_FEAT=VCS-Base-Runtime-Pkg
BADIST=$HOME/badist/bin/badist
WHAT=${1:-all}
ME=$(whoami)

hr() { printf '\n\033[1m%s\033[0m\n' "$1"; }

lic() {
  hr "VCS runtime seats  ($LIC_FEAT @ $LIC_SRV)"
  local out
  out=$(timeout 60 lmutil lmstat -c "$LIC_SRV" -f "$LIC_FEAT" 2>&1)
  echo "$out" | grep -oE 'Total of [0-9]+ licenses? issued;  Total of [0-9]+ licenses? in use' \
    | sed 's/^/  /' | head -1
  local iss use
  iss=$(echo "$out" | grep -oE 'Total of ([0-9]+) licenses? issued' | grep -oE '[0-9]+' | head -1)
  use=$(echo "$out" | grep -oE 'Total of ([0-9]+) licenses? in use' | grep -oE '[0-9]+' | head -1)
  [ -n "${iss:-}" ] && [ -n "${use:-}" ] && printf '  free: %d\n' $((iss - use))
  echo "  holders:"
  echo "$out" | grep -E '^ +[a-z][a-z0-9_]* ' | awk '{print $1}' | sort | uniq -c | sort -rn \
    | head -6 | awk -v me="$ME" '{printf "    %-12s %3d%s\n", $2, $1, ($2==me?"   <- us":"")}'
  # A refused simv exits in seconds. This is what that looks like on disk.
  local dead
  dead=$(find "$HW" -maxdepth 2 -name transcript -newermt '-30 days' -size -8k 2>/dev/null | wc -l)
  [ "$dead" -gt 0 ] && echo "  note: $dead transcript(s) under 8k in hardware/ -- possible licence-denied arms"
}

fleet() {
  hr "badile fleet"
  [ -x "$BADIST" ] || { echo "  badist not installed at $BADIST"; return; }
  local b
  for b in $(ls -t "$HOME/badist/state" 2>/dev/null | grep -v '\.json$' | head -3); do
    printf '  batch %s\n' "$b"
    timeout 90 "$BADIST" status "$b" --json 2>/dev/null | python3 -c '
import json,sys,collections
try: rows=json.load(sys.stdin)
except Exception: print("    (no ledger yet)"); raise SystemExit
st=collections.Counter(r["state"] for r in rows)
print("    " + "  ".join("%s=%d" % (k, st[k]) for k in sorted(st)))
run=[r for r in rows if r["state"]=="running"]
if run:
    by=collections.Counter(r.get("node") or "?" for r in run)
    print("    on: " + " ".join("%s(%d)" % (n,c) for n,c in sorted(by.items())))
    slow=[r for r in run if r.get("cpu_frac") is not None and r["cpu_frac"] < .5]
    if slow: print("    STARVED (<50%% of a core): " + " ".join((r.get("meta") or {}).get("arm", r["job"]) for r in slow))
bad=[r for r in rows if r["state"] in ("failed","lost")]
if bad:
    print("    !! " + ", ".join("%s:%s" % ((r.get("meta") or {}).get("arm", r["job"]), r["state"]) for r in bad[:8]))
'
  done
  hr "badile node health"
  timeout 180 "$BADIST" nodes 2>/dev/null | tail -6
}

local_() {
  hr "fenga1"
  uptime | sed 's/^/  /'
  printf '  cores: %s   simv(VCS): %s   vsimk(Questa): %s\n' \
    "$(nproc)" \
    "$(pgrep -u "$ME" -x mempool_simvopt 2>/dev/null | wc -l)" \
    "$(pgrep -u "$ME" -f vsimk 2>/dev/null | wc -l)"
  echo "  local sims by directory:"
  for p in $(pgrep -u "$ME" -x mempool_simvopt 2>/dev/null); do
    printf '    %-30s cpu=%s\n' "$(basename "$(readlink /proc/$p/cwd 2>/dev/null)")" \
      "$(ps -o pcpu= -p "$p" 2>/dev/null | tr -d ' ')"
  done | sort | head -25
}

arms() {
  hr "run5 sweep arms"
  # A dead arm is the trap: a 4k transcript frozen at the launch minute with no process
  # reads as "loading" to anything that only looks for the absence of an [FPU] line.
  local liveset
  liveset=$(for p in $(pgrep -u "$ME" -x mempool_simvopt 2>/dev/null); do
              basename "$(readlink /proc/$p/cwd 2>/dev/null)"; done | sort -u | tr '\n' ' ')
  # An arm dispatched to the fleet still has its OLD local transcript on disk until
  # `teranoc_fleet.py fetch` overwrites it -- so the on-disk test alone would call a
  # perfectly healthy fleet arm dead. Ask the ledger which arms it is holding.
  local onfleet
  onfleet=$(python3 - <<'PY' 2>/dev/null
import json, os, glob
live = set()
root = os.path.expanduser("~/badist/state")
for b in sorted(os.listdir(root), reverse=True)[:6]:
    d = os.path.join(root, b)
    if not os.path.isdir(d):
        continue
    try:
        jobs = json.load(open(os.path.join(d, "jobs.json")))
    except Exception:
        continue
    term = {}
    for f in glob.glob(os.path.join(d, "jobs", "*.jsonl")):
        last = None
        for ln in open(f):
            try: last = json.loads(ln)
            except Exception: pass
        if last:
            term[os.path.basename(f)[:-6]] = last.get("state")
    for j in jobs:
        st = term.get(j["job_id"])
        if st in ("done", "failed", "cancelled"):
            continue
        arm = (j.get("meta") or {}).get("arm")
        if arm:
            live.add("run5_" + arm)
print(" ".join(sorted(live)))
PY
)
  local d done_=0 bench=0 warm=0 dead=0 fleet_=0
  local now; now=$(date +%s)
  for d in "$HW"/run5_*; do
    [ -d "$d" ] || continue
    local n t T; n=$(basename "$d"); T=$d/transcript
    if grep -aqm1 'execution took' "$T" 2>/dev/null; then done_=$((done_+1)); continue; fi
    if [[ " $liveset " == *" $n "* ]]; then
      grep -aqm1 '\[FPU\] bench' "$T" 2>/dev/null && bench=$((bench+1)) || warm=$((warm+1))
      continue
    fi
    if [[ " $onfleet " == *" $n "* ]]; then fleet_=$((fleet_+1)); continue; fi
    t=$(stat -c %Y "$T" 2>/dev/null || echo "$now")
    if [ $((now - t)) -gt 900 ] && [ "$(du -sk "$T" 2>/dev/null | cut -f1)" -le 8 ]; then
      dead=$((dead+1))
    else
      fleet_=$((fleet_+1))
    fi
  done
  printf '  done=%d  benching(local)=%d  warmup(local)=%d  on-fleet=%d  \033[31mDEAD=%d\033[0m\n' \
    "$done_" "$bench" "$warm" "$fleet_" "$dead"
  [ "$dead" -gt 0 ] && echo "  (DEAD = 4k transcript, no process, untouched >15min -- almost always a refused VCS seat)"
}

case "$WHAT" in
  lic|license) lic ;;
  fleet)       fleet ;;
  local)       local_ ;;
  arms)        arms ;;
  *)           lic; local_; arms; fleet ;;
esac
echo
