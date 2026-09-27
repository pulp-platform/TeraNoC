#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
"""Where did the FPU time go? Probe digest for a qwen-gate-up (or any GEMM) RTL run.

Reads the TB probe lines of one run and prints, over a cycle window:

  1. utilisation   [FPU] lane occupancy: mean / median / p10, share of dip periods
  2. loss budget   100% - mean, split into (the "good" level is the p75 period)
                     * steady shortfall  -- 100% minus the good level,
                     * barrier sleep     -- periods with a group asleep (FPU, insn and every
                                            stall counter 0: parked in a wfi barrier, e.g. the
                                            per-K-tile DMA barrier),
                     * sync / refill     -- dips with nobody asleep (the per-column-chunk group
                                            rendezvous, C store/reload, W pipeline refill),
                   and the dip period, so a dip can be matched to a loop level
  3. per group     [FPUG] util, [STALLG] stall shares, [INSNG] IPC -- stragglers show here
  4. MSHR          [MSHRU] mean valid entries per slice (s0-3 rows = bursts in decode,
                   s4-7 columns = singles), [BYP] bypass forwards per kcyc per group
  5. NoC           [BP] stage handshakes per group per cycle and stall/handshake
  6. banks         [BP] bank_req stall/handshake per group, and per period how many of a
                   group's tiles carry its bank traffic (concentration; averaged over periods,
                   since the hot tiles move from one column chunk to the next)
  7. DMA           dma.log transfer durations by size (the K-tile refills), and -- when the
                   image has tb_dma_profiling.svh -- [DMAP]/[L2BW]: per backend, the share of
                   its busy cycles moving data (R handshake), stalled by the L1 write side
                   (R valid, not ready), or waiting on L2 / the NoC (no R, reads outstanding),
                   the mean outstanding read beats, and the L2 channels' beats per cycle

Handles both simulators: QuestaSim prefixes every transcript line with "# ", VCS does not,
and the per-group CSV probes carry a leading space on field 0. A live (still running)
transcript is fine -- a half-written last line is skipped.

Usage:
  scripts/qwen_perf_analyze.py hardware/build_3                 # GUI build dir
  scripts/qwen_perf_analyze.py hardware/run6_arm/transcript     # a transcript file
  scripts/qwen_perf_analyze.py RUN_A RUN_B --from 40000 --to 400000
A directory argument reads <dir>/transcript and, if present, <dir>/dma.log. Several runs
are analysed one after the other; pass the same --from/--to to compare them fairly.
"""

import argparse
import os
import re
import statistics
import sys

NG = 16  # overwritten from the first per-group probe line

KV = re.compile(r'(\w+)=\s*([\d.,\s]*[\d.])')


def kv(s):
  out = {}
  for k, v in KV.findall(s):
    out[k] = v
  return out


def csv_ints(v):
  return [int(x.strip()) for x in v.split(',')]


