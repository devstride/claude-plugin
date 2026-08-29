#!/bin/bash
# Deterministic tests for doctor's personal status-line override helper.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HELPER="$ROOT/skills/doctor/scripts/statusline-override.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" XDG_STATE_HOME="$WORK/state"; mkdir -p "$HOME/.claude"
unset CLAUDE_CONFIG_DIR

if PYTHONPYCACHEPREFIX="$WORK/pycache" python3 -m py_compile "$HELPER"; then
  ok "(0) helper compiles"
else bad "(0) helper does not compile"; fi

field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
sha_from() { printf '%s' "$1" | field 'd["sha256"]'; }

repo() {
  local root="$WORK/$1"
  mkdir -p "$root/.claude"; git -C "$root" init -q
  git -C "$root" config user.email test@example.invalid
  git -C "$root" config user.name "Status Line Test"
  printf '%s\n' '{"statusLine":{"type":"command","command":"bash .claude/statusline.sh","padding":0},"shared":true}' > "$root/.claude/settings.json"
  printf '%s\n' '#!/bin/bash' '# ds-statusline: managed v3.0.0 — test marker' 'echo "Repo: test"' > "$root/.claude/statusline.sh"
  chmod 755 "$root/.claude/statusline.sh"
  git -C "$root" add .claude/settings.json .claude/statusline.sh
  git -C "$root" commit -qm "add shared status line"
  printf '%s' "$root"
}

# (1) Local inspect discloses only a file digest; removal needs that digest and writes a 0600 backup.
R="$(repo local)"; PERSONAL="$R/.claude/settings.local.json"
printf '%s\n' '#!/bin/bash' 'echo personal' > "$R/personal-status.sh"
printf '%s\n' '{' \
  '  "statusLine": {"type": "command", "command": "bash personal-status.sh", "padding": 1},' \
  '  "permissions": {"allow": ["Read", "Bash(git status)"]},' \
  '  "enabledPlugins": {"devstride@devstride": true}' \
  '}' > "$PERSONAL"; chmod 640 "$PERSONAL"; cp "$PERSONAL" "$WORK/local-before.json"
OUT="$(python3 "$HELPER" inspect --local "$R")"; RC=$?; SHA="$(sha_from "$OUT")"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | field 'd["result"]')" = present ] \
   && ! printf '%s' "$OUT" | grep -q 'personal-status' && cmp -s "$PERSONAL" "$WORK/local-before.json"; then
  ok "(1) local inspect emits a race digest without printing the personal command"
else bad "(1) rc=$RC out=$OUT"; fi

OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA")"; RC=$?
BACKUP="$(printf '%s' "$OUT" | field 'd["backup"]')"
MODE="$(stat -f '%Lp' "$BACKUP" 2>/dev/null || stat -c '%a' "$BACKUP")"
SETTINGS_MODE="$(stat -f '%Lp' "$PERSONAL" 2>/dev/null || stat -c '%a' "$PERSONAL")"
if [ "$RC" -eq 0 ] && [ "$MODE" = 600 ] && [ "$SETTINGS_MODE" = 640 ] \
   && [ "${BACKUP#"$R"/}" = "$BACKUP" ] && ! printf '%s' "$OUT" | grep -q 'personal-status' \
   && python3 - "$PERSONAL" "$BACKUP" <<'PY'
import json, sys
settings, backup = (json.load(open(p)) for p in sys.argv[1:])
expected = {"type": "command", "command": "bash personal-status.sh", "padding": 1}
assert settings == {"permissions":{"allow":["Read","Bash(git status)"]}, "enabledPlugins":{"devstride@devstride":True}}
assert backup == {"statusLine": expected}
PY
then
  if [ -f "$PERSONAL" ] && grep -q 'echo personal' "$R/personal-status.sh"; then
    ok "(2) local remove preserves siblings/mode, keeps files, and returns a private recovery backup"
  else bad "(2) a settings or referenced script file was deleted"; fi
else bad "(2) rc=$RC mode=$MODE out=$OUT"; fi

