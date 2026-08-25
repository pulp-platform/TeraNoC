#!/usr/bin/env python3
"""teranoc_fleet -- run TeraNoC RTL simulations on the badile fleet.

`badist` (~/badist, from msc26f31) is the *service*: it knows about hosts, jobs,
resources and results, and nothing about simulators. This file is the TeraNoC
*client*. Everything domain-specific lives here:

  * what an "arm" is (a name + an ELF, run against one simulator image),
  * how each backend is invoked (VCS `+PRELOAD=`, Verilator `--meminit=ram,`),
  * which FlexLM feature the VCS simv actually holds -- `VCS-Base-Runtime-Pkg`,
    NOT the `VCSRuntime_Net` in badist's README, which does not exist on our
    server (checked with `lmutil lmstat -c 8169@lic-synopsys.ethz.ch -a`), and
  * the part that makes the fleet a drop-in replacement for a local sweep:
    every result is unpacked back into `hardware/<prefix>_<arm>/transcript`,
    exactly where gen_fp16_sweep_dash.py and friends already look. Nothing
    downstream of the simulator has to know the run happened on another machine.

Usage
-----
    scripts/badist/teranoc_fleet.py submit --shapes scripts/gemm_sweep_shapes.txt \
        --elf-template 'i2_{prec}_{shape}.elf' --run-prefix run6 --dry-run
    scripts/badist/teranoc_fleet.py submit --arms my_arms.txt --run-prefix run6
    scripts/badist/teranoc_fleet.py status
    scripts/badist/teranoc_fleet.py fetch            # unpack into hardware/<prefix>_<arm>/
    scripts/badist/teranoc_fleet.py license          # VCS runtime-seat headroom

Python 3.6-compatible and stdlib-only, like badist itself: the controller has to
run from whichever machine you are sitting at.
"""

from __future__ import print_function

import argparse
import json
import time
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------- locations

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HW = os.path.join(REPO, "hardware")
BADIST_HOME = os.path.expanduser("~/badist")
BADIST_BIN = os.path.join(BADIST_HOME, "bin", "badist")
SPEC_DIR = os.path.join(HW, "badist_specs")

# The VCS runtime feature our simv actually checks out. Verified by
#   lmutil lmstat -c 8169@lic-synopsys.ethz.ch -f VCS-Base-Runtime-Pkg
# while our own sims were running. 100 seats department-wide, and a multi-hour
# arm holds one for its whole life -- so a fan-out without a governor can take
# the pool out from under everybody.
VCS_LICENSE_FEATURE = "VCS-Base-Runtime-Pkg"
VCS_LICENSE_SERVER = "8169@lic-synopsys.ethz.ch"

# QuestaSim's pool is a different order of magnitude: 400 msimhdlsim seats against VCS's
# 100, and measured 106 in use department-wide while VCS sat at 100/100. That is what
# makes Questa the fallback rather than the thing we wait for -- and cycle counts are
# validated bit-identical between the two (91,859 both), so results pool with VCS arms.
QUESTA_LICENSE_FEATURE = "msimhdlsim"
# A Questa run checks out BOTH of these, and msimhdlsim is NOT the binding one:
#   msimhdlsim       400 seats
#   mtiverification  200 seats   <-- the real ceiling
# Governing on msimhdlsim alone reported "158 free" while mtiverification sat at 200/200 and
# colleagues could not start Questa at all. We held 150 of its 200 seats before anyone noticed.
# Always take the TIGHTEST of the two.
QUESTA_LICENSE_FEATURES = ("msimhdlsim", "mtiverification")
QUESTA_LICENSE_SERVER = "8161@lic-mentor.ethz.ch"
# ABSOLUTE path, not a bare name. badist runs the job in a NON-LOGIN shell whose PATH is
# /usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin -- /usr/sepp/bin is not on it, so a bare
# name fails with rc=127 on EVERY node (verified badile/larain/fenga 2026-08-22). VCS never hit
# this because its spec runs the elaborated simv binary by absolute path and needs nothing on
# PATH. Worse, the wrapper's retry loop reports any early exit as "no licence seat?", so the
# failure looked like licence pressure and burned 12 x 300 s of a held slot.
QUESTA_CMD = "/usr/sepp/bin/questa-2023.4-zr"
# Pre-elaborated design in the shared work library (see questa_launch). Falls back to the
# module name only if you rebuild the library without running the vopt step.
QUESTA_OPT = "s8_opt"
DRAMSYS = "deps/dram_rtl_sim/dramsys_lib/DRAMSys"

