#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# Qwen decode-layer performance datasets (GVSoC + RTL) for the "Qwen Layer Perf" dashboard.
#
#   perf_dash.py fetch            RTL transcripts -> hardware/elf_mixer/dash_cache/<arm>.tr
#                                 (finished jobs from the badist gather archive, running jobs from
#                                 the node, filtered to the lines used here)
#   perf_dash.py build [outdir]   -> perf_runs.json perf_stages.json perf_timeline.json perf_peaks.json
#
# Per stage (from the app's own stage timers) the work is analytic: MACs and the bytes the DMA
# must move (weights streamed once per projection, the KV cache, the GDN state in and out). From
# those: FPU utilisation = ideal compute cycles / cycles (8 fp16 MAC per core per cycle), DMA
# bandwidth = bytes / cycles against the DMA peak (64 B per group per cycle, capped by the 64 B
# L2 channels), and the roofline bound max(compute, memory). RTL runs add the TB's measured
# windows (1000 cycles): [FPU] busy lane-cycles / capacity (issue slots of the 4 FPU lanes) and
# [DMAP] R beats (64 B), aggregated per stage and compared with the expected bytes.
import io
import json
import os
import re
import subprocess
import sys
import tarfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), *[".."] * 5))
HW = os.path.join(ROOT, "hardware")
ELF = os.path.join(HW, "elf_mixer")
CACHE = os.path.join(ELF, "dash_cache")
GVS = "/usr/scratch/fenga1/zexifu/gvsoc_mixer"
RESULTS = "/usr/scratch/fenga1/zexifu/badist-results"
BATCHES = ["mx3", "mx4", "mx5", "mx6", "mx7", "mx8", "mx9"]

MESH = {  # cores, groups, L2 channels
    "4x4": dict(cores=256, groups=16, l2=16),
    "8x8": dict(cores=1024, groups=64, l2=32),
}
MAC_PER_CORE = 8  # fp16 FMA per core per cycle (4 FPUs x 2), as the apps' own "ideal"
BEAT = 64         # DMA / L2 beat bytes

# GVSoC runs on the dashboard: (log tag, set). "final" = the current code.
GVSOC_RUNS = [
    ("qlal10_b4_s512", "final"), ("qlal10_b4_s2048", "final"), ("qlal10_b4_s8192", "final"),
    ("qlal10_b1_s8192", "final"), ("qlal10_b16_s2048", "final"),
    ("qlal8f_b16_s512", "final"), ("qlal8f_b16_s2048", "final"), ("qlal8f_b4_s8192", "final"),
    ("gdnl4_b4", "final"), ("gdnl8_b16", "final"), ("qla10_b4_s512", "final"),
    ("qlal4_b4_s2048", "history"), ("qlal8c_b16_s2048", "history"),
    ("gdnb_b4q", "history"), ("gdnb_b1", "history"),
]
RTL_SKIP = {"gdnb_ck_b4", "gdnb_ck2_b4", "qlal_b4_s2048", "gdnl_b4"}  # checks / invalid / lost


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw).stdout


# ---------------------------------------------------------------- build metadata (knobs) -------
def build_info(tag):
    """app, mesh and knobs from the build_app.sh header of hardware/elf_mixer/<tag>.log."""
    p = os.path.join(ELF, tag + ".log")
    if not os.path.exists(p):
        return None
    head = open(p, errors="replace").readline()
    m = re.match(r"# build_app.sh (\S+) (\S+) (\S+) (.*?) \(\d{4}-", head)
    if not m:
        return None
    app, mesh, _, args = m.groups()
    kv = dict(re.findall(r"(\w+)=([^\s]+)", args))
    for k, v in re.findall(r"-D(\w+)=(\w+)", args):
        kv[k] = v
    return dict(app=app, mesh=mesh, kv=kv, built=head.split("(")[-1].split(",")[0])