# (3) User selection resolves from CLAUDE_CONFIG_DIR, not HOME/.claude.
R="$(repo user)"; export CLAUDE_CONFIG_DIR="$WORK/claude-config"; mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"statusLine":{"type":"command","command":"private-user-line"},"theme":"dark"}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
printf '{"sentinel":"home-file"}\n' > "$HOME/.claude/settings.json"
OUT="$(python3 "$HELPER" inspect --user "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --user "$R" --expect-sha256 "$SHA")"; RC=$?
if [ "$RC" -eq 0 ] \
   && python3 -c 'import json,sys; assert json.load(open(sys.argv[1])) == {"theme":"dark"}' "$CLAUDE_CONFIG_DIR/settings.json" \
   && grep -q 'home-file' "$HOME/.claude/settings.json"; then
  ok "(3) --user uses CLAUDE_CONFIG_DIR/settings.json and leaves HOME settings untouched"
else bad "(3) rc=$RC out=$OUT"; fi
unset CLAUDE_CONFIG_DIR

# Without CLAUDE_CONFIG_DIR, --user must use HOME/.claude/settings.json.
R="$(repo user-home)"; PERSONAL="$HOME/.claude/settings.json"
printf '{"statusLine":{"type":"command","command":"home-user-line"},"theme":"light"}\n' > "$PERSONAL"
OUT="$(python3 "$HELPER" inspect --user "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --user "$R" --expect-sha256 "$SHA")"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | field 'd["result"]')" = removed ] \
   && python3 -c 'import json,sys; assert json.load(open(sys.argv[1])) == {"theme":"light"}' "$PERSONAL"; then
  ok "(3a) --user falls back to HOME/.claude/settings.json"
else bad "(3a) rc=$RC out=$OUT"; fi

# Missing personal settings are a normal state: inspect and remove report it without creating anything.
R="$(repo missing)"; PERSONAL="$R/.claude/settings.local.json"
OUT="$(python3 "$HELPER" inspect --local "$R")"; RC=$?; SHA="$(sha_from "$OUT")"
REMOVE_OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA")"; REMOVE_RC=$?
if [ "$RC" -eq 0 ] && [ "$REMOVE_RC" -eq 0 ] \
   && [ "$(printf '%s' "$OUT" | field 'd["result"]')" = missing ] \
   && [ "$(printf '%s' "$REMOVE_OUT" | field 'd["result"]')" = missing ] \
   && [ ! -e "$PERSONAL" ]; then
  ok "(3b) missing local settings → normal no-op without file creation"
else bad "(3b) inspect=$OUT remove=$REMOVE_OUT"; fi

export CLAUDE_CONFIG_DIR="$WORK/missing-claude-config"
R="$(repo missing-user)"; PERSONAL="$CLAUDE_CONFIG_DIR/settings.json"
OUT="$(python3 "$HELPER" inspect --user "$R")"; RC=$?; SHA="$(sha_from "$OUT")"
REMOVE_OUT="$(python3 "$HELPER" remove --user "$R" --expect-sha256 "$SHA")"; REMOVE_RC=$?
if [ "$RC" -eq 0 ] && [ "$REMOVE_RC" -eq 0 ] \
   && [ "$(printf '%s' "$OUT" | field 'd["result"]')" = missing ] \
   && [ "$(printf '%s' "$REMOVE_OUT" | field 'd["result"]')" = missing ] \
   && [ ! -e "$PERSONAL" ]; then
  ok "(3c) missing user settings → normal no-op without file creation"
else bad "(3c) inspect=$OUT remove=$REMOVE_OUT"; fi
unset CLAUDE_CONFIG_DIR

# (4) No top-level key is a byte-for-byte no-op, but remove still requires the inspected digest.
R="$(repo absent)"; PERSONAL="$R/.claude/settings.local.json"
printf '{ "theme" : "light", "nested" : {"statusLine":"not top-level"} }\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/absent-before.json"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA")"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | field 'd["result"]')" = absent ] \
   && cmp -s "$PERSONAL" "$WORK/absent-before.json"; then
  ok "(4) no top-level statusLine → absent and byte-for-byte no-op"
else bad "(4) rc=$RC out=$OUT"; fi

