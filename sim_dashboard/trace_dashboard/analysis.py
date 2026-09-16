"""Roofline accounting and constrained, explicitly modeled hash exploration."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
from collections import Counter
from .burst import requests, PROFILES

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
  profile = meta.get('burst_model', h.get('burst_model'))
  if profile not in PROFILES:
    return {"available": False, "reason": "Hash analysis needs the run's burst_model: aligned-v1 or tile-contained-v1. Old unversioned assumptions are not applied automatically."}
  geometry = dict(meta.get('burst_geometry', h.get('burst_geometry', {})))
  required = ('tile_words', 'max_words', 'lanes', 'rob_depth')
  if any(key not in geometry for key in required):
    return {"available": False, "reason": "Hash analysis needs burst_geometry: tile_words, max_words, lanes, rob_depth (and optional enabled)."}
  geometry = {key: geometry[key] for key in (*required, 'enabled') if key in geometry}
  if meta.get('banks_per_tile', geometry['tile_words']) != geometry['tile_words']:
    raise ValueError('Burst tile_words differs from captured banks_per_tile')
  path = ROOT / "scripts/mshr_bank_hash_explore.py"
  spec = importlib.util.spec_from_file_location("hash_reference", path)
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  M, N, P = meta["shape"]
  if min(M, N, P) <= 0 or h.get('max_steps', 16) < 1:
    raise ValueError('Positive GEMM dimensions and sample count required')
  if h['kernel'] not in (1, 2, 4, 8) or h['split'] not in ('decode', 'prefill'):
    raise ValueError('Unsupported GEMM kernel size or work split')
  banks = h["banks"]
  if banks < 2 or banks & (banks-1) or h["entries"] % banks:
    raise ValueError("Hash model requires power-of-two banks >= 2 and divisible entries")
  # Reduced active sets (ACTIVE_GROUP_DIV) run the kernel on the first active_groups
  # groups only; partition and model those, while addresses keep the full-mesh map.
  mesh_groups = meta["mesh"][0]*meta["mesh"][1]
  active_groups = h.get("active_groups", mesh_groups)
  if not isinstance(active_groups, int) or not 1 <= active_groups <= mesh_groups or mesh_groups % active_groups:
    raise ValueError("active_groups must divide the mesh group count")
  args = SimpleNamespace(M=M, N=min(N, h.get("max_steps", 16)), P=P,
      ks=h["kernel"], elem_bytes=2 if meta["precision"] == "fp16" else 4,
      min_burst=2, max_burst=geometry["max_words"],
      entries=h["entries"], banks=banks,
      cores=active_groups*meta["tiles_per_group"]*meta["cores_per_tile"],
      groups=active_groups, vlen=meta.get("vlen", 512),
      elen=32, split=h["split"])
  g = module.build(args)
  # Repository kernels cap LMUL at m8.
  g.lmul = min(8, max(1, 16//g.ks))
  # B may be stored on padded column blocks (b_block elements per core, b_cols per row), with
  # short loads rounded to whole words inside the padding; unpadded builds omit these fields.
  b_block, b_cols = h.get("b_block", g.pspan), h.get("b_cols", P)
  load_bytes = h.get("b_load_bytes", min(g.vlen*g.lmul//8, g.pspan*g.elem_bytes))
  if b_block < g.pspan or b_cols < P:
    raise ValueError("Padded B layout is smaller than the work partition")
  g.load_words = load_bytes//4
  if g.load_words <= 0 or g.pspan <= 0:
    return {"available": False, "reason": "Work partition gives no full word per core; model does not support this shape."}
  # Use the original N stride, even when sampling reduction steps.
  g.N = N
  g.a_words = M*N*g.elem_bytes//4
  a_bases = list(h.get("a_base_per_group", [h.get("a_base", 0)]*mesh_groups))[:args.groups]
  if (len(a_bases) != args.groups or
      any(not isinstance(base, int) or base < 0 or base % 4 for base in a_bases)):
    raise ValueError("Hash A bases require one word-aligned byte address per group")
  sample_steps = [s*(N-1)//max(1, args.N-1) for s in range(args.N)]
  results = []
  any_burst = False
  for group in range(args.groups):
    # Generate only bounded reduction steps, preserving actual matrix strides.
    A, W, B_single = [], [], []
    a_core_tiles, b_core_tiles = Counter(), Counter()
    a_base = a_bases[group]
    for c in range(g.cpg):
      cid = group*g.cpg+c
      if g.split == "decode":
        pblk, rc = divmod(cid, g.nrow)
      else:
        rc, pblk = divmod(c, g.npb)
      p0 = pblk*b_block
      m0 = rc*g.ks + (group*(M//args.groups) if g.split == "prefill" else 0)
      if g.split == 'prefill' and (M//args.groups)//g.ks >= g.cpg:
        m0 = group*(M//args.groups) + c*((M//args.groups)//g.cpg)
      a_core_tiles[m0] += 1
      b_core_tiles[p0] += 1
      for step in sample_steps:
        address = h.get("w_base", g.a_words*4) + (step*b_cols+p0)*g.elem_bytes
        for word, count in requests(address, load_bytes, profile=profile, **geometry):
          target = W if count > 1 else B_single
          target.append((step, word))
      for b in range(m0, min(m0+g.ks, M)):
        for step in sample_steps:
          A.append((step, a_base//4+(b*N+step)*g.elem_bytes//4))
    # Subscribers share the same MSHR entry. Score distinct request starts,
    # preserving the common reduction-step sampling for both request classes.
    A, W, B_single = sorted(set(A)), sorted(set(W)), sorted(set(B_single))
    singles_addresses = sorted(set(A + B_single))
    b_request_counts = dict(single=len(B_single), burst=len(W))
    any_burst = any_burst or bool(W)
    def score(addresses, shift, bb):
      reached, fraction, hist = module.spread(addresses, shift, bb, g)
      fraction *= len({step for step, _ in addresses}) / args.N
      return dict(shift=shift, burst_bits=bb, concurrent_banks=fraction*banks,
                  fraction=fraction, histogram=[hist[i] for i in range(banks)])
    lo, hi = max(4, h.get("shift_min", 4)), min(10, h.get("shift_max", 10), 30-g.bankidw)
    singles = [score(singles_addresses, s, 0) for s in range(lo, hi+1)]
    weights = [score(W, s, bb) for bb in range(min(1, h.get("burst_bits_max", 1), g.bankidw-1)+1)
               for s in range(max(lo, g.align+bb), hi+1)]
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
    if current and (len(current) != 3 or current[2] not in (0, 1) or
                    not 4 <= current[0] <= 10 or
                    not max(4, g.align+current[2]) <= current[1] <= 10):
      raise ValueError('Current hash selectors are outside the supported RTL CSR range')
    locality = None
    if meta.get("banks_per_tile"):
      group_words = meta["banks_per_tile"] * meta["tiles_per_group"]
      def local_fraction(addresses):
        return (sum((word // group_words) % mesh_groups == group
                    for _, word in addresses) / len(addresses)) if addresses else None
      locality = dict(a=local_fraction(A), b=local_fraction(W + B_single))
    results.append(dict(g=group, sharing=shared, locality=locality, request_counts=b_request_counts, singles=singles[:5], weights=weights[:5],
        current_a=score(singles_addresses, current[0], 0) if current else None,
        current_w=score(W, current[1], current[2]) if current else None))
  return dict(available=True, groups=results, active_groups=args.groups, mesh_groups=mesh_groups,
              banks=banks, entries=h["entries"],
              burst_model=profile, burst_eligible=any_burst, sampled_steps=args.N, total_steps=N,
              source=str(path), note=h.get("input_status", "")+" Single-class scores include A and scalar B requests; burst scores include burst B requests. First microtile, unmasked unit-stride loads, vstart=0; modeled simultaneous k-steps; best bank spread among supplied legal settings, not a predicted speedup. Addresses/partition are assumptions unless captured from the run.")
