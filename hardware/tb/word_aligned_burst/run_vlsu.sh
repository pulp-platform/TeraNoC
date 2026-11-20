#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
build=${1:-/tmp/teranoc-vlsu-tile-burst}
mkdir -p "$build"
cd "$build"
sha256sum "$root/working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv" \
  "$root/working_dir/spatz/hw/ip/spatz/src/reorder_buffer.sv" \
  "$root/hardware/tb/word_aligned_burst/vlsu_tile_burst_tb.sv" >source_hashes.before
vcs-2024.09-zr vcs -full64 -sverilog -timescale=1ns/1ps +define+TARGET_MEMPOOL +define+VLEN=4096 \
  +define+SPATZ_VLSU_BLOCK_ALLOC="${VLSU_BLOCK_ALLOC:-1}" \
  +incdir+"$root/hardware/deps/common_cells/include" \
  "$root/hardware/deps/common_cells/src/cf_math_pkg.sv" \
  "$root/hardware/deps/fpnew/src/fpnew_pkg.sv" \
  "$root/working_dir/spatz/hw/ip/spatz/src/rvv_pkg.sv" \
  "$root/working_dir/spatz/hw/ip/spatz/src/generated/spatz_pkg.sv" \
  "$root/hardware/deps/common_cells/src/fifo_v3.sv" \
  "$root/hardware/deps/common_cells/src/delta_counter.sv" \
  "$root/hardware/deps/common_cells/src/spill_register_flushable.sv" \
  "$root/hardware/deps/common_cells/src/spill_register.sv" \
  "$root/working_dir/spatz/hw/ip/spatz/src/reorder_buffer.sv" \
  "$root/working_dir/spatz/hw/ip/spatz/src/spatz_vlsu.sv" \
  "$root/hardware/tb/word_aligned_burst/vlsu_tile_burst_tb.sv" \
  -top mempool_tb -o simv >compile.log 2>&1
./simv >run.log 2>&1
sha256sum --check source_hashes.before >source_hashes.check
cat run.log
if grep -aEq 'Fatal:|Error:|Assertion.*fail' run.log; then
  exit 1
fi
grep -aq 'PASS VLSU 1024 reset cases + 100 consecutive loads' run.log
