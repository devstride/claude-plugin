#!/bin/bash
# scripts/tests/check-source.sh — the one entry point for the source checks: usage errors, the
# steps each mode lists, their order and arguments, and that the first failing step stops the run
# and is named on the last line. Every check it runs here is a stub in a throwaway copy, so this
# test never starts the real test runner (which would run this test again).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SRC="$ROOT/scripts/check-source.sh"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A throwaway plugin directory: the real check-source.sh beside stubs for every check it runs.
# Each stub appends `<its path> <its arguments>` to $CALLS and fails when $STUB_FAIL names it.
P="$WORK/plugin"; CALLS="$WORK/calls"; export CALLS
mkdir -p "$P/scripts/tests" "$P/skills/doctor/scripts" "$P/hooks"
cp "$SRC" "$P/scripts/check-source.sh"
for s in scripts/validate.sh scripts/check-neutrality.sh scripts/build-config-schema.py scripts/check-config-keys.py \
         skills/doctor/scripts/validate-config.py scripts/check-public-hygiene.sh scripts/check-version-bump.sh \
         scripts/tests/run.sh scripts/measure-cost.sh scripts/check-workflows.py scripts/workflow-registry.py; do
  case "$s" in
    *.py) printf 'import os, sys\nopen(os.environ["CALLS"], "a").write("%s " + " ".join(sys.argv[1:]) + "\\n")\nprint("stub %s")\nsys.exit(1 if os.environ.get("STUB_FAIL") == "%s" else 0)\n' "$s" "$s" "$s" > "$P/$s" ;;
    *) printf 'echo "%s $*" >> "$CALLS"\necho "stub %s"\n[ "${STUB_FAIL:-}" = "%s" ] && exit 1\nexit 0\n' "$s" "$s" "$s" > "$P/$s" ;;
  esac
done
# The hygiene stub also keeps a copy of the published allow list it was handed (the temporary
# file, not the tree's own scripts/public-hygiene.allow, which the second scan names).
printf 'echo "scripts/check-public-hygiene.sh $*" >> "$CALLS"\nwhile [ $# -gt 0 ]; do [ "$1" = --allow ] && [ "$2" != scripts/public-hygiene.allow ] && cp "$2" "$CALLS.allow"; shift; done\necho "stub scripts/check-public-hygiene.sh"\n[ "${STUB_FAIL:-}" = "scripts/check-public-hygiene.sh" ] && exit 1\nexit 0\n' > "$P/scripts/check-public-hygiene.sh"
# A git repository whose only commit is a `plugin import` (no origin/master), holding the allow
# list that was published; the working tree then adds a line of its own that must not count.
printf 'item I20100 the published example\n' > "$P/scripts/public-hygiene.allow"
git -C "$P" init -q && git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@example.com commit -q -m 'plugin import: test baseline'
printf 'item I20101 added by this change\n' >> "$P/scripts/public-hygiene.allow"
CS="$P/scripts/check-source.sh"
run() { : > "$CALLS"; OUT="$(cd "$WORK" && STUB_FAIL="${STUB_FAIL:-}" bash "$CS" "$@" 2>&1)"; RC=$?; LAST="$(printf '%s\n' "$OUT" | tail -n 1)"; }
called() { cut -d' ' -f1 "$CALLS" | tr '\n' ' ' | sed 's/ $//'; }

LOCAL_STEPS="neutrality schema config-keys config-validation hygiene registry version-bump validate"
CLOUD_STEPS="shell-syntax neutrality budgets schema config-keys workflows config-validation hygiene registry version-bump tests"
LOCAL_CALLS="scripts/check-neutrality.sh scripts/build-config-schema.py scripts/check-config-keys.py skills/doctor/scripts/validate-config.py scripts/check-public-hygiene.sh scripts/check-public-hygiene.sh scripts/workflow-registry.py scripts/check-version-bump.sh scripts/validate.sh"
CLOUD_CALLS="scripts/check-neutrality.sh scripts/measure-cost.sh scripts/build-config-schema.py scripts/check-config-keys.py scripts/check-workflows.py skills/doctor/scripts/validate-config.py scripts/check-public-hygiene.sh scripts/check-public-hygiene.sh scripts/workflow-registry.py scripts/check-version-bump.sh scripts/tests/run.sh"

