#!/bin/bash
# Tests for scripts/check-version-bump.sh. Every case gets its own repository: a base commit at
# 1.0.0 carrying the release tag devstride--v1.0.0, then one head commit shaped by the case.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; CHECK="$ROOT/scripts/check-version-bump.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# set_version V — plugin.json, and README's line in its shipped `Current version: **x.y.z**` shape
set_version() {
  printf '{\n  "name": "devstride",\n  "version": "%s"\n}\n' "$1" > "$R/.claude-plugin/plugin.json"
  printf 'Current version: **%s** — see [CHANGELOG.md](CHANGELOG.md) for what changed, and\n' "$1" > "$R/README.md"
}
new_case() {
  R="$WORK/$1"; mkdir -p "$R/.claude-plugin" "$R/skills/a" "$R/scripts"
  git -C "$R" init -q; set_version 1.0.0
  echo one > "$R/skills/a/SKILL.md"; echo one > "$R/scripts/tool.sh"
  printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] — 2026-01-01\n' > "$R/CHANGELOG.md"
  git -C "$R" add -A; git -C "$R" commit -qm base; git -C "$R" tag devstride--v1.0.0
  BASE="$(git -C "$R" rev-parse HEAD)"
}
changelog_heading() { printf '\n## [%s] — 2026-02-01\n' "$1" >> "$R/CHANGELOG.md"; }
check() {
  git -C "$R" add -A; git -C "$R" commit -qm head
  OUT="$(cd "$R" && bash "$CHECK" --base "$BASE" 2>&1)"; RC=$?
}
# expect LABEL EXIT PATTERN
expect() {
  if [ "$RC" = "$2" ] && printf '%s\n' "$OUT" | grep -q -- "$3"; then ok "$1"; else bad "$1 — exit $RC: $OUT"; fi
}

new_case bumped; echo two > "$R/skills/a/SKILL.md"; set_version 1.1.0; changelog_heading 1.1.0; check
expect "(1) skill change with a complete bump, README in its shipped **x.y.z** shape → ok" 0 "bumped from 1.0.0"

new_case unbumped; echo two > "$R/skills/a/SKILL.md"; check
expect "(2) skill change without a bump → refused, names the file" 1 "without a version bump.*skills/a/SKILL.md"

new_case readme-stale; echo two > "$R/skills/a/SKILL.md"; set_version 1.1.0; changelog_heading 1.1.0
printf 'Current version: **1.0.0** — left behind\n' > "$R/README.md"; check
expect "(3) README line left behind → refused, names both versions" 1 "says 1.0.0, plugin.json says 1.1.0"

new_case no-heading; echo two > "$R/skills/a/SKILL.md"; set_version 1.1.0; check
expect "(4) bump without a CHANGELOG heading → refused" 1 "CHANGELOG.md has no"

new_case tooling-only; echo two > "$R/scripts/tool.sh"; check
expect "(5) maintainer-script change after a release, no bump → ok, not 'already released'" 0 "no bump required"

new_case new-component; printf '{}\n' > "$R/.mcp.json"; check
expect "(6) a new root-level plugin component without a bump → refused, names it" 1 "without a version bump.*\.mcp\.json"

new_case docs-only; printf 'Current version: **1.0.0** — one clarified sentence\n' > "$R/README.md"
echo "more history" >> "$R/CHANGELOG.md"; check
expect "(7) README/CHANGELOG-only change → ok, no bump required" 0 "no bump required"

new_case moved-out; git -C "$R" mv skills/a/SKILL.md scripts/SKILL.md; check
expect "(8) a skill moved into scripts/ still ships (it leaves the release) → refused" 1 "without a version bump.*skills/a/SKILL.md"

exit $FAIL
