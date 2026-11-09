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
# train ships: the train merged into develop a minute before, develop into master at D, master synced
# back into develop, then the train fast-forwarded to develop, so the train's own first-parent walk no
# longer shows its landings and they must be read through the merges into develop.
land() {   # land <story> <time> -> prints the landing sha
  g checkout -q -b "story/$1" train/release
  at "$2" commit -q --allow-empty -m "story $1"
  g checkout -q train/release
  at "$2" merge -q --no-ff -m "merge: $1 onto the train" "story/$1"
  g rev-parse HEAD
}
release() {   # release <time>: train -> develop -> master, master synced into develop, train fast-forwarded
  g checkout -q develop; at "$(minutes "$1" -1)" merge -q --no-ff -m "train into develop" train/release
  g checkout -q master; at "$1" merge -q --no-ff -m "release" develop
  g checkout -q develop; at "$(minutes "$1" 1)" merge -q --no-ff -m "sync master into develop" master
  g branch -f train/release develop
}
DURATIONS=(60 90 120 120 150 180 180 240 300 360)
FIRST=""
for i in $(seq 0 9); do
  day=$(python3 -c 'import datetime,sys; print((datetime.date(2026,10,27)+datetime.timedelta(days=int(sys.argv[1]))).isoformat())' "$i")
  sha=$(land "s$i" "${day}T10:00:00Z")
  [ -n "$FIRST" ] || FIRST="$sha"
  release "$(minutes "${day}T10:00:00Z" "${DURATIONS[$i]}")"
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

# (1) A landing 30 minutes old, with ten released landings and no sync merge counted: the range runs
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
if [ "$CODE" = 10 ] && echo "$OUT" | grep -q "^NONE not landed on train/release yet: no clock time before landing"; then
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
g checkout -q develop; at 2026-11-09T17:50:00Z merge -q --no-ff -m "train into develop" train/release
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