BACKENDS = {
    # image: default simulator binary, relative to hardware/
    # cmd:   how the arm is launched, {image}/{elf} substituted by us
    # mem_gb: measured peak RSS plus headroom
    "vcs": {
        "image": "build_vcs_fix/mempool_simvopt",
        # {licwait} becomes "+vcs+lic+wait" only when there is NO fallback. That flag
        # makes a seat-starved simv QUEUE instead of exiting -- which is right when
        # waiting is the only option (it is how 38 of 61 arms of a local sweep vanished
        # silently on 2026-08-21: refused, dead in seconds, stderr sent to /dev/null),
        # and exactly wrong when a fallback simulator is available, because a queued
        # simv never fails and the fallback would never fire.
        # +notracer: the per-flit NoC tracer (tb_noc_req_resp_tracer.svh:100) writes
        # noc_trace/events.csv -- ~30 GB per NODE, none of which the result scrape reads
        # (the job collects only `transcript`). It filled larain12 to 100% on 2026-08-24
        # and came within ~45 min of killing three day-old arms. It has a RUNTIME
        # disable, so this costs nothing and needs no rebuild. The other two producers
        # (trace_hart_*.dasm ~48 GB via SNITCH_TRACE, v4m_out ~8 GB via V4M_ENABLE) are
        # build-time and want snitch_trace=0 / +define+V4M_ENABLE=0 at the next rebuild.
        "cmd": '"{image}" {licwait}+notracer +PRELOAD="{elf}" -l transcript',
        "mem_gb": 4,          # measured 2.0 GB across every running terapool arm
        "licensed": True,
        # SINGLE SOURCE OF TRUTH for the VCS courtesy line. 2 is the user's current figure
        # (5 -> 3 -> 2 over 2026-08-23). It lives here because only sim_topup passed
        # --reserve-licenses; auto_resubmit, rescue_orphans, heal_stuck_arms and vcs_topup all
        # fell through to this default, so they were stopping at 5 free while the top-up filled
        # to 2 -- the submitters disagreed about where the line was, which showed up as seats
        # sitting idle AND the pool hovering at the line at the same time.
        "reserve_default": 2,
        "feature": VCS_LICENSE_FEATURE,
        "server": VCS_LICENSE_SERVER,
    },
    "questa": {
        # `image` here is a compiled BUILD DIRECTORY (work/ + work-dpi/ + modelsim.ini),
        # not an executable -- build one with
        #   make -o update-floogen compile config=terapool_spatz4_fpu \
        #        buildpath=build_bp_q group_mshr_merge_reqs=16
        # and check its +define+ set against the VCS image before trusting a mixed sweep.
        "image": "build_bp_q",
        "cmd": None,               # built by questa_launch(): it needs a prelude
        "mem_gb": 20,              # measured 15.9 GB headless (24.3 GB with wave logging)
        "licensed": True,
        "feature": QUESTA_LICENSE_FEATURE,
        "features": QUESTA_LICENSE_FEATURES,   # msimhdlsim AND mtiverification
        "reserve_default": 10,                 # always leave 10 mtiverification seats for others
        "server": QUESTA_LICENSE_SERVER,
        "dir_image": True,
    },
    "verilator": {
        # A single self-contained 456 MB executable (4x4); only system libs. No
        # license at all, which is the whole point of having it here. Verilator
        # is known good at 4x4 and known to fail at 8x8 -- do not reach for it
        # to run an 8x8 mesh.
        "image": "vbuild_4x4/Vmempool_tb_verilator",
        "cmd": '"{image}" --meminit=ram,"{elf}" 2>&1 | tee transcript',
        "mem_gb": 8,          # not yet measured on the fleet; refine from `badist stats`
        "licensed": False,
        "feature": None,
        "server": None,
    },
}


def questa_launch(build_dir, elf):
    """Shell lines that run one arm under QuestaSim against a SHARED compiled library.

    Symlinks rather than a copy: the library is 1.4 GB and read-only during simulation,
    so N arms can share one build directory -- while every transcript, WLF and
    trace_hart_*.dasm still lands in the job's own directory, where concurrent arms on
    the same node cannot clobber each other.
    """
    dram = os.path.join(HW, DRAMSYS)
    return [
        'ln -sfn "%s/work" work' % build_dir,
        'ln -sfn "%s/work-dpi" work-dpi' % build_dir,
        'cp -f "%s/modelsim.ini" .' % build_dir,
        # +acc REMOVED 2026-08-22 (user direction): it suppresses most optimisation, so the
        # simulation runs markedly slower, and hardware/Makefile records that at 1024 cores
        # "vopt alone did not finish in 60 minutes" with it.
        #
        # THE RISK IT TRADES AGAINST, kept here because the failure is SILENT: TB probes that
        # reach into the design hierarchically ([FPU], [FPUG], [MSHRG], [STALLG]) can have their
        # nets optimised away, and the run then completes normally while reporting NO DATA --
        # not an error. Do not read an empty-probe transcript as "the feature is off"; check
        # first that the probe emitted anything at all. Gate every questa arm on:
        #     grep -c '^\[FPU\]' transcript      # 0 => probes optimised away, rerun with +acc
        '%s vsim -c -suppress vsim-12070 '
        '+DRAMSYS_RES=%s/configs '
        '-sv_lib %s/build/lib/libsystemc -sv_lib %s/build/lib/libDRAMSys_Simulator '
        '-sv_lib work-dpi/mempool_dpi -work work '
        # work.s8_opt, NOT work.mempool_tb. Naming the module makes vsim run an IMPLICIT vopt that
        # WRITES a fresh optimised design into the SHARED work/ library -- measured: three runs made
        # three designs (_opt/_opt1/_opt2) at ~2.6 GB each, and two arms deadlocked on work/_lock
        # while a killed arm left the lock behind naming a dead pid. Naming the PRE-ELABORATED
        # design instead means no vopt, no lock, no growth, and no ~10 min per-arm elaboration.
        # Rebuild it after any RTL change:
        #   cd hardware/build_q_8x8 && questa-2023.4-zr vopt -work work work.mempool_tb -o s8_opt
        '+notracer +PRELOAD="%s" work.%s -do "run -a" -l transcript'
        % (QUESTA_CMD, dram, dram, dram, elf, QUESTA_OPT),
    ]


def die(msg):
    sys.stderr.write("teranoc_fleet: %s\n" % msg)
    sys.exit(1)


def warn(msg):
    sys.stderr.write("teranoc_fleet: warning: %s\n" % msg)


def _badist():
    """Import the service. It lives in $HOME so every node sees the same ledger."""
    if BADIST_HOME not in sys.path:
        sys.path.insert(0, BADIST_HOME)
    try:
        import badist
    except ImportError as e:
        die("cannot import badist from %s (%s).\n"
            "  Install it with: cp -r /home/msc26f31/badist ~/badist" % (BADIST_HOME, e))
    return badist


# ------------------------------------------------------------------- arms

class Arm(object):
    """One simulation: a name, an ELF, and the image to run it against."""

    def __init__(self, name, elf, image=None, meta=None):
        self.name = name
        self.elf = elf
        self.image = image
        self.meta = meta or {}


