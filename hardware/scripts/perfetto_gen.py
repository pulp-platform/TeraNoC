#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# perfetto_gen.py -- Phase 1 of the performance-visualization plan.
#
# Reads the per-hart Snitch traces (trace_hart_*.dasm) and emits a Perfetto
# *protobuf* trace (https://ui.perfetto.dev). Scale-ready successor to and
# SUPERSET of `make tracevis`: group>tile>core nested track tree, per-core
# function/instruction slices, and per-core IPC + stall-breakdown COUNTER
# tracks (windowed over --window-ns), which tracevis never had.
#
# Counter semantics (matters for correctness): the .dasm emits a line only when
# an instruction RETIRES, and its stall_* count the cycles of the gap that
# PRECEDED that retirement, so each instruction's stalls are spread across the
# windows the retirement gap spans; every active window is emitted so an idle
# window reads a true 0 (no sample-and-hold).
#
# Everything comes from the raw .dasm (no `make trace`): stalls + pc in the
# line, function/source via addr2line on the elf, disasm via spike-dasm.
#
# Usage:
#   scripts/perfetto_gen.py build_vcs/trace_hart_*.dasm -o out.perfetto-trace
# scripts/perfetto_gen.py ... --slices instruction # full per-insn timeline
#   scripts/perfetto_gen.py ... --slices none             # counters only
#   (geometry defaults match tensorpool64: 4 cores/tile, 4 tiles/group)

import argparse
import bisect
import collections
import glob
import os
import re
import subprocess
import sys

from perfetto.trace_builder.proto_builder import TraceProtoBuilder
from perfetto.protos.perfetto.trace.perfetto_trace_pb2 import TrackEvent

SEQ = 1  # trusted_packet_sequence_id (single producer; absolute timestamps)

# One .dasm line:  <time> <cyc> <pc> <instr-or-DASM(hex)> #; {'k': 0x.., ...}
# spike-dasm replaces DASM(hex) with disasm but preserves the `#;` extras dict,
# so this matches both forms.
LINE_RE = re.compile(
    r"^\s*(\d+)\s+(\d+)\s+(0x[0-9a-fA-F]+)\s+(.*?)\s+#;\s*(.*)$")
FIELD_RE = re.compile(r"'(\w+)':\s*(0x[0-9a-fA-F]+)")
HART_RE = re.compile(r"trace_hart_0x([0-9a-fA-F]+)\.dasm")

# Per-core counter metrics. IPC from the retirement count; stalls from the
# .dasm extras dict.
STALLS = ["stall_tot", "stall_raw", "stall_lsu", "stall_acc", "stall_ins"]
STALL_COMPONENTS = [s for s in STALLS if s != "stall_tot"]  # raw/lsu/acc/ins
METRICS = ["IPC"] + STALLS

# Functions that bracket the region of interest (tracevis -cb semantics).
BENCH_START = "mempool_start_benchmark"
BENCH_STOP = "mempool_stop_benchmark"


class Uuids:
    """Deterministic, collision-free uuid allocator keyed by a name."""

    def __init__(self):
        self._n = 0
        self._m = {}
        self._seen = set()

    def get(self, key):
        if key not in self._m:
            self._n += 1
            self._m[key] = self._n
        return self._m[key]


class Addr2Line:
    """Batched, globally-cached PC -> (function, source, inlined-frames)."""

    def __init__(self, tool, elf):
        self.tool = tool
        self.elf = elf
        self.cache = {}

    def resolve(self, pcs):
        need = sorted({p for p in pcs if p not in self.cache})
        if need and self.tool and self.elf:
            for i in range(0, len(need), 4000):  # stay under arg-length limits
                chunk = need[i:i + 4000]
                out = subprocess.run(
                    [self.tool, "-e", self.elf, "-f", "-a", "-i"]
                    + [f"0x{p:x}" for p in chunk],
                    capture_output=True, text=True).stdout
                self._parse(out)
        for p in need:  # anything addr2line didn't echo
            self.cache.setdefault(p, ("??", "??:0", ""))

    def _parse(self, out):
        # Block: 0x<addr>\n<func>\n<file>:<line>\n[<inl func>\n<inl file>\n]...
        # `-a` echoes the address; `-i` lists inlined-by frames after the
        # first.
        lines = out.split("\n")
        i, n = 0, len(lines)
        while i < n:
            if not lines[i].startswith("0x"):
                i += 1
                continue
            addr = int(lines[i], 16)
            func = lines[i + 1] if i + 1 < n else "??"
            src = lines[i + 2] if i + 2 < n else "??:0"
            i += 3
            inl = []
            while i < n and not lines[i].startswith("0x"):
                inl.append(lines[i])
                i += 1
            # remaining lines are (func, file) pairs for each inlined-by frame
            inline_str = " ".join("(inlined by) " + x for x in inl if x)
            self.cache[addr] = (func, src, inline_str)

    def get(self, pc):
        return self.cache.get(pc, ("??", "??:0", ""))


# TrackDescriptor.ChildTracksOrdering.EXPLICIT: order children by
# sibling_order_rank
CHILD_ORDER_EXPLICIT = 3


def add_track(
        builder,
        uuid,
        name,
        parent=None,
        counter=False,
        child_order=None,
        order_rank=None):
    pkt = builder.add_packet()
    td = pkt.track_descriptor
    td.uuid = uuid
    td.name = name
    if parent is not None:
        td.parent_uuid = parent
    if counter:
        td.counter.SetInParent()
    # how THIS track's children are ordered in the UI
    if child_order is not None:
        td.child_ordering = child_order
    # this track's rank among its siblings (EXPLICIT parent)
    if order_rank is not None:
        td.sibling_order_rank = order_rank
    return uuid


# Flow-slice ordering. Several hops of one transaction can land on the SAME
# cycle (combinational wires across pipeline stages). Perfetto chains
# same-timestamp flow slices by TRACE-INSERTION order, but the passes below
# emit per NODE TYPE (cores, tiles, routers, banks), NOT per transaction. So we
# BUFFER every event and flush it (flush_events) stable-sorted by (ts, phase,
# rank): the pipeline `rank` puts same-cycle hops in causal order. The rank
# lives ONLY in the sort key -- timestamps stay the TRUE cycle*clk_ns, so a
# 1-cycle handshake is exactly clk_ns wide (honest ns axis).
#
# Canonical transaction order (= strictly increasing (cycle, rank) along the
# chain):
# core req -> tile req out -> (router in -> router out)* -> tile req in -> bank
#   -> tile resp out -> (router in -> router out)* -> tile resp in -> core resp
# `rank` (pipeline stage, used by the flush sort key, NOT the timestamp):
#   0 = origin (core req)    1 = send (tile/router out)
#   2 = recv  (router/tile in)  3 = sink (bank, core resp terminator)
# ns per cycle: the timeline axis is REAL ns = cycle * clk_ns. Set in main()
# from
TICK = 2.0
# --clk-freq (default 500 MHz -> 2.0 ns/cycle) or --clk-period.

# The Perfetto UI orders sibling tracks LEXICOGRAPHICALLY by name, so numeric
# ids must be zero-padded (else Tile 10 sorts before Tile 2) and the top-level
# roots are numbered so the flow reads top-to-bottom. Widths set in main();
# MESH_NY (= --mesh-y) maps a linear group id to its mesh (x,y).
PAD_G = PAD_T = PAD_H = 2
MESH_NY = 1


def _gname(g):
    """Group track label: zero-padded linear id + its mesh (x,y) coordinate."""
    return f"Group {g:0{PAD_G}d} ({g // MESH_NY},{g % MESH_NY})"


def _tname(t):
    return f"Tile {t:0{PAD_T}d}"


# Export window in CYCLE NUMBERS (frequency-independent). Out-of-window data is
# DROPPED at load so the trace/DB actually shrinks. Defaults cover the whole
# run; set in main() from --cycle-start/end.
WIN_CYC_LO = 0
WIN_CYC_HI = 1 << 62


def _winclip(s, e):
    """Clip a [start,end] cycle run to the export window; None if it doesn't
    overlap."""
    s = s if s > WIN_CYC_LO else WIN_CYC_LO
    e = e if e < WIN_CYC_HI else WIN_CYC_HI
    return (s, e) if e > s else None


# Buffered track events, flushed by flush_events in a final stable sort by (ts,
# phase, rank). phase orders END(0) < COUNTER(1) < BEGIN(2) so a slice closes
# before the next opens at a shared timestamp; among same-cycle BEGINs the
# pipeline `rank` gives causal order so flows chain correctly.
_EVENTS = []
_PH_END, _PH_CTR, _PH_BEGIN = 0, 1, 2


