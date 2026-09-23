#!/usr/bin/env python3
"""Compile and run the deterministic probe test with VCS or Questa."""
import argparse
import json
import subprocess
from pathlib import Path

root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--backend',choices=('vcs','questa'),default='vcs')
p.add_argument('--vcs',default='vcs-2024.09-zr')
p.add_argument('--questa',default='questa-2023.4-zr')
a=p.parse_args()
build=root/'generated/probe_test'
build.mkdir(parents=True,exist_ok=True)
if a.backend == 'vcs':
  commands = [[a.vcs, 'vcs', '-full64', '-sverilog',
               '+incdir+'+str(root/'rtl'), str(root/'tests/probe_tb.sv'),
               '-top', 'mempool_tb', '-o', 'probe_simv'],
              [str(build/'probe_simv'), '+dashboard_file=telemetry.jsonl',
               '+dashboard_period=4', '+dashboard_entries',
               '+dashboard_banks', '+dashboard_links']]
else:
  commands = [[a.questa, 'vlib', 'work'],
              [a.questa, 'vlog', '-sv', '-work', 'work',
               '+incdir+'+str(root/'rtl'), str(root/'tests/probe_tb.sv')],
              [a.questa, 'vsim', '-c', '-lib', 'work', 'mempool_tb',
               '+dashboard_file=telemetry.jsonl', '+dashboard_period=4',
               '+dashboard_entries', '+dashboard_banks', '+dashboard_links',
               '-do', 'log -r /*; run -all; quit -f']]
for command in commands:
  subprocess.run(command,cwd=build,check=True)

rows=[json.loads(line) for line in (build/'telemetry.jsonl').read_text().splitlines()]
banks=[row for row in rows if row.get('kind')=='mshr_bank' and row['g']==0]
assert {row['bank'] for row in banks}=={0,1}
assert sum(row['allocations'] for row in banks)==2, 'resident entries recounted at a window boundary'
assert sum(row['full_cycles'] for row in banks if row['bank']==0)==8
assert all(row['full_cycles']==0 for row in banks if row['bank']==1)
assert all(row['full_cycles']<=row['end']-row['start'] for row in banks)
