#!/usr/bin/env python3
"""Keep a simulator pool working right up to its reserve line, without crossing it.

Idle seats are pure loss: a licence nobody is using finishes no arm. But the reserve is a promise
to other people on a shared server, so the line is a hard floor, not a target to drift through.
This reads the pool, computes room = issued - in_use - reserve, and hands that many QUEUED arms to
the backend. It never decides how many actually run -- the submitted batch carries the client's own
governor, which re-checks the pool at dispatch.

Generalised from vcs_topup.py, which was VCS-only. The two pools differ in every constant that
matters -- Questa's binding feature is mtiverification (200 seats, and it checks out msimhdlsim as
well), VCS's is VCS-Base-Runtime-Pkg (100) -- and Questa needs ~16 GB against VCS's ~2 GB, so a
node fits far fewer of them. Those live in BACKENDS below; the logic is identical.

Never moves an arm that is already executing, already finished, or already queued for the SAME
backend: "not running" is true of an arm this script queued twenty minutes ago, and without that
last check the VCS version re-picked the same arms every cycle and double-submitted nine of them.

Moving an arm queued for the OTHER backend is deliberate and is the whole point -- an arm sitting
behind a full VCS pool should start now on a free Questa seat. If both copies eventually start,
kill_duplicate_arms.py keeps the one with more progress. Cancelling the old queued copy instead
would be worse: it nudges the scheduler into dispatching another job from that batch (measured; see
KNOWN_ISSUES).
"""
import argparse, glob, json, os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from feasibility import stalling, KNOWN_STALL, fits, projected_hours, delivered

ROOT   = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC"
STATE  = os.path.expanduser("~/badist/state")
CLIENT = os.path.join(ROOT, "scripts/badist/teranoc_fleet.py")

BACKENDS = {
    # reserve 2 (was 5, briefly 3) -- user decision 2026-08-23: leave 2 VCS seats for others.
    # VCS reserve: 5 -> 3 -> 2 over the session as the user revised it; 2 is the CURRENT figure
    # ("from now on we only leave 2 free vcs license for other people", 2026-08-23). A concurrent
    # session restored 5 from an earlier message it had seen; do not re-raise it without checking
    # the latest instruction.
    "vcs": dict(feature="VCS-Base-Runtime-Pkg", server="8169@lic-synopsys.ethz.ch",
                # reserve 5: the user's explicit instruction is to leave 5 VCS seats for other
                # people (and 10 Questa). 73954d49 lowered this to 2; restoring the stated
                # policy. If 2 was deliberate, it needs to come from the user, not from us.
                reserve=2, image="build_vcs_8x8/mempool_simvopt", mem_gb=12,
                name="s8vtop", max_parallel=30),
    # mtiverification is the binding Questa feature (200 seats); msimhdlsim has 400 and never runs
    # out first. Governing on msimhdlsim alone once let us take 150 of the 200 while the tool
    # reported plenty free and colleagues were locked out.
    # image MUST be build_q_8x8, and the client default (build_bp_q) is wrong for this campaign.
    #
    # This was the real cause of the rc=12 / "Error loading design" failures, after two wrong
    # diagnoses. build_q_8x8 holds a PRE-ELABORATED design (s8_opt); build_bp_q does not. Naming a
    # build without it makes vsim run an implicit vopt that takes the shared work/ library lock, so
    # the first arm elaborates while the rest wait and give up after exactly 16:42. Evidence: all
    # 100 healthy Questa arms run build_q_8x8 + s8_opt; every arm submitted with the default failed.
    #
    # It was NOT burst contention (max_parallel was cut 30 -> 4 on that theory; 3 arms at 4 still
    # failed 3/3) and NOT the stale locks (those were real and removed, but sat in build_q_8x8 while
    # the failing arms blocked on a LIVE holder in build_bp_q). max_parallel returns to 30: with a
    # pre-elaborated design there is no vopt, so nothing serialises on the lock.
    "questa": dict(feature="mtiverification", server="8161@lic-mentor.ethz.ch",
                   reserve=10, image="build_q_8x8", mem_gb=17,
                   name="s8qtop", max_parallel=30),
}


def seats(server, feature):
    try:
        out = subprocess.check_output(["lmutil", "lmstat", "-c", server, "-f", feature],
                                      stderr=subprocess.STDOUT, text=True, timeout=120)
    except Exception:
        return None
    m = re.search(r"Total of (\d+) licenses? issued;\s*Total of (\d+) licenses? in use", out)
    return (int(m.group(1)), int(m.group(2))) if m else None


# A queued job moves only while ITS OWN submit controller lives; once that process exits its
# queue is stranded forever. Those arms still look "already queued on this backend", so the skip
# below refused to move them and the pool sat over its idle line with arms waiting -- which needed
# a manual --allow-requeue every time the watchdog fired.
# The liveness signal is the batch's dispatch/ directory mtime: an active controller touches it as
# it places jobs. Measured 2026-08-23: of 40 batches holding queued 8x8 arms, 39 were stale by
# hours to days (up to 30 h) and exactly one was recent. A batch that is merely FINISHED dispatching
# has no queued jobs left, so it never reaches this test.
STALE_MIN = 45


def _stranded(d):
    """True if this batch still has queued jobs but no controller has touched it recently."""
    dd = os.path.join(d, "dispatch")
    try:
        return (time.time() - os.path.getmtime(dd)) / 60.0 > STALE_MIN
    except OSError:
        return True          # no dispatch dir at all -- nothing ever placed from here


