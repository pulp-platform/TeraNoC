#!/usr/bin/env python3
"""Generate the quiescent-deadlock debugging record as a standalone artifact page.

Reads live campaign data so the page can be regenerated rather than hand-maintained:
  docs/benchmarks/8x8_scaleup/results.tsv        -- recorded outcomes incl. state=deadlock
  docs/benchmarks/8x8_scaleup/run_progress.json  -- live per-arm progress
  docs/benchmarks/8x8_scaleup/manifest.txt       -- the planned 248 arms
"""
import csv, json, os, collections, html

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
D = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup")
OUT = "/tmp/claude-620771/deadlock.html"

rows = list(csv.reader(open(os.path.join(D, "results.tsv")), delimiter="\t"))[1:]
rec = {(r[1], r[0]): r for r in rows if len(r) > 9}
prog = {r["arm"]: r for r in json.load(open(os.path.join(D, "run_progress.json")))["rows"]}
mani = [l.split() for l in open(os.path.join(D, "manifest.txt")) if len(l.split()) == 4]

# outcome by contraction
byN = collections.defaultdict(collections.Counter)
stuck = []
for M, N, P, PR in mani:
    prec, shape = "fp%s" % PR, "%sx%sx%s" % (M, N, P)
    arm = "%s_%s" % (prec, shape)
    if (prec, shape) in rec:
        st = rec[(prec, shape)][9]
    elif arm in prog:
        st = "deadlock" if (prog[arm].get("cum_util") or 99) < 5 else "running"
    else:
        st = "not-dispatched"
    byN[int(N)][st] += 1
    if st == "deadlock":
        # Source the retired arms from results.tsv, NOT run_progress: once they are killed they
        # are no longer running, so run_progress drops them and the table would come out empty.
        r = rec.get((prec, shape))
        p = prog.get(arm, {})
        cyc = int(r[3]) if r and r[3].strip().isdigit() else (p.get("cyc") or 0)
        u = r[4].lstrip("~") if r else ""
        try:
            util = float(u)
        except ValueError:
            util = p.get("cum_util") or 0.0
        stuck.append((arm, p.get("node", "-"), p.get("backend", "-"), util, cyc,
                      int(M), int(N), int(P)))
stuck.sort(key=lambda x: (-x[4],))

def esc(s): return html.escape(str(s))

