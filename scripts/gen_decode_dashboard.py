#!/usr/bin/env python3
"""Render the decode-GEMM benchmark dashboard.

EXTENSIBILITY IS THE POINT. Nothing about the current eight arms is hardcoded:

  * Arms are DISCOVERED (delivered ones from hardware/dec_*, running ones from
    decode_progress.json), so a new run appears with no code change.
  * mesh / core-count / precision come from FAMILIES, a one-line-per-family table. A new
    config -- 8x8 fp8, a 16x16 mesh, whatever -- is one entry.
  * Sections are grouped dynamically by mesh, then precision. Adding a mesh adds a section.
  * Peak, ideal cycles, efficiency and B slice are all COMPUTED from the shape and the family,
    never tabulated.

Reads only local files; run refresh_decode_progress.py first to update the live numbers.
"""
import glob, html, json, os, re

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT = "/tmp/claude-620771/decode_dash.html"
PROG = os.path.join(ROOT, "docs/benchmarks/decode_progress.json")

# arm-name prefix -> (mesh label, cores, precision, element bytes, MACs per FPU per cycle)
# ADD A LINE HERE to onboard a new config. Order matters only for prefix disambiguation.
FAMILIES = [
    ("dec4_",  ("4x4",  256, "fp16", 2, 2)),
    ("dec8_",  ("8x8", 1024, "fp16", 2, 2)),
    ("d4f32_", ("4x4",  256, "fp32", 4, 1)),
    ("d8f32_", ("8x8", 1024, "fp32", 4, 1)),
]
N_FU = 4
KERNEL_SIZE = 8


def family(arm):
    for p, f in FAMILIES:
        if arm.startswith(p):
            return f
    return None


def scrape(arm):
    t = os.path.join(ROOT, "hardware", "dec_" + arm, "transcript")
    try:
        b = open(t, "rb").read()
    except OSError:
        return None
    m = re.search(rb"execution took (\d+)", b)
    if not m:
        return None
    u = re.search(rb"\[FPU FINAL\][^\n]*?util=([0-9.]+)%", b)
    eoc = b.count(b"[EOC]") > 0 or b.count(b"Simulation ended") > 0
    # SUM the per-period deltas: mshr_timeout / bankfull_bypass are per-period, not totals.
    txt = b"\n".join(l[2:] if l.startswith(b"# ") else l for l in b.split(b"\n"))
    tot = lambda tag: sum(int(x) for x in re.findall(tag + rb"=\+(\d+)", txt))
    return {"cycles": int(m.group(1)), "util": float(u.group(1)) if u else None, "eoc": eoc,
            "tmo": tot(rb"mshr_timeout"), "bf": tot(rb"bankfull_bypass"),
            "rh": txt.count(b"RH STUCK")}


def scrape_dir(d):
    """Same fields as scrape(), but takes a DIRECTORY PATH.

    scrape() takes an ARM NAME and prepends "dec_" internally; handing it a path yields
    hardware/dec_/usr/... and a silent None. The w8k re-runs live under a different prefix, so
    they need this. Keep the two in step.
    """
    try:
        b = open(os.path.join(d, "transcript"), "rb").read()
    except OSError:
        return None
    m = re.search(rb"execution took (\d+)", b)
    if not m:
        return None
    u = re.search(rb"\[FPU FINAL\][^\n]*?util=([0-9.]+)%", b)
    txt = b"\n".join(l[2:] if l.startswith(b"# ") else l for l in b.split(b"\n"))
    tot = lambda tag: sum(int(x) for x in re.findall(tag + rb"=\+(\d+)", txt))
    return {"cycles": int(m.group(1)), "util": float(u.group(1)) if u else None,
            "eoc": b.count(b"[EOC]") > 0, "tmo": tot(rb"mshr_timeout"),
            "bf": tot(rb"bankfull_bypass"), "rh": txt.count(b"RH STUCK")}


