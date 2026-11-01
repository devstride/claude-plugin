#!/bin/bash
# Tests for the status-line half of hooks/version-check.sh — the session-start refresh of a
# repository's copied .claude/statusline.sh. The fake plugin omits the update helper, so the version
# half finishes quietly without network after the status-line result is recorded.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$ROOT/hooks/version-check.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export XDG_CACHE_HOME="$WORK/cache"

# A fake plugin root: the hook reads the RUNNING version and the shipped status line from it.
FAKE="$WORK/plugin"; mkdir -p "$FAKE/.claude-plugin" "$FAKE/skills/setup/references"
printf '{"version":"9.9.9"}' > "$FAKE/.claude-plugin/plugin.json"
shipped() { printf '# ds-statusline: managed v%s — marker\necho shipped-%s\n' "$1" "$1" > "$FAKE/skills/setup/references/statusline.sh"; }
shipped 2.8.0

mkrepo() { # mkrepo NAME [STATUSLINE-CONTENT] [CONFIG]
  local d="$WORK/$1" config="${3:-}"; mkdir -p "$d/.claude"; git -C "$d" -c init.defaultBranch=master init -q
  [ -n "${2:-}" ] && printf '%s' "$2" > "$d/.claude/statusline.sh"
  [ -n "$config" ] || config='{}'
  printf '%s' "$config" > "$d/.claude/ds-config.json"
  printf '%s' "$d"
}
run() { CLAUDE_PLUGIN_ROOT="$FAKE" bash "$HOOK" <<< "$(printf '{"cwd":"%s"}' "$1")" 2>/dev/null; }
managed() { printf '# ds-statusline: managed v%s — marker\necho local-%s\n' "$1" "$1"; }
bak() { printf '%s/.git/devstride/statusline.bak' "$1"; }   # the backup never lands in the work tree

# (1) an older managed copy is replaced, the previous one kept, and it is announced
R="$(mkrepo old "$(managed 2.7.0)")"
OUT="$(run "$R")"
if grep -q 'shipped-2.8.0' "$R/.claude/statusline.sh" && grep -q 'local-2.7.0' "$(bak "$R")" \
   && [ ! -e "$R/.claude/statusline.sh.bak" ] \
   && printf '%s' "$OUT" | grep -q 'status line: updated 2.7.0 → 2.8.0' \
   && printf '%s' "$OUT" | grep -qF "$(bak "$R")" && ! printf '%s' "$OUT" | grep -q 'Commit it'; then
  ok "(1) untracked managed v2.7.0 → replaced, backup in the git directory, no commit advice on the base branch"
else bad "(1) out=$OUT file=$(cat "$R/.claude/statusline.sh" 2>/dev/null)"; fi

# (1b) a later release can safely rotate an existing ordinary backup
shipped 2.9.0
OUT="$(run "$R")"
if grep -q 'shipped-2.9.0' "$R/.claude/statusline.sh" \
   && grep -q 'shipped-2.8.0' "$(bak "$R")" \
   && printf '%s' "$OUT" | grep -q 'status line: updated 2.8.0 → 2.9.0'; then
  ok "(1b) a later managed update rotates the existing safe .bak"
else bad "(1b) out=$OUT file=$(cat "$R/.claude/statusline.sh" 2>/dev/null)"; fi
shipped 2.8.0

# (2) an up-to-date copy is left alone and says nothing — silence is the contract
R="$(mkrepo current "$(managed 2.8.0)")"
OUT="$(run "$R")"
if grep -q 'local-2.8.0' "$R/.claude/statusline.sh" && [ ! -f "$(bak "$R")" ] \
   && ! printf '%s' "$OUT" | grep -q 'status line'; then
  ok "(2) an already-current copy is untouched and silent"
else bad "(2) out=$OUT"; fi

# (3) a NEWER local copy is never downgraded
R="$(mkrepo newer "$(managed 9.0.0)")"
run "$R" >/dev/null
if grep -q 'local-9.0.0' "$R/.claude/statusline.sh"; then
  ok "(3) a local copy newer than the shipped one is not rolled back"
