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

# No label may be left dangling: a segment symbol followed by the separator or the
# end of a line means a segment rendered with nothing in it. This is the invariant
# the whole seg() mechanism exists to hold, so it is asserted on every case below.
no_dangling() { printf '%s\n' "$1" | perl -Mutf8 -CS -ne 'exit 1 if /[◆↯▣⑂⎇⊞☻▲⇄⚑](?: ·|\s*$)/'; }

R="$(mkrepo plain '{}')"

# (1) the ordinary case: every segment that has a value, in order, separated by ·
O="$(render "$R" ',"model":{"display_name":"Opus 5"}')"
if [ "$O" = "◆ Opus 5 · ▣ plain · ⑂ main · ⎇ main" ] && no_dangling "$O"; then
  ok "(1) full line: Model · Repo · Checkout · Branch, no Stage/PR/Effort to show"
else bad "(1) got: $O"; fi

# (2) a missing value drops its segment AND its separator — no leading " · "
O="$(render "$R")"
if [ "$O" = "▣ plain · ⑂ main · ⎇ main" ] && no_dangling "$O"; then
  ok "(2) no model in the payload → no Model segment and no orphan separator"
else bad "(2) got: $O"; fi

# (3) the regression this file exists for: a label is never printed empty
O="$(render "$R" ',"model":{"display_name":""}')"
if no_dangling "$O" && ! printf '%s' "$O" | grep -q '◆'; then
  ok "(3) an empty display_name renders no '◆' label at all"
else bad "(3) got: $O"; fi

# (4) hiddenSegments suppresses a segment that WOULD have rendered
H="$(mkrepo hidden '{"statusLine":{"hiddenSegments":["checkout","model"]}}')"
O="$(render "$H" ',"model":{"display_name":"Opus 5"}')"
if [ "$O" = "▣ hidden · ⎇ main" ] && no_dangling "$O"; then
  ok "(4) hiddenSegments [checkout, model] → both gone, the rest still joined correctly"
else bad "(4) got: $O"; fi

# (5) an unknown key in hiddenSegments is inert, not fatal
O="$(render "$(mkrepo unknownkey '{"statusLine":{"hiddenSegments":["nosuchsegment"]}}')")"
if [ "$O" = "▣ unknownkey · ⑂ main · ⎇ main" ]; then
  ok "(5) an unrecognized hiddenSegments entry changes nothing"
else bad "(5) got: $O"; fi

# (6) not a git repo: the message, and nothing dangling before it
mkdir -p "$WORK/nogit"
O="$(render "$WORK/nogit" ',"model":{"display_name":"Opus 5"}')"
if [ "$O" = "◆ Opus 5 · —not a git repo—" ] && no_dangling "$O"; then
  ok "(6) outside a repo → Model · —not a git repo—"
else bad "(6) got: $O"; fi

# (7) detached HEAD renders the sha; the "(detached)" suffix never appears alone
D="$(mkrepo detached '{}')"; git -C "$D" checkout -q --detach HEAD
O="$(render "$D")"
if printf '%s' "$O" | grep -qE '⎇ [0-9a-f]+ \(detached\)' && no_dangling "$O"; then
  ok "(7) detached HEAD → '⎇ <sha> (detached)', never a bare '(detached)'"
else bad "(7) got: $O"; fi

# (8) stage.resolve drives the Stage segment; a resolve printing nothing shows none
S="$(mkrepo staged '{"stage":{"resolve":"echo my-stage","productionStages":["prod"]}}')"
O="$(render "$S")"
N="$(render "$(mkrepo unstaged '{"stage":{"resolve":"true"}}')")"
if printf '%s' "$O" | grep -q '▲ my-stage' && ! printf '%s' "$N" | grep -q '▲' && no_dangling "$N"; then
  ok "(8) stage.resolve with output → Stage; resolve printing nothing → no Stage label"
else bad "(8) got: $O | $N"; fi