# (5) Invalid, non-object, and duplicate-key JSON are refused without rewriting.
R="$(repo invalid)"; PERSONAL="$R/.claude/settings.local.json"
for CASE in malformed nonobject duplicate; do
  case "$CASE" in
    malformed) printf '{"statusLine":' > "$PERSONAL" ;;
    nonobject) printf '[{"statusLine":"array member"}]\n' > "$PERSONAL" ;;
    duplicate) printf '{"statusLine":"one","statusLine":"two","keep":1}\n' > "$PERSONAL" ;;
  esac
  cp "$PERSONAL" "$WORK/$CASE-before.json"
  OUT="$(python3 "$HELPER" inspect --local "$R" 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '"result":"refused"' \
     && cmp -s "$PERSONAL" "$WORK/$CASE-before.json"; then
    ok "(5-$CASE) $CASE JSON → refused and untouched"
  else bad "(5-$CASE) rc=$RC out=$OUT"; fi
done

# (6) Removal refuses when the working shared repository status line is not already canonical.
R="$(repo guard)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":{"type":"command","command":"mine"},"keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/guard-before.json"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
printf '{"statusLine":{"type":"command","command":"other.sh"}}\n' > "$R/.claude/settings.json"
git -C "$R" add .claude/settings.json; git -C "$R" commit -qm "set noncanonical command"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'canonical statusLine command' \
   && cmp -s "$PERSONAL" "$WORK/guard-before.json"; then
  ok "(6) broken shared status line → personal removal refused"
else bad "(6) rc=$RC out=$OUT"; fi

# A canonical setting is not enough when the managed script renders nothing.
printf '%s\n' '{"statusLine":{"type":"command","command":"bash .claude/statusline.sh"}}' > "$R/.claude/settings.json"
printf '%s\n' '#!/bin/bash' '# ds-statusline: managed v3.0.0 — test marker' 'exit 0' > "$R/.claude/statusline.sh"
chmod 755 "$R/.claude/statusline.sh"
git -C "$R" add .claude/settings.json .claude/statusline.sh; git -C "$R" commit -qm "set empty renderer"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'did not render non-empty' \
   && cmp -s "$PERSONAL" "$WORK/guard-before.json"; then
  ok "(6b) empty managed render → personal removal refused"
else bad "(6b) rc=$RC out=$OUT"; fi

# Shared artifacts hidden from git cannot qualify a personal override for removal.
printf '%s\n' '#!/bin/bash' '# ds-statusline: managed v3.0.0 — test marker' 'echo shared' > "$R/.claude/statusline.sh"
chmod 755 "$R/.claude/statusline.sh"
git -C "$R" add .claude/statusline.sh; git -C "$R" commit -qm "restore renderer"
printf '%s\n' '.claude/statusline.sh' > "$R/.gitignore"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'gitignored' \
   && cmp -s "$PERSONAL" "$WORK/guard-before.json"; then
  ok "(6c) ignored shared script → personal removal refused"
else bad "(6c) rc=$RC out=$OUT"; fi

# A hanging managed script and its children are killed at the short guard timeout.
R="$(repo hanging-render)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/hanging-before.json"
printf '%s\n' '#!/bin/bash' '# ds-statusline: managed v3.0.0 — test marker' 'sleep 30' 'echo too-late' > "$R/.claude/statusline.sh"
chmod 755 "$R/.claude/statusline.sh"
git -C "$R" add .claude/statusline.sh; git -C "$R" commit -qm "set hanging renderer"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"; START="$(date +%s)"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
ELAPSED=$(( $(date +%s) - START ))
if [ "$RC" -eq 2 ] && [ "$ELAPSED" -le 6 ] \
   && printf '%s' "$OUT" | grep -q '3-second safety check' \
   && cmp -s "$PERSONAL" "$WORK/hanging-before.json"; then
  ok "(6d) hanging managed render → process group killed within the short timeout"
else bad "(6d) rc=$RC elapsed=${ELAPSED}s out=$OUT"; fi