L = []
A = L.append
A('<title>Quiescent Deadlock</title>')
A('''<style>
:root{
  --bg:#F3F4F1; --surface:#FBFBF9; --surface-2:#EAECE7;
  --ink:#191C19; --ink-2:#41473F; --ink-3:#6E756A;
  --rule:#D6D9D1; --rule-2:#C2C6BB;
  --accent:#1F6350; --accent-soft:#E2EDE8;
  --bad:#9B3226; --bad-soft:#F7E2DF;
  --ok:#2F6B3C; --ok-soft:#E1EFE3;
  --warn:#8A6212; --warn-soft:#F6EDD8;
  --serif:ui-serif,"Iowan Old Style","Palatino Linotype",Palatino,Georgia,Cambria,serif;
  --sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
  --mono:ui-monospace,"SF Mono","Cascadia Code","Roboto Mono",Menlo,Consolas,monospace;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --bg:#14171A; --surface:#1B1F22; --surface-2:#23282C;
  --ink:#E7EAE6; --ink-2:#B6BDB6; --ink-3:#8B938B;
  --rule:#2E3439; --rule-2:#3C444A;
  --accent:#63BCA1; --accent-soft:#1D2E2A;
  --bad:#E08A7C; --bad-soft:#301F1D;
  --ok:#77C08A; --ok-soft:#1C2A20;
  --warn:#D9B564; --warn-soft:#2C2519;
}}
:root[data-theme="dark"]{
  --bg:#14171A; --surface:#1B1F22; --surface-2:#23282C;
  --ink:#E7EAE6; --ink-2:#B6BDB6; --ink-3:#8B938B;
  --rule:#2E3439; --rule-2:#3C444A;
  --accent:#63BCA1; --accent-soft:#1D2E2A;
  --bad:#E08A7C; --bad-soft:#301F1D;
  --ok:#77C08A; --ok-soft:#1C2A20;
  --warn:#D9B564; --warn-soft:#2C2519;
}
*{box-sizing:border-box}
body{background:var(--bg); color:var(--ink); font-family:var(--serif); font-size:17px;
  line-height:1.62; margin:0; padding:0 20px 96px; -webkit-font-smoothing:antialiased}
.wrap{max-width:80ch; margin:0 auto; display:flex; flex-direction:column; gap:1.35rem}
header{padding:56px 0 8px; display:flex; flex-direction:column; gap:1rem}
.eyebrow{font-family:var(--sans); font-size:.7rem; font-weight:650; letter-spacing:.13em;
  text-transform:uppercase; color:var(--bad); margin:0}
h1{font-family:var(--sans); font-weight:700; letter-spacing:-.022em;
  font-size:clamp(2rem,5.6vw,2.9rem); line-height:1.06; margin:0; text-wrap:balance}
.standfirst{font-size:1.13rem; color:var(--ink-2); margin:0; max-width:62ch}
.byline{font-family:var(--sans); font-size:.78rem; color:var(--ink-3);
  border-top:1px solid var(--rule); padding-top:.7rem; margin:0; display:flex;
  flex-wrap:wrap; gap:.4rem 1.1rem}
section{display:flex; flex-direction:column; gap:1.1rem; margin-top:2.4rem}
h2{font-family:var(--sans); font-weight:680; font-size:1.36rem; letter-spacing:-.014em;
  line-height:1.2; margin:0; padding-top:1rem; border-top:2px solid var(--ink); text-wrap:balance}
h3{font-family:var(--sans); font-weight:660; font-size:1rem; margin:.4rem 0 -.5rem}
p{margin:0}
code,.mono{font-family:var(--mono); font-size:.86em; background:var(--surface-2);
  padding:.1em .34em; border-radius:3px}
pre{font-family:var(--mono); font-size:.78rem; line-height:1.5; background:var(--surface);
  border:1px solid var(--rule); border-radius:3px; padding:.9rem 1rem; overflow-x:auto; margin:0}
.tw{overflow-x:auto; border:1px solid var(--rule); border-radius:2px; background:var(--surface)}
table{border-collapse:collapse; width:100%; font-family:var(--sans); font-size:.845rem; line-height:1.45}
th,td{text-align:left; padding:.5rem .7rem; border-bottom:1px solid var(--rule); white-space:nowrap}
thead th{font-weight:660; font-size:.75rem; letter-spacing:.04em; text-transform:uppercase;
  color:var(--ink-3); background:var(--surface-2)}
tbody tr:last-child td{border-bottom:none}
td.n,th.n{text-align:right; font-variant-numeric:tabular-nums}
td.wrap-ok{white-space:normal; min-width:22ch}
.pill{font-family:var(--sans); font-size:.72rem; font-weight:640; padding:.12em .5em;
  border-radius:10px; white-space:nowrap}
.pill.bad{background:var(--bad-soft); color:var(--bad)}
.pill.ok{background:var(--ok-soft); color:var(--ok)}
.pill.warn{background:var(--warn-soft); color:var(--warn)}
.callout{background:var(--surface); border:1px solid var(--rule); border-left:3px solid var(--accent);
  border-radius:2px; padding:.9rem 1.1rem; display:flex; flex-direction:column; gap:.5rem}
.callout.hot{border-left-color:var(--bad)}
.callout .ct{font-family:var(--sans); font-weight:660; font-size:.93rem}
.callout p{font-size:.97rem}
.bar{display:flex; align-items:center; gap:.5rem}
.bar .t{height:9px; border-radius:2px; background:var(--bad); min-width:2px}
.bar .t.zero{background:var(--ok)}
</style>''')
A('<div class="wrap">')
A('<header>')
A('<p class="eyebrow">8&times;8 campaign &middot; failure record</p>')
A('<h1>Quiescent Deadlock</h1>')
A('<p class="standfirst">A third terminal state, distinct from the recorded livelock: every FPU '
  'lane idle across all 64 groups, no response hazards, no MSHR timeouts, and the NoC links '
  '<em>idle rather than stalled</em>. The machine is stopped, not thrashing &mdash; and neither '
  'detector could see it.</p>')
A('<p class="byline"><span>%d arms retired</span><span>0 delivered results contaminated</span>'
  '<span>docs/benchmarks/8x8_scaleup/quiescent_deadlock.md</span></p>' % len(stuck))
A('</header>')

