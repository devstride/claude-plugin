#!/bin/bash
# Deterministic tests for hooks/presence.py — every session reports itself through the repository's
# own presence command. Each case runs against a private cache and throwaway repositories; the
# "repository command" appends its environment to a log, so a case reads exactly what was sent.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$ROOT/hooks/presence.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"
cleanup() { # stop the stand-in owners and every keeper the cases started (keepers exit on their own too)
  for p in $(cat "$WORK/owners" 2>/dev/null); do kill "$p" 2>/dev/null; done
  for sid in $(ls "$RECORDS" 2>/dev/null | sed -n 's/\.json$//p'); do pkill -f "presence.py keeper $sid\$" 2>/dev/null; done
  chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT
export XDG_CACHE_HOME="$WORK/cache"
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID   # the cases name their own stand-in process
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
fire() { # fire EVENT SESSION CWD [REASON-OR-SOURCE] [EXTRA-JSON] — run the hook as Claude Code does; prints its
  #        stdout. EXTRA-JSON (an object) is merged into the payload: tool_name, tool_use_id, agent_id, …
  python3 -c 'import json,sys; p={"hook_event_name":sys.argv[1],"session_id":sys.argv[2],"cwd":sys.argv[3],"reason":sys.argv[4],"source":sys.argv[4]}; p.update(json.loads(sys.argv[5] or "{}")); print(json.dumps(p))' \
    "$1" "$2" "$3" "${4:-}" "${5:-}" | python3 "$HOOK" hook
}
sent() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
wait_sent() { # wait_sent N — until the log holds N lines (detached sends), at most 10 s
  local i=0; while [ "$(sent)" -lt "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(sent)" -ge "$1" ]
}
field() { sed -n "${1}p" "$LOG" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$2"; }
age() { # age SESSION SECONDS — pretend the last send was SECONDS ago
  python3 - "$RECORDS/$1.json" "$2" <<'PY'
import json, os, sys, time
p = sys.argv[1]; r = json.load(open(p)); r["sent"] = time.time() - float(sys.argv[2])
json.dump(r, open(p + ".t", "w")); os.replace(p + ".t", p)   # atomic, as a running keeper may read it
PY
}
edit() { # edit SESSION PYTHON — change the record atomically (r is the record)
  python3 - "$RECORDS/$1.json" "$2" <<'PY'
import json, os, sys
p = sys.argv[1]; r = json.load(open(p)); exec(sys.argv[2])
json.dump(r, open(p + ".t", "w")); os.replace(p + ".t", p)
PY
}
stop_keeper() { # stop_keeper SESSION — kill its keeper and wait until the lock is free
  pkill -f "presence.py keeper $1\$" 2>/dev/null
  local i=0; while keeper_alive "$1" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
keeper_alive() { # keeper_alive SESSION — is a keeper holding the session's keeper lock?
  python3 - "$RECORDS/$1.keeper.lock" <<'PY'
import fcntl, os, sys
try:
    fd = os.open(sys.argv[1], os.O_RDWR)
except OSError:
    sys.exit(1)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sys.exit(1)
except OSError:
    sys.exit(0)
PY
}
owner() { sleep 300 >/dev/null 2>&1 & echo "$!" >> "$WORK/owners"; echo "$!"; }  # a stand-in Claude Code process

R="$(mkrepo repo "$(config)" "phil/26-01-01/$ITEM_NO-some-story")"

# (1) no block, a null block, or a directory outside any repository: silent, nothing written
N="$(mkrepo plain '{"presence":null}')"; mkdir -p "$WORK/loose"
OUT="$(fire SessionStart s0 "$WORK/$(basename "$(mkrepo none)")")$(fire SessionStart s0 "$N")$(fire UserPromptSubmit s0 "$WORK/loose")"
sleep 0.5
if [ -z "$OUT" ] && [ ! -e "$XDG_CACHE_HOME/devstride-plugin" ] && [ "$(sent)" = 0 ]; then ok "(1) no presence block / null / no repository → silent, no directory or file created, nothing sent"
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
age s1 61; fire Stop s1 "$R" >/dev/null                           # a finished turn after the end: nothing
wait_sent 1; sleep 0.5; C="$(sent)"; ST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$RECORDS/s1.json")"
fire SessionStart s1 "$R" >/dev/null
if [ "$C" = 1 ] && [ "$ST" = ended ] && [ "$(field 1 PRESENCE_EVENT)" = end ] && [ "$(field 1 PRESENCE_END_REASON)" = clear ] \
  && [ "$(field 1 PRESENCE_STATE)" = ended ] && wait_sent 2 && [ "$(field 2 PRESENCE_EVENT)" = start ]; then
  ok "(5) SessionEnd → end (reason clear) once; Stop after it → nothing; resume after it → start"
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
keeper_alive s8; KEEPER=$?
kill "$O8" 2>/dev/null; wait "$O8" 2>/dev/null
i=0; while ! grep -q '"PRESENCE_EVENT": "end"' "$LOG" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.6
if [ "$BEATS" -ge 2 ] && grep -q '"PRESENCE_END_REASON": "gone"' "$LOG" && [ "$KEEPER" = 0 ] && ! keeper_alive s8 \
  && [ "$(tail -1 "$LOG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["PRESENCE_EVENT"])')" = end ]; then
  ok "(8) keeper → beats every interval; owner gone → end (reason gone), keeper exits"
else bad "(8) beats=$BEATS keeper=$KEEPER $(cat "$LOG")"; fi

# (9) the keeper of an ended session sends nothing more and exits at its next check
: > "$LOG"; K5="$(mkrepo keeper5 "$(config 5)")"
O9="$(owner)"
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O9" fire SessionStart s9 "$K5" >/dev/null
wait_sent 1; sleep 0.2; keeper_alive s9; KEEPER=$?
fire SessionEnd s9 "$K5" logout >/dev/null; wait_sent 2; sleep 0.3
if [ "$KEEPER" = 0 ] && ! keeper_alive s9 && sleep 2.5 && [ "$(sent)" = 2 ] && [ "$(field 2 PRESENCE_EVENT)" = end ]; then
  ok "(9) SessionEnd → the keeper exits at its next check (well inside the interval) and sends nothing more"
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
# An unwritable cache: its own, where a plain file holds the records directory's place. Unwritable
# for every user, root included (root writes through a read-only mode bit, as in a container), and
# out of reach of the keepers earlier cases left running in the shared cache, which recreate it.
C11="$WORK/cache11"; mkdir -p "$C11/devstride-plugin"; : > "$C11/devstride-plugin/presence"
O="$O$(XDG_CACHE_HOME="$C11" fire SessionStart s11 "$R" 2>&1)"; RC=$((RC + $?))
O="$O$(python3 "$HOOK" 2>&1)$(python3 "$HOOK" send bogus starting s1 ab 9 1 2>&1)$(python3 "$HOOK" send beat working s1 ab x 1 2>&1)$(python3 "$HOOK" send beat bogus s1 ab 9 1 2>&1)$(DEVSTRIDE_PRESENCE_MINUTE=x python3 "$HOOK" keeper nobody 2>&1)"; RC=$((RC + $?))
if [ "$RC" = 0 ] && [ -z "$O" ] && [ ! -e "$XDG_CACHE_HOME/devstride-plugin/x.json" ] && [ ! -e "$RECORDS/s11.json" ] \
  && [ ! -e "$RECORDS/nobody.keeper.lock" ] && [ -f "$C11/devstride-plugin/presence" ] \
  && [ "$(ls -A "$C11/devstride-plugin")" = presence ]; then
  ok "(11) malformed payload / bad session id / unknown event / unwritable cache / bad args → exit 0, silent"
else bad "(11) rc=$RC out=$O"; fi

# (13) the session moves to a checkout without the block: Stop and SessionEnd still report, under the old one
: > "$LOG"; M="$(mkrepo moved '{}')"
fire SessionStart s13 "$R" >/dev/null; wait_sent 1
age s13 31; fire Stop s13 "$M" >/dev/null; wait_sent 2
fire SessionEnd s13 "$M" clear >/dev/null; wait_sent 3; sleep 0.3
if [ "$(sent)" = 3 ] && [ "$(field 2 PRESENCE_STATE)" = waiting ] && [ "$(field 3 PRESENCE_EVENT)" = end ] \
  && [ "$(field 3 PRESENCE_CHECKOUT)" = "$(cd "$R" && pwd -P)" ]; then
  ok "(13) moved to a checkout without the block → Stop and SessionEnd still sent, under the checkout it came from"
else bad "(13) $(cat "$LOG")"; fi

# (14) moving between two configured checkouts beats from the new one, never a second start
: > "$LOG"; R2="$(mkrepo second "$(config)")"
fire SessionStart s14 "$R" >/dev/null; wait_sent 1
fire UserPromptSubmit s14 "$R2" >/dev/null; wait_sent 2; sleep 0.3
if [ "$(sent)" = 2 ] && [ "$(field 2 PRESENCE_EVENT)" = beat ] && [ "$(field 2 PRESENCE_CHECKOUT)" = "$(cd "$R2" && pwd -P)" ]; then
  ok "(14) prompt in another configured checkout → beat from it (no second start)"
else bad "(14) $(cat "$LOG")"; fi

# (15) a session resumed in a new process right after a clean exit, while the old keeper still
#      holds its lock: no false "gone", the new process is reported, and a keeper keeps running
: > "$LOG"
OA="$(owner)"; DEVSTRIDE_PRESENCE_MINUTE=3 CLAUDE_PID="$OA" fire SessionStart s15 "$K5" >/dev/null; wait_sent 1; sleep 0.2
fire SessionEnd s15 "$K5" prompt_input_exit >/dev/null
OB="$(owner)"; kill "$OA"; wait "$OA" 2>/dev/null
DEVSTRIDE_PRESENCE_MINUTE=3 CLAUDE_PID="$OB" fire SessionStart s15 "$K5" resume >/dev/null; wait_sent 3; sleep 1.5
if ! grep -q '"PRESENCE_END_REASON": "gone"' "$LOG" && [ "$(field 3 PRESENCE_EVENT)" = start ] \
  && [ "$(field 3 CLAUDE_PID)" = "$OB" ] && keeper_alive s15; then
  ok "(15) resume in a new process after a clean exit → start with the new process, no false end, keeper running"
else bad "(15) $(cat "$LOG")"; fi
stop_keeper s15   # its owner lives on: left running, it beats into the shared log of every later case

# (16) reports run one at a time and in order: an end queued with a beat never ends up before it
: > "$LOG"
SLOW="$(mkrepo slow "$(python3 -c 'import json,sys; print(json.dumps({"presence":{"command":"sleep 0.4; "+sys.argv[1]}}))' "$REPORT")")"
fire SessionStart s16 "$SLOW" >/dev/null; age s16 31
fire Stop s16 "$SLOW" >/dev/null; fire SessionEnd s16 "$SLOW" logout >/dev/null; sleep 2.5
LASTEV="$(tail -1 "$LOG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["PRESENCE_EVENT"])' 2>/dev/null)"
if [ "$LASTEV" = end ] && [ "$(grep -c '"PRESENCE_EVENT": "end"' "$LOG")" = 1 ] && [ -n "$(field 1 PRESENCE_AT)" ]; then
  ok "(16) a beat and an end queued together → end last, once; PRESENCE_AT set"
else bad "(16) $(cat "$LOG")"; fi

# (17) a keeper lock nobody holds (a stale record from before a reboot) does not stop a new keeper
: > "$LOG"; O17="$(owner)"
CLAUDE_PID="$O17" fire SessionStart s17 "$K5" >/dev/null; wait_sent 1
stop_keeper s17; KBEFORE=0; keeper_alive s17 && KBEFORE=1
edit s17 'r["owner"] = 99998; r["ownerStarted"] = 1'
CLAUDE_PID="$O17" fire SessionStart s17 "$K5" resume >/dev/null; wait_sent 2
i=0; while ! keeper_alive s17 && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if [ "$KBEFORE" = 0 ] && keeper_alive s17 && [ "$(field 2 PRESENCE_EVENT)" = start ] && [ "$(field 2 CLAUDE_PID)" = "$O17" ]; then
  ok "(17) stale record → resume sends start with the live process and starts a keeper"
else bad "(17) $(cat "$LOG")"; fi

# (18) an automatic compaction mid-turn changes nothing; a prompt larger than 64 KB still reports
: > "$LOG"
fire SessionStart s18 "$R" >/dev/null; wait_sent 1; age s18 61
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"SessionStart","source":"compact","session_id":"s18","cwd":sys.argv[1]}))' "$R" | python3 "$HOOK" hook
python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"s18","cwd":sys.argv[1],"prompt":"x"*200000}))' "$R" | python3 "$HOOK" hook
wait_sent 2; sleep 0.3
if [ "$(sent)" = 2 ] && [ "$(field 2 PRESENCE_EVENT)" = beat ] && [ "$(field 2 PRESENCE_STATE)" = working ]; then
  ok "(18) SessionStart source compact → ignored; a 200 KB prompt → beat (working)"
