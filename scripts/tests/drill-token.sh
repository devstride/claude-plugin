#!/bin/bash
# Tests for skills/setup/scripts/drill-token.py — no network and no real claude: a fake `claude`
# on PATH answers the sign-in request by the token it was given, and records how it was given it.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SC="$ROOT/skills/setup/scripts/drill-token.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SECRET="sk-ant-oat01-test-drill-$$-secret"
mkdir -p "$TMP/bin" "$TMP/repo/.claude"
cat > "$TMP/bin/claude" <<'FAKE'
#!/bin/bash
# fake claude: logs argv and where the token came from, never the token itself
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  auth) [ -n "${FAKE_AUTH_BROKEN:-}" ] && { echo "boom" >&2; exit 1; }; echo "{\"loggedIn\": true, \"authMethod\": \"${FAKE_AUTH_METHOD:-oauth_token}\"}" ;;
  -p)
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && [ -z "$(ls -A "$CLAUDE_CONFIG_DIR")" ] \
      && [ "$(pwd -P)" = "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" ] && echo "config-dir: fresh, and the working directory" >> "$FAKE_LOG"
    echo "stdin bytes: $(head -c 100 | wc -c | tr -d ' ')" >> "$FAKE_LOG"
    if [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$FAKE_GOOD" ]; then echo '{"is_error": false, "result": "ok"}'
    elif [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "sk-ant-oat01-busy" ]; then echo '{"is_error": true, "terminal_reason": "api_error", "api_error_status": 429}'; exit 1
    else echo '{"is_error": true, "terminal_reason": "sk-leak-me", "api_error_status": 401}'; exit 1; fi ;;
  setup-token) echo "Your token: (fake, printed here only)" ;;
esac
FAKE
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/claude.log" FAKE_GOOD="$SECRET"
TOK="$TMP/person/.drill/token"; mkdir -p "$(dirname "$TOK")"
run() { python3 "$SC" "$@" 2>&1; }

# (1) no drillSessions key → N/A, exit 0
echo '{"profile": "standard"}' > "$TMP/repo/.claude/ds-config.json"
OUT="$(run check --config "$TMP/repo/.claude/ds-config.json")"; RC=$?
if [ $RC -eq 0 ] && [ "$OUT" = "DRILL TOKEN: N/A (drillSessions not set)" ]; then ok "(1) key absent → N/A"; else bad "(1) rc=$RC $OUT"; fi
echo '{"drillSessions": null}' > "$TMP/repo/.claude/ds-config.json"
OUT="$(run check --config "$TMP/repo/.claude/ds-config.json")"; RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^DRILL TOKEN: N/A'; then ok "(1b) key null → N/A"; else bad "(1b) rc=$RC $OUT"; fi

# (2) key set, no file → NOT READY with the fix line
printf '{"drillSessions": {"tokenFile": "%s"}}\n' "$TOK" > "$TMP/repo/.claude/ds-config.json"
OUT="$(run check --config "$TMP/repo/.claude/ds-config.json")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q '^DRILL TOKEN: NOT READY — no token file' \
   && printf '%s' "$OUT" | tail -1 | grep -qx 'Fix: /devstride:setup drills'; then ok "(2) missing file → NOT READY + Fix"; else bad "(2) rc=$RC $OUT"; fi

# (3) readable by others → NOT READY, and nothing is tried
printf '%s\n' "$SECRET" > "$TOK"; chmod 644 "$TOK"; : > "$FAKE_LOG"
OUT="$(run check --file "$TOK")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'owner-only' && [ ! -s "$FAKE_LOG" ]; then ok "(3) mode 644 → NOT READY, claude never run"; else bad "(3) rc=$RC $OUT"; fi

# (4) empty → NOT READY
: > "$TOK"; chmod 600 "$TOK"
OUT="$(run check --file "$TOK")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'is empty'; then ok "(4) empty → NOT READY"; else bad "(4) rc=$RC $OUT"; fi

# (5) a good token → READY; the token went by environment into a fresh folder, never argv or output
printf '  %s  \n' "$SECRET" > "$TOK"; chmod 600 "$TOK"; : > "$FAKE_LOG"
OUT="$(run check --config "$TMP/repo/.claude/ds-config.json")"; RC=$?
if [ $RC -eq 0 ] && [ "$OUT" = "DRILL TOKEN: READY ($TOK, signed in in a separate Claude Code folder)" ]; then ok "(5) good token → READY"; else bad "(5) rc=$RC $OUT"; fi
if grep -q '^-p .*--model haiku --tools  --setting-sources user .*--no-session-persistence' "$FAKE_LOG" \
   && grep -qx 'config-dir: fresh, and the working directory' "$FAKE_LOG" && ! grep -q "$SECRET" "$FAKE_LOG"; then
  ok "(5b) one tiny Haiku request in a fresh folder, token never on the command line"; else bad "(5b) $(cat "$FAKE_LOG")"; fi