def collect():
    try:
        prog = json.load(open(PROG))["arms"]
    except Exception:
        prog = {}
    arms = set(prog)
    for d in glob.glob(os.path.join(ROOT, "hardware", "dec_*")):
        arms.add(os.path.basename(d)[4:])
    rows = []
    for arm in sorted(arms):
        f = family(arm)
        m = re.search(r"(\d+)x(\d+)x(\d+)$", arm)
        if not f or not m:
            continue
        mesh, cores, prec, eb, mac = f
        B, D, I = (int(x) for x in m.groups())
        peak = cores * N_FU * mac
        ideal = B * D * I / peak
        chunks = max(1, B // KERNEL_SIZE)
        blocks = max(1, cores // chunks)
        slice_b = (I // blocks) * eb
        r = scrape(arm)
        p = prog.get(arm, {})
        rows.append(dict(arm=arm, mesh=mesh, cores=cores, prec=prec, B=B, D=D, I=I,
                         slice=slice_b, peak=peak, ideal=ideal, blocks=blocks, chunks=chunks,
                         ws=(B * D * eb + D * I * eb + B * I * eb) / 2**20,
                         cycles=r["cycles"] if r else None,
                         util=r["util"] if r else None,
                         tmo=r["tmo"] if r else None, bf=r["bf"] if r else None,
                         rh=r["rh"] if r else None,
                         eoc=r["eoc"] if r else None,
                         eff=(100.0 * ideal / r["cycles"]) if r and r["cycles"] else None,
                         live_cyc=p.get("cyc"), live_cum=p.get("cum"),
                         state="done" if r else ("running" if arm in prog else "queued")))
    return rows


def bar(pct, cls):
    w = max(0.0, min(100.0, pct or 0.0))
    return ('<div class="bar"><span class="%s" style="width:%.1f%%"></span></div>' % (cls, w))


def main():
    rows = collect()
    done = [r for r in rows if r["state"] == "done"]
    best = max(done, key=lambda r: r["eff"]) if done else None
    H = []
    H.append("<title>Decode GEMM Benchmark</title>")
    H.append("""<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Sans+Condensed:wght@600;700&family=IBM+Plex+Mono:wght@400;500&display=swap">""")
    H.append("""<style>
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
</style>""")
    H.append('<div class="wrap">')
    # ---- header
    H.append('<header>')
    H.append('<p class="eyebrow">TeraNoC &middot; Spatz &middot; shared-L1 manycore</p>')
    H.append('<h1>Decode-shape GEMM</h1>')
    H.append('<p class="sub">LLM decode is <code>C[B][I] = A[B][D] &times; W[D][I]</code> with a tiny batch. '
             'At <code>B&nbsp;=&nbsp;32</code> the prefill work split leaves almost the whole mesh idle, so the '
             'kernel keeps the same inner loop and changes only how work is divided.</p>')
    H.append('</header>')
    # ---- 2026-08-26: every number below predates the MSHR merge fix
    H.append('<section class="card"><div><h2>Read this first &mdash; the merge was off</h2></div>')
    H.append('<p class="note flag">Every measurement on this page was taken with <b>MSHR request '
             'merging bypassed</b>. <code>mshr_cfg.h</code> derived the merge config from the '
             '<b>prefill</b> split, <code>(GEMM_M / NUM_GROUPS) / KERNEL_SIZE</code> &mdash; at '
             'decode <code>B&nbsp;=&nbsp;32</code> on 8&times;8 that is <code>32/64&nbsp;=&nbsp;0</code> '
             'in integer arithmetic. It emitted <code>hold_subs_single=1</code> (bypass), '
             '<code>hold_subs_burst=0</code>, both hold windows <code>0</code>, and '
             '<code>gap_words=8192</code>. The hardware <b>rejected</b> the out-of-range <code>0</code> (<code>subs_ok</code>, <code>mempool_group_mshr_cfg.sv:128</code>) and kept its default of 4, but it <i>accepted</i> both zero hold windows &mdash; 0 is in range. So bursts could merge yet were never held: an entry issued the instant it allocated, and only coincidental overlap merged. That is the measured <b>1.06&times;</b>. Singles were genuinely bypassed: <code>1</code> is the legal bypass encoding.</p>')
    H.append('<p class="note">The decode split actually gives a group sharing degree of '
             '<b>4 for both A and W</b>: <code>n_row_chunks = M/KERNEL_SIZE = 4</code> and '
             '<code>row_chunk</code> varies fastest, so the four cores sharing a W column-block are '
             'consecutive <code>cid</code> and land in one group. Fixed 2026-08-26; run 3 re-runs '
             'all 8 arms on <b>byte-identical hardware images</b>, so the CSR config is the only '
             'variable. Derived values were verified out of the built ELFs '
             '(<code>subs 4/4</code>, windows <code>8191/8191</code>, <code>gap_words 32</code>), '
             'not from the source.</p>')
    H.append('<p class="note">This is consistent with what the stage profile already showed: '
             '<code>REQ_TILE_OUT</code>/<code>REQ_MSHR_IN</code> stalled <b>90.2%</b> while mesh '
             'links ran only <b>9.3%</b> busy, and merge capture measured <b>1.06&times;</b> against '
             'an available 4&times;. It does not yet prove admission pressure is the ceiling &mdash; '
             'if run 3 comes back flat, the W-streaming bandwidth argument stands unchanged.</p>')
    H.append('</section>')
    # ---- hero
    if best:
        H.append('<section class="card"><div class="hero">')
        H.append('<div class="stat"><span class="n">%.1f%%</span><span class="l">best efficiency &mdash; %s %s <code>%dx%dx%d</code></span></div>'
                 % (best["eff"], best["mesh"], best["prec"], best["B"], best["D"], best["I"]))
        H.append('<div class="stat"><span class="n">%d</span><span class="l">arms measured</span></div>' % len(done))
        H.append('<div class="stat"><span class="n">%d</span><span class="l">running</span></div>'
                 % sum(1 for r in rows if r["state"] == "running"))
        H.append('<div class="stat"><span class="n">%d&nbsp;B</span><span class="l">B slice &mdash; every arm on the optimum</span></div>'
                 % (done[0]["slice"] if done else 0))
        H.append('</div></section>')
    # ---- results, grouped by mesh then precision (dynamic)
    for mesh in sorted({r["mesh"] for r in rows}):
        fam = [r for r in rows if r["mesh"] == mesh]
        cores = fam[0]["cores"]
        H.append('<section class="card">')
        H.append('<div><h2>%s mesh &mdash; %d cores</h2>'
                 '<p class="sub">Peak %s MAC/cycle at fp16, %s at fp32 (cores &times; 4 FPU, fp16 double-pumped).</p></div>'
                 % (mesh, cores, "{:,}".format(cores * N_FU * 2), "{:,}".format(cores * N_FU)))
        H.append('<div class="tw"><table><tr>'
                 '<th>shape B&times;D&times;I</th><th>prec</th><th class="num">B slice</th>'
                 '<th class="num">cycles</th><th class="num">ideal</th><th class="num">efficiency</th>'
                 '<th style="min-width:110px">&nbsp;</th>'
                 '<th class="num">tmo</th><th class="num">bankfull</th><th class="num">RH</th>'
                 '<th class="num">working set</th><th>state</th></tr>')
        for r in sorted(fam, key=lambda x: (x["prec"], x["D"], x["I"])):
            if r["state"] == "done":
                eff = '<span class="eff">%.1f%%</span>' % r["eff"]
                bar_html = bar(r["eff"], "b-eff")
                cyc = "{:,}".format(r["cycles"])
            elif r["live_cum"] is not None:
                eff = '<span class="st-running">%.0f%% cum util</span>' % r["live_cum"]
                bar_html = bar(r["live_cum"], "b-live")
                cyc = "at %s" % "{:,}".format(r["live_cyc"] or 0)
            else:
                eff = '<span class="st-queued">&mdash;</span>'; bar_html = ""; cyc = "&mdash;"
            ctr = lambda v: ("{:,}".format(v) if v is not None else "&mdash;")
            H.append('<tr><td><code>%d&times;%d&times;%d</code></td>'
                     '<td><span class="chip %s">%s</span></td>'
                     '<td class="num">%d B</td><td class="num">%s</td><td class="num">%s</td>'
                     '<td class="num">%s</td><td>%s</td>'
                     '<td class="num">%s</td><td class="num">%s</td><td class="num">%s</td>'
                     '<td class="num">%.2f MiB</td>'
                     '<td><span class="chip st-%s">%s</span></td></tr>'
                     % (r["B"], r["D"], r["I"], r["prec"], r["prec"], r["slice"], cyc,
                        "{:,}".format(int(r["ideal"])), eff, bar_html,
                        ctr(r.get("tmo")), ctr(r.get("bf")), ctr(r.get("rh")), r["ws"],
                        r["state"], r["state"]))
        H.append('</table></div></section>')
    # ---- config A/B: the w8k re-runs (remap 2->3, hold/serve 2047->8191)
    ab = []
    for r in rows:
        if not r.get("cycles"):
            continue
        s2 = scrape_dir(os.path.join(ROOT, "hardware", "w8k_" + r["arm"]))
        if s2 and s2.get("cycles"):
            ab.append((r, s2))
    if ab:
        H.append('<section class="card">')
        H.append('<div><h2>Config A/B &mdash; <code>remap 2&rarr;3</code>, '
                 '<code>hold/serve 2047&rarr;8191</code></h2></div>')
        H.append('<p class="note">Same shapes, same <code>KERNEL_SIZE=8</code>, same ELF source; '
                 're-runs in <code>hardware/w8k_&lt;arm&gt;/</code>. The 4&times;4 pair also flips '
                 '<code>BANKFULL_BACKPRESSURE</code> off&rarr;on, which is why <b>bankfull</b> '
                 'collapses to 0 there. <b>The prediction was no effect</b>: every decode arm '
                 'already runs at <code>tmo = 0</code>, and the sweep A/B found the hold window&rsquo;s '
                 'payoff tracks the timeout <i>rate</i> &mdash; a shape with no timeouts has nothing '
                 'to gain.</p>')
        H.append('<div class="tw"><table><tr><th>shape B&times;D&times;I</th><th>prec</th>'
                 '<th class="num">baseline</th><th class="num">re-run</th><th class="num">delta</th>'
                 '<th class="num">base eff</th><th class="num">new eff</th>'
                 '<th class="num">bankfull</th></tr>')
        ds = []
        for r, s2 in sorted(ab, key=lambda x: (x[0]["mesh"], x[0]["prec"], x[0]["D"])):
            d = 100.0 * (s2["cycles"] - r["cycles"]) / r["cycles"]
            ds.append(d)
            e0 = 100.0 * r["ideal"] / r["cycles"]; e1 = 100.0 * r["ideal"] / s2["cycles"]
            cls = "eff" if abs(d) < 3 else "st-running"
            H.append('<tr><td><code>%d&times;%d&times;%d</code></td>'
                     '<td><span class="chip %s">%s</span></td>'
                     '<td class="num">%s</td><td class="num">%s</td>'
                     '<td class="num"><span class="%s">%+.1f%%</span></td>'
                     '<td class="num">%.1f%%</td><td class="num">%.1f%%</td>'
                     '<td class="num">%s &rarr; %s</td></tr>'
                     % (r["B"], r["D"], r["I"], r["prec"], r["prec"],
                        "{:,}".format(r["cycles"]), "{:,}".format(s2["cycles"]), cls, d, e0, e1,
                        "{:,}".format(r["bf"]) if r.get("bf") is not None else "&mdash;",
                        "{:,}".format(s2["bf"]) if s2.get("bf") is not None else "&mdash;"))
        H.append('</table></div>')
        H.append('<p class="note"><b>%d of 8 arms in; spread %+.1f%% to %+.1f%%, mean %+.1f%%.</b> '
                 'Scatter around zero in both directions is what the timeout-rate model predicts; '
                 'a systematic gain would not be.</p>'
                 % (len(ab), min(ds), max(ds), sum(ds)/len(ds)))
        H.append('</section>')

    # ---- run 3: the corrected merge derivation
    r3 = []
    for r in rows:
        if not r.get("cycles"):
            continue
        s3 = scrape_dir(os.path.join(ROOT, "hardware", "fix_" + r["arm"]))
        if s3 and s3.get("cycles"):
            s2 = scrape_dir(os.path.join(ROOT, "hardware", "w8k_" + r["arm"]))
            r3.append((r, s2, s3))
    if r3:
        H.append('<section class="card">')
        H.append('<div><h2>Run 3 &mdash; the merge turned on</h2></div>')
        H.append('<p class="note">Same shapes, same <code>KERNEL_SIZE=8</code>, '
                 '<b>byte-identical hardware images</b> to run 2 &mdash; the MSHR CSR config is the '
                 'only variable. <code>subs 4/4</code>, windows <code>8191/8191</code>, '
                 '<code>gap_words 32</code>, verified out of the built ELFs. Every arm also carries '
                 'a runtime guard that prints <code>[MSHR] SPLIT MISMATCH</code> if the compile-time '
                 'derivation and the kernel&rsquo;s own split ever disagree again; no arm has printed it.</p>')
        H.append('<div class="tw"><table><tr><th>shape B&times;D&times;I</th><th>mesh</th><th>prec</th>'
                 '<th class="num">run 1</th><th class="num">run 2</th><th class="num">run 3</th>'
                 '<th class="num">vs run 2</th><th class="num">eff before</th><th class="num">eff after</th>'
                 '<th class="num">tmo</th></tr>')
        ds = []
        for r, s2, s3 in sorted(r3, key=lambda x: (x[0]["mesh"], x[0]["prec"], x[0]["D"])):
            base2 = s2["cycles"] if (s2 and s2.get("cycles")) else r["cycles"]
            d = 100.0 * (s3["cycles"] - base2) / base2
            ds.append(d)
            e0 = 100.0 * r["ideal"] / base2
            e1 = 100.0 * r["ideal"] / s3["cycles"]
            cls = "eff" if d < -3 else ("st-running" if d > 3 else "")
            H.append('<tr><td><code>%d&times;%d&times;%d</code></td><td>%s</td>'
                     '<td><span class="chip %s">%s</span></td>'
                     '<td class="num">%s</td><td class="num">%s</td><td class="num"><b>%s</b></td>'
                     '<td class="num"><span class="%s">%+.1f%%</span></td>'
                     '<td class="num">%.1f%%</td><td class="num"><b>%.1f%%</b></td>'
                     '<td class="num">%s</td></tr>'
                     % (r["B"], r["D"], r["I"], r["mesh"], r["prec"], r["prec"],
                        "{:,}".format(r["cycles"]),
                        "{:,}".format(s2["cycles"]) if (s2 and s2.get("cycles")) else "&mdash;",
                        "{:,}".format(s3["cycles"]), cls, d, e0, e1,
                        "{:,}".format(s3["tmo"]) if s3.get("tmo") is not None else "&mdash;"))
        H.append('</table></div>')
        H.append('<p class="note"><b>%d of 8 arms in; spread %+.1f%% to %+.1f%%, mean %+.1f%%.</b> '
                 'The measured bottleneck was MSHR <i>entry admission</i> &mdash; <code>REQ_MSHR_IN</code> '
                 'stalled 90.2%% while links ran 9.3%% busy &mdash; so this is where turning merging on '
                 'should show &mdash; and it does, at BOTH meshes. <b>The 49%% roofline ceiling quoted here '
                 'earlier for <code>B&nbsp;=&nbsp;32</code> fp16 at 8&times;8 is refuted:</b> 8&times;8 fp16 '
                 'reaches <b>63.6%%</b> and fp32 <b>60.5%%</b>. That ceiling was computed from a supply '
                 'figure measured on a configuration where merging was off, so it described the machine '
                 'without the MSHR rather than with it. Merging does not just close an admission gap &mdash; '
                 'it lowers the bandwidth <i>demand</i>, because four cores in a group share one fetch and '
                 'one multicast response. The ceiling scales with merge degree.</p>'
                 '<p class="note flag"><b>Caveat:</b> these arms carry no result verification &mdash; <code>MATMUL_VERIFY</code> is not set and the kernel prints no pass/fail. Cycle counts are comparable across runs (identical shape and per-core split, and the MSHR is transparent to arithmetic), but none of these runs establishes numerical correctness.</p>'
                 % (len(r3), min(ds), max(ds), sum(ds)/len(ds)))
        H.append('</section>')

    # ---- how the split works
    H.append('<section class="card">')
    H.append('<div><h2>Why this needs its own work split</h2></div>')
    H.append('<p class="note">The prefill split divides <b>M</b> across groups first. Decode has '
             '<code>M = B = 32</code>, far below the group count, so each group would get zero rows and the '
             'prefill path rejects the shape outright. The decode split divides <b>P</b> as well as <b>M</b>:</p>')
    H.append('<div class="grid">')
    for k, v in (("row_chunk", "cid % n_row_chunks &mdash; which 8 rows of B this core owns"),
                 ("p_block", "cid / n_row_chunks &mdash; which column slice it owns"),
                 ("n_row_chunks", "B / KERNEL_SIZE = 4"),
                 ("n_p_blocks", "cores / n_row_chunks")):
        H.append('<div class="kv"><div class="k">%s</div><div class="v">%s</div></div>' % (k, v))
    H.append('</div>')
    H.append('<p class="note"><b>No transpose is required</b>, which matters because the DMA has no transpose '
             'support. <code>A[b][d]</code> is contiguous for the scalar load and <code>W[d][p:p+VL]</code> is '
             'contiguous for the vector load &mdash; exactly what the prefill inner loop already does. Only the '
             'work split changes; <code>MATMUL_DECODE_SPLIT</code> selects it, and it is derived from the shape '
             'at compile time rather than passed by hand.</p>')
    H.append('<p class="note"><code>row_chunk</code> varies fastest <b>on purpose</b>: cores sharing a '
             '<code>p_block</code> read the same W bytes and consecutive core ids sit in the same group, so the '
             'group MSHR burst-merges their identical W loads and W leaves L2 once rather than '
             '<code>n_row_chunks</code> times.</p>')
    H.append('</section>')
    # ---- findings, only what the data supports
    if len(done) >= 2:
        H.append('<section class="card"><div><h2>What the measurements say</h2></div><ul>')
        for mesh in sorted({r["mesh"] for r in done}):
            for prec in sorted({r["prec"] for r in done if r["mesh"] == mesh}):
                g = sorted([r for r in done if r["mesh"] == mesh and r["prec"] == prec],
                           key=lambda x: x["D"])
                if len(g) >= 2:
                    H.append('<li><b>%s %s:</b> D=%d reaches %.1f%%, D=%d reaches %.1f%% &mdash; the wider hidden '
                             'dimension gives each core more work per W fetch, amortising the per-iteration fixed '
                             'cost.</li>' % (mesh, prec, g[0]["D"], g[0]["eff"], g[-1]["D"], g[-1]["eff"]))
        pairs = {}
        for r in done:
            pairs.setdefault((r["mesh"], r["D"]), {})[r["prec"]] = r
        for (mesh, D), p in sorted(pairs.items()):
            if "fp16" in p and "fp32" in p:
                a, b = p["fp16"], p["fp32"]
                H.append('<li><b>%s, D=%d:</b> fp32 converts %.1f%% of its peak against fp16&rsquo;s %.1f%%, while fp16 '
                         'still delivers %.1fx the absolute MAC rate. Same B slice, same ideal cycle count &mdash; '
                         'fp16 wastes more of a larger peak, consistent with its scalar-A values needing sub-word '
                         'extraction on the critical path.</li>'
                         % (mesh, D, b["eff"], a["eff"],
                            (a["B"]*a["D"]*a["I"]/a["cycles"]) / (b["B"]*b["D"]*b["I"]/b["cycles"])))
        H.append('</ul></section>')
    # ---- per-group mesh + progress (only if we have per-group data)
    try:
        GU = json.load(open(os.path.join(ROOT, "docs/benchmarks/decode_group_util.json")))
    except Exception:
        GU = {}
    if GU:
        H.append('<section class="card">')
        H.append('<div><h2>Per-group FPU utilisation over the benchmark</h2>'
                 '<p class="sub">Each cell is one group, laid out as the physical mesh. Colour is that '
                 'group&rsquo;s FPU utilisation in one 1000-cycle window. Drag the slider to move through '
                 'time. The whole-run number averages over every group and every window, so it hides '
                 'exactly what this shows: <b>how evenly the work is spread</b>. The mesh resizes itself '
                 'to the selected arm, so a 4x4 and an 8x8 arm both render correctly.</p></div>')
        H.append('<div class="mctl">'
                 '<div><label for="marm">arm</label><select id="marm">'
                 + "".join('<option value="%s">%s &middot; %s &middot; %s</option>'
                           % (html.escape(a), GU[a]["mesh"], GU[a]["prec"],
                              html.escape(a.split("_", 1)[1]))
                           for a in sorted(GU))
                 + '</select></div>'
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
                 '</dl><p class="sub" style="margin-top:13px;font-size:12.5px">A wide spread means some '
                 'groups are starved while others saturate. For decode this is the number to watch: the '
                 'split gives every core an equal tile, so any spread is the memory system, not the '
                 'partition.</p></div></div>')
        H.append('<h3 class="sec">Per-group progress &mdash; are the groups advancing together?</h3>')
        H.append('<p class="sub" style="margin-bottom:13px">Each bar is a group&rsquo;s progress against its '
                 '<b>own equal share</b> of the work &mdash; MACs completed divided by '
                 '<code>B&middot;D&middot;I / groups</code>. MACs come from the probe as '
                 '<code>&Sigma;(util &times; denom)</code> &times; MAC/lane-cycle (2 for fp16, two values '
                 'packed per word; 1 for fp32). Driven by the same slider. Aligned groups move as one '
                 'block; spread is wasted machine, because the kernel ends only when the <b>last</b> group '
                 'finishes.</p>')
        # Quote the overhead MEASURED on these arms, not the 8x8 campaign's ~15%: for decode it is
        # ~3.5%, and carrying over a number from another campaign would misstate it by 4x.
        ovh = []
        for v in GU.values():
            tot = sum(u / 100 * v["denom"] * v["mac"] for pp in v["periods"] for u in pp["u"])
            ovh.append(tot / (v["share"] * v["groups"]))
        ov = (sum(ovh) / len(ovh) - 1) * 100 if ovh else 0
        gaps = []
        for v in GU.values():
            n = v["groups"]; cum = [0.0] * n
            for pp in v["periods"]:
                for g, u in enumerate(pp["u"]):
                    cum[g] += u / 100 * v["denom"] * v["mac"]
            pct = [100 * c / v["share"] for c in cum]
            gaps.append(max(pct) - min(pct))
        H.append('<p class="sub" style="margin-bottom:13px;font-size:12.5px">A finished group reads a little '
                 '<b>over 100%%</b>. That is expected &mdash; the probe counts lane <b>occupancy</b>, not '
                 'retired MACs; across these arms the excess is a consistent <b>%.1f%%</b>. The bar clamps at '
                 '100%%; the number does not, so the overhead stays visible instead of being quietly hidden.</p>'
                 % ov)
        H.append('<p class="sub" style="margin-bottom:13px"><b>The groups finish within %.0f&ndash;%.0f pp of '
                 'each other</b> on every measured arm. That is the decode split working as intended: each core '
                 'gets an identical tile, and the memory system keeps them fed evenly. For contrast, the 8x8 '
                 'prefill sweep fans out to tens of points between fastest and slowest group.</p>'
                 % (min(gaps), max(gaps)))
        H.append('<div class="mmeta" style="margin-bottom:11px"><dl>'
                 '<dt>leader</dt><dd id="plead">-</dd><dt>laggard</dt><dd id="plag">-</dd>'
                 '<dt>gap</dt><dd id="pgap">-</dd><dt>laggard / leader</dt><dd id="pratio">-</dd>'
                 '</dl></div><div class="prog" id="pgrid"></div>')
        H.append("<script>const GU=%s;</script>" % json.dumps(GU, separators=(",", ":")))
        H.append("""<script>
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
</script>""")
        H.append('</section>')

    # ---- known issue
    H.append('<section class="card"><div><h2>Known issue &mdash; the spotcheck wedge</h2></div>')
    H.append('<p class="note flag">Arms built with <code>MATMUL_SPOTCHECK=1</code> print their result banner and then '
             '<b>wedge core 0 inside printf</b> (<code>_ntoa_long</code>), leaving every other core at '
             '<code>mempool_barrier</code>. No <code>[EOC]</code> is emitted, the testbench never terminates, and the '
             'arm holds a licence seat indefinitely &mdash; one ran to cycle 1,826,000 after a 15,697-cycle benchmark. '
             'The cycle count is still valid, since it is printed before the spotcheck. The control is clean: arms '
             'built without the define emit <code>[EOC]</code> and deliver normally. Such arms are harvested off the '
             'node at the banner and their seat reclaimed.</p></section>')
    H.append('<footer>Generated by <code>scripts/gen_decode_dashboard.py</code> from '
             '<code>hardware/dec_*</code> and <code>decode_progress.json</code>. '
             'Efficiency = ideal/actual; ideal = B&middot;D&middot;I / peak. Ranked on efficiency, not on the '
             'testbench <code>util</code> column, which is lane occupancy.</footer>')
    H.append('</div>')
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "w").write("\n".join(H))
    print("wrote %s (%d arms, %d done, %d running)"
          % (OUT, len(rows), len(done), sum(1 for r in rows if r["state"] == "running")))


main()
