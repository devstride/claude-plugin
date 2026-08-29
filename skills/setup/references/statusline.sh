#!/bin/bash
# ds-statusline: managed v3.1.1 — installed and kept up to date by the devstride
# plugin. DELETE THIS LINE to take ownership: the session-start hook only ever
# replaces a file that still carries it, and never touches one that does not.
#
# Claude Code status line for a repository running the DevStride delivery loop.
#
#   Model: Opus 5 · Effort: high · Repo: acme · Checkout: ⑂ i123-widget ·
#   Branch: phil/08-28-26/widget · Stage: phil-mac · PR: #412 draft
#
# `setup` copies this into the consuming repository as `.claude/statusline.sh`
# and points `statusLine.command` at it. It is deliberately repo-AGNOSTIC: every
# repository-specific fact it shows is read at runtime from that repository's
# own `.claude/ds-config.json`, so this file is identical everywhere and needs
# no substitution when it is copied.
#
# NO VALUE MEANS NO SEGMENT. Every segment is emitted through `seg`, which drops
# it when its guard is empty, so a fact this repository does not have never
# renders as a label with nothing after it ("Checkout:    "). A dangling label is
# worse than a missing one: it reads as a value that failed to load, and sends
# people looking for a break that is not there. `statusLine.hiddenSegments` in
# ds-config.json suppresses a segment that DOES resolve but is not wanted.
#
# Requires python3 (the plugin already does) and, for the PR segment, gh.

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
start = cwd or os.getcwd()
try:
    here = os.path.abspath(start)
    while True:
        candidate = os.path.join(here, ".claude", "ds-config.json")
        if os.path.isfile(candidate):
            with open(candidate) as fh:
                cfg = json.load(fh)
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
' 2>/dev/null
)"

[ -n "$SL_CWD" ] && cd "$SL_CWD" 2>/dev/null

# Colors
#
# NOTHING USES ANSI BRIGHT BLACK (90). It is the one palette slot themes are
# free to set AT the background - it is where most of them put comment text -
# so a value rendered in it can come out invisible while its DIM label still
# renders. That failure is worse than a wrong colour: "Checkout:" with nothing
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
# seg <key> <label> <guard> <body>
#   Appends "Label: body" only when <guard> is non-empty and <key> is not
#   suppressed. <guard> is the RAW value and <body> the rendered one, because a
#   rendered body is never empty - it always carries colour escapes - so testing
#   it would defeat the whole check.
out=""
seg() {
  [ -n "$3" ] || return 0
  case " $SL_HIDDEN " in *" $1 "*) return 0 ;; esac
  [ -n "$out" ] && out="$out ${DIM}·${RESET} "
  out="$out${DIM}${2}:${RESET} ${4}"
}

seg model "Model" "$SL_MODEL" "${BLUE}${SL_MODEL}${RESET}"

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
  seg effort "Effort" "$effort" "${ec}${effort}${RESET}"
fi

toplevel=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$toplevel" ]; then
  [ -n "$out" ] && out="$out ${DIM}·${RESET} "
  printf '%s' "${out}${DIM}—not a git repo—${RESET}"
  exit 0
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
  # Name the REPO in the Repo segment, not the worktree directory:
  # --show-toplevel points at the worktree, so basename would render the repo
  # as "i123-widget". That is actively misleading when the whole point of the
  # indicator is to say where you are.
  repo=$(basename "${gitdir%/.git/worktrees/*}")
else
  repo=$(basename "$toplevel")
fi

seg repo "Repo" "$repo" "${CYAN}${repo}${RESET}"

# ⑂ and yellow mark a linked worktree, because "you are not in the main
# checkout" is exactly what you want to notice before you commit. The main
# checkout stays dim so the loud colour keeps meaning the unusual case.
if [ -n "$worktree" ]; then
  seg checkout "Checkout" "$worktree" "${YELLOW}⑂ ${worktree}${RESET}"
else
  seg checkout "Checkout" "main" "${DIM}main${RESET}"
fi

# A detached HEAD with no commit yet resolves to no sha at all; rendering
# "Branch: (detached)" with nothing in front of it is the dangling label this
# file exists to avoid, so the fallback only applies when there IS a sha.
branch=$(git branch --show-current 2>/dev/null)
if [ -z "$branch" ]; then
  sha=$(git rev-parse --short HEAD 2>/dev/null)
  [ -n "$sha" ] && branch="$sha (detached)"
fi
seg branch "Branch" "$branch" "${GREEN}${branch}${RESET}"

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
  [ -f "$scache" ] && sage=$(( $(date +%s) - $(stat -f %m "$scache" 2>/dev/null || stat -c %Y "$scache" 2>/dev/null || echo 0) ))
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
  seg stage "Stage" "$stage" "${sc}${stage}${RESET}"
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
  age=$(( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0) ))
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
  # and render only the parts that resolved, rather than "PR: #412 ".
  body="${c}${link}${RESET}"
  [ -n "$state" ] && body="${c}${link} ${state}${RESET}"
  seg pr "PR" "$num" "$body"
fi

printf '%s' "$out"
