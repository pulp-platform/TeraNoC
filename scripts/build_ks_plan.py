#!/usr/bin/env python3
"""Regenerate ks_plan.json (the plan artifact's data) from the same status() the sweep page uses."""
import io, contextlib, os, json, re
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN=os.path.join(ROOT,"scripts","gen_ks_sweep_artifact.py")
src=io.open(GEN,encoding="utf-8").read()
src=src.replace('open(OUT, "w").write("\\n".join(H))','pass').replace("__file__",repr(GEN))
g={"__name__":"__main__"}
with contextlib.redirect_stdout(open(os.devnull,"w")):
    try: exec(compile(src,"gen","exec"),g)
    except SystemExit: pass
M,status,armname,FLEET=g["M"],g["status"],g["armname"],g["FLEET"]
out=[]
for r in sorted(M,key=lambda x:(x["mesh"],x["prec"],x["KS"],x["B"])):
    n=armname(r); cls,cell,lab=status(r)
    cyc=None
    m=re.search(r"\(([\d,]+) cyc",lab)
    if m: cyc=int(m.group(1).replace(",",""))
    eff=None
    mm=re.match(r"^([\d.]+)%",cell)
    if mm: eff=float(mm.group(1))
    st=("measured" if lab.startswith("measured") else
        "degraded" if ("livelock" in lab or "degraded" in lab) else
        "running" if FLEET.get(n,("",""))[0] in ("running","submitted","dispatched") else
        "nodata" if "never activated" in lab else "planned")
    out.append(dict(arm=n,mesh=r["mesh"],prec=r["prec"],KS=r["KS"],B=r["B"],D=r["D"],I=r["I"],
                    sh=r["sh"],vl=r.get("vl"),R=r.get("R"),ideal=r["ideal"],st=st,note=lab,
                    cyc=cyc,eff=eff,
                    band=1 if (r["sh"] in (2,4) and (r.get("vl") or 0)>=128) else 0,
                    split=1 if "split load" in lab else 0))
io.open("/tmp/claude-620771/ks_plan.json","w").write(json.dumps(out,separators=(",",":")))
print("ks_plan.json: %d arms, %d measured" % (len(out), sum(1 for x in out if x["st"]=="measured")))