else bad "(18) $(cat "$LOG")"; fi

# (19) the keeper sends a held state change once 30 seconds pass, with no hook firing
: > "$LOG"; O19="$(owner)"
K60="$(mkrepo keeper60 "$(config 60)")"   # the ordinary beat is 60 s away: only the held change can send
DEVSTRIDE_PRESENCE_MINUTE=1 CLAUDE_PID="$O19" fire SessionStart s19 "$K60" >/dev/null; wait_sent 1
fire Stop s19 "$K60" >/dev/null; sleep 0.5; H="$(sent)"           # held: within 30 s of the start
age s19 31; wait_sent 2; sleep 0.3
if [ "$H" = 1 ] && [ "$(sent)" = 2 ] && [ "$(field 2 PRESENCE_EVENT)" = beat ] && [ "$(field 2 PRESENCE_STATE)" = waiting ]; then
  ok "(19) Stop held within 30 s → the keeper sends it (beat, waiting) once 30 s pass"
else bad "(19) h=$H $(cat "$LOG")"; fi
stop_keeper s19   # likewise: its next beat would land in a later case

# (20) a report overtaken by a newer one, or queued by a record since replaced, is dropped
: > "$LOG"
fire SessionStart s20 "$R" >/dev/null; wait_sent 1; stop_keeper s20
ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$RECORDS/s20.json")"
NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
python3 "$HOOK" send start starting s20 "$ID" 3 "$NOW_MS"; python3 "$HOOK" send end ended s20 "$ID" 2 "$NOW_MS"
python3 "$HOOK" send beat working s20 "$ID" 3 "$NOW_MS"; python3 "$HOOK" send beat working s20 0123456789ab 9 "$NOW_MS"; sleep 0.3
DONE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["done"])' "$RECORDS/s20.json")"
if [ "$(sent)" = 2 ] && [ "$(field 2 PRESENCE_EVENT)" = start ] && [ "$DONE" = 3 ] && [ "$(field 1 PRESENCE_AT)" -gt 1000000000000 ]; then
  ok "(20) sequence 3 (start) ran → 2 (end), a repeat of 3 and another record's 9 dropped; PRESENCE_AT in ms"
