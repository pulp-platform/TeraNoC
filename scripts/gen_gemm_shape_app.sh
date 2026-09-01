#!/bin/bash
# Build a PREFILL GEMM ELF for one shape, to a private path.
#   usage: gen_gemm_shape_app.sh M N P [16|32]
#
# NO PER-SHAPE DIRECTORY. This script used to create software/apps/spatz_apps/sp-fp{16,32}-<shape>
# per shape. 274 of them accumulated and DRIFTED: the fp16 majority (141 dirs) sat **96
# non-comment lines** behind the canonical app -- no MATMUL_REPEAT, MATMUL_SPOTCHECK at 0 instead
# of 1, and no KERNEL_SIZE / auto-derived MATMUL_DECODE_SPLIT. Not one of the 152 fp16 dirs
# matched the canonical source, and only 1 of 122 fp32 dirs did.
#
# Now there are two thin wrappers, sp-prefill-fp16 / sp-prefill-fp32, whose main.c, kernel/ and
# gen_data.py are SYMLINKS to the canonical sp-fmatmul-opt-burst-merge{,-fp16}; the shape is a
# make variable. A kernel fix is made once and cannot drift. The wrappers exist so the canonical
# apps' own checked-in matmul.json stays pristine -- building a shape never dirties a tracked file.
#
# MERGE_REQS must MATCH the RTL image. Software reads it (MSHR_MERGE_REQS) to decide whether a
# cache reuse target of 2*hold_subs_single is reachable; if software thought the capacity were 4
# while the hardware elaborated 16, every shape with subs_single>2 would silently fall back to
# the legacy cache policy.
set -u
M=$1; N=$2; P=$3; PREC=${4:-16}; S="${M}x${N}x${P}"
ROOT=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
APPS=$ROOT/software/apps/spatz_apps
case "$PREC" in 16|32) ;; *) echo "BAD_PREC $PREC (want 16 or 32)"; exit 1;; esac
APP=$([ "$PREC" = 16 ] && echo sp-fmatmul-opt-burst-merge-fp16 || echo sp-fmatmul-opt-burst-merge)
PFX=sp-fp$PREC          # ELF naming unchanged, so every existing scraper keeps working
[ -d "$APPS/$APP" ] || { echo "MISSING APP $APPS/$APP"; exit 1; }

# runtime.mk:162 -- make with EXTRA_DEFINES silently does NOTHING and reports SUCCESS when the
# ELF is newer than the source, so a define-only rebuild is a no-op. rm the binary first.
rm -f "$APPS/$APP"/*.o "$ROOT/software/bin/apps/spatz_apps/$APP" 2>/dev/null

# CONFIG is REQUIRED for a different mesh: the app bakes in NUM_CORES/NUM_GROUPS, so building an
# 8x8 arm against terapool_spatz4_fpu yields a 256-core binary on 1024-core hardware -- no error,
# just a wrong work split and barrier chaos. OUT_PREFIX keeps the two meshes' ELFs from colliding
# under hardware/, where the filename carries only the shape.
LOG=/tmp/claude-620771/gemmbuild_${OUT_PREFIX:-}$S.log
if (cd "$APPS" && timeout 3600 make "$APP" \
      config=${CONFIG:-terapool_spatz4_fpu} \
      gemm_m=$M gemm_n=$N gemm_p=$P \
      group_mshr_merge_reqs=${MERGE_REQS:-16} \
      EXTRA_DEFINES="${EXTRA_DEFINES:-}" >"$LOG" 2>&1) \
   && [ -s "$ROOT/software/bin/apps/spatz_apps/$APP" ]; then
  OUT="$ROOT/hardware/${OUT_PREFIX:-}${PFX#sp-}_$S.elf"
  cp -f "$ROOT/software/bin/apps/spatz_apps/$APP" "$OUT"
  # Prove the ELF carries the shape we asked for: data_gemm.h supplies GEMM_M/N/P and
  # runtime/mshr_cfg.h tunes the MSHR from them AT COMPILE TIME, so a stale header would
  # silently mistune the run rather than fail.
  got=$(grep -hoE '#define GEMM_[MNP] [0-9]+' "$APPS/$APP/data/data_gemm.h" 2>/dev/null \
        | awk '{printf "%s ",$3}')
  [ "$got" = "$M $N $P " ] || { echo "SHAPE_MISMATCH $S: header says [$got]"; exit 1; }
  echo "ELF_OK $S ($(stat -c%s "$OUT") bytes)"
else
  echo "BUILD_FAIL $S"; tail -4 "$LOG"; exit 1
fi