# A child may detach into a new session while retaining the output pipes; the helper must still return.
R="$(repo detached-render)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/detached-before.json"
printf '%s\n' '#!/bin/bash' '# ds-statusline: managed v3.0.0 — test marker' \
  "python3 -c 'import os,time; os.setsid(); open(\"detached.pid\",\"w\").write(str(os.getpid())); time.sleep(30)' &" \
  'exit 0' > "$R/.claude/statusline.sh"
chmod 755 "$R/.claude/statusline.sh"; git -C "$R" add .claude/statusline.sh; git -C "$R" commit -qm "set detached renderer"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"; START="$(date +%s)"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
ELAPSED=$(( $(date +%s) - START )); DETACHED_PID="$(cat "$R/detached.pid" 2>/dev/null || true)"
[ -n "$DETACHED_PID" ] && kill "$DETACHED_PID" 2>/dev/null || true
if [ "$RC" -eq 2 ] && [ "$ELAPSED" -le 6 ] \
   && printf '%s' "$OUT" | grep -q '3-second safety check' \
   && cmp -s "$PERSONAL" "$WORK/detached-before.json"; then
  ok "(6e) detached child retaining pipes → helper refuses and returns within its bound"
else bad "(6e) rc=$RC elapsed=${ELAPSED}s out=$OUT"; fi

# (7) A digest mismatch prevents overwriting a settings file changed after inspection.
R="$(repo race)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"old","keep":1}\n' > "$PERSONAL"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
printf '{"statusLine":"new","keep":2}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/race-after.json"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'changed since inspect' \
   && cmp -s "$PERSONAL" "$WORK/race-after.json"; then
  ok "(7) inspect/remove race → stale digest refused, newer bytes preserved"
else bad "(7) rc=$RC out=$OUT"; fi

# (8) Personal settings symlinks and hardlinks are never followed or rewritten.
R="$(repo links)"; PERSONAL="$R/.claude/settings.local.json"; TARGET="$WORK/personal-target.json"
printf '{"statusLine":"linked"}\n' > "$TARGET"; ln -s "$TARGET" "$PERSONAL"
OUT="$(python3 "$HELPER" inspect --local "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'regular non-symlink'; then
  ok "(8) selected settings symlink → refused"
else bad "(8) rc=$RC out=$OUT"; fi
rm "$PERSONAL"; ln "$TARGET" "$PERSONAL"
OUT="$(python3 "$HELPER" inspect --local "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'hard links' && grep -q linked "$TARGET"; then
  ok "(8b) selected settings hardlink → refused and target untouched"
else bad "(8b) rc=$RC out=$OUT"; fi

# (9) A tracked local settings file may be inspected, but is shared source and cannot be rewritten.
R="$(repo tracked-local)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"tracked","keep":1}\n' > "$PERSONAL"
git -C "$R" add .claude/settings.local.json; cp "$PERSONAL" "$WORK/tracked-local-before.json"
OUT="$(python3 "$HELPER" inspect --local "$R")"; RC=$?; SHA="$(sha_from "$OUT")"
REMOVE_OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; REMOVE_RC=$?
if [ "$RC" -eq 0 ] && [ "$REMOVE_RC" -eq 2 ] \
   && printf '%s' "$REMOVE_OUT" | grep -q 'tracked by git' \
   && cmp -s "$PERSONAL" "$WORK/tracked-local-before.json"; then
  ok "(9) tracked local settings → inspect allowed, removal refused and untouched"
else bad "(9) inspect=$OUT remove=$REMOVE_OUT"; fi

# (10) Existing symlinks below the state root cannot redirect a private backup into the repo.
SAVED_XDG_STATE_HOME="$XDG_STATE_HOME"; export XDG_STATE_HOME="$WORK/symlink-state"
R="$(repo cache-symlink)"; PERSONAL="$R/.claude/settings.local.json"
mkdir -p "$XDG_STATE_HOME" "$R/state-escape"; ln -s "$R/state-escape" "$XDG_STATE_HOME/devstride-plugin"
printf '{"statusLine":"cache-link","keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/cache-link-before.json"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'must be a real directory, not a symlink' \
   && cmp -s "$PERSONAL" "$WORK/cache-link-before.json" \
   && [ ! -e "$R/state-escape/statusline-overrides" ]; then
  ok "(10) symlinked state component → refused without backup escape or settings rewrite"
