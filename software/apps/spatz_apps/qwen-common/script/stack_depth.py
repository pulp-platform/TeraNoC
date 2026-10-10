#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# Worst-case stack depth from main, from the disassembly (frames = `addi sp, sp, -N`, calls =
# jal / auipc+jalr). Each core's stack is its 512 B sequential region, which ALSO holds the
# log-barrier counter at offset 4 (qc_sync.h): crt0 starts sp at 0x1fc, so a call chain deeper
# than 500 B silently overwrites the barrier word, and one of 508 B wraps below address 0.
#
#   stack_depth.py <elf> [--budget 500] [--objdump PATH]     exit 1 when over budget
import argparse
import re
import subprocess
import sys

ap = argparse.ArgumentParser()
ap.add_argument("elf")
ap.add_argument("--budget", type=int, default=500)
ap.add_argument("--objdump", default=None)
ap.add_argument("--root", default="main")
a = ap.parse_args()
od = a.objdump
if od is None:
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    od = os.path.join(here, "../../../../../install/llvm/bin/llvm-objdump")
txt = subprocess.run([od, "-d", "--no-show-raw-insn", a.elf], capture_output=True, text=True,
                     check=True).stdout

fn_re = re.compile(r"^([0-9a-f]+) <([^>]+)>:")
ins_re = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$")
funcs = {}       # name -> dict(frame, calls set, indirect bool)
addr2fn = {}
cur = None
last_auipc = {}  # reg -> (pc, imm)
for ln in txt.splitlines():
    m = fn_re.match(ln)
    if m:
        cur = m.group(2)
        funcs[cur] = {"frame": 0, "calls": set(), "indirect": False}
        addr2fn[int(m.group(1), 16)] = cur
        last_auipc = {}
        continue
    m = ins_re.match(ln)
    if not m or cur is None:
        continue
    pc, op, args = int(m.group(1), 16), m.group(2), m.group(3)
    f = funcs[cur]
    if op == "addi" and re.match(r"sp,\s*sp,\s*-\d+", args):
        f["frame"] += int(args.split("-")[-1])
    elif op == "auipc":
        r, imm = [x.strip() for x in args.split(",")]
        last_auipc[r] = (pc, int(imm, 0))
    elif op == "jalr":
        mm = re.match(r"(?:ra,\s*)?(-?\d+)\((\w+)\)", args)
        if mm and mm.group(2) in last_auipc:
            p, imm = last_auipc[mm.group(2)]
            f["calls"].add(p + (imm << 12) + int(mm.group(1)))
        elif mm and mm.group(2) == "ra" and "ra" not in last_auipc:
            pass
        elif args.strip() not in ("ra", "zero, 0(ra)", "0(ra)"):
            f["indirect"] = True
    elif op in ("jal", "call"):
        mm = re.search(r"(?:^|,\s*)(?:0x)?([0-9a-f]+)\s*<", args)
        rd = args.split(",")[0].strip() if "," in args else "ra"
        if mm and rd == "ra":
            f["calls"].add(int(mm.group(1), 16))

by_name = {}
for ad, n in addr2fn.items():
    by_name[n] = ad
memo = {}


def depth(name, stack):
    if name in stack:
        return 0, [name + " (recursion)"]
    if name in memo:
        return memo[name]
    f = funcs.get(name)
    if f is None:
        return 0, [name]
    best, path = 0, []
    for t in f["calls"]:
        tn = addr2fn.get(t)
        if tn is None:
            continue
        d, p = depth(tn, stack | {name})
        if d > best:
            best, path = d, p
    r = (f["frame"] + best, [f"{name}({f['frame']})"] + path)
    memo[name] = r
    return r


d, p = depth(a.root, frozenset())
ind = sorted(n for n, f in funcs.items() if f["indirect"])
print(f"{a.elf}: max stack {d} B (budget {a.budget}): " + " > ".join(p))
if ind:
    print("  indirect calls (not followed): " + ", ".join(ind[:8]))
sys.exit(1 if d > a.budget else 0)
