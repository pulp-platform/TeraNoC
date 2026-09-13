#!/usr/bin/env python3
"""Host-only parity between the C tuner and Python burst request model."""
import ctypes
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'sim_dashboard'))
from trace_dashboard.burst import requests
from trace_dashboard.analysis import hash_explore


def run():
  geometry = dict(profile='tile-contained-v1', tile_words=16, max_words=16,
                  lanes=4, rob_depth=32)
  assert requests(32, 32, **geometry) == [(8, 8)]
  assert requests(32, 36, **geometry) == [(8, 8), (16, 1)]
  assert requests(4, 64, **geometry) == [(w, 1) for w in range(1, 17)]
  assert requests(16, 64, **geometry) == [(4, 12), (16, 4)]
  assert requests(0, 6, **geometry) == [(0, 1), (1, 1)]
  assert requests(0, 516, **geometry) == [(w, 1) for w in range(129)]
  assert requests(32, 32, **dict(geometry, profile='aligned-v1')) == [(w, 1) for w in range(8, 16)]
  count = 0
  with tempfile.TemporaryDirectory(prefix='gemm-burst-host-') as folder:
    folder = Path(folder)
    source = folder/'test.c'
    source.write_text('''#include "gemm_burst.h"
unsigned stream(unsigned addr, unsigned bytes, unsigned *out) {
  if (!bytes) return 0;
  unsigned eligible=gemm_burst_eligible(addr,bytes);
  unsigned remaining=(addr%4+bytes+3)/4, word=addr/4, n=0;
  while(remaining) {
    unsigned len=gemm_burst_next(word,remaining,eligible);
    out[2*n]=word;out[2*n+1]=len;n++;word+=len;remaining-=len;
  }
  return n;
}
''')
    for tile in (1, 8, 16, 32):
      so = folder/f'burst{tile}.so'
      subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-shared','-fPIC',
                      '-I'+str(ROOT/'software/runtime'),f'-DGEMM_BURST_TILE_WORDS={tile}',
                      '-DGEMM_BURST_LANES=4','-DGEMM_BURST_ROB_DEPTH=32',str(source),'-o',str(so)],check=True)
      lib=ctypes.CDLL(str(so));buf=(ctypes.c_uint*300)()
      for address in range(tile*4):
        for size in range(1, 521):
          n=lib.stream(address,size,buf)
          actual=[(buf[2*i],buf[2*i+1]) for i in range(n)]
          expected=requests(address,size,**dict(geometry,tile_words=tile))
          assert actual==expected,(tile,address,size,actual,expected)
          count+=1
  meta=dict(mesh=[8,8],shape=[16,128,4096],precision='fp16',
            tiles_per_group=16,cores_per_tile=1,banks_per_tile=16,
            burst_model='tile-contained-v1',burst_geometry={k:v for k,v in geometry.items() if k!='profile'},
            hash=dict(kernel=4,split='decode',banks=16,entries=64,current=[6,4,0],max_steps=16))
  new=hash_explore(meta)
  old=hash_explore(dict(meta,burst_model='aligned-v1'))
  assert new['groups'][0]['request_counts']==dict(single=0,burst=64)
  assert old['groups'][0]['request_counts']==dict(single=256,burst=32)
  assert not hash_explore({k:v for k,v in meta.items() if k!='burst_model'})['available']
  print(f'PASS {count} C/Python request streams; short, split, fallback, capacity and historical-model checks')

if __name__=='__main__':
  run()
