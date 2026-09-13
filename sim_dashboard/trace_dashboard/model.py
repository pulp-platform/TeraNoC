"""Simulator-independent telemetry validation and conservative aggregation."""
import json
import hashlib
import math
from collections import defaultdict

KINDS = {"fpu", "mshr", "entry", "bank", "link", "work", "traffic", "stage", "pressure", "overall"}
ADDITIVE = {"busy", "capacity", "occupied", "occupied_single", "occupied_burst", "full", "hsk", "stall", "idle", "fmac", "cached", "held", "alloc", "release", "timeout", "bypass", "active"}


class RecordCollector(list):
  """Retain only overlapping windows while adapters stream the source files."""
  def __init__(self, bounds=None):
    super().__init__()
    self.bounds = bounds

  def append(self, row):
    if (self.bounds is None or
        row['end'] > self.bounds[0] and row['start'] < self.bounds[1]):
      super().append(row)

  def extend(self, rows):
    for row in rows:
      self.append(row)


def iter_telemetry(path, source_info=None):
  """Yield validated headers and rows without retaining the trace in memory."""
  digest = hashlib.sha256() if source_info is not None else None
  with open(path, 'rb') as stream:
    for line_number, line in enumerate(stream, 1):
      if digest is not None:
        digest.update(line)
      if not line.strip():
        continue
      try:
        row = json.loads(line)
        if row.get("kind") == "meta":
          if row.get("schema_version", 1) != 1:
            raise ValueError("unsupported schema_version")
        else:
          if row.get('kind') == 'link' and isinstance(row.get('network'), str):
            row['network'] = row['network'].strip()
          validate(row)
          row["source_line"] = line_number
          row["origin"] = "telemetry"
        yield row
      except (ValueError, TypeError, KeyError) as error:
        raise ValueError(f"{path}:{line_number}: {error}") from error

  if source_info is not None:
    source_info['sha256'] = digest.hexdigest()


def read_telemetry(path, bounds=None):
  records, meta = RecordCollector(bounds), {}
  for row in iter_telemetry(path):
    if row['kind'] == 'meta':
      meta.update({k: v for k, v in row.items() if k != 'kind'})
    else:
      records.append(row)
  return records, meta


def validate(row):
  if row["kind"] not in KINDS:
    raise ValueError(f"unknown record kind {row['kind']!r}")
  if not isinstance(row["start"], int) or not isinstance(row["end"], int) or not 0 <= row["start"] < row["end"]:
    raise ValueError("require integer cycles 0 <= start < end")
  for k, v in row.items():
    if isinstance(v, (int, float)) and (not math.isfinite(v) or (k in ADDITIVE and v < 0)):
      raise ValueError(f"invalid {k}: {v}")
  for numerator in ("busy", "occupied"):
    if numerator in row and (row.get("capacity", 0) <= 0 or row[numerator] > row["capacity"]):
      raise ValueError(f"{numerator} exceeds capacity or capacity absent")
  split = ("occupied_single", "occupied_burst")
  if any(k in row for k in split):
    if (not all(k in row for k in split) or
        any(not isinstance(row[k], int) or row[k] < 0 for k in split) or
        sum(row[k] for k in split) != row.get("occupied")):
      raise ValueError("single + burst occupancy must equal total occupancy")
  if row["kind"] in {"bank", "link"}:
    if row.get("hsk", 0)+row.get("stall", 0) > row["end"]-row["start"]:
      raise ValueError("handshake + stall exceeds single-port window")


def identity(row):
  return (row.get("kind"), row.get("g"), row.get("t"), row.get("bank"),
          row.get("entry"), row.get("network"), row.get("subnet"),
          row.get("direction"), row.get("label"))


def assemble(records, meta, width, warnings, frame_bounds=None):
  """Keep original records; aggregate only wholly contained windows, never split counts."""
  nx, ny = meta["mesh"]
  groups = nx*ny
  if nx < 1 or ny < 1:
    raise ValueError("mesh dimensions must be positive")
  preferred = {identity(r) for r in records if r.get("origin") == "telemetry"}
  rows = [r for r in records if r.get("origin") != "legacy" or identity(r) not in preferred]
  seen, ends = set(), {}
  cleaned = []
  for r in sorted(rows, key=lambda x: (x["start"], x["end"])):
    if r["end"] <= r["start"]:
      continue
    if "g" in r and not 0 <= r["g"] < groups:
      raise ValueError(f"Group {r['g']} outside {nx}x{ny} mesh")
    key = identity(r)
    stamp = (key, r["start"], r["end"])
    if stamp in seen:
      raise ValueError(f"Duplicate record {stamp}")
    seen.add(stamp)
    if key in ends and r["start"] < ends[key]:
      warnings.append(f"Overlapping {r['kind']} windows; inspect source lines (resets or concatenated runs).")
    ends[key] = r["end"]
    cleaned.append(r)
  if not cleaned:
    raise ValueError("No usable telemetry found")
  start, end = min(r["start"] for r in cleaned), max(r["end"] for r in cleaned)
  if frame_bounds is not None:
    # Long records keep their original span but occupy only their end-cycle
    # frame in this storage block. Do not allocate their full history again.
    start, end = frame_bounds
  if (end-start)/width > 20000:
    raise ValueError("More than 20,000 display windows; increase --window")
  bins = defaultdict(list)
  for r in cleaned:
    # A window crossing a display boundary remains inspectable as raw data,
    # and is shown by the browser only with its actual interval, not interpolated.
    bins[(r["end"]-1)//width].append(r)
  frames = []
  for index in range(start//width, (end-1)//width+1):
    frames.append({"start": index*width, "end": (index+1)*width, "rows": bins[index]})
  return frames, cleaned
