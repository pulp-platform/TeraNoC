#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# Build one qwen-gdn ELF (check builds generate their expected values first).
#
#   qwen-gdn/script/build.sh <4x4|8x8> <tag> <outdir> <B> <stream 0|1> <check 0|1|2> [-Dmore ...]
set -euo pipefail
[ $# -ge 6 ] || { echo "usage: $0 <4x4|8x8> <tag> <outdir> <B> <stream> <check> [-D...]" >&2; exit 2; }
mesh=$1 tag=$2 out=$3 b=$4 stream=$5 check=$6
shift 6
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$here/data"
if [ "$check" != 0 ]; then python3.12 "$here/script/gen_check.py" "$b" "$here/data/gdn_check.h" >/dev/null; fi
"$here/../qwen-common/script/build_app.sh" qwen-gdn "$mesh" "$tag" "$out" \
  EXTRA_DEFINES="-DGDN_B=$b -DGDN_STREAM=$stream -DGDN_CHECK=$check $*"
