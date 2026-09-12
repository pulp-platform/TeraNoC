#!/usr/bin/env python3
"""Create an instrumented TB copy. The original repository files are not edited."""
import argparse
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent


def main():
  p = argparse.ArgumentParser(description=__doc__)
  p.add_argument("--tb", type=Path, default=HERE.parent/"hardware/tb/mempool_tb.sv")
  p.add_argument("--compile-script", type=Path, help="Existing Questa compile.tcl to relocate")
  p.add_argument("--out", type=Path, default=HERE/"generated/mempool_tb.sv")
  args = p.parse_args()
  if args.out.resolve() == args.tb.resolve():
    p.error("output must be a new copy")
  text = args.tb.read_text()
  matches = list(re.finditer(r"^endmodule\b", text, re.M))
  if len(matches) != 1:
    p.error("expected one mempool_tb module")
  # Preserve original relative includes when compiling the relocated copy.
  def include(m):
    path = args.tb.parent/m[1]
    return '`include "'+str(path.resolve())+'"' if path.exists() else m[0]
  text = re.sub(r'`include "([^"]+)"', include, text)
  text = re.sub(r"^endmodule\b", '`include "'+str(HERE/'rtl/dashboard_probe.svh')+'"\n\nendmodule', text, count=1, flags=re.M)
  args.out.parent.mkdir(parents=True, exist_ok=True)
  args.out.write_text(text)
  if args.compile_script:
    script = args.compile_script.read_text()
    pattern = r'"[^"\n]*hardware/tb/mempool_tb\.sv"'
    script, count = re.subn(pattern, '"'+str(args.out.resolve())+'"', script)
    if count != 1:
      p.error("compile script must reference exactly one hardware/tb/mempool_tb.sv")
    target = args.out.parent/"compile.tcl"
    if target.resolve() == args.compile_script.resolve():
      p.error("refusing to overwrite original compile script")
    target.write_text(script)
    print(target.resolve())
  print(args.out.resolve())
  print("Compile this copy IN PLACE OF hardware/tb/mempool_tb.sv using the same defines/include paths. Add +dashboard_file=<absolute JSONL path> at simulation launch.")

if __name__ == '__main__':
  main()
