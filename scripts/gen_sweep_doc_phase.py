#!/usr/bin/env python3
"""Generate a per-phase GEMM benchmark table for the MSHR PPA campaign.

    gen_sweep_doc_phase.py <tag> <baseline_tag> <out_name> "<Phase title>" "<what changed>"

Replaces the three hand-copied generators (gen_sweep_doc{,_opt3,_c2}.py). Each phase gets its own
file, and every phase carries TWO deltas: against `gemm_results.md` (where the tree stands overall)
and against the immediately preceding phase (the single-knob measurement of THIS phase).

Only the second is attributable -- see docs/benchmarks/README.md for why the campaign is built as a
chain one knob apart at each link.
"""
import re, os, sys, hashlib, subprocess, datetime

tag, base_tag, out_name, title, changed = sys.argv[1:6]
W = '/usr/scratch/fenga1/zexifu/mshr_ppa_wt/'
T = '/tmp/claude-620771/'
OUT = W + 'docs/benchmarks/' + out_name

tab = {}
for ln in open(W + 'docs/benchmarks/gemm_results.md'):
    if not re.match(r'\|\s*\d+x\d+x\d+\s*\|', ln):
        continue
    c = [x.strip() for x in ln.strip().strip('|').split('|')]
    if len(c) < 16:
        continue
    try:
        tab[c[0]] = dict(ash=int(c[5]), bsh=int(c[6]), merge=int(c[7]),
                         ours=int(re.sub(r'[^\d]', '', c[10])),
                         pct=float(re.sub(r'[^\d.]', '', c[11])))
    except Exception:
        pass


def final(p):
    p = T + p
    if not os.path.exists(p):
        return None
    for ln in reversed(open(p, errors='ignore').read().splitlines()):
        if ln.startswith('# '):
            ln = ln[2:]
        if '[FPU FINAL]' in ln:
            return int(re.search(r'over (\d+)', ln).group(1))
    return None


def periods(p):
    p = T + p
    return 0 if not os.path.exists(p) else sum(
        1 for ln in open(p, errors='ignore') if ln.lstrip('# ').startswith('[FPU] bench'))


elf_suffix = sys.argv[6] if len(sys.argv) > 6 else ''
shapes = [s.strip() for s in open(T + 'sweep_shapes.txt') if s.strip()]
defs = {}
for probe in (f'_defs_{tag}_256x512x256.txt', f'_defs_{tag}_256x256x256.txt'):
    if os.path.exists(T + probe):
        defs = dict(l.strip().split('=') for l in open(T + probe) if '=' in l)
        break
sha = subprocess.run(['git', '-C', W, 'rev-parse', '--short', 'HEAD'],
                     capture_output=True, text=True).stdout.strip()

rows, d_old, d_base = [], [], []
for s in shapes:
    t = tab.get(s)
    if not t:
        continue
    M, N, P = map(int, s.split('x'))
    ideal = M * N * P / 1024
    new = final(f'mx_{tag}_{s}_run.log')
    bas = final(f'mx_{base_tag}_{s}_run.log')
    # Provenance must name the binary that ACTUALLY ran. The CSR sweep preloads
    # matmul_4x4_<shape>_csr.elf (CSR writes compiled in); recording the plain ELF's md5 here
    # would document a file the arm never touched.
    elf = W + f'hardware/matmul_4x4_{s}{elf_suffix}.elf'
    md5 = hashlib.md5(open(elf, 'rb').read()).hexdigest()[:8] if os.path.exists(elf) else '-'
    bs = f"{bas:,}" if bas else "—"
    if new:
        a = 100 * (new - t['ours']) / t['ours']
        d_old.append(a)
        if bas:
            b = 100 * (new - bas) / bas
            d_base.append(b)
            bt = f"{b:+.2f}%"
        else:
            bt = "—"
        rows.append((s, t, ideal, f"{new:,}", f"{100*ideal/new:.1f}%", f"{a:+.1f}%", bt, md5, bs))
    else:
        rows.append((s, t, ideal, f"_running ({periods(f'mx_{tag}_{s}_run.log')} periods)_", "—", "—", "—", md5, bs))

now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
L = []
A = L.append
A(f"# GEMM benchmark results — {title}")
A("")
A(f"Generated {now} from `{sha}`. **Re-runnable**: "
  f"`python3 scripts/gen_sweep_doc_phase.py {tag} {base_tag} {out_name} \"{title}\" \"{changed}\"`.")
A("")
A(f"**What changed in this phase:** {changed}")
A("")
A(f"Part of the chained PPA campaign — see [`README.md`](README.md). The **`Δ vs {base_tag}`** column "
  f"is this phase measured alone, against the arm immediately before it; that is the number to quote. "
  f"`Δ vs old` compares against `gemm_results.md` and bundles everything since 2026-08-03.")