else bad "(20) $(cat "$LOG")"; fi

# (21) a resume re-reads the process start time even when the process id is the same number
: > "$LOG"; O21="$(owner)"
CLAUDE_PID="$O21" fire SessionStart s21 "$R" >/dev/null; wait_sent 1
edit s21 'r["ownerStarted"] = 1'
CLAUDE_PID="$O21" fire SessionStart s21 "$R" resume >/dev/null; wait_sent 2
W="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ownerStarted"])' "$RECORDS/s21.json")"
REAL="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$O21" | python3 -c 'import calendar,sys,time; print(calendar.timegm(time.strptime(" ".join(sys.stdin.read().split()), "%a %b %d %H:%M:%S %Y")))')"
if [ "$W" = "$REAL" ]; then
  ok "(21) resume with the same process id → its start time re-read (no false gone after a reboot)"
else bad "(21) ownerStarted=$W"; fi

# (22) a failing `ps` never reads as a replaced process: the keeper keeps beating, no end
: > "$LOG"; O22="$(owner)"; mkdir -p "$WORK/badps"; printf '#!/bin/sh\nexit 1\n' > "$WORK/badps/ps"; chmod +x "$WORK/badps/ps"
CLAUDE_PID="$O22" fire SessionStart s22 "$K" >/dev/null; wait_sent 1; stop_keeper s22
(DEVSTRIDE_PRESENCE_MINUTE=0.4 PATH="$WORK/badps:$PATH" python3 "$HOOK" keeper s22 >/dev/null 2>&1 &)
wait_sent 3; sleep 0.2
if [ "$(sent)" -ge 3 ] && ! grep -q '"PRESENCE_EVENT": "end"' "$LOG" && keeper_alive s22; then
  ok "(22) ps failing → the keeper keeps beating, no false end"
else bad "(22) $(cat "$LOG")"; fi
stop_keeper s22

# (23) a new session prunes other sessions' files untouched for 7 days, and nothing else
: > "$LOG"; touch -t 202001010000 "$RECORDS/s6x.json" 2>/dev/null
for f in old.json old.state.lock old.send.lock .old.json.x.tmp; do printf '{}' > "$RECORDS/$f"; touch -t 202001010000 "$RECORDS/$f"; done
fire SessionStart s23 "$R" >/dev/null; wait_sent 1
LEFT="$(ls -a "$RECORDS" | grep -c '^\.\{0,1\}old')"
if [ "$LEFT" = 0 ] && [ -e "$RECORDS/s23.json" ] && [ -e "$RECORDS/s1.json" ]; then
  ok "(23) a new session → other sessions' week-old record, locks and temporary files pruned; live ones kept"
else bad "(23) left=$LEFT $(ls -a "$RECORDS")"; fi

# (24) Stop or SessionEnd from an older process of a resumed session does nothing
: > "$LOG"; O24A="$(owner)"; O24B="$(owner)"
CLAUDE_PID="$O24A" fire SessionStart s24 "$R" >/dev/null; wait_sent 1
CLAUDE_PID="$O24B" fire SessionStart s24 "$R" resume >/dev/null; wait_sent 2
age s24 61; CLAUDE_PID="$O24A" fire Stop s24 "$R" >/dev/null; CLAUDE_PID="$O24A" fire SessionEnd s24 "$R" other >/dev/null; sleep 0.5
if [ "$(sent)" = 2 ] && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$RECORDS/s24.json")" = starting ]; then
  ok "(24) Stop / SessionEnd from the older process after a resume in a newer one → nothing"
else bad "(24) $(cat "$LOG")"; fi

# (25) many hooks at once, across two checkouts, with a keeper beating: every queued report is
#      accounted for, report times never go backwards, one keeper
: > "$LOG"; O25="$(owner)"; K60B="$(mkrepo keeper60b "$(config 60)")"
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O25" fire SessionStart s25 "$K60" >/dev/null; wait_sent 1
for n in $(seq 1 30); do
  if [ $((n % 2)) = 0 ]; then D="$K60"; else D="$K60B"; fi
  (age s25 61 2>/dev/null; CLAUDE_PID="$O25" fire UserPromptSubmit s25 "$D" >/dev/null) &
  [ $((n % 7)) = 0 ] && (CLAUDE_PID="$O25" fire Stop s25 "$D" >/dev/null) &
done
wait
i=0; while [ $i -lt 100 ]; do
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r.get("queued")==r.get("done") else 1)' "$RECORDS/s25.json" 2>/dev/null && break
  sleep 0.1; i=$((i + 1))
