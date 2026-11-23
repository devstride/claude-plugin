#!/bin/bash
# Tests for scripts/check-version-bump.sh. Every case gets its own repository: a base commit at
# 1.0.0 carrying the release tag devstride--v1.0.0, then one head commit shaped by the case. The
# whole set runs twice: with the plugin at the repository root, and with it under claude-plugin/
# beside files of a larger repository. $R is the repository, $P the plugin directory inside it.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; CHECK="$ROOT/scripts/check-version-bump.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
SUB=""; LAYOUT="root"

# set_version V — plugin.json, and README's line in its shipped `Current version: **x.y.z**` shape
set_version() {
  printf '{\n  "name": "devstride",\n  "version": "%s"\n}\n' "$1" > "$P/.claude-plugin/plugin.json"
  printf 'Current version: **%s** — see [CHANGELOG.md](CHANGELOG.md) for what changed, and\n' "$1" > "$P/README.md"
}
# plugin_tree — the plugin's files at 1.0.0, uncommitted
plugin_tree() {
  mkdir -p "$P/.claude-plugin" "$P/skills/a" "$P/scripts"; set_version 1.0.0
  echo one > "$P/skills/a/SKILL.md"; echo one > "$P/scripts/tool.sh"
  mkdir -p "$P/skills/update/scripts"; cp "$ROOT/skills/update/scripts/update-plugin.py" "$P/skills/update/scripts/update-plugin.py"
  printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] — 2026-01-01\n' > "$P/CHANGELOG.md"
}
# empty_repo NAME — a repository holding only what surrounds the plugin (nothing, at the root layout)
empty_repo() {
  R="$WORK/$LAYOUT/$1"; P="$R${SUB:+/$SUB}"; mkdir -p "$R"; git -C "$R" init -q -b master
  if [ -n "$SUB" ]; then mkdir -p "$R/backend"; echo app > "$R/backend/app.ts"; echo host > "$R/README.md"; fi
}
new_case() {
  empty_repo "$1"; plugin_tree
  git -C "$R" add -A; git -C "$R" commit -qm base; git -C "$R" tag devstride--v1.0.0
  BASE="$(git -C "$R" rev-parse HEAD)"
}
changelog_heading() { printf '\n## [%s] — 2026-02-01\n' "$1" >> "$P/CHANGELOG.md"; }
# check — commit the case's change and run the check from outside the repository
check() {
  git -C "$R" add -A; git -C "$R" commit -qm head
  OUT="$(cd "$WORK" && bash "$CHECK" --plugin-dir "$P" --base "$BASE" 2>&1)"; RC=$?
}
# check_in_flight ARG... — as check, with extra arguments (the --in-flight refs)
check_in_flight() {
  git -C "$R" add -A; git -C "$R" commit -qm head
  OUT="$(cd "$WORK" && bash "$CHECK" --plugin-dir "$P" --base "$BASE" "$@" 2>&1)"; RC=$?
}
# in_flight_case NAME — the base at 1.0.0, then a release on its way at 1.1.0 (a shipped change, a
# complete bump) that origin/next and origin/release/01-01 point at; the head starts from it
in_flight_case() {
  new_case "$1"; echo two > "$P/skills/a/SKILL.md"; set_version 1.1.0; changelog_heading 1.1.0
  git -C "$R" add -A; git -C "$R" commit -qm "a release on its way"
  git -C "$R" update-ref refs/remotes/origin/next HEAD; git -C "$R" update-ref refs/remotes/origin/release/01-01 HEAD
}
# expect LABEL EXIT PATTERN
expect() {
  if [ "$RC" = "$2" ] && printf '%s\n' "$OUT" | grep -q -- "$3"; then ok "[$LAYOUT] $1"; else bad "[$LAYOUT] $1 — exit $RC: $OUT"; fi
}

