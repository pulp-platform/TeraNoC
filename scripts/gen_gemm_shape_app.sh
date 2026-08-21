#!/bin/bash
# Create a per-shape GEMM app and build its ELF to a private path.
#   usage: gen_gemm_shape_app.sh M N P [16|32]
# The app is a COPY of the single per-precision source (sp-fmatmul-opt-burst-merge-fp16 /
# sp-fmatmul-opt-burst-merge); only data_gemm.h differs. The MSHR tuning is NOT passed in --
# it is derived at compile time from the GEMM_M/N/P macros the data header emits
# (software/runtime/mshr_cfg.h), which is why there is no per-shape config/*.mk any more.
set -u
M=$1; N=$2; P=$3; PREC=${4:-16}; S="${M}x${N}x${P}"
ROOT=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
APPS=$ROOT/software/apps/spatz_apps
if [ "$PREC" = "32" ]; then SRC=$APPS/sp-fmatmul-opt-burst-merge; PFX=sp-fp32
else SRC=$APPS/sp-fmatmul-opt-burst-merge-fp16; PFX=sp-fp16; fi
d=$APPS/$PFX-$S
rm -rf "$d"; mkdir -p "$d/script" "$d/data"
cp "$SRC/main.c" "$d/main.c"
cp -r "$SRC/kernel" "$d/kernel"
cp "$SRC/script/gen_data.py" "$d/script/gen_data.py"
cp "$SRC/data/layer.h" "$d/data/layer.h" 2>/dev/null
cat > "$d/script/matmul.json" <<JSON
// fp16 perf sweep arm, ${S}. Source identical to sp-fmatmul-opt-burst-merge-fp16;
// only the shape differs. prec:16 -> e16,m2 at KERNEL_SIZE=8 (128 B vl, under the
// 256 B use_port0_burst_req ceiling; kernel_size=2 would be m8=512 B and silently
// leave the burst path).
{
    kernel: "GEMM"
    M: ${M},
    N: ${N},
    P: ${P},
    alpha: 0,
    transpose_A: false,
    transpose_B: false,
    prec: ${PREC},
    expand: 0
}
JSON
cd "$APPS" || exit 1
python3 "$d/script/gen_data.py" -c "$d/script/matmul.json" >/dev/null 2>&1 || { echo "DATAGEN_FAIL $S"; exit 1; }
if timeout 3600 make "$PFX-$S" config=terapool_spatz4_fpu >/tmp/claude-620771/gemmbuild_$S.log 2>&1; then
  cp "$ROOT/software/bin/apps/spatz_apps/$PFX-$S" "$ROOT/hardware/${PFX#sp-}_$S.elf"
  echo "ELF_OK $S ($(stat -c%s $ROOT/hardware/${PFX#sp-}_$S.elf) bytes)"
else
  echo "BUILD_FAIL $S"; tail -4 /tmp/claude-620771/gemmbuild_$S.log
fi
