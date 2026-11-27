#!/bin/bash
# Deterministic tests for hooks/presence-report.py — the built-in session reporter — and for the
# shared key resolver it uses (skills/build-item/scripts/devstride_connection.py). A fake DevStride
# server on 127.0.0.1 stands in (scripts/tests/fixtures/clearance/fake-devstride.py). A maintainer's
# real configuration file and real key are never read: a throwaway HOME, a scratch CLAUDE_CONFIG_DIR
# whose .claude.json only a case writes, and none of the key variables unless a case sets them.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; RP="$ROOT/hooks/presence-report.py"; FX="$ROOT/scripts/tests/fixtures/clearance"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"   # every server's pid goes in a file: `server` runs in a subshell, which a variable would not leave
trap 'for p in $(cat "$WORK/pids" 2>/dev/null); do kill "$p" 2>/dev/null; done; chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" XDG_CONFIG_HOME="$WORK/config" CLAUDE_CONFIG_DIR="$WORK/claude"; mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$WORK/dir"
# on native Windows the session reporter credential lives under %APPDATA%, which wins over XDG_CONFIG_HOME:
# point it at the same scratch folder, so no case ever writes into the real profile and every path is one
export APPDATA="$XDG_CONFIG_HOME"
export PYTHONDONTWRITEBYTECODE=1   # a case imports the plugin's modules: never leave compiled files in the tree
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1; printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
unset DEVSTRIDE_API_KEY DEVSTRIDE_API_SECRET DEVSTRIDE_ORG_ID DEVSTRIDE_ORG_SLUG DEVSTRIDE_BASE_URL DEVSTRIDE_PRESENCE \
      DEVSTRIDE_PLUGIN_TEST_URL DEVSTRIDE_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID DEVSTRIDE_MACHINE_NAME
for v in $(env | sed -n 's/^\(PRESENCE_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
ALL="$WORK/all-output.log"; : > "$ALL"
KEY=test-key-7f3a; SECRET=test-secret-91bc; ORG=org-55e0   # throwaway values no output may ever hold
cd "$WORK/dir" || exit 1

server() { # server NAME — start a fake server expecting the throwaway key; prints its state directory
  local d="$WORK/ds-$1" n=0; mkdir -p "$d"
  FAKE_DS_KEY="$KEY" FAKE_DS_SECRET="$SECRET" FAKE_DS_ORG="$ORG" python3 "$FX/fake-devstride.py" "$d" >/dev/null 2>&1 &
  echo "$!" >> "$WORK/pids"; until [ -s "$d/port" ] || [ $n -gt 100 ]; do sleep 0.05; n=$((n + 1)); done; printf '%s' "$d"
}
DS="$(server main)"; URL="http://127.0.0.1:$(cat "$DS/port")"
key() { export DEVSTRIDE_API_KEY="$KEY" DEVSTRIDE_API_SECRET="$SECRET" DEVSTRIDE_ORG_ID="$ORG"; }
nokey() { unset DEVSTRIDE_API_KEY DEVSTRIDE_API_SECRET DEVSTRIDE_ORG_ID; }
run() { # run [ARG] — the reporter with the current environment; OUT is everything it printed, RC its exit code
  OUT="$(python3 "$RP" "$@" 2>&1)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL"
}
report() { # report VAR=VALUE… — one report with those PRESENCE_* variables against the main server
  OUT="$(env DEVSTRIDE_PLUGIN_TEST_URL="$URL" "$@" python3 "$RP" 2>&1)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL"
}
lines() { [ -f "$DS/presence.jsonl" ] && wc -l < "$DS/presence.jsonl" | tr -d ' ' || echo 0; }
last() { tail -1 "$DS/presence.jsonl" | python3 -c 'import json,sys; r=json.load(sys.stdin); k=sys.argv[1]; print(",".join(sorted(x for x in r if not x.startswith("_"))) if k=="keys" else r.get(k,"-"))' "$1"; }
claudejson() { # claudejson PYTHON — Claude Code's configuration file (mode 600); E(**changes) is a devstride entry
  python3 - "$CLAUDE_CONFIG_DIR/.claude.json" "$1" "$KEY" "$SECRET" "$ORG" <<'PY'
import json, os, sys
def E(url="https://api.devstride.com/mcp", **changes):
    headers = {"X-DevStride-Api-Key": sys.argv[3], "X-DevStride-Api-Secret": sys.argv[4], "X-DevStride-Organization-Id": sys.argv[5]}
    headers.update(changes)
    return {"type": "http", "url": url, "headers": {k: v for k, v in headers.items() if v is not None}}
path = sys.argv[1]
if os.path.lexists(path):
    os.unlink(path)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, json.dumps(eval(sys.argv[2])).encode()); os.close(fd)
PY
}
noconfig() { rm -f "$CLAUDE_CONFIG_DIR/.claude.json"; }

# (1) body_from: every key, every omission rule, the cuts, and what is never sent
if python3 - "$ROOT" <<'PY'
import importlib.util, os, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("presence_report", os.path.join(root, "hooks", "presence-report.py"))
report = importlib.util.module_from_spec(spec); spec.loader.exec_module(report)
body = report.body_from
full = {"PRESENCE_EVENT": "beat", "PRESENCE_SESSION_ID": "s-1", "PRESENCE_STATE": "working", "PRESENCE_MACHINE": "m9",
        "PRESENCE_CHECKOUT": "/some/where/my-repo", "PRESENCE_BRANCH": "feature/x", "PRESENCE_ITEM": "I20100",
        "PRESENCE_PLUGIN_VERSION": "9.9.9", "PRESENCE_INTERVAL_MINUTES": "3", "PRESENCE_AT": "1700000000000",
        "PRESENCE_ACTIVE_AT": "1700000000001", "PRESENCE_BUSY_SINCE": "1700000000002", "PRESENCE_END_REASON": "logout",
        "DEVSTRIDE_SESSION": "my session", "HOME": "/nonexistent"}
got = body(full)
assert got == {"event": "beat", "sessionId": "s-1", "state": "working", "machine": "m9", "label": "my session",
               "branch": "feature/x", "checkout": "my-repo", "item": "I20100", "pluginVersion": "9.9.9", "intervalMinutes": 3,
               "reportedAt": 1700000000000, "activeAt": 1700000000001, "busySince": 1700000000002}, got
end = body(dict(full, PRESENCE_EVENT="end", PRESENCE_STATE="ended"))
assert end["endReason"] == "logout" and "state" not in end and "busySince" not in end, end
assert "state" not in body(dict(full, PRESENCE_STATE="ended")), "a state the server does not know is left out"
assert body(dict(full, PRESENCE_EVENT="bogus")) is None and body(dict(full, PRESENCE_SESSION_ID="")) is None
assert body(dict(full, PRESENCE_SESSION_ID="has space")) is None
bare = body({"PRESENCE_EVENT": "start", "PRESENCE_SESSION_ID": "s-2", "HOME": "/nonexistent"})
assert bare == {"event": "start", "sessionId": "s-2"}, bare
for name, value in (("PRESENCE_AT", "1" * 17), ("PRESENCE_ACTIVE_AT", "12x"), ("PRESENCE_BUSY_SINCE", "-5"),
                    ("PRESENCE_INTERVAL_MINUTES", "0"), ("PRESENCE_INTERVAL_MINUTES", "61"), ("PRESENCE_INTERVAL_MINUTES", "x")):
    key = {"PRESENCE_AT": "reportedAt", "PRESENCE_ACTIVE_AT": "activeAt", "PRESENCE_BUSY_SINCE": "busySince",
           "PRESENCE_INTERVAL_MINUTES": "intervalMinutes"}[name]
    assert key not in body(dict(full, **{name: value})), (name, value)
cut = body(dict(full, PRESENCE_BRANCH="a\tb\x00c" + "x" * 600, PRESENCE_MACHINE="m" * 300, PRESENCE_ITEM="i" * 100,
                PRESENCE_CHECKOUT="/p/" + "c" * 600, DEVSTRIDE_SESSION="n" * 300, PRESENCE_PLUGIN_VERSION=" 1.2.3\n"))
assert cut["branch"].startswith("a b c") and len(cut["branch"]) == 500 and len(cut["machine"]) == 200
assert len(cut["item"]) == 64 and len(cut["checkout"]) == 500 and len(cut["label"]) == 200 and cut["pluginVersion"] == "1.2.3"
assert "checkout" not in body(dict(full, PRESENCE_CHECKOUT="")), "outside a repository there is no checkout"
assert "/" not in got["checkout"]
PY
then ok "(1) body_from: every field, each omission (end, an unknown state, bad stamps, a 17-digit stamp, a bad interval), control characters cleaned, the 500/200/64 cuts, the checkout a base name"
else bad "(1) body_from"; fi

