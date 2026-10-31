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
def runtime(groups, matcherless):
    return [h for g in groups if (not matcherless or "matcher" not in g) for h in g["hooks"]
            if "hooks/session-runtime.py\" record" in h["command"] and h.get("timeout") == 5]
assert runtime(hooks["SessionStart"], True) and runtime(hooks["UserPromptSubmit"], False)
PY
then ok "(5) hooks.json records on every SessionStart (no matcher) and every UserPromptSubmit, 5 s timeout"; else bad "(5) hooks.json registration"; fi

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

exit $FAIL
