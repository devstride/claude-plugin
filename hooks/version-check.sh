#!/usr/bin/env bash
# Session-start version check for the devstride plugin.
#
# Contract (the invariants file, section R, holds the reasons):
#   - NEVER blocks a session and NEVER exits non-zero. Every network command runs under a hard
#     deadline (macOS has no `timeout`; perl's alarm is portable), and every failure records
#     itself and stays quiet. A hook that hangs or errors on every session start is worse than
#     no check.
#   - SILENT when current or unreachable. It speaks only when there is something for the user
#     to do — the token-minimal choice; doctor reports the last record either way.
#   - Reads the RUNNING version from the loaded copy ($CLAUDE_PLUGIN_ROOT), never from disk, and
#     updates ONLY the installation that copy belongs to, for THIS repository — identified by
#     installPath, never assumed. If it cannot identify the install it says so and names no id.
#   - Config comes from the REPOSITORY ROOT's .claude/ds-config.json (`plugin` block), not the
#     launch directory: updateCheck (true), autoUpdate (false), pin (null).
#   - Session start is the ONLY moment an update may be applied (opt-in).
#   - Recipe for "newest release": skills/doctor/references/version-currency.md — TAGS not
#     GitHub Releases; strip the `devstride--v` prefix; compare with sort -V.
# DEVSTRIDE_PLUGIN_UPDATE_CHECK=0 disables the check; DEVSTRIDE_PLUGIN_REPO overrides the source.

[ "${DEVSTRIDE_PLUGIN_UPDATE_CHECK:-1}" = "0" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0
cap() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # cap SECONDS cmd args... — a hard deadline

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$ROOT" ] || exit 0
STDIN_JSON=$(cat 2>/dev/null | head -c 4000)
CWD=$(printf '%s' "$STDIN_JSON" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: print("")' 2>/dev/null)
CWD="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
# The repository root, so a session launched from packages/web still finds the repo's config.
REPO=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null); REPO="${REPO:-$CWD}"

RUNNING=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]+"/.claude-plugin/plugin.json")).get("version",""))
except Exception: print("")' "$ROOT" 2>/dev/null)
[ -n "$RUNNING" ] || exit 0

read -r CHECK AUTO PIN <<EOF
$(python3 -c 'import json,sys
p={}
try: p=json.load(open(sys.argv[1]+"/.claude/ds-config.json")).get("plugin",{}) or {}
except Exception: pass
print("1" if p.get("updateCheck",True) else "0", "1" if p.get("autoUpdate",False) else "0", p.get("pin") or "-")' "$REPO" 2>/dev/null || echo "1 0 -")
EOF
[ "$CHECK" = "0" ] && exit 0

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/devstride-plugin"; mkdir -p "$CACHE_DIR" 2>/dev/null
NEWEST_CACHE="$CACHE_DIR/newest.json"                       # shared: the newest tag is not per-repo
KEY=$(printf '%s' "$REPO" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:12])')
RECORD="$CACHE_DIR/repo-$KEY.json"                            # per-repo: mode and result are
NOW=$(date +%s); TTL=21600                                    # 6h — a release is rare; a session start is not

NEWEST=""; SOURCE="cache"
if [ -f "$NEWEST_CACHE" ]; then
  read -r FETCHED_AT CACHED <<EOF
$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1])); print(d.get("fetchedAt",0), d.get("newest",""))
except Exception: print("0", "")' "$NEWEST_CACHE" 2>/dev/null || echo "0 ")
EOF
  [ -n "$CACHED" ] && [ $((NOW - ${FETCHED_AT:-0})) -lt $TTL ] && NEWEST="$CACHED"
