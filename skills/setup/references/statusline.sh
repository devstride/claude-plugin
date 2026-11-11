#!/bin/bash
# Claude Code status line for a repository running the DevStride delivery loop.
#
# It runs FROM THE PLUGIN, never from a copy: a repository's `.claude/statusline.sh` is the
# launcher beside this file (statusline-launcher.sh), which runs this script from the plugin
# version the session has loaded. So this file carries no "managed" marker and must never
# assume where it lives: everything about the repository comes from the payload's directory.
#
# Two lines, each segment led by a one-character symbol instead of a word:
#
#   ◆ Opus 5 · ↯ high · ▣ acme · ⑂ i123-widget · ⎇ phil/26-08-28/widget
#   ⊞ 3.16.0 · ☻ blue-fox · ▲ phil-mac · ⇄ #412 draft · ⚑ release/26-10-17 · alice · ci
#
#   ◆ model   ↯ effort   ▣ repository   ⑂ checkout (a worktree's name, or main)   ⎇ branch
#   ⊞ devstride plugin this session runs   ☻ this session's name   ▲ stage   ⇄ pull request
#   ⚑ release in flight
#
# The plugin segment is dim while current, and loud while this session runs an older plugin than
# it could:
#   ⊞ 3.15.0 → 3.16.0 · /reload-plugins        (red: the newer copy is installed, not loaded)
#   ⊞ 3.16.0 (3.16.1 out · /devstride:update)  (yellow: a newer release is published)
# The second line is printed only when one of its segments has a value.
#
# `statusLine.refreshInterval` (30 seconds, as setup writes it) redraws the bar on a timer as well
# as on Claude Code's own events, so an update installed or published mid-session shows within
# half a minute.
#
# It is deliberately repo-AGNOSTIC: every repository-specific fact it shows is read at
# runtime from that repository's own `.claude/ds-config.json`.
#
# NO VALUE MEANS NO SEGMENT. Every segment is emitted through `seg`, which drops
# it when its guard is empty, so a fact this repository does not have never
# renders as a symbol with nothing after it ("⑂    "). A dangling label is
# worse than a missing one: it reads as a value that failed to load, and sends
# people looking for a break that is not there. `statusLine.hiddenSegments` in
# ds-config.json suppresses a segment that DOES resolve but is not wanted.
#
# Requires python3 (the plugin already does) and, for the PR and Release segments, gh.

input=$(cat)

# --- one JSON pass ---------------------------------------------------------
# The status-line payload and the repo config are both read here, in a single
# python3 invocation, because process startup dominates the cost of rendering a
# status line: two parsers is twice the latency for the same answers.
eval "$(
  printf '%s' "$input" | python3 -c '
import json, os, shlex, sys

def emit(k, v):
    print("%s=%s" % (k, shlex.quote(str(v or ""))))

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

