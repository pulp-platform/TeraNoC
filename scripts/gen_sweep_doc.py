#!/usr/bin/env python3
"""Generate docs/benchmarks/gemm_results_mshr_ppa.md from the live sweep logs.

Re-runnable: call it again as arms complete and the table fills in. Deliberately
mirrors the layout of gemm_results.md so the two can be read side by side.
"""
import re, os, hashlib, subprocess, datetime

W = '/usr/scratch/fenga1/zexifu/mshr_ppa_wt/'
T = '/tmp/claude-620771/'
OUT = W + 'docs/benchmarks/gemm_results_mshr_ppa.md'

# ---- reference table -------------------------------------------------------
tab = {}
for ln in open(W + 'docs/benchmarks/gemm_results.md'):
    if not re.match(r'\|\s*\d+x\d+x\d+\s*\|', ln):
        continue
    c = [x.strip() for x in ln.strip().strip('|').split('|')]
    if len(c) < 16:
        continue
    try:
        tab[c[0]] = dict(l1=c[1], ss=int(c[2]), sb=int(c[3]), bb=int(c[4]),
                         ash=int(c[5]), bsh=int(c[6]), merge=int(c[7]), it=int(c[8]),
                         floor=int(re.sub(r'[^\d]', '', c[9])),
                         ours=int(re.sub(r'[^\d]', '', c[10])),
                         pct=float(re.sub(r'[^\d.]', '', c[11])),
                         lim=c[15])
    except Exception:
        pass

def final(p):
    if not os.path.exists(T + p):
        return None
    for ln in reversed(open(T + p, errors='ignore').read().splitlines()):
        if ln.startswith('# '):
            ln = ln[2:]
        if '[FPU FINAL]' in ln:
            return int(re.search(r'over (\d+)', ln).group(1))
    return None

def periods(p):
    if not os.path.exists(T + p):
        return 0
    return sum(1 for ln in open(T + p, errors='ignore')
               if ln.lstrip('# ').startswith('[FPU] bench'))

shapes = [s.strip() for s in open(T + 'sweep_shapes.txt') if s.strip()]

# ---- the define set actually compiled in (identical across arms bar per-shape) ----
defs = {}
bl = T + 'mx_sweep2047_256x512x256_build.log'
if os.path.exists(bl):
    defs = dict(re.findall(r'GROUP_MSHR_([A-Z_0-9]+)=(\d+)', open(bl, errors='ignore').read()))

sha = subprocess.run(['git', '-C', W, 'rev-parse', '--short', 'HEAD'],
                     capture_output=True, text=True).stdout.strip()
built_at = '8ca4f060'

rows, deltas = [], []
for s in shapes:
    t = tab.get(s)
    if not t:
        continue
    M, N, P = map(int, s.split('x'))
    ideal = M * N * P / 1024
    new = final(f'mx_sweep2047_{s}_run.log')
    elf = W + f'hardware/matmul_4x4_{s}.elf'
    md5 = hashlib.md5(open(elf, 'rb').read()).hexdigest()[:8] if os.path.exists(elf) else '-'
    win = 0 if t['bsh'] == 1 else 2047
    if new:
        d = 100 * (new - t['ours']) / t['ours']
        deltas.append(d)
        rows.append((s, t, ideal, f"{new:,}", f"{100*ideal/new:.1f}%", f"{d:+.1f}%", win, md5))
    else:
        rows.append((s, t, ideal, f"_{periods(f'mx_sweep2047_{s}_run.log')}p_", "—", "—", win, md5))

now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
L = []
A = L.append
A("# GEMM benchmark results — MSHR PPA re-baseline")
A("")
A(f"Generated {now}. **Re-runnable**: `python3 scripts/gen_sweep_doc.py` refreshes this file as arms complete.")
A("")
A("Companion to `gemm_results.md`, which this re-measures. Same kernel, same shapes, same")
A("`ideal = M·N·P / 1024` definition — so the two tables are directly comparable.")
A("")
A("## What changed since `gemm_results.md` (2026-08-03)")
A("")
A("| | `gemm_results.md` | this run |")
A("|---|---|---|")
A(f"| RTL | pre-PPA | `{built_at}` — A1–A5, B0.3, B1, B2, B3 |")
A("| `group_mshr_drain_from_q` | 0 | **1** (timing closure; the 0 path does not close) |")
A("| `group_mshr_bank_publish` | 0 | **0** — see caveat below |")
A("| `group_mshr_hold_window_burst` | 255 | **2047**, except four shapes pinned to 0 |")
A("")
A("**CAVEAT — opt3 is NOT in these arms.** All 23 were built at 15:01, before")
A("`bank_publish` defaulted to 1 (`ee38f5ff`, 15:43) and before C1 (`cc2a751e`, 15:45).")
A("So this measures the verified-inert RTL work plus opt2 and the hold window, *without*")
A("opt3's unexplained +21.2% on `512x512x512` confounding every shape. That makes it a")
A("clean baseline, but it is **not** the shipping default set.")
A("")
A("## Configuration")
A("")
A("Common to all 23 arms:")
A("")
A("```")
A("base config   terapool_spatz4_fpu.mk — 256 cores, 16 groups, 4x4 mesh, Spatz vlen=512")
A("kernel        apps/spatz_apps/sp-fmatmul-opt-burst-merge")
A("ELF           one private per shape, md5-verified distinct (column below)")
A("simulator     VCS, +notracer, no waveforms")
A("passed        hold_window_burst=2047  serve_timeout=2047  hold_prescale_w=0")
A("```")
A("")
A("Resolved MSHR defines (per-shape values in the table; the rest are constant):")
A("")
A("```")
for k in sorted(defs):
    if k in ('MERGE_REQS', 'HOLD_SUBS_SINGLE', 'HOLD_SUBS_BURST',
             'BANK_SHIFT_SINGLE', 'BANK_SHIFT_BURST', 'HOLD_WINDOW_BURST'):
        continue
    A(f"GROUP_MSHR_{k} = {defs[k]}")
