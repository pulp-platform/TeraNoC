#!/usr/bin/env python3
"""Corrected-MSHR-hash results page.

ONE DATASET. Every table, card, grid and the per-group explorer are derived from the same
ARMS dict built below -- there is no second path to the numbers, so they cannot disagree.

STALENESS RULE. A pre-fix cycle count for a shape that the bank-hash defect ACTUALLY AFFECTED
(docs/benchmarks/mshr_hash_affected.tsv, 72 cells) is not a valid measurement of this design and
is NOT shown as one. Such a shape appears only once its corrected re-run has landed. Shapes the
defect never touched keep their original number, which is still valid.

TWO PERCENTAGES, deliberately never conflated:
  efficiency     = ideal/actual cycles          <- rank on this
  FPU occupancy  = the TB `cum=` counter        <- lane occupancy, NOT conserved across runs
"""
import glob, json, os, re, sys, time

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
SCR  = "/tmp/claude-620771"
OUT  = os.path.join(SCR, "hashfix_results.html")

# ---- inputs ----------------------------------------------------------------------------------
def _load(path, what):
    try: return json.load(open(path))
    except Exception as e:
        sys.stderr.write("%s load failed: %s\n" % (what, e)); return {}

SM = _load(os.path.join(SCR, "sweep_matrix.json"), "sweep_matrix") or []
GU_ALL = _load(os.path.join(SCR, "ks_group_util.json"), "group_util")

AFFECTED = set()
try:
    for l in open(os.path.join(ROOT, "docs/benchmarks/mshr_hash_affected.tsv")):
        if l.startswith("#") or not l.strip(): continue
        f = l.rstrip("\n").split("\t")
        if len(f) >= 5: AFFECTED.add((f[1], f[2], int(f[3]), f[4]))
except IOError as e:
    sys.stderr.write("hash-affected list missing: %s\n" % e)

# Scrape cache. A full pass reads ~17 GB of transcripts, several of which are >500 MB, which made
# regenerating this page a multi-minute job -- too slow for something meant to be kept current.
# Key on (size, mtime): a transcript that has not changed cannot have new counters.
_CACHE_PATH = os.path.join(SCR, "hashfix_scrape_cache.json")
try:    _CACHE = json.load(open(_CACHE_PATH))
except Exception: _CACHE = {}
_CACHE_HITS = [0, 0]

def scrape(p):
    try: st = os.stat(p)
    except OSError: return None
    ck = "%s|%d|%d" % (p, st.st_size, int(st.st_mtime))
    if ck in _CACHE:
        _CACHE_HITS[0] += 1
        return _CACHE[ck]
    _CACHE_HITS[1] += 1
    r = _scrape_raw(p)
    if r is not None: _CACHE[ck] = r
    return r

def _scrape_raw(p):
    try: b = re.sub(rb"(?m)^# ", b"", open(p, "rb").read())
    except IOError: return None
    m  = re.search(rb"execution took (\d+)", b)
    u  = re.findall(rb"\[FPU\] bench[^\n]*cum=([0-9.]+)%", b)
    t  = re.findall(rb"timeouts:\s+resp_hold=(\d+) cache_aged=(\d+) issue=(\d+)\s+bankfull_bypass=(\d+)", b)
    tm = re.findall(rb"mshr_timeout=\+(\d+)", b)
    return dict(cyc=int(m.group(1)) if m else None, rh=b.count(b"RH STUCK"),
                util=float(u[-1]) if u else None,
                rhold=int(t[-1][0]) if t else None, aged=int(t[-1][1]) if t else None,
                issue=int(t[-1][2]) if t else None, bf=int(t[-1][3]) if t else None,
                tmo=sum(int(x) for x in tm) if tm else 0)

# ---- THE dataset -------------------------------------------------------------------------------
ARMS = {}
for r in SM:
    key = "%s_%s_ks%d_%dx%dx%d" % (r["mesh"], r["prec"], r["KS"], r["B"], r["D"], r["I"])
    ARMS[key] = dict(mesh=r["mesh"], prec=r["prec"], ks=r["KS"], B=r["B"], D=r["D"], I=r["I"],
                     ideal=r.get("ideal"), new=None, old=None, old_pref=None,
                     affected=(r["mesh"], r["prec"], r["KS"], "%dx%dx%d" % (r["B"], r["D"], r["I"])) in AFFECTED)

