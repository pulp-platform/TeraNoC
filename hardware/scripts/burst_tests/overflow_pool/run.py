#!/usr/bin/env python3
"""Run real-MSHR overflow-pool regressions in a new, private VCS library."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
OVERRIDES = {
    'GROUP_MSHR_CFG_RUNTIME': 1,
    'GROUP_MSHR_HOLD_PRESCALE_W': 0,
    'GROUP_MSHR_BANK_HASH': 0,
    'GROUP_MSHR_ENABLE_STATS': 0,
    'GROUP_MSHR_BYPASS_PROBE': 0,
    'GROUP_MSHR_RESP_HOLD_PROBE': 0,
}


def check_license():
    result = subprocess.run(
        ['lmutil', 'lmstat', '-c', '8169@lic-synopsys.ethz.ch',
         '-f', 'VCS-Base-Runtime-Pkg'],
        capture_output=True, text=True, timeout=30, check=True)
    match = re.search(r'Total of (\d+) licenses? issued;\s*'
                      r'Total of (\d+) licenses? in use', result.stdout)
    if not match or int(match[1]) - int(match[2]) < 21:
        raise SystemExit('Need at least 21 free VCS runtime seats to leave 20 free')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compile-script', type=Path, required=True)
    parser.add_argument('--build-dir', type=Path, required=True,
                        help='Must not already exist; no shared libraries are reused')
    parser.add_argument('--rtl-file', type=Path,
                        default=ROOT / 'hardware/src/mempool_group_mshr.sv')
    parser.add_argument('--pool-num', type=int, choices=(0, 1, 2), default=1)
    parser.add_argument('--top', choices=('overflow_pool_tb', 'pool_response_tb'),
                        default='overflow_pool_tb')
    parser.add_argument('--define', action='append', default=[], metavar='NAME=VALUE',
                        help='Override an additional compile define; repeatable')
    parser.add_argument('--cases', nargs='+',
                        default=['alloc_stall', 'owner_parallel',
                                 'replay_scalar', 'replay_burst'])
    parser.add_argument('--vcs', default='vcs-2024.09-zr')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=False)
    (build / 'license.log').write_text(check_license())
    sources = build / 'sources'
    sources.mkdir()
    seen = {}
    hashes = {}
    headers = {}
    include_dir = build / 'includes'
    # These project headers can change independently of a frozen DUT file. Keep
    # the statistics and interface macro definitions fixed for the whole build.
    for relative in ('mempool/mempool.svh', 'mempool/mempool_group_mshr_stats.svh'):
        source = ROOT / 'hardware/include' / relative
        snapshot = include_dir / relative
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        snapshot.write_bytes(data)
        headers[str(source)] = str(snapshot)
        hashes[str(source)] = hashlib.sha256(data).hexdigest()
    commands = []
    overrides = OVERRIDES | {'TB_POOL_NUM': args.pool_num}
    for definition in args.define:
        match = re.fullmatch(r'([A-Za-z_][A-Za-z_0-9]*)=(.+)', definition)
        if not match:
            parser.error(f'Invalid --define {definition!r}; expected NAME=VALUE')
        overrides[match[1]] = match[2]

    def freeze(source):
        source = Path(source).resolve()
        if source.name == 'mempool_group_mshr.sv':
            source = args.rtl_file.resolve()
        if str(source) in seen:
            return None
        snapshot = sources / f'{len(seen):02d}_{source.name}'
        data = source.read_bytes()
        snapshot.write_bytes(data)
        seen[str(source)] = str(snapshot)
        hashes[str(source)] = hashlib.sha256(data).hexdigest()
        return str(snapshot)

    script = args.compile_script.read_text().replace('\\\n', ' ')
    script = script.replace('$ROOT', str(ROOT))
    for line in script.splitlines():
        if ' vlogan ' not in line:
            continue
        tokens = shlex.split(line)
        opts = [x for x in tokens if not x.endswith(('.sv', '.v'))]
        opts[0] = args.vcs
        opts.insert(2, '+incdir+' + str(include_dir))
        opts = [x for x in opts if not any(
            x == f'+define+{key}' or x.startswith(f'+define+{key}=')
            for key in overrides)]
        opts += [f'+define+{key}={value}' for key, value in overrides.items()]
        selected = []
        for source in tokens:
            if not source.endswith(('.sv', '.v')):
                continue
            if not (source.endswith(('_pkg.sv', '/riscv_instr.sv')) or
                    '/mempool_group_mshr' in source):
                continue
            selected_source = freeze(source)
            if selected_source:
                selected.append(selected_source)
        if selected:
            commands.append(opts + selected)
    if not commands or str(args.rtl_file.resolve()) not in seen:
        raise SystemExit('Compile script did not supply the DUT and packages')
    extra = [ROOT / 'hardware/deps/common_cells/src/spill_register_flushable.sv',
             ROOT / 'hardware/deps/common_cells/src/spill_register.sv',
             HERE / f'{args.top}.sv']
    commands.append(opts + [freeze(source) for source in extra])
    commands.append([args.vcs, 'vcs', '-full64', '-sverilog', '-debug_access+all',
                     '-top', args.top, '-o', str(build / 'simv')])
    (build / 'sources.json').write_text(json.dumps(
        {'sha256': hashes, 'snapshot': seen, 'headers': headers,
         'overrides': overrides}, indent=2) + '\n')
    with (build / 'compile.log').open('w') as log:
        for command in commands:
            log.write('COMMAND ' + shlex.join(command) + '\n')
            log.flush()
            subprocess.run(command, cwd=build, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=600)
    compile_output = (build / 'compile.log').read_text()
    for snapshot in headers.values():
        if f"Parsing included file '{snapshot}'" not in compile_output:
            raise RuntimeError(f'Compiler did not read frozen project header: {snapshot}')
    failed = []
    for case in args.cases:
        (build / 'license.log').write_text(check_license())
        case_dir = build / case
        case_dir.mkdir()
        with (case_dir / 'run.log').open('w') as log:
            result = subprocess.run([str(build / 'simv'), f'+CASE={case}'],
                                    cwd=case_dir, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=60)
        output = (case_dir / 'run.log').read_text()
        print(output)
        if result.returncode or f'PASS overflow_pool {case}' not in output:
            failed.append(case)
    if failed:
        raise SystemExit('Failed cases: ' + ', '.join(failed))


if __name__ == '__main__':
    main()
