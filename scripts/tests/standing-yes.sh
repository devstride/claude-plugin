#!/bin/bash
# Tests for skills/release/scripts/standing-yes.py — the owner's standing yes for light releases,
# and (from case F1) the written standing yes for full releases with approved migrations.
# A fake `gh` on PATH answers `gh pr view <n>` from one file per pull-request number (the release
# pull request is #42) and `gh pr list` for each train title from its own file, so the reviewed
# train is found by the helper (the latest merged one, merged into the head), never passed in. One passing case, then one case per condition,
# each failing only that condition: the first failed condition is what the script names, and
# nothing but all nine conditions answers MERGE. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/release/scripts/standing-yes.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

g() { git -C "$WORK/repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
mkdir -p "$WORK/bin" "$WORK/prs"
# The configuration is COMMITTED: the helper reads it from the release head, never the working
# folder. cfg() rebuilds the whole graph with that configuration in its base commit; after the
# graph is built the working folder is left holding a config that turns everything ON, so a
# helper that read the working folder would answer MERGE where the committed one says ASK.
build() {
  rm -rf "$WORK/repo"; git init -q -b develop "$WORK/repo"; mkdir -p "$WORK/repo/.claude"
  printf '%s\n' "$1" > "$WORK/repo/.claude/ds-config.json"
  echo 0 > "$WORK/repo/f"; g add -A; g commit -q -m base
  g checkout -q -b train; echo a > "$WORK/repo/f"; g commit -q -am "train snapshot, reviewed"
  TRAIN="$(g rev-parse HEAD)"                                                   # the reviewed train head
  g checkout -q develop; g merge -q --no-ff -m "Merge the train" train; MERGE="$(g rev-parse HEAD)"
  g commit -q --allow-empty -m "release branch cut"; RELEASE="$(g rev-parse HEAD)"   # same tree, another commit
  echo b > "$WORK/repo/f"; g commit -q -am "a fix on the release branch"; FIXED="$(g rev-parse HEAD)"   # another tree
  g checkout -q -b elsewhere "$TRAIN~1"; g commit -q --allow-empty -m "never merged"; STRAY="$(g rev-parse HEAD)"
  printf '%s\n' "$AMBIENT" > "$WORK/repo/.claude/ds-config.json"
}
AMBIENT='{"release": {"classifySkill": "classify", "clearance": {"provider": "github"}, "lightRelease": {"standingYes": true}}}'

# the fake gh: `gh pr view <n> --json ...` prints prs/<n>.json, or fails when there is none
cat > "$WORK/bin/gh" <<SH
#!/bin/bash
if [ "\$1 \$2" = "pr list" ]; then
  case " \$* " in *" --base develop "*) ;; *) echo "fake gh: only develop holds trains here" >&2; exit 1;; esac
  case " \$* " in *" --state merged "*) ;; *) echo "fake gh: only merged trains are asked for" >&2; exit 1;; esac
  case "\$*" in *'"Release train:"'*) f=list-release;; *'"Support train:"'*) f=list-support;; *) exit 1;; esac
  [ -f "$WORK/prs/fail-list" ] && exit 1
  if [ -f "$WORK/prs/\$f.json" ]; then cat "$WORK/prs/\$f.json"; else echo '[]'; fi; exit 0