_PREF_RANK = ["wc8", "wc4", "wc", "wa8", "s8k8", "wb", "run2", "wa2"]
for d in glob.glob(os.path.join(ROOT, "hardware", "*_[48]x[48]_*")):
    b = os.path.basename(d)
    mf = re.match(r"^(.+?)_(?:hf|rf|r8)_([48]x[48]_.+)$", b)
    ms = re.match(r"^(.+?)_sw_([48]x[48]_.+)$", b)
    m, corrected = (mf, True) if mf else ((ms, False) if ms else (None, False))
    if not m or m.group(2) not in ARMS: continue
    s = scrape(os.path.join(d, "transcript"))
    if not s: continue
    a = ARMS[m.group(2)]
    if corrected:
        if s.get("cyc") and (a["new"] is None or s["cyc"]): a["new"] = s
    else:
        pref = m.group(1)
        rank = _PREF_RANK.index(pref) if pref in _PREF_RANK else 99
        if a["old"] is None or rank < (_PREF_RANK.index(a["old_pref"]) if a["old_pref"] in _PREF_RANK else 99):
            a["old"], a["old_pref"] = s, pref

def eff(a, cyc):
    return (100.0 * a["ideal"] / cyc) if (a.get("ideal") and cyc) else None
def effs(a, cyc):
    e = eff(a, cyc); return ("%.1f%%" % e) if e else "&mdash;"
def fmt(n): return format(n, ",") if n else "&mdash;"

# ---- classification, applying the staleness rule ------------------------------------------------
for k, a in ARMS.items():
    o, n = a["old"], a["new"]
    o_ok = bool(o and o.get("cyc"))
    if n and o_ok:                      a["cls"] = "recovered" if False else "rerun"
    elif n and o and not o_ok:          a["cls"] = "recovered"      # baseline never completed
    elif n:                             a["cls"] = "rerun"          # corrected, no baseline
    elif o_ok and not a["affected"]:    a["cls"] = "valid"          # untouched by the defect
    elif o_ok and a["affected"]:        a["cls"] = "stale"          # pre-fix, defect applied -> HIDE
    elif o and not o_ok:
        # SPLIT. Calling every result-less baseline "livelocked" was wrong: 28 of the 36 so
        # labelled at 8x8 have RH=0 and one of them ran at 73.74% utilisation -- it was working
        # and got cut off, not livelocked. RH>1000 is the established livelock signature
        # (rh_livelock_root_cause); anything else is "no result recorded", cause undiagnosed.
        a["cls"] = "livelocked" if o.get("rh", 0) > 1000 else "noresult"
    else:                               a["cls"] = "none"

SHOWN   = {k: a for k, a in ARMS.items() if a["cls"] in ("recovered", "rerun", "valid")}
HIDDEN  = {k: a for k, a in ARMS.items() if a["cls"] == "stale"}
REC     = sorted([a for a in SHOWN.values() if a["cls"] == "recovered"], key=lambda x: -x["old"]["rh"])
RERUN   = sorted([a for a in SHOWN.values() if a["cls"] == "rerun"],
                 key=lambda x: (x["new"]["cyc"] - x["old"]["cyc"]) / float(x["old"]["cyc"]) if x["old"] and x["old"].get("cyc") else 0)
VALID   = sorted([a for a in SHOWN.values() if a["cls"] == "valid"], key=lambda x: (x["mesh"], x["prec"], x["ks"], x["B"]))

def nm(a): return "%s_%s_ks%d_%dx%dx%d" % (a["mesh"], a["prec"], a["ks"], a["B"], a["D"], a["I"])

# ---- SINGLE BENCHMARK RESULT TABLE ---------------------------------------------------------
# Emitted from the SAME ARMS dict as the page, so the doc and the artifact cannot disagree.
# TSV for machines, Markdown for humans. Regenerated on every run of this script.
_TSV = os.path.join(ROOT, "docs/benchmarks/decode_sweep_results.tsv")
_MD  = os.path.join(ROOT, "docs/benchmarks/decode_sweep_results.md")

