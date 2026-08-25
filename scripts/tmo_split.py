#!/usr/bin/env python3
"""Split each arm's mshr_timeout by the probe's own PHASE LABEL -> tmo_split.json.

SPLIT BY LABEL, NEVER BY COMPARING cyc TO THE CYCLE COUNT. The TB's `cyc=` is a GLOBAL counter
-- for fp16_4096x128x128 the `bench` phase runs from cyc 35,000 to 82,000 -- while the software's
"execution took N cycles" is a DURATION, not a position on that axis. An earlier version of this
script classified `cyc > N` as post-benchmark, which put the middle of the bench window on the
wrong side and reported 93% of that arm's timeouts as teardown. The truth by label is 1,426 of
1,428 in `bench`. Every downstream conclusion from that version was void:

    "M=2048 timeouts are 100% teardown"          -- WRONG
    "18 of 48 arms are pure teardown"            -- WRONG
    "fp16_4096x128x128 is 14x overstated"        -- WRONG; it is a real in-benchmark signal

The probe emits `pre` before the benchmark region and `bench` inside it; a `post` label exists in
the format but is not produced by these runs.
"""
import csv, json, os, re

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/tmo_split.json")
PH   = ("pre", "bench", "post")


def phase_sums(b):
    out = {}
    for ph in PH:
        pat = (r"\[FPU\]\s+%s\s+cyc=\d+[^\n]*?mshr_timeout=\+(\d+)" % ph).encode()
        out[ph] = sum(int(m.group(1)) for m in re.finditer(pat, b))
    return out


out = {}
for r in csv.DictReader(open(os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")),
                        delimiter="\t"):
    if r.get("state") != "done":
        continue
    arm = "%s_%s" % (r["prec"], r["shape"])
    try:
        b = open(os.path.join(ROOT, "hardware", "s8_" + arm, "transcript"), "rb").read()
    except OSError:
        continue
    b = b"\n".join(l[2:] if l.startswith(b"# ") else l for l in b.split(b"\n"))
    s = phase_sums(b)
    if sum(s.values()):
        s["whole"] = sum(s[p] for p in PH)
        out[arm] = s

os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)
tot = sum(v["whole"] for v in out.values())
bench = sum(v["bench"] for v in out.values())
print("wrote %s (%d arms; %d of %d timeouts are in the bench phase = %.1f%%)"
      % (OUT, len(out), bench, tot, 100.0 * bench / tot if tot else 0))
