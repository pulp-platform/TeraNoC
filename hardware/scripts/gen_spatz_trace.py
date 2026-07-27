#!/usr/bin/env python3
# Copyright 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Post-process the per-Spatz-core vector traces emitted by
# working_dir/spatz/hw/ip/spatz_cc/src/spatz_mempool_cc.sv (the vector counterpart of the Snitch
# trace_hart_*.dasm / gen_trace.py flow). Two input streams per core, in $(buildpath):
#   trace_spatz_insn_hart_<id>.log : one ISSUE and one RETIRE line per vector instruction.
#   trace_spatz_cyc_hart_<id>.log  : one line per active cycle (per-lane IPU + per-FPU + VLSU).
# For each core it writes <out>/spatz_hart_<id>.txt (readable instruction timeline + a
# FU-utilization / stall-reason summary), and an aggregate <out>/spatz_summary.csv.

import argparse
import glob
import os
import re
from collections import Counter, defaultdict

ISSUE_RE = re.compile(
    r'ISSUE\s+(\d+)\s+id=(\d+)\s+(\S+)\s+(\S+)'
    r'(?:\s+pc=(0x[0-9a-fA-F]+))?(?:\s+insn=(0x[0-9a-fA-F]+))?'
    r'\s+vd=(\d+)\s+vs1=(\d+)\s+vs2=(\d+)\s+vl=(\d+)')
RETIRE_RE = re.compile(
    r'RETIRE\s+(\d+)\s+id=(\d+)\s+(\S+)\s+(\S+)'
    r'(?:\s+pc=(0x[0-9a-fA-F]+))?(?:\s+insn=(0x[0-9a-fA-F]+))?'
    r'\s+active=(\d+)\s+stall=(\d+)\s+ipu_cyc=(\d+)\s+fpu_cyc=(\d+)\s+mem_beats=(\d+)')
CYC_RE = re.compile(
    r'(\d+)\s+(\w+)\s+reason=(\S+)\s+run=(\S+)\s+ipu_busy=(\S+)\s+ipu_vld=(\S+)\s+'
    r'fpu_vld=(\S+)\s+vlsu=(\S+)\s+mem_req=(\d+)\s+mem_rsp=(\d+)'
    # optional (added 2026-07-26): VFU occupancy vs operand-wait disambiguation
    r'(?:\s+vfu_ins=(\d+)\s+vfu_opr=(\d+)\s+vfu_stl=(\d+)\s+sb_deps=(\S+))?')


def hart_id_of(path):
    m = re.search(r'hart_(0x[0-9a-fA-F]+)', os.path.basename(path))
    return m.group(1) if m else os.path.basename(path)


def split_reasons(reason):
    """The tracer now lists EVERY active stall reason as a comma list (e.g. 'vfu,idfull,');
    older traces had a single priority-encoded token. Return the individual reasons."""
    return [r for r in reason.rstrip(',').split(',') if r and r != '-']


def lane_bits(bitstr):
    # SystemVerilog %b is MSB-first; lane 0 is the LSB (rightmost char). Return a list where
    # index l is 1 iff lane l's bit is set, ordered lane 0 .. lane N-1.
    s = bitstr.strip()
    return [1 if c == '1' else 0 for c in reversed(s)]


