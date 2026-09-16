#!/usr/bin/env python3
"""Stamp the selector inputs when compiling a target object, not when patching it."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

SELECTOR_ABI = 1
HEADERS = ('gemm_hash.h', 'gemm_config.h', 'gemm_burst.h')


def fingerprint(runtime):
    digest = hashlib.sha256(b'TeraNoC GEMM selector\0' + struct.pack('<I', SELECTOR_ABI))
    for name in HEADERS:
        data = (runtime/name).read_bytes()
        digest.update(name.encode() + b'\0' + struct.pack('<Q', len(data)) + data)
    return digest.digest()


def compile_object(runtime, command):
    before = fingerprint(runtime)
    words = ','.join(f'0x{x:08x}u' for x in struct.unpack('<8I', before))
    defines = [f'-DGEMM_HASH_BUILD_FINGERPRINT={words}',
               f'-DGEMM_HASH_BUILD_ABI={SELECTOR_ABI}',
               '-DGEMM_HASH_BUILD_RUNTIME=' + json.dumps(str(runtime.resolve()))]
    result = subprocess.run(command + defines)
    if fingerprint(runtime) != before:
        if '-o' in command:
            Path(command[command.index('-o') + 1]).unlink(missing_ok=True)
        raise SystemExit('GEMM selector headers changed during compilation; rebuild the object')
    return result.returncode


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('compiler command required after --')
    raise SystemExit(compile_object(args.runtime, command))