def survey(backend):
    """running arms, queued arms (in order), and those already queued for THIS backend.

    An arm queued in a stranded batch is NOT counted as waiting on the backend: nothing will ever
    dispatch it, so a fresh controller must.
    """
    running, queued, on_backend = set(), [], set()
    for d in sorted(glob.glob(os.path.join(STATE, "*"))):
        jf = os.path.join(d, "jobs.json")
        if not os.path.exists(jf):
            continue
        try:
            jobs = json.load(open(jf))
        except Exception:
            continue
        stranded = _stranded(d)
        started = {os.path.basename(f)[:-6] for f in glob.glob(os.path.join(d, "jobs", "*.jsonl"))}
        for j in jobs:
            m = j.get("meta") or {}
            a = m.get("arm", "")
            if not a.startswith(("fp16_", "fp32_")):
                continue
            if j["job_id"] not in started:
                queued.append(a)
                if (m.get("backend") or "questa") == backend and not stranded:
                    on_backend.add(a)
                continue
            last = None
            for ln in open(os.path.join(d, "jobs", j["job_id"] + ".jsonl")):
                try:
                    last = json.loads(ln)
                except Exception:
                    pass
            if last and last.get("state") == "running":
                running.add(a)
    return running, queued, on_backend


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=sorted(BACKENDS), required=True)
    ap.add_argument("--reserve", type=int)
    ap.add_argument("--batch", type=int, default=12)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--margin", type=int, default=2,
                    help="extra seats to leave beyond the reserve, to absorb concurrent dispatch "
                         "by our own other controllers (see the note where room is computed)")
    ap.add_argument("--allow-requeue", action="store_true",
                    help="also pick arms already queued for this backend. Use when the pool sits "
                         "above its reserve line while arms wait: an existing batch at its own "
                         "--max-parallel will not dispatch into a free seat no matter how many "
                         "there are, and a fresh batch has its own cap. Costs a duplicate queued "
                         "copy, which kill_duplicate_arms.py resolves if both ever start.")
    a = ap.parse_args()
    cfg = BACKENDS[a.backend]
    reserve = cfg["reserve"] if a.reserve is None else a.reserve

    s = seats(cfg["server"], cfg["feature"])
    if not s:
        print("  could not read the %s pool -- doing nothing" % a.backend)
        return 0
    issued, in_use = s
    # Margin for our OWN concurrent controllers. Every live `submit` re-checks the pool at
    # dispatch, so several of them can each see the same free seats and each place an arm into
    # them. Measured 2026-08-23: room computed as 4 at 186/200, we placed 4, and the pool landed
    # at 193 -- ours went 124 -> 128 while others FELL by one, so the extra three were our own
    # s8big controller (--max-parallel 80) draining its queue in the same window. That put us 3
    # seats past a reserve line the user promised to colleagues.
    # The margin costs no throughput: the seats it declines are the ones another of our
    # controllers is about to take anyway. It only stops us claiming them twice.
    room = issued - in_use - reserve - a.margin
    print("  %s %s %d/%d in use, reserve %d (+%d margin) -> room for %d"
          % (a.backend, cfg["feature"], in_use, issued, reserve, a.margin, room))
    if room <= 0:
        print("  pool is at the reserve line; nothing to add")
        return 0

    running, queued, on_backend = survey(a.backend)

    # NO queue-depth guard here. One was added and reverted the same hour: it skipped whenever
    # the backend already held more than room+8 queued arms, which with 182 queued on Questa
    # meant it refused to place arms into REAL free seats -- 5 seats idle with 8 arms waiting.
    # The case it was meant to fix (topping up a pool that is already full) is handled above by
    # the room<=0 early return; the churn it was reacting to was legitimate dispatch.

    pick, seen = [], set()
    for arm in queued:
        if arm in running or arm in seen or (arm in on_backend and not a.allow_requeue):
            continue
        if stalling(arm):
            announce_once("stall:" + arm,
                          "  KNOWN-STALL %-22s %s -- held back, needs the hold-window experiment"
                          % (arm, KNOWN_STALL[arm]))
            continue
        if not fits(arm):
            # Do not hand a seat to a shape the deadline cannot hold: it runs the full 48h and
            # then fails. The top-up moved fp16_2048x1024x1024 (~200 h projected) to VCS before
            # this guard existed.
            continue
        if delivered(arm):
            continue              # already recorded; re-running it wastes a seat
        seen.add(arm); pick.append(arm)
        if len(pick) >= min(a.batch, room):
            break
    if not pick:
        print("  no queued arm is free to move (%d already waiting on %s)"
              % (len(on_backend), a.backend))
        return 0
    print("  moving %d queued arm(s) to %s: %s%s"
          % (len(pick), a.backend, ", ".join(pick[:4]), " ..." if len(pick) > 4 else ""))
    if a.dry_run:
        print("  --dry-run: not submitting")
        return 0

    lst = "/tmp/claude-620771/arms_%s_topup.txt" % a.backend
    with open(lst, "w") as f:
        for arm in pick:
            img = (" " + cfg["image"]) if cfg["image"] else ""
            f.write("%s s8_%s.elf%s\n" % (arm, arm, img))
    cmd = [CLIENT, "submit", "--arms", lst, "--backend", a.backend,
           "--run-prefix", "s8", "--name", cfg["name"],
           "--max-parallel", str(cfg["max_parallel"]), "--mem-gb", str(cfg["mem_gb"]),
           "--reserve-licenses", str(reserve), "--est-runtime-s", "60000",
           "--timeout-s", "2592000", "--force"]
    p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=120)
    except subprocess.TimeoutExpired:
        out = "(controller running in background -- expected)"
    for ln in (out or "").splitlines():
        if "batch" in ln or "rror" in ln:
            print("  %s" % ln)
    return 0


if __name__ == "__main__":
    sys.exit(main())