def parse_insn(path):
    """Pair ISSUE/RETIRE (by id, LIFO per id since ids are reused) into instruction records."""
    open_by_id = defaultdict(list)
    records = []
    with open(path) as fh:
        for line in fh:
            if line.startswith('#'):
                continue
            mi = ISSUE_RE.match(line)
            if mi:
                cyc, iid, unit, op, pc, insn, vd, vs1, vs2, vl = mi.groups()
                open_by_id[int(iid)].append({
                    'issue': int(cyc), 'id': int(iid), 'unit': unit, 'op': op,
                    'pc': pc or '-', 'insn': insn or '-',
                    'vd': int(vd), 'vs1': int(vs1), 'vs2': int(vs2), 'vl': int(vl)})
                continue
            mr = RETIRE_RE.match(line)
            if mr:
                cyc, iid, unit, op, pc, insn, act, stall, ipuc, fpuc, memb = mr.groups()
                stack = open_by_id.get(int(iid))
                # FIFO: a reused id retires in program order (oldest open ISSUE first).
                rec = stack.pop(0) if stack else {
                    'issue': None, 'id': int(iid), 'unit': unit, 'op': op,
                    'pc': '-', 'insn': '-', 'vd': -1, 'vs1': -1, 'vs2': -1, 'vl': -1}
                rec.update({'retire': int(cyc),
                            # An old-format ISSUE (no pc/insn) leaves them '-'; take them from
                            # whichever side has them.
                            'pc': rec.get('pc', '-') if rec.get('pc', '-') != '-' else (pc or '-'),
                            'insn': rec.get('insn', '-') if rec.get('insn', '-') != '-' else (insn or '-'),
                            'active': int(act), 'stall': int(stall),
                            'ipu_cyc': int(ipuc), 'fpu_cyc': int(fpuc), 'mem_beats': int(memb)})
                records.append(rec)
    # Instructions still in flight at trace end (issued, never retired within the window).
    for stack in open_by_id.values():
        for rec in stack:
            rec.setdefault('retire', None)
            records.append(rec)
    records.sort(key=lambda r: (r['issue'] if r['issue'] is not None else r.get('retire', 0)))
    return records


def parse_cyc(path, nlanes_max=64):
    """Aggregate per-cycle activity into utilization / stall stats."""
    s = {
        'traced_cycles': 0, 'run_cycles': 0, 'stall_cycles': 0,
        'stall_by_reason': Counter(),
        'ipu_busy': [0] * nlanes_max, 'ipu_vld': [0] * nlanes_max, 'fpu_vld': [0] * nlanes_max,
        'nlanes': 0, 'nfpu': 0,
        'mem_req_beats': 0, 'mem_rsp_beats': 0,
        'vlsu_load_cyc': 0, 'vlsu_store_cyc': 0,
        'any_ipu_cyc': 0, 'any_fpu_cyc': 0,
        # VFU occupancy split (needs the vfu_ins/vfu_opr fields; stays 0 on older traces).
        # vfu_busy_compute : VFU holds an instruction AND its operands are ready -> real work
        # vfu_busy_waitdata: VFU holds an instruction but operands NOT ready -> waiting on a load
        # vfu_empty        : VFU holds nothing -> issue-starved (nothing to compute)
        'vfu_fields': False, 'vfu_busy_compute': 0, 'vfu_busy_waitdata': 0, 'vfu_empty': 0,
        'first_cyc': None, 'last_cyc': None,
    }
    with open(path) as fh:
        for line in fh:
            if line.startswith('#'):
                continue
            m = CYC_RE.match(line)
            if not m:
                continue
            (cyc, state, reason, run, ipu_b, ipu_v, fpu_v, vlsu, mreq, mrsp,
             vfu_ins, vfu_opr, vfu_stl, sb_deps) = m.groups()
            cyc = int(cyc)
            if vfu_ins is not None:
                s['vfu_fields'] = True
                if vfu_ins == '0':
                    s['vfu_empty'] += 1
                elif vfu_opr == '1':
                    s['vfu_busy_compute'] += 1
                else:
                    s['vfu_busy_waitdata'] += 1
            s['traced_cycles'] += 1
            s['first_cyc'] = cyc if s['first_cyc'] is None else s['first_cyc']
            s['last_cyc'] = cyc
            if state == 'stall':
                s['stall_cycles'] += 1
                # reason is a comma list (e.g. 'vfu,idfull,'); each active reason is counted, so
                # the reason percentages can overlap (sum > 100% of stall cycles).
                for r in split_reasons(reason):
                    s['stall_by_reason'][r] += 1
            else:
                s['run_cycles'] += 1
            ib, iv, fv = lane_bits(ipu_b), lane_bits(ipu_v), lane_bits(fpu_v)
            s['nlanes'] = max(s['nlanes'], len(ib), len(iv))
            s['nfpu'] = max(s['nfpu'], len(fv))
            for l, b in enumerate(ib):
                s['ipu_busy'][l] += b
            for l, b in enumerate(iv):
                s['ipu_vld'][l] += b
            for l, b in enumerate(fv):
                s['fpu_vld'][l] += b
            if any(ib):
                s['any_ipu_cyc'] += 1
            if any(fv):
                s['any_fpu_cyc'] += 1
            if int(mreq):
                s['mem_req_beats'] += 1
            if int(mrsp):
                s['mem_rsp_beats'] += 1
            if 'Load' in vlsu:
                s['vlsu_load_cyc'] += 1
            elif 'Store' in vlsu:
                s['vlsu_store_cyc'] += 1
    return s


