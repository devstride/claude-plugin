#!/bin/bash
# Deterministic tests for the plugin-update half of hooks/version-check.sh. All network and Claude
# CLI calls are stubs; every case gets its own repository and six-hour cache.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$ROOT/hooks/version-check.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REAL_GIT="$(command -v git)"; export REAL_GIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/git" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "ls-remote" ]; then
  printf 'git:%s\n' "$*" >> "$VC_LOG"
  printf '1111111111111111111111111111111111111111\trefs/tags/devstride--v%s\n' "$VC_NEWEST"
  printf '%s\trefs/tags/devstride--v%s^{}\n' "$VC_RELEASE_COMMIT" "$VC_NEWEST"
  exit 0
fi
exec "$REAL_GIT" "$@"
STUB

cat > "$WORK/bin/claude" <<'STUB'
#!/bin/bash
printf 'claude:%s keep=%s\n' "$*" \
  "${CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE:-}" >> "$VC_LOG"
case "${1:-} ${2:-}" in
  'plugin list')
    if [ -f "$VC_STATE/updated" ]; then cat "$VC_STATE/list-after.json"
    else cat "$VC_STATE/list-before.json"
    fi
    ;;
  'plugin marketplace')
    if [ "${3:-}" = "list" ]; then cat "$VC_STATE/marketplaces.json"
    else [ "${VC_COMMAND_MODE:-ok}" != "marketplace-fail" ]
    fi
    ;;
  'plugin update')
    [ "${VC_COMMAND_MODE:-ok}" = "update-fail" ] && exit 1
    : > "$VC_STATE/updated"
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$WORK/bin/git" "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

# setup_case NAME NEWEST CONFIG SCOPE POST_VERSION [BOUND]
setup_case() {
  CASE_DIR="$WORK/$1"; VC_NEWEST="$2"; CONFIG="$3"; SCOPE="$4"; POST_VERSION="$5"; BOUND="${6:-1}"
  REPO="$CASE_DIR/repo"; LINEAGE="$CASE_DIR/cache/devstride/devstride"; PLUGIN="$LINEAGE/2.8.0"
  VC_STATE="$CASE_DIR/state"; VC_LOG="$CASE_DIR/calls"; MARKET="$CASE_DIR/market"
  XDG_CACHE_HOME="$CASE_DIR/cache"; XDG_RUNTIME_DIR="$CASE_DIR/runtime"
  export CASE_DIR REPO LINEAGE PLUGIN VC_STATE VC_LOG VC_NEWEST XDG_CACHE_HOME XDG_RUNTIME_DIR MARKET
  mkdir -p "$REPO/.claude" "$PLUGIN/.claude-plugin" "$PLUGIN/skills/update/scripts" \
    "$VC_STATE" "$MARKET/.claude-plugin" "$MARKET/skills/update/scripts" "$XDG_RUNTIME_DIR"
  "$REAL_GIT" -C "$REPO" init -q
  REPO="$($REAL_GIT -C "$REPO" rev-parse --show-toplevel)"; export REPO
  printf '%s' "$CONFIG" > "$REPO/.claude/ds-config.json"
  printf '{"name":"devstride","version":"2.8.0"}' > "$PLUGIN/.claude-plugin/plugin.json"
  cp "$ROOT/skills/update/scripts/update-plugin.py" "$PLUGIN/skills/update/scripts/update-plugin.py"
  cp "$ROOT/skills/update/scripts/latest-version.sh" "$PLUGIN/skills/update/scripts/latest-version.sh"
  cp "$ROOT/skills/update/scripts/update-plugin.py" "$MARKET/skills/update/scripts/update-plugin.py"
  cp "$ROOT/skills/update/scripts/latest-version.sh" "$MARKET/skills/update/scripts/latest-version.sh"
  printf '{"name":"devstride","version":"%s"}' "$VC_NEWEST" > "$MARKET/.claude-plugin/plugin.json"
  printf '{"plugins":[{"name":"devstride","source":"./"},{"name":"ds","source":"./"}]}' \
    > "$MARKET/.claude-plugin/marketplace.json"
  "$REAL_GIT" -C "$MARKET" init -q
  "$REAL_GIT" -C "$MARKET" config user.name test
  "$REAL_GIT" -C "$MARKET" config user.email test@example.com
  "$REAL_GIT" -C "$MARKET" add .
  "$REAL_GIT" -C "$MARKET" commit -qm fixture
  VC_RELEASE_COMMIT="$("$REAL_GIT" -C "$MARKET" rev-parse HEAD)"; export VC_RELEASE_COMMIT
  python3 - "$VC_STATE/list-before.json" "$VC_STATE/list-after.json" "$PLUGIN" "$LINEAGE" \
    "$REPO" "$SCOPE" "$POST_VERSION" "$BOUND" <<'PY'
import json, os, sys
before, after, root, lineage, repo, scope, post, bound = sys.argv[1:]
row = {"id": "devstride@devstride", "version": "2.8.0", "scope": scope,
       "enabled": True, "installPath": root}
if bound == "1" and scope in ("project", "local"):
    row["projectPath"] = repo
with open(before, "w") as f:
    json.dump([row], f)
updated = dict(row, version=post, installPath=os.path.join(lineage, post))
with open(after, "w") as f:
    json.dump([updated], f)
PY
  mkdir -p "$LINEAGE/$POST_VERSION/.claude-plugin" "$LINEAGE/$POST_VERSION/skills/update/scripts"
  printf '{"name":"devstride","version":"%s"}' "$POST_VERSION" \
    > "$LINEAGE/$POST_VERSION/.claude-plugin/plugin.json"
  cp "$MARKET/.claude-plugin/marketplace.json" "$LINEAGE/$POST_VERSION/.claude-plugin/marketplace.json"
  cp "$ROOT/skills/update/scripts/update-plugin.py" "$LINEAGE/$POST_VERSION/skills/update/scripts/update-plugin.py"
  cp "$ROOT/skills/update/scripts/latest-version.sh" "$LINEAGE/$POST_VERSION/skills/update/scripts/latest-version.sh"
  python3 - "$VC_STATE/marketplaces.json" "$MARKET" <<'PY'
import json,sys
json.dump([{"name":"devstride","source":"github","repo":"devstride/claude-plugin",
            "installLocation":sys.argv[2]}],open(sys.argv[1],"w"))
PY
}