cwd = (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or ""
emit("SL_CWD", cwd)
emit("SL_MODEL", (d.get("model") or {}).get("display_name"))
emit("SL_TRANSCRIPT", d.get("transcript_path"))

# Claude may be working in a SUBDIRECTORY of the repo, so walk up looking for
# the config rather than checking cwd alone - a status line that silently drops
# the Stage segment whenever you cd into backend/ is worse than no segment.
# Every failure is tolerated: a status line must never be the thing that breaks.
cfg = {}
cfg_root = ""
start = cwd or os.getcwd()
try:
    here = os.path.abspath(start)
    while True:
        candidate = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(candidate):
            with open(candidate) as fh:
                cfg = json.load(fh)
            cfg_root = here
            break
        parent = os.path.dirname(here)
        if parent == here:
            break
        here = parent
except Exception:
    cfg = {}
stage = cfg.get("stage") or {}
emit("SL_STAGE_RESOLVE", stage.get("resolve"))
emit("SL_PROD_STAGES", " ".join(stage.get("productionStages") or []))
# Segments the owner has confirmed do not apply here. A segment with no value is
# already dropped; this is for one that WOULD render and is not wanted.
sl = cfg.get("statusLine") or {}
emit("SL_HIDDEN", " ".join(str(x) for x in (sl.get("hiddenSegments") or [])))

# The session: its own name from the payload (present when it has a custom name or a title), else
# the `session.nameCommand` of the repository, run from the config directory (see the Session segment).
# The id only keys the cache file of that command, so anything but a plain id is dropped.
sid = str(d.get("session_id") or "")
emit("SL_SESSION_ID", sid if sid.replace("-", "").isalnum() else "")
def display(value):
    """One line, no control characters or `|`, at most 64 characters (never cut inside a character)."""
    if not isinstance(value, str):
        return ""
    return " ".join("".join(" " if ord(c) < 32 or ord(c) == 127 or c == "|" else c for c in value).split())[:64].strip()
emit("SL_SESSION_NAME", display(d.get("session_name")))
session_cfg = cfg.get("session") if isinstance(cfg.get("session"), dict) else {}
name_cmd = session_cfg.get("nameCommand")
emit("SL_SESSION_CMD", name_cmd if isinstance(name_cmd, str) and name_cmd.strip() else "")
emit("SL_CFG_ROOT", cfg_root)

# The installed copies of this plugin, from the Claude Code plugin registry (a status line runs
# outside any skill, so it cannot assume a plugin root). Read once; both lookups below use it.
def installed_roots():
    roots = [os.environ.get("CLAUDE_PLUGIN_ROOT") or ""]
    try:
        registry = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                                "plugins", "installed_plugins.json")
        with open(registry) as fh:
            rows = (json.load(fh).get("plugins") or {})
        for key in ("devstride@devstride", "ds@devstride"):
            for row in rows.get(key) or []:
                roots.append(row.get("installPath") or "")
    except Exception:
        pass
    return [root for root in roots if root]
roots = installed_roots()

# The plugin THIS session runs, against the install that applies here and the newest release:
# hooks/session-runtime.py (whose hooks, run by the loaded copy, record what was loaded; its check owns the
# rule) is imported in-process, so the verdict costs no second python start. "reload|A|B" or
# "update|A|B"; "current|A|" whenever the running version is known; nothing otherwise.
plugin_state = ""
if d.get("session_id"):
    for root in roots:
        helper = os.path.join(root, "hooks", "session-runtime.py")
        if not os.path.isfile(helper):
            continue
        try:
            # Compiled from its source, never imported: an import would save a compiled copy
            # (hooks/__pycache__) inside the installed plugin, which the update check then counts
            # as a foreign file, and would read back any such copy found there.
            import types
            runtime = types.ModuleType("ds_session_runtime")
            runtime.__file__ = helper
            with open(helper, "rb") as source:
                exec(compile(source.read(), helper, "exec"), runtime.__dict__)
            verdict = runtime.check(d.get("session_id"), cwd or None)
            # The payload carries the live model and effort: note them in the same record (a write
            # only when one changed), for the skills that compare them with what the repository expects.
            if hasattr(runtime, "observe"):
                model = d.get("model") if isinstance(d.get("model"), dict) else {}
                effort = d.get("effort") if isinstance(d.get("effort"), dict) else {}
                runtime.observe(d.get("session_id"), model.get("id"), model.get("display_name"), effort.get("level"))
            if verdict.get("verdict") == "reload":
                plugin_state = "reload|%s|%s" % (verdict["running"], verdict["installed"])
            elif verdict.get("verdict") == "update":
                plugin_state = "update|%s|%s" % (verdict["running"], verdict["newest"])
            elif verdict.get("running"):
                plugin_state = "current|%s|" % verdict["running"]
        except Exception:
            plugin_state = ""
        break
emit("SL_PLUGIN", plugin_state)

# Release clearance (release.clearance): the command whose `status --short` names the
# release in flight, or nothing when the block is null. A repo-supplied provider is its
# own `commands.status`; a built-in one is the clearance-<provider>.sh the plugin ships, found
# through $DEVSTRIDE_CLEARANCE_PROVIDER, the loaded plugin ($CLAUDE_PLUGIN_ROOT), or the
# installed copy recorded in the Claude Code plugin registry (a status line runs outside
# any skill, so it cannot assume a plugin root). Nothing found → no segment, never an error.
clearance_cmd = ""
clearance = (cfg.get("release") or {}).get("clearance") or {}
if isinstance(clearance, dict) and clearance:
    commands = clearance.get("commands") or {}
    if isinstance(commands, dict) and commands.get("status"):
        clearance_cmd = str(commands["status"]) + " --short"
    elif clearance.get("provider") in ("github", "devstride"):
        rel = "skills/release/scripts/clearance-%s.sh" % clearance["provider"]
        candidates = [os.environ.get("DEVSTRIDE_CLEARANCE_PROVIDER") or ""]
        candidates += [os.path.join(root, rel) for root in roots]
        for candidate in candidates:
            if candidate and os.path.isfile(candidate):
                clearance_cmd = "bash " + shlex.quote(candidate) + " status --short"
                break
