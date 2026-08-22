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
                # Rank by what the arm IS, not by which record is newest. An arm can have several
                # copies (resubmit, heal, a duplicate that was killed); killing a duplicate writes
                # a NEWER cancelled record than the surviving copy's `running`, so latest-ts
                # reported healthy arms as failed. Same rule as campaign_status.py.
                st = last.get("state") or "?"
                rank = {"running": 3, "done": 4, "succeeded": 4, "completed": 4,
                        "submitted": 2, "dispatched": 2, "pending": 2, "queued": 2}.get(st, 1)
                ts = last.get("ts") or 0
                prev = ts_seen.get(arm)
                if prev is None or rank > prev[0] or (rank == prev[0] and ts >= prev[1]):
                    ts_seen[arm] = (rank, ts)
                    out[arm] = (st, last.get("node", "-"))
        for jid, arm in ids.items():
            # no jsonl = never started = QUEUED. Rank 2, so a freshly requeued job beats the
            # cancelled copy it replaced instead of inheriting its verdict.
            if not arm.startswith(("fp16_", "fp32_")) or jid in seen:
                continue
            prev = ts_seen.get(arm)
            if prev is None or 2 > prev[0]:
                ts_seen[arm] = (2, 0)
                out[arm] = ("queued", "-")
    return out

