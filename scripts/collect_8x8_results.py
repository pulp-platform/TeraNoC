#!/usr/bin/env python3
"""Scrape delivered 8x8 arm transcripts into docs/benchmarks/8x8_scaleup/results.tsv.

Keyed on the run-prefix on disk (hardware/s8_<arm>/transcript), so it is batch-agnostic and
picks up every wave without being told which batches exist.

Two habits this file exists to enforce:
  * strip QuestaSim's leading "# " before ANY anchored match -- VCS logs have no such prefix, so
    a pattern like ^\\[FPU\\] silently matches zero lines on a Questa arm and that arm reads as
    "no data" rather than "wrong filter".
  * record the spotcheck GROUP COUNT, not just presence. A perf number with no correctness
    signal is not a result; a kernel that computes garbage faster still wins a sweep.
"""
import os, re, sys

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
OUT  = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/results.tsv")
MANI = os.path.join(ROOT, "docs/benchmarks/8x8_scaleup/manifest.txt")
HDR  = ("shape\tprec\tA_share\tcycles\tfpu_util\tRH\tmshr_timeout\tbankfull"
        "\tspotcheck\tstate")

def a_share(M):
    # at 8x8 the A-row sharing degree is set by M alone
    return {512: 16, 1024: 8, 2048: 4, 4096: 2}.get(M, 1)

def scrape(arm):
    t = os.path.join(ROOT, "hardware", "s8_" + arm, "transcript")
    if not os.path.exists(t):
        return None
    raw = open(t, "rb").read()
    # normalise the Questa prefix once, here, before anything anchored runs
    txt = b"\n".join(l[2:] if l.startswith(b"# ") else l for l in raw.split(b"\n"))
    cyc = re.findall(rb"execution took (\d+)", txt)
    if not cyc:
        return dict(state="running")
    def tot(tag):
        return sum(int(x) for x in re.findall(tag.encode() + rb"=\+?(\d+)", txt))
    # The kernel's printf reaches the transcript through the UART model, which prefixes it:
    # the line is "[UART] [SPOT] g= 0 ...", so an anchored ^\[SPOT\] matches ZERO and every arm
    # reads as MISSING. Same class as the QuestaSim "# " prefix -- a prefix I guarded against and
    # a second one I did not know about. Do not anchor on a payload tag; allow the carrier.
    spot = len(re.findall(rb"^(?:\[UART\] )?\[SPOT\] g=", txt, re.M))
    # A run killed by $fatal still prints "execution took N" if the benchmark finished first, so
    # the cycle count can be real while everything after it (the spotcheck) is missing. That must
    # never be recorded as a clean completion.
    # $fatal is worded DIFFERENTLY per simulator, and 213 of 248 arms are on Questa:
    #   VCS    : $finish called from file ".../mempool_group_mshr.sv", line 2258.
    #   Questa : ** Fatal: <msg>   /  ** Note: $finish : .../mempool_group_mshr.sv(2247)
    # A VCS-only pattern silently reports every Questa arm as a clean completion.
    fat = (re.search(rb'\$finish called from file [^\n]*?([A-Za-z0-9_]+\.sv)", line (\d+)', txt)
           or re.search(rb'\$finish[^\n]*?([A-Za-z0-9_]+\.sv)\((\d+)\)', txt))
    fmsg = re.search(rb"(MSHR clock gate dropped[^\n]*|\*\* Fatal: [^\n]{0,110}|Fatal: [^\n]{0,110})", txt)
    # Whole-run FPU utilisation, from the TB's end-of-benchmark summary:
    #   [FPU FINAL] busy=<n> of <d> lane-cycles over <c> benchmark cycles -> util=25.89%
    # This is the summary line, NOT the per-period [FPU] samples -- those oscillate and their
    # cumulative value is a running average that keeps moving. Printed before a $fatal kill, so
    # it survives on the arms the assertion terminates.
    u = re.search(rb"\[FPU FINAL\][^\n]*?util=([0-9.]+)%", txt)
    util = float(u.group(1)) if u else None
    recon_w = 0
    if util is None:
        # A SALVAGED arm has no [FPU FINAL]: the program finished, but the sim was parked at the
        # vsim prompt and never reached the $finish that prints it. Rebuild the same quantity from
        # the per-period [FPUG] lines, which carry both a bench/pre tag and their own denominator:
        #   FINAL = busy_cum / (active_cyc * lanes);  each bench window contributes
        #   sum_g(busy[g]) over denom*NumGroups lane-cycles.
        # Only "bench" windows count -- including the "pre" ones was what made an earlier attempt
        # disagree with FINAL. Validated on the 35 arms that have both: mean error 1.10 pp, and the
        # error is pure window quantisation, scaling as 1/windows (1.61 pp mean below 20 windows,
        # 0.15 pp above 80) because the benchmark region does not land on window boundaries.
        # Reported with a leading "~" so a reconstructed value can never be read as a measured one.
        num = den = 0
        for m in re.finditer(rb"\[FPUG\]\s+(\S+)\s+cyc=\d+\s+denom=(\d+)\s+busy=\s*([0-9, ]+)", txt):
            if m.group(1) != b"bench":
                continue
            v = [int(x) for x in m.group(3).split(b",") if x.strip()]
            num += sum(v); den += int(m.group(2)) * len(v); recon_w += 1
        if den:
            util = 100.0 * num / den
    return dict(state="done", cycles=int(cyc[-1]), rh=txt.count(b"RH STUCK"),
                tmo=tot("mshr_timeout"), bf=tot("bankfull_bypass"), spot=spot,
                util=util, util_recon=(u is None and util is not None), recon_w=recon_w,
                fatal=(fat.group(1).decode() + ":" + fat.group(2).decode()) if fat else "",
                fmsg=fmsg.group(1).decode()[:90] if fmsg else "")

