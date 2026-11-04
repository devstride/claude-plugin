#!/bin/bash
# Tests for skills/release/scripts/previous-release-gate.sh — the next release's merge gate: the
# newest release merge into the production branch (anchored pattern; hotfixes ignored) and its
# `release/post-deploy` commit status. A fake `gh` (fixtures/post-deploy/fake-gh.py); no network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; G="$ROOT/skills/release/scripts/previous-release-gate.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"; printf '#!/bin/bash\nexec python3 "%s/scripts/tests/fixtures/post-deploy/fake-gh.py" "$@"\n' "$ROOT" > "$W/bin/gh"; chmod +x "$W/bin/gh"
export PATH="$W/bin:$PATH" POST_DEPLOY_REPO=o/r POST_DEPLOY_POLL_SECONDS=0 POST_DEPLOY_WAIT_MINUTES=1
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; H=cccccccccccccccccccccccccccccccccccccccc
fresh() { # fresh SCOPE — a repo directory with that scope and an empty fake-gh state
  export FAKE_GH_STATE="$W/s$RANDOM"; mkdir -p "$FAKE_GH_STATE/.claude"; cd "$FAKE_GH_STATE" || exit 1
  printf '{"release":{"productionBranch":"master","releaseBranchPattern":"release/<YY-MM-DD>[-n]","clearance":{"provider":"github","scope":"%s"}}}' "$1" > .claude/ds-config.json
}
prs() { printf '%s' "$1" > "$FAKE_GH_STATE/prs.json"; }
status() { printf '[{"context":"release/post-deploy","state":"%s","description":"release/26-11-03 by m5 / wt1-ab"},{"context":"golden-release","state":"success"}]' "$2" > "$FAKE_GH_STATE/status-$1.json"; }
run() { OUT="$(bash "$G" "$@" 2>&1)"; RC=$?; }
TWO='[{"number":20,"headRefName":"release/26-11-03","mergeCommit":{"oid":"'$A'"},"mergedAt":"2026-11-03T20:00:00Z"},
      {"number":10,"headRefName":"release/26-11-02","mergeCommit":{"oid":"'$B'"},"mergedAt":"2026-11-02T20:00:00Z"}]'

