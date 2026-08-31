#!/usr/bin/env python3
"""Extract per-group FPU utilisation series for the B x KS artifact.

[FPUG] <tag> cyc=N denom=D busy=<per-group lane-busy cycles>
  - denom is LANE-cycles for the whole group, so util = busy[g]/denom.
  - Field 0 carries a LEADING SPACE (SV pads the shorter "%0d" literal), so the pattern must
    be `busy=\\s*` and every field stripped before int() -- a pattern demanding a digit straight
    after '=' matches nothing and reports "probe not compiled in" for a log full of them.
  - QuestaSim prefixes every line with '# '; strip it before matching.
Emits {arm: {groups, mesh, prec, periods:[{cyc,u:[...]}], macs_per_group}}.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def series(path, tag=b"bench"):
    try: b = re.sub(rb"(?m)^# ", b"", open(path, "rb").read())
    except IOError: return []
    out = []
    for m in re.finditer(rb"\[FPUG\]\s+(\S+)\s+cyc=(\d+)\s+denom=(\d+)\s+busy=\s*([0-9,\s]+)", b):
        if m.group(1) != tag: continue
        cyc, den = int(m.group(2)), int(m.group(3))
        if den <= 0: continue
        u = [round(100.0 * int(x.strip()) / den, 1)
             for x in m.group(4).split(b",") if x.strip()]
        if u: out.append({"cyc": cyc, "u": u, "den": den})
    return out

def collect(runs):
    gu = {}
    for label, rel, B, D, I, prec, R in runs:
        p = os.path.join(ROOT, "hardware", rel, "sim.out")
        # 'both' completed with its log on a deleted inode (a queued script rm -rf'd the run dir);
        # the mirror captured it. Prefer the mirror when it holds the finished run.
        alt = "/tmp/claude-620771/both_orphan.log"
        if rel == "both_run_ks1" and os.path.exists(alt):
            try:
                if b"execution took" in open(alt, "rb").read(): p = alt
            except IOError: pass
        s = series(p)
        if not s: continue
        g = len(s[0]["u"])
        s = [w for w in s if len(w["u"]) == g]
        # guard: windows*1000 should approximate took/R. If it does not, R is wrong.
        try:
            b = re.sub(rb"(?m)^# ", b"", open(p, "rb").read())
            m = re.search(rb"execution took (\d+)", b)
            if m:
                took = int(m.group(1))
                exp = took * R / 1000.0
                if abs(exp - len(s)) > max(3, 0.25 * len(s)):
                    sys.stderr.write("WARN %s: R=%d implies ~%.0f windows but log has %d\n"
                                     % (label, R, exp, len(s)))
        except IOError:
            pass
        gu[label] = {"groups": g, "prec": prec,
                     "mesh": "4x4" if g <= 16 else "8x8",
                     "shape": "%dx%dx%d" % (B, D, I),
                     "run": "local", "state": "done", "ks": 1, "B": B, "D": D, "I": I,
                     "periods": s,
                     # MACs each group must retire over the measured region
                     "macs_per_group": B * D * I * R / float(g)}
    return gu

def collect_fleet(gu):
    """Fleet arms: [FPUG] bench lines pulled node-side into /tmp/.../fpug/<arm>.txt.

    R (repeat passes) is DERIVED from the window count, not assumed: these fleet ELFs do use
    MATMUL_REPEAT (147 windows for a 4,595-cycle pass => R~32) while the local ladder ELFs do
    not. Hard-coding R here is what made every progress bar read 16x low before.
    """
    import glob as _g
    # health state for the running ("deg__") arms, so the explorer can filter normal vs degraded
    _state = {}
    try:
        for _l in open("/tmp/claude-620771/deg_results.tsv"):
            _p = _l.rstrip("\n").split("\t")
            if len(_p) >= 14: _state[_p[0]] = _p[13]
    except IOError:
        pass
    idx = {}
    for f in sorted(_g.glob("/tmp/claude-620771/fpug/*.txt")):
        base = os.path.basename(f)[:-4]
        # files are namespaced "<runtag>__<arm>" so run1 and run2 cannot overwrite each other's
        # series for the same arm name (they are different configs of the same shape).
        tag, _, arm = base.partition("__")
        if not arm: tag, arm = "", base
        # "deg" and "deg-<batch>" both mark a running-arm harvest; keep the batch so run1 and
        # run2 series for the SAME arm name cannot overwrite each other (they are different
        # configs of one shape, and that collision silently replaced run2 data with run1's).
        batch = ""
        if tag.startswith("deg"):
            batch = tag[4:] if tag.startswith("deg-") else ""
            tag = "deg"
        m = re.match(r"sw_(\dx\d)_(fp\d+)_ks(\d+)_(\d+)x(\d+)x(\d+)$", arm)
        if not m: continue
        mesh, prec, ks, B, D, I = m.group(1), m.group(2), int(m.group(3)), \
                                  int(m.group(4)), int(m.group(5)), int(m.group(6))
        per = []
        for ln in open(f, "rb"):
            mm = re.search(rb"cyc=(\d+) denom=(\d+) busy=\s*([0-9,\s]+)", ln)
            if not mm: continue
            den = int(mm.group(2))
            if den <= 0: continue
            u = [round(100.0 * int(x.strip()) / den, 1)
                 for x in mm.group(3).split(b",") if x.strip()]
            if u: per.append({"cyc": int(mm.group(1)), "u": u, "den": den})
        if not per: continue
        g = len(per[0]["u"])
        per = [w for w in per if len(w["u"]) == g]
        # derive R from the measured span: windows are 1000 cycles apart
        span = per[-1]["cyc"] - per[0]["cyc"] + 1000
        lane = 2 if prec == "fp16" else 1
        # macs_per_group is only used for the (normalised) progress view; keep it consistent
        R = max(1, round(span / (B * D * I / (256.0 * 4 * lane))))
        key = (batch + "__" + arm) if batch else arm
        st = _state.get(key, _state.get(arm, "done")) if tag == "deg" else "done"
        base_tag = ("degraded" if st == "degraded" else "running") if tag == "deg" else tag
        shown_tag = (base_tag + " " + batch) if (batch and tag == "deg") else base_tag
        label = "%s%s KS=%d %dx%dx%d" % ((shown_tag + " ") if shown_tag else "", prec, ks, B, D, I)
        gu[label] = {"groups": g, "prec": prec, "mesh": mesh,
                     "shape": "%dx%dx%d" % (B, D, I), "periods": per,
                     "run": shown_tag or "local", "state": st,
                     "ks": ks, "B": B, "D": D, "I": I,
                     "macs_per_group": B * D * I * R / float(g)}
    return gu


if __name__ == "__main__":
    RUNS = [
        # label,            run dir,          B,   D,    I,    prec,   R
        # R = MATMUL_REPEAT passes inside the timed region. These local ladder ELFs do NOT use
        # the repeat loop -- verified from the logs: bench-window count ~= cycles/1000
        # (r256 17 windows / 16,748 cyc; both 18 / 17,503). Passing R=16 here made
        # macs_per_group 16x too large and every progress bar read ~16x low.
        ("r256 KS=1 ROB0=256", "r256_run_ks1", 8, 128, 8192, "fp16", 1),
        ("both KS=1 ROB0=128", "both_run_ks1", 8, 128, 8192, "fp16", 1),
    ]
    gu = collect(RUNS)
    gu = collect_fleet(gu)
    out = os.path.join("/tmp/claude-620771", "ks_group_util.json")
    json.dump(gu, open(out, "w"))
    for k, v in gu.items():
        print("  %-24s groups=%-3d windows=%-4d shape=%s" % (k, v["groups"], len(v["periods"]), v["shape"]))
    print("wrote %s (%d bytes)" % (out, os.path.getsize(out)))
