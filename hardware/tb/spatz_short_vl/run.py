#!/usr/bin/env python3
"""Run focused Spatz VFU, controller/VRF/slide, or VLSU regressions."""
import argparse
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--buildpath', type=Path, required=True)
parser.add_argument('--rtl-file', type=Path, default=ROOT / 'working_dir/spatz/hw/ip/spatz/src/spatz_vfu.sv')
parser.add_argument('--long-only', action='store_true')
parser.add_argument('--trace', action='store_true')
parser.add_argument('--mixed', action='store_true')
parser.add_argument('--reorder', action='store_true')
parser.add_argument('--skew', action='store_true')
parser.add_argument('--skew-add', action='store_true')
parser.add_argument('--integration', action='store_true')
parser.add_argument('--slide-file', type=Path)
parser.add_argument('--loads', action='store_true')
parser.add_argument('--load-file', type=Path)
parser.add_argument('--load-e32', action='store_true')
parser.add_argument('--load-long', action='store_true')
parser.add_argument('--load-dual', type=int, choices=(1, 2), default=2)
parser.add_argument('--load-block-alloc', type=int, choices=(0, 1), default=1)
parser.add_argument('--rob-count-id', type=int, choices=(0, 1), default=1)
args = parser.parse_args()
build = args.buildpath.resolve()
build.mkdir(parents=True, exist_ok=True)
common = 'hardware/deps/common_cells/src/'
fpnew = 'hardware/deps/fpnew/src/'
spatz = 'working_dir/spatz/hw/ip/spatz/src/'
sources = [common + name for name in (
    'cf_math_pkg.sv', 'lzc.sv', 'rr_arb_tree.sv', 'fifo_v3.sv',
    'deprecated/find_first_one.sv',
    'spill_register_flushable.sv', 'spill_register.sv')]
sources += [fpnew + name for name in (
    'fpnew_pkg.sv', 'fpnew_cast_multi.sv', 'fpnew_classifier.sv',
    'fpnew_fma.sv', 'fpnew_fma_multi.sv', 'fpnew_noncomp.sv',
    'fpnew_opgroup_block.sv', 'fpnew_opgroup_fmt_slice.sv',
    'fpnew_opgroup_multifmt_slice.sv', 'fpnew_rounding.sv', 'lfsr_sr.sv',
    'fpnew_top.sv')]
sources += [spatz + name for name in (
    'rvv_pkg.sv', 'generated/spatz_pkg.sv', 'spatz_serdiv.sv',
    'spatz_simd_lane.sv', 'spatz_ipu.sv', 'spatz_vfu.sv')]
paths = [args.rtl_file.resolve() if p.endswith('/spatz_vfu.sv') else ROOT / p for p in sources]
paths.insert(0, ROOT / 'hardware/deps/snitch/src/riscv_instr.sv')
if args.integration:
    paths += [ROOT / name for name in (
        'hardware/deps/common_cells/src/fall_through_register.sv',
        'hardware/deps/tech_cells_generic/src/rtl/tc_clk.sv',
        'working_dir/spatz/hw/ip/spatz/src/spatz_decoder.sv',
        'working_dir/spatz/hw/ip/spatz/src/vregfile.sv',
        'working_dir/spatz/hw/ip/spatz/src/spatz_vrf.sv',
        'working_dir/spatz/hw/ip/spatz/src/spatz_controller.sv',
        'working_dir/spatz/hw/ip/spatz/src/spatz_vsldu.sv')]
if args.slide_file:
    paths = [args.slide_file.resolve() if p.name == 'spatz_vsldu.sv' else p for p in paths]
if args.loads:
    paths += [ROOT / name for name in (
        'hardware/deps/common_cells/src/delta_counter.sv',
        'working_dir/spatz/hw/ip/spatz/src/reorder_buffer.sv',
        'working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv')]
if args.load_file:
    paths = [args.load_file.resolve() if p.name == 'spatz_vlsu.sv' else p for p in paths]
paths.append(ROOT / ('hardware/tb/spatz_short_vl/load.sv' if args.loads else
                    'hardware/tb/spatz_short_vl/chain.sv' if args.integration else
                     'hardware/tb/spatz_short_vl/tb.sv'))
# Keep the exact tested RTL alongside the logs and waves.
snapshots = []
manifest = {}
for i, path in enumerate(paths):
    dest = build / 'sources' / f'{i:02d}_{path.name}'
    dest.parent.mkdir(exist_ok=True)
    shutil.copyfile(path, dest)
    snapshots.append(dest)
    manifest[str(path)] = hashlib.sha256(dest.read_bytes()).hexdigest()
paths = snapshots
(build / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n')
commands = [
    ['questa-2023.4-zr', 'vlib', 'work'],
    ['questa-2023.4-zr', 'vlog', '-sv', '+define+RVF=1', '+define+RVD=0',
     '+define+VLEN=512', '+define+N_IPU=4', '+define+N_FPU=4',
     *(['+define+TARGET_MEMPOOL', '+define+SPATZ_VLSU_ROB_DEPTH=32',
        f'+define+SPATZ_VLSU_BLOCK_ALLOC={args.load_block_alloc}',
        f'+define+SPATZ_ROB_CNT_IDVALID={args.rob_count_id}',
        f'+define+SPATZ_VLSU_DUAL_LOAD={args.load_dual}',
        '+define+SPATZ_VLSU_COMMIT_QMIN=1']
       if args.loads else []),
     '+incdir+' + str(ROOT / 'hardware/deps/common_cells/include')] + list(map(str, paths)),
    ['questa-2023.4-zr', 'vsim', '-c', '-voptargs=+acc', '-wlf', 'vfu.wlf',
     'work.mempool_tb' if args.loads else 'work.chain' if args.integration else 'work.tb',
     *(['+long_only'] if args.long_only else []),
     *(['+trace'] if args.trace else []),
     *(['+load_e32'] if args.load_e32 else []),
     *(['+load_long'] if args.load_long else []),
     *(['+mixed'] if args.mixed else []),
     *(['+reorder'] if args.reorder else []),
     *(['+skew'] if args.skew or args.skew_add else []),
     *(['+skew_add'] if args.skew_add else []), '-do', 'onerror {quit -code 1}; onbreak {quit -code 1}; log -r /*; run -all; quit -code 0'],
]
(build / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
for name, command in zip(('library', 'compile', 'run'), commands):
    with (build / (name + '.log')).open('w') as log:
        result = subprocess.run(command, cwd=build, stdout=log, stderr=subprocess.STDOUT, timeout=300)
    if result.returncode:
        print((build / (name + '.log')).read_text()[-12000:])
        raise SystemExit(result.returncode)
output = (build / 'run.log').read_text()
print('\n'.join(line for line in output.splitlines() if any(
    marker in line for marker in ('PASS short VL', '** Error', '** Fatal', '# C', '# LONG', '# CHAIN'))))
if 'PASS short VL' not in output or '** Error' in output or '** Fatal' in output:
    raise SystemExit('Spatz regression failed')