else bad "(3) $(cat "$R/.claude/statusline.sh")"; fi

# (4) no marker = the owner took the file over; never touched, whatever the version
R="$(mkrepo owned '#!/bin/bash
echo my own status line')"
OUT="$(run "$R")"
if grep -q 'my own status line' "$R/.claude/statusline.sh" && [ ! -f "$(bak "$R")" ] \
   && ! printf '%s' "$OUT" | grep -q 'status line:'; then
  ok "(4) a file without the managed marker is never replaced — deleting the line opts out"
else bad "(4) out=$OUT"; fi

# (5) a repo with no status line never gets one created here
R="$(mkrepo none "")"
run "$R" >/dev/null
if [ ! -f "$R/.claude/statusline.sh" ]; then
  ok "(5) no status line present → none created; that needs consent, not a hook"
else bad "(5) a statusline.sh was created"; fi

# (6) statusLine.autoUpdate:false opts the repository out entirely
R="$(mkrepo optout "$(managed 2.7.0)" '{"statusLine":{"autoUpdate":false}}')"
run "$R" >/dev/null
if grep -q 'local-2.7.0' "$R/.claude/statusline.sh"; then
  ok "(6) statusLine.autoUpdate:false → the old copy is kept"
else bad "(6) it was updated anyway"; fi

# (7) the outcome is recorded, so doctor can report what the last session start did
R="$(mkrepo recorded "$(managed 2.7.0)")"
run "$R" >/dev/null
# The record is keyed on the hook's OWN repo path — git's toplevel, which resolves the
# macOS /var -> /private/var symlink; globbing for "some recent record" would pick up another
# case's file and assert against the wrong repository.
TOP=$(git -C "$R" rev-parse --show-toplevel)
KEY=$(printf '%s' "$TOP" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:12])')
REC="$XDG_CACHE_HOME/devstride-plugin/repo-$KEY.json"
if [ -n "$REC" ] && python3 -c 'import json,sys; sys.exit(0 if "updated:2.7.0:2.8.0"==json.load(open(sys.argv[1])).get("statusLine") else 1)' "$REC"; then
  ok "(7) the per-repo record carries statusLine=updated:2.7.0:2.8.0"
else bad "(7) record=$REC"; fi

# (8) the hook still never fails, whatever happened
R="$(mkrepo exitcode "$(managed 2.7.0)")"
if run "$R" >/dev/null; then ok "(8) exit 0 — a session start is never blocked by this hook"
else bad "(8) non-zero exit"; fi

# --- a COMMITTED status line: the work tree is the repository's -----------------------------
# tracked NAME BRANCH [CONFIG]: a repository whose develop commits managed v2.7.0, with an origin
# remote that is never contacted (its refs are written locally), then BRANCH checked out.
gitc() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
tracked() {
  R="$(mkrepo "$1" "$(managed 2.7.0)" "${3:-}")"
  gitc checkout -q -b develop; gitc add -A; gitc commit -qm base
  gitc remote add origin "$WORK/no-such-remote"
  gitc update-ref refs/remotes/origin/develop HEAD
  [ "$2" = develop ] || gitc checkout -q -b "$2"
}
newer_on() { # newer_on REF: REF carries managed v2.8.0, the work tree does not
  gitc checkout -q -b tmp-newer; managed 2.8.0 > "$R/.claude/statusline.sh"; gitc commit -qam newer
  gitc update-ref "$1" HEAD; gitc checkout -q -; gitc branch -q -D tmp-newer
}
clean() { [ -z "$(git -C "$R" status --porcelain)" ]; }
record() {
  local top key; top=$(git -C "$R" rev-parse --show-toplevel)
  key=$(printf '%s' "$top" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:12])')
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("statusLine",""))' \
    "$XDG_CACHE_HOME/devstride-plugin/repo-$key.json" 2>/dev/null
}

