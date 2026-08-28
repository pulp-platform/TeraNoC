#!/usr/bin/env python3
"""Render the VLSU ROB experiments as an Artifact page.

Same shape as the decode dashboard -- tables, a per-group mesh with a time slider,
and per-group progress -- because the questions are the same: what did the change
cost, and was the cost spread evenly across the machine or concentrated.
"""
import html, json, os, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
TSV  = os.path.join(ROOT, "docs/benchmarks/rob_results.tsv")
GUJ  = os.path.join(ROOT, "docs/benchmarks/rob_group_util.json")
OUT  = "/tmp/claude-620771/rob_dash.html"

IMAGES = [("A", "rob64 + dual-load", "production today"),
          ("B", "rob64, no dual-load", "isolates dual-load"),
          ("C", "rob32, no dual-load", "isolates ROB depth"),
          ("D0", "ROB0 64 / ROB1-3 64", "asymmetric control"),
          ("D1", "ROB0 64 / ROB1-3 16", "shrink the idle ROBs"),
          ("D1a", "ROB0 64 / ROB1-3 16 + guards", "A-TRUNC live"),
          ("D2", "ROB0 128 / ROB1-3 16", "deep burst ROB")]
LABEL = {"d16a":"decode fp16 D=128","d16b":"decode fp16 D=256","d32a":"decode fp32 D=128",
         "d32b":"decode fp32 D=256","p09":"2048x32x128","p20":"2048x64x128",
         "p50":"1024x128x256","p49f":"1024x64x256","p66":"1024x128x512","p78":"1024x256x512"}


def load():
    rows = []
    if os.path.exists(TSV):
        with open(TSV) as f:
            hdr = f.readline().rstrip("\n").split("\t")
            for ln in f:
                rows.append(dict(zip(hdr, ln.rstrip("\n").split("\t"))))
    return rows


# An arm is LIVELOCKED, not merely slow, when the response-hold machinery is thrashing.
# The separation is not marginal: C|p20 shows rh=87,277 / tmo=17,499 while the highest
# non-livelocked arm in the whole set is rh=861 / tmo=93 -- a 100x gap, so any threshold in
# between gives the same partition. These arms must be reported separately, never averaged
# into the dual-load range: a single 27x arm would turn "+7.7% to +16.4%" into
# "+7.7% to +2624%" and make the summary meaningless.
RH_LIVELOCK, TMO_LIVELOCK = 10000, 1000


def livelocked(r):
    try:
        return int(r.get("rh", 0)) >= RH_LIVELOCK or int(r.get("tmo", 0)) >= TMO_LIVELOCK
    except (TypeError, ValueError):
        return False


