#!/bin/bash
# Deterministic tests for `/devstride:update`; every Claude/network call is stubbed.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/update/scripts/update-plugin.py"
FAIL=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REAL_GIT="$(command -v git)"; export REAL_GIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/git" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "ls-remote" ]; then
  printf 'git:%s\n' "$*" >> "$UP_LOG"
  [ "${UP_LATEST:-}" = "unreachable" ] && exit 1
  printf 'deadbeef\trefs/tags/999.0.0\n'
  printf 'deadbeef\trefs/tags/not-devstride--v999.0.0\n'
  printf '1111111111111111111111111111111111111111\trefs/tags/devstride--v%s\n' "$UP_LATEST"
  printf '%s\trefs/tags/devstride--v%s^{}\n' "$UP_RELEASE_COMMIT" "$UP_LATEST"
  if [ "${UP_MODE:-ok}" = "pin-race" ]; then
    printf '{"plugin":{"pin":"3.0.0"}}' > "$REPO/.claude/ds-config.json"
  fi
  exit 0
fi
exec "$REAL_GIT" "$@"
STUB

cat > "$WORK/bin/claude" <<'STUB'
#!/bin/bash
printf 'keep=%s pwd=%s claude:%s\n' \
  "${CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE:-}" "$PWD" "$*" >> "$UP_LOG"
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  count=0; [ ! -f "$UP_STATE/list-count" ] || count="$(cat "$UP_STATE/list-count")"
  count=$((count + 1)); printf '%s' "$count" > "$UP_STATE/list-count"
  if [ "${UP_MODE:-ok}" = "swap-before-update" ] && [ "$count" -eq 4 ]; then
    printf 'changed after attestation\n' > "$MARKET/race.txt"
    "$REAL_GIT" -C "$MARKET" add race.txt
    "$REAL_GIT" -C "$MARKET" commit -qm race
  fi
  if [ -f "$UP_STATE/updated" ]; then cat "$UP_STATE/list-after.json"
  else cat "$UP_STATE/list-before.json"
  fi
elif [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "list" ]; then
  cat "$UP_STATE/marketplaces.json"
elif [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "update" ]; then
  [ "${UP_MODE:-ok}" = "marketplace-fail" ] && exit 1
  if [ "${UP_MODE:-ok}" = "large-output" ]; then
    python3 -c 'import sys; sys.stdout.write("x"*(1024*1024+65536))'
  fi
  if [ "${UP_MODE:-ok}" = "hold" ]; then
    : > "$UP_STATE/holding"
    sleep 2
  fi
  if [ "${UP_MODE:-ok}" = "deadline-child" ]; then
    (sleep 2; : > "$UP_STATE/orphan-child") &
    sleep 5
  fi
  exit 0
elif [ "${1:-}" = "plugin" ] && [ "${2:-}" = "update" ]; then
  [ "${UP_MODE:-ok}" = "update-fail" ] && exit 1
  [ "${UP_MODE:-ok}" = "no-change" ] || : > "$UP_STATE/updated"
  exit 0
else
  exit 2
fi
STUB
chmod +x "$WORK/bin/git" "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

