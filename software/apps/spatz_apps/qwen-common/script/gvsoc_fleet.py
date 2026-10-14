#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# GVSoC runs on the badile fleet (badist), each converted into an RTL-style transcript.
#
#   gvsoc_fleet.py submit --name lg1 --arms arms.txt [--max 40] [--est 3600] [--mem-gb 6]
#   gvsoc_fleet.py harvest <batch> --dest <dir>
#
# arms.txt: "<tag> <4x4|8x8> <elf> [max_seconds]" per line (ELF paths absolute, fleet-visible --
# never software/bin, which is rebuilt in place). One job per arm runs gvsoc_job.sh into its node-
# local job directory; badist collects the transcript, the model's log and statistics and the
# DMA log. `submit` stays in the foreground while jobs are pending (badist's scheduler is
# in-process: run it in the background, never under `timeout`). `harvest` unpacks each job into
# <dest>/<tag>/ (transcript, run.log, run.dma, run.d/*.log, badist_job.json).
import argparse
import io
import json
import os
import subprocess
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = "/usr/scratch/fenga1/zexifu/badist-results"
SPECS = "/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/badist_specs"


def cmd_submit(a):
    jobs = []
    for ln in open(a.arms):
        p = ln.split()
        if not p or p[0].startswith("#"):
            continue
        tag, mesh, elf = p[:3]
        tmax = p[3] if len(p) > 3 else "0"
        elf = os.path.abspath(elf)
        if not os.path.isfile(elf):
            sys.exit("missing ELF: %s" % elf)
        if "/software/bin/" in elf:
            sys.exit("refusing an ELF under software/bin (rebuilt in place): %s" % elf)
        jobs.append({"command": "%s/gvsoc_job.sh %s %s {jobdir} %s" % (HERE, mesh, elf, tmax),
                     "meta": {"arm": tag, "mesh": mesh, "elf": elf}})
    spec = {
        "name": a.name,
        "workdir": HERE,
        "resources": {"cpus": 1, "mem_gb": a.mem_gb, "disk_gb": a.disk_gb,
                      "est_runtime_s": a.est, "max_retries": 1, "retry_on_failure": False},
        "license": {"max": a.max},
        "collect": ["transcript", "run.log", "run.dma", "run.d/*.log"],
        "jobs": jobs,
    }
    os.makedirs(a.spec_dir, exist_ok=True)
    path = os.path.join(a.spec_dir, a.name + ".json")
    with open(path, "w") as f:
        json.dump(spec, f, indent=1)
    print("%d jobs -> %s" % (len(jobs), path), flush=True)
    cmd = (["badist"] + (["--config", a.config] if a.config else []) + ["submit", path] +
           (["--dry-run"] if a.dry_run else []))
    return subprocess.call(cmd)


def cmd_harvest(a):
    bdir = os.path.join(RESULTS, a.batch)
    n = 0
    for fn in sorted(os.listdir(bdir)):
        if not fn.endswith(".tar.zst"):
            continue
        raw = subprocess.run(["zstd", "-dc", os.path.join(bdir, fn)], stdout=subprocess.PIPE,
                             check=True).stdout
        tf = tarfile.open(fileobj=io.BytesIO(raw))
        meta = {}
        for m in tf.getmembers():
            if m.name.endswith("badist_job.json"):
                meta = json.load(tf.extractfile(m)).get("meta", {})
        tag = meta.get("arm") or fn.split(".")[0]
        # a job that failed before the converter ran (no transcript) must not overwrite a good
        # harvest of the same arm from a retry batch
        if not any(m.isfile() and os.path.basename(m.name) == "transcript" for m in tf.getmembers()):
            print("%s (%s): no transcript, skipped" % (fn, tag))
            continue
        dest = os.path.join(a.dest, tag)
        os.makedirs(dest, exist_ok=True)
        for m in tf.getmembers():
            if not m.isfile():
                continue
            out = os.path.join(dest, m.name.lstrip("./"))
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as f:
                f.write(tf.extractfile(m).read())
        n += 1
        print("%s -> %s" % (fn, dest))
    print("%d jobs harvested" % n)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("submit")
    s.add_argument("--name", required=True)
    s.add_argument("--arms", required=True)
    s.add_argument("--max", type=int, default=40, help="jobs running at once")
    s.add_argument("--est", type=int, default=3600, help="estimated seconds per job")
    s.add_argument("--mem-gb", type=float, default=6)
    s.add_argument("--disk-gb", type=float, default=5)
    s.add_argument("--spec-dir", default=SPECS)
    s.add_argument("--dry-run", action="store_true")
    # Not every node can run the model (no /usr/bin/python3.12 on some badiles): a badist config
    # whose hosts.exclude lists them (hardware/linear_bench/badist_gvsoc.json).
    s.add_argument("--config", help="badist config JSON (host exclusions)")
    h = sub.add_parser("harvest")
    h.add_argument("batch")
    h.add_argument("--dest", required=True)
    a = ap.parse_args()
    if a.cmd == "submit":
        return cmd_submit(a)
    if a.cmd == "harvest":
        return cmd_harvest(a)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