def run_shape(info):
    kv, app = info["kv"], info["app"]
    if app == "qwen-layer":
        attn = kv.get("ql_mixer", "gdn") == "attn"
        return dict(kind="attention" if attn else "gdn", B=int(kv.get("ql_b", 4)),
                    S=int(kv.get("ql_s", 2048)) if attn else None,
                    scope="mixer" if kv.get("ql_mixer_only", "0") == "1"
                    else "layer" if kv.get("ql_ffn", "0") == "1" else "block")
    if app == "qwen-gdn-block":
        return dict(kind="gdn", B=int(kv.get("gdnb_b", 4)), S=None, scope="block")
    if app == "qwen-attn":
        return dict(kind="attention", B=int(kv.get("ATT_B", 4)), S=int(kv.get("ATT_S", 512)),
                    scope="kernel")
    return None


# ---------------------------------------------------------------- analytic work per stage ------
H, P_QA, P_QZ, K_O, P_GU, K_DN = 4096, 14336, 16384, 6144, 32768, 16384
GDN_VH, GDN_D = 48, 128


def proj(B, K, P):
    return B * K * P, K * P * 2  # MACs, weight bytes (streamed once)


def attn_work(B, S):
    return B * 4 * S * 6 * 256 * 2, B * 4 * S * 256 * 2 * 2  # QK + PV MACs, K + V bytes


def gdn_work(B):  # delta rule: ~4 FPU ops per state element; state streamed in and out
    el = B * GDN_VH * GDN_D * GDN_D
    return 4 * el + B * 96 * H, 2 * 2 * el


# ---------------------------------------------------------------- app stage parsing ------------
def norm_lines(text):
    for ln in text.splitlines():
        if ln.startswith("# "):
            ln = ln[2:]
        if ln.startswith("[UART] "):
            ln = ln[7:]
        yield ln


def kv_of(line):
    return {k: int(v) for k, v in re.findall(r"([\w+]+)=(\d+)", line)}


def stages_of(text, shape):
    """[(stage, cycles, macs, bytes, parent)] in time order, or None if no result line."""
    B, S, kind = shape["B"], shape["S"], shape["kind"]
    ql = gd = at = atl = gdm = None
    for ln in norm_lines(text):
        if ln.startswith("[QL] B="):
            ql = kv_of(ln)
        elif ln.startswith("[GDNB] B="):
            gd = kv_of(ln)
        elif ln.startswith("[GDNB] mixer"):
            gdm = kv_of(ln)
        elif ln.startswith("[ATT] B="):
            at = kv_of(ln)
        elif ln.startswith("[ATTL] mixer"):
            atl = kv_of(ln)
    out = []
    mix = attn_work(B, S) if kind == "attention" else gdn_work(B)
    inp = proj(B, H, P_QA if kind == "attention" else P_QZ)
    inname = "in-proj (q gate k v)" if kind == "attention" else "in-proj (q k v z)"
    sub = []
    if kind == "attention" and atl:
        sub = [("prep (norm, RoPE, K tile 0)", atl.get("prep", 0), 0, 0),
               ("flash rounds", atl.get("rounds", 0), mix[0], atl.get("kv_bytes", mix[1])),
               ("combine + gate", atl.get("combine+gate", atl.get("combine", 0) + atl.get("finish", 0)), 0, 0)]
    elif kind == "gdn" and gdm:
        sub = [("a,b dot products", gdm.get("ab", 0), B * 96 * H, 0),
               ("state prologue", gdm.get("prologue", 0), 0, 0),
               ("delta-rule rounds", gdm.get("rounds", 0), mix[0] - B * 96 * H, mix[1])]
    if ql:
        seq = [("RMSNorm (pre-mixer)", ql["norm"], 0, 0), (inname, ql["qkvz"], *inp),
               ("mixer", ql["mixer"], *mix), ("handover", ql["handover"], 0, 0),
               ("o-proj + residual", ql["oproj"], *proj(B, K_O, H))]
        if shape["scope"] == "layer":
            seq += [("RMSNorm (pre-FFN)", ql["ffn_norm"], 0, 0),
                    ("gate+up + SwiGLU", ql["gateup"], *proj(B, H, P_GU)),
                    ("handover 2", ql["handover2"], 0, 0),
                    ("down + residual", ql["down"], *proj(B, K_DN, H))]
    elif gd:
        seq = [(inname, gd["qkvz"], *inp), ("mixer", gd["mixer"], *mix),
               ("handover", gd["handover"], 0, 0), ("o-proj + residual", gd["oproj"], *proj(B, K_O, H))]
    elif at:
        seq = [("prologue", at["prologue"], 0, 0),
               ("flash rounds", at["rounds_cyc"], mix[0], at.get("kv_bytes", mix[1])),
               ("combine", at["combine"], 0, 0)]
        sub = []
    else:
        return None
    for name, cyc, macs, byt in seq:
        if cyc == 0:  # a stage this build does not run (mixer-only, no FFN)
            continue
        out.append(dict(stage=name, cycles=cyc, macs=macs, bytes=byt, parent=None))
        if name == "mixer" and sub:
            done = 0
            for sn, sc, sm, sb in sub:
                out.append(dict(stage=sn, cycles=sc, macs=sm, bytes=sb, parent="mixer"))
                done += sc
            if cyc - done > 0:
                out.append(dict(stage="other (DMA waits, next phase prime)", cycles=cyc - done,
                                macs=0, bytes=0, parent="mixer"))
    return out