run_set() {
new_case bumped; echo two > "$P/skills/a/SKILL.md"; set_version 1.1.0; changelog_heading 1.1.0; check
expect "(1) skill change with a complete bump, README in its shipped **x.y.z** shape → ok" 0 "bumped from 1.0.0"

new_case unbumped; echo two > "$P/skills/a/SKILL.md"; check
expect "(2) skill change without a bump → refused, names the file" 1 "without a version bump.*skills/a/SKILL.md"

new_case readme-stale; echo two > "$P/skills/a/SKILL.md"; set_version 1.1.0; changelog_heading 1.1.0
printf 'Current version: **1.0.0** — left behind\n' > "$P/README.md"; check
expect "(3) README line left behind → refused, names both versions" 1 "says 1.0.0, plugin.json says 1.1.0"

new_case no-heading; echo two > "$P/skills/a/SKILL.md"; set_version 1.1.0; check
expect "(4) bump without a CHANGELOG heading → refused" 1 "CHANGELOG.md has no"

new_case tooling-only; echo two > "$P/scripts/tool.sh"; check
expect "(5) maintainer-script change after a release, no bump → ok, not 'already released'" 0 "no bump required"

new_case new-component; printf '{}\n' > "$P/.mcp.json"; check
expect "(6) a new root-level plugin component without a bump → refused, names it" 1 "without a version bump.*\.mcp\.json"

new_case docs-only; printf 'Current version: **1.0.0** — one clarified sentence\n' > "$P/README.md"
echo "more history" >> "$P/CHANGELOG.md"; check
expect "(7) README/CHANGELOG-only change → ok, no bump required" 0 "no bump required"

new_case moved-out; git -C "$P" mv skills/a/SKILL.md scripts/SKILL.md; check
expect "(8) a skill moved into scripts/ still ships (it leaves the release) → refused" 1 "without a version bump.*skills/a/SKILL.md"

new_case escaped; printf 'x\n' > "$P/scripts/café tool.sh"; check
expect "(9) a scripts/ file with an accented, spaced name → still maintainer tooling, no bump" 0 "no bump required"

new_case unlisted-base; printf '# a release older than 3.5.1 carries no inert list\n' > "$P/skills/update/scripts/update-plugin.py"
git -C "$R" commit -qam "base without the list"; BASE="$(git -C "$R" rev-parse HEAD)"
echo two > "$P/scripts/tool.sh"; check
expect "(10) after a release with no inert list, a scripts/ change needs a bump — the updater's strict rule" 1 "without a version bump.*scripts/tool.sh"

new_case maintainer-folders; mkdir -p "$P/.claude" "$P/.github/workflows"
printf '{}\n' > "$P/.claude/ds-config.json"; printf 'name: x\n' > "$P/.github/workflows/x.yml"; printf '@AGENTS.md\n' > "$P/CLAUDE.md"; check
expect "(11) .claude/, .github/ and CLAUDE.md after a release that lists them → no bump required" 0 "no bump required"

new_case older-list; python3 - "$P/skills/update/scripts/update-plugin.py" <<'PY'
import re, sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"INERT_DIRS = \([^)]*\)", 'INERT_DIRS = ("scripts/",)', s, count=1))
PY
git -C "$R" commit -qam "base listing only scripts/"; BASE="$(git -C "$R" rev-parse HEAD)"
mkdir -p "$P/.claude"; printf '{}\n' > "$P/.claude/ds-config.json"; check
expect "(12) after a release listing only scripts/, a .claude/ change needs a bump — the widening ships first" 1 "without a version bump.*\.claude/ds-config.json"


# --- the base is read from the tree the plugin is in, never from tags ---
new_case base-line; echo two > "$P/scripts/tool.sh"; check
expect "(13) the first line names the base used" 0 "^base: $BASE (merge base "

empty_repo no-tags; plugin_tree; git -C "$R" add -A; git -C "$R" commit -qm base; BASE="$(git -C "$R" rev-parse HEAD)"
echo two > "$P/skills/a/SKILL.md"; set_version 1.1.0; changelog_heading 1.1.0; check
expect "(14) no release tag anywhere, a complete bump → ok" 0 "bumped from 1.0.0"
echo three > "$P/skills/a/SKILL.md"; BASE="$(git -C "$R" rev-parse HEAD)"; check
expect "(14b) no release tag anywhere, a skill change without a bump → refused" 1 "without a version bump.*skills/a/SKILL.md"

