#!/usr/bin/env python3
"""Check post-link tables, unchanged ELF layout, and recorded runtime selections.

Pass isolated build directories containing workload.elf. Optional campaign
comparison uses the existing calibration transcripts and their frozen ELF files.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import struct
import tempfile

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('precompute', ROOT/'software/scripts/precompute_gemm_hash.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def check(path, campaign=None):
    data = path.read_bytes()
    elf = module.Elf32(data)
    off, size = elf.span('gemm_hash_descriptor')
    desc = struct.unpack_from('<24I', data, off)
    assert size == 96
    off, size = elf.span('gemm_hash_table')
    table = struct.unpack_from('<' + 'I' * (size // 4), data, off)
    assert table[0] == 0x47484d31
    base = elf.address('a_mesh' if desc[21] > 1 else 'a')
    expected = module.selections(desc, base, elf.address('b'), ROOT/'software/runtime')
    assert list(table[1:]) == expected
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp)/'workload.elf'
        unpatched = bytearray(data)
        unpatched[off:off+size] = bytes(size)
        copy.write_bytes(unpatched)
        module.patch(copy, ROOT/'software/runtime')
        assert copy.read_bytes() == data, 'Only reserved table bytes may change'
        module.patch(copy, ROOT/'software/runtime')
        assert copy.read_bytes() == data, 'Patching must be idempotent'
    if campaign:
        mesh = 4 if desc[6] == 16 else 8
        precision = desc[4] * 8
        arm = 'B' if precision == 16 else 'C'
        run = campaign/'runs'/f'CAL2-{arm}_{mesh}x{mesh}_fp{precision}'
        manifest = json.loads((run/'elf_manifest.json').read_text())
        assert list(desc[1:4]) == manifest['shape']
        original = module.Elf32(Path(manifest['elf']).read_bytes())
        base = original.address('a_mesh' if desc[21] > 1 else 'a')
        # Recorded runs must be compared with their frozen selector version.
        selected = module.selections(desc, base, original.address('b'),
                                     campaign/'source_snapshot/software/runtime')
        reports = {int(g): list(map(int, (s, b, bits))) for g, s, b, bits in
                   re.findall(r'\[DASHBOARD_HASH\] g=(\d+) single=(\d+) burst=(\d+) bits=(\d+)',
                              (run/'results/transcript').read_text(errors='replace'))}
        assert len(reports) == desc[6]
        for group, config in reports.items():
            assert selected[3*group:3*group+3] == config, (path, group, config)
    print('PASS', path, 'all group selectors and byte-exact patch boundaries')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('elf', type=Path, nargs='+')
    parser.add_argument('--campaign', type=Path)
    args = parser.parse_args()
    for path in args.elf:
        check(path, args.campaign)
