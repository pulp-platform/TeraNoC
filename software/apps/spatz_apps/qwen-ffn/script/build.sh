#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# Build one qwen-ffn ELF and keep it, with its provenance, outside software/bin.
#
#   script/build.sh <4x4|8x8> <tag> <outdir> [ffn_var=value ...]
#   script/build.sh 4x4 c4_b16_k1 /path/elf_ffn ffn_b=16 ffn_k=2048 ffn_check=1 ffn_preload=1
#
# Writes <outdir>/<tag>.elf, <tag>.dump and <tag>.log (make output + the generated shape,
# tiles and hash headers, so the -D defines and derived parameters travel with the ELF).
# The memory sizes are FIXED here: l1_bank_size=4096 (16 / 64 MiB L1) and a 512 MiB L2,
# the configuration every RTL image and GVSoC profile in this project uses.
# One build at a time per worktree: the generated headers live in qwen-ffn/data/.
set -euo pipefail

[ $# -ge 3 ] || { echo "usage: $0 <4x4|8x8> <tag> <outdir> [ffn_var=value ...]" >&2; exit 2; }
mesh=$1 tag=$2 out=$3
shift 3
case $mesh in
  4x4) cfg=terapool_spatz4_fpu ;;
  8x8) cfg=terapool_spatz4_fpu_8x8 ;;
  *) echo "mesh must be 4x4 or 8x8" >&2; exit 2 ;;
esac

apps=$(cd "$(dirname "$0")/../.." && pwd)
bin="$apps/../../bin/apps/spatz_apps/qwen-ffn"
mkdir -p "$out"
log="$out/$tag.log"
out=$(cd "$out" && pwd)

rm -f "$bin"  # a failed build must not leave the previous ELF looking like this one
{
  echo "# build.sh $mesh $tag $* ($(date -Is), $(git -C "$apps" rev-parse --short HEAD)$(git -C "$apps" diff --quiet -- . || echo '+dirty'))"
  echo "# make -o update_opcodes qwen-ffn config=$cfg icache_warmup=1 l1_bank_size=4096 l2_size=536870912 $*"
} > "$log"
if ! (cd "$apps" && PATH="/home/zexifu/.local/pyshim:$PATH" \
      make -o update_opcodes qwen-ffn config="$cfg" icache_warmup=1 \
           l1_bank_size=4096 l2_size=536870912 "$@") >> "$log" 2>&1; then
  echo "BUILD FAILED ($mesh $tag): $log" >&2
  tail -5 "$log" >&2
  exit 1
fi
[ -f "$bin" ] || { echo "BUILD produced no ELF ($mesh $tag): $log" >&2; exit 1; }
for h in gu/data/qwen_shape.h gu/data/qwen_tiles.h gu/data/qwen_hash.h dn/data/qwen_shape.h dn/data/qwen_tiles.h dn/data/qwen_hash.h data/ffn_joint.h data/ffn_shared.h; do
  { echo "# ---- $h"; cat "$apps/qwen-ffn/$h"; } >> "$log"
done
cp "$bin" "$out/$tag.elf"
cp "$bin.dump" "$out/$tag.dump"
echo "$out/$tag.elf  ($(grep -m1 '^// gate+up KT' "$apps/qwen-ffn/data/ffn_joint.h" | cut -c4-))"