else bad "(10) rc=$RC out=$OUT"; fi
export XDG_STATE_HOME="$SAVED_XDG_STATE_HOME"

# (11) Shared replacements must exist in HEAD and have no staged or working-tree changes.
R="$(repo shared-untracked)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/untracked-before.json"
git -C "$R" rm --cached -q .claude/settings.json .claude/statusline.sh
git -C "$R" commit -qm "remove shared pair from HEAD"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'not committed in HEAD' \
   && cmp -s "$PERSONAL" "$WORK/untracked-before.json"; then
  ok "(11a) untracked shared pair → removal refused"
else bad "(11a) rc=$RC out=$OUT"; fi

R="$(repo shared-staged)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/staged-before.json"
printf '%s\n' '{"statusLine":{"type":"command","command":"bash .claude/statusline.sh"},"staged":true}' > "$R/.claude/settings.json"
git -C "$R" add .claude/settings.json
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'staged changes' \
   && cmp -s "$PERSONAL" "$WORK/staged-before.json"; then
  ok "(11b) staged shared setting → removal refused"
else bad "(11b) rc=$RC out=$OUT"; fi

R="$(repo shared-modified)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/modified-before.json"
printf '%s\n' '# local edit' >> "$R/.claude/statusline.sh"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'uncommitted changes' \
   && cmp -s "$PERSONAL" "$WORK/modified-before.json"; then
  ok "(11c) modified shared script → removal refused"
else bad "(11c) rc=$RC out=$OUT"; fi

R="$(repo shared-clean)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA")"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | field 'd["result"]')" = removed ]; then
  ok "(11d) committed clean shared pair → removal allowed"
else bad "(11d) rc=$RC out=$OUT"; fi

# (12) The highest accessible disableAllHooks value must leave hooks enabled.
R="$(repo hooks-local-disabled)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","disableAllHooks":true,"keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/hooks-local-before.json"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'effective disableAllHooks:true from local' \
   && cmp -s "$PERSONAL" "$WORK/hooks-local-before.json"; then
  ok "(12a) local disableAllHooks:true → removal refused"
else bad "(12a) rc=$RC out=$OUT"; fi

R="$(repo hooks-shared-disabled)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/hooks-shared-before.json"
printf '%s\n' '{"statusLine":{"type":"command","command":"bash .claude/statusline.sh"},"disableAllHooks":true}' > "$R/.claude/settings.json"
git -C "$R" add .claude/settings.json; git -C "$R" commit -qm "disable hooks in shared settings"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'effective disableAllHooks:true from shared project' \
   && cmp -s "$PERSONAL" "$WORK/hooks-shared-before.json"; then
  ok "(12b) shared disableAllHooks:true → removal refused"
else bad "(12b) rc=$RC out=$OUT"; fi

R="$(repo hooks-user-disabled)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/hooks-user-before.json"
export CLAUDE_CONFIG_DIR="$WORK/hooks-user-config"; mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"disableAllHooks":true}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'effective disableAllHooks:true from user' \
   && cmp -s "$PERSONAL" "$WORK/hooks-user-before.json"; then
  ok "(12c) user disableAllHooks:true without a higher value → removal refused"
else bad "(12c) rc=$RC out=$OUT"; fi
unset CLAUDE_CONFIG_DIR

R="$(repo hooks-local-enabled)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","disableAllHooks":false,"keep":1}\n' > "$PERSONAL"
printf '%s\n' '{"statusLine":{"type":"command","command":"bash .claude/statusline.sh"},"disableAllHooks":true}' > "$R/.claude/settings.json"
git -C "$R" add .claude/settings.json; git -C "$R" commit -qm "lower-precedence disable"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA")"; RC=$?
if [ "$RC" -eq 0 ] && python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["disableAllHooks"] is False' "$PERSONAL"; then
  ok "(12d) local false overrides shared true and cleanup preserves the enabling value"
else bad "(12d) rc=$RC out=$OUT"; fi