def parse(path, c_from, c_to):
  global NG
  fpu = {}            # cyc -> util
  grp = {}            # (tag, field) -> {cyc: [per group]}
  mshru = {}          # slice index -> [valid_avg_x100]
  mshru_idx = {}
  byp = {}            # cyc -> summed fwd over groups/slices
  stage = {}          # name -> [hsk, stall, set(cyc)]
  bank = {}           # (g, t) -> [hsk, stall]
  bank_p = {}         # (cyc, g) -> {t: hsk}  -- per period, for concentration
  qwen = []
  dmap = {}           # field -> [per-group sums] over periods with DMA activity
  l2bw = []           # per period: list of per-channel beats
  with open(path, 'rb') as f:
    for raw in f:
      ln = raw[2:] if raw.startswith(b'# ') else raw
      if not ln.startswith(b'['):
        continue
      try:
        s = ln.decode()
        if s.startswith('[UART] [QWEN]') or s.startswith('[UART] [MSHR] share'):
          qwen.append(s.strip())
          continue
        if s.startswith('[DMAP]') or s.startswith('[L2BW]'):
          d = kv(s)
          c = int(d['cyc'])
          if not c_from <= c <= c_to:
            continue
          if s.startswith('[L2BW]'):
            l2bw.append(csv_ints(d['beats']))
          else:
            for k in ('busy', 'r', 'rstall', 'rwait', 'wstall', 'out'):
              vals = csv_ints(d[k])
              acc = dmap.setdefault(k, [0] * len(vals))
              for i, v in enumerate(vals):
                acc[i] += v
            dmap['_n'] = dmap.get('_n', 0) + 1
          continue
        if s.startswith('[FPU] bench'):
          d = kv(s)
          c = int(d['cyc'])
          if c_from <= c <= c_to:
            fpu[c] = float(d['util'])
        elif s.startswith(('[FPUG] bench', '[STALLG] bench', '[INSNG] bench', '[MEMOG] bench')):
          tag = s[1:s.index(']')]
          d = kv(s)
          c = int(d['cyc'])
          if not c_from <= c <= c_to:
            continue
          for k, v in d.items():
            if ',' in v:
              vals = csv_ints(v)
              NG = len(vals)
              grp.setdefault((tag, k), {})[c] = vals
        elif s.startswith('[MSHRU]'):
          d = kv(s)
          c, g = int(d['cyc']), int(d['g'])
          if not c_from <= c <= c_to:
            continue
          i = mshru_idx.get((c, g), 0)
          mshru_idx[(c, g)] = i + 1
          mshru.setdefault(i, []).append(int(d['valid_avg_x100']))
        elif s.startswith('[BYP] cyc'):
          d = kv(s)
          c = int(d['cyc'])
          byp[c] = byp.get(c, 0) + int(d['fwd'])
        elif s.startswith('[BP] delta,kind=stage') or s.startswith('[BP] delta,kind=bank_req'):
          d = dict(x.split('=', 1) for x in s.strip().split(',')[1:] if '=' in x)
          c = int(d['cyc'])
          if not c_from <= c <= c_to:
            continue
          if 'kind=stage' in s:
            a = stage.setdefault(d['s'], [0, 0, set()])
            a[0] += int(d['hsk'])
            a[1] += int(d['stall'])
            a[2].add(c)
          else:
            g, t = int(d['g']), int(d['t'])
            a = bank.setdefault((g, t), [0, 0])
            a[0] += int(d['hsk'])
            a[1] += int(d['stall'])
            bank_p.setdefault((c, g), {})[t] = int(d['hsk'])
      except (KeyError, ValueError, UnicodeDecodeError, IndexError):
        pass  # half-written live line, or a probe variant this digest does not know
  return dict(fpu=fpu, grp=grp, mshru=mshru, byp=byp, stage=stage, bank=bank, bank_p=bank_p,
              qwen=qwen, dmap=dmap, l2bw=l2bw)


def parse_dma(path):
  """Pair each '[mempool_dma] Launch request of N bytes' with the next 'Duration' line."""
  sizes = {}
  pending = []
  with open(path, 'rb') as f:
    for raw in f:
      if raw.startswith(b'[mempool_dma] Launch request of'):
        pending.append(int(raw.split()[-2]))
      elif raw.startswith(b'[mempool_dma] Duration:'):
        cyc = int(raw.split()[2])
        n = pending.pop(0) if pending else -1
        sizes.setdefault(n, []).append(cyc)
  return sizes


def pct(xs, q):
  xs = sorted(xs)
  return xs[min(len(xs) - 1, int(q * len(xs)))]


def row(label, vals, fmt):
  return f"  {label:<11}" + ' '.join(fmt(v) for v in vals)


