#!/bin/bash
# Tests for skills/release/scripts/estimate.py — honest estimates: no clock time before landing, a
# range from measured history after it, and each quote scored against when the work went live. A
# temporary repository with a bare origin carries production (master), the release source
# (develop) and a release train; every landing, release and sync merge gets a fixed committer time
# (GIT_COMMITTER_DATE), so the history, and so the range, is exact. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/release/scripts/estimate.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

g() { git -C "$WORK/repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
at() { local when="$1"; shift; GIT_COMMITTER_DATE="$when" GIT_AUTHOR_DATE="$when" g "$@"; }
minutes() { python3 -c 'import datetime,sys; t=datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print((t+datetime.timedelta(minutes=int(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1" "$2"; }

git init -q --bare "$WORK/origin.git"
git init -q -b develop "$WORK/repo"
at 2026-10-20T06:00:00Z commit -q --allow-empty -m base
g branch master; g branch train/release
g remote add origin "$WORK/origin.git"
mkdir -p "$WORK/repo/.claude"
cat > "$WORK/repo/.claude/ds-config.json" <<'JSON'
{"releaseTrain": {"branch": "train/release"},
 "release": {"productionBranch": "master", "releaseSource": "develop", "mergeTrainBeforeCut": true,
             "holdTimeZone": "America/Chicago", "estimates": {"deployMinutes": 15}}}
JSON

# One landing a day, Oct 27 to Nov 5 at 10:00Z, each released after D minutes, the way a release
# train ships (release-branch.md): a snapshot cut from the train, develop merged into it, on one
# release a review fix committed on it (on another a hotfix the sync brings back), its pull request merged into develop a minute before,
# develop into master at D, master synced back into develop through a sync pull request, then the
# train fast-forwarded to develop, so the train's own first-parent walk no longer shows its landings
# and they must be read through the merges into develop.
land() {   # land <story> <time> -> prints the landing sha
  g checkout -q -b "story/$1" train/release
  at "$2" commit -q --allow-empty -m "story $1"
  g checkout -q train/release
  at "$2" merge -q --no-ff -m "merge: ${3:-$1} onto the train" "story/$1"
  g rev-parse HEAD
}
deliver() {   # deliver <time> [fix]: the train's snapshot pull request merged into develop at <time>
  local slug; slug=$(echo "$1" | tr -d ':TZ-'); local snap="p/release-train-$slug"
  g checkout -q -b "$snap" train/release
  at "$(minutes "$1" -2)" merge -q --no-ff -m "merge: origin/develop into the release train snapshot" develop
  [ -z "${2:-}" ] || at "$(minutes "$1" -2)" commit -q --allow-empty -m "fix: a review finding on the snapshot"
  g checkout -q develop
  at "$1" merge -q --no-ff -m "Merge pull request #1 from acme/$snap" -m "Release train: one-offs" "$snap"
}
release() {   # release <time> [fix]: the train delivered, develop -> master, master synced back by pull request, train fast-forwarded
  deliver "$(minutes "$1" -1)" "${2:-}"
  g checkout -q master; at "$1" merge -q --no-ff -m "release" develop
  if [ -n "${3:-}" ]; then   # a hotfix merged into master, which the sync below brings back
    g checkout -q -b "hotfix-$3" master; at "$1" commit -q --allow-empty -m "hotfix"
    g checkout -q master; at "$1" merge -q --no-ff -m "Merge pull request #5 from acme/hotfix-$3" "hotfix-$3"
  fi
  local sync; sync="ci/sync-$(echo "$1" | tr -d ':TZ-')"; g checkout -q -b "$sync" develop
  at "$(minutes "$1" 1)" merge -q --no-ff -m "merge: master into develop" master
  g checkout -q develop; at "$(minutes "$1" 1)" merge -q --no-ff -m "Merge pull request #2 from acme/$sync" "$sync"
  g branch -f train/release develop
}
DURATIONS=(60 90 120 120 150 180 180 240 300 360)
FIRST=""
for i in $(seq 0 9); do
  day=$(python3 -c 'import datetime,sys; print((datetime.date(2026,10,27)+datetime.timedelta(days=int(sys.argv[1]))).isoformat())' "$i")
  sha=$(land "s$i" "${day}T10:00:00Z" "I4$i")
  [ -n "$FIRST" ] || FIRST="$sha"
  release "$(minutes "${day}T10:00:00Z" "${DURATIONS[$i]}")" "$([ "$i" = 3 ] && echo fix)" "$([ "$i" = 5 ] && echo "$i")"
done
CANDIDATE=$(land cand 2026-11-09T17:30:00Z)
g checkout -q -b story/unlanded develop
at 2026-11-09T17:40:00Z commit -q --allow-empty -m "not landed"
UNLANDED=$(g rev-parse HEAD)
g checkout -q develop
g push -q origin develop master train/release
g fetch -q origin
export AUTO_START_NO_FETCH=1

run() { (cd "$WORK/repo" && python3 "$HELPER" "$@"); }
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))' "$1"; }