def _row(a):
    # A STALE row must carry NO numbers. Its only measurement is a pre-fix cycle count for a
    # hash-affected shape, which is not a valid result -- and the first version of this function
    # fell back to a["old"] for cycles_after, so the withheld number reappeared one column to the
    # right. Counters come from the corrected run when there is one, from the baseline only when
    # that baseline is itself valid.
    o = a["old"]
    if a["cls"] == "stale":
        s, cyc = {}, None
    else:
        s = a["new"] or (o if a["cls"] in ("valid", "livelocked", "noresult") else {}) or {}
        cyc = a["new"]["cyc"] if a["new"] else (o.get("cyc") if (o and a["cls"] == "valid") else None)
    d = (100.0*(a["new"]["cyc"]-o["cyc"])/o["cyc"]) if (a["new"] and o and o.get("cyc")) else None
    e = eff(a, cyc)
    return [nm(a), a["mesh"], a["prec"], str(a["ks"]), "%dx%dx%d" % (a["B"], a["D"], a["I"]),
            a["cls"], "yes" if a["affected"] else "no",
            (str(o["cyc"]) if (o and o.get("cyc") and a["cls"] != "stale") else "-"),
            str(cyc) if cyc else "-",
            ("%+.2f" % d) if d is not None else "-",
            ("%.1f" % e) if e else "-",
            ("%.2f" % s["util"]) if s.get("util") else "-",
            str(s.get("rh", "-")), str(s.get("rhold", "-")), str(s.get("aged", "-")),
            str(s.get("issue", "-")), str(s.get("bf", "-")), str(s.get("tmo", "-"))]

_HDR = ["arm","mesh","prec","KS","shape","class","hash_affected","cycles_before","cycles_after",
        "delta_pct","efficiency_pct","fpu_occupancy_pct","RH","resp_hold","cache_aged","issue",
        "bankfull","tmo"]
_rows = sorted((_row(a) for a in ARMS.values() if a["cls"] != "none"),
               key=lambda r: (r[1], r[2], int(r[3]), r[0]))
try:
    with open(_TSV, "w") as fh:
        fh.write("# Decode B x KS sweep -- single result table. GENERATED by\n"
                 "# scripts/gen_hashfix_results_artifact.py from the same dataset as the artifact.\n"
                 "# class: recovered=baseline never completed | rerun=corrected re-run, baseline existed\n"
                 "#        valid=defect never applied, original number stands | stale=hash-affected,\n"
                 "#        corrected re-run pending, cycles_before deliberately NOT a valid result\n"
                 "#        livelocked=never produced a cycle count\n"
                 "# efficiency = ideal/actual. fpu_occupancy = TB cum= counter (NOT conserved across runs).\n")
        fh.write("\t".join(_HDR) + "\n")
        for r in _rows: fh.write("\t".join(r) + "\n")
    with open(_MD, "w") as fh:
        fh.write("# Decode B x KS sweep - single result table\n\n")
        fh.write("> **GENERATED** by `scripts/gen_hashfix_results_artifact.py` from the same dataset\n"
                 "> as the artifact <https://claude.ai/code/artifact/3663f462-2b8a-4d5f-a97a-88003efe9074>.\n"
                 "> Do not hand-edit. `efficiency` = ideal/actual and is the metric to rank on;\n"
                 "> `fpu_occupancy` is the TB `cum=` counter and is NOT conserved across runs.\n"
                 "> A `stale` row's `cycles_before` is a pre-fix number for a hash-affected shape and\n"
                 "> is **not** a valid measurement of this design.\n\n")
        fh.write("Generated %s. %d rows.\n\n" % (time.strftime("%Y-%m-%d %H:%M"), len(_rows)))
        fh.write("| " + " | ".join(_HDR) + " |\n")
        fh.write("|" + "|".join("---" for _ in _HDR) + "|\n")
        for r in _rows: fh.write("| " + " | ".join(r) + " |\n")
    print("  wrote %s and %s (%d rows)" % (os.path.basename(_TSV), os.path.basename(_MD), len(_rows)))
except IOError as _e:
    sys.stderr.write("result-table write failed: %s\n" % _e)