# ---------------------------------------------------------------- RTL windows ------------------
def rtl_windows(text, groups):
    """[(cyc, fpu_busy, fpu_cap)] bench windows and {cyc: dma_beats}."""
    fpu, dma = [], {}
    for ln in norm_lines(text):
        if ln.startswith("[FPU] bench"):
            m = re.search(r"cyc=(\d+).*?busy=(\d+)/(\d+)", ln)
            if m:
                fpu.append(tuple(int(x) for x in m.groups()))
        elif ln.startswith("[DMAP]"):
            m = re.search(r"cyc=(\d+) busy=\s*[\d,\s]+ r=\s*([\d,\s]+?) rstall", ln)
            if m:
                dma[int(m.group(1))] = sum(int(x) for x in m.group(2).replace(" ", "").split(",") if x)
    return fpu, dma


# ---------------------------------------------------------------- fetch ------------------------
def badist_jobs(batch_prefix):
    ids = sh(f"ls -d {RESULTS}/{batch_prefix}-* 2>/dev/null").split()
    sub = os.path.join(ELF, f"submit_{batch_prefix}.log")
    if os.path.exists(sub):
        first = open(sub).readline().split()
        if len(first) > 1:
            ids.append(os.path.join(RESULTS, first[1]))
    out = []
    for path in sorted(set(ids)):
        batch = os.path.basename(path)
        for ln in sh(f"badist status {batch} 2>/dev/null").splitlines():
            m = re.match(r"(\d{4})\s+(\w+)\s+(\S+).*arm=(\S+)", ln)
            if m:
                out.append(dict(batch=batch, job=m.group(1), state=m.group(2), node=m.group(3),
                                arm=m.group(4)))
    return out


KEEP = re.compile(r"^(# )?(\[FPU\] bench|\[DMAP\]|\[UART\]|\[(QL|GDNB|ATT|ATTL|FFN)\])")


def fetch():
    os.makedirs(CACHE, exist_ok=True)
    meta = {}
    for b in BATCHES:
        for j in badist_jobs(b):
            if j["arm"] in RTL_SKIP or j["state"] not in ("done", "running"):
                continue
            dst = os.path.join(CACHE, j["arm"] + ".tr")
            tar = os.path.join(RESULTS, j["batch"], j["job"] + ".tar.zst")
            text = None
            if j["state"] == "done" and os.path.exists(tar):
                raw = subprocess.run(f"zstd -dc {tar}", shell=True, capture_output=True).stdout
                with tarfile.open(fileobj=io.BytesIO(raw)) as tf:
                    for m in tf.getmembers():
                        if m.name.endswith("transcript"):
                            text = tf.extractfile(m).read().decode(errors="replace")
            elif j["state"] == "running":
                rd = f"zexifu_cache/badist/run/{j['batch']}/{j['job']}/transcript"
                text = sh(f"ssh -n -o ConnectTimeout=8 {j['node']} "
                          f"'for r in /scratch /scratch2; do f=$r/{rd}; [ -f $f ] && "
                          f"grep -a -E \"^(# )?(\\[FPU\\] bench|\\[DMAP\\]|\\[UART\\])\" $f; done'",
                          timeout=300)
            if not text:
                continue
            keep = "\n".join(l for l in text.splitlines() if KEEP.match(l))
            open(dst, "w").write(keep + "\n")
            meta[j["arm"]] = dict(state=j["state"], batch=j["batch"], job=j["job"], node=j["node"])
            print(f"{j['arm']:22s} {j['state']:8s} {len(keep.splitlines()):6d} lines")
    json.dump(meta, open(os.path.join(CACHE, "jobs.json"), "w"), indent=1)


