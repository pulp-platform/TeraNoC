#!/usr/bin/env python3
"""Render the 8x8 scale-up ladder dashboard. Reads results.tsv + live badist state."""
import io, os, subprocess, html, time

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUTD = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup")
OUT  = "/tmp/claude-620771/s8_rungs.html"   # NOT s8_ladder.html -- gen_8x8_dashboard.py owns that
                                           # path and the results loop republishes it, so sharing
                                           # it meant whichever generator ran last silently
                                           # clobbered the published artifact.

RUNGS = [
    (16, "512x2048x1024",  "512x1024x1024"),
    (8,  "1024x2048x512",  "1024x1024x512"),
    (4,  "2048x1024x512",  "2048x512x512"),
    (2,  "4096x512x512",   "4096x256x512"),
    (1,  "8192x256x512",   None),
]

def batch():
    try: return io.open(os.path.join(OUTD, "batch.txt")).read().strip()
    except Exception: return ""

def live():
    """arm -> (state, node) from badist."""
    b = batch()
    if not b: return {}
    try:
        out = subprocess.run([os.path.expanduser("~/badist/bin/badist"), "status", b, "--json"],
                             capture_output=True, text=True, timeout=90).stdout
        import json
        return dict(((r.get("meta") or {}).get("arm", "?"),
                     (r.get("state") or "?", r.get("node") or "-")) for r in json.loads(out))
    except Exception:
        return {}

def results():
    rows = {}
    COLS = []
    try:
        for ln in io.open(os.path.join(OUTD, "results.tsv")):
            p = ln.rstrip("\n").split("\t")
            if p[0] == "shape":
                COLS = p                       # the file states its own layout; trust it
                continue
            if len(p) >= 9 and COLS:
                # Index by NAME, not position. These were hardcoded p[3..7] and went stale the
                # day fpu_util was inserted at index 4: every field from there on shifted by one,
                # so the cards rendered fpu_util under "RH", RH under "timeout" and mshr_timeout
                # under "bypass", and r["sc"] held the bankfull COUNT -- which is never the string
                # "ok", so every arm painted as "bad". Read the header instead.
                rows["%s_%s" % (p[1], p[0])] = {k: p[i] for i, k in enumerate(COLS) if i < len(p)}
    except Exception:
        pass
    return rows

L, R = live(), results()

def card(prec, shape):
    if shape is None:
        return ('<div class="arm none"><div class="armhead"><span class="prec">fp32</span>'
                '<span class="pill na">not possible</span></div>'
                '<div class="why">C alone needs 20.3&nbsp;MiB &gt; 14.5 budget</div></div>')
    arm = "%s_%s" % (prec, shape)
    st, node = L.get(arm, ("pending", "-"))
    r = R.get(arm)
    if r:
        sc = r.get("spotcheck", "")
        # RH-STUCK episode count is the livelock detector: a healthy arm is in single digits
        # (2048x128x128 -> 4 at 41% util), a livelocked one is 10^5. See
        # docs/benchmarks/8x8_scaleup/rh_livelock_root_cause.md -- those arms measure a software
        # cohort-target bug, not the architecture, so the number must not read as a result.
        try:
            live = int(r.get("RH", "0")) > 1000
        except ValueError:
            live = False
        if live:
            cls, lab = "bad", "LIVELOCK"
        elif sc.startswith("ok") or sc.startswith("grp0-only"):
            cls, lab = "ok", "done"
        else:
            cls, lab = "bad", (sc or "done")
        body = ('<dl class="m"><div><dt>cycles</dt><dd class="big">%s</dd></div>'
                '<div><dt>util</dt><dd>%s%%</dd></div><div><dt>RH</dt><dd>%s</dd></div>'
                '<div><dt>timeout</dt><dd>%s</dd></div></dl>'
                % (fmt(r.get("cycles")), r.get("fpu_util", "-"),
                   fmt(r.get("RH")), fmt(r.get("mshr_timeout"))))
    else:
        cls = "run" if st == "running" else "wait"
        lab = st
        body = '<div class="why">on %s</div>' % html.escape(node)
    return ('<div class="arm %s"><div class="armhead"><span class="prec">%s</span>'
            '<span class="pill %s">%s</span></div><code class="shape">%s</code>%s</div>'
            % (cls, prec, cls, html.escape(lab), html.escape(shape), body))