# ---- page --------------------------------------------------------------------------------------
H=[]; A=H.append
A('<title>Corrected Hash Re-Runs</title>')
A('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?'
  'family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap">')
A('''<style>
:root{--bg:#f7f6f3;--surf:#fff;--ink:#1a1917;--ink2:#57534e;--ink3:#8a8480;--line:#e0ddd7;
      --good:#166534;--bad:#9a3412;--accent:#7c5c3e;--rule:#c9c3ba}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
      --bg:#161513;--surf:#201e1b;--ink:#f0ede8;--ink2:#b5aea6;--ink3:#7d766e;--line:#33302b;
      --good:#86efac;--bad:#fdba74;--accent:#d6b88f;--rule:#3d3934}}
:root[data-theme="dark"]{--bg:#161513;--surf:#201e1b;--ink:#f0ede8;--ink2:#b5aea6;--ink3:#7d766e;
      --line:#33302b;--good:#86efac;--bad:#fdba74;--accent:#d6b88f;--rule:#3d3934}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 "IBM Plex Sans",system-ui,sans-serif;padding:40px 22px 80px}
.wrap{max-width:1120px;margin:0 auto}
h1{font-size:27px;margin:0 0 6px;letter-spacing:-.02em;text-wrap:balance}
h2{font-size:17px;margin:38px 0 4px}
h3{font-size:14px;margin:18px 0 8px;color:var(--ink2)}
p{margin:8px 0 16px;color:var(--ink2);max-width:76ch}
.sub{color:var(--ink2);margin:0 0 26px;font-size:14px}
.card{background:var(--surf);border:1px solid var(--line);border-radius:9px;padding:18px 20px;margin:14px 0}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:20px 0}
.kpi{background:var(--surf);border:1px solid var(--line);border-radius:9px;padding:15px 17px}
.kpi .v{font:600 25px/1.15 "IBM Plex Mono",monospace;font-variant-numeric:tabular-nums}
.kpi .k{color:var(--ink3);font-size:11.5px;text-transform:uppercase;letter-spacing:.07em;margin-top:5px}
.tw{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13px}
th{text-align:left;color:var(--ink3);font-weight:600;font-size:10.5px;text-transform:uppercase;
   letter-spacing:.05em;padding:7px 10px 7px 0;border-bottom:1.5px solid var(--rule);white-space:nowrap}
td{padding:7px 10px 7px 0;border-bottom:1px solid var(--line);font-variant-numeric:tabular-nums;white-space:nowrap}
td.n,th.n{text-align:right}
.mono{font-family:"IBM Plex Mono",monospace;font-size:12px}
.good{color:var(--good);font-weight:600}.bad{color:var(--bad);font-weight:600}
.big{font-weight:600}.dim,td.dim{color:var(--ink3)}
.none{color:var(--ink3);font-style:italic}
.note{border-left:3px solid var(--accent);padding:2px 0 2px 15px;margin:18px 0;color:var(--ink2)}
code{font-family:"IBM Plex Mono",monospace;font-size:.9em;background:var(--bg);border:1px solid var(--line);border-radius:4px;padding:1px 5px}
.ctl{display:flex;flex-wrap:wrap;gap:13px;align-items:center;margin:12px 0 6px;font-size:12.5px}
.ctl label{display:flex;align-items:center;gap:7px;color:var(--ink2)}
.ctl .grow{flex:1;min-width:220px}
.ctl select{font-family:"IBM Plex Mono",monospace;font-size:12px;padding:3px 6px;border:1px solid var(--line);border-radius:4px;background:var(--bg);color:var(--ink)}
.ctl input[type=range]{flex:1;accent-color:var(--accent);min-width:160px}
.ctl.facets{gap:10px 14px;padding:10px 12px;background:var(--bg);border:1px solid var(--line);border-radius:6px}
.ctl.facets select{min-width:74px}
.ctl.facets label{font-family:"IBM Plex Mono",monospace;font-size:11px}
.rst{font-family:"IBM Plex Mono",monospace;font-size:11px;padding:3px 9px;border:1px solid var(--line);border-radius:4px;background:var(--surf);color:var(--ink2);cursor:pointer}
.mstats{display:flex;flex-wrap:wrap;gap:22px;margin:10px 0 12px}
.stat{display:flex;flex-direction:column;gap:1px}
.stat .k{font-family:"IBM Plex Mono",monospace;font-size:10px;letter-spacing:.09em;text-transform:uppercase;color:var(--ink3)}
.stat .v{font-size:17px;font-weight:600;font-variant-numeric:tabular-nums}
.mesh{display:grid;gap:2px;max-width:560px}
.mesh .cell{aspect-ratio:1;display:flex;align-items:center;justify-content:center;font-family:"IBM Plex Mono",monospace;font-size:12px;font-variant-numeric:tabular-nums;border-radius:3px}
.mesh.dense{max-width:660px}.mesh.dense .cell{font-size:9px;border-radius:1px}
.pgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:3px 20px;margin-top:6px}
.prow{display:flex;align-items:center;gap:7px;font-size:11.5px}
.prow .gid{font-family:"IBM Plex Mono",monospace;color:var(--ink3);width:26px;flex:none}
.prow .pb2{flex:1;height:7px;background:var(--line);border-radius:4px;overflow:hidden}
.prow .pb2 span{display:block;height:100%;background:var(--accent);border-radius:4px}
.prow .pv{font-family:"IBM Plex Mono",monospace;font-variant-numeric:tabular-nums;color:var(--ink2);width:34px;text-align:right;flex:none}
.foot{color:var(--ink3);font-size:12px;margin-top:34px;border-top:1px solid var(--line);padding-top:14px}
</style>''')
A('<div class="wrap">')
A('<h1>Corrected MSHR bank hash &mdash; results</h1>')
A('<p class="sub">Every table, grid and chart on this page is derived from one dataset. '
  'Generated %s.</p>' % time.strftime("%Y-%m-%d %H:%M"))

