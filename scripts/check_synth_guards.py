#!/usr/bin/env python3
"""Find signals DECLARED in a simulation-only region but USED outside it.

This class of bug is invisible to simulation and fatal to synthesis, and it has bitten this repo
twice in one day:

  * mempool_group_mshr.sv -- mshr_resp_hold_timeout_dbg / mshr_cache_timeout_dbg declared inside a
    `pragma translate_off` region, cleared and set outside it. Presto analysis died in 18 seconds
    with "The symbol ... is not defined (VER-956)". Introduced 2026-08-21, found 2026-09-04 only
    because an out-of-context synthesis run was finally attempted on the current RTL.
  * sp-fmatmul .../main.c -- a_fill_cyc declared inside `#if MATMUL_A_REPLICAS > 1`, printed
    outside it, so every PREFILL shape failed to compile while decode shapes hid it.

Simulators compile `pragma translate_off` regions and define neither TARGET_SYNTHESIS nor
SYNTHESIS, so the declaration is always there in a sim and the code looks fine. Synthesis drops it
and the use dangles. A full elaboration is the only other way to catch it, and that is the thing
this check exists to avoid waiting for.

Usage:
    scripts/check_synth_guards.py hardware/src/mempool_group_mshr.sv [more.sv ...]
    scripts/check_synth_guards.py --all          # every .sv under hardware/src

Exit 0 = clean, 1 = findings, 2 = usage error. Findings print as file:line for the USE site.

Deliberately syntactic, not a parser: it reports a use of a sim-only name from an unguarded line.
That is exactly the failure mode, and it needs no elaboration, no tool licence and no config.
"""
import re
import sys
from pathlib import Path

# A region is simulation-only if synthesis will not see it.
OFF_OPEN = re.compile(r'^\s*//\s*pragma\s+translate_off\b')
OFF_CLOSE = re.compile(r'^\s*//\s*pragma\s+translate_on\b')
# `ifndef TARGET_SYNTHESIS / `ifndef SYNTHESIS open a sim-only region; `ifdef opens the converse.
IFN_SYNTH = re.compile(r'^\s*`ifndef\s+(TARGET_SYNTHESIS|SYNTHESIS)\b')
IFD_SYNTH = re.compile(r'^\s*`ifdef\s+(TARGET_SYNTHESIS|SYNTHESIS)\b')
IF_ANY = re.compile(r'^\s*`(ifdef|ifndef)\b')
ELSE_ANY = re.compile(r'^\s*`else\b')
ENDIF_ANY = re.compile(r'^\s*`endif\b')

# A declaration we can attribute a name to. Keep this conservative: a false NEGATIVE just means we
# miss one, a false POSITIVE wastes someone's morning.
DECL = re.compile(
    r'^\s*(?:automatic\s+)?'
    r'(?:logic|bit|reg|wire|int|integer|byte|shortint|longint|real)\b'
    r'(?:\s+(?:signed|unsigned))?'
    r'(?:\s*\[[^;]*?\])?\s*'
    r'([A-Za-z_]\w*)'
    r'\s*(?:\[[^;]*?\])?\s*(?:;|,|=)'
)
IDENT = re.compile(r'\b([A-Za-z_]\w*)\b')


def classify(lines):
    """Return a per-line bool: True if synthesis will NOT see this line."""
    simonly = []
    # translate_off is a FLAG, not a nestable scope: a second `translate_off` before any
    # `translate_on` is redundant, and one `translate_on` ends the region. Counting nesting
    # instead (the obvious first guess) makes the region never close -- mempool_group_mshr.sv
    # has translate_off twice in a row, which silently marked 600 later lines sim-only and hid
    # the very bug this script was written for.
    off = False
    stack = []              # per `ifdef level: True while the ACTIVE arm is sim-only
    for ln in lines:
        if OFF_OPEN.search(ln):
            off = True
        elif OFF_CLOSE.search(ln):
            off = False

        if IFN_SYNTH.match(ln):
            stack.append(True)
        elif IFD_SYNTH.match(ln):
            stack.append(False)
        elif IF_ANY.match(ln):
            stack.append(None)          # unrelated conditional; inherits nothing
        elif ELSE_ANY.match(ln) and stack:
            top = stack[-1]
            stack[-1] = (not top) if isinstance(top, bool) else None
        elif ENDIF_ANY.match(ln) and stack:
            stack.pop()

        simonly.append(off or any(s is True for s in stack))
    return simonly


def scan(path):
    # A sweep must not die on one unreadable file -- the RTL trees here contain dangling symlinks
    # (working_dir/spatz has several), and a crash halfway through reads as "clean so far".
    try:
        lines = Path(path).read_text(errors='replace').split('\n')
    except OSError as e:
        print(f'{path}: SKIPPED ({e.strerror})', file=sys.stderr)
        return []
    simonly = classify(lines)

    # Names declared ONLY in sim-only regions.
    declared_sim, declared_synth = {}, set()
    for i, ln in enumerate(lines):
        code = ln.split('//')[0]
        m = DECL.match(code)
        if not m:
            continue
        name = m.group(1)
        if simonly[i]:
            declared_sim.setdefault(name, i + 1)
        else:
            declared_synth.add(name)
    suspect = {n: l for n, l in declared_sim.items() if n not in declared_synth}
    if not suspect:
        return []

    findings = []
    for i, ln in enumerate(lines):
        if simonly[i]:
            continue
        code = ln.split('//')[0]
        if not code.strip():
            continue
        for name in set(IDENT.findall(code)):
            if name in suspect:
                findings.append((path, i + 1, name, suspect[name], ln.strip()[:90]))
    return findings


def check_pragma_case(path):
    """Synthesis pragmas are CASE-SENSITIVE. An automated comment pass rewrote
    `// pragma translate_off` to `// Pragma translate_off` on 2026-09-04, silently making 17 of
    them inert -- simulation stayed clean and vopt reported nothing. Also flags an unbalanced
    region, which is how 4 translate_off lines got eaten by a comment-compression pass the same
    day (they sit at the end of a `//` run and look like prose)."""
    out = []
    try:
        lines = Path(path).read_text(errors='replace').split('\n')
    except OSError:
        return out
    off = on = 0
    for i, ln in enumerate(lines):
        low = ln.lower()
        if 'pragma translate_off' in low or 'pragma translate_on' in low:
            if 'pragma translate_off' not in ln and 'pragma translate_on' not in ln:
                out.append((path, i + 1, 'pragma directive is not lowercase -- synthesis ignores it',
                            0, ln.strip()[:90]))
        if OFF_OPEN.search(ln):
            off += 1
        elif OFF_CLOSE.search(ln):
            on += 1
    if off and on and abs(off - on) > 1:
        out.append((path, 0, 'translate_off/translate_on counts differ (%d/%d)' % (off, on), 0, ''))
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    if argv[1] == '--all':
        root = Path(__file__).resolve().parent.parent / 'hardware' / 'src'
        files = sorted(str(p) for p in root.rglob('*.sv'))
    else:
        files = argv[1:]

    total = 0
    for f in files:
        for path, use_line, name, decl_line, text in list(scan(f)) + check_pragma_case(f):
            total += 1
            print(f'{path}:{use_line}: {name!r} is declared only in a simulation-only region '
                  f'(line {decl_line}) but used here, where synthesis can see it')
            print(f'    {text}')
    if total:
        print(f'\n{total} finding(s): these break synthesis while simulating cleanly.')
        return 1
    print(f'clean: {len(files)} file(s) checked')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