emit("SL_CLEARANCE_CMD", clearance_cmd)
' 2>/dev/null
)"

[ -n "$SL_CWD" ] && cd "$SL_CWD" 2>/dev/null

# Colors
#
# NOTHING USES ANSI BRIGHT BLACK (90). It is the one palette slot themes are
# free to set AT the background - it is where most of them put comment text -
# so a value rendered in it can come out invisible while its DIM label still
# renders. That failure is worse than a wrong colour: "⑂" with nothing
# after it reads as a lookup that broke, which is exactly the dangling label
# this file's header promises never to emit, and it is invisible to the person
# who chose the theme's author rather than the theme.
#
# So a value that is the UNREMARKABLE case is dimmed rather than coloured: DIM
# is an attribute applied to the theme's own foreground, so it cannot collide
# with the background, and a terminal that does not implement it falls back to
# full-brightness foreground - still legible. Colour is reserved for values
# worth looking at, which is what makes the coloured ones carry meaning.
RESET=$'\033[0m'; DIM=$'\033[2m'
CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
MAGENTA=$'\033[35m'; RED=$'\033[31m'; BLUE=$'\033[34m'

# OSC 8 hyperlink: ESC ] 8 ;; <url> ESC \  <text>  ESC ] 8 ;; ESC \
OSC8=$'\033]8;;'; OSC8_END=$'\033\\'

# --- segment assembly ------------------------------------------------------
# seg <line> <key> <symbol> <guard> <body>
#   Appends "symbol body" to line 1 or 2 only when <guard> is non-empty and
#   <key> is not suppressed. <guard> is the RAW value and <body> the rendered
#   one, because a rendered body is never empty - it always carries colour
#   escapes - so testing it would defeat the whole check. <key> stays the
#   segment's name in `statusLine.hiddenSegments`.
out=""; out2=""
seg() {
  [ -n "$4" ] || return 0
  case " $SL_HIDDEN " in *" $2 "*) return 0 ;; esac
  local piece="${DIM}${3}${RESET} ${5}"
  if [ "$1" = 2 ]; then
    [ -n "$out2" ] && out2="$out2 ${DIM}·${RESET} "; out2="$out2$piece"
  else
    [ -n "$out" ] && out="$out ${DIM}·${RESET} "; out="$out$piece"
  fi
}
# Line 2 only when it has something on it: a bare newline would be an empty row.
finish() { printf '%s' "$out"; [ -n "$out2" ] && printf '\n%s' "$out2"; exit 0; }

seg 1 model "◆" "$SL_MODEL" "${BLUE}${SL_MODEL}${RESET}"

# --- effort ----------------------------------------------------------------
# The status-line payload carries no effort field, and the persisted
# `effortLevel` is only the DEFAULT - unset while the level is "auto", and stale
# the moment /effort changes it for one session. The transcript is the reliable
# source: every `assistant` record carries a top-level "effort" holding the
# level that record was RESOLVED at, so the last one is the level in force, and
# "auto" renders as whatever auto actually chose rather than the word "auto".
#
# Read a bounded tail, not the whole file: transcripts reach megabytes, and
# effort appears on every assistant record, so 128K always holds recent ones. A
# tail slicing mid-line is harmless - the match is a short self-contained token,
# and no JSON parse is attempted on it.
effort=""
if [ -n "$SL_TRANSCRIPT" ] && [ -f "$SL_TRANSCRIPT" ]; then
  effort=$(tail -c 131072 "$SL_TRANSCRIPT" 2>/dev/null \
    | grep -o '"effort":"[a-z]*"' | tail -1 | cut -d'"' -f4)
