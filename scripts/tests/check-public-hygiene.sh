#!/bin/bash
# Tests for scripts/check-public-hygiene.sh. Every case gets its own repository with one base
# commit and one head commit shaped by the case, checked against a scratch allow list.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; CHECK="$ROOT/scripts/check-public-hygiene.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
ALLOW="$WORK/allow"
printf '# scratch\nitem I20130 the example story\nhost docs.devstride.com the public docs\n' > "$ALLOW"

new_case() {
  R="$WORK/$1"; mkdir -p "$R/skills/a"; git -C "$R" init -q
  echo base > "$R/skills/a/SKILL.md"; git -C "$R" add -A; git -C "$R" commit -qm base
  BASE="$(git -C "$R" rev-parse HEAD)"
}
# commit MESSAGE — commit everything with that message
commit() { git -C "$R" add -A; git -C "$R" commit -qm "$1"; }
check() { OUT="$(cd "$R" && bash "$CHECK" --base "$BASE" --allow "$ALLOW" "$@" 2>&1)"; RC=$?; }
# expect LABEL EXIT PATTERN [PATTERN...]
expect() {
  local label="$1" code="$2"; shift 2
  local good=1; [ "$RC" = "$code" ] || good=0
  for p in "$@"; do printf '%s\n' "$OUT" | grep -q -- "$p" || good=0; done
  if [ "$good" = 1 ]; then ok "$label"; else bad "$label — exit $RC: $OUT"; fi
}

new_case clean; echo "A plain sentence; see I20130 and https://docs.devstride.com/x." >> "$R/skills/a/SKILL.md"
commit "docs: clarify a step"; check --branch jane/26-11-02/clarify --title "Clarify a step"
expect "(1) allowed example number and public host, clean branch and title → CLEAN" 0 "^PUBLIC HYGIENE: CLEAN$"

new_case item; echo "Fixed in I14321." >> "$R/skills/a/SKILL.md"; commit "fix: a thing"; check
expect "(2) a tracker number in an added line → finding with file and line" 1 \
  "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: item-number in skills/a/SKILL.md:2: Fixed in I14321"

new_case message; echo more >> "$R/skills/a/SKILL.md"
commit "$(printf 'fix: a thing\n\nCo-Authored-By: A <a@example.com>\nClaude-Session: https://claude.ai/code/session_abc')"; check
expect "(3) a session trailer and link in a commit message → both found; Co-Authored-By is fine" 1 \
  "^PUBLIC HYGIENE: 2 finding(s)$" "session-trailer in commit" "session-link in commit"

new_case doc-trailer; echo 'Commits carry no `Claude-Session:` trailer here.' >> "$R/skills/a/SKILL.md"; commit "docs: say so"; check
expect "(4) skill text that names the trailer → not a finding (trailers count only in messages)" 0 "CLEAN"

new_case file-link; echo "see https://claude.ai/code/session_xyz" >> "$R/skills/a/SKILL.md"; commit "docs: x"; check
expect "(5) a session link in an added line → finding" 1 "session-link in skills/a/SKILL.md:2"

new_case host; echo "curl https://api-jane.devstride.dev/mcp and devstride.dev" >> "$R/skills/a/SKILL.md"; commit "docs: x"; check
expect "(6) a personal-stage host and a bare internal domain → two findings" 1 \
  "^PUBLIC HYGIENE: 2 finding(s)$" "internal-host.*api-jane.devstride.dev"

new_case paths; printf 'run ~/dev/repo/x and /Users/jane/x and a/.worktrees/wt1\n.claude-plugin/plugin.json is fine\n' >> "$R/skills/a/SKILL.md"
commit "docs: x"; check
expect "(7) home, development and worktree paths → three findings; .claude-plugin is not one" 1 \
  "^PUBLIC HYGIENE: 3 finding(s)$" "internal-path in skills/a/SKILL.md:2"

new_case meta; echo fine >> "$R/skills/a/SKILL.md"; commit "docs: x"
printf 'Closes I14321.\n' > "$WORK/body.md"
check --branch jane/26-11-02/I14321-thing --title "I14321 do a thing" --body-file "$WORK/body.md"
expect "(8) a number in the branch, title and body → three findings, each named by where" 1 \
  "^PUBLIC HYGIENE: 3 finding(s)$" "item-number in branch" "item-number in title" "item-number in body"

new_case removed; echo "Fixed in I14321." >> "$R/skills/a/SKILL.md"; git -C "$R" add -A; git -C "$R" commit -qm "add"
BASE="$(git -C "$R" rev-parse HEAD)"; echo base > "$R/skills/a/SKILL.md"; commit "docs: remove the number"; check
expect "(9) a REMOVED line is not scanned: taking a leak out is never blocked" 0 "CLEAN"

new_case self; mkdir -p "$R/scripts/tests"; echo "item I14321 a reason" > "$R/scripts/public-hygiene.allow"
echo "I14321" > "$R/scripts/tests/check-public-hygiene.sh"; commit "chore: the check's own files"; check
expect "(10) the check's own test is not scanned, nor the token an allow line allows" 0 "CLEAN"

new_case badref; check --head no-such-ref
expect "(11) an unknown ref → exit 2" 2 "unknown ref"

new_case badallow; printf 'item\n' > "$WORK/bad-allow"
OUT="$(cd "$R" && bash "$CHECK" --base "$BASE" --allow "$WORK/bad-allow" 2>&1)"; RC=$?
expect "(12) an allow line without a reason → exit 2, never a silent allow" 2 "allow list line 1"

