#!/bin/bash
# Tests for the status-line half of hooks/version-check.sh — the session-start refresh of a
# repository's copied .claude/statusline.sh. The fake plugin omits the update helper, so the version
# half finishes quietly without network after the status-line result is recorded.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$ROOT/hooks/version-check.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export XDG_CACHE_HOME="$WORK/cache"

# A fake plugin root: the hook reads the RUNNING version and the shipped status line from it.
FAKE="$WORK/plugin"; mkdir -p "$FAKE/.claude-plugin" "$FAKE/skills/setup/references"
printf '{"version":"9.9.9"}' > "$FAKE/.claude-plugin/plugin.json"
shipped() { printf '# ds-statusline: managed v%s — marker\necho shipped-%s\n' "$1" "$1" > "$FAKE/skills/setup/references/statusline.sh"; }
shipped 2.8.0

mkrepo() { # mkrepo NAME [STATUSLINE-CONTENT] [CONFIG]
  local d="$WORK/$1" config="${3:-}"; mkdir -p "$d/.claude"; git -C "$d" init -q
  [ -n "${2:-}" ] && printf '%s' "$2" > "$d/.claude/statusline.sh"
  [ -n "$config" ] || config='{}'
  printf '%s' "$config" > "$d/.claude/ds-config.json"
  printf '%s' "$d"
}
run() { CLAUDE_PLUGIN_ROOT="$FAKE" bash "$HOOK" <<< "$(printf '{"cwd":"%s"}' "$1")" 2>/dev/null; }
managed() { printf '# ds-statusline: managed v%s — marker\necho local-%s\n' "$1" "$1"; }

# (1) an older managed copy is replaced, the previous one kept, and it is announced
R="$(mkrepo old "$(managed 2.7.0)")"
OUT="$(run "$R")"
if grep -q 'shipped-2.8.0' "$R/.claude/statusline.sh" && grep -q 'local-2.7.0' "$R/.claude/statusline.sh.bak" \
   && printf '%s' "$OUT" | grep -q 'status line: updated 2.7.0 → 2.8.0'; then
  ok "(1) managed v2.7.0 → replaced with the shipped v2.8.0, .bak kept, one line printed"
else bad "(1) out=$OUT file=$(cat "$R/.claude/statusline.sh" 2>/dev/null)"; fi

# (1b) a later release can safely rotate an existing ordinary backup
shipped 2.9.0
OUT="$(run "$R")"
if grep -q 'shipped-2.9.0' "$R/.claude/statusline.sh" \
   && grep -q 'shipped-2.8.0' "$R/.claude/statusline.sh.bak" \
   && printf '%s' "$OUT" | grep -q 'status line: updated 2.8.0 → 2.9.0'; then
  ok "(1b) a later managed update rotates the existing safe .bak"
else bad "(1b) out=$OUT file=$(cat "$R/.claude/statusline.sh" 2>/dev/null)"; fi
shipped 2.8.0

# (2) an up-to-date copy is left alone and says nothing — silence is the contract
R="$(mkrepo current "$(managed 2.8.0)")"
OUT="$(run "$R")"
if grep -q 'local-2.8.0' "$R/.claude/statusline.sh" && [ ! -f "$R/.claude/statusline.sh.bak" ] \
   && ! printf '%s' "$OUT" | grep -q 'status line'; then
  ok "(2) an already-current copy is untouched and silent"
else bad "(2) out=$OUT"; fi

# (3) a NEWER local copy is never downgraded
R="$(mkrepo newer "$(managed 9.0.0)")"
run "$R" >/dev/null
if grep -q 'local-9.0.0' "$R/.claude/statusline.sh"; then
  ok "(3) a local copy newer than the shipped one is not rolled back"
else bad "(3) $(cat "$R/.claude/statusline.sh")"; fi

# (4) no marker = the owner took the file over; never touched, whatever the version
R="$(mkrepo owned '#!/bin/bash
echo my own status line')"
OUT="$(run "$R")"
if grep -q 'my own status line' "$R/.claude/statusline.sh" && [ ! -f "$R/.claude/statusline.sh.bak" ] \
   && ! printf '%s' "$OUT" | grep -q 'status line:'; then
  ok "(4) a file without the managed marker is never replaced — deleting the line opts out"
else bad "(4) out=$OUT"; fi

# (5) a repo with no status line never gets one created here
R="$(mkrepo none "")"
run "$R" >/dev/null
if [ ! -f "$R/.claude/statusline.sh" ]; then
  ok "(5) no status line present → none created; that needs consent, not a hook"
else bad "(5) a statusline.sh was created"; fi

# (6) statusLine.autoUpdate:false opts the repository out entirely
R="$(mkrepo optout "$(managed 2.7.0)" '{"statusLine":{"autoUpdate":false}}')"
run "$R" >/dev/null
if grep -q 'local-2.7.0' "$R/.claude/statusline.sh"; then
  ok "(6) statusLine.autoUpdate:false → the old copy is kept"
else bad "(6) it was updated anyway"; fi

# (7) the outcome is recorded, so doctor can report what the last session start did
R="$(mkrepo recorded "$(managed 2.7.0)")"
run "$R" >/dev/null
# The record is keyed on the hook's OWN repo path — git's toplevel, which resolves the
# macOS /var -> /private/var symlink; globbing for "some recent record" would pick up another
# case's file and assert against the wrong repository.
TOP=$(git -C "$R" rev-parse --show-toplevel)
KEY=$(printf '%s' "$TOP" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:12])')
REC="$XDG_CACHE_HOME/devstride-plugin/repo-$KEY.json"
if [ -n "$REC" ] && python3 -c 'import json,sys; sys.exit(0 if "updated:2.7.0:2.8.0"==json.load(open(sys.argv[1])).get("statusLine") else 1)' "$REC"; then
  ok "(7) the per-repo record carries statusLine=updated:2.7.0:2.8.0"
else bad "(7) record=$REC"; fi

# (8) the hook still never fails, whatever happened
R="$(mkrepo exitcode "$(managed 2.7.0)")"
if run "$R" >/dev/null; then ok "(8) exit 0 — a session start is never blocked by this hook"
else bad "(8) non-zero exit"; fi

exit $FAIL
