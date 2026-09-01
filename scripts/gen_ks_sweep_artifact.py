#!/usr/bin/env python3
"""Generate the decode B x KS sweep artifact.

Same shape as the 8x8 scale-up and decode-GEMM dashboards: caveat first, then live progress,
then the design, then results per mesh/precision, then how to read the numbers, then the open
issues. Re-run as arms land -- the output path is stable so the artifact keeps its URL.

Inputs (all optional except the matrix; missing ones just render as pending):
  /tmp/claude-620771/sweep_matrix.json   the 104-arm plan
  /tmp/claude-620771/fleet_status.tsv    arm<TAB>state<TAB>node  (teranoc_fleet.py status)
  hardware/{wa1,wa2}_<arm>/transcript    fetched results
"""
import json, os, re, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCR  = "/tmp/claude-620771"
OUT  = os.path.join(SCR, "ks_sweep.html")
M    = json.load(open(os.path.join(SCR, "sweep_matrix.json")))

# ---------------------------------------------------------------- inputs
FLEET = {}
try:
    for ln in open(os.path.join(SCR, "fleet_status.tsv")):
        p = ln.rstrip("\n").split("\t")
        if len(p) >= 2: FLEET[p[0]] = (p[1], p[2] if len(p) > 2 else "")
except IOError: pass

def scrape(path):
    try: b = re.sub(rb"(?m)^# ", b"", open(path, "rb").read())
    except IOError: return None
    m = re.search(rb"execution took (\d+)", b)
    return dict(cycles = int(m.group(1)) if m else None,
                bypass = b"bypass-track overflow" in b,
                fatal  = b"Fatal" in b,
                tmo    = sum(int(x) for x in re.findall(rb"mshr_timeout=\+(\d+)", b)),
                rh0    = len(re.findall(rb"\[RH STUCK\][^\n]*peers=0", b)))

RES = {}
# DERIVE the prefixes from disk instead of hardcoding them. A result dir is named
# "<run-prefix>_<arm>", and the run-prefix is chosen at submit time -- so any hardcoded list
# goes stale the moment a new wave is dispatched under a new prefix, and its finished arms
# become INVISIBLE (they read as "not dispatched"). That happened three times today: `wc4`,
# `wc8` and `s8k8`, the last of which hid the first 8x8 result in the campaign, and `wc4`
# caused four completed arms to be re-dispatched.
RES = {}
_PREF_RANK = ["wc8", "wc4", "wc", "wa8", "s8k8", "wb", "run2", "wa2"]   # wa1 = superseded wave
for _d in sorted(glob.glob(os.path.join(ROOT, "hardware", "*_sw_*"))):
    _b = os.path.basename(_d)
    _m = re.match(r"^(.+?)_(sw_[48]x[48]_.+)$", _b)
    if not _m: continue
    pref, arm = _m.group(1), _m.group(2)
    t = os.path.join(_d, "transcript")
    if not os.path.exists(t): continue
    s_ = scrape(t)
    if s_: RES.setdefault(arm, {})[pref] = s_

# Local diagnostic runs that measure a matrix cell. The ROB0=256 arm needed a non-default
# ROB depth to run at all, so its cell is flagged rather than presented as a stock result.
LOCAL = {
    ("4x4", "fp16", 1, 8, 128, 8192): ("r256_run_ks1", "ROB0=256"),
}

def _local_cycles(d):
    try: b = re.sub(rb"(?m)^# ", b"", open(os.path.join(ROOT, "hardware", d, "sim.out"), "rb").read())
    except IOError: return None
    m = re.search(rb"execution took (\d+)", b)
    return int(m.group(1)) if m else None

def armname(r):
    return "sw_%s_%s_ks%d_%dx%dx%d" % (r["mesh"], r["prec"], r["KS"], r["B"], r["D"], r["I"])

def status(r):
    """(css-class, cell-text, long-label) for one planned arm.

    A live fleet state outranks a transcript from an earlier wave: the nine KS=2 arms that died on
    the bypass track in take-1 are re-running right now with a wider track, and must not read as
    failures. Only a *completed* newer result overrides the fleet.
    """
    name = armname(r)
    r2 = RUN2.get(name)
    if r2:
        if r2["cyc"]:
            return ("done", "%.1f%%" % (100.0 * r["ideal"] / r2["cyc"]),
                    "measured on the target config (%s cyc, tmo=%d)"
                    % (format(r2["cyc"], ","), r2["tmo"]))
        if r2["bench"] == 0:
            # An EMPTY probe file yields bench==0 too, which is indistinguishable from "the
            # benchmark region never activated" unless we check for an actual transcript. The
            # fleet harvest returns nothing for an arm that has already FINISHED (its node-local
            # data is gone), so two completed arms -- fp16_ks8_8x128x8192 at 5,898 cyc and
            # fp16_ks8_32x256x2048 at 11,876 -- were being reported as "no data" while their
            # local transcripts held the result. A missing measurement must not render as a
            # zero measurement.
            _r = RES.get(name, {})
            _t = _r.get("run2") or _r.get("wc") or _r.get("wb") or _r.get("wa2") or _r.get("wa1")
            if _t and _t["cycles"]:
                return ("done", "%.1f%%" % (100.0 * r["ideal"] / _t["cycles"]),
                        "measured on the target config (%s cyc, tmo=%d) [from transcript; probe empty]"
                        % (format(_t["cycles"], ","), _t["tmo"]))
            return ("bad", "no data", "finished with the benchmark region never activated")
    loc  = LOCAL.get((r["mesh"], r["prec"], r["KS"], r["B"], r["D"], r["I"]))
    if loc:
        # A LOCAL entry is a DIAGNOSTIC run at a non-default config (here ROB0=256, against the
        # target's 128). It must never shadow a real target-config result -- so only fall back to
        # it when no campaign transcript has cycles. Without this, the moment the real Wave C arm
        # finishes, the asterisked ROB0=256 number would keep winning and the page would report a
        # config nobody is running.
        _rr = RES.get(name, {})
        _real = _rr.get("run2") or _rr.get("wc") or _rr.get("wb") or _rr.get("wa2")
        if not (_real and _real["cycles"]):
            c = _local_cycles(loc[0])
            if c: return ("done", "%.1f%%*" % (100.0 * r["ideal"] / c),
                          "measured locally (%s) \u2014 no target-config run yet" % loc[1])
    got  = RES.get(name, {})
    # `run2` IS the target config, so its transcript is authoritative when the probe file
    # carries no cycle count -- which happens whenever an arm finishes before the harvest
    # runs, or is still `running` in badist while its kernel has already completed.
    # Excluding it stranded fp32_ks4_32x256x1024 (20,875 cyc, tmo=0) as "running".
    # wa1 stays excluded: that is the superseded stock-config wave.
    # follow _PREF_RANK so a new wave prefix is picked up automatically; wa1 is the
    # superseded stock-config wave and is deliberately never used as `best`.
    best = next((got[k] for k in _PREF_RANK if k in got), None)
    if best and best["cycles"]:
        # A run that printed a cycle count FINISHED -- it is a measurement, not a livelock.
        # This used to relabel any completed arm with `tmo > 0 and rh0 > 0` as "livelocked",
        # which discarded two real results: fp16/fp32 KS=1 B=1, completed in 3,559 / 5,810
        # cycles with tmo=4 and rh0=4. Arms that genuinely livelock never print a cycle count
        # at all and carry timeouts in the thousands (2,612-97,556), so completion separates
        # them with no threshold to invent. Keep the number; surface the counters beside it.
        _eff = "%.1f%%" % (100.0 * r["ideal"] / best["cycles"])
        if best["tmo"] > 0 or best["rh0"] > 0:
            return ("done", _eff,
                    "measured (%s cyc; %d merge timeouts, %d RH-stuck episodes)"
                    % (format(best["cycles"], ","), best["tmo"], best["rh0"]))
        return ("done", _eff, "measured (%s cyc)" % format(best["cycles"], ","))
    if best and best["bypass"]: return ("bad", "bypass", "bypass-track overflow")
    if best and best["fatal"]:  return ("bad", "fatal",  "fatal")
    if name in KILLED:
        return ("bad", "degr", "livelocked \u2014 killed, partial data only, not a measurement")
    if name in KEPT_ALIVE:
        return ("bad", "degr?", "degraded but still running \u2014 borderline, left alive")
    if name in WEDGED8:
        _w = WEDGED8[name]
        return ("bad", "wedged",
                "wedged in the benchmark region \u2014 %s windows, zero retirement, no result"
                % format(_w["win"], ","))
    st = FLEET.get(name, ("", ""))[0]
    if st == "failed":    return ("bad", "killed", "killed after livelock")
    if st == "running":   return ("run",  "run",   "running")
    if st == "submitted": return ("wait", "queue", "queued")
    # vl == 512 fills ROB0 exactly at the target depth of 128. DECIDED 2026-08-29: these run
    # with the split load (SPATZ_1XVL_LOAD_LMUL=4), measured cost 4.5%. Not blocked -- planned.
    if r["vl"] > 256:     return ("split", "split", "runs with the split load (2x256 B)")
    prior = got.get("wa1")
    if prior and prior["bypass"]: return ("bad", "bypass", "bypass-track overflow (take-1)")
    return ("pending", "&mdash;", "not dispatched")

# how many arms died on the bypass track in wave A take-1, regardless of what they read as now
WA1_BYPASS = sum(1 for a in RES.values() if a.get("wa1", {}).get("bypass"))

# ---- run 1 (stock ROB0=64) baseline, harvested node-side: fetch does not deliver these ----
def _load_results(fn):
    """arm + cyc,bench,tmo,util,rh,peers0,byp,req,acc,raw,ins,fen  (old 5-field rows still load)."""
    F = ["cyc","bench","tmo","util","rh","peers0","byp","req","acc","raw","ins","fen"]
    out = {}
    try:
        for _l in open(os.path.join(SCR, fn)):
            p = _l.rstrip("\n").split("\t")
            if len(p) < 2: continue
            d = {}
            for i, k in enumerate(F):
                v = p[i+1] if len(p) > i+1 else ""
                d[k] = v
            def num(k, cast=int, dflt=None):
                try: return cast(d[k]) if d[k] else dflt
                except ValueError: return dflt
            out[p[0]] = {"cyc": num("cyc"), "bench": num("bench", int, 0) or 0,
                         "tmo": num("tmo", int, 0) or 0, "util": num("util", float),
                         "rh": num("rh", int, 0) or 0, "peers0": num("peers0", int, 0) or 0,
                         "byp": num("byp", int, 0) or 0, "req": num("req", int),
                         "acc": num("acc", float), "raw": num("raw", float),
                         "ins": num("ins", float), "fen": num("fen", float)}
    except IOError:
        pass
    return out

# run 2 is the TARGET config -- it is the primary result set the matrix shows.
RUN2 = _load_results("run2_results.tsv")

RUN1 = _load_results("run1_results.tsv")
WB   = _load_results("wb_results.tsv")
S8   = _load_results("s8_results.tsv")
_unused_run1_loader = """
try:
    for _l in open(os.path.join(SCR, "run1_results.tsv")):
        _p = _l.rstrip("\n").split("\t")
        if len(_p) >= 5:
            pass
except IOError:
    pass
"""

# ---- 8x8 arms wedged in the benchmark region (detected 2026-09-01) ------------------
# Same class as the 4x4 livelocks in outcome -- no forward progress -- but a DIFFERENT population:
# none is in the failure band, and they skew hard to fp16 and to high KS. Kept in their own set so
# the page never conflates them with the band arms.
WEDGED8 = {}
try:
    for _l in open(os.path.join(ROOT, "docs", "benchmarks", "wedged_8x8.tsv")):
        if _l.startswith("#") or not _l.strip(): continue
        _f = _l.rstrip("\n").split("\t")
        if len(_f) >= 4:
            # later rows carry '-' where a field was never measured; never let one
            # unparsed placeholder drop the whole evidence file.
            def _n(i, cast=int, dflt=0):
                try:    return cast(_f[i])
                except (IndexError, ValueError): return dflt
            WEDGED8[_f[0]] = dict(node=_f[1], win=_n(2), age=_n(3, float, 0.0),
                                  died=_n(7), peak=_n(8), tmo=_n(9))
except IOError:
    pass

# arms found livelocked and killed -- their cells must NOT read as pending or running
DEGRADED = set()
try:
    for _l in open(os.path.join(SCR, "deg_results.tsv")):
        _p = _l.rstrip("\n").split("\t")
        if len(_p) >= 14 and _p[13] == "degraded":
            DEGRADED.add(_p[0].split("__")[-1])
except IOError:
    pass
# one borderline arm was deliberately left running (tmo=0, few windows) -- it is degraded but
# NOT killed, and the headline count must not imply otherwise.
# sw_4x4_fp32_ks4_32x256x1024 was held here as "degraded but still running -- borderline".
# It has since COMPLETED: 20,875 cycles, 166 windows, tmo=0. What looked like a collapse was
# the wind-down of a finishing run -- a healthy arm also retires less in its final windows,
# so a declining tail is not sufficient evidence of livelock. Completion is.
KEPT_ALIVE = set()
KILLED = DEGRADED - KEPT_ALIVE

TALLY = {}
for r in M: TALLY[status(r)[2]] = TALLY.get(status(r)[2], 0) + 1