fi
[ "\$1 \$2" = "pr view" ] || { echo "fake gh: unexpected \$*" >&2; exit 1; }
[ -f "$WORK/prs/\$3.json" ] || { echo "no pull request \$3" >&2; exit 1; }
cat "$WORK/prs/\$3.json"
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
pr() { # number state title base head [isDraft] — baseRefOid: wherever origin/master points now (the live base)
  local base_oid; base_oid="$(g rev-parse -q --verify refs/remotes/origin/master 2>/dev/null)"
  printf '{"state": "%s", "title": "%s", "baseRefName": "%s", "baseRefOid": "%s", "headRefOid": "%s", "isDraft": %s}' "$2" "$3" "$4" "$base_oid" "$5" "${6:-false}" > "$WORK/prs/$1.json"
}
release_pr() { pr 42 "${2:-OPEN}" "Release 26-01-15" "${3:-master}" "${1:-$RELEASE}" "${4:-false}"; }
row() { # number title marker mergedAt head merge
  printf '{"number": %s, "title": "%s", "body": "<!-- %s source 1111111 snapshot 2222222 -->", "mergedAt": "%s", "headRefOid": "%s", "mergeCommit": {"oid": "%s"}}' "$@"
}
trains() { printf '[%s]' "$1" > "$WORK/prs/list-release.json"; printf '[%s]' "${2:-}" > "$WORK/prs/list-support.json"; }
fresh() {
  OLD="$(row 30 "Release train: 1 one-off(s) for release 26-01-14" devstride:release-train 2026-01-14T18:00:00Z "$STRAY" "$STRAY")"
  NEW="$(row 40 "Release train: 2 one-off(s) for release 26-01-15" devstride:release-train 2026-01-15T17:00:00Z "$TRAIN" "$MERGE")"
  rm -f "$WORK/prs/"*; release_pr; trains "$OLD, $NEW"
}

cfg() { build "$1"; }
cfg '{"baseBranch": "main", "release": {"classifySkill": "classify", "clearance": {"provider": "github"}, "lightRelease": {"standingYes": true}}}'

TOWER=$'Tower: clear\nOn final: #42 release/26-01-15 (draft)\nWaiting: #43 release/26-01-15-2'
# the passing argument set; each case overrides one value
base() {
  fresh
  PR=42 HEAD_ARG="$RELEASE" CLASS="RELEASE CLASS: LIGHT" CHECKS=green UNRESOLVED=0
  PRESHIP="PRE-SHIP: PASS (2 ran, 0 waived)" PREMERGE="PRE-MERGE: CLEAR" PREV=0 DEV=not-applicable TOWER_ARG="$TOWER" NO_DEV="" REVIEWED=""
}
run() {
  local dev=(--dev-deploy "$DEV"); [ -n "$NO_DEV" ] && dev=()
  local reviewed=(); [ -n "${REVIEWED:-}" ] && reviewed=(--reviewed-head "$REVIEWED")
  (cd "$WORK/repo" && python3 "$HELPER" --pr "$PR" --head "$HEAD_ARG" --class "$CLASS" \
    --checks "$CHECKS" --unresolved "$UNRESOLVED" --pre-ship "$PRESHIP" --pre-merge "$PREMERGE" --previous-release "$PREV" ${dev[@]+"${dev[@]}"} --tower "$TOWER_ARG" ${reviewed[@]+"${reviewed[@]}"} 2>&1)
}
expect() { # label, expected exit, regex
  local out code; out="$(run)"; code=$?
  if [ "$code" = "$2" ] && printf '%s\n' "$out" | grep -Eq "$3"; then ok "$1"; else bad "$1  (exit $code) $out"; fi
}

base; expect "(1) every condition holds → MERGE naming the release head (another commit, the same tree)" 0 "^MERGE $RELEASE\$"
base; expect "(1e) ...with the light comment on the next line" 0 '^COMMENT Merged on the standing yes for light releases identical to the reviewed train \(release.lightRelease.standingYes\)\.$'

base; DEV=0; expect "(1b) with the dev-deploy wait answered 0 → MERGE" 0 '^MERGE [0-9a-f]{40}$'
base; PRESHIP="PRE-SHIP: NOTHING TO RUN"; expect "(1c) nothing to pre-ship → MERGE" 0 '^MERGE [0-9a-f]{40}$'
base; expect "(1d) releaseSource absent → develop, not baseBranch (main)" 0 '^MERGE '