# setup_case NAME ENTRY SCOPE DISK_BEFORE TARGET DISK_AFTER [BOUND] [PIN] [STALE_RUNTIME]
setup_case() {
  CASE_DIR="$WORK/$1"; ENTRY="$2"; SCOPE="$3"; BEFORE="$4"; TARGET="$5"; AFTER="$6"
  BOUND="${7:-1}"; PIN="${8:--}"; STALE="${9:-0}"
  REPO="$CASE_DIR/repo"; LINEAGE="$CASE_DIR/cache/devstride/$ENTRY"
  PLUGIN="$LINEAGE/3.0.0"; MARKET="$CASE_DIR/market"; UP_STATE="$CASE_DIR/state"
  UP_LOG="$CASE_DIR/calls"; UP_LATEST="$TARGET"; UP_MODE=ok; XDG_RUNTIME_DIR="$CASE_DIR/runtime"
  export CASE_DIR REPO LINEAGE PLUGIN MARKET UP_STATE UP_LOG UP_LATEST UP_MODE XDG_RUNTIME_DIR
  mkdir -p "$REPO/.claude" "$PLUGIN/.claude-plugin" "$MARKET/.claude-plugin" "$UP_STATE" "$XDG_RUNTIME_DIR"
  "$REAL_GIT" -C "$REPO" init -q
  REPO="$($REAL_GIT -C "$REPO" rev-parse --show-toplevel)"; export REPO
  printf '{"name":"devstride","version":"3.0.0"}' > "$PLUGIN/.claude-plugin/plugin.json"
  python3 - "$REPO/.claude/ds-config.json" "$PIN" <<'PY'
import json, sys
pin = None if sys.argv[2] == "-" else sys.argv[2]
with open(sys.argv[1], "w") as handle:
    json.dump({"plugin": {"pin": pin}}, handle)
PY
  python3 - "$UP_STATE/list-before.json" "$UP_STATE/list-after.json" \
    "$PLUGIN" "$LINEAGE" "$REPO" "$ENTRY" "$SCOPE" "$BEFORE" "$AFTER" "$BOUND" "$STALE" <<'PY'
import json, os, sys
before_file, after_file, root, lineage, repo, entry, scope, before, after, bound, stale = sys.argv[1:]
plugin_id = entry + "@devstride"
row = {"id": plugin_id, "version": before, "scope": scope, "enabled": True,
       "installPath": os.path.join(lineage, before) if stale == "1" else root}
if scope in ("project", "local"):
    row["projectPath"] = repo if bound == "1" else os.path.join(os.path.dirname(repo), "other")
with open(before_file, "w") as handle: json.dump([row], handle)
updated = dict(row, version=after, installPath=os.path.join(lineage, after))
with open(after_file, "w") as handle: json.dump([updated], handle)
PY
  python3 - "$MARKET/.claude-plugin/marketplace.json" "$MARKET/.claude-plugin/plugin.json" \
    "$UP_STATE/marketplaces.json" "$ENTRY" "$TARGET" "$MARKET" <<'PY'
import json, sys
catalog, manifest, rows, entry, target, market = sys.argv[1:]
with open(catalog, "w") as handle:
    json.dump({"plugins": [{"name": "devstride", "source": "./"},
                            {"name": "ds", "source": "./"}]}, handle)
with open(manifest, "w") as handle:
    json.dump({"name": "devstride", "version": target}, handle)
with open(rows, "w") as handle:
    json.dump([{"name": "devstride", "source": "github",
                "repo": "devstride/claude-plugin", "installLocation": market}], handle)
PY
  mkdir -p "$MARKET/skills/update/scripts"
  cp "$ROOT/skills/update/scripts/update-plugin.py" "$MARKET/skills/update/scripts/update-plugin.py"
  cp "$ROOT/skills/update/scripts/latest-version.sh" "$MARKET/skills/update/scripts/latest-version.sh"
  "$REAL_GIT" -C "$MARKET" init -q
  "$REAL_GIT" -C "$MARKET" config user.name test
  "$REAL_GIT" -C "$MARKET" config user.email test@example.com
  "$REAL_GIT" -C "$MARKET" add .
  "$REAL_GIT" -C "$MARKET" commit -qm fixture
  UP_RELEASE_COMMIT="$("$REAL_GIT" -C "$MARKET" rev-parse HEAD)"; export UP_RELEASE_COMMIT
  python3 - "$LINEAGE" "$PLUGIN" "$AFTER" <<'PY'
import json, os, sys
lineage, loaded, after = sys.argv[1:]
target = os.path.join(lineage, after)
os.makedirs(os.path.join(target, ".claude-plugin"), exist_ok=True)
with open(os.path.join(target, ".claude-plugin", "plugin.json"), "w") as handle:
    json.dump({"name": "devstride", "version": after}, handle)
PY
  cp "$MARKET/.claude-plugin/marketplace.json" "$LINEAGE/$AFTER/.claude-plugin/marketplace.json"
  mkdir -p "$LINEAGE/$AFTER/skills/update/scripts"
  cp "$ROOT/skills/update/scripts/update-plugin.py" "$LINEAGE/$AFTER/skills/update/scripts/update-plugin.py"
  cp "$ROOT/skills/update/scripts/latest-version.sh" "$LINEAGE/$AFTER/skills/update/scripts/latest-version.sh"
}

