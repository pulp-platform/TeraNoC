#!/usr/bin/env python3
"""Is an arm's shape completable inside the job deadline?

The 8x8 sweep's largest shapes cannot finish, and retrying them costs a licence seat for the full
deadline before failing identically. On 2026-08-23 the original cohort's 24h deadline expired en
masse: 115 arms timed out, 82 with nothing delivered.

Calibration (all measured from this campaign's own delivered arms, not assumed):
  * cycles scale with M*N*P -- median 2.911e-4 cyc per MAC-unit for fp16, 7.150e-4 for fp32
    (fp32 needs ~2.5x the cycles, consistent with ~2 MACs per lane-cycle at fp16 vs ~1 at fp32)
  * wall time ~1.15 s per simulated cycle, on BOTH simulators (n=32 questa, n=34 vcs) -- the
    1.7x VCS advantage measured on one arm does not hold across the campaign
So: hours ~= M*N*P * cyc_per_mac * 1.15 / 3600.

At the 48h deadline the cutoff is M*N*P <= 5.2e8 (fp16) / 2.1e8 (fp32); 78 of the 248 manifest
arms exceed it, the worst by 5x (245 h).

This is a PROJECTION from medians, and the per-arm spread is wide (fp16 1.7e-4..1.65e-3), so treat
it as a planning filter, never as grounds for discarding a delivered measurement.
"""
import re

import csv as _csv
import os as _os

