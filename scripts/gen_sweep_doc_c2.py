#!/usr/bin/env python3
"""Generate docs/benchmarks/gemm_results_mshr_ppa_c2.md from the live C2 sweep logs.

Re-runnable: call it again as arms complete and the table fills in.

Unlike its two companions this file carries TWO deltas per shape. The one against
`gemm_results.md` says where the tree now stands; the one against the opt3 sweep is the
single-knob measurement of C2 itself, and is the number to quote for C2.
"""
import re, os, hashlib, subprocess, datetime

W = '/usr/scratch/fenga1/zexifu/mshr_ppa_wt/'
T = '/tmp/claude-620771/'
OUT = W + 'docs/benchmarks/gemm_results_mshr_ppa_c2.md'

# ---- reference table -------------------------------------------------------
tab = {}
for ln in open(W + 'docs/benchmarks/gemm_results.md'):
    if not re.match(r'\|\s*\d+x\d+x\d+\s*\|', ln):
        continue
    c = [x.strip() for x in ln.strip().strip('|').split('|')]
    if len(c) < 16:
        continue
    try:
        tab[c[0]] = dict(ss=int(c[2]), sb=int(c[3]), ash=int(c[5]), bsh=int(c[6]),
                         merge=int(c[7]),
                         ours=int(re.sub(r'[^\d]', '', c[10])),
                         pct=float(re.sub(r'[^\d.]', '', c[11])))
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
bl = T + 'mx_sweepC2_256x512x256_build.log'
if os.path.exists(bl):
    defs = dict(re.findall(r'GROUP_MSHR_([A-Z_0-9]+)=(\d+)', open(bl, errors='ignore').read()))

sha = subprocess.run(['git', '-C', W, 'rev-parse', '--short', 'HEAD'],
                     capture_output=True, text=True).stdout.strip()

rows, d_old, d_o3 = [], [], []
for s in shapes:
    t = tab.get(s)
    if not t:
        continue
    M, N, P = map(int, s.split('x'))
    ideal = M * N * P / 1024
    new = final(f'mx_sweepC2_{s}_run.log')
    o3 = final(f'mx_sweepO3_{s}_run.log')
    elf = W + f'hardware/matmul_4x4_{s}.elf'
    md5 = hashlib.md5(open(elf, 'rb').read()).hexdigest()[:8] if os.path.exists(elf) else '-'
    win = 0 if t['bsh'] == 1 else 2047
    o3s = f"{o3:,}" if o3 else "—"
    if new:
        a = 100 * (new - t['ours']) / t['ours']
        d_old.append(a)
        if o3:
            b = 100 * (new - o3) / o3
            d_o3.append(b)
            bs = f"{b:+.2f}%"
        else:
            bs = "—"
        rows.append((s, t, ideal, f"{new:,}", f"{100*ideal/new:.1f}%", f"{a:+.1f}%", bs, win, md5, o3s))
    else:
        rows.append((s, t, ideal, f"_{periods(f'mx_sweepC2_{s}_run.log')}p_",
                     "—", "—", "—", win, md5, o3s))

now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
L = []
A = L.append
A("# GEMM benchmark results — MSHR PPA re-baseline, opt2 + opt3 + C2 (req-in spill bypassed)")
A("")
A(f"Generated {now}. **Re-runnable**: `python3 scripts/gen_sweep_doc_c2.py` refreshes this file as arms complete.")
A("")
A("Third of three PPA sweeps over the same 23 shapes. See")
A("[`README.md`](README.md) for how the files relate; in short:")
A("")
A("| file | `bank_publish` (opt3) | `spill_req_in` (C2) |")
A("|---|---|---|")
A("| `gemm_results_mshr_ppa.md` | 0 | 1 |")
A("| `gemm_results_mshr_ppa_opt3.md` | **1** | 1 |")
A("| **this file** | **1** | **0** |")
A("")
A("So **the delta against the opt3 file is C2 measured alone** — that is the number to quote")
A("for C2. The delta against `gemm_results.md` says where the tree stands overall and bundles")
A("everything since 2026-08-03.")
A("")
A("## What C2 is")
A("")
A("`SpillReqIn = 0` bypasses the MSHR's request-input spill register. The tile already")
A("registers its request output (`mempool_tile.sv:838`) and only two wire assigns separate the")
A("two (`mempool_group.sv:216`, `:569`) — two registers back to back with no logic between")
A("them. Bypassing removes **32 × 166 = 5,312 flops per group**, ~85k across the cluster.")
A("")
A("It was gated on C1, not on the data path: the bypass re-exposes the tile's spill to this")
A("module's `req_in_ready`, which used to carry an up-to-32-deep serial merge read-modify-write.")
A("C1 replaced that with a prefix rank against the registered array, so the ready path is now")
A("shallow and the bypass is safe to take.")
A("")
A("**This is the one PPA change that is NOT bit-identical.** A1–A5, B0.3, B1, B2, B3, C1 and C3")
A("were each verified to reproduce 34,715 cycles exactly. C2 removes a pipeline stage, so")
A("requests arrive a cycle earlier and cycle counts legitimately move — there is no equivalence")
A("check to run, and this sweep IS its verification.")
A("")
A("**The other three spills stay.** `req_out` is the only register between the replay path and")
A("the NoC; `resp_out` is documented deadlock-relevant (`mempool_group_mshr.sv:1067-1072`) and")
A("feeds a `fall_through_register` that is combinational when empty; bypassing `resp_in` would")
A("compose the router output crossbar onto the capture→drain arc.")
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
A("              drain_from_q=1  bank_publish=1  spill_req_in=0")
A("```")
A("")
A("All three of `drain_from_q`, `bank_publish` and `spill_req_in` are passed **explicitly**")
A("rather than inherited from the flavour default, and the launcher aborts an arm whose compile")
A("line lacks `GROUP_MSHR_SPILL_REQ_IN=0`. A silently-absent define would make this sweep a")
A("duplicate of the opt3 one, and the delta would read as \"C2 is free\" when C2 was never in it.")
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
A("`128x256x512`, `128x128x512`. All have **B shared 1-way**, so `hold_subs_burst` clamps to 2")
A("and a 1-way-shared line can never supply 2 subscribers: the early-release condition is")
A("unreachable and any non-zero window becomes a guaranteed full-window stall on every burst")
A("allocation. Forcing 2047 on `128x1024x512` measured **+803%** before that arm was killed.")
A("The pin is a disable, not a tuning value.")
A("")
A("## Confound, stated up front")
A("")
A(f"These arms build from `{sha}`, which adds **B1b, C3 and C2** over the opt3 sweep's base.")
A("B1b and C3 are claimed bit-identical and their equivalence runs are in flight. If both")
A("verify, opt3-sweep → this sweep is a clean single-knob comparison. If either does not, the")
A("delta bundles that commit too and both sets need rebuilding from a common base.")
A("")
A("## Results")
A("")
A("| M×N×P | ideal | ss | sb | A-sh | B-sh | merge | win | ELF | old cyc | old % | opt3 cyc | C2 cyc | C2 % | Δ vs old | **Δ vs opt3** |")
A("|---|---:|---:|---:|---:|---:|---:|---:|:---|---:|---:|---:|---:|---:|---:|---:|")
for s, t, ideal, new, newpct, a, b, win, md5, o3s in rows:
    A(f"| {s} | {ideal:,.0f} | {t['ss']} | {t['sb']} | {t['ash']} | {t['bsh']} | {t['merge']} | "
      f"{win} | `{md5}` | {t['ours']:,} | {t['pct']:.1f}% | {o3s} | {new} | {newpct} | {a} | **{b}** |")