def arms_from_shapes(path, precisions, elf_template):
    """`M N P PREC` per line (scripts/gemm_sweep_shapes.txt) -> arms.

    Arm names match the local sweep convention `<prec>_<M>x<N>x<P>`, so a fleet
    run drops into the same `run<N>_<arm>` directories the scrapers already read.
    """
    arms = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 4:
                die("%s: cannot parse %r (want 'M N P PREC')" % (path, line))
            m, n, p, prec = parts[0], parts[1], parts[2], parts[3]
            if precisions and prec not in precisions:
                continue
            shape = "%sx%sx%s" % (m, n, p)
            arms.append(Arm(
                name="%s_%s" % (prec, shape),
                elf=elf_template.format(prec=prec, shape=shape, M=m, N=n, P=p),
                meta={"prec": prec, "shape": shape, "M": int(m), "N": int(n), "P": int(p)},
            ))
    return arms


def arms_from_file(path):
    """`<name> <elf> [image]` per line; '#' comments and blank lines ignored."""
    arms = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                die("%s: cannot parse %r (want '<name> <elf> [image]')" % (path, line))
            arms.append(Arm(parts[0], parts[1],
                            image=parts[2] if len(parts) > 2 else None))
    return arms


# -------------------------------------------------------------- preflight

def _abs_hw(path):
    """Resolve a path relative to hardware/, which is how we name images and ELFs."""
    return path if os.path.isabs(path) else os.path.join(HW, path)


def _fleet_visible(path):
    """Is this path on a filesystem every badile node can see?

    /usr/scratch/<host> and /home are automounted fleet-wide; /scratch, /tmp and
    a node's own /usr/scratch shorthand are not. A path that only exists here
    fails on every node with no error we would recognise as the cause.
    """
    real = os.path.realpath(path)
    return real.startswith("/usr/scratch/") or real.startswith("/home/")


def check_image(image, backend):
    """What has to be true of a simulator image for a fleet job to be able to run it."""
    out = []
    if not os.path.exists(image):
        return ["simulator image not found: %s" % image]
    if not _fleet_visible(image):
        out.append("simulator image is not on a fleet-visible path: %s" % image)

    if BACKENDS[backend].get("dir_image"):
        # QuestaSim's "image" is a compiled build directory, not a binary.
        if not os.path.isdir(image):
            return out + ["%s image must be a compiled build directory: %s"
                          % (backend, image)]
        for need in ("work", "work-dpi", "modelsim.ini"):
            if not os.path.exists(os.path.join(image, need)):
                out.append("%s build dir has no %s -- compile it first with "
                           "`make -o update-floogen compile ... buildpath=%s`"
                           % (backend, need, os.path.basename(image)))
        return out

    if not os.access(image, os.X_OK):
        out.append("simulator image is not executable: %s" % image)
    if backend == "vcs":
        # VCS links its archives with RPATH $ORIGIN/<image>.daidir, so the image is
        # relocatable -- but only together with that directory.
        daidir = image + ".daidir"
        if not os.path.isdir(daidir):
            out.append("VCS image has no %s next to it; the simv cannot resolve "
                       "its archives" % os.path.basename(daidir))
    return out


def preflight(arms, backend, default_image, run_prefix, force, fallback=None,
              fallback_image=None):
    """Refuse the submit for the mistakes that are silent rather than loud."""
    problems = []

    seen = {}
    for arm in arms:
        if arm.name in seen:
            problems.append("duplicate arm name %r -- both would land in the same "
                            "run directory" % arm.name)
        seen[arm.name] = True

    images = set()
    for arm in arms:
        image = _abs_hw(arm.image or default_image)
        arm.image = image
        images.add(image)
        elf = _abs_hw(arm.elf)
        arm.elf = elf

        if not os.path.exists(elf):
            problems.append("%s: ELF not found: %s" % (arm.name, elf))
        elif not _fleet_visible(elf):
            problems.append("%s: ELF is not on a fleet-visible path: %s" % (arm.name, elf))

        # hardware/Makefile resolves preload to the ONE shared software/bin path, and
        # the ELF is read at simulation time 0 -- not at launch. A rebuild while a
        # fleet job is still starting silently hands it the wrong workload.
        if os.sep + os.path.join("software", "bin") + os.sep in elf:
            problems.append("%s: ELF is under software/bin, which is rebuilt in place. "
                            "Copy it to a private path first (hardware/<name>.elf)." % arm.name)

        rundir = os.path.join(HW, "%s_%s" % (run_prefix, arm.name))
        arm.meta = dict(arm.meta)
        arm.meta.update({"arm": arm.name, "run_dir": rundir, "backend": backend})
        if os.path.isdir(rundir) and os.listdir(rundir) and not force:
            problems.append("%s: run dir already has content: %s (use --force to "
                            "overwrite, or pick another --run-prefix)" % (arm.name, rundir))

    for image in sorted(images):
        problems += check_image(image, backend)

    if fallback:
        # A fallback that is not actually usable is worse than none: every arm would run
        # the primary, fail, then fail again -- and only the stderr of 38 tarballs would
        # say why. Check it exactly as hard as the primary.
        fbi = _abs_hw(fallback_image or BACKENDS[fallback]["image"])
        problems += ["fallback: " + m for m in check_image(fbi, fallback)]

    if problems:
        for p in problems:
            sys.stderr.write("  ! %s\n" % p)
        die("%d preflight problem(s); nothing submitted" % len(problems))


# --------------------------------------------------------------- licenses

def license_free_multi(features, server):
    """Tightest (issued, in_use, mine) across several features on one server.

    A tool that consumes more than one feature is limited by the scarcest, so reporting any
    single feature overstates headroom -- by 2x for Questa, which is how this fleet came to hold
    150 of 200 mtiverification seats while its own governor reported plenty free.
    """
    worst = None
    for f in features:
        r = license_free(f, server)
        if r is None:
            continue
        if worst is None or (r[0] - r[1]) < (worst[0] - worst[1]):
            worst = r
    return worst