# (1) A landing 30 minutes old, with ten released landings, and no sync merge, snapshot fix or sync
# pull request counted: the range runs
# from the 10th to the 90th percentile of the rest of the wait (60-30 and 300-30 minutes), plus the
# 15-minute deploy, rounded out to five minutes, shown in the hold zone.
OUT=$(run quote --sha "$CANDIDATE" --now 2026-11-09T18:00:00Z --json); CODE=$?
if [ "$CODE" = 0 ] && [ "$(echo "$OUT" | field verdict)" = QUOTE ] &&
   [ "$(echo "$OUT" | field low)" = 2026-11-09T18:45:00Z ] && [ "$(echo "$OUT" | field high)" = 2026-11-09T22:45:00Z ] &&
   [ "$(echo "$OUT" | field landings)" = 10 ] && [ "$(echo "$OUT" | field atRisk)" = 10 ]; then
  ok "(1) a quote after landing is the measured 10th-90th percentile range, sync merges left out"
else
  bad "(1) quote after landing: exit $CODE $OUT"
fi
LINE=$(run quote --sha "$CANDIDATE" --now 2026-11-09T18:00:00Z)
if echo "$LINE" | head -1 | grep -qF "QUOTE live between 12:45 PM CST and 4:45 PM CST (8 in 10 chance), from 10 landings in the last 14 days" &&
   echo "$LINE" | sed -n 2p | grep -qE '^\[estimate v1 sha=[0-9a-f]{12} quoted=2026-11-09T18:00:00Z low=2026-11-09T18:45:00Z high=2026-11-09T22:45:00Z p=80 n=10\]$'; then
  ok "(2) the line reads in the owner's time zone and the token records the quote in UTC"
else
  bad "(2) quote line or token: $LINE"
fi

# (3) No clock time before landing: a commit not on the train gets NONE.
OUT=$(run quote --sha "$UNLANDED" --now 2026-11-09T18:00:00Z); CODE=$?
if [ "$CODE" = 10 ] && echo "$OUT" | grep -q "^NONE not landed on train/release or develop yet: no clock time before landing"; then
  ok "(3) work not landed yet gets no clock time"
else
  bad "(3) not landed: exit $CODE $OUT"
fi

# (4) Too little history: having waited 250 minutes, only two landings ever waited that long.
OUT=$(run quote --sha "$CANDIDATE" --now 2026-11-09T21:40:00Z); CODE=$?
if [ "$CODE" = 10 ] && echo "$OUT" | grep -q "^NONE too little history for an honest range: 2 landing(s)"; then
  ok "(4) the range is conditional on the wait so far, and too little history gives no range"
else
  bad "(4) conditional history: exit $CODE $OUT"
fi

# (5) Already on production: LIVE, with the deploy time added.
OUT=$(run quote --sha "$FIRST" --now 2026-11-09T18:00:00Z --json); CODE=$?
if [ "$CODE" = 11 ] && [ "$(echo "$OUT" | field live)" = 2026-10-27T11:15:00Z ]; then
  ok "(5) a landing already on production is LIVE, never quoted"
else
  bad "(5) live: exit $CODE $OUT"
fi

# (6) Scoring: from git (the production merge plus the deploy), and from a confirmed deploy time.
OUT=$(run score --sha "$FIRST" --quoted 2026-10-27T10:05:00Z --low 2026-10-27T10:30:00Z --high 2026-10-27T11:00:00Z --json); CODE=$?
if [ "$CODE" = 0 ] && [ "$(echo "$OUT" | field result)" = late ] && [ "$(echo "$OUT" | field minutes)" = 15 ] &&
   echo "$OUT" | field token | grep -qE '^\[estimate-score v1 sha=[0-9a-f]{12} quoted=2026-10-27T10:05:00Z low=2026-10-27T10:30:00Z high=2026-10-27T11:00:00Z live=2026-10-27T11:15:00Z result=late minutes=15\]$'; then
  ok "(6) a score read from git: late by the minutes past the range"
else
  bad "(6) score from git: exit $CODE $OUT"
