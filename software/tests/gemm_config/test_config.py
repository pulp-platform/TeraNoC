#!/usr/bin/env python3
"""Host-check the actual C selector/CSR derivation against a partition model."""
import ctypes
import itertools
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]


def partition(m, p, groups, ks, div=1, forced=None):
  active, cpg = groups // div, 16
  rows = m // active
  tiles = rows // ks
  prefill = (m % active == 0 and tiles > 0 and rows % ks == 0
             and (cpg % tiles == 0 if tiles < cpg else rows % (cpg * ks) == 0))
  if prefill:
    prefill = p % (cpg // tiles if tiles < cpg else 1) == 0
  decode = not prefill if forced is None else bool(forced)
  if decode:
    nr = m // ks
    if (m % ks or not nr or nr > active * cpg or active * cpg % nr
        or (cpg % nr if nr < cpg else nr % cpg)):
      return None
    pb = active * cpg // nr
    if p % pb:
      return None
    allocations = [(c % nr * ks, c // nr * (p // pb), ks, p // pb)
                   for c in range(active * cpg)]
    sb = min(nr, cpg)
  else:
    if not prefill:
      return None
    sb = min(tiles, cpg)
    pa = cpg // sb
    allocations = [(g * rows + (c // pa * ks if tiles < cpg else c * (rows // cpg)),
                    c % pa * (p // pa), ks if tiles < cpg else rows // cpg, p // pa)
                   for g in range(active) for c in range(cpg)]
  # Check exact output coverage using intervals, without allocating an M*P bitmap.
  for row in range(m):
    spans = sorted((col, col + width) for r, col, height, width in allocations
                   if r <= row < r + height)
    assert spans and spans[0][0] == 0 and spans[-1][1] == p
    assert all(a[1] == b[0] for a, b in zip(spans, spans[1:]))
  return int(decode), cpg // sb, sb, allocations


def model_score(allocations, n, p, elem, ks, group, banks, burst, shift, bits, a, b):
  cohort = allocations[group * 16:group * 16 + 16]
  words = min(512 * min(8, 16 // ks) // 32, cohort[0][3] * elem // 4)
  total = 0
  for step in range(min(n, 16)):
    k = step * (n - 1) // (min(n, 16) - 1)
    addresses = set()
    for row, col, _, _ in cohort:
      if not burst:
        addresses.update((a + ((row + r) * n + k) * elem) // 4 for r in range(ks))
      full = words // 16 * 16
      addresses.update((b + (k * p + col) * elem) // 4 + w
                       for w in range(0 if burst else full,
                                      full if burst else words, 16 if burst else 1))
    def bank(w):
      if not bits:
        return (w >> shift) % banks
      return (((w >> shift) % (max(1, banks // 2))) * 2 + ((w // 16) % 2)) % banks
    total += len({bank(w) for w in addresses})
  return total


def run():
  cases = []
  for groups, elem in itertools.product((16, 64), (2, 4)):
    for m, n, p in ((1, 128, 4096), (4, 128, 4096), (16, 128, 4096),
                    (512, 128, 512), (2048, 32, 512), (16, 32, 4096)):
      cases.append((groups, elem, m, n, p, 1, None, None))
    cases += [(groups, elem, 512, 128, 512, 1, 2, None),
              (groups, elem, 16, 128, 4096, 4, None, None),
              (groups, elem, 16, 128, 4096, 1, 2, 1)]
  with tempfile.TemporaryDirectory(prefix='gemm-config-test-') as folder:
    out = Path(folder)
    for name in ('gemm_config.h', 'gemm_hash.h', 'mshr_cfg.h'):
      shutil.copy(ROOT / 'software/runtime' / name, out)
    (out / 'encoding.h').write_text('')
    (out / 'runtime.h').write_text('''
#define GROUP_BARRIER_WORD 0
#define N_FU 4
#define BANKING_FACTOR 4
#define NUM_CORES_PER_TILE 1
#define NUM_TILES_PER_GROUP 16
static inline unsigned mempool_get_group_id(void) { return 0; }
static inline unsigned mempool_get_tile_id(void) { return 0; }
static inline unsigned mempool_get_core_id(void) { return 0; }
''')
    for idx, (groups, elem, m, n, p, div, override, forced) in enumerate(cases):
      legal = [(ks, partition(m, p, groups, ks, div, forced)) for ks in (1, 2, 4, 8)]
      legal = [(ks, info) for ks, info in legal if info]
      def rank(item):
        ks, (_, sa, sb, alloc) = item
        words = min(512 * min(8, 16 // ks) // 32, alloc[0][3] * elem // 4)
        return abs(sa - sb), words < 16, -ks
      ks, (decode, sa, sb, alloc) = (next(x for x in legal if x[0] == override)
                                   if override else min(legal, key=rank))
      defines = dict(NUM_GROUPS=groups, NUM_CORES=groups * 16, GEMM_M=m,
                     GEMM_N=n, GEMM_P=p, GEMM_ELEM_BYTES=elem, VLEN=512,
                     ACTIVE_GROUP_DIV=div, MSHR_MERGE_REQS=8,
                     MSHR_CFG_HOLD_WINDOW_SINGLE=0, MSHR_CFG_HOLD_WINDOW_BURST=2047,
                     MSHR_CFG_HASH_MODE=3, MSHR_CFG_ENTRIES=64, MSHR_CFG_WAYS=4)
      if override:
        defines['KERNEL_SIZE'] = override
      if forced is not None:
        defines['MATMUL_DECODE_SPLIT'] = forced
      source = ''.join(f'#define {key} {value}\n' for key, value in defines.items())
      source += '''#include "gemm_config.h"
#include "mshr_cfg.h"
int check(void) {
  mshr_cfg_t c = {0};
  if (mshr_cfg_derive(GEMM_M, GEMM_N, GEMM_P, GEMM_ELEM_BYTES, KERNEL_SIZE, &c)) return 1;
  if (c.hold_subs_single != MSHR_D_HOLD_SUBS_SINGLE ||
      c.hold_subs_burst != MSHR_D_HOLD_SUBS_BURST ||
      c.bank_shift_single != MSHR_D_BANK_SHIFT_SINGLE ||
      c.bank_shift_burst != MSHR_D_BANK_SHIFT_BURST ||
      c.bank_burst_bits != MSHR_D_BANK_BURST_BITS) return 2;
  return 0;
}
unsigned config(unsigned i) {
  const unsigned x[] = {KERNEL_SIZE, MATMUL_DECODE_SPLIT,
    GEMM_SHARE_A(KERNEL_SIZE), GEMM_SHARE_B(KERNEL_SIZE),
    MSHR_D_BANK_SHIFT_SINGLE, MSHR_D_BANK_SHIFT_BURST, MSHR_D_BANK_BURST_BITS};
  return x[i];
}
unsigned score(unsigned a, unsigned b, unsigned g, unsigned banks,
               unsigned burst, unsigned shift, unsigned bits) {
  return gemm_hash_score(a, b, g, banks, burst, shift, bits);
}
int select_hash(unsigned a, unsigned b, unsigned g, unsigned banks, unsigned *x) {
  return gemm_hash_select(a, b, g, banks, x, x+1, x+2);
}
'''
      c = out / 'test.c'; c.write_text(source)
      so = out / f'test{idx}.so'
      subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                      '-shared', '-fPIC', str(c), '-o', str(so)], check=True)
      lib = ctypes.CDLL(str(so))
      assert lib.check() == 0, (idx, 'runtime/constant CSR mismatch', lib.check())
      assert [lib.config(i) for i in range(4)] == [ks, decode, sa, sb]
      for group, banks, a, b in ((0, 16, 0x10000000, 0x10020000),
                                  (groups // div - 1, 4, 0x100000c0, 0x10020140)):
        chosen = (ctypes.c_uint * 3)(*[lib.config(i) for i in range(4, 7)])
        assert lib.select_hash(a, b, group, banks, chosen) == 1
        for burst in (0, 1):
          scores = {}
          for shift in range(4, 11):
            for bits in range(2 if burst else 1):
              if shift < 4 + bits:
                continue
              expected = model_score(alloc, n, p, elem, ks, group, banks,
                                     burst, shift, bits, a, b)
              assert lib.score(a, b, group, banks, burst, shift, bits) == expected
              scores[shift, bits] = expected
          key = (chosen[1], chosen[2]) if burst else (chosen[0], 0)
          assert scores[key] == max(scores.values()), (idx, key, scores)
        assert lib.select_hash(a, b, group, 3, chosen) == 0
      print(f'{groups:2} groups fp{elem*8} {m}x{n}x{p} div={div}: KS={ks}, A/B={sa}/{sb}')
    # Explicit illegal KS and unsupported shapes must fail at build time.
    for flags in ('-DKERNEL_SIZE=3', '-DGEMM_M=3', '-DACTIVE_GROUP_DIV=3', '-DGEMM_N=3'):
      cmd = ['cc', '-E', '-x', 'c', '-I', str(out), '-DNUM_GROUPS=16',
             '-DNUM_CORES=256', '-DGEMM_P=4096', '-DGEMM_ELEM_BYTES=2', '-DVLEN=512']
      cmd += ['-DGEMM_M=16'] if 'GEMM_M' not in flags else []
      cmd += ['-DGEMM_N=128'] if 'GEMM_N' not in flags else []
      result = subprocess.run(cmd + [flags, '-'], input='#include "gemm_config.h"\n',
                              text=True, capture_output=True)
      assert result.returncode != 0, flags
  print(f'PASS: {len(cases)} shapes/configurations, coverage, CSR parity, exhaustive legal hash choices; 4 rejection checks')


if __name__ == '__main__':
  run()
