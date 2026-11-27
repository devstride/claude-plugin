#!/bin/bash
# Deterministic tests for hooks/presence.py — every session reports itself, through the repository's
# own presence command or the built-in reporter. Each case runs against a private cache and throwaway
# repositories; the "repository command" appends its environment to a log, and the built-in
# reporter's cases (B1)-(B8) read a fake server's log, so a case reads exactly what was sent.
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
export XDG_CONFIG_HOME="$WORK/config"   # where a session reporter credential would live
export APPDATA="$XDG_CONFIG_HOME"   # and where it lives on native Windows, which prefers %APPDATA%
export CLAUDE_CONFIG_DIR="$WORK/claude"   # Claude Code's own session status files (case 38b) live here
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID   # the cases name their own stand-in process
unset CLAUDE_CODE_ENTRYPOINT DEVSTRIDE_UNATTENDED   # and say themselves when no person is at a session
# A maintainer's real configuration file and real key are never read: a throwaway HOME, a scratch
# CLAUDE_CONFIG_DIR (above) whose .claude.json only a case writes, and none of the key variables.
export HOME="$WORK/home"; mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1; printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
unset DEVSTRIDE_API_KEY DEVSTRIDE_API_SECRET DEVSTRIDE_ORG_ID DEVSTRIDE_ORG_SLUG DEVSTRIDE_BASE_URL DEVSTRIDE_PRESENCE DEVSTRIDE_PLUGIN_TEST_URL DEVSTRIDE_SESSION
RECORDS="$XDG_CACHE_HOME/devstride-plugin/presence"
LOG="$WORK/sent.log"
ITEM_NO="I$((20000 + 100))"   # an example item number, built at run time (public-repo hygiene)

# CLAUDE_PLUGIN_ROOT names another version: a report carries the version of the code sending it
PLUGIN="$WORK/plugin"; mkdir -p "$PLUGIN/.claude-plugin"
printf '{"name":"devstride","version":"9.8.7"}' > "$PLUGIN/.claude-plugin/plugin.json"
export CLAUDE_PLUGIN_ROOT="$PLUGIN"
OWNV="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"

