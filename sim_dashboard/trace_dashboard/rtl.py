"""Streaming legacy RTL transcript adapter. Never invent absent probes."""
import json
import re
from .model import RecordCollector


def fields(line):
  return dict(re.findall(r"(\w+)=\s*([^\s]+)", line))


def channels(value):
  return [int(x) for x in re.findall(r"(?:^|/)(\d+)\(", value)]


def parse_transcript(path, period=1000, bounds=None):
  records, info = RecordCollector(bounds), {"warnings": [], "source": str(path)}
  last = {}
  with open(path, errors="replace") as stream:
    for number, line in enumerate(stream, 1):
      if "[DASHBOARD_META]" in line:
        try:
          info.update(json.loads(line.split("[DASHBOARD_META]", 1)[1]))
        except (ValueError, TypeError) as error:
          raise ValueError(f"Invalid workload metadata at line {number}: {error}") from error
      if "[MSHRLIFE-BL]" in line:
        xy = re.search(r"gen_groups_x\[(\d+)\].*gen_groups_y\[(\d+)\]", line)
        if xy:
          info.setdefault("mshr_lifetime_classes", {})[",".join(xy.groups())] = {
            k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}
      if "[MSHRLIFE]" in line:
        xy = re.search(r"gen_groups_x\[(\d+)\].*gen_groups_y\[(\d+)\]", line)
        if xy:
          info.setdefault("mshr_lifetime", {})[",".join(xy.groups())] = {
            k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}
      tag = re.search(r"\[(FPUG|FPU|MSHRU|MSHRG|LP|BP|STALLG)\]\s+(.*)", line)
      took = re.search(r"The execution took (\d+) cycles", line)
      if took:
        info["cycles_per_pass"] = int(took[1])
      repeat = re.search(r"\[REPEAT\].*?r=(\d+)", line)
      if repeat:
        info["repetitions"] = int(repeat[1])
      if not tag:
        continue
      kind, body = tag.groups()
      f = dict(re.findall(r"(\w+)=([^,\s]+)", body)) if kind == "BP" else fields(body)
      if "cyc" not in f:
        continue
      end = int(f["cyc"])
      phase = "bench" if body.startswith("bench") else "pre" if body.startswith("pre") else "unknown"
      base = {"end": end, "start": max(0, end-period),
              "phase": phase, "source_line": number}
      try:
        if kind == "FPUG":
          vals = [int(x) for x in f["busy"].split(",")]
          denom = int(f["denom"])
          if end == 0:
            continue
          for g, busy in enumerate(vals):
            records.append(dict(base, kind="fpu", g=g, busy=busy,
                                capacity=denom, origin="legacy"))
          info["observed_groups"] = len(vals)
        elif kind == "FPU" and "util" in f and end:
          records.append(dict(base, kind="overall", util=float(f["util"].rstrip("%"))))
        elif kind == "MSHRU":
          win, g = int(f["win"]), int(f["g"])
          records.append(dict(base, kind="mshr", g=g, start=end-win,
                              occupied=float(f["valid_avg_x100"])*win/100,
                              capacity=int(f["entries"])*win,
                              peak=int(f["valid_max"]), full=int(f["full_cyc"]),
                              entries=int(f["entries"]), origin="legacy"))
        elif kind == "MSHRG":
          for g, (timeout, bypass) in enumerate(zip(f["timeout"].split(","), f["bypass"].split(","))):
            records.append(dict(base, kind="pressure", g=g,
                                timeout=int(timeout), bypass=int(bypass)))
        elif kind == "LP" and "mst_resp" in f and "nreq" in f and body.startswith("delta"):
          row = dict(base, kind="traffic", origin="legacy")
          for key in ("mst_req", "mst_resp", "slv_req", "slv_resp"):
            row[key] = channels(f[key])
          records.append(row)
        elif kind == "BP" and "kind" in f:
          f = dict(re.findall(r"(\w+)=([^,\s]+)", body))
          g = int(f["g"])
          key = (f["kind"], g, f.get("t"), f.get("s"))
          start = last.get(key, max(0, end-period))
          last[key] = end
          records.append(dict(base, kind="stage", start=start, g=g,
                              label=f.get("s", f["kind"]), t=int(f.get("t", -1)),
                              hsk=int(f["hsk"]), stall=int(f["stall"]),
                              idle=int(f["idle"]), active=int(f["active_cyc"])))
      except (ValueError, KeyError) as error:
        info["warnings"].append(f"Line {number}: incomplete {kind} record ({error})")
  if any(r["kind"] == "fpu" for r in records):
    info["warnings"].append("Legacy FPU windows use the supplied period; phase labels describe the window end. Boundary windows may mix phases.")
  if any(r["kind"] == "traffic" for r in records):
    info["warnings"].append("Legacy LP records are endpoint channel totals, not directional sub-NoC links. Their benchmark boundaries are approximate.")
  return records, info