run_apply() {
  CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$REPO" \
    python3 "$HELPER" apply --root "$PLUGIN" --repo "$REPO" 2>/dev/null
}
run_apply_timed() {
  CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$REPO" \
    python3 "$HELPER" apply --root "$PLUGIN" --repo "$REPO" --total-timeout 1 2>/dev/null
}
field() { printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }
called() { grep -q -- "$1" "$UP_LOG" 2>/dev/null; }
not_called() { ! called "$1"; }

# 1. Explicit user invocation updates the exact id/scope and verifies the new disk row.
setup_case user devstride user 3.0.0 3.1.0 3.1.0
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(field status)" = updated ] && [ "$(field diskAfter)" = 3.1.0 ] \
   && [ "$(field reloadRequired)" = True ] \
   && [ "$(field safeToReload)" = True ] \
   && called 'claude:plugin marketplace update devstride' \
   && called 'claude:plugin update devstride@devstride --scope user' \
   && called 'keep=1 .*claude:plugin marketplace update' \
   && not_called '--yes'; then
  ok "(1) user install → exact refresh/update/post-verification, then reload"
else bad "(1) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 2. The ds alias remains the selected installed id; it is never rewritten to devstride@.
setup_case alias ds user 3.0.0 3.1.0 3.1.0
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(field id)" = ds@devstride ] \
   && called 'claude:plugin update ds@devstride --scope user' \
   && not_called 'plugin update devstride@devstride'; then
  ok "(2) ds alias → update the alias actually installed"
else bad "(2) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 3. Force refresh still checks the marketplace when already current, but skips install mutation.
setup_case current devstride user 3.0.0 3.0.0 3.0.0
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(field status)" = current ] \
   && [ "$(field reloadRequired)" = False ] && called 'marketplace update devstride' \
   && not_called 'claude:plugin update'; then
  ok "(3) already current → refreshed and verified without rewriting the install"
else bad "(3) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 4. When another process already advanced disk, cache lineage identifies the old loaded copy.
setup_case stale-runtime devstride user 3.1.0 3.1.0 3.1.0 1 - 1
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(field status)" = current ] \
   && [ "$(field runningVersion)" = 3.0.0 ] && [ "$(field diskAfter)" = 3.1.0 ] \
   && [ "$(field reloadRequired)" = True ]; then
  ok "(4) stale runtime path → disk-current result still requires reload"
else bad "(4) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 5. A project install is updated only when its projectPath is this repository.
setup_case project devstride project 3.0.0 3.1.0 3.1.0 1
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(field scope)" = project ] \
   && called "pwd=$REPO claude:plugin update devstride@devstride --scope project"; then
  ok "(5) bound project install → exact repository and explicit scope"
else bad "(5) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 6. A project/local label without an exact repository binding grants no mutation authority.
setup_case unbound devstride project 3.0.0 3.1.0 3.1.0 0
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = project-install-unbound ] \
   && not_called 'marketplace update' && not_called 'plugin update'; then
  ok "(6) unbound project install → blocked before mutation"
else bad "(6) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 7. Managed installation updates stay with the administrator.
setup_case managed devstride managed 3.0.0 3.1.0 3.1.0
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = managed-install ] \
   && not_called 'marketplace update' && not_called 'plugin update'; then
  ok "(7) managed install → report-only administrator boundary"
else bad "(7) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 7b. CLI JSON booleans are authority fields, not truthy strings.
setup_case malformed-enabled devstride user 3.0.0 3.1.0 3.1.0
python3 - "$UP_STATE/list-before.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); rows[0]["enabled"]="false"; json.dump(rows,open(sys.argv[1],"w"))
PY
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = installed-row-invalid ] \
   && not_called 'marketplace update' && not_called 'plugin update'; then
  ok "(7b) malformed enabled field → fail closed before mutation"
else bad "(7b) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 8. A repository version pin remains authoritative even under the explicit update command.
setup_case pinned devstride user 3.0.0 3.1.0 3.1.0 1 3.0.0
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = repository-pinned ] \
   && [ "$(field pin)" = 3.0.0 ] && not_called 'marketplace update'; then
  ok "(8) repository pin → never silently overridden"
else bad "(8) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 9. Marketplace ref pins are a separate deliberate stop; never remove/re-add them.
setup_case market-pin devstride user 3.0.0 3.1.0 3.1.0
python3 - "$UP_STATE/marketplaces.json" <<'PY'
import json, sys
rows=json.load(open(sys.argv[1])); rows[0]["ref"]="devstride--v3.0.0"
json.dump(rows, open(sys.argv[1], "w"))
PY
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = marketplace-pinned ] \
   && not_called 'marketplace update' && not_called 'marketplace remove'; then
  ok "(9) marketplace pin → blocked without destructive unpinning"