cfg '{"release": {"classifySkill": "classify"}}'
base; expect "(2) the standing yes is off → ASK" 0 '^ASK the standing yes is off \(neither'
[ "$(cat "$WORK/repo/.claude/ds-config.json")" = "$AMBIENT" ] && ok "(2h) ...even with the working folder's config switching everything on" || bad "(2h) the ambient config was not in place"
cfg '{"release": {"classifySkill": "classify", "lightRelease": {"standingYes": "yes"}}}'
base; expect "(2b) a non-boolean standingYes is off → ASK" 0 '^ASK the standing yes is off'
cfg '{"baseBranch": "main", "release": {"classifySkill": "classify", "clearance": {"provider": "github"}, "lightRelease": {"standingYes": true}}}'

cfg '{"release": {"classifySkill": "classify", "lightRelease": {"standingYes": true}}}'
base; expect "(2c) no release.clearance, even with a convincing On final line → ASK" 0 '^ASK no usable release.clearance is configured'
cfg '{"release": {"classifySkill": "classify", "clearance": {"scope": "cut-to-deploy"}, "lightRelease": {"standingYes": true}}}'
base; expect "(2d) a clearance block with neither provider nor commands → ASK" 0 '^ASK no usable release.clearance is configured'
V='"claim": "c", "status": "s", "heartbeat": "h", "release": "r", "adopt": "a"'
for bad_clearance in '{"provider": "bogus"}' '{"commands": {}}' "{\"commands\": {$V, \"adopt\": \"\"}}" "{\"provider\": \"github\", \"commands\": {$V}}"; do
  cfg "{\"release\": {\"classifySkill\": \"classify\", \"clearance\": $bad_clearance, \"lightRelease\": {\"standingYes\": true}}}"
  base; expect "(2e) an unusable clearance $bad_clearance → ASK" 0 '^ASK no usable release.clearance is configured'
done
cfg "{\"release\": {\"classifySkill\": \"classify\", \"clearance\": {\"commands\": {$V}}, \"lightRelease\": {\"standingYes\": true}}}"
base; expect "(2f) a complete commands clearance → MERGE" 0 '^MERGE '
for bad_classifier in '' ', "classifySkill": ""' ', "classifySkill": true'; do
  cfg "{\"release\": {\"clearance\": {\"provider\": \"github\"}, \"lightRelease\": {\"standingYes\": true}$bad_classifier}}"
  base; expect "(2g) no usable classifySkill ($bad_classifier) with a caller's LIGHT line → ASK" 0 '^ASK no release.classifySkill is configured'
done
cfg '{"baseBranch": "main", "release": {"classifySkill": "classify", "clearance": {"provider": "github"}, "lightRelease": {"standingYes": true}}}'
base; release_pr "$RELEASE" CLOSED; expect "(3c) a closed release pull request → ASK" 0 '^ASK pull request #42 is not open into master'
base; release_pr "$RELEASE" OPEN develop; expect "(3d) a release pull request retargeted away from production → ASK" 0 '^ASK pull request #42 is not open into master'
base; CLASS="RELEASE CLASS: FULL"; expect "(3) a full release → ASK" 0 '^ASK not a light release \(RELEASE CLASS: FULL\)$'
base; CLASS=""; expect "(3b) no class line → ASK" 0 '^ASK not a light release \(no class line\)$'