run_hook() {
  CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$HOOK" <<< "$(printf '{\"cwd\":\"%s\"}' "$REPO")" 2>/dev/null
}
result_is() {
  KEY=$(printf '%s' "$REPO" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:12])')
  python3 - "$XDG_CACHE_HOME/devstride-plugin/repo-$KEY.json" "$1" <<'PY'
import json, sys
try: actual = json.load(open(sys.argv[1])).get("result")
except Exception: actual = None
raise SystemExit(0 if actual == sys.argv[2] else 1)
PY
}
not_called() { [ ! -f "$VC_LOG" ] || ! grep -q -- "$1" "$VC_LOG"; }

# (1) Current is silent and never asks Claude to resolve an install.
setup_case current 2.8.0 '{}' project 2.8.0
OUT="$(run_hook)"
if [ -z "$OUT" ] && result_is current && not_called '^claude:'; then
  ok "(1) current release → silent, no install lookup"
else bad "(1) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (2) Notify-only resolves the exact repository-scoped install but mutates nothing.
setup_case behind 2.9.0 '{}' project 2.9.0
OUT="$(run_hook)"
if result_is behind && printf '%s' "$OUT" | grep -qF '/devstride:update' \
   && printf '%s' "$OUT" | grep -q 'verify the exact tagged install' \
   && ! printf '%s' "$OUT" | grep -q 'claude plugin update' \
   && not_called 'plugin marketplace' && not_called 'plugin update'; then
  ok "(2) behind, autoUpdate off → verified updater handoff, no raw mutation"
else bad "(2) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (3) Repository-bound project scope may auto-update; success is the second list result, not exit 0.
setup_case project-auto 2.9.0 '{"plugin":{"autoUpdate":true}}' project 2.9.0
OUT="$(run_hook)"
if result_is updated && printf '%s' "$OUT" | grep -q 'updated on disk 2.8.0 → 2.9.0' \
   && printf '%s' "$OUT" | grep -qF '/reload-plugins' \
   && printf '%s' "$OUT" | grep -qi 'restart' \
   && grep -q 'claude:plugin marketplace update devstride keep=1' "$VC_LOG" \
   && grep -q 'claude:plugin update devstride@devstride --scope project keep=1' "$VC_LOG" \
   && not_called --yes \
   && [ "$(grep -c 'claude:plugin list --json' "$VC_LOG")" -ge 5 ]; then
  ok "(3) project opt-in → preserved cache, exact update, verification, reload/restart"