fresh cut-to-deploy; run
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: NONE' && ok "(1) no earlier release → 0 NONE" || bad "(1) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; status $A success; run
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: SUCCESS release/26-11-03 (#20) — release/26-11-03 by m5 / wt1-ab$' && ok "(2) success → 0, naming the newest release" || bad "(2) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; status $A pending; run
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: PENDING release/26-11-03 (#20) — release/26-11-03 by m5 / wt1-ab$' && ok "(3) pending → 2, saying who runs the check" || bad "(3) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; status $A failure; run
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: FAILED release/26-11-03 (#20)' && ok "(4) failure → 1" || bad "(4) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; status $A error; run
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: FAILED' && ok "(5) error → 1" || bad "(5) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; run
[ "$RC" = 3 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: NO STATUS release/26-11-03 (#20)' && ok "(6) no status → 3" || bad "(6) rc=$RC: $OUT"
fresh cut-to-deploy
prs '[{"number":30,"headRefName":"phil/hotfix/26-11-04/I1-fix","mergeCommit":{"oid":"'$H'"},"mergedAt":"2026-11-04T09:00:00Z"},
      {"number":20,"headRefName":"release/26-11-03","mergeCommit":{"oid":"'$A'"},"mergedAt":"2026-11-03T20:00:00Z"}]'
status $A success; run
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'SUCCESS release/26-11-03 (#20)' && ! grep -q "$H" "$FAKE_GH_STATE/calls.log" \
  && ok "(7) a newer hotfix merge is ignored; the release before it is read" || bad "(7) rc=$RC: $OUT"
fresh cut-to-deploy
prs '[{"number":40,"headRefName":"x/release/26-11-04","mergeCommit":{"oid":"'$H'"},"mergedAt":"2026-11-04T10:00:00Z"},
      {"number":41,"headRefName":"release/26-11-04/extra","mergeCommit":{"oid":"'$H'"},"mergedAt":"2026-11-04T11:00:00Z"},
      {"number":20,"headRefName":"release/26-11-03-2","mergeCommit":{"oid":"'$A'"},"mergedAt":"2026-11-03T20:00:00Z"}]'
status $A success; run
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'SUCCESS release/26-11-03-2 (#20)' && ok "(8) a head that only contains the pattern is not a release (anchored)" || bad "(8) rc=$RC: $OUT"
fresh release; prs "$TWO"; status $A failure; run
[ "$RC" = 0 ] && [ "$OUT" = "PREVIOUS RELEASE: NOT GATED (release.clearance.scope is release)" ] && [ ! -s "$FAKE_GH_STATE/calls.log" ] \
  && ok "(9) scope release → not gated, and gh is never called" || bad "(9) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; printf success > "$FAKE_GH_STATE/flip-$A"; run --wait
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^waiting: release/26-11-03 (#20) post-deploy check is running' && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: SUCCESS' \
  && ok "(10) --wait polls a pending status until it turns success" || bad "(10) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; status $A pending; POST_DEPLOY_WAIT_MINUTES=0 run --wait
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'still pending after the wait. Finish it with /devstride:release post-deploy only' \
  && ok "(11) --wait gives up at its limit, naming the release and the command that finishes it" || bad "(11) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; touch "$FAKE_GH_STATE/gh-down"; run
[ "$RC" = 4 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: UNREADABLE' && ok "(12) gh unreachable → 4 UNREADABLE, never a pass" || bad "(12) rc=$RC: $OUT"
fresh nonsense; run
[ "$RC" = 4 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: UNREADABLE release.clearance.scope is' && ok "(13) an unknown scope is UNREADABLE (4), never \"the release failed\"" || bad "(13) rc=$RC: $OUT"
fresh cut-to-deploy; printf '{"baseBranch":"main","release":{"clearance":{"provider":"github","scope":"cut-to-deploy"}}}' > .claude/ds-config.json
prs '[{"number":20,"headRefName":"develop","mergeCommit":{"oid":"'$A'"},"mergedAt":"2026-11-03T20:00:00Z"}]'; status $A success; run
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'SUCCESS develop (#20)' && grep -q '"--base", "master"' "$FAKE_GH_STATE/calls.log" \
  && ok "(14) unset branch keys: production master, release source develop (never baseBranch)" || bad "(14) rc=$RC: $OUT"
C="$(head -1 "$FAKE_GH_STATE/calls.log")"; S="$(grep '/status' "$FAKE_GH_STATE/calls.log" | head -1)"
printf '%s' "$C" | grep -q '"--limit", "100"' && printf '%s' "$C" | grep -q '"--search", "sort:updated-desc"' && printf '%s' "$S" | grep -q 'status?per_page=100"' \
  && ok "(14b) it reads 100 merges, newest updated first, and every status context" || bad "(14b) $C / $S"
fresh cut-to-deploy
prs '[{"number":10,"headRefName":"release/26-11-02","mergeCommit":{"oid":"'$B'"},"mergedAt":"2026-11-02T20:00:00Z"},
      {"number":20,"headRefName":"release/26-11-03","mergeCommit":{"oid":"'$A'"},"mergedAt":"2026-11-03T20:00:00Z"}]'
status $A failure; status $B success; run
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'FAILED release/26-11-03 (#20)' && ok "(15) the newest by merge time is read, whatever order gh lists them in" || bad "(15) rc=$RC: $OUT"
fresh cut-to-deploy; printf '{"release":{"releaseBranchPattern":"**","clearance":{"provider":"github","scope":"cut-to-deploy"}}}' > .claude/ds-config.json
prs '[{"number":30,"headRefName":"phil/hotfix/26-11-04/I1-fix","mergeCommit":{"oid":"'$H'"},"mergedAt":"2026-11-04T09:00:00Z"},
      {"number":20,"headRefName":"release/26-11-03","mergeCommit":{"oid":"'$A'"},"mergedAt":"2026-11-03T20:00:00Z"}]'
status $A success; run
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'SUCCESS release/26-11-03 (#20)' && ok "(16) a hotfix head never counts, even under a release pattern that matches it" || bad "(16) rc=$RC: $OUT"
fresh cut-to-deploy; printf '{"releaseTower":{"hotfixPattern":"urgent/**"},"release":{"releaseBranchPattern":"**","clearance":{"provider":"github","scope":"cut-to-deploy"}}}' > .claude/ds-config.json
prs '[{"number":31,"headRefName":"urgent/fix-login","mergeCommit":{"oid":"'$H'"},"mergedAt":"2026-11-04T09:00:00Z"},
      {"number":20,"headRefName":"release/26-11-03","mergeCommit":{"oid":"'$A'"},"mergedAt":"2026-11-03T20:00:00Z"}]'
status $A success; run
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'SUCCESS release/26-11-03 (#20)' && ok "(16b) a configured releaseTower.hotfixPattern is honoured" || bad "(16b) rc=$RC: $OUT"
fresh cut-to-deploy
python3 -c 'import json; print(json.dumps([{"number":100+i,"headRefName":"phil/hotfix/26-11-04/I%d-x" % i,"mergeCommit":{"oid":"c"*40},"mergedAt":"2026-11-04T%02d:%02d:00Z" % (i//60, i%60),"updatedAt":"2026-11-04T%02d:%02d:00Z" % (i//60, i%60)} for i in range(100)]))' > "$FAKE_GH_STATE/prs.json"
run
[ "$RC" = 4 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: UNREADABLE cannot prove which release merged last' && ok "(17) a full page with no release in it is UNREADABLE, never NONE" || bad "(17) rc=$RC: $OUT"
# (17b) full page: 99 hotfixes updated 05:00-06:38 plus an OLD release re-labelled at 07:00; the newest release is off the page
fresh cut-to-deploy
python3 - "$FAKE_GH_STATE" "$A" <<'PY'
import json, sys
rows = [{"number": 200 + i, "headRefName": "phil/hotfix/26-11-04/I%d-x" % i, "mergeCommit": {"oid": "c" * 40},
         "mergedAt": "2026-11-04T%02d:%02d:00Z" % (5 + i // 60, i % 60), "updatedAt": "2026-11-04T%02d:%02d:00Z" % (5 + i // 60, i % 60)} for i in range(99)]
rows.append({"number": 9, "headRefName": "release/26-11-01", "mergeCommit": {"oid": sys.argv[2]}, "mergedAt": "2026-11-01T10:00:00Z", "updatedAt": "2026-11-04T07:00:00Z"})
open(sys.argv[1] + "/prs.json", "w").write(json.dumps(rows))
PY
status $A success; run
[ "$RC" = 4 ] && printf '%s' "$OUT" | grep -q 'cannot prove which release merged last' && ok "(17b) a full page whose release merged before the page boundary is UNREADABLE, not that older release" || bad "(17b) rc=$RC: $OUT"
# (17c) full page whose newest release merged after the boundary is read normally
fresh cut-to-deploy
python3 - "$FAKE_GH_STATE" "$A" <<'PY'
import json, sys
rows = [{"number": 200 + i, "headRefName": "phil/hotfix/26-11-04/I%d-x" % i, "mergeCommit": {"oid": "c" * 40},
         "mergedAt": "2026-11-04T%02d:%02d:00Z" % (5 + i // 60, i % 60), "updatedAt": "2026-11-04T%02d:%02d:00Z" % (5 + i // 60, i % 60)} for i in range(99)]
rows.append({"number": 300, "headRefName": "release/26-11-04", "mergeCommit": {"oid": sys.argv[2]}, "mergedAt": "2026-11-04T06:00:00Z", "updatedAt": "2026-11-04T06:00:00Z"})
open(sys.argv[1] + "/prs.json", "w").write(json.dumps(rows))
PY
status $A success; run
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'SUCCESS release/26-11-04 (#300)' && ok "(17c) a full page whose release merged after the boundary is trusted" || bad "(17c) rc=$RC: $OUT"
fresh cut-to-deploy; printf '{not json' > .claude/ds-config.json; run
[ "$RC" = 4 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: UNREADABLE' && ok "(18) a config file that is not JSON is UNREADABLE (4)" || bad "(18) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; status $A success; printf 1 > "$FAKE_GH_STATE/status-down"; run --wait
[ "$RC" = 4 ] && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: UNREADABLE' && ok "(19) a failed FIRST read is UNREADABLE: nothing is known yet" || bad "(19) rc=$RC: $OUT"
fresh cut-to-deploy; prs "$TWO"; printf success > "$FAKE_GH_STATE/flip-$A"; printf 2 > "$FAKE_GH_STATE/status-down"; run --wait
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'could not read the status' && printf '%s' "$OUT" | grep -q '^PREVIOUS RELEASE: SUCCESS' \
  && ok "(20) a failed read WHILE waiting is retried, not reported" || bad "(20) rc=$RC: $OUT"
exit $FAIL
