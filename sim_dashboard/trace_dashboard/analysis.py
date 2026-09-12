"""Roofline accounting and constrained, explicitly modeled hash exploration."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
from collections import Counter

ROOT = Path(__file__).resolve().parents[2]


def roofline(rows, meta, peaks_path, warnings):
  if not peaks_path:
    return {"available": False, "reason": "Supply --peaks with the peak JSON for this run's actual configuration."}
  with open(peaks_path) as stream:
    source = json.load(stream)
  d = source["derived"]
  top = d["topology"]
  if [top["mesh_x"], top["mesh_y"]] != meta["mesh"]:
    raise ValueError("Peak table mesh differs from run mesh")
  for field, key in (("tiles_per_group", "tiles_per_group"), ("cores_per_tile", "cores_per_tile"), ("n_fpu", "n_fpu")):
    if field in meta and meta[field] != top[key]:
      raise ValueError(f"Peak table {field} differs from run metadata")
  precision = meta.get("precision")
  if precision not in ("fp16", "fp32"):
    return {"available": False, "reason": "Specify fp16 or fp32 precision."}
  peak = d["compute"][precision+"_flop_per_cyc"]
  roofs = [{"name": "L1 ports", "boundary": "l1", "bandwidth": d["l1_local"]["chip_port_bytes_per_cyc"]},
           {"name": "Remote receive", "boundary": "demand", "bandwidth": d["l1_remote"]["chip_recv_bytes_per_cyc"]},
           {"name": "Mesh: uniform-traffic model", "boundary": "mesh", "bandwidth": d["l1_remote"]["uniform_random_cap_bytes_per_cyc"]},
           {"name": "L2", "boundary": "l2", "bandwidth": d["l2"]["chip_bytes_per_cyc"]}]
  out = dict(available=True, peak=peak, roofs=roofs, points=[], source=str(peaks_path),
             config=source.get("config", {}))
  shape, cycles = meta.get("shape"), meta.get("cycles_per_pass")
  bench = meta.get("benchmark")
  work = [r for r in rows if r["kind"] == "work" and r.get("phase") == "bench"]
  traffic = [r for r in rows if r["kind"] == "traffic"]
  if bench:
    traffic = [r for r in traffic if r["start"] >= bench[0] and r["end"] <= bench[1]]
    work = [r for r in work if r["start"] >= bench[0] and r["end"] <= bench[1]]
  else:
    ends = [r["end"] for r in rows if r["kind"] == "fpu" and r.get("phase") == "bench"]
    if ends:
      traffic = [r for r in traffic if min(ends) <= r["end"] <= max(ends)]
  if not shape or not cycles:
    out["reason"] = "Ceilings available; whole-run point needs GEMM shape and timed cycles."
    return out
  repeats = meta.get("repetitions", 1)
  flops = 2*shape[0]*shape[1]*shape[2]*repeats
  actual_cycles = bench[1]-bench[0] if bench else cycles*repeats
  out.update(flops=flops, cycles=cycles*repeats, performance=flops/(cycles*repeats),
             ideal_cycles=flops/peak, benchmark_cycles=actual_cycles,
             benchmark_compute_utilization=flops/peak/actual_cycles,
             utilization_definition="Conventional GEMM work (2*M*N*P*repetitions) / peak FLOPs per cycle / benchmark cycles; distinct from busy-lane utilization.")
  for boundary, key in (("demand", "mst_resp"), ("mesh", "slv_resp")):
    count = sum(sum(r.get(key, [])) for r in traffic)
    if count:
      out["points"].append(dict(boundary=boundary, ai=flops/(4*count), bytes=4*count))
  out["estimated_ai"] = not bool(bench and traffic and all(r.get("origin") == "telemetry" for r in traffic)
                                  and min(r["start"] for r in traffic) == bench[0]
                                  and max(r["end"] for r in traffic) == bench[1]
                                  and sum(r["end"]-r["start"] for r in traffic) == bench[1]-bench[0])
  if out["estimated_ai"] and out["points"]:
    warnings.append("Whole-run roofline intensity is estimated: legacy/cropped byte windows may not cover the exact timed workload. Performance uses reported GEMM cycles.")
  if len(out["points"]) == 2:
    out["merge_factor"] = out["points"][1]["ai"] / out["points"][0]["ai"]
  return out


def hash_explore(meta):
  h = meta.get("hash")
  if not h or not meta.get("shape"):
    return {"available": False, "reason": "Add hash geometry, kernel size, split and current settings to the manifest (see examples)."}
  path = ROOT / "scripts/mshr_bank_hash_explore.py"
  spec = importlib.util.spec_from_file_location("hash_reference", path)
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  M, N, P = meta["shape"]
  banks = h["banks"]
  if banks < 2 or banks & (banks-1) or h["entries"] % banks:
    raise ValueError("Hash model requires power-of-two banks >= 2 and divisible entries")
  args = SimpleNamespace(M=M, N=min(N, h.get("max_steps", 1024)), P=P,
      ks=h["kernel"], elem_bytes=2 if meta["precision"] == "fp16" else 4,
      min_burst=h.get("min_burst", 16), max_burst=h.get("max_burst", 16),
      entries=h["entries"], banks=banks,
      cores=meta["mesh"][0]*meta["mesh"][1]*meta["tiles_per_group"]*meta["cores_per_tile"],
      groups=meta["mesh"][0]*meta["mesh"][1], vlen=meta.get("vlen", 512),
      elen=32, split=h["split"])
  g = module.build(args)
  # Repository kernels cap LMUL at m8 (the explorer's ks=1 default is m16).
  g.lmul = min(8, max(1, 16//g.ks))
  g.load_words = min(g.vlen*g.lmul//32, g.pspan*g.elem_bytes//4)
  if g.load_words <= 0 or g.pspan <= 0:
    return {"available": False, "reason": "Work partition gives no full word per core; model does not support this shape."}
  # Use the original N stride, even when sampling reduction steps.
  g.N = N
  g.a_words = M*N*g.elem_bytes//4
  a_bases = h.get("a_base_per_group", [h.get("a_base", 0)]*args.groups)
  if (len(a_bases) != args.groups or
      any(not isinstance(base, int) or base < 0 or base % 4 for base in a_bases)):
    raise ValueError("Hash A bases require one word-aligned byte address per group")
  results = []
  for group in range(args.groups):
    # Generate only bounded reduction steps, preserving actual matrix strides.
    A, W = [], []
    a_core_tiles, b_core_tiles = Counter(), Counter()
    a_base = a_bases[group]
    for c in range(g.cpg):
      cid = group*g.cpg+c
      if g.split == "decode":
        pblk, rc = divmod(cid, g.nrow)
      else:
        rc, pblk = divmod(c, g.npb)
      p0 = pblk*g.pspan
      m0 = rc*g.ks + (group*(M//args.groups) if g.split == "prefill" else 0)
      a_core_tiles[m0] += 1
      b_core_tiles[p0] += 1
      for step in range(args.N):
        base = h.get("w_base", g.a_words*4)//4 + (step*P+p0)*g.elem_bytes//4
        burst = g.load_words >= g.min_burst
        offsets = range(0, g.load_words, g.max_burst if burst else 1)
        for offset in offsets:
          W.append((step, base+offset))
      for b in range(m0, min(m0+g.ks, M)):
        for step in range(0, args.N, 8):
          A.append((step, a_base//4+(b*N+step)*g.elem_bytes//4))
    def score(addresses, shift, bb):
      reached, fraction, hist = module.spread(addresses, shift, bb, g)
      return dict(shift=shift, burst_bits=bb, concurrent_banks=fraction*banks,
                  fraction=fraction, histogram=[hist[i] for i in range(banks)])
    lo, hi = h.get("shift_min", 4), min(h.get("shift_max", 10), 30-g.bankidw)
    singles = [score(A, s, 0) for s in range(lo, hi+1)]
    is_burst = g.load_words >= g.min_burst
    weights = [score(W, s, bb) for bb in range(min(h.get("burst_bits_max", 1), g.bankidw-1)+1)
               for s in range(max(lo, g.align+bb) if is_burst else lo, hi+1)
               if is_burst or bb == 0]
    rank = lambda r: (-r["fraction"], max(r["histogram"], default=0), r["shift"], r["burst_bits"])
    singles.sort(key=rank)
    weights.sort(key=rank)
    if not singles or not weights:
      raise ValueError("No legal hash candidates for the supplied constraints")
    def sharing(counts):
      return dict(mean=sum(counts.values())/len(counts),
                  minimum=min(counts.values()), maximum=max(counts.values()),
                  distinct_tiles=len(counts))
    shared = dict(cores=g.cpg, kernel_rows=g.ks, columns_per_core=g.pspan,
                  a=sharing(a_core_tiles), b=sharing(b_core_tiles))
    current = h.get("current_by_group", {}).get(str(group), h.get("current"))
    locality = None
    if meta.get("banks_per_tile"):
      group_words = meta["banks_per_tile"] * meta["tiles_per_group"]
      def local_fraction(addresses):
        return (sum((word // group_words) % args.groups == group
                    for _, word in addresses) / len(addresses)) if addresses else None
      locality = dict(a=local_fraction(A), b=local_fraction(W))
    results.append(dict(g=group, sharing=shared, locality=locality, singles=singles[:5], weights=weights[:5],
        current_a=score(A, current[0], 0) if current else None,
        current_w=score(W, current[1] if is_burst else current[0], current[2] if is_burst else 0) if current else None))
  return dict(available=True, groups=results, banks=banks, entries=h["entries"],
              burst_eligible=is_burst, sampled_steps=args.N, total_steps=N,
              source=str(path), note=h.get("input_status", "")+" Modeled simultaneous k-steps; best bank spread among supplied legal settings, not a predicted speedup. Addresses/partition are assumptions unless captured from the run.")
