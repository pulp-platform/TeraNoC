#!/usr/bin/env python3
"""Collect the decode-GEMM benchmark arms into docs/benchmarks/decode_gemm_results.md.

The decode arms are NOT part of the 8x8 sweep and have no row in results.tsv, so without this
they exist only as scattered run dirs. Shapes are B x D x I mapped to GEMM as M=B, N=D, P=I.

Efficiency = ideal/actual, where ideal = M*N*P / peak and peak = cores * N_FU * (2 for fp16).
Rank on THIS, not on the TB util column, which is lane occupancy and is not conserved across
runs of identical work.
"""
import glob, os, re

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = os.path.join(ROOT, "docs/benchmarks/decode_gemm_results.md")

# arm-name prefix -> (mesh, cores, precision)
FAMILY = {"dec4_": ("4x4", 256, "fp16"), "dec8_": ("8x8", 1024, "fp16"),
          "d4f32_": ("4x4", 256, "fp32"), "d8f32_": ("8x8", 1024, "fp32")}
N_FU = 4


def scrape(d):
    t = os.path.join(d, "transcript")
    try:
        b = open(t, "rb").read()
    except OSError:
        return None
    m = re.search(rb"execution took (\d+)", b)
    if not m:
        return {"state": "running", "cycles": None, "util": None}
    u = re.search(rb"\[FPU FINAL\][^\n]*?util=([0-9.]+)%", b)
    return {"state": "done", "cycles": int(m.group(1)),
            "util": float(u.group(1)) if u else None}


rows = []
for d in sorted(glob.glob(os.path.join(ROOT, "hardware", "dec_*"))):
    arm = os.path.basename(d)[4:]
    fam = next((k for k in FAMILY if arm.startswith(k)), None)
    if not fam:
        continue
    mesh, cores, prec = FAMILY[fam]
    m = re.search(r"(\d+)x(\d+)x(\d+)$", arm)
    if not m:
        continue
    B, D, I = (int(x) for x in m.groups())
    r = scrape(d)
    if not r:
        continue
    peak = cores * N_FU * (2 if prec == "fp16" else 1)
    ideal = B * D * I / peak
    eb = 2 if prec == "fp16" else 4
    n_row_chunks = B // 8
    slice_b = (I // (cores // n_row_chunks)) * eb if n_row_chunks else 0
    eff = 100.0 * ideal / r["cycles"] if r["cycles"] else None
    rows.append(dict(arm=arm, mesh=mesh, prec=prec, B=B, D=D, I=I, slice=slice_b,
                     cycles=r["cycles"], util=r["util"], eff=eff, state=r["state"],
                     ideal=ideal))

L = ["# Decode-shape GEMM — benchmark results", "",
     "`C[B][I] = A[B][D] x W[D][I]`, mapped to GEMM as `M=B, N=D, P=I`. Batch is 32 throughout,",
     "which is why the prefill work split cannot be used: it would give `M/KERNEL_SIZE = 4`",
     "row-chunks for the whole mesh. The decode split divides `P` as well as `M`.", "",
     "**No transpose is required.** `A[b][d]` is contiguous for the scalar load and",
     "`W[d][p:p+VL]` is contiguous for the vector load, so the inner loop is the prefill kernel's",
     "unchanged (`MATMUL_DECODE_SPLIT` selects only the work split).", "",
     "Efficiency is `ideal/actual`; peak is `cores * 4 FPU * (2 for fp16)`. Rank on it, not on",
     "the TB `util` column, which is lane occupancy.", "",
     "| mesh | prec | B x D x I | B slice | cycles | ideal | efficiency | util | state |",
     "|---|---|---|---:|---:|---:|---:|---:|---|"]
for r in sorted(rows, key=lambda x: (x["mesh"], x["prec"], x["D"])):
    L.append("| %s | %s | `%dx%dx%d` | %d B | %s | %.0f | %s | %s | %s |"
             % (r["mesh"], r["prec"], r["B"], r["D"], r["I"], r["slice"],
                "{:,}".format(r["cycles"]) if r["cycles"] else "—", r["ideal"],
                ("**%.1f%%**" % r["eff"]) if r["eff"] else "—",
                ("%.2f%%" % r["util"]) if r["util"] else "—", r["state"]))
done = [r for r in rows if r["state"] == "done"]
if len(done) >= 2:
    L += ["", "## Notes", ""]
    for mesh in sorted({r["mesh"] for r in done}):
        fam = [r for r in done if r["mesh"] == mesh]
        for prec in sorted({r["prec"] for r in fam}):
            g = sorted([r for r in fam if r["prec"] == prec], key=lambda x: x["D"])
            if len(g) == 2:
                L.append("* %s %s: D=%d gives %.1f%%, D=%d gives %.1f%% — %s."
                         % (mesh, prec, g[0]["D"], g[0]["eff"], g[1]["D"], g[1]["eff"],
                            "the wider hidden dimension amortises the fixed per-iteration cost"
                            if g[1]["eff"] > g[0]["eff"] else "the narrower one wins"))
    L.append("")
open(OUT, "w").write("\n".join(L) + "\n")
print("wrote %s (%d arms, %d done)" % (OUT, len(rows), len(done)))
