#!/usr/bin/env python3
"""Generate the 8x8 scale-up campaign dashboard HTML from live fleet state + results.tsv.

Writes /tmp/claude-620771/s8_ladder.html (the path the published artifact is redeployed from --
keep it, a new path would claim a new URL and orphan the existing link).
"""
import glob, html, json, os, re, subprocess, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = "/tmp/claude-620771/s8_ladder.html"
STATE = os.path.expanduser("~/badist/state")

LADDER = [(16, "fp16_512x2048x1024", "fp32_512x1024x1024"),
          (8,  "fp16_1024x2048x512", "fp32_1024x1024x512"),
          (4,  "fp16_2048x1024x512", "fp32_2048x512x512"),
          (2,  "fp16_4096x512x512",  "fp32_4096x256x512"),
          (1,  "fp16_8192x256x512",  None)]

_DELIVERED_CACHE = None


def _delivered(arm):
    """True if this arm has a durable row in results.tsv (merge-only, outlives the transcript)."""
    global _DELIVERED_CACHE
    if _DELIVERED_CACHE is None:
        _DELIVERED_CACHE = set()
        try:
            with open(os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")) as fh:
                for ln in fh.read().splitlines()[1:]:
                    p_ = ln.split("\t")
                    if len(p_) > 3 and p_[3].strip().isdigit():
                        _DELIVERED_CACHE.add(p_[1] + "_" + p_[0])
        except OSError:
            pass
    return arm in _DELIVERED_CACHE


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
                # A `done` record with NOTHING DELIVERED is not done -- badist records the state it was
                # told, and a job can end "done" having produced no transcript. Left at rank 4 it outranks
                # the arm's live `running` copy, so the arm reads finished while it is still executing:
                # 29 arms were counted that way here, which is why this page said 118 running / 45 queued
                # against the true 147 / 16. campaign_status.py was fixed for this; the dashboard was not.
                if rank == 4 and not _delivered(arm):
                    rank = 1
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

LIVELOCKED = []          # recorded failures, kept out of the analysis set but reported

def results():
    """Delivered MEASUREMENTS only.

    Rows with state 'livelock' are recorded FAILURES, not results: the arm never completed, and
    its ~0.05-4% utilisation measures the mshr_cfg.h cohort-target bug rather than the
    architecture (docs/benchmarks/8x8_scaleup/rh_livelock_root_cause.md). Feeding them to the
    charts would add 22 spurious near-zero points to every utilisation scatter and drag the
    fp32/fp16 ratio, while looking like legitimate evidence that 8x8 scales badly. Count them,
    show them separately, never average them in.
    """
    p = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")
    rows = []
    del LIVELOCKED[:]
    try:
        for i, ln in enumerate(open(p)):
            if i == 0: continue
            f = ln.rstrip("\n").split("\t")
            if len(f) < 10:
                continue                      # fpu_util added at index 4
            if f[9] == "livelock":
                LIVELOCKED.append(f)
                continue
            rows.append(f)
    except Exception:
        pass
    return rows

def ratio_chart(pairs):
    """Scatter of fp32/fp16 cycle ratio against P, with the 2x arithmetic ceiling drawn in.

    The findings panel already reports a median and a range, but the open question is whether the
    fp16 advantage tracks a shape parameter -- and ten numbers in a table do not answer that.

    The ceiling is the interpretive line: fp16 does ~2 MACs per lane-cycle against fp32's ~1, so 2x
    is the compute-bound limit. A point ABOVE it cannot be explained by arithmetic, which implies
    fp32 is losing on traffic (it moves twice the bytes for the same shape).

    Deliberately plain: one y-axis, marks carry a single encoding (filled = above the ceiling), and
    only the extremes are labelled -- a label on every point turns ten marks into noise.
    """
    pts = []
    for shape, ratio, sick16, sick32 in pairs:
        m = re.match(r"^(\d+)x(\d+)x(\d+)$", shape)
        if not m:
            continue
        M, N, P = (int(x) for x in m.groups())
        pts.append((shape, M, N, P, ratio, sick16, sick32))
    if len(pts) < 4:
        return ""
    W, H, L, R, T, B = 620, 250, 46, 16, 18, 40
    xs = sorted({p[3] for p in pts})
    ymax = max(3.6, max(p[4] for p in pts) * 1.12)

    def px(P):
        return L + (xs.index(P) / max(len(xs) - 1, 1)) * (W - L - R)

    def py(r):
        return T + (1 - (r - 1.0) / (ymax - 1.0)) * (H - T - B)

    o = ['<div class="tw"><svg viewBox="0 0 %d %d" width="100%%" height="%d" style="max-width:%dpx" '
         'role="img" aria-label="fp32 over fp16 cycle ratio against P">' % (W, H, H, W)]
    for gy in (1.0, 1.5, 2.0, 2.5, 3.0, 3.5):
        if gy > ymax:
            continue
        y = py(gy)
        o.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="var(--line)" stroke-width="1"/>'
                 % (L, y, W - R, y))
        o.append('<text x="%d" y="%.1f" fill="var(--dim)" font-size="10" text-anchor="end" '
                 'font-family="IBM Plex Mono,monospace">%.1f&#215;</text>' % (L - 6, y + 3, gy))
    yc = py(2.0)
    o.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="var(--bad)" stroke-width="2" '
             'stroke-dasharray="5 4"/>' % (L, yc, W - R, yc))
    o.append('<text x="%d" y="%.1f" fill="var(--bad)" font-size="10.5" '
             'font-family="IBM Plex Mono,monospace">2&#215; arithmetic ceiling &#8212; above this, '
             'fp32 loses on traffic, not MACs</text>' % (L + 6, yc - 7))
    for P in xs:
        o.append('<text x="%.1f" y="%d" fill="var(--dim)" font-size="10.5" text-anchor="middle" '
                 'font-family="IBM Plex Mono,monospace">P=%d</text>' % (px(P), H - 14, P))
    clean = [p for p in pts if p[5] == 0 and p[6] == 0]
    hi = max(clean, key=lambda p: p[4]) if clean else None
    lo = min(clean, key=lambda p: p[4]) if clean else None
    for shape, M, N, P, r, s16, s32 in sorted(pts, key=lambda p: p[4]):
        x, y = px(P), py(r)
        ok = (s16 == 0 and s32 == 0)
        if ok:
            note = "clean"
            o.append('<circle cx="%.1f" cy="%.1f" r="5.5" fill="var(--acc)" stroke="var(--acc)" '
                     'stroke-width="2"><title>%s   M=%d N=%d P=%d   %.2fx   %s</title></circle>'
                     % (x, y, shape, M, N, P, r, note))
        else:
            # hollow + muted: the arm ran sick, so this ratio measures MSHR degradation.
            note = ("fp32 sicker (RH+timeout %d vs %d) -- ratio OVERstated" % (s32, s16)) if s32 > s16 \
                   else ("fp16 sicker (RH+timeout %d vs %d) -- ratio UNDERstated" % (s16, s32))
            o.append('<circle cx="%.1f" cy="%.1f" r="4.5" fill="none" stroke="var(--dim)" '
                     'stroke-width="1.5" stroke-dasharray="2 2">'
                     '<title>%s   M=%d N=%d P=%d   %.2fx   %s</title></circle>'
                     % (x, y, shape, M, N, P, r, note))
        if hi and shape in (hi[0], lo[0]):
            o.append('<text x="%.1f" y="%.1f" fill="var(--ink)" font-size="10.5" text-anchor="middle" '
                     'font-family="IBM Plex Mono,monospace">%s</text>' % (x, y - 11, shape))
    o.append('</svg></div>')
    return "".join(o)