base; release_pr "$FIXED"; HEAD_ARG="$FIXED"; expect "(4) a fix on the release branch changed the tree → ASK" 0 '^ASK the head.s tree .* differs from the reviewed train tree'
base; release_pr "$FIXED"; expect "(4a) the pull request moved past the head given (a stale head) → ASK" 0 '^ASK pull request #42 is at .* not the head'
base; HEAD_ARG="$TRAIN"; expect "(4c) the train head passed as the release head → ASK" 0 '^ASK pull request #42 is at .* not the head'
base; rm "$WORK/prs/42.json"; expect "(4d) the release pull request cannot be read → ASK" 0 '^ASK the current head of pull request #42 cannot be read$'
base; HEAD_ARG="deadbeef"; expect "(4b) an unreadable head → ASK" 0 '^ASK the head deadbeef cannot be read$'
base; release_pr "$FIXED"; HEAD_ARG="$FIXED"; trains "$OLD, $NEW, $(row 41 "Release train: x" devstride:release-train 2026-01-15T16:00:00Z "$FIXED" "$MERGE")"
expect "(4f) a lookalike train at the fix's own head (F/F) is not the latest merged train → ASK" 0 '^ASK the head.s tree .* differs from the reviewed train tree'
base; trains "$OLD, $NEW, $(row 41 "Release train: x" devstride:release-train 2026-01-15T17:30:00Z "$RELEASE" "$STRAY")"
expect "(4g) a later train-looking pull request not merged into the head → ASK" 0 '^ASK the latest train #41 is not merged into the head'
base; trains "$OLD, $NEW, $(row 41 "Release train: x" no-marker 2026-01-15T17:30:00Z "$STRAY" "$STRAY")"
expect "(4h) a later train title without the body marker is ignored → MERGE" 0 '^MERGE '
base; trains "$OLD, $NEW, $(printf '{"number": 41, "title": "Release train: x", "body": "<!-- devstride:release-train-holder abcdef012345 on m -->", "mergedAt": "2026-01-15T17:30:00Z", "headRefOid": "%s", "mergeCommit": {"oid": "%s"}}' "$STRAY" "$STRAY")"
expect "(4m) a later train title carrying only the holder marker is not a reviewed train → MERGE" 0 '^MERGE '
base; trains "$OLD, $NEW, $(printf '{"number": 41, "title": "Release train: x", "body": "see devstride:release-train for the range", "mergedAt": "2026-01-15T17:30:00Z", "headRefOid": "%s", "mergeCommit": {"oid": "%s"}}' "$STRAY" "$STRAY")"
expect "(4n) prose naming the marker is not a marker → MERGE" 0 '^MERGE '
base; trains "$OLD, $(row 41 "Ship it" devstride:release-train 2026-01-15T17:30:00Z "$STRAY" "$STRAY"), $NEW"
expect "(4i) a later pull request whose title is not a train is ignored → MERGE" 0 '^MERGE '
base; trains "$OLD" "$(row 40 "Support train: 2 one-off(s)" devstride:support-train 2026-01-15T17:00:00Z "$TRAIN" "$MERGE")"
expect "(4j) the old Support train: spelling is found → MERGE" 0 '^MERGE '
base; trains ""; expect "(4k) no merged train at all → ASK" 0 '^ASK no merged release-train pull request into develop'
base; touch "$WORK/prs/fail-list"; expect "(4l) gh cannot list the trains → ASK" 0 '^ASK the merged release-train pull requests into develop cannot be read$'
base; trains "$OLD, $(row 40 "Release train: x" devstride:release-train 2026-01-15T17:00:00Z feedface "$MERGE")"
expect "(4e) an unreadable reviewed head → ASK" 0 '^ASK the reviewed train head of #40 cannot be read$'

