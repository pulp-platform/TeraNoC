#!/usr/bin/env python3
"""Per-group, per-period FPU utilisation for every completed 8x8 arm -> JSON.

Source is the TB's [FPUG] probe: one CSV field per group, `denom` lane-cycles each per period.

Two parsing traps this file exists to avoid, both documented and both previously costly:
  * QuestaSim prefixes every transcript line with "# ", VCS does not -- an anchored ^\\[FPUG\\]
    silently matches zero lines on a Questa arm, and that arm reads as "no data".
  * The SV probe pads field 0, so the output is `busy= 24016,17932,...` with a LEADING SPACE.
    A pattern demanding a digit straight after `=` matches nothing on a log full of them.
Only the BENCHMARK phase is kept; pre/post periods are idle and would flatten the colour scale.
"""
import glob, json, os, re, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
# In the repo, not a session scratchpad: this is derived campaign data that must outlive the
# session that produced it, and at ~0.4 MB there is no reason to keep it anywhere else.
OUT  = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "docs/benchmarks/8x8_scaleup/group_util.json")
LINE = re.compile(rb"^\[FPUG\]\s+(\w+)\s+cyc=(\d+)\s+denom=(\d+)\s+busy=\s*([0-9,\s]+)")

def scrape(arm):
    t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
    if not os.path.exists(t):
        return None
    raw = open(t, "rb").read()
    if b"execution took" not in raw:
        return None
    txt = b"\n".join(l[2:] if l.startswith(b"# ") else l for l in raw.split(b"\n"))
    per = []
    for m in LINE.finditer(txt, re.M) if False else re.finditer(LINE.pattern, txt, re.M):
        phase = m.group(1).decode()
        if phase != "bench":
            continue
        cyc = int(m.group(2)); den = int(m.group(3))
        vals = [int(x) for x in m.group(4).split(b",") if x.strip()]
        if den <= 0 or len(vals) != 64:
            continue
        per.append({"cyc": cyc, "u": [round(100.0 * v / den, 1) for v in vals]})
    return per or None

def main():
    arms = []
    for ln in open(os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/manifest.txt")):
        p = ln.split()
        if len(p) == 4:
            arms.append("fp%s_%sx%sx%s" % (p[3], p[0], p[1], p[2]))
    # Merge, never regenerate blind -- same hazard as results.tsv: badist overwrites
    # hardware/s8_<arm>/transcript unconditionally, so a later duplicate can replace a finished
    # transcript with a partial one and this arm's per-group data would silently disappear.
    # fp16_2048x64x256 was lost that way before this was added.
    out = {}
    try:
        out = json.load(open(OUT))
    except Exception:
        pass
    kept0 = set(out)
    for a in arms:
        d = scrape(a)
        if d:
            out[a] = d
    carried = sorted(kept0 - {a for a in arms if scrape(a)})
    if carried:
        print("  carried %d arm(s) forward whose transcript is gone: %s"
              % (len(carried), ", ".join(carried[:4])))
    json.dump(out, open(OUT, "w"), separators=(",", ":"))
    tot = sum(len(v) for v in out.values())
    print("  %d arm(s), %d benchmark periods, %.0f KB"
          % (len(out), tot, os.path.getsize(OUT) / 1024.0))
    for a in sorted(out)[:3]:
        print("    %-22s %2d periods  peak group util %.1f%%"
              % (a, len(out[a]), max(max(p["u"]) for p in out[a])))

main()
