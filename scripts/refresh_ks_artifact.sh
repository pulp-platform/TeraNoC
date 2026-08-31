#!/bin/bash
# Harvest both runs node-side and regenerate the B x KS artifact.
#
# Design: ssh returns only the RAW probe lines (a few KB); all parsing happens locally in
# python. The previous version parsed inside the ssh heredoc, where nested quoting made the
# probe near-impossible to extend safely.
set -u
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
cd $R
mkdir -p /tmp/claude-620771/fpug /tmp/claude-620771/probe

BATCHES_RUN1="teranoc-20260829-165720-48f9 teranoc-20260829-171031-09f6 waveA2rest-20260829-181331-48b9"
BATCHES_RUN2="run2tgt-20260829-212656-8043 run2tgtb-20260829-215219-729b"
BATCHES_WB="waveB-$(ls -d /dev/null 2>/dev/null; true)"

collect() {   # $1 = out tag, rest = batch ids
  local tag=$1; shift
  mkdir -p /tmp/claude-620771/probe
  : > /tmp/claude-620771/${tag}_raw.txt
  for B in "$@"; do
    timeout 120 /home/zexifu/badist/bin/badist status "$B" 2>/dev/null \
      | awk '/^[0-9]{4}[[:space:]]/ && $2=="done"{ if (match($0,/arm=[^ ]+/)) print $1"\t"$3"\t"substr($0,RSTART+4,RLENGTH-4) }' \
      | while IFS=$'\t' read -r job node arm; do
          # raw probe lines only -- parsed locally below
          ssh -n -o ConnectTimeout=10 "$node" \
            "for dd in /scratch*/zexifu_cache/badist/run/$B/$job; do [ -d \"\$dd\" ] || continue; \
               sed 's/^# //' \$dd/transcript 2>/dev/null | grep -aE 'execution took|\[STALLG\] bench|\[FPU\] bench|RH STUCK|peers=0|FPU FINAL|period_summary'; break; done" \
            2>/dev/null > /tmp/claude-620771/probe/${tag}__$arm.txt
          echo "$arm" >> /tmp/claude-620771/${tag}_raw.txt
          # per-group series for the utilisation explorer, once per arm
          if [ ! -s /tmp/claude-620771/fpug/${tag}__$arm.txt ]; then
            ssh -n -o ConnectTimeout=10 "$node" \
              "for dd in /scratch*/zexifu_cache/badist/run/$B/$job; do [ -d \"\$dd\" ] || continue; \
                 sed 's/^# //' \$dd/transcript 2>/dev/null | grep -a '^\[FPUG\] bench'; break; done" \
              2>/dev/null > /tmp/claude-620771/fpug/${tag}__$arm.txt
            [ -s /tmp/claude-620771/fpug/${tag}__$arm.txt ] || rm -f /tmp/claude-620771/fpug/${tag}__$arm.txt
          fi
        done
  done
}
collect run1 $BATCHES_RUN1
collect run2 $BATCHES_RUN2
WB=$(timeout 60 /home/zexifu/badist/bin/badist batches 2>/dev/null | awk '/^waveB-/{print $1;exit}')
[ -n "$WB" ] && collect wb $WB || : > /tmp/claude-620771/wb_raw.txt
S8=$(timeout 60 /home/zexifu/badist/bin/badist batches 2>/dev/null | awk '/^s8ks8p1-/{print $1;exit}')
[ -n "$S8" ] && collect s8 $S8 || : > /tmp/claude-620771/s8_raw.txt
# 8x8 Wave A (KS=2/4). `badist batches` shows only ~20 of 265 by default, so ask for enough
# rows to still find a batch once newer ones pile on top of it -- see the windowed-view note.
WC=$(timeout 90 /home/zexifu/badist/bin/badist batches --limit 300 2>/dev/null | awk '/^waveC4-/{print $1;exit}')
[ -n "$WC" ] && collect wc4 $WC || : > /tmp/claude-620771/wc4_raw.txt
WA8=$(timeout 90 /home/zexifu/badist/bin/badist batches --limit 300 2>/dev/null | awk '/^waveA8x8-/{print $1;exit}')
[ -n "$WA8" ] && collect wa8 $WA8 || : > /tmp/claude-620771/wa8_raw.txt

python3 scripts/parse_ks_probes.py
python3 scripts/extract_ks_group_util.py
python3 scripts/gen_ks_sweep_artifact.py
