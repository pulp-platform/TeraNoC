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
import shutil
import subprocess
import sys
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
    desc = struct.unpack_from('<' + 'I' * (size // 4), data, off)
    assert desc[0] == 2 and size == 132
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
    # Refuse every selector dependency mismatch without changing even a ready ELF.
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        runtime = tmp/'wrong-runtime'
        runtime.mkdir()
        for name in module.HEADERS:
            shutil.copyfile(ROOT/'software/runtime'/name, runtime/name)
        copy = tmp/'workload.elf'
        copy.write_bytes(data)
        for name in module.HEADERS:
            header = runtime/name
            original = header.read_bytes()
            header.write_bytes(original + b'\n// Different snapshot\n')
            result = subprocess.run([sys.executable, str(ROOT/'software/scripts/precompute_gemm_hash.py'),
                                     str(copy), '--runtime', str(runtime)], capture_output=True, text=True)
            assert result.returncode != 0 and 'fingerprint mismatch' in result.stderr
            assert 'Expected build runtime:' in result.stderr
            assert copy.read_bytes() == data
            assert not copy.with_name(copy.name+'.hash.json').exists()
            header.write_bytes(original)
        header = runtime/'gemm_hash.h'
        header.write_bytes(header.read_bytes() + b'\n// Deliberate comparison\n')
        module.patch(copy, runtime, allow_header_mismatch=True)
        report = json.loads(copy.with_name(copy.name+'.hash.json').read_text())
        assert report['header_mismatch'] and report['mismatch_override']
        assert report['expected_fingerprint'] != report['used_fingerprint']
        # ABI mismatches fail independently of the header bytes.
        changed = bytearray(data)
        descriptor_offset, _ = elf.span('gemm_hash_descriptor')
        struct.pack_into('<I', changed, descriptor_offset + 24*4, 999)
        copy.write_bytes(changed)
        try:
            module.patch(copy, ROOT/'software/runtime')
        except ValueError as error:
            assert 'fingerprint mismatch' in str(error)
        else:
            raise AssertionError('Mismatched selector ABI accepted')
        assert copy.read_bytes() == changed
        # A v1 ELF has no fingerprint. Reject it unless explicitly overridden.
        legacy = bytearray(data)
        struct.pack_into('<I', legacy, descriptor_offset, 1)
        value = elf.address('gemm_hash_descriptor')
        for section in elf.sections:
            if section[1] == 2:
                for symbol in range(section[4], section[4]+section[5], section[9]):
                    if struct.unpack_from('<I', legacy, symbol+4)[0] == value:
                        struct.pack_into('<I', legacy, symbol+8, 24*4)
        copy.write_bytes(legacy)
        try:
            module.patch(copy, ROOT/'software/runtime')
        except ValueError as error:
            assert 'missing fingerprint' in str(error)
        else:
            raise AssertionError('Legacy descriptor accepted without override')
        assert copy.read_bytes() == legacy
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