def license_free(feature=VCS_LICENSE_FEATURE, server=VCS_LICENSE_SERVER):
    """(issued, in_use, mine) for a FlexLM feature, or None if lmutil failed."""
    try:
        out = subprocess.check_output(
            ["lmutil", "lmstat", "-c", server, "-f", feature],
            stderr=subprocess.STDOUT, universal_newlines=True, timeout=90)
    except Exception:
        return None
    m = re.search(r"Users of %s:\s*\(Total of (\d+) licenses? issued;\s*"
                  r"Total of (\d+) licenses? in use" % re.escape(feature), out)
    if not m:
        return None
    me = os.environ.get("USER", "")
    mine = len(re.findall(r"^\s+%s " % re.escape(me), out, re.M)) if me else 0
    return int(m.group(1)), int(m.group(2)), mine


# ------------------------------------------------------------------- spec

def build_spec(args, arms):
    backend = BACKENDS[args.backend]

    fb = BACKENDS[args.fallback] if args.fallback else None
    fb_image = _abs_hw(args.fallback_image or fb["image"]) if fb else None

    def launch_lines(be, image, elf, licwait=False):
        """The shell lines that actually start one simulator."""
        if be is BACKENDS["questa"]:
            return questa_launch(image, elf)
        return [be["cmd"].format(image=image, elf=elf,
                                 licwait="+vcs+lic+wait " if licwait else "")]

    jobs = []
    for arm in arms:
        launch = launch_lines(backend, arm.image, arm.elf,
                              licwait=(fb is None and args.license_wait))
        lines = [
            "set -o pipefail",
            # Our local launchers raise this; a terapool arm opens a lot of files.
            "ulimit -n 8192 2>/dev/null || true",
            # {jobdir} renders to $BADIST_JOBDIR, expanded by the worker's bash on the
            # node -- each node picks its own scratch disk, so this cannot be baked in.
            'cd "{jobdir}"',
        ]
        if fb is not None:
            # THE POINT: a full licence pool must not mean waiting. Try the primary
            # simulator; if it exits before simulation time 0 -- the signature of a
            # refused seat, and the only thing a denied simv leaves behind -- run the
            # same ELF under the fallback simulator instead, in the same job, on the
            # same node. Nothing queues, nothing is lost, and .sim_backend records which
            # one actually produced the transcript so provenance survives into the
            # result tarball.
            lines += [
                "run_primary() {",
            ] + ["  " + l for l in launch] + [
                "}",
                "run_fallback() {",
            ] + ["  " + l for l in launch_lines(fb, fb_image, arm.elf)] + [
                "}",
                'started() { [ "$(wc -l < transcript 2>/dev/null || echo 0)" -gt 8 ]; }',
                "run_primary; rc=$?",
                "if started; then",
                '  echo %s > .sim_backend' % args.backend,
                "  exit $rc",
                "fi",
                'echo "primary (%s) exited rc=$rc before simulation time 0 -- no licence'
                ' seat; falling back to %s" >&2' % (args.backend, args.fallback),
                "rm -f transcript",
                "run_fallback; rc=$?",
                'echo %s > .sim_backend' % args.fallback,
                "exit $rc",
            ]
        elif backend["licensed"] and args.license_retries > 0:
            # A VCS runtime seat may not be free at the moment this job starts. A denied
            # simv exits within seconds having printed only its four-line version banner:
            # it never reaches simulation time 0, so nothing the DESIGN prints appears.
            # That is what we retry on -- a line-count test, not the wording of Synopsys'
            # message, which we never see anyway because it goes to stderr.
            #
            # This is the failure that silently killed 38 of 61 arms of a local sweep on
            # 2026-08-21: launched all at once into a full pool, refused, exited in
            # seconds, stderr discarded. A retry turns that into a queue.
            lines += [
                'for attempt in $(seq 1 %d); do' % args.license_retries,
            ] + ["  " + l for l in launch] + [
                '  rc=$?',
                '  if [ "$(wc -l < transcript 2>/dev/null || echo 0)" -gt 8 ]; then',
                '    exit $rc',   # it really ran; its exit status is the answer
                '  fi',
                '  echo "attempt $attempt: simulator exited rc=$rc before simulation time 0'
                ' (no licence seat?) -- retrying in %ds" >&2' % args.license_retry_s,
                '  sleep %d' % args.license_retry_s,
                'done',
                'echo "never started after %d attempts" >&2' % args.license_retries,
                'exit 1',
            ]
        else:
            lines += launch
        jobs.append({"command": "\n".join(lines), "meta": arm.meta})

    spec = {
        "name": args.name,
        # cwd for the job. Absolute image/ELF paths mean nothing depends on it, but
        # keeping it in hardware/ matches how these sims are run by hand.
        "workdir": HW,
        "jobs": jobs,
        "collect": args.collect,
        "meta": {"campaign": args.name, "run_prefix": args.run_prefix,
                 "backend": args.backend},
        "resources": {
            "cpus": args.cpus,
            # A job that may fall back to Questa can use 16 GB, so it must be PLACED as
            # if it will -- otherwise the fallback lands on a node that cannot hold it.
            "mem_gb": (args.mem_gb if args.mem_gb is not None
                       else max(backend["mem_gb"], fb["mem_gb"] if fb else 0)),
            "disk_gb": args.disk_gb,
            "est_runtime_s": args.est_runtime_s,
            "timeout_s": args.timeout_s,
            # Infrastructure loss only. An RTL simulation is deterministic: an arm that
            # exited non-zero will exit non-zero again, and re-running burns the same
            # hours for the same answer.
            "max_retries": args.max_retries,
            "retry_on_failure": False,
        },
    }
    if args.min_link_mbps:
        spec["resources"]["min_link_mbps"] = args.min_link_mbps
    if args.env:
        spec["env"] = args.env

    if backend["licensed"] and not fb:
        # With a fallback in place we deliberately do NOT throttle on the primary pool:
        # the whole point is to use the fallback the moment the primary is full, and a
        # governor that held jobs back would reintroduce the waiting we are removing.
        # `max` still caps our total concurrency.
        # Govern on the SCARCEST feature this backend consumes. Questa needs msimhdlsim (400)
        # and mtiverification (200); governing on msimhdlsim let us take 150 of the 200
        # mtiverification seats while the tool reported 158 free and colleagues were locked out.
        gov_feature = backend["feature"]
        feats = backend.get("features") or (backend["feature"],)
        if len(feats) > 1:
            tight = None
            for f in feats:
                r = license_free(f, backend["server"])
                if r is None:
                    continue
                if tight is None or (r[0] - r[1]) < tight[0]:
                    tight, gov_feature = (r[0] - r[1], f), f
        spec["license"] = {
            "feature": gov_feature,
            "server": backend["server"],
            "max": args.max_parallel,
            # Default per backend rather than one number for both: mtiverification has only
            # 200 seats against VCS's 100-issued/dept-wide pool, and a Questa sweep that does
            # not hold seats back starves every other Questa user on the site.
            "reserve_for_others": (args.reserve_licenses if args.reserve_licenses is not None
                                   else backend.get("reserve_default", 20)),
            # The governor holds its lmstat reading between polls and does NOT decrement it
            # for seats it hands out in between, so a long poll lets a burst overshoot the
            # real headroom. Poll often; the command's own retry loop covers what slips past.
            "poll_s": args.license_poll_s,
        }
    elif args.max_parallel:  # fallback in play, or an unlicensed backend: a plain cap
        # No feature/server: the governor degenerates into a plain concurrency cap,
        # which is what we want for an unlicensed backend on other people's desktops.
        spec["license"] = {"max": args.max_parallel}
    return spec


