#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# Run one ELF on the calibrated GVSoC model (read-only use of its tree).
#
#   [FFN_HB=1] script/gvsoc_run.sh <4x4|8x8> <elf> <rundir> [max_seconds]
#
# Writes <rundir>.log (stdout+stderr) and the model's work dir <rundir>.d. Prints one line:
# the verdict (success!/FAIL/none), EOC and the timed-region cycles. A max_seconds bound
# (default none) kills a run that is not going to finish -- a full-K perf run is read from
# its progress, not from its end.
#
# Trust (gvsoc/docs/calibration/current-rtl-20260928.md): 8x8 short runs within 2.2% of RTL,
# long 8x8 K-tile intervals 3-7% fast; 4x4 -11..+6%. B < 8 timing is NOT evidence (the RTL's
# split-NoC fold/steer is not modelled).
set -uo pipefail

[ $# -ge 3 ] || { echo "usage: $0 <4x4|8x8> <elf> <rundir> [max_seconds]" >&2; exit 2; }
mesh=$1 elf=$(readlink -f "$2") run=$3 tmax=${4:-0}
case $mesh in
  4x4) prof=terapool_spatz4_fpu ;;
  8x8) prof=terapool_spatz4_fpu_8x8 ;;
  *) echo "mesh must be 4x4 or 8x8" >&2; exit 2 ;;
esac
GV=${GVSOC_DIR:-/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC_gvsoc/gvsoc}
shim=/tmp/teranoc-gvsoc-py312
mkdir -p "$shim" && ln -sf /usr/bin/python3.12 "$shim/python3"
mkdir -p "$(dirname "$run")"
run=$(readlink -f "$run")

# FFN_HB=1: the model's MSHR heartbeat (one change-gated line per 65536 cycles) into the run's
# own directory -- the only live progress a long run gives. Always an absolute path: the
# model runs from its own tree, where a relative one would land.
unset TERANOC_MSHR_HB_PATH
if [ "${FFN_HB:-0}" = 1 ]; then mkdir -p "$run.d"; export TERANOC_MSHR_HB_PATH="$run.d/hb.log"; fi
cmd=(/usr/bin/python3.12 -m gvrun "--target=teranoc_spatz:system_config=$prof"
     "--work-dir=$run.d" --parameter "binary=$elf" run)
t0=$(date +%s)
(
  cd "$GV" || exit 1
  export PATH="$GV/install/bin:$shim:$PATH" PYTHONPATH="$GV/install/python" \
         LD_LIBRARY_PATH="$GV/install/lib"
  if [ "$tmax" -gt 0 ]; then exec timeout --signal=KILL "$tmax" "${cmd[@]}"; else exec "${cmd[@]}"; fi
) > "$run.log" 2>&1
rc=$?
verdict=$(grep -a -o -m1 'success!\|FAIL:.*' "$run.log" || echo none)
eoc=$(grep -a -o -m1 'EOC register return value: 0x[0-9a-f]*' "$run.log" | awk '{print $NF}')
took=$(grep -a -o -m1 'The execution took [0-9]* cycles' "$run.log" | awk '{print $4}')
echo "$(basename "$run"): rc=$rc verdict=$verdict eoc=${eoc:--} took=${took:--} wall=$(( $(date +%s) - t0 ))s"
