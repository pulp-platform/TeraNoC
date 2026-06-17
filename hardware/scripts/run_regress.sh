#!/bin/bash
# Headless regression run of a completing spatz app (e.g. sp-mshr-burst-test, vector-burst-test).
# Uses `run -a` (these tests reach EOC, unlike the deadlocking sp-fmatmul). Tracer disabled (+notracer).
# Runs in a dedicated build dir; does NOT touch build_1/build_2.
set -u
BUILD=${1:-build_trace}
APP=${2:-apps/spatz_apps/sp-mshr-burst-test}
ROOT=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
PRELOAD="$ROOT/software/bin/$APP"
DRAMSYS="$ROOT/hardware/deps/dram_rtl_sim/dramsys_lib/DRAMSys"
cd "$ROOT/hardware/$BUILD" || exit 2
echo "[run_regress] cwd=$(pwd) app=$APP"
questa-2023.4-zr vsim -c -voptargs=+acc -wlf regress.wlf \
  +DRAMSYS_RES="$DRAMSYS/configs" \
  -sv_lib "$DRAMSYS/build/lib/libsystemc" \
  -sv_lib "$DRAMSYS/build/lib/libDRAMSys_Simulator" \
  +APP=$APP +PRELOAD="$PRELOAD" +notracer \
  -sv_lib work-dpi/mempool_dpi -work work \
  -suppress vsim-12070 work.mempool_tb \
  -do "run -a; quit -f"
echo "[run_regress] vsim exit=$?"