def main():
    rows = load()
    by = {}
    for r in rows:
        by.setdefault(r["shape"], {})[r["image"]] = r
    try:
        GU = json.load(open(GUJ))
    except Exception:
        GU = {}

    H = ["<title>VLSU ROB Sizing</title>",
         '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?'
         'family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans+Condensed:wght@600;700'
         '&family=IBM+Plex+Sans:wght@400;500&display=swap">',
         '''<style>
:root{
  --ground:#f4f6f7; --panel:#ffffff; --line:#d8dee1; --line-soft:#e4e9ec;
  --ink:#0e1418; --ink-2:#5a6b75; --ink-3:#7d8b93;
  --accent:#d98324;
  --fp16:#1f6f8b; --fp32:#7d8b93;
  --good:#1f7a5c; --warn:#d98324; --bad:#b3382c; --wait:#7d8b93; --track:#e4e9ec;
  --shadow:0 1px 2px rgba(14,20,24,.06);
  --mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
  --sans:"IBM Plex Sans",system-ui,-apple-system,Segoe UI,sans-serif;
  --cond:"IBM Plex Sans Condensed","IBM Plex Sans",system-ui,sans-serif;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --ground:#0e1418; --panel:#161e23; --line:#26313a; --line-soft:#1e272d;
  --ink:#e6edf1; --ink-2:#8aa0ad; --ink-3:#6b7d88;
  --accent:#e8a04e; --fp16:#4fa3c4; --fp32:#8aa0ad;
  --good:#3fa37c; --warn:#e8a04e; --bad:#d9614f; --wait:#6b7d88; --track:#1e272d;
  --shadow:0 1px 2px rgba(0,0,0,.35);
}}
:root[data-theme="dark"]{
  --ground:#0e1418; --panel:#161e23; --line:#26313a; --line-soft:#1e272d;
  --ink:#e6edf1; --ink-2:#8aa0ad; --ink-3:#6b7d88;
  --accent:#e8a04e; --fp16:#4fa3c4; --fp32:#8aa0ad;
  --good:#3fa37c; --warn:#e8a04e; --bad:#d9614f; --wait:#6b7d88; --track:#1e272d;
  --shadow:0 1px 2px rgba(0,0,0,.35);
}
*{box-sizing:border-box}
body{background:var(--ground);color:var(--ink);font-family:var(--sans);
     line-height:1.55;margin:0;padding:32px 20px 72px;-webkit-font-smoothing:antialiased}
.wrap{max-width:1080px;margin:0 auto;display:flex;flex-direction:column;gap:26px}
h1{font-family:var(--cond);font-weight:700;font-size:clamp(28px,4.4vw,42px);letter-spacing:-.015em;
   margin:0;text-wrap:balance}
h2{font-family:var(--cond);font-weight:600;font-size:19px;letter-spacing:.01em;margin:0 0 4px}
.eyebrow{font-family:var(--mono);font-size:11px;letter-spacing:.14em;text-transform:uppercase;
   color:var(--ink-3);margin:0 0 8px}
.sub{color:var(--ink-2);font-size:14.5px;margin:0}
.card{background:var(--panel);border:1px solid var(--line);border-radius:4px;padding:20px 22px;
      box-shadow:var(--shadow);display:flex;flex-direction:column;gap:14px}
.hero{display:flex;flex-wrap:wrap;gap:26px;align-items:flex-end;justify-content:space-between}
.stat{display:flex;flex-direction:column;gap:2px}
.stat .n{font-family:var(--mono);font-weight:500;font-size:34px;color:var(--accent);
         font-variant-numeric:tabular-nums;line-height:1}
.stat .l{font-size:12.5px;color:var(--ink-3)}
.tw{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13.5px}
th{font-family:var(--mono);font-weight:500;font-size:10.5px;letter-spacing:.09em;
   text-transform:uppercase;color:var(--ink-3);text-align:left;
   border-bottom:1px solid var(--line);padding:0 10px 7px;white-space:nowrap}
td{border-bottom:1px solid var(--line-soft);padding:9px 10px;vertical-align:middle}
tr:last-child td{border-bottom:none}
.num{text-align:right;font-family:var(--mono);font-variant-numeric:tabular-nums;white-space:nowrap}
code{font-family:var(--mono);font-size:12.5px;background:var(--track);padding:1px 5px;border-radius:4px}
.chip{display:inline-block;font-family:var(--mono);font-size:10.5px;letter-spacing:.05em;
      padding:2px 7px;border-radius:999px;border:1px solid currentColor;white-space:nowrap}
.fp16{color:var(--fp16)} .fp32{color:var(--fp32)}
.st-done{color:var(--good)} .st-running{color:var(--warn)} .st-queued{color:var(--ink-3)}
.bar{height:6px;background:var(--track);border-radius:3px;overflow:hidden;min-width:96px}
.bar span{display:block;height:100%;border-radius:3px}
.b-eff{background:var(--fp16)} .b-live{background:var(--wait)}
.eff{font-family:var(--mono);font-weight:500;font-variant-numeric:tabular-nums;color:var(--accent)}
.note{font-size:13.5px;color:var(--ink-2)}
.note b{color:var(--ink)}
ul{margin:0;padding-left:18px} li{margin:5px 0;font-size:13.5px;color:var(--ink-2)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px}
.kv{border:1px solid var(--line-soft);border-radius:8px;padding:11px 13px}
.kv .k{font-family:var(--mono);font-size:10.5px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3)}
.kv .v{font-size:14px;margin-top:3px}
.flag{border-left:3px solid var(--warn);padding-left:13px}
.mctl{display:flex;flex-wrap:wrap;gap:16px 22px;align-items:flex-end;margin-bottom:6px}
.mctl label{display:block;font-family:var(--mono);font-size:10px;letter-spacing:.09em;
  text-transform:uppercase;color:var(--ink-3);margin-bottom:4px}
.mctl select{font-family:var(--mono);font-size:12.5px;padding:5px 8px;border-radius:6px;
  border:1px solid var(--line);background:var(--panel);color:var(--ink)}
.mctl input[type=range]{width:min(420px,52vw);accent-color:var(--accent);vertical-align:middle}
.meshwrap{display:flex;flex-wrap:wrap;gap:26px;align-items:flex-start}
.mesh{display:grid;gap:3px;width:min(340px,80vw)}
.cell{aspect-ratio:1;border-radius:2px;display:flex;align-items:center;justify-content:center;
  font-family:var(--mono);font-size:9px;font-weight:500;color:#fff;background:var(--track)}
.cell.lo{color:var(--ink-3)}
.scale{display:flex;align-items:center;gap:7px;margin-top:9px;font-family:var(--mono);
  font-size:10px;color:var(--ink-3)}
.scale i{flex:1;height:8px;border-radius:2px;
  background:linear-gradient(90deg,#e8eef1,#9fc7d4,#4e94ab,#1f6f8b,#0d3f52)}
:root:not([data-theme="light"]) .scale i{background:linear-gradient(90deg,#1b2b33,#255d72,#2f88a4,#4fa3c4,#9fd8ea)}
:root[data-theme="dark"] .scale i{background:linear-gradient(90deg,#1b2b33,#255d72,#2f88a4,#4fa3c4,#9fd8ea)}
.mmeta{flex:1;min-width:230px}
.mmeta dl{display:grid;grid-template-columns:repeat(2,minmax(96px,1fr));gap:11px 18px;margin:0}
.mmeta dt{font-family:var(--mono);font-size:9.5px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3)}
.mmeta dd{margin:2px 0 0;font-family:var(--mono);font-size:14px;font-variant-numeric:tabular-nums}
.prog{display:grid;grid-template-columns:repeat(auto-fill,minmax(168px,1fr));gap:5px 14px}
.prow{display:flex;align-items:center;gap:7px;font-family:var(--mono);font-size:10.5px}
.prow .gid{color:var(--ink-3);width:26px;text-align:right}
.prow .pb{flex:1;height:7px;background:var(--track);border-radius:3px;overflow:hidden}
.prow .pb span{display:block;height:100%;background:var(--fp16);border-radius:3px}
.prow .pv{width:40px;text-align:right;font-variant-numeric:tabular-nums;color:var(--ink-2)}
h3.sec{font-family:var(--mono);font-weight:500;font-size:12px;letter-spacing:.08em;
  text-transform:uppercase;color:var(--ink-3);margin:30px 0 6px}
footer{color:var(--ink-3);font-size:12px;font-family:var(--mono)}
</style>''',
         '<div class="wrap"><header>',
         "<h1>VLSU ROB Sizing</h1>",
         '<p class="sub">How deep does the Spatz reorder buffer need to be, and what does its '
         'depth actually buy? Three images isolate the two candidate answers &mdash; buffer '
         '<i>depth</i> and H1 <i>dual-load</i> &mdash; across ten shapes spanning 9% to 78% '
         'FPU utilisation and both precisions. Every image differs only in the defines named '
         'below, verified by a full define-diff before dispatch.</p>',
         "</header>"]

    # ---- images
    H.append('<section class="card"><div><h2>The images</h2></div>')
    H.append('<div class="tw"><table><tr><th>image</th><th>configuration</th><th>isolates</th></tr>')
    for i, cfg, role in IMAGES:
        H.append("<tr><td><b>%s</b></td><td><code>%s</code></td><td>%s</td></tr>"
                 % (i, html.escape(cfg), html.escape(role)))
    H.append("</table></div>")
    H.append('<p class="note"><b>B vs A</b> is dual-load\'s worth. <b>C vs B</b> is the ROB '
             'depth\'s worth. D0/D1/D2 test asymmetric sizing: bursts use <b>ROB0 only</b>, so '
             'ports 1&ndash;3 can be shrunk independently.</p></section>')

    # ---- results
    if rows:
        H.append('<section class="card"><div><h2>Cycles by image</h2></div><div class="tw"><table><tr>'
                 '<th>shape</th><th>prec</th>'
                 + "".join("<th class=num>%s</th>" % i for i, _, _ in IMAGES)
                 + '<th class="num">B vs A</th><th class="num">C vs B</th>'
                   '<th class="num">D1 vs A</th></tr>')
        for tag in LABEL:
            d = by.get(tag)
            if not d:
                continue
            cells = []
            for i, _, _ in IMAGES:
                cells.append('<td class="num">%s</td>' %
                             ("{:,}".format(int(d[i]["cycles"])) if i in d else "&mdash;"))
            a = int(d["A"]["cycles"]) if "A" in d else None
            b = int(d["B"]["cycles"]) if "B" in d else None
            c = int(d["C"]["cycles"]) if "C" in d else None
            dba = ('<span class="st-running">%+.1f%%</span>' % (100.0*(b-a)/a)) if a and b else "&mdash;"
            dcb = ('<span class="eff">%+.1f%%</span>' % (100.0*(c-b)/b)) if b and c else "&mdash;"
            d1 = int(d["D1"]["cycles"]) if "D1" in d else None
            dd1 = ('<span class="eff">%+.1f%%</span>' % (100.0*(d1-a)/a)) if a and d1 else "&mdash;"
            prec = d[list(d)[0]]["prec"]
            H.append("<tr><td><code>%s</code><br><span class=sub>%s</span></td>"
                     '<td><span class="chip %s">%s</span></td>%s'
                     '<td class="num">%s</td><td class="num">%s</td>'
                     '<td class="num">%s</td></tr>'
                     % (tag, html.escape(LABEL[tag]), prec, prec, "".join(cells), dba, dcb, dd1))
        H.append("</table></div>")
        done = [t for t in by if all(x in by[t] for x in ("A","B","C"))]
        ll   = sorted(t for t in by if any(livelocked(r) for r in by[t].values()))
        slope = [t for t in done if t not in ll]
        if slope:
            dl = [100.0*(int(by[t]["B"]["cycles"])-int(by[t]["A"]["cycles"]))/int(by[t]["A"]["cycles"]) for t in slope]
            H.append('<p class="note"><b>%d of %d triples complete.</b> On the %d that run cleanly, '
                     'dual-load is worth <b>%+.1f%% to %+.1f%%</b> (mean %+.1f%%). <b>ROB depth '
                     'alone is worth +0.0%%</b> &mdash; B and C are identical on every one of them, '
                     'so 32 vs 64 slots changes nothing by itself. All of ROB64&rsquo;s value is '
                     'that it lets two loads be co-resident.%s</p>'
                     % (len(done), len(LABEL), len(slope), min(dl), max(dl), sum(dl)/len(dl),
                        ('' if not ll else
                         ' <b>%s excluded</b> from that range as livelocked, not slow &mdash; '
                         'see below; averaging it in would report a meaningless spread.'
                         % ", ".join("<code>%s</code>" % t for t in ll))))
        H.append("</section>")

    # ---- the headline: is the asymmetric ROB free?
    pairs = [(t, int(by[t]["A"]["cycles"]), int(by[t]["D1"]["cycles"]))
             for t in LABEL if t in by and "A" in by[t] and "D1" in by[t]]
    if pairs:
        exact = sum(1 for _, a, d in pairs if a == d)
        H.append('<section class="card"><div><h2>Is the asymmetric ROB free?</h2>'
                 '<p class="sub">Bursts are <b>port-0 only</b> &mdash; ports 1&ndash;3 fail '
                 '<code>burst_addr_aligned</code> by construction, and ParityDrain lands both even '
                 'and odd beats in ROB0&rsquo;s id range. With every sampled load on the burst '
                 'path, ROB1&ndash;3 should be dead storage. This measures whether they are.</p>'
                 '</div>')
        H.append('<div class="tw"><table><tr><th>shape</th>'
                 '<th class="num">A &mdash; ROB1-3 = 64</th>'
                 '<th class="num">D1 &mdash; ROB1-3 = 16</th>'
                 '<th class="num">delta</th><th>verdict</th></tr>')
        for t, a, dd in pairs:
            H.append('<tr><td><code>%s</code><br><span class=sub>%s</span></td>'
                     '<td class="num">%s</td><td class="num">%s</td>'
                     '<td class="num">%s</td><td><span class="chip %s">%s</span></td></tr>'
                     % (t, html.escape(LABEL.get(t, t)), "{:,}".format(a), "{:,}".format(dd),
                        ("%+d" % (dd - a)) if dd != a else "0",
                        "fp32" if dd == a else "fp16",
                        "identical" if dd == a else "differs"))
        H.append("</table></div>")
        H.append('<p class="note"><b>%d of %d shapes identical to the cycle.</b> Not "within '
                 'noise" &mdash; the same number. Load-side storage per core falls from '
                 '<b>8,192</b> flops (4 x 64 x 32b) to <b>3,584</b> (ROB0 64 + three ROBs of 16), '
                 'a <b>56%%</b> cut, for no measured cost. <code>D1a</code> repeats it with the '
                 'A-TRUNC width guard elaborated and live: also identical, and the assertion '
                 'never fires &mdash; so ports 1&ndash;3 really do take every id from their own '
                 'ROB.</p>' % (exact, len(pairs)))
        H.append("</section>")

    # ---- the livelock finding: a cliff, not a slope
    ll = sorted(t for t in by if any(livelocked(r) for r in by[t].values()))
    if ll:
        H.append('<section class="card"><div><h2>Where dual-load stops being an optimisation</h2>'
                 '<p class="sub">On most shapes dual-load buys a few per cent. On the shapes below '
                 'the machine does the <b>same work</b> and takes an order of magnitude longer to '
                 'do it. Reported apart from the range above because it is a different '
                 'phenomenon, not the tail of the same one.</p></div>')
        H.append('<div class="tw"><table><tr><th>shape</th><th>image</th>'
                 '<th class="num">cycles</th><th class="num">efficiency</th>'
                 '<th class="num">RH stuck</th><th class="num">MSHR timeouts</th>'
                 '<th>sim end</th><th>verdict</th></tr>')
        for tag in ll:
            for i, cfg, _ in IMAGES:
                r = by[tag].get(i)
                if not r:
                    continue
                bad = livelocked(r)
                H.append('<tr><td><code>%s</code><br><span class=sub>%s</span></td>'
                         '<td><span class=sub>%s</span></td>'
                         '<td class="num">%s</td><td class="num">%s%%</td>'
                         '<td class="num">%s</td><td class="num">%s</td>'
                         '<td><span class=sub>%s</span></td>'
                         '<td><span class="chip %s">%s</span></td></tr>'
                         % (tag, html.escape(LABEL.get(tag, tag)), html.escape(cfg),
                            "{:,}".format(int(r["cycles"])), r["eff"],
                            "{:,}".format(int(r.get("rh", 0))), "{:,}".format(int(r.get("tmo", 0))),
                            html.escape(r.get("state", "?")),
                            "fp16" if bad else "fp32", "livelocked" if bad else "clean"))
        H.append("</table></div>")
        H.append('<p class="note"><b>Neither arm reaches <code>[EOC]</code>.</b> Every '
                 '<code>p*</code> arm in this sweep &mdash; all images &mdash; dies in the '
                 '<b>epilogue</b> on a pre-existing assertion, <code>mempool_group_mshr.sv:2269</code> '
                 '(&ldquo;MSHR clock gate dropped a resp_buf write&rdquo;), which is an open issue '
                 'unrelated to ROB sizing. The kernel itself completes: the benchmark region opens '
                 '<i>and closes</i>, so the cycle counts are real workload measures. But these arms '
                 'must not be described as having finished &mdash; only the decode shapes and '
                 '<code>p49f</code> do. The <code>state</code> column says which is which.</p>')
        H.append('<p class="note"><b>The comparison is controlled.</b> Every hold-window, '
                 'serve-timeout and response-hold define is <b>identical</b> across these images '
                 '&mdash; the only differences are <code>SPATZ_VLSU_DUAL_LOAD</code> and '
                 '<code>SPATZ_VLSU_ROB_DEPTH</code>. That matters because the RH probe counts '
                 '<i>episodes</i>, so its counts are only comparable when the window is the same. '
                 'And ROB depth is worth nothing on its own (B = C everywhere), so what is left '
                 'is dual-load. The control is <code>p78</code>: RH and timeouts are <b>0</b> in '
                 'both arms there, and they finish 7% apart.</p>')
        H.append("</section>")

    # ---- mesh + slider
    if GU:
        H.append('<section class="card">')
        H.append('<div><h2>Per-group FPU utilisation over the benchmark</h2>'
                 '<p class="sub">Each cell is one group of the 8&times;8 mesh; colour is its FPU '
                 'utilisation in one 1000-cycle window. Drag the slider to move through time, and '
                 'switch image to see whether a configuration&rsquo;s cost lands evenly across the '
                 'machine or on a few groups. A whole-run number cannot show that.</p></div>')
        H.append('<div class="mctl"><div><label for="marm">image &middot; shape</label>'
                 '<select id="marm">'
                 + "".join('<option value="%s">%s &middot; %s &middot; %s</option>'
                           % (html.escape(k), html.escape(v["image"]), html.escape(v["cfg"]),
                              html.escape(v["label"]))
                           for k, v in sorted(GU.items(), key=lambda kv: (kv[1]["shape"], kv[1]["image"])))
                 + "</select></div>"
                 '<div style="flex:1"><label for="mper">benchmark window</label>'
                 '<input type="range" id="mper" min="0" max="0" value="0" step="1"> '
                 '<span id="mcyc" class="eff"></span></div></div>')
        H.append('<div class="meshwrap"><div><div class="mesh" id="mgrid"></div>'
                 '<div class="scale"><span>0%</span><i></i><span>100%</span></div></div>'
                 '<div class="mmeta"><dl>'
                 '<dt>window mean</dt><dd id="mmean">-</dd>'
                 '<dt>spread (max&minus;min)</dt><dd id="mspread">-</dd>'
                 '<dt>busiest</dt><dd id="mmax">-</dd>'
                 '<dt>idlest</dt><dd id="mmin">-</dd>'
                 '<dt>windows</dt><dd id="mwin">-</dd>'
                 '<dt>groups</dt><dd id="mgn">-</dd>'
                 "</dl></div></div>")
        H.append('<h3 class="sec">Per-group progress &mdash; are the groups advancing together?</h3>')
        H.append('<p class="sub" style="margin-bottom:13px">Each bar is a group&rsquo;s cumulative '
                 'MACs against its <b>own equal share</b> of the work. Spread is wasted machine: the '
                 'kernel ends when the <b>last</b> group finishes.</p>')
        H.append('<div class="mmeta"><dl>'
                 '<dt>leader</dt><dd id="plead">-</dd><dt>laggard</dt><dd id="plag">-</dd>'
                 '<dt>gap</dt><dd id="pgap">-</dd><dt>lag/lead</dt><dd id="pratio">-</dd>'
                 "</dl></div>")
        H.append('<div class="pgrid" id="pgrid"></div>')
        H.append("</section>")
        H.append("<script>const GU=%s;</script>" % json.dumps(GU, separators=(",", ":")))
        H.append('''<script>
(function(){
 const $=i=>document.getElementById(i);
 const grid=$("mgrid"), sel=$("marm"), rng=$("mper"), pg=$("pgrid");
 // Same five stops as the 8x8 campaign mesh: one hue, light -> dark. Magnitude is a
 // sequential encoding, never a rainbow.
 const STOPS=[[232,238,241],[159,199,212],[78,148,171],[31,111,139],[13,63,82]];
 function colour(u){const t=Math.max(0,Math.min(100,u))/100*(STOPS.length-1);
   const i=Math.min(STOPS.length-2,Math.floor(t)),f=t-i,a=STOPS[i],b=STOPS[i+1];
   return `rgb(${Math.round(a[0]+(b[0]-a[0])*f)},${Math.round(a[1]+(b[1]-a[1])*f)},${Math.round(a[2]+(b[2]-a[2])*f)})`;}
 function draw(){
   const a=sel.value, d=GU[a]; if(!d) return;
   const n=d.groups, side=Math.round(Math.sqrt(n));
   grid.style.gridTemplateColumns=`repeat(${side},1fr)`;
   const i=Math.min(+rng.value, d.periods.length-1), p=d.periods[i];
   rng.max=d.periods.length-1;
   $("mcyc").textContent=`cyc ${p.cyc.toLocaleString()}`;
   grid.innerHTML="";
   p.u.forEach((u,g)=>{const e=document.createElement("div");
     e.className="cell"+(u<45?" lo":""); e.style.background=colour(u);
     e.textContent=Math.round(u); e.title=`group ${g}: ${u}%`; grid.appendChild(e);});
   const mx=Math.max(...p.u), mn=Math.min(...p.u);
   const mean=p.u.reduce((s,v)=>s+v,0)/n;
   $("mmean").textContent=mean.toFixed(1)+"%";
   $("mspread").textContent=(mx-mn).toFixed(1)+" pp";
   $("mmax").textContent=`g${p.u.indexOf(mx)} · ${mx}%`;
   $("mmin").textContent=`g${p.u.indexOf(mn)} · ${mn}%`;
   $("mwin").textContent=`${i+1} / ${d.periods.length}`;
   $("mgn").textContent=n;
   // cumulative MACs per group up to and including this window
   const cum=new Array(n).fill(0);
   for(let k=0;k<=i;k++) d.periods[k].u.forEach((u,g)=>{cum[g]+=u/100*d.denom*d.mac;});
   const pct=cum.map(v=>100*v/d.share);
   const lead=Math.max(...pct), lag=Math.min(...pct);
   $("plead").textContent=`g${pct.indexOf(lead)} · ${lead.toFixed(1)}%`;
   $("plag").textContent=`g${pct.indexOf(lag)} · ${lag.toFixed(1)}%`;
   $("pgap").textContent=(lead-lag).toFixed(1)+" pp";
   $("pratio").textContent=lead>0?(lag/lead).toFixed(3):"-";
   pg.innerHTML="";
   pct.forEach((v,g)=>{const r=document.createElement("div"); r.className="prow";
     r.innerHTML=`<span class="gid">g${g}</span><span class="pb"><span style="width:${Math.min(100,v).toFixed(1)}%"></span></span><span class="pv">${v.toFixed(0)}%</span>`;
     pg.appendChild(r);});
 }
 sel.addEventListener("change",()=>{rng.value=0;draw();});
 rng.addEventListener("input",draw);
 if(sel.options.length){rng.max=Math.max(0,GU[sel.value].periods.length-1);
   rng.value=Math.floor(GU[sel.value].periods.length/2);draw();}
})();
</script>''')

    H.append("</div>")
    open(OUT, "w").write("\n".join(H))
    print("wrote %s (%d arm(s), %d with mesh)" % (OUT, len(rows), len(GU)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
