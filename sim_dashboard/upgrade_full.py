#!/usr/bin/env python3
"""Add full-run overview to an existing full dashboard without repacking detail.

Compressed detail blocks are copied byte-for-byte. The overview is derived from
those same records; no transcript reread or telemetry downsampling is required.
"""
from collections import Counter, defaultdict
import argparse
import base64
import gzip
import hashlib
import json
from pathlib import Path
from trace_dashboard.packaging import full_template, packed
from trace_dashboard.timeline import overview_points
from trace_dashboard.analysis import hash_explore
from trace_dashboard.diagnostics import benchmark_diagnostics


def blocks(path):
  marker = b'<script type="application/json" id="'
  close = b'</script>'
  buffer = b''
  with path.open('rb') as stream:
    while True:
      pos = buffer.find(marker)
      if pos < 0:
        chunk = stream.read(1024*1024)
        if not chunk:
          return
        buffer = buffer[-len(marker):] + chunk
        continue
      buffer = buffer[pos:]
      while close not in buffer:
        chunk = stream.read(1024*1024)
        if not chunk:
          raise ValueError('Truncated embedded dataset')
        buffer += chunk
      stop = buffer.index(close) + len(close)
      block, buffer = buffer[:stop], buffer[stop:]
      header_end = block.index(b'>')
      name = block[len(marker):].split(b'"',1)[0].decode()
      yield name, block[header_end+1:-len(close)], block


def unpack(payload):
  return json.loads(gzip.decompress(base64.b64decode(json.loads(payload)['data'])))


def upgrade(source, out):
  records = []
  entry_totals = defaultdict(Counter)
  long_intervals = []
  hashes = {}
  root = None
  width = 1000
  for name, payload, raw in blocks(source):
    if name == 'dataset':
      root = unpack(payload)
      width = root.get("window", 1000)
    elif name.startswith('page-data-'):
      page = unpack(payload)
      for frame in page['frames']:
        long_intervals.extend(r for r in frame['rows'] if r['end'] - r['start'] > width)
        records.extend(r for r in frame['rows'] if r['kind'] not in ('entry','bank','link'))
        for r in frame['rows']:
          if r['kind'] == 'entry' and r.get('phase') == 'bench':
            for field in ('occupied', 'held', 'cached'):
              entry_totals[r['g']][field] += r.get(field, 0)
      hashes[name] = hashlib.sha256(raw).hexdigest()
      print('Read',name,flush=True)
  if root is None or len(hashes) != len(root['pages']):
    raise ValueError('Missing root or detail blocks')
  root['hash'] = hash_explore(root['meta'])
  bench = root['meta'].get('benchmark')
  diagnostic_rows = records + ([dict(kind='entry', g=g, phase='bench',
    start=bench[0], end=bench[1], **totals) for g, totals in entry_totals.items()] if bench else [])
  root['diagnostics'] = benchmark_diagnostics(diagnostic_rows, root['meta'], root['hash'])
  root['overview'] = overview_points(records)
  root['long_intervals'] = long_intervals
  root['warnings'][0] = ('Full capture through cycle '+str(root['pages'][-1]['end'])+
    '. The overview shows the complete captured run; detail retains original measurement windows. '+
    ('Simulation complete.' if root['meta'].get('run_complete') else 'Simulation incomplete; final correctness is not established.'))
  del records
  # Hash results are recomputed above; old manual hash-model correction banners
  # describe superseded results and remain only in the untouched source HTML.
  template = full_template(root)
  before, after = template.split('__DASHBOARD_DATA__')
  temporary = out.with_suffix('.html.tmp')
  with temporary.open('wb') as stream:
    stream.write(before.encode());stream.write(packed(root).encode());stream.write(b'</script>')
    for name,payload,raw in blocks(source):
      if name.startswith('page-data-'):
        assert hashes[name] == hashlib.sha256(raw).hexdigest()
        stream.write(raw)
    stream.write(after[len('</script>'):].encode())
  # Read back the serialized file, rather than assuming writes preserved the blocks.
  actual = {name:hashlib.sha256(raw).hexdigest() for name,_,raw in blocks(temporary)
            if name.startswith('page-data-')}
  assert actual == hashes
  temporary.replace(out)
  report = dict(source=str(source.resolve()),output=str(out.resolve()),
                unchanged_detail_blocks=len(hashes),detail_sha256=hashes,
                overview_points=len(root['overview']),detail_preserved=True)
  out.with_suffix('.overview_audit.json').write_text(json.dumps(report,indent=2)+'\n')
  print(out,flush=True)


if __name__ == '__main__':
  p=argparse.ArgumentParser(description=__doc__)
  p.add_argument('source',type=Path);p.add_argument('--out',type=Path,required=True)
  a=p.parse_args();a.out.parent.mkdir(parents=True,exist_ok=True)
  upgrade(a.source,a.out)
