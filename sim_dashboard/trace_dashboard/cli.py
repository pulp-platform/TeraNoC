"""CLI and single-file HTML packaging. Python standard library only."""
import argparse
import base64
import gzip
import json
import math
from pathlib import Path

from .analysis import hash_explore, roofline
from .diagnostics import benchmark_diagnostics
from .model import assemble, read_telemetry
from .rtl import parse_transcript

HERE = Path(__file__).resolve().parents[1]


def positive(value):
  result = int(value)
  if result <= 0:
    raise argparse.ArgumentTypeError("must be positive")
  return result


def expected_fmac_total(meta):
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
  p.add_argument("--cycle-range", help="Display records overlapping START:END cycles; source windows are kept whole")
  p.add_argument("--cycles", type=positive, help="timed cycles per GEMM pass")
  p.add_argument("--repeat", type=positive)
  p.add_argument("--period", type=positive, default=1000, help="legacy FPU/LP period")
  p.add_argument("--window", type=positive, default=1000, help="display window cycles")
  p.add_argument("--peaks", type=Path, help="roofline/peaks/*.json matching the run")
  p.add_argument("--out", type=Path, default=HERE/"output/dashboard.html")
  p.add_argument("--json-out", type=Path, help="optional reusable parsed dataset")
  args = p.parse_args()
  if not args.transcript and not args.telemetry:
    p.error("supply --transcript and/or --telemetry")
  try:
    bounds = None
    if args.cycle_range:
      bounds = [int(x) for x in args.cycle_range.split(':')]
      if len(bounds) != 2 or bounds[0] < 0 or bounds[1] <= bounds[0]:
        raise ValueError('cycle range must be nonnegative START:END with END > START')
    records, meta, warnings, sources = [], {}, [], []
    if args.transcript:
      records, info = parse_transcript(args.transcript, args.period, bounds)
      meta.update({k: v for k, v in info.items() if k not in ("warnings", "source")})
      warnings.extend(info["warnings"])
      sources.append(args.transcript)
    for path in args.telemetry:
      rows, header = read_telemetry(path, bounds)
      records.extend(rows)
      meta.update(header)
      sources.append(path)
    if args.manifest:
      manifest = json.loads(args.manifest.read_text())
      for field in ("mesh", "tiles_per_group", "cores_per_tile", "n_fpu", "banks_per_tile", "mshr_entries", "mshr_ways", "kernel_size"):
        if field in manifest and field in meta and manifest[field] != meta[field]:
          raise ValueError(f"Manifest {field} differs from captured telemetry")
      meta.update(manifest)
      sources.append(args.manifest)
    if args.mesh:
      meta["mesh"] = [int(x) for x in args.mesh.lower().split("x")]
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
    frames, rows = assemble(records, meta, args.window, warnings)
    for kind, counter in (("fpu", "busy"), ("mshr", "occupied"), ("bank", "hsk"), ("link", "hsk")):
      active = [r for r in rows if r["kind"] == kind and r.get("phase") == "bench"]
      if active and not any(r.get(counter, 0) for r in active):
        warnings.append(f"All benchmark {kind} {counter} counters are zero; check probe enablement and workload activity.")
    roof = roofline(rows, meta, args.peaks, warnings)
    if args.peaks:
      sources.append(args.peaks)
    if any(r["end"]-r["start"] > args.window or r["start"] < (r["end"]-1)//args.window*args.window for r in rows):
      warnings.append("Some source windows cross display boundaries. They are assigned by end cycle; tooltips retain their actual span. Counts are never interpolated.")
    hash_result = hash_explore(meta)
    diagnostics = benchmark_diagnostics(rows, meta, hash_result)
    data = dict(diagnostics=diagnostics, schema_version=1, meta=meta, frames=frames, roofline=roof,
                hash=hash_result, warnings=sorted(set(warnings)), window=args.window,
                sources=[dict(path=str(path.resolve()), bytes=path.stat().st_size) for path in sources])
    payload = json.dumps(data, separators=(",", ":"), allow_nan=False)
    # Escape HTML parser terminators and JS-unfriendly Unicode. Never interpolate log text as HTML.
    payload = payload.replace("<", "\\u003c").replace("&", "\\u0026").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    html = (HERE/"assets/index.html").read_text()
    html = html.replace("/* DASHBOARD_CSS */", (HERE/"assets/dashboard.css").read_text())
    html = html.replace("/* DASHBOARD_JS */", (HERE/"assets/dashboard.js").read_text())
    packed = base64.b64encode(gzip.compress(payload.encode(), mtime=0)).decode()
    html = html.replace("__DASHBOARD_DATA__", json.dumps({"encoding": "gzip-base64", "data": packed}))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(html)
    if args.json_out:
      args.json_out.parent.mkdir(parents=True, exist_ok=True)
      args.json_out.write_text(json.dumps(data, allow_nan=False))
    print(f"Wrote {args.out.resolve()} ({len(rows):,} records, {len(frames):,} windows)")
    print("Available:", ", ".join(sorted({r['kind'] for r in rows})))
    for warning in data["warnings"]:
      print("Note:", warning)
  except (ValueError, KeyError, OSError) as error:
    p.error(str(error))