fi
if [ -n "$effort" ]; then
  case "$effort" in
    max|xhigh) ec=$MAGENTA ;;
    high)      ec=$GREEN ;;
    medium)    ec=$YELLOW ;;
    *)         ec=$DIM ;;
  esac
  seg 1 effort "↯" "$effort" "${ec}${effort}${RESET}"
fi

# --- plugin: the devstride plugin this session runs -------------------------
# Dim while current. Red when a newer copy is INSTALLED but this session has not loaded it
# (/reload-plugins fixes it); yellow when this session runs the installed copy and a newer release
# is published. Silent whenever the running version cannot be read.
if [ -n "$SL_PLUGIN" ]; then
  IFS='|' read -r pverdict pfrom pto <<<"$SL_PLUGIN"
  case "$pverdict" in
    reload)  seg 2 plugin "⊞" "$pfrom" "${RED}${pfrom} → ${pto} · /reload-plugins${RESET}" ;;
    update)  seg 2 plugin "⊞" "$pfrom" "${YELLOW}${pfrom} (${pto} out · /devstride:update)${RESET}" ;;
    current) seg 2 plugin "⊞" "$pfrom" "${DIM}${pfrom}${RESET}" ;;
  esac
fi

# --- session: this session's name ---------------------------------------------
# The payload's session_name when the session has a custom name, else the first line of the
# repository's `session.nameCommand`, run from the config's directory with the payload's session id
# exported as CLAUDE_CODE_SESSION_ID. A status line redraws constantly and that command may start a
# runtime, so it is refreshed out of band (the PR segment's serve-the-cache shape, 10 s): the very
# first draw of a new session can lack the segment for a moment. Read-only: the cache and its lock
# under $TMPDIR are its only writes, never the plugin directory or the repository. Shown before the
# git checks, so it shows outside a repository too. A hidden segment never runs the command.
session="$SL_SESSION_NAME"
case " $SL_HIDDEN " in *" session "*) SL_SESSION_CMD="" ;; esac
if [ -z "$session" ] && [ -n "$SL_SESSION_CMD" ] && [ -n "$SL_SESSION_ID" ] && [ -n "$SL_CFG_ROOT" ]; then
  ncache="${TMPDIR:-/tmp}/ds-statusline-session-$SL_SESSION_ID"; nlock="$ncache.lock"
  nrefresh() {
    local name ntmp
    sh -c 'echo "$PPID"' >"$nlock/pid" 2>/dev/null
    name=$( (cd "$SL_CFG_ROOT" && CLAUDE_CODE_SESSION_ID="$SL_SESSION_ID" eval "$SL_SESSION_CMD") 2>/dev/null </dev/null ) || name=""
    if ntmp=$(mktemp "$ncache.XXXXXX" 2>/dev/null); then
      printf '%s' "$name" | python3 -c 'import sys
line = (sys.stdin.read().splitlines() or [""])[0]
sys.stdout.write(" ".join("".join(" " if ord(c) < 32 or ord(c) == 127 or c == "|" else c for c in line).split())[:64].strip())' >"$ntmp" 2>/dev/null
      mv -f "$ntmp" "$ncache" 2>/dev/null || rm -f "$ntmp"
    fi
    rm -rf "$nlock" 2>/dev/null
  }
  # One refresh in flight per session: a command that hangs keeps its lock, so no redraw starts a
  # second copy while its refresher lives (else one more would pile up every 10 s). The lock of a
  # refresher that is gone (its pid dead, or none written within 10 s) is taken over.
  nspawn() {
    touch "$ncache" 2>/dev/null
    if ! mkdir "$nlock" 2>/dev/null; then
      local npid; npid=$(cat "$nlock/pid" 2>/dev/null)
      if [ -n "$npid" ]; then
        kill -0 "$npid" 2>/dev/null && return 0
      elif [ $(( $(date +%s) - $(stat -c %Y "$nlock" 2>/dev/null || stat -f %m "$nlock" 2>/dev/null || echo 0) )) -lt 10 ]; then
        return 0
      fi
      rm -rf "$nlock" 2>/dev/null; mkdir "$nlock" 2>/dev/null || return 0
    fi
    (nrefresh &) >/dev/null 2>&1
  }
  if [ -f "$ncache" ]; then
    nage=$(( $(date +%s) - $(stat -c %Y "$ncache" 2>/dev/null || stat -f %m "$ncache" 2>/dev/null || echo 0) ))
    session=$(head -1 "$ncache" 2>/dev/null)
    [ "$nage" -ge 10 ] && nspawn
  else
    nspawn
  fi
