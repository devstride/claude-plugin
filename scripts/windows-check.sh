#!/bin/bash
# scripts/windows-check.sh — prove the plugin runs on native Windows. Run on a Windows machine, in
# Git for Windows' bash (where Claude Code runs hooks), with Python from python.org on the path:
#
#   bash scripts/windows-check.sh
#
# What it proves, each as one PASS or FAIL line, ending `WINDOWS CHECK: CLEAN` or
# `WINDOWS CHECK: FAILED (<n>)`:
#   1. the checkout's shell scripts have LF line endings (Git for Windows converts to CRLF unless
#      the repository says otherwise, and bash cannot run a script whose lines end in CR);
#   2. the hook launcher finds Python 3 although `python3` is the Microsoft Store placeholder
#      (one is put first on the path here), gives the session's own commands a working
#      `python3` through CLAUDE_ENV_FILE, and keeps the base Python when started inside a
#      virtual environment;
#   3. every Python file the plugin ships imports;
#   4. every command in hooks/hooks.json runs on a sample event of its kind, exits 0, prints no
#      Python error, and the session record and the live-status record are written;
#   5. the connection check reads a key from Claude Code's configuration and from the environment
#      (READY), and the built-in reporter sends a report to a stand-in DevStride server;
#   6. every shipped script started with no arguments ends without a Python error (a usage line
#      is fine), and the release scripts' time-zone and date formatting work.
# It changes nothing outside a scratch folder. A maintainer script: nothing the plugin runs reads it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILED=$((FAILED + 1)); }
case "${OSTYPE:-}" in
  msys* | cygwin*) ;;
  *) echo "windows-check: run this on Windows, in Git for Windows' bash (OSTYPE is '${OSTYPE:-}')"; exit 2 ;;
esac
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT
winpath() { cygpath -w "$1"; }
export HOME="$WORK/home" CLAUDE_CONFIG_DIR="$WORK/claude"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$WORK/stub" "$WORK/repo"
export USERPROFILE="$(winpath "$HOME")"
unset DEVSTRIDE_API_KEY DEVSTRIDE_API_SECRET DEVSTRIDE_ORG_ID DEVSTRIDE_ORG_SLUG DEVSTRIDE_BASE_URL \
  DEVSTRIDE_PRESENCE DEVSTRIDE_PLUGIN_TEST_URL CLAUDE_PID DEVSTRIDE_PY PYTHONUTF8
# The Microsoft Store placeholder: found as python3, prints an error and exits 9009.
printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 9009\n' >"$WORK/stub/python3"
chmod +x "$WORK/stub/python3"
export PATH="$WORK/stub:$PATH"

