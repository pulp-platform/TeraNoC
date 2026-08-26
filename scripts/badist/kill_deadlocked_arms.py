#!/usr/bin/env python3
"""Retire arms that are permanently quiescent (the deadlock class), carefully.

An arm in this class has every FPU lane idle across all 64 groups, no RH episodes, no MSHR
timeouts, and bank links idle rather than stalled. It cannot recover and cannot print
`execution took`, so it holds its seat until the wall clock kills it and is then re-dispatched
forever. See docs/benchmarks/8x8_scaleup/quiescent_deadlock.md.

SAFETY -- this kills the user's running simulations, so every arm must clear ALL of:

  1. no `execution took` in its transcript (it has not finished);
  2. `busy=0` on the last [FPU] bench line (no FPU work at this instant);
  3. TWO samples separated by --settle seconds show the simulated cycle ADVANCING while
     `busy` stays 0 and cumulative utilisation does not rise. Time passing with no work is the
     discriminator between "stuck" and "slow"; a single sample cannot tell those apart.
  4. the run dir resolved from the ledger matches the arm (guards against killing a neighbour).

Then, and only then: cancel the badist job, and kill the simulator by PID verified against
/proc/PID/cwd -- `badist cancel` and `pkill` both hit the wrapper, and QuestaSim's vsimk carries
neither the arm name nor the build dir on its command line, so it survives both.
"""
import argparse, json, os, re, subprocess, sys, time

ROOT = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE = os.path.expanduser("~/badist/state")
BENCH = re.compile(r"\[FPU\]\s+\w+\s+cyc=(\d+)\s+util=([0-9.]+)%\s+cum=([0-9.]+)%\s+busy=(\d+)/")


def sh(host, cmd, timeout=90):
    try:
        r = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                            host, cmd], capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def running_arms():
    """arm -> (batch, job, node). Newest batch wins; only state==running."""
    out = {}
    import glob
    for d in sorted(glob.glob(os.path.join(STATE, "*")), key=os.path.getmtime, reverse=True):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        for j in jobs:
            m = j.get("meta") or {}
            a = m.get("arm", "")
            if not a.startswith(("fp16_", "fp32_")) or a in out:
                continue
            st = node = None
            try:
                for ln in open(os.path.join(d, "jobs", j["job_id"] + ".jsonl")):
                    r = json.loads(ln)
                    st = r.get("state") or st
                    node = r.get("node") or node
            except OSError:
                continue
            if st == "running" and node:
                out[a] = (os.path.basename(d), j["job_id"], node)
    return out


def sample(node, batch, job):
    """(cyc, util, cum, busy, finished) from the live transcript, or None."""
    cmd = ("D=$(ls -d /scratch*/zexifu_cache/badist/run/%s/%s 2>/dev/null|head -1); "
           "[ -n \"$D\" ] || exit; T=$D/transcript; "
           "grep -acm1 'execution took' $T; "
           "sed 's/^# //' $T | grep -a '\\[FPU\\]' | tail -1" % (batch, job))
    out = sh(node, cmd)
    if not out:
        return None
    lines = out.splitlines()
    fin = lines[0].strip() not in ("0", "")
    m = BENCH.search(out)
    if not m:
        return None
    return (int(m.group(1)), float(m.group(2)), float(m.group(3)), int(m.group(4)), fin)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settle", type=int, default=120,
                    help="seconds between the two progress samples")
    ap.add_argument("--max-util", type=float, default=5.0)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    arms = running_arms()
    print("running arms: %d" % len(arms))

    first = {}
    for arm, (b, j, node) in sorted(arms.items()):
        s = sample(node, b, j)
        if s and not s[4] and s[3] == 0 and s[2] < a.max_util:
            first[arm] = (b, j, node, s)
    print("candidates after sample 1 (busy=0, cum<%.1f%%, unfinished): %d" % (a.max_util, len(first)))
    if not first:
        return
    for arm in sorted(first):
        print("   %-26s %-10s cyc=%s cum=%.2f%%" % (arm, first[arm][2],
                                                    "{:,}".format(first[arm][3][0]), first[arm][3][2]))

    print("\nwaiting %ds for the second sample ..." % a.settle)
    time.sleep(a.settle)

    doomed = []
    for arm, (b, j, node, s1) in sorted(first.items()):
        s2 = sample(node, b, j)
        if not s2:
            print("  SKIP %-26s second sample unreadable" % arm); continue
        if s2[4]:
            print("  SKIP %-26s it FINISHED between samples" % arm); continue
        if s2[3] != 0:
            print("  SKIP %-26s busy=%d -- doing work now" % (arm, s2[3])); continue
        if s2[2] > s1[2] + 0.01:
            print("  SKIP %-26s cum util RISING %.2f -> %.2f" % (arm, s1[2], s2[2])); continue
        if s2[0] <= s1[0]:
            print("  SKIP %-26s simulated cycle NOT advancing (%s -> %s) -- host may be stalled, "
                  "not the arm" % (arm, s1[0], s2[0])); continue
        print("  STUCK %-26s %-10s cyc %s -> %s, busy=0 both, cum %.2f%% flat"
              % (arm, node, "{:,}".format(s1[0]), "{:,}".format(s2[0]), s2[2]))
        doomed.append((arm, b, j, node, s2))

    print("\nconfirmed deadlocked: %d" % len(doomed))
    if a.dry_run:
        print("--dry-run: nothing cancelled or killed")
        return
    for arm, b, j, node, s in doomed:
        subprocess.run([os.path.expanduser("~/badist/bin/badist"), "cancel", b, "--job", j],
                       capture_output=True, text=True, timeout=120)
        killed = sh(node,
                    "for p in $(pgrep -u $USER -x vsimk; pgrep -u $USER -x simv); do "
                    "  d=$(readlink /proc/$p/cwd 2>/dev/null); "
                    "  case \"$d\" in */%s/%s) kill $p && echo killed=$p;; esac; done" % (b, j))
        print("  %-26s cancelled; %s" % (arm, killed or "no simulator matched its cwd"))


if __name__ == "__main__":
    main()
