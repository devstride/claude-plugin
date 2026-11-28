#!/bin/bash
# Deterministic tests for hooks/run-watch.py — a workflow run is driven only where its step agents
# can be heard, and a turn that ends while a run has a step nothing is running is held once. The
# runs are real ones, made through the step runner with the fixtures' claim-only definition (and a
# one-step copy of it whose step can stop to ask the person), in a private cache; no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$ROOT/hooks/run-watch.py"
RUNNER="$ROOT/skills/run-workflow/scripts/workflow.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export XDG_CACHE_HOME="$WORK/cache" HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" PYTHONDONTWRITEBYTECODE=1
export DEVSTRIDE_PLUGIN_TEST_URL="http://127.0.0.1:9"   # the runner's history goes nowhere
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CLAUDE_PID DEVSTRIDE_API_KEY DEVSTRIDE_API_SECRET DEVSTRIDE_ORG_ID DEVSTRIDE_BASE_URL
mkdir -p "$HOME" "$WORK/plain"
MARKS="$XDG_CACHE_HOME/devstride-plugin/run-watch"

wf() { # wf COMMAND JSON — one runner command; prints its answer
  printf '%s' "$2" | python3 -B "$RUNNER" "$1"
}
start() { # start SESSION ITEM [ask] — a claim-only run (or the asking copy) in SESSION for ITEM, bound to $START_CWD (default the plain folder); prints its run id
  python3 - "$ROOT" "${START_CWD:-$WORK/plain}" "$1" "$2" "${3:-}" <<'PY' | python3 -B "$RUNNER" start | python3 -c 'import json,sys; print(json.load(sys.stdin)["runId"])'
import copy, json, sys
root, cwd, session, item, ask = sys.argv[1:]
fixtures = json.load(open(root + "/skills/run-workflow/scripts/workflow-fixtures.json"))
definition = copy.deepcopy(fixtures["definitions"]["claim-only"])
context = dict(fixtures["context"], cwd=cwd, item=item)
if ask:
    step = definition["phases"][0]["steps"][0]
    step.update(id="preflight", contract="hotfix-preflight@1")
    step["run"]["ref"] = "hotfix-steps"
    definition["id"] = "ask-only"
    context["branchArgument"] = "x"
print(json.dumps({"definition": definition, "context": context, "session": session}))
PY
}
pre() { # pre JSON-MEMBERS — the PreToolUse mode; OUT its stdout, RC its exit code
  OUT="$(printf '{"hook_event_name":"PreToolUse","session_id":"p1","cwd":"%s"%s}' "$WORK" "$1" | python3 "$HOOK" pre 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
stop() { # stop SESSION [JSON-MEMBERS] — the Stop mode (cwd $STOP_CWD, default the plain folder), with an empty background_tasks unless the members name one; OUT its stdout, RC its exit code
  local members="${2:-}"; case "$members" in *'"background_tasks"'*) ;; *) members="$members,\"background_tasks\":[]" ;; esac
  OUT="$(printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s","stop_hook_active":false%s}' "$1" "${STOP_CWD:-$WORK/plain}" "$members" | python3 "$HOOK" stop 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
denies() { # denies TEXT — OUT is exactly one PreToolUse refusal whose reason holds TEXT
  printf '%s' "$OUT" | python3 -c 'import json,sys
got = json.loads(sys.stdin.read()); out = got["hookSpecificOutput"]
sys.exit(0 if set(got) == {"hookSpecificOutput"} and set(out) == {"hookEventName", "permissionDecision", "permissionDecisionReason"}
         and out["hookEventName"] == "PreToolUse" and out["permissionDecision"] == "deny" and sys.argv[1] in out["permissionDecisionReason"] else 1)' "$1" 2>/dev/null
}
before() { # before FIRST SECOND — OUT's reason holds FIRST, and holds it ahead of SECOND
  printf '%s' "$OUT" | python3 -c 'import json,sys
r = json.loads(sys.stdin.read())["reason"]; a, b = sys.argv[1:]
sys.exit(0 if a in r and b in r and r.index(a) < r.index(b) else 1)' "$1" "$2" 2>/dev/null
}
holds() { # holds TEXT... — OUT is exactly one block whose reason holds every TEXT
  printf '%s' "$OUT" | python3 -c 'import json,sys
got = json.loads(sys.stdin.read())
sys.exit(0 if set(got) == {"decision", "reason"} and got["decision"] == "block" and all(t in got["reason"] for t in sys.argv[1:]) else 1)' "$@" 2>/dev/null
}
TASK() { # TASK TYPE [STATUS] [COMMAND] — one background_tasks entry
  printf '{"id":"t%s","type":"%s","status":"%s","description":"d"%s}' "$RANDOM" "$1" "${2:-running}" "${3:+,\"command\":\"$3\"}"
}