# (1) usage errors: exit 2, a reason on stderr, no verdict line, nothing run.
n=0
for args in "" "--mode" "--mode nightly" "--mode local --base" "--mode local --head" "--mode local --in-flight" "--mode cloud --bogus" "--list" "--mode local extra"; do
  n=$((n + 1))
  # shellcheck disable=SC2086
  run $args
  if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q '^check-source: ' && ! printf '%s' "$OUT" | grep -q 'PLUGIN SOURCE' && [ ! -s "$CALLS" ]; then
    ok "(1.$n) usage error for '$args'"
  else bad "(1.$n) '$args' gave exit $RC: $OUT"; fi
done

# (2) --list names each mode's steps in order and runs nothing.
for mode in local cloud; do
  [ "$mode" = local ] && WANT="$LOCAL_STEPS" || WANT="$CLOUD_STEPS"
  run --mode "$mode" --list
  GOT="$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
  [ "$RC" = 0 ] && [ "$GOT" = "$WANT" ] && [ ! -s "$CALLS" ] && ! printf '%s' "$OUT" | grep -q 'PLUGIN SOURCE' \
    && ok "(2) --list for $mode names its steps and runs nothing" || bad "(2) $mode list, exit $RC: $GOT"
done
run --mode local --list
[ "$(printf '%s\n' "$OUT" | tail -n 1)" = "validate	bash scripts/validate.sh --needles" ] && ! printf '%s\n' "$OUT" | grep -q -e '^tests	' -e '^budgets	' \
  && ok "(2b) local runs validate.sh --needles last and no separate tests or budgets step" || bad "(2b) $OUT"
run --mode cloud --list
[ "$(printf '%s\n' "$OUT" | tail -n 1)" = "tests	bash scripts/tests/run.sh" ] && ok "(2c0) cloud runs the script tests last, after the checks that take seconds" || bad "(2c0) $OUT"
! printf '%s\n' "$OUT" | grep -q 'validate\.sh' && ok "(2c) cloud never runs validate.sh (it needs the claude CLI)" || bad "(2c) $OUT"
run --mode cloud --list --base origin/next
[ "$(printf '%s\n' "$OUT" | grep -c -e '--base origin/next$')" = 2 ] && ok "(2d) --list shows the base the schema and version steps would use" || bad "(2d) $OUT"

# (3) a clean run: every step in order, the base passed on, one verdict line, and it is the last.
for mode in local cloud; do
  [ "$mode" = local ] && WANT="$LOCAL_CALLS" || WANT="$CLOUD_CALLS"
  run --mode "$mode"
  [ "$RC" = 0 ] && [ "$LAST" = "PLUGIN SOURCE: CLEAN" ] && [ "$(called)" = "$WANT" ] && [ "$(printf '%s\n' "$OUT" | grep -c '^PLUGIN SOURCE: ')" = 1 ] \
    && ok "(3) $mode: every step runs in order and the run ends CLEAN" || bad "(3) $mode exit $RC, calls '$(called)': $OUT"
  grep -q '^scripts/build-config-schema.py --check --release --base origin/master$' "$CALLS" \
    && grep -q '^scripts/check-version-bump.sh --base origin/master$' "$CALLS" \
    && grep -q '^scripts/check-public-hygiene.sh --tree \. --allow ' "$CALLS" \
    && grep -q '^skills/doctor/scripts/validate-config.py scripts/tests/fixtures/config/plugin-repo.json --schema schemas/ds-config.schema.json$' "$CALLS" \
    && ok "(3b) $mode: default base origin/master, hygiene on the tree, the example config" || bad "(3b) $mode: $(cat "$CALLS")"
