#!/usr/bin/env python3
"""Collect the decode-GEMM benchmark arms into docs/benchmarks/decode_gemm_results.md.

The decode arms are NOT part of the 8x8 sweep and have no row in results.tsv, so without this
they exist only as scattered run dirs. Shapes are B x D x I mapped to GEMM as M=B, N=D, P=I.

Efficiency = ideal/actual, where ideal = M*N*P / peak and peak = cores * N_FU * (2 for fp16).
Rank on THIS, not on the TB util column, which is lane occupancy and is not conserved across
runs of identical work.

Arms are enumerated from the badist LEDGER unioned with the local run dirs, never from the local
dirs alone: an arm that has not been fetched even once has no local dir, and globbing would drop
its row entirely -- which reads as "never planned" rather than "still running". d8f32_32x256x8192
was invisible here for exactly that reason.

The fleet state is carried alongside the locally scraped one and shown when they DISAGREE. A run
can print its result and still be marked failed by the job wrapper (both dec4_ fp16 arms did):
the measurement is good, but silently showing it as a clean `done` would hide a real fleet fault.
"""
import glob, json, os, re

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = os.path.join(ROOT, "docs/benchmarks/decode_gemm_results.md")

# arm-name prefix -> (mesh, cores, precision)
FAMILY = {"dec4_": ("4x4", 256, "fp16"), "dec8_": ("8x8", 1024, "fp16"),
          "d4f32_": ("4x4", 256, "fp32"), "d8f32_": ("8x8", 1024, "fp32")}
N_FU = 4
# KERNEL_SIZE the decode ELFs were built with. It sets the B-slice column only, and MUST be
# updated alongside any KS sweep -- there is no way to read it back out of the transcript.
KERNEL_SIZE = 8

STATE = os.path.expanduser("~/badist/state")
ARM_RE = re.compile(r"^(dec\d|d\df32|dec)[A-Za-z0-9]*_\d+x\d+x\d+$")


def ledger_arms():
    """arm -> fleet state, newest batch winning. Mirrors refresh_decode_progress.running_arms,
    but keeps EVERY state: a failed or pending arm still deserves a row."""
    out = {}
    for d in sorted((x for x in glob.glob(os.path.join(STATE, "*")) if os.path.isdir(x)),
                    key=os.path.getmtime, reverse=True):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        for j in jobs:
            arm = (j.get("meta") or {}).get("arm", "")
            if not ARM_RE.match(arm) or arm in out:
                continue
            st = None
            try:
                for ln in open(os.path.join(d, "jobs", j["job_id"] + ".jsonl")):
                    st = json.loads(ln).get("state") or st
            except OSError:
                continue
            if st:
                out[arm] = st
    return out


def scrape(d):
    t = os.path.join(d, "transcript")
    try:
        b = open(t, "rb").read()
    except OSError:
        return None
    m = re.search(rb"execution took (\d+)", b)
    if not m:
        return {"state": "running", "cycles": None, "util": None, "tmo": None, "bf": None, "rh": None}
    u = re.search(rb"\[FPU FINAL\][^\n]*?util=([0-9.]+)%", b)
    # Sum the per-period deltas -- `mshr_timeout=+N` and `bankfull_bypass=+N` are PER-PERIOD, not
    # running totals. Reading the last bench line as the total understates them to near zero, and
    # doing exactly that once inverted a conclusion about an A/B arm.
    txt = b"\n".join(l[2:] if l.startswith(b"# ") else l for l in b.split(b"\n"))
    def tot(tag):
        return sum(int(x) for x in re.findall(tag + rb"=\+(\d+)", txt))
    return {"state": "done", "cycles": int(m.group(1)),
            "util": float(u.group(1)) if u else None,
            "tmo": tot(rb"mshr_timeout"), "bf": tot(rb"bankfull_bypass"),
            "rh": txt.count(b"RH STUCK")}


fleet = ledger_arms()
local = {os.path.basename(d)[4:]: d for d in glob.glob(os.path.join(ROOT, "hardware", "dec_*"))}