# (1) a run-driving skill inside an agent is refused: each of the five, with or without one leading /
D=""
for name in devstride:release devstride:plan devstride:run-workflow devstride:branch-hotfix devstride:rebalance /devstride:release; do
  pre ',"tool_name":"Skill","agent_id":"a1","agent_type":"general-purpose","tool_input":{"skill":"'"$name"'","args":"x"}'
  denies "runs only in the session's main conversation, never inside an agent" && denies "${name#/}" && [ "$RC:$ERR" = "0:" ] || D="$D $name"
done
pre ',"tool_name":"Skill","agent_id":"a1","tool_input":{"skill":"devstride:release"}'
denies "release it now (the release_claim tool"; CLAIM=$?
if [ -z "$D" ] && [ "$CLAIM" = 0 ]; then
  ok "(1) a helper agent is refused release, plan, run-workflow, branch-hotfix and rebalance (one leading / allowed), told to hand back and to release a train claim it took, exit 0"
else bad "(1) not refused:$D claim=$CLAIM out=$OUT"; fi

# (2) the near misses stay silent
N=""
for members in ',"tool_name":"Skill","agent_id":"a1","tool_input":{"skill":"release"}' \
               ',"tool_name":"Skill","agent_id":"a1","tool_input":{"skill":"devstride:review"}' \
               ',"tool_name":"Skill","agent_id":"a1","tool_input":{"skill":"//devstride:release"}' \
               ',"tool_name":"Skill","agent_id":"a1","tool_input":{"skill":"devstride:release-steps"}' \
               ',"tool_name":"Skill","tool_input":{"skill":"devstride:release"}' \
               ',"tool_name":"Skill","agent_id":"","tool_input":{"skill":"devstride:plan"}' \
               ',"tool_name":"Agent","tool_input":{"subagent_type":"devstride:workflow-steps","prompt":"run: x"}' \
               ',"tool_name":"Agent","tool_input":{"subagent_type":"devstride:workflow-steps","run_in_background":false}' \
               ',"tool_name":"Agent","tool_input":{"subagent_type":"devstride:workflow-steps","run_in_background":"true"}' \
               ',"tool_name":"Agent","tool_input":{"subagent_type":"Explore","run_in_background":true}' \
               ',"tool_name":"Agent","tool_input":{"subagent_type":"workflow-steps","run_in_background":true}' \
               ',"tool_name":"Bash","agent_id":"a1","tool_input":{"command":"echo devstride:release","run_in_background":true}' \
               ',"tool_name":"Skill","agent_id":"a1","tool_input":"devstride:release"'; do
  pre "$members"; [ "$RC:$OUT:$ERR" = "0::" ] || N="$N [$members -> $RC:$OUT]"
done
if [ -z "$N" ]; then
  ok "(2) silent: a bare or doubly slashed name, another devstride skill, the main conversation, a foreground step agent, a background agent of another type, another tool, a tool input that is not an object"
else bad "(2)$N"; fi

# (3) a step agent started in the background is refused, from the main conversation or from an agent
B=""
for members in ',"tool_name":"Agent","tool_input":{"subagent_type":"devstride:workflow-steps","run_in_background":true}' \
               ',"tool_name":"Agent","agent_id":"a1","tool_input":{"subagent_type":"devstride:workflow-judgement","run_in_background":true}' \
               ',"tool_name":"Task","tool_input":{"subagent_type":"devstride:workflow-steps","run_in_background":true}'; do
  pre "$members"; denies "Start it again with run_in_background false" && [ "$RC" = 0 ] || B="$B [$members -> $OUT]"
done
if [ -z "$B" ]; then ok "(3) devstride:workflow-steps or workflow-judgement with run_in_background true is refused, main conversation or agent, under Agent or its older name Task, and told to pass run_in_background false"
else bad "(3)$B"; fi

