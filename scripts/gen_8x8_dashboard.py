#!/usr/bin/env python3
"""Generate the 8x8 scale-up campaign dashboard HTML from live fleet state + results.tsv.

Writes /tmp/claude-620771/s8_ladder.html (the path the published artifact is redeployed from --
keep it, a new path would claim a new URL and orphan the existing link).
"""
import glob, json, os, re, subprocess, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = "/tmp/claude-620771/s8_ladder.html"
STATE = os.path.expanduser("~/badist/state")

LADDER = [(16, "fp16_512x2048x1024", "fp32_512x1024x1024"),
          (8,  "fp16_1024x2048x512", "fp32_1024x1024x512"),
          (4,  "fp16_2048x1024x512", "fp32_2048x512x512"),
          (2,  "fp16_4096x512x512",  "fp32_4096x256x512"),
          (1,  "fp16_8192x256x512",  None)]

def states():
    out, ts_seen = {}, {}
    for d in sorted(glob.glob(os.path.join(STATE, "*"))):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        ids = {j["job_id"]: (j.get("meta") or {}).get("arm", "") for j in jobs}
        seen = set()
        for f in glob.glob(os.path.join(d, "jobs", "*.jsonl")):
            jid = os.path.basename(f)[:-6]
            arm = ids.get(jid, "")
            if not arm.startswith(("fp16_", "fp32_")):
                continue
            seen.add(jid)
            last = None
            for ln in open(f):
                try: last = json.loads(ln)
                except Exception: pass
            if last:
                # a later batch supersedes an earlier verdict for the same arm -- decided by the
                # record's ts, NOT by batch-name order (campaign prefixes make name order != time
                # order, which left resubmitted arms showing their old `failed`)
                prev = ts_seen.get(arm)
                if prev is None or (last.get("ts") or 0) >= prev:
                    ts_seen[arm] = last.get("ts") or 0
                    out[arm] = (last.get("state"), last.get("node", "-"))
        for jid, arm in ids.items():
            if arm.startswith(("fp16_", "fp32_")) and jid not in seen and arm not in out:
                out[arm] = ("queued", "-")
    return out

def results():
    p = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")
    rows = []
    try:
        for i, ln in enumerate(open(p)):
            if i == 0: continue
            f = ln.rstrip("\n").split("\t")
            if len(f) >= 9: rows.append(f)
    except Exception:
        pass
    return rows

def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