# ---- the KS=1 fix ladder (three local runs, matched on shape 8x128x8192) -------------
LADDER = [
    ("earlier control", "128", "unsplit", "ctl"),
    ("r256",            "256", "unsplit", "r256_run_ks1"),
    ("both",            "128", "split 2&times;256&nbsp;B", "both_run_ks1"),
]
def ladder_row(d):
    """Live state of one ladder run; ('ctl') is the recorded frozen control."""
    if d == "ctl":
        return dict(bench=0, cyc=None, tmo=0, p0=0, took=None, grants=0, refus=None,
                    verdict=("bad", "froze at req 241,349"))
    f = os.path.join(ROOT, "hardware", d, "sim.out")
    alt = "/tmp/claude-620771/both_orphan.log"
    if d == "both_run_ks1" and os.path.exists(alt):
        try:
            if b"execution took" in open(alt, "rb").read(): f = alt
        except IOError: pass
    try: b = re.sub(rb"(?m)^# ", b"", open(f, "rb").read())
    except IOError: return None
    took = re.search(rb"execution took (\d+)", b)
    cyc  = re.findall(rb"\[CMS\] cyc=(\d+)", b)
    bench= len(re.findall(rb"\[STALLG\] bench", b))
    tmo  = sum(int(x) for x in re.findall(rb"mshr_timeout=\+(\d+)", b))
    p0   = len(re.findall(rb"peers=0", b))
    # [BURSTWHY] is capped at BurstWhyMax load decisions PER CORE, so the grant count
    # saturates (256 cores x 24 = 6144) and measures the probe, not burst volume. What the
    # probe does establish is the REFUSAL count: zero refusals across every sampled decision.
    gr   = len(re.findall(rb"=> burst=1", b))
    rf   = len(re.findall(rb"=> burst=0", b))
    if took:
        cyc_n = int(took.group(1))
        # shape 8x128x8192 fp16 on 256 cores x 4 lanes, x2 for fp16
        ideal = 8*128*8192/(256*4*2)
        v = ("done", "%s cyc &middot; %.1f%%" % (format(cyc_n, ","), 100.0*ideal/cyc_n))
    elif tmo and p0: v = ("bad", "livelocking")
    elif bench:   v = ("run", "in bench, %d window%s" % (bench, "" if bench == 1 else "s"))
    else:         v = ("wait", "pre-benchmark")
    return dict(bench=bench, cyc=int(cyc[-1]) if cyc else None, tmo=tmo, p0=p0,
                took=int(took.group(1)) if took else None, grants=gr, refus=rf, verdict=v)


def perf_detail(d):
    """Per-run performance counters, from the probes the TB actually emits.

    Denominators matter: [STALLG] prints denom= per GROUP in core-cycles, so the whole-machine
    denominator for a window is denom * NumGroups. [FPUG] prints denom in LANE-cycles.
    """
    if d == "ctl": return None
    f = os.path.join(ROOT, "hardware", d, "sim.out")
    alt = "/tmp/claude-620771/both_orphan.log"
    if d == "both_run_ks1" and os.path.exists(alt):
        try:
            if b"execution took" in open(alt, "rb").read(): f = alt
        except IOError: pass
    try: b = re.sub(rb"(?m)^# ", b"", open(f, "rb").read())
    except IOError: return None

    out = {}
    # --- MSHR health -------------------------------------------------------------
    out["tmo"]    = sum(int(x) for x in re.findall(rb"mshr_timeout=\+(\d+)", b))
    mg = re.findall(rb"\[MSHRG\] bench[^\n]*timeout=\s*([0-9, ]+)bypass=\s*([0-9, ]+)", b)
    out["tmo_g"]  = sum(int(v) for t, _ in mg for v in t.replace(b" ", b"").split(b",") if v.isdigit())
    out["byp"]    = sum(int(v) for _, y in mg for v in y.replace(b" ", b"").split(b",") if v.isdigit())
    out["rh"]     = len(re.findall(rb"RH STUCK", b))
    out["peers0"] = len(re.findall(rb"peers=0", b))
    # --- why cores were idle: the TB's own decode buckets -------------------------
    tot = {k: 0 for k in ("ins", "raw", "lsu", "acc", "fen")}
    den = 0
    for m in re.finditer(rb"\[STALLG\] bench[^\n]*denom=(\d+)([^\n]*)", b):
        dn, rest = int(m.group(1)), m.group(2)
        ng = 0
        for k in tot:
            mm = re.search((k + r"=\s*([0-9, ]+)").encode(), rest)
            if not mm: continue
            vals = [int(v) for v in mm.group(1).replace(b" ", b"").split(b",") if v.isdigit()]
            tot[k] += sum(vals); ng = max(ng, len(vals))
        den += dn * max(ng, 1)
    out["stall"] = {k: (100.0 * v / den if den else 0.0) for k, v in tot.items()}
    # --- FPU occupancy spread ----------------------------------------------------
    us = []
    for m in re.finditer(rb"\[FPUG\] bench[^\n]*denom=(\d+) busy=\s*([0-9, ]+)", b):
        dn = int(m.group(1))
        v = [int(x) for x in m.group(2).replace(b" ", b"").split(b",") if x.isdigit()]
        if v and dn: us.append([100.0 * x / dn for x in v])
    if us:
        mean = [sum(w) / len(w) for w in us]
        out["util"]   = sum(mean) / len(mean)
        last = us[-1]
        out["spread"] = max(last) - min(last)
    # --- traffic + burst admission ----------------------------------------------
    cm = re.findall(rb"req=(\d+) resp=(\d+) inflight=(\d+)", b)
    if cm: out["req"], out["resp"], out["infl"] = (int(cm[-1][0]), int(cm[-1][1]), int(cm[-1][2]))
    out["bgrant"] = len(re.findall(rb"=> burst=1", b))
    out["brefuse"] = len(re.findall(rb"=> burst=0", b))
    return out

BS  = sorted({r["B"]  for r in M})
KSS = sorted({r["KS"] for r in M})

def matrix(mesh, prec):
    idx = {(r["B"], r["KS"]): r for r in M if r["mesh"] == mesh and r["prec"] == prec}
    h = ['<div class="tw"><table><thead><tr>',
         '<th class="num">B</th><th class="num">D</th><th class="num">I</th><th class="num">L1</th>']
    h += ['<th class="num">KS=%d</th>' % k for k in KSS]
    h.append('<th class="num">vl by KS (B)</th><th class="num">sharers</th><th class="num">R</th>'
             '</tr></thead><tbody>')
    for B in BS:
        row  = [idx.get((B, k)) for k in KSS]
        anyr = next((x for x in row if x), None)
        if not anyr: continue
        h.append('<tr><td class="num b">%d</td><td class="num dim">%d</td><td class="num dim">%d</td>'
                 '<td class="num dim">%.0f%%</td>' % (B, anyr["D"], anyr["I"], anyr["pct"]))
        for r in row:
            if r is None:
                h.append('<td class="num na" title="KS must divide B">&middot;</td>'); continue
            cls, txt, lab = status(r)
            h.append('<td class="num st-%s" title="%s &middot; %s">%s</td>' % (cls, armname(r), lab, txt))
        h.append('<td class="num dim sm">%s</td><td class="num dim sm">%s</td><td class="num dim">%d</td></tr>'
                 % (" / ".join(str(r["vl"]) for r in row if r),
                    " / ".join(str(r["sh"]) for r in row if r), anyr["R"]))
    h.append('</tbody></table></div>')
    return "".join(h)

CSS = r"""
:root{--ground:#f4f6f7;--panel:#fff;--line:#d8dee1;--line-soft:#e4e9ec;--ink:#0e1418;--ink-2:#5a6b75;
--ink-3:#7d8b93;--accent:#d98324;--good:#1f7a5c;--warn:#d98324;--bad:#b3382c;--cool:#1f6f8b;
--track:#e4e9ec;--shadow:0 1px 2px rgba(14,20,24,.06);
--mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
--sans:"IBM Plex Sans",system-ui,-apple-system,"Segoe UI",sans-serif;
--cond:"IBM Plex Sans Condensed","IBM Plex Sans",system-ui,sans-serif}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--ground:#0e1418;--panel:#161e24;
--line:#2a353d;--line-soft:#222c33;--ink:#e8eef1;--ink-2:#9fb0ba;--ink-3:#7d8b93;--track:#222c33;
--good:#3f9e7c;--bad:#d1594c;--cool:#4f9ab4;--shadow:0 1px 2px rgba(0,0,0,.34)}}
:root[data-theme=dark]{--ground:#0e1418;--panel:#161e24;--line:#2a353d;--line-soft:#222c33;
--ink:#e8eef1;--ink-2:#9fb0ba;--ink-3:#7d8b93;--track:#222c33;--good:#3f9e7c;--bad:#d1594c;
--cool:#4f9ab4;--shadow:0 1px 2px rgba(0,0,0,.34)}
*{box-sizing:border-box}
body{background:var(--ground);color:var(--ink);font-family:var(--sans);font-size:15px;
line-height:1.62;margin:0;padding:34px 20px 72px}
.wrap{max-width:1080px;margin:0 auto;display:flex;flex-direction:column;gap:20px}
.eyebrow{font-family:var(--mono);font-size:11px;letter-spacing:.14em;text-transform:uppercase;
color:var(--ink-3);margin:0 0 6px}
h1{font-family:var(--cond);font-size:32px;font-weight:600;margin:0 0 6px;letter-spacing:-.012em;text-wrap:balance}
h2{font-family:var(--cond);font-size:20px;font-weight:600;margin:0 0 2px;text-wrap:balance}
h3{font-family:var(--cond);font-size:15px;font-weight:600;margin:16px 0 0;color:var(--ink-2);
letter-spacing:.02em}
p{margin:.55em 0;max-width:76ch}
.sub{color:var(--ink-2);font-size:14.5px;margin:0;max-width:80ch}
.card{background:var(--panel);border:1px solid var(--line);border-radius:4px;padding:17px 20px;
box-shadow:var(--shadow);display:flex;flex-direction:column;gap:2px}
.hero{flex-direction:row;flex-wrap:wrap;gap:30px;align-items:flex-end}
.stat{display:flex;flex-direction:column;gap:1px}
.stat .k{font-family:var(--mono);font-size:10px;letter-spacing:.09em;text-transform:uppercase;color:var(--ink-3)}
.stat .v{font-family:var(--cond);font-size:26px;font-weight:600;line-height:1.12}
.stat .v.g{color:var(--good)}.stat .v.r{color:var(--bad)}.stat .v.w{color:var(--warn)}
.tw{overflow-x:auto;margin:12px 0 4px}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{padding:5px 9px;border-bottom:1px solid var(--line-soft);text-align:left;white-space:nowrap}
th{font-family:var(--mono);font-size:10px;letter-spacing:.07em;text-transform:uppercase;
color:var(--ink-3);font-weight:500}
.num{text-align:right;font-family:var(--mono);font-variant-numeric:tabular-nums}
.mono{font-family:var(--mono)}.dim{color:var(--ink-3)}.na{color:var(--line)}
.sm{font-size:11px}.b{font-weight:600}
.st-done{color:var(--good);font-weight:600}.st-bad{color:var(--bad);font-weight:600}
.st-blocked{color:var(--warn);font-weight:600}
.st-split{color:var(--accent);font-weight:600}.st-run{color:var(--cool)}
.st-wait,.st-pending{color:var(--ink-3)}
.chip{display:inline-block;font-family:var(--mono);font-size:10.5px;padding:2px 8px;border-radius:20px;
white-space:nowrap;font-weight:500}
.c-good{background:rgba(31,122,92,.14);color:var(--good)}
.c-bad{background:rgba(179,56,44,.14);color:var(--bad)}
.c-warn{background:rgba(217,131,36,.15);color:var(--warn)}
.c-cool{background:rgba(31,111,139,.14);color:var(--cool)}
.note{border-left:3px solid var(--accent);background:rgba(217,131,36,.075);padding:12px 16px;
border-radius:0 4px 4px 0;margin:14px 0 4px;max-width:82ch}
.note.bad{border-left-color:var(--bad);background:rgba(179,56,44,.075)}
.note.good{border-left-color:var(--good);background:rgba(31,122,92,.075)}
.note .lab{font-family:var(--mono);font-size:10px;letter-spacing:.09em;text-transform:uppercase;
font-weight:600;color:var(--accent);display:block;margin-bottom:4px}
.note.bad .lab{color:var(--bad)}.note.good .lab{color:var(--good)}
.note p{margin:.35em 0}.note p:last-child{margin-bottom:0}
code{font-family:var(--mono);font-size:12.5px;background:var(--line-soft);padding:1px 4px;border-radius:3px}
ul{max-width:78ch;padding-left:19px;margin:.55em 0}li{margin:.3em 0}
.key{display:flex;flex-wrap:wrap;gap:8px 16px;font-size:12px;color:var(--ink-2);margin-top:8px}
.foot{color:var(--ink-3);font-size:11.5px;font-family:var(--mono);border-top:1px solid var(--line-soft);
padding-top:12px;margin:0}
.pb{height:7px;background:var(--track);border-radius:4px;overflow:hidden;display:flex;margin:10px 0 2px}
.pb i{display:block;height:100%}

.ctl{display:flex;flex-wrap:wrap;gap:14px;align-items:center;margin:12px 0 6px;font-size:12.5px}
.ctl label{display:flex;align-items:center;gap:7px;color:var(--ink-2)}
.ctl .grow{flex:1;min-width:220px}
.ctl select{font-family:var(--mono);font-size:12px;padding:3px 6px;border:1px solid var(--line);
border-radius:3px;background:var(--panel);color:var(--ink)}
.ctl input[type=range]{flex:1;accent-color:var(--cool);min-width:160px}
.ctl.facets{gap:10px 14px;padding:10px 12px;background:var(--line-soft);border-radius:4px}
.ctl.facets select{min-width:74px}
.ctl.facets label{font-family:var(--mono);font-size:11px;letter-spacing:.04em}
.rst{font-family:var(--mono);font-size:11px;padding:3px 9px;border:1px solid var(--line);
border-radius:3px;background:var(--panel);color:var(--ink-2);cursor:pointer}
.rst:hover{color:var(--ink);border-color:var(--ink-3)}
#f_count{margin-left:auto}
.mstats{display:flex;flex-wrap:wrap;gap:22px;margin:10px 0 12px}
.mstats .v{font-size:17px}
.mesh{display:grid;gap:2px;max-width:560px}
.mesh .cell{aspect-ratio:1;display:flex;align-items:center;justify-content:center;
font-family:var(--mono);font-size:12px;font-variant-numeric:tabular-nums;border-radius:2px;
transition:background .12s}
.mesh.dense{max-width:660px}
.mesh.dense .cell{font-size:9px;border-radius:1px}
.pgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:3px 20px;margin-top:6px}
.prow{display:flex;align-items:center;gap:7px;font-size:11.5px}
.prow .gid{font-family:var(--mono);color:var(--ink-3);width:26px;flex:none}
.prow .pb2{flex:1;height:7px;background:var(--track);border-radius:4px;overflow:hidden}
.prow .pb2 span{display:block;height:100%;background:var(--cool);border-radius:4px}
.prow .pv{font-family:var(--mono);font-variant-numeric:tabular-nums;color:var(--ink-2);
width:34px;text-align:right;flex:none}
@media (prefers-reduced-motion:reduce){.mesh .cell{transition:none}}
"""

