#!/bin/bash
# Tests for skills/release/scripts/post-deploy-status.sh — the `release/post-deploy` commit status
# a cut-to-deploy release posts on its production merge commit. A fake `gh`; no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; S="$ROOT/skills/release/scripts/post-deploy-status.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"; printf '#!/bin/bash\nexec python3 "%s/scripts/tests/fixtures/post-deploy/fake-gh.py" "$@"\n' "$ROOT" > "$W/bin/gh"; chmod +x "$W/bin/gh"
export PATH="$W/bin:$PATH" POST_DEPLOY_REPO=o/r
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fresh() {
  export FAKE_GH_STATE="$W/s$RANDOM"; mkdir -p "$FAKE_GH_STATE/.claude"; cd "$FAKE_GH_STATE" || exit 1
  if [ -n "$1" ]; then printf '{"release":{"clearance":{"provider":"github","scope":"%s"}}}' "$1" > .claude/ds-config.json
  else printf '{"release":{"clearance":{"provider":"github"}}}' > .claude/ds-config.json; fi
}
run() { OUT="$(bash "$S" "$@" 2>&1)"; RC=$?; }
call() { python3 -c 'import json,sys; c=[json.loads(l) for l in open(sys.argv[1])]; print("\n".join(c[-1]))' "$FAKE_GH_STATE/calls.log"; }

# Every case runs under BOTH gated scopes (cut-to-deploy and merge-and-deploy): the verdicts must be
# identical. The default scope (release) stays NOT GATED / SKIPPED in each pass.
for GATED in cut-to-deploy merge-and-deploy; do
echo "  -- scope $GATED"
fresh "$GATED"; run "$A" pending "release/26-11-04 by m5 / wt2-9f: post-deploy check running"
C="$(call)"
[ "$RC" = 0 ] && [ "$OUT" = "POST-DEPLOY STATUS: POSTED pending on aaaaaaaaaaaa" ] && printf '%s' "$C" | grep -qx "repos/o/r/statuses/$A" \
  && printf '%s' "$C" | grep -qx 'context=release/post-deploy' && printf '%s' "$C" | grep -qx 'state=pending' \
  && printf '%s' "$C" | grep -qx 'description=release/26-11-04 by m5 / wt2-9f: post-deploy check running' \
  && ok "(1) posts the release/post-deploy context on that sha with the state and description" || bad "(1) rc=$RC: $OUT / $C"
fresh "$GATED"; run "$A" success "$(printf 'x%.0s' $(seq 1 200))"
D="$(call | sed -n 's/^description=//p')"
[ "$RC" = 0 ] && [ "${#D}" -eq 140 ] && ok "(2) the description is capped at 140 characters" || bad "(2) rc=$RC len=${#D}"
fresh release; run "$A" success "x"
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^POST-DEPLOY STATUS: SKIPPED' && [ ! -s "$FAKE_GH_STATE/calls.log" ] \
  && ok "(3) scope release → posts nothing" || bad "(3) rc=$RC: $OUT"
fresh ""; run "$A" success "x"
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^POST-DEPLOY STATUS: SKIPPED' && [ ! -s "$FAKE_GH_STATE/calls.log" ] \
  && ok "(4) scope absent (the default) → posts nothing" || bad "(4) rc=$RC: $OUT"
fresh "$GATED"; run abc123 success "x"
[ "$RC" = 2 ] && ok "(5) a short sha is refused (the full merge commit is required)" || bad "(5) rc=$RC: $OUT"
fresh "$GATED"; run "$A" done "x"
[ "$RC" = 2 ] && ok "(6) an unknown state is refused" || bad "(6) rc=$RC: $OUT"
fresh "$GATED"; touch "$FAKE_GH_STATE/gh-down"; run "$A" failure "x"
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q '^POST-DEPLOY STATUS: FAILED' && ok "(7) a failed post says FAILED and exits 1" || bad "(7) rc=$RC: $OUT"
done
exit $FAIL