done
ORDER="$(python3 -c '
import json,sys
ats=[int(json.loads(l)["PRESENCE_AT"]) for l in open(sys.argv[1])]
print("ok" if ats==sorted(ats) and len(ats)>=2 else "bad %s" % ats)' "$LOG")"
KEEPERS="$(pgrep -f "presence.py keeper s25\$" | wc -l | tr -d ' ')"
if [ "$i" -lt 100 ] && [ "$ORDER" = ok ] && [ "$KEEPERS" = 1 ]; then
  ok "(25) 30 prompts and Stops at once across two checkouts → queued = done, PRESENCE_AT never falls, one keeper"
else bad "(25) i=$i order=$ORDER keepers=$KEEPERS $(cat "$RECORDS/s25.json")"; fi
stop_keeper s25

# (26) a hook waits for the session's state lock: nothing in the record changes while another
#      process holds it, and the update lands once it is released
: > "$LOG"; O26="$(owner)"
CLAUDE_PID="$O26" fire SessionStart s26 "$K60" >/dev/null; wait_sent 1; stop_keeper s26; age s26 61
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(1.5)' "$RECORDS/s26.state.lock" "$WORK/held26" &
HOLDER=$!
i=0; while [ ! -e "$WORK/held26" ] && [ $i -lt 50 ]; do sleep 0.05; i=$((i + 1)); done
(CLAUDE_PID="$O26" fire UserPromptSubmit s26 "$K60" >/dev/null) &
sleep 0.7; Q1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["queued"])' "$RECORDS/s26.json")"
wait "$HOLDER"; wait_sent 2
Q2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["queued"])' "$RECORDS/s26.json")"
if [ "$Q1" = 1 ] && [ "$Q2" = 2 ] && [ "$(field 2 PRESENCE_EVENT)" = beat ]; then
  ok "(26) state lock held elsewhere → the prompt's update waits for it, then lands (beat)"
else bad "(26) q1=$Q1 q2=$Q2 $(cat "$LOG")"; fi
stop_keeper s26

# (27) a start time a few seconds off is the same process (no end); a send for a record removed
#      meanwhile runs nothing and recreates nothing
: > "$LOG"; O27="$(owner)"
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O27" fire SessionStart s27 "$K" >/dev/null; wait_sent 1
edit s27 'r["ownerStarted"] = r["ownerStarted"] - 3'
wait_sent 3; sleep 0.2
GONE27="$(grep -c '"PRESENCE_EVENT": "end"' "$LOG")"; stop_keeper s27
ID27="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$RECORDS/s27.json")"
rm -f "$RECORDS/s27.json"; N27="$(grep -c '"PRESENCE_SESSION_ID": "s27"' "$LOG")"
python3 "$HOOK" send beat working s27 "$ID27" 99 1
if [ "$GONE27" = 0 ] && [ "$(grep -c '"PRESENCE_SESSION_ID": "s27"' "$LOG")" = "$N27" ] && [ ! -e "$RECORDS/s27.json" ]; then
  ok "(27) start time 3 s off → still beating, no end; a send after its record was removed → nothing, not recreated"
else bad "(27) gone=$GONE27 $(cat "$LOG")"; fi