# ---------------------------------------------------------------- build ------------------------
def analyse(run, backend, text, info, status, extra):
    elf = run
    run = f"{run}@{backend}"  # one ELF can run on both backends: the id must tell them apart
    shape = run_shape(info)
    if not shape:
        return None
    m = MESH[info["mesh"]]
    mac_pk = m["cores"] * MAC_PER_CORE
    dma_pk = min(m["groups"], m["l2"]) * BEAT
    st = stages_of(text, shape)
    fpu, dma = rtl_windows(text, m["groups"]) if backend == "rtl" else ([], {})
    t0 = (fpu[0][0] - 1000) if fpu else 0
    stages, timeline = [], []
    pos = 0
    for s in st or []:
        if s["parent"] is None:
            s["start"] = pos
            pos += s["cycles"]
    # sub-stages start at their parent's start
    cur = None
    for s in st or []:
        if s["parent"] is None:
            cur = s
            sub_pos = s["start"]
        else:
            s["start"] = sub_pos
            sub_pos += s["cycles"]
    for i, s in enumerate(st or []):
        c = max(s["cycles"], 1)
        comp = s["macs"] / mac_pk
        mem = s["bytes"] / dma_pk
        roof = max(comp, mem)
        if roof < 0.05 * c:
            bound = "overhead"
        else:
            bound = "compute" if comp >= mem else "memory"
        row = dict(run=run, idx=i, stage=s["stage"], parent=s["parent"] or "",
                   level=2 if s["parent"] else 1, start=s["start"], cycles=s["cycles"],
                   macs=s["macs"], bytes=s["bytes"], ideal_compute=round(comp),
                   ideal_memory=round(mem), roof=round(roof),
                   fpu_util=round(comp / c, 4), dma_Bpc=round(s["bytes"] / c, 1),
                   dma_util=round(mem / c, 4),
                   intensity=round(s["macs"] / s["bytes"], 2) if s["bytes"] else None,
                   mac_per_cycle=round(s["macs"] / c, 1), roof_eff=round(roof / c, 4), bound=bound,
                   meas_fpu=None, meas_dma_bytes=None, meas_dma_Bpc=None, meas_vs_expected=None)
        if fpu:
            a, b = t0 + s["start"], t0 + s["start"] + s["cycles"]
            ws = [w for w in fpu if a <= w[0] - 500 < b]
            if ws:
                row["meas_fpu"] = round(sum(w[1] for w in ws) / max(1, sum(w[2] for w in ws)), 4)
            beats = sum(v for k, v in dma.items() if a <= k - 500 < b)
            row["meas_dma_bytes"] = beats * BEAT
            row["meas_dma_Bpc"] = round(beats * BEAT / c, 1)
            if s["bytes"]:
                row["meas_vs_expected"] = round(beats * BEAT / s["bytes"], 3)
        stages.append(row)
    for w in fpu:
        k = w[0]
        timeline.append(dict(run=run, kcyc=round((k - 1000 - t0) / 1000, 3),
                             fpu=round(w[1] / max(1, w[2]), 4),
                             dma=round(dma.get(k, 0) / (m["groups"] * 1000), 4),
                             dma_Bpc=round(dma.get(k, 0) * BEAT / 1000, 1)))
    top = [s for s in stages if s["level"] == 1]
    tot = sum(s["cycles"] for s in top)
    for s in stages:
        s["share"] = round(s["cycles"] / tot, 4) if tot else None
    macs = sum(s["macs"] for s in top)
    byt = sum(s["bytes"] for s in top)
    roof = sum(s["roof"] for s in top)
    mix = sum(s["cycles"] for s in top if s["stage"] == "mixer" or s["stage"] == "flash rounds")
    what = {"layer": "layer", "block": "mixer block", "mixer": "mixer only",
            "kernel": "kernel"}[shape["scope"]]
    label = (f"{shape['kind']} {what} · {info['mesh']} · B={shape['B']}"
             + (f" · S={shape['S']}" if shape["S"] else "") + f" · {'RTL' if backend == 'rtl' else 'GVSoC'}")
    m_exp = re.search(r"^\S*\[QL\] B=.*\bexp=(real|fake)", text, re.M)
    expk = m_exp.group(1) if m_exp else "real"  # builds before 2026-10-10 always used the real exp
    label += f" · exp {expk}" if expk == "fake" else ""
    r = dict(run=run, elf=elf, label=label, exp=expk, backend=backend, mesh=info["mesh"], app=info["app"], kind=shape["kind"],
             scope=shape["scope"], B=shape["B"], S=shape["S"], status=status, set=extra.get("set", ""),
             built=info["built"], cycles=tot or None, macs=macs, bytes=byt,
             fpu_util=round(macs / mac_pk / tot, 4) if tot else None,
             dma_Bpc=round(byt / tot, 1) if tot else None,
             dma_util=round(byt / dma_pk / tot, 4) if tot else None,
             roof_eff=round(roof / tot, 4) if tot else None,
             mixer_share=round(mix / tot, 4) if tot else None,
             meas_fpu=None, meas_dma_Bpc=None, progress_kcyc=None)
    if fpu:
        r["meas_fpu"] = round(sum(w[1] for w in fpu) / max(1, sum(w[2] for w in fpu)), 4)
        r["meas_dma_Bpc"] = round(sum(dma.values()) * BEAT / (len(fpu) * 1000), 1)
        r["progress_kcyc"] = round(len(fpu), 0)
    if not st:
        r["status"] = "running" if status == "running" else "no result"
    return r, stages, timeline


