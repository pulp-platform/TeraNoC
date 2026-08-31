#!/bin/bash
# Rebuild /tmp/claude-620771/fleet_status.tsv from LIVE badist state.
# The artifact's "running / not dispatched" split comes entirely from this file, so a stale copy
# renders running arms as never-started -- it once showed 26 wave-A arms as "not dispatched" for
# seventeen hours, and later hid a whole freshly-dispatched batch. Run this before regenerating.
set -u
export PATH="$HOME/badist/bin:$HOME/.local/bin:$PATH"
OUT=/tmp/claude-620771/fleet_status.tsv
/usr/local/anaconda3-2022.05/bin/python3 - <<'PY' > "$OUT.new"
import subprocess, json, sys
# every batch that still has jobs we care about; add new ones here when a wave is dispatched
B=["waveC8x8-20260831-171742-219a","waveC4rest-20260831-170908-f050",
   "waveA8x8-20260831-023909-89fc","waveA8x8rq-20260831-150519-6b30",
   "waveA8x8rq2-20260831-155555-ad7c","waveC4-20260831-012318-5320",
   "waveB-20260830-153733-672b","s8ks8p1-20260830-121014-db54",
   "run2tgt-20260829-212656-8043","run2tgtb-20260829-215219-729b",
   "teranoc-20260829-165720-48f9","teranoc-20260829-171031-09f6",
   "waveA2rest-20260829-181331-48b9"]
RANK={"done":0,"running":1,"dispatched":1,"submitted":2,"failed":3,"lost":4,"cancelled":5}
best={}; unread=[]
for b in B:
    j=None
    for _ in range(3):
        o=subprocess.run(["badist","status",b,"--json"],capture_output=True,timeout=150,text=True).stdout
        if o.strip():
            try: j=json.loads(o); break
            except Exception: pass
    if j is None: unread.append(b); continue
    for x in j:
        a=(x.get("meta") or {}).get("arm"); st=x.get("state")
        if not a or not st: continue
        r=RANK.get(st,9)
        if a not in best or r<best[a][0]: best[a]=(r,st,x.get("node") or "")
if unread: print("UNREADABLE: %s" % ",".join(unread), file=sys.stderr)
for a,(r,st,nd) in sorted(best.items()): print("%s\t%s\t%s"%(a,st,nd))
PY
n=$(wc -l < "$OUT.new")
# Never install a smaller file over a good one on a partial read -- that would re-create the very
# staleness this script exists to prevent.
o=$( [ -f "$OUT" ] && wc -l < "$OUT" || echo 0 )
if [ "$n" -lt $(( o / 2 )) ]; then
  echo "REFUSED: new file has $n rows against $o -- looks like a partial read, keeping the old one"
  rm -f "$OUT.new"; exit 1
fi
mv "$OUT.new" "$OUT"
echo "fleet_status.tsv rebuilt: $n rows"