# (2) a report: one call with exactly the body, no output; nothing to send is exit 0 and no call
key
report PRESENCE_EVENT=start PRESENCE_SESSION_ID=r2 PRESENCE_STATE=starting PRESENCE_MACHINE=m9 PRESENCE_AT=1700000000000; A="$RC:$OUT:$(lines):$(last keys)"
report PRESENCE_EVENT=end PRESENCE_SESSION_ID=r2 PRESENCE_STATE=ended PRESENCE_MACHINE=m9 PRESENCE_END_REASON=clear; B="$RC:$OUT:$(lines):$(last event):$(last endReason)"
report PRESENCE_EVENT=nope PRESENCE_SESSION_ID=r2 PRESENCE_MACHINE=m9; C="$RC:$OUT:$(lines)"
report PRESENCE_EVENT=beat PRESENCE_MACHINE=m9; D="$RC:$OUT:$(lines)"
for o in stale not-owner; do printf '%s' "$o" > "$DS/presence-outcome"; report PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r2 PRESENCE_STATE=working PRESENCE_MACHINE=m9; E="${E:-}$RC:$OUT "; done
printf 'surprise' > "$DS/presence-outcome"; report PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r2 PRESENCE_STATE=working PRESENCE_MACHINE=m9; F="$RC:$OUT"; rm -f "$DS/presence-outcome"
if [ "$A" = "0::1:event,machine,reportedAt,sessionId,state" ] && [ "$B" = "0::2:end:clear" ] && [ "$C" = "0::2" ] && [ "$D" = "0::2" ] \
   && [ "$E" = "0: 0: " ] && [ "$F" = "4:" ]; then
  ok "(2) a report is one call carrying exactly the body, silent, exit 0 (recorded, ended, stale, not-owner alike); an unknown answer is exit 4; an unknown event or no session id sends nothing, exit 0"
else bad "(2) a=$A b=$B c=$C d=$D e=$E f=$F"; fi

# (3) the exit-code map, by server answer; never a word on stdout or stderr
codes() { # codes MODE… — the exit code and output of a beat against a server in each mode
  local d m r=""; for m in "$@"; do
    d="$(server "m-$m")"; : > "$d/any-key"; printf '%s' "$m" > "$d/mode"
    OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="http://127.0.0.1:$(cat "$d/port")" PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r3 PRESENCE_STATE=working PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"
    r="$r$m=$?:$OUT "; printf '%s\n' "$OUT" >> "$ALL"; [ "$m" = redirect ] && [ -e "$d/followed" ] && r="$r(FOLLOWED) "
  done; printf '%s' "$r"
}
A="$(codes unknown-tool http403 http401 http500 http429 bad-json redirect)"
DEAD="$(server dead)"; DEADURL="http://127.0.0.1:$(cat "$DEAD/port")"; pkill -f "fake-devstride.py $DEAD\$" 2>/dev/null; sleep 0.2
OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="$DEADURL" PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r3 PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; B="$?:$OUT"
SLOW="$(server slow)"; printf 2 > "$SLOW/delay"; : > "$SLOW/any-key"
OUT="$(DEVSTRIDE_PRESENCE_TIMEOUT=0.5 DEVSTRIDE_PLUGIN_TEST_URL="http://127.0.0.1:$(cat "$SLOW/port")" PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r3 PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; C="$?:$OUT"
OUT="$(DEVSTRIDE_API_SECRET=wrong DEVSTRIDE_PLUGIN_TEST_URL="$URL" PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r3 PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; D="$?:$OUT"
OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="$URL" PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r3 PRESENCE_STATE=working PRESENCE_MACHINE=m9 PRESENCE_BRANCH="$(printf 'a\001b')" python3 "$RP" 2>&1)"; G="$?:$OUT:$(last branch)"
if [ "$A" = "unknown-tool=3: http403=3: http401=3: http500=4: http429=4: bad-json=4: redirect=4: " ] && [ "$B" = "4:" ] && [ "$C" = "4:" ] \
   && [ "$D" = "3:" ] && [ "$G" = "0::a b" ] && [ "$(wc -l < "$WORK/ds-m-http500/calls.log" | tr -d ' ')" = 1 ]; then
  ok "(3) no such tool, 403, 401 (a wrong secret too) → exit 3; 500, 429, an answer that is not JSON, a redirect (never followed), a refused connection, a timeout → exit 4, after one attempt; a control character is cleaned before it is sent; never any output"
else bad "(3) a=$A b=$B c=$C d=$D g=$G"; fi

# (4) the address: anything but a DevStride API host is refused before any request
N0="$(lines)"
for base in http://evil.example https://api.devstride.com.evil.example 'https://api.devstride.com/x'; do
  OUT="$(DEVSTRIDE_BASE_URL="$base" PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r4 PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; H="${H:-}$?:$OUT "
done
OUT="$(DEVSTRIDE_PLUGIN_TEST_URL=http://example.com:80 PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r4 PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; I="$?:$OUT"
if [ "$H" = "3: 3: 3: " ] && [ "$I" = "3:" ] && [ "$(lines)" = "$N0" ]; then
  ok "(4) DEVSTRIDE_BASE_URL off api(-x).devstride.com/.dev, or a tests-only address that is not 127.0.0.1 → refused (exit 3) before any request"
else bad "(4) h=$H i=$I"; fi

# (5) check: where the key was found, by fixed words only; NOT READY with the fix; the presence line and interval
REPO="$WORK/repo"; mkdir -p "$REPO/.claude"; git -C "$REPO" init -q 2>/dev/null; RREAL="$(cd "$REPO" && pwd -P)"
chk() { OUT="$( (cd "${1:-$WORK/dir}" && python3 "$RP" check) 2>&1)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL"; printf '%s' "$OUT" | tr '\n' '|'; }
key; noconfig; A="$(chk)"
nokey; claudejson '{"mcpServers": {"devstride": E()}}'; B="$(chk)"
claudejson "{'projects': {'$RREAL': {'mcpServers': {'devstride': E()}}}}"; C="$(chk "$REPO")"; C2="$(chk)"
noconfig; D="$(chk)"
claudejson '{"mcpServers": {"devstride": {"type": "http", "url": "https://api.devstride.com/mcp"}}}'; D2="$(chk)"
claudejson '{"mcpServers": {"devstride": E()}}'; chmod 644 "$CLAUDE_CONFIG_DIR/.claude.json"; E1="$(chk)"
mv "$CLAUDE_CONFIG_DIR/.claude.json" "$WORK/real.json"; chmod 600 "$WORK/real.json"; ln -s "$WORK/real.json" "$CLAUDE_CONFIG_DIR/.claude.json"; E2="$(chk)"
rm -f "$CLAUDE_CONFIG_DIR/.claude.json"; claudejson '{"mcpServers": {"devstride": E()}}'
python3 -c 'import sys; open(sys.argv[1],"ab").truncate(17*1048576)' "$CLAUDE_CONFIG_DIR/.claude.json"; E3="$(chk)"
for u in https://example.com/mcp https://api.devstride.com.evil.example/mcp https://api.devstride.com/other; do
  rm -f "$CLAUDE_CONFIG_DIR/.claude.json"; claudejson "{'mcpServers': {'devstride': E(url='$u')}}"; F5="${F5:-}$(chk)#"; done
NR="AGENT CONNECTION: NOT READY"; FIXL="Fix: /devstride:setup connect"
if [ "$A" = "AGENT CONNECTION: READY (key from the environment)|PRESENCE: ON (built-in reporter)|INTERVAL: 1 minute(s)" ] \
   && [ "$B" = "AGENT CONNECTION: READY (key from the devstride connection, user level)|PRESENCE: ON (built-in reporter)|INTERVAL: 1 minute(s)" ] \
   && [ "$C" = "AGENT CONNECTION: READY (key from the devstride connection, this project)|PRESENCE: ON (built-in reporter)|INTERVAL: 1 minute(s)" ] \
   && [ "$C2" = "$NR (no API key: browser sign-in only, or no devstride connection)|$FIXL|PRESENCE: OFF (no-key)|INTERVAL: none" ] \
   && [ "$D" = "$C2" ] && [ "$D2" = "$C2" ] && [ "$F5" = "$C2#$C2#$C2#" ] \
   && [ "$E1" = "$NR (Claude Code's configuration file cannot be read safely: mode too open)|$FIXL|PRESENCE: OFF (no-key)|INTERVAL: none" ] \
   && [ "$E2" = "$NR (Claude Code's configuration file cannot be read safely: a link)|$FIXL|PRESENCE: OFF (no-key)|INTERVAL: none" ] \
   && [ "$E3" = "$NR (Claude Code's configuration file cannot be read safely: too large)|$FIXL|PRESENCE: OFF (no-key)|INTERVAL: none" ]; then
  ok "(5) check: READY from the environment, the user-level entry, this project's entry; NOT READY (no key, a keyless entry, an entry at a foreign or look-alike host or another path, a file open to others, a link, too large), each with the Fix line"
