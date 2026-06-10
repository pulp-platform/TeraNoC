#!/usr/bin/env python3
# Summarize [CMS *] lines from a sim transcript.
# Usage: summarize_cms.py <transcript_path>

import re
import sys
from collections import defaultdict, Counter

if len(sys.argv) != 2:
    print("usage: summarize_cms.py <transcript>", file=sys.stderr)
    sys.exit(1)

stuck = []
orphan = Counter()
dup = Counter()
period_summary = []
final_inflight = []
final_global = None

stuck_re = re.compile(
    r"\[CMS WARN\] cyc=(\d+) STUCK_REQ g=(\d+) t=(\d+) c=(\d+) p=(\d+) "
    r"hart=0x([0-9a-fA-F]+) id=(\d+) age=(\d+) addr=0x([0-9a-fA-F]+) "
    r"(R|W) bl=(\d+) beats=(\d+)"
)
orphan_re = re.compile(
    r"\[CMS WARN\] cyc=(\d+) g=(\d+) t=(\d+) c=(\d+) p=(\d+) hart=0x([0-9a-fA-F]+) "
    r"ORPHAN_RESP id=(\d+)"
)
dup_re = re.compile(
    r"\[CMS WARN\] cyc=(\d+) g=(\d+) t=(\d+) c=(\d+) p=(\d+) hart=0x([0-9a-fA-F]+) "
    r"DUP_ALLOC id=(\d+)"
)
period_re = re.compile(
    r"\[CMS\] cyc=(\d+) period_summary: req=(\d+) resp=(\d+) inflight=(\d+) "
    r"orphan=(\d+) dup_alloc=(\d+) top_inflight=\{g=(\d+),t=(\d+),c=(\d+),p=(\d+),"
    r"hart=0x([0-9a-fA-F]+),n=(\d+)\}"
)
final_port_re = re.compile(
    r"\[CMS FINAL\] STILL_INFLIGHT g=(\d+) t=(\d+) c=(\d+) p=(\d+) hart=0x([0-9a-fA-F]+) "
    r"\s*inflight=(\d+) +req=(\d+) +resp=(\d+) +resp_beats=(\d+) +hw=(\d+) +"
    r"avg_lat=(\d+) +max_lat=(\d+)"
)
final_global_re = re.compile(
    r"\[CMS FINAL\] global: req=(\d+) +resp=(\d+) +inflight_ports=(\d+) +"
    r"inflight_entries=(\d+) +orphan=(\d+) +dup_alloc=(\d+) +avg_lat=(\d+)"
)

with open(sys.argv[1], errors="ignore") as f:
    for line in f:
        m = stuck_re.search(line)
        if m:
            stuck.append({
                "cyc": int(m.group(1)),
                "g": int(m.group(2)), "t": int(m.group(3)),
                "c": int(m.group(4)), "p": int(m.group(5)),
                "hart": m.group(6),
                "id": int(m.group(7)), "age": int(m.group(8)),
                "addr": m.group(9), "wr": m.group(10),
                "bl": int(m.group(11)), "beats": int(m.group(12)),
            })
            continue
        m = orphan_re.search(line)
        if m:
            orphan[(int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)))] += 1
            continue
        m = dup_re.search(line)
        if m:
            dup[(int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)))] += 1
            continue
        m = period_re.search(line)
        if m:
            period_summary.append({
                "cyc": int(m.group(1)),
                "req": int(m.group(2)), "resp": int(m.group(3)),
                "inflight": int(m.group(4)),
                "orphan": int(m.group(5)), "dup": int(m.group(6)),
                "top_hart": m.group(11), "top_n": int(m.group(12)),
            })
            continue
        m = final_port_re.search(line)
        if m:
            final_inflight.append({
                "g": int(m.group(1)), "t": int(m.group(2)),
                "c": int(m.group(3)), "p": int(m.group(4)),
                "hart": m.group(5),
                "inflight": int(m.group(6)),
                "req": int(m.group(7)), "resp": int(m.group(8)),
                "max_lat": int(m.group(12)),
            })
            continue
        m = final_global_re.search(line)
        if m:
            final_global = {
                "req": int(m.group(1)), "resp": int(m.group(2)),
                "inflight_ports": int(m.group(3)),
                "inflight_entries": int(m.group(4)),
                "orphan": int(m.group(5)), "dup": int(m.group(6)),
                "avg_lat": int(m.group(7)),
            }

# --- Output ---
print("=" * 70)
print("CMS Scoreboard Summary")
print("=" * 70)

if period_summary:
    print(f"\nPeriodic summaries: {len(period_summary)}")
    print(f"First @ cyc={period_summary[0]['cyc']}: "
          f"req={period_summary[0]['req']} resp={period_summary[0]['resp']} inflight={period_summary[0]['inflight']}")
    print(f"Last  @ cyc={period_summary[-1]['cyc']}: "
          f"req={period_summary[-1]['req']} resp={period_summary[-1]['resp']} inflight={period_summary[-1]['inflight']} top_hart=0x{period_summary[-1]['top_hart']}")
    # Detect stall: if req count stops growing
    if len(period_summary) > 2:
        last_req = period_summary[-1]["req"]
        prev_req = period_summary[-2]["req"]
        if last_req == prev_req:
            print(f"  >>> NO PROGRESS: req unchanged between last two periods at {last_req}")

print(f"\nFirst STUCK_REQ warning: {stuck[0] if stuck else 'NONE'}")

stuck_by_hart = defaultdict(list)
for s in stuck:
    stuck_by_hart[s["hart"]].append(s)

print(f"\nUnique stuck harts: {len(stuck_by_hart)}")
print(f"\nPer-stuck-hart first occurrence:")
for hart, entries in sorted(stuck_by_hart.items(),
                            key=lambda x: x[1][0]["cyc"]):
    e = entries[0]
    print(f"  hart=0x{hart} (g={e['g']} t={e['t']} c={e['c']} p={e['p']}) "
          f"first@cyc={e['cyc']} id={e['id']} addr=0x{e['addr']} {e['wr']} "
          f"bl={e['bl']} beats={e['beats']} age={e['age']}")

if orphan:
    print(f"\nORPHAN responses: {sum(orphan.values())} total across {len(orphan)} ports")
    for (g,t,c,p), n in orphan.most_common(5):
        print(f"  g={g} t={t} c={c} p={p}: {n}")

if dup:
    print(f"\nDUP allocations: {sum(dup.values())} total across {len(dup)} ports")
    for (g,t,c,p), n in dup.most_common(5):
        print(f"  g={g} t={t} c={c} p={p}: {n}")

if final_global:
    print(f"\nFINAL: req={final_global['req']} resp={final_global['resp']} "
          f"inflight_ports={final_global['inflight_ports']} "
          f"inflight_entries={final_global['inflight_entries']} "
          f"avg_lat={final_global['avg_lat']}")
if final_inflight:
    print(f"\nPorts still inflight at end: {len(final_inflight)}")
    for f in sorted(final_inflight, key=lambda x: -x["inflight"])[:10]:
        print(f"  hart=0x{f['hart']} (g={f['g']} t={f['t']} c={f['c']} p={f['p']}): "
              f"inflight={f['inflight']} req={f['req']} resp={f['resp']} max_lat={f['max_lat']}")