fi
OUT=$(run score --sha "$CANDIDATE" --quoted 2026-11-09T18:00:00Z --low 2026-11-09T18:45:00Z --high 2026-11-09T22:45:00Z --live 2026-11-09T20:10:00Z); CODE=$?
if [ "$CODE" = 0 ] && echo "$OUT" | head -1 | grep -qF "SCORED live at 2:10 PM CST; the quote of 12:00 PM CST was 12:45 PM CST to 4:45 PM CST: inside the range"; then
  ok "(7) a score from the confirmed deploy time: inside the range"
else
  bad "(7) score with --live: exit $CODE $OUT"
fi
OUT=$(run score --sha "$CANDIDATE" --quoted 2026-11-09T18:00:00Z --low 2026-11-09T18:45:00Z --high 2026-11-09T22:45:00Z); CODE=$?
if [ "$CODE" = 10 ] && echo "$OUT" | grep -q "^PENDING not on master yet"; then
  ok "(8) work not on production yet is PENDING, never scored"
else
  bad "(8) pending: exit $CODE $OUT"
fi

# (9) Once the train's pull request has merged into develop, the landing time is still the train merge.
g checkout -q develop   # the train merged as it is (no snapshot): its subject names the train
at 2026-11-09T17:50:00Z merge -q --no-ff -m "Merge branch 'train/release' into develop" train/release
g push -q origin develop; g fetch -q origin
OUT=$(run quote --sha "$CANDIDATE" --now 2026-11-09T18:00:00Z --json)
if [ "$(echo "$OUT" | field landedAt)" = 2026-11-09T17:30:00Z ] && [ "$(echo "$OUT" | field low)" = 2026-11-09T18:45:00Z ] &&
   [ "$(echo "$OUT" | field high)" = 2026-11-09T22:45:00Z ]; then
  ok "(9) on develop but not production: the landing time is the train merge, so the range is unchanged"
else
  bad "(9) landed on develop: $OUT"
fi

# (9b) A landing still waiting counts as at least that long: the 90th percentile moves out.
g checkout -q train/release
WAITING=$(land waiting 2026-11-09T09:40:00Z)
g push -q origin train/release; g fetch -q origin
OUT=$(run quote --sha "$CANDIDATE" --now 2026-11-09T18:00:00Z --json)
if [ "$(echo "$OUT" | field atRisk)" = 11 ] && [ "$(echo "$OUT" | field high)" = 2026-11-09T23:45:00Z ]; then
  ok "(9b) work still waiting stays in the history (counted as at least its wait so far)"
else
  bad "(9b) censored landing: $OUT"
fi

# (9c) Work merged straight into the release source while a train ships (an excluded one-off, an
# epic's release pull request) has landed too, at its merge into the source.
g checkout -q -b story/direct develop
at 2026-11-09T17:50:00Z commit -q --allow-empty -m "direct"
g checkout -q develop; at 2026-11-09T17:55:00Z merge -q --no-ff -m "Merge pull request #7 from acme/direct" story/direct
DIRECT=$(g rev-parse HEAD)
g push -q origin develop; g fetch -q origin
OUT=$(run quote --sha "$DIRECT" --now 2026-11-09T18:00:00Z --json); CODE=$?
if [ "$CODE" = 0 ] && [ "$(echo "$OUT" | field verdict)" = QUOTE ] && [ "$(echo "$OUT" | field landedAt)" = 2026-11-09T17:55:00Z ]; then
  ok "(9c) work merged straight into the release source is quoted from its merge"
else
  bad "(9c) straight into the source: exit $CODE $OUT"
fi

# (9d) shipped: the landings one release brought, with the item numbers their messages name.
RELEASE1=$(git -C "$WORK/repo" rev-list --first-parent --reverse origin/master | sed -n 2p)
OUT=$(run shipped --merge "$RELEASE1" --json); CODE=$?
if [ "$CODE" = 0 ] && echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); l=d["landings"]; sys.exit(0 if len(l)==1 and l[0]["items"]==["I40"] and l[0]["sha"]==sys.argv[1] else 1)' "$FIRST"; then
  ok "(9d) shipped lists the release's one landing and the item it names"
else
  bad "(9d) shipped: exit $CODE $OUT"
fi
OUT=$(run shipped --merge "$CANDIDATE"); CODE=$?
[ "$CODE" = 1 ] && echo "$OUT" | grep -q "is not a first-parent commit of master" && ok "(9e) shipped refuses a commit that is not a release merge" || bad "(9e) shipped non-release: exit $CODE $OUT"