else bad "(5) a=$A b=$B c=$C c2=$C2 d=$D d2=$D2 e1=$E1 e2=$E2 e3=$E3"; fi
noconfig

# (5a) a key with an address that is not DevStride's is NOT READY, with its own fix; a report from a
#      directory that is gone is still sent; one with no key is recorded as not sent (exit 4)
key; A="$(DEVSTRIDE_BASE_URL=https://evil.example chk | cut -d'|' -f1-2)"
mkdir -p "$WORK/gone"; OUT="$(cd "$WORK/gone" && rmdir "$WORK/gone" && DEVSTRIDE_PLUGIN_TEST_URL="$URL" PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r5 PRESENCE_STATE=working PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; B="$?:$OUT"
nokey; OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="$URL" PRESENCE_EVENT=beat PRESENCE_SESSION_ID=r5 PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; C="$?:$OUT"
if [ "$A" = "AGENT CONNECTION: NOT READY (DEVSTRIDE_BASE_URL is not a DevStride API address)|Fix: unset DEVSTRIDE_BASE_URL, or set it to https://api.devstride.com" ] \
   && [ "$B" = "0:" ] && [ "$C" = "4:" ]; then
  ok "(5a) a key with a foreign address → NOT READY naming the address; no key at report time → exit 4, silent; from a deleted directory the report is still sent"
else bad "(5a) a=$A b=$B c=$C"; fi

# (5b) check's presence line: the repository command, the two switches, a blank command, the block's interval
key
printf '{"presence":{"command":"true","intervalMinutes":7}}' > "$REPO/.claude/ds-config.json"; A="$(chk "$REPO" | cut -d'|' -f2-3)"
printf '{"presence":null}' > "$REPO/.claude/ds-config.json"; B="$(chk "$REPO" | cut -d'|' -f2-3)"
printf '{"presence":{"command":""}}' > "$REPO/.claude/ds-config.json"; C="$(chk "$REPO" | cut -d'|' -f2-3)"
printf '{"presence":{"intervalMinutes":4}}' > "$REPO/.claude/ds-config.json"; D="$(chk "$REPO" | cut -d'|' -f2-3)"
E="$(DEVSTRIDE_PRESENCE=off chk "$REPO" | cut -d'|' -f2-3)"
printf '{"presence": null,}' > "$REPO/.claude/ds-config.json"; F="$(chk "$REPO" | cut -d'|' -f2-3)"; rm -f "$REPO/.claude/ds-config.json"
if [ "$A" = "PRESENCE: ON (repository command)|INTERVAL: 7 minute(s)" ] && [ "$B" = "PRESENCE: OFF (repo-null)|INTERVAL: none" ] \
   && [ "$C" = "PRESENCE: OFF (command-blank)|INTERVAL: none" ] && [ "$D" = "PRESENCE: ON (built-in reporter)|INTERVAL: 4 minute(s)" ] \
   && [ "$E" = "PRESENCE: OFF (machine-off)|INTERVAL: none" ] && [ "$F" = "PRESENCE: OFF (config-unreadable)|INTERVAL: none" ]; then
  ok "(5b) check: a repository command, presence null, a blank command, a block's own interval, DEVSTRIDE_PRESENCE off; a config file that cannot be read switches nothing on"
else bad "(5b) a=$A b=$B c=$C d=$D e=$E f=$F"; fi

# (5c) a configuration file another user owns is refused (needs root to create one)
if [ "$(id -u)" = 0 ]; then
  nokey; claudejson '{"mcpServers": {"devstride": E()}}'; chown 12345 "$CLAUDE_CONFIG_DIR/.claude.json"; A="$(chk)"
  if printf '%s' "$A" | grep -q "cannot be read safely: not yours"; then ok "(5c) a configuration file another user owns → NOT READY (not yours)"; else bad "(5c) $A"; fi
  noconfig
else ok "(5c) a configuration file another user owns — skipped (not root)"; fi

# (6) prove: a start and an end for a throwaway session; each answer has its one line
key; N0="$(lines)"
OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="$URL" python3 "$RP" prove 2>&1)"; A="$?:$OUT"; printf '%s\n' "$OUT" >> "$ALL"
SID="$(last sessionId)"; EV="$(sed -n "$((N0 + 1))p" "$DS/presence.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["event"])'):$(last event)"
prove_in() { local d; d="$(server "p-$1")"; : > "$d/any-key"; printf '%s' "$1" > "$d/mode"
  OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="http://127.0.0.1:$(cat "$d/port")" python3 "$RP" prove 2>&1)"; printf '%s:%s' "$?" "$OUT"; printf '%s\n' "$OUT" >> "$ALL"; }
B="$(prove_in unknown-tool)"; C="$(prove_in http403)"; D="$(prove_in http500)"; G="$(prove_in echo-key)"
OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="$DEADURL" python3 "$RP" prove 2>&1)"; E="$?:$OUT"
nokey; OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="$URL" python3 "$RP" prove 2>&1)"; F="$?:$OUT"; printf '%s\n' "$OUT" >> "$ALL"
if [ "$A" = "0:PROOF: ok" ] && [ "$(lines)" = "$((N0 + 2))" ] && [ "$EV" = "start:end" ] && printf '%s' "$SID" | grep -Eq '^setup-check-[0-9a-f]{8}$' \
   && [ "$B" = "1:PROOF: NOT AVAILABLE (the server has no live status yet)" ] \
   && [ "$C" = "1:PROOF: REFUSED (HTTP 403: the key, secret and organization id must belong together)" ] \
   && [ "$D" = "1:PROOF: FAILED (DevStride answered HTTP 500)" ] && [ "$E" = "1:PROOF: UNREACHABLE" ] \
   && [ "$F" = "1:PROOF: NOT READY (the DevStride connection carries no API key)" ] \
   && printf '%s' "$G" | grep -q '^1:PROOF: FAILED (Rejected: ' && ! printf '%s' "$G" | grep -qF -e "$KEY" -e "$SECRET"; then
  ok "(6) prove: a start then an end for setup-check-<8 hex> → PROOF: ok; NOT AVAILABLE, REFUSED, FAILED, UNREACHABLE and NOT READY each say so; a server error that repeats the key and secret is shown without them"
else bad "(6) a=$A ev=$EV sid=$SID b=$B c=$C d=$D e=$E f=$F g=$(printf '%s' "$G" | cut -c1-24)"; fi

# (7) the hook starts the reporter with no arguments and adds nothing to its environment but the
#     PRESENCE_* variables and the session's id and process: a key can never show in a process list
nokey; claudejson '{"mcpServers": {"devstride": E()}}'
if python3 - "$ROOT" "$WORK/dir" "$KEY" "$SECRET" "$ORG" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "hooks"))
before = dict(os.environ)
import presence
job = presence.report_job("s7", {"schema": 1, "top": None, "dir": sys.argv[2], "owner": 4242}, "beat", "working", 1700000000000)
mode, command, cwd, env = job
assert mode == "builtin" and command == [sys.executable, presence.REPORTER] and cwd == sys.argv[2], (mode, command, cwd)
added = {k for k in env if k not in before}
assert added <= {"CLAUDE_CODE_SESSION_ID", "CLAUDE_PID"} | {k for k in env if k.startswith("PRESENCE_")}, added
assert all(before[k] == env[k] for k in before if not k.startswith("PRESENCE_") and k not in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_PID"))
assert env["PRESENCE_CHECKOUT"] == "" and env["PRESENCE_BRANCH"] == "" and env["PRESENCE_ITEM"] == ""
assert presence.connection_ready(None, sys.argv[2]), "the entry's key is what makes this session report"
assert not any(k.startswith("DEVSTRIDE_API") or k.startswith("DEVSTRIDE_ORG") for k in env), "the key never becomes a variable"
for secret in sys.argv[3:6]:
    assert all(secret not in part for part in command) and all(secret not in value for value in env.values())
PY
then ok "(7) with the key in the connection's entry, the reporter is started with no arguments and no added variables beyond PRESENCE_* (and the session's id and process): no key, secret or organization id in either"
else bad "(7) the job the hook builds"; fi
noconfig

# (8) the resolver refuses to mix sources, and a maintainer's real file is never read
nokey
if python3 - "$ROOT" "$WORK" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
import devstride_connection as c
work = sys.argv[2]
path = os.path.join(work, "mix.json")
def write(data, mode=0o600):
    if os.path.lexists(path): os.unlink(path)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, mode); os.write(fd, json.dumps(data).encode()); os.close(fd); os.chmod(path, mode)