def fmt(v):
    try: return "{:,}".format(int(v))
    except Exception: return html.escape(str(v))

done = len(R)
rung_html = []
for share, s16, s32 in RUNGS:
    rung_html.append(
        '<section class="rung"><div class="deg"><span class="n">%d</span><span class="u">-way</span>'
        '<span class="lbl">A-share</span></div><div class="arms">%s%s</div></section>'
        % (share, card("fp16", s16), card("fp32", s32)))

doc = """<title>8&times;8 A-Share Ladder</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans+Condensed:wght@600;700&family=IBM+Plex+Sans:wght@400;500&display=swap">
<style>
:root{--bg:#f4f6f7;--surf:#fff;--line:#d8dee1;--ink:#0e1418;--dim:#5a6b75;--acc:#d98324;
--ok:#1f7a5c;--bad:#b3382c;--run:#1f6f8b;--wait:#7d8b93;--shadow:0 1px 2px rgba(14,20,24,.06)}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0e1418;--surf:#161e23;
--line:#26313a;--ink:#e6edf1;--dim:#8aa0ad;--acc:#e8a04e;--ok:#3fa37c;--bad:#d9614f;--run:#4fa3c4;
--wait:#6b7d88;--shadow:0 1px 2px rgba(0,0,0,.35)}}
:root[data-theme="dark"]{--bg:#0e1418;--surf:#161e23;--line:#26313a;--ink:#e6edf1;--dim:#8aa0ad;
--acc:#e8a04e;--ok:#3fa37c;--bad:#d9614f;--run:#4fa3c4;--wait:#6b7d88;--shadow:0 1px 2px rgba(0,0,0,.35)}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font:400 15px/1.55 "IBM Plex Sans",system-ui,sans-serif;padding:28px 20px 60px}
.wrap{max-width:1000px;margin:0 auto;display:flex;flex-direction:column;gap:26px}
h1{font:700 30px/1.15 "IBM Plex Sans Condensed","IBM Plex Sans",sans-serif;margin:0;
letter-spacing:-.01em;text-wrap:balance}
.sub{color:var(--dim);margin:6px 0 0;max-width:65ch}
.meta{display:flex;flex-wrap:wrap;gap:8px 18px;font:400 12.5px/1 "IBM Plex Mono",monospace;
color:var(--dim);margin-top:12px}
.warn{border:1px solid var(--bad);border-left-width:4px;border-radius:3px;padding:13px 15px;
background:var(--surf);box-shadow:var(--shadow)}
.warn b{color:var(--bad);font-weight:600}
.warn ol{margin:8px 0 0;padding-left:20px}.warn li{margin:4px 0}
.rung{display:grid;grid-template-columns:112px 1fr;gap:16px;align-items:stretch}
.deg{display:flex;flex-direction:column;justify-content:center;align-items:flex-end;
border-right:2px solid var(--acc);padding-right:14px}
.deg .n{font:700 40px/1 "IBM Plex Sans Condensed",sans-serif;color:var(--acc);
font-variant-numeric:tabular-nums}
.deg .u{font:600 13px/1 "IBM Plex Sans Condensed",sans-serif;color:var(--acc)}
.deg .lbl{font:400 10.5px/1.6 "IBM Plex Mono",monospace;color:var(--dim);
letter-spacing:.09em;text-transform:uppercase}
.arms{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.arm{background:var(--surf);border:1px solid var(--line);border-radius:4px;padding:13px 15px;
box-shadow:var(--shadow);display:flex;flex-direction:column;gap:8px}
.arm.none{opacity:.62}
.armhead{display:flex;justify-content:space-between;align-items:center;gap:10px}
.prec{font:600 12px/1 "IBM Plex Mono",monospace;letter-spacing:.06em;color:var(--dim)}
.pill{font:600 10.5px/1 "IBM Plex Mono",monospace;letter-spacing:.07em;text-transform:uppercase;
padding:4px 8px;border-radius:2px;color:#fff}
.pill.ok{background:var(--ok)}.pill.bad{background:var(--bad)}.pill.run{background:var(--run)}
.pill.wait,.pill.na{background:var(--wait)}
.shape{font:600 15px/1 "IBM Plex Mono",monospace;color:var(--ink)}
.why{font:400 12px/1.5 "IBM Plex Mono",monospace;color:var(--dim)}
dl.m{display:grid;grid-template-columns:repeat(4,1fr);gap:9px;margin:0}
dl.m dt{font:400 10px/1.4 "IBM Plex Mono",monospace;color:var(--dim);
letter-spacing:.07em;text-transform:uppercase}
dl.m dd{margin:2px 0 0;font:600 14px/1.2 "IBM Plex Mono",monospace;
font-variant-numeric:tabular-nums}
dl.m dd.big{color:var(--acc)}
table{border-collapse:collapse;width:100%;font:400 13px/1.5 "IBM Plex Sans",sans-serif}
.tw{overflow-x:auto}
th,td{text-align:left;padding:7px 12px 7px 0;border-bottom:1px solid var(--line)}
th{font:600 10.5px/1 "IBM Plex Mono",monospace;color:var(--dim);letter-spacing:.08em;
text-transform:uppercase}
td.num{font-family:"IBM Plex Mono",monospace;font-variant-numeric:tabular-nums}
h2{font:600 13px/1 "IBM Plex Mono",monospace;letter-spacing:.1em;text-transform:uppercase;
color:var(--dim);margin:0 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line)}
code{font-family:"IBM Plex Mono",monospace}
</style>
<div class="wrap">
<header>
<h1>8&times;8 A-Share Ladder</h1>
<p class="sub">Nine arms hold total work <code>M&middot;N&middot;P</code> constant and vary only
<b>M</b>, which alone sets how many cores share the same A rows &mdash; the degree the group MSHR
can coalesce. Growing total size while holding M fixed would say nothing about coalescing; this
isolates it.</p>
<div class="meta"><span>batch @@BATCH@@</span><span>1024 cores &middot; 64 groups</span>
<span>VCS &middot; build_vcs_8x8</span><span>@@DONE@@/9 complete</span>
<span>updated @@WHEN@@</span></div>
</header>

<div class="warn"><b>Dispatched speculatively &mdash; gate 6c step 2 was not met.</b>
No pilot had completed and no spotcheck had passed when these launched. Read every result with
these in mind:
<ol>
<li>Correctness is <b>self-reported per arm</b>. Check the spotcheck before quoting a cycle count.</li>
<li><b>L2 bandwidth per group halves at 8&times;8</b> (64 groups / 32 channels, against 16/16 at
4&times;4). A cross-mesh loss mixes mesh scaling with that halving &mdash; the ladder does not
separate them.</li>
<li>Record <b>RH per arm</b>, not just cycles: RH gates whether backpressure can help a shape at all.</li>
<li>The <b>M=128 family cannot run here</b> (<code>M % 512 == 0</code>), so the largest 4&times;4
results are not portable without changing <code>KERNEL_SIZE</code>.</li>
</ol></div>

@@RUNGS@@

<section><h2>Measured from the pilots</h2><div class="tw"><table>
<tr><th>quantity</th><th>estimated</th><th>measured</th></tr>
<tr><td>VCS peak RSS</td><td class="num">~7-9 GiB</td><td class="num">7.80 GiB</td></tr>
<tr><td>VCS throughput</td><td class="num">~13 cyc/s</td><td class="num">19.4 cyc/s</td></tr>
<tr><td>Questa peak RSS</td><td class="num">~60 GiB</td><td class="num">16.4 GiB</td></tr>
<tr><td>Questa throughput</td><td class="num">&mdash;</td><td class="num">12.2 cyc/s + ~10 min vopt/arm</td></tr>
<tr><td>FPU efficiency</td><td class="num">45% of peak</td><td class="num">~15%</td></tr>
</table></div>
<p class="sub" style="margin-top:12px">VCS and Questa produce identical state at 8&times;8
(<code>util=14.92%</code>, <code>RH=0</code>, <code>CMS=4037</code> on one ELF), extending the
validated-identical result from 4&times;4. The efficiency shortfall outweighs the throughput gain:
arms are <b>~12-13 h</b> each, not the 8 h planned.</p></section>
</div>
"""
doc = (doc.replace("@@BATCH@@", html.escape(batch() or "?"))
          .replace("@@DONE@@", str(done))
          .replace("@@RUNGS@@", "\n".join(rung_html))
          .replace("@@WHEN@@", time.strftime("%H:%M")))

io.open(OUT, "w", encoding="utf-8").write(doc)
print("wrote %s (%d bytes) - %d/9 arms with results" % (OUT, len(doc), done))