# (9f) A late landing absorbed into the snapshot (release-branch.md 4a) and a review fix after it:
# the release ships every landing, the late one at its own train merge, never the absorb merge.
g checkout -q -b p/absorb train/release
at 2026-11-09T18:11:00Z merge -q --no-ff -m "merge: origin/develop into the release train snapshot" develop
g checkout -q train/release
LATE=$(land late 2026-11-09T18:20:00Z I77)
g checkout -q p/absorb; at 2026-11-09T18:25:00Z merge -q --no-ff -m "merge: absorb the late landing" train/release
at 2026-11-09T18:26:00Z commit -q --allow-empty -m "fix: after the absorb"
g checkout -q develop; at 2026-11-09T18:30:00Z merge -q --no-ff -m "Merge pull request #3 from acme/p/release-train-26-11-09-2" p/absorb
g checkout -q master; at 2026-11-09T18:40:00Z merge -q --no-ff -m "release" develop
RELEASE2=$(g rev-parse HEAD)
g push -q origin develop master train/release; g fetch -q origin
OUT=$(run shipped --merge "$RELEASE2" --json); CODE=$?
if [ "$CODE" = 0 ] && echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); got={l["sha"] for l in d["landings"]}; sys.exit(0 if got==set(sys.argv[1:]) else 1)' "$CANDIDATE" "$WAITING" "$LATE" "$DIRECT"; then
  ok "(9f) a release lists every landing it shipped, an absorbed late one included, never a fix, sync or absorb merge"
else
  bad "(9f) absorbed landing: exit $CODE $OUT"
fi
OUT=$(run quote --sha "$LATE" --now 2026-11-09T18:35:00Z --json)
[ "$(echo "$OUT" | field landing)" = "$LATE" ] && ok "(9g) an absorbed landing landed at its own train merge" || bad "(9g) absorbed landing time: $OUT"

# (9h) An epic's release pull request merged straight into develop is one landing at its merge,
# never its stories at their merges onto the epic branch, though that branch holds only merges and
# its title mentions the train.
g checkout -q -b epic/e develop
g checkout -q -b story/e1 epic/e; at 2026-11-01T09:00:00Z commit -q --allow-empty -m "e1"
g checkout -q epic/e; at 2026-11-01T09:00:00Z merge -q --no-ff -m "merge: I501 [1] one into epic integration" story/e1
STORY=$(g rev-parse HEAD)
g checkout -q develop; at 2026-11-09T18:50:00Z merge -q --no-ff -m "Merge pull request #4 from acme/p/epic-I500-e" -m "Retry handling for train/release and its release-train- snapshots" epic/e
EPIC=$(g rev-parse HEAD)
g push -q origin develop; g fetch -q origin
OUT=$(run quote --sha "$STORY" --now 2026-11-09T19:00:00Z --json)
[ "$(echo "$OUT" | field landing)" = "$EPIC" ] && ok "(9h) an epic's release pull request is one landing at its merge" || bad "(9h) epic landing: $OUT"

# (9i) backtest replays only what was quotable and live as of --now: at Nov 5 12:00 the Nov 5
# landing (live at 16:00) is not live yet, and the earlier ones are scored.
OUT=$(run backtest --days 14 --now 2026-11-05T12:00:00Z --json); CODE=$?
if [ "$CODE" = 0 ] && [ "$(echo "$OUT" | field pending)" = 1 ] &&
   [ "$(echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["inside"]+d["early"]+d["late"]+d["none"])')" = 9 ]; then
  ok "(9i) backtest never counts an outcome after --now"
else
  bad "(9i) backtest: exit $CODE $OUT"
fi

# (9j) A batch branch cut from the train mid-cycle, holding only merges, and an epic's release pull
# request onto the train are each one landing, never read through as if they were absorbs (the
# release also ships (9h)'s epic).
g branch -f train/release develop
L1=$(land b1 2026-11-09T19:00:00Z I611)
g checkout -q -b batch train/release
for n in 2 3; do
  g checkout -q -b "b$n" batch; at "2026-11-09T19:0${n}:00Z" commit -q --allow-empty -m "I61$n"
  g checkout -q batch; at "2026-11-09T19:0${n}:00Z" merge -q --no-ff -m "merge: I61$n into the batch" "b$n"
