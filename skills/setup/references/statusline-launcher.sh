#!/bin/bash
# ds-statusline-launcher: managed v1 — installed and kept up to date by the devstride
# plugin. DELETE THIS LINE to take ownership: the session-start hook only ever
# replaces a file that still carries it, and never touches one that does not.
#
# Claude Code status line for a repository running the DevStride delivery loop.
#
# This file draws nothing itself. `setup` writes it into the repository as
# `.claude/statusline.sh`; on every redraw it finds the devstride plugin THIS session has
# loaded and runs the status line that copy ships (skills/setup/references/statusline.sh),
# with the same payload on stdin. So the bar always matches the loaded plugin, and a plugin
# release never changes a file in this repository.
#
# Where the plugin is looked for, first hit wins:
#   1. the session's own record, which the loaded plugin's hooks write at every session start
#      and every prompt (${XDG_CACHE_HOME:-~/.cache}/devstride-plugin/sessions/<session id>.json)
#      — after an update and /reload-plugins, the next prompt moves the bar to the new version;
#   2. $CLAUDE_PLUGIN_ROOT;
#   3. the Claude Code plugin registry: the install recorded for this repository (local, then
#      project scope; another repository's is never used), else the user's, else a managed
#      one. Among installs of one scope, the one recorded for this very checkout comes first,
#      then the highest version, then the path that sorts first. This lookup starts python3, so
#      its answer is kept for a minute beside the session record.
# Nothing found, or the plugin's script printed nothing: a plain directory-and-branch line.
# It never prints an error and never exits non-zero.
#
# `--which` prints the plugin copy it would run, and nothing when it finds none: the one way to
# tell the plugin's bar from the plain line, whatever segments a repository shows.
#
# The record and the kept answer name a script this file then RUNS, so both are read only when
# the sessions directory and the file itself are this user's own, are not symbolic links and
# are writable by nobody else. Anything else is ignored and the next source is tried.

input=$(cat)
rel="skills/setup/references/statusline.sh"
sessions="${XDG_CACHE_HOME:-$HOME/.cache}/devstride-plugin/sessions"

sid=""; re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-][A-Za-z0-9._-]*)"'
[[ $input =~ $re ]] && [ "${#BASH_REMATCH[1]}" -le 128 ] && sid="${BASH_REMATCH[1]}"

# trusted [FILE] — the sessions directory, and FILE when given, pass the rule above. The
# ownership and link tests are the shell's own; the permission bits cost one `ls`.
trusted() {
  [ -d "$sessions" ] && [ ! -L "$sessions" ] && [ -O "$sessions" ] || return 1
  if [ $# -gt 0 ]; then [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1; fi
  local listing mode rest
  listing=$(ls -ldn "$sessions" "$@" 2>/dev/null) || return 1
  [ -n "$listing" ] || return 1
  while IFS=' ' read -r mode rest; do
    case "$mode" in ?????w*|????????w*) return 1 ;; esac
  done <<<"$listing"
  return 0
}