else bad "(3) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# The loaded copy may be old while Claude's on-disk row already points at a newer version. The
# documented cache/<marketplace>/<entry>/<version> lineage still identifies the exact install.
setup_case stale-loaded 2.9.0 '{}' project 2.9.0
python3 - "$VC_STATE/list-before.json" "$LINEAGE" <<'PY'
import json, os, sys
rows=json.load(open(sys.argv[1])); rows[0]["version"]="2.9.0"
rows[0]["installPath"]=os.path.join(sys.argv[2], "2.9.0")
json.dump(rows, open(sys.argv[1], "w"))
PY
printf '\n# tampered after install\n' >> "$LINEAGE/2.9.0/skills/update/scripts/latest-version.sh"
OUT="$(run_hook)"
if result_is disk-current-unverified \
   && printf '%s' "$OUT" | grep -q 'tagged files have not been verified' \
   && printf '%s' "$OUT" | grep -qF '/devstride:update' \
   && printf '%s' "$OUT" | grep -q 'do not reload' \
   && ! printf '%s' "$OUT" | grep -qF '/reload-plugins' \
   && [ "$(grep -c 'claude:plugin list --json' "$VC_LOG")" -eq 1 ] \
   && not_called 'plugin marketplace' && not_called 'plugin update'; then
  ok "(3b) stale/tampered disk copy → no reload before tagged-file proof"
else bad "(3b) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (4) Repo-local config cannot change a shared user install, even with autoUpdate true.
setup_case shared-user 2.9.0 '{"plugin":{"autoUpdate":true}}' user 2.9.0 0
OUT="$(run_hook)"
if result_is shared-scope-auto-refused \
   && printf '%s' "$OUT" | grep -q 'cannot change shared user install' \
   && printf '%s' "$OUT" | grep -qF '/devstride:update' \
   && not_called 'plugin marketplace' && not_called 'plugin update'; then
  ok "(4) shared user scope → explicit verified updater, no background mutation"
else bad "(4) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# Managed installs get the same refusal, phrased for the administrator who owns that scope.
setup_case shared-managed 2.9.0 '{"plugin":{"autoUpdate":true}}' managed 2.9.0 0
OUT="$(run_hook)"
if result_is shared-scope-auto-refused && printf '%s' "$OUT" | grep -q 'administrator must update and verify' \
   && printf '%s' "$OUT" | grep -qF '/reload-plugins' \
   && printf '%s' "$OUT" | grep -qi 'restart' \
   && not_called 'plugin marketplace' && not_called 'plugin update'; then
  ok "(4b) shared managed scope → administrator instruction, no mutation"
else bad "(4b) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# A project/local label without the repository binding field is not enough authority to mutate it.
setup_case unbound-project 2.9.0 '{"plugin":{"autoUpdate":true}}' project 2.9.0 0
OUT="$(run_hook)"
if result_is lookup-failed && printf '%s' "$OUT" | grep -q 'active install is ambiguous or unsafe' \
   && printf '%s' "$OUT" | grep -qF '/devstride:doctor' \
   && printf '%s' "$OUT" | grep -q 'do not guess' \
   && ! printf '%s' "$OUT" | grep -qF '/reload-plugins' \
   && not_called 'plugin marketplace' && not_called 'plugin update' \
   && [ "$(grep -c 'claude:plugin list --json' "$VC_LOG")" -eq 1 ]; then
  ok "(4c) unbound project row → safe lookup failure, no guessed authority"
else bad "(4c) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (5) An explicit pin suppresses all install/update commands; a disabled check suppresses network too.
setup_case pinned 2.9.0 '{"plugin":{"pin":"2.8.0","autoUpdate":true}}' project 2.9.0
OUT="$(run_hook)"
if result_is behind-pinned && printf '%s' "$OUT" | grep -q 'pinned at 2.8.0' && not_called '^claude:'; then
  ok "(5) explicit pin → report only, never update"
else bad "(5) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