done
run --mode local; grep -q '^scripts/validate.sh --needles$' "$CALLS" && ok "(3c) local passes --needles" || bad "(3c) $(cat "$CALLS")"
[ "$(cat "$CALLS.allow")" = "item I20100 the published example" ] \
  && ok "(3h) hygiene reads the published allow list (the import commit's, the base holding none), not this change's own" || bad "(3h) $(cat "$CALLS.allow")"
[ "$(grep -c '^scripts/check-public-hygiene.sh ' "$CALLS")" = 2 ] \
  && [ "$(grep '^scripts/check-public-hygiene.sh ' "$CALLS" | tail -n 1)" = "scripts/check-public-hygiene.sh --tree . --allow scripts/public-hygiene.allow" ] \
  && ok "(3k) ... and then the change's own list, which the publisher scans the export with, so a withdrawn exception still needed fails here" || bad "(3k) $(cat "$CALLS")"
git -C "$P" branch -q fake-base && git -C "$P" -c user.name=t -c user.email=t@example.com commit -q -am 'a later change' \
  && git -C "$P" checkout -q fake-base -- scripts/public-hygiene.allow
printf 'item I20102 on the base\n' > "$P/scripts/public-hygiene.allow" && git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@example.com commit -q -m 'base list' \
  && git -C "$P" branch -q -f fake-base HEAD && printf 'item I20103 this change\n' > "$P/scripts/public-hygiene.allow"
run --mode local --base fake-base
[ "$(cat "$CALLS.allow")" = "item I20102 on the base" ] && ok "(3i) with a base that holds the list, the base's copy is read" || bad "(3i) $(cat "$CALLS.allow")"
git -C "$P" checkout -q -- scripts/public-hygiene.allow 2>/dev/null
: > "$CALLS"; rm -rf "$P/.git.off"; mv "$P/.git" "$P/.git.off"
run --mode local
[ "$RC" = 1 ] && [ "$LAST" = "PLUGIN SOURCE: FAILED at hygiene" ] && printf '%s' "$OUT" | grep -q 'no published allow list' \
  && ok "(3j) no published allow list anywhere fails the hygiene step, never falls back to the tree's own" || bad "(3j) exit $RC: $OUT"
mv "$P/.git.off" "$P/.git"
run --mode cloud; grep -q '^scripts/measure-cost.sh --check$' "$CALLS" && ok "(3d) cloud checks the budgets" || bad "(3d) $(cat "$CALLS")"
run --mode cloud --base some/ref
grep -q '^scripts/build-config-schema.py --check --release --base some/ref$' "$CALLS" && grep -q '^scripts/check-version-bump.sh --base some/ref$' "$CALLS" \
  && ok "(3e) --base reaches the schema and version steps" || bad "(3e) $(cat "$CALLS")"
printf '%s\n' "$OUT" | grep -q '^== budgets: ' && printf '%s\n' "$OUT" | grep -q '^== version-bump: ' && ok "(3f) each step prints its name" || bad "(3f) $OUT"
run --mode local --base some/ref --head some/commit
grep -q '^scripts/check-version-bump.sh --base some/ref --head some/commit$' "$CALLS" \
  && grep -q '^scripts/build-config-schema.py --check --release --base some/ref$' "$CALLS" && [ "$(grep -c 'some/commit' "$CALLS")" = 1 ] \
  && ok "(3e2) --head reaches the version step only (the one that reads commits, not the tree)" || bad "(3e2) $(cat "$CALLS")"
run --mode local --base some/ref --in-flight some/next --in-flight 'some/release/*'
grep -q '^scripts/check-version-bump.sh --base some/ref --in-flight some/next --in-flight some/release/\*$' "$CALLS" \
  && [ "$(grep -c 'in-flight' "$CALLS")" = 1 ] \
  && ok "(3e3) each --in-flight reaches the version step only, in order, a pattern unexpanded" || bad "(3e3) $(cat "$CALLS")"
# From another working directory, by a relative path.
: > "$CALLS"; OUT="$(cd "$P/skills" && bash ../scripts/check-source.sh --mode local 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(called)" = "$LOCAL_CALLS" ] && ok "(3g) runs from any working directory" || bad "(3g) exit $RC: $OUT"