def main():
    rows, ndone, fatals, unverified, partial = [], 0, [], [], []
    for ln in open(MANI):
        p = ln.split()
        if len(p) != 4:
            continue
        M, N, P, PR = int(p[0]), int(p[1]), int(p[2]), p[3]
        arm = "fp%s_%dx%dx%d" % (PR, M, N, P)
        r = scrape(arm)
        if not r or r["state"] != "done":
            continue
        ndone += 1
        # 64 groups at 8x8: fewer [SPOT] lines than groups means the probe did not complete
        # fp32 has NO spotcheck by construction: all 150 fp16 apps carry the [SPOT] probe and
        # 0 of 122 fp32 apps do, and fp32's only other check (MATMUL_VERIFY) is off by default
        # because it wedges core 0. Flagging those as MISSING would mark half the campaign
        # "do not quote" for a probe that was never compiled in -- and, worse, would hide the
        # real point: fp32 arms carry NO correctness signal at all.
        if PR == "32":
            sc = "n/a(fp32:no-probe)"
            unverified.append(arm)
        elif r["spot"] >= 64:
            sc = "ok(%d)" % r["spot"]           # never yet observed -- see below
        elif r["spot"] >= 1:
            # The probe loops g=0..active_groups-1 (64 at 8x8, 16 at 4x4) but ALWAYS emits exactly
            # one line: core 0 wedges reading group 1's remote C address and never returns. Proven
            # on an assertion-free 4x4 run, which idled 840k further cycles (113k->953k) with every
            # counter at zero and no second line. So real coverage is GROUP 0 ONLY.
            # Gating on 64 would mark every fp16 arm PARTIAL forever -- a threshold the probe
            # cannot reach is not a correctness signal, it is a broken test reported as data.
            sc = "grp0-only(%d)" % r["spot"]
            partial.append(arm)
        else:
            sc = "MISSING"
        if r.get("fatal"):
            sc += "+FATAL@" + r["fatal"]
            fatals.append((arm, r["fatal"], r.get("fmsg", "")))
        rows.append("%dx%dx%d\tfp%s\t%d\t%d\t%s\t%d\t%d\t%d\t%s\tdone"
                    % (M, N, P, PR, a_share(M), r["cycles"],
                       (("~%.2f" if r.get("util_recon") else "%.2f") % r["util"])
                       if r["util"] is not None else "-",
                       r["rh"], r["tmo"], r["bf"], sc))
    # MERGE with what is already recorded, never regenerate blind.
    #
    # This file is rebuilt from the transcripts on disk, and a transcript can be DESTROYED after it
    # was delivered: badist writes hardware/s8_<arm>/transcript unconditionally, so a duplicate or
    # rescued copy that starts later overwrites a finished result with its own partial one. The row
    # then vanishes on the next scrape and the arm silently reverts to "not done".
    # Observed once: fp16_2048x64x256 was recorded at 14,186 cycles in two commits and then
    # disappeared when a later copy delivered a partial transcript over the salvaged one.
    # A delivered measurement is not re-derivable, so a row is only ever added or updated here --
    # never dropped because the evidence behind it went missing.
    prev = {}
    try:
        with open(OUT) as f:
            for ln in f.read().splitlines()[1:]:
                p_ = ln.split("\t")
                if len(p_) > 3:
                    prev[(p_[0], p_[1])] = ln
    except OSError:
        pass
    have = {(r.split("\t")[0], r.split("\t")[1]) for r in rows}
    kept = [ln for k, ln in prev.items() if k not in have]
    if kept:
        print("  kept %d earlier row(s) whose transcript is no longer on disk: %s"
              % (len(kept), ", ".join("%s_%s" % (k[1], k[0]) for k in prev if k not in have)))
        rows.extend(kept)
    rows.sort(key=lambda s: int(s.split("\t")[3]))
    with open(OUT, "w") as f:
        f.write(HDR + "\n")
        for r in rows:
            f.write(r + "\n")
    print("  results.tsv: %d completed arm(s)" % ndone)
    if fatals:
        print("  KILLED BY $fatal (cycle count may be real, everything after it is not):")
        for a, w, m in fatals:
            print("    %-26s %s  %s" % (a, w, m))
    # grp0-only is the probe's NORMAL (broken) behaviour, so it must not land in the
    # "do not quote" list -- that would flag every fp16 arm forever, the exact blanket the
    # previous commit removed from the gate. Only a genuinely absent probe belongs here.
    bad = [r for r in rows if "MISSING" in r.split("\t")[8]]
    if bad:
        print("  fp16 arms with NO [SPOT] output at all (probe absent or run died before it):")
        for r in bad:
            print("    " + "\t".join(r.split("\t")[:2] + [r.split("\t")[8]]))
    if partial:
        print("  %d fp16 arm(s) verified on GROUP 0 ONLY: the [SPOT] loop hangs core 0 after the"
              " first group, so 1 of %s groups is checked, not all of them." % (len(partial), 64))
    if unverified:
        print("  %d fp32 arm(s) have NO correctness signal at all (no [SPOT] probe in any fp32"
              " app; MATMUL_VERIFY is off because it wedges core 0). Perf data only."
              % len(unverified))

main()
