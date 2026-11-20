#!/usr/bin/env python3
"""Run focused Snitch ordering tests in an isolated Questa library."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--buildpath', type=Path, default=ROOT / 'hardware/build_scalar_accel_ordering')
args = parser.parse_args()
build = args.buildpath.resolve()
build.mkdir(parents=True, exist_ok=True)


def run(tool, *arguments):
    subprocess.run(['questa-2023.4-zr', tool, *map(str, arguments)], cwd=build, check=True)


sources = [
    'hardware/deps/common_cells/src/cf_math_pkg.sv',
    'hardware/deps/fpnew/src/fpnew_pkg.sv',
    'hardware/deps/snitch/src/riscv_instr.sv',
    'hardware/deps/snitch/src/snitch_pkg.sv',
    'hardware/deps/common_cells/src/lzc.sv',
    'hardware/deps/snitch/src/snitch_regfile_ff.sv',
    'hardware/deps/snitch/src/snitch_lsu.sv',
    'hardware/deps/snitch/src/snitch.sv',
    'hardware/tb/scalar_accel_ordering/tb.sv',
]
run('vlib', 'work')
run('vlog', '-sv', '+define+TARGET_SPATZ', '+define+XPULPIMG=0',
    '+define+SNITCH_ENABLE_PERF', '+define+SNITCH_ENABLE_STALL_COUNTER',
    '+define+ZFINX=0', '+define+ZQUARTERINX=0', '+define+XDIVSQRT=0',
    f'+incdir+{ROOT}/hardware/deps/common_cells/include',
    *(ROOT / source for source in sources))
for ordering in (0, 1):
    log = build / f'ordering_{ordering}.log'
    run('vsim', '-c', '-voptargs=+acc', f'-gOrdering={ordering}',
        '-wlf', f'ordering_{ordering}.wlf', '-l', log, 'work.tb', '-do',
        'onerror {quit -code 1}; onbreak {quit -code 1}; '
        'log -r /*; run -all; quit -code 0')
    transcript = log.read_text()
    if (f'PASS scalar/accelerator ordering={ordering}' not in transcript
            or '** Error' in transcript or '** Fatal' in transcript):
        raise SystemExit(f'Simulation failed: {log}')
