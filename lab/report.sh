#!/usr/bin/env bash
# Summarises lab/.run/results.tsv per scenario and preset.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)

median() { sort -n | awk '{ value[NR] = $1 } END { if (NR) print value[int((NR + 1) / 2)]; else print "-" }'; }

{
  printf 'pg\tcenário\testratégia\truns\tsucesso\ttempo_ms\tdano_s\tpior_excesso_ms\tfila_máx\n'
  cut -f1-3 "$HERE/.run/results.tsv" | sort -u | while IFS=$'\t' read -r version scenario preset; do
    rows=$(awk -F'\t' -v version="$version" -v scenario="$scenario" -v preset="$preset" \
      '$1 == version && $2 == scenario && $3 == preset' "$HERE/.run/results.tsv")
    runs=$(echo "$rows" | wc -l | tr -d ' ')
    successes=$(echo "$rows" | awk -F'\t' '$5 == "success"' | wc -l | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s%%\t%s\t%s\t%s\t%s\n' "$version" "$scenario" "$preset" "$runs" \
      $((100 * successes / runs)) \
      "$(echo "$rows" | awk -F'\t' '$5 == "success" { print $7 }' | median)" \
      "$(echo "$rows" | cut -f8 | median)" \
      "$(echo "$rows" | cut -f9 | median)" \
      "$(echo "$rows" | cut -f11 | median)"
  done
} | column -t -s $'\t'