entry = {"url": "https://api.devstride.com/mcp", "headers": {"X-DevStride-Api-Key": "ek", "X-DevStride-Api-Secret": "es",
                                                                    "X-DevStride-Organization-Id": "eo", "X-DevStride-Organization-Slug": "slug"}}
write({"mcpServers": {"devstride": entry}})
# a partial environment is never completed from the entry: the entry's key, secret, organization and address travel together
got = c.credentials({"DEVSTRIDE_API_KEY": "envkey"}, path, [])
assert (got["DEVSTRIDE_API_KEY"], got["DEVSTRIDE_API_SECRET"], got["DEVSTRIDE_ORG_ID"], got["DEVSTRIDE_ORG_SLUG"]) == ("ek", "es", "eo", "slug"), got
assert got["base"] == "https://api.devstride.com" and got["source"] == "connection-user"
assert c.readiness({}, path, []) == "connection-user" and c.readiness({}, os.path.join(work, "absent.json"), []) == "no-key"
write({"mcpServers": {"devstride": entry}}, 0o640)
assert c.readiness({}, path, []) == "unsafe-config"
assert c.readiness({"DEVSTRIDE_API_KEY": "a", "DEVSTRIDE_API_SECRET": "b", "DEVSTRIDE_ORG_ID": "c"}, path, []) == "environment"
write("not an object")
assert c.readiness({}, path, []) == "no-key"
# the default file is the one under CLAUDE_CONFIG_DIR, else the home directory's
assert c.config_file({"CLAUDE_CONFIG_DIR": "/x"}) == "/x/.claude.json"
assert c.config_file({}) == os.path.join(os.path.expanduser("~"), ".claude.json")
assert os.path.expanduser("~") == os.path.join(work, "home"), "the tests never run against a real home"
# places outside a repository: the real path, then the path as given when it differs
assert c.project_places(None, work) == [os.path.realpath(work)] + ([work] if work != os.path.realpath(work) else [])
PY
then ok "(8) the entry's key, secret, organization and address are taken together, never mixed with the environment; an unsafe file is unsafe-config unless the environment has a key; the home directory is a throwaway"
else bad "(8) the resolver"; fi
OUT="$(HOME="$WORK/empty-home" CLAUDE_CONFIG_DIR="$WORK/empty-config" python3 "$RP" check 2>&1 | head -1)"
if [ "$OUT" = "AGENT CONNECTION: NOT READY (no API key: browser sign-in only, or no devstride connection)" ]; then ok "(8b) an empty home and an empty configuration directory → NOT READY: nothing else is read"
else bad "(8b) $OUT"; fi

# (10) a rename asked for on the Agent Fleet: a recorded answer's request is kept for the title hook,
#      the title hook applies it, and once the session carries the name the next report says so and
#      the kept request goes; another answer keeps it, an end removes it; the exit code never changes
key; noconfig
TH="$ROOT/hooks/session-title.py"; RSID=4c1e2f00-aaaa-bbbb-cccc-000000000010; KEPT="$XDG_CACHE_HOME/devstride-plugin/session-title/$RSID.request.json"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
named() { printf '{"sessionId":"%s","name":"%s"}' "$RSID" "$1" > "$CLAUDE_CONFIG_DIR/sessions/4242.json"; }
beat() { report PRESENCE_EVENT="${1:-beat}" PRESENCE_SESSION_ID="$RSID" PRESENCE_STATE=working PRESENCE_MACHINE=m9 CLAUDE_CODE_SESSION_ID="$RSID" CLAUDE_PID=4242; }
kept() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$KEPT" 2>/dev/null || echo none; }
prompt() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s","prompt":"x","session_title":"%s"}' "$RSID" "$WORK/dir" "$1" \
  | python3 "$TH" hook | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t)["hookSpecificOutput"]["sessionTitle"] if t.strip() else "-")'; }
named "Old name"; printf '{"name":"New  name","at":"2026-11-24T16:00:00.000Z"}' > "$DS/presence-rename"
beat; A="$RC:$OUT:$(last renameApplied):$(last label):$(kept)"
MODE="$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(os.path.dirname(sys.argv[1])).st_mode)), oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$KEPT" 2>/dev/null)"
printf 'stale' > "$DS/presence-outcome"; beat; B="$RC:$(kept)"; rm -f "$DS/presence-outcome"
beat; A2="$RC:$(last renameApplied):$(kept)"
C="$(prompt "Old name")"; D="$(prompt "New name")"
named "Something else"; beat; E="$RC:$(last renameApplied):$(kept)"
named "New name"; beat; F="$RC:$(last renameApplied):$([ -e "$DS/presence-rename" ] && echo asking || echo taken):$(kept)"
beat; G="$RC:$(last renameApplied):$(kept)"
printf '{"name":"Again","at":"2026-11-24T17:00:00.000Z"}' > "$DS/presence-rename"; beat; H1="$(kept)"
beat end; H="$RC:$(last renameApplied):$(kept)"
printf '{"name":"Third","at":"2026-11-24T18:00:00.000Z"}' > "$DS/presence-rename"; beat; I1="$(prompt "New name")"
named "Typed by hand"; beat; I="$RC:$(last renameApplied):$([ -e "$DS/presence-rename" ] && echo asking || echo taken)"
beat; I2="$(kept)"
printf '{"name":"Fourth","at":"2026-11-24T19:00:00.000Z"}' > "$DS/presence-rename"; beat; named "Fourth"; beat; J="$(last renameApplied):$(kept)"
rm -f "$DS/presence-rename"
if [ "$A" = "0::-:Old name:New name" ] && [ "$MODE" = "0o700 0o600" ] && [ "$B" = "0:New name" ] && [ "$A2" = "0:-:New name" ] \
   && [ "$C" = "New name" ] && [ "$D" = "-" ] \
   && [ "$E" = "0:2026-11-24T16:00:00.000Z:none" ] && [ "$F" = "0:-:taken:none" ] && [ "$G" = "0:-:none" ] \
   && [ "$H1" = "Again" ] && [ "$H" = "0:-:none" ] && [ "$I1" = "Third" ] \
   && [ "$I" = "0:2026-11-24T18:00:00.000Z:taken" ] && [ "$I2" = "none" ] && [ "$J" = "2026-11-24T19:00:00.000Z:none" ]; then
  ok "(10) a Fleet rename on a recorded answer is kept owner-only (name cleaned) and set as the title at the next prompt; renameApplied is sent only once the session's own name matches or the title hook set it (a /rename typed since never strands it), and the server stops asking; a stale answer keeps it, a recorded answer without one or an end removes it; exit 0 throughout"
else bad "(10) a=$A mode=$MODE b=$B a2=$A2 c=$C d=$D e=$E f=$F g=$G h1=$H1 h=$H i1=$I1 i=$I i2=$I2 j=$J"; fi

# (10b) the kept request is read, replaced or removed only in a records directory that is this
#       user's own, never a link nor open to others for writing
if python3 - "$ROOT" "$WORK/rn" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
work = sys.argv[2]
os.makedirs(work)
os.environ["XDG_CACHE_HOME"] = os.path.join(work, "cache")
import session_rename as r
r.write("s1", "Name", "t1")
assert r.read("s1") == {"name": "Name", "at": "t1"}
records = r.directory()
assert oct(os.stat(records).st_mode & 0o777) == "0o700" and oct(os.stat(r.path("s1")).st_mode & 0o777) == "0o600"
assert oct(os.stat(os.path.dirname(records)).st_mode & 0o777) == "0o700", "a parent this creates is private"
os.chmod(os.path.dirname(records), 0o775)
assert r.read("s1") == {"name": "Name", "at": "t1"}, "a parent left open to the group by a umask of 002 is fine"
os.chmod(os.path.dirname(records), 0o777)
assert r.read("s1") is None, "a parent other users may write to is not trusted"
os.chmod(os.path.dirname(records), 0o755)
os.chmod(records, 0o770)
assert r.read("s1") is None, "a directory others may write to is not read"
r.remove("s1"); assert os.path.exists(r.path("s1")), "nor removed from"
os.chmod(records, 0o700)
elsewhere = os.path.join(work, "elsewhere"); os.makedirs(elsewhere, mode=0o700)
open(os.path.join(elsewhere, "s2.request.json"), "w").write('{"name":"Other","at":"t2"}')
os.rename(records, records + ".real"); os.symlink(elsewhere, records)
assert r.read("s2") is None, "a linked directory is not read"
r.remove("s2"); assert os.path.exists(os.path.join(elsewhere, "s2.request.json")), "nor removed from"
try:
    r.write("s3", "N", "t3"); raise SystemExit("wrote through a linked directory")
