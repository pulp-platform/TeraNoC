"""CLI and single-file HTML packaging. Python standard library only."""
import argparse
import gc
import gzip
import hashlib
import json
import pickle
import tempfile
import time
from pathlib import Path

from .packaging import render
from .model import iter_telemetry, identity, benchmark_bounds
from .rtl import parse_transcript

HERE = Path(__file__).resolve().parents[1]


def positive(value):
  result = int(value)
  if result <= 0:
    raise argparse.ArgumentTypeError("must be positive")
  return result


def expected_fmac_total(meta):
  workload = meta.get('workload', {})
  if 'executed_fmac' in workload:
    value = workload['executed_fmac']
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
      raise ValueError('workload.executed_fmac must be a nonnegative integer')
    return value
  m, n, p = meta['shape']
  steps = meta.get('fmac_reduction_steps', n)
  if not isinstance(steps, int) or not 0 <= steps <= n:
    raise ValueError('fmac_reduction_steps must be an integer between 0 and N')
  return m*steps*p*meta.get('repetitions', 1)


def main():
  p = argparse.ArgumentParser(description=__doc__)
  p.add_argument("--transcript", type=Path)
  p.add_argument("--telemetry", type=Path, action="append", default=[])
  p.add_argument("--manifest", type=Path)
  p.add_argument("--mesh", help="NxM, e.g. 4x4 or 8x8; never inferred from group count")
  p.add_argument("--shape", help="GEMM MxNxP; N is reduction dimension")
  p.add_argument("--precision", choices=["fp16", "fp32"])
  p.add_argument("--cycle-range", help="Display records overlapping START:END cycles, or "
                 "'bench' for the captured benchmark phase; source windows are kept whole")
  p.add_argument("--cycles", type=positive, help="timed cycles per GEMM pass")
  p.add_argument("--repeat", type=positive)
  p.add_argument("--period", type=positive, default=1000, help="legacy FPU/LP period")
  p.add_argument("--window", type=positive, default=1000, help="display window cycles")
  p.add_argument("--peaks", type=Path, help="roofline/peaks/*.json matching the run")
  p.add_argument("--out", type=Path, default=HERE/"output/dashboard.html")
  p.add_argument("--json-out", type=Path, help="optional reusable parsed dataset")
  p.add_argument("--cutoff", type=positive, help="Keep records ending at or before this cycle; default: all recorded intervals")
  p.add_argument("--complete", action="store_true", help="Declare simulation finished; does not validate correctness")
  p.add_argument("--page-cycles", type=positive, help="Detail block width; default: 20000 rounded up to a multiple of --window")
  p.add_argument("--jobs", type=int, default=1,
                 help="worker processes for telemetry ingest; 1 (default) reads "
                      "sequentially. Output is identical either way")
  p.add_argument("--compression-level", type=int, choices=range(1, 10), default=3,
                 help="Lossless gzip level: 3 (default) favors speed; 9 favors file size")
  args = p.parse_args()
  if args.page_cycles is None:
    args.page_cycles = ((20000 + args.window - 1)//args.window)*args.window
  if args.page_cycles % args.window:
    p.error("--page-cycles must be a multiple of --window")
  if not args.transcript and not args.telemetry:
    p.error("supply --transcript and/or --telemetry")
  started = time.monotonic()
  args.out.parent.mkdir(parents=True, exist_ok=True)
  cache = tempfile.TemporaryDirectory(prefix='dashboard-input-', dir=args.out.parent)
  # Trace records are acyclic JSON trees. Reference counting releases them;
  # cyclic-GC scans otherwise revisit millions of long-lived rows repeatedly.
  gc_enabled = gc.isenabled()
  gc.disable()
  try:
    bounds = None
    if args.cycle_range == 'bench':
      # The timed region, read from the capture's own phase labels. A run that
      # streams operands in spends most of its cycles outside it.
      bounds = benchmark_bounds(args.telemetry)
      if bounds is None:
        raise ValueError('--cycle-range bench needs telemetry with a bench phase')
      print(f'Benchmark phase: cycles {bounds[0]}-{bounds[1]}', flush=True)
    elif args.cycle_range:
      bounds = [int(x) for x in args.cycle_range.split(':')]
      if len(bounds) != 2 or bounds[0] < 0 or bounds[1] <= bounds[0]:
        raise ValueError('cycle range must be nonnegative START:END with END > START')
    records, meta, warnings, sources = [], {}, [], []
    if args.transcript:
      records, info = parse_transcript(args.transcript, args.period, bounds)
      meta.update({k: v for k, v in info.items() if k not in ("warnings", "source")})
      warnings.extend(info["warnings"])
      sources.append(args.transcript)
    def selected(row):
      return ((args.cutoff is None or row['end'] <= args.cutoff) and
              (bounds is None or row['end'] > bounds[0] and row['start'] < bounds[1]))

    captured_fields = ("mesh", "tiles_per_group", "cores_per_tile", "n_fpu",
                       "banks_per_tile", "mshr_entries", "mshr_ways", "kernel_size",
                       "shape", "precision", "burst_model", "burst_geometry")
    preferred = set()
    source_details = {}
    source_stamps = {}

    def stamp(path):
      stat = path.stat()
      return stat.st_size, stat.st_mtime_ns
    caches = {}
    for path in args.telemetry:
      # Metadata and identity prepass uses bounded memory; the packaging pass
      # streams full rows. This supports headers anywhere and multiple inputs.
      source_stamps[path] = stamp(path)
      source_details[path] = {}
      cached = Path(cache.name)/f'{len(caches)}.pickle.gz'
      caches[path] = cached
      def accept_header(row):
        header = {k: v for k, v in row.items() if k != 'kind'}
        for field in captured_fields:
          if field in header and field in meta and header[field] != meta[field]:
            raise ValueError(f"Captured {field} differs between input sources")
        meta.update(header)

      with gzip.open(cached, 'wb', compresslevel=1) as stream:
        if args.jobs > 1:
          # json.loads and validate() dominate ingest and are pure per row, so the
          # decode is spread across processes. Reading, the digest and the order
          # batches reach the cache stay here, which keeps the bytes identical.
          from concurrent.futures import ProcessPoolExecutor
          from .parallel import chunks, parse_chunk
          digest = hashlib.sha256()
          with ProcessPoolExecutor(max_workers=args.jobs) as pool:
            tasks = ((str(path), first, blob, args.cutoff, bounds)
                     for first, blob in chunks(path, digest))
            for data, ids, headers, _ in pool.map(parse_chunk, tasks):
              for row in headers:
                accept_header(row)
              preferred.update(ids)
              stream.write(data)
          source_details[path]['sha256'] = digest.hexdigest()
          if str(path).endswith('.gz'):
            source_details[path]['sha256_scope'] = 'decoded JSONL bytes'
        else:
          batch = []
          for row in iter_telemetry(path, source_details[path]):
            if row['kind'] == 'meta':
              accept_header(row)
            elif selected(row):
              preferred.add(identity(row))
              batch.append(row)
              if len(batch) >= 1024:
                pickle.dump(batch, stream, protocol=pickle.HIGHEST_PROTOCOL)
                batch.clear()
          if batch:
            pickle.dump(batch, stream, protocol=pickle.HIGHEST_PROTOCOL)
      print(f'Validated and cached {path.name} ({time.monotonic()-started:.1f}s)', flush=True)
      if stamp(path) != source_stamps[path]:
        raise ValueError(f'{path} changed while reading; use a stable file snapshot')
      sources.append(path)
    if args.manifest:
      manifest = json.loads(args.manifest.read_text())
      for field in captured_fields:
        if field in manifest and field in meta and manifest[field] != meta[field]:
          raise ValueError(f"Manifest {field} differs from captured telemetry")
      meta.update(manifest)
      sources.append(args.manifest)
    if args.mesh:
      mesh = [int(x) for x in args.mesh.lower().split("x")]
      if 'mesh' in meta and meta['mesh'] != mesh:
        raise ValueError('--mesh differs from captured or manifest geometry')
      meta['mesh'] = mesh
    if args.shape:
      meta["shape"] = [int(x) for x in args.shape.lower().split("x")]
    for key, value in (("precision", args.precision), ("cycles_per_pass", args.cycles), ("repetitions", args.repeat)):
      if value is not None:
        meta[key] = value
    if len(meta.get("mesh", [])) != 2:
      raise ValueError("Supply --mesh or a manifest with mesh: [x,y]")
    if "shape" in meta and (len(meta["shape"]) != 3 or min(meta["shape"]) <= 0):
      raise ValueError("shape must contain three positive dimensions")
    for field in ("cycles_per_pass", "repetitions", "tiles_per_group", "cores_per_tile", "n_fpu"):
      if field in meta and (not isinstance(meta[field], int) or meta[field] <= 0):
        raise ValueError(f"{field} must be a positive integer")
    kernel_size = meta.get("kernel_size", meta.get("hash", {}).get("kernel"))
    if kernel_size is not None:
      if not isinstance(kernel_size, int) or isinstance(kernel_size, bool) or kernel_size <= 0:
        raise ValueError("kernel_size must be a positive integer (rows per kernel)")
      if meta.get("hash", {}).get("kernel", kernel_size) != kernel_size:
        raise ValueError("Captured kernel_size differs from hash-model kernel size")
      meta["kernel_size"] = kernel_size
    meta.setdefault("name", args.transcript.parent.name if args.transcript else args.telemetry[0].stem)
    meta.setdefault("backend", "rtl")
    meta.setdefault("correctness", "unknown")
    expected = meta.get("expected_fmac_per_group")
    if expected is not None:
      if len(expected) != meta["mesh"][0]*meta["mesh"][1] or any(not isinstance(v, int) or v < 0 for v in expected):
        raise ValueError("expected_fmac_per_group must contain one nonnegative integer per group")
      if meta.get("shape") and sum(expected) != expected_fmac_total(meta):
        raise ValueError("expected group FMAC totals do not match the declared kernel FMAC workload")
    if bounds is not None:
      meta['display_cycle_range'] = bounds
      warnings.append(f'Display limited to cycles {bounds[0]}–{bounds[1]}; overlapping source windows are retained whole. Complete raw traces remain in the source files.')
    if not args.peaks and meta.get('peaks'):
      args.peaks = Path(meta['peaks'])
    if args.complete or meta.get('run_complete'):
      args.complete = True
    if args.peaks:
      sources.append(args.peaks)

    def rows():
      for path in args.telemetry:
        if stamp(path) != source_stamps[path]:
          raise ValueError(f'{path} changed while reading; use a stable file snapshot')
        # Only read our private cache, never deserialize user-supplied pickle.
        with gzip.open(caches[path], 'rb') as stream:
          while True:
            try:
              batch = pickle.load(stream)
            except EOFError:
              break
            for row in batch:
              if len(args.telemetry) > 1:
                row['source_path'] = str(path.resolve())
              yield row
        if stamp(path) != source_stamps[path]:
          raise ValueError(f'{path} changed while reading; use a stable file snapshot')
      for row in records:
        if selected(row) and identity(row) not in preferred:
          row.setdefault('origin', 'legacy')
          yield row

    render(rows(), meta,
           [dict(path=str(path.resolve()), bytes=path.stat().st_size,
                 **source_details.get(path, {})) for path in sources],
           warnings, args)
  except (ValueError, KeyError, OSError) as error:
    p.error(str(error))
  finally:
    cache.cleanup()
    if gc_enabled:
      gc.enable()