else bad "(9) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 10. Installing both aliases is ambiguous; the command updates neither.
setup_case duplicate devstride user 3.0.0 3.1.0 3.1.0
python3 - "$UP_STATE/list-before.json" <<'PY'
import json, os, sys
rows=json.load(open(sys.argv[1])); other=dict(rows[0], id="ds@devstride",
    installPath=os.path.join(os.path.dirname(rows[0]["installPath"]), "ds", "3.0.0"))
rows.append(other); json.dump(rows, open(sys.argv[1], "w"))
PY
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = multiple-applicable-installs ] \
   && not_called 'marketplace update'; then
  ok "(10) duplicate aliases/scopes → blocked instead of guessing"
else bad "(10) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 11. A missing marketplace is a setup/trust issue, not permission to add one.
setup_case missing-market devstride user 3.0.0 3.1.0 3.1.0
printf '[]' > "$UP_STATE/marketplaces.json"
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = marketplace-missing ] \
   && not_called 'marketplace update' && not_called 'marketplace add'; then
  ok "(11) missing marketplace → blocked without adding trust"
else bad "(11) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 12. Offline/auth/policy refresh failure preserves cache and never attempts plugin update.
setup_case refresh-fail devstride user 3.0.0 3.1.0 3.1.0
UP_MODE=marketplace-fail; export UP_MODE
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 4 ] && [ "$(field code)" = marketplace-refresh-failed ] \
   && called 'keep=1 .*marketplace update devstride' && not_called 'claude:plugin update'; then
  ok "(12) refresh failure → old cache preserved, installed copy untouched"
else bad "(12) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 13. Exit zero is not proof: unchanged disk below target is a verification failure.
setup_case no-change devstride user 3.0.0 3.1.0 3.1.0
UP_MODE=no-change; export UP_MODE
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 4 ] && [ "$(field code)" = update-verification-failed ] \
   && [ "$(field diskAfter)" = 3.0.0 ]; then
  ok "(13) successful CLI with old disk → failure, never a false update"
else bad "(13) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 14. Main ahead of its public tag is not a release and must not install.
setup_case untagged devstride user 3.0.0 3.1.0 3.1.0
UP_LATEST=3.0.0; export UP_LATEST
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = marketplace-release-mismatch ] \
   && [ "$(field publishedVersion)" = 3.0.0 ] && not_called 'claude:plugin update'; then
  ok "(14) marketplace ahead of its tag → untagged code is not installed"
else bad "(14) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 15. A same-version checkout on an untagged commit is not a published release.
setup_case untagged-head devstride user 3.0.0 3.1.0 3.1.0
printf 'post-tag code\n' > "$MARKET/post-tag.txt"
"$REAL_GIT" -C "$MARKET" add post-tag.txt
"$REAL_GIT" -C "$MARKET" commit -qm post-tag
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = marketplace-checkout-untagged ] \
   && not_called 'claude:plugin update'; then
  ok "(15) same manifest version on later commit → untagged code blocked"
else bad "(15) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 16. The marketplace name alone grants no trust; its source must be the official repository.
setup_case wrong-source devstride user 3.0.0 3.1.0 3.1.0
python3 - "$UP_STATE/marketplaces.json" <<'PY'
import json, sys
rows=json.load(open(sys.argv[1])); rows[0]["repo"]="someone-else/claude-plugin"
json.dump(rows, open(sys.argv[1], "w"))
PY
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = marketplace-untrusted ] \
   && not_called 'marketplace update' && not_called 'claude:plugin update'; then
  ok "(16) matching marketplace name/version from another source → blocked"
else bad "(16) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 17. Local changes in the marketplace checkout cannot become an accidental release.
setup_case dirty-market devstride user 3.0.0 3.1.0 3.1.0
printf 'not committed\n' > "$MARKET/dirty.txt"
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = marketplace-checkout-dirty ] \
   && not_called 'claude:plugin update'; then
  ok "(17) dirty marketplace checkout → blocked before install mutation"