CSS = """
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
.wrap{max-width:1060px;margin:0 auto;display:flex;flex-direction:column;gap:26px}
h1{font:700 30px/1.15 "IBM Plex Sans Condensed","IBM Plex Sans",sans-serif;margin:0;
letter-spacing:-.01em;text-wrap:balance}
.sub{color:var(--dim);margin:6px 0 0;max-width:65ch}
.meta{display:flex;flex-wrap:wrap;gap:8px 18px;font:400 12.5px/1 "IBM Plex Mono",monospace;
color:var(--dim);margin-top:12px}
h2{font:600 13px/1 "IBM Plex Mono",monospace;letter-spacing:.1em;text-transform:uppercase;
color:var(--dim);margin:0 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(132px,1fr));gap:12px}
.tile{background:var(--surf);border:1px solid var(--line);border-radius:4px;padding:14px 16px;
box-shadow:var(--shadow);display:flex;flex-direction:column;gap:3px}
.tile .n{font:700 30px/1 "IBM Plex Sans Condensed",sans-serif;font-variant-numeric:tabular-nums}
.tile .l{font:400 10.5px/1.5 "IBM Plex Mono",monospace;color:var(--dim);
letter-spacing:.09em;text-transform:uppercase}
.tile.done .n{color:var(--ok)}.tile.run .n{color:var(--run)}.tile.bad .n{color:var(--bad)}
.tile.wait .n{color:var(--wait)}
.bar{height:9px;border-radius:2px;background:var(--line);overflow:hidden;display:flex}
.bar i{display:block;height:100%}
.bar .d{background:var(--ok)}.bar .r{background:var(--run)}.bar .q{background:var(--wait)}
.bar .f{background:var(--bad)}
.warn{border:1px solid var(--bad);border-left-width:4px;border-radius:3px;padding:13px 15px;
background:var(--surf);box-shadow:var(--shadow)}
.warn b{color:var(--bad);font-weight:600}
.warn ol{margin:8px 0 0;padding-left:20px}.warn li{margin:4px 0}
table{border-collapse:collapse;width:100%;font:400 13px/1.5 "IBM Plex Sans",sans-serif}
.tw{overflow-x:auto}
th,td{text-align:left;padding:7px 12px 7px 0;border-bottom:1px solid var(--line);white-space:nowrap}
th{font:600 10.5px/1 "IBM Plex Mono",monospace;color:var(--dim);letter-spacing:.08em;
text-transform:uppercase}
td.num{font-family:"IBM Plex Mono",monospace;font-variant-numeric:tabular-nums;text-align:right}
.pill{font:600 10px/1 "IBM Plex Mono",monospace;letter-spacing:.06em;text-transform:uppercase;
padding:3px 7px;border-radius:2px;color:#fff;display:inline-block}
.pill.ok{background:var(--ok)}.pill.bad{background:var(--bad)}.pill.run{background:var(--run)}
.pill.wait,.pill.na{background:var(--wait)}
.rung{display:grid;grid-template-columns:104px 1fr;gap:16px;align-items:stretch;margin-bottom:12px}
.deg{display:flex;flex-direction:column;justify-content:center;align-items:flex-end;
border-right:2px solid var(--acc);padding-right:14px}
.deg .n{font:700 34px/1 "IBM Plex Sans Condensed",sans-serif;color:var(--acc);
font-variant-numeric:tabular-nums}
.deg .u{font:600 12px/1 "IBM Plex Sans Condensed",sans-serif;color:var(--acc)}
.arms{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.arm{background:var(--surf);border:1px solid var(--line);border-radius:4px;padding:11px 13px;
box-shadow:var(--shadow);display:flex;flex-direction:column;gap:6px}
.arm.none{opacity:.6}
.armhead{display:flex;justify-content:space-between;align-items:center;gap:10px}
.prec{font:600 11px/1 "IBM Plex Mono",monospace;letter-spacing:.06em;color:var(--dim)}
.shape{font:600 14px/1 "IBM Plex Mono",monospace}
.why{font:400 11.5px/1.45 "IBM Plex Mono",monospace;color:var(--dim)}
.empty{color:var(--dim);font:400 13px/1.6 "IBM Plex Sans",sans-serif;
border:1px dashed var(--line);border-radius:4px;padding:18px;text-align:center}
code{font-family:"IBM Plex Mono",monospace}
"""

