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

CYC_PER_MAC = {"fp16": 2.911e-4, "fp32": 7.150e-4}
SEC_PER_CYCLE = 1.15


def projected_hours(arm, sec_per_cycle=SEC_PER_CYCLE):
    """arm like 'fp16_1024x256x512' -> projected wall hours, or None if unparseable."""
    m = re.match(r"^(fp16|fp32)_(\d+)x(\d+)x(\d+)$", arm or "")
    if not m:
        return None
    pr, M, N, P = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
    return M * N * P * CYC_PER_MAC[pr] * sec_per_cycle / 3600.0


def fits(arm, deadline_s=172800, margin=0.85):
    """True if the arm is projected to finish inside the deadline with margin to spare.

    margin < 1 because the projection uses medians: an arm at the slow end of the spread needs
    headroom, and a run killed at the deadline delivers NOTHING, so the asymmetry favours caution.
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
import csv as _csv
import os as _os

_ROOT = _os.path.dirname(_os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
_TSV = _os.path.join(_ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")


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
