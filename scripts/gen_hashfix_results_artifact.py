#!/usr/bin/env python3
"""Standalone results page for the corrected-MSHR-hash + derived-LOAD_LMUL re-runs.

Deliberately SEPARATE from gen_ks_sweep_artifact.py: that page is a 16 MB campaign explorer
with 18 sections, and these results were unreadable inside it (they lived only in tooltips).
This page shows exactly one thing and shows it in visible tables.

Reads the delivered transcripts directly. No hidden state, no cached JSON.
"""
import glob, os, re, sys, time

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = "/tmp/claude-620771/hashfix_results.html"

def scrape(p):
    try: b = re.sub(rb"(?m)^# ", b"", open(p, "rb").read())
    except IOError: return None
    m = re.search(rb"execution took (\d+)", b)
    u = re.findall(rb"\[FPU\] bench[^\n]*cum=([0-9.]+)%", b)
    t = re.findall(rb"timeouts:\s+resp_hold=(\d+) cache_aged=(\d+)", b)
    return dict(cyc=int(m.group(1)) if m else None, rh=b.count(b"RH STUCK"),
                util=float(u[-1]) if u else None,
                rhold=int(t[-1][0]) if t else None)

def baseline(arm):
    for p in ("run2_sw_4x4_", "wc4_sw_4x4_"):
        bp = os.path.join(ROOT, "hardware", p + arm, "transcript")
        if os.path.exists(bp):
            s = scrape(bp)
            if s: return s, p.rstrip("_")
    return None, None

REC, NUL, RF = [], [], []
for d in sorted(glob.glob(os.path.join(ROOT, "hardware", "hashfix_hf_4x4_*"))):
    arm = os.path.basename(d).replace("hashfix_hf_4x4_", "")
    new = scrape(os.path.join(d, "transcript"))
    if not new or not new["cyc"]: continue
    old, _ = baseline(arm)
    if not old: continue
    (NUL if old["cyc"] else REC).append((arm, old, new))
for d in sorted(glob.glob(os.path.join(ROOT, "hardware", "rf_rf_4x4_*"))):
    arm = os.path.basename(d).replace("rf_rf_4x4_", "")
    new = scrape(os.path.join(d, "transcript"))
    if not new or not new["cyc"]: continue
    old, _ = baseline(arm)
    RF.append((arm, old, new))

# ---- per-group FPU utilisation series for the corrected arms --------------------------------
import json
GU = {}
try:
    _all = json.load(open("/tmp/claude-620771/ks_group_util.json"))
    for _k, _v in _all.items():
        if _k.startswith("fixed ") and _v.get("periods") and _v.get("mesh") == "4x4":
            GU[_k[6:]] = {"g": _v["groups"], "cyc": _v["cycles"],
                          "p": [{"c": w["cyc"], "u": w["u"]} for w in _v["periods"]]}
except Exception as _e:
    sys.stderr.write("group-util load failed: %s\n" % _e)

H = []
A = H.append
A('<title>Corrected Hash Re-Runs</title>')
A('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?'
  'family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap">')