setup_case pinned-ahead 2.9.0 '{"plugin":{"pin":"3.0.0","autoUpdate":true}}' project 2.9.0
printf '{"name":"devstride","version":"3.0.0"}' > "$PLUGIN/.claude-plugin/plugin.json"
OUT="$(run_hook)"
if result_is pinned-ahead && printf '%s' "$OUT" | grep -q 'newer than the latest tagged release' \
   && printf '%s' "$OUT" | grep -q 'Do not reload or update' && not_called '^claude:'; then
  ok "(5a) pin names an ahead version → unverified, never blessed as current"
else bad "(5a) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

setup_case disabled 2.9.0 '{"plugin":{"updateCheck":false,"autoUpdate":true}}' project 2.9.0
OUT="$(run_hook)"
if [ -z "$OUT" ] && [ ! -f "$VC_LOG" ]; then
  ok "(5b) updateCheck false → no release lookup and no install command"
else bad "(5b) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (6) Exit 0 is not success when the installed version remains old.
setup_case failed-postverify 2.9.0 '{"plugin":{"autoUpdate":true}}' project 2.8.0
OUT="$(run_hook)"
if result_is update-verification-failed \
   && printf '%s' "$OUT" | grep -q 'could not prove a tagged release was installed' \
   && printf '%s' "$OUT" | grep -qF '/devstride:update' \
   && ! printf '%s' "$OUT" | grep -qF '/reload-plugins'; then
  ok "(6) update exits 0 but disk stays old → failure, never reload advice"
else bad "(6) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# Invalid configuration cannot enable either mutation path through truthy strings or malformed JSON.
setup_case invalid-types 2.9.0 \
  '{"plugin":{"autoUpdate":"false"},"statusLine":{"autoUpdate":1}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.9.0 — marker\necho shipped\n' > "$PLUGIN/skills/setup/references/statusline.sh"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
OUT="$(run_hook)"
if result_is invalid-config && [ -z "$OUT" ] && grep -q 'echo old' "$REPO/.claude/statusline.sh" \
   && [ ! -e "$REPO/.claude/statusline.sh.bak" ] && not_called '^claude:' \
   && not_called '^git:ls-remote'; then
  ok "(6b) non-boolean mutation flags → invalid config, no plugin/status-line change"
else bad "(6b) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

setup_case invalid-top-level 2.9.0 '[]' project 2.9.0
OUT="$(run_hook)"
if result_is invalid-config && [ -z "$OUT" ] && not_called '^claude:' \
   && not_called '^git:ls-remote'; then
  ok "(6c) malformed top-level config → no network or mutation"
else bad "(6c) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# Legacy/poisoned cache data is parsed as data, never shell arithmetic, and cannot skip a fresh lookup.
setup_case poisoned-cache 2.8.0 '{}' project 2.8.0
mkdir -p "$XDG_CACHE_HOME/devstride-plugin"
SIDE_EFFECT="$CASE_DIR/arithmetic-executed"
python3 - "$XDG_CACHE_HOME/devstride-plugin/newest.json" "$SIDE_EFFECT" <<'PY'
import json,sys
json.dump({"newest":"9.9.9","fetchedAt":f"x[$(touch {sys.argv[2]})]"},open(sys.argv[1],"w"))
PY
OUT="$(run_hook)"
if result_is current && [ -z "$OUT" ] && [ ! -e "$SIDE_EFFECT" ] \
   && grep -q '^git:ls-remote' "$VC_LOG" \
   && python3 - "$XDG_CACHE_HOME/devstride-plugin/newest.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); raise SystemExit(0 if d.get("schema")==2 and d.get("newest")=="2.8.0" else 1)
PY
then
  ok "(6d) legacy/poisoned cache → ignored safely and replaced from canonical tags"
else bad "(6d) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

setup_case invalid-runtime 2.9.0 '{}' project 2.9.0
printf '{"name":"devstride","version":"not-a-version"}' > "$PLUGIN/.claude-plugin/plugin.json"
OUT="$(run_hook)"
if result_is invalid-runtime && [ -z "$OUT" ] && not_called '^claude:' \
   && not_called '^git:ls-remote'; then
  ok "(6e) malformed running manifest → fail closed before network or update"