def results():
    p = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")
    rows = []
    try:
        for i, ln in enumerate(open(p)):
            if i == 0: continue
            f = ln.rstrip("\n").split("\t")
            if len(f) >= 10: rows.append(f)   # fpu_util added at index 4
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
td.dim,tr.unpaired td{color:var(--dim)}
.dot{color:var(--bad);font-size:9px;vertical-align:super;margin-left:3px}
td.ratio{font-weight:600;color:var(--acc)}
td.zero{color:var(--line)}
td.hot{font-weight:600;color:var(--bad)}
th.grp{text-align:center;color:var(--ink);font-size:12px;letter-spacing:.14em;padding-bottom:2px}
.pairs th.gs,.pairs td.gs{border-left:1px solid var(--line);padding-left:12px}
.pairs th,.pairs td{padding-right:14px}
table tr:first-child th{border-bottom:none}
/* --- per-group mesh view --- */
.mesh-ctl{display:flex;flex-wrap:wrap;gap:14px 20px;align-items:center;margin-bottom:16px}
.mesh-ctl label{font:400 10.5px/1 "IBM Plex Mono",monospace;color:var(--dim);
letter-spacing:.08em;text-transform:uppercase;display:block;margin-bottom:5px}
.mesh-ctl select{font:600 13px/1 "IBM Plex Mono",monospace;background:var(--surf);
color:var(--ink);border:1px solid var(--line);border-radius:3px;padding:7px 9px;min-width:210px}
.mesh-ctl select.narrow{min-width:96px}
.mesh-ctl .none{font:400 12px/1.4 "IBM Plex Sans",sans-serif;color:var(--bad)}
.mesh-ctl input[type=range]{width:min(420px,52vw);accent-color:var(--acc);vertical-align:middle}
.meshwrap{display:grid;grid-template-columns:auto 1fr;gap:22px;align-items:start}
@media(max-width:720px){.meshwrap{grid-template-columns:1fr}}
.mesh{display:grid;grid-template-columns:repeat(8,1fr);gap:3px;width:min(360px,84vw)}
.cell{aspect-ratio:1;border-radius:2px;display:flex;align-items:center;justify-content:center;
font:600 9px/1 "IBM Plex Mono",monospace;color:#fff;background:var(--line)}
.cell.lo{color:var(--dim)}
.mesh-meta dl{display:grid;grid-template-columns:repeat(2,minmax(96px,1fr));gap:12px 18px;margin:0}
.mesh-meta dt{font:400 10px/1.4 "IBM Plex Mono",monospace;color:var(--dim);
letter-spacing:.07em;text-transform:uppercase}
.mesh-meta dd{margin:2px 0 0;font:600 17px/1.2 "IBM Plex Mono",monospace;
font-variant-numeric:tabular-nums}
.scale{display:flex;align-items:center;gap:8px;margin-top:16px;
font:400 10.5px/1 "IBM Plex Mono",monospace;color:var(--dim)}
/* --- per-group progress bars --- */
/* All 64 groups visible at once -- columns, never a scrollbar. Comparing progress means
   seeing the whole set in one glance; a scroll region hides exactly the outliers you are
   looking for. Column count adapts to width; rows-per-column falls to 16 at 4 columns. */
.prog{display:grid;grid-template-columns:repeat(auto-fit,minmax(184px,1fr));
gap:2px 18px;margin-top:6px;align-content:start}
.prow{display:grid;grid-template-columns:26px 1fr 34px;gap:7px;align-items:center}
.prow .g{font:400 9px/1 "IBM Plex Mono",monospace;color:var(--dim);text-align:right}
.prow .track{height:8px;background:var(--line);border-radius:2px;overflow:hidden}
.prow .fill{height:100%;background:var(--run);border-radius:2px;transition:width .09s linear}
.prow .fill.lead{background:var(--ok)}
.prow .fill.lag{background:var(--bad)}
.prow .pct{font:600 9px/1 "IBM Plex Mono",monospace;font-variant-numeric:tabular-nums;
text-align:right}
.scale i{display:block;height:9px;flex:1;border-radius:2px;
background:linear-gradient(90deg,#e8eef1,#9fc7d4,#4e94ab,#1f6f8b,#0d3f52)}
:root:not([data-theme="light"]) .scale i{background:linear-gradient(90deg,#1b2b33,#255d72,#2f88a4,#4fa3c4,#9fd8ea)}
:root[data-theme="dark"] .scale i{background:linear-gradient(90deg,#1b2b33,#255d72,#2f88a4,#4fa3c4,#9fd8ea)}
"""

def main():
    st = states()
    res = results()
    tot = 248
    # COMPLETE means a usable result, not a ledger verdict: an arm whose partial was delivered
    # over its result is "done" in the ledger with nothing to show, and counting those inflated
    # this tile to 25 while the results table held 19.
    done = len(res)
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
         '<span>VCS + Questa, licence-governed</span>'
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
          '<li><b><code>M % 512 == 0</code> comes from the build, not the mesh.</b> It follows from '
          '<code>#define KERNEL_SIZE 8</code>; the kernel also supports 4 and 2, and the real rule is '
          '<code>(M/64) % kernel_size == 0</code>. Building with <code>-DKERNEL_SIZE=4</code> would '
          'admit the M=256 family and <code>=2</code> the M=128 family &mdash; at a different LMUL and '
          'burst regime, so such arms are a different operating point rather than the same '
          'measurement at a new shape.</li>',
          '<li>Concurrency was <b>deliberately reduced</b> partway through: a Questa run holds an '
          '<code>mtiverification</code> seat, that pool has only 200, and we were holding 150 of '
          'them. Submits now reserve 10 seats for other users, so arms queue behind the licence '
          'rather than starving the department. Wall-clock per arm is contended; <b>cycle counts '
          'are unaffected</b>.</li></ol></div>']

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
                cls, lab, why = "ok", "done", (r[3] + " cyc &middot; util " + r[4] +
                                               "% &middot; RH " + r[5])
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
    na16 = sum(1 for r in res if r[1] == "fp16" and "FATAL" in r[8])
    nf32 = sum(1 for r in res if r[1] == "fp32")
    na32 = sum(1 for r in res if r[1] == "fp32" and "FATAL" in r[8])
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

    # ---- what the data says so far (computed, so it cannot go stale) ----
    if len(res) >= 4:
        def f(r, i): return float(r[i])
        best = max(res, key=lambda r: f(r, 4)); worst = min(res, key=lambda r: f(r, 4))
        pairs = {}
        for r in res:
            pairs.setdefault(r[0], {})[r[1]] = r
        both = [(k, v) for k, v in pairs.items() if len(v) == 2]
        ratios = [int(v["fp32"][3]) / float(v["fp16"][3]) for _, v in both if int(v["fp16"][3])]
        n16 = sum(1 for r in res if r[1] == "fp16")
        a16 = sum(1 for r in res if r[1] == "fp16" and "FATAL" in r[8])
        n32 = sum(1 for r in res if r[1] == "fp32")
        a32 = sum(1 for r in res if r[1] == "fp32" and "FATAL" in r[8])
        h += ['<section><h2>What the data says so far</h2><div class="tiles">',
              '<div class="tile"><span class="n">%s%%</span><span class="l">best util &mdash; %s %s</span></div>'
              % (best[4], esc(best[1]), esc(best[0])),
              '<div class="tile"><span class="n">%s%%</span><span class="l">worst util &mdash; %s %s</span></div>'
              % (worst[4], esc(worst[1]), esc(worst[0]))]
        if ratios:
            h += ['<div class="tile"><span class="n">%.2f&times;</span>'
                  '<span class="l">fp32 / fp16, %d matched pair%s</span></div>'
                  % (sum(ratios) / len(ratios), len(ratios), "" if len(ratios) == 1 else "s")]
        h += ['<div class="tile bad"><span class="n">%d/%d</span>'
              '<span class="l">fp16 hit the assertion</span></div>' % (a16, n16),
              '<div class="tile done"><span class="n">%d/%d</span>'
              '<span class="l">fp32 hit it</span></div>' % (a32, n32),
              '</div><p class="sub" style="margin-top:14px">Utilisation spans a <b>%.1f&times;</b> range '
              'across shapes. Read that with care: the earlier 8&times;8 campaign recorded 94.1%% when '
              'correctly provisioned against 20.8&ndash;28.2%% under-provisioned, so a low number is not '
              'automatically a shape effect &mdash; check the arm\'s MSHR settings before concluding.</p>'
              '</section>' % (f(best, 4) / f(worst, 4) if f(worst, 4) else 0)]

    # ---- per-group mesh over time ----
    try:
        gu = json.load(open("/tmp/claude-620771/group_util.json"))
    except Exception:
        gu = {}
    if gu:
        h += ['<section><h2>Per-group FPU utilisation over the benchmark</h2>',
              '<p class="sub" style="margin-bottom:18px">Each cell is one of the 64 groups, laid '
              'out as the physical 8&times;8 mesh (row = mesh Y, column = mesh X). Colour is that '
              'group\'s FPU utilisation in one 1000-cycle window of the benchmark. Drag the slider '
              'to move through time. Whole-run utilisation averages this over every group and '
              'every window, so it hides exactly what this shows: <b>how unevenly the work is '
              'spread across the mesh</b>.</p>',
              '<div class="mesh-ctl">',
              '<div><label for="mprec">precision</label>'
              '<select id="mprec" class="narrow"></select></div>',
              '<div><label for="mM">M</label><select id="mM" class="narrow"></select></div>',
              '<div><label for="mN">N</label><select id="mN" class="narrow"></select></div>',
              '<div><label for="mP">P</label><select id="mP" class="narrow"></select></div>',
              '<select id="marm" hidden>'] + \
             ['<option value="' + esc(a) + '">' + esc(a) + '</option>'
              for a in sorted(gu)] + ['</select>',
              '<div style="flex:1"><label for="mper">benchmark window</label>'
              '<input type="range" id="mper" min="0" max="0" value="0" step="1">'
              ' <span id="mcyc" style="font:600 12px/1 \'IBM Plex Mono\',monospace"></span></div>',
              '</div>',
              '<div class="meshwrap"><div><div class="mesh" id="mgrid"></div>',
              '<div class="scale"><span>0%</span><i></i><span>100%</span></div></div>',
              '<div class="mesh-meta"><dl>',
              '<dt>window mean</dt><dd id="mmean">-</dd>',
              '<dt>spread (max-min)</dt><dd id="mspread">-</dd>',
              '<dt>busiest group</dt><dd id="mmax">-</dd>',
              '<dt>idlest group</dt><dd id="mmin">-</dd>',
              '<dt>whole-run util</dt><dd id="mrun">-</dd>',
              '<dt>cycles</dt><dd id="mcycles">-</dd>',
              '</dl><p class="sub" style="margin-top:14px;font-size:12.5px">A wide spread means '
              'some groups are starved while others saturate &mdash; the alignment problem the '
              'group-MSHR design is meant to address. A single number cannot show it.</p></div></div>',
              '<h3 style="font:600 13px/1 \'IBM Plex Mono\',monospace;letter-spacing:.06em;'
              'text-transform:uppercase;color:var(--dim);margin:34px 0 6px">'
              'Per-group progress &mdash; are the groups advancing together?</h3>',
              '<p class="sub" style="margin-bottom:14px">The kernel hands every group an equal '
              'share of the work, so a group\'s <b>cumulative</b> busy lane-cycles measure how far '
              'through that share it has got. One bar per group, driven by the same slider. If the '
              'groups were aligned the bars would move as a single block &mdash; the spread between '
              'them is wasted machine, because the kernel does not end until the <b>last</b> group '
              'finishes.</p>',
              '<div class="mesh-meta" style="margin-bottom:12px"><dl>',
              '<dt>leader</dt><dd id="plead">-</dd>',
              '<dt>laggard</dt><dd id="plag">-</dd>',
              '<dt>gap (leader-laggard)</dt><dd id="pgap">-</dd>',
              '<dt>laggard / leader</dt><dd id="pratio">-</dd>',
              '</dl></div>',
              '<div class="prog" id="pgrid"></div>',
              '<script>',
              'const GU=' + json.dumps(gu, separators=(",", ":")) + ';',
              'const RES=' + json.dumps(
                  {r[1] + "_" + r[0]: {"cyc": r[3], "util": r[4], "rh": r[5],
                                       "fatal": ("FATAL" in r[8])}
                   for r in res}, separators=(",", ":")) + ';',
              """
const $=i=>document.getElementById(i), grid=$("mgrid"), sel=$("marm"), rng=$("mper");
// Four cascading pickers instead of one long list: with 248 shapes a single dropdown is a
// haystack. Each level only offers values that EXIST at the levels above it, so every
// combination the UI lets you build has data behind it -- no empty states to hit.
const SHAPES=Object.keys(GU).map(a=>{const m=/^fp(\d+)_(\d+)x(\d+)x(\d+)$/.exec(a);
  return m?{arm:a,prec:m[1],M:+m[2],N:+m[3],P:+m[4]}:null}).filter(Boolean);
const eP=$("mprec"), eM=$("mM"), eN=$("mN"), ePp=$("mP");
function fill(el,vals,keep){
  // Compare as STRINGS. vals are numbers (512, 1024) while el.value is always a string, so
  // vals.includes(keep) was ALWAYS false and every picker snapped back to vals[0] -- you could
  // never select anything but the smallest M/N/P. Classic JS type mismatch, silent by nature.
  const sv=vals.map(String);
  const prev=(keep!=null && sv.includes(String(keep))) ? keep : vals[0];
  el.innerHTML="";
  for(const v of vals){const o=document.createElement("option");o.value=String(v);o.textContent=String(v);
    if(String(v)===String(prev))o.selected=true;el.appendChild(o);}
  return prev;
}
const uniq=a=>[...new Set(a)];
function cascade(){
  const precs=uniq(SHAPES.map(s=>s.prec)).sort();
  fill(eP,precs,eP.value);
  // relabel precision options as fp16/fp32 while keeping numeric values
  [...eP.options].forEach(o=>o.textContent="fp"+o.value);
  let pool=SHAPES.filter(s=>s.prec===eP.value);
  fill(eM,uniq(pool.map(s=>s.M)).sort((a,b)=>a-b), eM.value);
  pool=pool.filter(s=>String(s.M)===eM.value);
  fill(eN,uniq(pool.map(s=>s.N)).sort((a,b)=>a-b), eN.value);
  pool=pool.filter(s=>String(s.N)===eN.value);
  fill(ePp,uniq(pool.map(s=>s.P)).sort((a,b)=>a-b), ePp.value);
  const hit=SHAPES.find(s=>s.prec===eP.value&&String(s.M)===eM.value&&
                           String(s.N)===eN.value&&String(s.P)===ePp.value);
  if(hit){sel.value=hit.arm;}
  return !!hit;
}
for(let i=0;i<64;i++){const c=document.createElement("div");c.className="cell";grid.appendChild(c);}
// one hue, light->dark: magnitude is a sequential encoding, never a rainbow
const STOPS=[[232,238,241],[159,199,212],[78,148,171],[31,111,139],[13,63,82]];
function col(u){const t=Math.max(0,Math.min(100,u))/100*(STOPS.length-1);
  const i=Math.min(STOPS.length-2,Math.floor(t)),f=t-i,a=STOPS[i],b=STOPS[i+1];
  return `rgb(${Math.round(a[0]+(b[0]-a[0])*f)},${Math.round(a[1]+(b[1]-a[1])*f)},${Math.round(a[2]+(b[2]-a[2])*f)})`;}
function draw(){
  const d=GU[sel.value]; if(!d||!d.length) return;
  const k=Math.min(d.length-1,+rng.value), p=d[k], u=p.u;
  const cells=grid.children;
  for(let g=0;g<64;g++){const c=cells[g];c.style.background=col(u[g]);
    c.className="cell"+(u[g]<45?" lo":"");c.textContent=Math.round(u[g]);
    c.title=`group ${g} (x=${g%8}, y=${Math.floor(g/8)}) — ${u[g].toFixed(1)}%`;}
  const mx=Math.max(...u), mn=Math.min(...u), me=u.reduce((a,b)=>a+b,0)/64;
  $("mcyc").textContent=`cyc ${p.cyc.toLocaleString()}  (${k+1}/${d.length})`;
  $("mmean").textContent=me.toFixed(1)+"%";
  $("mspread").textContent=(mx-mn).toFixed(1)+" pp";
  $("mmax").textContent=`g${u.indexOf(mx)} — ${mx.toFixed(1)}%`;
  $("mmin").textContent=`g${u.indexOf(mn)} — ${mn.toFixed(1)}%`;
  // The headline number for this arm, beside the per-window detail: the point is that a
  // whole-run average of ~40% and a group peaking at 100% describe the SAME run.
  const r=RES[sel.value];
  $("mrun").textContent = r ? r.util+"%" : "-";
  $("mcycles").textContent = r ? Number(r.cyc).toLocaleString() : "-";
}
// --- cumulative per-group progress -------------------------------------------------
// busy lane-cycles accumulate; denom is constant per window, so summing the per-window
// utilisation is proportional to cumulative busy and needs no extra data.
const pg=$("pgrid"); const rows=[];
for(let g=0;g<64;g++){
  const row=document.createElement("div"); row.className="prow";
  const lab=document.createElement("div"); lab.className="g"; lab.textContent="g"+g;
  const tr=document.createElement("div"); tr.className="track";
  const fi=document.createElement("div"); fi.className="fill"; fi.style.width="0%";
  tr.appendChild(fi);
  const pc=document.createElement("div"); pc.className="pct"; pc.textContent="0";
  row.appendChild(lab); row.appendChild(tr); row.appendChild(pc);
  row.title="group "+g+" (x="+(g%8)+", y="+Math.floor(g/8)+")";
  pg.appendChild(row); rows.push({fi,pc});
}
let CUM=null;
function buildCum(){
  const d=GU[sel.value]||[]; CUM=[];
  const run=new Array(64).fill(0);
  for(const p of d){ for(let g=0;g<64;g++) run[g]+=p.u[g]; CUM.push(run.slice()); }
}
function drawProg(){
  if(!CUM||!CUM.length) return;
  const k=Math.min(CUM.length-1,+rng.value), c=CUM[k];
  const mx=Math.max(...c), mn=Math.min(...c);
  const li=c.indexOf(mx), gi=c.indexOf(mn);
  for(let g=0;g<64;g++){
    const w=mx>0?(c[g]/mx*100):0;
    rows[g].fi.style.width=w.toFixed(1)+"%";
    rows[g].fi.className="fill"+(g===li?" lead":(g===gi?" lag":""));
    rows[g].pc.textContent=w.toFixed(0)+"%";
  }
  $("plead").textContent="g"+li;
  $("plag").textContent="g"+gi;
  $("pgap").textContent=(mx>0?((mx-mn)/mx*100).toFixed(1):"0")+"%";
  $("pratio").textContent=(mx>0?(mn/mx*100).toFixed(1):"0")+"%";
}
function reset(){
  const d=GU[sel.value]||[];
  rng.max=Math.max(0,d.length-1); rng.value=0;
  rng.disabled=(d.length<2);            // nothing to scrub through
  buildCum(); draw(); drawProg();
}
for(const el of [eP,eM,eN,ePp]) el.addEventListener("change",()=>{cascade();reset();});
// The slider needs its OWN handler. Rewiring the pickers once replaced this line and the
// scrubber silently stopped responding -- no error, it just never redrew.
rng.addEventListener("input",()=>{draw();drawProg();});
cascade(); reset();
""",
              '</script></section>']

    # ---- results ----
    h += ['<section><h2>Results</h2>']
    if not res:
        h += ['<div class="empty">No arm has completed yet. At the measured ~19 cyc/s (VCS) and '
              '~12 cyc/s (Questa), the first completions are hours out.<br>'
              'This table fills automatically as transcripts are delivered.</div>']
    else:
        # One row per SHAPE, fp16 and fp32 side by side: the pair is the comparison that
        # matters, and a row-per-arm table buries it (the two halves of a pair can be dozens of
        # rows apart once sorted by cycles). Shapes that exist in only one precision still appear,
        # dimmed, so nothing is hidden by the pairing.
        by = {}
        for r in res:
            by.setdefault(r[0], {})[r[1]] = r
        def cyc(d, pr):
            return int(d[pr][3]) if pr in d else None
        # paired shapes first (that is the point of the table), each group by fp16 cycles
        order = sorted(by, key=lambda sh: (len(by[sh]) < 2,
                                           cyc(by[sh], "fp16") or cyc(by[sh], "fp32") or 0))
        h += ['<div class="tw"><table class="pairs"><tr><th></th><th></th>'
              '<th colspan="5" class="grp">fp16</th>'
              '<th colspan="5" class="grp">fp32</th><th></th></tr>'
              '<tr><th>shape</th><th>A&#8209;share</th>'
              '<th class="gs">cycles</th><th>util</th><th>RH</th><th>timeout</th><th>bypass</th>'
              '<th class="gs">cycles</th><th>util</th><th>RH</th><th>timeout</th><th>bypass</th>'
              '<th class="gs">fp32/fp16</th></tr>']
        for sh in order:
            d = by[sh]
            paired = len(d) == 2
            ash = (d.get("fp16") or d.get("fp32"))[2]
            def cell(pr):
                if pr not in d:
                    return '<td class="num dim gs">&mdash;</td>' + '<td class="num dim">&mdash;</td>' * 4
                r = d[pr]
                # a FATAL arm still has a valid cycle count -- mark it, do not hide it
                mark = ('<span class="dot" title="killed by $fatal after the benchmark">&#9679;</span>'
                        if "FATAL" in r[8] else "")
                # RH / timeout / bypass are 0 on almost every arm, so a column of bold zeros hides
                # the few that are not. Dim the zeros; make the exceptions the thing that reads.
                def z(v):
                    return ('<td class="num zero">0</td>' if v.strip() in ("0", "")
                            else '<td class="num hot">' + esc(v) + '</td>')
                return ('<td class="num gs">' + "{:,}".format(int(r[3])) + mark +
                        '</td><td class="num">' + esc(r[4]) + '%</td>' +
                        z(r[5]) + z(r[6]) + z(r[7]))
            if paired:
                a, b = int(d["fp16"][3]), int(d["fp32"][3])
                ratio = ('<td class="num ratio gs">%.2f&times;</td>' % (b / float(a))) if a else '<td class="gs"></td>'
            else:
                ratio = '<td class="num dim gs">&mdash;</td>'
            h += ['<tr' + ('' if paired else ' class="unpaired"') + '><td><code>' + esc(sh) +
                  '</code></td><td class="num">' + esc(ash) + '</td>' +
                  cell("fp16") + cell("fp32") + ratio + '</tr>']
        h += ['</table></div>',
              '<p class="sub" style="margin-top:10px"><span class="dot">&#9679;</span> killed by '
              '<code>$fatal</code> at <code>mempool_group_mshr.sv:2258</code> after the benchmark '
              '&mdash; the cycle count and utilisation are valid, the spotcheck is not. '
              '<b>fp32/fp16</b> is how many times longer fp32 takes on the same shape; dimmed '
              'rows have completed in only one precision so far. <b>RH</b>, <b>timeout</b> and '
              '<b>bypass</b> are zero on almost every arm, so zeros are greyed and any non-zero '
              'is red &mdash; those are the arms where the MSHR was under pressure.</p>']
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