A('''<style>
:root{--bg:#f7f6f3;--surf:#fff;--ink:#1a1917;--ink2:#57534e;--ink3:#8a8480;
      --line:#e0ddd7;--good:#166534;--bad:#9a3412;--accent:#7c5c3e;--rule:#c9c3ba}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
      --bg:#161513;--surf:#201e1b;--ink:#f0ede8;--ink2:#b5aea6;--ink3:#7d766e;
      --line:#33302b;--good:#86efac;--bad:#fdba74;--accent:#d6b88f;--rule:#3d3934}}
:root[data-theme="dark"]{--bg:#161513;--surf:#201e1b;--ink:#f0ede8;--ink2:#b5aea6;
      --ink3:#7d766e;--line:#33302b;--good:#86efac;--bad:#fdba74;--accent:#d6b88f;--rule:#3d3934}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
     font:15px/1.6 "IBM Plex Sans",system-ui,sans-serif;padding:40px 22px 80px}
.wrap{max-width:1060px;margin:0 auto}
h1{font-size:27px;margin:0 0 6px;letter-spacing:-.02em;text-wrap:balance}
.sub{color:var(--ink2);margin:0 0 30px;font-size:14px}
h2{font-size:17px;margin:38px 0 4px;letter-spacing:-.01em}
h2 .n{color:var(--ink3);font-weight:400}
p{margin:8px 0 16px;color:var(--ink2);max-width:74ch}
.card{background:var(--surf);border:1px solid var(--line);border-radius:9px;
      padding:20px 22px;margin:16px 0}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px;margin:22px 0 6px}
.kpi{background:var(--surf);border:1px solid var(--line);border-radius:9px;padding:15px 17px}
.kpi .v{font:600 25px/1.15 "IBM Plex Mono",monospace;letter-spacing:-.02em;
        font-variant-numeric:tabular-nums}
.kpi .k{color:var(--ink3);font-size:11.5px;text-transform:uppercase;letter-spacing:.07em;margin-top:5px}
.tw{overflow-x:auto;margin:6px 0 4px}
table{border-collapse:collapse;width:100%;font-size:13.5px}
th{text-align:left;color:var(--ink3);font-weight:600;font-size:11px;text-transform:uppercase;
   letter-spacing:.06em;padding:7px 12px 7px 0;border-bottom:1.5px solid var(--rule);white-space:nowrap}
td{padding:8px 12px 8px 0;border-bottom:1px solid var(--line);
   font-variant-numeric:tabular-nums;white-space:nowrap}
td.n,th.n{text-align:right}
.mono{font-family:"IBM Plex Mono",monospace;font-size:12.5px}
.good{color:var(--good);font-weight:600}
.bad{color:var(--bad);font-weight:600}
.big{font-weight:600;font-size:14.5px}
.none{color:var(--ink3);font-style:italic}
.note{border-left:3px solid var(--accent);padding:2px 0 2px 15px;margin:20px 0;color:var(--ink2)}
code{font-family:"IBM Plex Mono",monospace;font-size:.9em;background:var(--bg);
     border:1px solid var(--line);border-radius:4px;padding:1px 5px}
.mctl{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-bottom:14px}
.mctl select{font:inherit;font-size:13px;padding:5px 8px;border:1px solid var(--line);
             border-radius:6px;background:var(--bg);color:var(--ink);max-width:340px}
.mctl input[type=range]{flex:1;min-width:200px;accent-color:var(--accent)}
.mesh{display:grid;grid-template-columns:repeat(4,1fr);gap:4px;max-width:340px}
.mesh i{aspect-ratio:1;border-radius:5px;border:1px solid var(--line);display:block}
.scale{display:flex;align-items:center;gap:9px;margin-top:13px;color:var(--ink3);font-size:11.5px}
.ramp{flex:0 0 130px;height:9px;border-radius:5px;
      background:linear-gradient(90deg,color-mix(in oklab,var(--accent) 6%,var(--bg)),var(--accent))}
.foot{color:var(--ink3);font-size:12px;margin-top:34px;border-top:1px solid var(--line);padding-top:14px}
</style>''')
A('<div class="wrap">')
A('<h1>Corrected MSHR bank hash &mdash; re-run results</h1>')
A('<p class="sub">4&times;4 mesh, 256 cores, <code>terapool_spatz4_fpu</code>. '
  'Each row is one shape run twice: once before the fix, once after. Generated %s.</p>'
  % time.strftime("%Y-%m-%d %H:%M"))

sb = sum(o["cyc"] for _, o, _ in NUL) or 1
sa = sum(n["cyc"] for _, _, n in NUL)
A('<div class="kpis">')
A('<div class="kpi"><div class="v good">%d</div><div class="k">arms recovered<br>from producing nothing</div></div>' % len(REC))
A('<div class="kpi"><div class="v">%+.2f%%</div><div class="k">aggregate on the %d arms<br>that already worked</div></div>' % (100.0*(sa-sb)/sb, len(NUL)))
A('<div class="kpi"><div class="v bad">%d</div><div class="k">arms measurably slower<br>(&gt;1%%)</div></div>'
  % len([1 for _, o, n in NUL if 100.0*(n["cyc"]-o["cyc"])/o["cyc"] > 1.0]))
A('<div class="kpi"><div class="v">%d</div><div class="k">of 36 arms<br>delivered so far</div></div>' % (len(REC)+len(NUL)+len(RF)))
A('</div>')

A('<h2>1 &nbsp;These arms produced no result at all before <span class="n">&mdash; %d</span></h2>' % len(REC))
A('<p>Each sat in the RH livelock: riding out <code>serve_timeout</code> on every remote load, '
  '3&ndash;13% FPU utilisation, killed by the wall clock after ~2.5M cycles without ever emitting '
  'a cycle count. There is no &ldquo;before&rdquo; number because none was ever produced.</p>')
A('<div class="card"><div class="tw"><table><thead><tr><th>arm</th><th class="n">before</th>'
  '<th class="n">after</th><th class="n">RH before</th><th class="n">RH after</th>'
  '<th class="n">util before</th><th class="n">util after</th></tr></thead><tbody>')
