#!/usr/bin/env python3

# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# This script automates the build of multiple configurations and workloads.
# Author: Yinrong Li <yinrli@student.ethz.ch>

"""
bench_runner.py — FINAL (meta.json + abbr_map from config +
fixed max_parallel + richer console logs).

Live three-pane terminal UI (rich.live.Live): Queued / Ongoing /
Completed panels, plus a CPU/Mem/Disk header. Per-config runner.log
files still capture START/END/STATUS lines for forensic review.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text


# ============================================================
# Resource monitoring (Linux, no psutil dependency)
# ============================================================

def read_mem_usage_percent() -> float:
    mem: Dict[str, float] = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                mem[parts[0].rstrip(":")] = float(parts[1])  # kB
    total = mem.get("MemTotal", 0.0)
    avail = mem.get("MemAvailable", 0.0)
    if total <= 0:
        return 0.0
    used = max(total - avail, 0.0)
    return used / total * 100.0


def read_disk_usage_percent(path: str = "/") -> float:
    u = shutil.disk_usage(path)
    return (u.used / u.total * 100.0) if u.total else 0.0


async def read_cpu_usage_percent(sample_interval_sec: float = 0.2) -> float:
    # Async-friendly /proc/stat sampler: the only thing this function has to
    # wait for is the sampling window, so use asyncio.sleep so the event loop
    # (other in-flight jobs, TUI redraws, subprocess monitors) keeps making
    # progress instead of blocking for the whole interval.
    def snap() -> Tuple[int, int]:
        with open("/proc/stat", "r", encoding="utf-8") as f:
            vals = list(map(int, f.readline().split()[1:]))
        idle = vals[3] + (vals[4] if len(vals) > 4 else 0)  # idle + iowait
        return sum(vals), idle

    t1, i1 = snap()
    await asyncio.sleep(sample_interval_sec)
    t2, i2 = snap()

    dt = max(t2 - t1, 1)
    didle = max(i2 - i1, 0)
    return max(dt - didle, 0) / dt * 100.0


# ============================================================
# Helpers
# ============================================================

def _as_abs_dir(path_str: str, base_dir: Path) -> Path:
    p = Path(path_str)
    return p if p.is_absolute() else (base_dir / p).resolve()


def _quote(s: str) -> str:
    import shlex
    return shlex.quote(s)


def now_ts() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


# ============================================================
# Logging helper
# ============================================================

class RunnerLog:
    """Async-safe append-only logger."""
    def __init__(self, path: Path):
        self.path = path
        self._lock = asyncio.Lock()

    async def write(self, msg: str) -> None:
        line = f"[{now_ts()}] {msg}\n"
        async with self._lock:
            await asyncio.to_thread(self._append, line)

    def _append(self, line: str) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as f:
            f.write(line)


# ============================================================
# Runner
# ============================================================

@dataclass(frozen=True)
class LoadControl:
    max_parallel: int
    poll_interval_sec: float
    cpu_threshold_percent: float
    mem_threshold_percent: float
    disk_threshold_percent: float
    nice: Optional[int] = None
    ionice_class: Optional[int] = None
    ionice_level: Optional[int] = None


@dataclass(frozen=True)
class EnvConfig:
    conda_sh: str
    conda_env: str


class BenchTUI:
    """Live three-panel display: Queued | Ongoing | Completed."""

    def __init__(self, max_parallel: int):
        self.max_parallel = max_parallel
        self.queued: List[Dict[str, Any]] = []
        self.ongoing: Dict[str, Dict[str, Any]] = {}
        self.completed: List[Dict[str, Any]] = []
        self.cpu = 0.0
        self.mem = 0.0
        self.disk = 0.0

    @staticmethod
    def _key(config_dir: str, app_name: str) -> str:
        return f"{config_dir}/{app_name}"

    def enqueue(self, config_dir: str, app_name: str) -> None:
        self.queued.append({
            "config_dir": config_dir, "app_name": app_name,
        })

    def mark_running(self, config_dir: str, app_name: str,
                     t_start: float) -> None:
        for i, q in enumerate(self.queued):
            if (q["config_dir"] == config_dir and
                    q["app_name"] == app_name):
                self.queued.pop(i)
                break
        self.ongoing[self._key(config_dir, app_name)] = {
            "config_dir": config_dir, "app_name": app_name,
            "start_ts": t_start,
        }

    def mark_done(self, config_dir: str, app_name: str,
                  rc: int, elapsed: float) -> None:
        self.ongoing.pop(self._key(config_dir, app_name), None)
        self.completed.append({
            "config_dir": config_dir, "app_name": app_name,
            "rc": rc, "elapsed": elapsed,
        })

    def update_resources(self, cpu: float, mem: float,
                         disk: float) -> None:
        self.cpu = cpu
        self.mem = mem
        self.disk = disk

    def __rich__(self) -> Layout:
        header_text = Text.assemble(
            "Running ",
            (f"{len(self.ongoing)}/{self.max_parallel}", "bold cyan"),
            "  |  CPU=",
            (f"{self.cpu:5.1f}%", "yellow"),
            "  Mem=",
            (f"{self.mem:5.1f}%", "yellow"),
            "  Disk=",
            (f"{self.disk:5.1f}%", "yellow"),
            f"  |  Queued={len(self.queued)}  ",
            f"Completed={len(self.completed)}",
        )

        queued_tbl = Table(
            title=f"Queued ({len(self.queued)})",
            expand=True, show_header=True, header_style="bold magenta",
        )
        queued_tbl.add_column("config_dir", overflow="fold")
        queued_tbl.add_column("app", overflow="fold")
        for q in self.queued[:50]:
            queued_tbl.add_row(q["config_dir"], q["app_name"])

        ongoing_tbl = Table(
            title=f"Ongoing ({len(self.ongoing)})",
            expand=True, show_header=True, header_style="bold yellow",
        )
        ongoing_tbl.add_column("config_dir", overflow="fold")
        ongoing_tbl.add_column("app", overflow="fold")
        ongoing_tbl.add_column("elapsed", justify="right")
        now = time.time()
        for v in self.ongoing.values():
            ongoing_tbl.add_row(
                v["config_dir"], v["app_name"],
                f"{now - v['start_ts']:.1f}s",
            )

        completed_tbl = Table(
            title=f"Completed ({len(self.completed)})",
            expand=True, show_header=True, header_style="bold green",
        )
        completed_tbl.add_column("config_dir", overflow="fold")
        completed_tbl.add_column("app", overflow="fold")
        completed_tbl.add_column("rc", justify="right")
        completed_tbl.add_column("elapsed", justify="right")
        # newest at top, last 50
        for c in self.completed[-50:][::-1]:
            rc_style = "green" if c["rc"] == 0 else "red bold"
            completed_tbl.add_row(
                c["config_dir"], c["app_name"],
                Text(str(c["rc"]), style=rc_style),
                f"{c['elapsed']:.1f}s",
            )

        layout = Layout()
        layout.split_column(
            Layout(
                Panel(header_text, title="Bench Runner",
                      border_style="cyan"),
                name="header", size=3,
            ),
            Layout(name="body"),
        )
        layout["body"].split_row(
            Layout(queued_tbl, name="queued"),
            Layout(ongoing_tbl, name="ongoing"),
            Layout(completed_tbl, name="completed"),
        )
        return layout


class BenchRunner:
    def __init__(self, cfg: Dict[str, Any], config_dir: Path):
        self.config_dir = config_dir
        self.exec_root = _as_abs_dir(cfg["exec_root"], config_dir)
        self.results_dir_global = _as_abs_dir(cfg["results_dir"], config_dir)

        # Abbreviation mapping from config (order preserved)
        self.abbr_map: Dict[str, str] = cfg.get("abbr_map", {}) or {}
        if not isinstance(self.abbr_map, dict):
            raise ValueError("'abbr_map' must be a dict if provided.")

        self.ulimit_nofile = cfg.get("ulimit_nofile", None)

        env = cfg["env"]
        self.env = EnvConfig(
            conda_sh=env["conda_sh"], conda_env=env["conda_env"]
        )

        lc = cfg["load_control"]
        self.load = LoadControl(
            max_parallel=int(lc["max_parallel"]),
            poll_interval_sec=float(lc.get("poll_interval_sec", 1.0)),
            cpu_threshold_percent=float(lc.get("cpu_threshold_percent", 70.0)),
            mem_threshold_percent=float(lc.get("mem_threshold_percent", 70.0)),
            disk_threshold_percent=float(
                lc.get("disk_threshold_percent", 90.0)
            ),
            nice=lc.get("nice"),
            ionice_class=lc.get("ionice_class"),
            ionice_level=lc.get("ionice_level"),
        )

        paths = cfg.get("paths", {}) or {}
        self.build_prefix = paths.get("build_prefix", "build_")

        self.make_steps: List[str] = cfg["make_steps"]
        self.copy_rules: List[Dict[str, Any]] = cfg.get("copy_rules", []) or []
        self.configs: List[Dict[str, Any]] = cfg["configs"]

        self.tui = BenchTUI(self.load.max_parallel)

    # --------------------
    # Naming
    # --------------------

    def build_make_config_str(self, cfg_obj: Dict[str, Any]) -> str:
        base = cfg_obj.get("config")
        if not base:
            raise ValueError("config entry missing required field: 'config'")
        parts = [f"config={base}"]
        params = cfg_obj.get("params", {}) or {}
        if not isinstance(params, dict):
            raise ValueError("'params' must be a dict if provided.")
        for k in sorted(params.keys()):
            parts.append(f"{k}={params[k]}")
        return " ".join(parts)

    def build_config_dir_name(
        self, cfg_obj: Dict[str, Any], timestamp: str
    ) -> str:
        base = cfg_obj.get("config")
        if not base:
            raise ValueError("config entry missing required field: 'config'")

        name = cfg_obj.get("name")
        if name:
            base_name = f"{base}_{name}_{timestamp}"
        else:
            params = cfg_obj.get("params", {}) or {}
            tokens: List[str] = []
            for key, abbr in self.abbr_map.items():
                if key in params:
                    tokens.append(f"{abbr}{params[key]}")
            base_name = (
                f"{base}_{'_'.join(tokens)}_{timestamp}"
                if tokens else f"{base}_{timestamp}"
            )

        extra = cfg_obj.get("extra_info", "") or ""
        return f"{base_name}{extra}"

    # --------------------
    # Shell & scheduling
    # --------------------

    def _shell_prefix(self) -> str:
        parts: List[str] = []
        if self.ulimit_nofile:
            parts.append(f"ulimit -n {int(self.ulimit_nofile)}")
        parts.append(f"source {_quote(self.env.conda_sh)}")
        parts.append(f"conda activate {_quote(self.env.conda_env)}")
        parts.append(f"cd {_quote(str(self.exec_root))}")
        return " && ".join(parts)

    def _sched_prefix(self) -> str:
        p = ""
        if (self.load.ionice_class is not None
                and self.load.ionice_level is not None):
            p += (
                f"ionice -c {int(self.load.ionice_class)} "
                f"-n {int(self.load.ionice_level)} "
            )
        if self.load.nice is not None:
            p += f"nice -n {int(self.load.nice)} "
        return p

    async def wait_for_capacity(
        self, running_fn: Callable[[], int]
    ) -> Tuple[int, float, float, float]:
        """
        Returns (running, cpu, mem, disk) snapshot when admitted.
        """
        while True:
            running = int(running_fn())
            cpu = await read_cpu_usage_percent()
            mem = read_mem_usage_percent()
            disk = read_disk_usage_percent("/")

            self.tui.update_resources(cpu, mem, disk)

            if running < self.load.max_parallel:
                if (cpu < self.load.cpu_threshold_percent
                        and mem < self.load.mem_threshold_percent
                        and disk < self.load.disk_threshold_percent):
                    return running, cpu, mem, disk

            await asyncio.sleep(self.load.poll_interval_sec)

    # --------------------
    # Copy rules
    # --------------------

    def _resolve_src_in_exec_root(self, maybe_path: str) -> Path:
        p = Path(maybe_path)
        return p if p.is_absolute() else (self.exec_root / p).resolve()

    def _resolve_dst_in_cwd(self, maybe_path: str) -> Path:
        p = Path(maybe_path)
        return p if p.is_absolute() else (self.config_dir / p).resolve()

    def _apply_copy_rules(self, ctx: Dict[str, str]) -> None:
        for rule in self.copy_rules:
            rtype = rule["type"]
            optional = bool(rule.get("optional", False))

            src_s = rule["src"].format(**ctx)
            dst_s = rule["dst"].format(**ctx)

            src_p = self._resolve_src_in_exec_root(src_s)
            dst_p = self._resolve_dst_in_cwd(dst_s)

            if not src_p.exists():
                if optional:
                    continue
                raise FileNotFoundError(
                    f"Required artifact not found: {src_p}"
                )

            dst_p.parent.mkdir(parents=True, exist_ok=True)

            if rtype == "file":
                shutil.copy2(src_p, dst_p)
            elif rtype == "dir":
                if dst_p.exists():
                    shutil.rmtree(dst_p)
                shutil.copytree(src_p, dst_p)
            else:
                raise ValueError(f"Unknown copy rule type: {rtype}")

    # --------------------
    # Meta.json
    # --------------------

    def _write_meta_json(self, meta_path: Path, meta: Dict[str, Any]) -> None:
        meta_path.parent.mkdir(parents=True, exist_ok=True)
        with meta_path.open("w", encoding="utf-8") as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)

    # --------------------
    # Group expansion
    # --------------------

    async def iter_config_groups(self) -> List[Dict[str, Any]]:
        groups: List[Dict[str, Any]] = []

        for cfg_obj in self.configs:
            if not cfg_obj.get("config"):
                raise ValueError("Each config entry must include 'config'")
            if not cfg_obj.get("binary_dir"):
                raise ValueError("Each config entry must include 'binary_dir'")
            apps = cfg_obj.get("apps")
            if not apps or not isinstance(apps, list):
                raise ValueError(
                    "Each config entry must include a non-empty 'apps' list"
                )

            results_dir_override = cfg_obj.get("results_dir")
            results_root = (
                _as_abs_dir(results_dir_override, self.config_dir)
                if results_dir_override else self.results_dir_global
            )

            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            config_dir = self.build_config_dir_name(cfg_obj, timestamp)
            config_result_root = (results_root / config_dir).resolve()
            config_result_root.mkdir(parents=True, exist_ok=True)

            runner_log = RunnerLog(config_result_root / "runner.log")

            make_cfg_str = self.build_make_config_str(cfg_obj)
            binary_dir = str(cfg_obj["binary_dir"]).rstrip("/")

            jobs: List[Dict[str, str]] = []
            for app_name in apps:
                result_dir = (config_result_root / app_name).resolve()
                buildpath = (
                    self.exec_root
                    / f"{self.build_prefix}{config_dir}"
                    / app_name
                ).resolve()
                jobs.append({
                    "app_name": app_name,
                    "app_make": f"{binary_dir}/{app_name}",
                    "buildpath": str(buildpath),
                    "result_dir": str(result_dir),
                    "app_log": str((result_dir / "app.log").resolve()),
                })

            meta = {
                "created_at": now_ts(),
                "timestamp": timestamp,
                "exec_root": str(self.exec_root),
                "results_root": str(results_root),
                "config_dir": config_dir,
                "build_prefix": self.build_prefix,
                "abbr_map": self.abbr_map,
                "make_config_str": make_cfg_str,
                "binary_dir": binary_dir,
                "apps": apps,
                "config": cfg_obj,
                "jobs": jobs
            }
            self._write_meta_json(config_result_root / "meta.json", meta)

            groups.append({
                "cfg_obj": cfg_obj,
                "jobs": jobs,
                "make_cfg_str": make_cfg_str,
                "config_dir": config_dir,
                "results_root": str(results_root),
                "config_result_root": str(config_result_root),
                "binary_dir": binary_dir,
                "config_name": str(cfg_obj["config"]),
                "runner_log": runner_log,
            })

            # Cooperative yield between groups: keeps the event loop responsive
            # to any other coroutine already running (TUI redraws, log writes)
            # without stalling on time.sleep. The short pause also helps space
            # out the per-second config-dir timestamps when many configs are
            # processed back-to-back.
            await asyncio.sleep(0.01)

        return groups

    def make_job_ctx(
        self,
        job: Dict[str, str],
        make_cfg_str: str,
        config_result_root: str,
    ) -> Dict[str, str]:
        return {
            "app_name": job["app_name"],
            "app": job["app_make"],
            "config": make_cfg_str,
            "buildpath": job["buildpath"],
            "result_dir": job["result_dir"],
            "config_result_root": config_result_root,
        }

    # --------------------
    # Execution
    # --------------------

    async def run_one(self, ctx: Dict[str, str], rlog: RunnerLog) -> int:
        result_dir = Path(ctx["result_dir"])
        result_dir.mkdir(parents=True, exist_ok=True)
        app_log_path = result_dir / "app.log"

        steps = [s.format(**ctx) for s in self.make_steps]
        sched = self._sched_prefix()
        full_cmd = (
            self._shell_prefix()
            + " && "
            + " && ".join(f"{sched}{step}" for step in steps)
        )

        await rlog.write(
            f"START app_name={ctx['app_name']} app_make={ctx['app']}"
        )
        await rlog.write(f"BUILD    {ctx['buildpath']}")
        await rlog.write(f"RESULT   {ctx['result_dir']}")
        await rlog.write(f"CMD      {full_cmd}")

        proc = await asyncio.create_subprocess_shell(
            full_cmd,
            executable="/bin/bash",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )

        assert proc.stdout is not None
        with app_log_path.open("wb") as f:
            while True:
                chunk = await proc.stdout.read(4096)
                if not chunk:
                    break
                f.write(chunk)

        rc = await proc.wait()
        await rlog.write(f"END   app_name={ctx['app_name']} rc={rc}")

        try:
            self._apply_copy_rules(ctx)
        except Exception as e:
            await rlog.write(
                f"COPY_RULES_ERROR app_name={ctx['app_name']} err={repr(e)}"
            )

        return rc

    async def run_all(self) -> int:
        groups = await self.iter_config_groups()
        sem = asyncio.Semaphore(self.load.max_parallel)

        tasks: List[asyncio.Task] = []
        # (config_dir, app_name, rc, elapsed)
        results: List[Tuple[str, str, int, float]] = []

        # map task -> display info
        task_info: Dict[asyncio.Task, Dict[str, str]] = {}

        async def _wrapped(
            ctx: Dict[str, str],
            rlog: RunnerLog,
            info: Dict[str, str],
        ) -> None:
            async with sem:
                t0 = time.time()
                self.tui.mark_running(
                    info["config_dir"], ctx["app_name"], t0
                )

                rc = await self.run_one(ctx, rlog)
                elapsed = time.time() - t0
                results.append(
                    (info["config_dir"], ctx["app_name"], rc, elapsed)
                )
                self.tui.mark_done(
                    info["config_dir"], ctx["app_name"], rc, elapsed
                )

                status = "OK" if rc == 0 else f"FAIL({rc})"
                await rlog.write(
                    f"STATUS {status} app_name={ctx['app_name']} "
                    f"elapsed_sec={elapsed:.3f}"
                )

        # Pre-populate the Queued pane in declaration order, across all groups.
        for g in groups:
            for job in g["jobs"]:
                self.tui.enqueue(g["config_dir"], job["app_name"])

        with Live(self.tui, refresh_per_second=4, screen=True):
            # launch jobs sequentially with gating
            for g in groups:
                rlog: RunnerLog = g["runner_log"]
                config_dir = g["config_dir"]

                await rlog.write(f"CONFIG_START config_dir={config_dir}")
                await rlog.write(f"RESULTS_ROOT {g['results_root']}")
                await rlog.write(
                    f"CONFIG_RESULT_ROOT {g['config_result_root']}"
                )
                await rlog.write(f"BINARY_DIR {g['binary_dir']}")
                await rlog.write(f"MAKE_CONFIG_STR {g['make_cfg_str']}")
                await rlog.write(f"EXEC_ROOT {self.exec_root}")
                await rlog.write("META_JSON meta.json written")

                for job in g["jobs"]:
                    running, cpu, mem, disk = await self.wait_for_capacity(
                        lambda: sum(1 for t in tasks if not t.done())
                    )

                    ctx = self.make_job_ctx(
                        job,
                        g["make_cfg_str"],
                        g["config_result_root"],
                    )
                    await rlog.write(
                        f"LAUNCH app_name={ctx['app_name']} "
                        f"running={running} cpu={cpu:.1f}% "
                        f"mem={mem:.1f}% disk={disk:.1f}% "
                        f"result_dir={ctx['result_dir']}"
                    )

                    info = {
                        "config_dir": config_dir,
                        "config_name": g["config_name"],
                        "binary_dir": g["binary_dir"],
                    }

                    t = asyncio.create_task(_wrapped(ctx, rlog, info))
                    task_info[t] = info
                    tasks.append(t)

                await rlog.write(f"CONFIG_LAUNCHED apps={len(g['jobs'])}")

            await asyncio.gather(*tasks)

        # terminal summary (after Live exits the alt-screen)
        failed = [(c, a, rc, el) for (c, a, rc, el) in results if rc != 0]
        print("\n=== Summary ===")
        print(f"Total: {len(results)}, Failed: {len(failed)}")
        for c, a, rc, el in failed[:50]:
            print(f"  - config_dir={c} app={a} rc={rc} elapsed={el:.1f}s")

        # per-config end log entries
        for g in groups:
            config_dir = g["config_dir"]
            group_results = [
                (c, a, rc, el)
                for (c, a, rc, el) in results
                if c == config_dir
            ]
            group_failed = [
                (c, a, rc, el)
                for (c, a, rc, el) in group_results
                if rc != 0
            ]

            rlog: RunnerLog = g["runner_log"]
            await rlog.write(
                f"CONFIG_END total={len(group_results)} "
                f"failed={len(group_failed)}"
            )
            for _, a, rc, el in group_failed[:50]:
                await rlog.write(
                    f"FAILED app_name={a} rc={rc} elapsed_sec={el:.3f}"
                )

        return 1 if failed else 0


# ============================================================
# Entrypoint
# ============================================================

def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


async def main_async() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--config", default="bench_config.json",
        help="Path to bench_config.json",
    )
    ap.add_argument(
        "--dry-run", action="store_true",
        help="Preview expanded config dirs/jobs and exit",
    )
    args = ap.parse_args()

    config_path = Path(args.config).expanduser().resolve()
    cfg = load_json(config_path)
    runner = BenchRunner(cfg, config_path.parent)

    if args.dry_run:
        groups = await runner.iter_config_groups()
        for g in groups:
            root = Path(g["config_result_root"])
            print("==== CONFIG GROUP ====")
            print("config_dir         :", g["config_dir"])
            print("exec_root          :", str(runner.exec_root))
            print("results_root       :", g["results_root"])
            print("config_result_root :", g["config_result_root"])
            print("runner_log         :", str(root / "runner.log"))
            print("meta_json          :", str(root / "meta.json"))
            print("config_name        :", g["config_name"])
            print("binary_dir         :", g["binary_dir"])
            print("make_config_str    :", g["make_cfg_str"])
            print("apps               :", len(g["jobs"]))
            for job in g["jobs"]:
                print("  ----")
                print("  app_name  :", job["app_name"])
                print("  app_make  :", job["app_make"])
                print("  buildpath :", job["buildpath"])
                print("  result_dir:", job["result_dir"])
                print("  app_log   :", job["app_log"])
        return 0

    return await runner.run_all()


def main() -> None:
    rc = asyncio.run(main_async())
    raise SystemExit(rc)


if __name__ == "__main__":
    main()