: > "$FAKE_LOG"; OUT="$(printf 'private notes\n' | run check --file "$TOK")"
if grep -qx 'stdin bytes: 0' "$FAKE_LOG"; then ok "(5d) the caller's input never reaches the request"; else bad "(5d) $(cat "$FAKE_LOG")"; fi
if ! printf '%s' "$OUT" | grep -q "$SECRET"; then ok "(5c) the token never appears in the output"; else bad "(5c) token printed"; fi

# (6) a token the server refuses → NOT READY, make a new one; nothing the server said is echoed
printf 'sk-ant-oat01-other\n' > "$TOK"; chmod 600 "$TOK"
OUT="$(run check --file "$TOK")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'refused (HTTP 401); make a new one' && ! printf '%s' "$OUT" | grep -q 'sk-leak-me' \
   && printf '%s' "$OUT" | tail -1 | grep -qx 'Fix: /devstride:setup drills'; then ok "(6) refused token → NOT READY, make a new one"; else bad "(6) rc=$RC $OUT"; fi

# (6b) a service failure is not a refusal: check again later, never make a new one
printf 'sk-ant-oat01-busy\n' > "$TOK"
OUT="$(run check --file "$TOK")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'HTTP 429); the token was not refused' \
   && printf '%s' "$OUT" | tail -1 | grep -qx 'Fix: run the check again later'; then ok "(6b) HTTP 429 → check again later"; else bad "(6b) rc=$RC $OUT"; fi

# (6c) another credential ahead of the token (a machine-managed key) → NOT READY, never a false READY
printf '%s\n' "$SECRET" > "$TOK"
OUT="$(FAKE_AUTH_METHOD=api_key run check --file "$TOK")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'another credential ahead of the token' \
   && printf '%s' "$OUT" | tail -1 | grep -q "^Fix: remove this machine's other Claude credential"; then ok "(6c) another credential in use → NOT READY"; else bad "(6c) rc=$RC $OUT"; fi

# (6d) two lines in the file → NOT READY before anything is tried
printf '%s\nsecond\n' "$SECRET" > "$TOK"; : > "$FAKE_LOG"
OUT="$(run check --file "$TOK")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'does not hold one Claude Code token alone' && [ ! -s "$FAKE_LOG" ]; then ok "(6d) two lines → NOT READY, nothing tried"; else bad "(6d) rc=$RC $OUT"; fi
printf '//registry.example/:_authToken=npm-secret\n' > "$TOK"; : > "$FAKE_LOG"
OUT="$(run check --file "$TOK")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'nothing was sent' && [ ! -s "$FAKE_LOG" ]; then ok "(6g) another service's credential → NOT READY, never sent"; else bad "(6g) rc=$RC $OUT"; fi

# (6e) a relative path, or one inside a git repository, is refused (it could be committed)
OUT="$(run check --file relative/token)"; RC=$?
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q 'absolute or ~ path'; then ok "(6e) relative path → refused"; else bad "(6e) rc=$RC $OUT"; fi
git init -q "$TMP/repo"
OUT="$(run check --file "$TMP/repo/.claude/token")"; RC=$?
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q 'inside a git repository'; then ok "(6f) path inside a repository → refused"; else bad "(6f) rc=$RC $OUT"; fi

# (6h) auth status itself fails → check again later, never "make a new one"
printf '%s\n' "$SECRET" > "$TOK"
OUT="$(FAKE_AUTH_BROKEN=1 run check --file "$TOK")"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | tail -1 | grep -qx 'Fix: run the check again later'; then ok "(6h) auth status unreadable → check again later"; else bad "(6h) rc=$RC $OUT"; fi

# (7) no claude on PATH → NOT READY with that reason
printf '%s\n' "$SECRET" > "$TOK"; chmod 600 "$TOK"
OUT="$(PATH=/usr/bin:/bin python3 "$SC" check --file "$TOK" 2>&1)"; RC=$?
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'not on PATH'; then ok "(7) claude missing → NOT READY"; else bad "(7) rc=$RC $OUT"; fi