# (13) User selection and local parent directories cannot escape through the repository or links.
R="$(repo user-inside-repo)"; export CLAUDE_CONFIG_DIR="$R/other-dir"; mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"statusLine":"inside"}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
OUT="$(python3 "$HELPER" inspect --user "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'resolves inside the target repository'; then
  ok "(13a) user config directory inside repository → refused"
else bad "(13a) rc=$RC out=$OUT"; fi
unset CLAUDE_CONFIG_DIR

R="$WORK/local-parent-link"; OUTSIDE="$WORK/local-parent-outside"; mkdir -p "$R" "$OUTSIDE"
git -C "$R" init -q; ln -s "$OUTSIDE" "$R/.claude"; printf '{"statusLine":"escaped"}\n' > "$OUTSIDE/settings.local.json"
OUT="$(python3 "$HELPER" inspect --local "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'repository .claude must be a real directory'; then
  ok "(13b) symlinked local .claude parent → refused before following it"
else bad "(13b) rc=$RC out=$OUT"; fi

R="$(repo user-final-link)"; export CLAUDE_CONFIG_DIR="$WORK/user-final-config"; mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"statusLine":"target"}\n' > "$WORK/user-final-target.json"; ln -s "$WORK/user-final-target.json" "$CLAUDE_CONFIG_DIR/settings.json"
OUT="$(python3 "$HELPER" inspect --user "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'regular non-symlink'; then
  ok "(13c) final user settings symlink → refused instead of resolved and followed"
else bad "(13c) rc=$RC out=$OUT"; fi
unset CLAUDE_CONFIG_DIR

# (14) Status scripts cannot consume unbounded output memory, and timeout teardown remains bounded.
for STREAM in stdout stderr; do
  R="$(repo output-$STREAM)"; PERSONAL="$R/.claude/settings.local.json"
  printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"; cp "$PERSONAL" "$WORK/output-$STREAM-before.json"
  if [ "$STREAM" = stdout ]; then REDIRECT=''; else REDIRECT='>&2'; fi
  printf '%s\n' '#!/bin/bash' '# ds-statusline: managed v3.0.0 — test marker' "yes flood $REDIRECT" > "$R/.claude/statusline.sh"
  chmod 755 "$R/.claude/statusline.sh"; git -C "$R" add .claude/statusline.sh; git -C "$R" commit -qm "set noisy renderer"
  OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"; START="$(date +%s)"
  OUT="$(python3 "$HELPER" remove --local "$R" --expect-sha256 "$SHA" 2>&1)"; RC=$?; ELAPSED=$(( $(date +%s) - START ))
  if [ "$RC" -eq 2 ] && [ "$ELAPSED" -le 6 ] && printf '%s' "$OUT" | grep -q "$STREAM exceeded the 65536-byte safety limit" \
     && cmp -s "$PERSONAL" "$WORK/output-$STREAM-before.json"; then
    ok "(14-$STREAM) noisy $STREAM → bounded and refused"
  else bad "(14-$STREAM) rc=$RC elapsed=${ELAPSED}s out=$OUT"; fi
done
if grep -qF 'remaining = SCRIPT_INSPECT_LIMIT' "$HELPER" && ! grep -qF 'read_text(' "$HELPER" \
   && ! grep -qF '.communicate(' "$HELPER"; then
  ok "(14c) script inspection and timeout teardown use bounded reads without communicate()"
else bad "(14c) bounded script/teardown contract missing"; fi

# (15) A post-rewrite concurrent writer is preserved; stale original bytes never overwrite it.
R="$(repo concurrent-postcheck)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 - "$HELPER" "$R" "$SHA" <<'PY' 2>&1
import importlib.util, os, sys
helper, repository, digest = sys.argv[1:]
spec = importlib.util.spec_from_file_location("statusline_override_test", helper)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
original = module.atomic_compare_exchange_at
calls = 0
def raced(directory_fd, name, expected_raw, expected_metadata, replacement_raw, mode):
    global calls
    result = original(
        directory_fd, name, expected_raw, expected_metadata, replacement_raw, mode
    )
    calls += 1
    if calls == 1:
        fd = os.open(name, os.O_WRONLY | os.O_TRUNC, dir_fd=directory_fd)
        with os.fdopen(fd, "wb") as handle:
            handle.write(b'{"concurrent":true}\n'); handle.flush(); os.fsync(handle.fileno())
    return result
