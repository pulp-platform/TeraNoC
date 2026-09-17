#!/usr/bin/env bash
set -euo pipefail
test_dir=$(cd "$(dirname "$0")" && pwd)
build=${1:-$(mktemp -d /tmp/teranoc-pool-select.XXXXXX)}
mkdir -p "$build"
build=$(cd "$build" && pwd)
cd "$build"
sha256sum "$test_dir/pool_select_equiv_tb.sv" > source_hashes.before
vcs-2024.09-zr vcs -full64 -sverilog -timescale=1ns/1ps \
  "$test_dir/pool_select_equiv_tb.sv" -top pool_select_equiv_tb \
  -o simv > compile.log 2>&1
./simv > run.log 2>&1
sha256sum --check source_hashes.before > source_hashes.check
cat run.log
grep -aq 'PASS pool selection equivalence: 1200000 vectors' run.log
