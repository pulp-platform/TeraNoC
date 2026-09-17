#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
bench=${1:?Usage: run.sh decode|transport RTL_BUILD [PRIVATE_BUILD]}
case "$bench" in
  decode|transport) ;;
  *) echo "Unknown bench: $bench" >&2; exit 2 ;;
esac
rtl_build=$(realpath "${2:?Missing RTL_BUILD}")
build=${3:-/tmp/teranoc-group-control-$bench}
mkdir -p "$build"
build=$(realpath "$build")
questa=${QUESTA_CMD:-questa-2023.4-zr}
test -d "$rtl_build/work"
test -f "$rtl_build/work-dpi/mempool_dpi.so"
cd "$build"
"$questa" vlib work >library.log 2>&1
"$questa" vmap rtl "$rtl_build/work" >>library.log 2>&1
"$questa" vlog -sv -L rtl -work work \
  "$root/hardware/tb/group_control/tb_group_control_$bench.sv" >compile.log 2>&1
"$questa" vsim -c -L rtl -voptargs=+acc \
  -sv_lib "$rtl_build/work-dpi/mempool_dpi" work.mempool_tb -wlf "$bench.wlf" \
  -do 'log -r /mempool_tb/address /mempool_tb/dut; run -a; quit -f' \
  >run.log 2>&1
cat run.log
if grep -aEq 'Fatal:|Error:|Assertion.*fail' run.log; then
  exit 1
fi
grep -aq "PASS group-control ${bench/decode/decoder}:" run.log