except OSError:
    pass
os.unlink(records); os.rename(records + ".real", records)
os.symlink(r.path("s1"), r.path("s4"))
assert r.read("s4") is None, "a linked request is not read"
assert r.read("../s1") is None and r.read("") is None and r.read(None) is None
assert r.request_of({"outcome": "stale", "rename": {"name": "x", "at": "t"}}) is None
assert r.request_of({"outcome": "recorded", "rename": {"name": " a\tb ", "at": "t"}}) == ("a b", "t")
assert r.request_of({"outcome": "recorded", "rename": {"name": "x", "at": "t" * 65}}) is None
PY
then ok "(10b) the kept request lives owner-only; a directory open to others, a linked directory or a linked request is never read, written or removed through; a bad session id, a non-recorded answer or an over-long time is no request"
else bad "(10b) the rename helper's file safety"; fi

# (11) the session reporter credential: made by prepare and finish, never printed; the reporter's last
#      source, after the environment and the connection; refused when unsafe; never read by release clearance
RC_SCRIPT="$ROOT/skills/build-item/scripts/reporter_credential.py"; CONF="$XDG_CONFIG_HOME/devstride-plugin"
nokey; noconfig
# on native Windows too (where %APPDATA% wins) the credential these cases write is the scratch one
if python3 -c 'import os, sys; sys.path.insert(0, sys.argv[1]); import portable, reporter_credential as rc; portable.IS_WINDOWS = True; assert rc.folder() == sys.argv[2], rc.folder()' \
     "$ROOT/skills/build-item/scripts" "$CONF" 2>/dev/null; then ok "(11) the credential folder is the scratch one, as Windows would resolve it too"
else bad "(11) as Windows resolves it, the credential folder is not the scratch one: APPDATA must point at it"; fi
S0="$(python3 "$RC_SCRIPT" status 2>&1)"
python3 "$RC_SCRIPT" finish --key-id k --org-id o --org-slug s --username u >/dev/null 2>&1; NOPEND=$?
PREP="$(DEVSTRIDE_MACHINE_NAME="Jane's Mac" python3 "$RC_SCRIPT" prepare 2>&1)"; printf '%s\n' "$PREP" >> "$ALL"
S1="$(python3 "$RC_SCRIPT" status 2>&1)"
python3 "$RC_SCRIPT" finish --key-id "k-rep" --org-id "o-rep" --org-slug "acme" --username $'bad\nname' >/dev/null 2>&1; BADVAL=$?
FIN="$(python3 "$RC_SCRIPT" finish --key-id "k-rep" --org-id "o-rep" --org-slug "acme" --username "jane" 2>&1)"; printf '%s\n' "$FIN" >> "$ALL"
S2="$(python3 "$RC_SCRIPT" status 2>&1)"
if [ "$S0" = NONE ] && [ "$NOPEND" = 2 ] && [ "$S1" = PENDING ] && [ "$BADVAL" = 2 ] && [ "$S2" = READY ] \
   && [ "$FIN" = "REPORTER: READY (Session reporter · jane-s-mac)" ] && python3 - "$PREP" "$CONF" "$ALL" <<'PY'
import hashlib, json, os, re, stat, sys
prep, conf, all_out = sys.argv[1], sys.argv[2], open(sys.argv[3]).read()
lines = prep.splitlines()
assert len(lines) == 2 and re.match(r"^FINGERPRINT: [0-9a-f]{64}$", lines[0]) and lines[1] == "MACHINE: jane-s-mac", lines
assert stat.S_IMODE(os.stat(conf).st_mode) == 0o700
path = os.path.join(conf, "session-reporter.json")
assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
assert not os.path.exists(os.path.join(conf, "session-reporter.pending.json")), "the pending secret is moved, not copied"
stored = json.load(open(path))
assert stored == dict(stored, apiKey="k-rep", organizationId="o-rep", organizationSlug="acme", username="jane", machine="jane-s-mac")
assert hashlib.sha256(stored["secret"].encode()).hexdigest() == lines[0].split(": ")[1], "the fingerprint is the secret's"
assert stored["secret"] not in all_out, "the secret is never printed"
assert sorted(os.listdir(conf)) == ["session-reporter.json"], "no temporary file is left"
PY
then ok "(11a) prepare prints only the fingerprint and the machine; finish moves the pending secret into an owner-only file (0600 in 0700) with the answer; status says NONE, PENDING, READY; a missing pending secret or a malformed value is refused; the secret is never printed"
else bad "(11a) s0=$S0 nopend=$NOPEND s1=$S1 bad=$BADVAL s2=$S2 fin=$FIN prep=$PREP"; fi
if python3 - "$ROOT" "$WORK" "$CONF/session-reporter.json" <<'PY'
import json, os, shutil, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
import devstride_connection as c
work, stored = sys.argv[2], sys.argv[3]
none = os.path.join(work, "absent.json")
env = {"XDG_CONFIG_HOME": os.path.join(work, "config")}
try:
    c.credentials(env, none, [])
    raise AssertionError("no caller but the reporter reads the reporter credential")
except c.Missing:
    pass
got = c.credentials(env, none, [], reporter=True)
assert got["source"] == "session-reporter" and got["DEVSTRIDE_API_KEY"] == "k-rep" and got["DEVSTRIDE_ORG_SLUG"] == "acme", got
import hashlib
secret = json.load(open(stored))["secret"]
assert got["DEVSTRIDE_API_SECRET"] == secret, "the stored secret itself is what is sent"
assert got["DEVSTRIDE_API_SECRET"] != hashlib.sha256(secret.encode()).hexdigest(), "never its fingerprint"
assert got["DEVSTRIDE_ORG_ID"] == "o-rep", "the registered organization id is what is sent"
assert got["base"] == "https://api.devstride.com"
assert c.readiness(env, none, [], reporter=True) == "session-reporter" and c.readiness(env, none, []) == "no-key"
full = dict(env, DEVSTRIDE_API_KEY="a", DEVSTRIDE_API_SECRET="b", DEVSTRIDE_ORG_ID="c")
assert c.credentials(full, none, [], reporter=True)["source"] == "environment", "a full key wins"
entry = {"url": "https://api.devstride.com/mcp", "headers": {"X-DevStride-Api-Key": "ek", "X-DevStride-Api-Secret": "es",
                                                                    "X-DevStride-Organization-Id": "eo"}}
config = os.path.join(work, "full.json")
fd = os.open(config, os.O_WRONLY | os.O_CREAT, 0o600); os.write(fd, json.dumps({"mcpServers": {"devstride": entry}}).encode()); os.close(fd)
assert c.credentials(env, config, [], reporter=True)["source"] == "connection-user", "the connection's full key wins"
os.chmod(stored, 0o640)
assert c.readiness(env, none, [], reporter=True) == "unsafe-config"
assert c.unsafe_reason(env, none, [], reporter=True).kind == "reporter"
os.chmod(stored, 0o600)
link = os.path.join(work, "config-link"); real = os.path.join(work, "config-real")
os.makedirs(os.path.join(real, "devstride-plugin"), mode=0o700); shutil.copy(stored, os.path.join(real, "devstride-plugin", "x.json"))
os.symlink(os.path.join(real, "devstride-plugin", "x.json"), os.path.join(real, "devstride-plugin", "session-reporter.json"))
assert c.readiness({"XDG_CONFIG_HOME": real}, none, [], reporter=True) == "unsafe-config", "a link is refused"
clearance = open(os.path.join(sys.argv[1], "skills/release/scripts/clearance_core.py")).read()
assert "reporter=True" not in clearance and "reporter_credential" not in clearance, "release clearance never reads it"
PY
then ok "(11b) the credential is the reporter's last source only, sending the stored secret (never its fingerprint) and the registered organization id: a full key from the environment or the connection wins, other callers never see it, a file open to others or a link is unsafe-config, and release clearance never reads it"
else bad "(11b) the fourth source"; fi
REP_DS="$(server reporter)"; : > "$REP_DS/any-key"; REP_URL="http://127.0.0.1:$(cat "$REP_DS/port")"
OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="$REP_URL" python3 "$RP" check 2>&1)"; printf '%s\n' "$OUT" >> "$ALL"
CHECK1="$(printf '%s\n' "$OUT" | head -1)"
run identity; IDENT_REP="$OUT"
IDENT_FULL="$(DEVSTRIDE_PLUGIN_TEST_URL="$URL" DEVSTRIDE_API_KEY="$KEY" DEVSTRIDE_API_SECRET="$SECRET" DEVSTRIDE_ORG_ID="$ORG" python3 "$RP" identity 2>&1)"
printf '%s\n' "$IDENT_FULL" >> "$ALL"
OUT="$(env DEVSTRIDE_PLUGIN_TEST_URL="http://127.0.0.1:$(cat "$REP_DS/port")" PRESENCE_EVENT=start PRESENCE_SESSION_ID=s-rep PRESENCE_STATE=starting PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; RC=$?
if [ "$CHECK1" = "AGENT CONNECTION: READY (session reporter, registered for jane)" ] && [ "$IDENT_REP" = "KEY USER: jane" ] \
   && [ "$IDENT_FULL" = "KEY USER: keyholder" ] && [ "$RC" = 0 ] && [ -s "$REP_DS/presence.jsonl" ]; then
  ok "(11c) check names the session reporter and its member; identity names the key's member (stored for a reporter, one whoami for a full key); a report goes with the reporter credential"