# 1. line endings: read as bytes (a script holding the two characters \r as text is fine)
crlf=$(cd "$ROOT" && for f in hooks/*.sh hooks/*.json skills/*/scripts/*.sh skills/setup/references/*.sh; do
  [ -f "$f" ] && od -An -c "$f" | grep -q '\\r *\\n' && echo "$f"; done | head -5)
[ -z "$crlf" ] && pass "line endings: every shell script and hook file has LF endings" || fail "line endings: CRLF in $crlf"

# 2. the launcher
export CLAUDE_ENV_FILE="$WORK/env-file"
: >"$CLAUDE_ENV_FILE"
if (. "$ROOT/hooks/python.sh" && "$DEVSTRIDE_PY" -c 'import sys; assert sys.version_info >= (3, 8)' && printf '%s\n' "$DEVSTRIDE_PY" >"$WORK/py"); then
  PY="$(cat "$WORK/py")"
  pass "launcher: found $PY past the Store placeholder"
else
  fail "launcher: no Python found"
  echo "WINDOWS CHECK: FAILED ($FAILED)"
  exit 1
fi
if (. "$CLAUDE_ENV_FILE" && [ "$(command -v python3)" != "$WORK/stub/python3" ] && python3 -c 'import sys; print(sys.version_info[0])' | grep -q 3); then
  pass "launcher: the session's own shell commands get a working python3"
else
  fail "launcher: CLAUDE_ENV_FILE does not give a working python3 ($(cat "$CLAUDE_ENV_FILE"))"
fi
unset CLAUDE_ENV_FILE
# Started inside a virtual environment, the launcher keeps the Python it was made from, never the
# environment's own copy, because the kept path serves every project afterwards.
# `py -3` picks the system's Python whatever environment is active, so `py` is hidden here and the
# search reaches the environment's own `python`.
mkdir -p "$WORK/nopy" && printf '#!/bin/sh\nexit 1\n' >"$WORK/nopy/py" && chmod +x "$WORK/nopy/py"
if "$PY" -m venv "$WORK/venv" >/dev/null 2>&1; then
  out=$(HOME="$WORK/venv-home" USERPROFILE="$(winpath "$WORK/venv-home")" VIRTUAL_ENV="$(winpath "$WORK/venv")" \
    PATH="$WORK/nopy:$WORK/venv/Scripts:$PATH" bash -c '. "$1/hooks/python.sh" && "$DEVSTRIDE_PY" -c "import sys; print(sys.prefix == sys.base_prefix)"' _ "$ROOT" 2>&1 | tr -d '\r')
  [ "$out" = "True" ] && pass "launcher: inside a virtual environment it keeps the base Python" \
    || fail "launcher: inside a virtual environment it kept the environment's Python ($out)"
else
  fail "launcher: could not make a virtual environment to test with"
fi

# 3. every shipped Python file imports
cat >"$WORK/imports.py" <<'PY'
import glob, importlib.util, os, sys
sys.dont_write_bytecode = True
root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, "hooks", "*.py")) + glob.glob(os.path.join(root, "skills", "*", "scripts", "*.py")))
bad = 0
for i, path in enumerate(files):
    spec = importlib.util.spec_from_file_location("_windows_check_%d" % i, path)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, os.path.dirname(path))
    try:
        spec.loader.exec_module(module)
    except BaseException as error:
        bad += 1
        print("  %s: %s: %s" % (os.path.relpath(path, root), type(error).__name__, error))
    finally:
        sys.path.pop(0)
print("%d of %d" % (len(files) - bad, len(files)))
sys.exit(1 if bad else 0)
PY
if out=$("$PY" "$WORK/imports.py" "$(winpath "$ROOT")" 2>&1); then pass "imports: every shipped Python file imports ($(echo "$out" | tail -1))"; else fail "imports:"; echo "$out"; fi

# 4. every hook command, on a sample event, from a git repository
(cd "$WORK/repo" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init) >/dev/null 2>&1
SID="0f8a2c1e-7b3d-4e5f-9a6b-1c2d3e4f5a6b"
REPO_W="$(winpath "$WORK/repo")"
TRANSCRIPT="$WORK/transcript.jsonl"; : >"$TRANSCRIPT"
"$PY" - "$(winpath "$ROOT/hooks/hooks.json")" >"$WORK/commands" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    hooks = json.load(f)["hooks"]
for event, groups in hooks.items():
    for group in groups:
        for hook in group["hooks"]:
            print(event + "\t" + hook["command"])
PY
n=0
while IFS=$'\t' read -r event command; do
  n=$((n + 1))
  "$PY" -c 'import json,sys; e,s,c,t=sys.argv[1:5]; print(json.dumps({"session_id":s,"hook_event_name":e,"cwd":c,"transcript_path":t,"source":"startup","prompt":"check the plugin → on Windows ✓","tool_name":"Bash","tool_input":{"command":"ls"},"message":"waiting","reason":"other"}))' \
    "$event" "$SID" "$REPO_W" "$(winpath "$TRANSCRIPT")" >"$WORK/payload"
  (cd "$WORK/repo" && CLAUDE_PLUGIN_ROOT="$(winpath "$ROOT")" CLAUDE_PROJECT_DIR="$REPO_W" \
    timeout 30 bash -c "$command" <"$WORK/payload" >"$WORK/hook.out" 2>"$WORK/hook.err")
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q 'Traceback' "$WORK/hook.err"; then
    pass "hook $n $event: $(printf '%s' "$command" | sed 's/.*hooks\///; s/[";].*//')"
  else
    fail "hook $n $event (exit $rc): $command"
    sed 's/^/    /' "$WORK/hook.err" | head -20
  fi
done <"$WORK/commands"
[ "$n" -gt 10 ] || fail "hooks: only $n commands found in hooks.json"
CACHE="$HOME/.cache/devstride-plugin"
[ -f "$CACHE/sessions/$SID.json" ] && pass "hooks: the session record was written" || fail "hooks: no session record in $CACHE/sessions ($(ls "$CACHE" 2>&1))"

# 5. the connection check and a report, against a stand-in DevStride server
KEY=test-key-7f3a; SECRET=test-secret-91bc; ORG=org-55e0
mkdir -p "$WORK/ds"
FAKE_DS_KEY="$KEY" FAKE_DS_SECRET="$SECRET" FAKE_DS_ORG="$ORG" "$PY" "$ROOT/scripts/tests/fixtures/clearance/fake-devstride.py" "$(winpath "$WORK/ds")" >/dev/null 2>&1 &
SERVER=$!
for _ in $(seq 1 100); do [ -s "$WORK/ds/port" ] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat "$WORK/ds/port" 2>/dev/null)"
"$PY" - "$(winpath "$CLAUDE_CONFIG_DIR/.claude.json")" "$KEY" "$SECRET" "$ORG" "$URL" <<'PY'
import json, sys
path, key, secret, org, url = sys.argv[1:6]
entry = {"type": "http", "url": url + "/mcp", "headers": {"X-DevStride-Api-Key": key, "X-DevStride-Api-Secret": secret, "X-DevStride-Organization-Id": org}}
with open(path, "w", encoding="utf-8") as f:
    json.dump({"mcpServers": {"devstride": entry}}, f)