new_case quoted; printf 'Fixed in I14321.\n' > "$R/skills/a/café.md"; printf 'Fixed in I14322.\n' > "$R/skills/a/a\"b.md"
commit "docs: x"; check
expect "(14) files whose names git quotes (non-ASCII, a double quote) are still scanned" 1 \
  "^PUBLIC HYGIENE: 2 finding(s)$" "item-number in skills/a/café.md:1" 'item-number in skills/a/a"b.md:1'

new_case plusplus; printf 'one\n++ not a header\nFixed in I14321.\n' > "$R/skills/a/b.md"; commit "docs: x"; check
expect "(15) an added line starting with '++ ' is content; the lines after it are still scanned" 1 \
  "^PUBLIC HYGIENE: 1 finding(s)$" "item-number in skills/a/b.md:3"

new_case separators; printf 'ok\rFixed in I14321\nx\fin I14322\ny\342\200\250see I14323\n' > "$R/skills/a/b.md"; commit "docs: x"; check
expect "(16) carriage returns, form feeds and Unicode separators inside a line hide nothing" 1 \
  "^PUBLIC HYGIENE: 3 finding(s)$" "item-number in skills/a/b.md:1" "item-number in skills/a/b.md:3"

new_case encoded; printf '%s\n' '/private/tmp/claude-501/-Users-jane-dev-repo/x' '~/.claude/projects/-Users-jane-dev-repo/m.md' \
  '/home/jane/dev/repo/file' '/private/var/folders/ab/T/x' > "$R/skills/a/b.md"; commit "docs: x"; check
expect "(17) agent session paths and Linux home folders are internal paths" 1 \
  "internal-path in skills/a/b.md:1" "internal-path in skills/a/b.md:2" "internal-path in skills/a/b.md:3" "internal-path in skills/a/b.md:4"

new_case binary; printf 'PNG\0see https://claude.ai/code/session_abc\0' > "$R/skills/a/shot.png"; commit "docs: x"; check
expect "(18) a binary file cannot be shown clean → finding" 1 "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: binary-file in skills/a/shot.png"
printf 'file skills/a/shot.png a screenshot for the README\n' >> "$ALLOW"; check
expect "(19) a binary file the allow list names, with a reason → CLEAN" 0 "CLEAN"
printf '# scratch\nitem I20130 the example story\nhost docs.devstride.com the public docs\n' > "$ALLOW"

new_case allow-reasons; mkdir -p "$R/scripts"
printf '# from I14399\nitem I14321 used in I14322 at /Users/jane\n' > "$R/scripts/public-hygiene.allow"; commit "chore: allow"; check
expect "(20) the allow file's comments and reasons are scanned; only the allowed token is skipped" 1 \
  "^PUBLIC HYGIENE: 3 finding(s)$" "item-number in scripts/public-hygiene.allow:1" "item-number in scripts/public-hygiene.allow:2: .*I14322"

new_case gitconfig; echo "Fixed in I14321." >> "$R/skills/a/SKILL.md"; commit "docs: x"
OUT="$(cd "$R/skills" && GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true \
  GIT_CONFIG_KEY_1=diff.relative GIT_CONFIG_VALUE_1=true GIT_CONFIG_KEY_2=diff.dstPrefix GIT_CONFIG_VALUE_2=new/ \
  bash "$CHECK" --base "$BASE" --allow "$ALLOW" 2>&1)"; RC=$?
expect "(21) a person's diff settings (no prefix, relative, another prefix) cannot hide a finding" 1 \
  "item-number in skills/a/SKILL.md:2"

new_case allow-file-path; mkdir -p "$R/scripts"
printf 'file /Users/jane/dev/repo/logo.png the logo\n' > "$R/scripts/public-hygiene.allow"; commit "chore: allow"; check
expect "(22) a file line's path is scanned: an absolute machine path in it is a finding" 1 "internal-path in scripts/public-hygiene.allow:1"

new_case smuggled; mkdir -p "$R/scripts"
printf 'item https://claude.ai/code/session_x a link\nhost /Users/jane a path\n' > "$R/scripts/public-hygiene.allow"; commit "chore: allow"; check
expect "(23) an allow line whose token is not an item number or host is scanned whole" 1 \
  "session-link in scripts/public-hygiene.allow:1" "internal-path in scripts/public-hygiene.allow:2"
printf 'item https://claude.ai/code/session_x a link\n' > "$WORK/smuggle-allow"
OUT="$(cd "$R" && bash "$CHECK" --base "$BASE" --allow "$WORK/smuggle-allow" 2>&1)"; RC=$?
expect "(24) an allow list whose token breaks its kind's grammar is refused, exit 2" 2 "allow list line 1"

new_case binary-gone; printf 'PNG\0x' > "$R/skills/a/logo"; git -C "$R" add -A; git -C "$R" commit -qm "add"
BASE="$(git -C "$R" rev-parse HEAD)"; git -C "$R" rm -q skills/a/logo; mkdir -p "$R/skills/a/logo"
echo hi > "$R/skills/a/logo/readme.md"; commit "docs: replace"; check
expect "(25) a deleted binary is not a finding, even when a folder now has its name" 0 "CLEAN"

# The real allow list parses, and every line carries a reason.
OUT="$(cd "$ROOT" && bash "$CHECK" --base HEAD --head HEAD 2>&1)"; RC=$?
expect "(13) this repository's allow list parses" 0 "CLEAN"

exit $FAIL