FPL_REQ = re.compile(r'REQ (\d+) addr=(0x[0-9a-fA-F]+) tag=(\d+) (\w)')
FPL_RSP = re.compile(r'RSP (\d+) tag=(\d+)')
# New (2026-07-25): the FP-sequencer stream also carries an ISSUE/RETIRE instruction view with
# pc+insn, and its STALL reason is a comma list. pc is optional so old traces still parse.
FPL_ISSUE = re.compile(
    r'ISSUE\s+(\d+)\s+pc=(0x[0-9a-fA-F]+)\s+insn=(0x[0-9a-fA-F]+)\s+kind=(\w+)\s+fd=(\d+)')
FPL_RETIRE = re.compile(
    r'RETIRE\s+(\d+)\s+port=(\w+)\s+fd=(\d+)\s+pc=(0x[0-9a-fA-F]+)\s+insn=(0x[0-9a-fA-F]+)')
FPL_STALL = re.compile(r'STALL\s+(\d+)\s+reason=(\S+)(?:\s+pc=(0x[0-9a-fA-F]+))?')


def parse_fplsu(path):
    """FP-sequencer (flw/fsw/fmv + scalar-offload) stream.
      * memory view: pair REQ->RSP by tag (= fd) into per-load latencies;
      * instruction view: pair ISSUE->RETIRE by fd (FIFO) into offload->writeback latencies.
      * sequencer stall-reason histogram (comma-list, each reason counted)."""
    from collections import defaultdict, deque
    open_by_tag = defaultdict(deque)
    open_by_fd = defaultdict(deque)
    loads = []            # REQ/RSP pairs: {req, rsp, addr, store}
    issues = []           # ISSUE/RETIRE pairs: {issue, retire, kind, pc, insn, port}
    kind_counts = Counter()
    port_counts = Counter()
    unmatched_retires = 0
    stalls = Counter()
    n_req = n_rsp = 0
    with open(path) as fh:
        for line in fh:
            if line.startswith('#'):
                continue
            m = FPL_REQ.match(line)
            if m:
                cyc, addr, tag, ls = m.groups()
                open_by_tag[tag].append((int(cyc), addr, ls))
                n_req += 1
                continue
            m = FPL_RSP.match(line)
            if m:
                cyc, tag = m.groups()
                n_rsp += 1
                q = open_by_tag.get(tag)
                if q:
                    rc, addr, ls = q.popleft()
                    loads.append({'req': rc, 'rsp': int(cyc), 'addr': addr, 'store': ls == 'S'})
                continue
            m = FPL_ISSUE.match(line)
            if m:
                cyc, pc, insn, kind, fd = m.groups()
                kind_counts[kind] += 1
                # A store produces no writeback, so it never gets a RETIRE -- don't queue it.
                if kind != 'store':
                    open_by_fd[fd].append((int(cyc), kind, pc, insn))
                continue
            m = FPL_RETIRE.match(line)
            if m:
                cyc, port, fd, pc, insn = m.groups()
                port_counts[port] += 1
                q = open_by_fd.get(fd)
                if q:
                    rc, kind, ipc, iinsn = q.popleft()
                    issues.append({'issue': rc, 'retire': int(cyc), 'kind': kind,
                                   'pc': ipc, 'insn': iinsn, 'port': port})
                else:
                    unmatched_retires += 1
                continue
            m = FPL_STALL.match(line)
            if m:
                for r in split_reasons(m.group(2)):
                    stalls[r] += 1
    return {'loads': loads, 'issues': issues, 'kind_counts': kind_counts,
            'port_counts': port_counts, 'unmatched_retires': unmatched_retires,
            'stalls': stalls, 'n_req': n_req, 'n_rsp': n_rsp}