PY
out=$(cd "$WORK/repo" && DEVSTRIDE_PLUGIN_TEST_URL="$URL" "$PY" "$ROOT/hooks/presence-report.py" check 2>&1)
case "$out" in
  "AGENT CONNECTION: READY (key from the devstride connection, user level)"*) pass "connection check: READY from Claude Code's configuration" ;;
  *) fail "connection check (configuration):"; echo "$out" | sed 's/^/    /' ;;
esac
out=$(cd "$WORK/repo" && DEVSTRIDE_PLUGIN_TEST_URL="$URL" DEVSTRIDE_API_KEY="$KEY" DEVSTRIDE_API_SECRET="$SECRET" DEVSTRIDE_ORG_ID="$ORG" "$PY" "$ROOT/hooks/presence-report.py" check 2>&1)
case "$out" in
  "AGENT CONNECTION: READY (key from the environment)"*) pass "connection check: READY from the environment" ;;
  *) fail "connection check (environment):"; echo "$out" | sed 's/^/    /' ;;
esac
(cd "$WORK/repo" && DEVSTRIDE_PLUGIN_TEST_URL="$URL" DEVSTRIDE_API_KEY="$KEY" DEVSTRIDE_API_SECRET="$SECRET" DEVSTRIDE_ORG_ID="$ORG" \
  PRESENCE_SESSION_ID="$SID" PRESENCE_STATE=working PRESENCE_EVENT=start PRESENCE_MACHINE=windows-check "$PY" "$ROOT/hooks/presence-report.py" >"$WORK/report.out" 2>&1)
if [ -s "$WORK/ds/presence.jsonl" ]; then pass "reporter: a live-status report reached the stand-in server"; else fail "reporter: nothing reached the server"; sed 's/^/    /' "$WORK/report.out"; fi
# The live-status hook itself, at session start, with a key: it writes the session's record and
# its report reaches the server (step 4 had no key, so live status was off there, as designed).
before=$(wc -l <"$WORK/ds/presence.jsonl" 2>/dev/null || echo 0)
start=$(grep -m1 '^SessionStart'$'\t''.*presence.py' "$WORK/commands" | cut -f2-)
"$PY" -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"hook_event_name":"SessionStart","cwd":sys.argv[2],"source":"startup"}))' "$SID" "$REPO_W" >"$WORK/payload"
(cd "$WORK/repo" && CLAUDE_PLUGIN_ROOT="$(winpath "$ROOT")" DEVSTRIDE_PLUGIN_TEST_URL="$URL" DEVSTRIDE_API_KEY="$KEY" \
  DEVSTRIDE_API_SECRET="$SECRET" DEVSTRIDE_ORG_ID="$ORG" timeout 30 bash -c "$start" <"$WORK/payload" >/dev/null 2>"$WORK/hook.err")