fi
seg 2 session "☻" "$session" "${MAGENTA}${session}${RESET}"

toplevel=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$toplevel" ]; then
  [ -n "$out" ] && out="$out ${DIM}·${RESET} "
  out="${out}${DIM}—not a git repo—${RESET}"
  finish
fi

# --- checkout: main or a linked worktree -----------------------------------
# A linked worktree's git dir is <main-repo>/.git/worktrees/<name>; the main
# checkout's is just <main-repo>/.git. The PATH is the tell. Comparing
# --git-dir against --git-common-dir does not work: the main checkout returns a
# relative ".git" and a worktree an absolute path, so a string compare always
# reports "worktree".
gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null)
worktree=""
if [ "${gitdir}" != "${gitdir%/.git/worktrees/*}" ]; then
  worktree=$(basename "$toplevel")
  # Name the REPO in the repo segment, not the worktree directory:
  # --show-toplevel points at the worktree, so basename would render the repo
  # as "i123-widget". That is actively misleading when the whole point of the
  # indicator is to say where you are.
  repo=$(basename "${gitdir%/.git/worktrees/*}")
else
  repo=$(basename "$toplevel")
fi

seg 1 repo "▣" "$repo" "${CYAN}${repo}${RESET}"

# Yellow marks a linked worktree, because "you are not in the main checkout" is
# exactly what you want to notice before you commit. The main checkout stays
# dim so the loud colour keeps meaning the unusual case.
if [ -n "$worktree" ]; then
  seg 1 checkout "⑂" "$worktree" "${YELLOW}${worktree}${RESET}"
else
  seg 1 checkout "⑂" "main" "${DIM}main${RESET}"
fi

# A detached HEAD with no commit yet resolves to no sha at all; rendering
# "⎇ (detached)" with nothing in front of it is the dangling label this
# file exists to avoid, so the fallback only applies when there IS a sha.
branch=$(git branch --show-current 2>/dev/null)
if [ -z "$branch" ]; then
  sha=$(git rev-parse --short HEAD 2>/dev/null)
  [ -n "$sha" ] && branch="$sha (detached)"
fi
seg 1 branch "⎇" "$branch" "${GREEN}${branch}${RESET}"

# --- stage -----------------------------------------------------------------
# Only repositories that deploy per-environment infrastructure have a stage, so
# this is driven entirely by `stage.resolve` in the repo's config: a command
# whose stdout is the stage THIS checkout deploys to. No block, no command, no
# segment. Nothing is ever inferred from the branch name - a branch is not proof
# of what deploys, and rendering "prod" wrongly is worse than rendering nothing.
#
# The result is cached briefly: `resolve` may shell out to a CLI, and a status
# line re-renders far more often than a stage changes.
stage=""
if [ -n "$SL_STAGE_RESOLVE" ]; then
  skey=$(printf '%s' "$toplevel" | (md5 -q 2>/dev/null || shasum | cut -d' ' -f1))
  scache="${TMPDIR:-/tmp}/ds-statusline-stage-$skey"
  sage=99999
  [ -f "$scache" ] && sage=$(( $(date +%s) - $(stat -c %Y "$scache" 2>/dev/null || stat -f %m "$scache" 2>/dev/null || echo 0) ))
  if [ "$sage" -lt 10 ]; then
    stage=$(cat "$scache" 2>/dev/null)
  else
    stage=$( (cd "$toplevel" && eval "$SL_STAGE_RESOLVE") 2>/dev/null | head -1 | tr -d '[:space:]')
    printf '%s' "$stage" >"$scache" 2>/dev/null
  fi
fi
if [ -n "$stage" ]; then
  # Production is red because a stage indicator only earns its space if the
  # dangerous answer is impossible to skim past. Which stages are production is
  # the repo's to declare - `productionStages` - because no name is universal.
  sc=$CYAN
  for p in $SL_PROD_STAGES; do
    [ "$stage" = "$p" ] && sc=$RED && break
  done
  seg 2 stage "▲" "$stage" "${sc}${stage}${RESET}"