# (28) a tool use: nothing for a session never reported; otherwise it stamps the session's last
#      activity, which every later report carries as PRESENCE_ACTIVE_AT, and a waiting session that
#      uses a tool (a turn a notification started, no prompt) reports `working` once 30 s allow
s28() { python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; rows=[r for r in rows if r.get("PRESENCE_SESSION_ID")=="s28"]; n=int(sys.argv[2]); print(len(rows) if n==0 else (rows[n-1].get(sys.argv[3],"") if len(rows)>=n else ""))' "$LOG" "$1" "${2:-}"; }
wait28() { local i=0; while [ "$(s28 0)" -lt "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; }
O28="$(owner)"; R28="$(mkrepo r28 "$(config)")"
OUT="$(fire PostToolUse s28 "$R28" 2>&1)"; sleep 0.3
if [ -z "$OUT" ] && [ ! -e "$RECORDS/s28.json" ] && [ "$(s28 0)" = 0 ]; then
  CLAUDE_PID="$O28" fire SessionStart s28 "$R28" >/dev/null; wait28 1
  START_ACTIVE="$(s28 1 PRESENCE_ACTIVE_AT)"; T0="$(python3 -c 'import time; print(int(time.time()*1000))')"
  age s28 31; fire Stop s28 "$R28" >/dev/null; wait28 2                     # waiting
  sleep 0.05; age s28 31; fire PostToolUse s28 "$R28" >/dev/null; wait28 3  # back to working
  ACT3="$(s28 3 PRESENCE_ACTIVE_AT)"
  if [ "$(s28 3 PRESENCE_EVENT)" = beat ] && [ "$(s28 3 PRESENCE_STATE)" = working ] \
     && [ -n "$START_ACTIVE" ] && [ "$ACT3" -ge "$T0" ] && [ "$ACT3" -gt "$START_ACTIVE" ] && [ "$(s28 2 PRESENCE_STATE)" = waiting ]; then
    fire PostToolUse s28 "$R28" >/dev/null; sleep 0.4                           # same state, 0 s later: nothing sent
    STAMP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("activeAt"))' "$RECORDS/s28.json")"
    if [ "$(s28 0)" = 3 ] && [ "$STAMP" -gt "$ACT3" ]; then
      ok "(28) tool use → no report for an unknown session; stamps activity (PRESENCE_ACTIVE_AT on every report); waiting → working beat"
    else bad "(28) repeat sent=$(s28 0) stamp=$STAMP act3=$ACT3"; fi
  else bad "(28) e3=$(s28 3 PRESENCE_EVENT) s3=$(s28 3 PRESENCE_STATE) start=$START_ACTIVE act3=$ACT3 t0=$T0"; fi
else bad "(28) unknown session: out=$OUT sent=$(s28 0)"; fi
stop_keeper s28

# (28b) a tool use never resurrects an ended session, never moves a record a newer process of the
#       session holds, and an `end` stamps no activity
O28B="$(owner)"; CLAUDE_PID="$O28B" fire SessionStart s28b "$R28" >/dev/null; wait28 3
A0="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["activeAt"])' "$RECORDS/s28b.json")"
OLD28="$(owner)"; CLAUDE_PID="$OLD28" fire PostToolUse s28b "$R28" >/dev/null                 # an older process
A1="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["activeAt"], r["state"])' "$RECORDS/s28b.json")"
sleep 0.05; fire SessionEnd s28b "$R28" other >/dev/null
A2="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["activeAt"], r["state"])' "$RECORDS/s28b.json")"
fire PostToolUse s28b "$R28" >/dev/null; sleep 0.3
A3="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["activeAt"], r["state"])' "$RECORDS/s28b.json")"
if [ "$A1" = "$A0 starting" ] && [ "$A2" = "$A0 ended" ] && [ "$A3" = "$A0 ended" ]; then
  ok "(28b) tool use from an older process or after an end → record unchanged; an end stamps no activity"
else bad "(28b) a0=$A0 a1=$A1 a2=$A2 a3=$A3"; fi
stop_keeper s28b

# Helpers for (29)-(35): one session's reports in the shared log, its record, and a report run now.
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
of() { # of SESSION N FIELD — FIELD of the session's Nth report (N=0: how many it has)
  python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; rows=[r for r in rows if r.get("PRESENCE_SESSION_ID")==sys.argv[2]]; n=int(sys.argv[3]); print(len(rows) if n==0 else (rows[n-1].get(sys.argv[4],"") if len(rows)>=n else "-"))' "$LOG" "$1" "$2" "${3:-}"
}
upto() { local i=0; while [ "$(of "$1" 0)" -lt "$2" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; [ "$(of "$1" 0)" -ge "$2" ]; }
rec() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$RECORDS/$1.json" "$2"; }
probe() { # probe SESSION — run one report now, as the keeper would, and print the PRESENCE_BUSY_SINCE it carried
  edit "$1" 'r["queued"] = int(r.get("queued") or 0) + 1'
  python3 "$HOOK" send beat "$(rec "$1" 'r["state"]')" "$1" "$(rec "$1" 'r["id"]')" "$(rec "$1" 'r["queued"]')" "$(now_ms)"
  of "$1" "$(of "$1" 0)" PRESENCE_BUSY_SINCE
}
begin() { # begin SESSION — a reported session with no keeper (the cases drive every send themselves)
  fire SessionStart "$1" "$R29" >/dev/null; upto "$1" 1; stop_keeper "$1"
}
tool() { printf '{"tool_name":"%s","tool_use_id":"%s"%s}' "$1" "$2" "${3:+,\"agent_id\":\"$3\"}"; }
R29="$(mkrepo r29 "$(config)")"

# (29) a call's start stamps activity and opens it: PRESENCE_BUSY_SINCE is the earliest open call's
#      start; closing one leaves the other's; closing the last (PostToolUse or PostToolUseFailure) empties it
begin s29; T0="$(now_ms)"
fire PreToolUse s29 "$R29" "" "$(tool Bash t1)" >/dev/null
S1="$(rec s29 'r["tools"]["t1"]')"; A1="$(rec s29 'r["activeAt"]')"; ST1="$(rec s29 'r["state"]')"
sleep 0.05; age s29 31; fire PreToolUse s29 "$R29" "" "$(tool Read t2)" >/dev/null; upto s29 2   # the held change: beat
S2="$(rec s29 'r["tools"]["t2"]')"
fire PostToolUse s29 "$R29" "" "$(tool Bash t1)" >/dev/null; B1="$(probe s29)"
fire PostToolUseFailure s29 "$R29" "" "$(tool Read t2)" >/dev/null; B2="$(probe s29)"
if [ "$ST1" = working ] && [ "$S1" -ge "$T0" ] && [ "$A1" -ge "$T0" ] && [ "$S2" -gt "$S1" ] \
   && [ "$(of s29 2 PRESENCE_EVENT)" = beat ] && [ "$(of s29 2 PRESENCE_STATE)" = working ] \
   && [ "$(of s29 2 PRESENCE_BUSY_SINCE)" = "$S1" ] && [ "$B1" = "$S2" ] && [ -z "$B2" ] && [ "$(rec s29 'len(r["tools"])')" = 0 ] \
   && [ -z "$(of s29 1 PRESENCE_BUSY_SINCE)" ]; then
  ok "(29) PreToolUse → activity and an open call; busy-since = the earliest of two; closing each → the other's, then empty"
else bad "(29) st=$ST1 s1=$S1 s2=$S2 a1=$A1 t0=$T0 b1=$B1 b2=$B2 $(grep '"s29"' "$LOG")"; fi

# (29b) at most 64 calls are open: the oldest is dropped
begin s29b
for n in $(seq 1 66); do fire PreToolUse s29b "$R29" "" "$(tool Bash "c$n")" >/dev/null; done
if [ "$(rec s29b 'len(r["tools"])')" = 64 ] && [ "$(rec s29b '"c1" in r["tools"] or "c2" in r["tools"]')" = False ] \
   && [ "$(rec s29b '"c3" in r["tools"] and "c66" in r["tools"]')" = True ]; then
  ok "(29b) 66 calls open → 64 kept, the two oldest dropped"
else bad "(29b) $(rec s29b 'sorted(r["tools"])')"; fi

# (30) a permission prompt waits on the person: beat waiting once 30 s allow; the call ending → working
begin s30; age s30 31; fire PreToolUse s30 "$R29" "" "$(tool Bash p1)" >/dev/null; upto s30 2
P1="$(rec s30 'r["tools"]["p1"]')"
age s30 31; fire Notification s30 "$R29" "" '{"notification_type":"permission_prompt"}' >/dev/null; upto s30 3
age s30 31; fire PostToolUse s30 "$R29" "" "$(tool Bash p1)" >/dev/null; upto s30 4
if [ "$(of s30 2 PRESENCE_STATE)" = working ] && [ "$(of s30 3 PRESENCE_STATE)" = waiting ] && [ "$(of s30 3 PRESENCE_BUSY_SINCE)" = "$P1" ] \
   && [ "$(of s30 4 PRESENCE_STATE)" = working ] && [ -z "$(of s30 4 PRESENCE_BUSY_SINCE)" ]; then
  ok "(30) Notification permission_prompt → beat waiting (the call still open); its PostToolUse → beat working, not busy"
else bad "(30) $(grep '"s30"' "$LOG")"; fi

# (30b) an MCP elicitation waits on the person; the person's answer → working while the call goes on
begin s30b; age s30b 31; fire PreToolUse s30b "$R29" "" "$(tool mcp__x__login e1)" >/dev/null; upto s30b 2
age s30b 31; fire Notification s30b "$R29" "" '{"notification_type":"elicitation_dialog"}' >/dev/null; upto s30b 3
age s30b 31; fire Notification s30b "$R29" "" '{"notification_type":"elicitation_response"}' >/dev/null; upto s30b 4
E1="$(rec s30b 'r["tools"]["e1"]')"
age s30b 31; fire Notification s30b "$R29" "" '{"notification_type":"elicitation_url_dialog"}' >/dev/null; upto s30b 5
age s30b 31; fire Notification s30b "$R29" "" '{"notification_type":"elicitation_complete"}' >/dev/null; upto s30b 6
if [ "$(of s30b 3 PRESENCE_STATE)" = waiting ] && [ "$(of s30b 4 PRESENCE_STATE)" = working ] && [ "$(of s30b 4 PRESENCE_BUSY_SINCE)" = "$E1" ] \
   && [ "$(of s30b 5 PRESENCE_STATE)" = waiting ] && [ "$(of s30b 6 PRESENCE_STATE)" = working ]; then
  ok "(30b) elicitation_dialog / _url_dialog → waiting; elicitation_response / _complete → working, the call still busy"
else bad "(30b) $(grep '"s30b"' "$LOG")"; fi

# (31) the idle prompt (about 60 s after an interrupt, which fires no hook): open calls dropped, waiting;
#      the next prompt → working
begin s31; age s31 31; fire UserPromptSubmit s31 "$R29" >/dev/null; upto s31 2
fire PreToolUse s31 "$R29" "" "$(tool Bash i1)" >/dev/null
age s31 31; fire Notification s31 "$R29" "" '{"notification_type":"idle_prompt"}' >/dev/null; upto s31 3
age s31 31; fire UserPromptSubmit s31 "$R29" >/dev/null; upto s31 4
if [ "$(of s31 2 PRESENCE_STATE)" = working ] && [ "$(of s31 3 PRESENCE_STATE)" = waiting ] && [ -z "$(of s31 3 PRESENCE_BUSY_SINCE)" ] \
   && [ "$(of s31 4 PRESENCE_STATE)" = working ] && [ "$(rec s31 'len(r["tools"])')" = 0 ]; then
  ok "(31) working with an open call, then idle_prompt → beat waiting, busy-since empty; a prompt → working"
else bad "(31) $(grep '"s31"' "$LOG")"; fi

# (32) the main conversation asking its person (AskUserQuestion, ExitPlanMode) waits; the answer → working;
#      the same tool from a helper agent is an ordinary call
begin s32; age s32 31; fire UserPromptSubmit s32 "$R29" >/dev/null; upto s32 2
age s32 31; fire PreToolUse s32 "$R29" "" "$(tool AskUserQuestion q1)" >/dev/null; upto s32 3
Q1="$(rec s32 '"q1" in r["tools"]')"
age s32 31; fire PostToolUse s32 "$R29" "" "$(tool AskUserQuestion q1)" >/dev/null; upto s32 4
age s32 31; fire PreToolUse s32 "$R29" "" "$(tool ExitPlanMode q2)" >/dev/null; upto s32 5
age s32 31; fire PostToolUse s32 "$R29" "" "$(tool ExitPlanMode q2)" >/dev/null; upto s32 6
age s32 31; fire PreToolUse s32 "$R29" "" "$(tool AskUserQuestion q3 helper-1)" >/dev/null; sleep 0.4
H32="$(rec s32 'r["state"], "q3" in r["tools"]')"; fire PostToolUse s32 "$R29" "" "$(tool AskUserQuestion q3 helper-1)" >/dev/null
# while the question is open, a background helper's calls (and a parallel call of the main
# conversation) change nothing; the question's own answer does
age s32 31; fire PreToolUse s32 "$R29" "" "$(tool AskUserQuestion q4)" >/dev/null; upto s32 7
age s32 31; fire PreToolUse s32 "$R29" "" "$(tool Bash h1 helper-2)" >/dev/null
age s32 31; fire PostToolUse s32 "$R29" "" "$(tool Bash h1 helper-2)" >/dev/null
age s32 31; fire PostToolUseFailure s32 "$R29" "" "$(tool Read m1)" >/dev/null; sleep 0.4
W32="$(rec s32 'r["state"]')"; N32="$(of s32 0)"
age s32 31; fire PostToolUse s32 "$R29" "" "$(tool AskUserQuestion q4)" >/dev/null; upto s32 8
if [ "$(of s32 3 PRESENCE_STATE)" = waiting ] && [ "$Q1" = False ] && [ "$(of s32 4 PRESENCE_STATE)" = working ] \
   && [ "$(of s32 5 PRESENCE_STATE)" = waiting ] && [ "$(of s32 6 PRESENCE_STATE)" = working ] && [ "$H32" = "('working', True)" ] \
   && [ "$(of s32 7 PRESENCE_STATE)" = waiting ] && [ "$W32" = waiting ] && [ "$N32" = 7 ] \
   && [ "$(of s32 8 PRESENCE_STATE)" = working ] && [ "$(rec s32 'r["asking"]')" = "" ]; then
  ok "(32) main-conversation AskUserQuestion / ExitPlanMode → waiting, not busy; answered → working; from a helper agent → nothing; other calls while it is open → still waiting"
else bad "(32) $(grep '"s32"' "$LOG") $(cat "$RECORDS/s32.json")"; fi

# (33) a finished turn that left its own background work running stays working, busy since the Stop;
#      the idle prompt then changes nothing; a later Stop with none running → waiting
begin s33; age s33 31; fire UserPromptSubmit s33 "$R29" >/dev/null; upto s33 2
T1="$(now_ms)"; age s33 31
fire Stop s33 "$R29" "" '{"background_tasks":[{"id":"b1","type":"shell","status":"running","command":"npm test"}]}' >/dev/null
sleep 0.4; N33="$(of s33 0)"; BG="$(rec s33 'r["background"]')"; ST33="$(rec s33 'r["state"]')"; ACT33="$(rec s33 'r["activeAt"]')"
age s33 31; fire Notification s33 "$R29" "" '{"notification_type":"idle_prompt"}' >/dev/null; sleep 0.4
AFTER="$(rec s33 'r["state"], r["background"], r["activeAt"]')"; B33="$(probe s33)"; N33B="$(of s33 0)"
age s33 31; fire Stop s33 "$R29" "" '{"background_tasks":[{"id":"b1","type":"shell","status":"completed"},{"id":"t1","type":"teammate","status":"running"}]}' >/dev/null; upto s33 $((N33B + 1))
if [ "$N33" = 2 ] && [ "$ST33" = working ] && [ "$BG" -ge "$T1" ] && [ "$AFTER" = "('working', $BG, $ACT33)" ] && [ "$B33" = "$BG" ] \
   && [ "$(of s33 "$((N33B + 1))" PRESENCE_STATE)" = waiting ] && [ -z "$(of s33 "$((N33B + 1))" PRESENCE_BUSY_SINCE)" ]; then
  ok "(33) Stop with background work running → working, busy since the Stop; idle_prompt → unchanged; Stop with none (an idle teammate is none) → waiting"
else bad "(33) n=$N33 st=$ST33 bg=$BG t1=$T1 after=$AFTER b=$B33 $(grep '"s33"' "$LOG")"; fi

# (34) a turn ended on an API error (a usage limit) stays working, not busy, with no new activity, so it
#      still reads as idle while working; the idle prompt keeps it so; the next prompt clears it
begin s34; age s34 31; fire UserPromptSubmit s34 "$R29" >/dev/null; upto s34 2
fire PreToolUse s34 "$R29" "" "$(tool Bash f1)" >/dev/null; ACT34="$(rec s34 'r["activeAt"]')"; sleep 0.05
age s34 31; fire StopFailure s34 "$R29" "" '{"error":"rate_limit"}' >/dev/null
F1="$(rec s34 'r["state"], r["failed"], len(r["tools"]), r["activeAt"]')"; B34="$(probe s34)"; N34="$(of s34 0)"
age s34 31; fire Notification s34 "$R29" "" '{"notification_type":"idle_prompt"}' >/dev/null; sleep 0.4
F2="$(rec s34 'r["state"], r["activeAt"]')"; N34B="$(of s34 0)"
age s34 31; fire UserPromptSubmit s34 "$R29" >/dev/null
F3="$(rec s34 'r["state"], r["failed"]')"
if [ "$F1" = "('working', True, 0, $ACT34)" ] && [ -z "$B34" ] && [ "$F2" = "('working', $ACT34)" ] && [ "$N34B" = "$N34" ] \
   && [ "$F3" = "('working', False)" ]; then
  ok "(34) StopFailure → still working, busy empty, activity unchanged; idle_prompt → still working; a prompt clears it"
else bad "(34) f1=$F1 act=$ACT34 b=$B34 f2=$F2 n=$N34/$N34B f3=$F3"; fi

# (35) any other notification type changes nothing; a new event for a session never reported does nothing
begin s35; age s35 31; BEFORE35="$(cat "$RECORDS/s35.json")"; N35="$(of s35 0)"
fire Notification s35 "$R29" "" '{"notification_type":"auth_success"}' >/dev/null
fire Notification s35 "$R29" "" '{"notification_type":"agent_needs_input"}' >/dev/null
fire Notification s35 "$R29" "" '{}' >/dev/null
for e in PreToolUse PostToolUseFailure Notification StopFailure; do
  fire "$e" s35x "$R29" "" '{"tool_name":"Bash","tool_use_id":"x1","notification_type":"idle_prompt","error":"rate_limit"}' >/dev/null
done; sleep 0.4
if [ "$(cat "$RECORDS/s35.json")" = "$BEFORE35" ] && [ "$(of s35 0)" = "$N35" ] && [ ! -e "$RECORDS/s35x.json" ] && [ "$(of s35x 0)" = 0 ]; then
  ok "(35) auth_success / agent_needs_input / no type → nothing; new events for an unknown session → nothing written or sent"
else bad "(35) $(diff <(echo "$BEFORE35") "$RECORDS/s35.json") $(grep '"s35' "$LOG")"; fi

# (36) a finished batch closes every call it lists and every other open call of the same agent (a call
#      a deny rule or a hook refused never gets its PostToolUse); a helper agent's calls stay open
#      until its own batch ends
begin s36
for c in b1 b2; do fire PreToolUse s36 "$R29" "" "$(tool Bash "$c")" >/dev/null; done
fire PreToolUse s36 "$R29" "" "$(tool Read h1 helper-3)" >/dev/null
fire PostToolUse s36 "$R29" "" "$(tool Bash b1)" >/dev/null
fire PostToolBatch s36 "$R29" "" '{"tool_calls":[{"tool_name":"Bash","tool_use_id":"b1","tool_response":"ok"}]}' >/dev/null
L1="$(rec s36 'sorted(r["tools"]), r["callers"]')"
fire PostToolBatch s36 "$R29" "" '{"agent_id":"helper-3","tool_calls":[]}' >/dev/null
L2="$(rec s36 'sorted(r["tools"]), r["callers"], r["state"]')"
if [ "$L1" = "(['h1'], {'h1': 'helper-3'})" ] && [ "$L2" = "([], {}, 'working')" ]; then
  ok "(36) PostToolBatch → its calls and the same agent's refused call closed; a helper's call kept until its own batch ends"
else bad "(36) l1=$L1 l2=$L2"; fi

# Helpers for (37)-(38): a session's transcript, as Claude Code writes it (one JSON entry a line).
entry() { # entry FILE KIND[,KIND…] [AGE-MS] [new] — append the entries, stamped now or AGE-MS ago, in one
  #         write (`new`: as a new file, moved into place whole, so a keeper never reads half of it);
  #         prints their time in epoch ms
  python3 - "$1" "$2" "${3:-0}" "${4:-}" <<'PY'
import json, os, sys, time
path, kinds, age, new = sys.argv[1], sys.argv[2].split(","), int(sys.argv[3]), sys.argv[4] == "new"
ms = int(time.time() * 1000) - age
at = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms // 1000)) + ".%03dZ" % (ms % 1000)
user = lambda content, **more: dict({"type": "user", "isSidechain": False, "uuid": "u-%d" % ms, "timestamp": at,
                                     "message": {"role": "user", "content": content}}, **more)
rows = {
    "esc": [user([{"type": "text", "text": "[Request interrupted by user]"}], interruptedMessageId="msg_1")],
    "esc-tool": [user([{"type": "tool_result", "tool_use_id": "i1", "is_error": True, "content": "rejected"}]),
                 {"type": "attachment", "timestamp": at, "attachment": {"pad": "x" * 300000}},
                 user([{"type": "text", "text": "[Request interrupted by user for tool use]"}])],
    "esc-untimed": [{k: v for k, v in user([{"type": "text", "text": "[Request interrupted by user]"}]).items() if k != "timestamp"}],
    "esc-helper": [user([{"type": "text", "text": "[Request interrupted by user]"}], isSidechain=True)],
    "prompt": [user("carry on")],
    "typed": [user("[Request interrupted by user]")],
    "assistant": [{"type": "assistant", "isSidechain": False, "timestamp": at,
                   "message": {"role": "assistant", "content": [{"type": "text", "text": "working on it"}]}}],
    "helper": [{"type": "assistant", "isSidechain": True, "timestamp": at,
                "message": {"role": "assistant", "content": [{"type": "text", "text": "a helper agent, still going"}]}}],
    "bookkeeping": [{"type": "last-prompt", "lastPrompt": "x"}, {"type": "custom-title", "customTitle": "x"},
                    {"type": "system", "subtype": "away_summary", "timestamp": at}, {"type": "bridge-session"}],
}
text = "".join(json.dumps(row) + "\n" for kind in kinds if kind != "cut" for row in rows[kind])
text += '{"type":"user","mess' if "cut" in kinds else ""   # an entry Claude Code is still writing
with open(path + ".new" if new else path, "a") as f:
    f.write(text)
if new:
    os.replace(path + ".new", path)
print(ms)
PY
}
transcript() { printf '{"transcript_path":"%s"}' "$1"; }
settle() { sleep 0.6; }   # three keeper checks at DEVSTRIDE_PRESENCE_MINUTE=1

# (37) an interrupt (Esc) fires no hook: the keeper reads it from the end of the transcript. A working
#      session whose transcript ends on the interrupt entry → waiting, open calls dropped, sent as a
#      held change; applied once: the next prompt → working, even while the transcript still ends there
: > "$LOG"; O37="$(owner)"; T37="$WORK/t37.jsonl"
entry "$T37" prompt,assistant >/dev/null
DEVSTRIDE_PRESENCE_MINUTE=1 CLAUDE_PID="$O37" fire SessionStart s37 "$K60" "" "$(transcript "$T37")" >/dev/null; upto s37 1
age s37 61; CLAUDE_PID="$O37" fire UserPromptSubmit s37 "$K60" "" "$(transcript "$T37")" >/dev/null; upto s37 2
fire PreToolUse s37 "$K60" "" "$(tool Bash i1)" >/dev/null; settle
BEFORE37="$(rec s37 'r["state"], len(r["tools"])')"; sleep 0.05
M37="$(entry "$T37" esc-tool,bookkeeping,helper)"; settle
HELD37="$(rec s37 'r["state"], len(r["tools"]), r["interrupt"], r["activeAt"]')"; N37="$(of s37 0)"   # held: sent within 30 s
age s37 31; upto s37 3
age s37 31; CLAUDE_PID="$O37" fire UserPromptSubmit s37 "$K60" "" "$(transcript "$T37")" >/dev/null; upto s37 4; settle
AGAIN37="$(rec s37 'r["state"]')"
M37B="$(entry "$T37" esc)"; settle; age s37 31; upto s37 5   # interrupted again, while Claude was writing
if [ "$BEFORE37" = "('working', 1)" ] && [ "$HELD37" = "('waiting', 0, $M37, $M37)" ] && [ "$N37" = 2 ] \
   && [ "$(of s37 3 PRESENCE_EVENT)" = beat ] && [ "$(of s37 3 PRESENCE_STATE)" = waiting ] && [ -z "$(of s37 3 PRESENCE_BUSY_SINCE)" ] \
   && [ "$(of s37 3 PRESENCE_ACTIVE_AT)" = "$M37" ] && [ "$(of s37 4 PRESENCE_STATE)" = working ] && [ "$AGAIN37" = working ] \
   && [ "$(of s37 5 PRESENCE_STATE)" = waiting ] && [ "$(rec s37 'r["interrupt"]')" = "$M37B" ]; then
  ok "(37) transcript ends on the interrupt entry (past a 300 KB entry, bookkeeping and a helper's entry) → the keeper sends waiting, not busy; a prompt → working, the old interrupt not applied again; a new interrupt → waiting"
else bad "(37) before=$BEFORE37 held=$HELD37 m=$M37 n=$N37 again=$AGAIN37 m2=$M37B $(grep '"s37"' "$LOG") $(cat "$RECORDS/s37.json")"; fi
stop_keeper s37

# (38) never waiting on a doubt: an interrupt older than the last prompt, one followed by anything the
#      main conversation said, one in a helper's conversation, one with no time, a typed prompt with the
#      same words, an entry cut mid-line, a symlink, a missing file, a session not working, and a hook
#      payload naming the event all change nothing; then the same keeper acts on a real one
: > "$LOG"; O38="$(owner)"; T38="$WORK/t38.jsonl"; D38=""
entry "$T38" prompt,esc >/dev/null
DEVSTRIDE_PRESENCE_MINUTE=1 CLAUDE_PID="$O38" fire SessionStart s38 "$K60" "" "$(transcript "$T38")" >/dev/null; upto s38 1
entry "$T38" esc >/dev/null; settle; D38="$D38 starting:$(rec s38 'r["state"]')"                      # not working
age s38 61; CLAUDE_PID="$O38" fire UserPromptSubmit s38 "$K60" "" "$(transcript "$T38")" >/dev/null; upto s38 2
doubt() { settle; D38="$D38 $1:$(rec s38 'r["state"], r.get("interrupt")')"; }
doubt older                                                                                             # before this prompt
entry "$T38" esc 5000 new >/dev/null; doubt older-by-time
entry "$T38" esc,assistant 0 new >/dev/null; doubt answered
entry "$T38" esc,prompt 0 new >/dev/null; doubt prompted
entry "$T38" assistant,esc-helper 0 new >/dev/null; doubt helper
entry "$T38" esc-untimed 0 new >/dev/null; doubt untimed
entry "$T38" typed 0 new >/dev/null; doubt typed
entry "$T38" esc,cut 0 new >/dev/null; doubt cut
entry "$WORK/t38.real" esc >/dev/null; ln -s "$WORK/t38.real" "$T38.link"; mv -f "$T38.link" "$T38"; doubt symlink
rm -f "$T38"; doubt missing
fire Interrupt s38 "$K60" >/dev/null; doubt named
N38="$(of s38 0)"; M38="$(entry "$T38" esc)"; settle; age s38 31; upto s38 3
WANT38=" starting:starting"; for d in older older-by-time answered prompted helper untimed typed cut symlink missing named; do WANT38="$WANT38 $d:('working', None)"; done
if [ "$D38" = "$WANT38" ] && [ "$N38" = 2 ] && [ "$(of s38 3 PRESENCE_STATE)" = waiting ] && [ "$(rec s38 'r["interrupt"]')" = "$M38" ]; then
  ok "(38) an interrupt that is stale, answered, a helper's, untimed, typed, cut mid-line, behind a symlink or missing, or a session not working → nothing; a real one after them → waiting"
else bad "(38) got=$D38 n=$N38 $(grep '"s38"' "$LOG") $(cat "$RECORDS/s38.json")"; fi
stop_keeper s38

# (12) hooks.json registers the hook on all ten events, bounded and failing open; Notification only for
#      the six prompt types the hook reads, and PreToolUse after the model recorder
if python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
for event in ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
              "Notification", "Stop", "StopFailure", "SessionEnd"):
    found = [(g, c) for g in h[event] for c in g["hooks"] if "hooks/presence.py\" hook" in c["command"]]
    assert len(found) == 1 and found[0][1].get("timeout") == 5 and found[0][1]["command"].endswith("exit 0"), event
    if event == "Notification":
        assert found[0][0].get("matcher") == "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|elicitation_response|elicitation_complete"
    elif event != "SessionStart":
        assert "matcher" not in found[0][0], event
pre = [c["command"] for g in h["PreToolUse"] for c in g["hooks"]]
assert "session-runtime.py\" seen" in pre[0] and "presence.py\" hook" in pre[1], pre
PY
then ok "(12) hooks.json → presence hook on ten events (timeout 5, exit 0); Notification for the six prompt types only"
else bad "(12) hooks.json registration"; fi

exit $FAIL