else bad "(11c) check=$CHECK1 identity=$IDENT_REP full=$IDENT_FULL rc=$RC"; fi

# (11d) a reporter credential DevStride no longer knows (revoked, or replaced by another registration) is
#       set aside, whether the refusal is an HTTP 401 or the hosted address's tool error, so the machine
#       reads as keyless and registers again, the hosted address's bare gateway refusal included; a 403,
#       a refusal that names its reason or an outage keeps it; check sends nothing
REPORTER_FILE="$CONF/session-reporter.json"; SAVED="$WORK/reporter-saved.json"; cp -p "$REPORTER_FILE" "$SAVED"
restore() { rm -f "$REPORTER_FILE.refused"; cp -p "$SAVED" "$REPORTER_FILE"; }
send_rep() { OUT="$(env DEVSTRIDE_PLUGIN_TEST_URL="$REP_URL" PRESENCE_EVENT=beat PRESENCE_SESSION_ID=s-rep PRESENCE_STATE=working PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; RC=$?; }
printf 'http403' > "$REP_DS/mode"; send_rep; K403="$RC:$([ -f "$REPORTER_FILE" ] && echo kept)"
printf 'http500' > "$REP_DS/mode"; send_rep; K500="$RC:$([ -f "$REPORTER_FILE" ] && echo kept)"
printf 'http401' > "$REP_DS/mode"; send_rep; D401="$RC:$([ -f "$REPORTER_FILE" ] || echo gone):$([ -f "$REPORTER_FILE.refused" ] && echo aside)"
restore; printf 'tool401' > "$REP_DS/mode"; send_rep; DTOOL="$RC:$([ -f "$REPORTER_FILE" ] || echo gone):$([ -f "$REPORTER_FILE.refused" ] && echo aside)"
restore; printf 'toolgateway' > "$REP_DS/mode"; send_rep; DGW="$RC:$([ -f "$REPORTER_FILE" ] || echo gone):$([ -f "$REPORTER_FILE.refused" ] && echo aside)"
restore; printf 'forbidden' > "$REP_DS/mode"; send_rep; KREASON="$RC:$([ -f "$REPORTER_FILE" ] && echo kept)"
: > "$REP_DS/presence.jsonl"; rm -f "$REP_DS/mode"
OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="$REP_URL" python3 "$RP" check 2>&1)"; printf '%s\n' "$OUT" >> "$ALL"
DCHECK="$(printf '%s\n' "$OUT" | head -1)"; DSENT="$([ -s "$REP_DS/presence.jsonl" ] && echo sent || echo none)"
if [ "$K403" = "3:kept" ] && [ "$K500" = "4:kept" ] && [ "$D401" = "4:gone:aside" ] && [ "$DTOOL" = "4:gone:aside" ] \
   && [ "$DGW" = "4:gone:aside" ] && [ "$KREASON" = "4:kept" ] && [ "$DSENT" = none ] \
   && [ "$DCHECK" = "AGENT CONNECTION: READY (session reporter, registered for jane)" ]; then
  ok "(11d) a reporter credential DevStride no longer knows is set aside (HTTP 401, the tool's 401 error or the gateway's bare refusal) with exit 4, so the hook waits 2 minutes, not 30, for the next skill's registration; a 403, a reasoned refusal or an outage keeps it; check sends nothing"
else bad "(11d) 403=$K403 500=$K500 401=$D401 tool=$DTOOL gateway=$DGW reasoned=$KREASON check=$DCHECK sent=$DSENT"; fi

# (11e) check on a reporter credential that cannot be read safely: NOT READY with the fix that suits the
#       reason (chmod 600 only for a file too open, chmod 700 for a folder too open, remove a link), then
#       the PRESENCE and INTERVAL lines, exit 0
nokey; noconfig; restore
chmod 644 "$REPORTER_FILE"; UMODE="$(chk; printf '|rc=%s' "$RC")"; chmod 600 "$REPORTER_FILE"
chmod 775 "$CONF"; UFOLDER="$(chk; printf '|rc=%s' "$RC")"; chmod 700 "$CONF"
mv "$REPORTER_FILE" "$WORK/reporter-real.json"; ln -s "$WORK/reporter-real.json" "$REPORTER_FILE"; ULINK="$(chk; printf '|rc=%s' "$RC")"
rm -f "$REPORTER_FILE"; mv "$WORK/reporter-real.json" "$REPORTER_FILE"
UNR="AGENT CONNECTION: NOT READY (the session reporter credential cannot be read safely"; OFF="PRESENCE: OFF (no-key)|INTERVAL: none|rc=0"
if [ "$UMODE" = "$UNR: mode too open)|Fix: chmod 600 $REPORTER_FILE|$OFF" ] \
   && [ "$UFOLDER" = "$UNR: folder open to others)|Fix: chmod 700 $CONF|$OFF" ] \
   && [ "$ULINK" = "$UNR: a link)|Fix: remove $REPORTER_FILE; the next DevStride skill run sets up a new one|$OFF" ]; then
  ok "(11e) check on an unsafe reporter credential: chmod 600 for a file too open, chmod 700 for a folder too open, remove a link (never chmod through it); PRESENCE and INTERVAL follow, exit 0"
else bad "(11e) mode=$UMODE folder=$UFOLDER link=$ULINK"; fi

# (11f) the folder: prepare closes a folder of the user's own that group or other users have ANY access to
#       (a 0755 one too) before it writes; a credential in a folder others may write to is never read, one
#       others may only read is (the file itself is owner-only) (macOS and Linux; Windows has no mode bits)
if python3 - "$ROOT" "$WORK/rf" <<'PY'
import os, stat, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
import devstride_connection as c, portable, reporter_credential as rc
work = sys.argv[2]
env = {"XDG_CONFIG_HOME": work, "DEVSTRIDE_MACHINE_NAME": "m1"}
conf = rc.folder(env)
os.makedirs(conf)
for start in (0o777, 0o755, 0o750, 0o705, 0o711, 0o740):
    os.chmod(conf, start)
    rc.prepare(env)
    got = stat.S_IMODE(os.stat(conf).st_mode)
    assert got == 0o700, "prepare left a %o folder at %o: it must close it to 0700 before writing" % (start, got)
rc.finish({"apiKey": "k", "organizationId": "o", "organizationSlug": "s", "username": "u"}, env)
assert rc.read(env)["apiKey"] == "k"
for mode in (0o770, 0o707, 0o720):
    os.chmod(conf, mode)
    try:
        rc.read(env); raise AssertionError("read a credential in a folder others may write to: %o" % mode)
    except c.UnsafeFile as error:
        assert error.reason == "folder open to others", error.reason
    assert rc.status(env) == "NONE"
    assert c.readiness(env, os.path.join(work, "absent.json"), [], reporter=True) == "unsafe-config"
os.chmod(conf, 0o750)
assert rc.read(env)["apiKey"] == "k", "a folder others may only read is fine"
os.chmod(conf, 0o770)  # left group-writable: only the Windows exemption may pass it now
portable.IS_WINDOWS = True
assert rc.unsafe_folder(conf) is None, "Windows has no mode bits: its profile's access list guards the folder"
assert rc.foreign_folder(conf) is None
PY
then ok "(11f) prepare closes the user's own folder to 0700 before writing, whatever access group or others had (0755 too); a credential in a folder group or others may write to is refused (status NONE, unsafe-config), one they may only read is not; Windows keeps its access-list rule"
else bad "(11f) the folder's safety"; fi

