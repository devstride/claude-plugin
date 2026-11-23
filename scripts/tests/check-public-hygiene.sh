#!/bin/bash
# Tests for scripts/check-public-hygiene.sh. Every case gets its own folder shaped by the case (a
# git work tree unless the case says otherwise), scanned against a scratch allow list.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; CHECK="$ROOT/scripts/check-public-hygiene.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
ALLOW="$WORK/allow"
reset_allow() { printf '# scratch\nitem I20130 the example story\nhost docs.devstride.com the public docs\n' > "$ALLOW"; }
reset_allow

# new_case NAME [plain] — a folder with one clean file; a git work tree unless `plain`
new_case() {
  R="$WORK/$1"; F="$R/skills/a/SKILL.md"; mkdir -p "$R/skills/a"; echo "A plain sentence." > "$F"
  [ "${2:-}" = plain ] || git -C "$R" init -q
}
check() { OUT="$(bash "$CHECK" --tree "$R" --allow "$ALLOW" "$@" 2>&1)"; RC=$?; }
# expect LABEL EXIT PATTERN [PATTERN...]
expect() {
  local label="$1" code="$2"; shift 2
  local good=1; [ "$RC" = "$code" ] || good=0
  for p in "$@"; do printf '%s\n' "$OUT" | grep -q -- "$p" || good=0; done
  if [ "$good" = 1 ]; then ok "$label"; else bad "$label — exit $RC: $OUT"; fi
}

new_case clean; check
expect "(1) a clean tree → CLEAN, and nothing else" 0 "^PUBLIC HYGIENE: CLEAN$"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || bad "(1) CLEAN is the only line — $OUT"

new_case item; echo "Fixed in I14321." >> "$F"; check
expect "(2) a tracker number → finding with file and line" 1 \
  "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: item-number in skills/a/SKILL.md:2: Fixed in I14321"

new_case link; echo "see https://claude.ai/code/session_xyz" >> "$F"; check
expect "(3) a session link → finding" 1 "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: session-link in skills/a/SKILL.md:2"

new_case doc-trailer; echo 'Commits carry no `Claude-Session:` trailer here.' >> "$F"; check
expect "(4) text that names the session trailer → not a finding (that kind is gone)" 0 "CLEAN"

new_case host; echo "curl https://api-jane.devstride.dev/mcp and devstride.dev" >> "$F"; check
expect "(5) a personal-stage host and a bare internal domain → two findings" 1 \
  "^PUBLIC HYGIENE: 2 finding(s)$" "^HYGIENE: internal-host in skills/a/SKILL.md:2: .*api-jane.devstride.dev"

new_case home; printf 'run /Users/jane/x\nand /home/jane/dev/repo/file\nand ~/dev/repo/x\n.claude-plugin/plugin.json is fine\n' >> "$F"; check
expect "(6) home paths (macOS, Linux, a home-relative development folder) → three findings; .claude-plugin is not one" 1 \
  "^PUBLIC HYGIENE: 3 finding(s)$" "internal-path in skills/a/SKILL.md:2" "internal-path in skills/a/SKILL.md:3" "internal-path in skills/a/SKILL.md:4"

new_case worktree; echo "edit a/.worktrees/wt1/file" >> "$F"; check
expect "(7) a worktree path → finding" 1 "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: internal-path in skills/a/SKILL.md:2"

new_case encoded; printf '%s\n' '/private/tmp/claude-501/x' 'a -Users-jane-dev-repo folder' '~/.claude/projects/m.md' \
  '/private/var/folders/ab/T/x' > "$R/skills/a/b.md"; check
expect "(8) an agent's encoded session paths → one finding per line" 1 "^PUBLIC HYGIENE: 4 finding(s)$" \
  "internal-path in skills/a/b.md:1" "internal-path in skills/a/b.md:2" "internal-path in skills/a/b.md:3" "internal-path in skills/a/b.md:4"

new_case binary; printf 'PNG\0see https://claude.ai/code/session_abc\0' > "$R/skills/a/shot.png"; git -C "$R" add -A; check
expect "(9) a tracked binary file cannot be shown clean → finding" 1 "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: binary-file in skills/a/shot.png"
printf 'file skills/a/shot.png a screenshot for the README\n' >> "$ALLOW"; check
expect "(10) a binary file the allow list names, with a reason → CLEAN" 0 "CLEAN"
reset_allow

new_case allowed; echo "See I20130 and https://docs.devstride.com/x." >> "$F"; check
expect "(11) an allow-listed example number and public host → CLEAN" 0 "^PUBLIC HYGIENE: CLEAN$"
echo "See I20131 and https://app.devstride.com/x." >> "$F"; check
expect "(12) a number and a host the list does not name are still found" 1 "^PUBLIC HYGIENE: 2 finding(s)$" "item-number.*I20131" "internal-host.*app.devstride.com"