A('<div class="note"><b>What is shown, and what is withheld.</b> The bank-hash defect made the '
  'pre-fix number wrong for %d shapes. Those appear here <b>only</b> once their corrected re-run '
  'has landed &mdash; %d still have none and are omitted rather than shown stale. Shapes the '
  'defect never touched keep their original measurement, which is still valid.<br><br>'
  '<b>Two percentages, never the same quantity.</b> <b>Efficiency</b> = ideal/actual cycles; rank '
  'on this. <b>FPU occupancy</b> is the testbench <code>cum=</code> counter (lane-cycles busy), '
  'which is not conserved across runs and has inverted a real ranking here before. Example: '
  '<code>4x4_fp16_ks4_8x128x8192</code> is <b>69.8%% efficiency</b> but <b>78.45%% occupancy</b>.'
  '</div>' % (len(AFFECTED), len(HIDDEN)))

_nul = [a for a in RERUN if a["old"] and a["old"].get("cyc")]
_sb = sum(a["old"]["cyc"] for a in _nul) or 1
_sa = sum(a["new"]["cyc"] for a in _nul)
A('<div class="kpis">')
A('<div class="kpi"><div class="v good">%d</div><div class="k">recovered<br>produced nothing before</div></div>' % len(REC))
A('<div class="kpi"><div class="v">%+.2f%%</div><div class="k">aggregate on the %d<br>that already worked</div></div>' % (100.0*(_sa-_sb)/_sb, len(_nul)))
A('<div class="kpi"><div class="v">%d</div><div class="k">shapes still awaiting<br>a corrected re-run</div></div>' % len(HIDDEN))
A('<div class="kpi"><div class="v">%d</div><div class="k">shapes shown<br>of %d in the sweep</div></div>' % (len(SHOWN), len(ARMS)))
A('</div>')

