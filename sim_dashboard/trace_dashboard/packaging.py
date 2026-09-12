#!/usr/bin/env python3
"""Package every telemetry record into an offline HTML with lossless time pages."""
import base64
from collections import Counter, defaultdict
import gzip
import html
import json
from pathlib import Path
import tempfile

from .analysis import hash_explore, roofline
from .diagnostics import benchmark_diagnostics
from .model import assemble, validate
from .timeline import overview_points

HERE = Path(__file__).resolve().parents[1]


def packed(value):
  raw = json.dumps(value, separators=(',', ':'), allow_nan=False).encode()
  return json.dumps(dict(encoding='gzip-base64',
                        data=base64.b64encode(gzip.compress(raw, mtime=0)).decode()))


def full_template(root):
  warning = root["warnings"][0]
  template = (HERE/'assets/index.html').read_text()
  template = template.replace('/* DASHBOARD_CSS */', (HERE/'assets/dashboard.css').read_text())
  controls = (HERE/'assets/full_timeline.html').read_text()
  template = template.replace('<body>', '<body><p style="padding:12px;background:#fff3cd">'+html.escape(warning)+'</p>')
  template = template.replace('</header>', '</header>'+controls)
  js = (HERE/'assets/dashboard.js').read_text()
  begin = js.index('  const packed =')
  end = js.index('  let selected =', begin)
  js = js[:begin]+'''  async function unpack(id) {
  const p = JSON.parse(document.getElementById(id).textContent);
  const bytes = Uint8Array.from(atob(p.data), c => c.charCodeAt(0));
  return JSON.parse(await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"))).text());
}
const root = await unpack("dataset");
let pageNumber = Math.max(0, root.pages.findIndex(p => p.end > (root.meta.benchmark?.[0] || 0)));
const initial = {frames: [], work_before: Array(root.meta.mesh[0]*root.meta.mesh[1]).fill(0)};
const D = {...root, ...initial}, M = D.meta;
M.work_before = initial.work_before;
const $ = id => document.getElementById(id);
let F = D.frames;
'''+js[end:]
  js = js.replace('  const rowIndex = F.map((frame) => {', '  function indexFrames() { return F.map((frame) => {')
  js = js.replace('  const rows = (i, kind, g = null) => {', '  }\n  let rowIndex = indexFrames();\n  const rows = (i, kind, g = null) => {')
  js = js.replace('done: rs.length ? sum(rs, "fmac") : null', 'done: rs.length || (M.work_before?.[g] > 0) ? (M.work_before?.[g] || 0)+sum(rs, "fmac") : null')
  marker='  const firstBenchmark = F.findIndex'
  extra = (HERE/'assets/full_timeline.js').read_text()
  js = js.replace(marker, extra+marker)
  js = js.replace('window.dashboardTest = { select,', 'window.dashboardTest = { loadPage, loadRange, get detailRange() { return detailRange; }, get pageNumber() { return pageNumber; }, select,')
  js = js.replace('const lo = F[visible[0]].start, hi = F[visible.at(-1)].end;',
                  'const lo = D.detail_range?.[0] ?? F[visible[0]].start, hi = D.detail_range?.[1] ?? F[visible.at(-1)].end;')
  template = template.replace('/* DASHBOARD_JS */', js)
  return template