def pct(n, d):
    return (100.0 * n / d) if d else 0.0


def _median(vals):
    if not vals:
        return 0
    s = sorted(vals)
    return s[len(s) // 2]


def write_core_report(out_dir, hid, insn, cyc, fpl=None):
    path = os.path.join(out_dir, f'spatz_hart_{hid}.txt')
    tc = cyc['traced_cycles']
    with open(path, 'w') as fh:
        fh.write(f'# Spatz core trace summary  hart {hid}\n')
        if cyc['first_cyc'] is not None:
            fh.write(f'# traced cycles: {tc}  (cyc {cyc["first_cyc"]}..{cyc["last_cyc"]})\n')
        fh.write(f'# vector instructions retired: {sum(1 for r in insn if r.get("retire"))}\n\n')

        fh.write('== Cycle occupancy ==\n')
        fh.write(f'  run   : {cyc["run_cycles"]:>8}  ({pct(cyc["run_cycles"], tc):5.1f}%)\n')
        fh.write(f'  stall : {cyc["stall_cycles"]:>8}  ({pct(cyc["stall_cycles"], tc):5.1f}%)\n')
        fh.write('  (stall reasons are comma-listed per cycle, so these can overlap)\n')
        for reason, n in cyc['stall_by_reason'].most_common():
            fh.write(f'      stall:{reason:<8} {n:>8}  ({pct(n, tc):5.1f}%)\n')

        fh.write('\n== Functional-unit utilization (fraction of traced cycles) ==\n')
        for l in range(cyc['nlanes']):
            fh.write(f'  IPU lane {l}: busy {pct(cyc["ipu_busy"][l], tc):5.1f}%  '
                     f'result {pct(cyc["ipu_vld"][l], tc):5.1f}%\n')
        for l in range(cyc['nfpu']):
            fh.write(f'  FPU {l}    : result {pct(cyc["fpu_vld"][l], tc):5.1f}%\n')
        fh.write(f'  any-IPU-busy : {pct(cyc["any_ipu_cyc"], tc):5.1f}%   '
                 f'any-FPU-result : {pct(cyc["any_fpu_cyc"], tc):5.1f}%\n')
        if cyc.get('vfu_fields'):
            fh.write('\n== VFU occupancy split (is the VFU COMPUTING or WAITING?) ==\n')
            fh.write(f'  busy, operands ready (real compute) : {pct(cyc["vfu_busy_compute"], tc):5.1f}%\n')
            fh.write(f'  busy, WAITING FOR DATA (operands)   : {pct(cyc["vfu_busy_waitdata"], tc):5.1f}%\n')
            fh.write(f'  empty (issue-starved, nothing to do): {pct(cyc["vfu_empty"], tc):5.1f}%\n')
        fh.write(f'  VLSU  load-state {pct(cyc["vlsu_load_cyc"], tc):5.1f}%  '
                 f'store-state {pct(cyc["vlsu_store_cyc"], tc):5.1f}%  '
                 f'req-beats {cyc["mem_req_beats"]}  rsp-beats {cyc["mem_rsp_beats"]}\n')

        if fpl:
            fh.write('\n== FP sequencer (scalar flw/fsw/fmv + scalar offloads) ==\n')
            fh.write('  issues : ' +
                     ', '.join(f'{k}={v}' for k, v in fpl['kind_counts'].most_common()) + '\n')
            fh.write('  retire : ' +
                     ', '.join(f'{p}={v}' for p, v in fpl['port_counts'].most_common()) +
                     (f"  (unmatched retires: {fpl['unmatched_retires']})"
                      if fpl['unmatched_retires'] else '') + '\n')
            fh.write('  offload->writeback latency (median cyc):')
            for kind in ('load', 'move', 'vector'):
                lats = [i['retire'] - i['issue'] for i in fpl['issues'] if i['kind'] == kind]
                if lats:
                    fh.write(f'  {kind}={_median(lats)} (n={len(lats)})')
            fh.write('\n')
            fh.write('  FP-LSU memory: reqs={} rsps={}  load lat(median cyc)={}\n'.format(
                fpl['n_req'], fpl['n_rsp'],
                _median([l['rsp'] - l['req'] for l in fpl['loads'] if not l['store']])))
            if fpl['stalls']:
                fh.write('  sequencer stalls: ' +
                         ', '.join(f'{r}={n}' for r, n in fpl['stalls'].most_common()) + '\n')

        fh.write('\n== Instruction mix ==\n')
        by_op = Counter(r['op'] for r in insn)
        for op, n in by_op.most_common():
            fh.write(f'  {op:<10} {n}\n')

        fh.write('\n== Instruction timeline (issue -> retire) ==\n')
        fh.write(f'  {"pc":>10} {"issue":>8} {"retire":>8} {"unit":<5} {"op":<10} '
                 f'{"vd":>3} {"vl":>4} {"active":>7} {"stall":>6} '
                 f'{"ipu":>5} {"fpu":>5} {"mem":>5}\n')
        for r in insn:
            iss = r['issue'] if r['issue'] is not None else -1
            ret = r.get('retire') if r.get('retire') is not None else -1
            fh.write(f'  {r.get("pc", "-"):>10} {iss:>8} {ret:>8} {r["unit"]:<5} {r["op"]:<10} '
                     f'{r["vd"]:>3} {r["vl"]:>4} {r.get("active", -1):>7} {r.get("stall", -1):>6} '
                     f'{r.get("ipu_cyc", -1):>5} {r.get("fpu_cyc", -1):>5} {r.get("mem_beats", -1):>5}\n')
    return path


def _stats(vals):
    if not vals:
        return (0.0, 0.0, 0.0, 0.0)
    s = sorted(vals)
    n = len(s)
    mean = sum(s) / n
    median = s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2
    return (mean, median, s[0], s[-1])


def write_aggregate(out_dir, per_core):
    """Fleet-wide utilization + bottleneck summary across all traced cores."""
    path = os.path.join(out_dir, 'spatz_aggregate.txt')
    n = len(per_core)
    col = lambda k: [r[k] for r in per_core]
    with open(path, 'w') as fh:
        fh.write(f'# Spatz fleet aggregate over {n} traced core(s)\n\n')
        fh.write(f'{"metric":<20}{"mean":>9}{"median":>9}{"min":>9}{"max":>9}\n')
        for label, key in [('run %', 'run_pct'), ('stall %', 'stall_pct'),
                           ('  stall idfull %', 'idfull_pct'), ('  stall vfu %', 'vfu_pct'),
                           ('  stall vlsu %', 'vlsu_pct'), ('  stall vsldu %', 'vsldu_pct'),
                           ('FPU busy %', 'fpu_pct'), ('IPU busy %', 'ipu_pct')]:
            m, md, lo, hi = _stats(col(key))
            fh.write(f'{label:<20}{m:>9.1f}{md:>9.1f}{lo:>9.1f}{hi:>9.1f}\n')
        fh.write(f'\ntotal insns retired: {sum(col("insn"))}   '
                 f'mem req-beats: {sum(col("mem_req"))}   rsp-beats: {sum(col("mem_rsp"))}\n')
        mean_stall = _stats(col('stall_pct'))[0]
        mean_fpu = _stats(col('fpu_pct'))[0]
        mean_ipu = _stats(col('ipu_pct'))[0]
        reasons = {r: _stats(col(f'{r}_pct'))[0] for r in ('idfull', 'vfu', 'vlsu', 'vsldu')}
        top = max(reasons, key=reasons.get)
        fh.write('\n== Bottleneck (fleet mean) ==\n')
        fh.write(f'  compute: {100 - mean_stall:.1f}% run, {mean_stall:.1f}% stalled; '
                 f'FPU busy {mean_fpu:.1f}%, IPU busy {mean_ipu:.1f}%\n')
        fh.write(f'  dominant stall reason: {top} ({reasons[top]:.1f}% of cycles)  '
                 f'[all: ' + ', '.join(f'{k}={v:.1f}%' for k, v in reasons.items()) + ']\n')
    return path


def _flush_cluster(cur, addr, clusters):
    """One shared-load instance: keep the first RSP per core in this time window; if >=2 cores
    participated, record the response-cycle spread."""
    if not cur:
        return
    by_core = {}
    for req, rsp, h in cur:
        by_core.setdefault(h, rsp)
    if len(by_core) >= 2:
        rsps = list(by_core.values())
        clusters.append((addr, len(by_core), max(rsps) - min(rsps), cur[0][0]))


def write_fplsu_alignment(out_dir, fplsu_by_hart, gap=24):
    """Cross-core scalar-load return alignment. For LOADS to the same address, cluster by request
    time (the sharing cores loading it within `gap` cycles = one shared instance) and report the
    RESPONSE-cycle spread: 0 = the group MSHR coalesced + multicast to one aligned cycle; large =
    un-coalesced (each an independent NoC round-trip)."""
    from collections import defaultdict
    by_addr = defaultdict(list)
    for hid, fp in fplsu_by_hart.items():
        for ld in fp['loads']:
            if not ld['store']:
                by_addr[ld['addr']].append((ld['req'], ld['rsp'], hid))

    clusters = []
    for addr, evs in by_addr.items():
        evs.sort()
        cur, last = [], None
        for req, rsp, hid in evs:
            if last is not None and req - last > gap:
                _flush_cluster(cur, addr, clusters)
                cur = []
            cur.append((req, rsp, hid))
            last = req
        _flush_cluster(cur, addr, clusters)

    path = os.path.join(out_dir, 'spatz_fplsu_alignment.txt')
    multi = [c for c in clusters if c[1] >= 2]
    with open(path, 'w') as fh:
        fh.write('# Shared scalar-load (flw) return-alignment across cores.\n')
        fh.write(f'# shared instance = sharing cores loading the same addr within {gap} cyc; '
                 'spread = max-min of their RSP cycle.\n')
        fh.write('# spread 0 = MSHR coalesced+multicast (aligned); >4 = un-coalesced '
                 '(per-core NoC round-trip).\n\n')
        if not multi:
            fh.write('no multi-core shared-load instances found.\n')
            return path
        spreads = sorted(c[2] for c in multi)
        n = len(multi)
        aligned = sum(1 for s in spreads if s == 0)
        tight = sum(1 for s in spreads if 0 < s <= 4)
        loose = sum(1 for s in spreads if s > 4)
        fh.write(f'shared-load instances (>=2 cores): {n}\n')
        fh.write(f'  RSP-spread == 0  (perfect multicast) : {aligned:>6}  ({pct(aligned, n):4.1f}%)\n')
        fh.write(f'  RSP-spread 1..4  (coalesced+drain)   : {tight:>6}  ({pct(tight, n):4.1f}%)\n')
        fh.write(f'  RSP-spread > 4   (un-coalesced)      : {loose:>6}  ({pct(loose, n):4.1f}%)\n')
        fh.write(f'  median RSP-spread: {spreads[n // 2]} cyc   max: {spreads[-1]} cyc\n\n')
        fh.write(f'{"addr":>10} {"cores":>6} {"rsp_spread":>11} {"first_req":>10}\n')
        for addr, ncores, spread, reqmin in sorted(multi, key=lambda c: -c[2])[:12]:
            fh.write(f'{addr:>10} {ncores:>6} {spread:>11} {reqmin:>10}\n')
    return path


def main():
    ap = argparse.ArgumentParser(description='Post-process Spatz vector-core traces.')
    ap.add_argument('--buildpath', required=True, help='dir containing trace_spatz_*_hart_*.log')
    ap.add_argument('--out', required=True, help='output dir for reports')
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    insn_files = sorted(glob.glob(os.path.join(args.buildpath, 'trace_spatz_insn_hart_*.log')))
    if not insn_files:
        print(f'[gen_spatz_trace] no trace_spatz_insn_hart_*.log in {args.buildpath} '
              f'(run a sim with the benchmark csr_trace region, or spatz_trace=1)')
        return

    per_core = []
    fplsu_by_hart = {}
    reported = 0
    for ipath in insn_files:
        hid = hart_id_of(ipath)
        cpath = os.path.join(args.buildpath, f'trace_spatz_cyc_hart_{hid}.log')
        fplpath = os.path.join(args.buildpath, f'trace_spatz_fplsu_hart_{hid}.log')
        insn = parse_insn(ipath)
        cyc = parse_cyc(cpath) if os.path.exists(cpath) else parse_cyc(os.devnull)
        # Skip cores that never traced anything (empty benchmark region on that core).
        if cyc['traced_cycles'] == 0 and not insn:
            continue
        tc = cyc['traced_cycles'] or 1
        sr = cyc['stall_by_reason']
        rec = {
            'hart': hid, 'traced': cyc['traced_cycles'],
            'run_pct': pct(cyc['run_cycles'], tc), 'stall_pct': pct(cyc['stall_cycles'], tc),
            'idfull_pct': pct(sr.get('idfull', 0), tc), 'vfu_pct': pct(sr.get('vfu', 0), tc),
            'vlsu_pct': pct(sr.get('vlsu', 0), tc), 'vsldu_pct': pct(sr.get('vsldu', 0), tc),
            'fpu_pct': pct(cyc['any_fpu_cyc'], tc), 'ipu_pct': pct(cyc['any_ipu_cyc'], tc),
            'insn': sum(1 for r in insn if r.get('retire')),
            'mem_req': cyc['mem_req_beats'], 'mem_rsp': cyc['mem_rsp_beats'],
            'fpl_loads': 0, 'fpl_lat_med': 0, 'fpl_off_lat_med': 0}
        fp = parse_fplsu(fplpath) if os.path.exists(fplpath) else None
        if fp and (fp['loads'] or fp['issues']):
            fplsu_by_hart[hid] = fp
            lats = [l['rsp'] - l['req'] for l in fp['loads'] if not l['store']]
            rec['fpl_loads'] = len(lats)
            rec['fpl_lat_med'] = _median(lats)
            # offload -> writeback (ISSUE -> RETIRE) latency, the full scalar-offload round trip.
            rec['fpl_off_lat_med'] = _median([i['retire'] - i['issue'] for i in fp['issues']])
        write_core_report(args.out, hid, insn, cyc, fp)
        reported += 1
        per_core.append(rec)

    cols = ['hart', 'traced', 'run_pct', 'stall_pct', 'idfull_pct', 'vfu_pct', 'vlsu_pct',
            'vsldu_pct', 'fpu_pct', 'ipu_pct', 'insn', 'mem_req', 'mem_rsp',
            'fpl_loads', 'fpl_lat_med', 'fpl_off_lat_med']
    csv_path = os.path.join(args.out, 'spatz_summary.csv')
    with open(csv_path, 'w') as fh:
        fh.write(','.join(cols) + '\n')
        for r in per_core:
            fh.write(','.join(f'{r[c]:.1f}' if isinstance(r[c], float) else str(r[c])
                              for c in cols) + '\n')
    agg_path = write_aggregate(args.out, per_core) if per_core else '(none)'
    align_path = write_fplsu_alignment(args.out, fplsu_by_hart) if fplsu_by_hart else '(no fplsu stream)'
    print(f'[gen_spatz_trace] wrote {reported} core report(s), {csv_path}, {agg_path}, {align_path}')


if __name__ == '__main__':
    main()