# --------------------------------------------------------------- commands

def cmd_submit(args):
    if args.arms:
        arms = arms_from_file(args.arms)
    elif args.shapes:
        precisions = [p.strip() for p in args.prec.split(",")] if args.prec else []
        arms = arms_from_shapes(args.shapes, precisions, args.elf_template)
    else:
        die("need --arms FILE or --shapes FILE")
    if not arms:
        die("no arms selected")

    default_image = args.image or BACKENDS[args.backend]["image"]
    preflight(arms, args.backend, default_image, args.run_prefix, args.force,
              fallback=args.fallback, fallback_image=args.fallback_image)

    for role, name in (("primary", args.backend), ("fallback", args.fallback)):
        if not name or not BACKENDS[name]["licensed"]:
            continue
        be = BACKENDS[name]
        # Report the SCARCEST feature this backend consumes, not the first one. Questa needs
        # msimhdlsim (400) and mtiverification (200); reading only the former said "158 free"
        # while the latter was 200/200 and nobody else could start Questa.
        feats = be.get("features") or (be["feature"],)
        tight, tightname = None, be["feature"]
        for f in feats:
            r = license_free(f, be["server"])
            if r is None:
                continue
            if tight is None or (r[0] - r[1]) < (tight[0] - tight[1]):
                tight, tightname = r, f
        seats = tight
        if not seats:
            warn("could not read %s from %s" % ("/".join(feats), be["server"]))
            continue
        issued, in_use, mine = seats
        extra = "" if len(feats) == 1 else "  [tightest of %s]" % ", ".join(feats)
        print("%-8s %-22s %3d/%3d in use, %3d free (%d ours)%s"
              % (role, tightname, in_use, issued, issued - in_use, mine, extra))
        if role == "primary" and issued - in_use <= 0 and not args.fallback:
            warn("that pool is FULL and no --fallback is set. Arms will queue or die "
                 "rather than run. Consider --fallback questa.")

    spec = build_spec(args, arms)
    if not os.path.isdir(SPEC_DIR):
        os.makedirs(SPEC_DIR)
    spec_path = os.path.join(SPEC_DIR, "%s.json" % args.name)
    with open(spec_path, "w") as fh:
        json.dump(spec, fh, indent=2)
    print("spec: %s  (%d arms, backend=%s, run dirs %s_<arm>)"
          % (spec_path, len(arms), args.backend, os.path.join(HW, args.run_prefix)))

    argv = [BADIST_BIN, "submit", spec_path]
    if args.dry_run:
        argv.append("--dry-run")
    if args.local:
        argv.append("--local")
    if args.no_watch:
        argv.append("--no-watch")
    if args.deadline:
        argv += ["--deadline", str(args.deadline)]
    print("+ %s" % " ".join(argv))
    rc = subprocess.call(argv)
    if rc != 0 or args.dry_run or args.no_watch:
        return rc

    # Watch mode returned, so the batch is finished: pull the results into the
    # layout the scrapers expect without making that a second manual step.
    return cmd_fetch(argparse.Namespace(batch=None, quiet=False))


def _resolve_batch(badist, batch):
    if batch:
        return batch
    known = badist.batches()
    if not known:
        die("no batches in the ledger yet")
    return known[0]["batch"] if isinstance(known[0], dict) else known[0]


_KEEP = ".transcript.fetchkeep"
_FETCH_LOCK = "/tmp/claude-620771/.teranoc_fetch.lock"


class _FetchLock(object):
    """Serialise extractions across every process that fetches.

    The transcript guard links a good file aside, lets the extraction run, then restores.
    Two fetches interleaved on the same run dir defeat that: the second guard pass deletes
    the first's keepfile and re-links the clobbered transcript, so the only complete copy
    disappears. Several loops call `fetch`, so the lock is not optional.
    """

    def __init__(self, timeout=1800):
        self.timeout = timeout
        self.fh = None

    def __enter__(self):
        import fcntl
        d = os.path.dirname(_FETCH_LOCK)
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass
        try:
            self.fh = open(_FETCH_LOCK, "w")
        except OSError:
            return self                      # no lock file: proceed rather than block a fetch
        deadline = time.time() + self.timeout
        while True:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except IOError:
                if time.time() > deadline:
                    warn("another fetch has held the lock for %ds -- proceeding without it"
                         % self.timeout)
                    return self
                time.sleep(2)

    def __exit__(self, *a):
        if self.fh:
            try:
                import fcntl
                fcntl.flock(self.fh, fcntl.LOCK_UN)
                self.fh.close()
            except Exception:
                pass
        return False