# 1. The session's record, read without a JSON parser. Only a path that JSON had to escape
#    (a non-ASCII directory) starts python3, here, so it still comes before every other source.
root=""; line=""
if [ -n "$sid" ] && trusted "$sessions/$sid.json"; then
  { IFS= read -r line <"$sessions/$sid.json"; } 2>/dev/null
  case "$line" in *'"root":"'*) root="${line#*\"root\":\"}"; root="${root%%\"*}" ;; esac
  case "$root" in
    *\\*) root=$(python3 -c 'import json, sys
with open(sys.argv[1]) as handle:
    value = json.load(handle).get("root")
sys.stdout.write(value if isinstance(value, str) else "")' "$sessions/$sid.json" 2>/dev/null) ;;
  esac
  [ -n "$root" ] && [ -f "$root/$rel" ] || root=""
fi

# 2. The environment.
if [ -z "$root" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/$rel" ]; then
  root="$CLAUDE_PLUGIN_ROOT"
fi

# 3. The plugin registry. Skipped outright when it names no devstride plugin, so a machine
#    without the plugin starts nothing here.
if [ -z "$root" ]; then
  registry="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
  listed=""; [ -f "$registry" ] && { listed=$(<"$registry"); } 2>/dev/null
  case "$listed" in
    *'@devstride"'*)
      now=$(date +%s 2>/dev/null); case "$now" in ''|*[!0-9]*) now=0 ;; esac
      hit=""; at=""; cached=""
      if [ -n "$sid" ] && trusted "$sessions/$sid.root"; then
        { { IFS= read -r at; IFS= read -r cached; } <"$sessions/$sid.root"; } 2>/dev/null
        # Digits only, short enough for arithmetic, read as base 10 (a leading 0 is not octal).
        case "$at" in ''|*[!0-9]*) at=0 ;; esac
        [ "${#at}" -le 12 ] || at=0
        age=$(( 10#$now - 10#$at ))
        if [ "$age" -ge 0 ] && [ "$age" -lt 60 ] && { [ -z "$cached" ] || [ -f "$cached/$rel" ]; }; then
          hit=1; root="$cached"
        fi
      fi
      if [ -z "$hit" ] && command -v python3 >/dev/null 2>&1; then
        root=$(printf '%s' "$input" | python3 -c '
import json, os, sys

rel, registry = sys.argv[1:3]

def load(path):
    try:
        with open(path) as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}

def checkout(start):
    """(top directory, shared git directory) of the checkout holding `start`; every linked
    worktree of one repository shares the second."""
    try:
        here = os.path.realpath(start)
        while True:
            dot = os.path.join(here, ".git")
            if os.path.isdir(dot):
                return here, os.path.realpath(dot)
            if os.path.isfile(dot):
                with open(dot) as handle:
                    text = handle.readline().strip()
                if not text.startswith("gitdir:"):
                    return here, None
                gitdir = os.path.normpath(os.path.join(here, text[7:].strip()))
                link = os.path.join(gitdir, "commondir")
                if os.path.isfile(link):
                    with open(link) as handle:
                        gitdir = os.path.normpath(os.path.join(gitdir, handle.readline().strip()))
                return here, os.path.realpath(gitdir)
            parent = os.path.dirname(here)
            if parent == here:
                return None, None
            here = parent
    except Exception:
        return None, None

def number(value):
    try:
        return tuple(-int(part) for part in str(value).split("."))
    except Exception:
        return (1,)

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}
if not isinstance(payload, dict):
    payload = {}

workspace = payload.get("workspace") if isinstance(payload.get("workspace"), dict) else {}
top, mine = checkout(workspace.get("current_dir") or payload.get("cwd") or os.getcwd())
order = {"local": 0, "project": 1, "user": 2, "managed": 3}
rows = {}
plugins = load(registry).get("plugins")
for key in ("devstride@devstride", "ds@devstride"):
    for row in (plugins.get(key) if isinstance(plugins, dict) else None) or []:
        if not isinstance(row, dict):
            continue
        scope, path, elsewhere = row.get("scope"), row.get("installPath"), 1
        if not (isinstance(path, str) and path and os.path.isfile(os.path.join(path, rel))):
            continue
        if scope in ("local", "project"):
            project = row.get("projectPath")
            there = checkout(project) if isinstance(project, str) else (None, None)
            if not (mine and there[1] == mine):
                continue
            elsewhere = 0 if there[0] == top else 1
        rank = (order.get(scope, 4) if isinstance(scope, str) else 4, elsewhere, number(row.get("version")), path)
        rows[path] = min(rank, rows.get(path, rank))
sys.stdout.write(min(rows.values())[3] if rows else "")
' "$rel" "$registry" 2>/dev/null)
        [ -n "$root" ] && [ -f "$root/$rel" ] || root=""
        # Keep the answer: only in a directory that passes the rule, through a temporary file
        # that is created new (never written through a link someone left there).
        if [ -n "$sid" ]; then
          {
            (umask 077; mkdir -p "$sessions")
            if trusted; then
              rm -f "$sessions/$sid.root.$$"
              (umask 077; set -C; printf '%s\n%s\n' "$now" "$root" >"$sessions/$sid.root.$$") \
                && mv -f "$sessions/$sid.root.$$" "$sessions/$sid.root"
            fi
          } 2>/dev/null
        fi
      fi
      ;;
  esac
fi

if [ "${1:-}" = "--which" ]; then
  [ -n "$root" ] && printf '%s\n' "$root"
  exit 0
fi

if [ -n "$root" ]; then
  out=$(printf '%s' "$input" | CLAUDE_PLUGIN_ROOT="$root" bash "$root/$rel" 2>/dev/null)
  if [ -n "$out" ]; then printf '%s' "$out"; exit 0; fi
fi

# The plain line: the directory and its branch, in the full bar's own symbols.
cwd=""; re='"current_dir"[[:space:]]*:[[:space:]]*"([^"\\]+)"'
[[ $input =~ $re ]] && cwd="${BASH_REMATCH[1]}"
if [ -z "$cwd" ]; then
  re='"cwd"[[:space:]]*:[[:space:]]*"([^"\\]+)"'
  [[ $input =~ $re ]] && cwd="${BASH_REMATCH[1]}"
fi
[ -d "$cwd" ] || cwd="$PWD"
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
printf '\033[2m▣\033[0m %s' "${cwd##*/}"
[ -n "$branch" ] && printf ' \033[2m·\033[0m \033[2m⎇\033[0m %s' "$branch"
exit 0
