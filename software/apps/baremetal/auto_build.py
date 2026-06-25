#!/usr/bin/env python3

# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# This script automates the build of multiple configurations and workloads.
# Author: Yinrong Li <yinrli@student.ethz.ch>

import json
import re
import shutil
import subprocess
import shlex
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, List


# =========================
# logging helpers
# =========================
class Logger:
    def __init__(self, log_file: Path):
        self.log_file = log_file
        self.log_file.parent.mkdir(parents=True, exist_ok=True)

    def log(self, msg: str):
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{ts}] {msg}"
        print(line)
        with self.log_file.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    def sep(self, ch: str = "-", n: int = 80):
        self.log(ch * n)


# =========================
# path + fs utils
# =========================
def ensure_dir(p: Path):
    p.mkdir(parents=True, exist_ok=True)


def resolve_path(base_dir: Path, p: str) -> Path:
    """
    - absolute path: use directly
    - relative path: relative to build_plan.json directory
    """
    path = Path(p).expanduser()
    return path if path.is_absolute() else (base_dir / path).resolve()


# =========================
# make helpers
# =========================
def extra_args_for_kernel(
        kernel: str, extra_args: Dict[str, str]) -> List[str]:
    """
    Read per-kernel extra args from plan.extra_args, parse to argv list.
    Supports quotes, e.g. CFLAGS="-O3 -g"
    """
    s = extra_args.get(kernel, "")
    if s is None:
        return []
    s = str(s).strip()
    if not s:
        return []
    return shlex.split(s)


def parse_app_entry(app_entry):
    """An app entry is either a list of task-param dicts, or a dict with
    "tasks" (list) and optional "variants".

    Variants can use the original compact form:
      {"_opt": "-DSP_FOO_OPT"}

    or the expanded form, which lets a merged app use variant-specific data:
      {"_bk": {"defines": "-DSP_GEMV_ROWMAJ", "tasks": [{"transpose_a": 0}]}}

    Returns (tasks, variants). Use parse_variant_entry() to resolve each
    variant against the app's default tasks.
    """
    if isinstance(app_entry, dict):
        tasks = app_entry.get("tasks", [])
        variants = app_entry.get("variants", {"": ""})
    else:
        tasks = app_entry
        variants = {"": ""}
    return tasks, variants


def parse_variant_entry(variant_entry, default_tasks):
    """Return (defines, tasks) for one variant entry."""
    if isinstance(variant_entry, dict):
        defines = variant_entry.get("defines", "")
        tasks = variant_entry.get("tasks", default_tasks)
    else:
        defines = variant_entry
        tasks = default_tasks

    if defines is None:
        defines = ""
    if tasks is None:
        tasks = []

    return str(defines).strip(), tasks


def run_make_with_log(cmd: List[str], cwd: Path,
                      make_log: Path, logger: Logger):
    """
    Stream make output to terminal; save stdout+stderr (merged) to make_log.
    """
    logger.log(f"RUN: {' '.join(cmd)} (cwd={cwd})")
    make_log.parent.mkdir(parents=True, exist_ok=True)

    with make_log.open("w", encoding="utf-8") as f:
        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            print(line, end="")  # keep make live output
            f.write(line)
        ret = proc.wait()

    logger.log(f"MAKE DONE: return_code={ret} log={make_log}")
    if ret != 0:
        raise RuntimeError(f"make failed: {' '.join(cmd)}")


# =========================
# gendata patch
# =========================
def patch_workload_block(
    hjson_text: str, workload: str, replacements: Dict[str, Any]
) -> str:
    """
    Patch ONLY within `"workload": { ... }` block:
      ("key", 123) -> ("key", replacements[key])
    """
    anchor = f'"{workload}":'
    start = hjson_text.find(anchor)
    if start < 0:
        raise RuntimeError(
            f'Cannot find workload "{workload}" in gendata_params.hjson')

    brace0 = hjson_text.find("{", start)
    if brace0 < 0:
        raise RuntimeError(f'Cannot find "{{" after "{workload}":')

    i = brace0
    depth = 0
    end = None
    while i < len(hjson_text):
        c = hjson_text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
        i += 1
    if end is None:
        raise RuntimeError(f"Unbalanced braces in {workload} block")

    block = hjson_text[brace0: end + 1]
    patched = block

    for key, val in replacements.items():
        pattern = rf'(\(\s*"{re.escape(key)}"\s*,\s*)-?\d+(\s*\))'
        patched2, n = re.subn(pattern, rf"\g<1>{int(val)}\g<2>", patched)
        if n != 1:
            raise RuntimeError(
                f'Expected exactly one "{key}" in {workload} block, got {n}. '
                f"Check key name or block format."
            )
        patched = patched2

    return hjson_text[:brace0] + patched + hjson_text[end + 1:]


# =========================
# naming + packing
# =========================
def make_size_tag(
        workload: str, params: Dict[str, Any], rules: Dict[str, Any]) -> str:
    """
    Build tag from rename_tag_rules:
      - matmul_i32 -> 256x256x256
      - axpy_i32   -> 1024
    If no rule, use sorted keys for stable tag.
    """
    keys = rules.get(workload, sorted(params.keys()))
    for k in keys:
        if k not in params:
            raise RuntimeError(
                f"rename_tag_rules wants key={k} but params "
                f"missing it for {workload}"
            )
    return "x".join(str(params[k]) for k in keys)