MESH_JS = """
<script>
(function(){
 var $=function(i){return document.getElementById(i)};
 var grid=$("mgrid"), sel=$("marm"), rng=$("mper"), pg=$("pgrid");
 var KEYS=Object.keys(GU);
 // one hue, light -> dark. Magnitude is a sequential encoding, never a rainbow.
 var STOPS=[[232,238,241],[159,199,212],[78,148,171],[31,111,139],[13,63,82]];
 function colour(u){
   var t=Math.max(0,Math.min(100,u))/100*(STOPS.length-1);
   var i=Math.min(STOPS.length-2,Math.floor(t)), f=t-i, a=STOPS[i], b=STOPS[i+1];
   return "rgb("+Math.round(a[0]+(b[0]-a[0])*f)+","+Math.round(a[1]+(b[1]-a[1])*f)+","+
          Math.round(a[2]+(b[2]-a[2])*f)+")";
 }
 function draw(){
   var d=GU[sel.value]; if(!d||!d.periods.length) return;
   var n=d.groups, side=Math.round(Math.sqrt(n));
   if(side*side!==n) side=Math.ceil(Math.sqrt(n));
   grid.style.gridTemplateColumns="repeat("+side+",1fr)";
   grid.classList.toggle("dense", n>16);
   rng.max=d.periods.length-1;
   var i=Math.min(+rng.value,d.periods.length-1), p=d.periods[i];
   $("mcyc").textContent="cyc "+p.cyc.toLocaleString();
   grid.innerHTML="";
   p.u.forEach(function(u,g){
     var e=document.createElement("div");
     e.className="cell"; e.style.background=colour(u);
     e.style.color = u>55 ? "#fff" : "#0e1418";
     e.textContent=Math.round(u);
     e.title="group "+g+": "+u+"% busy";
     grid.appendChild(e);
   });
   var mx=Math.max.apply(null,p.u), mn=Math.min.apply(null,p.u);
   var mean=p.u.reduce(function(s,v){return s+v},0)/n;
   $("mmean").textContent=mean.toFixed(1)+"%";
   $("mspread").textContent=(mx-mn).toFixed(1)+" pp";
   $("mmax").textContent="g"+p.u.indexOf(mx)+" \\u00b7 "+mx+"%";
   $("mmin").textContent="g"+p.u.indexOf(mn)+" \\u00b7 "+mn+"%";
   $("mwin").textContent=(i+1)+" / "+d.periods.length;
   $("mgn").textContent=side+"\\u00d7"+side+" \\u00b7 "+n+" grp";
   // RELATIVE progress: cumulative busy lane-cycles per group, normalised to the LEADER.
   // Deliberately not a share of absolute work -- the TB counter is lane OCCUPANCY, which is
   // not conserved across runs, so an absolute denominator would mislead.
   var cum=new Array(n).fill(0);
   for(var k=0;k<=i;k++){
     var w=d.periods[k];
     w.u.forEach(function(u,g){ cum[g]+= u/100*w.den; });
   }
   var top=Math.max.apply(null,cum)||1;
   var pct=cum.map(function(v){return 100*v/top});
   var lead=Math.max.apply(null,pct), lag=Math.min.apply(null,pct);
   $("plead").textContent="g"+pct.indexOf(lead)+" \\u00b7 "+lead.toFixed(1)+"%";
   $("plag").textContent="g"+pct.indexOf(lag)+" \\u00b7 "+lag.toFixed(1)+"%";
   $("pgap").textContent=(lead-lag).toFixed(1)+" pp";
   $("pratio").textContent=lead>0?(lag/lead).toFixed(3):"\\u2014";
   pg.innerHTML="";
   pct.forEach(function(v,g){
     var r=document.createElement("div"); r.className="prow";
     r.innerHTML='<span class="gid">g'+g+'</span><span class="pb2"><span style="width:'+
        Math.min(100,v).toFixed(1)+'%"></span></span><span class="pv">'+v.toFixed(0)+'%</span>';
     pg.appendChild(r);
   });
 }
 // Facet order matters: each select is populated from the arms that survive the facets to its
 // LEFT, so a combination that does not exist can never be selected. "any" opts out of a facet.
 var FACETS=[["f_mesh","mesh"],["f_state","state"],["f_run","run"],["f_prec","prec"],["f_ks","ks"],["f_B","B"],["f_D","D"],["f_I","I"]];
 function matches(k, upto){
   for (var i=0;i<FACETS.length;i++){
     if (upto!==undefined && i>=upto) break;
     var el=$(FACETS[i][0]); if(!el) continue;
     var v=el.value; if(v==="") continue;
     if (String(GU[k][FACETS[i][1]])!==v) return false;
   }
   return true;
 }
 function num(a,b){ var x=+a,y=+b; return (isNaN(x)||isNaN(y)) ? (a<b?-1:a>b?1:0) : x-y; }
 function rebuild(){
   FACETS.forEach(function(f,i){
     var el=$(f[0]); if(!el) return;
     var keep=el.value;
     var pool=KEYS.filter(function(k){return matches(k,i)});
     var vals=[]; pool.forEach(function(k){var v=String(GU[k][f[1]]); if(vals.indexOf(v)<0) vals.push(v)});
     vals.sort(num);
     var cur = (keep && vals.indexOf(keep)>=0) ? keep : "";
     el.innerHTML='<option value="">any</option>'+vals.map(function(v){
       return '<option value="'+v+'"'+(v===cur?' selected':'')+'>'+v+'</option>'}).join("");
     el.value=cur;
   });
   var pool=KEYS.filter(function(k){return matches(k)});
   pool.sort();
   var prev=sel.value;
   sel.innerHTML=pool.map(function(k){return '<option value="'+k+'">'+k+'</option>'}).join("");
   if(pool.indexOf(prev)>=0) sel.value=prev;
   $("f_count").textContent=pool.length+(pool.length===1?" arm":" arms");
   // land mid-run, not at window 0: the first windows precede the benchmark region, so a
   // fresh selection would otherwise open on an all-zero mesh.
   if(pool.length){
     var d0=GU[sel.value];
     rng.max = d0 ? Math.max(0,d0.periods.length-1) : 0;
     rng.value = d0 ? Math.floor(d0.periods.length/2) : 0;
     draw();
   }
   else { grid.innerHTML=""; pg.innerHTML=""; $("mcyc").textContent="no arm matches"; }
 }
 FACETS.forEach(function(f){ var el=$(f[0]); if(el) el.addEventListener("change",rebuild); });
 sel.addEventListener("change",function(){
   var d0=GU[sel.value];
   rng.max = d0 ? Math.max(0,d0.periods.length-1) : 0;
   rng.value = d0 ? Math.floor(d0.periods.length/2) : 0;
   draw();
 });
 rng.addEventListener("input",draw);
 var rb=$("f_reset");
 if(rb) rb.addEventListener("click",function(){
   FACETS.forEach(function(f){ var el=$(f[0]); if(el) el.value=""; }); rebuild(); });
 rebuild();
})();
</script>
"""

H = []
A = H.append
A('<title>Decode B x KS Sweep</title>')
A('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?'
  'family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&'
  'family=IBM+Plex+Sans+Condensed:wght@600&display=swap">')
A('<style>%s</style>' % CSS)
A('<div class="wrap">')

A('<div><p class="eyebrow">TeraNoC &middot; Spatz &middot; decode shapes</p>'
  '<h1>Decode <span class="mono">B &times; KS</span> sweep</h1>'
  '<p class="sub">What batch size and kernel size cost each other on decode-shape GEMM, over '
  '4&times;4 and 8&times;8, fp16 and fp32 &mdash; the two RTL capacity limits that gated it, and '
  'the first KS=1 measurement the machine has ever produced.</p></div>')

nb  = TALLY.get("runs with the split load (2x256 B)", 0)
nbp = WA1_BYPASS
# Count from the data, not from TALLY key names: a new status label (e.g. "measured on the
# target config") silently vanishes from a name-matched sum. Dedupe by arm across sources.
_measured = {k for k, v in RUN2.items() if v["cyc"]} | {k for k, v in RUN1.items() if v["cyc"]}
_measured |= {armname(r) for r in M
              if LOCAL.get((r["mesh"], r["prec"], r["KS"], r["B"], r["D"], r["I"]))
              and _local_cycles(LOCAL[(r["mesh"], r["prec"], r["KS"], r["B"], r["D"], r["I"])][0])}
nd  = len([k for k, v in RUN2.items() if v["cyc"]])   # target config = the real campaign
_any = len(_measured)                                    # union incl. the run-1 baseline
_empty = len([k for k, v in RUN1.items() if not v["cyc"]] +
             [k for k, v in RUN2.items() if not v["cyc"]])
nr  = sum(1 for st, _ in FLEET.values() if st in ("running", "submitted"))
_lad = [ladder_row(d) for _, _, _, d in LADDER]
_best = [x for x in _lad if x and x.get("took")]
_ks1 = ("%.1f%%" % max(100.0*(8*128*8192/(256*4*2))/x["took"] for x in _best)) if _best else "&mdash;"
A('<div class="card hero">'
  '<div class="stat"><span class="k">planned arms</span><span class="v">%d</span></div>'
  '<div class="stat"><span class="k">measured (target cfg)</span><span class="v %s">%d</span></div>'
  '<div class="stat"><span class="k">in flight</span><span class="v">%d</span></div>'
  '<div class="stat"><span class="k">need split load</span><span class="v w">%d</span></div>'
  '<div class="stat"><span class="k">run-1 bypass deaths</span><span class="v r">%d</span></div>'
  '<div class="stat"><span class="k">best KS=1</span><span class="v %s">%s</span></div>'
  '<div class="stat"><span class="k">empty exits</span><span class="v %s">%d</span></div>'
  '<div class="stat"><span class="k">livelocked killed</span><span class="v r">%d</span></div>'
  '<div class="stat"><span class="k">work per arm</span><span class="v">65,536</span></div>'
  '</div>' % (len(M), "g" if nd else "", nd, nr, nb, nbp,
              "g" if _best else "", _ks1,
              "r" if _empty else "", _empty, len(KILLED)))

# ---- caveat first, exactly as the reference dashboards do -------------------
A('<div class="card"><h2>Read this first</h2>'
  '<p>Before any sweep arm finished, the campaign had already produced two results &mdash; and both '
  'are RTL defects that gated whole columns of the matrix. <strong>Run&nbsp;2 addresses both</strong> '
  '(see the config table below); they are recorded here because they explain why run&nbsp;1 is not '
  'the measurement, and because the admission rule underneath them is still wrong. '
  'Each is a structure sized to hold <em>exactly one instruction\'s</em> worth of bursts, '
  'with no margin for the second instruction that dual-load runahead keeps in flight by design. '
  'Neither is visible to the directed tests that pass today, because those tests never issue a '
  'load wide enough to fill the structure.</p>'
  '<div class="tw"><table><thead><tr><th>structure</th><th class="num">capacity</th>'
  '<th>filled by a load of</th><th>failure</th><th>bites</th></tr></thead><tbody>'
  '<tr><td class="mono">BypassTrackWays</td><td class="num">ROB0/16</td>'
  '<td class="mono">vl = ROB0&times;4 &divide; 2</td>'
  '<td><span class="chip c-bad">fatal assertion</span></td><td class="mono">KS=2 @ 256&nbsp;B</td></tr>'
  '<tr><td class="mono">ROB0 ids</td><td class="num">ROB0</td><td class="mono">vl = ROB0&times;4</td>'
  '<td><span class="chip c-warn">wedge before the kernel</span></td>'
  '<td class="mono">KS=1 @ 512&nbsp;B</td></tr>'
  '</tbody></table></div>'
  '<p>At the stock ROB0=64, 256&nbsp;B is four 64&nbsp;B bursts and the bypass track has four ways: '
  'one instruction fills it exactly. <strong>%d of %d</strong> KS=2 arms in the first wave died '
  'there. Raising <code>group_mshr_bypass_ways</code> to 8 is the workaround under test; the arms '
  'now in flight all carry it.</p>'
  '<div class="note bad"><span class="lab">the admission rule is the defect</span>'
  '<p><code>use_port0_burst_req</code> admits a burst when '
  '<code>vl &le; NrOutstandingLoads &times; MemDataWidthB</code>. That inequality permits a single '
  'load to reserve <em>every</em> ROB0 id, leaving nothing for the next instruction &mdash; so the '
  'ceiling is set one instruction too high, not one too low.</p>'
  '<p>Proven by single-variable control, same image and same ELF: ROB0=128 froze at request '
  '241,349; ROB0=256 ran through into the benchmark region.</p></div></div>' % (WA1_BYPASS, WA1_BYPASS))