# (9) a production stage is still just one segment (the colour differs, stripped here)
O="$(render "$(mkrepo prodstage '{"stage":{"resolve":"echo prod","productionStages":["prod"]}}')")"
if printf '%s' "$O" | grep -q '▲ prod'; then
  ok "(9) a stage named in productionStages renders normally (red, stripped in test)"
else bad "(9) got: $O"; fi

# (10) the config is found from a SUBDIRECTORY, not just the repo root
mkdir -p "$H/packages/web"
O="$(render "$H/packages/web" ',"model":{"display_name":"Opus 5"}')"
if [ "$O" = "▣ hidden · ⎇ main" ]; then
  ok "(10) config resolved by walking up from packages/web — hiddenSegments still applied"
else bad "(10) got: $O"; fi

# (11) unparsable config is tolerated: a status line must never be what breaks
B="$(mkrepo broken 'not json at all')"
O="$(render "$B")"
if [ "$O" = "▣ broken · ⑂ main · ⎇ main" ]; then
  ok "(11) a corrupt ds-config.json degrades to the default segments, no error"
else bad "(11) got: $O"; fi

# (12) a linked worktree renders ⑂ <worktree> and names the REPO, not the worktree dir
git -C "$R" worktree add -q "$WORK/wt-feature" -b feature 2>/dev/null
O="$(render "$WORK/wt-feature")"
if printf '%s' "$O" | grep -q '▣ plain' && printf '%s' "$O" | grep -q '⑂ wt-feature'; then
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
if printf '%s' "$O" | grep -q '⇄ #412 open' && printf '%s' "$O2" | grep -q '⇄ #412' && no_dangling "$O2"; then
  ok "(13) PR from cache renders '#412 open'; a truncated line renders '#412' with no empty state"
else bad "(13) got: $O | $O2"; fi

# (14) the managed marker is present and carries a version — the session-start
#      hook keys its refresh on exactly this line
if head -3 "$SL" | grep -qE '^# ds-statusline: managed v[0-9]+\.[0-9]+\.[0-9]+ '; then
  ok "(14) the shipped file carries its 'ds-statusline: managed v<x.y.z>' marker"
else bad "(14) marker line missing or malformed"; fi

# (15) nothing renders in ANSI bright black (90). Themes are free to set that
#      slot AT the background - most put comment text there - so a value in it
#      can come out invisible while its DIM label still renders, which reads as
#      a lookup that broke. The source check catches the paths this harness has
#      no fixture for (a draft PR, a low effort level); the render check catches
#      a colour reaching the terminal from anywhere at all.
RAW="$(printf '{"workspace":{"current_dir":"%s"}}' "$R" | bash "$SL" 2>/dev/null)"
if ! grep -q '\[90m' "$SL" && ! printf '%s' "$RAW" | grep -q $'\033\[90m'; then
  ok "(15) no segment uses ANSI bright black, which some themes render invisible"
else bad "(15) ANSI bright black (90) is back in the status line"; fi

# (16) the Release segment: a clearance provider's `status --short` line, served from the
#      cache like the PR segment; a stale clearance keeps its STALE marker; a null
#      release.clearance renders no Release label even with a cache file present
RL="$(mkrepo released '{"release":{"clearance":{"commands":{"status":"echo release/26-10-17 · alice · ci"}}}}')"
RTOP=$(git -C "$RL" rev-parse --show-toplevel)
rkey=$(printf '%s' "$RTOP" | (md5 -q 2>/dev/null || shasum | cut -d' ' -f1))
printf 'release/26-10-17 · alice · ci' > "$TMPDIR/ds-statusline-release-$rkey"
O="$(render "$RL")"
printf 'release/26-10-17 · alice · review · STALE' > "$TMPDIR/ds-statusline-release-$rkey"
O2="$(render "$RL")"
NL="$(mkrepo unreleased '{"release":{"clearance":null}}')"
nkey=$(printf '%s' "$(git -C "$NL" rev-parse --show-toplevel)" | (md5 -q 2>/dev/null || shasum | cut -d' ' -f1))
printf 'release/26-10-17 · alice · ci' > "$TMPDIR/ds-statusline-release-$nkey"
O3="$(render "$NL")"
if printf '%s' "$O" | grep -q '⚑ release/26-10-17 · alice · ci$' && printf '%s' "$O2" | grep -q '⚑ release/26-10-17 · alice · review · STALE$' \
   && ! printf '%s' "$O3" | grep -q '⚑' && no_dangling "$O3"; then
  ok "(16) Release segment from the provider's short line; STALE kept; null clearance → no Release label"