def build(outdir):
    os.makedirs(outdir, exist_ok=True)
    runs, stages, timeline = [], [], []
    for tag, set_ in GVSOC_RUNS:
        p = os.path.join(GVS, tag + ".log")
        info = build_info(tag)
        if not (os.path.exists(p) and info):
            continue
        res = analyse(tag, "gvsoc", open(p, errors="replace").read(), info, "done", {"set": set_})
        if res and res[1]:
            runs.append(res[0]); stages += res[1]
    jobs = json.load(open(os.path.join(CACHE, "jobs.json"))) if os.path.exists(
        os.path.join(CACHE, "jobs.json")) else {}
    for arm, j in sorted(jobs.items()):
        info = build_info(arm)
        if not info:
            continue
        text = open(os.path.join(CACHE, arm + ".tr"), errors="replace").read()
        res = analyse(arm, "rtl", text, info, j["state"], {"set": "rtl"})
        if res:
            runs.append(res[0]); stages += res[1]; timeline += res[2]
    peaks = [dict(mesh=k, cores=v["cores"], groups=v["groups"], l2_channels=v["l2"],
                  mac_per_cycle=v["cores"] * MAC_PER_CORE, dma_group_Bpc=v["groups"] * BEAT,
                  l2_Bpc=v["l2"] * BEAT, dma_peak_Bpc=min(v["groups"], v["l2"]) * BEAT)
             for k, v in MESH.items()]
    for name, rows in (("perf_runs", runs), ("perf_stages", stages), ("perf_timeline", timeline),
                       ("perf_peaks", peaks)):
        json.dump(rows, open(os.path.join(outdir, name + ".json"), "w"), separators=(",", ":"))
        print(f"{name}: {len(rows)} rows")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "fetch":
        fetch()
    elif len(sys.argv) > 1 and sys.argv[1] == "build":
        build(sys.argv[2] if len(sys.argv) > 2 else os.path.join(ELF, "dash_out"))
    else:
        print(__doc__ if __doc__ else "usage: perf_dash.py fetch | build [outdir]")
