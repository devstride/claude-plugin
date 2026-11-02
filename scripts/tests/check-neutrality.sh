#!/bin/bash
# scripts/tests/check-neutrality.sh — the neutrality check flags one repository's own tooling names
# in the shipped tree, exempts exactly what its lists allow, and passes the real tree.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/check-neutrality.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A minimal root: the real lists, and one skill file the cases write.
fresh() {
  rm -rf "$WORK/r"; mkdir -p "$WORK/r/scripts" "$WORK/r/skills/demo"
  cp "$ROOT/scripts/neutrality-denylist.txt" "$ROOT/scripts/neutrality-allow.txt" \
     "$ROOT/scripts/public-hygiene.allow" "$WORK/r/scripts/"
  printf '%s\n' "$@" > "$WORK/r/skills/demo/SKILL.md"
}
run() { OUT="$(bash "$CHECK" --root "$WORK/r" "$@" 2>&1)"; RC=$?; }

# (1) the real tree is clean
OUT="$(bash "$CHECK" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "NEUTRALITY: CLEAN" ]; then ok "(1) the shipped tree is CLEAN"
else bad "(1) the shipped tree is not clean (exit $RC): $OUT"; fi

# (2) each denylist family is flagged with file, line and label
DS="ds"  # spelled apart so this test file never reads as a hit itself
fresh "neutral first line" \
  "run ./$DS run backend" \
  "$DS pool checkout" "$DS tower status" "$DS verify land" "$DS golden build" "$DS work start" \
  "$DS fleet status" "$DS machine ready" "$DS stage create" "$DS migrations run" \
  "$DS worktree ls" "$DS agent mcp-config" "$DS neon branches" "$DS secrets pull" \
  "the Gol""den dataset" "a gol""den build" "the Ne""on branch" "check w""t2 first" \
  "deploy-""prod.yml" "the Deploy"" Prod workflow" "the same rule as a pool"" lease" "item I9""8765" \
  "$DS run ui" "$DS script set-config" "the ne""onctl command" \
  "$DS -u script generate-api-client" "$DS  --stage dev  merge-path check" "$DS team add-developer" \
  "$DS quickbooks search" "$DS graph read-user" "$DS stripe billing" "the ds-""update-docs skill" \
  "see .claude/hooks/merge-""guard.sh" "the deploy"" prod job" "DEPLOY-""PROD"
run
expect_hit() {  # <line> <label>
  if printf '%s\n' "$OUT" | grep -qF "NEUTRALITY: skills/demo/SKILL.md:$1: $2: "; then return 0; fi
  bad "(2) line $1 not flagged as $2"; return 1
}
ALL=0
for spec in 2:launcher 3:command-family 4:command-family 5:command-family 6:command-family \
            7:command-family 8:command-family 9:command-family 10:command-family 11:command-family \
            12:command-family 13:command-family 14:command-family 15:command-family 16:golden \
            17:golden 18:neon 19:checkout-name 20:deploy-workflow 21:deploy-workflow 22:pool-lease \
            23:item-number 24:command-family 25:command-family 26:neon 27:command-family \
            28:command-family 29:command-family 30:command-family 31:command-family \
            32:command-family 33:local-skill 34:merge-guard 35:deploy-workflow 36:deploy-workflow; do
  expect_hit "${spec%%:*}" "${spec#*:}" || ALL=1