def render(records, meta, sources, warnings, args):
  """Stream original rows into bounded detail blocks with a shared overview."""
  args.out.parent.mkdir(parents=True, exist_ok=True)
  with tempfile.TemporaryDirectory(prefix='dashboard-pages-', dir=args.out.parent) as temp:
    temp = Path(temp)
    counts, telemetry_counts, supplemental = Counter(), Counter(), Counter()
    summary, long_intervals = [], []
    entry_totals = defaultdict(Counter)
    benchmark_activity = defaultdict(Counter)
    crossing = False
    bench, extent = [None, None], [None, None]
    handles = {}
    # Bound open descriptors even for long simulations or out-of-order groups.
    def spool(page, row):
      if page not in handles:
        if len(handles) >= 32:
          handles.pop(next(iter(handles))).close()
        handles[page] = (temp/f'{page}.jsonl').open('a')
      handles[page].write(json.dumps(row, separators=(',', ':'))+'\n')
    page_ids = set()
    try:
      for row in records:
        validate(row)
        page = (row['end']-1)//args.page_cycles
        page_ids.add(page)
        spool(page, row)
        counts[row['kind']] += 1
        target = telemetry_counts if row.get('origin') == 'telemetry' else supplemental
        target[row['kind']] += 1
        extent[0] = min(extent[0] if extent[0] is not None else row['start'], row['start'])
        extent[1] = max(extent[1] or 0, row['end'])
        if row['start'] < (row['end']-1)//args.window*args.window:
          crossing = True
        if row['end']-row['start'] > args.window:
          long_intervals.append(row)
        if row['kind'] not in ('entry', 'bank', 'link'):
          summary.append(row)
        if row.get('phase') == 'bench':
          benchmark_activity[row['kind']]['records'] += 1
          for field in ('busy', 'occupied', 'hsk'):
            benchmark_activity[row['kind']][field] += row.get(field, 0)
          bench[0] = min(bench[0] if bench[0] is not None else row['start'], row['start'])
          bench[1] = max(bench[1] or 0, row['end'])
          if row['kind'] == 'entry':
            for field in ('occupied', 'held', 'cached'):
              entry_totals[row['g']][field] += row.get(field, 0)
    finally:
      for handle in handles.values():
        handle.close()
    if not counts:
      raise ValueError('No usable records found in the selected capture')
    cutoff = args.cutoff or extent[1]
    meta['full_record_counts'] = dict(counts)
    meta['telemetry_record_counts'] = dict(telemetry_counts)
    meta['transcript_supplement_counts'] = dict(supplemental)
    meta['page_cycles'] = args.page_cycles
    meta['run_complete'] = args.complete
    meta.setdefault('snapshot', {})
    meta['snapshot']['detail_windows'] = [extent]
    meta['snapshot']['coverage_note'] = 'Every selected source record is retained.'
    meta['snapshot'].pop('counts', None)
    meta.pop('snapshot_note', None)
    if all(value is not None for value in bench):
      meta.setdefault('benchmark', bench)
    meta['name'] = meta['name'].split(' — ')[0] + (
      ' — FULL COVERAGE' if args.complete else ' — FULL COVERAGE / COMPLETION UNCONFIRMED')
    warning = (f'Captured records through cycle {extent[1]}. '
               'The overview summarizes counters; detail retains original intervals. ' +
               (f"Simulation complete. Correctness: {meta['correctness']}." if args.complete else
                'Simulation completion is unconfirmed; use --complete only for a finished run.'))
    warnings.insert(0, warning)
    if crossing:
      warnings.append('Some source windows cross display boundaries. Original counts and intervals are retained whole.')
    for kind, counter in (('fpu', 'busy'), ('mshr', 'occupied'), ('bank', 'hsk'), ('link', 'hsk')):
      if benchmark_activity[kind]['records'] and not benchmark_activity[kind][counter]:
        warnings.append(f'All benchmark {kind} {counter} counters are zero; check probe enablement and workload activity.')
    hash_result = hash_explore(meta)
    roof = roofline(summary, meta, args.peaks, warnings)
    diag_rows = summary + [dict(kind='entry', g=g, start=bench[0], end=bench[1],
                               phase='bench', **totals)
                           for g, totals in entry_totals.items()]
    diagnostics = benchmark_diagnostics(diag_rows, meta, hash_result)
    diagnostics.setdefault('notes', []).append('Diagnosis spans the captured benchmark, independent of the detail selection.')
    pages = sorted(page_ids)
    root = dict(schema_version=1, meta=meta, hash=hash_result, roofline=roof,
                diagnostics=diagnostics, warnings=warnings, window=args.window,
                overview=overview_points(summary), long_intervals=long_intervals,
                sources=sources,
                pages=[dict(index=n, start=i*args.page_cycles,
                            end=min((i+1)*args.page_cycles, cutoff))
                       for n, i in enumerate(pages)])
    counts_out = Counter()
    work_before = [0]*(meta['mesh'][0]*meta['mesh'][1])
    exported_rows = [] if args.json_out else None
    # Validate and compress detail before serializing the root, so warnings
    # discovered during assembly are included in the exported dashboard.
    for n, i in enumerate(pages):
      with (temp/f'{i}.jsonl').open() as page_file:
        rows = [json.loads(line) for line in page_file]
      frames, clean = assemble(rows, meta, args.window, warnings,
                               frame_bounds=(i*args.page_cycles, (i+1)*args.page_cycles))
      counts_out.update(r['kind'] for r in clean)
      if exported_rows is not None:
        exported_rows.extend(clean)
      (temp/f'{n}.packed').write_text(packed(dict(frames=frames, work_before=work_before.copy())))
      for row in clean:
        if row['kind'] == 'work' and (row.get('phase') == 'bench' or row.get('workload_phase') == 'bench'):
          work_before[row['g']] += row['fmac']
    if counts_out != counts:
      raise ValueError(f'Record preservation failed: {counts} != {counts_out}')
    warnings[:] = list(dict.fromkeys(warnings))
    # Missing storage intervals remain gaps, never fabricated measurements.
    template = full_template(root)
    before, after = template.split('__DASHBOARD_DATA__')
    close = '</script>'
    assert after.startswith(close)
    tmpout = args.out.with_suffix('.html.tmp')
    with tmpout.open('w') as stream:
      stream.write(before); stream.write(packed(root)); stream.write(close)
      for n in range(len(pages)):
        stream.write(f'<script type="application/json" id="page-data-{n}">')
        with (temp/f'{n}.packed').open() as blob:
          while True:
            chunk = blob.read(1024*1024)
            if not chunk:
              break
            stream.write(chunk)
        stream.write(close)
      stream.write(after[len(close):])
    tmpout.replace(args.out)
    if exported_rows is not None:
      frames, _ = assemble(exported_rows, meta, args.window, [])
      args.json_out.parent.mkdir(parents=True, exist_ok=True)
      args.json_out.write_text(json.dumps(dict(root, frames=frames), allow_nan=False))
    report = dict(sources=sources, cutoff=cutoff, input_counts=dict(counts),
                  output_counts=dict(counts_out), all_records_preserved=True,
                  pages=len(pages), fmac_by_group=work_before, benchmark=bench)
    args.out.with_suffix('.coverage.json').write_text(json.dumps(report, indent=2)+'\n')
    args.out.with_suffix('.diagnosis.json').write_text(json.dumps(diagnostics, indent=2)+'\n')
    print(f'Wrote {args.out.resolve()} ({sum(counts.values()):,} records, {len(pages):,} detail blocks)')
    for warning in warnings:
      print('Note:', warning)
