#!/usr/bin/env python3
"""Run preserved short-vector ELFs on a private 4x4 VCS image."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--image', type=Path, required=True)
parser.add_argument('--prefix', default='spatzfix')
parser.add_argument('--max-parallel', type=int, default=2)
parser.add_argument('--cases', nargs='+')
parser.add_argument('--elf-dir', type=Path)
parser.add_argument('--run-ns', type=int, default=800000)
parser.add_argument('--gate-up-cycles', type=int, default=74122,
                    help='Expected gate/up cycles; default is the historical reference')
args = parser.parse_args()
image = args.image.resolve()
cases = {
    name: ((args.elf_dir.resolve() if args.elf_dir else
            ROOT / 'hardware/elf_spatzfix/arithmetic') /
           f'{name}.elf', '[VPROBE] ALL_DONE')
    for name in ('probe_e32_m4', 'probe_e32_m1', 'probe_e16_m4', 'probe_e16_m1')
}
cases.update({
    'original_p4': (ROOT / 'hardware/elf_ffn/probe/vprobe_p4.elf',
                    '[VPROBE] ALL_DONE'),
    'nowa_b1_k512': (ROOT / 'hardware/elf_spatzfix/nowa_b1_k512.elf', 'success!'),
    'gemm_calibration': (ROOT / 'hardware/elf_split/ks2/c4_b1_p1.elf', 'success'),
    'gate_up_calibration': (ROOT / 'hardware/elf_split/kt/kc4_auto_small.elf', 'success'),
})
selected = args.cases or [name for name in cases if name != 'original_p4']
image_hash = hashlib.sha256(image.read_bytes()).hexdigest()


def run(name):
    elf, marker = cases[name]
    build = ROOT / 'hardware' / f'{args.prefix}_{name}'
    build.mkdir(exist_ok=False)
    (build / 'cmds.tcl').write_text(f'run {args.run_ns} ns\nquit\n')
    command = [str(image), '-ucli', '-do', 'cmds.tcl',
               '+PRELOAD=' + str(elf), '-l', 'transcript']
    manifest = {
        'command': command, 'image_sha256': image_hash,
        'elf_sha256': hashlib.sha256(elf.read_bytes()).hexdigest(),
        'expected_marker': marker, 'simulation_bound_ns': args.run_ns,
    }
    (build / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'START {name}: {build}', flush=True)
    with (build / 'sim.out').open('w') as out, (build / 'sim.err').open('w') as err:
        # Let UCLI quit normally so the per-hart trace buffers are flushed.
        result = subprocess.run(command, cwd=build, stdout=out, stderr=err)
    output = (build / 'transcript').read_bytes().decode(errors='replace')
    passed = result.returncode == 0 and marker in output
    eoc = re.findall(r'\[EOC\].*\(retval = (\d+)\)', output)
    passed &= eoc == ['0']
    manifest['eoc_returnvalue'] = eoc
    if name.startswith('probe_') or name == 'original_p4':
        phases = range(4, 7) if name == 'original_p4' else range(8)
        manifest['expected_phases'] = list(phases)
        passed &= all(re.search(rf'\[VPROBE\] P{phase}_\S+ OK', output)
                      for phase in phases)
    passed &= not any(s in output for s in ('Fatal:', 'Error-[', 'Assertion failed'))
    measured = re.findall(r'The execution took (\d+) cycles\.', output)
    if measured:
        manifest['measured_cycles'] = measured
    expected_cycles = {'gemm_calibration': 23851, 'gate_up_calibration': args.gate_up_cycles}
    if name in expected_cycles:
        passed &= measured == [str(expected_cycles[name])]
        manifest['expected_cycles'] = expected_cycles[name]
        manifest['measured_cycles'] = measured
    manifest.update(returncode=result.returncode, passed=passed)
    (build / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{"PASS" if passed else "FAIL"} {name}: {build}', flush=True)
    return passed


with ThreadPoolExecutor(max_workers=args.max_parallel) as pool:
    results = list(pool.map(run, selected))
if not all(results):
    raise SystemExit('Inspect failed transcripts')
