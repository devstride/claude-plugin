#!/bin/bash
# Tests for the opt-in session-start fetch in hooks/version-check.sh
# (`localEnvironment.fetchOnSessionStart`). The fake plugin omits the update helper, so the
# version half finishes quietly without network after the fetch has run.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$ROOT/hooks/version-check.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export XDG_CACHE_HOME="$WORK/cache"
FAKE="$WORK/plugin"; mkdir -p "$FAKE/.claude-plugin" "$FAKE/skills/setup/references"
printf '{"version":"9.9.9"}' > "$FAKE/.claude-plugin/plugin.json"

git_q() { git "$@" >/dev/null 2>&1; }
# mkpair NAME CONFIG — an upstream bare repo and a clone whose main branch tracks it.
mkpair() {
  local up="$WORK/$1-upstream" clone="$WORK/$1" seed="$WORK/$1-seed"
  git_q init -q --bare "$up"; git_q -C "$up" symbolic-ref HEAD refs/heads/main
  git_q init -q "$seed"; git -C "$seed" config user.name t; git -C "$seed" config user.email t@example.com
  git_q -C "$seed" checkout -b main
  printf 'one\n' > "$seed/file"; git_q -C "$seed" add file; git_q -C "$seed" commit -qm one
  git_q -C "$seed" push -q "$up" main
  git_q clone -q "$up" "$clone"; git -C "$clone" config user.name t; git -C "$clone" config user.email t@example.com
  mkdir -p "$clone/.claude"; printf '%s' "$2" > "$clone/.claude/ds-config.json"
  printf '%s' "$clone"
}
advance_upstream() { # push one more commit to NAME's upstream from the seed checkout
  local seed="$WORK/$1-seed" up="$WORK/$1-upstream"
  printf 'two\n' >> "$seed/file"; git_q -C "$seed" commit -qam two; git_q -C "$seed" push -q "$up" main
}
run() { CLAUDE_PLUGIN_ROOT="$FAKE" bash "$HOOK" <<< "$(printf '{"cwd":"%s"}' "$1")" 2>/dev/null; }
remote_head() { git -C "$1" rev-parse --verify -q refs/remotes/origin/main; }

# (1) key absent → nothing is fetched and nothing is printed
R="$(mkpair absent '{}')"; advance_upstream absent
BEFORE="$(remote_head "$R")"; OUT="$(run "$R")"
if [ "$(remote_head "$R")" = "$BEFORE" ] && [ -z "$OUT" ]; then
  ok "(1) key absent → no fetch, silent"
else bad "(1) out=$OUT"; fi

# (2) key true and the upstream moved → fetched, one line naming how far behind
R="$(mkpair behind '{"localEnvironment":{"fetchOnSessionStart":true}}')"; advance_upstream behind
BEFORE="$(remote_head "$R")"; OUT="$(run "$R")"
if [ "$(remote_head "$R")" != "$BEFORE" ] && printf '%s' "$OUT" | grep -q 'behind its upstream' \
   && [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ] && printf '%s' "$OUT" | grep -q '1 commit'; then
  ok "(2) fetchOnSessionStart → fetched, one line: 1 commit behind"
else bad "(2) out=$OUT"; fi

# (3) key true and already current → fetched, silent
R="$(mkpair current '{"localEnvironment":{"fetchOnSessionStart":true}}')"
OUT="$(run "$R")"
if [ -z "$OUT" ]; then ok "(3) current after fetch → silent"; else bad "(3) out=$OUT"; fi

# (4) key true but the fetch hangs → killed at the deadline, silent, hook still exits 0
R="$(mkpair hang '{"localEnvironment":{"fetchOnSessionStart":true}}')"; advance_upstream hang
mkdir -p "$WORK/bin"; REAL_GIT="$(command -v git)"
cat > "$WORK/bin/git" <<STUB
#!/bin/bash
if [ "\${1:-}" = "fetch" ]; then sleep 30; exit 0; fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$WORK/bin/git"
START=$(date +%s)
OUT="$(PATH="$WORK/bin:$PATH" DEVSTRIDE_SESSION_FETCH_TIMEOUT=1 run "$R")"; CODE=$?
ELAPSED=$(( $(date +%s) - START ))
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ] && [ "$ELAPSED" -lt 10 ]; then
  ok "(4) hanging fetch → killed at the deadline (${ELAPSED}s), silent, exit 0"
else bad "(4) code=$CODE elapsed=${ELAPSED}s out=$OUT"; fi

# (5) a non-boolean value is an invalid config: no fetch, and the rest of the hook stays quiet
R="$(mkpair invalid '{"localEnvironment":{"fetchOnSessionStart":"yes"}}')"; advance_upstream invalid
BEFORE="$(remote_head "$R")"; OUT="$(run "$R")"
if [ "$(remote_head "$R")" = "$BEFORE" ] && [ -z "$OUT" ]; then
  ok "(5) non-boolean value → treated as invalid config, no fetch, silent"
else bad "(5) out=$OUT"; fi

exit $FAIL