def resolve_pack_dir(config_name: str, pack_dir: str |
                     None, batch_ts: str) -> str:
    """
    Empty/None pack_dir -> <config>_<batch_ts> (same ts for all configs).
    Else: use pack_dir as-is.
    """
    if pack_dir is None or str(pack_dir).strip() == "":
        return f"{config_name}_{batch_ts}"
    return str(pack_dir).strip()


def move_and_rename(
    app: str, pack_dir: str, size_tag: str, out_dir: Path, logger: Logger,
    variant: str = ""
) -> Path:
    """
    Inputs produced by make in out_dir root:
      out_dir/app
      out_dir/app.dump
    Move & rename into:
      out_dir/pack_dir/app_<tag>
      out_dir/pack_dir/app_<tag>.dump

    Returns:
      Path to the packed executable (not .dump)
    """
    src_bin = out_dir / app
    src_dump = out_dir / f"{app}.dump"

    if not src_bin.exists():
        raise FileNotFoundError(f"Missing binary: {src_bin}")
    if not src_dump.exists():
        raise FileNotFoundError(f"Missing dump: {src_dump}")

    dst_dir = out_dir / pack_dir
    ensure_dir(dst_dir)

    dst_bin = dst_dir / f"{app}{variant}_{size_tag}"
    dst_dump = dst_dir / f"{app}{variant}_{size_tag}.dump"

    # overwrite to avoid confusion
    if dst_bin.exists():
        dst_bin.unlink()
    if dst_dump.exists():
        dst_dump.unlink()

    shutil.move(str(src_bin), str(dst_bin))
    shutil.move(str(src_dump), str(dst_dump))

    logger.log(f"PACK: {dst_bin}")
    logger.log(f"PACK: {dst_dump}")
    return dst_bin


# =========================
# filelist (per pack_dir)
# =========================
def write_filelist(
        pack_root: Path, executable_paths: List[Path], logger: Logger):
    """
    Generate filelist under pack_root listing packed executables (no .dump),
    one per line, using paths relative to pack_root.
    """
    filelist_path = pack_root / "filelist.txt"

    rels: List[str] = []
    for p in executable_paths:
        # we expect p inside pack_root
        try:
            rels.append(str(p.relative_to(pack_root)))
        except ValueError:
            # fallback to basename (still useful)
            rels.append(p.name)

    # unique + stable
    rels = sorted(dict.fromkeys(rels))
    filelist_path.write_text(
        "\n".join(rels) + ("\n" if rels else ""), encoding="utf-8")

    logger.log(f"FILELIST: wrote {len(rels)} entries -> {filelist_path}")


# =========================
# dry-run printer
# =========================
def print_dry_run_summary(
    plan_path: Path,
    make_cwd: Path,
    out_dir: Path,
    gendata_params: Path,
    configs: list,
    rename_rules: Dict[str, Any],
    batch_ts: str,
    extra_args: Dict[str, str],
):
    print("\n" + "=" * 100)
    print(
        "[DRY-RUN] Will NOT modify gendata, will NOT run make, "
        "will NOT move outputs, will NOT write logs/filelists."
    )
    print("=" * 100)
    print(f"plan_path      : {plan_path}")
    print(f"make_cwd       : {make_cwd}")
    print(f"out_dir        : {out_dir}")
    print(f"gendata_params : {gendata_params}")
    print(f"batch_ts       : {batch_ts}")

    total = 0
    for cfg in configs:
        cfg_name = cfg["name"]
        pack_dir = resolve_pack_dir(cfg_name, cfg.get("pack_dir"), batch_ts)
        pack_root = out_dir / pack_dir
        log_dir = pack_root / f"build_logs_{batch_ts}"
        filelist = pack_root / "filelist.txt"

        print("\n" + "-" * 100)
        print(f"[CONFIG] name={cfg_name}")
        print(f"        pack_dir={pack_dir}")
        print(f"        logs    ={log_dir}")
        print(f"        filelist={filelist}")

        for app, app_entry in cfg["apps"].items():
            tasks, variants = parse_app_entry(app_entry)
            extra = extra_args_for_kernel(app, extra_args)
            extra_str = " ".join(extra) if extra else "(none)"
            print(f"  [KERNEL] {app}  tasks={len(tasks)}  "
                  f"variants={list(variants)}  extra={extra_str}")

            for vsuffix, variant_entry in variants.items():
                vdef, variant_tasks = parse_variant_entry(
                    variant_entry, tasks)
                vextra = extra + ([f"APP_DEFINES={vdef}"] if vdef else [])
                for i, params in enumerate(variant_tasks, 1):
                    tag = make_size_tag(app, params, rename_rules)
                    cmd = ["make", app, f"config={cfg_name}"] + vextra
                    total += 1
                    print(f"    - TASK {i}/{len(variant_tasks)} "
                          f"app={app}{vsuffix} tag={tag}")
                    print(f"      params={params}")
                    print(f"      make: (cwd={make_cwd}) {' '.join(cmd)}")
                    print(f"      pack: "
                          f"{pack_root / (app + vsuffix + '_' + tag)}")

    print("\n" + "=" * 100)
    print(f"[DRY-RUN] Total tasks: {total}")
    print("=" * 100 + "\n")