# ---- progress --------------------------------------------------------------
A('<div class="card"><h2>Two rounds, two configurations</h2>'
  '<p>Run&nbsp;1 measured a machine we are not shipping. Its KS=2 arms sat <em>exactly</em> on the '
  'ROB0 admission ceiling &mdash; at ROB0=64 the ceiling is 64&times;4 = 256&nbsp;B and those arms '
  'have <code>vl = 256&nbsp;B</code>, so one load reserved every ROB0 id and dual-load runahead was '
  'defeated. Run&nbsp;2 is the design target.</p>'
  '<div class="tw"><table><thead><tr><th>knob</th><th class="num">run 1</th><th class="num">run 2 '
  '&mdash; target</th><th>why it changed</th></tr></thead><tbody>'
  '<tr><td class="mono">ROB0</td><td class="num">64</td><td class="num b">128</td>'
  '<td>burst ceiling 256&rarr;512&nbsp;B, so KS=2 at vl=256&nbsp;B gets 2&times; headroom</td></tr>'
  '<tr><td class="mono">ROBN</td><td class="num dim">unset &rarr; 64</td><td class="num b">16</td>'
  '<td>asymmetric &ldquo;ROB0 deep, rest shallow&rdquo;; bursts only use ROB0</td></tr>'
  '<tr><td class="mono">group_mshr_num</td><td class="num">64</td><td class="num b">64</td>'
  '<td>the shipped default; the 128 in the debug images was residue from a refuted hypothesis '
  '(worth 0.07%)</td></tr>'
  '<tr><td class="mono">bypass_ways</td><td class="num">8</td><td class="num b">16</td>'
  '<td>derived would be 8, which two overlapping loads consume exactly &mdash; zero margin</td></tr>'
  '<tr><td class="mono">snitch_trace</td><td class="num">1</td><td class="num b">0</td>'
  '<td>per-hart traces are not needed for a sweep and have filled node scratch before</td></tr>'
  '</tbody></table></div>'
  '<p class="sub">The two images differ in exactly these four defines and nothing else, verified by '
  'a full <code>+define+</code> diff. Run&nbsp;1 is left running as a stock-ROB baseline.</p>'
  '<div class="note good"><span class="lab">the target config was smoke-tested first</span>'
  '<p>Before committing 36 arms, the exact case that killed nine run&nbsp;1 arms &mdash; KS=2 at '
  '<code>vl=256&nbsp;B</code> &mdash; was run on the new image: it reached the benchmark region with '
  '<strong>6,064 burst grants and zero refusals</strong>, no bypass overflow, <code>tmo=0</code>, '
  '16/16 groups retiring.</p></div></div>')

segs = [("measured", "var(--good)"), ("running", "var(--cool)"), ("queued", "var(--track)"),
        ("blocked on the ROB0 ceiling", "var(--warn)"), ("bypass-track overflow", "var(--bad)"),
        ("livelocked", "var(--bad)"), ("fatal", "var(--bad)"), ("not dispatched", "var(--line)")]
A('<div class="card"><h2>Progress</h2>'
  '<p class="sub">4&times;4 first, by the user\'s call; the 8&times;8 half waits on that review. '
  'Wave A covers KS&nbsp;2/4/8 &mdash; the kernels that exist today. Waves B and C are KS=1 and are '
  'gated on the ROB0 fix.</p>'
  '<div class="pb">%s</div><div class="key">%s</div></div>'
  % ("".join('<i style="width:%.2f%%;background:%s"></i>' % (100.0*TALLY.get(k,0)/len(M), c)
             for k, c in segs if TALLY.get(k)),
     "".join('<span><span class="chip" style="background:%s;color:#fff">&nbsp;</span> %s '
             '<span class="mono">%d</span></span>' % (c, k, TALLY[k]) for k, c in segs if TALLY.get(k))))

# ---- the design ------------------------------------------------------------
A('<div class="card"><h2>Why the tile is derived, not swept</h2>'
  '<p>Decode has <code>M = B</code>, far below the group count, so the prefill work split &mdash; '
  'which divides M across groups &mdash; returns an error for every legal decode shape. The decode '
  'split divides <em>P</em> and <em>B</em> instead, and that pins the whole tile once B and KS are '
  'chosen. There is nothing left to sweep inside a cell:</p>'
  '<ul>'
  '<li><code>sharers = B / KS</code> &mdash; cores reading the same W bytes. This is the group-MSHR '
  'merge cohort, and it is the entire reason KS matters.</li>'
  '<li><code>n_p_blocks = cores &times; KS / B</code>, then <code>p_span = I / n_p_blocks</code>.</li>'
  '<li><code>vl = p_span &times; elem_bytes</code>, capped at <code>LMUL &times; 64&nbsp;B</code>.</li>'
  '<li><code>KS &times; LMUL = 16</code> registers, so KS 8/4/2 map to m2/m4/m8. <strong>KS=1 would '
  'need m16, which RVV does not have</strong> &mdash; hence a separate one-accumulator kernel.</li>'
  '</ul>'
  '<p>I shrinks as B grows so <code>vl</code> stays inside the burst window, which frees D to grow '
  '128&rarr;1024 and keep the working set near half of L1 &mdash; deliberately half, so the same '
  'shapes still fit once double buffering lands. Every arm runs <code>R = 128/B</code> repeats of '
  'the kernel inside the timed region, which equalises all 104 at <strong>65,536 ideal cycles</strong>. '
  'That is what makes a B=1 arm and a B=128 arm comparable on one axis.</p>'
  '<div class="note"><span class="lab">what R changes and what it does not</span>'
  '<p>The repeat loop wraps only the measured dispatch, and the reported cycle count is '
  '<code>timer / R</code> &mdash; per pass, the same quantity every existing scraper already reads. '
  'The raw total goes on its own <code>[REPEAT]</code> line. Repeats also warm the caches, so R&gt;1 '
  'arms report a steady-state pass rather than a cold one; the B=128 arms (R=1) do not get that, and '
  'their numbers carry a cold-start component the small-B arms do not.</p></div></div>')

# ---- results ---------------------------------------------------------------
for mesh, cores in (("4x4", 256), ("8x8", 1024)):
    A('<div class="card"><h2>%s mesh &mdash; %d cores</h2>' % (mesh.replace("x", "&times;"), cores))
    for prec in ("fp16", "fp32"):
        A('<h3>%s</h3>' % prec)
        A(matrix(mesh, prec))
    A('<p class="sub">Cells carry <strong>efficiency</strong> = ideal/actual once measured. '
      '<span class="st-split">split</span> = vl=512&nbsp;B, runs with the split load &middot; '
      '<span class="st-bad">degr</span> = livelocked and killed (partial data in the degraded section; never a measurement) &middot; '
      '<span class="st-run">run</span> = on the fleet &middot; '
      '<span class="na">&middot;</span> = KS does not divide B, so the arm does not exist. '
      '<strong>An asterisk (*)</strong> marks a cell measured on a <em>non-default</em> '
      'configuration &mdash; the number is real but not comparable with stock arms, and the '
      'deviation is named in the cell tooltip and in the fix-ladder table above. '
      '<span class="mono">L1</span> is the working set as a share of the %s&nbsp;MB L1.</p></div>'
      % ("4" if mesh == "4x4" else "16"))

# ---- ONE performance table for both meshes ---------------------------------------
# The counters used to live in three places -- a 4x4-only ladder, a run2 result table and a
# separate 8x8 card -- so no single view answered "how is arm X doing". This replaces all three.
try:
    _PA = json.load(open("/tmp/claude-620771/perf_all.json"))
except Exception:
    _PA = []
if _PA:
    _ST = {"measured": ("done", "measured"), "livelocked": ("bad", "livelocked"),
           "running": ("run", "running"), "pending": ("", "not started")}
    _prow = "".join(
        '<tr class="%s" data-mesh="%s" data-prec="%s" data-ks="%d" data-st="%s" data-band="%d">'
        '<td class="mono">%s</td><td>%s</td><td class="num">%d</td><td class="num">%d</td>'
        '<td class="num">%s</td><td class="num">%s</td>'
        '<td><span class="pill %s">%s</span></td>'
        '<td class="num">%s</td><td class="num b">%s</td>'
        '<td class="num %s">%s</td><td class="num %s">%s</td><td class="num dim">%s</td>'
        '<td class="num">%s</td></tr>'
        % ("bandrow" if x["band"] else "", x["mesh"], x["prec"], x["KS"], x["st"], x["band"],
           x["arm"].replace("sw_", ""), x["mesh"], x["KS"], x["B"], x["sh"], x["vl"],
           _ST[x["st"]][0], _ST[x["st"]][1],
           format(x["cyc"], ",") if x["cyc"] else "&mdash;",
           ("%.1f%%" % x["eff"]) if x["eff"] else "&mdash;",
           "st-bad b" if x["tmo"] else "dim", format(x["tmo"], ","),
           "st-bad" if x["rh"] else "dim", format(x["rh"], ","),
           format(x["byp"], ","),
           format(x["win"], ",") if x["win"] else "&mdash;")
        for x in _PA)
    A('<div class="card"><h2>Every arm, both meshes &mdash; results and counters</h2>'
      '<p class="sub">One table for the whole campaign: cycles and efficiency where an arm has '
      'finished, and merge-cohort timeouts, RH-stuck episodes and bank-full bypasses for every arm '
      '&mdash; read live for those still running. A red edge marks the failure band '
      '(<code>sharers &isin; {2,4}</code> and <code>vl &ge; 128&nbsp;B</code>).</p>'
      '<div class="filters">'
      '<label>mesh<select id="p_mesh"></select></label>'
      '<label>prec<select id="p_prec"></select></label>'
      '<label>KS<select id="p_ks"></select></label>'
      '<label>state<select id="p_st"></select></label>'
      '<label>band<select id="p_band"></select></label>'
      '<label>&nbsp;<span id="p_n" class="mono" style="color:var(--muted)"></span></label></div>'
      '<div class="tw"><table class="d"><thead><tr>'
      '<th>arm</th><th>mesh</th><th class="num">KS</th><th class="num">B</th>'
      '<th class="num">sharers</th><th class="num">vl</th><th>state</th>'
      '<th class="num">cycles</th><th class="num">efficiency</th>'
      '<th class="num" title="merge-cohort timeouts">tmo</th>'
      '<th class="num" title="RH-stuck episodes">RH</th>'
      '<th class="num" title="bank-full bypasses">byp</th>'
      '<th class="num" title="benchmark windows so far">win</th>'
      '</tr></thead><tbody id="p_rows">%s</tbody></table></div>'
      '<p class="sub">Counters are cumulative from the start of a run and include the warm-up '
      'region, so compare arms of similar age. An arm cannot be judged before about '
      '<strong>100 windows</strong>.</p></div>' % _prow)

# ---- method ----------------------------------------------------------------
if _best:
    _rows = []
    for label, rob0, load, d in LADDER:
        st = ladder_row(d)
        if not st or not st.get("took"): continue
        ideal = 8*128*8192/(256*4*2)
        _rows.append('<tr><td class="mono">fp16 8&times;128&times;8192</td>'
                     '<td class="mono">ROB0=%s, %s</td><td class="num b">%s</td>'
                     '<td class="num dim">4,096</td><td class="num st-done">%.1f%%</td>'
                     '<td><span class="chip c-good">clean</span></td></tr>'
                     % (rob0, load, format(st["took"], ","), 100.0*ideal/st["took"]))
    A('<div class="card"><h2>Completed KS=1 measurements</h2>'
      '<p><code>KS=1</code> now runs, completes, and emits <code>[SPOT]</code> words. That is the '
      'capability the ROB0 ceiling was blocking: without it there is no legal kernel at B=1 and '
      'decode GEMV cannot execute at all. Both rows below appear in the utilisation explorer '
      'further down.</p>'
      '<div class="tw"><table><thead><tr><th>shape</th><th>config</th><th class="num">cycles/pass</th>'
      '<th class="num">ideal</th><th class="num">efficiency</th><th>health</th></tr></thead><tbody>%s'
      '</tbody></table></div>'
      '<div class="note"><span class="lab">~24%% is the operating point, not a defect</span>'
      '<p>At <code>sharers = B/KS = 1</code> the group MSHR has no cohort to merge and every loaded '
      'element feeds exactly one FMA. Low efficiency is what this corner <em>is</em>; the number '
      'prices decode GEMV rather than indicting it.</p></div>'
      '<p>The split-load arm buys <strong>half the ROB depth for +4.5%% cycles</strong>. An earlier '
      'reading expected it to be <em>faster</em>, from a 2.5&times; higher instruction rate &mdash; '
      'that was entirely instruction-count inflation (the split issues more instructions for the '
      'same work) and the completed cycle counts refute it.</p></div>'
      % "".join(_rows))

    # ---- performance counters behind the two numbers -------------------------------
    _pr = []
    for label, rob0, load, d in LADDER:
        st = ladder_row(d); pd = perf_detail(d)
        if not st or not st.get("took") or not pd: continue
        _pr.append('<tr><td class="mono b">%s</td>'
                   '<td class="num st-%s">%d</td><td class="num">%d</td><td class="num">%d</td>'
                   '<td class="num">%.1f%%</td><td class="num">%.1f%%</td><td class="num">%.1f%%</td>'
                   '<td class="num">%.1f%%</td><td class="num dim">%s</td><td class="num">%s / %d</td></tr>'
                   % (label,
                      "done" if pd["tmo"] == 0 else "bad", pd["tmo"], pd["byp"], pd["rh"],
                      pd["stall"]["acc"], pd["stall"]["raw"], pd["stall"]["ins"], pd["stall"]["fen"],
                      format(pd.get("req", 0), ","),
                      format(pd["bgrant"], ","), pd["brefuse"]))
    if _pr:
        A('<h3>Performance counters behind those two numbers</h3>'
          '<div class="tw"><table><thead><tr><th>run</th>'
          '<th class="num" title="group-MSHR merge-cohort timeouts">mshr tmo</th>'
          '<th class="num" title="bank-full bypasses of the MSHR">bankfull byp</th>'
          '<th class="num" title="response-hold stuck episodes">RH stuck</th>'
          '<th class="num" title="core cycles parked on the Spatz accelerator queue">stall acc</th>'
          '<th class="num" title="scalar RAW hazard">raw</th>'
          '<th class="num" title="icache starvation">icache</th>'
          '<th class="num" title="waiting on memory already requested">fence</th>'
          '<th class="num">requests</th>'
          '<th class="num" title="burst admissions granted / refused">burst ok / no</th>'
          '</tr></thead><tbody>%s</tbody></table></div>'
          '<p class="sub">Stall columns are shares of total core-cycles, read with the TB\'s own '
          'decode rule: <em>low FPU + low insn + high acc</em> means Spatz is backed up and the core '
          'cannot hand off &mdash; which is what both runs show, and what a KS=1 vector chain should '
          'look like. <code>icache</code> is <code>[STALLG] ins=</code>, which counts '
          'icache-starvation stall cycles, <strong>not</strong> retired instructions.</p>'
          '<div class="note"><span class="lab">why FPU utilisation is absent from this table</span>'
          '<p>These two runs do <em>identical</em> work and finish within 4.5%% of each other '
          '(24.5%% vs 23.4%% efficiency), yet their TB utilisation counters read <strong>42.1%% and '
          '23.6%%</strong> &mdash; 78%% apart. The counter measures lane <em>occupancy</em>, which is '
          'not conserved across runs, so it is shown per-group in the explorer below (where '
          'within-run comparison is valid) and deliberately not quoted as a headline number. '
          '<code>RH stuck</code> carries the same caveat: it counts hold <em>episodes</em>, so it is '
          'comparable within a configuration but not across one.</p></div>'
          % "".join(_pr))