done
if [ "$RC" -eq 1 ] && [ "$ALL" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -q 'SKILL.md:1:'; then
  ok "(2) every family is flagged with file, line and label; a neutral line is not"
else bad "(2) exit $RC"; fi

# (3) allowed example item numbers, product names and the hyphenated pool phrase pass
fresh "see I2""0130 and I1""234" "devstride:release, the devstride provider, DEVSTRIDE_SESSION_GATE" \
      "the checkout-pool"" lease when the repo declares a pool" "a golden""rod flower" "ads pool party" \
      "compare against a golden"" file, a golden"" test or golden"" output" \
      "read .claude/ds-""config.json, the ds-""config key and .claude/ds-""lessons.md" "a deployment to prod"
run
if [ "$RC" -eq 0 ] && [ "$OUT" = "NEUTRALITY: CLEAN" ]; then ok "(3) allowed item numbers, product names and neutral look-alikes pass"
else bad "(3) expected clean, got (exit $RC): $OUT"; fi

# (4) an allow line exempts exactly its substring, and nothing else on the same line
fresh "the Deploy"" Prod example and w""t3 too"
printf 'the Deploy Prod example\tan illustration in this test\n' >> "$WORK/r/scripts/neutrality-allow.txt"
run
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q ': checkout-name: ' && ! printf '%s\n' "$OUT" | grep -q ': deploy-workflow: '; then
  ok "(4) an allow line exempts its own substring only"
else bad "(4) got (exit $RC): $OUT"; fi

# (5) the 3.18.0 text of the two known leaks is flagged (regression for their fix)
fresh "x"
mkdir -p "$WORK/r/skills/release/references" "$WORK/r/skills/release/scripts"
printf '%s\n' "- **Holder identity** is the same rule as a pool"" lease, so one identity means one thing everywhere:" \
  > "$WORK/r/skills/release/references/clearance.md"
printf '%s\n' "# ── identity (the same rule as a pool"" lease: one identity means one thing everywhere) ──" \
  > "$WORK/r/skills/release/scripts/clearance-github.sh"
run
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^NEUTRALITY: skills/release/references/clearance.md:1: pool-lease: ' \
   && printf '%s\n' "$OUT" | grep -q '^NEUTRALITY: skills/release/scripts/clearance-github.sh:1: pool-lease: '; then
  ok "(5) the two known leaks, restored, are flagged"
else bad "(5) got (exit $RC): $OUT"; fi

# (6) CHANGELOG history and repository tooling are out of scope
fresh "x"; printf 'retired: deploy-''prod\n' > "$WORK/r/CHANGELOG.md"; printf 'w''t1\n' > "$WORK/r/scripts/tool.sh"
run
if [ "$RC" -eq 0 ]; then ok "(6) CHANGELOG.md and scripts/ are not scanned"; else bad "(6) got (exit $RC): $OUT"; fi

# (7) usage errors exit 2
fresh "x"
bash "$CHECK" --bogus >/dev/null 2>&1; A=$?
bash "$CHECK" --root "$WORK/r" --denylist "$WORK/missing.txt" >/dev/null 2>&1; B=$?
printf 'broken\t(unclosed\n' > "$WORK/bad.txt"; bash "$CHECK" --root "$WORK/r" --denylist "$WORK/bad.txt" >/dev/null 2>&1; C=$?
printf 'no reason here\n' > "$WORK/allow.txt"; bash "$CHECK" --root "$WORK/r" --allow "$WORK/allow.txt" >/dev/null 2>&1; D=$?
if [ "$A" -eq 2 ] && [ "$B" -eq 2 ] && [ "$C" -eq 2 ] && [ "$D" -eq 2 ]; then
  ok "(7) an unknown argument, an unreadable denylist, a bad pattern and a reasonless allow line exit 2"
else bad "(7) exits $A $B $C $D, expected 2 2 2 2"; fi

# (8) a shipped file's own path is scanned too, reported as <path>:path
fresh "neutral"
mkdir -p "$WORK/r/skills/ds-""reset-db" "$WORK/r/skills/demo/references"
printf 'neutral\n' > "$WORK/r/skills/ds-""reset-db/SKILL.md"
printf 'neutral\n' > "$WORK/r/skills/demo/references/golden-""build.md"
run
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "NEUTRALITY: skills/ds-""reset-db/SKILL.md:path: local-skill: " \
   && printf '%s\n' "$OUT" | grep -qF "NEUTRALITY: skills/demo/references/golden-""build.md:path: golden: " \
   && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 2 ]; then
  ok "(8) a repository-specific name in a shipped path is flagged as a path finding"
else bad "(8) got (exit $RC): $OUT"; fi

exit "$FAIL"