for _ in $(seq 1 50); do [ "$(wc -l <"$WORK/ds/presence.jsonl" 2>/dev/null || echo 0)" -gt "$before" ] && break; sleep 0.2; done
if ls "$CACHE/presence/" 2>/dev/null | grep -q . && [ "$(wc -l <"$WORK/ds/presence.jsonl")" -gt "$before" ]; then
  pass "live status: the session-start hook wrote its record and its report reached the server"
else
  fail "live status: record $(ls "$CACHE/presence" 2>&1 | head -3), reports $before -> $(wc -l <"$WORK/ds/presence.jsonl" 2>/dev/null)"
  sed 's/^/    /' "$WORK/hook.err" | head -10
fi
kill "$SERVER" 2>/dev/null

# 6. every shipped script, with no arguments
skips=" portable.py devstride_connection.py presence_settings.py "
for script in "$ROOT"/hooks/*.py "$ROOT"/skills/*/scripts/*.py; do
  name="$(basename "$script")"
  case "$skips" in *" $name "*) continue ;; esac
  rc=0; (cd "$WORK/repo" && timeout 30 "$PY" "$script" </dev/null >"$WORK/s.out" 2>&1) || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -ge 125 ]; then  # a usage refusal is 1 or 2; these are a hang or a failed start
    fail "script ${script#"$ROOT"/} with no arguments: $([ "$rc" -eq 124 ] && echo "still running after 30 seconds" || echo "did not start (exit $rc)")"
  elif grep -q '^Traceback' "$WORK/s.out"; then
    fail "script ${script#"$ROOT"/} with no arguments:"; tail -4 "$WORK/s.out" | sed 's/^/    /'
  fi
done
pass "scripts: every other shipped script ends without a Python error when started with no arguments (failures above)"
out=$("$PY" - "$(winpath "$ROOT/skills/build-item/scripts")" <<'PY' 2>&1
import sys, datetime
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import portable
assert portable.zone("UTC").utcoffset(None) == datetime.timedelta(0)
p = portable.spawn_detached([sys.executable, "-c", "import time; time.sleep(30)"])
assert portable.alive(p.pid), "a running child reads as alive"
assert portable.parent_of(__import__("os").getpid()) > 0, "this process has a parent"
assert portable.started(p.pid) > 0, "a running child has a start time"
portable.kill_tree(p); p.wait(timeout=10)
assert not portable.alive(p.pid), "a stopped child reads as gone"
q = __import__("subprocess").Popen(portable.shell("echo $((1 + 2))"), stdout=-1, text=True)
assert q.communicate(timeout=20)[0].strip() == "3", "a shell command line runs in bash"
import os, tempfile
fd, path = tempfile.mkstemp()
assert portable.lock(fd, False), "a free lock is taken"
other = os.open(path, os.O_RDWR)
assert portable.lock(other, False) is False, "a second descriptor cannot take a held lock"
os.close(other); os.close(fd); os.unlink(path)
here = tempfile.mkdtemp()
for planted in ("bash.exe", "claude.cmd"):
    open(os.path.join(here, planted), "w").close()
os.chdir(here)
for name in ("bash", "claude"):
    found = portable.which(name) or ""
    assert os.path.dirname(os.path.abspath(found)) != here, "a %s in the current directory is never chosen" % name
assert os.path.dirname(os.path.abspath(portable.bash())) != here, "bash never comes from the current directory"
print("ok")
PY
)
[ "$out" = "ok" ] && pass "portable: process start, liveness, stop, shell, lock, time zone and a lookup that skips the current directory" || { fail "portable:"; echo "$out" | sed 's/^/    /'; }

if [ "$FAILED" -eq 0 ]; then echo "WINDOWS CHECK: CLEAN"; else echo "WINDOWS CHECK: FAILED ($FAILED)"; exit 1; fi
