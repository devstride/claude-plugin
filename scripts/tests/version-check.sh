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
  printf 'deadbeef\trefs/tags/devstride--v%s\n' "$VC_NEWEST"
  exit 0
fi
exec "$REAL_GIT" "$@"
STUB

cat > "$WORK/bin/claude" <<'STUB'
#!/bin/bash
printf 'claude:%s\n' "$*" >> "$VC_LOG"
case "${1:-} ${2:-}" in
  'plugin list')
    if [ -f "$VC_STATE/updated" ]; then cat "$VC_STATE/list-after.json"
    else cat "$VC_STATE/list-before.json"
    fi
    ;;
  'plugin marketplace')
    [ "${VC_COMMAND_MODE:-ok}" != "marketplace-fail" ]
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
  REPO="$CASE_DIR/repo"; PLUGIN="$CASE_DIR/plugin"; VC_STATE="$CASE_DIR/state"; VC_LOG="$CASE_DIR/calls"
  XDG_CACHE_HOME="$CASE_DIR/cache"
  export CASE_DIR REPO PLUGIN VC_STATE VC_LOG VC_NEWEST XDG_CACHE_HOME
  mkdir -p "$REPO/.claude" "$PLUGIN/.claude-plugin" "$VC_STATE"
  "$REAL_GIT" -C "$REPO" init -q
  REPO="$($REAL_GIT -C "$REPO" rev-parse --show-toplevel)"; export REPO
  printf '%s' "$CONFIG" > "$REPO/.claude/ds-config.json"
  printf '{"version":"2.8.0"}' > "$PLUGIN/.claude-plugin/plugin.json"
  python3 - "$VC_STATE/list-before.json" "$VC_STATE/list-after.json" "$PLUGIN" "$REPO" "$SCOPE" "$POST_VERSION" "$BOUND" <<'PY'
import json, sys
before, after, root, repo, scope, post, bound = sys.argv[1:]
row = {"id": "devstride@devstride", "version": "2.8.0", "scope": scope,
       "enabled": True, "installPath": root}
if bound == "1" and scope in ("project", "local"):
    row["projectPath"] = repo
with open(before, "w") as f:
    json.dump([row], f)
updated = dict(row, version=post, installPath=root + "-" + post)
with open(after, "w") as f:
    json.dump([updated], f)
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
not_called() { [ ! -f "$VC_LOG" ] || ! grep -q "$1" "$VC_LOG"; }

# (1) Current is silent and never asks Claude to resolve an install.
setup_case current 2.8.0 '{}' project 2.8.0
OUT="$(run_hook)"
if [ -z "$OUT" ] && result_is current && not_called '^claude:'; then
  ok "(1) current release → silent, no install lookup"
else bad "(1) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (2) Notify-only resolves the exact repository-scoped install but mutates nothing.
setup_case behind 2.9.0 '{}' project 2.9.0
OUT="$(run_hook)"
if result_is behind && printf '%s' "$OUT" | grep -q 'plugin update devstride@devstride --scope project' \
   && not_called 'plugin marketplace' && not_called 'plugin update'; then
  ok "(2) behind, autoUpdate off → exact manual command, no mutation"
else bad "(2) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (3) Repository-bound project scope may auto-update; success is the second list result, not exit 0.
setup_case project-auto 2.9.0 '{"plugin":{"autoUpdate":true}}' project 2.9.0
OUT="$(run_hook)"
if result_is updated && printf '%s' "$OUT" | grep -q 'updated on disk 2.8.0 → 2.9.0' \
   && printf '%s' "$OUT" | grep -q 'restart to pick it up' \
   && grep -q 'claude:plugin update devstride@devstride --scope project --yes' "$VC_LOG" \
   && [ "$(grep -c 'claude:plugin list --json' "$VC_LOG")" -eq 2 ]; then
  ok "(3) project-scope opt-in → update, post-verify installed version, require restart"
else bad "(3) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (4) Repo-local config cannot change a shared user install, even with autoUpdate true.
setup_case shared-user 2.9.0 '{"plugin":{"autoUpdate":true}}' user 2.9.0 0
OUT="$(run_hook)"
if result_is shared-scope-auto-refused \
   && printf '%s' "$OUT" | grep -q 'did not change the shared user install' \
   && printf '%s' "$OUT" | grep -q 'then restart' \
   && not_called 'plugin marketplace' && not_called 'plugin update'; then
  ok "(4) shared user scope → precise manual/restart instruction, no mutation"
else bad "(4) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# Managed installs get the same refusal, phrased for the administrator who owns that scope.
setup_case shared-managed 2.9.0 '{"plugin":{"autoUpdate":true}}' managed 2.9.0 0
OUT="$(run_hook)"
if result_is shared-scope-auto-refused && printf '%s' "$OUT" | grep -q 'Ask its administrator' \
   && not_called 'plugin marketplace' && not_called 'plugin update'; then
  ok "(4b) shared managed scope → administrator instruction, no mutation"
else bad "(4b) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# A project/local label without the repository binding field is not enough authority to mutate it.
setup_case unbound-project 2.9.0 '{"plugin":{"autoUpdate":true}}' project 2.9.0 0
OUT="$(run_hook)"
if result_is scope-binding-unverified && printf '%s' "$OUT" | grep -q 'could not prove' \
   && not_called 'plugin marketplace' && not_called 'plugin update' \
   && [ "$(grep -c 'claude:plugin list --json' "$VC_LOG")" -eq 1 ]; then
  ok "(4c) unbound project row → manual instruction, no guessed authority"
else bad "(4c) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (5) An explicit pin suppresses all install/update commands; a disabled check suppresses network too.
setup_case pinned 2.9.0 '{"plugin":{"pin":"2.8.0","autoUpdate":true}}' project 2.9.0
OUT="$(run_hook)"
if result_is behind-pinned && printf '%s' "$OUT" | grep -q 'pinned at 2.8.0' && not_called '^claude:'; then
  ok "(5) explicit pin → report only, never update"
else bad "(5) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

setup_case disabled 2.9.0 '{"plugin":{"updateCheck":false,"autoUpdate":true}}' project 2.9.0
OUT="$(run_hook)"
if [ -z "$OUT" ] && [ ! -f "$VC_LOG" ]; then
  ok "(5b) updateCheck false → no release lookup and no install command"
else bad "(5b) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

# (6) Exit 0 is not success when the installed version remains old.
setup_case failed-postverify 2.9.0 '{"plugin":{"autoUpdate":true}}' project 2.8.0
OUT="$(run_hook)"
if result_is update-verification-failed \
   && printf '%s' "$OUT" | grep -q 'still reports 2.8.0; expected 2.9.0' \
   && printf '%s' "$OUT" | grep -q 'verify with claude plugin list, then restart'; then
  ok "(6) update exits 0 but disk stays old → verification failure, not false success"
else bad "(6) out=$OUT calls=$(cat "$VC_LOG" 2>/dev/null)"; fi

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

exit $FAIL