A("")
if d_o3:
    A(f"**{len(d_old)} of {len(shapes)} complete**, {len(d_o3)} with an opt3 counterpart to pair against.")
    A("")
    A(f"- **C2 alone (vs opt3): mean {sum(d_o3)/len(d_o3):+.2f}%** · best {min(d_o3):+.2f}% · worst {max(d_o3):+.2f}%")
    A(f"- whole tree (vs `gemm_results.md`): mean {sum(d_old)/len(d_old):+.1f}% · best {min(d_old):+.1f}% · worst {max(d_old):+.1f}%")
elif d_old:
    A(f"**{len(d_old)} of {len(shapes)} complete**, none yet paired against opt3.")
    A("")
    A(f"- whole tree (vs `gemm_results.md`): mean {sum(d_old)/len(d_old):+.1f}% · best {min(d_old):+.1f}% · worst {max(d_old):+.1f}%")
else:
    A(f"**0 of {len(shapes)} complete.**")
A("")
A("`ideal = M·N·P / 1024` (MACs ÷ 1024 FMA lanes = 256 cores × 4 FPU). Efficiency is")
A("`ideal / actual`; the denominator comes from the data size, never from simulation.")
A("")
A("## Reading this table")
A("")
A("**Do not rank on the TB's `[FPU] util`.** It samples `spatz_vfu.fpu_busy_q` — lane")
A("*occupancy*, which is not conserved across runs of identical work. On the `1024x128x128`")
A("opt2/opt3 pair it ranked the arm that finished **434 cycles later** as higher. Rank on")
A("completion cycles, or equivalently on `ideal/actual`.")
A("")
A("**C2 is an area change first.** Its job is 5,312 flops per group; the performance column")
A("exists to prove it did not cost anything, not to claim a speedup. A mean near zero is the")
A("success condition. A consistent gain would be the pipeline stage's latency coming back, and")
A("a consistent loss would mean the shortened `req_in_ready` path is throttling — either way")
A("the sign matters more than the magnitude.")
A("")
A("## Verification")
A("")
A("Every arm is cross-checked before its result is accepted:")
A("")
A("- `GROUP_MSHR_SPILL_REQ_IN=0` asserted in the compile line — the arm aborts without it")
A("- `merge_reqs`, `hold_subs_single/burst`, `bank_shift_single/burst` against `gemm_results.md`")
A("- `hold_window_burst` = 0 where B-sh = 1, else 2047")
A("- `drain_from_q` = 1 and `bank_publish` = 1 on every arm")
A("- ELF md5 against the build record, and its `.M/.N/.P` header against the shape name")
A("- each **running process**'s `+PRELOAD` path and simv symlink read from `/proc/<pid>/cmdline`")
A("- `hardware/generated/` confirmed 4×4 — it is shared across build dirs and encodes the mesh")
A("- zero uncommitted changes under `hardware/src`, so every arm is reproducible from git")
A("")
open(OUT, 'w').write("\n".join(L) + "\n")
print(f"  wrote {OUT}  ({len(d_old)}/{len(shapes)} complete, {len(d_o3)} paired)")