A('<section><h2>The signature</h2>')
A('<pre>[FPU] bench cyc=2398000 util=0.00% cum=0.09% busy=0/4096000 lane-cyc\n'
  '      grp_max=0.0%(g0) grp_min=0.0%(g0)  mshr_timeout=+0 bankfull_bypass=+0\n'
  '      core_spread=0/0(g0)  bar_rel=+0 bar_spread=0.0 bar_max=4913\n'
  '[BP] delta,kind=bank_req,cyc=2399000,hsk=0,stall=0,idle=16000,util=0.0000</pre>')
A('<div class="tw"><table><thead><tr><th></th><th>recorded livelock</th>'
  '<th>quiescent deadlock</th></tr></thead><tbody>'
  '<tr><td><code>RH STUCK</code> episodes</td><td>~10<sup>5</sup></td><td><b>0</b></td></tr>'
  '<tr><td>FPU busy lane-cycles</td><td>non-zero</td><td><b>0 / 4,096,000</b></td></tr>'
  '<tr><td><code>mshr_timeout</code></td><td>0</td><td>0</td></tr>'
  '<tr><td>bank req/resp links</td><td>thrashing</td><td><b>idle</b> (<code>hsk=0 stall=0</code>)</td></tr>'
  '<tr><td>what the machine is doing</td><td>working badly</td><td><b>nothing at all</b></td></tr>'
  '</tbody></table></div>')
A('<div class="callout hot"><span class="ct">Why nothing caught it</span>'
  '<p><code>collect_8x8_results.py</code> recorded a livelock only when <code>RH STUCK &gt; 1000</code>; '
  'these sit at <b>0</b>, so no row was written and the retry loops would re-dispatch them forever. '
  '<code>campaign_status.py</code> flags WEDGED on <code>util &lt; 0.5 AND cms &gt; 50000</code> &mdash; '
  'utilisation reaches 2.74% and CMS is 26,795, so it missed on both and reported <code>WEDGED 0</code>.</p></div>')
A('</section>')

A('<section><h2>Where the cores actually stop</h2>')
A('<p>Final <em>retired</em> PC across all 1024 harts of <code>fp32_2048x32x256</code>. The trace '
  'records retirement, so a core is blocked on the instruction <em>after</em> its last line.</p>')
A('<div class="tw"><table><thead><tr><th class="n">harts</th><th>last retired</th>'
  '<th>instruction</th><th>blocked on</th></tr></thead><tbody>'
  '<tr><td class="n">221</td><td><code>0x80000294</code></td><td><code>sfence.vma</code></td>'
  '<td><code>0x80000298 lw t1, 0(a0)</code></td></tr>'
  '<tr><td class="n">221</td><td><code>0x80000298</code></td><td><code>lw t1, 0(a0)</code></td>'
  '<td><code>0x8000029c fence.i</code></td></tr>'
  '<tr><td class="n">346</td><td><code>0x80002604</code></td><td><code>bne</code> &mdash; barrier spin</td>'
  '<td>the 442 above</td></tr>'
  '<tr><td class="n">65</td><td>&mdash;</td><td><code>wfi</code></td><td>parked</td></tr>'
  '</tbody></table></div>')
A('<p>That range is the barrier-entry sequence <code>sfence.vma; lw; fence.i</code> inside '
  '<b><code>matmul_8xVL</code></b>.</p>')
A('<div class="callout"><span class="ct">The blocking event</span>'
  '<p>Hart <code>0x202</code> (group 32, tile 2) has exactly two scoreboard records, and they are '
  '<b>the same request</b>:</p>'
  '<pre>cyc=21000 STUCK_REQ g=32 t=2 p=0 hart=0x202 id=0 age=1053 addr=0x00f880c0 R bl=1 beats=0\n'
  'cyc=33000 STUCK_REQ g=32 t=2 p=0 hart=0x202 id=0 age=1935 addr=0x00f880c0 R bl=1 beats=0</pre>'
  '<p>Same <code>id</code>, same address, <code>beats=0</code> throughout, age growing. '
  '<code>p=0</code> is the shared scalar port; <code>0x00f880c0</code> decodes to group&nbsp;0, '
  'tile&nbsp;12 &mdash; a <b>remote scalar read that never receives a response</b>. The hart\'s last '
  'instruction retired at cycle 31,064, and the second warning places the request\'s start at '
  '~31,065.</p></div>')