else bad "(17) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 18. Re-attestation immediately before mutation catches a checkout swapped after the first proof.
setup_case checkout-race devstride user 3.0.0 3.1.0 3.1.0
UP_MODE=swap-before-update; export UP_MODE
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = marketplace-checkout-untagged ] \
   && not_called 'claude:plugin update'; then
  ok "(18) checkout changed after attestation → second proof blocks update"
else bad "(18) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 19. A CLI row is not disk proof: the selected cache path must contain a matching safe manifest.
setup_case missing-payload devstride user 3.0.0 3.1.0 3.1.0
rm "$LINEAGE/3.1.0/.claude-plugin/plugin.json"
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 4 ] && [ "$(field code)" = post-update-inspection-failed ] \
   && [ "$(field safeToReload)" = False ] && [ "$(field manualInspectionRequired)" = True ] \
   && [ "$(field repairRequired)" = False ]; then
  ok "(19) list row pointing at missing installed manifest → verification failure"
else bad "(19) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 20. A cache manifest with a different version cannot satisfy post-verification.
setup_case wrong-payload devstride user 3.0.0 3.1.0 3.1.0
printf '{"name":"devstride","version":"3.0.0"}' > "$LINEAGE/3.1.0/.claude-plugin/plugin.json"
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 4 ] && [ "$(field code)" = post-update-inspection-failed ]; then
  ok "(20) list version and installed manifest disagree → verification failure"
else bad "(20) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 21. A linked manifest cannot redirect verification outside the selected cache directory.
setup_case linked-payload devstride user 3.0.0 3.1.0 3.1.0
rm "$LINEAGE/3.1.0/.claude-plugin/plugin.json"
ln -s "$PLUGIN/.claude-plugin/plugin.json" "$LINEAGE/3.1.0/.claude-plugin/plugin.json"
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 4 ] && [ "$(field code)" = post-update-inspection-failed ]; then
  ok "(21) symlinked installed manifest → verification failure"
else bad "(21) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 22. Disk ahead of the newest tag is an anomaly, not an acceptable current install.
setup_case ahead-before devstride user 3.2.0 3.1.0 3.2.0 1 - 1
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = installed-ahead-of-release ] \
   && not_called 'claude:plugin update'; then
  ok "(22) installed version newer than newest tag → blocked as unverified"
else bad "(22) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 23. A post-update row newer than the target is not accepted as 'close enough'.
setup_case ahead-after devstride user 3.0.0 3.1.0 3.2.0
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 4 ] && [ "$(field code)" = update-verification-failed ] \
   && [ "$(field diskAfter)" = 3.2.0 ]; then
  ok "(23) post-update disk differs from exact tag target → verification failure"
else bad "(23) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 23b. Matching version text is insufficient when the installed payload differs from the tag.
setup_case tampered-payload devstride user 3.0.0 3.1.0 3.1.0
printf '\n# changed payload\n' >> "$LINEAGE/3.1.0/skills/update/scripts/latest-version.sh"
OUT="$(run_apply)"; RC=$?
SECOND="$(run_apply)"; SECOND_RC=$?
SECOND_CODE="$(printf '%s' "$SECOND" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("code"))')"
SECOND_SAFE="$(printf '%s' "$SECOND" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("safeToReload"))')"
if [ "$RC" -eq 4 ] && [ "$(field code)" = installed-payload-mismatch ] \
   && [ "$(field safeToReload)" = False ] && [ "$(field repairRequired)" = True ] \
   && [ "$(field retryCommand)" = None ] && [ "$SECOND_RC" -eq 4 ] \
   && [ "$SECOND_CODE" = installed-payload-mismatch ] && [ "$SECOND_SAFE" = False ]; then
  ok "(23b) changed payload → first and repeated runs refuse reload and require repair"
else bad "(23b) rc=$RC out=$OUT second=$SECOND calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 23c. A pin added during the update window is observed before mutation.
setup_case pin-race devstride user 3.0.0 3.1.0 3.1.0
UP_MODE=pin-race; export UP_MODE
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = install-changed-during-update ] \
   && not_called 'claude:plugin update'; then
  ok "(23c) repository pin added mid-run → update stops before mutation"