def _transcript_complete(path, tail=64 << 20):
    """Does this transcript end in a completed run?

    Reads only the last `tail` bytes -- the `execution took` banner is emitted by the
    benchmark at the end, ~1 MB from EOF even on a 12 MB transcript. A full read of the
    227 MB arms would make this guard too slow to run on every fetch, and a guard that
    is too slow to run is a guard that gets removed.
    """
    try:
        sz = os.path.getsize(path)
        with open(path, "rb") as f:
            if sz > tail:
                f.seek(sz - tail)
            return b"execution took" in f.read()
    except OSError:
        return False


def _guard_transcripts(dests):
    """Hardlink every already-complete transcript aside before an extraction overwrites it.

    WHY: extract_batch unpacks a job's tarball straight over hardware/<prefix>_<arm>/, and
    a FAILED job's tarball holds a partial, design-load-only transcript. Re-fetching an old
    batch therefore destroys a good result that a later batch delivered for the same arm.
    On 2026-08-25 a results loop re-fetching 2026-08-23 batches clobbered 50 of 138
    completed 8x8 transcripts this way. The numbers survived only because they had already
    been extracted into results.tsv / group_util.json / probe_archive.

    A hardlink costs nothing and survives tar's unlink-and-recreate, so the old bytes are
    still reachable after the overwrite.
    """
    guard = {}
    for rd in sorted(set(dests)):
        t = os.path.join(rd, "transcript")
        if not os.path.exists(t) or not _transcript_complete(t):
            continue
        k = os.path.join(rd, _KEEP)
        try:
            if os.path.exists(k):
                os.remove(k)
            os.link(t, k)
            guard[t] = (k, os.path.getsize(t))
        except OSError:
            pass
    return guard


def _all_run_dirs():
    """Every run dir this campaign delivers into, not just the batch being fetched.

    Orphan recovery has to be global. A fetch killed by its `timeout` leaves an orphan in the
    dirs of the batch it was mid-way through, and the settled-batch skip means that batch may
    never be fetched again -- so recovery scoped to the current batch would never reach it.
    """
    import glob as _g
    return [os.path.dirname(f) for f in _g.glob(os.path.join(HW, "*", _KEEP))]


def _recover_orphans(dests):
    """Salvage a keepfile left behind by a fetch that was interrupted mid-extraction.

    _guard_transcripts links the good transcript aside and _restore_transcripts puts it back,
    but a fetch killed between the two leaves the clobbered transcript in place next to a
    keepfile holding the only complete copy. Left alone, the NEXT fetch would guard the
    clobbered file, delete that keepfile, and destroy the last copy -- so recover before
    guarding, never after.
    """
    n = 0
    for rd in sorted(set(dests)):
        k = os.path.join(rd, _KEEP)
        t = os.path.join(rd, "transcript")
        if not os.path.exists(k):
            continue
        try:
            kc, tc = _transcript_complete(k), _transcript_complete(t)
            if kc and not tc:
                os.replace(k, t)
                n += 1
                warn("recovered %s from a keepfile left by an interrupted fetch"
                     % os.path.basename(rd))
            elif kc and tc and os.path.getsize(k) > os.path.getsize(t):
                # Both complete: keep the longer one, which carries strictly more probe output.
                os.replace(k, t)
                n += 1
            else:
                # The live file is already as good or better -- often because the vault healed
                # it first. Drop the keepfile: leaving it is a real disk leak (it stops sharing
                # an inode the moment the live file is replaced) and the next guard pass would
                # only delete it anyway.
                os.remove(k)
        except OSError:
            pass
    return n


def _restore_transcripts(guard):
    """Put a complete transcript back if the extraction replaced it with a lesser one.

    Restores only when the new file is BOTH shorter AND incomplete -- a genuine re-delivery
    of the same run may differ in length without being worse.
    """
    restored = 0
    for t, (k, old_size) in guard.items():
        try:
            if not os.path.exists(t) or (os.path.getsize(t) < old_size
                                         and not _transcript_complete(t)):
                os.replace(k, t)
                restored += 1
                warn("kept the complete transcript for %s -- the fetched one was incomplete"
                     % os.path.basename(os.path.dirname(t)))
            else:
                os.remove(k)
        except OSError:
            pass
    return restored


def cmd_fetch(args):
    badist = _badist()
    batch = _resolve_batch(badist, args.batch)
    print("batch %s" % batch)

    # Anything a worker could not push at the time lands here first.
    rec = badist.reconcile(batch)
    if rec.get("recovered"):
        print("recovered %d result(s) that never landed" % rec["recovered"])

    # gather.extract_batch() feeds dest_for() the rows from ledger.batch_status(), which
    # carry no `meta` -- only badist.status() merges that in. Reading meta off the status
    # row therefore yields None for every job, and extract_batch SILENTLY SKIPS a job
    # whose dest_for returns None: it is counted neither as extracted nor as missing, so
    # a delivered result just never appears. Take run_dir from the job records instead.
    run_dirs = {}
    for j in badist.ledger.read_jobs(badist.config.load(), batch):
        rd = (j.get("meta") or {}).get("run_dir")
        if rd:
            run_dirs[j["job_id"]] = rd

    def dest_for(st):
        return run_dirs.get(st["job"])

    with _FetchLock():
        # Global, not per-batch: see _all_run_dirs.
        rescued = _recover_orphans(list(run_dirs.values()) + _all_run_dirs())
        if rescued:
            print("recovered %d transcript(s) from an interrupted earlier fetch" % rescued)
        guard = _guard_transcripts(run_dirs.values())

        # `timeout 300` (every loop wraps fetch in one) sends SIGTERM, and Python's default
        # handler exits WITHOUT unwinding -- so the `finally` below never ran and every
        # timed-out fetch left a clobbered transcript behind. Restore from the signal itself.
        import signal as _sig

        def _on_term(signum, frame):
            _restore_transcripts(guard)
            os._exit(143)

        _prev = {}
        for _s in (_sig.SIGTERM, _sig.SIGINT, _sig.SIGHUP):
            try:
                _prev[_s] = _sig.signal(_s, _on_term)
            except Exception:
                pass
        try:
            out = badist.extract_batch(batch, dest_for=dest_for, verbose=not args.quiet)
        finally:
            kept = _restore_transcripts(guard)
            for _s, _h in _prev.items():
                try:
                    _sig.signal(_s, _h)
                except Exception:
                    pass
    print("extracted %d, missing %d" % (out["extracted"], out["missing"]))
    if kept:
        print("protected %d complete transcript(s) from an incomplete re-fetch" % kept)
    for job, err in out.get("errors", []):
        warn("%s: %s" % (job, err))

    # A one-line verdict per arm, read straight out of the transcript that just landed
    # -- the same grep the local sweep watcher uses.
    rows = []
    for st in badist.status(batch):
        meta = st.get("meta") or {}
        rundir = meta.get("run_dir") or run_dirs.get(st["job"])
        cyc = "-"
        if rundir:
            tr = os.path.join(rundir, "transcript")
            if os.path.exists(tr):
                cyc = _cycles(tr) or "-"
        rows.append((meta.get("arm", st["job"]), st["state"], st.get("node") or "-",
                     st.get("wall_s"), cyc))
    if rows:
        print()
        print("%-24s %-10s %-10s %8s %12s" % ("ARM", "STATE", "NODE", "WALL", "CYCLES"))
        for arm, state, node, wall, cyc in rows:
            print("%-24s %-10s %-10s %8s %12s"
                  % (arm, state, node, ("%ds" % wall) if wall else "-", cyc))
    return 0