# (11g) a folder another user owns, even one that cannot be traversed, or a linked folder, is named BEFORE
#       the credential is looked up: never read as no key (which would send the next skill into a
#       registration that cannot be saved); check names the folder reason and removes the folder or the link
if python3 - "$ROOT" "$WORK/rg" <<'PY'
import contextlib, importlib.util, io, os, shutil, sys
root, work = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "skills/build-item/scripts"))
import devstride_connection as c, portable, reporter_credential as rc
spec = importlib.util.spec_from_file_location("presence_report", os.path.join(root, "hooks", "presence-report.py"))
report = importlib.util.module_from_spec(spec); spec.loader.exec_module(report)
env = dict(os.environ, XDG_CONFIG_HOME=work, DEVSTRIDE_MACHINE_NAME="m1")
for name in ("DEVSTRIDE_API_KEY", "DEVSTRIDE_API_SECRET", "DEVSTRIDE_ORG_ID"):
    env.pop(name, None)
conf = rc.folder(env)
rc.prepare(env)
rc.finish({"apiKey": "k", "organizationId": "o", "organizationSlug": "s", "username": "u"}, env)
absent = os.path.join(work, "absent.json")
def check_lines():
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        report.check(env)
    return out.getvalue().splitlines()
real_uid = portable.uid
portable.uid = lambda: real_uid() + 1  # the folder (and the file in it) now belong to someone else
os.chmod(conf, 0o000)  # and it cannot be traversed: the file cannot even be looked up
try:
    try:
        rc.read(env); raise AssertionError("a folder another user owns read as no credential")
    except c.UnsafeFile as error:
        assert error.reason == "folder not yours", error.reason
    assert rc.status(env) == "NONE"
    assert c.readiness(env, absent, [], reporter=True) == "unsafe-config", "never no-key: that would ask for a registration"
    lines = check_lines()
    assert lines[0] == "AGENT CONNECTION: NOT READY (the session reporter credential cannot be read safely: folder not yours)", lines
    assert lines[1] == "Fix: remove %s; the next DevStride skill run sets up a new one" % conf, lines
finally:
    os.chmod(conf, 0o700); portable.uid = real_uid
assert rc.read(env)["apiKey"] == "k"
real = os.path.join(work, "real-folder"); shutil.move(conf, real); os.symlink(real, conf)
try:
    rc.read(env); raise AssertionError("a credential read through a linked folder")
except c.UnsafeFile as error:
    assert error.reason == "folder is a link", error.reason
os.unlink(os.path.join(real, rc.FILE_NAME))
try:
    rc.read(env); raise AssertionError("a linked folder with no credential read as no key")
except c.UnsafeFile as error:
    assert error.reason == "folder is a link", error.reason
lines = check_lines()
assert lines[1] == "Fix: remove %s; the next DevStride skill run sets up a new one" % conf, "remove the link, never the file through it: %r" % lines
portable.IS_WINDOWS = True
assert rc.foreign_folder(conf) is None, "Windows keeps its access-list rule"
PY
then ok "(11g) a folder another user owns (even one that cannot be traversed) or a linked folder is refused before the credential is looked up, never read as no key; check names the reason and removes the folder or the link itself"
else bad "(11g) a foreign or linked folder"; fi
rm -rf "$CONF"

# (12) stop-sync: a stop a person asked for is kept on this machine, acknowledged, put back when the
#      record is removed by hand, and removed once the server says it is over
SS="$(server stop)"; SURL="http://127.0.0.1:$(cat "$SS/port")"; key
STOPS="$XDG_CACHE_HOME/devstride-plugin/stop"
sync() { # sync SESSION — one stop check for SESSION against the stop server; OUT what it printed, RC its exit code
  OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="${SYNC_URL:-$SURL}" PRESENCE_SESSION_ID="$1" python3 "$RP" stop-sync 2>&1)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL"
}
asked() { # asked — what each stop check the server got carried as `acknowledged` ("-" for none), in order
  python3 -c 'import json,os,sys
p = os.path.join(sys.argv[1], "stop-sync.jsonl")
print(" ".join(json.loads(l).get("acknowledged", "-") for l in open(p)) if os.path.exists(p) else "")' "$SS"
}
kept() { # kept SESSION — the kept stop as "<id>/<by>/<reason>/<scope>/<acknowledged>", or "none", or "unreadable"
  python3 - "$ROOT" "$1" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
import session_stop
stop = session_stop.read(sys.argv[2])
print("none" if stop is None else "unreadable" if stop.get("unreadable")
      else "/".join(str(stop[k]) for k in ("id", "by", "reason", "scope", "acknowledged")))
PY
}
short() { kept "$1" | cut -d/ -f1,5; }   # short SESSION — "<id>/<acknowledged>"
keep() { # keep SESSION ID — a kept stop the server has not been told about yet
  python3 - "$ROOT" "$1" "$2" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
import session_stop
session_stop.write(sys.argv[2], session_stop.stop_of({"id": sys.argv[3], "by": {"name": "Jane Doe"}}), False)
PY
}
stop_is() { # stop_is ID [REASON-JSON] [SCOPE] — the stop the server holds open
  printf '{"id":"%s","by":{"userId":"u-1","name":"Jane Doe"},"at":"2026-11-25T20:14:00.000Z","reason":%s,"scope":"%s"}' "$1" "${2:-null}" "${3:-session}" > "$SS/stop"
}
sync st1; A="$RC:$OUT:$(kept st1):$(asked)"; [ -e "$STOPS" ] && A="$A:folder"
stop_is stop-1 '"Wrong branch"'; sync st1; B="$RC:$OUT:$(kept st1):$(asked)"
MODES="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777), oct(os.stat(os.path.dirname(sys.argv[1])).st_mode & 0o777))' "$STOPS/st1.json")"
sync st1; C="$RC:$(short st1):$(asked)"
rm -f "$STOPS/st1.json"; sync st1; D="$RC:$(short st1):$(asked)"
: > "$SS/stop-sync.jsonl"; keep st1 stop-1; E0="$(short st1)"; sync st1; E="$RC:$(short st1):$(asked)"
: > "$SS/stop-sync.jsonl"; stop_is stop-2 null organization; sync st1; F="$RC:$OUT:$(kept st1):$(asked)"
rm -f "$SS/stop"; sync st1; G="$RC:$OUT:$(kept st1)"
N0="$(asked | wc -w | tr -d ' ')"; sync 'a:b'; sync ''; H="$RC:$OUT:$(asked | wc -w | tr -d ' ')"
if [ "$A" = "0::none:-" ] && [ "$B" = "0::stop-1/Jane Doe/Wrong branch/session/True:- - stop-1" ] && [ "$MODES" = "0o600 0o700" ] \
   && [ "$C" = "0:stop-1/True:- - stop-1 -" ] && [ "$D" = "0:stop-1/True:- - stop-1 - - stop-1" ] \
   && [ "$E0" = "stop-1/False" ] && [ "$E" = "0:stop-1/True:stop-1" ] \
   && [ "$F" = "0::stop-2/Jane Doe/None/organization/True:- stop-2" ] && [ "$G" = "0::none" ] && [ "$H" = "0::$N0" ]; then
  ok "(12) stop-sync: no stop → nothing kept; a new stop → kept owner-only, then acknowledged at once; an acknowledged one → one plain call; a record removed by hand comes back; an unacknowledged one is acknowledged by the next call; a newer stop replaces it; no stop → removed; a session id no record could be kept for → no call; never any output"
else bad "(12) a=$A b=$B modes=$MODES c=$C d=$D e=$E0|$E f=$F g=$G h=$H (was $N0)"; fi

# (12b) the stop check that removes a record because the stop is over leaves the session one note for
#       its next prompt (only when this machine heard it: no name, no reason); with no record, none
noted() { # noted SESSION — the note as "<its keys>/<at is UTC ISO>/<line opens right>", then it is taken; or "none"
  python3 - "$ROOT" "$1" <<'PY2'
import json, os, re, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
import session_stop
p = session_stop.path(sys.argv[2], kind=session_stop.LIFTED)
note = json.load(open(p)) if os.path.exists(p) else None
line = session_stop.take_lifted(sys.argv[2])
if note is None:
    print("none" if line is None and not os.path.exists(p) else "stray")
else:
    print("%s/%s/%s" % (",".join(sorted(note)), bool(re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", note.get("at") or "")),
          bool(line) and line.startswith("The stop from DevStride is over") and not os.path.exists(p)))
PY2
}
N1="$(noted st1)"; N2="$(noted st1)"
sync st1; N3="$(noted st1)"
stop_is stop-3 '"Wrong branch"'; sync st1; rm -f "$SS/stop"; sync st1; N4="$(noted st1):$(kept st1)"
LMODE="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$XDG_CACHE_HOME/devstride-plugin/stop-lifted")"
if [ "$N1" = "at/True/True" ] && [ "$N2" = none ] && [ "$N3" = none ] && [ "$N4" = "at/True/True:none" ] && [ "$LMODE" = 0o700 ]; then
  ok "(12b) stop-sync: a stop that is over leaves one owner-only note (only when this machine heard it: no name, no reason), taken once; no record kept, no note"