_ROOT = _os.path.dirname(_os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
_TSV = _os.path.join(_ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")

CYC_PER_MAC = {"fp16": 2.911e-4, "fp32": 7.150e-4}   # linear fallback, used if the fit has too few points
SEC_PER_CYCLE = 1.015   # measured median over 105 completed jobs (questa 0.906, vcs 1.125)

# Cycles scale SUB-LINEARLY with M*N*P: fitting log(cycles) on log(work) over this campaign's own
# delivered arms gives an exponent of ~0.80 (fp16, n=46) and ~0.85 (fp32, n=38), not 1.0. Bigger
# shapes amortise better, so a linear model over-charges them -- it put 19 arms over the 48h
# deadline at 44h that the fit puts at 38h.
#
# The fit is recomputed from results.tsv on each call rather than hardcoded, so it sharpens as the
# sweep fills in instead of going stale. The linear constants above remain the fallback.
#
# SEC_PER_CYCLE is the MEASURED median (1.015 s/cycle over 105 completed jobs: questa 0.906, vcs
# 1.125). It was 1.15, which is ~13% conservative -- and that silently DOUBLED the caution, since
# `fits()` already applies a 0.85 margin. Keep the projection honest and the caution in one place.
# (An earlier claim of 12.2 cyc/s from the dashboard's "measured" panel was wrong by ~12x; wall-time
# per job is the trustworthy source, not that panel.)
_FIT_CACHE = {}


def _fit(pr):
    """(coefficient, exponent) for cycles ~= a * work**k, from delivered arms of this precision."""
    if pr in _FIT_CACHE:
        return _FIT_CACHE[pr]
    import math
    pts = []
    try:
        with open(_TSV) as fh:
            for r in list(_csv.reader(fh, delimiter="\t"))[1:]:
                if len(r) < 4 or r[1] != pr or not r[3].strip().isdigit():
                    continue
                m = re.match(r"^(\d+)x(\d+)x(\d+)$", r[0])
                if not m:
                    continue
                w = 1
                for g in m.groups():
                    w *= int(g)
                pts.append((w, int(r[3])))
    except OSError:
        pts = []
    if len(pts) < 12:                     # too few to fit; caller falls back to linear
        _FIT_CACHE[pr] = None
        return None
    xs = [math.log(w) for w, _ in pts]
    ys = [math.log(c) for _, c in pts]
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    if den <= 0:
        _FIT_CACHE[pr] = None
        return None
    k = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den
    _FIT_CACHE[pr] = (math.exp(my - k * mx), k)
    return _FIT_CACHE[pr]


def projected_hours(arm, sec_per_cycle=SEC_PER_CYCLE):
    """arm like 'fp16_1024x256x512' -> projected wall hours, or None if unparseable."""
    m = re.match(r"^(fp16|fp32)_(\d+)x(\d+)x(\d+)$", arm or "")
    if not m:
        return None
    pr, M, N, P = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
    w = M * N * P
    f = _fit(pr)
    cycles = (f[0] * w ** f[1]) if f else (w * CYC_PER_MAC[pr])
    return cycles * sec_per_cycle / 3600.0


def fits(arm, deadline_s=2592000, margin=0.85):
    """True if the arm is projected to finish inside the deadline.

    DEADLINES WERE REMOVED 2026-08-23 (user decision): a healthy run is never killed on wall-clock,
    so `deadline_s` defaults to 30 days and this returns True for every real shape. Nothing is
    "infeasible" any more -- that category only existed because a FIXED wall was compared against
    variable runtimes, and it was cutting 24% of the manifest (48 arms projected 42-136 h against a
    48 h line) purely because of where the line happened to sit.

    `projected_hours` is still the useful half of this module: it says how long an arm should take,
    which is what liveness checks compare against to spot a wedge (~75x its projection at ~1% FPU
    utilisation). Keep the projection; drop the guillotine.
    """
    h = projected_hours(arm)
    if h is None:
        return True                      # unknown shape: never block on a guess
    return h <= (deadline_s / 3600.0) * margin


if __name__ == "__main__":
    import sys
    for a in sys.argv[1:]:
        h = projected_hours(a)
        print("%-24s %s  (%s)" % (a, "%.1f h" % h if h else "?",
                                  "fits" if fits(a) else "EXCEEDS 48h deadline"))


# --- delivery test -------------------------------------------------------------------------
# The transcript is NOT a reliable "have we got this result" test: badist overwrites
# hardware/s8_<arm>/transcript unconditionally, so a duplicate can destroy a delivered one, and a
# fetch can restore it minutes later. Anything deciding whether to spend a seat on an arm sees a
# different answer depending on when it looks -- the top-up re-picked four already-delivered arms
# in exactly that window.
#
# results.tsv is merge-only: once a row exists it is never dropped, even if the evidence behind it
# disappears. So it, not the transcript, is the durable record of "we already have this".


def delivered(arm):
    """True if this arm has a recorded result (durable row) or a finished transcript."""
    try:
        with open(_TSV) as fh:
            for r in list(_csv.reader(fh, delimiter="\t"))[1:]:
                if len(r) > 3 and (r[1] + "_" + r[0]) == arm and r[3].strip().isdigit():
                    return True
    except OSError:
        pass
    t = _os.path.join(_ROOT, "hardware", "s8_" + arm, "transcript")
    try:
        return b"execution took" in open(t, "rb").read()
    except OSError:
        return False


# --- announce-once -------------------------------------------------------------------------
# These scripts are re-invoked by a loop every few minutes. A skip reason that has not changed is
# noise, and a channel that repeats itself trains the reader to ignore it -- which is how a real
# event gets missed. Callers announce through here so the state is shared and survives cycles.
import json as _json

_SEEN_PATH = "/tmp/claude-620771/badist_announced.json"
try:
    _seen = set(_json.load(open(_SEEN_PATH)))
except Exception:
    _seen = set()


def announce_once(key, message):
    """Print message the first time this key is seen; stay silent afterwards. Returns True if printed."""
    if key in _seen:
        return False
    _seen.add(key)
    print(message)
    return True


def save_announced():
    try:
        _json.dump(sorted(_seen), open(_SEEN_PATH, "w"))
    except OSError:
        pass


# --- known-stalling shapes ------------------------------------------------------------------
# These do not fail, they STALL: ~0.1% FPU utilisation, mshr_timeout 0, [GroupMerge] 0, and
# request ages pinned just under the 2047-cycle MSHR burst hold window. fp16_512x64x256 reached
# 565,122 cycles against ~2,442 expected -- ~80x its own fp32 twin (7,138). Each has been killed
# and requeued 3+ times; every attempt stalls the same way, so retrying only holds a licence seat
# for hours and produces nothing.
#
# They are NOT dropped from the campaign -- they are held back from AUTOMATIC dispatch until the
# one-knob experiment runs (burst hold window 0; see the KB note
# `experiments/fp16-m512-smallP-stall`). Submit one by hand at any time to test.
# NOT fp16-specific -- fp32_512x32x128 shows the identical signature (0.32% util, GroupMerge 0,
# max request age 1999, 185 MB transcript). The common factor is M=512 with small P (128-256),
# across both precisions and any N from 32 to 512.
KNOWN_STALL = {
    "fp16_512x64x256":  "~0.1% util, 231x expected cycles, no merge partners",
    "fp16_512x256x128": "~0.1% util, stalls identically across 4 nodes",
    "fp16_512x512x128": "~0.1% util, stalls identically across 4 nodes",
    "fp32_512x32x128":  "0.32% util, same signature -- shows it is not precision-specific",
}


def stalling(arm):
    """True if this arm is known to stall rather than run; reason available in KNOWN_STALL."""
    return arm in KNOWN_STALL