A("")
A("## Results")
A("")
A("Column guide — the three cycle columns are three DIFFERENT measurements, which is easy to misread:")
A("")
A("| column | what it is |")
A("|---|---|")
A(f"| `baseline cyc` | pre-campaign reference from `gemm_results.md` (2026-08-03) |")
A(f"| `{base_tag} cyc` | the phase immediately before this one |")
A(f"| **`THIS PHASE cyc`** | **this sweep's result** |")
A(f"| `Δ vs baseline` | bundles every change since 2026-08-03 |")
A(f"| **`Δ vs {base_tag}`** | **this phase alone — the number to quote** |")
A("")
A("`_running (N periods)_` means the arm has not produced a FINAL yet; it is not a result.")
A("")
A(f"| M×N×P | ideal | A-sh | B-sh | merge | ELF | baseline cyc | baseline % | {base_tag} cyc | **THIS PHASE cyc** | this % | Δ vs baseline | **Δ vs {base_tag}** |")
A("|---|---:|---:|---:|---:|:--|---:|---:|---:|---:|---:|---:|---:|")
for s, t, ideal, new, newpct, a, b, md5, bs in rows:
    A(f"| {s} | {ideal:,.0f} | {t['ash']} | {t['bsh']} | {t['merge']} | `{md5}` | "
      f"{t['ours']:,} | {t['pct']:.1f}% | {bs} | {new} | {newpct} | {a} | **{b}** |")
A("")
if d_base:
    A(f"**{len(d_old)} of {len(shapes)} complete**, {len(d_base)} paired against `{base_tag}`.")
    A("")
    # Report the DISTRIBUTION, not a bare mean. A single collapsed arm dominates: on the CSR sweep
    # one arm at +252.7% pulled the mean of 20 to +14.79% while 18 arms sat inside +/-3.5%. Median
    # plus an explicit outlier split says what a mean cannot.
    _hi = [x for x in d_base if abs(x) > 10.0]
    _ok = [x for x in d_base if abs(x) <= 10.0] or d_base
    _srt = sorted(_ok)
    _med = _srt[len(_srt)//2] if len(_srt) % 2 else (_srt[len(_srt)//2 - 1] + _srt[len(_srt)//2]) / 2
    A(f"- **this phase, the {len(_ok)} arms within \u00b110%: mean {sum(_ok)/len(_ok):+.2f}%, "
      f"median {_med:+.2f}%** \u00b7 range {min(_ok):+.2f}% .. {max(_ok):+.2f}%")
    if _hi:
        A(f"- **{len(_hi)} arm(s) outside \u00b110%, reported as defects and EXCLUDED from the mean above:** "
          + ", ".join(f"{x:+.1f}%" for x in sorted(_hi, reverse=True))
          + f". Including them the mean would read {sum(d_base)/len(d_base):+.2f}%, which one arm dominates.")
    A(f"- whole tree vs `gemm_results.md`: mean {sum(d_old)/len(d_old):+.1f}%")
elif d_old:
    A(f"**{len(d_old)} of {len(shapes)} complete**, none paired yet.")
else:
    A(f"**0 of {len(shapes)} complete.**")
A("")
A("`ideal = M·N·P / 1024` (MACs ÷ 1024 FMA lanes = 256 cores × 4 FPU). Efficiency is `ideal / actual`;")
A("the denominator comes from the data size, never from simulation. **Do not rank on the TB's")
A("`[FPU] util`** — it samples lane occupancy, which is not conserved across runs of identical work,")
A("and it once ranked an arm that finished 434 cycles later as higher.")
A("")
if defs:
    A("## Compiled configuration")
    A("")
    A("Recorded from the arm's own build log, not from the launcher's intent:")
    A("")
    A("```")
    for k in sorted(defs):
        if k.split('_')[-1] in ('REQS',) or k in (
                'GROUP_MSHR_MERGE_REQS', 'GROUP_MSHR_HOLD_SUBS_SINGLE', 'GROUP_MSHR_HOLD_SUBS_BURST',
                'GROUP_MSHR_BANK_SHIFT_SINGLE', 'GROUP_MSHR_BANK_SHIFT_BURST',
                'GROUP_MSHR_HOLD_WINDOW_BURST'):
            continue
        A(f"{k} = {defs[k]}")
    A("```")
    A("")
    A("Per-shape knobs (`merge_reqs`, `hold_subs_*`, `bank_shift_*`, `hold_window_burst`) come from")
    A("`scripts/gemm_autotune.py` via `config/terapool_spatz4_fpu_gemm<shape>.mk` and are omitted here.")
    A("")
A("## Known caveat on four shapes")
A("")
A("`128x1024x512`, `128x512x512`, `128x256x512`, `128x128x512` have **B shared 1-way** and their")
A("flavour pins `hold_window_burst := 0`. Their `Δ vs old` also carries a `serve_timeout` 255→2047")
A("difference from `gemm_results.md`, so that column is **two-variable** on those rows. The")
A(f"`Δ vs {base_tag}` column is unaffected — both arms use the same timeout.")
A("")
open(OUT, 'w').write("\n".join(L) + "\n")
print(f"  wrote {OUT}  ({len(d_old)}/{len(shapes)} complete, {len(d_base)} paired vs {base_tag})")
