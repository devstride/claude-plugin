#!/usr/bin/env bash
# Local runner for the invariants check embedded in delivery-loop-invariants.md.
set -u
cd "$(dirname "$0")/.."
awk '/^```bash/{f=1;next}/^```/{f=0}f' skills/review/references/delivery-loop-invariants.md > /tmp/ds-invariants-check.sh
out=$(bash /tmp/ds-invariants-check.sh 2>&1)
echo "$out"
if echo "$out" | grep -q '^MISSING'; then echo "INVARIANTS: misses above — go and read"; exit 1; fi
echo "INVARIANTS: clean"