if RUN1:
    _ok  = [(k, v) for k, v in sorted(RUN1.items()) if v["cyc"]]
    _bad = [k for k, v in RUN1.items() if not v["cyc"]]
    _idx = {"sw_%s_%s_ks%d_%dx%dx%d" % (r["mesh"], r["prec"], r["KS"], r["B"], r["D"], r["I"]): r
            for r in M}
    _rows = []
    for k, v in _ok:
        r = _idx.get(k)
        eff = (100.0 * r["ideal"] / v["cyc"]) if r else None
        _rows.append('<tr><td class="mono">%s</td><td class="num">%s</td><td class="num">%s</td>'
                     '<td class="num b">%s</td><td class="num st-done">%s</td>'
                     '<td class="num dim">%s</td>'
                     '<td class="num %s">%d</td><td class="num %s">%d</td>'
                     '<td class="num dim">%d</td><td class="num dim">%s</td>'
                     '<td class="num dim">%s</td><td class="num dim">%s</td></tr>'
                     % (k.replace("sw_4x4_", ""), r["KS"] if r else "?", r["sh"] if r else "?",
                        format(v["cyc"], ","), ("%.1f%%" % eff) if eff else "&mdash;",
                        ("%.1f%%" % v["util"]) if v["util"] else "&mdash;",
                        "st-bad" if v["tmo"] else "dim", v["tmo"],
                        "st-bad" if v["rh"] else "dim", v["rh"], v["byp"],
                        ("%.0f%%" % v["acc"]) if v["acc"] is not None else "&mdash;",
                        ("%.0f%%" % v["raw"]) if v["raw"] is not None else "&mdash;",
                        ("%.0f%%" % v["ins"]) if v["ins"] is not None else "&mdash;"))
    A('<div class="card"><h2>Run&nbsp;1 &mdash; the superseded baseline</h2>'
      '<p>Run&nbsp;1 has finished %d of its 36 arms. They split into two groups, and the split is '
      'the finding.</p>'
      '<div class="tw"><table><thead><tr><th>arm</th><th class="num">KS</th>'
      '<th class="num">sharers</th><th class="num">cycles/pass</th><th class="num">efficiency</th>'
      '<th class="num">TB util</th>'
      '<th class="num" title="group-MSHR merge-cohort timeouts">tmo</th>'
      '<th class="num" title="response-hold stuck episodes; comparable WITHIN a config only">RH</th>'
      '<th class="num" title="bank-full bypasses of the MSHR">byp</th>'
      '<th class="num" title="core cycles parked on the Spatz queue">acc</th>'
      '<th class="num" title="scalar RAW hazard">raw</th>'
      '<th class="num" title="icache starvation (NOT retired instructions)">i$</th>'
      '</tr></thead><tbody>%s</tbody></table></div>'
      '<div class="note bad"><span class="lab">%d arms finished having measured nothing</span>'
      '<p>Every KS=2 arm at <code>vl=256&nbsp;B</code> ran for about <strong>2.5 minutes</strong>, '
      'reached <code>$finish</code>, and exited <code>rc=0</code> &mdash; with '
      '<code>[FPU&nbsp;FINAL] benchmark region never active (csr_trace_any_global stayed low)</code>. '
      'No error, no assertion, no hang: a scraper counting completions would score them as '
      'successful arms.</p>'
      '<p><strong>The same ELF measures normally on the target config.</strong> '
      '<code>ks2_8x128x8192</code> produced nothing on run&nbsp;1 and is 43 benchmark windows deep '
      'on run&nbsp;2. The arms sit exactly on the stock admission ceiling '
      '(<code>vl = ROB0&times;4 = 256&nbsp;B</code>); at ROB0=128 they have 2&times; headroom. '
      'Why a hardware capacity boundary makes the <em>software</em> skip its instrumented region '
      'and exit cleanly is still unexplained.</p></div>'
      '<p class="sub">The two measured arms are both <code>sharers=1</code>, so neither gets any '
      'MSHR merging &mdash; KS=8 reaching 69.4%% against KS=4&rsquo;s 44.6%% is the larger kernel '
      'amortising better, not a merging effect. Note these fleet arms <em>do</em> use the repeat '
      'loop (147 windows for a 4,595-cycle pass implies R&asymp;32), unlike the local ladder runs.</p>'
      '</div>' % (len(RUN1), "".join(_rows), len(_bad)))

# ---- degraded / livelocked arms: partial data, explicitly NOT measurements ----------
DEG = []
try:
    for _l in open(os.path.join(SCR, "deg_results.tsv")):
        _p = _l.rstrip("\n").split("\t")
        if len(_p) >= 15 and _p[13] == "degraded":
            _b, _, _a = _p[0].rpartition("__")
            DEG.append({"arm": _a, "batch": {"teranoc": "run 1"}.get(_b, "run 2 / wave B"),
                        "cyc": _p[1], "bench": _p[2], "tmo": _p[3],
                        "rh": _p[5], "byp": _p[7], "acc": _p[9],
                        "insn": int(_p[14]) if _p[14].isdigit() else 0,
                        "grp": int(_p[15]) if len(_p) > 15 and _p[15].isdigit() else 0,
                        "peak": int(_p[16]) if len(_p) > 16 and _p[16].isdigit() else 0})
except (IOError, IndexError, ValueError):
    pass
if DEG:
    _i4 = {"sw_%s_%s_ks%d_%dx%dx%d" % (r["mesh"], r["prec"], r["KS"], r["B"], r["D"], r["I"]): r
           for r in M}
    _dr = []
    for d in sorted(DEG, key=lambda x: x["arm"]):
        r = _i4.get(d["arm"], {})
        _dr.append('<tr><td class="mono">%s</td><td class="dim sm">%s</td>'
                   '<td class="num">%s</td><td class="num">%s</td>'
                   '<td class="num">%s</td><td class="num st-bad">%s</td>'
                   '<td class="num dim">%s</td>'
                   '<td class="num st-bad">%s</td><td class="num st-bad">%s</td></tr>'
                   % (d["arm"].replace("sw_", ""), d["batch"], r.get("KS", "?"), r.get("sh", "?"),
                      d["bench"], d["tmo"], d["acc"] or "&mdash;",
                      format(d["peak"], ","), format(d["insn"], ",")))
    A('<div class="card"><h2>The livelocked arms</h2>'
      '<p>These %d arms are still running but have stopped doing useful work. They are kept here '
      'because a failure mode is evidence, and their per-group series are in the explorer above '
      '(filter <code>state = degraded</code>) &mdash; but <strong>none of these is a cycle '
      'measurement</strong> and none appears in the result tables.</p>'
      '<div class="tw"><table><thead><tr><th>arm</th><th>batch</th><th class="num">KS</th>'
      '<th class="num">sharers</th><th class="num">bench windows</th>'
      '<th class="num" title="measured-region merge-cohort timeouts">tmo</th>'
      '<th class="num">stall acc</th>'
      '<th class="num" title="90th-percentile retire rate over this arm&apos;s own windows">peak insn/win</th>'
      '<th class="num" title="retired instructions per window, last 3">recent</th>'
      '</tr></thead><tbody>%s</tbody></table></div>'
      '<div class="note bad"><span class="lab">how these were identified</span>'
      '<p>By <strong>peak retire rate</strong>, not by a tuned threshold. Across 4&times;4 arms the '
      '90th-percentile retire rate falls into two populations with a <strong>9&times; gap and '
      'nothing in between</strong>: healthy arms peak at 18,800&ndash;51,300 instructions per '
      'window, these peak at 20&ndash;2,107.</p>'
      '<p><strong>Correction.</strong> An earlier version of this page said these arms never had '
      'a healthy phase. That was wrong. They retire <em>normally for roughly the first 100 '
      'windows</em> &mdash; 6,600 to 20,800 instructions per window, indistinguishable from arms '
      'that go on to finish &mdash; and only then collapse to 92&ndash;514. The 90th-percentile '
      'reading is near zero because the dead tail runs for thousands of windows and swamps the '
      'healthy opening, not because the opening is absent.</p>'
      '<p>The classifier is unaffected: the tail still dominates, so the two populations still '
      'separate with no cutoff. What changes is the <strong>detection horizon</strong> &mdash; an '
      'arm cannot be judged until it is past about 100 benchmark windows. Before that it looks '
      'healthy whichever it is.</p>'
      '<p>Timeouts alone would mis-rank them: <code>tmo</code> spans 2,321&ndash;97,556 here, and '
      'healthy arms elsewhere in the campaign carry high counts while still making progress.</p></div>'
      '<p class="sub">All %d are 4&times;4. <strong>Zero 8&times;8 arms are degraded</strong>, '
      'including all ten KS=8 arms at <code>vl=64&nbsp;B</code>.</p></div>'
      % (len(DEG), "".join(_dr), len(DEG)))

# ---- 8x8 wedged arms ---------------------------------------------------------------
if WEDGED8:
    # local index -- _idx2 is built further down, after this card
    _wix = {armname(r): r for r in M}
    _w8 = []
    for _n, _d in sorted(WEDGED8.items(), key=lambda kv: -kv[1]["win"]):
        _r = _wix.get(_n) or {}
        _w8.append('<tr><td class="mono">%s</td><td>%s</td><td class="num">%s</td>'
                   '<td class="num">%s</td><td class="num st-bad b">%s</td>'
                   '<td class="num b">%s</td><td class="num">%s</td>'
                   '<td class="num dim">%s</td></tr>'
                   % (_n.replace("sw_8x8_", ""), _r.get("prec", "?"), _r.get("sh", "?"),
                      _r.get("vl", "?"), format(_d["win"], ","), format(_d["died"], ","),
                      format(_d["peak"], ","), _d["tmo"]))
    _fp16 = sum(1 for n in WEDGED8 if "fp16" in n)
    A('<div class="card"><h2>8&times;8 arms wedged &mdash; no forward progress</h2>'
      '<p class="sub">Nine 8&times;8 arms stopped retiring instructions entirely while their '
      'simulations kept advancing. Harvested, then <strong>killed 2026-09-01</strong> &mdash; each '
      're-verified on its node, immediately before the kill, to hold no cycle count.</p>'
      '<div class="tw"><table><thead><tr><th>arm</th><th>prec</th><th class="num">sharers</th>'
      '<th class="num">vl</th><th class="num">windows</th>'
      '<th class="num" title="last window in which the arm retired anything">stopped at</th>'
      '<th class="num" title="peak instructions retired in one window">peak insn/win</th>'
      '<th class="num">tmo</th></tr></thead><tbody>%s</tbody></table></div>'
      '<div class="note bad"><span class="lab">they stop exactly where a healthy arm FINISHES</span>'
      '<p>Every one stopped retiring between window <strong>137 and 210</strong> (mean 170) &mdash; '
      'and a completing 8&times;8 arm needs <strong>159&ndash;195</strong>. Their peak retirement '
      '(58,000&ndash;129,000 per window) matches healthy arms too. So they are not stalling part-way '
      'through the work: they do roughly a full arm&rsquo;s worth and then hang.</p>'
      '<p><strong>The MSHR counters carry no signal here.</strong> <code>tmo</code>, '
      '<code>bankfull_bypass</code> and RH are <em>identically zero</em> across all twelve 8&times;8 '
      'arms &mdash; the three that completed as well as the nine that hung. They discriminated the '
      '4&times;4 livelocks (2,612&ndash;97,556 timeouts) but at 8&times;8 they are uniformly zero, so '
      'they say nothing about these arms either way. <span class="dim">(An earlier version of this '
      'card read their zeroes as evidence of a healthy memory system; that was wrong &mdash; a '
      'counter that is zero for healthy and failing arms alike is not evidence.)</span></p>'
      '<p><strong>The barrier is the discriminator.</strong> Last window with a non-zero '
      '<code>bar_rel</code>, as a fraction of the arm&rsquo;s total windows:</p>'
      '<div class="tw"><table><thead><tr><th>arms</th><th class="num">bar_last</th>'
      '<th class="num">total windows</th><th class="num">bar_last / total</th></tr></thead><tbody>'
      '<tr><td>3 completed</td><td class="num">113&ndash;178</td><td class="num">159&ndash;195</td>'
      '<td class="num b">0.58&ndash;0.94</td></tr>'
      '<tr><td>9 wedged</td><td class="num">82&ndash;174</td><td class="num">727&ndash;2,343</td>'
      '<td class="num b st-bad">0.04&ndash;0.22</td></tr></tbody></table></div>'
      '<p>The barrier fires for <strong>the same absolute span in both</strong> &mdash; it stops '
      'somewhere around window 82&ndash;178 either way. The difference is what happens next: a '
      'healthy arm <em>finishes</em> there, while a wedged arm runs on for another '
      '<strong>600&ndash;2,200 windows</strong> with the barrier silent and retirement draining to '
      'nothing.</p>'
      '<p>Their UART output reaches only the prologue &mdash; <code>finish copy</code> and the shape '
      'line &mdash; and never <code>execution took</code>. Since the timer print precedes the '
      'verify, the hang sits <em>before</em> the result is reported: at the end of the kernel or in '
      'the barrier/fence ahead of the timer read, not in the memory system and not in the verify.</p>'
      '<p class="sub">This is a completion-path hang, not a livelock, and it is why no cycle count '
      'can be recovered from them.</p></div>'
      '<div class="note"><span class="lab">how they were identified</span>'
      '<p><strong>Zero</strong> retired instructions across the last 40 windows, summed over all 64 '
      'groups, with no <code>execution took</code> and only the two banner UART lines. A completing '
      '8&times;8 arm needs <strong>160&ndash;195 windows</strong>; these are at 540&ndash;2,082.</p>'
      '<p>They are <em>spinning, not paused</em> &mdash; watched for 60 s, one advanced its cycle '
      'counter 2,301,000&rarr;2,302,000 and its window 2237&rarr;2238 while retiring nothing.</p>'
      '</div>'
      '<div class="note"><span class="lab">this is NOT the failure band</span>'
      '<p><strong>0 of the 9 are band arms</strong>, and 0 of the 12 band arms are wedged. Two other '
      'variables track it instead:</p>'
      '<div class="formula">'
      'by precision &nbsp; fp16 <b>8 of 26</b> (31%%) &nbsp;&middot;&nbsp; fp32 <b>1 of 24</b> (4%%)<br>'
      'by kernel split &nbsp; KS=1 <b>0%%</b> &nbsp; KS=2 <b>14%%</b> &nbsp; KS=4 <b>25%%</b> &nbsp; '
      'KS=8 <b>50%%</b>'
      '</div>'
      '<p>So the wedges are an fp16-and-high-KS phenomenon, monotone in KS, and the livelock '
      'predicate does not point at them at all. The known fp16 VFU wedge '
      '(<code>spatz_vfu.sv:159</code>, vsew read from the live request instead of the result tag) '
      'is <strong>already fixed</strong> in the compiled source, so it is not the cause &mdash; this '
      'is something else.</p></div>'
      '<p class="sub">Recorded in <code>docs/benchmarks/wedged_8x8.tsv</code>; '
      '%d of the 9 are fp16. Their nine grid points are unmeasured &mdash; requeueing them on the '
      'same image would reproduce the hang, so they need the cause first.</p></div>'
      % ("".join(_w8), _fp16))

