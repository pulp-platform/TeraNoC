"""Small, phase-aware overview derived from additive trace counters."""
from collections import defaultdict


def overview_points(records, max_points=1200):
  """Aggregate counts before dividing; never average window utilization rates.

  Phase/start/end groups retain their measured extent. Missing counter families
  remain absent rather than becoming measured zero. Detail records are untouched.
  """
  buckets = defaultdict(dict)
  for r in records:
    if r['kind'] not in ('fpu', 'mshr', 'traffic', 'overall'):
      continue
    key = (r.get('phase', 'unknown'), r['start'], r['end'])
    b = buckets[key]
    if r['kind'] == 'overall':
      # Printed percentages lack lane counters; keep their duration-weighted
      # series separate from measured busy/capacity counters.
      b['overall_util_duration'] = r['util'] * (r['end']-r['start'])
      b['overall_duration'] = r['end']-r['start']
      continue
    if r['kind'] == 'traffic':
      b['traffic_duration'] = r['end'] - r['start']
    fields = {'fpu': ('busy', 'capacity'), 'mshr': ('occupied', 'capacity'),
              'traffic': ('mst_req', 'slv_req', 'mst_resp', 'slv_resp')}[r['kind']]
    for field in fields:
      if field not in r:
        continue
      value = r[field]
      b[r['kind'] + '_' + field] = b.get(r['kind'] + '_' + field, 0) + (
        sum(value) if isinstance(value, list) else value)
  points = [dict(phase=k[0], start=k[1], end=k[2], **v) for k, v in buckets.items()]
  points.sort(key=lambda x: (x['start'], x['end'], x['phase']))
  # Keep original phase boundaries; only combine consecutive observed windows.
  stride = max(1, (len(points) + max_points - 1) // max_points)
  out = []
  for phase in sorted({p['phase'] for p in points}):
    active = [p for p in points if p['phase'] == phase]
    chunks = []
    chunk = []
    for point in active:
      if chunk and (len(chunk) >= stride or point['start'] > chunk[-1]['end']):
        chunks.append(chunk)
        chunk = []
      chunk.append(point)
    if chunk:
      chunks.append(chunk)
    for chunk in chunks:
      b = dict(phase=phase, start=min(p['start'] for p in chunk),
               end=max(p['end'] for p in chunk), windows=len(chunk))
      b['duration'] = sum(p['end'] - p['start'] for p in chunk)
      for p in chunk:
        for key, value in p.items():
          if key not in ('phase', 'start', 'end'):
            b[key] = b.get(key, 0) + value
      out.append(b)
  return sorted(out, key=lambda p: (p['start'], p['end'], p['phase']))
