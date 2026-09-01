#!/bin/bash
# Build a DECODE-GEMM ELF for one shape, to a private path.
#   usage: gen_decode_shape_app.sh B D I [16|32]
#
# Decode shape: C[B][I] = A[B][D] x W[D][I], mapped to GEMM as M=B, N=D, P=I. No transpose is
# required -- A[b][d] is contiguous for the scalar load and W[d][p:p+VL] is contiguous for the
# vector load -- so the inner loop is the prefill kernel's; only the WORK SPLIT differs, and
# that is behind -DMATMUL_DECODE_SPLIT=1.
#
# NO PER-SHAPE DIRECTORY. This script used to create software/apps/spatz_apps/sp-decode-<shape>
# per shape. 43 of them accumulated and DRIFTED: 5 distinct main.c versions and 6 distinct
# kernels, three of the groups stale -- one missing MATMUL_REPEAT entirely, so its cycles were
# not comparable to any other arm. Now there are exactly two app dirs, sp-decode-fp16 and
# sp-decode-fp32, whose main.c/kernel/gen_data.py are SYMLINKS to the canonical
# sp-fmatmul-opt-burst-merge{,-fp16}; the shape is a make variable. A kernel fix is made once.
set -u
B=$1; D=$2; I=$3; PREC=${4:-16}; S="${B}x${D}x${I}"
ROOT=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
APPS=$ROOT/software/apps/spatz_apps
case "$PREC" in 16|32) ;; *) echo "BAD_PREC $PREC (want 16 or 32)"; exit 1;; esac
APP=sp-decode-fp$PREC
[ -d "$APPS/$APP" ] || { echo "MISSING APP $APPS/$APP"; exit 1; }

# The app target depends on main.c.o, not on the define set: if the binary is newer than the
# source, make does NOTHING and reports success (runtime.mk:165). Always clear it first.
rm -f "$APPS/$APP"/*.o "$ROOT/software/bin/apps/spatz_apps/$APP" 2>/dev/null

LOG=/tmp/claude-620771/decodebuild_${OUT_PREFIX:-}$S.log
if (cd "$APPS" && timeout 3600 make "$APP" \
      config=${CONFIG:-terapool_spatz4_fpu} \
      gemm_m=$B gemm_n=$D gemm_p=$I \
      group_mshr_merge_reqs=${MERGE_REQS:-16} \
      ${MAKE_VARS:-} EXTRA_DEFINES="-DMATMUL_DECODE_SPLIT=1 ${EXTRA_DEFINES:-}" >"$LOG" 2>&1) \
   && [ -s "$ROOT/software/bin/apps/spatz_apps/$APP" ]; then
  OUT="$ROOT/hardware/${OUT_PREFIX:-dec_}${S}.elf"
  cp -f "$ROOT/software/bin/apps/spatz_apps/$APP" "$OUT"
  # Prove the ELF really carries the shape we asked for: data_gemm.h supplies GEMM_M/N/P, and
  # runtime/mshr_cfg.h tunes the MSHR from them AT COMPILE TIME, so a stale header would
  # silently mistune the run rather than fail.
  got=$(grep -hoE '#define GEMM_[MNP] [0-9]+' "$APPS/$APP/data/data_gemm.h" 2>/dev/null \
        | awk '{printf "%s ",$3}')
  [ "$got" = "$B $D $I " ] || { echo "SHAPE_MISMATCH $S: header says [$got]"; exit 1; }
  echo "ELF_OK $S -> $(basename "$OUT") ($(stat -c%s "$OUT") bytes)"
else
  echo "BUILD_FAIL $S"; tail -5 "$LOG"; exit 1
fi