# (4) the first failing step stops the run and is named on the last line.
fails_at() { # <mode> <stub that fails> <step name> <calls expected, the failing one last>
  STUB_FAIL="$2" run --mode "$1"
  [ "$RC" = 1 ] && [ "$LAST" = "PLUGIN SOURCE: FAILED at $3" ] && [ "$(called)" = "$4" ] && [ "$(printf '%s\n' "$OUT" | grep -c '^PLUGIN SOURCE: ')" = 1 ] \
    && ok "(4) $1: a failing $3 step stops the run there" || bad "(4) $1/$3 exit $RC, last '$LAST', calls '$(called)'"
}
fails_at local scripts/check-neutrality.sh neutrality "scripts/check-neutrality.sh"
fails_at local scripts/check-public-hygiene.sh hygiene "scripts/check-neutrality.sh scripts/build-config-schema.py scripts/check-config-keys.py skills/doctor/scripts/validate-config.py scripts/check-public-hygiene.sh"
fails_at local scripts/workflow-registry.py registry "scripts/check-neutrality.sh scripts/build-config-schema.py scripts/check-config-keys.py skills/doctor/scripts/validate-config.py scripts/check-public-hygiene.sh scripts/check-public-hygiene.sh scripts/workflow-registry.py"
fails_at local scripts/check-version-bump.sh version-bump "scripts/check-neutrality.sh scripts/build-config-schema.py scripts/check-config-keys.py skills/doctor/scripts/validate-config.py scripts/check-public-hygiene.sh scripts/check-public-hygiene.sh scripts/workflow-registry.py scripts/check-version-bump.sh"
fails_at local scripts/validate.sh validate "$LOCAL_CALLS"
fails_at cloud scripts/measure-cost.sh budgets "scripts/check-neutrality.sh scripts/measure-cost.sh"
fails_at cloud scripts/check-workflows.py workflows "scripts/check-neutrality.sh scripts/measure-cost.sh scripts/build-config-schema.py scripts/check-config-keys.py scripts/check-workflows.py"
fails_at cloud scripts/check-public-hygiene.sh hygiene "scripts/check-neutrality.sh scripts/measure-cost.sh scripts/build-config-schema.py scripts/check-config-keys.py scripts/check-workflows.py skills/doctor/scripts/validate-config.py scripts/check-public-hygiene.sh"
fails_at cloud scripts/workflow-registry.py registry "scripts/check-neutrality.sh scripts/measure-cost.sh scripts/build-config-schema.py scripts/check-config-keys.py scripts/check-workflows.py skills/doctor/scripts/validate-config.py scripts/check-public-hygiene.sh scripts/check-public-hygiene.sh scripts/workflow-registry.py"
fails_at cloud scripts/check-version-bump.sh version-bump "scripts/check-neutrality.sh scripts/measure-cost.sh scripts/build-config-schema.py scripts/check-config-keys.py scripts/check-workflows.py skills/doctor/scripts/validate-config.py scripts/check-public-hygiene.sh scripts/check-public-hygiene.sh scripts/workflow-registry.py scripts/check-version-bump.sh"
fails_at cloud scripts/tests/run.sh tests "$CLOUD_CALLS"

# (5) cloud's own syntax step: a script that does not parse fails it before anything else runs.
printf 'if then\n' > "$P/hooks/broken.sh"
run --mode cloud
[ "$RC" = 1 ] && [ "$LAST" = "PLUGIN SOURCE: FAILED at shell-syntax" ] && [ ! -s "$CALLS" ] && printf '%s' "$OUT" | grep -q 'hooks/broken.sh' \
  && ok "(5) cloud: a script with a syntax error fails shell-syntax first" || bad "(5) exit $RC: $OUT"
rm -f "$P/hooks/broken.sh"

# (6) the real script's lists are the ones this test pins (the copy above is the real file).
cmp -s "$SRC" "$CS" && ok "(6) the tested copy is the shipped script" || bad "(6) the copy differs"
exit $FAIL