else bad "(6e) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (7) Status-line refresh is independent of plugin.updateCheck.
setup_case status-independent 2.9.0 '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.9.0 — marker\necho shipped\n' > "$PLUGIN/skills/setup/references/statusline.sh"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
OUT="$(run_hook)"
if printf '%s' "$OUT" | grep -q 'status line: updated 2.8.0 → 2.9.0' \
   && grep -q 'echo shipped' "$REPO/.claude/statusline.sh" && [ ! -f "$VC_LOG" ]; then
  ok "(7) plugin check disabled → opted-in managed status line still refreshes"
else bad "(7) out=$OUT file=$(cat "$REPO/.claude/statusline.sh" 2>/dev/null)"; fi

# (8) Status-line refresh refuses links in the source, target, or preexisting backup.
setup_case status-target-symlink 2.9.0 '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.9.0 — marker\necho shipped\n' > "$PLUGIN/skills/setup/references/statusline.sh"
printf '# ds-statusline: managed v2.8.0 — marker\necho outside\n' > "$CASE_DIR/outside-target"
ln -s "$CASE_DIR/outside-target" "$REPO/.claude/statusline.sh"
OUT="$(run_hook)"
if [ -L "$REPO/.claude/statusline.sh" ] && grep -q 'echo outside' "$CASE_DIR/outside-target" \
   && [ ! -e "$REPO/.claude/statusline.sh.bak" ] && [ -z "$OUT" ]; then
  ok "(8a) symlinked repository status line → refused without touching its target"
else bad "(8a) out=$OUT target=$(cat "$CASE_DIR/outside-target")"; fi

setup_case status-target-hardlink 2.9.0 '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.9.0 — marker\necho shipped\n' > "$PLUGIN/skills/setup/references/statusline.sh"
printf '# ds-statusline: managed v2.8.0 — marker\necho hard-target\n' > "$CASE_DIR/outside-target"
ln "$CASE_DIR/outside-target" "$REPO/.claude/statusline.sh"
OUT="$(run_hook)"
if grep -q 'echo hard-target' "$CASE_DIR/outside-target" \
   && [ ! -e "$REPO/.claude/statusline.sh.bak" ] && [ -z "$OUT" ]; then
  ok "(8b) hardlinked repository status line → refused without touching either link"
else bad "(8b) out=$OUT target=$(cat "$CASE_DIR/outside-target")"; fi

setup_case status-backup-link 2.9.0 '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.9.0 — marker\necho shipped\n' > "$PLUGIN/skills/setup/references/statusline.sh"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
printf 'outside-backup\n' > "$CASE_DIR/outside-backup"; ln -s "$CASE_DIR/outside-backup" "$REPO/.claude/statusline.sh.bak"
OUT="$(run_hook)"
if grep -q 'echo old' "$REPO/.claude/statusline.sh" && grep -q outside-backup "$CASE_DIR/outside-backup" \
   && [ -L "$REPO/.claude/statusline.sh.bak" ] && [ -z "$OUT" ]; then
  ok "(8c) unsafe preexisting backup link → refresh refused without overwriting it"
else bad "(8c) out=$OUT target=$(cat "$REPO/.claude/statusline.sh")"; fi

setup_case status-backup-hardlink 2.9.0 '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.9.0 — marker\necho shipped\n' > "$PLUGIN/skills/setup/references/statusline.sh"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
printf 'outside-hard-backup\n' > "$CASE_DIR/outside-backup"; ln "$CASE_DIR/outside-backup" "$REPO/.claude/statusline.sh.bak"
OUT="$(run_hook)"
if grep -q 'echo old' "$REPO/.claude/statusline.sh" && grep -q outside-hard-backup "$CASE_DIR/outside-backup" \
   && [ -z "$OUT" ]; then
  ok "(8d) unsafe preexisting backup hardlink → refresh refused without overwriting it"
else bad "(8d) out=$OUT target=$(cat "$REPO/.claude/statusline.sh")"; fi

setup_case status-source-link 2.9.0 '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
printf '# ds-statusline: managed v2.9.0 — marker\necho linked-source\n' > "$CASE_DIR/outside-source"
ln -s "$CASE_DIR/outside-source" "$PLUGIN/skills/setup/references/statusline.sh"
OUT="$(run_hook)"
if grep -q 'echo old' "$REPO/.claude/statusline.sh" && [ ! -e "$REPO/.claude/statusline.sh.bak" ] \
   && [ -z "$OUT" ]; then
  ok "(8e) symlinked shipped source → refresh refused"