# =========================
# main
# =========================
def main():
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", default="build_plan.json",
                    help="path to build plan json")
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="print planned tasks only; do not run make or touch files",
    )
    args = ap.parse_args()

    plan_path = Path(args.plan).expanduser().resolve()
    plan_dir = plan_path.parent
    plan = json.loads(plan_path.read_text(encoding="utf-8"))

    make_cwd = resolve_path(plan_dir, plan["make_cwd"])
    out_dir = resolve_path(plan_dir, plan["out_dir"])
    gendata_params = resolve_path(plan_dir, plan["gendata_params"])

    rename_rules = plan.get("rename_tag_rules", {}) or {}
    extra_args = plan.get("extra_args", {}) or {}
    configs = plan["configs"]

    # one batch timestamp shared by all configs
    batch_ts = datetime.now().strftime("%Y%m%d_%H%M%S")

    if args.dry_run:
        print_dry_run_summary(
            plan_path,
            make_cwd,
            out_dir,
            gendata_params,
            configs,
            rename_rules,
            batch_ts,
            extra_args,
        )
        return

    # sanity checks
    if not make_cwd.exists():
        raise FileNotFoundError(f"make_cwd does not exist: {make_cwd}")
    if not out_dir.exists():
        raise FileNotFoundError(f"out_dir does not exist: {out_dir}")
    if not gendata_params.exists():
        raise FileNotFoundError(
            f"gendata_params does not exist: {gendata_params}")

    original = gendata_params.read_text(encoding="utf-8")

    try:
        for cfg in configs:
            cfg_name = cfg["name"]
            pack_dir = resolve_pack_dir(
                cfg_name, cfg.get("pack_dir"), batch_ts)
            apps = cfg["apps"]

            # logs ONLY under pack_dir
            pack_root = out_dir / pack_dir
            ensure_dir(pack_root)
            log_dir = pack_root / f"build_logs_{batch_ts}"
            ensure_dir(log_dir)

            logger = Logger(log_dir / "build.log")

            # collect executables for THIS pack_dir only
            packed_execs: List[Path] = []

            # CONFIG header
            logger.sep("#", 92)
            logger.log(
                f"[CONFIG] name={cfg_name}  pack_dir={pack_dir}  "
                f"batch_ts={batch_ts}"
            )
            logger.log(f"         make_cwd={make_cwd}")
            logger.log(f"         out_dir={out_dir}")
            logger.log(f"         gendata_params={gendata_params}")
            logger.log(f"         log_dir={log_dir}")
            logger.sep("#", 92)

            for app, app_entry in apps.items():
                tasks, variants = parse_app_entry(app_entry)
                extra = extra_args_for_kernel(app, extra_args)
                extra_str = " ".join(extra) if extra else "(none)"

                # KERNEL group header (EXTRA ARGS goes here)
                logger.sep("=", 92)
                logger.log(
                    f"[KERNEL] {app}  tasks={len(tasks)}  "
                    f"variants={list(variants)}  extra={extra_str}")
                logger.sep("=", 92)

                for vsuffix, variant_entry in variants.items():
                    vdef, variant_tasks = parse_variant_entry(
                        variant_entry, tasks)
                    vextra = extra + (
                        [f"APP_DEFINES={vdef}"] if vdef else [])
                    for idx, params in enumerate(variant_tasks, 1):
                        tag = make_size_tag(app, params, rename_rules)

                        logger.sep("-", 92)
                        logger.log(
                            f"[TASK {idx}/{len(variant_tasks)}] "
                            f"app={app}{vsuffix}  tag={tag}")
                        logger.log(f"          params={params}")

                        # patch gendata
                        patched = patch_workload_block(original, app, params)
                        gendata_params.write_text(patched, encoding="utf-8")
                        logger.log("STEP: patched gendata_params.hjson")

                        # make + per-task make log (also under pack_dir)
                        cmd = (["make", app, f"config={cfg_name}"] + vextra)
                        make_log = (
                            log_dir /
                            f"make_{cfg_name}_{app}{vsuffix}"
                            f"_task{idx:03d}_{tag}.log"
                        )
                        run_make_with_log(cmd, make_cwd, make_log, logger)

                        # pack outputs
                        exe_path = move_and_rename(
                            app, pack_dir, tag, out_dir, logger, vsuffix)
                        packed_execs.append(exe_path)

            # write per-pack_dir filelist under pack_dir root
            write_filelist(pack_root, packed_execs, logger)
            logger.log("[CONFIG] done")

    finally:
        gendata_params.write_text(original, encoding="utf-8")
        print("[INFO] Restored gendata_params.hjson to original.")


if __name__ == "__main__":
    main()