# (4) Stop: an issued step nothing runs is held once; the same again is silent; a new attempt is held again
R1="$(start s1 I123)"
stop s1 ',"stop_hook_active":true'; A="$RC:$OUT"
stop s1 ',"agent_id":"a1"'; Bq="$RC:$OUT"
stop s1 ",\"background_tasks\":[$(TASK subagent),$(TASK shell running 'npm test')]"; C="$RC:$OUT"
stop s1 ",\"background_tasks\":[$(TASK workflow pending)]"; Cw="$RC:$OUT"
stop s1 ",\"background_tasks\":[$(TASK 'cloud session')]"; Cc="$RC:$OUT"
stop s1 ",\"background_tasks\":[$(TASK code)]"; Cs="$RC:$OUT"
stop s1 ",\"background_tasks\":[$(TASK local_script pending)]"; Cl="$RC:$OUT"
stop s1 ",\"background_tasks\":[$(TASK subagent completed)]"; holds "$R1"; Cdone=$?
rm -f "$MARKS/s1.json"
OUT="$(printf '{"hook_event_name":"Stop","session_id":"s1","cwd":"%s"}' "$WORK/plain" | python3 "$HOOK" stop 2>&1)"; Nk="$?:$OUT"
stop s1 ',"background_tasks":{"t1":"running"}'; Nl="$RC:$OUT"
stop s1; holds "No agent, workflow or script of this session is running now" \
  "Claim only, run $R1 for I123: step claim (1 of 1, attempt 1) was handed out and nothing is running it." "status with all, then next" \
  "tell the person in one line that it had stopped" "Never start a step a second time" "This hold is never a yes"; H1="$?:$RC"
before "if the person asked this conversation to pause, stop or leave that run" "Otherwise drive it now, here"; H1="$H1:$?"
stop s1; E="$RC:$OUT"
wf done '{"item":"I123","session":"s1","stepId":"claim","attempt":1,"output":"nonsense\n"}' >/dev/null   # stops: no verdict
stop s1; NV="$RC:$OUT"
wf resume '{"item":"I123","session":"s1"}' >/dev/null                                                  # attempt 2
stop s1; holds "step claim (1 of 1, attempt 2)"; H2="$?:$RC"
if [ "$A" = "0:" ] && [ "$Bq" = "0:" ] && [ "$C" = "0:" ] && [ "$Cw" = "0:" ] && [ "$Cc" = "0:" ] && [ "$Cs:$Cl" = "0::0:" ] && [ "$Cdone" = 0 ] \
   && [ "$Nk" = "0:" ] && [ "$Nl" = "0:" ] && [ "$H1" = "0:0:0" ] && [ "$E" = "0:" ] && [ "$NV" = "0:" ] && [ "$H2" = "0:0" ]; then
  ok "(4) an issued step with nothing running is held once (named with its workflow, run, step, N of M and attempt; ending the turn again when the person paused or left the run comes before driving it) and silent the second time; a run stopped on a failure is not; a new attempt is held again; silent for stop_hook_active, a helper agent, a running or pending subagent, workflow, script (code, or local_script) or cloud session; a finished subagent does not count; a payload with no background_tasks list is silent (the host cannot say what runs)"
else bad "(4) active=$A agent=$Bq sub=$C wf=$Cw cloud=$Cc script=$Cs/$Cl done=$Cdone nokey=$Nk notlist=$Nl h1=$H1 again=$E noverdict=$NV h2=$H2 out=$OUT"; fi

# (5) only a shell running: held, naming the shell command and wait; an unknown task type: held
wf done '{"item":"I123","session":"s1","stepId":"claim","attempt":2,"output":"nonsense\n"}' >/dev/null
wf resume '{"item":"I123","session":"s1"}' >/dev/null                                                  # attempt 3
stop s1 ",\"background_tasks\":[$(TASK shell running 'pnpm test --run')]"
holds "attempt 3" "These background tasks still run: shell command \`pnpm test --run\`" "report wait for the step" "end the turn instead"; S="$?:$RC"
wf done '{"item":"I123","session":"s1","stepId":"claim","attempt":3,"output":"nonsense\n"}' >/dev/null
wf resume '{"item":"I123","session":"s1"}' >/dev/null                                                  # attempt 4
stop s1 ",\"background_tasks\":[$(TASK dream),$(TASK teammate)]"; holds "attempt 4" "These background tasks still run: dream \`d\`."; U="$?:$RC"
printf '%s' "$OUT" | grep -q 'teammate'; U="$U:$?"
if [ "$S" = "0:0" ] && [ "$U" = "0:0:1" ]; then
  ok "(5) only a shell running → held, naming the shell command and saying to report wait for its step and end the turn; an unknown type or a teammate → held, naming the unknown type and never the teammate"
