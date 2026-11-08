#!/bin/bash
# Deterministic tests for hooks/presence.py — every session reports itself through the repository's
# own presence command. Each case runs against a private cache and throwaway repositories; the
# "repository command" appends its environment to a log, so a case reads exactly what was sent.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$ROOT/hooks/presence.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"
cleanup() { # stop the stand-in owners and every keeper the cases started
  for p in $(cat "$WORK/owners" 2>/dev/null) $(cat "$XDG_CACHE_HOME"/devstride-plugin/presence/*.json 2>/dev/null \
      | python3 -c 'import json,sys; [print(json.loads(l).get("keeper") or "") for l in sys.stdin if l.strip()]' 2>/dev/null); do
    kill "$p" 2>/dev/null
  done
  chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT
export XDG_CACHE_HOME="$WORK/cache"
RECORDS="$XDG_CACHE_HOME/devstride-plugin/presence"
LOG="$WORK/sent.log"
ITEM_NO="I$((20000 + 100))"   # an example item number, built at run time (public-repo hygiene)

PLUGIN="$WORK/plugin"; mkdir -p "$PLUGIN/.claude-plugin"
printf '{"name":"devstride","version":"9.8.7"}' > "$PLUGIN/.claude-plugin/plugin.json"
export CLAUDE_PLUGIN_ROOT="$PLUGIN"

# The repository's command: one JSON line per send, with every exported variable it should see.
REPORT='python3 -c "import json,os; print(json.dumps({k:v for k,v in os.environ.items() if k.startswith(\"PRESENCE_\") or k in (\"CLAUDE_CODE_SESSION_ID\",\"CLAUDE_PID\")}))" >> '"$LOG"
mkrepo() { # mkrepo NAME [CONFIG-JSON] [BRANCH]
  local d="$WORK/$1"; mkdir -p "$d/.claude"; git -C "$d" init -q -b "${3:-main}" 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "${2:-{\}}" > "$d/.claude/ds-config.json"; printf '%s' "$d"
}
config() { python3 -c 'import json,sys; print(json.dumps({"presence":{"command":sys.argv[1],"intervalMinutes":int(sys.argv[2])}}))' "$REPORT" "${1:-5}"; }
fire() { # fire EVENT SESSION CWD [REASON] — run the hook as Claude Code does; prints its stdout
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":sys.argv[1],"session_id":sys.argv[2],"cwd":sys.argv[3],"reason":sys.argv[4]}))' \
    "$1" "$2" "$3" "${4:-}" | python3 "$HOOK" hook
}
sent() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
wait_sent() { # wait_sent N — until the log holds N lines (detached sends), at most 10 s
  local i=0; while [ "$(sent)" -lt "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(sent)" -ge "$1" ]
}
field() { sed -n "${1}p" "$LOG" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$2"; }
age() { # age SESSION SECONDS — pretend the last send was SECONDS ago
  python3 - "$RECORDS/$1.json" "$2" <<'PY'
import json, sys, time
p = sys.argv[1]; r = json.load(open(p)); r["sent"] = time.time() - float(sys.argv[2]); json.dump(r, open(p, "w"))
PY
}
owner() { sleep 300 >/dev/null 2>&1 & echo "$!" >> "$WORK/owners"; echo "$!"; }  # a stand-in Claude Code process

R="$(mkrepo repo "$(config)" "phil/26-01-01/$ITEM_NO-some-story")"

# (1) no block, a null block, or a directory outside any repository: silent, nothing written
N="$(mkrepo plain '{"presence":null}')"; mkdir -p "$WORK/loose"
OUT="$(fire SessionStart s0 "$WORK/$(basename "$(mkrepo none)")")$(fire SessionStart s0 "$N")$(fire UserPromptSubmit s0 "$WORK/loose")"
sleep 0.5
if [ -z "$OUT" ] && [ ! -e "$RECORDS/s0.json" ] && [ "$(sent)" = 0 ]; then ok "(1) no presence block / null / no repository → silent, nothing written or sent"
else bad "(1) out=$OUT sent=$(sent)"; fi

# (2) session start sends `start` with every documented variable; the record is owner-only
O1="$(owner)"
mkdir -p "$R/sub/dir"
OUT="$(CLAUDE_PID="$O1" fire SessionStart s1 "$R/sub/dir" 2>&1)"
if [ -z "$OUT" ] && wait_sent 1 && [ "$(field 1 PRESENCE_EVENT)" = start ] && [ "$(field 1 PRESENCE_STATE)" = starting ] \
  && [ "$(field 1 PRESENCE_SESSION_ID)" = s1 ] && [ "$(field 1 CLAUDE_CODE_SESSION_ID)" = s1 ] && [ "$(field 1 CLAUDE_PID)" = "$O1" ] \
  && [ "$(field 1 PRESENCE_CHECKOUT)" = "$(cd "$R" && pwd -P)" ] && [ "$(field 1 PRESENCE_BRANCH)" = "phil/26-01-01/$ITEM_NO-some-story" ] \
  && [ "$(field 1 PRESENCE_ITEM)" = "$ITEM_NO" ] && [ "$(field 1 PRESENCE_PLUGIN_VERSION)" = 9.8.7 ] \
  && [ "$(field 1 PRESENCE_INTERVAL_MINUTES)" = 5 ] && [ -n "$(field 1 PRESENCE_MACHINE)" ] && [ -z "$(field 1 PRESENCE_END_REASON)" ] \
  && [ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$RECORDS/s1.json")" = 0o600 ]; then
  ok "(2) SessionStart → start: state, session, CLAUDE_PID, checkout root, branch, item, version, interval, machine; mode 600"
else bad "(2) out=$OUT $(cat "$LOG" 2>/dev/null)"; fi

# (3) a prompt right after a send waits; a prompt a minute later beats as working
fire UserPromptSubmit s1 "$R" >/dev/null; sleep 0.5; A="$(sent)"
age s1 61; fire UserPromptSubmit s1 "$R" >/dev/null
if [ "$A" = 1 ] && wait_sent 2 && [ "$(field 2 PRESENCE_EVENT)" = beat ] && [ "$(field 2 PRESENCE_STATE)" = working ]; then
  ok "(3) prompt within a minute → nothing; a minute later → beat (working)"
else bad "(3) a=$A $(cat "$LOG")"; fi

# (4) a finished turn is a state change: sent after 30 s, held before; a repeat Stop sends nothing
fire Stop s1 "$R" >/dev/null; sleep 0.5; B="$(sent)"           # waiting, held
age s1 31; fire Stop s1 "$R" >/dev/null                           # the held change is sent now
wait_sent 3; age s1 31; fire Stop s1 "$R" >/dev/null; sleep 0.5   # unchanged: nothing
if [ "$B" = 2 ] && [ "$(sent)" = 3 ] && [ "$(field 3 PRESENCE_STATE)" = waiting ] && [ "$(field 3 PRESENCE_EVENT)" = beat ]; then
  ok "(4) Stop within 30 s → held; the next Stop sends it (waiting); an unchanged state sends nothing more"
else bad "(4) b=$B $(cat "$LOG")"; fi

# (5) session end sends `end` with the reason, once; a resumed session starts again
: > "$LOG"
fire SessionEnd s1 "$R" clear >/dev/null; fire SessionEnd s1 "$R" clear >/dev/null
wait_sent 1; sleep 0.5; C="$(sent)"
fire SessionStart s1 "$R" >/dev/null
if [ "$C" = 1 ] && [ "$(field 1 PRESENCE_EVENT)" = end ] && [ "$(field 1 PRESENCE_END_REASON)" = clear ] \
  && [ "$(field 1 PRESENCE_STATE)" = ended ] && wait_sent 2 && [ "$(field 2 PRESENCE_EVENT)" = start ]; then
  ok "(5) SessionEnd → end (reason clear) once; resume after it → start"
else bad "(5) c=$C $(cat "$LOG")"; fi

# (6) Stop or SessionEnd for a session never reported here sends nothing
: > "$LOG"
fire Stop s6 "$R" >/dev/null; fire SessionEnd s6 "$R" other >/dev/null; sleep 0.5
if [ "$(sent)" = 0 ] && [ ! -e "$RECORDS/s6.json" ]; then ok "(6) Stop / SessionEnd with no record → nothing"
else bad "(6) $(cat "$LOG")"; fi

# (7) a prompt in a session that began before the block existed starts it (start, not beat)
fire UserPromptSubmit s7 "$R" >/dev/null
if wait_sent 1 && [ "$(field 1 PRESENCE_EVENT)" = start ] && [ "$(field 1 PRESENCE_STATE)" = working ]; then
  ok "(7) first prompt with no record → start (working)"
else bad "(7) $(cat "$LOG")"; fi

# (8) the keeper beats while the owner lives, sends `end` (reason gone) when it dies, then exits
: > "$LOG"
K="$(mkrepo keeper "$(config 1)")"
O8="$(owner)"
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O8" fire SessionStart s8 "$K" >/dev/null
wait_sent 3; BEATS="$(grep -c '"PRESENCE_EVENT": "beat"' "$LOG")"
KEEPER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keeper"])' "$RECORDS/s8.json")"
kill "$O8" 2>/dev/null; wait "$O8" 2>/dev/null
i=0; while ! grep -q '"PRESENCE_EVENT": "end"' "$LOG" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.6
if [ "$BEATS" -ge 2 ] && grep -q '"PRESENCE_END_REASON": "gone"' "$LOG" && ! kill -0 "$KEEPER" 2>/dev/null \
  && [ "$(tail -1 "$LOG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["PRESENCE_EVENT"])')" = end ]; then
  ok "(8) keeper → beats every interval; owner gone → end (reason gone), keeper exits"
else bad "(8) beats=$BEATS keeper=$KEEPER $(cat "$LOG")"; fi

# (9) the keeper of an ended session sends nothing more and exits
: > "$LOG"
O9="$(owner)"
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O9" fire SessionStart s9 "$K" >/dev/null
wait_sent 1; KEEPER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("keeper",0))' "$RECORDS/s9.json")"
fire SessionEnd s9 "$K" logout >/dev/null; wait_sent 2; sleep 1.2
if [ "$(sent)" = 2 ] && [ "$(field 2 PRESENCE_EVENT)" = end ] && ! kill -0 "$KEEPER" 2>/dev/null; then
  ok "(9) SessionEnd → the keeper sends nothing more and exits"
else bad "(9) keeper=$KEEPER $(cat "$LOG")"; fi

# (10) a failing command's exit code is kept; an out-of-range interval reads as 5
F="$(mkrepo failing '{"presence":{"command":"exit 7","intervalMinutes":0}}')"
fire SessionStart s10 "$F" >/dev/null
i=0; while ! grep -q '"last"' "$RECORDS/s10.json" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
L="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["last"]["event"], r["last"]["exit"])' "$RECORDS/s10.json" 2>/dev/null)"
X="$(mkrepo interval "$(config 0)")"; : > "$LOG"; fire SessionStart s10b "$X" >/dev/null
if [ "$L" = "start 7" ] && wait_sent 1 && [ "$(field 1 PRESENCE_INTERVAL_MINUTES)" = 5 ]; then
  ok "(10) failing command → exit 7 recorded; intervalMinutes 0 → 5"
else bad "(10) last=$L $(cat "$LOG")"; fi

# (11) fails open: bad payloads, a bad session id, an unwritable cache — exit 0, silent
O=""; RC=0
for p in 'not json' '[]' '{"hook_event_name":"SessionStart","session_id":"../x","cwd":"'"$R"'"}' '{"hook_event_name":"Other","session_id":"ok","cwd":"'"$R"'"}'; do
  O="$O$(printf '%s' "$p" | python3 "$HOOK" hook 2>&1)"; RC=$((RC + $?))
done
chmod 500 "$RECORDS"
O="$O$(fire SessionStart s11 "$R" 2>&1)"; RC=$((RC + $?))
chmod 700 "$RECORDS"
O="$O$(python3 "$HOOK" 2>&1)$(python3 "$HOOK" send bogus s1 2>&1)$(DEVSTRIDE_PRESENCE_MINUTE=x python3 "$HOOK" keeper nobody 2>&1)"; RC=$((RC + $?))
if [ "$RC" = 0 ] && [ -z "$O" ] && [ ! -e "$XDG_CACHE_HOME/devstride-plugin/x.json" ] && [ ! -e "$RECORDS/s11.json" ]; then
  ok "(11) malformed payload / bad session id / unknown event / unwritable cache / bad args → exit 0, silent"
else bad "(11) rc=$RC out=$O"; fi

# (12) hooks.json registers the hook on all four events, bounded and failing open
if python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
for event in ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"):
    found = [c for g in h[event] for c in g["hooks"] if "hooks/presence.py\" hook" in c["command"]]
    assert len(found) == 1 and found[0].get("timeout") == 5 and found[0]["command"].endswith("exit 0"), event
PY
then ok "(12) hooks.json → presence hook on SessionStart, UserPromptSubmit, Stop, SessionEnd (timeout 5, exit 0)"
else bad "(12) hooks.json registration"; fi

exit $FAIL
