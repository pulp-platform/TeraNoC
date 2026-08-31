#!/usr/bin/env python3
"""Build /tmp/claude-620771/perf_all.json -- one counter record per planned arm, both meshes.

Counters come from the arm's own transcript where we hold one, and from the live node-side
transcript for arms still running. This is the single source the artifact's unified performance
table renders, so nothing here may quietly disagree with status().
"""
import io, contextlib, os, json, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCR  = "/tmp/claude-620771"
GEN  = os.path.join(ROOT, "scripts", "gen_ks_sweep_artifact.py")

src = io.open(GEN, encoding="utf-8").read()
src = src.replace('open(OUT, "w").write("\\n".join(H))', 'pass').replace("__file__", repr(GEN))
g = {"__name__": "__main__"}
with contextlib.redirect_stdout(open(os.devnull, "w")):
    try: exec(compile(src, "gen", "exec"), g)
    except SystemExit: pass

M, status, armname = g["M"], g["status"], g["armname"]
RUN2, RES, FLEET, RANK = g["RUN2"], g["RES"], g["FLEET"], g["_PREF_RANK"]

def from_transcript(path):
    b = open(path, "rb").read()
    return dict(tmo=sum(int(x) for x in re.findall(rb"mshr_timeout=\+(\d+)", b)),
                rh=len(re.findall(rb"RH STUCK", b)),
                byp=sum(int(x) for x in re.findall(rb"bankfull_bypass=\+(\d+)", b)),
                win=len(re.findall(rb"\[STALLG\] bench", b)))

def counters(n):
    v = RUN2.get(n) or {}
    if v.get("tmo") is not None and (v.get("bench") or 0) > 0:
        return dict(tmo=v.get("tmo") or 0, rh=v.get("rh") or 0,
                    byp=v.get("byp") or 0, win=int(v.get("bench") or 0))
    for k in RANK:
        if k not in RES.get(n, {}): continue
        p = os.path.join(ROOT, "hardware", "%s_%s" % (k, n), "transcript")
        if os.path.exists(p): return from_transcript(p)
    return None

# live counters harvested earlier for running arms; keep them when we have nothing better
try:    LIVE = {x["arm"]: x for x in json.load(open(os.path.join(SCR, "perf8x8.json")))}
except Exception: LIVE = {}

out = []
for r in sorted(M, key=lambda x: (x["mesh"], x["prec"], x["KS"], x["B"])):
    n = armname(r); cls, cell, lab = status(r)
    st = ("measured" if lab.startswith("measured") else
          "livelocked" if ("livelock" in lab or "degraded" in lab) else
          "running" if FLEET.get(n, ("", ""))[0] in ("running", "submitted", "dispatched")
          else "pending")
    cyc = None
    m = re.search(r"\(([\d,]+) cyc", lab)
    if m: cyc = int(m.group(1).replace(",", ""))
    eff = None
    mm = re.match(r"^([\d.]+)%", cell)
    if mm: eff = float(mm.group(1))
    ct = counters(n) or {k: LIVE.get(n, {}).get(k, 0) for k in ("tmo", "rh", "byp", "win")}
    out.append(dict(arm=n, mesh=r["mesh"], prec=r["prec"], KS=r["KS"], B=r["B"], D=r["D"],
                    I=r["I"], sh=r["sh"], vl=r.get("vl"), st=st, cyc=cyc, eff=eff,
                    util=LIVE.get(n, {}).get("util"),
                    band=1 if (r["sh"] in (2, 4) and (r.get("vl") or 0) >= 128) else 0, **ct))
io.open(os.path.join(SCR, "perf_all.json"), "w").write(json.dumps(out, separators=(",", ":")))
print("perf_all.json: %d arms, %d measured, %d with counters"
      % (len(out), sum(1 for x in out if x["st"] == "measured"),
         sum(1 for x in out if x["tmo"] or x["rh"])))