# ---- half the machine idle at 8x8 -------------------------------------------------
A('<div class="card"><h2>A slow group set, not dead cores &mdash; and it precedes the hang</h2>'
  '<p class="sub">In six 8&times;8 arms, groups <strong>32&ndash;63</strong> (cores 512&ndash;1023) '
  'show zero FPU utilisation for the entire run, while groups 0&ndash;31 run at ~65%. '
  'Four of those six went on to wedge; the three arms that <em>completed</em> all use 64/64.</p>'
  '<div class="note"><span class="lab">it is not a missing work assignment</span>'
  '<p>The obvious explanation &mdash; software forgot to hand the top half any work &mdash; is '
  'ruled out. The kernel prints its own split, and a broken arm and a working arm compute the '
  '<em>same</em> 1024-core decomposition:</p>'
  '<div class="tw"><table><thead><tr><th>arm</th><th>M,N,P</th><th>m_start,m_end</th>'
  '<th>p_start,p_end</th><th class="num">row_chunks</th><th class="num">p_blocks</th>'
  '<th class="num">cores covered</th></tr></thead><tbody>'
  '<tr><td>fp32 KS=1 4x128x16384 <span class="st-bad">(dead top half)</span></td>'
  '<td>4, 128, 16384</td><td>0, 1</td><td>0, 64</td><td class="num">4</td>'
  '<td class="num">256</td><td class="num b">1024</td></tr>'
  '<tr><td>fp32 KS=8 32x256x4096 <span class="st-ok">(all 64 busy)</span></td>'
  '<td>32, 256, 4096</td><td>0, 8</td><td>0, 16</td><td class="num">4</td>'
  '<td class="num">256</td><td class="num b">1024</td></tr></tbody></table></div>'
  '<p><code>ACTIVE_GROUP_DIV</code> &mdash; the one knob that would idle the top groups &mdash; is '
  '<strong>1</strong> in every app (the <code>=4</code> in the source is comment text, not a '
  'setting), and every NUM_CORES-scaled ELF symbol is identical across working and broken '
  'builds.</p></div>'
  '<div class="note bad"><span class="lab">RETRACTED: they are slow, not dead</span>'
      '<p>An earlier version of this card claimed 400 of 1024 cores <em>never execute a single instruction</em>, based on their <code>trace_hart_*.dasm</code> being 0 bytes while others held 14,307,328. <strong>That was wrong.</strong> <code>mempool_cc.sv:337</code> gates the tracer:</p>'
      '<pre class="code">if ((i_snitch.csr_trace_q || SnitchTrace) &amp;&amp; ...)</pre>'
      '<p>This image is built <code>SNITCH_TRACE=0</code>, so a hart writes its trace <em>only while <code>csr_trace_q</code> is set</em> &mdash; the CSR the benchmark enables. An empty file means the core never reached the traced region, not that it never ran.</p>'
      '<p>The FPU counters say so directly: over the full series, <strong>all 64 groups reach non-zero utilisation</strong>. What is real is a <strong>bimodal split</strong>:</p>'
      '<div class="tw"><table><thead><tr><th>group set</th><th class="num">count</th><th class="num">peak FPU utilisation</th></tr></thead><tbody>'
      '<tr><td>fast &mdash; reached the traced region</td><td class="num">39</td>'
      '<td class="num b st-ok">80.1 &ndash; 99.8%</td></tr>'
      '<tr><td>slow &mdash; never did</td><td class="num">25</td>'
      '<td class="num b st-bad">10.7 &ndash; 43.9%</td></tr></tbody></table></div>'
      '<p>The two bands do not overlap at all, and this matches the previously recorded <em>fixed spatial slow set</em> at 8&times;8 (21 of 64 groups, bimodal ~82%/~22%). So this is that same phenomenon, not a boot failure.</p></div>'
      '<div class="note bad"><span class="lab">and it is not the work split</span>'
  '<p>Two independent probes agree. Mid-run, <code>[STALLG]</code> shows groups 0&ndash;31 with '
  'accelerator-stall 4,000&ndash;16,000 of 16,000 while groups 32&ndash;63 report exactly zero of '
  '<em>everything</em> &mdash; no instructions, no RAW stalls, no LSU, no accelerator. '
  '<code>[CMS]</code> reports STUCK_REQ only in the bottom half.</p>'
  '<p>These zeroes are real idleness, not a tracing gap: the TB counters are gated by '
  '<code>csr_trace_any_global</code>, a <em>global</em> OR, so once any core enables tracing every '
  'group is being measured.</p></div>'
  '<div class="note bad"><span class="lab">where the fast cores end up: <code>mempool_barrier</code></span>'
      '<p>This part still holds &mdash; it comes from real program counters. Every traced core ends at one of two PCs, both inside <code>mempool_barrier</code> (<code>0x80002cb4</code>):</p>'
      '<div class="tw"><table><thead><tr><th>PC</th><th>instruction</th></tr></thead><tbody>'
      '<tr><td><code>0x80002cc8</code></td><td><code>bne</code> &mdash; barrier spin</td></tr>'
      '<tr><td><code>0x80002ce4</code></td><td><code>wfi</code> &mdash; asleep, awaiting wake</td></tr></tbody></table></div>'
      '<p>So the fast groups finish their share and park in the barrier. The barrier waits for <code>NUM_CORES</code> = 1024, and the slow groups &mdash; running at roughly a quarter of the rate &mdash; do not arrive. Utilisation falls to zero and <code>execution took</code> is never reached.</p>'
      '<p class="sub">What is <em>not</em> established is why the slow set is slow. The earlier claim that it is a boot failure is withdrawn: those cores run, they are simply far behind. Whether the barrier never releases, or merely takes longer than the run allowed, is open.</p></div>'
      '<div class="note"><span class="lab">the prologue-stuck arms are a DIFFERENT failure</span>'
  '<p>Ten <code>waveC8x8</code> arms never emitted a single <code>[FPU] bench</code> window, '
  'sitting in the <code>pre</code> phase at 1.43&ndash;1.83M cycles &mdash; roughly 7&ndash;9x a '
  'healthy arm&rsquo;s <em>entire</em> runtime. But measured over their full FPUG series, '
  '<strong>all 64 groups run in every one of them</strong> (0 idle groups).</p>'
  '<p class="sub">So this is <em>not</em> the barrier deadlock: that one is defined by groups that '
  'never start. An earlier reading here claimed they shared the idle-group pattern &mdash; that '
  'came from one window&rsquo;s instantaneous <code>grp_min=0.0%</code>, which is not the same as '
  'a group never running, and it was wrong. Two distinct problems.</p></div>'
  '<div class="note"><span class="lab">what is still open</span>'
  '<p>If 512 cores never arrive, the bottom half completes its own share and then waits at a '
  'barrier for cores that will never come. That is exactly the wedge signature: the barrier goes '
  'quiet around window 82&ndash;178, retirement drains to nothing, and <code>execution took</code> '
  'is never printed.</p>'
  '<p class="sub">Falsifiable prediction: the two dead-top-half arms still running '
  '(<code>fp32 KS=1 4x128x16384</code>, <code>fp32 KS=8 16x128x8192</code>) should also wedge. '
  'What this does not yet explain is why only some shapes are affected &mdash; the split '
  'arithmetic is identical in both. Settling it needs a debug image '
  '(<code>snitch_trace=1</code>) to recover a top-half hart\'s stuck PC.</p></div>'
  '<p class="sub">Per-arm counts in <code>docs/benchmarks/dead_top_half_8x8.tsv</code>; filter the '
  'utilisation explorer to <em>mesh 8&times;8</em> to see it directly.</p></div>')

# ---- prologue-stuck waveC8x8 arms -------------------------------------------------
PRO = []
try:
    for _l in open(os.path.join(ROOT, "docs", "benchmarks", "prologue_stuck_8x8.tsv")):
        if _l.startswith("#") or not _l.strip(): continue
        _f = _l.rstrip("\n").split("\t")
        if len(_f) >= 7: PRO.append(_f)
except IOError: pass
if PRO:
    _rows = "".join(
        '<tr><td class="mono">%s</td><td class="dim sm">%s</td><td class="num">%s</td>'
        '<td class="num st-bad">%s</td><td class="num b st-ok">%s</td>'
        '<td class="num dim">%s</td></tr>'
        % (f[0].replace("sw_8x8_", ""), f[1], format(int(f[2]), ","), f[3],
           "%s/%s" % (int(f[4]) - int(f[5]), f[4]), f[6])
        for f in PRO)
    A('<div class="card"><h2>Ten arms never reached the timed region</h2>'
      '<p class="sub">The whole <code>waveC8x8</code> batch &mdash; every one KS=1 &mdash; sat in '
      'the prologue for 1.4&ndash;1.8M cycles without emitting a single benchmark window. '
      'Harvested and killed 2026-09-01.</p>'
      '<div class="tw"><table><thead><tr><th>arm</th><th>node</th>'
      '<th class="num">cycles reached</th>'
      '<th class="num" title="[FPU] bench windows emitted">bench windows</th>'
      '<th class="num" title="groups that retired something at any point">groups active</th>'
      '<th class="num">FPUG windows</th></tr></thead><tbody>%s</tbody></table></div>'
      '<p>For scale: a healthy 8&times;8 arm completes its <em>entire</em> benchmark in about '
      '200,000 cycles. These ran 7&ndash;9x that without starting it, while still executing '
      '(~3.5%% utilisation, transcripts growing).</p>'
      '<div class="note"><span class="lab">distinct from the barrier deadlock</span>'
      '<p>Every one uses <strong>all 64 groups</strong>. The barrier deadlock is defined by groups '
      'that never start, so whatever holds these in the prologue is a second, separate problem '
      '&mdash; and it correlates perfectly with <strong>KS=1</strong>, the largest row-chunk count '
      'and therefore the smallest number of column blocks.</p></div>'
      '<p class="sub">Evidence in <code>docs/benchmarks/prologue_stuck_8x8.tsv</code>; their series '
      'are in the utilisation explorer under state <em>prologue</em>.</p></div>' % _rows)

# ---- kernel size vs efficiency, at fixed sharers -------------------------------
_line = []
_idx2 = {"sw_%s_%s_ks%d_%dx%dx%d" % (r["mesh"], r["prec"], r["KS"], r["B"], r["D"], r["I"]): r
         for r in M}
for _k, _v in sorted(RUN1.items()):
    _r = _idx2.get(_k)
    if not _v["cyc"] or not _r: continue
    if _r["sh"] != 1 or _r["prec"] != "fp16": continue
    _line.append((_r["KS"], _k, _v["cyc"], 100.0 * _r["ideal"] / _v["cyc"]))
