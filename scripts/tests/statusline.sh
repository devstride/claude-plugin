#!/bin/bash
# Tests for skills/setup/references/statusline.sh — the shipped status line.
# Everything runs in throwaway git repos under a private TMPDIR, so no cache,
# no repo and no gh call from these tests can touch the machine's real state.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SL="$ROOT/skills/setup/references/statusline.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"

# render CWD [JSON-EXTRAS] — run the status line and strip colour + OSC 8 so the
# assertions read as the text a user sees.
render() {
  local cwd="$1" extra="${2:-}"
  printf '{"workspace":{"current_dir":"%s"}%s}' "$cwd" "$extra" \
    | bash "$SL" 2>/dev/null \
    | perl -pe 's/\e\[[0-9;]*m//g; s/\e\]8;;[^\e]*\e\\//g'
}

mkrepo() { # mkrepo NAME [CONFIG-JSON] — a git repo with one commit, on branch main
  local d="$WORK/$1"; mkdir -p "$d/.claude"
  git -C "$d" init -q -b main 2>/dev/null || { git -C "$d" init -q; git -C "$d" checkout -q -b main 2>/dev/null; }
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  [ $# -ge 2 ] && printf '%s' "$2" > "$d/.claude/ds-config.json"
  printf '%s' "$d"
}

# No label may be left dangling: "Label:" followed by the separator or the end of
# the line means a segment rendered with nothing in it. This is the invariant the
# whole seg() mechanism exists to hold, so it is asserted on every case below.
no_dangling() { ! printf '%s' "$1" | grep -qE '[A-Za-z]+:( ·|[[:space:]]*$)'; }

R="$(mkrepo plain '{}')"

# (1) the ordinary case: every segment that has a value, in order, separated by ·
O="$(render "$R" ',"model":{"display_name":"Opus 5"}')"
if [ "$O" = "Model: Opus 5 · Repo: plain · Checkout: main · Branch: main" ] && no_dangling "$O"; then
  ok "(1) full line: Model · Repo · Checkout · Branch, no Stage/PR/Effort to show"
else bad "(1) got: $O"; fi

# (2) a missing value drops its segment AND its separator — no leading " · "
O="$(render "$R")"
if [ "$O" = "Repo: plain · Checkout: main · Branch: main" ] && no_dangling "$O"; then
  ok "(2) no model in the payload → no Model segment and no orphan separator"
else bad "(2) got: $O"; fi

# (3) the regression this file exists for: a label is never printed empty
O="$(render "$R" ',"model":{"display_name":""}')"
if no_dangling "$O" && ! printf '%s' "$O" | grep -q 'Model:'; then
  ok "(3) an empty display_name renders no 'Model:' label at all"
else bad "(3) got: $O"; fi

# (4) hiddenSegments suppresses a segment that WOULD have rendered
H="$(mkrepo hidden '{"statusLine":{"hiddenSegments":["checkout","model"]}}')"
O="$(render "$H" ',"model":{"display_name":"Opus 5"}')"
if [ "$O" = "Repo: hidden · Branch: main" ] && no_dangling "$O"; then
  ok "(4) hiddenSegments [checkout, model] → both gone, the rest still joined correctly"
else bad "(4) got: $O"; fi

# (5) an unknown key in hiddenSegments is inert, not fatal
O="$(render "$(mkrepo unknownkey '{"statusLine":{"hiddenSegments":["nosuchsegment"]}}')")"
if [ "$O" = "Repo: unknownkey · Checkout: main · Branch: main" ]; then
  ok "(5) an unrecognized hiddenSegments entry changes nothing"
else bad "(5) got: $O"; fi

# (6) not a git repo: the message, and nothing dangling before it
mkdir -p "$WORK/nogit"
O="$(render "$WORK/nogit" ',"model":{"display_name":"Opus 5"}')"
if [ "$O" = "Model: Opus 5 · —not a git repo—" ] && no_dangling "$O"; then
  ok "(6) outside a repo → Model · —not a git repo—"
else bad "(6) got: $O"; fi

# (7) detached HEAD renders the sha; the "(detached)" suffix never appears alone
D="$(mkrepo detached '{}')"; git -C "$D" checkout -q --detach HEAD
O="$(render "$D")"
if printf '%s' "$O" | grep -qE 'Branch: [0-9a-f]+ \(detached\)' && no_dangling "$O"; then
  ok "(7) detached HEAD → 'Branch: <sha> (detached)', never a bare '(detached)'"
else bad "(7) got: $O"; fi

# (8) stage.resolve drives the Stage segment; a resolve printing nothing shows none
S="$(mkrepo staged '{"stage":{"resolve":"echo my-stage","productionStages":["prod"]}}')"
O="$(render "$S")"
N="$(render "$(mkrepo unstaged '{"stage":{"resolve":"true"}}')")"
if printf '%s' "$O" | grep -q 'Stage: my-stage' && ! printf '%s' "$N" | grep -q 'Stage:' && no_dangling "$N"; then
  ok "(8) stage.resolve with output → Stage; resolve printing nothing → no Stage label"
else bad "(8) got: $O | $N"; fi

# (9) a production stage is still just one segment (the colour differs, stripped here)
O="$(render "$(mkrepo prodstage '{"stage":{"resolve":"echo prod","productionStages":["prod"]}}')")"
if printf '%s' "$O" | grep -q 'Stage: prod'; then
  ok "(9) a stage named in productionStages renders normally (red, stripped in test)"
else bad "(9) got: $O"; fi

# (10) the config is found from a SUBDIRECTORY, not just the repo root
mkdir -p "$H/packages/web"
O="$(render "$H/packages/web" ',"model":{"display_name":"Opus 5"}')"
if [ "$O" = "Repo: hidden · Branch: main" ]; then
  ok "(10) config resolved by walking up from packages/web — hiddenSegments still applied"
else bad "(10) got: $O"; fi

# (11) unparsable config is tolerated: a status line must never be what breaks
B="$(mkrepo broken 'not json at all')"
O="$(render "$B")"
if [ "$O" = "Repo: broken · Checkout: main · Branch: main" ]; then
  ok "(11) a corrupt ds-config.json degrades to the default segments, no error"
else bad "(11) got: $O"; fi

# (12) a linked worktree renders ⑂ <worktree> and names the REPO, not the worktree dir
git -C "$R" worktree add -q "$WORK/wt-feature" -b feature 2>/dev/null
O="$(render "$WORK/wt-feature")"
if printf '%s' "$O" | grep -q 'Repo: plain' && printf '%s' "$O" | grep -q 'Checkout: ⑂ wt-feature'; then
  ok "(12) linked worktree → Repo stays 'plain', Checkout shows ⑂ wt-feature"
else bad "(12) got: $O"; fi

# (13) the PR segment comes from the cache, and a truncated cache line renders no
#      trailing empty state — the same dangling-label bug in the PR's own fields
#      The key is built from git's OWN toplevel, which on macOS resolves the
#      /var -> /private/var symlink; hashing $R would key a file nothing reads.
TOP=$(git -C "$R" rev-parse --show-toplevel)
key=$(printf '%s@%s' "$TOP" "main" | (md5 -q 2>/dev/null || shasum | cut -d' ' -f1))
printf '#412|open|https://example.test/pr/412' > "$TMPDIR/ds-statusline-pr-$key"
O="$(render "$R")"
printf '#412' > "$TMPDIR/ds-statusline-pr-$key"
O2="$(render "$R")"
if printf '%s' "$O" | grep -q 'PR: #412 open' && printf '%s' "$O2" | grep -q 'PR: #412' && no_dangling "$O2"; then
  ok "(13) PR from cache renders '#412 open'; a truncated line renders '#412' with no empty state"
else bad "(13) got: $O | $O2"; fi

# (14) the managed marker is present and carries a version — the session-start
#      hook keys its refresh on exactly this line
if head -3 "$SL" | grep -qE '^# ds-statusline: managed v[0-9]+\.[0-9]+\.[0-9]+ '; then
  ok "(14) the shipped file carries its 'ds-statusline: managed v<x.y.z>' marker"
else bad "(14) marker line missing or malformed"; fi

exit $FAIL