fi

# --- PR (cached, refreshed in the background) ------------------------------
# gh is a network call; rendering must never block on it. Serve the cache, and
# refresh out of band when it is stale.
key=$(printf '%s@%s' "$toplevel" "$branch" | (md5 -q 2>/dev/null || shasum | cut -d' ' -f1))
cache="${TMPDIR:-/tmp}/ds-statusline-pr-$key"
ttl=45

refresh() {
  gh pr view --json number,state,isDraft,url \
    --jq 'if .isDraft then "#\(.number)|draft|\(.url)" else "#\(.number)|\(.state|ascii_downcase)|\(.url)" end' \
    2>/dev/null >"$cache.tmp"
  mv -f "$cache.tmp" "$cache" 2>/dev/null
}
spawn_refresh() { touch "$cache" 2>/dev/null; (refresh &) >/dev/null 2>&1; }

pr=""
if [ -f "$cache" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0) ))
  pr=$(cat "$cache" 2>/dev/null)
  [ "$age" -ge "$ttl" ] && spawn_refresh
else
  : >"$cache"; spawn_refresh
fi

if [ -n "$pr" ]; then
  IFS='|' read -r num state url <<<"$pr"
  case "$state" in
    open)   c=$GREEN ;;
    merged) c=$MAGENTA ;;
    closed) c=$RED ;;
    draft)  c=$DIM ;;
    *)      c=$YELLOW ;;
  esac
  # OSC 8 makes the PR number clickable in terminals that support it; those that
  # do not simply print the text, so this degrades cleanly rather than emitting
  # escape garbage.
  if [ -n "$url" ]; then
    link="${OSC8}${url}${OSC8_END}${num}${OSC8}${OSC8_END}"
  else
    link="$num"
  fi
  # A truncated cache line can yield a number with no state; guard on the number
  # and render only the parts that resolved, rather than "⇄ #412 ".
  body="${c}${link}${RESET}"
  [ -n "$state" ] && body="${c}${link} ${state}${RESET}"
  seg 2 pr "⇄" "$num" "$body"
fi

# --- release clearance (cached, refreshed in the background) ----------------
# The release in flight for this repository, from the clearance provider's
# `status --short` (release.clearance): one line such as
# `release/26-10-17 · alice · ci`, a `close-out owed · …` line while this machine
# owes close-out work after a hand-back, or nothing.
# Network, so the same cache-and-refresh shape as the PR segment; a provider
# that fails prints nothing, and nothing renders — never an error in the bar.
if [ -n "$SL_CLEARANCE_CMD" ]; then
  rkey=$(printf '%s' "$toplevel" | (md5 -q 2>/dev/null || shasum | cut -d' ' -f1))
  rcache="${TMPDIR:-/tmp}/ds-statusline-release-$rkey"
  rrefresh() {
    # A provider that fails prints nothing here, whatever it wrote: the bar never shows an error.
    local line; line=$( (cd "$toplevel" && eval "$SL_CLEARANCE_CMD") 2>/dev/null ) || line=""
    printf '%s' "$line" | head -1 >"$rcache.tmp"
    mv -f "$rcache.tmp" "$rcache" 2>/dev/null
  }
  rspawn() { touch "$rcache" 2>/dev/null; (rrefresh &) >/dev/null 2>&1; }
  rel=""
  if [ -f "$rcache" ]; then
    rage=$(( $(date +%s) - $(stat -c %Y "$rcache" 2>/dev/null || stat -f %m "$rcache" 2>/dev/null || echo 0) ))
    rel=$(tr -d '[:space:]' <"$rcache" 2>/dev/null | head -c 1)
    [ -n "$rel" ] && rel=$(head -1 "$rcache" 2>/dev/null)
    [ "$rage" -ge "$ttl" ] && rspawn
  else
    : >"$rcache"; rspawn
  fi
  if [ -n "$rel" ]; then
    # A stale clearance (its session may be gone) or a stuck one (alive, not moving) is the
    # one worth noticing.
    case "$rel" in *STALE*|*STUCK*) rc=$RED ;; *) rc=$MAGENTA ;; esac
    seg 2 release "⚑" "$rel" "${rc}${rel}${RESET}"
  fi
fi

finish
