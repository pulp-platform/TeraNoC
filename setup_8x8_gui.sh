#!/bin/bash
# ---------------------------------------------------------------------------
# Set up an 8x8 (1024-core) QuestaSim GUI run of sp-fmatmul-opt-burst-merge.
#
# Does three things, then prints the commands to compile and open the GUI:
#   1. regenerates the 8x8 NoC packages (perimeter map, floo pkg, route tables)
#   2. regenerates the matmul data for 2048x512x512 and builds the ELF
#   3. leaves the tree ready for `make sim config=terapool_spatz4_fpu_8x8`
#
# Shape rationale: merge degree = M / (num_groups * kernel_size). At 64 groups and
# kernel_size 8, M = 2048 holds the degree at 4, which is what the shipping
# group_mshr_* knobs are tuned for. M = 512 (the minimum legal) collapses the degree
# to 1 and the group MSHR does nothing.
# ---------------------------------------------------------------------------
set -eu
R="$(cd "$(dirname "$0")" && pwd)"
VENV=/tmp/claude-620771/floogen_venv/bin
VERIBLE=/tmp/claude-620771/verible-v0.0-3752-g8b64887e/bin
export PATH="$VERIBLE:$PATH"
M=2048; N=512; P=512
APP=sp-fmatmul-opt-burst-merge
CFG=terapool_spatz4_fpu_8x8

echo "=== 1/3  generate the 8x8 NoC packages ==="
cd "$R"
python3 hardware/scripts/gen_perimeter_map.py --num-x 8 --num-y 8 \
    -o hardware/generated --emit-yml config/floo_noc_terapool_spatz4_fpu_8x8.yml | tail -1
"$VENV/floogen" -c config/floo_noc_terapool_spatz4_fpu_8x8.yml -o hardware/generated --only-pkg \
    2>&1 | grep -viE "warning|ni_src|model_valid|returning" | tail -1 || true
"$VENV/python" hardware/scripts/gen_floo_route_tables.py \
    -c config/floo_noc_terapool_spatz4_fpu_8x8.yml -o hardware/generated | tail -2
echo "    mesh=$(grep -oE 'NumMeshX +=  *[0-9]+' hardware/generated/perimeter_map_pkg.sv | grep -oE '[0-9]+$')" \
     "PeriphHbmChannel=$(grep -oE 'PeriphHbmChannel = [0-9]+' hardware/generated/perimeter_map_pkg.sv | grep -oE '[0-9]+$') (must be 13)"

echo "=== 2/3  generate ${M}x${N}x${P} data and build the ELF for $CFG ==="
cd "$R/software/apps/spatz_apps/$APP"
python3 - "$M" "$N" "$P" <<'EOF'
import sys, re, pathlib
p = pathlib.Path("script/matmul.json"); s = p.read_text()
for k, v in zip(("M", "N", "P"), sys.argv[1:4]):
    s = re.sub(rf"^\s*{k}:\s*\d+,", f"    {k}: {v},", s, count=1, flags=re.M)
p.write_text(s)
EOF
python3 script/gen_data.py -c script/matmul.json
echo "    header $(stat -c%s data/data_gemm.h | awk '{printf "%.1f MB", $1/1048576}')," \
     "$(grep -aoE '\.M = [0-9]+|\.N = [0-9]+|\.P = [0-9]+' data/data_gemm.h | head -3 | tr '\n' ' ')"
cd "$R/software/apps/spatz_apps"
make $APP config=$CFG >/dev/null
ELF="$R/software/bin/apps/spatz_apps/$APP"
echo "    elf $(stat -c%s "$ELF" | awk '{printf "%.2f MB", $1/1048576}')  md5 $(md5sum "$ELF" | cut -c1-12)"

echo "=== 3/3  ready.  Compile and open the GUI with: ==="
cat <<EOS

  cd $R/hardware

  # GUI run (auto-loads scripts/questa/wave.tcl):
  app=apps/spatz_apps/$APP make -o update-floogen sim \\
      config=$CFG buildpath=build_gui

  # If elaboration is too slow, narrow +acc to the instances you actually probe.
  # Full +acc on 1024 cores is what pushed vopt past 60 min; the default -O5 path
  # elaborates in ~30 min:
  app=apps/spatz_apps/$APP make -o update-floogen sim \\
      config=$CFG buildpath=build_gui \\
      questa_voptargs='+acc=rn+mempool_tb/dut/i_mempool_cluster/gen_groups_x[0]/gen_groups_y[0]/...'

Notes
  * -o update-floogen skips the floogen re-run; step 1 already produced the packages.
  * Do not run this while another 8x8 build is in its vlog phase -- step 1 rewrites
    hardware/generated/, which is shared and mesh-specific.
  * The kernel skips its device-side verify (MATMUL_VERIFY=0); that check wedges core 0
    on the scalar FP path and is a debug-only host-side check.
  * Expect ~90k cycles of serial setup (DMA of A and B, then a 2048-element checksum
    copy) before all 1024 cores enter the kernel.
EOS