else bad "(16) got: $O | $O2 | $O3"; fi

# (17) the built-in provider is found through DEVSTRIDE_CLEARANCE_PROVIDER and refreshed in the
#      background: an empty cache renders nothing, and the next render shows the line
GH="$(mkrepo ghclear '{"release":{"clearance":{"provider":"github"}}}')"
printf '#!/bin/bash\n[ "$1 $2" = "status --short" ] && echo "release/26-10-18 · bob · pr"\n' > "$WORK/fake-provider.sh"
O="$(DEVSTRIDE_CLEARANCE_PROVIDER="$WORK/fake-provider.sh" render "$GH")"
gkey=$(printf '%s' "$(git -C "$GH" rev-parse --show-toplevel)" | (md5 -q 2>/dev/null || shasum | cut -d' ' -f1))
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMPDIR/ds-statusline-release-$gkey" ] && break; sleep 0.3; done
O2="$(DEVSTRIDE_CLEARANCE_PROVIDER="$WORK/fake-provider.sh" render "$GH")"
if ! printf '%s' "$O" | grep -q '⚑' && no_dangling "$O" && printf '%s' "$O2" | grep -q '⚑ release/26-10-18 · bob · pr$'; then
  ok "(17) provider github → resolved via DEVSTRIDE_CLEARANCE_PROVIDER, refreshed out of band, shown on the next render"
else bad "(17) got: $O | $O2"; fi

# (18) provider github with no provider anywhere → no segment, no error, nothing dangling
O="$(DEVSTRIDE_CLEARANCE_PROVIDER=/nonexistent CLAUDE_PLUGIN_ROOT=/nonexistent CLAUDE_CONFIG_DIR="$WORK/noclaude" render "$(mkrepo noprov '{"release":{"clearance":{"provider":"github"}}}')")"
if ! printf '%s' "$O" | grep -q '⚑' && no_dangling "$O" && [ -n "$O" ]; then
  ok "(18) provider github with no installed provider → the segment is simply absent"
else bad "(18) got: $O"; fi

# (19) the Plugin segment: the session-runtime record against the install that applies here. Red
#      "A → B · /reload-plugins" when the installed copy is newer than the loaded one, yellow
#      "A (B out · /devstride:update)" when a newer release is published, the running version
#      (dim) when current, nothing when the session has no record, and hidden by hiddenSegments.
export XDG_CACHE_HOME="$WORK/xdg" CLAUDE_CONFIG_DIR="$WORK/claude"; mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
PL="$(mkrepo pluginrepo '{}')"; PH="$(mkrepo pluginhidden '{"statusLine":{"hiddenSegments":["plugin"]}}')"
mkdir -p "$WORK/loaded/.claude-plugin"; printf '{"name":"devstride","version":"3.15.0"}' > "$WORK/loaded/.claude-plugin/plugin.json"
printf '{"session_id":"sl1","hook_event_name":"SessionStart"}' | CLAUDE_PLUGIN_ROOT="$WORK/loaded" python3 "$ROOT/hooks/session-runtime.py" record
printf '{"version":2,"plugins":{"devstride@devstride":[{"scope":"project","projectPath":"%s","installPath":"%s","version":"3.16.0"},{"scope":"project","projectPath":"%s","installPath":"%s","version":"3.16.0"}]}}' \
  "$PL" "$ROOT" "$PH" "$ROOT" > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
