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

# (1) tip reads the production tip before the checks; stamp names head, tree, that tip, class and
#     time; verify on the same state is UNCHANGED
run tip; TIP="$OUT"; M1="$(git rev-parse origin/main)"
run stamp --head "$HEAD1" --class light --master "$M1"; S="$OUT"
T1="$(git rev-parse "$HEAD1^{tree}")"
run verify --stamp "$S" --head "$HEAD1"
if [ "$TIP" = "PRODUCTION TIP $M1" ] && [ "$S" = "CHECKS STAMP head $HEAD1 tree $T1 master $M1 class LIGHT at 2026-10-18T10:05:00Z" ] && [ "$RC" -eq 0 ] && [ "$OUT" = "UNCHANGED head $HEAD1 tree $T1 master $M1" ]; then
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
git reset -q --hard "$HEAD1"; git merge -q --no-edit origin/main; run stamp --head HEAD --class FULL --master "$(git rev-parse origin/main)"; S2="$OUT"
git checkout -q main; git merge -q --ff-only release/26-10-18; git push -q origin main; git checkout -q release/26-10-18
run verify --stamp "$S2" --head HEAD
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^CHANGED master' && ! printf '%s' "$OUT" | grep -q 'CHANGED tree'; then
  ok "(5) production moved to a commit with the release's own tree → still CHANGED master (re-run against the new tip)"
else bad "(5) rc=$RC: $OUT"; fi

# (6) a stamp that cannot be parsed, a bad class, or an unknown head is an ERROR (exit 1), never UNCHANGED
run verify --stamp "CHECKS STAMP head nope" --head HEAD; A="$RC:$OUT"
run stamp --head HEAD --class MEDIUM --master "$M1"; B="$RC:$OUT"
run verify --stamp "$S" --head 0000000000000000000000000000000000000000; C="$RC:$OUT"
run verify --head HEAD; D="$RC:$OUT"
if [ "${A%%:*}" -eq 1 ] && printf '%s' "$A" | grep -q '^1:ERROR the stamp cannot be parsed' && [ "${B%%:*}" -eq 1 ] && [ "${C%%:*}" -eq 1 ] && [ "${D%%:*}" -eq 1 ] \
   && ! printf '%s%s%s%s' "$A" "$B" "$C" "$D" | grep -q UNCHANGED; then
  ok "(6) an unparsable stamp, a bad class, an unknown head or a missing stamp → ERROR, exit 1"
else bad "(6) a=$A b=$B c=$C d=$D"; fi

# (7) production moved while the checks ran (between tip and stamp) → stamp says CHANGED master,
#     exit 3, and prints no stamp: the checks run again; stamp without --master is an ERROR
git checkout -q -b r7 "$HEAD1"; BEGAN="$(git rev-parse origin/main)"
git checkout -q main; echo m7 > m7; git add m7; git commit -qm "release ahead merged"; git push -q origin main; git checkout -q r7
git merge -q --no-edit "$BEGAN" 2>/dev/null
run stamp --head HEAD --class FULL --master "$BEGAN"; A="$RC:$OUT"; run stamp --head HEAD --class FULL; B="$RC:$OUT"
if [ "${A%%:*}" -eq 3 ] && printf '%s' "$A" | grep -q "^3:CHANGED master ${BEGAN:0:12}\.\." && ! printf '%s' "$A" | grep -q 'CHECKS STAMP' \
   && [ "${B%%:*}" -eq 1 ] && printf '%s' "$B" | grep -q '^1:ERROR usage'; then
  ok "(7) production moved between tip and stamp → CHANGED master (exit 3), no stamp; no --master → ERROR"
else bad "(7) a=$A b=$B"; fi

# (8) an unchanged pair whose production tip the head does not contain (a hotfix not yet in the
#     release source) is BEHIND, exit 3: merging would combine the release with untested commits
git checkout -q -b r8 "$HEAD1"; NOW_TIP="$(git rev-parse origin/main)"
run stamp --head HEAD --class LIGHT --master "$NOW_TIP"; S8="$OUT"; run verify --stamp "$S8" --head HEAD; A="$RC:$OUT"
git merge -q --no-edit origin/main; run stamp --head HEAD --class LIGHT --master "$NOW_TIP"; S9="$OUT"; run verify --stamp "$S9" --head HEAD; B="$RC:$OUT"
if printf '%s' "$S8" | grep -q '^CHECKS STAMP' && [ "${A%%:*}" -eq 3 ] && printf '%s' "$A" | grep -q "^3:BEHIND master ${NOW_TIP:0:12} " \
   && [ "${B%%:*}" -eq 0 ] && printf '%s' "$B" | grep -q '^0:UNCHANGED'; then
  ok "(8) a stamped production tip the head does not contain → BEHIND (exit 3); merged in and checked again → UNCHANGED"
else bad "(8) s8=$S8 a=$A b=$B"; fi

# (9) the queue story: release N+1 is cut while release N merges into production; `contains` says
#     BEHIND until production (N's merge) is merged into N+1's branch, then CONTAINS; N+1 is checked
#     and stamped on top of N's merge, and that stamp verifies UNCHANGED while N deploys. When N is
#     reverted (production moves again) the stamp is CHANGED master: N+1 is rebuilt and checked again
git checkout -q main; git checkout -q -b release/26-10-19 main; echo n > n; git add n; git commit -qm "release N"
git checkout -q main; git checkout -q -b release/26-10-19-2 release/26-10-19; echo n1 > n1; git add n1; git commit -qm "release N+1 work"
NEXT_CUT="$(git rev-parse HEAD)"
git checkout -q main; git merge -q --no-ff --no-edit -m "Merge release N" release/26-10-19; git push -q origin main; git checkout -q release/26-10-19-2
run contains --head "$NEXT_CUT"; A="$RC:$OUT"
git merge -q --no-ff --no-edit origin/main; ON_TOP="$(git rev-parse HEAD)"; run contains --head "$ON_TOP"; B="$RC:$OUT"
run tip; N_TIP="${OUT#PRODUCTION TIP }"; run stamp --head "$ON_TOP" --class LIGHT --master "$N_TIP"; S10="$OUT"
run verify --stamp "$S10" --head "$ON_TOP"; C="$RC:$OUT"
git checkout -q main; git revert --no-edit -m 1 HEAD >/dev/null; git push -q origin main; git checkout -q release/26-10-19-2
run verify --stamp "$S10" --head "$ON_TOP"; D="$RC:$OUT"; run contains --head "$ON_TOP"; E="$RC:$OUT"
run contains --head 0000000000000000000000000000000000000000; F="$RC:$OUT"; run contains; G="$RC:$OUT"
if printf '%s' "$A" | grep -q "^3:BEHIND master $(printf '%s' "$N_TIP" | cut -c1-12) " && printf '%s' "$B" | grep -q "^0:CONTAINS master $N_TIP " \
   && printf '%s' "$C" | grep -q '^0:UNCHANGED' && printf '%s' "$D" | grep -q '^3:CHANGED master' && printf '%s' "$E" | grep -q '^3:BEHIND master' \
   && printf '%s' "$F" | grep -q '^1:ERROR' && printf '%s' "$G" | grep -q '^1:ERROR usage'; then
  ok "(9) prepared on top of the release ahead: BEHIND until its merge is brought in, CONTAINS after, UNCHANGED while it deploys, CHANGED once it is reverted; a bad head → ERROR"
else bad "(9) a=$A b=$B c=$C d=$D e=$E f=$F g=$G"; fi

exit $FAIL
