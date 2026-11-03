#!/bin/bash
# scripts/tests/check-train-name.sh — the old name `supportTrain` is confined to the files that explain
# the rename: the real tree passes, a stray mention in another skill text is flagged.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; CHECK="$ROOT/scripts/check-train-name.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OUT="$(bash "$CHECK" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "(1) the shipped skill text passes" || bad "(1) exit $RC: $OUT"
mkdir -p "$WORK/skills/demo" "$WORK/skills/doctor"
echo 'set `supportTrain.branch`' > "$WORK/skills/demo/SKILL.md"; echo 'the old `supportTrain` name' > "$WORK/skills/doctor/SKILL.md"
OUT="$(bash "$CHECK" --root "$WORK" 2>&1)"; RC=$?
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q '^skills/demo/SKILL.md:1:' && ! printf '%s' "$OUT" | grep -q 'skills/doctor' \
  && ok "(2) a stray mention is flagged, the allowed file is not" || bad "(2) exit $RC: $OUT"
exit $FAIL