# The tree's own allow file is the default list, and it is scanned like any other file.
new_case own-allow; mkdir -p "$R/scripts"; echo "Fixed in I14321." >> "$F"
printf 'item I14321 an example\n' > "$R/scripts/public-hygiene.allow"
OUT="$(bash "$CHECK" --tree "$R" 2>&1)"; RC=$?
expect "(13) without --allow the list is <dir>/scripts/public-hygiene.allow, and its allowed token is skipped" 0 "CLEAN"

new_case allow-reasons; mkdir -p "$R/scripts"
printf '# from I14399\nitem I14321 used in I14322 at /Users/jane\n' > "$R/scripts/public-hygiene.allow"; check
expect "(14) the allow file's comments and reasons are scanned; only the allowed token is skipped" 1 \
  "^PUBLIC HYGIENE: 3 finding(s)$" "item-number in scripts/public-hygiene.allow:1" "item-number in scripts/public-hygiene.allow:2: .*I14322" \
  "internal-path in scripts/public-hygiene.allow:2"

new_case smuggled; mkdir -p "$R/scripts"
printf 'item https://claude.ai/code/session_x a link\nhost /Users/jane a path\nfile /Users/jane/dev/repo/logo.png the logo\n' > "$R/scripts/public-hygiene.allow"; check
expect "(15) an allow line cannot smuggle another kind: a link, a path or a file line's machine path is scanned" 1 \
  "session-link in scripts/public-hygiene.allow:1" "internal-path in scripts/public-hygiene.allow:2" "internal-path in scripts/public-hygiene.allow:3"

new_case cross-kind; mkdir -p "$R/scripts"
printf 'host I14321.devstride.dev a host\nhost x-Users-jane.devstride.dev a host\nitem I14322 fine\n' > "$R/scripts/public-hygiene.allow"; check
expect "(16) an allowed host is exempt only as a host: a number or session path inside it is still found" 1 \
  "^PUBLIC HYGIENE: 2 finding(s)$" "item-number in scripts/public-hygiene.allow:1" "internal-path in scripts/public-hygiene.allow:2"

new_case badallow; printf 'item\n' > "$WORK/bad-allow"
OUT="$(bash "$CHECK" --tree "$R" --allow "$WORK/bad-allow" 2>&1)"; RC=$?
expect "(17) an allow line without a reason → exit 2, never a silent allow" 2 "allow list line 1"
printf 'item https://claude.ai/code/session_x a link\n' > "$WORK/smuggle-allow"
OUT="$(bash "$CHECK" --tree "$R" --allow "$WORK/smuggle-allow" 2>&1)"; RC=$?
expect "(18) an allow list whose token breaks its kind's grammar is refused, exit 2" 2 "allow list line 1"

new_case ignored; printf '__pycache__/\n' > "$R/.gitignore"; mkdir -p "$R/skills/a/__pycache__"
printf 'PYC\0I14321 /Users/jane\0' > "$R/skills/a/__pycache__/x.cpython-312.pyc"; echo "Fixed in I14321." > "$R/skills/a/__pycache__/note.txt"; check
expect "(19) ignored __pycache__ files in a work tree are not read" 0 "^PUBLIC HYGIENE: CLEAN$"
echo "Fixed in I14322." > "$R/skills/a/new.md"; check
expect "(20) an untracked file git does not ignore is read" 1 "^PUBLIC HYGIENE: 1 finding(s)$" "item-number in skills/a/new.md:1"

new_case plain plain; mkdir -p "$R/skills/a/__pycache__"; echo "Fixed in I14321." > "$R/skills/a/__pycache__/note.txt"
printf '__pycache__/\n' > "$R/.gitignore"; printf 'PNG\0x' > "$R/skills/a/logo.png"; check
expect "(21) a folder that is not a git work tree is walked whole: nothing is ignored there" 1 \
  "^PUBLIC HYGIENE: 2 finding(s)$" "item-number in skills/a/__pycache__/note.txt:1" "binary-file in skills/a/logo.png"

# A folder git itself ignores would list no files; it is walked instead of passing unread.
new_case outer; printf 'export/\n' > "$R/.gitignore"; mkdir -p "$R/export/skills"; echo "Fixed in I14321." > "$R/export/skills/x.md"
OUT="$(bash "$CHECK" --tree "$R/export" --allow "$ALLOW" 2>&1)"; RC=$?
expect "(22) a folder git ignores is walked, never passed unread; paths are relative to the folder" 1 \
  "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: item-number in skills/x.md:1"

