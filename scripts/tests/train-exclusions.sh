#!/bin/bash
# Tests for skills/release/scripts/train_exclusions.py — the release train's fix-exclusion check —
# on scratch git repositories with a `gh` stub on PATH. No network, nothing outside a temp dir.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; TOOL="$ROOT/skills/release/scripts/train_exclusions.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/pr"
# gh stub: `gh pr view <n> --json …` prints $WORK/pr/<n>.json, and fails when there is none. The
# review proof: `gh api …/commits/<sha>/statuses?…` prints $WORK/pr/status-<sha>.json (else []), and
# `gh api …/collaborators/<login>/permission` answers admin for "owner", write for anyone else.
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
[ "$1" = pr ] && [ "$2" = view ] && [ -f "$GH_STUB_DIR/$3.json" ] && { cat "$GH_STUB_DIR/$3.json"; exit 0; }
if [ "$1" = api ]; then
  case "$2" in
    */statuses\?*) [ -n "${GH_STATUS_FAIL:-}" ] && { echo "HTTP 502" >&2; exit 1; }; sha="${2#*/commits/}"; sha="${sha%%/*}"
      [ -f "$GH_STUB_DIR/status-$sha.json" ] && cat "$GH_STUB_DIR/status-$sha.json" || echo '[]'; exit 0 ;;
    */collaborators/*/permission) login="${2#*/collaborators/}"; login="${login%%/*}"
      [ "$login" = owner ] && echo '{"permission":"admin"}' || echo '{"permission":"write"}'; exit 0 ;;
  esac
fi
exit 1
STUB
chmod +x "$WORK/bin/gh"; export GH_STUB_DIR="$WORK/pr" PATH="$WORK/bin:$PATH"
export GIT_AUTHOR_NAME=jane GIT_AUTHOR_EMAIL=jane@example.com GIT_COMMITTER_NAME=jane GIT_COMMITTER_EMAIL=jane@example.com

# config [renumber]: the fixture configuration, with or without release.migrationRenumber
config() {
  python3 - "$1" "${2:-}" <<'PY'
import json, sys
c = {"release": {"releaseSource": "develop", "releaseBranchFixExclusions": ["db/migrations/**", "infra/**"]},
     "releaseTrain": {"branch": "train"},
     "epicIntegrationBranches": {"pattern": "<prefix>/<YY-MM-DD>/epic-<epic-title-slug>"},
     "planIntegrationBranches": {"pattern": "<prefix>/<YY-MM-DD>/plan-<plan-number>-<plan-title-slug>"}}
if sys.argv[2]:
    c["release"]["migrationRenumber"] = {"sqlGlobs": ["db/migrations/*.sql"], "metaGlobs": ["db/migrations/meta/**"]}
json.dump(c, open(sys.argv[1], "w"))
PY
}
# repo NAME: a repository with develop (also origin/develop), a train branch cut from it, SB = the source at the cut
repo() {
  R="$WORK/$1"; mkdir "$R"; cd "$R" || exit 2; rm -f "$GH_STUB_DIR"/status-*.json   # fixture SHAs repeat across repos
  git init -q -b develop; mkdir -p db/migrations/meta infra src
  echo "select 1;" > db/migrations/0001_init.sql; echo "{}" > db/migrations/meta/_journal.json
  echo a > infra/main.tf; echo a > src/a.txt; git add -A; git commit -qm base
  git update-ref refs/remotes/origin/develop develop; SB="$(git rev-parse HEAD)"; git checkout -q -b train
}
# unit BRANCH SUBJECT FILE…: commit the files on a branch off the train, merge it --no-ff with SUBJECT
unit() {
  b="$1"; subj="$2"; shift 2; git checkout -q -b "$b" train
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "$b $f" > "$f"; done
  git add -A; git commit -qm "work on $b"; git checkout -q train; git merge -q --no-ff -m "$subj" "$b"
}
# stub N BASE STATE MERGE-OID: gh's answer for pull request N, merged after the grandfather cutoff (MERGED_AT
# overrides); unless NOPROOF=1, the merged head (MERGE-OID^2) carries an admin's settled-review status
stub() {
  printf '{"baseRefName":"%s","state":"%s","mergeCommit":{"oid":"%s"},"mergedAt":"%s"}\n' "$2" "$3" "$4" "${MERGED_AT:-2026-12-01T10:00:00Z}" > "$GH_STUB_DIR/$1.json"
  h="$(git rev-parse --verify --quiet "$4^2" 2>/dev/null)"
  [ -n "$h" ] && [ "${NOPROOF:-}" != 1 ] && DESC="Settled review of #$1 into $2" proof "$h" owner success
}
# proof SHA LOGIN STATE…: the devstride/reviewed statuses on SHA, newest first, each described as
# DESC (default: a settled review of #30 into train)
proof() {
  sha="$1"; shift; out="["; i=0
  while [ $# -ge 2 ]; do
    [ $i -gt 0 ] && out="$out,"
    out="$out{\"id\":$((100 - i)),\"context\":\"devstride/reviewed\",\"state\":\"$2\",\"description\":\"${DESC:-Settled review of #30 into train}\",\"created_at\":\"2026-12-01T1$((9 - i)):00:00Z\",\"creator\":{\"login\":\"$1\"}}"
    i=$((i + 1)); shift 2
  done
  echo "$out]" > "$GH_STUB_DIR/status-$sha.json"
}
# run NAME [renumber]: the tool over SB..train; sets RC and OUT
run() { config "$WORK/c-$1.json" "${2:-}"; OUT="$(python3 "$TOOL" --config "$WORK/c-$1.json" --source-before "${SB_OVERRIDE:-$SB}" --head "${HEAD_REF:-train}" --repo "$WORK/$1" 2>&1)"; RC=$?; }
# expect LABEL RC PYTHON-CONDITION-ON-d
expect() {
  if [ "$RC" = "$2" ] && printf '%s' "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert $3" 2>/dev/null; then ok "$1"
  else bad "$1 — exit $RC: $OUT"; fi
}

repo t1; unit oneoff "merge: item-1 add a column into train" db/migrations/0002_col.sql; run t1
expect "(1) a fast-merged one-off touching db/migrations is refused" 1 "d['refused']==['db/migrations/0002_col.sql'] and d['reviewedUnits']==[]"

repo t2; unit epic "Merge pull request #7 from acme/jane/26-10-01/epic-checkout" db/migrations/0002_col.sql infra/queue.tf
stub 7 train MERGED "$(git rev-parse HEAD)"; run t2
expect "(2) a reviewed epic pull-request merge carrying a migration and infra is allowed and listed" 0 "d['refused']==[] and d['reviewedUnits']==[7]"

repo t3a; unit epic "Merge pull request #9 from acme/jane/26-10-01/epic-checkout" infra/queue.tf
stub 9 develop MERGED "$(git rev-parse HEAD)"; run t3a
expect "(3a) a pull-request-shaped subject whose pull request was based on another branch is refused" 1 "d['refused']==['infra/queue.tf']"
repo t3b; unit epic "Merge pull request #9 from acme/jane/26-10-01/epic-checkout" infra/queue.tf
stub 9 train OPEN "$(git rev-parse HEAD)"; run t3b
expect "(3b) ... or one that is not merged is refused" 1 "d['refused']==['infra/queue.tf']"
repo t3c; unit epic "Merge pull request #9 from acme/jane/26-10-01/epic-checkout" infra/queue.tf
stub 9 train MERGED "0000000000000000000000000000000000000000"; run t3c
expect "(3c) ... or one whose merge commit is another commit is refused" 1 "d['refused']==['infra/queue.tf']"
repo t3d; unit epic "Merge pull request #8 from acme/jane/26-10-01/epic-checkout" infra/queue.tf; run t3d
expect "(3d) ... or one gh cannot find is refused" 1 "d['refused']==['infra/queue.tf']"
repo t3e; unit hand "Merge pull request #7 from acme/jane/26-10-01/not-an-epic" infra/queue.tf
stub 7 train MERGED "$(git rev-parse HEAD)"; run t3e
expect "(3e) ... and so is a merged pull request whose head is not an integration branch" 1 "d['refused']==['infra/queue.tf']"

# a reviewed epic adds 0002_add.sql; the source then takes 0002 for itself and is merged into the snapshot
renumber_repo() {
  repo "$1"; unit epic "Merge pull request #7 from acme/jane/26-10-01/epic-checkout" db/migrations/0002_add.sql db/migrations/meta/_journal.json
  stub 7 train MERGED "$(git rev-parse HEAD)"
  git checkout -q develop; echo "select 2;" > db/migrations/0002_other.sql; git add -A; git commit -qm "source takes 0002"
  git update-ref refs/remotes/origin/develop develop; git checkout -q train; git merge -q --no-ff -m "merge the source" develop
  git mv db/migrations/0002_add.sql db/migrations/0003_add.sql; echo '{"renumbered":true}' > db/migrations/meta/_journal.json
  [ "${2:-}" = changed ] && echo "select changed;" >> db/migrations/0003_add.sql
  git add -A; git commit -qm "renumber"
}
renumber_repo t4; run t4 yes
expect "(4) a byte-identical renumber with only metadata besides is allowed and reported" 0 "d['refused']==[] and d['allowedRenumbers']==[{'from':'db/migrations/0002_add.sql','to':'db/migrations/0003_add.sql'}]"
renumber_repo t5 changed; run t5 yes
expect "(5) a renumber whose SQL changed is refused" 1 "'db/migrations/0003_add.sql' in d['refused'] and d['allowedRenumbers']==[]"
renumber_repo t6; run t6
expect "(6) with no release.migrationRenumber a renumber is refused" 1 "'db/migrations/0003_add.sql' in d['refused'] and d['allowedRenumbers']==[]"

repo t7; git checkout -q -b snapshot train; echo b > infra/main.tf; git add -A; git commit -qm "fix"; git checkout -q train; git merge -q --ff-only snapshot; run t7
expect "(7) a snapshot fix commit touching infra is refused" 1 "d['refused']==['infra/main.tf']"

repo t8; git checkout -q develop; echo "select 9;" > db/migrations/0009_src.sql; echo b > infra/src.tf; git add -A; git commit -qm "source work"
git update-ref refs/remotes/origin/develop develop; git checkout -q train; git merge -q --no-ff -m "merge the source" develop; run t8
expect "(8) merges of the source are ignored" 0 "d['refused']==[] and d['reviewedUnits']==[]"

repo t9; unit oneoff "merge: item-1 docs into train" src/b.txt; run t9
expect "(9) a one-off touching no excluded path passes" 0 "d['refused']==[]"

# (10) A: a source merge whose conflict resolution adds a migration is refused; the clean one (t8) passes
repo t10; git checkout -q develop; echo dev > src/a.txt; git add -A; git commit -qm "source edits a"
git update-ref refs/remotes/origin/develop develop; git checkout -q train; echo train > src/a.txt; git add -A; git commit -qm "train edits a"
git merge -q --no-ff -m "merge the source" develop >/dev/null 2>&1; echo resolved > src/a.txt; echo "select 5;" > db/migrations/x.sql; git add -A; git commit -qm "merge the source"; run t10
expect "(10) a source merge whose resolution adds a migration is refused" 1 "d['refused']==['db/migrations/x.sql']"
repo t10b; git checkout -q -b epic train; echo e > src/e.txt; git add -A; git commit -qm e; git checkout -q train
git merge -q --no-ff -m "Merge pull request #7 from acme/jane/26-10-01/epic-checkout" epic; echo x > db/migrations/y.sql; git add -A
git commit -q --amend -m "Merge pull request #7 from acme/jane/26-10-01/epic-checkout"
stub 7 train MERGED "$(git rev-parse HEAD)"; run t10b
expect "(10b) a reviewed-unit merge whose own result adds a migration is refused" 1 "d['refused']==['db/migrations/y.sql']"

# (11) B: the range must be an ancestor of the source and of the head
repo t11; git checkout -q -b side; echo s > src/s.txt; git add -A; git commit -qm side; SIDE="$(git rev-parse HEAD)"; git checkout -q train
SB_OVERRIDE="$SIDE" run t11
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q "^train_exclusions: .*not an ancestor" && ok "(11) a source-before that is not an ancestor of the source is exit 2" || bad "(11) exit $RC: $OUT"
repo t11c; git checkout -q develop; echo n > src/n.txt; git add -A; git commit -qm n; git update-ref refs/remotes/origin/develop develop
git checkout -q train; SB_OVERRIDE="$(git rev-parse develop)" run t11c
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q "not an ancestor of --head" && ok "(11c) a source-before that is not an ancestor of the head is exit 2" || bad "(11c) exit $RC: $OUT"

# (12) C: a non-ASCII migration path is matched
repo t12; unit oneoff "merge: item-1 accent into train" "db/migrations/é.sql"; run t12
expect "(12) a fast-merged one-off adding a non-ASCII migration is refused" 1 "d['refused']==['db/migrations/\\u00e9.sql']"

# (13) D: no release.releaseSource means develop
repo t13; unit oneoff "merge: item-1 col into train" db/migrations/0002_col.sql
config "$WORK/c-t13.json"
python3 - "$WORK/c-t13.json" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1])); del c["release"]["releaseSource"]; json.dump(c, open(sys.argv[1], "w"))
PYEOF
OUT="$(python3 "$TOOL" --config "$WORK/c-t13.json" --source-before "$SB" --head train --repo "$WORK/t13" 2>&1)"; RC=$?
expect "(13) a config without releaseSource defaults to develop" 1 "d['refused']==['db/migrations/0002_col.sql']"

# (14) E: late absorption into the snapshot
late() {  # late NAME SUBJECT: snapshot cut, then the train gains a unit, absorbed by a --no-ff merge
  repo "$1"; git checkout -q -b snapshot train; git checkout -q train
  unit late "$2" db/migrations/0002_col.sql infra/q.tf; TRAIN_TIP="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/train train; git checkout -q snapshot; git merge -q --no-ff -m "absorb late landings" "$TRAIN_TIP"; HEAD_REF=snapshot
}
late t14 "Merge pull request #7 from acme/jane/26-10-01/epic-checkout"; stub 7 train MERGED "$TRAIN_TIP"; run t14; unset HEAD_REF
expect "(14) a reviewed epic absorbed late into the snapshot passes the whole-range check" 0 "d['refused']==[] and d['reviewedUnits']==[7]"
late t14b "merge: item-2 col into train"; run t14b; unset HEAD_REF
expect "(14b) a one-off carrying a migration absorbed late is still refused" 1 "'db/migrations/0002_col.sql' in d['refused']"

# (15) octopus merges are never exempt: an unreviewed branch inside one is checked
repo t15; git checkout -q develop; echo d > src/d.txt; git add -A; git commit -qm "source tip"; git update-ref refs/remotes/origin/develop develop
git checkout -q -b side "$SB"; echo s > src/s.txt; git add -A; git commit -qm side
git checkout -q -b unrel "$SB"; echo y > db/migrations/y.sql; git add -A; git commit -qm unrel; git checkout -q train
git merge -q -m "octopus" develop side unrel >/dev/null 2>&1; run t15
expect "(15) an octopus merge carrying an unreviewed migration is refused" 1 "d['refused']==['db/migrations/y.sql']"

# (16) step 4a's exact call: the start is the snapshot, which is on the train and not on the source
repo t16; unit first "merge: item-0 docs into train" src/first.txt; SNAP="$(git rev-parse HEAD)"; git branch snapshot
unit late "Merge pull request #7 from acme/jane/26-10-01/epic-checkout" db/migrations/0002_col.sql; stub 7 train MERGED "$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/train train; config "$WORK/c-t16.json"
OUT="$(python3 "$TOOL" --config "$WORK/c-t16.json" --start-on train --source-before "$SNAP" --head train --repo "$WORK/t16" 2>&1)"; RC=$?
expect "(16) 4a: a late reviewed unit passes with --start-on train" 0 "d['refused']==[] and d['reviewedUnits']==[7]"
OUT="$(python3 "$TOOL" --config "$WORK/c-t16.json" --source-before "$SNAP" --head train --repo "$WORK/t16" 2>&1)"; RC=$?
[ "$RC" = 2 ] && ok "(16b) the same train-only start without --start-on train is exit 2" || bad "(16b) exit $RC: $OUT"
unit late2 "merge: item-3 col into train" db/migrations/0003_col.sql; git update-ref refs/remotes/origin/train train
OUT="$(python3 "$TOOL" --config "$WORK/c-t16.json" --start-on train --source-before "$SNAP" --head train --repo "$WORK/t16" 2>&1)"; RC=$?
expect "(16c) 4a: a late one-off carrying a migration is refused" 1 "d['refused']==['db/migrations/0003_col.sql']"

# (17) only a MISSING releaseSource defaults; present but empty, false or null is exit 2
repo t17; unit oneoff "merge: item-1 docs into train" src/b.txt
for bad_value in '""' false null; do
  config "$WORK/c-t17.json"; python3 - "$WORK/c-t17.json" "$bad_value" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1])); c["release"]["releaseSource"] = json.loads(sys.argv[2]); json.dump(c, open(sys.argv[1], "w"))
PYEOF
  OUT="$(python3 "$TOOL" --config "$WORK/c-t17.json" --source-before "$SB" --head train --repo "$WORK/t17" 2>&1)"; RC=$?
  [ "$RC" = 2 ] && ok "(17) releaseSource $bad_value is exit 2" || bad "(17) releaseSource $bad_value: exit $RC: $OUT"
done

# (18) a journal conflict resolved inside the source merge: allowed only beside an allowed renumber
journal_repo() {  # journal_repo NAME [renumber]
  repo "$1"; unit epic "Merge pull request #7 from acme/jane/26-10-01/epic-checkout" db/migrations/0002_add.sql
  echo '{"e":1}' > db/migrations/meta/_journal.json; git add -A; git commit -q --amend -m "Merge pull request #7 from acme/jane/26-10-01/epic-checkout"
  stub 7 train MERGED "$(git rev-parse HEAD)"
  git checkout -q develop; echo "select 2;" > db/migrations/0002_other.sql; echo '{"d":1}' > db/migrations/meta/_journal.json; git add -A; git commit -qm "source takes 0002"
  git update-ref refs/remotes/origin/develop develop; git checkout -q train
  git merge -q --no-ff -m "merge the source" develop >/dev/null 2>&1; echo '{"e":1,"d":1}' > db/migrations/meta/_journal.json; git add -A; git commit -qm "merge the source"
  if [ "${2:-}" = renumber ]; then git mv db/migrations/0002_add.sql db/migrations/0003_add.sql; git commit -qm renumber; fi
}
journal_repo t18 renumber; run t18 yes
expect "(18) a journal resolution inside the source merge plus a byte-identical renumber is allowed and reported" 0 "d['refused']==[] and d['allowedRenumbers']==[{'from':'db/migrations/0002_add.sql','to':'db/migrations/0003_add.sql'}]"
journal_repo t18b; run t18b yes
expect "(18b) the same journal resolution with no renumber in the range is refused" 1 "d['refused']==['db/migrations/meta/_journal.json']"
journal_repo t18c renumber; run t18c
expect "(18c) ... and with no release.migrationRenumber it is refused" 1 "'db/migrations/meta/_journal.json' in d['refused']"
# (19) a source merge may bring only the source's changes: one whose resolution deletes a reviewed migration is refused
repo t19; unit epic "Merge pull request #7 from acme/jane/26-10-01/epic-checkout" db/migrations/0002_col.sql
stub 7 train MERGED "$(git rev-parse HEAD)"
git checkout -q develop; echo dev > src/dev.txt; git add -A; git commit -qm "source work"; git update-ref refs/remotes/origin/develop develop
git checkout -q train; git merge -q --no-ff --no-commit develop >/dev/null 2>&1; git rm -q db/migrations/0002_col.sql; git commit -qm "merge the source"; run t19
expect "(19) a source merge whose resolution deletes a reviewed migration is refused" 1 "d['refused']==['db/migrations/0002_col.sql'] and d['reviewedUnits']==[7]"
# (19b) --start-on train needs a head on the train
repo t19b; unit first "merge: item-0 docs into train" src/first.txt; SNAP="$(git rev-parse HEAD)"; git update-ref refs/remotes/origin/train train
git checkout -q -b offtrain train; echo o > src/o.txt; git add -A; git commit -qm off; config "$WORK/c-t19b.json"
OUT="$(python3 "$TOOL" --config "$WORK/c-t19b.json" --start-on train --source-before "$SNAP" --head offtrain --repo "$WORK/t19b" 2>&1)"; RC=$?
[ "$RC" = 2 ] && ok "(19b) --start-on train with a head off the train is exit 2" || bad "(19b) exit $RC: $OUT"
# (20) a clean automatic merge of edits both sides made to one excluded file is not a resolution
repo t20; seq 1 60 > infra/big.tf; git add -A; git commit -qm "big file"; git checkout -q develop; git merge -q --ff-only train
git update-ref refs/remotes/origin/develop develop; SB="$(git rev-parse HEAD)"; git checkout -q train
git checkout -q develop; sed -i.bak 's/^40$/forty/' infra/big.tf; rm -f infra/big.tf.bak; git commit -qam "source edits line 40"
git update-ref refs/remotes/origin/develop develop
git checkout -q train; unit epic "Merge pull request #7 from acme/jane/26-10-01/epic-checkout" src/e.txt
git checkout -q -b epic2 train; sed -i.bak 's/^2$/two/' infra/big.tf; rm -f infra/big.tf.bak; git commit -qam "epic edits line 2"
git checkout -q train; git merge -q --no-ff -m "Merge pull request #8 from acme/jane/26-10-01/epic-billing" epic2; stub 8 train MERGED "$(git rev-parse HEAD)"
stub 7 train MERGED "$(git rev-parse HEAD^1)"
PRE20="$(git rev-parse HEAD)"; git merge -q --no-ff -m "merge the source" develop || bad "(20) setup: the source merge failed"
[ "$(git rev-parse HEAD)" != "$PRE20" ] && [ "$(git rev-parse HEAD^2)" = "$(git rev-parse develop)" ] || bad "(20) setup: HEAD is not a new merge of the source"; run t20
expect "(20) a clean source merge of a file both sides edited is allowed" 0 "d['refused']==[] and 8 in d['reviewedUnits']"
# (21) a modify/delete conflict on an excluded file leaves no markers; its resolution is still checked
repo t21; echo keep > infra/gone.tf; git add -A; git commit -qm "gone.tf"; git checkout -q develop; git merge -q --ff-only train
git update-ref refs/remotes/origin/develop develop; SB="$(git rev-parse HEAD)"; git checkout -q train
git checkout -q develop; git rm -q infra/gone.tf; git commit -qm "source deletes gone.tf"; git update-ref refs/remotes/origin/develop develop
git checkout -q train; unit epic "Merge pull request #9 from acme/jane/26-10-01/epic-gone" infra/gone.tf; stub 9 train MERGED "$(git rev-parse HEAD)"
git merge -q --no-ff --no-commit develop >/dev/null 2>&1; M21=$?; [ "$M21" = 1 ] || bad "(21) setup: the merge did not stop on its conflict ($M21)"
git add infra/gone.tf; git commit -qm "merge the source"   # keep the train's edit: the result matches git's own merge
[ -z "$(git diff --name-only "$(git merge-tree --write-tree HEAD^1 HEAD^2 | head -1)" HEAD)" ] || bad "(21) setup: the resolution differs from git's merge"; run t21
expect "(21) a modify/delete conflict on an excluded file, resolved to match git's own merge, is still refused" 1 "d['refused']==['infra/gone.tf'] and d['reviewedUnits']==[9]"
# (22) a directory-rename split names only a directory, beside an ordinary conflict: the check stops
repo t22; mkdir -p infra/z; echo b > infra/z/b; echo c > infra/z/c; git add -A; git commit -qm "z"; git checkout -q develop; git merge -q --ff-only train
git update-ref refs/remotes/origin/develop develop; SB="$(git rev-parse HEAD)"; git checkout -q -b split train
mkdir -p infra/y infra/w; git mv infra/z/b infra/y/b; git mv infra/z/c infra/w/c; echo split > src/a.txt; git commit -qam "split z"
git checkout -q train; git merge -q --no-ff -m "Merge pull request #10 from acme/jane/26-10-01/epic-split" split; stub 10 train MERGED "$(git rev-parse HEAD)"
git checkout -q develop; echo d > infra/z/d; echo dev > src/a.txt; git add -A; git commit -qm "source adds z/d"; git update-ref refs/remotes/origin/develop develop
git checkout -q train; git merge -q --no-ff --no-commit develop >/dev/null 2>&1; M22=$?; [ "$M22" = 1 ] || bad "(22) setup: the merge did not stop ($M22)"
git checkout -q --ours src/a.txt; git add -A; git commit -qm "merge the source"; run t22
[ "$RC" = 2 ] && ok "(22) a directory-rename split beside an ordinary conflict stops the check (exit 2)" || bad "(22) exit $RC: $OUT"
# (23) plan scope: an epic reviewed onto the plan branch, then the plan released onto the train
PLAN=jane/26-10-01/plan-I303-checkout
plan_repo() {
  repo "$1"; git checkout -q -b plan train
  git checkout -q -b epic plan; mkdir -p db/migrations; echo "epic" > db/migrations/0002_col.sql; git add -A; git commit -qm "story"
  git checkout -q plan; git merge -q --no-ff -m "Merge pull request #11 from acme/jane/26-10-01/epic-checkout" epic
  stub 11 "${2:-$PLAN}" MERGED "$(git rev-parse HEAD)"
  git checkout -q train; echo t > src/t.txt; git add -A; git commit -qm "train moves"
  git checkout -q plan; git merge -q --no-ff -m "refresh from the train" train
  if [ -n "${3:-}" ]; then echo direct > "$3"; git add -A; git commit -qm "direct commit"; fi
  git checkout -q train; git merge -q --no-ff -m "Merge pull request #13 from acme/$PLAN" plan
  stub 13 train MERGED "$(git rev-parse HEAD)"
}
plan_repo t23; run t23
expect "(23) a reviewed plan release carrying an epic's reviewed migration is allowed, both units listed" 0 "d['refused']==[] and 13 in d['reviewedUnits'] and 11 in d['reviewedUnits']"
plan_repo t23b "" infra/direct.tf; run t23b
expect "(23b) a commit on the plan branch that no pull request reviewed is still checked" 1 "d['refused']==['infra/direct.tf']"
plan_repo t23c train; run t23c
expect "(23c) an epic pull request on the plan branch that was based elsewhere is not a reviewed unit" 1 "d['refused']==['db/migrations/0002_col.sql']"
# (24) the shipped default patterns, where a plan head also fits the epic pattern: a plan release is
#      still judged as a plan, so a direct commit on the plan branch is checked
PLAN=jane/11-05-26/plan-I303-checkout
repo t24; git checkout -q -b plan train
git checkout -q -b epic plan; echo e > src/e.txt; git add -A; git commit -qm story
git checkout -q plan; git merge -q --no-ff -m "Merge pull request #11 from acme/jane/11-05-26/I302-faster-checkout" epic
stub 11 "$PLAN" MERGED "$(git rev-parse HEAD)"; echo direct > infra/direct.tf; git add -A; git commit -qm "direct commit"
git checkout -q train; git merge -q --no-ff -m "Merge pull request #13 from acme/$PLAN" plan; stub 13 train MERGED "$(git rev-parse HEAD)"
python3 - "$WORK/c-t24.json" <<'PY2'
import json, sys
json.dump({"release": {"releaseSource": "develop", "releaseBranchFixExclusions": ["db/migrations/**", "infra/**"]},
           "releaseTrain": {"branch": "train"},
           "epicIntegrationBranches": {"pattern": "<prefix>/<MM-DD-YY>/<epic-number>-<epic-title-slug>"},
           "planIntegrationBranches": {"pattern": "<prefix>/<MM-DD-YY>/plan-<plan-number>-<plan-title-slug>"}}, open(sys.argv[1], "w"))
PY2
OUT="$(python3 "$TOOL" --config "$WORK/c-t24.json" --source-before "$SB" --head train --repo "$WORK/t24" 2>&1)"; RC=$?
expect "(24) with the default patterns a plan release is judged as a plan, its direct commit checked" 1 "d['refused']==['infra/direct.tf'] and d['reviewedUnits']==[13, 11]"

# The review proof: a branch named like an epic is never enough on its own.
E="Merge pull request #30 from acme/jane/26-10-01/epic-checkout"
repo t30; unit epic "$E" infra/queue.tf; NOPROOF=1 stub 30 train MERGED "$(git rev-parse HEAD)"; run t30
expect "(30) an epic-named, gh-confirmed pull request with no review proof is checked like any commit" 1 "d['refused']==['infra/queue.tf'] and d['reviewedUnits']==[]"
repo t31; unit epic "$E" infra/queue.tf; NOPROOF=1 stub 30 train MERGED "$(git rev-parse HEAD)"; proof "$(git rev-parse HEAD^2)" partner success; run t31
expect "(31) a reviewed status posted by someone without admin permission is ignored" 1 "d['refused']==['infra/queue.tf']"
repo t32; unit epic "$E" infra/queue.tf; NOPROOF=1 stub 30 train MERGED "$(git rev-parse HEAD)"; proof "$(git rev-parse HEAD)" owner success; run t32
expect "(32) proof on another commit (the merge, not its merged head) does not count" 1 "d['refused']==['infra/queue.tf']"
repo t33; unit epic "$E" infra/queue.tf; NOPROOF=1 stub 30 train MERGED "$(git rev-parse HEAD)"; proof "$(git rev-parse HEAD^2)" owner failure owner success; run t33
expect "(33) an admin who withdrew the proof (newest admin status failure) leaves the unit unreviewed" 1 "d['refused']==['infra/queue.tf']"
repo t34; unit epic "$E" infra/queue.tf; NOPROOF=1 stub 30 train MERGED "$(git rev-parse HEAD)"; proof "$(git rev-parse HEAD^2)" partner failure owner success; run t34
expect "(34) a later status from a non-admin never overrides an admin's proof" 0 "d['refused']==[] and d['reviewedUnits']==[30] and d['grandfatheredUnits']==[]"
repo t35; unit epic "$E" infra/queue.tf; NOPROOF=1 MERGED_AT=2026-11-01T12:00:00Z stub 30 train MERGED "$(git rev-parse HEAD)"; run t35
expect "(35) a unit merged before the grandfather cutoff keeps the old rule, and is listed as grandfathered" 0 "d['refused']==[] and d['reviewedUnits']==[30] and d['grandfatheredUnits']==[30]"
repo t36; unit epic "$E" infra/queue.tf; NOPROOF=1 MERGED_AT="" stub 30 train MERGED "$(git rev-parse HEAD)"; run t36
expect "(36) no mergedAt from gh is never read as before the cutoff" 1 "d['refused']==['infra/queue.tf']"
repo t37; git config log.showSignature true; git config color.ui always; unit epic "$E" infra/queue.tf; stub 30 train MERGED "$(git rev-parse HEAD)"; run t37
expect "(37) local log and colour settings never change the subject the check reads" 0 "d['reviewedUnits']==[30]"
repo t38; unit epic "$E" infra/queue.tf; NOPROOF=1 stub 30 train MERGED "$(git rev-parse HEAD)"; DESC="Settled review of #12 into jane/26-10-01/epic-checkout" proof "$(git rev-parse HEAD^2)" owner success; run t38
expect "(38) an admin's proof for another pull request or base (a story into the epic) does not count" 1 "d['refused']==['infra/queue.tf'] and d['unprovenUnits'][0]['number']==30 and 'for #30 into train' in d['unprovenUnits'][0]['reason']"
repo t39; unit epic "$E" infra/queue.tf; NOPROOF=1 stub 30 train MERGED "$(git rev-parse HEAD)"; DESC="Settled review of #30 into train, carried from abcdef123456 (same tree)" proof "$(git rev-parse HEAD^2)" owner success; run t39
expect "(39) a proof carried to a tree-identical rebase counts" 0 "d['reviewedUnits']==[30] and d['unprovenUnits']==[]"
repo t40; unit epic "$E" infra/queue.tf; stub 30 train MERGED "$(git rev-parse HEAD)"; GH_STATUS_FAIL=1 run t40
[ "$RC" = 2 ] && [[ "$OUT" == *"review proof of #30 could not be read"* ]] && ok "(40) GitHub unreadable while reading a proof: exit 2, never a guess" || bad "(40) $RC $OUT"
repo t41; unit epic "$E" infra/queue.tf; NOPROOF=1 MERGED_AT=2026-11-01T12:00:00Z stub 30 train MERGED "$(git rev-parse HEAD)"; GH_STATUS_FAIL=1 run t41
expect "(41) a grandfathered unit never needs GitHub's statuses" 0 "d['grandfatheredUnits']==[30]"
repo t42; unit epic "Merge pull request #42 from acme/jane/26-10-01/epic-checkout" infra/queue.tf; run t42
expect "(42) a pull request gh cannot confirm is listed with the reason and checked file by file" 1 "d['refused']==['infra/queue.tf'] and d['unprovenUnits'][0]['number']==42 and d['unprovenUnits'][0]['reason'].startswith('gh could not confirm #42')"
exit $FAIL