fi
if [ -z "$NEWEST" ]; then
  SOURCE="network"
  NEWEST=$(cap 5 git ls-remote --tags "${DEVSTRIDE_PLUGIN_REPO:-https://github.com/devstride/claude-plugin}" 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/tags/||' | grep -v '\^{}' | sed 's/.*--v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  [ -n "$NEWEST" ] && python3 -c 'import json,sys,time; json.dump({"newest":sys.argv[2],"fetchedAt":int(time.time())},open(sys.argv[1],"w"))' "$NEWEST_CACHE" "$NEWEST" 2>/dev/null
fi

PREV_NOTIFIED=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("notifiedFor",""))
except Exception: print("")' "$RECORD" 2>/dev/null)
MODE="notify"; [ "$AUTO" = "1" ] && MODE="auto-update"; [ "$PIN" != "-" ] && MODE="pinned"
RESULT=""; NOTIFIED=""
finish() { # writes the per-repo record once, then exits 0 — the single exit path after the checks
  python3 -c 'import json,sys,time
json.dump({"checkedAt":int(time.time()),"repo":sys.argv[2],"running":sys.argv[3],"newest":sys.argv[4] or None,
           "source":sys.argv[5],"mode":sys.argv[6],"result":sys.argv[7],"install":sys.argv[8] or None,
           "notifiedFor":sys.argv[9]},open(sys.argv[1],"w"))' \
    "$RECORD" "$REPO" "$RUNNING" "$NEWEST" "$SOURCE" "$MODE" "$RESULT" "${INSTALL:-}" "$NOTIFIED" 2>/dev/null
  exit 0
}
newer() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ] && [ "$1" != "$2" ]; } # newer A B: B > A

[ -z "$NEWEST" ] && { RESULT="unreachable"; finish; }          # offline: quiet; doctor shows it

if [ "$PIN" != "-" ]; then
  # A pin is a VERSION, compared, not a flag. Each distinct situation is said ONCE, not every start.
  if [ "$RUNNING" != "$PIN" ]; then
    RESULT="pin-drift"; NOTIFIED="drift:$PIN:$RUNNING"
    [ "$PREV_NOTIFIED" != "$NOTIFIED" ] && echo "devstride plugin: this repository pins $PIN, but this session runs $RUNNING."
  elif newer "$RUNNING" "$NEWEST"; then
    RESULT="behind-pinned"; NOTIFIED="pinned:$PIN:$NEWEST"
    [ "$PREV_NOTIFIED" != "$NOTIFIED" ] && echo "devstride plugin: pinned at $PIN (running it); newest release is $NEWEST."
  else
    RESULT="current"
  fi
  finish
fi

newer "$RUNNING" "$NEWEST" || { RESULT="current"; finish; }   # current: silent

# Behind. Identify THIS install — the enabled row whose installPath is the loaded copy, preferring
# a project-scope row for this repository over a user-scope one. Never fabricate an id.
INSTALL=$(cap 10 claude plugin list --json 2>/dev/null | python3 -c 'import json,os,sys
root=os.path.realpath(sys.argv[1]); repo=os.path.realpath(sys.argv[2]); rows=[]
try:
  for e in json.load(sys.stdin):
    if not e.get("enabled",True): continue
    if os.path.realpath(e.get("installPath","")) != root: continue
    rows.append(e)
except Exception: rows=[]
proj=[e for e in rows if e.get("scope")=="project" and os.path.realpath(e.get("projectPath","") or "/nonexistent")==repo]
pick=(proj or [e for e in rows if e.get("scope")=="user"] or rows)
print(pick[0]["id"], pick[0].get("scope","user")) if pick else print("")' "$ROOT" "$REPO" 2>/dev/null)

if [ -z "$INSTALL" ]; then
  RESULT="lookup-failed"
  echo "devstride plugin: $RUNNING running, $NEWEST available. Could not identify this install from \`claude plugin list\` — run it to find the id and scope, then: claude plugin marketplace update devstride && claude plugin update <id> --scope <scope>, and restart."
  finish
fi
ID=${INSTALL%% *}; SCOPE=${INSTALL#* }

if [ "$AUTO" = "1" ]; then
  if cap 60 claude plugin marketplace update devstride >/dev/null 2>&1 && cap 120 claude plugin update "$ID" --scope "$SCOPE" >/dev/null 2>&1; then
    RESULT="updated"
    echo "devstride plugin: updated on disk $RUNNING → $NEWEST ($ID, $SCOPE). This session still runs $RUNNING — restart to pick it up."
    finish
  fi
  RESULT="update-failed"
  echo "devstride plugin: automatic update to $NEWEST failed (this session runs $RUNNING). By hand: claude plugin marketplace update devstride && claude plugin update $ID --scope $SCOPE, then restart."
  finish
fi

RESULT="behind"
echo "devstride plugin: $RUNNING running, $NEWEST available. To update (both commands, then restart):"
echo "  claude plugin marketplace update devstride && claude plugin update $ID --scope $SCOPE"
finish
