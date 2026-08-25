#!/usr/bin/env python3
"""Split each arm's mshr_timeout into IN-BENCHMARK and POST-BENCHMARK -> tmo_split.json.

WHY THIS EXISTS. results.tsv's `mshr_timeout` sums every `+N` delta in the transcript, but the
probe keeps printing long after the benchmark ends, so the column mixes timeouts that cost
benchmark cycles with teardown drain that costs nothing. Measured across the 48 arms with a
nonzero count:

    M=2048   0 in-benchmark, 603 post      -> 100% teardown; the window NEVER binds during work
    M=4096   20,964 in-benchmark, 10,822 post -> 34% teardown
    M=8192   92,844 in-benchmark, 14,494 post -> 14% teardown

and 18 of the 48 arms are 100% teardown. Reading the whole-transcript number as a performance
signal overstates it -- for fp16_4096x128x128 by 14x (1428 whole vs 103 in-benchmark), which is
enough to have put that shape into an A/B it did not belong in.

Written as a SEPARATE file rather than a results.tsv column on purpose: four consumers read that
file positionally and the collector merges rows against existing records, so widening the schema
mid-campaign is a much larger change than the finding warrants.
"""
import csv, json, os, re

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/tmo_split.json")
EV   = re.compile(rb"cyc=(\d+)[^\n]*?mshr_timeout=\+(\d+)")

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
    m = re.search(rb"execution took (\d+)", b)
    if not m:
        continue
    end = int(m.group(1))
    ev = [(int(c), int(v)) for c, v in EV.findall(b)]
    inb = sum(v for c, v in ev if c <= end)
    post = sum(v for c, v in ev if c > end)
    if inb or post:
        out[arm] = {"cycles": end, "in_bench": inb, "post": post, "whole": inb + post}

os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)
pure = sum(1 for v in out.values() if v["in_bench"] == 0)
print("wrote %s (%d arm(s) with timeouts; %d are 100%% post-benchmark)" % (OUT, len(out), pure))