def emit_counter(builder, ts_ns, track_uuid, value):
    t = int(ts_ns)
    _EVENTS.append(((t, _PH_CTR, 0), ("C", t, track_uuid, float(value))))


def pin_counter_range(builder, ctr_uuids, end_ns, clk_ns, lo=0.0, hi=1.0):
    """Pin each counter's y-axis to [lo, hi] (the protobuf has NO counter range
    field -- only data-driven auto-scaling). Emit a 1-cycle `hi` blip then `lo`
    at the very END of the track, past all real samples so it draws no visible
    bar yet forces the auto-range to span [lo, hi]; `lo` last so the track ends
    at 0."""
    for u in ctr_uuids:
        emit_counter(builder, end_ns - clk_ns, u, hi)
        emit_counter(builder, end_ns, u, lo)


def emit_slice_begin(
        builder,
        ts_ns,
        track_uuid,
        name,
        annos=None,
        flow_id=None,
        terminating=False,
        rank=0):
    # `rank` is the pipeline stage (0 origin .. 3 sink); it orders same-cycle
    # flow slices in the flush sort key, NEVER the timestamp.
    t = int(ts_ns)
    _EVENTS.append(((t, _PH_BEGIN, rank), ("B", t, track_uuid,
                   name, annos, flow_id, terminating)))


def emit_slice_end(builder, ts_ns, track_uuid):
    t = int(ts_ns)
    _EVENTS.append(((t, _PH_END, 0), ("E", t, track_uuid)))


def flush_events(builder):
    """Write every buffered track event, stable-sorted by (ts, phase, rank) so
    same-cycle flow begins land in pipeline order (see _EVENTS)."""
    for _, p in sorted(_EVENTS, key=lambda x: x[0]):
        pkt = builder.add_packet()
        pkt.timestamp = p[1]
        pkt.trusted_packet_sequence_id = SEQ
        ev = pkt.track_event
        ev.track_uuid = p[2]
        kind = p[0]
        if kind == "C":
            ev.type = TrackEvent.TYPE_COUNTER
            ev.double_counter_value = p[3]
        elif kind == "E":
            ev.type = TrackEvent.TYPE_SLICE_END
        # "B": slice begin (may carry a flow)
        else:
            ev.type = TrackEvent.TYPE_SLICE_BEGIN
            ev.name = p[3]
            annos, flow_id, terminating = p[4], p[5], p[6]
            # Flow: every slice of one transaction shares the flow_id, so a
            # click follows the arrows to the originating request and back. The
            # LAST hop lists the id in terminating_flow_ids ONLY -- not
            # flow_ids: Perfetto's FlowTracker inserts an edge on both
            # Begin(flow_ids) and End(terminating_flow_ids), so putting it in
            # both would self-loop the terminator (a bogus extra arrow).
            if flow_id is not None:
                if terminating:
                    ev.terminating_flow_ids.append(flow_id)
                else:
                    ev.flow_ids.append(flow_id)
            for k, v in (annos or []):
                if not v:
                    continue
                da = ev.debug_annotations.add()
                da.name = k
                da.string_value = v
    _EVENTS.clear()