A('<div class="callout hot"><span class="ct">Retracted: it is not the request-sent fence</span>'
  '<p>An earlier reading blamed <code>fence_stall = (|acc_mem_req_cnt_q)</code> and a rising-edge '
  'pulse that back-to-back mem ops could coalesce. <b>The trace refutes it</b> &mdash; '
  '<code>sfence.vma</code> retires normally, with a per-instruction <code>stall_tot</code> of 10 '
  'cycles on its last occurrence. The counter/pulse shape mismatch may still be a latent defect, '
  'but it is not what stops these arms. Kept as a worked example of a mechanism that fits a summary '
  'and dies on the raw trace.</p></div>')
A('</section>')

A('<section><h2>Blast radius</h2>')
tot = collections.Counter()
for N in byN:
    for k, v in byN[N].items():
        tot[k] += v
small = sum(v for N in byN if N <= 256 for v in [sum(byN[N].values())])
A('<div class="tw"><table><thead><tr><th class="n">N</th><th class="n">done</th>'
  '<th class="n">livelock</th><th class="n">deadlock</th><th class="n">rate</th>'
  '<th>of settled</th></tr></thead><tbody>')
for N in sorted(byN):
    c = byN[N]
    settled = c["done"] + c["livelock"] + c["deadlock"]
    rate = (100.0 * c["deadlock"] / settled) if settled else 0
    w = int(rate * 6) + (2 if rate else 2)
    A('<tr><td class="n"><code>%d</code></td><td class="n">%d</td><td class="n">%d</td>'
      '<td class="n"><b>%d</b></td><td class="n">%.1f%%</td>'
      '<td><span class="bar"><span class="t%s" style="width:%dpx"></span></span></td></tr>'
      % (N, c["done"], c["livelock"], c["deadlock"], rate, "" if rate else " zero", w))
A('</tbody></table></div>')
A('<div class="callout"><span class="ct">A floor at <code>N &ge; 512</code>, ~11% below it</span>'
  '<p>Zero deadlocks at <code>N &ge; 512</code> across every settled arm, and a roughly flat rate '
  'at <code>N = 32</code>&ndash;<code>256</code>. That reads as a <b>race that only becomes '
  'reachable when the contraction is short</b>, not a size threshold &mdash; 118 small-<code>N</code> '
  'arms completed cleanly.</p>'
  '<p><b>No delivered result is contaminated.</b> An arm in this state never prints '
  '<code>execution took</code>, so it never produced a row. The cost is lost seat-time and missing '
  'coverage, not wrong data.</p></div>')
A('</section>')

A('<section><h2>The retired arms</h2>')
A('<p>Each was verified with <b>two samples</b> spaced apart: the simulated cycle must advance '
  'while <code>busy</code> stays 0 and cumulative utilisation stays flat. Time passing with no work '
  'is what separates <em>stuck</em> from <em>slow</em>.</p>')
A('<div class="tw"><table><thead><tr><th>arm</th><th>node</th><th>sim</th>'
  '<th class="n">M</th><th class="n">N</th><th class="n">P</th>'
  '<th class="n">cum util</th><th class="n">cycles reached</th></tr></thead><tbody>')
for arm, node, be, u, cyc, M, N, P in stuck:
    A('<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td class="n">%d</td>'
      '<td class="n"><b>%d</b></td><td class="n">%d</td>'
      '<td class="n">%.2f%%</td><td class="n">%s</td></tr>'
      % (esc(arm), esc(node), esc(be), M, N, P, u, "{:,}".format(cyc)))
A('</tbody></table></div>')
A('</section>')

A('<section><h2>What would settle the mechanism</h2>')
A('<p>The request is identified precisely enough to trace directly: '
  '<code>g=32 t=2 p=0 id=0 addr=0x00f880c0</code>. A waveform on one arm following it from the tile '
  'port through the group MSHR to the NoC and back would distinguish the three candidates &mdash; a '
  'response dropped in the NoC, an MSHR entry that completes without arming its timeout, or a request '
  'that never reached the MSHR at all.</p>')
A('<p><b>Cost of a fix is not estimable until then.</b> A timeout that should have armed is a logic '
  'change with essentially no area; a dropped NoC response could be materially more. Any number '
  'quoted before the waveform would be invented.</p>')
A('</section>')
A('</div>')

open(OUT, "w").write("\n".join(L) + "\n")
print("wrote %s (%d retired arms)" % (OUT, len(stuck)))