for a, o, n in sorted(REC, key=lambda x: -x[1]["rh"]):
    A('<tr><td class="mono">%s</td><td class="n none">never completed</td>'
      '<td class="n big good">%s</td><td class="n">%s</td><td class="n">%d</td>'
      '<td class="n">%.2f%%</td><td class="n big">%.2f%%</td></tr>'
      % (a, format(n["cyc"], ","), format(o["rh"], ","), n["rh"], o["util"] or 0, n["util"] or 0))
A('</tbody></table></div></div>')
A('<div class="note">RH-STUCK falls to a flat <b>8&ndash;16 on every arm</b>, whether it started at '
  '41,807 or 4,116. That is a fixed floor, not a residue proportional to the old problem.</div>')

A('<h2>2 &nbsp;These arms already worked <span class="n">&mdash; %d, aggregate %+.2f%%</span></h2>'
  % (len(NUL), 100.0*(sa-sb)/sb))
A('<p>A positive delta is <b>slower</b>. Sorted best to worst.</p>')
A('<div class="card"><div class="tw"><table><thead><tr><th>arm</th><th class="n">before</th>'
  '<th class="n">after</th><th class="n">delta</th><th class="n">util before</th>'
  '<th class="n">util after</th></tr></thead><tbody>')
for a, o, n in sorted(NUL, key=lambda x: (x[2]["cyc"]-x[1]["cyc"])/float(x[1]["cyc"])):
    d = 100.0*(n["cyc"]-o["cyc"])/o["cyc"]
    cls = "bad" if d > 1.0 else ("good" if d < -0.5 else "")
    A('<tr><td class="mono">%s</td><td class="n">%s</td><td class="n">%s</td>'
      '<td class="n %s">%+.2f%%</td><td class="n">%.2f%%</td><td class="n">%.2f%%</td></tr>'
      % (a, format(o["cyc"], ","), format(n["cyc"], ","), cls, d, o["util"] or 0, n["util"] or 0))
A('<tr><td class="mono"><b>aggregate</b></td><td class="n"><b>%s</b></td><td class="n"><b>%s</b></td>'
  '<td class="n"><b>%+.2f%%</b></td><td class="n">&mdash;</td><td class="n">&mdash;</td></tr>'
  % (format(sb, ","), format(sa, ","), 100.0*(sa-sb)/sb))
A('</tbody></table></div></div>')
A('<div class="note"><b>Two arms are genuinely slower</b>, both B=16 KS=2, and every stress counter '
  'is zero on both sides &mdash; nothing new is stalling, utilisation simply drops. A hash better on '
  'average can be worse for one access pattern. Not root-caused.<br><br>'
  'Also unexplained: utilisation falls on 8 of these 9 arms even where cycles barely move.</div>')

if RF:
    A('<h2>3 &nbsp;Derived <code>LOAD_LMUL</code> vs the hand-passed flag <span class="n">&mdash; %d</span></h2>' % len(RF))
    A('<p>These shapes need the 512&nbsp;B load split or they deadlock before the kernel. The flag '
      'used to be passed by hand; it is now derived from the shape. Both builds emit a '
      '<b>byte-identical</b> <code>matmul_1xVL</code>, so this checks the derivation picks the same '
      'setting &mdash; any delta comes from the bank hash, which the older baselines predate.</p>')
    A('<div class="card"><div class="tw"><table><thead><tr><th>arm</th><th class="n">hand-flagged</th>'
      '<th class="n">derived</th><th class="n">delta</th><th class="n">util before</th>'
      '<th class="n">util after</th></tr></thead><tbody>')
    for a, o, n in sorted(RF):
        if o and o["cyc"]:
            d = 100.0*(n["cyc"]-o["cyc"])/o["cyc"]
            A('<tr><td class="mono">%s</td><td class="n">%s</td><td class="n">%s</td>'
              '<td class="n %s">%+.2f%%</td><td class="n">%.2f%%</td><td class="n">%.2f%%</td></tr>'
              % (a, format(o["cyc"], ","), format(n["cyc"], ","),
                 "good" if d < -0.5 else ("bad" if d > 1.0 else ""), d,
                 o["util"] or 0, n["util"] or 0))
        else:
            A('<tr><td class="mono">%s</td><td class="n none">never completed</td>'
              '<td class="n big good">%s</td><td class="n">&mdash;</td><td class="n">&mdash;</td>'
              '<td class="n">%.2f%%</td></tr>' % (a, format(n["cyc"], ","), n["util"] or 0))
    A('</tbody></table></div></div>')