# ---- one table renderer, used for every results table -------------------------------------------
COLS = [("arm",   lambda a: '<td class="mono">%s</td>' % nm(a)),
        ("class", lambda a: '<td class="dim">%s</td>' % a["cls"]),
        ("before",lambda a: '<td class="n">%s</td>' % (format(a["old"]["cyc"], ",")
                    if a["old"] and a["old"].get("cyc") else '<span class="none">never</span>')),
        ("after", lambda a: '<td class="n big">%s</td>' % (format(a["new"]["cyc"], ",") if a["new"] else "&mdash;")),
        ("delta", lambda a: _delta(a)),
        ("efficiency", lambda a: '<td class="n big">%s</td>' % effs(a, (a["new"] or a["old"] or {}).get("cyc"))),
        ("FPU occupancy", lambda a: '<td class="n">%s</td>' % _occ(a)),
        ("RH",        lambda a: _z((a["new"] or a["old"] or {}).get("rh"))),
        ("resp_hold", lambda a: _z((a["new"] or a["old"] or {}).get("rhold"))),
        ("aged",      lambda a: _z((a["new"] or a["old"] or {}).get("aged"))),
        ("issue",     lambda a: _z((a["new"] or a["old"] or {}).get("issue"))),
        ("bankfull",  lambda a: _z((a["new"] or a["old"] or {}).get("bf"))),
        ("tmo",       lambda a: _z((a["new"] or a["old"] or {}).get("tmo")))]

def _z(v):
    return '<td class="n dim">0</td>' if v in (0, None) else '<td class="n bad">%s</td>' % format(v, ",")
def _occ(a):
    s = a["new"] or a["old"] or {}
    return ("%.2f%%" % s["util"]) if s.get("util") else "&mdash;"
def _delta(a):
    o, n = a["old"], a["new"]
    if not (n and o and o.get("cyc")): return '<td class="n dim">&mdash;</td>'
    d = 100.0 * (n["cyc"] - o["cyc"]) / o["cyc"]
    cls = "bad" if d > 1.0 else ("good" if d < -0.5 else "")
    return '<td class="n %s">%+.2f%%</td>' % (cls, d)

def table(rows):
    if not rows: return
    A('<div class="card"><div class="tw"><table><thead><tr>')
    for i, (h, _) in enumerate(COLS):
        A('<th%s>%s</th>' % ('' if i == 0 else ' class="n"' if i > 1 else '', h))
    A('</tr></thead><tbody>')
    for a in rows:
        A('<tr>' + "".join(f(a) for _, f in COLS) + '</tr>')
    A('</tbody></table></div></div>')

A('<h2>Arms that produced no result before <span class="dim">&mdash; %d</span></h2>' % len(REC))
A('<p>Each sat in the RH livelock at 3&ndash;13%% FPU occupancy and was killed by the wall clock '
  'without ever emitting a cycle count. There is no &ldquo;before&rdquo; number because none '
  'existed. Counters shown are from the corrected run.</p>')
table(REC)

A('<h2>Corrected re-runs whose baseline also completed <span class="dim">&mdash; %d, aggregate %+.2f%%</span></h2>'
  % (len(_nul), 100.0*(_sa-_sb)/_sb))
A('<p>A positive delta is <b>slower</b>. Sorted best to worst.</p>')
table(RERUN)

if VALID:
    A('<h2>Shapes the defect never touched <span class="dim">&mdash; %d</span></h2>' % len(VALID))
    A('<p>Not re-run, and they do not need to be: the bank-hash defect did not apply to these '
      'shapes, so their original measurement stands. Shown for completeness of the grid.</p>')
    table(VALID)

# ---- the grid, from the SAME ARMS dict -----------------------------------------------------------
KSS = sorted({a["ks"] for a in ARMS.values()})
A('<h2>The full grid, both meshes</h2>')
A('<p>Cells carry <b>efficiency</b> = ideal/actual. '
  '<span class="good">green</span> = measured on the corrected hash &middot; '
  'plain = the defect never applied, original number still valid &middot; '
  '<span class="bad">await</span> = hash-affected, corrected re-run not landed, deliberately '
  '<b>not</b> showing the stale pre-fix number &middot; '
  '<span class="dim">livelock</span> = RH&gt;1000, the livelock signature &middot; '
  '<span class="dim">no result</span> = no cycle count recorded, cause undiagnosed (NOT a '
  'livelock: some of these ran at high utilisation and were simply cut off) &middot; '
  '<span class="dim">&middot;</span> = KS does not divide B. Hover any cell for its cycles.</p>')
