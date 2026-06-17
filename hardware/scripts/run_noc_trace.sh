#!/bin/bash
# Run sp-fmatmul-opt-burst-merge headless in a dedicated build dir, capturing the
# per-flit NoC event trace (noc_trace/events.csv) over a bounded time window.
# Bounded run (not `run -a`) because the bug is a hang — `run -a` never returns.
# Does NOT touch build_1/build_2 (the user's live GUI sims).
set -u
BUILD=${1:-build_trace}
LO=${2:-15000}
HI=${3:-28000}
RUN_NS=${4:-28000}
ROOT=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
APP=apps/spatz_apps/sp-fmatmul-opt-burst-merge
PRELOAD="$ROOT/software/bin/$APP"
DRAMSYS="$ROOT/hardware/deps/dram_rtl_sim/dramsys_lib/DRAMSys"

cd "$ROOT/hardware/$BUILD" || exit 2
echo "[run_noc_trace] cwd=$(pwd)  window=[$LO,$HI]ns  run=${RUN_NS}ns"
questa-2023.4-zr vsim -c -voptargs=+acc -wlf vsim_trace.wlf \
  +DRAMSYS_RES="$DRAMSYS/configs" \
  -sv_lib "$DRAMSYS/build/lib/libsystemc" \
  -sv_lib "$DRAMSYS/build/lib/libDRAMSys_Simulator" \
  +APP=$APP +PRELOAD="$PRELOAD" \
  +tracer_lo_ns=$LO +tracer_hi_ns=$HI \
  -sv_lib work-dpi/mempool_dpi -work work \
  -suppress vsim-12070 work.mempool_tb \
  -do "run ${RUN_NS}ns; quit -f"
echo "[run_noc_trace] vsim exit=$?"
echo "[run_noc_trace] events.csv: $(wc -l < noc_trace/events.csv 2>/dev/null || echo MISSING) lines"
