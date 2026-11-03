#!/bin/bash
# Tests for skills/release/scripts/train_exclusions.py — the release train's fix-exclusion check —
# on scratch git repositories with a `gh` stub on PATH. No network, nothing outside a temp dir.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; TOOL="$ROOT/skills/release/scripts/train_exclusions.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/pr"
# gh stub: `gh pr view <n> --json …` prints $WORK/pr/<n>.json, and fails when there is none.
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
[ "$1" = pr ] && [ "$2" = view ] && [ -f "$GH_STUB_DIR/$3.json" ] && { cat "$GH_STUB_DIR/$3.json"; exit 0; }
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
     "epicIntegrationBranches": {"pattern": "<prefix>/<YY-MM-DD>/epic-<epic-title-slug>"}}
if sys.argv[2]:
    c["release"]["migrationRenumber"] = {"sqlGlobs": ["db/migrations/*.sql"], "metaGlobs": ["db/migrations/meta/**"]}
json.dump(c, open(sys.argv[1], "w"))
PY
}
# repo NAME: a repository with develop (also origin/develop), a train branch cut from it, SB = the source at the cut
repo() {
  R="$WORK/$1"; mkdir "$R"; cd "$R" || exit 2
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
stub() { printf '{"baseRefName":"%s","state":"%s","mergeCommit":{"oid":"%s"}}\n' "$2" "$3" "$4" > "$GH_STUB_DIR/$1.json"; }
# run NAME [renumber]: the tool over SB..train; sets RC and OUT
run() { config "$WORK/c-$1.json" "${2:-}"; OUT="$(python3 "$TOOL" --config "$WORK/c-$1.json" --source-before "$SB" --head train --repo "$WORK/$1" 2>&1)"; RC=$?; }
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
exit $FAIL