else bad "(5) shell=$S unknown=$U out=$OUT"; fi

# (6) a waiting step: silent while anything runs; held once nothing does
R2="$(start s2 I200)"
wf wait '{"item":"I200","session":"s2","stepId":"claim","attempt":1,"reason":"Waiting on the test suite"}' >/dev/null
stop s2 ",\"background_tasks\":[$(TASK shell running 'npm test')]"; W1="$RC:$OUT"
stop s2; holds "run $R2 for I200: step claim (1 of 1, attempt 1) reported it is waiting (Waiting on the test suite), and nothing of this session runs now"; W2="$?:$RC"
before "its step waits on the person's answer to a question already shown to them, end the turn again" "Otherwise drive it now"; W2="$W2:$?"
before "A wait on anything else (a deploy, a test run, a review) is no reason to end the turn once nothing runs it: read that work's own result (the exit status and output of the background task that ran it, or the deploy or review by its own id; the run's status keeps only the wait's reason)" "Otherwise drive it now"; W2="$W2:$?"
printf '%s' "$OUT" | grep -q 'evidence true'; W2="$W2:$?"
printf '%s' "$OUT" | grep -q -e 'has ended' -e 'already told'; W2="$W2:$?"
stop s2; W3="$RC:$OUT"
R2T="$(start s2t I201)"
wf wait '{"item":"I201","session":"s2t","stepId":"claim","attempt":1,"reason":"Waiting on the build"}' >/dev/null
stop s2t ",\"background_tasks\":[$(TASK teammate)]"; holds "run $R2T for I201: step claim (1 of 1, attempt 1) reported it is waiting"; W4="$?:$RC"
if [ "$W1" = "0:" ] && [ "$W2" = "0:0:0:0:1:1" ] && [ "$W3" = "0:" ] && [ "$W4" = "0:0" ]; then
  ok "(6) a step that reported wait → silent while a shell of the session runs, held once when nothing runs, leading with ending the turn again only when it waits on the person's answer to a question already shown (any other wait has its result read from the work itself, never from the run's status, and is carried on, never ended on because the person was told of it) and never claiming its reporter ended (a teammate, whose entry reads running all session, does not count), then silent"
else bad "(6) shell=$W1 held=$W2 again=$W3 teammate=$W4"; fi

# (7) a run stopped on a question for the person: held once; a finished run and another session's run: silent
R3="$(start s3 I300 ask)"
wf done '{"item":"I300","session":"s3","stepId":"preflight","attempt":1,"output":"HOTFIX PREFLIGHT: DIRTY\n"}' >/dev/null
stop s3; holds "run $R3 for I300: stopped at step preflight (1 of 1, attempt 1) for the person's answer" "show it now; otherwise end the turn"; Q1="$?:$RC"
stop s3; Q2="$RC:$OUT"
start s4 I400 >/dev/null
wf done '{"item":"I400","session":"s4","stepId":"claim","attempt":1,"output":"CLAIM: WON\nclaimed\n```json\n{\"state\":\"won\"}\n```\n"}' >/dev/null
stop s4; F="$RC:$OUT"
stop s5; O="$RC:$OUT"
if [ "$Q1" = "0:0" ] && [ "$Q2" = "0:" ] && [ "$F" = "0:" ] && [ "$O" = "0:" ]; then
  ok "(7) a run stopped for the person's answer is held once to make sure its question is shown; a finished run, and a session with no runs while others have some, are silent"
else bad "(7) question=$Q1 again=$Q2 finished=$F other=$O out=$OUT"; fi

# (8) a stop a person placed on the Agent Fleet silences it
start s6 I600 >/dev/null
python3 - "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "skills/build-item/scripts"))
import session_stop
session_stop.write("s6", session_stop.stop_of({"id": "stop-1", "by": {"name": "Jane"}, "at": "2026-11-25T20:14:00Z", "reason": "r", "scope": "session"}))
PY
stop s6; K1="$RC:$OUT"
rm -f "$XDG_CACHE_HOME/devstride-plugin/stop/s6.json"
stop s6; holds "Claim only"; K2="$?:$RC"
if [ "$K1" = "0:" ] && [ "$K2" = "0:0" ]; then ok "(8) a stop kept for the session on this machine → silent; once it is gone the same run is held"
else bad "(8) stopped=$K1 after=$K2"; fi

