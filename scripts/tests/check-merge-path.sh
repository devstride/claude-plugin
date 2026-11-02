#!/bin/bash
# Tests for scripts/check-merge-path.sh against this repository's own .claude/ds-config.json, plus
# a scratch config for the usage and config-error paths.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; CHECK="$ROOT/scripts/check-merge-path.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
run() { OUT="$(bash "$CHECK" "$@" 2>&1)"; RC=$?; }
# expect LABEL EXIT PATTERN
expect() {
  if [ "$RC" = "$2" ] && printf '%s\n' "$OUT" | head -1 | grep -q -- "$3"; then ok "$1"; else bad "$1 — exit $RC: $OUT"; fi
}

run --head anything --base some-feature-branch
expect "(1) a base with no rules → ALLOWED" 0 "^ALLOWED anything -> some-feature-branch"

run --head jane/26-11-02/epic-faster-reviews --base main --bumps-version yes
expect "(2) an epic branch that bumps the version → ALLOWED as a release" 0 "^ALLOWED .*an epic's release"

run --head jane/26-11-02/epic-faster-reviews --base main
expect "(3) an epic branch without a bump → BLOCKED" 1 "^BLOCKED .*only as a release"

run --head jane/26-11-02/fix-status-line --base main
expect "(4) a dated story or one-off branch → ALLOWED" 0 "^ALLOWED jane/26-11-02/fix-status-line -> main"

run --head jane/hotfix/26-11-02/update-loop --base main
expect "(5) a hotfix branch → ALLOWED" 0 "^ALLOWED .*hotfix"

run --head dependabot/github_actions/actions/checkout-5 --base main
expect "(6) a Dependabot branch → ALLOWED" 0 "^ALLOWED dependabot/"

run --head my-experiment --base main
expect "(7) an undated branch → BLOCKED" 1 "^BLOCKED my-experiment -> main"

run --head my-experiment --base main --labels "documentation,merge-path-override"
expect "(8) the override label admits it, and the line says so" 0 "^ALLOWED .*merge-path-override"

run --head jane/26-11-02 --base main
expect "(9) a date with no slug is not a story branch → BLOCKED" 1 "^BLOCKED"

run --base main
expect "(10) a missing --head → usage, exit 2" 2 "--head"

run --head a --base main --bumps-version maybe
expect "(11) --bumps-version other than yes|no → usage, exit 2" 2 "yes or no"

printf '{"mergePath": "not an object"}\n' > "$WORK/bad.json"
run --head a --base main --config "$WORK/bad.json"
expect "(12) a config without a mergePath object → exit 2, never a fallback" 2 "no mergePath object"

printf '{not json\n' > "$WORK/broken.json"
run --head a --base main --config "$WORK/broken.json"
expect "(13) an unreadable config → exit 2" 2 "cannot read"

exit $FAIL