else bad "(8e) out=$OUT target=$(cat "$REPO/.claude/statusline.sh")"; fi

setup_case status-source-hardlink 2.9.0 '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
printf '# ds-statusline: managed v2.9.0 — marker\necho hard-source\n' > "$CASE_DIR/outside-source"
ln "$CASE_DIR/outside-source" "$PLUGIN/skills/setup/references/statusline.sh"
OUT="$(run_hook)"
if grep -q 'echo old' "$REPO/.claude/statusline.sh" && [ ! -e "$REPO/.claude/statusline.sh.bak" ] \
   && [ -z "$OUT" ]; then
  ok "(8f) hardlinked shipped source → refresh refused"
else bad "(8f) out=$OUT target=$(cat "$REPO/.claude/statusline.sh")"; fi

if grep -qF 'os.replace(' "$HOOK" && ! grep -q 'cp "$SL_REPO"' "$HOOK"; then
  ok "(8g) accepted refreshes use same-directory temporary files and atomic rename"
else bad "(8g) atomic refresh contract missing"; fi

# (9) A writer landing after backup creation is kept, and abandoned temp files are removed.
setup_case status-concurrent 2.9.0 '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
{
  printf '# ds-statusline: managed v2.9.0 — marker\n'
  dd if=/dev/zero bs=1000 count=900 2>/dev/null | tr '\000' '#'
  printf '\necho shipped\n'
} > "$PLUGIN/skills/setup/references/statusline.sh"
(
  while [ ! -e "$REPO/.claude/statusline.sh.bak" ]; do :; done
  printf '# owner concurrent edit\necho newer\n' > "$REPO/.claude/statusline.sh"
) & WRITER=$!
OUT="$(run_hook)"; wait "$WRITER"
LEFTOVERS="$(find "$REPO/.claude" -maxdepth 1 -type f -name '.statusline.sh.*' -print)"
if grep -q 'echo newer' "$REPO/.claude/statusline.sh" && [ -z "$OUT" ] && [ -z "$LEFTOVERS" ]; then
  ok "(9) concurrent owner edit → preserved, refresh refused, temporary files cleaned"
else bad "(9) out=$OUT target=$(cat "$REPO/.claude/statusline.sh") leftovers=$LEFTOVERS"; fi