done
L4=$(land b4 2026-11-09T19:10:00Z I614)
g checkout -q train/release; at 2026-11-09T19:20:00Z merge -q --no-ff -m "merge: the batch (I612, I613) into train/release" batch
LB=$(g rev-parse HEAD)
g checkout -q -b epic2 develop
g checkout -q -b e2s epic2; at 2026-11-09T19:00:00Z commit -q --allow-empty -m "I621"
g checkout -q epic2; at 2026-11-09T19:00:00Z merge -q --no-ff -m "merge: I621 [1] into epic integration" e2s
g checkout -q train/release; at 2026-11-09T19:25:00Z merge -q --no-ff -m "Merge pull request #8 from acme/p/epic-I620-y" epic2
EB=$(g rev-parse HEAD)
deliver 2026-11-09T19:30:00Z
g checkout -q master; at 2026-11-09T19:40:00Z merge -q --no-ff -m "release" develop
RELEASE3=$(g rev-parse HEAD)
g push -q origin develop master train/release; g fetch -q origin
OUT=$(run shipped --merge "$RELEASE3" --json); CODE=$?
if [ "$CODE" = 0 ] && echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); got={l["sha"] for l in d["landings"]}; sys.exit(0 if got==set(sys.argv[1:]) else 1)' "$L1" "$L4" "$LB" "$EB" "$EPIC"; then
  ok "(9j) a batch branch and an epic onto the train are each one landing"
else
  bad "(9j) batch and epic: exit $CODE $OUT"
fi
OUT=$(run quote --sha "$L4" --now 2026-11-09T19:35:00Z --json)
[ "$(echo "$OUT" | field landedAt)" = 2026-11-09T19:10:00Z ] && ok "(9k) a landing after a batch branch was cut keeps its own landing time" || bad "(9k) landing time: $OUT"

# (9l) Only an absorb's subject marks it (release-branch.md 4a). Branches cut from the train merged
# back at its tip (one named for absorb work), or after a sync of develop, stay one landing; with the snapshot's merge of
# develop a no-op, an absorb by git's own subject and one by the prescribed subject are read
# through; a delivery whose subject is its title is recognised; a sync from master as the pull
# request's head carries nothing; backtest holds a release still deploying as pending.
g branch -f train/release develop
batch() {   # batch <name> <time>: a branch of two --no-ff merges cut from the train tip
  g checkout -q -b "$1" train/release
  for n in 1 2; do
    g checkout -q -b "$1-$n" "$1"; at "$2" commit -q --allow-empty -m "$1 part $n"
    g checkout -q "$1"; at "$2" merge -q --no-ff -m "merge: $1 part $n" "$1-$n"
  done
}
L7=$(land l7 2026-11-09T20:00:00Z I707)
batch tipbatch 2026-11-09T20:01:00Z
g checkout -q train/release; at 2026-11-09T20:02:00Z merge -q --no-ff -m "Merge pull request #14 from acme/p/fix-absorb-validation" tipbatch
LB3=$(g rev-parse HEAD)
batch syncbatch 2026-11-09T20:06:00Z
g checkout -q -b direct2 develop; at 2026-11-09T20:07:00Z commit -q --allow-empty -m "direct two"
g checkout -q develop; at 2026-11-09T20:08:00Z merge -q --no-ff -m "Merge pull request #10 from acme/direct2" direct2
DIRECT2=$(g rev-parse HEAD)
g checkout -q train/release; at 2026-11-09T20:09:00Z merge -q --no-ff -m "merge: develop into train/release" develop
at 2026-11-09T20:10:00Z merge -q --no-ff -m "merge: syncbatch into train/release" syncbatch
LB4=$(g rev-parse HEAD)
g checkout -q -b p/release-train-noop train/release
at 2026-11-09T20:20:00Z merge -q --no-ff -m "merge: origin/develop into the snapshot" develop   # a no-op
L8=$(land l8 2026-11-09T20:25:00Z I708)
g checkout -q p/release-train-noop; at 2026-11-09T20:30:00Z merge -q --no-ff --no-edit "$L8"
L9=$(land l9 2026-11-09T20:35:00Z I709)
g checkout -q p/release-train-noop; at 2026-11-09T20:40:00Z merge -q --no-ff -m "Merge branch 'train/release' ($L9) into p/release-train-noop" "$L9"
g checkout -q develop; at 2026-11-09T20:50:00Z merge -q --no-ff -m "Release train: five one-offs (#12)" p/release-train-noop
g checkout -q master; at 2026-11-09T21:40:00Z merge -q --no-ff -m "release" develop
RELEASE4=$(g rev-parse HEAD)
g checkout -q -b hotfix-late master; at 2026-11-09T21:50:00Z commit -q --allow-empty -m "hotfix"
g checkout -q master; at 2026-11-09T21:50:00Z merge -q --no-ff -m "Merge pull request #11 from acme/hotfix-late" hotfix-late
g checkout -q develop; at 2026-11-09T21:55:00Z merge -q --no-ff -m "Merge pull request #13 from acme/master" master
g checkout -q master; at 2026-11-09T22:00:00Z merge -q --no-ff -m "release" develop
RELEASE5=$(g rev-parse HEAD)
g checkout -q develop
g push -q origin develop master train/release; g fetch -q origin
OUT=$(run shipped --merge "$RELEASE4" --json); CODE=$?
if [ "$CODE" = 0 ] && echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); got={l["sha"] for l in d["landings"]}; sys.exit(0 if got==set(sys.argv[1:]) else 1)' "$LB3" "$L7" "$LB4" "$DIRECT2" "$L8" "$L9"; then
  ok "(9l) only an absorb's subject marks it; batches stay one landing; a title subject is a delivery"