def _cycles(transcript):
    """The kernel's own cycle count, from the UART line the benchmark prints."""
    try:
        with open(transcript, "rb") as fh:
            for raw in fh:
                if b"execution took" in raw:
                    m = re.search(rb"(\d+)", raw.split(b"execution took")[1])
                    if m:
                        return m.group(1).decode()
    except (IOError, OSError):
        pass
    return None


def cmd_gc(args):
    """Free a batch's node-local scratch -- but only once it is genuinely finished.

    badist's own `gc` issues `rm -rf <scratch>/run/<batch> <scratch>/out/<batch>` on every
    host that holds ANY job of the batch, with no regard for job state. On a
    part-finished batch that deletes the working directory out from under arms that are
    still simulating. It also runs before checking that the results were ever gathered,
    so a bad push plus a gc loses the run outright.

    Nothing is deleted here until every job is terminal AND every result is on disk.
    """
    badist = _badist()
    batch = _resolve_batch(badist, args.batch)
    rows = badist.status(batch)
    running = [r for r in rows if r["state"] not in ("done", "failed", "cancelled")]
    if running and not args.force:
        for r in running[:8]:
            sys.stderr.write("  still %s: %s\n"
                             % (r["state"], (r.get("meta") or {}).get("arm", r["job"])))
        die("%d job(s) of %s are not finished; gc would delete their working "
            "directories mid-run. Wait, or --force if you know better."
            % (len(running), batch))

    missing = []
    for r in rows:
        rd = (r.get("meta") or {}).get("run_dir")
        if r["state"] == "done" and rd and not os.path.exists(os.path.join(rd, "transcript")):
            missing.append((r.get("meta") or {}).get("arm", r["job"]))
    if missing and not args.force:
        die("%d done job(s) have no transcript locally (%s...). Run `fetch` first -- the "
            "node copy is the only remaining one." % (len(missing), ", ".join(missing[:4])))

    out = badist.gc(batch)
    print("cleaned %d node(s): %s" % (out.get("freed_nodes", 0),
                                      " ".join(out.get("hosts", []))))
    return 0


def cmd_status(args):
    badist = _badist()
    batch = _resolve_batch(badist, args.batch)
    print("%-24s %-10s %-10s %8s  %s" % ("ARM", "STATE", "NODE", "WALL", "RESULT"))
    for st in badist.status(batch):
        meta = st.get("meta") or {}
        print("%-24s %-10s %-10s %8s  %s"
              % (meta.get("arm", st["job"]), st["state"], st.get("node") or "-",
                 ("%ds" % st["wall_s"]) if st.get("wall_s") else "-",
                 st.get("result") or ""))
    return 0


def cmd_stage(args):
    """Seed the simulator image to node-local disk.

    Worth it for VCS: the image plus its .daidir is ~835 MB on one NFS server, and
    badist measured 8 concurrent cold readers collapsing to 40-71 MB/s each. The
    simv is relocatable (RPATH $ORIGIN/<image>.daidir), so a node-local copy runs.
    --warm is the cheaper option: no copy, just fault the tree into page cache.
    """
    image = _abs_hw(args.image or BACKENDS[args.backend]["image"])
    root = os.path.dirname(image)
    argv = [BADIST_BIN, "stage", root]
    if args.warm:
        argv.append("--warm")
    else:
        argv += ["--path", os.path.basename(image)]
        if args.backend == "vcs":
            argv += ["--path", os.path.basename(image) + ".daidir"]
    print("+ %s" % " ".join(argv))
    return subprocess.call(argv)


def cmd_license(args):
    seats = license_free(args.feature, args.server)
    if not seats:
        die("could not read %s from %s" % (args.feature, args.server))
    issued, in_use, mine = seats
    print("%s @ %s" % (args.feature, args.server))
    print("  issued %d   in use %d   free %d   ours %d" % (issued, in_use, issued - in_use, mine))
    return 0