else bad "(23c) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 23d. Claude's narrowly shaped live-session markers are allowed, but links or arbitrary content
# cannot hide from the tagged-payload comparison.
setup_case live-marker devstride user 3.0.0 3.0.0 3.0.0
mkdir -p "$PLUGIN/.in_use"
printf '{"pid":123,"procStart":"Sat Aug 29 14:11:39 2026"}' > "$PLUGIN/.in_use/123"
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(field status)" = current ] \
   && [ "$(field safeToReload)" = True ]; then
  ok "(23d) valid Claude live-session marker → ignored without hiding payload"
else bad "(23d) rc=$RC out=$OUT"; fi

setup_case linked-marker devstride user 3.0.0 3.0.0 3.0.0
mkdir "$CASE_DIR/outside-marker"; ln -s "$CASE_DIR/outside-marker" "$PLUGIN/.in_use"
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 4 ] && [ "$(field code)" = installed-payload-unsafe ] \
   && [ "$(field safeToReload)" = False ]; then
  ok "(23e) linked live-session directory → integrity failure, no reload"
else bad "(23e) rc=$RC out=$OUT"; fi

# 24. Command output is killed at its hard cap instead of filling memory or temporary storage.
setup_case output-cap devstride user 3.0.0 3.1.0 3.1.0
UP_MODE=large-output; export UP_MODE
OUT="$(run_apply)"; RC=$?
if [ "$RC" -eq 4 ] && [ "$(field code)" = command-output-too-large ] \
   && not_called 'claude:plugin update'; then
  ok "(24) noisy marketplace command → bounded failure before plugin update"
else bad "(24) rc=$RC out=$OUT calls=$(cat "$UP_LOG" 2>/dev/null)"; fi

# 25. Two update processes for the same install cannot refresh/install concurrently.
setup_case lock devstride user 3.0.0 3.1.0 3.1.0
UP_MODE=hold; export UP_MODE
run_apply > "$UP_STATE/first.out" 2>/dev/null & FIRST_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$UP_STATE/holding" ] && break; sleep 0.1; done
OUT="$(run_apply)"; RC=$?
wait "$FIRST_PID"; FIRST_RC=$?
if [ "$RC" -eq 3 ] && [ "$(field code)" = update-in-progress ] && [ "$FIRST_RC" -eq 0 ]; then
  ok "(25) concurrent updater → one lock holder, second process stops"
else bad "(25) rc=$RC first=$FIRST_RC out=$OUT"; fi

# 25b. The helper owns its whole-run deadline, so it kills a mutating CLI process group before
# releasing the lock; an outer hook timeout must never strand an orphan mutation.
setup_case total-deadline devstride user 3.0.0 3.1.0 3.1.0
UP_MODE=deadline-child; export UP_MODE
OUT="$(run_apply_timed)"; RC=$?
sleep 2.2
if [ "$RC" -eq 4 ] && { [ "$(field code)" = command-timeout ] \
      || [ "$(field code)" = update-deadline-exceeded ]; } \
   && [ ! -e "$UP_STATE/orphan-child" ] && not_called 'claude:plugin update'; then
  ok "(25b) whole-run deadline → active CLI descendants killed before unlock"
else bad "(25b) rc=$RC out=$OUT orphan=$([ -e "$UP_STATE/orphan-child" ] && echo yes || echo no)"; fi

# 26. Static command contract: user-only, plain output, shared resolver, no silent mid-loop switch.
if grep -qF 'disable-model-invocation: true' "$ROOT/skills/update/SKILL.md" \
   && grep -qF 'plain-language-output.md' "$ROOT/skills/update/SKILL.md" \
   && grep -qF 'Run `/reload-plugins`' "$ROOT/skills/update/SKILL.md" \
   && grep -qF 'safeToReload' "$ROOT/skills/update/SKILL.md" \
   && grep -qF 'do not reload or invoke' "$ROOT/skills/update/SKILL.md" \
   && grep -qF 'UPDATE_HELPER=' "$ROOT/hooks/version-check.sh" \
   && grep -qF -- '--total-timeout 120' "$ROOT/hooks/version-check.sh" \
   && ! grep -R -qF -- '--yes' "$ROOT/skills/update" "$ROOT/hooks/version-check.sh" \
   && ! grep -R -qF 'marketplace remove' "$ROOT/skills/update"; then
  ok "(26) skill is explicit-only, plain, shared with hook, and stops for reload"
else bad "(26) static update contract drifted"; fi

exit "$FAIL"