else
  bad "(9l) absorb by subject: exit $CODE $OUT"
fi
OUT=$(run shipped --merge "$RELEASE5" --json)
echo "$OUT" | grep -q '"landings": \[\]' && ok "(9m) a sync from master as the pull request's head carries nothing" || bad "(9m) master-headed sync: $OUT"
OUT=$(run backtest --days 1 --now 2026-11-09T21:45:00Z --json)
[ "$(echo "$OUT" | field pending)" = 6 ] && ok "(9n) backtest holds a release still deploying at --now as pending" || bad "(9n) deploying: $OUT"

# (9o) A subject that reads like an absorb is not enough: the merge must also hold only merges,
# continue a commit of the delivery and have no landing after that commit. A one-off, a batch with a
# landing after its cut, and an epic cut from develop each stay one landing (the one-off is cut at the
# train's newest landing, so only its non-merge story keeps it whole).
g branch -f train/release develop
L11=$(land l11 2026-11-10T08:59:00Z I719)
g checkout -q -b absorb-retries train/release; at 2026-11-10T09:00:00Z commit -q --allow-empty -m "I720"
g checkout -q train/release; at 2026-11-10T09:01:00Z merge -q --no-ff -m "merge: absorb one-off into the release snapshot" absorb-retries
O1=$(g rev-parse HEAD)
batch absorbbatch 2026-11-10T09:02:00Z
L10=$(land l10 2026-11-10T09:05:00Z I721)
g checkout -q train/release; at 2026-11-10T09:06:00Z merge -q --no-ff -m "merge: absorb batch into the release train snapshot" absorbbatch
B5=$(g rev-parse HEAD)
g checkout -q -b epic3 develop
g checkout -q -b e3s epic3; at 2026-11-10T09:07:00Z commit -q --allow-empty -m "I731"
g checkout -q epic3; at 2026-11-10T09:07:00Z merge -q --no-ff -m "merge: I731 [1] into epic integration" e3s
g checkout -q train/release; at 2026-11-10T09:08:00Z merge -q --no-ff -m "merge: absorb epic three into the release snapshot" epic3
E5=$(g rev-parse HEAD)
deliver 2026-11-10T09:30:00Z
g checkout -q master; at 2026-11-10T09:40:00Z merge -q --no-ff -m "release" develop
RELEASE6=$(g rev-parse HEAD)
g checkout -q develop; g push -q origin develop master train/release; g fetch -q origin
OUT=$(run shipped --merge "$RELEASE6" --json); CODE=$?
if [ "$CODE" = 0 ] && echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); got={l["sha"] for l in d["landings"]}; sys.exit(0 if got==set(sys.argv[1:]) else 1)' "$L11" "$O1" "$L10" "$B5" "$E5"; then
  ok "(9o) an absorb-like subject alone never reads a one-off, a batch or an epic through"
else
  bad "(9o) absorb-like subjects: exit $CODE $OUT"
fi

