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
fire() { # fire EVENT SESSION CWD [REASON-OR-SOURCE] — run the hook as Claude Code does; prints its stdout
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":sys.argv[1],"session_id":sys.argv[2],"cwd":sys.argv[3],"reason":sys.argv[4],"source":sys.argv[4]}))' \
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
chmod 500 "$RECORDS"
O="$O$(fire SessionStart s11 "$R" 2>&1)"; RC=$((RC + $?))
chmod 700 "$RECORDS"
O="$O$(python3 "$HOOK" 2>&1)$(python3 "$HOOK" send bogus starting s1 ab 9 1 2>&1)$(python3 "$HOOK" send beat working s1 ab x 1 2>&1)$(python3 "$HOOK" send beat bogus s1 ab 9 1 2>&1)$(DEVSTRIDE_PRESENCE_MINUTE=x python3 "$HOOK" keeper nobody 2>&1)"; RC=$((RC + $?))
if [ "$RC" = 0 ] && [ -z "$O" ] && [ ! -e "$XDG_CACHE_HOME/devstride-plugin/x.json" ] && [ ! -e "$RECORDS/s11.json" ] \
  && [ ! -e "$RECORDS/nobody.keeper.lock" ]; then
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
rm -f "$RECORDS/s27.json"; N27="$(sent)"
python3 "$HOOK" send beat working s27 "$ID27" 99 1
if [ "$GONE27" = 0 ] && [ "$(sent)" = "$N27" ] && [ ! -e "$RECORDS/s27.json" ]; then
  ok "(27) start time 3 s off → still beating, no end; a send after its record was removed → nothing, not recreated"
else bad "(27) gone=$GONE27 $(cat "$LOG")"; fi

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