for mesh, cores in (("4x4", 256), ("8x8", 1024)):
    rows = [a for a in ARMS.values() if a["mesh"] == mesh]
    if not rows: continue
    A('<div class="card"><h3>%s mesh &mdash; %d cores</h3>' % (mesh.replace("x", "&times;"), cores))
    for prec in ("fp16", "fp32"):
        sub = [a for a in rows if a["prec"] == prec]
        if not sub: continue
        byB = {}
        for a in sub: byB.setdefault(a["B"], {})[a["ks"]] = a
        A('<h3 style="margin:14px 0 4px">%s</h3>' % prec)
        A('<div class="tw"><table><thead><tr><th>B</th><th class="n">D</th><th class="n">I</th>'
          + "".join('<th class="n">KS=%d</th>' % k for k in KSS) + '</tr></thead><tbody>')
        for B in sorted(byB):
            any_a = next(iter(byB[B].values()))
            A('<tr><td class="mono">%d</td><td class="n dim">%d</td><td class="n dim">%d</td>' % (B, any_a["D"], any_a["I"]))
            for k in KSS:
                a = byB[B].get(k)
                if a is None:
                    A('<td class="n dim" title="KS does not divide B">&middot;</td>'); continue
                if a["cls"] in ("recovered", "rerun"):
                    o = a["old"]
                    ttl = "%s &mdash; corrected: %s cyc%s" % (nm(a), format(a["new"]["cyc"], ","),
                          (", was %s" % format(o["cyc"], ",")) if (o and o.get("cyc")) else ", baseline never completed")
                    A('<td class="n good" title="%s">%s</td>' % (ttl, effs(a, a["new"]["cyc"])))
                elif a["cls"] == "valid":
                    A('<td class="n" title="%s &mdash; %s cyc, defect did not apply">%s</td>'
                      % (nm(a), format(a["old"]["cyc"], ","), effs(a, a["old"]["cyc"])))
                elif a["cls"] == "stale":
                    A('<td class="n bad" title="%s &mdash; hash-affected; pre-fix number withheld, re-run pending">await</td>' % nm(a))
                elif a["cls"] == "livelocked":
                    A('<td class="n dim" title="%s &mdash; RH %s, livelock signature">livelock</td>'
                      % (nm(a), format(a["old"]["rh"], ",")))
                elif a["cls"] == "noresult":
                    _u = a["old"].get("util")
                    A('<td class="n dim" title="%s &mdash; no cycle count recorded, RH=%s%s; cause '
                      'undiagnosed, NOT a livelock">no result</td>'
                      % (nm(a), a["old"].get("rh", 0),
                         (", last util %.2f%%" % _u) if _u else ", no FPU data"))
                else:
                    A('<td class="n dim" title="%s &mdash; not dispatched">&middot;</td>' % nm(a))
            A('</tr>')
        A('</tbody></table></div>')
    A('</div>')

# ---- per-group explorer, restricted to the SHOWN arms --------------------------------------------
def _gu_key(a):   # ks_group_util labels look like "fixed fp16 KS=2 8x128x8192" / "done fp32 KS=1 ..."
    return "%s KS=%d %dx%dx%d" % (a["prec"], a["ks"], a["B"], a["D"], a["I"])
_ok = {_gu_key(a) for a in SHOWN.values()}
GU = {k: v for k, v in GU_ALL.items() if " " in k and k.split(" ", 1)[1] in _ok}
try:
    MESH_JS = re.search(r'MESH_JS = """(.*?)"""',
                        open(os.path.join(ROOT, "scripts", "gen_ks_sweep_artifact.py")).read(), re.S).group(1)
except Exception as e:
    MESH_JS = ""; sys.stderr.write("MESH_JS extract failed: %s\n" % e)