if GU:
    _keys = sorted(GU)
    A('<h2>Per-group FPU utilisation over the benchmark <span class="n">&mdash; %d arms</span></h2>'
      % len(_keys))
    A('<p>Each cell is one of the 16 groups of the 4&times;4 mesh, coloured by the share of its FPU '
      'lane-cycles busy in that 1000-cycle window. Whole-run utilisation averages this over every '
      'group and every window, so it hides what this shows: <b>how evenly the work is spread</b>. '
      'Drag the scrubber to move through the run.</p>')
    A('<div class="card">')
    A('<div class="mctl"><select id="ga">%s</select>'
      '<input id="gt" type="range" min="0" max="1" value="0">'
      '<span class="mono" id="gl"></span></div>'
      % "".join('<option value="%d">%s</option>' % (i, k) for i, k in enumerate(_keys)))
    A('<div id="gm" class="mesh"></div>')
    A('<div class="scale"><span>0%</span><i class="ramp"></i><span>100%</span>'
      '<span class="mono" id="gs"></span></div>')
    A('</div>')
    A('<script>var GU=%s;var GK=%s;</script>'
      % (json.dumps([GU[k] for k in _keys], separators=(",", ":")),
         json.dumps(_keys, separators=(",", ":"))))
    A('''<script>
(function(){
  var sel=document.getElementById("ga"), sl=document.getElementById("gt"),
      lab=document.getElementById("gl"), mesh=document.getElementById("gm"),
      stat=document.getElementById("gs"), cells=[];
  for(var i=0;i<16;i++){var c=document.createElement("i");mesh.appendChild(c);cells.push(c);}
  function paint(){
    var a=GU[+sel.value], w=a.p[+sl.value];
    lab.textContent="cyc "+w.c.toLocaleString()+"  ("+(+sl.value+1)+"/"+a.p.length+")";
    var s=0,mn=101,mx=-1;
    for(var i=0;i<16;i++){
      var v=(w.u[i]===undefined)?0:w.u[i]; s+=v; if(v<mn)mn=v; if(v>mx)mx=v;
      var t=Math.max(0,Math.min(1,v/100));
      cells[i].style.background="color-mix(in oklab, var(--accent) "+(6+94*t)+"%, var(--bg))";
      cells[i].title="group "+i+": "+v.toFixed(1)+"%";
    }
    stat.textContent="mean "+(s/16).toFixed(1)+"%  min "+mn.toFixed(1)+"%  max "+mx.toFixed(1)+"%";
  }
  function reset(){var a=GU[+sel.value];sl.max=a.p.length-1;sl.value=0;paint();}
  sel.addEventListener("change",reset); sl.addEventListener("input",paint); reset();
})();
</script>''')

A('<h2>How to judge this fix</h2>')
A('<div class="note"><b>Use RH-STUCK, not <code>bankfull_bypass</code>.</b> '
  '<code>bankfull_bypass</code> is <b>0 on all 44 baselines &mdash; including every livelocked '
  'one</b>. Surveying it produced two successive wrong conclusions here: first that a throughput '
  'win was expected, then that there was nothing to recover. The pressure lives in the RH-STUCK '
  'episode count: single digits when healthy, 10<sup>4</sup> when livelocked.<br><br>'
  'Generally: a stress counter that is identically zero across a whole grid is a reason to distrust '
  'the counter, not evidence of health &mdash; especially when some arms in that grid produced no '
  'result at all.</div>')

A('<div class="foot">Sources: <code>hardware/hashfix_hf_4x4_*/transcript</code> (corrected hash), '
  '<code>hardware/rf_rf_4x4_*/transcript</code> (derived LOAD_LMUL), '
  '<code>hardware/{run2,wc4}_sw_4x4_*/transcript</code> (baselines). '
  'Regenerate: <code>scripts/gen_hashfix_results_artifact.py</code>. '
  'Full campaign explorer: the Decode B&times;KS Sweep artifact.</div>')
A('</div>')

open(OUT, "w").write("\n".join(H))

# self-check on VISIBLE text
vis = re.sub(r"<[^>]*>", " ", open(OUT).read())
miss = [format(x[2]["cyc"], ",") for x in REC + NUL + RF
        if format(x[2]["cyc"], ",") not in vis]
if miss:
    sys.stderr.write("SELF-CHECK FAILED: %d cycle count(s) not in visible text: %s\n"
                     % (len(miss), ", ".join(miss[:8])))
    sys.exit(3)
print("wrote %s  (%d recovered, %d null, %d rf) -- all %d counts visible"
      % (OUT, len(REC), len(NUL), len(RF), len(REC)+len(NUL)+len(RF)))