def data_mib(shape, prec):
    """A + B + C working set in MiB. This is the number that had to fit the 14.50 MiB L1 budget,
    and it explains an arm's behaviour better than M/N/P read separately."""
    try:
        M, N, P = (int(x) for x in shape.split("x"))
    except Exception:
        return None
    b = 2 if prec == "fp16" else 4
    return (M * N + N * P + M * P) * b / float(1 << 20)


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
td.recon{color:var(--muted);font-style:italic}
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
    # A DELIVERED arm is done, whatever its ledger says. An arm that was salvaged and then killed
    # ends with a `cancelled` record while its measurement sits safely in results.tsv, and an arm
    # that delivered can still hold a stale `queued` copy in some retired batch. Counting the ledger
    # alone reported 3 failed and 41 queued when the true figures were 0 and 16 -- every one of the
    # "failed" three (fp16_4096x128x128, fp16_4096x64x256, fp16_8192x64x128) had a result.
    # campaign_status.py was fixed for exactly this; the dashboard was not.
    _have = {r[1] + "_" + r[0] for r in res}
    run  = sum(1 for a, (s, n) in st.items() if s == "running" and a not in _have)
    fail = sum(1 for a, (s, n) in st.items()
               if s in ("failed", "lost", "cancelled") and a not in _have)
    # QUEUED is a RESIDUAL, so every arm accounted for elsewhere must be subtracted or it lands
    # here. When results() began excluding livelock rows (so they stay out of the charts), `done`
    # dropped by 26 and all 26 reappeared as "queued" -- the page claimed 25 arms were waiting for
    # a seat while campaign_status.py correctly reported 0 pending. They have their own tile; count
    # them once. Clamp at 0: an arm can hold both a result and a live retry, so the parts can
    # briefly exceed the total.
    live_n = len({f[1] + "_" + f[0] for f in LIVELOCKED} - _have)
    q    = max(0, tot - done - live_n - run - fail)
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
          # Recorded failures get their OWN tile rather than being folded into "complete" (which
          # would overstate progress and put 0.05-4% points into every chart) or into "failed"
          # (which is a dispatch verdict, not a result). See rh_livelock_root_cause.md.
          ('<div class="tile bad"><span class="n">' + str(len(LIVELOCKED)) +
           '</span><span class="l">livelock</span></div>') if LIVELOCKED else '',
          '</div></section>',
          ('<section class="card"><h2>' + str(len(LIVELOCKED)) + ' arms excluded as LIVELOCK</h2>'
           '<p class="sub">These ran at <b>0.05&ndash;4% FPU utilisation</b> and never completed. '
           'They measure a <b>software</b> defect, not the architecture: the scalar-load cohort '
           'target in <code>software/runtime/mshr_cfg.h</code> is derived from <code>M</code> '
           'alone and ignores <code>P</code>, so every remote scalar load rides out '
           '<code>serve_timeout=2047</code> waiting for a cohort that cannot assemble in time. '
           'They are kept out of every chart and every average on this page &mdash; including them '
           'drags the mean utilisation from <b>40.3%</b> to <b>33.4%</b> and looks like evidence '
           'that 8&times;8 scales badly. Root cause: '
           '<code>docs/benchmarks/8x8_scaleup/rh_livelock_root_cause.md</code>.</p>'
           '<p class="sub"><code>' +
           html.escape(", ".join(sorted(f[1] + "_" + f[0] for f in LIVELOCKED))) +
           '</code></p></section>') if LIVELOCKED else '']

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
        def f(r, i):
            # A salvaged arm has cycles but no end-of-run util: the program finished, but the
            # sim was parked at the vsim prompt and never reached the $finish that prints
            # [FPU FINAL]. Aggregating its [FPUG] windows does NOT reproduce that number
            # (the windows include warm-up, and the dilution differs per arm), so the value
            # stays absent rather than being filled with an incomparable one.
            try:
                return float(r[i])
            except (TypeError, ValueError):
                return float("nan")
        withutil = [r for r in res if f(r, 4) == f(r, 4)]
        if not withutil:
            withutil = res
        best = max(withutil, key=lambda r: f(r, 4)); worst = min(withutil, key=lambda r: f(r, 4))
        pairs = {}
        for r in res:
            pairs.setdefault(r[0], {})[r[1]] = r
        both = [(k, v) for k, v in pairs.items() if len(v) == 2]
        ratios = [int(v["fp32"][3]) / float(v["fp16"][3]) for _, v in both if int(v["fp16"][3])]
        # carry per-side RH + mshr_timeout: a degraded fp32 arm INFLATES the ratio and a
        # degraded fp16 arm deflates it, so a contaminated pair measures MSHR sickness,
        # not precision. All three ratios above the 2x ceiling were fp32-sick.
        def _sick(r):
            try: return int(r[5] or 0) + int(r[6] or 0)
            except Exception: return 0
        ratio_pairs = [(k, int(v["fp32"][3]) / float(v["fp16"][3]),
                        _sick(v["fp16"]), _sick(v["fp32"]))
                       for k, v in both if int(v["fp16"][3])]
        n16 = sum(1 for r in res if r[1] == "fp16")
        a16 = sum(1 for r in res if r[1] == "fp16" and "FATAL" in r[8])
        n32 = sum(1 for r in res if r[1] == "fp32")
        a32 = sum(1 for r in res if r[1] == "fp32" and "FATAL" in r[8])
    # ---- how to read these numbers (provenance) ----------------------------------------------
    # The table mixes three kinds of number and nothing on the page said so. A reader cannot tell a
    # MEASURED utilisation from one REBUILT after the sim was killed before $finish, nor spot a row
    # whose transcript no longer exists. Both are legitimate; silently blending them is not.
    n_all = len(res)
    n_rec = sum(1 for r in res if str(r[4]).startswith("~"))
    n_fat = sum(1 for r in res if "FATAL" in r[8])
    # "carried forward" = the ROW survives but its transcript no longer does. Test the transcript
    # directly; absence from group_util.json is a DIFFERENT thing (mesh extraction can lag or an arm
    # can lack [FPUG] entirely), and using it as a proxy under-counted 13 as 2.
    def _no_evidence(arm):
        try:
            with open(os.path.join(ROOT, "hardware", "s8_" + arm, "transcript"), "rb") as fh:
                return b"execution took" not in fh.read()
        except OSError:
            return True
    n_carried = sum(1 for r in res if _no_evidence(r[1] + "_" + r[0]))
    if n_all:
        h += ['<section><h2>How to read these numbers</h2>',
              '<div class="tiles">',
              '<div class="tile done"><span class="n">%d</span><span class="l">delivered &mdash; '
              'cycle counts all measured</span></div>' % n_all,
              '<div class="tile"><span class="n">%d</span><span class="l">util reconstructed '
              '(shown <i>~</i>)</span></div>' % n_rec,
              '<div class="tile wait"><span class="n">%d</span><span class="l">row kept, transcript '
              'overwritten</span></div>' % n_carried,
              '<div class="tile bad"><span class="n">%d</span><span class="l">lost their spotcheck '
              'to the assertion</span></div>' % n_fat,
              '</div>',
              '<p class="sub" style="margin-top:12px"><b>Cycle counts are always measured.</b> A '
              'cycle count only exists if the benchmark ran to completion, so every row in the '
              'table is a finished run.</p>',
              '<p class="sub"><b>A <i>~</i> utilisation was rebuilt, not measured.</b> '
              '<code>[FPU FINAL]</code> is printed from a SystemVerilog <code>final</code> block, so '
              'it only appears if the simulation reaches <code>$finish</code>. An arm salvaged from a '
              'parked sim, or killed because its result already existed, finished its program but '
              'never got there. Those are rebuilt by summing the per-period <code>[FPUG]</code> '
              'windows tagged <code>bench</code> &mdash; validated against the arms that have both '
              'numbers at <b>1.1 pp mean error</b>, the error being window quantisation (1.6 pp under '
              '20 windows, 0.15 pp over 80). They are excluded from the best/worst-util headline so a '
              'rebuilt figure can never be quoted as a measured one.</p>',
              '<p class="sub"><b>Utilisation is benchmark-region only.</b> The counter is gated on '
              '<code>csr_trace_any_global</code>, so boot, DMA, I-cache warm-up and the pre-kernel '
              'barriers are excluded from both the numerator and the denominator.</p>',
              '<p class="sub"><b>A kept row means its evidence was overwritten.</b> badist writes '
              '<code>hardware/s8_&lt;arm&gt;/transcript</code> unconditionally, so a re-run replaces a '
              'delivered transcript with its own. <code>results.tsv</code> is merge-only and keeps the '
              'measurement, but that arm\'s per-group mesh data is gone until the re-run completes.</p>',
              '</section>']
        h += ['<section><h2>What the data says so far</h2><div class="tiles">',
              '<div class="tile"><span class="n">%s%%</span><span class="l">best util &mdash; %s %s</span></div>'
              % (best[4], esc(best[1]), esc(best[0])),
              '<div class="tile"><span class="n">%s%%</span><span class="l">worst util &mdash; %s %s</span></div>'
              % (worst[4], esc(worst[1]), esc(worst[0]))]
        if ratios:
            # MEDIAN, not mean: with a handful of pairs a single anomalous arm moves the mean a
            # long way. 512x64x1024 sits at 3.11x while the rest cluster at 1.50-1.52x, which
            # dragged the mean to 1.91x -- a number matching no pair in the set.
            rs = sorted(ratios); n = len(rs)
            med = rs[n // 2] if n % 2 else (rs[n // 2 - 1] + rs[n // 2]) / 2.0
            h += ['<div class="tile"><span class="n">%.2f&times;</span>'
                  '<span class="l">fp32 / fp16 &mdash; median of %d pair%s</span></div>'
                  % (med, n, "" if n == 1 else "s")]
            if n >= 3 and rs[-1] > 1.5 * med:
                # COUNT the arms above the band instead of asserting "one". The label read
                # "one arm is an outlier" while TWO sat at 3.11x and 3.29x -- a hardcoded claim
                # that went stale as pairs landed, in the panel meant to be the trustworthy summary.
                hi = sum(1 for r in rs if r > 1.5 * med)
                h += ['<div class="tile"><span class="n">%.2f&ndash;%.2f</span>'
                      '<span class="l">ratio range &mdash; %s</span></div>'
                      % (rs[0], rs[-1],
                         "one arm above the band" if hi == 1 else "%d arms above the band" % hi)]
        h += ['<div class="tile bad"><span class="n">%d/%d</span>'
              '<span class="l">fp16 hit the assertion</span></div>' % (a16, n16),
              '<div class="tile done"><span class="n">%d/%d</span>'
              '<span class="l">fp32 hit it</span></div>' % (a32, n32),
              '</div><p class="sub" style="margin-top:14px">Utilisation spans a <b>%.1f&times;</b> range '
              'across shapes. Read that with care: the earlier 8&times;8 campaign recorded 94.1%% when '
              'correctly provisioned against 20.8&ndash;28.2%% under-provisioned, so a low number is not '
              'automatically a shape effect &mdash; check the arm\'s MSHR settings before concluding.</p>'
              '' % (f(best, 4) / f(worst, 4) if f(worst, 4) else 0)]
        h += [ratio_chart(ratio_pairs), '<p class="sub" style="margin-top:2px">Filled marks are pairs where BOTH arms ran clean; hollow dashed marks carry RH&nbsp;&gt;&nbsp;0 or mshr_timeout&nbsp;&gt;&nbsp;0 on one side and measure MSHR degradation, not precision &mdash; a sick fp32 arm inflates the ratio, a sick fp16 arm deflates it. <b>Every point above the 2&times; ceiling is fp32-sick</b>, so the earlier reading of this chart (&ldquo;fp32 is losing on traffic&rdquo;) does not survive: on the clean pairs alone the ratio sits at or just around the arithmetic limit, which is what ~2 MACs per lane-cycle predicts and needs no traffic explanation. Hover any mark for its health counters.</p></section>']

    # ---- per-group mesh over time ----
    try:
        gu = json.load(open(os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/group_util.json")))
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
              '<dt>working set</dt><dd id="mdata">-</dd>',
              '</dl><p class="sub" style="margin-top:14px;font-size:12.5px">A wide spread means '
              'some groups are starved while others saturate &mdash; the alignment problem the '
              'group-MSHR design is meant to address. A single number cannot show it.</p></div></div>',
              '<h3 style="font:600 13px/1 \'IBM Plex Mono\',monospace;letter-spacing:.06em;'
              'text-transform:uppercase;color:var(--dim);margin:34px 0 6px">'
              'Per-group progress &mdash; are the groups advancing together?</h3>',
              '<p class="sub" style="margin-bottom:14px">Each bar is a group\'s progress against its '
              '<b>own theoretical share</b> of the work &mdash; MACs completed divided by '
              '<code>M&middot;N&middot;P / 64</code>, since the kernel splits M equally across the 64 '
              'groups. MACs are taken from the probe as '
              '<code>&Sigma;(util &times; 64000 lane-cycles) &times; MAC/lane-cycle</code>, with 2 for '
              'fp16 (two values packed per word) and 1 for fp32. Driven by the same slider. If the '
              'groups were aligned the bars would move as one block; the spread is wasted machine, '
              'because the kernel does not end until the <b>last</b> group finishes.</p>',
              '<p class="sub" style="margin-bottom:14px;font-size:12.5px">A finished group reads a '
              'little <b>over 100%</b>. That is expected: the probe counts lane <b>occupancy</b>, not '
              'retired MACs, and across the completed arms the excess is a consistent ~15%. The bar '
              'clamps at 100%; the number does not, so the overhead stays visible rather than being '
              'quietly hidden.</p>',
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
  // A+B+C in MiB -- the number that had to fit the 14.50 MiB L1 budget
  const sm=/^fp(\d+)_(\d+)x(\d+)x(\d+)$/.exec(sel.value);
  if(sm){ const b=sm[1]==="16"?2:4, M=+sm[2], N=+sm[3], P=+sm[4];
    $("mdata").textContent=((M*N+N*P+M*P)*b/1048576).toFixed(2)+" MiB"; }
  else $("mdata").textContent="-";
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
let CUM=null, SHARE=0;
// Absolute progress against the theoretical work, not against the leading group.
//   MACs done by a group = sum over windows of (util/100 * 64000 lane-cycles) * MAC_PER_LC
//   MACs the group owes  = M*N*P / 64            (the kernel splits M equally across 64 groups)
// MAC_PER_LC is 2 for fp16 (two values packed per 32-bit word) and 1 for fp32. Derived from the
// data, not assumed: across 27 completed arms the implied factor clusters at 1.60-1.90 for fp16
// and 0.72-0.90 for fp32, i.e. 2 and 1 with a consistent ~15% occupancy overhead -- the probe
// counts lane OCCUPANCY, not retired MACs, so a finished group reads a little over 100%.
const DENOM_LC=64000;
function buildCum(){
  const d=GU[sel.value]||[]; CUM=[];
  const m=/^fp(\d+)_(\d+)x(\d+)x(\d+)$/.exec(sel.value);
  const macPerLc = m && m[1]==="16" ? 2 : 1;
  SHARE = m ? (+m[2])*(+m[3])*(+m[4])/64 : 0;      // MACs this group owes
  const run=new Array(64).fill(0);
  for(const p of d){
    for(let g=0;g<64;g++) run[g]+=p.u[g]/100*DENOM_LC*macPerLc;
    CUM.push(run.slice());
  }
}
function drawProg(){
  if(!CUM||!CUM.length||!SHARE) return;
  const k=Math.min(CUM.length-1,+rng.value), c=CUM[k];
  const pct=c.map(v=>v/SHARE*100);                 // % of this group's OWN theoretical share
  const mx=Math.max(...pct), mn=Math.min(...pct);
  const li=pct.indexOf(mx), gi=pct.indexOf(mn);
  for(let g=0;g<64;g++){
    rows[g].fi.style.width=Math.min(100,pct[g]).toFixed(1)+"%";   // bar clamps, number does not
    rows[g].fi.className="fill"+(g===li?" lead":(g===gi?" lag":""));
    rows[g].pc.textContent=pct[g].toFixed(0)+"%";
  }
  $("plead").textContent=`g${li} — ${mx.toFixed(0)}%`;
  $("plag").textContent=`g${gi} — ${mn.toFixed(0)}%`;
  $("pgap").textContent=(mx-mn).toFixed(1)+" pp";
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
        # Default order: paired shapes first (the side-by-side comparison is the point), then by
        # PROBLEM SIZE. Size is a property of the shape, so the order does not reshuffle as arms
        # land -- sorting by fp16 cycles moved a row every time its other half finished, which is
        # disorienting on a page you re-read. Any column can be clicked to re-sort.
        def mnp(sh):
            try:
                M, N, P = (int(x) for x in sh.split("x")); return M * N * P
            except Exception:
                return 0
        order = sorted(by, key=lambda sh: (len(by[sh]) < 2, mnp(sh)))
        h += ['<div class="tw"><table class="pairs">'
              '<tr><th></th><th></th><th colspan="2" class="grp">working set</th>'
              '<th colspan="5" class="grp">fp16</th>'
              '<th colspan="5" class="grp">fp32</th><th></th></tr>'
              '<tr id="sorthdr"><th data-c="0">shape</th><th data-c="1">A&#8209;share</th>'
              '<th class="gs" data-c="2">fp16&nbsp;MiB</th><th data-c="3">fp32&nbsp;MiB</th>'
              '<th class="gs" data-c="4">cycles</th><th data-c="5">util</th><th data-c="6">RH</th>'
              '<th data-c="7">timeout</th><th data-c="8">bypass</th>'
              '<th class="gs" data-c="9">cycles</th><th data-c="10">util</th><th data-c="11">RH</th>'
              '<th data-c="12">timeout</th><th data-c="13">bypass</th>'
              '<th class="gs" data-c="14">fp32/fp16</th></tr>']
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
                # A leading "~" marks a util rebuilt from the [FPUG] windows because this arm was
                # salvaged and never printed [FPU FINAL]. Render it visibly different so it can
                # never be quoted as a measured value.
                u = r[4]
                if u.startswith("~"):
                    ucell = ('<td class="num recon" title="Reconstructed from the per-period '
                             '[FPUG] windows: this arm was salvaged from a parked sim and never '
                             'reached the $finish that prints [FPU FINAL]. Validated on 35 arms '
                             'that have both -- mean error 1.1 pp, from window quantisation, '
                             'scaling as 1/windows.">' + esc(u) + '%</td>')
                else:
                    ucell = '<td class="num">' + esc(u) + '%</td>'
                return ('<td class="num gs">' + "{:,}".format(int(r[3])) + mark +
                        '</td>' + ucell +
                        z(r[5]) + z(r[6]) + z(r[7]))
            if paired:
                a, b = int(d["fp16"][3]), int(d["fp32"][3])
                ratio = ('<td class="num ratio gs">%.2f&times;</td>' % (b / float(a))) if a else '<td class="gs"></td>'
            else:
                ratio = '<td class="num dim gs">&mdash;</td>'
            d16 = data_mib(sh, "fp16"); d32 = data_mib(sh, "fp32")
            def k(pr, i):
                # lstrip('~'): a reconstructed util still sorts as the number it is; leaving the
                # tilde in made float() raise, which parked every salvaged arm at the bottom of
                # a util sort regardless of direction.
                try: return str(float(str(d[pr][i]).lstrip('~')))
                except Exception: return ""
            keys = [str(mnp(sh)), str(ash), "%.4f" % (d16 or 0), "%.4f" % (d32 or 0),
                    k("fp16", 3), k("fp16", 4), k("fp16", 5), k("fp16", 6), k("fp16", 7),
                    k("fp32", 3), k("fp32", 4), k("fp32", 5), k("fp32", 6), k("fp32", 7),
                    ("%.4f" % (int(d["fp32"][3]) / float(d["fp16"][3]))) if paired and int(d["fp16"][3]) else ""]
            h += ['<tr' + ('' if paired else ' class="unpaired"') +
                  ' data-k="' + esc("|".join(keys)) + '"><td><code>' + esc(sh) +
                  '</code></td><td class="num">' + esc(ash) + '</td>' +
                  '<td class="num gs">' + ("%.2f" % d16 if d16 else "&mdash;") + '</td>' +
                  '<td class="num">' + ("%.2f" % d32 if d32 else "&mdash;") + '</td>' +
                  cell("fp16") + cell("fp32") + ratio + '</tr>']
        h += ['</table></div>',
              '<script>(function(){',
              '''
const hdr=document.getElementById("sorthdr"); if(!hdr) return;
const tb=hdr.parentNode, body=[...tb.querySelectorAll("tr")].filter(r=>r.dataset.k!==undefined);
let col=-1, dir=1;
hdr.querySelectorAll("th[data-c]").forEach(th=>{
  th.style.cursor="pointer"; th.title="sort by this column";
  th.addEventListener("click",()=>{
    const c=+th.dataset.c;
    dir = (c===col) ? -dir : 1;         // same column toggles direction, a new column starts ascending
    col = c;
    hdr.querySelectorAll("th[data-c]").forEach(x=>x.textContent=x.textContent.replace(/[ \u25b2\u25bc]+$/,""));
    th.textContent = th.textContent + (dir>0?" \u25b2":" \u25bc");
    const rows=body.slice().sort((a,b)=>{
      const A=a.dataset.k.split("|")[c], B=b.dataset.k.split("|")[c];
      // a missing value (an unfinished half) always sorts last, whichever way the column runs
      if(A===""&&B==="") return 0;
      if(A==="") return 1;
      if(B==="") return -1;
      const na=parseFloat(A), nb=parseFloat(B);
      if(!isNaN(na)&&!isNaN(nb)) return (na-nb)*dir;
      return A.localeCompare(B)*dir;
    });
    rows.forEach(r=>tb.appendChild(r));
  });
});
''',
              '})();</script>',
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
    # ---- live progress of the RUNNING arms -------------------------------------------------
    # Progress is estimated from FPU lane-cycles accumulated, not from the cycle count: an arm has
    # no idea how many cycles it will need. See scripts/gen_run_progress.py for the K correction
    # (busy is lane OCCUPANCY, ~1.15x the MAC count on a finished arm) and why livelocked arms are
    # excluded from that calibration.
    try:
        prog = json.load(open(os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/run_progress.json")))
    except Exception:
        prog = None
    if prog and prog.get("rows"):
        pr_rows = prog["rows"]
        K = prog.get("K", {})
        def med(v):
            v = sorted(x for x in v if x is not None)
            return v[len(v) // 2] if v else 0
        byb = {}
        for r in pr_rows:
            byb.setdefault(r["backend"], []).append(r)
        h += ['<section class="card"><h2>Live progress of the ' + str(len(pr_rows)) + ' running arms</h2>',
              '<p class="sub">Estimated from FPU lane-cycles accumulated against '
              '<code>M&times;N&times;P</code>, with a per-precision correction '
              '<code>K</code> (' + ", ".join("%s %.3f" % (k, v) for k, v in sorted(K.items())) +
              ') calibrated on 75 completed runs &mdash; <code>busy</code> is lane <em>occupancy</em>, '
              'not a MAC counter, so a finished arm accumulates ~15% more lane-cycles than it had '
              'MACs. Treat these as &plusmn;10%, not exact.</p>',
              '<div class="tiles" style="margin-bottom:14px">']
        for b in sorted(byb):
            g = byb[b]
            h += ['<div class="tile run"><span class="n">%d%%</span><span class="l">%s median (%d arms)</span></div>'
                  % (round(100 * med([x["progress"] for x in g])), b, len(g))]
        h += ['</div>', '<div class="tw"><table>',
              '<tr><th>arm</th><th>sim</th><th class="num">progress</th>'
              '<th class="num">cum util</th><th class="num">cycles</th><th>node</th></tr>']
        for r in pr_rows:
            cls = ' class="unpaired"' if (r["cum_util"] is not None and r["cum_util"] < 5) else ''
            h += ['<tr%s><td><code>%s</code></td><td>%s</td><td class="num">%d%%</td>'
                  '<td class="num">%s</td><td class="num">%s</td><td>%s</td></tr>'
                  % (cls, html.escape(r["arm"]), r["backend"], round(100 * r["progress"]),
                     ("%.2f%%" % r["cum_util"]) if r["cum_util"] is not None else "&mdash;",
                     "{:,}".format(r["cyc"]) if r["cyc"] else "&mdash;",
                     html.escape(r["node"] or "-"))]
        lowN = [r for r in pr_rows if r["cum_util"] is not None and r["cum_util"] < 5]
        h += ['</table></div>']
        if lowN:
            h += ['<p class="sub"><b>' + str(len(lowN)) + ' running arms are under 5%% utilisation '
                  'with <code>RH = 0</code></b> &mdash; so this is <em>not</em> the cohort livelock. '
                  '%d of them have <code>N &le; 64</code>. Small contraction depth looks like a '
                  'second, independent low-utilisation mechanism.</p>'
                  % sum(1 for r in lowN if r["N"] <= 64)]
        h += ['</section>']
    h += ['</div>']
    open(OUT, "w").write("\n".join(h))
    print("  wrote %s  (%d done, %d running, %d queued, %d failed)" % (OUT, done, run, q, fail))

main()
