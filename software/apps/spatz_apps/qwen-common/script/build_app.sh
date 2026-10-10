#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# Build one Qwen mixer app ELF and keep it, with its provenance, outside software/bin.
#
#   qwen-common/script/build_app.sh <app> <4x4|8x8> <tag> <outdir> [make vars ...]
#   qwen-common/script/build_app.sh qwen-gdn 4x4 a_b1 hardware/elf_mixer EXTRA_DEFINES="-DGDN_B=1"
#
# Writes <outdir>/<tag>.elf, .dump and .log. The app's objects AND the shared runtime objects
# are deleted first: the app target does not depend on EXTRA_DEFINES (CLAUDE.md, runtime.mk
# "stale object" note), and software/runtime/*.o are compiled with NUM_CORES etc., so a leftover
# from another mesh would be linked silently. L2 is linked for the existing 512 MiB images unless
# QC_L2_SIZE says otherwise. Builds are serialised on a lock (shared runtime objects).
set -euo pipefail

[ $# -ge 4 ] || { echo "usage: $0 <app> <4x4|8x8> <tag> <outdir> [make vars]" >&2; exit 2; }
app=$1 mesh=$2 tag=$3 out=$4
shift 4
case $mesh in
  4x4) cfg=terapool_spatz4_fpu ;;
  8x8) cfg=terapool_spatz4_fpu_8x8 ;;
  *) echo "mesh must be 4x4 or 8x8" >&2; exit 2 ;;
esac
l2=${QC_L2_SIZE:-536870912}

apps=$(cd "$(dirname "$0")/../.." && pwd)
sw=$(cd "$apps/../.." && pwd)
bin="$sw/bin/apps/spatz_apps/$app"
mkdir -p "$out"
out=$(cd "$out" && pwd)
log="$out/$tag.log"

exec 9> "$apps/qwen-common/.build.lock"
flock 9
rm -f "$bin" "$bin.dump" "$apps/$app"/*.o "$sw"/runtime/*.o
{
  echo "# build_app.sh $app $mesh $tag $* ($(date -Is), $(git -C "$apps" rev-parse --short HEAD)$(git -C "$apps" diff --quiet -- . || echo '+dirty'))"
  echo "# make -o update_opcodes $app config=$cfg l1_bank_size=4096 l2_size=$l2 $*"
} > "$log"
if ! (cd "$apps" && PATH="/home/zexifu/.local/pyshim:$PATH" \
      make -o update_opcodes "$app" config="$cfg" l1_bank_size=4096 l2_size="$l2" "$@") >> "$log" 2>&1; then
  echo "BUILD FAILED ($app $mesh $tag): $log" >&2
  grep -a -m5 'error' "$log" >&2 || tail -5 "$log" >&2
  exit 1
fi
[ -f "$bin" ] || { echo "BUILD produced no ELF ($app $mesh $tag): $log" >&2; exit 1; }
cp "$bin" "$out/$tag.elf"
cp "$bin.dump" "$out/$tag.dump"
# the 512 B stack also holds the log-barrier counter: refuse an ELF whose call chain reaches it
if ! python3 "$apps/qwen-common/script/stack_depth.py" "$out/$tag.elf" >> "$log"; then
  echo "STACK OVER BUDGET ($app $mesh $tag): $(grep -a 'max stack' "$log" | tail -1)" >&2
  exit 1
fi
echo "$out/$tag.elf"