# (9) no runner, a runner that fails or answers something unreadable, a payload that cannot be read: silent
start s7 I700 >/dev/null
fake() { # fake NAME [RUNNER-BODY] — a copy of the hook in a plugin of its own, with that runner or none
  mkdir -p "$WORK/$1/hooks" "$WORK/$1/skills/build-item/scripts"
  cp "$HOOK" "$WORK/$1/hooks/"; cp "$ROOT/skills/build-item/scripts/session_stop.py" "$ROOT/skills/build-item/scripts/portable.py" "$WORK/$1/skills/build-item/scripts/"
  if [ -n "${2:-}" ]; then mkdir -p "$WORK/$1/skills/run-workflow/scripts"; printf '%s\n' "$2" > "$WORK/$1/skills/run-workflow/scripts/workflow.py"; fi
}
# a runner whose answer alone would hold a run: so only its exit code or its lateness keeps the hook silent
LISTING='import json, sys
req = json.load(sys.stdin)
print(json.dumps({"runs": [{"runId": "r-fake", "state": "running", "workflow": "Fake", "position": {"stepId": "s", "index": 1, "of": 1}}]}
                 if req.get("all") else {"rows": [{"stepId": "s", "attempt": 1}]}), flush=True)'
fake none; fake garbage 'print("not json")'; fake good "$LISTING"; fake fails "$LISTING
sys.exit(2)"; fake slow "import time; time.sleep(10)
$LISTING"
OUT="$(printf '{"hook_event_name":"Stop","session_id":"s7ok","cwd":"%s","background_tasks":[]}' "$WORK/plain" | python3 "$WORK/good/hooks/run-watch.py" stop 2>&1)"
holds "Fake, run r-fake: step s (1 of 1, attempt 1)"; GOOD=$?
M=""; SLOW=""
for name in none garbage fails slow; do
  BEGAN=$SECONDS
  M="$M$(printf '{"hook_event_name":"Stop","session_id":"s7","cwd":"%s","background_tasks":[]}' "$WORK/plain" | python3 "$WORK/$name/hooks/run-watch.py" stop 2>&1)$?|"
  [ "$name" = slow ] && SLOW=$((SECONDS - BEGAN))
done
M="$M$(printf 'not json' | python3 "$HOOK" stop 2>&1)$?|$(python3 "$HOOK" stop </dev/null 2>&1)$?|$(printf '[]' | python3 "$HOOK" pre 2>&1)$?|"
M="$M$(printf '{"session_id":"../s7","cwd":"%s","background_tasks":[]}' "$WORK/plain" | python3 "$WORK/good/hooks/run-watch.py" stop 2>&1)$?|$(printf '{"session_id":"s7"}' | python3 "$HOOK" 2>&1)$?"
if [ "$GOOD" = 0 ] && [ "$M" = "0|0|0|0|0|0|0|0|0" ] && [ ! -e "$XDG_CACHE_HOME/devstride-plugin/s7.json" ] && [ "$SLOW" -le 5 ] && [ ! -e "$MARKS/s7.json" ]; then
  ok "(9) a runner whose listing holds a run → held; the same listing with exit 2, or after more than three seconds (given up within five), → silent; no runner, one that prints no JSON, a payload that is not JSON or an object, a session id that is not one (with that same holding runner), no mode → silent, exit 0, nothing recorded"
else bad "(9) good=$GOOD slow=${SLOW}s $M"; fi

# (10) two runs: one block naming both; the record is owner-only, in an owner-only folder
R8A="$(start s8 I801)"; R8B="$(start s8 I802)"
stop s8; holds "run $R8A for I801: step claim" "run $R8B for I802: step claim"; T="$?:$RC:$(printf '%s' "$OUT" | grep -o '"decision"' | wc -l | tr -d ' ')"
P="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777), oct(os.stat(sys.argv[2]).st_mode & 0o777))' "$MARKS/s8.json" "$MARKS")"
LEFT="$(ls -A "$MARKS" | grep -c '^\.')"
if [ "$T" = "0:0:1" ] && [ "$P" = "0o600 0o700" ] && [ "$LEFT" = 0 ]; then
  ok "(10) two runs with steps nothing runs → one block naming both; the record is 0600 in a 0700 folder, and no temporary file is left"