new_case tag-ignored; git -C "$R" tag devstride--v9.0.0; echo two > "$P/skills/a/SKILL.md"; set_version 1.1.0; changelog_heading 1.1.0; check
expect "(15) a newer release tag is not consulted: the publisher owns tags" 0 "bumped from 1.0.0"

# --- the import fallback: the base ref does not hold the plugin yet ---
# import_case NAME — master without the plugin, then a branch whose first commit imports it at 1.0.0
import_case() {
  empty_repo "$1"; echo seed > "$R/seed.txt"; git -C "$R" add -A; git -C "$R" commit -qm "before the plugin"
  git -C "$R" checkout -q -b work; plugin_tree
  git -C "$R" add -A; git -C "$R" commit -qm "plugin import: v1.0.0 at 0000000"; BASE=master
}
import_case import-tooling; echo two > "$P/scripts/tool.sh"; check
expect "(16) base without the plugin → the import commit is the base, and the first line says so" 0 "^base: plugin import commit "
expect "(16b) … and a maintainer-script change after the import needs no bump" 0 "no bump required"

import_case import-unbumped; echo two > "$P/skills/a/SKILL.md"; check
expect "(17) after the import, a skill change without a bump → refused" 1 "without a version bump.*skills/a/SKILL.md"

import_case import-two-stories; echo two > "$P/skills/a/SKILL.md"; set_version 1.1.0; changelog_heading 1.1.0
git -C "$R" add -A; git -C "$R" commit -qm "story one"; mkdir -p "$P/skills/b"; echo new > "$P/skills/b/SKILL.md"; check
expect "(18) two changes after the import add up to one version above the imported one" 0 "bumped from 1.0.0"

import_case import-body-mention; echo two > "$P/skills/a/SKILL.md"
git -C "$R" add -A; git -C "$R" commit -qm "story" -m "plugin import is mentioned in this body only"; echo three > "$P/scripts/tool.sh"; check
expect "(19) 'plugin import' in a message body is not an import: the skill change still needs a bump" 1 "without a version bump.*skills/a/SKILL.md"

import_case resync; IMPORT1="$(git -C "$R" rev-parse --short HEAD)"; echo two > "$P/scripts/tool.sh"
git -C "$R" add -A; git -C "$R" commit -qm "tooling"
echo urgent > "$P/skills/a/SKILL.md"; set_version 1.0.1; changelog_heading 1.0.1
git -C "$R" add -A; git -C "$R" commit -qm "plugin import: re-sync v1.0.1 at 1111111"; RESYNC="$(git -C "$R" rev-parse --short HEAD)"
echo three > "$P/scripts/tool.sh"; check
expect "(20) a later re-sync import moves the base to itself (not the first import $IMPORT1)" 0 "^base: plugin import commit $RESYNC "
expect "(20b) … so a maintainer-script change after it reads as 1.0.1 with no bump required" 0 "ok version 1.0.1 (0 shipped"
echo four > "$P/skills/a/SKILL.md"; check
expect "(20c) … and a skill change after it without a bump is refused against 1.0.1" 1 "without a version bump (still 1.0.1)"

# --- rule 3: a version already on its way to release is not open to this change ---
in_flight_case in-flight-shipped; echo three > "$P/skills/a/SKILL.md"; check_in_flight --in-flight origin/next
expect "(25) a shipped change at the version an in-flight ref already carries → refused, names the ref" 1 "origin/next already carries 1.1.0 on its way to release.*skills/a/SKILL.md"

in_flight_case in-flight-above; echo three > "$P/skills/a/SKILL.md"; set_version 1.2.0; changelog_heading 1.2.0; check_in_flight --in-flight origin/next
expect "(26) … and bumped above it → ok" 0 "bumped from 1.0.0"
expect "(26b) … the in-flight ref is named with its version" 0 "^in flight: origin/next at 1.1.0 (1 shipped"