# (9p) Absorbs in the older hand-written wording are read through to their own train merges: one
# "into the … snapshot", one into the snapshot's release-train- branch, one "late train landing", one
# into a snapshot whose name starts with the train's, one into a support-train- slug; case never matters.
g branch -f train/release develop
L0=$(land l0 2026-11-10T09:55:00Z I750)
g checkout -q -b p/release-train-26-11-10-3 train/release
LA=$(land la 2026-11-10T10:00:00Z I751)
g checkout -q p/release-train-26-11-10-3; at 2026-11-10T10:01:00Z merge -q --no-ff -m "merge: train/release (${LA:0:10}) into the release 26-11-10 Snapshot — absorbs I751" train/release
LB=$(land lb 2026-11-10T10:02:00Z I752)
g checkout -q p/release-train-26-11-10-3; at 2026-11-10T10:03:00Z merge -q --no-ff -m "merge: train/release at ${LB:0:10} (I752) into p/release-train-26-11-10-3" train/release
LC=$(land lc 2026-11-10T10:04:00Z I753)
g checkout -q p/release-train-26-11-10-3; at 2026-11-10T10:05:00Z merge -q --no-ff -m "Merge: Late Train Landing I753" train/release
LD=$(land ld 2026-11-10T10:06:00Z I754)
g checkout -q p/release-train-26-11-10-3; at 2026-11-10T10:07:00Z merge -q --no-ff -m "merge: train/release (${LD:0:10}) into train/release-train-26-11-10-3" train/release
LE=$(land le 2026-11-10T10:08:00Z I755)
g checkout -q p/release-train-26-11-10-3; at 2026-11-10T10:09:00Z merge -q --no-ff -m "merge: train/support at ${LE:0:10} (I755) into support-train-26-11-10-3" train/release
g checkout -q develop; at 2026-11-10T10:10:00Z merge -q --no-ff -m "Merge pull request #15 from acme/p/release-train-26-11-10-3" p/release-train-26-11-10-3
g checkout -q master; at 2026-11-10T10:20:00Z merge -q --no-ff -m "release" develop
RELEASE7=$(g rev-parse HEAD)
g checkout -q develop; g push -q origin develop master train/release; g fetch -q origin
OUT=$(run shipped --merge "$RELEASE7" --json); CODE=$?
if [ "$CODE" = 0 ] && echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); got={l["sha"] for l in d["landings"]}; sys.exit(0 if got==set(sys.argv[1:]) else 1)' "$L0" "$LA" "$LB" "$LC" "$LD" "$LE"; then
  ok "(9p) absorbs in the older wording are read through to their own landings"
else
  bad "(9p) older absorb wording: exit $CODE $OUT"
fi

# (9q) Only whole absorb words, or a train's own merge whose phrase after "into" names a snapshot,
# mark an absorb; a subject that says it goes into the train itself never does. Batches of merges, each cut at the train's
# newest landing and merged back under one of these subjects, stay one landing each.
g branch -f train/release develop
L12=$(land l12 2026-11-10T11:00:00Z I760)
EXPECT9Q="$L12"; k=0
while IFS= read -r subject <&3; do
  k=$((k+1)); batch "nq$k" "2026-11-10T11:$(printf %02d $((k*2)))":00Z
  g checkout -q train/release; at "2026-11-10T11:$(printf %02d $((k*2+1)))":00Z merge -q --no-ff -m "$subject" "nq$k"
  EXPECT9Q="$EXPECT9Q $(g rev-parse HEAD)"
done 3<<'SUBJECTS'
merge: absorb-two
merge: snapbatch into train/release (snapshot prep)
merge: absorb batch into train/release
merge: batch into the train (snapshot prep)
merge: batch into origin/train/release before the snapshot
merge: batch into train/release (folds I761 into snapshot prep)
merge: golden snapshot fix into the integration batch
MERGE: Absorb batch Into Train/Release
merge: absorb batch into train/release.
merge: batch I762, I763 onto train/release (fold fixtures into snapshot tests)
merge: train/fixes into p/integration, snapshot prep
merge: train/fixes into p/integration; snapshot prep
merge: train/fixes into p/integration — snapshot prep
merge: train/fixes into p/integration (snapshot prep)
SUBJECTS
batch nqsha 2026-11-10T11:40:00Z   # git's own subject for a merge by sha: "Merge commit '<sha>' into train/release"
g checkout -q train/release; at 2026-11-10T11:41:00Z merge -q --no-ff --no-edit "$(g rev-parse nqsha)"
g log -1 --format=%s | grep -q "^Merge commit '.*' into train/release$" || bad "(9q) fixture: git's merge-by-sha subject changed"
EXPECT9Q="$EXPECT9Q $(g rev-parse HEAD)"
deliver 2026-11-10T11:50:00Z
g checkout -q master; at 2026-11-10T11:55:00Z merge -q --no-ff -m "release" develop
RELEASE8=$(g rev-parse HEAD)
g checkout -q develop; g push -q origin develop master train/release; g fetch -q origin
OUT=$(run shipped --merge "$RELEASE8" --json); CODE=$?
# shellcheck disable=SC2086
if [ "$CODE" = 0 ] && echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); got={l["sha"] for l in d["landings"]}; sys.exit(0 if got==set(sys.argv[1:]) else 1)' $EXPECT9Q; then
  ok "(9q) a branch named absorb-…, or a subject saying it goes into the train, is never an absorb"