else bad "(10) t=$T perms=$P left=$LEFT out=$OUT"; fi

# (10b) a run bound to another checkout is named with it and never driven from here; one bound to this checkout is not
mkdir -p "$WORK/other"; OTHER="$(cd "$WORK/other" && pwd -P)"   # the runner keeps the folder's real path
R9A="$(START_CWD="$WORK/other" start s9 I901)"; R9B="$(start s9 I902)"
stop s9; holds "run $R9A for I901 (checkout $OTHER, not this one): step claim" "run $R9B for I902: step claim" \
  "A run bound to another checkout is never driven from here"; X="$?:$RC"
printf '%s' "$OUT" | grep -q "checkout $(cd "$WORK/plain" && pwd -P)"; X="$X:$?"; O9="$OUT"
R10="$(start s10 I910)"; stop s10; printf '%s' "$OUT" | grep -q 'another checkout'; X="$X:$?"
if [ "$X" = "0:0:1:1" ]; then
  ok "(10b) a run bound to another checkout is held naming that checkout and saying it is never driven from here; a run bound to this one is held as before"
else bad "(10b) $X out=$O9"; fi

# (10c) checkouts are compared, not folders: a run started at a checkout's top is this session's own
# while the session sits in a subfolder of it (and the other way round); a second checkout is another
mkdir -p "$WORK/repo/backend" "$WORK/repo2"; git init -q "$WORK/repo"; git init -q "$WORK/repo2"
REPO="$(cd "$WORK/repo" && pwd -P)"
R11A="$(START_CWD="$WORK/repo" start s11 I911)"
STOP_CWD="$WORK/repo/backend" stop s11; holds "run $R11A for I911: step claim"; Y="$?:$RC"
printf '%s' "$OUT" | grep -q -e 'another checkout' -e 'not this one'; Y="$Y:$?"
R12A="$(START_CWD="$WORK/repo/backend" start s12 I912)"
STOP_CWD="$WORK/repo" stop s12; holds "run $R12A for I912: step claim"; Y="$Y:$?"
printf '%s' "$OUT" | grep -q -e 'another checkout' -e 'not this one'; Y="$Y:$?"
R13A="$(START_CWD="$WORK/repo" start s13 I913)"
STOP_CWD="$WORK/repo2" stop s13; holds "run $R13A for I913 (checkout $REPO, not this one): step claim" "A run bound to another checkout is never driven from here"; Y="$Y:$?"
R14A="$(START_CWD="$WORK/repo" start s14 I914)"
stop s14; holds "run $R14A for I914: step claim"; Y="$Y:$?"
printf '%s' "$OUT" | grep -q 'another checkout'; Y="$Y:$?"
mkdir -p "$WORK/repo/nest/gone"; git init -q "$WORK/repo/nest/gone"; GONE="$REPO/nest/gone"
R15A="$(START_CWD="$WORK/repo/nest/gone" start s15 I915)"
STOP_CWD="$WORK/repo" stop s15; holds "run $R15A for I915 (checkout $GONE, not this one): step claim"; Y="$Y:$?"
rm -rf "$WORK/repo/nest/gone"; rm -f "$MARKS/s15.json"
STOP_CWD="$WORK/repo" stop s15; holds "run $R15A for I915 (checkout $GONE, which no longer exists): step claim" "A run bound to another checkout is never driven from here"; Y="$Y:$?"
if [ "$Y" = "0:0:1:0:1:0:0:1:0:0" ]; then
  ok "(10c) a run started at a checkout's top, with the session in a subfolder of it (or started in a subfolder, with the session at the top), is held as this checkout's own; one in a second checkout is named as another; one in a checkout, with the session outside any, is never called another; one whose nested checkout was removed is named as another that no longer exists, never as the enclosing checkout's own"
else bad "(10c) $Y out=$OUT"; fi

# (11) a record that is damaged is written whole again; one that is a link is never followed, and nothing is held
printf 'not json' > "$MARKS/s8.json"
stop s8; holds "run $R8A"; G1="$?"
stop s8; G2="$RC:$OUT"
printf '{"held":[]}' > "$WORK/planted.json"; rm -f "$MARKS/s1.json"; ln -s "$WORK/planted.json" "$MARKS/s1.json"
stop s1; G3="$RC:$OUT:$(cat "$WORK/planted.json")"
if [ "$G1" = 0 ] && [ "$G2" = "0:" ] && [ "$G3" = '0::{"held":[]}' ]; then
  ok "(11) a damaged record → held and written whole again, then silent; a link in its place → silent, its target untouched"
