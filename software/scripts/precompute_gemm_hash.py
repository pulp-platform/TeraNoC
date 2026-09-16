#!/usr/bin/env python3
"""Patch GEMM hash selectors using final ELF addresses and the runtime C model.

Standard-library Python plus a native C compiler; no cross execution or relink.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import struct
import subprocess
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'runtime'))
from gemm_hash_fingerprint import HEADERS, SELECTOR_ABI, fingerprint

DEFINES = ('GEMM_M GEMM_N GEMM_P GEMM_ELEM_BYTES NUM_CORES NUM_GROUPS '
           'ACTIVE_GROUP_DIV KERNEL_SIZE MATMUL_DECODE_SPLIT VLEN '
           'GEMM_BURST_ENABLED GEMM_BURST_TILE_WORDS GEMM_BURST_LANES '
           'GEMM_BURST_ROB_DEPTH GEMM_BURST_MAX_WORDS MSHR_HASH_SAMPLE_STEPS').split()


class Elf32:
    def __init__(self, data):
        self.data = data
        if data[:7] != b'\x7fELF\x01\x01\x01':
            raise ValueError('Expected little-endian ELF32')
        hdr = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
        self.sections = [struct.unpack_from('<10I', data, hdr[6] + i * hdr[11])
                         for i in range(hdr[12])]
        self.symbols = {}
        for sec in self.sections:
            if sec[1] != 2:
                continue
            strings = self.sections[sec[6]]
            names = data[strings[4]:strings[4] + strings[5]]
            for off in range(sec[4], sec[4] + sec[5], sec[9]):
                name, value, size, info, other, index = struct.unpack_from('<IIIBBH', data, off)
                end = names.find(b'\0', name)
                self.symbols[names[name:end].decode()] = (value, size, index)

    def address(self, name):
        return self.symbols[name][0]

    def span(self, name):
        value, size, index = self.symbols[name]
        sec = self.sections[index]
        if sec[1] == 8 or not sec[3] <= value <= value + size <= sec[3] + sec[5]:
            raise ValueError(f'{name}: expected file-backed symbol')
        return sec[4] + value - sec[3], size


def selections(desc, a, b, runtime):
    if (desc[0], len(desc)) not in ((1, 24), (2, 33)):
        raise ValueError('Unsupported GEMM hash descriptor')
    macros = dict(zip(DEFINES, desc[1:17]))
    groups = macros['NUM_GROUPS']
    banks, single, burst, bits, replicas, groups_per_replica, stride = desc[17:24]
    source = '\n'.join(f'#define {key} {value}u' for key, value in macros.items())
    source += '\n#include "gemm_hash.h"\n#include <stdio.h>\nint main(void) {\n'
    source += f'''  for (unsigned g = 0; g < {groups}u; ++g) {{
    unsigned s = {single}u, b = {burst}u, bits = {bits}u;
    unsigned a = {a}u + (g / {groups_per_replica}u) * {stride if replicas > 1 else 0}u;
    gemm_hash_select(a, {b}u, g, {banks}u, &s, &b, &bits);
    printf("%u %u %u\\n", s, b, bits);
  }}
  return 0;
}}
'''
    with tempfile.TemporaryDirectory(prefix='gemm-hash-') as tmp:
        tmp = Path(tmp)
        (tmp/'select.c').write_text(source)
        subprocess.run(shlex.split(os.environ.get('HOST_CC', 'cc')) +
                       ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-I', str(runtime), str(tmp/'select.c'), '-o', str(tmp/'select')], check=True)
        values = list(map(int, subprocess.check_output([str(tmp/'select')], text=True).split()))
    if len(values) != 3 * groups:
        raise ValueError('Incomplete hash table')
    return values


def patch(path, runtime, allow_header_mismatch=False):
    data = bytearray(path.read_bytes())
    elf = Elf32(data)
    if 'gemm_hash_descriptor' not in elf.symbols:
        print('GEMM hash: runtime search or fixed configuration selected')
        return
    offset, size = elf.span('gemm_hash_descriptor')
    desc = struct.unpack_from('<' + 'I' * (size // 4), data, offset)
    if (desc[0], len(desc)) not in ((1, 24), (2, 33)):
        raise ValueError('Unsupported GEMM hash descriptor')
    expected_runtime = '(not recorded; rebuild this legacy ELF)'
    if 'gemm_hash_build_runtime' in elf.symbols:
        build_offset, build_size = elf.span('gemm_hash_build_runtime')
        expected_runtime = bytes(data[build_offset:build_offset+build_size]).rstrip(b'\0').decode()
    expected = struct.pack('<8I', *desc[25:33]).hex() if desc[0] == 2 else None
    a = elf.address('a_mesh' if desc[21] > 1 else 'a')
    # Compile only the private header snapshot whose bytes we verified.
    with tempfile.TemporaryDirectory(prefix='gemm-hash-headers-') as tmp:
        snapshot = Path(tmp)
        for name in HEADERS:
            shutil.copyfile(runtime/name, snapshot/name)
        actual = fingerprint(snapshot).hex()
        mismatch = expected != actual or desc[0] != 2 or desc[24] != SELECTOR_ABI
        if mismatch and not allow_header_mismatch:
            raise ValueError(
                f'GEMM selector fingerprint mismatch: ELF expects {expected or "missing fingerprint"}; '
                f'--runtime {runtime.resolve()} provides {actual}. '
                f'Expected build runtime: {expected_runtime}. '
                'Pass --runtime with that matching snapshot or rebuild the ELF. '
                'For deliberate cross-version experiments only, use --allow-header-mismatch.')
        if mismatch:
            print('OVERRIDE: using a different GEMM selector; recorded in .hash.json', file=sys.stderr)
        values = selections(desc, a, elf.address('b'), snapshot)
    offset, size = elf.span('gemm_hash_table')
    encoded = struct.pack('<' + 'I' * (1 + len(values)), 0x47484d31, *values)
    if len(encoded) != size:
        raise ValueError('Hash table size mismatch')
    data[offset:offset + size] = encoded
    # Atomic replacement changes only reserved table bytes, never symbol addresses.
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        tmp = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.chmod(tmp, path.stat().st_mode)
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)
    report = dict(schema_version=2, elf=str(path.resolve()),
                  selector_abi=SELECTOR_ABI, expected_runtime=expected_runtime,
                  expected_fingerprint=expected, used_fingerprint=actual,
                  header_mismatch=mismatch, mismatch_override=allow_header_mismatch,
                  config=dict(zip(DEFINES, desc[1:17])),
                  banks=desc[17], a_base=a, b_base=elf.address('b'),
                  replicas=desc[21], groups_per_replica=desc[22],
                  replica_stride_bytes=desc[23],
                  selectors=[dict(group=g, single=values[3*g],
                                  burst=values[3*g+1], bits=values[3*g+2])
                             for g in range(desc[6])])
    path.with_name(path.name + '.hash.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'GEMM hash: embedded {len(values)//3} groups using final operand addresses')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('elf', type=Path)
    parser.add_argument('--runtime', type=Path, default=Path(__file__).resolve().parents[1]/'runtime')
    parser.add_argument('--allow-header-mismatch', action='store_true',
                        help='Deliberately use different selector headers; records override in hash report')
    args = parser.parse_args()
    try:
        patch(args.elf, args.runtime, args.allow_header_mismatch)
    except (ValueError, OSError, KeyError, struct.error) as error:
        parser.exit(2, f'error: {error}\n')