class WindowAcc:
    """Per-window IPC + stall accumulator with gap-aware stall spreading.

    add(prev_t, t, stalls): the instruction retired at `t`; its stall cycles
    occurred during (prev_t, t], so they are distributed across the windows
    that interval overlaps. The retirement (for IPC) is counted in window(t).
    emit() then writes every window in [first_active, last_active] -- idle
    windows in between get a real 0.
    """

    def __init__(self, window_ns, clk_ns):
        self.W = window_ns
        self.clk = clk_ns
        self.count = {}
        self.stall = {}
        self.first = None
        self.last = None
        self.last_t = None

    def _touch(self, w):
        if self.first is None or w < self.first:
            self.first = w
        if self.last is None or w > self.last:
            self.last = w

    def _add_stall(self, w, stalls, frac):
        d = self.stall.setdefault(w, {s: 0.0 for s in STALLS})
        for s in STALLS:
            d[s] += stalls[s] * frac
        self._touch(w)

    def add(self, prev_t, t, stalls):
        w = int(t // self.W)
        self.count[w] = self.count.get(w, 0) + 1
        self._touch(w)
        self.last_t = t
        a = prev_t if (prev_t is not None and prev_t < t) else t
        if a >= t:                       # no preceding gap -> all in window(t)
            self._add_stall(w, stalls, 1.0)
            return
        span = t - a
        for ww in range(int(a // self.W), int((t - 1) // self.W) + 1):
            lo = max(a, ww * self.W)
            hi = min(t, (ww + 1) * self.W)
            if hi > lo:
                self._add_stall(ww, stalls, (hi - lo) / span)

    def emit(self, builder, ctr_uuid, pin=True):
        # Perfetto counters are sample-and-hold, so emit a value only when it
        # CHANGES (idle stretches collapse to a single 0 point). The first and
        # last active windows are always emitted to bound the track.
        if self.first is None:
            return
        cyc_per_win = self.W / self.clk
        zero = {s: 0.0 for s in STALLS}
        last_val = {m: None for m in METRICS}
        for w in range(self.first, self.last + 1):
            ts = w * self.W
            # IPC = retirements / active cycles; the trailing window is
            # partial.
            if w == self.last and self.last_t is not None:
                cyc = max(1.0, (self.last_t - ts) / self.clk)
            else:
                cyc = cyc_per_win
            st = self.stall.get(w, zero)
            # CPI-stack as PER-CYCLE fractions so IPC + stalls == 1 while busy.
            # The raw .dasm stall_* OVERLAP (one stall is charged to several
            # bursting instructions), so summed they can exceed the
            # non-retiring budget (1 - IPC); we cap the components into that
            # budget (preserving their ratio) and stall_tot is their sum.
            # IPC + stall_tot == 1 when busy, < 1 only when genuinely idle.
            ipc = self.count.get(w, 0) / cyc
            nonretire = max(0.0, 1.0 - ipc)
            raw = sum(st[s] for s in STALL_COMPONENTS) / \
                cyc     # measured stall frac (may overlap)
            scale = (nonretire / raw) if raw > nonretire else 1.0
            vals = {"IPC": ipc}
            tot = 0.0
            for s in STALL_COMPONENTS:
                f = (st[s] / cyc) * scale
                vals[s] = f
                tot += f
            vals["stall_tot"] = tot
            force = (w == self.first or w == self.last)
            for m in METRICS:
                if force or vals[m] != last_val[m]:
                    emit_counter(builder, ts, ctr_uuid[m], vals[m])
                    last_val[m] = vals[m]
        # Drop to 0 one window past the last active window so a finished core's
        # final value doesn't sample-and-hold across the idle tail.
        ts_end = (self.last + 1) * self.W
        for m in METRICS:
            if last_val[m]:
                emit_counter(builder, ts_end, ctr_uuid[m], 0.0)
        # Pin every metric's y-axis to [0,1] (1.0 blip past the data).
        if pin:
            pin_counter_range(
                builder,
                ctr_uuid.values(),
                ts_end + 2 * self.clk,
                self.clk)


def hart_to_gtc(hart, cores_per_tile, tiles_per_group):
    cores_per_group = cores_per_tile * tiles_per_group
    g = hart // cores_per_group
    within = hart % cores_per_group
    return g, within // cores_per_tile, within % cores_per_tile


def collect_pcs(path):
    """Cheap first pass over the RAW .dasm: just the PC column (for
    addr2line)."""
    pcs = set()
    with open(path, "r", errors="replace") as f:
        for line in f:
            m = LINE_RE.match(line)
            if m:
                pcs.add(int(m.group(3), 16))
    return pcs


def line_iter(path, spike_dasm, want_disasm):
    """Stream lines (O(1) memory): raw, or piped through spike-dasm for
    disasm."""
    if want_disasm and spike_dasm:
        proc = subprocess.Popen([spike_dasm], stdin=open(path, "r"),
                                stdout=subprocess.PIPE, text=True,
                                errors="replace")
        try:
            for line in proc.stdout:
                yield line
        finally:
            proc.stdout.close()
            proc.wait()
    else:
        with open(path, "r", errors="replace") as f:
            for line in f:
                yield line


def process_dasm(path, hart, builder, uu, args, a2l, pe_data=None, flows=None):
    g, t, c = hart_to_gtc(hart, args.cores_per_tile, args.tiles_per_group)
    want_disasm = (args.slices == "instruction")
    want_slices = (args.slices != "none")
    # marker names are needed even in counters-only mode when filtering
    need_names = want_slices or args.filter_benchmark

    # --- Core › group / tile / core track tree (deduped by Uuids._seen) ---
    # "Core" is a top-level root mirroring the "NoC routers"/"NoC tiles" roots.
    core_root = uu.get(("core_root",))
    if ("core_root",) not in uu._seen:
        add_track(builder, core_root, "1 Core")
        uu._seen.add(("core_root",))
    g_uuid = uu.get(("g", g))
    if ("g", g) not in uu._seen:
        add_track(builder, g_uuid, _gname(g), parent=core_root)
        uu._seen.add(("g", g))
    t_uuid = uu.get(("t", g, t))
    if ("t", g, t) not in uu._seen:
        add_track(builder, t_uuid, _tname(t), parent=g_uuid)
        uu._seen.add(("t", g, t))
    # EXPLICIT child ordering so the stat counters and the PE port-traffic
    # tracks don't interleave (default lexicographic sort would slot req/resp
    # between IPC and stall_*). Counters first (rank 0..), traffic last.
    core_uuid = uu.get(("c", hart))
    add_track(
        builder,
        core_uuid,
        f"Core {hart:0{PAD_H}d} (G{g}T{t}C{c})",
        parent=t_uuid,
        child_order=CHILD_ORDER_EXPLICIT)
    ctr_uuid = {
        name: add_track(
            builder,
            uu.get(
                ("ctr",
                 hart,
                 name)),
            name,
            parent=core_uuid,
            counter=True,
            order_rank=i) for i,
        name in enumerate(METRICS)}

    # PE (Snitch core) data-port traffic as expandable child tracks of the Core
    # node, beside IPC/stalls. No bw/util for PE ports (traffic); req shows
    # read/write/stall, resp shows hsk/stall, idle = grey gaps. --noc-slices
    # packet shows one slice per load/store with its address.
    pe = pe_data.get((g, t, c)) if pe_data else None
    if pe:
        pe_runs, pe_pkts = pe
        for j, (rr, io, port) in enumerate(sorted(pe_runs)):
            label = ("req" if rr == 0 else "resp") + \
                (f" {port}" if port else "")
            leaf = add_track(
                builder,
                uu.get(
                    ("pe",
                     hart,
                     rr,
                     io,
                     port)),
                label,
                parent=core_uuid,
                order_rank=len(METRICS) +
                j)
            if args.noc_slices == "packet" and rr == 0 and (
                    io, port) in pe_pkts:
                _emit_req_packet_slices(
                    pe_runs[(rr, io, port)], pe_pkts[(io, port)],
                    leaf, rr, builder, args, pe=True, flows=flows,
                    req_ctx=(g, t, c), flow_rank=0)
            elif (flows and args.noc_slices == "packet" and rr == 1
                  and (io, port) in pe_pkts):
                _emit_pe_resp_packets(pe_runs[(rr, io, port)], pe_pkts[(
                    io, port)], leaf, builder, args, flows, (g, t, c))
            else:
                _emit_state_slices(
                    pe_runs[(rr, io, port)], leaf, rr, builder, args)

    if need_names:
        a2l.resolve(collect_pcs(path))

    # counter bucket (cycles)
    win_cyc = max(1, int(round(args.window_ns / args.clk_ns)))
    acc = WindowAcc(win_cyc * TICK, TICK)
    cur_func = None          # name of the open function slice (None = closed)
    instr_open = False
    in_bench = not args.filter_benchmark
    prev_t = None
    last_t = None

    def close_instr(ts):
        nonlocal instr_open
        if instr_open:
            emit_slice_end(builder, ts, core_uuid)
            instr_open = False

    def close_func(ts):
        nonlocal cur_func
        close_instr(ts)
        if cur_func is not None:
            emit_slice_end(builder, ts, core_uuid)
            cur_func = None

    for line in line_iter(path, args.spike_dasm, want_disasm):
        m = LINE_RE.match(line)
        if not m:
            continue
        cyc = m.group(2)
        cyc_n = int(cyc)
        # core lane on the same cycle axis as traffic lanes
        time_ns = cyc_n * TICK
        if cyc_n < WIN_CYC_LO:           # before the export window -> skip
            prev_t = None  # don't bridge stalls across the window start
            continue
        # past it (dasm is time-ordered) -> close + stop
        if cyc_n >= WIN_CYC_HI:
            close_func(time_ns)
            break
        pc = int(m.group(3), 16)
        func, src, inl = a2l.get(pc) if need_names else ("", "", "")

        if args.filter_benchmark:
            if func == BENCH_START:
                in_bench = True
                prev_t = None        # don't bridge stalls across the boundary
                continue
            if func == BENCH_STOP:
                in_bench = False
                close_func(time_ns)
                continue
        if not in_bench:
            continue

        ex = dict(FIELD_RE.findall(m.group(5)))
        stalls = {s: int(ex.get(s, "0x0"), 16) for s in STALLS}
        acc.add(prev_t, time_ns, stalls)
        prev_t = last_t = time_ns

        if want_slices:
            if func != cur_func:
                close_func(time_ns)
                label = func if func and func != "??" else os.path.basename(
                    src)
                emit_slice_begin(builder, time_ns, core_uuid, label or "??",
                                 annos=[("source", src), ("cyc", cyc)])
                cur_func = func
            if want_disasm:
                close_instr(time_ns)
                instr = m.group(4).strip()
                emit_slice_begin(builder, time_ns, core_uuid, instr or "?",
                                 annos=[("pc", f"0x{pc:08x}"), ("source", src),
                                        ("cyc", cyc), ("inline", inl)])
                instr_open = True

    acc.emit(builder, ctr_uuid, pin=not args.free_range)
    close_func((last_t + TICK) if last_t is not None else 0)
    return g, t, c


def detect_elf(files):
    """Look for PRELOAD=<elf> in the build dir's transcript (next to
    traces)."""
    seen = set()
    for f in files:
        d = os.path.dirname(os.path.abspath(f))
        if d in seen:
            continue
        seen.add(d)
        tr = os.path.join(d, "transcript")
        if os.path.isfile(tr):
            with open(tr, "r", errors="replace") as fh:
                m = re.search(r"PRELOAD=(\S+)", fh.read())
                if m and os.path.isfile(m.group(1)):
                    return m.group(1)
    return None


def find_tool(explicit, names):
    if explicit:
        return explicit
    from shutil import which
    here = os.path.dirname(os.path.abspath(__file__))
    roots = [os.path.join(here, "..", "..", "install", "riscv-gcc", "bin"),
             os.path.join(here, "..", "..", "install", "riscv-isa-sim", "bin")]
    for r in roots:
        for nm in names:
            cand = os.path.join(r, nm)
            if os.path.isfile(cand):
                return cand
    for nm in names:  # fall back to PATH
        if which(nm):
            return which(nm)
    return None


# ---------------------------------------------------------------------------
# NoC interconnect: derived ENTIRELY from the per-router / per-tile full logs
# (router_g*_<req|resp>.log, tile_g*_t*.log -- one file per router and per
# tile). Each file carries BOTH the state runs (S lines) and the per-request
# packet detail (P lines); --noc-slices picks the granularity at export, like
# the core --slices function|instruction. Two trees ("NoC routers", "NoC
# tiles"): each per-port node carries its util/throughput/stall counters SIDE
# BY SIDE with that port's traffic slices. state 0=idle 1=stall 2=hsk/read
# 3=hsk-write. Idle is DROPPED so the gap renders as Perfetto's neutral grey
# (the protobuf has no per-slice color field).
# ---------------------------------------------------------------------------
NOC_NET = {0: "REQ", 1: "RESP"}
NOC_PORTIDX = {0: "N", 1: "E", 2: "S", 3: "W", 4: "local"}
NOC_IO = {0: "in", 1: "out"}
# Per-port-side stats, per-cycle fractions of the window:
#   bw [flit/cyc] = handshakes/win ; stall [cyc/cyc] = stalled/win ;
#   util = (handshakes+stalled)/win = bw+stall (idle = 1-util).
NOC_PORT_METRICS = ["util", "bw [flit/cyc]", "stall [cyc/cyc]"]


def noc_state_name(rr, st):
    """Slice name (Perfetto colors by name)."""
    if st == 0:
        return "idle"
    if st == 1:
        return "stall"
    if rr == 1:                              # resp ports: no read/write split
        return "hsk"
    return "read" if st == 2 else "write"    # req ports


# merged: one file per group
ROUTER_LOG_RE = re.compile(r"router_g(\d+)_(req|resp)\.log$")
TILE_LOG_RE = re.compile(r"tile_g(\d+)_t(\d+)\.log$")
# merged: one file per tile (core in line)
PE_LOG_RE = re.compile(r"pe_g(\d+)_t(\d+)\.log$")
SPM_BANK_LOG_RE = re.compile(r"bank_g(\d+)_t(\d+)\.log$")


def load_spm_bank_logs(spm_dir):
    """Glob per-tile SPM bank logs (bank_g<g>_t<t>.log; one per tile, all its
    banks). Returns {(g,t): (runs, packets)}: S line = bank start end state
    (0=idle 1=stall 2=read 3=write); P line =
    bank cyc wen addr loc wide port sg it core meta_id (each granted access).
    loc=1 if a local input port won, wide=1 for a DMA access, port=winning
    arbiter input-port index, sg/it/core=remote NoC origin."""
    out = {}
    for path in glob.glob(os.path.join(spm_dir, "bank_g*_t*.log")):
        m = SPM_BANK_LOG_RE.search(os.path.basename(path))
        if not m:
            continue
        key = (int(m.group(1)), int(m.group(2)))
        runs, packets = out.setdefault(key, ({}, {}))
        with open(path, "r", errors="replace") as f:
            for line in f:
                x = line.split()
                if len(
                        x) == 5 and x[0] == "S":  # S bank start end state
                    try:
                        bank, s, e, st = int(
                            x[1]), int(
                            x[2]), int(
                            x[3]), int(
                            x[4])
                    except ValueError:
                        continue
                    w = _winclip(s, e)
                    if w:
                        runs.setdefault(bank, []).append((w[0], w[1], st))
                # P bank cyc wen addr loc wide port sg it core meta_id
                elif len(x) == 12 and x[0] == "P":
                    try:
                        bank = int(x[1])
                        rec = [
                            int(
                                x[2]), int(
                                x[3]), int(
                                x[4], 16), int(
                                x[5]), int(
                                x[6]), int(
                                x[7]), int(
                                x[8]), int(
                                    x[9]), int(
                                        x[10]), int(
                                            x[11])]
                    except ValueError:
                        continue
                    if not (WIN_CYC_LO <= rec[0] < WIN_CYC_HI):
                        continue
                    packets.setdefault(bank, []).append(rec)
    return out


def load_pe_logs(noc_dir):
    """Glob the MERGED per-tile core-port logs -> {(g,t,c): (runs, packets)}.
    pe_g<g>_t<t>.log is one file PER TILE with every line PREFIXED by its core
    index (idx), so idx is read from the line, not the filename.
      runs[(rr,io,port)] = [(s,e,st)]                                 (S lines)
      packets[(io,port)] : req (io=1) [[cyc,wen,addr,meta_id]]
                           resp (io=0) [[cyc,meta_id]]                (P lines)
    The trailing meta_id ties each packet to its originating request."""
    out = {}
    for path in glob.glob(os.path.join(noc_dir, "pe_g*_t*.log")):
        m = PE_LOG_RE.search(os.path.basename(path))
        if not m:
            continue
        g, t = int(m.group(1)), int(m.group(2))
        with open(path, "r", errors="replace") as f:
            for line in f:
                x = line.split()
                if len(x) < 2:
                    continue
                try:
                    # leading demux index = core / port
                    idx = int(x[0])
                except ValueError:
                    continue
                # the rest is the original S/P line
                x = x[1:]
                runs, packets = out.setdefault((g, t, idx), ({}, {}))
                # S rr io port start end state
                if len(x) == 7 and x[0] == "S":
                    try:
                        rr, io, port, s, e, st = (int(z) for z in x[1:])
                    except ValueError:
                        continue
                    w = _winclip(s, e)
                    if w:
                        runs.setdefault(
                            (rr, io, port), []).append(
                            (w[0], w[1], st))
                # REQ: P io port cyc wen addr meta_id
                elif len(x) == 7 and x[0] == "P":
                    try:
                        io, port, cyc, wen = int(
                            x[1]), int(
                            x[2]), int(
                            x[3]), int(
                            x[4])
                        if not (WIN_CYC_LO <= cyc < WIN_CYC_HI):
                            continue
                        packets.setdefault((io, port), []).append(
                            [cyc, wen, int(x[5], 16), int(x[6])])
                    except ValueError:
                        continue
                # RESP: P io port cyc meta_id
                elif len(x) == 5 and x[0] == "P":
                    try:
                        io, port, cyc, mid = int(
                            x[1]), int(
                            x[2]), int(
                            x[3]), int(
                            x[4])
                        if not (WIN_CYC_LO <= cyc < WIN_CYC_HI):
                            continue
                        packets.setdefault((io, port), []).append([cyc, mid])
                    except ValueError:
                        continue
    return out


def load_noc_router_logs(noc_dir):
    """Glob the per-router full logs. `rid` is a flat router id within the
    group (NOT tile/port -- the remapper shuffles the tile<->router
    assignment), read from the line prefix. Returns:
      runs[(g,rid,rr,pi,io)] = [(start,end,state)]   (from S lines)
      packets[(g,rid,rr,pi,io)] (P lines):
        req:  [[cyc,wen,addr,dstx,dsty,srcx,srcy,src_tile,core,meta_id]]
        resp: [[cyc,dstx,dsty,srcx,srcy,req_tile,req_core,meta_id]]
    Resp flits have no tgt_addr; dst_id is the requester they return to, src_id
    the responder. The trailing meta_id is the per-request correlation id."""
    runs, packets = {}, {}
    for path in glob.glob(os.path.join(noc_dir, "router_g*_*.log")):
        m = ROUTER_LOG_RE.search(os.path.basename(path))
        if not m:  # skip tile_/pe_/... that also match the glob
            continue
        g = int(m.group(1))
        rr = 0 if m.group(2) == "req" else 1
        with open(path, "r", errors="replace") as f:
            for line in f:
                x = line.split()
                if len(x) < 2:
                    continue
                try:
                    # leading demux index = in-group router id
                    rid = int(x[0])
                except ValueError:
                    continue
                # the rest is the original S/P line
                x = x[1:]
                # S portidx io start end state
                if len(x) == 6 and x[0] == "S":
                    try:
                        pi, io, s, e, st = (int(z) for z in x[1:])
                    except ValueError:
                        continue
                    w = _winclip(s, e)
                    if w:
                        runs.setdefault(
                            (g, rid, rr, pi, io), []).append(
                            (w[0], w[1], st))
                # REQ: pi io cyc wen addr dstx dsty srcx srcy stile core mid
                elif len(x) == 13 and x[0] == "P":
                    try:
                        pi, io, cyc, wen = int(
                            x[1]), int(
                            x[2]), int(
                            x[3]), int(
                            x[4])
                        if not (WIN_CYC_LO <= cyc < WIN_CYC_HI):
                            continue
                        rec = [
                            cyc, wen, int(
                                x[5], 16), int(
                                x[6]), int(
                                x[7]), int(
                                x[8]), int(
                                x[9]), int(
                                x[10]), int(
                                x[11]), int(
                                    x[12])]
                    except ValueError:
                        continue
                    packets.setdefault((g, rid, rr, pi, io), []).append(rec)
                # RESP: pi io cyc dstx dsty srcx srcy rtile rcore mid
                elif len(x) == 11 and x[0] == "P":
                    try:
                        pi, io, cyc = int(x[1]), int(x[2]), int(x[3])
                        if not (WIN_CYC_LO <= cyc < WIN_CYC_HI):
                            continue
                        rec = [
                            cyc, int(
                                x[4]), int(
                                x[5]), int(
                                x[6]), int(
                                x[7]), int(
                                x[8]), int(
                                x[9]), int(
                                x[10])]
                    except ValueError:
                        continue
                    packets.setdefault((g, rid, rr, pi, io), []).append(rec)
    return runs, packets


def load_noc_tile_logs(noc_dir):
    """Glob the per-tile full logs (tile_g<g>_t<t>.log). Returns (runs,
    packets):
      runs[(g,t,rr,io,p)] = [(start,end,state)]   (S lines)
      req  (P): [[cyc,wen,addr,src_grp,dst_grp,req_tile,req_core,meta_id]]
      resp (Q): [[cyc,srcvalid,src_grp,dst_grp,req_tile,req_core,meta_id]]
    Resp Q lines have no addr/wen; srcvalid=0 (master_resp, in) = responder
    group unknown so only dst (x,y); srcvalid=1 (slave_resp, out) has both
    src and dst (x,y) (linear groups)."""
    runs, packets = {}, {}
    for path in glob.glob(os.path.join(noc_dir, "tile_g*_t*.log")):
        m = TILE_LOG_RE.search(os.path.basename(path))
        if not m:
            continue
        g, t = int(m.group(1)), int(m.group(2))
        with open(path, "r", errors="replace") as f:
            for line in f:
                x = line.split()
                # S rr io port start end state
                if len(x) == 7 and x[0] == "S":
                    try:
                        rr, io, p, s, e, st = (int(z) for z in x[1:])
                    except ValueError:
                        continue
                    w = _winclip(s, e)
                    if w:
                        runs.setdefault(
                            (g, t, rr, io, p), []).append(
                            (w[0], w[1], st))
                # REQ: io port cyc wen addr sgrp dgrp rtile rcore mid
                elif len(x) == 11 and x[0] == "P":
                    try:
                        io, p, cyc, wen = int(
                            x[1]), int(
                            x[2]), int(
                            x[3]), int(
                            x[4])
                        if not (WIN_CYC_LO <= cyc < WIN_CYC_HI):
                            continue
                        rec = [
                            cyc, wen, int(
                                x[5], 16), int(
                                x[6]), int(
                                x[7]), int(
                                x[8]), int(
                                x[9]), int(
                                x[10])]
                    except ValueError:
                        continue
                    packets.setdefault((g, t, 0, io, p), []).append(rec)
                # RESP: io port cyc srcvalid sgrp dgrp rtile rcore mid
                elif len(x) == 10 and x[0] == "Q":
                    try:
                        io, p, cyc = int(x[1]), int(x[2]), int(x[3])
                        if not (WIN_CYC_LO <= cyc < WIN_CYC_HI):
                            continue
                        rec = [
                            cyc, int(
                                x[4]), int(
                                x[5]), int(
                                x[6]), int(
                                x[7]), int(
                                x[8]), int(
                                x[9])]
                    except ValueError:
                        continue
                    packets.setdefault((g, t, 1, io, p), []).append(rec)
    return runs, packets


class Flows:
    """Transaction correlation across every packet trace, via (requester,
    meta_id).

    For a reorder-buffered requester (the Snitch load/store port) meta_id is
    unique among that requester's OUTSTANDING requests and carried unchanged
    end-to-end, so per (requester, meta_id) the req/resp pairs are strictly
    ordered (a meta_id cannot be reused until its response returns), even
    though responses across DIFFERENT meta_ids may return out of order (NUMA).
    So we segment each (group, tile, core idx, meta_id) timeline into
    non-overlapping [req_cyc, resp_cyc] intervals (k-th req pairs with k-th
    resp), each given a unique Perfetto flow_id. Any packet carrying that
    requester+meta_id inside the interval binds to the flow.

    NOT every requester reorders: an in-order requester may reuse one meta_id
    for many concurrently-outstanding requests (a stream tag, not a unique id),
    and the interconnect re-derives the address at each hop, so no key spans
    the path. We auto-detect such buckets (overlapping outstanding) and leave
    them UNFLOWED -- their packets keep annotations, just no arrows.

    The local-port idx is the core_id space ([0,cpt) Snitch cores)."""

    INF = float("inf")

    def __init__(self, pe_data):
        # (g,t,idx) -> {meta_id: (req_cyc list, resp_cyc list, [(rc,sc,fid)])}
        self.ix = {}
        # (g,t,idx,meta_id) buckets that are in-order streams (no flows)
        self.streams = set()
        # flow ids start at 1 (0 is "no flow" for Perfetto)
        self._next = 1
        self.n_txn = self.n_inflight = self.n_orphan_resp = self.n_stream = 0
        self.bound = self.unbound = self.stream_pkts = 0
        self._build(pe_data or {}, 0)

    def _build(self, data, base):
        for (g, t, sub), (_runs, pkts) in data.items():
            idx = base + sub
            req_by_m = collections.defaultdict(list)
            resp_by_m = collections.defaultdict(list)
            for rec in pkts.get((1, 0), []):     # req  [cyc,wen,addr,meta_id]
                req_by_m[rec[3]].append(rec[0])
            for rec in pkts.get((0, 0), []):     # resp [cyc,meta_id]
                resp_by_m[rec[1]].append(rec[0])
            d = {}
            for m, rc in req_by_m.items():
                rcs = sorted(rc)
                resp = sorted(resp_by_m.get(m, []))
                scs = [
                    resp[k] if k < len(resp) else self.INF for k in range(
                        len(rcs))]
                # In-order STREAM detection: a request issued before the
                # previous response of the same (requester, meta_id) returned
                # => >1 concurrent outstanding => meta_id is reused as a stream
                # tag, not a unique reorder id. Such a bucket has no
                # per-request identity to follow (and the address is re-derived
                # per hop), so we do NOT fabricate flows -- its packets keep
                # annotations, no arrows. Loads keep a unique meta_id per
                # outstanding, so they never trip this.
                if any(rcs[k + 1] < scs[k] for k in range(len(rcs) - 1)):
                    self.streams.add((g, t, idx, m))
                    self.n_stream += len(rcs)
                    continue
                ivs = []
                for k, rcyc in enumerate(rcs):
                    ivs.append((rcyc, scs[k], self._next))
                    self._next += 1
                    if scs[k] is self.INF:
                        self.n_inflight += 1
                self.n_txn += len(rcs)
                if len(resp) > len(
                        rcs):         # resp with no preceding req (trace edge)
                    self.n_orphan_resp += len(resp) - len(rcs)
                # intervals are non-overlapping and ordered, so the resp-cyc
                # list can be bisected directly; inf (in-flight) sorts last.
                d[m] = (rcs, [iv[1] for iv in ivs], ivs)
            self.ix[(g, t, idx)] = d

    def fid(self, g, t, idx, meta_id, cyc, is_resp=False):
        """Resolve the flow_id for a packet at `cyc` carrying (requester,
        meta_id). Intervals share boundaries when a meta_id is reused
        immediately, so disambiguate by direction: a request-side packet binds
        to the latest interval whose req has started (req_cyc <= cyc); a
        response-side packet to the earliest interval whose resp ends at/after
        cyc. Bounds are EXACT and no slack is allowed, else a 1-cycle gap
        between back-to-back transactions would pull a packet into the wrong
        flow. Returns None (counted unbound) if cyc lands in no interval;
        in-order stream buckets are deliberately not flowed."""
        # in-order stream: keep annotations, no arrows
        if (g, t, idx, meta_id) in self.streams:
            self.stream_pkts += 1
            return None
        ent = self.ix.get((g, t, idx), _EMPTY).get(meta_id)
        if ent:
            rcs, scs, ivs = ent
            i = bisect.bisect_left(
                scs, cyc) if is_resp else bisect.bisect_right(
                rcs, cyc) - 1
            if 0 <= i < len(ivs):
                rcyc, scyc, fid = ivs[i]
                if rcyc <= cyc <= scyc:
                    self.bound += 1
                    return fid
        self.unbound += 1
        return None

    def report(self):
        return (f"  flows: {self.n_txn} transactions / "
                f"{self._next - 1} flow ids; "
                f"{self.bound} packet-hops bound, {self.unbound} unbound "
                f"(DMA/uncorrelated), "
                f"{self.stream_pkts} in in-order streams (annotated, not "
                f"flowed: "
                f"{len(self.streams)} streams / {self.n_stream} txns); "
                f"{self.n_inflight} in-flight at EOS, {self.n_orphan_resp} "
                f"orphan resp")


_EMPTY = {}


def _ensure(builder, uu, key, name, parent_key=None):
    """Idempotent container track (deduped via uu._seen). Returns its uuid."""
    if key not in uu._seen:
        parent = uu.get(parent_key) if parent_key is not None else None
        add_track(builder, uu.get(key), name, parent=parent)
        uu._seen.add(key)
    return uu.get(key)


def _emit_state_slices(rl, leaf, rr, builder, args, only=None):
    """One colored slice per non-idle run. Idle (st==0) is DROPPED so the gap
    renders as Perfetto's neutral grey (the protobuf has no per-slice color
    field). `only` (a set of state codes) restricts which states are drawn --
    packet mode passes {1} to keep the stall runs. Returns #emitted."""
    n = 0
    for s, e, st in sorted(rl):
        if st == 0:                              # idle -> leave a grey gap
            continue
        if only is not None and st not in only:
            continue
        emit_slice_begin(builder, s * TICK, leaf, noc_state_name(rr, st))
        emit_slice_end(builder, e * TICK, leaf)
        n += 1
    return n


def _req_eng(core, cpt):
    """Render an originating local-port id as a core (C{core})."""
    return f"C{core}"


def _emit_req_packet_slices(
        rl,
        recs,
        leaf,
        rr,
        builder,
        args,
        is_router=True,
        pe=False,
        show_xy=True,
        is_resp=False,
        flows=None,
        req_ctx=None,
        flow_rank=0):
    """Packet granularity for a REQUEST port: per-request read/write slices
    (address + routing on hover) MERGED with the stall runs and emitted in
    start-time order. Merging is REQUIRED: stall and packet slices share
    boundary timestamps, and two separate passes make Perfetto's timestamp sort
    nest the stall INSIDE the just-closed packet (a malformed marker arrow).
    Every NoC packet is annotated with src (x,y), dst (x,y), and the
    originating requester as a LINEAR G<group> T<tile> C<port>. Layout:
      router req =[cyc,wen,addr,dstx,dsty,srcx,srcy,src_tile,core,meta_id]
      router resp=[cyc,dstx,dsty,srcx,srcy,req_tile,req_core,meta_id] (is_resp)
      tile req =[cyc,wen,addr,src_grp,dst_grp,req_tile,req_core,meta_id]
      tile resp  =[cyc,srcvalid,src_grp,dst_grp,req_tile,req_core,meta_id]
      pe    =[cyc,wen,addr,meta_id]  (meta_id is rec[-1] in every layout)
    A RESPONSE flit carries no address; src=responder, dst=the requester it
    returns to."""
    ny = args.mesh_y
    cpt = args.cores_per_tile
    # items carry a 5th field = flow_id (None for stall runs and when --flows
    # is off). The requester key (group,tile,idx) is read straight from the
    # packet's own fields, so every hop binds independently.
    items = [(s, e, "stall", None, None) for s, e, st in rl if st == 1]
    for rec in recs:
        mid = rec[-1]
        # ROUTER resp flit: no addr; src=responder, dst=requester
        if is_resp and is_router:
            cyc, dstx, dsty, srcx, srcy, tile, core = rec[:7]
            annos = [("src (x,y)", f"({srcx},{srcy})"),
                     ("dst (x,y)", f"({dstx},{dsty})"),
                     ("requester",
                      f"G{dstx * ny + dsty} T{tile} {_req_eng(core, cpt)}"),
                     ("meta_id", str(mid)), ("op", "resp")]
            fid = flows.fid(dstx * ny + dsty, tile, core, mid,
                            cyc, is_resp=True) if flows else None
            items.append((cyc, cyc + 1, "resp", annos, fid))
            continue
        # TILE resp: src/dst are linear groups (src only if srcvalid)
        if is_resp:
            cyc, srcvalid, src_grp, dst_grp, req_tile, core = rec[:6]
            annos = []
            # local port (show_xy=False) hides both
            if show_xy:
                # master_resp (srcvalid=0): responder group unknown
                if srcvalid:
                    annos.append(
                        ("src (x,y)", f"({src_grp // ny},{src_grp % ny})"))
                annos.append(
                    ("dst (x,y)", f"({dst_grp // ny},{dst_grp % ny})"))
            annos += [("requester",
                       f"G{dst_grp} T{req_tile} {_req_eng(core, cpt)}"),
                      ("meta_id",
                       str(mid)),
                      ("op",
                       "resp")]
            fid = flows.fid(dst_grp, req_tile, core, mid, cyc,
                            is_resp=True) if flows else None
            items.append((cyc, cyc + 1, "resp", annos, fid))
            continue
        cyc, wen, addr = rec[0], rec[1], rec[2]
        op = "write" if wen else "read"
        # requester is the port itself (req_ctx)
        if pe:
            annos = [("addr", f"0x{addr:x}"), ("op", op)]
            rg, rt, ridx = req_ctx
        # src/dst already mesh (x,y)
        elif is_router:
            dstx, dsty, srcx, srcy, src_tile, core = rec[3:9]
            annos = [("addr", f"0x{addr:x}"),
                     ("src (x,y)", f"({srcx},{srcy})"),
                     ("dst (x,y)", f"({dstx},{dsty})"),
                     ("requester",
                     f"G{srcx * ny + srcy} T{src_tile} {_req_eng(core, cpt)}"),
                     ("op", op)]
            rg, rt, ridx = srcx * ny + srcy, src_tile, core
        # tile: src/dst groups linear -> mesh (x,y)
        else:
            src_grp, dst_grp, req_tile, core = rec[3:7]
            annos = [("addr", f"0x{addr:x}")]
            # local port stays in-group: src/dst (x,y) is redundant
            if show_xy:
                annos += [("src (x,y)", f"({src_grp // ny},{src_grp % ny})"),
                          ("dst (x,y)", f"({dst_grp // ny},{dst_grp % ny})")]
            annos += [("requester",
                       f"G{src_grp} T{req_tile} {_req_eng(core, cpt)}"),
                      ("op", op)]
            rg, rt, ridx = src_grp, req_tile, core
        annos.append(("meta_id", str(mid)))
        fid = flows.fid(rg, rt, ridx, mid, cyc) if flows else None
        items.append((cyc, cyc + 1, op, annos, fid))
    for s, e, name, annos, fid in sorted(
            items, key=lambda x: x[0]):  # start-time order (starts unique)
        emit_slice_begin(
            builder,
            s * TICK,
            leaf,
            name,
            annos,
            flow_id=fid,
            rank=flow_rank)
        emit_slice_end(builder, e * TICK, leaf)
    return len(items)


def _emit_port(
        builder,
        uu,
        leaf_key,
        leaf_name,
        parent_key,
        rl,
        rr,
        win,
        args,
        pkts=None,
        is_router=True,
        show_xy=True,
        is_resp=False,
        flows=None,
        flow_rank=0):
    """One NoC port-side, laid out like a Core: the traffic state slices are
    drawn ON the port's own line, and its statistics hang under it as
    expandable counter children, computed INDIVIDUALLY for this port-side,
    windowed, as PER-CYCLE fractions (bw = handshake/win, stall = stalled/win,
    util = (handshake+stalled)/win = bw+stall). Returns #traffic slices."""
    import collections
    leaf = add_track(
        builder,
        uu.get(leaf_key),
        leaf_name,
        parent=uu.get(parent_key))
    ctr = {m: add_track(builder, uu.get(leaf_key + (m,)), m,
                        parent=leaf, counter=True) for m in NOC_PORT_METRICS}
    # state granularity (default)
    if pkts is None:
        nsl = _emit_state_slices(rl, leaf, rr, builder, args)
    # packet granularity (request port):
    else:
        nsl = _emit_req_packet_slices(
            rl,
            pkts,
            leaf,
            rr,
            builder,
            args,
            is_router=is_router,
            show_xy=show_xy,
            is_resp=is_resp,
            flows=flows,
            flow_rank=flow_rank)
    # NOTE: stats below are ALWAYS derived from the state runs (rl),
    # independent of slice granularity.
    # window -> [handshake_cyc, stall_cyc]
    acc = collections.defaultdict(lambda: [0, 0])
    maxw = -1
    for s, e, st in rl:
        if st == 0:                                  # idle adds nothing
            continue
        w = s // win
        while w * win < e:
            d = min(e, (w + 1) * win) - max(s, w * win)
            # st>=2 handshake (read/write/hsk), st==1 stall
            acc[w][0 if st >= 2 else 1] += d
            if w > maxw:
                maxw = w
            w += 1
    # change-detected emit (sample-and-hold)
    last = {}
    for w in range(maxw + 1):
        ts = w * win * TICK
        hsk, stall = acc.get(w, (0, 0))
        for m, val in (("bw [flit/cyc]", hsk / win),
                       ("stall [cyc/cyc]", stall / win),
                       ("util", (hsk + stall) / win)):
            if last.get(m) != val:
                emit_counter(builder, ts, ctr[m], val)
                last[m] = val
    # Drop to 0 one window past the last active window, else sample-and-hold
    # smears the last value across the idle tail.
    if maxw >= 0:
        ts_close = (maxw + 1) * win * TICK
        for m in NOC_PORT_METRICS:
            if last.get(m):
                emit_counter(builder, ts_close, ctr[m], 0.0)
    else:  # fully-idle port: one 0 baseline at t0
        for m in NOC_PORT_METRICS:
            emit_counter(builder, 0, ctr[m], 0.0)
    # Pin every counter's y-axis to [0,1] with a blip at the end of the
    # timeline (all ports share the flush cycle, so it sits at the far right).
    if not args.free_range:
        pin_counter_range(
            builder, ctr.values(), max(
                e for _, e, _ in rl) * TICK, TICK)
    return nsl


def _emit_pe_resp_packets(rl, recs, leaf, builder, args, flows, req_ctx):
    """The originating port's RESPONSE side as per-packet slices
    (rec=[cyc,meta_id]), merged with stall runs. Each response is the LAST hop
    of its transaction, so it carries the flow's terminating arrow (no dangling
    outgoing flow). It is emitted in pipeline order AFTER the same-cycle
    router-resp-out and tile-resp-in (rank 3), so insertion-order tie-break
    makes it uniquely the LAST slice of its flow."""
    g, t, idx = req_ctx
    items = [(s, e, "stall", None, None, False) for s, e, st in rl if st == 1]
    for cyc, mid in recs:
        fid = flows.fid(g, t, idx, mid, cyc, is_resp=True) if flows else None
        items.append((cyc, cyc + 1, "resp",
                     [("meta_id", str(mid)), ("op", "resp")],
                     fid, fid is not None))
    for s, e, name, annos, fid, term in sorted(items, key=lambda x: x[0]):
        emit_slice_begin(
            builder,
            s * TICK,
            leaf,
            name,
            annos,
            flow_id=fid,
            terminating=term,
            rank=3)  # terminator = sink, last in the cycle
        emit_slice_end(builder, e * TICK, leaf)
    return len(items)


def process_noc_routers(noc_dir, builder, uu, args, flows=None):
    """NoC routers laid out like the core view: one LINE per router port-side
    ({N/E/S/W/local} {in|out}) carrying its traffic slices, with util/bw/stall
    as expandable counter children. Hierarchy: NoC routers > Group > Router >
    port-side line. Routers carry a flat group router id from the file name
    (NOT tile/port -- remapping makes the tile<->router association
    meaningless). Leaves are local-first so the stall-heavy ejection port
    surfaces above the mesh links."""
    runs, packets = load_noc_router_logs(
        noc_dir)        # runs:(g,rid,rr,pi,io)  packets:(g,rid,pi,io)
    if not runs:
        print(
            f"  NoC routers: no router_g*_r*_*.log in {noc_dir}; skipping",
            file=sys.stderr)
        return 0
    win = max(1, int(round(args.window_ns / args.clk_ns)))
    groups = sorted({k[0] for k in runs})
    # zero-pad router id for lexicographic order
    rpad = len(str(max((k[1] for k in runs), default=0)))

    # local (pi=4) first within a router
    def leaf_order(item):
        (g, rid, rr, pi, io), _ = item
        return (g, rid, rr, 0 if pi == 4 else 1, pi, io)

    # packet granularity (chosen at export): per-flit slices on REQUEST
    # (read/write + addr) AND RESPONSE (src/dst + requester) ports.
    packet_mode = args.noc_slices == "packet"

    nsl = nports = 0
    for (g, rid, rr, pi, io), rl in sorted(runs.items(), key=leaf_order):
        _ensure(builder, uu, ("nr",), "3 NoC routers")
        _ensure(builder, uu, ("nr_g", g), _gname(g), ("nr",))
        _ensure(
            builder, uu, ("nr_p", g, rid, rr),
            f"Router {rid:0{rpad}d} {NOC_NET[rr]}", ("nr_g", g))
        pk = packets.get((g, rid, rr, pi, io), []) if packet_mode else None
        nsl += _emit_port(
            builder, uu, ("nr_l", g, rid, rr, pi, io),
            f"{NOC_PORTIDX[pi]} {NOC_IO[io]}", ("nr_p", g, rid, rr),
            rl, rr, win, args, pkts=pk, is_router=True, is_resp=(rr == 1),
            flows=flows,
            flow_rank=(1 if io == 1 else 2))  # out=send(1), in=recv(2)
        nports += 1
    gran = "packet" if packet_mode else "state"
    print(f"  NoC routers: {len(groups)} groups, "
          f"{nports} port-side lines, {nsl} slices "
          f"({gran} granularity; util/bw/stall expandable)")
    return nports


def process_noc_tiles(noc_dir, builder, uu, args, flows=None):
    """NoC tiles laid out like the core view: one LINE per tile port-side
    ({in|out} {local|remoteN}) carrying its traffic slices, with util/bw/stall
    as expandable counter children. Hierarchy: NoC tiles > Group > Tile >
    {REQ|RESP} > port-side line."""
    runs, packets = load_noc_tile_logs(
        noc_dir)          # runs:(g,t,rr,io,p)  packets:(g,t,io,p)
    if not runs:
        print(
            f"  NoC tiles: no tile_g*_t*.log in {noc_dir}; skipping",
            file=sys.stderr)
        return 0
    win = max(1, int(round(args.window_ns / args.clk_ns)))
    groups = sorted({k[0] for k in runs})
    # per-request slices on req ports
    packet_mode = args.noc_slices == "packet"
    nsl = nports = 0
    for (g, t, rr, io, p), rl in sorted(runs.items()):
        _ensure(builder, uu, ("nt",), "2 NoC tiles")
        _ensure(builder, uu, ("nt_g", g), _gname(g), ("nt",))
        _ensure(builder, uu, ("nt_t", g, t), _tname(t), ("nt_g", g))
        _ensure(builder, uu, ("nt_n", g, t, rr), NOC_NET[rr], ("nt_t", g, t))
        leaf_name = f"{NOC_IO[io]} " + ("local" if p == 0 else f"remote{p}")
        pk = packets.get((g, t, rr, io, p), []) if packet_mode else None
        nsl += _emit_port(
            builder, uu, ("nt_l", g, t, rr, io, p), leaf_name,
            ("nt_n", g, t, rr), rl, rr, win, args, pkts=pk,
            is_router=False,
            # tile local port (p==0): in-group, hide src/dst (x,y)
            show_xy=(p != 0),
            # resp ports use the Q-line recs (src/dst + requester + op)
            is_resp=(rr == 1),
            # out=send(1), in=recv(2)
            flows=flows, flow_rank=(1 if io == 1 else 2))
        nports += 1
    gran = "packet" if packet_mode else "state"
    print(f"  NoC tiles: {len(groups)} groups, "
          f"{nports} port-side lines, {nsl} slices "
          f"({gran} granularity; util/bw/stall expandable)")
    return nports


def _emit_bank_packets(rl, recs, leaf, bg, bt, builder, args, flows=None):
    """SPM bank accesses (packet granularity): per-access read/write slice
    (address + the requester that won the bank on hover) merged with the bank's
    stall runs, start-sorted (same anti-nesting reason as
    _emit_req_packet_slices). The requester uses the SAME uniform
    "G<grp> T<tile> C<idx>" format as NoC packets (no local/remote/DMA words):
    a true local input is named by the bank's own (bg,bt) + the winning port
    index, since local requests zero their payload src fields; remote NoC and
    wide DMA carry the origin in sg/it/core. DMA/wide accesses have no core
    flow -> they stay unbound."""
    cpt = args.cores_per_tile

    # (group, tile, local-port idx) + label
    def _req(loc, wide, port, sg, it, core):
        if loc and not wide:                     # this tile's own core port
            return (bg, bt, port), f"G{bg} T{bt} {_req_eng(port, cpt)}"
        return (sg, it, core), f"G{sg} T{it} {_req_eng(core, cpt)}"

    items = [(s, e, "stall", None, None) for s, e, st in rl if st == 1]
    for cyc, wen, addr, loc, wide, port, sg, it, core, meta_id in recs:
        op = "write" if wen else "read"
        (rg, rt, ridx), who = _req(loc, wide, port, sg, it, core)
        # wide = a 512-bit DMA burst (separate initiator, no core flow); don't
        # even probe, to keep the unbound count clean.
        fid = flows.fid(
            rg, rt, ridx, meta_id, cyc) if (
            flows and not wide) else None
        items.append((cyc,
                      cyc + 1,
                      op,
                      [("addr",
                        f"0x{addr:x}"),
                          ("requester",
                           who),
                          ("meta_id",
                           str(meta_id)),
                          ("op",
                           op)],
                      fid))
    for s, e, name, annos, fid in sorted(items, key=lambda x: x[0]):
        emit_slice_begin(
            builder,
            s * TICK,
            leaf,
            name,
            annos,
            flow_id=fid,
            rank=3)  # bank = sink
        emit_slice_end(builder, e * TICK, leaf)
    return len(items)


def process_spm_banks(spm_dir, builder, uu, args, flows=None):
    """Per-SPM-bank access trace under each Tile node (NoC tiles › Group › Tile
    › SPM banks › bank N). Explains slave_req-in stalls: who won each contended
    bank. Follows --noc-slices (state = read/write/stall runs; packet =
    per-access slice with address + requester). No bw/util counters."""
    banks = load_spm_bank_logs(spm_dir)
    if not banks:
        print(
            f"  SPM banks: no bank_g*_t*.log in {spm_dir}; skipping",
            file=sys.stderr)
        return 0
    packet_mode = args.noc_slices == "packet"
    bpad = len(str(max((b for runs, _ in banks.values()
               for b in runs), default=0)))
    nb = ntile = 0
    for (g, t), (runs, packets) in sorted(banks.items()):
        _ensure(builder, uu, ("nt",), "2 NoC tiles")
        _ensure(builder, uu, ("nt_g", g), _gname(g), ("nt",))
        _ensure(builder, uu, ("nt_t", g, t), _tname(t), ("nt_g", g))
        _ensure(builder, uu, ("nt_spm", g, t), "SPM banks", ("nt_t", g, t))
        for bank in sorted(runs):
            leaf = add_track(
                builder,
                uu.get(("nt_bank", g, t, bank)),
                f"bank {bank:0{bpad}d}",
                parent=uu.get(("nt_spm", g, t)))
            if packet_mode and bank in packets:
                _emit_bank_packets(
                    runs[bank],
                    packets[bank],
                    leaf,
                    g,
                    t,
                    builder,
                    args,
                    flows=flows)
            else:  # rr=0 -> read/write/stall naming
                _emit_state_slices(runs[bank], leaf, 0, builder, args)
            nb += 1
        ntile += 1
    print(f"  SPM banks: {nb} bank tracks across {ntile} tiles "
          f"({'packet' if packet_mode else 'state'} granularity)")
    return nb


def main():
    ap = argparse.ArgumentParser("perfetto_gen")
    ap.add_argument("traces", nargs="+", help="trace_hart_*.dasm files")
    ap.add_argument("-o", "--output", default="perf.perfetto-trace")
    ap.add_argument("--cores-per-tile", type=int, default=4)
    ap.add_argument("--tiles-per-group", type=int, default=4)
    ap.add_argument(
        "--mesh-y",
        type=int,
        default=1,
        help="NoC mesh Y dimension (NumY = NumGroups / NumX). "
        "A linear group g maps "
        "to mesh (g // mesh_y, g %% mesh_y); used to render src/dst (x,y) on "
        "NoC "
        "packets. Pass from config (Makefile does) or src/dst (x,y) will be "
        "wrong.")
    ap.add_argument("--window-ns", type=int, default=1000,
                    help="counter window in ns (default 1000 = 500 cycles)")
    ap.add_argument(
        "--clk-freq",
        type=float,
        default=500.0,
        help="clock frequency in MHz (default 500 -> 2.0 ns/cycle). "
        "The timeline "
        "axis is REAL ns = cycle * (1000 / clk_freq); 1 cycle therefore spans "
        "the true clock period, not a misleading 1 ns.")
    ap.add_argument(
        "--clk-period",
        "--clk-ns",
        type=float,
        default=None,
        dest="clk_ns",
        help="clock period in ns -- overrides --clk-freq if given "
        "(e.g. --clk-period 1.25 for 800 MHz).")
    ap.add_argument("--slices", choices=["none", "function", "instruction"],
                    default="function",
                    help="timeline slices: none, function (default), or "
                         "instruction (per-insn disasm; heavy at scale)")
    ap.add_argument("--filter-benchmark", action="store_true",
                    help="only emit between mempool_start/stop_benchmark")
    ap.add_argument(
        "--elf",
        help="elf for addr2line (default: from transcript)")
    ap.add_argument(
        "--addr2line",
        help="addr2line path (default: auto-detect)")
    ap.add_argument(
        "--spike-dasm",
        help="spike-dasm path (default: auto-detect)")
    ap.add_argument(
        "--noc", help="noc_profiling/ dir (router_g*/tile_g* full logs); "
        "overlays NoC state-runs + derived counters on the timeline")
    ap.add_argument(
        "--spm", help="spm_profiling/ dir (bank_g*_t*.log); adds per-SPM-bank "
        "access tracks under each Tile node (needs --noc for the tiles)")
    ap.add_argument(
        "--cycle-start",
        type=int,
        default=0,
        help="export only cycles >= this (frequency-independent; default 0)")
    ap.add_argument(
        "--cycle-end",
        type=int,
        default=None,
        help="export only cycles < this (default: end of run). "
        "Windowing DROPS "
        "out-of-range data, shrinking the trace/DB for fast load + click")
    ap.add_argument(
        "--free-range",
        action="store_true",
        help="let counter y-axes auto-scale to their data range "
        "(default: every fraction counter is pinned to [0,1])")
    ap.add_argument(
        "--noc-slices",
        choices=[
            "state",
            "packet"],
        default="state",
        help="NoC request-port traffic granularity (chosen here, like "
        "--slices function|instruction -- the per-router/tile logs "
        "always carry both): 'state' (default) = idle/stall/read/write "
        "runs; 'packet' = one slice per request flit w/ address + target XY")
    ap.add_argument(
        "--flows",
        action="store_true",
        help="correlate packets into Perfetto flows via (requester, meta_id): "
        "click any NoC/bank packet to follow arrows to the originating "
        "core request and back. Requires --noc-slices packet.")
    args = ap.parse_args()

    # ns per cycle (honest real-ns axis)
    global TICK
    if args.clk_ns is None:  # derive period from frequency
        args.clk_ns = 1000.0 / args.clk_freq
    TICK = float(args.clk_ns)
    print(f"  clock: {args.clk_freq:g} MHz -> {args.clk_ns:g} ns/cycle "
          f"(timeline axis in real ns; flow order via rank, not time)")

    files = []
    for pat in args.traces:
        files.extend(sorted(glob.glob(pat)) if any(ch in pat for ch in "*?[")
                     else [pat])

    # export window (cycles); drops the rest
    global WIN_CYC_LO, WIN_CYC_HI
    WIN_CYC_LO = max(0, args.cycle_start)
    WIN_CYC_HI = args.cycle_end if args.cycle_end is not None else (1 << 62)
    if WIN_CYC_LO or args.cycle_end is not None:
        print(f"  window: cycles [{WIN_CYC_LO}, "
              f"{WIN_CYC_HI if args.cycle_end is not None else 'end'})")

    # Zero-pad widths so the lexicographic UI order matches numeric order
    # (Tile 00..15).
    global PAD_G, PAD_T, PAD_H, MESH_NY
    MESH_NY = max(1, args.mesh_y)
    harts = [int(m.group(1), 16)
             for m in (HART_RE.search(p) for p in files) if m]
    cpg = max(1, args.cores_per_tile * args.tiles_per_group)
    PAD_H = len(str(max(harts))) if harts else 2
    PAD_G = len(str(max(harts) // cpg)) if harts else 2
    PAD_T = len(str(max(1, args.tiles_per_group - 1)))

    if args.slices != "none" or args.filter_benchmark:
        args.elf = args.elf or detect_elf(files)
        args.addr2line = find_tool(
            args.addr2line, [
                "riscv32-unknown-elf-addr2line", "addr2line"])
        if not args.elf or not args.addr2line:
            print(f"  WARNING: function/source names need elf+addr2line "
                  f"(elf={args.elf}, addr2line={args.addr2line}); "
                  f"slices unnamed, --filter-benchmark may drop everything",
                  file=sys.stderr)
    if args.slices == "instruction":
        args.spike_dasm = find_tool(args.spike_dasm, ["spike-dasm"])
        if not args.spike_dasm:
            print("  WARNING: spike-dasm not found; instruction slices will "
                  "show raw DASM(hex)", file=sys.stderr)

    builder = TraceProtoBuilder()
    uu = Uuids()
    a2l = Addr2Line(args.addr2line, args.elf)

    pe_data = load_pe_logs(args.noc) if args.noc else {
    }    # per-core PE port traffic
    flows = None
    if args.flows:  # flows only in packet mode
        if args.noc_slices != "packet":
            print(
                "  WARNING: --flows needs --noc-slices packet; flows disabled",
                file=sys.stderr)
        else:
            flows = Flows(pe_data)
    n = 0
    for path in files:
        m = HART_RE.search(path)
        if not m:
            print(f"skip (no hart id): {path}", file=sys.stderr)
            continue
        process_dasm(path, int(m.group(1), 16), builder,
                     uu, args, a2l, pe_data, flows=flows)
        n += 1
    if pe_data:
        print(
            f"  PE ports: attached {len(pe_data)} core port "
            "traces under Core nodes")
    if args.noc:
        # Tiles BEFORE routers so the root order is Core / NoC tiles / NoC
        # routers: a memory access enters/exits the mesh at the tile, so
        # keeping tiles adjacent to the cores makes the
        # req->tile->router->tile->bank flow read top-to-bottom.
        process_noc_tiles(args.noc, builder, uu, args, flows=flows)
        process_noc_routers(args.noc, builder, uu, args, flows=flows)
    if args.spm:  # per-SPM-bank tracks under the tiles
        process_spm_banks(args.spm, builder, uu, args, flows=flows)
    if flows:
        print(flows.report())

    # write buffered events in (ts, phase, rank) order
    flush_events(builder)
    with open(args.output, "wb") as f:
        f.write(builder.serialize())
    per_group = args.cores_per_tile * args.tiles_per_group
    groups = (n + per_group - 1) // per_group
    print(f"wrote {args.output}: {n} cores -> {groups} groups x "
          f"{args.tiles_per_group} tiles/group x {args.cores_per_tile} "
          f"cores/tile, slices={args.slices}, "
          f"{len(builder.trace.packet)} packets")
    if n % per_group:
        print(f"  WARNING: {n} cores not divisible by {per_group} cores/group "
              f"-- check --cores-per-tile/--tiles-per-group (or pass "
              f"config=<flavor> to make)", file=sys.stderr)


if __name__ == "__main__":
    main()