else bad "(11) damaged=$G1 again=$G2 link=$G3"; fi

# (12) hooks.json: pre on Skill, Agent and Task after the stop gate's group; stop after presence on Stop; both bounded, failing open
CMDS="$(python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
pre = hooks["PreToolUse"]
assert "matcher" not in pre[0] and "stop-gate.py" in pre[0]["hooks"][0]["command"], pre[0]
mine = [(g, h) for g in pre for h in g["hooks"] if "run-watch.py" in h["command"]]
assert len(mine) == 1 and mine[0][0].get("matcher") == "Skill|Agent|Task" and len(mine[0][0]["hooks"]) == 1, mine
stop = [h["command"] for g in hooks["Stop"] for h in g["hooks"]]
assert len(hooks["Stop"]) == 1 and "matcher" not in hooks["Stop"][0], hooks["Stop"]
assert "presence.py\" hook" in stop[0] and stop[1].endswith("run-watch.py\" stop; exit 0") and len(stop) == 2, stop
others = [e for e in hooks if e not in ("PreToolUse", "Stop") for g in hooks[e] for h in g["hooks"] if "run-watch.py" in h["command"]]
assert not others, others
for group, hook in mine + [(hooks["Stop"][0], hooks["Stop"][0]["hooks"][1])]:
    assert hook.get("timeout") == 5 and hook.get("type") == "command", hook
assert mine[0][1]["command"] == '. "${CLAUDE_PLUGIN_ROOT}/hooks/python.sh" && "$DEVSTRIDE_PY" "${CLAUDE_PLUGIN_ROOT}/hooks/run-watch.py" pre; exit 0'
print(mine[0][1]["command"]); print(stop[1])
PY
)"; WIRED=$?
PRE_CMD="$(printf '%s\n' "$CMDS" | sed -n 1p)"; STOP_CMD="$(printf '%s\n' "$CMDS" | sed -n 2p)"
mkdir -p "$WORK/nobin"; R12="$(start s12 I120)"
A="$(printf '{"tool_name":"Skill","agent_id":"a","tool_input":{"skill":"devstride:release"}}' | env -i PATH="$WORK/nobin" CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$PRE_CMD" 2>&1)"; RA=$?
Bn="$(printf '{"session_id":"s12","cwd":"%s","background_tasks":[]}' "$WORK/plain" | env -i PATH="$WORK/nobin" XDG_CACHE_HOME="$XDG_CACHE_HOME" CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$STOP_CMD" 2>&1)"; RB=$?
OUT="$(printf '{"tool_name":"Skill","agent_id":"a","tool_input":{"skill":"devstride:release"}}' | CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$PRE_CMD" 2>/dev/null)"; RP=$?; denies "devstride:release"; DP=$?
OUT="$(printf '{"session_id":"s12","cwd":"%s","background_tasks":[]}' "$WORK/plain" | CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$STOP_CMD" 2>/dev/null)"; RS=$?; holds "run $R12"; DS=$?
if [ "$WIRED" = 0 ] && [ "$RA:$A" = "0:" ] && [ "$RB:$Bn" = "0:" ] && [ "$RP:$DP" = "0:0" ] && [ "$RS:$DS" = "0:0" ]; then
  ok "(12) hooks.json runs pre on Skill|Agent|Task in a group after the stop gate's, and stop after presence on Stop, 5 s each; the registered commands refuse and hold, and with no python on PATH exit 0 silently"
else bad "(12) wired=$WIRED nopython=$RA:$A/$RB:$Bn pre=$RP:$DP stop=$RS:$DS"; fi

# (13) the hook starts only the runner, by the running Python, and imports nothing that reaches the network
if grep -q 'sys.executable, "-B", RUNNER, "status"' "$HOOK" && ! grep -Eq 'shell=True|fcntl|strftime|"python3"' "$HOOK" \
   && ! grep -Eq '^[[:space:]]*(import|from)[[:space:]]+(urllib|http|socket|ssl|ctypes)' "$HOOK"; then
  ok "(13) it runs only the runner's status, with sys.executable, no shell, no file lock, no network import"
else bad "(13) the hook's imports or process start"; fi

exit $FAIL
