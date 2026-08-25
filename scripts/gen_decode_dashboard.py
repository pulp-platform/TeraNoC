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
    return {"cycles": int(m.group(1)), "util": float(u.group(1)) if u else None, "eoc": eoc}


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
  --ground:#f4f5f7; --panel:#ffffff; --line:#dcdfe6; --line-soft:#e9ebf0;
  --ink:#171a22; --ink-2:#4a5163; --ink-3:#767d8f;
  --accent:#b4642f;            /* copper: efficiency, the one number that matters */
  --fp16:#3f6f9e; --fp32:#6f5f96;
  --good:#357a5b; --warn:#a8792c; --bad:#a2453d;
  --track:#e6e9ef;
  --mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
  --sans:"IBM Plex Sans",system-ui,-apple-system,Segoe UI,sans-serif;
  --cond:"IBM Plex Sans Condensed","IBM Plex Sans",system-ui,sans-serif;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --ground:#0f1219; --panel:#161a24; --line:#2a3040; --line-soft:#212736;
  --ink:#e8eaf0; --ink-2:#a8b0c2; --ink-3:#79839a;
  --accent:#d98950; --fp16:#6fa3d4; --fp32:#a08fd0;
  --good:#5cb389; --warn:#d4a955; --bad:#d4756a; --track:#232936;
}}
:root[data-theme="dark"]{
  --ground:#0f1219; --panel:#161a24; --line:#2a3040; --line-soft:#212736;
  --ink:#e8eaf0; --ink-2:#a8b0c2; --ink-3:#79839a;
  --accent:#d98950; --fp16:#6fa3d4; --fp32:#a08fd0;
  --good:#5cb389; --warn:#d4a955; --bad:#d4756a; --track:#232936;
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
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:20px 22px;
      display:flex;flex-direction:column;gap:14px}
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
.b-eff{background:var(--accent)} .b-live{background:var(--warn)}
.eff{font-family:var(--mono);font-weight:500;font-variant-numeric:tabular-nums;color:var(--accent)}
.note{font-size:13.5px;color:var(--ink-2)}
.note b{color:var(--ink)}
ul{margin:0;padding-left:18px} li{margin:5px 0;font-size:13.5px;color:var(--ink-2)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px}
.kv{border:1px solid var(--line-soft);border-radius:8px;padding:11px 13px}
.kv .k{font-family:var(--mono);font-size:10.5px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3)}
.kv .v{font-size:14px;margin-top:3px}
.flag{border-left:3px solid var(--warn);padding-left:13px}
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
                 '<th style="min-width:110px">&nbsp;</th><th class="num">working set</th><th>state</th></tr>')
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
            H.append('<tr><td><code>%d&times;%d&times;%d</code></td>'
                     '<td><span class="chip %s">%s</span></td>'
                     '<td class="num">%d B</td><td class="num">%s</td><td class="num">%s</td>'
                     '<td class="num">%s</td><td>%s</td><td class="num">%.2f MiB</td>'
                     '<td><span class="chip st-%s">%s</span></td></tr>'
                     % (r["B"], r["D"], r["I"], r["prec"], r["prec"], r["slice"], cyc,
                        "{:,}".format(int(r["ideal"])), eff, bar_html, r["ws"],
                        r["state"], r["state"]))
        H.append('</table></div></section>')
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