if GU and MESH_JS:
    A('<h2>Per-group FPU utilisation over the benchmark</h2>')
    A('<p>Each cell is one group of the mesh, coloured by the share of its FPU lane-cycles busy in '
      'that window. Restricted to the same shapes as the tables above &mdash; %d series. Filter '
      '<b>run = fixed</b> for the corrected arms.</p>' % len(GU))
    A('<div class="card">')
    A('<div class="ctl facets">'
      '<label>mesh <select id="f_mesh"></select></label><label>state <select id="f_state"></select></label>'
      '<label>run <select id="f_run"></select></label><label>prec <select id="f_prec"></select></label>'
      '<label>KS <select id="f_ks"></select></label><label>B (M) <select id="f_B"></select></label>'
      '<label>D (N) <select id="f_D"></select></label><label>I (P) <select id="f_I"></select></label>'
      '<label>arm <select id="marm"></select></label>'
      '<button type="button" id="f_reset" class="rst">reset</button>'
      '<span class="mono dim" id="f_count"></span></div>')
    A('<div class="ctl"><label class="grow">window <input id="mper" type="range" min="0" max="1" value="0"></label>'
      '<span class="mono dim" id="mcyc">&mdash;</span></div>')
    A('<div class="mstats">'
      + "".join('<div class="stat"><span class="k">%s</span><span class="v" id="%s">&mdash;</span></div>' % (k, i)
                for k, i in [("mesh","mgn"),("mean util","mmean"),("spread","mspread"),
                             ("busiest","mmax"),("idlest","mmin"),("window","mwin")]) + '</div>')
    A('<div id="mgrid" class="mesh"></div>')
    A('<p style="margin-top:12px">Utilisation above is an instantaneous rate. <b>Relative progress</b> '
      'below is its integral: cumulative busy lane-cycles per group, normalised so the leading group '
      'reads 100%. A group can look busy in one window and still be cumulatively behind.</p>')
    A('<div class="mstats">'
      + "".join('<div class="stat"><span class="k">%s</span><span class="v" id="%s">&mdash;</span></div>' % (k, i)
                for k, i in [("leader (=100%)","plead"),("laggard","plag"),("gap","pgap"),("lag/lead","pratio")]) + '</div>')
    A('<div id="pgrid" class="pgrid"></div></div>')
    A('<script>var GU=%s;</script>' % json.dumps(GU, separators=(",", ":")))
    A(MESH_JS)

A('<div class="foot">One dataset: %d shapes from sweep_matrix.json, transcripts under '
  '<code>hardware/{hashfix_hf,rf_rf,r8_r8,r8b_r8}_*</code> (corrected) and '
  '<code>hardware/*_sw_*</code> (baselines), hash-affected list from '
  '<code>docs/benchmarks/mshr_hash_affected.tsv</code>. Regenerate: '
  '<code>scripts/gen_hashfix_results_artifact.py</code>.</div>' % len(ARMS))
A('</div>')
open(OUT, "w").write("\n".join(H))

# ---- self-checks ---------------------------------------------------------------------------------
vis = re.sub(r"<[^>]*>", " ", open(OUT).read())
miss = [nm(a) for a in SHOWN.values()
        if (a["new"] or a["old"]) and format((a["new"] or a["old"])["cyc"], ",") not in vis
        and (a["new"] or a["old"]).get("cyc")]
leak = [nm(a) for a in HIDDEN.values()
        if a["old"].get("cyc") and format(a["old"]["cyc"], ",") in vis]
# the TSV is a second output and needs the same guarantee -- the first version of _row leaked
# every withheld number into cycles_after there while the HTML check passed.
try:
    _tsv = open(_TSV).read()
    leak += ["%s (in TSV)" % nm(a) for a in HIDDEN.values()
             if a["old"].get("cyc") and ("\t%d\t" % a["old"]["cyc"]) in _tsv]
except IOError: pass
bad = []
if miss: bad.append("%d shown arm(s) whose cycle count is not in the visible text: %s" % (len(miss), miss[:5]))
if leak: bad.append("%d STALE hash-affected number(s) leaked into the page: %s" % (len(leak), leak[:5]))
if bad:
    for b in bad: sys.stderr.write("SELF-CHECK FAILED: %s\n" % b)
    sys.exit(3)
try:
    json.dump(_CACHE, open(_CACHE_PATH, "w"))
except IOError: pass
print("wrote %s  (scrape cache: %d hits, %d misses)" % (OUT, _CACHE_HITS[0], _CACHE_HITS[1]))
print("  shown %d (recovered %d, rerun %d, valid %d) | withheld-stale %d | livelocked %d"
      % (len(SHOWN), len(REC), len(RERUN), len(VALID), len(HIDDEN),
         len([a for a in ARMS.values() if a["cls"] == "livelocked"])))
print("  self-check OK: every shown number visible, no stale number leaked, %d group series" % len(GU))
