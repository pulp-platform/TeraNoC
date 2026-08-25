#!/usr/bin/env python3
"""Per-group, per-period FPU utilisation for the decode arms -> docs/benchmarks/decode_group_util.json.

Source is the TB's [FPUG] probe: one CSV field per group, `denom` lane-cycles each per period.

MESH-AGNOSTIC, unlike the 8x8 extractor which hardcodes 64 fields. The group count comes from the
arm's family (cores / 16 cores-per-group), so 4x4 (16 groups) and 8x8 (64) both work and a future
mesh needs only its FAMILIES entry.

Two parsing traps, both previously costly and both guarded here:
  * QuestaSim prefixes every transcript line with "# "; VCS does not. An anchored ^\\[FPUG\\]
    silently matches zero lines on a Questa arm, and that arm reads as "no data".
  * The SV probe pads field 0, so the output is `busy= 50104,...` with a LEADING SPACE. A pattern
    demanding a digit straight after `=` matches nothing on a log full of them.
Only the BENCHMARK phase is kept; pre/post periods are idle and would flatten the colour scale.
"""
import glob, json, os, re

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = os.path.join(ROOT, "docs/benchmarks/decode_group_util.json")
CPG  = 16                      # cores per group
LINE = re.compile(rb"^\[FPUG\]\s+(\w+)\s+cyc=(\d+)\s+denom=(\d+)\s+busy=\s*([0-9,\s]+)", re.M)

FAMILIES = [("dec4_",  (256, "fp16", 2)), ("dec8_",  (1024, "fp16", 2)),
            ("d4f32_", (256, "fp32", 1)), ("d8f32_", (1024, "fp32", 1))]


def family(arm):
    for p, f in FAMILIES:
        if arm.startswith(p):
            return f
    return None


out = {}
for d in sorted(glob.glob(os.path.join(ROOT, "hardware", "dec_*"))):
    arm = os.path.basename(d)[4:]
    f = family(arm)
    m = re.search(r"(\d+)x(\d+)x(\d+)$", arm)
    if not f or not m:
        continue
    cores, prec, mac = f
    ngroups = cores // CPG
    B, D, I = (int(x) for x in m.groups())
    try:
        raw = open(os.path.join(d, "transcript"), "rb").read()
    except OSError:
        continue
    if b"execution took" not in raw:
        continue
    txt = b"\n".join(l[2:] if l.startswith(b"# ") else l for l in raw.split(b"\n"))
    per = []
    for mm in LINE.finditer(txt):
        if mm.group(1) != b"bench":
            continue
        den = int(mm.group(3))
        vals = [int(x) for x in mm.group(4).split(b",") if x.strip()]
        if den <= 0 or len(vals) != ngroups:
            continue
        per.append({"cyc": int(mm.group(2)),
                    "u": [round(100.0 * v / den, 1) for v in vals]})
    if not per:
        continue
    out[arm] = {"groups": ngroups, "denom": den, "mac": mac, "prec": prec,
                "mesh": "%dx%d" % (int(ngroups ** 0.5), int(ngroups ** 0.5)),
                "share": B * D * I / ngroups, "periods": per}

os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump(out, open(OUT, "w"))
print("wrote %s (%d arm(s): %s)"
      % (OUT, len(out), ", ".join("%s=%dg/%dw" % (a, v["groups"], len(v["periods"]))
                                  for a, v in sorted(out.items()))))
