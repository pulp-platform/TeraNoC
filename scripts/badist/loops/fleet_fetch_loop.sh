#!/bin/bash
# Pull finished fleet arms into hardware/run5_<arm>/ as they land, so the artifact
# scrapers see them without a manual step. Reports each arm's cycle count once.
set -u
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC
seen=""
for i in $(seq 1 400); do
  for B in bp-revive-20260821-204201-b4c4 bp-revive2-20260821-205530-09dd; do
    out=$(cd "$R" && timeout 400 ./scripts/badist/teranoc_fleet.py fetch "$B" -q 2>/dev/null)
    while IFS= read -r ln; do
      case "$ln" in
        *" done "*)
          arm=$(echo "$ln" | awk '{print $1}')
          case " $seen " in *" $arm "*) continue;; esac
          cyc=$(echo "$ln" | awk '{print $NF}')
          [ "$cyc" = "-" ] && continue
          # the idea-2 figure for the same arm, so each line carries its comparison
          r4="$R/hardware/run4_$arm/transcript"
          if [ -f "$r4" ]; then
            c4=$(grep -a "execution took" "$r4" 2>/dev/null | head -1 | grep -oE "[0-9]+" | head -1)
          else c4=""; fi
          if [ -n "${c4:-}" ] && [ "$c4" -gt 0 ] 2>/dev/null; then
            echo "FLEET $arm: $cyc cyc (i2 $c4, $(( (cyc - c4) * 100 / c4 ))%)"
          else
            echo "FLEET $arm: $cyc cyc"
          fi
          seen="$seen $arm"
          ;;
      esac
    done <<< "$out"
  done
  sleep 600
done