# (9) origin/<baseBranch> already carries the new copy: a detached checkout is only behind
tracked behind-detached develop; newer_on refs/remotes/origin/develop; gitc checkout -q --detach
OUT="$(run "$R")"
if clean && [ ! -e "$(bak "$R")" ] \
   && printf '%s' "$OUT" | grep -q 'status line: v2.8.0 is already on origin/develop; pull to get it' \
   && [ "$(record)" = "on-upstream:2.7.0:2.8.0:origin/develop" ]; then
  ok "(9) committed copy, origin/develop already newer → tree untouched, one 'pull' line"
else bad "(9) out=$OUT status=$(git -C "$R" status --porcelain) record=$(record)"; fi

# (10) the branch's own upstream is read first
tracked behind-upstream feat; gitc config branch.feat.remote origin; gitc config branch.feat.merge refs/heads/feat
newer_on refs/remotes/origin/feat
OUT="$(run "$R")"
if clean && printf '%s' "$OUT" | grep -q 'v2.8.0 is already on origin/feat; pull to get it'; then
  ok "(10) a feature branch whose upstream is newer → 'pull', tree untouched"
else bad "(10) out=$OUT status=$(git -C "$R" status --porcelain)"; fi

# (11) nothing newer anywhere, but HEAD is detached / on the base branch / on a protected pattern:
# silent, untouched, recorded as held
tracked held-detached develop; gitc checkout -q --detach; OUT="$(run "$R")"
if clean && [ -z "$OUT" ] && [ "$(record)" = "held:2.7.0:2.8.0" ]; then
  ok "(11a) detached HEAD → no write, silent, recorded as held"
else bad "(11a) out=$OUT status=$(git -C "$R" status --porcelain) record=$(record)"; fi
tracked held-base develop; OUT="$(run "$R")"
if clean && [ -z "$OUT" ]; then ok "(11b) on baseBranch (develop) → no write, silent"
else bad "(11b) out=$OUT status=$(git -C "$R" status --porcelain)"; fi
tracked held-main main '{"baseBranch":"main","release":{"productionBranch":"main"}}'; OUT="$(run "$R")"
if clean && [ -z "$OUT" ]; then ok "(11c) on the configured base/production branch → no write, silent"
else bad "(11c) out=$OUT status=$(git -C "$R" status --porcelain)"; fi
tracked held-pattern release/26-11-01 '{"protectedBranches":["release/*"]}'; OUT="$(run "$R")"
if clean && [ -z "$OUT" ]; then ok "(11d) on a protectedBranches pattern match → no write, silent"
else bad "(11d) out=$OUT status=$(git -C "$R" status --porcelain)"; fi

# (12) a feature branch with nothing newer upstream: refreshed, committing advised, backup outside
tracked feature-refresh phil/x
OUT="$(run "$R")"
if [ "$(git -C "$R" status --porcelain)" = " M .claude/statusline.sh" ] \
   && grep -q 'local-2.7.0' "$(bak "$R")" && [ ! -e "$R/.claude/statusline.sh.bak" ] \
   && printf '%s' "$OUT" | grep -q 'updated 2.7.0 → 2.8.0' && printf '%s' "$OUT" | grep -q 'Commit it so every clone gets it' \
   && [ "$(record)" = "updated:2.7.0:2.8.0" ]; then
  ok "(12) feature branch → refreshed, only the status line modified, 'Commit it' printed"
else bad "(12) out=$OUT status=$(git -C "$R" status --porcelain) record=$(record)"; fi

# (13) a linked worktree keeps its backup in the shared git directory, never in its own tree
gitc worktree add -q "$WORK/feature-refresh-wt" -b phil/y develop 2>/dev/null
WT="$WORK/feature-refresh-wt"; OUT="$(run "$WT")"
if [ "$(git -C "$WT" status --porcelain)" = " M .claude/statusline.sh" ] \
   && grep -q 'local-2.7.0' "$(bak "$R")" && [ ! -e "$WT/.claude/statusline.sh.bak" ]; then
  ok "(13) linked worktree → backup in the common git directory, its tree holds only the refresh"
else bad "(13) out=$OUT status=$(git -C "$WT" status --porcelain)"; fi

exit $FAIL