# (8) make refuses without a terminal and writes nothing
rm -f "$TOK"
OUT="$(run make --file "$TOK" < /dev/null)"; RC=$?
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q "your own terminal" && [ ! -e "$TOK" ]; then ok "(8) make without a terminal → refused, nothing written"; else bad "(8) rc=$RC $OUT"; fi

# (9) make in a terminal: setup-token runs, the pasted token is saved 0600 (folder 0700), then checked
NEW="$TMP/person/.fresh/token"
cat > "$TMP/drive.py" <<'PY'
import os, pty, sys, time
sc, path, secret = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("python3", ["python3", sc, "make", "--file", path])
buf = b""
sent = False
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if not sent and b"Token:" in buf:
        os.write(fd, (secret + "\n").encode()); sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace"))
print("\nEXIT=%d" % os.waitstatus_to_exitcode(status))
PY
OUT="$(python3 "$TMP/drive.py" "$SC" "$NEW" "$SECRET")"
MODE="$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)), oct(stat.S_IMODE(os.stat(os.path.dirname(sys.argv[1])).st_mode)))' "$NEW" 2>/dev/null)"
if printf '%s' "$OUT" | grep -q 'EXIT=0' && printf '%s' "$OUT" | grep -q '^DRILL TOKEN: READY' \
   && [ "$MODE" = "0o600 0o700" ] && [ "$(cat "$NEW")" = "$SECRET" ] && grep -qx 'setup-token' "$FAKE_LOG"; then
  ok "(9) make in a terminal → saved 0600 in a 0700 folder, then READY"; else bad "(9) mode=$MODE $OUT"; fi
if ! printf '%s' "$OUT" | grep -q "$SECRET"; then ok "(9b) the pasted token is never echoed"; else bad "(9b) token echoed"; fi

# (10) a mistyped paste during renewal is refused before anything is saved; the old token stays
OUT="$(python3 "$TMP/drive.py" "$SC" "$NEW" "sk-ant-oat01-typo")"
if printf '%s' "$OUT" | grep -q 'not saved' && printf '%s' "$OUT" | grep -q 'EXIT=1' && [ "$(cat "$NEW")" = "$SECRET" ]; then
  ok "(10) a refused paste keeps the token already saved"; else bad "(10) $OUT"; fi

# (11) make never overwrites a file holding something else
printf 'ssh-private-key-material\n' > "$NEW"; chmod 600 "$NEW"
OUT="$(python3 "$TMP/drive.py" "$SC" "$NEW" "$SECRET")"
if printf '%s' "$OUT" | grep -q 'not a Claude Code token' && [ "$(cat "$NEW")" = "ssh-private-key-material" ]; then
  ok "(11) make refuses to overwrite another file"; else bad "(11) $OUT"; fi

# (12) an empty file (the state check sends to make) is replaced, never a dead end
: > "$NEW"; chmod 600 "$NEW"
OUT="$(python3 "$TMP/drive.py" "$SC" "$NEW" "$SECRET")"
if printf '%s' "$OUT" | grep -q 'EXIT=0' && [ "$(cat "$NEW")" = "$SECRET" ]; then ok "(12) make replaces an empty file"; else bad "(12) $OUT"; fi

# (13) an API key in the file is never sent, and make never overwrites it
printf 'sk-ant-api03-not-a-drill-token\n' > "$NEW"; chmod 600 "$NEW"; : > "$FAKE_LOG"
OUT="$(run check --file "$NEW")"; RC=$?
OUT2="$(python3 "$TMP/drive.py" "$SC" "$NEW" "$SECRET")"
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'nothing was sent' && ! grep -q '^-p' "$FAKE_LOG" \
   && printf '%s' "$OUT2" | grep -q 'not a Claude Code token' && [ "$(cat "$NEW")" = "sk-ant-api03-not-a-drill-token" ]; then
  ok "(13) an API key is never sent or overwritten"; else bad "(13) rc=$RC $OUT $OUT2"; fi

# (14) make refuses a path that is not a file, rather than waiting on it
mkfifo "$TMP/person/pipe"
OUT="$(python3 "$TMP/drive.py" "$SC" "$TMP/person/pipe" "$SECRET")"
if printf '%s' "$OUT" | grep -q 'not a Claude Code token' && [ -p "$TMP/person/pipe" ]; then ok "(14) make refuses a FIFO without hanging"; else bad "(14) $OUT"; fi

exit $FAIL