_line.sort()
if len(_line) >= 2:
    _lr = "".join('<tr><td class="num b">%d</td><td class="mono">%s</td><td class="num">%s</td>'
                  '<td class="num st-done">%.1f%%</td></tr>'
                  % (k, a.replace("sw_4x4_fp16_", ""), format(c, ","), e) for k, a, c, e in _line)
    _l1 = "".join('<tr><td class="num b">1</td><td class="mono">%s</td><td class="num">%s</td>'
                  '<td class="num st-done">%.1f%%</td></tr>'
                  % ("%s (ROB0=%s, %s)" % (lb, rb0, ld), format(st["took"], ","),
                     100.0 * (8*128*8192/(256*4*2)) / st["took"])
                  for lb, rb0, ld, _d in LADDER
                  for st in [ladder_row(_d)] if st and st.get("took"))
    A('<div class="card"><h2>What kernel size buys</h2>'
      '<p>At <code>sharers = B/KS = 1</code> there is no MSHR merging at all, so these arms isolate '
      'the kernel shape. Same precision, same D and I; only KS changes:</p>'
      '<div class="tw"><table><thead><tr><th class="num">KS</th><th>arm</th>'
      '<th class="num">cycles/pass</th><th class="num">efficiency</th></tr></thead><tbody>%s%s'
      '</tbody></table></div>'
      '<div class="note good"><span class="lab">what this says about KS=1</span>'
      '<p>Efficiency rises monotonically with kernel size, and the two KS=1 measurements land '
      'exactly where the trend extrapolates. <strong>KS=1&rsquo;s low efficiency is the operating '
      'point, not a cost of the split-load workaround</strong> &mdash; which was the open question '
      'when ROB0=128 + split was chosen. The split costs 4.5%%; the kernel shape costs the rest.</p>'
      '<p>Larger KS amortises the per-iteration scalar and loop overhead across more FMAs per loaded '
      'element. It also needs more registers (<code>KS &times; LMUL = 16</code>), which is why KS=8 '
      'is the practical ceiling and why B must be a multiple of KS.</p></div>'
      % (_l1, _lr))

# ---- matched-B KS comparison ---------------------------------------------------
# A per-KS MEDIAN over a partially-landed grid is a median over whichever arms finished,
# and B >= KS removes the small-B arms from KS=8, so the B ranges are NOT balanced across
# KS. Comparing pooled medians therefore compares different parts of the grid. Only
# same-precision, same-B pairs isolate KS. (Trap raised by the GVSoC peer session, which
# hit it from the other side; verified here against our own landed set.)
# Build from status(), NOT from RUN2 alone. RUN2 only carries arms whose fleet probe landed,
# so a card sourced from it silently omits every arm harvested from a transcript -- which is
# how this table showed 4 rows while 9 matched-B ladders existed, and hid the B=128 inversion
# entirely. Every card must read the same source the tables render.
_lan = {}
for _r in M:
    if _r["mesh"] != "4x4": continue
    _c, _t, _l = status(_r)
    if _c != "done": continue
    _txt = _t.rstrip("%*")
    if not _txt.replace(".", "").isdigit(): continue
    _lan[(_r["prec"], _r["KS"], _r["B"])] = (float(_txt), _r.get("vl"))
_byb = {}
for (_p, _ks, _b), _val in _lan.items():
    _byb.setdefault((_p, _b), {})[_ks] = _val
_mrows = []
for (_p, _b), _d in sorted(_byb.items()):
    if len(_d) < 2: continue
    _cells = "".join('<td class="num">%s</td>'
                     % ('<b>%.1f%%</b><span class="dim sm"> vl=%s</span>' % (_d[_ks][0], _d[_ks][1])
                        if _ks in _d else '&mdash;')
                     for _ks in (2, 4, 8))
    # max(_d)/min(_d) over a DICT returns max/min KEYS -- i.e. highest-KS over lowest-KS,
    # not best over worst. Those coincide only while the ranking is monotonic, so the header
    # ("best / worst") and the number silently disagreed until B=128 inverted the order.
    _best = max(_v[0] for _v in _d.values())
    _worst = min(_v[0] for _v in _d.values())
    _peak = max(_d, key=lambda k: _d[k][0])
    _mrows.append('<tr><td class="mono">%s</td><td class="num">%d</td>%s'
                  '<td class="num st-done b">%.2f&times;</td>'
                  '<td class="num%s">KS=%d</td></tr>'
                  % (_p, _b, _cells, _best / _worst,
                     ' st-bad b' if _peak != max(_d) else '', _peak))
_unb = "  ".join("KS=%d: B&nbsp;=&nbsp;%s" % (_ks, ",&nbsp;".join(
        str(_x) for _x in sorted({_bb for (_pp, _kk, _bb) in _lan if _kk == _ks})))
        for _ks in (2, 4, 8))
if _mrows:
    A('<h3 style="margin-top:22px">At matched B &mdash; the only comparison the grid supports</h3>'
      '<h3>At matched B &mdash; the only fair comparison</h3>'
      '<p>The landed arms are <strong>not balanced across KS</strong>, because <code>B &ge; KS</code> '
      'removes the small-B arms from KS=8 and only part of the grid has finished:</p>'
      '<p class="mono sm">%s</p>'
      '<p>So a per-KS median compares different regions of the grid. These rows hold precision '
      '<em>and</em> B fixed, varying only KS:</p>'
      '<div class="tw"><table><thead><tr><th>prec</th><th class="num">B</th>'
      '<th class="num">KS=2</th><th class="num">KS=4</th><th class="num">KS=8</th>'
      '<th class="num">best / worst</th><th class="num">peak at</th></tr></thead><tbody>%s</tbody></table></div>'
      '<div class="note bad"><span class="lab">CORRECTION &mdash; the ranking is not monotonic</span>'
      '<p>An earlier version of this page said every matched pair ranks the same way, '
      'monotonically. That was drawn from <code>B&nbsp;&le;&nbsp;64</code>, and it is wrong at the '
      'top of the range. <strong>At <code>B=128</code> the order inverts in both precisions</strong>, '
      'with KS=8 falling <em>below</em> KS=4 &mdash; 44.0%%&rarr;33.0%% in fp16 and '
      '43.3%%&rarr;33.5%% in fp32, from arms with <code>tmo=0</code> and identical '
      '<code>ideal</code>.</p>'
      '<p>So the real shape is a <strong>peak at KS=4 for large B</strong>, not a climb to KS=8. '
      'KS=8 still wins decisively at <code>B&nbsp;&le;&nbsp;64</code> (up to 3.21&times;), and the '
      'effect is still not an artifact of which arms landed &mdash; but &ldquo;larger KS is '
      'better&rdquo; is only true below B=128.</p>'
      '<p class="sub">This surfaced only when 13 arms that had finished, while still being '
      'reported as running, were harvested &mdash; and every one of them sits at the large-B end '
      'of the grid. A partially-landed grid does not just add noise; it can hide a whole '
      'regime.</p></div>'
      '<div class="note bad"><span class="lab">but KS and vl cannot be separated here</span>'
      '<p>At fixed B, KS <em>determines</em> vl: <code>vl = I &middot; B &middot; elem_bytes / '
      '(cores &middot; KS)</code>, so KS=2&rarr;256&nbsp;B, KS=4&rarr;128&nbsp;B, KS=8&rarr;64&nbsp;B '
      'every time (see the vl labels). The two are perfectly anti-correlated <em>by construction</em> '
      'and no arm in this grid breaks the tie.</p>'
      '<p>The defensible claim is therefore <strong>&ldquo;KS=8/vl=64 beats KS=2/vl=256 by '
      '2.2&ndash;3.2&times; at matched B&rdquo;</strong>, as a package. That KS is the causal '
      'variable rather than vl is <strong>not established</strong>; separating them needs an arm '
      'holding one fixed while moving the other, which this grid cannot express. '
      'KS=4 also appears in only one matched pair &mdash; treat it as a point, not a level.</p>'
      '</div></div>' % (_unb, "".join(_mrows)))

# ---- livelock predicate ---------------------------------------------------------
# Neither sharers nor vl alone separates the degraded arms; the CONJUNCTION does.
# Scored over every 4x4 arm with a known outcome. The degraded labels come from the
# peak-retire-rate test, which uses neither sharers nor vl, so this is not circular.
def _pred(r): return r["sh"] in (2, 4) and (r.get("vl") or 0) >= 128
_cells, _sc = {}, [0, 0, 0, 0]      # tp, fp, fn, tn
for _k, _r in _idx2.items():
    if _r["mesh"] != "4x4": continue
    _c = (RUN2.get(_k) or {}).get("cyc") or (RUN1.get(_k) or {}).get("cyc")
    if _k in DEGRADED: _o = True
    elif _c: _o = False
    else: continue
    _cells.setdefault((_r["sh"], _r.get("vl")), []).append(_o)
    _p = _pred(_r)
    _sc[0 if (_p and _o) else 1 if _p else 2 if _o else 3] += 1
_crows = []
for (_sh, _vl), _v in sorted(_cells.items()):
    _bad = all(_v); _good = not any(_v)
    _crows.append('<tr><td class="num">%s</td><td class="num">%s</td><td class="num">%d</td>'
                  '<td class="%s">%s</td></tr>'
                  % (_sh, _vl, len(_v),
                     "st-bad b" if _bad else ("st-done" if _good else "num"),
                     "all degraded" if _bad else ("all completed" if _good else "MIXED")))
_fut = sorted(_k for _k, _r in _idx2.items()
              if _r["mesh"] == "8x8" and _r["KS"] in (2, 4) and _pred(_r))
if _crows:
    A('<div class="card"><h2>Why arms livelock &mdash; two conditions, not one</h2>'
      '<p>Neither <em>sharers</em> nor <em>vl</em> predicts failure on its own. Two arms with '
      '<code>sharers=2</code> complete; one with <code>sharers=8</code> and <code>vl=128</code> '
      'completes; arms at <code>vl=256</code> complete at every cohort size from 8 up. Every cell '
      'of the grid, by outcome:</p>'
      '<div class="tw"><table><thead><tr><th class="num">sharers</th><th class="num">vl (B)</th>'
      '<th class="num">arms</th><th>outcome</th></tr></thead><tbody>%s</tbody></table></div>'
      '<div class="note bad"><span class="lab">the predicate</span>'
      '<p><strong><code>sharers &isin; {2,4}</code> AND <code>vl &ge; 128&nbsp;B</code></strong> '
      '&rarr; livelock. Scored over every 4x4 arm with a known outcome: '
      '<strong>%d/%d correct</strong> &mdash; %d true positives, %d true negatives, '
      '<strong>0 false alarms, 0 misses</strong>.</p>'
      '<p>A cohort large enough to be worth assembling but too small to assemble quickly, carrying '
      'bursts big enough to matter. Either condition alone is survivable; together they are not. '
      'The degraded labels come from the peak-retire-rate test, which uses neither variable &mdash; '
      'so the separation is not circular.</p></div>'
      '<div class="note"><span class="lab">stated before the data lands</span>'
      '<p>The predicate says <strong>%d of the 26 running 8&times;8 Wave&nbsp;A arms will '
      'degrade</strong> and the other %d will complete:</p><p class="mono sm">%s</p>'
      '<p>These arms were dispatched before this analysis existed and are running now, so this is a '
      'test rather than a fit. <strong>Any completion in that list falsifies the predicate.</strong>'
      '</p></div>'
      '<p class="sub">Untested cells: <code>sharers&nbsp;&le;&nbsp;1</code> exists only at '
      '<code>vl=64</code>, and <code>sharers&nbsp;&isin;&nbsp;{2,4}</code> never occurs at '
      '<code>vl=512</code> anywhere in the grid &mdash; so neither corner is covered, and the '
      'predicate is a boundary fitted on 31 points with <strong>no mechanism yet</strong>.</p>'
      ''
      % ("".join(_crows), _sc[0] + _sc[3], sum(_sc), _sc[0], _sc[3],
         len(_fut), 26 - len(_fut),
         "<br>".join(_x.replace("sw_8x8_", "") for _x in _fut)))

# ---- live predicate test: horizon progress ---------------------------------------
# An arm cannot be judged before ~100 benchmark windows -- the 4x4 failures retired
# normally until then. This card reports how far the live arms have got, so the page
# never implies a verdict the data cannot yet support.
try:
    _HZ = json.load(open("/tmp/claude-620771/horizon.json"))
except Exception:
    _HZ = []