else
  bad "(9q) absorb words and destination: exit $CODE $OUT"
fi

# (10) No release train that ships: work lands on the release source; a source that is production
# means a merge is the release.
python3 - "$WORK/repo/.claude/ds-config.json" <<'PY'
import json, sys
path = sys.argv[1]; config = json.load(open(path))
config["release"]["mergeTrainBeforeCut"] = False
json.dump(config, open(path, "w"))
PY
OUT=$(run quote --sha "$WAITING" --now 2026-11-09T18:00:00Z); CODE=$?
if [ "$CODE" = 10 ] && echo "$OUT" | grep -q "^NONE not landed on develop yet"; then
  ok "(10) without a train that ships, work lands on the release source"
else
  bad "(10) no train: exit $CODE $OUT"
fi
# (10b) There, a sync pull request (production merged back through a branch) carries nothing: the
# history beside the quoted merge is the eleven train deliveries, not the ten syncs as well (21).
OUT=$(run quote --sha "$DIRECT" --now 2026-11-09T18:00:00Z --json)
[ "$(echo "$OUT" | field landings)" = 11 ] && ok "(10b) sync pull requests are not landings" || bad "(10b) sync pull requests: $OUT"
# (10d) A release source that is the production branch: each merge into it is a landing, never a
# sync of itself.
python3 - "$WORK/repo/.claude/ds-config.json" <<'PY'
import json, sys
path = sys.argv[1]; config = json.load(open(path))
config["release"]["releaseSource"] = "master"
json.dump(config, open(path, "w"))
PY
OUT=$(run shipped --merge "$RELEASE1" --json)
echo "$OUT" | python3 -c 'import json,sys; l=json.load(sys.stdin)["landings"]; sys.exit(0 if [x["sha"] for x in l]==[sys.argv[1]] else 1)' "$RELEASE1" &&
  ok "(10d) a source that is production: each merge into it is a landing" || bad "(10d) source is production: $OUT"
python3 - "$WORK/repo/.claude/ds-config.json" <<'PY'
import json, sys
path = sys.argv[1]; config = json.load(open(path))
config["release"]["releaseSource"] = "develop"
json.dump(config, open(path, "w"))
PY
# (10c) A train configured to ship but not created yet: work lands on the source, never an ERROR.
python3 - "$WORK/repo/.claude/ds-config.json" <<'PY'
import json, sys
path = sys.argv[1]; config = json.load(open(path))
config["release"]["mergeTrainBeforeCut"] = True; config["releaseTrain"]["branch"] = "train/not-yet"
json.dump(config, open(path, "w"))
PY
OUT=$(run quote --sha "$DIRECT" --now 2026-11-09T18:00:00Z --json); CODE=$?
[ "$CODE" != 1 ] && [ "$(echo "$OUT" | field landingBranch)" = develop ] && ok "(10c) a train not created yet: work lands on the source" || bad "(10c) missing train: exit $CODE $OUT"
OUT=$(run quote --sha nonsense --now 2026-11-09T18:00:00Z); CODE=$?
if [ "$CODE" = 1 ] && echo "$OUT" | grep -q "^ERROR no commit"; then
  ok "(11) an unknown commit is an ERROR"
else
  bad "(11) unknown commit: exit $CODE $OUT"
fi
python3 - "$WORK/repo/.claude/ds-config.json" <<'PY'
import json, sys
path = sys.argv[1]; config = json.load(open(path))
config["release"]["estimates"]["deployMinutes"] = "soon"
json.dump(config, open(path, "w"))
PY
OUT=$(run quote --sha "$CANDIDATE" --now 2026-11-09T18:00:00Z); CODE=$?
if [ "$CODE" = 1 ] && echo "$OUT" | grep -q "^ERROR release.estimates.deployMinutes"; then
  ok "(12) a malformed deployMinutes is an ERROR, never a guess"
else
  bad "(12) bad config: exit $CODE $OUT"
fi
OUT=$(run nonsense); CODE=$?
[ "$CODE" = 2 ] && ok "(13) an unknown command prints usage" || bad "(13) usage: exit $CODE"

[ "$FAIL" -eq 0 ] && echo "estimate: all passed" || echo "estimate: FAILURES"
exit "$FAIL"