module.atomic_compare_exchange_at = raced
sys.argv = [helper, "remove", "--local", repository, "--expect-sha256", digest]
raise SystemExit(module.main())
PY
)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'concurrent change was preserved' \
   && [ "$(tr -d '\n ' < "$PERSONAL")" = '{"concurrent":true}' ]; then
  ok "(15) concurrent postcheck write → preserved instead of overwritten by rollback"
else bad "(15) rc=$RC out=$OUT file=$(cat "$PERSONAL")"; fi

# A writer landing after the final bound read but before replacement is preserved by atomic exchange.
R="$(repo concurrent-prerewrite)"; PERSONAL="$R/.claude/settings.local.json"
printf '{"statusLine":"mine","keep":1}\n' > "$PERSONAL"
OUT="$(python3 "$HELPER" inspect --local "$R")"; SHA="$(sha_from "$OUT")"
OUT="$(python3 - "$HELPER" "$R" "$SHA" <<'PY' 2>&1
import importlib.util, os, sys
helper, repository, digest = sys.argv[1:]
spec = importlib.util.spec_from_file_location("statusline_override_prerace_test", helper)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
original = module.exchange_names
calls = 0
def raced(directory_fd, left, right):
    global calls
    calls += 1
    if calls == 1:
        fd = os.open(right, os.O_WRONLY | os.O_TRUNC, dir_fd=directory_fd)
        with os.fdopen(fd, "wb") as handle:
            handle.write(b'{"concurrent":"before-exchange"}\n'); handle.flush(); os.fsync(handle.fileno())
    return original(directory_fd, left, right)
module.exchange_names = raced
sys.argv = [helper, "remove", "--local", repository, "--expect-sha256", digest]
raise SystemExit(module.main())
PY
)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'concurrent bytes were preserved' \
   && [ "$(tr -d '\n ' < "$PERSONAL")" = '{"concurrent":"before-exchange"}' ]; then
  ok "(15b) pre-rewrite concurrent write → atomic exchange restores the newer bytes"
else bad "(15b) rc=$RC out=$OUT file=$(cat "$PERSONAL")"; fi

# (16) Doctor and its repair reference carry the helper's complete runtime/consent contract.
DOCTOR="$ROOT/skills/doctor/SKILL.md"; REPAIRS="$ROOT/skills/doctor/references/repairs.md"
INVARIANTS="$ROOT/skills/review/references/delivery-loop-invariants.md"
if grep -qF 'on every invocation' "$DOCTOR" \
   && grep -qF 'inspect --local <repo-root>' "$DOCTOR" \
   && grep -qF 'inspect --user <repo-root>' "$DOCTOR" \
   && grep -qF 'managed > CLI >' "$DOCTOR" \
   && grep -qF 'local > shared project > user' "$DOCTOR" \
   && grep -qF 'ask outside the batch' "$REPAIRS" \
   && grep -qF 'shared already wins here' "$REPAIRS" \
   && grep -qF 'Repositories without their own project status' "$REPAIRS" \
   && grep -qF 'committed in `HEAD`, clean in both index and working tree' "$REPAIRS" \
   && grep -qF 'private durable state directory' "$REPAIRS" \
   && grep -qF 'effective `true` FAILs and blocks cleanup' "$DOCTOR" \
   && grep -qF 'Found / Why it matters / Fix' "$DOCTOR" \
   && grep -qF -- '--expect-sha256 <digest>' "$REPAIRS" \
   && grep -qF 'never replacing that file' "$REPAIRS" \
   && grep -qF 'skills/doctor/references/repairs.md|ask outside the batch' "$INVARIANTS"; then
  ok "(16) doctor integration pins unconditional inspection, precedence, consent, race and recovery"
else bad "(16) doctor/helper prose contract is incomplete"; fi

exit "$FAIL"