def dma_probe(r):
  """[DMAP] / [L2BW] digest: the DMA's busy cycles by what the R channel was doing."""
  d = r['dmap']
  if not d:
    return
  n = d['_n']
  busy = sum(d['busy'])
  if not busy:
    return
  moved = sum(d['r'])
  print(f"  DMA probe ({n} active periods, all groups): of the backends' busy cycles "
        f"{100 * moved / busy:.0f}% moving data (R), {100 * sum(d['rstall']) / busy:.0f}% R held "
        f"by the L1 write side, {100 * sum(d['rwait']) / busy:.0f}% waiting on L2/NoC; "
        f"W stalled {100 * sum(d['wstall']) / busy:.0f}%; mean outstanding "
        f"{sum(d['out']) / busy:.1f} beats")
  print(f"  DMA beats/busy cycle per group: " +
        ' '.join(f"{r_ / max(b, 1):.2f}" for r_, b in zip(d['r'], d['busy'])))
  if r['l2bw']:
    ch = len(r['l2bw'][0])
    per = [sum(p[k] for p in r['l2bw']) / (len(r['l2bw']) * 1000) for k in range(ch)]
    print(f"  L2 beats/cycle per channel (active periods): " + ' '.join(f"{v:.2f}" for v in per) +
          f"  | total {64 * sum(per):.0f} B/cyc of {64 * ch} peak")