# Inject a writer immediately before link(2), the no-overwrite commit primitive. This makes the
# two smallest race windows deterministic without adding test-only pauses to the shipped hook.
install_statusline_race_injector() {
  RACE_PY="$CASE_DIR/race-python"; mkdir -p "$RACE_PY"
  cat > "$RACE_PY/sitecustomize.py" <<'PY'
import os

real_link = os.link
mode = os.environ.get("VC_STATUSLINE_RACE", "")
target = os.environ.get("VC_STATUSLINE_TARGET", "")
race_log = os.environ.get("VC_STATUSLINE_RACE_LOG", "")
fired = False

def racing_link(source, destination, *args, **kwargs):
    global fired
    destination_name = os.fspath(destination)
    wanted = os.path.basename(target) + (".bak" if mode == "backup" else "")
    if not fired and mode == "post-target" and destination_name == wanted:
        result = real_link(source, destination, *args, **kwargs)
        temporary = target + ".concurrent"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(descriptor, b"# owner concurrent edit\necho post-link-writer\n")
        finally:
            os.close(descriptor)
        os.replace(temporary, target)
        with open(race_log, "w", encoding="utf-8") as handle:
            handle.write(mode)
        fired = True
        return result
    if not fired and mode in ("backup", "target") and destination_name == wanted:
        raced_path = target + (".bak" if mode == "backup" else "")
        descriptor = os.open(raced_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            content = ("# concurrent backup\necho other-backup\n" if mode == "backup"
                       else "# owner concurrent edit\necho final-writer\n")
            os.write(descriptor, content.encode())
        finally:
            os.close(descriptor)
        with open(race_log, "w", encoding="utf-8") as handle:
            handle.write(mode)
        fired = True
    return real_link(source, destination, *args, **kwargs)

if mode in ("backup", "target", "post-target") and target:
    os.link = racing_link
PY
}

# (10) A backup created after all inspections wins; the hook restores the old target and stops.
setup_case status-backup-race 2.9.0 \
  '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.9.0 — marker\necho shipped\n' > "$PLUGIN/skills/setup/references/statusline.sh"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
install_statusline_race_injector
RACE_LOG="$CASE_DIR/race-fired"
OUT="$(VC_STATUSLINE_RACE=backup VC_STATUSLINE_TARGET="$REPO/.claude/statusline.sh" \
  VC_STATUSLINE_RACE_LOG="$RACE_LOG" PYTHONPATH="$RACE_PY" run_hook)"
LEFTOVERS="$(find "$REPO/.claude" -maxdepth 1 -type f -name '.statusline.sh.*' -print)"
if grep -q 'echo old' "$REPO/.claude/statusline.sh" \
   && grep -q 'echo other-backup' "$REPO/.claude/statusline.sh.bak" \
   && [ "$(cat "$RACE_LOG" 2>/dev/null)" = backup ] && [ -z "$OUT" ] && [ -z "$LEFTOVERS" ]; then
  ok "(10) last-second .bak creator → preserved; refresh rolls back without temp files"
else bad "(10) out=$OUT target=$(cat "$REPO/.claude/statusline.sh" 2>/dev/null) backup=$(cat "$REPO/.claude/statusline.sh.bak" 2>/dev/null) leftovers=$LEFTOVERS"; fi

# (11) A target writer landing after the old target was moved aside wins the final path.
setup_case status-final-target-race 2.9.0 \
  '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.9.0 — marker\necho shipped\n' > "$PLUGIN/skills/setup/references/statusline.sh"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
install_statusline_race_injector
RACE_LOG="$CASE_DIR/race-fired"
OUT="$(VC_STATUSLINE_RACE=target VC_STATUSLINE_TARGET="$REPO/.claude/statusline.sh" \
  VC_STATUSLINE_RACE_LOG="$RACE_LOG" PYTHONPATH="$RACE_PY" run_hook)"
LEFTOVERS="$(find "$REPO/.claude" -maxdepth 1 -type f -name '.statusline.sh.*' -print)"
if grep -q 'echo final-writer' "$REPO/.claude/statusline.sh" \
   && grep -q 'echo old' "$REPO/.claude/statusline.sh.bak" \
   && [ "$(cat "$RACE_LOG" 2>/dev/null)" = target ] && [ -z "$OUT" ] && [ -z "$LEFTOVERS" ]; then
  ok "(11) final-gap target writer → preserved; shipped copy never clobbers it"
else bad "(11) out=$OUT target=$(cat "$REPO/.claude/statusline.sh" 2>/dev/null) backup=$(cat "$REPO/.claude/statusline.sh.bak" 2>/dev/null) leftovers=$LEFTOVERS"; fi

# (12) A writer replacing the just-linked target before the final proof also wins.
setup_case status-post-link-race 2.9.0 \
  '{"plugin":{"updateCheck":false},"statusLine":{"autoUpdate":true}}' project 2.9.0
mkdir -p "$PLUGIN/skills/setup/references"
printf '# ds-statusline: managed v2.9.0 — marker\necho shipped\n' > "$PLUGIN/skills/setup/references/statusline.sh"
printf '# ds-statusline: managed v2.8.0 — marker\necho old\n' > "$REPO/.claude/statusline.sh"
install_statusline_race_injector
RACE_LOG="$CASE_DIR/race-fired"
OUT="$(VC_STATUSLINE_RACE=post-target VC_STATUSLINE_TARGET="$REPO/.claude/statusline.sh" \
  VC_STATUSLINE_RACE_LOG="$RACE_LOG" PYTHONPATH="$RACE_PY" run_hook)"
LEFTOVERS="$(find "$REPO/.claude" -maxdepth 1 -type f -name '.statusline.sh.*' -print)"
if grep -q 'echo post-link-writer' "$REPO/.claude/statusline.sh" \
   && grep -q 'echo old' "$REPO/.claude/statusline.sh.bak" \
   && [ "$(cat "$RACE_LOG" 2>/dev/null)" = post-target ] && [ -z "$OUT" ] \
   && [ -z "$LEFTOVERS" ]; then
  ok "(12) post-link target writer → final proof catches it and preserves the edit"
else bad "(12) out=$OUT target=$(cat "$REPO/.claude/statusline.sh" 2>/dev/null) backup=$(cat "$REPO/.claude/statusline.sh.bak" 2>/dev/null) leftovers=$LEFTOVERS"; fi

exit $FAIL