base; CHECKS=red; expect "(5) a required check not green → ASK" 0 '^ASK a required check on the head is not green$'
base; UNRESOLVED=1; expect "(6) an unresolved thread → ASK" 0 '^ASK 1 review thread\(s\) unresolved$'
base; PRESHIP="PRE-SHIP: PASS (2 ran, 1 waived)"; expect "(7) a waived pre-ship check → ASK" 0 '^ASK the pre-ship checks did not all pass unwaived'
base; PRESHIP="PRE-SHIP: FAIL golden"; expect "(7b) a failed pre-ship check → ASK" 0 '^ASK the pre-ship checks did not all pass unwaived'
base; PREMERGE="PRE-MERGE: NOT CONFIGURED"; expect "(7c) no pre-merge hook configured → MERGE" 0 '^MERGE '
cfg '{"release": {"classifySkill": "classify", "preMergeSkill": "checkpoint", "clearance": {"provider": "github"}, "lightRelease": {"standingYes": true}}}'
base; PREMERGE="PRE-MERGE: NOT CONFIGURED"; expect "(7g) NOT CONFIGURED while release.preMergeSkill is set → ASK" 0 '^ASK the pre-merge check did not clear \(PRE-MERGE: NOT CONFIGURED\)$'
base; expect "(7h) the configured hook answered CLEAR → MERGE" 0 '^MERGE '
cfg '{"baseBranch": "main", "release": {"classifySkill": "classify", "clearance": {"provider": "github"}, "lightRelease": {"standingYes": true}}}'
base; PREMERGE="PRE-MERGE: NOT RUN"; expect "(7d) the pre-merge check did not run → ASK" 0 '^ASK the pre-merge check did not clear \(PRE-MERGE: NOT RUN\)$'
base; PREMERGE="PRE-MERGE: HOLD checkpoint missing"; expect "(7e) a pre-merge hold → ASK" 0 '^ASK the pre-merge check did not clear'
base; PREMERGE=""; expect "(7f) no pre-merge verdict → ASK" 0 '^ASK the pre-merge check did not clear \(no verdict\)$'
base; PREV=2; expect "(8) the previous release still pending → ASK" 0 '^ASK the previous-release gate answered 2, not 0$'
base; DEV=2; expect "(9) the dev deploy not yet done → ASK" 0 '^ASK the dev-deploy wait answered 2, not 0$'
base; NO_DEV=1; expect "(9b) the dev-deploy answer omitted → ERROR, never a MERGE" 1 '^ERROR .*--dev-deploy'
cfg '{"release": {"classifySkill": "classify", "clearance": {"provider": "github"}, "devDeployVerification": "verify-dev", "lightRelease": {"standingYes": true}}}'
base; expect "(9c) not-applicable while devDeployVerification is configured → ASK" 0 '^ASK release.devDeployVerification is configured'
base; DEV=0; expect "(9d) the configured wait answered 0 → MERGE" 0 '^MERGE '
cfg '{"release": {"classifySkill": "classify", "clearance": {"provider": "github"}, "devDeployVerification": "", "lightRelease": {"standingYes": true}}}'
base; expect "(9e) an empty devDeployVerification still counts as configured → ASK" 0 '^ASK release.devDeployVerification is configured'
cfg '{"baseBranch": "main", "release": {"classifySkill": "classify", "clearance": {"provider": "github"}, "lightRelease": {"standingYes": true}}}'
base; TOWER_ARG=$'Tower: clear\nOn final: #41 release/26-01-14\nWaiting: #42 release/26-01-15'; expect "(10) another release is on final → ASK" 0 '^ASK pull request #42 is not the one release On final'
base; TOWER_ARG=$'On final: #421 release/x'; expect "(10b) #421 on final does not match #42 → ASK" 0 '^ASK pull request #42 is not the one release On final'
base; TOWER_ARG=$'On final: #42-old release/x'; expect "(10c) #42-old is not #42 → ASK" 0 '^ASK pull request #42 is not the one release On final'
base; TOWER_ARG=$'On final: #42 release/old\nOn final: #43 release/current'; expect "(10d) two On final lines → ASK" 0 '^ASK pull request #42 is not the one release On final'
base; TOWER_ARG=$'On final: #42'; expect "(10e) an On final line with no head → ASK" 0 '^ASK pull request #42 is not the one release On final'

base; CLASS="RELEASE CLASS: FULL"; CHECKS=red
expect "(11) several failures → the first in order is named" 0 '^ASK not a light release'

base; CHECKS=amber; expect "(12) a bad argument → ERROR, exit 1" 1 '^ERROR '
out="$(cd "$WORK/repo" && python3 "$HELPER" --pr 42 2>&1)"; code=$?
[ "$code" = 1 ] && printf '%s\n' "$out" | grep -q '^ERROR ' && ok "(12b) missing arguments → ERROR, exit 1" || bad "(12b) (exit $code) $out"
cfg '{nope'
base; expect "(13) an unreadable committed config → ERROR, exit 1" 1 '^ERROR .*cannot be read as JSON'

