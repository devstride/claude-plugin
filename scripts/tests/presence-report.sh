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
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" CLAUDE_CONFIG_DIR="$WORK/claude"; mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$WORK/dir"
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

# (9) across every captured output, and everything the reporter left on disk: no key, secret or organization id
if ! grep -rqF -e "$KEY" -e "$SECRET" -e "$ORG" "$ALL" "$XDG_CACHE_HOME" 2>/dev/null \
   && ! grep -qF -e "$SECRET" -e "$ORG" "$DS/presence.jsonl" && ! grep -qF "$KEY" "$DS/presence.jsonl"; then
  ok "(9) no output of the reporter, check or prove, no file it left, and no report body holds the key, the secret or the organization id"
else bad "(9) a secret leaked: $(grep -rlF -e "$KEY" -e "$SECRET" -e "$ORG" "$ALL" "$XDG_CACHE_HOME" "$DS/presence.jsonl" 2>/dev/null)"; fi

exit $FAIL
