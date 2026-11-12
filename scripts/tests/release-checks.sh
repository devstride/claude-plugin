#!/bin/bash
# Tests for skills/release/scripts/release_checks.py — the check stamp of scope merge-and-deploy:
# the tested tree is the merged tree only while the head's tree and the production tip are both
# unchanged. A real bare origin; no network; nothing outside a private TMPDIR.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; RC_PY="$ROOT/skills/release/scripts/release_checks.py"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1 DEVSTRIDE_MERGE_GUARD=0; mkdir -p "$HOME"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
export RELEASE_CHECKS_NOW=2026-10-18T10:05:00Z

git init -q --bare "$WORK/origin.git"
git init -q -b main "$WORK/w" 2>/dev/null || { git init -q "$WORK/w"; git -C "$WORK/w" checkout -q -b main; }
cd "$WORK/w" || exit 1
mkdir -p .claude; printf '{"release": {"productionBranch": "main"}}' > .claude/ds-config.json
echo a > a; git add -A; git commit -qm base; git remote add origin "$WORK/origin.git"; git push -q origin main
git checkout -q -b release/26-10-18; echo b > b; git add b; git commit -qm work; HEAD1="$(git rev-parse HEAD)"
run() { OUT="$(python3 "$RC_PY" "$@" 2>&1)"; RC=$?; }

# (1) stamp names head, tree, production tip, class and time; verify on the same state is UNCHANGED
run stamp --head "$HEAD1" --class light; S="$OUT"
T1="$(git rev-parse "$HEAD1^{tree}")"; M1="$(git rev-parse origin/main)"
run verify --stamp "$S" --head "$HEAD1"
if [ "$S" = "CHECKS STAMP head $HEAD1 tree $T1 master $M1 class LIGHT at 2026-10-18T10:05:00Z" ] && [ "$RC" -eq 0 ] && [ "$OUT" = "UNCHANGED head $HEAD1 tree $T1 master $M1" ]; then
  ok "(1) stamp → CHECKS STAMP head/tree/master/class/at; verify unchanged → UNCHANGED, exit 0"
else bad "(1) s=$S rc=$RC out=$OUT"; fi

# (2) an empty same-tree re-trigger commit is UNCHANGED (the tree is what was tested)
git commit -q --allow-empty -m retrigger; run verify --stamp "$S" --head HEAD
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^UNCHANGED'; then ok "(2) an empty re-trigger commit with the same tree → UNCHANGED"; else bad "(2) rc=$RC: $OUT"; fi

# (3) a fix commit changes the tree → CHANGED tree, exit 3
echo fix > c; git add c; git commit -qm fix; run verify --stamp "$S" --head HEAD
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^CHANGED tree ' && ! printf '%s' "$OUT" | grep -q 'CHANGED master'; then ok "(3) a fix commit → CHANGED tree, exit 3"; else bad "(3) rc=$RC: $OUT"; fi

# (4) production advanced (a hotfix, the release ahead merging) → CHANGED master, even with the same tree
git checkout -q main; echo h > h; git add h; git commit -qm hotfix; git push -q origin main; git checkout -q release/26-10-18
run verify --stamp "$S" --head "$HEAD1"
if [ "$RC" -eq 3 ] && [ "$OUT" = "CHANGED master ${M1:0:12}..$(git rev-parse origin/main | cut -c1-12)" ]; then ok "(4) production advanced → CHANGED master, exit 3"; else bad "(4) rc=$RC: $OUT"; fi

# (5) production merged into the release branch: the checks must re-run against the new tip
git reset -q --hard "$HEAD1"; git merge -q --no-edit origin/main; run stamp --head HEAD --class FULL; S2="$OUT"
git checkout -q main; git merge -q --ff-only release/26-10-18; git push -q origin main; git checkout -q release/26-10-18
run verify --stamp "$S2" --head HEAD
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^CHANGED master' && ! printf '%s' "$OUT" | grep -q 'CHANGED tree'; then
  ok "(5) production moved to a commit with the release's own tree → still CHANGED master (re-run against the new tip)"
else bad "(5) rc=$RC: $OUT"; fi

# (6) a stamp that cannot be parsed, a bad class, or an unknown head is an ERROR (exit 1), never UNCHANGED
run verify --stamp "CHECKS STAMP head nope" --head HEAD; A="$RC:$OUT"
run stamp --head HEAD --class MEDIUM; B="$RC:$OUT"
run verify --stamp "$S" --head 0000000000000000000000000000000000000000; C="$RC:$OUT"
run verify --head HEAD; D="$RC:$OUT"
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q '^1:ERROR the stamp cannot be parsed' && [ "${B%%:*}" -eq 1 ] && [ "${C%%:*}" -eq 1 ] && [ "${D%%:*}" -eq 1 ] \
   && ! printf '%s%s%s%s' "$A" "$B" "$C" "$D" | grep -q UNCHANGED; then
  ok "(6) an unparsable stamp, a bad class, an unknown head or a missing stamp → ERROR, exit 1"
else bad "(6) a=$A b=$B c=$C d=$D"; fi

exit $FAIL
