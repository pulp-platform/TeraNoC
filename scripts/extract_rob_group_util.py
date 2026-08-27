#!/usr/bin/env python3
"""Per-group FPU utilisation over time for the ROB experiments.

Feeds the mesh + time-slider on the ROB artifact, exactly as
extract_decode_group_util.py does for the decode one. Keys are "<image>|<shape>" so
the three (or six) images of one shape sit adjacent in the selector -- comparing
images is the entire point of this experiment.
"""
import glob, json, os, re

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = os.path.join(ROOT, "docs/benchmarks/rob_group_util.json")
CPG  = 16
LINE = re.compile(rb"^\[FPUG\]\s+(\w+)\s+cyc=(\d+)\s+denom=(\d+)\s+busy=\s*([0-9,\s]+)", re.M)

# tag -> (precision, MAC per lane-cycle, label, M, N, P)
SHAPES = {"d16a": (16, 2, "decode fp16 D=128"), "d16b": (16, 2, "decode fp16 D=256"),
          "d32a": (32, 1, "decode fp32 D=128"), "d32b": (32, 1, "decode fp32 D=256"),
          "p09":  (16, 2, "prefill 2048x32x128"), "p20": (16, 2, "prefill 2048x64x128"),
          "p50":  (16, 2, "prefill 1024x128x256"), "p49f": (32, 1, "prefill 1024x64x256"),
          "p66":  (16, 2, "prefill 1024x128x512"), "p78": (16, 2, "prefill 1024x256x512")}
DIMS = {"d16a": (32,128,16384), "d16b": (32,256,16384), "d32a": (32,128,8192),
        "d32b": (32,256,8192), "p09": (2048,32,128), "p20": (2048,64,128),
        "p50": (1024,128,256), "p49f": (1024,64,256), "p66": (1024,128,512),
        "p78": (1024,256,512)}
IMAGES = ["A", "B", "C", "D0", "D1", "D2"]
CFG = {"A": "rob64+dual", "B": "rob64", "C": "rob32",
       "D0": "64/64", "D1": "64/16", "D2": "128/16"}

out = {}
for tag, (prec, mac, label) in SHAPES.items():
    for img in IMAGES:
        d = None
        for pfx in ("rob", "robn"):
            p = os.path.join(ROOT, "hardware", "%s_%s_%s" % (pfx, img, tag))
            if os.path.isdir(p):
                d = p
                break
        if not d:
            continue
        try:
            raw = open(os.path.join(d, "transcript"), "rb").read()
        except OSError:
            continue
        if b"execution took" not in raw:
            continue
        txt = b"\n".join(l[2:] if l.startswith(b"# ") else l for l in raw.split(b"\n"))
        per, den = [], 0
        for m in LINE.finditer(txt):
            if m.group(1) != b"bench":
                continue
            den = int(m.group(3))
            vals = [int(x) for x in m.group(4).split(b",") if x.strip()]
            if den <= 0 or len(vals) != 64:
                continue
            per.append({"cyc": int(m.group(2)),
                        "u": [round(100.0 * v / den, 1) for v in vals]})
        if not per:
            continue
        M, N, P = DIMS[tag]
        out["%s|%s" % (img, tag)] = {
            "image": img, "cfg": CFG[img], "shape": tag, "label": label,
            "prec": "fp%d" % prec, "mac": mac, "mesh": "8x8",
            # a group's EQUAL SHARE of the MACs -- the per-group progress bars are
            # measured against this, not against the leader
            "share": (M * N * P) / 64.0,
            "groups": 64, "denom": den, "periods": per}

os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump(out, open(OUT, "w"))
print("wrote %s (%d arm(s))" % (OUT, len(out)))
if out:
    print("  " + ", ".join("%s=%dw" % (k, len(v["periods"])) for k, v in sorted(out.items())[:8]))