new_case subfolder; mkdir -p "$R/plugin/skills"; echo "Fixed in I14321." > "$R/plugin/skills/x.md"; echo "Fixed in I14322." > "$R/outside.md"
OUT="$(bash "$CHECK" --tree "$R/plugin" --allow "$ALLOW" 2>&1)"; RC=$?
expect "(23) a subfolder of a work tree: only its files, paths relative to it" 1 \
  "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: item-number in skills/x.md:1"

new_case self; mkdir -p "$R/scripts/tests" "$R/other/scripts"
echo "I14321 /Users/jane" > "$R/scripts/check-public-hygiene.sh"; echo "I14321" > "$R/scripts/tests/check-public-hygiene.sh"; check
expect "(24) the script and its test are exempt" 0 "CLEAN"
echo "I14321" > "$R/other/scripts/check-public-hygiene.sh"; check
expect "(25) …by their path inside the folder only: the same name elsewhere is scanned" 1 \
  "^PUBLIC HYGIENE: 1 finding(s)$" "item-number in other/scripts/check-public-hygiene.sh:1"

new_case names; printf 'Fixed in I14321.\n' > "$R/skills/a/café.md"; printf 'Fixed in I14322.\n' > "$R/skills/a/a\"b c.md"; check
expect "(26) files whose names git would quote (non-ASCII, a double quote, a space) are scanned" 1 \
  "^PUBLIC HYGIENE: 2 finding(s)$" "item-number in skills/a/café.md:1" 'item-number in skills/a/a"b c.md:1'

new_case separators; printf 'ok\rFixed in I14321\nx\fin I14322\ny\342\200\250see I14323\n' > "$R/skills/a/b.md"; check
expect "(27) carriage returns, form feeds and Unicode separators inside a line hide nothing" 1 \
  "^PUBLIC HYGIENE: 3 finding(s)$" "item-number in skills/a/b.md:1" "item-number in skills/a/b.md:2" "item-number in skills/a/b.md:3"

new_case link-target; ln -s /Users/jane/dev/repo/x "$R/skills/a/link"; check
expect "(28) a link's target text is scanned" 1 "internal-path in skills/a/link:1"

new_case deleted; echo "Fixed in I14321." > "$R/skills/a/gone.md"; git -C "$R" add -A; rm "$R/skills/a/gone.md"; check
expect "(29) a tracked file deleted from the working copy is not a finding" 0 "CLEAN"

new_case old-options
for opt in --base --head --branch --title --body-file; do
  OUT="$(bash "$CHECK" --tree "$R" --allow "$ALLOW" "$opt" x 2>&1)"; RC=$?
  expect "(30) the old option $opt is refused, exit 2" 2 "unknown argument: $opt"
done
OUT="$(bash "$CHECK" --allow "$ALLOW" 2>&1)"; RC=$?
expect "(31) no --tree → exit 2" 2 "--tree <dir> is required"
OUT="$(bash "$CHECK" --tree "$WORK/no-such-folder" --allow "$ALLOW" 2>&1)"; RC=$?
expect "(32) a folder that does not exist → exit 2" 2 "not a folder"
OUT="$(bash "$CHECK" --tree "$R" 2>&1)"; RC=$?
expect "(33) a folder without an allow list, and none named → exit 2" 2 "cannot read the allow list"

# The real tree passes with its own allow list, from any directory.
OUT="$(cd / && bash "$CHECK" --tree "$ROOT" 2>&1)"; RC=$?
expect "(34) this plugin's own tree → CLEAN" 0 "^PUBLIC HYGIENE: CLEAN$"

# A workflow definition is read like every other file: a tracker number in workflows/ is found.
new_case workflow; mkdir -p "$R/workflows"
printf '{"id": "demo", "summary": "Fixed in I%s."}\n' "14321" > "$R/workflows/demo.json"
check
expect "(35) a tracker number in a workflows/ definition → finding with file and line" 1 \
  "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: item-number in workflows/demo.json:1:"

# A name is published too: a tracker number in a file name is a finding with no line number, even
# when the file's content is clean; an allowed example number in a name is not.
new_case name; NAMED="skills/a/notes-I$(printf '%s' 14321).md"
echo "A plain sentence." > "$R/$NAMED"; echo "A plain sentence." > "$R/skills/a/notes-I20130.md"; check
expect "(36) a tracker number in a file name → finding naming the path, no line" 1 \
  "^PUBLIC HYGIENE: 1 finding(s)$" "^HYGIENE: item-number in $NAMED: $NAMED$"

exit $FAIL