# ------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(
        description="Run TeraNoC RTL simulations on the badile fleet (badist client).")
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True

    s = sub.add_parser("submit", help="build a spec from arms and hand it to badist")
    src = s.add_argument_group("what to run")
    src.add_argument("--arms", help="file of '<name> <elf> [image]' lines")
    src.add_argument("--shapes", help="file of 'M N P PREC' lines "
                                      "(scripts/gemm_sweep_shapes.txt)")
    src.add_argument("--prec", default="", help="with --shapes: keep only these "
                                                "precisions, e.g. '16' or '16,32'")
    src.add_argument("--elf-template", default="i2_{prec}_{shape}.elf",
                     help="with --shapes: ELF path per arm; {prec} {shape} {M} {N} {P}")
    src.add_argument("--image", help="simulator binary (default: per backend)")
    src.add_argument("--backend", choices=sorted(BACKENDS), default="vcs",
                     help="vcs (100 seats, fastest), questa (400 seats, 8x the RAM, "
                          "cycle-identical to vcs), verilator (no licence, 4x4 only)")
    src.add_argument("--fallback", choices=sorted(BACKENDS), default=None,
                     help="run this simulator instead when the primary is refused a "
                          "licence seat, in the same job -- rather than waiting. "
                          "'questa' is the validated choice.")
    src.add_argument("--fallback-image", default=None,
                     help="simulator binary / build dir for --fallback")

    out = s.add_argument_group("where results go")
    out.add_argument("--name", default="teranoc", help="campaign name (batch prefix)")
    out.add_argument("--run-prefix", default="fleet",
                     help="results land in hardware/<prefix>_<arm>/")
    out.add_argument("--collect", action="append", default=None,
                     help="extra glob to bring back (repeatable); default: transcript")
    out.add_argument("--force", action="store_true",
                     help="overwrite run dirs that already have content")

    res = s.add_argument_group("resources -- declare them, do not leave the defaults")
    res.add_argument("--cpus", type=int, default=1)
    res.add_argument("--mem-gb", type=float, default=None,
                     help="default: 4 for vcs (2.0 GB measured), 8 for verilator")
    res.add_argument("--disk-gb", type=float, default=5)
    res.add_argument("--est-runtime-s", type=int, default=5400,
                     help="sets the liveness window; over-declaring is the cheap "
                          "mistake, under-declaring kills healthy long arms")
    # DEFAULT 30 DAYS, effectively no wall-clock deadline (user decision 2026-08-23:
    # "don't set a deadline as long as the run is alive -- I don't want to kill runs halfway").
    # A fixed wall cannot tell a healthy long run from a sick one: at ~1 s per simulated cycle
    # the largest shapes need 66-136 h, so the old 24 h killed 83 arms mid-flight after a full
    # day each, and a 48 h line still amputated 24% of the manifest. Pathology is caught by
    # LIVENESS instead -- CPU starvation, the heartbeat, and wedge detection (util~0 with the
    # cycle counter still advancing) -- which also catches a small wedged arm in minutes, where
    # a wall-clock deadline would let it squat for days.
    res.add_argument("--timeout-s", type=int, default=2592000)
    res.add_argument("--max-retries", type=int, default=2)
    res.add_argument("--min-link-mbps", type=int, default=0,
                     help="1000 keeps trace-heavy arms off the 100 Mb nodes")
    res.add_argument("--max-parallel", type=int, default=24,
                     help="our own concurrent-arm cap (VCS: also the seat cap)")
    res.add_argument("--reserve-licenses", type=int, default=None,
                     help="seats to leave free for the rest of the department "
                          "(default: 5 for VCS, 10 for Questa's 200-seat mtiverification pool)")
    res.add_argument("--env", action="append", default=None,
                     help="shell line to run before the simulator (repeatable)")
    res.add_argument("--license-retries", type=int, default=12,
                     help="VCS only: times to re-try an arm that exited before simulation "
                          "time 0 (the signature of a refused runtime seat); 0 disables")
    res.add_argument("--license-retry-s", type=int, default=300,
                     help="seconds to wait between those retries")
    res.add_argument("--license-poll-s", type=int, default=60,
                     help="how often the governor re-reads the server's free-seat count")
    res.add_argument("--no-license-wait", dest="license_wait", action="store_false",
                     default=True,
                     help="VCS only, no --fallback: do NOT pass +vcs+lic+wait, so a "
                          "seat-starved simv fails fast instead of queueing")

    run = s.add_argument_group("how to submit")
    run.add_argument("--dry-run", action="store_true",
                     help="expand, validate, show placement -- run this first")
    run.add_argument("--local", action="store_true", help="this machine only, no ssh")
    run.add_argument("--no-watch", action="store_true",
                     help="dispatch what fits now and return")
    run.add_argument("--deadline", type=int, default=None,
                     help="stop waiting after N s; jobs keep running and still deliver")
    s.set_defaults(func=cmd_submit)

    f = sub.add_parser("fetch", help="unpack results into hardware/<prefix>_<arm>/")
    f.add_argument("batch", nargs="?")
    f.add_argument("--quiet", "-q", action="store_true")
    f.set_defaults(func=cmd_fetch)

    st = sub.add_parser("status", help="per-arm status of a batch")
    st.add_argument("batch", nargs="?")
    st.set_defaults(func=cmd_status)

    sg = sub.add_parser("stage", help="seed the simulator image to node-local disk")
    sg.add_argument("--backend", choices=sorted(BACKENDS), default="vcs")
    sg.add_argument("--image")
    sg.add_argument("--warm", action="store_true",
                    help="just warm each node's page cache; no node-local copy")
    sg.set_defaults(func=cmd_stage)

    gcp = sub.add_parser("gc", help="free a finished batch's node-local scratch")
    gcp.add_argument("batch", nargs="?")
    gcp.add_argument("--force", action="store_true",
                     help="clean even if jobs are still running or results are not fetched")
    gcp.set_defaults(func=cmd_gc)

    lc = sub.add_parser("license", help="VCS runtime-seat headroom")
    lc.add_argument("--feature", default=VCS_LICENSE_FEATURE)
    lc.add_argument("--server", default=VCS_LICENSE_SERVER)
    lc.set_defaults(func=cmd_license)

    args = ap.parse_args()
    if args.cmd == "submit":
        # transcript is not optional: every scraper in scripts/ reads it, and an arm
        # that comes back without one is indistinguishable from an arm that never ran.
        # .sim_backend records WHICH simulator produced this transcript. With a
        # fallback in play a sweep can be a mix, and a mixed sweep whose provenance is
        # not recorded is a sweep you cannot defend.
        keep = ["transcript", ".sim_backend"]
        args.collect = keep + [c for c in (args.collect or []) if c not in keep]
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