# ── the full route: release.fullRelease, the owner's written standing yes ──
# fullgraph: production (master) at the base commit; the release adds one migration on top of the
# light graph's FIXED head (a tree no train reviewed, so only the full route can answer MERGE).
MIG="db/migrations/sql/0352_add_x.sql"
FULLCFG() { # [approved-entries-json] [extra fullRelease keys]
  printf '{"release": {"clearance": {"provider": "github"}, "fullRelease": {"standingYes": true, "ownerDecision": "2026-11-07", "migrationGlobs": ["db/migrations/sql/*.sql"], "approvedMigrations": [%s]%s}}}' "${1:-}" "${2:-}"
}
fullgraph() { # config, [migration content]
  build "$1"
  g branch -q master "$(g rev-list --max-parents=0 HEAD)"
  g update-ref refs/remotes/origin/master master
  g checkout -q -b rel "$FIXED"
  mkdir -p "$WORK/repo/db/migrations/sql/meta"
  printf '%s\n' "${2:-create table x (id int);}" > "$WORK/repo/$MIG"; echo '{"j":1}' > "$WORK/repo/db/migrations/sql/meta/_journal.json"
  g add db; g commit -q -m "migration 0352"; FULLHEAD="$(g rev-parse HEAD)"; BLOB="$(g rev-parse "HEAD:$MIG")"
  g commit -q --allow-empty -m "review re-trigger"; RETRIGGER="$(g rev-parse HEAD)"
  g checkout -q develop
}
approved() { printf '{"blob": "%s", "path": "%s", "item": "I20100", "approved": "2026-11-07"}' "${1:-$BLOB}" "$MIG"; }
fbase() { base; HEAD_ARG="$FULLHEAD" REVIEWED="$FULLHEAD" CLASS="RELEASE CLASS: FULL"; release_pr "$FULLHEAD"; }
refull() { fullgraph "$(FULLCFG "$1" "${2:-}")" "${3:-}"; }

fullgraph "$(FULLCFG)"; FIRSTBLOB="$BLOB"
refull "$(approved "$FIRSTBLOB")"
fbase; expect "(F1) a full release, every gate green, its migration approved by content → MERGE" 0 "^MERGE $FULLHEAD\$"
fbase; expect "(F1b) ...with the dated full comment naming the approved migration" 0 '^COMMENT Merged on the owner.s written standing yes .*owner decision 2026-11-07\). Migrations: db/migrations/sql/0352_add_x.sql \(I20100, approved 2026-11-07\)\.$'
fbase; CLASS="RELEASE CLASS: LIGHT"; expect "(F1c) a light release whose tree no train reviewed, full yes on → MERGE by the full route" 0 '^COMMENT Merged on the owner.s written standing yes'
fbase; HEAD_ARG="$RETRIGGER"; release_pr "$RETRIGGER"; expect "(F1d) review's same-tree re-trigger commit on top of the reviewed head → MERGE" 0 "^MERGE $RETRIGGER\$"
fbase; expect "(F1e) the meta journal beside it is not a migration (only migrationGlobs count)" 0 '^MERGE '

