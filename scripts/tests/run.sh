#!/bin/bash
# scripts/tests/run.sh — run every scripts/tests/*.sh except itself; non-zero if any fails.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; FAILED=0; RAN=0
for t in "$DIR"/*.sh; do
  [ "$(basename "$t")" = "run.sh" ] && continue
  RAN=$((RAN + 1))
  if bash "$t"; then echo "PASS $(basename "$t")"; else echo "FAIL $(basename "$t")"; FAILED=$((FAILED + 1)); fi
done
echo "tests: $RAN ran, $FAILED failed"
[ "$FAILED" -eq 0 ]