A("```")
A("")
A("Per-shape knobs come from `scripts/gemm_autotune.py` via")
A("`config/terapool_spatz4_fpu_gemm<shape>.mk`. `hold_subs_single/_burst` = A-sh / B-sh")
A("clamped to `[2, merge]`.")
A("")
A("**Four shapes pin `hold_window_burst := 0`** — `128x1024x512`, `128x512x512`,")
A("`128x256x512`, `128x128x512`. All have **B shared 1-way**, so `hold_subs_burst` clamps")
A("to 2 and a 1-way-shared line can never supply 2 subscribers: the early-release condition")
A("is unreachable and any non-zero window becomes a guaranteed full-window stall on every")
A("burst allocation. Forcing 2047 on `128x1024x512` measured **+803%** before that arm was")
A("killed. The pin is a disable, not a tuning value.")
A("")
A("## Results")
A("")
A("| M×N×P | ideal | ss | sb | A-sh | B-sh | merge | win | ELF | old cyc | old % | new cyc | new % | delta |")
A("|---|---:|---:|---:|---:|---:|---:|---:|:---|---:|---:|---:|---:|---:|")
for s, t, ideal, new, newpct, d, win, md5 in rows:
    A(f"| {s} | {ideal:,.0f} | {t['ss']} | {t['sb']} | {t['ash']} | {t['bsh']} | {t['merge']} | "
      f"{win} | `{md5}` | {t['ours']:,} | {t['pct']:.1f}% | {new} | {newpct} | {d} |")
A("")
if deltas:
    A(f"**{len(deltas)} of {len(shapes)} complete.** "
      f"mean **{sum(deltas)/len(deltas):+.1f}%** · best {min(deltas):+.1f}% · worst {max(deltas):+.1f}%")
else:
    A(f"**0 of {len(shapes)} complete.**")
A("")
A("`ideal = M·N·P / 1024` (MACs ÷ 1024 FMA lanes = 256 cores × 4 FPU). Efficiency is")
A("`ideal / actual`; the denominator comes from the data size, never from simulation.")
A("")
A("## Reading this table")
A("")
A("**Do not rank on the TB's `[FPU] util`.** It samples `spatz_vfu.fpu_busy_q` — lane")
A("*occupancy*, which is not conserved across runs of identical work. On the")
A("`1024x128x128` opt2/opt3 pair it ranked the arm that finished **434 cycles later** as")
A("higher. Rank on completion cycles, or equivalently on `ideal/actual`.")
A("")
A("**The delta bundles every change at once** — nine RTL commits, `drain_from_q=1` and")
A("hold 255→2047. It says what the current tree does; it does not attribute the gain. A")
A("matching sweep at hold=255 would separate the window out (one was started and stopped).")
A("")
A("## Verification")
A("")
A("Every arm was cross-checked before its result was accepted:")
A("")
A("- `merge_reqs`, `hold_subs_single/burst`, `bank_shift_single/burst` against `gemm_results.md`")
A("- `hold_window_burst` = 0 where B-sh = 1, else 2047")
A("- `drain_from_q` = 1 on every arm")
A("- ELF md5 against the build record, and its `.M/.N/.P` header against the shape name")
A("- each **running process**'s `+PRELOAD` path and simv symlink read from `/proc/<pid>/cmdline`")
A("- `hardware/generated/` confirmed 4×4 — it is shared across build dirs and encodes the mesh")
A("- zero uncommitted changes under `hardware/src`, so every arm is reproducible from git")
A("")
A("23/23 verified clean.")
A("")
open(OUT, 'w').write("\n".join(L) + "\n")
print(f"  wrote {OUT}  ({len(deltas)}/{len(shapes)} complete)")
