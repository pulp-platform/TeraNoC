"""Lossless encoding and eviction of private temporary page buffers."""
import base64
import gzip
import json
import re
import subprocess
import sys
from pathlib import Path

from trace_dashboard.packaging import packed


def test_compression_levels_preserve_payload():
  value = {'rows': [{'g': g, 'occupied': g, 'phase': 'bench'} for g in range(64)]}
  for level in (1, 3, 9):
    blob = json.loads(packed(value, level))
    assert json.loads(gzip.decompress(base64.b64decode(blob['data']))) == value


def test_out_of_order_pages_and_late_metadata(tmp_path):
  # Evict and reopen page handles, including batches below the flush threshold.
  rows = [dict(kind='work', g=g, start=i*1000, end=(i+1)*1000,
               phase='bench', fmac=i+g+1)
          for g in range(2) for i in range(35)]
  source = tmp_path/'input.jsonl'
  source.write_text(''.join(json.dumps(r)+'\n' for r in rows + [
      dict(kind='meta', mesh=[1, 2])]))
  out = tmp_path/'result.html'
  cli = Path(__file__).resolve().parents[1]/'generate.py'
  subprocess.run([sys.executable, str(cli), '--telemetry', str(source),
                  '--page-cycles', '1000', '--out', str(out)], check=True)
  scripts = dict(re.findall(r'<script type="application/json" id="([^"]+)">(.*?)</script>', out.read_text(), re.S))
  recovered = []
  for name, raw in scripts.items():
    if name.startswith('page-data-'):
      blob = json.loads(raw)
      page = json.loads(gzip.decompress(base64.b64decode(blob['data'])))
      recovered.extend({k:v for k,v in r.items() if k not in ('source_line','origin')}
                       for f in page['frames'] for r in f['rows'])
  key = lambda r: (r['g'], r['start'])
  assert sorted(recovered, key=key) == sorted(rows, key=key)
  assert not list(tmp_path.glob('dashboard-input-*'))
  assert not list(tmp_path.glob('dashboard-pages-*'))


def test_gzip_telemetry_input(tmp_path):
  source = tmp_path/'input.jsonl.gz'
  with gzip.open(source, 'wt') as stream:
    stream.write(json.dumps(dict(kind='meta', mesh=[1, 1]))+'\n')
    stream.write(json.dumps(dict(kind='fpu', g=0, start=0, end=1000,
                                 phase='bench', busy=2, capacity=1000))+'\n')
  out = tmp_path/'result.html'
  cli = Path(__file__).resolve().parents[1]/'generate.py'
  subprocess.run([sys.executable, str(cli), '--telemetry', str(source),
                  '--out', str(out)], check=True)
  scripts = dict(re.findall(
      r'<script type="application/json" id="([^"]+)">(.*?)</script>',
      out.read_text(), re.S))
  root = json.loads(gzip.decompress(base64.b64decode(
      json.loads(scripts['dataset'])['data'])))
  page = json.loads(gzip.decompress(base64.b64decode(
      json.loads(scripts['page-data-0'])['data'])))
  assert root['sources'][0]['sha256_scope'] == 'decoded JSONL bytes'
  assert page['frames'][0]['rows'][0]['busy'] == 2


def test_gc_state_restored_on_invalid_input(tmp_path, monkeypatch):
  import gc
  import pytest
  from trace_dashboard.cli import main
  source = tmp_path/'bad.jsonl'
  source.write_text('{"kind":"fpu","start":0,"end":0}\n')
  monkeypatch.setattr(sys, 'argv', ['generate.py', '--telemetry', str(source),
                                  '--out', str(tmp_path/'bad.html')])
  before = gc.isenabled()
  with pytest.raises(SystemExit):
    main()
  assert gc.isenabled() == before
  assert not list(tmp_path.glob('dashboard-input-*'))