rows = []
for arm in sorted(set(fleet) | set(local)):
    d = local.get(arm, os.path.join(ROOT, "hardware", "dec_" + arm))
    fam = next((k for k in FAMILY if arm.startswith(k)), None)
    if not fam:
        continue
    mesh, cores, prec = FAMILY[fam]
    m = re.search(r"(\d+)x(\d+)x(\d+)$", arm)
    if not m:
        continue
    B, D, I = (int(x) for x in m.groups())
    r = scrape(d) or {"state": fleet.get(arm, "pending"), "cycles": None, "util": None,
                      "tmo": None, "bf": None, "rh": None}
    fl = fleet.get(arm)
    # A measured arm the fleet calls failed keeps its number and says so; an unmeasured one
    # reports the fleet's own word, so "no local dir" never masquerades as "not planned".
    if r["cycles"] is None and fl:
        r["state"] = fl
    peak = cores * N_FU * (2 if prec == "fp16" else 1)
    ideal = B * D * I / peak
    eb = 2 if prec == "fp16" else 4
    n_row_chunks = B // KERNEL_SIZE
    slice_b = (I // (cores // n_row_chunks)) * eb if n_row_chunks else 0
    eff = 100.0 * ideal / r["cycles"] if r["cycles"] else None
    state = r["state"]
    if fl and fl != state and not (fl == "done" and state == "done"):
        state = "%s (fleet: %s)" % (state, fl)
    rows.append(dict(arm=arm, mesh=mesh, prec=prec, B=B, D=D, I=I, slice=slice_b,
                     cycles=r["cycles"], util=r["util"], eff=eff, state=state,
                     tmo=r.get("tmo"), bf=r.get("bf"), rh=r.get("rh"), ideal=ideal))

L = ["# Decode-shape GEMM — benchmark results", "",
     "> ⚠️ **THIS FILE IS GENERATED** by `scripts/collect_decode_results.py` and is rewritten in",
     "> full on every run, including from the dashboard loop. **Do not add analysis here — it will",
     "> be destroyed silently.** Hand-maintained prose lives in `decode_config_and_limits.md`,",
     "> which also records the config, the `KERNEL_SIZE`, and the caveats that bound these numbers.",
     "",
     "`C[B][I] = A[B][D] x W[D][I]`, mapped to GEMM as `M=B, N=D, P=I`. Batch is 32 throughout,",
     "which is why the prefill work split cannot be used: it would give `M/KERNEL_SIZE = 4`",
     "row-chunks for the whole mesh. The decode split divides `P` as well as `M`.", "",
     "**No transpose is required.** `A[b][d]` is contiguous for the scalar load and",
     "`W[d][p:p+VL]` is contiguous for the vector load, so the inner loop is the prefill kernel's",
     "unchanged (`MATMUL_DECODE_SPLIT` selects only the work split).", "",
     "Efficiency is `ideal/actual`; peak is `cores * 4 FPU * (2 for fp16)`. Rank on it, not on",
     "the TB `util` column, which is lane occupancy.", "",
     "| mesh | prec | B x D x I | B slice | cycles | ideal | efficiency | util | tmo | bankfull | RH | state |",
     "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|"]
for r in sorted(rows, key=lambda x: (x["mesh"], x["prec"], x["D"])):
    n = lambda v: ("{:,}".format(v) if v is not None else "—")
    L.append("| %s | %s | `%dx%dx%d` | %d B | %s | %.0f | %s | %s | %s | %s | %s | %s |"
             % (r["mesh"], r["prec"], r["B"], r["D"], r["I"], r["slice"],
                "{:,}".format(r["cycles"]) if r["cycles"] else "—", r["ideal"],
                ("**%.1f%%**" % r["eff"]) if r["eff"] else "—",
                ("%.2f%%" % r["util"]) if r["util"] else "—",
                n(r.get("tmo")), n(r.get("bf")), n(r.get("rh")), r["state"]))
done = [r for r in rows if r["cycles"]]
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
    # Cross-mesh scaling: the 8x8 arms run 4x the work on 4x the cores, so equal cycles would be
    # perfect scaling. Report what 4x the cores actually bought, per precision and D.
    pairs = []
    for prec in sorted({r["prec"] for r in done}):
        for D in sorted({r["D"] for r in done if r["prec"] == prec}):
            g = {r["mesh"]: r for r in done if r["prec"] == prec and r["D"] == D}
            if "4x4" in g and "8x8" in g:
                small, big = g["4x4"], g["8x8"]
                if big["I"] == 4 * small["I"]:
                    pairs.append((prec, D, small, big, 4.0 * small["cycles"] / big["cycles"]))
    if pairs:
        L += ["", "## Scaling 4x4 -> 8x8", "",
              "Both meshes run the SAME work per core: the 8x8 arm has 4x the cores and 4x the",
              "`I`, so equal cycle counts would be perfect scaling. `speedup` is throughput —",
              "`4 * cycles(4x4) / cycles(8x8)` — where 4.00x is ideal and 1.00x means the extra",
              "768 cores bought nothing.", "",
              "| prec | D | 4x4 cycles | 8x8 cycles | speedup | of ideal |",
              "|---|---:|---:|---:|---:|---:|"]
        for prec, D, small, big, sp in pairs:
            L.append("| %s | %d | %s | %s | **%.2fx** | %.0f%% |"
                     % (prec, D, "{:,}".format(small["cycles"]), "{:,}".format(big["cycles"]),
                        sp, 100.0 * sp / 4.0))
    L.append("")

# ---- config A/B: the w8k re-runs (remap 2->3, hold/serve 2047->8191, bankfull ON at 4x4) ----
# GENERATED, so it stays current as the remaining arms land. Baseline numbers come from the rows
# above; the re-run numbers are scraped from hardware/w8k_<arm>/.
ab = []
for r in rows:
    if not r["cycles"]:
        continue
    d2 = os.path.join(ROOT, "hardware", "w8k_" + r["arm"])
    s2 = scrape(d2)
    if s2 and s2.get("cycles"):
        ab.append((r, s2))
if ab:
    L += ["## Config A/B — `remap 2→3`, `hold/serve 2047→8191`", "",
          "Same shapes, same `KERNEL_SIZE=8`, same ELF source. Re-run arms live in",
          "`hardware/w8k_<arm>/`. The 4x4 pair ALSO flips `GROUP_MSHR_BANKFULL_BACKPRESSURE`",
          "off→on, which is why `bankfull` collapses to 0 there — that knob was absent from the",
          "old 4x4 image and present in the old 8x8 one (see `decode_config_and_limits.md`).", "",
          "| mesh | prec | D | baseline cyc | re-run cyc | delta | base eff | new eff | base bankfull | new bankfull |",
          "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    ds = []
    for r, s2 in sorted(ab, key=lambda x: (x[0]["mesh"], x[0]["prec"], x[0]["D"])):
        d = 100.0 * (s2["cycles"] - r["cycles"]) / r["cycles"]
        ds.append(d)
        e0 = 100.0 * r["ideal"] / r["cycles"]
        e1 = 100.0 * r["ideal"] / s2["cycles"]
        L.append("| %s | %s | %d | %s | %s | **%+.1f%%** | %.1f%% | %.1f%% | %s | %s |"
                 % (r["mesh"], r["prec"], r["D"], "{:,}".format(r["cycles"]),
                    "{:,}".format(s2["cycles"]), d, e0, e1,
                    "{:,}".format(r["bf"]) if r.get("bf") is not None else "—",
                    "{:,}".format(s2["bf"]) if s2.get("bf") is not None else "—"))
    L += ["", "**%d of 8 arms in; spread %+.1f%% to %+.1f%%, mean %+.1f%%.**"
          % (len(ab), min(ds), max(ds), sum(ds) / len(ds)), "",
          "The prediction was NO effect, on the grounds that every decode arm already runs at",
          "`tmo = 0` and the hold window only pays where there are timeouts to eliminate — the",
          "8x8 sweep A/B found its payoff tracks the timeout RATE",
          "(`8x8_scaleup/remap_x_window_ab.md`). Scatter around zero in both directions is",
          "consistent with that; a systematic gain would not be.", ""]

open(OUT, "w").write("\n".join(L) + "\n")
print("wrote %s (%d arms, %d done)" % (OUT, len(rows), len(done)))