else bad "(12b) n1=$N1 n2=$N2 n3=$N3 n4=$N4 mode=$LMODE"; fi

# (13) only a definite answer changes the record: an error, a refusal, a timeout, an unreachable server,
#      an answer that names no usable stop and a machine with no key leave it as it is, kept or absent
stop_is stop-2; sync st1; sync st2; BASE="$(short st1) $(short st2)"; rm -f "$STOPS/st2.json"
A=""; for m in http500 http429 bad-json unknown-tool http401 http403; do
  printf '%s' "$m" > "$SS/mode"; sync st1; A="$A$m=$RC:$OUT:$(short st1) "; sync st2; A="$A$RC:$(kept st2) "
done; rm -f "$SS/mode"
B=""; for t in '{"by":{"name":"x"}}' '"yes"' '{"id":""}'; do printf '%s' "$t" > "$SS/stop"; sync st1; B="$B$RC:$(short st1) "; sync st2; B="$B$RC:$(kept st2) "; done
SYNC_URL="$DEADURL"; sync st1; C="$RC:$OUT:$(short st1)"; sync st2; C="$C $RC:$(kept st2)"
SYNC_URL="http://127.0.0.1:$(cat "$SLOW/port")"; export DEVSTRIDE_PRESENCE_TIMEOUT=0.5; sync st1; D="$RC:$OUT:$(short st1)"; sync st2; D="$D $RC:$(kept st2)"
unset SYNC_URL DEVSTRIDE_PRESENCE_TIMEOUT
stop_is stop-2; nokey; sync st1; E="$RC:$OUT:$(short st1)"; sync st2; E="$E $RC:$(kept st2)"; key
printf 'not json' > "$STOPS/st1.json"; U0="$(kept st1)"; printf http500 > "$SS/mode"; sync st1; U1="$RC:$(kept st1)"; rm -f "$SS/mode"
sync st1; U2="$RC:$(short st1)"
printf 'not json' > "$STOPS/st1.json"; rm -f "$SS/stop"; sync st1; U3="$RC:$(kept st1)"
WANT=""; for m in http500=4 http429=4 bad-json=4 unknown-tool=3 http401=3 http403=3; do WANT="$WANT$m::stop-2/True ${m#*=}:none "; done
if [ "$BASE" = "stop-2/True stop-2/True" ] && [ "$A" = "$WANT" ] && [ "$B" = "4:stop-2/True 4:none 4:stop-2/True 4:none 4:stop-2/True 4:none " ] \
   && [ "$C" = "4::stop-2/True 4:none" ] && [ "$D" = "4::stop-2/True 4:none" ] && [ "$E" = "4::stop-2/True 4:none" ] \
   && [ "$U0" = unreadable ] && [ "$U1" = "4:unreadable" ] && [ "$U2" = "0:stop-2/True" ] && [ "$U3" = "0:none" ]; then
  ok "(13) stop-sync keeps the record as it is, kept or absent, on HTTP 500 and 429, a bad answer, a stop with no usable id, an unreachable server, a timeout and a machine with no key (exit 4) and on no such tool, 401 and 403 (exit 3); a record that cannot be read is replaced by an open stop and removed when there is none"
else bad "(13) base=$BASE a=$A (want $WANT) b=$B c=$C d=$D e=$E u=$U0|$U1|$U2|$U3"; fi

# (13b) a machine whose only credential is the session reporter's checks for a stop with it (a server
#       that takes only that credential's key, secret and organization answers), and no refusal sets
#       it aside: the tool's 401 error and the gateway's bare refusal exit 4 (asked again at the next
#       check), an HTTP 401 or 403 exits 3, nothing is printed, and the credential stays each time; a
#       full key wins over it (the stop server, which takes only the full key, answers it)
nokey; mkdir -p "$CONF"; chmod 700 "$CONF"; cp -p "$SAVED" "$REPORTER_FILE"; rm -f "$REPORTER_FILE.refused"
RSS="$WORK/ds-reporter-stop"; mkdir -p "$RSS"
python3 - "$SAVED" "$FX/fake-devstride.py" "$RSS" >/dev/null 2>&1 <<'PY' &
import json, os, sys
stored = json.load(open(sys.argv[1]))  # the drill's own throwaway credential; nothing is printed
env = dict(os.environ, FAKE_DS_KEY=stored["apiKey"], FAKE_DS_SECRET=stored["secret"], FAKE_DS_ORG=stored["organizationId"])
os.execve(sys.executable, [sys.executable, sys.argv[2], sys.argv[3]], env)
PY
echo "$!" >> "$WORK/pids"; n=0; until [ -s "$RSS/port" ] || [ $n -gt 100 ]; do sleep 0.05; n=$((n + 1)); done
SYNC_URL="http://127.0.0.1:$(cat "$RSS/port")"
calls() { [ -f "$RSS/stop-sync.jsonl" ] && wc -l < "$RSS/stop-sync.jsonl" | tr -d ' ' || echo 0; }
sync st7; A="$RC:$OUT:$(kept st7):$(calls)"
B=""; for m in tool401 toolgateway http401 http403; do
  printf '%s' "$m" > "$RSS/mode"; sync st7
  B="$B$m=$RC:$OUT:$([ -f "$REPORTER_FILE" ] && echo kept)$([ -e "$REPORTER_FILE.refused" ] && echo :aside) "
done; rm -f "$RSS/mode"
key; unset SYNC_URL; N0="$(wc -l < "$SS/stop-sync.jsonl")"; sync st7
C="$RC:$OUT:$(( $(wc -l < "$SS/stop-sync.jsonl") - N0 )):$(calls)"
rm -rf "$CONF"
if [ "$A" = "0::none:1" ] && [ "$B" = "tool401=4::kept toolgateway=4::kept http401=3::kept http403=3::kept " ] && [ "$C" = "0::1:1" ]; then
  ok "(13b) a machine whose only credential is the session reporter's checks for a stop with it; a refusal never sets it aside: the tool's 401 error and the gateway's bare refusal exit 4 (asked again at the next check), an HTTP 401 or 403 exits 3, nothing is printed, and the credential stays each time; a full key wins over it (the server that takes only the full key answers, the reporter's server is not asked)"
else bad "(13b) a=$A b=$B c=$C"; fi

# (14) a recorded report's answer may carry the stop too: it is kept, never acknowledged or removed by a report
beat() { # beat SESSION — one working beat for SESSION against the stop server
  OUT="$(DEVSTRIDE_PLUGIN_TEST_URL="$SURL" PRESENCE_EVENT=beat PRESENCE_SESSION_ID="$1" PRESENCE_STATE=working PRESENCE_MACHINE=m9 python3 "$RP" 2>&1)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL"
}
: > "$SS/stop-sync.jsonl"; stop_is stop-4 '"Hold on"'
beat st5; A="$RC:$OUT:$(kept st5)"
sync st5; B="$RC:$(short st5):$(asked)"
beat st5; C="$RC:$(short st5)"
printf stale > "$SS/presence-outcome"; beat st6; D="$RC:$(kept st6)"; rm -f "$SS/presence-outcome"
rm -f "$SS/stop"; beat st5; E="$RC:$(short st5)"
if [ "$A" = "0::stop-4/Jane Doe/Hold on/session/False" ] && [ "$B" = "0:stop-4/True:stop-4" ] && [ "$C" = "0:stop-4/True" ] \
   && [ "$D" = "0:none" ] && [ "$E" = "0:stop-4/True" ]; then
  ok "(14) a recorded report whose answer carries a stop keeps it, unacknowledged, and the next stop check acknowledges it in one call; a later report keeps the acknowledgement; an answer that is not a renewal keeps nothing; a report with no stop on its answer never removes one"
else bad "(14) a=$A b=$B c=$C d=$D e=$E"; fi

# (9) across every captured output, and everything the reporter left on disk: no key, secret or organization id
if ! grep -rqF -e "$KEY" -e "$SECRET" -e "$ORG" "$ALL" "$XDG_CACHE_HOME" 2>/dev/null \
   && ! grep -qF -e "$SECRET" -e "$ORG" "$DS/presence.jsonl" && ! grep -qF "$KEY" "$DS/presence.jsonl"; then
  ok "(9) no output of the reporter, check or prove, no file it left, and no report body holds the key, the secret or the organization id"
else bad "(9) a secret leaked: $(grep -rlF -e "$KEY" -e "$SECRET" -e "$ORG" "$ALL" "$XDG_CACHE_HOME" "$DS/presence.jsonl" 2>/dev/null)"; fi

exit $FAIL
