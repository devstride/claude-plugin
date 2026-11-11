#!/bin/bash
# Deterministic tests for hooks/session-runtime.py — the per-session record of the plugin version a
# session has LOADED, and the verdict the status line reads from it. Every case runs against a
# private cache, plugin registry and throwaway repositories; nothing touches the machine's state.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HELPER="$ROOT/hooks/session-runtime.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export XDG_CACHE_HOME="$WORK/cache" CLAUDE_CONFIG_DIR="$WORK/claude"
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
SESSIONS="$XDG_CACHE_HOME/devstride-plugin/sessions"

plugin_copy() { # plugin_copy VERSION → a fixture plugin root carrying that manifest
  local d="$WORK/plugin-$1"; mkdir -p "$d/.claude-plugin"
  printf '{"name":"devstride","version":"%s"}' "$1" > "$d/.claude-plugin/plugin.json"; printf '%s' "$d"
}
mkrepo() { # mkrepo NAME [CONFIG-JSON]
  local d="$WORK/$1"; mkdir -p "$d/.claude"; git -C "$d" init -q 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "${2:-{\}}" > "$d/.claude/ds-config.json"; printf '%s' "$d"
}
registry() { printf '{"version":2,"plugins":{%s}}' "$1" > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"; }
project_row() { printf '{"scope":"project","projectPath":"%s","installPath":"%s","version":"%s"}' "$1" "$WORK/plugin-$2" "$2"; }
newest() { # newest VERSION AGE-SECONDS
  mkdir -p "$XDG_CACHE_HOME/devstride-plugin"
  python3 -c 'import json,sys,time; print(json.dumps({"schema":2,"source":"https://github.com/devstride/claude-plugin","newest":sys.argv[1],"fetchedAt":int(time.time())-int(sys.argv[2])}))' "$1" "$2" \
    > "$XDG_CACHE_HOME/devstride-plugin/newest.json"
}
# record ROOT SESSION [EVENT] [TRANSCRIPT] — run the hook as Claude Code does
record() {
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"%s"}' "$2" "${4:-}" "${3:-UserPromptSubmit}" \
    | CLAUDE_PLUGIN_ROOT="$1" python3 "$HELPER" record 2>&1
}
verdict() { python3 "$HELPER" check --session "$1" --repo "$2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])'; }
iso() { python3 -c 'import datetime,sys,time; print(datetime.datetime.fromtimestamp(time.time()+int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"; }
reload_line() { printf '{"type":"system","subtype":"local_command","content":"<local-command-stdout>Reloaded: 1 plugin</local-command-stdout>","timestamp":"%s","commandRun":{"command":"reload-plugins","args":""}}\n' "$1"; }

P15="$(plugin_copy 3.15.0)"; P16="$(plugin_copy 3.16.0)"; plugin_copy 3.16.1 >/dev/null
R="$(mkrepo repo)"; T="$WORK/transcript.jsonl"; : > "$T"

# (1) the hook writes the record from the loaded copy and the payload, owner-only
OUT="$(record "$P15" s1 SessionStart "$T")"; RC=$?
REC="$SESSIONS/s1.json"
if [ $RC -eq 0 ] && [ -z "$OUT" ] && python3 - "$REC" "$P15" "$T" <<'PY'
import json, os, stat, sys
r = json.load(open(sys.argv[1]))
assert r["schema"] == 1 and r["running"] == "3.15.0" and r["root"] == os.path.realpath(sys.argv[2])
assert r["transcript"] == sys.argv[3] and isinstance(r["at"], (int, float))
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
then ok "(1) record → {schema 1, running, root, transcript, at}, mode 600, silent"; else bad "(1) rc=$RC out=$OUT $(cat "$REC" 2>/dev/null)"; fi

# (2) a bad session id, no plugin root, or a manifest that is not this plugin's writes nothing
B="$(record "$P15" '../escape')$(record "$P15" '')$(printf '{"session_id":"s2"}' | python3 "$HELPER" record 2>&1)"
mkdir -p "$WORK/other/.claude-plugin"; printf '{"name":"other","version":"1.0.0"}' > "$WORK/other/.claude-plugin/plugin.json"
B="$B$(record "$WORK/other" s3)"
if [ -z "$B" ] && [ ! -e "$XDG_CACHE_HOME/devstride-plugin/escape.json" ] && [ ! -e "$SESSIONS/s2.json" ] && [ ! -e "$SESSIONS/s3.json" ]; then
  ok "(2) bad session id / no CLAUDE_PLUGIN_ROOT / foreign manifest → nothing written, silent"; else bad "(2) $B"; fi

# (3) an unwritable cache, and a machine with no python3, both exit 0 silently
mkdir -p "$WORK/ro"; chmod 500 "$WORK/ro"
OUT="$(printf '{"session_id":"s4"}' | XDG_CACHE_HOME="$WORK/ro" CLAUDE_PLUGIN_ROOT="$P15" python3 "$HELPER" record 2>&1)"; RC=$?
CMD="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["UserPromptSubmit"][0]["hooks"][1]["command"])' "$ROOT/hooks/hooks.json")"
OUT2="$(printf '{"session_id":"s4"}' | env -i PATH="$WORK/nobin" CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$CMD" 2>&1)"; RC2=$?
if [ $RC -eq 0 ] && [ -z "$OUT" ] && [ $RC2 -eq 0 ] && [ -z "$OUT2" ]; then
  ok "(3) unwritable cache → exit 0, silent; the registered command with no python3 → exit 0, silent"; else bad "(3) rc=$RC/$RC2 $OUT|$OUT2"; fi

# (4) session start prunes records older than 7 days; a prompt does not; a fresh record survives
record "$P15" old >/dev/null; touch -t 202001010000 "$SESSIONS/old.json"
record "$P15" fresh >/dev/null
record "$P15" s5 UserPromptSubmit >/dev/null; [ -e "$SESSIONS/old.json" ] && KEPT=1 || KEPT=0
record "$P15" s5 SessionStart >/dev/null
if [ $KEPT = 1 ] && [ ! -e "$SESSIONS/old.json" ] && [ -e "$SESSIONS/fresh.json" ]; then
  ok "(4) SessionStart prunes a record older than 7 days, keeps fresh ones; a prompt never prunes"; else bad "(4) kept=$KEPT $(ls "$SESSIONS")"; fi

# (5) the registration: session start with NO matcher (startup, resume, clear, compact) and every prompt
if python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
def runtime(groups, matcherless, mode):
    return [h for g in groups if (not matcherless or "matcher" not in g) for h in g["hooks"]
            if ('hooks/session-runtime.py" %s;' % mode) in h["command"] and h.get("timeout") == 5]
assert runtime(hooks["SessionStart"], True, "record") and runtime(hooks["UserPromptSubmit"], False, "prompt")
PY
then ok "(5) hooks.json records on every SessionStart (no matcher) and runs the prompt mode on every UserPromptSubmit, 5 s timeout"; else bad "(5) hooks.json registration"; fi

# --- check ---------------------------------------------------------------------------------
registry "\"devstride@devstride\":[$(project_row "$R" 3.16.0)]"
newest 3.16.0 0
# (6) no record and a malformed record are unknown
printf 'not json' > "$SESSIONS/broken.json"
if [ "$(verdict nosuch "$R")" = unknown ] && [ "$(verdict broken "$R")" = unknown ] && [ "$(verdict '../x' "$R")" = unknown ]; then
  ok "(6) no record / malformed record / bad id → unknown"; else bad "(6)"; fi

# (7) running older than the install that applies here → reload, also from a linked worktree
record "$P15" r1 SessionStart "$T" >/dev/null
git -C "$R" worktree add -q "$WORK/repo-wt" -b side 2>/dev/null
JSON="$(python3 "$HELPER" check --session r1 --repo "$R")"
if [ "$(verdict r1 "$R")" = reload ] && [ "$(verdict r1 "$WORK/repo-wt")" = reload ] \
   && printf '%s' "$JSON" | grep -q '"installed": "3.16.0"' && printf '%s' "$JSON" | grep -q '"running": "3.15.0"'; then
  ok "(7) running 3.15.0, installed 3.16.0 (project row of the main checkout) → reload, from the worktree too"; else bad "(7) $JSON"; fi

# (8) a /reload-plugins after the record was written reads as current; one before it does not
reload_line "$(iso 60)" >> "$T"
V1="$(verdict r1 "$R")"
: > "$T"; reload_line "$(iso -60)" >> "$T"
V2="$(verdict r1 "$R")"
if [ "$V1" = current ] && [ "$V2" = reload ]; then
  ok "(8) reload after the record → current until the next prompt; reload before it → still reload"; else bad "(8) $V1 $V2"; fi
# (8b) a failed reload: the next prompt rewrites the record with what is still loaded → reload again
: > "$T"; reload_line "$(iso -1)" >> "$T"; record "$P15" r1 UserPromptSubmit "$T" >/dev/null
[ "$(verdict r1 "$R")" = reload ] && ok "(8b) the prompt after a failed reload shows the warning again" || bad "(8b) $(verdict r1 "$R")"

# (9) running the installed copy, newer release published → update; stale newest, a pin, or the
#     check switched off → current; newest equal → current
record "$P16" u1 SessionStart >/dev/null
newest 3.16.1 0; V1="$(verdict u1 "$R")"
P="$(mkrepo pinned '{"plugin":{"pin":"3.16.0"}}')"; OFF="$(mkrepo off '{"plugin":{"updateCheck":false}}')"
registry "\"devstride@devstride\":[$(project_row "$R" 3.16.0),$(project_row "$P" 3.16.0),$(project_row "$OFF" 3.16.0)]"
V2="$(verdict u1 "$P")"; V3="$(verdict u1 "$OFF")"
newest 3.16.1 30000; V4="$(verdict u1 "$R")"
newest 3.16.0 0; V5="$(verdict u1 "$R")"
if [ "$V1" = update ] && [ "$V2" = current ] && [ "$V3" = current ] && [ "$V4" = current ] && [ "$V5" = current ]; then
  ok "(9) update only when running == installed < a fresh newest and the repo neither pins nor opts out"; else bad "(9) $V1 $V2 $V3 $V4 $V5"; fi

# (10) no single applicable install → unknown: a project row plus a user row, or only another repo's row
registry "\"devstride@devstride\":[$(project_row "$R" 3.16.0)],\"ds@devstride\":[{\"scope\":\"user\",\"installPath\":\"$P16\",\"version\":\"3.16.0\"}]"
V1="$(verdict r1 "$R")"
O="$(mkrepo elsewhere)"; registry "\"devstride@devstride\":[$(project_row "$O" 3.16.0)]"
V2="$(verdict r1 "$R")"
registry "\"devstride@devstride\":[{\"scope\":\"user\",\"installPath\":\"$P16\",\"version\":\"3.16.0\"}]"
V3="$(verdict r1 "$R")"
if [ "$V1" = unknown ] && [ "$V2" = unknown ] && [ "$V3" = reload ]; then
  ok "(10) project + user rows → unknown; only another repository's row → unknown; one user row applies"; else bad "(10) $V1 $V2 $V3"; fi

# (11) the system python the status line may run under (macOS ships 3.9) reads the same verdict
if [ -x /usr/bin/python3 ]; then
  V="$(/usr/bin/python3 "$HELPER" check --session r1 --repo "$R" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')"
  [ "$V" = reload ] && ok "(11) /usr/bin/python3 gives the same verdict" || bad "(11) $V"
fi

# --- prompt: the once-per-version ask, and the background refresh ---------------------------
# prompt ROOT SESSION REPO [PROMPT] — run the UserPromptSubmit hook as Claude Code does
prompt() {
  printf '{"session_id":"%s","cwd":"%s","prompt":"%s","hook_event_name":"UserPromptSubmit"}' "$2" "$3" "${4:-hello}" \
    | CLAUDE_PLUGIN_ROOT="$1" DEVSTRIDE_PLUGIN_UPDATE_CHECK="${UC:-1}" python3 "${RUNTIME:-$HELPER}" prompt 2>&1
}
: > "$T"; registry "\"devstride@devstride\":[$(project_row "$R" 3.16.0),$(project_row "$P" 3.16.0),$(project_row "$OFF" 3.16.0)]"
newest 3.16.0 0   # fresh: no background fetch from these cases
# (12) running older than installed → ONE reload line, then silence for the same version; the
#      marker survives the record rewrite every prompt does
N1="$(prompt "$P15" n1 "$R")"; N2="$(prompt "$P15" n1 "$R")"
if printf '%s' "$N1" | grep -q 'still running 3.15.0, and 3.16.0 is installed' && printf '%s' "$N1" | grep -q '/reload-plugins' \
   && [ -z "$N2" ] && grep -q '"nudged":"reload:3.16.0"' "$SESSIONS/n1.json"; then
  ok "(12) reload: one context line naming /reload-plugins, then silent for that version (nudged kept)"; else bad "(12) [$N1] [$N2]"; fi

# (13) a loop or scheduled prompt, and /devstride:update itself, never get the line
L1="$(prompt "$P15" n2 "$R" '/loop /devstride:build-item')"; L2="$(prompt "$P15" n2 "$R" '<<autonomous-loop-dynamic>>')"
L3="$(prompt "$P15" n2 "$R" '/devstride:update')$(prompt "$P15" n2 "$R" '<task-notification><task-id>x</task-id></task-notification>')"; L4="$(prompt "$P15" n2 "$R" 'what does <task-notification> mean here')"
if [ -z "$L1$L2$L3" ] && printf '%s' "$L4" | grep -q '3.16.0 is installed'; then
  ok "(13) /loop, an autonomous-loop wakeup, a background-task report and /devstride:update → no line; a prompt that only mentions one gets it"; else bad "(13) [$L1|$L2|$L3|$L4]"; fi

# (14) running the installed copy with a newer release → ONE ask to update; never for a pinned or
#      opted-out repository, nor with DEVSTRIDE_PLUGIN_UPDATE_CHECK=0; a newer target asks again
newest 3.16.1 0
U1="$(prompt "$P16" n3 "$R")"; U2="$(prompt "$P16" n3 "$R")"
U3="$(prompt "$P16" n4 "$P")$(prompt "$P16" n5 "$OFF")$(UC=0 prompt "$P16" n6 "$R")"
newest 3.16.2 0; U4="$(prompt "$P16" n3 "$R")"
if printf '%s' "$U1" | grep -q 'runs 3.16.0 and 3.16.1 is published' && printf '%s' "$U1" | grep -q '/devstride:update' \
   && printf '%s' "$U1" | grep -q 'do not ask' && [ -z "$U2" ] && [ -z "$U3" ] && printf '%s' "$U4" | grep -q '3.16.2 is published'; then
  ok "(14) update: asked once per published version; pinned, opted-out and check-off repos are never asked"; else bad "(14) [$U1] [$U2] [$U3] [$U4]"; fi

# (14b) the reload line obeys the same switches: none with the check off (setting or variable),
#       and in a pinning repository only a reload onto the pinned version
registry "\"devstride@devstride\":[$(project_row "$R" 3.16.0),$(project_row "$P" 3.16.0),$(project_row "$OFF" 3.16.0)]"
P17="$(mkrepo pinned17 '{"plugin":{"pin":"3.17.0"}}')"
registry "\"devstride@devstride\":[$(project_row "$R" 3.16.0),$(project_row "$P" 3.16.0),$(project_row "$OFF" 3.16.0),$(project_row "$P17" 3.16.0)]"
newest 3.16.0 0
B1="$(prompt "$P15" r20 "$OFF")$(UC=0 prompt "$P15" r21 "$R")$(prompt "$P15" r22 "$P17")"
B2="$(prompt "$P15" r23 "$P")"
if [ -z "$B1" ] && printf '%s' "$B2" | grep -q '3.16.0 is installed'; then
  ok "(14b) reload line: none with updateCheck false, the variable at 0, or a pin on another version; pinned onto 3.16.0 → told"
else bad "(14b) [$B1] [$B2]"; fi

# (15) current → silent; no record (no plugin root) → silent, exit 0
newest 3.16.0 0
C1="$(prompt "$P16" n7 "$R")"; C2="$(printf '{"session_id":"n8"}' | python3 "$HELPER" prompt 2>&1)"; RC=$?
if [ -z "$C1$C2" ] && [ $RC -eq 0 ]; then ok "(15) current, or nothing to record → silent, exit 0"; else bad "(15) [$C1|$C2] rc=$RC"; fi

# (16) the background refresh: a stale cache starts ONE detached fetch that writes newest.json in
#      the session-start check's format and drops its lock; a held lock, a pin, the check switched
#      off or a cache under 30 minutes old starts none. A copy of the helper in a fixture plugin
#      tree fetches from a fake, so nothing reaches the network.
FP="$WORK/fakeplugin"; mkdir -p "$FP/hooks" "$FP/skills/update/scripts"; cp "$HELPER" "$FP/hooks/"
printf 'print("3.17.0")\n' > "$FP/skills/update/scripts/update-plugin.py"
NJ="$XDG_CACHE_HOME/devstride-plugin/newest.json"; LOCK="$XDG_CACHE_HOME/devstride-plugin/newest.refresh"
wait_newest() { for _ in $(seq 1 30); do grep -q "$1" "$NJ" 2>/dev/null && [ ! -e "$LOCK" ] && return 0; sleep 0.1; done; return 1; }
newest 3.16.0 4000; RUNTIME="$FP/hooks/session-runtime.py" prompt "$P16" n9 "$R" >/dev/null
wait_newest 3.17.0 && FETCHED=1 || FETCHED=0
FMT="$(python3 -c '
import json, os, stat, sys, time
v = json.load(open(sys.argv[1]))
ok = (v["schema"] == 2 and v["source"] == "https://github.com/devstride/claude-plugin" and v["newest"] == "3.17.0"
      and abs(time.time() - v["fetchedAt"]) < 60 and stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600)
print("1" if ok else "0")' "$NJ")"
newest 3.16.0 4000; : > "$LOCK"; RUNTIME="$FP/hooks/session-runtime.py" prompt "$P16" n9 "$R" >/dev/null; sleep 1; grep -q 3.16.0 "$NJ" && D1=1 || D1=0
rm -f "$LOCK"; RUNTIME="$FP/hooks/session-runtime.py" prompt "$P16" n10 "$P" >/dev/null; sleep 1; grep -q 3.16.0 "$NJ" && D2=1 || D2=0
UC=0 RUNTIME="$FP/hooks/session-runtime.py" prompt "$P16" n11 "$R" >/dev/null; sleep 1
grep -q '3.16.0' "$NJ" && NONE=1 || NONE=0
newest 3.16.0 600; RUNTIME="$FP/hooks/session-runtime.py" prompt "$P16" n12 "$R" >/dev/null; sleep 1
grep -q '3.16.0' "$NJ" && FRESH=1 || FRESH=0
if [ $FETCHED = 1 ] && [ "$FMT" = 1 ] && [ "$D1$D2$NONE" = 111 ] && [ $FRESH = 1 ] && [ ! -d "$FP/hooks/__pycache__" ]; then
  ok "(16) stale cache → one detached fetch, newest.json in the session-start format, lock dropped; held lock / pin / check off / a 10-minute-old cache → no fetch"
else bad "(16) d1=$D1 d2=$D2 fetched=$FETCHED fmt=$FMT none=$NONE fresh=$FRESH"; fi

# (17) a failed fetch (offline) keeps its lock: the next prompts start no fetch until it is five
#      minutes old, and then one does. The fake helper counts its runs.
printf 'import os\nopen(os.path.join(os.path.dirname(__file__), "runs"), "a").write("x")\nraise SystemExit(1)\n' \
  > "$FP/skills/update/scripts/update-plugin.py"; RUNS="$FP/skills/update/scripts/runs"; rm -f "$LOCK" "$RUNS"
runs() { wc -c < "$RUNS" 2>/dev/null | tr -d ' ' || echo 0; }
newest 3.16.0 4000; RUNTIME="$FP/hooks/session-runtime.py" prompt "$P16" n13 "$R" >/dev/null
for _ in $(seq 1 30); do [ "$(runs)" = 1 ] && break; sleep 0.1; done; sleep 0.5
RUNTIME="$FP/hooks/session-runtime.py" prompt "$P16" n13 "$R" >/dev/null; sleep 1; R1="$(runs)"
touch -t "$(date -v-6M +%Y%m%d%H%M.%S 2>/dev/null || date -d '6 minutes ago' +%Y%m%d%H%M.%S)" "$LOCK"
RUNTIME="$FP/hooks/session-runtime.py" prompt "$P16" n13 "$R" >/dev/null
for _ in $(seq 1 30); do [ "$(runs)" = 2 ] && break; sleep 0.1; done; R2="$(runs)"
if [ "$R1" = 1 ] && [ "$R2" = 2 ] && [ -e "$LOCK" ] && grep -q '3.16.0' "$NJ"; then
  ok "(17) a failed fetch keeps newest.json and its lock: no retry on the next prompt, one retry once the lock is 5 minutes old"
else bad "(17) runs after 2 prompts=$R1, after the lock aged=$R2"; fi

# --- the live model and effort, and the `models` verdict -----------------------------------
# event SESSION EVENT EXTRA-JSON [MODE] — a hook payload carrying a model and/or an effort
event() { printf '{"session_id":"%s","hook_event_name":"%s"%s}' "$1" "$2" "$3" | CLAUDE_PLUGIN_ROOT="$P16" python3 "$HELPER" "${4:-record}" 2>&1; }
field() { python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v.get(k) if isinstance(v, dict) else None
print(v)' "$SESSIONS/$1.json" "$2"; }
mverdict() { python3 "$HELPER" models --role "$1" --session "$2" --repo "${3:-$R}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])'; }
stamp() { python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino, s.st_mtime_ns)' "$SESSIONS/$1.json"; }

# (18) SessionStart's model is recorded (a bare id or an object), a tool event's effort is added,
#      and a later prompt, which carries neither, keeps both
event m1 SessionStart ',"model":"claude-fable-5-2"' >/dev/null
M1="$(field m1 model.id)/$(field m1 effort.level)"
OUT="$(event m1 PreToolUse ',"effort":{"level":"high"}' seen)"
event m1 UserPromptSubmit '' prompt >/dev/null
M2="$(field m1 model.id)/$(field m1 effort.level)/$(field m1 running)"
event m2 SessionStart ',"model":{"id":"claude-opus-5","display_name":"Opus 5"}' >/dev/null
if [ "$M1" = "claude-fable-5-2/None" ] && [ -z "$OUT" ] && [ "$M2" = "claude-fable-5-2/high/3.16.0" ] \
   && [ "$(field m2 model.id)/$(field m2 model.name)" = "claude-opus-5/Opus 5" ] \
   && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["schema"]==1 and isinstance(r["model"]["at"],(int,float)) and isinstance(r["effort"]["at"],(int,float))' "$SESSIONS/m1.json"; then
  ok "(18) SessionStart records the model (bare id or object), a tool event adds the effort, a prompt keeps both; schema stays 1"
else bad "(18) m1=$M1 m2=$M2 out=$OUT $(cat "$SESSIONS/m1.json")"; fi

# (19) `seen` rewrites nothing when nothing changed, rewrites once when the effort changes, never
#      moves the record's own `at`, and never creates a record
AT="$(field m1 at)"; S0="$(stamp m1)"
event m1 PreToolUse ',"effort":{"level":"high"}' seen >/dev/null; event m1 PostToolUse '' seen >/dev/null; S1="$(stamp m1)"
EAT="$(field m1 effort.at)"; sleep 0.05
event m1 Stop ',"effort":{"level":"xhigh"}' seen >/dev/null; S2="$(stamp m1)"
event nosuch PreToolUse ',"effort":{"level":"high"}' seen >/dev/null
if [ "$S0" = "$S1" ] && [ "$S1" != "$S2" ] && [ "$(field m1 effort.level)" = xhigh ] && [ "$(field m1 effort.at)" != "$EAT" ] \
   && [ "$(field m1 at)" = "$AT" ] && [ "$(field m1 model.id)" = claude-fable-5-2 ] && [ ! -e "$SESSIONS/nosuch.json" ]; then
  ok "(19) seen: unchanged effort → no write; a new effort → one write with a new time; record 'at' and the model kept; no record → none created"
else bad "(19) $S0 | $S1 | $S2 $(cat "$SESSIONS/m1.json")"; fi

# (20) garbage fails open: unparsable input, wrong shapes and hostile values write nothing, print
#      nothing and exit 0; the registered PreToolUse command is bounded and survives no python3
S2="$(stamp m1)"; G=""
G="$G$(printf 'not json' | python3 "$HELPER" seen 2>&1)$?"
G="$G$(event m1 PreToolUse ',"effort":{"level":"HIGH; rm"},"model":["x"]' seen)$?"
G="$G$(event m1 PreToolUse ',"effort":7,"model":{"id":"a b","display_name":7}' seen)$?"
G="$G$(event '../m1' PreToolUse ',"effort":{"level":"low"}' seen)$?"
G="$G$(printf '{"session_id":"m1","effort":{"level":"low"}}' | XDG_CACHE_HOME="$WORK/ro" python3 "$HELPER" seen 2>&1)$?"
CMD="$(python3 -c 'import json,sys
h = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
c = [x for g in h for x in g["hooks"] if "hooks/session-runtime.py\" seen;" in x["command"] and x.get("timeout") == 5 and x["command"].endswith("exit 0")]
assert len(c) == 1 and all("matcher" not in g for g in h); print(c[0]["command"])' "$ROOT/hooks/hooks.json")"
G="$G$(printf '{"session_id":"m1"}' | env -i PATH="$WORK/nobin" CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$CMD" 2>&1)$?"
if [ "$G" = 000000 ] && [ "$(stamp m1)" = "$S2" ] && [ -n "$CMD" ]; then
  ok "(20) seen fails open on garbage (no write, silent, exit 0); hooks.json runs it on every PreToolUse, 5 s timeout, exit 0 without python3"
else bad "(20) g=$G cmd=$CMD"; fi

# (21) the status line's path: observe() notes the payload's model and effort in an existing
#      record, writes only when one changed, and never raises
OBS="$(python3 - "$HELPER" <<'PY'
import os, sys, types
helper = sys.argv[1]; rt = types.ModuleType("rt"); rt.__file__ = helper
exec(compile(open(helper, "rb").read(), helper, "exec"), rt.__dict__)
out = [rt.observe("m2", "claude-opus-5", "Opus 5", "medium"), rt.observe("m2", "claude-opus-5", "Opus 5", "medium"),
       rt.observe("m2", "claude-opus-5", None, None), rt.observe("m2", "claude-sonnet-5", "Sonnet 5", "medium"),
       rt.observe("m2", None, None, None), rt.observe("absent", "claude-opus-5", "Opus 5", "high"),
       rt.observe(None, {"x": 1}, 7, ["high"])]
print("".join("1" if o else "0" for o in out))
PY
)"
if [ "$OBS" = 1001000 ] && [ "$(field m2 model.id)/$(field m2 model.name)/$(field m2 effort.level)" = "claude-sonnet-5/Sonnet 5/medium" ]; then
  ok "(21) observe: first sight writes, the same values do not, a new model does; nothing to note, no record and garbage → False, no error"
else bad "(21) obs=$OBS $(cat "$SESSIONS/m2.json")"; fi

# (22) verdicts: an alias matches by family, [1m] is ignored on either side, a full id matches only itself
seed() { # seed SESSION MODEL EFFORT
  event "$1" SessionStart ",\"model\":\"$2\"" >/dev/null; [ -z "${3:-}" ] || event "$1" PreToolUse ",\"effort\":{\"level\":\"$3\"}" seen >/dev/null
}
seed v1 claude-fable-5-2 high; seed v2 'claude-opus-5[1m]' high; seed v3 claude-opus-5-20270101 high
RF="$(mkrepo models-full '{"sessionModels":{"runner":{"model":"claude-opus-5","effort":"high"},"planning":{"model":"fable[1m]"}}}')"
V="$(mverdict planning v1) $(mverdict runner v2) $(mverdict runner v2 "$RF") $(mverdict runner v3 "$RF") $(mverdict planning v1 "$RF") $(mverdict runner v1)"
LINE="$(python3 "$HELPER" models --role planning --session v1 --repo "$R")"
if [ "$V" = "match match match mismatch match mismatch" ] \
   && [ "$LINE" = '{"expected": {"effort": "high", "model": "fable"}, "role": "planning", "running": {"effort": "high", "model": "claude-fable-5-2"}, "verdict": "match"}' ]; then
  ok "(22) models: alias ↔ family, [1m] ignored either side, full id only itself, a different family mismatches; one JSON line"
else bad "(22) $V | $LINE"; fi

# (23) anchored, never a substring: `opus` does not match an id whose segment merely starts with it
seed v4 claude-opusplan-x high; seed v5 claude-3-5-sonnet-20241022 high
RS="$(mkrepo models-sonnet '{"sessionModels":{"runner":{"model":"sonnet"}}}')"
V="$(mverdict runner v4) $(mverdict runner v1) $(mverdict runner v5 "$RS") $(mverdict runner v2 "$RS")"
if [ "$V" = "mismatch mismatch match mismatch" ]; then
  ok "(23) models: opus ≠ claude-opusplan-x and ≠ claude-fable-…; sonnet matches an id carrying it as a whole segment"
else bad "(23) $V"; fi

# (24) the effort alone mismatches; a configured override decides; the default session id is CLAUDE_CODE_SESSION_ID
seed v6 claude-opus-5 medium
RE="$(mkrepo models-effort '{"sessionModels":{"runner":{"effort":"medium"},"planning":{"model":"opus","effort":"medium"}}}')"
ENVV="$(CLAUDE_CODE_SESSION_ID=v6 python3 "$HELPER" models --role runner --repo "$RE" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["verdict"], d["expected"]["effort"], d["running"]["effort"])')"
V="$(mverdict runner v6) $(mverdict runner v6 "$RE") $(mverdict planning v6 "$RE") $(mverdict planning v6)"
if [ "$V" = "mismatch match match mismatch" ] && [ "$ENVV" = "match medium medium" ]; then
  ok "(24) models: effort-only mismatch; a repository's own sessionModels decide; the session defaults to CLAUDE_CODE_SESSION_ID"
else bad "(24) $V | $ENVV"; fi

# (25) unknown is never a mismatch: no record, no session, an effort or model not seen yet, a name
#      that cannot be compared, a bad role, an unreadable config; a KNOWN difference still mismatches
seed v7 claude-opus-5; event v8 SessionStart '' >/dev/null; event v8 PreToolUse ',"effort":{"level":"high"}' seen >/dev/null
RD="$(mkrepo models-default '{"sessionModels":{"runner":{"model":"opusplan"},"planning":{"model":"best"}}}')"
RB="$(mkrepo models-bad '{"sessionModels":{"runner":{"model":"gpt-9","effort":"huge"}}}')"; RJ="$(mkrepo models-junk 'not json')"
V="$(mverdict runner nosuch) $(env -u CLAUDE_CODE_SESSION_ID python3 "$HELPER" models --role runner --repo "$R" | grep -c '"verdict": "unknown"')"
V="$V $(mverdict runner v7) $(mverdict runner v8) $(mverdict runner v2 "$RD") $(mverdict planning v2 "$RD") $(mverdict runner v2 "$RB")"
V="$V $(mverdict nobody v2) $(mverdict runner v2 "$RJ") $(mverdict runner v6 "$RD") $(mverdict planning v7)"
RCS="$(python3 "$HELPER" models >/dev/null 2>&1; echo $?)$(python3 "$HELPER" models --role >/dev/null 2>&1; echo $?)"
if [ "$V" = "unknown 1 unknown unknown unknown unknown unknown unknown match mismatch mismatch" ] && [ "$RCS" = 00 ]; then
  ok "(25) models: no record / no session / value not seen / default, best, opusplan / an unusable name / a bad role → unknown, exit 0; a known difference still mismatches"
else bad "(25) $V rc=$RCS"; fi

# (26) sessionModels.check: false → off, whatever runs
RO="$(mkrepo models-off '{"sessionModels":{"check":false}}')"
if [ "$(mverdict runner v1 "$RO") $(mverdict planning nosuch "$RO")" = "off off" ]; then
  ok "(26) models: sessionModels.check false → off"; else bad "(26) $(mverdict runner v1 "$RO")"; fi

# (27) doctor's lines: each role's effective values and their source; a WARN per unusable name
REP="$(python3 "$HELPER" models-report --repo "$R")"; REPB="$(python3 "$HELPER" models-report --repo "$RB")"; REPO_OFF="$(python3 "$HELPER" models-report --repo "$RO")"
if printf '%s\n' "$REP" | grep -q '^sessionModels.planning: model "fable" (shipped default), effort "high" (shipped default)$' \
   && printf '%s\n' "$REP" | grep -q '^sessionModels.runner: model "opus" (shipped default), effort "high" (shipped default)$' \
   && ! printf '%s\n' "$REP" | grep -q '^WARN' && printf '%s\n' "$REP" | head -1 | grep -q 'which models this account offers cannot be read' \
   && printf '%s\n' "$REPB" | grep -q '^sessionModels.runner: model "gpt-9" (configured), effort "huge" (configured)$' \
   && [ "$(printf '%s\n' "$REPB" | grep -c '^WARN sessionModels.runner.\(model\|effort\): ')" = 2 ] \
   && printf '%s\n' "$REPO_OFF" | grep -q '^sessionModels.check: false' \
   && ! python3 "$HELPER" models-report --repo "$RF" | grep -q '^WARN'; then
  ok "(27) models-report: effective values with their source; WARN for a name that is no alias or claude-… id and an effort outside the five; the switch reported"
else bad "(27) $REP | $REPB"; fi

# (28) the contract and its six citing skills: each cites session-models.md with its role, and
#      the defaults the contract states are the ones the helper and the registry ship
if python3 - "$ROOT" "$HELPER" <<'PY'
import json, re, sys, types
root, helper = sys.argv[1:3]
ref = "`${CLAUDE_PLUGIN_ROOT}/skills/plan/references/session-models.md`"
roles = {"plan": "planning", "insert-story": "planning", "insert-defect": "planning", "rebalance": "planning",
         "build-item": "runner", "ultracode-build": "runner"}
for skill, role in roles.items():
    lines = [l for l in open("%s/skills/%s/SKILL.md" % (root, skill), encoding="utf-8") if ref in l]
    assert len(lines) == 1 and "once per top-level run" in lines[0] and "role `%s`" % role in lines[0], skill
assert "`build-item` invoked" in [l for l in open(root + "/skills/ultracode-build/SKILL.md", encoding="utf-8") if ref in l][0]
text = open(root + "/skills/plan/references/session-models.md", encoding="utf-8").read()
assert text.startswith("---\nload: contract\n---\n") and "## Cited by" in text
rt = types.ModuleType("rt"); rt.__file__ = helper
exec(compile(open(helper, "rb").read(), helper, "exec"), rt.__dict__)
reg = {e["key"]: e for e in json.load(open(root + "/schemas/seam-registry.json"))["settings"]}
for role, (model, effort) in rt.ROLES.items():
    assert reg["sessionModels.%s.model" % role]["default"] == model and reg["sessionModels.%s.effort" % role]["default"] == effort
    assert reg["sessionModels.%s.effort" % role]["enum"] == list(rt.EFFORTS)
    assert re.search(r"\| `%s` \|[^\n]*default `%s`[^\n]*default `%s`" % (role, model, effort), text), role
assert reg["sessionModels.check"]["default"] is True
for word in list(rt.MODEL_ALIASES) + list(rt.EFFORTS) + ["match", "mismatch", "unknown", "off", "/model", "/effort", "models --role"]:
    assert word in text, word
schema = json.load(open(root + "/schemas/ds-config.schema.json"))["properties"]["sessionModels"]["properties"]
assert set(schema) == {"check", "planning", "runner"} and schema["runner"]["properties"]["effort"]["enum"] == list(rt.EFFORTS)
assert "session-runtime.py models-report" in open(root + "/skills/doctor/SKILL.md", encoding="utf-8").read()
PY
then ok "(28) plan, insert-story, insert-defect, rebalance (planning) and build-item, ultracode-build (runner) each cite the contract once; contract, helper, registry and schema agree; doctor runs models-report"
else bad "(28) a citing skill, the contract or the registry disagrees"; fi

exit $FAIL
