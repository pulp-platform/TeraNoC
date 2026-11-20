#!/usr/bin/env python3
"""Compile and run the focused metadata-reuse test in a fresh Questa library."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--rtl-file', type=Path,
                        default=ROOT / 'hardware/src/mempool_group_mshr.sv')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=False)
    defines = dict(NUM_CORES=16, NUM_CORES_PER_TILE=1, RVV=1, NUM_GROUPS=4,
                   NUM_X=2, BANKING_FACTOR=4, L1_BANK_SIZE=1024,
                   AXI_DATA_WIDTH=64, L2_SIZE=65536, L2_BANKS=4,
                   NUM_REMOTE_PORTS_PER_TILE=3, N_IPU=4, N_FPU=4,
                   GROUP_MSHR_NUM=8, GROUP_MSHR_OVERFLOW_NUM=1,
                   GROUP_MSHR_CFG_RUNTIME=1, GROUP_MSHR_HOLD_PRESCALE_W=0,
                   GROUP_MSHR_BANK_HASH=0, GROUP_MSHR_BANK_PUBLISH=1, GROUP_MSHR_ENABLE_STATS=0,
                   GROUP_MSHR_BYPASS_PROBE=0, GROUP_MSHR_RESP_HOLD_PROBE=0)
    sources = [ROOT / ('hardware/' + x) for x in (
        'deps/common_cells/src/cf_math_pkg.sv', 'deps/axi/src/axi_pkg.sv',
        'deps/fpnew/src/fpnew_pkg.sv', 'deps/snitch/src/riscv_instr.sv',
        'deps/snitch/src/snitch_pkg.sv', 'deps/reqrsp_interface/src/reqrsp_pkg.sv',
        'src/mempool_pkg.sv',
        'deps/common_cells/src/spill_register_flushable.sv',
        'deps/common_cells/src/spill_register.sv',
        'src/mempool_group_mshr_req_decode.sv',
        'src/mempool_group_mshr_free_way.sv', 'src/mempool_group_mshr_bank_arb.sv')]
    sources += [args.rtl_file.resolve(), ROOT / 'hardware/tb/tb_group_mshr_meta_reuse.sv']
    includes = [ROOT / 'hardware' / d for d in (
        'include', 'deps/axi/include', 'deps/common_cells/include',
        'deps/reqrsp_interface/include')]
    snapshots = {}
    for i, source in enumerate(sources):
        snapshot = build / 'sources' / f'{i:02d}_{source.name}'
        snapshot.parent.mkdir(exist_ok=True)
        shutil.copyfile(source, snapshot)
        snapshots[str(source)] = str(snapshot)
    include_snapshots = []
    for i, directory in enumerate(includes):
        snapshot = build / 'includes' / str(i)
        shutil.copytree(directory, snapshot)
        include_snapshots.append(snapshot)
        for source in directory.rglob('*'):
            if source.is_file():
                snapshots[str(source)] = str(snapshot / source.relative_to(directory))
    hashes = {source: hashlib.sha256(Path(snapshot).read_bytes()).hexdigest()
              for source, snapshot in snapshots.items()}
    (build / 'sources.json').write_text(json.dumps(
        {'sha256': hashes, 'snapshot': snapshots, 'defines': defines}, indent=2) + '\n')
    commands = [
        ['vlib', 'work'],
        ['vlog', '-sv', '-timescale', '1ns/1ps', '+define+TARGET_SPATZ'] +
        [f'+define+{k}={v}' for k, v in defines.items()] +
        ['+incdir+' + str(p) for p in include_snapshots] +
        [snapshots[str(p)] for p in sources],
        ['vsim', '-c', '-voptargs=+acc', 'work.tb_group_mshr_meta_reuse',
         '-do', 'log -r /*; run -all; quit -code 0'],
    ]
    (build / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    for name, command in zip(('library', 'compile', 'run'), commands):
        print(shlex.join(command), flush=True)
        with (build / (name + '.log')).open('w') as log:
            subprocess.run(command, cwd=build, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=300)
    output = (build / 'run.log').read_text()
    print(output)
    if 'PASS metadata reuse' not in output:
        raise SystemExit('Regression did not pass; inspect run.log')


if __name__ == '__main__':
    main()
