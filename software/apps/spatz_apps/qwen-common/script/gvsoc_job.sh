#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# One GVSoC run as a fleet job (gvsoc_fleet.py), or by hand:
#
#   qwen-common/script/gvsoc_job.sh <4x4|8x8> <elf> <outdir> [max_seconds]
#
# Runs the model with the FPU and DMA probes on (gvsoc_run.sh), converts its output into an
# RTL-style <outdir>/transcript (gvsoc_probes.py), then deletes what is big and not needed:
# the raw per-core FPU windows and the model's generated config. Keeps run.log, run.dma and the
# model's own statistics (run.d/*.log).
set -uo pipefail
[ $# -ge 3 ] || { echo "usage: $0 <4x4|8x8> <elf> <outdir> [max_seconds]" >&2; exit 2; }
mesh=$1 elf=$2 out=$3 tmax=${4:-0}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
# Some fleet nodes have no /usr/bin/python3.12: the uv-managed 3.12 in $HOME (mounted everywhere).
[ -x /usr/bin/python3.12 ] || export QC_PY=$HOME/.local/share/uv/python/cpython-3.12-linux-x86_64-gnu/bin/python3.12
export TERANOC_FPU_UTIL_PATH="$out/run.fpu" TERANOC_DMA_STATS_PATH="$out/run.dma" QC_LINEBUF=1
rm -f "$out/run.fpu" "$out/run.dma"
"$here/gvsoc_run.sh" "$mesh" "$elf" "$out/run" "$tmax"
rc=$?
python3 "$here/gvsoc_probes.py" --mesh "$mesh" --log "$out/run.log" --fpu "$out/run.fpu" \
  --dma "$out/run.dma" -o "$out/transcript" || rc=$((rc ? rc : 3))
rm -f "$out/run.fpu" "$out/run.d/gvsoc_config.json" "$out/run.d/gvsoc_runtime_config.txt" \
  "$out/run.d/trace_file.txt"
exit $rc
