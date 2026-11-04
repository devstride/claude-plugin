#!/bin/bash
# Tests for skills/release/scripts/standing-yes.py — the owner's standing yes for light releases.
# One passing case, then one case per condition, each failing only that condition: the first
# failed condition is what the script names, and nothing but all nine conditions answers MERGE.
# No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/release/scripts/standing-yes.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

git init -q "$WORK/repo"
git -C "$WORK/repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m one
HEAD_SHA="$(git -C "$WORK/repo" rev-parse HEAD)"; TREE="$(git -C "$WORK/repo" rev-parse 'HEAD^{tree}')"
mkdir -p "$WORK/repo/.claude"
cfg() { printf '%s\n' "$1" > "$WORK/repo/.claude/ds-config.json"; }
cfg '{"release": {"classifySkill": "classify", "lightRelease": {"standingYes": true}}}'

TOWER=$'Tower: clear\nOn final: #42 release/26-01-15 (draft)\nWaiting: #43 release/26-01-15-2'
# the passing argument set; each case overrides one value
base() {
  PR=42 HEAD_ARG="$HEAD_SHA" REVIEWED="$TREE" CLASS="RELEASE CLASS: LIGHT" CHECKS=green UNRESOLVED=0
  PRESHIP="PRE-SHIP: PASS (2 ran, 0 waived)" PREV=0 DEV="" TOWER_ARG="$TOWER"
}
run() {
  local extra=(); [ -n "$DEV" ] && extra=(--dev-deploy "$DEV")
  (cd "$WORK/repo" && python3 "$HELPER" --pr "$PR" --head "$HEAD_ARG" --reviewed-tree "$REVIEWED" --class "$CLASS" \
    --checks "$CHECKS" --unresolved "$UNRESOLVED" --pre-ship "$PRESHIP" --previous-release "$PREV" ${extra[@]+"${extra[@]}"} --tower "$TOWER_ARG" 2>&1)
}
expect() { # label, expected exit, regex
  local out code; out="$(run)"; code=$?
  if [ "$code" = "$2" ] && printf '%s\n' "$out" | grep -Eq "$3"; then ok "$1"; else bad "$1  (exit $code) $out"; fi
}

base; expect "(1) every condition holds → MERGE" 0 '^MERGE$'
base; DEV=0; expect "(1b) with the dev-deploy wait answered 0 → MERGE" 0 '^MERGE$'
base; PRESHIP="PRE-SHIP: NOTHING TO RUN"; expect "(1c) nothing to pre-ship → MERGE" 0 '^MERGE$'

cfg '{"release": {"classifySkill": "classify"}}'
base; expect "(2) the standing yes is off → ASK" 0 '^ASK the standing yes is off'
cfg '{"release": {"classifySkill": "classify", "lightRelease": {"standingYes": "yes"}}}'
base; expect "(2b) a non-boolean standingYes is off → ASK" 0 '^ASK the standing yes is off'
cfg '{"release": {"classifySkill": "classify", "lightRelease": {"standingYes": true}}}'

base; CLASS="RELEASE CLASS: FULL"; expect "(3) a full release → ASK" 0 '^ASK not a light release \(RELEASE CLASS: FULL\)$'
base; CLASS=""; expect "(3b) no class line → ASK" 0 '^ASK not a light release \(no class line\)$'
base; REVIEWED="0000000000000000000000000000000000000000"; expect "(4) the head's tree differs from the reviewed one → ASK" 0 '^ASK the head.s tree .* differs from the reviewed train tree 000000000000$'
base; HEAD_ARG="deadbeef"; expect "(4b) an unreadable head → ASK" 0 '^ASK the head deadbeef cannot be read$'
base; CHECKS=red; expect "(5) a required check not green → ASK" 0 '^ASK a required check on the head is not green$'
base; UNRESOLVED=1; expect "(6) an unresolved thread → ASK" 0 '^ASK 1 review thread\(s\) unresolved$'
base; PRESHIP="PRE-SHIP: PASS (2 ran, 1 waived)"; expect "(7) a waived pre-ship check → ASK" 0 '^ASK the pre-ship checks did not all pass unwaived'
base; PRESHIP="PRE-SHIP: FAIL golden"; expect "(7b) a failed pre-ship check → ASK" 0 '^ASK the pre-ship checks did not all pass unwaived'
base; PREV=2; expect "(8) the previous release still pending → ASK" 0 '^ASK the previous-release gate answered 2, not 0$'
base; DEV=2; expect "(9) the dev deploy not yet done → ASK" 0 '^ASK the dev-deploy wait answered 2, not 0$'
base; TOWER_ARG=$'Tower: clear\nOn final: #41 release/26-01-14\nWaiting: #42 release/26-01-15'; expect "(10) another release is on final → ASK" 0 '^ASK pull request #42 is not On final'
base; TOWER_ARG=$'On final: #421 release/x'; expect "(10b) #421 on final does not match #42 → ASK" 0 '^ASK pull request #42 is not On final'

base; CLASS="RELEASE CLASS: FULL"; CHECKS=red
expect "(11) several failures → the first in order is named" 0 '^ASK not a light release'

base; CHECKS=amber; expect "(12) a bad argument → ERROR, exit 1" 1 '^ERROR '
out="$(cd "$WORK/repo" && python3 "$HELPER" --pr 42 2>&1)"; code=$?
[ "$code" = 1 ] && printf '%s\n' "$out" | grep -q '^ERROR ' && ok "(12b) missing arguments → ERROR, exit 1" || bad "(12b) (exit $code) $out"
printf '{nope' > "$WORK/repo/.claude/ds-config.json"
base; expect "(13) an unreadable config → ERROR, exit 1" 1 '^ERROR .*cannot be read as JSON'

exit "$FAIL"
