#!/usr/bin/env bash
# Runs every scenario against every preset given. Usage: lab/matrix.sh <repetitions> <preset>...
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPETITIONS=$1
shift
for scenario in ${SCENARIOS:-fast long15x1 long15x3 autovac}; do
  for preset in "$@"; do
    caffeinate -dims "$HERE/run.sh" "$scenario" "$preset" "$REPETITIONS"
  done
done
"$HERE/report.sh"