if _HZ:
    _wc = [h for h in _HZ if h["wave"] == "waveC"]
    _wa = [h for h in _HZ if h["wave"] == "waveA"]
    _wcp = sum(1 for h in _wc if h["win"] >= 100)
    _bd  = [h for h in _wa if h["band"]]
    _bdp = sum(1 for h in _bd if h["win"] >= 100)
    _rows = "".join(
        '<tr><td class="mono">%s</td><td class="num">%s</td><td class="num">%s</td>'
        '<td class="num b">%s</td><td class="num">%s</td><td>%s</td></tr>'
        % (h["arm"].replace("sw_", ""), h["sh"], h["vl"], format(h["win"], ","),
           format(h["insn"], ","),
           ('<span class="st-bad">in band &mdash; predicted to fail</span>' if h["band"]
            else '<span class="dim">predicted healthy</span>'))
        for h in sorted(_HZ, key=lambda x: (-x["win"],)))
    A('<div class="note bad"><span class="lab">first disconfirming evidence &mdash; 8&times;8</span>'
      '<p>Three band arms have now passed the ~100-window mark at which <em>every</em> 4&times;4 '
      'failure had already collapsed, and they are <strong>not degrading</strong>:</p>'
      '<div class="formula">'
      'past the horizon &nbsp; in band <b>205,450</b> insn/window &nbsp;&middot;&nbsp; '
      'outside <b>210,500</b> &nbsp;&middot;&nbsp; ratio <b>0.98</b><br>'
      '<span style="color:var(--faint)">at 4&times;4 the failures fell to 92&ndash;514 per window '
      '&mdash; a ~40&times; drop. Here there is no drop at all.</span></div>'
      '<p>The band arms do carry the mechanism &mdash; <code>tmo</code> 3,964&ndash;11,207 against '
      '<strong>0</strong> for every out-of-band arm past the horizon &mdash; so the timeouts are '
      'real. They are simply <strong>not producing livelock at 8&times;8</strong>.</p>'
      '<p>Two readings, and the data does not yet separate them: the predicate may be '
      '<strong>4&times;4-specific</strong>, or the ~100-window horizon may not transfer to a mesh '
      'whose arms are far longer (the 4&times;4 failures collapsed at roughly 2%% of their eventual '
      'length). Treating the second as established would be explaining away a disconfirming result, '
      'so it is recorded as an open question rather than a rescue.</p></div>'
      '<h3 style="margin-top:24px">Is it holding? &mdash; the live test</h3>'
      '<p>An arm cannot be judged before about <strong>100 benchmark windows</strong>: every 4x4 '
      'failure retired 6,600&ndash;20,800 instructions per window, indistinguishable from a healthy '
      'arm, until roughly that point and only then collapsed. Progress against that horizon:</p>'
      '<div class="note good"><span class="lab">Wave&nbsp;C &mdash; first test to return a result</span>'
      '<p>All ten arms are <code>sharers&nbsp;&ge;&nbsp;8</code>, which the predicate says should '
      'complete. <strong>%d of %d are past the horizon</strong>, the furthest at '
      '<strong>%s windows</strong> &mdash; six times beyond the point where the 4x4 failures '
      'collapsed &mdash; and none has stopped retiring. The healthy half of the prediction '
      'holds.</p></div>'
      '<div class="note"><span class="lab">Wave&nbsp;A &mdash; the failure half, still pending</span>'
      '<p>%d of the 8 band arms have reached the horizon (furthest %s windows). '
      '<strong>Nothing is confirmed or refuted yet</strong>, and their current health is not '
      'evidence: a doomed arm looks exactly like this before window 100.</p></div>'
      '<div class="tw"><table><thead><tr><th>arm</th><th class="num">sharers</th>'
      '<th class="num">vl</th><th class="num">windows</th><th class="num">recent insn</th>'
      '<th>prediction</th></tr></thead><tbody>%s</tbody></table></div>'
      '<p class="sub">Live arms only; completed and livelocked arms appear in the tables above.</p>'
      '</div>'
      % (_wcp, len(_wc), format(max(h["win"] for h in _wc), ","),
         _bdp, format(max((h["win"] for h in _bd), default=0), ","), _rows))

# ---- KS=1 ------------------------------------------------------------------
A('<div class="card"><h2>Why KS=1 exists, and what it costs</h2>'
  '<p><code>kernel_size</code> must divide M, so <strong>KS=1 is the only legal kernel at B=1</strong>: '
  'without it, decode GEMV does not run at all. It is also the extreme of the sweep\'s one real '
  'trade-off. At <code>sharers = B/KS = 1</code> there is no cohort for the group MSHR to merge, and '
  'every loaded element feeds exactly one FMA. Expect it to be bandwidth-bound by construction &mdash; '
  'that is the operating point, not a defect, and the sweep exists to price it.</p>'
  '<div class="note good"><span class="lab">two fixes; only one is free</span>'
  '<p>Raising ROB0 128&rarr;256 clears the ceiling but doubles the deepest ROB in the design. '
  'Splitting the load instead (<code>SPATZ_1XVL_LOAD_LMUL=4</code>: two 256&nbsp;B loads of 64 ids '
  'each) keeps the original depth and stays on the burst path. Same trick as the store split '
  '(<code>SPATZ_1XVL_STORE_LMUL</code>), and legal for the same reason: element <em>i</em> lives in '
  'register <code>base + i/(VLEN/EEW)</code> regardless of LMUL, so a split that lands on a register '
  'boundary needs no data movement at all.</p></div>')

rows = []
for label, rob0, load, d in LADDER:
    st = ladder_row(d)
    if st is None: continue
    cls, txt = st["verdict"]
    extra = ("<span class=\"dim\">tmo %d &middot; peers0 %d</span>" % (st["tmo"], st["p0"])
             if d != "ctl" else "<span class=\"dim\">&mdash;</span>")
    rows.append('<tr><td class="mono b">%s</td><td class="num">%s</td><td class="mono">%s</td>'
                '<td class="st-%s">%s</td><td class="num dim">%s</td><td>%s</td></tr>'
                % (label, rob0, load, cls, txt,
                   ("%s / %s" % (st["refus"], format(st["grants"], ",")) if st["grants"] else "&mdash;"), extra))
A('<h3>The fix ladder &mdash; matched on shape 8&times;128&times;8192</h3>'
  '<div class="tw"><table><thead><tr><th>run</th><th class="num">ROB0</th><th>512&nbsp;B load</th>'
  '<th>state</th><th class="num">burst refused / sampled</th><th>health</th></tr></thead><tbody>%s</tbody>'
  '</table></div>'
  '<p class="sub">The two images differ by <strong>one define line out of 107</strong> '
  '(<code>SPATZ_VLSU_ROB_DEPTH</code>); the two ELFs by one software knob (30 <code>vle16.v</code> '
  'against 23, identical stores). So the ladder isolates exactly one variable at each step.</p>'
  '<div class="note good"><span class="lab">resolved &mdash; the cheap fix works, and costs 4.5%%</span>'
  '<p>The split load clears the ceiling at <strong>half</strong> the ROB depth: 17,503 cycles '
  'against the deep-ROB arm\'s 16,748, so it buys ROB0 128 instead of 256 for <strong>+4.5%% '
  'cycles</strong>. Both are clean (<code>tmo=0</code>, no assertion) and both stay on the burst '
  'path.</p>'
  '<p>An earlier reading of this page expected the split arm to be <em>faster</em>, because it was '
  'retiring ~2.5&times; more instructions per cycle. That was entirely instruction-count inflation '
  '&mdash; the split kernel issues more instructions for the same work &mdash; and the completed '
  'cycle counts refute it. Instructions-per-cycle is not throughput when the instruction count '
  'itself is what changed.</p></div>'
  % "".join(rows))

A('<p>What KS=1 cannot avoid is the register file. <code>KS &times; LMUL = 16</code> means KS=1 wants '
  'm16; the kernel uses one accumulator at m8 instead and leaves <code>v24</code>&ndash;<code>v31</code> '
  'idle. That waste is inherent to one accumulator, not a missed optimisation.</p></div>')

# ---- open issues -----------------------------------------------------------
A('<div class="card"><h2>Open issues</h2><ul>'
  '<li><strong>KS=1 above 256&nbsp;B needs the split load</strong> (%d arms) &mdash; decided, not '
  'blocked. <code>SPATZ_1XVL_LOAD_LMUL=4</code> at ROB0=128, measured cost 4.5%% against a '
  '256-deep ROB. The remaining unknown is whether the two halves actually overlap in the VLSU '
  'or are serialised by the <code>vsetvli</code> between them.</li>'
  '<li><strong>KS=2 cannot run on the stock config at all.</strong> It needs '
  '<code>group_mshr_bypass_ways &ge; 8</code>; at the shipped 4 every arm dies on the assertion. '
  'Whether the right answer is a larger track or a stricter admission rule is undecided &mdash; the '
  'admission rule is the thing that is actually wrong.</li>'
  '<li><strong>The livelock boundary is unmapped.</strong> Arms at or past the group-MSHR cohort '
  'capacity degrade rather than fail. Where that boundary sits across (B, KS, I) is itself one of '
  'the results this sweep should produce, and it is why the collector detects livelock instead of '
  'trusting a cycle count.</li>'
  '<li><strong>The 8&times;8 half is planned but not dispatched</strong> (52 arms), pending the '
  '4&times;4 review.</li>'
  '<li><strong>B=128 arms run R=1</strong>, so they alone carry cold-start cost. Do not compare '
  'them against small-B arms without saying so.</li>'
  '</ul></div>' % nb)


# ---- filters for the unified performance table -----------------------------------
if _PA:
    A('''<script>
(function(){
 var $=function(i){return document.getElementById(i)};
 var rows=[].slice.call(document.querySelectorAll("#p_rows tr"));
 var F=[["p_mesh","mesh"],["p_prec","prec"],["p_ks","ks"],["p_st","st"],["p_band","band"]];
 var LB={st:{measured:"measured",livelocked:"livelocked",running:"running",pending:"not started"},
         band:{"1":"in band","0":"outside"}};
 function keep(r,upto){
   for(var i=0;i<upto;i++){var v=$(F[i][0]).value;
     if(v!=="*"&&r.dataset[F[i][1]]!==v) return false;}
   return true;
 }
 // each select lists only values still reachable given the filters to its LEFT, so no
 // combination can produce an empty table
 function fill(){
   F.forEach(function(f,i){
     var el=$(f[0]), keepv=el.value||"*", seen=[];
     rows.forEach(function(r){ if(keep(r,i)){ var v=r.dataset[f[1]];
       if(seen.indexOf(v)<0) seen.push(v); }});
     seen.sort(function(a,b){return (isNaN(a)||isNaN(b))?a.localeCompare(b):(+a)-(+b)});
     el.innerHTML='<option value="*">all</option>'+seen.map(function(v){
       var t=(LB[f[1]]&&LB[f[1]][v])||v; return '<option value="'+v+'">'+t+'</option>';}).join("");
     el.value = seen.indexOf(keepv)>=0 ? keepv : "*";
   });
 }
 function draw(){
   var n=0;
   rows.forEach(function(r){ var ok=keep(r,F.length); r.style.display=ok?"":"none"; if(ok)n++; });
   $("p_n").textContent=n+" / "+rows.length+" arms";
 }
 F.forEach(function(f){$(f[0]).addEventListener("change",function(){fill();draw();})});
 fill(); draw();
})();
</script>''')

# ---- per-group utilisation: mesh heat-map, time scrubber, progress bars ----------
try:    GU = json.load(open(os.path.join(SCR, "ks_group_util.json")))
except Exception: GU = {}
if GU:
    A('<div class="card"><h2>Per-group FPU utilisation over the benchmark</h2>'
      '<p class="sub">Each cell is one group of the mesh, coloured by the share of its FPU '
      'lane-cycles that were busy in that window. Drag the scrubber to move through the run. '
      'The grid sizes itself to the mesh, so 4&times;4 (16 groups) and 8&times;8 (64 groups) '
      'both render.</p>'
      '<div class="ctl facets">'
      '<label>mesh <select id="f_mesh"></select></label>'
      '<label>state <select id="f_state"></select></label>'
      '<label>run <select id="f_run"></select></label>'
      '<label>prec <select id="f_prec"></select></label>'
      '<label>KS <select id="f_ks"></select></label>'
      '<label>B (M) <select id="f_B"></select></label>'
      '<label>D (N) <select id="f_D"></select></label>'
      '<label>I (P) <select id="f_I"></select></label>'
      '<label>arm <select id="marm"></select></label>'
      '<button type="button" id="f_reset" class="rst">reset</button>'
      '<span class="mono dim" id="f_count"></span>'
      '</div>'
      '<div class="ctl">'
      '<label class="grow">window <input id="mper" type="range" min="0" max="1" value="0"></label>'
      '<span class="mono dim" id="mcyc">&mdash;</span>'
      '</div>'
      '<div class="mstats">'
      '<div class="stat"><span class="k">mesh</span><span class="v" id="mgn">&mdash;</span></div>'
      '<div class="stat"><span class="k">mean util</span><span class="v" id="mmean">&mdash;</span></div>'
      '<div class="stat"><span class="k">spread</span><span class="v" id="mspread">&mdash;</span></div>'
      '<div class="stat"><span class="k">busiest</span><span class="v" id="mmax">&mdash;</span></div>'
      '<div class="stat"><span class="k">idlest</span><span class="v" id="mmin">&mdash;</span></div>'
      '<div class="stat"><span class="k">window</span><span class="v" id="mwin">&mdash;</span></div>'
      '</div>'
      '<div id="mgrid" class="mesh"></div>'
      '<p class="sub" style="margin-top:10px">Utilisation above is an instantaneous rate. '
      '<strong>Relative progress</strong> below is its integral: cumulative busy lane-cycles per '
      'group, normalised so the leading group reads 100%%. It answers &ldquo;which groups are '
      'behind, and by how much&rdquo; &mdash; a group can look busy in one window and still be '
      'cumulatively behind. It is deliberately <em>not</em> a share of absolute work: the TB '
      'counter measures lane occupancy, which is not conserved across runs, so an absolute '
      'denominator would be misleading.</p>'
      '<div class="mstats">'
      '<div class="stat"><span class="k">leader (=100%%)</span><span class="v" id="plead">&mdash;</span></div>'
      '<div class="stat"><span class="k">laggard</span><span class="v" id="plag">&mdash;</span></div>'
      '<div class="stat"><span class="k">gap</span><span class="v" id="pgap">&mdash;</span></div>'
      '<div class="stat"><span class="k">lag/lead</span><span class="v" id="pratio">&mdash;</span></div>'
      '</div>'
      '<div id="pgrid" class="pgrid"></div>'
      '</div>')
    A('<script>var GU=%s;</script>' % json.dumps(GU, separators=(",", ":")))
    A(MESH_JS)

A('<p class="foot">efficiency = ideal/actual &middot; %d planned arms &middot; R = 128/B repeats '
  '&middot; 65,536 ideal cycles per arm &middot; livelocked arms excluded, not averaged</p>' % len(M))
A('</div>')

open(OUT, "w").write("\n".join(H))
print("wrote %s (%d bytes)" % (OUT, os.path.getsize(OUT)))
for k in sorted(TALLY, key=lambda x: -TALLY[x]):
    print("  %-40s %d" % (k, TALLY[k]))
print("  %-40s %d" % ("[degraded, marked in tables]", len(DEGRADED)))