# The repository's command: one JSON line per send, with every exported variable it should see.
REPORT='python3 -c "import json,os; print(json.dumps({k:v for k,v in os.environ.items() if k.startswith(\"PRESENCE_\") or k in (\"CLAUDE_CODE_SESSION_ID\",\"CLAUDE_PID\")}))" >> '"$LOG"
mkrepo() { # mkrepo NAME [CONFIG-JSON] [BRANCH]
  local d="$WORK/$1"; mkdir -p "$d/.claude"; git -C "$d" init -q -b "${3:-main}" 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  local empty='{}'; printf '%s' "${2:-$empty}" > "$d/.claude/ds-config.json"; printf '%s' "$d"
}
config() { python3 -c 'import json,sys; print(json.dumps({"presence":{"command":sys.argv[1],"intervalMinutes":int(sys.argv[2])}}))' "$REPORT" "${1:-5}"; }
fire() { # fire EVENT SESSION CWD [REASON-OR-SOURCE] [EXTRA-JSON] — run the hook as Claude Code does; prints its
  #        stdout. EXTRA-JSON (an object) is merged into the payload: tool_name, tool_use_id, agent_id, …
  python3 -c 'import json,sys; p={"hook_event_name":sys.argv[1],"session_id":sys.argv[2],"cwd":sys.argv[3],"reason":sys.argv[4],"source":sys.argv[4]}; p.update(json.loads(sys.argv[5] or "{}")); print(json.dumps(p))' \
    "$1" "$2" "$3" "${4:-}" "${5:-}" | python3 "${HOOK_RUN:-$HOOK}" hook
}
sent() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
wait_sent() { # wait_sent N — until the log holds N lines (detached sends), at most 10 s
  local i=0; while [ "$(sent)" -lt "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(sent)" -ge "$1" ]
}
own() { grep -c "\"PRESENCE_SESSION_ID\": \"$1\"" "$LOG" 2>/dev/null || true; }   # own SESSION — its reports in the log
wait_own() { # wait_own SESSION N — until the log holds N of that session's reports, at most 10 s
  local i=0; while [ "$(own "$1")" -lt "$2" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(own "$1")" -ge "$2" ]
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
keeper_pid() { pgrep -f "hooks/presence.py keeper $1\$" | head -1; }
wait_keeper() { # wait_keeper SESSION — until a keeper holds the session's lock, at most 5 s. A keeper takes its
  #               lock once as it starts, and a probe (keeper_alive) holding the lock at that moment makes it
  #               leave, so nothing probes until the keeper is visible AND has taken the lock: the lock file is
  #               touched after the keeper was first seen, or it has been running for two seconds (one that
  #               failed to take it has left by then). Only then does keeper_alive confirm it.
  python3 - "$RECORDS/$1.keeper.lock" "hooks/presence.py keeper $1\$" <<'PY' && keeper_alive "$1"
import os, subprocess, sys, time
lock, pattern = sys.argv[1], sys.argv[2]
end, seen, since = time.time() + 5, None, 0
while time.time() < end:
    run = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    if run.returncode not in (0, 1):
        sys.exit("pgrep failed: %s" % run.stderr.strip())
    found = run.stdout.split()
    pid = found[0] if found else None
    if pid != seen:
        seen, since = pid, time.time()
    elif pid:
        try:
            touched = os.stat(lock).st_mtime >= since
        except OSError:
            touched = False
        if touched or time.time() - since >= 2.0:
            sys.exit(0)
    time.sleep(0.05)
sys.exit(1)
PY
}
owner() { sleep 300 >/dev/null 2>&1 & echo "$!" >> "$WORK/owners"; echo "$!"; }  # a stand-in Claude Code process

R="$(mkrepo repo "$(config)" "phil/26-01-01/$ITEM_NO-some-story")"

# (1) no key on this machine: an absent block, a null block and a directory outside any repository
#     send nothing and write no record. Every SessionStart shows the person one line, as JSON.
START_JSON='{"systemMessage": "This session is not on the DevStride Fleet yet. It will be set up the first time you run a DevStride skill."}'
N="$(mkrepo plain '{"presence":null}')"; mkdir -p "$WORK/loose"
OUT0="$(fire SessionStart s0 "$N")$(fire UserPromptSubmit s0 "$WORK/loose")"      # a null block, and a plain prompt: never
OUT1="$(fire SessionStart s0 "$(mkrepo none)" 2>&1)"                                # a start with no key
OUT2="$(fire SessionStart s0b "$WORK/none" 2>&1)"                                   # and the next one: said again
OUT3="$(fire UserPromptSubmit s0 "$WORK/loose" 2>&1)$(fire Stop s0 "$WORK/none" 2>&1)"
sleep 0.5
MARKER="$XDG_CACHE_HOME/devstride-plugin/presence-no-key"
if [ -z "$OUT0" ] && [ "$OUT1" = "$START_JSON" ] && [ "$OUT2" = "$START_JSON" ] && [ -z "$OUT3" ] && [ ! -e "$RECORDS" ] \
   && [ "$(sent)" = 0 ] && [ ! -e "$MARKER" ]; then
  ok "(1) no key: no block / null / no repository → nothing sent, no record; every SessionStart shows the one line as a systemMessage"
else bad "(1) out0=$OUT0 out1=$OUT1 out2=$OUT2 out3=$OUT3 sent=$(sent) records=$(ls "$RECORDS" 2>&1)"; fi

# (2) session start sends `start` with every documented variable; the record is owner-only
O1="$(owner)"
mkdir -p "$R/sub/dir"
OUT="$(CLAUDE_PID="$O1" fire SessionStart s1 "$R/sub/dir" 2>&1)"
if [ -z "$OUT" ] && wait_sent 1 && [ "$(field 1 PRESENCE_EVENT)" = start ] && [ "$(field 1 PRESENCE_STATE)" = starting ] \
  && [ "$(field 1 PRESENCE_SESSION_ID)" = s1 ] && [ "$(field 1 CLAUDE_CODE_SESSION_ID)" = s1 ] && [ "$(field 1 CLAUDE_PID)" = "$O1" ] \
  && [ "$(field 1 PRESENCE_CHECKOUT)" = "$(cd "$R" && pwd -P)" ] && [ "$(field 1 PRESENCE_BRANCH)" = "phil/26-01-01/$ITEM_NO-some-story" ] \
  && [ "$(field 1 PRESENCE_ITEM)" = "$ITEM_NO" ] && [ "$(field 1 PRESENCE_PLUGIN_VERSION)" = "$OWNV" ] \
  && [ "$(field 1 PRESENCE_INTERVAL_MINUTES)" = 5 ] && [ -n "$(field 1 PRESENCE_MACHINE)" ] && [ -z "$(field 1 PRESENCE_END_REASON)" ] \
  && [ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$RECORDS/s1.json")" = 0o600 ]; then
  ok "(2) SessionStart → start: state, session, CLAUDE_PID, checkout root, branch, item, the code's own version (not CLAUDE_PLUGIN_ROOT's), interval, machine; mode 600"
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
wait_sent 1; wait_keeper s9; KEEPER=$?
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
OA="$(owner)"; DEVSTRIDE_PRESENCE_MINUTE=3 CLAUDE_PID="$OA" fire SessionStart s15 "$K5" >/dev/null; wait_sent 1; wait_keeper s15; UP15=$?
fire SessionEnd s15 "$K5" prompt_input_exit >/dev/null
OB="$(owner)"; kill "$OA"; wait "$OA" 2>/dev/null
DEVSTRIDE_PRESENCE_MINUTE=3 CLAUDE_PID="$OB" fire SessionStart s15 "$K5" resume >/dev/null; wait_sent 3; sleep 1.5
if [ "$UP15" = 0 ] && ! grep -q '"PRESENCE_END_REASON": "gone"' "$LOG" && [ "$(field 3 PRESENCE_EVENT)" = start ] \
  && [ "$(field 3 CLAUDE_PID)" = "$OB" ] && wait_keeper s15; then
  ok "(15) resume in a new process after a clean exit → start with the new process, no false end, keeper running"
else bad "(15) up=$UP15 $(cat "$LOG")"; fi
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
wait_keeper s17; UP17=$?
if [ "$KBEFORE" = 0 ] && [ "$UP17" = 0 ] && [ "$(field 2 PRESENCE_EVENT)" = start ] && [ "$(field 2 CLAUDE_PID)" = "$O17" ]; then
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
wait_own s22 3; sleep 0.2
if [ "$(own s22)" -ge 3 ] && ! grep '"PRESENCE_SESSION_ID": "s22"' "$LOG" | grep -q '"PRESENCE_EVENT": "end"' && keeper_alive s22; then
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
CLAUDE_PID="$O24A" fire SessionStart s24 "$R" >/dev/null; wait_own s24 1
CLAUDE_PID="$O24B" fire SessionStart s24 "$R" resume >/dev/null; wait_own s24 2
age s24 61; CLAUDE_PID="$O24A" fire Stop s24 "$R" >/dev/null; CLAUDE_PID="$O24A" fire SessionEnd s24 "$R" other >/dev/null; sleep 0.5
# counts only this session's reports: a detached send from an earlier case may land after the log is emptied
if [ "$(own s24)" = 2 ] && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$RECORDS/s24.json")" = starting ]; then
  ok "(24) Stop / SessionEnd from the older process after a resume in a newer one → nothing"
else bad "(24) $(cat "$LOG")"; fi

# (25) many hooks at once, across two checkouts, with a keeper beating: every queued report is
#      accounted for, report times never go backwards, one keeper
: > "$LOG"; O25="$(owner)"; K60B="$(mkrepo keeper60b "$(config 60)")"
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O25" fire SessionStart s25 "$K60" >/dev/null; wait_sent 1
wait_keeper s25; UP25=$?   # the keeper holds its lock before the burst
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
# a duplicate keeper started during the burst tries its lock for up to two seconds before it leaves
j=0; while KEEPERS="$(pgrep -f "presence.py keeper s25\$" | wc -l | tr -d ' ')" && [ "$KEEPERS" != 1 ] && [ $j -lt 50 ]; do sleep 0.1; j=$((j + 1)); done
if [ "$UP25" = 0 ] && [ "$i" -lt 100 ] && [ "$ORDER" = ok ] && [ "$KEEPERS" = 1 ]; then
  ok "(25) 30 prompts and Stops at once across two checkouts → queued = done, PRESENCE_AT never falls, one keeper"
else bad "(25) up=$UP25 i=$i order=$ORDER keepers=$KEEPERS $(cat "$RECORDS/s25.json")"; fi
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
begin() { # begin SESSION — a reported session with no keeper (the cases drive every send themselves); with
  #           no known process, no later tool call starts one again (a prompt re-reads the process)
  fire SessionStart "$1" "$R29" >/dev/null; upto "$1" 1; stop_keeper "$1"; edit "$1" 'r["owner"] = 0'
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
#      held change; applied once: a helper's call with no prompt → working and its call kept, and the
#      next prompt → working, even while the transcript still ends there
: > "$LOG"; O37="$(owner)"; T37="$WORK/t37.jsonl"
entry "$T37" prompt,assistant >/dev/null
DEVSTRIDE_PRESENCE_MINUTE=1 CLAUDE_PID="$O37" fire SessionStart s37 "$K60" "" "$(transcript "$T37")" >/dev/null; upto s37 1
age s37 61; DEVSTRIDE_PRESENCE_MINUTE=1 CLAUDE_PID="$O37" fire UserPromptSubmit s37 "$K60" "" "$(transcript "$T37")" >/dev/null; upto s37 2
fire PreToolUse s37 "$K60" "" "$(tool Bash i1)" >/dev/null; settle
BEFORE37="$(rec s37 'r["state"], len(r["tools"])')"; sleep 0.05
M37="$(entry "$T37" esc-tool,bookkeeping,helper)"; settle
HELD37="$(rec s37 'r["state"], len(r["tools"]), r["interrupt"], r["activeAt"]')"; N37="$(of s37 0)"   # held: sent within 30 s
age s37 31; upto s37 3
fire PreToolUse s37 "$K60" "" "$(tool Read h37 helper-37)" >/dev/null; settle   # a helper that outlived the Esc works on; no prompt
HELPER37="$(rec s37 'r["state"], len(r["tools"]), r["interrupt"]')"            # the same interrupt is not applied a second time
fire Stop s37 "$K60" >/dev/null                                               # the helper is done: waiting again, as reported
age s37 31; DEVSTRIDE_PRESENCE_MINUTE=1 CLAUDE_PID="$O37" fire UserPromptSubmit s37 "$K60" "" "$(transcript "$T37")" >/dev/null; upto s37 4; settle
AGAIN37="$(rec s37 'r["state"]')"
M37B="$(entry "$T37" esc)"; settle; age s37 31; upto s37 5   # interrupted again, while Claude was writing
if [ "$BEFORE37" = "('working', 1)" ] && [ "$HELD37" = "('waiting', 0, $M37, $M37)" ] && [ "$N37" = 2 ] \
   && [ "$(of s37 3 PRESENCE_EVENT)" = beat ] && [ "$(of s37 3 PRESENCE_STATE)" = waiting ] && [ -z "$(of s37 3 PRESENCE_BUSY_SINCE)" ] \
   && [ "$(of s37 3 PRESENCE_ACTIVE_AT)" = "$M37" ] && [ "$HELPER37" = "('working', 1, $M37)" ] \
   && [ "$(of s37 4 PRESENCE_STATE)" = working ] && [ "$AGAIN37" = working ] \
   && [ "$(of s37 5 PRESENCE_STATE)" = waiting ] && [ "$(rec s37 'r["interrupt"]')" = "$M37B" ]; then
  ok "(37) transcript ends on the interrupt entry (past a 300 KB entry, bookkeeping and a helper's entry) → the keeper sends waiting, not busy; a helper's call or a prompt → working, the old interrupt not applied again; a new interrupt → waiting"
else bad "(37) before=$BEFORE37 held=$HELD37 m=$M37 n=$N37 helper=$HELPER37 again=$AGAIN37 m2=$M37B $(grep '"s37"' "$LOG") $(cat "$RECORDS/s37.json")"; fi
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

# (38b) an Esc while the model is still thinking writes no transcript entry and fires no hook, but
#       Claude Code's own status file for the session's process turns "idle": a working session whose
#       file says idle → waiting at that time, sent as a held change, and not applied again after the
#       next prompt; a busy file, an idle time before the last prompt or activity, another session or
#       process, a symlink, background work left running or a failed turn → nothing
status() { # status OWNER SESSION STATUS [AGE-MS] [PID] — write Claude Code's status file; prints its time
  python3 - "$CLAUDE_CONFIG_DIR/sessions" "$1" "$2" "$3" "${4:-0}" "${5:-$1}" <<'PY'
import json, os, sys, time
d, owner, sid, st, age, pid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
os.makedirs(d, exist_ok=True); ms = int(time.time() * 1000) - age; p = os.path.join(d, "%d.json" % owner)
json.dump({"pid": pid, "sessionId": sid, "status": st, "statusUpdatedAt": ms, "updatedAt": ms}, open(p + ".t", "w"))
os.replace(p + ".t", p); print(ms)
PY
}
: > "$LOG"; O38B="$(owner)"; T38B="$WORK/t38b.jsonl"; D38B=""
entry "$T38B" prompt,assistant >/dev/null
DEVSTRIDE_PRESENCE_MINUTE=1 CLAUDE_PID="$O38B" fire SessionStart s38b "$K60" "" "$(transcript "$T38B")" >/dev/null; upto s38b 1
wait_keeper s38b   # its keeper (one check a second) holds the lock before any step
age s38b 61; DEVSTRIDE_PRESENCE_MINUTE=1 CLAUDE_PID="$O38B" fire UserPromptSubmit s38b "$K60" "" "$(transcript "$T38B")" >/dev/null; upto s38b 2
entry "$T38B" prompt >/dev/null   # the transcript ends on the prompt, as it does mid-thought
doubt38b() { settle; D38B="$D38B $1:$(rec s38b 'r["state"], r.get("interrupt")')"; }
status "$O38B" s38b busy >/dev/null; doubt38b busy
status "$O38B" s38b idle 60000 >/dev/null; doubt38b before-prompt
status "$O38B" other idle >/dev/null; doubt38b other-session
status "$O38B" s38b idle 0 1 >/dev/null; doubt38b other-process
edit s38b 'r["background"] = r["activeAt"]'; status "$O38B" s38b idle >/dev/null; doubt38b background
edit s38b 'r["background"] = 0; r["failed"] = True'; status "$O38B" s38b idle >/dev/null; doubt38b failed
edit s38b 'r["failed"] = False; r["activeAt"] = int(__import__("time").time() * 1000) + 60000'; status "$O38B" s38b idle >/dev/null; doubt38b before-activity
status "$O38B" s38b busy >/dev/null; edit s38b 'r["activeAt"] = r["prompted"]'   # busy first: the idle file left by the step above would now qualify
status 1 s38b idle 0 "$O38B" >/dev/null; mv -f "$CLAUDE_CONFIG_DIR/sessions/1.json" "$WORK/real38b.json"
rm -f "$CLAUDE_CONFIG_DIR/sessions/$O38B.json"; ln -s "$WORK/real38b.json" "$CLAUDE_CONFIG_DIR/sessions/$O38B.json"; doubt38b symlink
rm -f "$CLAUDE_CONFIG_DIR/sessions/$O38B.json"; doubt38b missing
N38B="$(of s38b 0)"; M38B="$(status "$O38B" s38b idle)"; settle
HELD38B="$(rec s38b 'r["state"], len(r["tools"]), r["interrupt"], r["activeAt"]')"; age s38b 31; upto s38b 3
age s38b 31; DEVSTRIDE_PRESENCE_MINUTE=1 CLAUDE_PID="$O38B" fire UserPromptSubmit s38b "$K60" "" "$(transcript "$T38B")" >/dev/null; upto s38b 4; settle
AGAIN38B="$(rec s38b 'r["state"]')"   # the file still says idle, from before this prompt
WANT38B=""; for d in busy before-prompt other-session other-process background failed before-activity symlink missing; do WANT38B="$WANT38B $d:('working', None)"; done
if [ "$D38B" = "$WANT38B" ] && [ "$N38B" = 2 ] && [ "$HELD38B" = "('waiting', 0, $M38B, $M38B)" ] \
   && [ "$(of s38b 3 PRESENCE_STATE)" = waiting ] && [ "$(of s38b 3 PRESENCE_ACTIVE_AT)" = "$M38B" ] \
   && [ "$(of s38b 4 PRESENCE_STATE)" = working ] && [ "$AGAIN38B" = working ]; then
  ok "(38b) Claude Code's status file turns idle (an Esc mid-thought) → waiting at that time, once; busy, stale, another session or process, a symlink, background work or a failed turn → nothing"
else bad "(38b) got=$D38B n=$N38B held=$HELD38B m=$M38B again=$AGAIN38B $(grep '"s38b"' "$LOG") $(cat "$RECORDS/s38b.json")"; fi
stop_keeper s38b

# Helpers for (39)-(42): a copy of this plugin at another version (the same code, so its keeper
# checks the version), and a stand-in for a keeper an earlier version started, which holds the
# session's keeper lock and never checks anything.
OLDP="$WORK/oldplugin"; mkdir -p "$OLDP/.claude-plugin" "$OLDP/hooks" "$OLDP/skills/build-item/scripts"
printf '{"name":"devstride","version":"1.0.0"}' > "$OLDP/.claude-plugin/plugin.json"
cp "$HOOK" "$ROOT/hooks/presence-report.py" "$OLDP/hooks/"; cp "$ROOT"/skills/build-item/scripts/*.py "$OLDP/skills/build-item/scripts/"
LEGACY="$WORK/legacyplugin"; mkdir -p "$LEGACY/hooks"
cat > "$LEGACY/hooks/presence.py" <<'PY'
import fcntl, os, sys, time
fd = os.open(os.path.join(os.environ["XDG_CACHE_HOME"], "devstride-plugin", "presence", sys.argv[2] + ".keeper.lock"),
             os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(300)
PY
keeper_cmd() { local p; p="$(keeper_pid "$1")"; [ -n "$p" ] && ps -ww -o command= -p "$p"; }
legacy() { # legacy SESSION — start a stand-in earlier-version keeper for SESSION and wait for its lock
  python3 "$LEGACY/hooks/presence.py" keeper "$1" >/dev/null 2>&1 &
  echo "$!" >> "$WORK/owners"; wait_keeper "$1"   # the EXIT trap stops it, however the case ends
}

# (39) each report carries the version of the code sending it: an older copy's send reports its
#      own version, whatever the record holds
begin s47; edit s47 'r["queued"] = int(r.get("queued") or 0) + 1'
python3 "$OLDP/hooks/presence.py" send beat "$(rec s47 'r["state"]')" s47 "$(rec s47 'r["id"]')" "$(rec s47 'r["queued"]')" "$(now_ms)"
if [ "$(rec s47 'r["version"]')" = "$OWNV" ] && [ "$(of s47 1 PRESENCE_PLUGIN_VERSION)" = "$OWNV" ] \
   && [ "$(of s47 2 PRESENCE_PLUGIN_VERSION)" = 1.0.0 ]; then
  ok "(39) the record holds the hook's own version; a report sent by another version's code carries that code's version"
else bad "(39) record=$(rec s47 'r["version"]') $(grep '"s47"' "$LOG")"; fi

# (40) a keeper leaves once the session's hooks run another version: the loaded version's hook records
#      its own version, the old keeper sees it and leaves by itself, and the session's next hook event
#      of any kind, here a tool call ending, starts one from the loaded version
: > "$LOG"; O38="$(owner)"
HOOK_RUN="$OLDP/hooks/presence.py" DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O38" fire SessionStart s48 "$K60" >/dev/null
wait_keeper s48; OLDK="$(keeper_cmd s48)"; V0="$(rec s48 'r["version"]')"
edit s48 'r["swept"] = "'"$OWNV"'"'   # no process scan: the old keeper's own check is what is tested
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O38" fire PreToolUse s48 "$K60" "" "$(tool Bash k38)" >/dev/null
V1="$(rec s48 'r["version"]')"
i=0; while keeper_alive s48 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; LEFT38=$i
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O38" fire PostToolUse s48 "$K60" "" "$(tool Bash k38)" >/dev/null
wait_keeper s48; UP48=$?; NEWK="$(keeper_cmd s48)"
if case "$OLDK" in *"$OLDP/hooks/presence.py keeper s48") true;; *) false;; esac && [ "$V0" = 1.0.0 ] && [ "$V1" = "$OWNV" ] \
   && [ "$LEFT38" -lt 50 ] && [ "$UP48" = 0 ] && [ -n "$NEWK" ] && case "$NEWK" in *"$OLDP"*) false;; *"/hooks/presence.py keeper s48") true;; *) false;; esac; then
  ok "(40) the loaded version's tool call records its version → the old keeper leaves by itself; the call's end starts the loaded version's keeper"
else bad "(40) old=$OLDK v=$V0/$V1 left=$LEFT38 up=$UP48 new=$NEWK"; fi
stop_keeper s48

# (41) after an update, a keeper an earlier version started (it never checks the version) is ended
#      once by the new hook, which starts its own; only this session's: another session's keeper and
#      a keeper running this very code are never touched. The replacement's reports carry the busy
#      mark while a call is open and while the finished turn's background work runs.
: > "$LOG"; O39="$(owner)"
CLAUDE_PID="$O39" fire SessionStart s49 "$K" >/dev/null; upto s49 1; stop_keeper s49
edit s49 'r.pop("swept", None)'            # written by an earlier version: no sweep recorded
legacy s49; legacy s49x; LPID="$(keeper_pid s49)"; XPID="$(keeper_pid s49x)"
# another session (s49y) whose keeper runs this code, and whose record names no sweep either
CLAUDE_PID="$O39" fire SessionStart s49y "$K60" >/dev/null; wait_keeper s49y; YPID="$(keeper_pid s49y)"
edit s49y 'r.pop("swept", None)'; age s49y 61; CLAUDE_PID="$O39" fire UserPromptSubmit s49y "$K60" >/dev/null
T39="$(now_ms)"; DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O39" fire PreToolUse s49 "$K" "" "$(tool Bash c39)" >/dev/null
wait_keeper s49; RPID="$(keeper_pid s49)"; RCMD="$(keeper_cmd s49)"; C39="$(rec s49 'r["tools"]["c39"]')"
N39="$(of s49 0)"; upto s49 $((N39 + 2)); CALLBUSY="$(of s49 "$((N39 + 2))" PRESENCE_BUSY_SINCE)"
fire PostToolUse s49 "$K" "" "$(tool Bash c39)" >/dev/null
fire Stop s49 "$K" "" '{"background_tasks":[{"id":"b39","type":"shell","status":"running","command":"sleep 900"}]}' >/dev/null
BG39="$(rec s49 'r["background"]')"; N39B="$(of s49 0)"; upto s49 $((N39B + 2))
BGBUSY="$(of s49 "$((N39B + 2))" PRESENCE_BUSY_SINCE)"; BGVER="$(of s49 "$((N39B + 2))" PRESENCE_PLUGIN_VERSION)"
if [ -n "$LPID" ] && ! kill -0 "$LPID" 2>/dev/null && kill -0 "$XPID" 2>/dev/null && [ -n "$YPID" ] && [ "$(keeper_pid s49y)" = "$YPID" ] && [ "$(rec s49y 'r.get("swept")')" = "$OWNV" ] \
   && [ -n "$RPID" ] && [ "$RPID" != "$LPID" ] && case "$RCMD" in *"$LEGACY"*) false;; *"/hooks/presence.py keeper s49") true;; *) false;; esac \
   && [ "$(rec s49 'r["swept"]')" = "$OWNV" ] && [ "$C39" -ge "$T39" ] && [ "$CALLBUSY" = "$C39" ] \
   && [ -n "$BG39" ] && [ "$BG39" != 0 ] && [ "$BGBUSY" = "$BG39" ] && [ "$BGVER" = "$OWNV" ]; then
  ok "(41) an earlier version's keeper → ended at the next tool call and replaced; another session's untouched; the replacement beats busy (open call, then background work), with its own version"
else bad "(41) legacy=$LPID other=$XPID y=$YPID/$(keeper_pid s49y) yalive=$(kill -0 "$YPID" 2>/dev/null && echo yes || echo no) yrec=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print({k: r.get(k) for k in ("state","reason","version","swept","owner","ownerStarted","sent","mode")})' "$RECORDS/s49y.json" 2>&1) ownernow=$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$O39" 2>&1) new=$RPID cmd=$RCMD swept=$(rec s49 'r.get("swept")') c=$C39 t=$T39 callbusy=$CALLBUSY bg=$BG39 bgbusy=$BGBUSY ver=$BGVER"; fi
kill "$XPID" "$LPID" 2>/dev/null; stop_keeper s49; stop_keeper s49y

# (42) the hook that ends an earlier version's keeper sends a report from this version at once, busy
#      since the call it opens: the ended keeper may have dropped one, and the replacement's first
#      ordinary beat is an interval away (here an hour; a held change waits 30 s)
: > "$LOG"; O40="$(owner)"
CLAUDE_PID="$O40" fire SessionStart s50 "$K60" >/dev/null; upto s50 1; stop_keeper s50
edit s50 'r.pop("swept", None)'; legacy s50; L40="$(keeper_pid s50)"
CLAUDE_PID="$O40" fire PreToolUse s50 "$K60" "" "$(tool Bash c40)" >/dev/null; upto s50 2
C40="$(rec s50 'r["tools"]["c40"]')"
if ! kill -0 "$L40" 2>/dev/null && [ "$(of s50 0)" = 2 ] && [ "$(of s50 2 PRESENCE_EVENT)" = beat ] \
   && [ "$(of s50 2 PRESENCE_STATE)" = working ] && [ "$(of s50 2 PRESENCE_BUSY_SINCE)" = "$C40" ] \
   && [ "$(of s50 2 PRESENCE_PLUGIN_VERSION)" = "$OWNV" ] && wait_keeper s50; then
  ok "(42) ending an earlier version's keeper → a beat from this version at once (busy since the open call), its own keeper running"
else bad "(42) legacy=$L40 $(grep '"s50"' "$LOG")"; fi
kill "$L40" 2>/dev/null; stop_keeper s50

# (43) a keeper starting while something only checks the lock (a hook's keeper_running, a test's
#      probe) waits for it instead of leaving: a check holds the lock, the keeper starts and is still
#      waiting a second later (a keeper that tries once has left by then), and once the check lets
#      go the same keeper takes the lock and runs
: > "$LOG"; O43="$(owner)"
CLAUDE_PID="$O43" fire SessionStart s51 "$K60" >/dev/null; upto s51 1; stop_keeper s51
python3 - "$RECORDS/s51.keeper.lock" "$WORK/held43" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(60)
PY
P43=$!; echo "$P43" >> "$WORK/owners"
i=0; while [ ! -e "$WORK/held43" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
python3 "$HOOK" keeper s51 >/dev/null 2>&1 & K43=$!; echo "$K43" >> "$WORK/owners"
sleep 1; INWAIT=no; kill -0 "$K43" 2>/dev/null && INWAIT=yes   # still trying while the check holds it
kill "$P43" 2>/dev/null; wait "$P43" 2>/dev/null; wait_keeper s51; UP43=$?
if [ -e "$WORK/held43" ] && [ "$INWAIT" = yes ] && [ "$UP43" = 0 ] && kill -0 "$K43" 2>/dev/null \
   && [ "$(keeper_pid s51)" = "$K43" ]; then
  ok "(43) a keeper starting while a check holds its lock waits for it, then runs and holds the lock"
else bad "(43) held=$([ -e "$WORK/held43" ] && echo yes || echo no) inwait=$INWAIT up=$UP43 alive=$(kill -0 "$K43" 2>/dev/null && echo yes || echo no) pid=$K43/$(keeper_pid s51)"; fi
kill "$K43" 2>/dev/null; stop_keeper s51

# ── The built-in reporter (B1)-(B8): no repository command, the report goes to DevStride with the
# key the machine's connection carries. A fake server stands in (it accepts any key and records the
# digest of the one that arrived); every session's keeper is stopped once its case has its start.
FX="$ROOT/scripts/tests/fixtures/clearance"
server() { # server NAME — start a fake DevStride server; prints its state directory
  local d="$WORK/ds-$1" n=0; mkdir -p "$d"; : > "$d/any-key"
  python3 "$FX/fake-devstride.py" "$d" >/dev/null 2>&1 & echo "$!" >> "$WORK/owners"
  until [ -s "$d/port" ] || [ $n -gt 100 ]; do sleep 0.05; n=$((n + 1)); done; printf '%s' "$d"
}
DS="$(server main)"; export DEVSTRIDE_PLUGIN_TEST_URL="http://127.0.0.1:$(cat "$DS/port")"
key() { export DEVSTRIDE_API_KEY="${1:-test-key}" DEVSTRIDE_API_SECRET=test-secret DEVSTRIDE_ORG_ID=org-1; }
nokey() { unset DEVSTRIDE_API_KEY DEVSTRIDE_API_SECRET DEVSTRIDE_ORG_ID; }
dig() { printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest())'; }
got() { # got SESSION N FIELD [STATE-DIR] — FIELD of the session's Nth report at the server (N=0: how many);
  #       FIELD `keys` is its sorted key list; a key the report does not carry prints "-"
  python3 -c 'import json,os,sys
p=os.path.join(sys.argv[4],"presence.jsonl")
rows=[json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []
rows=[r for r in rows if r.get("sessionId")==sys.argv[1]]; n=int(sys.argv[2])
if n==0: print(len(rows))
elif len(rows)<n: print("?")
elif sys.argv[3]=="keys": print(",".join(sorted(k for k in rows[n-1] if not k.startswith("_"))))
else: print(rows[n-1].get(sys.argv[3],"-"))' "$1" "$2" "${3:-}" "${4:-$DS}"
}
reach() { local i=0; while [ "$(got "$1" 0 "" "${3:-$DS}")" -lt "$2" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; [ "$(got "$1" 0 "" "${3:-$DS}")" -ge "$2" ]; }
bbegin() { # bbegin SESSION DIR — a session the built-in reporter started, with no keeper and no known process
  fire SessionStart "$1" "$2" >/dev/null 2>&1; reach "$1" 1; stop_keeper "$1"; edit "$1" 'r["owner"] = 0'
}
claudejson() { # claudejson PYTHON — write Claude Code's configuration file (mode 600) from a Python expression;
  #              E(key, **changes) is a devstride server entry carrying KEY
  python3 - "$CLAUDE_CONFIG_DIR/.claude.json" "$1" <<'PY'
import json, os, sys
def E(key, url=os.environ["DEVSTRIDE_PLUGIN_TEST_URL"] + "/mcp", **changes):  # under the tests-only address only an entry at it is usable
    headers = {"X-DevStride-Api-Key": key, "X-DevStride-Api-Secret": "test-secret", "X-DevStride-Organization-Id": "org-1"}
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
real() { (cd "$1" && pwd -P); }
BP="$(mkrepo b-plain)"   # a repository with no presence block

# (B1) the decision: the machine switch, the repository switch, a blank command, a named command over
#      a key, the built-in reporter with a key and nothing without one, and the interval defaults
key; : > "$LOG"
for w in 0 false OFF " no "; do DEVSTRIDE_PRESENCE="$w" fire SessionStart b1off "$R" >/dev/null 2>&1; DEVSTRIDE_PRESENCE="$w" fire SessionStart b1off "$BP" >/dev/null 2>&1; done
fire SessionStart b1null "$N" >/dev/null 2>&1
fire SessionStart b1blank "$(mkrepo b-blank '{"presence":{"command":"  ","intervalMinutes":2}}')" >/dev/null 2>&1
fire SessionStart b1cmd "$R" >/dev/null 2>&1; upto b1cmd 1; stop_keeper b1cmd
bbegin b1in "$BP"
(nokey; fire SessionStart b1nk "$BP" >/dev/null 2>&1); sleep 0.5
bbegin b1e "$(mkrepo b-empty '{"presence":{}}')"; bbegin b1i3 "$(mkrepo b-three '{"presence":{"intervalMinutes":3}}')"
bbegin b1i99 "$(mkrepo b-far '{"presence":{"intervalMinutes":99}}')"; bbegin b1str "$(mkrepo b-str '{"presence":"yes"}')"
if [ "$(of b1off 0)" = 0 ] && [ "$(got b1off 0)" = 0 ] && [ ! -e "$RECORDS/b1off.json" ] && [ ! -e "$RECORDS/b1null.json" ] \
   && [ ! -e "$RECORDS/b1blank.json" ] && [ "$(of b1cmd 0)" = 1 ] && [ "$(got b1cmd 0)" = 0 ] && [ "$(rec b1cmd 'r["mode"]')" = command ] \
   && [ "$(got b1in 1 event)" = start ] && [ "$(rec b1in 'r["mode"]')" = builtin ] && [ "$(of b1in 0)" = 0 ] \
   && [ ! -e "$RECORDS/b1nk.json" ] && ! keeper_alive b1nk \
   && [ "$(got b1in 1 intervalMinutes)" = 1 ] && [ "$(got b1e 1 intervalMinutes)" = 1 ] && [ "$(got b1i3 1 intervalMinutes)" = 3 ] \
   && [ "$(got b1i99 1 intervalMinutes)" = 1 ] && [ "$(got b1str 1 intervalMinutes)" = 1 ]; then
  ok "(B1) DEVSTRIDE_PRESENCE off (a repository command included), presence null, a blank command → nothing; a named command wins over a key; no block + a key → the built-in reporter (interval 1, a block's own 3, out of range 1); no key → no record, no keeper"
else bad "(B1) off=$(of b1off 0)/$(got b1off 0) cmd=$(of b1cmd 0)/$(got b1cmd 0) in=$(got b1in 1 event)/$(of b1in 0) nk=$(ls "$RECORDS" | grep -c b1nk) iv=$(got b1in 1 intervalMinutes),$(got b1e 1 intervalMinutes),$(got b1i3 1 intervalMinutes),$(got b1i99 1 intervalMinutes),$(got b1str 1 intervalMinutes)"; fi

# (B2) outside any repository: a start with no checkout, branch or item; the record has no root and
#      keeps the directory; a prompt from a subdirectory is not a move; walking into a repository beats once
mkdir -p "$WORK/out/sub"
fire SessionStart b2 "$WORK/out" >/dev/null 2>&1; reach b2 1; stop_keeper b2
K1="$(got b2 1 keys)"; TOP="$(rec b2 'r["top"]')"; DIR1="$(rec b2 'r["dir"]')"
fire UserPromptSubmit b2 "$WORK/out/sub" >/dev/null 2>&1; sleep 0.6; A="$(got b2 0)"
fire UserPromptSubmit b2 "$BP" >/dev/null 2>&1; reach b2 2; stop_keeper b2
fire UserPromptSubmit b2 "$BP" >/dev/null 2>&1; sleep 0.6; stop_keeper b2
if [ "$K1" = "activeAt,event,intervalMinutes,machine,pluginVersion,reportedAt,sessionId,state" ] && [ "$TOP" = None ] \
   && [ "$DIR1" = "$(real "$WORK/out")" ] && [ "$A" = 1 ] && [ "$(got b2 0)" = 2 ] && [ "$(got b2 2 event)" = beat ] \
   && [ "$(got b2 2 checkout)" = b-plain ] && [ "$(got b2 2 branch)" = main ]; then
  ok "(B2) outside a repository → start with no checkout, branch or item (record: no root, the directory kept); a subdirectory is no move; into a repository → one beat from it"
else bad "(B2) keys=$K1 top=$TOP dir=$DIR1 a=$A n=$(got b2 0) $(got b2 2 keys)"; fi

# (B3) what is sent: exactly the documented fields for a start, a working beat (busy since its open
#      call), a waiting beat and an end; the checkout is a base name; the label is the session's own name
BB="$(mkrepo b-body '{}' "phil/26-01-01/$ITEM_NO-built-in")"; O3="$(owner)"; mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
printf '{"sessionId":"b3","pid":%s,"name":"Fleet walk"}' "$O3" > "$CLAUDE_CONFIG_DIR/sessions/$O3.json"
CLAUDE_PID="$O3" fire SessionStart b3 "$BB" >/dev/null 2>&1; reach b3 1; stop_keeper b3; edit b3 'r["owner"] = 0'
age b3 61; fire UserPromptSubmit b3 "$BB" >/dev/null 2>&1; reach b3 2
fire PreToolUse b3 "$BB" "" "$(tool Bash t-b3)" >/dev/null 2>&1
edit b3 'r["queued"] = int(r.get("queued") or 0) + 1'
python3 "$HOOK" send beat working b3 "$(rec b3 'r["id"]')" "$(rec b3 'r["queued"]')" "$(now_ms)"; reach b3 3
fire PostToolUse b3 "$BB" "" "$(tool Bash t-b3)" >/dev/null 2>&1
age b3 31; fire Stop b3 "$BB" >/dev/null 2>&1; reach b3 4
fire SessionEnd b3 "$BB" logout >/dev/null 2>&1; reach b3 5
COMMON="activeAt,branch,checkout,event,intervalMinutes,item,label,machine,pluginVersion,reportedAt,sessionId"
if [ "$(got b3 1 keys)" = "$COMMON,state" ] && [ "$(got b3 1 state)" = starting ] && [ "$(got b3 1 checkout)" = b-body ] \
   && [ "$(got b3 1 item)" = "$ITEM_NO" ] && [ "$(got b3 1 pluginVersion)" = "$OWNV" ] && [ "$(got b3 1 reportedAt)" -gt 1000000000000 ] \
   && [ "$(got b3 2 keys)" = "$COMMON,state" ] && [ "$(got b3 2 state)" = working ] \
   && [ "$(got b3 3 keys)" = "activeAt,branch,busySince,checkout,event,intervalMinutes,item,label,machine,pluginVersion,reportedAt,sessionId,state" ] \
   && [ "$(got b3 4 keys)" = "$COMMON,state" ] && [ "$(got b3 4 state)" = waiting ] \
   && [ "$(got b3 5 keys)" = "activeAt,branch,checkout,endReason,event,intervalMinutes,item,label,machine,pluginVersion,reportedAt,sessionId" ] \
   && [ "$(got b3 5 event)" = end ] && [ "$(got b3 5 endReason)" = logout ]; then
  ok "(B3) start, working beat (busySince only while a call is open), waiting beat and end carry exactly the documented fields; checkout is a base name"
else bad "(B3) 1=$(got b3 1 keys) 2=$(got b3 2 keys) 3=$(got b3 3 keys) 4=$(got b3 4 keys) 5=$(got b3 5 keys)"; fi
if [ "$(got b3 1 label)" = "Fleet walk" ] && [ "$(got b2 1 label)" = "-" ]; then ok "(B3b) the label is the session's own name from Claude Code's session record; none → no label"
else bad "(B3b) label=$(got b3 1 label) / $(got b2 1 label)"; fi

# (B4) where the key comes from: the environment, the connection's user-level entry, the session's
#      project entry (the repository root, the main checkout for a linked worktree, a plain directory);
#      the environment wins over an entry and a project entry over the user-level one
MAINR="$(mkrepo b-main)"; git -C "$MAINR" worktree add -q "$WORK/b-linked" -b linked 2>/dev/null; mkdir -p "$WORK/b-dir"
src() { # src SESSION DIR EXPECTED-KEY — start SESSION in DIR; pass when the server got EXPECTED-KEY's digest
  fire SessionStart "$1" "$2" >/dev/null 2>&1; reach "$1" 1; stop_keeper "$1"
  [ "$(got "$1" 1 _keyDigest)" = "$(dig "$3")" ] || { SRC_BAD="$SRC_BAD $1=$(got "$1" 0)"; return 1; }
}
SRC_BAD=""
key k-env; noconfig; src b4env "$BP" k-env
nokey
claudejson '{"mcpServers": {"devstride": E("k-user")}}'; src b4user "$BP" k-user
claudejson "{'projects': {'$(real "$BP")': {'mcpServers': {'devstride': E('k-proj')}}}}"; src b4proj "$BP" k-proj
claudejson "{'projects': {'$(real "$MAINR")': {'mcpServers': {'devstride': E('k-main')}}}}"; src b4tree "$WORK/b-linked" k-main
claudejson "{'projects': {'$(real "$WORK/b-dir")': {'mcpServers': {'devstride': E('k-dir')}}}}"; src b4dir "$WORK/b-dir" k-dir
claudejson "{'mcpServers': {'devstride': E('k-user')}, 'projects': {'$(real "$BP")': {'mcpServers': {'devstride': E('k-proj')}}}}"; src b4both "$BP" k-proj
claudejson "{'mcpServers': {'devstride': {'type': 'http', 'url': '$DEVSTRIDE_PLUGIN_TEST_URL/mcp', 'headers': {'x-devstride-api-key': 'k-lower', 'x-devstride-api-secret': 'test-secret', 'x-devstride-organization-id': 'org-1'}}}}"; src b4low "$BP" k-lower
key k-env2; claudejson '{"mcpServers": {"devstride": E("k-user")}}'; src b4wins "$BP" k-env2
nokey
if [ -z "$SRC_BAD" ]; then ok "(B4) the key is found in the environment, the user-level entry, the project entry (repository root, main checkout of a linked worktree, a plain directory); environment > project entry > user-level; header names in any case"
else bad "(B4) wrong or no key for:$SRC_BAD"; fi

# (B4b) never used, so the session is not reported: a header that references a variable, an entry
#       missing its secret or organization, an address that is not a DevStride API host, another
#       server name, a keyless entry (the browser sign-in shape), an unsafe configuration file
unused() { fire SessionStart "$1" "$BP" >/dev/null 2>&1; sleep 0.3; [ ! -e "$RECORDS/$1.json" ] || { USED="$USED $1"; stop_keeper "$1"; }; }
USED=""
claudejson '{"mcpServers": {"devstride": E("${DEVSTRIDE_API_KEY}")}}'; unused b4ref
claudejson '{"mcpServers": {"devstride": E("k", **{"X-DevStride-Api-Secret": None})}}'; unused b4nosecret
claudejson '{"mcpServers": {"devstride": E("k", **{"X-DevStride-Organization-Id": ""})}}'; unused b4noorg
claudejson '{"mcpServers": {"devstride": E("k", url="https://example.com/mcp")}}'; unused b4host
claudejson '{"mcpServers": {"devstride": E("k", url="https://api.devstride.com.evil.example/mcp")}}'; unused b4evil
claudejson '{"mcpServers": {"devstride": E("k", url="https://api.devstride.com/other")}}'; unused b4path
claudejson '{"mcpServers": {"devstride": E("k", url="https://api.devstride.com/mcp")}}'; unused b4real
claudejson '{"mcpServers": {"devstride-2": E("k")}}'; unused b4name
claudejson '{"mcpServers": {"devstride": {"type": "http", "url": "https://api.devstride.com/mcp"}}}'; unused b4keyless
claudejson '{"mcpServers": {"devstride": E("k")}}'; chmod 644 "$CLAUDE_CONFIG_DIR/.claude.json"; unused b4mode
claudejson '{"mcpServers": {"devstride": E("k")}}'; mv "$CLAUDE_CONFIG_DIR/.claude.json" "$WORK/real.json"; ln -s "$WORK/real.json" "$CLAUDE_CONFIG_DIR/.claude.json"; unused b4link
rm -f "$CLAUDE_CONFIG_DIR/.claude.json"
claudejson '{"mcpServers": {"devstride": E("k")}}'; python3 -c 'import sys; f=open(sys.argv[1],"ab"); f.truncate(17*1048576)' "$CLAUDE_CONFIG_DIR/.claude.json"; unused b4big
noconfig
if [ -z "$USED" ]; then ok "(B4b) a \${VAR} header, a missing secret or organization, a foreign or look-alike host, another path, DevStride's real address while the tests-only one is set, another server name, a keyless entry, a file open to others, a link and an oversized file are never used: no record"
else bad "(B4b) used:$USED"; fi

# (B5) the no-key notices: never with reporting switched off or a repository command; with no key, every
#      start shows the line and a prompt that runs a DevStride skill asks the model to register a reporter
#      credential; a key, or a reporter credential, silences both; an old once-per-machine marker is removed
line_case() { # the cases below, in a cache of their own
  local cache="$WORK/cache-line"; local mark="$cache/devstride-plugin/presence-no-key"
  export XDG_CACHE_HOME="$cache"; nokey; noconfig
  mkdir -p "$(dirname "$mark")"; : > "$mark"
  local quiet first again ask alias plain keyed
  quiet="$(DEVSTRIDE_PRESENCE=0 fire SessionStart b5a "$BP" 2>&1)$(fire SessionStart b5b "$N" 2>&1)$(fire SessionStart b5c "$R" 2>&1)"
  [ -z "$quiet" ] && [ ! -e "$mark" ] || { echo "switched off or a command printed: $quiet (or the marker stayed)"; return 1; }
  first="$(fire SessionStart b5d "$BP" 2>&1)"; again="$(fire SessionStart b5e "$WORK/out" 2>&1)"
  [ "$first" = "$START_JSON" ] && [ "$again" = "$START_JSON" ] || { echo "first=$first again=$again"; return 1; }
  ask="$(fire UserPromptSubmit b5d "$BP" "" '{"prompt":"  /devstride:build-item I1"}' 2>&1)"
  own="$(fire UserPromptSubmit b5d "$BP" "" '{"prompt":"/devstride:setup connect"}' 2>&1)$(fire UserPromptSubmit b5d "$BP" "" '{"prompt":"/devstride:doctor"}' 2>&1)"
  alias="$(fire UserPromptSubmit b5d "$BP" "" '{"prompt":"/ds:build-item next"}' 2>&1)"
  plain="$(fire UserPromptSubmit b5d "$BP" "" '{"prompt":"please run /devstride:build-item"}' 2>&1)"
  python3 - "$ask" "$(cd "$ROOT" && pwd -P)" <<'PY' || { echo "ask=$ask"; return 1; }
import json, sys
for raw in sys.argv[1:2]:
    out = json.loads(raw)["hookSpecificOutput"]
    assert out["hookEventName"] == "UserPromptSubmit", out
    text = out["additionalContext"]
    assert "register_session_reporter" in text and "prepare" in text and "finish --key-id" in text, text
    assert sys.argv[2] + "/skills/build-item/scripts/reporter_credential.py" in text, text
    assert "Profile Settings" in text and "/devstride:setup connect" in text, text
PY
  [ -z "$plain" ] || { echo "a prompt not starting with a skill asked: $plain"; return 1; }
  [ -z "$alias" ] || { echo "a /ds: prompt (which runs no skill) asked: $alias"; return 1; }
  [ -z "$own" ] || { echo "setup or doctor asked to register: $own"; return 1; }
  key; keyed="$(fire SessionStart b5f "$BP" 2>&1)$(fire UserPromptSubmit b5f "$BP" "" '{"prompt":"/devstride:build-item"}' 2>&1)"
  pkill -f "presence.py keeper b5f\$" 2>/dev/null
  [ -z "$keyed" ] || { echo "with a key: $keyed"; return 1; }
  nokey
  # a reporter credential is a key for the reporter: nothing is said
  local conf="$XDG_CONFIG_HOME/devstride-plugin" reported
  mkdir -p "$conf"; chmod 700 "$conf"
  python3 - "$conf/session-reporter.json" <<'PY'
import json, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps({"apiKey": "k-rep", "secret": "a" * 64, "organizationId": "o-1", "organizationSlug": "acme",
                         "username": "jane", "machine": "m1"}).encode()); os.close(fd)
PY
  reported="$(fire SessionStart b5g "$BP" 2>&1)$(fire UserPromptSubmit b5g "$BP" "" '{"prompt":"/devstride:build-item"}' 2>&1)"
  pkill -f "presence.py keeper b5g\$" 2>/dev/null; rm -f "$conf/session-reporter.json"
  [ -z "$reported" ] || { echo "with a reporter credential: $reported"; return 1; }
  # a key only one project's entry carries is that project's: there nothing is said, elsewhere the line is
  claudejson "{'projects': {'$(real "$BP")': {'mcpServers': {'devstride': E('k-proj')}}}}"
  local inproj elsewhere
  inproj="$(fire SessionStart b5i "$BP" 2>&1)"; pkill -f "presence.py keeper b5i\$" 2>/dev/null
  elsewhere="$(fire SessionStart b5j "$WORK/out" 2>&1)"; noconfig
  [ -z "$inproj" ] && [ "$elsewhere" = "$START_JSON" ] || { echo "project key: in=$inproj elsewhere=$elsewhere"; return 1; }
}
if WHY="$(line_case)"; then ok "(B5) the no-key notices: never when switched off, null or a repository command; the start line every time; the register steps only for a prompt that starts with /devstride: and a skill other than setup or doctor (never /ds:); a key or a reporter credential silences both; the old marker is removed"
else bad "(B5) $WHY"; fi
for s in a b c d e f g h i j; do pkill -f "$HOOK keeper b5$s\$" 2>/dev/null; done

# (B5b) a session that registers the reporter credential during its own turn shows straight away: its
#       start and prompt came with no key and opened nothing, and its next tool call, once the
#       credential is there, opens the record with a start; with no credential a tool call opens nothing
registered_case() {
  nokey; noconfig
  local conf="$XDG_CONFIG_HOME/devstride-plugin"
  fire SessionStart b5k "$BP" >/dev/null 2>&1
  fire UserPromptSubmit b5k "$BP" "" '{"prompt":"/devstride:build-item"}' >/dev/null 2>&1
  fire PreToolUse b5k "$BP" "" "$(tool Bash t1)" >/dev/null 2>&1
  [ ! -e "$RECORDS/b5k.json" ] || { echo "a session with no key opened a record"; return 1; }
  mkdir -p "$conf"; chmod 700 "$conf"
  python3 - "$conf/session-reporter.json" <<'PY'
import json, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps({"apiKey": "k-rep", "secret": "a" * 64, "organizationId": "o-1", "organizationSlug": "acme",
                         "username": "jane", "machine": "m1"}).encode()); os.close(fd)
PY
  fire PostToolUse b5k "$BP" "" "$(tool Bash t1)" >/dev/null 2>&1
  reach b5k 1 || { echo "no report after the credential appeared"; return 1; }
  [ "$(got b5k 1 event)" = "start" ] || { echo "first report was $(got b5k 1 event)"; return 1; }
  [ "$(rec b5k 'r["state"]')" = "working" ] || { echo "state $(rec b5k 'r["state"]')"; return 1; }
  fire SessionEnd b5l "$BP" "" '{"reason":"other"}' >/dev/null 2>&1
  [ ! -e "$RECORDS/b5l.json" ] || { echo "a session end opened a record"; return 1; }
  # the same with CLAUDE_PID exported, as Claude Code does: the fresh record opens with that owner
  local pid; pid="$(owner)"
  CLAUDE_PID="$pid" fire PostToolUse b5m "$BP" "" "$(tool Bash t1)" >/dev/null 2>&1
  reach b5m 1 || { echo "no report for a session with CLAUDE_PID set"; return 1; }
  [ "$(got b5m 1 event)" = "start" ] && [ "$(rec b5m 'r["owner"]')" = "$pid" ] \
    || { echo "with CLAUDE_PID: first report $(got b5m 1 event), owner $(rec b5m 'r["owner"]')"; return 1; }
}
if WHY="$(registered_case)"; then ok "(B5b) the session that registers the reporter credential shows at its next tool call, with a start, CLAUDE_PID exported or not; nothing opens without it, and an end never opens one"
else bad "(B5b) $WHY"; fi
pkill -f "$HOOK keeper b5k\$" 2>/dev/null; pkill -f "$HOOK keeper b5m\$" 2>/dev/null; rm -f "$XDG_CONFIG_HOME/devstride-plugin/session-reporter.json"

# (B6) quiet: a server with no such tool, or refusing the key → exit 3, nothing more for 30 minutes;
#      a failing or unreachable one → exit 4, 2 minutes; a good answer removes the note; never a word
QS="$(server quiet)"; QURL="http://127.0.0.1:$(cat "$QS/port")"; key
calls() { [ -f "$QS/calls.log" ] && wc -l < "$QS/calls.log" | tr -d ' ' || echo 0; }
lasted() { local i=0; while [ "$(rec "$1" 'r.get("last",{}).get("exit")' 2>/dev/null)" = None ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; }
quiet_case() { # quiet_case SESSION MODE — a start against the server in MODE; prints "<exit> <seconds of quiet, rounded to the minute>"
  printf '%s' "$2" > "$QS/mode"
  # the keeper is stopped at once: its stop check would be one more call at the server
  DEVSTRIDE_PLUGIN_TEST_URL="$QURL" fire SessionStart "$1" "$BP" >> "$WORK/qout" 2>&1 || echo "hook exit for $1" >> "$WORK/qout"; stop_keeper "$1"; lasted "$1"; edit "$1" 'r["owner"] = 0'
  rec "$1" 'str(r["last"]["exit"]) + " " + str(round((r.get("quiet", 0) - r["last"]["at"]) / 60))'
}
: > "$WORK/qout"; A="$(quiet_case b6u unknown-tool)"; C0="$(calls)"
age b6u 61; DEVSTRIDE_PLUGIN_TEST_URL="$QURL" fire UserPromptSubmit b6u "$BP" >> "$WORK/qout" 2>&1 || echo "hook exit" >> "$WORK/qout"; stop_keeper b6u; sleep 0.7; C1="$(calls)"; D1="$(rec b6u 'r["done"]')"
edit b6u 'r["quiet"] = 1'; age b6u 61; DEVSTRIDE_PLUGIN_TEST_URL="$QURL" fire UserPromptSubmit b6u "$BP" >> "$WORK/qout" 2>&1 || echo "hook exit" >> "$WORK/qout"; stop_keeper b6u
i=0; while [ "$(calls)" -lt 2 ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; C2="$(calls)"
B="$(quiet_case b6a http401) $(quiet_case b6b http403)"; C="$(quiet_case b6c http500) $(quiet_case b6d http429) $(quiet_case b6e bad-json)"
CE0="$(calls)"; DEVSTRIDE_PLUGIN_TEST_URL="$QURL" fire SessionEnd b6a "$BP" logout >> "$WORK/qout" 2>&1; sleep 0.7; CE1="$(calls)"   # an end inside the quiet time
printf '' > "$QS/mode"; printf '2' > "$QS/delay"; S="$(DEVSTRIDE_PRESENCE_TIMEOUT=0.5 quiet_case b6s '')"; rm -f "$QS/delay"
DEAD="$(server dead)"; DEADURL="http://127.0.0.1:$(cat "$DEAD/port")"; pkill -f "fake-devstride.py $DEAD\$" 2>/dev/null; sleep 0.2
QURL_KEEP="$QURL"; QURL="$DEADURL"; X="$(quiet_case b6x '')"; QURL="$QURL_KEEP"
printf 'http500' > "$QS/mode"; G0="$(quiet_case b6g http500)"; printf '' > "$QS/mode"
edit b6g 'r["quiet"] = 1'; age b6g 61; DEVSTRIDE_PLUGIN_TEST_URL="$QURL" fire UserPromptSubmit b6g "$BP" >/dev/null 2>&1; reach b6g 1 "$QS"; sleep 0.3
if [ "$A" = "3 30" ] && [ "$C0" = 1 ] && [ "$C1" = 1 ] && [ "$D1" = 2 ] && [ "$C2" = 2 ] && [ "$B" = "3 30 3 30" ] && [ "$C" = "4 2 4 2 4 2" ] \
   && [ "$S" = "4 2" ] && [ "$X" = "4 2" ] && [ "$G0" = "4 2" ] && [ "$(rec b6g '"quiet" in r')" = False ] && [ "$(rec b6g 'r["last"]["exit"]')" = 0 ] && [ "$CE0" = "$CE1" ] && [ ! -s "$WORK/qout" ]; then
  ok "(B6) no such tool, 401, 403 → exit 3 and 30 minutes of quiet (a beat or an end inside it runs nothing; one try after it); 500, 429, a bad answer, a timeout, a refused connection → exit 4 and 2 minutes; a good answer removes the note; the hook prints nothing and exits 0 throughout"
else bad "(B6) a=$A calls=$C0/$C1/$C2 done=$D1 b=$B c=$C s=$S x=$X g=$G0 quiet=$(rec b6g '"quiet" in r') end=$CE0/$CE1 out=$(cat "$WORK/qout")"; fi

# (B7) the keeper under the built-in reporter: it beats at the interval and ends a killed session
#      (reason gone); it leaves when the repository switches reporting off, and when the connection
#      loses its key; a keeper an earlier version started is replaced and the session keeps reporting
key; O7="$(owner)"; K7="$(mkrepo b-keep)"
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O7" fire SessionStart b7 "$K7" >/dev/null 2>&1; reach b7 3; N7="$(got b7 0)"; E7="$(got b7 2 event):$(got b7 3 event)"
kill "$O7" 2>/dev/null; wait "$O7" 2>/dev/null
i=0; while [ "$(got b7 "$(got b7 0)" event)" != end ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; sleep 0.4
LAST7="$(got b7 "$(got b7 0)" event):$(got b7 "$(got b7 0)" endReason)"; keeper_alive b7; GONE7=$?
O7N="$(owner)"; K7N="$(mkrepo b-null)"
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O7N" fire SessionStart b7n "$K7N" >/dev/null 2>&1; reach b7n 1; wait_keeper b7n; UP7N=$?
printf '{"presence":null}' > "$K7N/.claude/ds-config.json"
i=0; while keeper_alive b7n && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; keeper_alive b7n; LEFT7N=$?
nokey; claudejson '{"mcpServers": {"devstride": E("k-keep")}}'; O7K="$(owner)"
DEVSTRIDE_PRESENCE_MINUTE=0.4 CLAUDE_PID="$O7K" fire SessionStart b7k "$BP" >/dev/null 2>&1; reach b7k 1; wait_keeper b7k; UP7K=$?
claudejson '{"mcpServers": {"devstride": {"type": "http", "url": "https://api.devstride.com/mcp"}}}'
i=0; while keeper_alive b7k && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; keeper_alive b7k; LEFT7K=$?
noconfig; key; O7L="$(owner)"
CLAUDE_PID="$O7L" fire SessionStart b7l "$BP" >/dev/null 2>&1; reach b7l 1; stop_keeper b7l; edit b7l 'r.pop("swept", None)'
legacy b7l; CLAUDE_PID="$O7L" fire UserPromptSubmit b7l "$BP" >/dev/null 2>&1; reach b7l 2
i=0; while ! keeper_cmd b7l | grep -qF "$HOOK keeper b7l" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if [ "$N7" -ge 3 ] && [ "$E7" = "beat:beat" ] && [ "$LAST7" = "end:gone" ] && [ "$GONE7" = 1 ] && [ "$UP7N" = 0 ] && [ "$LEFT7N" = 1 ] && [ "$UP7K" = 0 ] && [ "$LEFT7K" = 1 ] \
   && [ "$(got b7l 2 event)" = beat ] && keeper_cmd b7l | grep -qF "$HOOK keeper b7l"; then
  ok "(B7) built-in keeper: beats, then end (gone) for a killed session; leaves when presence becomes null and when the connection loses its key; an earlier version's keeper is replaced and the session reports at once"
else bad "(B7) beats=$N7/$E7 last=$LAST7 gone=$GONE7 null=$UP7N/$LEFT7N key=$UP7K/$LEFT7K legacy=$(got b7l 0) $(keeper_cmd b7l)"; fi
stop_keeper b7l; kill "$O7N" "$O7K" "$O7L" 2>/dev/null

# (B9) a session a repository's own command reports stays with that command when it moves to a place
#      that names none (a key is there, so the built-in reporter could run): the command keeps getting
#      its reports, the server gets none; and a
#      repository whose config file cannot be read switches nothing on
key; : > "$LOG"
fire SessionStart b9 "$R" >/dev/null 2>&1; upto b9 1; stop_keeper b9; edit b9 'r["owner"] = 0'
age b9 61; fire UserPromptSubmit b9 "$BP" >/dev/null 2>&1; upto b9 2
age b9 61; fire UserPromptSubmit b9 "$WORK/out" >/dev/null 2>&1; upto b9 3
fire SessionEnd b9 "$BP" logout >/dev/null 2>&1; upto b9 4
BROKEN="$(mkrepo b-broken '{"presence": null,}')"; fire SessionStart b9x "$BROKEN" >/dev/null 2>&1; sleep 0.4
if [ "$(of b9 0)" = 4 ] && [ "$(of b9 4 PRESENCE_EVENT)" = end ] && [ "$(of b9 3 PRESENCE_CHECKOUT)" = "$(real "$R")" ] \
   && [ "$(got b9 0)" = 0 ] && [ "$(rec b9 'r["mode"]')" = command ] && [ ! -e "$RECORDS/b9x.json" ]; then
  ok "(B9) a session its repository's command reports keeps that command in a place that names none (the built-in reporter never takes it over); an unreadable config file switches nothing on"
else bad "(B9) command got $(of b9 0), server got $(got b9 0), mode=$(rec b9 'r.get("mode")') broken=$(ls "$RECORDS" | grep -c b9x)"; fi
nokey

# (B8) ordering, holds and ownership are the same for a built-in session as for a repository command:
#      cases (3), (4), (16), (20) and (26) once more, against the server
key; BO="$(mkrepo b-order)"
bbegin b8 "$BO"
fire UserPromptSubmit b8 "$BO" >/dev/null 2>&1; sleep 0.5; A="$(got b8 0)"
age b8 61; fire UserPromptSubmit b8 "$BO" >/dev/null 2>&1; reach b8 2                        # (3)
fire Stop b8 "$BO" >/dev/null 2>&1; sleep 0.5; B="$(got b8 0)"                                # (4) held
age b8 31; fire Stop b8 "$BO" >/dev/null 2>&1; reach b8 3; age b8 31; fire Stop b8 "$BO" >/dev/null 2>&1; sleep 0.5
if [ "$A" = 1 ] && [ "$(got b8 2 event):$(got b8 2 state)" = beat:working ] && [ "$B" = 2 ] && [ "$(got b8 0)" = 3 ] \
   && [ "$(got b8 3 event):$(got b8 3 state)" = beat:waiting ] && [ "$(rec b8 'r["mode"]')" = builtin ] && [ "$(rec s1 'r["mode"]')" = command ]; then
  ok "(B8) built-in: a prompt within a minute waits, a minute later beats; a finished turn is held 30 s, then sent once; the record's mode is builtin (command for a repository that names one)"
else bad "(B8) a=$A b=$B n=$(got b8 0) 2=$(got b8 2 event):$(got b8 2 state) 3=$(got b8 3 event):$(got b8 3 state) mode=$(rec b8 'r.get("mode")')/$(rec s1 'r.get("mode")')"; fi
printf '0.4' > "$DS/delay"                                                                    # (16) a slow report
bbegin b816 "$BO"; age b816 31
fire Stop b816 "$BO" >/dev/null 2>&1; fire SessionEnd b816 "$BO" logout >/dev/null 2>&1; sleep 2.5; rm -f "$DS/delay"
ENDS="$(python3 -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l).get("sessionId")=="b816" and json.loads(l)["event"]=="end"))' "$DS/presence.jsonl")"
if [ "$(got b816 "$(got b816 0)" event)" = end ] && [ "$ENDS" = 1 ]; then ok "(B8b) built-in: a beat and an end queued together → end last, once"
else bad "(B8b) n=$(got b816 0) ends=$ENDS"; fi
bbegin b820 "$BO"; ID="$(rec b820 'r["id"]')"; NOW_MS="$(now_ms)"                               # (20)
python3 "$HOOK" send start starting b820 "$ID" 3 "$NOW_MS"; python3 "$HOOK" send end ended b820 "$ID" 2 "$NOW_MS"
python3 "$HOOK" send beat working b820 "$ID" 3 "$NOW_MS"; python3 "$HOOK" send beat working b820 0123456789ab 9 "$NOW_MS"; sleep 0.3
if [ "$(got b820 0)" = 2 ] && [ "$(got b820 2 event)" = start ] && [ "$(rec b820 'r["done"]')" = 3 ]; then
  ok "(B8c) built-in: a report overtaken by a newer one, or queued by a record since replaced, is dropped"
else bad "(B8c) n=$(got b820 0) done=$(rec b820 'r["done"]')"; fi
O826="$(owner)"; CLAUDE_PID="$O826" fire SessionStart b826 "$BO" >/dev/null 2>&1; reach b826 1; stop_keeper b826; age b826 61   # (26)
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(1.5)' "$RECORDS/b826.state.lock" "$WORK/heldb826" &
HOLDER=$!
i=0; while [ ! -e "$WORK/heldb826" ] && [ $i -lt 50 ]; do sleep 0.05; i=$((i + 1)); done
(CLAUDE_PID="$O826" fire UserPromptSubmit b826 "$BO" >/dev/null 2>&1) &
sleep 0.7; Q1="$(rec b826 'r["queued"]')"; wait "$HOLDER"; reach b826 2; Q2="$(rec b826 'r["queued"]')"
if [ "$Q1" = 1 ] && [ "$Q2" = 2 ] && [ "$(got b826 2 event)" = beat ]; then ok "(B8d) built-in: a hook waits for the session's state lock, then its update lands (beat)"
else bad "(B8d) q1=$Q1 q2=$Q2 n=$(got b826 0)"; fi
stop_keeper b826; nokey

# (S1)-(S6) a stop a person asked for on the Agent Fleet: the keeper asks the server for it and keeps
#      what it hears for the stop gate; only a session with no person at it has its process ended.
#      These sessions end with a SessionEnd, and their stand-in processes by their own process ids.
STOPS="$XDG_CACHE_HOME/devstride-plugin/stop"
STOP_ASKED='{"id":"stop-9","by":{"userId":"u-1","name":"Jane Doe"},"at":"2026-11-25T20:14:00.000Z","reason":"Wrong branch","scope":"session"}'
asked() { # asked SESSION STATE-DIR [WHAT] — the stop checks that server got for the session: how many; `gaps:<epoch>` the
  #         seconds between those that came after that time; `heard` how many came after the one that acknowledged a stop (-1: none did)
  python3 -c 'import json,os,sys
p=os.path.join(sys.argv[2],"stop-sync.jsonl"); what=sys.argv[3]
rows=[json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []
rows=[r for r in rows if r.get("sessionId")==sys.argv[1]]
if what=="": print(len(rows))
elif what=="heard":
    at=next((i for i,r in enumerate(rows) if r.get("acknowledged")),None); print(-1 if at is None else len(rows)-at-1)
else:
    times=[r["_at"] for r in rows if r["_at"]>=float(what.partition(":")[2])]
    print(" ".join("%.2f"%(b-a) for a,b in zip(times,times[1:])))' "$1" "$2" "${3:-}"
}
atleast() { # atleast N COMMAND… — until the command prints at least N, at most 20 s
  local want="$1" i=0; shift; while [ "$("$@")" -lt "$want" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i + 1)); done; [ "$("$@")" -ge "$want" ]
}
left() { local i=0; while keeper_alive "$1" && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; ! keeper_alive "$1"; }   # left SESSION — its keeper has gone
during() { # during SESSION DIR OWNER MINUTE URL EVENT [REASON] [VAR=VALUE…] — one hook event of a session that process runs
  local sid="$1" dir="$2" pid="$3" minute="$4" url="$5" event="$6" why="${7:-}"; shift 6; [ $# -gt 0 ] && shift
  ( export DEVSTRIDE_PRESENCE_MINUTE="$minute" DEVSTRIDE_PLUGIN_TEST_URL="$url" CLAUDE_PID="$pid" "$@"; fire "$event" "$sid" "$dir" "$why" >/dev/null 2>&1 )
}
kept_stop() { # kept_stop SESSION — the stop kept for it: "<id> <acknowledged>", `none`, or `unreadable`
  python3 -B -c 'import os,sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
import session_stop
stop = session_stop.read(sys.argv[2])
print("none" if stop is None else "unreadable" if stop.get("unreadable") else "%s %s" % (stop["id"], stop["acknowledged"]))' "$ROOT" "$1"
}
pyowner() { python3 -c 'import time; time.sleep(300)' "$@" >/dev/null 2>&1 & echo "$!" >> "$WORK/owners"; echo "$!"; }   # a stand-in with arguments

# (S1) whether a person is at the session is read when it starts, from what started it
nokey
person() { # person SESSION OWNER [VAR=VALUE…] — a session that process starts with those variables set; prints the record's `unattended`
  local sid="$1" pid="$2"; shift 2
  during "$sid" "$K60" "$pid" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" SessionStart "" "$@"; rec "$sid" 'r.get("unattended")'
  during "$sid" "$K60" "$pid" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" SessionEnd logout; left "$sid"
}
OP1="$(owner)"; OP2="$(pyowner -p 'do the thing')"; OP3="$(pyowner --print 'do the thing')"; OP4="$(pyowner 'explain the -p flag, and --print')"
OP5="$(pyowner -- -p)"; OP6="$(owner)"; sleep 0.5   # each stand-in has become its own program before its arguments are read
P1="$(person sp1 "$OP1" DEVSTRIDE_UNATTENDED=1) $(person sp2 "$OP1" CLAUDE_CODE_ENTRYPOINT=sdk-py) $(person sp3 "$OP2") $(person sp4 "$OP3")"
P2="$(person sp5 "$OP1") $(person sp6 "$OP1" CLAUDE_CODE_ENTRYPOINT=cli DEVSTRIDE_UNATTENDED=yes) $(person sp7 "$OP4") $(person sp8 "$OP5")"
during sp9 "$K60" "$OP1" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" SessionStart "" DEVSTRIDE_UNATTENDED=1
during sp9 "$K60" "$OP1" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" UserPromptSubmit; P3="$(rec sp9 'r.get("unattended")')"          # the same process, later
during sp9 "$K60" "$OP6" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" UserPromptSubmit; P3="$P3 $(rec sp9 'r.get("unattended")')"     # another process took it over
during sp9 "$K60" "$OP6" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" SessionStart resume DEVSTRIDE_UNATTENDED=1; P3="$P3 $(rec sp9 'r.get("unattended")')"
during sp9 "$K60" "$OP6" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" SessionStart compact; P3="$P3 $(rec sp9 'r.get("unattended")')"  # a compaction is not a start
during sp9 "$K60" "$OP6" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" SessionStart resume; P3="$P3 $(rec sp9 'r.get("unattended")')"
during sp9 "$K60" "$OP6" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" SessionEnd logout; left sp9
if [ "$P1" = "True True True True" ] && [ "$P2" = "False False False False" ] && [ "$P3" = "True False True True False" ]; then
  ok "(S1) a session is recorded as unattended at its start when DEVSTRIDE_UNATTENDED=1, the entry point is an SDK's, or its process was given -p or --print; a prompt that mentions -p, one after --, another entry point and a plain start are a person's; the next start reads it again, and another process taking the session over clears it"
else bad "(S1) unattended=$P1 attended=$P2 later=$P3"; fi

# (S2) the keeper asks the server every 15 s while the session starts or works and every 60 s while it
#      waits on its person (a keeper minute is 2 s here: 0.5 s and 2 s), and keeps nothing while no stop is open
key; SK="$(server stops)"; SKURL="http://127.0.0.1:$(cat "$SK/port")"; OS2="$(owner)"; T0="$(python3 -c 'import time; print(time.time())')"
during st2 "$BP" "$OS2" 2 "$SKURL" SessionStart; atleast 3 asked st2 "$SK"; UP2A=$?
during st2 "$BP" "$OS2" 2 "$SKURL" UserPromptSubmit; atleast 6 asked st2 "$SK"; UP2B=$?
during st2 "$BP" "$OS2" 2 "$SKURL" Stop; sleep 0.7; T1="$(python3 -c 'import time; print(time.time())')"; N2="$(asked st2 "$SK")"
atleast $((N2 + 3)) asked st2 "$SK"; UP2C=$?
BUSY2="$(asked st2 "$SK" "gaps:$T0" | cut -d' ' -f1-5)"; IDLE2="$(asked st2 "$SK" "gaps:$T1" | cut -d' ' -f1-2)"; KEPT2="$(kept_stop st2)"
BODY2="$(python3 -c 'import json,sys; print(sorted(set(tuple(sorted(json.loads(l))) for l in open(sys.argv[1]))))' "$SK/stop-sync.jsonl")"
during st2 "$BP" "$OS2" 2 "$SKURL" SessionEnd logout; left st2; GONE2=$?; N2E="$(asked st2 "$SK")"; sleep 1.2
if [ "$UP2A$UP2B$UP2C" = 000 ] && [ "$KEPT2" = none ] && [ "$BODY2" = "[('_at', '_open', 'sessionId')]" ] && [ "$GONE2" = 0 ] && [ "$(asked st2 "$SK")" = "$N2E" ] \
   && python3 -c 'import sys
busy, idle = [float(g) for g in sys.argv[1].split()], [float(g) for g in sys.argv[2].split()]
assert len(busy) == 5 and len(idle) == 2, (busy, idle)
assert all(g >= 0.4 for g in busy) and sorted(busy)[2] < 1.5, busy   # three wakes apart: 0.5 s and the time a check takes
assert all(1.8 <= g < 6 for g in idle), idle                         # twelve wakes apart: 2 s' "$BUSY2" "$IDLE2"; then
  ok "(S2) the keeper asks for a stop every 15 s while the session starts or works and every 60 s while it waits, sending the session's id and nothing else; with no stop open nothing is kept, and an ended session is asked about no more"
else bad "(S2) up=$UP2A$UP2B$UP2C busy=$BUSY2 idle=$IDLE2 kept=$KEPT2 body=$BODY2 gone=$GONE2 after-end=$N2E/$(asked st2 "$SK")"; fi

# (S3) a machine whose connection carries no key asks nothing; a session its repository's own command
#      reports is asked about all the same
nokey; OS3="$(owner)"
during st3n "$K60" "$OS3" 1 "$SKURL" SessionStart; wait_keeper st3n; UP3N=$?; sleep 1.5; N3N="$(asked st3n "$SK")"
during st3n "$K60" "$OS3" 1 "$SKURL" SessionEnd logout; left st3n
key
during st3c "$K60" "$OS3" 1 "$SKURL" SessionStart; atleast 2 asked st3c "$SK"; UP3C=$?; M3C="$(rec st3c 'r["mode"]')"
during st3c "$K60" "$OS3" 1 "$SKURL" SessionEnd logout; left st3c
if [ "$UP3N" = 0 ] && [ "$N3N" = 0 ] && [ "$UP3C" = 0 ] && [ "$M3C" = command ]; then
  ok "(S3) with no key on the machine's DevStride connection the keeper asks for no stop; with one it asks for a session its repository's own command reports too"
else bad "(S3) no-key: keeper=$UP3N asked=$N3N; command: asked=$UP3C mode=$M3C"; fi

# (S4) a server with no such tool, or one that refuses the key, is asked once, then left alone
SQ="$(server stopq)"; SQURL="http://127.0.0.1:$(cat "$SQ/port")"; printf 'unknown-tool' > "$SQ/mode"
stop_calls() { local n; n="$(grep -c '"tool": "sync_session_stop"' "$1/calls.log" 2>/dev/null)"; echo "${n:-0}"; }   # stop_calls STATE-DIR
during st4 "$BP" "$OS3" 1 "$SQURL" SessionStart; atleast 1 stop_calls "$SQ"; UP4=$?; sleep 1.5; N4="$(stop_calls "$SQ")"; KEPT4="$(kept_stop st4)"
during st4 "$BP" "$OS3" 1 "$SQURL" SessionEnd logout; left st4
if [ "$UP4" = 0 ] && [ "$N4" = 1 ] && [ "$KEPT4" = none ]; then
  ok "(S4) a server that has no stop check is asked once and then left alone (six checks' time passed without another); nothing is kept"
else bad "(S4) asked=$UP4 calls=$N4 kept=$KEPT4"; fi

# (S5) a stop is open: an unattended session's process is ended (SIGTERM) and the session ends with the
#      reason `stopped`; a session with a person at it, and one whose process id now belongs to another
#      process, are never signalled: the stop gate refuses their tools, and a record removed by hand comes back
SX="$(server stopx)"; SXURL="http://127.0.0.1:$(cat "$SX/port")"
last() { got "$1" "$(got "$1" 0 "" "$SX")" "$2" "$SX"; }   # last SESSION FIELD — of its newest report at that server
OX2="$(owner)"; OX3="$(owner)"
during su2 "$K60" "$OX2" 1 "$SXURL" SessionStart "" DEVSTRIDE_UNATTENDED=1; atleast 1 asked su2 "$SX"
edit su2 'r["ownerStarted"] -= 1000'                                    # the process id was since reused: another start time
during su3 "$BP" "$OX3" 1 "$SXURL" SessionStart; atleast 1 asked su3 "$SX"; during su3 "$BP" "$OX3" 1 "$SXURL" UserPromptSubmit
printf '%s' "$STOP_ASKED" > "$SX/stop"
python3 -c 'import signal, sys, time   # the unattended session: a stand-in that writes down the signal that ends it
def heard(*_):
    open(sys.argv[1], "w").write("SIGTERM"); sys.exit(0)
signal.signal(signal.SIGTERM, heard); open(sys.argv[1] + ".ready", "w").close(); time.sleep(300)' "$WORK/ox1" >/dev/null 2>&1 &
OX1=$!; i=0; while [ ! -e "$WORK/ox1.ready" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
during su1 "$BP" "$OX1" 1 "$SXURL" SessionStart "" DEVSTRIDE_UNATTENDED=1
i=0; while kill -0 "$OX1" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$OX1" 2>/dev/null; then kill -9 "$OX1"; HOW1=alive; else HOW1="$(cat "$WORK/ox1" 2>/dev/null)"; fi; wait "$OX1" 2>/dev/null
i=0; while [ "$(last su1 event)" != end ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; left su1; GONE1=$?
END1="$(last su1 event):$(last su1 endReason):$(rec su1 'r["state"]'):$(rec su1 'r["reason"]')"; KEPT1="$(kept_stop su1 | cut -d' ' -f1)"
atleast 2 asked su2 "$SX" heard; UP2=$?; atleast 2 asked su3 "$SX" heard; UP3=$?
kill -0 "$OX2" 2>/dev/null; LIVE2=$?; kill -0 "$OX3" 2>/dev/null; LIVE3=$?
STATE23="$(rec su2 'r["state"]'):$(rec su2 'r.get("reason")'):$(kept_stop su2) $(rec su3 'r["state"]'):$(rec su3 'r.get("reason")'):$(kept_stop su3)"
GATE3="$(printf '{"hook_event_name":"PreToolUse","session_id":"su3","tool_name":"Bash"}' | python3 "$ROOT/hooks/stop-gate.py" PreToolUse 2>&1)"
PROMPT3="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"su3","prompt":"go on"}' | python3 "$ROOT/hooks/stop-gate.py" UserPromptSubmit 2>&1)"; RC3=$?
rm -f "$STOPS/su3.json"; i=0; while [ "$(kept_stop su3)" != "stop-9 True" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; BACK3="$(kept_stop su3)"
rm -f "$SX/stop"; i=0; while [ "$(kept_stop su3)" != none ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; OVER3="$(kept_stop su3)"
FREE3="$(printf '{"hook_event_name":"PreToolUse","session_id":"su3","tool_name":"Bash"}' | python3 "$ROOT/hooks/stop-gate.py" PreToolUse 2>&1)$?"
kill -0 "$OX3" 2>/dev/null; LIVE3B=$?
during su2 "$K60" "$OX2" 1 "$SXURL" SessionEnd logout; left su2; during su3 "$BP" "$OX3" 1 "$SXURL" SessionEnd logout; left su3
if [ "$HOW1" = SIGTERM ] && [ "$GONE1" = 0 ] && [ "$END1" = "end:stopped:ended:stopped" ] && [ "$KEPT1" = stop-9 ] \
   && [ "$UP2$UP3" = 00 ] && [ "$LIVE2$LIVE3$LIVE3B" = 000 ] && [ "$STATE23" = "starting:None:stop-9 True working:None:stop-9 True" ] \
   && printf '%s' "$GATE3" | grep -q '"permissionDecision": "deny"' && printf '%s' "$GATE3" | grep -q 'Stopped from DevStride by Jane Doe at ' \
   && [ "$RC3" = 2 ] && printf '%s' "$PROMPT3" | grep -q 'Wrong branch\. This session runs no more tools .* Your prompt was not sent\.$' \
   && [ "$BACK3" = "stop-9 True" ] && [ "$OVER3" = none ] && [ "$FREE3" = 0 ]; then
  ok "(S5) a stop: an unattended session's process is ended with SIGTERM and the session ends with the reason stopped, its keeper gone; a session with a person at it and one whose process id was reused are never signalled, however often the keeper asks; the gate refuses the stopped session's tool and prompt, a record removed by hand comes back, and once the person lets it continue the record goes and the gate passes"
else bad "(S5) unattended: owner=$HOW1 keeper-gone=$GONE1 end=$END1 kept=$KEPT1; others: asked=$UP2$UP3 alive=$LIVE2$LIVE3$LIVE3B state=$STATE23 gate=$GATE3 prompt=$RC3:$PROMPT3 back=$BACK3 over=$OVER3 free=$FREE3"; fi

# (S5b) the unattended session (S5) ended, started again once the person let it continue (the server
#       holds no stop now): no keeper ran while it was ended, so its stop is still kept, and its start
#       asks at once. A keeper minute of 36 s puts the keeper's own first check 3 seconds away, so only
#       the start's check can let the first prompt through, and the server's count is read first
cp "$STOPS/su1.json" "$WORK/su1.stop"   # the kept stop, again for (S5c)
told_over() { # told_over OUTPUT — whether a prompt's output is the one line saying the stop is over
  printf '%s' "$1" | python3 -c 'import json,sys
c = json.loads(sys.stdin.read())["hookSpecificOutput"]
sys.exit(0 if c["hookEventName"] == "UserPromptSubmit" and c["additionalContext"].startswith("The stop from DevStride is over:") else 1)' 2>/dev/null
}
KEPT5B="$(kept_stop su1)"; OX5B="$(owner)"; N5B="$(asked su1 "$SX")"
during su1 "$BP" "$OX5B" 36 "$SXURL" SessionStart resume DEVSTRIDE_UNATTENDED=1; ASKED5B=$(( $(asked su1 "$SX") - N5B ))
PROMPT5B="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"su1","prompt":"go on"}' | python3 "$ROOT/hooks/stop-gate.py" UserPromptSubmit 2>&1)"; RC5B=$?
AFTER5B="$(kept_stop su1):$(rec su1 'r["state"]'):$(rec su1 'r.get("unattended")'):$ASKED5B"
sleep 3.5; kill -0 "$OX5B" 2>/dev/null; LIVE5B=$?   # past the keeper's first check: never signalled
during su1 "$BP" "$OX5B" 36 "$SXURL" SessionEnd logout; stop_keeper su1; kill "$OX5B" 2>/dev/null
if [ "$KEPT5B" = "stop-9 True" ] && [ "$RC5B" = 0 ] && told_over "$PROMPT5B" && [ "$AFTER5B" = "none:starting:True:1" ] && [ "$LIVE5B" = 0 ]; then
  ok "(S5b) a session a stop ended, started again once the person let it continue: its start asks the server at once, so its first prompt goes through, told the stop is over, the kept stop is gone and the new process is never signalled"
else bad "(S5b) kept-before=$KEPT5B prompt=$RC5B:$PROMPT5B after=$AFTER5B alive=$LIVE5B"; fi

# (S5c) the same start while the server takes 5 seconds to answer the stop check: the start goes on after
#       its 3 seconds with the stop still kept, so that run's first prompt is refused and the run ends,
#       and the check it left running still lands, so the next start's first prompt goes through. A
#       keeper minute of 120 s keeps the keeper's own first check 10 seconds away, and the keeper of an
#       ended session never asks, so only the start's check can remove the stop
cp "$WORK/su1.stop" "$STOPS/su1.json"; printf 5 > "$SX/stop-delay"; OX5C="$(owner)"
during su1 "$BP" "$OX5C" 120 "$SXURL" SessionStart resume DEVSTRIDE_UNATTENDED=1; EARLY5C="$(kept_stop su1)"
printf '{"hook_event_name":"UserPromptSubmit","session_id":"su1","prompt":"go on"}' | python3 "$ROOT/hooks/stop-gate.py" UserPromptSubmit >/dev/null 2>&1; RC5C=$?
during su1 "$BP" "$OX5C" 120 "$SXURL" SessionEnd other   # the refused run ends
i=0; while [ "$(kept_stop su1)" != none ] && [ $i -lt 120 ]; do sleep 0.1; i=$((i + 1)); done; LATE5C="$(kept_stop su1)"
rm -f "$SX/stop-delay"; stop_keeper su1; kill "$OX5C" 2>/dev/null
NEXT5C="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"su1","prompt":"go on"}' | python3 "$ROOT/hooks/stop-gate.py" UserPromptSubmit 2>&1)"; RN5C=$?
if [ "$EARLY5C" = "stop-9 True" ] && [ "$RC5C" = 2 ] && [ "$LATE5C" = none ] && [ "$RN5C" = 0 ] && told_over "$NEXT5C"; then
  ok "(S5c) the same start while the server answers slowly: the start goes on after 3 seconds with the stop still kept, so that run's first prompt is refused, and the check it left running lands, so the next start's first prompt goes through, told the stop is over"
else bad "(S5c) early=$EARLY5C prompt=$RC5C late=$LATE5C next=$RN5C:$NEXT5C"; fi

# (S6) the keeper's own clock, wake by wake, with nothing real asked or signalled: when it asks, how long it
#      stays quiet after a refusal, and exactly which session it ends
nokey; OS6="$(owner)"
during st6 "$K60" "$OS6" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" SessionStart; wait_keeper st6
during st6 "$K60" "$OS6" 0.4 "$DEVSTRIDE_PLUGIN_TEST_URL" SessionEnd logout; left st6
if python3 - "$HOOK" st6 "$ROOT" <<'PY'
import importlib.util, os, sys, time as real_time
hook, sid, root = sys.argv[1:4]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("presence_under_test", hook)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import session_stop  # on the path once the hook has loaded
base = m.load(sid)
base.pop("reason", None)
stop = session_stop.stop_of({"id": "stop-6", "by": {"name": "Jane Doe"}, "at": "2026-11-25T20:14:00Z", "reason": "r", "scope": "organization"})


class Clock:
    """The keeper's time module: every sleep is one wake, and nothing really waits."""

    def __init__(self, plan):
        self.wake, self.plan = 0, plan

    def sleep(self, seconds):
        if seconds != m.KEEPER_TICK * m.MINUTE / 60:
            return real_time.sleep(seconds)  # a lock retry, not a wake
        self.wake += 1
        change = self.plan.get(self.wake)
        if change:
            # under the state lock, as every writer of the record: a report this session's own hooks
            # queued may still be writing the record back, and an unlocked change would be lost to it
            with m.state_lock(sid):
                m.save(sid, dict(m.load(sid), **change))
        if self.wake > 2000:
            raise SystemExit("the keeper never left")

    def __getattr__(self, name):
        return getattr(real_time, name)


def run(record, plan, answers=None, kept=None, signal=True):
    """One keeper over `record`: `plan` changes the record before a wake, `answers` are the stop
    checks' exit codes by wake, `kept` the stop record a check leaves. Returns the wakes at which
    it asked, the processes it signalled, the ends it sent and the record it left. `kept` is (the
    wake a check first leaves the stop at, whether it is acknowledged[, the wake a check removes it at])."""
    with m.state_lock(sid):  # as the clock's changes are
        m.save(sid, record)
    session_stop.remove(sid)
    clock, asked, signalled, sent = Clock(plan), [], [], []

    def stop_check(session, peek):
        asked.append(clock.wake)
        if kept and len(kept) > 2 and clock.wake >= kept[2]:
            session_stop.remove(sid)  # a person allowed the session to continue
        elif kept and clock.wake >= kept[0]:
            session_stop.write(sid, stop, kept[1])
        return (answers or {}).get(clock.wake, 0)

    def terminate(pid):
        signalled.append(pid)
        return signal

    m.time, m.stop_check, m.portable.terminate = clock, stop_check, terminate
    m.send = lambda *job: sent.append(job)
    m.keeper(sid)
    return asked, signalled, sent, m.load(sid)


# when it asks: the first wake, then every third while the session starts or works, every twelfth
# while it waits; a refusal (exit 3) quiets it for 360 wakes, half an hour; any other failure is
# asked again at the next turn; an ended session is asked about no more
plan = {11: {"state": "waiting"}, 35: {"state": "starting"}, 404: {"state": "ended"}}
asked, signalled, sent, left = run(dict(base, state="working", unattended=True), plan, answers={37: 3, 397: 4, 400: None})
assert asked == [1, 4, 7, 10, 22, 34, 37, 397, 400, 403], asked
assert signalled == [] and left["state"] == "ended" and session_stop.read(sid) is None, (signalled, left)
assert m.QUIET_REFUSED // m.KEEPER_TICK == 360 and m.STOP_CHECK_TICKS == {"starting": 3, "working": 3, "waiting": 12}

# while this machine keeps a stop, a waiting session is asked about every third wake too, so the
# person's "allow to continue" is heard within 15 seconds; once the record goes, every twelfth again
asked, signalled, sent, left = run(dict(base, state="waiting", unattended=False), {40: {"state": "ended"}}, kept=(1, True, 13))
assert asked == [1, 4, 7, 10, 13, 25, 37] and m.STOP_KEPT_TICKS == 3, asked
assert signalled == [] and session_stop.read(sid) is None, (signalled, left)

# which session it ends: one with no person at it, whose stop the server knows this machine heard,
# and whose process still has the start time the record names
mine = dict(base, state="working", unattended=True)
owner, begun = mine["owner"], mine["ownerStarted"]
assert owner > 1 and begun > 0 and m.confirmed(mine), mine
for unknown in ({"owner": 0}, {"owner": 1}, {"owner": True}, {"owner": None}, {"ownerStarted": None}, {"ownerStarted": True},
                {"ownerStarted": begun + m.STARTED_SLACK + 1}, {"ownerStarted": begun - m.STARTED_SLACK - 1}):
    assert not m.confirmed(dict(mine, **unknown)), unknown
end = {8: {"state": "ended"}}
for label, record, kept in (
        ("a stop not yet acknowledged", mine, (1, False)),
        ("a person at the session", dict(mine, unattended=False), (1, True)),
        ("nothing recorded about a person", {k: v for k, v in mine.items() if k != "unattended"}, (1, True)),
        ("another start time", dict(mine, ownerStarted=begun - 1000), (1, True)),
        ("no start time known", dict(mine, ownerStarted=0), (1, True)),
        ("no stop at all", mine, None)):
    asked, signalled, sent, left = run(record, end, kept=kept)
    assert signalled == [] and [job for job in sent if job[0] == "end"] == [] and left.get("reason") != "stopped", (label, signalled, sent, left)
    assert asked == [1, 4, 7], (label, asked)
asked, signalled, sent, left = run(mine, end, kept=(4, True))
assert asked == [1, 4] and signalled == [owner], (asked, signalled)
assert left["state"] == "ended" and left["reason"] == "stopped" and left["owner"] == owner, left
assert len(sent) == 1 and sent[0][:4] == ("end", "ended", sid, left["id"]) and sent[0][4] == left["queued"], (sent, left)
assert not m.keeper_running(sid), "the keeper left its lock"
asked, signalled, sent, left = run(mine, end, kept=(1, True), signal=False)   # the request to end could not be made
assert signalled == [owner, owner, owner] and left.get("reason") != "stopped" and [job for job in sent if job[0] == "end"] == [], (signalled, left, sent)
# a process whose start time cannot be read just now confirms nothing
real_started, m.started = m.started, lambda pid: 0
assert not m.confirmed(mine)
asked, signalled, sent, left = run(mine, end, kept=(1, True))
assert signalled == [] and left.get("reason") != "stopped", (signalled, left)
m.started = real_started
# the process changed between the keeper's look and its taking the session's lock
m.save(sid, dict(mine, owner=owner + 1))
with m.state_lock(sid):
    assert m.end_stopped(sid, mine) is None
m.save(sid, dict(mine, state="ended", reason="logout"))
with m.state_lock(sid):
    assert m.end_stopped(sid, mine) is None and m.load(sid)["reason"] == "logout"
session_stop.remove(sid)
PY
then ok "(S6) wake by wake: the keeper asks at its first wake, every third wake while the session starts or works and every twelfth while it waits (every third while a stop is kept); a refusal quiets it for half an hour, another failure is asked again; it ends only an unattended session whose stop was acknowledged and whose process has the recorded start time, sends its end once, and leaves"
else bad "(S6) the keeper's stop checks, wake by wake"; fi
kill "$OX2" "$OX3" "$OS2" "$OS3" "$OS6" "$OP1" "$OP2" "$OP3" "$OP4" "$OP5" "$OP6" 2>/dev/null
nokey

# (B10) nothing the hook wrote (a session's record, a lock, the no-key marker) holds a key or a secret
if [ -n "$(ls "$RECORDS")" ] && ! grep -rqF -e test-key -e test-secret -e k-env -e k-user -e k-proj -e k-main -e k-dir -e k-lower -e k-keep "$WORK/cache" "$WORK/cache-line" 2>/dev/null; then
  ok "(B10) no record, lock or marker the hook wrote holds a key or a secret, wherever the key came from"
else bad "(B10) a key or secret in: $(grep -rlF -e test-key -e test-secret -e k-env -e k-user -e k-proj -e k-main -e k-dir -e k-lower -e k-keep "$WORK/cache" "$WORK/cache-line" 2>/dev/null | head -3)"; fi

# (12) hooks.json registers the hook on all ten events, bounded and failing open; Notification only for
#      the six prompt types the hook reads, and PreToolUse after the stop gate and the model recorder
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
assert "stop-gate.py\" PreToolUse" in pre[0] and "session-runtime.py\" seen" in pre[1] and "presence.py\" hook" in pre[2], pre
PY
then ok "(12) hooks.json → presence hook on ten events (timeout 5, exit 0); Notification for the six prompt types only"
else bad "(12) hooks.json registration"; fi

exit $FAIL