in_flight_case in-flight-tooling; echo two > "$P/scripts/tool.sh"; check_in_flight --in-flight origin/next
expect "(27) a maintainer-script change at the in-flight version → no bump required" 0 "in flight: origin/next at 1.1.0 (0 shipped"

new_case in-flight-behind; git -C "$R" update-ref refs/remotes/origin/next HEAD
echo two > "$P/skills/a/SKILL.md"; set_version 1.1.0; changelog_heading 1.1.0; check_in_flight --in-flight origin/next
expect "(28) an open version above what is in flight → ok, adds up as before" 0 "bumped from 1.0.0"

in_flight_case in-flight-pattern; echo three > "$P/skills/a/SKILL.md"; check_in_flight --in-flight 'origin/release/*'
expect "(29) a pattern matches the remote-tracking release branches → refused, names the branch" 1 "origin/release/01-01 already carries 1.1.0"

in_flight_case in-flight-self; git -C "$R" checkout -q -b release/01-01; echo three > "$P/skills/a/SKILL.md"
check_in_flight --in-flight 'origin/release/*'
expect "(29b) a review fix on the release branch itself is not refused by its own copy" 0 "^in flight: origin/release/01-01 is this branch; not compared with itself"
git -C "$R" checkout -q -b other-work; echo four > "$P/skills/a/SKILL.md"
check_in_flight --in-flight origin/next --in-flight 'origin/release/*'
expect "(29c) … but any other branch at that version is still refused" 1 "already carries 1.1.0 on its way to release"

in_flight_case in-flight-missing; echo three > "$P/skills/a/SKILL.md"; set_version 1.2.0; changelog_heading 1.2.0
check_in_flight --in-flight origin/nowhere --in-flight 'origin/none/*'
expect "(30) an in-flight ref or pattern that names nothing is skipped" 0 "bumped from 1.0.0"

empty_repo no-import; echo seed > "$R/seed.txt"; git -C "$R" add -A; git -C "$R" commit -qm "before the plugin"
git -C "$R" checkout -q -b work; plugin_tree; git -C "$R" add -A; git -C "$R" commit -qm "copied by hand"; BASE=master
echo two > "$P/scripts/tool.sh"; check
expect "(21) base without the plugin and no import commit → usage error, never a silent pass" 2 "no commit whose subject starts 'plugin import'"
}

run_set
SUB="claude-plugin"; LAYOUT="claude-plugin/"
run_set

# only in a larger repository: what changes outside the plugin directory is not the plugin's business
new_case outside-only; echo changed > "$R/backend/app.ts"; echo changed > "$R/README.md"; mkdir -p "$R/skills/a"; echo stray > "$R/skills/a/SKILL.md"; check
expect "(22) changes outside the plugin directory (even a root skills/ folder) → no bump required" 0 "0 shipped file(s) changed; no bump required"
new_case outside-and-inside; echo changed > "$R/backend/app.ts"; echo two > "$P/skills/a/SKILL.md"; check
expect "(23) a skill change beside outside changes → refused, naming only the plugin's path" 1 "without a version bump (still 1.0.0): skills/a/SKILL.md$"

OUT="$(cd "$WORK" && bash "$CHECK" --plugin-dir "$P" --in-flight 2>&1)"; RC=$?
expect "(31) --in-flight with no value → usage error" 2 "--in-flight needs a value"

# the default base is origin/master
new_case default-base; git -C "$R" update-ref refs/remotes/origin/master HEAD; echo two > "$P/skills/a/SKILL.md"
git -C "$R" add -A; git -C "$R" commit -qm head; OUT="$(cd "$WORK" && bash "$CHECK" --plugin-dir "$P" 2>&1)"; RC=$?
expect "(24) with no --base the check compares against origin/master" 1 "^base: origin/master (merge base "

exit $FAIL