O="$(render "$PL" ',"session_id":"sl1"')"; OH="$(render "$PH" ',"session_id":"sl1"')"; ON="$(render "$PL" ',"session_id":"nosuch"')"
printf '{"session_id":"sl1","hook_event_name":"UserPromptSubmit"}' | CLAUDE_PLUGIN_ROOT="$WORK/loaded" python3 "$ROOT/hooks/session-runtime.py" record
sed -i.bak 's/"version":"3.16.0"/"version":"3.15.0"/g' "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
python3 -c 'import json,time; print(json.dumps({"schema":2,"source":"https://github.com/devstride/claude-plugin","newest":"3.16.1","fetchedAt":int(time.time())}))' > "$XDG_CACHE_HOME/devstride-plugin/newest.json"
OU="$(render "$PL" ',"session_id":"sl1"')"
rm -f "$XDG_CACHE_HOME/devstride-plugin/newest.json"; OC="$(render "$PL" ',"session_id":"sl1"')"
if printf '%s' "$O" | grep -q '⊞ 3.15.0 → 3.16.0 · /reload-plugins' && ! printf '%s' "$OH" | grep -q '⊞' \
   && ! printf '%s' "$ON" | grep -q '⊞' && printf '%s' "$OU" | grep -q '⊞ 3.15.0 (3.16.1 out · /devstride:update)' \
   && printf '%s' "$OC" | grep -q '^⊞ 3.15.0$' && no_dangling "$O" && no_dangling "$OU"; then
  ok "(19) Plugin segment: reload (red), update (yellow) and current (dim version) render on line 2; no record and hiddenSegments render none"
else bad "(19) got: $O | $OH | $ON | $OU | $OC"; fi
unset XDG_CACHE_HOME CLAUDE_CONFIG_DIR

# (20) two lines: where you are on line 1 (model, effort, repo, checkout, branch), what is in
#      flight on line 2 (plugin, stage, PR, release); line 2 is printed only when it has a value
O="$(render "$S" ',"model":{"display_name":"Opus 5"}')"
L1="$(printf '%s\n' "$O" | sed -n 1p)"; L2="$(printf '%s\n' "$O" | sed -n 2p)"; LN="$(printf '%s\n' "$O" | wc -l | tr -d ' ')"
ONE="$(render "$(mkrepo oneline '{}')")"
if [ "$LN" = 2 ] && [ "$L1" = "◆ Opus 5 · ▣ staged · ⑂ main · ⎇ main" ] && [ "$L2" = "▲ my-stage" ] \
   && [ "$(printf '%s\n' "$ONE" | wc -l | tr -d ' ')" = 1 ]; then
  ok "(20) line 1 = model · repo · checkout · branch; line 2 = stage; no line 2 when it would be empty"
else bad "(20) got [$O] / [$ONE]"; fi

# (21) the setting setup writes redraws every 30 seconds
if grep -qF '"refreshInterval": 30' "$ROOT/skills/setup/SKILL.md" && grep -qF '"refreshInterval": 30' "$ROOT/skills/doctor/references/repairs.md"; then
  ok "(21) setup and the doctor repair write statusLine.refreshInterval 30"
else bad "(21) refreshInterval 30 missing from the setup or doctor template"; fi