refull ""
fbase; expect "(F2) a new migration nobody approved → ASK naming it" 0 "^ASK the migration $MIG \\(blob [0-9a-f]{12}\\) has no owner approval for this content\$"
refull "$(approved "$FIRSTBLOB")" "" "create table x (id bigint);"
fbase; expect "(F2b) the approved migration changed after its approval → ASK" 0 "^ASK the migration $MIG .* has no owner approval"
refull '{"blob": "abc", "path": "p", "item": "I1", "approved": "2026-11-07"}'
fbase; expect "(F2c) a malformed approval entry → ASK" 0 '^ASK release.fullRelease.approvedMigrations\[0\] needs blob'
refull "$(approved "$FIRSTBLOB" | sed 's/"approved": "2026-11-07"/"approved": "2026-13-40"/')"
fbase; expect "(F2d) an approval with an impossible date → ASK" 0 '^ASK release.fullRelease.approvedMigrations\[0\]'
refull "$(approved "$FIRSTBLOB")"
fbase; g -c core.hooksPath=/dev/null checkout -q rel; g rm -q "$MIG"; g commit -q -m "drop it"; DROP="$(g rev-parse HEAD)"; g update-ref refs/remotes/origin/master "$FULLHEAD"; g checkout -q develop
HEAD_ARG="$DROP" REVIEWED="$DROP"; release_pr "$DROP"; expect "(F2e) a release that deletes a migration production has → ASK" 0 "^ASK the release deletes the migration $MIG\$"
g update-ref refs/remotes/origin/master master
fbase; g update-ref -d refs/remotes/origin/master; expect "(F2f) production cannot be read → ASK" 0 '^ASK origin/master cannot be read'
g update-ref refs/remotes/origin/master master
fbase; g update-ref refs/remotes/origin/master "$FULLHEAD"; expect "(F2g) a stale origin/master (not the pull request's live base) → ASK" 0 '^ASK origin/master is at .* but the pull request.s base is at'
g update-ref refs/remotes/origin/master master
refull "$(approved "$FIRSTBLOB" | sed 's/"approved": "2026-11-07"/"approved": "2999-01-01"/')"
fbase; expect "(F2h) an approval dated in the future → ASK" 0 '^ASK release.fullRelease.approvedMigrations\[0\] is dated 2999-01-01, after today'
refull ""
mkdir -p "$WORK/repo/sub"; fbase; g config diff.relative true
out="$(cd "$WORK/repo/sub" && python3 "$HELPER" --pr 42 --head "$FULLHEAD" --class "RELEASE CLASS: FULL" --checks green --unresolved 0 --pre-ship "PRE-SHIP: NOTHING TO RUN" --pre-merge "PRE-MERGE: CLEAR" --previous-release 0 --dev-deploy not-applicable --tower "$TOWER" --reviewed-head "$FULLHEAD" 2>&1)"
printf '%s\n' "$out" | grep -q "^ASK the migration $MIG" && ok "(F2i) diff.relative set, run from a subfolder → the unapproved migration is still found" || bad "(F2i) $out"
g config --unset diff.relative
fullgraph "$(FULLCFG "" ', "migrationGlobs": ["db/**"]' | sed 's/"migrationGlobs": \["db\/migrations\/sql\/\*.sql"\], //')"
g checkout -q rel; printf 'x\n' > "$WORK/repo/db/migrations/001
new.sql"; g add db; g commit -q -m "newline name"; NL="$(g rev-parse HEAD)"; g checkout -q develop
fbase; HEAD_ARG="$NL" REVIEWED="$NL"; release_pr "$NL"; expect "(F2j) a file name holding a newline → ASK, never classified" 0 '^ASK the release changes a file whose name holds a control character'
fullgraph "$(FULLCFG)"
g checkout -q rel; ln -s ../pending.txt "$WORK/repo/db/migrations/sql/0400_link.sql"; g add db; g commit -q -m "link migration"; LNK="$(g rev-parse HEAD)"
refull "$(approved "$FIRSTBLOB"), $(approved "$(g rev-parse "$LNK:db/migrations/sql/0400_link.sql")")"
g checkout -q rel; ln -s ../pending.txt "$WORK/repo/db/migrations/sql/0400_link.sql"; g add db; g commit -q -m "link migration"; LNK="$(g rev-parse HEAD)"; g checkout -q develop
fbase; HEAD_ARG="$LNK" REVIEWED="$LNK"; release_pr "$LNK"; expect "(F2k) a migration that is a symbolic link, even with its link blob approved → ASK" 0 '^ASK the migration db/migrations/sql/0400_link.sql is not a plain file \(mode 120000\)'

fbase; REVIEWED=""; expect "(F3) no --reviewed-head → ASK" 0 '^ASK no --reviewed-head as a full commit id'
fbase; REVIEWED="HEAD"; (cd "$WORK/repo" && g checkout -q "$FULLHEAD"); expect "(F3f) a moving ref as --reviewed-head (HEAD at the head) → ASK, never resolved" 0 '^ASK no --reviewed-head as a full commit id'
(cd "$WORK/repo" && g checkout -q develop)
fbase; REVIEWED="${FULLHEAD:0:12}"; expect "(F3g) an abbreviated reviewed head → ASK" 0 '^ASK no --reviewed-head as a full commit id'
fbase; REVIEWED="$RELEASE"; expect "(F3b) the reviewed head is an older, different tree → ASK" 0 '^ASK the head [0-9a-f]{12} is not the reviewed head'
fbase; release_pr "$FULLHEAD" OPEN master true; expect "(F3c) the release pull request is still a draft → ASK" 0 '^ASK pull request #42 is still a draft'
fbase; release_pr "$RELEASE"; expect "(F3d) the pull request moved past the head given → ASK" 0 '^ASK pull request #42 is at'
fbase; CLASS=""; expect "(F3e) no class line → ASK" 0 '^ASK no release class \(no class line\)$'
fbase; CHECKS=red; expect "(F4) a red required check → ASK" 0 '^ASK a required check on the head is not green$'
fbase; PRESHIP="PRE-SHIP: PASS (2 ran, 1 waived)"; expect "(F4b) a waived pre-ship check → ASK" 0 '^ASK the pre-ship checks did not all pass unwaived'
fbase; PREMERGE="PRE-MERGE: HOLD checkpoint missing"; expect "(F4c) a pre-merge hold → ASK" 0 '^ASK the pre-merge check did not clear'
fbase; TOWER_ARG=$'On final: #41 release/x'; expect "(F4d) another release on final → ASK" 0 '^ASK pull request #42 is not the one release On final'
fbase; PREV=1; expect "(F4e) the previous release not cleared → ASK" 0 '^ASK the previous-release gate answered 1'

for bad_decision in '' '"ownerDecision": "yes", ' '"ownerDecision": "2999-01-01", ' '"ownerDecision": "2026-02-30", '; do
  fullgraph "$(printf '{"release": {"clearance": {"provider": "github"}, "fullRelease": {"standingYes": true, %s"migrationGlobs": ["db/migrations/sql/*.sql"], "approvedMigrations": [%s]}}}' "$bad_decision" "$(approved "$FIRSTBLOB")")"
  fbase; expect "(F5) ownerDecision ${bad_decision:-absent} → ASK" 0 '^ASK release.fullRelease.ownerDecision must be the date'
done
for bad_globs in '' '"migrationGlobs": [], ' '"migrationGlobs": "db/**", '; do
  fullgraph "$(printf '{"release": {"clearance": {"provider": "github"}, "fullRelease": {"standingYes": true, "ownerDecision": "2026-11-07", %s"approvedMigrations": []}}}' "$bad_globs")"
  fbase; expect "(F5b) migrationGlobs ${bad_globs:-absent} → ASK" 0 '^ASK release.fullRelease.migrationGlobs must list'
done
fullgraph '{"release": {"fullRelease": {"standingYes": true, "ownerDecision": "2026-11-07", "migrationGlobs": ["db/**"]}}}'
fbase; expect "(F5c) no clearance → ASK" 0 '^ASK no usable release.clearance is configured'
fullgraph "$(printf '{"release": {"clearance": {"provider": "github"}, "fullRelease": {"standingYes": "yes", "ownerDecision": "2026-11-07", "migrationGlobs": ["db/**"]}}}')"
fbase; expect "(F5d) a non-boolean full standingYes is off → ASK" 0 '^ASK the standing yes is off'

fullgraph "$(printf '{"release": {"classifySkill": "c", "clearance": {"provider": "github"}, "lightRelease": {"standingYes": true}, "fullRelease": {"standingYes": true, "ownerDecision": "2026-11-07", "migrationGlobs": ["db/migrations/sql/*.sql"], "approvedMigrations": []}}}')"
fbase; CLASS="RELEASE CLASS: LIGHT"; expect "(F6) both yeses on, both routes ask → the full reason first, then the light one" 0 '^ASK the migration .* has no owner approval .*\(light route: the head.s tree .* differs from the reviewed train tree'
base; expect "(F6b) both on: a light release identical to its train → MERGE by the light route" 0 '^COMMENT Merged on the standing yes for light releases'

exit "$FAIL"