def main():
    st = states()
    res = results()
    tot = 248
    done = sum(1 for a, (s, n) in st.items() if s in ("done", "succeeded", "completed"))
    done = max(done, len(res))
    run  = sum(1 for a, (s, n) in st.items() if s == "running")
    fail = sum(1 for a, (s, n) in st.items() if s in ("failed", "lost", "cancelled"))
    q    = tot - done - run - fail
    stamp = subprocess.run(["date", "+%H:%M"], capture_output=True, text=True).stdout.strip()

    h = ['<title>8&times;8 Scale-Up Campaign</title>',
         '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?'
         'family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans+Condensed:wght@600;700'
         '&family=IBM+Plex+Sans:wght@400;500&display=swap">',
         '<style>' + CSS + '</style>', '<div class="wrap">', '<header>',
         '<h1>8&times;8 Scale-Up Campaign</h1>',
         '<p class="sub">All 248 feasible GEMM shapes for the main-repo design '
         '(idea-2 + backpressure + bit-width fix) on the 1024-core, 64-group mesh. '
         'Measures whether the group-MSHR design holds as the mesh scales 4&times;.</p>',
         '<div class="meta"><span>1024 cores &middot; 64 groups</span>'
         '<span>VCS (35 largest) + Questa (213)</span>'
         '<span>' + str(done) + '/' + str(tot) + ' complete</span>'
         '<span>updated ' + stamp + '</span></div></header>']

    pc = lambda v: ("%.4f" % (100.0 * v / tot)) + "%"
    h += ['<section><h2>Progress</h2><div class="bar">',
          '<i class="d" style="width:' + pc(done) + '"></i>',
          '<i class="r" style="width:' + pc(run) + '"></i>',
          '<i class="f" style="width:' + pc(fail) + '"></i>',
          '<i class="q" style="width:' + pc(q) + '"></i></div>',
          '<div class="tiles" style="margin-top:14px">',
          '<div class="tile done"><span class="n">' + str(done) + '</span><span class="l">complete</span></div>',
          '<div class="tile run"><span class="n">' + str(run) + '</span><span class="l">running</span></div>',
          '<div class="tile wait"><span class="n">' + str(q) + '</span><span class="l">queued</span></div>',
          '<div class="tile bad"><span class="n">' + str(fail) + '</span><span class="l">failed</span></div>',
          '</div></section>']

    h += ['<div class="warn"><b>Dispatched speculatively &mdash; the pilot gate was not met.</b>',
          'No arm had completed when these launched. Read every result with these in mind:<ol>',
          '<li><b>fp32 arms carry no correctness signal at all.</b> All 150 fp16 apps compile the '
          '<code>[SPOT]</code> probe (one line per group, 64 expected); <b>0 of 122 fp32 apps do</b>, '
          'and fp32\'s only other check <code>MATMUL_VERIFY</code> is off because it wedges core 0. '
          'Roughly half this grid is <b>performance data only</b> &mdash; treat an fp32 cycle count '
          'as provisional unless an fp16 arm of comparable shape spotchecks clean.</li>',
          '<li><b>fp16 is verified on group 0 only.</b> The <code>[SPOT]</code> loop is written to '
          'cover all 64 groups but always emits one line &mdash; core 0 wedges on the second '
          'iteration reading group 1\'s remote C address. So the failure it was written to catch '
          '(one desynchronised group) is the one it cannot see. A run killed by <code>$fatal</code> '
          'still prints its cycle count, so the number can be real while everything after it is absent.</li>',
          '<li><b>L2 bandwidth per group halves at 8&times;8</b> (64 groups / 32 channels, against '
          '16/16 at 4&times;4), so a cross-mesh loss mixes mesh scaling with that halving.</li>',
          '<li>Record <b>RH per arm</b>: it gates whether backpressure can help a shape at all.</li>',
          '<li>The <b>M=128 family cannot run here</b> (<code>M % 512 == 0</code>), so the largest '
          '4&times;4 results are not portable without changing <code>KERNEL_SIZE</code>.</li>',
          '<li>213 concurrent sims share the fleet, so wall-clock per arm is contended; '
          'cycle counts are unaffected.</li></ol></div>']

    # ---- ladder ----
    h += ['<section><h2>A-share ladder</h2><p class="sub" style="margin-bottom:16px">'
          'Nine arms hold total work <code>M&middot;N&middot;P</code> roughly constant and vary '
          'only <b>M</b>, which alone sets how many cores share the same A rows &mdash; the degree '
          'the group MSHR can coalesce.</p>']
    byarm = {r[0] + "|" + r[1]: r for r in res}
    for deg, a16, a32 in LADDER:
        h += ['<div class="rung"><div class="deg"><span class="n">' + str(deg) +
              '</span><span class="u">-way</span></div><div class="arms">']
        for arm in (a16, a32):
            if arm is None:
                h += ['<div class="arm none"><div class="armhead"><span class="prec">fp32</span>'
                      '<span class="pill na">not possible</span></div>'
                      '<div class="why">C alone needs 20.3&nbsp;MiB &gt; 14.5 budget</div></div>']
                continue
            prec, shape = arm.split("_", 1)
            s, node = st.get(arm, ("queued", "-"))
            key = shape + "|" + prec
            r = byarm.get(key)
            if r:
                cls, lab, why = "ok", "done", (r[3] + " cyc &middot; RH " + r[4] +
                                               " &middot; spot " + esc(r[7]))
            elif s == "running":
                cls, lab, why = "run", "running", "on " + esc(node)
            elif s in ("failed", "lost", "cancelled"):
                cls, lab, why = "bad", esc(s), "on " + esc(node)
            else:
                cls, lab, why = "wait", "queued", "awaiting a slot"
            h += ['<div class="arm"><div class="armhead"><span class="prec">' + prec +
                  '</span><span class="pill ' + cls + '">' + lab + '</span></div>'
                  '<code class="shape">' + esc(shape) + '</code>'
                  '<div class="why">' + why + '</div></div>']
        h += ['</div></div>']
    h += ['</section>']

    # ---- assertion split: computed from the data, shown only once it can say something ----
    nf16 = sum(1 for r in res if r[1] == "fp16")
    na16 = sum(1 for r in res if r[1] == "fp16" and "FATAL" in r[7])
    nf32 = sum(1 for r in res if r[1] == "fp32")
    na32 = sum(1 for r in res if r[1] == "fp32" and "FATAL" in r[7])
    if nf16 and nf32:
        pair = [r[0] for r in res if r[1] == "fp16"] and \
               sorted(set(r[0] for r in res if r[1] == "fp16") &
                      set(r[0] for r in res if r[1] == "fp32"))
        h += ['<section><h2>RTL assertion: fp16 only</h2>',
              '<div class="tiles">',
              '<div class="tile bad"><span class="n">' + str(na16) + '/' + str(nf16) +
              '</span><span class="l">fp16 hit</span></div>',
              '<div class="tile done"><span class="n">' + str(na32) + '/' + str(nf32) +
              '</span><span class="l">fp32 hit</span></div></div>',
              '<p class="sub" style="margin-top:12px">Every completed fp16 arm dies at '
              '<code>mempool_group_mshr.sv:2258</code> &mdash; <code>MSHR clock gate dropped a '
              'resp_buf write</code>, a <code>$fatal</code>. No fp32 arm does.']
        if pair:
            h += ['<b>Same shape, both precisions:</b> <code>' + esc(pair[0]) + '</code> fp16 dies, '
                  'fp32 finishes clean &mdash; which isolates it to precision, not shape or simulator. '
                  'fp16 packs two elements per 32-bit word, so the response path sees sub-word '
                  '<code>resp_buf</code> writes that fp32 never generates.']
        h += [' The benchmark completes <i>before</i> the assertion, so cycle counts survive; the '
              'spotcheck does not.</p></section>']

    # ---- results ----
    h += ['<section><h2>Results</h2>']
    if not res:
        h += ['<div class="empty">No arm has completed yet. At the measured ~19 cyc/s (VCS) and '
              '~12 cyc/s (Questa), the first completions are hours out.<br>'
              'This table fills automatically as transcripts are delivered.</div>']
    else:
        h += ['<div class="tw"><table><tr><th>shape</th><th>prec</th><th>A-share</th>'
              '<th>cycles</th><th>RH</th><th>mshr&nbsp;timeout</th><th>bankfull</th>'
              '<th>spotcheck</th></tr>']
        for r in res:
            bad = "ok(" not in r[7]
            h += ['<tr><td><code>' + esc(r[0]) + '</code></td><td>' + esc(r[1]) +
                  '</td><td class="num">' + esc(r[2]) + '</td><td class="num">' +
                  "{:,}".format(int(r[3])) + '</td><td class="num">' + esc(r[4]) +
                  '</td><td class="num">' + esc(r[5]) + '</td><td class="num">' + esc(r[6]) +
                  '</td><td>' + ('<span class="pill bad">' + esc(r[7]) + '</span>'
                                 if bad else esc(r[7])) + '</td></tr>']
        h += ['</table></div>']
    h += ['</section>']

    h += ['<section><h2>Measured, not estimated</h2><div class="tw"><table>'
          '<tr><th>quantity</th><th>planned</th><th>measured</th></tr>'
          '<tr><td>VCS peak RSS</td><td class="num">~7-9 GiB</td><td class="num">7.80 GiB</td></tr>'
          '<tr><td>VCS throughput</td><td class="num">~13 cyc/s</td><td class="num">19.4 cyc/s</td></tr>'
          '<tr><td>Questa peak RSS</td><td class="num">~60 GiB</td><td class="num">16.4 GiB</td></tr>'
          '<tr><td>Questa throughput</td><td class="num">&mdash;</td><td class="num">12.2 cyc/s</td></tr>'
          '<tr><td>FPU efficiency</td><td class="num">45% of peak</td><td class="num">~15%</td></tr>'
          '<tr><td>fleet free memory</td><td class="num">assumed tight</td>'
          '<td class="num">7879 GB (63 nodes)</td></tr>'
          '</table></div><p class="sub" style="margin-top:12px">VCS and Questa produce identical '
          'state at 8&times;8 (<code>util=14.92%</code>, <code>RH=0</code>, <code>CMS=4037</code> '
          'on one ELF), extending the validated-identical result from 4&times;4, so the two '
          'simulators\' arms pool into one dataset.</p></section>']
    h += ['</div>']
    open(OUT, "w").write("\n".join(h))
    print("  wrote %s  (%d done, %d running, %d queued, %d failed)" % (OUT, done, run, q, fail))

main()
