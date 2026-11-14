#!/bin/bash
# Tests for skills/release/scripts/train_receipts.py — which commits on a train snapshot carry a
# review receipt and what is left to review — on scratch git repositories with a `gh` stub on PATH.
# No network, nothing outside a temp dir.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; TOOL="$ROOT/skills/release/scripts/train_receipts.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/pr"
# gh stub, as train-exclusions.sh: `gh pr view <n>` prints $WORK/pr/<n>.json; `…/statuses?…` prints
# $WORK/pr/status-<sha>.json (else []); `…/commits/<sha>/pulls?…` fails as for a commit GitHub does
# not hold (so the merge subject is read); an admin is "owner".
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
[ "$1" = pr ] && [ "$2" = view ] && [ -f "$GH_STUB_DIR/$3.json" ] && { cat "$GH_STUB_DIR/$3.json"; exit 0; }
if [ "$1" = api ]; then
  case "$2" in
    */statuses\?*) sha="${2#*/commits/}"; sha="${sha%%/*}"
      [ -f "$GH_STUB_DIR/status-$sha.json" ] && cat "$GH_STUB_DIR/status-$sha.json" || echo '[]'; exit 0 ;;
    */commits/*/pulls\?*) echo "No commit found (HTTP 422)" >&2; exit 1 ;;
    */collaborators/*/permission) login="${2#*/collaborators/}"; login="${login%%/*}"
      [ "$login" = owner ] && echo '{"permission":"admin"}' || echo '{"permission":"write"}'; exit 0 ;;
  esac
fi
exit 1
STUB
chmod +x "$WORK/bin/gh"; export GH_STUB_DIR="$WORK/pr" PATH="$WORK/bin:$PATH"
export GIT_AUTHOR_NAME=jane GIT_AUTHOR_EMAIL=jane@example.com GIT_COMMITTER_NAME=jane GIT_COMMITTER_EMAIL=jane@example.com
CFG="$WORK/config.json"
cat > "$CFG" <<'JSON'
{"release": {"releaseSource": "develop"}, "releaseTrain": {"branch": "train", "reviewEveryLanding": true},
 "review": {"localCommand": "codex exec <context>"},
 "epicIntegrationBranches": {"pattern": "<prefix>/<YY-MM-DD>/epic-<epic-title-slug>"}}
JSON
# receipt HEAD [ENGINES]: the first mergeBody line review-gate.py writes for a review settled at HEAD
receipt() { echo "Review: LOCAL-FULL at $1 over origin/train (merge base 000000000000), 2 cycle(s), engines: ${2:-claude (no findings), codex (findings)}"; }
# prove SHA [LOGIN]: an admin's (default "owner") landing proof on SHA, as `reviewed-status.py post-landing` posts it
prove() {
  python3 - "$GH_STUB_DIR/status-$1.json" "${2:-owner}" <<'PY'
import json, os, sys
f, login = sys.argv[1:]
s = json.load(open(f)) if os.path.exists(f) else []
s.insert(0, {"id": 100 + len(s), "context": "devstride/landing-reviewed", "state": "success",
             "description": "Settled LOCAL-FULL review for landing onto train", "created_at": "2026-12-01T1%d:00:00Z" % len(s),
             "creator": {"login": login, "type": "User"}})
json.dump(s, open(f, "w"))
PY
}
# work BRANCH FILE: one commit changing FILE on a new branch off the train; prints nothing
work() { git checkout -q -b "$1" train; mkdir -p "$(dirname "$2")"; echo "$1" >> "$2"; git add -A; git commit -qm "work on $1"; }
# land BRANCH SUBJECT BODY: merge BRANCH onto the train --no-ff with that message
land() { git checkout -q train; git merge -q --no-ff -m "$2" -m "$3" "$1"; }
sync() { git update-ref refs/remotes/origin/train train; git update-ref refs/remotes/origin/develop develop; }
run() { OUT="$(python3 "$TOOL" --config "$CFG" --source-before "$SB" --head "${HEAD_REF:-train}" --repo "$R" 2>&1)"; RC=$?; }
expect() {
  if [ "$RC" = "$2" ] && printf '%s' "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert $3" 2>/dev/null; then ok "$1"
  else bad "$1 — exit $RC: $OUT"; fi
}

R="$WORK/r1"; mkdir "$R"; cd "$R" || exit 2
git init -q -b develop; echo base > a.txt; git add -A; git commit -qm base; SB="$(git rev-parse HEAD)"
git checkout -q -b train
work f1 src/one.txt; h1="$(git rev-parse HEAD)"; land f1 "merge: I1 one into train" "$(receipt "$h1")"
sync; run
expect "(1a) a receipt line without an admin's landing proof on GitHub is only text: reviewed on the pull request" 1 \
  "d['receipted']==[] and [(u['item'],u['why'].split(':')[0]) for u in d['unreviewed']]==[('I1','its receipt is not proven')] and 'devstride/landing-reviewed' in d['unreviewed'][0]['why']"
prove "$h1" partner; run
expect "(1b) ... and a proof posted by someone without admin permission does not count" 1 "d['receipted']==[]"
prove "$h1"; run
expect "(1) a landing whose receipt names the commit that landed is receipted" 0 \
  "d['verdict']=='receipted' and [r['item'] for r in d['receipted']]==['I1'] and d['receipted'][0]['head']=='$h1' and d['unreviewed']==[] and 'I1, merge' in d['body'] and d['receipted'][0]['provedBy']=='owner' and 'proof posted by owner' in d['body']"

work f2 src/two.txt; land f2 "merge: I2 two into train" "Review: small fix (1 file(s), 1 changed line(s)), covered by the train's release review"
sync; run
expect "(2) a small fix landed without a receipt is reviewed on the pull request, its whole change" 1 \
  "d['verdict']=='needs-review' and [(u['item'],u['why'],u['files']) for u in d['unreviewed']]==[('I2','landed without a review receipt',['src/two.txt'])]"

# (3) the ds work land shape: the receipt names the story head; the train moved, so the landing merges a
# clean refresh (train merged into the branch) whose first parent is that head
work f3 src/three.txt; h3="$(git rev-parse HEAD)"
work f3b src/other.txt; prove "$(git rev-parse f3b)"; prove "$h3"; land f3b "merge: I4 other into train" "$(receipt "$(git rev-parse f3b)")"
git checkout -q f3; git merge -q --no-ff -m "merge: origin/train into f3" train; land f3 "merge: I3 three into train" "$(receipt "$h3")"
sync; run
expect "(3) a receipt for the head a clean refresh carried is receipted" 1 \
  "[r['item'] for r in d['receipted']]==['I1','I4','I3'] and [u['item'] for u in d['unreviewed']]==['I2']"

work f5 src/five.txt; land f5 "merge: I5 five into train" "$(receipt "$h1")"
work f6 src/six.txt; prove "$(git rev-parse f6)"; land f6 "merge: I6 six into train" "$(receipt "$(git rev-parse f6)" "claude (no findings), codex (failed: timed out)")"
git checkout -q train; echo direct > src/direct.txt; git add -A; git commit -qm "a direct commit"
sync; run
expect "(4) a receipt naming another commit, one with no CLI result, and a direct commit are each reviewed" 1 \
  "[(u['item'],u['why']) for u in d['unreviewed']]==[('I2','landed without a review receipt'),('I5','its receipt names '+'$h1'[:12]+', not the commit that landed'),('I6','its receipt shows no result from Claude and the CLI engine'),(None,'a direct commit')]"

# (5) a conflict resolved in the landing merge: the landing is receipted AND what the merge itself changed is reviewed
git checkout -q -b f7 train; echo story > src/clash.txt; git add -A; git commit -qm "story side"; h7="$(git rev-parse HEAD)"; prove "$h7"
git checkout -q train; echo train > src/clash.txt; git add -A; git commit -qm "train side"
git merge -q --no-ff -m "merge: I7 clash into train" -m "$(receipt "$h7")" f7 >/dev/null 2>&1; echo resolved > src/clash.txt; git add -A; git commit -q --no-edit
sync; run
expect "(5) a landing that resolved a conflict is receipted and its resolution is reviewed" 1 \
  "'I7' in [r['item'] for r in d['receipted']] and any(u['item']=='I7' and u['why'].startswith('what the merge itself changed') and u['files']==['src/clash.txt'] for u in d['unreviewed'])"

# (6) the snapshot: a clean merge of the moved source is covered; a snapshot fix commit is reviewed; a late
# landing absorbed into the snapshot is read commit by commit
git checkout -q develop; echo src > dev.txt; git add -A; git commit -qm "source moved"; git checkout -q -b snap train
git merge -q --no-ff -m "Merge origin/develop into snap" develop; echo fix > src/fix.txt; git add -A; git commit -qm "snapshot fix"
work f8 src/eight.txt; prove "$(git rev-parse f8)"; land f8 "merge: I8 eight into train" "$(receipt "$(git rev-parse f8)")"; sync
git checkout -q snap; git merge -q --no-ff -m "Merge branch 'train' into snap" train
HEAD_REF=snap run
expect "(6) source merge covered, fix commit reviewed, an absorbed landing receipted" 1 \
  "any(c['by']=='the release source' for c in d['covered']) and 'I8' in [r['item'] for r in d['receipted']] and any(u['why']=='a direct commit' and u['files']==['src/fix.txt'] for u in d['unreviewed'])"

# (7) a reviewed epic pull request onto the train is covered by its own review
R="$WORK/r2"; mkdir "$R"; cd "$R" || exit 2
git init -q -b develop; echo base > a.txt; git add -A; git commit -qm base; SB="$(git rev-parse HEAD)"; git checkout -q -b train
work jane/26-10-01/epic-checkout src/epic.txt; land jane/26-10-01/epic-checkout "Merge pull request #7 from acme/jane/26-10-01/epic-checkout" "the epic"
m="$(git rev-parse HEAD)"; h="$(git rev-parse HEAD^2)"
printf '{"baseRefName":"train","state":"MERGED","mergeCommit":{"oid":"%s"},"mergedAt":"2026-12-01T10:00:00Z"}\n' "$m" > "$GH_STUB_DIR/7.json"
echo "[{\"id\":1,\"context\":\"devstride/reviewed\",\"state\":\"success\",\"description\":\"Settled review of #7 into train\",\"created_at\":\"2026-12-01T10:00:00Z\",\"creator\":{\"login\":\"owner\"}}]" > "$GH_STUB_DIR/status-$h.json"
sync; run
expect "(7) a reviewed epic release pull request is covered by its own review" 0 "d['covered']==[{'commit':'$m','by':'pull request #7'}] and d['verdict']=='receipted'"
rm -f "$GH_STUB_DIR/status-$h.json"; run
expect "(7b) ... and without its review proof it is reviewed on the train's pull request" 1 "[u['why'] for u in d['unreviewed']]==['landed without a review receipt']"

SB=0000000000000000000000000000000000000000 run
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q '^train_receipts: ' && ok "(8) a wrong range exits 2 with one line" || bad "(8) a wrong range — exit $RC: $OUT"
OUT="$(python3 "$TOOL" --config "$CFG" 2>&1)"; RC=$?
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q '^train_receipts: missing' && ok "(9) a missing argument exits 2" || bad "(9) missing argument — exit $RC: $OUT"
exit $FAIL