def report(name, r, dma, dip):
  print(f"=== {name}")
  for q in r['qwen']:
    print('  ' + q.replace('[UART] ', ''))
  dma_probe(r)
  fpu = r['fpu']
  if not fpu:
    print('  no [FPU] bench lines in the window (not yet in the benchmark?)')
    return
  cyc = sorted(fpu)
  u = [fpu[c] for c in cyc]
  mean = sum(u) / len(u)
  print(f"  window cyc {cyc[0]}..{cyc[-1]} ({len(u)} periods)")
  print(f"  util mean {mean:.1f}%  median {statistics.median(u):.1f}  p10 {pct(u, .1):.1f}  "
        f"periods <{dip:g}%: {100 * sum(x < dip for x in u) / len(u):.0f}%  <20%: "
        f"{100 * sum(x < 20 for x in u) / len(u):.0f}%")

  # ---- loss budget -------------------------------------------------------------------------
  busy = r['grp'].get(('FPUG', 'busy'), {})
  insn = r['grp'].get(('INSNG', 'insn'), {})
  stall_keys = [k for (t, k) in r['grp'] if t == 'STALLG']

  def asleep(c):
    """Groups that did nothing at all this period: FPU 0, insn 0, every stall 0."""
    if c not in busy or c not in insn:
      return 0
    n = 0
    for g in range(NG):
      if busy[c][g] == 0 and insn[c][g] == 0 and all(
          r['grp'][('STALLG', k)].get(c, [1] * NG)[g] == 0 for k in stall_keys):
        n += 1
    return n

  # Every period below the good level loses (good - util); a group asleep that period makes
  # it a barrier sleep, otherwise a sync / refill loss. Dip EVENTS (for the spacing) are the
  # runs of periods below --dip.
  good = pct(u, .75)
  lost = {'sleep': 0.0, 'sync': 0.0}
  events = {'sleep': [], 'sync': []}
  prev = None
  for c, x in zip(cyc, u):
    kind = 'sleep' if asleep(c) else 'sync'
    if x < good:
      lost[kind] += good - x
    if x >= dip:
      prev = None
      continue
    if prev != kind:
      events[kind].append(c)
    prev = kind
  n = len(u)
  print(f"  loss budget (of 100%): steady shortfall {100 - good:.1f} (good level p75 {good:.1f}) | "
        f"barrier sleep {lost['sleep'] / n:.1f} | sync/refill {lost['sync'] / n:.1f}")
  for kind, ev in events.items():
    if len(ev) > 1:
      gaps = [b - a for a, b in zip(ev, ev[1:])]
      print(f"    {kind:5s} dips <{dip:g}%: {len(ev)} events, median spacing "
            f"{statistics.median(gaps):.0f} cyc")
    elif ev:
      print(f"    {kind:5s} dips <{dip:g}%: 1 event at {ev[0]}")

  # ---- per group ---------------------------------------------------------------------------
  def tot(tag, k):
    m = r['grp'].get((tag, k), {})
    return [sum(v[g] for v in m.values()) for g in range(NG)], len(m)

  if busy:
    b, p = tot('FPUG', 'busy')
    lanes = 4 * 16 * 1000  # denom of [FPUG]: 16 cores x 4 lanes x 1000 cycles
    print(row('grp util%', b, lambda v: f"{100 * v / (lanes * p):4.0f}"))
  for k in ('acc', 'fen', 'lsu', 'ins', 'raw'):
    if ('STALLG', k) in r['grp']:
      v, p = tot('STALLG', k)
      print(row(f'{k} %', v, lambda x: f"{100 * x / (16000 * p):4.0f}"))
  if insn:
    v, p = tot('INSNG', 'insn')
    print(row('insn/cyc', v, lambda x: f"{x / (16000 * p):4.2f}"))

  # ---- MSHR --------------------------------------------------------------------------------
  if r['mshru']:
    sl = ' '.join(f"s{i}={sum(v) / len(v) / 100:.2f}" for i, v in sorted(r['mshru'].items()) if v)
    print(f"  mshr valid  {sl}")
  bc = sorted(c for c in r['byp'] if cyc[0] <= c <= cyc[-1])
  if len(bc) > 1:
    rate = (r['byp'][bc[-1]] - r['byp'][bc[0]]) / ((bc[-1] - bc[0]) / 1000) / NG
    print(f"  bypass      {rate:.0f} forwards /kcyc /group")

  # ---- NoC ---------------------------------------------------------------------------------
  for s_ in ('REQ_MSHR_OUT', 'REQ_SLAVE_IN', 'RESP_SLAVE_OUT', 'RESP_MSHR_IN'):
    a = r['stage'].get(s_)
    if a and a[2]:
      print(f"  {s_:<15}{a[0] / len(a[2]) / NG / 1000:5.2f} /grp/cyc  stall/hsk {a[1] / max(a[0], 1):.2f}")

  # ---- banks -------------------------------------------------------------------------------
  if r['bank']:
    tiles = max(t for (_, t) in r['bank']) + 1
    st, act = [], []
    for g in range(NG):
      h = [r['bank'].get((g, t), [0, 0])[0] for t in range(tiles)]
      s = [r['bank'].get((g, t), [0, 0])[1] for t in range(tiles)]
      st.append(sum(s) / max(sum(h), 1))
      # Per period: tiles carrying more than half their fair share of the group's traffic.
      per = []
      for (c, gg), m in r['bank_p'].items():
        if gg != g:
          continue
        tot_h = sum(m.values())
        if tot_h:
          per.append(sum(x > tot_h / (2 * tiles) for x in m.values()))
      act.append(sum(per) / len(per) if per else 0.0)
    print(row('bank st/hs', st, lambda v: f"{v:4.2f}"))
    print(row('busy tiles', act, lambda v: f"{v:4.1f}"))

  # ---- DMA ---------------------------------------------------------------------------------
  if dma:
    for size in sorted(dma, reverse=True)[:3]:
      d = dma[size]
      print(f"  dma {size:>9} B x{len(d):<3} cycles mean {sum(d) / len(d):.0f} "
            f"min {min(d)} max {max(d)}  ({size * len(d) / max(sum(d), 1):.0f} B/cyc)")


def main():
  ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
  ap.add_argument('runs', nargs='+', help='run directory (with transcript) or transcript file')
  ap.add_argument('--from', dest='c_from', type=int, default=0, help='first cycle (default 0)')
  ap.add_argument('--to', dest='c_to', type=int, default=1 << 62, help='last cycle')
  ap.add_argument('--dip', type=float, default=50.0, help='a period below this util%% is a dip')
  a = ap.parse_args()
  for run in a.runs:
    tr = os.path.join(run, 'transcript') if os.path.isdir(run) else run
    if not os.path.exists(tr):
      print(f"=== {run}: no transcript", file=sys.stderr)
      continue
    dl = os.path.join(os.path.dirname(tr), 'dma.log')
    dma = parse_dma(dl) if os.path.exists(dl) else {}
    report(run, parse(tr, a.c_from, a.c_to), dma, a.dip)
    print()


if __name__ == '__main__':
  main()
