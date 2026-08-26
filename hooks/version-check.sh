#!/usr/bin/env bash
# Session-start version check for the devstride plugin.
#
# Contract (the invariants file section R holds the reasons):
#   - NEVER blocks a session and NEVER exits non-zero. Every failure degrades to "record it and
#     stay quiet"; a hook that hangs or errors on every session start is worse than no check.
#   - SILENT when current or unreachable. It speaks only when there is something for the user
#     to do — that is the token-minimal choice, and doctor reports the last check either way.
#   - Reads the RUNNING version from the loaded copy ($CLAUDE_PLUGIN_ROOT), not from disk.
#   - The recipe for "newest release" is skills/doctor/references/version-currency.md: TAGS, not
#     GitHub Releases; strip the `devstride--v` prefix; the installed id comes from
#     `claude plugin list --json`, never assumed.
#   - Session start is the ONLY moment an update may be applied (opt-in): applying mid-loop would
#     change skill behaviour between the steps of a build.
# Config (consuming repo's .claude/ds-config.json, `plugin` block): updateCheck (default true),
# autoUpdate (default false), pin (default null). DEVSTRIDE_PLUGIN_UPDATE_CHECK=0 disables it.

[ "${DEVSTRIDE_PLUGIN_UPDATE_CHECK:-1}" = "0" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
STDIN_JSON=$(cat 2>/dev/null | head -c 4000)
CWD=$(printf '%s' "$STDIN_JSON" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: print("")' 2>/dev/null)
CWD="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"

RUNNING=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]+"/.claude-plugin/plugin.json")).get("version",""))
except Exception: print("")' "$ROOT" 2>/dev/null)
[ -z "$RUNNING" ] && exit 0

read -r CHECK AUTO PIN <<EOF
$(python3 -c 'import json,sys
p={}
try: p=json.load(open(sys.argv[1]+"/.claude/ds-config.json")).get("plugin",{}) or {}
except Exception: pass
print("1" if p.get("updateCheck",True) else "0", "1" if p.get("autoUpdate",False) else "0", p.get("pin") or "-")' "$CWD" 2>/dev/null || echo "1 0 -")
EOF
[ "$CHECK" = "0" ] && exit 0

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/devstride-plugin"; mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE="$CACHE_DIR/version-check.json"
NOW=$(date +%s)
TTL=21600   # 6h: a release is rare; a session start is not.

NEWEST=""; SOURCE="cache"
if [ -f "$CACHE" ]; then
  read -r CACHED_AT CACHED_NEWEST <<EOF
$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1])); print(d.get("fetchedAt",0), d.get("newest",""))
except Exception: print("0", "")' "$CACHE" 2>/dev/null || echo "0 ")
EOF
  if [ -n "$CACHED_NEWEST" ] && [ $((NOW - ${CACHED_AT:-0})) -lt $TTL ]; then NEWEST="$CACHED_NEWEST"; fi
fi
if [ -z "$NEWEST" ]; then
  SOURCE="network"
  # Hard time cap: macOS has no `timeout`; perl's alarm is portable.
  NEWEST=$(perl -e 'alarm 5; exec @ARGV' git ls-remote --tags "${DEVSTRIDE_PLUGIN_REPO:-https://github.com/devstride/claude-plugin}" 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/tags/||' | grep -v '\^{}' | sed 's/.*--v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
fi

record() { # result mode
  python3 -c 'import json,sys,time
d={"checkedAt":int(time.time()),"running":sys.argv[2],"newest":sys.argv[3] or None,"source":sys.argv[4],"mode":sys.argv[5],"result":sys.argv[6]}
if sys.argv[3] and sys.argv[4]=="network": d["fetchedAt"]=d["checkedAt"]
else:
  try: d["fetchedAt"]=json.load(open(sys.argv[1])).get("fetchedAt",0)
  except Exception: d["fetchedAt"]=0
json.dump(d,open(sys.argv[1],"w"))' "$CACHE" "$RUNNING" "$NEWEST" "$SOURCE" "$1" "$2" 2>/dev/null
}
MODE="notify"; [ "$AUTO" = "1" ] && MODE="auto-update"; [ "$PIN" != "-" ] && MODE="pinned"

if [ -z "$NEWEST" ]; then record "$MODE" "unreachable"; exit 0; fi           # offline: quiet; doctor shows it
if [ "$(printf '%s\n%s\n' "$RUNNING" "$NEWEST" | sort -V | tail -1)" = "$RUNNING" ]; then
  record "$MODE" "current"; exit 0                                            # current: silent
fi

if [ "$PIN" != "-" ]; then
  record pinned "behind-pinned"
  echo "devstride plugin: pinned at $PIN (this session runs $RUNNING); newest release is $NEWEST."
  exit 0
fi

# The installed id is whichever marketplace entry this machine installed through (devstride@… or
# ds@…), per scope — read it, never assume it: naming the other reports "not installed".
IDS=$(claude plugin list --json 2>/dev/null | python3 -c 'import json,sys
try:
  for e in json.load(sys.stdin):
    if str(e.get("id","")).endswith("@devstride"): print(e["id"], e.get("scope","user"))
except Exception: pass' 2>/dev/null)
[ -z "$IDS" ] && IDS="devstride@devstride user"

if [ "$AUTO" = "1" ]; then
  OK=1
  claude plugin marketplace update devstride >/dev/null 2>&1 || OK=0
  while read -r ID SCOPE; do [ -n "$ID" ] && { claude plugin update "$ID" --scope "$SCOPE" >/dev/null 2>&1 || OK=0; }; done <<EOF
$IDS
EOF
  if [ "$OK" = "1" ]; then
    record auto-update "updated"
    echo "devstride plugin: updated on disk $RUNNING → $NEWEST. This session still runs $RUNNING — restart to pick it up."
    exit 0
  fi
  record auto-update "update-failed"
fi

record "$MODE" "behind"
FIRST=$(printf '%s\n' "$IDS" | head -1); ID=${FIRST%% *}; SCOPE=${FIRST#* }
echo "devstride plugin: $RUNNING running, $NEWEST available. To update (both commands, then restart):"
echo "  claude plugin marketplace update devstride && claude plugin update $ID --scope $SCOPE"
exit 0