# (22) the Session segment: the payload's session_name; else the repository's session.nameCommand,
#      served from a cache under $TMPDIR and refreshed in the background with the payload's session
#      id exported; nothing (and no dangling ☻) without either; hidden by hiddenSegments; a failing
#      command prints nothing; nothing written to the repository or the working directory
SID=0b1c2d3e-0000-4000-8000-000000000001
N1="$(mkrepo sess1 '{}')"
A="$(render "$N1" ",\"session_id\":\"$SID\",\"session_name\":\"wt2-9f\"")"
B="$(render "$N1" ",\"session_id\":\"$SID\"")"
N2="$(mkrepo sess2 '{"session":{"nameCommand":"printf \"%s\\n%s\\n\" \"cmd-$CLAUDE_CODE_SESSION_ID\" extra; pwd > \"$TMPDIR/sess-pwd\""}}')"
BEFORE="$(git -C "$N2" status --porcelain --untracked-files=all)"
settled() { local n=0; until [ ! -d "$TMPDIR/ds-statusline-session-$1.lock" ] || [ $n -ge 50 ]; do sleep 0.1; n=$((n + 1)); done; }
C1="$(render "$N2" ",\"session_id\":\"$SID\"")"; settled "$SID"
C2="$(render "$N2" ",\"session_id\":\"$SID\"")"
CACHED="$(cat "$TMPDIR/ds-statusline-session-$SID" 2>/dev/null)"; RAN_IN="$(cat "$TMPDIR/sess-pwd" 2>/dev/null)"
P2="$(render "$N2" ",\"session_id\":\"$SID\",\"session_name\":\"named\"")"
N3="$(mkrepo sess3 '{"session":{"nameCommand":"echo nope; exit 3"},"statusLine":{}}')"
SID3=0b1c2d3e-0000-4000-8000-000000000003
render "$N3" ",\"session_id\":\"$SID3\"" >/dev/null; settled "$SID3"; D="$(render "$N3" ",\"session_id\":\"$SID3\"")"
N4="$(mkrepo sess4 '{"statusLine":{"hiddenSegments":["session"]}}')"
E="$(render "$N4" ",\"session_id\":\"$SID\",\"session_name\":\"wt2-9f\"")"
F="$(render "$WORK" ",\"session_id\":\"$SID\",\"session_name\":\"$(printf 'x|y')\"")"
DIRTY="$(git -C "$N2" status --porcelain --untracked-files=all)"
if printf '%s' "$A" | grep -q '☻ wt2-9f' && no_dangling "$A" && ! printf '%s' "$B" | grep -q '☻' && no_dangling "$B" \
   && printf '%s' "$C2" | grep -qE "☻ cmd-$SID( |\$)" && [ "$CACHED" = "cmd-$SID" ] && [ "$RAN_IN" = "$(cd "$N2" && pwd -P)" -o "$RAN_IN" = "$N2" ] \
   && printf '%s' "$P2" | grep -q '☻ named' && ! printf '%s' "$D" | grep -q '☻' && no_dangling "$D" \
   && ! printf '%s' "$E" | grep -q '☻' && printf '%s' "$F" | grep -q '☻ x y' && [ "$DIRTY" = "$BEFORE" ]; then
  ok "(22) Session: payload name; else nameCommand (first line, session id exported, run from the repo, cached under TMPDIR); none, failing or hidden → no segment; outside a repo too; repo left clean"
else bad "(22) a=$A | b=$B | c1=$C1 | c2=$C2 | cached=$CACHED | ran=$RAN_IN | p2=$P2 | d=$D | e=$E | f=$F | dirty=$DIRTY"; fi

# (22b) one refresh in flight per session: a nameCommand that hangs is not started again by a stale
#       redraw while its refresher lives; once it is gone, the next stale redraw runs it again, and a
#       lock left by a dead refresher is taken over; a hidden Session segment never runs the command.
#       Every process the case starts is stopped before it ends.
N5="$(mkrepo sess5 '{"session":{"nameCommand":"sh hang.sh"}}')"
printf 'echo $$ >> "$TMPDIR/hang-pids"; exec sleep 30\n' > "$N5/hang.sh"
N6="$(mkrepo sess6 '{"session":{"nameCommand":"sh ran.sh"},"statusLine":{"hiddenSegments":["session"]}}')"
printf 'echo ran > "$TMPDIR/hidden-ran"\n' > "$N6/ran.sh"
SID5=0b1c2d3e-0000-4000-8000-000000000005; SC5="$TMPDIR/ds-statusline-session-$SID5"
runs() { [ -f "$TMPDIR/hang-pids" ] && wc -l < "$TMPDIR/hang-pids" | tr -d ' ' || echo 0; }
until_runs() { local n=0; until [ "$(runs)" -ge "$1" ] || [ $n -ge 50 ]; do sleep 0.1; n=$((n + 1)); done; }
stale() { touch -t 202001010000 "$SC5"; }
render "$N6" ",\"session_id\":\"0b1c2d3e-0000-4000-8000-000000000006\"" >/dev/null
render "$N5" ",\"session_id\":\"$SID5\"" >/dev/null; until_runs 1
stale; render "$N5" ",\"session_id\":\"$SID5\"" >/dev/null; sleep 1; H1="$(runs)"
kill $(cat "$TMPDIR/hang-pids") 2>/dev/null; settled "$SID5"
stale; render "$N5" ",\"session_id\":\"$SID5\"" >/dev/null; until_runs 2; H2="$(runs)"
kill $(cat "$TMPDIR/hang-pids") 2>/dev/null; settled "$SID5"
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"; mkdir "$SC5.lock"; echo "$DEAD" > "$SC5.lock/pid"
stale; render "$N5" ",\"session_id\":\"$SID5\"" >/dev/null; until_runs 3; H3="$(runs)"
kill $(cat "$TMPDIR/hang-pids") 2>/dev/null; settled "$SID5"
if [ "$H1" = 1 ] && [ "$H2" = 2 ] && [ "$H3" = 3 ] && [ ! -e "$TMPDIR/hidden-ran" ]; then
  ok "(22b) Session refresh: a hung nameCommand is never started twice; rerun once it is gone; a dead refresher's lock is taken over; hidden → never run"
else bad "(22b) h1=$H1 h2=$H2 h3=$H3 hidden-ran=$([ -e "$TMPDIR/hidden-ran" ] && echo yes || echo no)"; fi

# (23) the payload's live model and effort reach the session record through the plugin copy the
#      status line loads, and a redraw with the same values rewrites nothing
export XDG_CACHE_HOME="$WORK/xdg" CLAUDE_CONFIG_DIR="$WORK/claude"
REC="$XDG_CACHE_HOME/devstride-plugin/sessions/sl1.json"
LIVE=',"session_id":"sl1","model":{"id":"claude-opus-5","display_name":"Opus 5"},"effort":{"level":"xhigh"}'
render "$PL" "$LIVE" >/dev/null
SEEN="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["model"]["id"], r["model"]["name"], r["effort"]["level"], r["running"])' "$REC" 2>&1)"
B0="$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino, s.st_mtime_ns)' "$REC")"
O="$(render "$PL" "$LIVE")"; B1="$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino, s.st_mtime_ns)' "$REC")"
VERDICT="$(python3 "$ROOT/hooks/session-runtime.py" models --role runner --session sl1 --repo "$PL" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')"
render "$PL" ',"session_id":"nosuch","model":{"id":"claude-opus-5"},"effort":{"level":"high"}' >/dev/null
if [ "$SEEN" = "claude-opus-5 Opus 5 xhigh 3.15.0" ] && [ "$B0" = "$B1" ] && [ "$VERDICT" = mismatch ] \
   && printf '%s' "$O" | grep -q '⊞ 3.15.0' && [ ! -e "$XDG_CACHE_HOME/devstride-plugin/sessions/nosuch.json" ]; then
  ok "(23) the status line notes the payload's model and effort in the session record; the same values → no rewrite; no record → none created"
else bad "(23) seen=$SEEN b0=$B0 b1=$B1 verdict=$VERDICT o=$O"; fi
unset XDG_CACHE_HOME CLAUDE_CONFIG_DIR

exit $FAIL
